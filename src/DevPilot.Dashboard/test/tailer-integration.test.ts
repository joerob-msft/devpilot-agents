import assert from "node:assert/strict";
import test from "node:test";
import { spawn, type ChildProcess } from "node:child_process";
import { access, appendFile, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import fsPromises from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import type { AgentEvent, SourceDiagnostic } from "../src/domain.js";
import { EventTailer, INITIAL_EVENT_LOG_WAIT_MS } from "../src/tailer.js";
import { OperationsReducer } from "../src/reducer.js";

function eventLine(sequence: number): string {
  return JSON.stringify({
    schemaVersion: 2,
    agent: "reviewer",
    instanceId: "appearing-instance",
    processId: 10,
    timestamp: new Date(Date.parse("2026-08-25T12:00:00Z") + sequence * 1_000).toISOString(),
    sequence,
    eventType: sequence === 1 ? "agent.started" : "agent.heartbeat",
    level: "info",
    cycleNumber: 0,
    pullRequestId: 0,
    sourceCommit: "",
    data: {},
    message: "",
  });
}

async function waitForFile(path: string, child: ChildProcess, timeoutMilliseconds = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    try {
      await access(path);
      return;
    } catch {
      if (child.exitCode !== null) throw new Error(`tailer child exited before creating ${path}`);
      await new Promise((resolveWait) => setTimeout(resolveWait, 10));
    }
  }
  throw new Error(`timed out waiting for ${path}`);
}

test("tailer discovers files after startup and holds partial content", async () => {
  const root = join(process.cwd(), `.dashboard-test-${process.pid}-${Date.now()}`);
  const directory = join(root, "logs", "events", "reviewer");
  const path = join(directory, "instance.jsonl");
  const events: AgentEvent[] = [];
  const diagnostics: SourceDiagnostic[] = [];
  const tailer = new EventTailer({
    stateDirectories: [root],
    eventLogPaths: [],
    onEvent: (event) => events.push(event),
    onDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
  });
  try {
    await tailer.poll();
    await mkdir(directory, { recursive: true });
    await writeFile(path, `${eventLine(1)}\n${eventLine(2).slice(0, 30)}`, "utf8");
    await tailer.poll();
    assert.deepEqual(events.map((item) => item.sequence), [1]);
    await appendFile(path, `${eventLine(2).slice(30)}\n`, "utf8");
    await tailer.poll();
    assert.deepEqual(events.map((item) => item.sequence), [1, 2]);
    assert.equal(diagnostics.length, 0);
  } finally {
    await tailer.stop();
    await rm(root, { recursive: true, force: true });
  }
});

test("started tailer keeps its process alive to poll a growing event stream", async () => {
  const root = join(process.cwd(), `.dashboard-test-${process.pid}-${Date.now()}`);
  const path = join(root, "instance.jsonl");
  const readyPath = join(root, "ready");
  const observedPath = join(root, "observed");
  let child: ChildProcess | undefined;
  try {
    await mkdir(root, { recursive: true });
    await writeFile(path, `${eventLine(1)}\n`, "utf8");
    child = spawn(process.execPath, [join(process.cwd(), "dist", "test", "tailer-process-fixture.js"), root, path], {
      stdio: "ignore",
    });
    await waitForFile(readyPath, child);
    await appendFile(path, `${eventLine(2)}\n`, "utf8");
    await waitForFile(observedPath, child);
  } finally {
    if (child?.exitCode === null) child.kill();
    await rm(root, { recursive: true, force: true });
  }
});

test("tailer resets after truncation and bounds malformed diagnostics", async () => {
  const root = join(process.cwd(), `.dashboard-test-${process.pid}-${Date.now()}`);
  const path = join(root, "explicit.jsonl");
  const events: AgentEvent[] = [];
  const diagnostics: SourceDiagnostic[] = [];
  const tailer = new EventTailer({
    stateDirectories: [],
    eventLogPaths: [path],
    onEvent: (event) => events.push(event),
    onDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
  });
  try {
    await mkdir(root, { recursive: true });
    await writeFile(path, `${eventLine(1)}\n`, "utf8");
    await tailer.poll();
    await writeFile(path, "{bad}\n", "utf8");
    await tailer.poll();
    assert.equal(events.length, 1);
    assert.equal(diagnostics.length, 1);
    assert.equal(diagnostics[0]?.kind, "malformed");
  } finally {
    await tailer.stop();
    await rm(root, { recursive: true, force: true });
  }
});

