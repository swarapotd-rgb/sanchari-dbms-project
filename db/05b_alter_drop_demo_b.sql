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

-- 3. CREATE + DROP a scratch table, to demonstrate DROP TABLE.
--    Constraint named explicitly even though the table is scratch —
--    CONVENTIONS.md section 2 makes no exception for throwaway tables.
CREATE TABLE scratch_trip_notes (
    note_id     SERIAL,
    trip_id     INTEGER,
    note_text   TEXT,
    CONSTRAINT pk_scratch_trip_notes PRIMARY KEY (note_id)
);

DROP TABLE scratch_trip_notes;
