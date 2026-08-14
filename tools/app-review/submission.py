#!/usr/bin/env python3
"""Idempotent App Review submission for one captain-approved candidate.

The engine can only move Apple towards the manifest the captain already merged,
and it proves it got there by reading Apple back:

1. Align. If the live release behavior, bound build, or App Review notes differ
   from the approved manifest, patch exactly those attributes and read them back.
   Nothing else is written, so listing copy, screenshots, products, and contact
   details stay captain-attended work that this engine can only observe.
2. Reconcile. `core.reconcile_authoritatively` compares the whole approved
   manifest against the authoritative GET-only read. A candidate that does not
   match is refused here, before any submission exists.
3. Submit. One open review submission is resumed or created, only the exact
   candidate version is attached, Cloud subscriptions are verified reviewable
   without becoming review-submission items, and the submission is submitted
   only while it is still `READY_FOR_REVIEW`.
4. Read back. The run is accepted only when Apple reports the submission and the
   App Store version in a submitted state.

Every step is safe to rerun: a resumed run that finds Apple already submitted
performs no write and proceeds straight to the monitor handoff.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import sys
from typing import Any, Mapping, Optional

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import asc_read  # noqa: E402
import asc_write  # noqa: E402
import content  # noqa: E402
import core  # noqa: E402

OPEN_SUBMISSION_STATES = (
    "READY_FOR_REVIEW",
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "UNRESOLVED_ISSUES",
)
ACCEPTED_SUBMISSION_STATES = frozenset(("WAITING_FOR_REVIEW", "IN_REVIEW"))
SUBSCRIPTION_ALREADY_REVIEWABLE = frozenset(
    ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_BINARY_APPROVAL", "APPROVED")
)


class SubmissionError(core.BoundedError):
    """A bounded, nonsecret submission failure. It never carries Apple payloads."""


@dataclass
class SubmissionOutcome:
    accepted: bool
    reconciliation: str
    submission_state: str
    version_state: str
    writes: list[str] = field(default_factory=list)


class SubmissionEngine:
    def __init__(
        self,
        read: asc_read.ReadSession,
        change: asc_write.ChangeSession,
        manifest: Mapping[str, Any],
        verified_files: Mapping[str, Mapping[str, Any]],
    ):
        self._read = read
        self._change = change
        self._manifest = core.validate_manifest(manifest)
        self._candidate = self._manifest["candidate"]
        self._verified_files = verified_files

    def run(self) -> SubmissionOutcome:
        version_id = self._align_candidate()
        reconciliation = core.reconcile_authoritatively(
            self._manifest,
            core.ReadOnlyASCClient(
                content.CandidateReadTransport(
                    self._read, self._candidate, self._verified_files
                )
            ),
        )
        if reconciliation.outcome != "matching_draft":
            # `already_submitted` is the resumable path: Apple accepted an earlier
            # run and only the handoff may still be outstanding.
            if reconciliation.outcome != "already_submitted":
                raise SubmissionError(
                    "the approved candidate is not in a submittable state on App Store Connect"
                )
            submission = self._open_submission(version_id)
            return self._accept(reconciliation.outcome, submission, version_id)

        submission_id, submission_state = self._resume_or_create_submission(version_id)
        if submission_state == "READY_FOR_REVIEW":
            self._attach_items(submission_id, version_id)
            self._verify_cloud_subscriptions_reviewable()
            self._change.submit_for_review(submission_id)
        return self._accept(
            reconciliation.outcome, (submission_id, None), version_id
        )

    # -- alignment ----------------------------------------------------------

    def _align_candidate(self) -> str:
        version = self._version_resource()
        version_id = version["id"]
        attributes = asc_read.attributes(version)

        if asc_read.text(attributes, "appVersionState") in core.SUBMITTED_STATES:
            # A resumed run must not try to edit a candidate Apple already has.
            return version_id

        if attributes.get("releaseType") != self._candidate["releaseType"]:
            self._change.set_release_type(version_id, self._candidate["releaseType"])
            if (
                asc_read.attributes(self._version_resource()).get("releaseType")
                != self._candidate["releaseType"]
            ):
                raise SubmissionError(
                    "App Store Connect did not retain the approved release behavior"
                )

        self._align_build(version_id)
        self._align_review_detail(version_id)
        return version_id

    def _version_resource(self) -> Mapping[str, Any]:
        # Query shape mirrors SSHHIP's proven `loadVersions`: filter server-side
        # only by platform and never restrict `fields[appStoreVersions]`, so
        # Apple returns its default attribute set (a superset of what this code
        # reads) and no invalid sparse-field name can ever reject the read. The
        # single 0.1.x candidate is still selected client-side below.
        versions, _ = self._read.collection(
            f"/v1/apps/{core.APP_ID}/appStoreVersions",
            {
                "filter[versionString]": self._candidate["version"],
                "filter[platform]": core.PLATFORM,
                "limit": "200",
            },
        )
        matching = [
            item
            for item in versions
            if asc_read.attributes(item).get("versionString")
            == self._candidate["version"]
            and asc_read.attributes(item).get("platform") == core.PLATFORM
        ]
        if len(matching) != 1:
            raise SubmissionError(
                "the approved App Store version is absent or ambiguous; the captain "
                "creates and completes it before submission"
            )
        return matching[0]

    def _align_build(self, version_id: str) -> None:
        target = self._candidate["build"]
        if self._bound_build_version(version_id) == target:
            return
        # SSHHIP's proven `loadBuild` filters: app + exact build version +
        # marketing (prerelease) version, with no `fields[builds]` restriction so
        # the default build attributes (`version`, `expired`, `processingState`,
        # ...) always come back.
        builds, _ = self._read.collection(
            "/v1/builds",
            {
                "filter[app]": core.APP_ID,
                "filter[version]": target,
                "filter[preReleaseVersion.version]": self._candidate["version"],
                "limit": "200",
            },
        )
        usable = [
            item
            for item in builds
            if asc_read.attributes(item).get("version") == target
            and asc_read.attributes(item).get("expired") is False
            and asc_read.attributes(item).get("processingState") == "VALID"
        ]
        if len(usable) != 1:
            raise SubmissionError(
                "the approved build is absent, expired, still processing, or ambiguous"
            )
        self._change.bind_build(version_id, usable[0]["id"])
        if self._bound_build_version(version_id) != target:
            raise SubmissionError(
                "App Store Connect did not bind the approved build to the candidate"
            )

    def _bound_build_version(self, version_id: str) -> Optional[str]:
        # The bound-build related-resource read takes Apple's default build
        # fields (no sparse-field restriction), and `optional_single` already
        # treats an unbound build (Apple's `data: null`) as absent.
        build = self._read.optional_single(
            f"/v1/appStoreVersions/{version_id}/build",
            {},
        )
        if build is None:
            return None
        attributes = asc_read.attributes(build)
        if attributes.get("expired") is not False:
            raise SubmissionError("the currently bound build is expired")
        return asc_read.text(attributes, "version")

    def _align_review_detail(self, version_id: str) -> None:
        approved = self._manifest["content"]["appReview"]
        # No `fields[appStoreReviewDetails]` restriction (Apple defaults);
        # `optional_single` reports an absent detail (`data: null`) as None, which
        # this method refuses on rather than inventing contact information.
        detail = self._read.optional_single(
            f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail",
            {},
        )
        if detail is None:
            raise SubmissionError(
                "the candidate has no App Review detail; the captain completes its "
                "contact information before submission"
            )
        attributes = asc_read.attributes(detail)
        if (
            asc_read.text(attributes, "notes") == approved["notes"]
            and attributes.get("demoAccountRequired") is False
        ):
            return
        self._change.set_review_detail(detail["id"], approved["notes"])
        readback = self._read.optional_single(
            f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail",
            {},
        )
        if readback is None:
            raise SubmissionError("App Store Connect lost the App Review detail")
        confirmed = asc_read.attributes(readback)
        if (
            asc_read.text(confirmed, "notes") != approved["notes"]
            or confirmed.get("demoAccountRequired") is not False
        ):
            raise SubmissionError(
                "App Store Connect did not retain the approved App Review detail"
            )

    # -- review submission --------------------------------------------------

    def _open_submissions(self) -> list[Mapping[str, Any]]:
        # SSHHIP's proven `loadSubmissions` shape: read the app-scoped
        # `/v1/apps/{APP_ID}/reviewSubmissions` relationship collection filtered
        # only by platform, with no `fields[reviewSubmissions]` restriction, and
        # narrow to the open states client-side. Requesting a sparse
        # `fields[reviewSubmissions]` set is exactly what let the invalid
        # `submitted` field reject this read; taking Apple's default fields
        # removes that whole class of failure.
        submissions, _ = self._read.collection(
            f"/v1/apps/{core.APP_ID}/reviewSubmissions",
            {
                "filter[platform]": core.PLATFORM,
                "limit": "200",
            },
        )
        open_submissions = [
            submission
            for submission in submissions
            if asc_read.text(asc_read.attributes(submission), "state")
            in OPEN_SUBMISSION_STATES
        ]
        if len(open_submissions) > 1:
            raise SubmissionError(
                "App Store Connect holds more than one open review submission"
            )
        return open_submissions

    def _submission_items(self, submission_id: str) -> list[Mapping[str, Any]]:
        # SSHHIP's proven items read: never restrict `fields[reviewSubmissionItems]`
        # and use `include=appStoreVersion` to materialize the version linkage this
        # code reads in `_contains_version`. `subscription` is not a valid
        # reviewSubmissionItems field/relationship on App Store Connect, so the
        # earlier `fields[reviewSubmissionItems]=...,subscription` sparse set
        # rejected this read; taking Apple defaults returns whatever linkages the
        # item actually carries without naming an invalid one.
        items, _ = self._read.collection(
            f"/v1/reviewSubmissions/{submission_id}/items",
            {
                "include": "appStoreVersion",
                "limit": "200",
            },
        )
        return items

    def _resume_or_create_submission(self, version_id: str) -> tuple[str, str]:
        open_submissions = self._open_submissions()
        if open_submissions:
            submission = open_submissions[0]
            state = asc_read.text(asc_read.attributes(submission), "state")
            if state != "READY_FOR_REVIEW" and not self._contains_version(
                submission["id"], version_id
            ):
                raise SubmissionError(
                    "an unrelated review submission is already in flight for this app"
                )
            return submission["id"], state
        submission_id = self._change.create_review_submission(
            core.APP_ID, core.PLATFORM
        )
        readback = self._open_submissions()
        if len(readback) != 1 or readback[0]["id"] != submission_id:
            raise SubmissionError(
                "App Store Connect did not return exactly the created review submission"
            )
        return submission_id, asc_read.text(
            asc_read.attributes(readback[0]), "state"
        )

    def _contains_version(self, submission_id: str, version_id: str) -> bool:
        return any(
            asc_read.linkage_id(item, "appStoreVersion", "appStoreVersions")
            == version_id
            for item in self._submission_items(submission_id)
        )

    def _attach_items(self, submission_id: str, version_id: str) -> None:
        """Attach and confirm only the candidate App Store version."""
        if not self._contains_version(submission_id, version_id):
            self._change.add_version_item(submission_id, version_id)
            if not self._contains_version(submission_id, version_id):
                raise SubmissionError(
                    "App Store Connect did not attach the approved candidate"
                )

    def _verify_cloud_subscriptions_reviewable(self) -> None:
        """Verify Cloud subscriptions without attaching purchase-product items."""
        _, included = self._read.collection(
            f"/v1/apps/{core.APP_ID}/subscriptionGroups",
            {
                "include": "subscriptions",
                "limit": "200",
            },
        )
        by_product = {
            asc_read.text(asc_read.attributes(item), "productId"): item
            for item in included
            if item.get("type") == "subscriptions"
        }
        acceptable_states = SUBSCRIPTION_ALREADY_REVIEWABLE | {"READY_TO_SUBMIT"}
        for product_id in core.CLOUD_PRODUCT_IDS:
            subscription = by_product.get(product_id)
            if subscription is None:
                raise SubmissionError(
                    "an approved Cloud subscription is absent from App Store Connect"
                )
            state = asc_read.text(asc_read.attributes(subscription), "state")
            if state not in acceptable_states:
                raise SubmissionError(
                    "a Cloud subscription needs captain-attended App Store Connect work"
                )

    # -- acceptance ---------------------------------------------------------

    def _open_submission(self, version_id: str) -> tuple[str, Optional[str]]:
        for submission in self._open_submissions():
            if self._contains_version(submission["id"], version_id):
                return submission["id"], asc_read.text(
                    asc_read.attributes(submission), "state"
                )
        raise SubmissionError(
            "App Store Connect reports the candidate submitted but holds no matching "
            "review submission"
        )

    def _accept(
        self,
        reconciliation: str,
        submission: tuple[str, Optional[str]],
        version_id: str,
    ) -> SubmissionOutcome:
        submission_id = submission[0]
        payload = self._read.get(
            f"/v1/reviewSubmissions/{submission_id}",
            {},
        )
        data = payload.get("data")
        if not isinstance(data, dict):
            raise SubmissionError("App Store Connect returned no review submission")
        submission_state = asc_read.text(
            asc_read.attributes(asc_read.resource(data)), "state"
        )
        version_state = self._version_state(version_id)
        accepted = (
            submission_state in ACCEPTED_SUBMISSION_STATES
            and version_state in core.SUBMITTED_STATES
        )
        if not accepted:
            raise SubmissionError(
                "Apple did not accept the submission; the monitor cycle stays unarmed"
            )
        return SubmissionOutcome(
            accepted=True,
            reconciliation=reconciliation,
            submission_state=submission_state,
            version_state=version_state,
            writes=list(self._change.writes),
        )

    def _version_state(self, version_id: str) -> str:
        payload = self._read.get(
            f"/v1/appStoreVersions/{version_id}",
            {},
        )
        data = payload.get("data")
        if not isinstance(data, dict):
            raise SubmissionError("App Store Connect returned no App Store version")
        return asc_read.text(asc_read.attributes(asc_read.resource(data)), "appVersionState")
