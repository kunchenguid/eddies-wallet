#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_HOST="${REMOTE_HOST:?Set REMOTE_HOST at invocation time; do not commit an address}"
REMOTE_USER="${REMOTE_USER:-eddies}"
REMOTE_DIR="${REMOTE_DIR:-/opt/eddies-wallet/deploy}"
MIGRATION_COMMAND="${MIGRATION_COMMAND:?Set MIGRATION_COMMAND to the reviewed backend migration command}"

ssh -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" \
  "docker compose --project-directory '$REMOTE_DIR' --file '$REMOTE_DIR/compose.yaml' run --rm --no-deps backend sh -lc '$MIGRATION_COMMAND'"
