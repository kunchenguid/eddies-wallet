#!/usr/bin/env node

"use strict";

// App Review preparation and submission owner for trusted default-branch
// GitHub Actions. It does not run app-owned evidence probes or cleanup.
//
// README.md is the operator contract.

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const {
  SafeError,
  formatError,
  loadSource,
  runSubmission,
  sha256,
  stableHash,
  toonObject,
} = require("./app_review_submit.js");
const { activateFromArgv, getActiveConfig, onChange } = require("./config");
const { EVIDENCE_MAX_AGE_MS, validateEvidenceEnvelope } = require("./evidence");
const monitor = require("./app_review_monitor.js");

let APP_ID;
let BUNDLE_ID;
let PLATFORM;
let SCREENSHOT_SPECS;
let REPOSITORY;
let DEFAULT_BRANCH_REF;
let MANIFEST_SCHEMA_VERSION;
let MANIFEST_BINDING_ALGORITHM;
let MANIFEST_DIRECTORY;
let MONITOR_VARIABLE;
let RECORD_MARKER_PREFIX;
let ISSUE_TITLE_TEMPLATE;
let SCRATCH_PREFIX;
let ENV_VERSION;
let ENV_CONFIRM;
let ENV_EVIDENCE;
let ENV_MONITOR_TOKEN;
function refreshPipelineConfig(config = getActiveConfig()) {
  APP_ID = config.app.appId;
  BUNDLE_ID = config.app.bundleId;
  PLATFORM = config.app.platform;
  SCREENSHOT_SPECS = config.listing.screenshotSpecs;
  REPOSITORY = config.github.repository;
  DEFAULT_BRANCH_REF = config.github.defaultBranchRef;
  MANIFEST_SCHEMA_VERSION = config.manifest.schemaVersion;
  MANIFEST_BINDING_ALGORITHM = config.manifest.bindingAlgorithm;
  MANIFEST_DIRECTORY = config.manifest.directory;
  MONITOR_VARIABLE = config.monitor.variableName;
  RECORD_MARKER_PREFIX = config.journal.recordMarkerPrefix;
  ISSUE_TITLE_TEMPLATE = config.journal.issueTitleTemplate;
  SCRATCH_PREFIX = config.journal.scratchPrefix;
  ENV_VERSION = config.env.version;
  ENV_CONFIRM = config.env.confirm;
  ENV_EVIDENCE = config.env.evidence;
  ENV_MONITOR_TOKEN = config.env.monitorVariableToken;
}
refreshPipelineConfig();
onChange(refreshPipelineConfig);

const GITHUB_ORIGIN = "https://api.github.com";
const GITHUB_API_VERSION = "2022-11-28";
const REQUEST_TIMEOUT_MS = 20_000;
const MAX_RESPONSE_BYTES = 1024 * 1024;
const MAX_ISSUE_PAGES = 10;
const ISSUES_PER_PAGE = 100;
const BOOKKEEPING_LABEL = "automation";

const MANIFEST_MAX_BYTES = 256 * 1024;
const RECORD_SCHEMA_VERSION = 1;
const GITHUB_ACTIONS_ACTOR = "github-actions[bot]";
const EVIDENCE_MAX_BYTES = 256 * 1024;
const CLOCK_SKEW_MS = 5 * 60 * 1_000;
const JOURNAL_STATE_MAX_BYTES = 64 * 1024;

const RELEASE_TYPES = Object.freeze(new Set(["MANUAL", "AFTER_APPROVAL"]));
const METADATA_FIELDS = Object.freeze([
  "appName",
  "subtitle",
  "promotionalText",
  "description",
  "keywords",
  "privacyPolicyUrl",
  "supportUrl",
  "whatsNew",
]);
const APP_STORE_CREDENTIAL_FIELDS = Object.freeze([
  "APP_STORE_CONNECT_API_KEY",
  "APP_STORE_CONNECT_ISSUER_ID",
  "APP_STORE_CONNECT_KEY_ID",
]);
const SUBCOMMANDS = Object.freeze(["compute-manifest", "verify-manifest", "prepare", "preflight", "submit", "monitor", "status"]);

const VERSION_PATTERN = /^[0-9]+(?:\.[0-9]+){1,2}$/u;
const BUILD_PATTERN = /^[0-9]+(?:\.[0-9]+){0,2}$/u;
const CYCLE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u;
const HEX_256_PATTERN = /^[0-9a-f]{64}$/u;
const COMMIT_PATTERN = /^[0-9a-f]{40}$/u;
const SAFE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/u;
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/u;

class PipelineFailure extends Error {
  constructor(code, message) {
    super(message);
    this.name = "PipelineFailure";
    this.code = code;
  }
}

function fail(code, message) {
  throw new PipelineFailure(code, message);
}

function ensure(condition, code, message) {
  if (!condition) fail(code, message);
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function exactKeys(value, keys, code, message) {
  ensure(isObject(value), code, message);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  ensure(actual.length === expected.length && actual.every((name, index) => name === expected[index]), code, message);
}

function parseJson(text, code, message) {
  try {
    return JSON.parse(text);
  } catch {
    return fail(code, message);
  }
}

function validTimestamp(value, nowMs) {
  if (typeof value !== "string" || value.length < 20 || value.length > 32) return false;
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) return false;
  return parsed <= nowMs + CLOCK_SKEW_MS;
}

// -- captain-approval manifest -------------------------------------------------

function manifestRelativePath(version) {
  ensure(VERSION_PATTERN.test(version), "E_MANIFEST", "manifest version is invalid");
  return `${MANIFEST_DIRECTORY.join("/")}/${version}.json`;
}

function manifestFilePath(sourceRoot, version) {
  ensure(VERSION_PATTERN.test(version), "E_MANIFEST", "manifest version is invalid");
  return path.join(sourceRoot, ...MANIFEST_DIRECTORY, `${version}.json`);
}

function manifestBindingInput(manifest) {
  const copy = { ...manifest };
  delete copy.binding;
  return copy;
}

function computeManifestHash(manifest) {
  return stableHash(manifestBindingInput(manifest));
}

