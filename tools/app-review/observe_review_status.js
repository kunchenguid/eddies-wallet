#!/usr/bin/env node
"use strict";

// GET-only live classifier for one App Store marketing version.
//
// Reconstructs the shared app-review-submit read-only client the way
// app_review_pipeline.js / runMonitor does (activate config, load ASC
// credentials, ApiClient { readOnly: true }, AppStoreRepository), then
// calls the engine's exported observeReviewStatus. It never loads
// app_review_pipeline.js, never calls runMonitor/status, and never
// constructs a GitHub issue client.
//
// This script is the executable behind app-review-monitor-e2e.yml.

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

function fail(message) {
  const error = new Error(message);
  error.code = "E_OBSERVE";
  throw error;
}

function requiredEnv(env, name) {
  const value = typeof env[name] === "string" ? env[name].trim() : "";
  if (value.length === 0 || value.includes("\0")) {
    fail(`${name} is missing or invalid`);
  }
  return value;
}

function loadCredentials(monitor, env) {
  if (typeof monitor.loadAscCredentials === "function") {
    return monitor.loadAscCredentials(env);
  }
  return Object.freeze({
    apiKey: requiredEnv(env, "APP_STORE_CONNECT_API_KEY"),
    issuerId: requiredEnv(env, "APP_STORE_CONNECT_ISSUER_ID"),
    keyId: requiredEnv(env, "APP_STORE_CONNECT_KEY_ID"),
  });
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
  const submit = require(path.join(engineDir, "app_review_submit.js"));
  const monitor = require(monitorPath);

  if (typeof config.activateFromArgv !== "function") {
    fail("engine config.activateFromArgv is missing");
  }
  if (typeof submit.ApiClient !== "function" || typeof submit.AppStoreRepository !== "function") {
    fail("engine ApiClient/AppStoreRepository is missing");
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

  const credentials = loadCredentials(monitor, env);
  const client = new submit.ApiClient(credentials, { readOnly: true });
  if (client.readOnly !== true) {
    fail("ApiClient was not constructed read-only");
  }
  const repository = new submit.AppStoreRepository(client, { version });
  const observation = await monitor.observeReviewStatus(repository, version);
  if (!observation || typeof observation !== "object" || typeof observation.outcome !== "string") {
    fail("observeReviewStatus returned an invalid observation");
  }

  const payload = {
    version,
    outcome: observation.outcome,
    terminal: observation.terminal === true,
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

module.exports = { main };

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
