#!/usr/bin/env python3
"""Attest the clean repository HEAD and release tag used by the formal gate."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, NoReturn

import check_x_publishing_contract as contract_checker


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = Path("manifests/auto-twitter-marketing.json")
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
GITHUB_CONTEXT_KEYS = (
    "GITHUB_REF_TYPE",
    "GITHUB_REF_NAME",
    "GITHUB_REF",
    "GITHUB_SHA",
)


class ReleaseProvenanceError(Exception):
    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


def fail(code: str, detail: str) -> NoReturn:
    raise ReleaseProvenanceError(code, detail)


@dataclass(frozen=True)
class ReleaseProvenance:
    package_ref: str
    tested_head: str
    release_context: str
    release_tag_commit: str


def run_git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ("git", "-C", str(root), *arguments),
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        fail("git_inspection_failed", " ".join(arguments))
    return result.stdout.strip()


def read_package_ref(root: Path) -> str:
    path = root / MANIFEST_PATH
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail("missing_release_manifest", MANIFEST_PATH.as_posix())
    except (OSError, json.JSONDecodeError):
        fail("invalid_release_manifest", MANIFEST_PATH.as_posix())
    if not isinstance(manifest, dict):
        fail("invalid_release_manifest", MANIFEST_PATH.as_posix())
    try:
        return contract_checker.validate_package_descriptors(manifest.get("packages"))
    except contract_checker.ContractCheckError as error:
        fail("invalid_release_manifest", error.code)


def inspect_clean_head(root: Path) -> str:
    top_level = Path(run_git(root, "rev-parse", "--show-toplevel")).resolve()
    if top_level != root.resolve():
        fail("unexpected_repository_root", str(top_level))
    head = run_git(root, "rev-parse", "--verify", "HEAD^{commit}")
    if SHA_PATTERN.fullmatch(head) is None:
        fail("invalid_repository_head", head)
    if run_git(root, "status", "--porcelain=v1", "--untracked-files=all"):
        fail("dirty_repository", "formal-gate requires a clean tracked and untracked worktree")
    return head


def resolve_revision(root: Path, revision: str, error_code: str) -> str:
    try:
        commit = run_git(root, "rev-parse", "--verify", f"{revision}^{{commit}}")
    except ReleaseProvenanceError:
        fail(error_code, revision)
    if SHA_PATTERN.fullmatch(commit) is None:
        fail(error_code, revision)
    return commit


def resolve_optional_release_tag(root: Path, package_ref: str) -> str | None:
    result = subprocess.run(
        (
            "git",
            "-C",
            str(root),
            "rev-parse",
            "--verify",
            f"refs/tags/{package_ref}^{{commit}}",
        ),
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        return None
    commit = result.stdout.strip()
    if SHA_PATTERN.fullmatch(commit) is None:
        fail("invalid_release_tag", package_ref)
    return commit


def read_github_context(environment: Mapping[str, str]) -> dict[str, str] | None:
    actions = environment.get("GITHUB_ACTIONS")
    supplied = {key: environment.get(key, "") for key in GITHUB_CONTEXT_KEYS}
    if actions is None:
        if any(supplied.values()):
            fail("incomplete_github_context", "GITHUB_ACTIONS is not set")
        return None
    if actions != "true":
        fail("invalid_github_context", "GITHUB_ACTIONS must be true when defined")
    missing = [key for key, value in supplied.items() if not value]
    if missing:
        fail("incomplete_github_context", ",".join(missing))
    if supplied["GITHUB_REF_TYPE"] not in {"branch", "tag"}:
        fail("invalid_github_ref_type", supplied["GITHUB_REF_TYPE"])
    return supplied


def validate_release_provenance(
    root: Path,
    package_ref: str,
    environment: Mapping[str, str],
) -> ReleaseProvenance:
    head = inspect_clean_head(root)
    release_tag_commit = resolve_optional_release_tag(root, package_ref)
    github = read_github_context(environment)

    if github is None:
        if release_tag_commit == head:
            context = "local-tagged"
        elif release_tag_commit is None:
            context = "local-pretag"
        else:
            context = "local-branch"
        return ReleaseProvenance(
            package_ref=package_ref,
            tested_head=head,
            release_context=context,
            release_tag_commit=release_tag_commit or "missing",
        )

    github_commit = resolve_revision(
        root, github["GITHUB_SHA"], "invalid_github_sha"
    )
    if github_commit != head:
        fail(
            "github_head_mismatch",
            f"github_sha={github_commit} tested_head={head}",
        )

    if github["GITHUB_REF_TYPE"] == "branch":
        return ReleaseProvenance(
            package_ref=package_ref,
            tested_head=head,
            release_context="github-branch",
            release_tag_commit=release_tag_commit or "missing",
        )

    expected_ref = f"refs/tags/{package_ref}"
    if github["GITHUB_REF_NAME"] != package_ref or github["GITHUB_REF"] != expected_ref:
        fail(
            "release_tag_manifest_mismatch",
            f"package_ref={package_ref} github_ref={github['GITHUB_REF']}",
        )
    if release_tag_commit is None:
        fail("missing_release_tag", package_ref)
    if release_tag_commit != head:
        fail(
            "release_tag_head_mismatch",
            f"tag_commit={release_tag_commit} tested_head={head}",
        )
    return ReleaseProvenance(
        package_ref=package_ref,
        tested_head=head,
        release_context="github-tag",
        release_tag_commit=release_tag_commit,
    )


def main() -> int:
    package_ref = read_package_ref(ROOT)
    provenance = validate_release_provenance(ROOT, package_ref, os.environ)
    print(
        "RELEASE_PROVENANCE_CHECK_OK "
        f"package_ref={provenance.package_ref} "
        f"tested_head={provenance.tested_head} "
        f"release_context={provenance.release_context} "
        f"release_tag_commit={provenance.release_tag_commit}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReleaseProvenanceError as error:
        print(
            f"RELEASE_PROVENANCE_CHECK_FAILED code={error.code} detail={error.detail}",
            file=sys.stderr,
        )
        raise SystemExit(1)
