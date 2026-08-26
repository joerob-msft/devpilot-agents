import assert from "node:assert/strict";
import test from "node:test";
import { parseAgentEvent } from "../src/domain.js";
import { eventNarrative, eventSummary } from "../src/format.js";

function namedEvent(eventType: string, data: Record<string, unknown> = {}, message = "") {
  return parseAgentEvent({
    schemaVersion: 2,
    agent: "reviewer",
    instanceId: "narrative",
    processId: 42,
    timestamp: "2026-08-25T12:00:00Z",
    sequence: 17,
    eventType,
    level: "info",
    cycleNumber: 2,
    pullRequestId: 94,
    sourceCommit: "",
    data,
    message,
  });
}

test("stable event names become concise narrative while raw summaries retain identity", () => {
  const selected = namedEvent("candidate.selected");
  assert.equal(eventNarrative(selected), "Pull request selected");
  assert.match(eventSummary(selected), /^candidate\.selected PR 94/);

  const phase = namedEvent("phase.changed", { phase: "running model review" });
  assert.equal(eventNarrative(phase), "Phase: running model review");
  assert.match(eventSummary(phase), /^phase\.changed PR 94 - running model review/);

  const completed = namedEvent("review.completed", { summary: "Three findings" });
  assert.equal(eventNarrative(completed), "Review completed - Three findings");
  assert.match(eventSummary(completed), /^review\.completed PR 94/);
});
