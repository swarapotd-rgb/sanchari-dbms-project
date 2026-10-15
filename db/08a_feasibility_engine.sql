-- =====================================================================
--  Sanchari · 08a_feasibility_engine.sql
--  Purpose    : The feasibility engine - checks one trip against rules
--               R01-R08 and records the result.
--  Author     : Swara
--  Runs after : 04a_views_places.sql (f_place_open_on) and the seed data
--
--  Two objects:
--    f_travel_minutes(from, to, mode, date)  how long one hop takes
--    p_check_trip(trip_id)                   the check itself (procedure)
--
--  The exact definition of every rule is in docs/feasibility_rules.md.
--
--  USING IT
--      CALL p_check_trip(27);
--      SELECT * FROM feasibility_run WHERE trip_id = 27;
--      SELECT * FROM violation WHERE run_id = (SELECT max(run_id)
--                                               FROM feasibility_run
--                                               WHERE trip_id = 27);
-- =====================================================================


-- =====================================================================
--  FUNCTION · f_travel_minutes(from_place, to_place, mode, date)
-- ---------------------------------------------------------------------
--  Minutes needed to get from one place to the next by one mode.
--    1. If travel_leg has that hop, use it - the monsoon figure when the
--       date is in June-September and a monsoon figure exists.
--    2. Otherwise estimate: straight-line km x 1.3 (roads are not
--       straight) / the mode's average speed. travel_leg only holds hops
--       inside one destination, so a day that crosses from one
--       destination to another lands here.
--  Used by rule R04 (enough time to get there) and R07 (daily total).
-- =====================================================================
CREATE FUNCTION f_travel_minutes(p_from    BIGINT,
                                 p_to      BIGINT,
                                 p_mode_id INT,
                                 p_date    DATE)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_typical  INT;
    v_monsoon  INT;
BEGIN
    IF p_from = p_to THEN
        RETURN 0;
    END IF;

    -- 1. a stored leg
    SELECT l.typical_duration_min, l.monsoon_duration_min
      INTO v_typical, v_monsoon
      FROM travel_leg l
     WHERE l.from_place_id = p_from
       AND l.to_place_id   = p_to
       AND l.mode_id       = p_mode_id;

    IF FOUND THEN
        IF EXTRACT(MONTH FROM p_date) BETWEEN 6 AND 9 AND v_monsoon IS NOT NULL THEN
            RETURN v_monsoon;
        END IF;
        RETURN v_typical;
    END IF;

    -- 2. no leg: estimate from the coordinates (same haversine as 06d)
    SELECT CEIL(
             ROUND((2 * 6371 * ASIN(SQRT(
                 POWER(SIN(RADIANS(b.latitude  - a.latitude ) / 2), 2) +
                 COS(RADIANS(a.latitude)) * COS(RADIANS(b.latitude)) *
                 POWER(SIN(RADIANS(b.longitude - a.longitude) / 2), 2)
             )) * 1.3)::NUMERIC, 2)
             / m.avg_speed_kmph * 60
           )::INT
      INTO v_typical
      FROM place a, place b, transport_mode m
     WHERE a.place_id = p_from
       AND b.place_id = p_to
       AND m.mode_id  = p_mode_id;

    RETURN v_typical;
END;
$$;

COMMENT ON FUNCTION f_travel_minutes(BIGINT, BIGINT, INT, DATE) IS
    'Minutes for one hop: travel_leg (monsoon figure Jun-Sep), else haversine x 1.3 / mode speed. Used by R04 and R07.';


