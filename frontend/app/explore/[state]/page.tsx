import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pool } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { southMap } from '@/lib/southMap';
import { stateBySlug, project, PLACE_TYPES, cap, minutes, rupees } from '@/lib/helpers';
import { AutoSubmitForm } from '../../components';

export const dynamic = 'force-dynamic';

type Search = {
  q?: string;
  dest?: string;
  type?: string;
  maxfee?: string;
  daylight?: string;
  sort?: string;
};

type PlaceRow = {
  place_id: string;
  name: string;
  place_type: string;
  destination: string;
  short_description: string | null;
  fee_indian: string;
  typical_visit_minutes: number;
  requires_daylight: boolean;
  avg_rating: string | null;
  review_count: number;
  categories: string | null;
  total: string;
};

const SORTS: Record<string, string> = {
  relevance: 'rank DESC, avg_rating DESC NULLS LAST, name',
  rating: 'avg_rating DESC NULLS LAST, review_count DESC, name',
  fee: 'fee_indian, name',
  name: 'name',
};

export default async function StatePage({
  params,
  searchParams,
}: {
  params: Promise<{ state: string }>;
  searchParams: Promise<Search>;
}) {
  await requireSession();
  const { state: slug } = await params;
  const shape = stateBySlug(slug);
  if (!shape) notFound();
  const sp = await searchParams;

  const q = (sp.q ?? '').trim().slice(0, 100);
  const dest = /^\d+$/.test(sp.dest ?? '') ? Number(sp.dest) : null;
  const type = PLACE_TYPES.includes(sp.type as (typeof PLACE_TYPES)[number]) ? sp.type! : null;
  const maxFee = /^\d+$/.test(sp.maxfee ?? '') ? Number(sp.maxfee) : null;
  const daylight = sp.daylight === 'yes' || sp.daylight === 'no' ? sp.daylight : null;
  const sort = sp.sort && SORTS[sp.sort] ? sp.sort : q ? 'relevance' : 'rating';

  const destinations = await pool.query<{
    destination_id: string;
    name: string;
    lat: string | null;
    lon: string | null;
    places: string;
  }>(
    `SELECT   d.destination_id, d.name, d.dest_lat AS lat, d.dest_lon AS lon,
              COUNT(p.place_id) AS places
     FROM     destination d
     LEFT JOIN place      p ON p.destination_id = d.destination_id
     WHERE    d.state = $1
     GROUP BY d.destination_id
     ORDER BY d.name`,
    [shape.name],
  );

  // Full-text search. Each place becomes a document made of its name, kind,
  // description and categories; websearch_to_tsquery understands what people
  // type ("quiet beach", "fort -museum", "\"spice farm\""). Stemming means
  // "waterfalls" also finds "waterfall". A plain name match is kept as a
  // fallback for partial words like "Mysu".
  // Every value is passed as a $n parameter, never pasted into the SQL.
  const places = await pool.query<PlaceRow>(
    `WITH doc AS (
       SELECT   p.place_id, p.name, p.place_type, p.short_description, p.fee_indian,
                p.typical_visit_minutes, p.requires_daylight, p.avg_rating, p.review_count,
                d.destination_id, d.name AS destination,
                string_agg(ic.name, ', ' ORDER BY pc.relevance DESC) AS categories
       FROM     place             p
       JOIN     destination       d  ON d.destination_id = p.destination_id
       LEFT JOIN place_category    pc ON pc.place_id     = p.place_id
       LEFT JOIN interest_category ic ON ic.category_id  = pc.category_id
       WHERE    d.state = $1
       GROUP BY p.place_id, d.destination_id
     ),
     scored AS (
       SELECT doc.*,
              CASE WHEN $2 = '' THEN 0
                   ELSE ts_rank(
                          setweight(to_tsvector('english', doc.name), 'A') ||
                          setweight(to_tsvector('english', doc.place_type || ' ' || COALESCE(doc.categories, '')), 'B') ||
                          setweight(to_tsvector('english', COALESCE(doc.short_description, '')), 'C'),
                          websearch_to_tsquery('english', $2))
              END AS rank
       FROM   doc
       WHERE  $2 = ''
          OR  to_tsvector('english', doc.name || ' ' || doc.place_type || ' ' ||
                                     COALESCE(doc.categories, '') || ' ' ||
                                     COALESCE(doc.short_description, ''))
              @@ websearch_to_tsquery('english', $2)
          OR  doc.name ILIKE '%' || $2 || '%'
     )
     SELECT   scored.*, COUNT(*) OVER () AS total
     FROM     scored
     WHERE    ($3::BIGINT  IS NULL OR destination_id = $3)
       AND    ($4::TEXT    IS NULL OR place_type     = $4)
       AND    ($5::NUMERIC IS NULL OR fee_indian    <= $5)
       AND    ($6::TEXT    IS NULL OR requires_daylight = ($6 = 'yes'))
     ORDER BY ${SORTS[sort]}
     LIMIT    60`,
    [shape.name, q, dest, type, maxFee, daylight],
  );

  const total = places.rows[0] ? Number(places.rows[0].total) : 0;
  const activeDest = destinations.rows.find((d) => Number(d.destination_id) === dest);
  const filtered = Boolean(q || dest || type || maxFee !== null || daylight);

  // Frame the state on the small map, with a margin, and make the dots
  // a size that suits how far we are zoomed in.
  const [bx, by, bw, bh] = shape.box;
  const size = Math.max(bw, bh, 60);
  const pad = size * 0.12;
  const cx = bx + bw / 2;
  const cy = by + bh / 2;
  const view = [cx - size / 2 - pad, cy - size / 2 - pad, size + 2 * pad, size + 2 * pad];
  const r = size * 0.018;

  const link = (patch: Partial<Record<keyof Search, string | null>>) => {
    const next = new URLSearchParams();
    const merged = { q, dest: dest?.toString(), type, maxfee: maxFee?.toString(), daylight, sort: sp.sort, ...patch };
    for (const [k, v] of Object.entries(merged)) if (v) next.set(k, String(v));
    const s = next.toString();
    return `/explore/${slug}${s ? '?' + s : ''}`;
  };

  return (
    <>
      <p className="crumbs">
        <Link href="/explore">All states</Link> / {shape.name}
      </p>
      <div className="page-head">
        <div>
          <h1>{activeDest ? `${activeDest.name}, ${shape.name}` : shape.name}</h1>
          <p>
            {destinations.rows.length} destinations and{' '}
            {destinations.rows.reduce((n, d) => n + Number(d.places), 0)} places. Search by name or
            by what you want to do, then open a place for its hours, reviews and similar places.
          </p>
        </div>
      </div>

      <div className="state-layout">
        <div>
          <AutoSubmitForm className="search-bar">
            <div className="q-row">
              <label htmlFor="q" className="visually-hidden">
                Search places
              </label>
              <input
                id="q"
                name="q"
                type="search"
                defaultValue={q}
                placeholder="Try: quiet beach, spice farm, fort, sunset viewpoint"
              />
              <button className="btn btn-primary" type="submit">
                Search
              </button>
            </div>
            <div className="form-grid">
              <div className="field">
                <label htmlFor="dest">Destination</label>
                <select id="dest" name="dest" defaultValue={dest ?? ''}>
                  <option value="">All destinations</option>
                  {destinations.rows.map((d) => (
                    <option key={d.destination_id} value={d.destination_id}>
                      {d.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="field">
                <label htmlFor="type">Kind of place</label>
                <select id="type" name="type" defaultValue={type ?? ''}>
                  <option value="">Any kind</option>
                  {PLACE_TYPES.map((t) => (
                    <option key={t} value={t}>
                      {cap(t)}
                    </option>
                  ))}
                </select>
              </div>
              <div className="field">
                <label htmlFor="maxfee">Entry fee up to</label>
                <select id="maxfee" name="maxfee" defaultValue={maxFee ?? ''}>
                  <option value="">Any fee</option>
                  <option value="0">Free only</option>
                  <option value="50">₹50</option>
                  <option value="100">₹100</option>
                  <option value="500">₹500</option>
                </select>
              </div>
              <div className="field">
                <label htmlFor="daylight">Daylight</label>
                <select id="daylight" name="daylight" defaultValue={daylight ?? ''}>
                  <option value="">Any time</option>
                  <option value="no">Can visit after dark</option>
                  <option value="yes">Daylight only</option>
                </select>
              </div>
              <div className="field">
                <label htmlFor="sort">Sort by</label>
                <select id="sort" name="sort" defaultValue={sort}>
                  {q && <option value="relevance">Best match</option>}
                  <option value="rating">Highest rated</option>
                  <option value="fee">Lowest fee</option>
                  <option value="name">Name</option>
                </select>
              </div>
            </div>
          </AutoSubmitForm>

          <div className="result-meta">
            <span>
              {total === 0
                ? 'No places match.'
                : `${total} ${total === 1 ? 'place' : 'places'}${total > 60 ? ', showing the first 60' : ''}`}
            </span>
            {filtered && <Link href={`/explore/${slug}`}>Clear search and filters</Link>}
          </div>

          {places.rows.length === 0 ? (
            <p className="empty">
              Nothing in {activeDest?.name ?? shape.name} matches that. Try fewer words, or clear a
              filter.
            </p>
          ) : (
            <ul className="places">
              {places.rows.map((p) => (
                <li key={p.place_id}>
                  <Link href={`/places/${p.place_id}`} className="place-row">
                    <div>
                      <h3>{p.name}</h3>
                      <span className="where">
                        {cap(p.place_type)} in {p.destination}
                      </span>
                    </div>
                    <div className="side">
                      {p.avg_rating ? (
                        <>
                          <span className="rating">{Number(p.avg_rating).toFixed(1)}</span>
                          <span className="muted small"> / 5 from {p.review_count}</span>
                        </>
                      ) : (
                        <span className="muted small">No reviews yet</span>
                      )}
                    </div>
                    {p.short_description && <p className="desc">{p.short_description}</p>}
                    <div className="facts">
                      <span>Entry {rupees(p.fee_indian)}</span>
                      <span>Usually {minutes(p.typical_visit_minutes)}</span>
                      {p.requires_daylight && <span>Daylight only</span>}
                      {p.categories && <span>{p.categories}</span>}
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </div>

        <aside className="state-mini" aria-label={`Destinations in ${shape.name}`}>
          <svg viewBox={view.join(' ')} role="img" aria-label={`Map of ${shape.name} with its destinations`}>
            {southMap.states
              .filter((s) => s.slug !== shape.slug)
              .map((s) => (
                <path key={s.slug} d={s.d} className="mini-other" style={{ strokeWidth: size * 0.002 }} />
              ))}
            <path d={shape.d} className="mini-state" style={{ strokeWidth: size * 0.004 }} />
            {destinations.rows
              .filter((d) => d.lat && d.lon)
              .map((d) => {
                const [x, y] = project(Number(d.lon), Number(d.lat));
                return (
                  <a key={d.destination_id} href={link({ dest: d.destination_id })}>
                    <circle
                      cx={x}
                      cy={y}
                      r={r}
                      className={`mini-dot${Number(d.destination_id) === dest ? ' is-on' : ''}`}
                      style={{ strokeWidth: r * 0.35 }}
                    >
                      <title>{`${d.name}: ${d.places} places`}</title>
                    </circle>
                  </a>
                );
              })}
          </svg>
          <ul className="mini-dest-list">
            {destinations.rows.map((d) => (
              <li key={d.destination_id}>
                <Link
                  href={link({ dest: Number(d.destination_id) === dest ? null : d.destination_id })}
                  aria-current={Number(d.destination_id) === dest ? 'true' : undefined}
                >
                  <span>{d.name}</span>
                  <span className="count">{d.places}</span>
                </Link>
              </li>
            ))}
          </ul>
        </aside>
      </div>
    </>
  );
}

