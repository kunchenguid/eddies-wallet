#!/usr/bin/env python3
"""Bounded nonsecret reviewer-path readiness evidence.

`app-review-demo-preflight.yml` proves the conditions Apple's reviewer depends
on - the exact candidate and build on App Store Connect, both Cloud products
reviewable with delivered review assets, and the public service actually
offering Cloud activation with exactly those two products - and emits this
document. The submit dispatch carries it back, and submission refuses unless the
evidence names the same approved candidate and is still fresh.

What this is: a freshness and binding gate. Evidence generated for another
version, another manifest, or hours ago cannot authorize a submission.

What this deliberately is not: proof of authorship. There is no shared signing
secret here, because the dispatcher is already the captain and adding a secret
would create custody work without adding a real boundary. The captain's explicit
`mode=assemble` or `mode=submit` dispatch remains the gate.

The document carries only allowlisted check names and pass/fail words. It can
never carry an Apple payload, account value, session, purchase, or contact.
"""

from __future__ import annotations

import base64
import binascii
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
from typing import Any, Mapping

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import core  # noqa: E402

EVIDENCE_SCHEMA_VERSION = 1
EVIDENCE_BINDING_ALGORITHM = "eddies-wallet-app-review-evidence-v1"
EVIDENCE_MAX_AGE_SECONDS = 6 * 60 * 60
MAX_EVIDENCE_BYTES = 8 * 1024

REQUIRED_CHECKS = (
    "asc.candidateVersion",
    "asc.boundBuildValid",
    "asc.cloudProductsReviewable",
    "asc.iapReviewAssetsDelivered",
    "public.serviceHealthy",
    "public.cloudActivationAvailable",
    "public.exactCloudProducts",
)
PASS = "pass"


class EvidenceError(core.BoundedError):
    """A bounded, nonsecret readiness-evidence failure."""


def _parse_utc(value: object, name: str) -> datetime:
    if not isinstance(value, str):
        raise EvidenceError(f"{name} is invalid")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        raise EvidenceError(f"{name} is invalid")


def build(
    manifest: Mapping[str, Any], checks: Mapping[str, str], generated_utc: str
) -> Mapping[str, Any]:
    approved = core.validate_manifest(manifest)
    if set(checks) != set(REQUIRED_CHECKS):
        raise EvidenceError("readiness evidence does not cover exactly the known checks")
    if any(value != PASS for value in checks.values()):
        raise EvidenceError("readiness evidence may only be emitted when every check passes")
    _parse_utc(generated_utc, "readiness evidence timestamp")
    document: dict[str, Any] = {
        "schemaVersion": EVIDENCE_SCHEMA_VERSION,
        "appId": core.APP_ID,
        "version": approved["candidate"]["version"],
        "build": approved["candidate"]["build"],
        "contentHash": approved["contentHash"],
        "manifestHash": approved["binding"]["manifestHash"],
        "generatedUtc": generated_utc,
        "checks": {name: PASS for name in REQUIRED_CHECKS},
        "binding": {"algorithm": EVIDENCE_BINDING_ALGORITHM, "evidenceHash": ""},
    }
    document["binding"]["evidenceHash"] = _binding_hash(document)
    return document


def _binding_hash(document: Mapping[str, Any]) -> str:
    binding_input = dict(document)
    binding_input.pop("binding", None)
    return core.stable_hash(binding_input)


def encode(document: Mapping[str, Any]) -> str:
    return base64.b64encode(core.canonical_bytes(document)).decode("ascii")


def decode(encoded: str) -> Mapping[str, Any]:
    trimmed = "".join((encoded or "").split())
    if not trimmed or len(trimmed) > MAX_EVIDENCE_BYTES:
        raise EvidenceError("readiness evidence is absent or implausibly large")
    try:
        raw = base64.b64decode(trimmed, validate=True)
    except (binascii.Error, ValueError):
        raise EvidenceError("readiness evidence is not valid base64")
    try:
        document = json.loads(raw)
    except json.JSONDecodeError:
        raise EvidenceError("readiness evidence is not valid JSON")
    if not isinstance(document, dict):
        raise EvidenceError("readiness evidence is not an object")
    return document


def verify(
    encoded: str,
    manifest: Mapping[str, Any],
    *,
    now: datetime,
    max_age_seconds: int = EVIDENCE_MAX_AGE_SECONDS,
) -> Mapping[str, Any]:
    """Refuse evidence for another candidate, another manifest, or a stale run."""
    approved = core.validate_manifest(manifest)
    document = decode(encoded)
    expected_keys = {
        "schemaVersion",
        "appId",
        "version",
        "build",
        "contentHash",
        "manifestHash",
        "generatedUtc",
        "checks",
        "binding",
    }
    if set(document) != expected_keys:
        raise EvidenceError("readiness evidence has unsupported or missing fields")
    if document["schemaVersion"] != EVIDENCE_SCHEMA_VERSION:
        raise EvidenceError("readiness evidence schema version is unsupported")
    if document["appId"] != core.APP_ID:
        raise EvidenceError("readiness evidence belongs to a different app")

    candidate = approved["candidate"]
    if (
        document["version"] != candidate["version"]
        or document["build"] != candidate["build"]
        or document["contentHash"] != approved["contentHash"]
        or document["manifestHash"] != approved["binding"]["manifestHash"]
    ):
        raise EvidenceError(
            "readiness evidence does not bind the captain-approved candidate"
        )

    binding = document["binding"]
    if (
        not isinstance(binding, dict)
        or set(binding) != {"algorithm", "evidenceHash"}
        or binding["algorithm"] != EVIDENCE_BINDING_ALGORITHM
        or binding["evidenceHash"] != _binding_hash(document)
    ):
        raise EvidenceError("readiness evidence binding hash does not match its content")

    checks = document["checks"]
    if not isinstance(checks, dict) or set(checks) != set(REQUIRED_CHECKS):
        raise EvidenceError("readiness evidence does not cover exactly the known checks")
    failed = sorted(name for name, value in checks.items() if value != PASS)
    if failed:
        raise EvidenceError(f"readiness evidence reports a failed check: {failed[0]}")

    generated = _parse_utc(document["generatedUtc"], "readiness evidence timestamp")
    age = (now - generated).total_seconds()
    if age < -300:
        raise EvidenceError("readiness evidence is dated in the future")
    if age > max_age_seconds:
        raise EvidenceError(
            "readiness evidence is stale; rerun the demo preflight before submitting"
        )
    return document
