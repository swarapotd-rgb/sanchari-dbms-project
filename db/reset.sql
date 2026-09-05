-- ============================================================
-- Sanchari — reset.sql
-- Drops everything so run_all.sql can be re-run cleanly.
--   psql -d sanchari -f db/reset.sql
-- ============================================================

DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- Re-grant default privileges (psql drops these along with the schema).
GRANT ALL ON SCHEMA public TO CURRENT_USER;
GRANT ALL ON SCHEMA public TO public;
