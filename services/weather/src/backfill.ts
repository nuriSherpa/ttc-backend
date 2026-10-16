import type { Pool } from 'pg';
import type { Logger } from './logger.js';
import { ARCHIVE_BATCH, fetchArchiveBatch } from './open-meteo.js';
import { insertHourly } from './hourly-store.js';
import { runHistorySync } from './sync.js';
import type { GridCell } from './types.js';

const ARCHIVE_LAG_DAYS = 5; // the archive trails real time; recent days come from the forecast API
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const isoDate = (d: Date) => d.toISOString().slice(0, 10);

export async function backfill(
  pg: Pool,
  cells: GridCell[],
  days: number,
  log: Logger,
): Promise<void> {
  const now = Date.now();
  const startStr = isoDate(new Date(now - days * 86_400_000));
  const endStr = isoDate(new Date(now - ARCHIVE_LAG_DAYS * 86_400_000));
  let failed = 0;

  log.info({ start: startStr, end: endStr, cells: cells.length }, 'backfill starting');

  if (startStr <= endStr) {
    for (let i = 0; i < cells.length; i += ARCHIVE_BATCH) {
      const batch = cells.slice(i, i + ARCHIVE_BATCH);
      try {
        const results = await fetchArchiveBatch(
          batch.map((c) => ({ lat: c.sampleLat, lon: c.sampleLon })),
          startStr,
          endStr,
        );
        const inserted = await insertHourly(pg, batch, results);
        log.info(
          {
            batch: Math.floor(i / ARCHIVE_BATCH) + 1,
            of: Math.ceil(cells.length / ARCHIVE_BATCH),
            inserted,
          },
          'backfill batch done',
        );
      } catch (err) {
        failed++;
        log.error({ err: String(err), batchStart: i }, 'backfill batch failed');
      }
      await sleep(1000);
    }
  }

  // Fill the gap between the archive's end and now.
  const recent = await runHistorySync(pg, cells, log, ARCHIVE_LAG_DAYS + 2);
  log.info(recent, 'backfill recent days done');

  if (failed > 0 || recent.errors > 0) {
    throw new Error(
      `backfill incomplete: ${failed} archive batches and ${recent.errors} recent batches failed (re-run; inserts are idempotent)`,
    );
  }
}
