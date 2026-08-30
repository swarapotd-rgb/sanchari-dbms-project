# Sanchari — Database Conventions

**Status: DRAFT by Swara. Not final until both team members have read it and agreed.**

This file exists so that two people writing SQL on two machines produce one consistent
schema. Agree it *before* writing any `CREATE TABLE`. Once agreed, change it only by
mutual agreement — a change here can break the other person's foreign keys.

---

## 1. Naming

| Thing | Rule | Example |
|---|---|---|
| Table name | `snake_case`, **singular**, lowercase | `opening_rule`, not `OpeningRules` |
| Column name | `snake_case`, lowercase | `typical_visit_minutes` |
| Primary key | `<table>_id` | `place_id` in table `place` |
| Foreign key column | **same name as the key it points to** | `place_id` in `itinerary_stop` |
| Two FKs to the same table | prefix with the role | `from_place_id`, `to_place_id` |
| View | `v_<what_it_shows>` | `v_place_open_on` |
| Index | `idx_<table>_<columns>` | `idx_opening_rule_place_day` |

Reserved words are avoided. Note `rank` is a reserved-ish word in SQL — if we ever need
it as a column, it gets quoted or renamed.

---

## 2. Constraint naming — **every constraint gets an explicit name**

This is the one rule that matters most. If you write an unnamed `CHECK`, PostgreSQL
invents a name like `place_check1`, and then `ALTER TABLE ... DROP CONSTRAINT` becomes
guesswork, and our `05_alter_drop_demo` files get ugly.

| Constraint | Pattern | Example |
|---|---|---|
| Primary key | `pk_<table>` | `pk_place` |
| Foreign key | `fk_<child>_<parent>` | `fk_itinerary_stop_place` |
| Foreign key, disambiguated | `fk_<child>_<column>` | `fk_travel_leg_from_place` |
| Unique | `uq_<table>_<columns>` | `uq_place_name_destination` |
| Check | `ck_<table>_<what_it_checks>` | `ck_trip_dates`, `ck_place_latitude_range` |

Written as:

```sql
CONSTRAINT ck_trip_dates CHECK (end_date >= start_date)
```

not:

```sql
CHECK (end_date >= start_date)          -- don't do this
```

---

## 3. Data types

| Kind of data | Type | Why |
|---|---|---|
| Surrogate key, high volume | `BIGSERIAL` | `place`, `trip`, `review_summary` — could grow |
| Surrogate key, small lookup | `SERIAL` | `role`, `transport_mode`, `interest_category` |
| Money / cost | `NUMERIC(10,2)` | **never** `FLOAT` or `REAL` — rounding errors in budgets |
| Latitude / longitude | `NUMERIC(9,6)` | ~11 cm precision, enough for map pins |
| Ratings, weights, scores | `NUMERIC(3,1)` or `NUMERIC(3,2)` | exact, with a `CHECK` on the range |
| Record-keeping timestamp | `TIMESTAMPTZ DEFAULT now()` | `created_at`, `updated_at` — real moments in time |
| Planned arrival / departure | `TIMESTAMP` (no timezone) | wall-clock time at the destination; a plan says "3 pm", not "3 pm UTC" |
| Calendar date | `DATE` | `calendar_date`, `start_date`, `visited_on` |
| Time of day | `TIME` | `opens_at`, `closes_at`, `last_entry_at` |
| Short bounded text | `VARCHAR(n)` | names, codes, statuses |
| Free prose | `TEXT` | `description`, `notes`, `message` |
| Yes/no | `BOOLEAN` with an explicit `DEFAULT` | never nullable unless "unknown" is a real state |
| Embedding | `VECTOR(384)` | pgvector; dimension fixed at 384 |

**The TIMESTAMPTZ vs TIMESTAMP split is deliberate.** `created_at` is an event that
happened at an absolute instant, so it carries a timezone. `planned_arrival` is
"we intend to be there at 3 pm local" — attaching a timezone to a plan makes the
feasibility comparison against `opens_at` (a plain `TIME`) awkward. Keep them plain.

