/*
 * Example of setting up pg_partman with pg_tde encrypted table,
 * generating bloat, and then using pg_repack to clear it.
 */

-- 0. Prerequisites
CREATE EXTENSION IF NOT EXISTS pg_partman;
CREATE EXTENSION IF NOT EXISTS pg_repack;
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- 1. Create new table using partition called "bloat_test_part_tde"
-- Note: pg_repack requires a PRIMARY KEY, and partitioned tables require the partition key to be part of the PK.
SET default_table_access_method = 'tde_heap'; -- session level

CREATE TABLE bloat_test_part_tde (
    id          BIGSERIAL,
    payload     TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- 3. Premake pg_partman for 1 month interval and 6 premake
DELETE FROM public.part_config WHERE parent_table = 'public.bloat_test_part_tde';

SELECT public.create_parent(
    p_parent_table  => 'public.bloat_test_part_tde',
    p_control       => 'created_at',
    p_interval      => '1 month',
    p_premake       => 6
);

-- Check access method of the generated partitions
SELECT relname, amname 
FROM pg_class c 
JOIN pg_am am ON c.relam = am.oid 
WHERE relname LIKE 'bloat_test_part_tde_p%'
ORDER BY relname;

-- 4. Create sample 500k at random created_at
-- This inserts data ranging from current time up to ~5 months in the future so it falls into the premade partitions
INSERT INTO bloat_test_part_tde (payload, created_at)
SELECT 
    md5(random()::text) || repeat('x', 200),
    now() + (random() * 5 * interval '1 month')
FROM generate_series(1, 500000);

-- Force analyze so stats are fresh
ANALYZE bloat_test_part_tde;

-- 5 & 6. Delete 80% of it and update it like in the pg_repack setup
DELETE FROM bloat_test_part_tde WHERE id % 5 != 0;
UPDATE bloat_test_part_tde SET payload = md5(random()::text) WHERE id % 2 = 0;
UPDATE bloat_test_part_tde SET payload = md5(random()::text) WHERE id % 3 = 0;

-- 7a. Create BEFORE check for the tuple and freespace percent
SELECT
    c.relname AS partition_name,
    pg_size_pretty(pg_relation_size(c.oid)) AS heap_size,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    st.dead_tuple_count,
    round(st.dead_tuple_percent::numeric, 2) AS dead_pct,
    round(st.free_percent::numeric, 2) AS free_pct
FROM pg_class c
JOIN pg_inherits i ON c.oid = i.inhrelid
JOIN pg_class p ON i.inhparent = p.oid
CROSS JOIN LATERAL pgstattuple(c.oid::regclass) st
WHERE p.relname = 'bloat_test_part_tde'
ORDER BY c.relname;

-- ====================================================================
-- Note: Run pg_repack from the CLI on the shell:
-- ====================================================================
/*
pg_repack \
  --host=localhost \
  --port=5432 \
  --username=postgres \
  --dbname=postgres \
  --table=bloat_test_part_tde_20260401 \
  --no-order \
  --wait-timeout=60 \
  --elevel=DEBUG
*/

-- ====================================================================
-- 7b. Create AFTER check to verify the tuple and freespace percent
-- (Run this in psql after running pg_repack in the shell)
-- ====================================================================
ANALYZE bloat_test_part_tde;

SELECT
    c.relname AS partition_name,
    pg_size_pretty(pg_relation_size(c.oid)) AS heap_size,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    st.dead_tuple_count,
    round(st.dead_tuple_percent::numeric, 2) AS dead_pct,
    round(st.free_percent::numeric, 2) AS free_pct
FROM pg_class c
JOIN pg_inherits i ON c.oid = i.inhrelid
JOIN pg_class p ON i.inhparent = p.oid
CROSS JOIN LATERAL pgstattuple(c.oid::regclass) st
WHERE p.relname = 'bloat_test_part_tde'
ORDER BY c.relname;
