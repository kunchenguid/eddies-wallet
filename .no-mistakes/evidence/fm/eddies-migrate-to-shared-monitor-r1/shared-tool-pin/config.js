"use strict";

const fs = require("node:fs");
const path = require("node:path");

const LISTING_POLICIES = new Set(["upload", "observe"]);
const COMMERCE_KINDS = new Set(["lifetimeIap", "subscriptions"]);
const EVIDENCE_ADAPTERS = new Set(["reviewHost", "demoPreflight"]);
const JWT_STYLES = new Set(["team", "individual"]);
const PLATFORMS = new Set(["IOS", "MAC_OS", "TV_OS"]);
const ALIGNMENT_WRITES = new Set(["releaseType", "build", "reviewNotes"]);

const DEFAULT_FIXTURE = path.join(__dirname, "fixtures", "sshhip", "app-review.config.json");

let activeConfig = null;
const listeners = new Set();

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fail(message) {
  const error = new Error(message);
  error.code = "E_CONFIG";
  throw error;
}

function ensure(condition, message) {
  if (!condition) fail(message);
}

function exactString(value, pattern, message) {
  ensure(typeof value === "string" && value.length >= 1 && value.length <= 256, message);
  if (pattern) ensure(pattern.test(value), message);
  return value;
}

function stringArray(value, message, { min = 1, max = 32, itemPattern = null } = {}) {
  ensure(Array.isArray(value) && value.length >= min && value.length <= max, message);
  return value.map((item) => {
    ensure(typeof item === "string" && item.length >= 1 && item.length <= 256, message);
    if (itemPattern) ensure(itemPattern.test(item), message);
    return item;
  });
}

function pathSegments(value, message) {
  return stringArray(value, message, { min: 1, max: 16, itemPattern: /^[A-Za-z0-9._-]+$/u });
}

function normalizeScreenshotSpecs(specs) {
  ensure(Array.isArray(specs) && specs.length >= 1 && specs.length <= 8, "listing.screenshotSpecs is invalid");
  return Object.freeze(specs.map((spec) => {
    ensure(isObject(spec), "listing.screenshotSpecs entry is invalid");
    ensure(typeof spec.displayType === "string" && spec.displayType.length >= 1, "screenshot displayType is invalid");
    ensure(Number.isSafeInteger(spec.width) && spec.width > 0, "screenshot width is invalid");
    ensure(Number.isSafeInteger(spec.height) && spec.height > 0, "screenshot height is invalid");
    ensure(Array.isArray(spec.files) && spec.files.length >= 1 && spec.files.length <= 10, "screenshot files are invalid");
    return Object.freeze({
      displayType: spec.displayType,
      width: spec.width,
      height: spec.height,
      files: Object.freeze(spec.files.map((fileName) => {
        ensure(typeof fileName === "string" && /^[A-Za-z0-9._-]+$/u.test(fileName), "screenshot fileName is invalid");
        return fileName;
      })),
    });
  }));
}

