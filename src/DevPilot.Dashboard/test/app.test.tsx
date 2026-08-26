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
  let setup: TestRendererSetup;
  try {
    setup = await testRender(() => <App reducer={reducer} tailer={tailer} />, {
      width: 140,
      height: 30,
    });
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
    assert.match(wide, /DEVPILOT OPERATIONS/);
    assert.match(wide, /API Hub/);
    assert.match(wide, /BLOCKED/);
    assert.match(wide, /INSPECTOR/);
    setup.resize(70, 24);
    await setup.renderOnce();
    assert.match(setup.captureCharFrame(), /INSTANCES/);
  } finally {
    setup.renderer.destroy();
    await tailer.stop();
  }
});
