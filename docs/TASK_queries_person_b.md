# Sanchari — brief for Shreya: the queries file

Hi Shreya! This document has two parts:

- **Part A — where the project is now.** Everything that has been built since you last
  worked on it, explained simply, so you know what is in the database before you query it.
- **Part B — your task.** Write `db/10_queries.sql`: about 15 SQL queries that show JOIN,
  GROUP BY, HAVING, subqueries, UPDATE and DELETE on our real data. It has a suggested
  list of queries, a template, the rules to follow, and how to test and submit.

---

# Part A — where the project is now

Everything below is on `main` on GitHub and rebuilds from an empty database with no errors.

## A1. Getting the latest version running

```powershell
git pull
docker cp db/. sanchari-db:/db
docker exec sanchari-db psql -U postgres -d sanchari -f /db/reset.sql
docker exec sanchari-db psql -U postgres -d sanchari -f /db/run_all.sql
docker exec sanchari-db psql -U postgres -d sanchari -f /db/verify.sql
```

- `reset.sql` empties the database, `run_all.sql` builds everything, `verify.sql` proves it.
- Always run `docker cp` again after `git pull` — the copy inside the container does not
  update by itself.
- During `run_all.sql` you will see 32 lines like
  `NOTICE: trip 27 "Madikeri on a Monday": 1 blocking, 0 warning, score 75.00`.
  That is normal — it is the feasibility check reporting on each trip.

`verify.sql` should show:

- Section 1: **19 tables · 24 foreign keys · 22 indexes · 4 views · 2 functions ·
  1 procedure · 2 triggers**
- Sections 2–5: **0 rows** each
- Section 8: the row counts in the table in A3 below
- Section 9: exactly **8 rows** — the 8 test trips, one rule each

To open a SQL prompt and try queries by hand:

```powershell
docker exec -it sanchari-db psql -U postgres -d sanchari
```

(Type `\q` to leave.)

## A2. What changed in the schema

Your 6 tables are the same as you left them, with three small additions:

- **`garden`** is now an allowed `place_type` (there are 12: fort, beach, temple, trail,
  wildlife, waterfall, museum, market, viewpoint, lake, heritage, garden).
- **`pgcrypto`** is switched on in `00_extensions.sql`. It is PostgreSQL's built-in
  password-hashing tool.
- `v_day_schedule` now shows the place's name, and `v_trip_health` picks the latest run
  correctly even when two runs have the same timestamp.

The ER diagram and relational schema in `docs/diagrams/` are updated to match.

## A3. The data — every table now has rows

| Table | Rows | What is in it |
|---|---:|---|
| `role` | 3 | Traveller, Curator, Admin |
| `user_account` | 30 | 1 Admin, 2 Curators, 27 Travellers — all invented |
| `traveller_profile` | 25 | travel preferences; 2 travellers deliberately have none |
| `interest_category` | 20 | waterfalls, temples-spiritual, beaches-coast … |
| `traveller_interest` | 72 | about 3 interests per traveller, each with a weight 1–5 |
| `destination` | 49 | towns/areas across 7 states |
| `place` | 358 | real places from OpenStreetMap |
| `place_category` | 742 | which categories each place belongs to, with a relevance 0–1 |
| `opening_rule` | 2,443 | opening hours, one row per place per open weekday |
| `closure_window` | 13 | special shut periods, e.g. monsoon closures |
| `transport_mode` | 5 | car, bike, bus, train, walk — with speed and cost per km |
| `travel_leg` | 7,450 | distance and time between nearby places, per mode |
| `place_embedding` | 358 | one 384-number "meaning" vector per place |
| `trip` | 34 | planned journeys |
| `trip_day` | 51 | the days of those trips |
| `itinerary_stop` | 172 | the places visited on those days |
| `review_summary` | 154 | reviews (rating, visit date, crowd level) |
| `feasibility_run` | 32 | results of checking the trips |
| `violation` | 8 | the problems those checks found |

### Places (the "world")

