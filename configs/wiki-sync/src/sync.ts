import { type BaseStore, type JsonFile, type PathRecord, sha256Hex } from "./base.ts";
import {
  type FileRead,
  type KnownStat,
  type LocalRead,
  type LocalStore,
  RootMissing,
  sameStat,
} from "./local.ts";
import { errText, log } from "./log.ts";
import {
  ancestryOf,
  type CopyAction,
  type CopyDest,
  emptyState,
  HISTORY_LIMIT,
  type LocalVersion,
  type Plan,
  reconcile,
  remember,
  type RemoteAction,
  type RevContent,
  winnerOf,
  withSuffix,
} from "./reconcile.ts";
import type { Change, FeedHandle, RemoteLeaf, RemoteStore, RevBody } from "./remote.ts";

export type BlockReason = "paused" | "locked" | "feed";

export class Blocked extends Error {
  constructor(readonly reason: BlockReason) {
    super(`blocked: ${reason}`);
  }
}

class UnreadableRevision extends Error {
  constructor(readonly path: string, rev: string) {
    super(`revision ${rev.slice(0, 12)} cannot be decoded`);
  }
}

export interface Gate {
  check(): Promise<void>;
}

export interface PauseWindow {
  from: number;
  to: number | null;
}

export interface SyncConfig {
  quietMs: number;
  retryMs: number;
  guardMs: number;
  scanMs: number;
  checkpointMs: number;
  feedRestartMs: number;
  pollMs: number;
  maxConflicts: number;
}

export const DEFAULT_CONFIG: SyncConfig = {
  quietMs: 2_000,
  retryMs: 60_000,
  guardMs: 10_000,
  scanMs: 300_000,
  checkpointMs: 10_000,
  feedRestartMs: 10_000,
  pollMs: 2_000,
  maxConflicts: 3,
};

export interface SyncDeps {
  remote: RemoteStore;
  local: LocalStore;
  bases: BaseStore;
  checkpoint: JsonFile<{ since: string }>;
  pauses: JsonFile<PauseWindow[]>;
  gate: Gate;
  identity: () => Promise<boolean>;
  recoveredDir: string;
  releaseMarker: string;
  config?: Partial<SyncConfig>;
}

export interface SyncHealth {
  failing: { path: string; since: number }[];
  failedCount: number;
  heldDeletions: number;
  collisions: number;
  noRemote: number;
  regressed: number;
  unreadable: number;
  oldestHandlerMs: number;
  caughtUp: boolean;
  root: "ok" | "missing";
  feedTs: number;
  remoteError: string | null;
}

interface Hint {
  path?: string;
  seenAt?: number;
  released?: boolean;
}

type Outcome = "ok" | "held" | "deferred";

interface Pending {
  hint: Hint;
  promise: Promise<void>;
  resolve: () => void;
}

interface Tracked {
  seq: string;
  done: boolean;
  sentinel?: boolean;
}

type Timer = ReturnType<typeof setTimeout>;

const PAUSE_WINDOW_KEEP_MS = 7 * 24 * 3600_000;
const REV_CACHE_LIMIT = 256;

function mergeHint(a: Hint, b: Hint): Hint {
  return {
    path: b.path ?? a.path,
    seenAt: a.seenAt !== undefined && b.seenAt !== undefined
      ? Math.min(a.seenAt, b.seenAt)
      : a.seenAt ?? b.seenAt,
    released: a.released || b.released,
  };
}

export class KeyedLock {
  private tails = new Map<string, Promise<unknown>>();

  run<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.tails.get(key) ?? Promise.resolve();
    const next = prev.then(fn, fn);
    const tail = next.catch(() => undefined);
    this.tails.set(key, tail);
    tail.then(() => {
      if (this.tails.get(key) === tail) this.tails.delete(key);
    });
    return next;
  }

  async idle(): Promise<void> {
    while (this.tails.size > 0) await Promise.all([...this.tails.values()]);
  }
}

