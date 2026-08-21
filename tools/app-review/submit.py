#!/usr/bin/env python3
"""Submit exactly the captain-approved App Review candidate, or refuse.

Two modes, run as two jobs with two different credential lanes.

`verify` is the dry run. It receives no App Store Connect credential and no
variable token, and it refuses to start if one is present. It re-checks the
double-confirm dispatch, the captain-approved manifest, the approved bytes, and
that preparation already opened the durable record.

`submit` is the App Review submission mutation lane. It is reachable only from
`app-review-submit.yml`'s `submit` job, which runs only when the dispatcher chose
`mode=submit` and typed the version twice. It imports `submission`, which is the
only importer of `asc_write`. Apple's acceptance is read back before the review
monitor is armed, so an unaccepted submission can never arm the monitor and an
interrupted handoff resumes without submitting twice. A separate one-shot
Guideline 3.1.2 workflow (`app-review-eula-append.yml`) may PATCH only the
pinned 0.1.17 en-US description and does not import this entrypoint.
"""

from __future__ import annotations

import argparse
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


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fresh_evidence(manifest) -> str:
    """Refuse unless the dispatch carries fresh readiness evidence for this candidate."""
    document = evidence.verify(
        os.environ.get("EDDIES_APP_REVIEW_EVIDENCE", ""),
        manifest,
        now=datetime.now(timezone.utc),
    )
    return document["generatedUtc"]


def verify() -> int:
    runtime.heading("App Review submission: verify")
    runtime.trusted_context(captain_only=True)
    version = runtime.confirmed_version()
    if not asc_read.Credential.absent_from_environment():
        raise runtime.GateError(
            "the verify lane must run without any App Store Connect credential"
        )
    manifest = runtime.load_manifest(version)
    commit = runtime.approved_commit()
    files = content.verify_manifest_files(manifest, Path.cwd())
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
    runtime.emit(f"readiness_evidence=fresh generated_utc={generated}")
    runtime.emit(
        "record=present resumable="
        + ("true" if opened.resumable else "false")
        + " asc_capability=none mutations=0"
    )
    return 0


def submit() -> int:
    runtime.heading("App Review submission: submit")
    runtime.trusted_context(captain_only=True)
    version = runtime.confirmed_version()
    manifest = runtime.load_manifest(version)
    commit = runtime.approved_commit()
    files = content.verify_manifest_files(manifest, Path.cwd())
    generated = fresh_evidence(manifest)

    # Imported here, and only here, so the mutation boundary is one edge wide.
    import asc_write
    import submission as submission_engine

    journal = core.GitHubIssueJournal(
        github_api.IssueBoundary(),
        core.JournalIdentity.from_manifest(manifest, commit),
    )
    journal.open(create=False)

    credential = asc_read.Credential.from_environment()
    outcome = submission_engine.SubmissionEngine(
        asc_read.ReadSession(credential),
        asc_write.ChangeSession(credential),
        manifest,
        files,
    ).run()

    journal.save(
        core.DurableJournalState(
            phase="reconciled",
            reconciliation="already_submitted",
            updated_utc=now_utc(),
        )
    )

    handoff = github_api.MonitorCycleVariable()
    if not handoff.configured:
        raise runtime.GateError(
            "Apple accepted the submission but the monitor variable token is absent; "
            "rerun this job with EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN configured to "
            "complete only the handoff"
        )
    handoff.hand_off(version, manifest["candidate"]["build"])

    runtime.emit(f"candidate={version} build={manifest['candidate']['build']}")
    runtime.emit(f"readiness_evidence=fresh generated_utc={generated}")
    runtime.emit(f"reconciliation={outcome.reconciliation}")
    runtime.emit(
        f"submission_state={outcome.submission_state} version_state={outcome.version_state}"
    )
    runtime.emit(f"asc_writes={len(outcome.writes)}")
    runtime.emit(f"monitor_cycle={github_api.MONITOR_CYCLE_VARIABLE} armed=true")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("verify", "submit"))
    arguments = parser.parse_args()
    return {"verify": verify, "submit": submit}[arguments.mode]()


if __name__ == "__main__":
    sys.exit(runtime.run(main))
