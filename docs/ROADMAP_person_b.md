# Sanchari — Roadmap for Person B

**Your half of the database.** This document takes you from nothing installed to the same
point Swara has already reached on her side, one step at a time.

Read the whole thing once before starting Step 1. It is short, and Step 3 explains a
decision you need to have in your head before you write any SQL.

---

## Where the project currently stands

| | Status |
|---|---|
| Design (ER diagram, relational schema) | Done — 16 entities, 19 tables, 24 foreign keys |
| Repo, branches, conventions | Done |
| **Person A** — 13 tables, 8 indexes, 2 views, 1 function, ALTER/DROP demo | **Done and pushed** to `ddl/people-places` |
| **Person B** — 6 tables, indexes, views, ALTER/DROP demo | **Not started — this is you** |
| Integration (`run_all` / `reset` / `verify`) | Not started — also you |

Your six tables all have foreign keys pointing *into* Person A's thirteen. Hers point at
nothing of yours. That one-way dependency is why the split falls where it does, and why
her branch merges into `main` before yours can run.

---

## Step 0 — Get PostgreSQL and pgvector running

**Do this before anything else.** It is the step most likely to eat an hour, and none of
it is shared work.

### The numbers you must match

Swara's environment, verified and working. Match the **major version** exactly — if one
of you is on 17 and the other on 18, a script that runs clean on one machine can fail on
the other, and you will lose an evening to something that has nothing to do with your
schema.

| | Value |
|---|---|
| PostgreSQL | **17** (hers reports 17.11) |
| pgvector | 0.8.x (hers is 0.8.6 — minor differences are fine) |
| Docker image | `pgvector/pgvector:pg17-bookworm` |
| Database name | `sanchari` |
| Local dev password | `sanchari_dev` |

### The quickest route — Docker

The image already contains PostgreSQL *and* pgvector, so there is nothing to compile.
It is also trivially resettable, which matters later when you have to prove the whole
schema builds from scratch.

1. Install **Docker Desktop**. On Windows, say yes when it asks to enable WSL 2.
2. Confirm it works: `docker --version`
3. Start the database — one line, run once:

```
docker run --name sanchari-db -e POSTGRES_PASSWORD=sanchari_dev -e POSTGRES_DB=sanchari -p 5432:5432 -v sanchari_data:/var/lib/postgresql/data -d pgvector/pgvector:pg17-bookworm
```

4. Check it is up: `docker ps` — you want `sanchari-db` with status `Up`.

**Commands you will use constantly:**

```powershell
# open a SQL prompt
docker exec -it sanchari-db psql -U postgres -d sanchari

# run a .sql file  (Windows PowerShell — note this syntax, it catches people out)
Get-Content db\somefile.sql | docker exec -i sanchari-db psql -U postgres -d sanchari

# macOS / Linux / WSL
docker exec -i sanchari-db psql -U postgres -d sanchari < db/somefile.sql

# stop / start between sessions
docker stop sanchari-db
docker start sanchari-db
```

If Docker is not an option on your machine, Ubuntu under WSL2 works too —
`sudo apt install postgresql-17 postgresql-17-pgvector` after adding the PostgreSQL
project's own apt repository. The full alternative paths are in
`docs/Sanchari_Step0_Setup.html`. Avoid installing PostgreSQL natively on Windows unless
you must: there is no pgvector installer for Windows, so you would have to compile it
with Visual Studio's C++ tools.

### Prove it works

Run the check script that is already in the repo:

```powershell
Get-Content db\00_check_setup.sql | docker exec -i sanchari-db psql -U postgres -d sanchari
```

It must finish with **no `ERROR` lines**. The section that matters is the similarity
search near the end:

```
   label   | cosine_distance
-----------+-----------------
 waterfall |        0.000000
 lake      |        0.008540
 fort      |        0.025368
```