- **49 destinations** in Karnataka, Kerala, Tamil Nadu, Puducherry, Andhra Pradesh,
  Telangana and Goa — for example Madikeri (Coorg), Hampi, Mysuru, Fort Kochi,
  Madurai, Old Goa.
- **358 places** inside them, collected from OpenStreetMap — Abbey Falls, Mysore Palace,
  Virupaksha Temple and so on. Each has coordinates, a type, a typical visit time, an
  entry fee, and whether it needs daylight (waterfalls, hills and trails do).
- **Opening hours**: `day_of_week` uses **0 = Sunday … 6 = Saturday**. A weekday with no
  row means the place is **closed** that day.
- **Closures**: 13 special periods such as "Kote Betta is shut in the monsoon".
  `is_annual_recurring = TRUE` means it repeats every year on the same dates.
- **Travel legs**: calculated from the coordinates, not typed in. For every two places in
  the same destination less than 60 km apart, we store the road distance and the time by
  car, bike and bus (walking only within 3 km). `monsoon_duration_min` is 25% slower.

### Embeddings — why "384"

Each place has a short description. A small AI model (all-MiniLM-L6-v2) turns that text
into a list of **384 numbers** — always 384, that is just the size this model produces.
Places with similar meanings get similar lists, so pgvector can answer "find places like
*quiet waterfall in the forest*" by finding the closest lists.
So `place_embedding` has 358 rows (one per place), each holding one list of 384 numbers.
The operator `<=>` gives the **cosine distance** between two lists: smaller = more similar.

### People

- **30 users**, all invented, all with `@example.com` emails (a domain reserved for fake
  data). They live in Bengaluru, Kochi, Chennai, Hyderabad, Madurai and other cities.
- **25 travellers have a profile** and **2 deliberately do not** (`kiran.rao` and
  `anjali.desai`) — this proves the ER diagram's "a user MAY have a profile".
- Profiles differ on purpose: pace (`slow` / `moderate` / `packed`), daily budget
  (₹1,800 to ₹8,000), and how many hours of travel a day they accept (3 to 7).
- **Passwords**: every account's password is **`Sanchari@2026`**, but only a **bcrypt
  hash** is stored, never the password itself. Logging in looks like this:

```sql
SELECT display_name FROM user_account
WHERE  email = 'ananya.rao@example.com'
  AND  password_hash = crypt('Sanchari@2026', password_hash);   -- 1 row = correct password
```

### Trips — what "34 trips, 51 days, 172 stops" means

Three levels, like folders inside folders:

```
Trip  (34)          trip 1 — "Coorg coffee weekend"
 └─ Day  (51)         Day 1 — Sat 22 Aug 2026
     └─ Stop  (172)     1. Abbey Falls        09:00–10:00
                        2. Raja's Seat        10:30–11:15
                        3. Madikeri Fort      11:35–12:35
                        4. Madikeri Museum    12:55–13:40
 └─ Day               Day 2 — Sun 23 Aug 2026
     └─ Stop            1. Dubare Elephant Camp  09:00–11:30
                        2. Nisargadhama          12:05–13:35
```

Some trips are 1 day, some 2–3 days (51 days in total), with about 3–4 stops a day
(172 stops in total). This is why `trip_day` and `itinerary_stop` are weak entities.

| Kind of trip | How many | trip_id | Status |
|---|---:|---|---|
| Completed (Aug–Oct 2026) | 9 | 1–9 | `completed` |
| Upcoming | 15 | 10–24 | `draft`, `validated` or `locked` |
| Cancelled | 2 | 25–26 | `cancelled` |
| **Test trips** | **8** | **27–34** | `blocked` or `validated` after the check |

Every normal trip was timed by a program using our real data — opening hours, closures,
daylight and travel times — so it **passes all 8 rules**. Each test trip was built to break
**exactly one** rule (see A4).

`trip_id` matches the codes in `db/data/trips.csv`: T01 is trip 1, T27 is trip 27.

### Reviews

