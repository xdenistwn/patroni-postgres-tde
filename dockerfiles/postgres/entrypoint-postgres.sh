#!/bin/bash
set -e

# Wait for etcd to be ready
echo "Waiting for etcd cluster to be ready..."
for i in {1..30}; do
  if curl -s http://etcd1:2379/health > /dev/null 2>&1 || curl -s http://etcd2:2379/health > /dev/null 2>&1 || curl -s http://etcd3:2379/health > /dev/null 2>&1; then
    echo "etcd cluster is ready"
    
    break
  fi
  echo "Waiting for etcd... ($i/30)"
  sleep 2
done

# Fix permissions on data directory
# PostgreSQL requires the data directory to have 0700 or 0750 permissions
DATA_DIR="${PATRONI_POSTGRESQL_DATA_DIR:-/data/db}"
if [ -d "$DATA_DIR" ]; then
  echo "Checking permissions on $DATA_DIR..."
  CURRENT_PERMS=$(stat -c '%a' "$DATA_DIR" 2>/dev/null || stat -f '%A' "$DATA_DIR" 2>/dev/null || echo "unknown")
  echo "Current permissions: $CURRENT_PERMS"
  
  # Only fix if we can (i.e., we own the directory or are root)
  if [ "$(stat -c '%U' "$DATA_DIR" 2>/dev/null || stat -f '%Su' "$DATA_DIR" 2>/dev/null)" = "postgres" ] || [ "$(id -u)" = "0" ]; then
    echo "Setting permissions to 0700..."
    chmod 0700 "$DATA_DIR" || echo "Warning: Could not set permissions"
  fi
fi

# Start PgBouncer in the background after PostgreSQL is ready
(
  echo "Waiting for PostgreSQL to be ready before starting PgBouncer..."
  for i in {1..30}; do
    if pg_isready -h 127.0.0.1 -p 5432 > /dev/null 2>&1; then
      echo "PostgreSQL is ready, starting PgBouncer on port 6432..."
      pgbouncer -d /etc/pgbouncer/pgbouncer.ini
      echo "PgBouncer started successfully"
      break
    fi
    sleep 2
  done
) &

# Start Patroni
exec "$@"