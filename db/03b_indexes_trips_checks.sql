-- ============================================================
-- Sanchari — Person B: indexes on trips & checking tables
-- File: db/03b_indexes_trips_checks.sql
-- Run after 01a + 01b (needs the tables to exist).
-- ============================================================

-- Every stop at a given place — used to build "places I've booked"
-- and to join into review/rating lookups per place.
CREATE INDEX idx_itinerary_stop_place
    ON itinerary_stop (place_id);

-- Stops ordered by arrival time — used by the schedule view and by
-- rule checks that scan a day in time order.
CREATE INDEX idx_itinerary_stop_arrival
    ON itinerary_stop (planned_arrival);

-- "Give me the latest check for this trip" — DESC on run_at so the
-- most recent run is first without an extra sort at query time.
CREATE INDEX idx_feasibility_run_trip_latest
    ON feasibility_run (trip_id, run_at DESC);

-- "Which rule fails most often" — a GROUP BY rule_code query.
CREATE INDEX idx_violation_rule
    ON violation (rule_code);

-- Partial index: most dashboards only care about blocking
-- violations, so index just that subset — smaller and faster
-- than indexing every row.
CREATE INDEX idx_violation_blocking
    ON violation (run_id)
    WHERE severity = 'blocking';

-- All reviews for a place — feeds the avg_rating / review_count
-- trigger on place, and per-place review listings.
CREATE INDEX idx_review_summary_place
    ON review_summary (place_id);
