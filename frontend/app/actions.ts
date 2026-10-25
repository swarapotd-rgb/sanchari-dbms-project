'use server';

import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { pool, inTransaction, reviewsCollection, ObjectId } from '@/lib/db';
import { requireSession, requireRole, createSessionToken, SESSION_COOKIE, sessionCookieOptions, type Role, type Session } from '@/lib/auth';
import { friendlyDbError, withMessage } from '@/lib/helpers';
import { cookies } from 'next/headers';

// =====================================================================
//  Every change to the data goes through this file (INSERT, UPDATE,
//  DELETE, CALL). Pages only read. Each action checks who is signed in
//  again, because an action can be called without loading its page.
// =====================================================================

const EDITABLE = ['draft', 'validated', 'blocked'];
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

// =====================================================================
//  Sign in and sign out
// =====================================================================
export type LoginState = { error: string | null; email: string };

type AccountRow = {
  user_id: string;
  display_name: string;
  email: string;
  role_name: Role;
  account_status: 'active' | 'suspended' | 'deleted';
};

export async function login(_prev: LoginState, formData: FormData): Promise<LoginState> {
  const email = String(formData.get('email') ?? '').trim();
  const password = String(formData.get('password') ?? '');

  if (!email || !password) {
    return { error: 'Enter your email and password.', email };
  }

  // The password is checked inside PostgreSQL with pgcrypto:
  // crypt(typed_password, stored_hash) re-hashes the typed password with the
  // salt inside the stored bcrypt hash. Equal hashes mean the password is right.
  // The plain password never leaves this query and is never stored.
  let account: AccountRow | undefined;
  try {
    const result = await pool.query<AccountRow>(
      `SELECT u.user_id,
              u.display_name,
              u.email,
              r.role_name,
              u.account_status
       FROM   user_account u
       JOIN   role         r ON r.role_id = u.role_id
       WHERE  lower(u.email)  = lower($1)
         AND  u.password_hash = crypt($2, u.password_hash)`,
      [email, password],
    );
    account = result.rows[0];
  } catch (err) {
    console.error('Login query failed:', err);
    return {
      error: 'Could not reach the database. Check that the sanchari-db container is running.',
      email,
    };
  }

  // Same message for "no such email" and "wrong password", so the form
  // does not reveal which emails have accounts.
  if (!account || account.account_status === 'deleted') {
    return { error: 'That email and password don’t match an account.', email };
  }

  if (account.account_status === 'suspended') {
    return { error: 'This account is suspended. Ask an admin to reactivate it.', email };
  }

  const token = await createSessionToken({
    userId: Number(account.user_id),
    name: account.display_name,
    email: account.email,
    role: account.role_name,
  });

  const jar = await cookies();
  jar.set(SESSION_COOKIE, token, sessionCookieOptions);

  redirect('/explore');
}

export async function logout() {
  const jar = await cookies();
  jar.delete(SESSION_COOKIE);
  redirect('/login');
}

// =====================================================================
//  Places: add to a trip, write a review, edit details
// =====================================================================

function backToPlace(placeId: number, kind: 'ok' | 'error', text: string, anchor = ''): never {
  redirect(withMessage(`/places/${placeId}`, kind, text) + anchor);
}

