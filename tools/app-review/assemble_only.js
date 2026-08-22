#!/usr/bin/env node

"use strict";

// Eddie assemble-only adapter onto the shared Node app-review-submit engine.
//
// The engine's Actions pipeline (`app_review_pipeline.js assemble`) expects the
// shared manifest shape. Eddie maps its captain-approved manifest onto
// `runSubmission({ assembleOnly: true })`. This CLI is assemble-only: it
// requires `--assemble-only` and hard-refuses `--submit`. Screenshot upload and
// full submit are separate gated adapters.

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const EULA_URL = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/";
const EULA_LINE = `Terms of Use (EULA): ${EULA_URL}`;
const ANCHOR = (
  "You can manage or cancel subscriptions in your Apple Account settings "
  + "after purchase."
);
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

class AssembleError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.name = "AssembleError";
    this.exitCode = exitCode;
  }
}

function formatEngineError(error, fallbackMessage) {
  if (error instanceof AssembleError) {
    return `error:\n  message: ${JSON.stringify(error.message)}\n`;
  }
  const message = (error && error.safeMessage) || fallbackMessage;
  const lines = ["error:"];
  const push = (key, value) => {
    lines.push(`  ${key}: ${typeof value === "number" ? String(value) : JSON.stringify(value)}`);
  };
  if (error && typeof error.code === "string" && error.code) push("code", error.code);
  if (error && typeof error.operation === "string" && error.operation) push("operation", error.operation);
  push("message", message);
  if (error && Number.isInteger(error.httpStatus) && error.httpStatus > 0) push("httpStatus", error.httpStatus);
  if (error && typeof error.appleCode === "string" && error.appleCode && error.appleCode !== "NONE") {
    push("appleCode", error.appleCode);
  }
  if (error && typeof error.detail === "string" && error.detail) push("detail", error.detail);
  return `${lines.join("\n")}\n`;
}

function writeEngineError(error, fallbackMessage) {
  process.stdout.write(formatEngineError(error, fallbackMessage));
  return error instanceof AssembleError ? error.exitCode : 1;
}

function fail(message, exitCode = 1) {
  throw new AssembleError(message, exitCode);
}

const ASSEMBLE_FLAGS = new Set(["--assemble-only", "--no-submit", "--first-release"]);

function parseAssembleArgv(argv) {
  const flags = argv.filter((value) => typeof value === "string" && value.startsWith("-"));
  const unknown = flags.filter((flag) => !ASSEMBLE_FLAGS.has(flag) && !flag.startsWith("--submit"));
  if (unknown.length > 0) fail(`unknown option ${unknown[0]}`, 2);
  const assembleOnly = flags.includes("--assemble-only") || flags.includes("--no-submit");
  if (flags.includes("--submit") || flags.includes("--submit=true")) {
    fail("refusing a submit flag; this adapter is assemble-only", 2);
  }
  if (!assembleOnly) {
    fail("assemble-only is required (--assemble-only or --no-submit); refusing to invoke a submitting command", 2);
  }
  return Object.freeze({
    assembleOnly: true,
    firstRelease: flags.includes("--first-release"),
  });
}

function requiredEnv(env, name) {
  const value = typeof env[name] === "string" ? env[name].trim() : "";
  if (!value) fail(`${name} is missing`);
  return value;
}

function confirmedVersion(env) {
  const version = requiredEnv(env, "EDDIES_APP_REVIEW_VERSION");
  const confirm = requiredEnv(env, "EDDIES_APP_REVIEW_CONFIRM");
  if (!/^[0-9]+(?:\.[0-9]+){1,2}$/u.test(version)) {
    fail("the dispatched version is not an exact marketing version");
  }
  if (confirm !== version) {
    fail("the confirmation does not repeat the dispatched version exactly");
  }
  return version;
}

function trustedContext(env) {
  const repository = requiredEnv(env, "GITHUB_REPOSITORY");
  const reference = requiredEnv(env, "GITHUB_REF");
  const eventName = requiredEnv(env, "GITHUB_EVENT_NAME");
  if (repository !== "kunchenguid/eddies-wallet") {
    fail("this action runs only in kunchenguid/eddies-wallet");
  }
  if (reference !== "refs/heads/main") {
    fail("this action runs only from the trusted default branch");
  }
  if (eventName !== "workflow_dispatch") {
    fail("this action runs only from a trusted default-branch dispatch");
  }
}

