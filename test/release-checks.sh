#!/usr/bin/env bash
# Release pipeline regression checks.
#
# Credential-free by construction: these checks read repository files and run
# the version-derivation script with fixture inputs. They never touch Apple
# credentials, App Store Connect, or the network, and they run identically on
# a developer Mac and on CI (macOS or Linux; plutil checks are skipped where
# plutil does not exist).
set -u

cd "$(dirname "$0")/.." || exit

FAILURES=0

fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "ok: $1"
}

require_grep() {
  local pattern="$1" file="$2" message="$3"
  if grep -qE -- "$pattern" "$file"; then
    pass "$message"
  else
    fail "$message ($file does not match: $pattern)"
  fi
}

forbid_grep() {
  local pattern="$1" file="$2" message="$3"
  if grep -qE -- "$pattern" "$file"; then
    fail "$message ($file matches forbidden pattern: $pattern)"
  else
    pass "$message"
  fi
}

WORKFLOWS=(.github/workflows/ci.yml .github/workflows/release.yml .github/workflows/release-please.yml .github/workflows/asc-build-status.yml .github/workflows/app-store-review-status.yml)

# --- Workflow syntax -------------------------------------------------------

for workflow in "${WORKFLOWS[@]}"; do
  if [ ! -f "$workflow" ]; then
    fail "workflow exists: $workflow"
    continue
  fi
  if ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$workflow" >/dev/null 2>&1; then
    pass "workflow parses as YAML: $workflow"
  else
    fail "workflow parses as YAML: $workflow"
  fi
done

# --- Immutable action pins -------------------------------------------------

for workflow in "${WORKFLOWS[@]}"; do
  [ -f "$workflow" ] || continue
  unpinned="$(grep -nE '^[[:space:]]*(- )?uses:' "$workflow" | grep -vE 'uses:[[:space:]]*[^[:space:]]+@[0-9a-f]{40}( |$)' || true)"
  if [ -n "$unpinned" ]; then
    fail "every action is pinned to a full commit SHA in $workflow: $unpinned"
  else
    pass "every action is pinned to a full commit SHA in $workflow"
  fi
done

# --- Event and permission safety ------------------------------------------

for workflow in "${WORKFLOWS[@]}"; do
  [ -f "$workflow" ] || continue
  forbid_grep 'pull_request_target' "$workflow" "no pull_request_target trigger in $workflow"
done

# Ordinary pull request validation must be credential-free.
forbid_grep 'secrets\.' .github/workflows/ci.yml "ci.yml references no secrets at all"
require_grep '^  pull_request:$' .github/workflows/ci.yml "ci.yml validates pull requests"
require_grep '^  contents: read$' .github/workflows/ci.yml "ci.yml permissions are contents: read"
forbid_grep '^[[:space:]]*(contents|actions|pull-requests|id-token|packages): write' .github/workflows/ci.yml "ci.yml grants no write permission"

# The secret-bearing release workflow must be reachable only from a trusted
# eddies-wallet-v* tag, a published release, or an explicit tag dispatch.
forbid_grep '^  pull_request:' .github/workflows/release.yml "release.yml has no pull_request trigger"
forbid_grep 'branches:' .github/workflows/release.yml "release.yml never triggers on branches"
require_grep "^      - 'eddies-wallet-v\*'$" .github/workflows/release.yml "release.yml tag trigger is eddies-wallet-v*"
require_grep '^  contents: read$' .github/workflows/release.yml "release.yml permissions are contents: read"
forbid_grep '^[[:space:]]*(contents|actions|pull-requests|id-token|packages): write' .github/workflows/release.yml "release.yml grants no write permission"

# Release revision binding: the checkout must resolve exactly the release tag.
require_grep 'ref: \$\{\{ inputs\.tag_name \|\| github\.event\.release\.tag_name \|\| github\.ref_name \}\}' .github/workflows/release.yml "release.yml checks out exactly the release tag"

