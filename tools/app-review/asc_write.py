#!/usr/bin/env python3
"""The single mutation-capable App Store Connect boundary in this repository.

Nothing else in `tools/app-review/` can send a non-GET request to Apple. Only
`submission.py` imports this module, and only `submit.py --mode submit` reaches
`submission.py`, so the mutation lane is one import edge wide and is checked by
`test/app-review-lanes-test.py`.

Every write here is expressed as one exact App Store Connect resource document.
There is no generic request helper, no DELETE, and no upload path: this boundary
can attach and submit an already-prepared candidate, and it cannot create,
replace, or remove listing copy, screenshots, products, or the app record.
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

ALLOWED_METHODS = ("POST", "PATCH")


class ChangeSession:
    """Sends exactly the two App Store Connect methods this pipeline may use."""

    def __init__(self, credential: asc_read.Credential):
        self._credential = credential
        self._opener = urllib.request.build_opener(asc_read.SameOriginRedirectHandler)
        self.writes: list[str] = []

    def _send(
        self, method: str, path: str, document: Mapping[str, Any]
    ) -> Optional[Mapping[str, Any]]:
        if method not in ALLOWED_METHODS:
            raise asc_read.AppStoreConnectError(
                "this App Store Connect boundary sends only POST and PATCH"
            )
        url = asc_read.build_url(path, {})
        request = urllib.request.Request(
            url,
            data=json.dumps(document, separators=(",", ":")).encode("utf-8"),
            method=method,
            headers={
                "Authorization": "Bearer " + self._credential.bearer_token(),
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        self.writes.append(f"{method} {path}")
        try:
            with self._opener.open(
                request, timeout=asc_read.REQUEST_TIMEOUT_SECONDS
            ) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise asc_read.AppStoreConnectUnauthorized(
                    "App Store Connect refused the mutation credential"
                )
            # A conflict means Apple already holds the state we asked for or a
            # competing state. The caller reconciles by reading, never by retrying.
            raise asc_read.AppStoreConnectError(
                f"App Store Connect {method} was rejected with status {error.code}"
            )
        except asc_read.AppStoreConnectError:
            raise
        except Exception:
            raise asc_read.AppStoreConnectError(
                f"App Store Connect {method} request failed"
            )
        if not body:
            return None
        payload = json.loads(body)
        if not isinstance(payload, dict):
            raise asc_read.AppStoreConnectError(
                "App Store Connect returned a malformed document"
            )
        return payload

    # -- exact resource mutations ------------------------------------------

    def set_release_type(self, version_id: str, release_type: str) -> None:
        self._send(
            "PATCH",
            f"/v1/appStoreVersions/{version_id}",
            {
                "data": {
                    "type": "appStoreVersions",
                    "id": version_id,
                    "attributes": {"releaseType": release_type},
                }
            },
        )

    def bind_build(self, version_id: str, build_id: str) -> None:
        self._send(
            "PATCH",
            f"/v1/appStoreVersions/{version_id}/relationships/build",
            {"data": {"type": "builds", "id": build_id}},
        )

    def set_review_detail(self, detail_id: str, notes: str) -> None:
        self._send(
            "PATCH",
            f"/v1/appStoreReviewDetails/{detail_id}",
            {
                "data": {
                    "type": "appStoreReviewDetails",
                    "id": detail_id,
                    "attributes": {"notes": notes, "demoAccountRequired": False},
                }
            },
        )

    def create_review_submission(self, app_id: str, platform: str) -> str:
        payload = self._send(
            "POST",
            "/v1/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": platform},
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}}
                    },
                }
            },
        )
        return _created_identifier(payload, "reviewSubmissions")

    def add_version_item(self, submission_id: str, version_id: str) -> str:
        return self._add_item(
            submission_id, "appStoreVersion", "appStoreVersions", version_id
        )

    def add_subscription_item(self, submission_id: str, subscription_id: str) -> str:
        return self._add_item(
            submission_id, "subscription", "subscriptions", subscription_id
        )

    def _add_item(
        self, submission_id: str, name: str, resource_type: str, identifier: str
    ) -> str:
        payload = self._send(
            "POST",
            "/v1/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {
                            "data": {
                                "type": "reviewSubmissions",
                                "id": submission_id,
                            }
                        },
                        name: {"data": {"type": resource_type, "id": identifier}},
                    },
                }
            },
        )
        return _created_identifier(payload, "reviewSubmissionItems")

    def submit_for_review(self, submission_id: str) -> None:
        self._send(
            "PATCH",
            f"/v1/reviewSubmissions/{submission_id}",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "id": submission_id,
                    "attributes": {"submitted": True},
                }
            },
        )


def _created_identifier(payload: Optional[Mapping[str, Any]], expected: str) -> str:
    data = payload.get("data") if isinstance(payload, Mapping) else None
    entry = asc_read.resource(data) if isinstance(data, dict) else None
    if entry is None or entry.get("type") != expected:
        raise asc_read.AppStoreConnectError(
            f"App Store Connect did not return a created {expected} resource"
        )
    return entry["id"]
