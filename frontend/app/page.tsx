import { redirect } from 'next/navigation';

// The home page just opens the map (which sends signed-out visitors to /login).
export default function Home() {
  redirect('/explore');
}
