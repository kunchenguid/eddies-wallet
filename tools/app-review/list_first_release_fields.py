#!/usr/bin/env python3
"""GET-only live-vs-config dump of first-release fields the Node engine validates.

Reads the same App Store Connect resources `app-review-submit@62bfbc3b` uses in
`validate_protected` / first-release `validate_target` / `validate_subscriptions`.
This entrypoint imports the structurally GET-only client and cannot construct
any other HTTP method. It writes nothing to App Store Connect.
"""

from __future__ import annotations

from pathlib import Path
import json
import sys
from typing import Any, Mapping, Optional

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import runtime  # noqa: E402

APP_ID = "6795664301"
BUNDLE_ID = "com.kunchenguid.eddieswallet"
VERSION = "0.1.17"
CONFIG_PATH = Path("tools/app-review/app-review.config.json")
MANIFEST_PATH = Path("tools/app-review/manifests/0.1.17.json")
ENGINE_REVIEWABLE = frozenset(
    (
        "WAITING_FOR_SUBMIT",
        "READY_TO_SUBMIT",
        "WAITING_FOR_REVIEW",
        "IN_REVIEW",
        "APPROVED",
    )
)


def _bool_text(value: object) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    text = str(value).strip().lower()
    if text in ("true", "false"):
        return text
    return str(value) if value is not None else "missing"


def _attr(resource: Optional[Mapping[str, Any]], name: str) -> str:
    if not resource:
        return ""
    attributes = resource.get("attributes")
    if not isinstance(attributes, dict):
        return ""
    value = attributes.get(name)
    return "" if value is None else str(value)


def _relationship_id(resource: Optional[Mapping[str, Any]]) -> str:
    if not resource:
        return ""
    identifier = resource.get("id")
    return identifier if isinstance(identifier, str) else ""


def _compact(value: object) -> str:
    return asc_read.redact(value) if value not in ("", None) else ""


def _match(config_value: str, live_value: str) -> str:
    if live_value.startswith("ERROR"):
        return "unread"
    if config_value.startswith("(not in config"):
        if live_value in ("", "null", "missing"):
            return "engine-required-missing"
        return "live-only"
    return "match" if config_value == live_value else "mismatch"


def _row(field: str, config_value: str, live_value: str) -> str:
    return "\t".join((field, config_value, live_value, _match(config_value, live_value)))


def _optional(session: asc_read.ReadSession, path: str, query: Optional[Mapping[str, str]] = None):
    try:
        return session.optional_single(path, query or {})
    except asc_read.AppStoreConnectError as error:
        if "status 404" in str(error):
            return None
        raise


def _collection(session: asc_read.ReadSession, path: str, query: Mapping[str, str]):
    try:
        return session.collection(path, query)
    except asc_read.AppStoreConnectError as error:
        if "status 404" in str(error):
            return [], []
        raise


def load_config() -> dict[str, Any]:
    return json.loads(CONFIG_PATH.read_text())


