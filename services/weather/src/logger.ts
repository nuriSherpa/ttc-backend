export type Level = 'debug' | 'info' | 'warn' | 'error';
const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export interface Logger {
  debug(obj: object, msg: string): void;
  info(obj: object, msg: string): void;
  warn(obj: object, msg: string): void;
  error(obj: object, msg: string): void;
}

export function makeLogger(level: Level): Logger {
  const min = ORDER[level];
  const emit =
    (lvl: Level) =>
    (obj: object, msg: string): void => {
      if (ORDER[lvl] < min) return;
      const line = JSON.stringify({ level: lvl, time: new Date().toISOString(), msg, ...obj });
      (lvl === 'error' || lvl === 'warn' ? process.stderr : process.stdout).write(line + '\n');
    };
  return { debug: emit('debug'), info: emit('info'), warn: emit('warn'), error: emit('error') };
}
