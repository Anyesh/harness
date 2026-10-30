type Level = "debug" | "info" | "notice" | "warn" | "error";

const ORDER: Record<Level, number> = { debug: 0, info: 1, notice: 2, warn: 3, error: 4 };
let threshold: Level = "info";

export function setLogLevel(level: Level): void {
  threshold = level;
}

function emit(level: Level, msg: string): void {
  if (ORDER[level] < ORDER[threshold]) return;
  const line = `${level.toUpperCase()} ${msg}`;
  if (ORDER[level] >= ORDER.warn) console.error(line);
  else console.log(line);
}

export const log = {
  debug: (m: string) => emit("debug", m),
  info: (m: string) => emit("info", m),
  notice: (m: string) => emit("notice", m),
  warn: (m: string) => emit("warn", m),
  error: (m: string) => emit("error", m),
};

export function errText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
