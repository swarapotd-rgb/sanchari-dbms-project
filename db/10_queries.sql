-- =====================================================================
--  Sanchari · 10_queries.sql
--  Purpose    : Meaningful queries over the seeded database - JOIN,
--               GROUP BY, HAVING, subqueries, UPDATE and DELETE.
--  Author     : Shreya
--  Runs after : run_all.sql (needs the seed data). Not part of run_all.
--
--  Every UPDATE and DELETE is wrapped in BEGIN ... ROLLBACK, so running
--  this file never changes the data.
--
--  Run:  docker exec sanchari-db psql -U postgres -d sanchari -f /db/10_queries.sql
-- =====================================================================


-- =====================================================================
--  PART 1 - JOINS
-- =====================================================================

-- ---------------------------------------------------------------------
--  Q1. The full plan of trip 1, in order.
--  Shows: 4-table JOIN (composite key join on trip_id + day_number)
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q1. Full plan of trip 1 ==='

SELECT   td.day_number,
         td.calendar_date,
         s.stop_seq,
         p.name                    AS place,
         d.name                    AS destination,
         s.planned_arrival::TIME   AS arrive,
         s.planned_departure::TIME AS leave
FROM     itinerary_stop s
JOIN     trip_day       td ON td.trip_id    = s.trip_id
                          AND td.day_number = s.day_number
JOIN     place          p  ON p.place_id    = s.place_id
JOIN     destination    d  ON d.destination_id = p.destination_id
WHERE    s.trip_id = 1
ORDER BY td.day_number, s.stop_seq;


-- ---------------------------------------------------------------------
--  Q2. Travellers who have no profile.
--  Shows: LEFT JOIN ... WHERE ... IS NULL
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q2. Travellers without a profile ==='

SELECT    u.user_id,
          u.display_name,
          u.email
FROM      user_account      u
JOIN      role              r  ON r.role_id  = u.role_id
LEFT JOIN traveller_profile tp ON tp.user_id = u.user_id
WHERE     r.role_name = 'Traveller'
  AND     tp.user_id IS NULL
ORDER BY  u.user_id;


-- ---------------------------------------------------------------------
--  Q3. How many places does each state have?
--  Shows: JOIN, GROUP BY, COUNT
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q3. Places per state ==='

SELECT   d.state,
         COUNT(*) AS places
FROM     place       p
JOIN     destination d ON d.destination_id = p.destination_id
GROUP BY d.state
ORDER BY places DESC;


-- ---------------------------------------------------------------------
--  Q4. What is each traveller interested in, strongest first?
--  Shows: 4-table JOIN, GROUP BY, string_agg with its own ORDER BY
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q4. Each traveller''s interests (strongest first) ==='

SELECT   u.display_name,
         tp.default_pace,
         string_agg(ic.name, ', ' ORDER BY ti.weight DESC, ic.name) AS interests
FROM     user_account       u
JOIN     traveller_profile  tp ON tp.user_id     = u.user_id
JOIN     traveller_interest ti ON ti.profile_id  = tp.profile_id
JOIN     interest_category  ic ON ic.category_id = ti.category_id
GROUP BY u.user_id, u.display_name, tp.default_pace
ORDER BY u.display_name
LIMIT    10;


-- ---------------------------------------------------------------------
--  Q5. The 5 quickest walks between two places in Hampi.
--  Shows: joining the same table twice (place as "from" and as "to")
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q5. The 5 quickest walks in Hampi ==='

SELECT   pf.name                 AS from_place,
         pt.name                 AS to_place,
         tl.distance_km,
         tl.typical_duration_min AS walk_min
FROM     travel_leg     tl
JOIN     place          pf ON pf.place_id = tl.from_place_id
JOIN     place          pt ON pt.place_id = tl.to_place_id
JOIN     transport_mode tm ON tm.mode_id  = tl.mode_id
JOIN     destination    d  ON d.destination_id = pf.destination_id
WHERE    tm.mode_name = 'walk'
  AND    d.name       = 'Hampi'
  AND    pf.place_id  < pt.place_id          -- each pair is stored both ways
ORDER BY tl.typical_duration_min, from_place, to_place
LIMIT    5;