# Per-tag concurrency dedupes reruns of the same tag without linking tags.
require_grep 'group: testflight-\$\{\{ inputs\.tag_name \|\| github\.event\.release\.tag_name \|\| github\.ref_name \}\}' .github/workflows/release.yml "release.yml concurrency group is per release tag"
require_grep 'cancel-in-progress: true' .github/workflows/release.yml "release.yml cancels superseded duplicate runs"

# Version and build identity come from the shared derivation script.
require_grep 'resolve_release_version\.sh' .github/workflows/release.yml "release.yml derives versions via resolve_release_version.sh"
# shellcheck disable=SC2016 # These are literal regexes for workflow shell source.
require_grep 'MARKETING_VERSION="\$APP_STORE_VERSION"' .github/workflows/release.yml "release.yml sets MARKETING_VERSION from the tag"
# shellcheck disable=SC2016 # These are literal regexes for workflow shell source.
require_grep 'CURRENT_PROJECT_VERSION="\$BUILD_NUMBER"' .github/workflows/release.yml "release.yml sets CURRENT_PROJECT_VERSION from run identity"

# TestFlight-only upload behavior: altool --upload-app and nothing that could
# submit for review, publish, or change App Store availability.
require_grep 'altool --upload-app' .github/workflows/release.yml "release.yml uploads with altool --upload-app"
for forbidden in 'appStoreVersionSubmissions' 'reviewSubmissions' '--upload-package' 'fastlane' 'deliver'; do
  forbid_grep "$forbidden" .github/workflows/release.yml "release.yml contains no review-submission or alternate-uploader path ($forbidden)"
done

# The Apple team ID stays out of Git and is injected from a repository variable.
require_grep 'vars\.APPLE_TEAM_ID' .github/workflows/release.yml "release.yml takes the team ID from the APPLE_TEAM_ID variable"
require_grep 'plutil -insert teamID' .github/workflows/release.yml "release.yml injects teamID into a runner-temp ExportOptions copy"
forbid_grep 'teamID' ExportOptions.plist "ExportOptions.plist commits no teamID"
forbid_grep 'DEVELOPMENT_TEAM = ' EddysWallet.xcodeproj/project.pbxproj "project.pbxproj commits no team ID"

# Release Please runs only on default-branch pushes with the manifest config.
require_grep '^      - main$' .github/workflows/release-please.yml "release-please.yml runs on main pushes"
require_grep 'config-file: release-please-config.json' .github/workflows/release-please.yml "release-please.yml uses the committed config"
require_grep 'manifest-file: .release-please-manifest.json' .github/workflows/release-please.yml "release-please.yml uses the committed manifest"
if grep -oE 'secrets\.[A-Za-z_]+' .github/workflows/release-please.yml | grep -qv 'secrets.GITHUB_TOKEN'; then
  fail "release-please.yml uses only the ephemeral GITHUB_TOKEN"
else
  pass "release-please.yml uses only the ephemeral GITHUB_TOKEN"
fi

# The ASC status check is dispatch-only and read-only.
status_triggers="$(grep -cE '^  (workflow_dispatch|push|pull_request|release|schedule):' .github/workflows/asc-build-status.yml)"
if [ "$status_triggers" = "1" ] && grep -qE '^  workflow_dispatch:$' .github/workflows/asc-build-status.yml; then
  pass "asc-build-status.yml is workflow_dispatch-only"
else
  fail "asc-build-status.yml is workflow_dispatch-only"
fi
require_grep '^  contents: read$' .github/workflows/asc-build-status.yml "asc-build-status.yml permissions are contents: read"

# The review monitor is deliberately separate from release/upload paths. It
# runs only from trusted schedules or trusted manual dispatches, observes one
# configured exact cycle, and may write only the bounded GitHub issue used for
# notification deduplication.
REVIEW_WORKFLOW=.github/workflows/app-store-review-status.yml
REVIEW_SCRIPT=.github/scripts/app_store_review_monitor.py
require_grep '^  schedule:$' "$REVIEW_WORKFLOW" "review monitor has a schedule trigger"
require_grep '^  workflow_dispatch:$' "$REVIEW_WORKFLOW" "review monitor has a manual trigger"
for forbidden in 'pull_request' 'pull_request_target' 'workflow_run' 'repository_dispatch' '^  push:'; do
  forbid_grep "$forbidden" "$REVIEW_WORKFLOW" "review monitor excludes untrusted trigger ($forbidden)"
