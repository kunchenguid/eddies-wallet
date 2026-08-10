#!/usr/bin/env python3
"""Fake-boundary tests for the credential-free App Review deterministic core."""

from __future__ import annotations

import copy
import importlib.util
import pathlib
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE_PATH = ROOT / "tools" / "app-review" / "core.py"
spec = importlib.util.spec_from_file_location("eddies_app_review_core", CORE_PATH)
core = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = core
spec.loader.exec_module(core)


class FakeASCTransport:
    """A GET boundary that makes mutation attempts visibly fail."""

    def __init__(self, document=None, unauthorized=False):
        self.document = document
        self.unauthorized = unauthorized
        self.get_calls = []
        self.mutation_calls = []

    def get(self, path, query):
        self.get_calls.append((path, dict(query)))
        if self.unauthorized:
            raise core.ASCUnauthorized()
        return self.document

    def post(self, *args, **kwargs):
        self.mutation_calls.append((args, kwargs))
        raise AssertionError("a GET-only client must never call a mutation boundary")


class FakeIssueBoundary:
    """An in-memory GitHub issue API boundary with a GitHub Actions actor."""

    def __init__(self):
        self.issues = []
        self.comments = {}
        self.calls = []
        self.next_issue = 100
        self.next_comment = 1000

    def list_issues(self):
        self.calls.append("list_issues")
        return tuple(self.issues)

    def create_issue(self, title, body):
        self.calls.append("create_issue")
        self.next_issue += 1
        issue = core.Issue(self.next_issue, title, body, "github-actions[bot]")
        self.issues.append(issue)
        self.comments[issue.number] = []
        return issue

    def list_comments(self, issue_number):
        self.calls.append("list_comments")
        return tuple(self.comments[issue_number])

    def create_comment(self, issue_number, body):
        self.calls.append("create_comment")
        self.next_comment += 1
        comment = core.Comment(self.next_comment, body, "github-actions[bot]")
        self.comments[issue_number].append(comment)
        return comment

    def update_comment(self, comment_identifier, body):
        self.calls.append("update_comment")
        for comments in self.comments.values():
            for index, comment in enumerate(comments):
                if comment.identifier == comment_identifier:
                    replacement = core.Comment(
                        comment_identifier, body, "github-actions[bot]"
                    )
                    comments[index] = replacement
                    return replacement
        raise AssertionError("missing comment")


