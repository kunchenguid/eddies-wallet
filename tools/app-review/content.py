#!/usr/bin/env python3
"""Bind the captain-approved manifest to real bytes and to real App Store state.

Two independent proofs meet here.

The manifest owns every reviewed string and a byte descriptor (path, size,
SHA-256) for every reviewed image. `verify_manifest_files` recomputes those
descriptors from the checked-out manifest-approved commit, so a manifest can
never point at a file whose bytes changed after the captain approved it.

App Store Connect owns the live reviewed state. `CandidateReadTransport` reads
it GET-only and normalizes it into exactly the document shape the deterministic
core reconciles. Apple never returns our SHA-256, so image identity is proven
the only way it honestly can be: Apple's own file name, byte size, and MD5
source checksum are compared against the same local file the manifest hashed.
Everything else - listing copy, in-app purchase review notes, App Review notes
and the demo-account answer - is taken from Apple verbatim, so a difference from
the manifest is a real difference and the core refuses the candidate.
"""

from __future__ import annotations

import hashlib
from pathlib import Path, PurePosixPath
import sys
from typing import Any, Mapping, Optional

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import core  # noqa: E402

REVIEWED_LOCALE = "en-US"
ASSET_COMPLETE = "COMPLETE"

# App Store Connect stores a subscription App Review screenshot's `fileName` as
# this literal sentinel rather than the real uploaded name, even after a correct
# re-upload. A listing screenshot instead carries its real uploaded file name, so
# only a subscription review asset whose name is exactly this sentinel is allowed
# to bind by byte size and MD5 alone.
SOURCE_FILENAME_SENTINEL = "SOURCE"


class ContentError(core.BoundedError):
    """A bounded, nonsecret reviewed-content binding failure."""


def verify_manifest_files(
    manifest: Mapping[str, Any], source_root: Path
) -> Mapping[str, Mapping[str, Any]]:
    """Prove every approved image still has exactly the approved bytes.

    Returns one entry per reviewed path carrying the recomputed size, SHA-256,
    and the MD5 App Store Connect reports for the same upload.
    """
    approved = core.validate_manifest(manifest)
    descriptors: list[Mapping[str, Any]] = []
    for screenshot in approved["content"]["screenshots"]:
        descriptors.extend(screenshot["files"])
    for purchase in approved["content"]["inAppPurchases"]:
        descriptors.append(purchase["reviewScreenshot"])

    verified: dict[str, Mapping[str, Any]] = {}
    for descriptor in descriptors:
        path = descriptor["path"]
        data = _read_reviewed_file(source_root, path)
        if len(data) != descriptor["bytes"]:
            raise ContentError(f"reviewed file changed size since approval: {path}")
        if hashlib.sha256(data).hexdigest() != descriptor["sha256"]:
            raise ContentError(f"reviewed file changed content since approval: {path}")
        verified[path] = {
            "bytes": len(data),
            "sha256": descriptor["sha256"],
            "md5": hashlib.md5(data).hexdigest(),
            "name": PurePosixPath(path).name,
        }
    return verified


def _read_reviewed_file(source_root: Path, relative_path: str) -> bytes:
    root = source_root.resolve()
    if not root.is_dir():
        raise ContentError("review source root is not a directory")
    current = root
    for part in PurePosixPath(relative_path).parts:
        current = current / part
        if current.is_symlink():
            raise ContentError(
                f"reviewed file must not traverse a symbolic link: {relative_path}"
            )
    if not current.is_file():
        raise ContentError(f"reviewed file is missing: {relative_path}")
    return current.read_bytes()


