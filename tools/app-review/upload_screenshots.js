#!/usr/bin/env node

"use strict";

// Eddie screenshot-upload adapter onto the shared Node app-review-submit engine.
//
// Exact engine argv is not invented here. Until the screenshot-upload SHA
// lands, SCREENSHOT_UPLOAD_ENGINE_ARGV stays unset and this adapter refuses
// closed. After that SHA, the workflow sets that env to a JSON array of
// strings and this adapter execs them from APP_REVIEW_ENGINE_DIR.
//
// This adapter never submits for review.

const { spawnSync } = require("node:child_process");
const assemble = require("./assemble_only");

function fail(message, exitCode = 1) {
  throw new assemble.AssembleError(message, exitCode);
}

function parseUploadArgv(argv) {
  const flags = argv.filter((value) => typeof value === "string" && value.startsWith("-"));
  if (flags.includes("--submit") || flags.includes("--submit=true")) {
    fail("refusing a submit flag; this adapter uploads screenshots only", 2);
  }
  if (flags.includes("--assemble-only") || flags.includes("--no-submit")) {
    fail("refusing an assemble-only flag; this adapter uploads screenshots only", 2);
  }
  if (flags.length > 0) fail(`unknown option ${flags[0]}`, 2);
  return Object.freeze({ upload: true });
}

function pinnedEngineArgv(env) {
  const raw = typeof env.SCREENSHOT_UPLOAD_ENGINE_ARGV === "string"
    ? env.SCREENSHOT_UPLOAD_ENGINE_ARGV.trim()
    : "";
  if (!raw) {
    fail(
      "screenshot upload CLI is not pinned; waiting for the engine SHA. "
        + "Set SCREENSHOT_UPLOAD_ENGINE_ARGV to a JSON array of strings. "
        + "Do not invent engine flags.",
      2,
    );
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail("SCREENSHOT_UPLOAD_ENGINE_ARGV must be a JSON array of strings", 2);
  }
  if (!Array.isArray(parsed) || parsed.length < 1) {
    fail("SCREENSHOT_UPLOAD_ENGINE_ARGV must be a JSON array of strings", 2);
  }
  const argv = parsed.map((item) => {
    if (typeof item !== "string" || item.length < 1) {
      fail("SCREENSHOT_UPLOAD_ENGINE_ARGV must be a JSON array of strings", 2);
    }
    return item;
  });
  if (argv.some((item) => item === "--submit" || item.startsWith("--submit="))) {
    fail("refusing a submit flag in SCREENSHOT_UPLOAD_ENGINE_ARGV", 2);
  }
  return Object.freeze(argv);
}

function runPinnedEngine(env, argv) {
  const engineDir = assemble.requiredEnv(env, "APP_REVIEW_ENGINE_DIR");
  const [command, ...args] = argv;
  const result = spawnSync(command, args, {
    cwd: engineDir,
    env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) fail(`screenshot upload engine failed to start: ${result.error.message}`);
  if (typeof result.stdout === "string" && result.stdout.length > 0) {
    process.stdout.write(result.stdout);
  }
  if (result.status !== 0) {
    fail("screenshot upload engine refused", result.status === null ? 1 : result.status);
  }
  return result;
}

async function runScreenshotUpload({ argv, env, runPinned } = {}) {
  const processEnv = env || process.env;
  parseUploadArgv(argv || process.argv.slice(2));
  assemble.trustedContext(processEnv);
  assemble.confirmedVersion(processEnv);
  const engineArgv = pinnedEngineArgv(processEnv);
  const runner = runPinned || runPinnedEngine;
  return runner(processEnv, engineArgv);
}

async function main(argv = process.argv.slice(2)) {
  try {
    await runScreenshotUpload({ argv });
    process.stdout.write(
      "help: Listing screenshots were uploaded without submitting. "
        + "The remaining action is a captain-gated mode=submit dispatch.\n",
    );
    return 0;
  } catch (error) {
    const message = error instanceof assemble.AssembleError
      ? error.message
      : (error && error.safeMessage) || "screenshot upload failed safely";
    process.stdout.write(`error:\n  message: ${JSON.stringify(message)}\n`);
    return error instanceof assemble.AssembleError ? error.exitCode : 1;
  }
}

module.exports = {
  parseUploadArgv,
  pinnedEngineArgv,
  runScreenshotUpload,
  main,
};

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
