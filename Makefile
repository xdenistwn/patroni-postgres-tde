.PHONY: all up down restart status logs up-minkms up-aistor down-minkms down-aistor

# all: up

# up: up-minkms up-minio
# stop: stop-minio stop-minkms
# down: down-minio down-minkms

# status:
# 	docker-compose -f minio/minkms/docker-compose.yml ps
# 	docker-compose -f minio/aistor/docker-compose.yml ps

create-network:
	docker network create --driver bridge pg_network

logs: logs-pg1 logs-pg2 logs-etcd

up-minkms:
	docker-compose -f minio/minkms/docker-compose.yml up -d
stop-minkms:
	docker-compose -f minio/minkms/docker-compose.yml stop
down-minkms:
	docker-compose -f minio/minkms/docker-compose.yml down
logs-minkms:
	docker-compose -f minio/minkms/docker-compose.yml logs -f

up-minio:
	docker-compose -f minio/aistor/docker-compose.yml up -d
stop-minio:
	docker-compose -f minio/aistor/docker-compose.yml stop
down-minio:
	docker-compose -f minio/aistor/docker-compose.yml down
logs-minio:
	docker-compose -f minio/aistor/docker-compose.yml logs -f

up-vault:
	docker-compose -f vault/docker-compose.yml up -d
stop-vault:
	docker-compose -f vault/docker-compose.yml stop
down-vault:
	docker-compose -f vault/docker-compose.yml down
logs-vault:
	docker-compose -f vault/docker-compose.yml logs -f

up-etcd:
	docker-compose -f etcd/node1/docker-compose.yml up -d
	docker-compose -f etcd/node2/docker-compose.yml up -d
	docker-compose -f etcd/node3/docker-compose.yml up -d
stop-etcd:
	docker-compose -f etcd/node1/docker-compose.yml stop
	docker-compose -f etcd/node2/docker-compose.yml stop
	docker-compose -f etcd/node3/docker-compose.yml stop
down-etcd:
	docker-compose -f etcd/node1/docker-compose.yml down
	docker-compose -f etcd/node2/docker-compose.yml down
	docker-compose -f etcd/node3/docker-compose.yml down
logs-etcd:
	docker-compose -f etcd/node1/docker-compose.yml logs -f
	docker-compose -f etcd/node2/docker-compose.yml logs -f
	docker-compose -f etcd/node3/docker-compose.yml logs -f
remove-etcd:
	docker volume rm node1_etcd1_data;
	docker volume rm node2_etcd2_data;
	docker volume rm node3_etcd3_data;

up-pg1:
	docker-compose -f postgres/master/docker-compose.yml up -d;
down-pg1:
	docker-compose -f postgres/master/docker-compose.yml down;
stop-pg1:
	docker-compose -f postgres/master/docker-compose.yml stop;
remove-pg1:
	docker volume rm master_postgres_one_data;
logs-pg1:
	docker-compose -f postgres/master/docker-compose.yml logs -f;

up-pg2:
	docker-compose -f postgres/replica_one/docker-compose.yml up -d;
down-pg2:
	docker-compose -f postgres/replica_one/docker-compose.yml down;
stop-pg2:
	docker-compose -f postgres/replica_one/docker-compose.yml stop;
remove-pg2:
	docker volume rm replica_one_postgres_two_data;
logs-pg2:
	docker-compose -f postgres/replica_one/docker-compose.yml logs -f;

remove-pg:
	docker-compose -f postgres/master/docker-compose.yml down;
	docker-compose -f postgres/replica_one/docker-compose.yml down;
	docker volume rm master_postgres_one_data;
	docker volume rm replica_one_postgres_two_data;

