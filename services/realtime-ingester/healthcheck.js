#!/usr/bin/env node
// Healthy if the newest vehicle sample is younger than 90 seconds.
// That is 6× the 15-second cycle interval — enough slack for a few
// failed TTC fetches or a slow Postgres without triggering a restart.
import pg from 'pg';

const MAX_AGE_S = 90;

async function main() {
  const pool = new pg.Pool({
    connectionString: process.env.DATABASE_URL,
    connectionTimeoutMillis: 3000,
    max: 1,
  });
  try {
    const { rows } = await pool.query(`
      SELECT EXTRACT(EPOCH FROM (now() - max(received_at)))::int AS age_s
      FROM rt.vehicle_latest
    `);
    const age = rows[0]?.age_s ?? 999_999;
    if (age <= MAX_AGE_S) {
      console.log(`ok: newest vehicle ${age}s old`);
      process.exit(0);
    }
    console.error(`stale: newest vehicle ${age}s old (limit ${MAX_AGE_S}s)`);
    process.exit(1);
  } catch (err) {
    console.error('healthcheck failed:', err.message);
    process.exit(1);
  } finally {
    await pool.end().catch(() => {});
  }
}

main();
