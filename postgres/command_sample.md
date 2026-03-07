1. restart all patroni cluster config
patronictl -c /etc/patroni/patroni.yml reload postgres-cluster

2. restart specific patroni cluster config
patronictl -c /etc/patroni/patroni.yml reload postgres-cluster postgres-one

3. patroni config that already bootstraped in etcd change be change only by edit-config or rest api
curl -s -XPATCH -H "Content-Type: application/json" -d '{
  "postgresql": {
    "parameters": {
      "archive_mode": "on",
      "archive_command": "pgbackrest --stanza=postgres-patroni-tde archive-push %p",
      "archive_timeout": 1800
    },
    "recovery_conf": {
      "restore_command": "pgbackrest --stanza=postgres-patroni-tde archive-get %f \"%p\""
    }
  }
}' http://localhost:8008/config

4. then restart the cluster
patronictl -c /etc/patroni/patroni.yml restart postgres-cluster