- **154 reviews**, generated by SQL in `07d_seed_reviews.sql`, not typed in:
  - 54 — every stop of the 9 completed trips, reviewed by the trip's owner.
  - 100 — each traveller reviews 4 places matching their interests.
- Ratings are mostly 4 and 5, with some 2 and 3. They are calculated from the id numbers
  (not random), so every rebuild gives the same reviews.
- `place.avg_rating` and `place.review_count` are filled from these reviews.
- `mongo_doc_id` is empty for now — the full review text will go into MongoDB later.

## A4. The 8 feasibility rules

Each rule asks one yes/no question about a trip plan. The full, exact definitions are in
`docs/feasibility_rules.md`.

| Rule | The question | Test trip that fails it | Type |
|---|---|---|---|
| R01 | Is the place open on that **weekday**? | 27 — Madikeri Museum on a Monday (closed Mondays) | blocking |
| R02 | Do you arrive within **entry hours**, and leave before closing? | 28 — Kamalapur museum at 16:45; last entry 16:30 | blocking |
| R03 | Is the place in a **special closure** on that date? | 29 — Kote Betta in July (monsoon closure) | blocking |
| R04 | Is there **enough time to travel** from the previous stop? | 30 — 10 minutes allowed, 50 needed | blocking |
| R05 | Do you spend **enough time** at the place? | 31 — 20 minutes at Mysore Palace; needs 120 | warning |
| R06 | Are **daylight-only** places visited between 06:30 and 18:30? | 32 — on Hemakuta Hill until 19:00 | blocking |
| R07 | Is the day's **total travel** within the traveller's limit? | 33 — 205 minutes of travel; limit 180 | warning |
| R08 | Is the trip within its **budget**? | 34 — family of 4, ₹3,000 budget, costs about ₹10,000 | warning |

- **Blocking** = the plan cannot work (the place is shut, or you cannot get there in time).
- **Warning** = the plan is possible but not advisable (rushed, tiring, over budget).

## A5. The feasibility engine — `p_check_trip`

The "engine" is a **stored procedure** in `db/08a_feasibility_engine.sql`. Run it with:

```sql
CALL p_check_trip(30);
```

It works like an exam checker for one trip plan:

1. **Locks the trip** (`SELECT … FOR UPDATE`), so two checks of the same trip cannot run
   at the same moment and mix up their results.
2. **Refuses impossible requests** — a trip that does not exist, or a cancelled trip,
   raises an error and nothing is saved.
3. **Opens a report card** — a new `feasibility_run` row with status `running`.
4. **Asks all 8 questions** of every stop with one big `INSERT … SELECT`. Each "no"
   becomes a `violation` row with a readable message, for example:
   *not enough time to reach Dubare Elephant Camp — 10 min allowed / 50 min needed*.
   R01–R06 point at the exact stop; R07 (a whole day) and R08 (the whole trip) leave the
   stop columns empty.
5. **Scores the trip**: 100, minus 25 per blocking problem, minus 10 per warning. The
   trip becomes `blocked` if it has any blocking problem, otherwise `validated` (locked
   and completed trips keep their status). The run is marked `completed`.

Every check adds a **new** run instead of overwriting the old one, so you can see a plan
improve over time (75 → 90 → 100) and ask "which rule fails most often?".

**The transaction:**
- The run, its violations and the trip's new score are saved **together or not at all**.
- Step 4 is inside a `BEGIN … EXCEPTION` block, which works like a **savepoint**. If it
  breaks, only the half-written violations are undone; the run stays, marked `failed`.

**Helper function `f_travel_minutes(from_place, to_place, mode, date)`** — minutes to get
from one place to the next. It uses `travel_leg` (the monsoon time in June–September);
if the pair is not there, it estimates from the distance and the mode's speed.

`db/09_run_feasibility.sql` calls the procedure for every trip except the 2 cancelled
ones. That is where the 32 runs and 8 violations come from: all 24 normal trips scored
100, and each test trip failed exactly its own rule.

