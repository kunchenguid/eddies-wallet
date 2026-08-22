#!/usr/bin/env python3
"""Prove the reviewer's public path is live, without touching anything.

Eddie's Wallet has no shared demo account: the reviewer signs in with their own
Apple Account and buys a Cloud plan through Apple's review or sandbox flow. So
what a runner can honestly prove is that the public route the reviewer will walk
is actually open at submission time:

- the exact approved candidate exists on App Store Connect with a valid, bound,
  unexpired build,
- both Cloud subscriptions are reviewable and their App Review screenshots are
  fully delivered, and
- the production service is healthy and publishes Cloud activation with exactly
  those two product identifiers.

When `listing.screenshotWrites` is true, this preflight does not require live
listing screenshots to match the approved set. That match is the dedicated
upload step after assemble. In-app purchase review screenshots still must match.

It cannot perform Sign in with Apple or a purchase. That one functional proof is
deliberately an attended pre-submission acceptance gate.

Every read here is a GET. This entrypoint imports no mutation module.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import sys
from typing import Any, Mapping
import urllib.error
import urllib.parse
import urllib.request

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import content  # noqa: E402
import core  # noqa: E402
import evidence  # noqa: E402
import runtime  # noqa: E402

SERVICE_ORIGIN = "https://eddieswallet.kunchenguid.com"
PUBLIC_TIMEOUT_SECONDS = 20
REVIEWABLE_SUBSCRIPTION_STATES = frozenset(
    ("READY_TO_SUBMIT", "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_BINARY_APPROVAL", "APPROVED")
)


class PreflightError(core.BoundedError):
    """A bounded, nonsecret readiness failure."""


def public_get(path: str) -> tuple[int, Mapping[str, Any]]:
    """Unauthenticated public read. It sends no credential and no session."""
    url = urllib.parse.urljoin(SERVICE_ORIGIN, path)
    if not url.startswith(SERVICE_ORIGIN + "/"):
        raise PreflightError("public readiness path is invalid")
    request = urllib.request.Request(
        url, method="GET", headers={"Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=PUBLIC_TIMEOUT_SECONDS) as response:
            body = response.read()
            status = response.status
    except urllib.error.HTTPError as error:
        return error.code, {}
    except Exception:
        raise PreflightError(f"the public service did not answer {path}")
    if not body:
        return status, {}
    try:
        document = json.loads(body)
    except json.JSONDecodeError:
        return status, {}
    return status, document if isinstance(document, dict) else {}


def main() -> int:
    runtime.heading("App Review reviewer-path readiness preflight")
    runtime.trusted_context()
    version = runtime.confirmed_version()
    manifest = runtime.load_manifest(version)
    config = runtime.load_config()
    files = content.verify_manifest_files(manifest, Path.cwd(), config=config)
    candidate = manifest["candidate"]
    config_screenshot_writes = (
        (config.get("listing") or {}).get("screenshotWrites") is True
    )
    manifest_screenshot_writes = manifest["listing"]["screenshotWrites"] is True
    if config_screenshot_writes != manifest_screenshot_writes:
        raise PreflightError(
            "config.listing.screenshotWrites must match the captain-approved "
            "manifest listing.screenshotWrites"
        )

    session = asc_read.ReadSession(asc_read.Credential.from_environment())
    checks: dict[str, str] = {}

    live = core.ReadOnlyASCClient(
        content.CandidateReadTransport(
            session,
            candidate,
            files,
            match_listing_screenshots=not manifest_screenshot_writes,
        )
    ).read_candidate(candidate)
    if live.state == "ABSENT":
        raise PreflightError("the approved candidate does not exist on App Store Connect")
    checks["asc.candidateVersion"] = evidence.PASS
    if live.build != candidate["build"]:
        raise PreflightError("the approved build is not bound to the candidate")
    checks["asc.boundBuildValid"] = evidence.PASS

    _, included = session.collection(
        f"/v1/apps/{core.APP_ID}/subscriptionGroups",
        {
            "fields[subscriptionGroups]": "subscriptions",
            "fields[subscriptions]": "productId,state",
            "include": "subscriptions",
            "limit": "50",
        },
    )
    states = {
        asc_read.text(asc_read.attributes(item), "productId"): asc_read.text(
            asc_read.attributes(item), "state"
        )
        for item in included
        if item.get("type") == "subscriptions"
    }
    for product_id in core.CLOUD_PRODUCT_IDS:
        if states.get(product_id) not in REVIEWABLE_SUBSCRIPTION_STATES:
            raise PreflightError(
                "a Cloud subscription is not reviewable on App Store Connect"
            )
    checks["asc.cloudProductsReviewable"] = evidence.PASS

    # Reading the candidate above already required every review asset to be
    # delivered and to match an approved file byte for byte.
    checks["asc.iapReviewAssetsDelivered"] = evidence.PASS

    status, _ = public_get("/healthz")
    if status != 200:
        raise PreflightError("the production service is not reporting healthy")
    checks["public.serviceHealthy"] = evidence.PASS

    status, capabilities = public_get("/v1/capabilities")
    if status != 200:
        raise PreflightError("the production service did not publish its capabilities")
    if (
        capabilities.get("cloudActivationAvailable") is not True
        or capabilities.get("cloudServiceAvailable") is not True
    ):
        raise PreflightError("Cloud activation is not publicly available")
    checks["public.cloudActivationAvailable"] = evidence.PASS
    products = capabilities.get("products")
    if not isinstance(products, list) or set(products) != set(core.CLOUD_PRODUCT_IDS):
        raise PreflightError(
            "the production service does not publish exactly the two Cloud products"
        )
    checks["public.exactCloudProducts"] = evidence.PASS

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    document = evidence.build(manifest, checks, generated)
    encoded = evidence.encode(document)

    runtime.emit(f"candidate={version} build={candidate['build']}")
    runtime.emit(f"checks_passed={len(evidence.REQUIRED_CHECKS)} mutations=0")
    runtime.emit(f"evidence_generated_utc={generated}")
    runtime.emit(f"evidence_valid_for_seconds={evidence.EVIDENCE_MAX_AGE_SECONDS}")
    runtime.block(
        "Paste this into the assemble dispatch's `evidence` input:", encoded
    )
    print(encoded, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(runtime.run(main))
