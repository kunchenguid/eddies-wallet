#!/usr/bin/env node

"use strict";

// Eddie full-submit adapter onto the shared Node app-review-submit engine.
//
// `assemble_only.js` refuses `--submit` by design. This CLI is the gated path
// that calls the same `runSubmission` engine with `assembleOnly: false`, which
// is the engine's real submit. Eddie cannot invoke the shared pipeline submit
// subcommand directly: that pipeline expects the shared manifest shape, not
// Eddie's captain-approved candidate manifest.
//
// After Apple accepts, the engine completes monitor handoff by writing
// `APP_REVIEW_MONITOR_VERSION`. This adapter injects that write so a successful
// Apple submit cannot split from an incomplete handoff.

const assemble = require("./assemble_only");

const SUBMIT_FLAGS = new Set(["--submit", "--first-release"]);

function fail(message, exitCode = 1) {
  throw new assemble.AssembleError(message, exitCode);
}

function parseSubmitArgv(argv) {
  const flags = argv.filter((value) => typeof value === "string" && value.startsWith("-"));
  if (flags.includes("--assemble-only") || flags.includes("--no-submit")) {
    fail("refusing an assemble-only flag; this adapter is full submit", 2);
  }
  const unknown = flags.filter((flag) => !SUBMIT_FLAGS.has(flag));
  if (unknown.length > 0) fail(`unknown option ${unknown[0]}`, 2);
  if (!flags.includes("--submit")) {
    fail("full submit is required (--submit); refusing to invoke assemble-only", 2);
  }
  return Object.freeze({
    assembleOnly: false,
    firstRelease: flags.includes("--first-release"),
  });
}

async function runFullSubmit({ argv, env, runSubmission, loadEngineModules, verifyEvidence, monitorVariable } = {}) {
  const parsed = parseSubmitArgv(argv || process.argv.slice(2));
  return assemble.runEngine({
    firstRelease: parsed.firstRelease,
    assembleOnly: false,
    env,
    runSubmission,
    loadEngineModules,
    verifyEvidence,
    monitorVariable,
  });
}

async function main(argv = process.argv.slice(2)) {
  try {
    const submitted = await runFullSubmit({ argv });
    process.stdout.write(submitted.output);
    const result = submitted.result || {};
    process.stdout.write(
      `submit: status=${result.status} submitted=${result.submitted} `
      + `submissionState=${result.submissionState} versionState=${result.versionState}\n`,
    );
    process.stdout.write(
      "help: Review submission was sent to Apple. "
      + "The engine armed APP_REVIEW_MONITOR_VERSION after Apple accepted.\n",
    );
    return 0;
  } catch (error) {
    const message = error instanceof assemble.AssembleError
      ? error.message
      : (error && error.safeMessage) || "full submit failed safely";
    process.stdout.write(`error:\n  message: ${JSON.stringify(message)}\n`);
    return error instanceof assemble.AssembleError ? error.exitCode : 1;
  }
}

module.exports = {
  parseSubmitArgv,
  runFullSubmit,
  main,
};

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
