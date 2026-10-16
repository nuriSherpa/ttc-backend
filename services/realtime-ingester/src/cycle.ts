import { Worker } from 'node:worker_threads';
import type { Pool } from 'pg';
import type { Redis } from 'ioredis';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { fetchFeed } from './http/fetch-feed.js';
import { writeAll } from './writers/postgres.js';
import { writeRedis } from './writers/redis.js';
import { sweepStale } from './writers/sweep.js';
import type { Config } from './config.js';
import type { Logger } from './logger.js';
import type { ParsedVehicle, ParsedTrip, ParsedAlert } from './decode/types.js';

const here = dirname(fileURLToPath(import.meta.url));
const workerPath = join(here, 'decode', 'worker.js');

async function decodeInWorker(
  kind: 'vehicles' | 'trips' | 'alerts',
  bytes: Uint8Array,
): Promise<unknown[]> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(workerPath);
    worker.once('message', (msg: any) => {
      worker.terminate();
      if (msg.ok) resolve(msg.entities);
      else reject(new Error(msg.error));
    });
    worker.once('error', reject);
    worker.postMessage({ kind, bytes });
  });
}

export async function runCycle(
  pg: Pool,
  redis: Redis,
  config: Config,
  logger: Logger,
): Promise<void> {
  const t0 = Date.now();

  const [vehBytes, tripBytes, alertBytes] = await Promise.all([
    fetchFeed(config.FEED_VEHICLES, {
      timeoutMs: config.FETCH_TIMEOUT_MS,
      retries: config.FETCH_RETRIES,
      logger,
    }),
    fetchFeed(config.FEED_TRIPS, {
      timeoutMs: config.FETCH_TIMEOUT_MS,
      retries: config.FETCH_RETRIES,
      logger,
    }),
    fetchFeed(config.FEED_ALERTS, {
      timeoutMs: config.FETCH_TIMEOUT_MS,
      retries: config.FETCH_RETRIES,
      logger,
    }),
  ]);

  const [vehicles, trips, alerts] = await Promise.all([
    decodeInWorker('vehicles', vehBytes) as Promise<ParsedVehicle[]>,
    decodeInWorker('trips', tripBytes) as Promise<ParsedTrip[]>,
    decodeInWorker('alerts', alertBytes) as Promise<ParsedAlert[]>,
  ]);

  logger.info({ vehicles: vehicles.length, trips: trips.length, alerts: alerts.length }, 'decoded');

  await writeAll(pg, vehicles, trips, alerts);
  logger.info({ ms: Date.now() - t0 }, 'postgres written');

  try {
    const s = await writeRedis(redis, pg);
    logger.info({ ...s, totalMs: Date.now() - t0 }, 'redis written');
  } catch (err) {
    logger.error({ err: (err as Error).message }, 'redis write failed; Postgres is current');
  }

  await sweepStale(pg);

  logger.info({ totalMs: Date.now() - t0 }, 'cycle complete');
}
