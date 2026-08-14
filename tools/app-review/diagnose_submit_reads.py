#!/usr/bin/env python3
"""GET-only diagnostic for the App Review SUBMIT-path App Store Connect reads.

`app-review-submit.yml` mode=submit once failed reproducibly, a few seconds in,
with `App Store Connect read request failed with status 400`. The structurally
read-only client in `asc_read.py` deliberately never surfaces Apple's response
body, so the offending `errors[]` code/title/detail is invisible. The GET-only
prepare/demo-preflight reconcile passes green, which places every such 400 in a
submit-specific read that preflight never issues.

Two invalid-field 400s were proven and fixed:

  * `_open_submissions()` once requested `fields[reviewSubmissions]=...,submitted`
    (`submitted` is not a valid reviewSubmissions field name);
  * `_submission_items()` once requested
    `fields[reviewSubmissionItems]=...,subscription` (`subscription` is not a
    valid reviewSubmissionItems field/relationship).

The fix aligned every submit-path read to SSHHIP's proven submission tool: it
sends no `fields[...]` sparse-field restriction on the reviewSubmissions/items
reads (and on the other submit reads), takes Apple's default fields, reads the
app-scoped `/v1/apps/{APP_ID}/reviewSubmissions` collection with client-side
state filtering, and uses `include=appStoreVersion` on the items read. That
removes the whole invalid-sparse-field class of 400.

This script reissues EVERY submit-phase read, in the same order and with the
same query shapes as `submission.SubmissionEngine`, each wrapped in its own
labeled try/except, and - unlike the production client - reads and prints
Apple's raw `errors[]` on an HTTP error so any residual 400 can be root-caused.
It covers, end to end:

  * `_version_resource` (appStoreVersions collection);
  * `_align_build` (the `/v1/builds` candidate read);
  * `_bound_build_version` (the bound build to-one read);
  * `_align_review_detail` (the appStoreReviewDetail to-one read);
  * `_open_submissions` (the app-scoped reviewSubmissions collection);
  * `_submission_items` against the first existing review submission (the read
    that 400'd on the invalid `subscription` field);
  * `_subscriptions_awaiting_review` (the subscriptionGroups include read);
  * the `_accept` reviewSubmission readback and `_version_state` version
    readback single `GET`s;
  * the content-reconcile reads, driven through the real
    `content.CandidateReadTransport` / `collect_content` path exactly as
    `SubmissionEngine.run()` reconciles.

Hard safety, non-negotiable, this handles a live credential:
  * It is GET-only. It imports neither `asc_write` nor `submission` (which
    imports the mutation boundary). Because `submission.py` imports `asc_write`,
    its query shapes cannot be imported without pulling in the mutation
    boundary, so they are reconstructed inline here from `core` constants and
    from verbatim copies of `submission.py` constants, and MUST stay identical
    to `submission.py`. It submits nothing; App Review is HELD.
  * It never prints, echoes, logs, or writes the API key, private key PEM,
    issuer id, key id, signed JWT/bearer token, the `Authorization` header, any
    request header, or any environment variable value. Its only output is
    Apple's response `errors[]` fields and the request path + query string,
    neither of which carries a secret.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Any, Mapping, Optional
import urllib.error
import urllib.parse
import urllib.request

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import content  # noqa: E402
import core  # noqa: E402
import runtime  # noqa: E402

VERSION = "0.1.17"

# Reconstructed verbatim from submission.py's OPEN_SUBMISSION_STATES and the
# submit-path read query shapes. Copied inline, not imported, because
# submission.py imports the mutation boundary asc_write and this diagnostic must
# import neither asc_write nor the mutating engine. Each query below MUST stay
# identical to the matching read in submission.py. Every submit read now sends
# NO `fields[...]` sparse-field restriction (Apple defaults), matching SSHHIP's
# proven tool; that is what removes the invalid-field 400s.
OPEN_SUBMISSION_STATES = (
    "READY_FOR_REVIEW",
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "UNRESOLVED_ISSUES",
)

# submission.py _version_resource
VERSION_PATH = f"/v1/apps/{core.APP_ID}/appStoreVersions"
VERSION_QUERY = {
    "filter[versionString]": VERSION,
    "filter[platform]": core.PLATFORM,
    "limit": "200",
}
# submission.py _open_submissions (app-scoped, no fields, client-side state)
OPEN_SUBMISSIONS_PATH = f"/v1/apps/{core.APP_ID}/reviewSubmissions"
OPEN_SUBMISSIONS_QUERY = {
    "filter[platform]": core.PLATFORM,
    "limit": "200",
}
# submission.py _submission_items
ITEMS_QUERY = {"include": "appStoreVersion", "limit": "200"}
# submission.py _subscriptions_awaiting_review
SUBSCRIPTION_GROUPS_PATH = f"/v1/apps/{core.APP_ID}/subscriptionGroups"
SUBSCRIPTION_GROUPS_QUERY = {"include": "subscriptions", "limit": "200"}


class ReadFailure(Exception):
    """A submit-phase read returned an HTTP error, with Apple's body captured."""


