import type { WeatherSnapshot, HourlyRow } from './types.js';
import { classifyWmo } from './condition.js';

const FORECAST = 'https://api.open-meteo.com/v1/forecast';
const ARCHIVE = 'https://archive-api.open-meteo.com/v1/archive';

/** Cells per request. Archive requests are weighted by days, so keep them smaller. */
export const BATCH = 100;
export const ARCHIVE_BATCH = 25;

const HOURLY_VARS = 'temperature_2m,precipitation,snowfall,weather_code,wind_speed_10m';
const TZ = 'America/Toronto';

type Coord = { lat: number; lon: number };
export type HourlyResult = { cellIdx: number; rows: Omit<HourlyRow, 'gridLat' | 'gridLon'>[] };

function coordParams(url: URL, cells: Coord[]): void {
  url.searchParams.set('latitude', cells.map((c) => c.lat.toFixed(4)).join(','));
  url.searchParams.set('longitude', cells.map((c) => c.lon.toFixed(4)).join(','));
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** GET json with retry on 429 / 5xx / network errors. Returns an array (one entry per location). */
async function getJson(
  url: URL,
  timeoutMs: number,
  expected: number,
  what: string,
): Promise<any[]> {
  let lastErr: unknown;
  for (let attempt = 0; attempt < 4; attempt++) {
    if (attempt > 0) await sleep(2000 * 2 ** (attempt - 1));
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
      if (res.status === 429 || res.status >= 500) {
        lastErr = new Error(`open-meteo ${what} ${res.status}`);
        continue;
      }
      if (!res.ok) {
        const body = await res.text().catch(() => '');
        throw new Error(`open-meteo ${what} ${res.status} ${body.slice(0, 200)}`);
      }
      const json: unknown = await res.json();
      const arr = Array.isArray(json) ? json : [json];
      if (arr.length !== expected) {
        throw new Error(`open-meteo ${what}: expected ${expected} locations, got ${arr.length}`);
      }
      return arr;
    } catch (err) {
      lastErr = err;
      if (err instanceof Error && /expected \d+ locations|open-meteo \w+ 4\d\d/.test(err.message))
        throw err;
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}

// ---------------------------------------------------------------------------
// Live fetch — current conditions
// ---------------------------------------------------------------------------

export async function fetchLiveBatch(cells: Coord[]): Promise<WeatherSnapshot[]> {
  if (cells.length === 0) return [];
  const url = new URL(FORECAST);
  coordParams(url, cells);
  url.searchParams.set(
    'current',
    'temperature_2m,precipitation,snowfall,weather_code,wind_speed_10m',
  );
  url.searchParams.set('timezone', TZ);

  const arr = await getJson(url, 15_000, cells.length, 'forecast');
  const now = Date.now();

  return arr.map((r: any, i: number): WeatherSnapshot => {
    const c = r?.current ?? {};
    const wc: number | null = c.weather_code ?? null;
    const precip: number = c.precipitation ?? 0;
    const { condition, severity } = classifyWmo(wc, precip);
    return {
      lat: cells[i]!.lat,
      lon: cells[i]!.lon,
      tempC: c.temperature_2m ?? null,
      precipMm: precip,
      snowCm: c.snowfall ?? 0,
      windKph: c.wind_speed_10m ?? null,
      weatherCode: wc,
      condition,
      severity,
      at: now,
      source: 'open-meteo',
    };
  });
}

// ---------------------------------------------------------------------------
// Hourly parsing. Requests use timeformat=unixtime, so `time` is exact UTC
// epoch seconds (the local-time strings are ambiguous across DST changes).
// ---------------------------------------------------------------------------

const localFmt = new Intl.DateTimeFormat('en-CA', {
  timeZone: TZ,
  hourCycle: 'h23',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
});

function localParts(d: Date): { date: string; hour: number } {
  const p: Record<string, string> = {};
  for (const part of localFmt.formatToParts(d)) p[part.type] = part.value;
  return { date: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour) };
}

function parseHourly(r: any, nowMs: number): HourlyResult['rows'] {
  const h = r?.hourly ?? {};
  const times: number[] = h.time ?? [];
  const out: HourlyResult['rows'] = [];
  for (let i = 0; i < times.length; i++) {
    const ms = Number(times[i]) * 1000;
    // Only completed hours: never freeze a forecast as if it were an observation.
    if (!Number.isFinite(ms) || ms + 3_600_000 > nowMs) continue;

    const temp: number | null = h.temperature_2m?.[i] ?? null;
    const wind: number | null = h.wind_speed_10m?.[i] ?? null;
    const wc: number | null = h.weather_code?.[i] ?? null;
    if (temp == null && wind == null && wc == null) continue; // no data for this hour

    const precip: number = h.precipitation?.[i] ?? 0;
    const { condition, severity } = classifyWmo(wc, precip);
    const at = new Date(ms);
    const { date, hour } = localParts(at);
    out.push({
      observedAtUtc: at,
      localDate: date,
      localHour: hour,
      tempC: temp,
      precipMm: precip,
      snowCm: h.snowfall?.[i] ?? 0,
      windKph: wind,
      weatherCode: wc,
      condition,
      severity,
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// History: recent hours via the forecast API (past_days, max 92)
// ---------------------------------------------------------------------------

export async function fetchHistoryBatch(cells: Coord[], pastDays: number): Promise<HourlyResult[]> {
  if (cells.length === 0) return [];
  const url = new URL(FORECAST);
  coordParams(url, cells);
  url.searchParams.set('hourly', HOURLY_VARS);
  url.searchParams.set('past_days', String(Math.min(Math.max(Math.floor(pastDays), 1), 92)));
  url.searchParams.set('forecast_days', '1');
  url.searchParams.set('timeformat', 'unixtime');
  url.searchParams.set('timezone', TZ);

  const arr = await getJson(url, 20_000, cells.length, 'history');
  const now = Date.now();
  return arr.map((r, cellIdx) => ({ cellIdx, rows: parseHourly(r, now) }));
}

// ---------------------------------------------------------------------------
// Archive: older days. The archive lags real time by a few days.
// ---------------------------------------------------------------------------

export async function fetchArchiveBatch(
  cells: Coord[],
  startDate: string,
  endDate: string,
): Promise<HourlyResult[]> {
  if (cells.length === 0) return [];
  const url = new URL(ARCHIVE);
  coordParams(url, cells);
  url.searchParams.set('start_date', startDate);
  url.searchParams.set('end_date', endDate);
  url.searchParams.set('hourly', HOURLY_VARS);
  url.searchParams.set('timeformat', 'unixtime');
  url.searchParams.set('timezone', TZ);

  const arr = await getJson(url, 60_000, cells.length, 'archive');
  const now = Date.now();
  return arr.map((r, cellIdx) => ({ cellIdx, rows: parseHourly(r, now) }));
}