test("tailer discovers agent streams below a state namespace root", async () => {
  const root = join(process.cwd(), `.dashboard-test-${process.pid}-${Date.now()}`);
  const directory = join(root, "Reviewer", "agent-name", "logs", "events", "reviewer");
  const path = join(directory, "instance.jsonl");
  const events: AgentEvent[] = [];
  const tailer = new EventTailer({
    stateDirectories: [root],
    eventLogPaths: [],
    onEvent: (event) => events.push(event),
    onDiagnostic: () => {},
  });
  try {
    await mkdir(directory, { recursive: true });
    await writeFile(path, `${eventLine(1)}\n`, "utf8");
    await tailer.poll();
    assert.deepEqual(events.map((item) => item.sequence), [1]);
  } finally {
    await tailer.stop();
    await rm(root, { recursive: true, force: true });
  }
});

test("tailer detects same-file truncate and regrow past the previous offset", async () => {
  const root = join(process.cwd(), `.dashboard-test-${process.pid}-${Date.now()}`);
  const path = join(root, "events.jsonl");
  const events: AgentEvent[] = [];
  const tailer = new EventTailer({
    stateDirectories: [],
    eventLogPaths: [path],
    onEvent: (event) => events.push(event),
    onDiagnostic: () => {},
  });

  try {
    await mkdir(root, { recursive: true });
    await writeFile(path, `${eventLine(1)}\n`, "utf8");
    await tailer.poll();
    await writeFile(path, `${eventLine(2)}\n${eventLine(3)}\n`, "utf8");
    await tailer.poll();
    assert.deepEqual(events.map((item) => item.sequence), [1, 2, 3]);
  } finally {
    await tailer.stop();
    await rm(root, { recursive: true, force: true });
  }
});

test("tailer drains unread rotated events before the new active generation", async () => {
  const root = join(process.cwd(), `.dashboard-test-${process.pid}-${Date.now()}`);
  const directory = join(root, "logs", "events", "reviewer");
  const path = join(directory, "instance.jsonl");
  const reducer = new OperationsReducer();
  const tailer = new EventTailer({
    stateDirectories: [root],
    eventLogPaths: [],
    onEvent: (event, source) => reducer.apply(event, source),
    onDiagnostic: (diagnostic) => reducer.addSourceDiagnostic(diagnostic),
  });

  try {
    await mkdir(directory, { recursive: true });
    await writeFile(path, `${eventLine(1)}\n`, "utf8");
    await tailer.poll();
    await appendFile(path, `${eventLine(2)}\n`, "utf8");
    await rename(path, `${path}.1`);
    await writeFile(path, `${eventLine(3)}\n`, "utf8");
    await tailer.poll();
    assert.deepEqual(
      reducer.get("reviewer:appearing-instance")?.timeline.map((event) => event.sequence),
      [1],
    );
    assert.equal(reducer.get("reviewer:appearing-instance")?.lastSequence, 3);
  } finally {
    await tailer.stop();
    await rm(root, { recursive: true, force: true });
  }
});

