# pgBackRest Backup Scheduling Guide

## Manual Backup Execution

You can run backups manually at any time:

```bash
# Full backup (recommended weekly)
./scripts/pgbackrest-backup.sh full

# Differential backup (recommended daily)
./scripts/pgbackrest-backup.sh diff

# Incremental backup (recommended hourly or every few hours)
./scripts/pgbackrest-backup.sh incr
```

## Automated Scheduling Options

### Option 1: Using Cron (Recommended for Linux/Mac)

Add these lines to your crontab (`crontab -e`):

```cron
# Full backup every Sunday at 2 AM
0 2 * * 0 cd /Users/deni/Projects/research/patroni-postgres-tde && ./scripts/pgbackrest-backup.sh full >> /var/log/pgbackrest-backup.log 2>&1

# Differential backup daily at 2 AM (except Sunday)
0 2 * * 1-6 cd /Users/deni/Projects/research/patroni-postgres-tde && ./scripts/pgbackrest-backup.sh diff >> /var/log/pgbackrest-backup.log 2>&1

# Incremental backup every 4 hours
0 */4 * * * cd /Users/deni/Projects/research/patroni-postgres-tde && ./scripts/pgbackrest-backup.sh incr >> /var/log/pgbackrest-backup.log 2>&1
```

### Option 2: Using Docker Compose Service (Recommended for Production)

Add a dedicated backup service to docker-compose.yml that runs on a schedule.

### Option 3: Using Kubernetes CronJob

If you're running in Kubernetes, use a CronJob resource.

## Backup Strategy Recommendations

### Conservative (High Safety, More Storage)
- **Full backup**: Weekly (Sunday 2 AM)
- **Differential backup**: Daily (2 AM)
- **Incremental backup**: Every 4 hours
- **Retention**: Keep last 4 full backups, 7 days of differential, 2 days of incremental

### Balanced (Recommended)
- **Full backup**: Weekly (Sunday 2 AM)
- **Differential backup**: Daily (2 AM)
- **Incremental backup**: Every 6 hours
- **Retention**: Keep last 2 full backups, 7 days of differential, 1 day of incremental

### Aggressive (Less Storage, Faster Recovery)
- **Full backup**: Daily (2 AM)
- **Differential backup**: Not needed
- **Incremental backup**: Every 2 hours
- **Retention**: Keep last 7 full backups, 1 day of incremental

## Monitoring Backups

Check backup status:
```bash
docker-compose exec -u postgres postgres-one pgbackrest --stanza=patroni-tde info
```

View backup details:
```bash
docker-compose exec -u postgres postgres-one pgbackrest --stanza=patroni-tde info --output=json
```

## What's Already Running Automatically

✅ **WAL Archiving**: Continuous (every time a WAL segment fills up, typically every 16MB of writes)
✅ **WAL Restore**: Automatic during replica recovery

## Current Status

Right now, you have:
- ✅ WAL archiving configured and running automatically
- ✅ Stanza created and ready
- ⏰ Base backups need to be scheduled (use the options above)
