"""CustomScript-only installation, batched short tests, and diagnostic collection."""

import base64
import fnmatch
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

AGENT = Path("/var/lib/waagent")
HANDLERS = ("Microsoft.CPlat.Core.RunCommandLinux", "Microsoft.Compute.CPlat.Core.RunCommandLinux")
MARKER = Path("/var/lib/action-runcommand-local-validation.json")
REPORT = Path("/var/lib/action-runcommand-validation-results.json")
LOG_DIRECTORY = Path("/var/log/azure/run-command")
DATA = AGENT / "run-command"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def active_directory():
    directories = sorted(
        directory for handler in HANDLERS for directory in AGENT.glob(handler + "-*")
        if directory.is_dir()
    )
    states = {
        directory: (directory / "config/HandlerState").read_text().strip()
        if (directory / "config/HandlerState").is_file() else None
        for directory in directories
    }
    inventory = ", ".join(directory.name + " (state=" + str(states[directory]) + ")"
                          for directory in directories) or "none"

    def checked(directory):
        if states[directory] not in (None, "Enabled"):
            raise RuntimeError("Selected handler is not enabled: " + inventory)
        if not (directory / "bin/run-command-extension").is_file():
            raise RuntimeError("Selected handler has no binary: " + inventory)
        return directory

    enabled = [directory for directory in directories if states[directory] == "Enabled"]
    if len(enabled) > 1:
        raise RuntimeError("Multiple enabled action RunCommand handlers: " + inventory)
    if enabled:
        return checked(enabled[0])
    configurations = sorted(AGENT.glob("ExtensionsConfig*.xml"),
                            key=lambda path: path.stat().st_mtime, reverse=True)
    for path in configurations[:1]:
        references = {
            (element.attrib["name"], element.attrib["version"])
            for element in ET.parse(path).getroot().iter()
            if element.tag.rsplit("}", 1)[-1] == "Plugin"
            and element.attrib.get("name") in HANDLERS and "version" in element.attrib
        }
        if len(references) == 1:
            handler, version = references.pop()
            directory = AGENT / (handler + "-" + version)
            if directory not in directories:
                raise RuntimeError("Agent references missing handler " + str(directory) + ": " + inventory)
            return checked(directory)
        if references:
            raise RuntimeError("Ambiguous agent configuration: " + inventory)
    candidates = [directory for directory in directories if states[directory] is None]
    if len(candidates) != 1:
        raise RuntimeError("Cannot identify the active action RunCommand handler: " + inventory)
    return checked(candidates[0])


def verify(config):
    installed = json.loads(MARKER.read_text())
    directory = active_directory()
    if installed["directory"] != str(directory) or installed["hashes"] != config["hashes"]:
        raise RuntimeError("Active handler or installation marker changed after replacement")
    for name in ("run-command-extension", "run-command-shim"):
        destination = directory / "bin" / name
        if digest(destination) != config["hashes"][name]:
            raise RuntimeError("Installed local bits changed: " + name)
        if destination.stat().st_mode & 0o777 != 0o755 or destination.stat().st_uid != 0:
            raise RuntimeError("Installed bits have incorrect ownership or permissions: " + name)
    print("Verified local extension and shim hashes in " + str(directory), flush=True)
    return directory


def install(config):
    directory = active_directory()
    for name, expected in config["hashes"].items():
        if digest(Path(name)) != expected:
            raise RuntimeError("Downloaded checksum mismatch: " + name)
    for name in ("run-command-extension", "run-command-shim"):
        destination = directory / "bin" / name
        staged = destination.with_name(destination.name + ".validation-new")
        with Path(name).open("rb") as source, staged.open("wb") as target:
            shutil.copyfileobj(source, target)
            target.flush()
            os.fsync(target.fileno())
        os.chown(staged, 0, 0)
        staged.chmod(0o755)
        os.replace(staged, destination)
    MARKER.write_text(json.dumps({"directory": str(directory), "hashes": config["hashes"]}))
    MARKER.chmod(0o600)
    verify(config)