test("tailer rechecks rotations when the active file rotates immediately before read", async () => {
  const root = join(process.cwd(), `.dashboard-test-${process.pid}-${Date.now()}`);
  const directory = join(root, "logs", "events", "reviewer");
  const path = join(directory, "instance.jsonl");
  const reducer = new OperationsReducer();
  let rotateBeforeRead = false;
  const tailer = new EventTailer({
    stateDirectories: [root],
    eventLogPaths: [],
    onEvent: (event, source) => reducer.apply(event, source),
    onDiagnostic: (diagnostic) => reducer.addSourceDiagnostic(diagnostic),
    beforeActiveRead: async (activePath) => {
      if (!rotateBeforeRead || activePath !== path) return;
      rotateBeforeRead = false;
      await rename(path, `${path}.1`);
      await writeFile(path, `${eventLine(3)}\n`, "utf8");
    },
  });
  try {
    await mkdir(directory, { recursive: true });
    await writeFile(path, `${eventLine(1)}\n`, "utf8");
    await tailer.poll();
    await appendFile(path, `${eventLine(2)}\n`, "utf8");
    rotateBeforeRead = true;
    await tailer.poll();
    assert.equal(reducer.get("reviewer:appearing-instance")?.lastSequence, 3);
    assert.equal(reducer.get("reviewer:appearing-instance")?.gapCount, 0);
  } finally {
    await tailer.stop();
    await rm(root, { recursive: true, force: true });
  }
});

  test("accepted path waits for first creation, ingests late and rotated events, but diagnoses disappearance", async () => {
    const root = join(process.cwd(), `.dashboard-test-late-${process.pid}-${Date.now()}`);
    const path = join(root, "late.jsonl");
    const events: AgentEvent[] = [];
    const diagnostics: SourceDiagnostic[] = [];
    const tailer = new EventTailer({
      stateDirectories: [], eventLogPaths: [],
      onEvent: (event) => events.push(event), onDiagnostic: (diagnostic) => diagnostics.push(diagnostic),
    });
    try {
      tailer.registerEventLogPath(path);
      await tailer.stop();
      for (let attempt = 0; attempt < 25; attempt++) await tailer.poll();
      assert.equal(diagnostics.length, 0, "initial ENOENT must not exhaust the diagnostic budget");
      await mkdir(root, { recursive: true });
      await writeFile(`${path}.1`, `${eventLine(1)}\n`);
      await writeFile(path, `${eventLine(2)}\n`);
      await tailer.poll();
      assert.deepEqual(events.map((event) => event.sequence), [1, 2]);
      await rm(path);
      await tailer.poll();
      assert.equal(diagnostics.at(-1)?.kind, "io");
      assert.match(diagnostics.at(-1)?.message ?? "", /cannot read event log/);
    } finally {
      await tailer.stop();
      await rm(root, { recursive: true, force: true });
    }
  });

  test("only initial ENOENT gets grace: explicit missing paths and permissions fail visibly; prolonged absence warns once", async (context) => {
    const path = join(process.cwd(), `.dashboard-test-absent-${process.pid}-${Date.now()}.jsonl`);
    const diagnostics: SourceDiagnostic[] = [];
    const options = { stateDirectories: [], eventLogPaths: [path], onEvent: () => {}, onDiagnostic: (d: SourceDiagnostic) => diagnostics.push(d) };
    const explicit = new EventTailer(options);
    await explicit.poll();
    assert.match(diagnostics.at(-1)?.message ?? "", /cannot read event log/);
    diagnostics.length = 0;
    const tailer = new EventTailer({ ...options, eventLogPaths: [] });
    try {
      tailer.registerEventLogPath(path);
      await tailer.stop();
      const originalNow = Date.now();
      const clock = context.mock.method(Date, "now", () => originalNow + INITIAL_EVENT_LOG_WAIT_MS + 1);
      await tailer.poll();
      await tailer.poll();
      assert.equal(diagnostics.length, 1);
      assert.match(diagnostics[0]?.message ?? "", /progress is unknown/);
      clock.mock.restore();
      const statMock = context.mock.method(fsPromises, "stat", async () => {
        throw Object.assign(new Error("permission denied"), { code: "EACCES" });
      });
      syncBuiltinESMExports();
      try {
        await tailer.poll();
      } finally {
        statMock.mock.restore();
        syncBuiltinESMExports();
      }
      assert.match(diagnostics.at(-1)?.message ?? "", /permission denied/);
    } finally {
      await tailer.stop();
    }
  });
