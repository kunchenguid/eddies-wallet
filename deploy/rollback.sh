#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_HOST="${REMOTE_HOST:?Set REMOTE_HOST at invocation time; do not commit an address}"
REMOTE_USER="${REMOTE_USER:-eddies}"
REMOTE_DIR="${REMOTE_DIR:-/opt/eddies-wallet/deploy}"
ROLLBACK_BACKEND_IMAGE="${ROLLBACK_BACKEND_IMAGE:?Set ROLLBACK_BACKEND_IMAGE to a previously deployed immutable image}"

ssh -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" \
  "grep -q '^BACKEND_IMAGE=' '$REMOTE_DIR/.env' && sed -i 's#^BACKEND_IMAGE=.*#BACKEND_IMAGE=$ROLLBACK_BACKEND_IMAGE#' '$REMOTE_DIR/.env' || printf '\\nBACKEND_IMAGE=%s\\n' '$ROLLBACK_BACKEND_IMAGE' >> '$REMOTE_DIR/.env'"
ssh -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" \
  "docker compose --project-directory '$REMOTE_DIR' --file '$REMOTE_DIR/compose.yaml' pull backend && docker compose --project-directory '$REMOTE_DIR' --file '$REMOTE_DIR/compose.yaml' up -d backend proxy"