// ---------------------------------------------------------------------
//  Add this place to one of the traveller's trips.          (INSERT)
// ---------------------------------------------------------------------
export async function addToTrip(formData: FormData) {
  const session = await requireRole('Traveller');
  const placeId = Number(formData.get('place_id'));
  const [tripId, dayNumber] = String(formData.get('trip_day') ?? '').split(':').map(Number);
  const arrive = String(formData.get('arrive') ?? '');
  const leave = String(formData.get('leave') ?? '');

  if (!tripId || !dayNumber) backToPlace(placeId, 'error', 'Choose a trip and a day.', '#plan');
  if (!TIME.test(arrive)) backToPlace(placeId, 'error', 'Enter an arrival time like 09:30.', '#plan');
  if (leave && !TIME.test(leave)) backToPlace(placeId, 'error', 'Enter a leave time like 11:00.', '#plan');

  let message: string | null = null;
  try {
    message = await inTransaction(async (db) => {
      // Lock the trip so two additions to the same day cannot pick the same stop number.
      const trip = await db.query<{ owner_user_id: string; status: string }>(
        'SELECT owner_user_id, status FROM trip WHERE trip_id = $1 FOR UPDATE',
        [tripId],
      );
      const t = trip.rows[0];
      if (!t || Number(t.owner_user_id) !== session.userId) return 'That trip is not yours.';
      if (!EDITABLE.includes(t.status)) return `This trip is ${t.status}, so its plan can no longer change.`;

      // Stops are added in visiting order: a new stop starts after the last one leaves.
      const last = await db.query<{ seq: number | null; left_at: string | null }>(
        `SELECT MAX(stop_seq) AS seq,
                to_char(MAX(planned_departure), 'HH24:MI') AS left_at
         FROM   itinerary_stop
         WHERE  trip_id = $1 AND day_number = $2`,
        [tripId, dayNumber],
      );
      const prev = last.rows[0];
      if (prev.left_at && arrive <= prev.left_at) {
        return `Add stops in the order you will visit them. The last stop on that day leaves at ${prev.left_at}, so arrive after that.`;
      }

      // estimated_cost follows docs/feasibility_rules.md: entry fee for the
      // whole party, plus road distance from the previous stop times the
      // mode's cost per km (per person for bus and train).
      // The leave time defaults to arrival + the place's typical visit length.
      await db.query(
        `WITH prev AS (
           SELECT s.place_id
           FROM   itinerary_stop s
           WHERE  s.trip_id = $1 AND s.day_number = $2
           ORDER  BY s.stop_seq DESC
           LIMIT  1
         ),
         km AS (
           SELECT COALESCE(
                    (SELECT tl.distance_km FROM travel_leg tl, trip t
                     WHERE  t.trip_id = $1 AND tl.mode_id = t.primary_mode_id
                       AND  tl.from_place_id = (SELECT place_id FROM prev) AND tl.to_place_id = $4),
                    (SELECT 1.3 * 2 * 6371 * asin(sqrt(
                              power(sin(radians(b.latitude - a.latitude) / 2), 2) +
                              cos(radians(a.latitude)) * cos(radians(b.latitude)) *
                              power(sin(radians(b.longitude - a.longitude) / 2), 2)))
                     FROM   place a, place b
                     WHERE  a.place_id = (SELECT place_id FROM prev) AND b.place_id = $4),
                    0)::NUMERIC AS dist
         )
         INSERT INTO itinerary_stop
                (trip_id, day_number, stop_seq, place_id,
                 planned_arrival, planned_departure, estimated_cost)
         SELECT $1, $2, $3, p.place_id,
                td.calendar_date + $5::TIME,
                td.calendar_date + COALESCE($6::TIME, $5::TIME + make_interval(mins => p.typical_visit_minutes)),
                ROUND(p.fee_indian * t.party_size
                      + km.dist * tm.cost_per_km
                        * CASE WHEN tm.mode_name IN ('bus', 'train') THEN t.party_size ELSE 1 END, 2)
         FROM   place p, trip t, trip_day td, transport_mode tm, km
         WHERE  p.place_id = $4
           AND  t.trip_id = $1
           AND  td.trip_id = $1 AND td.day_number = $2
           AND  tm.mode_id = t.primary_mode_id`,
        [tripId, dayNumber, (prev.seq ?? 0) + 1, placeId, arrive, leave || null],
      );

      // The plan changed, so the last check no longer applies.
      await db.query(
        `UPDATE trip SET status = 'draft', feasibility_score = NULL
         WHERE  trip_id = $1 AND status IN ('validated', 'blocked')`,
        [tripId],
      );
      return null;
    });
  } catch (err) {
    backToPlace(placeId, 'error', friendlyDbError(err), '#plan');
  }
  if (message) backToPlace(placeId, 'error', message, '#plan');

  revalidatePath(`/trips/${tripId}`);
  redirect(withMessage(`/trips/${tripId}`, 'ok', 'Stop added. Run the feasibility check to see if the day still works.'));
}