def _raw_get(
    credential: asc_read.Credential, path: str, query: Mapping[str, str]
) -> Mapping[str, Any]:
    """Issue one GET exactly as `asc_read.ReadSession` would, but on an HTTP
    error read Apple's raw response body and re-raise it as `ReadFailure` so the
    caller can print the `errors[]` the production client discards.

    The bearer token lives only in a local and only inside the request header;
    it is never printed. The response body is parsed only to extract Apple's
    documented `errors[]` fields, which are its whole purpose here.
    """
    url = asc_read.build_url(path, query)
    token = credential.bearer_token()
    opener = urllib.request.build_opener(asc_read.SameOriginRedirectHandler)
    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
        },
    )
    try:
        with opener.open(
            request, timeout=asc_read.REQUEST_TIMEOUT_SECONDS
        ) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        body_bytes = b""
        try:
            body_bytes = error.read() or b""
        except Exception:
            body_bytes = b""
        raise ReadFailure(
            _format_http_error(path, _query_string(query), error.code, body_bytes)
        )


class _BodyCapturingReadSession(asc_read.ReadSession):
    """A `ReadSession` that behaves exactly like production but, on an HTTP
    error, first captures Apple's raw `errors[]` (secret-free) before re-raising
    the same bounded error the parent would.

    The content-reconcile path (`content.CandidateReadTransport` ->
    `collect_content` -> `core.reconcile_authoritatively`) swallows the HTTP body
    on its way to `core.refuse`, so a plain run would hide any content-read 400.
    By reissuing every GET through this session the reconcile runs byte-identical
    to production, yet each HTTP error's body is recorded in `captured` and can
    be printed afterwards. Re-raising the parent's exact error types keeps the
    downstream transport/reconcile behavior unchanged.
    """

    def __init__(self, credential: asc_read.Credential):
        super().__init__(credential)
        self.captured: list[str] = []

    def get_url(self, url: str) -> Mapping[str, Any]:
        asc_read.validate_asc_url(url)
        request = urllib.request.Request(
            url,
            method="GET",
            headers={
                "Authorization": "Bearer " + self._bearer(),
                "Accept": "application/json",
            },
        )
        try:
            with self._opener.open(
                request, timeout=asc_read.REQUEST_TIMEOUT_SECONDS
            ) as response:
                payload = json.loads(response.read())
        except urllib.error.HTTPError as error:
            body_bytes = b""
            try:
                body_bytes = error.read() or b""
            except Exception:
                body_bytes = b""
            split = urllib.parse.urlsplit(url)
            self.captured.append(
                _format_http_error(split.path, split.query, error.code, body_bytes)
            )
            # Re-raise the same bounded error production would, so the transport
            # and reconcile see identical behavior.
            if error.code in (401, 403):
                raise asc_read.AppStoreConnectUnauthorized(
                    "App Store Connect refused the read credential"
                )
            raise asc_read.AppStoreConnectError(
                f"App Store Connect read request failed with status {error.code}"
            )
        except asc_read.AppStoreConnectError:
            raise
        except Exception:
            raise asc_read.AppStoreConnectError("App Store Connect read request failed")
        if not isinstance(payload, dict):
            raise asc_read.AppStoreConnectError("App Store Connect returned a malformed document")
        return payload


def _format_http_error(
    path: str, query_string: str, status: int, body: bytes
) -> str:
    """Render an HTTP error into a bounded, secret-free report. The request path
    and query carry no credential; the body is Apple's `errors[]` document."""
    lines = [
        f"  HTTP status: {status}",
        f"  request path: {path}",
        f"  request query: {query_string}",
    ]
    parsed: Any = None
    try:
        parsed = json.loads(body.decode("utf-8", "replace"))
    except Exception:
        parsed = None
    errors = parsed.get("errors") if isinstance(parsed, dict) else None
    if isinstance(errors, list) and errors:
        for index, entry in enumerate(errors):
            lines.append(f"  errors[{index}]:")
            if not isinstance(entry, dict):
                lines.append(f"    (non-object entry): {asc_read.redact(entry)}")
                continue
            for field in ("id", "status", "code", "title", "detail"):
                if field in entry:
                    lines.append(
                        f"    {field}: {asc_read.redact(entry.get(field))}"
                    )
            source = entry.get("source")
            if source is not None:
                lines.append(f"    source: {asc_read.redact(source)}")
    else:
        lines.append(
            "  errors[]: absent or unparseable; raw (redacted): "
            + asc_read.redact(body.decode('utf-8', 'replace'))
        )
    return "\n".join(lines)


