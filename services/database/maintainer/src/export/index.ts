import type { Pool } from 'pg';
import type { Redis } from 'ioredis';
import type { Logger } from '../logger.js';
import { exportStops } from './stops.js';
import { exportRoutes } from './routes.js';

export interface StaticExportResult {
  exported: boolean;
  feedVersion: string | null;
  stops?: number;
  routes?: number;
}

/**
 * Idempotent. Compares ops.feed.feed_version against meta:static.feed_version.
 * If they match → no-op (~5 ms). If not → full export.
 *
 * The Redis key meta:static IS the state — no local file needed.
 */
export async function ensureStaticExport(
  pg: Pool,
  redis: Redis,
  log: Logger,
): Promise<StaticExportResult> {
  const { rows } = await pg.query<{ feed_version: string }>(
    `SELECT feed_version FROM ops.feed WHERE source = 'ttc'`,
  );
  const active = rows[0]?.feed_version ?? null;

  if (!active) {
    log.warn({}, 'no active feed — skipping static export');
    return { exported: false, feedVersion: null };
  }

  const cached = await redis.hget('meta:static', 'feed_version');

  if (cached === active) {
    log.debug({ feed_version: active }, 'static export: cache current');
    return { exported: false, feedVersion: cached };
  }

  log.info({ active, cached: cached ?? null }, 'static export: cache stale, running');

  const stops = await exportStops(pg, redis, log);
  const routes = await exportRoutes(pg, redis, log);

  // Written LAST. Presence of a matching feed_version is the commit marker.
  await redis.hset('meta:static', {
    feed_version: active,
    exported_at: new Date().toISOString(),
    stops: String(stops),
    routes: String(routes),
  });

  log.info({ feed_version: active, stops, routes }, 'static export complete');

  return { exported: true, feedVersion: active, stops, routes };
}
