import assert from "node:assert/strict";
import test from "node:test";
import { testRender } from "@opentui/solid";
import type { TestRendererSetup } from "@opentui/core/testing";
import { App, BRAND_PLANE, completionResultColor, safeHttpUrl } from "../src/app.js";
import { parseAgentEvent } from "../src/domain.js";
import { OperationsReducer } from "../src/reducer.js";
import { EventTailer } from "../src/tailer.js";

function createFixture(prUrl = "https://github.com/joerob-msft/devpilot-agents/pull/94"): {
  reducer: OperationsReducer;
  tailer: EventTailer;
} {
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
    sourceCommit: "1234567890abcdef",
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
    eventType: "cycle.started",
  }));
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 3,
    eventType: "candidates.enumerated",
    data: { scanned: 4, selected: 1, skipped: { draft: 2, old: 1 } },
  }));
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 4,
    eventType: "candidate.selected",
    pullRequestId: 16933452,
    data: {
      title: "Add deployment stage",
      author: "Ada",
      url: prUrl,
      sourceBranch: "feature/deploy",
      targetBranch: "main",
      threadCount: 12,
      actionableThreadCount: 4,
      changedFileCount: 7,
    },
  }));
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 5,
    eventType: "phase.changed",
    pullRequestId: 16933452,
    data: { phase: "running model review", elapsedMilliseconds: 2_000 },
  }));
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 6,
    eventType: "delivery.blocked",
    level: "warning",
    pullRequestId: 16933452,
    data: { reason: "Change set unavailable", outstanding: ["comments"], retryable: true, nextRetry: "next cycle" },
  }));
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 7,
    eventType: "work.completed",
    pullRequestId: 16933452,
    data: {
      result: "partially delivered",
      reason: "One capability unavailable",
      summary: "Review finished with bounded findings",
      critical: 1,
      important: 2,
      suggestion: 3,
      requested: ["summary", "comments"],
      delivered: ["summary"],
      previewArtifact: "review-preview.md",
      nextScan: "in 30s",
      elapsedMilliseconds: 7_500,
    },
  }));
  const tailer = new EventTailer({
    stateDirectories: [],
    eventLogPaths: [],
    onEvent: () => {},
    onDiagnostic: () => {},
  });
  return { reducer, tailer };
}

async function renderAt(
  context: Parameters<typeof test>[1] extends (context: infer T) => unknown ? T : never,
  setupList: TestRendererSetup[],
  width: number,
  height: number,
  openUrl?: (url: string) => void | Promise<void>,
  prUrl?: string,
): Promise<TestRendererSetup | null> {
  const fixture = createFixture(prUrl);
  try {
    const setup = await testRender(() => <App reducer={fixture.reducer} tailer={fixture.tailer} openUrl={openUrl} />, {
      width,
      height,
      kittyKeyboard: true,
    });
    setupList.push(setup);
    await setup.renderOnce();
    return setup;
  } catch (error) {
    await fixture.tailer.stop();
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return null;
    }
    throw error;
  }
}

test("brand plane rows share one centered monospace geometry", () => {
  assert.deepEqual(BRAND_PLANE, ["       __|__       ", "--o--o--(_)--o--o--"]);
  assert.equal(BRAND_PLANE[0].length, BRAND_PLANE[1].length);
  assert.equal(BRAND_PLANE[0].indexOf("|"), BRAND_PLANE[1].indexOf("_"));
  assert.equal(BRAND_PLANE[0].indexOf("|"), Math.floor(BRAND_PLANE[0].length / 2));
});

test("brand plane renders on one center column", async (context) => {
  const reducer = new OperationsReducer();
  const tailer = new EventTailer({
    stateDirectories: [],
    eventLogPaths: [],
    onEvent: () => {},
    onDiagnostic: () => {},
  });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await testRender(() => <App reducer={reducer} tailer={tailer} />, {
      width: 70,
      height: 24,
      kittyKeyboard: true,
    });
    await setup.renderOnce();
    const rows = setup.captureCharFrame().split("\n");
    const tail = rows.find((row) => row.includes("__|__"));
    const fuselage = rows.find((row) => row.includes("--o--o--(_)--o--o--"));
    assert.ok(tail);
    assert.ok(fuselage);
    assert.equal(tail.indexOf("|"), fuselage.indexOf("_"));
  } catch (error) {
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return;
    }
    throw error;
  } finally {
    setup?.renderer.destroy();
    await tailer.stop();
  }
});

test("URL validation only permits credential-free HTTP(S) URLs", () => {
  assert.equal(safeHttpUrl("https://github.com/org/repo/pull/1"), "https://github.com/org/repo/pull/1");
  assert.equal(safeHttpUrl("http://dev.azure.com/org/project/_git/repo/pullrequest/2"), "http://dev.azure.com/org/project/_git/repo/pullrequest/2");
  assert.equal(safeHttpUrl("javascript:alert(1)"), null);
  assert.equal(safeHttpUrl("file:///C:/secret"), null);
  assert.equal(safeHttpUrl("https://user:password@example.com/pr"), null);
  assert.equal(safeHttpUrl("not a URL"), null);
});

test("partial and failure result phrases retain semantic colors", () => {
  assert.equal(completionResultColor("partially delivered"), "#f0b45a");
  assert.equal(completionResultColor("delivery failed"), "#ff6b6b");
  assert.equal(completionResultColor("delivered"), "#61d6a7");
});

