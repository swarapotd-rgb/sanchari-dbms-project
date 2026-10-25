import Link from 'next/link';
import { pool } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { cap, fmtRange } from '@/lib/helpers';
import { Notice, SubmitButton } from '../components';
import { createTrip } from '../actions';

export const dynamic = 'force-dynamic';

type TripRow = {
  trip_id: string;
  title: string;
  owner: string;
  start_date: Date;
  end_date: Date;
  days: string;
  stops: string;
  status: string;
  feasibility_score: string | null;
  blocking: number | null;
  warning: number | null;
  first_problem: string | null;
};

export default async function TripsPage({
  searchParams,
}: {
  searchParams: Promise<{ ok?: string; error?: string; status?: string }>;
}) {
  const session = await requireSession();
  const sp = await searchParams;
  const mine = session.role === 'Traveller';
  const statusFilter = ['draft', 'validated', 'blocked', 'locked', 'completed', 'cancelled'].includes(sp.status ?? '')
    ? sp.status!
    : null;

  // Each trip with its day and stop counts and the result of its latest
  // feasibility run (a LATERAL subquery picks that one run per trip).
  const trips = await pool.query<TripRow>(
    `SELECT   t.trip_id, t.title, u.display_name AS owner, t.start_date, t.end_date,
              (SELECT COUNT(*) FROM trip_day       td WHERE td.trip_id = t.trip_id) AS days,
              (SELECT COUNT(*) FROM itinerary_stop s  WHERE s.trip_id  = t.trip_id) AS stops,
              t.status, t.feasibility_score,
              lr.blocking_count AS blocking, lr.warning_count AS warning,
              (SELECT v.message FROM violation v
               WHERE  v.run_id = lr.run_id
               ORDER  BY (v.severity = 'blocking') DESC, v.violation_no
               LIMIT  1) AS first_problem
     FROM     trip         t
     JOIN     user_account u ON u.user_id = t.owner_user_id
     LEFT JOIN LATERAL (SELECT fr.run_id, fr.blocking_count, fr.warning_count
                        FROM   feasibility_run fr
                        WHERE  fr.trip_id = t.trip_id
                        ORDER  BY fr.run_id DESC
                        LIMIT  1) lr ON TRUE
     WHERE    ($1::BIGINT IS NULL OR t.owner_user_id = $1)
       AND    ($2::TEXT   IS NULL OR t.status = $2)
     ORDER BY t.start_date DESC, t.trip_id DESC`,
    [mine ? session.userId : null, statusFilter],
  );

  const [modes, destinations] = mine
    ? await Promise.all([
        pool.query<{ mode_id: number; mode_name: string }>('SELECT mode_id, mode_name FROM transport_mode ORDER BY mode_id'),
        pool.query<{ destination_id: string; name: string; state: string }>(
          'SELECT destination_id, name, state FROM destination ORDER BY state, name',
        ),
      ])
    : [null, null];

  const byState = new Map<string, { destination_id: string; name: string }[]>();
  destinations?.rows.forEach((d) => byState.set(d.state, [...(byState.get(d.state) ?? []), d]));

  return (
    <>
      <div className="page-head">
        <div>
          <h1>{mine ? 'My trips' : 'All trips'}</h1>
          <p>
            {mine
              ? 'Plan a trip, add places from Explore, then run the feasibility check to find any stop that will not work.'
              : 'Every traveller’s trips with the result of their latest feasibility check.'}
          </p>
        </div>
        {mine && (
          <a className="btn btn-primary" href="#new">
            Plan a new trip
          </a>
        )}
      </div>

      <Notice params={sp} />

      <form method="get" className="form-actions" style={{ marginTop: 0, marginBottom: '1rem', alignItems: 'center' }}>
        <label htmlFor="status">Show</label>
        <select id="status" name="status" defaultValue={statusFilter ?? ''} style={{ width: 'auto' }}>
          <option value="">All statuses</option>
          {['draft', 'validated', 'blocked', 'locked', 'completed', 'cancelled'].map((s) => (
            <option key={s} value={s}>
              {cap(s)}
            </option>
          ))}
        </select>
        <button className="btn btn-ghost btn-small" type="submit">
          Apply
        </button>
      </form>

      {trips.rows.length === 0 ? (
        <p className="empty">{statusFilter ? 'No trips with that status.' : 'No trips yet. Plan your first one below.'}</p>
      ) : (
        <ul className="trip-cards">
          {trips.rows.map((t) => (
            <li key={t.trip_id}>
              <Link href={`/trips/${t.trip_id}`} className="trip-card">
                <div className="top">
                  <div>
                    <h3>{t.title}</h3>
                    <span className="muted small">
                      {mine ? '' : `${t.owner}, `}
                      {fmtRange(t.start_date, t.end_date)}
                    </span>
                  </div>
                  <span className="score" title="Feasibility score">
                    {t.feasibility_score === null ? '' : Math.round(Number(t.feasibility_score))}
                  </span>
                </div>
                <span className="muted small">
                  {t.days} {Number(t.days) === 1 ? 'day' : 'days'}, {t.stops} {Number(t.stops) === 1 ? 'stop' : 'stops'}
                </span>
                <span>
                  <span className={`tag status-${t.status}`}>{t.status}</span>
                  {t.feasibility_score === null && t.status === 'draft' && <span className="muted small"> Not checked since the last change</span>}
                </span>
                {t.first_problem && t.status !== 'draft' && (
                  <span className="problem" style={{ color: t.blocking ? 'var(--danger)' : 'var(--warn)' }}>
                    {cap(t.first_problem)}
                  </span>
                )}
              </Link>
            </li>
          ))}
        </ul>
      )}

      {mine && modes && (
        <section className="section panel" id="new" aria-labelledby="new-title">
          <h2 id="new-title" style={{ marginBottom: '1rem' }}>
            Plan a new trip
          </h2>
          <form action={createTrip}>
            <div className="form-grid">
              <div className="field" style={{ gridColumn: '1 / -1' }}>
                <label htmlFor="title">Trip name</label>
                <input id="title" name="title" required maxLength={120} placeholder="Hampi long weekend" />
              </div>
              <div className="field">
                <label htmlFor="start_date">First day</label>
                <input id="start_date" name="start_date" type="date" required />
              </div>
              <div className="field">
                <label htmlFor="end_date">Last day</label>
                <input id="end_date" name="end_date" type="date" />
                <span className="hint">Leave empty for a day trip.</span>
              </div>
              <div className="field">
                <label htmlFor="party_size">People</label>
                <input id="party_size" name="party_size" type="number" min="1" defaultValue="2" required />
              </div>
              <div className="field">
                <label htmlFor="budget_cap">Budget (₹)</label>
                <input id="budget_cap" name="budget_cap" type="number" min="0" placeholder="Optional" />
              </div>
              <div className="field">
                <label htmlFor="mode_id">Getting around by</label>
                <select id="mode_id" name="mode_id" defaultValue="1">
                  {modes.rows.map((m) => (
                    <option key={m.mode_id} value={m.mode_id}>
                      {cap(m.mode_name)}
                    </option>
                  ))}
                </select>
              </div>
              <div className="field">
                <label htmlFor="base_destination_id">Staying in</label>
                <select id="base_destination_id" name="base_destination_id" defaultValue="">
                  <option value="">Not decided</option>
                  {[...byState.entries()].map(([state, list]) => (
                    <optgroup key={state} label={state}>
                      {list.map((d) => (
                        <option key={d.destination_id} value={d.destination_id}>
                          {d.name}
                        </option>
                      ))}
                    </optgroup>
                  ))}
                </select>
              </div>
              <div className="field">
                <label htmlFor="origin_city">Starting from</label>
                <input id="origin_city" name="origin_city" placeholder="Bengaluru" />
              </div>
            </div>
            <div className="form-actions">
              <SubmitButton pending="Creating…">Create trip</SubmitButton>
            </div>
          </form>
        </section>
      )}
    </>
  );
}
