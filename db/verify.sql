-- =====================================================================
--  Sanchari · verify.sql
--  Purpose    : Prove the schema is complete and built to convention.
--               This output is the lab-record screenshot.
--  Author     : Shreya (counts) · Swara (convention checks 2-5)
--  Runs after : run_all.sql
-- =====================================================================

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
      WHERE n.nspname = 'public' AND p.prokind = 'f'
        AND p.proname LIKE 'f\_%')                                     AS functions,
    (SELECT count(*) FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.prokind = 'p')                  AS procedures,
    (SELECT count(*) FROM pg_trigger tg
       JOIN pg_class c ON c.oid = tg.tgrelid
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND NOT tg.tgisinternal)              AS triggers;

\echo 'Expected:  tables 19 | foreign_keys 24 | idx_indexes 22 | views 4 | functions 2 | procedures 1 | triggers 2'


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
\echo '=== 8. Rows in every table ==='
\echo 'feasibility_run and violation are filled by 09_run_feasibility.sql.'

SELECT t.table_name,
       (xpath('/row/n/text()',
              query_to_xml(format('SELECT count(*) AS n FROM %I', t.table_name),
                           false, true, '')))[1]::text::int AS row_count
FROM   information_schema.tables t
WHERE  t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
ORDER  BY t.table_name;

\echo ''
\echo '=== 9. Feasibility results: every trip with a problem ==='
\echo 'From the latest run of each trip. Expect exactly 8 rows - the test'
\echo 'trips, one rule each: R01 R02 R03 R04 R05 R06 R07 R08.'

SELECT t.trip_id,
       t.title,
       t.status,
       r.feasibility_score                                  AS score,
       string_agg(v.rule_code || ' ' || v.severity, ', '
                  ORDER BY v.violation_no)                  AS rules_failed
FROM   trip t
JOIN   feasibility_run r ON r.trip_id = t.trip_id
                        AND r.run_id  = (SELECT max(run_id) FROM feasibility_run
                                          WHERE trip_id = t.trip_id)
JOIN   violation       v ON v.run_id  = r.run_id
GROUP  BY t.trip_id, t.title, t.status, r.feasibility_score
ORDER  BY t.trip_id;

\echo ''
\echo '=== 10. Reviews linked to MongoDB ==='
\echo 'Every review must carry the _id of its MongoDB document.'
\echo 'Expect: total 154 | linked 154 | distinct_ids 154'

SELECT count(*)                     AS total,
       count(mongo_doc_id)          AS linked,
       count(DISTINCT mongo_doc_id) AS distinct_ids
FROM   review_summary;

\echo ''
\echo '=== Done. Sections 2-5 must all report zero rows. ==='
