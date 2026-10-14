-- =====================================================================
--  Sanchari · 06b_seed_places.sql
--  Purpose    : Load places and their categories from db/data/places.csv
--               into place and place_category.
--  Author     : Swara
--  Runs after : 06a_seed_reference.sql  (needs destination and
--               interest_category rows to look names up in)
--
--  HOW IT WORKS - the staging-table pattern
--    1. The CSV is loaded as-is into a temporary table (stg_place).
--    2. Names in it are checked against the real tables. If any
--       destination or category slug does not exist, the build STOPS
--       and prints the bad rows - nothing is silently dropped.
--    3. INSERT ... SELECT ... JOIN turns names into real foreign keys.
--
--  The CSV path /db/data/... is where `docker cp db/. sanchari-db:/db`
--  puts it inside the container.
--
--  places.csv columns, in this order:
--    destination, state          exactly as in 06a
--    name                        unique within its destination
--    place_type                  one of the 11 in ck_place_type
--    latitude, longitude
--    typical_visit_minutes       > 0
--    fee_indian, fee_foreign     rupees; 0 if free (never blank)
--    requires_daylight           true / false
--    short_description           one sentence, at least 10 characters
--    categories                  slug:relevance pairs joined by ';'
--                                e.g. waterfalls:1.0;photography:0.6
-- =====================================================================

CREATE TEMP TABLE stg_place (
    destination            TEXT,
    state                  TEXT,
    name                   TEXT,
    place_type             TEXT,
    latitude               NUMERIC,
    longitude              NUMERIC,
    typical_visit_minutes  INT,
    fee_indian             NUMERIC,
    fee_foreign            NUMERIC,
    requires_daylight      BOOLEAN,
    short_description      TEXT,
    categories             TEXT
);

\copy stg_place FROM '/db/data/places.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')


-- ---------------------------------------------------------------------
--  Check 1: every (destination, state) must exist in 06a.
-- ---------------------------------------------------------------------
DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(DISTINCT s.destination || ' / ' || s.state, '; ')
      INTO bad
      FROM stg_place s
      LEFT JOIN destination d ON d.name = s.destination AND d.state = s.state
     WHERE d.destination_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'places.csv names destinations that are not in 06a: %', bad;
    END IF;
END $$;

-- ---------------------------------------------------------------------
--  Check 2: every category slug must exist in interest_category.
-- ---------------------------------------------------------------------
DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(DISTINCT split_part(c, ':', 1), ', ')
      INTO bad
      FROM stg_place s
      CROSS JOIN LATERAL unnest(string_to_array(s.categories, ';')) AS c
      LEFT JOIN interest_category ic ON ic.slug = trim(split_part(c, ':', 1))
     WHERE ic.category_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'places.csv uses category slugs that are not in 06a: %', bad;
    END IF;
END $$;


-- ---------------------------------------------------------------------
--  place: names -> destination_id
--  Any other mistake (wrong place_type, negative fee, short
--  description...) is caught by the table's own CHECK constraints.
-- ---------------------------------------------------------------------
INSERT INTO place (destination_id, name, place_type, latitude, longitude,
                   typical_visit_minutes, fee_indian, fee_foreign,
                   requires_daylight, short_description)
SELECT d.destination_id,
       trim(s.name),
       trim(s.place_type),
       s.latitude,
       s.longitude,
       s.typical_visit_minutes,
       COALESCE(s.fee_indian, 0),
       COALESCE(s.fee_foreign, 0),
       s.requires_daylight,
       trim(s.short_description)
FROM   stg_place   s
JOIN   destination d ON d.name = s.destination AND d.state = s.state;


-- ---------------------------------------------------------------------
--  place_category: one row per slug:relevance pair
--  'waterfalls:1.0;photography:0.6' is split on ';' into two rows,
--  then each is split on ':' into the slug and its relevance.
-- ---------------------------------------------------------------------
INSERT INTO place_category (place_id, category_id, relevance)
SELECT p.place_id,
       ic.category_id,
       trim(split_part(c, ':', 2))::NUMERIC(3,2)
FROM   stg_place   s
JOIN   destination d  ON d.name = s.destination AND d.state = s.state
JOIN   place       p  ON p.destination_id = d.destination_id AND p.name = trim(s.name)
CROSS JOIN LATERAL unnest(string_to_array(s.categories, ';')) AS c
JOIN   interest_category ic ON ic.slug = trim(split_part(c, ':', 1));


DROP TABLE stg_place;

-- =====================================================================
--  Sanity check:
--      SELECT d.name, count(*) FROM place p JOIN destination d USING (destination_id)
--      GROUP BY d.name ORDER BY d.name;
--      SELECT * FROM v_place_directory LIMIT 5;     -- categories collapsed per place
-- =====================================================================
