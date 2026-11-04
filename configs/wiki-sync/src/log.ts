type Level = "debug" | "info" | "notice" | "warn" | "error";

const ORDER: Record<Level, number> = { debug: 0, info: 1, notice: 2, warn: 3, error: 4 };
let threshold: Level = "info";
let timestamps = false;

export function setLogLevel(level: Level): void {
  threshold = level;
}

export function setTimestamps(on: boolean): void {
  timestamps = on;
}

const pad = (n: number) => String(n).padStart(2, "0");

export function formatLine(level: Level, msg: string, at: Date | null): string {
  const line = `${level.toUpperCase()} ${msg}`;
  if (!at) return line;
  const date = `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}`;
  const time = `${pad(at.getHours())}:${pad(at.getMinutes())}:${pad(at.getSeconds())}`;
  return `${date} ${time} ${line}`;
}

function emit(level: Level, msg: string): void {
  if (ORDER[level] < ORDER[threshold]) return;
  const line = formatLine(level, msg, timestamps ? new Date() : null);
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
