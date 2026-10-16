import { z } from 'zod';

const Schema = z.object({
  PGHOST: z.string().default('postgres'),
  PGUSER: z.string().default('ttc_admin'),
  PGPASSWORD: z.string(),
  PGDATABASE: z.string().default('ttc'),
  REDIS_URL: z.string().min(1),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
  BACKFILL_DAYS: z.coerce.number().default(90),
});

export type Config = z.infer<typeof Schema>;

export function loadConfig(): Config {
  const parsed = Schema.safeParse(process.env);
  if (!parsed.success) {
    console.error('invalid config:', parsed.error.flatten().fieldErrors);
    process.exit(1);
  }
  return parsed.data;
}
