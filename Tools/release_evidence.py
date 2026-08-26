#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


MAX_EVIDENCE_BYTES = 64 * 1024
MAX_CORPUS_BYTES = 256 * 1024
MAX_IPA_BYTES = 8 * 1024 * 1024 * 1024
REPOSITORY_PATTERN = re.compile(
    r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}", re.ASCII
)
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}", re.ASCII)
BUILD_PATTERN = re.compile(r"[1-9][0-9]{0,17}", re.ASCII)
IPA_NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,126}\.ipa", re.ASCII)
CORPUS_NAME_PATTERN = re.compile(r"[a-z0-9][a-z0-9-]{0,63}", re.ASCII)


class EvidenceError(ValueError):
    pass


def utc_timestamp(now=None):
    value = now or datetime.now(timezone.utc)
    if value.tzinfo is None:
        raise EvidenceError("timestamp source must be timezone-aware")
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def positive_integer(value, label):
    if isinstance(value, bool):
        raise EvidenceError(f"{label} must be a positive integer")
    try:
        parsed = int(value)
    except (TypeError, ValueError) as error:
        raise EvidenceError(f"{label} must be a positive integer") from error
    if parsed < 1 or str(parsed) != str(value):
        raise EvidenceError(f"{label} must be a canonical positive integer")
    return parsed


def validate_repository(value):
    if not isinstance(value, str) or not REPOSITORY_PATTERN.fullmatch(value):
        raise EvidenceError("repository must use the owner/name GitHub form")
    return value


def validate_commit(value):
    if not isinstance(value, str) or not COMMIT_PATTERN.fullmatch(value):
        raise EvidenceError("commit must be a lowercase 40-character SHA-1")
    return value


def validate_build(value):
    if not isinstance(value, str) or not BUILD_PATTERN.fullmatch(value):
        raise EvidenceError("build must be a canonical positive decimal string")
    return value


def validate_sha256(value, label="SHA-256"):
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9a-f]{64}", value, flags=re.ASCII
    ):
        raise EvidenceError(f"{label} must be a lowercase SHA-256")
    return value


