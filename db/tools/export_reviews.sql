-- =====================================================================
--  Sanchari · db/tools/export_reviews.sql
--  Purpose    : Export every review_summary row WITH its context (place,
--               author, and the completed trip it came from, if any) to
--               a CSV that make_review_docs.py turns into MongoDB
--               documents.
--  Author     : Swara
--
--  Only needed when the reviews change. Run inside the container, then
--  copy the CSV out next to this file:
--      docker exec sanchari-db psql -U postgres -d sanchari -f /db/tools/export_reviews.sql
--      docker cp sanchari-db:/tmp/reviews_export.csv db/tools/reviews_export.csv
-- =====================================================================

\copy (SELECT r.review_id, r.place_id, p.name AS place, p.place_type, p.requires_daylight, p.fee_indian, p.typical_visit_minutes, d.name AS destination, d.state, u.user_id, u.email, u.display_name, r.rating, r.visited_on, r.actual_duration_min, r.crowd_level, r.created_at, t.trip_id, t.title AS trip_title, t.party_size, m.mode_name FROM review_summary r JOIN place p ON p.place_id = r.place_id JOIN destination d ON d.destination_id = p.destination_id JOIN user_account u ON u.user_id = r.user_id LEFT JOIN LATERAL (SELECT t.* FROM trip t JOIN itinerary_stop s ON s.trip_id = t.trip_id WHERE t.owner_user_id = r.user_id AND t.status = 'completed' AND s.place_id = r.place_id AND s.planned_arrival::DATE = r.visited_on LIMIT 1) t ON TRUE LEFT JOIN transport_mode m ON m.mode_id = t.primary_mode_id ORDER BY r.review_id) TO '/tmp/reviews_export.csv' WITH (FORMAT csv, HEADER true)
