#!/usr/bin/env node

const crypto = require("node:crypto");
const fs = require("node:fs");

const API_BASE_URL = "https://api.appstoreconnect.apple.com";
const CERTIFICATES_PATH = "/v1/certificates?filter[certificateType]=DEVELOPMENT&limit=200";
const JWT_AUDIENCE = "appstoreconnect-v1";
const JWT_TTL_SECONDS = 10 * 60;
const TARGET_CERTIFICATE_TYPE = "DEVELOPMENT";
const MINIMUM_AGE_MS = 24 * 60 * 60 * 1000;
const API_SUBJECT_PREFIX = "Apple Development: Created via API";

function log(message) {
  console.log(`[asc-cert-cleanup] ${message}`);
}

function warning(message) {
  const singleLine = String(message).replace(/\s+/g, " ").trim();
  console.log(`::warning::${singleLine}`);
  log(`WARNING: ${singleLine}`);
}

function base64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function requiredEnv(name, env) {
  const value = (env[name] || "").trim();
  if (!value) {
    throw new Error(`${name} is not set`);
  }
  return value;
}

function decodeBase64Secret(name, env) {
  const encoded = requiredEnv(name, env).replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded) || encoded.length % 4 === 1) {
    throw new Error(`${name} is not valid base64`);
  }
  const decoded = Buffer.from(encoded, "base64");
  if (decoded.length === 0) {
    throw new Error(`${name} decoded to an empty value`);
  }
  return decoded;
}

function buildJwt(env) {
  const keyId = requiredEnv("APP_STORE_CONNECT_KEY_ID", env);
  const issuerId = requiredEnv("APP_STORE_CONNECT_ISSUER_ID", env);
  const privateKey = crypto.createPrivateKey(decodeBase64Secret("APP_STORE_CONNECT_API_KEY", env));
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = {
    iss: issuerId,
    iat: now,
    exp: now + JWT_TTL_SECONDS,
    aud: JWT_AUDIENCE,
  };
  const signingInput = [
    base64url(JSON.stringify(header)),
    base64url(JSON.stringify(payload)),
  ].join(".");
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

async function apiRequest(method, path, jwt) {
  if (typeof fetch !== "function") {
    throw new Error("Node.js fetch is required for App Store Connect API calls");
  }

  const url = new URL(path, API_BASE_URL);
  if (url.origin !== API_BASE_URL || url.pathname !== "/v1/certificates" || method !== "GET") {
    throw new Error("List-only cleanup permits only certificate GET requests to Apple");
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30000);
  let response;
  try {
    response = await fetch(url, {
      method,
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${jwt}`,
      },
      signal: controller.signal,
    });
  } catch (error) {
    if (error.name === "AbortError") {
      throw new Error(`${method} ${url} timed out after 30 seconds`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`${method} ${url} failed with HTTP ${response.status}: ${body}`);
  }
  return body ? JSON.parse(body) : null;
}

// Read signing commands, not provisioning-profile membership or display names.
// Preserve ALL fingerprints in this archive, including nested targets. A missing
// or unrecognised signing identity makes the entire list unsafe to select from.
function archiveSigners(text) {
  if (!text.includes("** ARCHIVE SUCCEEDED **")) return null;
  const commands = text.split(/\r?\n/).filter(line => /(?:^|\s)(?:\S*\/)?codesign\s/.test(line));
  if (!commands.length) return null;
  const signers = new Set();
  for (const command of commands) {
    const match = command.match(/(?:^|\s)--sign\s+["']?([a-fA-F0-9]{40})["']?(?=\s|$)/);
    if (!match) return null;
    signers.add(match[1].toUpperCase());
  }
  return signers;
}

function decision(record, signers, now) {
  if (record?.attributes?.certificateType !== TARGET_CERTIFICATE_TYPE) return { reason: "not-development" };
  if (typeof record.id !== "string" || !record.id) return { reason: "missing-id" };
  try {
    const content = record.attributes.certificateContent;
    if (typeof content !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(content)) throw new Error();
    const der = Buffer.from(content, "base64");
    const cert = new crypto.X509Certificate(der);
    // Reject trailing bytes and PEM in an API field documented as base64 DER.
    if (!cert.raw.equals(der)) throw new Error();
    const fingerprint = cert.fingerprint.replace(/:/g, "").toUpperCase();
    if (signers.has(fingerprint)) return { reason: "archive-signer", fingerprint };
    const cn = cert.subject.split("\n").filter(part => part.startsWith("CN="));
    if (cn.length !== 1 || !(cn[0].slice(3) === API_SUBJECT_PREFIX ||
        cn[0].slice(3).startsWith(`${API_SUBJECT_PREFIX} (`))) return { reason: "not-api-created", fingerprint };
    const start = Date.parse(cert.validFrom);
    if (!Number.isFinite(start) || !Number.isFinite(now) || now - start <= MINIMUM_AGE_MS) {
      return { reason: "not-over-24-hours", fingerprint };
    }
    return { reason: "would-revoke", fingerprint };
  } catch {
    return { reason: "unreadable-certificate" };
  }
}

async function loadCertificates(jwt, request) {
  const certificates = [];
  const visited = new Set();
  let path = CERTIFICATES_PATH;
  while (path) {
    const url = new URL(path, API_BASE_URL);
    if (url.origin !== API_BASE_URL || url.pathname !== "/v1/certificates" || visited.has(url.href) || visited.size >= 100) {
      throw new Error("Unsafe or repeated certificate pagination link");
    }
    visited.add(url.href);
    const payload = await request("GET", url.href, jwt);
    if (!Array.isArray(payload?.data)) throw new Error("Certificate list response did not contain a data array");
    certificates.push(...payload.data);
    path = payload.links?.next;
    if (path != null && typeof path !== "string") throw new Error("Invalid certificate pagination link");
  }
  return certificates;
}

async function run({ env = process.env, request = apiRequest, now = Date.now(), write = log } = {}) {
  // Intentionally NO DELETE implementation, opt-in flag or automatic promotion.
  // Captain review of the first live list is required before a separate change.
  write("List-only mode: revocation is disabled");
  if (!(env.RUNNER_NAME || "").startsWith("mini-mac")) {
    write("Skipping: this is not the Mac mini runner");
    return;
  }
  let signers;
  try {
    signers = archiveSigners(fs.readFileSync(requiredEnv("ASC_CERTIFICATE_CLEANUP_ARCHIVE_LOG", env), "utf8"));
  } catch {
    write("Skipping: archive signing evidence is unavailable");
    return;
  }
  if (!signers) {
    write("Skipping: successful archive and every signing fingerprint are required");
    return;
  }
  const certificates = await loadCertificates(buildJwt(env), request);
  let candidates = 0;
  for (const record of certificates) {
    const result = decision(record, signers, now);
    if (result.reason === "would-revoke") candidates++;
    // Do not print CN, key/team IDs, serials, certificate content or raw errors.
    write(`${result.reason === "would-revoke" ? "Would revoke" : "Keep"}: fingerprint=${result.fingerprint || "unavailable"}; reason=${result.reason}`);
  }
  write(`List complete: ${candidates} would revoke; ${certificates.length - candidates} kept; 0 revoked`);
}

if (require.main === module) {
  run().catch(() => warning("Skipping certificate list: request, credentials or response could not be validated; nothing was revoked"));
}
module.exports = { run, decision, archiveSigners };
