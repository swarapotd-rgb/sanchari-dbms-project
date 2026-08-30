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

- **16 entities · 20 relationships · 19 tables · 24 foreign keys · 130 columns**
- Eight feasibility checks (R01–R08), each traceable to the tables it reads
- Full design documentation in `docs/`

---

## Repository layout

```
db/     SQL — extensions, tables, indexes, views, run/reset/verify scripts
docs/   ER diagram, relational schema, design explanation, work split
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
