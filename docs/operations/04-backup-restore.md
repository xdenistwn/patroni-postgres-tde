# Operations Runbook — Backup & Restore (PITR)

## Executive Summary

Backing up an encrypted PostgreSQL cluster requires a specific approach: PostgreSQL uses `pgBackRest` to push base backups and continuous Write-Ahead Log (WAL) streams to MinIO object storage. The critical distinction is that the data inside the backups remains encrypted by `pg_tde`. The backup object itself is further encrypted by MinKMS in MinIO (SSE-KMS).

Point-In-Time Recovery (PITR) allows database administrators to restore the entire cluster to the exact state it was in right before an unwanted transaction (e.g., a bad TRUNCATE or accidental drop).

## Why This Matters (Business / Compliance Context)

Having a verifiable backup and restore process is the primary mechanism for meeting Recovery Point Objectives (RPO) and Recovery Time Objectives (RTO). It directly satisfies:
- **ISO 27001 A.12.3.1:** Information backup.
- **GDPR Article 32(1)(c):** Ability to restore the availability and access to personal data in a timely manner.
- **SOC 2:** Availability Principle.

## 1. Initialising the Backup Stanza

Before the first backup can be taken, or any WAL can be securely archived, the pgBackRest "stanza" (the backup configuration specific to this database cluster) must be initialised. This typically happens during cluster bootstrap.

### Prerequisites

- MinIO must be running and the `postgres-archive` bucket must exist.
- Patroni must have elected a leader.
- `pgbackrest.conf` must have the correct S3 credentials and endpoint configured on all nodes.

### Procedure

```bash
# Finds the primary node and executes stanza-create
./scripts/pgbackrest_setup_stanza.docker.sh

# Verify the stanza status
docker exec -t postgres-one pgbackrest --stanza=postgres-patroni-tde check
```
*Expected: The `check` command will create a test file in MinIO and verify it can be read back.*

---

## 2. Taking Manual Backups

The R&D stack uses a helper script (`scripts/pgbackrest_backup.docker.sh`) to automatically find the Patroni leader and run the correct pgBackRest command.

There are three types of backups:
1. **Full:** Copies all data cluster files. Slowest, largest, but standalone.
2. **Differential (diff):** Copies only files changed since the last *Full* backup. Must be restored alongside that Full backup.
3. **Incremental (incr):** Copies only files changed since the *last* backup of any type. Fastest, smallest, but requires a longer chain to restore.

### Command Examples

```bash
# Take a Full backup (Run this immediately after bootstrapping the cluster)
./scripts/pgbackrest_backup.docker.sh full

# Take a Differential backup (Typically run daily)
./scripts/pgbackrest_backup.docker.sh diff

# Take an Incremental backup (Typically run every few hours)
./scripts/pgbackrest_backup.docker.sh incr

# View Backup History and Status
docker exec postgres-one pgbackrest --stanza=postgres-patroni-tde info
```

See `BACKUP_SCHEDULING.md` for recommendations on production cron scheduling.

---

## 3. Point-In-Time Recovery (PITR)

A PITR operation restores the database from the last base backup, then replays the WAL files up to the exact timestamp you specify. 

**WARNING:** Restoring over the primary data directory is destructive. In a production scenario, you would typically restore to a *new* standby cluster to verify the data, then perform a switchover. 

This guide demonstrates restoring into a stopped node, assuming a complete failure or a dedicated recovery instance.

### Prerequisites

- The target node must have the exact same Vault token and Vault availability as the original cluster, because the restored heap files are encrypted with `pg_tde` keys. If Vault is unavailable, the restore will succeed, but PostgreSQL will fail to start.
- The PostgreSQL process on the target node must be gracefully stopped.

### Procedure (Restoring to a Specific Time)

1. **Identify the Target Timestamp:**
   Find the exact time you want to restore to. Look at application logs or `pgAudit` to find the bad transaction time. Let's assume `2026-03-20 14:00:00+07`.

2. **Stop Patroni / PostgreSQL on the target node:**
   ```bash
   docker exec -it postgres-one patronictl -c /etc/patroni/patroni.yml pause
   docker exec -it postgres-one pg_ctl stop -D /data/db -m fast
   ```

3. **Execute the Restore Command:**
   Instruct pgBackRest to restore using `--type=time` and `--target`. The `--target-action=promote` flag tells PostgreSQL to stop recovery at that time and open the database for reads/writes.
   
   ```bash
   # Run from inside the target container
   docker exec -it postgres-one \
     pgbackrest --stanza=postgres-patroni-tde \
     --type=time "--target=2026-03-20 14:00:00+07" \
     --target-action=promote \
     restore
   ```
   
   *Note: pgBackRest will automatically clean the existing `data_dir` and pull down the closest full backup, then setup a `recovery.signal` file containing the target parameters.*

4. **Start PostgreSQL / Resume Patroni:**
   Start the database to begin WAL replay.
   ```bash
   docker exec -it postgres-one patronictl -c /etc/patroni/patroni.yml resume
   ```

5. **Verify the Recovery:**
   Watch the PostgreSQL logs. You will see lines indicating WAL files are being fetched from MinIO via `archive_get`, replayed, and then `recovery stopping at restore point stamp "... 14:00:00"`.
   ```bash
   docker logs -f postgres-one
   ```

## Troubleshooting Backup & Restore

- **`WAL segment missing` during Backup or WAL Archiving:**
  If the network to MinIO was down for a long time, the primary may have rotated the WAL segment before pgBackRest could upload it. This breaks the PITR chain. You must run a new Full backup immediately.
  
- **Restore fails with S3 TLS error:**
  Ensure `repo1-storage-verify-tls=n` is set if using self-signed certs (R&D), or `repo1-storage-ca-file` is correctly mapped if verifying TLS in production.

- **Restore completes, but PostgreSQL fails to start: "pg_tde vault provider missing":**
  The `pg_tde` master key cannot be retrieved. Ensure Vault is online and the `/etc/postgresql/secrets/vault_token.txt` is mounted and valid.

## References

- [pgBackRest Restore Command](https://pgbackrest.org/user-guide.html#restore)
- [scripts/pgbackrest_setup_stanza.docker.sh](../../scripts/pgbackrest_setup_stanza.docker.sh)
- [scripts/pgbackrest_backup.docker.sh](../../scripts/pgbackrest_backup.docker.sh)
- [BACKUP_SCHEDULING.md](../../BACKUP_SCHEDULING.md)
