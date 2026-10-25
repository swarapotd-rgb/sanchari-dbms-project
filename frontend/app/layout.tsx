import Link from 'next/link';
import type { Metadata } from 'next';
import { getSession, isStaff } from '@/lib/auth';
import { logout } from './actions';
import { NavLinks } from './components';
import './globals.css';

export const metadata: Metadata = {
  title: 'Sanchari',
  description: 'Plan trips across South India and check, stop by stop, whether the plan can actually be done.',
};

// Wraps every page. Signed-in users get the top bar; the links depend on
// the role. (Each page still checks the login itself with requireSession.)
export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const session = await getSession();

  const links = [
    { href: '/explore', label: 'Explore' },
    { href: '/trips', label: session?.role === 'Traveller' ? 'My trips' : 'All trips' },
  ];
  if (session && isStaff(session)) links.push({ href: '/admin', label: 'Overview' });

  return (
    <html lang="en">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Figtree:wght@400;500;600;700&display=swap" />
      </head>
      <body>
        {session ? (
          <>
            <header className="topbar">
              <Link href="/explore" className="wordmark">Sanchari</Link>
              <NavLinks links={links} />
              <div className="who">
                <span>{session.name}</span>
                <span className="tag">{session.role}</span>
                <form action={logout}>
                  <button className="btn btn-ghost btn-small" type="submit">Sign out</button>
                </form>
              </div>
            </header>
            <main className="page">{children}</main>
          </>
        ) : (
          children
        )}
      </body>
    </html>
  );
}
