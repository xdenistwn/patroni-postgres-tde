-- ==========================================
-- PostgreSQL Monitoring Setup Script
-- Run this as superuser (postgres) on the cluster
-- ==========================================

-- 1. Create a dedicated monitoring role/user
CREATE USER monitor_user WITH PASSWORD 'monitor_password_secure';

-- 2. Grant the built-in pg_monitor role
-- This role allows access to pg_stat_database, pg_stat_activity, pg_stat_bgwriter,
-- pg_locks, and other standard system statistics.
GRANT pg_monitor TO monitor_user;

-- 3. Grant access to pg_stat_monitor
-- pg_stat_monitor is a Percona extension. We want the monitoring user to be able
-- to read query-level execution stats.
GRANT SELECT ON pg_stat_monitor TO monitor_user;

-- 4. Expose the pg_roles relation check if needed
GRANT SELECT ON pg_roles TO monitor_user;
GRANT SELECT ON pg_database TO monitor_user;

-- 5. PgBouncer integration:
-- Make sure the monitor_user is also present in pgbouncer userlist if we scrape via pgbouncer.
-- You can add the user to master/replica pgbouncer configs:
-- "monitor_user" "md5..." (matching password md5 or plain depending on auth_type)

-- Verification query
SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin 
FROM pg_roles 
WHERE rolname = 'monitor_user';
