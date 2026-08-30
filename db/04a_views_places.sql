-- =====================================================================
--  Sanchari · 04a_views_places.sql
--  Purpose    : The availability layer. This is where opening_rule and
--               closure_window finally meet — feasibility rules R01, R02
--               and R03 all sit on top of what this file defines.
--  Author     : Swara
--  Runs after : 01a_tables_people_places.sql
--
--  Contains two VIEWS and one FUNCTION. The split is not arbitrary:
--  a PostgreSQL view cannot take parameters, and "is this place open on
--  this date?" needs a date. So the browsable, parameterless parts are
--  views, and the part that answers a question about a specific date is
--  a function.
-- =====================================================================


-- =====================================================================
--  VIEW 1 · v_place_weekly_hours
-- ---------------------------------------------------------------------
--  Human-readable opening hours: one row per place per open weekday,
--  with the weekday spelled out. This is what a place detail page shows.
--
--  Places with no opening_rule rows at all simply do not appear, which
--  is correct — we know nothing about their hours.
-- =====================================================================
CREATE VIEW v_place_weekly_hours AS
SELECT
    p.place_id,
    p.name                                  AS place_name,
    d.name                                  AS destination_name,
    orl.day_of_week,
    -- 0 = Sunday, matching PostgreSQL's own EXTRACT(DOW FROM date)
    CASE orl.day_of_week
        WHEN 0 THEN 'Sunday'    WHEN 1 THEN 'Monday'
        WHEN 2 THEN 'Tuesday'   WHEN 3 THEN 'Wednesday'
        WHEN 4 THEN 'Thursday'  WHEN 5 THEN 'Friday'
        WHEN 6 THEN 'Saturday'
    END                                     AS day_name,
    orl.opens_at,
    orl.closes_at,
    -- fall back to closing time when there is no separate ticket cut-off
    COALESCE(orl.last_entry_at, orl.closes_at) AS effective_last_entry,
    -- how long the gate is actually open, in minutes
    (EXTRACT(EPOCH FROM (orl.closes_at - orl.opens_at)) / 60)::INT
                                            AS open_minutes
FROM        place        p
JOIN        destination  d   ON d.destination_id = p.destination_id
JOIN        opening_rule orl ON orl.place_id     = p.place_id;

COMMENT ON VIEW v_place_weekly_hours IS
    'Readable weekly opening pattern per place. Feeds the place detail page.';


-- =====================================================================
--  VIEW 2 · v_place_directory
-- ---------------------------------------------------------------------
--  One row per place with its region and all its categories collapsed
--  into a single text column. Without this, listing 50 places with their
--  tags means 50 extra queries — the classic N+1 problem.
--
--  Demonstrates JOIN + LEFT JOIN + GROUP BY + an aggregate function,
--  which is what requirement 6 asks to see.
--
--  LEFT JOIN on place_category matters: a newly added place with no tags
--  yet must still appear in the directory, with an empty category list.
--  An inner join would silently hide it.
-- =====================================================================
CREATE VIEW v_place_directory AS
SELECT
    p.place_id,
    p.name                                          AS place_name,
    p.place_type,
    d.name                                          AS destination_name,
    d.district,
    d.state,
    p.latitude,
    p.longitude,
    p.typical_visit_minutes,
    p.fee_indian,
    p.requires_daylight,
    p.avg_rating,
    p.review_count,
    -- categories as one comma-separated string, strongest fit first
    STRING_AGG(ic.name, ', ' ORDER BY pc.relevance DESC, ic.name)
                                                    AS categories,
    COUNT(ic.category_id)                           AS category_count,
    -- does this place have any opening hours recorded at all? If not,
    -- the feasibility engine cannot validate a visit to it.
    EXISTS (SELECT 1 FROM opening_rule orl
            WHERE orl.place_id = p.place_id)        AS has_opening_hours
FROM        place              p
JOIN        destination        d   ON d.destination_id = p.destination_id
LEFT JOIN   place_category     pc  ON pc.place_id      = p.place_id
LEFT JOIN   interest_category  ic  ON ic.category_id   = pc.category_id
GROUP BY    p.place_id, p.name, p.place_type, d.name, d.district, d.state,
            p.latitude, p.longitude, p.typical_visit_minutes, p.fee_indian,
            p.requires_daylight, p.avg_rating, p.review_count;

COMMENT ON VIEW v_place_directory IS
    'One row per place with region and categories flattened. Avoids N+1 queries on listing pages.';


