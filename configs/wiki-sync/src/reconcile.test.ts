import { assertEquals, assertObjectMatch } from "@std/assert";
import {
  copyName,
  emptyState,
  type LeafInfo,
  type LocalVersion,
  type PathState,
  type Plan,
  reconcile,
  type ReconcileInput,
  recoveredName,
  type RevContent,
  winnerOf,
} from "./reconcile.ts";

const PATH = "wiki/projects/a/note.md";
const NOW = 1_800_000_000_000;

function leaf(rev: string, ancestors: string[] = [], opts: Partial<LeafInfo> = {}): LeafInfo {
  const [gen] = rev.split("-");
  const ids = [rev, ...ancestors].map((r) => r.split("-")[1]);
  return {
    rev,
    hardDeleted: false,
    softDeleted: false,
    revisions: { start: Number(gen), ids },
    mtime: NOW - 60_000,
    ...opts,
  };
}

function file(hash: string, mtime = NOW - 120_000, extra: Partial<LocalVersion> = {}): LocalVersion {
  return { kind: "file", hash, mtime, ctime: mtime, generated: false, ...extra } as LocalVersion;
}

const ABSENT: LocalVersion = { kind: "absent" };

function synced(rev: string, hash: string | null, ancestors: string[] = [], mtime = NOW - 600_000) {
  return { rev, ancestry: [rev, ...ancestors], hash, mtime };
}

function state(s: Partial<PathState> = {}): PathState {
  return { ...emptyState(), ...s };
}

function content(entries: Record<string, string | null | RevContent>): Map<string, RevContent | null> {
  const m = new Map<string, RevContent | null>();
  for (const [rev, v] of Object.entries(entries)) {
    if (v === null) m.set(rev, null);
    else if (typeof v === "string") m.set(rev, { hash: v, generated: false, mtime: NOW - 60_000 });
    else m.set(rev, v);
  }
  return m;
}

function run(input: Partial<ReconcileInput>): Plan {
  const full: ReconcileInput = {
    path: PATH,
    state: emptyState(),
    local: ABSENT,
    leaves: [],
    content: new Map(),
    now: NOW,
    ...input,
  };
  const res = reconcile(full);
  if (res.kind !== "plan") throw new Error(`expected a plan, got need ${JSON.stringify(res)}`);
  return res;
}

Deno.test("winner follows CouchDB: live before deleted, then generation, then rev id", () => {
  assertEquals(winnerOf([leaf("2-a"), leaf("3-b", [], { hardDeleted: true })]).rev, "2-a");
  assertEquals(winnerOf([leaf("2-a"), leaf("3-b")]).rev, "3-b");
  assertEquals(winnerOf([leaf("3-a"), leaf("3-b")]).rev, "3-b");
  assertEquals(winnerOf([leaf("3-a", [], { softDeleted: true }), leaf("2-b")]).rev, "3-a");
});

Deno.test("copy names depend only on the losing version", () => {
  const t = Date.UTC(2026, 9, 30, 1, 2, 3);
  assertEquals(
    copyName("wiki/a/note.md", t, "abcdef0123"),
    "wiki/a/note.conflict-20261030T010203-abcdef01.md",
  );
  assertEquals(
    copyName("wiki/a/Makefile", t, "abcdef0123"),
    "wiki/a/Makefile.conflict-20261030T010203-abcdef01",
  );
  assertEquals(recoveredName("wiki/a/note.md", t, "abcdef0123"), "wiki/a/note.20261030T010203-abcdef01.md");
});

Deno.test("reconcile asks for the content it needs before deciding", () => {
  const res = reconcile({
    path: PATH,
    state: emptyState(),
    local: file("L"),
    leaves: [leaf("1-a")],
    content: new Map(),
    now: NOW,
  });
  assertEquals(res, { kind: "need", revs: ["1-a"] });
});

Deno.test("no base and no remote doc: a local file is pushed as a new doc", () => {
  const p = run({ local: file("L") });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: null } });
  assertEquals(p.local, undefined);
});