## A6. The two triggers — `db/08b_triggers.sql`

A trigger is an automatic reaction: "whenever this table changes, do that".

- **`trg_review_summary_rating`** — after a review is added, deleted, or has its rating or
  place changed, it recalculates that place's `avg_rating` and `review_count`.
  Example: Abbey Falls has one 5-star review (5.00). Add a 1-star review → it becomes
  3.00 from 2 reviews, immediately.
- **`trg_itinerary_stop_date`** — the one your `01b` comments promised. Before a stop is
  saved, it checks that the stop's arrival date equals its day's `calendar_date`. A CHECK
  constraint cannot do this, because a CHECK only sees its own row and this needs another
  table.

## A7. All the files, in run order

| File | What it does |
|---|---|
| `00_extensions.sql` | vector, btree_gist, pgcrypto |
| `01a`, `01b` | the 19 tables |
| `03a`, `03b` | the 22 indexes |
| `04a`, `04b` | 4 views and `f_place_open_on()` |
| `05a`, `05b` | the ALTER / DROP demonstrations |
| `06a` | roles, transport modes, categories, destinations |
| `06b` | places (from `data/places.csv`) |
| `06c` | opening hours and closures |
| `06d` | travel legs (calculated) |
| `06e` | embeddings |
| `07a` | users, profiles, interests |
| `07b` | trips, days, stops |
| `07d` | reviews + avg_rating |
| `08a` | the feasibility engine |
| `08b` | the two triggers |
| `09` | runs the engine on every trip |
| `10_queries.sql` | **← yours** |

## A8. Still to do in the project

1. **The queries file — you (Part B below).**
2. MongoDB for the full review text.
3. The Next.js app: login for 2 roles, trip planning with a "Check feasibility" button,
   place search.
4. Updating `docs/PROGRESS.md` (out of date), then the demo.

---

# Part B — your task: `db/10_queries.sql`

## B1. What it is for

The course asks us to show we can **query** the database, not only build it. This file is
a set of about **15 meaningful questions** about our data, each answered by one SQL
statement, together covering:

| Must show | At least |
|---|---|
| JOIN (including a LEFT JOIN and a 3+ table join) | 4 queries |
| GROUP BY with aggregates (COUNT, AVG, SUM, MIN, MAX) | 3 |
| HAVING | 2 |
| Subqueries — in WHERE, with IN / NOT IN or EXISTS, and in FROM | 3 |
| UPDATE | 2 |
| DELETE | 2 |

"Meaningful" means each query answers a question someone using Sanchari would really ask
— not `SELECT * FROM place`. This output also goes into the lab record as screenshots, so
it should look clean.

## B2. The rules

1. **Do not change the data permanently.** Every UPDATE and DELETE goes inside
   `BEGIN; … ROLLBACK;`. Show the rows before, make the change, show the rows after, then
   `ROLLBACK` undoes it. That way the file can be run any number of times and the
   database stays exactly as `run_all.sql` built it.
2. **Do not add this file to `run_all.sql`.** It is run on its own, after the build.
3. **Do not edit files 00–09.** If you find something wrong in them, tell Swara.
4. **Each query has a header comment** saying the question in plain English and which
   concepts it shows (see the template).
5. **Put `\echo` before each query** so the output says which question it is answering.
6. **Same style as the other files**: SQL keywords in CAPITALS, short table aliases
   (`p` for place, `t` for trip …), one clause per line, an `ORDER BY` on every query
   that returns more than one row.
7. **Keep results short**: add `LIMIT 10` where a query would return hundreds of rows.

## B3. Template for the file

```sql
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
```

## B4. Suggested queries

You can change these or add your own — just keep the coverage in B1. The hints tell you
which tables to use; writing the SQL is your part. "Expect" tells you what a correct
answer looks like, where we already know it.

### JOINs

