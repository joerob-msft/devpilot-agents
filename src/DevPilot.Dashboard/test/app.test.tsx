import assert from "node:assert/strict";
import test from "node:test";
import { testRender } from "@opentui/solid";
import type { TestRendererSetup } from "@opentui/core/testing";
import { App } from "../src/app.js";
import { parseAgentEvent } from "../src/domain.js";
import { OperationsReducer } from "../src/reducer.js";
import { EventTailer } from "../src/tailer.js";

test("operations console renders through the OpenTUI Solid renderer", async (context) => {
  const reducer = new OperationsReducer();
  const base = {
    schemaVersion: 2,
    agent: "reviewer",
    instanceId: "render-instance",
    processId: 42,
    timestamp: "2026-08-25T12:00:00Z",
    level: "info",
    cycleNumber: 3,
    pullRequestId: 0,
    sourceCommit: "",
    data: {},
    message: "",
  } as const;
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 1,
    eventType: "agent.started",
    data: { repository: "API Hub", organization: "sample", project: "project", writes: "preview only" },
  }));
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 2,
    eventType: "candidate.selected",
    pullRequestId: 16933452,
    data: { title: "Add deployment stage" },
  }));
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 3,
    eventType: "delivery.blocked",
    level: "warning",
    pullRequestId: 16933452,
    data: { reason: "Change set unavailable", outstanding: ["summary"], retryable: true, nextRetry: "next cycle" },
  }));
  const tailer = new EventTailer({
    stateDirectories: [],
    eventLogPaths: [],
    onEvent: () => {},
    onDiagnostic: () => {},
  });
  const setups: TestRendererSetup[] = [];
  let setup: TestRendererSetup;
  try {
    setup = await testRender(() => <App reducer={reducer} tailer={tailer} />, {
      width: 140,
      height: 30,
    });
    setups.push(setup);
  } catch (error) {
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return;
    }
    throw error;
  }
  try {
    await setup.renderOnce();
    const wide = setup.captureCharFrame();
    const lines = wide.split("\n");
    assert.match(wide, /DEVPILOT OPERATIONS/);
    assert.match(wide, /API Hub/);
    assert.match(wide, /BLOCKED/);
    assert.match(wide, /INSPECTOR/);
    assert.match(wide, /CURRENT PHASE/);
    assert.match(wide, /COMPLETION \/ NEXT WAIT/);
    assert.match(wide, /work in progress/);
    assert.match(wide, /RECENT CYCLES/);
    assert.match(wide, /no completed cycles/);
    assert.match(wide, /TIMELINE \(latest\)/);
    assert.match(wide, /Next retry: next cycle/);
    assert.equal(lines.some((line) => line.includes("COMPLETION / NEXT WAIT") && line.includes("work in progress")), false);
    assert.equal(lines.some((line) => line.includes("RECENT CYCLES") && line.includes("no completed cycles")), false);
    assert.equal(lines.some((line) => line.includes("BLOCKED:") && line.includes("Outstanding:")), false);
    assert.equal(lines.some((line) => line.includes("Outstanding:") && line.includes("Next retry:")), false);
    const standardSetup = await testRender(() => <App reducer={reducer} tailer={tailer} />, {
      width: 100,
      height: 26,
    });
    setups.push(standardSetup);
    await standardSetup.renderOnce();
    const standard = standardSetup.captureCharFrame();
    assert.match(standard, /role: ALL \| STANDARD/);
    assert.match(standard, /COMPLETION \/ NEXT WAIT/);
    assert.match(standard, /RECENT CYCLES/);
    assert.doesNotMatch(standard, /TIMELINEe\(latest\)es/);

    const compactSetup = await testRender(() => <App reducer={reducer} tailer={tailer} />, {
      width: 70,
      height: 24,
    });
    setups.push(compactSetup);
    await compactSetup.renderOnce();
    const compact = compactSetup.captureCharFrame();
    assert.match(compact, /role: ALL \| COMPACT/);
    assert.match(compact, /INSTANCES/);
    assert.match(compact, /F0 B1 R0/);
    assert.match(compact, /Enter \| \? \| q/);
  } finally {
    for (const item of setups.reverse()) item.renderer.destroy();
    await tailer.stop();
  }
});
