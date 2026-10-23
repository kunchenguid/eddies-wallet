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
// Issue #148 (0.1.19 approved, closed 2026-10-11) and issue #160 (0.1.21
// approved), as the engine and this consumer wrote them in this repository.
const MARKER_0_1_19 = "<!-- eddies-app-review-monitor:v1:ac94f4e64d8905f0849fbf82629d24e2d20172e7001b24ff6f7fbf1e89268326:approved -->";
const MARKER_0_1_21 = "<!-- eddies-app-review-monitor:v1:1d0fe773466f2790d9d6054d500f54c6f77b0f61619d51670ac2b87bf28c3f1f:approved -->";
// The armed 0.1.22 cycle; the engine hashes "v1\0<appId>\0<version>".
const MARKER_0_1_22 = "<!-- eddies-app-review-monitor:v1:03137a770878781e79ddd87d97cd0ac12de285f785927faa3d509acaf4bfd777:approved -->";
const TOKEN = "SENTINEL_GITHUB_TOKEN";
const BOT = { login: "github-actions[bot]", type: "Bot" };

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

// Issue #160 as the monitor run of 2026-10-23T03:49Z read it: assigned and
// mentioned on 2026-10-13, still open, and failing every run until this change.
function issue160() {
  return issueResource({
    number: 160,
    created_at: "2026-10-13T08:55:56Z",
    body: [
      "The configured exact Eddie's Wallet App Review target resolved as approved.",
      "",
      "This notification contains no App Store resource identifier or private review metadata.",
      "Reviewer-host cleanup remains disabled and requires separate authority.",
      "",
      MARKER_0_1_21,
    ].join("\n"),
    assignees: [{ login: "kunchenguid" }],
  });
}

function issue148() {
  return issueResource({
    number: 148,
    state: "closed",
    created_at: "2026-09-16T23:13:14Z",
    body: `The configured exact Eddie's Wallet App Review target resolved as approved.\n\n${MARKER_0_1_19}`,
    assignees: [{ login: "kunchenguid" }],
  });
}

function deliveredMention(appName = "Eddie's Wallet") {
  return {
    body: `@kunchenguid ${appName} App Review resolved as approved.\n\n${surface.SURFACE_MARKER}`,
    user: BOT,
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
      const issues = state.issuePages?.length ? state.issuePages.shift() : state.issues;
      return jsonResponse(issues);
    }
    const comments = parsed.pathname.match(/^\/repos\/kunchenguid\/eddies-wallet\/issues\/(\d+)\/comments$/u);
    if (comments && options.method === "GET") {
      return jsonResponse(state.comments[comments[1]] || []);
    }
    if (comments && options.method === "POST") {
      if (state.failMention) return jsonResponse({ message: "Server Error" }, 502);
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
      const change = JSON.parse(options.body);
      const issue = state.issues.find((entry) => entry.number === number);
      if (change.state === "closed" && state.failClose) return jsonResponse({ message: "Server Error" }, 502);
      if (issue && change.assignees) issue.assignees = change.assignees.map((login) => ({ login }));
      if (issue && change.state) issue.state = change.state;
      return jsonResponse({ number, state: issue ? issue.state : "open" });
    }
    throw new Error(`unexpected GitHub request ${options.method} ${parsed.pathname}`);
  };
  return { fetchImpl, requests, state };
}

function writes(github) {
  return github.requests
    .filter((request) => request.method !== "GET")
    .map((request) => {
      const pathname = new URL(request.url).pathname.replace("/repos/kunchenguid/eddies-wallet/issues/", "");
      const body = JSON.parse(request.body);
      if (request.method === "POST") return `mention ${pathname.split("/")[0]}`;
      if (body.state === "closed") return `close ${pathname}`;
      return `assign ${pathname}`;
    });
}

