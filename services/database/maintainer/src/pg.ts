import pg from 'pg';
import type { Config } from './config.js';

export function makePool(cfg: Config): pg.Pool {
  return new pg.Pool({
    host: cfg.PGHOST,
    user: cfg.PGUSER,
    password: cfg.PGPASSWORD,
    database: cfg.PGDATABASE,
    max: 4,
    idleTimeoutMillis: 5_000,
    connectionTimeoutMillis: 5_000,
  });
}

export async function waitForPg(pool: pg.Pool, timeoutMs = 60_000): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      await pool.query('SELECT 1');
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 1_000));
    }
  }
  throw new Error('postgres did not become reachable in time');
}

export async function getActiveFeedVersion(pool: pg.Pool): Promise<string | null> {
  const { rows } = await pool.query<{ feed_version: string }>(
    `SELECT feed_version FROM ops.feed WHERE source = 'ttc'`,
  );
  return rows[0]?.feed_version ?? null;
}

export async function runMaintain(pool: pg.Pool): Promise<unknown> {
  const { rows } = await pool.query<{ report: unknown }>('SELECT ops.maintain() AS report');
  return rows[0]?.report ?? null;
}
