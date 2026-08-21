#!/usr/bin/env python3
"""One-shot Guideline 3.1.2 remediation: append Apple's standard EULA line.

Apple rejected 0.1.17 because the en-US App Description lacked a functional
Terms of Use (EULA) link. Eddie uses Apple's standard EULA, so the required
fix is this exact URL in the description, nothing else.

This script is deliberately not a listing-sync feature and does not import
`asc_write` or `submission`. It GETs the live 0.1.17 en-US localization,
appends one line after the subscription auto-renewal paragraph when that URL
is absent, PATCHes only `description`, then GETs again to prove the prior
copy is intact. `listingPolicy` stays `observe`. It never submits for review
and never edits any other listing field or locale.

Dispatch (after this workflow is on main):

    gh workflow run app-review-eula-append.yml \\
      -R kunchenguid/eddies-wallet --ref main -f confirm=APPEND-EULA
"""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import os
import sys
from typing import Any, Mapping
import urllib.error
import urllib.request

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import core  # noqa: E402

APP_ID = "6795664301"
VERSION_ID = "e81dafd9-25cb-438e-8240-4764dbdc0675"
LOCALIZATION_ID = "3d89b9a4-a341-439b-a6cb-2ead4e2db35a"
EXPECTED_VERSION = "0.1.17"
EXPECTED_LOCALE = "en-US"
CONFIRM_VALUE = "APPEND-EULA"
CONFIRM_ENV = "EDDIES_EULA_APPEND_CONFIRM"
EULA_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
EULA_LINE = f"Terms of Use (EULA): {EULA_URL}"
ANCHOR = (
    "You can manage or cancel subscriptions in your Apple Account settings "
    "after purchase."
)
MAX_DESCRIPTION_CHARS = 4000
VERSION_PATH = f"/v1/appStoreVersions/{VERSION_ID}"
LOCALIZATION_PATH = f"/v1/appStoreVersionLocalizations/{LOCALIZATION_ID}"
VERSION_QUERY = {"fields[appStoreVersions]": "versionString,appVersionState"}
LOCALIZATION_QUERY = {
    "fields[appStoreVersionLocalizations]": (
        "description,locale,keywords,marketingUrl,promotionalText,"
        "supportUrl,whatsNew"
    )
}


class ConfirmError(core.BoundedError):
    """The dispatcher did not type the exact one-shot confirm token."""


class BoundMismatch(core.BoundedError):
    """The live Apple resource is not the pinned 0.1.17 en-US localization."""


class CannotAppend(core.BoundedError):
    """The live description cannot accept the EULA line without clobbering copy."""


class VerifyError(core.BoundedError):
    """The read-back did not prove the bounded append."""


@dataclass(frozen=True)
class Report:
    action: str
    before_present: bool
    before_chars: int
    after_present: bool
    after_chars: int
    prior_copy_intact: bool
    other_fields_unchanged: bool
    length_ok: bool
    version: str
    locale: str


def eula_present(description: str) -> bool:
    return EULA_URL in description


def append_eula_line(description: str) -> str:
    """Insert the EULA line after the auto-renewal paragraph, or refuse."""
    if eula_present(description):
        raise CannotAppend("the standard EULA link is already present")
    index = description.find(ANCHOR)
    if index < 0:
        raise CannotAppend(
            "the auto-renewal paragraph was not found in the live description"
        )
    insert_at = index + len(ANCHOR)
    updated = description[:insert_at] + "\n\n" + EULA_LINE + description[insert_at:]
    if len(updated) > MAX_DESCRIPTION_CHARS:
        raise CannotAppend(
            f"appending the EULA line would exceed {MAX_DESCRIPTION_CHARS} characters"
        )
    return updated


def prior_copy_intact(original: str, updated: str) -> bool:
    if eula_present(original):
        return original == updated
    try:
        return updated == append_eula_line(original)
    except CannotAppend:
        return False


def other_fields(attributes: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in attributes.items() if key != "description"}


def format_report(report: Report) -> str:
    def flag(name: str, value: bool) -> str:
        return f"{name}={'yes' if value else 'no'}"

    return "\n".join(
        (
            f"target: app={APP_ID} version={report.version} locale={report.locale} "
            f"localization={LOCALIZATION_ID}",
            f"before: {flag('eula_present', report.before_present)} "
            f"chars={report.before_chars}",
            f"action: {report.action}",
            f"after: {flag('eula_present', report.after_present)} "
            f"chars={report.after_chars} "
            f"{flag('prior_copy_intact', report.prior_copy_intact)} "
            f"{flag('other_fields_unchanged', report.other_fields_unchanged)} "
            f"{flag('length_ok', report.length_ok)}",
        )
    )