function env() {
  return {
    APP_REVIEW_CONFIG: CONFIG,
    GITHUB_REPOSITORY: "kunchenguid/eddies-wallet",
    GITHUB_TOKEN: TOKEN,
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
      { ...env(), ...extraEnv },
      [toonPath],
      { fetch: github.fetchImpl, sleep: async () => {} },
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
  // The captain's ask (task EDW-36): acknowledging an App Review decision
  // "should be automated... not manually done by me". The monitor closes each
  // outcome issue itself, and only after the captain has been notified.

  await test("a fresh decision is assigned, mentioned, then closed by the monitor in one passing run", async () => {
    const github = fakeGithub({
      issues: [issueResource({ created_at: "2026-08-25T17:08:25Z" })],
      comments: {},
    });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 0, result.output);
    assert.match(result.output, /outcome: "approved"/);
    assert.match(result.output, /assigned: \[129\]/);
    assert.match(result.output, /mentioned: \[129\]/);
    assert.match(result.output, /closed: \[129\]/);
    assert.match(result.output, /::notice title=App Review outcome delivered::issue #129 was assigned, mentioned, and closed/);
    assert.deepEqual(writes(github), ["assign 129", "mention 129", "close 129"]);
    const assign = github.requests.find((request) => request.method === "PATCH");
    assert.deepEqual(JSON.parse(assign.body), { assignees: ["kunchenguid"] });
    const close = github.requests.filter((request) => request.method === "PATCH").at(-1);
    assert.deepEqual(JSON.parse(close.body), { state: "closed", state_reason: "completed" });
    const mention = github.requests.find((request) => request.method === "POST");
    const body = JSON.parse(mention.body).body;
    assert.match(body, /@kunchenguid /);
    assert.match(body, /eddies-app-review-surface:v1/);
    assert.match(body, /nothing needs closing by hand/);
    assert.doesNotMatch(body, /Close it/);
    assert.equal(body.includes("c0fb330ac4693cf51df735363d36cf417f75a2097d87e0e83d0796c25c8294a4"), false);
    assert.equal(JSON.stringify(github.requests).includes(TOKEN), false);
    assert.equal(github.state.issues[0].state, "closed");
  });

  await test("issue #160, left open and already delivered, is closed on a pending poll and the run passes", async () => {
    const github = fakeGithub({
      issues: [issue160(), issue148()],
      comments: { 160: [deliveredMention()] },
    });
    const result = await runMain(monitorToon({
      outcome: "pending",
      notified: false,
      deduplicated: false,
    }), github);
    assert.equal(result.code, 0, result.output);
    assert.match(result.output, /open: \[160\]/);
    assert.match(result.output, /closed: \[160\]/);
    assert.deepEqual(writes(github), ["close 160"]);
    assert.doesNotMatch(result.output, /::error/);
  });

  await test("a fresh decision waits for its own open issue instead of settling for an older closed one", async () => {
    const fresh = issueResource({
      number: 171,
      created_at: "2026-10-24T18:00:00Z",
      body: `The configured exact Eddie's Wallet App Review target resolved as approved.\n\n${MARKER_0_1_22}`,
    });
    const closed160 = { ...issue160(), state: "closed" };
    // GitHub's first list read lags behind the engine's create; the next one shows it.
    const github = fakeGithub({
      issues: [fresh, closed160, issue148()],
      issuePages: [[closed160, issue148()]],
      comments: { 160: [deliveredMention()] },
    });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 0, result.output);
    const issueLists = github.requests.filter((request) => request.method === "GET"
      && new URL(request.url).pathname === "/repos/kunchenguid/eddies-wallet/issues");
    assert.equal(issueLists.length, 2);
    assert.deepEqual(writes(github), ["assign 171", "mention 171", "close 171"]);
  });

  await test("an issue is never closed when the captain mention could not be posted", async () => {
    const github = fakeGithub({
      issues: [issueResource()],
      comments: {},
      failMention: true,
    });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 1);
    assert.deepEqual(writes(github), ["assign 129", "mention 129"]);
    assert.equal(github.state.issues[0].state, "open");
  });

  await test("a failed close fails the run, and the next run closes without a second mention", async () => {
    const state = { issues: [issueResource()], comments: {}, failClose: true };
    const first = fakeGithub(state);
    const failed = await runMain(monitorToon(), first);
    assert.equal(failed.code, 1);
    assert.match(failed.output, /GitHub returned an unexpected status/);
    assert.deepEqual(writes(first), ["assign 129", "mention 129", "close 129"]);
    assert.equal(state.issues[0].state, "open");

    state.failClose = false;
    const second = fakeGithub(state);
    const passed = await runMain(monitorToon({ notified: false, deduplicated: true }), second);
    assert.equal(passed.code, 0, passed.output);
    assert.deepEqual(writes(second), ["close 129"]);
    assert.equal(state.comments[129].length, 1);
    assert.equal(state.issues[0].state, "closed");
  });

  await test("a just-created terminal issue is surfaced after GitHub's issue list catches up", async () => {
    const issue = issueResource({ created_at: "2026-08-25T12:00:00Z" });
    const github = fakeGithub({
      issues: [issue],
      issuePages: [[], [issue]],
      comments: {},
    });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 0, result.output);
    const issueLists = github.requests.filter((request) => request.method === "GET"
      && new URL(request.url).pathname === "/repos/kunchenguid/eddies-wallet/issues");
    assert.equal(issueLists.length, 2);
    assert.match(result.output, /assigned: \[129\]/);
    assert.match(result.output, /mentioned: \[129\]/);
    assert.match(result.output, /closed: \[129\]/);
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
    assert.deepEqual(writes(github), ["mention 129", "close 129"]);
  });

  await test("an untrusted marker issue is neither surfaced nor closed", async () => {
    const github = fakeGithub({
      issues: [issueResource({ user: { login: "attacker", type: "User" } })],
      comments: {},
    });
    const result = await runMain(monitorToon(), github);
    assert.equal(result.code, 1);
    assert.match(result.output, /no exact-cycle approved issue exists to surface/);
    assert.deepEqual(writes(github), []);
  });

  await test("closed outcome issues are left alone", async () => {
    const github = fakeGithub({
      issues: [{ ...issue160(), state: "closed" }, issue148(), issueResource({
        number: 105,
        state: "closed",
        title: "Eddie's Wallet App Review rejected",
        body: `rejected\n\n${REJECTED_MARKER}`,
        created_at: "2026-08-21T20:55:30Z",
      })],
      comments: {},
    });
    const result = await runMain(monitorToon({ notified: false, deduplicated: true }), github);
    assert.equal(result.code, 0, result.output);
    assert.match(result.output, /open: \[\]/);
    assert.match(result.output, /closed: \[\]/);
    assert.deepEqual(writes(github), []);
  });

  await test("a failed ASC poll still delivers and closes durable GitHub issues, then fails", async () => {
    const github = fakeGithub({
      issues: [issueResource({ created_at: "2026-08-25T12:00:00Z" })],
      comments: {},
    });
    const result = await runMain("partial invalid output", github, {
      APP_REVIEW_MONITOR_SUCCEEDED: "false",
    });
    assert.equal(result.code, 1);
    assert.match(result.output, /outcome: "poll_failed"/);
    assert.deepEqual(writes(github), ["assign 129", "mention 129", "close 129"]);
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
