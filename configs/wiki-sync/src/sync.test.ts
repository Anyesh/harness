import { assert, assertEquals } from "@std/assert";
import { BaseStore, JsonFile } from "./base.ts";
import { LocalStore } from "./local.ts";
import { MemoryRemote } from "./memory_remote.ts";
import { Blocked, type BlockReason, type PauseWindow, Syncer } from "./sync.ts";

const CONFIG = {
  quietMs: 30,
  retryMs: 200,
  guardMs: 80,
  scanMs: 60_000,
  checkpointMs: 40,
  feedRestartMs: 50,
  pollMs: 40,
};

interface Rig {
  root: string;
  state: string;
  remote: MemoryRemote;
  gate: { blocked: BlockReason | null; check(): Promise<void> };
  syncer: Syncer;
  bases: BaseStore;
  start(): Promise<void>;
  restart(): Promise<void>;
  stop(): Promise<void>;
}

async function rig(remote = new MemoryRemote(), dirs?: { root: string; state: string }): Promise<Rig> {
  const root = dirs?.root ?? await Deno.makeTempDir();
  const state = dirs?.state ?? await Deno.makeTempDir();
  await Deno.mkdir(`${root}/wiki`, { recursive: true });
  remote.longpollMs = 30;
  const gate = {
    blocked: null as BlockReason | null,
    check() {
      return this.blocked ? Promise.reject(new Blocked(this.blocked)) : Promise.resolve();
    },
  };
  const make = async () => {
    const bases = await BaseStore.open(`${state}/base`);
    const syncer = new Syncer({
      remote,
      local: new LocalStore(root, "wiki/"),
      bases,
      checkpoint: new JsonFile<{ since: string }>(`${state}/checkpoint.json`),
      pauses: new JsonFile<PauseWindow[]>(`${state}/pauses.json`),
      gate,
      identity: () => Promise.resolve(true),
      recoveredDir: `${state}/recovered`,
      releaseMarker: `${state}/release-deletions`,
      config: CONFIG,
    });
    return { bases, syncer };
  };
  const r: Rig = {
    root,
    state,
    remote,
    gate,
    ...(await make()),
    start: () => r.syncer.start(),
    async restart() {
      await r.syncer.stop();
      Object.assign(r, await make());
      await r.syncer.start();
    },
    stop: () => r.syncer.stop(),
  };
  return r;
}

async function until(cond: () => boolean | Promise<boolean>, ms = 4000): Promise<void> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await cond()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error("condition not met in time");
}

const read = (r: Rig, p: string) => Deno.readTextFile(`${r.root}/${p}`).catch(() => null);
const write = (r: Rig, p: string, t: string) =>
  Deno.mkdir(`${r.root}/${p}`.replace(/\/[^/]+$/, ""), { recursive: true }).then(() =>
    Deno.writeTextFile(`${r.root}/${p}`, t)
  );
const files = (r: Rig, dir = "wiki") => [...Deno.readDirSync(`${r.root}/${dir}`)].map((e) => e.name).sort();

Deno.test("pushes new files, applies remote edits and pushes nothing for unchanged files after a restart", async () => {
  const r = await rig();
  await write(r, "wiki/a.md", "local a");
  await r.remote.edit("wiki/b.md", "remote b");
  await r.start();
  try {
    await until(async () =>
      (await r.remote.text("wiki/a.md")) === "local a" && (await read(r, "wiki/b.md")) === "remote b"
    );
    await r.remote.edit("wiki/b.md", "remote b2");
    await until(async () => (await read(r, "wiki/b.md")) === "remote b2");
    await r.syncer.idle();
    const writes = r.remote.writes;
    await r.restart();
    await new Promise((res) => setTimeout(res, 200));
    await r.syncer.idle();
    assertEquals(r.remote.writes, writes);
  } finally {
    await r.stop();
  }
});

Deno.test("overlapping triggers for one path produce one push", async () => {
  const r = await rig();
  await r.start();
  try {
    await write(r, "wiki/x.md", "x");
    const id = "wiki/x.md";
    await Promise.all([
      r.syncer.enqueue(id, { path: id }),
      r.syncer.enqueue(id, { path: id }),
      r.syncer.scan(),
      r.syncer.enqueue(id, { path: id }),
    ]);
    await r.syncer.idle();
    assertEquals(r.remote.writes, 1);
    assertEquals(await r.remote.leafCount("wiki/x.md"), 1);
  } finally {
    await r.stop();
  }
});