Deno.test("no base, no doc and no file: nothing to do", () => {
  const p = run({});
  assertEquals(p.remote, undefined);
  assertEquals(p.local, undefined);
  assertEquals(p.state.synced, null);
});

Deno.test("no base and a missing local file: the remote is written, never deleted", () => {
  const p = run({ leaves: [leaf("1-a")], content: content({ "1-a": "A" }) });
  assertEquals(p.local, { kind: "write", rev: "1-a" });
  assertEquals(p.remote, undefined);
  assertEquals(p.state.synced?.rev, "1-a");
});

Deno.test("no base and identical content with a different mtime records the base only", () => {
  const p = run({
    local: file("A", NOW - 9_999_999),
    leaves: [leaf("1-a")],
    content: content({ "1-a": "A" }),
  });
  assertEquals(p.remote, undefined);
  assertEquals(p.local, undefined);
  assertEquals(p.copies, []);
  assertEquals(p.state.synced?.rev, "1-a");
  assertEquals(p.state.synced?.hash, "A");
});

Deno.test("no base and a newer local version: pushed onto the winner, old winner kept in recovered", () => {
  const p = run({
    local: file("L", NOW - 1000),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "B" }),
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "2-b" } });
  assertEquals(p.copies.length, 1);
  assertObjectMatch(p.copies[0], { source: { kind: "rev", rev: "2-b" }, dest: { where: "recovered" } });
});

Deno.test("no base and an older local version: winner written, local version kept in recovered", () => {
  const p = run({ local: file("L", NOW - 999_999), leaves: [leaf("1-a")], content: content({ "1-a": "A" }) });
  assertEquals(p.local, { kind: "write", rev: "1-a" });
  assertEquals(p.copies.length, 1);
  assertObjectMatch(p.copies[0], { source: { kind: "local" }, dest: { where: "recovered" }, keep: true });
});

Deno.test("the winner takes ties within 2 s", () => {
  const p = run({
    local: file("L", NOW - 60_000 + 1500),
    leaves: [leaf("1-a")],
    content: content({ "1-a": "A" }),
  });
  assertEquals(p.local, { kind: "write", rev: "1-a" });
});

Deno.test("a local version's time is the later of mtime and ctime", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("L", NOW - 999_999, { ctime: NOW - 1000 }),
    leaves: [leaf("2-b", ["1-a"]), leaf("2-c", ["1-a"], { mtime: NOW - 5000 })],
    content: content({ "2-b": "B", "2-c": "C" }),
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "2-c" } });
});

Deno.test("unchanged local and a descending remote: fast-forward the file", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("A"),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "B" }),
  });
  assertEquals(p.local, { kind: "write", rev: "2-b" });
  assertEquals(p.remote, undefined);
  assertEquals(p.copies, []);
  assertEquals(p.state.synced?.rev, "2-b");
});

Deno.test("changed local with the base leaf live: pushed onto the base leaf whatever its mtime", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("L", NOW - 99_999_999),
    leaves: [leaf("1-a")],
    content: content({ "1-a": "A" }),
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "1-a" } });
  assertEquals(p.copies, []);
  assertEquals(p.state.pending, { parentRev: "1-a", hash: "L" });
});

Deno.test("changed local with the base leaf live beside an outranking sibling still pushes onto the base", () => {
  const p = run({
    state: state({ synced: synced("2-a", "A", ["1-r"]) }),
    local: file("L"),
    leaves: [leaf("2-a", ["1-r"]), leaf("6-o", ["5-o", "4-o", "3-o", "2-o", "1-r"])],
    content: content({ "2-a": "A", "6-o": "O" }),
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "2-a" } });
});

Deno.test("changed local, remote moved on, local newer: push onto winner and copy the old winner, which no leaf keeps any more", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("L", NOW - 1000),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "B" }),
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "2-b" } });
  assertEquals(p.copies.length, 1);
  assertObjectMatch(p.copies[0], {
    source: { kind: "rev", rev: "2-b" },
    dest: { where: "vault" },
    keep: true,
  });
});

