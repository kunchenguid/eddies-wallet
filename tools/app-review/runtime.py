#!/usr/bin/env python3
"""Shared entrypoint plumbing for the App Review workflows.

The gate this module enforces is the whole gate, and it is deliberately the
SSHHIP shape rather than a protected GitHub Environment:

- the run must be a manual dispatch on the trusted repository's default branch,
- the dispatcher must type the exact version twice, and
- the version must already have a captain-approved manifest merged on main.

Every entrypoint refuses before it looks at a credential, so a failed gate never
reaches Apple. Diagnostics are bounded nonsecret text.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Callable, Mapping, Optional

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import core  # noqa: E402

MANIFEST_DIRECTORY = Path("tools/app-review/manifests")
CONFIG_PATH = Path("tools/app-review/app-review.config.json")


class GateError(core.BoundedError):
    """The dispatch is not one the captain already approved."""


def confirmed_version() -> str:
    """Refuse unless the dispatcher typed the same exact version twice."""
    version = os.environ.get("EDDIES_APP_REVIEW_VERSION", "").strip()
    confirm = os.environ.get("EDDIES_APP_REVIEW_CONFIRM", "").strip()
    if core.VERSION_RE.fullmatch(version) is None:
        raise GateError("the dispatched version is not an exact marketing version")
    if confirm != version:
        raise GateError(
            "the confirmation does not repeat the dispatched version exactly"
        )
    return version


def trusted_context(*, captain_only: bool = False) -> core.TrustedContext:
    context = core.TrustedContext(
        repository=os.environ.get("GITHUB_REPOSITORY", ""),
        ref=os.environ.get("GITHUB_REF", ""),
        event_name=os.environ.get("GITHUB_EVENT_NAME", ""),
        actor=os.environ.get("GITHUB_ACTOR", ""),
    )
    if captain_only:
        return core.assert_captain_actor(context)
    return core.assert_trusted_context(context)


def approved_commit() -> str:
    """The commit the workflow pinned as the last change to this manifest."""
    commit = os.environ.get("EDDIES_APP_REVIEW_APPROVED_COMMIT", "").strip()
    if core.COMMIT_RE.fullmatch(commit) is None:
        raise GateError("the manifest-approved commit was not pinned by the workflow")
    return commit


def manifest_path(version: str, root: Optional[Path] = None) -> Path:
    if core.VERSION_RE.fullmatch(version) is None:
        raise GateError("the dispatched version is not an exact marketing version")
    return (root or Path.cwd()) / MANIFEST_DIRECTORY / f"{version}.json"


def load_manifest(version: str, root: Optional[Path] = None) -> Mapping[str, Any]:
    """Load the captain-approved manifest that pins exactly this version."""
    path = manifest_path(version, root)
    if not path.is_file():
        raise GateError(
            "no captain-approved manifest for this version exists on the default branch"
        )
    raw = path.read_bytes()
    if len(raw) > 4 * 1024 * 1024:
        raise GateError("the captain-approved manifest is implausibly large")
    try:
        document = json.loads(raw)
    except json.JSONDecodeError:
        raise GateError("the captain-approved manifest is not valid JSON")
    manifest = core.validate_manifest(document)
    if manifest["candidate"]["version"] != version:
        raise GateError("the captain-approved manifest pins a different version")
    return manifest


def load_config(root: Optional[Path] = None) -> Mapping[str, Any]:
    path = (root or Path.cwd()) / CONFIG_PATH
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raise GateError("app-review.config.json is missing or not valid JSON")
    if not isinstance(document, dict):
        raise GateError("app-review.config.json is not an object")
    return document


def emit(line: str) -> None:
    """Print one bounded nonsecret line and mirror it into the run summary."""
    print(line, flush=True)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"- `{line}`\n")


def heading(title: str) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### {title}\n\n")


def block(caption: str, body: str) -> None:
    """Mirror one bounded nonsecret block, such as readiness evidence, to the run."""
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"\n{caption}\n\n```\n{body}\n```\n")


def run(main: Callable[[], int]) -> int:
    """Turn any bounded pipeline failure into one nonsecret line and exit 1."""
    try:
        return main()
    except core.BoundedError as error:
        # Only a declared bounded failure may describe itself. Its message is
        # written by this pipeline, never copied from Apple or GitHub.
        code = getattr(error, "code", type(error).__name__)
        print(f"EDDIES_APP_REVIEW refused ({code}): {_bounded(error)}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - deliberately silent
        # An unexpected fault's text can carry a payload, header, or credential,
        # so nothing about it is printed - not the type, not the message.
        print("EDDIES_APP_REVIEW refused: unexpected pipeline failure", file=sys.stderr)
        return 1


def _bounded(error: BaseException) -> str:
    return re.sub(r"[^A-Za-z0-9 .,:()/\[\]'-]", "?", str(error))[:220]
