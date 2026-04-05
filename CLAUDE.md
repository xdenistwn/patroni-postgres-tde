# Patroni PostgreSQL TDE Operations Guide

This guide provides specialized instructions and workflows for managing the Patroni-based PostgreSQL HA cluster with Transparent Data Encryption (TDE) via `pg_tde`, HashiCorp Vault, and pgBackRest on MinIO.

## Core Mandates

- **mTLS Everywhere**: All communication between components (etcd, Patroni, pgBackRest, MinIO) must be TLS-secured.
- **TDE Compliance**: Ensure all new tables use `tde_heap` access method. `default_table_access_method` should be set to `tde_heap` in Patroni DCS.
- **Boot Order**: Services must be started in order: Vault -> MinKMS -> MinIO -> etcd -> PostgreSQL/Patroni.
- **Secrets Management**: Never log Vault tokens or TDE master keys. Use `vault_token.txt` for container-level access.

## Operational Workflows

### 1. Cluster Status & Health
- Use `./scripts/patroni_cluster_status.sh` to check the current leader and replica status.
- Monitor etcd health via `etcdctl` (requires mTLS certs from `etcd/nodeX/certs/`).

### 2. Encryption (pg_tde & Vault)
- **Key Rotation**: Use `./scripts/pgtde_rotate_master_keys.docker.sh` to rotate TDE master keys in Vault.
- **Vault Status**: Ensure Vault is unsealed. Configuration is in `vault/`.
- **Query Setup**: Use `postgres/pg_tde_query_setup.sample.sql` for initial TDE configuration in a database.

### 3. Backup & Recovery (pgBackRest & MinIO)
- **Manual Backup**: Run `./scripts/pgbackrest_backup.docker.sh` to trigger a backup to MinIO.
- **Stanza Setup**: Use `./scripts/pgbackrest_setup_stanza.docker.sh` for initial stanza creation on MinIO.
- **PITR**: Refer to `docs/operations/pitr-simulation.md` for point-in-time recovery procedures.

### 4. Connection Pooling (PgBouncer)
- Clients should connect via PgBouncer on port `6432`.
- Configuration files are located in `postgres/master/pgbouncer/` and `postgres/replica_one/pgbouncer/`.

### 5. Extension Management
- Extensions `pg_tde`, `pg_partman`, `pg_cron`, `pg_repack`, `pg_stat_monitor`, `pgAudit` are available.
- See `postgres/*.sample.sql` for specific setup examples (e.g., `pg_partman_setup_encrypt.sample.sql`).

## Maintenance Commands

| Task | Command / Script |
|------|------------------|
| Initial Setup | `./scripts/postgres_setup.docker.sh` |
| Generate TLS | `./scripts/generate_tls_cert.sh` |
| Benchmark | `./scripts/pgbench_test.docker.sh` |
| PGBouncer Ping | `./scripts/pgbouncer_ping_test.docker.sh` |
| Patroni Status | `./scripts/patroni_cluster_status.sh` |

## Troubleshooting
- **Patroni Logs**: `docker logs postgres-one` or `docker logs postgres-two`.
- **Vault Connectivity**: Verify `vault_token.txt` in the respective postgres directories.
- **MinIO Access**: Ensure `pgbackrest-policy.json` is correctly applied.
- **TLS Issues**: Check cert expiration and CA matching using `openssl x509 -text -noout -in <cert>`.
