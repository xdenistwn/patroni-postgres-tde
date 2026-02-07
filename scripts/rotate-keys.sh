#!/bin/bash
set -e

# Configuration
DB_NAME=${DB_NAME:-"postgres"}
DB_USER=${DB_USER:-"postgres"}
PGPASSWORD=${PATRONI_SUPERUSER_PASSWORD:-"postgres_password_secure"}
export PGPASSWORD

VAULT_PROVIDER_NAME="vault_provider"
NEW_KEY_NAME="master-key-$(date +%s)"

echo "Finding Patroni leader..."
LEADER=$(docker exec postgres-one patronictl -c /etc/patroni/patroni.yml list -f json | jq -r '.[] | select(.Role=="Leader") | .Member')

if [ -z "$LEADER" ]; then
  echo "No leader found."
  exit 1
fi

echo "Rotating key to $NEW_KEY_NAME on leader $LEADER..."

# Running rotation SQL
docker exec -i "$LEADER" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_tde_rotate_key('$NEW_KEY_NAME', '$VAULT_PROVIDER_NAME');"

echo "Full cluster key rotation initiated. Replicas will follow the rotation through WAL."
