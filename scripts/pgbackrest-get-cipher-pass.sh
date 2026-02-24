#!/bin/bash
# =============================================================================
# pgbackrest-get-cipher-pass.sh
# Envelope Key Encryption - Runtime DEK resolver (No Cache Version)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/etc/postgresql/secrets/vault_token.txt}"
VAULT_KEK_PATH="${VAULT_KEK_PATH:-pgbackrest/kek}"
VAULT_SECRET_MOUNT="${VAULT_SECRET_MOUNT:-secret}"

DEK_FILE="${DEK_FILE:-/data/db/pgbackrest_dek.enc}"

# ---------------------------------------------------------------------------
# All logs go to stderr to not pollute stdout (which is used for the key)
# ---------------------------------------------------------------------------
die()  { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [get-cipher-pass] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Resolve DEK from Vault (Every time for maximum security)
# ---------------------------------------------------------------------------

# Load Vault token
VAULT_TOKEN="${VAULT_TOKEN:-}"
if [ -z "$VAULT_TOKEN" ] && [ -f "$VAULT_TOKEN_FILE" ]; then
  VAULT_TOKEN=$(cat "$VAULT_TOKEN_FILE" | tr -d '[:space:]')
fi
[ -z "$VAULT_TOKEN" ] && die "No VAULT_TOKEN found"

# Read encrypted DEK file
[ -f "$DEK_FILE" ] || die "DEK file not found: ${DEK_FILE}"
DEK_FILE_CONTENT=$(cat "$DEK_FILE" | tr -d '[:space:]')
IV=$(echo "$DEK_FILE_CONTENT" | cut -d: -f1)
ENC_B64=$(echo "$DEK_FILE_CONTENT" | cut -d: -f2)
HMAC_EXPECTED=$(echo "$DEK_FILE_CONTENT" | cut -d: -f3)

# Fetch KEK from Vault
KEK=$(curl -sf \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/${VAULT_SECRET_MOUNT}/data/${VAULT_KEK_PATH}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['data']['kek'], end='')" \
  2>/dev/null) || die "Failed to fetch KEK from Vault"

# Verify HMAC integrity before decryption
HMAC_ACTUAL=$(echo -n "${IV}${ENC_B64}" | openssl dgst -sha256 -hmac "$KEK" | awk '{print $2}')
if [ "$HMAC_ACTUAL" != "$HMAC_EXPECTED" ]; then
  die "HMAC verification FAILED. Encrypted DEK may be tampered."
fi

# Decrypt DEK and output to stdout
echo "$ENC_B64" | openssl enc -d -aes-256-cbc -K "$KEK" -iv "$IV" -a 2>/dev/null || die "Decryption failed"
