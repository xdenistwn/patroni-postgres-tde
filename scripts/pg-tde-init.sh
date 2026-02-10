#!/bin/sh
set -e

# Configuration
DB_NAME=${PATRONI_PG_SUPERUSER:-"postgres"}
DB_USER=${PATRONI_PG_SUPERUSER:-"postgres"}
export PGPASSWORD=${PATRONI_PG_PASSWORD:-"postgres_password_secure"}

# App Users from Environment (passed via docker-compose)
APP_DBA_USER=${DB_USER_NAME:-"snowball"}
APP_DBA_PASS=${DB_USER_PASSWORD:-"snowball_password_secure"}
APP_DEV_USER=${DB_DEV_USER_NAME:-"snowball_dev"}
APP_DEV_PASS=${DB_DEV_USER_PASSWORD:-"snowball_dev_password_secure"}

VAULT_PROVIDER_NAME="vault-provider"
VAULT_ADDR=${VAULT_ADDR:-"http://vault:8200"}
VAULT_MOUNT_PATH=${VAULT_MOUNT_PATH:-"tde"}
MASTER_KEY_NAME="global-master-key"

echo "Waiting for Patroni cluster to have a leader..."
while true; do
  LEADER_INFO=$(curl -s http://postgres-one:8008/cluster)
  if [ $? -eq 0 ] && [ -n "$LEADER_INFO" ]; then
  LEADER=$(echo "$LEADER_INFO" | jq -r '.members[]? | select(.role=="leader") | .name' 2>/dev/null)
  if [ -n "$LEADER" ] && [ "$LEADER" != "null" ]; then
  echo "Found leader: $LEADER"
  break
  fi
  fi
  echo "Waiting for leader..."
  sleep 2
done

TARGET_HOST="$LEADER"
echo "Using leader host: $TARGET_HOST. Initializing cluster-wide setup..."

TOKEN_FILE_PATH="/etc/postgresql/secrets/vault_token.txt"

# Function to run SQL
run_sql() {
  psql -h "$TARGET_HOST" -U "$DB_USER" -d "$DB_NAME" -t -c "$1"
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

# --- 2. WAL ENCRYPTION SETUP ---
echo "Enabling WAL encryption..."
run_sql "ALTER SYSTEM SET pg_tde.wal_encrypt = on;"
run_sql "SELECT pg_reload_conf();"

echo "Cluster initialization complete on $LEADER."