// ---------------------------------------------------------------------
//  Write a review.  Numbers go to PostgreSQL, words go to MongoDB.
// ---------------------------------------------------------------------
export async function writeReview(formData: FormData) {
  const session = await requireRole('Traveller');
  const placeId = Number(formData.get('place_id'));
  const rating = Number(formData.get('rating'));
  const visitedOn = String(formData.get('visited_on') ?? '');
  const crowd = formData.get('crowd') ? Number(formData.get('crowd')) : null;
  const spent = formData.get('spent') ? Number(formData.get('spent')) : null;
  const title = String(formData.get('title') ?? '').trim();
  const body = String(formData.get('body') ?? '').trim();

  if (!/^\d{4}-\d{2}-\d{2}$/.test(visitedOn)) backToPlace(placeId, 'error', 'Enter the date you visited.', '#review');
  if (visitedOn > new Date().toISOString().slice(0, 10)) backToPlace(placeId, 'error', 'You can only review a visit that has already happened.', '#review');
  if (body && (title.length < 3 || body.length < 20)) {
    backToPlace(placeId, 'error', 'A written review needs a title of 3 or more characters and at least 20 characters of text.', '#review');
  }

  // 1. PostgreSQL. The trigger trg_review_summary_rating updates the place's
  //    avg_rating and review_count as part of this same INSERT.
  let reviewId: number;
  try {
    const res = await pool.query<{ review_id: string }>(
      `INSERT INTO review_summary (place_id, user_id, rating, visited_on, crowd_level, actual_duration_min)
       VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING review_id`,
      [placeId, session.userId, rating, visitedOn, crowd, spent],
    );
    reviewId = Number(res.rows[0].review_id);
  } catch (err) {
    backToPlace(placeId, 'error', friendlyDbError(err), '#review');
  }

  // 2. MongoDB, only if there is text to keep and MongoDB is running.
  let note = 'Review saved. The place’s average rating has been updated.';
  if (body) {
    const reviews = await reviewsCollection();
    if (!reviews) {
      note = 'Rating saved. The written part was not kept because MongoDB is not connected.';
    } else {
      try {
        const place = await pool.query<{ name: string; place_type: string; destination: string; state: string }>(
          `SELECT p.name, p.place_type, d.name AS destination, d.state
           FROM place p JOIN destination d ON d.destination_id = p.destination_id
           WHERE p.place_id = $1`,
          [placeId],
        );
        const pl = place.rows[0];
        const _id = new ObjectId();
        await reviews.insertOne({
          _id,
          review_id: reviewId!,
          place_id: placeId,
          user_id: session.userId,
          place: { name: pl.name, type: pl.place_type, destination: pl.destination, state: pl.state },
          author: { display_name: session.name },
          rating,
          visited_on: new Date(visitedOn + 'T00:00:00Z'),
          title: title.slice(0, 80),
          body: body.slice(0, 5000),
          aspects: { overall: Math.round(rating) },
          tags: [],
          created_at: new Date(),
        });
        // 3. Link the two halves, exactly like the seeded reviews.
        await pool.query('UPDATE review_summary SET mongo_doc_id = $1 WHERE review_id = $2', [_id.toHexString(), reviewId!]);
      } catch (err) {
        console.error('MongoDB insert failed:', err);
        note = 'Rating saved. The written part could not be stored in MongoDB.';
      }
    }
  }

  revalidatePath(`/places/${placeId}`);
  backToPlace(placeId, 'ok', note, '#reviews');
}

// ---------------------------------------------------------------------
//  Curators and admins correct a place's details.             (UPDATE)
// ---------------------------------------------------------------------
export async function updatePlace(formData: FormData) {
  await requireRole('Curator', 'Admin');
  const placeId = Number(formData.get('place_id'));
  const description = String(formData.get('short_description') ?? '').trim();

  try {
    await pool.query(
      `UPDATE place
       SET    short_description     = NULLIF($2, ''),
              fee_indian            = $3,
              fee_foreign           = $4,
              typical_visit_minutes = $5,
              requires_daylight     = $6
       WHERE  place_id = $1`,
      [
        placeId,
        description,
        Number(formData.get('fee_indian')),
        Number(formData.get('fee_foreign')),
        Number(formData.get('typical_visit_minutes')),
        formData.get('requires_daylight') === 'on',
      ],
    );
  } catch (err) {
    backToPlace(placeId, 'error', friendlyDbError(err), '#edit');
  }
  revalidatePath(`/places/${placeId}`);
  backToPlace(placeId, 'ok', 'Place details saved.');
}

// =====================================================================
//  Trips: create, check feasibility, change stops, cancel, delete
// =====================================================================

function toTrip(tripId: number, kind: 'ok' | 'error' | 'info', text: string): never {
  redirect(withMessage(`/trips/${tripId}`, kind, text));
}

// The owner may change their own trip. Admins may run checks on any trip.
async function loadTrip(tripId: number, session: Session, need: 'owner' | 'owner-or-admin') {
  const res = await pool.query<{ owner_user_id: string; status: string }>(
    'SELECT owner_user_id, status FROM trip WHERE trip_id = $1',
    [tripId],
  );
  const t = res.rows[0];
  if (!t) redirect(withMessage('/trips', 'error', 'That trip does not exist.'));
  const isOwner = Number(t.owner_user_id) === session.userId;
  if (!isOwner && !(need === 'owner-or-admin' && session.role === 'Admin')) {
    toTrip(tripId, 'error', 'Only the traveller who planned this trip can change it.');
  }
  return t;
}

