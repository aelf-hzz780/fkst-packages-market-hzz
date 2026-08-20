#!/usr/bin/env python3
"""Regression tests for the offline X publishing contract checker."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_ROOT = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_ROOT.parent
sys.path.insert(0, str(SCRIPT_ROOT))

import check_x_publishing_contract as checker  # noqa: E402


class SemverValidationTest(unittest.TestCase):
    def test_accepts_stable_semver(self) -> None:
        for version in ("0.0.0", "1.0.0", "12.34.56"):
            with self.subTest(version=version):
                self.assertIsNotNone(checker.SEMVER_PATTERN.fullmatch(version))

    def test_rejects_leading_zero_versions(self) -> None:
        for version in ("01.0.0", "1.01.0", "1.0.01"):
            with self.subTest(version=version):
                self.assertIsNone(checker.SEMVER_PATTERN.fullmatch(version))

    def test_package_refs_accept_stable_and_canonical_prerelease_semver(self) -> None:
        for version in ("v0.3.0", "v0.3.0-rc.1", "v12.34.56-alpha-beta.7"):
            with self.subTest(version=version):
                descriptors = [
                    f"aelf-hzz780/fkst-packages-market-hzz@{version}:packages/{package}"
                    for package in checker.EXPECTED_PACKAGES
                ]
                self.assertEqual(checker.validate_package_descriptors(descriptors), version)

    def test_package_refs_reject_noncanonical_prerelease_or_build_metadata(self) -> None:
        for version in (
            "v0.3.0-rc.01",
            "v0.3.0-rc..1",
            "v0.3.0-",
            "v0.3.0+build.1",
            "v01.3.0-rc.1",
        ):
            with self.subTest(version=version):
                descriptors = [
                    f"aelf-hzz780/fkst-packages-market-hzz@{version}:packages/{package}"
                    for package in checker.EXPECTED_PACKAGES
                ]
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_package_descriptors(descriptors)
                self.assertEqual(error.exception.code, "mutable_or_invalid_package_ref")

    def test_release_manifest_uses_one_rc_semver_ref(self) -> None:
        self.assertEqual(checker.validate_release_manifest(), "v0.3.0-rc.4")

    def test_official_package_source_pins_local_tests_and_supported_hosted_ref(self) -> None:
        package_ref = checker.validate_release_manifest()
        source_ref = checker.validate_official_source_pin()
        official_tree = checker.validate_official_lock(source_ref)
        self.assertEqual(source_ref, "6fe5f82f76f6b2c02058488587f5f6281c203cf3")
        self.assertRegex(official_tree, r"^sha256-[0-9a-f]{64}$")
        self.assertEqual(
            checker.validate_official_release_descriptors(source_ref),
            checker.HOSTED_SHADOW_REF_CLASS,
        )
        checker.validate_active_business_release_docs(package_ref)
        checker.validate_acceptance_official_tree(official_tree)

    def test_active_business_release_docs_must_match_manifest_ref(self) -> None:
        package_ref = "v0.3.0-rc.4"
        descriptor = (
            "aelf-hzz780/fkst-packages-market-hzz@"
            f"{package_ref}:manifests/auto-twitter-marketing.json"
        )
        runbook_link = f"hzz780-{package_ref}-acceptance.md"
        with tempfile.TemporaryDirectory(prefix="business-release-docs-") as temporary:
            root = Path(temporary)
            for relative_path in checker.ACTIVE_BUSINESS_RELEASE_DOCS:
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                if relative_path == checker.ACTIVE_PACKAGE_README_PATH:
                    path.write_text(runbook_link + "\n", encoding="utf-8")
                else:
                    path.write_text(descriptor + "\n", encoding="utf-8")

            with mock.patch.object(checker, "ROOT", root):
                checker.validate_active_business_release_docs(package_ref)

                readme = root / checker.ACTIVE_BUSINESS_RELEASE_DOCS[0]
                readme.write_text(
                    descriptor.replace(package_ref, "v0.3.0-rc.3") + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_active_business_release_docs(package_ref)
                self.assertEqual(error.exception.code, "business_release_ref_drift")

                readme.write_text(descriptor + "\n", encoding="utf-8")
                package_readme = root / checker.ACTIVE_PACKAGE_README_PATH
                package_readme.write_text(
                    runbook_link.replace(package_ref, "v0.3.0-rc.3") + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_active_business_release_docs(package_ref)
                self.assertEqual(error.exception.code, "business_release_ref_drift")

    def test_acceptance_runbook_must_match_locked_official_tree(self) -> None:
        official_tree = "sha256-" + "a" * 64
        with tempfile.TemporaryDirectory(prefix="official-tree-doc-") as temporary:
            root = Path(temporary)
            path = root / checker.ACTIVE_ACCEPTANCE_PATH
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "pinned official commit and tree\n"
                + official_tree
                + "\ncontent-digest: sha256-"
                + "c" * 64
                + "\n",
                encoding="utf-8",
            )

            with mock.patch.object(checker, "ROOT", root):
                checker.validate_acceptance_official_tree(official_tree)

                path.write_text(
                    "pinned official commit and tree\n"
                    + official_tree
                    + "\n固定 official commit 和 tree\nsha256-"
                    + "b" * 64
                    + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_acceptance_official_tree(official_tree)
                self.assertEqual(error.exception.code, "official_tree_doc_drift")

    def test_official_release_descriptor_rejects_raw_sha_and_other_branches(self) -> None:
        source_ref = "a" * 40
        expected = "ChronoAIProject/fkst-hosted@packages:packages/github-proxy"
        blocker = (
            "Do not start a Stable Hosted Session while "
            "stable_hosted_release=blocked."
        )
        with tempfile.TemporaryDirectory(prefix="official-descriptor-check-") as temporary:
            root = Path(temporary)
            for relative_path in checker.OFFICIAL_DESCRIPTOR_DOCS:
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                suffix = f"\nofficial source SHA `{source_ref}`\n" \
                    if relative_path == checker.OFFICIAL_DESCRIPTOR_DOCS[-1] else "\n"
                path.write_text(expected + "\n" + blocker + suffix, encoding="utf-8")
            run_script = root / checker.RUN_SCRIPT_PATH
            run_script.parent.mkdir(parents=True, exist_ok=True)
            run_script.write_text(
                f'DEFAULT_OFFICIAL_SOURCE_URL="{checker.OFFICIAL_SOURCE_URL}"\n'
                f'DEFAULT_OFFICIAL_SOURCE_REF="{source_ref}"\n',
                encoding="utf-8",
            )
            env_example = root / checker.ENV_EXAMPLE_PATH
            env_example.parent.mkdir(parents=True, exist_ok=True)
            env_example.write_text(
                f"# FKST_OFFICIAL_PACKAGE_SOURCE_REF={source_ref}\n", encoding="utf-8"
            )

            with mock.patch.object(checker, "ROOT", root):
                self.assertEqual(
                    checker.validate_official_release_descriptors(source_ref),
                    checker.HOSTED_SHADOW_REF_CLASS,
                )
                readme = root / checker.OFFICIAL_DESCRIPTOR_DOCS[0]
                readme.write_text(expected + "\n", encoding="utf-8")
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_official_release_descriptors(source_ref)
                self.assertEqual(
                    error.exception.code, "missing_stable_hosted_blocker_guidance"
                )

                readme.write_text(
                    expected + "\n" + blocker
                    + "\nStop the RC Session before starting stable.\n",
                    encoding="utf-8",
                )
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_official_release_descriptors(source_ref)
                self.assertEqual(
                    error.exception.code, "stable_hosted_blocker_contradiction"
                )

                readme.write_text(
                    expected.replace("@packages:", f"@{source_ref}:")
                    + "\n" + blocker + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_official_release_descriptors(source_ref)
                self.assertEqual(error.exception.code, "hosted_raw_sha_unsupported")

                readme.write_text(
                    expected + "\n" + expected.replace("@packages:", "@main:")
                    + "\n" + blocker + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_official_release_descriptors(source_ref)
                self.assertEqual(error.exception.code, "unsupported_hosted_official_ref")

    def test_official_lock_rejects_resolved_ref_drift(self) -> None:
        source_ref = "a" * 40
        with tempfile.TemporaryDirectory(prefix="official-lock-check-") as temporary:
            root = Path(temporary)
            lock_path = root / checker.EXTERNAL_LOCK_PATH
            lock_path.write_text(
                "[[external_source]]\n"
                'id = "fkst-official"\n'
                f'git = "{checker.OFFICIAL_SOURCE_URL}"\n'
                "libraries = []\n\n"
                "[external_source.intent]\n"
                f'rev = "{source_ref}"\n\n'
                "[external_source.resolved]\n"
                f'rev = "{"b" * 40}"\n'
                f'tree_sha256 = "sha256-{"c" * 64}"\n',
                encoding="utf-8",
            )
            with mock.patch.object(checker, "ROOT", root):
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_official_lock(source_ref)
                self.assertEqual(error.exception.code, "official_lock_drift")

    def test_contract_and_generator_versions_remain_stable_only(self) -> None:
        source_lock = json.loads((REPO_ROOT / checker.LOCK_PATH).read_text(encoding="utf-8"))
        for field in ("contractVersion", "generatorVersion"):
            with self.subTest(field=field):
                with self.assertRaises(checker.ContractCheckError) as error:
                    checker.validate_lock({**source_lock, field: "1.2.3-rc.1"})
                self.assertEqual(error.exception.code, "invalid_lock")

    def test_rejects_mutable_or_mixed_package_refs(self) -> None:
        mutable = [
            "aelf-hzz780/fkst-packages-market-hzz@feature/quote-post-publishing:packages/x-publisher",
            "aelf-hzz780/fkst-packages-market-hzz@feature/quote-post-publishing:packages/github-auto-twitter-marketing",
            "aelf-hzz780/fkst-packages-market-hzz@feature/quote-post-publishing:packages/marketing-radar",
        ]
        with self.assertRaises(checker.ContractCheckError) as mutable_error:
            checker.validate_package_descriptors(mutable)
        self.assertEqual(mutable_error.exception.code, "mutable_or_invalid_package_ref")

        mixed = [
            "aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.4:packages/x-publisher",
            "aelf-hzz780/fkst-packages-market-hzz@v0.3.0-rc.4:packages/github-auto-twitter-marketing",
            "aelf-hzz780/fkst-packages-market-hzz@v0.2.2:packages/marketing-radar",
        ]
        with self.assertRaises(checker.ContractCheckError) as mixed_error:
            checker.validate_package_descriptors(mixed)
        self.assertEqual(mixed_error.exception.code, "inconsistent_manifest_packages")

    def test_cli_rejects_a_temporary_malformed_lock_without_credentials(self) -> None:
        source_lock = json.loads((REPO_ROOT / checker.LOCK_PATH).read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory(prefix="x-publishing-checker-") as temporary:
            root = Path(temporary)
            script = root / "scripts/check_x_publishing_contract.py"
            script.parent.mkdir(parents=True)
            shutil.copy2(SCRIPT_ROOT / "check_x_publishing_contract.py", script)
            for relative_path in checker.GENERATED_PATHS:
                destination = root / relative_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPO_ROOT / relative_path, destination)

            lock_path = root / checker.LOCK_PATH
            lock_path.parent.mkdir(parents=True)
            for version in ("01.0.0", "1.01.0", "1.0.01"):
                with self.subTest(version=version):
                    lock_path.write_text(
                        json.dumps({**source_lock, "contractVersion": version}, indent=2) + "\n",
                        encoding="utf-8",
                    )
                    result = subprocess.run(
                        [sys.executable, str(script)],
                        cwd=root,
                        env={"PATH": os.environ.get("PATH", "")},
                        capture_output=True,
                        check=False,
                        text=True,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("code=invalid_lock", result.stderr)


if __name__ == "__main__":
    unittest.main()
