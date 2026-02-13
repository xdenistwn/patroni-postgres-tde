#!/bin/bash
set -e

# This script helps initialize the pgBackRest stanza.
# It should be run after the cluster is up and running.

SERVICE_NAME="postgres-one"
STANZA_NAME="patroni-tde"

echo "Checking if $SERVICE_NAME is running..."
if [ -z "$(docker-compose ps -q $SERVICE_NAME)" ]; then
  echo "Error: Service $SERVICE_NAME is not running. Please start the cluster first."
  exit 1
fi

echo "Creating stanza '$STANZA_NAME' on $SERVICE_NAME..."
docker-compose exec -u postgres $SERVICE_NAME pgbackrest --stanza=$STANZA_NAME stanza-create

echo "Checking stanza status..."
docker-compose exec -u postgres $SERVICE_NAME pgbackrest --stanza=$STANZA_NAME check

echo "pgBackRest stanza initialized successfully!"
