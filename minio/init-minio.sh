#!/bin/sh
set -eu

MINIO_ALIAS="${MINIO_ALIAS:-local}"
MINIO_URL="${MINIO_URL:-http://minio:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
POLICIES_DIR="${POLICIES_DIR:-/policies}"

log() {
  echo "[minio-init] $*"
}

wait_for_minio() {
  attempt=1

  while ! mc alias set "$MINIO_ALIAS" "$MINIO_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
    if [ "$attempt" -ge 60 ]; then
      log "MinIO is not ready after 300 seconds"
      exit 1
    fi

    log "Waiting for MinIO to become ready (attempt $attempt/60)"
    attempt=$((attempt + 1))
    sleep 5
  done

  while ! mc admin info "$MINIO_ALIAS" >/dev/null 2>&1; do
    if [ "$attempt" -ge 60 ]; then
      log "MinIO admin API is not ready after 300 seconds"
      exit 1
    fi

    log "Waiting for MinIO admin API (attempt $attempt/60)"
    attempt=$((attempt + 1))
    sleep 5
  done
}

apply_policy() {
  policy_name="$1"
  policy_file="$2"

  if mc admin policy info "$MINIO_ALIAS" "$policy_name" >/dev/null 2>&1; then
    log "Refreshing policy '$policy_name'"
    mc admin policy remove "$MINIO_ALIAS" "$policy_name" >/dev/null 2>&1 || true
  else
    log "Creating policy '$policy_name'"
  fi

  mc admin policy create "$MINIO_ALIAS" "$policy_name" "$policy_file" >/dev/null
}

main() {
  wait_for_minio
  apply_policy "producer" "$POLICIES_DIR/producer.json"
  apply_policy "consumer" "$POLICIES_DIR/consumer.json"
  log "MinIO policy bootstrap completed"
}

main "$@"
