import { setTimeout as sleep } from 'node:timers/promises';

import type { Logger } from '../logger.js';

export interface FetchOptions {
  timeoutMs: number;
  retries: number;
  logger: Logger;
}

export async function fetchFeed(url: string, opts: FetchOptions): Promise<Uint8Array> {
  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= opts.retries; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), opts.timeoutMs);
    const started = Date.now();

    try {
      const res = await fetch(url, {
        method: 'GET',
        headers: {
          Accept: 'application/x-protobuf, application/octet-stream, */*',
          'Accept-Encoding': 'gzip',
          'User-Agent': 'ttc-ingestor/0.1',
        },
        signal: controller.signal,
      });

      clearTimeout(timer);

      if (!res.ok) {
        throw new Error(`HTTP ${res.status} ${res.statusText}`);
      }

      const buffer = new Uint8Array(await res.arrayBuffer());
      opts.logger.info(
        {
          url,
          bytes: buffer.byteLength,
          ms: Date.now() - started,
          attempt,
        },
        'feed fetched',
      );

      return buffer;
    } catch (err) {
      clearTimeout(timer);
      lastError = err as Error;
      opts.logger.warn({ url, attempt, err: lastError.message }, 'feed fetch failed');

      if (attempt < opts.retries) {
        await sleep(500 * Math.pow(2, attempt)); // 500ms, 1s, ...
      }
    }
  }

  throw new Error(`fetch failed after ${opts.retries + 1} attempts: ${lastError?.message}`);
}
