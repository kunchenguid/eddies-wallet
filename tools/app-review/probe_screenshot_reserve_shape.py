#!/usr/bin/env python3
"""GET-only probe of live App Store listing screenshot reservations.

Upload run 32592967034 fail-closed with E_AMBIGUOUS_CREATE after POST
/v1/appScreenshots: 'screenshot reservation was not proven'. This script does
not POST. It GETs the 0.1.17 en-US APP_IPHONE_67 and APP_IPAD_PRO_3GEN_129
screenshot sets, lists every appScreenshot, and reissues the engine's prove
reads (collection + relationship linkage, with and without uploadOperations)
so we can see whether a dangling incomplete reservation exists and which GET
shape Apple actually serves.

Hard safety, non-negotiable, this handles a live credential:
  * It is GET-only. It imports neither a mutation boundary nor a submission
    engine. It never POSTs, PATCHes, DELETEs, or submits.
  * It never prints, echoes, logs, or writes the API key, private key PEM,
    issuer id, key id, signed JWT/bearer token, the Authorization header, any
    request header, or any environment variable value.
  * uploadOperations URLs and requestHeaders are omitted: they carry
    time-limited blobstore signatures. Only method/offset/length/count.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Any, Mapping, Optional, Sequence
import urllib.error
import urllib.parse
import urllib.request

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import core  # noqa: E402

VERSION = "0.1.17"
TARGET_DISPLAY_TYPES = ("APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129")
APPROVED_FILES = {
    "APP_IPHONE_67": (
        "iphone-6.9-kid-home.png",
        "iphone-6.9-parent-area.png",
        "iphone-6.9-parent-loan-payments.png",
        "iphone-6.9-money-flow-review.png",
        "iphone-6.9-cloud-plans.png",
    ),
    "APP_IPAD_PRO_3GEN_129": (
        "ipad-13-kid-home.png",
        "ipad-13-parent-area.png",
        "ipad-13-parent-loan-payments.png",
        "ipad-13-money-flow-review.png",
        "ipad-13-cloud-plans.png",
    ),
}
ENGINE_SCREENSHOT_FIELDS = (
    "fileName,fileSize,sourceFileChecksum,imageAsset,assetDeliveryState,uploadOperations"
)
CONTENT_SCREENSHOT_FIELDS = "fileName,fileSize,sourceFileChecksum,assetDeliveryState"
COMPLETE_STATES = frozenset(("COMPLETE",))
INCOMPLETE_HINTS = frozenset(
    ("AWAITING_UPLOAD", "UPLOAD_COMPLETE", "FAILED", "UNKNOWN")
)


class ReadFailure(Exception):
    """A GET returned an HTTP error, with Apple's body captured."""


def _query_string(query: Mapping[str, str]) -> str:
    return "&".join(f"{key}={value}" for key, value in query.items())


def _format_http_error(
    path: str, query_string: str, status: int, body: bytes
) -> str:
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
                    lines.append(f"    {field}: {asc_read.redact(entry.get(field))}")
            source = entry.get("source")
            if source is not None:
                lines.append(f"    source: {asc_read.redact(source)}")
    else:
        lines.append(
            "  errors[]: absent or unparseable; raw (redacted): "
            + asc_read.redact(body.decode("utf-8", "replace"))
        )
    return "\n".join(lines)


def _raw_get(
    credential: asc_read.Credential, path: str, query: Mapping[str, str]
) -> Mapping[str, Any]:
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
        with opener.open(request, timeout=asc_read.REQUEST_TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read())
            if not isinstance(payload, dict):
                raise ReadFailure(
                    _format_http_error(path, _query_string(query), 200, b"{}")
                )
            return payload
    except urllib.error.HTTPError as error:
        body_bytes = b""
        try:
            body_bytes = error.read() or b""
        except Exception:
            body_bytes = b""
        raise ReadFailure(
            _format_http_error(path, _query_string(query), error.code, body_bytes)
        )


def _labeled_get(
    credential: asc_read.Credential,
    label: str,
    path: str,
    query: Mapping[str, str],
) -> Optional[Mapping[str, Any]]:
    print(f"{label}: GET {path}")
    print(f"      query: {_query_string(query) or '(none)'}")
    try:
        payload = _raw_get(credential, path, query)
        print("      SUCCESS (HTTP 200)")
        return payload
    except ReadFailure as failure:
        print("      FAILURE:")
        print(str(failure))
        return None


