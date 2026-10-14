-- =====================================================================
--  Sanchari · 06d_seed_travel_legs.sql
--  Purpose    : Build travel_leg - how far and how long between every
--               pair of places in the same destination, per mode.
--               Nothing is typed in: it is calculated from the
--               coordinates already stored in place.
--  Author     : Swara
--  Runs after : 06b_seed_places.sql
--
--  For every ordered pair (A -> B) of places in the same destination:
--    straight-line km  = haversine formula on the two coordinates
--    road km           = straight-line km x 1.3   (roads are not straight)
--    minutes           = road km / mode speed x 60, plus 5 minutes to
--                        park and get going for car, bike and bus
--    monsoon minutes   = 25% slower; NULL for walking (unmeasured)
--  Modes: car, bike and bus for every pair under 60 road-km;
--         walk only for pairs within 3 road-km.
--  Train is left out - nobody takes a train between two sights in the
--  same town; the engine falls back on avg_speed_kmph if ever needed.
--
--  Both directions are stored (A -> B and B -> A) because the primary
--  key is directional and rule R04 looks legs up by origin.
-- =====================================================================

INSERT INTO travel_leg (from_place_id, to_place_id, mode_id, distance_km,
                        typical_duration_min, monsoon_duration_min, toll_cost)
SELECT a.place_id,
       b.place_id,
       m.mode_id,
       r.road_km,
       t.minutes,
       CASE WHEN m.mode_name = 'walk' THEN NULL
            ELSE CEIL(t.minutes * 1.25)::INT
       END,
       0
FROM   place a
JOIN   place b
       ON  b.destination_id = a.destination_id
       AND b.place_id      <> a.place_id
-- haversine: great-circle distance on a sphere of radius 6371 km
CROSS JOIN LATERAL (
       SELECT ROUND((
                2 * 6371 * ASIN(SQRT(
                    POWER(SIN(RADIANS(b.latitude  - a.latitude ) / 2), 2) +
                    COS(RADIANS(a.latitude)) * COS(RADIANS(b.latitude)) *
                    POWER(SIN(RADIANS(b.longitude - a.longitude) / 2), 2)
                )) * 1.3
              )::NUMERIC, 2) AS road_km
) r
JOIN   transport_mode m
       ON  m.mode_name IN ('car', 'bike', 'bus')
       OR (m.mode_name = 'walk' AND r.road_km <= 3)
CROSS JOIN LATERAL (
       SELECT GREATEST(1, CEIL(r.road_km / m.avg_speed_kmph * 60)
                          + CASE WHEN m.mode_name = 'walk' THEN 0 ELSE 5 END)::INT AS minutes
) t
WHERE  r.road_km > 0
  AND  r.road_km < 60;

-- =====================================================================
--  Sanity check:
--      SELECT pf.name AS from_place, pt.name AS to_place, m.mode_name,
--             l.distance_km, l.typical_duration_min, l.monsoon_duration_min
--      FROM   travel_leg l
--      JOIN   place pf ON pf.place_id = l.from_place_id
--      JOIN   place pt ON pt.place_id = l.to_place_id
--      JOIN   transport_mode m USING (mode_id)
--      WHERE  pf.name = 'Abbey Falls'
--      ORDER  BY l.distance_km, m.mode_name;
-- =====================================================================
