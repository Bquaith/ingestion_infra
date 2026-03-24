#!/usr/bin/env bash
set -euo pipefail

readonly PGHOST="${PGHOST:-postgres}"
readonly PGPORT="${PGPORT:-5432}"
readonly PGUSER="${PGUSER:-postgres}"
readonly PGDATABASE="${PGDATABASE:-postgres}"

databases=(
  keycloak
  test_data_set
  data_contracts
  data_lake
  dag_audit
)

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

  echo "Database '$db_name' is ready"
done
