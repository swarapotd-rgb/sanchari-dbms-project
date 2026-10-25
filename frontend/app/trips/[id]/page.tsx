import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pool } from '@/lib/db';
import { requireSession, isStaff } from '@/lib/auth';
import { cap, fmtDay, fmtRange, minutes, rupees } from '@/lib/helpers';
import { Notice, SubmitButton } from '../../components';
import { checkTrip, updateStop, removeStop, cancelTrip, deleteTrip } from '../../actions';

export const dynamic = 'force-dynamic';

const EDITABLE = ['draft', 'validated', 'blocked'];

const RULES: Record<string, string> = {
  R01: 'Open that weekday',
  R02: 'Within entry hours',
  R03: 'No special closure',
  R04: 'Enough travel time',
  R05: 'Enough time there',
  R06: 'In daylight',
  R07: 'Daily travel limit',
  R08: 'Within budget',
};

export default async function TripPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ ok?: string; error?: string; info?: string }>;
}) {
  const session = await requireSession();
  const { id } = await params;
  if (!/^\d+$/.test(id)) notFound();
  const tripId = Number(id);
  const sp = await searchParams;

  const tripRes = await pool.query<{
    trip_id: string; owner_user_id: string; owner: string; title: string; origin_city: string | null;
    start_date: Date; end_date: Date; party_size: number; budget_cap: string | null; status: string;
    status_note: string | null; feasibility_score: string | null; mode_name: string;
  }>(
    `SELECT t.trip_id, t.owner_user_id, u.display_name AS owner, t.title, t.origin_city,
            t.start_date, t.end_date, t.party_size, t.budget_cap, t.status, t.status_note,
            t.feasibility_score, tm.mode_name
     FROM   trip           t
     JOIN   user_account   u  ON u.user_id  = t.owner_user_id
     JOIN   transport_mode tm ON tm.mode_id = t.primary_mode_id
     WHERE  t.trip_id = $1`,
    [tripId],
  );
  const trip = tripRes.rows[0];
  if (!trip) notFound();

  const isOwner = Number(trip.owner_user_id) === session.userId;
  if (!isOwner && !isStaff(session)) notFound(); // travellers only see their own trips
  const canEdit = isOwner && EDITABLE.includes(trip.status);
  const canCheck = (isOwner || session.role === 'Admin') && trip.status !== 'cancelled';

  const [days, stops, runs] = await Promise.all([
    pool.query<{ day_number: number; calendar_date: Date; base: string | null }>(
      `SELECT td.day_number, td.calendar_date, d.name AS base
       FROM   trip_day td LEFT JOIN destination d ON d.destination_id = td.base_destination_id
       WHERE  td.trip_id = $1 ORDER BY td.day_number`,
      [tripId],
    ),
    // v_day_schedule works out the gap since the previous stop with a
    // window function (LAG), so the page does not have to.
    pool.query<{
      day_number: number; stop_seq: number; place_id: string; place_name: string;
      arrive: string; leave: string; gap_minutes: string | null; allotted_minutes: string;
      estimated_cost: string | null; requires_daylight: boolean;
    }>(
      `SELECT v.day_number, v.stop_seq, v.place_id, v.place_name,
              to_char(v.planned_arrival, 'HH24:MI')   AS arrive,
              to_char(v.planned_departure, 'HH24:MI') AS leave,
              v.gap_minutes, v.allotted_minutes, s.estimated_cost, p.requires_daylight
       FROM   v_day_schedule v
       JOIN   itinerary_stop s ON s.trip_id = v.trip_id AND s.day_number = v.day_number AND s.stop_seq = v.stop_seq
       JOIN   place          p ON p.place_id = v.place_id
       WHERE  v.trip_id = $1
       ORDER  BY v.day_number, v.stop_seq`,
      [tripId],
    ),
    pool.query<{ run_id: string; run_at: Date; blocking_count: number; warning_count: number; feasibility_score: string | null; run_status: string; rules_evaluated: number }>(
      `SELECT run_id, run_at, blocking_count, warning_count, feasibility_score, run_status, rules_evaluated
       FROM   feasibility_run WHERE trip_id = $1 ORDER BY run_id DESC LIMIT 10`,
      [tripId],
    ),
  ]);

  const latest = runs.rows[0];
  const violations = latest
    ? (
        await pool.query<{ violation_no: number; rule_code: string; severity: string; message: string; observed_value: string | null; expected_value: string | null; day_number: number | null; stop_seq: number | null }>(
          `SELECT violation_no, rule_code, severity, message, observed_value, expected_value, day_number, stop_seq
           FROM   violation WHERE run_id = $1 ORDER BY (severity = 'blocking') DESC, violation_no`,
          [latest.run_id],
        )
      ).rows
    : [];

  const flagsFor = (day: number, seq: number) => violations.filter((v) => v.day_number === day && v.stop_seq === seq);
  const blocked = violations.some((v) => v.severity === 'blocking');
  const stale = trip.status === 'draft' && latest;
  const totalCost = stops.rows.reduce((n, s) => n + Number(s.estimated_cost ?? 0), 0);

  return (
    <>
      <p className="crumbs">
        <Link href="/trips">{session.role === 'Traveller' ? 'My trips' : 'All trips'}</Link> / {trip.title}
      </p>
      <div className="page-head">
        <div>
          <h1>{trip.title}</h1>
          <p>
            {fmtRange(trip.start_date, trip.end_date)}. {trip.party_size} {trip.party_size === 1 ? 'person' : 'people'} by {trip.mode_name}
            {trip.origin_city ? `, from ${trip.origin_city}` : ''}. {trip.budget_cap === null ? 'No budget set.' : `Budget ${rupees(trip.budget_cap)}.`}
            {!isOwner && ` Planned by ${trip.owner}.`}
          </p>
        </div>
        <span className={`tag status-${trip.status}`} style={{ fontSize: '0.95rem' }}>
          {trip.status}
        </span>
      </div>

      <Notice params={sp} />

      <section className="check-bar" aria-label="Feasibility">
        <div className={`score-big${blocked && !stale ? ' is-blocked' : ''}`}>
          <strong>{trip.feasibility_score === null ? '--' : Math.round(Number(trip.feasibility_score))}</strong>
          <span className="muted">
            {!latest
              ? 'Not checked yet'
              : stale
                ? 'Changed since the last check'
                : `out of 100, checked ${latest.run_at.toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', dateStyle: 'medium', timeStyle: 'short' })}`}
          </span>
        </div>
        {canCheck && (
          <form action={checkTrip}>
            <input type="hidden" name="trip_id" value={tripId} />
            <SubmitButton pending="Checking…">Check feasibility</SubmitButton>
          </form>
        )}
      </section>

      {latest && !stale && (
        violations.length === 0 ? (
          <p className="notice notice-ok" style={{ marginTop: '1rem' }}>
            All {latest.rules_evaluated} rules passed: every place is open, reachable in time, in daylight where needed, and within budget.
          </p>
        ) : (
          <ul className="violations" aria-label="Problems found">
            {violations.map((v) => (
              <li key={v.violation_no} className={`violation ${v.severity}`}>
                <span className="code">{v.rule_code}</span>
                <span>
                  <strong>{cap(v.message)}</strong>
                  <span className="muted small"> {RULES[v.rule_code]}, {v.severity}</span>
                </span>
                {(v.observed_value || v.expected_value) && (
                  <span className="detail">
                    {v.observed_value && `Planned: ${v.observed_value}`}
                    {v.observed_value && v.expected_value && '. '}
                    {v.expected_value && `Needed: ${v.expected_value}`}
                  </span>
                )}
              </li>
            ))}
          </ul>
        )
      )}

      <section className="section" aria-labelledby="plan-title">
        <div className="section-head">
          <h2 id="plan-title">Day by day</h2>
          <span className="muted small">
            Estimated cost {rupees(totalCost)}
            {canEdit && (
              <>
                . <Link href="/explore">Add places from Explore</Link>
              </>
            )}
          </span>
        </div>

        {days.rows.map((d) => {
          const dayStops = stops.rows.filter((s) => s.day_number === d.day_number);
          return (
            <div key={d.day_number} className="day">
              <div className="day-head">
                <h3>
                  Day {d.day_number}, {fmtDay(d.calendar_date)}
                </h3>
                {d.base && <span className="muted small">Staying in {d.base}</span>}
              </div>
              {dayStops.length === 0 ? (
                <p className="empty">
                  No stops yet.{' '}
                  {canEdit && (
                    <>
                      Find a place in <Link href="/explore">Explore</Link> and choose Add to a trip.
                    </>
                  )}
                </p>
              ) : (
                <div className="table-wrap">
                  <table>
                    <thead>
                      <tr>
                        <th>#</th>
                        <th>Place</th>
                        <th>Time</th>
                        <th>Stay</th>
                        <th>Cost</th>
                        {canEdit && <th aria-label="Actions" />}
                      </tr>
                    </thead>
                    <tbody>
                      {dayStops.map((s, i) => {
                        const flags = stale ? [] : flagsFor(s.day_number, s.stop_seq);
                        return (
                          <tr key={s.stop_seq} className={flags.length ? 'is-flagged' : undefined}>
                            <td className="num">{i + 1}</td>
                            <td>
                              <Link href={`/places/${s.place_id}`}>{s.place_name}</Link>
                              {s.gap_minutes !== null && (
                                <span className="gap-note">{minutes(s.gap_minutes)} after the previous stop</span>
                              )}
                              {flags.map((f) => (
                                <span key={f.violation_no} className={`stop-flag ${f.severity}`}>
                                  {f.rule_code}: {cap(f.message)}
                                </span>
                              ))}
                            </td>
                            <td>
                              {canEdit ? (
                                <form action={updateStop} className="stop-edit">
                                  <input type="hidden" name="trip_id" value={tripId} />
                                  <input type="hidden" name="day_number" value={s.day_number} />
                                  <input type="hidden" name="stop_seq" value={s.stop_seq} />
                                  <label className="visually-hidden" htmlFor={`a-${s.day_number}-${s.stop_seq}`}>Arrive</label>
                                  <input id={`a-${s.day_number}-${s.stop_seq}`} name="arrive" type="time" defaultValue={s.arrive} required />
                                  <span className="muted">to</span>
                                  <label className="visually-hidden" htmlFor={`l-${s.day_number}-${s.stop_seq}`}>Leave</label>
                                  <input id={`l-${s.day_number}-${s.stop_seq}`} name="leave" type="time" defaultValue={s.leave} required />
                                  <SubmitButton pending="Saving…" className="btn btn-ghost btn-small">
                                    Save
                                  </SubmitButton>
                                </form>
                              ) : (
                                <span className="num">
                                  {s.arrive} to {s.leave}
                                </span>
                              )}
                            </td>
                            <td className="num">{minutes(s.allotted_minutes)}</td>
                            <td className="num">{rupees(s.estimated_cost)}</td>
                            {canEdit && (
                              <td>
                                <form action={removeStop}>
                                  <input type="hidden" name="trip_id" value={tripId} />
                                  <input type="hidden" name="day_number" value={s.day_number} />
                                  <input type="hidden" name="stop_seq" value={s.stop_seq} />
                                  <SubmitButton pending="Removing…" className="btn btn-danger btn-small">
                                    Remove
                                  </SubmitButton>
                                </form>
                              </td>
                            )}
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          );
        })}
      </section>

      {runs.rows.length > 0 && (
        <section className="section" aria-labelledby="history-title">
          <h2 id="history-title">Check history</h2>
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Run</th>
                  <th>When</th>
                  <th>Rules checked</th>
                  <th>Blocking</th>
                  <th>Warnings</th>
                  <th>Score</th>
                </tr>
              </thead>
              <tbody>
                {runs.rows.map((r) => (
                  <tr key={r.run_id}>
                    <td className="num">{r.run_id}</td>
                    <td className="num">
                      {r.run_at.toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', dateStyle: 'medium', timeStyle: 'short' })}
                    </td>
                    <td className="num">{r.rules_evaluated}</td>
                    <td className="num">{r.blocking_count}</td>
                    <td className="num">{r.warning_count}</td>
                    <td className="num">{r.feasibility_score === null ? r.run_status : Math.round(Number(r.feasibility_score))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {isOwner && (
        <section className="section form-actions" aria-label="Trip actions">
          {!['cancelled', 'completed'].includes(trip.status) && (
            <form action={cancelTrip}>
              <input type="hidden" name="trip_id" value={tripId} />
              <SubmitButton pending="Cancelling…" className="btn btn-ghost" confirm="Cancel this trip? It stays in your list as cancelled.">
                Cancel trip
              </SubmitButton>
            </form>
          )}
          <form action={deleteTrip}>
            <input type="hidden" name="trip_id" value={tripId} />
            <SubmitButton pending="Deleting…" className="btn btn-danger" confirm="Delete this trip with all its days, stops and check history? This cannot be undone.">
              Delete trip
            </SubmitButton>
          </form>
        </section>
      )}
      {trip.status_note && <p className="muted small" style={{ marginTop: '1rem' }}>{trip.status_note}</p>}
    </>
  );
}