export class Syncer {
  private readonly cfg: SyncConfig;
  private readonly lock = new KeyedLock();
  private readonly pending = new Map<string, Pending>();
  private readonly parked = new Map<string, Hint>();
  private readonly running = new Map<string, number>();
  private readonly failing = new Map<string, { path: string; since: number }>();
  private readonly retryTimers = new Map<string, Timer>();
  private readonly waiters = new Map<string, (() => void)[]>();
  private readonly recheckTimers = new Map<string, Timer>();
  private readonly quietTimers = new Map<string, { timer: Timer; seenAt: number }>();
  private readonly revCache = new Map<string, RevBody>();
  private guardBatch = new Map<string, Hint>();
  private guardTimer: Timer | null = null;
  private heldDeletions = new Map<string, Hint>();
  private intervals: ReturnType<typeof setInterval>[] = [];
  private feed: FeedHandle | null = null;
  private feedGen = 0;
  private tracked: Tracked[] = [];
  private handledSeq = "";
  private savedSeq = "";
  private liveSeq = "";
  private caughtUp = false;
  private paused = false;
  private feedBlocked = false;
  private stopped = false;
  private rootIno: number | null = null;
  private watchedIno: number | null = null;
  private remoteError: string | null = null;
  private watcher: { close(): Promise<void> } | null = null;
  private windows: PauseWindow[] = [];

  constructor(private readonly d: SyncDeps) {
    this.cfg = { ...DEFAULT_CONFIG, ...d.config };
  }

  async start(paused = false): Promise<void> {
    this.handledSeq = this.savedSeq = (await this.d.checkpoint.read({ since: "" })).since;
    const cutoff = Date.now() - PAUSE_WINDOW_KEEP_MS;
    this.windows = (await this.d.pauses.read([])).filter((w) => w.to === null || w.to > cutoff);
    for (const w of this.windows) w.to ??= Date.now();
    this.rootIno = await this.d.local.rootInode();
    this.paused = paused;
    if (paused) await this.openPauseWindow();
    await this.startWatcher();
    this.intervals.push(
      setInterval(
        () => this.saveCheckpoint().catch((e) => log.warn(`checkpoint: ${errText(e)}`)),
        this.cfg.checkpointMs,
      ),
      setInterval(() => this.scan().catch((e) => log.warn(`scan: ${errText(e)}`)), this.cfg.scanMs),
      setInterval(() => this.poll().catch((e) => log.warn(`poll: ${errText(e)}`)), this.cfg.pollMs),
    );
    await this.restartFeed();
    if (!paused) await this.scan();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    for (const i of this.intervals) clearInterval(i);
    for (const t of [...this.retryTimers.values(), ...this.recheckTimers.values()]) clearTimeout(t);
    for (const q of this.quietTimers.values()) clearTimeout(q.timer);
    if (this.guardTimer !== null) clearTimeout(this.guardTimer);
    this.feed?.cancel();
    await this.watcher?.close();
    let timer: Timer | undefined;
    await Promise.race([this.lock.idle(), new Promise((r) => (timer = setTimeout(r, 10_000)))]);
    clearTimeout(timer);
    await this.saveCheckpoint();
  }

  isPaused(): boolean {
    return this.paused;
  }

  async pause(): Promise<void> {
    if (this.paused) return;
    this.paused = true;
    log.notice("Obsidian is open on this vault: pausing writes");
    await this.openPauseWindow();
  }

  async resume(): Promise<void> {
    if (!this.paused) return;
    this.paused = false;
    const open = this.windows.find((w) => w.to === null);
    if (open) open.to = Date.now();
    await this.d.pauses.write(this.windows);
    log.notice("Obsidian closed: resuming");
    await this.restartFeed();
    await this.scan();
    this.unpark();
  }

  private async openPauseWindow(): Promise<void> {
    if (!this.windows.some((w) => w.to === null)) this.windows.push({ from: Date.now(), to: null });
    await this.d.pauses.write(this.windows);
  }

