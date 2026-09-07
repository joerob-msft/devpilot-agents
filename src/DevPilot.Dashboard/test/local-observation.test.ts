import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { DispatchClient } from "../src/dispatch.js";
import type { LocalProcessStream } from "../src/process-observer.js";

test("the existing broker channel accepts bounded local capture metadata, not arbitrary or malformed provenance", async () => {
  const lookup = process.platform === "win32" ? "where.exe" : "which";
  const executablePath = execFileSync(lookup, ["pwsh"], { encoding: "utf8" }).trim().split(/\r?\n/)[0]!;
  const root = await mkdtemp(join(process.cwd(), ".dashboard-local-observation-"));
  const scriptPath = join(root, "broker.ps1");
  const descriptorPath = join(root, "notification.json");
  try {
    await writeFile(scriptPath, String.raw`
param([string]$DescriptorPath)
[Console]::Out.WriteLine([IO.File]::ReadAllText($DescriptorPath))
`, "utf8");
    const stream = { role: "reviewer", processId: 42, eventLogPath: join(root, "reviewer.stdout.jsonl") };
    for (const testCase of [
      { streams: [stream], valid: true },
      { streams: [], valid: true },
      { streams: [{ ...stream, processId: -1 }], valid: false },
      { streams: [{ ...stream, role: "other" }], valid: false },
      { streams: [{ ...stream, eventLogPath: "copied.jsonl" }], valid: false },
      { streams: [{ ...stream, eventLogPath: `${stream.eventLogPath}\n` }], valid: false },
      { streams: [stream, stream, stream], valid: false },
      { streams: [stream, stream], valid: false },
      { streams: [{ ...stream }, { ...stream, role: "review-handler" }], valid: false },
      { streams: [stream], requestId: "11111111-1111-4111-8111-111111111111", valid: false },
    ]) {
      await writeFile(descriptorPath, JSON.stringify({
        schemaVersion: 1, requestId: testCase.requestId ?? "00000000-0000-0000-0000-000000000000",
        operation: "local-observation", streams: testCase.streams,
      }));
      const received: LocalProcessStream[][] = [];
      let finished!: () => void;
      const ended = new Promise<void>((resolve) => { finished = resolve; });
      const client = new DispatchClient({ executablePath, scriptPath, descriptorPath }, {
        onLocalStreams: (streams) => { received.push(streams); },
        onBrokerFailure: () => { finished(); },
      });
      await ended;
      assert.equal(received.length, testCase.valid ? 1 : 0);
      if (testCase.valid) assert.deepEqual(received[0], testCase.streams);
      await client.shutdown();
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
