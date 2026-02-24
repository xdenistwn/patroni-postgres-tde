#!/bin/bash
# =============================================================================
# pgbackrest-keymgmt-rotate.sh
# Envelope Key Encryption - KEK + DEK Rotation
#
# Rotation process (single manual trigger):
#   1. Read current KEK from Vault
#   2. Decrypt the existing DEK using old KEK (verify integrity)
#   3. Generate a new KEK
#   4. Generate a new DEK (fresh cipher-pass for pgBackRest)
#   5. Encrypt new DEK with new KEK
#   6. Atomically write new encrypted DEK to /data/db (replicas will see it too)
#   7. Update KEK in Vault (version bumped)
#   8. Reload pgBackRest on all cluster nodes to pick up the new cipher-pass
#
# Run this MANUALLY from the host. Primary + replicas will automatically
# pick up the new DEK via /data/db/pgbackrest_dek.enc.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"   # from host, use exposed port
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_KEK_PATH="${VAULT_KEK_PATH:-pgbackrest/kek}"
VAULT_SECRET_MOUNT="${VAULT_SECRET_MOUNT:-secret}"

DEK_FILE="${DEK_FILE:-/data/db/pgbackrest_dek.enc}"
DEK_META_FILE="${DEK_META_FILE:-/data/db/pgbackrest_dek.meta}"

# Patroni endpoints (host-reachable ports)
PATRONI_ENDPOINTS=(
  "http://localhost:8008"
  "http://localhost:8009"
)

# Docker container names for all PG nodes
PG_CONTAINERS=("postgres-one" "postgres-two")

LOG_PREFIX="[pgbackrest-keymgmt-rotate]"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $LOG_PREFIX $*"; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARN:  $*"; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

vault_kv_put() {
  local path="$1"
  local payload="$2"
  curl -sf \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data "$payload" \
    "${VAULT_ADDR}/v1/${VAULT_SECRET_MOUNT}/data/${path}" >/dev/null \
    || die "Failed to write to Vault path: ${VAULT_SECRET_MOUNT}/data/${path}"
}

vault_kv_get_field() {
  local path="$1"
  local field="$2"
  curl -sf \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/${VAULT_SECRET_MOUNT}/data/${path}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['data']['${field}'], end='')" \
    || die "Failed to read field '${field}' from Vault at '${VAULT_SECRET_MOUNT}/data/${path}'"
}

decrypt_dek() {
  local kek_hex="$1"
  local iv="$2"
  local enc_b64="$3"
  local hmac_expected="$4"

  # Verify HMAC integrity first
  local hmac_actual
  hmac_actual=$(echo -n "${iv}${enc_b64}" | openssl dgst -sha256 -hmac "$kek_hex" | awk '{print $2}')
  if [ "$hmac_actual" != "$hmac_expected" ]; then
    die "HMAC verification FAILED. DEK file may be tampered or KEK mismatch. Aborting rotation."
  fi

  # Decrypt
  local plaintext
  plaintext=$(echo "$enc_b64" | openssl enc -d -aes-256-cbc \
    -K "$kek_hex" \
    -iv "$iv" \
    -a 2>/dev/null) || die "Failed to decrypt DEK with current KEK."
  echo -n "$plaintext"
}

encrypt_dek() {
  local kek_hex="$1"
  local dek_plaintext="$2"
  local iv
  iv=$(openssl rand -hex 16)

  local plain_tmp
  plain_tmp=$(mktemp)
  echo -n "$dek_plaintext" > "$plain_tmp"

  local enc_b64
  enc_b64=$(openssl enc -aes-256-cbc \
    -K "$kek_hex" \
    -iv "$iv" \
    -in "$plain_tmp" \
    -a 2>/dev/null)
  rm -f "$plain_tmp"

  local hmac
  hmac=$(echo -n "${iv}${enc_b64}" | openssl dgst -sha256 -hmac "$kek_hex" | awk '{print $2}')

  echo "${iv}:${enc_b64}:${hmac}"
}

