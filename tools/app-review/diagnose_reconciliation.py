#!/usr/bin/env python3
"""GET-only prepare diagnosis with no journal or raw Apple payload output.

The workflow supplies a source root exported from the last main commit that
changed the approved manifest. Code runs from the dispatched ref so a repaired
reader can be proven before merge. Only bounded field paths and outcomes leave
this process; reviewed values, resource IDs and credentials never do.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read
import content
import core
import runtime


def diagnose(version: str, source_root: Path) -> int:
    manifest = runtime.load_manifest(version, source_root)
    files = content.verify_manifest_files(
        manifest, source_root, config=runtime.load_config(source_root)
    )
    session = asc_read.ReadSession(asc_read.Credential.from_environment())
    client = core.ReadOnlyASCClient(
        content.CandidateReadTransport(session, manifest["candidate"], files)
    )
    live = client.read_candidate(manifest["candidate"])
    for path in core.reviewed_content_differences(manifest["content"], live.content):
        runtime.emit(f"difference={path}")
    result = core.reconcile_manifest_with_live_state(manifest, live)
    runtime.emit(f"reconciliation={result.outcome} live_state={result.state}")
    runtime.emit("asc_capability=get-only mutations=0 journal=untouched")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--source-root", type=Path, required=True)
    args = parser.parse_args()
    return diagnose(args.version, args.source_root)


if __name__ == "__main__":
    sys.exit(runtime.run(main))
