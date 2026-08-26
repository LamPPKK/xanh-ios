import unittest

from Tools.verify_entitlements import verify_entitlements


class VerifyEntitlementsTests(unittest.TestCase):
    team_id = "A1B2C3D4E5"
    bundle_id = "io.github.lamppkk.xanhbrowser.ios"

    def expected_entitlements(self):
        application_identifier = f"{self.team_id}.{self.bundle_id}"
        return {
            "application-identifier": application_identifier,
            "com.apple.developer.team-identifier": self.team_id,
            "aps-environment": "production",
            "get-task-allow": False,
            "com.apple.developer.default-data-protection": (
                "NSFileProtectionCompleteUntilFirstUserAuthentication"
            ),
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.icloud-container-identifiers": [
                f"iCloud.{self.bundle_id}"
            ],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.ubiquity-kvstore-identifier": application_identifier,
        }

    def test_accepts_expected_distribution_entitlements(self):
        self.assertEqual(
            verify_entitlements(
                self.expected_entitlements(),
                self.team_id,
                self.bundle_id,
            ),
            [],
        )

    def test_rejects_debug_and_wrong_cloudkit_entitlements(self):
        entitlements = self.expected_entitlements()
        entitlements.update(
            {
                "application-identifier": "OTHER.io.github.lamppkk.xanhbrowser.ios",
                "aps-environment": "development",
                "get-task-allow": True,
                "com.apple.developer.icloud-container-environment": "Development",
                "com.apple.developer.icloud-container-identifiers": ["iCloud.example.other"],
                "com.apple.developer.icloud-services": [],
            }
        )
        errors = verify_entitlements(entitlements, self.team_id, self.bundle_id)
        self.assertTrue(any("application-identifier" in error for error in errors))
        self.assertTrue(any("aps-environment" in error for error in errors))
        self.assertTrue(any("get-task-allow" in error for error in errors))
        self.assertTrue(any("environment" in error for error in errors))
        self.assertTrue(any("container identifiers" in error for error in errors))
        self.assertTrue(any("include CloudKit" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
