# Troubleshooting Guide

Select an issue to see how to handle it:

- [Replica is not syncing or has massive lag](#replica-is-not-syncing-or-has-massive-lag)
- [How to manually switch the leader](#how-to-manually-switch-the-leader)
- [How to reset a broken replica](#how-to-reset-a-broken-replica)
- [How to check cluster status](#how-to-check-cluster-status)

---

## Replica is not syncing or has massive lag
This usually happens when the replica is on a different timeline than the leader.

**Symptoms:**
- Cluster status shows "running" but not "streaming".
- Lag shows a very high number (e.g., 16 TB).

**How to handle:**
Follow the steps in [How to reset a broken replica](#how-to-reset-a-broken-replica).

---

## How to manually switch the leader
If you need to move the leader role to another node for maintenance.

**Command:**
```bash
docker exec -it postgres-one patronictl -c /etc/patroni/patroni.yml switchover
```
Follow the prompts to select the new leader.

---

## How to reset a broken replica
Use this if a replica cannot join the cluster or has corrupted data.

**Command:**
```bash
docker exec -it <container_name> patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster <member_name>
```
Example for `postgres-two`:
```bash
docker exec -it postgres-two patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster postgres-two
```

---

## How to check cluster status
Use this to see the health and roles of all nodes.

**Command:**
```bash
./scripts/patroni_cluster_status.sh
```
Or using patronictl directly:
```bash
docker exec postgres-one patronictl -c /etc/patroni/patroni.yml list
```
