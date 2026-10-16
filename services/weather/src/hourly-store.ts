import type { Pool } from 'pg';
import type { GridCell, HourlyRow } from './types.js';
import type { HourlyResult } from './open-meteo.js';

const COLS = 12;
// Postgres allows 65,535 bind parameters per statement.
const ROWS_PER_INSERT = 4000; // 48,000 params

/** Insert hourly rows (ON CONFLICT DO NOTHING), chunked. Returns rows actually inserted. */
export async function insertHourly(
  pg: Pool,
  cells: GridCell[],
  results: HourlyResult[],
): Promise<number> {
  const flat: HourlyRow[] = [];
  for (const res of results) {
    const cell = cells[res.cellIdx];
    if (!cell) continue;
    for (const row of res.rows) flat.push({ gridLat: cell.gridLat, gridLon: cell.gridLon, ...row });
  }

  let inserted = 0;
  for (let i = 0; i < flat.length; i += ROWS_PER_INSERT) {
    const chunk = flat.slice(i, i + ROWS_PER_INSERT);
    const values: unknown[] = [];
    const ph: string[] = [];
    chunk.forEach((r, k) => {
      const b = k * COLS;
      ph.push(`(${Array.from({ length: COLS }, (_, j) => `$${b + j + 1}`).join(',')})`);
      values.push(
        r.gridLat,
        r.gridLon,
        r.observedAtUtc,
        r.localDate,
        r.localHour,
        r.tempC,
        r.precipMm,
        r.snowCm,
        r.windKph,
        r.weatherCode,
        r.condition,
        r.severity,
      );
    });
    const res = await pg.query(
      `INSERT INTO ref.weather_hourly
         (grid_lat, grid_lon, observed_at_utc, local_date, local_hour,
          temp_c, precip_mm, snow_cm, wind_kph, weather_code, condition, severity)
       VALUES ${ph.join(',')}
       ON CONFLICT (grid_lat, grid_lon, observed_at_utc) DO NOTHING`,
      values,
    );
    inserted += res.rowCount ?? 0;
  }
  return inserted;
}