function loadConfig(configPath) {
  const parsed = JSON.parse(fs.readFileSync(configPath, "utf8"));
  if (!parsed || typeof parsed !== "object") fail("app-review.config.json is not an object");
  if (parsed.app.appId !== "6795664301") fail("config app id does not match Eddie's Wallet");
  if (parsed.commerce.kind !== "subscriptions") fail("config commerce kind must be subscriptions");
  const productIds = parsed.commerce.productIds;
  if (!Array.isArray(productIds) || productIds.length !== 2) {
    fail("config must name both Cloud subscriptions");
  }
  const details = parsed.reviewDetails;
  if (!details || typeof details !== "object") fail("config.reviewDetails is required for first-release assembly");
  if (details.demoAccountRequired !== false) {
    fail("config.reviewDetails.demoAccountRequired must be false; Eddie uses reviewer-owned Sign in with Apple");
  }
  if (details.demoAccountName || details.demoAccountPassword) {
    fail("config.reviewDetails must not include a demo account name or password");
  }
  return parsed;
}

function loadManifest(sourceRoot, version) {
  const filePath = path.join(sourceRoot, "tools", "app-review", "manifests", `${version}.json`);
  const manifest = JSON.parse(fs.readFileSync(filePath, "utf8"));
  if (manifest.candidate.version !== version) {
    fail("the captain-approved manifest pins a different version");
  }
  if (manifest.app.appId !== "6795664301") fail("manifest app id does not match Eddie's Wallet");
  return manifest;
}

function descriptionWithAppliedEula(description) {
  if (typeof description !== "string" || description.length < 1) {
    fail("approved listing description is missing");
  }
  if (description.includes(EULA_URL)) return description;
  const index = description.indexOf(ANCHOR);
  if (index < 0) {
    fail("the auto-renewal paragraph was not found in the approved description; cannot match the already-applied EULA line");
  }
  const updated = `${description.slice(0, index + ANCHOR.length)}\n\n${EULA_LINE}${description.slice(index + ANCHOR.length)}`;
  if (updated.length > 4000) fail("appending the already-applied EULA line would exceed Apple's description limit");
  return updated;
}

function inspectPng(buffer, expectedWidth, expectedHeight, fileName) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 33) fail(`screenshot is too small: ${fileName}`);
  if (!buffer.subarray(0, 8).equals(PNG_SIGNATURE)) fail(`screenshot is not PNG: ${fileName}`);
  if (buffer.readUInt32BE(8) !== 13 || buffer.subarray(12, 16).toString("ascii") !== "IHDR") {
    fail(`screenshot header is malformed: ${fileName}`);
  }
  const width = buffer.readUInt32BE(16);
  const height = buffer.readUInt32BE(20);
  if (width !== expectedWidth || height !== expectedHeight) {
    fail(`screenshot dimensions do not match the approved slot: ${fileName}`);
  }
  if (buffer[24] !== 8 || buffer[25] !== 2 || buffer[26] !== 0 || buffer[27] !== 0 || buffer[28] !== 0) {
    fail(`screenshot must be RGB8 without alpha: ${fileName}`);
  }
  return { width, height };
}

function fileDescriptor(sourceRoot, relativePath, expected) {
  const filePath = path.join(sourceRoot, relativePath);
  const bytes = fs.readFileSync(filePath);
  const sha256 = crypto.createHash("sha256").update(bytes).digest("hex");
  const md5 = crypto.createHash("md5").update(bytes).digest("hex");
  if (expected.bytes != null && bytes.length !== expected.bytes) {
    fail(`reviewed file changed size since approval: ${relativePath}`);
  }
  if (expected.sha256 && sha256 !== expected.sha256) {
    fail(`reviewed file changed content since approval: ${relativePath}`);
  }
  return { bytes, sha256, md5, filePath, fileName: path.posix.basename(relativePath.replaceAll("\\", "/")) };
}

function screenshotPathByName(manifest) {
  const found = new Map();
  for (const set of manifest.content.screenshots) {
    for (const file of set.files) {
      const fileName = file.fileName;
      if (typeof fileName !== "string" || fileName.length < 1) {
        fail("screenshot fileName is missing");
      }
      if (found.has(fileName)) fail(`screenshot fileName is duplicated: ${fileName}`);
      found.set(fileName, file);
    }
  }
  return found;
}

function sha256Text(value) {
  return crypto.createHash("sha256").update(value ?? "", "utf8").digest("hex");
}

function stableHash(value) {
  const stable = (item) => {
    if (Array.isArray(item)) return item.map(stable);
    if (item !== null && typeof item === "object") {
      return Object.fromEntries(Object.keys(item).sort().map((key) => [key, stable(item[key])]));
    }
    return item;
  };
  return crypto.createHash("sha256").update(JSON.stringify(stable(value))).digest("hex");
}

