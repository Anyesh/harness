export type Rev = string;

export interface LeafInfo {
  rev: Rev;
  hardDeleted: boolean;
  softDeleted: boolean;
  revisions: { start: number; ids: string[] };
  mtime: number;
}

export interface RevContent {
  hash: string;
  generated: boolean;
  mtime: number;
  deleted?: boolean;
}

export interface Synced {
  rev: Rev;
  ancestry: Rev[];
  hash: string | null;
  mtime: number;
}

export interface CopyDest {
  where: "vault" | "recovered";
  path: string;
}

export type Decision =
  | { state: "pending"; firstSeen: number; dest: CopyDest; wasBase: boolean }
  | { state: "copied"; dest: CopyDest }
  | { state: "none"; why: "echo" | "same" | "deletion" | "generated" | "superseded" };

export interface PathState {
  synced: Synced | null;
  pending?: { parentRev: Rev | null; hash: string | null };
  incoming?: Synced;
  recent: { rev: Rev; hash: string | null }[];
  decisions: Record<Rev, Decision>;
}

export type LocalVersion =
  | { kind: "absent"; seenAt?: number; duringPause?: boolean }
  | { kind: "file"; hash: string; mtime: number; ctime: number; generated: boolean; duringPause?: boolean };

export interface CopyAction {
  source: { kind: "local" } | { kind: "rev"; rev: Rev };
  dest: CopyDest;
  keep: boolean;
  rev?: Rev;
}

export interface RemoteAction {
  kind: "put" | "delete";
  parentRev: Rev | null;
  parentAncestry: Rev[];
}

export interface Plan {
  kind: "plan";
  hold?: "noRemote" | "regressed";
  copies: CopyAction[];
  remote?: RemoteAction;
  local?: { kind: "write"; rev: Rev } | { kind: "delete" };
  deferred: { rev: Rev; dest: CopyDest }[];
  state: PathState;
  recheckAt?: number;
}

export type ReconcileResult = Plan | { kind: "need"; revs: Rev[] } | { kind: "fail"; reason: string };

export interface ReconcileInput {
  path: string;
  state: PathState;
  local: LocalVersion;
  leaves: LeafInfo[];
  content: Map<Rev, RevContent | null>;
  now: number;
}

export const HISTORY_LIMIT = 100;
export const COPY_STABLE_MS = 30_000;
export const TIE_SLACK_MS = 2_000;

export function emptyState(): PathState {
  return { synced: null, recent: [], decisions: {} };
}

export function gen(rev: Rev): number {
  return Number(rev.slice(0, rev.indexOf("-")));
}

function revId(rev: Rev): string {
  return rev.slice(rev.indexOf("-") + 1);
}

export function ancestryOf(leaf: LeafInfo): Rev[] {
  return leaf.revisions.ids.map((id, i) => `${leaf.revisions.start - i}-${id}`);
}

export function winnerOf<T extends LeafInfo>(leaves: T[]): T {
  return leaves.reduce((best, l) => (outranks(l, best) ? l : best));
}

function outranks(a: LeafInfo, b: LeafInfo): boolean {
  if (a.hardDeleted !== b.hardDeleted) return !a.hardDeleted;
  if (gen(a.rev) !== gen(b.rev)) return gen(a.rev) > gen(b.rev);
  return revId(a.rev) > revId(b.rev);
}

type Relation = "equal" | "descends" | "ancestor" | "concurrent";

function relation(ancestry: Rev[], base: Synced): Relation {
  const rev = ancestry[0];
  if (rev === base.rev) return "equal";
  if (ancestry.includes(base.rev)) return "descends";
  const oldest = gen(rev) - ancestry.length + 1;
  if (oldest > gen(base.rev)) return "descends";
  if (base.ancestry.includes(rev)) return "ancestor";
  return "concurrent";
}

function coversWithOtherId(ancestry: Rev[], base: Synced): boolean {
  const g = gen(base.rev);
  const top = gen(ancestry[0]);
  const oldest = top - ancestry.length + 1;
  return oldest <= g && g <= top && ancestry[top - g] !== base.rev;
}

