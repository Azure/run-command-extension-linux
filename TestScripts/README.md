# Local action RunCommand validation

Run from Windows in **PowerShell 7.3 or later**, with Go and Azure CLI installed:

```powershell
az login
.\TestScripts\Test-RunCommand.ps1
.\TestScripts\Test-RunCommand.ps1 -Region eastus2euap -KeepResources
```

The default subscription is the existing Azure CLI default; the harness does not
sign in or change subscriptions. The defaults are `CentralUSEUAP`, an x64
`Standard_D2s_v5` VM, and Ubuntu 22.04. The signed-in user needs permission to
provision Compute, Network, Storage, and deployments and assign Storage Blob
Data Contributor. Regional quota and resource providers must be available.

**Creates billable Azure resources.** A predictable resource group,
`rg-action-runcommand-local-validation-<user-and-machine-hash>`, is reserved for
this harness. The ownership tag must match before an old group can be deleted.
Every invocation deletes a previous owned group and creates a fresh VM. The
default cleans up on both success and failure; `-KeepResources` retains resources
for debugging, including on failure. Charges continue until deletion. The next
invocation still deletes retained resources. Cleanup failures are reported and
fail the run; forced termination can prevent cleanup.

A startup mutex and held registration file coordinate invocations of this exact
script. A new run terminates the previous registered PowerShell host and its
children after checking its PID, start time, and script path. This can terminate
an interactive host running the previous invocation. The current host and its
ancestors are protected. Completed registrations do not cause termination.
Action and managed harnesses use different groups and registrations.

## Deployment and bit replacement

1. Cross-compile the local Linux/amd64 extension with the manifest version and
   the Makefile's `netgo,osusergo`/CGO-disabled settings. Also compile covered
   Linux Go test executables for all five first-party packages. Go dependencies
   come from the existing vendor directory; no Go installation on the VM is needed.
   Copied UTF-8/LF checksum fixtures are normalized back to LF after Windows
   `autocrlf` checkout; BOM bytes and intentional DOS/UTF-16 fixtures are preserved.
2. Deploy storage, storage-scoped RBAC, networking, and the VM together. The
   subnet has `defaultOutboundAccess: false`; a Standard public IP provides
   explicit outbound access. No inbound NSG ports are opened.
3. Invoke **action** RunCommand (`az vm run-command invoke`, `RunShellScript`)
   once with `ip addr` to install the released action extension.
4. Upload the local binary, normalized local shim, guest helper, and compiled
   tests to private storage. CustomScript downloads them using read-only,
   HTTPS-only, four-hour user-delegation SAS URLs in protected settings.
5. CustomScript discovers the active action handler using `config/HandlerState`,
   with the same exact-version XML/single-directory fallbacks as the managed
   harness. It rejects ambiguity, validates downloaded SHA-256 hashes, and
   atomically replaces the binary and shim with root-owned executable files.
   Installed hashes are checked before guest tests and after action tests.
6. Run batched short guest tests in that same CustomScript deployment, then
   sequential action API tests. Action RunCommand permits only one operation
   at a time; independent assertions are combined within each script.
7. A final CustomScript deployment uploads results, Go coverage profiles,
   handler test output, extension statuses, and VM agent/handler logs. Downloads
   use Entra authentication. Print the summary and clean up.

Storage disables anonymous blob access **and shared-key authentication** and
defaults to OAuth. Local storage operations use `--auth-mode login`, with bounded
authorization retries for RBAC propagation. The user object ID is read from the
existing ARM JWT's `oid` claim and checked against its tenant; no Graph access is
needed. Passwords and SAS URLs are redacted, temporary configurations are removed
locally and from storage, and resources stay pinned to the chosen subscription.
This is authenticated public HTTPS storage, not a private-endpoint deployment.
The native launcher uses UTF-8 for PowerShell, Python CLI output, and redirected
stdout/stderr so non-ASCII RunCommand output survives Windows code-page settings.
For the Windows MSI Azure CLI, it runs the wrapper's bundled Python and
`azure.cli` module with the same isolated/no-bytecode flags, plus `-X utf8`.
This is needed because `az.cmd` uses isolated Python, which ignores
`PYTHONIOENCODING`. It also avoids the batch wrapper's embedded-quote handling.
Other native `az.exe` installations use the usual executable; non-MSI command
wrappers without the adjacent bundled Python are explicitly rejected.

