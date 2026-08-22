#!/usr/bin/env python3
"""Behavioral tests for the listing-screenshot preflight CLI."""

from __future__ import annotations

import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools" / "app-review"
PREFLIGHT = TOOLS / "screenshot_preflight.py"

sys.path.insert(0, str(TOOLS))
import core  # noqa: E402
import screenshot_preflight  # noqa: E402


def rgb8_png(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    row = bytes(rgb) * width
    raw = b"".join(b"\x00" + row for _ in range(height))
    compressed = zlib.compress(raw, 9)

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", compressed) + chunk(b"IEND", b"")


LISTING = {
    "appName": "Eddie's Wallet",
    "subtitle": "A kid-first wallet",
    "promotionalText": "Family money habits, one small step at a time.",
    "description": "A reviewed description.",
    "keywords": "kids,allowance,wallet",
    "privacyPolicyUrl": "https://eddieswallet.example/privacy",
    "supportUrl": "https://eddieswallet.example/support",
    "whatsNew": "Improved the exact candidate for review.",
}


class ScreenshotPreflightTests(unittest.TestCase):
    def write_tree(self, root: pathlib.Path, *, duplicate: bool = False, bad_dims: bool = False):
        width, height = (8, 9) if bad_dims else (8, 8)
        files = {
            "iphone-6.9-kid-home.png": rgb8_png(width, height, (255, 0, 0)),
            "iphone-6.9-parent-area.png": rgb8_png(8, 8, (255, 0, 0))
            if duplicate
            else rgb8_png(width, height, (0, 255, 0)),
        }
        upload = root / "tools/app-review/assets/screenshots/0.1.17"
        upload.mkdir(parents=True)
        relative = []
        for name, data in files.items():
            (upload / name).write_bytes(data)
            relative.append(name)
        (upload / "iap.png").write_bytes(b"iap review screenshot bytes")
        content = core.materialize_source_content(
            root,
            LISTING,
            [{"displayType": "APP_IPHONE_67", "width": 8, "height": 8, "files": relative}],
            [
                {
                    "productId": core.CLOUD_PRODUCT_IDS[0],
                    "reviewNotes": "Optional Cloud monthly plan is available from Parent.",
                    "screenshotPath": "tools/app-review/assets/screenshots/0.1.17/iap.png",
                },
                {
                    "productId": core.CLOUD_PRODUCT_IDS[1],
                    "reviewNotes": "Optional Cloud annual plan is available from Parent.",
                    "screenshotPath": "tools/app-review/assets/screenshots/0.1.17/iap.png",
                },
            ],
            "Reviewers sign in with their own Apple Account.",
            screenshot_directory=[
                "tools",
                "app-review",
                "assets",
                "screenshots",
                "0.1.17",
            ],
        )
        manifest = core.build_manifest(
            {
                "version": "0.1.17",
                "build": "19.1",
                "firstRelease": True,
                "sourceCommit": "a" * 40,
                "releaseType": "AFTER_APPROVAL",
            },
            content,
            approved_utc="2026-08-22T00:00:00Z",
            approval_statement="Captain approved the screenshot fixture.",
        )
        manifest_path = root / "tools/app-review/manifests/0.1.17.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        config = {
            "listing": {
                "screenshotDirectory": [
                    "tools",
                    "app-review",
                    "assets",
                    "screenshots",
                    "0.1.17",
                ],
                "screenshotSpecs": [
                    {
                        "displayType": "APP_IPHONE_67",
                        "width": 8,
                        "height": 8,
                        "files": [
                            "iphone-6.9-kid-home.png",
                            "iphone-6.9-parent-area.png",
                        ],
                    }
                ],
            }
        }
        config_path = root / "tools/app-review/app-review.config.json"
        config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        return manifest, config

    def test_the_committed_0_1_17_upload_sets_pass_the_public_cli(self):
        completed = subprocess.run(
            [sys.executable, str(PREFLIGHT)],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("APP_IPHONE_67", completed.stdout)
        self.assertIn("APP_IPAD_PRO_3GEN_129", completed.stdout)
        self.assertIn("files=10", completed.stdout)

    def test_distinct_rgb8_slots_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, config = self.write_tree(root)
            report = screenshot_preflight.preflight_listing_screenshots(
                root, manifest, config
            )
            self.assertEqual(report["displayTypes"][0]["displayType"], "APP_IPHONE_67")
            self.assertEqual(len(report["displayTypes"][0]["files"]), 2)

    def test_byte_identical_slots_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, config = self.write_tree(root, duplicate=True)
            with self.assertRaises(screenshot_preflight.ScreenshotPreflightError) as caught:
                screenshot_preflight.preflight_listing_screenshots(root, manifest, config)
            self.assertIn("byte-identical", str(caught.exception))

    def test_wrong_dimensions_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, config = self.write_tree(root, bad_dims=True)
            with self.assertRaises(screenshot_preflight.ScreenshotPreflightError) as caught:
                screenshot_preflight.preflight_listing_screenshots(root, manifest, config)
            self.assertIn("dimensions", str(caught.exception))

    def test_a_checksum_drift_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, config = self.write_tree(root)
            drifted = (
                root
                / "tools/app-review/assets/screenshots/0.1.17/iphone-6.9-kid-home.png"
            )
            drifted.write_bytes(rgb8_png(8, 8, (0, 0, 255)))
            with self.assertRaises(screenshot_preflight.ScreenshotPreflightError) as caught:
                screenshot_preflight.preflight_listing_screenshots(root, manifest, config)
            self.assertIn("reviewed file changed", str(caught.exception))

    def test_cli_refuses_a_duplicate_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.write_tree(root, duplicate=True)
            completed = subprocess.run(
                [sys.executable, str(PREFLIGHT), "--root", str(root)],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("byte-identical", completed.stderr)


if __name__ == "__main__":
    unittest.main()
