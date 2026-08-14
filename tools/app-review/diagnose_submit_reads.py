#!/usr/bin/env python3
"""GET-only diagnostic for the App Review SUBMIT reconcile-read HTTP 400.

`app-review-submit.yml` mode=submit fails reproducibly, a few seconds in, with
`App Store Connect read request failed with status 400`. The structurally
read-only client in `asc_read.py` deliberately never surfaces Apple's response
body, so the offending `errors[]` code/title/detail is invisible. The GET-only
prepare/demo-preflight reconcile passes green, which places the 400 in a
submit-specific read that preflight never issues.

This script reissues exactly the submit-phase reads, in the same order, each
wrapped in its own labeled try/except, and - unlike the production client -
reads and prints Apple's raw `errors[]` on an HTTP error so the 400 can be
root-caused. It covers:

  * the three `SubmissionEngine._align_candidate()` reads (version resource,
    bound build, review detail) - already GET-clean per an earlier run;
  * the submit-only `_open_submissions()` read of `/v1/reviewSubmissions`. An
    earlier GET-only run (31782606696) proved its 400 came from an invalid
    `fields[reviewSubmissions]` entry (`submitted` is not a valid field name),
    NOT from `filter[platform]`. This diagnostic now issues the CORRECTED query
    (`fields[reviewSubmissions]=state,platform`, matching the fixed
    `submission.py`), so a green run confirms the corrected read returns 200;
  * the same corrected `/v1/reviewSubmissions` read with `filter[platform]`
    removed, kept only to re-confirm that `filter[platform]` is a supported
    filter on that collection (the corrected read must return 200 both ways),
    since the fix deliberately keeps `filter[platform]`;
  * the content-reconcile reads, driven through the real
    `content.CandidateReadTransport` / `collect_content` path exactly as
    `SubmissionEngine.run()` reconciles, so a 400 anywhere in that path is
    captured too.

Hard safety, non-negotiable, this handles a live credential:
  * It is GET-only. It imports neither `asc_write` nor `submission` (which
    imports the mutation boundary). It reconstructs the submit-phase read
    queries inline from `core` constants and from verbatim copies of
    `submission.py` constants instead. It submits nothing; App Review is HELD.
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

# The exact submit-phase align-read queries, reconstructed from `core` constants
# so this diagnostic issues byte-identical requests to
# `submission.SubmissionEngine` without importing the mutating engine. See
# tools/app-review/submission.py: _version_resource, _bound_build_version,
# _align_review_detail.
VERSION_QUERY = {
    "filter[versionString]": VERSION,
    "filter[platform]": core.PLATFORM,
    "fields[appStoreVersions]": "versionString,appVersionState,platform,releaseType,build",
    "limit": "50",
}
BUILD_FIELDS = {"fields[builds]": "version,expired,processingState"}
REVIEW_DETAIL_FIELDS = {
    "fields[appStoreReviewDetails]": "notes,demoAccountRequired"
}

# Reconstructed verbatim from submission.py's OPEN_SUBMISSION_STATES and the
# CORRECTED `_open_submissions()` read. Copied inline, not imported, because
# submission.py imports the mutation boundary asc_write and this diagnostic must
# import neither asc_write nor the mutating engine. The `fields` list here MUST
# stay identical to submission.py's `_open_submissions()` query: only valid
# reviewSubmissions fields (Apple's set includes state, platform, submittedDate,
# createdDate). `submitted` was invalid and caused the 400; it is dropped here
# exactly as it was dropped in submission.py.
OPEN_SUBMISSION_STATES = (
    "READY_FOR_REVIEW",
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "UNRESOLVED_ISSUES",
)
OPEN_SUBMISSIONS_PATH = "/v1/reviewSubmissions"
OPEN_SUBMISSIONS_QUERY = {
    "filter[app]": core.APP_ID,
    "filter[platform]": core.PLATFORM,
    "filter[state]": ",".join(OPEN_SUBMISSION_STATES),
    "fields[reviewSubmissions]": "state,platform",
    "limit": "50",
}
# The same corrected read with `filter[platform]` removed (filter[app] +
# filter[state] only), kept to re-confirm that `filter[platform]` is a supported
# filter on `/v1/reviewSubmissions` - the corrected read must return 200 both
# with and without it, since the fix keeps `filter[platform]`.
OPEN_SUBMISSIONS_QUERY_NO_PLATFORM = {
    key: value
    for key, value in OPEN_SUBMISSIONS_QUERY.items()
    if key != "filter[platform]"
}


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


def _reviewsubmissions_read(
    credential: asc_read.Credential,
    step: str,
    label: str,
    query: Mapping[str, str],
    failures: list[str],
) -> bool:
    """Issue one `/v1/reviewSubmissions` read and report it. Returns True on
    HTTP 200, False on any HTTP error."""
    print(f"{step} {label}: GET {OPEN_SUBMISSIONS_PATH}")
    print(f"      query: {_query_string(query)}")
    try:
        _raw_get(credential, OPEN_SUBMISSIONS_PATH, query)
        print("      SUCCESS (HTTP 200)")
        return True
    except ReadFailure as failure:
        print("      FAILURE:")
        print(str(failure))
        failures.append(label)
        return False


def _run_content_reconcile(
    credential: asc_read.Credential, failures: list[str]
) -> None:
    """Exercise the content-reconcile reads through the real
    `content.CandidateReadTransport` / `collect_content` path exactly as
    `SubmissionEngine.run()` does, capturing Apple's body on any HTTP error."""
    print("[6/6] content_reconcile: exercising the content-reconcile reads via")
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
    print("App Review submit reconcile-read diagnostic (GET-only, no secrets)")
    print(f"app: {core.APP_ID}  version: {VERSION}  platform: {core.PLATFORM}")
    print()

    try:
        credential = asc_read.Credential.from_environment()
    except asc_read.AppStoreConnectError as error:
        print(f"FATAL: could not build credential: {asc_read.redact(error)}")
        return 2

    failures: list[str] = []
    version_id: Optional[str] = None

    # Step 1 - _version_resource: the appStoreVersions collection query.
    version_path = f"/v1/apps/{core.APP_ID}/appStoreVersions"
    print(f"[1/6] version_resource: GET {version_path}")
    print(f"      query: {_query_string(VERSION_QUERY)}")
    try:
        payload = _raw_get(credential, version_path, VERSION_QUERY)
        version_id = _resolve_version_id(payload)
        if version_id is None:
            print(
                "      SUCCESS (HTTP 200) but the 0.1.17 IOS version was absent "
                "or ambiguous; cannot resolve version id for steps 2-3"
            )
        else:
            print("      SUCCESS (HTTP 200); resolved version id")
    except ReadFailure as failure:
        print("      FAILURE:")
        print(str(failure))
        failures.append("version_resource")

    # Step 2 - _bound_build_version: the bound build to-one read.
    print()
    if version_id is None:
        print(
            "[2/6] bound_build_version: SKIPPED (no version id from step 1)"
        )
    else:
        build_path = f"/v1/appStoreVersions/{version_id}/build"
        print(f"[2/6] bound_build_version: GET {build_path}")
        print(f"      query: {_query_string(BUILD_FIELDS)}")
        try:
            _raw_get(credential, build_path, BUILD_FIELDS)
            print("      SUCCESS (HTTP 200)")
        except ReadFailure as failure:
            print("      FAILURE:")
            print(str(failure))
            failures.append("bound_build_version")

    # Step 3 - _align_review_detail: the appStoreReviewDetail to-one read.
    print()
    if version_id is None:
        print(
            "[3/6] review_detail: SKIPPED (no version id from step 1)"
        )
    else:
        detail_path = f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail"
        print(f"[3/6] review_detail: GET {detail_path}")
        print(f"      query: {_query_string(REVIEW_DETAIL_FIELDS)}")
        try:
            _raw_get(credential, detail_path, REVIEW_DETAIL_FIELDS)
            print("      SUCCESS (HTTP 200)")
        except ReadFailure as failure:
            print("      FAILURE:")
            print(str(failure))
            failures.append("review_detail")

    # Step 4 - _open_submissions: the submit-only /v1/reviewSubmissions read,
    # the CORRECTED query (fields=state,platform, WITH filter[platform]). This
    # is the read that 400'd on the invalid `submitted` field; a 200 here
    # confirms the fix.
    print()
    open_with_platform_ok = _reviewsubmissions_read(
        credential,
        "[4/6]",
        "open_submissions_with_platform",
        OPEN_SUBMISSIONS_QUERY,
        failures,
    )

    # Step 5 - the same corrected read WITHOUT filter[platform], retained to
    # re-confirm that this filter was not the cause of the 400.
    print()
    open_without_platform_ok = _reviewsubmissions_read(
        credential,
        "[5/6]",
        "open_submissions_without_platform",
        OPEN_SUBMISSIONS_QUERY_NO_PLATFORM,
        failures,
    )

    # Step 6 - the content-reconcile reads via the real transport.
    print()
    _run_content_reconcile(credential, failures)

    print()
    print("summary:")
    # Report the corrected reviewSubmissions read explicitly. The 400 was the
    # invalid `submitted` field, now dropped; both reads should return 200.
    if open_with_platform_ok and open_without_platform_ok:
        print(
            "  corrected /v1/reviewSubmissions read returned HTTP 200 both WITH "
            "and WITHOUT filter[platform]: the fix (dropping the invalid "
            "`submitted` field) resolves the read and filter[platform] is fine"
        )
    elif open_with_platform_ok and not open_without_platform_ok:
        print(
            "  corrected /v1/reviewSubmissions read returned HTTP 200 WITH "
            "filter[platform] but FAILS without it (unexpected)"
        )
    else:
        print(
            "  corrected /v1/reviewSubmissions read still FAILS: the invalid "
            "`submitted` field was not the whole cause; inspect errors[] above"
        )

    if failures:
        print(f"  FAILED reads (HTTP error): {', '.join(failures)}")
        return 1
    if version_id is None:
        print(
            "  all issued reads returned HTTP 200, but the version was absent or "
            "ambiguous so the build/review-detail reads were not issued"
        )
        return 0
    print("  all issued reads returned HTTP 200")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