-- =====================================================================
--  PART 2 - GROUP BY AND HAVING
-- =====================================================================

-- ---------------------------------------------------------------------
--  Q6. Which destinations are best covered (at least 9 places)?
--  Shows: GROUP BY + HAVING COUNT
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q6. Destinations with at least 9 places ==='

SELECT   d.name  AS destination,
         d.state,
         COUNT(p.place_id) AS places
FROM     destination d
JOIN     place       p ON p.destination_id = d.destination_id
GROUP BY d.destination_id, d.name, d.state
HAVING   COUNT(p.place_id) >= 9
ORDER BY places DESC, destination;


-- ---------------------------------------------------------------------
--  Q7. The best-rated places that have at least 2 reviews.
--  Shows: GROUP BY, AVG, COUNT, HAVING, ORDER BY ... LIMIT
--  The calculated average is shown next to place.avg_rating -
--  they match, because the rating trigger keeps them in step.
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q7. Top 10 places with 2+ reviews ==='

SELECT   p.name,
         COUNT(*)                AS reviews,
         ROUND(AVG(r.rating), 2) AS calculated_avg,
         p.avg_rating            AS stored_avg
FROM     review_summary r
JOIN     place          p ON p.place_id = r.place_id
GROUP BY p.place_id, p.name, p.avg_rating
HAVING   COUNT(*) >= 2
ORDER BY calculated_avg DESC, reviews DESC, p.name
LIMIT    10;


-- ---------------------------------------------------------------------
--  Q8. Which interest categories have the best-rated places?
--  Shows: 3-table JOIN, GROUP BY, AVG, HAVING
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q8. Categories whose places average 4.0 or more ==='

SELECT   ic.name                     AS category,
         COUNT(*)                    AS rated_places,
         ROUND(AVG(p.avg_rating), 2) AS avg_rating
FROM     interest_category ic
JOIN     place_category    pc ON pc.category_id = ic.category_id
JOIN     place             p  ON p.place_id     = pc.place_id
WHERE    p.avg_rating IS NOT NULL
GROUP BY ic.category_id, ic.name
HAVING   AVG(p.avg_rating) >= 4.0
ORDER BY avg_rating DESC, category;


-- ---------------------------------------------------------------------
--  Q9. Which feasibility rule fails most often?
--  Shows: JOIN + GROUP BY on the engine's output, COUNT / MIN / MAX
--  The trip comes from feasibility_run, not violation.trip_id: R07
--  (whole day) and R08 (whole trip) leave the stop columns, including
--  violation.trip_id, empty.
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q9. Violations per rule ==='

SELECT   v.rule_code,
         v.severity,
         COUNT(*)        AS violations,
         MIN(fr.trip_id) AS first_trip,
         MAX(fr.trip_id) AS last_trip
FROM     violation       v
JOIN     feasibility_run fr ON fr.run_id = v.run_id
GROUP BY v.rule_code, v.severity
ORDER BY violations DESC, v.rule_code;


-- =====================================================================
--  PART 3 - SUBQUERIES
-- =====================================================================

-- ---------------------------------------------------------------------
--  Q10. Which places cost more than the average entry fee?
--  Shows: scalar subquery in WHERE (and in SELECT)
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q10. Places dearer than the average entry fee ==='

SELECT   p.name,
         p.place_type,
         p.fee_indian,
         (SELECT ROUND(AVG(fee_indian), 2) FROM place) AS average_fee
FROM     place p
WHERE    p.fee_indian > (SELECT AVG(fee_indian) FROM place)
ORDER BY p.fee_indian DESC, p.name
LIMIT    10;


-- ---------------------------------------------------------------------
--  Q11a. How many places has nobody planned to visit yet?
--  Shows: NOT IN and NOT EXISTS - both must give the same count
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q11a. Places in no trip - NOT IN vs NOT EXISTS ==='

SELECT
    (SELECT COUNT(*)
     FROM   place p
     WHERE  p.place_id NOT IN (SELECT s.place_id FROM itinerary_stop s)) AS using_not_in,
    (SELECT COUNT(*)
     FROM   place p
     WHERE  NOT EXISTS (SELECT 1
                        FROM   itinerary_stop s
                        WHERE  s.place_id = p.place_id))                 AS using_not_exists;


