'use client';

import Link from 'next/link';
import { useState, useActionState } from 'react';
import { usePathname } from 'next/navigation';
import { useFormStatus } from 'react-dom';
import { southMap } from '@/lib/southMap';
import { cap, project } from '@/lib/helpers';
import { login, signup, type LoginState, type SignupState } from './actions';

// =====================================================================
//  The pieces of the screen that run in the browser: navigation links,
//  the map, the sign-in and sign-up page, the submit button, the search
//  form and the message banner.
// =====================================================================

// ---------------- Navigation links ----------------
type NavLink = { href: string; label: string };

export function NavLinks({ links }: { links: NavLink[] }) {
  const path = usePathname();
  // Highlight the link for the section we are in (place pages count as Explore).
  const current = links
    .filter((l) => path === l.href || path.startsWith(l.href + '/') || (l.href === '/explore' && path.startsWith('/places/')))
    .sort((a, b) => b.href.length - a.href.length)[0]?.href;

  return (
    <nav className="nav" aria-label="Main">
      {links.map((l) => (
        <Link key={l.href} href={l.href} aria-current={l.href === current ? 'page' : undefined}>
          {l.label}
        </Link>
      ))}
    </nav>
  );
}

// ---------------- The map ----------------
export type StateStat = { destinations: number; places: number; rating: string | null; topTypes: string };
export type Dot = { name: string; state: string; x: number; y: number };

// Fill shade follows how many places a state has, so the map also reads as
// a quick picture of where Sanchari's data is richest.
const RAMP = ['#e6d6bd', '#d9c19c', '#c9a77a', '#b98d5c'];

function shade(places: number, max: number) {
  if (max === 0) return RAMP[0];
  const i = Math.min(RAMP.length - 1, Math.floor((places / max) * RAMP.length - 0.0001));
  return RAMP[Math.max(0, i)];
}

// Puducherry is too small to label inside its outline, so its name sits in
// the sea with a short line pointing at it.
const CALLOUTS: Record<string, { x: number; y: number; anchor: 'start' | 'middle' | 'end' }> = {
  Puducherry: { x: 640, y: 770, anchor: 'middle' },
  Goa: { x: 8, y: 470, anchor: 'start' },
  Kerala: { x: 150, y: 880, anchor: 'end' },
};

const CONTEXT_LABELS: Record<string, [number, number]> = {
  Maharashtra: [150, 90],
  Chhattisgarh: [640, 40],
};

export function SouthIndiaMap({
  stats,
  dots,
  totalPlaces,
}: {
  stats: Record<string, StateStat>;
  dots: Dot[];
  totalPlaces: number;
}) {
  const [hot, setHot] = useState<string | null>(null);
  const max = Math.max(...Object.values(stats).map((s) => s.places));
  const states = [...southMap.states].sort((a, b) => a.name.localeCompare(b.name));
  const hotStat = hot ? stats[hot] : null;

  return (
    <div className="explore">
      <section className="explore-intro" aria-labelledby="explore-title">
        <h1 id="explore-title">Where do you want to go?</h1>
        <p>
          {totalPlaces} places across seven states and union territories. Pick one to search its
          destinations, opening hours and reviews.
        </p>

        <ul className="state-list">
          {states.map((s) => {
            const st = stats[s.name];
            return (
              <li key={s.slug}>
                <Link
                  href={`/explore/${s.slug}`}
                  className={hot === s.name ? 'is-hot' : undefined}
                  onMouseEnter={() => setHot(s.name)}
                  onMouseLeave={() => setHot(null)}
                  onFocus={() => setHot(s.name)}
                  onBlur={() => setHot(null)}
                >
                  <span className="name">{s.name}</span>
                  <span className="count">{st ? `${st.places} places` : 'No places yet'}</span>
                  {st && <span className="types">{cap(st.topTypes)}</span>}
                </Link>
              </li>
            );
          })}
        </ul>
      </section>

      <section className="explore-map" aria-label="Map of the southern states">
        <div className="map-frame">
          <svg
            className="map-svg"
            viewBox={`0 0 ${southMap.width} ${southMap.height}`}
            role="img"
            aria-label="Map of Karnataka, Kerala, Tamil Nadu, Puducherry, Andhra Pradesh, Telangana and Goa. Select a state to explore it."
          >
            {southMap.context.map((c) => (
              <path key={c.name} d={c.d} className="map-context" />
            ))}
            {Object.entries(CONTEXT_LABELS).map(([name, [x, y]]) => (
              <text key={name} x={x} y={y} className="map-context-label" textAnchor="middle">
                {name}
              </text>
            ))}

            {southMap.states.map((s) => (
              <a
                key={s.slug}
                href={`/explore/${s.slug}`}
                className="map-state-link"
                aria-label={`${s.name}: ${stats[s.name]?.places ?? 0} places`}
                onMouseEnter={() => setHot(s.name)}
                onMouseLeave={() => setHot(null)}
                onFocus={() => setHot(s.name)}
                onBlur={() => setHot(null)}
              >
                <path
                  d={s.d}
                  className={`map-state${hot === s.name ? ' is-hot' : ''}`}
                  style={{ fill: shade(stats[s.name]?.places ?? 0, max) }}
                />
              </a>
            ))}

            {dots.map((d) => (
              <circle key={d.name} cx={d.x} cy={d.y} r={4.2} className="map-dot">
                <title>{d.name}</title>
              </circle>
            ))}

            {southMap.states.map((s) => {
              const call = CALLOUTS[s.name];
              const isHot = hot === s.name;
              if (call) {
                return (
                  <g key={s.slug}>
                    <line x1={s.labelX} y1={s.labelY} x2={call.anchor === 'end' ? call.x + 4 : call.x} y2={call.y - 6} className="map-callout-line" />
                    <text x={call.x} y={call.y + 12} className={`map-label${isHot ? ' is-callout-hot' : ''}`} textAnchor={call.anchor}>
                      {s.name}
                    </text>
                  </g>
                );
              }
              return (
                <text
                  key={s.slug}
                  x={s.labelX}
                  y={s.labelY}
                  className={`map-label${isHot ? ' is-hot' : ''}`}
                  textAnchor="middle"
                >
                  {s.name}
                </text>
              );
            })}
          </svg>

          {hot && hotStat && (
            <div className="map-tip" aria-hidden="true">
              <strong>{hot}</strong>
              <span>
                {hotStat.destinations} destinations, {hotStat.places} places
                {hotStat.rating ? `, rated ${hotStat.rating} on average` : ''}
              </span>
            </div>
          )}
        </div>

        <div className="map-legend" aria-hidden="true">
          <span>Fewer places</span>
          <span className="ramp">
            {RAMP.map((c) => (
              <span key={c} style={{ background: c }} />
            ))}
          </span>
          <span>More places</span>
          <span style={{ width: '1rem' }} />
          <span className="dot" /> <span>Destination</span>
        </div>
      </section>
    </div>
  );
}

