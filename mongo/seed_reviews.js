// =====================================================================
//  Sanchari · mongo/seed_reviews.js
//  Purpose    : Build the MongoDB half of the reviews - the `reviews`
//               collection with a validator, 154 documents and indexes.
//  Author     : Swara
//  Runs after : nothing in MongoDB; the matching SQL side is
//               db/07e_seed_review_links.sql
//
//  Run (Docker):
//      docker cp mongo/. sanchari-mongo:/mongo
//      docker exec sanchari-mongo mongosh sanchari --quiet /mongo/seed_reviews.js
//
//  Safe to run again: it drops and rebuilds the collection each time.
//
//  HOW THE TWO DATABASES SHARE A REVIEW
//    PostgreSQL review_summary   rating, visit date, crowd level, time spent
//                                (what the app counts, averages and joins)
//    MongoDB    reviews          title, written text, aspect ratings, tags,
//                                tip, photos (what the app displays)
//  review_summary.mongo_doc_id holds the _id of the document below, so
//  the app reads a review's numbers from SQL and its text from here.
// =====================================================================

const REVIEWS_FILE = (typeof reviewsFile !== 'undefined') ? reviewsFile : '/mongo/reviews.json';
const fs = require('fs');

// ---------------------------------------------------------------------
//  1. Start clean
// ---------------------------------------------------------------------
db.reviews.drop();


// ---------------------------------------------------------------------
//  2. The collection, with a validator
// ---------------------------------------------------------------------
//  MongoDB accepts any shape by default. The $jsonSchema validator is
//  MongoDB's version of NOT NULL and CHECK: every document must have
//  these fields with these types and ranges, or the insert is refused.
//
//  It still allows what SQL makes awkward:
//    aspects - different keys for different kinds of place (a museum is
//              rated on exhibits, a waterfall on trail_condition). Only
//              the VALUES are checked: whole numbers 1-5.
//    tip, photos, trip - optional; present on some documents only.
db.createCollection('reviews', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: ['review_id', 'place_id', 'user_id', 'place', 'author', 'rating',
                 'visited_on', 'title', 'body', 'aspects', 'tags', 'created_at'],
      properties: {
        review_id:  { bsonType: ['int', 'long'] },
        place_id:   { bsonType: ['int', 'long'] },
        user_id:    { bsonType: ['int', 'long'] },
        place: {
          bsonType: 'object',
          required: ['name', 'type', 'destination', 'state'],
          properties: {
            type: { enum: ['fort', 'beach', 'temple', 'trail', 'wildlife', 'waterfall',
                           'museum', 'market', 'viewpoint', 'lake', 'heritage', 'garden'] }
          }
        },
        author: {
          bsonType: 'object',
          required: ['display_name'],
          properties: { display_name: { bsonType: 'string' } }
        },
        rating:     { bsonType: ['double', 'int'], minimum: 1, maximum: 5 },
        visited_on: { bsonType: 'date' },
        title:      { bsonType: 'string', minLength: 3, maxLength: 80 },
        body:       { bsonType: 'string', minLength: 20, maxLength: 5000 },
        aspects: {
          bsonType: 'object',
          minProperties: 1,
          additionalProperties: { bsonType: 'int', minimum: 1, maximum: 5 }
        },
        tags: {
          bsonType: 'array',
          uniqueItems: true,
          items: { bsonType: 'string' }
        },
        tip:        { bsonType: 'string', maxLength: 300 },
        photos: {
          bsonType: 'array',
          maxItems: 10,
          items: {
            bsonType: 'object',
            required: ['path', 'caption'],
            properties: { path: { bsonType: 'string' }, caption: { bsonType: 'string' } }
          }
        },
        trip: {
          bsonType: 'object',
          required: ['trip_id', 'title', 'party_size', 'mode'],
          properties: { mode: { enum: ['car', 'bike', 'bus', 'train', 'walk'] } }
        },
        helpful_votes: { bsonType: 'int', minimum: 0 },
        language:      { bsonType: 'string' },
        created_at:    { bsonType: 'date' }
      }
    }
  },
  validationLevel: 'strict',
  validationAction: 'error'
});


// ---------------------------------------------------------------------
//  3. The documents
// ---------------------------------------------------------------------
//  reviews.json is Extended JSON: {"$oid": ...} and {"$date": ...} keep
//  ObjectIds and dates as real BSON types instead of plain strings.
const docs = EJSON.parse(fs.readFileSync(REVIEWS_FILE, 'utf8'));
const result = db.reviews.insertMany(docs);
print(`inserted ${Object.keys(result.insertedIds).length} review documents`);


// ---------------------------------------------------------------------
//  4. Indexes
// ---------------------------------------------------------------------
//  The same idea as the SQL idx_ indexes: each one exists for a query
//  the app runs.

// a place's page: its reviews, newest first
db.reviews.createIndex({ place_id: 1, created_at: -1 }, { name: 'ix_reviews_place_newest' });

// "my reviews" on a user's profile
db.reviews.createIndex({ user_id: 1 }, { name: 'ix_reviews_user' });

// one review per person per place per visit - the same rule as
// uq_review_summary_visit in PostgreSQL
db.reviews.createIndex({ place_id: 1, user_id: 1, visited_on: 1 },
                       { name: 'ux_reviews_visit', unique: true });

// browse by tag ("monsoon", "quiet" ...); tags is an array, so this is a
// multikey index - one index entry per tag
db.reviews.createIndex({ tags: 1 }, { name: 'ix_reviews_tags' });

// full-text search over what people wrote; a word in the title counts
// three times as much as one in the body
db.reviews.createIndex({ title: 'text', body: 'text', tip: 'text' },
                       { name: 'tx_reviews_text',
                         weights: { title: 3, body: 1, tip: 1 },
                         default_language: 'english' });


// ---------------------------------------------------------------------
//  5. Check
// ---------------------------------------------------------------------
print(`documents: ${db.reviews.countDocuments()}  (expected 154)`);
print(`indexes:   ${db.reviews.getIndexes().length}  (expected 6, counting _id)`);
