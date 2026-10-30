import { assert, assertEquals } from "@std/assert";
import { obsidianRunning, vaultMarkedOpen } from "./obsidian.ts";

const LINUX_PS = "(udev-worker)\nchrome\nzsh\nobsidian\nobsidian\nnode-MainThread\n";
const MAC_PS = "launchd         \nlogd            \nObsidian        \nObsidian Helper \n";

Deno.test("ps parsing matches the exact Obsidian process name per line", () => {
  assert(obsidianRunning(LINUX_PS));
  assert(obsidianRunning(MAC_PS));
  assert(!obsidianRunning("launchd         \nObsidian Helper \nobsidian-cli\n"));
  assert(!obsidianRunning("chrome\nzsh\n"));
});

Deno.test("the vault counts as open when its key is marked open", () => {
  const json = JSON.stringify({ vaults: { k1: { path: "/v", open: true }, k2: { path: "/w" } } });
  assertEquals(vaultMarkedOpen([json], ["k1"]), true);
  assertEquals(vaultMarkedOpen([json], ["k2"]), false);
});

Deno.test("an unmatched key or unreadable config counts as open", () => {
  const json = JSON.stringify({ vaults: { k1: { path: "/v", open: true } } });
  assertEquals(vaultMarkedOpen([json], []), true);
  assertEquals(vaultMarkedOpen([null, null], ["k1"]), true);
  assertEquals(vaultMarkedOpen(["{broken"], ["k1"]), true);
});
