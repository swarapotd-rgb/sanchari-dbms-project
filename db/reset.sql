-- =====================================================================
--  Sanchari · reset.sql
--  Purpose    : Drop everything so run_all.sql can rebuild from empty.
--               Removes ALL tables, views, functions AND data.
--  Author     : Shreya
--  Runs after : nothing — run it first, then run_all.sql
-- =====================================================================

DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- Re-grant default privileges (psql drops these along with the schema).
GRANT ALL ON SCHEMA public TO CURRENT_USER;
GRANT ALL ON SCHEMA public TO public;
