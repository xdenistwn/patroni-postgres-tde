# PostgreSQL Infrastructure Research Documentation

## Overview

This documentation covers a production-grade PostgreSQL 18 high-availability (HA) stack built for R&D purposes on aarch64 / RHEL 9 (containerised via Docker). The architecture combines Patroni-managed leader election over a TLS-secured etcd cluster, Percona's transparent data encryption (pg_tde), MinIO AIStor object storage backed by MinKMS, and HashiCorp Vault for secrets management — resulting in a fully encrypted, auditable, and highly available database platform. Non-technical readers can find a plain-language executive summary at the top of each component file; engineers will find precise configuration listings, known issues, and operational runbooks throughout.

## Stack Architecture

```mermaid
graph TD
    subgraph "Client Tier"
        APP["Application\n(any language)"]
        BENCH["pgBench\nbenchmarking"]
    end

    subgraph "VM: PostgreSQL + etcd + PgBouncer Node 1"
        direction TB
        PGB1["PgBouncer\nport 6432  (write/read)"]
        PG1["postgres-one\n(Patroni Leader)\nport 5432  Patroni API 8008"]
        E1["etcd1\nport 2379/2380\nmTLS"]
    end

    subgraph "VM: PostgreSQL + etcd + PgBouncer Node 2"
        direction TB
        PGB2["PgBouncer\nport 6432  (read-only)"]
        PG2["postgres-two\n(Patroni Replica)\nport 5432  Patroni API 8008"]
        E2["etcd2\nport 2379/2380\nmTLS"]
    end

    subgraph "VM: etcd Witness Node"
        E3["etcd3\nport 2379/2380\nmTLS"]
    end

    PG1 -- "Streaming Replication\nWAL shipping" --> PG2

    subgraph "Key Management"
        VAULT["Vault :8200"]
        MINKMS["MinKMS :7373"]
    end

    subgraph "Object Storage"
        MINIO["MinIO AIStor\nport 9000 API  9001 Console\nbucket: postgres-archive\nSSE-KMS enabled"]
    end

    EXT["PostgreSQL Extensions:\npg_tde, pg_partman, pg_cron\npg_repack, pg_stat_monitor\npgAudit, pgBackRest"]

    APP -->|"write/read"| PGB1
    APP -->|"read-only"| PGB2
    BENCH -->|"write/read"| PGB1
    PGB1 --> PG1
    PGB2 --> PG2

    PG1 <-->|"leader election\nLock / TTL=30s"| E1
    PG1 <-->|"heartbeat"| E2
    PG1 <-->|"heartbeat"| E3
    PG2 <-->|"DCS watch"| E1
    PG2 <-->|"DCS watch"| E2
    PG2 <-->|"DCS watch"| E3

    PG1 -->|"key provider"| VAULT
    PG2 -->|"key provider"| VAULT

    PG1 -->|"archive-push\npgBackRest"| MINIO
    PG2 -->|"archive-get"| MINIO

    MINIO -->|"SSE-KMS"| MINKMS
    MINKMS -->|"Transit seal-wrap\n(startup only)"| VAULT

    EXT -.->|"active on"| PG1
    EXT -.->|"active on"| PG2
```

## Component Index

