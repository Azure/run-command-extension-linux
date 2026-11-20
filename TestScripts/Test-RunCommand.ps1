#requires -Version 7.3
<#
.SYNOPSIS
Builds and tests the local action RunCommand extension on a disposable Azure VM.
.DESCRIPTION
Uses an existing az login and its default subscription. Creates billable resources.
Replaces the installed extension through CustomScript, never through RunCommand.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $Region = 'CentralUSEUAP',
    [ValidateNotNullOrEmpty()][string] $VmSize = 'Standard_D2s_v5',
    [switch] $KeepResources,
    [string[]] $Test = @('*')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:HarnessPath = $PSCommandPath
$script:LastConsoleUtc = [DateTime]::UtcNow

function Write-Step {
    param([string] $Message, [ConsoleColor] $Color = [ConsoleColor]::Cyan)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
    $script:LastConsoleUtc = [DateTime]::UtcNow
}

function Protect-Text {
    param([AllowEmptyString()][string] $Text)
    foreach ($secret in $script:Secrets) {
        if ($secret) { $Text = $Text.Replace($secret, '<redacted>') }
    }
    $Text -replace '(?i)([?&](?:sig|skoid|sktid|skt|ske|sks|skv|se|sp|sv|sr)=)[^&\s"''<>]+', '$1<redacted>'
}

