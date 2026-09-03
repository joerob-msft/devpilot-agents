import assert from "node:assert/strict";
import test from "node:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { discoverEventLogs, EventTailer, LineCursor } from "../src/tailer.js";

test("partial final lines are held until newline", () => {
  const cursor = new LineCursor();
  cursor.accept({ size: 15, identity: "one" });
  assert.deepEqual(cursor.push(Buffer.from('{"a":1}\n{"b":')), ['{"a":1}']);
  assert.equal(cursor.partial.toString(), '{"b":');
  assert.deepEqual(cursor.push(Buffer.from("2}\r\n")), ['{"b":2}']);
  assert.equal(cursor.partial.length, 0);
});

test("truncation resets offset and partial content", () => {
  const cursor = new LineCursor();
  cursor.accept({ size: 20, identity: "one" });
  cursor.push(Buffer.from("partial"));
  assert.equal(cursor.offset, 7);
  assert.equal(cursor.accept({ size: 2, identity: "one" }), true);
  assert.equal(cursor.offset, 0);
  assert.equal(cursor.partial.length, 0);
  assert.equal(cursor.prefix.length, 0);
  assert.equal(cursor.continuity.length, 0);
});

test("replacement rotation resets even when the new file is larger", () => {
  const cursor = new LineCursor();
  cursor.accept({ size: 20, identity: "one" });
  cursor.push(Buffer.from("old partial"));
  assert.equal(cursor.accept({ size: 100, identity: "two" }), true);
  assert.equal(cursor.offset, 0);
  assert.equal(cursor.partial.length, 0);
  assert.equal(cursor.identity, "two");
});

test("complete UTF-8 characters split across chunks are decoded safely", () => {
  const cursor = new LineCursor();
  cursor.accept({ size: 10, identity: "one" });
  const encoded = Buffer.from([0x22, 0x6f, 0x6b, 0x20, 0xc3, 0xa9, 0x22, 0x0a]);
  const split = 5;
  assert.deepEqual(cursor.push(encoded.subarray(0, split)), []);
  assert.equal(cursor.push(encoded.subarray(split))[0], Buffer.from(encoded.subarray(0, -1)).toString("utf8"));
});

test("accepted event paths can be registered dynamically without duplicates", () => {
  const tailer = new EventTailer({
    stateDirectories: [],
    eventLogPaths: [],
    onEvent: () => {},
    onDiagnostic: () => {},
  });
  const path = join(process.cwd(), "logs", "events", "reviewer", "dispatch.jsonl");
  assert.equal(tailer.registerEventLogPath(path), true);
  assert.equal(tailer.registerEventLogPath(path), false);
});

test("more than 500 dispatch-like directories cannot hide canonical flat event logs", () => {
  const root = join(process.cwd(), `.tailer-discovery-${process.pid}-${Date.now()}`);
  try {
    for (let index = 0; index < 501; index++) mkdirSync(join(root, `dispatch-${String(index).padStart(3, "0")}`), { recursive: true });
    const eventDirectory = join(root, "logs", "events", "reviewer");
    mkdirSync(eventDirectory, { recursive: true });
    const eventPath = join(eventDirectory, "instance.jsonl");
    writeFileSync(eventPath, "");
    assert.ok(discoverEventLogs([root], []).includes(eventPath));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
