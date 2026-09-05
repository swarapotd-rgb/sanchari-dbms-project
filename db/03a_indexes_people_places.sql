-- =====================================================================
--  Sanchari · 03a_indexes_people_places.sql
--  Purpose    : Indexes for Person A's tables. Every index below exists
--               because a specific query or feasibility rule needs it —
--               none is speculative.
--  Author     : Swara
--  Runs after : 01a_tables_people_places.sql
--
--  Reminder: PostgreSQL indexes primary keys and UNIQUE constraints
--  automatically, but NOT foreign key columns. Un-indexed foreign keys
--  are the classic cause of slow deletes on the parent table, because
--  the database must scan the whole child table to check for orphans.
-- =====================================================================


-- ---------------------------------------------------------------------
--  NOT created, deliberately: opening_rule (place_id, day_of_week)
--
--  Rule R01 looks a place up by (place_id, day_of_week), so this looks
--  like the most important index in the project. It already exists —
--  the UNIQUE constraint uq_opening_rule_place_day creates one on
--  exactly those columns. Adding a second index on the same columns
--  would cost write time and disk for zero read benefit.
--  Same reasoning for uq_place_name_destination and
--  uq_destination_name_state.
-- ---------------------------------------------------------------------


-- ============ foreign-key indexes ====================================

-- Supports "list every user with the Curator role", and keeps deletes
-- on `role` from scanning all of user_account.
CREATE INDEX idx_user_account_role
    ON user_account (role_id);

-- The primary key on traveller_interest is (profile_id, category_id),
-- which serves lookups that start with profile_id. Searching the other
-- way — "which travellers like Waterfalls?" — cannot use it, because
-- category_id is the second column of the key.
CREATE INDEX idx_traveller_interest_category
    ON traveller_interest (category_id);

-- "All places in Coorg" — the most common listing query in the app.
CREATE INDEX idx_place_destination
    ON place (destination_id);

-- Same second-column problem as traveller_interest: the PK is
-- (place_id, category_id), so "all places tagged Waterfalls" needs this.
CREATE INDEX idx_place_category_category
    ON place_category (category_id);


-- ============ query-driven indexes ===================================

-- Filtering the discovery feed by kind of place: "show me only trails".
CREATE INDEX idx_place_type
    ON place (place_type);

-- Rule R04 looks legs up by origin, which the primary key
-- (from_place_id, to_place_id, mode_id) already serves. But the repair
-- engine also asks the reverse question — "what reaches this place, and
-- by what mode?" — which the PK cannot answer efficiently.
CREATE INDEX idx_travel_leg_reverse
    ON travel_leg (to_place_id, mode_id);


-- ============ the interesting one: a range index ======================
--
--  Rule R03 asks "is this date inside any closure window for this
--  place?". A plain B-tree on (place_id, start_date, end_date) helps
--  only a little, because the question is containment, not equality.
--
--  A GiST index over a daterange answers containment directly. Mixing
--  the scalar place_id with the range in ONE index is exactly what the
--  btree_gist extension enables — this is why 00_extensions.sql turns
--  it on.
--
--  '[]' makes the range inclusive at both ends, matching how a closure
--  actually works: a window of 1 June to 30 September includes both
--  those days.
-- ---------------------------------------------------------------------
CREATE INDEX idx_closure_window_range
    ON closure_window
    USING gist (place_id, daterange(start_date, end_date, '[]'));


-- ============ vector similarity index =================================
--
--  HNSW (Hierarchical Navigable Small World) is an approximate nearest
--  neighbour index. Without it, a semantic search compares the query
--  vector against every row — fine for 50 places, useless at scale.
--
--  vector_cosine_ops must match the operator the queries use. Our
--  searches use <=> (cosine distance), so the index is built for cosine.
--  An index built for L2 distance would simply be ignored by a cosine
--  query, silently, which is a nasty bug to chase.
-- ---------------------------------------------------------------------
CREATE INDEX idx_place_embedding_hnsw
    ON place_embedding
    USING hnsw (embedding vector_cosine_ops);


-- =====================================================================
--  Sanity check:
--      SELECT indexname FROM pg_indexes
--      WHERE schemaname = 'public' AND indexname LIKE 'idx_%'
--      ORDER BY indexname;                        -- expect 8 rows
-- =====================================================================