function Write-JsonFile {
    param([string] $Path, [object] $Value)
    $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Invoke-Native {
    param(
        [string] $Executable, [string[]] $Arguments, [string] $Activity,
        [int] $TimeoutSeconds = 1800, [switch] $AllowFailure
    )
    $path = Join-Path $script:PrivateDirectory "$([guid]::NewGuid()).native.json"
    $process = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $msiCli = $false
        if ($Executable -eq 'az') {
            $cliPath = (Get-Command az -ErrorAction Stop).Source
            if ([IO.Path]::GetExtension($cliPath) -ieq '.cmd') {
                $cliPython = [IO.Path]::GetFullPath((Join-Path (Split-Path $cliPath -Parent) '..\python.exe'))
                if (-not (Test-Path -LiteralPath $cliPython -PathType Leaf)) {
                    throw 'This Azure CLI command wrapper has no adjacent bundled Python. Use the Windows MSI Azure CLI or an az.exe installation.'
                }
                # MSI az.cmd uses isolated Python, which ignores PYTHONIOENCODING.
                $Executable = $cliPython
                $Arguments = @('-I', '-X', 'utf8', '-B', '-m', 'azure.cli') + $Arguments
                $msiCli = $true
            }
        }
        Write-JsonFile $path @{ executable = $Executable; arguments = $Arguments }
        $escapedPath = $path.Replace("'", "''")
        $command = @"
`$ErrorActionPreference = 'Stop'
`$PSNativeCommandUseErrorActionPreference = `$false
`$OutputEncoding = [Text.UTF8Encoding]::new(`$false)
[Console]::OutputEncoding = `$OutputEncoding
`$document = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText('$escapedPath'))
try {
    `$tool = `$document.RootElement.GetProperty('executable').GetString()
    `$toolArguments = @(`$document.RootElement.GetProperty('arguments').EnumerateArray() | ForEach-Object { `$_.GetString() })
}
finally { `$document.Dispose() }
& `$tool @toolArguments
exit `$LASTEXITCODE
"@
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $start.WorkingDirectory = $PWD.ProviderPath
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $start.Environment['PYTHONIOENCODING'] = 'utf-8'
        if ($msiCli) { $start.Environment['AZ_INSTALLER'] = 'MSI' }
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand',
            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) {
            $start.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(1000)) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw [TimeoutException]::new("Timed out after $TimeoutSeconds seconds: $Activity")
            }
            if (([DateTime]::UtcNow - $script:LastConsoleUtc).TotalSeconds -ge 60) {
                Write-Step "Still $Activity ($([int]$timer.Elapsed.TotalSeconds)s elapsed)." DarkGray
            }
        }
        if (-not [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).Wait(5000)) {
            throw [TimeoutException]::new("Output streams did not close: $Activity")
        }
        $result = @{
            ExitCode = $process.ExitCode
            StdOut = $stdout.GetAwaiter().GetResult()
            StdErr = $stderr.GetAwaiter().GetResult()
        }
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "$Activity failed (exit $($result.ExitCode)). $(Protect-Text ($result.StdErr + $result.StdOut))"
        }
        return $result
    }
    finally {
        if ($process) {
            if (-not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { Write-Warning "Native process $($process.Id) did not exit." }
            }
            $process.Dispose()
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Az {
    param(
        [string[]] $Arguments, [string] $Activity,
        [ValidateSet('json', 'tsv', 'none')][string] $Output = 'json',
        [int] $TimeoutSeconds = 1800,
        [switch] $WithoutSubscription, [switch] $AllowFailure,
        [switch] $RetryStorageAuthorization,
        [int] $AuthorizationTimeoutSeconds = 600
    )
    $cliArguments = @($Arguments) + @('--output', $Output, '--only-show-errors')
    if (-not $WithoutSubscription) { $cliArguments += @('--subscription', $script:SubscriptionId) }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $notified = $false
    while ($true) {
        $remaining = $TimeoutSeconds - $timer.Elapsed.TotalSeconds
        if ($remaining -le 0) { throw [TimeoutException]::new("Timed out while $Activity") }
        $result = Invoke-Native az $cliArguments $Activity -TimeoutSeconds ([int][math]::Ceiling($remaining)) -AllowFailure
        if (-not $RetryStorageAuthorization -or $result.ExitCode -eq 0) { break }
        $authorizationError = $result.StdErr -match 'AuthorizationPermissionMismatch|AuthorizationFailure|\bForbidden\b|\b403\b|You do not have the required permissions'
        if (-not $authorizationError -or $result.StdErr -match 'AADSTS|AuthenticationFailed|InvalidAuthenticationInfo') { break }
        if ($timer.Elapsed.TotalSeconds -ge $AuthorizationTimeoutSeconds) { break }
        if (-not $notified) {
            Write-Step "Storage authorization rejected $Activity; allowing up to $AuthorizationTimeoutSeconds seconds for RBAC propagation." Yellow
            $notified = $true
        }
        Start-Sleep -Seconds 10
    }
    if ($AllowFailure) { return $result }
    if ($result.ExitCode -ne 0) {
        throw "$Activity failed (exit $($result.ExitCode)). $(Protect-Text ($result.StdErr + $result.StdOut))"
    }
    if ($Output -eq 'json' -and $result.StdOut.Trim()) {
        return ConvertFrom-Json -InputObject $result.StdOut -AsHashtable
    }
    if ($Output -eq 'tsv') { return $result.StdOut.Trim() }
}

function Wait-Condition {
    param([string] $Activity, [scriptblock] $Probe, [int] $TimeoutSeconds = 1200)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Probe)) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw [TimeoutException]::new("Timed out while $Activity")
        }
        if (([DateTime]::UtcNow - $script:LastConsoleUtc).TotalSeconds -ge 60) {
            Write-Step "Still $Activity ($([int]$timer.Elapsed.TotalSeconds)s elapsed)." DarkGray
        }
        Start-Sleep -Seconds 10
    }
}

function Enter-ValidationInstance {
    if (-not $IsWindows) { throw 'This harness requires Windows and PowerShell 7.3 or later.' }
    $fullPath = [IO.Path]::GetFullPath($script:HarnessPath)
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($fullPath.ToLowerInvariant()))).Substring(0, 24)
    $statePath = Join-Path ([IO.Path]::GetTempPath()) "action-runcommand-$key.instance.json"
    $mutex = [Threading.Mutex]::new($false, "Local\ActionRunCommandValidation-$key")
    $acquired = $false
    $registration = $null
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(60)) }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Step 'Recovered an interrupted validation startup lock.' Yellow
        }
        if (-not $acquired) { throw 'Timed out acquiring the validation startup lock.' }
        if (Test-Path -LiteralPath $statePath) {
            $active = $false
            try {
                $probe = [IO.File]::Open($statePath, 'Open', 'ReadWrite', 'None')
                $probe.Dispose()
            }
            catch [IO.IOException] {
                if (($_.Exception.HResult -band 0xffff) -notin @(32, 33)) { throw }
                $active = $true
            }
            if ($active) {
                $reader = [IO.StreamReader]::new([IO.File]::Open($statePath, 'Open', 'Read', 'ReadWrite'))
                try { $previous = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable }
                finally { $reader.Dispose() }
                $snapshot = @(Get-CimInstance Win32_Process)
                $ancestor = $PID
                while ($ancestor) {
                    if ($ancestor -eq $previous.ProcessId) { throw 'Refusing to terminate this PowerShell host or its ancestor.' }
                    $record = @($snapshot | Where-Object { $_.ProcessId -eq $ancestor })
                    $ancestor = if ($record.Count) { [int]$record[0].ParentProcessId } else { 0 }
                }
                $process = Get-Process -Id $previous.ProcessId -ErrorAction SilentlyContinue
                try {
                    if (-not $process -or $previous.ScriptPath -ine $fullPath -or
                        [string]$process.StartTime.ToUniversalTime().Ticks -ne $previous.ProcessStartTicks) {
                        throw 'Previous registration does not match its process; refusing unverified termination.'
                    }
                    $null = $process.Handle
                    Write-Step "Stopping the previous registered validation host (PID $($process.Id)) and its children." Yellow
                    $process.Kill($true)
                    if (-not $process.WaitForExit(30000)) { throw 'Previous validation process did not exit.' }
                }
                finally { if ($process) { $process.Dispose() } }
            }
        }
        $registration = [IO.File]::Open($statePath, 'OpenOrCreate', 'ReadWrite', 'Read')
        $self = Get-Process -Id $PID
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes((@{
                ScriptPath = $fullPath; ProcessId = $PID
                ProcessStartTicks = [string]$self.StartTime.ToUniversalTime().Ticks
            } | ConvertTo-Json -Compress))
        }
        finally { $self.Dispose() }
        $registration.SetLength(0)
        $registration.Write($bytes, 0, $bytes.Length)
        $registration.Flush()
        return $registration
    }
    catch {
        if ($registration) { $registration.Dispose() }
        throw
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-LoggedInAzureAccount {
    Write-Step 'Checking the existing Azure CLI login and default subscription.'
    $account = Invoke-Az @('account', 'show') 'checking Azure CLI login' -WithoutSubscription -AllowFailure -TimeoutSeconds 120
    if ($account.ExitCode -ne 0) { throw "Run az login first. $(Protect-Text $account.StdErr)" }
    $details = ConvertFrom-Json $account.StdOut -AsHashtable
    if ($details['user']['type'] -ne 'user') { throw 'A signed-in Azure CLI user is required for user-delegation SAS.' }
    $token = Invoke-Az @('account', 'get-access-token', '--resource-type', 'arm', '--query', 'accessToken') `
        'validating ARM credentials' -WithoutSubscription -AllowFailure -Output tsv -TimeoutSeconds 120
    if ($token.ExitCode -ne 0) { throw "Azure authentication expired; run az login. $(Protect-Text $token.StdErr)" }
    $script:Secrets.Add($token.StdOut.Trim())
    $parts = $token.StdOut.Trim().Split('.')
    if ($parts.Count -ne 3) { throw 'ARM token is not a JWT; cannot read user identity metadata.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
    $claims = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))) -AsHashtable
    $objectId = [guid]::Empty
    if ($claims['tid'] -ine $details.tenantId -or
        -not [guid]::TryParse([string]$claims['oid'], [ref]$objectId) -or $objectId -eq [guid]::Empty) {
        throw 'ARM identity metadata is missing or belongs to another tenant.'
    }
    $details.userObjectId = $objectId.ToString()
    return $details
}