class CandidateReadTransport:
    """The concrete GET boundary behind `core.ReadOnlyASCClient`.

    `core.ReadOnlyASCClient` calls `get` exactly once per candidate read and
    hands back a `core.LiveReadState`. This transport therefore performs the
    whole read and returns the normalized state document, never a raw Apple
    payload. It exposes no other method, so the client cannot widen it.
    """

    __slots__ = ("_session", "_candidate", "_verified_files", "_reads")

    def __init__(
        self,
        session: asc_read.ReadSession,
        candidate: Mapping[str, Any],
        verified_files: Mapping[str, Mapping[str, Any]],
    ):
        self._session = session
        self._candidate = dict(candidate)
        self._verified_files = verified_files
        self._reads = 0

    @property
    def reads(self) -> int:
        return self._reads

    def get(self, path: str, query: Mapping[str, str]) -> Mapping[str, Any]:
        # The core flattens any unrecognized transport exception into a generic
        # read failure, so translate first: the specific bounded reason is what
        # makes a refusal actionable without ever carrying an Apple payload.
        try:
            return self._read(path, query)
        except core.AppReviewError:
            raise
        except (asc_read.AppStoreConnectError, ContentError) as error:
            core.refuse("E_ASC_READ", str(error))
            raise AssertionError("unreachable")

    def _read(self, path: str, query: Mapping[str, str]) -> Mapping[str, Any]:
        self._reads += 1
        self._assert_app_identity()
        version = self._read_version(path, query)
        if version is None:
            return {
                "appId": core.APP_ID,
                "bundleId": core.BUNDLE_ID,
                "platform": core.PLATFORM,
                "version": self._candidate["version"],
                "build": self._candidate["build"],
                "state": "ABSENT",
                "releaseType": None,
                "content": None,
            }
        version_id, version_attributes, build_version = version
        return {
            "appId": core.APP_ID,
            "bundleId": core.BUNDLE_ID,
            "platform": core.PLATFORM,
            "version": asc_read.text(version_attributes, "versionString"),
            "build": build_version,
            "state": asc_read.text(version_attributes, "appVersionState"),
            "releaseType": version_attributes.get("releaseType"),
            "content": self.collect_content(version_id),
        }

    # -- live reads ---------------------------------------------------------

    def _assert_app_identity(self) -> None:
        app = self._session.get(f"/v1/apps/{core.APP_ID}", {"fields[apps]": "bundleId"})
        data = app.get("data")
        if not isinstance(data, dict):
            raise asc_read.AppStoreConnectError("App Store Connect returned no app")
        found = asc_read.attributes(asc_read.resource(data)).get("bundleId")
        if found != core.BUNDLE_ID:
            raise asc_read.AppStoreConnectError(
                "App Store Connect app record is not Eddie's Wallet"
            )

    def _read_version(
        self, path: str, query: Mapping[str, str]
    ) -> Optional[tuple[str, Mapping[str, Any], str]]:
        versions, included = self._session.collection(
            path,
            {
                **dict(query),
                "fields[appStoreVersions]": "versionString,appVersionState,platform,releaseType,build",
                "fields[builds]": "version,expired",
                "include": "build",
                "limit": "50",
            },
        )
        matching = [
            item
            for item in versions
            if item.get("type") == "appStoreVersions"
            and asc_read.attributes(item).get("versionString")
            == self._candidate["version"]
            and asc_read.attributes(item).get("platform") == core.PLATFORM
        ]
        if not matching:
            return None
        if len(matching) > 1:
            raise asc_read.AppStoreConnectError(
                "the exact marketing version is ambiguous on App Store Connect"
            )
        version = matching[0]
        build_id = asc_read.linkage_id(version, "build", "builds")
        if build_id is None:
            raise asc_read.AppStoreConnectError(
                "the exact marketing version has no bound build"
            )
        builds = {
            item["id"]: asc_read.attributes(item)
            for item in included
            if item.get("type") == "builds"
        }
        bound = builds.get(build_id)
        if bound is None or bound.get("expired") is not False:
            raise asc_read.AppStoreConnectError(
                "the bound build is absent, expired, or superseded"
            )
        return version["id"], asc_read.attributes(version), asc_read.text(bound, "version")

    def collect_content(self, version_id: str) -> Mapping[str, Any]:
        """Assemble the live reviewed content in the deterministic core's shape."""
        localization = self._version_localization(version_id)
        app_info = self._app_info_localization()
        return {
            "listing": {
                "appName": asc_read.text(app_info, "name"),
                "subtitle": asc_read.text(app_info, "subtitle"),
                "promotionalText": asc_read.text(localization[1], "promotionalText"),
                "description": asc_read.text(localization[1], "description"),
                "keywords": asc_read.text(localization[1], "keywords"),
                "privacyPolicyUrl": asc_read.text(app_info, "privacyPolicyUrl"),
                "supportUrl": asc_read.text(localization[1], "supportUrl"),
                "whatsNew": asc_read.text(localization[1], "whatsNew"),
            },
            "screenshots": self._screenshots(localization[0]),
            "inAppPurchases": self._in_app_purchases(),
            "appReview": self._app_review_detail(version_id),
        }

    def _version_localization(self, version_id: str) -> tuple[str, Mapping[str, Any]]:
        items, _ = self._session.collection(
            f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations",
            {
                "fields[appStoreVersionLocalizations]": "locale,description,keywords,promotionalText,whatsNew,supportUrl",
                "limit": "50",
            },
        )
        matching = [
            item
            for item in items
            if asc_read.attributes(item).get("locale") == REVIEWED_LOCALE
        ]
        if len(matching) != 1:
            raise asc_read.AppStoreConnectError(
                f"the {REVIEWED_LOCALE} version localization is absent or ambiguous"
            )
        return matching[0]["id"], asc_read.attributes(matching[0])

    def _app_info_localization(self) -> Mapping[str, Any]:
        """App Store Connect keeps a live and an editable app info; both must agree."""
        infos, _ = self._session.collection(
            f"/v1/apps/{core.APP_ID}/appInfos", {"fields[appInfos]": "state", "limit": "20"}
        )
        found: list[Mapping[str, Any]] = []
        for info in infos:
            items, _ = self._session.collection(
                f"/v1/appInfos/{info['id']}/appInfoLocalizations",
                {
                    "fields[appInfoLocalizations]": "locale,name,subtitle,privacyPolicyUrl",
                    "limit": "50",
                },
            )
            for item in items:
                localization = asc_read.attributes(item)
                if localization.get("locale") == REVIEWED_LOCALE:
                    found.append(
                        {
                            "name": asc_read.text(localization, "name"),
                            "subtitle": asc_read.text(localization, "subtitle"),
                            "privacyPolicyUrl": asc_read.text(
                                localization, "privacyPolicyUrl"
                            ),
                        }
                    )
        if not found:
            raise asc_read.AppStoreConnectError(
                f"the {REVIEWED_LOCALE} app info localization is absent"
            )
        if any(entry != found[0] for entry in found[1:]):
            raise asc_read.AppStoreConnectError(
                "the live and editable app info localizations disagree"
            )
        return found[0]

    def _screenshots(self, localization_id: str) -> list[Mapping[str, Any]]:
        sets, included = self._session.collection(
            f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
            {
                "fields[appScreenshotSets]": "screenshotDisplayType,appScreenshots",
                "fields[appScreenshots]": "fileName,fileSize,sourceFileChecksum,assetDeliveryState",
                "include": "appScreenshots",
                "limit": "50",
            },
        )
        assets = {
            item["id"]: asc_read.attributes(item)
            for item in included
            if item.get("type") == "appScreenshots"
        }
        collected: list[Mapping[str, Any]] = []
        for entry in sets:
            slot = asc_read.text(asc_read.attributes(entry), "screenshotDisplayType")
            files = [
                self._reviewed_asset(assets, identifier, f"screenshot {slot}")
                for identifier in _ordered_linkage(entry, "appScreenshots", "appScreenshots")
            ]
            collected.append({"slot": slot, "files": files})
        return collected

    def _in_app_purchases(self) -> list[Mapping[str, Any]]:
        groups, included = self._session.collection(
            f"/v1/apps/{core.APP_ID}/subscriptionGroups",
            {
                "fields[subscriptionGroups]": "subscriptions",
                "fields[subscriptions]": "productId,state,reviewNote",
                "include": "subscriptions",
                "limit": "50",
            },
        )
        del groups
        subscriptions = {
            asc_read.text(asc_read.attributes(item), "productId"): item
            for item in included
            if item.get("type") == "subscriptions"
        }
        collected: list[Mapping[str, Any]] = []
        for product_id in core.CLOUD_PRODUCT_IDS:
            subscription = subscriptions.get(product_id)
            if subscription is None:
                raise asc_read.AppStoreConnectError(
                    "an approved Cloud subscription is absent from App Store Connect"
                )
            screenshot = self._session.optional_single(
                f"/v1/subscriptions/{subscription['id']}/appStoreReviewScreenshot",
                {
                    "fields[subscriptionAppStoreReviewScreenshots]": "fileName,fileSize,sourceFileChecksum,assetDeliveryState"
                },
            )
            if screenshot is None:
                raise asc_read.AppStoreConnectError(
                    "a Cloud subscription has no App Review screenshot"
                )
            collected.append(
                {
                    "productId": product_id,
                    "reviewNotes": asc_read.text(
                        asc_read.attributes(subscription), "reviewNote"
                    ),
                    "reviewScreenshot": self._match_asset(
                        asc_read.attributes(screenshot),
                        f"in-app purchase {product_id}",
                        allow_source_filename=True,
                    ),
                }
            )
        return collected

    def _app_review_detail(self, version_id: str) -> Mapping[str, Any]:
        detail = self._session.optional_single(
            f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail",
            {"fields[appStoreReviewDetails]": "notes,demoAccountRequired"},
        )
        if detail is None:
            raise asc_read.AppStoreConnectError(
                "the candidate has no App Review detail; the captain must complete it"
            )
        found = asc_read.attributes(detail)
        return {
            "notes": asc_read.text(found, "notes"),
            "demoAccountRequired": found.get("demoAccountRequired"),
            "identity": core.REVIEWER_IDENTITY,
            "parentPin": core.REVIEWER_PARENT_PIN,
            "cloudPurchase": core.REVIEWER_CLOUD_PURCHASE,
        }

    # -- asset identity -----------------------------------------------------

    def _reviewed_asset(
        self, assets: Mapping[str, Mapping[str, Any]], identifier: str, label: str
    ) -> Mapping[str, Any]:
        found = assets.get(identifier)
        if found is None:
            raise asc_read.AppStoreConnectError(
                f"App Store Connect omitted an included {label} asset"
            )
        return self._match_asset(found, label)

    def _match_asset(
        self,
        asset: Mapping[str, Any],
        label: str,
        *,
        allow_source_filename: bool = False,
    ) -> Mapping[str, Any]:
        """Map one uploaded Apple asset back to the exact approved local file.

        Identity is proven by Apple's own file name, byte size, and MD5 source
        checksum against the same local file the manifest hashed. A subscription
        App Review screenshot is the one exception: Apple reports its file name
        as `SOURCE_FILENAME_SENTINEL` rather than the real uploaded name, so when
        `allow_source_filename` is set and the name is exactly that sentinel the
        name predicate is dropped and the asset binds on byte size and MD5 alone.
        Exactly one approved file must still match either way.
        """
        delivery = asset.get("assetDeliveryState")
        state = delivery.get("state") if isinstance(delivery, dict) else None
        if state != ASSET_COMPLETE:
            raise asc_read.AppStoreConnectError(
                f"an uploaded {label} asset is not fully delivered"
            )
        name = asc_read.text(asset, "fileName")
        size = asset.get("fileSize")
        checksum = asc_read.text(asset, "sourceFileChecksum")
        match_by_source = allow_source_filename and name == SOURCE_FILENAME_SENTINEL
        matches = [
            (path, verified)
            for path, verified in self._verified_files.items()
            if (match_by_source or verified["name"] == name)
            and verified["bytes"] == size
            and verified["md5"] == checksum
        ]
        if len(matches) != 1:
            raise asc_read.AppStoreConnectError(
                f"an uploaded {label} asset does not match exactly one approved file"
            )
        path, verified = matches[0]
        return {"path": path, "bytes": verified["bytes"], "sha256": verified["sha256"]}


def _ordered_linkage(
    value: Mapping[str, Any], name: str, expected_type: str
) -> list[str]:
    relationships = value.get("relationships")
    entry = relationships.get(name) if isinstance(relationships, dict) else None
    data = entry.get("data") if isinstance(entry, dict) else None
    if not isinstance(data, list):
        raise asc_read.AppStoreConnectError(
            "App Store Connect returned a malformed relationship collection"
        )
    identifiers = []
    for item in data:
        if not isinstance(item, dict) or item.get("type") != expected_type:
            raise asc_read.AppStoreConnectError(
                "App Store Connect returned a malformed relationship collection"
            )
        identifier = item.get("id")
        if not isinstance(identifier, str):
            raise asc_read.AppStoreConnectError(
                "App Store Connect returned a malformed relationship collection"
            )
        identifiers.append(identifier)
    return identifiers
