import { spawn } from 'node:child_process';
import type { Logger } from './logger.js';

/**
 * Run /tools/load_gtfs.sh <gtfs_dir> <feed_version> as a child process,
 * streaming its output to our stdout. Inherits env (PG*, DATABASE_URL).
 */
export function runLoader(
  script: string,
  gtfsDir: string,
  feedVersion: string,
  log: Logger,
): Promise<void> {
  log.info({ script, gtfsDir, feedVersion }, 'running gtfs loader');

  return new Promise<void>((resolve, reject) => {
    const child = spawn('bash', [script, gtfsDir, feedVersion], {
      stdio: 'inherit',
      env: process.env,
    });

    child.on('error', (err) => {
      log.error({ err: err.message }, 'loader failed to start');
      reject(err);
    });

    child.on('close', (code) => {
      if (code === 0) {
        log.info({ feedVersion }, 'loader succeeded');
        resolve();
      } else {
        const e = new Error(`loader exited with code ${code}`);
        log.error({ code, feedVersion }, 'loader failed');
        reject(e);
      }
    });
  });
}
