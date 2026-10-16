export interface GridCell {
  gridLat: number;
  gridLon: number;
  sampleLat: number;
  sampleLon: number;
  stopCount: number;
}

export interface WeatherSnapshot {
  lat: number;
  lon: number;
  tempC: number | null;
  precipMm: number;
  snowCm: number;
  windKph: number | null;
  weatherCode: number | null;
  condition: 'clear' | 'cloudy' | 'fog' | 'rain' | 'snow' | 'storm';
  severity: 0 | 1 | 2 | 3;
  at: number; // epoch ms
  source: 'open-meteo';
}

export interface HourlyRow {
  gridLat: number;
  gridLon: number;
  observedAtUtc: Date;
  localDate: string; // YYYY-MM-DD
  localHour: number; // 0..23
  tempC: number | null;
  precipMm: number;
  snowCm: number;
  windKph: number | null;
  weatherCode: number | null;
  condition: WeatherSnapshot['condition'];
  severity: 0 | 1 | 2 | 3;
}

export interface SyncStats {
  cells: number;
  batches: number;
  written: number;
  errors: number;
  ms: number;
}

export interface ForecastHour {
  at: number; // epoch ms (UTC)
  localDate: string; // YYYY-MM-DD (Toronto)
  localHour: number; // 0..23
  tempC: number | null;
  precipMm: number;
  snowCm: number;
  windKph: number | null;
  weatherCode: number | null;
  condition: WeatherSnapshot['condition'];
  severity: 0 | 1 | 2 | 3;
}

export interface ForecastBlob {
  lat: number;
  lon: number;
  generatedAt: number; // epoch ms
  hours: ForecastHour[]; // sorted ascending by `at`
}

export interface WeatherAdvice {
  level: 'none' | 'info' | 'warn' | 'alert';
  icon: 'sun' | 'cloud' | 'fog' | 'rain' | 'snow' | 'storm';
  title: string;
  detail: string;
}