const markChanged = (tripId: number) =>
  pool.query(
    `UPDATE trip SET status = 'draft', feasibility_score = NULL
     WHERE  trip_id = $1 AND status IN ('validated', 'blocked')`,
    [tripId],
  );

// ---------------------------------------------------------------------
//  Plan a new trip: one trip row and one trip_day row per date, saved
//  together in a single transaction.                            (INSERT)
// ---------------------------------------------------------------------
export async function createTrip(formData: FormData) {
  const session = await requireRole('Traveller');
  const title = String(formData.get('title') ?? '').trim();
  const start = String(formData.get('start_date') ?? '');
  const end = String(formData.get('end_date') ?? '') || start;
  const party = Number(formData.get('party_size') ?? 1);
  const budget = formData.get('budget_cap') ? Number(formData.get('budget_cap')) : null;
  const mode = Number(formData.get('mode_id'));
  const base = formData.get('base_destination_id') ? Number(formData.get('base_destination_id')) : null;
  const origin = String(formData.get('origin_city') ?? '').trim() || null;

  const fail = (msg: string): never => redirect(withMessage('/trips', 'error', msg) + '#new');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) fail('Choose the first day of the trip.');
  const days = Math.round((Date.parse(end) - Date.parse(start)) / 86_400_000) + 1;
  if (days > 14) fail('Plan up to 14 days at a time.');

  let tripId = 0;
  try {
    tripId = await inTransaction(async (db) => {
      const trip = await db.query<{ trip_id: string }>(
        `INSERT INTO trip (owner_user_id, primary_mode_id, title, origin_city,
                           start_date, end_date, party_size, budget_cap, status)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'draft')
         RETURNING trip_id`,
        [session.userId, mode, title, origin, start, end, party, budget],
      );
      const id = Number(trip.rows[0].trip_id);
      // One day per date, generated by the database. If the dates are the
      // wrong way round, ck_trip_dates refuses the trip above and nothing
      // at all is saved.
      await db.query(
        `INSERT INTO trip_day (trip_id, day_number, base_destination_id, calendar_date)
         SELECT $1, (g.d::DATE - $2::DATE) + 1, $4, g.d::DATE
         FROM   generate_series($2::DATE, $3::DATE, INTERVAL '1 day') AS g(d)`,
        [id, start, end, base],
      );
      return id;
    });
  } catch (err) {
    fail(friendlyDbError(err));
  }
  revalidatePath('/trips');
  toTrip(tripId, 'ok', 'Trip created. Open Explore and add places to each day.');
}

// ---------------------------------------------------------------------
//  Run the feasibility engine: CALL p_check_trip.
//  The procedure writes a feasibility_run and its violations and updates
//  the trip's score and status, all inside one transaction.
// ---------------------------------------------------------------------
export async function checkTrip(formData: FormData) {
  const session = await requireSession();
  const tripId = Number(formData.get('trip_id'));
  await loadTrip(tripId, session, 'owner-or-admin');

  let summary = '';
  let clean = true;
  try {
    await pool.query('CALL p_check_trip($1)', [tripId]);
    const run = await pool.query<{ blocking_count: number; warning_count: number; feasibility_score: string }>(
      `SELECT blocking_count, warning_count, feasibility_score
       FROM   feasibility_run WHERE trip_id = $1 ORDER BY run_id DESC LIMIT 1`,
      [tripId],
    );
    const r = run.rows[0];
    const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
    clean = r.blocking_count + r.warning_count === 0;
    summary = clean
      ? `Every stop works. Score ${Math.round(Number(r.feasibility_score))}.`
      : `The check found ${plural(r.blocking_count, 'blocking problem')} and ${plural(r.warning_count, 'warning')}. Score ${Math.round(Number(r.feasibility_score))}.`;
  } catch (err) {
    toTrip(tripId, 'error', friendlyDbError(err));
  }
  revalidatePath(`/trips/${tripId}`);
  toTrip(tripId, clean ? 'ok' : 'info', summary);
}

