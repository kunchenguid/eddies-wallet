#!/usr/bin/env node

"use strict";

// Eddie create-version adapter onto the shared Node app-review-submit engine.
//
// Engine contract: listingPolicy stays observe. This CLI maps onto
// runSubmission({ createVersion: true }) and never submits. It is the
// no-evidence mutate lane that creates a missing App Store update version,
// its en-US localization including What's New, and listing screenshot sets
// a new version cannot inherit. The shared pipeline equivalent, pinned by
// CREATE_VERSION_ENGINE_ARGV, is `node app_review_pipeline.js create-version`.
// Assemble, upload, and submit stay evidence-gated.

const assemble = require("./assemble_only");

const CREATE_FLAGS = new Set(["--create-version", "--first-release"]);
const EXPECTED_ENGINE_ARGV = Object.freeze(["node", "app_review_pipeline.js", "create-version"]);

function fail(message, exitCode = 1) {
  throw new assemble.AssembleError(message, exitCode);
}

function parseEngineArgv(env) {
  const raw = env && env.CREATE_VERSION_ENGINE_ARGV;
  if (typeof raw !== "string" || raw.trim() === "") {
    fail("CREATE_VERSION_ENGINE_ARGV is required", 2);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    fail("CREATE_VERSION_ENGINE_ARGV must be a JSON argv array", 2);
  }
  const matches = Array.isArray(parsed)
    && parsed.length === EXPECTED_ENGINE_ARGV.length
    && EXPECTED_ENGINE_ARGV.every((value, index) => parsed[index] === value);
  if (!matches) {
    fail(
      "CREATE_VERSION_ENGINE_ARGV must be "
        + JSON.stringify(EXPECTED_ENGINE_ARGV),
      2,
    );
  }
  return Object.freeze([...parsed]);
}

function parseCreateVersionArgv(argv) {
  const flags = argv.filter((value) => typeof value === "string" && value.startsWith("-"));
  if (flags.includes("--submit") || flags.includes("--submit=true")) {
    fail("refusing a submit flag; this adapter creates a version only", 2);
  }
  if (flags.includes("--assemble-only") || flags.includes("--no-submit")) {
    fail("refusing an assemble-only flag; this adapter creates a version only", 2);
  }
  if (flags.includes("--upload-screenshots")) {
    fail("refusing an upload-screenshots flag; this adapter creates a version only", 2);
  }
  const unknown = flags.filter((flag) => !CREATE_FLAGS.has(flag));
  if (unknown.length > 0) fail(`unknown option ${unknown[0]}`, 2);
  if (!flags.includes("--create-version")) {
    fail("create-version is required (--create-version)", 2);
  }
  return Object.freeze({
    assembleOnly: false,
    uploadScreenshots: false,
    createVersion: true,
    firstRelease: flags.includes("--first-release"),
  });
}

async function runCreateVersion({
  argv,
  env,
  runSubmission,
  loadEngineModules,
  verifyEvidence,
  monitorVariable,
} = {}) {
  const processEnv = env || process.env;
  parseEngineArgv(processEnv);
  const parsed = parseCreateVersionArgv(argv || process.argv.slice(2));
  return assemble.runEngine({
    firstRelease: parsed.firstRelease,
    assembleOnly: false,
    uploadScreenshots: false,
    createVersion: true,
    env: processEnv,
    runSubmission,
    loadEngineModules,
    verifyEvidence,
    monitorVariable,
  });
}

async function main(argv = process.argv.slice(2), deps = {}) {
  const run = deps.runCreateVersion || runCreateVersion;
  try {
    const created = await run({ argv });
    process.stdout.write(created.output);
    process.stdout.write(
      "help: The missing App Store version was created without submitting. "
        + "Next is demo-preflight evidence, then a captain-gated mode=assemble dispatch.\n",
    );
    return 0;
  } catch (error) {
    return assemble.writeEngineError(error, "create-version failed safely");
  }
}

module.exports = {
  EXPECTED_ENGINE_ARGV,
  parseEngineArgv,
  parseCreateVersionArgv,
  runCreateVersion,
  main,
};

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