  health(): SyncHealth {
    const now = Date.now();
    const records = this.d.bases.all();
    const failing = [...this.failing.values()].sort((a, b) => a.since - b.since);
    return {
      failing: failing.slice(0, 5),
      failedCount: failing.length,
      heldDeletions: this.heldDeletions.size,
      collisions: records.filter((r) => r.held === "collision").length,
      noRemote: records.filter((r) => r.held === "noRemote").length,
      regressed: records.filter((r) => r.held === "regressed").length,
      unreadable: records.filter((r) => r.held === "unreadable").length,
      oldestHandlerMs: Math.max(0, ...[...this.running.values()].map((t) => now - t)),
      caughtUp: this.caughtUp,
      root: this.rootIno === null ? "missing" : "ok",
      feedTs: this.d.remote.feedTs(),
      remoteError: this.remoteError,
    };
  }

  async idle(): Promise<void> {
    for (let i = 0; i < 1000; i++) {
      await this.lock.idle();
      await new Promise((r) => setTimeout(r, 5));
      if (this.pending.size === 0 && this.quietTimers.size === 0 && this.guardTimer === null) return;
    }
  }

  onLocalEvent(path: string, dir: boolean): void {
    if (this.stopped) return;
    const prev = this.quietTimers.get(path);
    if (prev) clearTimeout(prev.timer);
    const seenAt = prev?.seenAt ?? Date.now();
    const timer = setTimeout(() => {
      this.quietTimers.delete(path);
      (dir ? this.onDirEvent(path) : this.onFileEvent(path, seenAt)).catch((e) =>
        log.warn(`event ${path}: ${errText(e)}`)
      );
    }, this.cfg.quietMs);
    this.quietTimers.set(path, { timer, seenAt });
  }

  private async onFileEvent(path: string, seenAt: number): Promise<void> {
    if (!this.d.remote.accepts(path)) return;
    const id = await this.d.remote.idOf(path);
    void this.enqueue(id, { path, seenAt });
  }

  private async onDirEvent(dir: string): Promise<void> {
    const prefix = `${dir}/`;
    for (const r of this.d.bases.all()) {
      if (r.path.startsWith(prefix)) void this.enqueue(r.id, { path: r.path, seenAt: Date.now() });
    }
    for await (const e of this.d.local.walk(dir)) {
      if (!this.d.remote.accepts(e.path)) continue;
      void this.enqueue(await this.d.remote.idOf(e.path), { path: e.path });
    }
  }

  async scan(): Promise<void> {
    if (this.stopped || this.paused) return;
    if ((await this.d.local.rootInode()) === null) return;
    const seen = new Set<string>();
    for await (const e of this.d.local.walk()) {
      if (!this.d.remote.accepts(e.path)) continue;
      const id = await this.d.remote.idOf(e.path);
      seen.add(id);
      const rec = this.d.bases.get(id);
      if (!rec || !rec.stat || rec.path !== e.path || !sameStat(rec.stat, e.stat)) {
        void this.enqueue(id, { path: e.path });
      }
    }
    const now = Date.now();
    for (const r of this.d.bases.all()) {
      if (r.held) void this.enqueue(r.id, { path: r.path });
      else if (!seen.has(r.id) && r.synced && r.synced.hash !== null) {
        void this.enqueue(r.id, { path: r.path });
      } else if (r.recheckAt !== undefined) this.scheduleRecheck(r.id, r.recheckAt - now);
    }
    for (const id of this.heldDeletions.keys()) void this.enqueue(id, {});
  }

  private async poll(): Promise<void> {
    if (this.stopped) return;
    const ino = await this.d.local.rootInode();
    if (ino === null) {
      if (this.rootIno !== null) {
        log.warn(`wiki root ${this.d.local.wikiDir} is missing: holding all changes`);
      }
      this.rootIno = null;
    } else if (ino !== this.rootIno) {
      this.rootIno = ino;
      log.notice(`wiki root ${this.d.local.wikiDir} is readable again`);
      if (ino !== this.watchedIno) {
        await this.watcher?.close();
        this.watcher = null;
        await this.startWatcher();
      }
      await this.restartFeed();
      await this.scan();
    }
    if (this.heldDeletions.size > 0) {
      try {
        await Deno.stat(this.d.releaseMarker);
        const batch = [...this.heldDeletions];
        this.heldDeletions.clear();
        log.notice(`releasing ${batch.length} held deletions`);
        await Promise.all(batch.map(([id, hint]) => this.enqueue(id, { ...hint, released: true })));
        await Deno.remove(this.d.releaseMarker).catch(() => undefined);
      } catch (e) {
        if (!(e instanceof Deno.errors.NotFound)) throw e;
      }
    }
  }