| # | Component              | File                                               | Purpose                                    | Version / Source              |
|---|------------------------|----------------------------------------------------|--------------------------------------------|-------------------------------|
| 1 | PostgreSQL 18          | [01-postgresql.md](components/01-postgresql.md)   | Core database engine                        | 18.1 — Percona Distribution   |
| 2 | pg_tde                 | [02-pg_tde.md](components/02-pg_tde.md)           | Transparent Data Encryption                | Percona pg_tde                |
| 3 | PgBouncer              | [03-pgbouncer.md](components/03-pgbouncer.md)     | Connection pooling                          | percona-pgbouncer             |
| 4 | pg_partman             | [04-pg_partman.md](components/04-pg_partman.md)   | Partition management                        | pg_partman_18 (PGDG)          |
| 5 | pg_cron                | [05-pg_cron.md](components/05-pg_cron.md)         | Job scheduling inside PostgreSQL            | pg_cron_18 (PGDG)             |
| 6 | pg_repack              | [06-pg_repack.md](components/06-pg_repack.md)     | Online table/index bloat removal            | percona-pg_repack18           |
| 7 | Patroni                | [07-patroni.md](components/07-patroni.md)         | HA cluster management & leader election     | pip patroni[etcd3]            |
| 8 | etcd                   | [08-etcd.md](components/08-etcd.md)               | Distributed configuration store (DCS)       | quay.io/coreos/etcd:v3.5.16   |
| 9 | MinIO / AIStor / MinKMS| [09-minio-aistor-minkms.md](components/09-minio-aistor-minkms.md) | Object storage & KMS       | quay.io/minio/aistor images   |
|10 | HashiCorp Vault        | [10-vault.md](components/10-vault.md)             | Secrets management (pg_tde keys, tokens)    | hashicorp/vault:1.21          |
|11 | pgBench                | [11-pgbench.md](components/11-pgbench.md)         | Performance benchmarking                    | Built-in PostgreSQL tool      |
|12 | pgBackRest             | [12-pgbackrest.md](components/12-pgbackrest.md)   | Backup & Point-In-Time Recovery             | percona-pgbackrest            |
|13 | pg_stat_monitor        | [13-pg_stat_monitor.md](components/13-pg_stat_monitor.md) | Query performance analytics         | PGDG — pg_stat_monitor_18     |
|14 | pgAudit                | [14-pgaudit.md](components/14-pgaudit.md)         | Audit logging                               | postgresql-18-audit (PGDG)    |
|15 | Prometheus / Grafana   | *Integration Pending*                             | Cluster status, logs, & telemetry monitoring| *Coming Soon*                 |
|16 | PITR Simulation        | [pitr-simulation.md](operations/pitr-simulation.md) | Disaster recovery via isolated WAL replay   | Operational Runbook           |

## How to Read This Documentation

Each component file in `docs/components/` is structured with two layers:

1. **Executive Summary & Why This Matters** — at the top of every file. Written in plain language for non-technical stakeholders; explains what the component does and why the organisation needs it, with a reference to relevant compliance frameworks where applicable.
2. **Technical Detail sections** — follow the executive summary. These include actual configuration snippets lifted directly from the project files, key parameter explanations, integration points with other components, known issues discovered during R&D, and operational notes (health checks, diagnostic queries).

Runbooks for high-impact operational procedures (failover, backup/restore, key rotation, PITR) are located in `docs/operations/`:

- **[Cluster Setup Order](operations/cluster-setup-order.md)** — The most important starting point for a fresh environment. It documents the exact service startup order (Vault → MinKMS → MinIO → etcd → PostgreSQL) and mandatory post-start configurations.
- **[Point-In-Time-Recovery (PITR) Simulation](operations/pitr-simulation.md)** — A rigorous procedural workflow proving how to safely recover an accidentally dropped table natively via pgBackRest WAL replay using an isolated Patroni container.

Performance benchmark reference data is in `docs/benchmarks/`.

## Environment Summary

| Property              | Value                                                            |
|-----------------------|------------------------------------------------------------------|
| OS / Architecture     | RHEL 9 / aarch64 (arm64); x86_64 Dockerfile also provided       |
| Deployment model      | Docker Compose (multi-container, external `pg_network`)          |
| PostgreSQL version    | 18.1 (Percona Distribution)                                     |
| HA topology           | 1 leader (`postgres-one` + etcd1) + 1 replica (`postgres-two` + etcd2) |
| DCS                   | etcd v3.5.16 — 3-node cluster (co-located etcd1/2, separate etcd3)  |
| Encryption            | pg_tde with `tde_heap` access method; `default_table_access_method = tde_heap` |
| Key provider          | HashiCorp Vault — KV v2 (`pg_tde/`) for pg_tde; Transit engine for MinKMS seal-wrap |
| Connection pooler     | PgBouncer in `transaction` mode on port 6432                    |
| Backup repository     | MinIO AIStor (S3-compatible), bucket `postgres-archive`         |
| WAL archiving         | Enabled; `archive_command` uses pgBackRest                      |
| Stanza name           | `postgres-patroni-tde`                                           |
| Timezone              | Asia/Jakarta                                                     |
| TLS                   | mTLS everywhere — etcd client/peer, Patroni↔etcd, pgBackRest↔MinIO |

## References & Further Reading

- [Percona Distribution for PostgreSQL](https://www.percona.com/software/postgresql-database)
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [etcd Documentation](https://etcd.io/docs/)
- [pgBackRest User Guide](https://pgbackrest.org/user-guide.html)
- [HashiCorp Vault Docs](https://developer.hashicorp.com/vault/docs)
- [MinIO AIStor](https://min.io/product/aistor)
- [pg_tde — Percona](https://docs.percona.com/pg-tde/)
