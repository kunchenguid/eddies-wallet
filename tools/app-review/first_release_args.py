#!/usr/bin/env python3
"""Print adapter argv so first-release vs update is manifest-driven.

The captain-approved manifest is the source of truth. A first-release
candidate requires `--first-release`. An update candidate (baselineVersion)
must not receive that flag: the adapters refuse a mismatch.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
from typing import Any, Mapping, Sequence


def first_release_args(manifest: Mapping[str, Any]) -> list[str]:
    candidate = manifest.get("candidate")
    if not isinstance(candidate, Mapping):
        raise ValueError("manifest candidate is invalid")
    if candidate.get("firstRelease") is True:
        return ["--first-release"]
    baseline = candidate.get("baselineVersion")
    if not isinstance(baseline, str) or not baseline:
        raise ValueError("update manifest requires baselineVersion")
    return []


def load_manifest(version: str, *, root: Path | None = None) -> Mapping[str, Any]:
    if not version:
        raise ValueError("EDDIES_APP_REVIEW_VERSION is missing")
    base = root if root is not None else Path.cwd()
    path = base / "tools" / "app-review" / "manifests" / f"{version}.json"
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ValueError(f"captain-approved manifest is missing: {path}") from error
    if not isinstance(parsed, dict):
        raise ValueError("manifest is not an object")
    return parsed


def main(argv: Sequence[str] | None = None) -> int:
    del argv
    try:
        version = os.environ.get("EDDIES_APP_REVIEW_VERSION", "").strip()
        args = first_release_args(load_manifest(version))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    if args:
        sys.stdout.write(" ".join(args) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