Deno.test("writes made while the remote is down arrive after it returns, without a restart", async () => {
  const r = await rig();
  await r.start();
  try {
    r.remote.offline = true;
    await write(r, "wiki/off.md", "offline edit");
    await until(() => r.syncer.health().failedCount === 1);
    assertEquals(r.syncer.health().failing[0].path, "wiki/off.md");
    r.remote.offline = false;
    await until(async () => (await r.remote.text("wiki/off.md")) === "offline edit");
    await until(() => r.syncer.health().failedCount === 0);
  } finally {
    await r.stop();
  }
});

Deno.test("a change that fails while a later one succeeds is delivered again after a restart", async () => {
  const r = await rig();
  await r.remote.edit("wiki/first.md", "first");
  await r.remote.edit("wiki/second.md", "second");
  r.remote.failReadsFor.add("wiki/first.md");
  await r.start();
  try {
    await until(async () => (await read(r, "wiki/second.md")) === "second");
    await new Promise((res) => setTimeout(res, 100));
    await r.syncer.saveCheckpoint();
    assertEquals(await read(r, "wiki/first.md"), null);
    r.remote.failReadsFor.clear();
    await r.syncer.stop();
    const again = await rig(r.remote, { root: r.root, state: r.state });
    await again.start();
    try {
      await until(async () => (await read(r, "wiki/first.md")) === "first");
    } finally {
      await again.stop();
    }
  } finally {
    await r.stop();
  }
});

Deno.test("the checkpoint advances past changes once they are handled", async () => {
  const r = await rig();
  await r.remote.edit("wiki/c.md", "c");
  await r.start();
  try {
    await until(async () => (await read(r, "wiki/c.md")) === "c");
    await until(async () =>
      (await new JsonFile<{ since: string }>(`${r.state}/checkpoint.json`).read({ since: "" })).since !== ""
    );
    assert(r.syncer.health().caughtUp);
  } finally {
    await r.stop();
  }
});

Deno.test("a quiet live feed keeps feedTs fresh", async () => {
  const r = await rig();
  await r.start();
  try {
    await new Promise((res) => setTimeout(res, 300));
    const h = r.syncer.health();
    assert(Date.now() - h.feedTs < 150, `feedTs is ${Date.now() - h.feedTs} ms old`);
  } finally {
    await r.stop();
  }
});

Deno.test("a bulk local deletion is held until released; a small one is pushed", async () => {
  const r = await rig();
  for (let i = 0; i < 30; i++) await write(r, `wiki/n${i}.md`, `note ${i}`);
  await r.start();
  try {
    await until(async () => (await r.remote.text("wiki/n29.md")) === "note 29");
    await r.syncer.idle();
    for (let i = 0; i < 2; i++) await Deno.remove(`${r.root}/wiki/n${i}.md`);
    await until(async () => (await r.remote.text("wiki/n1.md")) === null);
    for (let i = 2; i < 25; i++) await Deno.remove(`${r.root}/wiki/n${i}.md`);
    await until(() => r.syncer.health().heldDeletions === 23);
    assertEquals(await r.remote.text("wiki/n10.md"), "note 10");
    await Deno.writeTextFile(`${r.state}/release-deletions`, "");
    await until(async () => (await r.remote.text("wiki/n24.md")) === null);
    await until(() => r.syncer.health().heldDeletions === 0);
    await until(async () => !(await Deno.stat(`${r.state}/release-deletions`).then(() => true, () => false)));
  } finally {
    await r.stop();
  }
});

