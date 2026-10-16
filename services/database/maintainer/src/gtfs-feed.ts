import { createWriteStream } from 'node:fs';
import { mkdir, rm, readFile, stat } from 'node:fs/promises';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import type { Logger } from './logger.js';

export async function downloadZip(url: string, dest: string, log: Logger): Promise<void> {
  await mkdir(join(dest, '..'), { recursive: true });
  log.info({ url, dest }, 'downloading gtfs zip');

  const r = await fetch(url, {
    headers: { 'User-Agent': 'ttc-maintainer/0.1' },
  });
  if (!r.ok || !r.body) throw new Error(`download HTTP ${r.status}`);

  const tmp = dest + '.part';
  await pipeline(Readable.fromWeb(r.body as never), createWriteStream(tmp));
  await rm(dest, { force: true });
  await (await import('node:fs/promises')).rename(tmp, dest);

  const { size } = await stat(dest);
  log.info({ bytes: size }, 'gtfs zip downloaded');
}

/**
 * Extract a zip using the system `unzip` binary. Overwrites existing files.
 * Uses a staging directory so a partial extract never corrupts the previous one.
 */
export async function extractZip(zipPath: string, destDir: string, log: Logger): Promise<void> {
  const staging = destDir + '.new';
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });

  log.info({ zipPath, staging }, 'extracting gtfs zip');
  await new Promise<void>((resolve, reject) => {
    const child = spawn('unzip', ['-oq', zipPath, '-d', staging], {
      stdio: ['ignore', 'ignore', 'inherit'],
    });
    child.on('close', (code) =>
      code === 0 ? resolve() : reject(new Error(`unzip exited ${code}`)),
    );
    child.on('error', reject);
  });

  await rm(destDir, { recursive: true, force: true });
  await (await import('node:fs/promises')).rename(staging, destDir);
  log.info({ destDir }, 'gtfs zip extracted');
}

export interface FeedInfo {
  feed_version: string;
  start_date: string; // YYYY-MM-DD
  end_date: string; // YYYY-MM-DD
}

/**
 * Parse feed_info.txt for the version and validity window.
 * GTFS dates are YYYYMMDD; we convert to YYYY-MM-DD.
 */
export async function readFeedInfo(gtfsDir: string): Promise<FeedInfo> {
  const txt = await readFile(join(gtfsDir, 'feed_info.txt'), 'utf8');
  const lines = txt.split(/\r?\n/).filter((l) => l.length > 0);
  if (lines.length < 2) throw new Error('feed_info.txt has no data row');

  const header = lines[0]!.split(',').map((s) => s.trim());
  const row = lines[1]!.split(',').map((s) => s.trim());

  const idx = (name: string) => header.indexOf(name);
  const get = (name: string): string => {
    const i = idx(name);
    return i >= 0 ? (row[i] ?? '') : '';
  };

  const fmtDate = (yyyymmdd: string): string => {
    if (!/^\d{8}$/.test(yyyymmdd)) return '';
    return `${yyyymmdd.slice(0, 4)}-${yyyymmdd.slice(4, 6)}-${yyyymmdd.slice(6, 8)}`;
  };

  const feed_version = get('feed_version');
  const start_date = fmtDate(get('feed_start_date'));
  const end_date = fmtDate(get('feed_end_date'));

  if (!feed_version || !start_date || !end_date) {
    throw new Error(
      `feed_info.txt missing required fields (version=${feed_version} start=${start_date} end=${end_date})`,
    );
  }
  return { feed_version, start_date, end_date };
}
