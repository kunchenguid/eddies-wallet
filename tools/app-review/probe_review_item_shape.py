#!/usr/bin/env python3
"""GET-only probe of how live App Store Connect represents subscription review items.

The shared engine's #14 pin proves subscription attachment by GETting
`/v1/reviewSubmissions/{id}/items?include=subscription`. Real ASC rejected that
include (HTTP 400); the mock accepted it. This script reissues a matrix of GET
query shapes against two known Eddie submissions and prints the JSON:API
relationship names, linkage types, and included resource types so the engine
can prove attachment with a query Apple actually serves.

Hard safety, non-negotiable, this handles a live credential:
  * It is GET-only. It imports neither a mutation boundary nor a submission
    engine. It submits nothing, attaches nothing, and deletes nothing.
  * It never prints, echoes, logs, or writes the API key, private key PEM,
    issuer id, key id, signed JWT/bearer token, the Authorization header, any
    request header, or any environment variable value. Apple attribute values
    pass through `asc_read.redact()`.
"""

from __future__ import annotations

import base64
import json
import re
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

# Leftover COMPLETE submission that already carries both Cloud subs (types
# 19+18+18) plus the 0.1.17 version. This is the live reference document.
LEFTOVER_SUBMISSION_ID = "8e9fbd18-6641-4270-b1c5-acbc92be740e"
# Active READY_FOR_REVIEW submission: version item only, zero Cloud sub items.
ACTIVE_SUBMISSION_ID = "be692e62-840d-40ad-b726-ddd82c409be2"

SUBMISSIONS = (
    ("leftover-complete", LEFTOVER_SUBMISSION_ID),
    ("active-ready-for-review", ACTIVE_SUBMISSION_ID),
)

# Query matrix: the engine's #14 include, Apple's documented includes, and the
# historical invalid sparse field. Each is GET-only.
ITEMS_QUERIES: tuple[tuple[str, Mapping[str, str]], ...] = (
    ("no-include", {"limit": "200"}),
    ("include-appStoreVersion", {"include": "appStoreVersion", "limit": "200"}),
    ("include-subscription", {"include": "subscription", "limit": "200"}),
    ("include-subscriptions", {"include": "subscriptions", "limit": "200"}),
    ("include-subscriptionVersion", {"include": "subscriptionVersion", "limit": "200"}),
    (
        "include-subscriptionGroupVersion",
        {"include": "subscriptionGroupVersion", "limit": "200"},
    ),
    (
        "include-sub-versions-both",
        {"include": "subscriptionVersion,subscriptionGroupVersion", "limit": "200"},
    ),
    (
        "include-version-and-sub-versions",
        {
            "include": "appStoreVersion,subscriptionVersion,subscriptionGroupVersion",
            "limit": "200",
        },
    ),
    (
        "include-inAppPurchaseVersion",
        {"include": "inAppPurchaseVersion", "limit": "200"},
    ),
    (
        "fields-subscription",
        {"fields[reviewSubmissionItems]": "state,subscription", "limit": "200"},
    ),
    (
        "fields-subscriptionVersion",
        {"fields[reviewSubmissionItems]": "state,subscriptionVersion", "limit": "200"},
    ),
)

SUBMISSION_QUERIES: tuple[tuple[str, Mapping[str, str]], ...] = (
    ("self", {}),
    ("include-items", {"include": "items"}),
    ("include-items-subscriptionVersion", {"include": "items.subscriptionVersion"}),
)

RELATED_RELATIONSHIPS = (
    "subscription",
    "subscriptions",
    "subscriptionVersion",
    "subscriptionGroupVersion",
    "appStoreVersion",
    "inAppPurchaseVersion",
)

TYPED_RESOURCE_PATHS = (
    "/v1/subscriptions",
    "/v1/subscriptionVersions",
    "/v1/subscriptionGroups",
    "/v1/subscriptionGroupVersions",
    "/v1/inAppPurchaseVersions",
    "/v1/appStoreVersions",
)

