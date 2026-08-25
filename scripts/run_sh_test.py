#!/usr/bin/env python3
"""Regression tests for the pinned fkst-framework runner contract."""

from __future__ import annotations

import os
import signal
import shlex
import shutil
import stat
import subprocess
import tempfile
import time
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
if [ "${FAKE_ASSERT_OFFICIAL_READONLY:-0}" = "1" ]; then
  expect_package_root=false
  for argument in "$@"; do
    if [ "$expect_package_root" = true ]; then
      case "$argument" in
        */official/export/fkst-hosted/packages/github-proxy)
          if [ ! -r "$argument/main.lua" ]; then
            echo "official package root is not readable: $argument" >&2
            exit 96
          fi
          if touch "$argument/.write-probe-$$" 2>/dev/null; then
            rm -f "$argument/.write-probe-$$"
            echo "official package root is writable: $argument" >&2
            exit 95
          fi
          ;;
      esac
      expect_package_root=false
    elif [ "$argument" = "--package-root" ]; then
      expect_package_root=true
    fi
  done
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
        return subprocess.run(
            [str(self.root / "scripts/run.sh"), command],
            cwd=self.root,
            env=self.runner_environment(actual_pin, **extra_env),
            capture_output=True,
            check=False,
            text=True,
        )

    def runner_environment(self, actual_pin: str, **extra_env: str) -> dict[str, str]:
        return {
            "PATH": os.environ.get("PATH", ""),
            "BIN": str(self.framework),
            "FAKE_FRAMEWORK_SOURCE_SHA": actual_pin,
            "FAKE_ENGINE_VER": actual_pin[:12],
            "FKST_FRAMEWORK_SOURCE_ROOT": str(self.source),
            **extra_env,
        }

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
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        fake_git = tool_bin / "git"
        fake_git.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
printf 'git:%s\\n' "$*" >> "${{FAKE_COMMAND_LOG:?}}"
if [ "${{3:-}}" = "fetch" ] && [ -n "${{FAKE_GIT_FETCH_BARRIER_DIR:-}}" ]; then
  mkdir -p "$FAKE_GIT_FETCH_BARRIER_DIR"
  touch "$FAKE_GIT_FETCH_BARRIER_DIR/$$"
  barrier_attempt=0
  while [ "$(find "$FAKE_GIT_FETCH_BARRIER_DIR" -type f | wc -l | tr -d ' ')" -lt 2 ]; do
    barrier_attempt=$((barrier_attempt + 1))
    if [ "$barrier_attempt" -gt 250 ]; then
      echo "git fetch barrier timed out" >&2
      exit 87
    fi
    sleep 0.02
  done
fi
if [ "${{3:-}}" = "archive" ] && [ -n "${{FAKE_GIT_ARCHIVE_COUNTER:-}}" ]; then
  archive_count=0
  if [ -f "$FAKE_GIT_ARCHIVE_COUNTER" ]; then
    archive_count="$(sed -n '1p' "$FAKE_GIT_ARCHIVE_COUNTER")"
  fi
  archive_count=$((archive_count + 1))
  printf '%s\\n' "$archive_count" > "$FAKE_GIT_ARCHIVE_COUNTER"
  if [ "$archive_count" = "${{FAKE_GIT_FAIL_ARCHIVE_CALL:-0}}" ]; then
    echo "injected git archive failure: call=$archive_count" >&2
    exit 86
  fi
