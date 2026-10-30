const PROCESS_NAMES = new Set(["obsidian", "Obsidian"]);

export function obsidianRunning(psOutput: string): boolean {
  return psOutput.split("\n").some((line) => PROCESS_NAMES.has(line.trim()));
}

export function vaultMarkedOpen(configs: (string | null)[], keys: string[]): boolean {
  const parsed = configs.flatMap((text) => {
    if (text === null) return [];
    try {
      return [JSON.parse(text) as { vaults?: Record<string, { open?: boolean }> }];
    } catch {
      return [];
    }
  });
  if (parsed.length === 0 || keys.length === 0) return true;
  return parsed.some((c) => keys.some((k) => c.vaults?.[k]?.open === true));
}

export class ObsidianWatch {
  private cached: { at: number; open: boolean } | null = null;

  constructor(private readonly configPaths: string[], private readonly keys: string[]) {}

  async isOpen(maxAgeMs = 1000): Promise<boolean> {
    if (this.cached && Date.now() - this.cached.at <= maxAgeMs) return this.cached.open;
    const open = await this.probe().catch(() => true);
    this.cached = { at: Date.now(), open };
    return open;
  }

  private async probe(): Promise<boolean> {
    const out = await new Deno.Command("ps", { args: ["-axo", "ucomm="], stdout: "piped", stderr: "null" })
      .output();
    if (!out.success) return true;
    if (!obsidianRunning(new TextDecoder().decode(out.stdout))) return false;
    const configs = await Promise.all(this.configPaths.map((p) => Deno.readTextFile(p).catch(() => null)));
    return vaultMarkedOpen(configs, this.keys);
  }
}
