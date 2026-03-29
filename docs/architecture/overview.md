# Architecture Overview

## Executive Summary

This document provides a high-level view of how the fourteen components in this R&D stack interconnect. It is intended as a companion map to the detailed component files and operational runbooks.

## Why This Matters (Business / Compliance Context)

A multi-component architecture diagram makes it straightforward to communicate risk scope to security auditors (ISO 27001 Annex A.14, SOC 2 CC6) and helps engineers trace failure blast radius during incident response. At a glance, a reader can see that encrypted data never leaves the database without passing through a Vault-managed key, and that WAL segments are backed up encrypted to MinIO.

## Full Stack Architecture Diagram

```mermaid
graph LR
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
    MINKMS -.->|"wraps key"| VAULT

    EXT -.->|"active on"| PG1
    EXT -.->|"active on"| PG2
```

## Component Dependency & Startup Order

The startup sequence matters because certain components depend on others being healthy:

```mermaid
sequenceDiagram
    participant etcd as etcd cluster (3 nodes)
    participant vault as HashiCorp Vault
    participant minkms as MinKMS
    participant minio as MinIO AIStor
    participant pg1 as postgres-one (Patroni)
    participant pg2 as postgres-two (Patroni)
    participant pgb as PgBouncer (in-container)

    etcd->>etcd: form quorum (3/3 nodes)
    vault->>vault: unseal / initialise
    minkms->>minkms: start KMS server
    minio->>minkms: connect SSE-KMS
    pg1->>etcd: wait until etcd healthy (30 retries × 2 s)
    pg1->>pg1: Patroni bootstraps PG, loads pg_tde
    pg1->>vault: register key provider, create master key
    pg1->>etcd: write cluster leader lock
    pgb->>pgb: start after pg_isready (background process)
    pg2->>etcd: discover leader
    pg2->>pg1: initiate base backup via tde_basebackup.sh
    pg2->>pg2: start streaming replication
```

## Network & Port Reference

| Service        | Host/Container   | Port(s)    | Protocol | Notes                              |
|----------------|------------------|------------|----------|------------------------------------|
| PostgreSQL     | postgres-one/two | 5432       | TCP      | pg_hba: md5 all 0.0.0.0/0          |
| PgBouncer      | postgres-one/two | 6432       | TCP      | transaction mode, md5 auth         |
| Patroni REST   | postgres-one/two | 8008       | HTTP     | cluster status, switchover API     |
| etcd client    | postgres-one/two, etcd3 | 2379       | HTTPS    | mTLS client + CA auth              |
| etcd peer      | postgres-one/two, etcd3 | 2380       | HTTPS    | mTLS peer auth                     |
| Vault          | vault            | 8200       | HTTP     | TLS disabled in dev/R&D mode       |
| MinKMS         | minkms           | 7373       | HTTPS    | mTLS using custom CA               |
| MinIO API      | minio            | 9000       | HTTPS    | S3-compatible                      |
| MinIO Console  | minio            | 9001       | HTTPS    | Web UI                             |

## Data Flow: Write Path (Encrypted)

```mermaid
flowchart LR
    WRITE["INSERT / UPDATE\nfrom application"] --> PGB["PgBouncer (Primary)\ntransaction pool"]
    PGB --> PG["PostgreSQL 18\npg_tde active"]
    PG -->|"encrypt page\nusing tde_heap"| HEAP["Encrypted heap file\n/data/db/base/..."]
    PG -->|"WAL segment\n(pg_tde.wal_encrypt=off\nencrypts data blocks)"| WAL["WAL stream"]
    WAL -->|"archive-push\npgBackRest"| MINIO["MinIO AIStor\nbucket: postgres-archive"]
    MINIO -->|"SSE-KMS wraps\nobject key"| MINKMS["MinKMS"]
    PG -->|"fetch data key"| VAULT["HashiCorp Vault\ntde/ KV v2"]
```

## Security Boundary Summary

| Boundary                         | Protection Mechanism                                       |
|----------------------------------|------------------------------------------------------------|
| Data at rest (heap files)        | pg_tde `tde_heap` — AES encryption, key in Vault          |
| Data in transit (replication)    | PostgreSQL SSL / mTLS etcd (WAL bytes unencrypted in stream) |
| Backup objects in MinIO          | SSE-KMS via MinKMS; TLS in transit                        |
| etcd cluster communication       | mTLS mutual auth with custom Root CA                       |
| Vault token exposure             | AppRole tokens stored in `/etc/postgresql/secrets/` (mode 600) |
| PgBouncer auth                   | md5 `userlist.txt`                                         |

## References & Further Reading

- [Patroni Architecture](https://patroni.readthedocs.io/en/latest/patroni_configuration.html)
- [etcd Security Model](https://etcd.io/docs/v3.5/op-guide/security/)
- [pg_tde Architecture — Percona](https://docs.percona.com/pg-tde/architecture.html)
- [pgBackRest Architecture](https://pgbackrest.org/user-guide.html#concept)
- [MinIO KMS Guide](https://min.io/docs/minio/linux/operations/server-side-encryption.html)
