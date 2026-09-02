#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..");
const HARNESS = path.join(ROOT, "tools", "app-review", "observe_review_fixture.js");
const FIXTURE = path.join(ROOT, "tools", "app-review", "fixtures", "monitor", "multiple-submissions-0.1.17.json");

const FAKE_CONFIG = `
"use strict";
const fs = require("node:fs");
function record(entry) {
  const path = process.env.FAKE_ENGINE_LOG;
  if (!path) return;
  fs.appendFileSync(path, JSON.stringify({ module: "config", ...entry }) + "\\n");
}
function activateFromArgv(argv, env) {
  record({ fn: "activateFromArgv", hasConfig: Boolean(env && env.APP_REVIEW_CONFIG) });
}
module.exports = { activateFromArgv };
`;

const FAKE_MONITOR = `
"use strict";
const fs = require("node:fs");
function record(entry) {
  const path = process.env.FAKE_ENGINE_LOG;
  if (!path) return;
  fs.appendFileSync(path, JSON.stringify({ module: "monitor", ...entry }) + "\\n");
}
async function observeReviewStatus(repository, versionString) {
  await repository.loadApp();
  const versions = await repository.loadPlatformVersions();
  const submissions = await repository.loadSubmissions();
  record({
    fn: "observeReviewStatus",
    version: versionString,
    versionString: versions[0] && versions[0].attributes && versions[0].attributes.versionString,
    submissionStates: submissions.map((bundle) => bundle.submission.attributes.state),
    itemStates: submissions.flatMap((bundle) => bundle.items.map((item) => item.attributes.state)),
  });
  const old = submissions[0];
  const current = submissions[1];
  if (
    submissions.length === 2
    && old.submission.attributes.state === "COMPLETE"
    && old.items[0].attributes.state === "REMOVED"
    && current.submission.attributes.state === "UNRESOLVED_ISSUES"
    && current.items[0].attributes.state === "REJECTED"
  ) {
    const outcome = process.env.FAKE_OBSERVE_OUTCOME || "rejected";
    const terminal = process.env.FAKE_OBSERVE_TERMINAL !== "false";
    return Object.freeze({
      outcome,
      terminal,
      ...(outcome === "rejected"
        ? { rejectedItemKinds: Object.freeze(["app_store_version"]) }
        : {}),
    });
  }
  throw new Error("fixture was not the recorded double-submission rejection");
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
module.exports = { observeReviewStatus, runMonitor, MonitorIssueClient };
`;

function writeEngine(directory) {
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, "config.js"), FAKE_CONFIG);
  fs.writeFileSync(path.join(directory, "app_review_monitor.js"), FAKE_MONITOR);
}

function readLog(filePath) {
  if (!fs.existsSync(filePath)) return [];
  return fs.readFileSync(filePath, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

function runFixtureHarness(extraEnv = {}) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "observe-fixture-"));
  const engine = path.join(temp, "engine");
  writeEngine(engine);
  const completed = spawnSync("node", [HARNESS], {
    encoding: "utf8",
    cwd: ROOT,
    env: {
      ...process.env,
      APP_REVIEW_ENGINE_DIR: engine,
      APP_REVIEW_CONFIG: path.join(ROOT, "tools", "app-review", "app-review.config.json"),
      APP_REVIEW_FIXTURE: FIXTURE,
      APP_REVIEW_OBSERVE_VERSION: "0.1.17",
      ...extraEnv,
    },
  });
  fs.rmSync(temp, { recursive: true, force: true });
  return completed;
}

async function test(name, fn) {
  await fn();
  process.stdout.write(`ok ${name}\n`);
}

