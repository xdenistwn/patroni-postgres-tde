#!/bin/bash
set -e

echo "Stopping containers..."
docker-compose down
sleep 5

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

echo "--------------------------"
echo "Cleanup complete!"