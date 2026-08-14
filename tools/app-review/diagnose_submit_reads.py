#!/usr/bin/env python3
"""GET-only diagnostic for the App Review SUBMIT reconcile-read HTTP 400.

`app-review-submit.yml` mode=submit fails reproducibly, a few seconds in, with
`App Store Connect read request failed with status 400`. The structurally
read-only client in `asc_read.py` deliberately never surfaces Apple's response
body, so the offending `errors[]` code/title/detail is invisible. The GET-only
prepare/demo-preflight reconcile passes green, which places the 400 in a
submit-specific read that preflight never issues.

This script reissues exactly the submit-phase reads that
`submission.SubmissionEngine._align_candidate()` performs, in the same order,
each wrapped in its own labeled try/except, and - unlike the production client -
reads and prints Apple's raw `errors[]` on an HTTP error so the 400 can be
root-caused.

Hard safety, non-negotiable, this handles a live credential:
  * It is GET-only. It imports neither `asc_write` nor `submission` (which
    imports the mutation boundary). It reconstructs the read queries inline from
    `core` constants instead. It submits nothing; App Review is HELD.
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
import urllib.request

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import core  # noqa: E402

VERSION = "0.1.17"

# The exact submit-phase read queries, reconstructed from `core` constants so
# this diagnostic issues byte-identical requests to
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
        raise ReadFailure(_format_http_error(path, query, error.code, body_bytes))


def _format_http_error(
    path: str, query: Mapping[str, str], status: int, body: bytes
) -> str:
    """Render an HTTP error into a bounded, secret-free report. The request path
    and query carry no credential; the body is Apple's `errors[]` document."""
    lines = [
        f"  HTTP status: {status}",
        f"  request path: {path}",
        f"  request query: {_query_string(query)}",
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
    print(f"[1/3] version_resource: GET {version_path}")
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
            print(f"      SUCCESS (HTTP 200); resolved version id")
    except ReadFailure as failure:
        print("      FAILURE:")
        print(str(failure))
        failures.append("version_resource")

    # Step 2 - _bound_build_version: the bound build to-one read.
    print()
    if version_id is None:
        print(
            "[2/3] bound_build_version: SKIPPED (no version id from step 1)"
        )
    else:
        build_path = f"/v1/appStoreVersions/{version_id}/build"
        print(f"[2/3] bound_build_version: GET {build_path}")
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
            "[3/3] review_detail: SKIPPED (no version id from step 1)"
        )
    else:
        detail_path = f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail"
        print(f"[3/3] review_detail: GET {detail_path}")
        print(f"      query: {_query_string(REVIEW_DETAIL_FIELDS)}")
        try:
            _raw_get(credential, detail_path, REVIEW_DETAIL_FIELDS)
            print("      SUCCESS (HTTP 200)")
        except ReadFailure as failure:
            print("      FAILURE:")
            print(str(failure))
            failures.append("review_detail")

    print()
    print("summary:")
    if failures:
        print(f"  FAILED reads: {', '.join(failures)}")
        return 1
    if version_id is None:
        print(
            "  all issued reads returned HTTP 200, but the version was absent or "
            "ambiguous so the build/review-detail reads were not issued"
        )
        return 0
    print("  all submit-phase reads returned HTTP 200")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
