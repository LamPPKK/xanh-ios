#!/usr/bin/env python3

import argparse
import base64
import binascii
import os
import re
import sys
import uuid
from pathlib import Path


REQUIRED_BUNDLE_ID = "io.github.lamppkk.xanhbrowser.ios"
REQUIRED_MARKETING_VERSION = "0.1.0"


def validate_environment(environment, project_path: Path):
    errors = []

    if environment.get("CLOUDKIT_SCHEMA_PROMOTED") != "true":
        errors.append("CLOUDKIT_SCHEMA_PROMOTED must be exactly 'true' after production promotion")

    team_id = environment.get("APPLE_TEAM_ID", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id, flags=re.ASCII):
        errors.append("APPLE_TEAM_ID must be a 10-character Apple team identifier")

    key_id = environment.get("APP_STORE_CONNECT_KEY_ID", "")
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id, flags=re.ASCII):
        errors.append("APP_STORE_CONNECT_KEY_ID must be a 10-character key identifier")

    issuer_id = environment.get("APP_STORE_CONNECT_ISSUER_ID", "")
    try:
        uuid.UUID(issuer_id)
    except (ValueError, AttributeError):
        errors.append("APP_STORE_CONNECT_ISSUER_ID must be a UUID")

    private_key = environment.get("APP_STORE_CONNECT_PRIVATE_KEY", "").strip()
    if not (
        private_key.startswith("-----BEGIN PRIVATE KEY-----")
        and private_key.endswith("-----END PRIVATE KEY-----")
    ):
        errors.append("APP_STORE_CONNECT_PRIVATE_KEY must contain the complete PEM private key")

    try:
        blocker_key = base64.b64decode(
            environment.get("BLOCKER_PUBLIC_KEY_BASE64", ""),
            validate=True,
        )
        if len(blocker_key) != 32:
            raise ValueError
    except (binascii.Error, ValueError):
        errors.append("BLOCKER_PUBLIC_KEY_BASE64 must decode to a 32-byte Ed25519 public key")

    project = project_path.read_text()
    if f"PRODUCT_BUNDLE_IDENTIFIER: {REQUIRED_BUNDLE_ID}" not in project:
        errors.append(f"project bundle identifier must remain {REQUIRED_BUNDLE_ID}")
    if f"MARKETING_VERSION: {REQUIRED_MARKETING_VERSION}" not in project:
        errors.append(f"marketing version must remain {REQUIRED_MARKETING_VERSION} for the first beta")

    return errors


def main():
    parser = argparse.ArgumentParser(description="Fail fast before creating a TestFlight archive.")
    parser.add_argument("--project", type=Path, default=Path("project.yml"))
    args = parser.parse_args()
    errors = validate_environment(os.environ, args.project)
    if errors:
        for error in errors:
            print(f"release preflight: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("release preflight passed")


if __name__ == "__main__":
    main()