function buildEngineSource(sourceRoot, manifest, config) {
  const listing = manifest.content.listing;
  const metadata = Object.freeze({
    appName: listing.appName,
    subtitle: listing.subtitle,
    promotionalText: listing.promotionalText,
    description: descriptionWithAppliedEula(listing.description),
    keywords: listing.keywords,
    privacyPolicyUrl: listing.privacyPolicyUrl,
    supportUrl: listing.supportUrl,
    marketingUrl: listing.marketingUrl || "",
    whatsNew: listing.whatsNew || null,
  });
  const screenshotWrites = config.listing && config.listing.screenshotWrites === true;
  const manifestWrites = manifest.listing && manifest.listing.screenshotWrites === true;
  if (screenshotWrites !== manifestWrites) {
    fail("config.listing.screenshotWrites must match the captain-approved manifest listing.screenshotWrites");
  }
  if (config.listingPolicy !== "observe") {
    fail("listingPolicy must stay observe so listing copy is never written");
  }
  const directory = Array.isArray(config.listing.screenshotDirectory)
    ? config.listing.screenshotDirectory
    : [];
  screenshotPathByName(manifest);
  const specs = config.listing.screenshotSpecs;
  const approvedSets = manifest.content.screenshots;
  if (specs.length !== approvedSets.length) {
    fail("config screenshot slots must exactly match the captain-approved manifest");
  }
  const screenshots = specs.map((spec, setIndex) => {
    const bound = approvedSets[setIndex];
    if (bound.displayType !== spec.displayType) {
      fail("config screenshot slot order must match the captain-approved manifest");
    }
    if (bound.width !== spec.width || bound.height !== spec.height) {
      fail(`manifest dimensions do not match screenshot spec ${spec.displayType}`);
    }
    const approvedNames = bound.files.map((file) => file.fileName);
    if (
      spec.files.length !== approvedNames.length
      || spec.files.some((fileName, index) => fileName !== approvedNames[index])
    ) {
      fail(`config screenshot order must match the captain-approved manifest for ${spec.displayType}`);
    }
    const files = spec.files.map((fileName, fileIndex) => {
      const descriptor = bound.files[fileIndex];
      const relativePath = [...directory, fileName].join("/");
      const file = fileDescriptor(sourceRoot, relativePath, {
        bytes: descriptor.fileSize,
        sha256: descriptor.sha256,
      });
      if (file.fileName !== fileName) fail(`screenshot fileName does not match path basename: ${relativePath}`);
      const dimensions = inspectPng(file.bytes, spec.width, spec.height, fileName);
      return Object.freeze({
        fileName,
        filePath: file.filePath,
        fileSize: file.bytes.length,
        md5: file.md5,
        sha256: file.sha256,
        ...dimensions,
      });
    });
    return Object.freeze({
      displayType: spec.displayType,
      width: spec.width,
      height: spec.height,
      files: Object.freeze(files),
    });
  });
  const content = Object.freeze({
    metadataHashes: Object.freeze(Object.fromEntries(
      Object.entries(metadata).map(([name, value]) => [name, sha256Text(value)]),
    )),
    screenshots: Object.freeze(screenshots.map((set) => Object.freeze({
      displayType: set.displayType,
      width: set.width,
      height: set.height,
      files: Object.freeze(set.files.map((file) => Object.freeze({
        fileName: file.fileName,
        fileSize: file.fileSize,
        sha256: file.sha256,
      }))),
    }))),
  });
  return Object.freeze({
    metadata,
    screenshots: Object.freeze(screenshots),
    content,
    contentHash: stableHash(content),
    listing: Object.freeze({ screenshotWrites }),
  });
}

function verifyEddieEvidence(env, toolsDir) {
  const script = [
    "import os, sys",
    "from datetime import datetime, timezone",
    "sys.path.insert(0, os.environ['EDDIE_APP_REVIEW_TOOLS'])",
    "import evidence, runtime",
    "manifest = runtime.load_manifest(os.environ['EDDIES_APP_REVIEW_VERSION'])",
    "evidence.verify(os.environ['EDDIES_APP_REVIEW_EVIDENCE'], manifest, now=datetime.now(timezone.utc))",
    "print('ok')",
  ].join(";");
  const child = spawnSync("python3", ["-c", script], {
    cwd: env.GITHUB_WORKSPACE,
    env: { ...env, EDDIE_APP_REVIEW_TOOLS: toolsDir },
    encoding: "utf8",
    timeout: 30_000,
  });
  if (child.status !== 0 || !String(child.stdout || "").includes("ok")) {
    const detail = String(child.stderr || child.stdout || "evidence verification failed").trim().slice(0, 220);
    fail(detail || "readiness evidence is not fresh and bound to this candidate");
  }
}

function ownerOnlyDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.chmodSync(directory, 0o700);
  return directory;
}

function writeOwnerOnlyFile(filePath, contents) {
  fs.writeFileSync(filePath, contents, { encoding: "utf8", mode: 0o600 });
  fs.chmodSync(filePath, 0o600);
  return filePath;
}

function loadEngine(engineDir, configPath) {
  const configModule = require(path.join(engineDir, "config.js"));
  configModule.setActiveConfig(configPath);
  return require(path.join(engineDir, "app_review_submit.js"));
}

function assertAssembled(result, { screenshotWrites = false } = {}) {
  const remaining = screenshotWrites ? "upload-screenshots" : "submit";
  if (!result || result.status !== "assembled" || result.submitted !== false || result.remaining !== remaining) {
    fail(
      "assemble-only did not prove an unsubmitted review submission "
      + `(status=${result && result.status}, submitted=${result && result.submitted}, remaining=${result && result.remaining})`,
    );
  }
}

function assertUploaded(result) {
  if (!result || result.status !== "screenshots_uploaded" || result.submitted !== false || result.remaining !== "submit") {
    fail(
      "screenshot upload did not prove an unsubmitted review submission "
      + `(status=${result && result.status}, submitted=${result && result.submitted}, remaining=${result && result.remaining})`,
    );
  }
}

function assertSubmitted(result) {
  const accepted = result && (result.status === "submitted" || result.status === "already_submitted");
  if (!accepted || result.submitted === false) {
    fail(
      "full submit did not prove Apple accepted the review submission "
      + `(status=${result && result.status}, submitted=${result && result.submitted})`,
    );
  }
}

function loadMonitorVariable(engineDir, token) {
  const pipeline = require(path.join(engineDir, "app_review_pipeline.js"));
  return new pipeline.MonitorVariableClient(new pipeline.GitHubRecordClient(token));
}

