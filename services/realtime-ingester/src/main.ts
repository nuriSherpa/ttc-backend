import pg from 'pg';
import { Redis } from 'ioredis';
import { loadConfig } from './config.js';
import { makeLogger } from './logger.js';
import { runCycle } from './cycle.js';
import { runLoop } from './loop.js';

async function main() {
  const cfg = loadConfig();
  const logger = makeLogger(cfg.LOG_LEVEL);

  const pgPool = new pg.Pool({
    connectionString: cfg.DATABASE_URL,
    max: 4,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
  });

  const redis = new Redis(cfg.REDIS_URL, {
    lazyConnect: false,
    enableAutoPipelining: true,
    maxRetriesPerRequest: 1,
    connectTimeout: 3_000,
  });

  try {
    await pgPool.query('SELECT 1');
    await redis.ping();
    logger.info({ mode: cfg.MODE }, 'connections ready');
  } catch (err) {
    logger.error({ err: err instanceof Error ? err.message : String(err) }, 'startup failed');
    process.exit(1);
  }

  if (cfg.MODE === 'loop') {
    try {
      await runLoop(pgPool, redis, cfg, logger);
    } finally {
      await pgPool.end().catch(() => {});
      redis.disconnect();
    }
    process.exit(0);
  }

  const started = Date.now();
  try {
    await runCycle(pgPool, redis, cfg, logger);
    logger.info({ totalMs: Date.now() - started }, 'ingestor run complete');
    process.exit(0);
  } catch (err) {
    logger.error(
      {
        err: err instanceof Error ? err.message : String(err),
        stack: err instanceof Error ? err.stack : undefined,
      },
      'ingestor run failed',
    );
    process.exit(1);
  } finally {
    await pgPool.end().catch(() => {});
    redis.disconnect();
  }
}

main();
