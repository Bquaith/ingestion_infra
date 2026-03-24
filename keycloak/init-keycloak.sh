#!/bin/sh
set -eu

KCADM="/opt/keycloak/bin/kcadm.sh"
KCADM_CONFIG="/tmp/kcadm.config"
export KCADM_CONFIG

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
KEYCLOAK_ADMIN_REALM="${KEYCLOAK_ADMIN_REALM:-master}"
KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USERNAME:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

KEYCLOAK_REALM="${KEYCLOAK_REALM:-vkr}"
MINIO_CONSOLE_URL="${MINIO_CONSOLE_URL:-http://localhost:9001}"
MINIO_OIDC_REDIRECT_URI="${MINIO_OIDC_REDIRECT_URI:-http://localhost:9001/oauth_callback}"
MINIO_CLIENT_ID="${MINIO_CLIENT_ID:-minio-console}"
MINIO_CLIENT_SECRET="${MINIO_CLIENT_SECRET:-minio-console-secret}"

SYSTEM_ROLES_CLIENT_ID="${SYSTEM_ROLES_CLIENT_ID:-system-roles}"
SYSTEM_ROLES_CLAIM_NAME="${SYSTEM_ROLES_CLAIM_NAME:-system_roles}"

MINIO_TEST_USERNAME="${MINIO_TEST_USERNAME:-minio-user}"
MINIO_TEST_PASSWORD="${MINIO_TEST_PASSWORD:-minio-user}"

log() {
  echo "[keycloak-init] $*"
}

kcadm() {
  "$KCADM" "$@"
}

wait_for_keycloak() {
  attempt=1

  while ! "$KCADM" config credentials \
    --server "$KEYCLOAK_URL" \
    --realm "$KEYCLOAK_ADMIN_REALM" \
    --client admin-cli \
    --user "$KEYCLOAK_ADMIN_USERNAME" \
    --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1; do
    if [ "$attempt" -ge 60 ]; then
      log "Keycloak is not ready after 300 seconds"
      exit 1
    fi

    log "Waiting for Keycloak to become ready (attempt $attempt/60)"
    attempt=$((attempt + 1))
    sleep 5
  done
}

realm_exists() {
  kcadm get "realms/$KEYCLOAK_REALM" >/dev/null 2>&1
}

user_exists() {
  username="$1"
  kcadm get users -r "$KEYCLOAK_REALM" -q username="$username" -q exact=true | grep -q "\"username\" : \"$username\""
}

user_id() {
  username="$1"
  kcadm get users -r "$KEYCLOAK_REALM" -q username="$username" -q exact=true |
    sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

realm_role_exists() {
  role_name="$1"
  kcadm get "roles/$role_name" -r "$KEYCLOAK_REALM" >/dev/null 2>&1
}

client_uuid_by_client_id() {
  target_client_id="$1"
  kcadm get clients -r "$KEYCLOAK_REALM" -q clientId="$target_client_id" |
    sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

client_role_exists() {
  client_uuid="$1"
  role_name="$2"
  kcadm get "clients/$client_uuid/roles/$role_name" -r "$KEYCLOAK_REALM" >/dev/null 2>&1
}

mapper_id_by_name() {
  mapper_client_uuid="$1"
  target_mapper_name="$2"
  current_id=""

  kcadm get "clients/$mapper_client_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" |
    while IFS= read -r line; do
      case "$line" in
        *'"id"'*)
          current_id="$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
          ;;
        *'"name"'*)
          current_name="$(printf '%s\n' "$line" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
          if [ "$current_name" = "$target_mapper_name" ]; then
            printf '%s\n' "$current_id"
            break
          fi
          ;;
      esac
    done
}

group_id() {
  target_group_name="$1"
  current_id=""

  kcadm get groups -r "$KEYCLOAK_REALM" -q search="$target_group_name" |
    while IFS= read -r line; do
      case "$line" in
        *'"id"'*)
          current_id="$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
          ;;
        *'"name"'*)
          current_name="$(printf '%s\n' "$line" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
          if [ "$current_name" = "$target_group_name" ]; then
            printf '%s\n' "$current_id"
            break
          fi
          ;;
      esac
    done
}

delete_realm_role_if_exists() {
  role_name="$1"

  if ! realm_role_exists "$role_name"; then
    return
  fi

  log "Removing legacy realm role '$role_name'"
  kcadm delete "roles/$role_name" -r "$KEYCLOAK_REALM" >/dev/null
}

