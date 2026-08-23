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

WORKFLOWS=(.github/workflows/ci.yml .github/workflows/release.yml .github/workflows/release-please.yml .github/workflows/asc-build-status.yml .github/workflows/app-review-monitor.yml .github/workflows/app-review-monitor-e2e.yml .github/workflows/app-review-list-versions.yml .github/workflows/app-review-list-app-info.yml .github/workflows/app-review-prepare.yml .github/workflows/app-review-submit.yml .github/workflows/app-review-demo-preflight.yml .github/workflows/app-review-eula-append.yml)

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

# --- release PR must create no CI run --------------------------------------
# release-please opens its PR with GITHUB_TOKEN, which can only produce
# action_required pull_request runs. Every path it writes must stay inside
# ci.yml's pull_request.paths-ignore so no run is created.
#
# Expected outputs are derived from release-please-config.json (release-type,
# changelog-path, version-file, extra-files) plus the manifest path from
# release-please.yml, so the ignore contract cannot silently drift when the
# strategy or extra-files change.
# shellcheck disable=SC2016 # Ruby program intentionally uses single-quoted strings.
if ci_event_shape_out="$(ruby -ryaml -e '
  wf = YAML.load_file(".github/workflows/ci.yml")
  # YAML parses a bare `on:` key as boolean true; accept either form.
  on = wf[true] || wf["on"]
  abort "ci.yml missing on: mapping" unless on.is_a?(Hash)
  expected_keys = %w[pull_request push release workflow_dispatch]
  actual_keys = on.keys.map(&:to_s)
  unless actual_keys == expected_keys
    abort "ci.yml on: keys drifted: expected #{expected_keys.inspect}, got #{actual_keys.inspect}"
  end
  push = on["push"]
  unless push.is_a?(Hash) && push["tags"] == ["eddies-wallet-v*"] && push.keys.map(&:to_s) == ["tags"]
    abort "ci.yml push trigger must remain tags-only eddies-wallet-v* (got #{push.inspect})"
  end
  release = on["release"]
  unless release.is_a?(Hash) && release["types"] == ["published"]
    abort "ci.yml release trigger must remain types: [published] (got #{release.inspect})"
  end
  unless on["workflow_dispatch"].is_a?(Hash)
    abort "ci.yml workflow_dispatch must remain a mapping"
  end
  pr = on["pull_request"]
  unless pr.is_a?(Hash)
    abort "ci.yml pull_request must be a mapping with paths-ignore"
  end
  if pr.key?("paths")
    abort "ci.yml pull_request must not combine paths with paths-ignore"
  end
  ignore = pr["paths-ignore"]
  unless ignore.is_a?(Array) && !ignore.empty?
    abort "ci.yml pull_request.paths-ignore must be a non-empty array"
  end
  puts "keys=#{actual_keys.join(",")} ignore=#{ignore.join(",")}"
')"; then
  pass "ci.yml pull_request event shape preserves non-PR triggers ($ci_event_shape_out)"
else
  fail "ci.yml pull_request event shape preserves non-PR triggers: $ci_event_shape_out"
fi

if release_ci_ignore_out="$(ruby -ryaml -rjson -e '
  config = JSON.parse(File.read("release-please-config.json"))
  pkg = config.fetch("packages").fetch(".")
  release_type = pkg["release-type"] || config["release-type"] || "node"
  changelog = pkg["changelog-path"] || config["changelog-path"] || "CHANGELOG.md"

  expected = [changelog]
  case release_type
  when "simple"
    expected << (pkg["version-file"] || config["version-file"] || "version.txt")
  when "node"
    expected << "package.json"
    expected << "package-lock.json" if File.exist?("package-lock.json")
  when "go"
    # changelog only by default
  else
    abort "unsupported release-please release-type for ignore derivation: #{release_type}"
  end

  extra = pkg["extra-files"] || config["extra-files"] || []
  extra.each do |entry|
    path = entry.is_a?(Hash) ? entry["path"] : entry
    expected << path if path && !path.to_s.empty?
  end

  # Manifest path is authoritative from the release-please workflow input.
  manifest = ".release-please-manifest.json"
  File.read(".github/workflows/release-please.yml").scan(/manifest-file:\s*(\S+)/) do |m|
    manifest = m[0]
  end
  expected << manifest
  expected = expected.map(&:to_s).uniq

  wf = YAML.load_file(".github/workflows/ci.yml")
  on = wf[true] || wf["on"] || {}
  pr = on["pull_request"] || {}
  ignore = Array(pr["paths-ignore"]).map(&:to_s)
  missing = expected.reject { |path| ignore.include?(path) }
  if missing.empty?
    puts "ignore covers #{expected.join(",")}"
    exit 0
  end
  abort "ci.yml pull_request.paths-ignore missing release-please outputs: #{missing.join(", ")} (expected #{expected.join(", ")}; have #{ignore.join(", ")})"
