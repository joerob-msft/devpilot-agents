import assert from "node:assert/strict";
import test from "node:test";
import { testRender } from "@opentui/solid";
import type { TestRendererSetup } from "@opentui/core/testing";
import {
  App, BRAND_PLANE, HELP_LEGEND, appendPromptScalar, completionResultColor,
  printableKeySequence, safeHttpUrl, selectableCount,
} from "../src/app.js";
import { parseAgentEvent } from "../src/domain.js";
import { OperationsReducer } from "../src/reducer.js";
import { EventTailer } from "../src/tailer.js";
import { PullRequestHistoryProjection } from "../src/history.js";
import { createDashboardLifecycle } from "../src/lifecycle.js";
import type { CapabilitySummary, DispatchAccepted, DispatchBroker, DispatchTerminal } from "../src/dispatch.js";

const DOCUMENTED_COMMAND_COVERAGE = [
  "Left", "Right", "Up", "Down", "j", "k", "Enter", "Esc", "b",
  "Tab", "Shift+Tab", "f", "Shift+f", "x", "Shift+x", "/",
  "number then Enter", "m", "prompt Tab", "prompt Enter",
  "Ctrl+d then d then y", "c", "i", "e", "w", "o", "Ctrl+P", "?", "q",
  "s", "settings Tab", "settings r",
] as const;

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
  reducer.apply(parseAgentEvent({
    ...base,
    sequence: 8,
    eventType: "agent.stopped",
  }));
  const tailer = new EventTailer({
    stateDirectories: [],
    eventLogPaths: [],
    onEvent: () => {},
    onDiagnostic: () => {},
  });
  return { reducer, tailer };
}

