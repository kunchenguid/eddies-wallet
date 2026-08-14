#!/usr/bin/env python3
"""Fake-boundary tests for the App Review workflow layer.

Nothing here uses a real credential, network endpoint, or App Store Connect
resource. A fake App Store Connect models the resources the pipeline reads and
writes, so idempotency, the refusal paths, and the post-acceptance monitor
handoff are exercised as behavior rather than asserted from source text.
"""

from __future__ import annotations

import contextlib
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest
import unittest.mock

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools" / "app-review"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, TOOLS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


core = load("core")
asc_read = load("asc_read")
content = load("content")
evidence = load("evidence")
github_api = load("github_api")
runtime = load("runtime")
asc_write = load("asc_write")
submission = load("submission")

APP_ID = core.APP_ID
LISTING = {
    "appName": "Eddie's Wallet",
    "subtitle": "A kid's own money, in one place",
    "promotionalText": "Cloud backup is optional.",
    "description": "Eddie's Wallet keeps a kid's money clear and their own.",
    "keywords": "allowance,kids,money",
    "privacyPolicyUrl": "https://eddieswallet.kunchenguid.com/privacy",
    "supportUrl": "https://eddieswallet.kunchenguid.com/support",
    "whatsNew": "Cloud backup and sync is now optional for parents.",
}
SCREENSHOT_SLOT = "APP_IPHONE_67"
NOW = datetime(2026, 8, 10, 12, 0, 0, tzinfo=timezone.utc)