def _resource_list(payload: Optional[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    if not isinstance(payload, dict):
        return []
    data = payload.get("data")
    if isinstance(data, dict) and isinstance(data.get("id"), str):
        return [data]
    if not isinstance(data, list):
        return []
    return [
        entry
        for entry in data
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    ]


def _included(payload: Optional[Mapping[str, Any]], type_name: str) -> list[Mapping[str, Any]]:
    if not isinstance(payload, dict):
        return []
    included = payload.get("included")
    if not isinstance(included, list):
        return []
    return [
        entry
        for entry in included
        if isinstance(entry, dict)
        and entry.get("type") == type_name
        and isinstance(entry.get("id"), str)
    ]


def _attributes(entry: Mapping[str, Any]) -> Mapping[str, Any]:
    found = entry.get("attributes")
    return found if isinstance(found, dict) else {}


def _relationship_ids(entry: Mapping[str, Any], name: str) -> list[str]:
    relationships = entry.get("relationships")
    rel = relationships.get(name) if isinstance(relationships, dict) else None
    data = rel.get("data") if isinstance(rel, dict) else None
    if isinstance(data, dict) and isinstance(data.get("id"), str):
        return [data["id"]]
    if not isinstance(data, list):
        return []
    return [
        item["id"]
        for item in data
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    ]


def _delivery_state(attributes: Mapping[str, Any]) -> str:
    state = attributes.get("assetDeliveryState")
    if isinstance(state, str):
        return state
    if isinstance(state, dict) and isinstance(state.get("state"), str):
        return state["state"]
    return "UNKNOWN"


def _print_delivery(attributes: Mapping[str, Any], indent: str) -> None:
    state = attributes.get("assetDeliveryState")
    if state is None:
        print(f"{indent}assetDeliveryState: (absent)")
        return
    if isinstance(state, str):
        print(f"{indent}assetDeliveryState: {asc_read.redact(state)}")
        return
    if not isinstance(state, dict):
        print(f"{indent}assetDeliveryState: (non-object)")
        return
    print(f"{indent}assetDeliveryState.state: {asc_read.redact(state.get('state'))}")
    for kind in ("errors", "warnings"):
        items = state.get(kind)
        if not isinstance(items, list):
            print(f"{indent}assetDeliveryState.{kind}: (absent)")
            continue
        print(f"{indent}assetDeliveryState.{kind}.count: {len(items)}")
        for index, item in enumerate(items[:4]):
            if not isinstance(item, dict):
                print(f"{indent}  {kind}[{index}]: {asc_read.redact(item)}")
                continue
            print(
                f"{indent}  {kind}[{index}].code: {asc_read.redact(item.get('code'))}"
            )
            print(
                f"{indent}  {kind}[{index}].description: {asc_read.redact(item.get('description'))}"
            )


def _print_upload_operations(attributes: Mapping[str, Any], indent: str) -> None:
    operations = attributes.get("uploadOperations")
    if operations is None:
        print(f"{indent}uploadOperations: (absent)")
        return
    if not isinstance(operations, list):
        print(f"{indent}uploadOperations: (non-array)")
        return
    print(f"{indent}uploadOperations.count: {len(operations)}")
    for index, item in enumerate(operations[:8]):
        if not isinstance(item, dict):
            print(f"{indent}  op[{index}]: (non-object)")
            continue
        print(
            f"{indent}  op[{index}].method: {asc_read.redact(item.get('method'))}"
        )
        print(
            f"{indent}  op[{index}].offset: {asc_read.redact(item.get('offset'))}"
        )
        print(
            f"{indent}  op[{index}].length: {asc_read.redact(item.get('length'))}"
        )
        print(
            f"{indent}  op[{index}].url: (omitted; signed blobstore URL)"
        )
        headers = item.get("requestHeaders")
        header_count = len(headers) if isinstance(headers, list) else 0
        print(f"{indent}  op[{index}].requestHeaders.count: {header_count}")


def _print_screenshot(entry: Mapping[str, Any], indent: str) -> None:
    attributes = _attributes(entry)
    print(f"{indent}id: {asc_read.redact(entry.get('id'))}")
    print(f"{indent}type: {asc_read.redact(entry.get('type'))}")
    print(f"{indent}attributeKeys: {asc_read.redact(','.join(sorted(attributes)))}")
    print(f"{indent}fileName: {asc_read.redact(attributes.get('fileName'))}")
    print(f"{indent}fileSize: {asc_read.redact(attributes.get('fileSize'))}")
    print(
        f"{indent}sourceFileChecksum: {asc_read.redact(attributes.get('sourceFileChecksum'))}"
    )
    if "uploaded" in attributes:
        print(f"{indent}uploaded: {asc_read.redact(attributes.get('uploaded'))}")
    else:
        print(f"{indent}uploaded: (absent)")
    image = attributes.get("imageAsset")
    if isinstance(image, dict):
        print(
            f"{indent}imageAsset.width: {asc_read.redact(image.get('width'))}"
        )
        print(
            f"{indent}imageAsset.height: {asc_read.redact(image.get('height'))}"
        )
    else:
        print(f"{indent}imageAsset: {asc_read.redact(image)}")
    _print_delivery(attributes, indent)
    _print_upload_operations(attributes, indent)
    print(
        f"{indent}appScreenshotSet linkage: {asc_read.redact(_relationship_ids(entry, 'appScreenshotSet'))}"
    )


def _classify(entry: Mapping[str, Any], approved: Sequence[str]) -> dict[str, Any]:
    attributes = _attributes(entry)
    name = attributes.get("fileName")
    state = _delivery_state(attributes)
    operations = attributes.get("uploadOperations")
    op_count = len(operations) if isinstance(operations, list) else 0
    return {
        "id": entry.get("id"),
        "fileName": name if isinstance(name, str) else "",
        "fileSize": attributes.get("fileSize"),
        "state": state,
        "complete": state in COMPLETE_STATES,
        "incomplete": state not in COMPLETE_STATES,
        "approved_name": isinstance(name, str) and name in approved,
        "has_upload_ops": op_count > 0,
        "upload_op_count": op_count,
        "uploaded_attr": attributes.get("uploaded") if "uploaded" in attributes else None,
    }


def _resolve_version_and_localization(
    credential: asc_read.Credential,
) -> tuple[Optional[str], Optional[str]]:
    versions = _labeled_get(
        credential,
        "[1] version",
        f"/v1/apps/{core.APP_ID}/appStoreVersions",
        {
            "filter[versionString]": VERSION,
            "filter[platform]": core.PLATFORM,
            "limit": "200",
        },
    )
    matching = []
    for entry in _resource_list(versions):
        attributes = _attributes(entry)
        if (
            attributes.get("versionString") == VERSION
            and attributes.get("platform") == core.PLATFORM
        ):
            matching.append(entry)
    if len(matching) != 1:
        print(f"      version match count: {len(matching)}")
        return None, None
    version_id = matching[0]["id"]
    print(f"      version id: {asc_read.redact(version_id)}")
    print(
        f"      appVersionState: {asc_read.redact(_attributes(matching[0]).get('appVersionState'))}"
    )
    localizations = _labeled_get(
        credential,
        "[2] en-US localization",
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        {"filter[locale]": "en-US", "limit": "50"},
    )
    english = [
        entry
        for entry in _resource_list(localizations)
        if _attributes(entry).get("locale") == "en-US"
    ]
    if len(english) != 1:
        print(f"      en-US localization count: {len(english)}")
        return version_id, None
    localization_id = english[0]["id"]
    print(f"      localization id: {asc_read.redact(localization_id)}")
    return version_id, localization_id


def _probe_set_queries(
    credential: asc_read.Credential, localization_id: str
) -> dict[str, Optional[Mapping[str, Any]]]:
    path = f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets"
    queries: tuple[tuple[str, Mapping[str, str]], ...] = (
        ("sets-default", {"limit": "200"}),
        ("sets-include-appScreenshots", {"include": "appScreenshots", "limit": "200"}),
        (
            "sets-content-fields",
            {
                "fields[appScreenshotSets]": "screenshotDisplayType,appScreenshots",
                "fields[appScreenshots]": CONTENT_SCREENSHOT_FIELDS,
                "include": "appScreenshots",
                "limit": "50",
            },
        ),
        (
            "sets-engine-fields-on-include",
            {
                "include": "appScreenshots",
                "fields[appScreenshots]": ENGINE_SCREENSHOT_FIELDS,
                "limit": "200",
            },
        ),
        (
            "sets-fields-uploaded",
            {
                "include": "appScreenshots",
                "fields[appScreenshots]": "fileName,fileSize,uploaded,assetDeliveryState,uploadOperations",
                "limit": "200",
            },
        ),
    )
    results: dict[str, Optional[Mapping[str, Any]]] = {}
    for label, query in queries:
        print()
        results[label] = _labeled_get(credential, f"[sets {label}]", path, query)
    return results


def _probe_one_set(
    credential: asc_read.Credential,
    display_type: str,
    set_id: str,
    approved: Sequence[str],
) -> list[dict[str, Any]]:
    print()
    print("=" * 72)
    print(f"SET {display_type} id={asc_read.redact(set_id)}")
    print("=" * 72)
    collection_path = f"/v1/appScreenshotSets/{set_id}/appScreenshots"
    related_path = f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots"
    self_path = f"/v1/appScreenshotSets/{set_id}"

    collection_queries: tuple[tuple[str, Mapping[str, str]], ...] = (
        ("collection-default", {}),
        (
            "collection-engine-fields",
            {"fields[appScreenshots]": ENGINE_SCREENSHOT_FIELDS, "limit": "200"},
        ),
        (
            "collection-content-fields",
            {"fields[appScreenshots]": CONTENT_SCREENSHOT_FIELDS, "limit": "200"},
        ),
        (
            "collection-uploaded-field",
            {
                "fields[appScreenshots]": "fileName,fileSize,uploaded,assetDeliveryState",
                "limit": "200",
            },
        ),
    )
    collection_payloads: dict[str, Optional[Mapping[str, Any]]] = {}
    for label, query in collection_queries:
        print()
        collection_payloads[label] = _labeled_get(
            credential, f"[{display_type} {label}]", collection_path, query
        )

    print()
    related = _labeled_get(
        credential,
        f"[{display_type} relationships]",
        related_path,
        {"limit": "200"},
    )
    print()
    _labeled_get(
        credential,
        f"[{display_type} set-self include]",
        self_path,
        {"include": "appScreenshots"},
    )

    engine_payload = collection_payloads.get("collection-engine-fields")
    default_payload = collection_payloads.get("collection-default")
    screenshots = _resource_list(engine_payload) or _resource_list(default_payload)
    related_ids = [entry["id"] for entry in _resource_list(related)]
    collection_ids = [entry["id"] for entry in screenshots]
    print()
    print(f"  collection count: {len(collection_ids)}")
    print(f"  relationship count: {len(related_ids)}")
    print(
        f"  ids in collection not relationship: {asc_read.redact(sorted(set(collection_ids) - set(related_ids)))}"
    )
    print(
        f"  ids in relationship not collection: {asc_read.redact(sorted(set(related_ids) - set(collection_ids)))}"
    )
    print(f"  approved fileNames ({len(approved)}): {asc_read.redact(','.join(approved))}")

    reports: list[dict[str, Any]] = []
    for index, entry in enumerate(screenshots, start=1):
        print()
        print(f"  screenshot {index}/{len(screenshots)} from collection:")
        _print_screenshot(entry, "    ")
        instance = _labeled_get(
            credential,
            f"    [{display_type} instance {index} engine-fields]",
            f"/v1/appScreenshots/{entry['id']}",
            {"fields[appScreenshots]": ENGINE_SCREENSHOT_FIELDS},
        )
        if instance is not None and _resource_list(instance):
            print("    instance GET (engine fields):")
            _print_screenshot(_resource_list(instance)[0], "      ")
            reports.append(_classify(_resource_list(instance)[0], approved))
        else:
            reports.append(_classify(entry, approved))
        print()
        _labeled_get(
            credential,
            f"    [{display_type} instance {index} default]",
            f"/v1/appScreenshots/{entry['id']}",
            {},
        )
        print()
        _labeled_get(
            credential,
            f"    [{display_type} related appScreenshotSet]",
            f"/v1/appScreenshots/{entry['id']}/appScreenshotSet",
            {},
        )

    extras = [item for item in reports if not item["approved_name"]]
    incomplete = [item for item in reports if item["incomplete"]]
    print()
    print(f"  {display_type} summary:")
    print(f"    live count: {len(reports)} (expected 5)")
    print(f"    extra vs approved names: {len(extras)}")
    print(f"    incomplete (not COMPLETE): {len(incomplete)}")
    for item in reports:
        flag = []
        if item["incomplete"]:
            flag.append("INCOMPLETE")
        if not item["approved_name"]:
            flag.append("UNEXPECTED_NAME")
        if item["has_upload_ops"]:
            flag.append("HAS_UPLOAD_OPS")
        if len(reports) > 5:
            flag.append("OVER_EXPECTED_COUNT")
        print(
            "    - "
            + asc_read.redact(item["fileName"])
            + f" id={asc_read.redact(item['id'])}"
            + f" state={asc_read.redact(item['state'])}"
            + f" size={asc_read.redact(item['fileSize'])}"
            + (" [" + ",".join(flag) + "]" if flag else " [COMPLETE expected-name]")
        )
    return reports


def main() -> int:
    print("App Review screenshot-reserve shape probe (GET-only, no mutation)")
    print(f"app: {core.APP_ID}  version: {VERSION}")
    print("failed upload run: 32592967034")
    print()
    try:
        credential = asc_read.Credential.from_environment()
    except asc_read.AppStoreConnectError as error:
        print(f"FATAL: could not build credential: {asc_read.redact(error)}")
        return 2

    _version_id, localization_id = _resolve_version_and_localization(credential)
    if localization_id is None:
        print("FATAL: could not resolve 0.1.17 en-US localization")
        return 1

    print()
    set_payloads = _probe_set_queries(credential, localization_id)
    sets = _resource_list(set_payloads.get("sets-default")) or _resource_list(
        set_payloads.get("sets-include-appScreenshots")
    )
    by_type: dict[str, Mapping[str, Any]] = {}
    print()
    print("sets found:")
    for entry in sets:
        display = _attributes(entry).get("screenshotDisplayType")
        print(
            f"  {asc_read.redact(display)} id={asc_read.redact(entry.get('id'))}"
        )
        if isinstance(display, str):
            by_type[display] = entry

    all_reports: dict[str, list[dict[str, Any]]] = {}
    for display in TARGET_DISPLAY_TYPES:
        entry = by_type.get(display)
        if entry is None:
            print()
            print(f"MISSING SET: {display}")
            continue
        all_reports[display] = _probe_one_set(
            credential, display, entry["id"], APPROVED_FILES[display]
        )

    print()
    print("=" * 72)
    print("DANGLING / INCOMPLETE RESERVATION SUMMARY")
    print("=" * 72)
    dangling = []
    for display, reports in all_reports.items():
        extras = [item for item in reports if not item["approved_name"] or item["incomplete"]]
        if len(reports) > 5:
            print(f"  {display}: live count {len(reports)} exceeds expected 5")
        if not extras and len(reports) <= 5:
            print(f"  {display}: no dangling/incomplete reservation; {len(reports)} COMPLETE expected-name files")
            continue
        for item in extras:
            dangling.append((display, item))
            print(
                f"  DANGLING {display}: id={asc_read.redact(item['id'])}"
                f" fileName={asc_read.redact(item['fileName'])}"
                f" state={asc_read.redact(item['state'])}"
                f" uploadOps={item['upload_op_count']}"
                f" uploaded={asc_read.redact(item['uploaded_attr'])}"
            )
    if not dangling:
        print("  overall: NO dangling/incomplete appScreenshot reservation is visible")
        print(
            "  cleanup: none required for an incomplete reserve; live sets are the "
            "pre-upload COMPLETE listing (still the old bytes until a proven upload)"
        )
    else:
        print(f"  overall: {len(dangling)} dangling/incomplete reservation(s) need captain/engine cleanup before re-run")
    print()
    print("engine prove notes (no POST issued):")
    print("  POST /v1/appScreenshots expected 201; reservation is proven when GET")
    print("  /v1/appScreenshotSets/{id}/appScreenshots contains that id AND")
    print("  /relationships/appScreenshots also lists it. Fallback prove (POST failed)")
    print("  requires exactly one non-COMPLETE screenshot with matching fileName+fileSize")
    print("  that is also in the relationship linkage.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
