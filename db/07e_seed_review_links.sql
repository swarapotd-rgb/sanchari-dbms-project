-- =====================================================================
--  Sanchari · 07e_seed_review_links.sql
--  Purpose    : Link each review_summary row to its MongoDB document by
--               filling in mongo_doc_id.
--  Author     : Swara
--  Runs after : 07d_seed_reviews.sql
--
--  A review is split across the two databases:
--    PostgreSQL review_summary  rating, visit date, crowd level, time
--                               spent - what the app counts and averages
--    MongoDB    reviews         title, written text, aspect ratings,
--                               tags, tip, photos - what the app displays
--  mongo_doc_id is the bridge: the 24-character hex _id of the document.
--
--  review_mongo_ids.csv   email, destination, place, visited_on,
--                         mongo_doc_id
--  It is written by db/tools/make_review_docs.py together with
--  mongo/reviews.json, so both sides always carry the same ids.
--  A review is found by its natural key - who, which place, which visit
--  date - the same three columns as uq_review_summary_visit.
--
--  This file only stores the ids. The documents themselves are loaded
--  into MongoDB by mongo/seed_reviews.js.
-- =====================================================================

CREATE TEMP TABLE stg_review_link (
    email         TEXT,
    destination   TEXT,
    place         TEXT,
    visited_on    DATE,
    mongo_doc_id  TEXT
);

\copy stg_review_link FROM '/db/data/review_mongo_ids.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- Every line must match exactly one review, every id must look like an
-- ObjectId, and every review must get an id - otherwise stop.
DO $$
DECLARE
    bad TEXT;
    n   INT;
BEGIN
    SELECT string_agg(s.email || ' / ' || s.place || ' / ' || s.visited_on, '; ') INTO bad
      FROM stg_review_link s
      LEFT JOIN user_account   u  ON u.email = s.email
      LEFT JOIN destination    d  ON d.name  = s.destination
      LEFT JOIN place          p  ON p.destination_id = d.destination_id AND p.name = s.place
      LEFT JOIN review_summary r  ON r.user_id = u.user_id AND r.place_id = p.place_id
                                 AND r.visited_on = s.visited_on
     WHERE r.review_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'review_mongo_ids.csv names reviews that do not exist: %', bad;
    END IF;

    SELECT string_agg(mongo_doc_id, ', ') INTO bad
      FROM stg_review_link
     WHERE mongo_doc_id !~ '^[0-9a-f]{24}$';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'not valid ObjectIds: %', bad;
    END IF;

    SELECT count(*) INTO n FROM review_summary;
    IF n <> (SELECT count(DISTINCT mongo_doc_id) FROM stg_review_link) THEN
        RAISE EXCEPTION 'review_summary has % reviews but review_mongo_ids.csv has % distinct ids - re-run db/tools/make_review_docs.py',
                        n, (SELECT count(DISTINCT mongo_doc_id) FROM stg_review_link);
    END IF;
END $$;

-- UPDATE ... FROM: the staging table is joined in to find each review
UPDATE review_summary r
SET    mongo_doc_id = s.mongo_doc_id
FROM   stg_review_link s
JOIN   user_account    u ON u.email = s.email
JOIN   destination     d ON d.name  = s.destination
JOIN   place           p ON p.destination_id = d.destination_id AND p.name = s.place
WHERE  r.user_id    = u.user_id
  AND  r.place_id   = p.place_id
  AND  r.visited_on = s.visited_on;

DROP TABLE stg_review_link;

-- =====================================================================
--  Sanity check:
--      SELECT count(*) FILTER (WHERE mongo_doc_id IS NULL) AS unlinked,
--             count(DISTINCT mongo_doc_id)                 AS distinct_ids
--      FROM   review_summary;                     -- 0 and 154
--
--  Then, in MongoDB, the same review's text:
--      db.reviews.findOne({ _id: ObjectId('<mongo_doc_id>') })
-- =====================================================================
