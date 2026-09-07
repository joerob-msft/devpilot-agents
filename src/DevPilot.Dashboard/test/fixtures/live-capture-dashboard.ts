// Installed as the dashboard entry in a private test toolkit. Real Watch, broker,
// process capture, ancestry checks, tailer and reducer remain production code.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DispatchClient } from "../../src/dispatch.js";
import { OperationsReducer, STALE_AFTER_MS } from "../../src/reducer.js";
import { EventTailer } from "../../src/tailer.js";
import { observeProcess, type LocalProcessStream } from "../../src/process-observer.js";

const args = process.argv.slice(2);
const value = (flag: string) => args[args.indexOf(flag) + 1]!;
let owned: LocalProcessStream[] = [];
const release = join(process.env.DEVPILOT_TEST_ARGV_DIR!, "release");
const reducer = new OperationsReducer();
const diagnostics: string[] = [];
const tailer = new EventTailer({
  stateDirectories: [], eventLogPaths: [],
  onEvent: (event, source) => { reducer.apply(event, source); },
  onDiagnostic: (item) => { diagnostics.push(item.kind); },
});
let streams: LocalProcessStream[] | undefined;
let brokerError = "";
let broker: DispatchClient | undefined;
async function waitFor(check: () => Promise<boolean>, label: string): Promise<void> {
  const until = Date.now() + 20_000;
  while (!(await check())) {
    assert.ok(Date.now() < until, label);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}
try {
  broker = new DispatchClient({
    executablePath: value("--broker-executable"),
    scriptPath: value("--broker-script"),
    descriptorPath: value("--broker-descriptor"),
  }, {
    onBrokerFailure: (message) => { brokerError = message; },
    onLocalStreams: (received) => {
      streams = received;
      for (const stream of received) {
        reducer.registerLocalStream(stream);
        tailer.registerEventLogPath(stream.eventLogPath);
      }
    },
  });
  await waitFor(async () => {
    assert.equal(brokerError, "");
    return streams?.length === 2;
  }, "real Golden broker did not publish live capture provenance");
  owned = streams!;
  assert.equal(streams!.length, 2);
  await waitFor(async () => {
    await tailer.poll();
    return reducer.list().length === 2;
  }, "real child stdout never reached the production tailer while alive");
  for (const stream of streams!) {
    assert.equal(await observeProcess(stream.processId), "present");
    assert.ok((await readFile(stream.eventLogPath)).length > 0);
  }
  assert.ok(reducer.list().every((state) => state.processOrigin === "local" && state.lastSequence === 1));
  await writeFile(release, "finish naturally");
  await waitFor(async () => (await Promise.all(owned.map((stream) => observeProcess(stream.processId)))).every((value) => value === "absent"),
    "fixture children did not exit naturally");
  await waitFor(async () => {
    await tailer.poll();
    return reducer.list().every((state) => state.lastSequence === 2);
  }, "split final JSONL frame was lost");
  await reducer.observeProcesses(observeProcess, Date.now() + STALE_AFTER_MS + 1_000);
  assert.equal(reducer.list(Date.now(), undefined, "current").length, 0);
  assert.equal(reducer.list(Date.now(), undefined, "live").length, 0);
  const history = reducer.list(Date.now(), undefined, "history");
  assert.equal(history.length, 2);
  assert.ok(history.every((state) => state.status === "exited" && state.completion === null && state.lifecycle !== "stopped"));
  assert.deepEqual(diagnostics, []);
  const captures = await Promise.all(streams!.map(async (stream) => ({
    path: stream.eventLogPath,
    hash: createHash("sha256").update(await readFile(stream.eventLogPath)).digest("hex"),
  })));
  await writeFile(join(process.env.DEVPILOT_TEST_ARGV_DIR!, "live-proof.json"), JSON.stringify({ captures, exited: history.length }));
} finally {
  await writeFile(release, "finish naturally");
  await waitFor(async () => (await Promise.all(owned.map((stream) => observeProcess(stream.processId)))).every((value) => value === "absent"),
    "fixture cleanup must not stop a live child");
  await tailer.stop();
  await broker?.shutdown(); // No manual children were dispatched.
}
