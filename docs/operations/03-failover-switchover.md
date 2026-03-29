# Operations Runbook — Failover & Switchover

## Executive Summary

Patroni manages the high availability of the PostgreSQL cluster. It uses etcd to maintain a consensus on which node is the primary ("leader") and which nodes are replicas. 

- **Switchover** is a graceful, planned operation governed by an administrator. It safely demotes the current leader, ensures the replica has caught up completely, and then promotes the replica to leader without data loss.
- **Failover** is an emergency, automated (or forced manual) operation. It occurs when the leader becomes unresponsive. Patroni promotes a replica to leader as quickly as possible to restore write availability, potentially at the cost of losing a tiny amount of WAL (up to `maximum_lag_on_failover`).

This runbook covers how to perform these operations manually and how to verify cluster health afterwards.

## Why This Matters (Business / Compliance Context)

High availability aligns directly with Business Continuity Planning (BCP). Knowing how to safely switch roles between database nodes without causing application downtime (or minimising it) is crucial for:
- Routine maintenance (e.g., OS patching, upgrading PostgreSQL minor versions).
- Mitigating underlying hardware degradation before a hard crash occurs.
- Meeting standard SOC 2 and ISO 27001 availability SLAs.

## 1. Planned Switchover

A switchover should be the standard procedure when you need to perform maintenance on the primary node (`postgres-one`). 

### Prerequisites

- Both `postgres-one` and `postgres-two` must be running.
- `postgres-two` must be in the `running` state with `role: replica`.
- Replication lag should be minimal (ideally 0 bytes).

### Procedure

1. **Verify cluster health:**
   Check the current status to ensure both nodes are healthy and synchronous.
   ```bash
   ./scripts/patroni_cluster_status.sh
   # OR
   docker exec postgres-one patronictl -c /etc/patroni/patroni.yml list
   ```

2. **Execute the Switchover:**
   Run the `switchover` command. Patroni will prompt you to confirm the master and candidate nodes, and the scheduled time (default is immediately).
   ```bash
   docker exec -it postgres-one patronictl -c /etc/patroni/patroni.yml switchover
   ```
   *To force it scriptably without prompts:*
   ```bash
   docker exec postgres-one patronictl -c /etc/patroni/patroni.yml switchover --master postgres-one --candidate postgres-two --force
   ```

3. **Monitor the Transition:**
   - Patroni will pause PgBouncer traffic.
   - It issues a `CHECKPOINT` and `pg_ctl stop -m fast` on the leader.
   - It waits for the replica to apply the final WAL segment.
   - It promotes the replica.
   - It updates the leader lock in etcd.

4. **Verify New Roles:**
   Run `./scripts/patroni_cluster_status.sh` again. `postgres-two` should now show as `Leader`, and `postgres-one` (once it restarts and rejoins via `pg_rewind`) will show as `Replica`.

### Application Impact During Switchover

PgBouncer (if configured properly with a virtual IP or load balancer) will queue connections during the brief seconds the database is unavailable, then route them to the new leader. In this Docker Compose environment, applications must point to the correct active PgBouncer IP, which requires a HAProxy/Keepalived layer above Patroni (not included in this R&D scope).

---

## 2. Emergency Failover

Failover occurs automatically if the primary node crashes or loses network connectivity to etcd for longer than the `ttl` (default 30 seconds). However, you can trigger a manual failover if the primary is degraded but hasn't lost its etcd lock yet.

### Automatic Failover Testing

To test Patroni's automatic failover mechanism:

1. Identify the current leader (`postgres-one`).
2. Simulate a hard crash by killing the PostgreSQL process (not the container, as Patroni would just restart the container).
   ```bash
   # Send SIGKILL to the postmaster
   docker exec postgres-one pkill -9 postgres
   ```
3. Watch the Patroni logs on `postgres-two`:
   ```bash
   docker logs -f postgres-two
   ```
   *Within ~10 seconds (`loop_wait`), Patroni will realise the leader is gone, acquire the lock in etcd, and promote `postgres-two` to leader.*

### Manual Failover

If the primary is acting erratically but Patroni hasn't failed it over, you can force it from the replica:

```bash
# Execute from the candidate replica
docker exec -it postgres-two patronictl -c /etc/patroni/patroni.yml failover
```

*Note: You cannot perform a failover from a node if it exceeds the `maximum_lag_on_failover` threshold (default 1MB).*

---

## 3. Rejoining a Failed Primary (pg_rewind)

When a former primary comes back online after a failover, its "timeline" (WAL history) has diverged from the new primary. It cannot simply resume replication.

Because `use_pg_rewind: true` is set in `patroni-one.yml`, Patroni handles this automatically:

1. Patroni detects the timeline divergence.
2. It stops the former primary.
3. It runs `pg_rewind` to sync the diverging data blocks from the new primary back to the old primary.
4. It starts the old primary as a replica.

### What if `pg_rewind` fails?

If the divergence is too great or the necessary WAL has already been archived and removed from the new primary, `pg_rewind` will fail. Patroni will then fall back to completely wiping the data directory and performing a full base backup using the custom `tde_basebackup.sh` script.

## Troubleshooting

- **Replica stuck in "creating replica":**
  Check the replica logs. Ensure the primary can communicate with Vault, and that `tde_basebackup.sh` has executable permissions.
- **"switchover is not possible: no good candidates found":**
  The replica is either offline, not streaming, or its replication lag exceeds the safe threshold. Check `pg_stat_replication` on the primary.
- **Failover took > 30 seconds:**
  Check the `ttl` and `loop_wait` parameters in the Patroni configuration. Also, ensure etcd disk I/O latency is under 50ms.

## References

- [Patroni Switchover & Failover](https://patroni.readthedocs.io/en/latest/patroni_configuration.html)
- [pg_rewind Documentation](https://www.postgresql.org/docs/current/app-pgrewind.html)
- [scripts/patroni_cluster_status.sh](../../scripts/patroni_cluster_status.sh)
