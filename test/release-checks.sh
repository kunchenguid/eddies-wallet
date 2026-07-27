#!/usr/bin/env bash
# Release pipeline regression checks.
#
# Credential-free by construction: these checks read repository files and run
# the version-derivation script with fixture inputs. They never touch Apple
# credentials, App Store Connect, or the network, and they run identically on
# a developer Mac and on CI (macOS or Linux; plutil checks are skipped where
# plutil does not exist).
set -u

cd "$(dirname "$0")/.."

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

WORKFLOWS=(.github/workflows/ci.yml .github/workflows/release.yml .github/workflows/release-please.yml .github/workflows/asc-build-status.yml)

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
require_grep 'MARKETING_VERSION="\$APP_STORE_VERSION"' .github/workflows/release.yml "release.yml sets MARKETING_VERSION from the tag"
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

require_grep 'MARKETING_VERSION = ' EddysWallet.xcodeproj/project.pbxproj "project.pbxproj pins a deterministic MARKETING_VERSION"
require_grep 'INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO' EddysWallet.xcodeproj/project.pbxproj "project.pbxproj declares exempt-encryption metadata for TestFlight"

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

# --- Result ----------------------------------------------------------------

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "release-checks: $FAILURES check(s) failed" >&2
  exit 1
fi
echo "release-checks: all checks passed"