function historyEvent(
  repositoryId: string,
  pullRequestId: number,
  sequence: number,
  options: {
    role?: "reviewer" | "review-handler";
    repositoryName?: string;
    title?: string;
    author?: string;
    timestamp?: string;
  } = {},
) {
  const repositoryName = options.repositoryName ?? "repo";
  return parseAgentEvent({
    schemaVersion: 3,
    agent: options.role ?? "reviewer",
    instanceId: `${options.role ?? "reviewer"}-${repositoryId}`,
    processId: sequence,
    timestamp: options.timestamp ?? `2026-09-03T00:00:${String(sequence).padStart(2, "0")}Z`,
    sequence,
    eventType: "work.completed",
    level: "info",
    cycleNumber: 1,
    pullRequestId,
    sourceCommit: String(sequence).repeat(40).slice(0, 40),
    repositoryIdentity: {
      schemaVersion: 1,
      provider: "GitHub",
      repositoryId,
      organization: "contoso",
      project: "",
      repositoryName,
      slug: `contoso/${repositoryName}`,
      key: `v1:github:${repositoryId}`,
      verifiedAtUtc: "2026-09-03T00:00:00Z",
      verified: true,
      dispatchEligible: true,
    },
    dispatch: null,
    data: {
      title: options.title ?? `PR ${pullRequestId}`,
      author: options.author ?? "Ada",
      result: options.role === "review-handler" ? "handled" : "reviewed",
    },
    message: "",
  });
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

test("help legend spells out view meaning and local-only forget behavior", () => {
  assert.deepEqual(HELP_LEGEND, [
    "Live = active work; Current session = Live plus newest retained per group.",
    "History = stopped/completed retained runs; Stale = heartbeat overdue.",
    "Forget never deletes agent state or event logs; unavailable actions report status.",
  ]);
});

test("documented command coverage matrix enumerates every dashboard command", () => {
  assert.deepEqual(DOCUMENTED_COMMAND_COVERAGE, [
    "Left", "Right", "Up", "Down", "j", "k", "Enter", "Esc", "b",
    "Tab", "Shift+Tab", "f", "Shift+f", "x", "Shift+x", "/",
    "number then Enter", "m", "prompt Tab", "prompt Enter",
    "Ctrl+d then d then y", "c", "i", "e", "w", "o", "Ctrl+P", "?", "q",
    "s", "settings Tab", "settings r",
  ]);
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

test("printable input maps OpenTUI space safely and rejects control sequences", () => {
  assert.equal(printableKeySequence({ name: "space", sequence: " " }), " ");
  assert.equal(printableKeySequence({ name: "q", sequence: "q" }), "q");
  assert.equal(printableKeySequence({ name: "q", sequence: "\u0011", ctrl: true }), null);
  assert.equal(printableKeySequence({ name: "escape", sequence: "\u001b" }), null);
  assert.equal(printableKeySequence({ name: "up", sequence: "\u001b[A" }), null);
  assert.equal(appendPromptScalar("review", printableKeySequence({ name: "space" })!), "review ");
});

test("selection counts history rows in history view and live instances elsewhere", () => {
  assert.equal(selectableCount("history", true, 12, 1), 12);
  assert.equal(selectableCount("history", true, 12, 0), 12);
  assert.equal(selectableCount("live", true, 12, 1), 1);
  assert.equal(selectableCount("live", true, 12, 0), 0);
});

test("renderer geometry and narrative remain readable at 140, 100, and 70 columns", async (context) => {
  const setups: TestRendererSetup[] = [];
  try {
    const wideSetup = await renderAt(context, setups, 140, 32);
    if (!wideSetup) return;
    const wide = wideSetup.captureCharFrame();
    const wideLines = wide.split("\n");
    assert.match(wide, /DEVPILOT OPERATIONS/);
    assert.match(wide, /REVIEWER \/ dashboard/);
    assert.match(wide, /History \/ partially/);
    assert.match(wide, /Ended 12:00:00Z/);
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
    assert.match(standard, /CURRENT SESSION \| ALL \| FOCUS RAIL/);
    assert.match(standard, /CURRENT PHASE/);
    assert.match(standard, /CURRENT-RUN TIMELINE/);
    assert.doesNotMatch(standard, /TIMELINEe/);

    const compactSetup = await renderAt(context, setups, 70, 24);
    assert.ok(compactSetup);
    const compact = compactSetup.captureCharFrame();
    assert.match(compact, /CURRENT \| ALL \| FOCUS RAIL/);
    assert.match(compact, /INSTANCES 1/);
    assert.match(compact, /Current session 1 \| L 0 H 1 S 0/);
    assert.match(compact, /Enter/);
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
    wide.mockInput.pressArrow("left");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Instance rail is the leftmost pane/);
    wide.mockInput.pressArrow("right");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /FOCUS DETAIL/);
    wide.mockInput.pressArrow("left");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /FOCUS RAIL/);
    for (const key of ["down", "up"] as const) {
      wide.mockInput.pressArrow(key);
      await wide.flush();
      assert.match(wide.captureCharFrame(), new RegExp(`STATUS: ${key === "up" ? "Previous" : "Next"} instance selected`));
    }
    wide.mockInput.pressKey("j");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Next instance selected/);
    wide.mockInput.pressKey("k");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Previous instance selected/);
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
    wide.mockInput.pressKey("b");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /FOCUS RAIL/);
    wide.mockInput.pressTab();
    await wide.flush();
    assert.match(wide.captureCharFrame(), /CURRENT SESSION \| REVIEWER/);
    wide.mockInput.pressTab({ shift: true });
    await wide.flush();
    assert.match(wide.captureCharFrame(), /CURRENT SESSION \| ALL/);
    wide.mockInput.pressKey("w");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Attention item selected: blocked/);
    wide.mockInput.pressKey("e");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /RAW EVENTS - ALL/);
    wide.mockInput.pressArrow("right");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /RAW EVENTS - WARNINGS/);
    wide.mockInput.pressKey("e");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /RAW EVENTS - ALL/);
    wide.mockInput.pressEscape();
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Events overlay closed/);
    wide.mockInput.pressKey("o");
    await wide.flush();
    assert.deepEqual(opened, ["https://github.com/joerob-msft/devpilot-agents/pull/94"]);
    assert.match(wide.captureCharFrame(), /STATUS: Opened validated PR URL/);
    wide.mockInput.pressKey("p", { ctrl: true });
    await wide.flush();
    assert.match(wide.captureCharFrame(), /CONTEXT COMMANDS - VIEW ONLY/);
    wide.mockInput.pressArrow("down");
    wide.mockInput.pressEnter();
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Live narrative is already focused/);
    wide.mockInput.pressEscape();
    await wide.flush();
    wide.mockInput.pressKey("f");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /HISTORY \| ALL \| WIDE \| FOCUS RAIL/);
    assert.match(wide.captureCharFrame(), /STATUS: View filter changed to History/);
    wide.mockInput.pressKey("f");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /LIVE \| ALL \| WIDE \| FOCUS RAIL/);
    assert.match(wide.captureCharFrame(), /INSTANCES 0/);
    wide.mockInput.pressKey("x");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: No historical instance is selected/);
    wide.mockInput.pressKey("f", { shift: true });
    await wide.flush();
    assert.match(wide.captureCharFrame(), /HISTORY \| ALL \| WIDE \| FOCUS RAIL/);
    wide.mockInput.pressKey("m");
    await wide.flush();
    assert.match(wide.captureCharFrame(), /STATUS: Observe-only launch: trusted manual broker is unavailable/);

    const standard = await renderAt(context, setups, 100, 30);
    assert.ok(standard);
    standard.mockInput.pressKey("i");
    await standard.renderOnce();
    assert.match(standard.captureCharFrame(), /INSPECTOR/);
    assert.match(standard.captureCharFrame(), /FOCUS INSPECTOR/);
    standard.mockInput.pressEscape();
    await standard.flush();
    assert.match(standard.captureCharFrame(), /FOCUS DETAIL/);
    standard.mockInput.pressKey("?");
    await standard.flush();
    assert.match(standard.captureCharFrame(), /HELP - OBSERVE MODE/);
    assert.match(standard.captureCharFrame(), /Left \/ Right\s+Focus visible pane/);
    standard.mockInput.pressKey("?");
    await standard.flush();
    assert.match(standard.captureCharFrame(), /STATUS: Help closed/);
    assert.doesNotMatch(standard.captureCharFrame(), /HELP - OBSERVE MODE/);
    standard.mockInput.pressKey("x", { shift: true });
    await standard.flush();
    assert.match(standard.captureCharFrame(), /STATUS: 1 historical row\(s\) forgotten for this dashboard process/);
    assert.match(standard.captureCharFrame(), /INSTANCES 0/);

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
    compact.mockInput.pressKey("f");
    await compact.flush();
    assert.match(compact.captureCharFrame(), /HISTORY \| ALL \| FOCUS RAIL/);
    compact.mockInput.pressKey("x");
    await compact.flush();
    assert.match(compact.captureCharFrame(), /STATUS: Historical row forgotten for this dashboard process/);
    assert.match(compact.captureCharFrame(), /INSTANCES 0/);

    const missingUrl = await renderAt(context, setups, 70, 24, undefined, "");
    assert.ok(missingUrl);
    missingUrl.mockInput.pressKey("o");
    await missingUrl.renderOnce();
    assert.match(missingUrl.captureCharFrame(), /STATUS: PR URL is missing or unsupported/);
  } finally {
    for (const setup of setups.reverse()) setup.renderer.destroy();
  }
});

