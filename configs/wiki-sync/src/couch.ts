import { DirectFileManipulator } from "@vrtmrz/livesync-commonlib";
import { createBinaryBlob, createTextBlob } from "@vrtmrz/livesync-commonlib/compat/common/utils";
import { isPlainText } from "@vrtmrz/livesync-commonlib/compat/string_and_binary/path";
import type { FilePathWithPrefix } from "@vrtmrz/livesync-commonlib/compat/common/types";
import { decodeBinary } from "octagonal-wheels/binary";
import { sha256Hex } from "./base.ts";
import { isGenerated } from "./local.ts";
import { errText, log } from "./log.ts";
import type { CasResult, Change, FeedHandle, RemoteLeaf, RemoteStore, RevBody } from "./remote.ts";
import type { Connection } from "./settings.ts";

export const SALT_DOC = "_local/obsidian_livesync_sync_parameters";
export const MILESTONE_DOC = "_local/obsydian_livesync_milestone";
const REQUEST_TIMEOUT_MS = 60_000;
const LONGPOLL_MS = 30_000;

export type RemoteState = "ok" | "unreachable" | "auth" | "error";

export class RemoteHttpError extends Error {
  constructor(readonly status: number, what: string) {
    super(`${what}: HTTP ${status}`);
  }
}

export interface RemoteIdentity {
  salt: string | null;
  created: number | null;
  milestone: Record<string, unknown> | null;
  instance: string | null;
}

export function classifyError(e: unknown): RemoteState {
  if (e instanceof RemoteHttpError) return e.status === 401 || e.status === 403 ? "auth" : "error";
  const status = (e as { status?: number })?.status;
  if (status === 401 || status === 403) return "auth";
  if (e instanceof TypeError || (e instanceof DOMException && e.name === "TimeoutError")) {
    return "unreachable";
  }
  const msg = errText(e);
  if (/timed out|timeout|network|connection|ECONN|fetch failed|unreachable/i.test(msg)) return "unreachable";
  return "error";
}

export class Couch {
  feedTs = 0;
  readonly authHeader: string;

  constructor(readonly conn: Connection) {
    this.authHeader = `Basic ${btoa(`${conn.username}:${conn.password}`)}`;
  }

  readonly fetch = async (input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const isChanges = /\/_changes(\?|$)/.test(url);
    const timeout = AbortSignal.timeout(isChanges ? LONGPOLL_MS + REQUEST_TIMEOUT_MS : REQUEST_TIMEOUT_MS);
    const signal = init.signal ? AbortSignal.any([init.signal, timeout]) : timeout;
    const res = await fetch(input, { ...init, signal });
    if (isChanges) this.feedTs = Date.now();
    return res;
  };

  async rawGet(docId: string): Promise<Record<string, unknown> | null> {
    const url = `${this.conn.url}/${encodeURIComponent(this.conn.database)}/${docId}`;
    const res = await this.fetch(url, {
      headers: { authorization: this.authHeader, accept: "application/json" },
    });
    if (res.status === 404) {
      await res.body?.cancel();
      return null;
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new RemoteHttpError(res.status, `GET ${docId}`);
    }
    return await res.json();
  }

  async identity(): Promise<RemoteIdentity> {
    const [params, milestone, info] = await Promise.all([
      this.rawGet(SALT_DOC),
      this.rawGet(MILESTONE_DOC),
      this.rawGet(""),
    ]);
    const salt = typeof params?.pbkdf2salt === "string" ? params.pbkdf2salt : null;
    const created = typeof milestone?.created === "number" ? milestone.created : null;
    // CouchDB 3.3+ reports the database's creation time here; older releases always say "0".
    const started = info?.instance_start_time;
    const instance = typeof started === "string" && started !== "0" ? started : null;
    return { salt, created, milestone, instance };
  }
}

function toBytes(doc: { data: string | string[]; type: string }): Uint8Array {
  if (doc.type === "newnote") return new Uint8Array(decodeBinary(doc.data));
  const text = typeof doc.data === "string" ? doc.data : doc.data.join("");
  return new TextEncoder().encode(text);
}