`lake` beating `fort` for closeness to `[1,2,3]` is the proof that vector search is
genuinely running on your machine, not just that the extension loaded.

### Step 0 is done when

- [ ] The check script runs with zero errors
- [ ] Your PostgreSQL **major** version is 17, same as Swara's
- [ ] You have saved your output to `docs/step0-verification-<yourname>.md`, matching the
      format of Swara's file already in that folder
- [ ] You have sent Swara your version numbers

---

## Step 1 — Get the repo and your branch

```powershell
git clone https://github.com/swarapotd-rgb/sanchari-dbms-project.git
cd sanchari-dbms-project

git config user.name  "<Your Name>"
git config user.email "<your@email>"

git checkout ddl/trips-checks
```

Setting your git identity matters more than it looks — requirement 15 says commits must
demonstrate individual contributions, and requirement 16 evaluates them. If your name is
not configured, your work does not show up as yours.

**Your branch already exists** and was pushed for you. Do not work on `main`.

---

## Step 2 — Read before you write

Three things, in this order. This is maybe forty minutes and it will save you far more.

1. **`CONVENTIONS.md`** — naming, types, constraint naming, `ON DELETE` behaviour.
   **This is a draft, not a decision.** Swara wrote it so you weren't staring at a blank
   file. Argue with it. Two choices in particular are worth your opinion:

   - `TIMESTAMPTZ` for record-keeping timestamps like `created_at`, but plain
     `TIMESTAMP` for `planned_arrival` / `planned_departure`. The reasoning: a plan that
     says "3 pm" means wall-clock time at the destination, not an absolute instant.
     **This affects your tables more than hers** — `itinerary_stop` is where those
     columns live. If you disagree, say so now, not after both files are written.
   - `VARCHAR` + a named `CHECK` instead of PostgreSQL's `ENUM` type, because adding a
     value to a real ENUM needs `ALTER TYPE` and is painful to reverse.

2. **`docs/Sanchari_Core_Design_Explained.html`** — every entity, every column, and every
   relationship in plain English, with why each is 1:1, 1:N or M:N. Sections 01
   (vocabulary) and 03 (all 20 relationships) are the ones to actually read.

3. **`db/01a_tables_people_places.sql`** — Swara's file. Read `opening_rule` especially.
   It is a weak entity, and **three of your six tables are weak entities too**, so its
   shape is the shape you will be copying.

---

## Step 3 — Review Swara's pull request

`ddl/people-places` → `main`, on GitHub. Her thirteen tables cannot merge without your
review, and **your tables cannot run until hers are on `main`**, because your foreign
keys point at them.

This is not a rubber stamp. Check her `CHECK` constraints against section 09 of the
design document, and look specifically at whether every `ON DELETE` choice makes sense.
Then approve and merge.

```powershell
git checkout main
git pull
git checkout ddl/trips-checks
git merge main          # bring her tables into your branch so yours will run
```

---

## Step 4 — Write your six tables

File: **`db/01b_tables_trips_checks.sql`**

Follow the header format from her file. Tables in dependency order, exactly as listed
below — each references only tables defined above it, or Person A's tables which now
exist.

### Suggested order of work

Write `trip` first, run it, confirm it creates. Then `trip_day`, run again. Working
blind through all six and then debugging is much worse than getting a green run after
each one.

---

### 4.1 · `trip`

One planned journey. Ordinary strong entity — a good warm-up.

| Column | Type | Notes |
|---|---|---|
| `trip_id` | `BIGSERIAL` | PK |
| `owner_user_id` | `BIGINT NOT NULL` | → `user_account` |
| `primary_mode_id` | `INT NOT NULL` | → `transport_mode` |
| `title` | `VARCHAR(120) NOT NULL` | |
| `origin_city` | `VARCHAR(60)` | |
| `start_date` | `DATE NOT NULL` | |
| `end_date` | `DATE NOT NULL` | |
| `party_size` | `SMALLINT NOT NULL DEFAULT 1` | multiplies entry fees |
| `budget_cap` | `NUMERIC(10,2)` | |
| `status` | `VARCHAR(12) NOT NULL DEFAULT 'draft'` | |
| `feasibility_score` | `NUMERIC(5,2)` | derived, from the latest run |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | |

Constraints:

- `pk_trip`
- `fk_trip_owner` → `user_account (user_id)` **ON DELETE CASCADE** — a trip has no
  meaning without its owner
- `fk_trip_mode` → `transport_mode (mode_id)` **ON DELETE RESTRICT** — deleting "car"
  must not delete every trip taken by car
- `ck_trip_dates` — `end_date >= start_date`
- `ck_trip_party` — `party_size >= 1`
- `ck_trip_budget` — `budget_cap IS NULL OR budget_cap >= 0`
- `ck_trip_status` — `status IN ('draft','validated','blocked','locked','completed','cancelled')`
- `ck_trip_score` — `feasibility_score IS NULL OR feasibility_score BETWEEN 0 AND 100`

---

### 4.2 · `trip_day`

**Your first weak entity.** "Day 2" is meaningless; "Day 2 of trip 900" is not. So it
borrows its identity from `trip` — `trip_id` is part of the primary key *and* a foreign
key at the same time.

| Column | Type | Notes |
|---|---|---|
| `trip_id` | `BIGINT NOT NULL` | PK **and** FK → `trip` |
| `day_number` | `SMALLINT NOT NULL` | partial key — 1, 2, 3 within that trip |
| `calendar_date` | `DATE NOT NULL` | what closure windows are checked against |
| `base_destination_id` | `INT` | → `destination`, nullable |
| `day_start_time` | `TIME NOT NULL DEFAULT '08:00'` | |
| `day_end_time` | `TIME NOT NULL DEFAULT '21:00'` | |

Constraints:

- `pk_trip_day` — **`PRIMARY KEY (trip_id, day_number)`**
- `fk_trip_day_trip` → `trip` **ON DELETE CASCADE** (identifying relationship — the day
  cannot outlive its trip)
- `fk_trip_day_destination` → `destination` **ON DELETE SET NULL** — the day survives
  even if the region record is removed
- `uq_trip_day_date` — `UNIQUE (trip_id, calendar_date)`, one row per calendar day
- `ck_trip_day_number` — `day_number > 0`
- `ck_trip_day_window` — `day_end_time > day_start_time`

---

### 4.3 · `itinerary_stop`

**A two-level weak entity** — weak on `trip_day`, which is itself weak on `trip`. That
is why its primary key is **three columns**, and why the composite foreign key below
lists two columns together in one clause.

| Column | Type | Notes |
|---|---|---|
| `trip_id` | `BIGINT NOT NULL` | part of PK, part of composite FK |
| `day_number` | `SMALLINT NOT NULL` | part of PK, part of composite FK |
| `stop_seq` | `SMALLINT NOT NULL` | partial key — 1st, 2nd, 3rd stop of that day |
| `place_id` | `BIGINT NOT NULL` | → `place` |
| `planned_arrival` | `TIMESTAMP NOT NULL` | plain TIMESTAMP — see CONVENTIONS §3 |
| `planned_departure` | `TIMESTAMP NOT NULL` | |
| `estimated_cost` | `NUMERIC(10,2) NOT NULL DEFAULT 0` | |
| `notes` | `TEXT` | |

Constraints:

- `pk_itinerary_stop` — `PRIMARY KEY (trip_id, day_number, stop_seq)`
- **`fk_itinerary_stop_day`** — this is the fiddly one:

```sql
CONSTRAINT fk_itinerary_stop_day FOREIGN KEY (trip_id, day_number)
    REFERENCES trip_day (trip_id, day_number) ON DELETE CASCADE,
```

  Both columns go in **one** clause. Two separate single-column foreign keys would be
  wrong — they would not guarantee that the pair exists together.

