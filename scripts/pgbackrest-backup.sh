#!/bin/bash
set -e

# This script performs pgBackRest backups
# Run this on a schedule (e.g., via cron) for automated backups

STANZA="patroni-tde"
BACKUP_TYPE="${1:-full}"  # full, diff, or incr

echo "$(date): Starting pgBackRest ${BACKUP_TYPE} backup for stanza ${STANZA}..."

# Run backup inside the postgres-one container
docker-compose exec -T -u postgres postgres-one \
  pgbackrest --stanza=${STANZA} --type=${BACKUP_TYPE} backup

if [ $? -eq 0 ]; then
  echo "$(date): Backup completed successfully"
  
  # Show backup info
  docker-compose exec -T -u postgres postgres-one \
    pgbackrest --stanza=${STANZA} info
else
  echo "$(date): Backup failed!"
  exit 1
fi
