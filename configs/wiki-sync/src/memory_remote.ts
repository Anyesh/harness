import { sha256Hex } from "./base.ts";
import { isGenerated } from "./local.ts";
import { gen, winnerOf } from "./reconcile.ts";
import type { CasResult, Change, FeedHandle, RemoteLeaf, RemoteStore, RevBody } from "./remote.ts";

interface RevNode {
  rev: string;
  parent: string | null;
  hard: boolean;
  soft: boolean;
  path: string;
  bytes: Uint8Array;
  mtime: number;
}

interface Doc {
  revs: Map<string, RevNode>;
}

export class Offline extends Error {
  constructor() {
    super("remote unreachable");
  }
}

export class MemoryRemote implements RemoteStore {
  docs = new Map<string, Doc>();
  log: Change[] = [];
  offline = false;
  writes = 0;
  failPutsFor = new Set<string>();
  failReadsFor = new Set<string>();
  undecodable = new Set<string>();
  longpollMs = 50;
  private seq = 0;
  private lastFeed = 0;
  private listeners = new Set<() => void>();

  idOf(path: string): Promise<string> {
    return Promise.resolve(path.toLowerCase());
  }

  accepts(path: string): boolean {
    return !path.startsWith(".");
  }

  private check(): void {
    if (this.offline) throw new Offline();
  }

  private ancestry(doc: Doc, rev: string): string[] {
    const out: string[] = [];
    for (let r: string | null = rev; r; r = doc.revs.get(r)!.parent) out.push(r);
    return out;
  }

  private leafRevs(doc: Doc): string[] {
    const parents = new Set([...doc.revs.values()].map((n) => n.parent).filter(Boolean));
    return [...doc.revs.keys()].filter((r) => !parents.has(r));
  }

  readLeaves(id: string): Promise<RemoteLeaf[]> {
    this.check();
    if (this.failReadsFor.has(id)) return Promise.reject(new Error(`injected read failure for ${id}`));
    const doc = this.docs.get(id);
    if (!doc) return Promise.resolve([]);
    return Promise.resolve(
      this.leafRevs(doc).map((rev) => {
        const n = doc.revs.get(rev)!;
        const anc = this.ancestry(doc, rev);
        return {
          rev,
          hardDeleted: n.hard,
          softDeleted: n.soft,
          revisions: { start: gen(rev), ids: anc.map((r) => r.slice(r.indexOf("-") + 1)) },
          mtime: n.hard ? 0 : n.mtime,
          path: n.hard ? null : n.path,
        };
      }),
    );
  }

  async readRev(id: string, rev: string): Promise<RevBody | null> {
    this.check();
    const n = this.docs.get(id)?.revs.get(rev);
    if (!n || n.hard || this.undecodable.has(rev)) return null;
    return {
      content: {
        hash: await sha256Hex(n.bytes),
        generated: isGenerated(n.bytes),
        mtime: n.mtime,
        deleted: n.soft,
      },
      bytes: n.bytes,
      path: n.path,
    };
  }

  private newRev(parent: string | null): string {
    return `${parent ? gen(parent) + 1 : 1}-${crypto.randomUUID().replaceAll("-", "")}`;
  }

  private commit(id: string, node: RevNode): string {
    let doc = this.docs.get(id);
    if (!doc) this.docs.set(id, doc = { revs: new Map() });
    doc.revs.set(node.rev, node);
    this.writes++;
    this.log.push({ id, seq: `${++this.seq}-x` });
    for (const l of this.listeners) l();
    return node.rev;
  }

  async casPut(
    path: string,
    bytes: Uint8Array,
    times: { mtime: number; ctime: number },
    parentRev: string | null,
  ): Promise<CasResult> {
    this.check();
    if (this.failPutsFor.has(path)) throw new Error(`injected failure for ${path}`);
    const id = await this.idOf(path);
    const doc = this.docs.get(id);
    let parent = parentRev;
    if (parentRev === null) {
      if (doc) {
        const leaves = await this.readLeaves(id);
        const w = winnerOf(leaves);
        if (!w.hardDeleted) return "conflict";
        parent = w.rev;
      }
    } else if (!doc || !this.leafRevs(doc).includes(parentRev) || doc.revs.get(parentRev)!.hard) {
      return "conflict";
    }
    const rev = this.commit(id, {
      rev: this.newRev(parent),
      parent,
      hard: false,
      soft: false,
      path,
      bytes,
      mtime: times.mtime,
    });
    return { rev, mtime: times.mtime };
  }

