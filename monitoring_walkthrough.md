# Observability & Monitoring Walkthrough

This guide details the newly deployed Prometheus + Grafana monitoring infrastructure for the Patroni PostgreSQL TDE cluster.

---

## 1. Directory Structure Created

A clean, modular structure has been deployed across the workspace:

*   **Central Observability Stack:** Managed under the `monitoring/` directory, containing Grafana, Prometheus, and the database metric scraper sidecars (`postgres-exporter-one` & `two`, `pgbouncer-exporter-one` & `two`).
*   **Database Master Node Host:** The host running the `postgres-one` database. A dedicated sidecar `node-exporter-one` container runs directly inside the **network namespace** of the `postgres-one` database, exposing host system metrics at `postgres-one:9100`.
*   **Database Replica Node Host:** The host running the `postgres-two` database. A dedicated sidecar `node-exporter-two` container runs directly inside the **network namespace** of the `postgres-two` database, exposing host system metrics at `postgres-two:9100` (mapped to host port `9101`).

```
monitoring/
├── docker-compose.yml          # Prometheus, Grafana, and DB metric scrapers
├── .env                        # Central stack and exporter DSN configurations
├── postgres_exporter/
│   └── queries.yaml            # Custom pg_stat_monitor queries
├── prometheus/
│   └── prometheus.yml          # Scrape target rules (points node scrapers to DB hosts)
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── prometheus.yml  # Auto-configures Prometheus datasource
    │   └── dashboards/
    │       └── dashboards.yml  # Auto-scans local JSON directory
    └── dashboards/
        ├── postgres-server.json        # OS/System metrics dashboard JSON
        ├── postgres-cluster.json       # DB engine and replication/cluster metrics JSON
        └── postgres-performance.json   # Connection pool, query stats & bgwriter metrics JSON
```

Additionally:
*   [postgres/monitoring_setup.sql](file:///Users/deni/Projects/research/patroni-postgres-tde/postgres/monitoring_setup.sql) has been created to bootstrap roles.
*   The root [Makefile](file:///Users/deni/Projects/research/patroni-postgres-tde/Makefile) has been updated with `up-monitoring`, `down-monitoring`, `logs-monitoring`, and `status-monitoring` lifecycle commands for the central stack.
*   The PgBouncer configs on `master` and `replica` have been updated with `monitor_user` listed in `stats_users` and credentials added to `userlist.txt`.

---

## 2. Deployment Steps

Follow these three simple steps to start monitoring:

### Step 2.1: Create the Database User
Connect to your active PostgreSQL Master container (e.g. `postgres-one`) and run the setup SQL as superuser (`postgres`):

```bash
docker exec -i postgres-one psql -U postgres < postgres/monitoring_setup.sql
```

This will:
1.  Create the `monitor_user` with password `monitor_password_secure`.
2.  Grant the system-level `pg_monitor` role for engine metrics.
3.  Grant SELECT permissions on `pg_stat_monitor` catalogs for query auditing.

---

### Step 2.2: Launch the Observability Infrastructure
Bring up the database containers (which now launch their system sidecars in their network namespace) and then launch the central monitoring servers:

```bash
# Start your master and replica database stacks (includes node_exporter sidecars)
make up-master
make up-replica-one

# Start the central monitoring servers and DB scrapers
make up-monitoring
```

This will launch:
*   **Prometheus** (`http://localhost:9090`)
*   **Grafana** (`http://localhost:3000`)
*   **postgres-exporter-one** & **two** (database metrics scrapers)
*   **pgbouncer-exporter-one** & **two** (connection pool scrapers)
*   **node-exporter-one** & **two** (scraped directly from `postgres-one:9100` and `postgres-two:9100`)

---

### Step 2.3: Access Grafana Dashboards
1.  Open your browser and navigate to: `http://localhost:3000`
2.  Log in using default credentials:
    *   **Username:** `admin`
    *   **Password:** `admin`
3.  **Three dedicated, production-grade dashboards** are automatically loaded and pre-provisioned:
    *   **"PostgreSQL Server Dashboard"**: Audits OS/System resources (CPU, Memory, Disk, Network, Load via `node_exporter`).
    *   **"PostgreSQL Patroni Cluster Dashboard"**: Audits database engine health, transactional activity, replication slots, WAL output, and Patroni status.
    *   **"PostgreSQL Performance & Components Dashboard"**: Audits PgBouncer pool connections, `pg_stat_monitor` slow query leaderboards, bgwriter/checkpointer, and pg_audit logs.
4.  Use the dropdown variables at the top of the dashboards to toggle between `postgres-one` and `postgres-two` dynamically!

---

## 3. Dashboards Breakdown

The three split dashboards categorize metrics cleanly:

### 1. PostgreSQL Server Dashboard
*   **Focus:** Core hardware resources of the PostgreSQL nodes.
*   **Key Panels:** CPU Usage by Mode, Memory Usage Gauge, Disk Space Usage %, Memory Breakdown, Disk I/O Throughput, Network I/O Throughput, System Load Averages.
*   **Source:** `node_exporter` targets.

### 2. PostgreSQL Patroni Cluster Dashboard
*   **Focus:** Engine availability, Patroni cluster replication status, WAL activity.
*   **Key Panels:** PostgreSQL Status (UP/DOWN), Uptime, Active Connections, Total Databases, Max Transaction Duration, Connections by State, Transactions per Second (TPS), Rows per Second by Operation, Deadlock Counts, Block Cache Hit Ratio, Database Disk Sizes, Lock Counts, Replication Lag, replica list table.
*   **Source:** `postgres_exporter` targets.

### 3. PostgreSQL Performance & Components Dashboard
*   **Focus:** Query optimization, connection pooling pools, checkpointers.
*   **Key Panels:** Top 10 slowest queries, QPS throughput, query wait time, PgBouncer active/waiting client pools, active/idle server pools, pool throughput, query latency via pools, checkpoint frequency, checkpointer write ratios, pg_audit notification logs.
*   **Source:** `pgbouncer_exporter`, `postgres_exporter` (queries), `pg_stat_monitor`.

---

## 4. Troubleshooting and Verification

*   **Check prometheus target status:**
    Navigate to `http://localhost:9090/targets` to verify all 6 exporter target streams are marked green and `UP`.
*   **Inspect logs:**
    Run `make logs-monitoring` to inspect streaming logs across exporters, Prometheus, and Grafana containers.
*   **Check container health:**
    Run `make status-monitoring` to confirm all 7 observability stack containers are running normally.
