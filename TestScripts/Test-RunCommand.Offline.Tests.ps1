#requires -Version 7.3
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = $null
$tokens = $null
$harness = Join-Path $PSScriptRoot 'Test-RunCommand.ps1'
$null = [Management.Automation.Language.Parser]::ParseFile($harness, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
. $harness

$script:Secrets = [Collections.Generic.List[string]]::new()
$script:PrivateDirectory = Join-Path ([IO.Path]::GetTempPath()) "action-offline-$([guid]::NewGuid().ToString('N'))"
$script:OutputDirectory = $script:PrivateDirectory
$script:ResourceGroup = 'offline-group'
$script:VmName = 'offline-vm'
$null = New-Item -ItemType Directory $script:PrivateDirectory
$passed = 0
try {
    $result = Invoke-Native pwsh @('-NoProfile', '-Command', 'Write-Output ''quote "$value; spaces''') 'testing native argument transport'
    if ($result.StdOut.Trim() -cne 'quote "$value; spaces') { throw 'Native argument quoting changed.' }
    $passed++
    $result = Invoke-Native pwsh @('-NoProfile', '-Command', 'exit 7') 'testing native failures' -AllowFailure
    if ($result.ExitCode -ne 7) { throw 'Native exit code was lost.' }
    $passed++
    $script:Secrets.Add('test-secret')
    if ((Protect-Text 'test-secret https://example.com/a?sig=signature&sp=r') -match 'test-secret|signature') {
        throw 'Secret redaction failed.'
    }
    $passed++

    function Invoke-Az {
        param([string[]] $Arguments, [string] $Activity, [int] $TimeoutSeconds)
        if ($Arguments[0..2] -join ' ' -cne 'vm run-command invoke') { throw 'Managed RunCommand API was used.' }
        if ('--command-id' -notin $Arguments -or 'RunShellScript' -notin $Arguments) { throw 'Action command ID missing.' }
        if ($TimeoutSeconds -ne 600) { throw 'Action deadline changed.' }
        $script:CapturedArguments = $Arguments
        return $script:FakeResponse
    }
    $script:FakeResponse = @{ value = @(@{ code = 'ProvisioningState/succeeded'; message = "[stdout]`r`nexpected" }) }
    $output = Invoke-ActionRunCommand offline "printf expected`n"
    if ($output -cne "[stdout]`nexpected") { throw 'Action output normalization failed.' }
    if (Test-Path (Join-Path $script:PrivateDirectory 'offline.sh')) { throw 'Private script was not cleaned up.' }
    $passed++
    $parameters = @("first='hello world'", "second='literal-`$dollar;quoted'")
    $null = Invoke-ActionRunCommand offline 'true' $parameters
    foreach ($parameter in $parameters) {
        if ($parameter -cnotin $script:CapturedArguments) { throw 'Shell-quoted parameter value changed in transit.' }
    }
    $passed++
    # Exercise the installed CLI, not a stand-in executable.
    $result = Invoke-Native az @('version', '--query', "'hello world'", '--output', 'tsv') `
        'testing literal single quotes through the installed Azure CLI'
    if ($result.StdOut.Trim() -cne 'hello world') { throw 'Azure CLI wrapper removed literal shell quotes.' }
    $passed++
    $expected = [string][char]0xe9
    $result = Invoke-Native az @('version', '--query', "'$expected'", '--output', 'tsv') `
        'testing UTF-8 output through the actual Azure CLI launcher'
    if ($result.StdOut.Trim() -cne $expected) { throw 'Azure CLI Unicode output was corrupted.' }
    $passed++
    foreach ($response in @(
        @{ value = @() },
        @{ value = @(@{ code = 'ProvisioningState/failed'; message = 'failure' }) }
    )) {
        $script:FakeResponse = $response
        $failed = $false
        try { $null = Invoke-ActionRunCommand offline 'true' }
        catch { $failed = $true }
        if (-not $failed) { throw 'Invalid action response was accepted.' }
        $passed++
    }
    Write-Host "All $passed offline PowerShell checks passed."
}
finally { Remove-Item -LiteralPath $script:PrivateDirectory -Recurse -Force }
