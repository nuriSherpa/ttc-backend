import type { Pool } from 'pg';
import type { Logger } from '../logger.js';
import type { StateStore } from '../state.js';
import { runMaintain } from '../pg.js';

export async function runMaintainTask(pg: Pool, state: StateStore, log: Logger): Promise<void> {
  log.info({}, 'maintain starting');
  try {
    const report = await runMaintain(pg);
    log.info({ report }, 'maintain complete');
    await state.update({
      last_maintain_at: new Date().toISOString(),
      last_maintain_result: report,
    });
  } catch (err) {
    log.error({ err: String((err as Error).message) }, 'maintain failed');
    throw err;
  }
}