function Build-RunCommand {
    param([string] $RepositoryRoot)
    Write-Step "Building local Linux/amd64 extension and Go test executables. Results: $($script:OutputDirectory)"
    $old = @{ GOOS = $env:GOOS; GOARCH = $env:GOARCH; CGO_ENABLED = $env:CGO_ENABLED }
    try {
        $env:GOOS = 'linux'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
        [xml]$manifest = Get-Content (Join-Path $RepositoryRoot 'misc\manifest.xml') -Raw
        $version = [string]$manifest.ExtensionImage.Version
        Push-Location $RepositoryRoot
        try {
            $null = Invoke-Native go @('build', '-mod=vendor', '-tags', 'netgo,osusergo',
                '-ldflags', "-X main.Version=$version", '-o',
                (Join-Path $script:OutputDirectory 'run-command-extension'), '.\main') 'building the Linux extension'
            $testRoot = Join-Path $script:OutputDirectory 'go-tests'
            $null = New-Item -ItemType Directory $testRoot
            foreach ($package in @('main', 'pkg\blobutil', 'pkg\download', 'pkg\preprocess', 'pkg\seqnum')) {
                $name = Split-Path $package -Leaf
                $directory = Join-Path $testRoot $name
                $null = New-Item -ItemType Directory $directory
                $null = Invoke-Native go @('test', '-c', '-vet=off', '-mod=vendor', '-cover',
                    '-o', (Join-Path $directory 'tests'), ".\$package") "compiling Linux tests for $package"
                $fixtures = Join-Path $RepositoryRoot "$package\testdata"
                if (Test-Path -LiteralPath $fixtures) {
                    Copy-Item -LiteralPath $fixtures -Destination $directory -Recurse
                    # Windows autocrlf changes these explicitly LF checksum fixtures.
                    foreach ($fixture in Get-ChildItem (Join-Path $directory 'testdata') -File -Filter 'utf8_*') {
                        $bytes = [IO.File]::ReadAllBytes($fixture.FullName)
                        $normalized = [Collections.Generic.List[byte]]::new()
                        for ($index = 0; $index -lt $bytes.Length; $index++) {
                            if ($bytes[$index] -eq 13 -and $index + 1 -lt $bytes.Length -and $bytes[$index + 1] -eq 10) { continue }
                            $normalized.Add($bytes[$index])
                        }
                        [IO.File]::WriteAllBytes($fixture.FullName, $normalized.ToArray())
                    }
                }
            }
            Compress-Archive -Path (Join-Path $testRoot '*') -DestinationPath (Join-Path $script:OutputDirectory 'go-tests.zip')
        }
        finally { Pop-Location }
        $shim = [IO.File]::ReadAllText((Join-Path $RepositoryRoot 'misc\run-command-shim')) -replace "`r", ''
        [IO.File]::WriteAllText((Join-Path $script:OutputDirectory 'run-command-shim'), $shim)
    }
    finally {
        foreach ($key in $old.Keys) { [Environment]::SetEnvironmentVariable($key, $old[$key], 'Process') }
    }
}

