#!/usr/bin/env python3
"""GET-only dump of 0.1.17 en-US App Store screenshots vs approved source.

Prints each live appScreenshotSet/appScreenshot the Node engine classifies in
classify_screenshots, then compares sourceFileChecksum/fileName/fileSize/
imageAsset size to the captain-approved files. Imports the structurally
GET-only client and cannot construct any other HTTP method.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
from typing import Any, Mapping, Optional

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import runtime  # noqa: E402

APP_ID = "6795664301"
LOCALIZATION_ID = "3d89b9a4-a341-439b-a6cb-2ead4e2db35a"
SETS_PATH = f"/v1/appStoreVersionLocalizations/{LOCALIZATION_ID}/appScreenshotSets"
MANIFEST_PATH = Path("tools/app-review/manifests/0.1.17.json")
CONFIG_PATH = Path("tools/app-review/app-review.config.json")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _attr(resource: Optional[Mapping[str, Any]], name: str) -> object:
    if not resource:
        return None
    attributes = resource.get("attributes")
    if not isinstance(attributes, dict):
        return None
    return attributes.get(name)


def _state(resource: Mapping[str, Any]) -> str:
    state = _attr(resource, "assetDeliveryState")
    if isinstance(state, str):
        return state
    if isinstance(state, dict) and isinstance(state.get("state"), str):
        return state["state"]
    return "UNKNOWN"


def _image_size(resource: Mapping[str, Any]) -> tuple[object, object]:
    image = _attr(resource, "imageAsset")
    if not isinstance(image, dict):
        return None, None
    return image.get("width"), image.get("height")


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != PNG_SIGNATURE:
        raise RuntimeError("approved screenshot is not PNG")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def expected_files() -> dict[str, list[dict[str, Any]]]:
    manifest = json.loads(MANIFEST_PATH.read_text())
    config = json.loads(CONFIG_PATH.read_text())
    by_name = {
        Path(item["path"]).name: item
        for slot in manifest["content"]["screenshots"]
        for item in slot["files"]
    }
    expected: dict[str, list[dict[str, Any]]] = {}
    for spec in config["listing"]["screenshotSpecs"]:
        files = []
        for file_name in spec["files"]:
            descriptor = by_name[file_name]
            data = Path(descriptor["path"]).read_bytes()
            width, height = png_size(data)
            files.append(
                {
                    "fileName": file_name,
                    "fileSize": len(data),
                    "md5": hashlib.md5(data).hexdigest(),
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "width": width,
                    "height": height,
                    "manifestBytes": descriptor["bytes"],
                    "manifestSha256": descriptor["sha256"],
                }
            )
        expected[spec["displayType"]] = files
    return expected


def classify_row(live: Mapping[str, Any], expected_by_md5: Mapping[str, dict[str, Any]]) -> str:
    checksum = live.get("sourceFileChecksum")
    if isinstance(checksum, str):
        checksum = checksum.lower()
    expected = expected_by_md5.get(checksum) if isinstance(checksum, str) else None
    if live.get("state") != "COMPLETE":
        return "incomplete"
    if expected is None:
        return "stale-or-unknown-checksum"
    conflicts = []
    if live.get("fileName") != expected["fileName"]:
        conflicts.append("fileName")
    if live.get("fileSize") != expected["fileSize"]:
        conflicts.append("fileSize")
    if live.get("width") != expected["width"] or live.get("height") != expected["height"]:
        conflicts.append("imageAsset")
    if conflicts:
        return "checksum-metadata-conflict:" + ",".join(conflicts)
    return "match"


def main() -> int:
    runtime.heading("App Review 0.1.17 en-US screenshots (GET-only)")
    expected = expected_files()
    session = asc_read.ReadSession(asc_read.Credential.from_environment())
    sets, included = session.collection(
        SETS_PATH,
        {
            "fields[appScreenshotSets]": "screenshotDisplayType",
            "limit": "50",
        },
    )
    print(f"GET {SETS_PATH} writes=0 method=GET")
    print(f"app={APP_ID} localization={LOCALIZATION_ID} sets={len(sets)}")
    print("EXPECTED_APPROVED")
    for display, files in expected.items():
        print(f"displayType={display} count={len(files)}")
        for file in files:
            print(
                "\t".join(
                    str(value)
                    for value in (
                        display,
                        file["fileName"],
                        file["fileSize"],
                        file["md5"],
                        file["width"],
                        file["height"],
                    )
                )
            )
    print(
        "setId\tdisplayType\tscreenshotId\tfileName\tfileSize\tchecksum\tstate\twidth\theight\tclass"
    )
    conflicts = []
    duplicates = []
    for item in sets:
        if item.get("type") != "appScreenshotSets":
            continue
        set_id = str(item.get("id") or "")
        display = str(_attr(item, "screenshotDisplayType") or "")
        screenshots, _ = session.collection(
            f"/v1/appScreenshotSets/{set_id}/appScreenshots",
            {
                "fields[appScreenshots]": (
                    "fileName,fileSize,sourceFileChecksum,imageAsset,assetDeliveryState"
                ),
                "limit": "50",
            },
        )
        expected_set = expected.get(display, [])
        by_md5: dict[str, dict[str, Any]] = {}
        seen_md5: dict[str, str] = {}
        for file in expected_set:
            if file["md5"] in by_md5:
                duplicates.append(
                    f"{display} approved files {seen_md5[file['md5']]} and {file['fileName']} share md5 {file['md5']}"
                )
            seen_md5[file["md5"]] = file["fileName"]
            by_md5[file["md5"]] = file
        for shot in screenshots:
            if shot.get("type") != "appScreenshots":
                continue
            width, height = _image_size(shot)
            live = {
                "id": str(shot.get("id") or ""),
                "fileName": _attr(shot, "fileName"),
                "fileSize": _attr(shot, "fileSize"),
                "sourceFileChecksum": _attr(shot, "sourceFileChecksum"),
                "state": _state(shot),
                "width": width,
                "height": height,
            }
            classification = classify_row(live, by_md5)
            print(
                "\t".join(
                    str(value)
                    for value in (
                        set_id,
                        display,
                        live["id"],
                        live["fileName"],
                        live["fileSize"],
                        live["sourceFileChecksum"],
                        live["state"],
                        live["width"],
                        live["height"],
                        classification,
                    )
                )
            )
            if classification.startswith("checksum-metadata-conflict"):
                expected_file = by_md5.get(str(live["sourceFileChecksum"]).lower())
                conflicts.append(
                    {
                        "displayType": display,
                        "live": live,
                        "expected": expected_file,
                        "class": classification,
                    }
                )
    print("APPROVED_DUPLICATE_MD5")
    if duplicates:
        for line in duplicates:
            print(line)
    else:
        print("none")
    print("CONFLICTS_JSON_BEGIN")
    print(json.dumps(conflicts, ensure_ascii=False, separators=(",", ":")))
    print("CONFLICTS_JSON_END")
    runtime.emit(f"sets={len(sets)} conflicts={len(conflicts)} mutations=0")
    return 0


if __name__ == "__main__":
    sys.exit(runtime.run(main))
