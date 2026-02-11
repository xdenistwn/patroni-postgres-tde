## Description
After extensive research and trial-and-error over the past two weeks, I am presenting this repository which provides a simple high-availability PostgreSQL cluster setup using Patroni, etcd, pg_tde, and HashiCorp Vault in container. It ensures that your data is encrypted at rest (TDE) and that encryption keys are securely managed in a centralized Vault instance.
> ⚠️ This repository is currently under active development and constant improvement. It is primarily used for research and development purposes and may not be production-ready.

## Overview
The architecture consists of:
- **PostgreSQL 18 (Percona Distribution)**: High-performance database engine with `pg_tde` built-in.
- **Patroni**: Template for PostgreSQL High Availability.
- **etcd**: Distributed Configuration Store (DCS) for cluster coordination and leader election.
- **pg_tde**: Transparent Data Encryption extension that offloads key management to an external provider.
- **HashiCorp Vault**: Secure centralized storage for TDE master keys.
- **PgBouncer**: Lightweight connection pooler for PostgreSQL.

## Key Features
- **Automated Failover**: Patroni manages the cluster state and handles primary election automatically.
- **Centralized Key Management**: Master keys never touch the database disk; they live inside Vault.
- **Transparent Encryption**: Tables are encrypted using the `tde_heap` access method.
- **Encrypted Replication**: Both WAL and basebackups are encrypted using `pg_tde` during streaming.
- **Connection Pooling**: PgBouncer manages connection pooling to reduce database overhead and improve performance.

## Prerequisites
- **Docker & Docker Compose**: v2.x or higher recommended.
- **Environment Config**: A configured `.env` file based on the provided variables.

## Feature Progress
| Feature | Status | branch |
| :--- | :---: | ---: |
| Setup Postgres cluster with 2 nodes (Primary, Replica) + 3 etcd | ✅ | main |
| Apply `pg_tde` extension to postgres and integrated with HashiCorp Vault | ✅ | main |
| Support WAL/Basebackup encryption using `pg_tde_basebackup` and `pg_tde.wal_encrypt` | ✅ | main |
| Handle Master Key rotation | ✅ | main |
| PgBouncer layer implementation | ✅ | main |
| Archiving into Object Storage (S3, MinIO) | - | - |
| Monitoring (Prometheus, Grafana) | - | - |
| Apply SSL/TLS between services | - | - |

### Setup
1. Clone the repository:
```bash
git clone https://github.com/your-username/patroni-postgres-tde.git
cd patroni-postgres-tde
```

2. Copy the example environment file and modify it as needed:
```bash
cp .env.example .env
vi .env
```

3. Build image:
```bash
docker-compose -f dockerfiles/postgres/docker-compose.build.yml build
```

4. Start cluster:
```bash
./scripts/run-cluster.sh
```