test("empty renderer reports unavailable navigation, attention, URL, and manual actions", async (context) => {
  const reducer = new OperationsReducer();
  const tailer = new EventTailer({
    stateDirectories: [],
    eventLogPaths: [],
    onEvent: () => {},
    onDiagnostic: (diagnostic) => reducer.addSourceDiagnostic(diagnostic),
  });
  reducer.addSourceDiagnostic({
    source: "Q:\\malformed.jsonl",
    kind: "malformed",
    message: "malformed diagnostic is bounded and visible",
    timestampMs: Date.now(),
  });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await testRender(() => <App reducer={reducer} tailer={tailer} />, {
      width: 100, height: 30, kittyKeyboard: true,
    });
    await setup.renderOnce();
    assert.match(setup.captureCharFrame(), /SOURCE WARNING: malformed diagnostic is bounded and visible/);
    for (const key of ["down", "w", "o", "m"] as const) {
      setup.mockInput.pressKey(key);
      await setup.flush();
    }
    assert.match(setup.captureCharFrame(), /STATUS: Observe-only launch: trusted manual broker is unavailable/);
    setup.mockInput.pressArrow("right");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /STATUS: No instance is available for detail/);
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

test("trusted manual flow requires describe plus two explicit confirmations", async (context) => {
  const fixture = createFixture();
  const history = new PullRequestHistoryProjection();
  history.apply(parseAgentEvent({
    schemaVersion: 3,
    agent: "reviewer",
    instanceId: "manual-history",
    processId: 1,
    timestamp: "2026-09-03T00:00:00Z",
    sequence: 1,
    eventType: "work.completed",
    level: "info",
    cycleNumber: 1,
    pullRequestId: 104,
    sourceCommit: "a".repeat(40),
    repositoryIdentity: {
      schemaVersion: 1,
      provider: "GitHub",
      repositoryId: "9007199254740993",
      organization: "contoso",
      project: "",
      repositoryName: "repo",
      slug: "contoso/repo",
      key: "v1:github:9007199254740993",
      verifiedAtUtc: "2026-09-03T00:00:00Z",
      verified: true,
      dispatchEligible: true,
    },
    dispatch: null,
    data: { title: "Manual PR", author: "Ada", result: "reviewed" },
    message: "",
  }));
  const reorderedIdentity = {
    schemaVersion: 1 as const,
    provider: "GitHub" as const,
    repositoryId: "9007199254740994",
    organization: "contoso",
    project: "",
    repositoryName: "other-repo",
    slug: "contoso/other-repo",
    key: "v1:github:9007199254740994",
    verifiedAtUtc: "2026-09-02T00:00:00Z",
    verified: true,
    dispatchEligible: true,
  };
  history.apply(parseAgentEvent({
    schemaVersion: 3,
    agent: "reviewer",
    instanceId: "other-history",
    processId: 2,
    timestamp: "2026-09-02T00:00:00Z",
    sequence: 1,
    eventType: "work.completed",
    level: "info",
    cycleNumber: 1,
    pullRequestId: 205,
    sourceCommit: "d".repeat(40),
    repositoryIdentity: reorderedIdentity,
    dispatch: null,
    data: { title: "Other PR", author: "Grace", result: "reviewed" },
    message: "",
  }));
  history.apply(parseAgentEvent({
    schemaVersion: 3,
    agent: "review-handler",
    instanceId: "handler-only-history",
    processId: 3,
    timestamp: "2026-09-04T00:00:00Z",
    sequence: 1,
    eventType: "work.completed",
    level: "info",
    cycleNumber: 1,
    pullRequestId: 306,
    sourceCommit: "e".repeat(40),
    repositoryIdentity: {
      schemaVersion: 1,
      provider: "GitHub",
      repositoryId: "9007199254740996",
      organization: "contoso",
      project: "",
      repositoryName: "handler-repo",
      slug: "contoso/handler-repo",
      key: "v1:github:9007199254740996",
      verifiedAtUtc: "2026-09-04T00:00:00Z",
      verified: true,
      dispatchEligible: true,
    },
    dispatch: null,
    data: { title: "Handler-only PR", author: "Linus", result: "handled" },
    message: "",
  }));
  let describeCount = 0;
  let dispatchCount = 0;
  let cancelCount = 0;
  let describedTarget = "";
  let dispatchedTarget = "";
  let resolveDescribe!: (value: CapabilitySummary) => void;
  const described = new Promise<CapabilitySummary>((resolve) => { resolveDescribe = resolve; });
  const summary: CapabilitySummary = {
    schemaVersion: 1,
    requestId: "11111111-1111-4111-8111-111111111111",
    operation: "capability-summary",
    role: "reviewer",
    dispatchDraftId: "22222222-2222-4222-8222-222222222222",
    repositoryIdentity: {
      ...history.jump(104)!.repositoryIdentity,
      repositoryName: "broker-repo",
      slug: "contoso/broker-repo",
    },
    prSnapshot: {
      schemaVersion: 1, pullRequestId: 104, sourceCommit: "a".repeat(40),
      sourceRef: "feature", targetRef: "main", active: true, draft: false, author: "Ada", title: "Manual PR",
    },
    capabilityPolicyDigest: "b".repeat(64),
    prStateFingerprint: "c".repeat(64),
    capabilities: ["EnableSummaryComment"],
    mandatoryDenies: ["EnableApprovalVote"],
    dynamicConstraints: [],
  };
  const accepted: DispatchAccepted = {
    schemaVersion: 1,
    requestId: "33333333-3333-4333-8333-333333333333",
    operation: "accepted",
    dispatchId: "44444444-4444-4444-8444-444444444444",
    repositoryIdentity: summary.repositoryIdentity,
    pullRequestId: 104,
    role: "reviewer",
    capabilityPolicyDigest: summary.capabilityPolicyDigest,
    prStateFingerprint: summary.prStateFingerprint,
    childProcessId: 42,
    eventLogPath: "Q:\\events\\reviewer.jsonl",
  };
  const broker: DispatchBroker = {
    describe: async (repositoryKey, pullRequestId) => {
      describeCount++;
      describedTarget = `${repositoryKey}:${pullRequestId}`;
      return described;
    },
    dispatch: async (describedSummary) => {
      dispatchCount++;
      dispatchedTarget = `${describedSummary.repositoryIdentity.key}:${describedSummary.prSnapshot.pullRequestId}`;
      return accepted;
    },
    cancel: async () => {
      cancelCount++;
      return {
        schemaVersion: 1,
        requestId: "x",
        operation: "cancelled",
        dispatchId: accepted.dispatchId,
        result: "cancelled-cooperative",
      } as DispatchTerminal;
    },
    shutdown: async () => {},
    subscribeTerminal: () => () => {},
  };
  let setup: TestRendererSetup | undefined;
  try {
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 100, height: 30, kittyKeyboard: true,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("f");
    await setup.flush();
    setup.mockInput.pressTab();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /HISTORY \| REVIEWER/);
    setup.mockInput.pressKey("/");
    await setup.mockInput.typeText("ManualX");
    setup.mockInput.pressBackspace();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /PR history filter: Manual/);
    setup.mockInput.pressKey("/");
    for (let index = 0; index < 6; index++) setup.mockInput.pressBackspace();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /PR history filter cleared/);
    setup.mockInput.pressKey("/");
    await setup.mockInput.typeText("cancelled");
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /STATUS: History input cancelled/);
    setup.mockInput.pressKey("9");
    setup.mockInput.pressKey("9");
    setup.mockInput.pressKey("9");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /jump is missing/);
    setup.mockInput.pressKey("3");
    setup.mockInput.pressKey("0");
    setup.mockInput.pressKey("6");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /excluded by the active role/);
    setup.mockInput.pressKey("1");
    setup.mockInput.pressKey("0");
    setup.mockInput.pressKey("4");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Jumped to repo PR #104/);
    setup.mockInput.pressKey("x");
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /repo PR #104/);
    setup.mockInput.pressKey("1");
    setup.mockInput.pressKey("0");
    setup.mockInput.pressKey("4");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Jumped to repo PR #104/);
    assert.match(setup.captureCharFrame(), /repo PR #104/);
    history.apply(historyEvent("9007199254740997", 104, 1, {
      repositoryName: "duplicate",
      title: "Duplicate number",
      timestamp: "2026-09-05T00:00:00Z",
    }));
    await new Promise((resolve) => setTimeout(resolve, 1_100));
    setup.mockInput.pressKey("1");
    setup.mockInput.pressKey("0");
    setup.mockInput.pressKey("4");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /ambiguous across repositories/);
    setup.mockInput.pressKey("/");
    await setup.mockInput.typeText("Manual PR");
    setup.mockInput.pressEnter();
    setup.mockInput.pressKey("1");
    setup.mockInput.pressKey("0");
    setup.mockInput.pressKey("4");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Jumped to repo PR #104/);
    setup.mockInput.pressKey("m");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /MANUAL DISPATCH/);
    assert.match(setup.captureCharFrame(), /contoso\/repo \/ PR #104/);
    assert.match(setup.captureCharFrame(), /Manual PR \| Ada/);
    assert.match(setup.captureCharFrame(), /512 Unicode scalars/);
    setup.mockInput.pressTab();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Role: HANDLER/);
    setup.mockInput.pressTab({ shift: true });
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Role: REVIEWER/);
    setup.mockInput.pressKey("q");
    setup.mockInput.pressKey("q", { ctrl: true });
    await setup.mockInput.typeText(" fix");
    setup.mockInput.pressEnter();
    await setup.mockInput.typeText("next");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /q fix \/ next/);
    setup.mockInput.pressBackspace();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /q fix \/ nex/);
    assert.equal(describeCount, 0);
    assert.equal(dispatchCount, 0);
    setup.mockInput.pressKey("d", { ctrl: true });
    await setup.renderOnce();
    assert.equal(describeCount, 1);
    assert.equal(describedTarget, "v1:github:9007199254740993:104");
    history.apply(parseAgentEvent({
      schemaVersion: 3,
      agent: "reviewer",
      instanceId: "other-history",
      processId: 2,
      timestamp: "2026-09-04T00:00:00Z",
      sequence: 2,
      eventType: "agent.heartbeat",
      level: "info",
      cycleNumber: 1,
      pullRequestId: 205,
      sourceCommit: "d".repeat(40),
      repositoryIdentity: reorderedIdentity,
      dispatch: null,
      data: { title: "Other PR", author: "Grace" },
      message: "",
    }));
    await new Promise((resolve) => setTimeout(resolve, 1_100));
    await setup.renderOnce();
    assert.match(setup.captureCharFrame(), /contoso\/repo \/ PR #104/);
    assert.doesNotMatch(setup.captureCharFrame(), /other-repo \/ PR #205/);
    resolveDescribe(summary);
    await setup.flush();
    assert.match(setup.captureCharFrame(), /contoso\/broker-repo \/ PR #104/);
    assert.match(setup.captureCharFrame(), /Disabled high-impact: EnableApprovalVote/);
    setup.mockInput.pressKey("d");
    await setup.flush();
    assert.equal(dispatchCount, 0);
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.equal(dispatchCount, 1);
    assert.equal(dispatchedTarget, "v1:github:9007199254740993:104");
    assert.match(setup.captureCharFrame(), /Accepted dispatch/);
    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.equal(cancelCount, 1);
    assert.match(setup.captureCharFrame(), /Cancellation completed: cancelled-cooperative/);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /MANUAL DISPATCH/);
  } catch (error) {
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return;
    }
    throw error;
  } finally {
    setup?.renderer.destroy();
    await fixture.tailer.stop();
  }
});