// ---------------------------------------------------------------------
//  Change a stop's times.                                       (UPDATE)
// ---------------------------------------------------------------------
export async function updateStop(formData: FormData) {
  const session = await requireSession();
  const tripId = Number(formData.get('trip_id'));
  const day = Number(formData.get('day_number'));
  const seq = Number(formData.get('stop_seq'));
  const arrive = String(formData.get('arrive') ?? '');
  const leave = String(formData.get('leave') ?? '');
  const t = await loadTrip(tripId, session, 'owner');
  if (!EDITABLE.includes(t.status)) toTrip(tripId, 'error', `This trip is ${t.status}, so its plan can no longer change.`);
  if (!TIME.test(arrive) || !TIME.test(leave)) toTrip(tripId, 'error', 'Enter times like 09:30.');

  try {
    // The date comes from the stop's own day; ck_itinerary_stop_times
    // refuses a leave time before the arrival time.
    await pool.query(
      `UPDATE itinerary_stop s
       SET    planned_arrival   = td.calendar_date + $4::TIME,
              planned_departure = td.calendar_date + $5::TIME
       FROM   trip_day td
       WHERE  td.trip_id = s.trip_id AND td.day_number = s.day_number
         AND  s.trip_id = $1 AND s.day_number = $2 AND s.stop_seq = $3`,
      [tripId, day, seq, arrive, leave],
    );
    await markChanged(tripId);
  } catch (err) {
    toTrip(tripId, 'error', friendlyDbError(err));
  }
  revalidatePath(`/trips/${tripId}`);
  toTrip(tripId, 'ok', 'Times saved. Run the check again to see the effect.');
}

// ---------------------------------------------------------------------
//  Remove a stop.                                               (DELETE)
//  Violations that pointed at it keep their message but lose the stop
//  link (fk_violation_itinerary_stop is ON DELETE SET NULL).
// ---------------------------------------------------------------------
export async function removeStop(formData: FormData) {
  const session = await requireSession();
  const tripId = Number(formData.get('trip_id'));
  const t = await loadTrip(tripId, session, 'owner');
  if (!EDITABLE.includes(t.status)) toTrip(tripId, 'error', `This trip is ${t.status}, so its plan can no longer change.`);
  try {
    await pool.query('DELETE FROM itinerary_stop WHERE trip_id = $1 AND day_number = $2 AND stop_seq = $3', [
      tripId,
      Number(formData.get('day_number')),
      Number(formData.get('stop_seq')),
    ]);
    await markChanged(tripId);
  } catch (err) {
    toTrip(tripId, 'error', friendlyDbError(err));
  }
  revalidatePath(`/trips/${tripId}`);
  toTrip(tripId, 'ok', 'Stop removed.');
}

// ---------------------------------------------------------------------
//  Cancel (UPDATE status) or delete (DELETE, cascading to days, stops,
//  runs and violations through ON DELETE CASCADE).
// ---------------------------------------------------------------------
export async function cancelTrip(formData: FormData) {
  const session = await requireSession();
  const tripId = Number(formData.get('trip_id'));
  const t = await loadTrip(tripId, session, 'owner');
  if (t.status === 'completed') toTrip(tripId, 'error', 'A completed trip cannot be cancelled.');
  await pool.query(`UPDATE trip SET status = 'cancelled', status_note = 'Cancelled by the traveller' WHERE trip_id = $1`, [tripId]);
  revalidatePath(`/trips/${tripId}`);
  toTrip(tripId, 'ok', 'Trip cancelled.');
}

export async function deleteTrip(formData: FormData) {
  const session = await requireSession();
  const tripId = Number(formData.get('trip_id'));
  await loadTrip(tripId, session, 'owner');
  try {
    await pool.query('DELETE FROM trip WHERE trip_id = $1', [tripId]);
  } catch (err) {
    toTrip(tripId, 'error', friendlyDbError(err));
  }
  revalidatePath('/trips');
  redirect(withMessage('/trips', 'ok', 'Trip deleted, with its days, stops and check history.'));
}

// =====================================================================
//  Users (Admin only)
// =====================================================================
// Admin only: suspend or reactivate an account.                  (UPDATE)
// A suspended user can no longer sign in (see login above).
export async function setAccountStatus(formData: FormData) {
  const session = await requireRole('Admin');
  const userId = Number(formData.get('user_id'));
  const status = String(formData.get('status'));

  if (userId === session.userId) redirect(withMessage('/admin', 'error', 'You cannot suspend your own account.'));
  if (status !== 'active' && status !== 'suspended') redirect(withMessage('/admin', 'error', 'Unknown status.'));

  let name = '';
  try {
    const res = await pool.query<{ display_name: string }>(
      'UPDATE user_account SET account_status = $2 WHERE user_id = $1 RETURNING display_name',
      [userId, status],
    );
    name = res.rows[0]?.display_name ?? 'That user';
  } catch (err) {
    redirect(withMessage('/admin', 'error', friendlyDbError(err)));
  }
  revalidatePath('/admin');
  redirect(withMessage('/admin', 'ok', `${name} is now ${status}.`) + '#users');
}