class AppReviewCoreTests(unittest.TestCase):
    CANDIDATE = {
        "version": "0.1",
        "build": "42.1",
        "baselineVersion": "0.0.9",
        "sourceCommit": "a" * 40,
        "releaseType": "MANUAL",
    }

    def assert_refusal(self, code, action):
        with self.assertRaises(core.AppReviewError) as failure:
            action()
        self.assertEqual(failure.exception.code, code)

    def reviewed_content(
        self, root, description="A reviewed description.", write_files=True
    ):
        root = pathlib.Path(root)
        files = {
            "screenshots/child-home.png": b"child home screenshot bytes",
            "screenshots/parent-area.png": b"parent area screenshot bytes",
            "iap/monthly.png": b"monthly purchase screenshot bytes",
            "iap/annual.png": b"annual purchase screenshot bytes",
        }
        if write_files:
            for relative_path, value in files.items():
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value)
        return core.materialize_source_content(
            root,
            {
                "appName": "Eddie's Wallet",
                "subtitle": "A kid-first wallet",
                "promotionalText": "Family money habits, one small step at a time.",
                "description": description,
                "keywords": "kids,allowance,wallet",
                "privacyPolicyUrl": "https://eddieswallet.example/privacy",
                "supportUrl": "https://eddieswallet.example/support",
                "whatsNew": "Improved the exact candidate for review.",
            },
            [
                {
                    "slot": "iphone-6.9",
                    "files": [
                        "screenshots/child-home.png",
                        "screenshots/parent-area.png",
                    ],
                }
            ],
            [
                {
                    "productId": core.CLOUD_PRODUCT_IDS[0],
                    "reviewNotes": "Optional Cloud monthly plan is available from Parent.",
                    "screenshotPath": "iap/monthly.png",
                },
                {
                    "productId": core.CLOUD_PRODUCT_IDS[1],
                    "reviewNotes": "Optional Cloud annual plan is available from Parent.",
                    "screenshotPath": "iap/annual.png",
                },
            ],
            "Reviewers sign in with their own Apple Account, choose a local PIN, and use Apple's review purchase flow.",
        )

    def manifest(self, content):
        return core.build_manifest(
            self.CANDIDATE,
            content,
            approved_utc="2026-08-10T12:00:00Z",
            approval_statement="Captain approved the exact candidate and reviewed content.",
        )

    def live_document(self, content, state="PREPARE_FOR_SUBMISSION"):
        return {
            "appId": core.APP_ID,
            "bundleId": core.BUNDLE_ID,
            "platform": core.PLATFORM,
            "version": self.CANDIDATE["version"],
            "build": self.CANDIDATE["build"],
            "state": state,
            "releaseType": self.CANDIDATE["releaseType"],
            "content": content,
        }

    def test_manifest_hash_binds_exact_source_bytes_and_reviewer_owned_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            original = self.reviewed_content(root)
            manifest = self.manifest(original)
            core.verify_manifest_content(manifest, original)
            self.assertEqual(
                manifest["contentHash"], core.source_content_hash(original)
            )
            self.assertEqual(
                manifest["content"]["appReview"]["demoAccountRequired"], False
            )
            self.assertEqual(
                manifest["content"]["appReview"]["identity"], core.REVIEWER_IDENTITY
            )

            # A one-byte screenshot drift after approval cannot reuse the manifest.
            (root / "screenshots/child-home.png").write_bytes(
                b"changed screenshot bytes"
            )
            changed = self.reviewed_content(root, write_files=False)
            self.assert_refusal(
                "E_MANIFEST_BINDING",
                lambda: core.verify_manifest_content(manifest, changed),
            )

            # A self-hash cannot hide a content edit either.
            tampered = copy.deepcopy(manifest)
            tampered["content"]["listing"]["description"] = "Unapproved listing text."
            self.assert_refusal("E_MANIFEST", lambda: core.validate_manifest(tampered))

    def test_manifest_refuses_the_rejected_password_demo_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            content = self.reviewed_content(directory)
            content["appReview"]["demoAccountRequired"] = True
            self.assert_refusal("E_MANIFEST", lambda: core.source_content_hash(content))

    def test_trusted_context_requires_repo_default_branch_dispatch_and_captain_when_requested(
        self,
    ):
        captain = core.TrustedContext(
            repository=core.REPOSITORY,
            ref=core.DEFAULT_BRANCH_REF,
            event_name="workflow_dispatch",
            actor=core.CAPTAIN_GITHUB_LOGIN,
        )
        self.assertEqual(core.assert_captain_actor(captain), captain)
        for changed in (
            {"repository": "someone/fork"},
            {"ref": "refs/heads/feature"},
            {"event_name": "pull_request"},
            {"actor": "invalid actor"},
        ):
            context = core.TrustedContext(**{**captain.__dict__, **changed})
            self.assert_refusal(
                "E_CONTEXT",
                lambda context=context: core.assert_trusted_context(context),
            )
        non_captain = core.TrustedContext(
            **{**captain.__dict__, "actor": "release-manager"}
        )
        core.assert_trusted_context(non_captain)
        self.assert_refusal("E_CONTEXT", lambda: core.assert_captain_actor(non_captain))

    def test_get_only_client_has_no_mutation_path_and_reconciliation_uses_only_get(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            content = self.reviewed_content(directory)
            manifest = self.manifest(content)
            transport = FakeASCTransport(self.live_document(content))
            client = core.ReadOnlyASCClient(transport)

            result = core.reconcile_authoritatively(manifest, client)

            self.assertEqual(result.outcome, "matching_draft")
            self.assertEqual(len(transport.get_calls), 1)
            self.assertEqual(transport.mutation_calls, [])
            self.assertFalse(hasattr(client, "post"))
            self.assertFalse(hasattr(client, "patch"))
            self.assertFalse(hasattr(client, "_transport"))
            with self.assertRaises(AttributeError):
                client.post("/v1/anything")
            self.assertEqual(transport.mutation_calls, [])
            self.assertEqual(
                transport.get_calls[0][0],
                f"/v1/apps/{core.APP_ID}/appStoreVersions",
            )

    def test_missing_or_unauthorized_read_capability_refuses_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            content = self.reviewed_content(directory)
            manifest = self.manifest(content)
            self.assert_refusal(
                "E_ASC_CAPABILITY",
                lambda: core.reconcile_authoritatively(manifest, None),
            )

            transport = FakeASCTransport(unauthorized=True)
            self.assert_refusal(
                "E_ASC_CAPABILITY",
                lambda: core.reconcile_authoritatively(
                    manifest, core.ReadOnlyASCClient(transport)
                ),
            )
            self.assertEqual(len(transport.get_calls), 1)
            self.assertEqual(transport.mutation_calls, [])

    def test_authoritative_reconciliation_accepts_only_exact_live_reviewed_content(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            content = self.reviewed_content(directory)
            manifest = self.manifest(content)

            absent = self.live_document(None, state="ABSENT")
            absent["releaseType"] = None
            self.assertEqual(
                core.reconcile_authoritatively(
                    manifest, core.ReadOnlyASCClient(FakeASCTransport(absent))
                ).outcome,
                "absent",
            )
            self.assertEqual(
                core.reconcile_authoritatively(
                    manifest,
                    core.ReadOnlyASCClient(
                        FakeASCTransport(
                            self.live_document(content, "WAITING_FOR_REVIEW")
                        )
                    ),
                ).outcome,
                "already_submitted",
            )

            changed = copy.deepcopy(content)
            changed["listing"]["description"] = "Different live listing text."
            self.assert_refusal(
                "E_RECONCILIATION",
                lambda: core.reconcile_authoritatively(
                    manifest,
                    core.ReadOnlyASCClient(
                        FakeASCTransport(self.live_document(changed))
                    ),
                ),
            )

    def test_issue_journal_is_deduplicated_nonsecret_and_resumable(self):
        with tempfile.TemporaryDirectory() as directory:
            content = self.reviewed_content(directory)
            manifest = self.manifest(content)
            identity = core.JournalIdentity.from_manifest(manifest, "b" * 40)
            boundary = FakeIssueBoundary()

            first = core.GitHubIssueJournal(boundary, identity)
            opened = first.open(create=True)
            self.assertEqual(
                (opened.created, opened.resumable, opened.state), (True, False, None)
            )
            first.save(
                core.DurableJournalState("prepared", "not_read", "2026-08-10T12:01:00Z")
            )

            resumed = core.GitHubIssueJournal(boundary, identity)
            restored = resumed.open(create=False)
            self.assertFalse(restored.created)
            self.assertTrue(restored.resumable)
            self.assertEqual(restored.state.reconciliation, "not_read")
            resumed.save(
                core.DurableJournalState(
                    "reconciled", "matching_draft", "2026-08-10T12:02:00Z"
                )
            )

            self.assertEqual(len(boundary.issues), 1)
            self.assertEqual(len(boundary.comments[boundary.issues[0].number]), 1)
            self.assertIn("update_comment", boundary.calls)
            durable_surfaces = "\n".join(
                [
                    boundary.issues[0].body,
                    boundary.comments[boundary.issues[0].number][0].body,
                ]
            )
            self.assertNotIn(content["listing"]["description"], durable_surfaces)
            self.assertNotIn(content["appReview"]["notes"], durable_surfaces)

            # A revised captain-approved manifest cannot reuse the prior recovery record.
            revised = self.manifest(
                self.reviewed_content(
                    directory, description="Revised reviewed description."
                )
            )
            revised_identity = core.JournalIdentity.from_manifest(revised, "b" * 40)
            self.assertNotEqual(revised_identity.key, identity.key)
            self.assertTrue(
                core.GitHubIssueJournal(boundary, revised_identity)
                .open(create=True)
                .created
            )
            self.assertEqual(len(boundary.issues), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
