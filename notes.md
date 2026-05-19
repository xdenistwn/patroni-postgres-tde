# Troubleshooting: Timeline Mismatch and Sync Failure

## Problem
The database replica (postgres-two) stopped syncing with the leader.
- The replica was on Timeline 2 while the leader was on Timeline 4.
- The lag showed a very large number (16 TB). This happens because the nodes are on different paths and cannot calculate real lag.

## Root Cause
The replica had written data that the leader did not have. Patroni tried to fix this using a tool called `pg_rewind`, but the tool crashed.

The crash happened because a system library in the container (`llvmjit.so`) is broken. It is missing a required internal component, which causes any process using it to fail.

## Solution
Because the automatic fix crashed, the replica had to be reset manually.

### How to fix
Run this command to wipe the replica data and start a fresh sync from the leader:
```bash
docker exec -it postgres-two patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster postgres-two
```

## Recommendations
- If this happens often, disable JIT in the configuration to avoid using the broken library.
- Update the container image to fix the broken system libraries.
