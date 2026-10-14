-- =====================================================================
--  Sanchari · 06c_seed_hours.sql
--  Purpose    : Load weekly opening hours (opening_rule) and dated
--               closures (closure_window) from two CSV files.
--  Author     : Swara
--  Runs after : 06b_seed_places.sql  (places must exist)
--
--  opening_hours.csv - ONE row per place, expanded here to one
--  opening_rule row per open weekday:
--    destination, name           as in places.csv
--    open_days                   digits of the days it is OPEN,
--                                1 = Monday ... 7 = Sunday
--                                1234567 = every day
--                                234567  = closed Monday
--                                (1-7, not 0-6, so Excel can never drop
--                                 a leading zero and lose Sunday)
--    opens_at, closes_at         24-hour times, closes after opens
--    last_entry_at               ticket cut-off, or blank for none
--
--  closures.csv - one row per closure:
--    destination, name
--    start_date, end_date        YYYY-MM-DD
--    reason_code                 monsoon | maintenance | festival |
--                                breeding_season | govt_order | other
--    is_annual_recurring         true = same dates every year
--
--  Weekly "closed on Monday" is NOT a closure - leave the day out of
--  open_days instead. closure_window is only for dated exceptions.
-- =====================================================================


-- #####################################################################
--  1. opening_rule
-- #####################################################################
CREATE TEMP TABLE stg_hours (
    destination    TEXT,
    name           TEXT,
    open_days      TEXT,
    opens_at       TIME,
    closes_at      TIME,
    last_entry_at  TIME
);

\copy stg_hours FROM '/db/data/opening_hours.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- every row must name a place that 06b loaded, and use only digits 1-7
DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(h.destination || ' / ' || h.name, '; ')
      INTO bad
      FROM stg_hours h
      LEFT JOIN destination d ON d.name = h.destination
      LEFT JOIN place p       ON p.destination_id = d.destination_id AND p.name = trim(h.name)
     WHERE p.place_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'opening_hours.csv names places not in places.csv: %', bad;
    END IF;

    SELECT string_agg(h.name || ' (' || coalesce(h.open_days, 'blank') || ')', '; ')
      INTO bad
      FROM stg_hours h
     WHERE h.open_days IS NULL OR h.open_days !~ '^[1-7]{1,7}$';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'open_days must be digits 1-7 (1 = Monday): %', bad;
    END IF;
END $$;

-- '234567' -> six rows. ISO day 7 (Sunday) becomes 0, which is what
-- opening_rule.day_of_week and EXTRACT(DOW ...) use.
-- rule_no simply numbers each place's rows 1, 2, 3 ...
INSERT INTO opening_rule (place_id, rule_no, day_of_week, opens_at, closes_at, last_entry_at)
SELECT p.place_id,
       ROW_NUMBER() OVER (PARTITION BY p.place_id ORDER BY x.iso_day)::SMALLINT,
       (x.iso_day % 7)::SMALLINT,
       h.opens_at,
       h.closes_at,
       h.last_entry_at
FROM   stg_hours   h
JOIN   destination d ON d.name = h.destination
JOIN   place       p ON p.destination_id = d.destination_id AND p.name = trim(h.name)
CROSS JOIN LATERAL (
       SELECT DISTINCT ch::INT AS iso_day
       FROM   regexp_split_to_table(h.open_days, '') AS ch
) x;

DROP TABLE stg_hours;


-- #####################################################################
--  2. closure_window
-- #####################################################################
CREATE TEMP TABLE stg_closure (
    destination          TEXT,
    name                 TEXT,
    start_date           DATE,
    end_date             DATE,
    reason_code          TEXT,
    is_annual_recurring  BOOLEAN
);

\copy stg_closure FROM '/db/data/closures.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(c.destination || ' / ' || c.name, '; ')
      INTO bad
      FROM stg_closure c
      LEFT JOIN destination d ON d.name = c.destination
      LEFT JOIN place p       ON p.destination_id = d.destination_id AND p.name = trim(c.name)
     WHERE p.place_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'closures.csv names places not in places.csv: %', bad;
    END IF;
END $$;

INSERT INTO closure_window (place_id, closure_no, start_date, end_date,
                            reason_code, is_annual_recurring)
SELECT p.place_id,
       ROW_NUMBER() OVER (PARTITION BY p.place_id ORDER BY c.start_date)::SMALLINT,
       c.start_date,
       c.end_date,
       trim(c.reason_code),
       COALESCE(c.is_annual_recurring, FALSE)
FROM   stg_closure c
JOIN   destination d ON d.name = c.destination
JOIN   place       p ON p.destination_id = d.destination_id AND p.name = trim(c.name);

DROP TABLE stg_closure;

-- =====================================================================
--  Sanity check - the core function now has real data to answer from:
--      SELECT * FROM f_place_open_on(
--          (SELECT place_id FROM place WHERE name = 'Kote Betta'), '2026-07-15');
--      -- closed: monsoon
--      SELECT * FROM f_place_open_on(
--          (SELECT place_id FROM place WHERE name = 'Madikeri Museum'), '2026-12-14');
--      -- 14 Dec 2026 is a Monday -> closed on Monday
-- =====================================================================
