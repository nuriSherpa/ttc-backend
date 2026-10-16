import { z } from 'zod';

const ConfigSchema = z.object({
  DATABASE_URL: z.string().min(1),
  REDIS_URL: z.string().min(1),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),

  FEED_VEHICLES: z.string().url().default('https://bustime.ttc.ca/gtfsrt/vehicles'),
  FEED_TRIPS: z.string().url().default('https://bustime.ttc.ca/gtfsrt/trips'),
  FEED_ALERTS: z.string().url().default('https://bustime.ttc.ca/gtfsrt/alerts'),

  FETCH_TIMEOUT_MS: z.coerce.number().int().positive().default(10_000),
  FETCH_RETRIES: z.coerce.number().int().nonnegative().default(2),

  // NEW: mode and interval
  MODE: z.enum(['once', 'loop']).default('once'),
  INTERVAL_MS: z.coerce.number().int().positive().default(15_000),
});

export type Config = z.infer<typeof ConfigSchema>;

export function loadConfig(): Config {
  const parsed = ConfigSchema.safeParse(process.env);
  if (!parsed.success) {
    console.error('invalid config:', parsed.error.flatten().fieldErrors);
    process.exit(1);
  }
  return parsed.data;
}
