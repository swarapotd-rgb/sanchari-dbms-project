import { SignJWT, jwtVerify } from 'jose';
import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';

// =====================================================================
//  Login sessions and role checks.
// =====================================================================

// The login session is a signed token in an httpOnly cookie. It holds only
// who the user is and their role; nothing secret. The signature stops anyone
// from editing the cookie to change their role.

export const SESSION_COOKIE = 'sanchari_session';
const SESSION_HOURS = 8;

export type Role = 'Traveller' | 'Curator' | 'Admin';

export type Session = {
  userId: number;
  name: string;
  email: string;
  role: Role;
};

function secretKey(): Uint8Array {
  const secret = process.env.SESSION_SECRET;
  if (!secret || secret.length < 32) {
    throw new Error('SESSION_SECRET must be set in .env.local (at least 32 characters).');
  }
  return new TextEncoder().encode(secret);
}

export async function createSessionToken(session: Session): Promise<string> {
  return new SignJWT({ ...session })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime(`${SESSION_HOURS}h`)
    .sign(secretKey());
}

export async function readSessionToken(token: string | undefined): Promise<Session | null> {
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, secretKey());
    return {
      userId: Number(payload.userId),
      name: String(payload.name),
      email: String(payload.email),
      role: payload.role as Role,
    };
  } catch {
    return null; // expired, tampered with, or signed with another secret
  }
}

export const sessionCookieOptions = {
  httpOnly: true,
  sameSite: 'lax' as const,
  secure: process.env.NODE_ENV === 'production',
  path: '/',
  maxAge: SESSION_HOURS * 60 * 60,
};

export async function getSession(): Promise<Session | null> {
  const jar = await cookies();
  return readSessionToken(jar.get(SESSION_COOKIE)?.value);
}

// Called at the top of every page and every action. Not signed in -> /login.
// Actions check too, because an action can be called without loading its page.
export async function requireSession(): Promise<Session> {
  const session = await getSession();
  if (!session) redirect('/login');
  return session;
}

// Authorisation: the user must hold one of the listed roles.
export async function requireRole(...roles: Role[]): Promise<Session> {
  const session = await requireSession();
  if (!roles.includes(session.role)) redirect('/explore?error=' + encodeURIComponent('That page is only for ' + roles.join(' or ') + ' accounts.'));
  return session;
}

export const isStaff = (s: Session) => s.role === 'Admin' || s.role === 'Curator';
