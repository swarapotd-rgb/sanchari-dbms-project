# Sanchari — the MongoDB side

## Why reviews are split across two databases

A review has two kinds of information:

| Part | Example | Stored in | Why there |
|---|---|---|---|
| **Numbers** | rating 4, visited 22 Aug, crowd level 3, stayed 45 min | PostgreSQL `review_summary` | the app **counts, averages and joins** these — `place.avg_rating`, "which places are busy in December" |
| **Words and extras** | title, the written review, aspect ratings, tags, a tip, photos | MongoDB `reviews` | the app mostly **displays** these, and their shape **differs from review to review** |

The shape really does differ, and that is the reason for MongoDB:

- **Aspect ratings depend on the kind of place.** A museum is rated on `exhibits` and
  `information`, a waterfall on `trail_condition` and `safety`, a safari on `sightings`.
  In SQL that would need either many mostly-empty columns or an extra table. Here each
  document simply has the aspects that make sense for it.
- **Some fields exist only sometimes.** 47 of the 154 reviews have photos, about half have
  a tip, and only the 54 reviews written after a planned trip have a `trip` section.
- **Long free text** is searched with a text index.

**The link between the two:** `review_summary.mongo_doc_id` (PostgreSQL) holds the `_id` of
the review's document (MongoDB). The app reads a review's numbers from SQL, then fetches
its text with `db.reviews.findOne({ _id: ObjectId(mongo_doc_id) })`.

## One document

```js
{
  _id: ObjectId('6a8b514053616e6368000001'),
  review_id: 1, place_id: 1, user_id: 4,           // the same review in PostgreSQL
  place:  { name: 'Abbey Falls', type: 'waterfall',
            destination: 'Coorg / Kodagu', state: 'Karnataka' },
  author: { display_name: 'Ananya Rao' },          // no email - login data stays in SQL
  rating: 5,
  visited_on: ISODate('2026-08-22'),
  title: 'The best part of the trip',
  body: 'Abbey Falls was the highlight of our day. The short walk down ...',
  aspects: { scenery: 5, trail_condition: 5, safety: 5, cleanliness: 5 },
  tags: ['waterfall', 'monsoon', 'crowded', 'daylight-only', 'must-see'],
  helpful_votes: 24,
  language: 'en',
  created_at: ISODate('2026-08-23T20:00:00Z'),
  photos: [ { path: 'photos/6a8b.../1.jpg', caption: 'The main fall from the viewing deck' } ],
  trip:   { trip_id: 1, title: 'Coorg coffee weekend', party_size: 2, mode: 'car' }
}
```

`place` and `author` are **copies** of a few SQL fields, kept so a review can be shown
without asking PostgreSQL. PostgreSQL stays the source of truth for them.

Photo paths are placeholders — no image files are included.

## The files

| File | What it does |
|---|---|
| `reviews.json` | the 154 documents, in MongoDB Extended JSON (`{"$oid": …}`, `{"$date": …}` keep ids and dates as real types) |
| `seed_reviews.js` | drops and rebuilds the `reviews` collection: validator → documents → indexes |
| `queries.js` | 8 demo queries (M1–M8) — see below |

Made by `db/tools/make_review_docs.py`, which also writes `db/data/review_mongo_ids.csv` —
the file `db/07e_seed_review_links.sql` uses to fill `mongo_doc_id`. Because both come from
the same run, the ids always match.

## How the 154 documents were made

Nobody typed them. `make_review_docs.py` takes each review's real data from PostgreSQL —
place, type, rating, visit date, crowd level, minutes spent, and the trip it came from —
and builds the text from sentence templates that fit that data:

- a 5-star review praises the place; a 2-star one names what was wrong;
- the crowd sentence follows `crowd_level` (1 = "hardly anyone else was there",
  5 = "expect queues");
- "felt a little rushed" appears only when the minutes spent were below the place's
  typical visit time;
- waterfalls and lakes visited June–September mention the monsoon;
- reviews from a planned trip say how the party travelled ("We drove in as a couple as
  part of our 'Coorg coffee weekend' trip").

Choices are made with a hash of the review's key, not at random, so the same files come
out every time.

Each `_id` is a valid ObjectId built from the data:
`created_at` as Unix seconds (4 bytes) + `Sanch` in ASCII (5 bytes) + `review_id` (3 bytes).
So `ObjectId(...).getTimestamp()` returns when the review was written.

## The validator (MongoDB's version of NOT NULL and CHECK)

MongoDB accepts any document by default. `seed_reviews.js` adds a `$jsonSchema` validator,
so a document is **refused** unless:

- the 12 main fields are present (`place_id`, `rating`, `title`, `body`, `aspects` …);
- `rating` is a number from 1 to 5;
- `place.type` is one of our 12 place types, and `trip.mode` one of our 5 modes;
- every aspect value — whatever its name — is a whole number from 1 to 5;
- `title` is 3–80 characters, `body` at least 20, tags are unique.

## The indexes

| Index | For |
|---|---|
| `ix_reviews_place_newest` (place_id, created_at ↓) | a place's page: its newest reviews |
| `ix_reviews_user` (user_id) | a user's own reviews |
| `ux_reviews_visit` (place_id, user_id, visited_on), **unique** | one review per person per place per visit — the same rule as `uq_review_summary_visit` in SQL |
| `ix_reviews_tags` (tags) | browse by tag; one index entry per tag (a *multikey* index) |
| `tx_reviews_text` (title, body, tip) | full-text search; a title word counts 3× |

## Run it

Create the container once:

```powershell
docker run --name sanchari-mongo -p 27017:27017 -v sanchari_mongo:/data/db -d mongo:7
```

Then, and again after every `git pull`:

```powershell
docker cp mongo/. sanchari-mongo:/mongo
docker exec sanchari-mongo mongosh sanchari --quiet /mongo/seed_reviews.js
docker exec sanchari-mongo mongosh sanchari --quiet /mongo/queries.js
```

`seed_reviews.js` must print:

```
inserted 154 review documents
documents: 154  (expected 154)
indexes:   6  (expected 6, counting _id)
```

To look around by hand: `docker exec -it sanchari-mongo mongosh sanchari`
(then e.g. `db.reviews.findOne()`, and `exit` to leave).

## The demo queries (`queries.js`)

| # | What it shows |
|---|---|
| M1 | fetch one review by the `_id` stored in PostgreSQL, and read the time from the ObjectId |
| M2 | a place's newest reviews — filter, sort, projection |
| M3 | full-text search for "slippery steps", ranked by relevance |
| M4 | average of every aspect per place type — an aggregation pipeline that works even though each type has different aspect names (`$objectToArray`) |
| M5 | most common tags — `$unwind` an array, then `$group` |
| M6 | optional fields — reviews that have photos (`$exists`) |
| M7 | an atomic update — "mark helpful" with `$inc`, then undone |
| M8 | the validator refusing a review rated 7 out of 5 |

None of them leaves the data changed.

## When the reviews change

If `07d_seed_reviews.sql` changes, regenerate both sides together:

```powershell
docker exec sanchari-db psql -U postgres -d sanchari -f /db/tools/export_reviews.sql
docker cp sanchari-db:/tmp/reviews_export.csv db/tools/reviews_export.csv
python db/tools/make_review_docs.py
```

Then rebuild PostgreSQL (`reset` → `run_all`) and re-run `seed_reviews.js`.
