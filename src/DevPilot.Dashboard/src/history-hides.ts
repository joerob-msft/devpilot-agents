import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { defaultDismissalDirectory } from "./dismissals.js";
import { PR_HISTORY_LIMIT } from "./history.js";

export interface HistoryHides {
  hiddenKeys: string[];
  clearedThroughMs: number;
}

export interface HistoryHideStorage {
  load(): Promise<HistoryHides>;
  save(value: HistoryHides): Promise<void>;
}

const MAX_FILE_BYTES = 2 * 1024 * 1024;
const MAX_KEY_LENGTH = 600;
// Canonical PR history key: "<repository identity key>:pr:<positive id>", printable only.
const HISTORY_KEY = /^[^\u0000-\u001f\u007f]{1,580}:pr:[1-9][0-9]{0,9}$/;

export function isHistoryKey(value: unknown): value is string {
  return typeof value === "string" && value.length <= MAX_KEY_LENGTH && HISTORY_KEY.test(value);
}

function valid(value: unknown): value is HistoryHides {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const record = value as Record<string, unknown>;
  return Array.isArray(record.hiddenKeys) && record.hiddenKeys.length <= PR_HISTORY_LIMIT &&
    record.hiddenKeys.every(isHistoryKey) &&
    typeof record.clearedThroughMs === "number" && Number.isSafeInteger(record.clearedThroughMs) &&
    record.clearedThroughMs >= 0;
}

export function defaultHistoryHideFile(): string {
  // Sibling of the dismissed-instances folder: same private, per-user dashboard state root.
  return join(dirname(defaultDismissalDirectory()), "hidden-pr-history.v1.json");
}

// Display preferences only, never authority. Written atomically, private to the user.
export class FileHistoryHideStorage implements HistoryHideStorage {
  constructor(private readonly file = defaultHistoryHideFile()) {}

  async load(): Promise<HistoryHides> {
    try {
      if ((await stat(this.file)).size > MAX_FILE_BYTES) throw new Error("Oversized PR history hide record.");
      const value: unknown = JSON.parse(await readFile(this.file, "utf8"));
      if (!valid(value)) throw new Error("Invalid PR history hide record.");
      return { hiddenKeys: [...new Set(value.hiddenKeys)], clearedThroughMs: value.clearedThroughMs };
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "ENOENT") return { hiddenKeys: [], clearedThroughMs: 0 };
      throw error;
    }
  }

  async save(value: HistoryHides): Promise<void> {
    const record: HistoryHides = { hiddenKeys: [...new Set(value.hiddenKeys)], clearedThroughMs: value.clearedThroughMs };
    if (!valid(record)) throw new Error("Invalid PR history hide record.");
    await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
    const temporary = join(dirname(this.file), `${randomUUID()}.tmp`);
    try {
      await writeFile(temporary, JSON.stringify(record), { encoding: "utf8", flag: "wx", mode: 0o600 });
      await rename(temporary, this.file);
    } finally {
      await rm(temporary, { force: true });
    }
  }
}
