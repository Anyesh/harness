import { assert, assertEquals, assertNotEquals, assertRejects, assertThrows } from "@std/assert";
import { encryptWithEphemeralSalt } from "octagonal-wheels/encryption/hkdf";
import { encrypt } from "octagonal-wheels/encryption/encryption";
import {
  applyPreferred,
  checkFingerprint,
  fingerprint,
  manipulatorOptions,
  netHost,
  PLUGIN_DEFAULT_KEY,
  readPluginSettings,
  SettingsError,
} from "./settings.ts";

const CONN = {
  couchDB_URI: "https://sync.example.org",
  couchDB_USER: "u",
  couchDB_PASSWORD: "p",
  couchDB_DBNAME: "obsidian",
  useJWT: false,
  couchDB_CustomHeaders: "",
};

async function fixture(
  extra: Record<string, unknown> = {},
  conn: Record<string, unknown> = CONN,
): Promise<string> {
  const data = {
    remoteType: "",
    configPassphraseStore: "",
    encrypt: true,
    E2EEAlgorithm: "v2",
    usePathObfuscation: false,
    handleFilenameCaseSensitive: false,
    customChunkSize: 50,
    chunkSplitterVersion: "v3-rabin-karp",
    hashAlg: "xxhash64",
    minimumChunkSize: 20,
    passphrase: "",
    couchDB_PASSWORD: "",
    encryptedCouchDBConnection: await encryptWithEphemeralSalt(JSON.stringify(conn), PLUGIN_DEFAULT_KEY),
    encryptedPassphrase: await encryptWithEphemeralSalt("secret", PLUGIN_DEFAULT_KEY),
    ...extra,
  };
  const path = `${await Deno.makeTempDir()}/data.json`;
  await Deno.writeTextFile(path, JSON.stringify(data));
  return path;
}

Deno.test("decrypts the connection and passphrase with the plugin's default key", async () => {
  const s = await readPluginSettings(await fixture());
  assertEquals(s.connection, {
    url: "https://sync.example.org",
    database: "obsidian",
    username: "u",
    password: "p",
  });
  assertEquals(s.passphrase, "secret");
  assertEquals(s.obfuscatePassphrase, "");
  const o = manipulatorOptions(s);
  assertEquals(o.customChunkSize, 50);
  assertEquals(o.chunkSplitterVersion, "v3-rabin-karp");
  assertEquals(o.handleFilenameCaseSensitive, false);
  assertEquals(o.E2EEAlgorithm, "v2");
  assertEquals(o.url, "https://sync.example.org");
});

Deno.test("decrypts the older prefixed forms too", async () => {
  const older = await encrypt(JSON.stringify(CONN), PLUGIN_DEFAULT_KEY, false);
  const s = await readPluginSettings(await fixture({ encryptedCouchDBConnection: older }));
  assertEquals(s.connection.username, "u");
});

Deno.test("takes the obfuscation passphrase only when the plugin obfuscates paths", async () => {
  const s = await readPluginSettings(await fixture({ usePathObfuscation: true }));
  assertEquals(s.obfuscatePassphrase, "secret");
});

Deno.test("refuses unsupported configurations by name", async () => {
  const cases: [Record<string, unknown>, string][] = [
    [{ configPassphraseStore: "LOCALSTORAGE" }, "configPassphraseStore"],
    [{ remoteType: "MINIO" }, "remoteType"],
    [{ encryptedCouchDBConnection: "" }, "encryptedCouchDBConnection"],
    [{ encryptedCouchDBConnection: "zz-unknown" }, "encryptedCouchDBConnection"],
    [{ encryptedPassphrase: "%$garbage" }, "encryptedPassphrase"],
  ];
  for (const [extra, name] of cases) {
    const err = await assertRejects(async () => readPluginSettings(await fixture(extra)), SettingsError);
    assert(err.message.includes(name), `${err.message} should name ${name}`);
  }
  const jwt = await assertRejects(
    async () => readPluginSettings(await fixture({}, { ...CONN, useJWT: true })),
    SettingsError,
  );
  assert(jwt.message.includes("useJWT"));
});

Deno.test("PREFERRED tweak values override data.json, and a mismatch on identity keys refuses", async () => {
  const s = await readPluginSettings(await fixture());
  const merged = applyPreferred(s, {
    tweak_values: { PREFERRED: { customChunkSize: 60, hashAlg: "xxhash64" } },
  });
  assertEquals(manipulatorOptions(merged).customChunkSize, 60);
  assertEquals(manipulatorOptions(applyPreferred(s, {})).customChunkSize, 50);
  const conflicting: Record<string, unknown> = {
    handleFilenameCaseSensitive: true,
    E2EEAlgorithm: "v1",
    encrypt: false,
  };
  for (const [k, v] of Object.entries(conflicting)) {
    const bad = { tweak_values: { PREFERRED: { [k]: v } } };
    const err = assertThrows(() => applyPreferred(s, bad), SettingsError);
    assert(err.message.includes(k));
  }
});

Deno.test("fingerprint reuses a stored salt and detects a rotated password", async () => {
  const s = await readPluginSettings(await fixture());
  const fp = await fingerprint(s);
  assertEquals(fp.host, "sync.example.org");
  assertEquals((await fingerprint(s, fp.salt)).hash, fp.hash);
  assertNotEquals((await fingerprint(s)).salt, fp.salt);
  assert(await checkFingerprint(s, fp));
  const rotated = await readPluginSettings(await fixture({}, { ...CONN, couchDB_PASSWORD: "q" }));
  assert(!(await checkFingerprint(rotated, fp)));
});

Deno.test("netHost keeps an explicit port", () => {
  assertEquals(netHost("https://sync.example.org"), "sync.example.org");
  assertEquals(netHost("http://127.0.0.1:5985/"), "127.0.0.1:5985");
});
