-- ============================================================
-- Sanchari — Person B: ALTER / DROP demo (Requirement 5)
-- File: db/05b_alter_drop_demo_b.sql
-- Shows all three DDL verbs on the trips & checking half.
--
-- NOTE: updated after Swara's 01b rewrite (7d35dba) — the original
-- demo added an is_cancelled flag and a budget-positive check, but
-- 01b now already has status='cancelled' and ck_trip_budget, so
-- those two would have duplicated existing schema. Swapped for a
-- genuinely new column and constraint instead.
-- ============================================================

-- 1. ALTER TABLE ... ADD COLUMN
--    A short free-text reason, captured when a trip is cancelled or
--    blocked — not modelled in the original design.
ALTER TABLE trip
    ADD COLUMN status_note VARCHAR(200);

-- 2. ALTER TABLE ... ADD CONSTRAINT (named explicitly, per CONVENTIONS.md)
--    A trip needs a real title, not just whitespace.
ALTER TABLE trip
    ADD CONSTRAINT ck_trip_title_not_blank
    CHECK (length(trim(title)) > 0);

-- 3. ALTER TABLE ... ALTER COLUMN ... SET DEFAULT
--    Most trips are planned for one person, so make that the default
--    rather than making the app remember to send it.
--    SET DEFAULT only affects FUTURE inserts -- existing rows are
--    untouched, which is worth knowing.
ALTER TABLE trip
    ALTER COLUMN party_size SET DEFAULT 1;


-- ============================================================
--  Throwaway demonstration of the rest of the ALTER / DROP range
--
--  Everything below is scratch. Demonstrating DROP on a table the
--  schema actually depends on would leave the database broken, so the
--  destructive verbs are shown on a table built purely to be destroyed.
-- ============================================================

CREATE TABLE scratch_trip_notes (
    note_id     SERIAL,
    trip_id     INTEGER,
    note_text   TEXT,
    -- Constraint named explicitly even though the table is scratch --
    -- CONVENTIONS.md section 2 makes no exception for throwaway tables.
    CONSTRAINT pk_scratch_trip_notes PRIMARY KEY (note_id)
);

INSERT INTO scratch_trip_notes (trip_id, note_text) VALUES
    (1, 'carry cash for the fort entry'),
    (1, 'last bus back leaves at 6'),
    (2, 'book the homestay early');

-- ALTER 1 * ADD COLUMN
ALTER TABLE scratch_trip_notes
    ADD COLUMN priority SMALLINT DEFAULT 1;

-- ALTER 2 * ALTER COLUMN TYPE (widening)
--    SMALLINT holds up to 32,767. Widening to INTEGER is safe because
--    every existing value already fits. Narrowing is the dangerous
--    direction -- PostgreSQL would check every row and refuse if any
--    value did not fit.
ALTER TABLE scratch_trip_notes
    ALTER COLUMN priority TYPE INTEGER;

-- ALTER 3 * RENAME COLUMN. Data is untouched; only the name changes.
ALTER TABLE scratch_trip_notes
    RENAME COLUMN note_text TO note_body;

-- ALTER 4 * ADD CONSTRAINT, then DROP CONSTRAINT
--    This is exactly why every constraint gets a name: DROP CONSTRAINT
--    needs one. A bare CHECK (priority > 0) would have been auto-named
--    something like scratch_trip_notes_priority_check and we would be
--    guessing at it here.
ALTER TABLE scratch_trip_notes
    ADD CONSTRAINT ck_scratch_trip_notes_priority CHECK (priority > 0);

ALTER TABLE scratch_trip_notes
    DROP CONSTRAINT ck_scratch_trip_notes_priority;

-- ALTER 5 * SET NOT NULL
--    Unlike ADD COLUMN, this one DOES scan the table -- it has to prove
--    no existing row is already NULL. So backfill first, or it fails.
UPDATE scratch_trip_notes SET priority = 1 WHERE priority IS NULL;

ALTER TABLE scratch_trip_notes
    ALTER COLUMN priority SET NOT NULL;

-- ALTER 6 * RENAME TABLE
ALTER TABLE scratch_trip_notes RENAME TO scratch_trip_notes_v2;

-- CREATE then DROP an index
CREATE INDEX idx_scratch_trip_notes_trip
    ON scratch_trip_notes_v2 (trip_id);

DROP INDEX idx_scratch_trip_notes_trip;

-- CREATE then DROP a view
--    Order matters: the view depends on the table, so it must go first.
--    Dropping the table first would either fail or, with CASCADE,
--    silently take the view with it.
CREATE VIEW v_scratch_high_priority AS
SELECT trip_id, note_body
FROM   scratch_trip_notes_v2
WHERE  priority > 1;

DROP VIEW v_scratch_high_priority;

-- DROP the scratch table.
--    IF EXISTS makes this safe to re-run during development.
DROP TABLE IF EXISTS scratch_trip_notes_v2;


-- ============================================================
--  What this file demonstrated, for the lab record:
--
--    CREATE * TABLE, INDEX, VIEW
--    ALTER  * ADD COLUMN, ADD CONSTRAINT, ALTER COLUMN TYPE,
--             SET DEFAULT, SET NOT NULL, RENAME COLUMN, RENAME TABLE,
--             DROP CONSTRAINT
--    DROP   * CONSTRAINT, INDEX, VIEW, TABLE
--
--  Confirm the permanent changes survived and the scratch did not:
--
--      SELECT column_name FROM information_schema.columns
--      WHERE table_name = 'trip' AND column_name = 'status_note';
--                                                    -- expect 1 row
--      SELECT count(*) FROM information_schema.tables
--      WHERE table_name LIKE 'scratch%';             -- expect 0
-- ============================================================
