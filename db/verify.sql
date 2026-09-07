-- ============================================================
-- Sanchari - verify.sql
-- Proves the schema is complete and built to convention.
-- This is the output that goes in the lab-record screenshot.
--   psql -d sanchari -f db/verify.sql
-- ============================================================

\echo ''
\echo '=== 1. Headline counts (all must match the Expected line) ==='

SELECT
    (SELECT count(*) FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE')     AS tables,
    (SELECT count(*) FROM information_schema.table_constraints
      WHERE constraint_schema = 'public'
        AND constraint_type = 'FOREIGN KEY')                           AS foreign_keys,
    (SELECT count(*) FROM pg_indexes
      WHERE schemaname = 'public' AND indexname LIKE 'idx\_%')         AS idx_indexes,
    (SELECT count(*) FROM information_schema.views
      WHERE table_schema = 'public')                                   AS views,
    (SELECT count(*) FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname LIKE 'f\_%')            AS functions;

\echo 'Expected:  tables 19 | foreign_keys 24 | idx_indexes 22 | views 4 | functions 1'


\echo ''
\echo '=== 2. Convention check: every constraint must be named by us ==='
\echo 'CONVENTIONS.md section 2 requires pk_ / fk_ / uq_ / ck_ prefixes.'
\echo 'Anything listed here was auto-named by PostgreSQL. Expect 0 rows.'

SELECT c.conname     AS unnamed_constraint,
       t.relname     AS on_table,
       CASE c.contype WHEN 'p' THEN 'PRIMARY KEY'
                      WHEN 'f' THEN 'FOREIGN KEY'
                      WHEN 'u' THEN 'UNIQUE'
                      WHEN 'c' THEN 'CHECK'
       END           AS kind
FROM       pg_constraint c
JOIN       pg_class      t ON t.oid = c.conrelid
JOIN       pg_namespace  n ON n.oid = t.relnamespace
WHERE      n.nspname = 'public'
  AND      c.contype IN ('p','f','u','c')
  AND      c.conname !~ '^(pk|fk|uq|ck)_'
ORDER BY   t.relname, c.conname;


\echo ''
\echo '=== 3. Convention check: every foreign key states ON DELETE ==='
\echo 'confdeltype = a means NO ACTION, i.e. nobody decided. Expect 0 rows.'

SELECT c.conname AS fk_left_on_no_action, t.relname AS on_table
FROM       pg_constraint c
JOIN       pg_class      t ON t.oid = c.conrelid
JOIN       pg_namespace  n ON n.oid = t.relnamespace
WHERE      n.nspname = 'public'
  AND      c.contype = 'f'
  AND      c.confdeltype = 'a'
ORDER BY   t.relname, c.conname;


\echo ''
\echo '=== 4. Foreign keys whose types do not match the parent ==='
\echo 'A BIGINT child pointing at an INTEGER parent still works, but'
\echo 'silently defeats index use on joins. Expect 0 rows.'

SELECT c.conname                AS mismatched_fk,
       ct.relname || '.' || ca.attname || ' ' || format_type(ca.atttypid, NULL) AS child,
       pt.relname || '.' || pa.attname || ' ' || format_type(pa.atttypid, NULL) AS parent
FROM       pg_constraint c
JOIN       pg_class      ct ON ct.oid = c.conrelid
JOIN       pg_class      pt ON pt.oid = c.confrelid
JOIN       pg_namespace  n  ON n.oid  = ct.relnamespace
CROSS JOIN LATERAL generate_subscripts(c.conkey, 1) AS i
JOIN       pg_attribute  ca ON ca.attrelid = c.conrelid  AND ca.attnum = c.conkey[i]
JOIN       pg_attribute  pa ON pa.attrelid = c.confrelid AND pa.attnum = c.confkey[i]
WHERE      n.nspname = 'public'
  AND      c.contype = 'f'
  AND      ca.atttypid <> pa.atttypid
ORDER BY   c.conname;


\echo ''
\echo '=== 5. Leftover scratch objects from the ALTER/DROP demos ==='
\echo 'The demo tables must not survive the run. Expect 0 rows.'

SELECT table_name AS leftover_scratch_object
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND (table_name LIKE '\_demo%' OR table_name LIKE 'scratch%')
ORDER BY table_name;


\echo ''
\echo '=== 6. All 19 tables, by name ==='

SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;


\echo ''
\echo '=== 7. All 24 foreign keys, with their ON DELETE action ==='

SELECT c.conname AS constraint_name,
       ct.relname AS child_table,
       pt.relname AS parent_table,
       CASE c.confdeltype WHEN 'c' THEN 'CASCADE'
                          WHEN 'r' THEN 'RESTRICT'
                          WHEN 'n' THEN 'SET NULL'
                          WHEN 'd' THEN 'SET DEFAULT'
                          ELSE 'NO ACTION'
       END      AS on_delete
FROM       pg_constraint c
JOIN       pg_class     ct ON ct.oid = c.conrelid
JOIN       pg_class     pt ON pt.oid = c.confrelid
JOIN       pg_namespace n  ON n.oid  = ct.relnamespace
WHERE      n.nspname = 'public' AND c.contype = 'f'
ORDER BY   ct.relname, c.conname;

\echo ''
\echo '=== Done. Sections 2-5 must all report zero rows. ==='
