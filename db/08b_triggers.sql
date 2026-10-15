-- =====================================================================
--  Sanchari · 08b_triggers.sql
--  Purpose    : Two triggers that keep stored data consistent on their
--               own, without the application having to remember.
--  Author     : Swara
--  Runs after : 07d_seed_reviews.sql
--
--  A trigger = a function PostgreSQL runs automatically when a row in a
--  table is inserted, updated or deleted. Each trigger below has two
--  parts: the trigger FUNCTION (what to do) and the CREATE TRIGGER
--  statement (which table and which events).
--
--    trg_review_summary_rating  keeps place.avg_rating / review_count
--                               equal to the reviews that exist
--    trg_itinerary_stop_date    refuses a stop whose arrival date is not
--                               its day's calendar_date
-- =====================================================================


-- =====================================================================
--  1. trg_review_summary_rating
-- ---------------------------------------------------------------------
--  place.avg_rating and place.review_count are DERIVED attributes (the
--  dashed ovals on the ER diagram). 07d filled them once; from now on
--  this trigger recalculates them for the affected place after every
--  review that is added, deleted, or has its rating or place changed.
--
--  AFTER, not BEFORE: the review must already be in (or out of) the
--  table when the average is recalculated.
--  FOR EACH ROW: runs once per review touched.
--  If an UPDATE moves a review to a different place, BOTH places are
--  recalculated - the old one loses a review, the new one gains it.
--  A place left with no reviews gets avg_rating NULL and review_count 0.
-- =====================================================================
CREATE FUNCTION tf_review_rating_rollup()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_places BIGINT[];
BEGIN
    v_places := CASE TG_OP
                    WHEN 'INSERT' THEN ARRAY[NEW.place_id]
                    WHEN 'DELETE' THEN ARRAY[OLD.place_id]
                    ELSE               ARRAY[OLD.place_id, NEW.place_id]
                END;

    UPDATE place p
       SET avg_rating   = (SELECT ROUND(AVG(r.rating), 2)
                             FROM review_summary r
                            WHERE r.place_id = p.place_id),
           review_count = (SELECT COUNT(*)
                             FROM review_summary r
                            WHERE r.place_id = p.place_id)
     WHERE p.place_id = ANY (v_places);

    RETURN NULL;     -- the return value of an AFTER trigger is ignored
END;
$$;

CREATE TRIGGER trg_review_summary_rating
AFTER INSERT OR DELETE OR UPDATE OF rating, place_id
ON review_summary
FOR EACH ROW
EXECUTE FUNCTION tf_review_rating_rollup();

COMMENT ON FUNCTION tf_review_rating_rollup() IS
    'Trigger function: recalculates place.avg_rating and review_count for the place(s) a review change touched.';


-- =====================================================================
--  2. trg_itinerary_stop_date
-- ---------------------------------------------------------------------
--  itinerary_stop stores full timestamps, so the DATE is stored twice:
--  once in trip_day.calendar_date and again inside planned_arrival
--  (01b explains why). A CHECK constraint cannot compare the two,
--  because a CHECK can only see its own row - so a trigger does it.
--
--  BEFORE, not AFTER: a wrong row is stopped before it is written.
--  Only the ARRIVAL must be on the day's date; the departure may run
--  past midnight.
-- =====================================================================
CREATE FUNCTION tf_stop_matches_day()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_date DATE;
BEGIN
    SELECT td.calendar_date
      INTO v_date
      FROM trip_day td
     WHERE td.trip_id    = NEW.trip_id
       AND td.day_number = NEW.day_number;

    -- no such day: leave it to the foreign key to reject the row
    IF FOUND AND NEW.planned_arrival::DATE <> v_date THEN
        RAISE EXCEPTION 'stop % of day % arrives on %, but day % of this trip is %',
                        NEW.stop_seq, NEW.day_number, NEW.planned_arrival::DATE,
                        NEW.day_number, v_date;
    END IF;

    RETURN NEW;      -- BEFORE trigger: returning the row lets it through
END;
$$;

CREATE TRIGGER trg_itinerary_stop_date
BEFORE INSERT OR UPDATE OF trip_id, day_number, planned_arrival
ON itinerary_stop
FOR EACH ROW
EXECUTE FUNCTION tf_stop_matches_day();

COMMENT ON FUNCTION tf_stop_matches_day() IS
    'Trigger function: rejects an itinerary_stop whose arrival date differs from its trip_day.calendar_date.';

-- =====================================================================
--  Try it (each block undoes itself with ROLLBACK):
--
--  1. Rating trigger
--      BEGIN;
--      SELECT name, avg_rating, review_count FROM place WHERE place_id = 1;
--      INSERT INTO review_summary (place_id, user_id, rating, visited_on)
--      VALUES (1, 4, 1.0, DATE '2026-10-01');
--      SELECT name, avg_rating, review_count FROM place WHERE place_id = 1;
--      -- review_count is one higher, avg_rating has dropped
--      ROLLBACK;
--
--  2. Stop-date trigger
--      BEGIN;
--      UPDATE itinerary_stop
--         SET planned_arrival   = planned_arrival   + INTERVAL '1 day',
--             planned_departure = planned_departure + INTERVAL '1 day'
--       WHERE trip_id = 1 AND day_number = 1 AND stop_seq = 1;
--      -- ERROR: stop 1 of day 1 arrives on ..., but day 1 of this trip is ...
--      ROLLBACK;
-- =====================================================================
