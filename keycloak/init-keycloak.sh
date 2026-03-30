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
INGESTION_SYSTEM_ROLE="${INGESTION_SYSTEM_ROLE:-ingestion_rw}"

AIRFLOW_STS_CLIENT_ID="${AIRFLOW_STS_CLIENT_ID:-airflow-minio-sts}"
AIRFLOW_STS_CLIENT_SECRET="${AIRFLOW_STS_CLIENT_SECRET:-airflow-minio-sts-secret}"
AIRFLOW_CONTRACTS_CLIENT_ID="${AIRFLOW_CONTRACTS_CLIENT_ID:-airflow-contracts}"
AIRFLOW_CONTRACTS_CLIENT_SECRET="${AIRFLOW_CONTRACTS_CLIENT_SECRET:-airflow-contracts-secret}"
AIRFLOW_AUTH_CLIENT_ID="${AIRFLOW_AUTH_CLIENT_ID:-airflow-auth}"
AIRFLOW_AUTH_CLIENT_SECRET="${AIRFLOW_AUTH_CLIENT_SECRET:-airflow-auth-secret}"
AIRFLOW_AUTH_ROOT_URL="${AIRFLOW_AUTH_ROOT_URL:-http://localhost:8088}"
CONTRACTS_API_CLIENT_ID="${CONTRACTS_API_CLIENT_ID:-contracts-api}"
CONTRACTS_CLIENT_ID="${CONTRACTS_CLIENT_ID:-contracts-client}"
CONTRACTS_CLIENT_SECRET="${CONTRACTS_CLIENT_SECRET:-contracts-client-secret}"
CONTRACTS_UI_DEV_CLIENT_ID="${CONTRACTS_UI_DEV_CLIENT_ID:-contracts-ui-dev}"
CONTRACTS_UI_DEV_ROOT_URL="${CONTRACTS_UI_DEV_ROOT_URL:-http://localhost:8000}"
CONTRACTS_UI_DEV_REDIRECT_URI="${CONTRACTS_UI_DEV_REDIRECT_URI:-http://localhost:8000/docs/oauth2-redirect}"
CONTRACTS_READER_ROLE="${CONTRACTS_READER_ROLE:-contracts_reader}"

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

