export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const ORDER: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export interface LogFields {
  [key: string]: unknown;
}

export interface Logger {
  debug(fields: LogFields, msg?: string): void;
  info(fields: LogFields, msg?: string): void;
  warn(fields: LogFields, msg?: string): void;
  error(fields: LogFields, msg?: string): void;
  child(fields: LogFields): Logger;
}

// ---------- serialization ---------------------------------------------------

function serializeError(err: Error): LogFields {
  const out: LogFields = {
    name: err.name,
    message: err.message,
    stack: err.stack,
  };
  const code = (err as { code?: unknown }).code;
  if (code !== undefined) out.code = code;
  const cause = (err as { cause?: unknown }).cause;
  if (cause !== undefined) out.cause = cause instanceof Error ? serializeError(cause) : cause;
  return out;
}

function safeValue(value: unknown): unknown {
  if (value instanceof Error) return serializeError(value);
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'bigint') return value.toString();
  if (value === undefined) return null;
  return value;
}

// ---------- implementation --------------------------------------------------

export function makeLogger(minLevel: LogLevel = 'info', bindings: LogFields = {}): Logger {
  const min = ORDER[minLevel];

  const emit = (level: LogLevel, fields: LogFields, msg?: string) => {
    if (ORDER[level] < min) return;

    let line: string;
    try {
      line = JSON.stringify(
        { level, time: new Date().toISOString(), ...bindings, ...fields, msg },
        (_key, value) => safeValue(value),
      );
    } catch (stringifyErr) {
      // If a value refuses to serialize, still emit something usable.
      line = JSON.stringify({
        level,
        time: new Date().toISOString(),
        ...bindings,
        msg,
        serialization_error: String(stringifyErr),
      });
    }

    // Route error/warn to stderr, info/debug to stdout.
    (level === 'error' || level === 'warn' ? process.stderr : process.stdout).write(line + '\n');
  };

  return {
    debug: (fields, msg) => emit('debug', fields, msg),
    info: (fields, msg) => emit('info', fields, msg),
    warn: (fields, msg) => emit('warn', fields, msg),
    error: (fields, msg) => emit('error', fields, msg),
    child: (extra) => makeLogger(minLevel, { ...bindings, ...extra }),
  };
}