  private async startWatcher(): Promise<void> {
    if (this.rootIno === null) return;
    this.watchedIno = this.rootIno;
    this.watcher = await this.d.local.watch((p, dir) => this.onLocalEvent(p, dir));
  }

  enqueue(id: string, hint: Hint): Promise<void> {
    const existing = this.pending.get(id);
    if (existing) {
      existing.hint = mergeHint(existing.hint, hint);
      return existing.promise;
    }
    let resolve!: () => void;
    const promise = new Promise<void>((r) => (resolve = r));
    const entry: Pending = { hint, promise, resolve };
    this.pending.set(id, entry);
    this.lock.run(id, () => this.runOnce(id, entry));
    return promise;
  }

  private unpark(): void {
    const parked = [...this.parked];
    this.parked.clear();
    for (const [id, hint] of parked) void this.enqueue(id, hint);
  }

  private async runOnce(id: string, entry: Pending): Promise<void> {
    if (this.pending.get(id) === entry) this.pending.delete(id);
    if (this.stopped) return;
    const retry = this.retryTimers.get(id);
    if (retry !== undefined) {
      clearTimeout(retry);
      this.retryTimers.delete(id);
    }
    this.running.set(id, Date.now());
    try {
      await this.handle(id, entry.hint);
      this.failing.delete(id);
      this.remoteError = null;
      entry.resolve();
      for (const w of this.waiters.get(id) ?? []) w();
      this.waiters.delete(id);
    } catch (e) {
      this.waiters.set(id, [...(this.waiters.get(id) ?? []), entry.resolve]);
      if (e instanceof Blocked) {
        this.parked.set(id, mergeHint(this.parked.get(id) ?? {}, entry.hint));
        return;
      }
      const path = entry.hint.path ?? this.d.bases.get(id)?.path ?? id;
      if (!this.failing.has(id)) this.failing.set(id, { path, since: Date.now() });
      if (!(e instanceof RootMissing)) this.remoteError = errText(e);
      log.warn(`${path}: ${errText(e)}; retrying in ${Math.round(this.cfg.retryMs / 1000)} s`);
      const timer = setTimeout(() => {
        this.retryTimers.delete(id);
        void this.enqueue(id, entry.hint);
      }, this.cfg.retryMs);
      this.retryTimers.set(id, timer);
    } finally {
      this.running.delete(id);
    }
  }

  private scheduleRecheck(id: string, delay: number): void {
    const prev = this.recheckTimers.get(id);
    if (prev !== undefined) clearTimeout(prev);
    const timer = setTimeout(() => {
      this.recheckTimers.delete(id);
      void this.enqueue(id, {});
    }, Math.max(0, delay));
    this.recheckTimers.set(id, timer);
  }

  private async guard(): Promise<void> {
    if (this.paused) throw new Blocked("paused");
    if (this.feedBlocked) throw new Blocked("feed");
    await this.d.gate.check();
  }

  private async readRev(id: string, rev: string): Promise<RevBody | null> {
    const key = `${id}\u0000${rev}`;
    const hit = this.revCache.get(key);
    if (hit) return hit;
    const body = await this.d.remote.readRev(id, rev);
    if (body) {
      this.revCache.set(key, body);
      if (this.revCache.size > REV_CACHE_LIMIT) this.revCache.delete(this.revCache.keys().next().value!);
    }
    return body;
  }

  // Deno reports ctime in whole seconds, so a window opens at the start of its second.
  private duringPause(ctime: number): boolean {
    return this.windows.some((w) =>
      ctime >= Math.floor(w.from / 1000) * 1000 && ctime <= (w.to ?? Date.now())
    );
  }

  private toLocalVersion(read: LocalRead, hint: Hint): LocalVersion {
    if (read.kind === "absent") return { kind: "absent", seenAt: hint.seenAt };
    return {
      kind: "file",
      hash: read.hash,
      mtime: read.stat.mtime,
      ctime: read.stat.ctime,
      generated: read.generated,
      duringPause: this.duringPause(read.stat.ctime),
    };
  }

