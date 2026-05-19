#!/bin/bash
# PostgreSQL Stress Test using pgbench
# Tests both direct connection and PgBouncer connection
set -e

# Load environment variables
if [ -f .env ]; then
  export $(cat .env | grep -v '^#' | xargs)
fi

PGUSER=${PATRONI_PG_SUPERUSER:-"postgres"}
PGPASSWORD=${PATRONI_PG_PASSWORD:-"postgres_password_secure"}
TEST_DB="pgbench_test"

# Default test parameters
SCALE=${1:-50}           # Database scale factor (default: 50 = ~7.5MB)
CLIENTS=${2:-50}         # Number of concurrent clients (default: 50)
THREADS=${3:-10}         # Number of threads (default: 10)
DURATION=${4:-60}        # Test duration in seconds (default: 60)

echo "=========================================="
echo "  PostgreSQL Stress Test with pgbench"
echo "=========================================="
echo ""
echo "Test Parameters:"
echo "  Scale Factor: $SCALE (approx $(($SCALE * 15 / 100))MB)"
echo "  Clients: $CLIENTS"
echo "  Threads: $THREADS"
echo "  Duration: ${DURATION}s"
echo ""
echo "NOTE: Cluster uses default_table_access_method=tde_heap."
echo "      pgbench init runs with heap override to avoid tde_heap errors."
echo ""

# ─────────────────────────────────────────────────────────────
# Function: create test database (always on port 5432 — primary)
# ─────────────────────────────────────────────────────────────
create_test_db() {
  echo ">>> Creating test database '$TEST_DB' on primary (port 5432)..."
  docker exec postgres-one bash -c "
    PGPASSWORD='$PGPASSWORD' psql -h 127.0.0.1 -p 5432 -U $PGUSER -d postgres \
      -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$TEST_DB';\" \
      -c \"DROP DATABASE IF EXISTS $TEST_DB;\" \
      -c \"CREATE DATABASE $TEST_DB OWNER $PGUSER;\"
  "
  echo "✓ Database '$TEST_DB' created"
}

# ─────────────────────────────────────────────────────────────
# Function: init pgbench with heap access method override
#
# WHY: patroni sets default_table_access_method=tde_heap globally.
#      pgbench init creates tables without specifying an AM, so it
#      inherits tde_heap and fails unless the DB has a TDE key setup.
#      We override at session level with PGOPTIONS so pgbench creates
#      plain heap tables that work without encryption config.
# ─────────────────────────────────────────────────────────────
init_pgbench() {
  local port=$1
  local name=$2

  echo ""
  echo ">>> Initialising pgbench on $name (port $port, heap override)..."
  docker exec postgres-one bash -c "
    PGPASSWORD='$PGPASSWORD' \
    PGOPTIONS='-c default_table_access_method=heap' \
    pgbench -h 127.0.0.1 -p $port -U $PGUSER \
      -i -s $SCALE \
      --no-vacuum \
      $TEST_DB
  "
  echo "✓ pgbench initialised on $name"
}

# ─────────────────────────────────────────────────────────────
# Function: run pgbench load test
# ─────────────────────────────────────────────────────────────
run_pgbench() {
  local port=$1
  local name=$2

  echo ""
  echo "=========================================="
  echo "  Running pgbench on $name"
  echo "  Port: $port | Clients: $CLIENTS | Duration: ${DURATION}s"
  echo "=========================================="

  docker exec postgres-one bash -c "
    PGPASSWORD='$PGPASSWORD' \
    pgbench -h 127.0.0.1 -p $port -U $PGUSER \
      -c $CLIENTS -j $THREADS -T $DURATION \
      -P 5 \
      $TEST_DB
  "
}

# ─────────────────────────────────────────────────────────────
# Function: show PgBouncer pool stats
# ─────────────────────────────────────────────────────────────
show_pool_stats() {
  echo ""
  echo "--- PgBouncer Pool Stats ---"
  docker exec postgres-one bash -c "
    PGPASSWORD='$PGPASSWORD' psql -h 127.0.0.1 -p 6432 -U $PGUSER -d pgbouncer -c 'SHOW POOLS;'
  " 2>/dev/null || echo "(Could not connect to PgBouncer admin)"
}

# ─────────────────────────────────────────────────────────────
# Main test flow
# ─────────────────────────────────────────────────────────────

# Always create DB and init via port 5432 (primary direct).
# PgBouncer in transaction mode blocks DDL, so init must be direct.
create_test_db
init_pgbench 5432 "postgres-one (direct)"

echo ""
echo "=========================================="
echo "  Test 1: Direct PostgreSQL Connection"
echo "=========================================="
run_pgbench 5432 "postgres-one (direct)"

echo ""
echo "=========================================="
echo "  Test 2: PgBouncer Connection"
echo "=========================================="
run_pgbench 6432 "postgres-one (via PgBouncer)"

show_pool_stats

echo ""
echo "=========================================="
echo "  Stress Test Complete!"
echo "=========================================="
echo ""
echo "Cleanup (drop test DB):"
echo "  docker exec postgres-one bash -c \\"
echo "    \"PGPASSWORD='$PGPASSWORD' psql -h 127.0.0.1 -p 5432 -U $PGUSER -c 'DROP DATABASE $TEST_DB;'\""
