#!/usr/bin/env node

const crypto = require("node:crypto");
const fs = require("node:fs");

const API_BASE_URL = "https://api.appstoreconnect.apple.com";
const CERTIFICATES_PATH = "/v1/certificates?limit=200";
const JWT_AUDIENCE = "appstoreconnect-v1";
const JWT_TTL_SECONDS = 10 * 60;
const TARGET_CERTIFICATE_TYPE = "DEVELOPMENT";
const DEFAULT_KEEP_COUNT = 2;

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

function requiredEnv(name) {
  const value = (process.env[name] || "").trim();
  if (!value) {
    throw new Error(`${name} is not set`);
  }
  return value;
}

function decodeBase64Secret(name) {
  const encoded = requiredEnv(name).replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded) || encoded.length % 4 === 1) {
    throw new Error(`${name} is not valid base64`);
  }
  const decoded = Buffer.from(encoded, "base64");
  if (decoded.length === 0) {
    throw new Error(`${name} decoded to an empty value`);
  }
  return decoded;
}

function buildJwt() {
  const keyId = requiredEnv("APP_STORE_CONNECT_KEY_ID");
  const issuerId = requiredEnv("APP_STORE_CONNECT_ISSUER_ID");
  const privateKey = crypto.createPrivateKey(decodeBase64Secret("APP_STORE_CONNECT_API_KEY"));
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

  const url = path.startsWith("https://") ? path : `${API_BASE_URL}${path}`;
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

async function loadCertificates(jwt) {
  const fixturePath = (process.env.ASC_CERTIFICATE_CLEANUP_FIXTURE || "").trim();
  if (fixturePath) {
    log(`Using certificate fixture ${fixturePath}`);
    return JSON.parse(fs.readFileSync(fixturePath, "utf8"));
  }
  return apiRequest("GET", CERTIFICATES_PATH, jwt);
}

function attributes(certificate) {
  return certificate && typeof certificate.attributes === "object" && certificate.attributes
    ? certificate.attributes
    : {};
}

function certificateType(certificate) {
  const value = attributes(certificate).certificateType;
  return typeof value === "string" ? value : "";
}

function certificateSortKey(certificate) {
  const certAttributes = attributes(certificate);
  const dateValue = certAttributes.createdDate || certAttributes.expirationDate || "";
  return [String(dateValue), String(certificate.id || "")];
}

function compareCertificatesNewestFirst(left, right) {
  const leftKey = certificateSortKey(left);
  const rightKey = certificateSortKey(right);
  return rightKey[0].localeCompare(leftKey[0]) || rightKey[1].localeCompare(leftKey[1]);
}

function describeCertificate(certificate) {
  const certAttributes = attributes(certificate);
  return [
    ["id", certificate.id],
    ["type", certAttributes.certificateType],
    ["displayName", certAttributes.displayName],
    ["name", certAttributes.name],
    ["serialNumber", certAttributes.serialNumber],
    ["createdDate", certAttributes.createdDate],
    ["expirationDate", certAttributes.expirationDate],
  ]
    .filter(([, value]) => value !== undefined && value !== null && value !== "")
    .map(([key, value]) => `${key}=${value}`)
    .join(", ");
}

function readKeepCount() {
  const rawValue = process.env.ASC_CERTIFICATE_CLEANUP_KEEP || String(DEFAULT_KEEP_COUNT);
  if (!/^[0-9]+$/.test(rawValue)) {
    throw new Error(`ASC_CERTIFICATE_CLEANUP_KEEP must be an integer, got ${rawValue}`);
  }
  const value = Number.parseInt(rawValue, 10);
  if (value < 1) {
    throw new Error("ASC_CERTIFICATE_CLEANUP_KEEP must be at least 1");
  }
  return value;
}

function certificateTypeCounts(certificates) {
  const counts = new Map();
  for (const certificate of certificates) {
    const type = certificateType(certificate) || "UNKNOWN";
    counts.set(type, (counts.get(type) || 0) + 1);
  }
  return [...counts.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([type, count]) => `${type}=${count}`)
    .join(", ");
}

async function deleteCertificate(certificate, jwt) {
  if (certificateType(certificate) !== TARGET_CERTIFICATE_TYPE) {
    throw new Error(`Refusing to delete non-DEVELOPMENT certificate: ${describeCertificate(certificate)}`);
  }
  if (typeof certificate.id !== "string" || !certificate.id) {
    throw new Error(`Refusing to delete certificate without an id: ${describeCertificate(certificate)}`);
  }
  if (process.env.ASC_CERTIFICATE_CLEANUP_DRY_RUN === "1") {
    log(`Dry run: would revoke ${describeCertificate(certificate)}`);
    return;
  }
  await apiRequest("DELETE", `/v1/certificates/${encodeURIComponent(certificate.id)}`, jwt);
  log(`Revoked ${describeCertificate(certificate)}`);
}

async function pruneDevelopmentCertificates(jwt) {
  const payload = await loadCertificates(jwt);
  const certificates = Array.isArray(payload && payload.data) ? payload.data : null;
  if (!certificates) {
    throw new Error("Certificate list response did not contain a data array");
  }

  log(`Fetched ${certificates.length} certificates (${certificateTypeCounts(certificates)})`);
  const developmentCertificates = certificates
    .filter((certificate) => certificateType(certificate) === TARGET_CERTIFICATE_TYPE)
    .sort(compareCertificatesNewestFirst);
  const keep = readKeepCount();
  if (developmentCertificates.length <= keep) {
    log(`Found ${developmentCertificates.length} DEVELOPMENT certificates, keeping all of them`);
    return;
  }

  const retained = developmentCertificates.slice(0, keep);
  const surplus = developmentCertificates.slice(keep);
  log(`Keeping newest ${retained.length} DEVELOPMENT certificates:`);
  for (const certificate of retained) {
    log(`Keeping ${describeCertificate(certificate)}`);
  }

  log(`Revoking ${surplus.length} surplus DEVELOPMENT certificates`);
  let failures = 0;
  for (const certificate of surplus) {
    try {
      await deleteCertificate(certificate, jwt);
    } catch (error) {
      failures += 1;
      warning(`Could not revoke ${describeCertificate(certificate)}: ${error.message}`);
    }
  }

  if (failures > 0) {
    warning(`Certificate cleanup finished with ${failures} deletion failure(s); release result is unaffected`);
  } else {
    log("Certificate cleanup finished successfully");
  }
}

async function main() {
  try {
    const jwt = buildJwt();
    await pruneDevelopmentCertificates(jwt);
  } catch (error) {
    warning(`Skipping App Store Connect certificate cleanup: ${error.message}`);
  }
}

main();