function toBlob(path: string, bytes: Uint8Array): Blob {
  if (isPlainText(path)) {
    try {
      const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
      return createTextBlob(text);
    } catch {
      log.debug(`${path} is not valid UTF-8; storing it as binary`);
    }
  }
  return createBinaryBlob(new Uint8Array(bytes));
}

interface PouchLike {
  // deno-lint-ignore no-explicit-any
  get(id: string, opts?: Record<string, unknown>): Promise<any>;
  // deno-lint-ignore no-explicit-any
  put(doc: any): Promise<{ ok: boolean; rev: string }>;
  // deno-lint-ignore no-explicit-any
  changes(opts: Record<string, unknown>): any;
}

export interface CouchRemoteOptions {
  couch: Couch;
  manipulatorOptions: Record<string, unknown>;
  prefix: string;
  beforeWrite: () => Promise<void>;
}

export class CouchRemote implements RemoteStore {
  private manip!: DirectFileManipulator;
  private db!: PouchLike;
  private prefixId = "";

  private constructor(private readonly o: CouchRemoteOptions) {}

  static async open(o: CouchRemoteOptions, expectedSalt: string): Promise<CouchRemote> {
    const r = new CouchRemote(o);
    // deno-lint-ignore no-explicit-any
    const manip = new DirectFileManipulator(o.manipulatorOptions as any, { fetch: o.couch.fetch } as any);
    const refuse = () => {
      throw new Error("refusing to write sync parameters: the salt document must already exist");
    };
    // deno-lint-ignore no-explicit-any
    const m = manip as any;
    m.putSyncParameters = refuse;
    m.getInitialSyncParameters = refuse;
    await manip.ready.promise;
    const salt: Uint8Array = await m.getReplicationPBKDF2Salt(m.getSettings());
    const expected = Uint8Array.from(atob(expectedSalt), (c) => c.charCodeAt(0));
    if (salt.length !== expected.length || salt.some((b, i) => b !== expected[i])) {
      throw new Error("the salt commonlib loaded differs from the salt document");
    }
    r.manip = manip;
    r.db = manip.liveSyncLocalDB.localDatabase as unknown as PouchLike;
    // A live-base put of a new doc sets an empty `_rev`, which PouchDB rejects as
    // "Invalid rev format"; without the key the create fails with 409 on an existing doc.
    const put = r.db.put.bind(r.db);
    r.db.put = (doc: Record<string, unknown>, ...rest: unknown[]) => {
      if (doc && "_rev" in doc && doc._rev == null) {
        const { _rev: _, ...clean } = doc;
        return (put as (...a: unknown[]) => Promise<{ ok: boolean; rev: string }>)(clean, ...rest);
      }
      return (put as (...a: unknown[]) => Promise<{ ok: boolean; rev: string }>)(doc, ...rest);
    };
    r.prefixId = await manip.path2id(o.prefix as FilePathWithPrefix);
    return r;
  }

  async close(): Promise<void> {
    await this.manip.close();
  }

  idOf(path: string): Promise<string> {
    return this.manip.path2id(path as FilePathWithPrefix);
  }

  accepts(path: string): boolean {
    return path.startsWith(this.o.prefix) && this.manip.liveSyncLocalDB.isTargetFile(path);
  }

  feedTs(): number {
    return this.o.couch.feedTs;
  }

  async currentSeq(): Promise<string> {
    const info = await this.o.couch.rawGet("");
    return String(info?.update_seq ?? "0");
  }

  async readLeaves(id: string): Promise<RemoteLeaf[]> {
    let rows: { ok?: Record<string, unknown> }[];
    try {
      rows = await this.db.get(id, { open_revs: "all", revs: true });
    } catch (e) {
      if ((e as { status?: number }).status === 404) return [];
      throw e;
    }
    const leaves: RemoteLeaf[] = [];
    for (const row of rows) {
      const doc = row.ok;
      if (!doc) continue;
      const revisions = doc._revisions as { start: number; ids: string[] };
      const hard = doc._deleted === true;
      leaves.push({
        rev: doc._rev as string,
        hardDeleted: hard,
        softDeleted: !hard && doc.deleted === true,
        revisions,
        mtime: typeof doc.mtime === "number" ? doc.mtime : 0,
        path: hard || typeof doc.path !== "string" ? null : doc.path,
      });
    }
    return leaves;
  }

