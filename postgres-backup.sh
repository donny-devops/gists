#!/usr/bin/env bash
# =============================================================================
# postgres-backup.sh
# Automated PostgreSQL backup with:
#   - pg_dump with compression
#   - Optional S3 upload (via AWS CLI)
#   - Local retention policy (keeps N most recent backups)
#   - Slack webhook notification on success or failure
#
# Usage:
#   ./postgres-backup.sh
#
# Required environment variables (or edit defaults below):
#   PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE
#   BACKUP_DIR       — local dir to store backups (default: /var/backups/postgres)
#   S3_BUCKET        — S3 bucket name (optional; skip upload if empty)
#   S3_PREFIX        — S3 key prefix (default: postgres-backups)
#   RETENTION_DAYS   — days to keep local backups (default: 7)
#   SLACK_WEBHOOK    — Slack incoming webhook URL (optional)
#
# Recommended cron (daily at 2 AM):
#   0 2 * * * /opt/scripts/postgres-backup.sh >> /var/log/postgres-backup.log 2>&1
# =============================================================================

set -euo pipefail

# Configuration — override via environment variables
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postgres}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-postgres-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/${PGDATABASE}_${TIMESTAMP}.dump.gz"
LOG_PREFIX="[postgres-backup]"

log()   { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} INFO  $*"; }
error() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} ERROR $*" >&2; }

slack_notify() {
  local message="$1"
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    curl -s -X POST "$SLACK_WEBHOOK" \
      -H 'Content-type: application/json' \
      --data "{\"text\": \"$message\"}" || true
  fi
}

on_error() {
  local exit_code=$?
  error "Backup FAILED (exit code $exit_code). See output above."
  slack_notify ":x: *PostgreSQL backup FAILED* for \`${PGDATABASE}\` on \`$(hostname)\` at $(date)"
  exit $exit_code
}
trap on_error ERR

check_deps() {
  for cmd in pg_dump gzip; do
    command -v "$cmd" &>/dev/null || { error "Required command not found: $cmd"; exit 1; }
  done
  if [[ -n "$S3_BUCKET" ]]; then
    command -v aws &>/dev/null || { error "AWS CLI not found but S3_BUCKET is set."; exit 1; }
  fi
}

create_backup() {
  mkdir -p "$BACKUP_DIR"
  log "Starting backup of database '${PGDATABASE}' to ${BACKUP_FILE}"

  PGPASSWORD="$PGPASSWORD" pg_dump \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --format=custom \
    --compress=9 \
    --no-password \
    "$PGDATABASE" | gzip > "$BACKUP_FILE"

  local size
  size=$(du -sh "$BACKUP_FILE" | cut -f1)
  log "Backup created: ${BACKUP_FILE} (${size})"
}

upload_to_s3() {
  if [[ -z "$S3_BUCKET" ]]; then
    log "S3_BUCKET not set — skipping S3 upload."
    return 0
  fi

  local s3_key="${S3_PREFIX}/${PGDATABASE}/$(basename "$BACKUP_FILE")"
  log "Uploading to s3://${S3_BUCKET}/${s3_key}"

  aws s3 cp "$BACKUP_FILE" "s3://${S3_BUCKET}/${s3_key}" \
    --storage-class STANDARD_IA \
    --no-progress

  log "S3 upload complete."
}

cleanup_old_backups() {
  log "Removing local backups older than ${RETENTION_DAYS} day(s)."
  find "$BACKUP_DIR" \
    -name "${PGDATABASE}_*.dump.gz" \
    -type f \
    -mtime +"${RETENTION_DAYS}" \
    -exec rm -v {} \;
  log "Local retention cleanup complete."
}

main() {
  log "========== PostgreSQL Backup Start =========="
  check_deps
  create_backup
  upload_to_s3
  cleanup_old_backups
  log "========== PostgreSQL Backup Complete =========="
  slack_notify ":white_check_mark: *PostgreSQL backup succeeded* for \`${PGDATABASE}\` on \`$(hostname)\` at $(date). File: \`$(basename "$BACKUP_FILE")\`"
}

main "$@"
