#!/usr/bin/env python3
"""Credential-free preflight for App Store listing screenshot slots.

This is the Eddie-side check that must pass before any live screenshot write.
It does not contact App Store Connect. The shared engine owns reserve / upload
/ commit verify-before-live once its SHA lands.

For every display type in `app-review.config.json` listing.screenshotSpecs it
proves:

- the captain-approved manifest binds that slot
- every required fileName has a repo path and checksum
- the path is the display-type upload directory for this version
- on-disk bytes still match the manifest
- the PNG is RGB8 without alpha at the approved dimensions
- no two files in a size are byte-identical
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
from typing import Any, Mapping, Sequence

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import core  # noqa: E402

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
DEFAULT_CONFIG = Path("tools/app-review/app-review.config.json")
DEFAULT_MANIFEST_DIRECTORY = Path("tools/app-review/manifests")


class ScreenshotPreflightError(core.AppReviewError):
    """A bounded, nonsecret listing-screenshot preflight failure."""

    def __init__(self, message: str, code: str = "E_PREFLIGHT"):
        super().__init__(code, message)


def _refuse(message: str) -> None:
    raise ScreenshotPreflightError(message)


def inspect_png(
    data: bytes, expected_width: int, expected_height: int, file_name: str
) -> None:
    """Match assemble_only.js inspectPng: PNG, RGB8, no alpha, exact dimensions."""
    if len(data) < 33:
        _refuse(f"screenshot is too small: {file_name}")
    if data[:8] != PNG_SIGNATURE:
        _refuse(f"screenshot is not PNG: {file_name}")
    if int.from_bytes(data[8:12], "big") != 13 or data[12:16] != b"IHDR":
        _refuse(f"screenshot header is malformed: {file_name}")
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    if width != expected_width or height != expected_height:
        _refuse(f"screenshot dimensions do not match the approved slot: {file_name}")
    if data[24] != 8 or data[25] != 2 or data[26] != 0 or data[27] != 0 or data[28] != 0:
        _refuse(f"screenshot must be RGB8 without alpha: {file_name}")


def _screenshot_directory(config: Mapping[str, Any]) -> tuple[str, ...]:
    listing = config.get("listing")
    if not isinstance(listing, dict):
        _refuse("config.listing is required")
    segments = listing.get("screenshotDirectory")
    if not isinstance(segments, list) or not segments:
        _refuse("config.listing.screenshotDirectory is required")
    if not all(isinstance(part, str) and part for part in segments):
        _refuse("config.listing.screenshotDirectory is invalid")
    return tuple(segments)


def _screenshot_specs(config: Mapping[str, Any]) -> Sequence[Mapping[str, Any]]:
    listing = config.get("listing")
    if not isinstance(listing, dict):
        _refuse("config.listing is required")
    specs = listing.get("screenshotSpecs")
    if not isinstance(specs, list) or not specs:
        _refuse("config.listing.screenshotSpecs is required")
    return specs


def _spec_files(spec: Mapping[str, Any]) -> list[str]:
    files = spec.get("files")
    if not isinstance(files, list) or not files:
        _refuse("screenshot spec files are invalid")
    names: list[str] = []
    for name in files:
        if not isinstance(name, str) or not name:
            _refuse("screenshot spec fileName is invalid")
        names.append(name)
    return names


def preflight_listing_screenshots(
    source_root: Path,
    manifest: Mapping[str, Any],
    config: Mapping[str, Any],
) -> Mapping[str, Any]:
    """Prove every required listing slot is complete, unique, and bound."""
    approved = core.validate_manifest(manifest)
    directory = _screenshot_directory(config)
    specs = _screenshot_specs(config)
    slots = {
        item["slot"]: item for item in approved["content"]["screenshots"]
    }
    spec_types = []
    for spec in specs:
        display_type = spec.get("displayType")
        if not isinstance(display_type, str) or not display_type:
            _refuse("screenshot displayType is invalid")
        spec_types.append(display_type)
        if display_type not in slots:
            _refuse(f"manifest is missing screenshot slot {display_type}")
    extra = set(slots) - set(spec_types)
    if extra:
        _refuse("manifest screenshot slots are not the approved display types")

    report: list[dict[str, Any]] = []
    for spec in specs:
        display_type = spec["displayType"]
        width = spec.get("width")
        height = spec.get("height")
        if not isinstance(width, int) or not isinstance(height, int):
            _refuse(f"screenshot dimensions are invalid for {display_type}")
        required = _spec_files(spec)
        bound_files = slots[display_type]["files"]
        bound_by_name = {}
        for descriptor in bound_files:
            name = descriptor["fileName"]
            if name in bound_by_name:
                _refuse(f"manifest fileName is duplicated in {display_type}: {name}")
            bound_by_name[name] = descriptor
        missing = [name for name in required if name not in bound_by_name]
        if missing:
            _refuse(
                f"manifest is missing screenshot fileName {missing[0]} in {display_type}"
            )
        extra_names = [name for name in bound_by_name if name not in required]
        if extra_names:
            _refuse(
                f"manifest has an unexpected screenshot fileName in {display_type}: "
                f"{extra_names[0]}"
            )

        seen_md5: dict[str, str] = {}
        seen_bytes: dict[bytes, str] = {}
        files_report = []
        for file_name in required:
            descriptor = bound_by_name[file_name]
            expected_path = "/".join((*directory, f"{display_type}-asc-upload", file_name))
            if descriptor["path"] != expected_path:
                _refuse(
                    f"screenshot path must be the display-type upload file: {file_name}"
                )
            file_path = source_root / Path(*PurePosixPath(descriptor["path"]).parts)
            if not file_path.is_file():
                _refuse(f"reviewed file is missing: {descriptor['path']}")
            data = file_path.read_bytes()
            if len(data) != descriptor["bytes"]:
                _refuse(f"reviewed file changed size since approval: {descriptor['path']}")
            digest = hashlib.sha256(data).hexdigest()
            if digest != descriptor["sha256"]:
                _refuse(
                    f"reviewed file changed content since approval: {descriptor['path']}"
                )
            inspect_png(data, width, height, file_name)
            md5 = hashlib.md5(data).hexdigest()
            if md5 in seen_md5:
                _refuse(
                    f"{seen_md5[md5]} and {file_name} are byte-identical in {display_type}"
                )
            if data in seen_bytes:
                _refuse(
                    f"{seen_bytes[data]} and {file_name} are byte-identical in {display_type}"
                )
            seen_md5[md5] = file_name
            seen_bytes[data] = file_name
            files_report.append(
                {
                    "fileName": file_name,
                    "path": descriptor["path"],
                    "bytes": descriptor["bytes"],
                    "sha256": descriptor["sha256"],
                    "md5": md5,
                    "width": width,
                    "height": height,
                }
            )
        report.append(
            {
                "displayType": display_type,
                "width": width,
                "height": height,
                "files": files_report,
            }
        )
    return {"displayTypes": report}


def load_json(path: Path) -> Mapping[str, Any]:
    if not path.is_file():
        _refuse(f"required file is missing: {path}")
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        _refuse(f"required file is not JSON: {path}")
    if not isinstance(parsed, dict):
        _refuse(f"required file is not a JSON object: {path}")
    return parsed


def parse_argv(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate listing screenshot slots before any live write."
    )
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG),
        help="app-review config path relative to --root, or absolute",
    )
    parser.add_argument(
        "--manifest",
        default="",
        help="manifest path relative to --root, or absolute",
    )
    parser.add_argument(
        "--version",
        default="",
        help="marketing version whose captain-approved manifest to load",
    )
    return parser.parse_args(argv)


def _resolve(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_argv(argv)
    root = Path(args.root).resolve()
    config = load_json(_resolve(root, args.config))
    if args.manifest:
        manifest_path = _resolve(root, args.manifest)
    else:
        version = args.version.strip()
        if not version:
            version = "0.1.17"
        manifest_path = root / DEFAULT_MANIFEST_DIRECTORY / f"{version}.json"
    manifest = load_json(manifest_path)
    report = preflight_listing_screenshots(root, manifest, config)
    types = ",".join(item["displayType"] for item in report["displayTypes"])
    files = sum(len(item["files"]) for item in report["displayTypes"])
    print(
        f"screenshot preflight ok displayTypes={types} files={files} unique RGB8 checksums match"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except core.BoundedError as error:
        code = getattr(error, "code", type(error).__name__)
        print(f"EDDIES_APP_REVIEW refused ({code}): {error}", file=sys.stderr)
        sys.exit(1)
