# Sanchari

**A travel planner for South India that checks whether your plan can actually be done.**

DBMS Experiential Learning, Level 3 project, 5th semester, PES University.
Instructor: Dr. Nagasundari S

---

## The problem

Travel apps tell you *where* to go, but not whether your day plan works. You can easily
plan to arrive at a museum on the one weekday it is closed, after its last entry, or with
40 minutes allowed for a 90-minute drive.

Sanchari checks every stop of a trip against real opening hours, closures, travel times,
daylight and budget, and tells you exactly which stop breaks the plan and why.

## Stack, and why each database

| Layer | Used for | Why |
|---|---|---|
| **PostgreSQL 17** | places, users, trips, the feasibility engine | the checks join many tables and need constraints and transactions |
| **pgvector** | "places like this" | finds places by meaning of their description, not by tag |
| **MongoDB** | the written part of reviews | review text, tags and aspect ratings differ in shape from one review to the next |
| **Next.js** | the web app | course requirement; server-side code talks to both databases |

## What is in the database

- **19 tables, 24 foreign keys, 22 indexes**, including a GiST range index for closures
  and an HNSW index for vector search
- **358 real places** from OpenStreetMap across **49 destinations** in Karnataka, Kerala,
  Tamil Nadu, Puducherry, Andhra Pradesh, Telangana and Goa
- **4 views, 2 functions, 1 stored procedure, 2 triggers**
- **154 reviews**: the numbers in PostgreSQL, the text in MongoDB, linked by `mongo_doc_id`

### The feasibility engine

`CALL p_check_trip(trip_id)` runs 8 rules on every stop and saves the result in one
transaction:

| Rule | Checks | Type |
|---|---|---|
| R01 | open on that weekday | blocking |
| R02 | arrival within entry hours | blocking |
| R03 | no special closure (e.g. monsoon) | blocking |
| R04 | enough travel time from the previous stop | blocking |
| R05 | enough time spent at the place | warning |
| R06 | daylight-only places visited in daylight | blocking |
| R07 | day's travel within the traveller's limit | warning |
| R08 | trip within budget | warning |

Score = 100, minus 25 per blocking problem, minus 10 per warning.

## The web app

Sign in, pick a state on the map of South India, search its places, open a place to see
its opening hours, reviews and similar places, add it to a trip, then click
**Check feasibility**.

| Role | Can do |
|---|---|
| Traveller | plan trips, add stops, run checks, write reviews |
| Curator | edit place details, see the overview |
| Admin | everything above, plus suspend or reactivate accounts |

Details of each screen are in [`frontend/README.md`](frontend/README.md).

## Repository layout

```
db/          SQL: tables, indexes, views, seed data, feasibility engine, triggers,
             queries (10_queries.sql), and run_all / reset / verify scripts
mongo/       review documents, validator, indexes, demo queries
frontend/    the Next.js app
docs/        ER diagram, relational schema, feasibility rules, work notes
```

## Setup

You need **Docker** and **Node.js 20+**. The commands are for Windows PowerShell.

**1. PostgreSQL** (with pgvector), then build the database:

```powershell
docker run --name sanchari-db -e POSTGRES_PASSWORD=sanchari_dev -e POSTGRES_DB=sanchari -p 5432:5432 -v sanchari_pg17:/var/lib/postgresql/data -d pgvector/pgvector:pg17-bookworm

docker cp db/. sanchari-db:/db
docker exec sanchari-db psql -U postgres -d sanchari -f /db/reset.sql
docker exec sanchari-db psql -U postgres -d sanchari -f /db/run_all.sql
docker exec sanchari-db psql -U postgres -d sanchari -f /db/verify.sql
```

`verify.sql` should report **19 tables, 24 foreign keys, 22 indexes, 4 views,
2 functions, 1 procedure, 2 triggers**.

**2. MongoDB** (optional; without it the app shows ratings but not review text):

```powershell
docker run --name sanchari-mongo -p 27017:27017 -v sanchari_mongo:/data/db -d mongo:7
docker cp mongo/. sanchari-mongo:/mongo
docker exec sanchari-mongo mongosh sanchari --quiet /mongo/seed_reviews.js
```

It should end with **documents: 154**.

**3. The web app:**

```powershell
cd frontend
npm install
copy .env.example .env.local
npm run dev
```

In `.env.local`, set `SESSION_SECRET` to any long random text. Then open
http://localhost:3000.

If PowerShell says *running scripts is disabled*, use `npm.cmd` instead of `npm`.

**4. Example queries** (JOIN, GROUP BY, HAVING, subqueries, UPDATE and DELETE inside
rolled-back transactions):

```powershell
docker exec sanchari-db psql -U postgres -d sanchari -f /db/10_queries.sql
```

## Demo accounts

Every password is `Sanchari@2026`. All accounts are invented and use `@example.com`.

| Role | Email |
|---|---|
| Traveller | ananya.rao@example.com |
| Curator | rahul.hegde@example.com |
| Admin | admin@example.com |

## Security

- Passwords are stored only as bcrypt hashes and checked inside PostgreSQL with `crypt()`.
- Database settings come from `.env.local`, which git ignores. Nothing secret is in the code.
- Every query passes user input as parameters (`$1, $2`), never pasted into SQL.
- Validation is enforced by the database itself: CHECK, UNIQUE and FOREIGN KEY
  constraints and a trigger. The app shows the rule's name when one refuses a change.

## Team

| Member | Main work |
|---|---|
| Swara Potdar | schema design, seed data, feasibility engine, triggers, MongoDB |
| Shreya Shahapur | trips and checks tables, queries file, Next.js frontend |

Conventions for SQL naming and types are in [`CONVENTIONS.md`](CONVENTIONS.md).