INCLUDED_ATTRIBUTE_ALLOWLIST = (
    "productId",
    "name",
    "state",
    "version",
    "versionString",
    "platform",
    "familySharable",
)

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
CAMEL_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]{0,80}$")


class ReadFailure(Exception):
    """A GET returned an HTTP error, with Apple's body captured."""


def safe_name(value: object) -> str:
    """Print a JSON:API type or relationship name as-is when it is a token."""
    text = str(value)
    if CAMEL_NAME_RE.fullmatch(text):
        return text
    return asc_read.redact(text)


def decode_item_id(item_id: str) -> Mapping[str, Optional[str]]:
    """Apple encodes reviewSubmissionItems ids as base64(submission|typeCode|resource)."""
    padded = item_id + "=" * ((-len(item_id)) % 4)
    try:
        raw = base64.b64decode(padded, validate=False).decode("ascii")
    except Exception:
        return {
            "submission": None,
            "typeCode": None,
            "resource": None,
            "decoded": None,
        }
    parts = raw.split("|")
    if len(parts) != 3:
        return {
            "submission": None,
            "typeCode": None,
            "resource": None,
            "decoded": raw,
        }
    return {
        "submission": parts[0],
        "typeCode": parts[1],
        "resource": parts[2],
        "decoded": raw,
    }


def describe_relationship(body: object) -> Mapping[str, Any]:
    """Normalize one JSON:API relationship object into a printable summary."""
    if not isinstance(body, dict):
        return {"kind": "non-object"}
    data = body.get("data")
    links = body.get("links") if isinstance(body.get("links"), dict) else {}
    related = links.get("related") if isinstance(links, dict) else None
    related_path = ""
    if isinstance(related, str):
        related_path = urllib.parse.urlsplit(related).path
    if data is None:
        return {"kind": "null", "related": related_path}
    if isinstance(data, dict):
        return {
            "kind": "to-one",
            "type": data.get("type"),
            "id": data.get("id"),
            "related": related_path,
        }
    if isinstance(data, list):
        entries = []
        for entry in data:
            if isinstance(entry, dict):
                entries.append({"type": entry.get("type"), "id": entry.get("id")})
        return {"kind": "to-many", "entries": entries, "related": related_path}
    return {"kind": "unknown", "related": related_path}


def summarize_item(item: Mapping[str, Any]) -> dict[str, Any]:
    """Extract the prove-relevant shape of one reviewSubmissionItems resource."""
    item_id = item.get("id") if isinstance(item.get("id"), str) else ""
    decoded = decode_item_id(item_id) if item_id else decode_item_id("")
    attributes = item.get("attributes") if isinstance(item.get("attributes"), dict) else {}
    relationships = (
        item.get("relationships") if isinstance(item.get("relationships"), dict) else {}
    )
    linkage = []
    for name, body in relationships.items():
        linkage.append({"name": name, **describe_relationship(body)})
    return {
        "type": item.get("type"),
        "id": item_id,
        "decoded": decoded,
        "attributeKeys": sorted(str(key) for key in attributes),
        "state": attributes.get("state"),
        "relationshipKeys": sorted(str(key) for key in relationships),
        "linkage": linkage,
    }


def summarize_included(entry: Mapping[str, Any]) -> dict[str, Any]:
    attributes = entry.get("attributes") if isinstance(entry.get("attributes"), dict) else {}
    kept = {
        name: attributes[name]
        for name in INCLUDED_ATTRIBUTE_ALLOWLIST
        if name in attributes
    }
    relationships = (
        entry.get("relationships") if isinstance(entry.get("relationships"), dict) else {}
    )
    return {
        "type": entry.get("type"),
        "id": entry.get("id"),
        "attributes": kept,
        "relationshipKeys": sorted(str(key) for key in relationships),
        "linkage": [
            {"name": name, **describe_relationship(body)}
            for name, body in relationships.items()
        ],
    }


