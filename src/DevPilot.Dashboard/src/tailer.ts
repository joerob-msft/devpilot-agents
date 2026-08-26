import { open, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { readdirSync, statSync } from "node:fs";
import { parseAgentEventLine, type AgentEvent, type SourceDiagnostic } from "./domain.js";

const READ_CHUNK_BYTES = 64 * 1024;
const MAX_DIAGNOSTICS_PER_SOURCE = 20;
const CONTINUITY_BYTES = 256;

export interface TailerOptions {
  stateDirectories: string[];
  eventLogPaths: string[];
  pollMilliseconds?: number;
  onEvent: (event: AgentEvent, source: string) => void;
  onDiagnostic: (diagnostic: SourceDiagnostic) => void;
  beforeActiveRead?: (path: string) => Promise<void>;
}

export interface FileSnapshot {
  size: number;
  identity: string;
}

interface BufferedEvent {
  event: AgentEvent;
  source: string;
}

export class LineCursor {
  offset = 0;
  partial: Buffer<ArrayBufferLike> = Buffer.alloc(0);
  prefix: Buffer<ArrayBufferLike> = Buffer.alloc(0);
  continuity: Buffer<ArrayBufferLike> = Buffer.alloc(0);
  identity = "";

  reset(identity = ""): void {
    this.offset = 0;
    this.partial = Buffer.alloc(0);
    this.prefix = Buffer.alloc(0);
    this.continuity = Buffer.alloc(0);
    this.identity = identity;
  }

  accept(snapshot: FileSnapshot): boolean {
    const replaced = Boolean(this.identity && snapshot.identity && this.identity !== snapshot.identity);
    const truncated = snapshot.size < this.offset;
    if (replaced || truncated) this.reset(snapshot.identity);
    if (!this.identity) this.identity = snapshot.identity;
    return replaced || truncated;
  }

  push(chunk: Buffer): string[] {
    if (this.prefix.length < CONTINUITY_BYTES) {
      const needed = CONTINUITY_BYTES - this.prefix.length;
      this.prefix = Buffer.concat([this.prefix, chunk.subarray(0, needed)]);
    }
    this.continuity = Buffer.concat([this.continuity, chunk]).subarray(-CONTINUITY_BYTES);
    this.offset += chunk.length;
    const combined = this.partial.length ? Buffer.concat([this.partial, chunk]) : chunk;
    const lines: string[] = [];
    let start = 0;
    for (let index = 0; index < combined.length; index++) {
      if (combined[index] !== 0x0a) continue;
      let end = index;
      if (end > start && combined[end - 1] === 0x0d) end--;
      lines.push(combined.subarray(start, end).toString("utf8"));
      start = index + 1;
    }
    this.partial = combined.subarray(start);
    return lines;
  }
}

function identityOf(value: { dev: number | bigint; ino: number | bigint; birthtimeMs: number }): string {
  return `${String(value.dev)}:${String(value.ino)}:${value.birthtimeMs}`;
}

export function discoverEventLogs(stateDirectories: string[], explicitPaths: string[]): string[] {
  const found = new Set<string>();
  for (const item of explicitPaths) {
    const path = resolve(item);
    found.add(path);
    for (let generation = 1; generation <= 5; generation++) {
      const rotated = `${path}.${generation}`;
      try {
        if (statSync(rotated).isFile()) found.add(rotated);
      } catch {
        // A rotation may appear on a later discovery pass.
      }
    }
  }
  for (const stateDirectory of stateDirectories) {
    const queue: Array<{ path: string; depth: number }> = [{ path: resolve(stateDirectory), depth: 0 }];
    let visited = 0;
    while (queue.length && visited++ < 500) {
      const current = queue.shift();
      if (!current) break;
      let entries;
      try {
        entries = readdirSync(current.path, { withFileTypes: true });
      } catch {
        continue;
      }
      const normalized = current.path.replaceAll("\\", "/").toLowerCase();
      const isEventDirectory =
        normalized.endsWith("/logs/events/reviewer") || normalized.endsWith("/logs/events/review-handler");
      for (const entry of entries) {
        const path = join(current.path, entry.name);
        if (entry.isFile() && isEventDirectory && /\.jsonl(?:\.\d+)?$/i.test(entry.name)) {
          try {
            if (statSync(path).isFile()) found.add(path);
          } catch {
            // The next discovery pass will retry files racing creation or rotation.
          }
        } else if (entry.isDirectory() && current.depth < 6) {
          queue.push({ path, depth: current.depth + 1 });
        }
      }
    }
  }
  return [...found].sort((left, right) => {
    const leftMatch = /^(.*\.jsonl)(?:\.(\d+))?$/i.exec(left);
    const rightMatch = /^(.*\.jsonl)(?:\.(\d+))?$/i.exec(right);
    const leftBase = leftMatch?.[1] ?? left;
    const rightBase = rightMatch?.[1] ?? right;
    const baseOrder = leftBase.localeCompare(rightBase);
    if (baseOrder) return baseOrder;
    const leftGeneration = Number(leftMatch?.[2] ?? 0);
    const rightGeneration = Number(rightMatch?.[2] ?? 0);
    return rightGeneration - leftGeneration;
  });
}

export class EventTailer {
  private readonly cursors = new Map<string, LineCursor>();
  private readonly diagnosticCounts = new Map<string, number>();
  private timer: NodeJS.Timeout | undefined;
  private polling = false;

  constructor(private readonly options: TailerOptions) {}

  start(): void {
    if (this.timer) return;
    void this.poll();
    this.timer = setInterval(() => void this.poll(), this.options.pollMilliseconds ?? 300);
    this.timer.unref();
  }

  async stop(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    while (this.polling) await new Promise((resolveWait) => setTimeout(resolveWait, 10));
  }

  async poll(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      const paths = discoverEventLogs(this.options.stateDirectories, this.options.eventLogPaths);
      const bases = new Set(paths.map((path) => /^(.*\.jsonl)(?:\.\d+)?$/i.exec(path)?.[1] ?? path));
      for (const base of bases) await this.pollStream(base);
    } finally {
      this.polling = false;
    }
  }

  private async pollStream(base: string): Promise<void> {
    const buffered: BufferedEvent[] = [];
    for (let attempt = 0; attempt < 3; attempt++) {
      const activeBefore = await this.activeIdentity(base);
      const before = await this.rotationSnapshot(base);
      for (let generation = 5; generation >= 1; generation--) {
        if (before.has(generation)) await this.pollFile(`${base}.${generation}`, buffered);
      }
      const after = await this.rotationSnapshot(base);
      if (!this.sameRotationSnapshot(before, after)) continue;

      const activeIdentity = await this.activeIdentity(base);
      if (activeBefore !== activeIdentity) continue;
      await this.options.beforeActiveRead?.(base);
      const result = await this.pollFile(base, buffered, activeIdentity);
      if (result === "changed") continue;
      this.flush(buffered);
      return;
    }
    this.flush(buffered);
  }

  private async activeIdentity(path: string): Promise<string | null> {
    try {
      const value = await stat(path);
      return value.isFile() ? identityOf(value) : null;
    } catch {
      return null;
    }
  }

  private async pollFile(
    path: string,
    buffered: BufferedEvent[],
    expectedIdentity?: string | null,
  ): Promise<"read" | "changed" | "missing"> {
    let snapshot;
    try {
      snapshot = await stat(path);
    } catch (error) {
      if (this.options.eventLogPaths.map((item) => resolve(item)).includes(resolve(path))) {
        this.diagnostic(path, "io", `cannot read event log: ${error instanceof Error ? error.message : String(error)}`);
      }
      return expectedIdentity !== undefined && expectedIdentity !== null ? "changed" : "missing";
    }
    if (!snapshot.isFile()) return "missing";
    const cursor = this.cursors.get(path) ?? new LineCursor();
    if (expectedIdentity !== undefined && identityOf(snapshot) !== expectedIdentity) return "changed";

    let handle;
    try {
      handle = await open(path, "r");
      const openedSnapshot = await handle.stat();
      if (expectedIdentity !== undefined && identityOf(openedSnapshot) !== expectedIdentity) return "changed";
      cursor.accept({ size: openedSnapshot.size, identity: identityOf(openedSnapshot) });
      this.cursors.set(path, cursor);
      if (openedSnapshot.size === 0 && cursor.offset === 0) return "read";
      if (cursor.offset > 0 && !(await this.matchesConsumedContent(handle, cursor))) {
        cursor.reset(identityOf(openedSnapshot));
      }
      while (cursor.offset < openedSnapshot.size) {
        const length = Math.min(READ_CHUNK_BYTES, openedSnapshot.size - cursor.offset);
        const buffer = Buffer.allocUnsafe(length);
        const result = await handle.read(buffer, 0, length, cursor.offset);
        if (!result.bytesRead) break;
        for (const line of cursor.push(buffer.subarray(0, result.bytesRead))) {
          if (!line.trim()) continue;
          try {
            buffered.push({ event: parseAgentEventLine(line), source: path });
          } catch (error) {
            this.diagnostic(path, "malformed", error instanceof Error ? error.message : String(error));
          }
        }
      }
    } catch (error) {
      this.diagnostic(path, "io", error instanceof Error ? error.message : String(error));
    } finally {
      if (handle) await handle.close();
    }
    return "read";
  }

  private async rotationSnapshot(base: string): Promise<Map<number, FileSnapshot>> {
    const snapshot = new Map<number, FileSnapshot>();
    for (let generation = 1; generation <= 5; generation++) {
      try {
        const value = await stat(`${base}.${generation}`);
        if (value.isFile()) snapshot.set(generation, { size: value.size, identity: identityOf(value) });
      } catch {
        // Missing generations are expected before the first rotation and while rotation is in progress.
      }
    }
    return snapshot;
  }

  private sameRotationSnapshot(left: Map<number, FileSnapshot>, right: Map<number, FileSnapshot>): boolean {
    if (left.size !== right.size) return false;
    for (const [generation, snapshot] of left) {
      const other = right.get(generation);
      if (!other || other.identity !== snapshot.identity || other.size !== snapshot.size) return false;
    }
    return true;
  }

  private flush(buffered: BufferedEvent[]): void {
    buffered.sort(
      (left, right) =>
        left.event.agent.localeCompare(right.event.agent) ||
        left.event.instanceId.localeCompare(right.event.instanceId) ||
        left.event.sequence - right.event.sequence,
    );
    for (const item of buffered) this.options.onEvent(item.event, item.source);
  }

  private async matchesConsumedContent(
    handle: Awaited<ReturnType<typeof open>>,
    cursor: LineCursor,
  ): Promise<boolean> {
    if (!cursor.prefix.length || !cursor.continuity.length) return true;
    const prefix = Buffer.alloc(cursor.prefix.length);
    const prefixRead = await handle.read(prefix, 0, prefix.length, 0);
    if (prefixRead.bytesRead !== prefix.length || !prefix.equals(cursor.prefix)) return false;
    const continuity = Buffer.alloc(cursor.continuity.length);
    const start = Math.max(0, cursor.offset - continuity.length);
    const continuityRead = await handle.read(continuity, 0, continuity.length, start);
    return continuityRead.bytesRead === continuity.length && continuity.equals(cursor.continuity);
  }

  private diagnostic(source: string, kind: SourceDiagnostic["kind"], message: string): void {
    const count = this.diagnosticCounts.get(source) ?? 0;
    if (count >= MAX_DIAGNOSTICS_PER_SOURCE) return;
    this.diagnosticCounts.set(source, count + 1);
    this.options.onDiagnostic({ source, kind, message, timestampMs: Date.now() });
  }
}
