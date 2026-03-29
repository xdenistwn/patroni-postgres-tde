# PgBouncer — Connection Pooling

## Executive Summary

PgBouncer is a lightweight connection pooler that sits in front of PostgreSQL. Instead of each application client maintaining a permanent, resource-heavy connection directly to PostgreSQL, all clients connect to PgBouncer (port 6432), and PgBouncer maintains a much smaller pool of real connections to PostgreSQL (port 5432). This allows the system to handle hundreds of concurrent application clients without exhausting PostgreSQL's `max_connections` limit.

In this stack, PgBouncer runs **inside the same container** as the PostgreSQL/Patroni process. It is started automatically by the container's entrypoint script once PostgreSQL is ready, and listens on port 6432 for all incoming application traffic.

## Why This Matters (Business / Compliance Context)

Without connection pooling, PostgreSQL's `max_connections = 100` hard limit would cap concurrent users at 100. Modern applications and microservices routinely open many more connections than that, leading to "sorry, too many clients" errors and application downtime. PgBouncer makes the database scalable to hundreds of simultaneous clients at negligible infrastructure cost. It also provides a consistent connection endpoint that doesn't change during Patroni failovers (because it always points to `127.0.0.1:5432` which Patroni controls). This directly supports the organisation's availability SLA.

## Component Role in This Stack

```mermaid
graph LR
    APP["Application\n(many clients)"] -->|"port 6432\ntransaction mode"| PGB["PgBouncer\npid: /tmp/pgbouncer.pid"]
    PGB -->|"pool of connections\n127.0.0.1:5432"| PG["PostgreSQL 18\n(Patroni managed)"]
    PGB -->|"userlist.txt\nmd5 auth"| AUTH["userlist.txt\n/etc/pgbouncer/"]
```

### Architecture Comparison

```mermaid
graph TD
    subgraph "Without PgBouncer (Direct Connection)"
        APP1["Client 1"] -->|port 5432| PG1[("PostgreSQL\n(Max Conn: 100)")]
        APP2["Client 2"] -->|port 5432| PG1
        APP3["Client 3"] -->|port 5432| PG1
        APP4["Client N"] -.->|fails if > 100 clients| PG1
    end

    subgraph "With PgBouncer (Connection Pooling)"
        APP5["Client 1"] -->|port 6432| PGB["PgBouncer\n(Max Clients: 500)"]
        APP6["Client 2"] -->|port 6432| PGB
        APP7["Client 3"] -->|port 6432| PGB
        APP8["Client N"] -.->|port 6432| PGB
        PGB == "Shared Persistent Pool\n(e.g. 75 conns)" ==> PG2[("PostgreSQL\n(Max Conn: 100)")]
    end
```

### Direct Connection vs. PgBouncer

| Approach | Scaling Behavior (e.g., 500 Clients vs 100 `max_connections`) | Pros | Cons |
|----------|-----------------------------------------------------------------|------|------|
| **Direct Connection**<br>(Without PgBouncer) | **Breaks Application:** Clients map 1:1 to PostgreSQL backend processes. The 101st application client receives a fatal `"sorry, too many clients already"` error and is rejected. | • Simple architecture, no extra moving parts<br>• Full support for prepared statements & all session-level features<br>• Slightly lower latency for establishing a single connection | • Hard limit on concurrent clients (`max_connections`)<br>• High CPU and memory overhead per connection request<br>• Vulnerable to connection spikes |
| **Connection Pooling**<br>(With PgBouncer) | **Keeps Database Safe:** PgBouncer successfully holds all 500 application connections open, but multiplexes their transactions over a pool of (e.g., 75) real PostgreSQL connections. If all 75 are busy, PgBouncer safely queues the excess transactions in memory. PostgreSQL is completely shielded and never breaks. | • Supports thousands of concurrent application clients safely<br>• Significantly reduces PostgreSQL memory and CPU overhead<br>• Protects database from sudden connection storms | • An extra component to configure, monitor, and maintain<br>• `transaction` mode breaks session-level features (e.g. `SET`, `PREPARE`)<br>• Small query delay when clients wait for an available pool slot |

## Version & Distribution

