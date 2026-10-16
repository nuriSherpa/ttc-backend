import pg from 'pg';
import type { Config } from './config.js';

export function makePool(cfg: Config): pg.Pool {
  const pool = new pg.Pool({
    host: cfg.PGHOST,
    user: cfg.PGUSER,
    password: cfg.PGPASSWORD,
    database: cfg.PGDATABASE,
    max: 4,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
  });
  // Without a handler, an idle-client error would crash the process.
  pool.on('error', (err) => {
    console.error(JSON.stringify({ level: 'error', msg: 'pg pool error', err: String(err) }));
  });
  return pool;
}

export async function waitForPg(pool: pg.Pool, attempts = 30, delayMs = 2000): Promise<void> {
  let last: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      await pool.query('SELECT 1');
      return;
    } catch (err) {
      last = err;
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw new Error(`postgres not reachable: ${String(last)}`);
}