async function main() {
  await test("the recorded 8e9fbd18-shape fixture classifies as terminal rejected", () => {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), "observe-fixture-"));
    const engine = path.join(temp, "engine");
    const logPath = path.join(temp, "engine.log");
    writeEngine(engine);
    const completed = spawnSync("node", [HARNESS], {
      encoding: "utf8",
      cwd: ROOT,
      env: {
        ...process.env,
        APP_REVIEW_ENGINE_DIR: engine,
        APP_REVIEW_CONFIG: path.join(ROOT, "tools", "app-review", "app-review.config.json"),
        APP_REVIEW_FIXTURE: FIXTURE,
        APP_REVIEW_OBSERVE_VERSION: "0.1.17",
        APP_REVIEW_OBSERVE_EXPECTED: "rejected",
        APP_REVIEW_ENGINE_SHA: "216a65513dbde70d04d0efd021792743f094ed77",
        FAKE_ENGINE_LOG: logPath,
      },
    });
    assert.equal(completed.status, 0, completed.stderr);
    assert.match(completed.stdout, /outcome: "rejected"/);
    assert.match(completed.stdout, /terminal: true/);
    assert.match(completed.stdout, /app_store_version/);
    assert.match(completed.stdout, /multiple-submissions-0\.1\.17\.json/);
    const observe = readLog(logPath).find((entry) => entry.fn === "observeReviewStatus");
    assert.deepEqual(observe.submissionStates, ["COMPLETE", "UNRESOLVED_ISSUES"]);
    assert.deepEqual(observe.itemStates, ["REMOVED", "REJECTED"]);
    assert.equal(readLog(logPath).some((entry) => entry.fn === "runMonitor"), false);
    fs.rmSync(temp, { recursive: true, force: true });
  });

  await test("a terminal approved fixture observation is accepted", () => {
    const completed = runFixtureHarness({
      APP_REVIEW_OBSERVE_EXPECTED: "approved",
      FAKE_OBSERVE_OUTCOME: "approved",
      FAKE_OBSERVE_TERMINAL: "true",
    });
    assert.equal(completed.status, 0, completed.stderr);
    assert.match(completed.stdout, /outcome: "approved"/);
    assert.match(completed.stdout, /terminal: true/);
  });

  await test("a nonterminal approved fixture observation fails closed", () => {
    const completed = runFixtureHarness({
      APP_REVIEW_OBSERVE_EXPECTED: "approved",
      FAKE_OBSERVE_OUTCOME: "approved",
      FAKE_OBSERVE_TERMINAL: "false",
    });
    assert.notEqual(completed.status, 0);
    assert.match(completed.stdout, /outcome: "approved"/);
    assert.match(completed.stdout, /terminal: false/);
    assert.match(completed.stderr, /approved observation was not terminal/);
  });

  await test("the fixture file is the recorded double-submission rejection shape", () => {
    const fixture = JSON.parse(fs.readFileSync(FIXTURE, "utf8"));
    assert.equal(fixture.version.attributes.versionString, "0.1.17");
    assert.equal(fixture.version.attributes.appVersionState, "REJECTED");
    assert.equal(fixture.submissions.length, 2);
    assert.equal(fixture.submissions[0].submission.attributes.state, "COMPLETE");
    assert.equal(fixture.submissions[0].items[0].attributes.state, "REMOVED");
    assert.equal(fixture.submissions[1].submission.attributes.state, "UNRESOLVED_ISSUES");
    assert.equal(fixture.submissions[1].items[0].attributes.state, "REJECTED");
    const blob = JSON.stringify(fixture);
    assert.equal(blob.includes("8e9fbd18"), false);
    assert.equal(blob.includes("6795664301"), false);
  });

  await test("a missing engine fails closed", () => {
    const missing = path.join(os.tmpdir(), "missing-app-review-engine");
    const completed = spawnSync("node", [HARNESS], {
      encoding: "utf8",
      cwd: ROOT,
      env: {
        ...process.env,
        APP_REVIEW_ENGINE_DIR: missing,
        APP_REVIEW_FIXTURE: FIXTURE,
      },
    });
    assert.notEqual(completed.status, 0);
    assert.match(completed.stderr, /App Review engine is missing/);
  });
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