Deno.test("changed local, remote moved on, local older: winner written and local copied beside it", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("L", NOW - 999_999),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "B" }),
  });
  assertEquals(p.local, { kind: "write", rev: "2-b" });
  assertObjectMatch(p.copies[0], { source: { kind: "local" }, dest: { where: "vault" }, keep: true });
});

Deno.test("old winner with the same content as the base gets no copy", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("L", NOW - 1000),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "A" }),
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "2-b" } });
  assertEquals(p.copies, []);
});

Deno.test("a remote soft deletion of an unchanged note removes it", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("A"),
    leaves: [leaf("2-d", ["1-a"], { softDeleted: true })],
  });
  assertEquals(p.local, { kind: "delete" });
  assertEquals(p.state.synced?.hash, null);
});

Deno.test("a local deletion with the base leaf live is pushed as a deletion", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: { kind: "absent", seenAt: NOW },
    leaves: [leaf("1-a")],
  });
  assertEquals(p.remote?.kind, "delete");
  assertObjectMatch(p, { remote: { parentRev: "1-a" } });
});

Deno.test("a scan deletion is stamped from the base and loses to a later edit, with no copy", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A", [], NOW - 600_000) }),
    local: { kind: "absent" },
    leaves: [leaf("2-b", ["1-a"], { mtime: NOW - 500_000 })],
    content: content({ "2-b": "B" }),
  });
  assertEquals(p.local, { kind: "write", rev: "2-b" });
  assertEquals(p.remote, undefined);
  assertEquals(p.copies, []);
});

Deno.test("two deletions are the same version: no tombstone over a deleted head", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: { kind: "absent", seenAt: NOW },
    leaves: [leaf("2-d", ["1-a"], { softDeleted: true })],
  });
  assertEquals(p.remote, undefined);
  assertEquals(p.local, undefined);
  assertEquals(p.state.synced?.rev, "2-d");
});

Deno.test("an absent base and a missing file are unchanged", () => {
  const p = run({
    state: state({ synced: synced("2-d", null, ["1-a"]) }),
    local: { kind: "absent" },
    leaves: [leaf("2-d", ["1-a"], { softDeleted: true })],
  });
  assertEquals(p.remote, undefined);
  assertEquals(p.local, undefined);
});

Deno.test("a new file at a deleted path is pushed onto the deletion with no copy", () => {
  const p = run({
    state: state({ synced: synced("2-d", null, ["1-a"]) }),
    local: file("N", NOW - 99_999_999),
    leaves: [leaf("2-d", ["1-a"], { softDeleted: true })],
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "2-d" } });
  assertEquals(p.copies, []);
});

Deno.test("a newer remote deletion of a locally edited file keeps the edit in a copy", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("L", NOW - 999_999),
    leaves: [leaf("2-d", ["1-a"], { softDeleted: true, mtime: NOW - 10_000 })],
  });
  assertEquals(p.local, { kind: "delete" });
  assertObjectMatch(p.copies[0], { source: { kind: "local" }, keep: true });
});

Deno.test("a live leaf that is a strict ancestor of the base is a regression", () => {
  const p = run({
    state: state({ synced: synced("3-c", "C", ["2-b", "1-a"]) }),
    local: file("C"),
    leaves: [leaf("2-b", ["1-a"])],
  });
  assertEquals(p.hold, "regressed");
  assertEquals(p.remote, undefined);
  assertEquals(p.local, undefined);
});

Deno.test("a leaf covering the base generation with another id and nothing descending is a regression", () => {
  const p = run({
    state: state({ synced: synced("3-c", "C", ["2-b", "1-a"]) }),
    local: file("C"),
    leaves: [leaf("4-x", ["3-x", "2-b", "1-a"])],
  });
  assertEquals(p.hold, "regressed");
});

