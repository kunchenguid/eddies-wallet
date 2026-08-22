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
    SCREENSHOT_UPLOAD_ENGINE_ARGV: JSON.stringify(adapter.EXPECTED_ENGINE_ARGV),
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
      { assembleOnly: false, uploadScreenshots: true, firstRelease: true },
    );
  });

  await test("SCREENSHOT_UPLOAD_ENGINE_ARGV must be the engine upload-screenshots CLI", () => {
    assert.throws(() => adapter.parseEngineArgv({}), /SCREENSHOT_UPLOAD_ENGINE_ARGV is required/);
    assert.throws(
      () => adapter.parseEngineArgv({ SCREENSHOT_UPLOAD_ENGINE_ARGV: "not-json" }),
      /must be a JSON argv array/,
    );
    assert.throws(
      () => adapter.parseEngineArgv({
        SCREENSHOT_UPLOAD_ENGINE_ARGV: JSON.stringify(["node", "app_review_pipeline.js", "submit"]),
      }),
      /must be \["node","app_review_pipeline.js","upload-screenshots"\]/,
    );
    assert.deepEqual(
      adapter.parseEngineArgv({
        SCREENSHOT_UPLOAD_ENGINE_ARGV: '["node","app_review_pipeline.js","upload-screenshots"]',
      }),
      adapter.EXPECTED_ENGINE_ARGV,
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
        assert.equal(args.assembleOnly, false);
        assert.equal(args.uploadScreenshots, true);
        assert.equal(args.firstRelease, true);
        assert.equal(args.baselineVersion, null);
        assert.equal(dependencies.monitorVariable, undefined);
        return {
          result: {
            status: "screenshots_uploaded",
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
    assert.equal(calls[0].args.assembleOnly, false);
    assert.equal(calls[0].dependencies.monitorVariable, undefined);
  });

  await test("main prints engine SafeError fields to stdout", async () => {
    const chunks = [];
    const write = process.stdout.write.bind(process.stdout);
    process.stdout.write = (chunk, encoding, callback) => {
      chunks.push(typeof chunk === "string" ? chunk : chunk.toString());
      if (typeof encoding === "function") encoding();
      if (typeof callback === "function") callback();
      return true;
    };
    let exitCode;
    try {
      exitCode = await adapter.main(["--upload-screenshots"], {
        runScreenshotUpload: async () => {
          const error = new Error("internal");
          error.safeMessage = "App Store Connect rejected the bounded operation";
          error.code = "E_API";
          error.operation = "POST /v1/appScreenshots";
          error.httpStatus = 409;
          error.appleCode = "ENTITY_ERROR.RELATIONSHIP.INVALID";
          error.detail = "The request cannot be fulfilled because of a conflict.";
          throw error;
        },
      });
    } finally {
      process.stdout.write = write;
    }
    const output = chunks.join("");
    assert.equal(exitCode, 1);
    assert.match(output, /code: "E_API"/);
    assert.match(output, /operation: "POST \/v1\/appScreenshots"/);
    assert.match(output, /message: "App Store Connect rejected the bounded operation"/);
    assert.match(output, /httpStatus: 409/);
    assert.match(output, /appleCode: "ENTITY_ERROR.RELATIONSHIP.INVALID"/);
    assert.match(output, /detail: "The request cannot be fulfilled because of a conflict."/);
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
