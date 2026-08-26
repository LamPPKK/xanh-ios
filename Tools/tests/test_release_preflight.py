import base64
import tempfile
import unittest
import uuid
from pathlib import Path

from Tools.release_preflight import validate_environment


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.project = Path(self.directory.name) / "project.yml"
        self.project.write_text(
            "PRODUCT_BUNDLE_IDENTIFIER: io.github.lamppkk.xanhbrowser.ios\nMARKETING_VERSION: 0.1.0\n"
        )
        self.environment = {
            "CLOUDKIT_SCHEMA_PROMOTED": "true",
            "APPLE_TEAM_ID": "A1B2C3D4E5",
            "APP_STORE_CONNECT_KEY_ID": "F6G7H8J9K0",
            "APP_STORE_CONNECT_ISSUER_ID": str(uuid.uuid4()),
            "APP_STORE_CONNECT_PRIVATE_KEY": (
                "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----"
            ),
            "BLOCKER_PUBLIC_KEY_BASE64": base64.b64encode(bytes(32)).decode(),
        }

    def tearDown(self):
        self.directory.cleanup()

    def test_accepts_complete_release_environment(self):
        self.assertEqual(validate_environment(self.environment, self.project), [])

    def test_reports_all_missing_release_inputs_without_values(self):
        errors = validate_environment({}, self.project)
        self.assertEqual(len(errors), 6)
        self.assertTrue(any("CLOUDKIT_SCHEMA_PROMOTED" in error for error in errors))
        self.assertTrue(any("APP_STORE_CONNECT_PRIVATE_KEY" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