done
require_grep '^  contents: read$' "$REVIEW_WORKFLOW" "review monitor needs contents read only"
require_grep '^  issues: write$' "$REVIEW_WORKFLOW" "review monitor grants only issue write for dedup notifications"
require_grep '^concurrency:$' "$REVIEW_WORKFLOW" "review monitor serializes transition deduplication"
require_grep '^  group: app-store-review-status$' "$REVIEW_WORKFLOW" "review monitor uses one concurrency group"
require_grep '^  cancel-in-progress: false$' "$REVIEW_WORKFLOW" "review monitor does not cancel active polling"
forbid_grep '^[[:space:]]*(actions|pull-requests|checks|id-token|packages): write' "$REVIEW_WORKFLOW" "review monitor has no extra write permissions"
require_grep 'ASC_REVIEW_MONITOR_KEY_ID' "$REVIEW_WORKFLOW" "review monitor uses its dedicated key ID secret"
require_grep 'ASC_REVIEW_MONITOR_PRIVATE_KEY' "$REVIEW_WORKFLOW" "review monitor uses its dedicated private-key secret"
forbid_grep 'ASC_REVIEW_MONITOR_ISSUER_ID' "$REVIEW_WORKFLOW" "review monitor individual key has no issuer secret"
forbid_grep 'APP_STORE_CONNECT_API_KEY' "$REVIEW_WORKFLOW" "review monitor never reuses upload credentials"
require_grep 'ASC_REVIEW_MONITOR_VERSION' "$REVIEW_WORKFLOW" "review monitor requires scheduled exact version configuration"
require_grep 'ASC_REVIEW_MONITOR_BUILD' "$REVIEW_WORKFLOW" "review monitor requires scheduled exact build configuration"
require_grep 'actions/checkout@[0-9a-f]{40}' "$REVIEW_WORKFLOW" "review monitor pins checkout immutably"
# Arming is resolved before any credential is in scope, so an unarmed schedule
# never reaches Apple and never leaves this workflow permanently red.
REVIEW_CYCLE_RESOLVER=.github/scripts/review_monitor_cycle.sh
require_grep 'review_monitor_cycle\.sh' "$REVIEW_WORKFLOW" "review monitor resolves its cycle before polling"
require_grep "if: steps\.cycle\.outputs\.armed == 'true'" "$REVIEW_WORKFLOW" "review monitor polls Apple only for an armed cycle"
forbid_grep 'ASC_REVIEW_MONITOR_PRIVATE_KEY' "$REVIEW_CYCLE_RESOLVER" "cycle resolver handles no credential"
if [ -x "$REVIEW_CYCLE_RESOLVER" ]; then
  pass "cycle resolver is executable"
else
  fail "cycle resolver is executable"
fi
require_grep 'method="GET"' "$REVIEW_SCRIPT" "review monitor makes App Store Connect GET requests"
forbidden_apple_mutation='appStoreVersionSubmissions|reviewSubmissions|--request POST|--request PATCH|--request DELETE|urlopen\(.*method="POST"'
forbid_grep "$forbidden_apple_mutation" "$REVIEW_SCRIPT" "review monitor contains no Apple mutation path"
if python3 test/app-store-review-monitor-test.py >/dev/null; then
  pass "review monitor deterministic fixtures and negative controls"
else
  fail "review monitor deterministic fixtures and negative controls"
fi

# --- Export options --------------------------------------------------------

if command -v plutil >/dev/null 2>&1; then
  if plutil -lint ExportOptions.plist >/dev/null; then
    pass "ExportOptions.plist lints as a property list"
  else
    fail "ExportOptions.plist lints as a property list"
  fi
else
  echo "skip: plutil unavailable; ExportOptions.plist lint runs on macOS"
