import { pool } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { project } from '@/lib/helpers';
import { Notice, SouthIndiaMap, type StateStat, type Dot } from '../components';

export const dynamic = 'force-dynamic';

export default async function ExplorePage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; ok?: string }>;
}) {
  await requireSession();
  const params = await searchParams;

  // One row per state: how many destinations and places it has, and its
  // three most common kinds of place.
  // Shows: JOIN, GROUP BY, COUNT(DISTINCT), and a subquery in FROM.
  const stats = await pool.query<{
    state: string;
    destinations: string;
    places: string;
    rated: string | null;
    top_types: string;
  }>(`
    SELECT   d.state,
             COUNT(DISTINCT d.destination_id)  AS destinations,
             COUNT(p.place_id)                 AS places,
             ROUND(AVG(p.avg_rating), 1)       AS rated,
             (SELECT string_agg(x.place_type, ', ' ORDER BY x.n DESC, x.place_type)
              FROM  (SELECT   p2.place_type, COUNT(*) AS n
                     FROM     place p2
                     JOIN     destination d2 ON d2.destination_id = p2.destination_id
                     WHERE    d2.state = d.state
                     GROUP BY p2.place_type
                     ORDER BY n DESC, p2.place_type
                     LIMIT    3) x)            AS top_types
    FROM     destination d
    LEFT JOIN place      p ON p.destination_id = d.destination_id
    GROUP BY d.state
    ORDER BY d.state`);

  const dests = await pool.query<{ name: string; state: string; lat: string; lon: string }>(`
    SELECT name, state, dest_lat AS lat, dest_lon AS lon
    FROM   destination
    WHERE  dest_lat IS NOT NULL AND dest_lon IS NOT NULL
    ORDER  BY name`);

  const byState: Record<string, StateStat> = {};
  for (const r of stats.rows) {
    byState[r.state] = {
      destinations: Number(r.destinations),
      places: Number(r.places),
      rating: r.rated,
      topTypes: r.top_types ?? '',
    };
  }

  const dots: Dot[] = dests.rows.map((d) => {
    const [x, y] = project(Number(d.lon), Number(d.lat));
    return { name: d.name, state: d.state, x, y };
  });

  const totalPlaces = stats.rows.reduce((n, r) => n + Number(r.places), 0);

  return (
    <>
      <Notice params={params} />
      <SouthIndiaMap stats={byState} dots={dots} totalPlaces={totalPlaces} />
    </>
  );
}