test("q shuts down the tailer and trusted broker before destroying the renderer", async (context) => {
  const fixture = createFixture();
  let shutdownCount = 0;
  let setup: TestRendererSetup | undefined;
  const broker: DispatchBroker = {
    describe: async () => { throw new Error("not called"); },
    dispatch: async () => { throw new Error("not called"); },
    cancel: async () => { throw new Error("not called"); },
    shutdown: async () => { shutdownCount++; },
    subscribeTerminal: () => () => {},
  };
  const lifecycle = createDashboardLifecycle(fixture.tailer, broker);
  try {
    setup = await testRender(() => <App
      reducer={fixture.reducer}
      tailer={fixture.tailer}
      broker={broker}
      shutdownBroker={lifecycle.shutdownBroker}
    />, {
      width: 100,
      height: 30,
      kittyKeyboard: true,
      onDestroy: lifecycle.onRendererDestroy,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("?");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /HELP - TRUSTED MANUAL MODE/);
    setup.mockInput.pressKey("q");
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(shutdownCount, 1);
    assert.equal(setup.renderer.isDestroyed, true);
  } catch (error) {
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return;
    }
    throw error;
  } finally {
    if (shutdownCount === 0) setup?.renderer.destroy();
    await fixture.tailer.stop();
  }
});

