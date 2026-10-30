import { log } from "./log.ts";
import type { PathState } from "./reconcile.ts";

export interface LocalStat {
  mtime: number;
  ctime: number;
  size: number;
  ino: number | null;
}

export type HoldReason = "collision" | "noRemote" | "regressed" | "unreadable";

export interface PathRecord extends PathState {
  id: string;
  path: string;
  stat?: LocalStat;
  recheckAt?: number;
  held?: HoldReason;
}

export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function writeAtomic(path: string, text: string): Promise<void> {
  const tmp = `${path}.tmp.${Deno.pid}.${crypto.randomUUID().slice(0, 8)}`;
  try {
    await Deno.writeTextFile(tmp, text);
    await Deno.rename(tmp, path);
  } catch (e) {
    await Deno.remove(tmp).catch(() => undefined);
    throw e;
  }
}

export class JsonFile<T> {
  constructor(readonly path: string) {}

  async read(fallback: T): Promise<T> {
    try {
      return JSON.parse(await Deno.readTextFile(this.path)) as T;
    } catch (e) {
      if (e instanceof Deno.errors.NotFound) return fallback;
      throw e;
    }
  }

  async write(value: T): Promise<void> {
    await writeAtomic(this.path, JSON.stringify(value));
  }
}

export class BaseStore {
  private constructor(private readonly dir: string, private readonly records: Map<string, PathRecord>) {}

  static async open(dir: string): Promise<BaseStore> {
    await Deno.mkdir(dir, { recursive: true });
    const records = new Map<string, PathRecord>();
    for await (const entry of Deno.readDir(dir)) {
      if (!entry.isFile || !entry.name.endsWith(".json")) continue;
      try {
        const rec = JSON.parse(await Deno.readTextFile(`${dir}/${entry.name}`)) as PathRecord;
        records.set(rec.id, rec);
      } catch (e) {
        log.warn(`skipping unreadable base file ${entry.name}: ${e}`);
      }
    }
    return new BaseStore(dir, records);
  }

  get(id: string): PathRecord | undefined {
    const rec = this.records.get(id);
    return rec && structuredClone(rec);
  }

  all(): PathRecord[] {
    return [...this.records.values()];
  }

  held(): PathRecord[] {
    return this.all().filter((r) => r.held);
  }

  withContent(): number {
    return this.all().filter((r) => r.synced && r.synced.hash !== null).length;
  }

  async put(rec: PathRecord): Promise<void> {
    await writeAtomic(await this.fileFor(rec.id), JSON.stringify(rec));
    this.records.set(rec.id, structuredClone(rec));
  }

  async delete(id: string): Promise<void> {
    await Deno.remove(await this.fileFor(id)).catch((e) => {
      if (!(e instanceof Deno.errors.NotFound)) throw e;
    });
    this.records.delete(id);
  }

  private async fileFor(id: string): Promise<string> {
    return `${this.dir}/${await sha256Hex(id)}.json`;
  }
}
