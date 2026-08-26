import base64
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from Tools.verify_ipa import REQUIRED_BLOCKER_MANIFEST_URL, verify_ipa


class VerifyIPATests(unittest.TestCase):
    release_key = bytes(range(32))

    def make_ipa(
        self,
        info_overrides=None,
        include_privacy=True,
        privacy_overrides=None,
        blocker_key=None,
        extra_files=None,
    ):
        directory = tempfile.TemporaryDirectory()
        ipa = Path(directory.name) / "Xanh.ipa"
        info = {
            "CFBundleIdentifier": "io.github.lamppkk.xanhbrowser.ios",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "XanhIOS",
            "MinimumOSVersion": "18.0",
            "XanhCloudKitEnabled": "YES",
            "XanhBlockerUpdatesEnabled": "YES",
            "XanhBlockerManifestURL": REQUIRED_BLOCKER_MANIFEST_URL,
            "UIBackgroundModes": ["remote-notification"],
            "UIApplicationSupportsIndirectInputEvents": True,
            "NSFaceIDUsageDescription": "Authenticate protected profiles.",
            "UIDeviceFamily": [1, 2],
        }
        info.update(info_overrides or {})
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/XanhIOS.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/XanhIOS.app/XanhIOS", b"binary")
            archive.writestr(
                "Payload/XanhIOS.app/blocker-public-key.txt",
                base64.b64encode(blocker_key or self.release_key).decode(),
            )
            if include_privacy:
                privacy = {
                    "NSPrivacyTracking": False,
                    "NSPrivacyTrackingDomains": [],
                    "NSPrivacyAccessedAPITypes": [
                        {
                            "NSPrivacyAccessedAPIType": (
                                "NSPrivacyAccessedAPICategoryUserDefaults"
                            ),
                            "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
                        }
                    ],
                    "NSPrivacyCollectedDataTypes": [
                        {
                            "NSPrivacyCollectedDataType": (
                                "NSPrivacyCollectedDataTypeBrowsingHistory"
                            ),
                            "NSPrivacyCollectedDataTypeLinked": False,
                            "NSPrivacyCollectedDataTypeTracking": False,
                            "NSPrivacyCollectedDataTypePurposes": [
                                "NSPrivacyCollectedDataTypePurposeAppFunctionality"
                            ],
                        }
                    ],
                }
                privacy.update(privacy_overrides or {})
                archive.writestr(
                    "Payload/XanhIOS.app/PrivacyInfo.xcprivacy",
                    plistlib.dumps(privacy),
                )
            for name, contents in (extra_files or {}).items():
                archive.writestr(name, contents)
        return directory, ipa

    def test_accepts_expected_release_metadata(self):
        directory, ipa = self.make_ipa()
        self.addCleanup(directory.cleanup)
        expected_key = base64.b64encode(self.release_key).decode()
        self.assertEqual(
            verify_ipa(ipa, "io.github.lamppkk.xanhbrowser.ios", "0.1.0", "42", expected_key),
            [],
        )

    def test_rejects_wrong_bundle_and_missing_privacy_manifest(self):
        directory, ipa = self.make_ipa(
            {"CFBundleIdentifier": "com.example.other"},
            include_privacy=False,
        )
        self.addCleanup(directory.cleanup)
        errors = verify_ipa(ipa, "io.github.lamppkk.xanhbrowser.ios", "0.1.0", "42")
        self.assertTrue(any("CFBundleIdentifier" in error for error in errors))
        self.assertTrue(any("PrivacyInfo.xcprivacy" in error for error in errors))

    def test_rejects_nonproduction_flags_and_wrong_release_key(self):
        directory, ipa = self.make_ipa(
            {
                "XanhCloudKitEnabled": "NO",
                "XanhBlockerUpdatesEnabled": "NO",
                "UIDeviceFamily": [1],
            }
        )
        self.addCleanup(directory.cleanup)
        wrong_key = base64.b64encode(bytes(reversed(range(32)))).decode()
        errors = verify_ipa(ipa, "io.github.lamppkk.xanhbrowser.ios", "0.1.0", "42", wrong_key)
        self.assertTrue(any("CloudKit" in error for error in errors))
        self.assertTrue(any("blocker public key does not match" in error for error in errors))
        self.assertTrue(any("iPhone and iPad" in error for error in errors))

    def test_rejects_incomplete_privacy_declaration_and_embedded_private_key(self):
        directory, ipa = self.make_ipa(
            privacy_overrides={
                "NSPrivacyAccessedAPITypes": ["malformed"],
                "NSPrivacyCollectedDataTypes": [],
            },
            extra_files={"Payload/XanhIOS.app/AuthKey_TEST.p8": "secret"},
        )
        self.addCleanup(directory.cleanup)
        errors = verify_ipa(ipa, "io.github.lamppkk.xanhbrowser.ios", "0.1.0", "42")
        self.assertTrue(any("UserDefaults reason" in error for error in errors))
        self.assertTrue(any("browsing history" in error for error in errors))
        self.assertTrue(any("sensitive key resources" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
