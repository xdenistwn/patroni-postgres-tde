#!/bin/bash
set -e

# This script helps initialize the pgBackRest stanza.
# It should be run after the cluster is up and running.

STANZA_NAME="postgres-patroni-tde"

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

echo "Current primary node: $LEADER"
echo "Creating stanza '$STANZA_NAME' on $LEADER..."
docker exec -t $LEADER pgbackrest --stanza=$STANZA_NAME stanza-create

echo "Checking stanza status..."
docker exec -t $LEADER pgbackrest --stanza=$STANZA_NAME check

echo "pgBackRest stanza initialized successfully on $LEADER!"
