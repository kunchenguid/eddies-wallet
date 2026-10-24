#!/usr/bin/env python3
"""EDW-39: prepare must identify reviewed drift and recognize approved updates.

The approved 0.1.23 content and image bytes are the fixture, not made-up listing
copy. Adverse cases change one fact at the readback boundary.
"""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/app-review"))
import core
import runtime


class ReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.manifest = runtime.load_manifest("0.1.23", ROOT)
        self.content = copy.deepcopy(self.manifest["content"])

    def reconcile(self, state="WAITING_FOR_REVIEW"):
        candidate = self.manifest["candidate"]
        return core.reconcile_manifest_with_live_state(self.manifest, core.LiveReadState(
            core.APP_ID, core.BUNDLE_ID, core.PLATFORM, candidate["version"],
            candidate["build"], state, candidate["releaseType"], self.content,
        ))

    def test_equal_reviewed_content_matches_draft_and_submitted_versions(self):
        for state in core.DRAFT_STATES | core.SUBMITTED_STATES:
            with self.subTest(state=state):
                self.assertEqual(self.reconcile(state).outcome,
                    "matching_draft" if state in core.DRAFT_STATES else "already_submitted")

    def test_every_listing_field_names_its_path_without_its_value(self):
        for field in core.LISTING_FIELDS:
            with self.subTest(field=field):
                self.setUp()
                self.content["listing"][field] += " private drift marker"
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr):
                    status = runtime.run(self.reconcile)
                self.assertEqual(status, 1)
                self.assertIn(f"content.listing.{field}", stderr.getvalue())
                self.assertNotIn("private drift marker", stderr.getvalue())
                self.assertNotIn(self.content["listing"][field], stderr.getvalue())

    def test_review_and_subscription_fields_are_actionable(self):
        for section, field, path in (
            (self.content["appReview"], "notes", "content.appReview.notes"),
            (self.content["appReview"], "demoAccountRequired", "content.appReview.demoAccountRequired"),
            (self.content["inAppPurchases"][0], "reviewNotes", "content.inAppPurchases[0].reviewNotes"),
        ):
            old = section[field]
            section[field] = True if isinstance(old, bool) else old + " changed"
            with self.assertRaises(core.AppReviewError) as caught:
                self.reconcile()
            self.assertEqual(caught.exception.code, "E_RECONCILIATION")
            self.assertIn(path, str(caught.exception))
            section[field] = old

    def test_untrusted_extra_keys_never_enter_diagnostics(self):
        self.content["appReview"]["private-contact-value"] = "private-payload"
        with self.assertRaises(core.AppReviewError) as caught:
            self.reconcile()
        self.assertIn("content.appReview", str(caught.exception))
        self.assertNotIn("private", str(caught.exception))

    def test_field_diagnostics_are_bounded(self):
        for field in core.LISTING_FIELDS:
            self.content["listing"][field] += " changed"
        self.content["appReview"]["notes"] += " changed"
        paths = core.reviewed_content_differences(self.manifest["content"], self.content)
        self.assertEqual(len(paths), 8)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(runtime.run(self.reconcile), 1)
        self.assertIn("content.listing.appName", stderr.getvalue())
        self.assertLess(len(stderr.getvalue()), 300)


if __name__ == "__main__":
    unittest.main()
