#!/usr/bin/env node
"use strict";

// GET-only classifier for a recorded App Review observation fixture.
//
// Live App Store Connect currently shows the armed 0.1.17 cycle as APPROVED.
// The double-submission rejection that previously broke classification is a
// historical shape: an older COMPLETE+REMOVED submission plus a current
// UNRESOLVED_ISSUES+REJECTED submission (the 8e9fbd18 cycle, Apple ids
// redacted). This harness loads that recorded fixture and calls the engine's
// observeReviewStatus. It never contacts Apple, never loads
// app_review_pipeline.js, and never constructs a GitHub issue client.

const fs = require("node:fs");
const path = require("node:path");

const VERSION_PATTERN = /^[0-9]+(?:\.[0-9]+){1,2}$/u;
const SHA_PATTERN = /^[0-9a-f]{40}$/u;
const OUTCOMES = new Set([
  "pending",
  "approved",
  "rejected",
  "resolved_other",
  "unavailable",
]);
const TERMINAL_OUTCOMES = new Set([
  "approved",
  "rejected",
  "resolved_other",
  "unavailable",
]);
const DEFAULT_FIXTURE = path.join(
  __dirname,
  "fixtures",
  "monitor",
  "multiple-submissions-0.1.17.json",
);

function fail(message) {
  const error = new Error(message);
  error.code = "E_OBSERVE";
  throw error;
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function loadFixture(filePath) {
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    fail(`review fixture is missing at ${filePath}`);
  }
  if (!isObject(raw) || !isObject(raw.version) || !Array.isArray(raw.submissions) || raw.submissions.length < 2) {
    fail("review fixture is invalid");
  }
  for (const bundle of raw.submissions) {
    if (!isObject(bundle) || !isObject(bundle.submission) || !Array.isArray(bundle.items)) {
      fail("review fixture is invalid");
    }
  }
  return raw;
}

function fixtureRepository(fixture) {
  return {
    async loadApp() {
      return Object.freeze({ type: "apps", id: "6795664301" });
    },
    async loadPlatformVersions() {
      return [fixture.version];
    },
    async loadSubmissions() {
      return fixture.submissions.map((bundle) => ({
        submission: bundle.submission,
        items: bundle.items,
      }));
    },
  };
}

function printObserve(payload) {
  const lines = ["observe:"];
  for (const [key, value] of Object.entries(payload)) {
    if (Array.isArray(value)) {
      lines.push(`  ${key}: [${value.map((item) => JSON.stringify(item)).join(", ")}]`);
    } else if (typeof value === "boolean") {
      lines.push(`  ${key}: ${value}`);
    } else {
      lines.push(`  ${key}: ${JSON.stringify(value)}`);
    }
  }
  process.stdout.write(`${lines.join("\n")}\n`);
}

async function main(env = process.env, argv = process.argv.slice(2)) {
  const engineDir = path.resolve(env.APP_REVIEW_ENGINE_DIR || ".app-review-submit");
  const monitorPath = path.join(engineDir, "app_review_monitor.js");
  if (!fs.existsSync(monitorPath)) {
    fail(`App Review engine is missing at ${engineDir}`);
  }

  const config = require(path.join(engineDir, "config.js"));
  const monitor = require(monitorPath);
  if (typeof config.activateFromArgv !== "function") {
    fail("engine config.activateFromArgv is missing");
  }
  if (typeof monitor.observeReviewStatus !== "function") {
    fail("engine observeReviewStatus is missing");
  }

  config.activateFromArgv(argv, env);

  const version = (typeof env.APP_REVIEW_OBSERVE_VERSION === "string"
    ? env.APP_REVIEW_OBSERVE_VERSION
    : "0.1.17").trim();
  if (!VERSION_PATTERN.test(version) || version.length > 32) {
    fail("APP_REVIEW_OBSERVE_VERSION is missing or invalid");
  }
  const expected = (typeof env.APP_REVIEW_OBSERVE_EXPECTED === "string"
    ? env.APP_REVIEW_OBSERVE_EXPECTED
    : "rejected").trim();
  if (!OUTCOMES.has(expected)) {
    fail("APP_REVIEW_OBSERVE_EXPECTED is missing or invalid");
  }
  const engineSha = typeof env.APP_REVIEW_ENGINE_SHA === "string"
    ? env.APP_REVIEW_ENGINE_SHA.trim()
    : "";
  if (engineSha.length > 0 && !SHA_PATTERN.test(engineSha)) {
    fail("APP_REVIEW_ENGINE_SHA is invalid");
  }
  const fixturePath = path.resolve(
    typeof env.APP_REVIEW_FIXTURE === "string" && env.APP_REVIEW_FIXTURE.trim()
      ? env.APP_REVIEW_FIXTURE.trim()
      : DEFAULT_FIXTURE,
  );
  const fixture = loadFixture(fixturePath);
  const observation = await monitor.observeReviewStatus(fixtureRepository(fixture), version);
  if (!observation || typeof observation !== "object" || typeof observation.outcome !== "string") {
    fail("observeReviewStatus returned an invalid observation");
  }

  const payload = {
    version,
    outcome: observation.outcome,
    terminal: observation.terminal === true,
    fixture: path.basename(fixturePath),
  };
  if (engineSha) payload.engine = engineSha;
  if (Array.isArray(observation.rejectedItemKinds)) {
    payload.rejectedItemKinds = [...observation.rejectedItemKinds];
  }
  printObserve(payload);

  if (observation.outcome !== expected) {
    fail(`expected outcome ${expected}, got ${observation.outcome}`);
  }
  if (TERMINAL_OUTCOMES.has(expected) && observation.terminal !== true) {
    fail(`${expected} observation was not terminal`);
  }
  return 0;
}

module.exports = { DEFAULT_FIXTURE, fixtureRepository, loadFixture, main };

if (require.main === module) {
  main().then((code) => {
    process.exitCode = code;
  }).catch((error) => {
    const message = error && typeof error.message === "string" && error.message.length > 0
      ? error.message
      : "observe failed";
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}
