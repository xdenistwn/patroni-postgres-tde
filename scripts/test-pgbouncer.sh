#!/bin/bash
# Script to test PgBouncer connections on both PostgreSQL nodes
set -e

echo "=========================================="
echo "  PgBouncer Connection Test"
echo "=========================================="
echo ""

# Load environment variables
# if [ -f .env ]; then
#   export $(cat .env | grep -v '^#' | xargs)
# fi

PGUSER=${PATRONI_PG_SUPERUSER:-"postgres"}
PGPASSWORD=${PATRONI_PG_PASSWORD:-"postgres_password_secure"}

# Test postgres-one PgBouncer
echo "Testing postgres-one PgBouncer (port 6432)..."
if docker exec postgres-one bash -c PGPASSWORD="$PGPASSWORD" psql -h localhost -p 6432 -U "$PGUSER" -d postgres -c "SELECT 'postgres-one PgBouncer OK' AS status, current_database(), inet_server_addr(), inet_server_port();" 2>/dev/null; then
  echo "✓ postgres-one PgBouncer connection successful!"
else
  echo "✗ postgres-one PgBouncer connection failed!"
fi

echo ""

# Test postgres-two PgBouncer
echo "Testing postgres-two PgBouncer (port 6433)..."
if docker exec postgres-two bash -c PGPASSWORD="$PGPASSWORD" psql -h localhost -p 6433 -U "$PGUSER" -d postgres -c "SELECT 'postgres-two PgBouncer OK' AS status, current_database(), inet_server_addr(), inet_server_port();" 2>/dev/null; then
  echo "✓ postgres-two PgBouncer connection successful!"
else
  echo "✗ postgres-two PgBouncer connection failed!"
fi

echo ""
echo "=========================================="
echo "  PgBouncer Pool Status"
echo "=========================================="
echo ""

echo "--- postgres-one (port 6432) ---"
PGPASSWORD="$PGPASSWORD" psql -h localhost -p 6432 -U "$PGUSER" -d pgbouncer -c "SHOW POOLS;" 2>/dev/null || echo "Could not retrieve pool status"

echo ""
echo "--- postgres-two (port 6433) ---"
PGPASSWORD="$PGPASSWORD" psql -h localhost -p 6433 -U "$PGUSER" -d pgbouncer -c "SHOW POOLS;" 2>/dev/null || echo "Could not retrieve pool status"

echo ""
echo "=========================================="
echo "  Architecture Summary"
echo "=========================================="
echo ""
echo "Port Mapping:"
echo "  5432 → postgres-one (PostgreSQL direct)"
echo "  6432 → postgres-one (PgBouncer → localhost:5432)"
echo "  5433 → postgres-two (PostgreSQL direct)"
echo "  6433 → postgres-two (PgBouncer → localhost:5432)"
echo ""
echo "Each PostgreSQL container runs its own PgBouncer instance."
echo "PgBouncer connects to PostgreSQL on localhost within the same container."
echo ""
echo "Recommended connection:"
echo "  Primary:  psql -h localhost -p 6432 -U $PGUSER -d postgres"
echo "  Replica:  psql -h localhost -p 6433 -U $PGUSER -d postgres"
