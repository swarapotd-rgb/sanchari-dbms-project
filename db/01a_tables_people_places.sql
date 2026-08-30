-- =====================================================================
--  Sanchari · 01a_tables_people_places.sql
--  Purpose    : Person A's half of the schema — 13 tables covering
--               people, their preferences, places, and the real-world
--               rules that govern when a place is available.
--  Author     : Swara
--  Runs after : 00_extensions.sql
--  Runs before: 01b_tables_trips_checks.sql  (B's tables reference these)
--
--  All naming, types and ON DELETE choices follow CONVENTIONS.md.
--  Tables are in dependency order — a table only ever references one
--  defined above it.
--
--  13 tables · 13 foreign keys
-- =====================================================================


-- =====================================================================
--  1. role
-- ---------------------------------------------------------------------
--  What kind of user someone is. Three rows will ever live here:
--  Traveller, Curator, Admin. Requirement 11 needs at least two roles.
--
--  Why a table rather than a plain text column on user_account: with a
--  table, the foreign key makes an invalid role impossible. A typo like
--  'admn' would silently create a user with no permissions.
-- =====================================================================
CREATE TABLE role (
    role_id         SERIAL,
    role_name       VARCHAR(30)     NOT NULL,
    description     TEXT,

    CONSTRAINT pk_role           PRIMARY KEY (role_id),
    -- role names must be distinct or the login layer can't resolve them
    CONSTRAINT uq_role_name      UNIQUE (role_name),
    CONSTRAINT ck_role_name_set  CHECK (role_name IN ('Traveller','Curator','Admin'))
);

COMMENT ON TABLE  role            IS 'Access roles. Requirement 11 (minimum 2 roles).';
COMMENT ON COLUMN role.role_name  IS 'Traveller | Curator | Admin';


-- =====================================================================
--  2. user_account
-- ---------------------------------------------------------------------
--  Login and identity only — nothing about travel preferences, those
--  live in traveller_profile.
--
--  N:1 to role: many users hold one role. Total participation on the
--  user side (role_id is NOT NULL — every account must have a role),
--  partial on the role side (a role can exist with nobody in it).
-- =====================================================================
CREATE TABLE user_account (
    -- key
    user_id         BIGSERIAL,

    -- foreign keys
    role_id         INT             NOT NULL,

    -- data
    email           VARCHAR(120)    NOT NULL,
    -- requirement 13: never store the real password. This holds a bcrypt
    -- hash, which cannot be reversed back into the password.
    password_hash   VARCHAR(255)    NOT NULL,
    display_name    VARCHAR(80)     NOT NULL,
    -- where they usually set off from; becomes the default trip origin
    home_city       VARCHAR(60),
    account_status  VARCHAR(15)     NOT NULL DEFAULT 'active',

    -- timestamps
    date_joined     TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_user_account PRIMARY KEY (user_id),

    -- email is the login name, so it must be unique
    CONSTRAINT uq_user_account_email UNIQUE (email),

    -- RESTRICT, not CASCADE: deleting a role must never silently delete
    -- every user who held it. Force the admin to reassign them first.
    CONSTRAINT fk_user_account_role FOREIGN KEY (role_id)
        REFERENCES role (role_id) ON DELETE RESTRICT,

    CONSTRAINT ck_user_account_status CHECK (account_status IN
        ('active','suspended','deleted')),

    -- cheap sanity check; real validation happens in the app too
    CONSTRAINT ck_user_account_email_shape CHECK (email LIKE '%@%.%')
);

COMMENT ON TABLE  user_account                IS 'Login and identity. Preferences live in traveller_profile.';
COMMENT ON COLUMN user_account.password_hash  IS 'bcrypt hash — never plaintext (requirement 13).';


-- =====================================================================
--  3. traveller_profile
-- ---------------------------------------------------------------------
--  The traveller's personal limits — what the feasibility engine reads
--  to decide whether a plan suits THIS person.
--
--  1:1 with user_account. The UNIQUE on user_id is what makes it 1:1
--  rather than 1:N — without it, one user could have many profiles.
--  Total participation on this side (a profile cannot exist without its
--  user), partial on the user side (you can sign up and never fill it
--  in). That asymmetry is why the ER diagram has a thick line on one end
--  and a thin one on the other.
--
--  Split from user_account rather than merged into it because roughly
--  half of users never fill it in, and merging would put six nullable
--  columns on the login table.
-- =====================================================================
CREATE TABLE traveller_profile (
    -- key
    profile_id                BIGSERIAL,

    -- foreign keys
    user_id                   BIGINT        NOT NULL,

    -- data
    -- controls how much spare time the engine leaves between stops
    default_pace              VARCHAR(10)   NOT NULL DEFAULT 'moderate',
    -- rupees per day; read by the budget check
    max_daily_budget          NUMERIC(10,2),
    -- how many hours of actual travelling they will tolerate in one day;
    -- read by the pace check
    max_travel_hours_per_day  NUMERIC(4,2),
    -- composite attribute `active_window`, flattened: the hours they are
    -- willing to be out. Every day plan is bounded by these.
    day_start_time            TIME          NOT NULL DEFAULT '08:00',
    day_end_time              TIME          NOT NULL DEFAULT '20:00',

    -- timestamps
    updated_at                TIMESTAMPTZ   NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_traveller_profile PRIMARY KEY (profile_id),

    -- this UNIQUE is what enforces the 1:1
    CONSTRAINT uq_traveller_profile_user UNIQUE (user_id),

    -- CASCADE: the profile is meaningless without its user
    CONSTRAINT fk_traveller_profile_user FOREIGN KEY (user_id)
        REFERENCES user_account (user_id) ON DELETE CASCADE,

    CONSTRAINT ck_traveller_profile_pace CHECK (default_pace IN
        ('slow','moderate','packed')),

    CONSTRAINT ck_traveller_profile_budget CHECK (
        max_daily_budget IS NULL OR max_daily_budget >= 0),

    -- 14 hours is already an unreasonable day; beyond that is bad data
    CONSTRAINT ck_traveller_profile_hours CHECK (
        max_travel_hours_per_day IS NULL
        OR max_travel_hours_per_day BETWEEN 0 AND 14),

    CONSTRAINT ck_traveller_profile_window CHECK (day_end_time > day_start_time)
);

COMMENT ON TABLE  traveller_profile      IS 'Constraint vector the feasibility engine reads. 1:1 with user_account.';
COMMENT ON COLUMN traveller_profile.max_travel_hours_per_day IS 'Read by the daily pace check (R07).';


-- =====================================================================
--  4. interest_category
-- ---------------------------------------------------------------------
--  The shared vocabulary — Nature, History, Waterfalls, Trekking...
--  Used on BOTH sides: people say how much they like each one, and
--  places say which ones they belong to. Recommendation is then just
--  matching the two, which only works because both sides speak the same
--  category_id.
-- =====================================================================
CREATE TABLE interest_category (
    -- key
    category_id     SERIAL,

    -- data
    name            VARCHAR(50)     NOT NULL,
    -- lowercase, no spaces — used in URLs and filter chips
    slug            VARCHAR(50)     NOT NULL,
    description     TEXT,

    -- ---------------- constraints ----------------
    CONSTRAINT pk_interest_category  PRIMARY KEY (category_id),
    CONSTRAINT uq_interest_category_slug UNIQUE (slug),
    CONSTRAINT uq_interest_category_name UNIQUE (name),
    -- a slug with spaces or capitals would break the URLs it feeds
    CONSTRAINT ck_interest_category_slug CHECK (slug ~ '^[a-z0-9-]+$')
);

COMMENT ON TABLE interest_category IS 'Shared category vocabulary, used by both travellers and places.';


-- =====================================================================
--  5. traveller_interest
-- ---------------------------------------------------------------------
--  The M:N bridge between traveller_profile and interest_category.
--
--  This table exists ONLY because a column cannot hold many values. A
--  traveller likes many categories; a category is liked by many
--  travellers. Neither side can store the other as a column, so the
--  relationship becomes its own table.
--
--  `weight` is an attribute of the PAIRING, not of the person and not of
--  the category — how strongly *this* traveller likes *this* category.
--  That is exactly when an attribute belongs on the relationship.
-- =====================================================================
CREATE TABLE traveller_interest (
    -- key: both foreign keys together
    profile_id      BIGINT          NOT NULL,
    category_id     INT             NOT NULL,

    -- data
    -- 1 = mild interest, 5 = strong. Multiplied against place_category
    -- .relevance to produce the recommendation score.
    weight          NUMERIC(3,1)    NOT NULL DEFAULT 3.0,

    -- timestamps
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    -- the composite key is what stops the same person rating the same
    -- category twice
    CONSTRAINT pk_traveller_interest PRIMARY KEY (profile_id, category_id),

    CONSTRAINT fk_traveller_interest_profile FOREIGN KEY (profile_id)
        REFERENCES traveller_profile (profile_id) ON DELETE CASCADE,

    CONSTRAINT fk_traveller_interest_category FOREIGN KEY (category_id)
        REFERENCES interest_category (category_id) ON DELETE CASCADE,

    CONSTRAINT ck_traveller_interest_weight CHECK (weight BETWEEN 1 AND 5)
);

COMMENT ON TABLE  traveller_interest         IS 'M:N bridge. Mapped from the PREFERS relationship.';
COMMENT ON COLUMN traveller_interest.weight  IS 'Relationship attribute: strength of preference, 1-5.';


-- =====================================================================
--  6. destination
-- ---------------------------------------------------------------------
--  A region or town — Coorg, Hampi, Chikkamagaluru. The bigger area that
--  individual attractions sit inside.
--
--  Why separate from place: if every place stored its own
--  "Coorg / Kodagu / Karnataka", those three words would repeat across
--  dozens of rows. Change the district name once and you would have to
--  fix every row — miss one and your data disagrees with itself. That is
--  an update anomaly, and avoiding it is what normalisation means.
-- =====================================================================
CREATE TABLE destination (
    -- key
    destination_id      SERIAL,

    -- data
    name                VARCHAR(80)     NOT NULL,
    district            VARCHAR(60),
    state               VARCHAR(60)     NOT NULL,
    -- composite attribute `centroid`, flattened — the middle of the
    -- region, used to centre the map view
    dest_lat            NUMERIC(9,6),
    dest_lon            NUMERIC(9,6),
    -- rough cost of staying there per day; feeds the budget estimate
    base_cost_per_day   NUMERIC(10,2),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_destination PRIMARY KEY (destination_id),

    -- two states could each have a town of the same name, so the PAIR is
    -- what is actually unique, not the name alone
    CONSTRAINT uq_destination_name_state UNIQUE (name, state),

    CONSTRAINT ck_destination_lat CHECK (
        dest_lat IS NULL OR dest_lat BETWEEN -90 AND 90),
    CONSTRAINT ck_destination_lon CHECK (
        dest_lon IS NULL OR dest_lon BETWEEN -180 AND 180),
    CONSTRAINT ck_destination_cost CHECK (
        base_cost_per_day IS NULL OR base_cost_per_day >= 0)
);

COMMENT ON TABLE destination IS 'Region or town containing places. Separate from place to avoid update anomalies.';


-- =====================================================================
--  7. transport_mode
-- ---------------------------------------------------------------------
--  Car, bike, bus. A small table, but it is what makes travel time
--  depend on HOW you travel — the same road takes very different times
--  by car and by bus. It is also the third leg of the ternary
--  relationship in travel_leg.
-- =====================================================================
CREATE TABLE transport_mode (
    -- key
    mode_id         SERIAL,

    -- data
    mode_name       VARCHAR(20)     NOT NULL,
    -- fallback speed when no measured travel time exists for a pair of
    -- places; the engine then estimates duration from distance
    avg_speed_kmph  NUMERIC(5,2)    NOT NULL,
    -- fuel or fare per km; used in the budget check
    cost_per_km     NUMERIC(6,2)    NOT NULL DEFAULT 0,

    -- ---------------- constraints ----------------
    CONSTRAINT pk_transport_mode      PRIMARY KEY (mode_id),
    CONSTRAINT uq_transport_mode_name UNIQUE (mode_name),
    CONSTRAINT ck_transport_mode_name CHECK (mode_name IN
        ('car','bike','bus','train','walk')),
    CONSTRAINT ck_transport_mode_speed CHECK (avg_speed_kmph > 0),
    CONSTRAINT ck_transport_mode_cost  CHECK (cost_per_km >= 0)
);

COMMENT ON TABLE transport_mode IS 'Travel modes. Third participant in the CONNECTED_BY ternary relationship.';


-- =====================================================================
--  8. place
-- ---------------------------------------------------------------------
--  The hub of the whole schema. Note three things while reading it:
--
--   (a) COMPOSITE ATTRIBUTES ARE FLATTENED. On the ER diagram
--       `coordinates` and `entry_fee` are single ovals with children.
--       SQL has no sub-column, so each child becomes an ordinary column.
--
--   (b) DERIVED ATTRIBUTES ARE STORED HERE. avg_rating and review_count
--       are dashed ovals on the diagram. We store them and let a trigger
--       keep them current, because they are read on every place card and
--       recomputed rarely. That is a deliberate trade, not an oversight.
--
--   (c) EVERY CHECK ENCODES A REAL RULE. requires_daylight isn't
--       decoration — rule R06 refuses a waterfall scheduled after sunset,
--       and this boolean is what it reads.
-- =====================================================================
CREATE TABLE place (
    -- key
    place_id                BIGSERIAL,

    -- foreign keys
    destination_id          INT             NOT NULL,

    -- data
    name                    VARCHAR(120)    NOT NULL,
    place_type              VARCHAR(25)     NOT NULL,
    -- composite attribute `coordinates`, flattened.
    -- NUMERIC(9,6) gives ~11 cm precision — plenty for a map pin, and
    -- exact, unlike FLOAT.
    latitude                NUMERIC(9,6)    NOT NULL,
    longitude               NUMERIC(9,6)    NOT NULL,
    -- how long a normal visit takes. Rule R05 compares the time the
    -- traveller allotted against this.
    typical_visit_minutes   INT             NOT NULL,
    -- composite attribute `entry_fee`, flattened. Two prices because
    -- Indian and foreign tariffs genuinely differ at ASI sites.
    fee_indian              NUMERIC(8,2)    NOT NULL DEFAULT 0,
    fee_foreign             NUMERIC(8,2)    NOT NULL DEFAULT 0,
    -- true for waterfalls, trails, viewpoints. Read by rule R06.
    requires_daylight       BOOLEAN         NOT NULL DEFAULT FALSE,

    -- derived, maintained by a trigger on review_summary
    avg_rating              NUMERIC(3,2),
    review_count            INT             NOT NULL DEFAULT 0,

    -- timestamps
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_place PRIMARY KEY (place_id),

    -- RESTRICT, not CASCADE: deleting a destination must not silently
    -- delete every attraction in it. Force the user to deal with them.
    CONSTRAINT fk_place_destination FOREIGN KEY (destination_id)
        REFERENCES destination (destination_id) ON DELETE RESTRICT,

    -- the same attraction name can repeat across regions (every district
    -- has a "Shiva Temple"), so uniqueness is name + region, not name
    CONSTRAINT uq_place_name_destination UNIQUE (name, destination_id),

    -- a fixed vocabulary, so nobody types 'watrfall' and breaks filtering
    CONSTRAINT ck_place_type CHECK (place_type IN
        ('fort','beach','temple','trail','wildlife','waterfall',
         'museum','market','viewpoint','lake','heritage')),

    CONSTRAINT ck_place_latitude  CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT ck_place_longitude CHECK (longitude BETWEEN -180 AND 180),

    -- a visit of zero minutes is meaningless and would break R05
    CONSTRAINT ck_place_visit_minutes CHECK (typical_visit_minutes > 0),

    CONSTRAINT ck_place_fees CHECK (fee_indian >= 0 AND fee_foreign >= 0),

    -- NULL until the first review arrives, then 0-5
    CONSTRAINT ck_place_avg_rating   CHECK (avg_rating IS NULL
                                            OR avg_rating BETWEEN 0 AND 5),
    CONSTRAINT ck_place_review_count CHECK (review_count >= 0)
);

COMMENT ON TABLE  place                    IS 'One visitable attraction.';
COMMENT ON COLUMN place.requires_daylight  IS 'Read by feasibility rule R06 (daylight).';
COMMENT ON COLUMN place.avg_rating         IS 'Derived; maintained by trigger on review_summary.';


-- =====================================================================
--  9. place_category
-- ---------------------------------------------------------------------
--  The second M:N bridge — a place belongs to many categories, a
--  category covers many places. Mirror of traveller_interest.
--
--  `relevance` is again an attribute of the pairing: Abbey Falls is
--  strongly Waterfalls (1.00) and mildly Nature (0.60). Neither the
--  place nor the category owns that number on its own.
-- =====================================================================
CREATE TABLE place_category (
    -- key: both foreign keys together
    place_id        BIGINT          NOT NULL,
    category_id     INT             NOT NULL,

    -- data
    relevance       NUMERIC(3,2)    NOT NULL DEFAULT 1.00,

    -- ---------------- constraints ----------------
    CONSTRAINT pk_place_category PRIMARY KEY (place_id, category_id),

    CONSTRAINT fk_place_category_place FOREIGN KEY (place_id)
        REFERENCES place (place_id) ON DELETE CASCADE,

    CONSTRAINT fk_place_category_category FOREIGN KEY (category_id)
        REFERENCES interest_category (category_id) ON DELETE CASCADE,

    CONSTRAINT ck_place_category_relevance CHECK (relevance BETWEEN 0 AND 1)
);

COMMENT ON TABLE  place_category            IS 'M:N bridge. Mapped from the TAGGED_AS relationship.';
COMMENT ON COLUMN place_category.relevance  IS 'Relationship attribute: how strongly this place fits this category, 0-1.';


-- =====================================================================
--  10. opening_rule
-- ---------------------------------------------------------------------
--  A WEAK ENTITY. Study the key: (place_id, rule_no).
--
--  "Rule 3" means nothing. "Rule 3 of Mysore Palace" means something.
--  So the table borrows its identity from its owner — place_id is part
--  of the primary key AND a foreign key at the same time. That double
--  duty is the signature of every weak entity in this schema, and it is
--  what the "PK,FK" marker means on the relational schema diagram.
--
--  ON DELETE CASCADE is not optional here. An opening rule cannot
--  outlive its place, so deletion must propagate.
--
--  This is also where the project's single most valuable column lives:
--  last_entry_at. Ticket counters shut before gates do, and nothing else
--  models that. It is the whole reason rule R02 exists.
-- =====================================================================
CREATE TABLE opening_rule (
    -- key: owner's key + this table's own discriminator
    place_id        BIGINT      NOT NULL,
    rule_no         SMALLINT    NOT NULL,

    -- data
    -- 0 = Sunday ... 6 = Saturday. A place closed on Mondays simply has
    -- no row for day 1 — absence is the closure, which keeps rule R01 a
    -- simple "is there a matching row?" test.
    day_of_week     SMALLINT    NOT NULL,
    opens_at        TIME        NOT NULL,
    closes_at       TIME        NOT NULL,
    -- NULL means there is no separate cut-off; the engine falls back to
    -- closes_at. Read by rule R02.
    last_entry_at   TIME,

    -- ---------------- constraints ----------------
    -- composite key: rule_no alone is not unique across the table
    CONSTRAINT pk_opening_rule PRIMARY KEY (place_id, rule_no),

    CONSTRAINT fk_opening_rule_place FOREIGN KEY (place_id)
        REFERENCES place (place_id) ON DELETE CASCADE,

    CONSTRAINT ck_opening_rule_day CHECK (day_of_week BETWEEN 0 AND 6),

    -- a place cannot close before it opens
    CONSTRAINT ck_opening_rule_hours CHECK (closes_at > opens_at),

    -- last entry must fall inside opening hours, if it is set at all
    CONSTRAINT ck_opening_rule_last_entry CHECK (
        last_entry_at IS NULL
        OR (last_entry_at > opens_at AND last_entry_at <= closes_at)
    ),

    -- one rule per weekday per place; two rows for the same Wednesday
    -- would make R01 ambiguous
    CONSTRAINT uq_opening_rule_place_day UNIQUE (place_id, day_of_week)
);

COMMENT ON TABLE  opening_rule                IS 'Weak entity owned by place. Weekly opening pattern.';
COMMENT ON COLUMN opening_rule.rule_no        IS 'Partial key — unique only within one place.';
COMMENT ON COLUMN opening_rule.last_entry_at  IS 'Ticket cut-off. Read by feasibility rule R02.';


-- =====================================================================
--  11. closure_window
-- ---------------------------------------------------------------------
--  The second weak entity on place, same shape as opening_rule.
--
--  Opening rules describe the normal week; this describes the
--  exceptions — monsoon shutdowns, maintenance, festival restrictions.
--  A closure beats an opening rule: if today falls inside a closure
--  window, the place is shut no matter what the weekday pattern says.
--  Read by rule R03.
-- =====================================================================
CREATE TABLE closure_window (
    -- key: owner's key + discriminator
    place_id             BIGINT         NOT NULL,
    closure_no           SMALLINT       NOT NULL,

    -- data
    start_date           DATE           NOT NULL,
    end_date             DATE           NOT NULL,
    reason_code          VARCHAR(25)    NOT NULL,
    -- TRUE means the same dates apply every year, so one row covers all
    -- future monsoons instead of needing a new row annually
    is_annual_recurring  BOOLEAN        NOT NULL DEFAULT FALSE,

    -- timestamps
    recorded_at          TIMESTAMPTZ    NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_closure_window PRIMARY KEY (place_id, closure_no),

    CONSTRAINT fk_closure_window_place FOREIGN KEY (place_id)
        REFERENCES place (place_id) ON DELETE CASCADE,

    -- a closure cannot end before it starts
    CONSTRAINT ck_closure_window_dates CHECK (end_date >= start_date),

    CONSTRAINT ck_closure_window_reason CHECK (reason_code IN
        ('monsoon','maintenance','festival','breeding_season',
         'govt_order','other'))
);

COMMENT ON TABLE  closure_window                      IS 'Weak entity owned by place. Dated exceptions that override opening_rule.';
COMMENT ON COLUMN closure_window.is_annual_recurring  IS 'TRUE = same dates every year (e.g. monsoon).';


-- =====================================================================
--  12. travel_leg
-- ---------------------------------------------------------------------
--  The TERNARY relationship, mapped. Three foreign keys, and all three
--  together form the primary key.
--
--  Why three-sided: travel time is NOT a fact about a pair of places.
--  Coorg to Mysore is roughly 3 hours by car and 5 by bus. If the
--  relationship only linked place to place, there would be nowhere to
--  put that difference. Three entities genuinely participate, so the
--  relationship is ternary — and note that PLACE participates twice, as
--  origin and as destination, which is why the two foreign keys need
--  different names (CONVENTIONS.md §2, the disambiguated case).
--
--  This table is what rule R04 reads to decide whether there is actually
--  enough time to get from the previous stop to this one.
-- =====================================================================
CREATE TABLE travel_leg (
    -- key: all three participants together
    from_place_id         BIGINT          NOT NULL,
    to_place_id           BIGINT          NOT NULL,
    mode_id               INT             NOT NULL,

    -- data
    distance_km           NUMERIC(7,2)    NOT NULL,
    -- measured, not computed from distance: 40 km of ghat road is not
    -- 40 km of highway
    typical_duration_min  INT             NOT NULL,
    -- NULL means we have no monsoon measurement; the engine falls back
    -- to typical_duration_min
    monsoon_duration_min  INT,
    toll_cost             NUMERIC(7,2)    NOT NULL DEFAULT 0,

    -- timestamps
    last_updated          TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_travel_leg PRIMARY KEY (from_place_id, to_place_id, mode_id),

    CONSTRAINT fk_travel_leg_from_place FOREIGN KEY (from_place_id)
        REFERENCES place (place_id) ON DELETE CASCADE,

    CONSTRAINT fk_travel_leg_to_place FOREIGN KEY (to_place_id)
        REFERENCES place (place_id) ON DELETE CASCADE,

    CONSTRAINT fk_travel_leg_mode FOREIGN KEY (mode_id)
        REFERENCES transport_mode (mode_id) ON DELETE RESTRICT,

    -- a leg from a place to itself is meaningless
    CONSTRAINT ck_travel_leg_distinct CHECK (from_place_id <> to_place_id),

    CONSTRAINT ck_travel_leg_distance CHECK (distance_km > 0),
    CONSTRAINT ck_travel_leg_duration CHECK (typical_duration_min > 0),

    -- monsoon can only make a journey slower, never faster. Encoding
    -- that stops bad data at the door.
    CONSTRAINT ck_travel_leg_monsoon CHECK (
        monsoon_duration_min IS NULL
        OR monsoon_duration_min >= typical_duration_min),

    CONSTRAINT ck_travel_leg_toll CHECK (toll_cost >= 0)
);

COMMENT ON TABLE  travel_leg                        IS 'Mapped ternary: place x place x transport_mode. The road network with measured weights.';
COMMENT ON COLUMN travel_leg.monsoon_duration_min   IS 'Slower monsoon timing; NULL means unmeasured.';


-- =====================================================================
--  13. place_embedding
-- ---------------------------------------------------------------------
--  The vector table. One place, one meaning-vector of 384 numbers.
--
--  Using the foreign key AS the primary key is the neatest way to force
--  1:1 — one row per place, no more, no less.
--
--  Kept as a separate table rather than a column on place so that
--  re-embedding with a different model rebuilds this small table instead
--  of rewriting the main one, and so model_name is recorded per vector.
--  Vectors from different models are not comparable, so that column is
--  not optional bookkeeping — it is correctness.
--
--  The HNSW similarity index goes in 03a_indexes, not here.
-- =====================================================================
CREATE TABLE place_embedding (
    -- key, which is also the foreign key
    place_id        BIGINT          NOT NULL,

    -- data
    -- 384 dimensions matches the all-MiniLM-L6-v2 sentence transformer
    embedding       VECTOR(384)     NOT NULL,
    model_name      VARCHAR(60)     NOT NULL,

    -- timestamps
    generated_at    TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---------------- constraints ----------------
    CONSTRAINT pk_place_embedding PRIMARY KEY (place_id),

    CONSTRAINT fk_place_embedding_place FOREIGN KEY (place_id)
        REFERENCES place (place_id) ON DELETE CASCADE
);

COMMENT ON TABLE  place_embedding             IS '1:1 with place. pgvector embedding for semantic search.';
COMMENT ON COLUMN place_embedding.model_name  IS 'Vectors from different models are not comparable — always record which produced this one.';


-- =====================================================================
--  End of Person A's tables.
--
--  Sanity check:
--      SELECT count(*) FROM information_schema.tables
--      WHERE table_schema = 'public';                    -- expect 13
--
--      SELECT count(*) FROM information_schema.table_constraints
--      WHERE constraint_type = 'FOREIGN KEY'
--        AND table_schema = 'public';                    -- expect 13
-- =====================================================================
