#!/usr/bin/env python3
"""GET-only listing of live App Info categories for Eddie's Wallet.

Reads `/v1/apps/6795664301/appInfos`, then each row's primaryCategory and
secondaryCategory relationships, then `/v1/appCategories/{id}` so the printed
name is Apple's category resource id (FINANCE, EDUCATION, PRODUCTIVITY, ...).
This entrypoint imports the structurally GET-only client and cannot construct
any other HTTP method.
"""

from __future__ import annotations

from pathlib import Path
import json
import sys
from typing import Any, Mapping, Optional, Protocol, Sequence

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import runtime  # noqa: E402

APP_ID = "6795664301"
INFOS_PATH = f"/v1/apps/{APP_ID}/appInfos"
INFOS_QUERY = {"fields[appInfos]": "state", "limit": "20"}
CONFIG_PATH = Path("tools/app-review/app-review.config.json")
COLUMNS = (
    "appInfoId",
    "state",
    "primaryId",
    "primaryName",
    "secondaryId",
    "secondaryName",
)


class CategoryReadSession(Protocol):
    def collection(
        self, path: str, query: Mapping[str, str]
    ) -> tuple[list[Mapping[str, Any]], list[Mapping[str, Any]]]: ...

    def optional_single(
        self, path: str, query: Mapping[str, str]
    ) -> Optional[Mapping[str, Any]]: ...

    def get(self, path: str, query: Mapping[str, str]) -> Mapping[str, Any]: ...


def configured_categories(path: Path = CONFIG_PATH) -> tuple[str, str]:
    document = json.loads(path.read_text())
    protected = document["protected"]
    return str(protected["primaryCategory"]), str(protected["secondaryCategory"])


def _relationship_id(resource: Optional[Mapping[str, Any]]) -> str:
    if not resource:
        return ""
    identifier = resource.get("id")
    return identifier if isinstance(identifier, str) else ""


def _category_name(payload: Mapping[str, Any], relationship_id: str) -> str:
    data = payload.get("data")
    if isinstance(data, dict) and data.get("type") == "appCategories":
        identifier = data.get("id")
        if isinstance(identifier, str) and identifier:
            return identifier
    return relationship_id


def collect_rows(session: CategoryReadSession) -> list[dict[str, str]]:
    infos, _included = session.collection(INFOS_PATH, INFOS_QUERY)
    rows: list[dict[str, str]] = []
    for item in infos:
        if item.get("type") != "appInfos":
            continue
        info_id = str(item.get("id") or "")
        attributes = item.get("attributes")
        if not isinstance(attributes, dict):
            attributes = {}
        state = "" if attributes.get("state") is None else str(attributes.get("state"))
        primary = session.optional_single(
            f"/v1/appInfos/{info_id}/relationships/primaryCategory", {}
        )
        secondary = session.optional_single(
            f"/v1/appInfos/{info_id}/relationships/secondaryCategory", {}
        )
        primary_id = _relationship_id(primary)
        secondary_id = _relationship_id(secondary)
        primary_name = primary_id
        secondary_name = secondary_id
        if primary_id:
            primary_name = _category_name(
                session.get(f"/v1/appCategories/{primary_id}", {}), primary_id
            )
        if secondary_id:
            secondary_name = _category_name(
                session.get(f"/v1/appCategories/{secondary_id}", {}), secondary_id
            )
        rows.append(
            {
                "appInfoId": info_id,
                "state": state,
                "primaryId": primary_id,
                "primaryName": primary_name,
                "secondaryId": secondary_id,
                "secondaryName": secondary_name,
            }
        )
    rows.sort(key=lambda row: (row["state"], row["appInfoId"]))
    return rows


def format_table(
    rows: Sequence[Mapping[str, str]], configured: tuple[str, str]
) -> str:
    configured_primary, configured_secondary = configured
    lines = [
        f"GET {INFOS_PATH}?fields[appInfos]=state&limit=20",
        f"count={len(rows)} writes=0 method=GET",
        f"configured.primary={configured_primary} configured.secondary={configured_secondary}",
        "\t".join(COLUMNS),
    ]
    for row in rows:
        lines.append("\t".join(row[name] for name in COLUMNS))
    return "\n".join(lines) + "\n"


def live_summary(rows: Sequence[Mapping[str, str]]) -> str:
    if not rows:
        return "live.primary= live.secondary= appInfos=0"
    primaries = sorted({row["primaryName"] for row in rows})
    secondaries = sorted({row["secondaryName"] for row in rows})
    return (
        f"live.primary={','.join(primaries)} "
        f"live.secondary={','.join(secondaries)} "
        f"appInfos={len(rows)}"
    )


def main() -> int:
    runtime.heading("App Review App Info categories")
    session = asc_read.ReadSession(asc_read.Credential.from_environment())
    rows = collect_rows(session)
    configured = configured_categories()
    sys.stdout.write(format_table(rows, configured))
    runtime.emit(live_summary(rows))
    runtime.emit("mutations=0")
    return 0


if __name__ == "__main__":
    sys.exit(runtime.run(main))
