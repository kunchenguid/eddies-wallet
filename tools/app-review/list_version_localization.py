#!/usr/bin/env python3
"""GET-only dump of the pinned 0.1.17 en-US version localization.

Prints the exact live description bytes (base64) plus the other observe-compared
listing fields so config can be matched to ASC without writing App Store copy.
This entrypoint imports the structurally GET-only client and cannot construct
any other HTTP method.
"""

from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import sys
from typing import Any, Mapping

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import runtime  # noqa: E402

APP_ID = "6795664301"
LOCALIZATION_ID = "3d89b9a4-a341-439b-a6cb-2ead4e2db35a"
LOCALIZATION_PATH = f"/v1/appStoreVersionLocalizations/{LOCALIZATION_ID}"
LOCALIZATION_QUERY = {
    "fields[appStoreVersionLocalizations]": (
        "description,locale,keywords,marketingUrl,promotionalText,"
        "supportUrl,whatsNew"
    )
}
COMPARED_FIELDS = (
    "description",
    "keywords",
    "promotionalText",
    "supportUrl",
    "whatsNew",
    "marketingUrl",
)
MANIFEST_PATH = Path("tools/app-review/manifests/0.1.17.json")


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _text(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise TypeError("localization field is not a string")
    return value


def main() -> int:
    runtime.heading("App Review 0.1.17 en-US localization (GET-only)")
    manifest = json.loads(MANIFEST_PATH.read_text())
    listing = manifest["content"]["listing"]
    session = asc_read.ReadSession(asc_read.Credential.from_environment())
    payload = session.get(LOCALIZATION_PATH, LOCALIZATION_QUERY)
    data = payload.get("data")
    if not isinstance(data, dict):
        raise RuntimeError("localization payload is not an object")
    loc_id = data.get("id")
    attributes = data.get("attributes")
    if not isinstance(attributes, dict):
        raise RuntimeError("localization attributes are missing")
    locale = attributes.get("locale")
    print(f"GET {LOCALIZATION_PATH} writes=0 method=GET")
    print(f"app={APP_ID} localization={loc_id} locale={locale}")
    live_fields: dict[str, Any] = {}
    for name in COMPARED_FIELDS:
        live_fields[name] = attributes.get(name)
        live_value = _text(attributes.get(name))
        manifest_value = listing.get(name)
        if name == "marketingUrl" and manifest_value in ("", None):
            manifest_value = None
        live_shown = live_value
        manifest_shown = manifest_value if isinstance(manifest_value, str) else None
        live_chars = 0 if live_shown is None else len(live_shown)
        manifest_chars = 0 if manifest_shown is None else len(manifest_shown)
        match = live_shown == manifest_shown
        print(
            f"field={name} match={str(match).lower()} "
            f"live_chars={live_chars} manifest_chars={manifest_chars} "
            f"live_null={str(live_shown is None).lower()} "
            f"manifest_null={str(manifest_shown is None).lower()}"
        )
        if name != "description":
            print(f"live.{name}={json.dumps(live_shown, ensure_ascii=False)}")
            print(f"manifest.{name}={json.dumps(manifest_shown, ensure_ascii=False)}")
    description = _text(attributes.get("description"))
    if description is None:
        raise RuntimeError("live description is missing")
    encoded = base64.b64encode(description.encode("utf-8")).decode("ascii")
    print(f"description_sha256={_sha256(description)}")
    print(f"manifest_description_sha256={_sha256(str(listing.get('description') or ''))}")
    print("LIVE_DESCRIPTION_B64_BEGIN")
    print(encoded)
    print("LIVE_DESCRIPTION_B64_END")
    print("LIVE_FIELDS_JSON_BEGIN")
    print(json.dumps(live_fields, ensure_ascii=False, separators=(",", ":")))
    print("LIVE_FIELDS_JSON_END")
    runtime.emit(f"localization={loc_id} locale={locale} mutations=0")
    return 0


if __name__ == "__main__":
    sys.exit(runtime.run(main))
