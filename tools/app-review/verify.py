#!/usr/bin/env python3
"""Verify exactly the captain-approved App Review candidate, with no Apple mutation.

This is the credential-free dry run for `app-review-submit.yml`. It receives no
App Store Connect credential and no variable token, and it refuses to start if
one is present. It re-checks the double-confirm dispatch, the captain-approved
manifest, the approved bytes, fresh readiness evidence, and that preparation
already opened the durable record.

The shared Node engine owns Apple mutation. This entrypoint cannot
create a review submission or submit for review.
"""

from __future__ import annotations

from datetime import datetime, timezone
import os
from pathlib import Path
import sys

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import content  # noqa: E402
import core  # noqa: E402
import evidence  # noqa: E402
import github_api  # noqa: E402
import runtime  # noqa: E402
import screenshot_preflight  # noqa: E402


def fresh_evidence(manifest) -> str:
    """Refuse unless the dispatch carries fresh readiness evidence for this candidate."""
    document = evidence.verify(
        os.environ.get("EDDIES_APP_REVIEW_EVIDENCE", ""),
        manifest,
        now=datetime.now(timezone.utc),
    )
    return document["generatedUtc"]


def main() -> int:
    runtime.heading("App Review submission: verify")
    runtime.trusted_context(captain_only=True)
    version = runtime.confirmed_version()
    if not asc_read.Credential.absent_from_environment():
        raise runtime.GateError(
            "the verify lane must run without any App Store Connect credential"
        )
    manifest = runtime.load_manifest(version)
    commit = runtime.approved_commit()
    config = runtime.load_config()
    files = content.verify_manifest_files(manifest, Path.cwd(), config=config)
    screenshot_preflight.preflight_listing_screenshots(Path.cwd(), manifest, config)
    generated = fresh_evidence(manifest)

    journal = core.GitHubIssueJournal(
        github_api.IssueBoundary(),
        core.JournalIdentity.from_manifest(manifest, commit),
    )
    opened = journal.open(create=False)
    runtime.emit(f"candidate={version} build={manifest['candidate']['build']}")
    runtime.emit(f"approved_commit={commit}")
    runtime.emit(f"content_hash={manifest['contentHash']}")
    runtime.emit(f"reviewed_files={len(files)} all bytes match the approved manifest")
    runtime.emit("listing_screenshots=preflight unique RGB8 checksums match")
    runtime.emit(f"readiness_evidence=fresh generated_utc={generated}")
    runtime.emit(
        "record=present resumable="
        + ("true" if opened.resumable else "false")
        + " asc_capability=none mutations=0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(runtime.run(main))
