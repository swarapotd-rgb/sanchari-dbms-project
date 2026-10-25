import { southMap } from './southMap';

// =====================================================================
//  Small helpers: formatting, database error messages, map projection.
// =====================================================================

// ---------------- Formatting ----------------
const day = new Intl.DateTimeFormat('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
const date = new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });

// PostgreSQL DATE values arrive as JavaScript Dates at UTC midnight (see
// lib/db.ts), so they are always formatted in UTC to avoid slipping a day.
export const fmtDate = (d: Date) => date.format(d);
export const fmtDay = (d: Date) => day.format(d);

export function fmtRange(a: Date, b: Date) {
  const x = fmtDate(a);
  const y = fmtDate(b);
  return x === y ? x : `${x} to ${y}`;
}

export const isoDate = (d: Date) => d.toISOString().slice(0, 10);

// "09:05:00" -> "09:05"
export const hhmm = (t: string | null | undefined) => (t ? t.slice(0, 5) : '');

export function rupees(n: number | string | null | undefined) {
  if (n === null || n === undefined) return 'Not set';
  const v = Number(n);
  return v === 0 ? 'Free' : '₹' + v.toLocaleString('en-IN', { maximumFractionDigits: 0 });
}

export function minutes(n: number | string) {
  const m = Math.round(Number(n));
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return m % 60 ? `${h} h ${m % 60} min` : `${h} h`;
}

export const PLACE_TYPES = [
  'beach', 'fort', 'garden', 'heritage', 'lake', 'market', 'museum',
  'temple', 'trail', 'viewpoint', 'waterfall', 'wildlife',
] as const;

export const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

// Builds "/path?error=..." for server actions that send the user back.
export function withMessage(path: string, kind: 'error' | 'ok' | 'info', text: string) {
  const sep = path.includes('?') ? '&' : '?';
  return `${path}${sep}${kind}=${encodeURIComponent(text)}`;
}

// ---------------- Database errors -> readable messages ----------------
// Turns PostgreSQL errors into sentences a traveller can act on.
//
// The rules themselves live in the database (CHECK, UNIQUE, FOREIGN KEY and
// the trigger). The app does not repeat them; it only translates the error
// the database raises, and names the rule so it can be pointed at in a demo.

const BY_CONSTRAINT: Record<string, string> = {
  ck_itinerary_stop_times: 'Leave time must be after arrival time.',
  ck_itinerary_stop_cost: 'A stop’s cost cannot be negative.',
  pk_itinerary_stop: 'That stop already exists on this day.',
  ck_trip_dates: 'The last day must be on or after the first day.',
  ck_trip_party_size: 'Party size must be at least 1.',
  ck_trip_budget: 'Budget cannot be negative.',
  ck_trip_title_not_blank: 'Give the trip a name.',
  ck_trip_day_window: 'The day must end after it starts.',
  uq_trip_day_date: 'This trip already has a day on that date.',
  ck_review_summary_rating: 'Rating must be between 1 and 5.',
  ck_review_summary_crowd: 'Crowd level must be between 1 and 5.',
  ck_review_summary_duration: 'Time spent must be more than 0 minutes.',
  uq_review_summary_visit: 'You have already reviewed this place for that visit date.',
  ck_place_fees: 'Entry fees cannot be negative.',
  ck_place_visit_minutes: 'Typical visit time must be more than 0 minutes.',
  ck_place_short_description: 'The description needs at least 10 characters.',
  fk_itinerary_stop_place: 'This place is part of a planned trip, so it cannot be removed.',
};

type PgError = { code?: string; constraint?: string; message?: string };

export function friendlyDbError(err: unknown): string {
  const e = (err ?? {}) as PgError;
  if (e.constraint && BY_CONSTRAINT[e.constraint]) {
    return `${BY_CONSTRAINT[e.constraint]} (database rule ${e.constraint})`;
  }
  // Errors raised by our own trigger and procedure carry their own wording.
  if (e.code === 'P0001' && e.message) return e.message;
  if (e.code === '22P02' || e.code === '22007' || e.code === '22008') {
    return 'One of the values is not in the right format.';
  }
  if (e.code === 'ECONNREFUSED' || e.code === '57P01') {
    return 'Could not reach the database. Check that the sanchari-db container is running.';
  }
  console.error('Unhandled database error:', err);
  return e.constraint
    ? `The database refused this change (rule ${e.constraint}).`
    : 'The database refused this change.';
}

// ---------------- Map ----------------
export type StateShape = (typeof southMap.states)[number];

export const STATES = southMap.states;

export function stateBySlug(slug: string): StateShape | undefined {
  return STATES.find((s) => s.slug === slug);
}

export function slugOf(stateName: string): string {
  return stateName.toLowerCase().replace(/ /g, '-');
}

// The same projection used to draw the outlines in southMap.ts, so a
// destination's latitude and longitude land in the right spot on the map.
export function project(lon: number, lat: number): [number, number] {
  const x = (lon - southMap.minLon) * southMap.cosLat * southMap.scale;
  const y = (southMap.maxLat - lat) * southMap.scale;
  return [Math.round(x * 10) / 10, Math.round(y * 10) / 10];
}