ensure_realm_role() {
  role_name="$1"

  if realm_role_exists "$role_name"; then
    log "Realm role '$role_name' already exists"
    return
  fi

  log "Creating realm role '$role_name'"
  kcadm create roles -r "$KEYCLOAK_REALM" -s name="$role_name" >/dev/null
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

ensure_service_client() {
  target_client_id="$1"
  target_client_secret="$2"
  client_uuid="$(client_uuid_by_client_id "$target_client_id")"

  if [ -z "$client_uuid" ]; then
    log "Creating service client '$target_client_id'"
    kcadm create clients -r "$KEYCLOAK_REALM" \
      -s clientId="$target_client_id" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=true \
      -s secret="$target_client_secret" >/dev/null
    return
  fi

  log "Service client '$target_client_id' already exists"
  kcadm update "clients/$client_uuid" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=true \
    -s secret="$target_client_secret" >/dev/null
}

ensure_resource_client() {
  target_client_id="$1"
  client_uuid="$(client_uuid_by_client_id "$target_client_id")"

  if [ -z "$client_uuid" ]; then
    log "Creating resource client '$target_client_id'"
    kcadm create clients -r "$KEYCLOAK_REALM" \
      -s clientId="$target_client_id" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=false >/dev/null
    return
  fi

  log "Resource client '$target_client_id' already exists"
  kcadm update "clients/$client_uuid" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false >/dev/null
}

ensure_direct_grants_client() {
  target_client_id="$1"
  target_client_secret="$2"
  client_uuid="$(client_uuid_by_client_id "$target_client_id")"

  if [ -z "$client_uuid" ]; then
    log "Creating direct grants client '$target_client_id'"
    kcadm create clients -r "$KEYCLOAK_REALM" \
      -s clientId="$target_client_id" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=true \
      -s serviceAccountsEnabled=false \
      -s secret="$target_client_secret" >/dev/null
    return
  fi

  log "Direct grants client '$target_client_id' already exists"
  kcadm update "clients/$client_uuid" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=true \
    -s serviceAccountsEnabled=false \
    -s secret="$target_client_secret" >/dev/null
}

ensure_public_browser_client() {
  target_client_id="$1"
  target_root_url="$2"
  target_redirect_uri="$3"
  client_uuid="$(client_uuid_by_client_id "$target_client_id")"
  target_docs_url="${target_root_url%/}/docs"

  if [ -z "$client_uuid" ]; then
    log "Creating browser client '$target_client_id'"
    kcadm create clients -r "$KEYCLOAK_REALM" \
      -s clientId="$target_client_id" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=true \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=false \
      -s "rootUrl=$target_root_url" \
      -s "baseUrl=$target_docs_url" \
      -s "redirectUris=[\"$target_redirect_uri\"]" \
      -s "webOrigins=[\"$target_root_url\"]" >/dev/null
    return
  fi

  log "Browser client '$target_client_id' already exists"
  kcadm update "clients/$client_uuid" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s "rootUrl=$target_root_url" \
    -s "baseUrl=$target_docs_url" \
    -s "redirectUris=[\"$target_redirect_uri\"]" \
    -s "webOrigins=[\"$target_root_url\"]" >/dev/null
}

ensure_airflow_auth_client() {
  target_client_id="$1"
  target_client_secret="$2"
  target_root_url="$3"
  client_uuid="$(client_uuid_by_client_id "$target_client_id")"
  target_callback_uri="${target_root_url%/}/auth/oauth-authorized/keycloak"
  target_redirect_root="${target_root_url%/}/*"

  if [ -z "$client_uuid" ]; then
    log "Creating Airflow auth client '$target_client_id'"
    kcadm create clients -r "$KEYCLOAK_REALM" \
      -s clientId="$target_client_id" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=true \
      -s serviceAccountsEnabled=false \
      -s authorizationServicesEnabled=false \
      -s frontchannelLogout=true \
      -s secret="$target_client_secret" \
      -s "rootUrl=$target_root_url" \
      -s "baseUrl=$target_root_url" \
      -s "adminUrl=$target_root_url" \
      -s "redirectUris=[\"$target_callback_uri\",\"$target_redirect_root\"]" \
      -s "webOrigins=[\"$target_root_url\"]" >/dev/null
    return
  fi

  log "Airflow auth client '$target_client_id' already exists"
  kcadm update "clients/$client_uuid" -r "$KEYCLOAK_REALM" \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s serviceAccountsEnabled=false \
    -s authorizationServicesEnabled=false \
    -s frontchannelLogout=true \
    -s secret="$target_client_secret" \
    -s "rootUrl=$target_root_url" \
    -s "baseUrl=$target_root_url" \
    -s "adminUrl=$target_root_url" \
    -s "redirectUris=[\"$target_callback_uri\",\"$target_redirect_root\"]" \
    -s "webOrigins=[\"$target_root_url\"]" >/dev/null
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
  target_client_uuid="$1"
  mapper_name="$2"
  system_roles_client_uuid="$(client_uuid_by_client_id "$SYSTEM_ROLES_CLIENT_ID")"

  if [ -z "$target_client_uuid" ] || [ -z "$system_roles_client_uuid" ]; then
    log "Unable to resolve clients for system roles mapper"
    exit 1
  fi

  delete_mapper_if_exists "$target_client_uuid" "groups-to-policy-claim"
  delete_mapper_if_exists "$target_client_uuid" "realm-roles-to-policy-claim"
  delete_mapper_if_exists "$target_client_uuid" "policy-to-console-admin"
  delete_mapper_if_exists "$target_client_uuid" "$mapper_name"

  log "Creating protocol mapper '$mapper_name'"
  kcadm create "clients/$target_client_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" -f - <<EOF >/dev/null
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

ensure_audience_mapper() {
  target_client_uuid="$1"
  mapper_name="$2"
  included_audience="$3"

  if [ -z "$target_client_uuid" ]; then
    log "Unable to resolve client for audience mapper '$mapper_name'"
    exit 1
  fi

  delete_mapper_if_exists "$target_client_uuid" "$mapper_name"

  log "Creating audience mapper '$mapper_name'"
  kcadm create "clients/$target_client_uuid/protocol-mappers/models" -r "$KEYCLOAK_REALM" -f - <<EOF >/dev/null
{
  "name": "$mapper_name",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "consentRequired": false,
  "config": {
    "included.client.audience": "$included_audience",
    "id.token.claim": "false",
    "access.token.claim": "true",
    "introspection.token.claim": "true"
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
    --rolename producer --rolename consumer --rolename admin --rolename "$INGESTION_SYSTEM_ROLE" --rolename "$CONTRACTS_READER_ROLE" >/dev/null 2>&1 || true

  for role_name in "$@"; do
    kcadm add-roles -r "$KEYCLOAK_REALM" --uusername "$username" --cclientid "$SYSTEM_ROLES_CLIENT_ID" \
      --rolename "$role_name" >/dev/null
  done
}

sync_user_realm_roles() {
  username="$1"
  shift

  kcadm remove-roles -r "$KEYCLOAK_REALM" --uusername "$username" \
    --rolename Viewer --rolename User --rolename Op --rolename Admin --rolename SuperAdmin >/dev/null 2>&1 || true

  for role_name in "$@"; do
    kcadm add-roles -r "$KEYCLOAK_REALM" --uusername "$username" \
      --rolename "$role_name" >/dev/null
  done
}

service_account_user_id() {
  client_uuid="$1"
  kcadm get "clients/$client_uuid/service-account-user" -r "$KEYCLOAK_REALM" |
    sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

sync_service_account_system_roles() {
  target_client_id="$1"
  shift

  target_client_uuid="$(client_uuid_by_client_id "$target_client_id")"
  if [ -z "$target_client_uuid" ]; then
    log "Unable to resolve service client '$target_client_id' for role sync"
    exit 1
  fi

  service_user_id="$(service_account_user_id "$target_client_uuid")"
  if [ -z "$service_user_id" ]; then
    log "Unable to resolve service account user for '$target_client_id'"
    exit 1
  fi

  kcadm remove-roles -r "$KEYCLOAK_REALM" --uid "$service_user_id" --cclientid "$SYSTEM_ROLES_CLIENT_ID" \
    --rolename producer --rolename consumer --rolename admin --rolename "$INGESTION_SYSTEM_ROLE" --rolename "$CONTRACTS_READER_ROLE" >/dev/null 2>&1 || true

  for role_name in "$@"; do
    kcadm add-roles -r "$KEYCLOAK_REALM" --uid "$service_user_id" --cclientid "$SYSTEM_ROLES_CLIENT_ID" \
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
  ensure_service_client "$AIRFLOW_STS_CLIENT_ID" "$AIRFLOW_STS_CLIENT_SECRET"
  ensure_airflow_auth_client "$AIRFLOW_AUTH_CLIENT_ID" "$AIRFLOW_AUTH_CLIENT_SECRET" "$AIRFLOW_AUTH_ROOT_URL"
  ensure_resource_client "$CONTRACTS_API_CLIENT_ID"
  ensure_direct_grants_client "$CONTRACTS_CLIENT_ID" "$CONTRACTS_CLIENT_SECRET"
  ensure_public_browser_client \
    "$CONTRACTS_UI_DEV_CLIENT_ID" \
    "$CONTRACTS_UI_DEV_ROOT_URL" \
    "$CONTRACTS_UI_DEV_REDIRECT_URI"
  ensure_service_client "$AIRFLOW_CONTRACTS_CLIENT_ID" "$AIRFLOW_CONTRACTS_CLIENT_SECRET"

  system_roles_client_uuid="$(client_uuid_by_client_id "$SYSTEM_ROLES_CLIENT_ID")"
  minio_client_uuid="$(client_uuid_by_client_id "$MINIO_CLIENT_ID")"
  airflow_sts_client_uuid="$(client_uuid_by_client_id "$AIRFLOW_STS_CLIENT_ID")"
  airflow_auth_client_uuid="$(client_uuid_by_client_id "$AIRFLOW_AUTH_CLIENT_ID")"
  contracts_client_uuid="$(client_uuid_by_client_id "$CONTRACTS_CLIENT_ID")"
  contracts_ui_dev_client_uuid="$(client_uuid_by_client_id "$CONTRACTS_UI_DEV_CLIENT_ID")"
  airflow_contracts_client_uuid="$(client_uuid_by_client_id "$AIRFLOW_CONTRACTS_CLIENT_ID")"
  ensure_client_role "$system_roles_client_uuid" "producer"
  ensure_client_role "$system_roles_client_uuid" "consumer"
  ensure_client_role "$system_roles_client_uuid" "admin"
  ensure_client_role "$system_roles_client_uuid" "$INGESTION_SYSTEM_ROLE"
  ensure_client_role "$system_roles_client_uuid" "$CONTRACTS_READER_ROLE"
  ensure_realm_role "Viewer"
  ensure_realm_role "User"
  ensure_realm_role "Op"
  ensure_realm_role "Admin"
  ensure_realm_role "SuperAdmin"
  ensure_system_roles_mapper "$minio_client_uuid" "system-roles-claim"
  ensure_system_roles_mapper "$airflow_sts_client_uuid" "system-roles-claim"
  ensure_system_roles_mapper "$contracts_client_uuid" "system-roles-claim"
  ensure_system_roles_mapper "$contracts_ui_dev_client_uuid" "system-roles-claim"
  ensure_system_roles_mapper "$airflow_contracts_client_uuid" "system-roles-claim"
  ensure_audience_mapper "$airflow_auth_client_uuid" "airflow-auth-audience" "$AIRFLOW_AUTH_CLIENT_ID"
  ensure_audience_mapper "$airflow_sts_client_uuid" "minio-console-audience" "$MINIO_CLIENT_ID"
  ensure_audience_mapper "$contracts_client_uuid" "contracts-api-audience" "$CONTRACTS_API_CLIENT_ID"
  ensure_audience_mapper "$contracts_ui_dev_client_uuid" "contracts-api-audience" "$CONTRACTS_API_CLIENT_ID"
  ensure_audience_mapper "$airflow_contracts_client_uuid" "contracts-api-audience" "$CONTRACTS_API_CLIENT_ID"

  ensure_user "admin" "admin" "Platform" "Admin" "admin@local.test"
  sync_user_system_roles "admin" "admin"
  sync_user_realm_roles "admin" "SuperAdmin"

  ensure_user "consumer" "consumer" "Data" "Consumer" "consumer@local.test"
  sync_user_system_roles "consumer" "consumer"
  sync_user_realm_roles "consumer" "User" "Op"

  ensure_user "producer" "producer" "Data" "Producer" "producer@local.test"
  sync_user_system_roles "producer" "producer"
  sync_user_realm_roles "producer" "User"

  ensure_user "$MINIO_TEST_USERNAME" "$MINIO_TEST_PASSWORD" "Multi" "Role User" "${MINIO_TEST_USERNAME}@local.test"
  sync_user_system_roles "$MINIO_TEST_USERNAME" "producer" "consumer"
  sync_user_realm_roles "$MINIO_TEST_USERNAME" "User"
  sync_service_account_system_roles "$AIRFLOW_STS_CLIENT_ID" "$INGESTION_SYSTEM_ROLE"
  sync_service_account_system_roles "$AIRFLOW_CONTRACTS_CLIENT_ID" "$CONTRACTS_READER_ROLE"

  log "Keycloak bootstrap completed"
}

main "$@"
