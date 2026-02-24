#!/bin/bash
# =============================================================================
# pgbackrest-backup.sh
# Runs a pgBackRest backup on the current Patroni primary.
# Cipher-pass is resolved at runtime via the envelope key helper.
# Usage: ./pgbackrest-backup.sh [full|diff|incr]  (default: full)
# =============================================================================
set -e

STANZA="patroni-tde"
BACKUP_TYPE="${1:-full}"  # full, diff, or incr

# Define multiple Patroni endpoints for resilience
PATRONI_ENDPOINTS=(
  "http://localhost:8008"
  "http://localhost:8009"
)

echo "$(date): Waiting for Patroni cluster to have a leader..."
while true; do
  LEADER=""

  # Try each endpoint until we find the leader
  for ENDPOINT in "${PATRONI_ENDPOINTS[@]}"; do
    LEADER_INFO=$(curl -s --connect-timeout 2 --max-time 5 "$ENDPOINT/cluster" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$LEADER_INFO" ]; then
      LEADER=$(echo "$LEADER_INFO" | jq -r '.members[]? | select(.role=="leader") | .name' 2>/dev/null)
      if [ -n "$LEADER" ] && [ "$LEADER" != "null" ]; then
        echo "$(date): Found leader: $LEADER (via $ENDPOINT)"
        break 2
      fi
    fi
  done

  echo "$(date): Waiting for leader... (tried ${#PATRONI_ENDPOINTS[@]} endpoints)"
  sleep 2
done

echo "$(date): Current primary node: $LEADER"
echo "$(date): Resolving pgBackRest cipher-pass via envelope key..."

# Resolve cipher-pass at runtime from the encrypted DEK on the leader container
CIPHER_PASS=$(docker-compose exec -T -u postgres "$LEADER" \
  /usr/local/bin/pgbackrest-get-cipher-pass.sh 2>/dev/null)

if [ -z "$CIPHER_PASS" ]; then
  echo "$(date): ERROR: Could not resolve cipher-pass. Check Vault connectivity and DEK file."
  exit 1
fi

echo "$(date): Cipher-pass resolved. Starting pgBackRest ${BACKUP_TYPE} backup on stanza ${STANZA}..."

# Run backup, passing the cipher-pass at runtime (never stored in env or config)
docker-compose exec -T -u postgres "$LEADER" \
  pgbackrest --stanza="${STANZA}" \
             --type="${BACKUP_TYPE}" \
             --cipher-type=aes-256-cbc \
             --cipher-pass="${CIPHER_PASS}" \
             backup

if [ $? -eq 0 ]; then
  echo "$(date): Backup completed successfully on $LEADER"

  # Show backup info (cipher-pass needed for info as well)
  docker-compose exec -T -u postgres "$LEADER" \
    pgbackrest --stanza="${STANZA}" \
               --cipher-type=aes-256-cbc \
               --cipher-pass="${CIPHER_PASS}" \
               info
else
  echo "$(date): Backup failed!"
  exit 1
fi