**Q1. The full plan of one trip, in order.**
For trip 1, list each day's date, stop number, place name, destination, arrival and
departure. *Shows: 4-table JOIN.*
Hint: `itinerary_stop` → `trip_day` (on trip_id AND day_number) → `place` →
`destination`. Order by day, then stop.

**Q2. Travellers who have no profile.**
*Shows: LEFT JOIN … WHERE … IS NULL.*
Hint: `user_account` JOIN `role` (only Travellers) LEFT JOIN `traveller_profile`.
Expect: 2 rows — `kiran.rao` and `anjali.desai`.

**Q3. Places per state.** *(Done in the template above — keep it.)*

**Q4. What each traveller is interested in.**
Each traveller's name next to their interests, strongest first.
*Shows: 4-table JOIN, `string_agg`, GROUP BY.*
Hint: `user_account` → `traveller_profile` → `traveller_interest` → `interest_category`.
`string_agg(ic.name, ', ' ORDER BY ti.weight DESC)` puts them in one line.

**Q5. The 5 quickest walks in Hampi.**
Pairs of places in Hampi with walking time, shortest first.
*Shows: joining the same table twice (place as "from" and as "to").*
Hint: `travel_leg` JOIN `place` AS `pf` (from) JOIN `place` AS `pt` (to) JOIN
`transport_mode` (where `mode_name = 'walk'`) JOIN `destination` (name = 'Hampi').
Each pair appears in both directions — keep one with `pf.place_id < pt.place_id`.

### GROUP BY and HAVING

**Q6. The best-covered destinations.**
Destinations that have at least 9 places, most first.
*Shows: GROUP BY + HAVING COUNT.*
Expect: 14 destinations (8 have 10 places, 6 have 9).

**Q7. Best-rated places with enough reviews.**
Top 10 places by average rating among those with at least 2 reviews.
(Reviews are spread thinly — 26 places have 2 or more, and the most any place has is 3.)
*Shows: GROUP BY on `review_summary`, HAVING, ORDER BY … LIMIT.*
Hint: work it out from `review_summary` with `AVG(rating)` and `COUNT(*)`, then compare
your numbers with `place.avg_rating` — they should match (the trigger keeps them equal).

**Q8. Which interest categories have the best-rated places?**
For each category: number of places, and their average rating. Keep only categories
whose average is at least 4.0.
*Shows: 3-table JOIN, GROUP BY, AVG, HAVING.*
Hint: `interest_category` → `place_category` → `place`; skip places with no rating
(`avg_rating IS NOT NULL`).
Expect: 11 categories, led by Coffee, Tea & Plantations (4.67).

**Q9. Which rule fails most often?**
Each rule code with how many violations it caused and its severity.
*Shows: GROUP BY on the engine's output.*
Expect: 8 rows (R01–R08), one violation each — because each test trip breaks one rule.

### Subqueries

**Q10. Places that cost more than the average entry fee.**
*Shows: scalar subquery in WHERE — `fee_indian > (SELECT AVG(fee_indian) FROM place)`.*

**Q11. Places nobody has planned to visit yet.**
How many of the 358 places appear in no trip? List 10 of them.
Write it once with NOT IN and once with NOT EXISTS — both must give the same count.
*Shows: NOT IN or NOT EXISTS with a subquery on `itinerary_stop`.*

**Q12. Travellers who reviewed a place on a trip they planned.**
*Shows: EXISTS with a correlated subquery (the inner query uses the outer row).*
Hint: for each review, EXISTS a stop in a trip owned by the same user at the same place.

**Q13. Average trip cost by status.**
For each trip status: number of trips and average total cost.
*Shows: subquery in FROM (a "derived table").*
Hint: the inner query adds up `estimated_cost` per trip; the outer one groups by status.

### Special features (good for the viva)

**Q14. Is Madikeri Museum open on Monday 14 December 2026?**
*Shows: calling our function inside a query.*
Hint: `SELECT * FROM f_place_open_on(<its place_id>, DATE '2026-12-14');` — use a
subquery to find the place_id by name instead of typing the number.
Expect: `is_open = false`, `status_reason = 'closed on Monday'`.

