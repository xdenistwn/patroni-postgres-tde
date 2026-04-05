# HAProxy Failover Operations

This runbook explains how HAProxy handles automated failovers under the Patroni PostgreSQL architecture.

## Automated Switchover Mechanism

HAProxy sits in front of the database clusters, but it doesn't know which node is "Primary" or "Replica" by just maintaining TCP connections. Instead, it relies on Patroni's REST API.

By default, Patroni exposes its REST API on port `8008` for all instances in a cluster. 

In `haproxy.cfg`, our health checks are set up like this:

```haproxy
option httpchk GET /primary
server postgres-one postgres-one:6432 check port 8008
```

### The Failover Timeline

1. **Before Failover**:
   - `postgres-one` is the Leader. `curl http://postgres-one:8008/primary` returns HTTP `200 OK`.
   - HAProxy routes all `5001` (primary port) traffic to `postgres-one:6432`.
   - `postgres-two` is a Replica. `curl http://postgres-two:8008/primary` returns HTTP `503 Service Unavailable`. HAProxy marks it as DOWN for the primary backend.

2. **Triggering Failover**:
   - `postgres-one` acts out or the VM fails, OR an admin manually runs `patronictl failover`.
   - Patroni steps down `postgres-one` and elects `postgres-two` as the new Leader.

3. **HAProxy Detection**:
   - Within 3 seconds (defined by `inter 3s`), HAProxy performs its next `httpchk GET /primary`.
   - `postgres-one` now returns `503 Service Unavailable` for `/primary`. HAProxy immediately disconnects the existing primary server connections and marks it DOWN.
   - `postgres-two` now returns `200 OK` for `/primary`. HAProxy marks it UP.
   - HAProxy automatically and seamlessly begins routing all write traffic on `5001` to `postgres-two:6432`.

### Application Resilience

The failover transition may briefly drop connections. Modern frameworks (like Laravel) must be structured correctly or configured to automatically retry dropped connections. Also, because we use `PgBouncer` on each node (`6432`), connection establishment overhead during the transition is minimised on the new leader.

### Testing Failovers (Simulation)

To manually observe HAProxy reacting to a failover, you can track it via the HAProxy stats interface:

1. Bring up the HAProxy statistics dashboard on `http://localhost:7000/`.
2. Run a Patroni switchover:
   ```bash
   docker exec -it postgres-one patronictl -c /etc/patroni/patroni.yml switchover
   ```
3. Answer the prompts.
4. Watch the HAProxy dashboard: observe `postgres-one` row turn red (down) in the primary pool, while `postgres-two` turns green (up). The reverse occurs in the replica pool.