| Property        | Value                                                           |
|-----------------|-----------------------------------------------------------------|
| Version         | percona-pgbouncer (version [TO BE CONFIRMED: run `pgbouncer --version` inside container]) |
| Source          | Percona DNF repository / ubuntu `pgbouncer` apt package        |
| Install method  | Docker — installed in Dockerfile alongside PostgreSQL           |
| Architecture    | aarch64 / x86_64                                               |
| Config file     | `/etc/pgbouncer/pgbouncer.ini`                                  |
| Auth file       | `/etc/pgbouncer/userlist.txt`                                   |

## Configuration

### `/etc/pgbouncer/pgbouncer.ini`

```ini
[databases]
; Wildcard: proxy all database names to local PostgreSQL
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr         = 0.0.0.0
listen_port         = 6432

; Authentication — md5 passwords from userlist.txt
auth_type           = md5
auth_file           = /etc/pgbouncer/userlist.txt

; Admin / stats access
admin_users         = postgres
stats_users         = postgres

; Pool configuration
pool_mode           = transaction        ; transaction-level pooling (most efficient)
max_client_conn     = 500               ; total concurrent client connections allowed
default_pool_size   = 75               ; server connections held per database+user pair
min_pool_size       = 25               ; connections kept up when idle
reserve_pool_size   = 75               ; extra connections for bursting
reserve_pool_timeout = 3               ; seconds before reserve pool is used

; Connection limits
max_db_connections  = 500
max_user_connections = 500

; Timeouts (seconds; 0 = unlimited)
server_idle_timeout = 600              ; remove idle server connection after 10 min
server_lifetime     = 3600             ; recycle server connection after 1 hour
server_connect_timeout = 15
query_timeout       = 0                ; no per-query timeout
query_wait_timeout  = 120              ; client waits max 2 min for a server connection
client_idle_timeout = 0
idle_transaction_timeout = 0

; Logging
log_connections     = 1
log_disconnections  = 1
log_pooler_errors   = 1
verbose             = 0

; Reset query between transactions
server_reset_query  = DISCARD ALL

; Health check
server_check_query  = SELECT 1
server_check_delay  = 30

; PID and socket
pidfile             = /tmp/pgbouncer.pid
unix_socket_dir     = /tmp
```

### Startup (entrypoint-postgres.sh)

```bash
# PgBouncer is started in the background after PostgreSQL becomes ready
(
  for i in {1..30}; do
    if pg_isready -h 127.0.0.1 -p 5432 > /dev/null 2>&1; then
      pgbouncer -d /etc/pgbouncer/pgbouncer.ini   # -d = daemon mode
      break
    fi
    sleep 2
  done
) &

exec "$@"   # start Patroni in foreground
```

### Key Parameters Explained

| Parameter               | Value Found | Effect                                                                    | Recommendation                            |
|-------------------------|-------------|---------------------------------------------------------------------------|-------------------------------------------|
| `pool_mode`             | transaction | Server connection released after each transaction, not session-end        | Best for stateless apps; avoid if using `SET` session-level |
| `max_client_conn`       | 500         | The maximum number of incoming application clients PgBouncer will hold continuously open before rejecting them. | Must be scaled to handle peak application connection demands. |
| `default_pool_size`     | 75          | The maximum number of physical backend connections PgBouncer makes to PostgreSQL to serve the 500 clients. | Keep safely below PostgreSQL's `max_connections` (e.g., `100 - 3`). |
| `min_pool_size`         | 25          | Pre-warmed connections to reduce connection latency                       | Set to expected steady-state concurrency  |
| `reserve_pool_size`     | 75          | Extra pool for burst above `default_pool_size`                            | Monitor `cl_waiting`; increase if > 0    |
| `query_wait_timeout`    | 120         | When all 75 backend connections are busy, queued transactions wait a max of 2 mins for a free slot before erroring. | Tune to application tolerance for queued queries. |
| `server_reset_query`    | DISCARD ALL | Clears session state between transactions                                 | Required in transaction mode              |
| `auth_type`             | md5         | Password hashed with MD5; consider `scram-sha-256` for stronger auth     | Upgrade to SCRAM in production            |

## Integration Points