Deno.test("trimmed history above the base generation counts as descending", () => {
  const anc = Array.from({ length: 9 }, (_, i) => `${99 - i}-t`);
  const p = run({
    state: state({ synced: synced("2-b", "B", ["1-a"]) }),
    local: file("B"),
    leaves: [leaf("100-z", anc)],
    content: content({ "100-z": "Z" }),
  });
  assertEquals(p.hold, undefined);
  assertEquals(p.local, { kind: "write", rev: "100-z" });
});

Deno.test("a base with no remote doc at all is held, never pushed", () => {
  const p = run({ state: state({ synced: synced("1-a", "A") }), local: file("L") });
  assertEquals(p.hold, "noRemote");
  assertEquals(p.remote, undefined);
});

Deno.test("a push that committed after its request failed is recognised as our own", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A"), pending: { parentRev: "1-a", hash: "L" } }),
    local: file("L"),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "L" }),
  });
  assertEquals(p.remote, undefined);
  assertEquals(p.local, undefined);
  assertEquals(p.state.synced?.rev, "2-b");
  assertEquals(p.state.pending, undefined);
});

Deno.test("a pending push for a new doc is matched against the root revision", () => {
  const p = run({
    state: state({ pending: { parentRev: null, hash: "L" } }),
    local: file("L"),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "1-a": "L", "2-b": "B" }),
  });
  assertEquals(p.remote, undefined);
  assertEquals(p.local, { kind: "write", rev: "2-b" });
  assertEquals(p.copies, []);
});

Deno.test("a file equal to a revision between the base and the winner fast-forwards", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("C", NOW),
    leaves: [leaf("4-d", ["3-c", "2-b", "1-a"])],
    content: content({ "4-d": "D", "3-c": "C", "2-b": "B" }),
  });
  assertEquals(p.remote, undefined);
  assertEquals(p.local, { kind: "write", rev: "4-d" });
  assertEquals(p.copies, []);
});

Deno.test("an incoming write recorded before a crash is not a local edit", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A"), incoming: synced("2-b", "B", ["1-a"]) }),
    local: file("B", NOW),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "B" }),
  });
  assertEquals(p.remote, undefined);
  assertEquals(p.local, undefined);
  assertEquals(p.state.synced?.rev, "2-b");
  assertEquals(p.state.incoming, undefined);
});

Deno.test("a file equal to a losing leaf that does not descend from the base is a local change", () => {
  const p = run({
    state: state({ synced: synced("2-a", "A", ["1-r"]) }),
    local: file("O", NOW, { ctime: NOW }),
    leaves: [leaf("3-a", ["2-a", "1-r"]), leaf("2-o", ["1-r"])],
    content: content({ "3-a": "A3", "2-o": "O" }),
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "3-a" } });
});

Deno.test("conflict between two descendants: winner written, loser pending for 30 s, base not copied", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("A"),
    leaves: [leaf("2-x", ["1-a"]), leaf("2-y", ["1-a"])],
    content: content({ "2-x": "X", "2-y": "Y" }),
  });
  assertEquals(p.local, { kind: "write", rev: "2-y" });
  assertEquals(p.copies, []);
  assertEquals(p.deferred, []);
  assertObjectMatch(p.state.decisions["2-x"], { state: "pending", firstSeen: NOW, dest: { where: "vault" } });
  assertEquals(p.recheckAt, NOW + 30_000);
});

Deno.test("a pending loser still losing after 30 s is due for a copy", () => {
  const dest = { where: "vault" as const, path: copyName(PATH, NOW - 60_000, "X") };
  const p = run({
    state: state({
      synced: synced("2-y", "Y", ["1-a"]),
      decisions: { "2-x": { state: "pending", firstSeen: NOW - 31_000, dest, wasBase: false } },
    }),
    local: file("Y"),
    leaves: [leaf("2-x", ["1-a"]), leaf("2-y", ["1-a"])],
    content: content({ "2-x": "X", "2-y": "Y" }),
  });
  assertEquals(p.deferred, [{ rev: "2-x", dest }]);
});