function utcStamp(ms: number): string {
  const d = new Date(ms);
  const p = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${p(d.getUTCFullYear(), 4)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}T${p(d.getUTCHours())}${
    p(d.getUTCMinutes())
  }${p(d.getUTCSeconds())}`;
}

function splitName(path: string): { dir: string; stem: string; ext: string } {
  const slash = path.lastIndexOf("/");
  const dir = slash >= 0 ? path.slice(0, slash + 1) : "";
  const base = path.slice(slash + 1);
  const dot = base.lastIndexOf(".");
  return dot > 0 ? { dir, stem: base.slice(0, dot), ext: base.slice(dot) } : { dir, stem: base, ext: "" };
}

export function copyName(path: string, mtime: number, hash: string): string {
  const { dir, stem, ext } = splitName(path);
  return `${dir}${stem}.conflict-${utcStamp(mtime)}-${hash.slice(0, 8)}${ext}`;
}

export function recoveredName(path: string, mtime: number, hash: string): string {
  const { dir, stem, ext } = splitName(path);
  return `${dir}${stem}.${utcStamp(mtime)}-${hash.slice(0, 8)}${ext}`;
}

export function withSuffix(path: string, n: number): string {
  const { dir, stem, ext } = splitName(path);
  return `${dir}${stem}-${n}${ext}`;
}

class Need {
  constructor(readonly revs: Rev[]) {}
}

class Unreadable {
  constructor(readonly rev: Rev) {}
}

export function reconcile(input: ReconcileInput): ReconcileResult {
  try {
    return decide(input);
  } catch (e) {
    if (e instanceof Need) return { kind: "need", revs: e.revs };
    if (e instanceof Unreadable) return { kind: "fail", reason: `revision ${e.rev} could not be read` };
    throw e;
  }
}

function decide(input: ReconcileInput): Plan {
  const { path, local, leaves, now } = input;
  const st: PathState = {
    synced: input.state.synced,
    pending: input.state.pending,
    incoming: input.state.incoming,
    recent: [...input.state.recent],
    decisions: { ...input.state.decisions },
  };
  const localHash = local.kind === "file" ? local.hash : null;

  const want = (revs: Rev[]): void => {
    const missing = revs.filter((r) => !input.content.has(r));
    if (missing.length > 0) throw new Need([...new Set(missing)]);
  };
  const contentOf = (rev: Rev): RevContent | null => {
    want([rev]);
    return input.content.get(rev) ?? null;
  };
  const versionOfRev = (rev: Rev): string | null | undefined => {
    if (st.synced?.rev === rev) return st.synced.hash;
    const known = st.recent.find((r) => r.rev === rev);
    if (known) return known.hash;
    const c = contentOf(rev);
    if (c === null) return undefined;
    return c.deleted ? null : c.hash;
  };
  const versionOfLeaf = (l: LeafInfo): string | null => {
    if (l.hardDeleted || l.softDeleted) return null;
    const v = versionOfRev(l.rev);
    if (v === undefined) throw new Unreadable(l.rev);
    return v;
  };

  const plan = (p: Partial<Plan>): Plan => ({ kind: "plan", copies: [], deferred: [], state: st, ...p });

  if (leaves.length === 0) {
    st.pending = undefined;
    st.incoming = undefined;
    if (st.synced) {
      if (st.synced.hash === null && local.kind === "absent") {
        return plan({ state: { ...emptyState(), recent: st.recent } });
      }
      return plan({ hold: "noRemote" });
    }
    if (local.kind === "file") {
      st.pending = { parentRev: null, hash: localHash };
      return plan({ remote: { kind: "put", parentRev: null, parentAncestry: [] } });
    }
    return plan({});
  }

  const anc = new Map<Rev, Rev[]>(leaves.map((l) => [l.rev, ancestryOf(l)]));
  const live = leaves.filter((l) => !l.hardDeleted);
  const winner = winnerOf(leaves);
  const syncedFromLeaf = (l: LeafInfo, hash: string | null): Synced => ({
    rev: l.rev,
    ancestry: anc.get(l.rev)!.slice(0, HISTORY_LIMIT),
    hash,
    mtime: l.mtime,
  });

  if (st.pending) {
    const p = st.pending;
    st.pending = undefined;
    let cand: { rev: Rev; ancestry: Rev[] } | undefined;
    for (const l of leaves) {
      const a = anc.get(l.rev)!;
      if (p.parentRev === null) {
        const root = a[a.length - 1];
        if (gen(root) === 1) cand = { rev: root, ancestry: [root] };
      } else {
        const k = a.indexOf(p.parentRev);
        if (k > 0) cand = { rev: a[k - 1], ancestry: a.slice(k - 1) };
      }
      if (cand) break;
    }
    if (cand) {
      const asLeaf = leaves.find((l) => l.rev === cand!.rev);
      const v = asLeaf && (asLeaf.softDeleted || asLeaf.hardDeleted) ? null : versionOfRev(cand.rev);
      if (v !== undefined && v === p.hash) {
        const mtime = asLeaf ? asLeaf.mtime : contentOf(cand.rev)!.mtime;
        st.synced = { rev: cand.rev, ancestry: cand.ancestry.slice(0, HISTORY_LIMIT), hash: v, mtime };
      }
    }
  }

  if (st.incoming) {
    if (st.incoming.hash === localHash) st.synced = st.incoming;
    st.incoming = undefined;
  }

  const base = st.synced;
  const rel = (l: LeafInfo): Relation => (base ? relation(anc.get(l.rev)!, base) : "concurrent");

  if (base) {
    const regressed = live.some((l) => rel(l) === "ancestor") ||
      (!leaves.some((l) => rel(l) === "equal" || rel(l) === "descends") &&
        leaves.some((l) => coversWithOtherId(anc.get(l.rev)!, base)));
    if (regressed) return plan({ hold: "regressed" });
  }

  let synced = base;
  let changed = synced ? localHash !== synced.hash : local.kind === "file";

  if (changed) {
    const winnerV = versionOfLeaf(winner);
    if (localHash === winnerV) {
      synced = syncedFromLeaf(winner, winnerV);
      changed = false;
    } else if (synced) {
      const descending = leaves.filter((l) => rel(l) === "descends");
      for (const l of descending) {
        if (l.hardDeleted) continue;
        if (versionOfLeaf(l) === localHash) {
          synced = syncedFromLeaf(l, localHash);
          changed = false;
          break;
        }
      }
      if (changed && local.kind === "file") {
        const between: { rev: Rev; ancestry: Rev[] }[] = [];
        for (const l of descending) {
          const a = anc.get(l.rev)!;
          const k = a.indexOf(synced.rev);
          const end = k < 0 ? a.length : k;
          for (let i = 1; i < end; i++) between.push({ rev: a[i], ancestry: a.slice(i) });
        }
        want(between.map((b) => b.rev));
        for (const b of between) {
          const c = input.content.get(b.rev);
          if (c && !c.deleted && c.hash === localHash) {
            synced = {
              rev: b.rev,
              ancestry: b.ancestry.slice(0, HISTORY_LIMIT),
              hash: localHash,
              mtime: c.mtime,
            };
            changed = false;
            break;
          }
        }
      }
    }
  }

  let stale = false;
  if (changed && local.kind === "file" && local.duringPause) {
    if (st.recent.some((r) => r.hash === localHash)) {
      stale = true;
    } else {
      const history = [...new Set(leaves.flatMap((l) => anc.get(l.rev)!))];
      want(history);
      stale = history.some((r) => {
        const c = input.content.get(r);
        return c && !c.deleted && c.hash === localHash;
      });
    }
    if (stale) changed = false;
  }

  const baseLeaf = synced ? live.find((l) => l.rev === synced!.rev) : undefined;
  const destFor = (p: string, mtime: number, hash: string): CopyDest =>
    synced
      ? { where: "vault", path: copyName(p, mtime, hash) }
      : { where: "recovered", path: recoveredName(p, mtime, hash) };

  if (changed && baseLeaf) {
    const remote: RemoteAction = local.kind === "file"
      ? { kind: "put", parentRev: baseLeaf.rev, parentAncestry: anc.get(baseLeaf.rev)! }
      : { kind: "delete", parentRev: baseLeaf.rev, parentAncestry: anc.get(baseLeaf.rev)! };
    st.synced = synced;
    st.pending = { parentRev: baseLeaf.rev, hash: localHash };
    return plan({ remote });
  }

  const winnerV = versionOfLeaf(winner);
  const copies: CopyAction[] = [];
  let localAction: Plan["local"];

  if (changed) {
    const localTime = local.kind === "file"
      ? Math.max(local.mtime, local.ctime)
      : local.seenAt ?? (synced ? synced.mtime + 1 : 0);
    const winnerTime = winner.hardDeleted ? 0 : winner.mtime;
    if (localTime > winnerTime + TIE_SLACK_MS) {
      const parentRev = winner.hardDeleted ? null : winner.rev;
      const remote: RemoteAction = local.kind === "file"
        ? { kind: "put", parentRev, parentAncestry: parentRev ? anc.get(winner.rev)! : [] }
        : { kind: "delete", parentRev: winner.rev, parentAncestry: anc.get(winner.rev)! };
      if (
        winnerV !== null && !contentOf(winner.rev)!.generated && winnerV !== synced?.hash &&
        winnerV !== localHash
      ) {
        const dest = destFor(path, winner.mtime, winnerV);
        copies.push({ source: { kind: "rev", rev: winner.rev }, dest, keep: true, rev: winner.rev });
        st.decisions[winner.rev] = { state: "copied", dest };
      }
      st.synced = synced;
      st.pending = { parentRev: remote.parentRev, hash: localHash };
      return plan({ remote, copies });
    }
    if (local.kind === "file" && !local.generated) {
      copies.push({ source: { kind: "local" }, dest: destFor(path, local.mtime, local.hash), keep: true });
    }
  } else if (
    baseLeaf && baseLeaf !== winner && synced!.hash !== null && synced!.hash !== winnerV &&
    st.decisions[baseLeaf.rev]?.state !== "copied"
  ) {
    const fromDisk = localHash === synced!.hash;
    const dest = destFor(path, baseLeaf.mtime, synced!.hash);
    copies.push({
      source: fromDisk ? { kind: "local" } : { kind: "rev", rev: baseLeaf.rev },
      dest,
      keep: fromDisk,
      rev: baseLeaf.rev,
    });
    st.decisions[baseLeaf.rev] = { state: "copied", dest };
  }

  if (winnerV === null) {
    if (local.kind === "file") localAction = { kind: "delete" };
  } else if (localHash !== winnerV) {
    localAction = { kind: "write", rev: winner.rev };
  }

  const deferred: { rev: Rev; dest: CopyDest }[] = [];
  let recheckAt: number | undefined;
  for (const l of live) {
    if (l === winner) continue;
    let d = st.decisions[l.rev];
    if (!d) {
      if (l.softDeleted) {
        d = { state: "none", why: "deletion" };
      } else {
        const c = contentOf(l.rev);
        if (c === null) throw new Unreadable(l.rev);
        if (c.generated) d = { state: "none", why: "generated" };
        else if ([localHash, base?.hash, synced?.hash, winnerV].includes(c.hash)) {
          d = { state: "none", why: "same" };
        } else if (rel(l) !== "descends" && st.recent.some((r) => r.hash === c.hash)) {
          d = { state: "none", why: "echo" };
        } else d = { state: "pending", firstSeen: now, dest: destFor(path, l.mtime, c.hash), wasBase: false };
      }
      st.decisions[l.rev] = d;
    }
    if (d.state === "pending") {
      const due = d.firstSeen + COPY_STABLE_MS;
      if (now >= due) deferred.push({ rev: l.rev, dest: d.dest });
      else recheckAt = Math.min(recheckAt ?? due, due);
    }
  }

  const liveRevs = new Set(live.map((l) => l.rev));
  for (const rev of Object.keys(st.decisions)) {
    if (!liveRevs.has(rev)) delete st.decisions[rev];
  }

  const next = syncedFromLeaf(winner, winnerV);
  st.synced = next;
  remember(st, next);
  return plan({ copies, local: localAction, deferred, recheckAt });
}

export function remember(st: PathState, s: { rev: Rev; hash: string | null }): void {
  if (st.recent.at(-1)?.rev === s.rev) return;
  st.recent = [...st.recent.filter((r) => r.rev !== s.rev), { rev: s.rev, hash: s.hash }].slice(
    -HISTORY_LIMIT,
  );
}
