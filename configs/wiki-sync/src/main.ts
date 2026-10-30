import { BaseStore, JsonFile } from "./base.ts";
import { classifyError, Couch, CouchRemote, type RemoteIdentity, type RemoteState } from "./couch.ts";
import { LocalStore } from "./local.ts";
import { errText, log } from "./log.ts";
import { ObsidianWatch } from "./obsidian.ts";
import {
  applyPreferred,
  checkFingerprint,
  type Fingerprint,
  fingerprint,
  manipulatorOptions,
  readPluginSettings,
  type Settings,
  SettingsError,
} from "./settings.ts";
import { Blocked, type PauseWindow, Syncer } from "./sync.ts";

interface StoredIdentity {
  endpoint: string;
  database: string;
  prefix: string;
  created: number | null;
  salt: string;
  instance?: string | null;
}

interface Env {
  state: string;
  vault: string;
  wikiDir: string;
  prefix: string;
  obsidianJson: string[];
  obsidianKeys: string[];
}

const HEALTH_MS = 10_000;
const IDENTITY_MS = 60_000;
const OBSIDIAN_POLL_MS = 1_000;

function readEnv(): Env {
  const get = (k: string) => {
    const v = Deno.env.get(k);
    if (!v) throw new Error(`${k} is not set`);
    return v;
  };
  const list = (k: string) => (Deno.env.get(k) ?? "").split("\n").map((s) => s.trim()).filter(Boolean);
  const vault = get("WIKI_SYNC_VAULT").replace(/\/+$/, "");
  const wikiDir = get("WIKI_SYNC_DIR").replace(/\/+$/, "");
  if (!wikiDir.startsWith(`${vault}/`)) throw new Error(`WIKI_SYNC_DIR ${wikiDir} is not inside ${vault}`);
  return {
    state: get("WIKI_SYNC_STATE").replace(/\/+$/, ""),
    vault,
    wikiDir,
    prefix: `${wikiDir.slice(vault.length + 1)}/`,
    obsidianJson: list("WIKI_SYNC_OBSIDIAN_JSON"),
    obsidianKeys: list("WIKI_SYNC_OBSIDIAN_KEYS"),
  };
}

function dataJsonPath(env: Env): string {
  return `${env.vault}/.obsidian/plugins/obsidian-livesync/data.json`;
}

async function fingerprintMode(env: Env, check: boolean): Promise<number> {
  const settings = await readPluginSettings(dataJsonPath(env));
  const seenFile = new JsonFile<Fingerprint | null>(`${env.state}/settings-seen`);
  const seen = await seenFile.read(null);
  if (check) {
    if (!seen) return 1;
    return (await checkFingerprint(settings, seen)) ? 0 : 1;
  }
  console.log(JSON.stringify(await fingerprint(settings, seen?.salt)));
  return 0;
}

class Daemon {
  private remoteState: RemoteState = "unreachable";
  private locked = false;
  private paused = false;
  private lastIdentityAt = 0;
  private syncer: Syncer | null = null;
  private couch!: Couch;
  private identityFile: JsonFile<StoredIdentity | null>;
  private stored: StoredIdentity | null = null;
  private obsidian: ObsidianWatch;
  private timers: ReturnType<typeof setInterval>[] = [];
  private stopping = false;

  constructor(private readonly env: Env) {
    this.identityFile = new JsonFile(`${env.state}/identity.json`);
    this.obsidian = new ObsidianWatch(env.obsidianJson, env.obsidianKeys);
  }

