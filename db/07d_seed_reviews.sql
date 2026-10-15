-- =====================================================================
--  Sanchari · 07d_seed_reviews.sql
--  Purpose    : Generate review_summary rows with INSERT ... SELECT (no
--               CSV), then fill in place.avg_rating and review_count.
--  Author     : Swara
--  Runs after : 07b_seed_trips.sql
--
--  Two kinds of review:
--    1. Every stop of a COMPLETED trip is reviewed by the trip's owner,
--       dated the day of the visit.
--    2. Each traveller with a profile also reviews four places they never
--       planned through the app, chosen from categories they like - the
--       way real users review places they visited on their own.
--
--  Ratings, durations and crowd levels are computed from the ids with
--  simple arithmetic (modulo), not random(), so every rebuild produces
--  exactly the same reviews. The review text itself will live in MongoDB;
--  mongo_doc_id stays NULL until that step.
-- =====================================================================


-- #####################################################################
--  1. Reviews of stops on completed trips
-- #####################################################################
INSERT INTO review_summary (place_id, user_id, rating, visited_on,
                            actual_duration_min, crowd_level, created_at)
SELECT s.place_id,
       t.owner_user_id,
       -- spread of ratings: 10% 2-star, 20% 3, 40% 4, 30% 5
       CASE (s.place_id * 7 + t.owner_user_id * 13) % 10
            WHEN 0 THEN 2.0
            WHEN 1 THEN 3.0 WHEN 2 THEN 3.0
            WHEN 3 THEN 4.0 WHEN 4 THEN 4.0 WHEN 5 THEN 4.0 WHEN 6 THEN 4.0
            ELSE 5.0
       END,
       s.planned_arrival::DATE,
       -- the planned time, give or take up to 10 minutes
       GREATEST(10, (EXTRACT(EPOCH FROM (s.planned_departure - s.planned_arrival)) / 60)::INT
                    + ((s.place_id + t.owner_user_id) % 5 - 2) * 5),
       1 + (s.place_id * t.owner_user_id) % 5,
       -- written the evening after the visit
       (s.planned_arrival::DATE + 1 + TIME '20:00')::TIMESTAMPTZ
FROM   itinerary_stop s
JOIN   trip           t ON t.trip_id = s.trip_id
WHERE  t.status = 'completed';


-- #####################################################################
--  2. Reviews of places visited outside the app
-- #####################################################################
--  For each traveller: places strongly tagged (relevance >= 0.8) with one
--  of their interests and not already reviewed by them, numbered in a
--  fixed shuffled order - the first four are kept. The visit date falls
--  between the day they joined and 10 October 2026. Shows a CTE,
--  DISTINCT and the ROW_NUMBER() window function in one statement.
WITH candidate AS (            -- every liked place each traveller has not reviewed
    SELECT DISTINCT
           u.user_id,
           u.date_joined::DATE AS joined,
           p.place_id,
           p.typical_visit_minutes
    FROM   user_account       u
    JOIN   traveller_profile  tp ON tp.user_id     = u.user_id
    JOIN   traveller_interest ti ON ti.profile_id  = tp.profile_id
    JOIN   place_category     pc ON pc.category_id = ti.category_id
                                AND pc.relevance  >= 0.8
    JOIN   place              p  ON p.place_id     = pc.place_id
    WHERE  NOT EXISTS (SELECT 1 FROM review_summary r
                       WHERE  r.user_id = u.user_id AND r.place_id = p.place_id)
),
ranked AS (                    -- number them in a fixed, shuffled order
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY c.user_id
                              ORDER BY (c.place_id * 31 + c.user_id * 17) % 101, c.place_id) AS rn
    FROM   candidate c
)
INSERT INTO review_summary (place_id, user_id, rating, visited_on,
                            actual_duration_min, crowd_level, created_at)
SELECT k.place_id,
       k.user_id,
       CASE (k.place_id * 7 + k.user_id * 13) % 10
            WHEN 0 THEN 2.0
            WHEN 1 THEN 3.0 WHEN 2 THEN 3.0
            WHEN 3 THEN 4.0 WHEN 4 THEN 4.0 WHEN 5 THEN 4.0 WHEN 6 THEN 4.0
            ELSE 5.0
       END,
       k.visit_date,
       GREATEST(10, k.typical_visit_minutes + ((k.place_id + k.user_id) % 5 - 2) * 5),
       1 + (k.place_id * k.user_id) % 5,
       (k.visit_date + 2 + TIME '19:00')::TIMESTAMPTZ
FROM  (SELECT r.*,
              -- a day between joining and 10 October 2026
              r.joined + ((r.place_id * 37 + r.user_id * 11)
                          % GREATEST(1, DATE '2026-10-10' - r.joined))::INT AS visit_date
       FROM   ranked r
       WHERE  r.rn <= 4) k;


-- #####################################################################
--  3. Derived columns on place
-- #####################################################################
--  avg_rating and review_count are derived attributes (dashed ovals on
--  the ER diagram). This UPDATE ... FROM (subquery) fills them in once;
--  the trigger added in the next step will keep them current afterwards.
UPDATE place p
SET    avg_rating   = r.avg_rating,
       review_count = r.review_count
FROM  (SELECT place_id,
              ROUND(AVG(rating), 2) AS avg_rating,
              COUNT(*)              AS review_count
       FROM   review_summary
       GROUP  BY place_id) r
WHERE  p.place_id = r.place_id;

-- =====================================================================
--  Sanity check:
--      SELECT count(*), round(avg(rating), 2) FROM review_summary;
--      SELECT name, avg_rating, review_count FROM place
--      WHERE review_count > 0 ORDER BY review_count DESC, avg_rating DESC LIMIT 10;
-- =====================================================================
