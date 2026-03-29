# Point-In-Time Recovery (PITR) Simulation Guide

This guide simulates a critical disaster scenario: someone accidentally drops a critical table or column in the production database. 
Because Patroni immediately streams changes (such as a `DROP TABLE` or `ALTER TABLE ... DROP COLUMN`) to all replicas, the error is immediately propagated across the cluster. We cannot simply failover to a replica to recover the data.

To resolve this, we will perform a PITR by spinning up a completely independent PostgreSQL container (called the "restore node"), joining the same internal Docker network (`pg_network`), retrieving the data up to the very moment before the drop operation, dumping the lost table, and then restoring it back directly into the primary Patroni cluster.

## Architecture of the Restore Node
- We created a `postgres/restore` directory which contains a dedicated `docker-compose.yml` and `patroni-restore.yml`.  
- It uses a separate Patroni scope (`postgres-restore`) so it doesn't accidentally join or interfere with our primary `postgres-cluster`.  
- It has `archive_mode: "off"` so it doesn't overwrite our live backups.
- It pulls backups from the same Vault and MinIO endpoints using the `pgbackrest` configuration.

---

## 1. Simulating the Disaster

To prove that Point-In-Time Recovery genuinely replays transactions, we will purposefully take a full backup *before* the target table even exists. We will then create the table, record the target timestamp, drop the table, and let pgBackRest seamlessly rebuild the node using the older full backup plus the subsequent WAL files!

### Step 1A: Take a Baseline Full Backup

First, let's take a clean full database backup. At this exact moment, the `critical_data` table does **not** exist yet.

Run this from your host machine (in the project root directory):
```bash
./scripts/pgbackrest_backup.docker.sh full
```

### Step 1B: Create the Target Data

Once the backup finishes, connect to the primary node:
```bash
docker exec -it postgres-one psql -U postgres -d postgres
```

Create the table and insert the records. Because our full backup already finished earlier, these new inserts are now recorded *purely* inside the rolling WAL (Write-Ahead Logs) segments!

```sql
-- 1. Create a critical table
CREATE TABLE critical_data (
    id SERIAL PRIMARY KEY,
    info VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. Insert some important rows
INSERT INTO critical_data (info) VALUES ('Transaction X'), ('Transaction Y'), ('Transaction Z');

-- 3. Force a WAL switch so these new records are immediately pushed to S3/MinIO
SELECT pg_switch_wal();
```

### Step 1C: Record the Target Timestamp

This is your safety point. This is the exact microsecond we want to restore to.
```sql
-- 4. CHECK THE EXACT TIME right before the disaster happens.
SELECT current_timestamp;
-- Example Output: 2026-03-29 11:15:30.12345+07
```
*(Copy your output timestamp to your clipboard!)*

### Step 1D: The Disaster (Accidental Drop)

Someone comes along and accidentally deletes the table.
```sql
-- 5. OH NO! The table is accidentally dropped!
DROP TABLE critical_data;

-- 6. Force another WAL switch to ensure the "DROP" command itself is flushed and archived into MinIO.
-- If the WAL file containing the DROP or the commands just before it hasn't synced, pgBackRest won't find them!
SELECT pg_switch_wal();
```

If you check the replicas (`replica_one`), you'll see the table is completely gone there as well due to the immediate streaming replication.

*(Optional: You can verify the WAL checkpoint was successfully pushed to MinIO by checking the pgBackRest info from your host shell: `docker exec -it postgres-one pgbackrest --stanza=postgres-patroni-tde info`)*

---

## 2. Preparing the Restore Node (PITR)

We will use the `postgres/restore` node to perform the PITR.

1. **Update the Target Time**: In the `postgres/restore/patroni-restore.yml` file, look for the `method: pgbackrest` section:

   ```yaml
   bootstrap:
     method: pgbackrest
     pgbackrest:
       # Update this target time to the timestamp you retrieved exactly before the DROP TABLE
       command: "/bin/bash -c \"pgbackrest --stanza=postgres-patroni-tde --type=time --target='2026-03-29 11:15:30+07' --target-timeline='current' --target-action=promote restore\""
       keep_existing_recovery_conf: true
   ```
   > **Note**: Modify the target time timezone format to match the pgbackrest expectation (e.g., `2026-03-29 11:15:30+07`).
   > 
   > **Why is the command wrapped in `/bin/bash -c`?** By design, Patroni automatically appends its own cluster metadata parameters (`--scope` and `--datadir`) to the end of any custom bootstrap command. Because `pgbackrest` strictly fails when it receives unrecognized arguments like `--scope`, you must wrap the execution inside a shell. Bash safely ignores those extra appended arguments, preventing `pgbackrest` from crashing during initialization.

