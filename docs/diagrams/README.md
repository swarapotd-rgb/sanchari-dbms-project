# Sanchari — design diagrams

| File | What it is |
|---|---|
| `er_diagram.png` / `.svg` | ER diagram in Chen notation — 16 entities, 20 relationships |
| `relational_schema.png` / `.svg` | Relational schema in crow's-foot notation — 19 tables, 24 foreign keys |
| `build_diagrams.py` | The script that draws both |

Open the **SVG** to zoom in without blur. Use the **PNG** for the lab record or slides.

## Why they are generated, not hand-drawn

A hand-drawn diagram goes out of date the moment someone adds a column. So:

- The **relational schema** is read straight out of PostgreSQL. It cannot disagree with
  the SQL.
- The **ER diagram** is written out in `build_diagrams.py`, because relationship names,
  derived attributes and composite attributes are design ideas that the database does
  not store. But before drawing, the script checks it against the database:
  - every column of every table is shown;
  - each of the 24 foreign keys belongs to exactly one relationship;
  - every thick line (total participation) sits on a `NOT NULL` foreign key, and every
    thin line on a nullable one;
  - every identifying relationship (double diamond) points at a weak entity whose
    primary key contains the owner's key.

  If any check fails, it prints what is wrong and draws nothing.

## How the ER diagram maps to the tables

| ER element | Becomes in SQL |
|---|---|
| Strong entity | Its own table with its own key (`place`, `trip`, …) |
| Weak entity (double rectangle) | Table whose PK = owner's key + partial key (`opening_rule`, `trip_day`, `itinerary_stop`, `violation`, `closure_window`) |
| `PLACE_EMBEDDING` (1:1 weak) | Table whose PK *is* the owner's key — `place_embedding.place_id` |
| 1:N relationship | Foreign key on the N side |
| 1:1 relationship (`HAS_PROFILE`) | Foreign key + `UNIQUE` (`traveller_profile.user_id`) |
| M:N relationship (`PREFERS`, `TAGGED_AS`) | Bridge table (`traveller_interest`, `place_category`) |
| Ternary relationship (`CONNECTED_BY`) | Bridge table with three foreign keys (`travel_leg`) |
| Relationship attribute (`weight`, `relevance`, `distance_km`, …) | Column on the bridge table |
| Composite attribute (`coordinates`, `entry_fee`, `centroid`, `active_window`) | One column per child |
| Derived attribute, stored (`avg_rating`, `review_count`, `feasibility_score`, counts) | Column kept up to date |
| Derived attribute marked `*` (`duration_days`, `allotted_minutes`, …) | No column — calculated when read (e.g. by `v_day_schedule`) |
| Attribute marked `†` | Column added later by the ALTER demo files (`05a`, `05b`) |

## Regenerate after a schema change

Needs Python 3.8+ and Graphviz (https://graphviz.org/download/). Build the schema
first (`reset.sql`, then `run_all.sql`), then from the repo root:

```bash
# Docker
PSQL="docker exec -i sanchari-db psql -U postgres -d sanchari" python docs/diagrams/build_diagrams.py
```
```powershell
# Windows PowerShell
$env:PSQL="docker exec -i sanchari-db psql -U postgres -d sanchari"; python docs/diagrams/build_diagrams.py
```

If you add a table or column, add it to `ER_ENTITIES` / `ER_RELATIONSHIPS` in the
script too. The check will tell you exactly what is missing until you do.
