import type { LeafInfo, RevContent } from "./reconcile.ts";

export interface RemoteLeaf extends LeafInfo {
  path: string | null;
}

export interface RevBody {
  content: RevContent;
  bytes: Uint8Array;
  path: string;
}

export interface Change {
  id: string;
  seq: string;
}

export interface FeedHandle {
  cancel(): void;
  done: Promise<{ lastSeq: string; error?: unknown }>;
}

export type CasResult = { rev: string; mtime: number } | "conflict";

export interface RemoteStore {
  idOf(path: string): Promise<string>;
  accepts(path: string): boolean;
  readLeaves(id: string): Promise<RemoteLeaf[]>;
  readRev(id: string, rev: string): Promise<RevBody | null>;
  casPut(
    path: string,
    bytes: Uint8Array,
    times: { mtime: number; ctime: number },
    parentRev: string | null,
  ): Promise<CasResult>;
  casDelete(path: string, parentRev: string): Promise<CasResult>;
  changes(opts: { since: string; live: boolean; onChange: (c: Change) => void }): FeedHandle;
  feedTs(): number;
}
