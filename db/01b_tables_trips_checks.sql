-- =====================================================================
--  Sanchari · 01b_tables_trips_checks.sql
--  Purpose    : Person B's half of the schema — trips, day plans,
--               itinerary stops, feasibility runs, violations, reviews.
--  Author     : Shreya (original)
--  Revised by : Swara — type alignment, named keys, ON DELETE actions,
--               UNIQUE constraints, TIMESTAMP decision.
--  Revised by : Shreya + Swara (round 2) — see CHANGELOG at the end.
--  Runs after : 01a_tables_people_places.sql  (foreign keys point into
--               user_account, place, destination, transport_mode)
--
--  All naming, types and ON DELETE choices follow CONVENTIONS.md.
--  6 tables · 11 foreign keys
-- =====================================================================


-- =====================================================================
--  14. trip
-- ---------------------------------------------------------------------
--  One planned journey. Ordinary strong entity.
--
--  Both foreign keys are deliberately different: deleting a USER should
--  take their trips with them (the trip has no meaning without an
--  owner), but deleting a transport MODE must never delete every trip
--  taken by car.
-- =====================================================================
CREATE TABLE trip (
    -- key
    trip_id             BIGSERIAL,

    -- foreign keys
    owner_user_id       BIGINT          NOT NULL,
    primary_mode_id     INT             NOT NULL,

    -- data
    title               VARCHAR(120)    NOT NULL,
    origin_city         VARCHAR(80),
    start_date          DATE            NOT NULL,
    end_date            DATE            NOT NULL,
    -- multiplies the entry fees when the budget check runs
    party_size          SMALLINT        NOT NULL DEFAULT 1,
    budget_cap          NUMERIC(10,2),
    status              VARCHAR(12)     NOT NULL DEFAULT 'draft',

    -- derived, copied from the most recent feasibility_run
    feasibility_score   NUMERIC(5,2),

    -- timestamps
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_trip PRIMARY KEY (trip_id),

    CONSTRAINT fk_trip_user_account FOREIGN KEY (owner_user_id)
        REFERENCES user_account (user_id) ON DELETE CASCADE,

    CONSTRAINT fk_trip_transport_mode FOREIGN KEY (primary_mode_id)
        REFERENCES transport_mode (mode_id) ON DELETE RESTRICT,

    CONSTRAINT ck_trip_dates      CHECK (end_date >= start_date),
    CONSTRAINT ck_trip_party_size CHECK (party_size > 0),
    CONSTRAINT ck_trip_budget     CHECK (budget_cap IS NULL OR budget_cap >= 0),
    CONSTRAINT ck_trip_status     CHECK (status IN
        ('draft','validated','blocked','locked','completed','cancelled')),
    CONSTRAINT ck_trip_score      CHECK (feasibility_score IS NULL
                                         OR feasibility_score BETWEEN 0 AND 100)
);

COMMENT ON TABLE  trip                    IS 'One planned journey.';
COMMENT ON COLUMN trip.feasibility_score  IS 'Derived; copied from the latest feasibility_run.';


-- =====================================================================
--  15. trip_day
-- ---------------------------------------------------------------------
--  WEAK ENTITY owned by trip. "Day 2" is meaningless; "Day 2 of trip
--  900" is not — so trip_id is part of the primary key AND a foreign key
--  at the same time.
--
--  calendar_date is what closure windows and weekday opening rules are
--  checked against, so it is NOT NULL and unique within the trip.
-- =====================================================================
CREATE TABLE trip_day (
    -- key: owner's key + this table's discriminator
    trip_id             BIGINT      NOT NULL,
    day_number          SMALLINT    NOT NULL,

    -- foreign keys
    base_destination_id INT,

    -- data
    calendar_date       DATE        NOT NULL,
    day_start_time      TIME        NOT NULL DEFAULT '08:00',
    day_end_time        TIME        NOT NULL DEFAULT '21:00',

    -- ---------------- constraints ----------------
    CONSTRAINT pk_trip_day PRIMARY KEY (trip_id, day_number),

    -- identifying relationship: the day cannot outlive its trip
    CONSTRAINT fk_trip_day_trip FOREIGN KEY (trip_id)
        REFERENCES trip (trip_id) ON DELETE CASCADE,

    -- the day survives even if the region record is removed
    CONSTRAINT fk_trip_day_destination FOREIGN KEY (base_destination_id)
        REFERENCES destination (destination_id) ON DELETE SET NULL,

    -- one trip cannot have two Day rows on the same calendar date
    CONSTRAINT uq_trip_day_date UNIQUE (trip_id, calendar_date),

    CONSTRAINT ck_trip_day_number CHECK (day_number > 0),
    CONSTRAINT ck_trip_day_window CHECK (day_end_time > day_start_time)
);