  private known(rec: PathRecord): KnownStat | undefined {
    const s = rec.stat as KnownStat | undefined;
    return s && typeof s.hash === "string" ? s : undefined;
  }

  private async resolveLocalPath(id: string, rec: PathRecord, remotePath: string | null, hint: Hint) {
    const candidates = [rec.path, hint.path, remotePath].filter((p): p is string => !!p);
    const existing = new Set<string>();
    for (const c of candidates) {
      for (const v of await this.d.local.caseVariants(c)) {
        if ((await this.d.remote.idOf(v)) === id) existing.add(v);
      }
    }
    return { existing: [...existing], fallback: rec.path || remotePath || hint.path || id };
  }

  // A case-only rename keeps the content hash, so reconcile sees no local change; it is pushed
  // when the disk is at the synced winner and only the local name moved away from the synced one.
  private caseRenamePush(
    rec: PathRecord,
    next: PathRecord,
    localPath: string,
    read: LocalRead,
    winner: RemoteLeaf | null,
    plan: Plan,
  ): RemoteAction | undefined {
    if (plan.local || read.kind !== "file" || !winner || winner.hardDeleted || winner.softDeleted) return;
    if (!rec.path || localPath === rec.path || winner.path !== rec.path) return;
    if (next.synced?.rev !== winner.rev || next.synced.hash !== read.hash) return;
    next.pending = { parentRev: winner.rev, hash: read.hash };
    return { kind: "put", parentRev: winner.rev, parentAncestry: ancestryOf(winner) };
  }

  private async handle(id: string, hint: Hint): Promise<Outcome> {
    try {
      return await this.settle(id, hint);
    } catch (e) {
      if (!(e instanceof UnreadableRevision)) throw e;
      const rec: PathRecord = this.d.bases.get(id) ?? { ...emptyState(), id, path: e.path };
      if (rec.held !== "unreadable") log.warn(`${e.path}: held (${e.message})`);
      await this.save({ ...rec, path: rec.path || e.path, held: "unreadable" });
      return "held";
    }
  }

