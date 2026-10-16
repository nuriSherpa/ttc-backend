import { Redis } from 'ioredis';
import type { Config } from './config.js';

export function makeRedis(cfg: Config): Redis {
  const r = new Redis(cfg.REDIS_URL, { maxRetriesPerRequest: 3, enableReadyCheck: true });
  r.on('error', (err) => {
    console.error(JSON.stringify({ level: 'error', msg: 'redis error', err: String(err) }));
  });
  return r;
}