')"; then
  pass "ci.yml pull_request ignores every config-derived release-please output ($release_ci_ignore_out)"
else
  fail "ci.yml pull_request ignores every config-derived release-please output: $release_ci_ignore_out"
fi

require_grep '"release-type": "simple"' release-please-config.json \
  "release-please still uses the simple strategy (output set: CHANGELOG.md, version.txt, manifest)"

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
# armed marketing version through the pinned shared GET-only tool, and may write
# only the bounded GitHub issue used for the exact-cycle wake signal.
REVIEW_WORKFLOW=.github/workflows/app-review-monitor.yml
require_grep '^  schedule:$' "$REVIEW_WORKFLOW" "review monitor has a schedule trigger"
require_grep '^  workflow_dispatch:$' "$REVIEW_WORKFLOW" "review monitor has a manual trigger"
for forbidden in 'pull_request' 'pull_request_target' 'workflow_run' 'repository_dispatch' '^  push:'; do
  forbid_grep "$forbidden" "$REVIEW_WORKFLOW" "review monitor excludes untrusted trigger ($forbidden)"
done
require_grep '^  contents: read$' "$REVIEW_WORKFLOW" "review monitor needs contents read only"
require_grep '^  issues: write$' "$REVIEW_WORKFLOW" "review monitor grants only issue write for exact-cycle notifications"
require_grep '^concurrency:$' "$REVIEW_WORKFLOW" "review monitor serializes transition deduplication"
require_grep '^  group: eddies-app-review-monitor$' "$REVIEW_WORKFLOW" "review monitor uses one concurrency group"
require_grep '^  cancel-in-progress: false$' "$REVIEW_WORKFLOW" "review monitor does not cancel active polling"
forbid_grep '^[[:space:]]*(actions|pull-requests|checks|id-token|packages): write' "$REVIEW_WORKFLOW" "review monitor has no extra write permissions"
require_grep 'APP_STORE_CONNECT_KEY_ID' "$REVIEW_WORKFLOW" "review monitor reuses the existing submit key ID"
require_grep 'APP_STORE_CONNECT_ISSUER_ID' "$REVIEW_WORKFLOW" "review monitor reuses the existing submit issuer"
require_grep 'APP_STORE_CONNECT_API_KEY' "$REVIEW_WORKFLOW" "review monitor reuses the existing submit API key"
forbid_grep 'ASC_REVIEW_MONITOR_' "$REVIEW_WORKFLOW" "review monitor never references a dedicated monitor credential"
forbid_grep 'app_review_pipeline\.js submit' "$REVIEW_WORKFLOW" "review monitor never invokes the shared submit command"
require_grep 'app_review_pipeline\.js monitor' "$REVIEW_WORKFLOW" "review monitor runs the shared GET-only monitor command"
require_grep 'kunchenguid/app-review-submit' "$REVIEW_WORKFLOW" "review monitor checks out the shared app-review-submit tool"
require_grep '216a65513dbde70d04d0efd021792743f094ed77' "$REVIEW_WORKFLOW" "review monitor pins the shared tool at the live-proven multi-submission SHA"
require_grep 'actions/checkout@[0-9a-f]{40}' "$REVIEW_WORKFLOW" "review monitor pins checkout immutably"

# The live GET-only proof classifies a candidate engine SHA against real ASC
# state without writing the exact-cycle GitHub issue or mutating Apple.
REVIEW_E2E_WORKFLOW=.github/workflows/app-review-monitor-e2e.yml
require_grep '^  workflow_dispatch:$' "$REVIEW_E2E_WORKFLOW" "review monitor E2E has a manual trigger"
for forbidden in 'pull_request' 'pull_request_target' 'workflow_run' 'repository_dispatch' '^  push:' '^  schedule:'; do
  forbid_grep "$forbidden" "$REVIEW_E2E_WORKFLOW" "review monitor E2E excludes untrusted trigger ($forbidden)"