test("renderer geometry and narrative remain readable at 140, 100, and 70 columns", async (context) => {
  const setups: TestRendererSetup[] = [];
  try {
    const wideSetup = await renderAt(context, setups, 140, 32);
    if (!wideSetup) return;
    const wide = wideSetup.captureCharFrame();
    const wideLines = wide.split("\n");
    assert.match(wide, /DEVPILOT OPERATIONS/);
    assert.match(wide, /Live \/ blocked/);
    assert.match(wide, /CURRENT PHASE/);
    assert.match(wide, /MODEL ACTIVITY/);
    assert.match(wide, /CANDIDATE STORY/);
    assert.match(wide, /Ada \| feature\/deploy -> main/);
    assert.match(wide, /threads 4\/12 actionable \| files 7/);
    assert.match(wide, /END-OF-RUN SUMMARY/);
    assert.match(wide, /Requested: summary, comments \| Delivered: summary/);
    assert.match(wide, /Preview review-preview\.md \| Next in 30s/);
    assert.match(wide, /CURRENT-RUN TIMELINE/);
    assert.match(wide, /Delivery is blocked - Change set unavailable/);
    assert.doesNotMatch(wide, /agent\.heartbeat/);
    assert.equal(wideLines.some((row) => row.includes("CURRENT PHASE") && row.includes("running model review")), false);
    assert.equal(wideLines.some((row) => row.includes("END-OF-RUN SUMMARY") && row.includes("partially delivered |")), false);
    assert.equal(wideLines.some((row) => row.includes("BLOCKED:") && row.includes("Outstanding:")), false);

    const standardSetup = await renderAt(context, setups, 100, 30);
    assert.ok(standardSetup);
    const standard = standardSetup.captureCharFrame();
    assert.match(standard, /ALL \| STANDARD \| FOCUS RAIL/);
    assert.match(standard, /CURRENT PHASE/);
    assert.match(standard, /CURRENT-RUN TIMELINE/);
    assert.doesNotMatch(standard, /TIMELINEe/);

    const compactSetup = await renderAt(context, setups, 70, 24);
    assert.ok(compactSetup);
    const compact = compactSetup.captureCharFrame();
    assert.match(compact, /ALL \| COMPACT \| FOCUS RAIL/);
    assert.match(compact, /INSTANCES 1/);
    assert.match(compact, /Live 1  Completed 0  Stale 0/);
    assert.match(compact, /Enter detail/);
  } finally {
    for (const setup of setups.reverse()) setup.renderer.destroy();
  }
});

test("native keyboard controls provide contextual effects and feedback in every layout", async (context) => {
  const setups: TestRendererSetup[] = [];
  const opened: string[] = [];
  try {
    const wide = await renderAt(context, setups, 140, 32, (url) => opened.push(url));
    if (!wide) return;
    wide.mockInput.pressEnter();
    await wide.renderOnce();
    assert.match(wide.captureCharFrame(), /FOCUS DETAIL/);
    wide.mockInput.pressEnter();
    await wide.renderOnce();
    assert.match(wide.captureCharFrame(), /FOCUS TIMELINE/);
    wide.mockInput.pressEnter();
    await wide.renderOnce();
    assert.match(wide.captureCharFrame(), /STATUS: Timeline is already focused/);
    wide.mockInput.pressEscape();
    await wide.flush();
    assert.match(wide.captureCharFrame(), /FOCUS DETAIL/);
    wide.mockInput.pressKey("o");
    await wide.flush();
    assert.deepEqual(opened, ["https://github.com/joerob-msft/devpilot-agents/pull/94"]);
    assert.match(wide.captureCharFrame(), /STATUS: Opened validated PR URL/);
    wide.mockInput.pressKey("p", { ctrl: true });
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Command palette opened/);
    wide.mockInput.pressArrow("down");
    wide.mockInput.pressEnter();
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Live narrative is already focused/);
    wide.mockInput.pressEscape();
    await wide.flush();

    const standard = await renderAt(context, setups, 100, 30);
    assert.ok(standard);
    standard.mockInput.pressKey("i");
    await standard.renderOnce();
    assert.match(standard.captureCharFrame(), /INSPECTOR/);
    assert.match(standard.captureCharFrame(), /FOCUS INSPECTOR/);
    standard.mockInput.pressEscape();
    await standard.flush();
    assert.match(standard.captureCharFrame(), /FOCUS DETAIL/);

    const compact = await renderAt(context, setups, 70, 24);
    assert.ok(compact);
    compact.mockInput.pressKey("i");
    await compact.renderOnce();
    assert.match(compact.captureCharFrame(), /STATUS: Open detail before the compact inspector/);
    compact.mockInput.pressEnter();
    await compact.renderOnce();
    assert.match(compact.captureCharFrame(), /CURRENT PHASE/);
    assert.match(compact.captureCharFrame(), /FOCUS DETAIL/);
    compact.mockInput.pressEscape();
    await compact.flush();
    assert.match(compact.captureCharFrame(), /INSTANCES 1/);
    assert.match(compact.captureCharFrame(), /FOCUS RAIL/);
    compact.mockInput.pressEscape();
    await compact.flush();
    assert.match(compact.captureCharFrame(), /STATUS: Instance rail is already focused/);

    const missingUrl = await renderAt(context, setups, 70, 24, undefined, "");
    assert.ok(missingUrl);
    missingUrl.mockInput.pressKey("o");
    await missingUrl.renderOnce();
    assert.match(missingUrl.captureCharFrame(), /STATUS: PR URL is missing or unsupported/);
  } finally {
    for (const setup of setups.reverse()) setup.renderer.destroy();
  }
});
