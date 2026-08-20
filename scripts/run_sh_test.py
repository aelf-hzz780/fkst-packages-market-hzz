#!/usr/bin/env python3
"""Regression tests for the pinned fkst-framework runner contract."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent

OTHER_PIN = "a8029a9ad316ed43b414824aeadac49e14292c80"
FORMAL_TREE = f"sha256-{'b' * 64}"


class FrameworkPinValidationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="fkst-runner-pin-")
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / ".fkst").mkdir()
        shutil.copy2(SCRIPT_ROOT / "run.sh", self.root / "scripts/run.sh")
        self.source = self.root / "fkst-substrate"
        self.source.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.source, check=True)
        self.tracked_pin = self.commit_source("tracked fixture")
        (self.root / ".fkst/substrate-ref").write_text(
            f"{self.tracked_pin}\n", encoding="ascii"
        )
        handler = (
            self.root
            / "packages/github-auto-twitter-marketing/departments/optional_pr_event_sink/main.lua"
        )
        handler.parent.mkdir(parents=True)
        handler.write_text("return {}\n", encoding="ascii")
        self.framework = self.root / "fake-fkst-framework"
        self.framework.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "init-package-repo" ]; then
  if [ "${FAKE_PIN_PROBE_FAILURE:-0}" = "1" ]; then
    echo "probe failed" >&2
    exit 19
  fi
  echo "init-package-repo repo=$PWD"
  echo "init-package-repo substrate_ref=${FAKE_FRAMEWORK_SOURCE_SHA:?}"
  echo "init-package-repo force=false"
  exit 0
fi
if [ "${1:-}" = "run" ]; then
  case "${FAKE_PROVENANCE_MODE:-clean}" in
    clean)
      echo "TIMESTAMP=2026-08-17T00:00:00Z LEVEL=info EVENT=code_provenance ENGINE_VER=${FAKE_ENGINE_VER:?} PKG_VERS=github-auto-twitter-marketing@test" >&2
      ;;
    missing)
      echo "TIMESTAMP=2026-08-17T00:00:00Z LEVEL=info MSG=probe-complete" >&2
      ;;
    *)
      echo "unknown FAKE_PROVENANCE_MODE: ${FAKE_PROVENANCE_MODE}" >&2
      exit 98
      ;;
  esac
  exit 0
fi
if [ -n "${FAKE_COMMAND_LOG:-}" ]; then
  printf 'framework:%s\n' "$*" >> "$FAKE_COMMAND_LOG"
fi
case "${1:-}" in
  deps|test|conformance)
    exit 0
    ;;
esac
echo "unexpected fake framework command: ${1:-}" >&2
exit 97
""",
            encoding="ascii",
        )
        self.framework.chmod(
            self.framework.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_runner(
        self, actual_pin: str, command: str = "verify-framework", **extra_env: str
    ) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": os.environ.get("PATH", ""),
            "BIN": str(self.framework),
            "FAKE_FRAMEWORK_SOURCE_SHA": actual_pin,
            "FAKE_ENGINE_VER": actual_pin[:12],
            "FKST_FRAMEWORK_SOURCE_ROOT": str(self.source),
            **extra_env,
        }
        return subprocess.run(
            [str(self.root / "scripts/run.sh"), command],
            cwd=self.root,
            env=env,
            capture_output=True,
            check=False,
            text=True,
        )

    def create_official_source(self) -> tuple[Path, str]:
        source = self.root / "official-source"
        source.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=source, check=True)
        (source / "fkst.workspace.toml").write_text("[workspace]\n", encoding="ascii")
        (source / "fkst.lock").write_text("# fixture\n", encoding="ascii")
        proxy = source / "packages/github-proxy"
        proxy.mkdir(parents=True)
        (proxy / "main.lua").write_text("return 'tracked'\n", encoding="ascii")
        for name in (
            "contract", "forge", "workflow", "testkit", "devloop", "github-proxy-effects"
        ):
            library = source / "libraries" / name
            library.mkdir(parents=True)
            (library / "marker.lua").write_text(f"return '{name}'\n", encoding="ascii")
        subprocess.run(["git", "add", "."], cwd=source, check=True)
        subprocess.run(
            ["git", "-c", "user.name=FKST Test", "-c", "user.email=fkst@example.invalid",
             "commit", "-qm", "official fixture"],
            cwd=source,
            check=True,
        )
        revision = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=source, check=True,
            capture_output=True, text=True,
        ).stdout.strip()
        return source, revision

    def prepare_formal_gate_fixture(self) -> tuple[str, str, Path]:
        official_source, official_ref = self.create_official_source()
        runner_path = self.root / "scripts/run.sh"
        runner = runner_path.read_text(encoding="utf-8")
        runner = runner.replace(
            'DEFAULT_OFFICIAL_SOURCE_URL="https://github.com/ChronoAIProject/fkst-hosted.git"',
            f'DEFAULT_OFFICIAL_SOURCE_URL="{official_source}"',
        )
        runner = runner.replace(
            'DEFAULT_OFFICIAL_SOURCE_REF="6fe5f82f76f6b2c02058488587f5f6281c203cf3"',
            f'DEFAULT_OFFICIAL_SOURCE_REF="{official_ref}"',
        )
        runner_path.write_text(runner, encoding="utf-8")

        (self.root / "fkst.lock").write_text(
            f'tree_sha256 = "{FORMAL_TREE}"\n', encoding="ascii"
        )
        (self.root / "libraries").mkdir()
        (self.root / "packages/x-publisher").mkdir()
        (self.root / "packages/marketing-radar").mkdir()

        tool_bin = self.root / "test-bin"
        tool_bin.mkdir()
        fake_python = tool_bin / "python3"
        fake_python.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf 'python:%s\\n' "$*" >> "${FAKE_COMMAND_LOG:?}"