-- ---------------------------------------------------------------------
--  Q11b. Ten of those unplanned places.
--  Shows: NOT EXISTS with a correlated subquery
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q11b. Ten places nobody has planned yet ==='

SELECT   p.name,
         d.name AS destination,
         p.place_type
FROM     place       p
JOIN     destination d ON d.destination_id = p.destination_id
WHERE    NOT EXISTS (SELECT 1
                     FROM   itinerary_stop s
                     WHERE  s.place_id = p.place_id)
ORDER BY d.name, p.name
LIMIT    10;


-- ---------------------------------------------------------------------
--  Q12. Which reviews were written about a place the reviewer
--       actually planned on one of their own trips?
--  Shows: EXISTS with a correlated subquery (inner query uses r and u)
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q12. Reviews of places the reviewer planned on their own trip ==='

SELECT   u.display_name,
         p.name   AS place,
         r.rating,
         r.visited_on
FROM     review_summary r
JOIN     user_account   u ON u.user_id  = r.user_id
JOIN     place          p ON p.place_id = r.place_id
WHERE    EXISTS (SELECT 1
                 FROM   itinerary_stop s
                 JOIN   trip           t ON t.trip_id = s.trip_id
                 WHERE  t.owner_user_id = r.user_id
                   AND  s.place_id      = r.place_id)
ORDER BY u.display_name, r.visited_on, p.name
LIMIT    10;


-- ---------------------------------------------------------------------
--  Q13. What does a trip cost on average, by status?
--  Shows: subquery in FROM (a derived table)
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q13. Average trip cost by status ==='

SELECT   tc.status,
         COUNT(*)                     AS trips,
         ROUND(AVG(tc.total_cost), 2) AS avg_total_cost,
         MAX(tc.total_cost)           AS dearest_trip
FROM     (SELECT   t.trip_id,
                   t.status,
                   COALESCE(SUM(s.estimated_cost), 0) AS total_cost
          FROM     trip           t
          LEFT JOIN itinerary_stop s ON s.trip_id = t.trip_id
          GROUP BY t.trip_id, t.status) AS tc
GROUP BY tc.status
ORDER BY avg_total_cost DESC;


-- =====================================================================
--  PART 4 - SPECIAL FEATURES
-- =====================================================================

-- ---------------------------------------------------------------------
--  Q14. Is Madikeri Museum open on Monday 14 December 2026?
--  Shows: calling our own function inside a query
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q14. Is Madikeri Museum open on Mon 14 Dec 2026? ==='

SELECT *
FROM   f_place_open_on(
           (SELECT place_id FROM place WHERE name = 'Madikeri Museum'),
           DATE '2026-12-14');


-- ---------------------------------------------------------------------
--  Q15. The 5 places most similar in meaning to Abbey Falls.
--  Shows: pgvector semantic search (<=> is cosine distance)
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q15. The 5 places most like Abbey Falls ==='

SELECT   p.name,
         p.place_type,
         ROUND((e.embedding <=> a.embedding)::NUMERIC, 4) AS distance
FROM     place_embedding e
JOIN     place           p ON p.place_id = e.place_id
CROSS JOIN (SELECT pe.embedding
            FROM   place_embedding pe
            JOIN   place           pa ON pa.place_id = pe.place_id
            WHERE  pa.name = 'Abbey Falls') AS a
WHERE    p.name <> 'Abbey Falls'
ORDER BY distance
LIMIT    5;


-- =====================================================================
--  PART 5 - UPDATE AND DELETE (every one undone by ROLLBACK)
-- =====================================================================

-- ---------------------------------------------------------------------
--  Q16. UPDATE: raise every museum's entry fee in Tamil Nadu by 10%.
--  Shows: UPDATE with a subquery in WHERE
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q16. UPDATE - Tamil Nadu museum fees +10% (rolled back) ==='

BEGIN;

\echo '--- before ---'
SELECT   p.name, p.fee_indian, p.fee_foreign
FROM     place p
WHERE    p.place_type = 'museum'
  AND    p.destination_id IN (SELECT destination_id
                              FROM   destination
                              WHERE  state = 'Tamil Nadu')
ORDER BY p.name;

