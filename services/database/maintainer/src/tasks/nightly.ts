import type { Pool } from 'pg';
import type { Logger } from '../logger.js';
import type { StateStore } from '../state.js';

export async function runNightly(pg: Pool, state: StateStore, log: Logger): Promise<void> {
  log.info({}, 'nightly starting');
  try {
    const { rows } = await pg.query<{ run_nightly: unknown }>(
      'SELECT ops.run_nightly() AS run_nightly',
    );
    log.info({ report: rows[0]?.run_nightly }, 'nightly complete');
    await state.update({ last_nightly_at: new Date().toISOString() });
  } catch (err) {
    log.error({ err: String((err as Error).message) }, 'nightly failed');
    throw err;
  }
}