def main() -> int:
    runtime.heading("App Review first-release fields (GET-only)")
    config = load_config()
    protected = config["protected"]
    review_details = config["reviewDetails"]
    product_ids = list(config["commerce"]["productIds"])
    expected_release = json.loads(MANIFEST_PATH.read_text())["candidate"]["releaseType"]
    session = asc_read.ReadSession(asc_read.Credential.from_environment())
    lines = [
        "GET-only first-release field compare writes=0 method=GET",
        f"app={APP_ID} version={VERSION}",
        "field\tconfig\tlive\tresult",
    ]

    apps, _ = session.collection(
        "/v1/apps",
        {
            "filter[bundleId]": BUNDLE_ID,
            "fields[apps]": "name,bundleId,contentRightsDeclaration,isOrEverWasMadeForKids",
            "limit": "10",
        },
    )
    app = next((item for item in apps if item.get("id") == APP_ID), None)
    lines.append(
        _row(
            "contentRightsDeclaration",
            str(protected["contentRightsDeclaration"]),
            _attr(app, "contentRightsDeclaration") or "missing",
        )
    )
    live_kids = ""
    if app:
        attributes = app.get("attributes") if isinstance(app.get("attributes"), dict) else {}
        live_kids = _bool_text(attributes.get("isOrEverWasMadeForKids"))
    lines.append(
        _row(
            "isOrEverWasMadeForKids",
            _bool_text(protected["isOrEverWasMadeForKids"]),
            live_kids or "missing",
        )
    )
    lines.append(
        _row(
            "appName",
            str(config["app"]["name"]),
            _attr(app, "name") or "missing",
        )
    )

    versions, _ = session.collection(
        f"/v1/apps/{APP_ID}/appStoreVersions",
        {
            "filter[platform]": "IOS",
            "filter[versionString]": VERSION,
            "fields[appStoreVersions]": "versionString,platform,appVersionState,copyright,releaseType",
            "limit": "20",
        },
    )
    target = versions[0] if len(versions) == 1 else None
    if len(versions) != 1:
        live_copyright = f"ERROR version-count={len(versions)}"
        live_release = live_copyright
        live_state = live_copyright
    else:
        live_copyright = _attr(target, "copyright") or "missing"
        live_release = _attr(target, "releaseType") or "missing"
        live_state = _attr(target, "appVersionState") or "missing"
    lines.append(
        _row("copyright", str(review_details.get("copyright") or ""), live_copyright)
    )
    lines.append(_row("releaseType", str(expected_release), live_release))
    lines.append(
        _row(
            "appVersionState",
            "(not in config; engine accepts REJECTED/editable first-release)",
            live_state,
        )
    )

    infos, _ = session.collection(
        f"/v1/apps/{APP_ID}/appInfos",
        {"fields[appInfos]": "state", "limit": "20"},
    )
    current_infos = [
        item
        for item in infos
        if item.get("type") == "appInfos"
        and _attr(item, "state") != "REPLACED_WITH_NEW_INFO"
    ]
    info = current_infos[0] if len(current_infos) == 1 else (infos[0] if infos else None)
    info_id = str(info.get("id") or "") if info else ""
    info_state = _attr(info, "state") if info else "missing"
    if info_id:
        primary = _optional(
            session, f"/v1/appInfos/{info_id}/relationships/primaryCategory"
        )
        secondary = _optional(
            session, f"/v1/appInfos/{info_id}/relationships/secondaryCategory"
        )
        age = _optional(session, f"/v1/appInfos/{info_id}/ageRatingDeclaration")
        live_primary = _relationship_id(primary)
        live_secondary = _relationship_id(secondary)
        if age:
            age_id = str(age.get("id") or "")
            age_attrs = age.get("attributes") if isinstance(age.get("attributes"), dict) else {}
            notable = {
                key: age_attrs.get(key)
                for key in (
                    "kidsAgeBand",
                    "ageRatingOverride",
                    "koreaAgeRatingOverride",
                    "gambling",
                    "contests",
                    "unrestrictedWebAccess",
                    "gamblingSimulated",
                    "horrorOrFearThemes",
                    "matureOrSuggestiveThemes",
                    "medicalOrTreatmentInformation",
                    "alcoholTobaccoOrDrugUseOrReferences",
                    "profanityOrCrudeHumor",
                    "sexualContentGraphicAndNudity",
                    "sexualContentOrNudity",
                    "violenceCartoonOrFantasy",
                    "violenceRealistic",
                    "violenceRealisticProlongedGraphicOrSadistic",
                )
                if key in age_attrs
            }
            live_age = f"present id={age_id} " + " ".join(
                f"{key}={_compact(value)}" for key, value in notable.items()
            )
        else:
            live_age = "missing"
    else:
        live_primary = "missing"
        live_secondary = "missing"
        live_age = "missing"
    lines.append(
        _row(
            "primaryCategory",
            str(protected["primaryCategory"]),
            live_primary or "empty",
        )
    )
    lines.append(
        _row(
            "secondaryCategory",
            str(protected.get("secondaryCategory") or ""),
            live_secondary or "empty",
        )
    )
    lines.append(
        _row(
            "ageRatingDeclaration",
            "(not in config; engine asserts non-null)",
            live_age,
        )
    )
    lines.append(
        _row(
            "appInfoState",
            "(not in config; engine selects non-replaced App Info)",
            info_state or "missing",
        )
    )

    schedule = _optional(session, f"/v1/apps/{APP_ID}/appPriceSchedule")
    if not schedule:
        lines.append(
            _row(
                "priceSchedule",
                "(not in config; engine requires a schedule, product is free)",
                "missing",
            )
        )
    else:
        schedule_id = str(schedule.get("id") or "")
        base = _optional(session, f"/v1/appPriceSchedules/{schedule_id}/baseTerritory")
        base_id = _relationship_id(base) or _attr(base, "currency") or (str(base.get("id") or "") if base else "")
        manual, _ = _collection(
            session,
            f"/v1/appPriceSchedules/{schedule_id}/manualPrices",
            {"limit": "200"},
        )
        prices: list[str] = []
        for item in manual[:20]:
            point = None
            point_id = ""
            relationships = item.get("relationships")
            if isinstance(relationships, dict):
                point_rel = relationships.get("appPricePoint")
                if isinstance(point_rel, dict):
                    data = point_rel.get("data")
                    if isinstance(data, dict) and isinstance(data.get("id"), str):
                        point_id = data["id"]
            if point_id:
                try:
                    payload = session.get(f"/v1/appPricePoints/{point_id}", {})
                    point = payload.get("data") if isinstance(payload, dict) else None
                except asc_read.AppStoreConnectError:
                    point = None
                    customer = f"point-unread:{point_id}"
                    prices.append(customer)
                    continue
            customer = _attr(point, "customerPrice") if isinstance(point, dict) else ""
            prices.append(customer or f"point={point_id or 'absent'}")
        unique = sorted(set(prices))
        live_price = (
            f"schedule={schedule_id} baseTerritory={base_id or 'missing'} "
            f"manualPrices={len(manual)} customerPrices={','.join(unique) or 'none'}"
        )
        lines.append(
            _row(
                "priceSchedule",
                "(not in config; engine hashes live schedule; product is free)",
                live_price,
            )
        )

    availability = _optional(session, f"/v1/apps/{APP_ID}/appAvailabilityV2")
    if availability:
        avail_id = str(availability.get("id") or "")
        available_in_new = _attr(availability, "availableInNewTerritories")
        territories, _ = _collection(
            session,
            f"/v1/appAvailabilities/{avail_id}/territoryAvailabilities",
            {"limit": "200"},
        )
        live_avail = (
            f"present id={avail_id} availableInNewTerritories={available_in_new or 'absent'} "
            f"territories={len(territories)}"
        )
    else:
        live_avail = "missing"
    lines.append(
        _row(
            "availability",
            "(not in config; engine requires appAvailabilityV2 present)",
            live_avail,
        )
    )

    _groups, included = session.collection(
        f"/v1/apps/{APP_ID}/subscriptionGroups",
        {
            "fields[subscriptionGroups]": "referenceName",
            "fields[subscriptions]": "productId,state,name",
            "include": "subscriptions",
            "limit": "50",
        },
    )
    states = {
        _attr(item, "productId"): _attr(item, "state")
        for item in included
        if item.get("type") == "subscriptions"
    }
    for product_id in product_ids:
        live_state = states.get(product_id) or "missing"
        config_sub = "reviewable"
        result = "match" if live_state in ENGINE_REVIEWABLE else "mismatch"
        lines.append(
            "\t".join(
                (
                    f"subscription.{product_id}",
                    config_sub,
                    live_state,
                    result,
                )
            )
        )

    text = "\n".join(lines) + "\n"
    sys.stdout.write(text)
    runtime.emit("mutations=0")
    mismatches = [line for line in lines if line.endswith("\tmismatch")]
    runtime.emit(f"mismatches={len(mismatches)}")
    return 0


if __name__ == "__main__":
    sys.exit(runtime.run(main))