- `fk_itinerary_stop_place` → `place (place_id)` **ON DELETE RESTRICT** — deleting a
  place someone has planned a visit to should fail loudly, not silently empty their trip
- `ck_itinerary_stop_seq` — `stop_seq > 0`
- `ck_itinerary_stop_times` — `planned_departure > planned_arrival`
- `ck_itinerary_stop_cost` — `estimated_cost >= 0`

---

### 4.4 · `feasibility_run`

One "check my plan" attempt. Keeping runs as rows, rather than overwriting a status,
means you can show a plan getting healthier over time — and it makes
*"which rule fails most often across all trips?"* a simple `GROUP BY`.

| Column | Type | Notes |
|---|---|---|
| `run_id` | `BIGSERIAL` | PK |
| `trip_id` | `BIGINT NOT NULL` | → `trip` |
| `run_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | |
| `rules_evaluated` | `SMALLINT NOT NULL DEFAULT 8` | |
| `blocking_count` | `INT NOT NULL DEFAULT 0` | derived from violations |
| `warning_count` | `INT NOT NULL DEFAULT 0` | derived |
| `feasibility_score` | `NUMERIC(5,2)` | 0–100 |
| `run_status` | `VARCHAR(12) NOT NULL DEFAULT 'running'` | |

Constraints: `pk_feasibility_run`; `fk_feasibility_run_trip` → `trip` **ON DELETE
CASCADE**; `ck_feasibility_run_status` — `run_status IN ('running','completed','failed')`;
`ck_feasibility_run_counts` — both counts `>= 0`; `ck_feasibility_run_score` — score
between 0 and 100 or NULL.

---

### 4.5 · `violation`

One problem found. Weak on `feasibility_run` — "violation 2" means nothing without
knowing which run found it.

**This is the table with the three-column foreign key.** Expect to get it wrong once.

| Column | Type | Notes |
|---|---|---|
| `run_id` | `BIGINT NOT NULL` | PK **and** FK → `feasibility_run` |
| `violation_no` | `INT NOT NULL` | partial key |
| `rule_code` | `VARCHAR(10) NOT NULL` | R01 … R08 |
| `severity` | `VARCHAR(10) NOT NULL` | `blocking` or `warning` |
| `trip_id` | `BIGINT` | **nullable** — part of the stop reference |
| `day_number` | `SMALLINT` | **nullable** |
| `stop_seq` | `SMALLINT` | **nullable** |
| `message` | `TEXT NOT NULL` | the sentence shown on screen |
| `observed_value` | `VARCHAR(120)` | what the plan says — e.g. `17:45` |
| `expected_value` | `VARCHAR(120)` | what it needed to be — e.g. `<= 17:00` |
| `detected_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | |

Constraints:

- `pk_violation` — `PRIMARY KEY (run_id, violation_no)`
- `fk_violation_run` → `feasibility_run` **ON DELETE CASCADE**
- **`fk_violation_stop`** — three columns, one clause:

```sql
CONSTRAINT fk_violation_stop FOREIGN KEY (trip_id, day_number, stop_seq)
    REFERENCES itinerary_stop (trip_id, day_number, stop_seq) ON DELETE CASCADE,
```

  **All three must be nullable**, because trip-level violations like "over budget"
  belong to no particular stop. PostgreSQL's default `MATCH SIMPLE` means the foreign
  key is not enforced when any of the three is NULL, which is exactly the behaviour you
  want here.

- `ck_violation_rule` — `rule_code IN ('R01','R02','R03','R04','R05','R06','R07','R08')`
- `ck_violation_severity` — `severity IN ('blocking','warning','info')`
- `ck_violation_stop_ref` — either all three stop columns are NULL, or none are:

