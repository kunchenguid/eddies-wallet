#!/usr/bin/env python3
"""Executable tests for the one-shot 0.1.17 en-US EULA description append.

Drives the public functions and `remediate()` against a fake App Store Connect
session. Nothing here reads a credential or contacts a network endpoint.
"""

from __future__ import annotations

import copy
import json
import pathlib
import sys
import unittest
from unittest import mock
import urllib.error

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools" / "app-review"
sys.path.insert(0, str(TOOLS))

import append_standard_eula as eula  # noqa: E402
import asc_read  # noqa: E402


def approved_description() -> str:
    document = json.loads(
        (ROOT / "tools" / "app-review" / "manifests" / "0.1.17.json").read_text()
    )
    return document["content"]["listing"]["description"]


def pre_eula_description() -> str:
    """The 0.1.17 listing before the one-shot live ASC EULA append."""
    current = approved_description()
    marker = "\n\n" + eula.EULA_LINE
    if eula.eula_present(current):
        if marker not in current:
            raise AssertionError("approved description has the EULA URL in an unexpected place")
        return current.replace(marker, "", 1)
    return current


def version_resource(version_string="0.1.17", state="REJECTED"):
    return {
        "data": {
            "type": "appStoreVersions",
            "id": eula.VERSION_ID,
            "attributes": {
                "versionString": version_string,
                "appVersionState": state,
            },
        }
    }


def localization_resource(description, locale="en-US", **extra):
    attributes = {
        "description": description,
        "locale": locale,
        "keywords": "allowance,pocket money",
        "marketingUrl": None,
        "promotionalText": "A parent-managed virtual allowance wallet.",
        "supportUrl": "https://eddies-wallet.kunchenguid.com/",
        "whatsNew": "",
    }
    attributes.update(extra)
    return {
        "data": {
            "type": "appStoreVersionLocalizations",
            "id": eula.LOCALIZATION_ID,
            "attributes": attributes,
        }
    }


class FakeSession:
    """In-memory Apple that records GET/PATCH and mutates the localization copy."""

    def __init__(self, description, locale="en-US", version="0.1.17"):
        self.version = version_resource(version)
        self.localization = localization_resource(description, locale=locale)
        self.gets = []
        self.patches = []

    def get(self, path, query):
        self.gets.append((path, dict(query)))
        if path == eula.VERSION_PATH:
            return copy.deepcopy(self.version)
        if path == eula.LOCALIZATION_PATH:
            return copy.deepcopy(self.localization)
        raise AssertionError(f"unexpected GET {path}")

    def patch(self, path, document):
        self.patches.append((path, copy.deepcopy(document)))
        if path != eula.LOCALIZATION_PATH:
            raise eula.CannotAppend("unexpected PATCH path")
        description = document["data"]["attributes"]["description"]
        attrs = dict(self.localization["data"]["attributes"])
        attrs["description"] = description
        self.localization["data"]["attributes"] = attrs
        return copy.deepcopy(self.localization)


class AppendLogicTests(unittest.TestCase):
    def test_the_approved_0117_listing_matches_the_already_applied_eula_line(self):
        self.assertTrue(eula.eula_present(approved_description()))
        self.assertEqual(
            approved_description(),
            eula.append_eula_line(pre_eula_description()),
        )

    def test_the_approved_0117_description_accepts_the_standard_eula_line(self):
        original = pre_eula_description()
        self.assertFalse(eula.eula_present(original))
        self.assertIn(eula.ANCHOR, original)
        updated = eula.append_eula_line(original)
        self.assertTrue(eula.eula_present(updated))
        self.assertEqual(updated, original.replace(
            eula.ANCHOR,
            eula.ANCHOR + "\n\n" + eula.EULA_LINE,
            1,
        ))
        self.assertTrue(eula.prior_copy_intact(original, updated))
        self.assertLessEqual(len(updated), eula.MAX_DESCRIPTION_CHARS)
        self.assertIn("\n\nVIRTUAL MONEY ONLY\n\n", updated)
        self.assertGreater(updated.find(eula.EULA_LINE), updated.find(eula.ANCHOR))
        self.assertGreater(
            updated.find("VIRTUAL MONEY ONLY"), updated.find(eula.EULA_LINE)
        )

    def test_append_is_refused_when_the_link_is_already_present(self):
        original = eula.append_eula_line(pre_eula_description())
        with self.assertRaises(eula.CannotAppend):
            eula.append_eula_line(original)
        self.assertTrue(eula.prior_copy_intact(original, original))

    def test_append_refuses_when_the_auto_renewal_anchor_is_missing(self):
        with self.assertRaises(eula.CannotAppend):
            eula.append_eula_line("A wallet with no subscription disclosure.")

    def test_append_refuses_when_the_result_would_exceed_apples_limit(self):
        padding = "x" * (eula.MAX_DESCRIPTION_CHARS - len(eula.ANCHOR) - 8)
        too_long = eula.ANCHOR + padding
        with self.assertRaises(eula.CannotAppend):
            eula.append_eula_line(too_long)


