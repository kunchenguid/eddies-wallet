#!/usr/bin/env bash
# Resolves the one exact App Store review cycle a monitor run may observe.
#
# A deliberately unarmed schedule is not a failure. When no cycle is configured
# there is no submitted cycle to watch, so the run reports armed=false, makes no
# Apple request, and succeeds. Failing instead would put this workflow
# permanently red between review cycles, which teaches everyone to ignore the
# one signal that is supposed to mean "App Review state changed".
#
# A half-configured schedule is still a hard failure: half a cycle identity can
# only ever point at the wrong version or the wrong build, and silently watching
# the wrong build is exactly what the exact-cycle contract exists to prevent.
# That is why EDDIES_REVIEW_MONITOR_CYCLE is one canonical value rather than two
# variables: the submission handoff arms a whole cycle or arms nothing.
#
# The canonical value is the exact compact JSON the submit handoff writes,
# {"build":"<build>","v":1,"version":"<version>"}. Accepting only that exact
# shape keeps this resolver free of an interpreter and refuses anything a hand
# edit might have reshaped.
#
# The retiring ASC_REVIEW_MONITOR_VERSION/ASC_REVIEW_MONITOR_BUILD pair is still
# honored so the migration can be verified before the pair is cleared. Setting
# both sources to different cycles is a hard failure, never a silent preference.
#
# Reads: EVENT_NAME plus SCHEDULED_CYCLE and/or SCHEDULED_VERSION/SCHEDULED_BUILD
# (schedule) or INPUT_VERSION/INPUT_BUILD/INPUT_REARM (manual dispatch). Writes
# GitHub Actions outputs when GITHUB_OUTPUT is set, and stdout otherwise so it is
# directly testable. It never contacts Apple or GitHub and handles no credential.
set -euo pipefail

event="${EVENT_NAME:-}"
if [ -z "$event" ]; then
  echo "EVENT_NAME is required." >&2
  exit 1
fi

emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$@" >>"$GITHUB_OUTPUT"
  else
    printf '%s\n' "$@"
  fi
}

if [ "$event" = "schedule" ]; then
  cycle="${SCHEDULED_CYCLE:-}"
  version="${SCHEDULED_VERSION:-}"
  build="${SCHEDULED_BUILD:-}"
  rearm="false"

  if [ -n "$cycle" ]; then
    canonical='^\{"build":"([0-9]+(\.[0-9]+){0,2})","v":1,"version":"([0-9]+(\.[0-9]+){1,2})"\}$'
    if ! [[ "$cycle" =~ $canonical ]]; then
      echo "EDDIES_REVIEW_MONITOR_CYCLE is not the canonical cycle value written by the App Review submit handoff." >&2
      exit 1
    fi
    canonical_build="${BASH_REMATCH[1]}"
    canonical_version="${BASH_REMATCH[3]}"
    if [ -n "$version" ] || [ -n "$build" ]; then
      if [ "$version" != "$canonical_version" ] || [ "$build" != "$canonical_build" ]; then
        echo "EDDIES_REVIEW_MONITOR_CYCLE and the retiring ASC_REVIEW_MONITOR_VERSION/ASC_REVIEW_MONITOR_BUILD pair name different cycles. Clear the pair, or set it to the same cycle." >&2
        exit 1
      fi
    fi
    version="$canonical_version"
    build="$canonical_build"
  else
    if [ -z "$version" ] && [ -z "$build" ]; then
      echo "No App Store review cycle is armed. The App Review submit handoff sets the EDDIES_REVIEW_MONITOR_CYCLE repository variable after Apple accepts a submission."
      emit "armed=false"
      exit 0
    fi
    if [ -z "$version" ] || [ -z "$build" ]; then
      echo "ASC_REVIEW_MONITOR is half configured. Set both ASC_REVIEW_MONITOR_VERSION and ASC_REVIEW_MONITOR_BUILD, or neither." >&2
      exit 1
    fi
  fi
else
  version="${INPUT_VERSION:-}"
  build="${INPUT_BUILD:-}"
  rearm="${INPUT_REARM:-false}"
  if [ -z "$version" ] || [ -z "$build" ]; then
    echo "A manual review-monitor run requires both an exact version and an exact build." >&2
    exit 1
  fi
fi

emit "armed=true" "version=$version" "build=$build" "rearm=$rearm"