delete_group_if_exists() {
  target_group_name="$1"
  gid="$(group_id "$target_group_name")"

  if [ -z "$gid" ]; then
    return
  fi

  log "Removing legacy group '$target_group_name'"
  kcadm delete "groups/$gid" -r "$KEYCLOAK_REALM" >/dev/null
}

delete_client_if_exists() {
  target_client_id="$1"
  client_uuid="$(client_uuid_by_client_id "$target_client_id")"

  if [ -z "$client_uuid" ]; then
    return
  fi

  log "Removing legacy client '$target_client_id'"
  kcadm delete "clients/$client_uuid" -r "$KEYCLOAK_REALM" >/dev/null
}

delete_mapper_if_exists() {
  mapper_client_uuid="$1"
  target_mapper_name="$2"
  mapper_id="$(mapper_id_by_name "$mapper_client_uuid" "$target_mapper_name")"

  if [ -z "$mapper_id" ]; then
    return
  fi

  log "Removing protocol mapper '$target_mapper_name'"
  kcadm delete "clients/$mapper_client_uuid/protocol-mappers/models/$mapper_id" -r "$KEYCLOAK_REALM" >/dev/null
}

ensure_master_realm() {
  log "Updating realm 'master' for local HTTP access"
  kcadm update realms/master -s sslRequired=NONE >/dev/null
}

ensure_realm() {
  if realm_exists; then
    log "Realm '$KEYCLOAK_REALM' already exists"
    kcadm update "realms/$KEYCLOAK_REALM" -s enabled=true -s sslRequired=NONE >/dev/null
    return
  fi

  log "Creating realm '$KEYCLOAK_REALM'"
  kcadm create realms -s realm="$KEYCLOAK_REALM" -s enabled=true -s sslRequired=NONE >/dev/null
}

ensure_oidc_client() {
  client_uuid="$(client_uuid_by_client_id "$MINIO_CLIENT_ID")"

  if [ -z "$client_uuid" ]; then
    log "Creating client '$MINIO_CLIENT_ID'"
    kcadm create clients -r "$KEYCLOAK_REALM" \
      -s clientId="$MINIO_CLIENT_ID" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=true \
      -s serviceAccountsEnabled=false \
      -s secret="$MINIO_CLIENT_SECRET" \
      -s "rootUrl=$MINIO_CONSOLE_URL" \
      -s "baseUrl=$MINIO_CONSOLE_URL" \
      -s "adminUrl=$MINIO_CONSOLE_URL" \
      -s "redirectUris=[\"$MINIO_OIDC_REDIRECT_URI\"]" \
      -s 'webOrigins=["+"]' >/dev/null
    return
  fi

  log "Client '$MINIO_CLIENT_ID' already exists"
  kcadm update "clients/$client_uuid" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s serviceAccountsEnabled=false \
    -s secret="$MINIO_CLIENT_SECRET" \
    -s "rootUrl=$MINIO_CONSOLE_URL" \
    -s "baseUrl=$MINIO_CONSOLE_URL" \
    -s "adminUrl=$MINIO_CONSOLE_URL" \
    -s "redirectUris=[\"$MINIO_OIDC_REDIRECT_URI\"]" \
    -s 'webOrigins=["+"]' >/dev/null
}

ensure_system_roles_client() {
  client_uuid="$(client_uuid_by_client_id "$SYSTEM_ROLES_CLIENT_ID")"

  if [ -z "$client_uuid" ]; then
    log "Creating system roles client '$SYSTEM_ROLES_CLIENT_ID'"
    kcadm create clients -r "$KEYCLOAK_REALM" \
      -s clientId="$SYSTEM_ROLES_CLIENT_ID" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=false >/dev/null
    return
  fi

  log "System roles client '$SYSTEM_ROLES_CLIENT_ID' already exists"
  kcadm update "clients/$client_uuid" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false >/dev/null
}

ensure_client_role() {
  client_uuid="$1"
  role_name="$2"

  if client_role_exists "$client_uuid" "$role_name"; then
    log "System role '$role_name' already exists"
    return
  fi

  log "Creating system role '$role_name'"
  kcadm create "clients/$client_uuid/roles" -r "$KEYCLOAK_REALM" -s name="$role_name" >/dev/null
}

