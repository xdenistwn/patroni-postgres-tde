#!/bin/bash
set -e

# Copy and rename vault token
yes | cp storage/vault/secrets/token.example.txt storage/vault/secrets/vault_token.txt

echo "Starting Postgres Patroni cluster with HashiCorp Vault..."
docker-compose up -d

echo "Waiting for services to be healthy..."
# Simple wait for simplicity, healthchecks in docker-compose are better
sleep 15

echo "Setup complete!"
echo "You can now test encryption by creating a table with TDE."
echo "Example: CREATE TABLE secret_data (id serial, data text) WITH (autotransaction_tde = on);"
echo "To rotate keys, run: ./scripts/rotate-keys.sh"
