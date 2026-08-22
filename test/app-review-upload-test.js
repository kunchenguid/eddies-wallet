#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
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
    RUNNER_TEMP: os.tmpdir(),
    EDDIES_APP_REVIEW_VERSION: "0.1.17",
    EDDIES_APP_REVIEW_CONFIRM: "0.1.17",
    APP_REVIEW_ENGINE_DIR: "/tmp/app-review-engine-not-used",
    APP_STORE_CONNECT_API_KEY: "test-key",
    APP_STORE_CONNECT_ISSUER_ID: "test-issuer",
    APP_STORE_CONNECT_KEY_ID: "test-key-id",
  };
}

async function main() {
  await test("upload refuses submit and assemble-only flags", () => {
    assert.throws(() => adapter.parseUploadArgv(["--submit"]), /refusing a submit flag/);
    assert.throws(
      () => adapter.parseUploadArgv(["--assemble-only"]),
      /refusing an assemble-only flag/,
    );
    assert.throws(() => adapter.parseUploadArgv(["--mystery"]), /unknown option/);
    assert.deepEqual(adapter.parseUploadArgv([]), { upload: true });
  });

  await test("unpinned engine argv refuses closed instead of inventing flags", () => {
    assert.throws(
      () => adapter.pinnedEngineArgv({}),
      /screenshot upload CLI is not pinned/,
    );
    assert.throws(
      () => adapter.pinnedEngineArgv({ SCREENSHOT_UPLOAD_ENGINE_ARGV: "not-json" }),
      /JSON array of strings/,
    );
    assert.throws(
      () => adapter.pinnedEngineArgv({ SCREENSHOT_UPLOAD_ENGINE_ARGV: '["--submit"]' }),
      /refusing a submit flag/,
    );
    assert.deepEqual(
      adapter.pinnedEngineArgv({ SCREENSHOT_UPLOAD_ENGINE_ARGV: '["node","upload.js"]' }),
      ["node", "upload.js"],
    );
  });

  await test("runScreenshotUpload execs the pinned argv and never submits", async () => {
    const env = {
      ...baseEnv(),
      SCREENSHOT_UPLOAD_ENGINE_ARGV: JSON.stringify(["node", "upload-screenshots.js", "--once"]),
    };
    const calls = [];
    await adapter.runScreenshotUpload({
      argv: [],
      env,
      runPinned: (processEnv, argv) => {
        calls.push({ argv, hasSubmitToken: Boolean(processEnv.APP_REVIEW_MONITOR_VARIABLE_TOKEN) });
        return { status: 0 };
      },
    });
    assert.deepEqual(calls, [{ argv: ["node", "upload-screenshots.js", "--once"], hasSubmitToken: false }]);
  });

  await test("runScreenshotUpload refuses when the CLI is not pinned", async () => {
    await assert.rejects(
      () => adapter.runScreenshotUpload({ argv: [], env: baseEnv(), runPinned: () => {
        throw new Error("must not start the engine");
      } }),
      /screenshot upload CLI is not pinned/,
    );
  });

  process.stdout.write("all screenshot-upload adapter tests passed\n");
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack || error}\n`);
  process.exitCode = 1;
});
