#!/bin/sh
set -e

# These variables should be set via environment or .env
export VAULT_ADDR=${VAULT_ADDR:-"http://vault:8200"}
export VAULT_TOKEN=${VAULT_TOKEN:-$VAULT_ROOT_DEV_TOKEN}
TOKEN_FILE="/vault/secrets/vault_token.txt"

echo "Waiting for Vault at $VAULT_ADDR..."
until vault status > /dev/null 2>&1; do
  echo "Still waiting for Vault..."
  sleep 2
done

echo "Vault is up. Checking existing configuration..."

# Idempotency check: Is there already a valid token?
if [ -f "$TOKEN_FILE" ]; then
  EXISTING_TOKEN=$(cat "$TOKEN_FILE")
  echo "Found existing token, checking validity..."
  if VAULT_TOKEN=$EXISTING_TOKEN vault token lookup > /dev/null 2>&1; then
    echo "Existing token is still valid. Checking if policy and auth also exist..."
    
    # Even if the token is valid, we might have lost the dev-mode data in a container restart 
    # (if Vault Dev mode restarted but the volume persisted an old token from a previous run).
    # But usually, if vault token lookup works, it means Vault state is alive.
    
    # Verify if the TDE engine is actually there
    if vault secrets list | grep -q "^tde/"; then
      echo "Vault is already initialized and token is valid. Skipping initialization."
      exit 0
    fi
    echo "Token valid but TDE engine missing (likely Vault restart). Re-initializing..."
  else
    echo "Existing token is invalid or expired. Re-initializing..."
  fi
fi

# 1. Enable the kv v2 secret engine
if ! vault secrets list | grep -q "^tde/"; then
  echo "Enabling KV v2 secret engine at tde..."
  vault secrets enable -path=tde -version=2 kv
else
  echo "KV v2 secret engine 'tde' already enabled."
fi

# 2. Create a Vault policy for pg_tde
echo "Writing tde-policy..."
vault policy write tde-policy - <<EOF
path "tde/data/*" {
  capabilities = ["read", "create", "update", "list"]
}

path "tde/metadata/*" {
  capabilities = ["read", "list"]
}

path "sys/mounts/*" {
  capabilities = ["read"]
}
EOF

# 3. Enable the AppRole authentication method
if ! vault auth list | grep -q "^approle/"; then
  echo "Enabling AppRole auth method..."
  vault auth enable approle
else
  echo "AppRole auth method already enabled."
fi

echo "Creating tde-role..."
vault write auth/approle/role/tde-role policies="tde-policy"

# 4. Generate a token with tde-policy
echo "Generating TDE token..."
TDE_TOKEN=$(vault token create -policy="tde-policy" -field=token)

# 5. Show and save the vault token
echo "---------------------------------------------------"
echo "NEW VAULT_TDE_TOKEN: $TDE_TOKEN"
echo "---------------------------------------------------"

if [ -d "/vault/secrets" ]; then
  echo "$TDE_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "Token saved to $TOKEN_FILE"
fi

echo "Vault initialization complete."
