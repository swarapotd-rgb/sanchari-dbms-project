import { Pool, types, type PoolClient } from 'pg';
import { MongoClient, ObjectId, type Collection } from 'mongodb';

// =====================================================================
//  Both database connections live in this one file.
//  PostgreSQL: places, trips, users, the feasibility engine.
//  MongoDB:    the written part of each review (optional).
//  Addresses and passwords come from .env.local, never from the code.
// =====================================================================

// ---------------- PostgreSQL ----------------
// DATE columns: keep them as UTC midnight so a date never shifts by a day
// depending on the laptop's time zone. (By default pg reads them as local
// midnight, which turns 22 Aug into 21 Aug 18:30 UTC in India.)
types.setTypeParser(1082, (v: string) => new Date(v + 'T00:00:00Z'));

// One pool for the whole server. In development Next.js reloads modules on
// every save, so the pool is parked on globalThis to avoid opening a new set
// of connections each time.
const globalForPg = globalThis as unknown as { sanchariPool?: Pool };

export const pool =
  globalForPg.sanchariPool ??
  new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 5,
  });

if (process.env.NODE_ENV !== 'production') globalForPg.sanchariPool = pool;

// Runs several statements as ONE transaction: all of them are saved, or,
// if any fails, none of them are (ROLLBACK).
export async function inTransaction<T>(work: (db: PoolClient) => Promise<T>): Promise<T> {
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    const result = await work(db);
    await db.query('COMMIT');
    return result;
  } catch (err) {
    await db.query('ROLLBACK');
    throw err;
  } finally {
    db.release();
  }
}

// ---------------- MongoDB ----------------
// MongoDB holds the written part of each review (title, text, aspects, tags).
// It is optional for the app: if MONGODB_URI is not set or the container is
// not running, pages still work and simply show the ratings from PostgreSQL.

export type ReviewDoc = {
  _id: ObjectId;
  review_id: number;
  place_id: number;
  user_id: number;
  place: { name: string; type: string; destination: string; state: string };
  author: { display_name: string };
  rating: number;
  visited_on: Date;
  title: string;
  body: string;
  aspects: Record<string, number>;
  tags: string[];
  tip?: string;
  created_at: Date;
};

const globalForMongo = globalThis as unknown as { sanchariMongo?: Promise<MongoClient> };

async function client(): Promise<MongoClient | null> {
  const uri = process.env.MONGODB_URI;
  if (!uri) return null;
  if (!globalForMongo.sanchariMongo) {
    globalForMongo.sanchariMongo = new MongoClient(uri, {
      serverSelectionTimeoutMS: 1500,
      connectTimeoutMS: 1500,
    }).connect();
    // If the first connection fails, forget it so the next request retries.
    globalForMongo.sanchariMongo.catch(() => {
      globalForMongo.sanchariMongo = undefined;
    });
  }
  return globalForMongo.sanchariMongo;
}

export async function reviewsCollection(): Promise<Collection<ReviewDoc> | null> {
  try {
    const c = await client();
    return c ? c.db(process.env.MONGODB_DB || 'sanchari').collection<ReviewDoc>('reviews') : null;
  } catch {
    return null;
  }
}


export { ObjectId };
