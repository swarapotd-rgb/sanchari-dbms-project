-- ============================================================
-- Sanchari - run_all.sql
-- Runs every DDL file in dependency order.
--
--   psql -d sanchari -f db/run_all.sql        (from the repo root)
--
-- IMPORTANT: the \ir paths below are resolved relative to THIS FILE,
-- not to wherever psql happens to be running. That is what \ir does
-- and \i does not - \i resolves against psql's own current directory,
-- which breaks the moment the script is piped into a container.
-- ============================================================

\ir 00_extensions.sql

\ir 01a_tables_people_places.sql
\ir 01b_tables_trips_checks.sql

\ir 03a_indexes_people_places.sql
\ir 03b_indexes_trips_checks.sql

\ir 04a_views_places.sql
\ir 04b_views_trips.sql

\ir 05a_alter_drop_demo_a.sql
\ir 05b_alter_drop_demo_b.sql
