import { Redis } from 'ioredis';
import type { Config } from './config.js';

let client: Redis | null = null;

export function getRedis(cfg: Config): Redis {
  if (!client) {
    client = new Redis(cfg.REDIS_URL, {
      lazyConnect: false,
      enableAutoPipelining: true,
      maxRetriesPerRequest: 2,
      // keep retrying forever — the maintainer is long-running and Redis
      // may restart under it. Exports that fail just retry next tick.
      retryStrategy: (times) => Math.min(times * 200, 5_000),
    });
  }
  return client;
}

export async function closeRedis(): Promise<void> {
  if (client) {
    await client.quit().catch(() => {});
    client = null;
  }
}
