-- ============================================================
-- Sanchari — verify.sql
-- Proves the schema is complete: 19 tables, 24 foreign keys.
-- This is the query whose output goes in the lab-record screenshot.
--   psql -d sanchari -f db/verify.sql
-- ============================================================

-- Table count (excludes views).
SELECT COUNT(*) AS table_count
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE';

-- Foreign key count.
SELECT COUNT(*) AS foreign_key_count
FROM information_schema.table_constraints
WHERE constraint_schema = 'public'
  AND constraint_type = 'FOREIGN KEY';

-- List every table, so you can eyeball that all 19 names are there.
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- List every foreign key with its chosen (not auto-generated) name.
SELECT constraint_name, table_name
FROM information_schema.table_constraints
WHERE constraint_schema = 'public'
  AND constraint_type = 'FOREIGN KEY'
ORDER BY table_name, constraint_name;