  private async settle(id: string, hint: Hint): Promise<Outcome> {
    if ((await this.d.local.rootInode()) === null) throw new RootMissing(this.d.local.wikiDir);
    if (this.paused) throw new Blocked("paused");
    let rec: PathRecord = this.d.bases.get(id) ?? { ...emptyState(), id, path: hint.path ?? "" };
    let conflicts = 0;
    for (let pass = 0; pass < 10; pass++) {
      const leaves = await this.d.remote.readLeaves(id);
      const liveLeaves = leaves.filter((l) => !l.hardDeleted);
      const winner = leaves.length ? winnerOf(leaves) : null;
      const remotePath = (winner && !winner.hardDeleted ? winner.path : liveLeaves[0]?.path) ?? null;
      const names = await this.resolveLocalPath(id, rec, remotePath, hint);
      if (names.existing.length > 1) {
        if (rec.held !== "collision") log.warn(`case collision held: ${names.existing.join(", ")}`);
        await this.save({ ...rec, held: "collision" });
        return "held";
      }
      const localPath = names.existing[0] ?? names.fallback;
      if (!this.d.remote.accepts(localPath)) return "ok";
      const read = await this.d.local.read(localPath, this.known(rec));
      const local = this.toLocalVersion(read, hint);
      const content = new Map<string, RevContent | null>();
      let res = reconcile({ path: localPath, state: rec, local, leaves, content, now: Date.now() });
      while (res.kind === "need") {
        for (const rev of res.revs) content.set(rev, (await this.readRev(id, rev))?.content ?? null);
        res = reconcile({ path: localPath, state: rec, local, leaves, content, now: Date.now() });
      }
      if (res.kind === "unreadable") throw new UnreadableRevision(localPath, res.rev);
      const plan: Plan = res;
      if (plan.hold) {
        if (rec.held !== plan.hold) log.warn(`${localPath}: held (${plan.hold})`);
        await this.save({ ...rec, ...plan.state, held: plan.hold });
        return "held";
      }
      if (plan.remote?.kind === "delete" && !hint.released) {
        this.collectDeletion(id, { ...hint, path: localPath });
        return "deferred";
      }
      this.heldDeletions.delete(id);
      const next: PathRecord = { ...rec, ...plan.state, held: undefined, path: rec.path || localPath };

      for (const c of plan.copies) await this.writeCopy(id, c, read, next);
      for (const dfr of plan.deferred) {
        await this.writeCopy(
          id,
          { source: { kind: "rev", rev: dfr.rev }, dest: dfr.dest, keep: false, rev: dfr.rev },
          read,
          next,
        );
      }

      const remote = plan.remote ?? this.caseRenamePush(rec, next, localPath, read, winner, plan);
      if (remote) {
        await this.guard();
        await this.save(next);
        const r = remote.kind === "put" && read.kind === "file"
          ? await this.d.remote.casPut(localPath, await read.bytes(), read.stat, remote.parentRev)
          : await this.d.remote.casDelete(localPath, remote.parentRev!);
        if (r === "conflict") {
          if (++conflicts > this.cfg.maxConflicts) throw new Error("kept conflicting with concurrent writes");
          rec = { ...next, pending: undefined };
          continue;
        }
        const hash = read.kind === "file" ? read.hash : null;
        next.synced = {
          rev: r.rev,
          ancestry: [r.rev, ...remote.parentAncestry].slice(0, HISTORY_LIMIT),
          hash,
          mtime: r.mtime,
        };
        next.pending = undefined;
        next.path = localPath;
        next.stat = read.kind === "file" ? this.statWithHash(read) : undefined;
        remember(next, next.synced);
        log.info(`${remote.kind === "put" ? "pushed" : "deleted"} ${localPath} (${r.rev.slice(0, 12)})`);
        await this.save(next);
        rec = next;
        continue;
      }

      const target = winner && !winner.hardDeleted && !winner.softDeleted && winner.path
        ? winner.path
        : localPath;
      const renamed = read.kind === "file" && target !== localPath && plan.local?.kind !== "delete";
      if (plan.local || renamed) {
        await this.guard();
        const now = await this.d.local.stat(localPath);
        const before = read.kind === "file" ? read.stat : null;
        if ((now === null) !== (before === null) || (now && before && !sameStat(now, before))) {
          rec = this.d.bases.get(id) ?? rec;
          continue;
        }
        if (plan.local?.kind === "delete") {
          await this.save({ ...rec, incoming: next.synced ?? undefined });
          await this.d.local.remove(localPath);
          next.stat = undefined;
          log.info(`removed ${localPath}`);
        } else {
          const body = plan.local?.kind === "write" ? await this.readRev(id, plan.local.rev) : null;
          if (plan.local?.kind === "write" && !body) {
            throw new UnreadableRevision(localPath, plan.local.rev);
          }
          const bytes = body ? body.bytes : await (read as FileRead).bytes();
          const mtime = body ? body.content.mtime : (read as FileRead).stat.mtime;
          await this.save({ ...rec, incoming: next.synced ?? undefined });
          const stat = await this.d.local.write(target, bytes, mtime);
          if (target !== localPath && (await this.d.local.exists(localPath))) {
            await this.d.local.remove(localPath);
          }
          const hash = body ? body.content.hash : (read as FileRead).hash;
          const generated = body ? body.content.generated : (read as FileRead).generated;
          next.stat = { ...stat, hash, generated } as KnownStat;
          next.path = target;
          log.info(`${target !== localPath ? `renamed ${localPath} to` : "updated"} ${target}`);
        }
      } else if (read.kind === "file") {
        next.stat = this.statWithHash(read);
        next.path = localPath;
      } else {
        next.stat = undefined;
      }
      next.incoming = undefined;
      next.recheckAt = plan.recheckAt;
      if (plan.recheckAt !== undefined) this.scheduleRecheck(id, plan.recheckAt - Date.now());
      await this.save(next);
      return "ok";
    }
    throw new Error("did not settle after repeated passes");
  }

  private statWithHash(read: FileRead): KnownStat {
    return { ...read.stat, hash: read.hash, generated: read.generated };
  }