def summarize_items_document(payload: Mapping[str, Any]) -> dict[str, Any]:
    """Turn a JSON:API items (or submission) document into a stable summary."""
    data = payload.get("data")
    items: list[Mapping[str, Any]] = []
    if isinstance(data, list):
        items = [entry for entry in data if isinstance(entry, dict)]
    elif isinstance(data, dict):
        items = [data]
    included_raw = payload.get("included")
    included = (
        [entry for entry in included_raw if isinstance(entry, dict)]
        if isinstance(included_raw, list)
        else []
    )
    return {
        "itemCount": len(items),
        "items": [summarize_item(item) for item in items],
        "includedCount": len(included),
        "included": [summarize_included(entry) for entry in included],
        "includedTypes": sorted(
            {
                str(entry.get("type"))
                for entry in included
                if isinstance(entry.get("type"), str)
            }
        ),
    }


def format_summary(summary: Mapping[str, Any], indent: str = "    ") -> list[str]:
    lines = [
        f"{indent}itemCount: {summary.get('itemCount')}",
        f"{indent}includedCount: {summary.get('includedCount')}",
        f"{indent}includedTypes: {', '.join(safe_name(name) for name in summary.get('includedTypes') or ['(none)'])}",
    ]
    for index, item in enumerate(summary.get("items") or [], start=1):
        decoded = item.get("decoded") or {}
        lines.append(f"{indent}item {index}:")
        lines.append(f"{indent}  type: {safe_name(item.get('type'))}")
        lines.append(f"{indent}  id: {asc_read.redact(item.get('id'))}")
        lines.append(
            f"{indent}  decoded.typeCode: {asc_read.redact(decoded.get('typeCode'))}"
        )
        lines.append(
            f"{indent}  decoded.resource: {asc_read.redact(decoded.get('resource'))}"
        )
        lines.append(f"{indent}  state: {asc_read.redact(item.get('state'))}")
        keys = item.get("relationshipKeys") or []
        lines.append(
            f"{indent}  relationshipKeys: {', '.join(safe_name(name) for name in keys) or '(none)'}"
        )
        for link in item.get("linkage") or []:
            lines.extend(_format_linkage(link, f"{indent}    "))
    for index, entry in enumerate(summary.get("included") or [], start=1):
        lines.append(f"{indent}included {index}:")
        lines.append(f"{indent}  type: {safe_name(entry.get('type'))}")
        lines.append(f"{indent}  id: {asc_read.redact(entry.get('id'))}")
        attributes = entry.get("attributes") or {}
        for name in INCLUDED_ATTRIBUTE_ALLOWLIST:
            if name in attributes:
                lines.append(
                    f"{indent}  attr.{name}: {asc_read.redact(attributes.get(name))}"
                )
        rel_keys = entry.get("relationshipKeys") or []
        if rel_keys:
            lines.append(
                f"{indent}  relationshipKeys: {', '.join(safe_name(name) for name in rel_keys)}"
            )
        for link in entry.get("linkage") or []:
            lines.extend(_format_linkage(link, f"{indent}    "))
    return lines


def _format_linkage(link: Mapping[str, Any], indent: str) -> list[str]:
    name = safe_name(link.get("name"))
    kind = link.get("kind")
    related = link.get("related") or ""
    related_text = f" related={asc_read.redact(related)}" if related else ""
    if kind == "to-one":
        return [
            f"{indent}{name}: to-one type={safe_name(link.get('type'))} "
            f"id={asc_read.redact(link.get('id'))}{related_text}"
        ]
    if kind == "to-many":
        entries = link.get("entries") or []
        rendered = ", ".join(
            f"{safe_name(entry.get('type'))}:{asc_read.redact(entry.get('id'))}"
            for entry in entries
        )
        return [f"{indent}{name}: to-many [{rendered}]{related_text}"]
    if kind == "null":
        return [f"{indent}{name}: data=null{related_text}"]
    return [f"{indent}{name}: kind={asc_read.redact(kind)}{related_text}"]


def populated_linkage_names(summary: Mapping[str, Any]) -> list[str]:
    """Relationship names whose `data` is a resource identifier, not null."""
    names: list[str] = []
    seen: set[str] = set()
    for item in summary.get("items") or []:
        for link in item.get("linkage") or []:
            name = link.get("name")
            if (
                isinstance(name, str)
                and name not in seen
                and link.get("kind") in ("to-one", "to-many")
            ):
                seen.add(name)
                names.append(name)
    return names