## Coverage and time bounds

The action API tests cover root execution, working directory, arguments with
spaces and literal shell metacharacters, UTF-8, stdout/stderr, nonzero script exits,
subsequent recovery, output tailing, and empty-output isolation. Nonzero user
script exits intentionally still report extension success in this product.
Parameter values are explicitly shell-quoted because RunShellScript embeds them
directly into its generated `export`/`set --` preamble. Quotes are part of the
parameter value supplied to the API, not just PowerShell argument quoting.
The tests use literal single quotes to preserve both spaces and dollar/semicolon
characters in the generated shell preamble.

Guest process-level tests execute the **same local extension binary** against
fixture HandlerEnvironment/settings files. A private mount namespace binds a
disposable agent directory, preventing lifecycle tests from deleting actual
agent-managed data. Tests include:

- Install/update/disable/uninstall and status shape.
- Public/protected commands and CMS-encrypted protected settings.
- Base64/gzip scripts, UTF-8 BOM/CRLF, UTF-16 LE/BE, and conversion opt-out.
- The exact 256 KiB encoded-script boundary and rejection above it.
- Single script downloads using loopback HTTP, protected/public settings, and
  unchanged bytes when conversion is disabled.
- Invalid configuration, duplicate/conflicting settings, malformed encoding.
- Sequence-number fallback, idempotency, PID-file cleanup, interrupted-status
  recovery, exact 4,096-byte tails for **each** stream, full-output file sizes,
  and script/output file permissions.

Existing Go tests supplement functional coverage with schema, downloads,
retry scheduling, preprocessing, sequences, status/log tailing, PID tracking,
and telemetry. They run as unprivileged UID/GID 65534 so permission-denial tests
remain meaningful; action/handler process tests run as root.
Per-package statement coverage and individual test results are
saved; this is unit-test coverage, not instrumented action API coverage.
The three legacy download tests requiring external endpoints/shared-key
credentials are explicitly skipped. Download retries are exercised through the
existing fake-sleep tests, not minutes-long real failing downloads.

Managed resources, multiple simultaneous RunCommands, immediate RunCommand,
extra artifacts, RunAs, append output blobs, and long timeout/reboot scenarios
are not deployed or tested as action features.

Each action API invocation has a ten-minute deadline. Go suites have 90-second
test deadlines, guest process cases have 15-second deadlines, the batched handler
suite has a three-minute deadline, and CustomScript has a ten-minute deadline.
Provisioning and resource deletion have 40-minute bounds and native operations
print minute heartbeats. Timeouts fail explicitly rather than allowing another
action operation to overlap an unfinished one.

## Results and developing the harness

Outputs persist under `bin\functional-validation\<timestamp>-<suffix>` (ignored
by Git): local bits, action responses, `results.json`, `guest-results.json`, and
`diagnostics.tar.gz`. The latter includes Go coverage profiles and captured
test output. An LF-normalized snapshot of the guest helper is saved beside the
bits; its SHA-256 is recorded in the guest report to identify the executed test
revision. No product source is changed.

Temporarily select groups while developing:

```powershell
.\TestScripts\Test-RunCommand.ps1 -Test 'handler-*'
.\TestScripts\Test-RunCommand.ps1 -Test 'go-*', 'action-*'
```

The build, infrastructure, bootstrap, replacement, hash checks, and cleanup still
run. Excluded tests are explicitly recorded as skipped. Use the default `-Test '*'`
for final validation.

Offline checks require no Azure resources:

```powershell
.\TestScripts\Test-RunCommand.Offline.Tests.ps1
python -m unittest discover -s .\TestScripts -p Test_RunCommandGuest.py -v
```
