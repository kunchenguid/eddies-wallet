#!/usr/bin/env python3
"""Executable tests for the GET-only live App Review observe harness.

The harness is the public interface: a Node script that loads a checked-out
app-review-submit engine and calls observeReviewStatus. These tests drive that
script against a fake engine directory. They never read a credential, contact
App Store Connect, or load the real shared tool.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = ROOT / "tools" / "app-review" / "observe_review_status.js"

FAKE_CONFIG = r"""
"use strict";
const fs = require("node:fs");
function record(entry) {
  const path = process.env.FAKE_ENGINE_LOG;
  if (!path) return;
  fs.appendFileSync(path, JSON.stringify({ module: "config", ...entry }) + "\n");
}
function activateFromArgv(argv, env) {
  record({ fn: "activateFromArgv", hasConfig: Boolean(env && env.APP_REVIEW_CONFIG) });
}
module.exports = { activateFromArgv };
"""

FAKE_SUBMIT = r"""
"use strict";
const fs = require("node:fs");
function record(entry) {
  const path = process.env.FAKE_ENGINE_LOG;
  if (!path) return;
  fs.appendFileSync(path, JSON.stringify({ module: "submit", ...entry }) + "\n");
}
class ApiClient {
  constructor(credentials, dependencies = {}) {
    record({
      fn: "ApiClient",
      readOnly: dependencies.readOnly === true,
      credentialKeys: Object.keys(credentials || {}).sort(),
    });
    this.readOnly = dependencies.readOnly === true;
  }
}
class AppStoreRepository {
  constructor(client, args) {
    record({
      fn: "AppStoreRepository",
      version: args && args.version,
      readOnly: client && client.readOnly === true,
    });
    this.client = client;
    this.args = args;
  }
}
module.exports = { ApiClient, AppStoreRepository };
"""

FAKE_MONITOR = r"""
"use strict";
const fs = require("node:fs");
function record(entry) {
  const path = process.env.FAKE_ENGINE_LOG;
  if (!path) return;
  fs.appendFileSync(path, JSON.stringify({ module: "monitor", ...entry }) + "\n");
}
function loadAscCredentials(env) {
  record({ fn: "loadAscCredentials", names: Object.keys(env).sort() });
  const value = (name) => {
    const raw = typeof env[name] === "string" ? env[name].trim() : "";
    if (!raw) throw new Error(name + " is missing or invalid");
    return raw;
  };
  return Object.freeze({
    apiKey: value("APP_STORE_CONNECT_API_KEY"),
    issuerId: value("APP_STORE_CONNECT_ISSUER_ID"),
    keyId: value("APP_STORE_CONNECT_KEY_ID"),
  });
}
async function observeReviewStatus(repository, versionString) {
  record({
    fn: "observeReviewStatus",
    version: versionString,
    repositoryVersion: repository && repository.args && repository.args.version,
    readOnly: repository && repository.client && repository.client.readOnly === true,
  });
  const outcome = process.env.FAKE_OBSERVE_OUTCOME || "rejected";
  const terminal = process.env.FAKE_OBSERVE_TERMINAL !== "false";
  if (outcome === "throw") throw new Error("engine threw");
  if (outcome === "rejected") {
    return Object.freeze({
      outcome,
      terminal,
      rejectedItemKinds: Object.freeze(["app_store_version"]),
    });
  }
  return Object.freeze({ outcome, terminal });
}
function runMonitor() {
  record({ fn: "runMonitor" });
  throw new Error("runMonitor must not be called");
}
class MonitorIssueClient {
  constructor() {
    record({ fn: "MonitorIssueClient" });
    throw new Error("MonitorIssueClient must not be constructed");
  }
}
module.exports = {
  loadAscCredentials,
  observeReviewStatus,
  runMonitor,
  MonitorIssueClient,
};
"""


def write_engine(directory: pathlib.Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "config.js").write_text(FAKE_CONFIG)
    (directory / "app_review_submit.js").write_text(FAKE_SUBMIT)
    (directory / "app_review_monitor.js").write_text(FAKE_MONITOR)


def read_log(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


class ObserveHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.engine = pathlib.Path(self.temp.name) / "engine"
        self.log_path = pathlib.Path(self.temp.name) / "engine.log"
        write_engine(self.engine)
        self.base_env = {
            "APP_STORE_CONNECT_API_KEY": "not-a-real-key",
            "APP_STORE_CONNECT_ISSUER_ID": "not-a-real-issuer",
            "APP_STORE_CONNECT_KEY_ID": "not-a-real-key-id",
            "APP_REVIEW_ENGINE_DIR": str(self.engine),
            "APP_REVIEW_CONFIG": str(ROOT / "tools" / "app-review" / "app-review.config.json"),
            "FAKE_ENGINE_LOG": str(self.log_path),
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_harness(self, extra: dict[str, str] | None = None, clear_github_token: bool = True) -> subprocess.CompletedProcess[str]:
        merged = os.environ.copy()
        if clear_github_token:
            merged.pop("GITHUB_TOKEN", None)
            merged.pop("GH_TOKEN", None)
        merged.update(self.base_env)
        if extra:
            merged.update(extra)
        return subprocess.run(
            ["node", str(HARNESS)],
            capture_output=True,
            text=True,
            cwd=str(ROOT),
            env=merged,
        )

    def test_the_harness_prints_and_accepts_a_terminal_rejected_observation(self):
        completed = self.run_harness(
            {
                "APP_REVIEW_OBSERVE_VERSION": "0.1.17",
                "APP_REVIEW_OBSERVE_EXPECTED": "rejected",
                "APP_REVIEW_ENGINE_SHA": "216a65513dbde70d04d0efd021792743f094ed77",
                "FAKE_OBSERVE_OUTCOME": "rejected",
            }
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("observe:", completed.stdout)
        self.assertIn('outcome: "rejected"', completed.stdout)
        self.assertIn("terminal: true", completed.stdout)
        self.assertIn('engine: "216a65513dbde70d04d0efd021792743f094ed77"', completed.stdout)
        self.assertIn("app_store_version", completed.stdout)
        self.assertNotIn("unavailable", completed.stdout)
        events = read_log(self.log_path)
        functions = [entry["fn"] for entry in events]
        self.assertIn("activateFromArgv", functions)
        self.assertIn("loadAscCredentials", functions)
        self.assertIn("ApiClient", functions)
        self.assertIn("AppStoreRepository", functions)
        self.assertIn("observeReviewStatus", functions)
        self.assertNotIn("runMonitor", functions)
        self.assertNotIn("MonitorIssueClient", functions)
        client = next(entry for entry in events if entry["fn"] == "ApiClient")
        self.assertTrue(client["readOnly"])
        observe = next(entry for entry in events if entry["fn"] == "observeReviewStatus")
        self.assertEqual(observe["version"], "0.1.17")
        self.assertTrue(observe["readOnly"])

    def test_the_harness_accepts_a_terminal_approved_observation(self):
        completed = self.run_harness(
            {
                "APP_REVIEW_OBSERVE_EXPECTED": "approved",
                "FAKE_OBSERVE_OUTCOME": "approved",
                "FAKE_OBSERVE_TERMINAL": "true",
            }
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn('outcome: "approved"', completed.stdout)
        self.assertIn("terminal: true", completed.stdout)

    def test_the_harness_rejects_a_nonterminal_approved_observation(self):
        completed = self.run_harness(
            {
                "APP_REVIEW_OBSERVE_EXPECTED": "approved",
                "FAKE_OBSERVE_OUTCOME": "approved",
                "FAKE_OBSERVE_TERMINAL": "false",
            }
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn('outcome: "approved"', completed.stdout)
        self.assertIn("terminal: false", completed.stdout)
        self.assertIn("approved observation was not terminal", completed.stderr)

    def test_the_harness_fails_when_the_engine_classifies_unavailable(self):
        completed = self.run_harness(
            {
                "APP_REVIEW_OBSERVE_EXPECTED": "rejected",
                "FAKE_OBSERVE_OUTCOME": "unavailable",
                "FAKE_OBSERVE_TERMINAL": "false",
            }
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn('outcome: "unavailable"', completed.stdout)
        self.assertIn("expected outcome rejected, got unavailable", completed.stderr)

    def test_the_harness_does_not_need_a_github_token(self):
        completed = self.run_harness({"APP_REVIEW_OBSERVE_EXPECTED": "rejected"})
        self.assertEqual(completed.returncode, 0, completed.stderr)
        load = next(entry for entry in read_log(self.log_path) if entry["fn"] == "loadAscCredentials")
        self.assertNotIn("GITHUB_TOKEN", load["names"])
        self.assertNotIn("GH_TOKEN", load["names"])

    def test_the_harness_refuses_a_missing_engine(self):
        missing = pathlib.Path(self.temp.name) / "missing"
        extra = dict(self.base_env)
        extra["APP_REVIEW_ENGINE_DIR"] = str(missing)
        completed = self.run_harness(extra)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("App Review engine is missing", completed.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
