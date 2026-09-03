import assert from "node:assert/strict";
import test from "node:test";
import { parseAgentEvent } from "../src/domain.js";
import { eventNarrative, eventSummary } from "../src/format.js";
import { appendPromptScalar, dispatchResultDetail, promptScalarCount } from "../src/app.js";

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

  test("manual prompt counts Unicode scalars and bounds input at 512", () => {
    const atLimit = "😀".repeat(512);
    assert.equal(promptScalarCount(atLimit), 512);
    assert.equal(appendPromptScalar(atLimit, "x"), atLimit);
    assert.equal(appendPromptScalar("line one", "\n"), "line one\n");
    assert.equal(appendPromptScalar("safe", "\u001b"), "safe");
    assert.equal(appendPromptScalar("safe", "\ud800"), "safe");
    assert.equal(appendPromptScalar("safe", "😀"), "safe😀");
  });

  test("manual rejection details stay distinct and safe", () => {
    assert.match(dispatchResultDetail("source-changed"), /Source changed/);
    assert.match(dispatchResultDetail("policy-changed"), /capability policy changed/);
    assert.match(dispatchResultDetail("delivery-pending"), /delivery is pending/);
    assert.match(dispatchResultDetail("already-running", "state-contended"), /role state is busy/);
    assert.doesNotMatch(dispatchResultDetail("launch-failed", "bad\u001bdetail"), /\u001b/);
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
