import chokidar from "chokidar";
import { type LocalStat, sha256Hex } from "./base.ts";

export interface KnownStat extends LocalStat {
  hash: string;
  generated: boolean;
}

export interface FileRead {
  kind: "file";
  path: string;
  stat: LocalStat;
  hash: string;
  generated: boolean;
  bytes: () => Promise<Uint8Array>;
}

export type LocalRead = FileRead | { kind: "absent"; path: string };

export class RootMissing extends Error {
  constructor(root: string) {
    super(`wiki root ${root} is missing or unreadable`);
  }
}

export function isIgnoredPath(rel: string): boolean {
  const parts = rel.split("/");
  if (parts.some((p) => p.startsWith("."))) return true;
  return /\.tmp\./.test(parts[parts.length - 1]);
}

export function isGenerated(bytes: Uint8Array): boolean {
  const head = new TextDecoder().decode(bytes.subarray(0, 4096)).replace(/\r\n/g, "\n");
  if (!head.startsWith("---\n")) return false;
  const end = head.indexOf("\n---", 3);
  if (end < 0) return false;
  return head.slice(4, end).split("\n").some((l) => /^generated:\s*true\s*$/.test(l));
}

export function sameStat(a: LocalStat, b: LocalStat): boolean {
  return a.mtime === b.mtime && a.size === b.size && a.ino === b.ino && a.ctime === b.ctime;
}

function toStat(info: Deno.FileInfo): LocalStat {
  return {
    mtime: info.mtime?.getTime() ?? 0,
    ctime: info.ctime?.getTime() ?? info.mtime?.getTime() ?? 0,
    size: info.size,
    ino: info.ino,
  };
}

function parentOf(path: string): string {
  const i = path.lastIndexOf("/");
  return i < 0 ? "" : path.slice(0, i);
}

function baseName(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}

export interface Watcher {
  close(): Promise<void>;
}

export class LocalStore {
  readonly wikiDir: string;

  constructor(readonly vaultRoot: string, readonly wikiPrefix: string) {
    this.wikiDir = `${vaultRoot}/${wikiPrefix.replace(/\/$/, "")}`;
  }

  abs(path: string): string {
    return `${this.vaultRoot}/${path}`;
  }

  rel(abs: string): string {
    return abs.slice(this.vaultRoot.length + 1);
  }

  async rootInode(): Promise<number | null> {
    try {
      const info = await Deno.stat(this.wikiDir);
      if (!info.isDirectory) return null;
      for await (const _ of Deno.readDir(this.wikiDir)) break;
      return info.ino ?? 0;
    } catch {
      return null;
    }
  }

  private async requireRoot(): Promise<void> {
    if ((await this.rootInode()) === null) throw new RootMissing(this.wikiDir);
  }

  private async names(dir: string): Promise<string[]> {
    try {
      const out: string[] = [];
      for await (const e of Deno.readDir(this.abs(dir))) out.push(e.name);
      return out;
    } catch (e) {
      if (e instanceof Deno.errors.NotFound || e instanceof Deno.errors.NotADirectory) return [];
      throw e;
    }
  }

  async caseVariants(path: string): Promise<string[]> {
    const dir = parentOf(path);
    const want = baseName(path).toLowerCase();
    return (await this.names(dir)).filter((n) => n.toLowerCase() === want).map((
      n,
    ) => (dir ? `${dir}/${n}` : n));
  }

  async exists(path: string): Promise<boolean> {
    return (await this.names(parentOf(path))).includes(baseName(path));
  }

  async stat(path: string): Promise<LocalStat | null> {
    if (!(await this.exists(path))) return null;
    try {
      const info = await Deno.stat(this.abs(path));
      return info.isFile ? toStat(info) : null;
    } catch (e) {
      if (e instanceof Deno.errors.NotFound) return null;
      throw e;
    }
  }

  async read(path: string, known?: KnownStat): Promise<LocalRead> {
    for (let attempt = 0; attempt < 3; attempt++) {
      const before = await this.stat(path);
      if (!before) return { kind: "absent", path };
      const load = () => Deno.readFile(this.abs(path));
      if (known && sameStat(before, known)) {
        return {
          kind: "file",
          path,
          stat: before,
          hash: known.hash,
          generated: known.generated,
          bytes: load,
        };
      }
      const bytes = await load();
      const after = await this.stat(path);
      if (!after || !sameStat(before, after)) continue;
      return {
        kind: "file",
        path,
        stat: after,
        hash: await sha256Hex(bytes),
        generated: isGenerated(bytes),
        bytes: () => Promise.resolve(bytes),
      };
    }
    throw new Error(`${path} kept changing while it was read`);
  }

  async write(path: string, bytes: Uint8Array, mtime: number): Promise<LocalStat> {
    await this.requireRoot();
    const dir = parentOf(path);
    await Deno.mkdir(this.abs(dir), { recursive: true });
    const tmp = this.abs(`${dir}/.${baseName(path)}.tmp.${Deno.pid}.${crypto.randomUUID().slice(0, 8)}`);
    try {
      await Deno.writeFile(tmp, bytes);
      await Deno.utime(tmp, new Date(), new Date(mtime));
      await Deno.rename(tmp, this.abs(path));
    } catch (e) {
      await Deno.remove(tmp).catch(() => undefined);
      throw e;
    }
    return toStat(await Deno.stat(this.abs(path)));
  }

  async remove(path: string): Promise<void> {
    await this.requireRoot();
    if (!(await this.exists(path))) return;
    await Deno.remove(this.abs(path));
  }

  async *walk(dir = this.wikiPrefix.replace(/\/$/, "")): AsyncGenerator<{ path: string; stat: LocalStat }> {
    const entries: Deno.DirEntry[] = [];
    try {
      for await (const e of Deno.readDir(this.abs(dir))) entries.push(e);
    } catch (e) {
      if (e instanceof Deno.errors.NotFound) return;
      throw e;
    }
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const e of entries) {
      const path = `${dir}/${e.name}`;
      if (isIgnoredPath(path)) continue;
      if (e.isDirectory) {
        yield* this.walk(path);
      } else if (e.isFile) {
        const stat = await this.stat(path);
        if (stat) yield { path, stat };
      }
    }
  }

  async watch(onPath: (path: string, dir: boolean) => void): Promise<Watcher> {
    const w = chokidar.watch(this.wikiDir, {
      ignoreInitial: true,
      persistent: true,
      followSymlinks: false,
      ignored: (p: string) => p.length > this.wikiDir.length && isIgnoredPath(this.rel(p)),
    });
    const emit = (dir: boolean) => (p: string) => onPath(this.rel(p), dir);
    w.on("add", emit(false)).on("change", emit(false)).on("unlink", emit(false)).on("unlinkDir", emit(true));
    w.on("addDir", emit(true));
    await new Promise<void>((resolve) => w.once("ready", () => resolve()));
    return { close: () => w.close() };
  }
}
