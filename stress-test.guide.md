# pgbench Stress Testing Guide

## Quick Start

### Basic Test (Default Settings)
```bash
./scripts/stress-test.sh
```

**Default Parameters:**
- Scale: 50 (~7.5MB database)
- Clients: 50 concurrent connections
- Threads: 10
- Duration: 60 seconds

### Custom Test
```bash
./scripts/stress-test.sh [scale] [clients] [threads] [duration]
```

**Examples:**
```bash
# Light test: 10 scale, 10 clients, 2 threads, 30 seconds
./scripts/stress-test.sh 10 10 2 30

# Medium test: 50 scale, 50 clients, 10 threads, 60 seconds
./scripts/stress-test.sh 50 50 10 60

# Heavy test: 100 scale, 100 clients, 20 threads, 120 seconds
./scripts/stress-test.sh 100 100 20 120

# Extreme test: 200 scale, 200 clients, 50 threads, 300 seconds
./scripts/stress-test.sh 200 200 50 300
```

## What the Script Does

1. **Test 1: Direct PostgreSQL Connection (Port 5432)**
   - Creates test database
   - Initializes pgbench with sample data
   - Runs benchmark directly against PostgreSQL
   - Shows raw PostgreSQL performance

2. **Test 2: PgBouncer Connection (Port 6432)**
   - Creates test database via PgBouncer
   - Initializes pgbench via PgBouncer
   - Runs benchmark through PgBouncer
   - Shows pooled connection performance
   - Displays pool statistics

## Understanding the Results

### pgbench Output Metrics

```
transaction type: <builtin: TPC-B (sort of)>
scaling factor: 50
query mode: simple
number of clients: 50
number of threads: 10
duration: 60 s
number of transactions actually processed: 123456
latency average = 24.321 ms
latency stddev = 12.345 ms
tps = 2057.600000 (including connections establishing)
tps = 2058.123456 (excluding connections establishing)
```

**Key Metrics:**
- **TPS (Transactions Per Second)**: Higher is better
- **Latency Average**: Lower is better (in milliseconds)
- **Latency Stddev**: Lower is better (more consistent)

### Expected Results

#### Direct Connection (Port 5432)
- **Pros**: Slightly lower latency per transaction
- **Cons**: Limited by max_connections, higher memory usage

#### PgBouncer Connection (Port 6432)
- **Pros**: Can handle many more clients, lower memory usage
- **Cons**: Slight overhead from pooling (usually negligible)

### Pool Statistics

After the test, you'll see PgBouncer pool stats:
```
 database  | user     | cl_active | cl_waiting | sv_active | sv_idle | sv_used
-----------+----------+-----------+------------+-----------+---------+---------
 pgbench_test | postgres |        50 |          0 |        25 |       0 |      25
```

**Columns:**
- `cl_active`: Active client connections
- `cl_waiting`: Clients waiting for a connection
- `sv_active`: Active server connections
- `sv_idle`: Idle server connections in pool
- `sv_used`: Total server connections used

**Good Signs:**
- `cl_waiting = 0`: No clients waiting (pool size is adequate)
- `sv_active < default_pool_size`: Pool not exhausted
- `sv_idle > 0`: Pool has spare capacity

**Bad Signs:**
- `cl_waiting > 0`: Increase pool size
- `sv_active = default_pool_size`: Pool exhausted, increase size

## Monitoring During Test

### Watch Pool Status (Real-time)
```bash
watch -n 2 'docker exec postgres-one bash -c "PGPASSWORD=postgres_password_secure psql -h localhost -p 6432 -U postgres -d pgbouncer -c \"SHOW POOLS;\""'
```

### Watch Active Connections
```bash
watch -n 2 'docker exec postgres-one bash -c "PGPASSWORD=postgres_password_secure psql -h localhost -p 5432 -U postgres -c \"SELECT count(*) FROM pg_stat_activity WHERE state = '\''active'\'';\""'
```

### Watch Database Stats
```bash
watch -n 2 'docker exec postgres-one bash -c "PGPASSWORD=postgres_password_secure psql -h localhost -p 5432 -U postgres -c \"SELECT datname, numbackends, xact_commit, xact_rollback FROM pg_stat_database WHERE datname = '\''pgbench_test'\'';\""'
```

## Tuning PgBouncer Based on Results

### If `cl_waiting > 0` (Clients Waiting)
Increase pool size in `config/pgbouncer/pgbouncer.ini`:
```ini
default_pool_size = 100  # Increase from 75
```

Then reload:
```bash
docker exec postgres-one pkill -HUP pgbouncer
```

### If Latency is High
1. Check if pool is exhausted
2. Increase pool size
3. Check PostgreSQL performance directly
4. Consider increasing `max_connections` in PostgreSQL

### If TPS is Low
1. Increase number of threads
2. Increase pool size
3. Check disk I/O and CPU usage
4. Consider scaling PostgreSQL resources

## Cleanup

### Remove Test Database
```bash
docker exec postgres-one bash -c "PGPASSWORD=postgres_password_secure psql -h localhost -p 5432 -U postgres -c 'DROP DATABASE pgbench_test;'"
```

### Reset PgBouncer
```bash
docker exec postgres-one pkill -HUP pgbouncer
```

## Advanced Testing

### Read-Only Test (SELECT only)
```bash
docker exec postgres-one bash -c "PGPASSWORD=postgres_password_secure pgbench -h localhost -p 6432 -U postgres -c 50 -j 10 -T 60 -S pgbench_test"
```

### Custom SQL Test
Create a file `custom.sql`:
```sql
\set aid random(1, 100000)
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
```

Run:
```bash
docker exec postgres-one bash -c "PGPASSWORD=postgres_password_secure pgbench -h localhost -p 6432 -U postgres -c 50 -j 10 -T 60 -f /path/to/custom.sql pgbench_test"
```

## Troubleshooting

### "too many clients already"
- Increase `max_client_conn` in pgbouncer.ini
- Reduce number of test clients

### "sorry, too many clients already" (PostgreSQL)
- Use PgBouncer (port 6432) instead of direct connection
- Increase `max_connections` in PostgreSQL config

### Connection timeouts
- Increase `server_connect_timeout` in pgbouncer.ini
- Check if PostgreSQL is overloaded

### Poor performance
- Check if TDE encryption is causing overhead
- Monitor CPU and disk I/O
- Ensure adequate pool size
- Check for lock contention

## Recommended Test Scenarios

### Scenario 1: Connection Pooling Benefit
```bash
# Test with many clients (would fail without pooling)
./scripts/stress-test.sh 50 200 20 60
```

### Scenario 2: High Throughput
```bash
# Large scale, many transactions
./scripts/stress-test.sh 100 100 20 120
```

### Scenario 3: Sustained Load
```bash
# Long duration test
./scripts/stress-test.sh 50 50 10 300
```

### Scenario 4: Burst Traffic
```bash
# Many clients, short duration
./scripts/stress-test.sh 50 500 50 30
```