class AppleSession:
    """GET via the read-only client; one localization-description PATCH of its own."""

    def __init__(self, credential: asc_read.Credential):
        self._reads = asc_read.ReadSession(credential)
        self._credential = credential
        self._opener = urllib.request.build_opener(asc_read.SameOriginRedirectHandler)

    def get(self, path: str, query: Mapping[str, str]) -> Mapping[str, Any]:
        return self._reads.get(path, query)

    def patch(self, path: str, document: Mapping[str, Any]) -> Mapping[str, Any]:
        if path != LOCALIZATION_PATH:
            raise CannotAppend("this remediation may PATCH only the pinned en-US localization")
        attributes = document.get("data", {}).get("attributes") if isinstance(document, dict) else None
        if not isinstance(attributes, dict) or set(attributes) != {"description"}:
            raise CannotAppend("this remediation may PATCH only the description field")
        url = asc_read.build_url(path, {})
        request = urllib.request.Request(
            url,
            data=json.dumps(document, separators=(",", ":")).encode("utf-8"),
            method="PATCH",
            headers={
                "Authorization": "Bearer " + self._credential.bearer_token(),
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with self._opener.open(
                request, timeout=asc_read.REQUEST_TIMEOUT_SECONDS
            ) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            _raise_patch_failure(error)
        except asc_read.AppStoreConnectError:
            raise
        except Exception:
            raise asc_read.AppStoreConnectError(
                "App Store Connect PATCH request failed"
            )
        if not body:
            return {}
        payload = json.loads(body)
        if not isinstance(payload, dict):
            raise asc_read.AppStoreConnectError(
                "App Store Connect returned a malformed document"
            )
        return payload


def _raise_patch_failure(error: urllib.error.HTTPError) -> None:
    summary = _apple_error_summary(error)
    if error.code in (401, 403):
        raise asc_read.AppStoreConnectUnauthorized(
            "App Store Connect refused the mutation credential "
            f"({summary}). The key role may lack metadata-write."
        )
    raise asc_read.AppStoreConnectError(
        f"App Store Connect PATCH was rejected ({summary})"
    )


def _apple_error_summary(error: urllib.error.HTTPError) -> str:
    try:
        payload = json.loads(error.read())
    except Exception:
        return f"status {error.code}"
    errors = payload.get("errors") if isinstance(payload, dict) else None
    if not isinstance(errors, list) or not errors:
        return f"status {error.code}"
    parts = []
    for entry in errors[:3]:
        if not isinstance(entry, dict):
            continue
        code = asc_read.redact(entry.get("code", ""))
        title = asc_read.redact(entry.get("title", ""))
        token = "/".join(piece for piece in (code, title) if piece and piece != "?")
        if token:
            parts.append(token)
    if not parts:
        return f"status {error.code}"
    return f"status {error.code} " + "; ".join(parts)


def _require_confirm(confirm: str) -> None:
    if confirm != CONFIRM_VALUE:
        raise ConfirmError(
            f"type {CONFIRM_VALUE} to confirm this one-shot 0.1.17 en-US description write"
        )


def _resource(payload: Mapping[str, Any], expected_type: str, expected_id: str) -> Mapping[str, Any]:
    entry = asc_read.resource(payload.get("data"))
    if entry["type"] != expected_type or entry["id"] != expected_id:
        raise BoundMismatch(
            f"App Store Connect returned a different {expected_type} resource"
        )
    return entry


def remediate(session: AppleSession, *, confirm: str) -> Report:
    _require_confirm(confirm)

    version_payload = session.get(VERSION_PATH, VERSION_QUERY)
    version = _resource(version_payload, "appStoreVersions", VERSION_ID)
    version_string = asc_read.text(asc_read.attributes(version), "versionString")
    if version_string != EXPECTED_VERSION:
        raise BoundMismatch(
            f"pinned version id is {version_string or 'empty'}, not {EXPECTED_VERSION}"
        )

    before_payload = session.get(LOCALIZATION_PATH, LOCALIZATION_QUERY)
    before_entry = _resource(before_payload, "appStoreVersionLocalizations", LOCALIZATION_ID)
    before_attrs = dict(asc_read.attributes(before_entry))
    locale = asc_read.text(before_attrs, "locale")
    if locale != EXPECTED_LOCALE:
        raise BoundMismatch(f"pinned localization is {locale or 'empty'}, not {EXPECTED_LOCALE}")

    original = asc_read.text(before_attrs, "description")
    before_had_eula = eula_present(original)
    snapshot = other_fields(before_attrs)

    if before_had_eula:
        action = "already-present"
        updated = original
    else:
        updated = append_eula_line(original)
        session.patch(
            LOCALIZATION_PATH,
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": LOCALIZATION_ID,
                    "attributes": {"description": updated},
                }
            },
        )
        action = "patched"

    after_payload = session.get(LOCALIZATION_PATH, LOCALIZATION_QUERY)
    after_entry = _resource(after_payload, "appStoreVersionLocalizations", LOCALIZATION_ID)
    after_attrs = dict(asc_read.attributes(after_entry))
    live = asc_read.text(after_attrs, "description")
    intact = prior_copy_intact(original, live)
    unchanged = other_fields(after_attrs) == snapshot
    present = eula_present(live)
    length_ok = len(live) <= MAX_DESCRIPTION_CHARS
    if live != updated:
        raise VerifyError("read-back description does not match the appended value")
    if not present:
        raise VerifyError("read-back description still lacks the standard EULA link")
    if not intact:
        raise VerifyError("read-back description did not preserve the prior copy")
    if not unchanged:
        raise VerifyError("a listing field other than description changed")
    if not length_ok:
        raise VerifyError(
            f"read-back description exceeds {MAX_DESCRIPTION_CHARS} characters"
        )

    return Report(
        action=action,
        before_present=before_had_eula,
        before_chars=len(original),
        after_present=present,
        after_chars=len(live),
        prior_copy_intact=intact,
        other_fields_unchanged=unchanged,
        length_ok=length_ok,
        version=version_string,
        locale=locale,
    )


def main() -> int:
    try:
        credential = asc_read.Credential.from_environment()
        report = remediate(
            AppleSession(credential),
            confirm=os.environ.get(CONFIRM_ENV, ""),
        )
        print(format_report(report), flush=True)
        return 0
    except core.BoundedError as error:
        print(f"error: {asc_read.redact(error)}", flush=True)
        return 1
    except Exception:
        print("error: unexpected EULA-append failure", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
