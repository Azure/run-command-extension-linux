"""Offline regression tests for the actual CustomScript helper."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "guest", Path(__file__).with_name("Invoke-RunCommandGuest.py"))
guest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guest)


class GuestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.agent = self.root / "agent"
        self.agent.mkdir()
        self.marker = self.root / "marker.json"
        patch = mock.patch.multiple(guest, AGENT=self.agent, MARKER=self.marker)
        patch.start()
        self.addCleanup(patch.stop)

    def directory(self, version="1.0.0", state="Enabled"):
        directory = self.agent / (guest.HANDLERS[0] + "-" + version)
        (directory / "bin").mkdir(parents=True)
        (directory / "config").mkdir()
        if state is not None:
            (directory / "config/HandlerState").write_text(state)
        for name in ("run-command-extension", "run-command-shim"):
            (directory / "bin" / name).write_bytes(b"local bits")
        return directory

    def config(self, directory):
        hashes = {name: guest.digest(directory / "bin" / name)
                  for name in ("run-command-extension", "run-command-shim")}
        hashes["go-tests.zip"] = "fixture"
        self.marker.write_text(json.dumps({"directory": str(directory), "hashes": hashes}))
        return {"hashes": hashes}

    def test_enabled_handler_beats_retained_version_and_stale_xml(self):
        self.directory("1.0.0", "Installed")
        active = self.directory("1.0.1")
        (self.agent / "ExtensionsConfig.xml").write_text(
            '<Extensions><Plugin name="' + guest.HANDLERS[0] + '" version="1.0.0"/></Extensions>')
        self.assertEqual(guest.active_directory(), active)

    def test_multiple_enabled_handlers_rejected(self):
        self.directory("1.0.0")
        self.directory("1.0.1")
        with self.assertRaisesRegex(RuntimeError, "Multiple enabled"):
            guest.active_directory()

    def test_inactive_handler_not_selected(self):
        self.directory(state="Installed")
        with self.assertRaisesRegex(RuntimeError, "Cannot identify"):
            guest.active_directory()

    def test_missing_binary_rejected(self):
        directory = self.directory()
        (directory / "bin/run-command-extension").unlink()
        with self.assertRaisesRegex(RuntimeError, "no binary"):
            guest.active_directory()

    def test_single_directory_without_state_supported(self):
        directory = self.directory(state=None)
        self.assertEqual(guest.active_directory(), directory)

    def test_namespaced_xml_selects_exact_installed_version(self):
        self.directory("1.0.0", None)
        active = self.directory("1.0.1", None)
        (self.agent / "ExtensionsConfig.xml").write_text(
            '<Extensions xmlns="urn:test"><Plugin name="' + guest.HANDLERS[0]
            + '" version="1.0.1"/></Extensions>')
        self.assertEqual(guest.active_directory(), active)

    def test_empty_inventory_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "none"):
            guest.active_directory()

    def test_digest_streams_large_binary(self):
        path = self.root / "large"
        content = b"test" * 500000
        path.write_bytes(content)
        self.assertEqual(guest.digest(path), hashlib.sha256(content).hexdigest())

    def test_changed_binary_rejected(self):
        directory = self.directory()
        config = self.config(directory)
        (directory / "bin/run-command-extension").write_bytes(b"changed bits")
        with self.assertRaisesRegex(RuntimeError, "bits changed"):
            guest.verify(config)

    def test_changed_active_version_rejected(self):
        directory = self.directory()
        config = self.config(directory)
        (directory / "config/HandlerState").write_text("Installed")
        self.directory("1.0.1")
        with self.assertRaisesRegex(RuntimeError, "marker changed"):
            guest.verify(config)

    def test_record_preserves_failure_and_continues(self):
        report = {"results": []}
        guest.record(report, "failing", lambda: guest.check(False, "test failure"), ["*"])
        guest.record(report, "passing", lambda: None, ["*"])
        self.assertEqual([value["State"] for value in report["results"]], ["Failed", "Passed"])
        self.assertEqual(report["results"][0]["Error"], "test failure")

    def test_selector_records_skip_without_executing(self):
        report = {"results": []}
        body = mock.Mock()
        guest.record(report, "handler-test", body, ["action-*"])
        body.assert_not_called()
        self.assertEqual(report["results"][0]["State"], "Skipped")

    def test_collect_reports_missing_results_as_failure(self):
        report = self.root / "report.json"
        with mock.patch.multiple(guest, REPORT=report, DATA=self.agent / "data",
                                 LOG_DIRECTORY=self.root / "logs"):
            with mock.patch.object(guest, "verify"), mock.patch.object(guest.tarfile, "open"):
                with mock.patch.object(guest, "upload") as upload:
                    guest.collect({"reportUri": "report", "uploadUri": "logs"})
                    self.assertEqual(upload.call_count, 2)
        result = json.loads(report.read_text())
        self.assertEqual(result["results"][0]["State"], "Failed")
        self.assertEqual(result["results"][0]["Name"], "guest-harness-completion")

    def test_collect_uploads_diagnostics_even_if_hash_verification_fails(self):
        report = self.root / "report.json"
        report.write_text(json.dumps({"results": [], "coverage": {}}))
        with mock.patch.multiple(guest, REPORT=report, DATA=self.agent / "data",
                                 LOG_DIRECTORY=self.root / "logs"):
            with mock.patch.object(guest, "verify", side_effect=RuntimeError("changed bits")):
                with mock.patch.object(guest.tarfile, "open"), mock.patch.object(guest, "upload") as upload:
                    guest.collect({"reportUri": "report", "uploadUri": "logs"})
                    self.assertEqual(upload.call_count, 2)
        result = json.loads(report.read_text())["results"][0]
        self.assertEqual(result["Name"], "installed-local-bits")
        self.assertEqual(result["State"], "Failed")
        self.assertEqual(result["Error"], "changed bits")


if __name__ == "__main__":
    unittest.main()
