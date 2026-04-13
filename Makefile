.PHONY: all up down restart status logs up-minkms up-aistor down-minkms down-aistor \
	up-haproxy down-haproxy stop-haproxy restart-haproxy logs-haproxy \
	up-haproxy-master down-haproxy-master stop-haproxy-master restart-haproxy-master logs-haproxy-master \
	up-haproxy-standby down-haproxy-standby stop-haproxy-standby restart-haproxy-standby logs-haproxy-standby \
	build-haproxy

# all: up

# up: up-minkms up-minio
# stop: stop-minio stop-minkms
# down: down-minio down-minkms

# status:
# 	docker compose -f minio/minkms/docker-compose.yml ps
# 	docker compose -f minio/aistor/docker-compose.yml ps

create-network-sg-1:
	docker network create sg-prod-zone-1 --subnet 172.20.0.0/24

logs: logs-pg1 logs-pg2 logs-etcd

up-minkms:
	docker compose -f minio/minkms/docker-compose.yml up -d
stop-minkms:
	docker compose -f minio/minkms/docker-compose.yml stop
down-minkms:
	docker compose -f minio/minkms/docker-compose.yml down
logs-minkms:
	docker compose -f minio/minkms/docker-compose.yml logs -f
remove-minkms:
	docker volume rm minkms_minkms_data;

up-minio:
	docker compose -f minio/aistor/docker-compose.yml up -d
stop-minio:
	docker compose -f minio/aistor/docker-compose.yml stop
down-minio:
	docker compose -f minio/aistor/docker-compose.yml down
logs-minio:
	docker compose -f minio/aistor/docker-compose.yml logs -f
remove-minio:
	docker volume rm aistor_minio_data;

up-vault:
	docker compose -f vault/docker-compose.yml up -d
stop-vault:
	docker compose -f vault/docker-compose.yml stop
down-vault:
	docker compose -f vault/docker-compose.yml down
logs-vault:
	docker compose -f vault/docker-compose.yml logs -f
remove-vault:
	docker volume rm vault_vault_data;

up-etcd:
	docker compose -f etcd/node1/docker-compose.yml up -d
	docker compose -f etcd/node2/docker-compose.yml up -d
	docker compose -f etcd/node3/docker-compose.yml up -d
stop-etcd:
	docker compose -f etcd/node1/docker-compose.yml stop
	docker compose -f etcd/node2/docker-compose.yml stop
	docker compose -f etcd/node3/docker-compose.yml stop
down-etcd:
	docker compose -f etcd/node1/docker-compose.yml down
	docker compose -f etcd/node2/docker-compose.yml down
	docker compose -f etcd/node3/docker-compose.yml down
logs-etcd:
	docker compose -f etcd/node1/docker-compose.yml logs -f
	docker compose -f etcd/node2/docker-compose.yml logs -f
	docker compose -f etcd/node3/docker-compose.yml logs -f
remove-etcd:
	docker volume rm node1_etcd1_data;
	docker volume rm node2_etcd2_data;
	docker volume rm node3_etcd3_data;

up-pg1:
	docker compose -f postgres/master/docker-compose.yml up -d;
down-pg1:
	docker compose -f postgres/master/docker-compose.yml down;
stop-pg1:
	docker compose -f postgres/master/docker-compose.yml stop;
remove-pg1:
	docker volume rm master_postgres_one_data;
logs-pg1:
	docker compose -f postgres/master/docker-compose.yml logs -f;

up-pg2:
	docker compose -f postgres/replica_one/docker-compose.yml up -d;
down-pg2:
	docker compose -f postgres/replica_one/docker-compose.yml down;
stop-pg2:
	docker compose -f postgres/replica_one/docker-compose.yml stop;
remove-pg2:
	docker volume rm replica_one_postgres_two_data;
logs-pg2:
	docker compose -f postgres/replica_one/docker-compose.yml logs -f;

remove-pg: down-pg1 remove-pg1 down-pg2 remove-pg2

up-haproxy: up-haproxy-master up-haproxy-standby
down-haproxy: down-haproxy-master down-haproxy-standby
stop-haproxy: stop-haproxy-master stop-haproxy-standby
restart-haproxy: restart-haproxy-master restart-haproxy-standby
logs-haproxy: logs-haproxy-master

build-haproxy:
	docker compose -f haproxy/docker-compose.build.yml build

up-haproxy-master:
	docker compose -f haproxy/master/docker-compose.yml up -d;
down-haproxy-master:
	docker compose -f haproxy/master/docker-compose.yml down;
stop-haproxy-master:
	docker compose -f haproxy/master/docker-compose.yml stop;
restart-haproxy-master:
	docker compose -f haproxy/master/docker-compose.yml restart;
logs-haproxy-master:
	docker compose -f haproxy/master/docker-compose.yml logs -f;

up-haproxy-standby:
	docker compose -f haproxy/standby/docker-compose.yml up -d;
down-haproxy-standby:
	docker compose -f haproxy/standby/docker-compose.yml down;
stop-haproxy-standby:
	docker compose -f haproxy/standby/docker-compose.yml stop;
restart-haproxy-standby:
	docker compose -f haproxy/standby/docker-compose.yml restart;
logs-haproxy-standby:
	docker compose -f haproxy/standby/docker-compose.yml logs -f;
