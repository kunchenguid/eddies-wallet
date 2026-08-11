#!/usr/bin/env bash
# Detach to the exact commit that last changed this version's App Review manifest.
#
# The captain's approval artifact is an ordinary reviewed merge of
# tools/app-review/manifests/<version>.json on the default branch. Running the
# pipeline from the manifest-approved commit - rather than from whatever main
# happens to be - means a later push cannot change the code or the reviewed bytes
# that a submission uses, and the recovery journal keys on that same commit.
#
# Reads EDDIES_APP_REVIEW_VERSION. Exports EDDIES_APP_REVIEW_APPROVED_COMMIT to
# the rest of the job. It contacts nothing and handles no credential.
set -euo pipefail

version="${EDDIES_APP_REVIEW_VERSION:-}"
if ! [[ "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "EDDIES_APP_REVIEW_VERSION must be an exact marketing version, for example 0.2.0" >&2
  exit 1
fi

manifest_path="tools/app-review/manifests/${version}.json"
if [ ! -f "$manifest_path" ]; then
  echo "No captain-approved manifest exists at $manifest_path on the default branch." >&2
  exit 1
fi

approved_commit="$(git log -1 --format=%H -- "$manifest_path")"
if ! [[ "$approved_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Could not resolve the commit that last approved $manifest_path." >&2
  exit 1
fi

git checkout --detach "$approved_commit"
echo "Pinned $manifest_path at $approved_commit"

if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'EDDIES_APP_REVIEW_APPROVED_COMMIT=%s\n' "$approved_commit" >>"$GITHUB_ENV"
else
  printf 'EDDIES_APP_REVIEW_APPROVED_COMMIT=%s\n' "$approved_commit"
fi
