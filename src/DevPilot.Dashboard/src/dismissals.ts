import { createHash, randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export interface InstanceDismissal {
  key: string;
  throughSequence: number;
}

export interface DismissalStorage {
  save(record: InstanceDismissal): Promise<void>;
  restoreAll(): Promise<number>;
}

const FILE_NAME = /^[a-f0-9]{64}(?:\.[1-9][0-9]{0,15})?\.json$/;
const MAX_RECORDS = 5_000;

function missing(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "ENOENT";
}

function validRecord(value: unknown): value is InstanceDismissal {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  return "key" in value && typeof value.key === "string" &&
    /^(reviewer|review-handler):[^\u0000-\u001f\u007f]{1,512}$/.test(value.key) &&
    "throughSequence" in value && typeof value.throughSequence === "number" &&
    Number.isSafeInteger(value.throughSequence) && value.throughSequence > 0;
}

function keyHash(key: string): string {
  return createHash("sha256").update(key).digest("hex");
}

function fileName(record: InstanceDismissal): string {
  return `${keyHash(record.key)}.${record.throughSequence}.json`;
}

export function defaultDismissalDirectory(): string {
  const base = process.platform === "win32"
    ? process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local")
    : process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
  return join(base, "DevPilot", "dashboard", "dismissed-instances");
}

// Immutable watermarks prevent a lagging dashboard from overwriting a newer
// dismissal. These records are display preferences, never authority.
export class FileDismissalStorage implements DismissalStorage {
  constructor(private readonly directory = defaultDismissalDirectory()) {}

  private async files(): Promise<string[]> {
    try {
      const entries = await readdir(this.directory, { withFileTypes: true });
      const files = entries.filter((entry) => FILE_NAME.test(entry.name)).map((entry) => entry.name);
      return files;
    } catch (error) {
      if (missing(error)) return [];
      throw error;
    }
  }

  async load(): Promise<InstanceDismissal[]> {
    const records = new Map<string, InstanceDismissal>();
    const files = await this.files();
    if (files.length > MAX_RECORDS) throw new Error("Too many dismissed instances; use Restore dismissed instances.");
    for (const name of files) {
      const path = join(this.directory, name);
      try {
        if ((await stat(path)).size > 4096) throw new Error(`Oversized dashboard dismissal record: ${name}`);
        const value: unknown = JSON.parse(await readFile(path, "utf8"));
        if (!validRecord(value) || (fileName(value) !== name && `${keyHash(value.key)}.json` !== name)) {
          throw new Error(`Invalid dashboard dismissal record: ${name}`);
        }
        if ((records.get(value.key)?.throughSequence ?? 0) < value.throughSequence) records.set(value.key, value);
      } catch (error) {
        if (!missing(error)) throw error;
      }
    }
    return [...records.values()];
  }

  async save(record: InstanceDismissal): Promise<void> {
    if (!validRecord(record)) throw new Error("Invalid dashboard dismissal.");
    const name = fileName(record);
    const files = await this.files();
    if (files.length >= MAX_RECORDS && !files.includes(name)) {
      throw new Error("Dismissal limit reached; use Restore dismissed instances.");
    }
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const temporary = join(this.directory, `${randomUUID()}.tmp`);
    try {
      await writeFile(temporary, JSON.stringify(record), { encoding: "utf8", flag: "wx", mode: 0o600 });
      await rename(temporary, join(this.directory, name));
    } finally {
      await rm(temporary, { force: true });
    }
  }

  async restoreAll(): Promise<number> {
    const files = await this.files();
    for (const name of files) await rm(join(this.directory, name), { force: true });
    return new Set(files.map((name) => name.slice(0, 64))).size;
  }
}