function validateContentBlock(content) {
  exactKeys(content, ["metadataHashes", "screenshots"], "E_MANIFEST", "manifest content block is malformed");
  exactKeys(content.metadataHashes, METADATA_FIELDS, "E_MANIFEST", "manifest metadata hashes are malformed");
  for (const field of METADATA_FIELDS) {
    ensure(HEX_256_PATTERN.test(content.metadataHashes[field]), "E_MANIFEST", "manifest metadata hash is malformed");
  }
  ensure(Array.isArray(content.screenshots) && content.screenshots.length === SCREENSHOT_SPECS.length, "E_MANIFEST", "manifest screenshot sets do not match the approved slots");
  content.screenshots.forEach((set, index) => {
    const spec = SCREENSHOT_SPECS[index];
    exactKeys(set, ["displayType", "width", "height", "files"], "E_MANIFEST", "manifest screenshot set is malformed");
    ensure(set.displayType === spec.displayType && set.width === spec.width && set.height === spec.height, "E_MANIFEST", "manifest screenshot set does not match the approved slot");
    ensure(Array.isArray(set.files) && set.files.length === spec.files.length, "E_MANIFEST", "manifest screenshot count does not match the approved slot");
    set.files.forEach((file, fileIndex) => {
      exactKeys(file, ["fileName", "fileSize", "sha256"], "E_MANIFEST", "manifest screenshot entry is malformed");
      ensure(file.fileName === spec.files[fileIndex], "E_MANIFEST", "manifest screenshot order does not match the approved slot");
      ensure(Number.isSafeInteger(file.fileSize) && file.fileSize > 0 && file.fileSize <= 32 * 1024 * 1024, "E_MANIFEST", "manifest screenshot size is invalid");
      ensure(HEX_256_PATTERN.test(file.sha256), "E_MANIFEST", "manifest screenshot digest is malformed");
    });
  });
}

function validateManifest(value, nowMs) {
  ensure(isObject(value), "E_MANIFEST", "manifest is not a JSON object");
  exactKeys(value, ["schemaVersion", "app", "release", "whatsNew", "content", "contentHash", "approval", "binding"], "E_MANIFEST", "manifest top-level fields are unsupported or incomplete");
  ensure(value.schemaVersion === MANIFEST_SCHEMA_VERSION, "E_MANIFEST", "manifest schema version is unsupported");

  exactKeys(value.app, ["appId", "bundleId", "platform"], "E_MANIFEST", "manifest app block is malformed");
  ensure(value.app.appId === APP_ID && value.app.bundleId === BUNDLE_ID && value.app.platform === PLATFORM, "E_MANIFEST", "manifest app identity does not match the configured app");

  exactKeys(value.release, ["version", "build", "baselineVersion", "reviewCycle", "releaseType"], "E_MANIFEST", "manifest release block is malformed");
  const release = value.release;
  ensure(typeof release.version === "string" && VERSION_PATTERN.test(release.version), "E_MANIFEST", "manifest version is invalid");
  ensure(typeof release.build === "string" && BUILD_PATTERN.test(release.build), "E_MANIFEST", "manifest build is invalid");
  ensure(typeof release.baselineVersion === "string" && VERSION_PATTERN.test(release.baselineVersion), "E_MANIFEST", "manifest baseline version is invalid");
  ensure(release.baselineVersion !== release.version, "E_MANIFEST", "manifest baseline and target versions must differ");
  ensure(typeof release.reviewCycle === "string" && CYCLE_PATTERN.test(release.reviewCycle), "E_MANIFEST", "manifest review cycle is invalid");
  ensure(RELEASE_TYPES.has(release.releaseType), "E_MANIFEST", "manifest release behavior must be MANUAL or AFTER_APPROVAL");

  ensure(typeof value.whatsNew === "string", "E_MANIFEST", "manifest What's New text is invalid");
  ensure(value.whatsNew.trim() === value.whatsNew, "E_MANIFEST", "manifest What's New text must be trimmed");
  ensure(value.whatsNew.length >= 1 && value.whatsNew.length <= 4_000, "E_MANIFEST", "manifest What's New length is invalid");
  ensure(!CONTROL_CHARACTER_PATTERN.test(value.whatsNew), "E_MANIFEST", "manifest What's New text contains control characters");

  validateContentBlock(value.content);
  ensure(typeof value.contentHash === "string" && HEX_256_PATTERN.test(value.contentHash), "E_MANIFEST", "manifest content hash is malformed");
  ensure(stableHash(value.content) === value.contentHash, "E_MANIFEST", "manifest content hash does not bind its own content block");
  ensure(value.content.metadataHashes.whatsNew === sha256(value.whatsNew), "E_MANIFEST", "manifest What's New text does not match its approved digest");

  exactKeys(value.approval, ["approved", "approvedBy", "approvedUtc", "statement"], "E_MANIFEST", "manifest approval block is malformed");
  ensure(value.approval.approved === true, "E_MANIFEST", "manifest is not marked captain-approved");
  ensure(typeof value.approval.approvedBy === "string" && SAFE_NAME_PATTERN.test(value.approval.approvedBy), "E_MANIFEST", "manifest approver is invalid");
  ensure(validTimestamp(value.approval.approvedUtc, nowMs), "E_MANIFEST", "manifest approval timestamp is invalid or in the future");
  ensure(typeof value.approval.statement === "string" && value.approval.statement.length >= 1 && value.approval.statement.length <= 500, "E_MANIFEST", "manifest approval statement is invalid");
  ensure(!CONTROL_CHARACTER_PATTERN.test(value.approval.statement), "E_MANIFEST", "manifest approval statement contains control characters");

  exactKeys(value.binding, ["algorithm", "manifestHash"], "E_MANIFEST", "manifest binding block is malformed");
  ensure(value.binding.algorithm === MANIFEST_BINDING_ALGORITHM, "E_MANIFEST", "manifest binding algorithm is unsupported");
  ensure(typeof value.binding.manifestHash === "string" && HEX_256_PATTERN.test(value.binding.manifestHash), "E_MANIFEST", "manifest binding hash is malformed");
  ensure(computeManifestHash(value) === value.binding.manifestHash, "E_MANIFEST", "manifest binding hash does not match the approved manifest content");

  return value;
}

function readManifest(sourceRoot, version, nowMs, dependencies = {}) {
  const filePath = manifestFilePath(sourceRoot, version);
  const readFile = dependencies.readFile || ((target) => fs.readFileSync(target, "utf8"));
  let text;
  try {
    text = readFile(filePath);
  } catch {
    return fail("E_MANIFEST", "no captain-approved submission manifest exists for this version");
  }
  ensure(typeof text === "string" && Buffer.byteLength(text, "utf8") <= MANIFEST_MAX_BYTES, "E_MANIFEST", "manifest file size is invalid");
  const manifest = validateManifest(parseJson(text, "E_MANIFEST", "manifest is not valid JSON"), nowMs);
  ensure(manifest.release.version === version, "E_MANIFEST", "manifest version does not match its approved manifest path");
  return Object.freeze({ manifest, filePath });
}