COMMENT ON TABLE  trip_day                IS 'Weak entity owned by trip. One row per day of the journey.';
COMMENT ON COLUMN trip_day.calendar_date  IS 'Checked against opening_rule weekday and closure_window dates.';


-- =====================================================================
--  16. itinerary_stop
-- ---------------------------------------------------------------------
--  A TWO-LEVEL WEAK ENTITY — weak on trip_day, which is itself weak on
--  trip. That is why the primary key is three columns, and why the
--  foreign key to trip_day lists two columns in ONE clause. Two separate
--  single-column keys would not guarantee that the pair exists together.
--
--  planned_arrival / planned_departure are full TIMESTAMPs, not TIME.
--  The date is redundant with trip_day.calendar_date, and we accept that
--  redundancy deliberately: rule R04 compares the previous stop's
--  departure plus the travel-leg duration against this stop's arrival,
--  and doing that arithmetic on bare TIME values breaks the moment a
--  journey crosses midnight. A trigger will be added later to keep the
--  timestamp's date aligned with the parent day's calendar_date — a
--  CHECK constraint cannot do it, because CHECK cannot read another
--  table.
-- =====================================================================
CREATE TABLE itinerary_stop (
    -- key: owner's two-part key + this table's discriminator
    trip_id                 BIGINT          NOT NULL,
    day_number              SMALLINT        NOT NULL,
    stop_seq                SMALLINT        NOT NULL,

    -- foreign keys
    place_id                BIGINT          NOT NULL,

    -- data
    planned_arrival         TIMESTAMP       NOT NULL,
    planned_departure       TIMESTAMP       NOT NULL,
    estimated_cost          NUMERIC(10,2),  -- NULL if the stop's cost hasn't been estimated yet
    notes                   TEXT,

    -- ---------------- constraints ----------------
    CONSTRAINT pk_itinerary_stop PRIMARY KEY (trip_id, day_number, stop_seq),

    -- composite foreign key: both columns in one clause
    CONSTRAINT fk_itinerary_stop_trip_day FOREIGN KEY (trip_id, day_number)
        REFERENCES trip_day (trip_id, day_number) ON DELETE CASCADE,

    -- RESTRICT: deleting a place someone has planned to visit should
    -- fail loudly rather than silently emptying their trip
    CONSTRAINT fk_itinerary_stop_place FOREIGN KEY (place_id)
        REFERENCES place (place_id) ON DELETE RESTRICT,

    CONSTRAINT ck_itinerary_stop_seq   CHECK (stop_seq > 0),
    CONSTRAINT ck_itinerary_stop_times CHECK (planned_departure > planned_arrival),
    CONSTRAINT ck_itinerary_stop_cost  CHECK (estimated_cost IS NULL OR estimated_cost >= 0)
);

COMMENT ON TABLE  itinerary_stop                  IS 'Two-level weak entity. One planned visit within a day.';
COMMENT ON COLUMN itinerary_stop.planned_arrival  IS 'Full timestamp so R04 arithmetic survives midnight crossings.';


-- =====================================================================
--  17. feasibility_run
-- ---------------------------------------------------------------------
--  One "check my plan" attempt. Keeping runs as rows rather than
--  overwriting a status is what lets the interface show a plan getting
--  healthier over time, and makes "which rule fails most often across
--  all trips?" a simple GROUP BY.
-- =====================================================================
CREATE TABLE feasibility_run (
    -- key
    run_id              BIGSERIAL,

    -- foreign keys
    trip_id             BIGINT          NOT NULL,

    -- data
    rules_evaluated     SMALLINT        NOT NULL DEFAULT 8,
    -- both counts are derived from the violation rows below
    blocking_count      INT             NOT NULL DEFAULT 0,
    warning_count       INT             NOT NULL DEFAULT 0,
    feasibility_score   NUMERIC(5,2),
    run_status          VARCHAR(12)     NOT NULL DEFAULT 'running',

    -- timestamps
    run_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_feasibility_run PRIMARY KEY (run_id),

    CONSTRAINT fk_feasibility_run_trip FOREIGN KEY (trip_id)
        REFERENCES trip (trip_id) ON DELETE CASCADE,

    CONSTRAINT ck_feasibility_run_status CHECK (run_status IN
        ('running','completed','failed')),
    CONSTRAINT ck_feasibility_run_counts CHECK (blocking_count >= 0
                                                AND warning_count >= 0),
    CONSTRAINT ck_feasibility_run_score  CHECK (feasibility_score IS NULL
                                                OR feasibility_score BETWEEN 0 AND 100)
);

