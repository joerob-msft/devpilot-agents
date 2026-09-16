import { closeSync, fstatSync, openSync, readSync } from "node:fs";
import { noLinks, object } from "./manifest.js";

export function observeLegacy(files: string[]) {
  const streams = new Map<string, { agent: string; instanceId: string; eventType: string;
    timestamp: string; sequence: number; message: string; pullRequestId: unknown; source: string }>();
  const diagnostics: string[] = [];
  for (const file of files) {
    let fd: number | undefined;
    try {
      noLinks(file);
      fd = openSync(file, "r");
      const size = fstatSync(fd).size;
      const start = Math.max(0, size - 1048576);
      const bytes = Buffer.alloc(Math.min(size, 1048576));
      const read = readSync(fd, bytes, 0, bytes.length, start);
      const lines = bytes.subarray(0, read).toString("utf8").split("\n");
      if (start > 0) { lines.shift(); diagnostics.push(`${file}: reading last 1 MiB only; earlier history unavailable`); }
      lines.pop(); // An unterminated event may still be in flight.
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const event = object(JSON.parse(line), "legacy event");
          if (event.agent !== "reviewer" && event.agent !== "review-handler") continue;
          if (typeof event.instanceId !== "string" || event.instanceId.length > 128 ||
              typeof event.sequence !== "number" || !Number.isInteger(event.sequence) ||
              typeof event.eventType !== "string") continue;
          const key = `${file}:${event.agent}:${event.instanceId}`;
          if (streams.size >= 100 && !streams.has(key)) continue;
          const previous = streams.get(key);
          if (previous && previous.sequence >= event.sequence) continue;
          streams.set(key, {
            agent: event.agent, instanceId: event.instanceId, sequence: event.sequence,
            eventType: event.eventType.slice(0, 100),
            timestamp: typeof event.timestamp === "string" ? event.timestamp.slice(0, 64) : "",
            message: typeof event.message === "string" ? event.message.slice(0, 500) : "",
            pullRequestId: typeof event.pullRequestId === "number" ? event.pullRequestId : null, source: file,
          });
        } catch { if (diagnostics.length < 20) diagnostics.push(`${file}: malformed event skipped`); }
      }
    } catch (error) { diagnostics.push(`${file}: ${error instanceof Error ? error.message : String(error)}`); }
    finally { if (fd !== undefined) closeSync(fd); }
  }
  return { streams: [...streams.values()], diagnostics: diagnostics.slice(0, 20),
    note: "Observed JSONL only. No control authority, complete history, or verified process liveness." };
}