  private async save(rec: PathRecord): Promise<void> {
    const empty = !rec.synced && !rec.pending && !rec.held && Object.keys(rec.decisions).length === 0 &&
      rec.recent.length === 0;
    if (empty) await this.d.bases.delete(rec.id);
    else await this.d.bases.put(rec);
  }

  private async writeCopy(id: string, c: CopyAction, read: LocalRead, next: PathRecord): Promise<void> {
    await this.guard();
    let bytes: Uint8Array;
    let mtime: number;
    if (c.source.kind === "local") {
      if (read.kind !== "file") return;
      bytes = await read.bytes();
      mtime = read.stat.mtime;
    } else {
      const body = await this.readRev(id, c.source.rev);
      if (!body) throw new UnreadableRevision(next.path, c.source.rev);
      bytes = body.bytes;
      mtime = body.content.mtime;
    }
    const hash = await sha256Hex(bytes);
    const record = (dest: CopyDest) => {
      if (c.rev) next.decisions[c.rev] = { state: "copied", dest };
    };
    if (c.dest.where === "recovered") {
      const target = `${this.d.recoveredDir}/${c.dest.path}`;
      try {
        await Deno.stat(target);
      } catch (e) {
        if (!(e instanceof Deno.errors.NotFound)) throw e;
        await Deno.mkdir(target.slice(0, target.lastIndexOf("/")), { recursive: true });
        const tmp = `${target}.tmp.${Deno.pid}`;
        await Deno.writeFile(tmp, bytes);
        await Deno.utime(tmp, new Date(), new Date(mtime));
        await Deno.rename(tmp, target);
        log.notice(`kept a losing version of ${c.dest.path} in ${target}`);
      }
      record(c.dest);
      return;
    }
    for (let n = 1; n < 100; n++) {
      const path = n === 1 ? c.dest.path : withSuffix(c.dest.path, n);
      const copyId = await this.d.remote.idOf(path);
      const leaves = await this.d.remote.readLeaves(copyId);
      if (leaves.length > 0) {
        const w = winnerOf(leaves);
        if (w.hardDeleted || w.softDeleted) {
          if (!c.keep) {
            record({ where: "vault", path });
            return;
          }
          continue;
        }
        // A version this machine overwrites gets its own copy: a live copy with the same content can be
        // one somebody is deleting because they just picked it, which is the version being overwritten.
        const body = c.keep ? null : await this.readRev(copyId, w.rev);
        if (body && body.content.hash === hash) {
          record({ where: "vault", path });
          return;
        }
        continue;
      }
      const existing = await this.d.local.read(path);
      if (existing.kind === "file") {
        if (existing.hash === hash) {
          record({ where: "vault", path });
          return;
        }
        continue;
      }
      await this.d.local.write(path, bytes, mtime);
      log.notice(`kept a conflicting version as ${path}`);
      record({ where: "vault", path });
      void this.enqueue(copyId, { path });
      return;
    }
    throw new Error(`no free name for a copy of ${c.dest.path}`);
  }

  private collectDeletion(id: string, hint: Hint): void {
    if (this.heldDeletions.has(id)) {
      this.heldDeletions.set(id, hint);
      return;
    }
    this.guardBatch.set(id, hint);
    if (this.guardTimer !== null) return;
    this.guardTimer = setTimeout(() => {
      this.guardTimer = null;
      const batch = this.guardBatch;
      this.guardBatch = new Map();
      const withContent = this.d.bases.withContent();
      if (batch.size >= 20 && batch.size > withContent * 0.1) {
        for (const [k, v] of batch) this.heldDeletions.set(k, v);
        log.warn(
          `held ${batch.size} local deletions (of ${withContent} synced files); run run.sh --release-deletions to push them`,
        );
        return;
      }
      for (const [k, v] of batch) void this.enqueue(k, { ...v, released: true });
    }, this.cfg.guardMs);
  }