-- =====================================================================
--  FUNCTION · f_place_open_on(place_id, date)
-- ---------------------------------------------------------------------
--  THE CORE OF THE PROJECT.
--
--  Given a place and a calendar date, answer: is it open, and if so
--  between what times, and until when can you still get in.
--
--  The order of checks matters and encodes a real-world rule:
--
--      1. A CLOSURE BEATS AN OPENING RULE.
--         A fort open every Wednesday is still shut on a Wednesday that
--         falls inside its monsoon closure. So closures are checked
--         first, and short-circuit.
--
--      2. AN ANNUAL CLOSURE IGNORES THE YEAR.
--         "Closed 1 June to 30 September, every year" is stored once,
--         not once per year. So for recurring windows we compare only
--         month-and-day. Comparing 'MM-DD' as text works because that
--         format sorts in calendar order.
--
--      3. A WINDOW CAN WRAP THE YEAR END.
--         "Closed 15 December to 15 January" has a start later than its
--         end in MM-DD terms. That case needs OR rather than BETWEEN,
--         which is the `IF s_md <= e_md` branch below.
--
--      4. NO RULE FOR THAT WEEKDAY MEANS CLOSED.
--         We store rows only for days a place opens, so a missing row
--         IS the closure. That keeps rule R01 a simple existence test.
--
--  This function is what rules R01 (open that weekday), R02 (arrives
--  after last entry) and R03 (inside a closure) all call.
-- =====================================================================
CREATE FUNCTION f_place_open_on(p_place_id BIGINT, p_date DATE)
RETURNS TABLE (
    is_open        BOOLEAN,
    opens_at       TIME,
    closes_at      TIME,
    last_entry_at  TIME,
    status_reason  TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_closure_reason  VARCHAR(25);
    v_dow             SMALLINT;
    v_rule            RECORD;
    v_md              TEXT;   -- the target date as 'MM-DD'
BEGIN
    -- ---------------------------------------------------------------
    -- Step 1: is the date inside any closure window?
    -- ---------------------------------------------------------------
    v_md := to_char(p_date, 'MM-DD');

    SELECT cw.reason_code
      INTO v_closure_reason
      FROM closure_window cw
     WHERE cw.place_id = p_place_id
       AND (
             -- one-off closure: plain date containment
             (cw.is_annual_recurring = FALSE
              AND p_date BETWEEN cw.start_date AND cw.end_date)
             OR
             -- recurring closure: compare month-and-day only
             (cw.is_annual_recurring = TRUE
              AND (
                    CASE
                      WHEN to_char(cw.start_date,'MM-DD')
                           <= to_char(cw.end_date,'MM-DD')
                      THEN v_md BETWEEN to_char(cw.start_date,'MM-DD')
                                    AND to_char(cw.end_date,'MM-DD')
                      -- window wraps the year end (e.g. 15 Dec - 15 Jan)
                      ELSE v_md >= to_char(cw.start_date,'MM-DD')
                        OR v_md <= to_char(cw.end_date,'MM-DD')
                    END
                  ))
           )
     LIMIT 1;

    IF FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::TIME, NULL::TIME, NULL::TIME,
                            'closed: ' || v_closure_reason;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------
    -- Step 2: is there an opening rule for that weekday?
    -- EXTRACT(DOW) gives 0 = Sunday .. 6 = Saturday, which is exactly
    -- the convention opening_rule.day_of_week uses.
    -- ---------------------------------------------------------------
    v_dow := EXTRACT(DOW FROM p_date)::SMALLINT;

    SELECT orl.opens_at, orl.closes_at, orl.last_entry_at
      INTO v_rule
      FROM opening_rule orl
     WHERE orl.place_id    = p_place_id
       AND orl.day_of_week = v_dow;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::TIME, NULL::TIME, NULL::TIME,
                            -- to_char pads day names to 9 characters,
                            -- so trim or every message gets trailing spaces
                            'closed on ' || trim(to_char(p_date, 'Day'));
        RETURN;
    END IF;

    -- ---------------------------------------------------------------
    -- Step 3: open. Report the times, defaulting last entry to closing.
    -- ---------------------------------------------------------------
    RETURN QUERY SELECT TRUE,
                        v_rule.opens_at,
                        v_rule.closes_at,
                        COALESCE(v_rule.last_entry_at, v_rule.closes_at),
                        'open'::TEXT;
END;
$$;

COMMENT ON FUNCTION f_place_open_on(BIGINT, DATE) IS
    'Resolves opening_rule against closure_window for one date. Basis of rules R01, R02, R03.';


-- =====================================================================
--  How the feasibility rules use this
--
--  R01 — closed that weekday:
--      SELECT is_open, status_reason FROM f_place_open_on(42, '2026-12-14');
--
--  R02 — arrives after last entry:
--      SELECT (TIME '17:45' > f.last_entry_at) AS too_late
--      FROM   f_place_open_on(42, '2026-12-14') f
--      WHERE  f.is_open;
--
--  R03 — inside a closure: status_reason starts with 'closed: '
-- =====================================================================
