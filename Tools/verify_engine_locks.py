#!/usr/bin/env python3
"""Fail closed when Xanh engine provenance locks or the Apple adapter drift."""

from __future__ import annotations

import argparse
from pathlib import Path


EXPECTED_LOCKS = {
    "XANH_WEBKIT.lock": {
        "format": "1",
        "repository": "https://github.com/LamPPKK/xanh-webkit",
        "revision": "10904b5a96cd9172c7753a2616fc491632b569b1",
    },
    "XANH_WEBVIEW.lock": {
        "format": "1",
        "api_version": "0.1.0-alpha.1",
        "release_tag": "v0.1.0-alpha.1",
        "repository": "https://github.com/LamPPKK/xanh-webview",
        "revision": "71d67e09d255797917c1ad7cb459feac60118bab",
    },
}

ADAPTER_TOKENS = {
    'contractVersion: "0.1.0-alpha.1"': "Xanh WebView contract version",
    'adapter: "xanh-webview/apple"': "Apple adapter identity",
    'backend: "WKWebView"': "system WKWebView backend",
    'backendOwner: "Apple system WebKit"': "backend owner",
    'fallback: "Apple system WebKit"': "truthful system fallback",
}


def parse_lock(path: Path) -> tuple[dict[str, str], list[str]]:
    values: dict[str, str] = {}
    errors: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        return values, [f"{path.name}: cannot read lock: {error}"]

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line:
            continue
        key, separator, value = line.partition("=")
        if not separator or not key or not value or key != key.strip() or value != value.strip():
            errors.append(f"{path.name}:{line_number}: expected key=value")
            continue
        if key in values:
            errors.append(f"{path.name}:{line_number}: duplicate key {key}")
            continue
        values[key] = value
    return values, errors


def verify_engine_locks(root: Path) -> list[str]:
    errors: list[str] = []
    parsed: dict[str, dict[str, str]] = {}
    for filename, expected in EXPECTED_LOCKS.items():
        values, lock_errors = parse_lock(root / filename)
        errors.extend(lock_errors)
        parsed[filename] = values
        unknown = set(values) - set(expected)
        missing = set(expected) - set(values)
        if unknown:
            errors.append(f"{filename}: unsupported keys: {', '.join(sorted(unknown))}")
        if missing:
            errors.append(f"{filename}: missing keys: {', '.join(sorted(missing))}")
        for key, expected_value in expected.items():
            if key in values and values[key] != expected_value:
                errors.append(
                    f"{filename}: {key} must be {expected_value}, got {values[key]}"
                )

    source_path = root / "Sources" / "Browser" / "XanhWebView.swift"
    try:
        source = source_path.read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"XanhWebView.swift: cannot read adapter source: {error}")
        return errors

    for token, label in ADAPTER_TOKENS.items():
        if token not in source:
            errors.append(f"XanhWebView.swift: missing {label}: {token}")

    webview_version = parsed.get("XANH_WEBVIEW.lock", {}).get("api_version")
    if webview_version and f'contractVersion: "{webview_version}"' not in source:
        errors.append(
            "XANH_WEBVIEW.lock: api_version does not match XanhWebViewEngineInfo"
        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root",
    )
    args = parser.parse_args()
    errors = verify_engine_locks(args.root.resolve())
    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1
    print("Xanh engine locks and Apple adapter contract verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
