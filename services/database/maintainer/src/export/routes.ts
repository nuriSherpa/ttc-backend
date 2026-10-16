import type { Pool } from 'pg';
import type { Redis } from 'ioredis';
import type { Logger } from '../logger.js';

export async function exportRoutes(pg: Pool, redis: Redis, log: Logger): Promise<number> {
  const { rows } = await pg.query<{
    route_id: string; route_short_name: string | null; route_long_name: string | null;
    route_type: number; route_color: string | null; route_text_color: string | null;
  }>(`
    SELECT route_id, route_short_name, route_long_name,
           route_type, route_color, route_text_color
    FROM cur.routes
  `);

  const pipe = redis.pipeline();
  for (const r of rows) {
    pipe.hset(`route:${r.route_id}`, {
      id: r.route_id,
      short_name: r.route_short_name ?? '',
      long_name: r.route_long_name ?? '',
      type: String(r.route_type),
      color: r.route_color ?? '808080',
      text_color: r.route_text_color ?? 'FFFFFF',
    });
  }
  await pipe.exec();

  log.info({ routes: rows.length }, 'routes exported');
  return rows.length;
}
