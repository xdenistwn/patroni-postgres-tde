# Operations Runbook — Cluster Bootstrap

## Executive Summary

Bootstrapping this highly available, encrypted PostgreSQL cluster requires a specific sequence of operations. Because Patroni depends on etcd for coordination, and `pg_tde` depends on Vault for encryption keys, the infrastructure must be brought online in a strict dependency order. Starting PostgreSQL before Vault is unsealed or before etcd has formed a quorum will result in a failed bootstrap.

This guide provides the step-by-step procedure to bring the entire stack online from zero, verify its health, and install the required database extensions.

## Prerequisites

- Docker and Docker Compose installed on the host(s).
- All custom TLS certificates generated and placed in the appropriate `certs/` directories (see `05-tls-management.md`).
- A clean state: no residual data in the `etcd1_data`, `etcd2_data`, `etcd3_data`, or `db_data` Docker volumes from previous failed bootstrap attempts.

## Step 1: Start the Distributed Configuration Store (etcd)

Patroni uses etcd to store cluster state and elect a leader. The etcd cluster must have a quorum (2 out of 3 nodes) before Patroni can start.

```bash
# Start all three etcd nodes in the background
docker-compose -f etcd/node1/docker-compose.yml up -d
docker-compose -f etcd/node2/docker-compose.yml up -d
docker-compose -f etcd/node3/docker-compose.yml up -d

# Verify etcd quorum health
docker exec etcd1 etcdctl \
  --endpoints=https://etcd1:2379,https://etcd2:2379,https://etcd3:2379 \
  --cacert=/certs/ca.crt \
  --cert=/certs/public.crt \
  --key=/certs/private.key \
  endpoint health
```

**Expected output:** `https://etcdX:2379 is healthy: successfully committed proposal...`

## Step 2: Start Key Management (Vault & MinKMS)

`pg_tde` requires Vault to generate and retrieve the master database encryption key. MinIO requires MinKMS for backup encryption.

```bash
# Start Vault
docker-compose -f vault/docker-compose.yml up -d

# Start MinKMS (required by MinIO later)
docker-compose -f minio/minkms/docker-compose.yml up -d

# Wait a few seconds for Vault to start, then initialise policies and tokens
docker exec -t vault sh /vault/config/vault-init.sh
```

**Validation:**
Ensure the token files were created with the correct permissions. These will be bind-mounted into the PostgreSQL container.
```bash
ls -l vault/secrets/vault_token.txt vault/secrets/pgbackrest_vault_token.txt
# Expected: -rw------- (chmod 600)
```

## Step 3: Start Object Storage (MinIO)

pgBackRest needs MinIO online to archive Write-Ahead Logs (WAL). If PostgreSQL starts and cannot push WAL to the archive, the `archive_command` will fail and WAL will back up on the primary.

```bash
# Start MinIO AIStor
docker-compose -f minio/aistor/docker-compose.yml up -d

# Check MinIO AIStor health
curl -fk https://localhost:9000/minio/health/live
```

**Bucket Setup:** (Assuming the `mc` client is configured alias `myminio`)
Ensure the `postgres-archive` bucket exists and the access keys in `pgbackrest.conf` are valid. See `minio/setup_bucket.md` for manual UI steps.

## Step 4: Bootstrap the Primary PostgreSQL Node (`postgres-one`)

Start the first PostgreSQL node. Patroni will connect to etcd, realize no cluster exists, initialize a new PostgreSQL cluster (`initdb`), acquire the leader lock, and start PostgreSQL.

```bash
# Start postgres-one
docker-compose -f postgres/master/docker-compose.yml up -d

# Watch the Patroni logs to confirm successful bootstrap
docker logs -f postgres-one
```

You should see log lines indicating `initdb` ran successfully, followed by `acquired session lock as a leader` and `database system is ready to accept connections`.

## Step 5: Install pg_tde and Extensions

Once `postgres-one` is the leader, you must configure `pg_tde` to connect to Vault, generate the master encryption key, and load all other extensions (`pg_partman`, `pg_cron`, etc.).

```bash
# Run the setup script interactively
./scripts/postgres_setup.docker.sh
```

**What this script does:**
1. Connects to `postgres-one` via `psql`.
2. Creates the `pg_tde` extension.
3. Maps the Vault provider to `http://vault:8200` using the token from Step 2.
4. Generates a new `global-master-key` in Vault and sets it as default.
5. Creates extensions: `pg_partman`, `pg_cron`, `pg_repack`, `pgstattuple`, `pg_stat_monitor`, `pgaudit`.

## Step 6: Initialise pgBackRest Stanza

Before creating any replicas, or doing any real work, pgBackRest must be initialised. This creates the backup directory structure in MinIO.

```bash
# Initialise stanza 'postgres-patroni-tde'
./scripts/pgbackrest_setup_stanza.docker.sh

# Take the first full backup (strongly recommended before adding replicas)
./scripts/pgbackrest_backup.docker.sh full
```

## Step 7: Bootstrap the Replica (`postgres-two`)

Now that the leader is running, encrypted, and backed up, start the replica. Patroni on the replica will start, see that `postgres-one` holds the leader lock, and automatically initiate a base backup to join the cluster.

```bash
# Start postgres-two
docker-compose -f postgres/replica_one/docker-compose.yml up -d

# Watch the replica logs
docker logs -f postgres-two
```

Patroni will execute the custom `tde_basebackup.sh` method configured in `patroni-two.yml`. Once the base backup completes, it will enter `streaming` state.

## Step 8: Final Cluster Verification

```bash
# Use the cluster status script to verify member roles and lag
./scripts/patroni_cluster_status.sh

# Verify the leader lock in etcd directly
docker exec etcd1 etcdctl \
  --endpoints=https://etcd1:2379 \
  --cacert=/certs/ca.crt \
  --cert=/certs/public.crt \
  --key=/certs/private.key \
  get /db/postgres-cluster/leader
```

## Troubleshooting Bootstrap Failures

1. **Patroni loops infinitely with "Waiting for leader to bootstrap":**
   - **Cause:** `postgres-one` cannot talk to etcd correctly.
   - **Fix:** Check TLS certificates. The hostname inside the container (`postgres-one`) must match a SAN in the certificate, or etcd must be using the exact Root CA configured in Patroni's `cacert`. Check `docker network list` to ensure all containers are on the same bridge network.
2. **PostgreSQL starts but `pg_tde` extensions fail to create:**
   - **Cause:** Vault is unreachable or the token has expired/has wrong permissions.
   - **Fix:** Check `docker logs vault`. Open a shell in `postgres-one` and try `curl -H "X-Vault-Token: $(cat /etc/postgresql/secrets/vault_token.txt)" http://vault:8200/v1/auth/token/lookup-self`.
3. **Replica fails to join (stuck in `creating replica`):**
   - **Cause:** The `tde_basebackup.sh` script is failing.
   - **Fix:** Ensure the replica can communicate over port 5432 to the primary. Check replica logs for `pg_basebackup` or TDE specific errors. Confirm the replica has access to the *same* Vault token as the primary.
