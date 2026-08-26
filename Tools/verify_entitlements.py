#!/usr/bin/env python3

import argparse
import plistlib
import sys
from pathlib import Path


def verify_entitlements(entitlements, team_id: str, bundle_id: str):
    errors = []
    application_identifier = f"{team_id}.{bundle_id}"
    cloud_container = f"iCloud.{bundle_id}"

    if entitlements.get("application-identifier") != application_identifier:
        errors.append(f"application-identifier must be {application_identifier}")
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        errors.append(f"com.apple.developer.team-identifier must be {team_id}")
    if entitlements.get("aps-environment") != "production":
        errors.append("aps-environment must be production")
    if entitlements.get("get-task-allow") is True:
        errors.append("get-task-allow must not be enabled in a distribution archive")
    if (
        entitlements.get("com.apple.developer.default-data-protection")
        != "NSFileProtectionCompleteUntilFirstUserAuthentication"
    ):
        errors.append(
            "com.apple.developer.default-data-protection must be "
            "NSFileProtectionCompleteUntilFirstUserAuthentication"
        )
    if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
        errors.append("CloudKit container environment must be Production")

    containers = entitlements.get("com.apple.developer.icloud-container-identifiers", [])
    if not isinstance(containers, list) or containers != [cloud_container]:
        errors.append(f"CloudKit container identifiers must contain only {cloud_container}")

    services = entitlements.get("com.apple.developer.icloud-services", [])
    if not isinstance(services, list) or "CloudKit" not in services:
        errors.append("iCloud services must include CloudKit")

    if (
        entitlements.get("com.apple.developer.ubiquity-kvstore-identifier")
        != application_identifier
    ):
        errors.append(f"ubiquity key-value store identifier must be {application_identifier}")

    return errors


def main():
    parser = argparse.ArgumentParser(
        description="Verify production entitlements extracted from the signed Xanh archive."
    )
    parser.add_argument("--plist", type=Path, required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    args = parser.parse_args()

    try:
        entitlements = plistlib.loads(args.plist.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        print(f"entitlement verification: cannot read entitlement plist: {error}", file=sys.stderr)
        raise SystemExit(1)

    errors = verify_entitlements(entitlements, args.team_id, args.bundle_id)
    if errors:
        for error in errors:
            print(f"entitlement verification: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("archive entitlement verification passed")


if __name__ == "__main__":
    main()
