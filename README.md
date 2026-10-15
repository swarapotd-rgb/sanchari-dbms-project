# Sanchari

**A constraint-aware travel itinerary feasibility and semantic discovery system for regional tourism.**

DBMS Experiential Learning — Level 3 project, 5th semester.
Instructor: Dr. Nagasundari S

---

## What the problem is

Every travel app tells you *where* to go. None of them tells you whether the plan you
just built can actually be executed.

Plan a Coorg weekend and you can easily end up with a 5:40 pm arrival at a gate whose
ticket counter shut at 5:00, on a Monday when the place is closed anyway, after a drive
that takes ninety minutes rather than the forty you assumed. Google Maps routes you.
TripAdvisor ranks places. Nobody validates the plan.

Sanchari validates the plan. You describe what you want in plain words, it finds
candidate places by meaning rather than by tag, you assemble a day-by-day itinerary, and
the database then checks every stop against real availability data and tells you exactly
which stop breaks the plan and why.

## Why it needs a database

Answering "is this day plan executable?" means checking one stop against opening hours
for that weekday, dated closure windows, travel time from the previous stop by the chosen
transport mode, daylight, the traveller's own pace and budget — simultaneously, in order,
for every stop. That is a join across five to seven tables with interval arithmetic. It is
exactly the work a relational database exists to do, and exactly the work a listing app
never does.

---

## Stack

| Layer | Choice | Why |
|---|---|---|
| Relational | PostgreSQL 17 | everything the feasibility engine reads; interval logic, referential integrity |
| Document | MongoDB | review bodies and rich place content, where the shape genuinely varies per row |
| Vector | pgvector | semantic retrieval — "somewhere green and quiet" matches no tag |
| Frontend | Next.js | required by the course |

The line, in one sentence: if the feasibility engine reads it, it is in PostgreSQL; if
its shape varies per row, it is in MongoDB; if it is retrieved by meaning rather than by
value, it is a vector.

---

## Core design

- **16 entities · 20 relationships · 19 tables · 24 foreign keys · 135 columns**
  (133 from `CREATE TABLE`, plus `place.short_description` and `trip.status_note`
  added by the ALTER demos)
- Eight feasibility checks (R01–R08), each traceable to the tables it reads —
  run by the procedure `p_check_trip` (`db/08a`), defined in `docs/feasibility_rules.md`
- ER diagram and relational schema in `docs/diagrams/`

---

## Repository layout

```
db/              SQL — extensions, tables, indexes, views, seed data, engine,
                 triggers, run/reset/verify scripts
docs/diagrams/   ER diagram (Chen) and relational schema (crow's foot)
docs/            roadmap, work split, setup verification
```

---

## Setup

You need PostgreSQL **17** with the `vector` and `btree_gist` extensions. Both team
members must run the same major version.

The quickest route is Docker, which ships PostgreSQL and pgvector together:

```bash
docker run --name sanchari-db \
  -e POSTGRES_PASSWORD=sanchari_dev \
  -e POSTGRES_DB=sanchari \
  -p 5432:5432 \
  -v sanchari_data:/var/lib/postgresql/data \
  -d pgvector/pgvector:pg17-bookworm
```

On Windows PowerShell, put that on one line without the `\` characters.

### Verify your setup

```bash
# macOS / Linux / WSL
docker exec -i sanchari-db psql -U postgres -d sanchari < db/00_check_setup.sql

# Windows PowerShell
Get-Content db\00_check_setup.sql | docker exec -i sanchari-db psql -U postgres -d sanchari
```

It should finish with no `ERROR` lines. The similarity search near the end must rank
`waterfall`, then `lake`, then `fort` — that ordering is the proof that pgvector is
genuinely working.

### Build the schema

`run_all.sql` pulls in the other files by path, so psql must be able to see the `db/`
folder. Piping the file into the container does not work — only its own text gets
sent. Copy the folder in instead:

```bash
docker cp db/. sanchari-db:/db
docker exec sanchari-db psql -U postgres -d sanchari -f /db/reset.sql
docker exec sanchari-db psql -U postgres -d sanchari -f /db/run_all.sql
docker exec sanchari-db psql -U postgres -d sanchari -f /db/verify.sql
```

(With native psql, from the repo root: `psql -U postgres -d sanchari -f db/run_all.sql`.)
`verify.sql` must report **19 tables · 24 foreign keys · 22 indexes · 4 views ·
2 functions · 1 procedure · 2 triggers**, zero rows in its checks 2–5, and in
check 9 exactly the 8 test trips, each failing its one rule.

Re-run `docker cp` after pulling changes — the copy in the container does not update
on its own.

Full setup instructions, including non-Docker paths and troubleshooting, are in
`docs/`.

---

## Team

Two members. Responsibilities are split by file, not by line — see the work split
document in `docs/`. Branch naming: `ddl/people-places` and `ddl/trips-checks`.

---

## Conventions

Read `CONVENTIONS.md` before writing any SQL. It fixes naming, types, constraint naming
and `ON DELETE` behaviour, so that two people writing on two machines produce one
consistent schema.

---

## Security note

Database credentials are never committed. `sanchari_dev` is a local development password
only. Application configuration is read from `.env`, which is listed in `.gitignore` from
the first commit.
