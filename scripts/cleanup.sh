#!/bin/bash
set -e

echo "Stopping containers..."
docker-compose down --remove-orphans
sleep 10

# Get the list of volumes
VOLUMES=$(docker volume ls -q | grep patroni || true)

if [ -z "$VOLUMES" ]; then
  echo "No Patroni volumes found to remove."
  exit 0
fi

echo "Starting volume cleanup..."
echo "--------------------------"

# Loop through each volume to show progress
for VOL in $VOLUMES; do
  echo -n "Removing $VOL... "
  docker volume rm "$VOL" > /dev/null
  echo "Done."
done

echo "Removing vault_token.txt..."
echo "--------------------------"
rm storage/vault/secrets/vault_token.txt

echo "--------------------------"
echo "Cleanup complete!"