Deno.test("decisions for revs that are no longer leaves are dropped", () => {
  const dest = { where: "vault" as const, path: "x" };
  const p = run({
    state: state({
      synced: synced("2-y", "Y", ["1-a"]),
      decisions: { "2-x": { state: "pending", firstSeen: NOW - 31_000, dest, wasBase: false } },
    }),
    local: file("Y"),
    leaves: [leaf("2-y", ["1-a"]), leaf("3-x", ["2-x", "1-a"], { hardDeleted: true })],
    content: content({ "2-y": "Y" }),
  });
  assertEquals(p.deferred, []);
  assertEquals(p.state.decisions, {});
});

Deno.test("an echo leaf matching a recently synced version gets no copy", () => {
  const p = run({
    state: state({
      synced: synced("3-a", "A3", ["2-a", "1-r"]),
      recent: [{ rev: "2-a", hash: "A2" }, { rev: "3-a", hash: "A3" }],
    }),
    local: file("A3"),
    leaves: [leaf("3-a", ["2-a", "1-r"]), leaf("2-e", ["1-r"])],
    content: content({ "3-a": "A3", "2-e": "A2" }),
  });
  assertEquals(p.state.decisions["2-e"], { state: "none", why: "echo" });
});

Deno.test("a revert descending from the base that loses is still copied", () => {
  const p = run({
    state: state({ synced: synced("2-a", "A2", ["1-r"]), recent: [{ rev: "1-r", hash: "R" }] }),
    local: file("A2"),
    leaves: [leaf("3-v", ["2-a", "1-r"]), leaf("3-w", ["2-a", "1-r"])],
    content: content({ "3-v": "R", "3-w": "W" }),
  });
  assertEquals(p.local, { kind: "write", rev: "3-w" });
  assertObjectMatch(p.state.decisions["3-v"], { state: "pending" });
});

Deno.test("the base leaf losing to a deeper sibling is copied like any loser once it stays losing", () => {
  const input = {
    state: state({ synced: synced("2-a", "A", ["1-r"]) }),
    local: file("A"),
    leaves: [leaf("2-a", ["1-r"]), leaf("6-o", ["5-o", "4-o", "3-o", "2-o", "1-r"])],
    content: content({ "2-a": "A", "6-o": "O" }),
  };
  const p = run(input);
  assertEquals(p.local, { kind: "write", rev: "6-o" });
  assertEquals(p.copies.length, 0);
  assertEquals(p.deferred.length, 0);
  assertObjectMatch(p.state.decisions["2-a"], { state: "pending", wasBase: true });
  const later = run({ ...input, state: p.state, local: file("O"), now: NOW + 31_000 });
  assertEquals(later.deferred.map((d) => d.rev), ["2-a"]);
});

Deno.test("generated losers, deletion losers and same-content losers get no copy", () => {
  const gen: RevContent = { hash: "G", generated: true, mtime: NOW };
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("A"),
    leaves: [
      leaf("2-w", ["1-a"]),
      leaf("2-g", ["1-a"]),
      leaf("2-d", ["1-a"], { softDeleted: true }),
      leaf("2-s", ["1-a"]),
      leaf("3-z", ["2-x", "1-a"]),
    ],
    content: content({ "2-w": "W", "2-g": gen, "2-s": "Z", "3-z": "Z" }),
  });
  assertEquals(p.local, { kind: "write", rev: "3-z" });
  assertEquals(p.state.decisions["2-g"], { state: "none", why: "generated" });
  assertEquals(p.state.decisions["2-d"], { state: "none", why: "deletion" });
  assertEquals(p.state.decisions["2-s"], { state: "none", why: "same" });
  assertObjectMatch(p.state.decisions["2-w"], { state: "pending" });
});

Deno.test("a hard-deleted leaf beside a live one is ignored", () => {
  const p = run({
    state: state({ synced: synced("2-a", "A", ["1-r"]) }),
    local: file("A"),
    leaves: [leaf("3-a", ["2-a", "1-r"], { hardDeleted: true }), leaf("2-o", ["1-r"])],
    content: content({ "2-o": "O" }),
  });
  assertEquals(p.local, { kind: "write", rev: "2-o" });
  assertEquals(p.copies, []);
  assertEquals(p.state.decisions, {});
});

