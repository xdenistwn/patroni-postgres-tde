# HAProxy Overview

**Executive Summary:**
HAProxy acts as a smart load balancer and traffic director between the application (like Laravel) and our PostgreSQL clusters. By understanding the real-time status of each database node—specifically, whether a node is the current "Leader" (Primary) or a "Replica"—HAProxy automatically splits database writes and reads to the correct servers. Furthermore, HAProxy supports a multi-tenant layout by mapping different sets of ports to entirely different database clusters, keeping tenant data pipelines completely isolated and highly available.

---

## 1. Multi-Tenant Architecture

HAProxy is configured to handle multiple Postgres clusters simultaneously. It achieves this by assigning a dedicated block of ports to each tenant cluster.

For example, each tenant gets a **Primary Port (RW)** and a **Replica Port (RO)**:
- **Tenant A (Main Cluster)**: Connects via `5001` (primary) and `5101` (replicas).
- **Tenant B (Alpha Cluster)**: Connects via `5002` (primary) and `5102` (replicas).
- **Tenant C (Beta Cluster)**: Connects via `5003` (primary) and `5103` (replicas).

### Sample Config: HAProxy (`haproxy.cfg`)

```haproxy
global
    maxconn 4096
    log stdout format raw local0

defaults
    mode tcp
    log global
    retries 3
    timeout connect 5s
    timeout client 30m
    timeout server 30m
    timeout check 5s

# ----------------------------------------------------
# TENANT A: Main Cluster (postgres-cluster)
# ----------------------------------------------------
listen tenant_a_primary
    bind *:5001
    # Patroni API check: 200 OK only if this node is the leader
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions maxconn 500

    server postgres-one postgres-one:6432 check port 8008
    server postgres-two postgres-two:6432 check port 8008

listen tenant_a_replicas
    bind *:5101
    balance roundrobin
    # Patroni API check: 200 OK only if this node is a running replica
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 maxconn 500

    server postgres-one postgres-one:6432 check port 8008
    server postgres-two postgres-two:6432 check port 8008

# ----------------------------------------------------
# TENANT B: Alpha Cluster (tenant-alpha-cluster)
# (Uncomment the servers below when spinning up Tenant B db cluster)
# ----------------------------------------------------
listen tenant_b_primary
    bind *:5002
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions maxconn 500

    # server pg-alpha-one pg-alpha-one:6432 check port 8008
    # server pg-alpha-two pg-alpha-two:6432 check port 8008

listen tenant_b_replicas
    bind *:5102
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 maxconn 500

    # server pg-alpha-one pg-alpha-one:6432 check port 8008
    # server pg-alpha-two pg-alpha-two:6432 check port 8008
```

---

## 2. Laravel Database Integration

Laravel natively supports "Read & Write Connections" in its configuration array, which perfectly complements HAProxy's port-based routing.

### Sample Config: Laravel (`config/database.php`)

```php
'connections' => [

    // ---------------------------------------------------
    // Tenant A Database Configuration
    // ---------------------------------------------------
    'tenant_a' => [
        'driver'   => 'pgsql',
        
        // Auto Read/Write Split
        'read' => [
            'host' => env('DB_HOST_PROXY', 'haproxy'),
            'port' => env('DB_PORT_A_RO', 5101),       // HAProxy Replica Port
        ],
        'write' => [
            'host' => env('DB_HOST_PROXY', 'haproxy'),
            'port' => env('DB_PORT_A_RW', 5001),       // HAProxy Primary Port
        ],

        // 'sticky' keeps subsequent queries on the write connection during 
        // a single request to avoid reading stale data from replication lag
        'sticky'   => true,

        'database' => env('DB_DATABASE_A', 'app_tenant_a'),
        'username' => env('DB_USERNAME_A', 'app_user'),
        'password' => env('DB_PASSWORD_A', ''),
        'charset'  => 'utf8',
        'prefix'   => '',
        'sslmode'  => 'prefer',
    ],

    // ---------------------------------------------------
    // Tenant B Database Configuration
    // ---------------------------------------------------
    'tenant_b' => [
        'driver'   => 'pgsql',
        
        'read' => [
            'host' => env('DB_HOST_PROXY', 'haproxy'),
            'port' => env('DB_PORT_B_RO', 5102),
        ],
        'write' => [
            'host' => env('DB_HOST_PROXY', 'haproxy'),
            'port' => env('DB_PORT_B_RW', 5002),
        ],

        'sticky'   => true,
        'database' => env('DB_DATABASE_B', 'app_tenant_b'),
        'username' => env('DB_USERNAME_B', 'app_user'),
        'password' => env('DB_PASSWORD_B', ''),
        'charset'  => 'utf8',
        'prefix'   => '',
        'sslmode'  => 'prefer',
    ],
],
```

Laravel connects to the `tenant_a` or `tenant_b` configurations depending on which tenant context is active (handled by your tenancy logic). When it issues an `UPDATE` or `INSERT`, Laravel sends it to the `write` port mapping. When executing an initial `SELECT`, it sends it to the `read` mapping.

---