  async run(): Promise<number> {
    let settings: Settings = await readPluginSettings(dataJsonPath(this.env));
    this.couch = new Couch(settings.connection);
    this.timers.push(
      setInterval(() => this.writeHealth().catch((e) => log.warn(`health: ${errText(e)}`)), HEALTH_MS),
    );
    await this.writeHealth();

    let ident: RemoteIdentity;
    for (;;) {
      try {
        ident = await this.couch.identity();
        break;
      } catch (e) {
        this.remoteState = classifyError(e);
        log.warn(`CouchDB not reachable yet (${this.remoteState}): ${errText(e)}; retrying in 30 s`);
        await this.writeHealth();
        await new Promise((r) => setTimeout(r, 30_000));
      }
    }
    if (!ident.salt) {
      log.error(`${settings.connection.database} has no sync parameters document; refusing to start`);
      return 2;
    }
    this.remoteState = "ok";
    settings = applyPreferred(settings, ident.milestone);

    this.stored = await this.identityFile.read(null);
    const current = {
      endpoint: settings.connection.url,
      database: settings.connection.database,
      prefix: this.env.prefix,
    };
    if (this.stored) {
      for (const k of ["endpoint", "database", "prefix"] as const) {
        if (this.stored[k] !== current[k]) {
          log.error(
            `the ${k} changed from ${this.stored[k]} to ${current[k]}; run reset.sh before syncing again`,
          );
          return 2;
        }
      }
      if (this.stored.created !== ident.created || this.stored.salt !== ident.salt) {
        this.lock("remote was rebuilt");
      } else if (await this.noteInstance(ident.instance)) {
        await new JsonFile<{ since: string }>(`${this.env.state}/checkpoint.json`).write({ since: "" });
      }
    } else {
      this.stored = { ...current, created: ident.created, salt: ident.salt, instance: ident.instance };
      await this.identityFile.write(this.stored);
    }
    this.lastIdentityAt = Date.now();

    const remote = await CouchRemote.open({
      couch: this.couch,
      manipulatorOptions: manipulatorOptions(settings),
      prefix: this.env.prefix,
      beforeWrite: () => this.beforeRemoteWrite(),
    }, this.stored.salt);

    const local = new LocalStore(this.env.vault, this.env.prefix);
    this.paused = await this.obsidian.isOpen();
    this.syncer = new Syncer({
      remote,
      local,
      bases: await BaseStore.open(`${this.env.state}/base`),
      checkpoint: new JsonFile<{ since: string }>(`${this.env.state}/checkpoint.json`),
      pauses: new JsonFile<PauseWindow[]>(`${this.env.state}/pauses.json`),
      gate: { check: () => this.gateCheck() },
      identity: () => this.verifyIdentity(),
      recoveredDir: `${this.env.state.replace(/\/+[^/]+\/*$/, "")}/recovered`,
      releaseMarker: `${this.env.state}/release-deletions`,
    });
    log.info(`syncing ${this.env.wikiDir} with ${settings.connection.database}/${this.env.prefix}`);
    await this.syncer.start(this.paused || this.locked);
    this.timers.push(
      setInterval(
        () => this.pollObsidian().catch((e) => log.warn(`obsidian check: ${errText(e)}`)),
        OBSIDIAN_POLL_MS,
      ),
      setInterval(() => this.verifyIdentity().catch((e) => log.warn(`identity: ${errText(e)}`)), IDENTITY_MS),
    );
    await this.writeHealth();
    await new Promise<void>((resolve) => {
      const stop = () => resolve();
      Deno.addSignalListener("SIGTERM", stop);
      Deno.addSignalListener("SIGINT", stop);
    });
    await this.stop();
    return 0;
  }

