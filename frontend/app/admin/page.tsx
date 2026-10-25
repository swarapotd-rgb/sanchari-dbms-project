import Link from 'next/link';
import { pool } from '@/lib/db';
import { requireRole } from '@/lib/auth';
import { fmtDate } from '@/lib/helpers';
import { Notice, SubmitButton } from '../components';
import { setAccountStatus } from '../actions';

export const dynamic = 'force-dynamic';

const RULES: Record<string, string> = {
  R01: 'Closed that weekday',
  R02: 'Outside entry hours',
  R03: 'Special closure',
  R04: 'Not enough travel time',
  R05: 'Too little time there',
  R06: 'After dark',
  R07: 'Too much travel in a day',
  R08: 'Over budget',
};

export default async function OverviewPage({
  searchParams,
}: {
  searchParams: Promise<{ ok?: string; error?: string }>;
}) {
  const session = await requireRole('Admin', 'Curator');
  const sp = await searchParams;

  // Admins also manage accounts. LEFT JOINs so users with no profile,
  // trips or reviews still appear.
  const users =
    session.role === 'Admin'
      ? (
          await pool.query<{
            user_id: string; display_name: string; email: string; role_name: string;
            account_status: string; date_joined: Date; trips: string; reviews: string;
          }>(
            `SELECT   u.user_id, u.display_name, u.email, r.role_name, u.account_status, u.date_joined,
                      COUNT(DISTINCT t.trip_id)    AS trips,
                      COUNT(DISTINCT rs.review_id) AS reviews
             FROM     user_account   u
             JOIN     role           r  ON r.role_id = u.role_id
             LEFT JOIN trip          t  ON t.owner_user_id = u.user_id
             LEFT JOIN review_summary rs ON rs.user_id = u.user_id
             GROUP BY u.user_id, r.role_name
             ORDER BY r.role_name, u.display_name`,
          )
        ).rows
      : [];

  const [figures, rules, perState, attention, topPlaces] = await Promise.all([
    pool.query<{ travellers: string; places: string; trips: string; blocked: string; reviews: string; runs: string }>(
      `SELECT (SELECT COUNT(*) FROM user_account u JOIN role r ON r.role_id = u.role_id
               WHERE r.role_name = 'Traveller')                     AS travellers,
              (SELECT COUNT(*) FROM place)                          AS places,
              (SELECT COUNT(*) FROM trip)                           AS trips,
              (SELECT COUNT(*) FROM trip WHERE status = 'blocked')  AS blocked,
              (SELECT COUNT(*) FROM review_summary)                 AS reviews,
              (SELECT COUNT(*) FROM feasibility_run)                AS runs`,
    ),
    // Which rule fails most often, counting every run ever made.
    pool.query<{ rule_code: string; severity: string; n: string }>(
      `SELECT   rule_code, MAX(severity) AS severity, COUNT(*) AS n
       FROM     violation
       GROUP BY rule_code
       ORDER BY n DESC, rule_code`,
    ),
    pool.query<{ state: string; places: string; rated: string | null }>(
      `SELECT   d.state, COUNT(*) AS places, ROUND(AVG(p.avg_rating), 2) AS rated
       FROM     place p JOIN destination d ON d.destination_id = p.destination_id
       GROUP BY d.state
       ORDER BY places DESC`,
    ),
    // v_trip_health: each trip with its latest run.
    pool.query<{ trip_id: string; title: string; status: string; blocking_count: number; warning_count: number; feasibility_score: string | null; owner: string }>(
      `SELECT   h.trip_id, h.title, h.status, h.blocking_count, h.warning_count, h.feasibility_score,
                u.display_name AS owner
       FROM     v_trip_health h
       JOIN     trip          t ON t.trip_id = h.trip_id
       JOIN     user_account  u ON u.user_id = t.owner_user_id
       WHERE    h.blocking_count + h.warning_count > 0
       ORDER BY h.blocking_count DESC, h.feasibility_score, h.trip_id`,
    ),
    pool.query<{ place_id: string; name: string; state: string; avg_rating: string; review_count: number }>(
      `SELECT   p.place_id, p.name, d.state, p.avg_rating, p.review_count
       FROM     place p JOIN destination d ON d.destination_id = p.destination_id
       WHERE    p.review_count >= 2
       ORDER BY p.avg_rating DESC, p.review_count DESC, p.name
       LIMIT    8`,
    ),
  ]);

  const f = figures.rows[0];
  const maxState = Math.max(...perState.rows.map((r) => Number(r.places)));
  const maxRule = Math.max(1, ...rules.rows.map((r) => Number(r.n)));

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Overview</h1>
          <p>What is in Sanchari, which rules trips break most often, and which trips need attention.</p>
        </div>
      </div>

      <Notice params={sp} />

      <div className="figures">
        <div className="figure"><strong>{f.travellers}</strong><span>Travellers</span></div>
        <div className="figure"><strong>{f.places}</strong><span>Places</span></div>
        <div className="figure"><strong>{f.reviews}</strong><span>Reviews</span></div>
        <div className="figure"><strong>{f.trips}</strong><span>Trips</span></div>
        <div className="figure"><strong>{f.runs}</strong><span>Feasibility checks run</span></div>
        <div className={`figure${Number(f.blocked) > 0 ? ' is-alert' : ''}`}><strong>{f.blocked}</strong><span>Blocked trips</span></div>
      </div>

      <div className="two-col section">
        <section className="panel" aria-labelledby="rules-title">
          <h2 id="rules-title" style={{ marginBottom: '1rem' }}>Problems found, by rule</h2>
          {rules.rows.length === 0 ? (
            <p className="muted">No check has found a problem yet.</p>
          ) : (
            <ul className="bars">
              {rules.rows.map((r) => (
                <li key={r.rule_code}>
                  <span>
                    <strong>{r.rule_code}</strong> <span className="muted small">{RULES[r.rule_code]}</span>
                  </span>
                  <span className="bar"><span style={{ width: `${(Number(r.n) / maxRule) * 100}%` }} /></span>
                  <span className="num">{r.n}</span>
                </li>
              ))}
            </ul>
          )}
        </section>

        <section className="panel" aria-labelledby="states-title">
          <h2 id="states-title" style={{ marginBottom: '1rem' }}>Places by state</h2>
          <ul className="bars">
            {perState.rows.map((r) => (
              <li key={r.state}>
                <span>{r.state}</span>
                <span className="bar"><span style={{ width: `${(Number(r.places) / maxState) * 100}%` }} /></span>
                <span className="num">{r.places}</span>
              </li>
            ))}
          </ul>
        </section>
      </div>

      <section className="section" aria-labelledby="attention-title">
        <h2 id="attention-title">Trips that need attention</h2>
        {attention.rows.length === 0 ? (
          <p className="empty">Every trip passed its latest check.</p>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr><th>Trip</th><th>Traveller</th><th>Blocking</th><th>Warnings</th><th>Score</th><th>Status</th></tr>
              </thead>
              <tbody>
                {attention.rows.map((t) => (
                  <tr key={t.trip_id}>
                    <td><Link href={`/trips/${t.trip_id}`}>{t.title}</Link></td>
                    <td>{t.owner}</td>
                    <td className="num">{t.blocking_count}</td>
                    <td className="num">{t.warning_count}</td>
                    <td className="num">{t.feasibility_score === null ? '' : Math.round(Number(t.feasibility_score))}</td>
                    <td><span className={`tag status-${t.status}`}>{t.status}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="section" aria-labelledby="top-title">
        <h2 id="top-title">Best-rated places with two or more reviews</h2>
        <div className="table-wrap">
          <table>
            <thead><tr><th>Place</th><th>State</th><th>Rating</th><th>Reviews</th></tr></thead>
            <tbody>
              {topPlaces.rows.map((p) => (
                <tr key={p.place_id}>
                  <td><Link href={`/places/${p.place_id}`}>{p.name}</Link></td>
                  <td>{p.state}</td>
                  <td className="num">{Number(p.avg_rating).toFixed(2)}</td>
                  <td className="num">{p.review_count}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="muted small" style={{ marginTop: '0.5rem' }}>Ratings are kept up to date by the trigger trg_review_summary_rating.</p>
      </section>

      {session.role === 'Admin' && (
        <section className="section" id="users" aria-labelledby="users-title">
          <h2 id="users-title">Users</h2>
          <p className="muted" style={{ marginBottom: '0.9rem' }}>Suspend an account to stop it signing in. Its trips and reviews are kept.</p>
          <div className="table-wrap">
            <table>
              <thead>
                <tr><th>Name</th><th>Email</th><th>Role</th><th>Joined</th><th>Trips</th><th>Reviews</th><th>Status</th><th aria-label="Actions" /></tr>
              </thead>
              <tbody>
                {users.map((u) => (
                  <tr key={u.user_id}>
                    <td>{u.display_name}</td>
                    <td>{u.email}</td>
                    <td>{u.role_name}</td>
                    <td className="num">{fmtDate(new Date(u.date_joined))}</td>
                    <td className="num">{u.trips}</td>
                    <td className="num">{u.reviews}</td>
                    <td><span className={`tag ${u.account_status === 'active' ? 'tag-ok' : 'tag-blocking'}`}>{u.account_status}</span></td>
                    <td>
                      {Number(u.user_id) !== session.userId && u.account_status !== 'deleted' && (
                        <form action={setAccountStatus}>
                          <input type="hidden" name="user_id" value={u.user_id} />
                          <input type="hidden" name="status" value={u.account_status === 'active' ? 'suspended' : 'active'} />
                          <SubmitButton pending="Saving…" className={u.account_status === 'active' ? 'btn btn-danger btn-small' : 'btn btn-ghost btn-small'}>
                            {u.account_status === 'active' ? 'Suspend' : 'Reactivate'}
                          </SubmitButton>
                        </form>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </>
  );
}