```sql
CONSTRAINT ck_violation_stop_ref CHECK (
    (trip_id IS NULL AND day_number IS NULL AND stop_seq IS NULL)
    OR (trip_id IS NOT NULL AND day_number IS NOT NULL AND stop_seq IS NOT NULL)
)
```

  Without this, a half-filled reference could sneak in and the foreign key would silently
  not check it. Worth writing — it is the kind of constraint an examiner notices.

Keep `observed_value` and `expected_value` as **separate columns**, not one message
string. That is what lets the interface say *"arrives 17:45, last entry is 17:00"*
instead of a vague red icon.

---

### 4.6 · `review_summary`

The countable half of a review. The prose, photos and per-aspect sub-ratings go to
MongoDB; `mongo_doc_id` is the string that links the two.

| Column | Type | Notes |
|---|---|---|
| `review_id` | `BIGSERIAL` | PK |
| `place_id` | `BIGINT NOT NULL` | → `place` |
| `user_id` | `BIGINT NOT NULL` | → `user_account` |
| `rating` | `NUMERIC(2,1) NOT NULL` | 1–5 |
| `visited_on` | `DATE NOT NULL` | date of the visit, not of writing |
| `actual_duration_min` | `INT` | corrects `place.typical_visit_minutes` over time |
| `crowd_level` | `SMALLINT` | 1–5 |
| `mongo_doc_id` | `CHAR(24)` | MongoDB ObjectId |
| `created_at` | `TIMESTAMPTZ NOT NULL DEFAULT now()` | |

Constraints: `pk_review_summary`; `fk_review_summary_place` → `place` **ON DELETE
CASCADE**; `fk_review_summary_user` → `user_account` **ON DELETE CASCADE**;
`uq_review_summary_visit` — `UNIQUE (place_id, user_id, visited_on)`, one review per
person per visit; `ck_review_summary_rating` — 1 to 5;
`ck_review_summary_crowd` — 1 to 5 or NULL; `ck_review_summary_duration` — `> 0` or NULL.

---

### Step 4 is done when

```powershell
docker exec -i sanchari-db psql -U postgres -d sanchari -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
Get-Content db\00_extensions.sql             | docker exec -i sanchari-db psql -U postgres -d sanchari
Get-Content db\01a_tables_people_places.sql  | docker exec -i sanchari-db psql -U postgres -d sanchari
Get-Content db\01b_tables_trips_checks.sql   | docker exec -i sanchari-db psql -U postgres -d sanchari

docker exec -i sanchari-db psql -U postgres -d sanchari -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';"
```

Expect **19**. Then:

```powershell
git add db/01b_tables_trips_checks.sql
git commit -m "feat(db): Person B tables - trips, itineraries and validation (6 tables, 11 FKs)"
git push -u origin ddl/trips-checks
```

---

## Step 5 — Your indexes

File: **`db/03b_indexes_trips_checks.sql`**

PostgreSQL indexes primary keys and UNIQUE constraints automatically, but **not** foreign
key columns. Un-indexed foreign keys are the classic cause of slow deletes on the parent.

| Index | On | Why |
|---|---|---|
| `idx_trip_owner` | `trip (owner_user_id)` | "all my trips" |
| `idx_trip_status` | `trip (status)` | dashboard filtering |
| `idx_trip_day_destination` | `trip_day (base_destination_id)` | foreign key |
| `idx_itinerary_stop_place` | `itinerary_stop (place_id)` | "who has planned to visit this place" |
| `idx_itinerary_stop_arrival` | `itinerary_stop (planned_arrival)` | rule R04 walks stops in time order |
| `idx_feasibility_run_latest` | `feasibility_run (trip_id, run_at DESC)` | "the most recent check for this trip" |
| `idx_violation_rule` | `violation (rule_code)` | "which rule fails most often" |
| `idx_violation_blocking` | `violation (run_id)` **WHERE `severity = 'blocking'`** | a **partial index** — only indexes the rows that matter, so it stays small |
| `idx_review_summary_place` | `review_summary (place_id)` | rating aggregation |
| `idx_review_summary_user` | `review_summary (user_id)` | foreign key |

