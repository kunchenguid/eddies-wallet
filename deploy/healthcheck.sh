#!/usr/bin/env bash
set -Eeuo pipefail

HEALTHCHECK_URL="${HEALTHCHECK_URL:?Set HEALTHCHECK_URL to the backend health endpoint}"
curl --fail --silent --show-error --max-time "${HEALTHCHECK_TIMEOUT_SECONDS:-15}" "$HEALTHCHECK_URL"
printf '\nhealth check passed: %s\n' "$HEALTHCHECK_URL"
