CREATE EXTENSION IF NOT EXISTS pg_repack;

-- Verify
SELECT * FROM pg_extension WHERE extname = 'pg_repack';

-- Create test table (MUST have a PRIMARY KEY — pg_repack requires it)
CREATE TABLE bloat_test_tde (
    id          SERIAL PRIMARY KEY,
    payload     TEXT,
    created_at  TIMESTAMPTZ DEFAULT now()
) USING tde_heap;

-- check access method
SELECT relname, amname 
FROM pg_class c 
JOIN pg_am am ON c.relam = am.oid 
WHERE relname LIKE 'bloat%'
ORDER BY relname;

-- Insert 500k rows
INSERT INTO bloat_test_tde (payload)
SELECT md5(random()::text) || repeat('x', 200)
FROM generate_series(1, 500000);

-- Force analyze so stats are fresh
ANALYZE bloat_test_tde;

-- Now create the bloat by deleting ~80% of rows (simulates UPDATE-heavy workloads):
-- Delete most rows, leaving only every 5th
-- update some rows
DELETE FROM bloat_test_tde WHERE id % 5 != 0;
UPDATE bloat_test_tde SET payload = md5(random()::text) WHERE id % 2 = 0;
UPDATE bloat_test_tde SET payload = md5(random()::text) WHERE id % 3 = 0;

-- 3. Measure Bloat Before Repack
-- 3a. Check table size (physical vs live data)
SELECT
    s.relname                                              AS table_name,
    s.n_live_tup                                          AS live_rows,
    s.n_dead_tup                                          AS dead_rows,
    pg_size_pretty(pg_total_relation_size(c.oid))         AS total_size,
    pg_size_pretty(pg_relation_size(c.oid))               AS heap_size,
    round(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables s
JOIN pg_class c ON c.relname = s.relname
WHERE s.relname = 'bloat_test_tde';

-- 3b. Estimate bloat using pgstattuple (more accurate)
CREATE EXTENSION IF NOT EXISTS pgstattuple;
SELECT
    table_len,
    tuple_count,
    tuple_len,
    dead_tuple_count,
    dead_tuple_len,
    round(dead_tuple_percent::numeric, 2) AS dead_pct,
    free_space,
    round(free_percent::numeric, 2)       AS free_pct
FROM pgstattuple('bloat_test_tde');
-- Expected output before repack: dead_tuple_percent should be high (40–80%).
-- or
-- dead_tuple_count = 0 but free_percent = 88.24% — this is expected and actually correct behavior. Here's what's happening:
-- PostgreSQL autovacuum already ran between your DELETE and the pgstattuple call. It cleaned the dead tuples but did not return the free space to the OS — the pages are still allocated, just marked as free internally. This is exactly the bloat pg_repack is meant to fix.
-- So your table is still bloated — just in a different form:
-- dead_tuple_percent = 0 → autovacuum already reclaimed dead tuples
-- free_percent = 88.24% → 88% of the heap is empty pages that PostgreSQL holds but can't shrink
-- Save baseline for comparison later
SELECT pg_size_pretty(pg_total_relation_size('bloat_test_tde')) AS size_before;

-- make sure to capture before & after with this query.
SELECT
    'bloat_test_tde'                                           AS table_name,
    pg_size_pretty(pg_relation_size('bloat_test_tde'))         AS heap_size,
    pg_size_pretty(pg_total_relation_size('bloat_test_tde'))   AS total_size_with_indexes,
    (SELECT dead_tuple_percent FROM pgstattuple('bloat_test_tde')) AS dead_pct;

-- Run pg_repack from cli
pg_repack \
  --host=localhost \
  --port=5432 \
  --username=postgres \
  --dbname=postgres \
  --table=bloat_test_tde \
  --no-order \
  --wait-timeout=60 \
  --elevel=DEBUG

-- Key flags explained:
--no-orderVACUUM FULL semantics (no CLUSTER ordering) — use this unless you have a CLUSTER index
--wait-timeout=60How long to wait for the final exclusive lock before killing conflicting queries
--tableTarget specific table instead of entire database
--jobs=NParallelize index rebuilds (good if you have many indexes)
--dry-runPreview what would be repacked without doing it

-- 4. Verify the Result

-- Run ANALYZE first so stats are accurate
ANALYZE bloat_test_tde;

SELECT
    s.relname                                              AS table_name,
    s.n_live_tup                                          AS live_rows,
    s.n_dead_tup                                          AS dead_rows,
    pg_size_pretty(pg_total_relation_size(c.oid))         AS total_size,
    pg_size_pretty(pg_relation_size(c.oid))               AS heap_size,
    round(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables s
JOIN pg_class c ON c.relname = s.relname
WHERE s.relname = 'bloat_test_tde';

-- run pgstattuple to verify
SELECT
    table_len,
    tuple_count,
    dead_tuple_count,
    round(dead_tuple_percent::numeric, 2) AS dead_pct,
    free_space,
    round(free_percent::numeric, 2)       AS free_pct
FROM pgstattuple('bloat_test_tde');
--Expected after repack: dead_tuple_percent ≈ 0, table_len significantly smaller.
