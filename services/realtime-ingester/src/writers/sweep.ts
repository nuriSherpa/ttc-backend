import type { Pool } from 'pg';

export async function sweepStale(pg: Pool): Promise<void> {
  await pg.query('SELECT rt.sweep_stale()');
}
