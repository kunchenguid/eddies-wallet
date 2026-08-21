#!/usr/bin/env python3
"""Fake-boundary tests for the GET-only 0.1.17 en-US description readout.

Drives the public `read_report` / `render_report` helpers against an in-memory
App Store Connect session. Nothing here reads a credential, contacts a network
endpoint, or loads the mutation boundary.
"""

from __future__ import annotations

import importlib
import pathlib
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools" / "app-review"


def load_reader():
    sys.path.insert(0, str(TOOLS))
    return importlib.import_module("read_en_us_version_description")


class FakeSession:
    def __init__(self, versions, localizations):
        self.versions = versions
        self.localizations = localizations
        self.calls = []

    def collection(self, path, query):
        self.calls.append((path, dict(query)))
        if path.endswith("/appStoreVersions"):
            return list(self.versions), []
        if path.endswith("/appStoreVersionLocalizations"):
            return list(self.localizations), []
        raise AssertionError(f"unexpected collection path: {path}")

    def get(self, *args, **kwargs):
        raise AssertionError("description readout must not call get()")

    def post(self, *args, **kwargs):
        raise AssertionError("description readout must not mutate")

    def patch(self, *args, **kwargs):
        raise AssertionError("description readout must not mutate")


def version_resource(identifier="ver-0-1-17", version_string="0.1.17", platform="IOS"):
    return {
        "type": "appStoreVersions",
        "id": identifier,
        "attributes": {"versionString": version_string, "platform": platform},
    }


def localization_resource(identifier="loc-en-us", locale="en-US", description="Hello."):
    return {
        "type": "appStoreVersionLocalizations",
        "id": identifier,
        "attributes": {"locale": locale, "description": description},
    }


class ReadReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reader = load_reader()

    def test_read_report_returns_ids_and_verbatim_description(self):
        copy = "Line one.\n\nLine two with punctuation."
        session = FakeSession(
            [version_resource()],
            [
                localization_resource(description=copy),
                localization_resource("loc-en-gb", "en-GB", "Other locale copy."),
            ],
        )
        report = self.reader.read_report(session)
        self.assertEqual(report["app_id"], "6795664301")
        self.assertEqual(report["app_store_version_id"], "ver-0-1-17")
        self.assertEqual(report["en_us_localization_id"], "loc-en-us")
        self.assertEqual(report["description"], copy)
        self.assertEqual(
            report["locales"],
            [("en-US", "loc-en-us"), ("en-GB", "loc-en-gb")],
        )
        self.assertEqual(
            session.calls[0][0], "/v1/apps/6795664301/appStoreVersions"
        )
        self.assertEqual(session.calls[0][1]["filter[versionString]"], "0.1.17")
        self.assertEqual(
            session.calls[1][0],
            "/v1/appStoreVersions/ver-0-1-17/appStoreVersionLocalizations",
        )
        rendered = self.reader.render_report(report)
        self.assertIn("app_id=6795664301", rendered)
        self.assertIn("app_store_version_id=ver-0-1-17", rendered)
        self.assertIn("en_us_localization_id=loc-en-us", rendered)
        self.assertIn(self.reader.DESCRIPTION_BEGIN, rendered)
        self.assertIn(copy, rendered)
        self.assertTrue(rendered.endswith(self.reader.DESCRIPTION_END))
        self.assertNotIn("Other locale copy.", rendered)

    def test_missing_version_is_a_bounded_failure(self):
        session = FakeSession([], [localization_resource()])
        with self.assertRaises(self.reader.DescriptionReadError):
            self.reader.read_report(session)

    def test_missing_en_us_localization_is_a_bounded_failure(self):
        session = FakeSession(
            [version_resource()],
            [localization_resource("loc-fr", "fr-FR", "Bonjour.")],
        )
        with self.assertRaises(self.reader.DescriptionReadError):
            self.reader.read_report(session)

    def test_reader_never_loads_the_mutation_boundary(self):
        program = (
            "import sys; sys.dont_write_bytecode = True;"
            f"sys.path.insert(0, {str(TOOLS)!r});"
            "import read_en_us_version_description;"
            "print(' '.join(sorted(sys.modules)))"
        )
        completed = subprocess.run(
            [sys.executable, "-c", program],
            capture_output=True,
            text=True,
            check=True,
            cwd=str(ROOT),
        )
        loaded = set(completed.stdout.split())
        self.assertIn("read_en_us_version_description", loaded)
        self.assertIn("asc_read", loaded)
        self.assertNotIn("asc_write", loaded)
        self.assertNotIn("submission", loaded)


if __name__ == "__main__":
    unittest.main(verbosity=2)
