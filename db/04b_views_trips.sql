-- ============================================================
-- Sanchari — Person B: views on trips & checking tables
-- File: db/04b_views_trips.sql
-- ============================================================

-- v_day_schedule
-- One row per stop, showing the previous stop's departure, the gap
-- in minutes before this stop starts, and how many minutes are
-- allotted at this stop. LAG() looks back one row within the same
-- (trip_id, day_number), ordered by stop_seq.
CREATE VIEW v_day_schedule AS
SELECT
    s.trip_id,
    s.day_number,
    s.stop_seq,
    s.place_id,
    LAG(s.stop_seq) OVER w              AS prev_stop_seq,
    LAG(s.planned_departure) OVER w     AS prev_departure,
    s.planned_arrival,
    s.planned_departure,
    EXTRACT(EPOCH FROM (s.planned_arrival - LAG(s.planned_departure) OVER w)) / 60
                                          AS gap_minutes,
    EXTRACT(EPOCH FROM (s.planned_departure - s.planned_arrival)) / 60
                                          AS allotted_minutes
FROM itinerary_stop s
WINDOW w AS (PARTITION BY s.trip_id, s.day_number ORDER BY s.stop_seq);

-- v_trip_health
-- Each trip alongside its most recent feasibility run, that run's
-- blocking-violation count, and its score. DISTINCT ON picks the
-- single latest row per trip_id (run_at DESC).
CREATE VIEW v_trip_health AS
SELECT DISTINCT ON (t.trip_id)
    t.trip_id,
    t.title,
    t.status,
    r.run_id            AS latest_run_id,
    r.run_at             AS latest_run_at,
    r.blocking_count,
    r.warning_count,
    r.feasibility_score
FROM trip t
LEFT JOIN feasibility_run r ON r.trip_id = t.trip_id
ORDER BY t.trip_id, r.run_at DESC NULLS LAST;