def decoded_resource_ids(summary: Mapping[str, Any]) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    for item in summary.get("items") or []:
        resource = (item.get("decoded") or {}).get("resource")
        if isinstance(resource, str) and UUID_RE.fullmatch(resource) and resource not in seen:
            seen.add(resource)
            found.append(resource)
        for link in item.get("linkage") or []:
            identifier = link.get("id")
            if (
                isinstance(identifier, str)
                and UUID_RE.fullmatch(identifier)
                and identifier not in seen
            ):
                seen.add(identifier)
                found.append(identifier)
            for entry in link.get("entries") or []:
                identifier = entry.get("id")
                if (
                    isinstance(identifier, str)
                    and UUID_RE.fullmatch(identifier)
                    and identifier not in seen
                ):
                    seen.add(identifier)
                    found.append(identifier)
    return found


def _query_string(query: Mapping[str, str]) -> str:
    if not query:
        return "(none)"
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


def _labeled_get(
    credential: asc_read.Credential,
    label: str,
    path: str,
    query: Mapping[str, str],
) -> tuple[str, Optional[Mapping[str, Any]]]:
    print(f"{label}: GET {path}")
    print(f"  query: {_query_string(query)}")
    try:
        payload = _raw_get(credential, path, query)
        print("  SUCCESS (HTTP 200)")
        return "200", payload
    except ReadFailure as failure:
        print("  FAILURE:")
        print(str(failure))
        match = re.search(r"HTTP status: (\d+)", str(failure))
        return (match.group(1) if match else "error"), None


def _print_summary(payload: Mapping[str, Any]) -> dict[str, Any]:
    summary = summarize_items_document(payload)
    for line in format_summary(summary):
        print(line)
    return summary


def probe_items(
    credential: asc_read.Credential, label: str, submission_id: str
) -> dict[str, Any]:
    print()
    print("=" * 72)
    print(f"ITEMS MATRIX  {label}  id={asc_read.redact(submission_id)}")
    print("=" * 72)
    outcomes: dict[str, str] = {}
    documents: dict[str, dict[str, Any]] = {}
    path = f"/v1/reviewSubmissions/{submission_id}/items"
    for name, query in ITEMS_QUERIES:
        print()
        status, payload = _labeled_get(
            credential, f"[{label}/{name}]", path, query
        )
        outcomes[name] = status
        if payload is not None:
            documents[name] = _print_summary(payload)
    return {"outcomes": outcomes, "documents": documents}


def probe_submission_resource(
    credential: asc_read.Credential, label: str, submission_id: str
) -> dict[str, str]:
    print()
    print(f"SUBMISSION RESOURCE  {label}")
    outcomes: dict[str, str] = {}
    path = f"/v1/reviewSubmissions/{submission_id}"
    for name, query in SUBMISSION_QUERIES:
        print()
        status, payload = _labeled_get(
            credential, f"[{label}/submission-{name}]", path, query
        )
        outcomes[name] = status
        if payload is not None:
            _print_summary(payload)
    return outcomes


def probe_related_and_typed(
    credential: asc_read.Credential,
    leftover_documents: Mapping[str, Mapping[str, Any]],
) -> None:
    """Follow related links and typed GETs for leftover item resource ids.

    Uses the first successful leftover items document as the id source so a
    400 include cannot starve the typed-resource probes.
    """
    print()
    print("=" * 72)
    print("RELATED LINKS + TYPED RESOURCE GETS (leftover 8e9fbd18 only)")
    print("=" * 72)
    source = None
    for name in (
        "include-appStoreVersion",
        "no-include",
        "include-subscriptionVersion",
        "include-sub-versions-both",
        "include-version-and-sub-versions",
    ):
        if name in leftover_documents:
            source = leftover_documents[name]
            print(f"id source document: {name}")
            break
    if source is None:
        print("no leftover items document succeeded; skipping related/typed GETs")
        return

    item_ids = [
        item.get("id")
        for item in source.get("items") or []
        if isinstance(item.get("id"), str)
    ]
    for item_id in item_ids:
        quoted = urllib.parse.quote(item_id, safe="")
        for relationship in RELATED_RELATIONSHIPS:
            path = f"/v1/reviewSubmissionItems/{quoted}/{relationship}"
            print()
            _labeled_get(
                credential,
                f"[related/{relationship}]",
                path,
                {},
            )

    resource_ids = decoded_resource_ids(source)
    print()
    print(f"decoded/linked UUID resources: {len(resource_ids)}")
    for resource_id in resource_ids:
        for prefix in TYPED_RESOURCE_PATHS:
            print()
            _labeled_get(
                credential,
                f"[typed/{prefix.rsplit('/', 1)[-1]}]",
                f"{prefix}/{resource_id}",
                {},
            )


