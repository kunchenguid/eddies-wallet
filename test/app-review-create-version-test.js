#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const adapter = require(path.join(ROOT, "tools", "app-review", "create_version.js"));
const approved = require("./app-review-approved-config");

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
    APP_REVIEW_CONFIG: approved.writeConfigAsApproved("0.1.19"),
    CREATE_VERSION_ENGINE_ARGV: JSON.stringify(adapter.EXPECTED_ENGINE_ARGV),
  };
}

// A next update after 0.1.22 in a scratch checkout: the 0.1.22 manifest as its
// baseline, the Parent-redesign screenshot bytes, and a 9.9.9 manifest built
// from the baseline by `change`.
function nextUpdateCheckout(change) {
  const config = approved.committedConfig();
  const baseline = approved.readManifest("0.1.22");
  const directory = config.listing.screenshotDirectory;
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "eddies-copy-write-")));
  fs.mkdirSync(path.join(root, ...directory), { recursive: true });
  for (const spec of config.listing.screenshotSpecs) {
    for (const fileName of spec.files) {
      fs.copyFileSync(path.join(ROOT, ...directory, fileName), path.join(root, ...directory, fileName));
    }
  }
  const manifest = structuredClone(baseline);
  manifest.candidate = { ...baseline.candidate, version: "9.9.9", build: "99.1", baselineVersion: "0.1.22" };
  manifest.content.listing.whatsNew = "Next update notes.";
  change(manifest);
  const manifests = path.join(root, "tools", "app-review", "manifests");
  fs.mkdirSync(manifests, { recursive: true });
  fs.writeFileSync(path.join(manifests, "0.1.22.json"), `${JSON.stringify(baseline, null, 2)}\n`);
  fs.writeFileSync(path.join(manifests, "9.9.9.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return root;
}

function approvedDescription() {
  return fs.readFileSync(path.join(ROOT, "tools", "app-review", "listing", "description.txt"), "utf8").replace(/\n$/u, "");
}

async function createNextUpdate(root, configPath = approved.CONFIG_PATH) {
  const env = baseEnv();
  env.GITHUB_WORKSPACE = root;
  env.EDDIES_APP_REVIEW_VERSION = "9.9.9";
  env.EDDIES_APP_REVIEW_CONFIRM = "9.9.9";
  env.APP_REVIEW_CONFIG = configPath;
  const calls = [];
  try {
    const created = await adapter.runCreateVersion({
      argv: ["--create-version"],
      env,
      loadEngineModules: (engineConfig) => {
        calls.push({ engineConfig });
        return { formatSuccess: () => "" };
      },
      runSubmission: async (args, credentials, dependencies) => {
        calls[calls.length - 1].dependencies = dependencies;
        return { result: { status: "version_created", submitted: false, remaining: "assemble" } };
      },
    });
    return { created, calls };
  } finally {
    fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
  }
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

  await test("create-version refuses config App Review notes the manifest did not approve", async () => {
    const env = baseEnv();
    env.EDDIES_APP_REVIEW_VERSION = "0.1.21";
    env.EDDIES_APP_REVIEW_CONFIRM = "0.1.21";
    env.APP_REVIEW_CONFIG = approved.CONFIG_PATH;
    const config = approved.committedConfig();
    assert.notEqual(
      config.reviewDetails.notes,
      approved.readManifest("0.1.21").content.appReview.notes,
      "the committed notes describe the redesigned Parent area, not the approved 0.1.21 text",
    );
    try {
      await assert.rejects(
        () => adapter.runCreateVersion({
          argv: ["--create-version"],
          env,
          loadEngineModules: () => ({ formatSuccess: () => "" }),
          runSubmission: async () => {
            throw new Error("must not reach the engine");
          },
        }),
        /config\.reviewDetails\.notes must match the captain-approved manifest App Review notes/,
      );
    } finally {
      fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
    }
  });

  await test("create-version maps a next update onto the Parent-redesign screenshots and notes", async () => {
    const config = approved.committedConfig();
    const previous = approved.readManifest("0.1.21");
    const directory = config.listing.screenshotDirectory;
    assert.deepEqual(directory, ["tools", "app-review", "assets", "screenshots", "parent-redesign"]);
    const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "eddies-next-update-")));
    fs.mkdirSync(path.join(root, ...directory), { recursive: true });
    const screenshots = config.listing.screenshotSpecs.map((spec) => ({
      displayType: spec.displayType,
      width: spec.width,
      height: spec.height,
      files: spec.files.map((fileName) => {
        const bytes = fs.readFileSync(path.join(ROOT, ...directory, fileName));
        fs.writeFileSync(path.join(root, ...directory, fileName), bytes);
        return {
          fileName,
          fileSize: bytes.length,
          sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
        };
      }),
    }));
    const manifest = {
      ...previous,
      candidate: { ...previous.candidate, version: "9.9.9", build: "99.1", baselineVersion: "0.1.21" },
      content: {
        ...previous.content,
        screenshots,
        appReview: { ...previous.content.appReview, notes: config.reviewDetails.notes },
      },
    };
    fs.mkdirSync(path.join(root, "tools", "app-review", "manifests"), { recursive: true });
    fs.writeFileSync(
      path.join(root, "tools", "app-review", "manifests", "9.9.9.json"),
      `${JSON.stringify(manifest, null, 2)}\n`,
    );
    const env = baseEnv();
    env.GITHUB_WORKSPACE = root;
    env.EDDIES_APP_REVIEW_VERSION = "9.9.9";
    env.EDDIES_APP_REVIEW_CONFIRM = "9.9.9";
    env.APP_REVIEW_CONFIG = approved.CONFIG_PATH;
    const calls = [];
    try {
      await adapter.runCreateVersion({
        argv: ["--create-version"],
        env,
        loadEngineModules: () => ({ formatSuccess: () => "" }),
        runSubmission: async (args, credentials, dependencies) => {
          calls.push({ args, dependencies });
          return {
            result: { status: "version_created", submitted: false, remaining: "assemble" },
          };
        },
      });
    } finally {
      fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
      fs.rmSync(root, { recursive: true, force: true });
    }
    assert.equal(calls.length, 1);
    const { args, dependencies } = calls[0];
    assert.equal(args.createVersion, true);
    assert.equal(args.version, "9.9.9");
    assert.equal(args.baselineVersion, "0.1.21");
    const mapped = dependencies.source.screenshots.flatMap((set) => set.files);
    assert.equal(mapped.length, 10);
    for (const file of mapped) {
      assert.equal(path.dirname(file.filePath), path.join(root, ...directory));
    }
    assert.deepEqual(
      mapped.map((file) => file.sha256),
      screenshots.flatMap((set) => set.files.map((file) => file.sha256)),
    );
    const previousHashes = new Set(
      previous.content.screenshots.flatMap((set) => set.files.map((file) => file.sha256)),
    );
    assert.equal(mapped.some((file) => previousHashes.has(file.sha256)), false);
  });

  // EDW-32 ("submit eddies wallet for app review"): the 0.1.22 dispatch pairs
  // the approved 0.1.22 manifest with the committed config, so the adapter must
  // accept that pair and hand the engine the bound redesign set.
  await test("create-version accepts the 0.1.22 manifest with the committed config", async () => {
    const manifest = approved.readManifest("0.1.22");
    const config = approved.committedConfig();
    const env = baseEnv();
    env.EDDIES_APP_REVIEW_VERSION = "0.1.22";
    env.EDDIES_APP_REVIEW_CONFIRM = "0.1.22";
    env.APP_REVIEW_CONFIG = approved.CONFIG_PATH;
    const calls = [];
    try {
      await adapter.runCreateVersion({
        argv: ["--create-version"],
        env,
        loadEngineModules: () => ({ formatSuccess: () => "" }),
        runSubmission: async (args, credentials, dependencies) => {
          calls.push({ args, dependencies });
          return {
            result: { status: "version_created", submitted: false, remaining: "assemble" },
          };
        },
      });
    } finally {
      fs.rmSync(env.RUNNER_TEMP, { recursive: true, force: true });
    }
    assert.equal(calls.length, 1);
    const { args, dependencies } = calls[0];
    assert.equal(args.createVersion, true);
    assert.equal(args.firstRelease, false);
    assert.equal(args.version, manifest.candidate.version);
    assert.equal(args.build, manifest.candidate.build);
    assert.equal(args.baselineVersion, manifest.candidate.baselineVersion);
    assert.equal(args.expectedReleaseType, manifest.candidate.releaseType);
    assert.equal(dependencies.source.metadata.whatsNew, manifest.content.listing.whatsNew);
    const directory = path.join(ROOT, ...config.listing.screenshotDirectory);
    const mapped = dependencies.source.screenshots.flatMap((set) => set.files);
    const bound = manifest.content.screenshots.flatMap((set) => set.files);
    assert.deepEqual(
      mapped.map((file) => [file.filePath, file.sha256]),
      bound.map((file) => [path.join(directory, file.fileName), file.sha256]),
    );
  });

  // EDW-34: the store description still says the child "cannot change" the
  // wallet after 0.1.22 gave the child Pay back. The next update's approved
  // manifest declares the new description, and create-version must hand the
  // engine a listing write for that run so the copy reaches the new version.
  await test("create-version writes the description a next update manifest declares", async () => {
    const description = approvedDescription();
    assert.notEqual(description, approved.readManifest("0.1.22").content.listing.description);
    const root = nextUpdateCheckout((manifest) => {
      manifest.listing = { ...manifest.listing, copyWrites: ["description"] };
      manifest.content.listing.description = description;
    });
    let outcome;
    try {
      outcome = await createNextUpdate(root);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
    const committed = approved.committedConfig();
    assert.equal(outcome.calls.length, 1);
    const { engineConfig, dependencies } = outcome.calls[0];
    assert.deepEqual(engineConfig.listing.alignmentWrites, [...committed.listing.alignmentWrites, "listing"]);
    assert.equal(engineConfig.listingPolicy, "observe");
    assert.equal(dependencies.source.metadata.description, description);
    assert.deepEqual(outcome.created.copyWrites, ["description"]);
  });

  await test("create-version keeps listing copy observe-only when the manifest declares no copy writes", async () => {
    const root = nextUpdateCheckout(() => {});
    let outcome;
    try {
      outcome = await createNextUpdate(root);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
    const committed = approved.committedConfig();
    assert.deepEqual(outcome.calls[0].engineConfig.listing.alignmentWrites, committed.listing.alignmentWrites);
    assert.deepEqual(outcome.created.copyWrites, []);
  });

  await test("create-version refuses listing copy changes the manifest does not declare exactly", async () => {
    const cases = [
      [
        (manifest) => {
          manifest.listing = { ...manifest.listing, copyWrites: ["description"] };
          manifest.content.listing.description = approvedDescription();
          manifest.content.listing.keywords = `${manifest.content.listing.keywords},chores`;
        },
        /listing keywords differs from the 0\.1\.22 manifest, but listing\.copyWrites does not name it/,
      ],
      [
        (manifest) => {
          manifest.listing = { ...manifest.listing, copyWrites: ["description"] };
        },
        /listing\.copyWrites names description, but it equals the 0\.1\.22 manifest/,
      ],
    ];
    for (const [change, refusal] of cases) {
      const root = nextUpdateCheckout(change);
      try {
        await assert.rejects(
          () => createNextUpdate(root).then(({ calls }) => {
            if (calls.length > 0) throw new Error("must not reach the engine");
          }),
          refusal,
        );
      } finally {
        fs.rmSync(root, { recursive: true, force: true });
      }
    }
  });

  await test("create-version refuses a config that turns listing copy writes on for every manifest", async () => {
    const config = approved.committedConfig();
    config.listing.alignmentWrites = [...config.listing.alignmentWrites, "listing"];
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "eddies-listing-config-"));
    const configPath = path.join(directory, "app-review.config.json");
    fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
    const root = nextUpdateCheckout(() => {});
    try {
      await assert.rejects(
        () => createNextUpdate(root, configPath),
        /config\.listing\.alignmentWrites must not include listing/,
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
      fs.rmSync(directory, { recursive: true, force: true });
    }
  });

  process.stdout.write("all create-version adapter tests passed\n");
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack || error}\n`);
  process.exitCode = 1;
});
