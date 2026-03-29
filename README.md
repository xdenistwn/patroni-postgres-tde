# Patroni PostgreSQL TDE & High Availability Cluster

Welcome to the Patroni PostgreSQL Transparent Data Encryption (TDE) cluster project. This repository provides a complete, containerized environment for running a highly-available, fully encrypted PostgreSQL 18 cluster using Percona Distribution, HashiCorp Vault, MinIO, and etcd.

> ⚠️ **CRITICAL: READ THE DOCS FIRST** ⚠️
> This architecture is highly advanced and involves precise service-startup sequences, encryption sealing, and timeline restorations. 
> **You MUST read the documentation in the [`/docs`](./docs) directory before attempting to build, test, or operate this cluster.** 
> Start by reading the [Main Documentation Index](./docs/README.md) and the [Cluster Setup Order](./docs/operations/cluster-setup-order.md).

> ⚠️ This repository is currently under active development and constant improvement. It is primarily used for research and development purposes and may not be production-ready.
> ⚠️ All Certificates are self-signed, sensitive token, else are for development purposes only. nothing to worry.

## What is this project?
This repository is the culmination of extensive R&D to build a production-grade, containerized database stack where security and reliability are the absolute top priorities. 

**Core capabilities:**
- **Automated Failover**: Patroni handles primary election automatically using `etcd` as a distributed configuration store.
- **Secure Key Management**: Encryption master keys never touch the database disk. They are stored centrally in **HashiCorp Vault**.
- **Transparent Data Encryption (TDE)**: Tables are encrypted locally using the `tde_heap` access method powered by `pg_tde`.
- **Encrypted Replication & Backups**: Streaming WAL and pgBackRest basebackups are stored safely using SSE-KMS via **MinIO** and **MinKMS**.
- **Point-In-Time-Recovery (PITR)**: We feature complete, mathematically isolated PITR simulation pipelines to recover dropped tables or records reliably.

> **Note on Monitoring:** 
> Observability components are currently under development. In a future update, we will be integrating **Prometheus and Grafana** directly into this stack to provide live metric dashboards and alerting for the PostgreSQL cluster status.

## Feature Progress
| Feature | Status | Branch |
| :--- | :---: | :---: |
| Setup Postgres cluster with 2 nodes (Primary, Replica) + 3 etcd | ✅ | main |
| Apply `pg_tde` extension to postgres and integrate with HashiCorp Vault | ✅ | main |
| Support WAL/Basebackup encryption using `pg_tde_basebackup` and `pg_tde.wal_encrypt` | ✅ | main |
| Handle Master Key rotation | ✅ | main |
| PgBouncer layer implementation | ✅ | main |
| Archiving into Object Storage with SSE (S3, MinIO) | ✅ | main |
| Apply SSL/TLS between services | ✅ | main |
| Point-In-Time-Recovery (PITR) workflow and simulation | ✅ | main |
| **Monitoring (Prometheus, Grafana) integration** | ⏳ | *Coming Soon* |

## Quick Start
Do not blindly run these commands without reading the docs. The setup has a strict initialization order (Vault → MinKMS → MinIO → etcd → Postgres). 

1. Ensure Docker & Docker Compose (v2.x) are installed.
2. Review the `Makefile` and `.env` files in the root directory.
3. Read the required sequence in [`docs/operations/cluster-setup-order.md`](./docs/operations/cluster-setup-order.md) to initialize the Vault Transit keys and MinIO buckets safely.

---
*For detailed architecture diagrams, component breakdown, and operational runbooks, please proceed immediately to the [`/docs/README.md`](./docs/README.md) file.*