def probe_subscription_catalog(credential: asc_read.Credential) -> None:
    print()
    print("=" * 72)
    print("SUBSCRIPTION CATALOG (productId map, GET-only)")
    print("=" * 72)
    print()
    status, payload = _labeled_get(
        credential,
        "[catalog/subscriptionGroups]",
        f"/v1/apps/{core.APP_ID}/subscriptionGroups",
        {"include": "subscriptions", "limit": "200"},
    )
    if payload is None or status != "200":
        return
    included = payload.get("included")
    entries = included if isinstance(included, list) else []
    print(f"  included subscriptions: {len(entries)}")
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("type") != "subscriptions":
            continue
        attributes = entry.get("attributes") if isinstance(entry.get("attributes"), dict) else {}
        print(f"  subscription id: {asc_read.redact(entry.get('id'))}")
        print(f"    productId: {asc_read.redact(attributes.get('productId'))}")
        print(f"    state: {asc_read.redact(attributes.get('state'))}")
        print(f"    name: {asc_read.redact(attributes.get('name'))}")


def print_matrix(results: Sequence[tuple[str, Mapping[str, str]]]) -> None:
    print()
    print("=" * 72)
    print("INCLUDE/FILTER MATRIX (HTTP status per query; GET-only)")
    print("=" * 72)
    for label, outcomes in results:
        print(f"  {label}:")
        for name, status in outcomes.items():
            print(f"    {name}: {status}")


def main() -> int:
    print("App Review subscription review-item shape probe (GET-only, no secrets)")
    print(f"app: {core.APP_ID}  leftover: {LEFTOVER_SUBMISSION_ID}")
    print(f"active: {ACTIVE_SUBMISSION_ID}")
    print("writes=0 method=GET")
    print()

    try:
        credential = asc_read.Credential.from_environment()
    except asc_read.AppStoreConnectError as error:
        print(f"FATAL: could not build credential: {asc_read.redact(error)}")
        return 2

    leftover = probe_items(credential, "leftover", LEFTOVER_SUBMISSION_ID)
    leftover_submission = probe_submission_resource(
        credential, "leftover", LEFTOVER_SUBMISSION_ID
    )
    active = probe_items(credential, "active", ACTIVE_SUBMISSION_ID)
    active_submission = probe_submission_resource(
        credential, "active", ACTIVE_SUBMISSION_ID
    )
    probe_related_and_typed(credential, leftover["documents"])
    probe_subscription_catalog(credential)

    print_matrix(
        (
            ("leftover items", leftover["outcomes"]),
            ("leftover submission", leftover_submission),
            ("active items", active["outcomes"]),
            ("active submission", active_submission),
        )
    )

    leftover_ok = any(status == "200" for status in leftover["outcomes"].values())
    if not leftover_ok:
        print()
        print("summary: leftover items collection never returned HTTP 200")
        return 1
    print()
    print("summary: leftover items collection returned at least one HTTP 200")
    populated = []
    for name, document in leftover["documents"].items():
        names = populated_linkage_names(document)
        print(
            f"  leftover {name} populated relationship names: "
            + (", ".join(safe_name(item) for item in names) or "(none)")
        )
        populated.extend(names)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
