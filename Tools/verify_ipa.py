#!/usr/bin/env python3

import argparse
import base64
import binascii
import plistlib
import re
import sys
import zipfile
from pathlib import Path, PurePosixPath


REQUIRED_BLOCKER_MANIFEST_URL = (
    "https://lamppkk.github.io/xanh-ios/blocker/manifest-v1.json"
)
SENSITIVE_RESOURCE_SUFFIXES = {".key", ".p8", ".pem"}


def version_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise ValueError(f"invalid numeric version: {value!r}")
    return tuple(int(component) for component in value.split("."))


def enabled(value):
    return value is True or str(value).upper() in {"1", "TRUE", "YES"}


def verify_ipa(
    ipa_path: Path,
    bundle_id: str,
    version: str,
    build: str,
    blocker_public_key_base64: str | None = None,
    blocker_manifest_url: str = REQUIRED_BLOCKER_MANIFEST_URL,
):
    errors = []
    with zipfile.ZipFile(ipa_path) as archive:
        names = archive.namelist()
        info_candidates = [
            name
            for name in names
            if len(PurePosixPath(name).parts) == 3
            and PurePosixPath(name).parts[0] == "Payload"
            and PurePosixPath(name).parts[1].endswith(".app")
            and PurePosixPath(name).name == "Info.plist"
        ]
        if len(info_candidates) != 1:
            return ["IPA must contain exactly one top-level application Info.plist"]

        app_prefix = str(PurePosixPath(info_candidates[0]).parent) + "/"
        info = plistlib.loads(archive.read(info_candidates[0]))
        expected_values = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        }
        for key, expected in expected_values.items():
            if str(info.get(key, "")) != expected:
                errors.append(f"{key} must be {expected}")

        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or "/" in executable:
            errors.append("CFBundleExecutable must name the top-level application executable")
        elif app_prefix + executable not in names:
            errors.append("the application executable is missing from the IPA")

        try:
            if version_tuple(info.get("MinimumOSVersion")) < (18, 0):
                errors.append("MinimumOSVersion must be iOS 18.0 or newer")
        except ValueError as error:
            errors.append(str(error))

        if not enabled(info.get("XanhCloudKitEnabled")):
            errors.append("XanhCloudKitEnabled must be enabled in the release IPA")
        if not enabled(info.get("XanhBlockerUpdatesEnabled")):
            errors.append("XanhBlockerUpdatesEnabled must be enabled in the release IPA")
        if info.get("XanhBlockerManifestURL") != blocker_manifest_url:
            errors.append(f"XanhBlockerManifestURL must be {blocker_manifest_url}")
        background_modes = info.get("UIBackgroundModes", [])
        if not isinstance(background_modes, list) or "remote-notification" not in background_modes:
            errors.append("UIBackgroundModes must include remote-notification")
        if info.get("UIApplicationSupportsIndirectInputEvents") is not True:
            errors.append("UIApplicationSupportsIndirectInputEvents must be true")
        if not str(info.get("NSFaceIDUsageDescription", "")).strip():
            errors.append("NSFaceIDUsageDescription must be present")
        device_families = info.get("UIDeviceFamily", [])
        if not isinstance(device_families, list) or not {1, 2}.issubset(set(device_families)):
            errors.append("UIDeviceFamily must include iPhone and iPad")

        privacy_path = app_prefix + "PrivacyInfo.xcprivacy"
        if privacy_path not in names:
            errors.append("PrivacyInfo.xcprivacy is missing from the application bundle")
        else:
            privacy = plistlib.loads(archive.read(privacy_path))
            if privacy.get("NSPrivacyTracking") is not False:
                errors.append("NSPrivacyTracking must be false")
            if privacy.get("NSPrivacyTrackingDomains") not in (None, []):
                errors.append("NSPrivacyTrackingDomains must be empty")

            accessed_types = privacy.get("NSPrivacyAccessedAPITypes", [])
            if not isinstance(accessed_types, list):
                accessed_types = []
            user_defaults = next(
                (
                    item
                    for item in accessed_types
                    if isinstance(item, dict)
                    if item.get("NSPrivacyAccessedAPIType")
                    == "NSPrivacyAccessedAPICategoryUserDefaults"
                ),
                None,
            )
            if not user_defaults or "CA92.1" not in user_defaults.get(
                "NSPrivacyAccessedAPITypeReasons", []
            ):
                errors.append("privacy manifest must declare UserDefaults reason CA92.1")

            collected_types = privacy.get("NSPrivacyCollectedDataTypes", [])
            if not isinstance(collected_types, list):
                collected_types = []
            browsing_history = next(
                (
                    item
                    for item in collected_types
                    if isinstance(item, dict)
                    if item.get("NSPrivacyCollectedDataType")
                    == "NSPrivacyCollectedDataTypeBrowsingHistory"
                ),
                None,
            )
            if (
                not browsing_history
                or browsing_history.get("NSPrivacyCollectedDataTypeLinked") is not False
                or browsing_history.get("NSPrivacyCollectedDataTypeTracking") is not False
                or "NSPrivacyCollectedDataTypePurposeAppFunctionality"
                not in browsing_history.get("NSPrivacyCollectedDataTypePurposes", [])
            ):
                errors.append(
                    "privacy manifest must declare unlinked, non-tracking browsing history for app functionality"
                )

        public_key_path = app_prefix + "blocker-public-key.txt"
        try:
            encoded_key = archive.read(public_key_path).decode().strip()
            bundled_key = base64.b64decode(encoded_key, validate=True)
            if len(bundled_key) != 32:
                raise ValueError
        except (KeyError, UnicodeDecodeError, binascii.Error, ValueError):
            errors.append("the bundled blocker public key must be valid 32-byte Ed25519 key data")
            bundled_key = None

        if blocker_public_key_base64 is not None:
            try:
                expected_key = base64.b64decode(blocker_public_key_base64, validate=True)
                if len(expected_key) != 32:
                    raise ValueError
            except (binascii.Error, ValueError):
                errors.append("the expected blocker public key must be valid 32-byte Ed25519 key data")
            else:
                if bundled_key is not None and bundled_key != expected_key:
                    errors.append("the bundled blocker public key does not match the release key")

        sensitive_resources = sorted(
            name
            for name in names
            if PurePosixPath(name).suffix.lower() in SENSITIVE_RESOURCE_SUFFIXES
        )
        if sensitive_resources:
            errors.append("IPA contains sensitive key resources: " + ", ".join(sensitive_resources))

    return errors


def main():
    parser = argparse.ArgumentParser(description="Verify the exact IPA that will be uploaded.")
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--blocker-public-key-base64", required=True)
    parser.add_argument("--blocker-manifest-url", default=REQUIRED_BLOCKER_MANIFEST_URL)
    args = parser.parse_args()
    errors = verify_ipa(
        args.ipa,
        args.bundle_id,
        args.version,
        args.build,
        args.blocker_public_key_base64,
        args.blocker_manifest_url,
    )
    if errors:
        for error in errors:
            print(f"IPA verification: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("exact IPA verification passed")


if __name__ == "__main__":
    main()
