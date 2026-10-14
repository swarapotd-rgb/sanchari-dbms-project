-- =====================================================================
--  Sanchari · 04b_views_trips.sql
--  Purpose    : Views on the trips & checking half — the day-by-day
--               schedule (what rule R04 reads) and each trip's latest
--               feasibility result (what the trip dashboard reads).
--  Author     : Shreya
--  Runs after : 03b_indexes_trips_checks.sql  (and 01a, for place)
-- =====================================================================


-- =====================================================================
--  VIEW 1 · v_day_schedule
-- ---------------------------------------------------------------------
--  One row per stop, with the place's name, the previous stop's
--  departure, the gap in minutes before this stop starts, and how many
--  minutes are allotted at this stop.
--
--  LAG() looks back one row within the same (trip_id, day_number),
--  ordered by stop_seq. The first stop of each day has no previous
--  stop, so its prev_* and gap_minutes columns are NULL.
--
--  Because planned_arrival / planned_departure are TIMESTAMP (not TIME),
--  the gap is a plain subtraction that still works across midnight.
-- =====================================================================
CREATE VIEW v_day_schedule AS
SELECT
    s.trip_id,
    s.day_number,
    s.stop_seq,
    s.place_id,
    p.name                                  AS place_name,
    LAG(s.stop_seq)          OVER w         AS prev_stop_seq,
    LAG(s.planned_departure) OVER w         AS prev_departure,
    s.planned_arrival,
    s.planned_departure,
    EXTRACT(EPOCH FROM (s.planned_arrival - LAG(s.planned_departure) OVER w)) / 60
                                            AS gap_minutes,
    EXTRACT(EPOCH FROM (s.planned_departure - s.planned_arrival)) / 60
                                            AS allotted_minutes
FROM   itinerary_stop s
JOIN   place          p ON p.place_id = s.place_id
WINDOW w AS (PARTITION BY s.trip_id, s.day_number ORDER BY s.stop_seq);

COMMENT ON VIEW v_day_schedule IS
    'One row per stop with previous departure and gap. Basis of rule R04.';


-- =====================================================================
--  VIEW 2 · v_trip_health
-- ---------------------------------------------------------------------
--  Each trip alongside its most recent feasibility run: that run's
--  blocking and warning counts and its score.
--
--  DISTINCT ON (trip_id) keeps only the first row per trip, and the
--  ORDER BY makes that first row the latest run. LEFT JOIN keeps trips
--  that have never been checked (their run columns are NULL).
-- =====================================================================
CREATE VIEW v_trip_health AS
SELECT DISTINCT ON (t.trip_id)
    t.trip_id,
    t.title,
    t.status,
    r.run_id            AS latest_run_id,
    r.run_at            AS latest_run_at,
    r.blocking_count,
    r.warning_count,
    r.feasibility_score
FROM      trip            t
LEFT JOIN feasibility_run r ON r.trip_id = t.trip_id
ORDER BY  t.trip_id, r.run_at DESC NULLS LAST;

COMMENT ON VIEW v_trip_health IS
    'Each trip with its most recent feasibility run. Feeds the trip dashboard.';
