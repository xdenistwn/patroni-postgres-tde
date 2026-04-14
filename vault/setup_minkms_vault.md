# Vault Setup for MinKMS (Transit + KV for AIStor API Key)

This doc covers two separate Vault integrations:
1. **Transit engine** — used by MinKMS itself to seal/unseal its root key (already done).
2. **KV engine** — used to store the MinIO AIStor scoped API key, so it's never hardcoded in `.env`.

---

## Part 1: Transit Engine (MinKMS Root Key Sealing)

> Already configured if MinKMS is running. Kept here for reference.

```bash
# Go inside the vault container
docker exec -it vault sh

export VAULT_TOKEN=<root_token_from_vault-json.local.json>
export VAULT_SKIP_VERIFY=true   # local/R&D only

# Enable transit engine
vault secrets enable transit

# Create sealing key for MinKMS
vault write -f transit/keys/minkms-sealing-key

# Write policy for MinKMS AppRole
vault policy write minkms-policy - <<EOF
path "transit/encrypt/minkms-sealing-key"  { capabilities = ["create", "update"] }
path "transit/decrypt/minkms-sealing-key"  { capabilities = ["create", "update"] }
path "transit/hmac/minkms-sealing-key"     { capabilities = ["create", "update"] }
path "transit/sign/minkms-sealing-key"     { capabilities = ["create", "update"] }
path "transit/verify/minkms-sealing-key"   { capabilities = ["create", "update"] }
path "transit/keys/minkms-sealing-key"     { capabilities = ["read", "create", "update"] }
EOF

# Enable AppRole auth (if not already enabled)
vault auth enable approle

# Create minkms-role
vault write auth/approle/role/minkms-role policies="minkms-policy"

# Generate Role ID + Secret ID → put into minkms/config.yaml
ROLE_ID=$(vault read -field=role_id auth/approle/role/minkms-role/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/minkms-role/secret-id)
echo "Role ID:    $ROLE_ID"
echo "Secret ID:  $SECRET_ID"
```

Put the output into `minio/minkms/config.local.yaml` under `hsm.hashicorp.vault.approle`.

---

## Part 2: KV Engine — Storing the MinIO AIStor API Key

This is how you move `MINIO_KMS_API_KEY` out of `.env` and into Vault.

### 2a. Enable KV v2 secrets engine (one-time)

```bash
# Inside vault container
vault secrets enable -path=secret kv-v2
```

### 2b. Write the scoped MinIO AIStor API key into Vault

After running `minkms add-identity` (no `--admin`) and getting the `k2:...` key:

```bash
vault kv put secret/minkms/aistor \
  api_key="k2:YOUR_SCOPED_API_KEY_HERE" \
  enclave="postgres-archive-demo" \
  sse_key="ggwp-key-1"
```

### 2c. Create a policy so only an authorized reader can fetch it

```bash
vault policy write minkms-aistor-reader - <<EOF
path "secret/data/minkms/aistor" {
  capabilities = ["read"]
}
EOF
```

### 2d. Create an AppRole for your deploy/init script

```bash
vault write auth/approle/role/minkms-aistor-reader \
  policies="minkms-aistor-reader" \
  secret_id_ttl="1h" \
  token_ttl="1h" \
  token_max_ttl="4h"

READER_ROLE_ID=$(vault read -field=role_id auth/approle/role/minkms-aistor-reader/role-id)
READER_SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/minkms-aistor-reader/secret-id)
echo "Reader Role ID:    $READER_ROLE_ID"
echo "Reader Secret ID:  $READER_SECRET_ID"
```

### 2e. Inject into Docker Compose at deploy time (init script)

Create a small shell script that fetches the secret and writes `.env` before `docker compose up`:

```bash
# scripts/inject-minkms-secret.sh
#!/bin/bash
set -e

VAULT_ADDR="http://vault:8200"
ROLE_ID="<reader_role_id>"
SECRET_ID="<reader_secret_id>"

# Authenticate and get a short-lived token
TOKEN=$(curl -s --request POST \
  --data "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" \
  $VAULT_ADDR/v1/auth/approle/login | jq -r '.auth.client_token')

# Fetch the scoped API key
API_KEY=$(curl -s --header "X-Vault-Token: $TOKEN" \
  $VAULT_ADDR/v1/secret/data/minkms/aistor | jq -r '.data.data.api_key')

# Write .env for minio aistor
cat > minio/aistor/.env <<EOF
MINIO_KMS_SERVER=https://minkms:7373
MINIO_KMS_API_KEY=${API_KEY}
MINIO_KMS_SSE_KEY=ggwp-key-1
MINIO_KMS_ENCLAVE=postgres-archive-demo
EOF

echo "Secrets injected into minio/aistor/.env"
```

Then in your startup flow:
```bash
bash scripts/inject-minkms-secret.sh
docker compose -f minio/aistor/docker-compose.yml up -d
```

---

## Identity Separation Summary

| Identity        | --admin | Stored In          | Used By                    |
|-----------------|---------|--------------------|----------------------------|
| Admin key       | ✅ Yes  | Vault KV (offline) | Operator CLI only          |
| AIStor app key  | ❌ No   | Vault KV secret    | MinIO AIStor container env |
