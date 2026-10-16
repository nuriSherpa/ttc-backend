import { loadConfig } from './config.js';
import { makeLogger } from './logger.js';
import { makePool, waitForPg } from './pg.js';
import { makeRedis } from './redis.js';
import { rebuildGrid, loadGrid } from './grid.js';
import { runLiveSync, runHistorySync } from './sync.js';
import { backfill } from './backfill.js';
import type { GridCell } from './types.js';

const LIVE_MS = 15 * 60_000;
const HIST_MS = 60 * 60_000;

async function main(): Promise<void> {
  const cfg = loadConfig();
  const log = makeLogger(cfg.LOG_LEVEL);
  const backfillMode = process.argv.includes('--backfill');

  log.info({ mode: backfillMode ? 'backfill' : 'loop' }, 'weather service starting');

  const pg = makePool(cfg);
  await waitForPg(pg);
  const redis = makeRedis(cfg);

  const timers: NodeJS.Timeout[] = [];
  const shutdown = async (sig: string): Promise<void> => {
    log.info({ sig }, 'shutting down');
    timers.forEach(clearInterval);
    try {
      await pg.end();
    } catch {
      /* ignore */
    }
    redis.disconnect();
    process.exit(0);
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));

  const refreshGrid = async (): Promise<GridCell[]> => {
    const n = await rebuildGrid(pg);
    log.info({ cells: n }, 'grid rebuilt');
    return loadGrid(pg);
  };

  let cells = await refreshGrid();
  if (cells.length === 0) {
    log.error({}, 'no grid cells — is ref.stop_points populated?');
    process.exit(1);
  }

  if (backfillMode) {
    try {
      await backfill(pg, cells, cfg.BACKFILL_DAYS, log);
      log.info({ days: cfg.BACKFILL_DAYS }, 'backfill complete');
      await pg.end();
      redis.disconnect();
      process.exit(0);
    } catch (err) {
      log.error({ err: String(err) }, 'backfill failed');
      process.exit(1);
    }
  }

  // Overlap guard: a slow run must not stack up behind itself.
  const guarded = (name: string, fn: () => Promise<void>) => {
    let running = false;
    return async (): Promise<void> => {
      if (running) {
        log.warn({ name }, 'previous run still going, skipping');
        return;
      }
      running = true;
      try {
        await fn();
      } catch (err) {
        log.error({ err: String(err), name }, `${name} failed`);
      } finally {
        running = false;
      }
    };
  };

  const live = guarded('live sync', async () => {
    log.info(await runLiveSync(cells, redis, log), 'live sync done');
  });

  let firstHistory = true;
  const history = guarded('history sync', async () => {
    // Pick up newly added stops / cells each hour (cheap, idempotent).
    try {
      const fresh = await refreshGrid();
      if (fresh.length > 0) cells = fresh;
    } catch (err) {
      log.warn({ err: String(err) }, 'grid refresh failed, keeping previous grid');
    }
    // After a restart, look back further so downtime doesn't leave a gap.
    const stats = await runHistorySync(pg, cells, log, firstHistory ? 3 : 1);
    firstHistory = false;
    log.info(stats, 'history sync done');
  });

  await live();
  await history();
  timers.push(setInterval(() => void live(), LIVE_MS));
  timers.push(setInterval(() => void history(), HIST_MS));

  log.info({ live_ms: LIVE_MS, hist_ms: HIST_MS }, 'weather service ready');
}

main().catch((err) => {
  console.error(
    JSON.stringify({
      level: 'error',
      time: new Date().toISOString(),
      err: String(err?.message ?? err),
      stack: err?.stack,
      msg: 'fatal startup error',
    }),
  );
  process.exit(1);
});
