/*
 * Example of setting up pg_partman with pg_tde encrypted table
 */

-- 1. Create the pg_partman extension (pg_tde extension must be run first)
CREATE EXTENSION IF NOT EXISTS pg_partman;

-- 2. create real table with the partition mode
CREATE TABLE events_encrypted (
    id          BIGSERIAL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload     TEXT
) PARTITION BY RANGE (created_at);

-- 3. create parent table
SELECT public.create_parent(
    p_parent_table  => 'public.events_encrypted',
    p_control       => 'created_at',
    p_interval      => '1 month'
);

-- 4. insert some sample data
INSERT INTO events_encrypted(created_at, payload) VALUES
    ('2025-11-15', 'november event'),
    ('2025-12-10', 'december event'),
    ('2026-01-20', 'january event'),
    ('2026-02-05', 'february event');

-- 5. Check table and the access method
SELECT relname, amname 
FROM pg_class c 
JOIN pg_am am ON c.relam = am.oid 
WHERE relname LIKE 'events%'
ORDER BY relname;

-- 6. query data with range
SELECT * FROM events_encrypted
WHERE created_at BETWEEN '2026-01-01' AND '2026-03-31';

-- 7. query data single month
SELECT * FROM events_encrypted
WHERE created_at >= '2026-02-01' AND created_at < '2026-02-01';

-- 8. checking how does the partition works from explain feature
-- the goals is for checking if the partition table got hit.
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM events_encrypted
WHERE created_at >= '2026-02-01' AND created_at < '2026-02-01';

-- 9. checking where the table file located in OS.
-- it will return: base/5/16652
SELECT pg_relation_filepath('events_encrypted_p20260201');

-- 10. check file is encrypted or not
-- in postgres server terminal, type this command.
-- it should return scrambel strings if yes its encrypted, if not its not encrypted.
strings /data/db/base/5/16652