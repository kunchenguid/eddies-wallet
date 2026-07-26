#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_HOST="${REMOTE_HOST:?Set REMOTE_HOST at invocation time; do not commit an address}"
REMOTE_USER="${REMOTE_USER:-eddies}"
REMOTE_DIR="${REMOTE_DIR:-/opt/eddies-wallet/deploy}"
LOCAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE_USER@$REMOTE_HOST" \
  "test -d '$REMOTE_DIR' || { echo 'bootstrap has not created $REMOTE_DIR' >&2; exit 1; }"

# .env is deliberately excluded. It is created and managed only on the host.
tar -C "$LOCAL_DIR" \
  --exclude='./.env' \
  --exclude='./.git' \
  -cf - . \
  | ssh -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" "tar -xf - -C '$REMOTE_DIR'"

ssh -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" "test -f '$REMOTE_DIR/.env' || { echo 'missing host-only $REMOTE_DIR/.env' >&2; exit 1; }"
ssh -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" \
  "sudo install -m 0755 '$REMOTE_DIR/nightly-encrypted-export.sh' /opt/eddies-wallet/deploy/nightly-encrypted-export.sh && sudo systemctl start eddies-wallet-backup.timer"

MIGRATION_COMMAND="${MIGRATION_COMMAND:?Set MIGRATION_COMMAND to the reviewed backend migration command}"
REMOTE_HOST="$REMOTE_HOST" REMOTE_USER="$REMOTE_USER" REMOTE_DIR="$REMOTE_DIR" MIGRATION_COMMAND="$MIGRATION_COMMAND" \
  "$LOCAL_DIR/migrate.sh"
ssh -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" \
  "docker compose --project-directory '$REMOTE_DIR' --file '$REMOTE_DIR/compose.yaml' pull && docker compose --project-directory '$REMOTE_DIR' --file '$REMOTE_DIR/compose.yaml' up -d --remove-orphans"
