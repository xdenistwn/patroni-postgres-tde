# Patroni PostgreSQL HA with TDE Work Order & Research Timeline

This document outlines the research phases and implementation tasks for the high-availability PostgreSQL cluster featuring Transparent Data Encryption (TDE), Partitioning, Archiving into Object Storage (MinIO Aistor, MinKMS), and Key Management integration.

## Implementation Roadmap (Bi-Weekly Research Cycles)

### Research Cycle 1: Infrastructure & HA Foundation
**Timeline:** 01 Jan 2026 - 14 Jan 2026
**Focus:** Patroni, etcd, and PostgreSQL Core environment setup.

| Task ID | Component | Description | Status |
|---|---|---|---|
| RC1-01 | Patroni/PG Research | Research how Patroni manages PostgreSQL failover and leader election via etcd. | ⬜ Todo |
| RC1-02 | etcd Foundation | Deploy and secure etcd cluster with TLS to serve as the Distributed Configuration Store (DCS). | ⬜ Todo |
| RC1-03 | Custom Build | Research and prepare custom PostgreSQL 18.x build with required extensions. | ⬜ Todo |

### Research Cycle 2: Security & KMS Deep-Dive
**Timeline:** 15 Jan 2026 - 28 Jan 2026
**Focus:** KMS integration, TLS security, and TDE initialization.

| Task ID | Component | Description | Status |
|---|---|---|---|
| RC2-01 | KMS / MinKMS | Research integration of HashiCorp Vault with MinKMS for master key management. | ⬜ Todo |
| RC2-02 | pg_tde Setup | Research `pg_tde` extension functionality and its binding to external KMS providers. | ⬜ Todo |
| RC2-03 | TLS Infrastructure | Establish the Root CA and generate internal certificates for secure inter-service communication. | ⬜ Todo |
| RC2-04 | Service Binding | Integrate Patroni bootstrap with `pg_tde` so instances initialize with encryption enabled. | ⬜ Todo |

### Research Cycle 3: Storage & Data Management
**Timeline:** 29 Jan 2026 - 11 Feb 2026
**Focus:** MinIO Object Storage, Partitioning logic, and Backup strategies.

| Task ID | Component | Description | Status |
|---|---|---|---|
| RC3-01 | Object Storage | Stand up MinIO Aistor and configure S3 buckets for database archiving and storage. | ⬜ Todo |
| RC3-02 | pg_partman | Research and implement `pg_partman` for managing large time-series data sets. | ⬜ Todo |
| RC3-03 | TDE-Partition Fix | Resolve the "heap vs tde_heap" issue to ensure all new partitions inherit TDE access methods. | ⬜ Todo |
| RC3-04 | Backup Strategy | Configure `pgBackRest` to leverage MinIO S3 for WAL and full database backups. | ⬜ Todo |

### Research Cycle 4: Chaos, Audit & Final Validation
**Timeline:** 12 Feb 2026 - 25 Feb 2026
**Focus:** Disaster Recovery validation, Security audits, and Performance benchmarking.

| Task ID | Component | Description | Status |
|---|---|---|---|
| RC4-01 | Failover Chaos | Execute forced failover tests and evaluate "Split-Brain" prevention and recovery time. | ⬜ Todo |
| RC4-02 | Key Rotation | Implement and verify automated master key rotation without service interruption. | ⬜ Todo |
| RC4-03 | Disk Audit | Verify data-at-rest encryption status using OS-level inspection of physical blocks. | ⬜ Todo |
| RC4-04 | Benchmarking | Run performance benchmarks on encrypted vs. non-encrypted tables to measure overhead. | ⬜ Todo |
