-- =====================================================================
--  Sanchari · run_all.sql
--  Purpose    : Build the whole schema in dependency order, one command.
--  Author     : Shreya
--  Runs after : reset.sql (on an existing database) — or nothing, on a
--               fresh one
--
--  HOW TO RUN — psql must be able to SEE the db/ folder, because \ir
--  opens each file by path (relative to this file):
--
--    Native psql, from the repo root:
--        psql -U postgres -d sanchari -f db/run_all.sql
--
--    Docker — copy the folder into the container first, then run there:
--        docker cp db/. sanchari-db:/db
--        docker exec sanchari-db psql -U postgres -d sanchari -f /db/run_all.sql
--
--  Piping this one file into the container (Get-Content ... | docker
--  exec ...) does NOT work: only this file's text is sent, and the
--  files it includes are not inside the container to be found.
-- =====================================================================

\ir 00_extensions.sql

\ir 01a_tables_people_places.sql
\ir 01b_tables_trips_checks.sql

\ir 03a_indexes_people_places.sql
\ir 03b_indexes_trips_checks.sql

\ir 04a_views_places.sql
\ir 04b_views_trips.sql

\ir 05a_alter_drop_demo_a.sql
\ir 05b_alter_drop_demo_b.sql

-- ---------------- seed data (Step 2) ----------------
\ir 06a_seed_reference.sql
\ir 06b_seed_places.sql
\ir 06c_seed_hours.sql
\ir 06d_seed_travel_legs.sql
\ir 06e_seed_embeddings.sql
\ir 07a_seed_users.sql
\ir 07b_seed_trips.sql