fi
require_grep '<string>app-store-connect</string>' ExportOptions.plist "ExportOptions.plist method is app-store-connect"
require_grep '<key>manageAppVersionAndBuildNumber</key>' ExportOptions.plist "ExportOptions.plist declares manageAppVersionAndBuildNumber"
if ruby -e 'content = File.read("ExportOptions.plist"); exit 1 unless content.include?("<key>manageAppVersionAndBuildNumber</key>\n\t<false/>")'; then
  pass "ExportOptions.plist keeps explicit version management (manageAppVersionAndBuildNumber false)"
else
  fail "ExportOptions.plist keeps explicit version management (manageAppVersionAndBuildNumber false)"
fi

# --- Version lineage -------------------------------------------------------

manifest_version="$(ruby -rjson -e 'puts JSON.parse(File.read(".release-please-manifest.json")).fetch(".")')"
file_version="$(cat version.txt)"
if [ "$manifest_version" = "$file_version" ]; then
  pass "version.txt matches .release-please-manifest.json ($file_version)"
else
  fail "version.txt ($file_version) matches .release-please-manifest.json ($manifest_version)"
fi

component="$(ruby -rjson -e 'puts JSON.parse(File.read("release-please-config.json")).dig("packages", ".", "component")')"
if [ "$component" = "eddies-wallet" ]; then
  pass "release-please component matches the eddies-wallet-v* tag trigger"
else
  fail "release-please component ($component) matches the eddies-wallet-v* tag trigger"
fi

# Release-please lineage (release-please 17.x / action v4.4.1):
# Pre-first-release: manifest/version seed stays 0.0.0. A 0.0.0 seed with no
# matching tag does NOT synthesize a latestRelease (manifest.js skips 0.0.0),
# so buildNewVersion falls through to initialReleaseVersion() - config
# initial-version or the hard-coded default 1.0.0. The approved unfinished-MVP
# lineage requires initial-version 0.1.0 so the first proposal is
# eddies-wallet-v0.1.0 (marketing 0.1), not 1.0.0.
# Post-first-release: release-please advances the seed to the cut version. The
# advanced seed must match the latest available released lineage (committed
# CHANGELOG headings plus any local eddies-wallet-v* tags present) - never a
# hard-coded perpetual 0.0.0 assertion.
# Counterfactuals live under test/fixtures/release-lineage/.
LINEAGE_VALIDATOR=test/fixtures/release-lineage/validate.rb
if [ ! -f "$LINEAGE_VALIDATOR" ]; then
  fail "release lineage validator exists: $LINEAGE_VALIDATOR"
else
  if lineage_out="$(ruby "$LINEAGE_VALIDATOR" --self-test 2>&1)"; then
    pass "release lineage pure counterfactuals (pre-first, post-first, mismatched, unjustified)"
  else
    fail "release lineage pure counterfactuals: $lineage_out"
  fi

  for fixture in test/fixtures/release-lineage/pre-first-release \
    test/fixtures/release-lineage/post-first-release \
    test/fixtures/release-lineage/mismatched-seed; do
    fixture_name="$(basename "$fixture")"
    if fixture_out="$(ruby "$LINEAGE_VALIDATOR" --fixture "$fixture" 2>&1)"; then
      pass "release lineage fixture $fixture_name"
    else
      fail "release lineage fixture $fixture_name: $fixture_out"
    fi
  done

  if live_out="$(ruby "$LINEAGE_VALIDATOR" --live . 2>&1)"; then
    pass "live release-please lineage matches committed state ($live_out)"
  else
    fail "live release-please lineage matches committed state: $live_out"
  fi
fi

require_grep 'MARKETING_VERSION = 0\.1' EddysWallet.xcodeproj/project.pbxproj "project.pbxproj placeholder MARKETING_VERSION matches the 0.1 first-release marketing version"
require_grep 'INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO' EddysWallet.xcodeproj/project.pbxproj "project.pbxproj declares exempt-encryption metadata for TestFlight"

