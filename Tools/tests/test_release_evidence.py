import hashlib
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from Tools.release_evidence import (
    EvidenceError,
    canonical_bytes,
    create_candidate,
    hash_ipa,
    load_evidence,
    select_single_ipa,
    validate_corpus,
    validate_evidence,
    write_atomic,
)


class ReleaseEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.export = self.root / "export"
        self.export.mkdir()
        self.ipa = self.export / "XanhIOS.ipa"
        self.ipa.write_bytes(b"signed release artifact")
        self.now = datetime(2026, 8, 21, 1, 2, 3, tzinfo=timezone.utc)

    def tearDown(self):
        self.directory.cleanup()

    def candidate(self):
        expected_sha256, expected_size = hash_ipa(self.ipa)
        return create_candidate(
            self.ipa,
            "LamPPKK/xanh-ios",
            "a" * 40,
            "32434697404",
            "1",
            "42",
            expected_sha256,
            expected_size,
            now=self.now,
        )

    def test_selects_exactly_one_regular_safe_named_ipa(self):
        self.assertEqual(select_single_ipa(self.export), self.ipa.resolve())

        second = self.export / "Other.ipa"
        second.write_bytes(b"other")
        with self.assertRaisesRegex(EvidenceError, "exactly one"):
            select_single_ipa(self.export)
        second.unlink()

        self.ipa.unlink()
        os.symlink(self.root / "outside.ipa", self.ipa)
        with self.assertRaisesRegex(EvidenceError, "regular non-symlink"):
            select_single_ipa(self.export)

        self.ipa.unlink()
        self.ipa.write_bytes(b"signed release artifact")
        unsafe = self.export / "unsafe name.ipa"
        unsafe.write_bytes(b"other")
        with self.assertRaisesRegex(EvidenceError, "filename is not safe"):
            select_single_ipa(self.export)

        unsafe.unlink()
        uppercase = self.export / "Other.IPA"
        uppercase.write_bytes(b"other")
        with self.assertRaisesRegex(EvidenceError, "filename is not safe"):
            select_single_ipa(self.export)

    def test_candidate_binds_commit_workflow_and_exact_ipa(self):
        evidence = self.candidate()
        self.assertEqual(evidence["commitSha"], "a" * 40)
        self.assertEqual(
            evidence["workflow"]["url"],
            "https://github.com/LamPPKK/xanh-ios/actions/runs/32434697404/attempts/1",
        )
        self.assertEqual(evidence["ipa"]["fileName"], "XanhIOS.ipa")
        self.assertEqual(
            evidence["ipa"]["sha256"],
            hashlib.sha256(b"signed release artifact").hexdigest(),
        )
        self.assertEqual(evidence["ipa"]["sizeBytes"], 23)
        self.assertEqual(evidence["releaseStatus"], "candidate")
        self.assertEqual(evidence["createdAt"], "2026-08-21T01:02:03Z")

    def test_candidate_rejects_noncanonical_identity_and_symlink(self):
        expected_sha256, expected_size = hash_ipa(self.ipa)
        with self.assertRaisesRegex(EvidenceError, "repository"):
            create_candidate(
                self.ipa, "not a repo", "a" * 40, "1", "1", "1", expected_sha256, expected_size
            )
        with self.assertRaisesRegex(EvidenceError, "commit"):
            create_candidate(
                self.ipa,
                "LamPPKK/xanh-ios",
                "A" * 40,
                "1",
                "1",
                "1",
                expected_sha256,
                expected_size,
            )
        with self.assertRaisesRegex(EvidenceError, "canonical positive"):
            create_candidate(
                self.ipa,
                "LamPPKK/xanh-ios",
                "a" * 40,
                "01",
                "1",
                "1",
                expected_sha256,
                expected_size,
            )

        link = self.root / "Linked.ipa"
        os.symlink(self.ipa, link)
        with self.assertRaisesRegex(EvidenceError, "non-symlink"):
            create_candidate(
                link,
                "LamPPKK/xanh-ios",
                "a" * 40,
                "1",
                "1",
                "1",
                expected_sha256,
                expected_size,
            )

    def test_candidate_rejects_post_upload_digest_or_size_drift(self):
        expected_sha256, expected_size = hash_ipa(self.ipa)
        self.ipa.write_bytes(b"different bytes after upload")

        with self.assertRaisesRegex(EvidenceError, "locked pre-upload identity"):
            create_candidate(
                self.ipa,
                "LamPPKK/xanh-ios",
                "a" * 40,
                "1",
                "1",
                "1",
                expected_sha256,
                expected_size,
            )

    def test_round_trip_is_canonical_and_rejects_unknown_or_duplicate_fields(self):
        output = self.root / "candidate.json"
        candidate = self.candidate()
        write_atomic(output, candidate)
        self.assertEqual(output.read_bytes(), canonical_bytes(candidate))
        self.assertEqual(load_evidence(output), candidate)

        unknown = dict(candidate)
        unknown["secret"] = "must not pass"
        with self.assertRaisesRegex(EvidenceError, "missing or unknown"):
            validate_evidence(unknown)

        duplicate = self.root / "duplicate.json"
        duplicate.write_text('{"schemaVersion":1,"schemaVersion":1}')
        with self.assertRaisesRegex(EvidenceError, "duplicate JSON field"):
            load_evidence(duplicate)

    def test_candidate_cannot_claim_app_store_or_beta_review(self):
        candidate = self.candidate()
        candidate["releaseStatus"] = "accepted"
        with self.assertRaisesRegex(EvidenceError, "only describe an uploaded candidate"):
            validate_evidence(candidate)

        candidate = self.candidate()
        candidate["appStore"] = {"processingStatus": "processed"}
        with self.assertRaisesRegex(EvidenceError, "missing or unknown"):
            validate_evidence(candidate)

    def test_boolean_schema_versions_are_rejected(self):
        candidate = self.candidate()
        candidate["schemaVersion"] = True
        with self.assertRaisesRegex(EvidenceError, "identity is invalid"):
            validate_evidence(candidate)

        corpus = self.root / "boolean-schema-version-corpus.json"
        corpus.write_text(json.dumps({"schemaVersion": True, "cases": []}))
        with self.assertRaisesRegex(EvidenceError, "identity is invalid"):
            validate_corpus(corpus)

    def test_schema_document_is_strict_json_and_matches_generated_shape(self):
        schema = json.loads((Path("Release") / "evidence-v1.schema.json").read_text())
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(set(schema["required"]), set(self.candidate()))
        self.assertEqual(schema["properties"]["releaseStatus"], {"const": "candidate"})
        for name in ["workflow", "app", "ipa", "validation", "upload"]:
            self.assertFalse(schema["properties"][name]["additionalProperties"])

    def test_published_corpus_exercises_normative_cross_field_invariants(self):
        corpus = Path("Release") / "evidence-v1.corpus.json"
        self.assertEqual(validate_corpus(corpus), 5)

    def test_testflight_workflow_reuses_the_selected_ipa_and_records_evidence(self):
        workflow = (Path(".github") / "workflows" / "testflight.yml").read_text()
        self.assertEqual(workflow.count("release_evidence.py select-ipa"), 1)
        self.assertEqual(workflow.count("release_evidence.py identify-ipa"), 1)
        self.assertEqual(workflow.count("steps.exact_ipa.outputs.path"), 2)
        self.assertEqual(workflow.count("steps.exact_ipa.outputs.sha256"), 1)
        self.assertEqual(workflow.count("steps.exact_ipa.outputs.size_bytes"), 1)
        self.assertNotIn('find "$RUNNER_TEMP/export"', workflow)
        self.assertLess(
            workflow.index("Upload exact validated IPA"),
            workflow.index("Record candidate evidence"),
        )
        self.assertIn("release-evidence-v1.json", workflow)

        pages = (Path(".github") / "workflows" / "pages.yml").read_text()
        self.assertIn("Release/evidence-v1.schema.json", pages)
        self.assertIn("site/release-evidence-v1.schema.json", pages)
        self.assertIn("site/release-evidence-v1.corpus.json", pages)
        self.assertIn("site/release-evidence-v1.invariants.md", pages)


if __name__ == "__main__":
    unittest.main()
