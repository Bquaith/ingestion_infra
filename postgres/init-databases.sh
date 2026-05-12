#!/usr/bin/env bash
set -euo pipefail

readonly PGHOST="${PGHOST:-postgres}"
readonly PGPORT="${PGPORT:-5432}"
readonly PGUSER="${PGUSER:-postgres}"
readonly PGDATABASE="${PGDATABASE:-postgres}"
readonly POSTGRES_DATABASES="${POSTGRES_DATABASES:-keycloak test_data_set data_contracts data_lake dag_audit}"

normalized_databases="$(printf '%s\n' "${POSTGRES_DATABASES}" | tr ',' ' ')"
read -r -a databases <<< "${normalized_databases}"

for db_name in "${databases[@]}"; do
  psql \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --dbname="$PGDATABASE" \
    --set=db_name="$db_name" \
    --set=ON_ERROR_STOP=1 <<'SQL'
SELECT format('CREATE DATABASE %I', :'db_name')
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_database
  WHERE datname = :'db_name'
);
\gexec
SQL

  psql \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$PGUSER" \
    --dbname="$db_name" \
    --set=ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL

  echo "Database '$db_name' is ready"
done
