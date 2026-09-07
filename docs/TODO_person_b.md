# Sanchari — TODO for Person B

**Read Step 0 before touching any file.** It explains why your `01b` and the one on `main`
have diverged, and it saves you from redoing work that is already done.

---

## Step 0 — What happened, and why you must pull first

You wrote a corrected `01b` from the roadmap. Independently, Swara had already corrected
the `01b` on `main`. Both fixes happened at the same time, so the two files now differ.

**We compared them properly.** Yours is a real improvement on your first version — types,
named primary keys, `TIMESTAMP`, `ON DELETE` on every foreign key, both composite foreign
keys correct. It runs clean: 19 tables, 24 foreign keys, zero auto-named constraints.

But eight constraints that are live on `main` are absent from yours:

```
ck_trip_budget              uq_trip_day_date
ck_trip_day_window          uq_review_summary_visit
ck_itinerary_stop_cost      ck_violation_stop_ref
ck_feasibility_run_counts   ck_review_summary_duration
```

and five columns went back to nullable (`trip.mode_id`, both `trip_day` time columns,
`estimated_cost`, `visited_on`). Nothing in yours is missing from `main`.

**So: do not merge your version.** `main`'s `01b` is already correct. Your file's job now
is as a comparison, not as a commit. This is a process problem — you were working from a
stale copy — not a problem with your SQL.

### Do this first

```powershell
# park your version somewhere safe, outside the repo
Move-Item db\01b_tables_trips_checks.sql $env:TEMP\01b_mine.sql -Force

git checkout main
git pull

git checkout ddl/trips-checks
git merge main -m "merge: bring corrected 01b and Person A files into branch"
git push
```

Your branch now has all 8 db files. From here on, **always `git pull` on `main` and merge
before starting a new file.**

---

## Step 1 — Compare, don't rewrite (15 minutes, worth it)

Open `$env:TEMP\01b_mine.sql` next to `db/01b_tables_trips_checks.sql` and read the
CHANGELOG block at the bottom of the repo version. It lists every correction and why.

Two things specifically worth understanding, because they will come up in the viva:

- **`ck_violation_stop_ref`** — either all three stop columns are set, or all three are
  NULL. PostgreSQL's default `MATCH SIMPLE` means the composite foreign key is *not
  enforced* when any of the three is NULL, so a half-filled reference would slip through
  unchecked. This CHECK closes that hole.
- **`uq_trip_day_date`** and **`uq_review_summary_visit`** — without them, one trip can
  hold two Day 3s, and one user can review a place endlessly, which would quietly corrupt
  `place.avg_rating`.

### One thing from your version we want to keep

Your `fk_violation_stop ON DELETE SET NULL` may be better than `main`'s `CASCADE`. Delete
a stop and the violation record survives with a null reference, rather than vanishing —
for an audit table that is arguably the right call, and `SET NULL` nulls all three columns
together so `ck_violation_stop_ref` still holds.

**Message Swara, agree it, then make it as a one-line change of its own** so the reasoning
is visible in the history:

```sql
-- in db/01b_tables_trips_checks.sql
CONSTRAINT fk_violation_stop FOREIGN KEY (trip_id, day_number, stop_seq)
    REFERENCES itinerary_stop (trip_id, day_number, stop_seq)
    ON DELETE SET NULL,          -- was CASCADE
```

### One bug in your version, already right on main

You had `trip_day.destination_id BIGINT`, but `destination.destination_id` is `SERIAL`
(i.e. `INTEGER`) in `01a` — a small lookup table, not a growing one. `user_id` really is
`BIGSERIAL`, so you were right about that one. `main` already has `INT`, so nothing to do
— but good instinct flagging the uncertainty in your header comment rather than guessing
silently.

### An ambiguity that is not your fault

You used `user_id` / `mode_id`; `main` uses `owner_user_id` / `primary_mode_id`.
CONVENTIONS.md §1 says a foreign key column takes *the same name as the key it points to*,
which makes **your** version the correct reading. We are keeping `main`'s names because the
design document uses them and `owner_user_id` will read better once trips gain editors —
but the conventions file needs its wording fixed so this does not happen again. Raise it.

