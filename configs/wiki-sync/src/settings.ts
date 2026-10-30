import { decryptString } from "@vrtmrz/livesync-commonlib/compat/encryption/stringEncryption";

export const PLUGIN_DEFAULT_KEY = "*" + "rHGMPtr6oWw7VSa3W3wpa8fT8U";
const FINGERPRINT_ITERATIONS = 600_000;

const OPTION_KEYS = [
  "minimumChunkSize",
  "idDerivationVersion",
  "idDerivationKey",
  "customChunkSize",
  "hashAlg",
  "useEden",
  "maxChunksInEden",
  "maxTotalLengthInEden",
  "maxAgeInEden",
  "enableChunkSplitterV2",
  "chunkSplitterVersion",
  "doNotUseFixedRevisionForChunks",
  "enableCompression",
  "handleFilenameCaseSensitive",
  "encryptInternalMetadata",
  "E2EEAlgorithm",
  "useDynamicIterationCount",
] as const;

const IDENTITY_KEYS = ["handleFilenameCaseSensitive", "E2EEAlgorithm", "encrypt"] as const;

export class SettingsError extends Error {}

export interface Connection {
  url: string;
  database: string;
  username: string;
  password: string;
}

export interface Settings {
  connection: Connection;
  passphrase: string;
  obfuscatePassphrase: string;
  encrypt: boolean;
  options: Record<string, unknown>;
}

export interface Fingerprint {
  host: string;
  salt: string;
  hash: string;
}

async function decryptField(data: Record<string, unknown>, field: string): Promise<string> {
  const value = data[field];
  if (typeof value !== "string" || value === "") {
    throw new SettingsError(`${field} is missing from the plugin's data.json`);
  }
  try {
    return await decryptString(value, PLUGIN_DEFAULT_KEY);
  } catch (e) {
    throw new SettingsError(`${field} could not be decrypted: ${e instanceof Error ? e.message : e}`);
  }
}

export async function readPluginSettings(dataJsonPath: string): Promise<Settings> {
  const data = JSON.parse(await Deno.readTextFile(dataJsonPath)) as Record<string, unknown>;
  if ((data.configPassphraseStore ?? "") !== "") {
    throw new SettingsError(
      `configPassphraseStore is "${data.configPassphraseStore}"; only the default store can be read headless`,
    );
  }
  if ((data.remoteType ?? "") !== "") {
    throw new SettingsError(`remoteType is "${data.remoteType}"; only CouchDB is supported`);
  }
  let conn: Record<string, unknown>;
  try {
    conn = JSON.parse(await decryptField(data, "encryptedCouchDBConnection"));
  } catch (e) {
    if (e instanceof SettingsError) throw e;
    throw new SettingsError("encryptedCouchDBConnection did not decrypt to JSON");
  }
  if (conn.useJWT) throw new SettingsError("useJWT is on; JWT authentication is not supported");
  if (typeof conn.couchDB_CustomHeaders === "string" && conn.couchDB_CustomHeaders.trim() !== "") {
    throw new SettingsError("couchDB_CustomHeaders is set; custom headers are not supported");
  }
  for (const k of ["couchDB_URI", "couchDB_DBNAME", "couchDB_USER", "couchDB_PASSWORD"]) {
    if (typeof conn[k] !== "string" || conn[k] === "") {
      throw new SettingsError(`encryptedCouchDBConnection has no ${k}`);
    }
  }
  const encrypt = data.encrypt === true;
  const passphrase = encrypt ? await decryptField(data, "encryptedPassphrase") : "";
  const options: Record<string, unknown> = {};
  for (const k of OPTION_KEYS) {
    if (k in data) options[k] = data[k];
  }
  return {
    connection: {
      url: String(conn.couchDB_URI).replace(/\/+$/, ""),
      database: String(conn.couchDB_DBNAME),
      username: String(conn.couchDB_USER),
      password: String(conn.couchDB_PASSWORD),
    },
    passphrase,
    obfuscatePassphrase: data.usePathObfuscation === true ? passphrase : "",
    encrypt,
    options,
  };
}

export function applyPreferred(s: Settings, milestone: unknown): Settings {
  const preferred = (milestone as { tweak_values?: Record<string, Record<string, unknown>> } | null)
    ?.tweak_values?.PREFERRED;
  if (!preferred) return s;
  const current: Record<string, unknown> = { ...s.options, encrypt: s.encrypt };
  for (const k of IDENTITY_KEYS) {
    if (k in preferred && k in current && preferred[k] !== current[k]) {
      throw new SettingsError(
        `the database's preferred ${k} (${preferred[k]}) differs from this device's (${
          current[k]
        }); fix the plugin settings first`,
      );
    }
  }
  const options = { ...s.options };
  for (const k of OPTION_KEYS) {
    if (k in preferred) options[k] = preferred[k];
  }
  return { ...s, options };
}

export function manipulatorOptions(s: Settings): Record<string, unknown> {
  return {
    ...s.options,
    url: s.connection.url,
    database: s.connection.database,
    username: s.connection.username,
    password: s.connection.password,
    passphrase: s.passphrase,
    obfuscatePassphrase: s.obfuscatePassphrase,
  };
}

export function netHost(url: string): string {
  const u = new URL(url);
  return u.port ? `${u.hostname}:${u.port}` : u.hostname;
}

function b64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

function unb64(s: string): Uint8Array {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

export async function fingerprint(s: Settings, salt?: string): Promise<Fingerprint> {
  const saltBytes = salt ? unb64(salt) : crypto.getRandomValues(new Uint8Array(16));
  const secret = JSON.stringify([
    s.connection.url,
    s.connection.database,
    s.connection.username,
    s.connection.password,
    s.passphrase,
  ]);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), "PBKDF2", false, [
    "deriveBits",
  ]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: saltBytes as BufferSource, iterations: FINGERPRINT_ITERATIONS },
    key,
    256,
  );
  const hash = Array.from(new Uint8Array(bits), (b) => b.toString(16).padStart(2, "0")).join("");
  return { host: netHost(s.connection.url), salt: b64(saltBytes), hash };
}

export async function checkFingerprint(s: Settings, seen: Fingerprint): Promise<boolean> {
  const now = await fingerprint(s, seen.salt);
  return now.hash === seen.hash && now.host === seen.host;
}