class RemediateTests(unittest.TestCase):
    def test_a_missing_eula_is_appended_and_read_back(self):
        original = pre_eula_description()
        session = FakeSession(original)
        report = eula.remediate(session, confirm=eula.CONFIRM_VALUE)
        self.assertEqual(report.action, "patched")
        self.assertFalse(report.before_present)
        self.assertTrue(report.after_present)
        self.assertTrue(report.prior_copy_intact)
        self.assertTrue(report.other_fields_unchanged)
        self.assertTrue(report.length_ok)
        self.assertEqual(report.version, "0.1.17")
        self.assertEqual(report.locale, "en-US")
        self.assertEqual(len(session.patches), 1)
        path, document = session.patches[0]
        self.assertEqual(path, eula.LOCALIZATION_PATH)
        self.assertEqual(
            set(document["data"]["attributes"]),
            {"description"},
        )
        self.assertEqual(document["data"]["id"], eula.LOCALIZATION_ID)
        self.assertEqual(document["data"]["type"], "appStoreVersionLocalizations")
        live = session.localization["data"]["attributes"]["description"]
        self.assertEqual(live, eula.append_eula_line(original))
        self.assertEqual(
            [path for path, _ in session.gets],
            [eula.VERSION_PATH, eula.LOCALIZATION_PATH, eula.LOCALIZATION_PATH],
        )
        self.assertIn("eula_present=no", eula.format_report(report))
        self.assertIn("action: patched", eula.format_report(report))
        self.assertIn("prior_copy_intact=yes", eula.format_report(report))

    def test_a_second_run_is_a_no_op(self):
        original = eula.append_eula_line(pre_eula_description())
        session = FakeSession(original)
        report = eula.remediate(session, confirm=eula.CONFIRM_VALUE)
        self.assertEqual(report.action, "already-present")
        self.assertTrue(report.before_present)
        self.assertTrue(report.after_present)
        self.assertEqual(report.before_chars, report.after_chars)
        self.assertEqual(session.patches, [])
        self.assertTrue(report.prior_copy_intact)
        self.assertTrue(report.other_fields_unchanged)

    def test_wrong_confirm_never_reaches_apple(self):
        session = FakeSession(pre_eula_description())
        with self.assertRaises(eula.ConfirmError):
            eula.remediate(session, confirm="please")
        self.assertEqual(session.gets, [])
        self.assertEqual(session.patches, [])

    def test_the_wrong_version_is_refused_before_a_write(self):
        session = FakeSession(pre_eula_description(), version="0.1.16")
        with self.assertRaises(eula.BoundMismatch):
            eula.remediate(session, confirm=eula.CONFIRM_VALUE)
        self.assertEqual(session.patches, [])

    def test_the_wrong_locale_is_refused_before_a_write(self):
        session = FakeSession(pre_eula_description(), locale="en-GB")
        with self.assertRaises(eula.BoundMismatch):
            eula.remediate(session, confirm=eula.CONFIRM_VALUE)
        self.assertEqual(session.patches, [])

    def test_a_changed_non_description_field_fails_the_readback(self):
        original = pre_eula_description()
        session = FakeSession(original)

        def patch_and_clobber(path, document):
            FakeSession.patch(session, path, document)
            session.localization["data"]["attributes"]["keywords"] = "changed"

        session.patch = patch_and_clobber
        with self.assertRaises(eula.VerifyError):
            eula.remediate(session, confirm=eula.CONFIRM_VALUE)


class PatchFailureTests(unittest.TestCase):
    class _Credential:
        def bearer_token(self, **_):
            return "not-a-real-token"

    def test_http_403_names_a_possible_missing_metadata_write_role(self):
        session = eula.AppleSession(self._Credential())

        def fail(_request, timeout=None):
            raise urllib.error.HTTPError(
                "https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/x",
                403,
                "Forbidden",
                hdrs=None,
                fp=mock.Mock(read=lambda: json.dumps(
                    {"errors": [{"code": "FORBIDDEN", "title": "Forbidden"}]}
                ).encode()),
            )

        session._opener.open = fail
        with self.assertRaises(asc_read.AppStoreConnectUnauthorized) as raised:
            session.patch(
                eula.LOCALIZATION_PATH,
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": eula.LOCALIZATION_ID,
                        "attributes": {"description": "x"},
                    }
                },
            )
        message = str(raised.exception)
        self.assertIn("403", message)
        self.assertIn("metadata-write", message)

    def test_the_live_session_refuses_to_patch_any_other_path_or_field(self):
        session = eula.AppleSession(self._Credential())
        with self.assertRaises(eula.CannotAppend):
            session.patch("/v1/appStoreVersions/" + eula.VERSION_ID, {
                "data": {"attributes": {"description": "x"}}
            })
        with self.assertRaises(eula.CannotAppend):
            session.patch(
                eula.LOCALIZATION_PATH,
                {
                    "data": {
                        "attributes": {
                            "description": "x",
                            "keywords": "no",
                        }
                    }
                },
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