---

## 4. Enumerated values

Use `VARCHAR` + a named `CHECK`, **not** PostgreSQL's `ENUM` type.

```sql
status VARCHAR(12) NOT NULL DEFAULT 'draft',
CONSTRAINT ck_trip_status CHECK (status IN
    ('draft','validated','blocked','locked','completed','cancelled'))
```

Reason: adding a value to a real `ENUM` needs `ALTER TYPE` and is a pain to reverse;
changing a `CHECK` is a normal `ALTER TABLE`. We will be adding values as the project
grows.

---

## 5. NULL policy

Default to `NOT NULL`. Make a column nullable only when "not yet known" or "does not
apply" is a genuine state, and leave a `--` comment saying which.

```sql
last_entry_at TIME,   -- NULL means no separate cut-off; use closes_at
```

---

## 6. ON DELETE behaviour

| Relationship | Rule | Why |
|---|---|---|
| Weak entity → its owner | `ON DELETE CASCADE` | an opening rule has no life without its place |
| Anything → reference data | `ON DELETE RESTRICT` | don't let someone delete a `place` that trips point at |
| Optional link | `ON DELETE SET NULL` | e.g. "who verified this" — the fact survives the user |

Every foreign key states its `ON DELETE` explicitly. No defaults left implicit.

---

## 7. Column order inside a table

1. Primary key column(s)
2. Foreign key columns
3. Data columns
4. Timestamps (`created_at`, `updated_at`)
5. Table-level constraints (`CONSTRAINT ...`) last

Consistent order makes the two halves of the schema read as one file.

---

## 8. SQL formatting

- Keywords `UPPERCASE`, identifiers `lowercase`
- One column per line
- Commas at the end of the line, not the start
- Indent constraint definitions to line up with columns
- `--` comment above anything that isn't obvious, especially every `CHECK` that encodes
  a real-world rule

```sql
CREATE TABLE opening_rule (
    place_id        BIGINT      NOT NULL,
    rule_no         SMALLINT    NOT NULL,
    day_of_week     SMALLINT    NOT NULL,
    opens_at        TIME        NOT NULL,
    closes_at       TIME        NOT NULL,
    -- ticket counters usually shut before the gate does; NULL = no separate cut-off
    last_entry_at   TIME,
    CONSTRAINT pk_opening_rule       PRIMARY KEY (place_id, rule_no),
    CONSTRAINT fk_opening_rule_place FOREIGN KEY (place_id)
                                     REFERENCES place (place_id) ON DELETE CASCADE,
    CONSTRAINT ck_opening_rule_dow   CHECK (day_of_week BETWEEN 0 AND 6),
    CONSTRAINT ck_opening_rule_hours CHECK (closes_at > opens_at),
    CONSTRAINT ck_opening_rule_entry CHECK (last_entry_at IS NULL
                                            OR last_entry_at <= closes_at)
);
```

---

## 9. File conventions

Every `.sql` file starts with a header block:

```sql
-- =====================================================================
--  Sanchari · <file name>
--  Purpose : <one line>
--  Author  : <name>
--  Runs after : <which file must have run first>
-- =====================================================================
```

Files are **not** individually re-runnable. `reset.sql` drops everything, and
`run_all.sql` recreates it in order. If you need to re-test, reset first.

---

## 10. Environment

| Setting | Value |
|---|---|
| PostgreSQL | **17** (both machines — major version must match) |
| Extensions | `vector`, `btree_gist` |
| Database name | `sanchari` |
| Local dev password | `sanchari_dev` (local only; the app reads `.env`, which is gitignored) |
| Schema | `public` (we are not using custom schemas) |

---

## 11. Changing this file

Any change to a naming rule, type choice or `ON DELETE` behaviour after work has
started must be agreed by both members before it is committed, because it may change
the other person's foreign keys. Raise it in chat first, then update this file in its
own commit so the change is visible in history.
