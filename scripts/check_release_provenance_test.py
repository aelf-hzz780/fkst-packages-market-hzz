#!/usr/bin/env python3
"""Regression tests for formal-gate repository and tag provenance."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_ROOT))

import check_release_provenance as provenance  # noqa: E402


PACKAGE_REF = "v0.3.0-rc.4"


class ReleaseProvenanceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="release-provenance-")
        self.root = Path(self.temporary.name)
        subprocess.run(("git", "init", "-q"), cwd=self.root, check=True)
        subprocess.run(
            ("git", "config", "user.name", "FKST Test"), cwd=self.root, check=True
        )
        subprocess.run(
            ("git", "config", "user.email", "fkst@example.invalid"),
            cwd=self.root,
            check=True,
        )
        manifest = self.root / provenance.MANIFEST_PATH
        manifest.parent.mkdir(parents=True)
        manifest.write_text(
            json.dumps(
                {
                    "packages": [
                        "aelf-hzz780/fkst-packages-market-hzz@"
                        f"{PACKAGE_REF}:packages/{package}"
                        for package in sorted(provenance.contract_checker.EXPECTED_PACKAGES)
                    ]
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        self.first_head = self.commit_all("initial fixture")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def commit_all(self, message: str) -> str:
        subprocess.run(("git", "add", "."), cwd=self.root, check=True)
        subprocess.run(("git", "commit", "-qm", message), cwd=self.root, check=True)
        return subprocess.run(
            ("git", "rev-parse", "HEAD"),
            cwd=self.root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def github_environment(
        self,
        *,
        ref_type: str,
        ref_name: str,
        ref: str,
        sha: str | None = None,
    ) -> dict[str, str]:
        return {
            "GITHUB_ACTIONS": "true",
            "GITHUB_REF_TYPE": ref_type,
            "GITHUB_REF_NAME": ref_name,
            "GITHUB_REF": ref,
            "GITHUB_SHA": sha or self.first_head,
        }

    def test_manifest_ref_reuses_contract_descriptor_validation(self) -> None:
        self.assertEqual(provenance.read_package_ref(self.root), PACKAGE_REF)

    def test_clean_local_pretag_checkout_is_attested(self) -> None:
        result = provenance.validate_release_provenance(self.root, PACKAGE_REF, {})

        self.assertEqual(result.tested_head, self.first_head)
        self.assertEqual(result.release_context, "local-pretag")
        self.assertEqual(result.release_tag_commit, "missing")

    def test_dirty_or_untracked_repository_fails_closed(self) -> None:
        (self.root / "untracked.txt").write_text("not tested as HEAD\n", encoding="ascii")

        with self.assertRaises(provenance.ReleaseProvenanceError) as error:
            provenance.validate_release_provenance(self.root, PACKAGE_REF, {})

        self.assertEqual(error.exception.code, "dirty_repository")

    def test_local_tag_on_tested_head_is_reported(self) -> None:
        subprocess.run(("git", "tag", PACKAGE_REF), cwd=self.root, check=True)

        result = provenance.validate_release_provenance(self.root, PACKAGE_REF, {})

        self.assertEqual(result.release_context, "local-tagged")
        self.assertEqual(result.release_tag_commit, self.first_head)

    def test_local_branch_after_existing_release_tag_remains_testable(self) -> None:
        subprocess.run(("git", "tag", PACKAGE_REF), cwd=self.root, check=True)
        (self.root / "next.txt").write_text("next\n", encoding="ascii")
        next_head = self.commit_all("next fixture")

        result = provenance.validate_release_provenance(self.root, PACKAGE_REF, {})

        self.assertEqual(result.tested_head, next_head)
        self.assertEqual(result.release_context, "local-branch")
        self.assertEqual(result.release_tag_commit, self.first_head)

    def test_github_branch_binds_event_sha_to_tested_head_without_requiring_tag(self) -> None:
        environment = self.github_environment(
            ref_type="branch",
            ref_name="feat/release",
            ref="refs/heads/feat/release",
        )

        result = provenance.validate_release_provenance(
            self.root, PACKAGE_REF, environment
        )

        self.assertEqual(result.release_context, "github-branch")
        self.assertEqual(result.tested_head, self.first_head)

    def test_github_tag_binds_manifest_tag_event_and_tested_head(self) -> None:
        subprocess.run(
            ("git", "tag", "-a", PACKAGE_REF, "-m", "annotated release fixture"),
            cwd=self.root,
            check=True,
        )
        environment = self.github_environment(
            ref_type="tag",
            ref_name=PACKAGE_REF,
            ref=f"refs/tags/{PACKAGE_REF}",
        )

        result = provenance.validate_release_provenance(
            self.root, PACKAGE_REF, environment
        )

        self.assertEqual(result.release_context, "github-tag")
        self.assertEqual(result.release_tag_commit, self.first_head)

    def test_github_tag_name_must_match_manifest_ref(self) -> None:
        subprocess.run(("git", "tag", PACKAGE_REF), cwd=self.root, check=True)
        environment = self.github_environment(
            ref_type="tag",
            ref_name="v0.3.0-rc.5",
            ref="refs/tags/v0.3.0-rc.5",
        )

        with self.assertRaises(provenance.ReleaseProvenanceError) as error:
            provenance.validate_release_provenance(self.root, PACKAGE_REF, environment)

        self.assertEqual(error.exception.code, "release_tag_manifest_mismatch")

    def test_github_tag_must_resolve_to_tested_head(self) -> None:
        subprocess.run(("git", "tag", PACKAGE_REF), cwd=self.root, check=True)
        (self.root / "next.txt").write_text("next\n", encoding="ascii")
        next_head = self.commit_all("next fixture")
        environment = self.github_environment(
            ref_type="tag",
            ref_name=PACKAGE_REF,
            ref=f"refs/tags/{PACKAGE_REF}",
            sha=next_head,
        )

        with self.assertRaises(provenance.ReleaseProvenanceError) as error:
            provenance.validate_release_provenance(self.root, PACKAGE_REF, environment)

        self.assertEqual(error.exception.code, "release_tag_head_mismatch")

    def test_github_event_sha_must_resolve_to_tested_head(self) -> None:
        (self.root / "next.txt").write_text("next\n", encoding="ascii")
        next_head = self.commit_all("next fixture")
        environment = self.github_environment(
            ref_type="branch",
            ref_name="feat/release",
            ref="refs/heads/feat/release",
            sha=self.first_head,
        )

        with self.assertRaises(provenance.ReleaseProvenanceError) as error:
            provenance.validate_release_provenance(self.root, PACKAGE_REF, environment)

        self.assertEqual(error.exception.code, "github_head_mismatch")
        self.assertNotEqual(next_head, self.first_head)

    def test_partial_or_spoofed_github_context_fails_closed(self) -> None:
        cases = (
            {"GITHUB_REF_TYPE": "tag"},
            {"GITHUB_ACTIONS": "false"},
            {"GITHUB_ACTIONS": "true", "GITHUB_REF_TYPE": "tag"},
        )
        for environment in cases:
            with self.subTest(environment=environment):
                with self.assertRaises(provenance.ReleaseProvenanceError) as error:
                    provenance.validate_release_provenance(
                        self.root, PACKAGE_REF, environment
                    )
                self.assertIn(
                    error.exception.code,
                    {"incomplete_github_context", "invalid_github_context"},
                )


if __name__ == "__main__":
    unittest.main()