async function runEngine({
  firstRelease: firstReleaseFlag,
  assembleOnly,
  uploadScreenshots = false,
  env,
  runSubmission,
  loadEngineModules,
  verifyEvidence,
  monitorVariable,
} = {}) {
  if (assembleOnly !== true && assembleOnly !== false) {
    fail("assembleOnly must be an explicit boolean");
  }
  if (uploadScreenshots && assembleOnly) {
    fail("screenshot upload cannot be combined with assemble-only");
  }
  const processEnv = env || process.env;
  trustedContext(processEnv);
  const version = confirmedVersion(processEnv);
  const sourceRoot = fs.realpathSync(requiredEnv(processEnv, "GITHUB_WORKSPACE"));
  const configPath = processEnv.APP_REVIEW_CONFIG || path.join(sourceRoot, "tools", "app-review", "app-review.config.json");
  const engineDir = processEnv.APP_REVIEW_ENGINE_DIR || path.join(sourceRoot, ".app-review-submit");
  const toolsDir = path.join(sourceRoot, "tools", "app-review");
  const config = loadConfig(configPath);
  const manifest = loadManifest(sourceRoot, version);
  const firstRelease = manifest.candidate.firstRelease === true;
  if (firstRelease !== Boolean(firstReleaseFlag)) {
    fail(
      firstRelease
        ? "first-release manifest requires --first-release"
        : "--first-release is only valid for a first-release manifest",
    );
  }
  if (firstRelease && manifest.candidate.baselineVersion != null) {
    fail("first-release manifest must omit baselineVersion");
  }
  if (!firstRelease && (manifest.candidate.baselineVersion == null || manifest.candidate.baselineVersion === "")) {
    fail("update manifest requires baselineVersion");
  }
  (verifyEvidence || verifyEddieEvidence)(processEnv, toolsDir);
  const source = buildEngineSource(sourceRoot, manifest, config);

  const scratch = ownerOnlyDirectory(path.join(
    processEnv.RUNNER_TEMP || path.join(sourceRoot, ".build"),
    uploadScreenshots
      ? "eddies-app-review-upload"
      : (assembleOnly ? "eddies-app-review-assemble" : "eddies-app-review-submit"),
  ));
  const journal = path.join(scratch, "journal.json");
  const evidencePath = writeOwnerOnlyFile(path.join(scratch, "evidence.json"), "{}\n");
  const whatsNewFile = writeOwnerOnlyFile(
    path.join(scratch, "whats-new.txt"),
    `${source.metadata.whatsNew ?? ""}\n`,
  );
  const sourceCommit = (
    processEnv.EDDIES_APP_REVIEW_APPROVED_COMMIT
    || manifest.candidate.sourceCommit
  ).toLowerCase();

  const args = Object.freeze({
    version,
    build: manifest.candidate.build,
    baselineVersion: firstRelease ? null : manifest.candidate.baselineVersion,
    firstRelease,
    reviewCycle: version,
    sourceRoot,
    sourceCommit,
    whatsNewFile,
    evidence: evidencePath,
    journal,
    diagnosticTraceDir: null,
    expectedReleaseType: manifest.candidate.releaseType,
    preflight: false,
    assembleOnly,
    uploadScreenshots: Boolean(uploadScreenshots),
    resume: false,
  });
  if (args.assembleOnly !== assembleOnly) fail("internal adapter dropped assembleOnly");
  if (args.uploadScreenshots !== Boolean(uploadScreenshots)) {
    fail("internal adapter dropped uploadScreenshots");
  }
  if (uploadScreenshots && source.listing.screenshotWrites !== true) {
    fail("screenshot upload requires listing.screenshotWrites=true");
  }
  if (firstRelease && (args.firstRelease !== true || args.baselineVersion !== null)) {
    fail("internal adapter dropped first-release mode");
  }

  const engine = loadEngineModules
    ? loadEngineModules()
    : loadEngine(engineDir, configPath);
  let handoff = monitorVariable;
  if (!assembleOnly && !uploadScreenshots && !handoff) {
    const tokenName = config.env && config.env.monitorVariableToken;
    if (!tokenName) fail("config.env.monitorVariableToken is required for full submit");
    handoff = loadMonitorVariable(engineDir, requiredEnv(processEnv, tokenName));
  }
  const submit = runSubmission || engine.runSubmission;
  const credentials = Object.freeze({
    apiKey: requiredEnv(processEnv, "APP_STORE_CONNECT_API_KEY"),
    issuerId: requiredEnv(processEnv, "APP_STORE_CONNECT_ISSUER_ID"),
    keyId: requiredEnv(processEnv, "APP_STORE_CONNECT_KEY_ID"),
  });
  const outcome = await submit(args, credentials, {
    source,
    env: {},
    verifyEvidence: () => true,
    ...(assembleOnly || uploadScreenshots ? {} : { monitorVariable: handoff }),
  });
  const result = outcome && outcome.result ? outcome.result : outcome;
  if (uploadScreenshots) assertUploaded(result);
  else if (assembleOnly) {
    assertAssembled(result, { screenshotWrites: source.listing.screenshotWrites === true });
  } else assertSubmitted(result);
  const output = engine && engine.formatSuccess
    ? engine.formatSuccess(result, journal)
    : JSON.stringify({
      status: result.status,
      submitted: result.submitted,
      remaining: result.remaining,
      version: result.version,
      build: result.build,
    }, null, 2) + "\n";
  return Object.freeze({ args, result, output, source });
}

async function runAssemble({ argv, env, runSubmission, loadEngineModules, verifyEvidence, monitorVariable } = {}) {
  const parsed = parseAssembleArgv(argv || process.argv.slice(2));
  return runEngine({
    firstRelease: parsed.firstRelease,
    assembleOnly: true,
    env,
    runSubmission,
    loadEngineModules,
    verifyEvidence,
    monitorVariable,
  });
}

async function main(argv = process.argv.slice(2)) {
  try {
    const assembled = await runAssemble({ argv });
    process.stdout.write(assembled.output);
    const next = assembled.source && assembled.source.listing && assembled.source.listing.screenshotWrites
      ? "a captain-gated mode=upload dispatch"
      : "a captain-gated mode=submit dispatch";
    process.stdout.write(
      "help: Review submission is assembled and unsubmitted. "
      + `The remaining action is ${next}.\n`,
    );
    return 0;
  } catch (error) {
    return writeEngineError(error, "assemble-only failed safely");
  }
}

module.exports = {
  ANCHOR,
  EULA_LINE,
  EULA_URL,
  AssembleError,
  formatEngineError,
  writeEngineError,
  assertAssembled,
  assertUploaded,
  assertSubmitted,
  buildEngineSource,
  confirmedVersion,
  descriptionWithAppliedEula,
  fail,
  loadConfig,
  loadManifest,
  parseAssembleArgv,
  requiredEnv,
  runAssemble,
  runEngine,
  trustedContext,
  main,
};

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