def utc(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


class Fixture:
    """One approved candidate: real reviewed bytes plus its captain manifest."""

    def __init__(self, root: pathlib.Path):
        self.root = root
        self.files = {
            "docs/app-store/screenshots/iphone-67/01-wallet.png": b"kid wallet png bytes",
            "docs/app-store/screenshots/iphone-67/02-parent.png": b"parent area png bytes",
            "docs/app-store/iap/cloud-monthly.png": b"cloud monthly review png",
            "docs/app-store/iap/cloud-annual.png": b"cloud annual review png",
        }
        for relative, data in self.files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

        self.content = core.materialize_source_content(
            root,
            LISTING,
            [
                {
                    "slot": SCREENSHOT_SLOT,
                    "files": [
                        "docs/app-store/screenshots/iphone-67/01-wallet.png",
                        "docs/app-store/screenshots/iphone-67/02-parent.png",
                    ],
                }
            ],
            [
                {
                    "productId": core.CLOUD_PRODUCT_IDS[0],
                    "reviewNotes": "Parent > Cloud backup & sync > Cloud monthly.",
                    "screenshotPath": "docs/app-store/iap/cloud-monthly.png",
                },
                {
                    "productId": core.CLOUD_PRODUCT_IDS[1],
                    "reviewNotes": "Parent > Cloud backup & sync > Cloud annual.",
                    "screenshotPath": "docs/app-store/iap/cloud-annual.png",
                },
            ],
            "Sign in with Apple with your own Apple Account, then set any PIN.",
        )
        self.candidate = {
            "version": "0.2.0",
            "build": "41.1",
            "baselineVersion": "0.1.13",
            "sourceCommit": "a" * 40,
            "releaseType": "MANUAL",
        }
        self.manifest = core.build_manifest(
            self.candidate,
            self.content,
            approved_utc=utc(NOW - timedelta(days=1)),
            approval_statement="Captain approved Eddie's Wallet 0.2.0 for App Review.",
        )
        self.approved_commit = "b" * 40
        manifest_path = root / runtime.MANIFEST_DIRECTORY / "0.2.0.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(self.manifest, indent=2), encoding="utf-8")
        self.verified = content.verify_manifest_files(self.manifest, root)


def descriptor_asset(fixture: Fixture, path: str) -> dict:
    data = fixture.files[path]
    return {
        "fileName": pathlib.PurePosixPath(path).name,
        "fileSize": len(data),
        "sourceFileChecksum": hashlib.md5(data).hexdigest(),
        "assetDeliveryState": {"state": "COMPLETE"},
    }


class FakeAppStoreConnect:
    """A small App Store Connect the pipeline can genuinely be driven against."""

    def __init__(self, fixture: Fixture, **overrides):
        self.fixture = fixture
        self.writes: list[str] = []
        self.reads: list[str] = []
        approved = fixture.content
        self.version = {
            "id": "ver-1",
            "versionString": fixture.candidate["version"],
            "appVersionState": overrides.get("state", "PREPARE_FOR_SUBMISSION"),
            "platform": "IOS",
            "releaseType": overrides.get("releaseType", "MANUAL"),
            "buildId": overrides.get("buildId", "build-1"),
        }
        self.builds = {
            "build-1": {"version": "41.1", "expired": False, "processingState": "VALID"},
            "build-old": {"version": "40.1", "expired": False, "processingState": "VALID"},
        }
        self.review_detail = {
            "id": "detail-1",
            "notes": approved["appReview"]["notes"],
            "demoAccountRequired": False,
        }
        self.version_localizations = [
            {
                "id": "loc-1",
                "locale": "en-US",
                "description": LISTING["description"],
                "keywords": LISTING["keywords"],
                "promotionalText": LISTING["promotionalText"],
                "whatsNew": LISTING["whatsNew"],
                "supportUrl": LISTING["supportUrl"],
            }
        ]
        self.app_infos = {
            "info-1": [
                {
                    "id": "infoloc-1",
                    "locale": "en-US",
                    "name": LISTING["appName"],
                    "subtitle": LISTING["subtitle"],
                    "privacyPolicyUrl": LISTING["privacyPolicyUrl"],
                }
            ]
        }
        self.screenshot_sets = [
            {
                "id": "set-1",
                "screenshotDisplayType": SCREENSHOT_SLOT,
                "screenshots": [
                    dict(
                        descriptor_asset(fixture, path),
                        id=f"shot-{index}",
                    )
                    for index, path in enumerate(
                        (
                            "docs/app-store/screenshots/iphone-67/01-wallet.png",
                            "docs/app-store/screenshots/iphone-67/02-parent.png",
                        )
                    )
                ],
            }
        ]
        self.subscriptions = {
            core.CLOUD_PRODUCT_IDS[0]: {
                "id": "sub-monthly",
                "state": overrides.get("subscriptionState", "READY_TO_SUBMIT"),
                "reviewNote": approved["inAppPurchases"][0]["reviewNotes"],
                "screenshot": dict(
                    descriptor_asset(fixture, "docs/app-store/iap/cloud-monthly.png"),
                    id="iapshot-1",
                ),
            },
            core.CLOUD_PRODUCT_IDS[1]: {
                "id": "sub-annual",
                "state": overrides.get("subscriptionState", "READY_TO_SUBMIT"),
                "reviewNote": approved["inAppPurchases"][1]["reviewNotes"],
                "screenshot": dict(
                    descriptor_asset(fixture, "docs/app-store/iap/cloud-annual.png"),
                    id="iapshot-2",
                ),
            },
        }
        self.review_submissions: dict[str, dict] = dict(
            overrides.get("reviewSubmissions", {})
        )
        self._next = 0

    # -- read boundary ------------------------------------------------------

    def get(self, path, query):
        self.reads.append(path)
        if path == f"/v1/apps/{APP_ID}":
            return {"data": _res("apps", APP_ID, {"bundleId": core.BUNDLE_ID})}
        if path == f"/v1/appStoreVersions/{self.version['id']}":
            return {"data": self._version_resource()}
        match = re.fullmatch(r"/v1/reviewSubmissions/([^/]+)", path)
        if match:
            submission_state = self.review_submissions[match.group(1)]
            return {
                "data": _res(
                    "reviewSubmissions",
                    match.group(1),
                    {"state": submission_state["state"], "platform": "IOS"},
                )
            }
        raise AssertionError(f"unexpected GET {path}")

    def optional_single(self, path, query):
        self.reads.append(path)
        if path == f"/v1/appStoreVersions/{self.version['id']}/build":
            build_id = self.version["buildId"]
            if build_id is None:
                return None
            return _res("builds", build_id, dict(self.builds[build_id]))
        if path == f"/v1/appStoreVersions/{self.version['id']}/appStoreReviewDetail":
            if self.review_detail is None:
                return None
            return _res(
                "appStoreReviewDetails",
                self.review_detail["id"],
                {
                    "notes": self.review_detail["notes"],
                    "demoAccountRequired": self.review_detail["demoAccountRequired"],
                },
            )
        match = re.fullmatch(r"/v1/subscriptions/([^/]+)/appStoreReviewScreenshot", path)
        if match:
            for subscription in self.subscriptions.values():
                if subscription["id"] == match.group(1):
                    shot = dict(subscription["screenshot"])
                    return _res(
                        "subscriptionAppStoreReviewScreenshots", shot.pop("id"), shot
                    )
            return None
        raise AssertionError(f"unexpected optional GET {path}")

    def collection(self, path, query):
        self.reads.append(path)
        if path == f"/v1/apps/{APP_ID}/appStoreVersions":
            wanted = query.get("filter[versionString]")
            if wanted != self.version["versionString"]:
                return [], []
            included = []
            if "include" in query and self.version["buildId"]:
                included.append(
                    _res(
                        "builds",
                        self.version["buildId"],
                        dict(self.builds[self.version["buildId"]]),
                    )
                )
            return [self._version_resource()], included
        if path == "/v1/builds":
            wanted = query.get("filter[version]")
            return (
                [
                    _res("builds", identifier, dict(attributes))
                    for identifier, attributes in self.builds.items()
                    if attributes["version"] == wanted
                ],
                [],
            )
        if path == f"/v1/appStoreVersions/{self.version['id']}/appStoreVersionLocalizations":
            return (
                [
                    _res("appStoreVersionLocalizations", entry["id"], _without_id(entry))
                    for entry in self.version_localizations
                ],
                [],
            )
        if path == f"/v1/apps/{APP_ID}/appInfos":
            return (
                [_res("appInfos", identifier, {"state": "READY_FOR_DISTRIBUTION"}) for identifier in self.app_infos],
                [],
            )
        match = re.fullmatch(r"/v1/appInfos/([^/]+)/appInfoLocalizations", path)
        if match:
            return (
                [
                    _res("appInfoLocalizations", entry["id"], _without_id(entry))
                    for entry in self.app_infos[match.group(1)]
                ],
                [],
            )
        match = re.fullmatch(
            r"/v1/appStoreVersionLocalizations/([^/]+)/appScreenshotSets", path
        )
        if match:
            sets, included = [], []
            for entry in self.screenshot_sets:
                sets.append(
                    {
                        "type": "appScreenshotSets",
                        "id": entry["id"],
                        "attributes": {
                            "screenshotDisplayType": entry["screenshotDisplayType"]
                        },
                        "relationships": {
                            "appScreenshots": {
                                "data": [
                                    {"type": "appScreenshots", "id": shot["id"]}
                                    for shot in entry["screenshots"]
                                ]
                            }
                        },
                    }
                )
                for shot in entry["screenshots"]:
                    payload = dict(shot)
                    included.append(
                        _res("appScreenshots", payload.pop("id"), payload)
                    )
            return sets, included
        if path == f"/v1/apps/{APP_ID}/subscriptionGroups":
            included = [
                _res(
                    "subscriptions",
                    subscription["id"],
                    {
                        "productId": product_id,
                        "state": subscription["state"],
                        "reviewNote": subscription["reviewNote"],
                    },
                )
                for product_id, subscription in self.subscriptions.items()
            ]
            return [_res("subscriptionGroups", "group-1", {})], included
        if path == f"/v1/apps/{APP_ID}/reviewSubmissions":
            # SSHHIP-aligned: the engine reads the app-scoped relationship
            # collection with no `filter[state]` and narrows to the open states
            # client-side, so this returns every review submission regardless of
            # state.
            return (
                [
                    _res(
                        "reviewSubmissions",
                        identifier,
                        {"state": entry["state"], "platform": "IOS"},
                    )
                    for identifier, entry in self.review_submissions.items()
                ],
                [],
            )
        match = re.fullmatch(r"/v1/reviewSubmissions/([^/]+)/items", path)
        if match:
            return (
                [
                    {
                        "type": "reviewSubmissionItems",
                        "id": item["id"],
                        "attributes": {"state": "READY_FOR_REVIEW"},
                        "relationships": {
                            name: {"data": {"type": kind, "id": item[name]}}
                            for name, kind in (
                                ("appStoreVersion", "appStoreVersions"),
                                ("subscription", "subscriptions"),
                            )
                            if item.get(name)
                        },
                    }
                    for item in self.review_submissions[match.group(1)]["items"]
                ],
                [],
            )
        raise AssertionError(f"unexpected collection {path}")

    def _version_resource(self):
        return {
            "type": "appStoreVersions",
            "id": self.version["id"],
            "attributes": {
                "versionString": self.version["versionString"],
                "appVersionState": self.version["appVersionState"],
                "platform": self.version["platform"],
                "releaseType": self.version["releaseType"],
            },
            "relationships": {
                "build": {
                    "data": (
                        {"type": "builds", "id": self.version["buildId"]}
                        if self.version["buildId"]
                        else None
                    )
                }
            },
        }

    # -- change boundary ----------------------------------------------------

    def set_release_type(self, version_id, release_type):
        self.writes.append("PATCH releaseType")
        self.version["releaseType"] = release_type

    def bind_build(self, version_id, build_id):
        self.writes.append("PATCH build")
        self.version["buildId"] = build_id

    def set_review_detail(self, detail_id, notes):
        self.writes.append("PATCH reviewDetail")
        self.review_detail = {
            "id": detail_id,
            "notes": notes,
            "demoAccountRequired": False,
        }

    def create_review_submission(self, app_id, platform):
        self.writes.append("POST reviewSubmission")
        self._next += 1
        identifier = f"rs-{self._next}"
        self.review_submissions[identifier] = {
            "state": "READY_FOR_REVIEW",
            "items": [],
        }
        return identifier

    def add_version_item(self, submission_id, version_id):
        self.writes.append("POST versionItem")
        self._next += 1
        self.review_submissions[submission_id]["items"].append(
            {"id": f"item-{self._next}", "appStoreVersion": version_id}
        )
        return f"item-{self._next}"

    def add_subscription_item(self, submission_id, subscription_id):
        self.writes.append("POST subscriptionItem")
        self._next += 1
        self.review_submissions[submission_id]["items"].append(
            {"id": f"item-{self._next}", "subscription": subscription_id}
        )
        return f"item-{self._next}"

    def submit_for_review(self, submission_id):
        self.writes.append("PATCH submitted")
        self.review_submissions[submission_id]["state"] = "WAITING_FOR_REVIEW"
        self.version["appVersionState"] = "WAITING_FOR_REVIEW"


def _res(kind, identifier, attributes):
    return {"type": kind, "id": identifier, "attributes": attributes}


def _without_id(entry):
    return {key: value for key, value in entry.items() if key != "id"}


# Apple's documented valid `fields[<type>]` sparse-fieldset values for the App
# Store Connect resource types the SUBMIT path reads, transcribed from Apple's
# App Store Connect OpenAPI specification. A `fields[<type>]` carrying anything
# outside its set makes App Store Connect reject the whole read with HTTP 400
# (PARAMETER_ERROR.INVALID, "'<name>' is not a valid field name") - the exact
# failure that blocked the submit twice: first `fields[reviewSubmissions]=...,
# submitted` (`submitted` invalid), then `fields[reviewSubmissionItems]=...,
# subscription` (`subscription` is not a reviewSubmissionItems field). Note that
# `submitted`/`subscription` are deliberately ABSENT from these sets.
VALID_SUBMIT_FIELDS = {
    "appStoreVersions": frozenset({
        "platform", "versionString", "appStoreState", "appVersionState",
        "copyright", "reviewType", "releaseType", "earliestReleaseDate",
        "usesIdfa", "downloadable", "createdDate", "app",
        "appStoreVersionLocalizations", "build", "appStoreVersionPhasedRelease",
        "gameCenterAppVersion", "routingAppCoverage", "appStoreReviewDetail",
        "appStoreVersionSubmission", "appClipDefaultExperience",
        "appStoreVersionExperiments", "appStoreVersionExperimentsV2",
        "customerReviews", "alternativeDistributionPackage",
    }),
    "builds": frozenset({
        "version", "uploadedDate", "expirationDate", "expired", "minOsVersion",
        "lsMinimumSystemVersion", "computedMinMacOsVersion",
        "computedMinVisionOsVersion", "iconAssetToken", "processingState",
        "buildAudienceType", "usesNonExemptEncryption", "preReleaseVersion",
        "individualTesters", "betaGroups", "betaBuildLocalizations",
        "appEncryptionDeclaration", "betaAppReviewSubmission", "app",
        "buildBetaDetail", "appStoreVersion", "icons", "buildBundles",
        "buildUpload", "perfPowerMetrics", "diagnosticSignatures",
    }),
    "appStoreReviewDetails": frozenset({
        "contactFirstName", "contactLastName", "contactPhone", "contactEmail",
        "demoAccountName", "demoAccountPassword", "demoAccountRequired", "notes",
        "appStoreVersion", "appStoreReviewAttachments",
    }),
    "reviewSubmissions": frozenset({
        "platform", "submittedDate", "state", "app", "items",
        "appStoreVersionForReview", "submittedByActor", "lastUpdatedByActor",
    }),
    "reviewSubmissionItems": frozenset({
        "state", "appStoreVersion", "appCustomProductPageVersion",
        "appStoreVersionExperiment", "appStoreVersionExperimentV2", "appEvent",
        "backgroundAssetVersion", "gameCenterAchievementVersion",
        "gameCenterActivityVersion", "gameCenterChallengeVersion",
        "gameCenterLeaderboardSetVersion", "gameCenterLeaderboardVersion",
    }),
    "subscriptionGroups": frozenset({
        "referenceName", "subscriptions", "subscriptionGroupLocalizations",
    }),
    "subscriptions": frozenset({
        "name", "productId", "familySharable", "state", "subscriptionPeriod",
        "reviewNote", "groupLevel", "subscriptionLocalizations",
        "appStoreReviewScreenshot", "group", "introductoryOffers",
        "promotionalOffers", "offerCodes", "prices", "pricePoints",
        "promotedPurchase", "subscriptionAvailability", "winBackOffers",
        "images", "planAvailabilities",
    }),
    "apps": frozenset({"bundleId", "name", "sku", "primaryLocale"}),
}

SUBMIT_ENDPOINT_FIELDS = {
    f"/v1/apps/{APP_ID}/appStoreVersions": frozenset({"appStoreVersions", "builds"}),
    "/v1/builds": frozenset({"builds"}),
    "/v1/appStoreVersions/{id}/build": frozenset({"builds"}),
    "/v1/appStoreVersions/{id}/appStoreReviewDetail": frozenset({"appStoreReviewDetails"}),
    f"/v1/apps/{APP_ID}/reviewSubmissions": frozenset({"reviewSubmissions"}),
    "/v1/reviewSubmissions/{id}/items": frozenset({
        "reviewSubmissionItems", "appStoreVersions",
    }),
    f"/v1/apps/{APP_ID}/subscriptionGroups": frozenset({
        "subscriptionGroups", "subscriptions",
    }),
    "/v1/reviewSubmissions/{id}": frozenset({"reviewSubmissions"}),
    "/v1/appStoreVersions/{id}": frozenset({"appStoreVersions"}),
}

VALID_SUBMIT_FILTERS = {
    endpoint: frozenset() for endpoint in SUBMIT_ENDPOINT_FIELDS
}
VALID_SUBMIT_FILTERS.update({
    f"/v1/apps/{APP_ID}/appStoreVersions": frozenset({
        "filter[versionString]", "filter[platform]", "filter[appStoreState]",
        "filter[appVersionState]", "filter[id]",
    }),
    "/v1/builds": frozenset({
        "filter[app]", "filter[version]", "filter[preReleaseVersion.version]",
        "filter[preReleaseVersion]", "filter[preReleaseVersion.platform]",
        "filter[appStoreVersion]", "filter[betaGroups]",
        "filter[buildAudienceType]", "filter[expired]", "filter[id]",
        "filter[processingState]", "filter[usesNonExemptEncryption]",
        "filter[betaAppReviewSubmission.betaReviewState]",
    }),
    f"/v1/apps/{APP_ID}/reviewSubmissions": frozenset({
        "filter[platform]", "filter[state]",
    }),
    f"/v1/apps/{APP_ID}/subscriptionGroups": frozenset({
        "filter[referenceName]", "filter[subscriptions.state]",
    }),
})

VALID_SUBMIT_INCLUDES = {
    endpoint: frozenset() for endpoint in SUBMIT_ENDPOINT_FIELDS
}
VALID_SUBMIT_INCLUDES.update({
    f"/v1/apps/{APP_ID}/appStoreVersions": frozenset({"build"}),
    "/v1/reviewSubmissions/{id}/items": frozenset({
        "appStoreVersion", "appCustomProductPageVersion",
        "appStoreVersionExperiment", "appStoreVersionExperimentV2", "appEvent",
        "backgroundAssetVersion", "gameCenterAchievementVersion",
        "gameCenterActivityVersion", "gameCenterChallengeVersion",
        "gameCenterLeaderboardSetVersion", "gameCenterLeaderboardVersion",
    }),
    f"/v1/apps/{APP_ID}/subscriptionGroups": frozenset({
        "subscriptions", "subscriptionGroupLocalizations",
    }),
})


def _submit_endpoint_key(path):
    patterns = (
        (r"/v1/reviewSubmissions/[^/]+/items", "/v1/reviewSubmissions/{id}/items"),
        (r"/v1/reviewSubmissions/[^/]+", "/v1/reviewSubmissions/{id}"),
        (r"/v1/appStoreVersions/[^/]+/build", "/v1/appStoreVersions/{id}/build"),
        (
            r"/v1/appStoreVersions/[^/]+/appStoreReviewDetail",
            "/v1/appStoreVersions/{id}/appStoreReviewDetail",
        ),
        (r"/v1/appStoreVersions/[^/]+", "/v1/appStoreVersions/{id}"),
    )
    for pattern, endpoint in patterns:
        if re.fullmatch(pattern, path):
            return endpoint
    return path


class FieldValidatingAppStoreConnect(FakeAppStoreConnect):
    """Reject invalid query parameters on every submit-path read endpoint."""

    def _guard(self, path, query):
        endpoint = _submit_endpoint_key(path)
        allowed_field_types = SUBMIT_ENDPOINT_FIELDS.get(endpoint)
        if allowed_field_types is None:
            return
        for key, value in query.items():
            if key.startswith("fields[") and key.endswith("]"):
                resource_type = key[len("fields["):-1]
                if resource_type not in allowed_field_types:
                    self._reject_400()
                valid = VALID_SUBMIT_FIELDS[resource_type]
                if {field for field in value.split(",") if field} - valid:
                    self._reject_400()
            if key.startswith("filter[") and key not in VALID_SUBMIT_FILTERS[endpoint]:
                self._reject_400()
        if "include" in query:
            requested = {value for value in query["include"].split(",") if value}
            if requested - VALID_SUBMIT_INCLUDES[endpoint]:
                self._reject_400()

    @staticmethod
    def _reject_400():
        raise asc_read.AppStoreConnectError(
            "App Store Connect read request failed with status 400"
        )

    def get(self, path, query):
        self._guard(path, query)
        return super().get(path, query)

    def optional_single(self, path, query):
        self._guard(path, query)
        return super().optional_single(path, query)

    def collection(self, path, query):
        self._guard(path, query)
        return super().collection(path, query)


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)
        self.root = pathlib.Path(self._directory.name)
        self.fixture = Fixture(self.root)


