export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const ORDER: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export interface Logger {
  debug: (o: object, msg?: string) => void;
  info: (o: object, msg?: string) => void;
  warn: (o: object, msg?: string) => void;
  error: (o: object, msg?: string) => void;
}

export function makeLogger(minLevel: LogLevel): Logger {
  const min = ORDER[minLevel];
  const write = (level: LogLevel, obj: object, msg?: string) => {
    if (ORDER[level] < min) return;
    const line = JSON.stringify({
      level,
      time: new Date().toISOString(),
      ...obj,
      msg,
    });
    (level === 'error' ? console.error : console.log)(line);
  };
  return {
    debug: (o, m) => write('debug', o, m),
    info: (o, m) => write('info', o, m),
    warn: (o, m) => write('warn', o, m),
    error: (o, m) => write('error', o, m),
  };
}