// ---------------- Sign-in / sign-up page layout ----------------
// Both pages share the brown travel panel on the left and differ only in
// the form on the right.

// A sample journey across South India, drawn on the same map as the Explore page.
// [name, latitude, longitude, label position: dx, dy, text anchor]
const ROUTE: [string, number, number, number, number, 'start' | 'middle' | 'end'][] = [
  ['Goa', 15.58, 73.75, 14, -12, 'start'],
  ['Hampi', 15.335, 76.46, 16, 8, 'start'],
  ['Bengaluru', 12.9716, 77.5946, 16, 8, 'start'],
  ['Mysuru', 12.354, 76.656, 0, 34, 'middle'],
  ['Coorg', 12.4244, 75.7382, -16, 8, 'end'],
  ['Kochi', 9.9658, 76.2421, -16, 8, 'end'],
  ['Munnar', 10.0889, 77.0595, 0, -18, 'middle'],
  ['Madurai', 9.9252, 78.1198, 16, 8, 'start'],
  ['Puducherry', 11.9416, 79.8083, 16, 8, 'start'],
];

export function AuthPage({ children }: { children: React.ReactNode }) {
  const stops = ROUTE.map(([name, lat, lon, dx, dy, anchor]) => {
    const [x, y] = project(lon, lat);
    return { name, x, y, dx, dy, anchor };
  });
  const path = stops.map((s, i) => `${i === 0 ? 'M' : 'L'}${s.x.toFixed(1)},${s.y.toFixed(1)}`).join(' ');

  return (
    <main className="login">
      <section className="login-story" aria-label="What Sanchari does">
        <div className="wordmark">Sanchari</div>
        <div>
          <h1>Plan South India. Know it will work.</h1>
          <p className="lede">
            From the beaches of Goa to the temples of Madurai: build your trip day by day, and
            Sanchari checks every stop against opening hours, closures, travel time, daylight
            and budget.
          </p>
        </div>
        <svg className="journey" viewBox="0 330 760 700" role="img" aria-label="A sample route through Goa, Hampi, Bengaluru, Mysuru, Coorg, Kochi, Munnar, Madurai and Puducherry">
          {southMap.states.map((s) => (
            <path key={s.slug} d={s.d} className="journey-land" />
          ))}
          <path d={path} className="journey-route" pathLength={1} />
          {stops.map((s) => (
            <g key={s.name}>
              <circle cx={s.x} cy={s.y} r={7} className="journey-stop" />
              <text x={s.x + s.dx} y={s.y + s.dy} textAnchor={s.anchor} className="journey-label">
                {s.name}
              </text>
            </g>
          ))}
        </svg>
        <p className="journey-caption">49 destinations and 358 places across seven states.</p>
      </section>

      <section className="login-form-side">
        <div className="login-card">{children}</div>
      </section>
    </main>
  );
}

