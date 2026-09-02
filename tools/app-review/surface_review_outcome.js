#!/usr/bin/env node
"use strict";

// Mini-independent App Review outcome consumer.
//
// The shared engine already opens one exact-cycle GitHub issue on a terminal
// or sustained-unavailable observation. That issue is a durable record, but it
// is unassigned and does not notify the captain by itself. This script is the
// Eddie-owned surfacing path: it assigns the captain, posts one @mention, and
// fails the scheduled run when an outcome issue stays open past the stale
// window. GitHub assignment mail, the mention, and a failed Actions run are
// all independent of any firstmate home being alive.
//
// Closing the issue is the captain ack. This script never closes or acks.

const fs = require("node:fs");
const path = require("node:path");

const GITHUB_ORIGIN = "https://api.github.com";
const GITHUB_API_VERSION = "2022-11-28";
const REQUEST_TIMEOUT_MS = 20_000;
const MAX_RESPONSE_BYTES = 1024 * 1024;
const MAX_ISSUE_PAGES = 10;
const ISSUES_PER_PAGE = 100;
const MAX_COMMENT_PAGES = 5;
const COMMENTS_PER_PAGE = 100;
const DEFAULT_ASSIGNEE = "kunchenguid";
const DEFAULT_STALE_AFTER_HOURS = 24;
const SURFACE_MARKER = "<!-- eddies-app-review-surface:v1 -->";
const TRUSTED_GITHUB_ACTOR = "github-actions[bot]";
const MONITOR_OUTCOMES = new Set([
  "pending",
  "approved",
  "rejected",
  "resolved_other",
  "unavailable",
  "not_armed",
]);
const SURFACED_OUTCOMES = new Set([
  "approved",
  "rejected",
  "resolved_other",
  "unavailable",
]);
const ASSIGNEE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/u;
const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;

class SurfaceError extends Error {
  constructor(message) {
    super(message);
    this.name = "SurfaceError";
  }
}

function fail(message) {
  throw new SurfaceError(message);
}

function ensure(condition, message) {
  if (!condition) fail(message);
}

function isObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOwn(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function requiredEnv(env, name, maxLength = 4096) {
  const value = typeof env[name] === "string" ? env[name].trim() : "";
  ensure(value.length > 0 && value.length <= maxLength && !value.includes("\0"), `${name} is missing or invalid`);
  return value;
}

function loadEddieConfig(env, readFile = fs.readFileSync) {
  const configPath = path.resolve(
    typeof env.APP_REVIEW_CONFIG === "string" && env.APP_REVIEW_CONFIG.trim()
      ? env.APP_REVIEW_CONFIG.trim()
      : path.join(__dirname, "app-review.config.json"),
  );
  let raw;
  try {
    raw = JSON.parse(readFile(configPath, "utf8"));
  } catch {
    fail("APP_REVIEW_CONFIG is missing or invalid");
  }
  ensure(isObject(raw) && isObject(raw.app) && isObject(raw.github) && isObject(raw.monitor), "APP_REVIEW_CONFIG is missing or invalid");
  const repository = raw.github.repository;
  const prefix = raw.monitor.recordMarkerPrefix;
  const appName = raw.app.name;
  ensure(typeof repository === "string" && REPOSITORY_PATTERN.test(repository), "config.github.repository is invalid");
  ensure(typeof prefix === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u.test(prefix), "config.monitor.recordMarkerPrefix is invalid");
  ensure(typeof appName === "string" && appName.length > 0 && appName.length <= 64, "config.app.name is invalid");
  return Object.freeze({ repository, prefix, appName, markerNeedle: `<!-- ${prefix}:v1:` });
}

function parseMonitorStdout(text) {
  if (typeof text !== "string" || text.trim().length === 0) fail("monitor outcome missing");
  const lines = text.replace(/\r\n/gu, "\n").replace(/\n+$/u, "").split("\n");
  ensure(lines[0] === "monitor:", "monitor outcome is malformed");
  const values = {};
  for (const line of lines.slice(1)) {
    const match = /^  ([A-Za-z][A-Za-z0-9_]*): (.+)$/u.exec(line);
    ensure(match, "monitor outcome is malformed");
    const key = match[1];
    const raw = match[2];
    let value;
    if (raw === "true") value = true;
    else if (raw === "false") value = false;
    else if (raw === "null") value = null;
    else if (raw.startsWith("\"") && raw.endsWith("\"")) {
      try {
        value = JSON.parse(raw);
      } catch {
        fail("monitor outcome is malformed");
      }
    } else {
      fail("monitor outcome is malformed");
    }
    ensure(!hasOwn(values, key), "monitor outcome is malformed");
    values[key] = value;
  }
  ensure(typeof values.outcome === "string" && MONITOR_OUTCOMES.has(values.outcome), "monitor outcome is invalid");
  ensure(values.armed === true || values.armed === false, "monitor outcome is invalid");
  ensure(values.notified === true || values.notified === false, "monitor outcome is invalid");
  ensure(values.deduplicated === true || values.deduplicated === false, "monitor outcome is invalid");
  return Object.freeze(values);
}

function parseAssignee(env) {
  const raw = typeof env.APP_REVIEW_SURFACE_ASSIGNEE === "string" ? env.APP_REVIEW_SURFACE_ASSIGNEE.trim() : DEFAULT_ASSIGNEE;
  ensure(ASSIGNEE_PATTERN.test(raw), "APP_REVIEW_SURFACE_ASSIGNEE is invalid");
  return raw;
}

function parseStaleAfterMs(env) {
  const raw = typeof env.APP_REVIEW_SURFACE_STALE_AFTER_HOURS === "string"
    ? env.APP_REVIEW_SURFACE_STALE_AFTER_HOURS.trim()
    : String(DEFAULT_STALE_AFTER_HOURS);
  const hours = Number(raw);
  ensure(Number.isInteger(hours) && hours >= 1 && hours <= 168, "APP_REVIEW_SURFACE_STALE_AFTER_HOURS is invalid");
  return hours * 60 * 60 * 1000;
}

function parseNow(env, nowFn) {
  if (typeof nowFn === "function") return nowFn();
  const raw = typeof env.APP_REVIEW_SURFACE_NOW === "string" ? env.APP_REVIEW_SURFACE_NOW.trim() : "";
  if (raw.length > 0) {
    const parsed = Date.parse(raw);
    ensure(Number.isFinite(parsed), "APP_REVIEW_SURFACE_NOW is invalid");
    return parsed;
  }
  return Date.now();
}

function issueHasMonitorMarker(issue, markerNeedle) {
  return typeof issue.body === "string" && issue.body.includes(markerNeedle);
}

function hasTrustedActor(resource) {
  return isObject(resource.user)
    && resource.user.login === TRUSTED_GITHUB_ACTOR
    && resource.user.type === "Bot";
}

function issueKind(issue, prefix) {
  if (typeof issue.body !== "string") return null;
  const match = issue.body.match(new RegExp(`<!-- ${prefix}:v1:[0-9a-f]{64}:([A-Za-z0-9_]+) -->`, "u"));
  return match ? match[1] : null;
}

function mentionBody(appName, kind, assignee) {
  const outcome = kind === "unavailable"
    ? "remained unavailable after its bounded retries"
    : `resolved as ${kind.replace(/_/gu, " ")}`;
  return [
    `@${assignee} ${appName} App Review ${outcome}.`,
    "",
    "This issue is the durable captain record. Close it once you have seen the outcome.",
    "A later monitor run fails if it is still open after 24 hours, so a dead poller cannot swallow it.",
    "",
    SURFACE_MARKER,
  ].join("\n");
}

async function readLimited(response, limit = MAX_RESPONSE_BYTES) {
  const declared = response.headers && response.headers.get ? response.headers.get("content-length") : null;
  if (declared !== null && declared !== undefined) {
    const size = Number(declared);
    ensure(Number.isSafeInteger(size) && size >= 0 && size <= limit, "GitHub response size is invalid");
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  ensure(bytes.length <= limit, "GitHub response size is invalid");
  return bytes;
}

class GithubClient {
  constructor(token, repository, fetchImpl) {
    ensure(typeof fetchImpl === "function", "no HTTP transport is available");
    ensure(typeof token === "string" && token.length > 0, "GITHUB_TOKEN is missing or invalid");
    ensure(REPOSITORY_PATTERN.test(repository), "GitHub repository identity is invalid");
    this.token = token;
    this.repository = repository;
    this.fetch = fetchImpl;
  }

  async request(method, pathname, { body, expected = 200 } = {}) {
    let url;
    try {
      url = new URL(pathname, GITHUB_ORIGIN);
    } catch {
      fail("GitHub request URL is invalid");
    }
    ensure(
      url.origin === GITHUB_ORIGIN && url.protocol === "https:" && !url.username && !url.password && !url.hash,
      "GitHub request URL is untrusted",
    );
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
      const bytes = await readLimited(response);
      ensure(Boolean(response) && accepted.includes(response.status), "GitHub returned an unexpected status");
      if (bytes.length === 0) return null;
      try {
        return JSON.parse(bytes.toString("utf8"));
      } catch {
        fail("GitHub returned an invalid JSON body");
      }
    } catch (error) {
      if (error instanceof SurfaceError) throw error;
      fail("the GitHub request failed");
    } finally {
      clearTimeout(timeout);
    }
    return null;
  }

  async listMonitorIssues(markerNeedle) {
    const matches = [];
    let complete = false;
    for (let page = 1; page <= MAX_ISSUE_PAGES; page += 1) {
      const query = new URLSearchParams({
        state: "all",
        per_page: String(ISSUES_PER_PAGE),
        page: String(page),
        sort: "created",
        direction: "desc",
      });
      const issues = await this.request("GET", `/repos/${this.repository}/issues?${query}`);
      ensure(Array.isArray(issues) && issues.length <= ISSUES_PER_PAGE, "GitHub returned a malformed issue page");
      for (const issue of issues) {
        ensure(isObject(issue), "GitHub returned a malformed issue");
        if (hasOwn(issue, "pull_request")) continue;
        if (!issueHasMonitorMarker(issue, markerNeedle)) continue;
        if (!hasTrustedActor(issue)) continue;
        ensure(Number.isSafeInteger(issue.number) && issue.number >= 1, "GitHub returned a malformed issue");
        ensure(["open", "closed"].includes(issue.state), "GitHub returned a malformed issue");
        ensure(typeof issue.created_at === "string" && Number.isFinite(Date.parse(issue.created_at)), "GitHub returned a malformed issue");
        const assignees = Array.isArray(issue.assignees) ? issue.assignees : [];
        matches.push(Object.freeze({
          number: issue.number,
          state: issue.state,
          title: typeof issue.title === "string" ? issue.title : "",
          body: issue.body,
          createdAt: Date.parse(issue.created_at),
          assignees: Object.freeze(assignees.map((entry) => (isObject(entry) ? entry.login : "")).filter(Boolean)),
        }));
      }
      if (issues.length < ISSUES_PER_PAGE) {
        complete = true;
        break;
      }
    }
    ensure(complete, "the monitor notification search exceeded its bound");
    return matches;
  }

  async listComments(number) {
    const comments = [];
    let complete = false;
    for (let page = 1; page <= MAX_COMMENT_PAGES; page += 1) {
      const query = new URLSearchParams({
        per_page: String(COMMENTS_PER_PAGE),
        page: String(page),
      });
      const batch = await this.request("GET", `/repos/${this.repository}/issues/${number}/comments?${query}`);
      ensure(Array.isArray(batch) && batch.length <= COMMENTS_PER_PAGE, "GitHub returned a malformed comment page");
      for (const comment of batch) {
        ensure(isObject(comment) && typeof comment.body === "string", "GitHub returned a malformed comment");
        if (hasTrustedActor(comment)) comments.push(comment.body);
      }
      if (batch.length < COMMENTS_PER_PAGE) {
        complete = true;
        break;
      }
    }
    ensure(complete, "the monitor comment search exceeded its bound");
    return comments;
  }

  async assign(number, login) {
    const updated = await this.request("PATCH", `/repos/${this.repository}/issues/${number}`, {
      body: { assignees: [login] },
    });
    ensure(isObject(updated) && updated.number === number, "GitHub did not assign the monitor notification");
  }

  async comment(number, body) {
    const created = await this.request("POST", `/repos/${this.repository}/issues/${number}/comments`, {
      expected: 201,
      body: { body },
    });
    ensure(
      isObject(created)
        && hasTrustedActor(created)
        && typeof created.body === "string"
        && created.body.includes(SURFACE_MARKER),
      "GitHub did not record the captain mention",
    );
  }
}

function printSurface(payload) {
  const lines = ["surface:"];
  for (const [key, value] of Object.entries(payload)) {
    if (Array.isArray(value)) {
      lines.push(`  ${key}: [${value.map((item) => JSON.stringify(item)).join(", ")}]`);
    } else if (typeof value === "boolean") {
      lines.push(`  ${key}: ${value}`);
    } else {
      lines.push(`  ${key}: ${JSON.stringify(value)}`);
    }
  }
  process.stdout.write(`${lines.join("\n")}\n`);
}

function writeAnnotations(stale, staleAfterHours) {
  for (const issue of stale) {
    const hours = Math.floor(issue.ageMs / (60 * 60 * 1000));
    process.stdout.write(
      `::error title=Unacked App Review outcome::issue #${issue.number} has been open for ${hours}h (limit ${staleAfterHours}h)\n`,
    );
  }
}

async function surfaceReviewOutcome({ monitor, config, assignee, staleAfterMs, now, client }) {
  const issues = await client.listMonitorIssues(config.markerNeedle);
  const open = issues.filter((issue) => issue.state === "open");
  if (SURFACED_OUTCOMES.has(monitor.outcome)) {
    const matching = issues.filter((issue) => issueKind(issue, config.prefix) === monitor.outcome);
    ensure(matching.length > 0, `no exact-cycle ${monitor.outcome} issue exists to surface`);
  }

  const assigned = [];
  const mentioned = [];
  for (const issue of open) {
    if (!issue.assignees.includes(assignee)) {
      await client.assign(issue.number, assignee);
      assigned.push(issue.number);
    }
    const comments = await client.listComments(issue.number);
    if (!comments.some((body) => body.includes(SURFACE_MARKER))) {
      await client.comment(
        issue.number,
        mentionBody(config.appName, issueKind(issue, config.prefix) || monitor.outcome, assignee),
      );
      mentioned.push(issue.number);
    }
  }

  const stale = open
    .filter((issue) => now - issue.createdAt >= staleAfterMs)
    .map((issue) => Object.freeze({
      number: issue.number,
      ageMs: now - issue.createdAt,
    }));

  return Object.freeze({
    outcome: monitor.outcome,
    armed: monitor.armed,
    open: open.map((issue) => issue.number),
    assigned,
    mentioned,
    stale: stale.map((issue) => issue.number),
    staleIssues: stale,
  });
}

async function main(env = process.env, argv = process.argv.slice(2), deps = {}) {
  ensure(argv.length === 1, "surface_review_outcome requires exactly one monitor stdout file");
  const toonPath = argv[0];
  ensure(typeof toonPath === "string" && toonPath.length > 0, "monitor stdout path is invalid");
  const monitorSucceededRaw = typeof env.APP_REVIEW_MONITOR_SUCCEEDED === "string"
    ? env.APP_REVIEW_MONITOR_SUCCEEDED.trim()
    : "true";
  ensure(["true", "false"].includes(monitorSucceededRaw), "APP_REVIEW_MONITOR_SUCCEEDED is invalid");
  const monitorSucceeded = monitorSucceededRaw === "true";
  const readFile = deps.readFile || fs.readFileSync;
  let monitor;
  if (monitorSucceeded) {
    let text;
    try {
      text = readFile(toonPath, "utf8");
    } catch {
      fail("monitor stdout file is missing");
    }
    monitor = parseMonitorStdout(text);
  } else {
    monitor = Object.freeze({ outcome: "poll_failed", armed: false });
  }
  const config = loadEddieConfig(env, readFile);
  const repository = requiredEnv(env, "GITHUB_REPOSITORY", 128);
  ensure(repository === config.repository, "this action runs only in the trusted configured repository");
  const assignee = parseAssignee(env);
  const staleAfterMs = parseStaleAfterMs(env);
  const staleAfterHours = staleAfterMs / (60 * 60 * 1000);
  const now = parseNow(env, deps.now);
  const client = deps.client || new GithubClient(
    requiredEnv(env, "GITHUB_TOKEN"),
    repository,
    deps.fetch || globalThis.fetch,
  );
  const result = await surfaceReviewOutcome({
    monitor,
    config,
    assignee,
    staleAfterMs,
    now,
    client,
  });
  printSurface({
    outcome: result.outcome,
    armed: result.armed,
    open: result.open,
    assigned: result.assigned,
    mentioned: result.mentioned,
    stale: result.stale,
  });
  if (result.stale.length > 0) {
    writeAnnotations(result.staleIssues, staleAfterHours);
    fail(`open App Review outcome issue ${result.stale[0]} has been unacked past ${staleAfterHours}h`);
  }
  if (!monitorSucceeded) fail("monitor poll failed after GitHub reconciliation");
  return 0;
}

module.exports = {
  DEFAULT_ASSIGNEE,
  DEFAULT_STALE_AFTER_HOURS,
  GithubClient,
  SURFACE_MARKER,
  SURFACED_OUTCOMES,
  TRUSTED_GITHUB_ACTOR,
  main,
  parseMonitorStdout,
  surfaceReviewOutcome,
};

if (require.main === module) {
  main().then((code) => {
    process.exitCode = code;
  }).catch((error) => {
    const message = error instanceof SurfaceError && error.message
      ? error.message
      : "surface failed";
    process.stderr.write(`${message}\n`);
    process.exitCode = 1;
  });
}
