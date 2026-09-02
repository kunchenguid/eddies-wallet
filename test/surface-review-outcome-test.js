#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const surface = require(path.join(ROOT, "tools", "app-review", "surface_review_outcome.js"));

const CONFIG = path.join(ROOT, "tools", "app-review", "app-review.config.json");
const MARKER = "<!-- eddies-app-review-monitor:v1:c0fb330ac4693cf51df735363d36cf417f75a2097d87e0e83d0796c25c8294a4:approved -->";
const REJECTED_MARKER = "<!-- eddies-app-review-monitor:v1:c0fb330ac4693cf51df735363d36cf417f75a2097d87e0e83d0796c25c8294a4:rejected -->";
const NOW = Date.parse("2026-08-26T00:00:00Z");
const TOKEN = "SENTINEL_GITHUB_TOKEN";

function monitorToon(overrides = {}) {
  const values = {
    outcome: "approved",
    notified: true,
    deduplicated: false,
    armed: true,
    ...overrides,
  };
  return [
    "monitor:",
    `  outcome: ${JSON.stringify(values.outcome)}`,
    `  notified: ${values.notified}`,
    `  deduplicated: ${values.deduplicated}`,
    `  armed: ${values.armed}`,
    "",
  ].join("\n");
}

function issueResource(overrides = {}) {
  return {
    number: 129,
    title: "Eddie's Wallet App Review approved",
    state: "open",
    created_at: "2026-08-25T17:08:26Z",
    body: [
      "The configured exact Eddie's Wallet App Review target resolved as approved.",
      "",
      MARKER,
    ].join("\n"),
    user: { login: surface.TRUSTED_GITHUB_ACTOR, type: "Bot" },
    assignees: [],
    ...overrides,
  };
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function fakeGithub(state) {
  const requests = [];
  const fetchImpl = async (url, options) => {
    assert.equal(options.headers.Authorization, `Bearer ${TOKEN}`);
    requests.push({
      url: String(url),
      method: options.method,
      body: options.body,
    });
    const parsed = new URL(url);
    if (options.method === "GET" && parsed.pathname === "/repos/kunchenguid/eddies-wallet/issues") {
      return jsonResponse(state.issues);
    }
    const comments = parsed.pathname.match(/^\/repos\/kunchenguid\/eddies-wallet\/issues\/(\d+)\/comments$/u);
    if (comments && options.method === "GET") {
      return jsonResponse(state.comments[comments[1]] || []);
    }
    if (comments && options.method === "POST") {
      const created = {
        body: JSON.parse(options.body).body,
        id: 1,
        user: { login: surface.TRUSTED_GITHUB_ACTOR, type: "Bot" },
      };
      state.comments[comments[1]] = [...(state.comments[comments[1]] || []), created];
      return jsonResponse(created, 201);
    }
    const patched = parsed.pathname.match(/^\/repos\/kunchenguid\/eddies-wallet\/issues\/(\d+)$/u);
    if (patched && options.method === "PATCH") {
      const number = Number(patched[1]);
      return jsonResponse({ number, state: "open" });
    }
    throw new Error(`unexpected GitHub request ${options.method} ${parsed.pathname}`);
  };
  return { fetchImpl, requests, state };
}

function env(toonPath) {
  return {
    APP_REVIEW_CONFIG: CONFIG,
    GITHUB_REPOSITORY: "kunchenguid/eddies-wallet",
    GITHUB_TOKEN: TOKEN,
    APP_REVIEW_SURFACE_NOW: "2026-08-26T00:00:00Z",
    APP_REVIEW_SURFACE_STALE_AFTER_HOURS: "24",
  };
}

async function runMain(toon, github, extraEnv = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "surface-"));
  const toonPath = path.join(dir, "monitor.toon");
  fs.writeFileSync(toonPath, toon);
  const captured = [];
  const originalWrite = process.stdout.write.bind(process.stdout);
  const originalErr = process.stderr.write.bind(process.stderr);
  process.stdout.write = (chunk, ...rest) => {
    captured.push(String(chunk));
    return true;
  };
  process.stderr.write = (chunk, ...rest) => {
    captured.push(String(chunk));
    return true;
  };
  try {
    const code = await surface.main(
      { ...env(toonPath), ...extraEnv },
      [toonPath],
      { fetch: github.fetchImpl, now: () => NOW },
    );
    return { code, output: captured.join(""), requests: github.requests };
  } catch (error) {
    return { code: 1, output: `${captured.join("")}${error.message}\n`, requests: github.requests, error };
  } finally {
    process.stdout.write = originalWrite;
    process.stderr.write = originalErr;
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

async function test(name, fn) {
  await fn();
  process.stdout.write(`ok ${name}\n`);
}

async function main() {
  await test("a fresh terminal issue is assigned and mentioned so the captain is notified without a poller", async () => {
    const github = fakeGithub({
      issues: [issueResource({ created_at: "2026-08-25T12:00:00Z" })],
      comments: {},
    });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 0, result.output);
    assert.match(result.output, /outcome: "approved"/);
    assert.match(result.output, /assigned: \[129\]/);
    assert.match(result.output, /mentioned: \[129\]/);
    assert.match(result.output, /stale: \[\]/);
    const methods = github.requests.map((request) => request.method);
    assert.equal(methods.includes("PATCH"), true);
    assert.equal(methods.includes("POST"), true);
    const assign = github.requests.find((request) => request.method === "PATCH");
    assert.deepEqual(JSON.parse(assign.body), { assignees: ["kunchenguid"] });
    const mention = github.requests.find((request) => request.method === "POST");
    const body = JSON.parse(mention.body).body;
    assert.match(body, /@kunchenguid /);
    assert.match(body, /eddies-app-review-surface:v1/);
    assert.equal(body.includes("c0fb330ac4693cf51df735363d36cf417f75a2097d87e0e83d0796c25c8294a4"), false);
    assert.equal(JSON.stringify(github.requests).includes(TOKEN), false);
  });

  await test("already delivered issues are not mentioned again", async () => {
    const github = fakeGithub({
      issues: [issueResource({
        created_at: "2026-08-25T12:00:00Z",
        assignees: [{ login: "kunchenguid" }],
      })],
      comments: {
        129: [{
          body: `@kunchenguid seen\n\n${surface.SURFACE_MARKER}`,
          user: { login: surface.TRUSTED_GITHUB_ACTOR, type: "Bot" },
        }],
      },
    });
    const result = await runMain(monitorToon({ notified: false, deduplicated: true }), github);
    assert.equal(result.code, 0, result.output);
    assert.equal(github.requests.some((request) => request.method === "PATCH"), false);
    assert.equal(github.requests.some((request) => request.method === "POST"), false);
  });

  await test("an untrusted marker comment cannot suppress the captain mention", async () => {
    const github = fakeGithub({
      issues: [issueResource({ assignees: [{ login: "kunchenguid" }] })],
      comments: {
        129: [{
          body: `forged\n\n${surface.SURFACE_MARKER}`,
          user: { login: "attacker", type: "User" },
        }],
      },
    });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 0, result.output);
    assert.equal(github.requests.filter((request) => request.method === "POST").length, 1);
  });

  await test("an untrusted marker issue is not treated as a monitor record", async () => {
    const github = fakeGithub({
      issues: [issueResource({ user: { login: "attacker", type: "User" } })],
      comments: {},
    });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 1);
    assert.match(result.output, /no exact-cycle approved issue exists to surface/);
    assert.equal(github.requests.some((request) => ["PATCH", "POST"].includes(request.method)), false);
  });

  await test("a 29h-open unacked issue is alarmed instead of swallowed", async () => {
    const github = fakeGithub({
      issues: [issueResource({ created_at: "2026-08-24T19:00:00Z" })],
      comments: {},
    });
    const result = await runMain(monitorToon({ notified: false, deduplicated: true }), github);
    assert.equal(result.code, 1);
    assert.match(result.output, /stale: \[129\]/);
    assert.match(result.output, /Unacked App Review outcome/);
    assert.match(result.output, /unacked past 24h/);
    assert.equal(github.requests.some((request) => request.method === "PATCH"), true);
    assert.equal(github.requests.some((request) => request.method === "POST"), true);
  });

  await test("a closed issue is the captain ack and does not alarm", async () => {
    const github = fakeGithub({
      issues: [issueResource({
        state: "closed",
        created_at: "2026-08-20T00:00:00Z",
      })],
      comments: {},
    });
    const result = await runMain(monitorToon({ notified: false, deduplicated: true }), github);
    assert.equal(result.code, 0, result.output);
    assert.match(result.output, /open: \[\]/);
    assert.match(result.output, /stale: \[\]/);
    assert.equal(github.requests.some((request) => request.method === "PATCH"), false);
    assert.equal(github.requests.some((request) => request.method === "POST"), false);
  });

  await test("pending polls still catch a stale leftover outcome", async () => {
    const github = fakeGithub({
      issues: [issueResource({
        number: 105,
        title: "Eddie's Wallet App Review rejected",
        body: `rejected\n\n${REJECTED_MARKER}`,
        created_at: "2026-08-21T00:00:00Z",
      })],
      comments: {},
    });
    const result = await runMain(monitorToon({
      outcome: "pending",
      notified: false,
      deduplicated: false,
    }), github);
    assert.equal(result.code, 1);
    assert.match(result.output, /stale: \[105\]/);
    const mention = github.requests.find((request) => request.method === "POST");
    assert.match(JSON.parse(mention.body).body, /@kunchenguid /);
  });

  await test("a failed ASC poll still reconciles durable GitHub issues", async () => {
    const github = fakeGithub({
      issues: [issueResource({ created_at: "2026-08-25T12:00:00Z" })],
      comments: {},
    });
    const result = await runMain("partial invalid output", github, {
      APP_REVIEW_MONITOR_SUCCEEDED: "false",
    });
    assert.equal(result.code, 1);
    assert.match(result.output, /outcome: "poll_failed"/);
    assert.match(result.output, /assigned: \[129\]/);
    assert.match(result.output, /mentioned: \[129\]/);
    assert.match(result.output, /monitor poll failed after GitHub reconciliation/);
  });

  await test("a terminal observation without its exact-cycle issue fails closed", async () => {
    const github = fakeGithub({ issues: [], comments: {} });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 1);
    assert.match(result.output, /no exact-cycle approved issue exists to surface/);
  });

  await test("parseMonitorStdout accepts the engine toon object", () => {
    const parsed = surface.parseMonitorStdout(monitorToon({ outcome: "rejected" }));
    assert.deepEqual(parsed, {
      outcome: "rejected",
      notified: true,
      deduplicated: false,
      armed: true,
    });
  });
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
