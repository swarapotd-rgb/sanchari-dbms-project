-- ============================================================
-- Sanchari — run_all.sql
-- Runs every DDL file in dependency order, one command:
--   psql -d sanchari -f db/run_all.sql
-- ============================================================

\i db/00_extensions.sql

\i db/01a_tables_people_places.sql
\i db/01b_tables_trips_checks.sql

\i db/03a_indexes_people_places.sql
\i db/03b_indexes_trips_checks.sql

\i db/04a_views_places.sql
\i db/04b_views_trips.sql

\i db/05a_alter_drop_demo_a.sql
\i db/05b_alter_drop_demo_b.sql