ensure_system_roles_mapper() {
  minio_client_uuid="$(client_uuid_by_client_id "$MINIO_CLIENT_ID")"
  system_roles_client_uuid="$(client_uuid_by_client_id "$SYSTEM_ROLES_CLIENT_ID")"
  mapper_name="system-roles-claim"

  if [ -z "$minio_client_uuid" ] || [ -z "$system_roles_client_uuid" ]; then
    log "Unable to resolve clients for system roles mapper"
    exit 1
  fi

  delete_mapper_if_exists "$minio_client_uuid" "groups-to-policy-claim"
  delete_mapper_if_exists "$minio_client_uuid" "realm-roles-to-policy-claim"
  delete_mapper_if_exists "$minio_client_uuid" "policy-to-console-admin"
  delete_mapper_if_exists "$minio_client_uuid" "$mapper_name"

  log "Creating protocol mapper '$mapper_name'"
  kcadm create "clients/$minio_client_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" -f - <<EOF >/dev/null
{
  "name": "$mapper_name",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-usermodel-client-role-mapper",
  "consentRequired": false,
  "config": {
    "introspection.token.claim": "true",
    "multivalued": "true",
    "userinfo.token.claim": "true",
    "id.token.claim": "true",
    "lightweight.claim": "false",
    "access.token.claim": "true",
    "claim.name": "$SYSTEM_ROLES_CLAIM_NAME",
    "jsonType.label": "String",
    "usermodel.clientRoleMapping.clientId": "$SYSTEM_ROLES_CLIENT_ID"
  }
}
EOF
}

ensure_user() {
  username="$1"
  password="$2"
  first_name="$3"
  last_name="$4"
  email="$5"

  if user_exists "$username"; then
    log "User '$username' already exists"
    kcadm update "users/$(user_id "$username")" -r "$KEYCLOAK_REALM" \
      -s firstName="$first_name" \
      -s lastName="$last_name" \
      -s email="$email" \
      -s emailVerified=true \
      -s enabled=true >/dev/null
  else
    log "Creating user '$username'"
    kcadm create users -r "$KEYCLOAK_REALM" \
      -s username="$username" \
      -s firstName="$first_name" \
      -s lastName="$last_name" \
      -s email="$email" \
      -s enabled=true \
      -s emailVerified=true >/dev/null
  fi

  kcadm set-password -r "$KEYCLOAK_REALM" --username "$username" --new-password "$password" >/dev/null
}

sync_user_system_roles() {
  username="$1"
  shift

  kcadm remove-roles -r "$KEYCLOAK_REALM" --uusername "$username" --cclientid "$SYSTEM_ROLES_CLIENT_ID" \
    --rolename producer --rolename consumer --rolename admin >/dev/null 2>&1 || true

  for role_name in "$@"; do
    kcadm add-roles -r "$KEYCLOAK_REALM" --uusername "$username" --cclientid "$SYSTEM_ROLES_CLIENT_ID" \
      --rolename "$role_name" >/dev/null
  done
}

cleanup_legacy_state() {
  delete_group_if_exists "producer"
  delete_group_if_exists "consumer"
  delete_group_if_exists "admin"

  delete_realm_role_if_exists "producer"
  delete_realm_role_if_exists "consumer"
  delete_realm_role_if_exists "admin"
  delete_realm_role_if_exists "readwrite"
  delete_realm_role_if_exists "readonly"
  delete_realm_role_if_exists "consoleAdmin"

  delete_client_if_exists "minio-producer"
  delete_client_if_exists "minio-consumer"
  delete_client_if_exists "minio-admin"
}

main() {
  wait_for_keycloak
  ensure_master_realm
  ensure_realm
  cleanup_legacy_state

  ensure_oidc_client
  ensure_system_roles_client

  system_roles_client_uuid="$(client_uuid_by_client_id "$SYSTEM_ROLES_CLIENT_ID")"
  ensure_client_role "$system_roles_client_uuid" "producer"
  ensure_client_role "$system_roles_client_uuid" "consumer"
  ensure_client_role "$system_roles_client_uuid" "admin"
  ensure_system_roles_mapper

  ensure_user "admin" "admin" "Platform" "Admin" "admin@local.test"
  sync_user_system_roles "admin" "admin"

  ensure_user "consumer" "consumer" "Data" "Consumer" "consumer@local.test"
  sync_user_system_roles "consumer" "consumer"

  ensure_user "producer" "producer" "Data" "Producer" "producer@local.test"
  sync_user_system_roles "producer" "producer"

  ensure_user "$MINIO_TEST_USERNAME" "$MINIO_TEST_PASSWORD" "Multi" "Role User" "${MINIO_TEST_USERNAME}@local.test"
  sync_user_system_roles "$MINIO_TEST_USERNAME" "producer" "consumer"

  log "Keycloak bootstrap completed"
}

main "$@"
