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

# Function to create test database
create_test_db() {
  local port=$1
  local name=$2
  
  echo "Creating test database on $name (port $port)..."
  docker exec postgres-one bash -c "PGPASSWORD='$PGPASSWORD' psql -h localhost -p $port -U $PGUSER -d postgres -c 'DROP DATABASE IF EXISTS $TEST_DB;'" 2>/dev/null || true
  docker exec postgres-one bash -c "PGPASSWORD='$PGPASSWORD' psql -h localhost -p $port -U $PGUSER -d postgres -c 'CREATE DATABASE $TEST_DB;'"
  echo "✓ Database created"
}

# Function to initialize pgbench
init_pgbench() {
  local port=$1
  local name=$2
  
  echo ""
  echo "Initializing pgbench on $name (port $port)..."
  docker exec postgres-one bash -c "PGPASSWORD='$PGPASSWORD' pgbench -h localhost -p $port -U $PGUSER -i -s $SCALE $TEST_DB"
  echo "✓ pgbench initialized"
}

# Function to run pgbench test
run_pgbench() {
  local port=$1
  local name=$2
  
  echo ""
  echo "=========================================="
  echo "  Running pgbench on $name"
  echo "  Port: $port"
  echo "=========================================="
  
  docker exec postgres-one bash -c "PGPASSWORD='$PGPASSWORD' pgbench -h localhost -p $port -U $PGUSER -c $CLIENTS -j $THREADS -T $DURATION -C -P 5 $TEST_DB"
}

# Function to show pool stats
show_pool_stats() {
  local port=$1
  local name=$2
  
  echo ""
  echo "--- PgBouncer Pool Stats ($name) ---"
  docker exec postgres-one bash -c "PGPASSWORD='$PGPASSWORD' psql -h localhost -p $port -U $PGUSER -d pgbouncer -c 'SHOW POOLS;'" 2>/dev/null || echo "Not a PgBouncer port"
}

# Main test flow
echo "=========================================="
echo "  Test 1: Direct PostgreSQL Connection"
echo "=========================================="

create_test_db 5432 "postgres-one (direct)"
init_pgbench 5432 "postgres-one (direct)"
run_pgbench 5432 "postgres-one (direct)"

echo ""
echo "=========================================="
echo "  Test 2: PgBouncer Connection"
echo "=========================================="

create_test_db 6432 "postgres-one (via PgBouncer)"
init_pgbench 6432 "postgres-one (via PgBouncer)"
run_pgbench 6432 "postgres-one (via PgBouncer)"

# Show final pool stats
show_pool_stats 6432 "postgres-one"

echo ""
echo "=========================================="
echo "  Stress Test Complete!"
echo "=========================================="
echo ""
echo "Cleanup:"
echo "  To remove test database, run:"
echo "  docker exec postgres-one psql -h localhost -p 5432 -U $PGUSER -c 'DROP DATABASE $TEST_DB;'"
