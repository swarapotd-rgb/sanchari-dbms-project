-- =====================================================================
--  Sanchari  ·  00_check_setup.sql
--  Environment check for Step 0. Both team members run this and compare
--  output. If it completes with no errors, your machine is ready.
--
--  Run it with:
--    Docker :  docker exec -i sanchari-db psql -U postgres -d sanchari < 00_check_setup.sql
--    Native :  psql -U postgres -d sanchari -f 00_check_setup.sql
-- =====================================================================

\echo ''
\echo '=== 1. Which PostgreSQL am I talking to? ============================'
SELECT version() AS postgres_version;

\echo ''
\echo '=== 2. Which database and user? ====================================='
SELECT current_database()        AS database,
       current_user              AS connected_as,
       current_setting('port')   AS port;

\echo ''
\echo '=== 3. Are the extensions we need available to install? ============='
--  installed_version will be NULL until we install them - that is fine.
--  If a row is MISSING here, the extension is not installed on this server
--  and no amount of CREATE EXTENSION will help. See the setup guide.
SELECT name,
       default_version,
       installed_version
FROM   pg_available_extensions
WHERE  name IN ('vector', 'btree_gist')
ORDER  BY name;

\echo ''
\echo '=== 4. Install them ================================================='
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS btree_gist;

\echo ''
\echo '=== 5. Confirm they are now installed ==============================='
SELECT extname AS extension,
       extversion AS version
FROM   pg_extension
WHERE  extname IN ('vector', 'btree_gist')
ORDER  BY extname;

\echo ''
\echo '=== 6. Smoke test: create, insert, vector search, drop =============='
--  This proves you can do everything the DDL step needs: create a table,
--  use the VECTOR type, run a similarity search, and clean up after.
CREATE TABLE _sanchari_smoke_test (
    id       SERIAL PRIMARY KEY,
    label    VARCHAR(40) NOT NULL,
    embedding VECTOR(3)  NOT NULL
);

INSERT INTO _sanchari_smoke_test (label, embedding) VALUES
    ('waterfall', '[1, 2, 3]'),
    ('fort',      '[4, 5, 6]'),
    ('lake',      '[1, 2, 4]');

\echo '--- nearest neighbours to [1,2,3] by cosine distance (lake should beat fort):'
SELECT label,
       ROUND((embedding <=> '[1,2,3]'::vector)::numeric, 6) AS cosine_distance
FROM   _sanchari_smoke_test
ORDER  BY embedding <=> '[1,2,3]'::vector;

\echo '--- checking a CHECK constraint actually fires:'
ALTER TABLE _sanchari_smoke_test
    ADD CONSTRAINT ck_smoke_label_not_blank CHECK (length(trim(label)) > 0);

DROP TABLE _sanchari_smoke_test;

\echo ''
\echo '=== 7. Timezone sanity ============================================='
--  Our dates matter (closure windows, weekday rules), so both machines
--  should agree. Not fatal if different, but note it.
SHOW timezone;
SELECT now() AS server_time_now;

\echo ''
\echo '====================================================================='
\echo ' If you reached here with no ERROR lines above, Step 0 is DONE.'
\echo ' Paste the output of sections 1, 5 and 6 to your teammate and check'
\echo ' that the PostgreSQL major version and the vector version MATCH.'
\echo '====================================================================='
\echo ''
