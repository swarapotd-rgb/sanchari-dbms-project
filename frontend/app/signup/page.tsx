import { redirect } from 'next/navigation';
import { getSession } from '@/lib/auth';
import { AuthPage, SignupForm } from '../components';

// New travellers create their own account here. The account is saved by
// the signup action in app/actions.ts.
export default async function SignupPage() {
  if (await getSession()) redirect('/explore'); // already signed in

  return (
    <AuthPage>
      <h2>Create an account</h2>
      <p className="hint">Join Sanchari to plan trips and check that every stop works.</p>
      <SignupForm />
    </AuthPage>
  );
}