class DispatchGateTests(FixtureCase):
    """The gate is the manifest plus a double-confirm dispatch, and nothing else."""

    def dispatch(self, **overrides):
        environment = {
            "GITHUB_REPOSITORY": core.REPOSITORY,
            "GITHUB_REF": core.DEFAULT_BRANCH_REF,
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_ACTOR": core.CAPTAIN_GITHUB_LOGIN,
            "EDDIES_APP_REVIEW_VERSION": "0.2.0",
            "EDDIES_APP_REVIEW_CONFIRM": "0.2.0",
            "EDDIES_APP_REVIEW_APPROVED_COMMIT": self.fixture.approved_commit,
        }
        environment.update(overrides)
        return unittest.mock.patch.dict(os.environ, environment, clear=True)

    def test_a_matching_double_confirm_passes_the_gate(self):
        with self.dispatch():
            self.assertEqual(runtime.confirmed_version(), "0.2.0")
            runtime.trusted_context(captain_only=True)
            self.assertEqual(runtime.approved_commit(), self.fixture.approved_commit)

    def test_a_mismatched_confirmation_refuses(self):
        with self.dispatch(EDDIES_APP_REVIEW_CONFIRM="0.2.1"):
            with self.assertRaises(runtime.GateError) as caught:
                runtime.confirmed_version()
        self.assertIn("repeat the dispatched version", str(caught.exception))

    def test_an_empty_or_malformed_version_refuses(self):
        for value in ("", "latest", "0", "0.2.0 ; rm -rf /", "../../etc/passwd"):
            with self.subTest(value=value), self.dispatch(
                EDDIES_APP_REVIEW_VERSION=value, EDDIES_APP_REVIEW_CONFIRM=value
            ):
                with self.assertRaises(runtime.GateError):
                    runtime.confirmed_version()

    def test_a_fork_a_branch_or_a_push_can_never_dispatch(self):
        for override in (
            {"GITHUB_REPOSITORY": "someone/eddies-wallet"},
            {"GITHUB_REF": "refs/heads/feature"},
            {"GITHUB_EVENT_NAME": "push"},
        ):
            with self.subTest(override=override), self.dispatch(**override):
                with self.assertRaises(core.AppReviewError):
                    runtime.trusted_context()

    def test_only_the_captain_may_reach_the_submission_lane(self):
        with self.dispatch(GITHUB_ACTOR="helpful-contributor"):
            runtime.trusted_context()
            with self.assertRaises(core.AppReviewError):
                runtime.trusted_context(captain_only=True)

    def test_a_version_without_an_approved_manifest_refuses(self):
        with self.assertRaises(runtime.GateError) as caught:
            runtime.load_manifest("0.9.9", self.root)
        self.assertIn("no captain-approved manifest", str(caught.exception))

    def test_a_manifest_that_pins_another_version_refuses(self):
        stray = self.root / runtime.MANIFEST_DIRECTORY / "0.3.0.json"
        stray.write_text(json.dumps(self.fixture.manifest), encoding="utf-8")
        with self.assertRaises(runtime.GateError) as caught:
            runtime.load_manifest("0.3.0", self.root)
        self.assertIn("pins a different version", str(caught.exception))

    def test_an_edited_manifest_field_invalidates_the_manifest(self):
        tampered = copy.deepcopy(self.fixture.manifest)
        tampered["content"]["listing"]["description"] = "Now with a hidden change."
        path = self.root / runtime.MANIFEST_DIRECTORY / "0.2.0.json"
        path.write_text(json.dumps(tampered), encoding="utf-8")
        with self.assertRaises(core.AppReviewError):
            runtime.load_manifest("0.2.0", self.root)


