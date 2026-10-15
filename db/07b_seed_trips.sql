-- =====================================================================
--  Sanchari · 07b_seed_trips.sql
--  Purpose    : Load trips, their days and their stops from three CSV
--               files in db/data/.
--  Author     : Swara
--  Runs after : 07a_seed_users.sql  (owners) and 06b (places)
--
--  trips.csv            trip_code, owner_email, title, origin_city,
--                       start_date, end_date, party_size, budget_cap,
--                       primary_mode, status, expect
--  trip_days.csv        trip_code, day_number, base_destination,
--                       day_start_time, day_end_time
--  itinerary_stops.csv  trip_code, day_number, stop_seq, destination,
--                       place, arrive, depart, estimated_cost, notes
--
--  trip_code (T01...) only links the three files together; the database
--  gives each trip its own trip_id.
--  calendar_date is NOT in the CSV: it is computed here as
--  start_date + (day_number - 1), so a day can never disagree with its trip.
--  arrive / depart are times; the day's date is added to make the full
--  TIMESTAMP that planned_arrival / planned_departure hold.
--
--  `expect` says what the feasibility engine should conclude: 'pass',
--  'cancelled', or the one rule (R01-R08) that trip was built to break.
--  It is kept in the CSV as the answer key for testing the engine, and is
--  not stored in the database. See docs/feasibility_rules.md.
-- =====================================================================


-- #####################################################################
--  1. trip
-- #####################################################################
CREATE TEMP TABLE stg_trip (
    trip_code     TEXT,
    owner_email   TEXT,
    title         TEXT,
    origin_city   TEXT,
    start_date    DATE,
    end_date      DATE,
    party_size    SMALLINT,
    budget_cap    NUMERIC,
    primary_mode  TEXT,
    status        TEXT,
    expect        TEXT
);

\copy stg_trip FROM '/db/data/trips.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(s.trip_code || ' (' || s.owner_email || ')', ', ') INTO bad
      FROM stg_trip s LEFT JOIN user_account u ON u.email = lower(trim(s.owner_email))
     WHERE u.user_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'trips.csv names owners not in users.csv: %', bad;
    END IF;
    SELECT string_agg(s.trip_code || ' (' || s.primary_mode || ')', ', ') INTO bad
      FROM stg_trip s LEFT JOIN transport_mode m ON m.mode_name = s.primary_mode
     WHERE m.mode_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'trips.csv uses unknown transport modes: %', bad;
    END IF;
END $$;

-- The insert hands back each new trip_id; the CTE pairs it with its
-- trip_code so the days and stops below can find their trip.
CREATE TEMP TABLE trip_map (trip_code TEXT PRIMARY KEY, trip_id BIGINT NOT NULL);

WITH new_trip AS (
    INSERT INTO trip (owner_user_id, primary_mode_id, title, origin_city,
                      start_date, end_date, party_size, budget_cap, status)
    SELECT u.user_id, m.mode_id, s.title, s.origin_city,
           s.start_date, s.end_date, s.party_size, s.budget_cap, s.status
    FROM   stg_trip       s
    JOIN   user_account   u ON u.email     = lower(trim(s.owner_email))
    JOIN   transport_mode m ON m.mode_name = s.primary_mode
    ORDER  BY s.trip_code
    RETURNING trip_id, owner_user_id, title, start_date
)
INSERT INTO trip_map (trip_code, trip_id)
SELECT s.trip_code, n.trip_id
FROM   new_trip     n
JOIN   user_account u ON u.user_id = n.owner_user_id
JOIN   stg_trip     s ON lower(trim(s.owner_email)) = u.email
                     AND s.title      = n.title
                     AND s.start_date = n.start_date;


-- #####################################################################
--  2. trip_day  (weak entity: trip_id + day_number)
-- #####################################################################
CREATE TEMP TABLE stg_day (
    trip_code         TEXT,
    day_number        SMALLINT,
    base_destination  TEXT,
    day_start_time    TIME,
    day_end_time      TIME
);

\copy stg_day FROM '/db/data/trip_days.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(d.trip_code || '/' || d.day_number, ', ') INTO bad
      FROM stg_day d
      LEFT JOIN trip_map    m  ON m.trip_code = d.trip_code
      LEFT JOIN destination ds ON ds.name     = d.base_destination
     WHERE m.trip_id IS NULL OR ds.destination_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'trip_days.csv has unknown trips or destinations: %', bad;
    END IF;
END $$;

INSERT INTO trip_day (trip_id, day_number, base_destination_id, calendar_date,
                      day_start_time, day_end_time)
SELECT m.trip_id,
       d.day_number,
       ds.destination_id,
       t.start_date + (d.day_number - 1),
       d.day_start_time,
       d.day_end_time
FROM   stg_day     d
JOIN   trip_map    m  ON m.trip_code = d.trip_code
JOIN   trip        t  ON t.trip_id   = m.trip_id
JOIN   destination ds ON ds.name     = d.base_destination;


-- #####################################################################
--  3. itinerary_stop  (weak entity: trip_id + day_number + stop_seq)
-- #####################################################################
CREATE TEMP TABLE stg_stop (
    trip_code       TEXT,
    day_number      SMALLINT,
    stop_seq        SMALLINT,
    destination     TEXT,
    place           TEXT,
    arrive          TIME,
    depart          TIME,
    estimated_cost  NUMERIC,
    notes           TEXT
);

\copy stg_stop FROM '/db/data/itinerary_stops.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(s.trip_code || ': ' || s.place, '; ') INTO bad
      FROM stg_stop s
      LEFT JOIN destination ds ON ds.name = s.destination
      LEFT JOIN place p        ON p.destination_id = ds.destination_id AND p.name = s.place
     WHERE p.place_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'itinerary_stops.csv names places not in places.csv: %', bad;
    END IF;
END $$;

INSERT INTO itinerary_stop (trip_id, day_number, stop_seq, place_id,
                            planned_arrival, planned_departure,
                            estimated_cost, notes)
SELECT m.trip_id,
       s.day_number,
       s.stop_seq,
       p.place_id,
       td.calendar_date + s.arrive,          -- DATE + TIME = TIMESTAMP
       td.calendar_date + s.depart,
       s.estimated_cost,
       NULLIF(s.notes, '')
FROM   stg_stop    s
JOIN   trip_map    m  ON m.trip_code = s.trip_code
JOIN   trip_day    td ON td.trip_id = m.trip_id AND td.day_number = s.day_number
JOIN   destination ds ON ds.name = s.destination
JOIN   place       p  ON p.destination_id = ds.destination_id AND p.name = s.place;

DROP TABLE stg_stop;
DROP TABLE stg_day;
DROP TABLE stg_trip;
DROP TABLE trip_map;

-- =====================================================================
--  Sanity check:
--      SELECT status, count(*) FROM trip GROUP BY status ORDER BY 2 DESC;
--      SELECT * FROM v_day_schedule WHERE trip_id = 1;   -- stops with gaps
-- =====================================================================