def validate_timestamp(value, label):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise EvidenceError(f"{label} must be an RFC 3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise EvidenceError(f"{label} must be an RFC 3339 UTC timestamp") from error
    if parsed.tzinfo is None or utc_timestamp(parsed) != value:
        raise EvidenceError(f"{label} must be a canonical RFC 3339 UTC timestamp")
    return value


def _open_regular_file(path: Path, maximum_size: int, label: str):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceError(f"{label} must be a readable non-symlink file") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise EvidenceError(f"{label} must be a regular file")
        if metadata.st_size < 1 or metadata.st_size > maximum_size:
            raise EvidenceError(f"{label} size is outside the supported range")
        return descriptor, metadata
    except Exception:
        os.close(descriptor)
        raise


def select_single_ipa(directory: Path):
    try:
        metadata = directory.stat(follow_symlinks=False)
    except OSError as error:
        raise EvidenceError("export directory must exist") from error
    if not stat.S_ISDIR(metadata.st_mode) or directory.is_symlink():
        raise EvidenceError("export directory must be a real directory")

    candidates = []
    for child in directory.iterdir():
        if not child.name.lower().endswith(".ipa"):
            continue
        if not IPA_NAME_PATTERN.fullmatch(child.name):
            raise EvidenceError("IPA candidate filename is not safe")
        try:
            child_metadata = child.stat(follow_symlinks=False)
        except OSError as error:
            raise EvidenceError("could not inspect an IPA candidate") from error
        if not stat.S_ISREG(child_metadata.st_mode):
            raise EvidenceError("IPA candidate must be a regular non-symlink file")
        candidates.append(child)

    if len(candidates) != 1:
        raise EvidenceError("export directory must contain exactly one safe-named IPA")
    return candidates[0].resolve()


def hash_ipa(path: Path):
    if not IPA_NAME_PATTERN.fullmatch(path.name):
        raise EvidenceError("IPA filename is not safe")
    descriptor, initial_metadata = _open_regular_file(path, MAX_IPA_BYTES, "IPA")
    digest = hashlib.sha256()
    total = 0
    try:
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_IPA_BYTES:
                    raise EvidenceError("IPA exceeded the supported size while hashing")
                digest.update(chunk)
            final_metadata = os.fstat(handle.fileno())
    except OSError as error:
        raise EvidenceError("IPA could not be read completely") from error
    initial_identity = (
        initial_metadata.st_dev,
        initial_metadata.st_ino,
        initial_metadata.st_size,
        initial_metadata.st_mtime_ns,
        initial_metadata.st_ctime_ns,
    )
    final_identity = (
        final_metadata.st_dev,
        final_metadata.st_ino,
        final_metadata.st_size,
        final_metadata.st_mtime_ns,
        final_metadata.st_ctime_ns,
    )
    if total != initial_metadata.st_size or final_identity != initial_identity:
        raise EvidenceError("IPA changed while it was being hashed")
    return digest.hexdigest(), total


def workflow_url(repository, run_id, attempt):
    return f"https://github.com/{repository}/actions/runs/{run_id}/attempts/{attempt}"


def create_candidate(
    ipa_path: Path,
    repository: str,
    commit: str,
    run_id,
    attempt,
    build: str,
    expected_sha256: str,
    expected_size_bytes,
    now=None,
):
    repository = validate_repository(repository)
    commit = validate_commit(commit)
    run_id = positive_integer(run_id, "run id")
    attempt = positive_integer(attempt, "run attempt")
    build = validate_build(build)
    expected_sha256 = validate_sha256(expected_sha256, "expected IPA SHA-256")
    expected_size_bytes = positive_integer(expected_size_bytes, "expected IPA size")
    if expected_size_bytes > MAX_IPA_BYTES:
        raise EvidenceError("expected IPA size exceeds the supported maximum")
    sha256, size = hash_ipa(ipa_path)
    if sha256 != expected_sha256 or size != expected_size_bytes:
        raise EvidenceError("IPA does not match the locked pre-upload identity")
    document = {
        "schemaVersion": 1,
        "product": "xanh-ios",
        "repository": repository,
        "commitSha": commit,
        "workflow": {
            "runId": run_id,
            "attempt": attempt,
            "url": workflow_url(repository, run_id, attempt),
        },
        "app": {
            "bundleIdentifier": "io.github.lamppkk.xanhbrowser.ios",
            "marketingVersion": "0.1.0",
            "buildNumber": build,
        },
        "ipa": {
            "fileName": ipa_path.name,
            "sha256": sha256,
            "sizeBytes": size,
        },
        "validation": {"tool": "xcrun altool", "status": "passed"},
        "upload": {"tool": "xcrun altool", "status": "accepted"},
        "releaseStatus": "candidate",
        "createdAt": utc_timestamp(now),
    }
    validate_evidence(document)
    return document


def _require_keys(value, expected, label):
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be an object")
    actual = set(value)
    expected = set(expected)
    if actual != expected:
        raise EvidenceError(f"{label} has missing or unknown fields")


def validate_evidence(document):
    _require_keys(
        document,
        {
            "schemaVersion",
            "product",
            "repository",
            "commitSha",
            "workflow",
            "app",
            "ipa",
            "validation",
            "upload",
            "releaseStatus",
            "createdAt",
        },
        "release evidence",
    )
    if (
        type(document["schemaVersion"]) is not int
        or document["schemaVersion"] != 1
        or document["product"] != "xanh-ios"
    ):
        raise EvidenceError("release evidence identity is invalid")
    repository = validate_repository(document["repository"])
    validate_commit(document["commitSha"])
    validate_timestamp(document["createdAt"], "createdAt")

    workflow = document["workflow"]
    _require_keys(workflow, {"runId", "attempt", "url"}, "workflow")
    run_id = positive_integer(workflow["runId"], "workflow run id")
    attempt = positive_integer(workflow["attempt"], "workflow attempt")
    if workflow["url"] != workflow_url(repository, run_id, attempt):
        raise EvidenceError("workflow URL does not match repository, run id and attempt")

    app = document["app"]
    _require_keys(app, {"bundleIdentifier", "marketingVersion", "buildNumber"}, "app")
    if app["bundleIdentifier"] != "io.github.lamppkk.xanhbrowser.ios":
        raise EvidenceError("bundle identifier is invalid")
    if app["marketingVersion"] != "0.1.0":
        raise EvidenceError("marketing version is invalid")
    validate_build(app["buildNumber"])

    ipa = document["ipa"]
    _require_keys(ipa, {"fileName", "sha256", "sizeBytes"}, "ipa")
    if not isinstance(ipa["fileName"], str) or not IPA_NAME_PATTERN.fullmatch(ipa["fileName"]):
        raise EvidenceError("IPA filename is invalid")
    validate_sha256(ipa["sha256"], "IPA SHA-256")
    size = positive_integer(ipa["sizeBytes"], "IPA size")
    if size > MAX_IPA_BYTES:
        raise EvidenceError("IPA size exceeds the supported maximum")

    validation = document["validation"]
    _require_keys(validation, {"tool", "status"}, "validation")
    if validation != {"tool": "xcrun altool", "status": "passed"}:
        raise EvidenceError("validation result is invalid")
    upload = document["upload"]
    _require_keys(upload, {"tool", "status"}, "upload")
    if upload != {"tool": "xcrun altool", "status": "accepted"}:
        raise EvidenceError("upload result is invalid")

    if document["releaseStatus"] != "candidate":
        raise EvidenceError("release evidence can only describe an uploaded candidate")
    return document


def _reject_duplicate_keys(pairs):
    document = {}
    for key, value in pairs:
        if key in document:
            raise EvidenceError(f"duplicate JSON field: {key}")
        document[key] = value
    return document


def load_json_document(path: Path, maximum_size: int, label: str):
    descriptor, initial_metadata = _open_regular_file(path, maximum_size, label)
    try:
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            payload = handle.read(maximum_size + 1)
            final_metadata = os.fstat(handle.fileno())
    except OSError as error:
        raise EvidenceError(f"{label} could not be read") from error
    initial_identity = (
        initial_metadata.st_dev,
        initial_metadata.st_ino,
        initial_metadata.st_size,
        initial_metadata.st_mtime_ns,
        initial_metadata.st_ctime_ns,
    )
    final_identity = (
        final_metadata.st_dev,
        final_metadata.st_ino,
        final_metadata.st_size,
        final_metadata.st_mtime_ns,
        final_metadata.st_ctime_ns,
    )
    if len(payload) != initial_metadata.st_size or final_identity != initial_identity:
        raise EvidenceError(f"{label} changed while it was being read")
    try:
        return json.loads(payload, object_pairs_hook=_reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise EvidenceError(f"{label} must be valid UTF-8 JSON") from error


def load_evidence(path: Path):
    return validate_evidence(load_json_document(path, MAX_EVIDENCE_BYTES, "evidence input"))


def validate_corpus(path: Path):
    corpus = load_json_document(path, MAX_CORPUS_BYTES, "conformance corpus")
    _require_keys(corpus, {"schemaVersion", "cases"}, "conformance corpus")
    if (
        type(corpus["schemaVersion"]) is not int
        or corpus["schemaVersion"] != 1
        or not isinstance(corpus["cases"], list)
    ):
        raise EvidenceError("conformance corpus identity is invalid")
    if not 2 <= len(corpus["cases"]) <= 128:
        raise EvidenceError("conformance corpus must contain 2 to 128 cases")

    names = set()
    expected_results = set()
    for case in corpus["cases"]:
        _require_keys(case, {"name", "valid", "document"}, "conformance case")
        name = case["name"]
        if not isinstance(name, str) or not CORPUS_NAME_PATTERN.fullmatch(name):
            raise EvidenceError("conformance case name is invalid")
        if name in names:
            raise EvidenceError(f"duplicate conformance case: {name}")
        names.add(name)
        if type(case["valid"]) is not bool:
            raise EvidenceError(f"conformance case {name} must declare a boolean result")
        expected_results.add(case["valid"])
        try:
            validate_evidence(case["document"])
            actual = True
        except EvidenceError:
            actual = False
        if actual is not case["valid"]:
            raise EvidenceError(f"conformance case {name} produced the wrong result")
    if expected_results != {False, True}:
        raise EvidenceError("conformance corpus must contain valid and invalid cases")
    return len(corpus["cases"])


def canonical_bytes(document):
    validate_evidence(document)
    return (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_atomic(path: Path, document):
    payload = canonical_bytes(document)
    parent = path.parent
    if not parent.is_dir() or parent.is_symlink():
        raise EvidenceError("output parent must be a real directory")
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", dir=parent, prefix=f".{path.name}.", delete=False
        ) as handle:
            temporary_name = handle.name
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, path)
        temporary_name = None
    except OSError as error:
        raise EvidenceError("release evidence output could not be written atomically") from error
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(
        description="Create and validate machine-readable TestFlight candidate evidence."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    select = subparsers.add_parser("select-ipa")
    select.add_argument("--directory", type=Path, required=True)

    identify = subparsers.add_parser("identify-ipa")
    identify.add_argument("--ipa", type=Path, required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--ipa", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    create.add_argument("--repository", required=True)
    create.add_argument("--commit", required=True)
    create.add_argument("--run-id", required=True)
    create.add_argument("--run-attempt", required=True)
    create.add_argument("--build", required=True)
    create.add_argument("--expected-sha256", required=True)
    create.add_argument("--expected-size-bytes", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--input", type=Path, required=True)

    corpus = subparsers.add_parser("validate-corpus")
    corpus.add_argument("--input", type=Path, required=True)

    args = parser.parse_args()
    try:
        if args.command == "select-ipa":
            print(select_single_ipa(args.directory))
        elif args.command == "identify-ipa":
            sha256, size = hash_ipa(args.ipa)
            print(f"{sha256} {size}")
        elif args.command == "create":
            document = create_candidate(
                args.ipa,
                args.repository,
                args.commit,
                args.run_id,
                args.run_attempt,
                args.build,
                args.expected_sha256,
                args.expected_size_bytes,
            )
            write_atomic(args.output, document)
            print(f"release candidate evidence written to {args.output}")
        elif args.command == "validate":
            load_evidence(args.input)
            print("release evidence validation passed")
        else:
            count = validate_corpus(args.input)
            print(f"release evidence conformance corpus passed ({count} cases)")
    except EvidenceError as error:
        print(f"release evidence: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