def _query_string(query: Mapping[str, str]) -> str:
    return "&".join(f"{key}={value}" for key, value in query.items())


def _resolve_version_id(payload: Mapping[str, Any]) -> Optional[str]:
    """Pick the single 0.1.17 IOS appStoreVersion id, mirroring
    `_version_resource`'s matching, or None if it is absent or ambiguous."""
    data = payload.get("data")
    if not isinstance(data, list):
        return None
    matching = []
    for entry in data:
        attributes = entry.get("attributes") if isinstance(entry, dict) else None
        if not isinstance(attributes, dict):
            continue
        if (
            attributes.get("versionString") == VERSION
            and attributes.get("platform") == core.PLATFORM
            and isinstance(entry.get("id"), str)
        ):
            matching.append(entry["id"])
    return matching[0] if len(matching) == 1 else None


def _first_submission_id(payload: Mapping[str, Any]) -> Optional[str]:
    """Return the first review submission id in an app-scoped reviewSubmissions
    payload, or None when the app holds no review submission yet. `_submission_items`
    and the `_accept` readback both need an existing submission id to exercise."""
    data = payload.get("data")
    if not isinstance(data, list):
        return None
    for entry in data:
        if isinstance(entry, dict) and isinstance(entry.get("id"), str):
            return entry["id"]
    return None


def _labeled_get(
    credential: asc_read.Credential,
    step: str,
    label: str,
    path: str,
    query: Mapping[str, str],
    failures: list[str],
) -> Optional[Mapping[str, Any]]:
    """Issue one GET, report it, and return its payload (None on HTTP error)."""
    print(f"{step} {label}: GET {path}")
    print(f"      query: {_query_string(query)}")
    try:
        payload = _raw_get(credential, path, query)
        print("      SUCCESS (HTTP 200)")
        return payload
    except ReadFailure as failure:
        print("      FAILURE:")
        print(str(failure))
        failures.append(label)
        return None


def _run_content_reconcile(
    credential: asc_read.Credential, failures: list[str]
) -> None:
    """Exercise the content-reconcile reads through the real
    `content.CandidateReadTransport` / `collect_content` path exactly as
    `SubmissionEngine.run()` does, capturing Apple's body on any HTTP error."""
    print("[10/10] content_reconcile: exercising the content-reconcile reads via")
    print("      content.CandidateReadTransport -> collect_content (real path)")
    repo_root = Path(__file__).resolve().parents[2]
    try:
        manifest = runtime.load_manifest(VERSION, root=repo_root)
        verified_files = content.verify_manifest_files(manifest, repo_root)
    except Exception as error:
        # A local manifest/asset problem is not the Apple 400 under
        # investigation; report it bounded and do not count it as an HTTP read
        # failure.
        print(
            "      SKIPPED: could not load the approved manifest or verify "
            "reviewed bytes locally:"
        )
        print(f"        {asc_read.redact(error)}")
        return

    session = _BodyCapturingReadSession(credential)
    transport = content.CandidateReadTransport(
        session, manifest["candidate"], verified_files
    )
    client = core.ReadOnlyASCClient(transport)
    try:
        reconciliation = core.reconcile_authoritatively(manifest, client)
        print(
            "      SUCCESS: every content-reconcile read returned HTTP 200 "
            f"(reconcile outcome: {asc_read.redact(reconciliation.outcome)})"
        )
    except core.AppReviewError as error:
        if session.captured:
            print("      FAILURE: a content-reconcile read returned an HTTP error:")
            for report in session.captured:
                print(report)
            failures.append("content_reconcile")
        else:
            # Reconcile refused for a non-transport reason (content mismatch,
            # absent version, and so on). That is not the 400 under
            # investigation; report it bounded and do not count it as an HTTP
            # read failure.
            print(
                "      NOTE: no content-reconcile read returned an HTTP error; "
                "reconcile refused for a non-transport reason:"
            )
            print(f"        {asc_read.redact(error)}")
    except ReadFailure as failure:
        # Defensive: production swallows the body before this point, but if a
        # ReadFailure ever escapes, surface it.
        print("      FAILURE:")
        print(str(failure))
        failures.append("content_reconcile")


