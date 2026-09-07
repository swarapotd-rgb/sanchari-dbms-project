-- ============================================================
-- Sanchari — Person B: indexes on trips & checking tables
-- File: db/03b_indexes_trips_checks.sql
-- Run after 01a + 01b (needs the tables to exist).
-- ============================================================

-- ============ foreign-key indexes ====================================
--
-- PostgreSQL indexes primary keys and UNIQUE constraints automatically,
-- but NOT foreign key columns. An un-indexed foreign key forces a full
-- scan of the child table every time a parent row is deleted.
--
-- Not created, deliberately:
--   itinerary_stop (trip_id, day_number) -> trip_day. Already covered:
--   pk_itinerary_stop is (trip_id, day_number, stop_seq) and those are
--   its two leading columns, so the primary key index serves it.
-- ---------------------------------------------------------------------

-- "All my trips" -- the first query the app runs after login. Also keeps
-- deleting a user_account from scanning every trip.
CREATE INDEX idx_trip_owner
    ON trip (owner_user_id);

-- Foreign key to transport_mode.
CREATE INDEX idx_trip_primary_mode
    ON trip (primary_mode_id);

-- Dashboard filtering: "show me my planned trips", "my completed trips".
CREATE INDEX idx_trip_status
    ON trip (status);

-- Foreign key to destination.
CREATE INDEX idx_trip_day_destination
    ON trip_day (base_destination_id);

-- The full three-column foreign key from violation to itinerary_stop.
-- One index on all three columns in key order serves the constraint.
CREATE INDEX idx_violation_stop
    ON violation (trip_id, day_number, stop_seq);

-- idx_violation_blocking below is PARTIAL, so it cannot be used to check
-- for orphans when a feasibility_run is deleted -- a non-blocking
-- violation would not be in it. This full index covers that.
CREATE INDEX idx_violation_run
    ON violation (run_id);

-- Foreign key to user_account, and "every review this user wrote".
CREATE INDEX idx_review_summary_user
    ON review_summary (user_id);


-- ============ query-driven indexes ===================================

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
