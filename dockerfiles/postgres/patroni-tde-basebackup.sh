#!/bin/bash
# Wrapper script for pg_tde_basebackup to be used with Patroni
set -e

echo "--- PATRONI: Arguments ---"
echo "$@"
echo "------------------------"

# 1. Parse arguments automatically appended by Patroni
for i in "$@"; do
  case $i in
  --datadir=*)
  DATA_DIR="${i#*=}"
  ;;
  --connstring=*)
  CONNSTRING="${i#*=}"
  # Extract values from connstring using sed
  REPLICATION_HOST=$(echo "$CONNSTRING" | sed -n 's/.*host=\([^ ]*\).*/\1/p')
  REPLICATION_PORT=$(echo "$CONNSTRING" | sed -n 's/.*port=\([^ ]*\).*/\1/p')
  REPLICATION_USER=$(echo "$CONNSTRING" | sed -n 's/.*user=\([^ ]*\).*/\1/p')
  ;;
  esac
done

# 2. Use environment variables as fallback
DATA_DIR=${DATA_DIR:-$PATRONI_POSTGRESQL_DATA_DIR}
REPLICATION_HOST=${REPLICATION_HOST:-$PATRONI_REPLICATION_HOST}
REPLICATION_PORT=${REPLICATION_PORT:-$PATRONI_REPLICATION_PORT}
REPLICATION_USER=${REPLICATION_USER:-$PATRONI_REPLICATION_USERNAME}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD:-$PATRONI_REPLICATION_PASSWORD}

echo "Final Target directory: ${DATA_DIR}"
echo "Final Source host: ${REPLICATION_HOST}"
echo "Final Source user: ${REPLICATION_USER}"
echo "Final Source port: ${REPLICATION_PORT}"

if [ -z "$DATA_DIR" ] || [ -z "$REPLICATION_HOST" ]; then
  echo "Error: Could not determine DATA_DIR or REPLICATION_HOST from args or environment!"
  exit 1
fi

# 3. Export password for authentication
export PGPASSWORD="$REPLICATION_PASSWORD"

# 4. Execute pg_tde_basebackup
/usr/pgsql-18/bin/pg_tde_basebackup \
  -h "$REPLICATION_HOST" \
  -p "${REPLICATION_PORT:-5432}" \
  -U "$REPLICATION_USER" \
  -D "$DATA_DIR" \
  --wal-method=stream \
  --checkpoint=fast \
  --max-rate=100M \
  -v -P

echo "pg_tde_basebackup completed successfully."