The partial index is worth calling out in your documentation — it is a genuinely
advanced feature and most student projects never use one.

---

## Step 6 — Your views

File: **`db/04b_views_trips.sql`**

### `v_day_schedule`

One row per stop, with the previous stop and the gap between them. This is what makes
rule R04 (travel-time overlap) readable instead of a mess of subqueries.

Use a window function:

```sql
LAG(planned_departure) OVER (PARTITION BY trip_id, day_number ORDER BY stop_seq)
```

Columns to expose: trip, day, stop sequence, place name, planned arrival and departure,
minutes allotted at the stop, the previous stop's departure, and the gap in minutes
between leaving the last place and arriving at this one.

### `v_trip_health`

One row per trip with its most recent feasibility run — score, blocking count, warning
count, when it last ran. `DISTINCT ON (trip_id) ... ORDER BY trip_id, run_at DESC` is the
neat PostgreSQL way to get "latest row per group".

Person A's file (`04a_views_places.sql`) has two worked views and one function you can
copy the style from — especially the commenting style.

---

## Step 7 — Your ALTER / DROP demonstration

File: **`db/05b_alter_drop_demo_b.sql`**

Requirement 5 asks to see `CREATE`, `ALTER` **and** `DROP`. Person A's file
(`05a_alter_drop_demo_a.sql`) shows the pattern: one real, additive, permanent change,
then a throwaway scratch table put through every kind of `ALTER` and then dropped.

Suggested real change: add `notes TEXT` to `trip`, or a `last_validated_at TIMESTAMPTZ`
column. Additive and safe.

Do **not** demonstrate `DROP` on anything the schema depends on.

---

## Step 8 — Integration (yours alone)

Three files that make the whole thing runnable and provable.

### `db/reset.sql`
```sql
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
```
Two lines, and you will use them constantly.

### `db/run_all.sql`
Calls every file in dependency order:
```
00_extensions.sql
01a_tables_people_places.sql
01b_tables_trips_checks.sql
03a_indexes_people_places.sql
03b_indexes_trips_checks.sql
04a_views_places.sql
04b_views_trips.sql
05a_alter_drop_demo_a.sql
05b_alter_drop_demo_b.sql
```
In psql, `\i filename.sql` includes another file.

### `db/verify.sql`
Queries `information_schema` to prove the schema is complete. **This is the screenshot
that goes in the lab record.** It should report:

- **19** base tables
- **24** foreign keys
- **0** constraints with system-generated names (all should match `pk_`/`fk_`/`uq_`/`ck_`)
- the index count and the view count

---

## Definition of done for the whole step

- [ ] Both `docs/step0-verification-*.md` files exist and the major versions match
- [ ] `psql -f db/run_all.sql` on a **brand-new empty database** completes with no errors
- [ ] `verify.sql` reports 19 tables and 24 foreign keys
- [ ] Every constraint has a name you chose, not one PostgreSQL generated
- [ ] Both branches merged to `main`, and `git log --author` shows real commits from each of you
- [ ] Screenshot captured for the lab record

---

## If you get stuck

| Problem | Almost certainly |
|---|---|
| `ERROR: extension "vector" is not available` | pgvector version doesn't match the server version. On Linux check `postgresql-**17**-pgvector`. |
| `relation "place" does not exist` | You haven't merged `main` into your branch, or you ran `01b` before `01a`. |
| `there is no unique constraint matching given keys` | Your composite foreign key columns don't exactly match the parent's primary key columns, in the same order. |
| `port is already allocated` | Another PostgreSQL is on 5432. Use `-p 5433:5432` and remember the port. |
| `could not connect to server` after a reboot | `docker start sanchari-db`. |

Anything else — message Swara rather than guessing. A schema change made unilaterally can
break the other person's foreign keys, so raise it before you change it.