""",
            encoding="ascii",
        )
        fake_python.chmod(
            fake_python.stat().st_mode
            | stat.S_IXUSR
            | stat.S_IXGRP
            | stat.S_IXOTH
        )
        return str(official_source), official_ref, tool_bin

    def commit_source(self, message: str) -> str:
        subprocess.run(
            ["git", "-c", "user.name=FKST Test", "-c", "user.email=fkst@example.invalid",
             "commit", "--allow-empty", "-qm", message],
            cwd=self.source,
            check=True,
        )
        return subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=self.source, check=True,
            capture_output=True, text=True,
        ).stdout.strip()

    def test_matching_binary_source_sha_is_accepted(self) -> None:
        result = self.run_runner(self.tracked_pin)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"source_sha={self.tracked_pin}", result.stdout)
        self.assertIn("source=tracked", result.stdout)
        self.assertIn(f"engine_ver={self.tracked_pin[:12]}", result.stdout)
        self.assertIn("binary_state=clean", result.stdout)
        self.assertIn(f"source_checkout={self.source.resolve()}", result.stdout)
        self.assertIn("checkout_state=clean", result.stdout)

    def test_default_rejects_binary_built_from_another_source_sha(self) -> None:
        result = self.run_runner(OTHER_PIN)

        self.assertEqual(result.returncode, 2)
        self.assertIn("fkst-framework source SHA mismatch", result.stderr)
        self.assertIn(f"expected={self.tracked_pin}", result.stderr)
        self.assertIn(f"actual={OTHER_PIN}", result.stderr)
        self.assertIn("FKST_FRAMEWORK_EXPECTED_SHA", result.stderr)

    def test_explicit_expected_sha_override_accepts_a_known_alternate_binary(self) -> None:
        alternate_pin = self.commit_source("alternate fixture")
        result = self.run_runner(
            alternate_pin,
            FKST_FRAMEWORK_EXPECTED_SHA=alternate_pin,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"source_sha={alternate_pin}", result.stdout)
        self.assertIn(f"engine_ver={alternate_pin[:12]}", result.stdout)
        self.assertIn("source=explicit-override", result.stdout)
        self.assertIn(f"tracked_sha={self.tracked_pin}", result.stdout)

    def test_probe_failure_is_closed_before_requested_framework_command_runs(self) -> None:
        result = self.run_runner(
            self.tracked_pin,
            FAKE_PIN_PROBE_FAILURE="1",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot determine fkst-framework source SHA", result.stderr)
        self.assertIn("probe failed", result.stderr)

    def test_invalid_tracked_pin_is_rejected(self) -> None:
        (self.root / ".fkst/substrate-ref").write_text("dev\n", encoding="ascii")

        result = self.run_runner(self.tracked_pin)

        self.assertEqual(result.returncode, 2)
        self.assertIn("must contain exactly one lowercase 40-character SHA", result.stderr)

    def test_dirty_source_checkout_is_rejected(self) -> None:
        (self.source / "uncommitted.txt").write_text("dirty\n", encoding="ascii")

        result = self.run_runner(self.tracked_pin)

        self.assertEqual(result.returncode, 2)
        self.assertIn("framework source checkout is dirty", result.stderr)

    def test_binary_built_while_source_was_dirty_is_rejected_after_checkout_is_clean(self) -> None:
        result = self.run_runner(
            self.tracked_pin,
            FAKE_ENGINE_VER=f"{self.tracked_pin[:12]}-dirty",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("framework binary was built from a dirty source checkout", result.stderr)
        self.assertIn(f"engine_ver={self.tracked_pin[:12]}-dirty", result.stderr)

    def test_binary_engine_version_must_match_the_reported_source_sha(self) -> None:
        result = self.run_runner(
            self.tracked_pin,
            FAKE_ENGINE_VER=OTHER_PIN[:12],
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("framework binary provenance mismatch", result.stderr)
        self.assertIn(f"source_sha={self.tracked_pin}", result.stderr)
        self.assertIn(f"engine_ver={OTHER_PIN[:12]}", result.stderr)

    def test_missing_binary_provenance_is_rejected(self) -> None:
        result = self.run_runner(
            self.tracked_pin,
            FAKE_PROVENANCE_MODE="missing",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot determine fkst-framework binary provenance", result.stderr)

    def test_mutable_official_package_source_override_is_rejected(self) -> None:
        result = self.run_runner(
            self.tracked_pin,
            FKST_OFFICIAL_PACKAGE_SOURCE_REF="packages",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "FKST_OFFICIAL_PACKAGE_SOURCE_REF must be a full lowercase 40-character SHA",
            result.stderr,
        )

    def test_unattested_custom_binary_layout_is_rejected(self) -> None:
        result = self.run_runner(self.tracked_pin, FKST_FRAMEWORK_SOURCE_ROOT="")

        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot attest framework source checkout", result.stderr)

    def test_official_export_ignores_dirty_and_untracked_cache_files(self) -> None:
        official_source, official_ref = self.create_official_source()
        options = {
            "FKST_OFFICIAL_PACKAGE_SOURCE_URL": str(official_source),
            "FKST_OFFICIAL_PACKAGE_SOURCE_REF": official_ref,
        }
        first = self.run_runner(self.tracked_pin, "export-official", **options)
        self.assertEqual(first.returncode, 0, first.stderr)

        cache_proxy = self.root / ".fkst/cache/fkst-hosted-src/packages/github-proxy"
        (cache_proxy / "main.lua").write_text("return 'dirty'\n", encoding="ascii")
        (cache_proxy / "injected.lua").write_text("return 'untracked'\n", encoding="ascii")

        second = self.run_runner(self.tracked_pin, "export-official", **options)
        self.assertEqual(second.returncode, 0, second.stderr)
        cache_head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.root / ".fkst/cache/fkst-hosted-src",
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        exported = self.root / ".fkst/official/fkst-hosted/packages/github-proxy"
        self.assertEqual(cache_head, official_ref)
        self.assertEqual((exported / "main.lua").read_text(encoding="ascii"), "return 'tracked'\n")
        self.assertFalse((exported / "injected.lua").exists())

    def test_formal_gate_skips_local_env_and_reports_locked_provenance_in_order(self) -> None:
        official_source, official_ref, tool_bin = self.prepare_formal_gate_fixture()
        command_log = self.root / "formal-command.log"
        (self.root / ".fkst/env").write_text(
            "\n".join(
                (
                    "BIN=/must/not/be/loaded",
                    f"FKST_FRAMEWORK_EXPECTED_SHA={OTHER_PIN}",
                    "FKST_OFFICIAL_PACKAGE_SOURCE_URL=/must/not/be/loaded",
                    f"FKST_OFFICIAL_PACKAGE_SOURCE_REF={OTHER_PIN}",
                )
            )
            + "\n",
            encoding="ascii",
        )

        result = self.run_runner(
            self.tracked_pin,
            "formal-gate",
            PATH=f"{tool_bin}{os.pathsep}{os.environ.get('PATH', '')}",
            FAKE_COMMAND_LOG=str(command_log),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        stages = (
            "formal_gate_stage=verify-framework",
            "formal_gate_stage=check",
            "formal_gate_stage=test",
            "formal_gate_stage=test-composed",
        )
        positions = [result.stdout.index(stage) for stage in stages]
        self.assertEqual(positions, sorted(positions))
        self.assertIn(f"tracked_official_url={official_source}", result.stdout)
        self.assertIn(f"effective_official_url={official_source}", result.stdout)
        self.assertIn(f"tracked_official_ref={official_ref}", result.stdout)
        self.assertIn(f"effective_official_ref={official_ref}", result.stdout)
        self.assertIn(f"fetched_official_sha={official_ref}", result.stdout)
        self.assertIn(f"locked_official_tree={FORMAL_TREE}", result.stdout)

        calls = command_log.read_text(encoding="utf-8")
        self.assertEqual(calls.count("check_release_provenance.py"), 2)
        self.assertIn("check_x_publishing_contract.py", calls)
        self.assertIn("framework:test --project-root", calls)
        self.assertIn("framework:conformance --project-root", calls)

    def test_formal_gate_rejects_release_pin_process_overrides(self) -> None:
        _, _, tool_bin = self.prepare_formal_gate_fixture()
        forbidden = (
            "FKST_FRAMEWORK_EXPECTED_SHA",
            "FKST_OFFICIAL_PACKAGE_SOURCE_URL",
            "FKST_OFFICIAL_PACKAGE_SOURCE_REF",
        )

        for variable in forbidden:
            with self.subTest(variable=variable):
                result = self.run_runner(
                    self.tracked_pin,
                    "formal-gate",
                    PATH=f"{tool_bin}{os.pathsep}{os.environ.get('PATH', '')}",
                    FAKE_COMMAND_LOG=str(self.root / f"{variable}.log"),
                    **{variable: "present-even-when-not-usable"},
                )

                self.assertEqual(result.returncode, 2)
                self.assertIn(
                    f"formal-gate rejects process environment override: {variable}",
                    result.stderr,
                )


class RepositoryFormalGateContractTest(unittest.TestCase):
    def test_release_ci_uses_formal_gate_and_diagnostic_keeps_override_path(self) -> None:
        workflow = (SCRIPT_ROOT.parent / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(workflow.count("scripts/run.sh formal-gate"), 1)
        self.assertIn('tags: ["v*"]', workflow)
        self.assertIn("path: .fkst/run/fkst-substrate", workflow)
        self.assertIn("FKST_FRAMEWORK_EXPECTED_SHA:", workflow)
        self.assertIn("scripts/run.sh test-composed", workflow)


if __name__ == "__main__":
    unittest.main()