function New-BlobSas {
    param([string] $Name, [string] $Permissions = 'r')
    $uri = Invoke-Az @('storage', 'blob', 'generate-sas', '--account-name', $script:StorageName,
        '--container-name', 'validation', '--name', $Name, '--permissions', $Permissions,
        '--expiry', [DateTime]::UtcNow.AddHours(4).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture),
        '--auth-mode', 'login', '--as-user', '--https-only', '--full-uri') `
        "issuing a user-delegation SAS for $Name" -Output tsv -RetryStorageAuthorization
    $script:Secrets.Add($uri)
    return $uri
}

function Send-Blob {
    param([string] $Path, [string] $Name)
    $null = Invoke-Az @('storage', 'blob', 'upload', '--account-name', $script:StorageName,
        '--container-name', 'validation', '--name', $Name, '--file', $Path,
        '--overwrite', 'true', '--auth-mode', 'login', '--no-progress') `
        "uploading $Name using Entra authentication" -Output none -RetryStorageAuthorization
}

function Receive-Blob {
    param([string] $Name, [string] $Path)
    $null = Invoke-Az @('storage', 'blob', 'download', '--account-name', $script:StorageName,
        '--container-name', 'validation', '--name', $Name, '--file', $Path,
        '--overwrite', 'true', '--auth-mode', 'login', '--no-progress') `
        "downloading $Name" -Output none -RetryStorageAuthorization
}

function Invoke-CustomScript {
    param([string] $Action, [hashtable] $Configuration = @{})
    Write-Step "CustomScript: $Action."
    $name = "guest-$([guid]::NewGuid().ToString('N')).json"
    $configPath = Join-Path $script:PrivateDirectory $name
    $protectedPath = Join-Path $script:PrivateDirectory "cse-$name"
    $uploaded = $false
    try {
        Write-JsonFile $configPath $Configuration
        Send-Blob $configPath $name
        $uploaded = $true
        $uris = @($script:GuestScriptUri, (New-BlobSas $name))
        if ($Action -eq 'install') { $uris += $script:BinaryUris }
        Write-JsonFile $protectedPath @{
            fileUris = $uris
            commandToExecute = "python3 Invoke-RunCommandGuest.py $Action $name"
        }
        $null = Invoke-Az @('vm', 'extension', 'set', '-g', $script:ResourceGroup,
            '--vm-name', $script:VmName, '--name', 'CustomScript', '--publisher', 'Microsoft.Azure.Extensions',
            '--version', '2.1', '--extension-instance-name', 'ActionRunCommandValidationCSE',
            '--force-update', '--protected-settings', "@$protectedPath") `
            "running CustomScript '$Action'" -Output none -TimeoutSeconds 600
    }
    finally {
        Remove-Item -LiteralPath $configPath, $protectedPath -Force -ErrorAction SilentlyContinue
        if ($uploaded) {
            try {
                $null = Invoke-Az @('storage', 'blob', 'delete', '--account-name', $script:StorageName,
                    '--container-name', 'validation', '--name', $name, '--auth-mode', 'login') `
                    'removing the temporary guest configuration' -Output none -RetryStorageAuthorization `
                    -AuthorizationTimeoutSeconds 120 -TimeoutSeconds 150
            }
            catch { Write-Warning "Guest configuration cleanup failed: $(Protect-Text $_.Exception.Message)" }
        }
    }
}