Deno.test("a doc whose every leaf is hard-deleted is a deletion", () => {
  const p = run({
    state: state({ synced: synced("1-a", "A") }),
    local: file("A"),
    leaves: [leaf("2-a", ["1-a"], { hardDeleted: true })],
  });
  assertEquals(p.local, { kind: "delete" });
});

Deno.test("a stale rewrite made while paused is not pushed", () => {
  const p = run({
    state: state({
      synced: synced("3-c", "C", ["2-b", "1-a"]),
      recent: [{ rev: "2-b", hash: "B" }, { rev: "3-c", hash: "C" }],
    }),
    local: file("B", NOW, { duringPause: true }),
    leaves: [leaf("4-d", ["3-c", "2-b", "1-a"])],
    content: content({ "4-d": "D", "3-c": "C", "2-b": "B", "1-a": null }),
  });
  assertEquals(p.remote, undefined);
  assertEquals(p.local, { kind: "write", rev: "4-d" });
  assertEquals(p.copies, []);
});

Deno.test("an unreadable live leaf is reported rather than guessed at", () => {
  const res = reconcile({
    path: PATH,
    state: state({ synced: synced("1-a", "A") }),
    local: file("A"),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": null }),
    now: NOW,
  });
  assertEquals(res, { kind: "unreadable", rev: "2-b" });
});

Deno.test("each synced version is remembered, at most 100", () => {
  const recent = Array.from({ length: 100 }, (_, i) => ({ rev: `r${i}`, hash: `h${i}` }));
  const p = run({
    state: state({ synced: synced("1-a", "A"), recent }),
    local: file("A"),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "B" }),
  });
  assertEquals(p.state.recent.length, 100);
  assertEquals(p.state.recent.at(-1), { rev: "2-b", hash: "B" });
});

Deno.test("an edit this machine pushed that loses is copied at once, before the winner overwrites it", () => {
  const p = run({
    state: state({ synced: { ...synced("2-a", "A", ["1-r"]), pushed: true } }),
    local: file("A"),
    leaves: [leaf("2-a", ["1-r"]), leaf("6-o", ["5-o", "4-o", "3-o", "2-o", "1-r"])],
    content: content({ "2-a": "A", "6-o": "O" }),
  });
  assertEquals(p.local, { kind: "write", rev: "6-o" });
  assertEquals(p.copies.length, 1);
  assertObjectMatch(p.copies[0], { source: { kind: "local" }, keep: true, rev: "2-a" });
});

Deno.test("with no base, losers of an existing conflict are kept in recovered even when the disk matches the winner", () => {
  const p = run({
    local: file("W"),
    leaves: [leaf("3-w", ["2-w", "1-r"]), leaf("2-l", ["1-r"])],
    content: content({ "3-w": "W", "2-l": "L" }),
  });
  assertObjectMatch(p.state.decisions["2-l"], { state: "pending", dest: { where: "recovered" } });
});

Deno.test("an old winner already copied on an earlier pass is not copied again", () => {
  const dest = { where: "vault" as const, path: "wiki/projects/a/note.conflict-x.md" };
  const p = run({
    state: state({ synced: synced("1-a", "A"), decisions: { "2-b": { state: "copied", dest } } }),
    local: file("L", NOW - 1000),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": "B" }),
  });
  assertObjectMatch(p, { remote: { kind: "put", parentRev: "2-b" } });
  assertEquals(p.copies.length, 0);
});

Deno.test("an old winner known only by hash whose body cannot be decoded is reported, not dereferenced", () => {
  const res = reconcile({
    path: PATH,
    state: state({ synced: synced("1-a", "A"), recent: [{ rev: "2-b", hash: "B" }] }),
    local: file("L", NOW - 1000),
    leaves: [leaf("2-b", ["1-a"])],
    content: content({ "2-b": null }),
    now: NOW,
  });
  assertEquals(res, { kind: "unreadable", rev: "2-b" });
});
