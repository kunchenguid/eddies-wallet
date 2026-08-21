#!/usr/bin/env python3
"""GET-only listing of every iOS App Store version for Eddie's Wallet.

Prints every `appStoreVersion` row Apple returns for app 6795664301:
versionString, appVersionState, appStoreState, createdDate. Pagination follows
`links.next`. This entrypoint imports the structurally GET-only client and
cannot construct any other HTTP method.
"""

from __future__ import annotations

from pathlib import Path
import sys
from typing import Any, Mapping, Sequence

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import runtime  # noqa: E402

APP_ID = "6795664301"
VERSIONS_PATH = f"/v1/apps/{APP_ID}/appStoreVersions"
VERSIONS_FIELDS = "versionString,appVersionState,appStoreState,createdDate"
VERSIONS_QUERY = {
    "fields[appStoreVersions]": VERSIONS_FIELDS,
    "filter[platform]": "IOS",
    "limit": "200",
}
COLUMNS = ("versionString", "appVersionState", "appStoreState", "createdDate")


def rows_from(items: Sequence[Mapping[str, Any]]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for item in items:
        if item.get("type") != "appStoreVersions":
            continue
        attributes = item.get("attributes")
        if not isinstance(attributes, dict):
            attributes = {}
        row = {name: "" if attributes.get(name) is None else str(attributes.get(name)) for name in COLUMNS}
        row["id"] = str(item.get("id") or "")
        rows.append(row)
    rows.sort(key=lambda row: (row["versionString"], row["createdDate"], row["id"]))
    return rows


def format_table(rows: Sequence[Mapping[str, str]]) -> str:
    header = "versionString\tappVersionState\tappStoreState\tcreatedDate\tid"
    lines = [
        f"GET {VERSIONS_PATH}?fields[appStoreVersions]={VERSIONS_FIELDS}&filter[platform]=IOS&limit=200",
        f"count={len(rows)} writes=0 method=GET",
        header,
    ]
    for row in rows:
        lines.append(
            "\t".join(row[name] for name in (*COLUMNS, "id"))
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    runtime.heading("App Review iOS version listing")
    session = asc_read.ReadSession(asc_read.Credential.from_environment())
    items, _included = session.collection(VERSIONS_PATH, VERSIONS_QUERY)
    rows = rows_from(items)
    sys.stdout.write(format_table(rows))
    runtime.emit(f"versions={len(rows)} mutations=0")
    return 0


if __name__ == "__main__":
    sys.exit(runtime.run(main))
