# Sanchari - progress log and demo script

Updated after Week 4. Everything below is committed on `main` and rebuilds from empty
with no errors.

---

## 1. What each file does (one line each)

### Setup
| File | What it does |
|---|---|
| `db/00_check_setup.sql` | Proves the environment is right - PostgreSQL 17, pgvector installed, and a 3-dimension vector smoke test that ranks waterfall / lake / fort by cosine distance. |
| `db/00_extensions.sql` | Turns on the two extensions the schema needs: `vector` for embeddings and `btree_gist` for the closure-window range index. |

### Tables (Requirement 4)
| File | What it does |
|---|---|
| `db/01a_tables_people_places.sql` | Creates Person A's 13 tables - the "world" half: users and roles, interests, destinations, places, opening hours, closures, travel legs and place embeddings. |
| `db/01b_tables_trips_checks.sql` | Creates Person B's 6 tables - the "activity" half: trips, trip days, itinerary stops, feasibility runs, violations and review summaries. |

### Indexes (Requirement 8)
| File | What it does |
|---|---|
| `db/03a_indexes_people_places.sql` | 9 indexes on Person A's tables, including a GiST range index for "is this date inside a closure?" and an HNSW vector index for semantic search. |
| `db/03b_indexes_trips_checks.sql` | 13 indexes on Person B's tables, including a partial index that covers only blocking violations. |

### Views and functions (Requirement 6)
| File | What it does |
|---|---|
| `db/04a_views_places.sql` | Two views (readable weekly hours, and a place directory with categories flattened) plus `f_place_open_on()`, the function that decides whether a place is open on a given date - the heart of rules R01, R02 and R03. |
| `db/04b_views_trips.sql` | Two views - `v_day_schedule` (each stop with the gap since the previous one, using a window function) and `v_trip_health` (each trip with its most recent feasibility result). |

### ALTER / DROP demonstration (Requirement 5)
| File | What it does |
|---|---|
| `db/05a_alter_drop_demo_a.sql` | Adds `place.short_description` permanently, then puts a throwaway table through the full ALTER and DROP range. |
| `db/05b_alter_drop_demo_b.sql` | Adds `trip.status_note` and a title check permanently, then does the same throwaway ALTER / DROP demonstration on the trips half. |

### Running and proving
| File | What it does |
|---|---|
| `db/reset.sql` | Wipes the database back to empty so the whole build can be re-run from scratch. |
| `db/run_all.sql` | Runs all nine DDL files in dependency order with one command. |
| `db/verify.sql` | The proof script - counts objects and then checks four things that must all be zero: auto-named constraints, foreign keys left on NO ACTION, type mismatches, and leftover scratch tables. |

### Documentation
| File | What it does |
|---|---|
| `CONVENTIONS.md` | The naming and typing rules both of us follow, agreed before any SQL was written. |
| `docs/ROADMAP_person_b.md` | The step-by-step brief Person B worked from. |
| `docs/TODO_person_b.md` | The follow-up corrections list after the first round of review. |
| `docs/step0-verification-swara.md` | Evidence that the environment was set up correctly. |

---

## 2. Demo script - what to type in front of the teacher

### Step 1 - start a clean container with the repo mounted

```powershell
cd C:\Users\swara\sanchari
git pull

docker rm -f sanchari-db
docker run --name sanchari-db `
  -e POSTGRES_PASSWORD=sanchari_dev `
  -e POSTGRES_DB=sanchari `
  -p 5432:5432 `
  -v sanchari_data:/var/lib/postgresql/data `
  -v ${PWD}:/repo `
  -d pgvector/pgvector:pg17-bookworm
```

Wait about ten seconds.

### Step 2 - show the environment is real

```powershell
docker exec -w /repo sanchari-db psql -U postgres -d sanchari -f db/00_check_setup.sql
```

Shows the PostgreSQL version, that pgvector is installed, and a working vector similarity
search.

### Step 3 - build the whole schema from nothing, live

```powershell
docker exec -w /repo sanchari-db psql -U postgres -d sanchari -f db/reset.sql
docker exec -w /repo sanchari-db psql -U postgres -d sanchari -f db/run_all.sql
```

This is the important one: it proves the schema is reproducible, not something that was
built by hand and cannot be rebuilt.

### Step 4 - the proof screenshot

```powershell
docker exec -w /repo sanchari-db psql -U postgres -d sanchari -f db/verify.sql
```

Expected: **19 tables, 24 foreign keys, 22 indexes, 4 views, 1 function**, and sections
2 to 5 all reporting **0 rows**.

### Step 5 - walk through the schema interactively

```powershell
docker exec -it sanchari-db psql -U postgres -d sanchari
```

Then inside psql:

```
\dt                  -- all 19 tables
\d place             -- one table in full: columns, checks, foreign keys, indexes
\d opening_rule      -- the weak entity: composite primary key (place_id, rule_no)
\d travel_leg        -- the ternary relationship: three-column primary key
\di                  -- every index
\dv                  -- the four views
\df f_place_open_on  -- the feasibility function
\q                   -- quit
```

### Step 6 - two things worth pointing at specifically

```sql
-- The GiST range index. A plain B-tree cannot answer "is this date inside
-- any closure window", because the question is containment, not equality.
\d closure_window

-- The vector column and its HNSW index, for semantic place search.
\d place_embedding
```

---

## 3. Where we are against the requirement list

| Req | Item | Status |
|---|---|---|
| 1-3 | Title, ER diagram, relational schema | Done |
| 4 | DDL for every table | Done - 19 tables |
| 5 | CREATE, ALTER and DROP demonstrated | Done - both halves |
| 8 | Indexes, including specialised ones | Done - 22 |
| 12 | Constraints enforced in the database | Done - 54 CHECK, 11 UNIQUE, 24 FK |
| 6 | DML - seed data and queries | **Next step** |
| 14 | Data dictionary matching the built schema | Pending |
| 16 | Individual contribution visible in commits | Ongoing |