// The manifest is content-bound: the automation refuses to submit anything whose
// listing, screenshots, What's New text, version, build, baseline, review cycle,
// or release behavior differs from what the captain approved on the default branch.
function verifyManifestBinding(manifest, source) {
  ensure(source.contentHash === manifest.contentHash, "E_MANIFEST_BINDING", "working-tree listing content does not match the approved manifest");
  ensure(stableHash(source.content) === stableHash(manifest.content), "E_MANIFEST_BINDING", "working-tree listing content does not match the approved manifest");
  ensure(source.metadata.whatsNew === manifest.whatsNew, "E_MANIFEST_BINDING", "materialized What's New text does not match the approved manifest");
  for (const field of METADATA_FIELDS) {
    ensure(sha256(source.metadata[field]) === manifest.content.metadataHashes[field], "E_MANIFEST_BINDING", "working-tree listing metadata does not match the approved manifest");
  }
  return Object.freeze({
    version: manifest.release.version,
    build: manifest.release.build,
    baselineVersion: manifest.release.baselineVersion,
    reviewCycle: manifest.release.reviewCycle,
    releaseType: manifest.release.releaseType,
    contentHash: manifest.contentHash,
    manifestHash: manifest.binding.manifestHash,
  });
}

function buildManifest({ release, whatsNew, approval }, source) {
  const content = {
    metadataHashes: Object.fromEntries(METADATA_FIELDS.map((field) => [field, sha256(source.metadata[field])])),
    screenshots: source.content.screenshots.map((set) => ({
      displayType: set.displayType,
      width: set.width,
      height: set.height,
      files: set.files.map((file) => ({ fileName: file.fileName, fileSize: file.fileSize, sha256: file.sha256 })),
    })),
  };
  const draft = {
    schemaVersion: MANIFEST_SCHEMA_VERSION,
    app: { appId: APP_ID, bundleId: BUNDLE_ID, platform: PLATFORM },
    release: {
      version: release.version,
      build: release.build,
      baselineVersion: release.baselineVersion,
      reviewCycle: release.reviewCycle,
      releaseType: release.releaseType,
    },
    whatsNew,
    content,
    contentHash: stableHash(content),
    approval: {
      approved: true,
      approvedBy: approval.approvedBy,
      approvedUtc: approval.approvedUtc,
      statement: approval.statement,
    },
    binding: { algorithm: MANIFEST_BINDING_ALGORITHM, manifestHash: "" },
  };
  draft.binding.manifestHash = computeManifestHash(draft);
  return draft;
}

// -- configured evidence ------------------------------------------------------

// Portable equivalent of the stock gate's `verify-evidence` binding and freshness
// stop conditions. The stock verifier compares the recorded transport directory by
// absolute realpath, which is machine-local, so evidence produced by the attended
// local gate run is re-verified off-machine by its exact trailing shape instead.
function verifyEvidenceDocument(evidence, { reviewCycle, nowMs }) {
  return validateEvidenceEnvelope(evidence, {
    reviewCycle,
    nowMs,
    config: getActiveConfig().evidence,
  }, (message) => {
    throw new PipelineFailure("E_EVIDENCE", message);
  });
}

function decodeEvidenceInput(encoded) {
  ensure(typeof encoded === "string" && encoded.trim().length > 0, "E_EVIDENCE", "reviewer-host evidence input is missing");
  const compact = encoded.replace(/\s+/gu, "");
  ensure(/^[A-Za-z0-9+/]+={0,2}$/u.test(compact) && compact.length % 4 !== 1, "E_EVIDENCE", "reviewer-host evidence input is not valid base64");
  const decoded = Buffer.from(compact, "base64");
  ensure(decoded.length > 0 && decoded.length <= EVIDENCE_MAX_BYTES, "E_EVIDENCE", "reviewer-host evidence input size is invalid");
  const text = decoded.toString("utf8");
  ensure(Buffer.from(text, "utf8").equals(decoded), "E_EVIDENCE", "reviewer-host evidence input is not valid UTF-8");
  return Object.freeze({ text, document: parseJson(text, "E_EVIDENCE", "reviewer-host evidence input is not valid JSON") });
}

// -- durable nonsecret submission record ---------------------------------------

// The checkout pin and durable journal share this tuple so a same-content
// manifest re-commit cannot reuse state carrying an older source commit.
function recordHash(version, manifestHash, approvedCommit) {
  return crypto.createHash("sha256")
    .update(`v${RECORD_SCHEMA_VERSION}\0${APP_ID}\0${version}\0${manifestHash}\0${approvedCommit}`)
    .digest("hex");
}

function recordMarker(hash, kind) {
  return `<!-- ${RECORD_MARKER_PREFIX}:v${RECORD_SCHEMA_VERSION}:${hash}:${kind} -->`;
}

function recordIssueContent(hash, summary) {
  return Object.freeze({
    title: ISSUE_TITLE_TEMPLATE.replaceAll("{appName}", getActiveConfig().app.name).replaceAll("{version}", summary.version),
    body: [
      `Durable nonsecret recovery record for one captain-approved ${getActiveConfig().app.name} App Review submission.`,
      "",
      `- Approved manifest: \`${manifestRelativePath(summary.version)}\``,
      `- Manifest binding hash: \`${summary.manifestHash}\``,
      `- Listing content hash: \`${summary.contentHash}\``,
      `- Build \`${summary.build}\`, baseline \`${summary.baselineVersion}\`, review cycle \`${summary.reviewCycle}\``,
      `- Release behavior: \`${summary.releaseType}\``,
      "",
      "This record carries only nonsecret identity hashes, safe App Store resource ids, safe states, phase, and timestamps.",
      "It never carries credentials, JWTs, Apple response bodies, private review details, or screenshot bytes.",
      "Reviewer-host cleanup remains disabled and requires separate authority.",
      "",
      recordMarker(hash, "record"),
    ].join("\n"),
  });
}

function journalCommentBody(hash, state) {
  return [
    recordMarker(hash, "journal"),
    "",
    "Latest durable submission journal state. A re-run restores this exact state and reconciles against authoritative App Store Connect reads instead of duplicating a submission.",
    "",
    "```json",
    JSON.stringify(state, null, 2),
    "```",
  ].join("\n");
}

