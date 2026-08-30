-- =====================================================================
--  Sanchari · 05a_alter_drop_demo_a.sql
--  Purpose    : Demonstrate ALTER and DROP, which requirement 5 asks to
--               see alongside CREATE.
--  Author     : Swara
--  Runs after : 04a_views_places.sql
--
--  Two parts, deliberately separated:
--
--    PART 1 is a REAL, PERMANENT change to the schema. It is additive
--           and safe, and the column it adds is genuinely needed later.
--
--    PART 2 is a THROWAWAY demonstration. It builds a scratch table,
--           puts it through every kind of ALTER, then drops it along
--           with a scratch index and view. Nothing the schema depends on
--           is ever altered destructively.
--
--  That separation is the point. Demonstrating DROP by dropping
--  something real would leave the schema broken; demonstrating it only
--  on scrap would leave the file feeling like theatre. This does both
--  honestly.
-- =====================================================================


-- #####################################################################
--  PART 1 · A real schema change
-- #####################################################################

-- ---------------------------------------------------------------------
--  ALTER TABLE ... ADD COLUMN
--
--  place needs a short text blurb. It is the text that will be fed to
--  the embedding model to produce place_embedding.embedding, so without
--  it the semantic search has nothing to embed.
--
--  Adding it here rather than in 01a is deliberate: it shows the normal
--  lifecycle of a schema — you design, you build, and then you discover
--  something is missing and you ALTER rather than rewrite. Adding a
--  nullable column is instant and cannot break existing rows.
-- ---------------------------------------------------------------------
ALTER TABLE place
    ADD COLUMN short_description VARCHAR(280);

COMMENT ON COLUMN place.short_description IS
    'One-line blurb. Source text for place_embedding.embedding.';

-- ---------------------------------------------------------------------
--  ALTER TABLE ... ADD CONSTRAINT
--
--  A blurb of whitespace is worse than no blurb — it produces a
--  meaningless embedding. Reject it at the database level rather than
--  hoping the application remembers (requirement 12).
--
--  Note it is added as a NAMED constraint, per CONVENTIONS.md §2. An
--  unnamed one would get a system-generated name and could not be
--  cleanly dropped later.
-- ---------------------------------------------------------------------
ALTER TABLE place
    ADD CONSTRAINT ck_place_short_description
    CHECK (short_description IS NULL OR length(trim(short_description)) >= 10);

-- ---------------------------------------------------------------------
--  ALTER TABLE ... ALTER COLUMN ... SET DEFAULT
--
--  Every place added from now on starts as unverified until a Curator
--  reviews it. Existing rows are untouched — SET DEFAULT only affects
--  future inserts, which is worth knowing.
-- ---------------------------------------------------------------------
ALTER TABLE place
    ALTER COLUMN review_count SET DEFAULT 0;


-- #####################################################################
--  PART 2 · Throwaway demonstration of the full ALTER and DROP range
-- #####################################################################

-- ---------------------------------------------------------------------
--  CREATE a scratch table to experiment on safely.
--  The leading underscore marks it as temporary scaffolding.
-- ---------------------------------------------------------------------
CREATE TABLE _demo_scratch (
    scratch_id   SERIAL,
    label        VARCHAR(20)  NOT NULL,
    quantity     SMALLINT     NOT NULL DEFAULT 1,

    CONSTRAINT pk_demo_scratch PRIMARY KEY (scratch_id)
);

INSERT INTO _demo_scratch (label, quantity) VALUES
    ('alpha', 3), ('beta', 7), ('gamma', 2);

-- ---------------------------------------------------------------------
--  ALTER 1 · add a column
-- ---------------------------------------------------------------------
ALTER TABLE _demo_scratch
    ADD COLUMN note TEXT;

-- ---------------------------------------------------------------------
--  ALTER 2 · widen a column's type
--
--  SMALLINT holds up to 32,767. Widening to INTEGER is safe because
--  every existing value already fits. Narrowing would be the dangerous
--  direction — PostgreSQL would have to check every row and would refuse
--  if any value did not fit.
-- ---------------------------------------------------------------------
ALTER TABLE _demo_scratch
    ALTER COLUMN quantity TYPE INTEGER;

-- ---------------------------------------------------------------------
--  ALTER 3 · rename a column
--  Existing data is untouched; only the name changes.
-- ---------------------------------------------------------------------
ALTER TABLE _demo_scratch
    RENAME COLUMN note TO remarks;

-- ---------------------------------------------------------------------
--  ALTER 4 · add a named constraint, then drop it again
--
--  This is exactly why CONVENTIONS.md insists every constraint is named:
--  DROP CONSTRAINT needs the name. Had it been written as a bare
--  CHECK (quantity > 0), PostgreSQL would have called it something like
--  _demo_scratch_quantity_check and we would be guessing.
-- ---------------------------------------------------------------------
ALTER TABLE _demo_scratch
    ADD CONSTRAINT ck_demo_scratch_quantity CHECK (quantity > 0);

ALTER TABLE _demo_scratch
    DROP CONSTRAINT ck_demo_scratch_quantity;

-- ---------------------------------------------------------------------
--  ALTER 5 · make a column NOT NULL
--  This one DOES scan the table — it must prove no row is already NULL.
--  We backfill first, or it would fail.
-- ---------------------------------------------------------------------
UPDATE _demo_scratch SET remarks = 'n/a' WHERE remarks IS NULL;

ALTER TABLE _demo_scratch
    ALTER COLUMN remarks SET NOT NULL;

-- ---------------------------------------------------------------------
--  ALTER 6 · rename the table itself
-- ---------------------------------------------------------------------
ALTER TABLE _demo_scratch RENAME TO _demo_scratch_renamed;

-- ---------------------------------------------------------------------
--  CREATE then DROP an index
-- ---------------------------------------------------------------------
CREATE INDEX idx_demo_scratch_label
    ON _demo_scratch_renamed (label);

DROP INDEX idx_demo_scratch_label;

-- ---------------------------------------------------------------------
--  CREATE then DROP a view
--
--  Dropping the view before the table matters: a view depends on the
--  table it reads. Dropping the table first would either fail or, with
--  CASCADE, silently take the view with it.
-- ---------------------------------------------------------------------
CREATE VIEW v_demo_scratch_summary AS
SELECT label, quantity
FROM   _demo_scratch_renamed
WHERE  quantity > 2;

DROP VIEW v_demo_scratch_summary;

-- ---------------------------------------------------------------------
--  DROP the scratch table
--
--  IF EXISTS makes the statement safe to run even if the table is
--  already gone, which matters when re-running scripts during
--  development.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS _demo_scratch_renamed;


-- =====================================================================
--  What this file demonstrated, for the lab record:
--
--    CREATE  · TABLE, INDEX, VIEW
--    ALTER   · ADD COLUMN, ALTER COLUMN TYPE, SET DEFAULT, SET NOT NULL,
--              RENAME COLUMN, RENAME TABLE, ADD CONSTRAINT,
--              DROP CONSTRAINT
--    DROP    · CONSTRAINT, INDEX, VIEW, TABLE
--
--  Verify the permanent change survived and the scratch objects did not:
--
--      SELECT column_name FROM information_schema.columns
--      WHERE table_name = 'place' AND column_name = 'short_description';
--                                                     -- expect 1 row
--
--      SELECT count(*) FROM information_schema.tables
--      WHERE table_name LIKE '_demo%';                -- expect 0
-- =====================================================================