-- =====================================================================
--  PROCEDURE · p_check_trip(trip_id)
-- ---------------------------------------------------------------------
--  What it does, in order:
--    1. Locks the trip row (SELECT ... FOR UPDATE), so two checks of the
--       same trip cannot run at the same moment and mix their results.
--    2. Refuses a trip that does not exist or is cancelled.
--    3. Opens a feasibility_run row with run_status = 'running'.
--    4. Finds every rule failure with ONE INSERT ... SELECT, and writes
--       each as a violation row numbered 1, 2, 3 ...
--    5. Counts blocking and warning violations, gives a score, marks the
--       run 'completed', and copies the score (and validated / blocked)
--       onto the trip.
--
--  WHY A PROCEDURE, AND THE TRANSACTION
--  A procedure is called with CALL and can change data. Everything it
--  does is ONE transaction: the run row, its violations and the trip
--  update are saved together or not at all - there is never a run with
--  half its violations.
--  Step 4 sits inside BEGIN ... EXCEPTION. That inner block works like a
--  SAVEPOINT: if anything in it fails, only the work done INSIDE the
--  block is rolled back. The run row from step 3 survives and is marked
--  'failed', so the history shows that a check was attempted and broke.
--
--  SCORE: 100 - 25 per blocking violation - 10 per warning, never
--  below 0. Blocking rules: R01 R02 R03 R04 R06. Warnings: R05 R07 R08.
--
--  TRIP STATUS: a draft / validated / blocked trip becomes 'blocked' if
--  any blocking rule failed, otherwise 'validated'. Locked and completed
--  trips keep their status - the check only reports on them.
-- =====================================================================
CREATE PROCEDURE p_check_trip(p_trip_id BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_trip       trip%ROWTYPE;
    v_limit_min  NUMERIC;          -- owner's travel limit per day, in minutes
    v_run_id     BIGINT;
    v_blocking   INT;
    v_warning    INT;
    v_score      NUMERIC(5,2);
BEGIN
    -- -----------------------------------------------------------------
    -- 1-2. lock the trip and make sure it can be checked
    -- -----------------------------------------------------------------
    SELECT * INTO v_trip
      FROM trip
     WHERE trip_id = p_trip_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'trip % does not exist', p_trip_id;
    END IF;
    IF v_trip.status = 'cancelled' THEN
        RAISE EXCEPTION 'trip % is cancelled - there is nothing to check', p_trip_id;
    END IF;

    -- NULL when the owner has no profile or set no limit -> R07 skipped
    SELECT tp.max_travel_hours_per_day * 60
      INTO v_limit_min
      FROM traveller_profile tp
     WHERE tp.user_id = v_trip.owner_user_id;

    -- -----------------------------------------------------------------
    -- 3. open the run. rules_evaluated drops below 8 when R07 or R08
    --    has nothing to compare against.
    -- -----------------------------------------------------------------
    INSERT INTO feasibility_run (trip_id, rules_evaluated, run_status)
    VALUES (p_trip_id,
            6 + (v_limit_min IS NOT NULL)::INT + (v_trip.budget_cap IS NOT NULL)::INT,
            'running')
    RETURNING run_id INTO v_run_id;

    -- -----------------------------------------------------------------
    -- 4. find the violations (inner block = savepoint)
    -- -----------------------------------------------------------------
    BEGIN
        INSERT INTO violation (run_id, violation_no, trip_id, day_number, stop_seq,
                               rule_code, severity, message,
                               observed_value, expected_value)
        WITH stop AS (
            -- every stop with its place, its day's date, the stop before
            -- it on the same day (LAG), and the place's hours that date
            SELECT s.trip_id, s.day_number, s.stop_seq,
                   s.place_id, p.name, p.typical_visit_minutes, p.requires_daylight,
                   s.planned_arrival, s.planned_departure,
                   td.calendar_date,
                   LAG(s.place_id)          OVER w AS prev_place_id,
                   LAG(s.planned_departure) OVER w AS prev_departure,
                   o.is_open, o.opens_at, o.closes_at, o.last_entry_at, o.status_reason
            FROM   itinerary_stop s
            JOIN   trip_day td ON td.trip_id = s.trip_id AND td.day_number = s.day_number
            JOIN   place    p  ON p.place_id = s.place_id
            CROSS JOIN LATERAL f_place_open_on(s.place_id, td.calendar_date) o
            WHERE  s.trip_id = p_trip_id
            WINDOW w AS (PARTITION BY s.day_number ORDER BY s.stop_seq)
        ),
        hop AS (
            -- minutes needed to reach this stop from the previous one
            SELECT st.*,
                   CASE WHEN st.prev_place_id IS NULL THEN 0
                        ELSE f_travel_minutes(st.prev_place_id, st.place_id,
                                              v_trip.primary_mode_id, st.calendar_date)
                   END AS travel_min
            FROM   stop st
        ),
        hit AS (
            -- R01 closed that weekday
            SELECT h.day_number, h.stop_seq, 'R01' AS rule_code,
                   h.name || ' is ' || h.status_reason AS message,
                   to_char(h.calendar_date, 'Dy DD Mon YYYY') AS observed_value,
                   'a day it is open' AS expected_value
            FROM   hop h
            WHERE  h.status_reason LIKE 'closed on %'

            UNION ALL
            -- R03 inside a closure window
            SELECT h.day_number, h.stop_seq, 'R03',
                   h.name || ' is closed (' || substr(h.status_reason, 9) || ') on this date',
                   to_char(h.calendar_date, 'DD Mon YYYY'),
                   'a date outside its closure'
            FROM   hop h
            WHERE  h.status_reason LIKE 'closed: %'

            UNION ALL
            -- R02 outside entry hours (only for a place that is open)
            SELECT h.day_number, h.stop_seq, 'R02',
                   h.name || CASE
                       WHEN h.planned_arrival::TIME < h.opens_at      THEN ': arrives before it opens'
                       WHEN h.planned_arrival::TIME > h.last_entry_at THEN ': arrives after last entry'
                       ELSE ': stays past closing time'
                   END,
                   'arrive ' || to_char(h.planned_arrival, 'HH24:MI')
                       || ', leave ' || to_char(h.planned_departure, 'HH24:MI'),
                   'arrive ' || to_char(h.opens_at, 'HH24:MI') || '-' || to_char(h.last_entry_at, 'HH24:MI')
                       || ', leave by ' || to_char(h.closes_at, 'HH24:MI')
            FROM   hop h
            WHERE  h.is_open
              AND (   h.planned_arrival::TIME   < h.opens_at
                   OR h.planned_arrival::TIME   > h.last_entry_at
                   OR h.planned_departure::TIME > h.closes_at)

            UNION ALL
            -- R04 not enough time to travel from the previous stop
            SELECT h.day_number, h.stop_seq, 'R04',
                   'not enough time to reach ' || h.name || ' from the previous stop',
                   CASE WHEN h.planned_arrival < h.prev_departure
                        THEN 'arrives before leaving the previous stop'
                        ELSE (EXTRACT(EPOCH FROM h.planned_arrival - h.prev_departure) / 60)::INT
                             || ' min allowed'
                   END,
                   h.travel_min || ' min needed'
            FROM   hop h
            WHERE  h.prev_place_id IS NOT NULL
              AND  h.prev_departure + make_interval(mins => h.travel_min) > h.planned_arrival

            UNION ALL
            -- R05 too little time at the place
            SELECT h.day_number, h.stop_seq, 'R05',
                   'too little time at ' || h.name,
                   (EXTRACT(EPOCH FROM h.planned_departure - h.planned_arrival) / 60)::INT || ' min planned',
                   'at least ' || h.typical_visit_minutes || ' min'
            FROM   hop h
            WHERE  h.planned_departure - h.planned_arrival
                       < make_interval(mins => h.typical_visit_minutes)

            UNION ALL
            -- R06 daylight-only place outside 06:30-18:30
            SELECT h.day_number, h.stop_seq, 'R06',
                   h.name || ' needs daylight',
                   to_char(h.planned_arrival, 'HH24:MI') || '-' || to_char(h.planned_departure, 'HH24:MI'),
                   'between 06:30 and 18:30'
            FROM   hop h
            WHERE  h.requires_daylight
              AND (   h.planned_arrival::TIME   < TIME '06:30'
                   OR h.planned_departure::TIME > TIME '18:30'
                   OR h.planned_departure::DATE > h.calendar_date)

            UNION ALL
            -- R07 too much travel in one day (day-level: no stop columns)
            SELECT NULL::SMALLINT, NULL::SMALLINT, 'R07',
                   'day ' || h.day_number || ' has more travel than the traveller allows',
                   SUM(h.travel_min) || ' min of travel',
                   'at most ' || v_limit_min::INT || ' min'
            FROM   hop h
            WHERE  v_limit_min IS NOT NULL
            GROUP  BY h.day_number
            HAVING SUM(h.travel_min) > v_limit_min

            UNION ALL
            -- R08 over budget (trip-level)
            SELECT NULL::SMALLINT, NULL::SMALLINT, 'R08',
                   'the trip costs more than its budget',
                   'Rs ' || c.total,
                   'at most Rs ' || v_trip.budget_cap
            FROM  (SELECT (SELECT COALESCE(SUM(s.estimated_cost), 0)
                             FROM itinerary_stop s
                            WHERE s.trip_id = p_trip_id)
                        + (SELECT COALESCE(SUM(d.base_cost_per_day), 0) * v_trip.party_size
                             FROM trip_day td
                             JOIN destination d ON d.destination_id = td.base_destination_id
                            WHERE td.trip_id = p_trip_id) AS total) c
            WHERE  v_trip.budget_cap IS NOT NULL
              AND  c.total > v_trip.budget_cap
        )
        SELECT v_run_id,
               ROW_NUMBER() OVER (ORDER BY h.day_number NULLS LAST, h.stop_seq NULLS LAST, h.rule_code),
               CASE WHEN h.stop_seq IS NULL THEN NULL ELSE p_trip_id END,
               h.day_number,
               h.stop_seq,
               h.rule_code,
               CASE WHEN h.rule_code IN ('R05', 'R07', 'R08') THEN 'warning' ELSE 'blocking' END,
               h.message,
               h.observed_value,
               h.expected_value
        FROM   hit h;

    EXCEPTION WHEN OTHERS THEN
        -- only the violations written in this block are undone
        UPDATE feasibility_run SET run_status = 'failed' WHERE run_id = v_run_id;
        RAISE WARNING 'check of trip % failed: %', p_trip_id, SQLERRM;
        RETURN;
    END;

    -- -----------------------------------------------------------------
    -- 5. totals, score, and the trip's status
    -- -----------------------------------------------------------------
    SELECT count(*) FILTER (WHERE severity = 'blocking'),
           count(*) FILTER (WHERE severity = 'warning')
      INTO v_blocking, v_warning
      FROM violation
     WHERE run_id = v_run_id;

    v_score := GREATEST(0, 100 - 25 * v_blocking - 10 * v_warning);

    UPDATE feasibility_run
       SET blocking_count    = v_blocking,
           warning_count     = v_warning,
           feasibility_score = v_score,
           run_status        = 'completed'
     WHERE run_id = v_run_id;

    UPDATE trip
       SET feasibility_score = v_score,
           status = CASE
                      WHEN status IN ('draft', 'validated', 'blocked')
                      THEN CASE WHEN v_blocking > 0 THEN 'blocked' ELSE 'validated' END
                      ELSE status
                    END
     WHERE trip_id = p_trip_id;

    RAISE NOTICE 'trip % "%": % blocking, % warning, score %',
                 p_trip_id, v_trip.title, v_blocking, v_warning, v_score;
END;
$$;

COMMENT ON PROCEDURE p_check_trip(BIGINT) IS
    'Checks one trip against R01-R08, writes a feasibility_run and its violations, updates the trip. One transaction.';

-- =====================================================================
--  Try it:
--      CALL p_check_trip(30);          -- the R04 test trip
--      SELECT rule_code, severity, message, observed_value, expected_value
--      FROM   violation
--      WHERE  run_id = (SELECT max(run_id) FROM feasibility_run WHERE trip_id = 30);
--
--      CALL p_check_trip(25);          -- cancelled: raises an error and
--                                      -- writes nothing at all
-- =====================================================================