find_leader() {
  local leader=""
  for endpoint in "${PATRONI_ENDPOINTS[@]}"; do
    local info
    info=$(curl -sf --connect-timeout 3 --max-time 6 "${endpoint}/cluster" 2>/dev/null || true)
    if [ -n "$info" ]; then
      leader=$(echo "$info" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('members',[]):
    if m.get('role')=='leader':
        print(m['name'])
        break
" 2>/dev/null || true)
      if [ -n "$leader" ] && [ "$leader" != "null" ]; then
        echo "$leader"
        return 0
      fi
    fi
  done
  die "Could not find Patroni cluster leader. Is the cluster running?"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_cmd curl python3 openssl docker

[ -z "$VAULT_TOKEN" ] && die "VAULT_TOKEN is not set. Export it before running."

log "======================================================"
log "  pgBackRest Envelope Key - ROTATION STARTING"
log "======================================================"

# Check Vault is reachable
log "Checking Vault at ${VAULT_ADDR}..."
curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1 \
  || die "Vault is not reachable at ${VAULT_ADDR}"
log "Vault is reachable."

# Find cluster leader
log "Finding Patroni cluster leader..."
LEADER=$(find_leader)
log "Current leader: ${LEADER}"

# Safety: check no basebackup is running
log "Checking for running pgbackrest backup processes..."
for container in "${PG_CONTAINERS[@]}"; do
  BKUP=$(docker exec "$container" ps aux 2>/dev/null | grep "pgbackrest.*backup" | grep -v grep || true)
  if [ -n "$BKUP" ]; then
    die "pgbackrest backup is currently running on ${container}! Wait for it to finish before rotating."
  fi
done
log "No active backups detected. Safe to rotate."

# ---------------------------------------------------------------------------
# Step 1: Read current KEK from Vault
# ---------------------------------------------------------------------------
log "Reading current KEK from Vault..."
OLD_KEK=$(vault_kv_get_field "${VAULT_KEK_PATH}" "kek")
OLD_VERSION=$(vault_kv_get_field "${VAULT_KEK_PATH}" "version")
log "Current KEK version: ${OLD_VERSION}"

# ---------------------------------------------------------------------------
# Step 2: Read & decrypt current DEK from primary
# ---------------------------------------------------------------------------
log "Reading encrypted DEK from ${LEADER}..."
DEK_FILE_CONTENT=$(docker exec "$LEADER" cat "$DEK_FILE" 2>/dev/null \
  || die "Cannot read DEK file '${DEK_FILE}' from container '${LEADER}'.")

# Parse: IV:ENCRYPTED_B64:HMAC
OLD_IV=$(echo "$DEK_FILE_CONTENT" | cut -d: -f1)
OLD_ENC=$(echo "$DEK_FILE_CONTENT" | cut -d: -f2)
OLD_HMAC=$(echo "$DEK_FILE_CONTENT" | cut -d: -f3)

log "Verifying DEK integrity and decrypting..."
OLD_DEK_PLAINTEXT=$(decrypt_dek "$OLD_KEK" "$OLD_IV" "$OLD_ENC" "$OLD_HMAC")
log "Current DEK decrypted and verified successfully."

# ---------------------------------------------------------------------------
# Step 3 & 4: Generate new KEK and new DEK
# ---------------------------------------------------------------------------
log "Generating new KEK (256-bit)..."
NEW_KEK=$(openssl rand -hex 32)

log "Generating new DEK (256-bit)..."
NEW_DEK_PLAINTEXT=$(openssl rand -hex 32)

# ---------------------------------------------------------------------------
# Step 5: Encrypt new DEK with new KEK
# ---------------------------------------------------------------------------
log "Encrypting new DEK with new KEK..."
NEW_DEK_FILE_CONTENT=$(encrypt_dek "$NEW_KEK" "$NEW_DEK_PLAINTEXT")

# ---------------------------------------------------------------------------
# Step 6: Atomically update encrypted DEK on PRIMARY node
# ---------------------------------------------------------------------------
NEW_VERSION="v$((${OLD_VERSION#v} + 1))"
ROTATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

log "Updating DEK file on ${LEADER}..."
docker exec -i "$LEADER" bash -c "
  # Update encrypted file
  TMP=\$(mktemp -p \$(dirname '${DEK_FILE}'))
  cat > \"\$TMP\" <<'EODEK'
${NEW_DEK_FILE_CONTENT}
EODEK
  chmod 600 \"\$TMP\"
  mv -f \"\$TMP\" '${DEK_FILE}'
"

# Update metadata
docker exec -i "$LEADER" bash -c "cat > '${DEK_META_FILE}' <<'EOMETA'
version=${NEW_VERSION}
created_at=${ROTATED_AT}
kek_vault_path=${VAULT_SECRET_MOUNT}/data/${VAULT_KEK_PATH}
EOMETA
chmod 600 '${DEK_META_FILE}'"

log "DEK updated on ${LEADER}."

# ---------------------------------------------------------------------------
# Step 7: Update KEK in Vault
# ---------------------------------------------------------------------------
log "Updating KEK in Vault (version: ${NEW_VERSION})..."
vault_kv_put "${VAULT_KEK_PATH}" \
  "{\"data\":{\"kek\":\"${NEW_KEK}\",\"version\":\"${NEW_VERSION}\",\"created_at\":\"${ROTATED_AT}\",\"previous_version\":\"${OLD_VERSION}\"}}"
log "New KEK stored in Vault successfully."

# ---------------------------------------------------------------------------
# Step 8: Propagate to replicas (Encrypted file only)
# ---------------------------------------------------------------------------
log "Propagating new encrypted DEK to replicas..."
for container in "${PG_CONTAINERS[@]}"; do
  if [ "$container" = "$LEADER" ]; then
    continue
  fi
  log "  Updating ${container}..."
  docker exec -i "$container" bash -c "
    # Update encrypted file
    cat > '${DEK_FILE}' <<'EODEK'
${NEW_DEK_FILE_CONTENT}
EODEK
    chmod 600 '${DEK_FILE}'
    
    cat > '${DEK_META_FILE}' <<'EOMETA'
version=${NEW_VERSION}
created_at=${ROTATED_AT}
kek_vault_path=${VAULT_SECRET_MOUNT}/data/${VAULT_KEK_PATH}
EOMETA
    chmod 600 '${DEK_META_FILE}'"
  log "  ${container}: Updated."
done

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "======================================================"
log "  ROTATION COMPLETE"
log "  Old KEK version : ${OLD_VERSION}"
log "  New KEK version : ${NEW_VERSION}"
log "  Rotated at      : ${ROTATED_AT}"
log "======================================================"
log "pgBackRest will use the new cipher-pass on next WAL archive / backup run."
log "No pgBackRest restart needed - get-cipher-pass is called per-run."
