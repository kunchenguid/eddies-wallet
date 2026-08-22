#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const adapter = require(path.join(ROOT, "tools", "app-review", "full_submit.js"));

async function test(name, fn) {
  await fn();
  process.stdout.write(`ok ${name}\n`);
}

function baseEnv() {
  return {
    GITHUB_REPOSITORY: "kunchenguid/eddies-wallet",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_WORKSPACE: ROOT,
    RUNNER_TEMP: fs.mkdtempSync(path.join(os.tmpdir(), "eddies-submit-")),
    EDDIES_APP_REVIEW_VERSION: "0.1.17",
    EDDIES_APP_REVIEW_CONFIRM: "0.1.17",
    EDDIES_APP_REVIEW_EVIDENCE: "not-used-when-verifyEvidence-is-injected",
    APP_STORE_CONNECT_API_KEY: "test-key",
    APP_STORE_CONNECT_ISSUER_ID: "test-issuer",
    APP_STORE_CONNECT_KEY_ID: "test-key-id",
    APP_REVIEW_MONITOR_VARIABLE_TOKEN: "test-monitor-token",
    APP_REVIEW_CONFIG: path.join(ROOT, "tools", "app-review", "app-review.config.json"),
  };
}

async function main() {
  await test("full submit requires --submit and refuses assemble-only flags", () => {
    assert.throws(() => adapter.parseSubmitArgv([]), /full submit is required/);
    assert.throws(() => adapter.parseSubmitArgv(["--assemble-only"]), /refusing an assemble-only flag/);
    assert.throws(() => adapter.parseSubmitArgv(["--no-submit"]), /refusing an assemble-only flag/);
    assert.throws(
      () => adapter.parseSubmitArgv(["--submit", "--assemble-only"]),
      /refusing an assemble-only flag/,
    );
    assert.deepEqual(
      adapter.parseSubmitArgv(["--submit", "--first-release"]),
      { assembleOnly: false, firstRelease: true },
    );
  });

  await test("runFullSubmit passes assembleOnly:false and requires a submitted result", async () => {
    const env = baseEnv();
    const calls = [];
    const monitorVariable = { read: async () => "0.1.17", write: async () => true };
    try {
      await adapter.runFullSubmit({
        argv: ["--submit", "--first-release"],
        env,
        verifyEvidence: () => undefined,
        monitorVariable,
        loadEngineModules: () => ({
          formatSuccess: (result) => `status: ${result.status}\n`,
        }),
        runSubmission: async (args, credentials, dependencies) => {
          calls.push({ args, dependencies });
          assert.equal(args.assembleOnly, false);
          assert.equal(args.firstRelease, true);
          assert.equal(args.baselineVersion, null);
          assert.equal(dependencies.monitorVariable, monitorVariable);
          return {
            result: {
              status: "submitted",
              version: args.version,
              build: args.build,
              submissionState: "WAITING_FOR_REVIEW",
              versionState: "WAITING_FOR_REVIEW",
            },
          };
        },
      });
      assert.equal(calls.length, 1);
      assert.equal(calls[0].args.assembleOnly, false);

      await assert.rejects(
        () => adapter.runFullSubmit({
          argv: ["--submit", "--first-release"],
          env,
          verifyEvidence: () => undefined,
          monitorVariable,
          loadEngineModules: () => ({ formatSuccess: () => "" }),
          runSubmission: async (args) => ({
            result: {
              status: "assembled",
              submitted: false,
              remaining: "submit",
              version: args.version,
              build: args.build,
            },
          }),
        }),
        /did not prove Apple accepted the review submission/,
      );
    } finally {
      fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
    }
  });

  await test("full submit refuses to start without the monitor variable token", async () => {
    const env = baseEnv();
    delete env.APP_REVIEW_MONITOR_VARIABLE_TOKEN;
    try {
      await assert.rejects(
        () => adapter.runFullSubmit({
          argv: ["--submit", "--first-release"],
          env,
          verifyEvidence: () => undefined,
          loadEngineModules: () => ({ formatSuccess: () => "" }),
          runSubmission: async () => {
            throw new Error("must not reach the engine");
          },
        }),
        /APP_REVIEW_MONITOR_VARIABLE_TOKEN is missing/,
      );
    } finally {
      fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
    }
  });

  await test("already_submitted is accepted as a successful full submit", async () => {
    const env = baseEnv();
    const monitorVariable = { read: async () => "0.1.17", write: async () => true };
    try {
      const outcome = await adapter.runFullSubmit({
        argv: ["--submit", "--first-release"],
        env,
        verifyEvidence: () => undefined,
        monitorVariable,
        loadEngineModules: () => ({
          formatSuccess: (result) => `status: ${result.status}\n`,
        }),
        runSubmission: async (args) => ({
          result: {
            status: "already_submitted",
            submitted: true,
            version: args.version,
            build: args.build,
            submissionState: "WAITING_FOR_REVIEW",
          },
        }),
      });
      assert.equal(outcome.result.status, "already_submitted");
      assert.equal(outcome.args.assembleOnly, false);
    } finally {
      fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
    }
  });

  process.stdout.write("all full-submit adapter tests passed\n");
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack || error}\n`);
  process.exitCode = 1;
});