done
require_grep '^  contents: read$' "$REVIEW_E2E_WORKFLOW" "review monitor E2E needs contents read only"
forbid_grep '^  issues: write$' "$REVIEW_E2E_WORKFLOW" "review monitor E2E never grants issue write"
require_grep '^concurrency:$' "$REVIEW_E2E_WORKFLOW" "review monitor E2E serializes live proofs"
require_grep '^  group: eddies-app-review-monitor-e2e$' "$REVIEW_E2E_WORKFLOW" "review monitor E2E uses its own concurrency group"
require_grep '^  cancel-in-progress: false$' "$REVIEW_E2E_WORKFLOW" "review monitor E2E does not cancel an in-flight proof"
forbid_grep '^[[:space:]]*(actions|pull-requests|checks|id-token|packages): write' "$REVIEW_E2E_WORKFLOW" "review monitor E2E has no extra write permissions"
require_grep 'APP_STORE_CONNECT_KEY_ID' "$REVIEW_E2E_WORKFLOW" "review monitor E2E reuses the existing submit key ID"
require_grep 'APP_STORE_CONNECT_ISSUER_ID' "$REVIEW_E2E_WORKFLOW" "review monitor E2E reuses the existing submit issuer"
require_grep 'APP_STORE_CONNECT_API_KEY' "$REVIEW_E2E_WORKFLOW" "review monitor E2E reuses the existing submit API key"
forbid_grep 'ASC_REVIEW_MONITOR_' "$REVIEW_E2E_WORKFLOW" "review monitor E2E never references a dedicated monitor credential"
forbid_grep 'app_review_pipeline\.js' "$REVIEW_E2E_WORKFLOW" "review monitor E2E never invokes the shared pipeline CLI"
require_grep 'observe_review_status\.js' "$REVIEW_E2E_WORKFLOW" "review monitor E2E runs the GET-only observe harness"
require_grep 'kunchenguid/app-review-submit' "$REVIEW_E2E_WORKFLOW" "review monitor E2E checks out the shared app-review-submit tool"
require_grep '216a65513dbde70d04d0efd021792743f094ed77' "$REVIEW_E2E_WORKFLOW" "review monitor E2E defaults to the fixed multi-submission engine SHA"
require_grep 'actions/checkout@[0-9a-f]{40}' "$REVIEW_E2E_WORKFLOW" "review monitor E2E pins checkout immutably"
forbid_grep 'GITHUB_TOKEN' "$REVIEW_E2E_WORKFLOW" "review monitor E2E never maps GITHUB_TOKEN"

# GET-only iOS App Store version listing. Encrypted submit-key credentials,
# one GET step, no issue write, no submit, no shared-engine mutation.
LIST_VERSIONS_WORKFLOW=.github/workflows/app-review-list-versions.yml
require_grep '^  workflow_dispatch:$' "$LIST_VERSIONS_WORKFLOW" "version listing has a manual trigger"
for forbidden in 'pull_request' 'pull_request_target' 'workflow_run' 'repository_dispatch' '^  push:' '^  schedule:'; do
  forbid_grep "$forbidden" "$LIST_VERSIONS_WORKFLOW" "version listing excludes untrusted trigger ($forbidden)"
