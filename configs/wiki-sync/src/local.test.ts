import { assert, assertEquals, assertRejects } from "@std/assert";
import { isGenerated, isIgnoredPath, LocalStore, RootMissing } from "./local.ts";

const enc = (s: string) => new TextEncoder().encode(s);

async function vault(): Promise<{ root: string; store: LocalStore }> {
  const root = await Deno.makeTempDir();
  await Deno.mkdir(`${root}/wiki`);
  return { root, store: new LocalStore(root, "wiki/") };
}

Deno.test("write is atomic, sets the doc mtime and leaves no temp file", async () => {
  const { root, store } = await vault();
  const mtime = Date.UTC(2026, 0, 2, 3, 4, 5);
  const stat = await store.write("wiki/a/b/note.md", enc("hello"), mtime);
  assertEquals(await Deno.readTextFile(`${root}/wiki/a/b/note.md`), "hello");
  assertEquals(stat.mtime, mtime);
  assertEquals([...Deno.readDirSync(`${root}/wiki/a/b`)].map((e) => e.name), ["note.md"]);
});

Deno.test("read hashes the file and reuses the hash when the stat matches", async () => {
  const { store } = await vault();
  await store.write("wiki/n.md", enc("one"), 1_000_000);
  const first = await store.read("wiki/n.md");
  assert(first.kind === "file");
  assertEquals(new TextDecoder().decode(await first.bytes()), "one");
  const reused = await store.read("wiki/n.md", { ...first.stat, hash: "cached", generated: false });
  assert(reused.kind === "file");
  assertEquals(reused.hash, "cached");
  assertEquals((await store.read("wiki/missing.md")).kind, "absent");
});

Deno.test("existence uses exact names, and case variants are listed", async () => {
  const { root, store } = await vault();
  await Deno.writeTextFile(`${root}/wiki/foo.md`, "a");
  await Deno.writeTextFile(`${root}/wiki/Foo.md`, "b");
  assertEquals((await store.caseVariants("wiki/FOO.md")).sort(), ["wiki/Foo.md", "wiki/foo.md"]);
  assertEquals(await store.exists("wiki/FOO.md"), false);
  assertEquals(await store.exists("wiki/Foo.md"), true);
});

Deno.test("walk skips dotfiles, dot-dirs and temp files", async () => {
  const { root, store } = await vault();
  await Deno.mkdir(`${root}/wiki/.obsidian`);
  await Deno.mkdir(`${root}/wiki/p`);
  for (const f of ["p/a.md", ".DS_Store", ".obsidian/x.json", "p/b.md.tmp.123.ab", "p/.hidden.md"]) {
    await Deno.writeTextFile(`${root}/wiki/${f}`, "x");
  }
  const seen: string[] = [];
  for await (const e of store.walk()) seen.push(e.path);
  assertEquals(seen, ["wiki/p/a.md"]);
});

Deno.test("isIgnoredPath covers dot segments and temp names", () => {
  assert(isIgnoredPath("wiki/.trash/a.md"));
  assert(isIgnoredPath("wiki/a.md.tmp.4.x"));
  assert(!isIgnoredPath("wiki/a.conflict-20260101T000000-abcdef01.md"));
});

Deno.test("isGenerated reads only the file's own front matter", () => {
  assert(isGenerated(enc("---\ntype: index\ngenerated: true\n---\n# x\n")));
  assert(!isGenerated(enc("# x\n---\ngenerated: true\n---\n")));
  assert(!isGenerated(enc("---\ntype: index\n---\ngenerated: true\n")));
});

Deno.test("writes and deletes refuse while the wiki root is missing", async () => {
  const { root, store } = await vault();
  await Deno.remove(`${root}/wiki`);
  await assertRejects(() => store.write("wiki/a.md", enc("x"), 1), RootMissing);
  await assertRejects(() => store.remove("wiki/a.md"), RootMissing);
  assertEquals(await store.rootInode(), null);
  assertEquals((await Deno.stat(root)).isDirectory, true);
  assertEquals([...Deno.readDirSync(root)], []);
});

Deno.test("the watcher reports files written into new folders", async () => {
  const { root, store } = await vault();
  const seen = new Set<string>();
  const w = await store.watch((p) => seen.add(p));
  try {
    for (let i = 0; i < 20; i++) {
      await Deno.mkdir(`${root}/wiki/d${i}`);
      await Deno.writeTextFile(`${root}/wiki/d${i}/n.md`, "x");
    }
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && [...seen].filter((p) => p.endsWith("/n.md")).length < 20) {
      await new Promise((r) => setTimeout(r, 100));
    }
    assertEquals([...seen].filter((p) => p.endsWith("/n.md")).length, 20);
  } finally {
    await w.close();
  }
});
