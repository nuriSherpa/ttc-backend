import type { Pool } from 'pg';
import type { Redis } from 'ioredis';
import type { Logger } from './logger.js';
import type { GridCell, ForecastBlob } from './types.js';
import { BATCH, fetchLiveBatch, fetchHistoryBatch, fetchForecastBatch } from './open-meteo.js';
import { insertHourly } from './hourly-store.js';

const LIVE_TTL_S = 1800; // two missed 15-min cycles before the key disappears
const FORECAST_TTL_S = 3600; // one hour; the loop runs every 30 min anyway

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function weatherKey(c: GridCell): string {
  return `weather:current:${c.gridLat.toFixed(2)}:${c.gridLon.toFixed(2)}`;
}

export function forecastKey(c: GridCell): string {
  return `weather:forecast:${c.gridLat.toFixed(2)}:${c.gridLon.toFixed(2)}`;
}

/** Live loop — writes Redis only. */
export async function runLiveSync(
  cells: GridCell[],
  redis: Redis,
  log: Logger,
): Promise<{ cells: number; written: number; errors: number; ms: number }> {
  const t0 = Date.now();
  let written = 0;
  let errors = 0;

  for (let i = 0; i < cells.length; i += BATCH) {
    const batch = cells.slice(i, i + BATCH);
    try {
      const snaps = await fetchLiveBatch(
        batch.map((c) => ({ lat: c.sampleLat, lon: c.sampleLon })),
      );
      const pipe = redis.pipeline();
      batch.forEach((cell, j) => {
        const snap = snaps[j];
        if (snap) {
          pipe.setex(weatherKey(cell), LIVE_TTL_S, JSON.stringify(snap));
          written++;
        }
      });
      await pipe.exec();
    } catch (err) {
      errors++;
      log.warn({ err: String(err), batchStart: i }, 'live batch failed');
    }
    if (i + BATCH < cells.length) await sleep(100);
  }
  return { cells: cells.length, written, errors, ms: Date.now() - t0 };
}

/** History loop — writes Postgres only. Idempotent (ON CONFLICT DO NOTHING). */
export async function runHistorySync(
  pg: Pool,
  cells: GridCell[],
  log: Logger,
  pastDays = 1,
): Promise<{ cells: number; rows: number; errors: number; ms: number }> {
  const t0 = Date.now();
  let rows = 0;
  let errors = 0;

  for (let i = 0; i < cells.length; i += BATCH) {
    const batch = cells.slice(i, i + BATCH);
    try {
      const results = await fetchHistoryBatch(
        batch.map((c) => ({ lat: c.sampleLat, lon: c.sampleLon })),
        pastDays,
      );
      rows += await insertHourly(pg, batch, results);
    } catch (err) {
      errors++;
      log.warn({ err: String(err), batchStart: i }, 'history batch failed');
    }
    if (i + BATCH < cells.length) await sleep(200);
  }
  return { cells: cells.length, rows, errors, ms: Date.now() - t0 };
}

/** Forecast loop — writes Redis only. Forward-looking hours for journey advice. */
export async function runForecastSync(
  cells: GridCell[],
  redis: Redis,
  log: Logger,
  hours = 24,
): Promise<{ cells: number; written: number; errors: number; ms: number }> {
  const t0 = Date.now();
  let written = 0;
  let errors = 0;

  for (let i = 0; i < cells.length; i += BATCH) {
    const batch = cells.slice(i, i + BATCH);
    try {
      const results = await fetchForecastBatch(
        batch.map((c) => ({ lat: c.sampleLat, lon: c.sampleLon })),
        hours,
      );
      const pipe = redis.pipeline();
      const generatedAt = Date.now();

      for (const r of results) {
        const cell = batch[r.cellIdx]!;
        const blob: ForecastBlob = {
          lat: cell.sampleLat,
          lon: cell.sampleLon,
          generatedAt,
          hours: r.rows,
        };
        pipe.setex(forecastKey(cell), FORECAST_TTL_S, JSON.stringify(blob));
        written++;
      }
      await pipe.exec();
    } catch (err) {
      errors++;
      log.warn({ err: String(err), batchStart: i }, 'forecast batch failed');
    }
    if (i + BATCH < cells.length) await sleep(100);
  }
  return { cells: cells.length, written, errors, ms: Date.now() - t0 };
}