# The StoreKit test configuration is a Debug/Test scheme input only. It must
# never be copied into the shipping app bundle's Resources.
forbid_grep 'EddysWallet\.storekit in Resources' EddysWallet.xcodeproj/project.pbxproj "project.pbxproj keeps the StoreKit test configuration out of the app bundle"
require_grep 'EddysWallet\.storekit' EddysWallet.xcodeproj/xcshareddata/xcschemes/EddysWallet.xcscheme "shared scheme still selects the checked-in StoreKit configuration"
require_grep 'StoreKitConfigurationFileReference' EddysWallet.xcodeproj/xcshareddata/xcschemes/EddysWallet.xcscheme "shared scheme keeps a StoreKit configuration reference for Debug and Test"

# --- Version/build derivation and retry identity ---------------------------

derive() {
  GITHUB_RUN_NUMBER="$1" GITHUB_RUN_ATTEMPT="$2" ./.github/scripts/resolve_release_version.sh "$3" 2>/dev/null
}

expect_derivation() {
  local run="$1" attempt="$2" tag="$3" expected="$4" label="$5"
  local actual
  actual="$(derive "$run" "$attempt" "$tag")"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (expected: [$expected] actual: [$actual])"
  fi
}

expect_derivation 12 1 eddies-wallet-v0.1.0 'tag_name=eddies-wallet-v0.1.0
release_version=0.1.0
app_store_version=0.1
build_number=12.1' "tag eddies-wallet-v0.1.0 derives marketing version 0.1 and build 12.1"

expect_derivation 12 1 eddies-wallet-v1.2.3 'tag_name=eddies-wallet-v1.2.3
release_version=1.2.3
app_store_version=1.2.3
build_number=12.1' "tag eddies-wallet-v1.2.3 keeps a nonzero patch"

expect_derivation 12 1 eddies-wallet-v1.2.0 'tag_name=eddies-wallet-v1.2.0
release_version=1.2.0
app_store_version=1.2
build_number=12.1' "tag eddies-wallet-v1.2.0 trims the zero patch"

# Retry identity: a rerun of the same tag keeps the same source and marketing
# version and gets a new unique build number, so an already-accepted build in
# App Store Connect is never collided with and never silently rebuilt from
# different source.
expect_derivation 12 2 eddies-wallet-v0.1.0 'tag_name=eddies-wallet-v0.1.0
release_version=0.1.0
app_store_version=0.1
build_number=12.2' "rerunning tag eddies-wallet-v0.1.0 keeps its versions and bumps only the attempt suffix"

first="$(derive 7 3 eddies-wallet-v2.0.0)"
second="$(derive 7 3 eddies-wallet-v2.0.0)"
if [ -n "$first" ] && [ "$first" = "$second" ]; then
  pass "derivation is deterministic for identical inputs"
else
  fail "derivation is deterministic for identical inputs"
fi

for bad_tag in main eddies-wallet-v1.2 v1.2.3.4 'eddies-wallet-v1.2.3-rc1'; do
  if derive 12 1 "$bad_tag" >/dev/null; then
    fail "derivation rejects non-release ref: $bad_tag"
  else
    pass "derivation rejects non-release ref: $bad_tag"
  fi
done

# --- Cloud subscription product contract -----------------------------------

# The App Store Connect products were configured against these exact values
# (docs/app-store-configuration.md). The bundled StoreKit configuration must not
# drift from them; EddysWalletTests/CloudStoreConfigurationTests.swift asserts
# the same contract from inside the app bundle.
STOREKIT=EddysWallet/Configuration/EddysWallet.storekit
CLOUD_MODELS=EddysWallet/Models/CloudModels.swift
APP_STORE_DOC=docs/app-store-configuration.md

for product in com.kunchenguid.eddieswallet.cloud.monthly com.kunchenguid.eddieswallet.cloud.annual; do
  require_grep "\"productID\" : \"$product\"" "$STOREKIT" "StoreKit configuration declares $product"
  require_grep "\"$product\"" "$CLOUD_MODELS" "runtime product identifiers declare $product"
  require_grep "\`$product\`" "$APP_STORE_DOC" "App Store configuration record documents $product"
