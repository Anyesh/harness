import { assertEquals, assertMatch } from "@std/assert";
import { formatLine } from "./log.ts";

Deno.test("formatLine without a time is level then message", () => {
  assertEquals(formatLine("warn", "feed stalled", null), "WARN feed stalled");
});

Deno.test("formatLine with a time prefixes the local date and time", () => {
  const at = new Date(2026, 10, 4, 7, 5, 9);
  assertEquals(formatLine("info", "syncing", at), "2026-11-04 07:05:09 INFO syncing");
  assertMatch(formatLine("error", "x", new Date()), /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ERROR x$/);
});