**Q15. The 5 places most similar to Abbey Falls.**
*Shows: pgvector semantic search.*
Hint: `ORDER BY e.embedding <=> (SELECT embedding FROM place_embedding WHERE place_id =
<Abbey Falls>)` and leave Abbey Falls itself out.
Expect: all 5 are waterfalls (Pochera Falls, Attukad Waterfalls, Charpa Falls, Iruppu
Falls, Bear Shola Falls) — the model has never been told what a "waterfall" is, it worked
that out from the descriptions.

### UPDATE and DELETE — always inside BEGIN … ROLLBACK

**Q16. UPDATE: raise every museum's entry fee in Tamil Nadu by 10%.**
Show the fees before, run the UPDATE, show them after, ROLLBACK.
*Shows: UPDATE with a subquery in WHERE (destination_id IN (SELECT … WHERE state =
'Tamil Nadu')).*

**Q17. UPDATE: the rating trigger in action.**
Pick a place with 3 reviews, such as Palolem Beach. Show its `avg_rating` and
`review_count`; change one of its reviews' `rating` to 1.0; show them again — the average
drops by itself, because the trigger did it; ROLLBACK.

**Q18. DELETE with CASCADE: delete trip 34.**
Count trip 34's days, stops, runs and violations; DELETE the trip; count again — all 0,
because the foreign keys are `ON DELETE CASCADE`; ROLLBACK.

**Q19. DELETE that is refused: try to delete a place someone has planned.**
DELETE Mysore Palace → **ERROR**, because `fk_itinerary_stop_place` is `ON DELETE
RESTRICT`. Then ROLLBACK.
Note: after an error, PostgreSQL ignores commands until ROLLBACK — so keep this block to
just `BEGIN; DELETE …; ROLLBACK;`, and put it **last** in the file so the error does not
hide other results. Add a comment saying the error is expected.

## B5. Things that are easy to get wrong

- **Joining a stop to its day needs two columns**: `ON td.trip_id = s.trip_id AND
  td.day_number = s.day_number`. Joining on trip_id alone gives wrong, repeated rows.
- **`day_of_week` is 0 = Sunday … 6 = Saturday** (same as `EXTRACT(DOW FROM date)`).
- **Names with apostrophes** need doubling in SQL: `'Raja''s Seat'`.
- **Destination names are exact**: Coorg is `'Coorg / Kodagu'`, not `'Coorg'`. Check with
  `SELECT name FROM destination ORDER BY name;` before filtering by name.
- **Two travellers have no profile** — an INNER JOIN to `traveller_profile` silently drops
  them. Use LEFT JOIN when you want everyone.
- **`travel_leg` stores both directions** (A→B and B→A).
- **`planned_arrival` is a full timestamp** — use `::TIME` for the clock time or
  `::DATE` for the date.
- **Rounding**: `ROUND(AVG(rating), 2)` keeps averages readable.
- **Role names** are exactly `'Traveller'`, `'Curator'`, `'Admin'`.

## B6. How to test

1. Write a few queries in the file.
2. Copy the folder in and run just your file:
   ```powershell
   docker cp db/. sanchari-db:/db
   docker exec sanchari-db psql -U postgres -d sanchari -f /db/10_queries.sql
   ```
3. Check every result makes sense (use the "Expect" notes).
4. **Run the file twice in a row.** The second run must give exactly the same output —
   that proves the ROLLBACKs work and nothing was changed.
5. Run `verify.sql` afterwards: the row counts in section 8 must be unchanged.

## B7. How to submit

```powershell
git pull                                   # get the latest first
git add db/10_queries.sql
git commit -m "feat(queries): meaningful queries - JOIN, GROUP BY, HAVING, subqueries, UPDATE, DELETE"
git push
```

If `git push` says your branch is behind, run `git pull` again, then push.

Then message Swara with a screenshot of the output. If anything in Part A is unclear, or a
query gives a result you don't expect, ask before changing any other file.
