import { z } from 'zod';

const ConfigSchema = z.object({
  // Postgres
  PGHOST: z.string().default('postgres'),
  PGUSER: z.string(),
  PGPASSWORD: z.string(),
  PGDATABASE: z.string(),
  DATABASE_URL: z.string().default('dbname=ttc'),

  // Redis
  REDIS_URL: z.string().min(1),

  // Schedule
  UPDATE_CHECK_HOURS: z.coerce.number().positive().default(1),
  MAINTAIN_HOURS: z.coerce.number().positive().default(6),
  ACTIVATE_DAYS_BEFORE_START: z.coerce.number().int().nonnegative().default(0),

  // Feed source
  CKAN_PACKAGE: z.string().default('merged-gtfs-ttc-routes-and-schedules'),
  GTFS_RESOURCE_NAME: z.string().optional(),

  // Filesystem
  STATE_DIR: z.string().default('/state'),
  GTFS_DIR: z.string().default('/state/gtfs'),
  LOADER_SCRIPT: z.string().default('/tools/load_gtfs.sh'),

  // Logging
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
  TZ: z.string().default('America/Toronto'),
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
