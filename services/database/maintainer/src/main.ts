import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { loadConfig } from './config.js';
import { makeLogger } from './logger.js';
import { StateStore } from './state.js';
import { makePool, waitForPg } from './pg.js';
import { getRedis, closeRedis } from './redis.js';
import { ensureStaticExport } from './export/index.js';
import { runUpdateCheck } from './tasks/update-check.js';
import { runMaintainTask } from './tasks/maintain.js';

async function safe(label: string, fn: () => Promise<void>, log: ReturnType<typeof makeLogger>) {
  try {
    await fn();
  } catch (err) {
    log.error({ task: label, err: String((err as Error).message) }, 'task failed');
  }
}

async function heartbeat(cfg: ReturnType<typeof loadConfig>) {
  try {
    await writeFile(join(cfg.STATE_DIR, 'heartbeat'), new Date().toISOString());
  } catch {
    /* best effort */
  }
}

async function main() {
  const cfg = loadConfig();
  const log = makeLogger(cfg.LOG_LEVEL);

  // Manual export mode: run once, exit. Used for the first-ever export
  // and for debugging without waiting for an update-check tick.
  if (process.argv.includes('--export-static')) {
    const pg = makePool(cfg);
    const redis = getRedis(cfg);
    try {
      await waitForPg(pg);
      const result = await ensureStaticExport(pg, redis, log);
      log.info(result, 'manual static export done');
      await closeRedis();
      await pg.end();
      process.exit(0);
    } catch (err) {
      log.error({ err: String((err as Error).message) }, 'manual static export failed');
      process.exit(1);
    }
  }
  log.info(
    {
      update_check_hours: cfg.UPDATE_CHECK_HOURS,
      maintain_hours: cfg.MAINTAIN_HOURS,
      activate_days_before_start: cfg.ACTIVATE_DAYS_BEFORE_START,
      ckan_package: cfg.CKAN_PACKAGE,
    },
    'maintainer starting',
  );

  const state = new StateStore(cfg.STATE_DIR);
  await state.load();
  log.info({ state: state.get() }, 'state loaded');

  const pg = makePool(cfg);
  await waitForPg(pg);
  log.info({}, 'postgres reachable');

  const redis = getRedis(cfg);
  log.info({}, 'redis client initialised');

  // Run both tasks once at startup, sequentially so their logs don't interleave.
  await safe('update-check', () => runUpdateCheck(cfg, pg, redis, state, log), log);
  await safe('maintain', () => runMaintainTask(pg, state, log), log);
  await heartbeat(cfg);

  // Schedule periodic runs.
  const updateMs = cfg.UPDATE_CHECK_HOURS * 3_600_000;
  const maintainMs = cfg.MAINTAIN_HOURS * 3_600_000;

  setInterval(
    () =>
      safe(
        'update-check',
        async () => {
          await runUpdateCheck(cfg, pg, redis, state, log);
          await heartbeat(cfg);
        },
        log,
      ),
    updateMs,
  );

  setInterval(
    () =>
      safe(
        'maintain',
        async () => {
          await runMaintainTask(pg, state, log);
          await heartbeat(cfg);
        },
        log,
      ),
    maintainMs,
  );

  // Write a heartbeat every minute so the healthcheck stays green even
  // when both tasks are between ticks.
  setInterval(() => heartbeat(cfg), 60_000);

  // Graceful shutdown.
  const shutdown = async (sig: string) => {
    log.info({ sig }, 'shutting down');
    try {
      await closeRedis();
      await pg.end();
    } catch {}
    process.exit(0);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  log.info({}, 'maintainer ready');
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
