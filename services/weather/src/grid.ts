import type { Pool } from 'pg';
import type { GridCell } from './types.js';

export async function rebuildGrid(pg: Pool): Promise<number> {
  const { rows } = await pg.query<{ rebuild_weather_grid: number }>(
    'SELECT ref.rebuild_weather_grid()',
  );
  return rows[0]?.rebuild_weather_grid ?? 0;
}

export async function loadGrid(pg: Pool): Promise<GridCell[]> {
  const { rows } = await pg.query<{
    grid_lat: string;
    grid_lon: string;
    sample_lat: string;
    sample_lon: string;
    stop_count: number;
  }>(`
    SELECT grid_lat::text, grid_lon::text,
           sample_lat::text, sample_lon::text,
           stop_count
    FROM ref.weather_grid
    WHERE stop_count > 0
    ORDER BY grid_lat, grid_lon
  `);

  return rows.map((r) => ({
    gridLat: Number(r.grid_lat),
    gridLon: Number(r.grid_lon),
    sampleLat: Number(r.sample_lat),
    sampleLon: Number(r.sample_lon),
    stopCount: r.stop_count,
  }));
}