  private onChange(c: Change, gen: number): void {
    this.liveSeq = c.seq;
    if (this.paused) {
      void this.lock.run(c.id, () => this.observe(c.id)).catch((e) =>
        log.debug(`observe ${c.id}: ${errText(e)}`)
      );
      return;
    }
    const entry: Tracked = { seq: c.seq, done: false };
    this.tracked.push(entry);
    this.enqueue(c.id, {}).then(() => {
      if (gen !== this.feedGen) return;
      entry.done = true;
      this.advance();
    });
  }

  private advance(): void {
    while (this.tracked.length > 0 && this.tracked[0].done) {
      const t = this.tracked.shift()!;
      this.handledSeq = t.seq;
      if (t.sentinel) this.caughtUp = true;
    }
  }

  private async observe(id: string): Promise<void> {
    const leaves = await this.d.remote.readLeaves(id);
    if (leaves.length === 0) return;
    const w = winnerOf(leaves);
    let hash: string | null = null;
    if (!w.hardDeleted && !w.softDeleted) {
      const body = await this.readRev(id, w.rev);
      if (!body) return;
      hash = body.content.hash;
    }
    const rec = this.d.bases.get(id) ?? { ...emptyState(), id, path: w.path ?? "" };
    remember(rec, { rev: w.rev, hash });
    await this.d.bases.put(rec);
  }

  async saveCheckpoint(): Promise<void> {
    if (this.handledSeq === this.savedSeq) return;
    const seq = this.handledSeq;
    await this.d.checkpoint.write({ since: seq });
    this.savedSeq = seq;
  }

  private async restartFeed(): Promise<void> {
    if (this.stopped) return;
    const gen = ++this.feedGen;
    this.feed?.cancel();
    this.feed = null;
    this.tracked = [];
    const since = this.handledSeq;
    const pass = this.d.remote.changes({ since, live: false, onChange: (c) => this.onChange(c, gen) });
    const res = await pass.done;
    if (gen !== this.feedGen) return;
    if (res.error) {
      this.remoteError = errText(res.error);
      log.warn(`changes feed failed: ${this.remoteError}; retrying in ${this.cfg.feedRestartMs / 1000} s`);
      this.feedBlocked = true;
      setTimeout(() => this.recoverFeed(gen), this.cfg.feedRestartMs);
      return;
    }
    const sentinel: Tracked = { seq: res.lastSeq, done: true, sentinel: true };
    this.tracked.push(sentinel);
    this.advance();
    this.followLive(gen, res.lastSeq);
  }

  private followLive(gen: number, since: string): void {
    this.liveSeq = since;
    const h = this.d.remote.changes({ since, live: true, onChange: (c) => this.onChange(c, gen) });
    this.feed = h;
    h.done.then((res) => {
      if (gen !== this.feedGen || this.stopped) return;
      if (res.error) {
        this.remoteError = errText(res.error);
        log.warn(
          `changes feed stopped: ${this.remoteError}; restarting in ${this.cfg.feedRestartMs / 1000} s`,
        );
        this.feedBlocked = true;
      }
      setTimeout(() => this.recoverFeed(gen), this.cfg.feedRestartMs);
    });
  }

  private async recoverFeed(gen: number): Promise<void> {
    if (gen !== this.feedGen || this.stopped) return;
    let ok = false;
    try {
      ok = await this.d.identity();
    } catch (e) {
      this.remoteError = errText(e);
    }
    if (!ok) {
      setTimeout(() => this.recoverFeed(gen), this.cfg.feedRestartMs);
      return;
    }
    const wasBlocked = this.feedBlocked;
    this.feedBlocked = false;
    this.remoteError = null;
    if (this.tracked.some((t) => t.sentinel) || this.caughtUp) {
      this.followLive(gen, this.liveSeq || this.handledSeq);
    } else {
      await this.restartFeed();
    }
    if (wasBlocked) this.unpark();
  }

  // A recreated database numbers its changes afresh, so the saved seq can skip everything in it.
  async replayFromStart(): Promise<void> {
    this.handledSeq = "";
    this.liveSeq = "";
    this.caughtUp = false;
    await this.d.checkpoint.write({ since: "" });
    this.savedSeq = "";
    await this.restartFeed();
  }

  async restartFromCheckpoint(): Promise<void> {
    await this.restartFeed();
    await this.scan();
    this.unpark();
  }
}
