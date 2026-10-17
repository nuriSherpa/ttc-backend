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
import { runNightly } from './tasks/nightly.js';

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

/**
 * Milliseconds until the next 03:00 in America/Toronto.
 * Handles DST correctly because Intl.DateTimeFormat knows the current offset.
 */
function msUntilNext3amToronto(): number {
  const now = new Date();
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Toronto',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  });
  const parts = Object.fromEntries(fmt.formatToParts(now).map((p) => [p.type, p.value]));
  const hour = Number(parts.hour);
  const minute = Number(parts.minute);
  const second = Number(parts.second);

  const msNow = (hour * 3600 + minute * 60 + second) * 1000;
  const msTarget = 3 * 3600 * 1000; // 03:00:00

  if (msNow < msTarget) return msTarget - msNow;
  return 24 * 3600 * 1000 - msNow + msTarget;
}

async function main() {
  const cfg = loadConfig();
  const log = makeLogger(cfg.LOG_LEVEL);

  // Manual export mode: run once, exit.
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

  // Manual nightly mode: run once, exit. Useful for testing.
  if (process.argv.includes('--nightly')) {
    const pg = makePool(cfg);
    const state = new StateStore(cfg.STATE_DIR);
    await state.load();
    try {
      await waitForPg(pg);
      await runNightly(pg, state, log);
      await pg.end();
      process.exit(0);
    } catch (err) {
      log.error({ err: String((err as Error).message) }, 'manual nightly failed');
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

  // Run update-check + maintain once at startup, sequentially.
  await safe('update-check', () => runUpdateCheck(cfg, pg, redis, state, log), log);
  await safe('maintain', () => runMaintainTask(pg, state, log), log);
  await heartbeat(cfg);

  // ----- Scheduled tasks -----

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

  // Nightly at 03:00 Toronto. First fire is scheduled precisely; after that,
  // a 24h interval keeps it aligned (DST handled because we recompute on each
  // start, and 24h is close enough — if it drifts by an hour post-DST, the
  // next process restart realigns it).
  const untilNightly = msUntilNext3amToronto();
  log.info({ ms_until_first_nightly: untilNightly }, 'nightly scheduled');
  setTimeout(() => {
    void safe('nightly', () => runNightly(pg, state, log), log);
    setInterval(() => void safe('nightly', () => runNightly(pg, state, log), log), 24 * 3_600_000);
  }, untilNightly);

  // Heartbeat every minute for healthcheck.
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