function normalizeConfig(raw) {
  ensure(isObject(raw), "config is not a JSON object");
  ensure(isObject(raw.app), "config.app is required");
  const app = Object.freeze({
    appId: exactString(raw.app.appId, /^[A-Za-z0-9]+$/u, "config.app.appId is invalid"),
    bundleId: exactString(raw.app.bundleId, /^[A-Za-z0-9.-]+$/u, "config.app.bundleId is invalid"),
    name: exactString(raw.app.name, /^[A-Za-z0-9][A-Za-z0-9 '._-]{0,63}$/u, "config.app.name is invalid"),
    platform: exactString(raw.app.platform, null, "config.app.platform is invalid"),
  });
  ensure(PLATFORMS.has(app.platform), "config.app.platform is unsupported");

  ensure(isObject(raw.github), "config.github is required");
  const github = Object.freeze({
    repository: exactString(raw.github.repository, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u, "config.github.repository is invalid"),
    defaultBranchRef: exactString(raw.github.defaultBranchRef || "refs/heads/main", /^refs\/heads\/[A-Za-z0-9._/-]+$/u, "config.github.defaultBranchRef is invalid"),
  });

  ensure(isObject(raw.monitor), "config.monitor is required");
  const monitor = Object.freeze({
    variableName: exactString(raw.monitor.variableName, /^[A-Z][A-Z0-9_]{1,127}$/u, "config.monitor.variableName is invalid"),
    recordMarkerPrefix: exactString(
      raw.monitor.recordMarkerPrefix,
      /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u,
      "config.monitor.recordMarkerPrefix is invalid",
    ),
  });

  ensure(isObject(raw.env), "config.env is required");
  const env = Object.freeze({
    version: exactString(raw.env.version, /^[A-Z][A-Z0-9_]{1,127}$/u, "config.env.version is invalid"),
    confirm: exactString(raw.env.confirm, /^[A-Z][A-Z0-9_]{1,127}$/u, "config.env.confirm is invalid"),
    evidence: exactString(raw.env.evidence, /^[A-Z][A-Z0-9_]{1,127}$/u, "config.env.evidence is invalid"),
    monitorVariableToken: exactString(raw.env.monitorVariableToken, /^[A-Z][A-Z0-9_]{1,127}$/u, "config.env.monitorVariableToken is invalid"),
  });

  ensure(isObject(raw.manifest), "config.manifest is required");
  const manifest = Object.freeze({
    schemaVersion: raw.manifest.schemaVersion === undefined ? 1 : raw.manifest.schemaVersion,
    bindingAlgorithm: exactString(raw.manifest.bindingAlgorithm, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u, "config.manifest.bindingAlgorithm is invalid"),
    directory: Object.freeze(pathSegments(raw.manifest.directory, "config.manifest.directory is invalid")),
  });
  ensure(Number.isSafeInteger(manifest.schemaVersion) && manifest.schemaVersion >= 1 && manifest.schemaVersion <= 16, "config.manifest.schemaVersion is invalid");

  const listingPolicy = raw.listingPolicy || "upload";
  ensure(LISTING_POLICIES.has(listingPolicy), "config.listingPolicy must be upload or observe");

  ensure(isObject(raw.listing), "config.listing is required");
  const alignmentWrites = raw.listing.alignmentWrites === undefined
    ? (listingPolicy === "observe" ? ["releaseType", "build", "reviewNotes"] : ["releaseType", "build", "reviewNotes", "listing", "screenshots", "version"])
    : raw.listing.alignmentWrites;
  ensure(Array.isArray(alignmentWrites) && alignmentWrites.every((name) => ALIGNMENT_WRITES.has(name) || name === "listing" || name === "screenshots" || name === "version"), "config.listing.alignmentWrites is invalid");
  const listing = Object.freeze({
    sourcePath: Object.freeze(pathSegments(raw.listing.sourcePath, "config.listing.sourcePath is invalid")),
    screenshotDirectory: Object.freeze(pathSegments(raw.listing.screenshotDirectory, "config.listing.screenshotDirectory is invalid")),
    approvedSubtitle: raw.listing.approvedSubtitle === undefined || raw.listing.approvedSubtitle === null
      ? null
      : exactString(raw.listing.approvedSubtitle, null, "config.listing.approvedSubtitle is invalid"),
    screenshotSpecs: normalizeScreenshotSpecs(raw.listing.screenshotSpecs),
    alignmentWrites: Object.freeze([...alignmentWrites]),
  });

  ensure(isObject(raw.commerce), "config.commerce is required");
  const commerceKind = raw.commerce.kind;
  ensure(COMMERCE_KINDS.has(commerceKind), "config.commerce.kind must be lifetimeIap or subscriptions");
  const commerce = commerceKind === "lifetimeIap"
    ? Object.freeze({
      kind: "lifetimeIap",
      productId: exactString(raw.commerce.productId, /^[A-Za-z0-9.-]+$/u, "config.commerce.productId is invalid"),
      productIds: Object.freeze([]),
    })
    : Object.freeze({
      kind: "subscriptions",
      productId: null,
      productIds: Object.freeze(stringArray(raw.commerce.productIds, "config.commerce.productIds is invalid", {
        min: 1,
        max: 16,
        itemPattern: /^[A-Za-z0-9.-]+$/u,
      })),
    });

  ensure(isObject(raw.protected), "config.protected is required");
  const protectedState = Object.freeze({
    contentRightsDeclaration: exactString(raw.protected.contentRightsDeclaration, /^[A-Z_]+$/u, "config.protected.contentRightsDeclaration is invalid"),
    isOrEverWasMadeForKids: raw.protected.isOrEverWasMadeForKids === true,
    primaryCategory: exactString(raw.protected.primaryCategory, /^[A-Z0-9_]+$/u, "config.protected.primaryCategory is invalid"),
    secondaryCategory: exactString(raw.protected.secondaryCategory, /^[A-Z0-9_]+$/u, "config.protected.secondaryCategory is invalid"),
  });

  ensure(isObject(raw.evidence), "config.evidence is required");
  const adapter = raw.evidence.adapter;
  ensure(EVIDENCE_ADAPTERS.has(adapter), "config.evidence.adapter must be reviewHost or demoPreflight");
  const evidence = Object.freeze({
    adapter,
    gateName: exactString(raw.evidence.gateName, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u, "config.evidence.gateName is invalid"),
    schemaVersion: raw.evidence.schemaVersion === undefined ? 1 : raw.evidence.schemaVersion,
    hostname: raw.evidence.hostname ? exactString(raw.evidence.hostname, /^[A-Za-z0-9.-]+$/u, "config.evidence.hostname is invalid") : null,
    legacyHostname: raw.evidence.legacyHostname ? exactString(raw.evidence.legacyHostname, /^[A-Za-z0-9.-]+$/u, "config.evidence.legacyHostname is invalid") : null,
    requireHostnameInNotes: raw.evidence.requireHostnameInNotes !== false,
    preflightScript: raw.evidence.preflightScript
      ? Object.freeze(pathSegments(raw.evidence.preflightScript, "config.evidence.preflightScript is invalid"))
      : null,
    realTransportSuffix: raw.evidence.realTransportSuffix
      ? Object.freeze(pathSegments(raw.evidence.realTransportSuffix, "config.evidence.realTransportSuffix is invalid"))
      : null,
    layers: Object.freeze(stringArray(raw.evidence.layers, "config.evidence.layers is invalid", {
      min: 1,
      max: 32,
      itemPattern: /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u,
    })),
  });
  ensure(Number.isSafeInteger(evidence.schemaVersion) && evidence.schemaVersion >= 1, "config.evidence.schemaVersion is invalid");
  if (adapter === "reviewHost") {
    ensure(evidence.hostname && evidence.preflightScript && evidence.realTransportSuffix, "reviewHost evidence requires hostname, preflightScript, and realTransportSuffix");
  }

  ensure(isObject(raw.journal), "config.journal is required");
  const journal = Object.freeze({
    recordMarkerPrefix: exactString(raw.journal.recordMarkerPrefix, /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u, "config.journal.recordMarkerPrefix is invalid"),
    issueTitleTemplate: exactString(raw.journal.issueTitleTemplate, null, "config.journal.issueTitleTemplate is invalid"),
    scratchPrefix: exactString(raw.journal.scratchPrefix || "app-review", /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u, "config.journal.scratchPrefix is invalid"),
  });

  const credentials = Object.freeze({
    jwtStyle: JWT_STYLES.has(raw.credentials && raw.credentials.jwtStyle) ? raw.credentials.jwtStyle : "team",
  });

  return Object.freeze({
    app,
    github,
    monitor,
    env,
    manifest,
    listingPolicy,
    listing,
    commerce,
    protected: protectedState,
    evidence,
    journal,
    credentials,
  });
}

function loadConfigObject(value) {
  return normalizeConfig(value);
}

function loadConfigFile(filePath) {
  ensure(typeof filePath === "string" && filePath.length > 0, "config path is required");
  const resolved = path.resolve(filePath);
  let text;
  try {
    text = fs.readFileSync(resolved, "utf8");
  } catch {
    fail(`config file is unavailable: ${resolved}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    fail("config file is not valid JSON");
  }
  return loadConfigObject(parsed);
}

function loadDefaultFixture() {
  return loadConfigFile(DEFAULT_FIXTURE);
}

function getActiveConfig() {
  if (activeConfig === null) activeConfig = loadDefaultFixture();
  return activeConfig;
}

function setActiveConfig(config) {
  activeConfig = typeof config === "string" ? loadConfigFile(config) : loadConfigObject(config);
  for (const listener of listeners) listener(activeConfig);
  return activeConfig;
}

function resetActiveConfig() {
  activeConfig = loadDefaultFixture();
  for (const listener of listeners) listener(activeConfig);
  return activeConfig;
}

function onChange(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function withConfig(config, fn) {
  const previous = activeConfig;
  setActiveConfig(config);
  try {
    return fn(getActiveConfig());
  } finally {
    activeConfig = previous;
    for (const listener of listeners) listener(getActiveConfig());
  }
}

async function withConfigAsync(config, fn) {
  const previous = activeConfig;
  setActiveConfig(config);
  try {
    return await fn(getActiveConfig());
  } finally {
    activeConfig = previous;
    for (const listener of listeners) listener(getActiveConfig());
  }
}

function resolveConfigPath(argv = [], env = process.env) {
  if (typeof env.APP_REVIEW_CONFIG === "string" && env.APP_REVIEW_CONFIG.length > 0) {
    return env.APP_REVIEW_CONFIG;
  }
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--config") {
      const value = argv[index + 1];
      ensure(typeof value === "string" && value.length > 0 && !value.startsWith("--"), "--config requires a path");
      return value;
    }
    if (typeof argv[index] === "string" && argv[index].startsWith("--config=")) {
      const value = argv[index].slice("--config=".length);
      ensure(value.length > 0, "--config requires a path");
      return value;
    }
  }
  return null;
}

function activateFromArgv(argv = [], env = process.env) {
  const filePath = resolveConfigPath(argv, env);
  if (filePath) return setActiveConfig(filePath);
  return getActiveConfig();
}

function listingWritesAllowed(kind) {
  const config = getActiveConfig();
  if (config.listingPolicy === "upload") return true;
  return config.listing.alignmentWrites.includes(kind);
}

function requireHostnameInNotes() {
  const evidence = getActiveConfig().evidence;
  return evidence.requireHostnameInNotes === true && typeof evidence.hostname === "string";
}

module.exports = {
  ALIGNMENT_WRITES,
  COMMERCE_KINDS,
  DEFAULT_FIXTURE,
  EVIDENCE_ADAPTERS,
  JWT_STYLES,
  LISTING_POLICIES,
  activateFromArgv,
  getActiveConfig,
  listingWritesAllowed,
  loadConfigFile,
  loadConfigObject,
  loadDefaultFixture,
  onChange,
  requireHostnameInNotes,
  resetActiveConfig,
  resolveConfigPath,
  setActiveConfig,
  withConfig,
  withConfigAsync,
};