---

## Step 2 — `db/03b_indexes_trips_checks.sql`

PostgreSQL indexes primary keys and UNIQUE constraints automatically, but **not** foreign
key columns. Un-indexed foreign keys are the classic cause of slow deletes on the parent.

| Index | On | Why |
|---|---|---|
| `idx_trip_owner` | `trip (owner_user_id)` | "all my trips" |
| `idx_trip_status` | `trip (status)` | dashboard filtering |
| `idx_trip_day_destination` | `trip_day (base_destination_id)` | foreign key |
| `idx_itinerary_stop_place` | `itinerary_stop (place_id)` | "who plans to visit this place" |
| `idx_itinerary_stop_arrival` | `itinerary_stop (planned_arrival)` | R04 walks stops in time order |
| `idx_feasibility_run_latest` | `feasibility_run (trip_id, run_at DESC)` | "latest check for this trip" |
| `idx_violation_rule` | `violation (rule_code)` | "which rule fails most often" |
| `idx_violation_blocking` | `violation (run_id)` **WHERE `severity = 'blocking'`** | **partial index** |
| `idx_review_summary_place` | `review_summary (place_id)` | rating aggregation |
| `idx_review_summary_user` | `review_summary (user_id)` | foreign key |

**Call the partial index out in your documentation.** Indexing only the rows that matter
keeps it small, and most student projects never use one.

Look at `03a_indexes_people_places.sql` first — it opens with a deliberate *non*-index and
explains why (the UNIQUE constraint already provides it). Check whether any of yours is
redundant for the same reason before you write it.

---

## Step 3 — `db/04b_views_trips.sql`

### `v_day_schedule`

One row per stop, with the previous stop's departure and the gap between them. This is what
makes rule R04 readable instead of a pile of subqueries.

```sql
LAG(planned_departure) OVER (PARTITION BY trip_id, day_number ORDER BY stop_seq)
```

Because `planned_arrival` and `planned_departure` are now `TIMESTAMP` rather than `TIME`,
the gap is a clean subtraction that survives a midnight crossing:

```sql
EXTRACT(EPOCH FROM (planned_arrival - LAG(planned_departure) OVER (...))) / 60 AS gap_minutes
```

Expose: trip, day, stop sequence, place name, planned arrival and departure, minutes
allotted at the stop, previous departure, and the gap in minutes.

### `v_trip_health`

One row per trip with its most recent run — score, blocking count, warning count, when it
last ran. `DISTINCT ON (trip_id) ... ORDER BY trip_id, run_at DESC` is the neat PostgreSQL
way to get "latest row per group".

`04a_views_places.sql` has two worked views and a function to copy the commenting style
from.

---

## Step 4 — `db/05b_alter_drop_demo_b.sql`

Requirement 5 wants `CREATE`, `ALTER` **and** `DROP` all visibly demonstrated. Follow the
shape of `05a_alter_drop_demo_a.sql`:

- **Part 1** — one real, additive, permanent change. Suggestion: add
  `last_validated_at TIMESTAMPTZ` to `trip`, or `notes TEXT`. Additive and safe.
- **Part 2** — a throwaway `_demo_scratch_b` table put through `ADD COLUMN`, `ALTER COLUMN
  TYPE`, `SET DEFAULT`, `SET NOT NULL`, `RENAME COLUMN`, `RENAME TABLE`, `ADD CONSTRAINT`,
  `DROP CONSTRAINT`, then `DROP INDEX`, `DROP VIEW`, `DROP TABLE`.

Never demonstrate `DROP` on anything the schema depends on.

---

## Step 5 — Integration (`run_all`, `reset`, `verify`)

These three are yours alone, and they are what let the team prove the step is finished.

### `db/reset.sql`
```sql
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
```

### `db/run_all.sql`
Every file in dependency order. In psql, `\i` includes another file:

