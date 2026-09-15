#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const adapter = require(path.join(ROOT, "tools", "app-review", "create_version.js"));

async function test(name, fn) {
  await fn();
  process.stdout.write(`ok ${name}\n`);
}

function baseEnv() {
  return {
    GITHUB_REPOSITORY: "kunchenguid/eddies-wallet",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_WORKSPACE: ROOT,
    RUNNER_TEMP: fs.mkdtempSync(path.join(os.tmpdir(), "eddies-create-version-")),
    EDDIES_APP_REVIEW_VERSION: "0.1.19",
    EDDIES_APP_REVIEW_CONFIRM: "0.1.19",
    APP_STORE_CONNECT_API_KEY: "test-key",
    APP_STORE_CONNECT_ISSUER_ID: "test-issuer",
    APP_STORE_CONNECT_KEY_ID: "test-key-id",
    APP_REVIEW_CONFIG: path.join(ROOT, "tools", "app-review", "app-review.config.json"),
    CREATE_VERSION_ENGINE_ARGV: JSON.stringify(adapter.EXPECTED_ENGINE_ARGV),
  };
}

async function main() {
  await test("create-version requires --create-version and refuses submit", () => {
    assert.throws(() => adapter.parseCreateVersionArgv([]), /create-version is required/);
    assert.throws(() => adapter.parseCreateVersionArgv(["--submit"]), /refusing a submit flag/);
    assert.throws(
      () => adapter.parseCreateVersionArgv(["--create-version", "--assemble-only"]),
      /refusing an assemble-only flag/,
    );
    assert.throws(
      () => adapter.parseCreateVersionArgv(["--create-version", "--upload-screenshots"]),
      /refusing an upload-screenshots flag/,
    );
    assert.throws(() => adapter.parseCreateVersionArgv(["--mystery"]), /unknown option/);
    assert.deepEqual(
      adapter.parseCreateVersionArgv(["--create-version"]),
      {
        assembleOnly: false,
        uploadScreenshots: false,
        createVersion: true,
        firstRelease: false,
      },
    );
  });

  await test("CREATE_VERSION_ENGINE_ARGV must be the engine create-version CLI", () => {
    assert.throws(() => adapter.parseEngineArgv({}), /CREATE_VERSION_ENGINE_ARGV is required/);
    assert.throws(
      () => adapter.parseEngineArgv({ CREATE_VERSION_ENGINE_ARGV: "not-json" }),
      /must be a JSON argv array/,
    );
    assert.throws(
      () => adapter.parseEngineArgv({
        CREATE_VERSION_ENGINE_ARGV: JSON.stringify(["node", "app_review_pipeline.js", "submit"]),
      }),
      /must be \["node","app_review_pipeline.js","create-version"\]/,
    );
    assert.deepEqual(
      adapter.parseEngineArgv({
        CREATE_VERSION_ENGINE_ARGV: '["node","app_review_pipeline.js","create-version"]',
      }),
      adapter.EXPECTED_ENGINE_ARGV,
    );
  });

  await test("runCreateVersion skips evidence, never submits, and never maps the monitor", async () => {
    const env = baseEnv();
    const calls = [];
    try {
      await adapter.runCreateVersion({
        argv: ["--create-version"],
        env,
        verifyEvidence: () => {
          throw new Error("create-version must not verify reviewer-path evidence");
        },
        loadEngineModules: () => ({
          formatSuccess: (result) => `status: ${result.status}\nsubmitted: ${result.submitted}\n`,
        }),
        runSubmission: async (args, credentials, dependencies) => {
          calls.push({ args, dependencies });
          assert.equal(args.assembleOnly, false);
          assert.equal(args.uploadScreenshots, false);
          assert.equal(args.createVersion, true);
          assert.equal(args.firstRelease, false);
          assert.equal(args.version, "0.1.19");
          assert.equal(args.baselineVersion, "0.1.17");
          assert.equal(dependencies.monitorVariable, undefined);
          assert.equal(dependencies.verifyEvidence, undefined);
          return {
            result: {
              status: "version_created",
              submitted: false,
              remaining: "assemble",
              version: args.version,
              build: args.build,
            },
          };
        },
      });
    } finally {
      fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
    }
    assert.equal(calls.length, 1);
    assert.equal(calls[0].args.createVersion, true);
    assert.equal(calls[0].dependencies.monitorVariable, undefined);
  });

  await test("create-version refuses a first-release manifest", async () => {
    const env = baseEnv();
    env.EDDIES_APP_REVIEW_VERSION = "0.1.17";
    env.EDDIES_APP_REVIEW_CONFIRM = "0.1.17";
    await assert.rejects(
      () => adapter.runCreateVersion({
        argv: ["--create-version", "--first-release"],
        env,
        verifyEvidence: () => {
          throw new Error("must not verify evidence");
        },
        loadEngineModules: () => ({ formatSuccess: () => "" }),
        runSubmission: async () => {
          throw new Error("must not reach the engine");
        },
      }),
      /only valid for an update/,
    );
  });

  await test("main prints engine SafeError fields to stdout", async () => {
    const chunks = [];
    const write = process.stdout.write.bind(process.stdout);
    process.stdout.write = (chunk, encoding, callback) => {
      chunks.push(typeof chunk === "string" ? chunk : chunk.toString());
      if (typeof encoding === "function") encoding();
      if (typeof callback === "function") callback();
      return true;
    };
    let exitCode;
    try {
      exitCode = await adapter.main(["--create-version"], {
        runCreateVersion: async () => {
          const error = new Error("internal");
          error.safeMessage = "App Store Connect rejected the bounded operation";
          error.code = "E_API";
          error.operation = "POST /v1/appStoreVersions";
          error.httpStatus = 409;
          error.appleCode = "ENTITY_ERROR.RELATIONSHIP.INVALID";
          error.detail = "The request cannot be fulfilled because of a conflict.";
          throw error;
        },
      });
    } finally {
      process.stdout.write = write;
    }
    const output = chunks.join("");
    assert.equal(exitCode, 1);
    assert.match(output, /code: "E_API"/);
    assert.match(output, /operation: "POST \/v1\/appStoreVersions"/);
    assert.match(output, /message: "App Store Connect rejected the bounded operation"/);
    assert.match(output, /httpStatus: 409/);
    assert.match(output, /appleCode: "ENTITY_ERROR.RELATIONSHIP.INVALID"/);
    assert.match(output, /detail: "The request cannot be fulfilled because of a conflict."/);
  });

  await test("runCreateVersion refuses a submitted result", async () => {
    const env = baseEnv();
    try {
      await assert.rejects(
        () => adapter.runCreateVersion({
          argv: ["--create-version"],
          env,
          verifyEvidence: () => {
            throw new Error("must not verify evidence");
          },
          loadEngineModules: () => ({ formatSuccess: () => "" }),
          runSubmission: async () => ({
            result: {
              status: "submitted",
              submitted: true,
              remaining: null,
            },
          }),
        }),
        /did not prove an unsubmitted created App Store version/,
      );
    } finally {
      fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
    }
  });

  process.stdout.write("all create-version adapter tests passed\n");
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack || error}\n`);
  process.exitCode = 1;
});
