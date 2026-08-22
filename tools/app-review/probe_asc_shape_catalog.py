#!/usr/bin/env python3
"""GET-only real-ASC shape catalog for the full 0.1.17 submit path.

Does not POST, PATCH, DELETE, or submit. Prints live JSON:API attribute keys,
relationship names, linkage types, and invalid-field 400s so the engine can
fix every create/reserve/mutate prove in one pass.

Known references:
  leftover COMPLETE submission 8e9fbd18 (version + group + both Cloud subs)
  live 0.1.17 version e81dafd9 / localization 3d89b9a4
  screenshot GET/reserve evidence: run 32593270812

Secrets never printed. Signed blobstore URLs never printed.
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
LEFTOVER_SUBMISSION_ID = "8e9fbd18-6641-4270-b1c5-acbc92be740e"
ENGINE_ITEMS_INCLUDE = "appStoreVersion,subscriptionVersion,subscriptionGroupVersion"
ENGINE_SCREENSHOT_FIELDS = (
    "fileName,fileSize,sourceFileChecksum,imageAsset,assetDeliveryState,uploadOperations"
)
ITEM_RELATED = (
    "appStoreVersion",
    "subscriptionVersion",
    "subscriptionGroupVersion",
    "subscription",
    "inAppPurchaseVersion",
)


class ReadFailure(Exception):
    pass


def _qs(query: Mapping[str, str]) -> str:
    return "&".join(f"{key}={value}" for key, value in query.items())


def _format_http_error(path: str, query: str, status: int, body: bytes) -> str:
    lines = [
        f"  HTTP status: {status}",
        f"  request path: {path}",
        f"  request query: {query}",
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
                lines.append(f"    (non-object): {asc_read.redact(entry)}")
                continue
            for field in ("id", "status", "code", "title", "detail"):
                if field in entry:
                    lines.append(f"    {field}: {asc_read.redact(entry.get(field))}")
            if entry.get("source") is not None:
                lines.append(f"    source: {asc_read.redact(entry.get('source'))}")
    else:
        lines.append(
            "  errors[]: "
            + asc_read.redact(body.decode("utf-8", "replace"))
        )
    return "\n".join(lines)


def _raw_get(
    credential: asc_read.Credential, path: str, query: Mapping[str, str]
) -> Mapping[str, Any]:
    url = asc_read.build_url(path, query)
    request = urllib.request.Request(
        url,
        method="GET",
        headers={
            "Authorization": "Bearer " + credential.bearer_token(),
            "Accept": "application/json",
        },
    )
    opener = urllib.request.build_opener(asc_read.SameOriginRedirectHandler)
    try:
        with opener.open(request, timeout=asc_read.REQUEST_TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read())
            if not isinstance(payload, dict):
                raise ReadFailure(_format_http_error(path, _qs(query), 200, b"{}"))
            return payload
    except urllib.error.HTTPError as error:
        body = b""
        try:
            body = error.read() or b""
        except Exception:
            body = b""
        raise ReadFailure(_format_http_error(path, _qs(query), error.code, body))


def labeled_get(
    credential: asc_read.Credential,
    label: str,
    path: str,
    query: Mapping[str, str] | None = None,
) -> Optional[Mapping[str, Any]]:
    query = query or {}
    print(f"{label}: GET {path}")
    print(f"      query: {_qs(query) or '(none)'}")
    try:
        payload = _raw_get(credential, path, query)
        print("      SUCCESS (HTTP 200)")
        return payload
    except ReadFailure as failure:
        print("      FAILURE:")
        print(str(failure))
        return None


def resources(payload: Optional[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    if not isinstance(payload, dict):
        return []
    data = payload.get("data")
    if isinstance(data, dict) and isinstance(data.get("id"), str):
        return [data]
    if not isinstance(data, list):
        return []
    return [item for item in data if isinstance(item, dict) and isinstance(item.get("id"), str)]


def included(payload: Optional[Mapping[str, Any]], type_name: str) -> list[Mapping[str, Any]]:
    if not isinstance(payload, dict) or not isinstance(payload.get("included"), list):
        return []
    return [
        item
        for item in payload["included"]
        if isinstance(item, dict) and item.get("type") == type_name and isinstance(item.get("id"), str)
    ]


def attrs(entry: Mapping[str, Any]) -> Mapping[str, Any]:
    found = entry.get("attributes")
    return found if isinstance(found, dict) else {}


def rel_names(entry: Mapping[str, Any]) -> list[str]:
    relationships = entry.get("relationships")
    if not isinstance(relationships, dict):
        return []
    return sorted(str(name) for name in relationships)


def rel_data(entry: Mapping[str, Any], name: str) -> Any:
    relationships = entry.get("relationships")
    rel = relationships.get(name) if isinstance(relationships, dict) else None
    return rel.get("data") if isinstance(rel, dict) else None


def print_linkage(entry: Mapping[str, Any], name: str, indent: str) -> None:
    data = rel_data(entry, name)
    if data is None:
        print(f"{indent}{name}: (absent or null)")
        return
    if isinstance(data, dict):
        print(
            f"{indent}{name}: type={asc_read.redact(data.get('type'))} id={asc_read.redact(data.get('id'))}"
        )
        return
    if isinstance(data, list):
        print(f"{indent}{name}.count: {len(data)}")
        for index, item in enumerate(data[:12]):
            if isinstance(item, dict):
                print(
                    f"{indent}  [{index}] type={asc_read.redact(item.get('type'))} id={asc_read.redact(item.get('id'))}"
                )
        return
    print(f"{indent}{name}: {asc_read.redact(data)}")


def delivery_state(attributes: Mapping[str, Any]) -> str:
    state = attributes.get("assetDeliveryState")
    if isinstance(state, str):
        return state
    if isinstance(state, dict) and isinstance(state.get("state"), str):
        return state["state"]
    return "UNKNOWN"


def print_resource_head(entry: Mapping[str, Any], indent: str) -> None:
    print(f"{indent}id: {asc_read.redact(entry.get('id'))}")
    print(f"{indent}type: {asc_read.redact(entry.get('type'))}")
    attributes = attrs(entry)
    print(f"{indent}attributeKeys: {asc_read.redact(','.join(sorted(attributes)))}")
    print(f"{indent}relationshipNames: {asc_read.redact(','.join(rel_names(entry)))}")


def probe_submissions(credential: asc_read.Credential) -> list[str]:
    print()
    print("=" * 72)
    print("REVIEW SUBMISSIONS (create/reuse/submit prove)")
    print("=" * 72)
    collection = labeled_get(
        credential,
        "[submissions default]",
        f"/v1/apps/{core.APP_ID}/reviewSubmissions",
        {"filter[platform]": core.PLATFORM, "limit": "200"},
    )
    labeled_get(
        credential,
        "[submissions fields=submitted INVALID?]",
        f"/v1/apps/{core.APP_ID}/reviewSubmissions",
        {
            "filter[platform]": core.PLATFORM,
            "fields[reviewSubmissions]": "platform,state,submitted,submittedDate",
            "limit": "200",
        },
    )
    labeled_get(
        credential,
        "[submissions fields=state,submittedDate]",
        f"/v1/apps/{core.APP_ID}/reviewSubmissions",
        {
            "filter[platform]": core.PLATFORM,
            "fields[reviewSubmissions]": "platform,state,submittedDate,createdDate",
            "limit": "200",
        },
    )
    ids: list[str] = []
    for entry in resources(collection):
        attributes = attrs(entry)
        print()
        print("  submission:")
        print_resource_head(entry, "    ")
        for name in (
            "state",
            "platform",
            "submitted",
            "submittedDate",
            "createdDate",
            "itemsLastModifiedDate",
        ):
            if name in attributes:
                print(f"    {name}: {asc_read.redact(attributes.get(name))}")
            else:
                print(f"    {name}: (absent)")
        ids.append(entry["id"])
    if LEFTOVER_SUBMISSION_ID not in ids:
        print(f"  leftover {LEFTOVER_SUBMISSION_ID} not in collection page; still probing by id")
        ids.append(LEFTOVER_SUBMISSION_ID)
    return ids


def probe_one_submission(credential: asc_read.Credential, submission_id: str) -> None:
    print()
    print("=" * 72)
    print(f"SUBMISSION {submission_id}")
    print("=" * 72)
    self_payload = labeled_get(
        credential, "[self default]", f"/v1/reviewSubmissions/{submission_id}", {}
    )
    if self_payload is not None:
        for entry in resources(self_payload):
            print_resource_head(entry, "    ")
            attributes = attrs(entry)
            for name in ("state", "platform", "submitted", "submittedDate", "createdDate"):
                print(f"    {name}: {asc_read.redact(attributes.get(name)) if name in attributes else '(absent)'}")
            print_linkage(entry, "items", "    ")
            print_linkage(entry, "app", "    ")
    labeled_get(
        credential,
        "[self fields=submitted INVALID?]",
        f"/v1/reviewSubmissions/{submission_id}",
        {"fields[reviewSubmissions]": "state,submitted,submittedDate"},
    )
    labeled_get(
        credential,
        "[self include=items]",
        f"/v1/reviewSubmissions/{submission_id}",
        {"include": "items"},
    )
    labeled_get(
        credential,
        "[relationships/items]",
        f"/v1/reviewSubmissions/{submission_id}/relationships/items",
        {"limit": "200"},
    )

    queries = (
        ("items-engine-include", {"include": ENGINE_ITEMS_INCLUDE, "limit": "200"}),
        ("items-include-subscription INVALID?", {"include": "subscription", "limit": "200"}),
        ("items-no-include", {"limit": "200"}),
    )
    engine_items = None
    for label, query in queries:
        payload = labeled_get(
            credential,
            f"[{label}]",
            f"/v1/reviewSubmissions/{submission_id}/items",
            query,
        )
        if label == "items-engine-include":
            engine_items = payload

    items = resources(engine_items)
    included_types = {}
    if isinstance(engine_items, dict) and isinstance(engine_items.get("included"), list):
        for item in engine_items["included"]:
            if isinstance(item, dict):
                included_types.setdefault(item.get("type"), 0)
                included_types[item.get("type")] += 1
    print(f"  items.count: {len(items)}")
    print(f"  included.types: {asc_read.redact(included_types)}")
    for index, item in enumerate(items, start=1):
        print()
        print(f"  item {index}/{len(items)}:")
        print_resource_head(item, "    ")
        print(f"    state: {asc_read.redact(attrs(item).get('state'))}")
        for name in ITEM_RELATED:
            print_linkage(item, name, "    ")
        labeled_get(
            credential,
            f"    [item instance default]",
            f"/v1/reviewSubmissionItems/{item['id']}",
            {},
        )
        for related in ITEM_RELATED:
            labeled_get(
                credential,
                f"    [item related {related}]",
                f"/v1/reviewSubmissionItems/{item['id']}/{related}",
                {},
            )
        for name, type_name, collection in (
            ("subscriptionVersion", "subscriptionVersions", "/v1/subscriptionVersions"),
            ("subscriptionGroupVersion", "subscriptionGroupVersions", "/v1/subscriptionGroupVersions"),
            ("appStoreVersion", "appStoreVersions", "/v1/appStoreVersions"),
            ("subscription", "subscriptions", "/v1/subscriptions"),
        ):
            data = rel_data(item, name)
            resource_id = data.get("id") if isinstance(data, dict) else None
            if not isinstance(resource_id, str):
                continue
            labeled_get(
                credential,
                f"    [typed GET {type_name}]",
                f"{collection}/{resource_id}",
                {},
            )
            if name == "subscriptionVersion":
                labeled_get(
                    credential,
                    f"    [WRONG typed GET subscriptions with version id]",
                    f"/v1/subscriptions/{resource_id}",
                    {},
                )


def probe_screenshots(credential: asc_read.Credential, localization_id: str) -> None:
    print()
    print("=" * 72)
    print("SCREENSHOT SETS / COMMIT RESULT / ORDER (GET of live COMPLETE)")
    print("=" * 72)
    sets = labeled_get(
        credential,
        "[sets default]",
        f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
        {"limit": "200"},
    )
    for entry in resources(sets):
        display = attrs(entry).get("screenshotDisplayType")
        set_id = entry["id"]
        print()
        print(f"  set {asc_read.redact(display)} id={asc_read.redact(set_id)}")
        print_resource_head(entry, "    ")
        labeled_get(
            credential,
            f"    [set self]",
            f"/v1/appScreenshotSets/{set_id}",
            {},
        )
        collection = labeled_get(
            credential,
            f"    [collection engine fields]",
            f"/v1/appScreenshotSets/{set_id}/appScreenshots",
            {"fields[appScreenshots]": ENGINE_SCREENSHOT_FIELDS, "limit": "200"},
        )
        related = labeled_get(
            credential,
            f"    [relationships/appScreenshots ORDER]",
            f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
            {"limit": "200"},
        )
        shots = resources(collection)
        rel_ids = [item["id"] for item in resources(related)]
        states = {}
        for shot in shots:
            state = delivery_state(attrs(shot))
            states[state] = states.get(state, 0) + 1
        print(f"    collection.count: {len(shots)}")
        print(f"    relationship.order: {asc_read.redact(rel_ids)}")
        print(f"    deliveryState.counts: {asc_read.redact(states)}")
        if not shots:
            continue
        exemplar = shots[0]
        print("    COMMIT-RESULT exemplar (first COMPLETE or first resource):")
        print_resource_head(exemplar, "      ")
        attributes = attrs(exemplar)
        print(f"      fileName: {asc_read.redact(attributes.get('fileName'))}")
        print(f"      fileSize: {asc_read.redact(attributes.get('fileSize'))}")
        print(
            f"      sourceFileChecksum: {asc_read.redact(attributes.get('sourceFileChecksum'))}"
        )
        print(f"      uploaded: {asc_read.redact(attributes.get('uploaded')) if 'uploaded' in attributes else '(absent)'}")
        print(f"      assetDeliveryState.state: {asc_read.redact(delivery_state(attributes))}")
        operations = attributes.get("uploadOperations")
        print(
            "      uploadOperations: "
            + (
                f"count={len(operations)}"
                if isinstance(operations, list)
                else "(absent/null)"
            )
        )
        image = attributes.get("imageAsset")
        if isinstance(image, dict):
            print(
                f"      imageAsset: {asc_read.redact(image.get('width'))}x{asc_read.redact(image.get('height'))}"
            )
        labeled_get(
            credential,
            "    [instance engine fields]",
            f"/v1/appScreenshots/{exemplar['id']}",
            {"fields[appScreenshots]": ENGINE_SCREENSHOT_FIELDS},
        )
        labeled_get(
            credential,
            "    [related appScreenshotSet 403?]",
            f"/v1/appScreenshots/{exemplar['id']}/appScreenshotSet",
            {},
        )


def probe_other_live(credential: asc_read.Credential, version_id: str) -> None:
    print()
    print("=" * 72)
    print("OTHER LIVE RESOURCES ON THE 0.1.17 PATH (GET only)")
    print("=" * 72)
    labeled_get(credential, "[version default]", f"/v1/appStoreVersions/{version_id}", {})
    labeled_get(
        credential,
        "[version/build relationship]",
        f"/v1/appStoreVersions/{version_id}/relationships/build",
        {},
    )
    labeled_get(
        credential,
        "[version/appStoreReviewDetail]",
        f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail",
        {},
    )


def main() -> int:
    print("App Review ASC shape catalog (GET-only, no mutation, no submit)")
    print(f"app: {core.APP_ID} version: {VERSION}")
    print()
    try:
        credential = asc_read.Credential.from_environment()
    except asc_read.AppStoreConnectError as error:
        print(f"FATAL: {asc_read.redact(error)}")
        return 2

    versions = labeled_get(
        credential,
        "[version collection]",
        f"/v1/apps/{core.APP_ID}/appStoreVersions",
        {
            "filter[versionString]": VERSION,
            "filter[platform]": core.PLATFORM,
            "limit": "200",
        },
    )
    matching = [
        entry
        for entry in resources(versions)
        if attrs(entry).get("versionString") == VERSION
        and attrs(entry).get("platform") == core.PLATFORM
    ]
    if len(matching) != 1:
        print(f"FATAL: version match count {len(matching)}")
        return 1
    version_id = matching[0]["id"]
    print(f"  version id: {asc_read.redact(version_id)}")
    print(f"  appVersionState: {asc_read.redact(attrs(matching[0]).get('appVersionState'))}")
    localizations = labeled_get(
        credential,
        "[en-US localization]",
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations",
        {"filter[locale]": "en-US", "limit": "50"},
    )
    english = [entry for entry in resources(localizations) if attrs(entry).get("locale") == "en-US"]
    if len(english) != 1:
        print("FATAL: en-US localization missing")
        return 1
    localization_id = english[0]["id"]
    print(f"  localization id: {asc_read.redact(localization_id)}")

    submission_ids = probe_submissions(credential)
    seen = set()
    for submission_id in submission_ids:
        if submission_id in seen:
            continue
        seen.add(submission_id)
        probe_one_submission(credential, submission_id)
    probe_screenshots(credential, localization_id)
    probe_other_live(credential, version_id)
    print()
    print("catalog probe complete (GET-only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