function Invoke-ActionRunCommand {
    param([string] $Name, [string] $Script, [string[]] $Parameters = @())
    $path = Join-Path $script:PrivateDirectory "$Name.sh"
    try {
        [IO.File]::WriteAllText($path, $Script, [Text.UTF8Encoding]::new($false))
        $arguments = @('vm', 'run-command', 'invoke', '-g', $script:ResourceGroup, '-n', $script:VmName,
            '--command-id', 'RunShellScript', '--scripts', "@$path")
        if ($Parameters.Count) { $arguments += @('--parameters') + $Parameters }
        $response = Invoke-Az $arguments "executing action RunCommand '$Name'" -TimeoutSeconds 600
        Write-JsonFile (Join-Path $script:OutputDirectory "$Name.response.json") $response
        if (-not $response -or -not $response['value'] -or $response.value.Count -eq 0) {
            throw 'Action RunCommand returned no instance-view status.'
        }
        foreach ($value in $response.value) {
            if ($value.code -notmatch '/succeeded$') { throw "Action RunCommand did not succeed: $(Protect-Text ($value | ConvertTo-Json -Compress))" }
        }
        return (($response.value | ForEach-Object { [string]$_.message }) -join "`n") -replace "`r", ''
    }
    finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Assert-Contains {
    param([string] $Actual, [string] $Expected)
    if (-not $Actual.Contains($Expected)) { throw "Expected '$Expected' in output. Received: $Actual" }
}

function Invoke-TestCase {
    param([string] $Name, [scriptblock] $Body)
    if (-not @($Test | Where-Object { $Name -like $_ }).Count) {
        $script:Results.Add(@{ Name = $Name; State = 'Skipped'; Reason = 'Excluded by -Test selector' })
        Write-Step "SKIP $Name (test selector)" Yellow
        return
    }
    Write-Step "TEST $Name"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = @{ Name = $Name; State = 'Failed'; Seconds = 0; Error = $null }
    try {
        & $Body
        $result.State = 'Passed'
        Write-Step "PASS $Name" Green
    }
    catch {
        $result.Error = Protect-Text $_.Exception.Message
        Write-Step "FAIL $Name`: $($result.Error)" Red
        if ($_.Exception -is [TimeoutException]) { throw }
    }
    finally {
        $result.Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
        $script:Results.Add($result)
    }
}

function Remove-TestResourceGroup {
    Write-Step "Deleting $($script:ResourceGroup) and all contained test resources."
    $null = Invoke-Az @('group', 'delete', '--name', $script:ResourceGroup, '--yes', '--no-wait') `
        'requesting resource-group deletion' -Output none
    Wait-Condition 'waiting for resource-group deletion' {
        (Invoke-Az @('group', 'exists', '--name', $script:ResourceGroup) 'checking resource-group deletion' -Output tsv -TimeoutSeconds 120) -eq 'false'
    } -TimeoutSeconds 2400
}

function New-TestInfrastructure {
    param([string] $Owner, [string] $ObjectId)
    $location = $Region.ToLowerInvariant()
    $script:StorageName = "rcact$Owner$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $vnet = 'validation-vnet'; $ip = 'validation-ip'; $nsg = 'validation-nsg'; $nic = 'validation-nic'
    $storageId = "[resourceId('Microsoft.Storage/storageAccounts', '$($script:StorageName)')]"
    $template = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        parameters = @{ adminPassword = @{ type = 'secureString' } }
        resources = @(
            @{
                type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2023-01-01'
                name = $script:StorageName; location = $location; kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }
                properties = @{
                    allowSharedKeyAccess = $false; allowBlobPublicAccess = $false; defaultToOAuthAuthentication = $true
                    supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'
                }
            },
            @{
                type = 'Microsoft.Authorization/roleAssignments'; apiVersion = '2022-04-01'
                name = "[guid(resourceGroup().id, '$($script:StorageName)', '$ObjectId')]"
                scope = $storageId; dependsOn = @($storageId)
                properties = @{
                    principalId = $ObjectId; principalType = 'User'
                    roleDefinitionId = "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')]"
                }
            },
            @{
                type = 'Microsoft.Network/virtualNetworks'; apiVersion = '2024-05-01'; name = $vnet; location = $location
                properties = @{
                    addressSpace = @{ addressPrefixes = @('10.77.0.0/16') }
                    subnets = @(@{ name = 'validation'; properties = @{ addressPrefix = '10.77.0.0/24'; defaultOutboundAccess = $false } })
                }
            },
            @{
                type = 'Microsoft.Network/publicIPAddresses'; apiVersion = '2024-05-01'; name = $ip; location = $location
                sku = @{ name = 'Standard' }; properties = @{ publicIPAllocationMethod = 'Static' }
            },
            @{
                type = 'Microsoft.Network/networkSecurityGroups'; apiVersion = '2024-05-01'; name = $nsg; location = $location
                properties = @{ securityRules = @() }
            },
            @{
                type = 'Microsoft.Network/networkInterfaces'; apiVersion = '2024-05-01'; name = $nic; location = $location
                dependsOn = @("[resourceId('Microsoft.Network/virtualNetworks', '$vnet')]",
                    "[resourceId('Microsoft.Network/publicIPAddresses', '$ip')]", "[resourceId('Microsoft.Network/networkSecurityGroups', '$nsg')]")
                properties = @{
                    networkSecurityGroup = @{ id = "[resourceId('Microsoft.Network/networkSecurityGroups', '$nsg')]" }
                    ipConfigurations = @(@{
                        name = 'primary'; properties = @{
                            privateIPAllocationMethod = 'Dynamic'
                            subnet = @{ id = "[resourceId('Microsoft.Network/virtualNetworks/subnets', '$vnet', 'validation')]" }
                            publicIPAddress = @{ id = "[resourceId('Microsoft.Network/publicIPAddresses', '$ip')]" }
                        }
                    })
                }
            },
            @{
                type = 'Microsoft.Compute/virtualMachines'; apiVersion = '2024-07-01'; name = $script:VmName; location = $location
                dependsOn = @("[resourceId('Microsoft.Network/networkInterfaces', '$nic')]")
                properties = @{
                    hardwareProfile = @{ vmSize = $VmSize }
                    osProfile = @{
                        computerName = $script:VmName; adminUsername = 'rcadmin'; adminPassword = "[parameters('adminPassword')]"
                        linuxConfiguration = @{ disablePasswordAuthentication = $false; provisionVMAgent = $true }
                    }
                    storageProfile = @{
                        imageReference = @{ publisher = 'Canonical'; offer = '0001-com-ubuntu-server-jammy'; sku = '22_04-lts-gen2'; version = 'latest' }
                        osDisk = @{ createOption = 'FromImage'; caching = 'ReadWrite'; managedDisk = @{ storageAccountType = 'Premium_LRS' } }
                    }
                    networkProfile = @{ networkInterfaces = @(@{ id = "[resourceId('Microsoft.Network/networkInterfaces', '$nic')]" }) }
                    securityProfile = @{ securityType = 'Standard' }
                }
            }
        )
    }
    $path = Join-Path $script:PrivateDirectory 'infrastructure.json'
    $parameters = Join-Path $script:PrivateDirectory 'infrastructure.parameters.json'
    $password = "Rc!$([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)))a9"
    $script:Secrets.Add($password)
    Write-JsonFile $path $template
    Write-JsonFile $parameters @{ adminPassword = @{ value = $password } }
    Write-Step "Deploying storage, RBAC, private subnet, explicit outbound IP, and Ubuntu 22.04 ($VmSize) together. No inbound ports."
    try {
        $id = Invoke-Az @('deployment', 'group', 'create', '-g', $script:ResourceGroup, '-n', 'action-validation-infrastructure',
            '--template-file', $path, '--parameters', "@$parameters", '--query', 'properties.correlationId') `
            'deploying the Linux VM and test infrastructure' -Output tsv -TimeoutSeconds 2400
        Write-Step "Infrastructure deployment correlation ID: $id" Magenta
    }
    finally { Remove-Item -LiteralPath $parameters -Force }
    $null = Invoke-Az @('storage', 'container', 'create', '--account-name', $script:StorageName,
        '--name', 'validation', '--public-access', 'off', '--auth-mode', 'login') `
        'creating the private validation container' -Output none -RetryStorageAuthorization
}

function Save-GuestResults {
    param([hashtable] $Hashes)
    $reportName = "guest-results-$([guid]::NewGuid().ToString('N')).json"
    $logsName = "diagnostics-$([guid]::NewGuid().ToString('N')).tar.gz"
    Invoke-CustomScript collect @{
        hashes = $Hashes; reportUri = (New-BlobSas $reportName 'cw'); uploadUri = (New-BlobSas $logsName 'cw')
    }
    $reportPath = Join-Path $script:OutputDirectory 'guest-results.json'
    Receive-Blob $reportName $reportPath
    Receive-Blob $logsName (Join-Path $script:OutputDirectory 'diagnostics.tar.gz')
    $report = ConvertFrom-Json ([IO.File]::ReadAllText($reportPath)) -AsHashtable
    foreach ($result in $report.results) {
        $script:Results.Add($result)
        $color = if ($result.State -eq 'Passed') { [ConsoleColor]::Green } elseif ($result.State -eq 'Skipped') { [ConsoleColor]::Yellow } else { [ConsoleColor]::Red }
        Write-Step "$($result.State.ToUpperInvariant()) $($result.Name)" $color
        if ($result['Error']) { Write-Step $result.Error $color }
    }
    foreach ($package in $report.coverage.Keys) {
        Write-Step "Coverage $package`: $($report.coverage[$package])"
    }
}