done
require_grep '^  contents: read$' "$LIST_VERSIONS_WORKFLOW" "version listing needs contents read only"
forbid_grep '^  issues: write$' "$LIST_VERSIONS_WORKFLOW" "version listing never grants issue write"
require_grep '^concurrency:$' "$LIST_VERSIONS_WORKFLOW" "version listing serializes live reads"
require_grep '^  group: eddies-app-review-list-versions$' "$LIST_VERSIONS_WORKFLOW" "version listing uses its own concurrency group"
require_grep '^  cancel-in-progress: false$' "$LIST_VERSIONS_WORKFLOW" "version listing does not cancel an in-flight read"
forbid_grep '^[[:space:]]*(actions|pull-requests|checks|id-token|packages): write' "$LIST_VERSIONS_WORKFLOW" "version listing has no extra write permissions"
require_grep 'APP_STORE_CONNECT_KEY_ID' "$LIST_VERSIONS_WORKFLOW" "version listing reuses the existing submit key ID"
require_grep 'APP_STORE_CONNECT_ISSUER_ID' "$LIST_VERSIONS_WORKFLOW" "version listing reuses the existing submit issuer"
require_grep 'APP_STORE_CONNECT_API_KEY' "$LIST_VERSIONS_WORKFLOW" "version listing reuses the existing submit API key"
forbid_grep 'ASC_REVIEW_MONITOR_' "$LIST_VERSIONS_WORKFLOW" "version listing never references a dedicated monitor credential"
forbid_grep 'app_review_pipeline\.js' "$LIST_VERSIONS_WORKFLOW" "version listing never invokes the shared pipeline CLI"
forbid_grep 'assemble_only\.js' "$LIST_VERSIONS_WORKFLOW" "version listing never invokes assemble-only"
forbid_grep 'submitted:true' "$LIST_VERSIONS_WORKFLOW" "version listing never submits"
require_grep 'list_app_store_versions\.py' "$LIST_VERSIONS_WORKFLOW" "version listing runs the GET-only listing script"
require_grep 'actions/checkout@[0-9a-f]{40}' "$LIST_VERSIONS_WORKFLOW" "version listing pins checkout immutably"
forbid_grep 'GITHUB_TOKEN' "$LIST_VERSIONS_WORKFLOW" "version listing never maps GITHUB_TOKEN"
forbid_grep 'APP_REVIEW_SUBMIT_READ_TOKEN' "$LIST_VERSIONS_WORKFLOW" "version listing never checks out the shared engine"

# GET-only App Info category listing. Encrypted submit-key credentials,
# one GET step, no issue write, no submit, no shared-engine mutation.
LIST_APP_INFO_WORKFLOW=.github/workflows/app-review-list-app-info.yml
require_grep '^  workflow_dispatch:$' "$LIST_APP_INFO_WORKFLOW" "App Info listing has a manual trigger"
for forbidden in 'pull_request' 'pull_request_target' 'workflow_run' 'repository_dispatch' '^  push:' '^  schedule:'; do
  forbid_grep "$forbidden" "$LIST_APP_INFO_WORKFLOW" "App Info listing excludes untrusted trigger ($forbidden)"
done
require_grep '^  contents: read$' "$LIST_APP_INFO_WORKFLOW" "App Info listing needs contents read only"
forbid_grep '^  issues: write$' "$LIST_APP_INFO_WORKFLOW" "App Info listing never grants issue write"
require_grep '^concurrency:$' "$LIST_APP_INFO_WORKFLOW" "App Info listing serializes live reads"
require_grep '^  group: eddies-app-review-list-app-info$' "$LIST_APP_INFO_WORKFLOW" "App Info listing uses its own concurrency group"
require_grep '^  cancel-in-progress: false$' "$LIST_APP_INFO_WORKFLOW" "App Info listing does not cancel an in-flight read"
forbid_grep '^[[:space:]]*(actions|pull-requests|checks|id-token|packages): write' "$LIST_APP_INFO_WORKFLOW" "App Info listing has no extra write permissions"
require_grep 'APP_STORE_CONNECT_KEY_ID' "$LIST_APP_INFO_WORKFLOW" "App Info listing reuses the existing submit key ID"
require_grep 'APP_STORE_CONNECT_ISSUER_ID' "$LIST_APP_INFO_WORKFLOW" "App Info listing reuses the existing submit issuer"
require_grep 'APP_STORE_CONNECT_API_KEY' "$LIST_APP_INFO_WORKFLOW" "App Info listing reuses the existing submit API key"
forbid_grep 'ASC_REVIEW_MONITOR_' "$LIST_APP_INFO_WORKFLOW" "App Info listing never references a dedicated monitor credential"
forbid_grep 'app_review_pipeline\.js' "$LIST_APP_INFO_WORKFLOW" "App Info listing never invokes the shared pipeline CLI"
forbid_grep 'assemble_only\.js' "$LIST_APP_INFO_WORKFLOW" "App Info listing never invokes assemble-only"
forbid_grep 'submitted:true' "$LIST_APP_INFO_WORKFLOW" "App Info listing never submits"
require_grep 'list_app_info_categories\.py' "$LIST_APP_INFO_WORKFLOW" "App Info listing runs the GET-only category script"
require_grep 'actions/checkout@[0-9a-f]{40}' "$LIST_APP_INFO_WORKFLOW" "App Info listing pins checkout immutably"
forbid_grep 'GITHUB_TOKEN' "$LIST_APP_INFO_WORKFLOW" "App Info listing never maps GITHUB_TOKEN"
forbid_grep 'APP_REVIEW_SUBMIT_READ_TOKEN' "$LIST_APP_INFO_WORKFLOW" "App Info listing never checks out the shared engine"
for retired in \
  .github/workflows/app-store-review-status.yml \
  .github/scripts/app_store_review_monitor.py \
  .github/scripts/review_monitor_cycle.sh \
  test/app-store-review-monitor-test.py
