import { redirect } from 'next/navigation';
import { getSession } from '@/lib/auth';
import { LoginForm } from '../components';

// Test trip 27 from the seed data, exactly as the feasibility engine sees it.
const exampleDay = [
  { time: '08:00', name: 'Raja’s Seat', note: 'Open, and in daylight' },
  { time: '10:00', name: 'Madikeri Fort', note: '7 min drive, 75 min allowed' },
  { time: '11:20', name: 'Madikeri Museum', problem: 'Closed on Mondays' },
];

export default async function LoginPage() {
  if (await getSession()) redirect('/explore'); // already signed in
  return (
    <main className="login">
      <section className="login-story" aria-label="What Sanchari does">
        <div className="wordmark">Sanchari</div>

        <div>
          <h1>Will this day actually work?</h1>
          <p className="lede">
            Sanchari checks every stop of your plan against opening hours, closures, travel
            time, daylight and budget, then tells you exactly which stop breaks it.
          </p>
        </div>

        <div>
          <p className="route-day">Coorg, Monday 14 December</p>
          <ol className="route">
            {exampleDay.map((stop) => (
              <li key={stop.name} className={`stop${stop.problem ? ' is-broken' : ''}`}>
                <span className="stop-time">{stop.time}</span>
                <span className="stop-track" aria-hidden="true">
                  <span className="stop-dot" />
                </span>
                <span>
                  <span className="stop-name">{stop.name}</span>
                  {stop.problem ? (
                    <>
                      <br />
                      <span className="verdict">{stop.problem}</span>
                    </>
                  ) : (
                    <span className="stop-ok">{stop.note}</span>
                  )}
                </span>
              </li>
            ))}
          </ol>
        </div>
      </section>

      <section className="login-form-side">
        <div className="login-card">
          <h2>Sign in</h2>
          <p className="hint">Use your Sanchari account to plan and check trips.</p>

          <LoginForm />

          <div className="demo-accounts">
            <p>
              Demo accounts. Every password is <code>Sanchari@2026</code>.
            </p>
            <ul>
              <li>
                Traveller: <code>ananya.rao@example.com</code>
              </li>
              <li>
                Curator: <code>rahul.hegde@example.com</code>
              </li>
              <li>
                Admin: <code>admin@example.com</code>
              </li>
            </ul>
          </div>
        </div>
      </section>
    </main>
  );
}
