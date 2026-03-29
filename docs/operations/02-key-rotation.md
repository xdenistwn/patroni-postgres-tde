# Operations Runbook — Key Rotation

## Executive Summary

Key rotation is the process of generating a new Master Encryption Key (MEK) and re-encrypting the local Data Encryption Keys (DEKs) that protect your database heap files and backups. This R&D environment supports two distinct key rotation procedures:

1. **pg_tde Master Key Rotation**: Rotating the key stored in HashiCorp Vault that encrypts all `tde_heap` tables inside PostgreSQL.
2. **MinIO SSE-KMS Key Rotation**: Rotating the key managed by MinKMS that encrypts the pgBackRest backup objects stored in the `postgres-archive` bucket.

Both operations are online and transparent to the application. They DO NOT require decrypting and re-encrypting the entire database or all historical backups — only the wrapped DEKs are rotated.

## Why This Matters (Business / Compliance Context)

Routine key rotation limits the amount of data encrypted by a single key, reducing the "blast radius" if a key is compromised. It is a strict requirement under:
- **PCI-DSS Requirement 3.6.4**: Cryptographic key changes for keys that have reached the end of their cryptoperiod.
- **ISO 27001 A.10.1.2**: Formal lifecycle management for cryptographic keys.
- **NIST SP 800-57**: Guidelines for Key Management.

## 1. pg_tde Master Key Rotation (Vault)

This process uses the automated script `scripts/pgtde_rotate_master_keys.docker.sh`.

### Prerequisites

- The PostgreSQL cluster must be healthy.
- **No pgBackRest backups** or Patroni replica creations can be running during the rotation.
- Vault must be unsealed and reachable by the primary PostgreSQL node.

### Procedure

1. **Check for blocking operations:** Ensure no backups are running. If a backup is running, wait for it to finish. Rotating the key while `pg_basebackup` is partially complete will corrupt the backup.

2. **Run the rotation script:**
   The script automatically finds the current Patroni leader, generates a new key name (suffixed with the current date/time), creates it in Vault, and sets it as the default.

   ```bash
   ./scripts/pgtde_rotate_master_keys.docker.sh
   ```

3. **Verify the rotation:**
   The script outputs the "Before" and "After" key status. You can manually verify the new key is active on the leader:

   ```bash
   docker exec -t <leader-node> psql -U postgres -c "SELECT * FROM pg_tde_server_key_info();"
   ```
   *Expected output: The `key_name` should reflect the newly generated timestamped name (e.g., `global-master-key-20260320-143000`), and `provider_name` should be `vault-provider`.*

### How it Works Under the Hood

When `pg_tde_set_default_key_using_global_key_provider()` is called, PostgreSQL connects to Vault via the `vault-provider` definition. It securely fetches the new MEK. It then decrypts its internal file-based DEKs (stored in `pg_tde` catalog) using the *old* MEK, and immediately re-encrypts them using the *new* MEK. 

The replicas receive the new MEK name via streaming replication (WAL) and perform the same DEK re-wrap operation locally.

---

## 2. MinIO SSE-KMS Key Rotation (Object Storage)

Rotating the Server-Side Encryption (SSE) key for pgBackRest backups involves updating the default key in MinIO and (optionally) re-encrypting existing objects in the bucket.

### Prerequisites

- The MinKMS server must be healthy.
- The MinIO `mc` client must be installed and configured (`mc alias set myminio https://localhost:9000 admin admin123 --insecure`).

### Step 2.1: Create a New SSE Key in MinKMS

Because the MinKMS in this R&D stack uses a static `MINIO_KMS_SSE_KEY` environment variable in `docker-compose.yml`, "rotating" the key currently requires a container restart to pick up the new default key name.

1. Edit `minio/aistor/docker-compose.yml`.
2. Change the environment variable:
   ```yaml
   environment:
     # Old: MINIO_KMS_SSE_KEY=postgres-arch-sample-key-123
     - MINIO_KMS_SSE_KEY=postgres-arch-key-v2-20260320
   ```
3. Restart the MinIO container (this causes a brief interruption to backups):
   ```bash
   docker-compose -f minio/aistor/docker-compose.yml up -d
   ```

*Note: In a true production environment with MinKMS connected to Vault Transit, you would rotate the key directly via the MinKMS/Vault API without restarting the MinIO container.*

### Step 2.2: Re-encrypt Existing Backups (Optional but Recommended)

By default, creating a new SSE key only affects *new* objects uploaded to the bucket. Existing pgBackRest files remain encrypted with the old key (which MinKMS still holds).

To satisfy strict compliance, you must re-wrap the DEKs of all existing objects in the bucket with the new Master Key.

```bash
# Verify the current key status of a backup file
mc stat myminio/postgres-archive/backup/postgres-patroni-tde/backup.info --insecure | grep SSE

# Run the MinIO Admin Heal command to re-encrypt all objects in the bucket
# with the newly configured MINIO_KMS_SSE_KEY
mc admin heal myminio postgres-archive --insecure
```

Alternatively, you can force re-encryption using the `mc cp` command:

```bash
mc cp --recursive --encrypt-key "myminio/postgres-archive=postgres-arch-key-v2-20260320" \
  myminio/postgres-archive myminio/postgres-archive --insecure
```

## Emergency Rotation (Compromise Scenario)

If you suspect **either** Vault or the MinIO HSM key has been compromised:

1. **Isolate the network:** Disconnect the affected infrastructure from public networks immediately.
2. **Rotate Vault Token:** Revoke the `/etc/postgresql/secrets/vault_token.txt` token in Vault and issue a new one manually.
3. **Rotate pg_tde MEK:** Run `pgtde_rotate_master_keys.docker.sh` immediately.
4. **Rotate MinKMS HSM Key:** Generate a new base64 AES256 key for `MINIO_KMS_HSM_KEY`, restart MinKMS, and run `mc admin heal` on MinIO.
5. **Take new full backup:** Run `pgbackrest_backup.docker.sh full`.
6. **Purge old backups:** Delete all backups stored under the compromised keys using `mc rm`.

## References

- [pg_tde Key Management](https://docs.percona.com/pg-tde/key-management.html)
- [MinIO Server-Side Encryption (KMS)](https://min.io/docs/minio/linux/operations/server-side-encryption.html)
- [scripts/pgtde_rotate_master_keys.docker.sh](../../scripts/pgtde_rotate_master_keys.docker.sh)
