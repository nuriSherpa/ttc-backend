import type { Pool } from 'pg';
import type { Redis } from 'ioredis';
import type { Logger } from '../logger.js';

export async function exportStops(pg: Pool, redis: Redis, log: Logger): Promise<number> {
  const [stopsQ, routesQ] = await Promise.all([
    pg.query<{
      stop_id: string;
      stop_code: string | null;
      stop_name: string;
      stop_lat: number;
      stop_lon: number;
      wheelchair_boarding: number | null;
      parent_station: string | null;
      station_name: string | null;
    }>(`
      SELECT stop_id, stop_code, stop_name, stop_lat, stop_lon,
             wheelchair_boarding, parent_station, station_name
      FROM ref.stop_points
      ORDER BY stop_id
    `),
    pg.query<{ stop_id: string; route_id: string }>(`
      SELECT stop_id, route_id FROM ref.stop_routes ORDER BY stop_id
    `),
  ]);

  const routesByStop = new Map<string, string[]>();
  for (const r of routesQ.rows) {
    let arr = routesByStop.get(r.stop_id);
    if (!arr) {
      arr = [];
      routesByStop.set(r.stop_id, arr);
    }
    arr.push(r.route_id);
  }

  // Stage the GEO index under a temp key, then RENAME — atomic swap.
  const staging = `geo:stops:new:${Date.now()}`;
  let pipe = redis.pipeline();
  let buf = 0;

  const flush = async () => {
    if (buf === 0) return;
    await pipe.exec();
    pipe = redis.pipeline();
    buf = 0;
  };

  for (const s of stopsQ.rows) {
    pipe.geoadd(staging, s.stop_lon, s.stop_lat, s.stop_id);
    pipe.hset(`stop:${s.stop_id}`, {
      id: s.stop_id,
      code: s.stop_code ?? '',
      name: s.stop_name,
      lat: String(s.stop_lat),
      lon: String(s.stop_lon),
      wheelchair: String(s.wheelchair_boarding ?? 0),
      parent: s.parent_station ?? '',
      station: s.station_name ?? '',
      routes: JSON.stringify(routesByStop.get(s.stop_id) ?? []),
    });
    // NOTE: no EXPIRE. Static keys must never be evicted by any policy.
    buf += 2;
    if (buf >= 2_000) await flush();
  }
  await flush();

  await redis.rename(staging, 'geo:stops');
  log.info({ stops: stopsQ.rows.length }, 'stops exported');
  return stopsQ.rows.length;
}
