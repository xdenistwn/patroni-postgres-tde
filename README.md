# Percona Postgres HA with TDE, Patroni& HashiCorp Vault

After researching & trial error for about 2 weeks. Im proudly presenting this project provides a simple high-availability PostgreSQL cluster setup using **Patroni**, **etcd**, **pg_tde**, and **HashiCorp Vault**. It ensures that your data is encrypted at rest (TDE) and that encryption keys are securely managed in a centralized Vault instance.

## Overview

The architecture consists of:
- **PostgreSQL 18 (Percona Distribution)**: High-performance database engine.
- **Patroni**: Template for PostgreSQL High Availability.
- **etcd**: Distributed Configuration Store (DCS) for cluster coordination.
- **pg_tde**: Transparent Data Encryption extension for PostgreSQL.
- **HashiCorp Vault**: Secure storage and management of TDE master keys.

## Key Features
- **Automated HA Failover**: Patroni ensures minimal downtime.
- **Secure Key Management**: Vault handles all encryption keys via AppRole.
- **Encrypted Storage**: Tables are encrypted using the `tde_heap` access method.
- **WAL Encryption**: Transaction logs are also encrypted cluster-wide.
- **One-Click Setup**: Fully automated initialization of both database and security layers.

## Prerequisites
- Docker & Docker Compose (v2.x recommended)
- `jq` (installed automatically in containers)

## Getting Started

### 1. Configuration
Customize your credentials and Vault settings in the `.env` file:
```bash
# Example .env contents
VAULT_TOKEN="your-root-token"
DB_USER=your_user
DB_PASSWORD=your_secure_password
```

### 2. Launch the Cluster
The easiest way to start everything is using the provided setup script:
```bash
./scripts/setup-all.sh
```
*Note: This script will run `docker-compose up` and wait for all services to initialize. The TDE keys and database users are created automatically by specialized initialization containers.*

### 3. Verify Initialization
Monitor the logs to see the TDE setup progress:
```bash
docker logs -f pg-tde-init
```

## Using Encryption
Once the cluster is running, you can create encrypted tables using the `USING tde_heap` clause.

### Example:
Connect as the `snowball` user and run:
```sql
CREATE TABLE sensitive_customers (
    id SERIAL PRIMARY KEY,
    name TEXT,
    ssn TEXT
) USING tde_heap;

INSERT INTO sensitive_customers (name, ssn) 
VALUES ('John Doe', '123-456-7890');
```
*All data in `sensitive_customers` is now encrypted on disk.*

## Maintenance & Cleanup

### Full Cleanup
To stop everything and remove all data/volumes:
```bash
./cleanup.sh
```

## Notes
- I still maintaining this project for my own needs, so it might not be production-ready.
- You can custimize for your own needs.