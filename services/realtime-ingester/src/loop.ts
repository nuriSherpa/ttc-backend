import type { Pool } from 'pg';
import type { Redis } from 'ioredis';
import { randomUUID } from 'node:crypto';
import type { Config } from './config.js';
import type { Logger } from './logger.js';
import { runCycle } from './cycle.js';

export async function runLoop(pg: Pool, redis: Redis, cfg: Config, logger: Logger): Promise<void> {
  let running = true;
  let consecutiveFailures = 0;
  let totalCycles = 0;
  let totalFailures = 0;

  const stop = (sig: string) => {
    if (!running) return;
    running = false;
    logger.info({ sig }, 'shutdown signal — will exit after current cycle');
  };

  process.on('SIGTERM', () => stop('SIGTERM'));
  process.on('SIGINT', () => stop('SIGINT'));

  // A stray rejection from a promise nobody awaited must not kill the process.
  process.on('unhandledRejection', (reason) => {
    logger.error(
      {
        err: reason instanceof Error ? reason.message : String(reason),
        stack: reason instanceof Error ? reason.stack : undefined,
      },
      'unhandled rejection (ignored)',
    );
  });

  // A true uncaught exception leaves the runtime in an unknown state. Log
  // and exit — Docker restart is the recovery.
  process.on('uncaughtException', (err) => {
    logger.error({ err: err.message, stack: err.stack }, 'uncaught exception — exiting');
    process.exit(1);
  });

  logger.info({ interval_ms: cfg.INTERVAL_MS }, 'loop starting');

  while (running) {
    const cycleLog = logger.child({
      cycle_id: randomUUID().slice(0, 8),
      cycle_num: totalCycles + 1,
    });
    const startedAt = Date.now();
    let failed = false;

    try {
      await runCycle(pg, redis, cfg, cycleLog);
    } catch (err) {
      failed = true;
      consecutiveFailures++;
      totalFailures++;
      cycleLog.error(
        {
          err: err instanceof Error ? err.message : String(err),
          stack: err instanceof Error ? err.stack : undefined,
          consecutive_failures: consecutiveFailures,
        },
        'cycle failed',
      );
    }

    if (!failed) {
      if (consecutiveFailures > 0) {
        cycleLog.info({ recovered_after: consecutiveFailures }, 'recovered');
      }
      consecutiveFailures = 0;
    }
    totalCycles++;

    const elapsed = Date.now() - startedAt;
    if (elapsed > cfg.INTERVAL_MS) {
      cycleLog.warn(
        { elapsed_ms: elapsed, interval_ms: cfg.INTERVAL_MS },
        'cycle exceeded interval — starting next immediately',
      );
    }

    if (!running) break;

    // Backoff when things go wrong. Normal cycles just wait the remainder.
    let waitMs = Math.max(0, cfg.INTERVAL_MS - elapsed);
    if (consecutiveFailures >= 10) waitMs = Math.max(waitMs, 5 * 60_000);
    else if (consecutiveFailures >= 6) waitMs = Math.max(waitMs, 60_000);
    else if (consecutiveFailures >= 3) waitMs = Math.max(waitMs, 30_000);

    if (waitMs > 0) {
      cycleLog.info(
        {
          wait_ms: waitMs,
          total_cycles: totalCycles,
          total_failures: totalFailures,
        },
        'idle',
      );
      await interruptibleSleep(waitMs, () => !running);
    }
  }

  logger.info({ total_cycles: totalCycles, total_failures: totalFailures }, 'loop stopped');
}

/** Sleep in 500ms chunks so SIGTERM is handled promptly. */
async function interruptibleSleep(ms: number, shouldStop: () => boolean): Promise<void> {
  const chunk = 500;
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (shouldStop()) return;
    await new Promise((r) => setTimeout(r, Math.min(chunk, end - Date.now())));
  }
}