COMMENT ON TABLE feasibility_run IS 'One validation pass over a trip. History is kept, not overwritten.';


-- =====================================================================
--  18. violation
-- ---------------------------------------------------------------------
--  One problem found. WEAK ENTITY owned by feasibility_run — "violation
--  2" means nothing without knowing which run found it.
--
--  The three stop columns are a single composite foreign key and are ALL
--  nullable, because trip-level problems (over budget, too much driving)
--  belong to no particular stop. They ON DELETE SET NULL rather than
--  CASCADE: this link is optional, not identifying, so a stop being
--  deleted later should turn the violation back into a whole-trip-style
--  record, not erase the fact that the check ever failed.
--  PostgreSQL's default MATCH SIMPLE means the foreign key is simply not
--  enforced when any of the three is NULL — but that also means a
--  HALF-filled reference would slip through unchecked. ck_violation_stop_ref
--  closes that hole: either all three are set, or none are.
--
--  observed_value and expected_value are stored separately, not folded
--  into the message, so the interface can say "arrives 17:45, last entry
--  is 17:00" instead of showing a vague red icon.
-- =====================================================================
CREATE TABLE violation (
    -- key: owner's key + discriminator
    run_id          BIGINT          NOT NULL,
    violation_no    INT             NOT NULL,

    -- foreign key to the offending stop (all three, or none)
    trip_id         BIGINT,
    day_number      SMALLINT,
    stop_seq        SMALLINT,

    -- data
    rule_code       VARCHAR(10)     NOT NULL,
    severity        VARCHAR(10)     NOT NULL,
    message         TEXT            NOT NULL,
    observed_value  VARCHAR(120),
    expected_value  VARCHAR(120),

    -- timestamps
    detected_at     TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_violation PRIMARY KEY (run_id, violation_no),

    CONSTRAINT fk_violation_feasibility_run FOREIGN KEY (run_id)
        REFERENCES feasibility_run (run_id) ON DELETE CASCADE,

    -- three-column composite foreign key, one clause; optional link,
    -- so the violation survives the stop being deleted
    CONSTRAINT fk_violation_itinerary_stop FOREIGN KEY (trip_id, day_number, stop_seq)
        REFERENCES itinerary_stop (trip_id, day_number, stop_seq)
        ON DELETE SET NULL,

    CONSTRAINT ck_violation_rule CHECK (rule_code IN
        ('R01','R02','R03','R04','R05','R06','R07','R08')),

    CONSTRAINT ck_violation_severity CHECK (severity IN
        ('blocking','warning','info')),

    -- all three stop columns set, or all three NULL — never a half
    -- reference, which the foreign key alone would not catch
    CONSTRAINT ck_violation_stop_ref CHECK (
        (trip_id IS NULL     AND day_number IS NULL     AND stop_seq IS NULL)
        OR
        (trip_id IS NOT NULL AND day_number IS NOT NULL AND stop_seq IS NOT NULL)
    )
);

COMMENT ON TABLE  violation                 IS 'Weak entity owned by feasibility_run. One rule failure.';
COMMENT ON COLUMN violation.observed_value  IS 'What the plan says, e.g. 17:45. Kept separate from message.';
COMMENT ON COLUMN violation.expected_value  IS 'What it needed to be, e.g. <= 17:00.';