function Start-RunCommandValidation {
    $script:Secrets = [Collections.Generic.List[string]]::new()
    $script:Results = [Collections.Generic.List[hashtable]]::new()
    $script:SubscriptionId = ''
    $repo = Split-Path -Parent $PSScriptRoot
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $script:OutputDirectory = Join-Path $repo "bin\functional-validation\$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $script:PrivateDirectory = Join-Path ([IO.Path]::GetTempPath()) "action-runcommand-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $script:OutputDirectory, $script:PrivateDirectory
    $instance = $null; $lock = $null; $ownsGroup = $false; $failure = $null; $installed = $false; $collected = $false
    try {
        foreach ($tool in @('go', 'az')) { $null = Get-Command $tool -ErrorAction Stop }
        $instance = Enter-ValidationInstance
        Build-RunCommand $repo
        $account = Get-LoggedInAzureAccount
        $script:SubscriptionId = $account.id
        $owner = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes("$($account.user.name)|$([Environment]::MachineName)"))).Substring(0, 12).ToLowerInvariant()
        $script:ResourceGroup = "rg-action-runcommand-local-validation-$owner"
        $script:VmName = 'action-runcommand-validation'
        Write-Step "Validation target: subscriptionId=$($account.id) ($($account.name)); resourceGroup=$($script:ResourceGroup); vmName=$($script:VmName); region=$Region." Magenta
        Write-Step 'Creates billable resources; any previous group owned by this harness will be deleted.' Yellow
        $lockPath = Join-Path ([IO.Path]::GetTempPath()) "$($account.id)-$($script:ResourceGroup).lock"
        $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        if ((Invoke-Az @('group', 'exists', '--name', $script:ResourceGroup) 'checking previous resources' -Output tsv) -eq 'true') {
            $previous = Invoke-Az @('group', 'show', '--name', $script:ResourceGroup) 'checking resource ownership'
            if (-not $previous['tags'] -or $previous.tags['ActionRunCommandValidationOwner'] -ne $owner) {
                throw 'Refusing to delete a resource group without this harness ownership tag.'
            }
            Remove-TestResourceGroup
        }
        $ownsGroup = $true
        $null = Invoke-Az @('group', 'create', '--name', $script:ResourceGroup, '--location', $Region,
            '--tags', "ActionRunCommandValidationOwner=$owner", 'Purpose=ActionRunCommandLocalValidation') 'creating the test resource group'
        New-TestInfrastructure $owner $account.userObjectId
        Write-Step 'Running action RunCommand once to install the released extension.'
        $bootstrap = Invoke-ActionRunCommand bootstrap "ip addr`n"
        Assert-Contains $bootstrap 'inet'
        $hashes = @{}
        $script:BinaryUris = @()
        foreach ($name in @('run-command-extension', 'run-command-shim', 'go-tests.zip')) {
            $path = Join-Path $script:OutputDirectory $name
            $hashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Send-Blob $path $name
            $script:BinaryUris += New-BlobSas $name
        }
        $guestPath = Join-Path $script:OutputDirectory 'Invoke-RunCommandGuest.py'
        $guestSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Invoke-RunCommandGuest.py')) -replace "`r", ''
        [IO.File]::WriteAllText($guestPath, $guestSource, [Text.UTF8Encoding]::new($false))
        Send-Blob $guestPath 'Invoke-RunCommandGuest.py'
        $script:GuestScriptUri = New-BlobSas 'Invoke-RunCommandGuest.py'
        $installed = $true
        Invoke-CustomScript install @{ hashes = $hashes; tests = $Test }

        Invoke-TestCase action-basics-and-parameters {
            $output = Invoke-ActionRunCommand basics @'
#!/bin/sh
set -eu
printf 'ACTION-CONTEXT uid=%s cwd=%s first=<%s> second=<%s>\n' "$(id -u)" "$PWD" "${1-}" "${2-}"
test "$(id -u)" = 0
case "$PWD" in /var/lib/waagent/run-command/download/*) ;; *) exit 31 ;; esac
test "$1" = 'hello world'
test "$2" = 'literal-$dollar;quoted'
printf 'ACTION-ROOT-PARAMETERS-CWD-PASS\n'
printf 'ACTION-STDERR-PASS\n' >&2
printf 'ACTION-UTF8-\303\251-PASS\n'
# RunShellScript embeds parameter values in a shell preamble without quoting them.
'@ @("first='hello world'", "second='literal-`$dollar;quoted'")
            Assert-Contains $output 'ACTION-ROOT-PARAMETERS-CWD-PASS'
            Assert-Contains $output 'ACTION-STDERR-PASS'
            Assert-Contains $output "ACTION-UTF8-$([char]0xe9)-PASS"
        }
        Invoke-TestCase action-nonzero-exit {
            $output = Invoke-ActionRunCommand nonzero "printf 'ACTION-BEFORE-EXIT-23\n'; printf 'ACTION-ERROR-23\n' >&2; exit 23`n"
            # Action RunCommand deliberately reports success even if the user command fails.
            Assert-Contains $output 'ACTION-BEFORE-EXIT-23'
            Assert-Contains $output 'ACTION-ERROR-23'
        }
        Invoke-TestCase action-recovery-and-output-tail {
            $output = Invoke-ActionRunCommand tail @'
#!/bin/sh
set -eu
printf 'OUT-PREFIX-MUST-BE-TRUNCATED\n'
head -c 6000 /dev/zero | tr '\000' x
printf '\nACTION-OUT-TAIL-PASS\n'
printf 'ERR-PREFIX-MUST-BE-TRUNCATED\n' >&2
head -c 6000 /dev/zero | tr '\000' y >&2
printf '\nACTION-ERR-TAIL-PASS\n' >&2
'@
            Assert-Contains $output 'ACTION-OUT-TAIL-PASS'
            Assert-Contains $output 'ACTION-ERR-TAIL-PASS'
            if ($output.Contains('PREFIX-MUST-BE-TRUNCATED')) { throw 'Output was not tailed to the extension limit.' }
        }
        Invoke-TestCase action-empty-output {
            $output = Invoke-ActionRunCommand empty "true`n"
            if ($output -match 'ACTION-(OUT|ERR)-TAIL-PASS') { throw 'Previous execution output leaked into the empty-output result.' }
        }
        Save-GuestResults $hashes
        $collected = $true
        if (@($script:Results | Where-Object { $_.State -eq 'Failed' }).Count) { throw 'Action RunCommand validation has failing tests; see results and diagnostics.' }
        $passed = @($script:Results | Where-Object { $_.State -eq 'Passed' }).Count
        $skipped = @($script:Results | Where-Object { $_.State -eq 'Skipped' }).Count
        Write-Step "All $passed enabled tests passed ($skipped explicitly skipped)." Green
    }
    catch {
        $failure = $_
        Write-Step (Protect-Text $_.Exception.Message) Red
        if ($installed -and -not $collected) {
            try { Save-GuestResults $hashes }
            catch { Write-Warning "Diagnostic collection failed: $(Protect-Text $_.Exception.Message)" }
        }
    }
    finally {
        if ($ownsGroup) {
            if ($KeepResources) { Write-Step "Keeping $($script:ResourceGroup); charges continue. The next run deletes it." Yellow }
            else {
                try { Remove-TestResourceGroup }
                catch {
                    Write-Step "CLEANUP FAILED: $(Protect-Text $_.Exception.Message). Delete $($script:ResourceGroup) manually." Red
                    if (-not $failure) { $failure = $_ }
                }
            }
        }
        if ($lock) { $lock.Dispose() }
        try {
            Write-JsonFile (Join-Path $script:OutputDirectory 'results.json') @($script:Results.ToArray())
            Write-Step "Results, responses, built binaries, and diagnostics: $($script:OutputDirectory)"
            Remove-Item -LiteralPath $script:PrivateDirectory -Recurse -Force
            $script:Secrets.Clear()
        }
        finally { if ($instance) { $instance.Dispose() } }
    }
    if ($failure) { throw $failure }
}

if ($MyInvocation.InvocationName -ne '.') { Start-RunCommandValidation }
