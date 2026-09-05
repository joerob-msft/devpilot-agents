import assert from "node:assert/strict";
import test from "node:test";
import { getString, getStringArray, parseAgentEvent, parseAgentEventLine } from "../src/domain.js";

function validEvent(): Record<string, unknown> {
  return {
    agent: "reviewer",
    instanceId: "instance-1",
    processId: 42,
    timestamp: "2026-08-25T12:00:00.000Z",
    sequence: 1,
    eventType: "agent.started",
    level: "info",
    cycleNumber: 0,
    pullRequestId: 0,
    sourceCommit: "",
    data: { repository: "sample", additiveField: { future: true } },
    message: "started",
    futureEnvelopeField: "ignored",
  };
}

test("schema parser defaults version and accepts additive fields", () => {
  const event = parseAgentEvent(validEvent());
  assert.equal(event.schemaVersion, 1);
  assert.equal(event.agent, "reviewer");
  assert.equal(event.data.repository, "sample");
  assert.deepEqual(event.data.additiveField, { future: true });
});

test("schema parser validates identity, sequence, role, and timestamp", () => {
  assert.throws(() => parseAgentEvent({ ...validEvent(), agent: "writer" }), /agent/);
  assert.throws(() => parseAgentEvent({ ...validEvent(), instanceId: "" }), /instanceId/);
  assert.throws(() => parseAgentEvent({ ...validEvent(), sequence: -1 }), /sequence/);
  assert.throws(() => parseAgentEvent({ ...validEvent(), timestamp: "yesterday" }), /timestamp/);
  assert.throws(() => parseAgentEventLine("{broken"), /invalid JSON/);
});

test("schema parser bounds operator-controlled strings and data keys", () => {
  const data = {
    nested: { text: "n".repeat(2_000), deeper: { one: { two: { three: "hidden" } } } },
    ...Object.fromEntries(Array.from({ length: 79 }, (_, index) => [`key${index}`, index])),
  };
  const event = parseAgentEvent({ ...validEvent(), message: "x".repeat(2_000), data });
  assert.equal(event.message.length, 512);
  assert.equal(Object.keys(event.data).length, 50);
  const nested = event.data.nested as { text: string; deeper: unknown };
  assert.equal(nested.text.length, 512);
  assert.deepEqual(nested.deeper, { one: { two: "[TRUNCATED]" } });
});

test("schema parser removes terminal control characters from rendered strings", () => {
  const event = parseAgentEvent({
    agent: "reviewer",
    instanceId: "safe",
    processId: 1,
    timestamp: "2026-08-25T12:00:00Z",
    sequence: 1,
    eventType: "candidate.selected",
    level: "info",
    cycleNumber: 1,
    pullRequestId: 42,
    sourceCommit: "",
    data: { title: "safe\u001b[2Jtitle", outstanding: ["one\u0007two"] },
    message: "hello\u001b[31mred",
  });
  assert.equal(event.message, "hello [31mred");
  assert.equal(getString(event.data, "title"), "safe [2Jtitle");
  assert.deepEqual(getStringArray(event.data, "outstanding"), ["one two"]);
});

test("schema v3 requires verified canonical identity and preserves opaque GitHub IDs", () => {
  const repositoryId = "900719925474099312345";
  const event = parseAgentEvent({
    ...validEvent(),
    schemaVersion: 3,
    repositoryIdentity: {
      schemaVersion: 1,
      provider: "GitHub",
      repositoryId,
      organization: "contoso",
      project: "",
      repositoryName: "widget-service",
      slug: "contoso/widget-service",
      key: `v1:github:${repositoryId}`,
      verifiedAtUtc: "2026-09-03T00:00:00Z",
      verified: true,
      dispatchEligible: true,
    },
    dispatch: null,
  });
  assert.equal(event.repositoryIdentity?.repositoryId, repositoryId);
  assert.equal(event.repositoryIdentity?.key, `v1:github:${repositoryId}`);
  assert.equal(event.dispatch, null);

  assert.throws(() => parseAgentEvent({ ...validEvent(), schemaVersion: 3 }), /repositoryIdentity/);
  assert.throws(() => parseAgentEvent({
    ...validEvent(),
    schemaVersion: 3,
    repositoryIdentity: { ...event.repositoryIdentity, key: "v1:github:rounded" },
  }), /key/);
});

test("issue #105 PR4: dispatch.forceAnalysis parses both true and false and rejects non-booleans", () => {
  const dispatchId = "11111111-1111-4111-8111-111111111111";
  const forced = parseAgentEvent({
    ...validEvent(),
    dispatch: { schemaVersion: 1, dispatchId, ownership: "tui", forceAnalysis: true },
  });
  assert.equal(forced.dispatch?.forceAnalysis, true);

  const unforced = parseAgentEvent({
    ...validEvent(),
    dispatch: { schemaVersion: 1, dispatchId, ownership: "tui", forceAnalysis: false },
  });
  assert.equal(unforced.dispatch?.forceAnalysis, false);

  assert.throws(() => parseAgentEvent({
    ...validEvent(),
    dispatch: { schemaVersion: 1, dispatchId, ownership: "tui", forceAnalysis: "true" },
  }), /dispatch metadata/);
  assert.throws(() => parseAgentEvent({
    ...validEvent(),
    dispatch: { schemaVersion: 1, dispatchId, ownership: "tui" },
  }), /dispatch metadata/);
});
