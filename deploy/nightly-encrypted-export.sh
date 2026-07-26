#!/usr/bin/env bash
# Export the private database, encrypt it with age, and upload it to an
# independent HTTPS destination. This script intentionally refuses to create a
# same-disk fallback that could be mistaken for off-site recovery.
set -Eeuo pipefail

log() { printf 'eddies-wallet-backup: %s\n' "$*" >&2; }
stop() { log "STOPPED: $*"; exit 78; }

ENV_FILE="${BACKUP_ENV_FILE:-/etc/eddies-wallet/backup.env}"
[[ -r "$ENV_FILE" ]] || stop "independent encrypted-export destination is not configured; missing $ENV_FILE; no same-disk dump was created"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

[[ -n "${BACKUP_DESTINATION:-}" ]] || stop "BACKUP_DESTINATION is not configured; no same-disk dump was created"
[[ -n "${BACKUP_AGE_RECIPIENT:-}" ]] || stop "BACKUP_AGE_RECIPIENT is not configured; no export was created"
[[ "$BACKUP_DESTINATION" == https://* ]] || stop "BACKUP_DESTINATION must be an independent HTTPS PUT endpoint; no same-disk dump was created"
case "$BACKUP_DESTINATION" in
  https://localhost*|https://127.*|https://0.0.0.0*|https://\[::1\]*|https://host.docker.internal*)
    stop "BACKUP_DESTINATION points at the local host; no same-disk dump was created"
    ;;
esac

COMPOSE_DIR="${COMPOSE_DIR:-/opt/eddies-wallet/deploy}"
COMPOSE_FILE="${COMPOSE_FILE:-$COMPOSE_DIR/compose.yaml}"
[[ -f "$COMPOSE_FILE" ]] || stop "Compose project is not deployed at $COMPOSE_FILE; no dump was created"
[[ -f "$COMPOSE_DIR/.env" ]] || stop "host-only Compose environment is missing at $COMPOSE_DIR/.env; no dump was created"
command -v age >/dev/null 2>&1 || stop "age is not installed; no dump was created"
command -v curl >/dev/null 2>&1 || stop "curl is not installed; no dump was created"

POSTGRES_DB="${POSTGRES_DB:?POSTGRES_DB is missing from $COMPOSE_DIR/.env}"
POSTGRES_USER="${POSTGRES_USER:?POSTGRES_USER is missing from $COMPOSE_DIR/.env}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DESTINATION="${BACKUP_DESTINATION%/}/eddies-wallet-${STAMP}.sql.gz.age"

log "exporting database to encrypted independent destination"
docker compose --project-directory "$COMPOSE_DIR" --file "$COMPOSE_FILE" exec -T db \
  pg_dump --no-owner --no-privileges -U "$POSTGRES_USER" "$POSTGRES_DB" \
  | gzip -c \
  | age --encrypt --recipient "$BACKUP_AGE_RECIPIENT" \
  | curl --fail --silent --show-error --upload-file - "$DESTINATION"
log "encrypted export uploaded: $DESTINATION"
