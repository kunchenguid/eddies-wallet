#!/usr/bin/env bash
# Resolves the one exact App Store review cycle a monitor run may observe.
#
# A deliberately unarmed schedule is not a failure. When neither cycle variable
# is set there is no submitted cycle to watch, so the run reports armed=false,
# makes no Apple request, and succeeds. Failing instead would put this workflow
# permanently red between review cycles, which teaches everyone to ignore the
# one signal that is supposed to mean "App Review state changed".
#
# A half-configured schedule is still a hard failure: half a cycle identity can
# only ever point at the wrong version or the wrong build, and silently watching
# the wrong build is exactly what the exact-cycle contract exists to prevent.
#
# Reads: EVENT_NAME plus SCHEDULED_VERSION/SCHEDULED_BUILD (schedule) or
# INPUT_VERSION/INPUT_BUILD/INPUT_REARM (manual dispatch). Writes GitHub Actions
# outputs when GITHUB_OUTPUT is set, and stdout otherwise so it is directly
# testable. It never contacts Apple or GitHub and handles no credential.
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
  version="${SCHEDULED_VERSION:-}"
  build="${SCHEDULED_BUILD:-}"
  rearm="false"
  if [ -z "$version" ] && [ -z "$build" ]; then
    echo "No App Store review cycle is armed. Set the ASC_REVIEW_MONITOR_VERSION and ASC_REVIEW_MONITOR_BUILD repository variables together to watch one."
    emit "armed=false"
    exit 0
  fi
  if [ -z "$version" ] || [ -z "$build" ]; then
    echo "ASC_REVIEW_MONITOR is half configured. Set both ASC_REVIEW_MONITOR_VERSION and ASC_REVIEW_MONITOR_BUILD, or neither." >&2
    exit 1
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