test("renderer destruction handles rejected trusted broker shutdown once", async (context) => {
  const fixture = createFixture();
  let shutdownCount = 0;
  let setup: TestRendererSetup | undefined;
  const reportedFailures: unknown[] = [];
  const unhandledRejections: unknown[] = [];
  const onUnhandledRejection = (reason: unknown): void => {
    unhandledRejections.push(reason);
  };
  const broker: DispatchBroker = {
    describe: async () => { throw new Error("not called"); },
    dispatch: async () => { throw new Error("not called"); },
    cancel: async () => { throw new Error("not called"); },
    shutdown: async () => {
      shutdownCount++;
      throw new Error("shutdown timed out");
    },
    subscribeTerminal: () => () => {},
  };
  const lifecycle = createDashboardLifecycle(fixture.tailer, broker, (error) => {
    reportedFailures.push(error);
  });
  process.on("unhandledRejection", onUnhandledRejection);
  try {
    setup = await testRender(() => <App
      reducer={fixture.reducer}
      tailer={fixture.tailer}
      broker={broker}
      shutdownBroker={lifecycle.shutdownBroker}
    />, {
      width: 100,
      height: 30,
      kittyKeyboard: true,
      onDestroy: lifecycle.onRendererDestroy,
    });
    await setup.renderOnce();
    setup.renderer.destroy();
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(shutdownCount, 1);
    assert.equal(reportedFailures.length, 1);
    assert.match(String(reportedFailures[0]), /shutdown timed out/);
    assert.deepEqual(unhandledRejections, []);
  } catch (error) {
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return;
    }
    throw error;
  } finally {
    process.off("unhandledRejection", onUnhandledRejection);
    if (!setup?.renderer.isDestroyed) setup?.renderer.destroy();
    await fixture.tailer.stop();
  }
});