def record(report, name, body, selectors):
    if not any(fnmatch.fnmatchcase(name, selector) for selector in selectors):
        report["results"].append({"Name": name, "State": "Skipped", "Reason": "Excluded by -Test selector"})
        return
    started = time.monotonic()
    result = {"Name": name, "State": "Failed", "Error": None}
    try:
        body()
        result["State"] = "Passed"
    except (AssertionError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        result["Error"] = str(error)
    result["Seconds"] = round(time.monotonic() - started, 3)
    report["results"].append(result)
    print(result["State"].upper() + " " + name + (": " + result["Error"] if result["Error"] else ""), flush=True)


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def run_go_tests(root, report, selectors):
    # These legacy tests require external/shared-key storage, not action RunCommand.
    excluded = ("Test_blobDownload_fails_badCreds", "Test_blobDownload_fails_urlNotFound",
                "Test_blobDownload_actualBlob")
    for name in excluded:
        report["results"].append({"Name": "go-download/" + name, "State": "Skipped",
                                  "Reason": "External/shared-key storage dependency; not used by this harness"})
    root.chmod(0o755)
    for directory in sorted(root.iterdir()):
        if not directory.is_dir():
            continue
        executable = directory / "tests"
        executable.chmod(0o755)
        os.chown(directory, 65534, 65534)
        directory.chmod(0o755)
        name = "go-" + directory.name

        def body(directory=directory, executable=executable, name=name):
            environment = dict(os.environ, AZURE_STORAGE_ACCOUNT="", AZURE_STORAGE_ACCESS_KEY="")
            result = subprocess.run(
                [str(executable), "-test.v", "-test.timeout=90s",
                 "-test.skip=^(" + "|".join(excluded) + ")$",
                 "-test.coverprofile=" + str(directory / "coverage.out")],
                cwd=directory, env=environment, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, timeout=105, user=65534, group=65534,
            )
            (directory / "output.txt").write_text(result.stdout)
            coverage = re.search(r"coverage: ([0-9.]+% of statements)", result.stdout)
            if coverage:
                report["coverage"][directory.name] = coverage.group(1)
            for state, test_name in re.findall(r"--- (PASS|FAIL|SKIP): (\S+)", result.stdout):
                report["results"].append({"Name": name + "/" + test_name,
                                          "State": {"PASS": "Passed", "FAIL": "Failed", "SKIP": "Skipped"}[state]})
            check(result.returncode == 0, result.stdout)
            check(coverage is not None, "Test executable returned no coverage: " + name)
        record(report, name, body, selectors)


def handler_tests(directory, report, selectors):
    with tempfile.TemporaryDirectory(prefix="action-handler-fixture-") as temporary:
        root = Path(temporary)
        handler = root / "handler"
        (handler / "bin").mkdir(parents=True)
        for name in ("config", "status", "logs"):
            (handler / name).mkdir()
        shutil.copy2(directory / "bin/run-command-extension", handler / "bin/run-command-extension")
        binary = handler / "bin/run-command-extension"
        isolated_agent = root / "agent"
        isolated_agent.mkdir()
        subprocess.run(["mount", "--bind", str(isolated_agent), str(AGENT)], check=True, timeout=10)
        environment_file = handler / "HandlerEnvironment.json"
        environment_file.write_text(json.dumps([{
            "version": 1, "name": HANDLERS[0],
            "handlerEnvironment": {"configFolder": str(handler / "config"),
                                   "statusFolder": str(handler / "status"),
                                   "logFolder": str(handler / "logs")},
        }]))
        thumbprint = "validation"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(root / (thumbprint + ".prv")),
                        "-out", str(root / (thumbprint + ".crt")), "-days", "1",
                        "-subj", "/CN=action-validation"], check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE, timeout=30)
        sequence = 0

        def settings(public, protected=None):
            nonlocal sequence
            sequence += 1
            value = {"publicSettings": public}
            if protected is not None:
                encrypted = subprocess.run(
                    ["openssl", "cms", "-encrypt", "-outform", "DER", "-aes256",
                     str(root / (thumbprint + ".crt"))], input=json.dumps(protected).encode(),
                    check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
                ).stdout
                value.update(protectedSettings=base64.b64encode(encrypted).decode(),
                             protectedSettingsCertThumbprint=thumbprint)
            (handler / "config" / (str(sequence) + ".settings")).write_text(
                json.dumps({"runtimeSettings": [{"handlerSettings": value}]}))
            return sequence

        def invoke(operation, seq=None, fallback=False):
            env = dict(os.environ)
            env.pop("ConfigSequenceNumber", None)
            if not fallback:
                env["ConfigSequenceNumber"] = str(sequence if seq is None else seq)
            result = subprocess.run([str(binary), operation], cwd=handler, env=env,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=15)
            (handler / "logs" / (operation + "-" + str(sequence) + ".txt")).write_text(result.stdout)
            return result

        def status(seq=None):
            document = json.loads((handler / "status" / (str(sequence if seq is None else seq) + ".status")).read_text())
            check(len(document) == 1, "Incorrect status report shape")
            value = document[0]["status"]
            check(document[0]["version"] == 1 and document[0]["timestampUTC"].endswith("Z"),
                  "Incorrect status version or timestamp")
            check(value["formattedMessage"]["lang"] == "en", "Incorrect status language")
            return value

        def execution(public, protected=None, expected="", failure=None, command_error=False, fallback=False):
            settings(public, protected)
            result = invoke("enable", fallback=fallback)
            value = status()
            if failure:
                check(result.returncode == 3 and value["status"] == "error", result.stdout + str(value))
                check(failure in value["formattedMessage"]["message"], str(value))
            else:
                check(result.returncode == 0 and value["status"] == "success", result.stdout + str(value))
                check(expected in value["formattedMessage"]["message"], str(value))
                if command_error:
                    check("enable script failed" in result.stdout, result.stdout)
                else:
                    check("event=enabled" in result.stdout, "Command did not actually succeed: " + result.stdout)
            return value

        def lifecycle():
            settings({"commandToExecute": "true"})
            check(invoke("install").returncode == 0 and DATA.is_dir(), "Install did not create data directory")
            check(not (handler / "status" / (str(sequence) + ".status")).exists(), "Install unexpectedly reported status")
            for operation in ("update", "disable"):
                check(invoke(operation).returncode == 0, operation + " failed")
                check(status()["operation"] == operation.capitalize() and status()["status"] == "success",
                      operation + " status incorrect")
        record(report, "handler-lifecycle", lifecycle, selectors)

        record(report, "handler-public-command", lambda: execution(
            {"commandToExecute": "printf 'PUBLIC-OUT'; printf 'PUBLIC-ERR' >&2"}, expected="PUBLIC-OUT"), selectors)
        record(report, "handler-protected-command", lambda: execution(
            {}, {"commandToExecute": "printf 'PROTECTED-PASS'"}, expected="PROTECTED-PASS"), selectors)
        script = b"#!/bin/sh\nprintf 'ENCODED-PASS'\n"
        for name, content, protected, skip in (
            ("base64", script, False, False),
            ("gzip-protected", gzip.compress(script), True, False),
            ("utf8-bom-crlf", b"\xef\xbb\xbf" + script.replace(b"\n", b"\r\n"), False, False),
            ("utf16-le", b"\xff\xfe" + script.decode().encode("utf-16-le"), False, False),
            ("utf16-be", b"\xfe\xff" + script.decode().encode("utf-16-be"), False, False),
            ("skip-conversion", script, False, True),
        ):
            def encoded(content=content, protected=protected, skip=skip):
                value = {"script": base64.b64encode(content).decode()}
                execution({"skipDos2Unix": skip} if protected else dict(value, skipDos2Unix=skip),
                          value if protected else None, expected="ENCODED-PASS")
                downloaded = DATA / "download" / str(sequence) / "script.sh"
                expected = content if skip else script
                if content[:2] == b"\x1f\x8b":
                    expected = script
                check(downloaded.read_bytes() == expected, "Script decoding/conversion bytes differ")
                check(downloaded.stat().st_mode & 0o777 == 0o500, "Script permissions differ")
            record(report, "handler-script-" + name, encoded, selectors)

        for name, public, protected, error in (
            ("missing-command", {}, None, "'commandToExecute' is not specified"),
            ("unknown-setting", {"commandToExecute": "true", "runAsUser": "not-supported"}, None, "invalid public settings JSON"),
            ("wrong-type", {"commandToExecute": 42}, None, "invalid public settings JSON"),
            ("duplicate-command", {"commandToExecute": "true"}, {"commandToExecute": "true"}, "specified both"),
            ("duplicate-script", {"script": "dHJ1ZQ=="}, {"script": "dHJ1ZQ=="}, "specified both"),
            ("command-and-script", {"commandToExecute": "true", "script": "dHJ1ZQ=="}, None, "both specified"),
            ("partial-storage-credentials", {"commandToExecute": "true"}, {"storageAccountName": "validation"}, "both 'storageAccountName'"),
        ):
            record(report, "handler-invalid-" + name,
                   lambda public=public, protected=protected, error=error: execution(
                       public, protected, failure=error), selectors)
        def invalid_base64():
            execution({"script": "!"}, command_error=True)
            check(not (DATA / "download" / str(sequence) / "script.sh").exists(),
                  "Invalid base64 was written as an executable script")
        record(report, "handler-invalid-base64", invalid_base64, selectors)
        boundary = b"#!/bin/sh\nprintf 'SIZE-BOUNDARY-PASS'\n#".ljust(196608, b"a")
        record(report, "handler-script-size-boundary", lambda: execution(
            {"script": base64.b64encode(boundary).decode()}, expected="SIZE-BOUNDARY-PASS"), selectors)

        def size_limit():
            oversized = base64.b64encode(boundary + b"aaa").decode()
            check(len(oversized) == 256 * 1024 + 4, "Oversized fixture length is incorrect")
            execution({"script": oversized}, command_error=True)
            check(not (DATA / "download" / str(sequence) / "script.sh").exists(),
                  "Over-limit script was written instead of rejected")
        record(report, "handler-script-size-limit", size_limit, selectors)
        record(report, "handler-command-failure-contract", lambda: execution(
            {"commandToExecute": "printf 'EXIT-PASS'; exit 23"}, expected="EXIT-PASS", command_error=True), selectors)
        record(report, "handler-config-sequence-fallback", lambda: execution(
            {"commandToExecute": "printf 'FALLBACK-PASS'"}, expected="FALLBACK-PASS", fallback=True), selectors)

        class ScriptServer(BaseHTTPRequestHandler):
            def do_GET(self):
                content = b"\xef\xbb\xbf" + script.replace(b"\n", b"\r\n")
                self.send_response(200)
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)

            def log_message(self, format_string, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), ScriptServer)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            uri = "http://127.0.0.1:" + str(server.server_port) + "/downloaded.sh?fixture=1"
            for protected in (False, True):
                def downloaded(protected=protected):
                    value = {"commandToExecute": "./downloaded.sh", "fileUris": [uri]}
                    execution({} if protected else value, value if protected else None, expected="ENCODED-PASS")
                    check((DATA / "download" / str(sequence) / "downloaded.sh").read_bytes() == script,
                          "Downloaded script BOM/CRLF processing differs")
                record(report, "handler-download-" + ("protected" if protected else "public"), downloaded, selectors)

            def skip_download():
                execution({"commandToExecute": "printf 'SKIP-DOWNLOAD-PASS'", "fileUris": [uri],
                           "skipDos2Unix": True}, expected="SKIP-DOWNLOAD-PASS")
                check((DATA / "download" / str(sequence) / "downloaded.sh").read_bytes()
                      == b"\xef\xbb\xbf" + script.replace(b"\n", b"\r\n"),
                      "skipDos2Unix did not preserve downloaded bytes")
            record(report, "handler-download-skip-conversion", skip_download, selectors)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)

        def sequence_test():
            counter = root / "counter"
            seq = settings({"commandToExecute": "printf x >> " + str(counter)})
            check(invoke("enable", seq).returncode == 0, "Initial enable failed")
            check(invoke("enable", seq).returncode == 0, "Duplicate enable failed")
            check(invoke("enable", seq - 1).returncode == 0, "Older sequence failed")
            check(counter.read_text() == "x", "Duplicate/older sequence re-executed")
            check(not (handler / "pidstart").exists(), "PID tracking file was not removed")
        record(report, "handler-sequence-idempotency", sequence_test, selectors)

        def interrupted_status():
            execution({"commandToExecute": "true"})
            path = handler / "status" / (str(sequence) + ".status")
            value = json.loads(path.read_text())
            value[0]["status"]["status"] = "transitioning"
            path.write_text(json.dumps(value))
            check(invoke("enable").returncode == 0, "Interrupted duplicate enable failed")
            check(status()["status"] == "success"
                  and "Last script execution didn't finish." in status()["formattedMessage"]["message"],
                  "Interrupted status was not recovered")
        record(report, "handler-interrupted-status-recovery", interrupted_status, selectors)

        def tails():
            value = execution({"commandToExecute": "head -c 6000 /dev/zero | tr '\\000' x; "
                               "head -c 6000 /dev/zero | tr '\\000' y >&2"})
            message = value["formattedMessage"]["message"]
            check(message == "Enable succeeded: \n[stdout]\n" + "x" * 4096 + "\n[stderr]\n" + "y" * 4096,
                  "Status did not contain exactly 4096 bytes of each stream tail")
            for name in ("stdout", "stderr"):
                path = DATA / "download" / str(sequence) / name
                check(path.stat().st_size == 6000 and path.stat().st_mode & 0o777 == 0o600,
                      "Full output/permissions incorrect")
        record(report, "handler-exact-output-limits", tails, selectors)

        def uninstall():
            check(invoke("uninstall").returncode == 0 and not DATA.exists(), "Uninstall did not remove isolated data directory")
        record(report, "handler-uninstall", uninstall, selectors)