done

require_grep '"displayPrice" : "2.99"' "$STOREKIT" "monthly Cloud price stays 2.99"
require_grep '"displayPrice" : "24.99"' "$STOREKIT" "annual Cloud price stays 24.99"
require_grep '"recurringSubscriptionPeriod" : "P1M"' "$STOREKIT" "monthly Cloud period stays one month"
require_grep '"recurringSubscriptionPeriod" : "P1Y"' "$STOREKIT" "annual Cloud period stays one year"

# Exactly two Cloud subscriptions, both without Family Sharing, and no offers of
# any kind - App Store Connect has none, so the local configuration must not
# invent one.
storekit_count() { grep -c -- "$1" "$STOREKIT"; }
if [ "$(storekit_count '"productID" :')" -eq 2 ]; then
  pass "StoreKit configuration declares exactly two products"
else
  fail "StoreKit configuration declares exactly two products (found $(storekit_count '"productID" :'))"
fi
if [ "$(storekit_count '"familyShareable" : false')" -eq 2 ]; then
  pass "both Cloud subscriptions keep Family Sharing off"
else
  fail "both Cloud subscriptions keep Family Sharing off"
fi
forbid_grep '"introductoryOffer"' "$STOREKIT" "no Cloud introductory offer or free trial is configured"
forbid_grep '"promotionalOffers" : \[[^]]' "$STOREKIT" "no Cloud promotional offer is configured"
forbid_grep '"offerCodes" : \[[^]]' "$STOREKIT" "no Cloud offer code is configured"

# --- Truthful shared-account and Cloud documentation -----------------------

# The shared Apple account already carries the Paid Applications agreement and
# tax/banking. Re-asserting that they are outstanding regenerates a duplicate
# captain request, so the stale claim must stay out of the release docs.
forbid_grep 'does not claim those prerequisites are complete' docs/release.md \
  "release docs no longer claim the Paid Applications agreement and tax/banking are unproven"
require_grep 'Paid Applications agreement, tax, and banking\*\* are already in place' docs/release.md \
  "release docs record that account-level distribution prerequisites are satisfied"
require_grep 'In-App Purchase\*\* key' docs/release.md \
  "release docs distinguish the backend In-App Purchase key class from the upload key"
# Custody is settled: the In-App Purchase key already exists in the captain's
# secret manager. Re-asserting that it is outstanding, or asking for a new key or
# a key conversion, regenerates a duplicate captain request.
require_grep 'already exists and is held in the captain' docs/release.md \
  "release docs record that the In-App Purchase key already exists in captain custody"
forbid_grep 'credential still outstanding' docs/release.md \
  "release docs no longer describe the In-App Purchase key as an outstanding credential"
require_grep 'Apple scopes certificates to the \*\*team\*\*' docs/release.md \
  "release docs warn that certificate cleanup revokes team-wide, not per app"
require_grep 'prune_asc_development_certs\.js' docs/release.md \
  "release docs name this repository's own certificate-cleanup script as a cause"
require_grep 'automatic signing regenerate a development certificate' docs/release.md \
  "release docs give the safe local signing recovery"

# The configuration record must stay honest about what has not happened.
require_grep 'READY_TO_SUBMIT' "$APP_STORE_DOC" "App Store configuration record states the product state"
require_grep 'SIXTEEN_DAYS' "$APP_STORE_DOC" "App Store configuration record states the billing grace period"
require_grep '/v1/app-store/notifications' "$APP_STORE_DOC" "App Store configuration record states the notification route"
require_grep 'What is deliberately not done' "$APP_STORE_DOC" \
  "App Store configuration record keeps its unproven-state disclaimer"
forbid_grep 'submitted for App Review|purchase succeeded|Sandbox purchase verified' "$APP_STORE_DOC" \
  "App Store configuration record claims no purchase, Sandbox, or App Review success"

# --- Result ----------------------------------------------------------------

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "release-checks: $FAILURES check(s) failed" >&2
  exit 1
fi
echo "release-checks: all checks passed"
