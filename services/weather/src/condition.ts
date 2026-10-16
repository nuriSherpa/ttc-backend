import type { WeatherSnapshot } from './types.js';

type Condition = WeatherSnapshot['condition'];
type Severity = WeatherSnapshot['severity'];

export function classifyWmo(
  code: number | null,
  precip: number,
): { condition: Condition; severity: Severity } {
  if (code == null) {
    // Fall back to precip-only
    if (precip > 5) return { condition: 'rain', severity: 2 };
    if (precip > 0.5) return { condition: 'rain', severity: 1 };
    return { condition: 'clear', severity: 0 };
  }
  // WMO weather codes: https://open-meteo.com/en/docs
  if (code === 0) return { condition: 'clear', severity: 0 };
  if (code >= 1 && code <= 3) return { condition: 'cloudy', severity: 0 };
  if (code === 45 || code === 48) return { condition: 'fog', severity: 1 };
  if (code >= 51 && code <= 57) return { condition: 'rain', severity: 1 };
  if (code >= 61 && code <= 65) return { condition: 'rain', severity: 2 };
  if (code === 66 || code === 67) return { condition: 'snow', severity: 2 };
  if (code >= 71 && code <= 77) return { condition: 'snow', severity: code >= 75 ? 3 : 2 };
  if (code >= 80 && code <= 82) return { condition: 'rain', severity: code === 82 ? 2 : 1 };
  if (code === 85 || code === 86) return { condition: 'snow', severity: code === 86 ? 3 : 2 };
  if (code >= 95) return { condition: 'storm', severity: 3 };
  return { condition: 'clear', severity: 0 };
}
