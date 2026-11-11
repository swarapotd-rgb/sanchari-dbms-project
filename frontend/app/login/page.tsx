import { redirect } from 'next/navigation';
import { getSession } from '@/lib/auth';
import { AuthPage, LoginForm } from '../components';

export default async function LoginPage() {
  if (await getSession()) redirect('/explore'); // already signed in

  return (
    <AuthPage>
      <h2>Sign in</h2>
      <p className="hint">Welcome back. Sign in to plan and check your trips.</p>
      <LoginForm />
    </AuthPage>
  );
}
