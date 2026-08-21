#!/usr/bin/env python3
"""GET-only readout of the 0.1.17 en-US App Store version description.

Captain-directed: print the live App Store Connect identifiers and the
verbatim en-US App Description so a human can edit listing copy. This
entrypoint imports neither `asc_write` nor `submission`, sends only GET, and
cannot PATCH, POST, or submit.

Hard safety, this handles a live credential:
  * GET-only via `asc_read.ReadSession`.
  * It never prints the API key, private key PEM, issuer id, key id, signed
    JWT, Authorization header, or any environment value.
  * The App Description is public store copy; it is printed verbatim between
    fixed markers so a captain can copy it without a dump of other listing
    fields.
"""

from __future__ import annotations

from pathlib import Path
import sys
from typing import Any, Mapping, Sequence

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import core  # noqa: E402

VERSION = "0.1.17"
LOCALE = "en-US"
DESCRIPTION_BEGIN = "--- description verbatim ---"
DESCRIPTION_END = "--- end description ---"


class DescriptionReadError(asc_read.AppStoreConnectError):
    """A bounded failure locating the exact version localization."""


def select_ios_version(
    versions: Sequence[Mapping[str, Any]],
    version_string: str,
    platform: str,
) -> Mapping[str, Any]:
    matching = [
        item
        for item in versions
        if asc_read.attributes(item).get("versionString") == version_string
        and asc_read.attributes(item).get("platform") == platform
    ]
    if len(matching) != 1:
        raise DescriptionReadError(
            f"the {version_string} {platform} App Store version is absent or ambiguous"
        )
    return matching[0]


def select_localization(
    items: Sequence[Mapping[str, Any]], locale: str
) -> Mapping[str, Any]:
    matching = [
        item for item in items if asc_read.attributes(item).get("locale") == locale
    ]
    if len(matching) != 1:
        raise DescriptionReadError(
            f"the {locale} version localization is absent or ambiguous"
        )
    return matching[0]


def read_report(
    session: asc_read.ReadSession,
    *,
    app_id: str = core.APP_ID,
    version_string: str = VERSION,
    platform: str = core.PLATFORM,
    locale: str = LOCALE,
) -> dict[str, Any]:
    versions, _ = session.collection(
        f"/v1/apps/{app_id}/appStoreVersions",
        {
            "filter[versionString]": version_string,
            "filter[platform]": platform,
            "limit": "200",
        },
    )
    version = select_ios_version(versions, version_string, platform)
    localizations, _ = session.collection(
        f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
        {
            "fields[appStoreVersionLocalizations]": "locale,description",
            "limit": "50",
        },
    )
    localization = select_localization(localizations, locale)
    attributes = asc_read.attributes(localization)
    return {
        "app_id": app_id,
        "version_string": version_string,
        "platform": platform,
        "locale": locale,
        "app_store_version_id": version["id"],
        "en_us_localization_id": localization["id"],
        "description": asc_read.text(attributes, "description"),
        "locales": [
            (str(asc_read.attributes(item).get("locale") or ""), item["id"])
            for item in localizations
        ],
    }


def render_report(report: Mapping[str, Any]) -> str:
    description = report["description"]
    locales = ", ".join(
        f"{locale or '?'}={identifier}" for locale, identifier in report["locales"]
    )
    return "\n".join(
        (
            "App Store Connect 0.1.17 en-US description (GET-only, no mutation)",
            f"app_id={report['app_id']}",
            f"app_store_version_id={report['app_store_version_id']}",
            f"en_us_localization_id={report['en_us_localization_id']}",
            f"description_chars={len(description)}",
            f"locales={locales}",
            DESCRIPTION_BEGIN,
            description,
            DESCRIPTION_END,
        )
    )


def main() -> int:
    credential = asc_read.Credential.from_environment()
    report = read_report(asc_read.ReadSession(credential))
    print(render_report(report), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except core.BoundedError as error:
        print(
            f"EDDIES_APP_REVIEW refused ({type(error).__name__}): "
            f"{asc_read.redact(error)}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    except Exception:  # noqa: BLE001 - deliberately silent
        print(
            "EDDIES_APP_REVIEW refused: unexpected pipeline failure",
            file=sys.stderr,
        )
        raise SystemExit(1)
