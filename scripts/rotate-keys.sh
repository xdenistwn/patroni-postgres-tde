#!/bin/bash
# Script to rotate the pg_tde Master Key using HashiCorp Vault
set -e

# Configuration
DB_NAME="postgres"
DB_USER=${PATRONI_PG_SUPERUSER:-"postgres"}
export PGPASSWORD=${PATRONI_PG_PASSWORD:-"postgres_password_secure"}

VAULT_PROVIDER_NAME="vault-provider"
NEW_KEY_NAME="master-key-$(date +%s)"

# Define multiple Patroni endpoints for resilience
PATRONI_ENDPOINTS=(
  "http://localhost:8008"
  "http://localhost:8009"
)

echo "Waiting for Patroni cluster to have a leader..."
while true; do
  LEADER=""
  
  # Try each endpoint until we find the leader
  for ENDPOINT in "${PATRONI_ENDPOINTS[@]}"; do
    echo "Checking leader status at $ENDPOINT..."
    LEADER_INFO=$(curl -s --connect-timeout 2 --max-time 5 "$ENDPOINT/cluster" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$LEADER_INFO" ]; then
      echo "Leader info: $LEADER_INFO"
      LEADER=$(echo "$LEADER_INFO" | jq -r '.members[]? | select(.role=="leader") | .name' 2>/dev/null)
      if [ -n "$LEADER" ] && [ "$LEADER" != "null" ]; then
        echo "Found leader: $LEADER (via $ENDPOINT)"
        break 2  # Break out of both loops
      fi
    fi
  done
  
  if [ -z "$LEADER" ] || [ "$LEADER" == "null" ]; then
    echo "Waiting for leader... (tried ${#PATRONI_ENDPOINTS[@]} endpoints)"
    sleep 2
  fi
done

echo "Starting Key Rotation on leader: $LEADER"
echo "New Key Name: $NEW_KEY_NAME"
echo ""

# Safety checks before rotation
echo "=========================================="
echo "  Pre-Rotation Safety Checks"
echo "=========================================="

# Check 1: Verify no pg_tde_basebackup is running
echo "Checking for running basebackup processes..."
BASEBACKUP_RUNNING=$(docker exec "$LEADER" ps aux | grep pg_tde_basebackup | grep -v grep || echo "")
if [ -n "$BASEBACKUP_RUNNING" ]; then
  echo "ERROR: pg_tde_basebackup is currently running!"
  echo "Details: $BASEBACKUP_RUNNING"
  echo ""
  echo "REASON: Key rotation during basebackup can cause:"
  echo "  - Replica startup failures during WAL replay"
  echo "  - Corruption of encrypted data"
  echo ""
  echo "Please wait for the basebackup to complete before rotating keys."
  exit 1
fi
echo "No basebackup processes running"

# Check 2: Verify no replicas are being created
echo "Checking cluster state for replica creation..."
for ENDPOINT in "${PATRONI_ENDPOINTS[@]}"; do
  CLUSTER_STATE=$(curl -s --connect-timeout 2 --max-time 5 "$ENDPOINT/cluster" 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$CLUSTER_STATE" ]; then
    CREATING_REPLICA=$(echo "$CLUSTER_STATE" | jq -r '.members[] | select(.state=="creating replica") | .name' 2>/dev/null || echo "")
    if [ -n "$CREATING_REPLICA" ]; then
      echo "ERROR: Replica '$CREATING_REPLICA' is being created!"
      echo ""
      echo "REASON: Key rotation during replica creation can cause:"
      echo "  - Inconsistent encryption keys between base data and WAL"
      echo "  - Replica startup failures"
      echo ""
      echo "Please wait for replica creation to complete."
      exit 1
    fi
    
    echo "No replicas being created"
    break
  fi
done

# Check 3: Verify all members are in running state
echo "Verifying all cluster members are healthy..."
for ENDPOINT in "${PATRONI_ENDPOINTS[@]}"; do
  CLUSTER_STATE=$(curl -s --connect-timeout 2 --max-time 5 "$ENDPOINT/cluster" 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$CLUSTER_STATE" ]; then
    UNHEALTHY=$(echo "$CLUSTER_STATE" | jq -r '.members[] | select(.state!="running") | "\(.name): \(.state)"' 2>/dev/null || echo "")
    if [ -n "$UNHEALTHY" ]; then
      echo "WARNING: Some cluster members are not in 'running' state:"
      echo "$UNHEALTHY"
      echo ""
      read -p "Continue anyway? (yes/no): " CONTINUE
      if [ "$CONTINUE" != "yes" ]; then
        echo "Key rotation cancelled."
        exit 1
      fi
    else
      echo "All cluster members are healthy"
    fi
    break
  fi
done

echo "=========================================="
echo "  All Safety Checks Passed"
echo "=========================================="
echo ""

# 1. Create the new key in Vault via pg_tde
echo "Creating new key in Vault..."
docker exec -i "$LEADER" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_tde_create_key_using_global_key_provider('$NEW_KEY_NAME', '$VAULT_PROVIDER_NAME');"

# 2. Set the new key as the default (this triggers the rotation)
echo "Setting $NEW_KEY_NAME as the new default principal key..."
docker exec -i "$LEADER" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_tde_set_default_key_using_global_key_provider('$NEW_KEY_NAME', '$VAULT_PROVIDER_NAME');"

echo "----------------------------------------------------------"
echo "SUCCESS: Master Key rotated to $NEW_KEY_NAME"
echo "All replicas will automatically sync the new key via WAL."
echo "----------------------------------------------------------"
