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