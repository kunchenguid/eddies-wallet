#!/usr/bin/env bash
# Derive the deterministic release identity for one release tag.
#
# stdout is exactly four key=value lines suitable for $GITHUB_OUTPUT:
#   tag_name, release_version, app_store_version, build_number
# Diagnostics go to stderr. Any invalid input exits nonzero.
#
# The same tag always yields the same release_version and app_store_version,
# so a workflow rerun rebuilds the identical source revision. build_number is
# GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT: a rerun of a failed upload gets a new,
# strictly attributable build number for the same tag instead of colliding
# with a build App Store Connect may already have accepted.
set -euo pipefail

TAG_NAME="${1:-}"
if [ -z "$TAG_NAME" ]; then
  echo "Usage: resolve_release_version.sh <tag-name>" >&2
  exit 1
fi

: "${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

RELEASE_VERSION="${TAG_NAME#eddies-wallet-v}"
RELEASE_VERSION="${RELEASE_VERSION#v}"
if ! [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Release tag '$TAG_NAME' must resolve to an App Store version like 1.2.3" >&2
  exit 1
fi

APP_STORE_VERSION="${RELEASE_VERSION%.0}"
BUILD_NUMBER="${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}"

echo "tag_name=$TAG_NAME"
echo "release_version=$RELEASE_VERSION"
echo "app_store_version=$APP_STORE_VERSION"
echo "build_number=$BUILD_NUMBER"
echo "Building Eddie's Wallet $APP_STORE_VERSION ($BUILD_NUMBER) from $TAG_NAME release $RELEASE_VERSION" >&2
