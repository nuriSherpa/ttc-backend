import type { Redis } from 'ioredis';
import { join } from 'node:path';
import type { Config } from '../config.js';
import type { Logger } from '../logger.js';
import type { StateStore } from '../state.js';
import type { Pool } from 'pg';
import { ensureStaticExport } from '../export/index.js';
import { findGtfsResource } from '../ckan.js';
import { downloadZip, extractZip, readFeedInfo } from '../gtfs-feed.js';
import { runLoader } from '../loader.js';
import { getActiveFeedVersion } from '../pg.js';

/** Days between now and `isoDate` (YYYY-MM-DD). */
function daysUntil(isoDate: string): number {
  const [y, m, d] = isoDate.split('-').map(Number) as [number, number, number];
  const target = Date.UTC(y, m - 1, d);
  const today = new Date();
  const todayUtc = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  return Math.round((target - todayUtc) / 86_400_000);
}

export async function runUpdateCheck(
  cfg: Config,
  pg: Pool,
  redis: Redis,
  state: StateStore,
  log: Logger,
): Promise<void> {
  log.info({}, 'update check starting');

  try {
    const s = state.get();

    // 1. Query CKAN for the current ZIP resource.
    const resource = await findGtfsResource(cfg.CKAN_PACKAGE, cfg.GTFS_RESOURCE_NAME, log);
    if (!resource) {
      log.warn({}, 'no gtfs zip resource found on ckan');
      await state.update({ last_check_at: new Date().toISOString() });
      return;
    }

    // 2. If we've seen this exact resource before AND we have no pending feed,
    //    there's nothing to do. (We still update last_check_at below.)
    const alreadySeen = s.last_modified_seen === resource.last_modified;
    const hasPending = s.pending !== null;

    if (alreadySeen && !hasPending) {
      log.info({ last_modified: resource.last_modified }, 'no change on ckan');
      await state.update({ last_check_at: new Date().toISOString() });
      return;
    }

    // 3. If a pending feed exists, decide whether to activate it now.
    if (hasPending) {
      const p = s.pending!;
      const days = daysUntil(p.start_date);
      if (days <= cfg.ACTIVATE_DAYS_BEFORE_START) {
        log.info(
          { feed_version: p.feed_version, start_date: p.start_date, days },
          'activating pending feed',
        );
        try {
          await runLoader(cfg.LOADER_SCRIPT, cfg.GTFS_DIR, p.feed_version, log);
          await state.update({
            active_feed_version: p.feed_version,
            pending: null,
            last_check_at: new Date().toISOString(),
          });
        } catch (err) {
          log.error({ err: String((err as Error).message) }, 'failed to activate pending feed');
          // Leave pending in place; retry next tick.
        }
        return;
      } else {
        log.info(
          { feed_version: p.feed_version, start_date: p.start_date, days },
          'pending feed not yet due',
        );
        // Fall through: also check whether CKAN has something newer.
      }
    }

    // 4. Fresh download path: new resource on CKAN.
    const zipPath = join(cfg.STATE_DIR, 'gtfs.zip');
    await downloadZip(resource.url, zipPath, log);
    await extractZip(zipPath, cfg.GTFS_DIR, log);

    const info = await readFeedInfo(cfg.GTFS_DIR);
    log.info(info, 'downloaded feed metadata');

    // 5. Is it already active?
    const active = await getActiveFeedVersion(pg);
    if (active === info.feed_version) {
      log.info({ feed_version: info.feed_version }, 'feed already active, skipping load');
      await state.update({
        last_check_at: new Date().toISOString(),
        last_modified_seen: resource.last_modified,
        active_feed_version: info.feed_version,
      });
      return;
    }

    // 6. Is it too far in the future?
    const days = daysUntil(info.start_date);
    if (days > cfg.ACTIVATE_DAYS_BEFORE_START) {
      log.info(
        { feed_version: info.feed_version, start_date: info.start_date, days },
        'new feed downloaded; holding activation until due',
      );
      await state.update({
        last_check_at: new Date().toISOString(),
        last_modified_seen: resource.last_modified,
        pending: {
          feed_version: info.feed_version,
          start_date: info.start_date,
          end_date: info.end_date,
          zip_path: zipPath,
        },
      });
      return;
    }

    // 7. Activate now.
    try {
      await runLoader(cfg.LOADER_SCRIPT, cfg.GTFS_DIR, info.feed_version, log);
      await state.update({
        last_check_at: new Date().toISOString(),
        last_modified_seen: resource.last_modified,
        active_feed_version: info.feed_version,
        pending: null,
      });
      log.info({ feed_version: info.feed_version }, 'feed activated');
    } catch (err) {
      log.error(
        { err: String((err as Error).message), feed_version: info.feed_version },
        'failed to load new feed',
      );
      // Keep last_modified_seen as-is so next tick retries the same download.
      await state.update({ last_check_at: new Date().toISOString() });
      throw err;
    }
  } finally {
    // Always runs, on every path — fast-path (loader just activated)
    // and self-heal (missed an earlier export for any reason).
    // No-op if meta:static.feed_version already matches ops.feed.feed_version.
    try {
      await ensureStaticExport(pg, redis, log);
    } catch (err) {
      log.error(
        { err: String((err as Error).message) },
        'static export failed; will retry next tick',
      );
    }
  }
}
