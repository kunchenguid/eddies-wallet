#!/usr/bin/env node

"use strict";

// Eddie screenshot-upload adapter onto the shared Node app-review-submit engine.
//
// Engine contract: listingPolicy stays observe (copy never written). Opt-in is
// listing.screenshotWrites=true. This CLI maps onto
// runSubmission({ uploadScreenshots: true, assembleOnly: true }) and never
// submits. The shared pipeline equivalent is
// `app_review_pipeline.js upload-screenshots`.
//
// Checkout pin stays on the current assemble SHA until the screenshot-upload
// engine merge SHA is provided.

const assemble = require("./assemble_only");

const UPLOAD_FLAGS = new Set(["--upload-screenshots", "--first-release"]);

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
  const unknown = flags.filter((flag) => !UPLOAD_FLAGS.has(flag));
  if (unknown.length > 0) fail(`unknown option ${unknown[0]}`, 2);
  if (!flags.includes("--upload-screenshots")) {
    fail("screenshot upload is required (--upload-screenshots)", 2);
  }
  return Object.freeze({
    assembleOnly: true,
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
  const parsed = parseUploadArgv(argv || process.argv.slice(2));
  return assemble.runEngine({
    firstRelease: parsed.firstRelease,
    assembleOnly: true,
    uploadScreenshots: true,
    env,
    runSubmission,
    loadEngineModules,
    verifyEvidence,
    monitorVariable,
  });
}

async function main(argv = process.argv.slice(2)) {
  try {
    const uploaded = await runScreenshotUpload({ argv });
    process.stdout.write(uploaded.output);
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
  runScreenshotUpload,
  main,
};

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