class ReviewedByteBindingTests(FixtureCase):
    def test_approved_bytes_are_recomputed_not_trusted(self):
        verified = content.verify_manifest_files(self.fixture.manifest, self.root)
        self.assertEqual(len(verified), 4)
        for path, entry in verified.items():
            self.assertEqual(
                entry["sha256"], hashlib.sha256(self.fixture.files[path]).hexdigest()
            )
            self.assertEqual(
                entry["md5"], hashlib.md5(self.fixture.files[path]).hexdigest()
            )

    def test_a_screenshot_edited_after_approval_refuses(self):
        target = self.root / "docs/app-store/screenshots/iphone-67/01-wallet.png"
        target.write_bytes(b"kid wallet png byte!")  # same length, different bytes
        with self.assertRaises(content.ContentError) as caught:
            content.verify_manifest_files(self.fixture.manifest, self.root)
        self.assertIn("changed content since approval", str(caught.exception))

    def test_a_missing_reviewed_file_refuses(self):
        (self.root / "docs/app-store/iap/cloud-annual.png").unlink()
        with self.assertRaises(content.ContentError):
            content.verify_manifest_files(self.fixture.manifest, self.root)


class LiveReconciliationTests(FixtureCase):
    def client(self, fake):
        return core.ReadOnlyASCClient(
            content.CandidateReadTransport(
                fake, self.fixture.candidate, self.fixture.verified
            )
        )

    def test_matching_live_state_reconciles_as_a_submittable_draft(self):
        fake = FakeAppStoreConnect(self.fixture)
        outcome = core.reconcile_authoritatively(
            self.fixture.manifest, self.client(fake)
        )
        self.assertEqual(outcome.outcome, "matching_draft")
        self.assertEqual(fake.writes, [])

    def test_listing_copy_that_drifted_on_apple_refuses(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.version_localizations[0]["whatsNew"] = "Something the captain never saw."
        with self.assertRaises(core.AppReviewError) as caught:
            core.reconcile_authoritatively(self.fixture.manifest, self.client(fake))
        self.assertEqual(caught.exception.code, "E_RECONCILIATION")

    def test_a_screenshot_apple_holds_that_is_not_the_approved_file_refuses(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.screenshot_sets[0]["screenshots"][0]["sourceFileChecksum"] = "0" * 32
        with self.assertRaises(core.AppReviewError) as caught:
            core.reconcile_authoritatively(self.fixture.manifest, self.client(fake))
        self.assertEqual(caught.exception.code, "E_ASC_READ")
        self.assertIn("does not match exactly one approved file", str(caught.exception))

    def test_an_undelivered_review_asset_refuses(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.subscriptions[core.CLOUD_PRODUCT_IDS[0]]["screenshot"][
            "assetDeliveryState"
        ] = {"state": "UPLOAD_COMPLETE"}
        with self.assertRaises(core.AppReviewError) as caught:
            core.reconcile_authoritatively(self.fixture.manifest, self.client(fake))
        self.assertEqual(caught.exception.code, "E_ASC_READ")
        self.assertIn("not fully delivered", str(caught.exception))

    def test_a_demo_account_requirement_on_apple_refuses(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.review_detail["demoAccountRequired"] = True
        with self.assertRaises(core.AppReviewError):
            core.reconcile_authoritatively(self.fixture.manifest, self.client(fake))

    def test_an_absent_candidate_reconciles_as_absent_without_writing(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.version["versionString"] = "0.1.13"
        outcome = core.reconcile_authoritatively(
            self.fixture.manifest, self.client(fake)
        )
        self.assertEqual(outcome.outcome, "absent")
        self.assertEqual(fake.writes, [])


class SubscriptionReviewAssetBindingTests(FixtureCase):
    """`_match_asset` binds a subscription review screenshot Apple names SOURCE.

    App Store Connect reports a subscription App Review screenshot's `fileName`
    as the literal sentinel `SOURCE` rather than the real uploaded name, even
    after a correct re-upload, so the strict name+size+md5 predicate that binds a
    listing screenshot matches zero approved files and the read refuses. These
    tests exercise the observable binding behavior through the real transport.
    """

    IAP_PATH = "docs/app-store/iap/cloud-monthly.png"
    LISTING_PATH = "docs/app-store/screenshots/iphone-67/01-wallet.png"

    def transport(self, verified):
        return content.CandidateReadTransport(None, self.fixture.candidate, verified)

    def client(self, fake):
        return core.ReadOnlyASCClient(
            content.CandidateReadTransport(
                fake, self.fixture.candidate, self.fixture.verified
            )
        )

    @staticmethod
    def asset(name, size, checksum, state="COMPLETE"):
        return {
            "fileName": name,
            "fileSize": size,
            "sourceFileChecksum": checksum,
            "assetDeliveryState": {"state": state},
        }

    def test_a_source_named_iap_asset_binds_by_size_and_checksum(self):
        entry = self.fixture.verified[self.IAP_PATH]
        bound = self.transport(self.fixture.verified)._match_asset(
            self.asset(content.SOURCE_FILENAME_SENTINEL, entry["bytes"], entry["md5"]),
            "in-app purchase com.example.cloud.monthly",
            allow_source_filename=True,
        )
        self.assertEqual(bound["path"], self.IAP_PATH)
        self.assertEqual(bound["sha256"], entry["sha256"])

    def test_a_full_read_binds_source_named_subscription_screenshots(self):
        fake = FakeAppStoreConnect(self.fixture)
        for product_id in core.CLOUD_PRODUCT_IDS:
            screenshot = fake.subscriptions[product_id]["screenshot"]
            screenshot["fileName"] = content.SOURCE_FILENAME_SENTINEL
        outcome = core.reconcile_authoritatively(
            self.fixture.manifest, self.client(fake)
        )
        self.assertEqual(outcome.outcome, "matching_draft")
        self.assertEqual(fake.writes, [])

    def test_a_source_name_is_not_relaxed_without_the_flag(self):
        entry = self.fixture.verified[self.IAP_PATH]
        with self.assertRaises(asc_read.AppStoreConnectError) as caught:
            self.transport(self.fixture.verified)._match_asset(
                self.asset(
                    content.SOURCE_FILENAME_SENTINEL, entry["bytes"], entry["md5"]
                ),
                "screenshot APP_IPHONE_67",
            )
        self.assertIn("does not match exactly one approved file", str(caught.exception))

    def test_a_listing_asset_still_binds_by_name_size_and_checksum(self):
        entry = self.fixture.verified[self.LISTING_PATH]
        bound = self.transport(self.fixture.verified)._match_asset(
            self.asset(entry["name"], entry["bytes"], entry["md5"]),
            "screenshot APP_IPHONE_67",
        )
        self.assertEqual(bound["path"], self.LISTING_PATH)

    def test_a_listing_asset_with_a_wrong_name_still_refuses(self):
        entry = self.fixture.verified[self.LISTING_PATH]
        with self.assertRaises(asc_read.AppStoreConnectError) as caught:
            self.transport(self.fixture.verified)._match_asset(
                self.asset("not-the-approved-name.png", entry["bytes"], entry["md5"]),
                "screenshot APP_IPHONE_67",
            )
        self.assertIn("does not match exactly one approved file", str(caught.exception))

    def test_a_real_iap_name_that_differs_is_not_relaxed(self):
        entry = self.fixture.verified[self.IAP_PATH]
        with self.assertRaises(asc_read.AppStoreConnectError) as caught:
            self.transport(self.fixture.verified)._match_asset(
                self.asset("a-real-but-wrong-name.png", entry["bytes"], entry["md5"]),
                "in-app purchase com.example.cloud.monthly",
                allow_source_filename=True,
            )
        self.assertIn("does not match exactly one approved file", str(caught.exception))

    def test_a_source_asset_matching_more_than_one_file_refuses(self):
        verified = {
            "docs/app-store/iap/one.png": {
                "bytes": 10,
                "sha256": "s1",
                "md5": "sharedmd5",
                "name": "one.png",
            },
            "docs/app-store/iap/two.png": {
                "bytes": 10,
                "sha256": "s2",
                "md5": "sharedmd5",
                "name": "two.png",
            },
        }
        with self.assertRaises(asc_read.AppStoreConnectError) as caught:
            self.transport(verified)._match_asset(
                self.asset(content.SOURCE_FILENAME_SENTINEL, 10, "sharedmd5"),
                "in-app purchase com.example.cloud.monthly",
                allow_source_filename=True,
            )
        self.assertIn("does not match exactly one approved file", str(caught.exception))

    def test_a_source_asset_matching_no_file_refuses(self):
        with self.assertRaises(asc_read.AppStoreConnectError) as caught:
            self.transport(self.fixture.verified)._match_asset(
                self.asset(content.SOURCE_FILENAME_SENTINEL, 999999, "0" * 32),
                "in-app purchase com.example.cloud.monthly",
                allow_source_filename=True,
            )
        self.assertIn("does not match exactly one approved file", str(caught.exception))

    def test_a_source_asset_that_is_undelivered_still_refuses(self):
        entry = self.fixture.verified[self.IAP_PATH]
        with self.assertRaises(asc_read.AppStoreConnectError) as caught:
            self.transport(self.fixture.verified)._match_asset(
                self.asset(
                    content.SOURCE_FILENAME_SENTINEL,
                    entry["bytes"],
                    entry["md5"],
                    state="UPLOAD_COMPLETE",
                ),
                "in-app purchase com.example.cloud.monthly",
                allow_source_filename=True,
            )
        self.assertIn("not fully delivered", str(caught.exception))


class SubmissionEngineTests(FixtureCase):
    def engine(self, fake):
        return submission.SubmissionEngine(
            fake, fake, self.fixture.manifest, self.fixture.verified
        )

    def test_a_clean_candidate_is_submitted_once_and_read_back(self):
        fake = FakeAppStoreConnect(self.fixture)
        outcome = self.engine(fake).run()
        self.assertTrue(outcome.accepted)
        self.assertEqual(outcome.submission_state, "WAITING_FOR_REVIEW")
        self.assertEqual(outcome.version_state, "WAITING_FOR_REVIEW")
        self.assertEqual(
            fake.writes,
            [
                "POST reviewSubmission",
                "POST versionItem",
                "PATCH submitted",
            ],
        )

    def test_every_submit_path_read_uses_only_valid_asc_query_shapes(self):
        # Regression for the two proven submit-path 400s and their whole class:
        # `_open_submissions()` once requested an invalid
        # `fields[reviewSubmissions]=...,submitted`, and `_submission_items()`
        # once requested an invalid `fields[reviewSubmissionItems]=...,
        # subscription`. Drive a full clean submit against a fake that 400s on
        # any `fields[...]`/`filter[...]`/`include` outside Apple's valid set for
        # the resource, exactly as App Store Connect does. Every submit-path read
        # - and the whole run - must succeed, which can only happen if no read
        # names an invalid field/filter/include. This fails if any submit-path
        # query regains one.
        # Start with the wrong build so the conditional `/v1/builds` candidate
        # lookup and its bound-build readback are exercised too. A normally
        # aligned fixture skips that submit-path query entirely.
        fake = FieldValidatingAppStoreConnect(self.fixture, buildId="build-old")
        outcome = self.engine(fake).run()
        self.assertTrue(outcome.accepted)
        exercised_submit_endpoints = {
            endpoint
            for path in fake.reads
            if (endpoint := _submit_endpoint_key(path)) in SUBMIT_ENDPOINT_FIELDS
        }
        self.assertEqual(exercised_submit_endpoints, set(SUBMIT_ENDPOINT_FIELDS))

    def test_resumed_run_reads_existing_submission_items_with_valid_fields(self):
        # The failed real submit already created a review submission, so on the
        # next run `_submission_items()` reads the items of a PRE-EXISTING
        # submission - the exact read that 400'd on the invalid `subscription`
        # field. Seed such a submission and drive the run against the
        # field-validating fake; the items read of the existing submission must
        # return 200 and the run must be accepted.
        fake = FieldValidatingAppStoreConnect(
            self.fixture,
            reviewSubmissions={
                "rs-existing": {
                    "state": "READY_FOR_REVIEW",
                    "items": [{"id": "item-v", "appStoreVersion": "ver-1"}],
                }
            },
        )
        outcome = self.engine(fake).run()
        self.assertTrue(outcome.accepted)
        self.assertIn("/v1/reviewSubmissions/rs-existing/items", fake.reads)

    def test_the_field_validator_rejects_invalid_submit_queries(self):
        fake = FieldValidatingAppStoreConnect(self.fixture)
        invalid_queries = (
            (
                f"/v1/apps/{APP_ID}/reviewSubmissions",
                {"fields[reviewSubmissions]": "state,platform,submitted"},
            ),
            (
                "/v1/reviewSubmissions/rs-existing/items",
                {"fields[reviewSubmissionItems]": "state,appStoreVersion,subscription"},
            ),
            (
                "/v1/builds",
                {"fields[bogus]": "version"},
            ),
            (
                "/v1/reviewSubmissions/rs-existing",
                {"filter[state]": "IN_REVIEW"},
            ),
            (
                "/v1/appStoreVersions/ver-1",
                {"include": "build"},
            ),
        )
        for path, query in invalid_queries:
            with self.subTest(path=path, query=query):
                with self.assertRaises(asc_read.AppStoreConnectError):
                    fake.get(path, query)

    def test_the_field_validator_leaves_content_reads_outside_submit_unchecked(self):
        fake = FieldValidatingAppStoreConnect(self.fixture)
        resources, _ = fake.collection(
            "/v1/appStoreVersions/ver-1/appStoreVersionLocalizations",
            {"fields[bogus]": "anything", "filter[bogus]": "anything", "include": "bogus"},
        )
        self.assertEqual([resource["id"] for resource in resources], ["loc-1"])

    def test_rerunning_an_accepted_submission_writes_nothing(self):
        fake = FakeAppStoreConnect(self.fixture)
        self.engine(fake).run()
        fake.writes.clear()
        outcome = self.engine(fake).run()
        self.assertTrue(outcome.accepted)
        self.assertEqual(outcome.reconciliation, "already_submitted")
        self.assertEqual(fake.writes, [], "a resumed run must not submit twice")

    def test_release_behavior_and_build_are_aligned_to_the_manifest_only(self):
        fake = FakeAppStoreConnect(
            self.fixture, releaseType="AFTER_APPROVAL", buildId="build-old"
        )
        self.engine(fake).run()
        self.assertEqual(fake.version["releaseType"], "MANUAL")
        self.assertEqual(fake.version["buildId"], "build-1")
        self.assertEqual(fake.writes[:2], ["PATCH releaseType", "PATCH build"])

    def test_drifted_review_notes_are_restored_to_the_approved_text(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.review_detail["notes"] = "someone edited this in the portal"
        self.engine(fake).run()
        self.assertEqual(
            fake.review_detail["notes"],
            self.fixture.content["appReview"]["notes"],
        )

    def test_an_absent_review_detail_refuses_rather_than_inventing_contacts(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.review_detail = None
        with self.assertRaises(submission.SubmissionError) as caught:
            self.engine(fake).run()
        self.assertIn("contact information", str(caught.exception))
        self.assertEqual(fake.writes, [])

    def test_a_subscription_needing_captain_work_refuses_before_submitting(self):
        fake = FakeAppStoreConnect(self.fixture, subscriptionState="MISSING_METADATA")
        with self.assertRaises(submission.SubmissionError):
            self.engine(fake).run()
        self.assertNotIn("PATCH submitted", fake.writes)

    def test_an_already_approved_subscription_is_not_resubmitted(self):
        fake = FakeAppStoreConnect(self.fixture, subscriptionState="APPROVED")
        self.engine(fake).run()
        self.assertNotIn("POST subscriptionItem", fake.writes)

    def test_an_unrelated_in_flight_submission_refuses(self):
        fake = FakeAppStoreConnect(
            self.fixture,
            reviewSubmissions={
                "rs-other": {
                    "state": "IN_REVIEW",
                    "items": [{"id": "item-x", "appStoreVersion": "ver-other"}],
                }
            },
        )
        with self.assertRaises(submission.SubmissionError) as caught:
            self.engine(fake).run()
        self.assertIn("unrelated review submission", str(caught.exception))

    def test_a_candidate_that_does_not_match_the_manifest_is_never_submitted(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.version_localizations[0]["description"] = "unapproved description"
        with self.assertRaises(core.AppReviewError):
            self.engine(fake).run()
        self.assertNotIn("POST reviewSubmission", fake.writes)
        self.assertNotIn("PATCH submitted", fake.writes)

    def test_the_missing_approved_build_refuses_instead_of_binding_another(self):
        fake = FakeAppStoreConnect(self.fixture, buildId="build-old")
        fake.builds["build-1"]["processingState"] = "PROCESSING"
        with self.assertRaises(submission.SubmissionError) as caught:
            self.engine(fake).run()
        self.assertIn("still processing", str(caught.exception))
        self.assertEqual(fake.version["buildId"], "build-old")


class ReadinessEvidenceTests(FixtureCase):
    def fresh(self, **overrides):
        checks = {name: evidence.PASS for name in evidence.REQUIRED_CHECKS}
        checks.update(overrides.pop("checks", {}))
        return evidence.build(
            self.fixture.manifest, checks, overrides.pop("generated", utc(NOW))
        )

    def test_fresh_evidence_for_this_candidate_verifies(self):
        document = evidence.verify(
            evidence.encode(self.fresh()), self.fixture.manifest, now=NOW
        )
        self.assertEqual(document["version"], "0.2.0")

    def test_stale_evidence_refuses(self):
        old = self.fresh(generated=utc(NOW - timedelta(hours=7)))
        with self.assertRaises(evidence.EvidenceError) as caught:
            evidence.verify(evidence.encode(old), self.fixture.manifest, now=NOW)
        self.assertIn("stale", str(caught.exception))

    def test_evidence_for_a_different_manifest_refuses(self):
        other = copy.deepcopy(self.fixture.manifest)
        document = self.fresh()
        document["manifestHash"] = "0" * 64
        with self.assertRaises(evidence.EvidenceError):
            evidence.verify(evidence.encode(document), other, now=NOW)

    def test_hand_edited_evidence_refuses(self):
        document = self.fresh()
        document["checks"]["public.cloudActivationAvailable"] = "skip"
        with self.assertRaises(evidence.EvidenceError):
            evidence.verify(evidence.encode(document), self.fixture.manifest, now=NOW)

    def test_evidence_cannot_be_built_from_a_failed_check(self):
        with self.assertRaises(evidence.EvidenceError):
            self.fresh(checks={"public.serviceHealthy": "fail"})

    def test_garbage_evidence_refuses_without_a_traceback(self):
        for value in ("", "not base64!!", evidence.encode({"schemaVersion": 1})):
            with self.subTest(value=value[:12]):
                with self.assertRaises(evidence.EvidenceError):
                    evidence.verify(value, self.fixture.manifest, now=NOW)


_REAL_REQUEST = github_api._request


class MonitorHandoffTests(unittest.TestCase):
    """One atomic cycle value, written only after acceptance and read back."""

    RESOLVER = ROOT / ".github/scripts/review_monitor_cycle.sh"

    def variable_client(self, existing=None):
        client = github_api.MonitorCycleVariable(token="fake", repo=core.REPOSITORY)
        store = {"value": existing}
        calls = []

        def request(token, method, path, payload=None):
            calls.append(method)
            if method == "GET":
                if store["value"] is None:
                    raise github_api.GitHubError("GitHub GET request failed with status 404", 404)
                return {"name": github_api.MONITOR_CYCLE_VARIABLE, "value": store["value"]}
            store["value"] = payload["value"]
            return None

        github_api._request = request
        self.addCleanup(setattr, github_api, "_request", _REAL_REQUEST)
        return client, store, calls

    def test_the_handoff_creates_then_reads_back_the_exact_cycle(self):
        client, store, calls = self.variable_client()
        value = client.hand_off("0.2.0", "41.1")
        self.assertEqual(store["value"], value)
        self.assertEqual(calls, ["GET", "POST", "GET"])

    def test_an_already_armed_identical_cycle_writes_nothing(self):
        armed = github_api.monitor_cycle_value("0.2.0", "41.1")
        client, _, calls = self.variable_client(existing=armed)
        client.hand_off("0.2.0", "41.1")
        self.assertEqual(calls, ["GET", "GET"])

    def test_a_stale_cycle_is_replaced_and_proven(self):
        stale = github_api.monitor_cycle_value("0.1.13", "40.1")
        client, store, calls = self.variable_client(existing=stale)
        client.hand_off("0.2.0", "41.1")
        self.assertEqual(calls, ["GET", "PATCH", "GET"])
        self.assertIn('"version":"0.2.0"', store["value"])

    def test_half_a_cycle_can_never_be_written(self):
        for version, build in (("", "41.1"), ("0.2.0", ""), ("latest", "41.1")):
            with self.subTest(version=version, build=build):
                with self.assertRaises(github_api.GitHubError):
                    github_api.monitor_cycle_value(version, build)

    def resolve(self, **environment):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "github-output"
            output.touch()
            completed = subprocess.run(
                [str(self.RESOLVER)],
                env={
                    "PATH": os.environ.get("PATH", ""),
                    "GITHUB_OUTPUT": str(output),
                    **environment,
                },
                capture_output=True,
                text=True,
            )
            return completed, dict(
                line.split("=", 1)
                for line in output.read_text().splitlines()
                if "=" in line
            )

    def test_the_monitor_resolves_exactly_what_the_handoff_writes(self):
        written = github_api.monitor_cycle_value("0.2.0", "41.1")
        completed, outputs = self.resolve(EVENT_NAME="schedule", SCHEDULED_CYCLE=written)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            outputs,
            {"armed": "true", "version": "0.2.0", "build": "41.1", "rearm": "false"},
        )

    def test_a_reshaped_cycle_variable_fails_visibly(self):
        for value in (
            '{"v":1,"version":"0.2.0","build":"41.1"}',
            '{"build":"41.1","v":2,"version":"0.2.0"}',
            '{"build":"41.1","v":1,"version":"latest"}',
            "0.2.0",
        ):
            with self.subTest(value=value):
                completed, outputs = self.resolve(
                    EVENT_NAME="schedule", SCHEDULED_CYCLE=value
                )
                self.assertEqual(completed.returncode, 1)
                self.assertEqual(outputs, {})

    def test_the_retiring_pair_still_works_during_migration(self):
        completed, outputs = self.resolve(
            EVENT_NAME="schedule", SCHEDULED_VERSION="0.1.13", SCHEDULED_BUILD="40.1"
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(outputs.get("version"), "0.1.13")

    def test_two_sources_naming_different_cycles_fail_rather_than_pick_one(self):
        completed, _ = self.resolve(
            EVENT_NAME="schedule",
            SCHEDULED_CYCLE=github_api.monitor_cycle_value("0.2.0", "41.1"),
            SCHEDULED_VERSION="0.1.13",
            SCHEDULED_BUILD="40.1",
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("different cycles", completed.stderr)

    def test_no_configured_cycle_stays_unarmed_and_succeeds(self):
        completed, outputs = self.resolve(EVENT_NAME="schedule")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(outputs.get("armed"), "false")


class BoundedDiagnosticsTests(unittest.TestCase):
    def test_apple_diagnostics_stay_bounded_ascii(self):
        noisy = "Bearer eyJhbGciOié\n" + "x" * 500
        redacted = asc_read.redact(noisy)
        self.assertLessEqual(len(redacted), 180)
        self.assertNotIn("\n", redacted)
        self.assertTrue(all(ord(character) < 128 for character in redacted))

    def test_an_unexpected_failure_prints_nothing_about_itself(self):
        # An undeclared exception's text can carry an Apple payload or a header,
        # and "ends in Error" is not a safety property, so none of it is printed.
        def explode():
            raise KeyError({"authorization": "Bearer super-secret-token"})

        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            code = runtime.run(explode)
        self.assertEqual(code, 1)
        self.assertNotIn("super-secret-token", captured.getvalue())
        self.assertNotIn("KeyError", captured.getvalue())
        self.assertIn("unexpected pipeline failure", captured.getvalue())

    def test_a_declared_bounded_failure_still_says_what_went_wrong(self):
        def refuse():
            raise runtime.GateError("the confirmation does not repeat the version")

        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            self.assertEqual(runtime.run(refuse), 1)
        self.assertIn("does not repeat the version", captured.getvalue())

    def test_the_read_boundary_refuses_a_non_apple_url(self):
        for url in (
            "http://api.appstoreconnect.apple.com/v1/apps",
            "https://api.appstoreconnect.apple.com.evil.test/v1/apps",
            "https://user:pass@api.appstoreconnect.apple.com/v1/apps",
        ):
            with self.subTest(url=url):
                with self.assertRaises(asc_read.AppStoreConnectError):
                    asc_read.validate_asc_url(url)

    def test_the_read_boundary_refuses_a_path_outside_the_api(self):
        for path in ("/v2/apps", "v1/apps", "/v1/../admin"):
            with self.subTest(path=path):
                with self.assertRaises(asc_read.AppStoreConnectError):
                    asc_read.build_url(path, {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