Deno.test("concurrent edits keep the newer on disk and the other as one conflict copy", async () => {
  const r = await rig();
  await write(r, "wiki/c.md", "base");
  await r.start();
  await until(async () => (await r.remote.text("wiki/c.md")) === "base");
  await r.syncer.idle();
  await r.syncer.stop();
  await write(r, "wiki/c.md", "local edit");
  await Deno.utime(`${r.root}/wiki/c.md`, new Date(), new Date(Date.now() - 3_600_000));
  await r.remote.edit("wiki/c.md", "remote edit", Date.now() + 10_000);
  const again = await rig(r.remote, { root: r.root, state: r.state });
  await again.start();
  try {
    await until(async () => (await read(r, "wiki/c.md")) === "remote edit");
    await until(() => files(r).some((f) => f.startsWith("c.conflict-")));
    const copy = files(r).find((f) => f.startsWith("c.conflict-"))!;
    assertEquals(await read(r, `wiki/${copy}`), "local edit");
    await until(async () => (await r.remote.text(`wiki/${copy}`)) === "local edit");
    assertEquals(files(r).filter((f) => f.includes("conflict")).length, 1);
  } finally {
    await again.stop();
  }
});

Deno.test("while paused nothing is written; afterwards local edits push and stale rewrites do not", async () => {
  const r = await rig();
  await write(r, "wiki/p.md", "v1");
  await write(r, "wiki/q.md", "q1");
  await r.start();
  try {
    await until(async () =>
      (await r.remote.text("wiki/q.md")) === "q1" && (await r.remote.text("wiki/p.md")) === "v1"
    );
    await r.syncer.idle();
    await write(r, "wiki/p.md", "v2");
    await until(async () => (await r.remote.text("wiki/p.md")) === "v2");
    await r.syncer.idle();
    await r.syncer.pause();
    const writes = r.remote.writes;
    await r.remote.edit("wiki/p.md", "v3 from obsidian");
    await write(r, "wiki/p.md", "v1");
    await write(r, "wiki/q.md", "agent edit while paused");
    await new Promise((res) => setTimeout(res, 200));
    assertEquals(r.remote.writes, writes + 1);
    await r.syncer.resume();
    await until(async () => (await r.remote.text("wiki/q.md")) === "agent edit while paused");
    await until(async () => (await read(r, "wiki/p.md")) === "v3 from obsidian");
    assertEquals(await r.remote.text("wiki/p.md"), "v3 from obsidian");
    assertEquals(files(r).filter((f) => f.includes("conflict")), []);
  } finally {
    await r.stop();
  }
});

Deno.test("a case collision is held and neither file is overwritten", async () => {
  const r = await rig();
  await write(r, "wiki/foo.md", "lower");
  await r.start();
  try {
    await until(async () => (await r.remote.text("wiki/foo.md")) === "lower");
    await r.syncer.idle();
    await write(r, "wiki/Foo.md", "upper");
    await until(() => r.syncer.health().collisions === 1);
    assertEquals(await read(r, "wiki/foo.md"), "lower");
    assertEquals(await read(r, "wiki/Foo.md"), "upper");
    assertEquals(await r.remote.text("wiki/foo.md"), "lower");
  } finally {
    await r.stop();
  }
});

Deno.test("a moved-away wiki root pushes no deletions and resumes when it returns", async () => {
  const r = await rig();
  await write(r, "wiki/k.md", "keep");
  await r.start();
  try {
    await until(async () => (await r.remote.text("wiki/k.md")) === "keep");
    await r.syncer.idle();
    await Deno.rename(`${r.root}/wiki`, `${r.root}/wiki.old`);
    await until(() => r.syncer.health().root === "missing");
    await r.remote.edit("wiki/k.md", "edited elsewhere");
    await new Promise((res) => setTimeout(res, 300));
    assertEquals(await r.remote.text("wiki/k.md"), "edited elsewhere");
    assertEquals(await Deno.stat(`${r.root}/wiki`).then(() => true, () => false), false);
    await Deno.rename(`${r.root}/wiki.old`, `${r.root}/wiki`);
    await until(async () => (await read(r, "wiki/k.md")) === "edited elsewhere");
    await until(() => r.syncer.health().root === "ok");
  } finally {
    await r.stop();
  }
});

Deno.test("a blocked gate parks handlers without counting failures", async () => {
  const r = await rig();
  await r.start();
  try {
    r.gate.blocked = "locked";
    await write(r, "wiki/g.md", "g");
    await new Promise((res) => setTimeout(res, 200));
    assertEquals(await r.remote.text("wiki/g.md"), null);
    assertEquals(r.syncer.health().failedCount, 0);
    r.gate.blocked = null;
    await r.syncer.restartFromCheckpoint();
    await until(async () => (await r.remote.text("wiki/g.md")) === "g");
  } finally {
    await r.stop();
  }
});