fi
exec {shlex.quote(real_git)} "$@"
""",
            encoding="ascii",
        )
        fake_git.chmod(
            fake_git.stat().st_mode
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

    def test_official_export_is_unique_read_only_and_ignores_upstream_worktree_changes(self) -> None:
        official_source, official_ref = self.create_official_source()
        proxy = official_source / "packages/github-proxy"
        (proxy / "main.lua").write_text("return 'dirty'\n", encoding="ascii")
        (proxy / "injected.lua").write_text("return 'untracked'\n", encoding="ascii")
        cache_sentinel = self.root / ".fkst/cache/user-sentinel"
        official_sentinel = self.root / ".fkst/official/user-sentinel"
        cache_sentinel.parent.mkdir(parents=True)
        official_sentinel.parent.mkdir(parents=True)
        cache_sentinel.write_text("keep\n", encoding="ascii")
        official_sentinel.write_text("keep\n", encoding="ascii")
        options = {
            "FKST_OFFICIAL_PACKAGE_SOURCE_URL": str(official_source),
            "FKST_OFFICIAL_PACKAGE_SOURCE_REF": official_ref,
        }
        result = self.run_runner(self.tracked_pin, "export-official", **options)

        self.assertEqual(result.returncode, 0, result.stderr)
        roots = [
            Path(line.removeprefix("official_package_root="))
            for line in result.stdout.splitlines()
            if line.startswith("official_package_root=")
        ]
        self.assertEqual(len(roots), 1, result.stdout)
        exported = roots[0]
        self.assertTrue(exported.is_dir())
        self.assertIn(self.root / ".fkst/official/exports", exported.parents)
        self.assertEqual(
            exported.stat().st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH),
            0,
        )
        exported_proxy = exported / "packages/github-proxy"
        self.assertEqual(
            (exported_proxy / "main.lua").read_text(encoding="ascii"),
            "return 'tracked'\n",
        )
        self.assertFalse((exported_proxy / "injected.lua").exists())
        self.assertEqual(cache_sentinel.read_text(encoding="ascii"), "keep\n")
        self.assertEqual(official_sentinel.read_text(encoding="ascii"), "keep\n")
        self.assertEqual(list((self.root / ".fkst/run").glob("invocation.*")), [])

    def test_official_export_signal_cleans_pending_persistent_artifact(self) -> None:
        official_source, official_ref = self.create_official_source()
        tool_bin = self.root / "interrupt-bin"
        tool_bin.mkdir()
        started = self.root / "cp-started"
        real_cp = shutil.which("cp")
        self.assertIsNotNone(real_cp)
        fake_cp = tool_bin / "cp"
        fake_cp.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
if [ -n "${{FAKE_CP_STARTED:-}}" ]; then
  touch "$FAKE_CP_STARTED"
  trap 'exit 143' HUP INT TERM
  while true; do
    sleep 0.05
  done
fi
exec {shlex.quote(real_cp)} "$@"
""",
            encoding="ascii",
        )
        fake_cp.chmod(
            fake_cp.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
        )
        process = subprocess.Popen(
            [str(self.root / "scripts/run.sh"), "export-official"],
            cwd=self.root,
            env=self.runner_environment(
                self.tracked_pin,
                PATH=f"{tool_bin}{os.pathsep}{os.environ.get('PATH', '')}",
                FAKE_CP_STARTED=str(started),
                FKST_OFFICIAL_PACKAGE_SOURCE_URL=str(official_source),
                FKST_OFFICIAL_PACKAGE_SOURCE_REF=official_ref,
            ),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )

        try:
            deadline = time.monotonic() + 10
            while not started.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(started.exists(), "export did not reach the persistent copy stage")
            os.killpg(process.pid, signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0, stdout + stderr)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)

        export_parent = self.root / ".fkst/official/exports"
        artifacts = list(export_parent.iterdir()) if export_parent.exists() else []
        self.assertEqual(artifacts, [])
        self.assertEqual(list((self.root / ".fkst/run").glob("invocation.*")), [])

    def test_formal_gate_skips_local_env_and_reports_locked_provenance_in_order(self) -> None:
        official_source, official_ref, tool_bin = self.prepare_formal_gate_fixture()
        command_log = self.root / "formal-command.log"
        cache_sentinel = self.root / ".fkst/cache/user-sentinel"
        official_sentinel = self.root / ".fkst/official/user-sentinel"
        cache_sentinel.parent.mkdir(parents=True)
        official_sentinel.parent.mkdir(parents=True)
        cache_sentinel.write_text("keep\n", encoding="ascii")
        official_sentinel.write_text("keep\n", encoding="ascii")
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
            FAKE_ASSERT_OFFICIAL_READONLY="1",
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
        official_fetches = [
            line
            for line in calls.splitlines()
            if line.startswith("git:-C ")
            and " fetch --no-tags --depth 1 " in line
        ]
        official_inits = [
            line
            for line in calls.splitlines()
            if line.startswith("git:-C ")
            and line.endswith(" init --bare -q")
        ]
        official_archives = [
            line
            for line in calls.splitlines()
            if line.startswith("git:-C ")
            and " archive --format=tar " in line
        ]
        self.assertEqual(len(official_fetches), 1, official_fetches)
        self.assertEqual(len(official_inits), 1, official_inits)
        self.assertEqual(len(official_archives), 1, official_archives)
        fetch_args = shlex.split(official_fetches[0].removeprefix("git:"))
        source_root = Path(fetch_args[1])
        self.assertEqual(fetch_args[0], "-C")
        self.assertIn(self.root / ".fkst/run", source_root.parents)
        self.assertEqual(source_root.parent.name, "official")
        self.assertTrue(source_root.parents[1].name.startswith("invocation."))
        package_roots = {
            Path(tokens[index + 1])
            for line in calls.splitlines()
            if line.startswith("framework:")
            for tokens in [shlex.split(line.removeprefix("framework:"))]
            for index, token in enumerate(tokens[:-1])
            if token == "--package-root"
            and tokens[index + 1].endswith(
                "/official/export/fkst-hosted/packages/github-proxy"
            )
        }
        self.assertEqual(len(package_roots), 1, package_roots)
        self.assertFalse(source_root.parent.exists())
        self.assertEqual(cache_sentinel.read_text(encoding="ascii"), "keep\n")
        self.assertEqual(official_sentinel.read_text(encoding="ascii"), "keep\n")

    def test_formal_gate_fails_closed_and_cleans_up_when_export_fails(self) -> None:
        _, _, tool_bin = self.prepare_formal_gate_fixture()
        command_log = self.root / "failed-export-command.log"
        archive_counter = self.root / "archive-counter.txt"

        result = self.run_runner(
            self.tracked_pin,
            "formal-gate",
            PATH=f"{tool_bin}{os.pathsep}{os.environ.get('PATH', '')}",
            FAKE_COMMAND_LOG=str(command_log),
            FAKE_GIT_ARCHIVE_COUNTER=str(archive_counter),
            FAKE_GIT_FAIL_ARCHIVE_CALL="1",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("injected git archive failure: call=1", result.stderr)
        self.assertNotIn("formal_gate_status=passed", result.stdout)
        self.assertEqual(archive_counter.read_text(encoding="ascii"), "1\n")
        calls = command_log.read_text(encoding="utf-8")
        self.assertEqual(
            calls.count(" fetch --no-tags --depth 1 "),
            1,
        )
        self.assertNotIn("framework:test --project-root", calls)
        fetch_line = next(
            line
            for line in calls.splitlines()
            if line.startswith("git:-C ")
            and " fetch --no-tags --depth 1 " in line
        )
        source_root = Path(shlex.split(fetch_line.removeprefix("git:"))[1])
        self.assertFalse(source_root.parent.exists())

    def test_concurrent_formal_gates_use_disjoint_official_workspaces(self) -> None:
        _, _, tool_bin = self.prepare_formal_gate_fixture()
        barrier = self.root / "fetch-barrier"
        processes: list[tuple[subprocess.Popen[str], Path]] = []
        for index in range(2):
            command_log = self.root / f"concurrent-{index}.log"
            process = subprocess.Popen(
                [str(self.root / "scripts/run.sh"), "formal-gate"],
                cwd=self.root,
                env=self.runner_environment(
                    self.tracked_pin,
                    PATH=f"{tool_bin}{os.pathsep}{os.environ.get('PATH', '')}",
                    FAKE_COMMAND_LOG=str(command_log),
                    FAKE_GIT_FETCH_BARRIER_DIR=str(barrier),
                    FAKE_ASSERT_OFFICIAL_READONLY="1",
                ),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            processes.append((process, command_log))

        outputs: list[tuple[str, str]] = []
        try:
            for process, _ in processes:
                outputs.append(process.communicate(timeout=40))
        finally:
            for process, _ in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

        source_roots = set()
        package_roots = set()
        for (process, command_log), (stdout, stderr) in zip(processes, outputs):
            self.assertEqual(process.returncode, 0, stderr)
            self.assertIn("formal_gate_status=passed", stdout)
            calls = command_log.read_text(encoding="utf-8")
            fetches = [
                line
                for line in calls.splitlines()
                if line.startswith("git:-C ")
                and " fetch --no-tags --depth 1 " in line
            ]
            self.assertEqual(len(fetches), 1, fetches)
            source_roots.add(
                Path(shlex.split(fetches[0].removeprefix("git:"))[1])
            )
            for line in calls.splitlines():
                if not line.startswith("framework:"):
                    continue
                tokens = shlex.split(line.removeprefix("framework:"))
                for argument_index, token in enumerate(tokens[:-1]):
                    candidate = tokens[argument_index + 1]
                    if token == "--package-root" and candidate.endswith(
                        "/official/export/fkst-hosted/packages/github-proxy"
                    ):
                        package_roots.add(Path(candidate))

        self.assertEqual(len(source_roots), 2, source_roots)
        self.assertEqual(len(package_roots), 2, package_roots)
        for source_root in source_roots:
            self.assertFalse(source_root.parent.exists())

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
