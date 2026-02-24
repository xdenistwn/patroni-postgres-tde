#!/bin/bash
# =============================================================================
# pgbackrest-keymgmt-init.sh
# Envelope Key Encryption - Initial Setup
#
# This script:
#   1. Generates a random DEK (Data Encryption Key)
#   2. Stores the KEK in Vault (transit engine or KV)
#   3. Encrypts the DEK using the KEK via Vault
#   4. Saves the encrypted DEK to /data/db/pgbackrest_dek.enc
#
# Run this once during cluster bootstrap, on the PRIMARY node only.
# Replicas will read the same encrypted DEK file from /data/db (shared PG data dir logic).
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/etc/postgresql/secrets/pgbackrest_vault_token.txt}"
VAULT_KEK_PATH="${VAULT_KEK_PATH:-pgbackrest/kek}"          # KV v2 path for KEK
VAULT_SECRET_MOUNT="${VAULT_SECRET_MOUNT:-secret}"           # KV v2 mount

DEK_FILE="${DEK_FILE:-/data/db/pgbackrest_dek.enc}"          # encrypted DEK location
DEK_META_FILE="${DEK_META_FILE:-/data/db/pgbackrest_dek.meta}" # metadata (version, timestamp)

LOG_PREFIX="[pgbackrest-keymgmt-init]"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $LOG_PREFIX $*"; }
die()  { log "ERROR: $*"; exit 1; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

vault_kv_put() {
  local path="$1"; shift
  curl -sf \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data "$1" \
    "${VAULT_ADDR}/v1/${VAULT_SECRET_MOUNT}/data/${path}" >/dev/null \
    || die "Failed to write to Vault path: ${VAULT_SECRET_MOUNT}/data/${path}"
}

vault_kv_get_field() {
  local path="$1"
  local field="$2"
  curl -sf \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/${VAULT_SECRET_MOUNT}/data/${path}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['data']['${field}'])" \
    || die "Failed to read field '${field}' from Vault path: ${VAULT_SECRET_MOUNT}/data/${path}"
}

vault_path_exists() {
  local path="$1"
  local http_code
  http_code=$(curl -o /dev/null -sw "%{http_code}" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/${VAULT_SECRET_MOUNT}/data/${path}")
  [ "$http_code" = "200" ]
}

ensure_kv_mount() {
  # Enable KV v2 at $VAULT_SECRET_MOUNT if not already enabled
  local status
  status=$(curl -o /dev/null -sw "%{http_code}" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/sys/mounts/${VAULT_SECRET_MOUNT}")
  if [ "$status" != "200" ]; then
    log "Enabling KV v2 mount at '${VAULT_SECRET_MOUNT}'..."
    curl -sf \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      -X POST \
      --data '{"type":"kv","options":{"version":"2"}}' \
      "${VAULT_ADDR}/v1/sys/mounts/${VAULT_SECRET_MOUNT}" >/dev/null \
      || die "Failed to enable KV mount '${VAULT_SECRET_MOUNT}'"
  else
    log "KV mount '${VAULT_SECRET_MOUNT}' already exists."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_cmd curl python3 openssl

# Load Vault token from file if not set as env var
if [ -z "$VAULT_TOKEN" ] && [ -f "${VAULT_TOKEN_FILE:-}" ]; then
  VAULT_TOKEN=$(cat "$VAULT_TOKEN_FILE" | tr -d '[:space:]')
fi

log "Starting pgBackRest envelope key initialization..."

[ -z "$VAULT_TOKEN" ] && die "VAULT_TOKEN is not set and ${VAULT_TOKEN_FILE} not found or empty."

# 1. Wait for Vault
log "Waiting for Vault at ${VAULT_ADDR}..."
until curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; do
  sleep 2
done
log "Vault is reachable."

# 2. Ensure KV v2 mount exists
ensure_kv_mount

# 3. Check if KEK already exists in Vault
if vault_path_exists "${VAULT_KEK_PATH}"; then
  log "KEK already exists at Vault path '${VAULT_SECRET_MOUNT}/data/${VAULT_KEK_PATH}'."
  log "If you want to rotate, run pgbackrest-keymgmt-rotate.sh instead."
  exit 0
fi

# 4. Check if DEK file already exists
if [ -f "$DEK_FILE" ]; then
  log "DEK file already exists at ${DEK_FILE}."
  log "If you want to rotate, run pgbackrest-keymgmt-rotate.sh instead."
  exit 0
fi

# 5. Generate KEK (256-bit AES key, stored in Vault)
log "Generating KEK (256-bit)..."
KEK_VALUE=$(openssl rand -hex 32)   # 32 bytes = 256 bits

# 6. Generate DEK (256-bit - this is the actual pgBackRest cipher-pass)
log "Generating DEK (256-bit)..."
DEK_PLAINTEXT=$(openssl rand -hex 32)  # 32 bytes = 256 bits

# 7. Encrypt DEK with KEK using AES-256-CBC + HMAC-SHA256 for integrity
log "Encrypting DEK with KEK..."
DEK_PLAIN_TMP=$(mktemp)
echo -n "$DEK_PLAINTEXT" > "$DEK_PLAIN_TMP"

IV=$(openssl rand -hex 16)

ENCRYPTED_DEK=$(openssl enc -aes-256-cbc \
  -K "$KEK_VALUE" \
  -iv "$IV" \
  -in "$DEK_PLAIN_TMP" \
  -a 2>/dev/null)

# Compute HMAC for integrity verification (covers IV + ciphertext)
HMAC=$(echo -n "${IV}${ENCRYPTED_DEK}" | openssl dgst -sha256 -hmac "$KEK_VALUE" | awk '{print $2}')

rm -f "$DEK_PLAIN_TMP"

# 8. Store KEK in Vault
log "Storing KEK in Vault at path '${VAULT_SECRET_MOUNT}/data/${VAULT_KEK_PATH}'..."
KEK_VERSION="v1"
CREATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

vault_kv_put "${VAULT_KEK_PATH}" \
  "{\"data\":{\"kek\":\"${KEK_VALUE}\",\"version\":\"${KEK_VERSION}\",\"created_at\":\"${CREATED_AT}\"}}"

log "KEK stored in Vault successfully."

# 9. Write encrypted DEK to /data/db
log "Writing encrypted DEK to ${DEK_FILE}..."
mkdir -p "$(dirname "$DEK_FILE")"

cat > "$DEK_FILE" <<EOF
${IV}:${ENCRYPTED_DEK}:${HMAC}
EOF
chmod 600 "$DEK_FILE"

# 10. Write metadata
cat > "$DEK_META_FILE" <<EOF
version=${KEK_VERSION}
created_at=${CREATED_AT}
kek_vault_path=${VAULT_SECRET_MOUNT}/data/${VAULT_KEK_PATH}
EOF
chmod 600 "$DEK_META_FILE"

log "======================================================"
log "  pgBackRest Envelope Key Encryption - INITIALIZED"
log "  KEK version : ${KEK_VERSION}"
log "  KEK path    : ${VAULT_SECRET_MOUNT}/data/${VAULT_KEK_PATH}"
log "  DEK file    : ${DEK_FILE}"
log "  Created at  : ${CREATED_AT}"
log "======================================================"
