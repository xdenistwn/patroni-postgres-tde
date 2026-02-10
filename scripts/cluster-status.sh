#!/bin/bash
# Script to display Patroni cluster status from multiple nodes
set -e

# Define Patroni endpoints
PATRONI_ENDPOINTS=(
  "postgres-one:8008"
  "postgres-two:8008"
)

echo "=========================================="
echo "  Patroni Cluster Status"
echo "=========================================="
echo ""

# Try to get cluster info from any available endpoint
CLUSTER_INFO=""
SUCCESSFUL_ENDPOINT=""

for ENDPOINT in "${PATRONI_ENDPOINTS[@]}"; do
  echo "Trying endpoint: $ENDPOINT..."
  CLUSTER_INFO=$(docker exec postgres-one curl -s "http://$ENDPOINT/cluster" 2>/dev/null || echo "")
  
  if [ -n "$CLUSTER_INFO" ] && [ "$CLUSTER_INFO" != "null" ]; then
    SUCCESSFUL_ENDPOINT="$ENDPOINT"
    echo "✓ Successfully connected to $ENDPOINT"
    echo ""
    break
  else
    echo "✗ Failed to connect to $ENDPOINT"
  fi
done

if [ -z "$CLUSTER_INFO" ]; then
  echo ""
  echo "ERROR: Could not connect to any Patroni endpoint!"
  echo "Make sure the cluster is running."
  exit 1
fi

# Display cluster information
echo "Cluster Information (from $SUCCESSFUL_ENDPOINT):"
echo "------------------------------------------"
echo "$CLUSTER_INFO" | jq -r '
  "Scope: \(.scope // "N/A")",
  "",
  "Members:"
' 2>/dev/null

# Display member details in a formatted table
echo "$CLUSTER_INFO" | jq -r '
  .members[] | 
  "  • \(.name)",
  "    Role:       \(.role)",
  "    State:      \(.state)",
  "    Host:       \(.host):\(.port)",
  "    Timeline:   \(.timeline // "N/A")",
  "    Lag in MB:  \(.lag // 0)",
  ""
' 2>/dev/null

# Highlight the leader
LEADER=$(echo "$CLUSTER_INFO" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null)
if [ -n "$LEADER" ]; then
  echo "------------------------------------------"
  echo "Current Leader: $LEADER"
  echo "------------------------------------------"
fi

echo ""
echo "To get more details, run:"
echo "  docker exec postgres-one patronictl -c /etc/patroni/patroni.yml list"
echo "  docker exec postgres-two patronictl -c /etc/patroni/patroni.yml list"
