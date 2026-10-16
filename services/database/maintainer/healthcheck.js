#!/usr/bin/env node
// Healthy if the maintainer wrote a heartbeat within the last 3 hours.
// The heartbeat is refreshed on every successful update-check or maintain tick.
import { statSync } from 'node:fs';

const HEARTBEAT = '/state/heartbeat';
const MAX_AGE_MS = 3 * 60 * 60 * 1000; // 3 hours

try {
  const ageMs = Date.now() - statSync(HEARTBEAT).mtimeMs;
  process.exit(ageMs < MAX_AGE_MS ? 0 : 1);
} catch {
  process.exit(1);
}
