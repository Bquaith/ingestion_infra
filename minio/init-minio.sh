#!/bin/sh
set -eu

MINIO_ALIAS="${MINIO_ALIAS:-local}"
MINIO_URL="${MINIO_URL:-http://minio:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
POLICIES_DIR="${POLICIES_DIR:-/policies}"
LANDING_BUCKET_NAME="${LANDING_BUCKET_NAME:-ingestion-landing}"
LANDING_BUCKET_ENABLE_VERSIONING="${LANDING_BUCKET_ENABLE_VERSIONING:-true}"

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

ensure_bucket() {
  bucket_name="$1"

  if mc ls "$MINIO_ALIAS/$bucket_name" >/dev/null 2>&1; then
    log "Bucket '$bucket_name' already exists"
  else
    log "Creating bucket '$bucket_name'"
    mc mb "$MINIO_ALIAS/$bucket_name" >/dev/null
  fi

  if [ "$LANDING_BUCKET_ENABLE_VERSIONING" = "true" ]; then
    log "Ensuring versioning is enabled for '$bucket_name'"
    mc version enable "$MINIO_ALIAS/$bucket_name" >/dev/null 2>&1 || true
  fi
}

apply_ingestion_policy() {
  tmp_policy_file="$(mktemp)"
  cat >"$tmp_policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [
        "arn:aws:s3:::$LANDING_BUCKET_NAME"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::$LANDING_BUCKET_NAME/*"
      ]
    }
  ]
}
EOF

  apply_policy "ingestion_rw" "$tmp_policy_file"
  rm -f "$tmp_policy_file"
}

main() {
  wait_for_minio
  apply_policy "producer" "$POLICIES_DIR/producer.json"
  apply_policy "consumer" "$POLICIES_DIR/consumer.json"
  apply_ingestion_policy
  ensure_bucket "$LANDING_BUCKET_NAME"
  log "MinIO policy bootstrap completed"
}

main "$@"