-- =====================================================================
--  19. review_summary
-- ---------------------------------------------------------------------
--  The countable half of a review. The prose, photos and per-aspect
--  sub-ratings live in MongoDB; mongo_doc_id is the string that links
--  the two halves.
--
--  visited_on is NOT NULL because it is part of the uniqueness rule —
--  one review per person per place per visit. Without that UNIQUE, a
--  single user could post unlimited reviews of one place and quietly
--  corrupt place.avg_rating, which a trigger maintains from this table.
--
--  fk_review_summary_place is RESTRICT, not CASCADE: a place with
--  reviews pointing at it shouldn't disappear and take the reviews with
--  it, the same reasoning CONVENTIONS.md gives for itinerary_stop.
-- =====================================================================
CREATE TABLE review_summary (
    -- key
    review_id            BIGSERIAL,

    -- foreign keys
    place_id             BIGINT         NOT NULL,
    user_id              BIGINT         NOT NULL,

    -- data
    rating               NUMERIC(2,1)   NOT NULL,
    -- the date of the VISIT, not of writing — lets us ask "what is this
    -- place like in December?"
    visited_on           DATE           NOT NULL,
    -- how long it really took; over time this corrects
    -- place.typical_visit_minutes
    actual_duration_min  INT,
    crowd_level          SMALLINT,
    -- the MongoDB ObjectId of the full review document
    mongo_doc_id         CHAR(24),

    -- timestamps
    created_at           TIMESTAMPTZ    NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_review_summary PRIMARY KEY (review_id),

    CONSTRAINT fk_review_summary_place FOREIGN KEY (place_id)
        REFERENCES place (place_id) ON DELETE RESTRICT,

    CONSTRAINT fk_review_summary_user_account FOREIGN KEY (user_id)
        REFERENCES user_account (user_id) ON DELETE CASCADE,

    -- one review per person per place per visit date
    CONSTRAINT uq_review_summary_visit UNIQUE (place_id, user_id, visited_on),

    CONSTRAINT ck_review_summary_rating   CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT ck_review_summary_crowd    CHECK (crowd_level IS NULL
                                                 OR crowd_level BETWEEN 1 AND 5),
    CONSTRAINT ck_review_summary_duration CHECK (actual_duration_min IS NULL
                                                 OR actual_duration_min > 0)
);

COMMENT ON TABLE  review_summary                     IS 'SQL half of a review. Prose and photos live in MongoDB.';
COMMENT ON COLUMN review_summary.actual_duration_min IS 'Feeds back into place.typical_visit_minutes over time.';


-- =====================================================================
--  CHANGELOG — corrections applied to the original commit
--
--  1. TYPES. owner_user_id, place_id, user_id and every trip_id changed
--     from INTEGER to BIGINT; trip_id / run_id / review_id from SERIAL
--     to BIGSERIAL. They now match the BIGSERIAL keys in 01a.
--
--  2. NAMED PRIMARY KEYS. Replaced system-generated names with
--     pk_trip / pk_feasibility_run / pk_review_summary per
--     CONVENTIONS.md §2.
--
--  3. ON DELETE ACTIONS. CASCADE on fk_trip_user_account,
--     fk_review_summary_user_account; SET NULL on fk_trip_day_destination,
--     fk_violation_itinerary_stop; RESTRICT on fk_trip_transport_mode,
--     fk_itinerary_stop_place, fk_review_summary_place.
--
--  4. UNIQUE CONSTRAINTS. uq_trip_day_date and uq_review_summary_visit
--     added.
--
--  5. TIMESTAMP. planned_arrival / planned_departure changed from TIME
--     to TIMESTAMP, so rule R04 arithmetic survives a midnight crossing.
--
--  6. MISSING CHECKS. ck_trip_budget, ck_trip_day_window,
--     ck_itinerary_stop_cost, ck_feasibility_run_counts,
--     ck_review_summary_duration, and ck_violation_stop_ref added.
--     'cancelled' added to trip status, 'info' to violation severity.
--
--  7. CONSTRAINT NAMES aligned to fk_<child>_<parent> per CONVENTIONS.md.
--
--  ROUND 2 (Shreya + Swara, after review):
--  8. ON DELETE corrected on fk_review_summary_place (CASCADE -> RESTRICT)
--     and fk_violation_itinerary_stop (CASCADE -> SET NULL), per
--     CONVENTIONS.md §6's reference-data and optional-link rules.
--  9. CONSTRAINT NAMES un-shortened: fk_itinerary_stop_day ->
--     fk_itinerary_stop_trip_day, fk_violation_run ->
--     fk_violation_feasibility_run, fk_violation_stop ->
--     fk_violation_itinerary_stop, fk_review_summary_user ->
--     fk_review_summary_user_account, fk_trip_owner ->
--     fk_trip_user_account, fk_trip_mode -> fk_trip_transport_mode.
--  10. estimated_cost made nullable again (was NOT NULL DEFAULT 0),
--      so "not yet estimated" is distinguishable from "costs nothing."
--
--  Sanity check with 01a:
--      SELECT count(*) FROM information_schema.tables
--      WHERE table_schema='public' AND table_type='BASE TABLE';   -- 19
--
--      SELECT count(*) FROM information_schema.table_constraints
--      WHERE constraint_type='FOREIGN KEY' AND table_schema='public'; -- 24
-- =====================================================================