do
  if [ -e "$retired" ]; then
    fail "retired dedicated-key monitor path is gone ($retired)"
  else
    pass "retired dedicated-key monitor path is gone ($retired)"
  fi
done

# Phase 1 App Review core is deliberately pure: its tests use only fake App
# Store Connect and GitHub issue boundaries, so this check cannot reach a
# credential, network endpoint, or mutation path.
if python3 test/app-review-core-test.py >/dev/null; then
  pass "App Review deterministic core fake-boundary tests"
else
  fail "App Review deterministic core fake-boundary tests"
fi

# The App Review workflow layer. The pipeline suite drives the real entrypoint
# logic against a fake App Store Connect; the lane suite parses the workflows
# into a model and proves the credential lanes and trust boundaries. Neither
# reads a credential or contacts anything.
if python3 test/app-review-pipeline-test.py >/dev/null 2>&1; then
  pass "App Review pipeline fake-boundary tests"
else
  fail "App Review pipeline fake-boundary tests"
fi
if python3 test/app-review-lanes-test.py >/dev/null 2>&1; then
  pass "App Review workflow credential-lane tests"
else
  fail "App Review workflow credential-lane tests"
fi
if node test/app-review-assemble-test.js >/dev/null; then
  pass "App Review assemble-only adapter tests"
else
  fail "App Review assemble-only adapter tests"
fi
if node test/app-review-full-submit-test.js >/dev/null; then
  pass "App Review full-submit adapter tests"
else
  fail "App Review full-submit adapter tests"
fi
if node test/app-review-upload-test.js >/dev/null; then
  pass "App Review screenshot-upload adapter tests"
else
  fail "App Review screenshot-upload adapter tests"
fi
if python3 test/app-review-screenshot-preflight-test.py >/dev/null 2>&1; then
  pass "App Review listing-screenshot preflight tests"
else
  fail "App Review listing-screenshot preflight tests"
fi
if python3 test/app-review-eula-append-test.py >/dev/null 2>&1; then
  pass "App Review 3.1.2 EULA-append fake-boundary tests"
else
  fail "App Review 3.1.2 EULA-append fake-boundary tests"
fi
if python3 test/observe-review-status-test.py >/dev/null 2>&1; then
  pass "App Review live-observe harness fake-engine tests"
else
  fail "App Review live-observe harness fake-engine tests"
fi

# The submission gate is the captain-approved manifest plus a double-confirm
# manual dispatch. It deliberately uses no protected GitHub Environment, so an
# `environment:` key appearing here would silently reshape the captain's gate.
APP_REVIEW_WORKFLOWS=(.github/workflows/app-review-prepare.yml .github/workflows/app-review-submit.yml .github/workflows/app-review-demo-preflight.yml)
for workflow in "${APP_REVIEW_WORKFLOWS[@]}"; do
  forbid_grep '^[[:space:]]*environment:' "$workflow" "App Review gate uses no GitHub Environment ($workflow)"
  require_grep "^  group: eddies-app-review-submission$" "$workflow" "App Review runs serialize on one group ($workflow)"
  require_grep 'pin_app_review_manifest\.sh' "$workflow" "App Review run pins the manifest-approved commit ($workflow)"
  for forbidden in 'pull_request' 'workflow_run' 'repository_dispatch' '^  push:' '^  schedule:'; do
    forbid_grep "$forbidden" "$workflow" "App Review workflow excludes untrusted trigger ($forbidden in $workflow)"
  done
