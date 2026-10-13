"use strict";

// The 0.1.17, 0.1.19 and 0.1.21 manifests were approved while the config
// bound the 0.1.17 screenshot directory and the pre-redesign App Review notes.
// The committed config now binds the Parent-redesign set and notes, and the
// mutation lanes restore the config from the dispatch commit, so the adapter
// refuses those manifests against it. These helpers rebuild the config each
// manifest was approved with, so adapter tests still exercise that pairing.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const CONFIG_PATH = path.join(ROOT, "tools", "app-review", "app-review.config.json");
const HISTORICAL_SCREENSHOT_DIRECTORY = Object.freeze(["tools", "app-review", "assets", "screenshots", "0.1.17"]);
const HISTORICAL_VERSIONS = new Set(["0.1.17", "0.1.19", "0.1.21"]);

function readManifest(version) {
  return JSON.parse(fs.readFileSync(
    path.join(ROOT, "tools", "app-review", "manifests", `${version}.json`),
    "utf8",
  ));
}

function committedConfig() {
  return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
}

function configAsApproved(version) {
  if (!HISTORICAL_VERSIONS.has(version)) {
    throw new Error(`no historical config is modeled for ${version}`);
  }
  const config = committedConfig();
  config.listing.screenshotDirectory = [...HISTORICAL_SCREENSHOT_DIRECTORY];
  config.reviewDetails.notes = readManifest(version).content.appReview.notes;
  return config;
}

function writeConfigAsApproved(version) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "eddies-approved-config-"));
  const file = path.join(directory, "app-review.config.json");
  fs.writeFileSync(file, `${JSON.stringify(configAsApproved(version), null, 2)}\n`);
  return file;
}

module.exports = {
  CONFIG_PATH,
  HISTORICAL_SCREENSHOT_DIRECTORY,
  committedConfig,
  configAsApproved,
  readManifest,
  writeConfigAsApproved,
};
