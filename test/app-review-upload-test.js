#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const adapter = require(path.join(ROOT, "tools", "app-review", "upload_screenshots.js"));

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
    RUNNER_TEMP: fs.mkdtempSync(path.join(os.tmpdir(), "eddies-upload-")),
    EDDIES_APP_REVIEW_VERSION: "0.1.17",
    EDDIES_APP_REVIEW_CONFIRM: "0.1.17",
    EDDIES_APP_REVIEW_EVIDENCE: "not-used-when-verifyEvidence-is-injected",
    APP_STORE_CONNECT_API_KEY: "test-key",
    APP_STORE_CONNECT_ISSUER_ID: "test-issuer",
    APP_STORE_CONNECT_KEY_ID: "test-key-id",
    APP_REVIEW_CONFIG: path.join(ROOT, "tools", "app-review", "app-review.config.json"),
  };
}

async function main() {
  await test("upload requires --upload-screenshots and refuses submit", () => {
    assert.throws(() => adapter.parseUploadArgv([]), /screenshot upload is required/);
    assert.throws(() => adapter.parseUploadArgv(["--submit"]), /refusing a submit flag/);
    assert.throws(
      () => adapter.parseUploadArgv(["--upload-screenshots", "--assemble-only"]),
      /refusing an assemble-only flag/,
    );
    assert.throws(() => adapter.parseUploadArgv(["--mystery"]), /unknown option/);
    assert.deepEqual(
      adapter.parseUploadArgv(["--upload-screenshots", "--first-release"]),
      { assembleOnly: true, uploadScreenshots: true, firstRelease: true },
    );
  });

  await test("runScreenshotUpload passes uploadScreenshots and never submits", async () => {
    const env = baseEnv();
    const calls = [];
    await adapter.runScreenshotUpload({
      argv: ["--upload-screenshots", "--first-release"],
      env,
      verifyEvidence: () => undefined,
      loadEngineModules: () => ({
        formatSuccess: (result) => `status: ${result.status}\nsubmitted: ${result.submitted}\n`,
      }),
      runSubmission: async (args, credentials, dependencies) => {
        calls.push({ args, dependencies });
        assert.equal(args.assembleOnly, true);
        assert.equal(args.uploadScreenshots, true);
        assert.equal(args.firstRelease, true);
        assert.equal(args.baselineVersion, null);
        assert.equal(dependencies.monitorVariable, undefined);
        return {
          result: {
            status: "assembled",
            submitted: false,
            remaining: "submit",
            version: args.version,
            build: args.build,
          },
        };
      },
    });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].args.uploadScreenshots, true);
    assert.equal(calls[0].args.assembleOnly, true);
    assert.equal(calls[0].dependencies.monitorVariable, undefined);
  });

  await test("runScreenshotUpload refuses a submitted result", async () => {
    await assert.rejects(
      () => adapter.runScreenshotUpload({
        argv: ["--upload-screenshots", "--first-release"],
        env: baseEnv(),
        verifyEvidence: () => undefined,
        loadEngineModules: () => ({ formatSuccess: () => "" }),
        runSubmission: async () => ({
          result: {
            status: "submitted",
            submitted: true,
            remaining: null,
          },
        }),
      }),
      /did not prove an unsubmitted/,
    );
  });

  process.stdout.write("all screenshot-upload adapter tests passed\n");
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack || error}\n`);
  process.exitCode = 1;
});
