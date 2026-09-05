-- ============================================================
-- Sanchari — Person B: Trips & Checking tables
-- File: db/01b_tables_trips_checks.sql
-- Depends on: db/01a_tables_people_places.sql (must run first —
--   these tables have foreign keys into user_account, place,
--   destination and transport_mode).
-- ============================================================

-- ------------------------------------------------------------
-- 11. TRIP  (strong entity)
-- ------------------------------------------------------------
CREATE TABLE trip (
    trip_id             SERIAL PRIMARY KEY,
    owner_user_id       INTEGER NOT NULL,
    title               VARCHAR(120) NOT NULL,
    origin_city         VARCHAR(80),
    start_date          DATE NOT NULL,
    end_date            DATE NOT NULL,
    party_size          INTEGER NOT NULL DEFAULT 1,
    budget_cap          NUMERIC(10,2),
    primary_mode_id     INTEGER,
    status              VARCHAR(20) NOT NULL DEFAULT 'draft',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    feasibility_score   INTEGER,

    CONSTRAINT fk_trip_owner
        FOREIGN KEY (owner_user_id) REFERENCES user_account(user_id),
    CONSTRAINT fk_trip_mode
        FOREIGN KEY (primary_mode_id) REFERENCES transport_mode(mode_id),
    CONSTRAINT ck_trip_dates
        CHECK (end_date >= start_date),
    CONSTRAINT ck_trip_party_size
        CHECK (party_size > 0),
    CONSTRAINT ck_trip_status
        CHECK (status IN ('draft','validated','blocked','locked','completed')),
    CONSTRAINT ck_trip_score
        CHECK (feasibility_score IS NULL OR feasibility_score BETWEEN 0 AND 100)
);

-- ------------------------------------------------------------
-- 12. TRIP_DAY  (weak entity — owned by TRIP)
-- PK = trip_id (owner key) + day_number (partial key)
-- ------------------------------------------------------------
CREATE TABLE trip_day (
    trip_id             INTEGER NOT NULL,
    day_number          INTEGER NOT NULL,
    calendar_date       DATE NOT NULL,
    base_destination_id INTEGER,
    day_start_time      TIME,
    day_end_time        TIME,

    CONSTRAINT pk_trip_day
        PRIMARY KEY (trip_id, day_number),
    CONSTRAINT fk_trip_day_trip
        FOREIGN KEY (trip_id) REFERENCES trip(trip_id) ON DELETE CASCADE,
    CONSTRAINT fk_trip_day_destination
        FOREIGN KEY (base_destination_id) REFERENCES destination(destination_id),
    CONSTRAINT ck_trip_day_number
        CHECK (day_number > 0)
);

-- ------------------------------------------------------------
-- 13. ITINERARY_STOP  (two-level weak entity — owned by TRIP_DAY)
-- PK = trip_id + day_number (owner key) + stop_seq (partial key)
-- ------------------------------------------------------------
CREATE TABLE itinerary_stop (
    trip_id                 INTEGER NOT NULL,
    day_number              INTEGER NOT NULL,
    stop_seq                INTEGER NOT NULL,
    place_id                INTEGER NOT NULL,
    planned_arrival         TIME NOT NULL,
    planned_departure       TIME NOT NULL,
    estimated_cost          NUMERIC(10,2),
    notes                   TEXT,

    CONSTRAINT pk_itinerary_stop
        PRIMARY KEY (trip_id, day_number, stop_seq),
    CONSTRAINT fk_stop_trip_day
        FOREIGN KEY (trip_id, day_number)
        REFERENCES trip_day(trip_id, day_number) ON DELETE CASCADE,
    CONSTRAINT fk_stop_place
        FOREIGN KEY (place_id) REFERENCES place(place_id),
    CONSTRAINT ck_stop_seq
        CHECK (stop_seq > 0),
    CONSTRAINT ck_stop_times
        CHECK (planned_departure > planned_arrival)
);

-- ------------------------------------------------------------
-- 14. FEASIBILITY_RUN  (strong entity)
-- ------------------------------------------------------------
CREATE TABLE feasibility_run (
    run_id              SERIAL PRIMARY KEY,
    trip_id             INTEGER NOT NULL,
    run_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    rules_evaluated     INTEGER,
    blocking_count      INTEGER NOT NULL DEFAULT 0,
    warning_count       INTEGER NOT NULL DEFAULT 0,
    feasibility_score   INTEGER,
    run_status          VARCHAR(20) NOT NULL DEFAULT 'running',

    CONSTRAINT fk_run_trip
        FOREIGN KEY (trip_id) REFERENCES trip(trip_id) ON DELETE CASCADE,
    CONSTRAINT ck_run_status
        CHECK (run_status IN ('running','completed','failed')),
    CONSTRAINT ck_run_score
        CHECK (feasibility_score IS NULL OR feasibility_score BETWEEN 0 AND 100)
);

-- ------------------------------------------------------------
-- 15. VIOLATION  (weak entity — owned by FEASIBILITY_RUN)
-- PK = run_id (owner key) + violation_no (partial key)
-- The (trip_id, day_number, stop_seq) FK is nullable — trip-level
-- problems (e.g. over budget) belong to no particular stop.
-- ------------------------------------------------------------
CREATE TABLE violation (
    run_id          INTEGER NOT NULL,
    violation_no    INTEGER NOT NULL,
    rule_code       VARCHAR(10) NOT NULL,
    severity        VARCHAR(20) NOT NULL,
    trip_id         INTEGER,
    day_number      INTEGER,
    stop_seq        INTEGER,
    message         TEXT,
    observed_value  TEXT,
    expected_value  TEXT,

    CONSTRAINT pk_violation
        PRIMARY KEY (run_id, violation_no),
    CONSTRAINT fk_violation_run
        FOREIGN KEY (run_id) REFERENCES feasibility_run(run_id) ON DELETE CASCADE,
    CONSTRAINT fk_violation_stop
        FOREIGN KEY (trip_id, day_number, stop_seq)
        REFERENCES itinerary_stop(trip_id, day_number, stop_seq),
    CONSTRAINT ck_violation_severity
        CHECK (severity IN ('blocking','warning')),
    CONSTRAINT ck_violation_rule
        CHECK (rule_code IN ('R01','R02','R03','R04','R05','R06','R07','R08'))
);

-- ------------------------------------------------------------
-- 16. REVIEW_SUMMARY  (strong entity)
-- The SQL half of a review; text/photos live in MongoDB, linked
-- via mongo_doc_id.
-- ------------------------------------------------------------
CREATE TABLE review_summary (
    review_id           SERIAL PRIMARY KEY,
    place_id             INTEGER NOT NULL,
    user_id              INTEGER NOT NULL,
    rating               NUMERIC(2,1) NOT NULL,
    visited_on           DATE,
    actual_duration_min  INTEGER,
    crowd_level          INTEGER,
    mongo_doc_id         VARCHAR(64),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_review_place
        FOREIGN KEY (place_id) REFERENCES place(place_id),
    CONSTRAINT fk_review_user
        FOREIGN KEY (user_id) REFERENCES user_account(user_id),
    CONSTRAINT ck_review_rating
        CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT ck_review_crowd
        CHECK (crowd_level IS NULL OR crowd_level BETWEEN 1 AND 5)
);
