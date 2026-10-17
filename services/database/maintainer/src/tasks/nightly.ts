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
  } catch (err) {
    log.error({ err: String((err as Error).message) }, 'nightly failed');
    throw err;
  }

  // Walk calibration: independent of feed/GTFS work. Non-fatal.
  try {
    const { rows } = await pg.query<{ calibrate: unknown }>(
      'SELECT app.calibrate_walks() AS calibrate',
    );
    log.info({ calibrate: rows[0]?.calibrate }, 'walk calibration complete');
  } catch (err) {
    log.error({ err: String((err as Error).message) }, 'walk calibration failed');
  }

  await state.update({ last_nightly_at: new Date().toISOString() });
}
