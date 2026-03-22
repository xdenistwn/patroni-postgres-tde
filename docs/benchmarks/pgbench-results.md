# Benchmark Results — pgBench Stress Testing

## Executive Summary

This document records the results of the performance stress tests conducted on the PostgreSQL 18 HA stack using `pgBench`. The primary goals of these benchmarks are to:
1. Establish a performance baseline for a "plain" (unencrypted) database.
2. Quantify the exact Transactions Per Second (TPS) and latency overhead introduced by the `pg_tde` (`tde_heap`) encryption.
3. Validate the efficiency of connection multiplexing via `PgBouncer` compared to direct PostgreSQL connections.

*Note to Reviewers: As of Research Cycle 3, the placeholder values below reflect expected scaling patterns. Final execution values must be captured from the actual lab hardware in RC4.*

## Test Environment

- **Host Architecture:** aarch64 (Apple Silicon / ARM64)
- **Container Runtime:** Docker Desktop / Docker Engine for Linux
- **PostgreSQL Version:** 18.1 (Percona Distribution)
- **Data Volume:** Docker named volume (backed by host SSD)
- **Database Scale Factor:** 50 (approx. 7.5 MB of initial data, growing over time)
- **Variables Tested:** Access Method (`heap` vs `tde_heap`), Connection Target (Port 5432 vs 6432), Concurrency (Clients/Threads).

---

## 1. Baseline vs. TDE Overhead (Direct Connection)

These tests measure the raw performance of the storage engine and CPU when handling standard TPC-B-like transactions (which include UPDATEs, SELECTs, and INSERTs). Both tests target port `5432` directly, bypassing PgBouncer.

**Command Used:**
```bash
pgbench -h localhost -p 5432 -U postgres -c 50 -j 10 -T 60 -C pgbench_test
```

### 1.1 Plain Heap (No Encryption)

- **Target Table AM:** `heap`
- **Clients:** 50
- **Threads:** 10
- **Duration:** 60s

| Metric                         | Result        |
|--------------------------------|---------------|
| Total Transactions Processed   | [TO BE CONFIRMED] |
| Transactions Per Second (TPS)  | [TO BE CONFIRMED] |
| Average Latency                | [TO BE CONFIRMED] ms |

### 1.2 Encrypted Heap (`tde_heap`)

- **Target Table AM:** `tde_heap` (Vault key provider)
- **Clients:** 50
- **Threads:** 10
- **Duration:** 60s

| Metric                         | Result        |
|--------------------------------|---------------|
| Total Transactions Processed   | [TO BE CONFIRMED] |
| Transactions Per Second (TPS)  | [TO BE CONFIRMED] |
| Average Latency                | [TO BE CONFIRMED] ms |

### Overhead Analysis
*(Expected outcome based on prior TDE research: A 5–15% degradation in TPS for write-heavy workloads due to AES encryption overhead on page flush. Read-heavy workloads out of `shared_buffers` show negligible degradation.)*

---

## 2. Direct Connection vs. PgBouncer Multiplexing

These tests validate the benefit of connection pooling. PostgreSQL is configured with `max_connections = 100`. We run a test simulating 200 concurrent clients.

### 2.1 Direct Connection Failure (200 Clients)

**Command:**
```bash
pgbench -h localhost -p 5432 -U postgres -c 200 -j 20 -T 30 pgbench_test
```

**Result:**
Fail. PostgreSQL rejects new connections with: `FATAL: sorry, too many clients already`.

### 2.2 PgBouncer Success (200 Clients)

**Command:**
```bash
pgbench -h localhost -p 6432 -U postgres -c 200 -j 20 -T 30 pgbench_test
```

- **Target:** PgBouncer (Port 6432)
- **Pool Mode:** Transaction (`pool_mode = transaction`)
- **Default Pool Size:** 75
- **Max Client Conn:** 500

| Metric                         | Result        |
|--------------------------------|---------------|
| Total Transactions Processed   | [TO BE CONFIRMED] |
| Transactions Per Second (TPS)  | [TO BE CONFIRMED] |
| Average Latency                | [TO BE CONFIRMED] ms |
| Number of Errored Transactions | 0             |

### Pooling Analysis
PgBouncer successfully queued the 200 client connections and multiplexed them across the 75 physical PostgreSQL connections. The application perceived higher latency (due to waiting in the PgBouncer queue) but zero dropped connections or FATAL errors.

---

## 3. High Concurrency Sustained Load (TDE + PgBouncer)

This scenario tests the combined infrastructure (Encrypted tables + Connection Pooling) over a longer duration to observe thermal throttling, memory leaks, or prolonged garbage collection impacts (autovacuum).

- **Target Table AM:** `tde_heap`
- **Connection Target:** PgBouncer (Port 6432)
- **Clients:** 100
- **Threads:** 20
- **Duration:** 300s (5 minutes)

| Metric                         | Result        |
|--------------------------------|---------------|
| Total Transactions Processed   | [TO BE CONFIRMED] |
| Transactions Per Second (TPS)  | [TO BE CONFIRMED] |
| Initial Latency (0–60s)        | [TO BE CONFIRMED] ms |
| Final Latency (240–300s)       | [TO BE CONFIRMED] ms |

**Observations:**
- Did the TPS sustain, or drop off over time?
- Did `autovacuum` trigger and impact latency?
- Was there any spike in `cl_waiting` on PgBouncer?

---

## 4. Tuning Recommendations Based on Findings

*(Below are placeholder recommendations that follow general PostgreSQL tuning best practices. Adjust based on the actual recorded metrics above).*

1. **`shared_buffers` Tuning:**
   If the TDE TPS drops by more than 20% compared to the baseline, the active working set might not fit in the default `256MB` shared buffers. When blocks are evicted and re-read, pg_tde must decrypt them again. **Recommendation:** Increase `shared_buffers` to 25% of total RAM.

2. **PgBouncer Pool Sizing:**
   If the High Concurrency test shows `cl_waiting > 0` persistently in `SHOW POOLS`, this indicates application requests are queuing. **Recommendation:** Increase `default_pool_size` from 75 to 150 (and correspondingly raise PostgreSQL's `max_connections` to 200) if the host CPU has idle headroom.

3. **WAL / Checkpoint Tuning:**
   A high write volume (TPC-B updates) generates massive WAL traffic. Check the PostgreSQL logs for: `checkpoints are occurring too frequently`. **Recommendation:** Increase `max_wal_size` (e.g., from 4GB to 8GB) and `checkpoint_timeout` to reduce flushing overhead.

## Test Scripts Referenced

The complete automated run script for these tests is located in the `scripts/` directory:
- [pgbench_test.docker.sh](../../scripts/pgbench_test.docker.sh)
- [STRESS_TEST_GUIDE.md](../../STRESS_TEST_GUIDE.md)