// ---------------- Login form ----------------
const initialState: LoginState = { error: null, email: '' };

export function LoginForm() {
  const [state, formAction, pending] = useActionState(login, initialState);

  return (
    <form action={formAction} noValidate>
      {state.error && (
        <p className="form-error" role="alert">
          {state.error}
        </p>
      )}

      <div className="field">
        <label htmlFor="email">Email</label>
        <input
          id="email"
          name="email"
          type="email"
          autoComplete="username"
          defaultValue={state.email}
          required
          autoFocus
        />
      </div>

      <div className="field">
        <label htmlFor="password">Password</label>
        <input
          id="password"
          name="password"
          type="password"
          autoComplete="current-password"
          required
        />
      </div>

      <button className="btn btn-primary btn-block" type="submit" disabled={pending}>
        {pending ? 'Signing in…' : 'Sign in'}
      </button>

      <p className="switch-auth">
        New to Sanchari? <Link href="/signup">Create an account</Link>
      </p>
    </form>
  );
}

// ---------------- Sign-up form ----------------
const signupInitial: SignupState = { error: null, name: '', email: '', city: '' };

export function SignupForm() {
  const [state, formAction, pending] = useActionState(signup, signupInitial);

  return (
    <form action={formAction} noValidate>
      {state.error && (
        <p className="form-error" role="alert">
          {state.error}
        </p>
      )}

      <div className="field">
        <label htmlFor="name">Your name</label>
        <input id="name" name="name" autoComplete="name" defaultValue={state.name} maxLength={80} required autoFocus />
      </div>

      <div className="field">
        <label htmlFor="email">Email</label>
        <input id="email" name="email" type="email" autoComplete="email" defaultValue={state.email} maxLength={120} required />
      </div>

      <div className="field">
        <label htmlFor="city">Home city <span className="optional">(optional)</span></label>
        <input id="city" name="city" autoComplete="address-level2" defaultValue={state.city} maxLength={60} placeholder="Bengaluru" />
      </div>

      <div className="field">
        <label htmlFor="password">Password</label>
        <input id="password" name="password" type="password" autoComplete="new-password" minLength={8} required />
        <span className="field-hint">At least 8 characters.</span>
      </div>

      <div className="field">
        <label htmlFor="confirm">Confirm password</label>
        <input id="confirm" name="confirm" type="password" autoComplete="new-password" required />
      </div>

      <button className="btn btn-primary btn-block" type="submit" disabled={pending}>
        {pending ? 'Creating account…' : 'Create account'}
      </button>

      <p className="switch-auth">
        Already have an account? <Link href="/login">Sign in</Link>
      </p>
    </form>
  );
}

// ---------------- Submit button ----------------
// A submit button that disables itself and changes its label while the
// server action runs, so a slow database call is not submitted twice.
export function SubmitButton({
  children,
  pending,
  className = 'btn btn-primary',
  confirm,
}: {
  children: React.ReactNode;
  pending: string;
  className?: string;
  confirm?: string;
}) {
  const status = useFormStatus();
  return (
    <button
      type="submit"
      className={className}
      disabled={status.pending}
      onClick={(e) => {
        if (confirm && !window.confirm(confirm)) e.preventDefault();
      }}
    >
      {status.pending ? pending : children}
    </button>
  );
}

// ---------------- Search form ----------------
// A normal GET search form, except that changing a dropdown applies it
// straight away, so the results always match the filters on screen.
export function AutoSubmitForm({ className, children }: { className?: string; children: React.ReactNode }) {
  return (
    <form
      className={className}
      method="get"
      role="search"
      onChange={(e) => {
        if (e.target instanceof HTMLSelectElement) e.currentTarget.requestSubmit();
      }}
    >
      {children}
    </form>
  );
}

// ---------------- Message banner ----------------
// Shows the result of the last form a server action handled. Actions send
// the user back with ?ok=... or ?error=... in the address.
export function Notice({ params }: { params: { ok?: string; error?: string; info?: string } }) {
  if (params.error) {
    return (
      <p className="notice notice-error" role="alert">
        {params.error}
      </p>
    );
  }
  if (params.ok) {
    return (
      <p className="notice notice-ok" role="status">
        {params.ok}
      </p>
    );
  }
  if (params.info) {
    return (
      <p className="notice notice-warn" role="status">
        {params.info}
      </p>
    );
  }
  return null;
}
