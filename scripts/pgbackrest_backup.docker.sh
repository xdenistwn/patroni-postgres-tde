#!/bin/bash
# =============================================================================
# pgbackrest-backup.sh
# Runs a pgBackRest backup on the current Patroni primary.
# Usage: ./pgbackrest-backup.sh [full|diff|incr]  (default: full)
# =============================================================================
set -e

STANZA="postgres-patroni-tde"
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
echo "$(date): Starting pgBackRest ${BACKUP_TYPE} backup on stanza ${STANZA}..."

# Run backup
docker exec -t $LEADER \
  pgbackrest --stanza="${STANZA}" \
             --type="${BACKUP_TYPE}" \
             backup

if [ $? -eq 0 ]; then
  echo "$(date): Backup completed successfully on $LEADER"

  # Show backup info
  docker exec -t $LEADER \
    pgbackrest --stanza="${STANZA}" \
               info
else
  echo "$(date): Backup failed!"
  exit 1
fi
