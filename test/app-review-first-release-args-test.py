#!/usr/bin/env python3
"""first_release_args.py is baseline-driven: first-release vs update argv."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "app-review"))

import first_release_args  # noqa: E402


class FirstReleaseArgsTests(unittest.TestCase):
    def test_first_release_manifest_emits_the_flag(self):
        manifest = json.loads(
            (ROOT / "tools" / "app-review" / "manifests" / "0.1.17.json").read_text()
        )
        self.assertEqual(first_release_args.first_release_args(manifest), ["--first-release"])

    def test_update_manifest_emits_no_flag(self):
        self.assertEqual(
            first_release_args.first_release_args(
                {
                    "candidate": {
                        "version": "0.1.19",
                        "build": "21.1",
                        "baselineVersion": "0.1.17",
                        "sourceCommit": "a" * 40,
                        "releaseType": "AFTER_APPROVAL",
                    }
                }
            ),
            [],
        )

    def test_update_without_baseline_is_refused(self):
        with self.assertRaisesRegex(ValueError, "baselineVersion"):
            first_release_args.first_release_args(
                {"candidate": {"version": "0.1.19", "build": "21.1"}}
            )

    def test_cli_prints_the_flag_for_the_live_first_release_manifest(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "app-review" / "first_release_args.py")],
            cwd=ROOT,
            env={**os.environ, "EDDIES_APP_REVIEW_VERSION": "0.1.17"},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "--first-release\n")


if __name__ == "__main__":
    unittest.main()
