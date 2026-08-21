#!/usr/bin/env python3
"""Read-only App Review preparation. This entrypoint cannot mutate Apple state.

`verify` is the credential-free lane. It refuses to run at all if an App Store
Connect credential is present in its environment, proving by execution that the
preparation gate is decided before any Apple capability exists. It checks the
double-confirm dispatch, the captain-approved manifest, and that every approved
image still has exactly its approved bytes, then opens the durable nonsecret
recovery record.

`preflight` is the read lane. It uses the shared release App Store Connect
credential through the deterministic core's structurally GET-only client and
records the authoritative reconciliation outcome in the same record.

Neither lane imports a mutation module, so neither can reach an App Store
write, and `test/app-review-lanes-test.py` proves that import boundary.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
import sys

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import content  # noqa: E402
import core  # noqa: E402
import github_api  # noqa: E402
import runtime  # noqa: E402


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def journal_for(manifest, commit) -> core.GitHubIssueJournal:
    return core.GitHubIssueJournal(
        github_api.IssueBoundary(),
        core.JournalIdentity.from_manifest(manifest, commit),
    )


def verify() -> int:
    runtime.heading("App Review preparation: verify")
    runtime.trusted_context()
    version = runtime.confirmed_version()
    if not asc_read.Credential.absent_from_environment():
        raise runtime.GateError(
            "the verify lane must run without any App Store Connect credential"
        )
    manifest = runtime.load_manifest(version)
    commit = runtime.approved_commit()
    files = content.verify_manifest_files(manifest, Path.cwd())

    journal = journal_for(manifest, commit)
    opened = journal.open(create=True)
    journal.save(
        core.DurableJournalState(
            phase="prepared", reconciliation="not_read", updated_utc=now_utc()
        )
    )
    runtime.emit(f"candidate={version} build={manifest['candidate']['build']}")
    runtime.emit(f"approved_commit={commit}")
    runtime.emit(f"content_hash={manifest['contentHash']}")
    runtime.emit(f"reviewed_files={len(files)} all bytes match the approved manifest")
    runtime.emit(
        "record=" + ("created" if opened.created else "resumed") + " asc_capability=none"
    )
    return 0


def preflight() -> int:
    runtime.heading("App Review preparation: read-only preflight")
    runtime.trusted_context()
    version = runtime.confirmed_version()
    manifest = runtime.load_manifest(version)
    commit = runtime.approved_commit()
    files = content.verify_manifest_files(manifest, Path.cwd())

    session = asc_read.ReadSession(asc_read.Credential.from_environment())
    transport = content.CandidateReadTransport(session, manifest["candidate"], files)
    reconciliation = core.reconcile_authoritatively(
        manifest, core.ReadOnlyASCClient(transport)
    )

    journal = journal_for(manifest, commit)
    journal.open(create=False)
    journal.save(
        core.DurableJournalState(
            phase="prepared",
            reconciliation=reconciliation.outcome,
            updated_utc=now_utc(),
        )
    )
    runtime.emit(f"candidate={version} build={manifest['candidate']['build']}")
    runtime.emit(
        f"reconciliation={reconciliation.outcome} live_state={reconciliation.state}"
    )
    runtime.emit("asc_capability=get-only mutations=0")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("verify", "preflight"))
    arguments = parser.parse_args()
    return {"verify": verify, "preflight": preflight}[arguments.mode]()


if __name__ == "__main__":
    sys.exit(runtime.run(main))