def batched_tests(config):
    report = {"results": [{"Name": "guest-harness-completion", "State": "Failed",
                          "Error": "Batched guest harness did not complete"}], "coverage": {},
              "guestScriptSha256": digest(Path(__file__).resolve())}
    REPORT.write_text(json.dumps(report))
    REPORT.chmod(0o600)
    selectors = config["tests"]
    directory = verify(config)
    with tempfile.TemporaryDirectory(prefix="action-go-tests-") as temporary:
        root = Path(temporary)
        with zipfile.ZipFile("go-tests.zip") as archive:
            archive.extractall(root)
        run_go_tests(root, report, selectors)
        # Save Go output and coverage before the temporary directory is removed.
        with tarfile.open(LOG_DIRECTORY / "go-tests.tar.gz", "w:gz") as archive:
            for path in root.rglob("*"):
                if path.is_file() and path.name != "tests":
                    archive.add(path, arcname=str(path.relative_to(root)))
    REPORT.write_text(json.dumps(report))
    # Product dataDir is fixed. Bind a disposable directory in a PRIVATE mount
    # namespace so lifecycle tests cannot touch the agent-managed execution data.
    with tempfile.TemporaryDirectory(prefix="action-data-") as temporary:
        child_config = Path(temporary) / "config.json"
        child_report = Path(temporary) / "report.json"
        child_config.write_text(json.dumps(dict(config, childReport=str(child_report))))
        process = subprocess.run(
            ["unshare", "--mount", "--propagation", "private", "python3", str(Path(__file__).resolve()),
             "handler-tests", str(child_config)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=180,
        )
        (LOG_DIRECTORY / "handler-tests.txt").write_text(process.stdout)
        print(process.stdout, flush=True)
        check(process.returncode == 0, "Isolated handler harness failed: " + process.stdout)
        report["results"].extend(json.loads(child_report.read_text())["results"])
    report["results"][0].update(State="Passed", Error=None)
    REPORT.write_text(json.dumps(report))
    REPORT.chmod(0o600)


def upload(uri, path, content_type):
    request = urllib.request.Request(uri, data=path.read_bytes(), method="PUT",
                                     headers={"x-ms-blob-type": "BlockBlob", "Content-Type": content_type})
    with urllib.request.urlopen(request, timeout=120) as response:
        check(response.status == 201, "Diagnostic upload returned HTTP " + str(response.status))


def collect(config):
    report = json.loads(REPORT.read_text()) if REPORT.exists() else {
        "results": [{"Name": "guest-harness-completion", "State": "Failed",
                     "Error": "Guest harness did not produce a results report"}], "coverage": {}}
    record(report, "installed-local-bits", lambda: verify(config), ["*"])
    REPORT.write_text(json.dumps(report))
    REPORT.chmod(0o600)
    archive_path = Path("/var/tmp/action-runcommand-validation-logs.tar.gz")
    paths = [LOG_DIRECTORY, Path("/var/log/waagent.log"), MARKER, REPORT]
    paths.extend(DATA.glob("download/*/script.sh"))
    paths.extend(DATA.glob("download/*/stdout"))
    paths.extend(DATA.glob("download/*/stderr"))
    for handler in HANDLERS:
        paths.extend(AGENT.glob(handler + "-*/status"))
    with tarfile.open(archive_path, "w:gz") as archive:
        for path in paths:
            if path.exists():
                archive.add(path, arcname=str(path).lstrip("/"))
    upload(config["uploadUri"], archive_path, "application/gzip")
    upload(config["reportUri"], REPORT, "application/json")
    print("Uploaded test results and RunCommand diagnostics", flush=True)


def main():
    action = sys.argv[1]
    config = json.loads(Path(sys.argv[2]).read_text())
    if action == "install":
        install(config)
        LOG_DIRECTORY.mkdir(parents=True, exist_ok=True)
        batched_tests(config)
    elif action == "handler-tests":
        report = {"results": [], "coverage": {}}
        handler_tests(verify(config), report, config["tests"])
        Path(config["childReport"]).write_text(json.dumps(report))
    elif action == "collect":
        collect(config)
    elif action == "verify":
        verify(config)
    else:
        raise ValueError("Unknown guest action: " + action)


if __name__ == "__main__":
    main()
