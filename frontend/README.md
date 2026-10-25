# Sanchari web app (Next.js)

After sign-in the user sees a map of the seven southern states. Click one to search its
places, open a place, add it to a trip, and press **Check feasibility** to let the
database test the plan stop by stop.

**In one sentence:** pages read with SQL, `app/actions.ts` writes with SQL, and
`lib/db.ts` connects to both databases.

## Files

```
lib/db.ts              connections: PostgreSQL pool, transactions, MongoDB
lib/auth.ts            login session (signed cookie) and role checks
lib/helpers.ts         formatting, database-error messages, map projection
lib/southMap.ts        the state outlines (data only)

app/actions.ts         EVERY change to the data: INSERT, UPDATE, DELETE, CALL
app/components.tsx     browser pieces: nav links, map, login form, button, messages
app/layout.tsx         top bar on every page
app/globals.css        the brown and beige theme

app/login/page.tsx            sign in
app/explore/page.tsx          the map
app/explore/[state]/page.tsx  search one state
app/places/[id]/page.tsx      one place
app/trips/page.tsx            trip list and new trip
app/trips/[id]/page.tsx       one trip and the feasibility check
app/admin/page.tsx            overview, and user accounts (Admin)
```

## Each screen and the database feature it shows

| Screen | Who | Database feature |
|---|---|---|
| Sign in | everyone | password checked inside PostgreSQL with `crypt()` (bcrypt) |
| Map | everyone | `JOIN`, `GROUP BY`, `COUNT`, subquery in `FROM` |
| State search | everyone | **full-text search** (`to_tsvector`, `websearch_to_tsquery`, `ts_rank`), filters |
| Place | everyone | **view** `v_place_weekly_hours`; **function** `f_place_open_on`; **vector search** (pgvector `<=>`); reviews: numbers from PostgreSQL, text from **MongoDB** |
| Add to trip | Traveller | `INSERT` into `itinerary_stop` |
| Write a review | Traveller | `INSERT`; the **trigger** updates the place rating; text saved in MongoDB, linked by `mongo_doc_id` |
| Edit place | Curator, Admin | `UPDATE`; CHECK constraints refuse bad values |
| New trip | Traveller | trip + its days inserted in **one transaction** |
| Trip | owner, staff | **procedure** `CALL p_check_trip`; **view** `v_day_schedule`; edit times (`UPDATE`), remove stop (`DELETE`), delete trip (`ON DELETE CASCADE`) |
| Overview | Curator, Admin | **view** `v_trip_health`, `GROUP BY` rule; Admin suspends/reactivates users (`UPDATE`) |

When the database refuses something, the app shows the rule by name, e.g.
*"Leave time must be after arrival time. (database rule ck_itinerary_stop_times)"*.

## Run it

Needs Node.js 20+, the `sanchari-db` container with the database built, and optionally
`sanchari-mongo` with the reviews loaded (see the main README and `mongo/README.md`).

```powershell
cd frontend
npm install
copy .env.example .env.local     # put a long random string in SESSION_SECRET
npm run dev
```

Open http://localhost:3000. Every password is `Sanchari@2026`:

| Role | Email |
|---|---|
| Traveller | ananya.rao@example.com |
| Curator | rahul.hegde@example.com |
| Admin | admin@example.com |

Without MongoDB everything still works; reviews then show their ratings only.

## Security in short

- Credentials live in `.env.local` only (ignored by git).
- Every query uses `$1, $2…` parameters; input is never glued into SQL.
- The login cookie is signed and httpOnly; every page and action checks it again on
  the server, and checks the role.
