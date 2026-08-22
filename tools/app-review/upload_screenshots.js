#!/usr/bin/env node

"use strict";

// Eddie screenshot-upload adapter onto the shared Node app-review-submit engine.
//
// Engine contract: listingPolicy stays observe (copy never written). Opt-in is
// listing.screenshotWrites=true. This CLI maps onto
// runSubmission({ uploadScreenshots: true }) and never submits. The shared
// pipeline equivalent, pinned by SCREENSHOT_UPLOAD_ENGINE_ARGV, is
// `node app_review_pipeline.js upload-screenshots`. The engine forbids combining
// that lane with assemble-only.

const assemble = require("./assemble_only");

const UPLOAD_FLAGS = new Set(["--upload-screenshots", "--first-release"]);
const EXPECTED_ENGINE_ARGV = Object.freeze(["node", "app_review_pipeline.js", "upload-screenshots"]);

function fail(message, exitCode = 1) {
  throw new assemble.AssembleError(message, exitCode);
}

function parseEngineArgv(env) {
  const raw = env && env.SCREENSHOT_UPLOAD_ENGINE_ARGV;
  if (typeof raw !== "string" || raw.trim() === "") {
    fail("SCREENSHOT_UPLOAD_ENGINE_ARGV is required", 2);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail("SCREENSHOT_UPLOAD_ENGINE_ARGV must be a JSON argv array", 2);
  }
  const matches = Array.isArray(parsed)
    && parsed.length === EXPECTED_ENGINE_ARGV.length
    && EXPECTED_ENGINE_ARGV.every((value, index) => parsed[index] === value);
  if (!matches) {
    fail(
      "SCREENSHOT_UPLOAD_ENGINE_ARGV must be "
        + JSON.stringify(EXPECTED_ENGINE_ARGV),
      2,
    );
  }
  return Object.freeze([...parsed]);
}

function parseUploadArgv(argv) {
  const flags = argv.filter((value) => typeof value === "string" && value.startsWith("-"));
  if (flags.includes("--submit") || flags.includes("--submit=true")) {
    fail("refusing a submit flag; this adapter uploads screenshots only", 2);
  }
  if (flags.includes("--assemble-only") || flags.includes("--no-submit")) {
    fail("refusing an assemble-only flag; this adapter uploads screenshots only", 2);
  }
  const unknown = flags.filter((flag) => !UPLOAD_FLAGS.has(flag));
  if (unknown.length > 0) fail(`unknown option ${unknown[0]}`, 2);
  if (!flags.includes("--upload-screenshots")) {
    fail("screenshot upload is required (--upload-screenshots)", 2);
  }
  return Object.freeze({
    assembleOnly: false,
    uploadScreenshots: true,
    firstRelease: flags.includes("--first-release"),
  });
}

async function runScreenshotUpload({
  argv,
  env,
  runSubmission,
  loadEngineModules,
  verifyEvidence,
  monitorVariable,
} = {}) {
  const processEnv = env || process.env;
  parseEngineArgv(processEnv);
  const parsed = parseUploadArgv(argv || process.argv.slice(2));
  return assemble.runEngine({
    firstRelease: parsed.firstRelease,
    assembleOnly: false,
    uploadScreenshots: true,
    env: processEnv,
    runSubmission,
    loadEngineModules,
    verifyEvidence,
    monitorVariable,
  });
}

async function main(argv = process.argv.slice(2), deps = {}) {
  const run = deps.runScreenshotUpload || runScreenshotUpload;
  try {
    const uploaded = await run({ argv });
    process.stdout.write(uploaded.output);
    process.stdout.write(
      "help: Listing screenshots were uploaded without submitting. "
        + "The remaining action is a captain-gated mode=assemble dispatch.\n",
    );
    return 0;
  } catch (error) {
    return assemble.writeEngineError(error, "screenshot upload failed safely");
  }
}

module.exports = {
  EXPECTED_ENGINE_ARGV,
  parseEngineArgv,
  parseUploadArgv,
  runScreenshotUpload,
  main,
};

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