  async stop(): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    for (const t of this.timers) clearInterval(t);
    await this.syncer?.stop();
    await this.writeHealth();
  }

  markError(e: unknown): void {
    log.error(`unhandled: ${errText(e)}`);
    this.remoteState = "error";
  }

  private lock(why: string): void {
    if (!this.locked) log.error(`${why}: sync is locked until reset.sh runs`);
    this.locked = true;
  }

  private async gateCheck(): Promise<void> {
    if (this.locked) throw new Blocked("locked");
    if (await this.obsidian.isOpen()) {
      void this.pollObsidian();
      throw new Blocked("paused");
    }
  }

  private async beforeRemoteWrite(): Promise<void> {
    await this.gateCheck();
    if (!(await this.verifyIdentity())) throw new Blocked("locked");
  }

  async verifyIdentity(): Promise<boolean> {
    let ident: RemoteIdentity;
    try {
      ident = await this.couch.identity();
    } catch (e) {
      this.remoteState = classifyError(e);
      return false;
    }
    this.remoteState = "ok";
    this.lastIdentityAt = Date.now();
    if (!ident.salt) {
      this.lock("the sync parameters document is gone");
    } else if (this.stored && (ident.created !== this.stored.created || ident.salt !== this.stored.salt)) {
      this.lock("the remote database was recreated (its created time or salt changed)");
    }
    if (!this.locked && (await this.noteInstance(ident.instance))) void this.syncer?.replayFromStart();
    const m = ident.milestone;
    const nodes = JSON.stringify([m?.locked ?? null, m?.accepted_nodes ?? null]);
    if (this.lastNodes !== null && nodes !== this.lastNodes) {
      log.notice("the milestone's lock or accepted devices changed");
    }
    this.lastNodes = nodes;
    return !this.locked;
  }

  private lastNodes: string | null = null;

  // True when the database was recreated with the same salt and created time, as a restore does.
  private async noteInstance(instance: string | null): Promise<boolean> {
    if (!this.stored || instance === null || this.stored.instance === instance) return false;
    const before = this.stored.instance;
    this.stored = { ...this.stored, instance };
    await this.identityFile.write(this.stored);
    if (!before) return false;
    log.notice("the remote database was recreated with the same identity, as a restore does: replaying it");
    return true;
  }

  private async pollObsidian(): Promise<void> {
    if (!this.syncer || this.locked) return;
    const open = await this.obsidian.isOpen();
    if (open && !this.syncer.isPaused()) await this.syncer.pause();
    else if (!open && this.syncer.isPaused()) await this.syncer.resume();
    this.paused = open;
  }

  private async writeHealth(): Promise<void> {
    const h = this.syncer?.health();
    const health = {
      ts: Date.now(),
      remote: this.remoteState,
      identityTs: this.lastIdentityAt,
      feedTs: h?.feedTs ?? 0,
      root: h?.root ?? "ok",
      locked: this.locked,
      paused: this.paused,
      oldestHandlerMs: h?.oldestHandlerMs ?? 0,
      failing: h?.failing ?? [],
      failedCount: h?.failedCount ?? 0,
      heldDeletions: h?.heldDeletions ?? 0,
      collisions: h?.collisions ?? 0,
      noRemote: h?.noRemote ?? 0,
      regressed: h?.regressed ?? 0,
      unreadable: h?.unreadable ?? 0,
      caughtUp: h?.caughtUp ?? false,
    };
    await new JsonFile<typeof health>(`${this.env.state}/health.json`).write(health);
  }
}

async function main(): Promise<number> {
  const env = readEnv();
  await Deno.mkdir(env.state, { recursive: true });
  const args = Deno.args;
  if (args.includes("--fingerprint")) return await fingerprintMode(env, false);
  if (args.includes("--check-fingerprint")) return await fingerprintMode(env, true);

  const lockFile = await Deno.open(`${env.state}/lock`, { create: true, write: true });
  if (!(await lockFile.tryLock(true))) {
    log.error("another wiki-sync instance holds the state lock");
    return 3;
  }
  const daemon = new Daemon(env);
  globalThis.addEventListener("unhandledrejection", (ev) => {
    ev.preventDefault();
    daemon.markError(ev.reason);
  });
  return await daemon.run();
}

if (import.meta.main) {
  try {
    Deno.exit(await main());
  } catch (e) {
    log.error(e instanceof SettingsError ? `settings: ${e.message}` : errText(e));
    Deno.exit(1);
  }
}