```
\i 00_extensions.sql
\i 01a_tables_people_places.sql
\i 01b_tables_trips_checks.sql
\i 03a_indexes_people_places.sql
\i 03b_indexes_trips_checks.sql
\i 04a_views_places.sql
\i 04b_views_trips.sql
\i 05a_alter_drop_demo_a.sql
\i 05b_alter_drop_demo_b.sql
```

### `db/verify.sql`
Queries `information_schema` and `pg_constraint` to prove the schema is complete.
**This output is the screenshot that goes in the lab record.** It should report:

| Check | Expected |
|---|---|
| base tables | **19** |
| foreign keys | **24** |
| constraints with system-generated names | **0** |
| `idx_` indexes | 18 (8 from A + 10 from B) |
| views | 4 |
| functions defined by us | 1 (`f_place_open_on`) |

A useful starting query:

```sql
SELECT
  (SELECT count(*) FROM information_schema.tables
    WHERE table_schema='public' AND table_type='BASE TABLE')            AS tables,
  (SELECT count(*) FROM information_schema.table_constraints
    WHERE constraint_type='FOREIGN KEY' AND table_schema='public')      AS foreign_keys,
  (SELECT count(*) FROM pg_constraint c
     JOIN pg_class t ON t.oid=c.conrelid
     JOIN pg_namespace n ON n.oid=t.relnamespace
    WHERE n.nspname='public' AND c.conname !~ '^(pk|fk|uq|ck)_')        AS unnamed_constraints;
```

---

## Test as you go

After **every** file you add, rebuild from scratch. This catches ordering mistakes
immediately instead of at the end:

```powershell
docker exec -i sanchari-db psql -U postgres -d sanchari -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
Get-Content db\00_extensions.sql             | docker exec -i sanchari-db psql -U postgres -d sanchari
Get-Content db\01a_tables_people_places.sql  | docker exec -i sanchari-db psql -U postgres -d sanchari
Get-Content db\01b_tables_trips_checks.sql   | docker exec -i sanchari-db psql -U postgres -d sanchari
Get-Content db\03a_indexes_people_places.sql | docker exec -i sanchari-db psql -U postgres -d sanchari
Get-Content db\03b_indexes_trips_checks.sql  | docker exec -i sanchari-db psql -U postgres -d sanchari
Get-Content db\04a_views_places.sql          | docker exec -i sanchari-db psql -U postgres -d sanchari
Get-Content db\04b_views_trips.sql           | docker exec -i sanchari-db psql -U postgres -d sanchari
```

Commit each file separately, with a message saying what it does. Separate commits are what
requirement 16 looks at when it evaluates individual contribution.

---

## Definition of done

- [ ] Branch merged with `main`; you are working from the current `01b`
- [ ] `fk_violation_stop` decision agreed with Swara and committed if adopted
- [ ] `03b_indexes_trips_checks.sql` — 10 indexes including one partial
- [ ] `04b_views_trips.sql` — `v_day_schedule` and `v_trip_health`
- [ ] `05b_alter_drop_demo_b.sql` — CREATE, ALTER and DROP all demonstrated
- [ ] `run_all.sql`, `reset.sql`, `verify.sql`
- [ ] `reset.sql` then `run_all.sql` on an empty database completes with **no errors**
- [ ] `verify.sql` reports 19 tables, 24 foreign keys, 0 unnamed constraints
- [ ] Screenshot captured for the lab record
- [ ] Everything merged to `main`

---

## If you get stuck

| Problem | Almost certainly |
|---|---|
| `relation "place" does not exist` | You haven't merged `main` into your branch |
| `there is no unique constraint matching given keys` | Composite FK columns don't match the parent's PK exactly, in the same order |
| `column ... referenced in foreign key constraint does not exist` | Column renamed on `main` — pull again |
| `cannot drop ... because other objects depend on it` | Drop the view before the table it reads |

Message Swara rather than guessing — and pull `main` before you start each file. That one
habit is what would have prevented this whole round-trip.