  async readRev(id: string, rev: string): Promise<RevBody | null> {
    let meta: Record<string, unknown>;
    try {
      meta = await this.db.get(id, { rev });
    } catch (e) {
      if ((e as { status?: number }).status === 404) return null;
      throw e;
    }
    if (meta._deleted || (meta.type !== "plain" && meta.type !== "newnote")) return null;
    // deno-lint-ignore no-explicit-any
    const doc = await this.manip.getByMeta(meta as any).catch((e: unknown) => {
      if (classifyError(e) !== "error") throw e;
      log.warn(`${meta.path}@${rev.slice(0, 12)} could not be decoded: ${errText(e)}`);
      return null;
    });
    if (!doc) return null;
    const bytes = toBytes(doc as unknown as { data: string | string[]; type: string });
    return {
      content: {
        hash: await sha256Hex(bytes),
        generated: isGenerated(bytes),
        mtime: typeof meta.mtime === "number" ? meta.mtime : 0,
        deleted: meta.deleted === true,
      },
      bytes,
      path: String(meta.path),
    };
  }

  async casPut(
    path: string,
    bytes: Uint8Array,
    times: { mtime: number; ctime: number },
    parentRev: string | null,
  ): Promise<CasResult> {
    await this.o.beforeWrite();
    const id = await this.idOf(path);
    const data = toBlob(path, bytes);
    const note = {
      _id: id,
      path,
      data,
      ctime: times.ctime,
      mtime: times.mtime,
      size: data.size,
      type: "plain",
      datatype: "plain",
      eden: {},
      children: [],
    };
    type Note = Parameters<typeof this.manip.liveSyncLocalDB.putDBEntryWithLiveBaseRevision>[0];
    const res = await this.manip.liveSyncLocalDB.putDBEntryWithLiveBaseRevision(
      note as unknown as Note,
      (parentRev ?? undefined) as string,
    );
    if (res && typeof res === "object" && "rev" in res) return { rev: res.rev as string, mtime: times.mtime };
    const leaves = await this.readLeaves(id);
    const live = leaves.filter((l) => !l.hardDeleted);
    if (parentRev === null ? live.length > 0 : !live.some((l) => l.rev === parentRev)) return "conflict";
    throw new Error(`put of ${path} was refused`);
  }

  async casDelete(path: string, parentRev: string): Promise<CasResult> {
    await this.o.beforeWrite();
    const id = await this.idOf(path);
    let obj: Record<string, unknown>;
    try {
      obj = await this.db.get(id, { rev: parentRev });
    } catch (e) {
      if ((e as { status?: number }).status === 404) return "conflict";
      throw e;
    }
    delete obj._deleted;
    obj.deleted = true;
    const mtime = Date.now();
    obj.mtime = mtime;
    try {
      const r = await this.db.put(obj);
      return { rev: r.rev, mtime };
    } catch (e) {
      if ((e as { status?: number }).status === 409) return "conflict";
      throw e;
    }
  }

  changes(opts: { since: string; live: boolean; onChange: (c: Change) => void }): FeedHandle {
    const feed = this.db.changes({
      since: opts.since === "" ? 0 : opts.since,
      live: opts.live,
      include_docs: false,
      style: "all_docs",
      selector: { type: { $ne: "leaf" } },
      timeout: LONGPOLL_MS,
      heartbeat: false,
      return_docs: false,
    });
    let lastSeq = opts.since === "" ? "0" : opts.since;
    feed.on("change", (c: { id: string; seq: string | number }) => {
      lastSeq = String(c.seq);
      if (c.id.startsWith(this.prefixId)) opts.onChange({ id: c.id, seq: lastSeq });
    });
    const done = new Promise<{ lastSeq: string; error?: unknown }>((resolve) => {
      feed.on("complete", (info: { last_seq?: string | number }) => {
        if (info?.last_seq !== undefined) lastSeq = String(info.last_seq);
        resolve({ lastSeq });
      });
      feed.on("error", (error: unknown) => resolve({ lastSeq, error }));
    });
    return { cancel: () => feed.cancel(), done };
  }
}