def main() -> int:
    print("App Review submit-path read diagnostic (GET-only, no secrets)")
    print(f"app: {core.APP_ID}  version: {VERSION}  platform: {core.PLATFORM}")
    print()

    try:
        credential = asc_read.Credential.from_environment()
    except asc_read.AppStoreConnectError as error:
        print(f"FATAL: could not build credential: {asc_read.redact(error)}")
        return 2

    # The `/v1/builds` candidate read needs the approved build number; load it
    # from the manifest so the diagnostic issues the same `_align_build` query.
    build_number: Optional[str] = None
    try:
        manifest = runtime.load_manifest(
            VERSION, root=Path(__file__).resolve().parents[2]
        )
        candidate = manifest["candidate"]
        if isinstance(candidate, Mapping):
            value = candidate.get("build")
            if isinstance(value, str):
                build_number = value
    except Exception as error:
        print(
            "NOTE: could not load the approved manifest for the build number; "
            f"the builds read will be skipped: {asc_read.redact(error)}"
        )

    failures: list[str] = []
    version_id: Optional[str] = None
    submission_id: Optional[str] = None

    # Step 1 - _version_resource: the appStoreVersions collection query.
    payload = _labeled_get(
        credential, "[1/10]", "version_resource", VERSION_PATH, VERSION_QUERY, failures
    )
    if payload is not None:
        version_id = _resolve_version_id(payload)
        if version_id is None:
            print(
                "      (the 0.1.17 IOS version was absent or ambiguous; the "
                "version-scoped reads below are skipped)"
            )

    # Step 2 - _align_build: the /v1/builds candidate read.
    print()
    if build_number is None:
        print("[2/10] align_build: SKIPPED (no build number from the manifest)")
    else:
        _labeled_get(
            credential,
            "[2/10]",
            "align_build",
            "/v1/builds",
            {
                "filter[app]": core.APP_ID,
                "filter[version]": build_number,
                "filter[preReleaseVersion.version]": VERSION,
                "limit": "200",
            },
            failures,
        )

    # Step 3 - _bound_build_version: the bound build to-one read.
    print()
    if version_id is None:
        print("[3/10] bound_build_version: SKIPPED (no version id from step 1)")
    else:
        _labeled_get(
            credential,
            "[3/10]",
            "bound_build_version",
            f"/v1/appStoreVersions/{version_id}/build",
            {},
            failures,
        )

    # Step 4 - _align_review_detail: the appStoreReviewDetail to-one read.
    print()
    if version_id is None:
        print("[4/10] review_detail: SKIPPED (no version id from step 1)")
    else:
        _labeled_get(
            credential,
            "[4/10]",
            "review_detail",
            f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail",
            {},
            failures,
        )

    # Step 5 - _open_submissions: the app-scoped reviewSubmissions collection.
    print()
    payload = _labeled_get(
        credential,
        "[5/10]",
        "open_submissions",
        OPEN_SUBMISSIONS_PATH,
        OPEN_SUBMISSIONS_QUERY,
        failures,
    )
    if payload is not None:
        submission_id = _first_submission_id(payload)
        if submission_id is None:
            print(
                "      (the app holds no review submission yet; the "
                "submission-scoped reads below are skipped)"
            )

    # Step 6 - _submission_items: the items read that 400'd on `subscription`.
    print()
    if submission_id is None:
        print("[6/10] submission_items: SKIPPED (no existing review submission)")
    else:
        _labeled_get(
            credential,
            "[6/10]",
            "submission_items",
            f"/v1/reviewSubmissions/{submission_id}/items",
            ITEMS_QUERY,
            failures,
        )

    # Step 7 - _subscriptions_awaiting_review: the subscriptionGroups include read.
    print()
    _labeled_get(
        credential,
        "[7/10]",
        "subscription_groups",
        SUBSCRIPTION_GROUPS_PATH,
        SUBSCRIPTION_GROUPS_QUERY,
        failures,
    )

    # Step 8 - _accept readback: the single reviewSubmission GET.
    print()
    if submission_id is None:
        print("[8/10] accept_submission_readback: SKIPPED (no existing review submission)")
    else:
        _labeled_get(
            credential,
            "[8/10]",
            "accept_submission_readback",
            f"/v1/reviewSubmissions/{submission_id}",
            {},
            failures,
        )

    # Step 9 - _version_state readback: the single appStoreVersion GET.
    print()
    if version_id is None:
        print("[9/10] version_state_readback: SKIPPED (no version id from step 1)")
    else:
        _labeled_get(
            credential,
            "[9/10]",
            "version_state_readback",
            f"/v1/appStoreVersions/{version_id}",
            {},
            failures,
        )

    # Step 10 - the content-reconcile reads via the real transport.
    print()
    _run_content_reconcile(credential, failures)

    print()
    print("summary:")
    if failures:
        print(f"  FAILED reads (HTTP error): {', '.join(failures)}")
        return 1
    print("  every issued submit-path read returned HTTP 200")
    if version_id is None:
        print("  NOTE: the 0.1.17 IOS version was absent; version-scoped reads were skipped")
    if submission_id is None:
        print("  NOTE: no review submission existed; submission-scoped reads were skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
