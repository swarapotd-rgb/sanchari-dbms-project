import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pool, reviewsCollection, type ReviewDoc } from '@/lib/db';
import { requireSession, isStaff } from '@/lib/auth';
import { slugOf, cap, fmtDate, fmtDay, hhmm, minutes, rupees } from '@/lib/helpers';
import { Notice, SubmitButton } from '../../components';
import { addToTrip, writeReview, updatePlace } from '../../actions';

export const dynamic = 'force-dynamic';

const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

function todayInIndia(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata' }).format(new Date());
}

export default async function PlacePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ on?: string; ok?: string; error?: string }>;
}) {
  const session = await requireSession();
  const { id } = await params;
  if (!/^\d+$/.test(id)) notFound();
  const placeId = Number(id);
  const sp = await searchParams;
  const checkDate = /^\d{4}-\d{2}-\d{2}$/.test(sp.on ?? '') ? sp.on! : todayInIndia();

  const placeRes = await pool.query<{
    place_id: string; name: string; place_type: string; short_description: string | null;
    fee_indian: string; fee_foreign: string; typical_visit_minutes: number; requires_daylight: boolean;
    avg_rating: string | null; review_count: number; latitude: string; longitude: string;
    destination: string; state: string; categories: string | null;
  }>(
    `SELECT p.place_id, p.name, p.place_type, p.short_description, p.fee_indian, p.fee_foreign,
            p.typical_visit_minutes, p.requires_daylight, p.avg_rating, p.review_count,
            p.latitude, p.longitude, d.name AS destination, d.state,
            v.categories
     FROM   place             p
     JOIN   destination       d ON d.destination_id = p.destination_id
     JOIN   v_place_directory v ON v.place_id       = p.place_id
     WHERE  p.place_id = $1`,
    [placeId],
  );
  const place = placeRes.rows[0];
  if (!place) notFound();

  const [hours, closures, openNow, similar, reviews, tripDays] = await Promise.all([
    // The view v_place_weekly_hours: one row per open weekday.
    pool.query<{ day_of_week: number; opens_at: string; closes_at: string; effective_last_entry: string | null }>(
      `SELECT day_of_week, opens_at, closes_at, effective_last_entry
       FROM   v_place_weekly_hours WHERE place_id = $1 ORDER BY day_of_week`,
      [placeId],
    ),
    pool.query<{ start_date: Date; end_date: Date; reason_code: string; is_annual_recurring: boolean }>(
      `SELECT start_date, end_date, reason_code, is_annual_recurring
       FROM   closure_window WHERE place_id = $1 ORDER BY start_date`,
      [placeId],
    ),
    // Our own function, the same one the feasibility engine uses for R01-R03.
    pool.query<{ is_open: boolean; opens_at: string | null; closes_at: string | null; last_entry_at: string | null; status_reason: string }>(
      'SELECT * FROM f_place_open_on($1, $2::DATE)',
      [placeId, checkDate],
    ),
    // Vector similarity search: the 5 places whose description embeddings
    // are closest to this one by cosine distance (<=>), using the HNSW index.
    pool.query<{ place_id: string; name: string; place_type: string; destination: string; state: string; distance: string }>(
      `SELECT   p.place_id, p.name, p.place_type, d.name AS destination, d.state,
                (e.embedding <=> me.embedding) AS distance
       FROM     place_embedding e
       JOIN     place           p ON p.place_id       = e.place_id
       JOIN     destination     d ON d.destination_id = p.destination_id
       CROSS JOIN (SELECT embedding FROM place_embedding WHERE place_id = $1) AS me
       WHERE    e.place_id <> $1
       ORDER BY e.embedding <=> me.embedding
       LIMIT    5`,
      [placeId],
    ),
    pool.query<{ review_id: string; rating: string; visited_on: Date; crowd_level: number | null; actual_duration_min: number | null; mongo_doc_id: string | null; author: string; user_id: string }>(
      `SELECT r.review_id, r.rating, r.visited_on, r.crowd_level, r.actual_duration_min,
              r.mongo_doc_id, u.display_name AS author, r.user_id
       FROM   review_summary r
       JOIN   user_account   u ON u.user_id = r.user_id
       WHERE  r.place_id = $1
       ORDER  BY r.visited_on DESC, r.review_id DESC
       LIMIT  10`,
      [placeId],
    ),
    session.role === 'Traveller'
      ? pool.query<{ trip_id: string; title: string; day_number: number; calendar_date: Date; stops: string }>(
          `SELECT   t.trip_id, t.title, td.day_number, td.calendar_date,
                    (SELECT COUNT(*) FROM itinerary_stop s
                     WHERE  s.trip_id = td.trip_id AND s.day_number = td.day_number) AS stops
           FROM     trip     t
           JOIN     trip_day td ON td.trip_id = t.trip_id
           WHERE    t.owner_user_id = $1
             AND    t.status IN ('draft', 'validated', 'blocked')
           ORDER BY t.start_date, t.trip_id, td.day_number`,
          [session.userId],
        )
      : Promise.resolve(null),
  ]);

  // The written part of each review lives in MongoDB, linked by review_id.
  const reviewIds = reviews.rows.map((r) => Number(r.review_id));
  const collection = reviewIds.length ? await reviewsCollection() : null;
  let docs = new Map<number, ReviewDoc>();
  let mongoDown = false;
  if (reviewIds.length) {
    if (!collection) mongoDown = true;
    else {
      try {
        const found = await collection.find({ review_id: { $in: reviewIds } }).toArray();
        docs = new Map(found.map((d) => [Number(d.review_id), d]));
      } catch {
        mongoDown = true;
      }
    }
  }

  const open = openNow.rows[0];
  const hoursByDay = new Map(hours.rows.map((h) => [h.day_of_week, h]));
  const checkDow = new Date(checkDate + 'T00:00:00Z').getUTCDay();
  const stateSlug = slugOf(place.state);

  return (
    <>
      <p className="crumbs">
        <Link href="/explore">All states</Link> / <Link href={`/explore/${stateSlug}`}>{place.state}</Link> /{' '}
        {place.destination}
      </p>
      <div className="page-head">
        <div>
          <h1>{place.name}</h1>
          <p>
            {cap(place.place_type)} in {place.destination}, {place.state}
            {place.categories ? `. ${place.categories}` : ''}
          </p>
        </div>
        {session.role === 'Traveller' && (
          <a className="btn btn-primary" href="#plan">
            Add to a trip
          </a>
        )}
      </div>

      <Notice params={sp} />

      <div className="place-layout">
        <div>
          {place.short_description && <p style={{ fontSize: '1.1rem', marginBottom: '1.25rem' }}>{place.short_description}</p>}

          <div className="facts-grid">
            <div className="fact">
              <strong>{place.avg_rating ? Number(place.avg_rating).toFixed(2) : 'None yet'}</strong>
              <span>{place.review_count} {place.review_count === 1 ? 'review' : 'reviews'}</span>
            </div>
            <div className="fact">
              <strong>{rupees(place.fee_indian)}</strong>
              <span>Entry, Indian visitors</span>
            </div>
            <div className="fact">
              <strong>{rupees(place.fee_foreign)}</strong>
              <span>Entry, foreign visitors</span>
            </div>
            <div className="fact">
              <strong>{minutes(place.typical_visit_minutes)}</strong>
              <span>Typical visit</span>
            </div>
            <div className="fact">
              <strong>{place.requires_daylight ? 'Daylight' : 'Any time'}</strong>
              <span>{place.requires_daylight ? 'Visit 06:30 to 18:30' : 'No daylight limit'}</span>
            </div>
          </div>

          <section className="section" aria-labelledby="hours-title">
            <h2 id="hours-title">Opening hours</h2>
            <div className="two-col">
              <div className="table-wrap">
                <table className="hours">
                  <thead>
                    <tr>
                      <th>Day</th>
                      <th>Open</th>
                      <th>Last entry</th>
                    </tr>
                  </thead>
                  <tbody>
                    {[1, 2, 3, 4, 5, 6, 0].map((d) => {
                      const h = hoursByDay.get(d);
                      return (
                        <tr key={d} className={d === checkDow ? 'is-today' : undefined}>
                          <td>{DAYS[d]}</td>
                          {h ? (
                            <>
                              <td className="num">
                                {hhmm(h.opens_at)} to {hhmm(h.closes_at)}
                              </td>
                              <td className="num">{hhmm(h.effective_last_entry) || 'Until closing'}</td>
                            </>
                          ) : (
                            <td className="closed" colSpan={2}>
                              Closed
                            </td>
                          )}
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>

              <div>
                <form method="get" className="panel">
                  <h3 style={{ marginBottom: '0.75rem' }}>Is it open on a particular day?</h3>
                  <div style={{ display: 'flex', gap: '0.5rem' }}>
                    <label htmlFor="on" className="visually-hidden">
                      Date
                    </label>
                    <input id="on" name="on" type="date" defaultValue={checkDate} />
                    <button className="btn btn-ghost" type="submit">
                      Check
                    </button>
                  </div>
                  <p className={`open-answer ${open.is_open ? 'yes' : 'no'}`}>
                    {fmtDay(new Date(checkDate + 'T00:00:00Z'))}:{' '}
                    {open.is_open
                      ? `open ${hhmm(open.opens_at)} to ${hhmm(open.closes_at)}${open.last_entry_at ? `, last entry ${hhmm(open.last_entry_at)}` : ''}.`
                      : `${open.status_reason}.`}
                  </p>
                </form>

                {closures.rows.length > 0 && (
                  <div className="panel">
                    <h3 style={{ marginBottom: '0.5rem' }}>Planned closures</h3>
                    <ul style={{ margin: 0, paddingLeft: '1.1rem' }}>
                      {closures.rows.map((c, i) => (
                        <li key={i}>
                          {cap(c.reason_code.replace(/_/g, ' '))}: {fmtDate(c.start_date)} to {fmtDate(c.end_date)}
                          {c.is_annual_recurring ? ', every year' : ''}
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
              </div>
            </div>
          </section>

          <section className="section" id="reviews" aria-labelledby="reviews-title">
            <div className="section-head">
              <h2 id="reviews-title">Reviews</h2>
              {mongoDown && <span className="muted small">Written reviews appear when MongoDB is running.</span>}
            </div>
            {reviews.rows.length === 0 ? (
              <p className="empty">No one has reviewed {place.name} yet.</p>
            ) : (
              <div className="panel">
                {reviews.rows.map((r) => {
                  const doc = docs.get(Number(r.review_id));
                  return (
                    <article key={r.review_id} className="review">
                      <div className="review-head">
                        <span>
                          <span className="rating">{Number(r.rating).toFixed(1)}</span>
                          <span className="muted small"> / 5</span>
                        </span>
                        <span className="meta">
                          {r.author}, visited {fmtDate(r.visited_on)}
                          {r.crowd_level ? `, crowd ${r.crowd_level} of 5` : ''}
                          {r.actual_duration_min ? `, stayed ${minutes(r.actual_duration_min)}` : ''}
                        </span>
                      </div>
                      {doc && (
                        <>
                          <h3>{doc.title}</h3>
                          <p className="body">{doc.body}</p>
                          {doc.tip && <p className="meta" style={{ marginTop: '0.4rem' }}>Tip: {doc.tip}</p>}
                          <div className="aspects">
                            {Object.entries(doc.aspects ?? {}).map(([k, v]) => (
                              <span key={k} className="tag">
                                {cap(k.replace(/_/g, ' '))} {v}
                              </span>
                            ))}
                          </div>
                        </>
                      )}
                    </article>
                  );
                })}
              </div>
            )}
          </section>

          {session.role === 'Traveller' && (
            <details className="panel section" id="review">
              <summary>Write a review</summary>
              <form action={writeReview}>
                <input type="hidden" name="place_id" value={placeId} />
                <div className="form-grid">
                  <div className="field">
                    <label htmlFor="rating">Rating</label>
                    <select id="rating" name="rating" defaultValue="5" required>
                      {[5, 4, 3, 2, 1].map((n) => (
                        <option key={n} value={n}>
                          {n} of 5
                        </option>
                      ))}
                    </select>
                  </div>
                  <div className="field">
                    <label htmlFor="visited_on">Date you visited</label>
                    <input id="visited_on" name="visited_on" type="date" max={todayInIndia()} required />
                  </div>
                  <div className="field">
                    <label htmlFor="crowd">How crowded</label>
                    <select id="crowd" name="crowd" defaultValue="">
                      <option value="">Skip</option>
                      <option value="1">1, empty</option>
                      <option value="2">2</option>
                      <option value="3">3</option>
                      <option value="4">4</option>
                      <option value="5">5, packed</option>
                    </select>
                  </div>
                  <div className="field">
                    <label htmlFor="spent">Minutes spent</label>
                    <input id="spent" name="spent" type="number" min="1" placeholder="Optional" />
                  </div>
                </div>
                <div className="field" style={{ marginTop: '0.9rem' }}>
                  <label htmlFor="title">Title</label>
                  <input id="title" name="title" maxLength={80} placeholder="Optional" />
                </div>
                <div className="field" style={{ marginTop: '0.9rem' }}>
                  <label htmlFor="body">Your review</label>
                  <textarea id="body" name="body" maxLength={5000} placeholder="Optional. What should the next visitor know?" />
                  <span className="hint">Ratings are stored in PostgreSQL; the written part in MongoDB.</span>
                </div>
                <div className="form-actions">
                  <SubmitButton pending="Saving…">Post review</SubmitButton>
                </div>
              </form>
            </details>
          )}

          {isStaff(session) && (
            <details className="panel section" id="edit">
              <summary>Edit place details</summary>
              <form action={updatePlace}>
                <input type="hidden" name="place_id" value={placeId} />
                <div className="field">
                  <label htmlFor="short_description">Short description</label>
                  <textarea id="short_description" name="short_description" maxLength={280} defaultValue={place.short_description ?? ''} />
                  <span className="hint">At least 10 characters, or leave empty.</span>
                </div>
                <div className="form-grid" style={{ marginTop: '0.9rem' }}>
                  <div className="field">
                    <label htmlFor="fee_indian">Fee, Indian (₹)</label>
                    <input id="fee_indian" name="fee_indian" type="number" step="1" defaultValue={Number(place.fee_indian)} required />
                  </div>
                  <div className="field">
                    <label htmlFor="fee_foreign">Fee, foreign (₹)</label>
                    <input id="fee_foreign" name="fee_foreign" type="number" step="1" defaultValue={Number(place.fee_foreign)} required />
                  </div>
                  <div className="field">
                    <label htmlFor="typical_visit_minutes">Typical visit (min)</label>
                    <input id="typical_visit_minutes" name="typical_visit_minutes" type="number" defaultValue={place.typical_visit_minutes} required />
                  </div>
                  <label className="check">
                    <input type="checkbox" name="requires_daylight" defaultChecked={place.requires_daylight} /> Daylight only
                  </label>
                </div>
                <div className="form-actions">
                  <SubmitButton pending="Saving…">Save changes</SubmitButton>
                </div>
              </form>
            </details>
          )}
        </div>

        <aside>
          {session.role === 'Traveller' && (
            <section className="panel" id="plan" aria-labelledby="plan-title">
              <h2 id="plan-title" style={{ marginBottom: '0.75rem' }}>
                Add to a trip
              </h2>
              {!tripDays || tripDays.rows.length === 0 ? (
                <p className="muted">
                  You have no trips that can still change. <Link href="/trips#new">Plan a new trip</Link> first.
                </p>
              ) : (
                <form action={addToTrip}>
                  <input type="hidden" name="place_id" value={placeId} />
                  <div className="field" style={{ marginBottom: '0.8rem' }}>
                    <label htmlFor="trip_day">Trip and day</label>
                    <select id="trip_day" name="trip_day" required>
                      {tripDays.rows.map((d) => (
                        <option key={`${d.trip_id}:${d.day_number}`} value={`${d.trip_id}:${d.day_number}`}>
                          {d.title}, day {d.day_number} ({fmtDay(d.calendar_date)}, {d.stops} stops)
                        </option>
                      ))}
                    </select>
                  </div>
                  <div className="form-grid">
                    <div className="field">
                      <label htmlFor="arrive">Arrive</label>
                      <input id="arrive" name="arrive" type="time" defaultValue="09:00" required />
                    </div>
                    <div className="field">
                      <label htmlFor="leave">Leave</label>
                      <input id="leave" name="leave" type="time" />
                    </div>
                  </div>
                  <p className="hint muted small" style={{ marginTop: '0.4rem' }}>
                    Leave empty to stay the usual {minutes(place.typical_visit_minutes)}.
                  </p>
                  <div className="form-actions">
                    <SubmitButton pending="Adding…" className="btn btn-primary btn-block">
                      Add stop
                    </SubmitButton>
                  </div>
                </form>
              )}
            </section>
          )}

          <section className="panel" aria-labelledby="similar-title">
            <h2 id="similar-title" style={{ marginBottom: '0.25rem' }}>
              Places like this
            </h2>
            <p className="muted small" style={{ marginBottom: '0.5rem' }}>
              Closest in meaning, found by vector similarity on the place descriptions.
            </p>
            <ul className="similar">
              {similar.rows.map((s) => (
                <li key={s.place_id}>
                  <Link href={`/places/${s.place_id}`}>
                    <span className="n">{s.name}</span>
                    <span className="d">{Math.round((1 - Number(s.distance)) * 100)}% match</span>
                    <span className="w">
                      {cap(s.place_type)}, {s.destination}, {s.state}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>

          <p className="muted small" style={{ marginTop: '1rem' }}>
            Location {Number(place.latitude).toFixed(4)}, {Number(place.longitude).toFixed(4)}
          </p>
        </aside>
      </div>
    </>
  );
}