UPDATE place
SET    fee_indian  = ROUND(fee_indian  * 1.10, 2),
       fee_foreign = ROUND(fee_foreign * 1.10, 2)
WHERE  place_type = 'museum'
  AND  destination_id IN (SELECT destination_id
                          FROM   destination
                          WHERE  state = 'Tamil Nadu');

\echo '--- after ---'
SELECT   p.name, p.fee_indian, p.fee_foreign
FROM     place p
WHERE    p.place_type = 'museum'
  AND    p.destination_id IN (SELECT destination_id
                              FROM   destination
                              WHERE  state = 'Tamil Nadu')
ORDER BY p.name;

ROLLBACK;


-- ---------------------------------------------------------------------
--  Q17. UPDATE: the rating trigger in action.
--  Change one Palolem Beach review to 1 star; the place's average
--  is recalculated by trg_review_summary_rating, not by us.
--  Shows: UPDATE firing an AFTER trigger
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q17. UPDATE - one Palolem Beach review set to 1 star (rolled back) ==='

BEGIN;

\echo '--- before ---'
SELECT p.name, p.avg_rating, p.review_count
FROM   place p
WHERE  p.name = 'Palolem Beach';

UPDATE review_summary
SET    rating = 1.0
WHERE  review_id = (SELECT MIN(r.review_id)
                    FROM   review_summary r
                    JOIN   place          p ON p.place_id = r.place_id
                    WHERE  p.name = 'Palolem Beach');

\echo '--- after (the trigger recalculated avg_rating) ---'
SELECT p.name, p.avg_rating, p.review_count
FROM   place p
WHERE  p.name = 'Palolem Beach';

ROLLBACK;


-- ---------------------------------------------------------------------
--  Q18. DELETE with CASCADE: delete test trip 34.
--  Its days, stops, runs and violations go with it, because those
--  foreign keys are ON DELETE CASCADE.
--  Shows: DELETE and cascading foreign keys
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q18. DELETE - trip 34 and everything under it (rolled back) ==='

BEGIN;

-- remember trip 34's run_id, so its violations can still be counted
-- after the run itself has been deleted (\gset stores it as :run34)
SELECT MAX(run_id) AS run34
FROM   feasibility_run
WHERE  trip_id = 34 \gset

\echo '--- before ---'
SELECT (SELECT COUNT(*) FROM trip            WHERE trip_id = 34)     AS trips,
       (SELECT COUNT(*) FROM trip_day        WHERE trip_id = 34)     AS days,
       (SELECT COUNT(*) FROM itinerary_stop  WHERE trip_id = 34)     AS stops,
       (SELECT COUNT(*) FROM feasibility_run WHERE trip_id = 34)     AS runs,
       (SELECT COUNT(*) FROM violation       WHERE run_id  = :run34) AS violations;

DELETE FROM trip
WHERE  trip_id = 34;

\echo '--- after ---'
SELECT (SELECT COUNT(*) FROM trip            WHERE trip_id = 34)     AS trips,
       (SELECT COUNT(*) FROM trip_day        WHERE trip_id = 34)     AS days,
       (SELECT COUNT(*) FROM itinerary_stop  WHERE trip_id = 34)     AS stops,
       (SELECT COUNT(*) FROM feasibility_run WHERE trip_id = 34)     AS runs,
       (SELECT COUNT(*) FROM violation       WHERE run_id  = :run34) AS violations;

ROLLBACK;


-- ---------------------------------------------------------------------
--  Q19. DELETE that is refused: try to delete Mysore Palace.
--  Trips plan to visit it and fk_itinerary_stop_place is
--  ON DELETE RESTRICT, so PostgreSQL refuses.
--
--  >>> THE ERROR BELOW IS EXPECTED - it proves the RESTRICT works. <<<
--
--  Kept last: after an error PostgreSQL ignores everything until
--  ROLLBACK, so nothing else can come after it in the transaction.
--  Shows: DELETE blocked by a RESTRICT foreign key
-- ---------------------------------------------------------------------
\echo ''
\echo '=== Q19. DELETE - Mysore Palace (an ERROR is expected) ==='

BEGIN;

DELETE FROM place
WHERE  name = 'Mysore Palace';

ROLLBACK;

\echo ''
\echo '=== End of 10_queries.sql ==='
