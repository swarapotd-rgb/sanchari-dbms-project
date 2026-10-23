// =====================================================================
//  Sanchari · mongo/queries.js
//  Purpose    : Show what the MongoDB side is for - the queries the app
//               runs on review documents, plus the validator at work.
//  Author     : Swara
//  Runs after : seed_reviews.js
//
//  Run (Docker):
//      docker exec sanchari-mongo mongosh sanchari --quiet /mongo/queries.js
//
//  Nothing here changes the data permanently: M7 adds a vote and takes it
//  back, and M8's bad document is refused.
// =====================================================================

function title(t) { print('\n=== ' + t + ' ==='); }


// ---------------------------------------------------------------------
//  M1. Fetch one review by its _id - exactly what the app does with
//      review_summary.mongo_doc_id from PostgreSQL.
//  Shows: find by _id; the _id also carries the time it was written.
// ---------------------------------------------------------------------
title('M1. One review, looked up by the id stored in PostgreSQL');
const id = ObjectId('6a8b514053616e6368000001');   // mongo_doc_id of review_id 1
const one = db.reviews.findOne({ _id: id },
                               { _id: 0, 'place.name': 1, rating: 1, title: 1, body: 1 });
printjson(one);
print('written at (read from the ObjectId itself): ' + id.getTimestamp().toISOString());


// ---------------------------------------------------------------------
//  M2. A place's page: its newest reviews.
//  Shows: filter + sort + limit + projection; uses ix_reviews_place_newest.
// ---------------------------------------------------------------------
title('M2. Newest reviews of Palolem Beach');
db.reviews.find({ 'place.name': 'Palolem Beach' },
                { _id: 0, 'author.display_name': 1, rating: 1, title: 1, created_at: 1 })
          .sort({ created_at: -1 })
          .forEach(printjson);


// ---------------------------------------------------------------------
//  M3. Full-text search: reviews that mention slippery steps.
//  Shows: the text index - stemming (searching "steps" also matches
//  "step"), common words like "the" ignored, results ranked by a
//  relevance score, with a word in the title counting 3x.
// ---------------------------------------------------------------------
title('M3. Text search: "slippery steps"');
db.reviews.find({ $text: { $search: 'slippery steps' } },
                { _id: 0, 'place.name': 1, title: 1, score: { $meta: 'textScore' } })
          .sort({ score: { $meta: 'textScore' } })
          .limit(5)
          .forEach(printjson);


// ---------------------------------------------------------------------
//  M4. Average of every aspect, per kind of place.
//  Shows: an aggregation pipeline. aspects has DIFFERENT keys per type,
//  so $objectToArray turns {scenery: 5, safety: 4} into a list of
//  {k, v} pairs that can be unwound and grouped - no fixed columns needed.
// ---------------------------------------------------------------------
title('M4. Average aspect scores per place type');
db.reviews.aggregate([
  { $project: { type: '$place.type', aspect: { $objectToArray: '$aspects' } } },
  { $unwind: '$aspect' },
  { $group: { _id: { type: '$type', aspect: '$aspect.k' },
              avg: { $avg: '$aspect.v' }, reviews: { $sum: 1 } } },
  { $group: { _id: '$_id.type',
              aspects: { $push: { k: '$_id.aspect', v: { $round: ['$avg', 2] } } },
              reviews: { $first: '$reviews' } } },
  { $project: { _id: 0, type: '$_id', reviews: 1, aspects: { $arrayToObject: '$aspects' } } },
  { $sort: { reviews: -1 } }
]).forEach(printjson);


// ---------------------------------------------------------------------
//  M5. Most used tags.
//  Shows: $unwind on an array field, then $group and $sort.
// ---------------------------------------------------------------------
title('M5. Most common tags');
db.reviews.aggregate([
  { $unwind: '$tags' },
  { $group: { _id: '$tags', reviews: { $sum: 1 } } },
  { $sort: { reviews: -1, _id: 1 } },
  { $limit: 8 }
]).forEach(printjson);


// ---------------------------------------------------------------------
//  M6. Optional fields: the most helpful reviews that include photos.
//  Shows: $exists - only some documents have photos at all.
// ---------------------------------------------------------------------
title('M6. Most helpful reviews with photos');
print('documents with photos: ' + db.reviews.countDocuments({ photos: { $exists: true } })
      + ' of ' + db.reviews.countDocuments());
db.reviews.find({ photos: { $exists: true } },
                { _id: 0, 'place.name': 1, title: 1, helpful_votes: 1, photos: 1 })
          .sort({ helpful_votes: -1 })
          .limit(3)
          .forEach(printjson);


// ---------------------------------------------------------------------
//  M7. Someone clicks "helpful".
//  Shows: an atomic update with $inc - no read-then-write race.
//  The vote is taken back afterwards so the data stays unchanged.
// ---------------------------------------------------------------------
title('M7. Mark a review helpful, then undo it');
const before = db.reviews.findOne({ _id: id }).helpful_votes;
db.reviews.updateOne({ _id: id }, { $inc: { helpful_votes: 1 } });
const after = db.reviews.findOne({ _id: id }).helpful_votes;
db.reviews.updateOne({ _id: id }, { $inc: { helpful_votes: -1 } });
print(`helpful_votes: ${before} -> ${after} -> back to ${db.reviews.findOne({ _id: id }).helpful_votes}`);


// ---------------------------------------------------------------------
//  M8. The validator at work: a review rated 7 out of 5.
//  Shows: MongoDB's $jsonSchema refusing a bad document, like a CHECK.
// ---------------------------------------------------------------------
title('M8. Insert a review rated 7 (must be refused)');
try {
  db.reviews.insertOne({
    review_id: 999, place_id: 1, user_id: 4,
    place: { name: 'Abbey Falls', type: 'waterfall', destination: 'Coorg / Kodagu', state: 'Karnataka' },
    author: { display_name: 'Test' },
    rating: 7,
    visited_on: new Date('2026-10-01'),
    title: 'Too good', body: 'This rating is outside the allowed range.',
    aspects: { scenery: 5 }, tags: [], created_at: new Date()
  });
  print('NOT refused - the validator is missing!');
} catch (e) {
  print('refused, as expected: ' + e.errInfo.details.schemaRulesNotSatisfied[0].propertiesNotSatisfied
                                    .map(p => p.propertyName + ' ' + p.details[0].reason).join('; '));
}
print('documents: ' + db.reviews.countDocuments() + '  (still 154)');