2. **Clean up any old restore data**: We want a clean slate for Patroni to trigger the bootstrap.
   
   ```bash
   docker-compose -f postgres/restore/docker-compose.yml down
   docker volume rm restore_postgres_restore_data
   docker exec -it etcd1 etcdctl --endpoints=https://etcd1:2379 --cacert=/certs/ca.crt --cert=/certs/public.crt --key=/certs/private.key del --prefix /db/postgres-restore
   ```
   > **Why do we need to delete the etcd scope?** 
   > Patroni relies on `etcd` to maintain High Availability and prevent split-brain. Even when you destroy the container and the data volume, Patroni's initialization record persists in `etcd`. If you restart the container without dropping the `etcd` prefix, Patroni thinks the cluster already exists—so instead of bootstrapping your target timestamp, it indefinitely hangs while "waiting for leader" to join as a replica! Using Patroni for this PITR gives us immense configuration automation (pg_tde, pgBackRest, Vault mapping for free), but the trade-off is that we must manually wipe its state in `etcd` to trigger a fresh extraction.

3. **Start the Restore Container**:

   ```bash
   docker-compose -f postgres/restore/docker-compose.yml up -d &&
   docker-compose -f postgres/restore/docker-compose.yml logs -f
   ```
   **Verify the node is starting and restoring**:
   *Look for pgBackRest logs fetching the WAL segments from MinIO up until your target time, followed by PostgreSQL entering read-write mode (promoted).*

---

## 3. Dumping the Lost Data

Once the `postgres-restore` node is up and running, the `critical_data` table should exist inside it. 
We'll dump the table's structure, its sequence (so the latest `id` value is retained), and its data from this node.

```bash
# We use the docker network and the pg_dump utility inside the restore container
# Notice we explicitly include the implicitly created sequence: critical_data_id_seq
docker exec -it postgres-restore pg_dump -U postgres -d postgres -t critical_data -t critical_data_id_seq -F c -f /tmp/critical_data.dump
```

*This creates a dump file located at `/tmp/critical_data.dump` inside the `postgres-restore` container.*

---

## 4. Restoring the Data to the Primary Cluster

Because the `postgres-restore` container is on the same `pg_network` as `postgres-one` (the main cluster's primary endpoint), we can use `pg_restore` directly from the `postgres-restore` container to push the data back into the main cluster!

```bash
# Push the dump directly into main cluster's primary (postgres-one), port 5432
# By NOT using -t here, we tell pg_restore to restore everything inside the custom dump (both the table and the sequence).
docker exec -it postgres-restore pg_restore -h postgres-one -p 5432 -U postgres -d postgres -1 /tmp/critical_data.dump
```
*(If prompted, enter the Patroni superuser password. Alternatively, set `PGPASSWORD` within the `exec` command).*

---

## 5. Cleaning Up

Verify inside the primary database that the table is restored properly and the replicas have synchronized it:

```bash
docker exec -it postgres-one psql -U postgres -d postgres -c "SELECT * FROM critical_data;"
```

If everything looks correct, you can safely spin down and remove the restore node, as we no longer need it.

```bash
docker-compose -f postgres/restore/docker-compose.yml down -v
# Also delete the scope from etcd
docker exec -it etcd1 etcdctl --endpoints=https://etcd1:2379 --cacert=/certs/ca.crt --cert=/certs/public.crt --key=/certs/private.key del --prefix /db/postgres-restore
```

## Summary
By using a dedicated, side-by-side isolated Patroni scope (`postgres-restore`) connected to the same infrastructure (MinKMS/MinIO Vault endpoints), we successfully pulled Point-in-Time data to bypass the streaming failure propagated to all nodes, seamlessly restoring partial data directly to the live cluster.
