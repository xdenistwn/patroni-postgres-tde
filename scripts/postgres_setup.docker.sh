#!/bin/sh
set -e

# --- Required: Postgres superuser credentials (interactive) ---
while [ -z "$DB_USER" ]; do
  printf "Postgres username (required): "
  read -r DB_USER
done

while [ -z "$PGPASSWORD" ]; do
  printf "Postgres password (required): "
  read -rs PGPASSWORD
  printf "\n"
done
export PGPASSWORD

while [ -z "$VAULT_PROVIDER_NAME" ]; do
  printf "Vault provider name (required): "
  read -r VAULT_PROVIDER_NAME
done

while [ -z "$VAULT_MOUNT_PATH" ]; do
  printf "Vault mount path (required): "
  read -r VAULT_MOUNT_PATH
done

# --- Optional: connection settings (press Enter to use defaults) ---
printf "Database name   [postgres]: "
read -r _DB_NAME_INPUT
DB_NAME=${_DB_NAME_INPUT:-"postgres"}

printf "Host / Container Name            [postgres-one]: "
read -r _HOST_INPUT
TARGET_HOST=${_HOST_INPUT:-"postgres-one"}

printf "Port            [5432]: "
read -r _PORT_INPUT
DB_PORT=${_PORT_INPUT:-"5432"}

# App Users from Environment (passed via docker compose)
APP_DBA_USER=${DB_USER_NAME}
APP_DBA_PASS=${DB_USER_PASSWORD}
APP_DEV_USER=${DB_DEV_USER_NAME}
APP_DEV_PASS=${DB_DEV_USER_PASSWORD}

VAULT_ADDR=${VAULT_ADDR:-"http://vault:8200"}
MASTER_KEY_NAME="global-master-key-one"
TOKEN_FILE_PATH="/etc/postgresql/secrets/vault_token.txt"

# --- Pre-flight: verify Postgres is reachable on the target host ---
echo "Checking Postgres is reachable on $TARGET_HOST:$DB_PORT..."
if ! docker exec -e PGPASSWORD="$PGPASSWORD" ${TARGET_HOST} psql -h "$TARGET_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" > /dev/null 2>&1; then
  echo "Cannot connect to Postgres at $TARGET_HOST:$DB_PORT. Is the server running?"
  exit 1
fi
echo "Connected to $TARGET_HOST. Initializing cluster-wide setup..."

# Function to run SQL
run_sql() {
  docker exec -e PGPASSWORD="$PGPASSWORD" ${TARGET_HOST} psql -h "$TARGET_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "$1"
}

# --- 1. Encryption TDE SETUP ---
echo "--- Setting up PG_TDE ---"
echo "Creating extension pg_tde..."
run_sql "CREATE EXTENSION IF NOT EXISTS pg_tde;"

echo "Checking for existing provider..."
PROVIDER_EXISTS=$(run_sql "SELECT 1 FROM pg_tde_list_all_global_key_providers() WHERE name = '$VAULT_PROVIDER_NAME';" | tr -d '[:space:]')

if [ "$PROVIDER_EXISTS" != "1" ]; then
  echo "Adding Global Vault key provider (v2)..."
  run_sql "SELECT pg_tde_add_global_key_provider_vault_v2('$VAULT_PROVIDER_NAME', '$VAULT_ADDR', '$VAULT_MOUNT_PATH', '$TOKEN_FILE_PATH', '');"
else
  echo "Key provider '$VAULT_PROVIDER_NAME' already exists."
fi

echo "Checking for existing server principal key..."
PRINCIPAL_VARS=$(run_sql "SELECT key_name FROM pg_tde_server_key_info() WHERE key_name IS NOT NULL;" | tr -d '[:space:]')

if [ -z "$PRINCIPAL_VARS" ]; then
  echo "Creating principal key '$MASTER_KEY_NAME'..."
  run_sql "SELECT pg_tde_create_key_using_global_key_provider('$MASTER_KEY_NAME', '$VAULT_PROVIDER_NAME');"

  echo "Setting default principal key to '$MASTER_KEY_NAME'..."
  run_sql "SELECT pg_tde_set_default_key_using_global_key_provider('$MASTER_KEY_NAME', '$VAULT_PROVIDER_NAME');"
else
  echo "Default principal key is already configured."
fi

echo "Cluster initialization complete on $TARGET_HOST."

# --- 2. Setup pg_partman ---
echo "--- Setting up pg_partman ---"
echo "Creating extension pg_partman..."
run_sql "CREATE SCHEMA IF NOT EXISTS partman;" 
run_sql "CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;"

# -- 3. Setup pg_repack
echo "--- Setting up pg_repack ---"
echo "Creating extension pg_repack..."
run_sql "CREATE EXTENSION IF NOT EXISTS pg_repack; CREATE EXTENSION IF NOT EXISTS pgstattuple;"

# -- 4. Setup pg_stat_monitor
echo "--- Setting up pg_stat_monitor ---"
echo "Creating extension pg_stat_monitor..."
run_sql "CREATE EXTENSION IF NOT EXISTS pg_stat_monitor;"

# -- 5. Setup pg_cron
echo "--- Setting up pg_cron ---"
echo "Creating extension pg_cron..."
run_sql "CREATE EXTENSION IF NOT EXISTS pg_cron;"

# -- 6. Setup pg_audit
echo "--- Setting up pg_audit ---"
echo "Creating extension pg_audit..."
run_sql "CREATE EXTENSION IF NOT EXISTS pgaudit;"

