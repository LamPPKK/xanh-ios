import tempfile
import unittest
from pathlib import Path

from Tools.verify_engine_locks import EXPECTED_LOCKS, verify_engine_locks


class VerifyEngineLocksTests(unittest.TestCase):
    def make_fixture(self) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for filename, values in EXPECTED_LOCKS.items():
            (root / filename).write_text(
                "".join(f"{key}={value}\n" for key, value in values.items()),
                encoding="utf-8",
            )
        source = root / "Sources" / "Browser" / "XanhWebView.swift"
        source.parent.mkdir(parents=True)
        source.write_text(
            """
contractVersion: "0.1.0-alpha.1"
adapter: "xanh-webview/apple"
backend: "WKWebView"
backendOwner: "Apple system WebKit"
fallback: "Apple system WebKit"
""",
            encoding="utf-8",
        )
        return root

    def test_accepts_pinned_repositories_and_truthful_adapter(self):
        self.assertEqual(verify_engine_locks(self.make_fixture()), [])

    def test_rejects_revision_and_adapter_contract_drift(self):
        root = self.make_fixture()
        (root / "XANH_WEBKIT.lock").write_text(
            "format=1\n"
            "repository=https://github.com/LamPPKK/xanh-webkit\n"
            "revision=0000000000000000000000000000000000000000\n",
            encoding="utf-8",
        )
        source = root / "Sources" / "Browser" / "XanhWebView.swift"
        source.write_text(
            source.read_text(encoding="utf-8").replace(
                'contractVersion: "0.1.0-alpha.1"',
                'contractVersion: "0.2.0"',
            ),
            encoding="utf-8",
        )

        errors = verify_engine_locks(root)

        self.assertTrue(any("revision must be" in error for error in errors))
        self.assertTrue(any("contract version" in error for error in errors))
        self.assertTrue(any("api_version does not match" in error for error in errors))

    def test_rejects_duplicate_and_unknown_lock_keys(self):
        root = self.make_fixture()
        lock = root / "XANH_WEBVIEW.lock"
        lock.write_text(
            lock.read_text(encoding="utf-8")
            + "api_version=0.1.0-alpha.1\nunknown=value\n",
            encoding="utf-8",
        )

        errors = verify_engine_locks(root)

        self.assertTrue(any("duplicate key api_version" in error for error in errors))
        self.assertTrue(any("unsupported keys: unknown" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
