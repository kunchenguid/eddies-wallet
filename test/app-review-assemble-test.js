#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const adapter = require(path.join(ROOT, "tools", "app-review", "assemble_only.js"));

async function test(name, fn) {
  await fn();
  process.stdout.write(`ok ${name}\n`);
}

async function main() {

  await test("assemble-only is required and a submit flag is refused", () => {
  assert.throws(() => adapter.parseAssembleArgv([]), /assemble-only is required/);
  assert.throws(() => adapter.parseAssembleArgv(["submit"]), /assemble-only is required/);
  assert.throws(() => adapter.parseAssembleArgv(["--submit"]), /refusing a submit flag/);
  assert.deepEqual(adapter.parseAssembleArgv(["--assemble-only"]), { assembleOnly: true, firstRelease: false });
  assert.deepEqual(adapter.parseAssembleArgv(["--no-submit"]), { assembleOnly: true, firstRelease: false });
  assert.deepEqual(
    adapter.parseAssembleArgv(["--assemble-only", "--first-release"]),
    { assembleOnly: true, firstRelease: true },
  );
});

  await test("the already-applied EULA line is appended exactly once", () => {
  const original = [
    "Cloud is optional.",
    "",
    "You can manage or cancel subscriptions in your Apple Account settings after purchase.",
    "",
    "VIRTUAL MONEY ONLY",
  ].join("\n");
  const once = adapter.descriptionWithAppliedEula(original);
  assert.match(once, new RegExp(adapter.EULA_URL.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")));
  assert.equal(adapter.descriptionWithAppliedEula(once), once);
  assert.equal(once.split(adapter.EULA_LINE).length - 1, 1);
});

  await test("engine source maps the captain-approved 0.1.17 listing and both screenshot slots", () => {
  const manifest = JSON.parse(fs.readFileSync(
    path.join(ROOT, "tools", "app-review", "manifests", "0.1.17.json"),
    "utf8",
  ));
  const config = JSON.parse(fs.readFileSync(
    path.join(ROOT, "tools", "app-review", "app-review.config.json"),
    "utf8",
  ));
  const source = adapter.buildEngineSource(ROOT, manifest, config);
  assert.equal(source.metadata.appName, "Eddie's Wallet");
  assert.equal(source.metadata.subtitle, "Virtual allowance practice");
  assert.equal(source.metadata.description, manifest.content.listing.description);
  assert.match(source.metadata.description, /Terms of Use \(EULA\): https:\/\/www\.apple\.com\/legal\/internet-services\/itunes\/dev\/stdeula\//);
  assert.equal(source.metadata.whatsNew, null);
  assert.equal(source.metadata.marketingUrl, "");
  assert.equal(source.screenshots.length, 2);
  assert.equal(source.screenshots[0].displayType, "APP_IPHONE_67");
  assert.equal(source.screenshots[0].files.length, 5);
  assert.equal(source.screenshots[1].displayType, "APP_IPAD_PRO_3GEN_129");
  assert.equal(source.screenshots[1].files.length, 5);
  assert.equal(source.screenshots[0].files[0].fileName, "iphone-6.9-kid-home.png");
  assert.equal(source.screenshots[0].files[0].fileSize, 497984);
  assert.equal(
    config.commerce.productIds.join(" "),
    "com.kunchenguid.eddieswallet.cloud.monthly com.kunchenguid.eddieswallet.cloud.annual",
  );
  assert.equal(manifest.candidate.firstRelease, true);
  assert.equal(manifest.candidate.baselineVersion, undefined);
  assert.equal(config.reviewDetails.demoAccountRequired, false);
  assert.equal(config.reviewDetails.demoAccountName, undefined);
  assert.equal(config.reviewDetails.demoAccountPassword, undefined);
  assert.equal(config.reviewDetails.contactEmail, "kun@kunchenguid.com");
});

  await test("runAssemble always passes assembleOnly:true and refuses a submitted result", async () => {
  const manifest = JSON.parse(fs.readFileSync(
    path.join(ROOT, "tools", "app-review", "manifests", "0.1.17.json"),
    "utf8",
  ));
  const calls = [];
  const env = {
    GITHUB_REPOSITORY: "kunchenguid/eddies-wallet",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_WORKSPACE: ROOT,
    RUNNER_TEMP: fs.mkdtempSync(path.join(require("node:os").tmpdir(), "eddies-assemble-")),
    EDDIES_APP_REVIEW_VERSION: "0.1.17",
    EDDIES_APP_REVIEW_CONFIRM: "0.1.17",
    EDDIES_APP_REVIEW_EVIDENCE: "not-used-when-verifyEvidence-is-injected",
    APP_STORE_CONNECT_API_KEY: "test-key",
    APP_STORE_CONNECT_ISSUER_ID: "test-issuer",
    APP_STORE_CONNECT_KEY_ID: "test-key-id",
    APP_REVIEW_CONFIG: path.join(ROOT, "tools", "app-review", "app-review.config.json"),
  };

  try {
    await adapter.runAssemble({
      argv: ["--assemble-only", "--first-release"],
      env,
      verifyEvidence: () => undefined,
      loadEngineModules: () => ({
        formatSuccess: (result) => `status: ${result.status}\nsubmitted: ${result.submitted}\n`,
      }),
      runSubmission: async (args, credentials, dependencies) => {
        calls.push(args);
        assert.equal(args.assembleOnly, true);
        assert.equal(args.firstRelease, true);
        assert.equal(args.baselineVersion, null);
        assert.equal(args.preflight, false);
        assert.equal(args.version, "0.1.17");
        assert.equal(args.build, manifest.candidate.build);
        assert.equal(args.expectedReleaseType, "AFTER_APPROVAL");
        assert.equal(dependencies.monitorVariable, undefined);
        return {
          result: {
            status: "assembled",
            submitted: false,
            remaining: "submit",
            version: args.version,
            build: args.build,
            mutations: 3,
          },
        };
      },
    });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].assembleOnly, true);
    assert.equal(calls[0].firstRelease, true);
    assert.equal(calls[0].baselineVersion, null);

    await assert.rejects(
      () => adapter.runAssemble({
        argv: ["--assemble-only", "--first-release"],
        env,
        verifyEvidence: () => undefined,
        loadEngineModules: () => ({ formatSuccess: () => "" }),
        runSubmission: async (args) => ({
          result: {
            status: "submitted",
            submitted: true,
            version: args.version,
            build: args.build,
          },
        }),
      }),
      /did not prove an unsubmitted review submission/,
    );
  } finally {
    fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
  }
});

  await test("runAssemble refuses to start without the assemble-only flag", async () => {
  await assert.rejects(
    () => adapter.runAssemble({ argv: [], env: { GITHUB_REPOSITORY: "kunchenguid/eddies-wallet" } }),
    /assemble-only is required/,
  );
});

  await test("a first-release manifest without --first-release is refused", async () => {
  const env = {
    GITHUB_REPOSITORY: "kunchenguid/eddies-wallet",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_WORKSPACE: ROOT,
    EDDIES_APP_REVIEW_VERSION: "0.1.17",
    EDDIES_APP_REVIEW_CONFIRM: "0.1.17",
    APP_STORE_CONNECT_API_KEY: "test-key",
    APP_STORE_CONNECT_ISSUER_ID: "test-issuer",
    APP_STORE_CONNECT_KEY_ID: "test-key-id",
  };
  await assert.rejects(
    () => adapter.runAssemble({
      argv: ["--assemble-only"],
      env,
      verifyEvidence: () => undefined,
      runSubmission: async () => {
        throw new Error("must not reach the engine");
      },
    }),
    /first-release manifest requires --first-release/,
  );
});

  process.stdout.write("all assemble-only adapter tests passed\n");
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack || error}\n`);
  process.exitCode = 1;
});