function eventCommentBody(hash, event) {
  return [recordMarker(hash, "event"), "", "```json", JSON.stringify(event, null, 2), "```"].join("\n");
}

function parseJournalComment(body) {
  const start = body.indexOf("```json");
  const end = body.lastIndexOf("```");
  if (start < 0 || end <= start) return null;
  const text = body.slice(start + "```json".length, end).trim();
  if (text.length === 0 || Buffer.byteLength(text, "utf8") > JOURNAL_STATE_MAX_BYTES) return null;
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  return isObject(parsed) ? parsed : null;
}

async function readLimited(response, limit = MAX_RESPONSE_BYTES) {
  const declared = response.headers && response.headers.get ? response.headers.get("content-length") : null;
  if (declared !== null && declared !== undefined) {
    const size = Number(declared);
    ensure(Number.isSafeInteger(size) && size >= 0 && size <= limit, "E_GITHUB", "GitHub response size is invalid");
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  ensure(bytes.length <= limit, "E_GITHUB", "GitHub response size is invalid");
  return bytes;
}

function hasTrustedRecordActor(value) {
  return isObject(value)
    && isObject(value.user)
    && value.user.login === GITHUB_ACTIONS_ACTOR
    && value.user.type === "Bot";
}

class GitHubRecordClient {
  constructor(token, fetchImpl = globalThis.fetch) {
    ensure(typeof fetchImpl === "function", "E_GITHUB", "no HTTP transport is available");
    ensure(typeof token === "string" && token.length > 0, "E_GITHUB", "no GitHub credential is available");
    this.token = token;
    this.fetch = fetchImpl;
  }

  async request(method, pathname, { body, expected = 200 } = {}) {
    let url;
    try {
      url = new URL(pathname, GITHUB_ORIGIN);
    } catch {
      return fail("E_GITHUB", "GitHub request URL is invalid");
    }
    ensure(url.origin === GITHUB_ORIGIN && url.protocol === "https:" && !url.username && !url.password && !url.hash, "E_GITHUB", "GitHub request URL is untrusted");
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      const response = await this.fetch(url, {
        method,
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${this.token}`,
          "X-GitHub-Api-Version": GITHUB_API_VERSION,
          ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: "no-store",
        redirect: "error",
        signal: controller.signal,
      });
      const accepted = Array.isArray(expected) ? expected : [expected];
      ensure(Boolean(response) && accepted.includes(response.status), "E_GITHUB", "GitHub returned an unexpected status");
      if (response.status === 204) return null;
      const bytes = await readLimited(response);
      ensure(bytes.length > 0, "E_GITHUB", "GitHub returned an empty body");
      return parseJson(bytes.toString("utf8"), "E_GITHUB", "GitHub returned an invalid JSON body");
    } catch (error) {
      if (error instanceof PipelineFailure) throw error;
      return fail("E_GITHUB", "the GitHub request failed");
    } finally {
      clearTimeout(timeout);
    }
  }

  async findIssue(marker) {
    let complete = false;
    let match = null;
    for (let page = 1; page <= MAX_ISSUE_PAGES; page += 1) {
      const query = new URLSearchParams({
        state: "all",
        per_page: String(ISSUES_PER_PAGE),
        page: String(page),
        sort: "created",
        direction: "desc",
      });
      const issues = await this.request("GET", `/repos/${REPOSITORY}/issues?${query}`);
      ensure(Array.isArray(issues) && issues.length <= ISSUES_PER_PAGE, "E_GITHUB", "GitHub returned a malformed issue page");
      for (const issue of issues) {
        ensure(isObject(issue), "E_GITHUB", "GitHub returned a malformed issue");
        if (hasOwn(issue, "pull_request")) continue;
        if (hasTrustedRecordActor(issue) && typeof issue.body === "string" && issue.body.includes(marker)) {
          ensure(Number.isSafeInteger(issue.number) && issue.number >= 1 && match === null, "E_RECORD", "more than one durable submission record matches this approved manifest");
          match = { number: issue.number };
        }
      }
      if (issues.length < ISSUES_PER_PAGE) {
        complete = true;
        break;
      }
    }
    ensure(complete, "E_GITHUB", "the durable record search exceeded its bound");
    return match;
  }

  async createIssue(content) {
    const created = await this.request("POST", `/repos/${REPOSITORY}/issues`, {
      expected: 201,
      body: { title: content.title, body: content.body, labels: [BOOKKEEPING_LABEL] },
    });
    ensure(hasTrustedRecordActor(created) && Number.isSafeInteger(created.number) && created.number >= 1, "E_GITHUB", "GitHub returned a malformed created issue");
    return Object.freeze({ number: created.number });
  }

  async listComments(issueNumber) {
    ensure(Number.isSafeInteger(issueNumber) && issueNumber >= 1, "E_GITHUB", "the durable record issue number is invalid");
    const comments = [];
    let complete = false;
    for (let page = 1; page <= MAX_ISSUE_PAGES; page += 1) {
      const query = new URLSearchParams({ per_page: String(ISSUES_PER_PAGE), page: String(page), direction: "asc" });
      const values = await this.request("GET", `/repos/${REPOSITORY}/issues/${issueNumber}/comments?${query}`);
      ensure(Array.isArray(values) && values.length <= ISSUES_PER_PAGE, "E_GITHUB", "GitHub returned a malformed comment page");
      for (const value of values) {
        ensure(isObject(value) && typeof value.body === "string" && Number.isSafeInteger(value.id), "E_GITHUB", "GitHub returned a malformed comment");
        if (hasTrustedRecordActor(value)) comments.push({ id: value.id, body: value.body });
      }
      if (values.length < ISSUES_PER_PAGE) {
        complete = true;
        break;
      }
    }
    ensure(complete, "E_GITHUB", "the durable record comment scan exceeded its bound");
    return comments;
  }

  async createComment(issueNumber, body) {
    ensure(Number.isSafeInteger(issueNumber) && issueNumber >= 1 && typeof body === "string" && body.length > 0, "E_GITHUB", "the durable record comment request is invalid");
    const created = await this.request("POST", `/repos/${REPOSITORY}/issues/${issueNumber}/comments`, { expected: 201, body: { body } });
    ensure(hasTrustedRecordActor(created) && Number.isSafeInteger(created.id) && created.id >= 1, "E_GITHUB", "GitHub returned a malformed created comment");
    return Object.freeze({ id: created.id });
  }

  async updateComment(commentId, body) {
    ensure(Number.isSafeInteger(commentId) && commentId >= 1 && typeof body === "string" && body.length > 0, "E_GITHUB", "the durable record comment update is invalid");
    const updated = await this.request("PATCH", `/repos/${REPOSITORY}/issues/comments/${commentId}`, { body: { body } });
    ensure(hasTrustedRecordActor(updated) && updated.id === commentId, "E_GITHUB", "GitHub returned a malformed updated comment");
    return Object.freeze({ id: updated.id });
  }
}

class SubmissionRecord {
  constructor(client, hash, summary) {
    this.client = client;
    this.hash = hash;
    this.summary = summary;
    this.issueNumber = null;
    this.journalCommentId = null;
    this.journalState = null;
  }

  async open({ create }) {
    const existing = await this.client.findIssue(recordMarker(this.hash, "record"));
    if (existing === null) {
      ensure(create, "E_RECORD", "no durable submission record exists; run the App Review preparation workflow first");
      const created = await this.client.createIssue(recordIssueContent(this.hash, this.summary));
      this.issueNumber = created.number;
      return Object.freeze({ created: true, resumable: false });
    }
    this.issueNumber = existing.number;
    const journalMarker = recordMarker(this.hash, "journal");
    let match = null;
    for (const comment of await this.client.listComments(this.issueNumber)) {
      if (!comment.body.includes(journalMarker)) continue;
      ensure(match === null, "E_RECORD", "the durable record holds more than one journal state");
      match = comment;
    }
    if (match !== null) {
      this.journalCommentId = match.id;
      this.journalState = parseJournalComment(match.body);
      ensure(this.journalState !== null, "E_RECORD", "the durable journal state is corrupt");
    }
    return Object.freeze({ created: false, resumable: this.journalState !== null });
  }

  async saveJournal(state) {
    const body = journalCommentBody(this.hash, state);
    if (this.journalCommentId === null) {
      const created = await this.client.createComment(this.issueNumber, body);
      this.journalCommentId = created.id;
      return;
    }
    await this.client.updateComment(this.journalCommentId, body);
  }

  async appendEvent(event) {
    await this.client.createComment(this.issueNumber, eventCommentBody(this.hash, event));
  }
}

// -- least-privilege monitor-variable handoff ----------------------------------

class MonitorVariableClient {
  constructor(client) {
    this.client = client;
  }

  async read() {
    const value = await this.client.request("GET", `/repos/${REPOSITORY}/actions/variables/${MONITOR_VARIABLE}`, { expected: [200, 404] });
    if (!isObject(value) || value.name !== MONITOR_VARIABLE || typeof value.value !== "string") return null;
    return value.value;
  }

  async write(version) {
    try {
      await this.client.request("PATCH", `/repos/${REPOSITORY}/actions/variables/${MONITOR_VARIABLE}`, {
        expected: 204,
        body: { name: MONITOR_VARIABLE, value: version },
      });
      return true;
    } catch (error) {
      if (!(error instanceof PipelineFailure)) throw error;
    }
    try {
      await this.client.request("POST", `/repos/${REPOSITORY}/actions/variables`, {
        expected: 201,
        body: { name: MONITOR_VARIABLE, value: version },
      });
      return true;
    } catch (error) {
      if (!(error instanceof PipelineFailure)) throw error;
      return false;
    }
  }
}

// -- configuration -------------------------------------------------------------

function requiredValue(env, name, pattern, maxLength = 4096) {
  const value = typeof env[name] === "string" ? env[name].trim() : "";
  ensure(value.length > 0 && value.length <= maxLength && !value.includes("\0"), "E_CONFIG", `${name} is missing or invalid`);
  ensure(!pattern || pattern.test(value), "E_CONFIG", `${name} is missing or invalid`);
  return value;
}

function assertNoAppStoreCredentials(env) {
  for (const name of APP_STORE_CREDENTIAL_FIELDS) {
    ensure(typeof env[name] !== "string" || env[name].length === 0, "E_CAPABILITY", "this job must run without App Store Connect credentials");
  }
}

function loadTrustedContext(env) {
  const repository = requiredValue(env, "GITHUB_REPOSITORY", null, 128);
  const reference = requiredValue(env, "GITHUB_REF", null, 256);
  const eventName = requiredValue(env, "GITHUB_EVENT_NAME", null, 64);
  ensure(repository === REPOSITORY, "E_CONFIG", "this action runs only in the trusted configured repository");
  ensure(reference === DEFAULT_BRANCH_REF, "E_CONFIG", "this action runs only from the trusted default branch");
  ensure(eventName === "workflow_dispatch", "E_CONFIG", "this action runs only from a trusted default-branch dispatch");
  return Object.freeze({ repository, reference, eventName });
}

function loadReleaseInputs(env) {
  const version = requiredValue(env, ENV_VERSION, VERSION_PATTERN, 32);
  const confirm = requiredValue(env, ENV_CONFIRM, VERSION_PATTERN, 32);
  ensure(confirm === version, "E_CONFIG", "the confirmation input does not repeat the exact version");
  return Object.freeze({ version });
}

function existingDirectory(env, name) {
  const value = requiredValue(env, name, null, 4096);
  ensure(path.isAbsolute(value), "E_CONFIG", `${name} is not an absolute path`);
  try {
    return fs.realpathSync(value);
  } catch {
    return fail("E_CONFIG", `${name} is unavailable`);
  }
}

function runnerScratchDirectory(env, name) {
  const directory = path.join(existingDirectory(env, "RUNNER_TEMP"), name);
  try {
    fs.mkdirSync(directory, { mode: 0o700 });
  } catch (error) {
    if (!error || error.code !== "EEXIST") fail("E_SCRATCH", "the scratch directory could not be created");
  }
  try {
    fs.chmodSync(directory, 0o700);
  } catch {
    fail("E_SCRATCH", "the scratch directory could not be secured");
  }
  return directory;
}

function writeOwnerOnlyFile(filePath, contents) {
  try {
    fs.rmSync(filePath, { force: true });
    const descriptor = fs.openSync(filePath, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try {
      fs.writeFileSync(descriptor, contents, "utf8");
      fs.fsyncSync(descriptor);
    } finally {
      fs.closeSync(descriptor);
    }
  } catch {
    fail("E_SCRATCH", "a required scratch file could not be written");
  }
  return filePath;
}

function currentCommit(sourceRoot, dependencies = {}) {
  const readCommit = dependencies.readCommit || (() => {
    const child = {};
    for (const name of ["PATH", "HOME", "TMPDIR", "LANG", "TZ"]) {
      if (typeof process.env[name] === "string") child[name] = process.env[name];
    }
    const runProcess = dependencies.spawnSync || spawnSync;
    const result = runProcess("git", ["-C", sourceRoot, "rev-parse", "--verify", "HEAD^{commit}"], {
      shell: false,
      encoding: "utf8",
      env: child,
      timeout: 5_000,
      maxBuffer: 64 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
    });
    return result && result.status === 0 ? String(result.stdout) : "";
  });
  const commit = String(readCommit()).trim().toLowerCase();
  ensure(COMMIT_PATTERN.test(commit), "E_SOURCE", "the checked-out commit could not be resolved");
  return commit;
}

function approvedManifestCommit(sourceRoot, version, dependencies = {}) {
  const readApprovedCommit = dependencies.readApprovedCommit || (() => {
    const child = {};
    for (const name of ["PATH", "HOME", "TMPDIR", "LANG", "TZ"]) {
      if (typeof process.env[name] === "string") child[name] = process.env[name];
    }
    const runProcess = dependencies.spawnSync || spawnSync;
    const result = runProcess("git", [
      "-C",
      sourceRoot,
      "log",
      "-1",
      "--format=%H",
      "--",
      manifestRelativePath(version),
    ], {
      shell: false,
      encoding: "utf8",
      env: child,
      timeout: 5_000,
      maxBuffer: 64 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
    });
    return result && result.status === 0 ? String(result.stdout) : "";
  });
  const commit = String(readApprovedCommit()).trim().toLowerCase();
  ensure(COMMIT_PATTERN.test(commit), "E_SOURCE", "the manifest-approved commit could not be resolved");
  return commit;
}

function pinnedSourceCommit(sourceRoot, version, dependencies = {}) {
  const head = currentCommit(sourceRoot, dependencies);
  const approved = approvedManifestCommit(sourceRoot, version, dependencies);
  ensure(head === approved, "E_SOURCE", "the checkout is not pinned to the manifest-approved commit");
  return approved;
}

// -- shared verification -------------------------------------------------------

function prepareSubmissionArguments({ sourceRoot, manifest, scratch, evidencePath, resume }, dependencies = {}) {
  const whatsNewFile = writeOwnerOnlyFile(path.join(scratch, "whats-new.txt"), `${manifest.whatsNew}\n`);
  const approvedCommit = pinnedSourceCommit(sourceRoot, manifest.release.version, dependencies);
  const args = Object.freeze({
    version: manifest.release.version,
    build: manifest.release.build,
    baselineVersion: manifest.release.baselineVersion,
    reviewCycle: manifest.release.reviewCycle,
    sourceRoot,
    sourceCommit: approvedCommit,
    whatsNewFile,
    evidence: evidencePath,
    journal: path.join(scratch, "journal.json"),
    diagnosticTraceDir: null,
    expectedReleaseType: manifest.release.releaseType,
    preflight: false,
    resume,
  });
  const source = (dependencies.loadSource || loadSource)(args);
  return Object.freeze({ args, source, summary: verifyManifestBinding(manifest, source), approvedCommit });
}

// -- subcommands ---------------------------------------------------------------

function runManifestGate(env, dependencies, { requireEvidence, scratchName }) {
  assertNoAppStoreCredentials(env);
  loadTrustedContext(env);
  const nowMs = (dependencies.now || Date.now)();
  const { version } = loadReleaseInputs(env);
  const sourceRoot = existingDirectory(env, "GITHUB_WORKSPACE");
  const { manifest } = readManifest(sourceRoot, version, nowMs, dependencies);
  const scratch = runnerScratchDirectory(env, scratchName);
  const evidencePath = path.join(scratch, "evidence.json");
  let evidence = null;
  if (requireEvidence) {
    const decoded = decodeEvidenceInput(env[ENV_EVIDENCE]);
    evidence = verifyEvidenceDocument(decoded.document, { reviewCycle: manifest.release.reviewCycle, nowMs });
    writeOwnerOnlyFile(evidencePath, decoded.text);
  }
  const prepared = prepareSubmissionArguments({ sourceRoot, manifest, scratch, evidencePath, resume: false }, dependencies);
  return Object.freeze({
    outcome: "verified",
    summary: prepared.summary,
    approvedCommit: prepared.approvedCommit,
    evidenceGeneratedUtc: evidence ? evidence.generatedUtc : null,
  });
}

async function runVerifyManifest(env, dependencies = {}) {
  return runManifestGate(env, dependencies, { requireEvidence: true, scratchName: `${SCRATCH_PREFIX}-verify` });
}

async function runPrepare(env, dependencies = {}) {
  const verified = runManifestGate(env, dependencies, { requireEvidence: false, scratchName: `${SCRATCH_PREFIX}-prepare` });
  const client = dependencies.recordClient || new GitHubRecordClient(requiredValue(env, "GITHUB_TOKEN", null, 4096), dependencies.fetch);
  const record = new SubmissionRecord(
    client,
    recordHash(verified.summary.version, verified.summary.manifestHash, verified.approvedCommit),
    verified.summary,
  );
  const opened = await record.open({ create: true });
  await record.appendEvent({
    schemaVersion: RECORD_SCHEMA_VERSION,
    kind: "prepared",
    version: verified.summary.version,
    build: verified.summary.build,
    baselineVersion: verified.summary.baselineVersion,
    reviewCycle: verified.summary.reviewCycle,
    releaseType: verified.summary.releaseType,
    manifestHash: verified.summary.manifestHash,
    contentHash: verified.summary.contentHash,
    runId: typeof env.GITHUB_RUN_ID === "string" ? env.GITHUB_RUN_ID.slice(0, 32) : null,
    recordedUtc: new Date((dependencies.now || Date.now)()).toISOString(),
  });
  return Object.freeze({
    outcome: "prepared",
    summary: verified.summary,
    recordCreated: opened.created,
    resumable: opened.resumable,
  });
}

async function runPreflight(env, dependencies = {}) {
  loadTrustedContext(env);
  const nowMs = (dependencies.now || Date.now)();
  const { version } = loadReleaseInputs(env);
  const sourceRoot = existingDirectory(env, "GITHUB_WORKSPACE");
  const { manifest } = readManifest(sourceRoot, version, nowMs, dependencies);
  const scratch = runnerScratchDirectory(env, `${SCRATCH_PREFIX}-preflight`);
  const traceDirectory = runnerScratchDirectory({ RUNNER_TEMP: scratch }, "traces");
  const prepared = prepareSubmissionArguments({
    sourceRoot,
    manifest,
    scratch,
    evidencePath: path.join(scratch, "evidence.json"),
    resume: false,
  }, dependencies);
  const args = Object.freeze({ ...prepared.args, preflight: true, diagnosticTraceDir: traceDirectory });
  const credentials = Object.freeze({
    apiKey: env.APP_STORE_CONNECT_API_KEY,
    issuerId: env.APP_STORE_CONNECT_ISSUER_ID,
    keyId: env.APP_STORE_CONNECT_KEY_ID,
  });
  const submit = dependencies.runSubmission || runSubmission;
  const result = await submit(args, credentials, { ...dependencies, source: prepared.source, env: {} });
  return Object.freeze({
    outcome: "preflight_passed",
    summary: prepared.summary,
    mutations: result && result.result && Number.isSafeInteger(result.result.mutations) ? result.result.mutations : 0,
  });
}

async function runSubmit(env, dependencies = {}) {
  loadTrustedContext(env);
  const now = dependencies.now || Date.now;
  const { version } = loadReleaseInputs(env);
  const sourceRoot = existingDirectory(env, "GITHUB_WORKSPACE");
  const { manifest } = readManifest(sourceRoot, version, now(), dependencies);

  const scratch = runnerScratchDirectory(env, `${SCRATCH_PREFIX}-submit`);
  const decoded = decodeEvidenceInput(env[ENV_EVIDENCE]);
  const evidence = verifyEvidenceDocument(decoded.document, { reviewCycle: manifest.release.reviewCycle, nowMs: now() });
  const evidencePath = writeOwnerOnlyFile(path.join(scratch, "evidence.json"), decoded.text);

  const client = dependencies.recordClient || new GitHubRecordClient(requiredValue(env, "GITHUB_TOKEN", null, 4096), dependencies.fetch);
  const monitorVariable = dependencies.monitorVariable
    || new MonitorVariableClient(new GitHubRecordClient(requiredValue(env, ENV_MONITOR_TOKEN, null, 4096), dependencies.fetch));

  const probe = prepareSubmissionArguments({ sourceRoot, manifest, scratch, evidencePath, resume: false }, dependencies);
  const record = new SubmissionRecord(
    client,
    recordHash(probe.summary.version, probe.summary.manifestHash, probe.approvedCommit),
    probe.summary,
  );
  const opened = await record.open({ create: false });

  if (opened.resumable) writeOwnerOnlyFile(probe.args.journal, `${JSON.stringify(record.journalState, null, 2)}\n`);
  const args = Object.freeze({ ...probe.args, resume: opened.resumable });

  await record.appendEvent({
    schemaVersion: RECORD_SCHEMA_VERSION,
    kind: "submission_started",
    version: probe.summary.version,
    build: probe.summary.build,
    resumed: opened.resumable,
    evidenceGeneratedUtc: evidence.generatedUtc,
    runId: typeof env.GITHUB_RUN_ID === "string" ? env.GITHUB_RUN_ID.slice(0, 32) : null,
    recordedUtc: new Date(now()).toISOString(),
  });

  const credentials = Object.freeze({
    apiKey: env.APP_STORE_CONNECT_API_KEY,
    issuerId: env.APP_STORE_CONNECT_ISSUER_ID,
    keyId: env.APP_STORE_CONNECT_KEY_ID,
  });
  const submit = dependencies.runSubmission || runSubmission;
  const readJournalState = dependencies.readJournalState
    || (() => parseJson(fs.readFileSync(probe.args.journal, "utf8"), "E_RECORD", "the local journal could not be read"));

  let result = null;
  let failure = null;
  try {
    result = await submit(args, credentials, {
      ...dependencies,
      source: probe.source,
      env: {},
      monitorVariable,
      verifyEvidence: dependencies.verifyEvidence
        || (() => Boolean(verifyEvidenceDocument(decoded.document, { reviewCycle: manifest.release.reviewCycle, nowMs: now() }))),
    });
  } catch (error) {
    failure = error;
  }

  let persisted = null;
  try {
    persisted = readJournalState();
  } catch {
    persisted = null;
  }
  if (isObject(persisted)) await record.saveJournal(persisted);
  await record.appendEvent({
    schemaVersion: RECORD_SCHEMA_VERSION,
    kind: failure === null ? "submission_completed" : "submission_failed",
    version: probe.summary.version,
    build: probe.summary.build,
    status: failure === null && result && result.result ? String(result.result.status).slice(0, 32) : null,
    errorCode: failure === null ? null : failure instanceof SafeError || failure instanceof PipelineFailure ? failure.code : "E_UNEXPECTED",
    recordedUtc: new Date(now()).toISOString(),
  });

  if (failure !== null) throw failure;
  return Object.freeze({
    outcome: "submitted",
    summary: probe.summary,
    status: result.result.status,
    resumed: opened.resumable,
    mutations: result.result.mutations,
  });
}

// -- local manifest authoring --------------------------------------------------

function parseComputeArguments(argv) {
  const flags = [
    "--version",
    "--build",
    "--baseline-version",
    "--review-cycle",
    "--release-type",
    "--source-root",
    "--whats-new-file",
    "--approved-by",
    "--approval-statement",
    "--out",
  ];
  const known = new Set(flags);
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    ensure(known.has(flag), "E_USAGE", "unknown compute-manifest option");
    ensure(!hasOwn(values, flag), "E_USAGE", "compute-manifest options may appear only once");
    const value = argv[index + 1];
    ensure(typeof value === "string" && value.length > 0 && !value.startsWith("--"), "E_USAGE", "a compute-manifest option is missing its value");
    values[flag] = value;
    index += 1;
  }
  for (const flag of flags) ensure(hasOwn(values, flag), "E_USAGE", `${flag} is required`);
  for (const flag of ["--source-root", "--whats-new-file", "--out"]) {
    ensure(path.isAbsolute(values[flag]) && path.normalize(values[flag]) === values[flag], "E_USAGE", `${flag} must be a normalized absolute path`);
  }
  ensure(RELEASE_TYPES.has(values["--release-type"]), "E_USAGE", "--release-type must be MANUAL or AFTER_APPROVAL");
  return Object.freeze({
    release: Object.freeze({
      version: values["--version"],
      build: values["--build"],
      baselineVersion: values["--baseline-version"],
      reviewCycle: values["--review-cycle"],
      releaseType: values["--release-type"],
    }),
    sourceRoot: values["--source-root"],
    whatsNewFile: values["--whats-new-file"],
    approvedBy: values["--approved-by"],
    statement: values["--approval-statement"],
    out: values["--out"],
  });
}

function runComputeManifest(argv, dependencies = {}) {
  const parsed = parseComputeArguments(argv);
  const nowMs = (dependencies.now || Date.now)();
  const source = (dependencies.loadSource || loadSource)(Object.freeze({
    version: parsed.release.version,
    build: parsed.release.build,
    baselineVersion: parsed.release.baselineVersion,
    reviewCycle: parsed.release.reviewCycle,
    sourceRoot: parsed.sourceRoot,
    sourceCommit: currentCommit(parsed.sourceRoot, dependencies),
    whatsNewFile: parsed.whatsNewFile,
    evidence: parsed.whatsNewFile,
    journal: parsed.whatsNewFile,
    diagnosticTraceDir: null,
    expectedReleaseType: parsed.release.releaseType,
    preflight: false,
    resume: false,
  }));
  const manifest = buildManifest({
    release: parsed.release,
    whatsNew: source.metadata.whatsNew,
    approval: {
      approvedBy: parsed.approvedBy,
      approvedUtc: new Date(nowMs).toISOString().replace(/\.\d{3}Z$/u, "Z"),
      statement: parsed.statement,
    },
  }, source);
  validateManifest(manifest, nowMs);
  const write = dependencies.writeFile || ((target, contents) => fs.writeFileSync(target, contents, "utf8"));
  write(parsed.out, `${JSON.stringify(manifest, null, 2)}\n`);
  return Object.freeze({ outcome: "manifest_written", path: parsed.out, manifestHash: manifest.binding.manifestHash });
}

// -- entrypoint ----------------------------------------------------------------

function formatOutcome(name, values) {
  return `${toonObject(name, values)}\n`;
}

function formatPipelineError(error) {
  if (error instanceof PipelineFailure || error instanceof monitor.MonitorFailure) {
    return formatOutcome("error", { code: error.code, message: error.message });
  }
  if (error instanceof SafeError) return formatError(error);
  return formatOutcome("error", { code: "E_UNEXPECTED", message: "the App Review pipeline action failed safely" });
}

function stripConfigArgv(argv) {
  const stripped = [];
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--config") {
      index += 1;
      continue;
    }
    if (typeof argv[index] === "string" && argv[index].startsWith("--config=")) continue;
    stripped.push(argv[index]);
  }
  return stripped;
}

async function main(argv = process.argv.slice(2), env = process.env, dependencies = {}) {
  const write = dependencies.write || ((value) => process.stdout.write(value));
  activateFromArgv(argv, env);
  const commandArgv = stripConfigArgv(argv);
  const command = commandArgv[0];
  try {
    ensure(SUBCOMMANDS.includes(command), "E_USAGE", `usage: app_review_pipeline.js <${SUBCOMMANDS.join("|")}>`);
    if (command === "compute-manifest") {
      const result = runComputeManifest(commandArgv.slice(1), dependencies);
      write(formatOutcome("manifest", result));
      return 0;
    }
    ensure(commandArgv.length === 1, "E_USAGE", "this subcommand takes no arguments");
    if (command === "verify-manifest") {
      const result = await runVerifyManifest(env, dependencies);
      write(formatOutcome("verify", {
        outcome: result.outcome,
        version: result.summary.version,
        build: result.summary.build,
        releaseType: result.summary.releaseType,
        manifestHash: result.summary.manifestHash,
        evidenceGeneratedUtc: result.evidenceGeneratedUtc,
      }));
      return 0;
    }
    if (command === "prepare") {
      const result = await runPrepare(env, dependencies);
      write(formatOutcome("prepare", {
        outcome: result.outcome,
        version: result.summary.version,
        build: result.summary.build,
        releaseType: result.summary.releaseType,
        manifestHash: result.summary.manifestHash,
        recordCreated: result.recordCreated,
        resumable: result.resumable,
      }));
      return 0;
    }
    if (command === "preflight") {
      const result = await runPreflight(env, dependencies);
      write(formatOutcome("preflight", {
        outcome: result.outcome,
        version: result.summary.version,
        build: result.summary.build,
        mutations: result.mutations,
      }));
      return 0;
    }
    if (command === "monitor" || command === "status") {
      const result = await (dependencies.runMonitor || monitor.runMonitor)(env, dependencies);
      write(monitor.formatMonitor(result));
      return 0;
    }
    const result = await runSubmit(env, dependencies);
    write(formatOutcome("submit", {
      outcome: result.outcome,
      version: result.summary.version,
      build: result.summary.build,
      status: result.status,
      resumed: result.resumed,
      mutations: result.mutations,
    }));
    return 0;
  } catch (error) {
    write(formatPipelineError(error));
    return error instanceof PipelineFailure && error.code === "E_USAGE" ? 2 : 1;
  }
}

module.exports = {
  APP_STORE_CREDENTIAL_FIELDS,
  BOOKKEEPING_LABEL,
  EVIDENCE_MAX_AGE_MS,
  GitHubRecordClient,
  get MANIFEST_BINDING_ALGORITHM() { return MANIFEST_BINDING_ALGORITHM; },
  get MANIFEST_SCHEMA_VERSION() { return MANIFEST_SCHEMA_VERSION; },
  get MONITOR_VARIABLE() { return MONITOR_VARIABLE; },
  MonitorVariableClient,
  PipelineFailure,
  RECORD_SCHEMA_VERSION,
  RELEASE_TYPES,
  SUBCOMMANDS,
  SubmissionRecord,
  assertNoAppStoreCredentials,
  buildManifest,
  computeManifestHash,
  decodeEvidenceInput,
  eventCommentBody,
  journalCommentBody,
  main,
  manifestFilePath,
  manifestRelativePath,
  parseComputeArguments,
  parseJournalComment,
  prepareSubmissionArguments,
  readManifest,
  recordHash,
  recordMarker,
  runComputeManifest,
  runPrepare,
  runPreflight,
  runSubmit,
  runVerifyManifest,
  validateManifest,
  verifyEvidenceDocument,
  verifyManifestBinding,
};

if (require.main === module) {
  main().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