| Component     | Integration                                                                              |
|---------------|------------------------------------------------------------------------------------------|
| PostgreSQL    | PgBouncer connects to `127.0.0.1:5432`; shares the same container                       |
| Patroni       | Patroni controls port 5432 (promotes/demotes); PgBouncer automatically follows because it always points to localhost |
| pgBench       | pgBench tests run against both port 5432 (direct) and port 6432 (via PgBouncer) in `pgbench_test.docker.sh` |
| Application   | Port 6432 is the recommended connection endpoint for all application traffic             |

## Known Issues & Research Findings

### Prepared Statements (`PREPARE` / `EXECUTE`) Issue

When PgBouncer is in `transaction` mode, it runs a `DISCARD ALL` command to wipe the database connection cleanly after every single transaction. This ensures the connection is fresh and prevents data or settings from leaking between different clients sharing the pool.

However, this "hard wipe" also deletes **Prepared Statements**—queries your application specifically asks the database to "remember" so it can run them faster later. Because PgBouncer wipes them out, your application will throw errors when it tries to use them again.

If your application relies heavily on prepared statements, you have three options to fix this:
1. **Switch to Session Pooling:** Change to `pool_mode = session`. This binds a client to a database connection for their entire session, allowing prepared statements to survive. The downside is it severely limits how many simultaneous clients PgBouncer can safely handle.
2. **Use a Gentler Cleanup:** Keep the highly scalable `transaction` mode, but configure PgBouncer to perform a softer cleanup (such as tweaking `server_reset_query` and `server_reset_query_always`), so it stops wiping out the prepared statements.
3. **Application-Side Fix (Laravel Example):** Keep `transaction` mode and simply tell your application framework to stop using server-side prepared statements. Instead, it will "emulate" them locally securely.

   **Example for Laravel (`config/database.php`):**
   ```php
   'pgsql' => [
       'driver'   => 'pgsql',
       'host'     => env('DB_HOST', '127.0.0.1'),
       'port'     => env('DB_PORT', '6432'), // Connect to PgBouncer port
       'database' => env('DB_DATABASE', 'forge'),
       'username' => env('DB_USERNAME', 'forge'),
       'password' => env('DB_PASSWORD', ''),
       // ... other settings ...
       
       'options'  => [
           // This tells Laravel/PDO to emulate prepared statements locally, 
           // bypassing the PgBouncer 'DISCARD ALL' wipe issue completely!
           \PDO::ATTR_EMULATE_PREPARES => true,
       ],
   ],
   ```

### PgBouncer Not HA-Aware

PgBouncer connects to `127.0.0.1:5432` which is always the local node. When Patroni promotes `postgres-two` to leader while `postgres-one` is down, writes that go through the old `postgres-one:6432` will fail. For true transparent HA, a DNS-based virtual IP or a load balancer in front of PgBouncer instances is required.

## Operational Notes

```bash
# Connect to PgBouncer admin console
psql -h 127.0.0.1 -p 6432 -U postgres pgbouncer

# Show pool status
SHOW POOLS;

# Show server connections
SHOW SERVERS;

# Show client connections
SHOW CLIENTS;

# Show statistics
SHOW STATS;

# Reload config without restart
RELOAD;

# Reload from OS
docker exec postgres-one pkill -HUP pgbouncer

# Ping test script
./scripts/pgbouncer_ping_test.docker.sh
```

## Performance Considerations

- In pgBench tests (see `docs/benchmarks/pgbench-results.md`), transaction-mode PgBouncer delivered very similar TPS to direct PostgreSQL connection while supporting far more clients than `max_connections = 100` allows.
- Pool exhaustion (`cl_waiting > 0`) is indicated in `SHOW POOLS` output. When this occurs, increase `default_pool_size` or reduce application connection churn.
- `DISCARD ALL` adds a small overhead per transaction; disable `server_reset_query` only if your application guarantees no cross-transaction session state.

## References & Further Reading

- [pgBouncer Documentation](https://www.pgbouncer.org/config.html)
- [Percona pgBouncer](https://www.percona.com/software/postgresql-database/pgbouncer)
- [pgBouncer Pool Modes](https://www.pgbouncer.org/features.html)
- [STRESS_TEST_GUIDE.md](../../STRESS_TEST_GUIDE.md) — PgBouncer tuning guidance based on pgBench results