done
# app-review-lanes-test.py owns the per-step credential-lane model; these are
# the coarse whole-file invariants that must hold however the jobs are shaped.
# The existing repo secret is EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN. Submit maps
# it onto the engine env APP_REVIEW_MONITOR_VARIABLE_TOKEN; assemble, prepare,
# and preflight never receive it.
require_grep 'APP_REVIEW_MONITOR_VARIABLE_TOKEN: \$\{\{ secrets\.EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN \}\}' .github/workflows/app-review-submit.yml "submit maps the existing Eddie monitor variable token onto the engine env"
forbid_grep 'EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN' .github/workflows/app-review-prepare.yml "preparation never receives the monitor variable token"
forbid_grep 'EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN' .github/workflows/app-review-demo-preflight.yml "the readiness preflight never receives the monitor variable token"
require_grep 'assemble_only.js --assemble-only --first-release' .github/workflows/app-review-submit.yml "submit workflow runs Node assemble-only first-release"
require_grep 'full_submit.js --submit --first-release' .github/workflows/app-review-submit.yml "submit workflow runs Node full-submit first-release when mode=submit"
forbid_grep 'app_review_pipeline.js submit' .github/workflows/app-review-submit.yml "submit workflow never invokes the Node pipeline submit command"
forbid_grep 'python3 tools/app-review/submit.py' .github/workflows/app-review-submit.yml "submit workflow never invokes the retired Python submit engine"
forbid_grep '16df9345ada8d50f4e1f7637839b8f2616c54ddb' .github/workflows/app-review-submit.yml "submit workflow no longer pins the superseded first-release-only SHA"
forbid_grep 'appStoreVersionSubmissions|reviewSubmissions' tools/app-review/prepare.py "preparation contains no Apple submission path"
forbid_grep 'appStoreVersionSubmissions|reviewSubmissions' tools/app-review/demo_preflight.py "the readiness preflight contains no Apple submission path"
forbid_grep 'appStoreVersionSubmissions|reviewSubmissions' tools/app-review/append_standard_eula.py "the EULA append never submits for review"
EULA_APPEND_WORKFLOW=.github/workflows/app-review-eula-append.yml
forbid_grep '^[[:space:]]*environment:' "$EULA_APPEND_WORKFLOW" "the EULA append uses no GitHub Environment"
require_grep "^  group: eddies-app-review-eula-append$" "$EULA_APPEND_WORKFLOW" "the EULA append uses its own concurrency group"
require_grep 'append_standard_eula\.py' "$EULA_APPEND_WORKFLOW" "the EULA append runs the one-shot script"
forbid_grep 'pin_app_review_manifest\.sh' "$EULA_APPEND_WORKFLOW" "the EULA append does not pin a manifest commit"
forbid_grep 'EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN' "$EULA_APPEND_WORKFLOW" "the EULA append never receives the monitor variable token"
require_grep "github.ref == 'refs/heads/main'" "$EULA_APPEND_WORKFLOW" "the EULA append is pinned to main"
require_grep 'APPEND-EULA' "$EULA_APPEND_WORKFLOW" "the EULA append requires an explicit confirm token"
for forbidden in 'pull_request' 'workflow_run' 'repository_dispatch' '^  push:' '^  schedule:'; do
  forbid_grep "$forbidden" "$EULA_APPEND_WORKFLOW" "EULA append excludes untrusted trigger ($forbidden)"
done
if [ -x .github/scripts/pin_app_review_manifest.sh ]; then
  pass "App Review manifest pin script is executable"
else
  fail "App Review manifest pin script is executable"
fi
forbid_grep 'curl|wget|PRIVATE_KEY|APP_STORE_CONNECT' .github/scripts/pin_app_review_manifest.sh "the manifest pin handles no credential and contacts nothing"

# The shared GET-only monitor consumes APP_REVIEW_MONITOR_VERSION, on an
# off-top-of-hour four-hour cadence.
require_grep 'vars\.APP_REVIEW_MONITOR_VERSION' "$REVIEW_WORKFLOW" "review monitor reads the shared-tool arming variable"
require_grep '^    - cron: "[1-9][0-9]? \*/4 \* \* \*"$' "$REVIEW_WORKFLOW" "review monitor polls four-hourly off the top of the hour"

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
require_grep 'Live Sandbox evidence and remaining boundaries' "$APP_STORE_DOC" \
  "App Store configuration record keeps its live evidence boundary"
forbid_grep 'submitted for App Review|purchase succeeded|Sandbox purchase verified' "$APP_STORE_DOC" \
  "App Store configuration record claims no purchase, Sandbox, or App Review success"

# --- Result ----------------------------------------------------------------

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "release-checks: $FAILURES check(s) failed" >&2
  exit 1
fi
echo "release-checks: all checks passed"