  async casDelete(path: string, parentRev: string): Promise<CasResult> {
    this.check();
    const id = await this.idOf(path);
    const doc = this.docs.get(id);
    if (!doc || !this.leafRevs(doc).includes(parentRev) || doc.revs.get(parentRev)!.hard) return "conflict";
    const base = doc.revs.get(parentRev)!;
    const mtime = Date.now();
    const rev = this.commit(id, {
      ...base,
      rev: this.newRev(parentRev),
      parent: parentRev,
      soft: true,
      mtime,
    });
    return { rev, mtime };
  }

  async edit(
    path: string,
    text: string | Uint8Array,
    mtime = Date.now(),
    parentRev?: string,
  ): Promise<string> {
    const id = await this.idOf(path);
    const bytes = typeof text === "string" ? new TextEncoder().encode(text) : text;
    const parent = parentRev ?? (this.docs.has(id) ? winnerOf(await this.readLeaves(id)).rev : null);
    return this.commit(id, {
      rev: this.newRev(parent),
      parent,
      hard: false,
      soft: false,
      path,
      bytes,
      mtime,
    });
  }

  async branch(path: string, fromRev: string | null, texts: string[], mtime = Date.now()): Promise<string> {
    const id = await this.idOf(path);
    let parent = fromRev;
    for (const t of texts) {
      parent = this.commit(id, {
        rev: this.newRev(parent),
        parent,
        hard: false,
        soft: false,
        path,
        bytes: new TextEncoder().encode(t),
        mtime,
      });
    }
    return parent!;
  }

  async softDelete(path: string): Promise<string> {
    const id = await this.idOf(path);
    const w = winnerOf(await this.readLeaves(id));
    const r = await this.casDelete(path, w.rev);
    if (r === "conflict") throw new Error("delete conflict");
    return r.rev;
  }

  async retire(path: string, rev: string): Promise<void> {
    const id = await this.idOf(path);
    const base = this.docs.get(id)!.revs.get(rev)!;
    this.commit(id, { ...base, rev: this.newRev(rev), parent: rev, hard: true, soft: false });
  }

  async text(path: string): Promise<string | null> {
    const id = await this.idOf(path);
    if (!this.docs.has(id)) return null;
    const w = winnerOf(await this.readLeaves(id));
    if (w.hardDeleted || w.softDeleted) return null;
    return new TextDecoder().decode((await this.readRev(id, w.rev))!.bytes);
  }

  async leafCount(path: string): Promise<number> {
    return (await this.readLeaves(await this.idOf(path))).filter((l) => !l.hardDeleted).length;
  }

  feedTs(): number {
    return this.lastFeed;
  }

  changes(opts: { since: string; live: boolean; onChange: (c: Change) => void }): FeedHandle {
    let cancelled = false;
    let wake: (() => void) | null = null;
    const start = opts.since === "" ? 0 : Number(opts.since.split("-")[0]);
    const done = (async () => {
      let pos = start;
      let lastSeq = opts.since === "" ? "0" : opts.since;
      try {
        while (!cancelled) {
          this.check();
          const latest = new Map<string, Change>();
          for (const c of this.log.slice(pos)) {
            latest.delete(c.id);
            latest.set(c.id, c);
          }
          pos = this.log.length;
          for (const c of latest.values()) {
            opts.onChange(c);
            lastSeq = c.seq;
          }
          if (!opts.live) return { lastSeq: pos === 0 ? "0" : this.log[pos - 1].seq };
          await new Promise<void>((resolve) => {
            wake = resolve;
            this.listeners.add(resolve);
            setTimeout(resolve, this.longpollMs);
          });
          this.listeners.delete(wake!);
          this.lastFeed = Date.now();
        }
        return { lastSeq };
      } catch (error) {
        return { lastSeq, error };
      }
    })();
    return {
      cancel: () => {
        cancelled = true;
        wake?.();
      },
      done,
    };
  }
}
