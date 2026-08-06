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


SCRIPT_ROOT = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_ROOT.parent
sys.path.insert(0, str(SCRIPT_ROOT))

import check_x_publishing_contract as checker  # noqa: E402


class StableSemverTest(unittest.TestCase):
    def test_accepts_stable_semver(self) -> None:
        for version in ("0.0.0", "1.0.0", "12.34.56"):
            with self.subTest(version=version):
                self.assertIsNotNone(checker.SEMVER_PATTERN.fullmatch(version))

    def test_rejects_leading_zero_versions(self) -> None:
        for version in ("01.0.0", "1.01.0", "1.0.01"):
            with self.subTest(version=version):
                self.assertIsNone(checker.SEMVER_PATTERN.fullmatch(version))

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
