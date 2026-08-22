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
SCREENSHOT_DIRECTORY = ("docs", "app-store", "screenshots", "iphone-67")
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
                    "displayType": SCREENSHOT_SLOT,
                    "width": 8,
                    "height": 8,
                    "files": [
                        "01-wallet.png",
                        "02-parent.png",
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
            screenshot_directory=SCREENSHOT_DIRECTORY,
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
        self.verified = content.verify_manifest_files(
            self.manifest, root, screenshot_directory=SCREENSHOT_DIRECTORY
        )


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
        verified = content.verify_manifest_files(
            self.fixture.manifest, self.root, screenshot_directory=SCREENSHOT_DIRECTORY
        )
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
            content.verify_manifest_files(
                self.fixture.manifest, self.root, screenshot_directory=SCREENSHOT_DIRECTORY
            )
        self.assertIn("changed content since approval", str(caught.exception))

    def test_a_missing_reviewed_file_refuses(self):
        (self.root / "docs/app-store/iap/cloud-annual.png").unlink()
        with self.assertRaises(content.ContentError):
            content.verify_manifest_files(
                self.fixture.manifest, self.root, screenshot_directory=SCREENSHOT_DIRECTORY
            )


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

    def test_listing_screenshot_drift_is_readable_when_listing_match_is_deferred(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.screenshot_sets[0]["screenshots"][0]["sourceFileChecksum"] = "0" * 32
        live = core.ReadOnlyASCClient(
            content.CandidateReadTransport(
                fake,
                self.fixture.candidate,
                self.fixture.verified,
                match_listing_screenshots=False,
            )
        ).read_candidate(self.fixture.candidate)
        self.assertEqual(live.version, self.fixture.candidate["version"])
        self.assertEqual(live.build, self.fixture.candidate["build"])
        self.assertEqual(live.content["screenshots"], [])
        self.assertEqual(len(live.content["inAppPurchases"]), 2)
        self.assertEqual(fake.writes, [])

    def test_deferred_listing_match_still_requires_delivered_iap_review_assets(self):
        fake = FakeAppStoreConnect(self.fixture)
        fake.screenshot_sets[0]["screenshots"][0]["sourceFileChecksum"] = "0" * 32
        fake.subscriptions[core.CLOUD_PRODUCT_IDS[0]]["screenshot"][
            "assetDeliveryState"
        ] = {"state": "UPLOAD_COMPLETE"}
        with self.assertRaises(core.AppReviewError) as caught:
            core.ReadOnlyASCClient(
                content.CandidateReadTransport(
                    fake,
                    self.fixture.candidate,
                    self.fixture.verified,
                    match_listing_screenshots=False,
                )
            ).read_candidate(self.fixture.candidate)
        self.assertEqual(caught.exception.code, "E_ASC_READ")
        self.assertIn("not fully delivered", str(caught.exception))

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
