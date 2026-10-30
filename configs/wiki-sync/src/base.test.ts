import { assert, assertEquals } from "@std/assert";
import { BaseStore, JsonFile, type PathRecord } from "./base.ts";
import { emptyState } from "./reconcile.ts";

function record(id: string, path: string, extra: Partial<PathRecord> = {}): PathRecord {
  return { ...emptyState(), id, path, ...extra };
}

Deno.test("records survive a reopen and are keyed by id, not path", async () => {
  const dir = await Deno.makeTempDir();
  const a = await BaseStore.open(dir);
  await a.put(
    record("wiki/foo.md", "wiki/Foo.md", { synced: { rev: "1-a", ancestry: ["1-a"], hash: "h", mtime: 5 } }),
  );
  const b = await BaseStore.open(dir);
  assertEquals(b.get("wiki/foo.md")?.path, "wiki/Foo.md");
  assertEquals(b.get("wiki/foo.md")?.synced?.rev, "1-a");
  assertEquals(b.get("wiki/Foo.md"), undefined);
});

Deno.test("files are named by the id's sha256 and no temp files are left", async () => {
  const dir = await Deno.makeTempDir();
  const s = await BaseStore.open(dir);
  await s.put(record("wiki/a.md", "wiki/a.md"));
  await s.put(record("wiki/a.md", "wiki/a.md", { recheckAt: 9 }));
  const names = [...Deno.readDirSync(dir)].map((e) => e.name);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("wiki/a.md")));
  const hex = [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
  assertEquals(names, [`${hex}.json`]);
});

Deno.test("delete removes the record from memory and disk", async () => {
  const dir = await Deno.makeTempDir();
  const s = await BaseStore.open(dir);
  await s.put(record("wiki/a.md", "wiki/a.md"));
  await s.delete("wiki/a.md");
  assertEquals(s.get("wiki/a.md"), undefined);
  assertEquals([...Deno.readDirSync(dir)].length, 0);
  assertEquals((await BaseStore.open(dir)).get("wiki/a.md"), undefined);
});

Deno.test("held records and records with content are listed", async () => {
  const dir = await Deno.makeTempDir();
  const s = await BaseStore.open(dir);
  await s.put(record("a", "a", { held: "collision" }));
  await s.put(record("b", "b", { synced: { rev: "1-x", ancestry: ["1-x"], hash: "h", mtime: 1 } }));
  await s.put(record("c", "c", { synced: { rev: "2-x", ancestry: ["2-x"], hash: null, mtime: 1 } }));
  assertEquals(s.held().map((r) => r.id), ["a"]);
  assertEquals(s.withContent(), 1);
  assertEquals(s.all().length, 3);
});

Deno.test("a corrupt record file is skipped with a warning, not fatal", async () => {
  const dir = await Deno.makeTempDir();
  await Deno.writeTextFile(`${dir}/bad.json`, "{not json");
  const s = await BaseStore.open(dir);
  assertEquals(s.all().length, 0);
});

Deno.test("JsonFile writes atomically and reads back, missing gives the default", async () => {
  const dir = await Deno.makeTempDir();
  const f = new JsonFile<{ since: string }>(`${dir}/checkpoint.json`);
  assertEquals(await f.read({ since: "" }), { since: "" });
  await f.write({ since: "12-abc" });
  assertEquals(await f.read({ since: "" }), { since: "12-abc" });
  assert(![...Deno.readDirSync(dir)].some((e) => e.name.includes(".tmp")));
});
