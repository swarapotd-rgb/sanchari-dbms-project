import { redirect } from 'next/navigation';
import { getSession } from '@/lib/auth';
import { southMap } from '@/lib/southMap';
import { project } from '@/lib/helpers';
import { LoginForm } from '../components';

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

export default async function LoginPage() {
  if (await getSession()) redirect('/explore'); // already signed in

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
        <div className="login-card">
          <h2>Sign in</h2>
          <p className="hint">Welcome back. Sign in to plan and check your trips.</p>
          <LoginForm />
        </div>
      </section>
    </main>
  );
}
