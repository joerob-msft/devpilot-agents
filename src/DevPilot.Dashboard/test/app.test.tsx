import assert from "node:assert/strict";
import { join } from "node:path";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import test, { type TestContext } from "node:test";
import { testRender } from "@opentui/solid";
import { BoxRenderable } from "@opentui/core";
import type { TestRendererSetup } from "@opentui/core/testing";
import {
  App, BRAND_PLANE, HELP_LEGEND, appendPromptScalar, completionResultColor,
  printableKeySequence, safeHttpUrl, selectableCount, parseManualPullRequestId,
  type AppProps,
} from "../src/app.js";
import { parseAgentEvent, type AgentRole, type AgentEvent } from "../src/domain.js";
import { selectionWindow, simpleCapability, simpleInstanceRow, automationStatusText, scanNowResultText } from "../src/simple-view.js";
import { OperationsReducer } from "../src/reducer.js";
import { EventTailer } from "../src/tailer.js";
import { PullRequestHistoryProjection } from "../src/history.js";
import { createDashboardLifecycle } from "../src/lifecycle.js";
import type {
  AutomationStatus,
  ScanNowResult,
  CapabilityNarrowingApplied,
  CapabilityNarrowingPreview,
  CapabilityProfile,
  CapabilityProvenance,
  CapabilitySummary,
  DispatchAccepted,
  DispatchBroker,
  DispatchTerminal,
  KillSwitchApplied,
  NarrowingAction,
  NarrowingScope,
  RunPrepared,
  RunQueued,
  RunProgress,
  ScheduledDispatchAccepted,
  WideningCancelled,
  WideningMinted,
  WideningPreview,
  WideningSummary,
} from "../src/dispatch.js";
import { BrokerRejectionError } from "../src/dispatch.js";
import { FileDismissalStorage, type DismissalStorage } from "../src/dismissals.js";

const DOCUMENTED_COMMAND_COVERAGE = [
  "Left", "Right", "Up", "Down", "j", "k", "Enter", "Esc", "b",
  "Tab", "Shift+Tab", "f", "Shift+f", "l", "Delete", "Shift+Delete", "x", "Shift+x", "/",
  "number then Enter", "m", "target Tab", "target Enter", "preview p", "prompt Enter",
  "Enter preview then Enter start", "Shift+Enter newline", "c", "i", "e", "w", "o", "Ctrl+P", "?", "q",
  "s", "settings Tab", "settings r",
] as const;

async function renderAdvanced(...args: Parameters<typeof testRender>): ReturnType<typeof testRender> {
  const setup = await testRender(...args);
  await setup.renderOnce();
  setup.mockInput.pressKey("a");
  await setup.flush();
  return setup;
}

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
    const setup = await renderAdvanced(() => <App reducer={fixture.reducer} tailer={fixture.tailer} openUrl={openUrl} />, {
      width,
      height,
      kittyKeyboard: true,
    });
    setupList.push(setup);
    await setup.renderOnce();
    setup.mockInput.pressKey("l"); // This fixture exercises retained end-of-run narrative, not the default Live view.
    await setup.flush();
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

function createSettingsHistory(): PullRequestHistoryProjection {
  const history = new PullRequestHistoryProjection();
  history.apply(historyEvent("9007199254740993", 104, 1, {
    repositoryName: "repo",
    title: "Settings PR",
    author: "Ada",
  }));
  return history;
}

type NarrowingCall =
  | { operation: "profile"; repositoryKey: string; pullRequestId: number; role: AgentRole }
  | { operation: "preview-narrowing"; repositoryKey: string; pullRequestId: number; role: AgentRole; scope: NarrowingScope; capability: string; action: NarrowingAction }
  | { operation: "apply-narrowing"; repositoryKey: string; pullRequestId: number; role: AgentRole; scope: NarrowingScope; capability: string; action: NarrowingAction; previewToken: string; storeFingerprint: string }
  | { operation: "set-kill-switch"; repositoryKey: string; role: AgentRole; enabled: boolean }
  | { operation: "shutdown" };

function createSettingsBrokerFixture(): {
  broker: DispatchBroker;
  calls: NarrowingCall[];
  // Test-only levers (point 6/10 coverage): forceKillSwitchRejection simulates the kill switch
  // becoming active concurrently with an in-flight preview/apply (broker rejects with the
  // distinct narrowing-kill-switch-active code); setKillSwitchTtlMinutes controls the TTL the next
  // set-kill-switch response reports via killSwitchExpiresAtUtc.
  forceKillSwitchRejection: (value: boolean) => void;
  setKillSwitchTtlMinutes: (minutes: number) => void;
} {
  const calls: NarrowingCall[] = [];
  const repositoryKey = "v1:github:9007199254740993";
  const repositoryIdentity = {
    schemaVersion: 1 as const,
    provider: "GitHub" as const,
    repositoryId: "9007199254740993",
    organization: "contoso",
    project: "",
    repositoryName: "repo",
    slug: "contoso/repo",
    key: repositoryKey,
    verifiedAtUtc: "2026-09-03T00:00:00Z",
    verified: true,
    dispatchEligible: true,
  };
  const prSnapshot = {
    schemaVersion: 1 as const,
    pullRequestId: 104,
    sourceCommit: "a".repeat(40),
    sourceRef: "feature",
    targetRef: "main",
    active: true,
    draft: false,
    author: "Ada",
    title: "Settings PR",
  };
  const allowedManualCapabilities = ["EnableFindingComments", "EnableSummaryComment", "EnableThreadReplies"];
  const absoluteDenies = ["EnableApprovalVote"];
  const baseProvenance: Record<string, CapabilityProvenance> = {
    EnableFindingComments: "repo-worktree",
    EnableSummaryComment: "machine",
    EnableThreadReplies: "user",
    EnableApprovalVote: "operational-default",
  };
  const state = {
    killSwitchActive: false,
    killSwitchExpiresAtUtc: null as string | null,
    enabled: new Set(["EnableSummaryComment", "EnableThreadReplies"]),
    mandatoryDenies: new Set(["EnableFindingComments", "EnableApprovalVote"]),
  };
  let killSwitchTtlMinutes = 60;
  let rejectWithKillSwitchActive = false;

  function effect(): CapabilityNarrowingPreview["current"] {
    const provenance: Record<string, CapabilityProvenance> = Object.create(null);
    for (const capability of [...allowedManualCapabilities, ...absoluteDenies]) {
      provenance[capability] = state.killSwitchActive ? "kill-switch" : baseProvenance[capability]!;
    }
    return {
      capabilities: [...state.enabled],
      mandatoryDenies: [...state.mandatoryDenies],
      provenance,
    };
  }

  function previewEffect(action: NarrowingAction, capability: string): CapabilityNarrowingPreview["proposed"] {
    const enabled = new Set(state.enabled);
    const mandatoryDenies = new Set(state.mandatoryDenies);
    if (action === "off") {
      enabled.delete(capability);
      mandatoryDenies.add(capability);
    } else {
      enabled.add(capability);
      mandatoryDenies.delete(capability);
    }
    const provenance: Record<string, CapabilityProvenance> = Object.create(null);
    for (const entry of [...allowedManualCapabilities, ...absoluteDenies]) {
      provenance[entry] = state.killSwitchActive ? "kill-switch" : baseProvenance[entry]!;
    }
    return {
      capabilities: [...enabled],
      mandatoryDenies: [...mandatoryDenies],
      provenance,
    };
  }

  function profile(role: AgentRole): CapabilityProfile {
    calls.push({ operation: "profile", repositoryKey, pullRequestId: prSnapshot.pullRequestId, role });
    return {
      schemaVersion: 1,
      requestId: `profile-${calls.length}`,
      operation: "capability-profile",
      role,
      repositoryIdentity,
      prSnapshot,
      capabilities: [...state.enabled],
      mandatoryDenies: [...state.mandatoryDenies],
      dynamicConstraints: [],
      absoluteDenies,
      allowedManualCapabilities,
      delegableAvailable: [],
      provenance: effect().provenance,
      killSwitchActive: state.killSwitchActive,
      killSwitchExpiresAtUtc: state.killSwitchExpiresAtUtc,
      editingAvailable: true,
    };
  }

  const broker: DispatchBroker = {
    describe: async () => { throw new Error("not called"); },
    profileCurrent: async () => { throw new Error("not called"); },
    profile: async (_repositoryKey, pullRequestId, role) => {
      if (pullRequestId !== prSnapshot.pullRequestId) throw new Error("unexpected pullRequestId");
      return profile(role);
    },
    previewNarrowing: async (_repositoryKey, pullRequestId, role, scope, capability, action) => {
      if (pullRequestId !== prSnapshot.pullRequestId) throw new Error("unexpected pullRequestId");
      if (rejectWithKillSwitchActive) {
        throw new BrokerRejectionError("narrowing-kill-switch-active", "kill switch is active");
      }
      calls.push({ operation: "preview-narrowing", repositoryKey, pullRequestId, role, scope, capability, action });
      const current = effect();
      return {
        schemaVersion: 1,
        requestId: `preview-${calls.length}`,
        operation: "narrowing-preview",
        state: "previewed",
        role,
        repositoryIdentity,
        prSnapshot,
        scope,
        capability,
        action,
        previewToken: `preview-${scope}-${capability}-${action}`,
        storeFingerprint: `store-${state.killSwitchActive ? "kill-switch" : "normal"}`,
        expiresAtUtc: "2026-09-03T16:00:00Z",
        killSwitchActive: state.killSwitchActive,
        changed: JSON.stringify(current) !== JSON.stringify(previewEffect(action, capability)),
        current,
        proposed: previewEffect(action, capability),
      };
    },
    applyNarrowing: async (preview, _repositoryKey, pullRequestId) => {
      if (pullRequestId !== prSnapshot.pullRequestId) throw new Error("unexpected pullRequestId");
      if (rejectWithKillSwitchActive) {
        throw new BrokerRejectionError("narrowing-kill-switch-active", "kill switch is active");
      }
      calls.push({
        operation: "apply-narrowing",
        repositoryKey,
        pullRequestId,
        role: preview.role,
        scope: preview.scope,
        capability: preview.capability,
        action: preview.action,
        previewToken: preview.previewToken,
        storeFingerprint: preview.storeFingerprint,
      });
      if (preview.action === "off") {
        state.enabled.delete(preview.capability);
        state.mandatoryDenies.add(preview.capability);
      } else {
        state.enabled.add(preview.capability);
        state.mandatoryDenies.delete(preview.capability);
      }
      const applied: CapabilityNarrowingApplied = {
        schemaVersion: 1,
        requestId: `apply-${calls.length}`,
        operation: "narrowing-applied",
        state: "applied",
        role: preview.role,
        scope: preview.scope,
        capability: preview.capability,
        action: preview.action,
        previewToken: preview.previewToken,
      };
      return applied;
    },
    setKillSwitch: async (_repositoryKey, role, enabled) => {
      calls.push({ operation: "set-kill-switch", repositoryKey, role, enabled });
      state.killSwitchActive = enabled;
      state.killSwitchExpiresAtUtc = enabled
        ? new Date(Date.now() + killSwitchTtlMinutes * 60_000).toISOString()
        : null;
      const applied: KillSwitchApplied = {
        schemaVersion: 1,
        requestId: `kill-switch-${calls.length}`,
        operation: "kill-switch-applied",
        role,
        enabled,
        killSwitchExpiresAtUtc: state.killSwitchExpiresAtUtc,
      };
      return applied;
    },
    dispatch: async () => { throw new Error("not called"); },
    cancel: async () => { throw new Error("not called"); },
    shutdown: async () => {
      calls.push({ operation: "shutdown" });
    },
    subscribeTerminal: () => () => {},
  };

  return {
    broker,
    calls,
    forceKillSwitchRejection: (value: boolean) => { rejectWithKillSwitchActive = value; },
    setKillSwitchTtlMinutes: (minutes: number) => { killSwitchTtlMinutes = minutes; },
  };
}

test("brand plane rows share one centered monospace geometry", () => {
  assert.deepEqual(BRAND_PLANE, ["       __|__       ", "--o--o--(_)--o--o--"]);
  assert.equal(BRAND_PLANE[0].length, BRAND_PLANE[1].length);
  assert.equal(BRAND_PLANE[0].indexOf("|"), BRAND_PLANE[1].indexOf("_"));
  assert.equal(BRAND_PLANE[0].indexOf("|"), Math.floor(BRAND_PLANE[0].length / 2));
});

test("help legend spells out Live only, persistent dismissal, and preserved logs", () => {
  assert.deepEqual(HELP_LEGEND, [
    "Live only = recent heartbeats, including waiting agents; l toggles Current.",
    "History includes observed exits; Stale alone never proves process exit.",
    "Delete remembers dismissal; new heartbeats restore it. Logs/state are untouched.",
  ]);
});

test("documented command coverage matrix enumerates every dashboard command", () => {
  assert.deepEqual(DOCUMENTED_COMMAND_COVERAGE, [
    "Left", "Right", "Up", "Down", "j", "k", "Enter", "Esc", "b",
    "Tab", "Shift+Tab", "f", "Shift+f", "l", "Delete", "Shift+Delete", "x", "Shift+x", "/",
    "number then Enter", "m", "target Tab", "target Enter", "preview p", "prompt Enter",
    "Enter preview then Enter start", "Shift+Enter newline", "c", "i", "e", "w", "o", "Ctrl+P", "?", "q",
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
    setup = await renderAdvanced(() => <App reducer={reducer} tailer={tailer} />, {
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
    assert.match(compact, /Current session 1/);
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
    assert.match(wide.captureCharFrame(), /DASHBOARD COMMANDS/);
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
    assert.match(wide.captureCharFrame(), /LIVE ONLY \| ALL \| WIDE \| FOCUS RAIL/);
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
    setup = await renderAdvanced(() => <App reducer={reducer} tailer={tailer} />, {
      width: 140, height: 32, kittyKeyboard: true,
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

test("history refresh during filter input updates reordered rows without OpenTUI warnings", async (context) => {
  const fixture = createFixture();
  const history = new PullRequestHistoryProjection();
  for (let index = 1; index <= 29; index++) {
    history.apply(historyEvent(
      `900719925474${String(index).padStart(4, "0")}`,
      100 + index,
      index,
      {
        title: `Retained pull request ${index}`,
        timestamp: `2026-09-03T00:00:${String(index).padStart(2, "0")}Z`,
      },
    ));
  }
  const warnings: string[] = [];
  const originalWarn = console.warn;
  let setup: TestRendererSetup | undefined;
  console.warn = (...values: unknown[]) => {
    warnings.push(values.map(String).join(" "));
  };
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} />, {
      width: 140,
      height: 32,
      kittyKeyboard: true,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("f", { shift: true });
    await setup.flush();
    for (let index = 0; index < 28; index++) setup.mockInput.pressArrow("down");
    await setup.flush();
    setup.mockInput.pressKey("/");
    history.apply(historyEvent("9007199254740001", 101, 30, {
      title: "Matching retained pull request",
      timestamp: "2026-09-03T00:01:00Z",
    }));
    await new Promise((resolve) => setTimeout(resolve, 1_100));
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Matching retained pull request/);
    assert.deepEqual(warnings.filter((warning) => warning.includes("insertBefore")), []);
  } catch (error) {
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return;
    }
    throw error;
  } finally {
    console.warn = originalWarn;
    setup?.renderer.destroy();
    await fixture.tailer.stop();
  }
});

test("settings overlay reports an explicit unavailable state without a trusted broker", async (context) => {
  const fixture = createFixture();
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} tailer={fixture.tailer} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("s");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EFFECTIVE CAPABILITY PROFILE/);
    assert.match(setup.captureCharFrame(), /Applies only to the next manual dispatch/);
    assert.match(setup.captureCharFrame(), /A running agent's own profile is immutable and is not shown here\./);
    assert.match(setup.captureCharFrame(), /Unavailable: trusted manual broker is not connected \(observe-only mode\)\./);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /SETTINGS - EFFECTIVE CAPABILITY PROFILE/);
    assert.match(setup.captureCharFrame(), /STATUS: Effective profile settings closed/);
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

test("settings overlay renders every known capability provenance value", async (context) => {
  const fixture = createFixture();
  const history = new PullRequestHistoryProjection();
  history.apply(historyEvent("9007199254740993", 104, 1, { title: "Provenance PR", author: "Ada" }));
  const repositoryIdentity = {
    schemaVersion: 1 as const,
    provider: "GitHub" as const,
    repositoryId: "9007199254740993",
    organization: "contoso",
    project: "",
    repositoryName: "repo",
    slug: "contoso/repo",
    key: "v1:github:9007199254740993",
    verifiedAtUtc: "2026-09-03T00:00:00Z",
    verified: true,
    dispatchEligible: true,
  };
  const prSnapshot = {
    schemaVersion: 1 as const,
    pullRequestId: 104,
    sourceCommit: "a".repeat(40),
    sourceRef: "feature",
    targetRef: "main",
    active: true,
    draft: false,
    author: "Ada",
    title: "Provenance PR",
  };
  function profileWith(provenance: CapabilityProfile["provenance"]): CapabilityProfile {
    return {
      schemaVersion: 1,
      requestId: "provenance-request",
      operation: "capability-profile",
      role: "reviewer",
      repositoryIdentity,
      prSnapshot,
      capabilities: Object.keys(provenance),
      mandatoryDenies: [],
      dynamicConstraints: [],
      absoluteDenies: [],
      allowedManualCapabilities: Object.keys(provenance),
      delegableAvailable: [],
      provenance,
      killSwitchActive: false,
      killSwitchExpiresAtUtc: null,
      editingAvailable: true,
    };
  }
  let profileCallCount = 0;
  const broker: DispatchBroker = {
    describe: async () => { throw new Error("not called"); },
    profileCurrent: async () => { throw new Error("not called"); },
    profile: async () => {
      profileCallCount++;
      // The SETTINGS overlay's Provenance line is a fixed-width, non-wrapping single row, so all
      // five KNOWN_PROVENANCE values (issue #105 PR2 review) can't be proven visible at once
      // without risking clipping. Two short, comfortably-fitting batches still exercise every
      // value through the real renderer instead of only the parser.
      return profileCallCount === 1
        ? profileWith({ a: "operational-default", b: "machine", c: "user" })
        : profileWith({ d: "repo-worktree", e: "pr" });
    },
    dispatch: async () => { throw new Error("not called"); },
    cancel: async () => { throw new Error("not called"); },
    shutdown: async () => {},
    subscribeTerminal: () => () => {},
  };
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("s");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EFFECTIVE CAPABILITY PROFILE/);
    assert.match(setup.captureCharFrame(), /a=operational-default/);
    assert.match(setup.captureCharFrame(), /b=machine/);
    assert.match(setup.captureCharFrame(), /c=user/);

    setup.mockInput.pressKey("r");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /d=repo-worktree/);
    assert.match(setup.captureCharFrame(), /e=pr/);
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

test("settings role toggle refetches without ever pairing a role label with another role's profile body", async (context) => {
  const fixture = createFixture();
  const history = new PullRequestHistoryProjection();
  history.apply(historyEvent("9007199254740993", 104, 1, { title: "Settings PR", author: "Ada" }));
  const repositoryIdentity = {
    schemaVersion: 1 as const,
    provider: "GitHub" as const,
    repositoryId: "9007199254740993",
    organization: "contoso",
    project: "",
    repositoryName: "repo",
    slug: "contoso/repo",
    key: "v1:github:9007199254740993",
    verifiedAtUtc: "2026-09-03T00:00:00Z",
    verified: true,
    dispatchEligible: true,
  };
  const prSnapshot = {
    schemaVersion: 1 as const,
    pullRequestId: 104,
    sourceCommit: "a".repeat(40),
    sourceRef: "feature",
    targetRef: "main",
    active: true,
    draft: false,
    author: "Ada",
    title: "Settings PR",
  };
  const profileCalls: AgentRole[] = [];
  let resolveReviewer!: (value: CapabilityProfile) => void;
  let resolveHandler!: (value: CapabilityProfile) => void;
  const reviewerPending = new Promise<CapabilityProfile>((resolve) => { resolveReviewer = resolve; });
  const handlerPending = new Promise<CapabilityProfile>((resolve) => { resolveHandler = resolve; });
  function profileFor(role: AgentRole, tag: string): CapabilityProfile {
    return {
      schemaVersion: 1,
      requestId: `${tag}-request`,
      operation: "capability-profile",
      role,
      repositoryIdentity,
      prSnapshot,
      capabilities: [`${tag}-only-capability`],
      mandatoryDenies: [],
      dynamicConstraints: [],
      absoluteDenies: [],
      allowedManualCapabilities: [`${tag}-only-capability`],
      delegableAvailable: [],
      provenance: { [`${tag}-only-capability`]: "operational-default" },
      killSwitchActive: false,
      killSwitchExpiresAtUtc: null,
      editingAvailable: true,
    };
  }
  const reviewerProfile = profileFor("reviewer", "reviewer");
  const handlerProfile = profileFor("review-handler", "handler");
  const broker: DispatchBroker = {
    describe: async () => { throw new Error("not called"); },
    profileCurrent: async () => { throw new Error("not called"); },
    profile: async (_repositoryKey, _pullRequestId, role) => {
      profileCalls.push(role);
      return role === "reviewer" ? reviewerPending : handlerPending;
    },
    dispatch: async () => { throw new Error("not called"); },
    cancel: async () => { throw new Error("not called"); },
    shutdown: async () => {},
    subscribeTerminal: () => () => {},
  };
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("s");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EFFECTIVE CAPABILITY PROFILE/);
    assert.match(setup.captureCharFrame(), /Role: REVIEWER/);
    assert.deepEqual(profileCalls, ["reviewer"]);
    assert.match(setup.captureCharFrame(), /Resolving effective profile for the next manual dispatch/);

    // Gate: Tab and r are ignored while the reviewer profile() request is still outstanding. This
    // is defense-in-depth against UI churn and out-of-order responses -- profile() is side-effect-
    // free on the broker, so unlike the old describe()-based flow this no longer needs to bound
    // broker-side draft allocation, but the role label must still never be able to outrun its own
    // refetch.
    setup.mockInput.pressTab();
    await setup.flush();
    assert.deepEqual(profileCalls, ["reviewer"]);
    assert.match(setup.captureCharFrame(), /Role: REVIEWER/);
    setup.mockInput.pressKey("r");
    await setup.flush();
    assert.deepEqual(profileCalls, ["reviewer"]);

    resolveReviewer(reviewerProfile);
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Role: REVIEWER/);
    assert.match(setup.captureCharFrame(), /reviewer-only-capability/);

    // Toggling role now fires a fresh profile() request for review-handler. Until it resolves, the
    // stale reviewer profile must never render under the new HANDLER label.
    setup.mockInput.pressTab();
    await setup.flush();
    assert.deepEqual(profileCalls, ["reviewer", "review-handler"]);
    assert.match(setup.captureCharFrame(), /Role: HANDLER/);
    assert.doesNotMatch(setup.captureCharFrame(), /reviewer-only-capability/);
    assert.match(setup.captureCharFrame(), /Resolving effective profile for the next manual dispatch/);

    resolveHandler(handlerProfile);
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Role: HANDLER/);
    assert.match(setup.captureCharFrame(), /handler-only-capability/);
    assert.doesNotMatch(setup.captureCharFrame(), /reviewer-only-capability/);

    setup.mockInput.pressEscape();
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /SETTINGS - EFFECTIVE CAPABILITY PROFILE/);
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

test("settings editor previews off and inherit changes without applying until the final confirmation", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls } = createSettingsBrokerFixture();
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140,
      height: 32,
      kittyKeyboard: true,
    });
    await setup.renderOnce();

    setup.mockInput.pressKey("s");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EFFECTIVE CAPABILITY PROFILE/);
    assert.match(setup.captureCharFrame(), /Role: REVIEWER \| Tab role \| r refresh \| e edit narrowing \| k kill switch \| Esc\/s close/);
    assert.deepEqual(calls.map((call) => call.operation), ["profile"]);

    setup.mockInput.pressKey("e");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EDIT PERSISTED NARROWING/);
    assert.match(setup.captureCharFrame(), /Scope: \[machine\]\s+user\s+repo-worktree\s+pr/);
    assert.match(setup.captureCharFrame(), /> EnableFindingComments/);

    setup.mockInput.pressArrow("right");
    await setup.flush();
    setup.mockInput.pressArrow("right");
    await setup.flush();
    setup.mockInput.pressArrow("down");
    await setup.flush();
    setup.mockInput.pressArrow("down");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Scope: machine\s+user\s+\[repo-worktree\]\s+pr/);
    assert.match(setup.captureCharFrame(), /> EnableThreadReplies/);

    setup.mockInput.pressKey("o");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /repo-worktree \/ EnableThreadReplies -> off/);
    assert.match(setup.captureCharFrame(), /This changes the effective profile:/);
    assert.match(setup.captureCharFrame(), /First confirmation: press c to review the final apply gate; Esc cancels\./);
    assert.deepEqual(calls.map((call) => call.operation), ["profile", "preview-narrowing"]);

    setup.mockInput.pressEscape();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EDIT PERSISTED NARROWING/);
    assert.match(setup.captureCharFrame(), /> EnableThreadReplies/);
    assert.equal(calls.filter((call) => call.operation === "apply-narrowing").length, 0);

    setup.mockInput.pressArrow("up");
    await setup.flush();
    setup.mockInput.pressArrow("up");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /> EnableFindingComments/);

    setup.mockInput.pressKey("i");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /repo-worktree \/ EnableFindingComments -> inherit/);
    assert.match(setup.captureCharFrame(), /First confirmation: press c to review the final apply gate; Esc cancels\./);
    assert.deepEqual(calls.map((call) => call.operation), ["profile", "preview-narrowing", "preview-narrowing"]);

    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /FINAL CONFIRMATION: press y to apply this exact preview; Esc cancels\./);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EDIT PERSISTED NARROWING/);
    assert.equal(calls.filter((call) => call.operation === "apply-narrowing").length, 0);

    setup.mockInput.pressKey("i");
    await setup.flush();
    setup.mockInput.pressKey("c");
    await setup.flush();
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Applied: EnableFindingComments reset to inherit at repo-worktree scope\./);
    assert.match(setup.captureCharFrame(), /Enabled: EnableSummaryComment, EnableThreadReplies, EnableFindingComments/);
    assert.match(setup.captureCharFrame(), /Denied \(mandatory\): EnableApprovalVote/);
    assert.deepEqual(calls.map((call) => call.operation), [
      "profile",
      "preview-narrowing",
      "preview-narrowing",
      "preview-narrowing",
      "apply-narrowing",
      "profile",
    ]);
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

test("settings kill switch two-stage confirm can be cancelled at either stage, enabled, disabled, and displays its expiry", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls, setKillSwitchTtlMinutes } = createSettingsBrokerFixture();
  setKillSwitchTtlMinutes(45);
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140,
      height: 32,
      kittyKeyboard: true,
    });
    await setup.renderOnce();

    setup.mockInput.pressKey("s");
    await setup.flush();

    // First-stage cancel: pressing k shows the full-disclosure warning (machine+user-wide blast
    // radius, ignores local narrowing, NEXT-launches-only, running agents immutable, no delegated
    // approval-vote/auto-complete) and Esc backs all the way out with no RPC call at all.
    setup.mockInput.pressKey("k");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /WARNING: machine\+user-wide emergency lever -- affects ALL repos\/worktrees\/PRs for this user on this machine, not just this PR\./);
    assert.match(setup.captureCharFrame(), /Ignores all locally persisted narrowing; restores compiled operational defaults for NEXT launches only\./);
    assert.match(setup.captureCharFrame(), /Any already-running agent is immutable and unaffected; grants no delegated approval-vote or auto-complete\./);
    assert.match(setup.captureCharFrame(), /Press c to review the final confirmation; Esc cancels\./);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /WARNING: machine\+user-wide emergency lever/);
    assert.equal(calls.filter((call) => call.operation === "set-kill-switch").length, 0);

    // Final-stage cancel: advance past the warning with c, then Esc at the terse final gate still
    // backs out with no RPC call.
    setup.mockInput.pressKey("k");
    await setup.flush();
    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /FINAL CONFIRMATION: enable the kill switch machine\+user-wide across ALL repos\/worktrees\/PRs\?/);
    assert.match(setup.captureCharFrame(), /Press y to enable; Esc cancels\./);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /FINAL CONFIRMATION: enable the kill switch/);
    assert.equal(calls.filter((call) => call.operation === "set-kill-switch").length, 0);

    // Enable: k (warning) -> c (final gate) -> y (confirm) actually toggles it on.
    setup.mockInput.pressKey("k");
    await setup.flush();
    setup.mockInput.pressKey("c");
    await setup.flush();
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Ignore local narrowing overrides is now ON: persisted narrowing is ignored until the next launch\./);
    assert.match(setup.captureCharFrame(), /Ignore local narrowing overrides: ON \(emergency lever, not a security lockdown\)/);
    assert.match(setup.captureCharFrame(), /Provenance: .*kill-switch/);
    assert.equal(calls.filter((call) => call.operation === "set-kill-switch").length, 1);

    // Expiry displayed: the broker's reported TTL renders as a minutes-remaining countdown plus
    // the raw timestamp it echoed (not pinning an exact minute count, since Settings' own display
    // is computed from a live clock signal relative to whenever this assertion happens to run).
    assert.match(setup.captureCharFrame(), /ON \(emergency lever, not a security lockdown\) \(expires in \d+m, \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);

    // Disable: k (terse warning, smaller blast radius) -> c (final gate) -> y (confirm) turns it
    // back off.
    setup.mockInput.pressKey("k");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Disable 'Ignore local narrowing overrides'\? Persisted narrowing becomes active again for next launches\./);
    assert.match(setup.captureCharFrame(), /Press c to review the final confirmation; Esc cancels\./);
    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /FINAL CONFIRMATION: disable 'Ignore local narrowing overrides'\? Persisted narrowing becomes active again\./);
    assert.match(setup.captureCharFrame(), /Press y to disable; Esc cancels\./);
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Ignore local narrowing overrides is now OFF: persisted narrowing applies again\./);
    assert.match(setup.captureCharFrame(), /Ignore local narrowing overrides: off/);
    assert.equal(calls.filter((call) => call.operation === "set-kill-switch").length, 2);
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

test("settings kill switch during a post-toggle refresh queues against the active generation instead of a stale profile, and still reverses correctly", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker: baseBroker, calls } = createSettingsBrokerFixture();
  // issue #105 PR3 closure: toggleKillSwitch() fires its own post-toggle profile() refresh
  // without awaiting it (`void refreshSettingsProfile(...)`), so that refresh (call #2 below) can
  // still be outstanding when the operator presses 'k' again. Holding exactly that second call
  // pending lets this test race a second 'k' press against it deterministically.
  let profileCallCount = 0;
  let releaseSecondProfile: (() => void) | undefined;
  const broker: DispatchBroker = {
    ...baseBroker,
    profile: async (repositoryKey, pullRequestId, role) => {
      profileCallCount++;
      if (profileCallCount === 2) {
        await new Promise<void>((resolve) => { releaseSecondProfile = resolve; });
      }
      return baseBroker.profile(repositoryKey, pullRequestId, role);
    },
  };
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140,
      height: 32,
      kittyKeyboard: true,
    });
    await setup.renderOnce();

    setup.mockInput.pressKey("s");
    await setup.flush();
    assert.equal(profileCallCount, 1);

    // Enable the kill switch normally; its own profile() call (#1) already resolved above.
    setup.mockInput.pressKey("k");
    await setup.flush();
    setup.mockInput.pressKey("c");
    await setup.flush();
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Ignore local narrowing overrides is now ON/);
    assert.equal(calls.filter((call) => call.operation === "set-kill-switch").length, 1);
    // toggleKillSwitch's own silent refresh (profile call #2) is now in flight and deliberately
    // held pending by the broker override above.
    assert.equal(profileCallCount, 2);

    // Press k again WHILE that refresh is still outstanding. The currently loaded profile is
    // still the STALE pre-toggle snapshot (killSwitchActive: false) -- this must queue against
    // the active refresh rather than act on it immediately.
    setup.mockInput.pressKey("k");
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /WARNING: machine\+user-wide emergency lever/);
    assert.doesNotMatch(setup.captureCharFrame(), /Disable 'Ignore local narrowing overrides'\?/);
    assert.match(setup.captureCharFrame(), /Kill switch will open once the effective profile finishes loading\./);

    // Extra c/y presses while still queued (killSwitchStage is still "none", nothing has opened
    // yet) must never be silently misinterpreted as advancing or firing a confirm -- no dropped
    // key ever turns into an unintended RPC.
    setup.mockInput.pressKey("c");
    await setup.flush();
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.equal(calls.filter((call) => call.operation === "set-kill-switch").length, 1);

    // Release the deferred refresh: the queued 'k' now fires against the FRESH, post-toggle
    // profile (killSwitchActive: true), so the dialog must open showing the DISABLE direction,
    // never repeating the stale ENABLE direction.
    releaseSecondProfile?.();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Disable 'Ignore local narrowing overrides'\? Persisted narrowing becomes active again for next launches\./);

    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /FINAL CONFIRMATION: disable 'Ignore local narrowing overrides'\?/);
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Ignore local narrowing overrides is now OFF: persisted narrowing applies again\./);
    // Exactly one additional (correct, reverse) set-kill-switch call -- never a repeated ENABLE.
    assert.equal(calls.filter((call) => call.operation === "set-kill-switch").length, 2);
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

test("settings editor is unavailable without a trusted broker", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} />, {
      width: 140,
      height: 32,
      kittyKeyboard: true,
    });
    await setup.renderOnce();

    setup.mockInput.pressKey("s");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EFFECTIVE CAPABILITY PROFILE/);
    assert.match(setup.captureCharFrame(), /Unavailable: trusted manual broker is not connected \(observe-only mode\)\./);

    setup.mockInput.pressKey("e");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Observe-only: trusted manual broker is unavailable/);
    assert.match(setup.captureCharFrame(), /SETTINGS - EFFECTIVE CAPABILITY PROFILE/);
    assert.doesNotMatch(setup.captureCharFrame(), /SETTINGS - EDIT PERSISTED NARROWING/);
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

test("q closes the settings editor globally and shuts down the broker", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker } = createSettingsBrokerFixture();
  let shutdownCount = 0;
  const wrappedBroker: DispatchBroker = {
    ...broker,
    shutdown: async () => {
      shutdownCount++;
      await broker.shutdown();
    },
  };
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={wrappedBroker} />, {
      width: 140,
      height: 32,
      kittyKeyboard: true,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("s");
    await setup.flush();
    setup.mockInput.pressKey("e");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /SETTINGS - EDIT PERSISTED NARROWING/);

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

test("trusted manual flow binds a fresh preview and explicit start independently of History", async (context) => {
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
    absoluteDenies: [],
    allowedManualCapabilities: [],
    delegableAvailable: [],
    provenance: {},
    killSwitchActive: false,
    killSwitchExpiresAtUtc: null,
    editingAvailable: true,
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
    profileCurrent: async () => ({ ...summary, operation: "capability-profile" }),
    describe: async (repositoryKey, pullRequestId) => {
      describeCount++;
      describedTarget = `${repositoryKey}:${pullRequestId}`;
      return described;
    },
    profile: async () => { throw new Error("not called"); },
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
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("f", { shift: true });
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
    assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
    assert.match(setup.captureCharFrame(), /PR ID: \(blank\)/);
    setup.mockInput.pressTab();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Role: HANDLER/);
    setup.mockInput.pressTab({ shift: true });
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Role: REVIEWER/);
    await setup.mockInput.typeText("104");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /contoso\/broker-repo \/ PR #104/);
    assert.match(setup.captureCharFrame(), /Manual PR \| Ada/);
    assert.match(setup.captureCharFrame(), /Preparing preview/);
    setup.mockInput.pressTab();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Role: REVIEWER/);
    assert.equal(dispatchCount, 0);
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
    assert.match(setup.captureCharFrame(), /contoso\/broker-repo \/ PR #104/);
    assert.doesNotMatch(setup.captureCharFrame(), /other-repo \/ PR #205/);
    resolveDescribe(summary);
    await setup.flush();
    assert.match(setup.captureCharFrame(), /contoso\/broker-repo \/ PR #104/);
    assert.match(setup.captureCharFrame(), /Not allowed: approval vote/);
    setup.mockInput.pressKey("p");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Optional instructions/);
    setup.mockInput.pressKey("q");
    setup.mockInput.pressKey("q", { ctrl: true });
    await setup.mockInput.typeText(" fix");
    setup.mockInput.pressEnter({ shift: true });
    await setup.mockInput.typeText("next");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /q fix \/ next/);
    setup.mockInput.pressBackspace();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /q fix \/ nex/);
    setup.mockInput.pressKey("d", { ctrl: true });
    await setup.flush();
    assert.equal(describeCount, 1, "optional instructions do not allocate another draft");
    assert.equal(dispatchCount, 0);
    setup.mockInput.pressKey("d");
    await setup.flush();
    assert.equal(dispatchCount, 0);
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.equal(dispatchCount, 1);
    assert.equal(dispatchedTarget, "v1:github:9007199254740993:104");
    assert.match(setup.captureCharFrame(), /STARTED \/ RUNNING/);
    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.equal(cancelCount, 1);
    assert.match(setup.captureCharFrame(), /CANCELLED/);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
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
    profileCurrent: async () => { throw new Error("not called"); },
    profile: async () => { throw new Error("not called"); },
    dispatch: async () => { throw new Error("not called"); },
    cancel: async () => { throw new Error("not called"); },
    shutdown: async () => { shutdownCount++; },
    subscribeTerminal: () => () => {},
  };
  const lifecycle = createDashboardLifecycle(fixture.tailer, broker);
  try {
    setup = await renderAdvanced(() => <App
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
    profileCurrent: async () => { throw new Error("not called"); },
    profile: async () => { throw new Error("not called"); },
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
    setup = await renderAdvanced(() => <App
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

// PR4 interactive widening (issue #105): a dedicated fixture mirroring createSettingsBrokerFixture's
// style but for the manual-dispatch draft + widening chain specifically. describe() always resolves
// immediately (unlike the big manual-dispatch test's deferred-promise fixture above) since these
// tests exercise the widening sub-flow, not describe()'s own pending/race behavior.
function createWideningBrokerFixture(options: {
  role?: AgentRole;
  delegableAvailable?: string[];
  killSwitchActive?: boolean;
  pairedCapabilityActive?: boolean;
  describeWideningRejection?: { code: string; detail?: string };
} = {}): {
  broker: DispatchBroker;
  calls: string[];
  dispatchedSummaries: CapabilitySummary[];
} {
  const role: AgentRole = options.role ?? "reviewer";
  const capability = role === "reviewer" ? "EnableApprovalVote" : "EnableAutoComplete";
  const pairedCapability = role === "reviewer" ? "EnableFindingComments" : null;
  const pairedCapabilityActive = options.pairedCapabilityActive ?? true;
  const calls: string[] = [];
  const dispatchedSummaries: CapabilitySummary[] = [];
  let generation = 0;
  const repositoryIdentity = {
    schemaVersion: 1 as const,
    provider: "GitHub" as const,
    repositoryId: "9007199254740993",
    organization: "contoso",
    project: "",
    repositoryName: "repo",
    slug: "contoso/repo",
    key: "v1:github:9007199254740993",
    verifiedAtUtc: "2026-09-03T00:00:00Z",
    verified: true,
    dispatchEligible: true,
  };
  const prSnapshot = {
    schemaVersion: 1 as const,
    pullRequestId: 104,
    sourceCommit: "a".repeat(40),
    sourceRef: "feature",
    targetRef: "main",
    active: true,
    draft: false,
    author: "Ada",
    title: "Widening PR",
  };
  const summary: CapabilitySummary = {
    schemaVersion: 1,
    requestId: "r-describe",
    operation: "capability-summary",
    role,
    dispatchDraftId: "22222222-2222-4222-8222-222222222222",
    repositoryIdentity,
    prSnapshot,
    capabilityPolicyDigest: "b".repeat(64),
    prStateFingerprint: "c".repeat(64),
    capabilities: [],
    mandatoryDenies: [capability],
    dynamicConstraints: [],
    absoluteDenies: [],
    allowedManualCapabilities: [],
    delegableAvailable: options.delegableAvailable ?? [capability],
    provenance: {},
    killSwitchActive: options.killSwitchActive ?? false,
    killSwitchExpiresAtUtc: null,
    editingAvailable: true,
  };
  const accepted: DispatchAccepted = {
    schemaVersion: 1,
    requestId: "r-accept",
    operation: "accepted",
    dispatchId: "44444444-4444-4444-8444-444444444444",
    repositoryIdentity,
    pullRequestId: 104,
    role,
    capabilityPolicyDigest: "d".repeat(64),
    prStateFingerprint: summary.prStateFingerprint,
    childProcessId: 42,
    eventLogPath: "Q:\\events\\widening.jsonl",
  };
  const broker: DispatchBroker = {
    profileCurrent: async () => ({ ...summary, operation: "capability-profile" }),
    describe: async () => { calls.push("describe"); return summary; },
    profile: async () => { throw new Error("not called"); },
    previewNarrowing: async () => { throw new Error("not called"); },
    applyNarrowing: async () => { throw new Error("not called"); },
    setKillSwitch: async () => { throw new Error("not called"); },
    describeWidening: async (s, cap): Promise<WideningPreview> => {
      calls.push(`describe-widening:${cap}`);
      if (options.describeWideningRejection) {
        throw new BrokerRejectionError(options.describeWideningRejection.code, options.describeWideningRejection.detail ?? "");
      }
      generation += 1;
      return {
        schemaVersion: 1,
        requestId: `w-${generation}`,
        operation: "widening-preview",
        state: "previewed",
        dispatchDraftId: s.dispatchDraftId,
        capability: cap,
        challenge: "a".repeat(48),
        effectiveDiff: { addedCapabilities: [cap], removedDenies: [cap], pairedCapability, pairedCapabilityActive },
        expiresAtUtc: "2026-09-03T18:00:00Z",
        generation,
      };
    },
    confirmWideningPreview: async (s, stage): Promise<WideningSummary> => {
      calls.push("confirm-widening-preview");
      generation += 1;
      return {
        schemaVersion: 1,
        requestId: `w-${generation}`,
        operation: "widening-summary",
        state: "awaiting-final-confirmation",
        dispatchDraftId: s.dispatchDraftId,
        capability: stage.capability,
        challenge: "b".repeat(48),
        effectiveDiff: stage.effectiveDiff,
        expiresAtUtc: "2026-09-03T18:01:00Z",
        generation,
      };
    },
    confirmWideningMint: async (s, stage): Promise<WideningMinted> => {
      calls.push("confirm-widening-mint");
      generation += 1;
      return {
        schemaVersion: 1,
        requestId: `w-${generation}`,
        operation: "widening-minted",
        state: "minted",
        dispatchDraftId: s.dispatchDraftId,
        capability: stage.capability,
        capabilities: [...summary.capabilities, stage.capability],
        mandatoryDenies: summary.mandatoryDenies.filter((deny) => deny !== stage.capability),
        capabilityPolicyDigest: "d".repeat(64),
        effectiveDiff: stage.effectiveDiff,
        grantExpiresAtUtc: "2026-09-03T18:10:00Z",
        generation,
      };
    },
    cancelWidening: async (s, requestedGeneration): Promise<WideningCancelled> => {
      calls.push(`cancel-widening:${requestedGeneration}`);
      generation += 1;
      return {
        schemaVersion: 1,
        requestId: `w-${generation}`,
        operation: "widening-cancelled",
        state: "cancelled",
        dispatchDraftId: s.dispatchDraftId,
        capabilities: summary.capabilities,
        mandatoryDenies: summary.mandatoryDenies,
        capabilityPolicyDigest: summary.capabilityPolicyDigest,
        delegableAvailable: summary.delegableAvailable,
        generation,
      };
    },
    dispatch: async (describedSummary) => {
      calls.push("dispatch");
      dispatchedSummaries.push(describedSummary);
      return accepted;
    },
    cancel: async () => { throw new Error("not called"); },
    shutdown: async () => { calls.push("shutdown"); },
    subscribeTerminal: () => () => {},
  };
  return { broker, calls, dispatchedSummaries };
}

async function openManualAndDescribe(setup: TestRendererSetup, role: AgentRole = "reviewer"): Promise<void> {
  setup.mockInput.pressKey("m");
  await setup.flush();
  if (role === "review-handler") {
    setup.mockInput.pressTab();
    await setup.flush();
  }
  await setup.mockInput.typeText("104");
  setup.mockInput.pressEnter();
  await setup.flush();
  assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
}

test("manual dispatch widening: reviewer mints EnableApprovalVote via two explicit confirms, shows the paired EnableFindingComments requirement, never auto-dispatches, and the existing d/y gate dispatches the minted digest", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls, dispatchedSummaries } = createWideningBrokerFixture({ role: "reviewer" });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    await openManualAndDescribe(setup);
    assert.match(setup.captureCharFrame(), /force fresh analysis/);
    assert.match(setup.captureCharFrame(), /Press w to request EnableApprovalVote widening/);

    setup.mockInput.pressKey("w");
    await setup.flush();
    assert.deepEqual(calls, ["describe", "describe-widening:EnableApprovalVote"]);
    assert.match(setup.captureCharFrame(), /Widening preview: EnableApprovalVote/);
    assert.match(setup.captureCharFrame(), /Paired requirement: EnableFindingComments must already be active \(confirmed active\)/);
    assert.match(setup.captureCharFrame(), /unexplained verdict/);
    assert.match(setup.captureCharFrame(), /First widening confirmation: press c/);
    setup.mockInput.pressEnter();
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.equal(calls.at(-1), "describe-widening:EnableApprovalVote");

    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.equal(calls.at(-1), "confirm-widening-preview");
    assert.match(setup.captureCharFrame(), /Final widening blast radius: EnableApprovalVote/);
    assert.match(setup.captureCharFrame(), /Single-use grant; expires/);
    assert.match(setup.captureCharFrame(), /Unavailable to headless\/direct\/watcher dispatch/);
    assert.match(setup.captureCharFrame(), /FINAL WIDENING CONFIRMATION: press y/);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.equal(calls.at(-1), "confirm-widening-preview");

    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.equal(calls.at(-1), "confirm-widening-mint");
    assert.equal(calls.includes("dispatch"), false, "minting must never auto-dispatch");
    assert.match(setup.captureCharFrame(), /Widening grant minted and active for this draft/);
    assert.match(setup.captureCharFrame(), /vote-grant dispatch: skips forced fresh analysis/);
    assert.match(setup.captureCharFrame(), /Allowed: approval vote/);

    // Existing, unmodified dispatch confirmation gate -- 'd' then 'y' -- is what finally dispatches.
    setup.mockInput.pressKey("d");
    await setup.flush();
    assert.equal(calls.includes("dispatch"), false);
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.deepEqual(calls.slice(-1), ["dispatch"]);
    assert.equal(dispatchedSummaries.length, 1);
    assert.equal(dispatchedSummaries[0]?.capabilityPolicyDigest, "d".repeat(64));
    assert.deepEqual(dispatchedSummaries[0]?.capabilities, ["EnableApprovalVote"]);
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

test("manual dispatch widening: Esc during preview and during the final summary each cancel widening with the current generation and never dispatch", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls } = createWideningBrokerFixture({ role: "reviewer" });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    await openManualAndDescribe(setup);

    // Cancel at the first widening stage (preview).
    setup.mockInput.pressKey("w");
    await setup.flush();
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.deepEqual(calls, ["describe", "describe-widening:EnableApprovalVote", "cancel-widening:1"]);
    assert.match(setup.captureCharFrame(), /Widening cancelled/);
    assert.match(setup.captureCharFrame(), /Press w to request EnableApprovalVote widening/);

    // Cancel again, this time at the final summary stage, after a fresh describe-widening.
    setup.mockInput.pressKey("w");
    await setup.flush();
    setup.mockInput.pressKey("c");
    await setup.flush();
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.deepEqual(calls.slice(-3), ["describe-widening:EnableApprovalVote", "confirm-widening-preview", "cancel-widening:4"]);
    assert.match(setup.captureCharFrame(), /Widening cancelled/);
    assert.equal(calls.includes("confirm-widening-mint"), false);
    assert.equal(calls.includes("dispatch"), false);
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

test("manual dispatch widening: empty delegableAvailable and an active kill switch both block the widening entry point in the UI", async (context) => {
  const fixture1 = createFixture();
  const history1 = createSettingsHistory();
  const { broker: emptyBroker, calls: emptyCalls } = createWideningBrokerFixture({ delegableAvailable: [] });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture1.reducer} history={history1} tailer={fixture1.tailer} broker={emptyBroker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    await openManualAndDescribe(setup);
    assert.match(setup.captureCharFrame(), /No delegated capabilities available for this role/);
    setup.mockInput.pressKey("w");
    await setup.flush();
    assert.equal(emptyCalls.includes("describe-widening:EnableApprovalVote"), false);
  } catch (error) {
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return;
    }
    throw error;
  } finally {
    setup?.renderer.destroy();
    await fixture1.tailer.stop();
  }

  const fixture2 = createFixture();
  const history2 = createSettingsHistory();
  const { broker: killSwitchBroker, calls: killSwitchCalls } = createWideningBrokerFixture({ killSwitchActive: true });
  let setup2: TestRendererSetup | undefined;
  try {
    setup2 = await renderAdvanced(() => <App reducer={fixture2.reducer} history={history2} tailer={fixture2.tailer} broker={killSwitchBroker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup2.renderOnce();
    await openManualAndDescribe(setup2);
    assert.match(setup2.captureCharFrame(), /Widening unavailable while the kill switch is active/);
    setup2.mockInput.pressKey("w");
    await setup2.flush();
    assert.equal(killSwitchCalls.includes("describe-widening:EnableApprovalVote"), false);
  } catch (error) {
    if (error instanceof Error && error.message.includes("native FFI is not available")) {
      context.skip("native rendering is covered by npm run test:renderer with the locked Bun runtime");
      return;
    }
    throw error;
  } finally {
    setup2?.renderer.destroy();
    await fixture2.tailer.stop();
  }
});

test("manual dispatch widening: a rejected describe-widening is terminal (no auto-retry) and surfaces the broker's message; review-handler grants its own EnableAutoComplete capability", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls } = createWideningBrokerFixture({
    role: "review-handler",
    describeWideningRejection: { code: "widening-expired", detail: "" },
  });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    await openManualAndDescribe(setup, "review-handler");
    assert.match(setup.captureCharFrame(), /Role: HANDLER/);
    assert.match(setup.captureCharFrame(), /Press w to request EnableAutoComplete widening/);

    setup.mockInput.pressKey("w");
    await setup.flush();
    assert.deepEqual(calls, ["describe", "describe-widening:EnableAutoComplete"]);
    assert.match(setup.captureCharFrame(), /widening confirmation expired; request widening again/);
    // Terminal, not auto-retried: the hint to press w again is back, and no further
    // describe-widening call has been made without an explicit fresh keypress.
    assert.match(setup.captureCharFrame(), /Press w to request EnableAutoComplete widening/);
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.deepEqual(calls, ["describe", "describe-widening:EnableAutoComplete"]);
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

test("manual dispatch widening: closing the panel with a minted-but-undispatched grant best-effort cancels it", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls } = createWideningBrokerFixture({ role: "reviewer" });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140, height: 32, kittyKeyboard: true,
    });
    await setup.renderOnce();
    await openManualAndDescribe(setup);
    setup.mockInput.pressKey("w");
    await setup.flush();
    setup.mockInput.pressKey("c");
    await setup.flush();
    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.equal(calls.includes("dispatch"), false);
    assert.equal(calls.includes("cancel-widening:3"), false);

    setup.mockInput.pressEscape();
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
    assert.ok(calls.includes("cancel-widening:3"), "closing with a minted grant must best-effort cancel it");
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

test("golden operational chrome keeps History and manual launch discoverable at supported widths", async (context) => {
  for (const width of [70, 100, 140]) {
    const fixture = createFixture();
    const history = createSettingsHistory();
    let setup: TestRendererSetup | undefined;
    try {
      setup = await renderAdvanced(() => (
        <App
          reducer={fixture.reducer}
          history={history}
          tailer={fixture.tailer}
          launchMode="operational"
        />
      ), { width, height: 32, kittyKeyboard: true });
      await setup.renderOnce();
      const initial = setup.captureCharFrame();
      assert.match(initial, /OPERATIONAL/);
      assert.match(initial, /m Start Agent by PR ID/);

      setup.mockInput.pressKey("f", { shift: true });
      await setup.flush();
      const historyFrame = setup.captureCharFrame();
      assert.match(historyFrame, /PR history 1/);
      assert.match(historyFrame, /selected repo #104/);
      assert.match(historyFrame, /m Start Agent by PR ID/);
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
  }
});

  async function startFixture() {
    const seed = createWideningBrokerFixture();
    const base = await seed.broker.describe("", 104, "reviewer");
    const calls: { operation: string; prId?: number; role?: AgentRole; key?: string; summary?: CapabilitySummary }[] = [];
    const summaryFor = (prId: number, role: AgentRole): CapabilitySummary => {
      const id = role === "reviewer" ? "101" : "202";
      const capabilities = role === "reviewer"
        ? ["EnableFindingComments", "EnableThreadReplies", "EnableSummaryComment"]
        : ["EnableCodeChanges", "EnablePush", "EnableThreadReplies", "LocalValidation"];
      return {
        ...base, role,
        repositoryIdentity: { ...base.repositoryIdentity, repositoryId: id, key: `v1:github:${id}`, slug: `configured/${role}` },
        prSnapshot: { ...base.prSnapshot, pullRequestId: prId, title: `Unobserved PR ${prId}` },
        capabilities, allowedManualCapabilities: capabilities, delegableAvailable: [],
        mandatoryDenies: [role === "reviewer" ? "EnableApprovalVote" : "EnableAutoComplete"],
      };
    };
    const broker: DispatchBroker = {
      ...seed.broker,
      profileCurrent: async (prId, role) => {
        calls.push({ operation: "profile-current", prId, role });
        const { dispatchDraftId: _draft, capabilityPolicyDigest: _policy, prStateFingerprint: _pr, ...profile } = summaryFor(prId, role);
        return { ...profile, operation: "capability-profile" };
      },
      describe: async (key, prId, role) => {
        calls.push({ operation: "describe", key, prId, role });
        return summaryFor(prId, role);
      },
      dispatch: async (summary) => {
        calls.push({ operation: "dispatch", summary });
        return {
          schemaVersion: 1, requestId: "accepted", operation: "accepted", dispatchId: "44444444-4444-4444-8444-444444444444",
          repositoryIdentity: summary.repositoryIdentity, role: summary.role,
          pullRequestId: summary.prSnapshot.pullRequestId, capabilityPolicyDigest: summary.capabilityPolicyDigest,
          prStateFingerprint: summary.prStateFingerprint, childProcessId: 42,
          eventLogPath: join(process.cwd(), "unobserved-test-events.jsonl"),
        };
      },
      shutdown: async () => { calls.push({ operation: "shutdown" }); },
    };
    return { broker, calls, summaryFor };
  }

  async function withStartRenderer(
    context: TestContext,
    broker: DispatchBroker,
    run: (setup: TestRendererSetup, history: PullRequestHistoryProjection, reducer: OperationsReducer) => Promise<void>,
    width = 140,
    launchMode: "operational" | "preview" = "operational",
    brokerFailure?: () => string,
  ): Promise<void> {
    const fixture = createFixture();
    const history = new PullRequestHistoryProjection();
    const reducer = new OperationsReducer();
    let setup: TestRendererSetup | undefined;
    try {
      setup = await renderAdvanced(() => (
        <App reducer={reducer} history={width === 100 ? undefined : history} tailer={fixture.tailer} broker={broker} launchMode={launchMode} brokerFailure={brokerFailure} />
      ), { width, height: 36, kittyKeyboard: true });
      await setup.renderOnce();
      await run(setup, history, reducer);
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
  }

  test("Start Agent by PR ID: both configured repositories work without history from every view, command and width", { timeout: 30_000 }, async (context) => {
    for (const width of [70, 100, 140]) {
      for (const view of ["current", "live", "history"]) {
        for (const role of ["reviewer", "review-handler"] as const) {
          for (const command of ["m", "palette"]) {
            const { broker, calls } = await startFixture();
            await withStartRenderer(context, broker, async (setup, history) => {
              if (view !== "live") setup.mockInput.pressKey("f", { shift: view === "history" });
              await setup.flush();
              assert.match(setup.captureCharFrame(), /m Start Agent by PR ID/);
              if (command === "m") setup.mockInput.pressKey("m");
              else {
                setup.mockInput.pressKey("p", { ctrl: true });
                for (let i = 0; i < 10; i++) setup.mockInput.pressArrow("down");
                setup.mockInput.pressEnter();
              }
              await setup.flush();
              assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
              assert.match(setup.captureCharFrame(), /PR ID: \(blank\)/);
              assert.match(setup.captureCharFrame(), /Agent: Reviewer/);
              assert.match(setup.captureCharFrame(), /Uses the selected agent's configured repository/);
              if (role === "review-handler") setup.mockInput.pressTab();
              await setup.mockInput.typeText("912");
              setup.mockInput.pressEnter();
              await setup.flush();
              assert.match(setup.captureCharFrame(), new RegExp(`configured/${role} / PR #912`));
              assert.match(setup.captureCharFrame(), /Unobserved PR 912/);
              setup.mockInput.pressTab(); // Resolution freezes the chosen role.
              await setup.flush();
              assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
              assert.doesNotMatch(setup.captureCharFrame(), /Optional instructions \(/);
              assert.deepEqual(calls.map((call) => call.operation), ["profile-current", "describe"]);
              assert.deepEqual(calls[1], {
                operation: "describe", role, prId: 912, key: role === "reviewer" ? "v1:github:101" : "v1:github:202",
              });
              setup.mockInput.pressEnter();
              setup.mockInput.pressEnter();
              await setup.flush();
              assert.equal(calls.filter((call) => call.operation === "dispatch").length, 1);
              assert.ok(calls[2]?.summary?.capabilities.includes(role === "reviewer" ? "EnableFindingComments" : "EnablePush"));
              assert.equal(history.list().length, 0, "no synthetic history is inserted");
            }, width);
            if (context.signal.aborted) return;
          }
        }
      }
    }
  });

  test("Start Agent input validates whole typed and pasted strings, rejects truncation, and permits deliberate correction", async (context) => {
    for (const value of ["", "0", "-1", "1.2", "1e2", "2147483648", "１２", "1 2", "1\n2", "1\u001b2"]) {
      assert.equal(parseManualPullRequestId(value), null);
    }
    assert.equal(parseManualPullRequestId("2147483647"), 2147483647);
    const { broker, calls } = await startFixture();
    await withStartRenderer(context, broker, async (setup) => {
      setup.mockInput.pressKey("m");
      await setup.flush();
      for (const value of ["", "0", "-1", "1.2", "1e2", "2147483648", "１２", "1 2"]) {
        setup.mockInput.pressKey("u", { ctrl: true });
        await setup.mockInput.typeText(value);
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.match(setup.captureCharFrame(), /PR ID must be in 1..2147483647/);
        assert.equal(calls.length, 0, `must not reinterpret ${value}`);
      }
      for (const value of ["1.2", "-1", "2147483648", "9".repeat(100), "104\n", "1\u001b2"]) {
        setup.mockInput.pressKey("u", { ctrl: true });
        await setup.mockInput.pasteBracketedText(value);
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.equal(calls.length, 0, `must not reinterpret paste ${JSON.stringify(value)}`);
      }
      setup.mockInput.pressKey("u", { ctrl: true });
      await setup.mockInput.typeText("104");
      await setup.mockInput.pasteBracketedText("0".repeat(100));
      setup.mockInput.pressBackspace();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.equal(calls.length, 0, "overflow never leaves a submittable retained prefix");
      assert.match(setup.captureCharFrame(), /Input rejected. Ctrl\+U to clear/);
      setup.mockInput.pressKey("u", { ctrl: true });
      await setup.mockInput.typeText("2147483648");
      setup.mockInput.pressBackspace();
      setup.mockInput.pressKey("7");
      setup.mockInput.pressArrow("left");
      setup.mockInput.pressKey("q", { ctrl: true });
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.equal(calls[0]?.prId, 2147483647);
      setup.mockInput.pressKey("p");
      await setup.flush();
      await setup.mockInput.pasteBracketedText("🚀".repeat(512));
      await setup.flush();
      assert.match(setup.captureCharFrame(), /512\/512/);
      await setup.mockInput.pasteBracketedText("x");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /Context paste rejected/);
    });
  });

  test("Start Agent pending reads cancel, deduplicate and ignore stale success AND failure after reopening", async (context) => {
    for (const stage of ["resolving", "describing"]) {
      for (const outcome of ["success", "failure"]) {
        const { broker, calls, summaryFor } = await startFixture();
        let settle!: (value: CapabilitySummary) => void;
        let fail!: (reason: Error) => void;
        const pending = new Promise<CapabilitySummary>((resolve, reject) => { settle = resolve; fail = reject; });
        let readCount = 0;
        if (stage === "resolving") {
          const original = broker.profileCurrent;
          broker.profileCurrent = async (prId, role) => {
            readCount++;
            if (readCount === 1) return { ...await pending, operation: "capability-profile" };
            return original(prId, role);
          };
        } else {
          const original = broker.describe;
          broker.describe = async (...args) => { readCount++; return readCount === 1 ? pending : original(...args); };
        }
        await withStartRenderer(context, broker, async (setup) => {
          setup.mockInput.pressKey("m");
          await setup.mockInput.typeText("104");
          setup.mockInput.pressEnter();
          setup.mockInput.pressEnter();
          await setup.flush();
          if (stage === "describing") {
            setup.mockInput.pressKey("d", { ctrl: true });
            setup.mockInput.pressKey("d", { ctrl: true });
            await setup.flush();
          }
          assert.equal(readCount, 1);
          setup.mockInput.pressTab();
          setup.mockInput.pressEscape();
          await setup.flush();
          assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
          setup.mockInput.pressKey("m");
          setup.mockInput.pressTab();
          await setup.mockInput.typeText("205");
          setup.mockInput.pressEnter();
          await setup.flush();
          assert.match(setup.captureCharFrame(), /configured\/review-handler \/ PR #205/);
          if (outcome === "success") settle(summaryFor(104, "reviewer"));
          else fail(new Error("stale failure must not surface"));
          await setup.flush();
          assert.match(setup.captureCharFrame(), /configured\/review-handler \/ PR #205/);
          assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
          assert.doesNotMatch(setup.captureCharFrame(), /stale failure|First confirmation/);
          assert.equal(calls.some((call) => call.operation === "dispatch"), false);
          setup.mockInput.pressEscape();
          setup.mockInput.pressKey("m");
          await setup.flush();
          assert.match(setup.captureCharFrame(), /Agent: Reviewer/);
          assert.match(setup.captureCharFrame(), /PR ID: \(blank\)/);
        });
      }
    }
  });

  test("Start Agent fails closed for discovery and fresh-describe mismatches, disabled roles and provider failures", async (context) => {
    for (const fault of ["resolve-pr", "resolve-role", "describe-pr", "describe-role", "describe-key", "disabled", "provider"]) {
      const { broker, calls } = await startFixture();
      const discover = broker.profileCurrent;
      const describe = broker.describe;
      broker.profileCurrent = async (prId, role) => {
        if (fault === "disabled") throw new BrokerRejectionError("role-not-allowed", "");
        if (fault === "provider") throw new Error("private/path/provider-secret");
        const profile = await discover(prId, role);
        if (fault === "resolve-pr") profile.prSnapshot.pullRequestId++;
        if (fault === "resolve-role") profile.role = "review-handler";
        return profile;
      };
      broker.describe = async (key, prId, role) => {
        const summary = await describe(key, prId, role);
        if (fault === "describe-pr") summary.prSnapshot.pullRequestId++;
        if (fault === "describe-role") summary.role = "review-handler";
        if (fault === "describe-key") summary.repositoryIdentity.key = "v1:github:999";
        return summary;
      };
      await withStartRenderer(context, broker, async (setup) => {
        setup.mockInput.pressKey("m");
        await setup.mockInput.typeText("104");
        setup.mockInput.pressEnter();
        await setup.flush();
        if (fault.startsWith("describe")) {
          setup.mockInput.pressKey("d", { ctrl: true });
          await setup.flush();
        }
        assert.match(setup.captureCharFrame(), /Could not verify|not enabled by the trusted launcher/);
        assert.doesNotMatch(setup.captureCharFrame(), /private\/path|First confirmation/);
        setup.mockInput.pressKey("d");
        setup.mockInput.pressKey("y");
        await setup.flush();
        assert.equal(calls.some((call) => call.operation === "dispatch"), false);
      });
    }
  });

test("Start Agent pending reads cannot revive UI after quit or renderer cleanup", async (context) => {
  for (const stage of ["resolving", "describing"]) {
    for (const exit of ["quit", "destroy"]) {
      for (const outcome of ["success", "failure"]) {
        const { broker, calls, summaryFor } = await startFixture();
        let complete!: (summary: CapabilitySummary) => void;
        let fail!: (reason: Error) => void;
        const pending = new Promise<CapabilitySummary>((resolve, reject) => { complete = resolve; fail = reject; });
        if (stage === "resolving") broker.profileCurrent = async () => ({ ...await pending, operation: "capability-profile" });
        else broker.describe = async () => pending;
        await withStartRenderer(context, broker, async (setup) => {
          setup.mockInput.pressKey("m");
          await setup.mockInput.typeText("104");
          setup.mockInput.pressEnter();
          await setup.flush();
          if (stage === "describing") {
            setup.mockInput.pressKey("d", { ctrl: true });
            await setup.flush();
          }
          if (exit === "quit") setup.mockInput.pressKey("q");
          else setup.renderer.destroy();
          await new Promise((resolve) => setTimeout(resolve, 20));
          assert.equal(setup.renderer.isDestroyed, true);
          if (outcome === "success") complete(summaryFor(104, "reviewer"));
          else fail(new Error("abandoned request"));
          await new Promise((resolve) => setTimeout(resolve, 20));
          assert.equal(calls.filter((call) => call.operation === "shutdown").length, 1);
          assert.equal(calls.some((call) => call.operation === "dispatch"), false);
        });
      }
    }
  }
});

  test("Enter previews then starts exactly once; both roles show visible progress and cancellation at 70/100/140 columns", { timeout: 20_000 }, async (context) => {
    for (const width of [70, 100, 140]) {
      const role: AgentRole = width === 100 ? "review-handler" : "reviewer";
      const { broker, calls, summaryFor } = await startFixture();
      let accept!: (value: DispatchAccepted) => void;
      let cancel!: (value: DispatchTerminal) => void;
      let terminalListener: ((value: DispatchTerminal) => void) | undefined;
      let dispatchedPrompt = "";
      let cancelCount = 0;
      const dispatch = broker.dispatch;
      broker.dispatch = async (summary, prompt) => {
        dispatchedPrompt = prompt;
        const accepted = await dispatch(summary, prompt);
        await new Promise<void>((resolve) => { accept = (value) => { assert.deepEqual(value, accepted); resolve(); }; });
        return accepted;
      };
      broker.cancel = async () => {
        cancelCount++;
        return new Promise<DispatchTerminal>((resolve) => { cancel = resolve; });
      };
      broker.subscribeTerminal = (listener) => {
        terminalListener = listener;
        return () => { terminalListener = undefined; };
      };
      await withStartRenderer(context, broker, async (setup, _history, reducer) => {
        setup.mockInput.pressKey("f", { shift: true }); // History/filter selection must not hide manual progress.
        setup.mockInput.pressTab();
        setup.mockInput.pressKey("m");
        if (role === "review-handler") setup.mockInput.pressTab();
        await setup.mockInput.typeText("104");
        setup.mockInput.pressEnter();
        setup.mockInput.pressEnter(); // Buffered Enter cannot start the asynchronously loaded preview.
        await setup.flush();
        assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
        assert.equal(calls.some((call) => call.operation === "dispatch"), false);
        setup.mockInput.pressKey("p");
        await setup.flush();
        assert.match(setup.captureCharFrame(), /Optional instructions/);
        assert.match(setup.captureCharFrame(), /Enter: return to preview/);
        await setup.mockInput.typeText("q d y w");
        setup.mockInput.pressEnter({ shift: true });
        await setup.mockInput.pasteBracketedText("line two\r\nc y\nm");
        assert.equal(calls.filter((call) => call.operation === "describe").length, 1);
        setup.mockInput.pressEnter();
        setup.mockInput.pressEnter(); // Same input batch may reveal, but must never accept, preview.
        await setup.flush();
        assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
        assert.match(setup.captureCharFrame(), /Enter: START \| Esc: cancel/);
        assert.equal(calls.some((call) => call.operation === "dispatch"), false);
        setup.mockInput.pressKey("\x1b[13;1:2u"); // Kitty's actual held-key repeat sequence.
        await setup.flush();
        assert.equal(calls.some((call) => call.operation === "dispatch"), false);
        setup.mockInput.pressEnter();
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.match(setup.captureCharFrame(), /STARTING/);
        assert.equal(calls.filter((call) => call.operation === "dispatch").length, 1);
        assert.equal(dispatchedPrompt, "q d y w\nline two\nc y\nm");
        const summary = summaryFor(104, role);
        const accepted: DispatchAccepted = {
          schemaVersion: 1, requestId: "accepted", operation: "accepted", dispatchId: "44444444-4444-4444-8444-444444444444",
          repositoryIdentity: summary.repositoryIdentity, role, pullRequestId: 104,
          capabilityPolicyDigest: summary.capabilityPolicyDigest, prStateFingerprint: summary.prStateFingerprint,
          childProcessId: 42, eventLogPath: join(process.cwd(), "unobserved-test-events.jsonl"),
        };
        accept(accepted);
        await setup.flush();
        assert.match(setup.captureCharFrame(), /STARTED \/ RUNNING/);
        assert.match(setup.captureCharFrame(), /Child PID 42 \| elapsed/);
        assert.match(setup.captureCharFrame(), /Waiting for first progress/);
        assert.match(setup.captureCharFrame(), /c: cancel this run/);
        setup.mockInput.pressEnter();
        setup.mockInput.pressEnter();
        assert.equal(calls.filter((call) => call.operation === "dispatch").length, 1);
        const event = (sequence: number, type: string, data: Record<string, unknown>, overrides = {}) => parseAgentEvent({
          schemaVersion: 3, agent: role, instanceId: "manual-test", processId: 42, timestamp: new Date().toISOString(),
          sequence, eventType: type, pullRequestId: 104, repositoryIdentity: summary.repositoryIdentity,
          dispatch: { schemaVersion: 1, dispatchId: accepted.dispatchId, ownership: "tui", forceAnalysis: true },
          data, ...overrides,
        });
        reducer.apply(event(1, "work.completed", { result: "failed" }, { instanceId: "automatic", dispatch: null }));
        terminalListener?.({ schemaVersion: 1, requestId: "other", operation: "completed", dispatchId: "other", exitCode: 1 });
        await new Promise((resolve) => setTimeout(resolve, 1_050));
        await setup.renderOnce();
        assert.match(setup.captureCharFrame(), /Waiting for first progress/);
        reducer.apply(event(1, "agent.started", {}));
        reducer.apply(event(2, "phase.changed", { phase: "manual review in progress" }));
        await new Promise((resolve) => setTimeout(resolve, 1_050));
        await setup.renderOnce();
        assert.match(setup.captureCharFrame(), /Phase: manual review in progress/);
        setup.mockInput.pressKey("c");
        setup.mockInput.pressKey("c");
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.equal(cancelCount, 1);
        assert.match(setup.captureCharFrame(), /CANCELLING/);
        cancel({ schemaVersion: 1, requestId: "cancel", operation: "cancelled", dispatchId: accepted.dispatchId, result: "cancelled-cooperative" });
        await setup.flush();
        assert.match(setup.captureCharFrame(), /CANCELLED/);
        assert.match(setup.captureCharFrame(), /Enter or Esc: close/);
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
      }, width);
    }
  });

  test("fast terminal before accepted continuation is retained; exit zero cannot overwrite failed/blocked work", async (context) => {
    for (const outcome of ["unreported", "failed", "blocked"]) {
      const { broker, summaryFor } = await startFixture();
      let listener: ((value: DispatchTerminal) => void) | undefined;
      broker.subscribeTerminal = (value) => { listener = value; return () => { listener = undefined; }; };
      const dispatch = broker.dispatch;
      broker.dispatch = async (summary, prompt) => {
        const accepted = await dispatch(summary, prompt);
        listener?.({ schemaVersion: 1, requestId: "fast", operation: "completed", dispatchId: accepted.dispatchId, exitCode: 0 });
        return accepted;
      };
      await withStartRenderer(context, broker, async (setup, _history, reducer) => {
        await openManualAndDescribe(setup);
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.match(setup.captureCharFrame(), /FINISHED/);
        assert.match(setup.captureCharFrame(), /outcome was not reported/);
        if (outcome !== "unreported") {
          const summary = summaryFor(104, "reviewer");
          reducer.apply(parseAgentEvent({
            schemaVersion: 3, agent: "reviewer", instanceId: "fast", processId: 42, timestamp: new Date().toISOString(),
            sequence: 1, eventType: "work.completed", pullRequestId: 104, repositoryIdentity: summary.repositoryIdentity,
            dispatch: { schemaVersion: 1, dispatchId: "44444444-4444-4444-8444-444444444444", ownership: "tui", forceAnalysis: true },
            data: { result: outcome, reason: "Delivery unavailable", summary: "Manual completion summary" },
          }));
          await new Promise((resolve) => setTimeout(resolve, 1_050));
          await setup.renderOnce();
          assert.match(setup.captureCharFrame(), new RegExp(outcome.toUpperCase()));
          assert.match(setup.captureCharFrame(), /Manual completion summary/);
        }
      });
    }
  });

  test("broker loss and cancellation failure report uncertainty without claiming child exit", async (context) => {
    const { broker } = await startFixture();
    let failure = "";
    broker.cancel = async () => { throw new Error("transport lost"); };
    await withStartRenderer(context, broker, async (setup) => {
      await openManualAndDescribe(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      failure = "Broker closed";
      await new Promise((resolve) => setTimeout(resolve, 1_050));
      await setup.renderOnce();
      assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
      setup.mockInput.pressKey("c");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
      assert.match(setup.captureCharFrame(), /child exit is not confirmed/);
      setup.mockInput.pressEnter();
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
      assert.doesNotMatch(setup.captureCharFrame(), /FINISHED|CANCELLED/);
    }, 100, "operational", () => failure);
  });

test("PreviewOnly chrome locks widening even when a broker reports a delegable capability", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls } = createWideningBrokerFixture({
    role: "reviewer",
    delegableAvailable: ["EnableApprovalVote"],
  });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => (
      <App
        reducer={fixture.reducer}
        history={history}
        tailer={fixture.tailer}
        broker={broker}
        launchMode="preview"
      />
    ), { width: 140, height: 32, kittyKeyboard: true });
    await setup.renderOnce();
    assert.match(setup.captureCharFrame(), /PREVIEW/);
    setup.mockInput.pressKey("s");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /PreviewOnly is a terminal ceiling/);
    setup.mockInput.pressEscape();
    await setup.flush();

    await openManualAndDescribe(setup);
    assert.match(setup.captureCharFrame(), /Widening locked by PreviewOnly/);
    assert.match(setup.captureCharFrame(), /No PR comments or code pushes/);
    setup.mockInput.pressKey("w");
    await setup.flush();
    assert.equal(calls.includes("describe-widening:EnableApprovalVote"), false);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.equal(calls.filter((call) => call === "dispatch").length, 1);
    assert.match(setup.captureCharFrame(), /STARTED \/ RUNNING/);
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

for (const failure of [
  { name: "transport", error: new Error("lost acceptance response") },
  { name: "termination", error: new BrokerRejectionError("termination-failed", "Child exit is not confirmed.") },
]) {
  test(`unconfirmed start ${failure.name} failure stays uncertain and cannot be redispatched`, async (context) => {
    const { broker, calls } = await startFixture();
    const dispatch = broker.dispatch;
    broker.dispatch = async (summary, prompt) => {
      await dispatch(summary, prompt);
      throw failure.error;
    };
    await withStartRenderer(context, broker, async (setup) => {
      await openManualAndDescribe(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /START STATUS UNKNOWN/);
      assert.doesNotMatch(setup.captureCharFrame(), /NOT STARTED|REQUEST FAILED/);
      setup.mockInput.pressEnter();
      setup.mockInput.pressEscape();
      setup.mockInput.pressKey("m");
      await setup.flush();
      assert.equal(calls.filter((call) => call.operation === "dispatch").length, 1);
      assert.match(setup.captureCharFrame(), /START STATUS UNKNOWN/);
      assert.match(setup.captureCharFrame(), /q: quit and stop/);
    });
  });
}

test("confirmed startup rejection remains dismissible and preserves the actual error", async (context) => {
  const { broker } = await startFixture();
  broker.dispatch = async () => {
    throw new BrokerRejectionError("launch-failed", "Child exited before readiness.");
  };
  await withStartRenderer(context, broker, async (setup) => {
    await openManualAndDescribe(setup);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /NOT STARTED \/ REQUEST FAILED/);
    assert.match(setup.captureCharFrame(), /Child exited before readiness/);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
  });
});

test("widening RPCs exclusively own input; Enter cannot advance or mint during any in-flight challenge", async (context) => {
  const { broker, calls } = createWideningBrokerFixture();
  let release!: () => void;
  const pause = () => new Promise<void>((resolve) => { release = resolve; });
  const describe = broker.describeWidening!;
  const confirm = broker.confirmWideningPreview!;
  const mint = broker.confirmWideningMint!;
  broker.describeWidening = async (...args) => { await pause(); return describe(...args); };
  broker.confirmWideningPreview = async (...args) => { await pause(); return confirm(...args); };
  broker.confirmWideningMint = async (...args) => { await pause(); return mint(...args); };
  await withStartRenderer(context, broker, async (setup) => {
    await openManualAndDescribe(setup);
    for (const [key, label] of [
      ["w", "Requesting capability widening"],
      ["c", "Confirming widening preview"],
      ["y", "Minting capability widening"],
    ]) {
      setup.mockInput.pressKey(key!);
      await setup.flush();
      assert.match(setup.captureCharFrame(), new RegExp(label!));
      const before = calls.length;
      for (const input of ["\r", "y", "d", "c", "w", "\x1b"]) setup.mockInput.pressKey(input);
      await setup.flush();
      assert.equal(calls.length, before);
      assert.equal(calls.includes("dispatch"), false);
      release();
      await setup.flush();
    }
    assert.equal(calls.filter((call) => call === "confirm-widening-mint").length, 1);
    assert.equal(calls.includes("dispatch"), false);
    assert.match(setup.captureCharFrame(), /Enter: START/);
  });
});

test("ID Enter loads the keyed preview, but no Enter can dispatch before its first rendered frame", async (context) => {
  const { broker, calls, summaryFor } = await startFixture();
  let release!: (value: CapabilitySummary) => void;
  broker.describe = async () => new Promise<CapabilitySummary>((resolve) => { release = resolve; });
  await withStartRenderer(context, broker, async (setup) => {
    setup.mockInput.pressKey("m");
    await setup.mockInput.typeText("104");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Preparing preview/);
    const frame = setup.renderer.frameId;
    release(summaryFor(104, "reviewer"));
    for (let i = 0; i < 5; i++) await Promise.resolve();
    assert.equal(setup.renderer.frameId, frame);
    setup.mockInput.pressEnter();
    assert.equal(calls.some((call) => call.operation === "dispatch"), false);
    await setup.flush();
    assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.equal(calls.filter((call) => call.operation === "dispatch").length, 1);
  });
});

test("confirmed exits leave Current and Live, but canonical and legacy diagnostics remain accessible in History", async (context) => {
  for (const width of [70, 100, 140]) {
    const { broker, summaryFor } = await startFixture();
    await withStartRenderer(context, broker, async (setup, history, reducer) => {
      const summary = summaryFor(104, "reviewer");
      const timestamp = new Date(Date.now() - 60_000).toISOString();
      const source = join(process.cwd(), "retained-run.jsonl");
      reducer.registerLocalStream({ eventLogPath: source, processId: 42, role: "reviewer" });
      const started = parseAgentEvent({
        schemaVersion: 3, agent: "reviewer", instanceId: "exited-canonical", processId: 42,
        timestamp, sequence: 1, eventType: "agent.started", pullRequestId: 104,
        repositoryIdentity: summary.repositoryIdentity, data: { repository: "repo", title: "Retained context" },
      });
      reducer.apply(started, source);
      history.apply(started);
      reducer.apply(parseAgentEvent({
        ...started, sequence: 2, eventType: "candidate.selected", data: { title: "Retained context", author: "Ada" },
      }), source);
      reducer.apply(parseAgentEvent({
        ...started, schemaVersion: 2, repositoryIdentity: null, instanceId: "exited-legacy", pullRequestId: 0,
      }), source);
      reducer.apply(parseAgentEvent({ ...started, instanceId: "alive-warning", processId: 43 }), source);
      await reducer.observeProcesses(async (pid) => pid === 42 ? "absent" : "present");
      await new Promise((resolve) => setTimeout(resolve, 1_050));
      assert.equal(reducer.list(Date.now(), undefined, "live").length, 0);
      setup.mockInput.pressKey("l");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /INSTANCES 1/);
      assert.match(setup.captureCharFrame(), /Stale \/ stale/);
      assert.doesNotMatch(setup.captureCharFrame(), /exited-c|exited-l/);
      setup.mockInput.pressKey("f");
      await setup.flush();
      if (width !== 100) {
        assert.match(setup.captureCharFrame(), /EXITED 2/);
        setup.mockInput.pressArrow("down"); // First exit, after the real PR projection row.
      } else assert.match(setup.captureCharFrame(), /INSTANCES 2/);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /Process exit observed/);
      assert.match(setup.captureCharFrame(), /Interrupted \/ outcome unknown/);
      assert.match(setup.captureCharFrame(), /retained-run.jsonl/);
      assert.match(setup.captureCharFrame(), /Retained context/);
      setup.mockInput.pressKey("e");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /candidate.selected/);
      setup.mockInput.pressEscape();
      setup.mockInput.pressEscape();
      await setup.flush();
      setup.mockInput.pressArrow("down");
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /Process exit observed/);
      assert.match(setup.captureCharFrame(), /none selected/);
      assert.equal(history.list().length, 1, "legacy archive rows never synthesize canonical History");
    }, width);
  }
});

test("archiving never detaches the active accepted manual panel or fabricates a successful outcome", async (context) => {
  const { broker, summaryFor } = await startFixture();
  await withStartRenderer(context, broker, async (setup, _history, reducer) => {
    await openManualAndDescribe(setup);
    setup.mockInput.pressEnter();
    await setup.flush();
    const summary = summaryFor(104, "reviewer");
    const timestamp = new Date(Date.now() - 60_000).toISOString();
    reducer.apply(parseAgentEvent({
      schemaVersion: 3, agent: "reviewer", instanceId: "manual-exited", processId: 42,
      timestamp, sequence: 1, eventType: "agent.started", pullRequestId: 104,
      repositoryIdentity: summary.repositoryIdentity,
      dispatch: { schemaVersion: 1, dispatchId: "44444444-4444-4444-8444-444444444444", ownership: "tui", forceAnalysis: true },
      data: {},
    }), join(process.cwd(), "unobserved-test-events.jsonl"));
    await reducer.observeProcesses(async () => "absent");
    assert.equal(reducer.list(Date.now(), undefined, "current").length, 0);
    await new Promise((resolve) => setTimeout(resolve, 1_050));
    await setup.renderOnce();
    assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
    assert.match(setup.captureCharFrame(), /EXITED \/ OUTCOME UNKNOWN/);
    assert.match(setup.captureCharFrame(), /Child PID 42/);
    assert.doesNotMatch(setup.captureCharFrame(), /FINISHED|READY TO START/);
  });
});

test("an unknown-origin live row repaints as a stale warning and never probes its locally absent PID", async (context) => {
  const { broker } = await startFixture();
  await withStartRenderer(context, broker, async (setup, _history, reducer) => {
    reducer.apply(parseAgentEvent({
      schemaVersion: 2, agent: "reviewer", instanceId: "live-stale", processId: 42,
      timestamp: new Date().toISOString(), sequence: 1, eventType: "agent.started",
      data: { repository: "repo" },
    }));
    await waitForFrame(setup, /Live \/ running/);
    const state = reducer.get("reviewer:live-stale")!;
    state.lastHeartbeatMs -= 60_000;
    state.lastEventMs -= 60_000;
    let probes = 0;
    await reducer.observeProcesses(async () => { probes++; return "absent"; });
    assert.equal(probes, 0);
    assert.equal(state.processOrigin, "unknown");
    await new Promise((resolve) => setTimeout(resolve, 1_050));
    await setup.renderOnce();
    assert.match(setup.captureCharFrame(), /INSTANCES 0/);
    setup.mockInput.pressKey("l");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Stale \/ stale/);
    assert.match(setup.captureCharFrame(), /INSTANCES 1/);
    assert.doesNotMatch(setup.captureCharFrame(), /Process exit observed/);
  });
});

test("state contention tells either requested role to wait and retry, retains the typed reason, and never queues work", async (context) => {
    for (const role of ["reviewer", "review-handler"] as const) {
      const { broker } = await startFixture();
      let attempts = 0;
      broker.dispatch = async () => {
        attempts++;
        throw new BrokerRejectionError("already-running", "state-contended: repository state is busy");
      };
      await withStartRenderer(context, broker, async (setup) => {
        await openManualAndDescribe(setup, role);
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.match(setup.captureCharFrame(), new RegExp(`Another ${role === "reviewer" ? "Reviewer" : "Review Handler"} is using`));
        assert.match(setup.captureCharFrame(), /finish, then retry/);
        assert.match(setup.captureCharFrame(), /state-contended/);
        assert.match(setup.captureCharFrame(), /NOT STARTED \/ REQUEST FAILED/);
        assert.equal(attempts, 1);
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
        assert.equal(attempts, 1);
      }, 70);
    }
});

async function waitForFrame(setup: TestRendererSetup, expected: RegExp): Promise<void> {
  const deadline = Date.now() + 3_000;
  do {
    await setup.flush();
    if (expected.test(setup.captureCharFrame())) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  } while (Date.now() < deadline);
  assert.match(setup.captureCharFrame(), expected);
}

async function withSimpleRenderer(
  context: TestContext,
  run: (setup: TestRendererSetup, reducer: OperationsReducer, history: PullRequestHistoryProjection) => Promise<void>,
  options: Partial<Omit<AppProps, "tailer">> & { width?: number; height?: number } = {},
): Promise<void> {
  const fixture = createFixture();
  const reducer = options.reducer ?? new OperationsReducer();
  const history = options.history ?? new PullRequestHistoryProjection();
  let setup: TestRendererSetup | undefined;
  try {
    setup = await testRender(() => <App {...options} reducer={reducer} history={history} tailer={fixture.tailer} />,
      { width: options.width ?? 100, height: options.height ?? 24, kittyKeyboard: true });
    await setup.renderOnce();
    await run(setup, reducer, history);
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
}

function simpleLiveEvent(instanceId: string, prId: number, sequence = 1, overrides: Partial<AgentEvent> = {}): AgentEvent {
  return parseAgentEvent({
    ...historyEvent("101", prId, sequence, { timestamp: new Date().toISOString() }),
    instanceId, processId: 42, eventType: "candidate.selected",
    data: { title: `Live work ${prId}`, repository: "contoso/repo" }, ...overrides,
  });
}

function simplePanel(setup: TestRendererSetup, id: string): BoxRenderable {
  const panel = setup.renderer.root.findDescendantById(id);
  assert.ok(panel instanceof BoxRenderable, `Missing Simple panel: ${id}`);
  return panel;
}

function simplePanelText(setup: TestRendererSetup, id: string): string {
  const panel = simplePanel(setup, id);
  return setup.captureCharFrame().split("\n").slice(panel.screenY, panel.screenY + panel.height)
    .map((row) => row.slice(panel.screenX, panel.screenX + panel.width)).join("\n");
}

test("Simple presentation keeps unknown outcomes honest and all capability names available", () => {
  const reducer = new OperationsReducer();
  reducer.apply(simpleLiveEvent("one", 104));
  reducer.apply(simpleLiveEvent("two", 104));
  const rows = reducer.list(Date.now(), undefined, "live").map(simpleInstanceRow);
  assert.equal(rows.length, 2);
  assert.notEqual(rows[0]!.key, rows[1]!.key, "same PID and PR do not merge instance identities");
  assert.ok(rows.every((row) => row.details.includes("Outcome: Not reported")));
  assert.equal(simpleCapability("EnablePush"), "Code pushes");
  assert.equal(simpleCapability("New actual capability"), "New actual capability");
  assert.equal(selectionWindow(9, 3), 7);
  assert.equal(selectionWindow(0, 0), 0);
});

test("Simple boxed sidebar has separate native bounds and visible focus at 100 and 140 columns, including eight rows", { timeout: 20_000 }, async (context) => {
  for (const width of [100, 140]) for (const height of [8, 16]) {
    const fixture = await automationFixture();
    const reducer = new OperationsReducer();
    reducer.apply(simpleLiveEvent("boxed-reviewer-private", 104));
    reducer.apply(simpleLiveEvent("boxed-handler-private", 2147483647, 1, { agent: "review-handler" }));
    await withSimpleRenderer(context, async (setup) => {
      await waitForFrame(setup, /Auto: Both/);
      const ordered = reducer.list(Date.now(), undefined, "live");
      const handlerIndex = ordered.findIndex((state) => state.agent === "review-handler");
      assert.ok(handlerIndex >= 0);
      for (let index = 0; index < handlerIndex; index++) setup.mockInput.pressArrow("down");
      await setup.flush();
      const rail = simplePanel(setup, "simple-agent-sidebar");
      const content = simplePanel(setup, "simple-main-content");
      assert.equal(rail.border, true);
      assert.equal(content.border, true);
      assert.ok(rail.width >= 40 && rail.width <= 42);
      assert.equal(rail.screenX, 0);
      assert.equal(content.screenX, rail.screenX + rail.width + 1);
      assert.equal(content.screenY, rail.screenY);
      assert.equal(content.height, rail.height);
      assert.ok(rail.height >= 4);
      assert.ok(content.width >= 55);
      assert.ok(content.screenX + content.width <= width);
      assert.ok(rail.screenY + rail.height < height);
      assert.notDeepEqual(rail.borderColor.toInts(), content.borderColor.toInts());
      const railFocusColor = rail.borderColor.toInts();
      assert.match(simplePanelText(setup, "simple-agent-sidebar"), /Review Handler \| PR #2147483647/);
      assert.ok(simplePanelText(setup, "simple-agent-sidebar").includes(ordered[handlerIndex]!.status));
      assert.match(simplePanelText(setup, "simple-main-content"), /SELECTION - Enter details/);
      let frame = setup.captureCharFrame();
      for (const label of ["m Start agent", "h History", "a Advanced", "q Quit", "r Scan now", "OPERATIONAL", "Auto: Both"]) {
        assert.ok(frame.includes(label), `Missing Simple control/status: ${label}`);
      }
      assert.doesNotMatch(frame, /FOCUS|INSPECTOR|METRICS|Tab role|boxed-handler-private|PID/);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.equal(simplePanel(setup, "simple-agent-sidebar").screenX, rail.screenX);
      assert.deepEqual(simplePanel(setup, "simple-main-content").borderColor.toInts(), railFocusColor);
      assert.notDeepEqual(simplePanel(setup, "simple-agent-sidebar").borderColor.toInts(), railFocusColor);
      assert.match(simplePanelText(setup, "simple-main-content"), /DETAILS/);
      assert.match(setup.captureCharFrame(), /Esc Back/);
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.equal(setup.renderer.root.findDescendantById("simple-detail-scroll"), undefined);
      assert.match(simplePanelText(setup, "simple-main-content"), /SELECTION/);
      assert.deepEqual(simplePanel(setup, "simple-agent-sidebar").borderColor.toInts(), railFocusColor);
      if (height === 8) {
        setup.mockInput.pressKey("s");
        await setup.flush();
        assert.match(setup.captureCharFrame(), /Press a for Advanced/);
        assert.equal(setup.renderer.root.findDescendantById("simple-agent-sidebar"), undefined);
        assert.equal(simplePanel(setup, "simple-agent-list").width, width);
        assert.doesNotMatch(setup.captureCharFrame(), /SETTINGS|INSPECTOR/);
      }
      setup.mockInput.pressKey("m");
      await setup.flush();
      frame = setup.captureCharFrame();
      assert.match(frame, /START AGENT BY PR ID/);
      assert.equal(setup.renderer.root.findDescendantById("simple-agent-sidebar"), undefined);
      assert.equal(setup.renderer.root.findDescendantById("simple-main-content"), undefined);
      assert.doesNotMatch(frame, /r Scan now/);
    }, { broker: fixture.broker, reducer, width, height, launchMode: "operational" });
  }
});

test("Simple boxed sidebar keeps the 70-column full-width list and Enter/Esc drill-down at eight rows", async (context) => {
  for (const height of [8, 16]) {
    const fixture = await automationFixture();
    const reducer = new OperationsReducer();
    reducer.apply(simpleLiveEvent("narrow-box-private", 104));
    await withSimpleRenderer(context, async (setup) => {
      await waitForFrame(setup, /Auto: Both/);
      assert.equal(setup.renderer.root.findDescendantById("simple-agent-sidebar"), undefined);
      assert.equal(setup.renderer.root.findDescendantById("simple-main-content"), undefined);
      const list = simplePanel(setup, "simple-agent-list");
      assert.equal(list.width, 70);
      assert.equal(list.screenX, 0);
      assert.equal(list.border, true);
      assert.match(simplePanelText(setup, "simple-agent-list"), /Reviewer \| PR #104/);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.equal(setup.renderer.root.findDescendantById("simple-agent-list"), undefined);
      assert.equal(simplePanel(setup, "simple-main-content").width, 70);
      assert.match(setup.captureCharFrame(), /DETAILS/);
      assert.match(setup.captureCharFrame(), /Esc Back/);
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.equal(simplePanel(setup, "simple-agent-list").width, 70);
      assert.equal(setup.renderer.root.findDescendantById("simple-main-content"), undefined);
      assert.match(setup.captureCharFrame(), /r Scan now/);
    }, { broker: fixture.broker, reducer, width: 70, height });
  }
});

test("Simple boxed History keeps canonical details pinned across side-by-side reorders, resize and eviction", { timeout: 20_000 }, async (context) => {
  for (const width of [100, 140]) {
    const history = new PullRequestHistoryProjection(2);
    history.apply(historyEvent("101", 104, 1, { repositoryName: "selected", title: "Chosen canonical PR" }));
    await withSimpleRenderer(context, async (setup) => {
      setup.mockInput.pressKey("h");
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(simplePanelText(setup, "simple-agent-sidebar"), /HISTORY/);
      assert.match(simplePanelText(setup, "simple-main-content"), /contoso\/selected \/ PR #104/);
      history.apply(historyEvent("202", 104, 2, { repositoryName: "other", title: "Other canonical PR" }));
      history.apply(historyEvent("101", 104, 3, { role: "review-handler", repositoryName: "selected", title: "Pinned canonical update" }));
      await waitForFrame(setup, /Pinned canonical update/);
      assert.match(simplePanelText(setup, "simple-main-content"), /Review Handler: handled/);
      assert.doesNotMatch(simplePanelText(setup, "simple-main-content"), /Other canonical PR|contoso\/other/);
      setup.renderer.resize(70, 16);
      await setup.flush();
      assert.equal(setup.renderer.root.findDescendantById("simple-agent-sidebar"), undefined);
      assert.match(simplePanelText(setup, "simple-main-content"), /contoso\/selected \/ PR #104/);
      setup.renderer.resize(width, 16);
      await setup.flush();
      assert.ok(simplePanel(setup, "simple-agent-sidebar").width < width);
      assert.match(simplePanelText(setup, "simple-main-content"), /contoso\/selected \/ PR #104/);
      history.apply(historyEvent("202", 104, 4, { repositoryName: "other" }));
      history.apply(historyEvent("303", 105, 5, { repositoryName: "newest" }));
      await waitForFrame(setup, /Selected history is no longer available/);
      const detail = simplePanelText(setup, "simple-main-content");
      assert.match(detail, /contoso\/selected \/ PR #104/);
      assert.doesNotMatch(detail, /contoso\/other|contoso\/newest|PR #105/);
      assert.match(simplePanelText(setup, "simple-agent-sidebar"), /PR #105/);
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.match(simplePanelText(setup, "simple-main-content"), /SELECTION/);
      assert.match(simplePanelText(setup, "simple-main-content"), /PR #105/);
    }, { history, width, height: 16 });
  }
});

test("Simple boxed sidebar scrolls selection while Enter transfers scrolling to pinned details", async (context) => {
  const reducer = new OperationsReducer();
  for (let index = 0; index < 8; index++) {
    reducer.apply(simpleLiveEvent(`boxed-scroll-${index}`, 104 + index, 1, {
      data: { title: `${"Readable selected title ".repeat(6)}BOXEDEND`, repository: "contoso/repo" },
    }));
  }
  await withSimpleRenderer(context, async (setup) => {
    const ordered = reducer.list(Date.now(), undefined, "live");
    for (let index = 1; index < ordered.length; index++) setup.mockInput.pressArrow("down");
    await setup.flush();
    const selectedPr = ordered.at(-1)!.pullRequestId;
    const before = simplePanelText(setup, "simple-agent-sidebar");
    assert.match(before, new RegExp(`> Reviewer \\| PR #${selectedPr}`));
    setup.mockInput.pressEnter();
    await setup.flush();
    let observed = simplePanelText(setup, "simple-main-content");
    for (let index = 0; index < 20; index++) {
      setup.mockInput.pressArrow("down");
      await setup.flush();
      observed += simplePanelText(setup, "simple-main-content");
      assert.equal(simplePanelText(setup, "simple-agent-sidebar"), before);
    }
    assert.match(observed, /BOXEDEND/);
    assert.match(setup.captureCharFrame(), /Esc Back/);
    assert.doesNotMatch(setup.captureCharFrame(), /FOCUS|INSPECTOR|Tab role/);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.equal(setup.renderer.root.findDescendantById("simple-detail-scroll"), undefined);
    assert.match(simplePanelText(setup, "simple-main-content"), new RegExp(`PR #${selectedPr}`));
  }, { reducer, width: 100, height: 8 });
});

for (const width of [70, 100, 140]) {
  test(`Simple defaults, basic footer, authority and details fit ${width} columns and short heights`, async (context) => {
    for (const height of [12, 24]) {
      const reducer = new OperationsReducer();
      reducer.apply(simpleLiveEvent("private-instance-identifier", 104));
      await withSimpleRenderer(context, async (setup) => {
        let frame = setup.captureCharFrame();
        assert.match(frame, /OPERATIONAL/);
        assert.match(frame, /LIVE AGENTS/);
        assert.match(frame, /Reviewer \| PR #104/);
        assert.match(frame, /m Start agent \| h History \| a Advanced \| q Quit/);
        assert.doesNotMatch(frame, /INSPECTOR|FOCUS|CURRENT RUN|METRICS|private-instance|PID|v1:github|Tab role|Del|STATUS:/);
        setup.mockInput.pressEnter();
        await setup.flush();
        frame = setup.captureCharFrame();
        assert.match(frame, /DETAILS/);
        assert.match(frame, /contoso\/repo \/ PR #104/);
        assert.match(frame, /Esc Back/);
        setup.mockInput.pressEscape();
        setup.mockInput.pressKey("h");
        await setup.flush();
        assert.match(setup.captureCharFrame(), /h Live/);
        setup.mockInput.pressKey("a");
        await setup.flush();
        assert.match(setup.captureCharFrame(), /FOCUS/);
        setup.mockInput.pressKey("a");
        await setup.flush();
        assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
        assert.doesNotMatch(setup.captureCharFrame(), /FOCUS|INSPECTOR|DETAILS/);
      }, { width, height, reducer, launchMode: "operational" });
    }
  });
}

test("Simple details pin exact instance identity across insertions, status updates and removal", async (context) => {
  const reducer = new OperationsReducer();
  reducer.apply(simpleLiveEvent("selected", 104));
  await withSimpleRenderer(context, async (setup) => {
    setup.mockInput.pressEnter();
    await setup.flush();
    reducer.apply(simpleLiveEvent("newer", 999));
    reducer.apply(simpleLiveEvent("selected", 104, 2, {
      eventType: "phase.changed", data: { phase: "Pinned activity after reorder" },
    }));
    await waitForFrame(setup, /Pinned activity after reorder/);
    assert.match(simplePanelText(setup, "simple-main-content"), /PR #104/);
    assert.doesNotMatch(simplePanelText(setup, "simple-main-content"), /PR #999/);
    reducer.apply(simpleLiveEvent("selected", 104, 3, { eventType: "agent.stopped", data: {} }));
    await waitForFrame(setup, /Selected agent is no longer live/);
    assert.match(simplePanelText(setup, "simple-main-content"), /contoso\/repo \/ PR #104/);
    assert.doesNotMatch(simplePanelText(setup, "simple-main-content"), /PR #999/);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /> Reviewer \| PR #999/);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(simplePanelText(setup, "simple-main-content"), /PR #999/);
  }, { reducer });
});

test("Simple canonical History details survive reorder and explicitly report eviction without substituting same-numbered PRs", async (context) => {
  const history = new PullRequestHistoryProjection(2);
  history.apply(historyEvent("101", 104, 1, { repositoryName: "selected", title: "Selected history" }));
  await withSimpleRenderer(context, async (setup) => {
    setup.mockInput.pressKey("h");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /contoso\/selected \/ PR #104/);
    assert.match(setup.captureCharFrame(), /Reviewer: reviewed/);
    history.apply(historyEvent("202", 104, 2, { repositoryName: "other", title: "Other repository" }));
    history.apply(historyEvent("101", 104, 3, { role: "review-handler", repositoryName: "selected", title: "Updated selected history" }));
    await waitForFrame(setup, /Review Handler: handled/);
    assert.match(setup.captureCharFrame(), /Updated selected history/);
    assert.doesNotMatch(setup.captureCharFrame(), /Other repository/);
    history.apply(historyEvent("202", 104, 4, { repositoryName: "other" }));
    history.apply(historyEvent("303", 105, 5));
    await waitForFrame(setup, /Selected history is no longer available/);
    assert.match(setup.captureCharFrame(), /contoso\/selected \/ PR #104/);
    assert.doesNotMatch(setup.captureCharFrame(), /contoso\/other/);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /PR #105/);
  }, { history, width: 70, height: 16 });
});

test("Simple lists scroll selection into view and returning from Advanced clears incompatible filters", async (context) => {
  const reducer = new OperationsReducer();
  for (let index = 1; index <= 12; index++) reducer.apply(simpleLiveEvent(`instance-${index}`, 100 + index));
  reducer.apply(simpleLiveEvent("handler", 222, 1, { agent: "review-handler" }));
  const history = new PullRequestHistoryProjection();
  history.apply(historyEvent("101", 104, 1));
  await withSimpleRenderer(context, async (setup) => {
    const ordered = reducer.list(Date.now(), undefined, "live");
    for (let index = 0; index < ordered.length - 1; index++) setup.mockInput.pressArrow("down");
    await setup.flush();
    const last = ordered.at(-1)!;
    assert.match(setup.captureCharFrame(), new RegExp(`> ${last.agent === "reviewer" ? "Reviewer" : "Review Handler"} \\| PR #${last.pullRequestId}`));
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), new RegExp(`PR #${last.pullRequestId}`));
    setup.mockInput.pressEscape();
    setup.mockInput.pressKey("\u001b[5~");
    await setup.flush();
    assert.doesNotMatch(setup.captureCharFrame(), new RegExp(`> .*PR #${last.pullRequestId}\\b`));
    setup.mockInput.pressKey("a");
    setup.mockInput.pressTab();
    setup.mockInput.pressKey("f", { shift: true });
    setup.mockInput.pressKey("/");
    await setup.mockInput.typeText("missing-filter");
    setup.mockInput.pressEnter();
    setup.mockInput.pressKey("a");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
    assert.doesNotMatch(setup.captureCharFrame(), /FOCUS|INSPECTOR|missing-filter/);
    setup.mockInput.pressKey("h");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /PR #104/);
    setup.mockInput.pressKey("h");
    await setup.flush();
    let liveFrames = setup.captureCharFrame();
    for (let index = 0; index < ordered.length; index++) {
      setup.mockInput.pressArrow("down");
      await setup.flush();
      liveFrames += setup.captureCharFrame();
    }
    assert.match(liveFrames, /Review Handler \| PR #222/);
  }, { reducer, history, width: 70, height: 12 });
});

test("Simple gates Advanced keys and keeps palette and help bounded at short widths", async (context) => {
  for (const width of [70, 100, 140]) for (const height of [8, 12]) {
    const { broker, calls } = await startFixture();
    await withSimpleRenderer(context, async (setup) => {
      for (const key of ["s", "i", "e", "f", "w", "l", "DELETE", "x", "/", "o", "1"]) {
        setup.mockInput.pressKey(key);
        await setup.flush();
        assert.match(setup.captureCharFrame(), /Press a for Advanced/);
        assert.doesNotMatch(setup.captureCharFrame(), /SETTINGS|INSPECTOR|RAW EVENTS|WIDENING/);
      }
      setup.mockInput.pressKey("p", { ctrl: true });
      await setup.flush();
      assert.match(setup.captureCharFrame(), /DASHBOARD COMMANDS/);
      assert.match(setup.captureCharFrame(), /> Start Agent by PR ID/);
      assert.doesNotMatch(setup.captureCharFrame(), /Settings|inspector|Restore|Widen|failed instance/);
      setup.mockInput.pressKey("a");
      for (let index = 0; index < 5; index++) setup.mockInput.pressKey("\u001b[6~");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /> Quit/);
      setup.mockInput.pressEscape();
      setup.mockInput.pressKey("?");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /HELP - SIMPLE/);
      setup.mockInput.pressKey("a");
      for (let index = 0; index < 30; index++) setup.mockInput.pressKey("\u001b[6~");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /outcomes stay unknown/);
      assert.match(setup.captureCharFrame(), /Esc close/);
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
      assert.deepEqual(calls, []);
      setup.mockInput.pressKey("p", { ctrl: true });
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
    }, { broker, width, height });
  }
});

test("Simple two-Enter start works for both roles, both views and every width without changing authority", { timeout: 30_000 }, async (context) => {
  for (const width of [70, 100, 140]) for (const role of ["reviewer", "review-handler"] as const) for (const history of [false, true]) {
    const { broker, calls } = await startFixture();
    await withSimpleRenderer(context, async (setup, _reducer, projection) => {
      if (history) setup.mockInput.pressKey("h");
      setup.mockInput.pressKey("m");
      if (role === "review-handler") setup.mockInput.pressTab();
      await setup.mockInput.typeText("912");
      setup.mockInput.pressEnter();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
      assert.match(setup.captureCharFrame(), new RegExp(`configured/${role} / PR #912`));
      assert.match(setup.captureCharFrame(), /OPERATIONAL/);
      assert.doesNotMatch(setup.captureCharFrame(), /Optional instructions \(|Mandatory|force.analysis|vote.grant|PID|Widen/);
      assert.deepEqual(calls.map((call) => call.operation), ["profile-current", "describe"]);
      setup.mockInput.pressKey("\u001b[13;1:2u");
      await setup.flush();
      assert.equal(calls.filter((call) => call.operation === "dispatch").length, 0, "held Enter cannot start");
      setup.mockInput.pressKey("a");
      setup.mockInput.pressTab();
      setup.mockInput.pressEnter();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.equal(calls.filter((call) => call.operation === "dispatch").length, 1);
      assert.equal(calls.at(-1)!.summary!.role, role);
      assert.match(setup.captureCharFrame(), /STARTED/);
      assert.match(setup.captureCharFrame(), /Waiting for first progress/);
      assert.match(setup.captureCharFrame(), /Elapsed:/);
      assert.doesNotMatch(setup.captureCharFrame(), /PID|FOCUS|INSPECTOR/);
      assert.equal(projection.list().length, 0);
    }, { broker, width, height: 20, launchMode: "operational" });
  }
});

test("Simple long preview exposes complete actions and constraints by scrolling while Start and Cancel remain reachable", async (context) => {
  for (const width of [70, 100, 140]) for (const height of [8, 12]) {
    const { broker } = await startFixture();
    const describe = broker.describe;
    const longAction = `Unfamiliar actual action ${"with explicitly scoped behavior ".repeat(6)}ACTION-END`;
    const constraint = `Only the displayed repository and commit ${"must satisfy this dynamic restriction ".repeat(8)}CONSTRAINT-END`;
    broker.describe = async (...args) => ({
      ...await describe(...args), capabilities: ["EnableCodeChanges", "EnablePush", longAction],
      dynamicConstraints: [constraint],
    });
    await withSimpleRenderer(context, async (setup) => {
      await openManualAndDescribe(setup);
      let observed = setup.captureCharFrame();
      for (let index = 0; index < 35; index++) {
        setup.mockInput.pressArrow("down");
        await setup.flush();
        const frame = setup.captureCharFrame();
        observed += frame;
        assert.match(frame, /Enter: START/);
        assert.match(frame, /Esc: cancel/);
      }
      assert.match(observed, /Code changes/);
      assert.match(observed, /Code pushes/);
      assert.match(observed, /ACTION-END/);
      assert.match(observed, /CONSTRAINT-END/);
      for (let index = 0; index < 35; index++) setup.mockInput.pressKey("\u001b[5~");
      setup.mockInput.pressArrow("up");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /configured\/reviewer \/ PR #104/);
      for (let index = 0; index < 35; index++) setup.mockInput.pressKey("\u001b[6~");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /CONSTRAINT-END/);
      assert.match(setup.captureCharFrame(), /Enter: START/);
      assert.match(setup.captureCharFrame(), /Esc: cancel/);
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
    }, { broker, width, height });
  }
});

test("Simple 70x8 wrapped preview status leaves identity, actions and constraints recoverable by scrolling", async (context) => {
  for (const finish of ["enter", "escape"] as const) {
    const { broker, calls } = await startFixture();
    const describe = broker.describe;
    const constraint = "This run must stay within the displayed repository and commit. Check the current policy before writing comments. STATUS-CONSTRAINT-END.";
    broker.describe = async (...args) => ({ ...await describe(...args), dynamicConstraints: [constraint] });
    await withSimpleRenderer(context, async (setup) => {
      await openManualAndDescribe(setup);
      setup.mockInput.pressKey("w");
      await setup.flush();
      let observed = setup.captureCharFrame();
      for (let index = 0; index < 25; index++) {
        setup.mockInput.pressArrow("down");
        await setup.flush();
        const frame = setup.captureCharFrame();
        observed += frame;
        assert.match(frame, /NOT STARTED \/ READY TO START/);
        assert.match(frame, /Enter: START/);
        assert.match(frame, /Esc: cancel/);
      }
      assert.match(observed, /Capability widening is in Advanced/);
      assert.match(observed, /press a\./);
      assert.match(observed, /configured\/reviewer \/ PR #104/);
      assert.match(observed, /Agent: Reviewer/);
      assert.match(observed, /Unobserved PR 104/);
      assert.match(observed, /Finding comments/);
      assert.match(observed, /Thread replies/);
      assert.match(observed, /Summary comments/);
      assert.match(observed, /STATUS-CONSTRAINT-END/);
      assert.deepEqual(calls.map((call) => call.operation), ["profile-current", "describe"]);

      for (let index = 0; index < 25; index++) setup.mockInput.pressKey("\u001b[5~");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /Enter: START/);
      assert.match(setup.captureCharFrame(), /Esc: cancel/);
      if (finish === "enter") {
        setup.mockInput.pressEnter();
        await setup.flush();
        const dispatched = calls.filter((call) => call.operation === "dispatch");
        assert.equal(dispatched.length, 1);
        assert.equal(dispatched[0]!.summary!.prSnapshot.pullRequestId, 104);
        assert.equal(dispatched[0]!.summary!.role, "reviewer");
        assert.deepEqual(dispatched[0]!.summary!.dynamicConstraints, [constraint]);
        assert.match(setup.captureCharFrame(), /STARTED/);
      } else {
        setup.mockInput.pressEscape();
        await setup.flush();
        assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
        assert.equal(calls.filter((call) => call.operation === "dispatch").length, 0);
      }
    }, { broker, width: 70, height: 8, launchMode: "operational" });
  }
});

test("Simple 70x8 long terminal error remains fully reachable by scrolling with Enter and Esc available", async (context) => {
  for (const finish of ["enter", "escape"] as const) {
    const { broker } = await startFixture();
    const detail = "ERROR-BEGIN: Child exited before readiness. Verify the configured repository, role, permissions and startup settings before retrying. ERROR-END.";
    let attempts = 0;
    broker.dispatch = async () => {
      attempts++;
      throw new BrokerRejectionError("launch-failed", detail);
    };
    await withSimpleRenderer(context, async (setup) => {
      await openManualAndDescribe(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      const initial = setup.captureCharFrame();
      assert.match(initial, /NOT STARTED \/ REQUEST FAILED/);
      assert.doesNotMatch(initial, /ERROR-END/);
      let observed = initial;
      for (let index = 0; index < 25; index++) {
        setup.mockInput.pressArrow("down");
        await setup.flush();
        const frame = setup.captureCharFrame();
        observed += frame;
        assert.match(frame, /NOT STARTED \/ REQUEST FAILED/);
        assert.match(frame, /Enter or Esc: close/);
      }
      assert.match(observed, /ERROR-BEGIN/);
      assert.match(observed, /ERROR-END/);
      for (const word of detail.split(/\s+/)) assert.ok(observed.includes(word), `Missing error text: ${word}`);
      for (let index = 0; index < 25; index++) setup.mockInput.pressKey("\u001b[5~");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /Enter or Esc: close/);
      if (finish === "enter") setup.mockInput.pressEnter();
      else setup.mockInput.pressEscape();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
      assert.equal(attempts, 1);
    }, { broker, width: 70, height: 8, launchMode: "operational" });
  }
});

async function busyFixture(role: AgentRole = "reviewer") {
  const seed = await startFixture();
  const calls: string[] = [];
  const preparations: RunPrepared[] = [];
  const progressListeners = new Set<(value: RunProgress) => void>();
  const acceptedListeners = new Set<(value: ScheduledDispatchAccepted) => void>();
  const terminalListeners = new Set<(value: DispatchTerminal) => void>();
  let summary: CapabilitySummary = { ...seed.summaryFor(104, role), scheduling: { version: 1, scope: "current-launcher" } };
  let descriptions = 0;
  let queues = 0;
  const broker: DispatchBroker = {
    ...seed.broker,
    describe: async (key, prId, requestedRole) => {
      assert.equal(key, summary.repositoryIdentity.key);
      assert.equal(prId, 104);
      assert.equal(requestedRole, role);
      calls.push("describe");
      summary = { ...summary, dispatchDraftId: `22222222-2222-4222-8222-${String(++descriptions).padStart(12, "0")}` };
      return summary;
    },
    dispatch: async (value) => {
      calls.push(`dispatch:${value.dispatchDraftId}`);
      throw new BrokerRejectionError("already-running", "state-contended: repository state is busy");
    },
    prepareRun: async (value, mode, prompt) => {
      assert.equal(value.repositoryIdentity.key, summary.repositoryIdentity.key);
      assert.equal(prompt, "");
      calls.push(`prepare:${mode}`);
      const prepared: RunPrepared = {
        schemaVersion: 1, requestId: "prepare", operation: "run-prepared", schedulingVersion: 1,
        scope: "current-launcher", confirmationToken: `token-${preparations.length + 1}`,
        expiresAtUtc: new Date(Date.now() + 60_000).toISOString(),
        repositoryKey: value.repositoryIdentity.key, role: value.role, pullRequestId: value.prSnapshot.pullRequestId, mode,
        conflict: { kind: "automatic", workId: "current-work", generation: `generation-${preparations.length + 1}`, pullRequestId: 888 },
      };
      preparations.push(prepared);
      return prepared;
    },
    confirmRun: async (prepared): Promise<RunQueued> => {
      calls.push(`confirm:${prepared.confirmationToken}`);
      return { schemaVersion: 1, requestId: "confirm", operation: "run-queued", schedulingVersion: 1,
        queueId: `55555555-5555-4555-8555-${String(++queues).padStart(12, "0")}`, mode: prepared.mode };
    },
    cancelQueued: async (queueId) => {
      calls.push(`cancel-queued:${queueId}`);
      return { schemaVersion: 1, requestId: "cancel-queue", operation: "queue-cancelled", schedulingVersion: 1, queueId };
    },
    cancel: async (dispatchId) => {
      calls.push(`cancel-child:${dispatchId}`);
      return { schemaVersion: 1, requestId: "cancel", operation: "cancelled", dispatchId, result: "cancelled-cooperative" };
    },
    subscribeSchedule: (listener) => { progressListeners.add(listener); return () => { progressListeners.delete(listener); }; },
    subscribeScheduledAccepted: (listener) => { acceptedListeners.add(listener); return () => { acceptedListeners.delete(listener); }; },
    subscribeTerminal: (listener) => { terminalListeners.add(listener); return () => { terminalListeners.delete(listener); }; },
  };
  return {
    broker, calls, preparations, progressListeners, acceptedListeners,
    queueId: () => `55555555-5555-4555-8555-${String(queues).padStart(12, "0")}`,
    summary: () => summary,
    updateSummary: (patch: Partial<CapabilitySummary>) => { summary = { ...summary, ...patch }; },
    progress: (queueId: string, state: RunProgress["state"], code = "") => {
      const value: RunProgress = { schemaVersion: 1, requestId: "progress", operation: "run-progress",
        schedulingVersion: 1, queueId, state, code };
      for (const listener of progressListeners) listener(value);
    },
    acceptance: (queueId: string, patch: Partial<ScheduledDispatchAccepted> = {}): ScheduledDispatchAccepted => ({
      schemaVersion: 1, requestId: "scheduled", operation: "accepted", queueId,
      dispatchId: "44444444-4444-4444-8444-444444444444", repositoryIdentity: summary.repositoryIdentity,
      role: summary.role, pullRequestId: 104, capabilityPolicyDigest: summary.capabilityPolicyDigest,
      prStateFingerprint: summary.prStateFingerprint, childProcessId: 42,
      eventLogPath: join(process.cwd(), "unobserved-scheduled-test-events.jsonl"), ...patch,
    }),
    accept: (value: ScheduledDispatchAccepted) => { for (const listener of acceptedListeners) listener(value); },
    terminal: (value: DispatchTerminal) => { for (const listener of terminalListeners) listener(value); },
  };
}

async function openBusy(setup: TestRendererSetup, role: AgentRole = "reviewer"): Promise<void> {
  await openManualAndDescribe(setup, role);
  setup.mockInput.pressEnter();
  await setup.flush();
}

test("Busy UI prepares Replace inertly for both roles and modes, then requires a newly rendered explicit Enter", { timeout: 20_000 }, async (context) => {
  for (const width of [70, 100, 140]) for (const advanced of [false, true]) for (const role of ["reviewer", "review-handler"] as const) {
    const fixture = await busyFixture(role);
    await withSimpleRenderer(context, async (setup) => {
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      await openManualAndDescribe(setup, role);
      setup.mockInput.pressEnter();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /> Replace \/ run now/);
      assert.match(setup.captureCharFrame(), /PR #888 is busy/);
      assert.match(setup.captureCharFrame(), /Current launcher only/);
      assert.doesNotMatch(setup.captureCharFrame(), /STOPPING|QUEUED/);
      assert.deepEqual(fixture.calls.filter((call) => call.startsWith("prepare")), ["prepare:replace"]);
      assert.equal(fixture.calls.some((call) => call.startsWith("confirm")), false);
      setup.mockInput.pressKey("\u001b[13;1:2u");
      await setup.flush();
      assert.equal(fixture.calls.some((call) => call.startsWith("confirm")), false);
      setup.mockInput.pressEnter();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /QUEUED \/ NOT STARTED/);
      assert.equal(fixture.calls.filter((call) => call.startsWith("confirm")).length, 1);
      for (const [state, label] of [["quiescing", /STOPPING CURRENT WORK/], ["waiting-authority", /WAITING FOR AUTHORITY/],
        ["revalidating", /REVALIDATING/]] as const) {
        fixture.progress(fixture.queueId(), state);
        await setup.flush();
        assert.match(setup.captureCharFrame(), label);
      }
      assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
    }, { broker: fixture.broker, width, height: 30, launchMode: "operational" });
  }
});

test("Busy UI choice changes replace the binding; Run next waits the current PR and Back never confirms", async (context) => {
  for (const advanced of [false, true]) {
    const fixture = await busyFixture();
    await withSimpleRenderer(context, async (setup) => {
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      await openBusy(setup);
      setup.mockInput.pressTab();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /> Run next/);
      assert.match(setup.captureCharFrame(), /current PR, not the whole scan cycle/);
      assert.deepEqual(fixture.calls.filter((call) => call.startsWith("prepare:")), ["prepare:replace", "prepare:next"]);
      assert.equal(fixture.calls.some((call) => call.startsWith("confirm")), false);
      setup.mockInput.pressArrow("down");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /> Back/);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
      assert.equal(fixture.calls.some((call) => call.startsWith("confirm")), false);
      await openBusy(setup);
      setup.mockInput.pressTab();
      await setup.flush();
      const next = fixture.preparations.at(-1)!;
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.ok(fixture.calls.includes(`confirm:${next.confirmationToken}`));
      assert.match(setup.captureCharFrame(), /QUEUED \/ NOT STARTED/);
    }, { broker: fixture.broker, height: 32, launchMode: "operational" });
  }
});

test("Busy UI never exposes Replace for legacy, partially negotiated, foreign or mismatched ownership", async (context) => {
  for (const reason of ["legacy", "partial", "foreign", "mismatch"] as const) {
    const fixture = await busyFixture();
    if (reason === "legacy") delete fixture.summary().scheduling;
    if (reason === "partial") delete fixture.broker.subscribeScheduledAccepted;
    if (reason === "foreign") fixture.broker.prepareRun = async () => { throw new BrokerRejectionError("not-owner", "Not a verified current-launcher owner."); };
    if (reason === "mismatch") {
      const prepare = fixture.broker.prepareRun!;
      fixture.broker.prepareRun = async (...args) => ({ ...await prepare(...args), repositoryKey: "v1:github:999" });
    }
    await withSimpleRenderer(context, async (setup) => {
      await openBusy(setup);
      assert.match(setup.captureCharFrame(), /NOT STARTED \/ REQUEST FAILED/);
      assert.doesNotMatch(setup.captureCharFrame(), /Replace \/ run now|Run next/);
      if (reason === "foreign" || reason === "mismatch") assert.match(setup.captureCharFrame(), /nothing was stopped/);
      assert.equal(fixture.calls.some((call) => call.startsWith("confirm")), false);
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
    }, { broker: fixture.broker, height: 32 });
  }
});

test("Busy UI cancels inert preparation, ignores late proposals, and refreshes stale generations without confirming successors", async (context) => {
  const fixture = await busyFixture();
  const prepare = fixture.broker.prepareRun!;
  let release!: () => void;
  fixture.broker.prepareRun = async (...args) => { await new Promise<void>((resolve) => { release = resolve; }); return prepare(...args); };
  await withSimpleRenderer(context, async (setup) => {
    await openBusy(setup);
    assert.match(setup.captureCharFrame(), /CHECKING OWNED WORK/);
    assert.doesNotMatch(setup.captureCharFrame(), /STOPPING|> Replace/);
    setup.mockInput.pressEscape();
    await setup.flush();
    release();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
    fixture.broker.prepareRun = prepare;
  }, { broker: fixture.broker });
  const refreshed = await busyFixture();
  const confirm = refreshed.broker.confirmRun!;
  let attempts = 0;
  refreshed.broker.confirmRun = async (prepared) => {
    if (++attempts === 1) throw new BrokerRejectionError("schedule-stale", "Current work generation changed.");
    return confirm(prepared);
  };
  await withSimpleRenderer(context, async (setup) => {
    await openBusy(setup);
    const first = refreshed.preparations[0]!;
    setup.mockInput.pressEnter();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /> Replace \/ run now/);
    assert.equal(attempts, 1);
    assert.notEqual(refreshed.preparations.at(-1)!.conflict.generation, first.conflict.generation);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.equal(attempts, 2);
    assert.match(setup.captureCharFrame(), /QUEUED \/ NOT STARTED/);
  }, { broker: refreshed.broker });
});

test("Busy UI re-previews abandoned intents only after matching resumed, with fresh target and consent", { timeout: 20_000 }, async (context) => {
  for (const code of ["schedule-repreview-required", "schedule-expired", "schedule-stale", "schedule-interrupted",
    "policy-changed", "source-changed", "pr-state-changed", "repository-mismatch"]) {
    const fixture = await busyFixture();
    await withSimpleRenderer(context, async (setup) => {
      await openBusy(setup);
      const previous = fixture.summary();
      setup.mockInput.pressEnter();
      await setup.flush();
      fixture.updateSummary({ prSnapshot: { ...previous.prSnapshot, title: "Fresh changed target", sourceCommit: "f".repeat(40) },
        capabilityPolicyDigest: "e".repeat(64), capabilities: ["EnableSummaryComment"], mandatoryDenies: ["EnablePush", "EnableApprovalVote"] });
      fixture.progress(fixture.queueId(), "blocked", code);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /BLOCKED \/ WAITING FOR SLOT RELEASE/);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
      fixture.progress("unrelated", "resumed");
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
      fixture.progress(fixture.queueId(), "blocked", "schedule-interrupted");
      await setup.flush();
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1, "a second soft block still retains the slot");
      fixture.progress(fixture.queueId(), "resumed");
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
      assert.match(setup.captureCharFrame(), /Fresh changed target/);
      assert.match(setup.captureCharFrame(), /ffffffffffff/);
      assert.notEqual(fixture.summary().dispatchDraftId, previous.dispatchDraftId);
      assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 2);
      assert.ok(fixture.calls.includes(`dispatch:${fixture.summary().dispatchDraftId}`));
      assert.match(setup.captureCharFrame(), /> Replace \/ run now/);
    }, { broker: fixture.broker, height: 32 });
  }
});

test("Busy UI correlates early progress, acceptance and terminal before confirm continuation and preserves outcome on resume", async (context) => {
  const fixture = await busyFixture();
  const confirm = fixture.broker.confirmRun!;
  fixture.broker.confirmRun = async (prepared) => {
    const queued = await confirm(prepared);
    fixture.progress("unrelated", "blocked", "termination-failed");
    fixture.accept(fixture.acceptance("unrelated"));
    fixture.progress(queued.queueId, "revalidating");
    const accepted = fixture.acceptance(queued.queueId);
    fixture.accept(accepted);
    fixture.terminal({ schemaVersion: 1, requestId: "fast", operation: "completed", dispatchId: accepted.dispatchId, exitCode: 0 });
    fixture.progress(queued.queueId, "resumed");
    return queued;
  };
  await withSimpleRenderer(context, async (setup, reducer) => {
    await openBusy(setup);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /FINISHED \/ OUTCOME UNKNOWN/);
    assert.match(setup.captureCharFrame(), /Automatic work resumed/);
    assert.match(setup.captureCharFrame(), /outcome was not reported/);
    const summary = fixture.summary();
    reducer.apply(parseAgentEvent({
      ...simpleLiveEvent("scheduled-matched", 104), eventType: "work.completed", repositoryIdentity: summary.repositoryIdentity,
      dispatch: { schemaVersion: 1, dispatchId: fixture.acceptance(fixture.queueId()).dispatchId, ownership: "tui", forceAnalysis: true },
      data: { result: "failed", reason: "Delivery failed", summary: "Reported actual failure" },
    }));
    await waitForFrame(setup, /FAILED/);
    fixture.progress(fixture.queueId(), "resumed");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /FAILED/);
    assert.match(setup.captureCharFrame(), /Reported actual failure/);
    setup.mockInput.pressEscape();
    await setup.flush();
    fixture.accept(fixture.acceptance(fixture.queueId()));
    fixture.progress(fixture.queueId(), "quiescing");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
    assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
  }, { broker: fixture.broker, height: 32 });
  assert.equal(fixture.progressListeners.size, 0);
  assert.equal(fixture.acceptedListeners.size, 0);
});

test("Busy UI queued cancellation touches only the queued intent and cannot close before confirmation", async (context) => {
  const fixture = await busyFixture();
  const cancel = fixture.broker.cancelQueued!;
  let release!: () => void;
  fixture.broker.cancelQueued = async (queueId) => { await new Promise<void>((resolve) => { release = resolve; }); return cancel(queueId); };
  await withSimpleRenderer(context, async (setup) => {
    await openBusy(setup);
    setup.mockInput.pressEnter();
    await setup.flush();
    setup.mockInput.pressEscape();
    setup.mockInput.pressEscape();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /CANCELLING QUEUED REQUEST/);
    assert.equal(fixture.calls.some((call) => call.startsWith("cancel-child:")), false);
    release();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /CANCELLATION ACKNOWLEDGED \/ CLEANUP PENDING/);
    setup.mockInput.pressEscape();
    setup.mockInput.pressEnter();
    fixture.progress("unrelated", "resumed");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
    assert.doesNotMatch(setup.captureCharFrame(), /CANCELLED \/ NOT STARTED/);
    fixture.progress(fixture.queueId(), "resumed");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /CANCELLED \/ NOT STARTED/);
    assert.equal(fixture.calls.filter((call) => call.startsWith("cancel-queued:")).length, 1);
    setup.mockInput.pressEscape();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
  }, { broker: fixture.broker });
});

test("Busy UI resumed before the cancel reply waits for acknowledgment and never treats not-queued as cancellation", async (context) => {
  for (const acknowledged of [false, true]) {
    const fixture = await busyFixture();
    const cancel = fixture.broker.cancelQueued!;
    let release!: () => void;
    fixture.broker.cancelQueued = async (queueId) => {
      fixture.progress(queueId, "resumed");
      await new Promise<void>((resolve) => { release = resolve; });
      if (!acknowledged) throw new BrokerRejectionError("not-queued", "Intent already abandoned.");
      return cancel(queueId);
    };
    await withSimpleRenderer(context, async (setup) => {
      await openBusy(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      setup.mockInput.pressKey("c");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /CANCELLING QUEUED REQUEST/);
      setup.mockInput.pressEscape();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.doesNotMatch(setup.captureCharFrame(), /CANCELLED|LIVE AGENTS/);
      release();
      await setup.flush();
      assert.match(setup.captureCharFrame(), acknowledged ? /CANCELLED \/ NOT STARTED/ : /REQUEST ENDED \/ OUTCOME UNKNOWN/);
      if (!acknowledged) assert.doesNotMatch(setup.captureCharFrame(), /CANCELLED|STARTED/);
      assert.equal(fixture.calls.some((call) => call.startsWith("cancel-child:")), false);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
    }, { broker: fixture.broker });
  }
});

test("Busy UI predecessor completion cannot release a cancelled or expired pending intent", async (context) => {
  for (const advanced of [false, true]) for (const ended of ["cancelled", "expired"]) {
    const fixture = await busyFixture();
    await withSimpleRenderer(context, async (setup) => {
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      await openBusy(setup);
      setup.mockInput.pressTab();
      await setup.flush();
      setup.mockInput.pressEnter();
      await setup.flush();
      if (ended === "cancelled") setup.mockInput.pressKey("c");
      else fixture.progress(fixture.queueId(), "blocked", "schedule-expired");
      await setup.flush();
      const waiting = ended === "cancelled" ? /CANCELLATION ACKNOWLEDGED \/ CLEANUP PENDING/ : /BLOCKED \/ WAITING FOR SLOT RELEASE/;
      assert.match(setup.captureCharFrame(), waiting);
      fixture.progress(fixture.queueId(), "waiting-authority", "predecessor-running");
      fixture.terminal({
        schemaVersion: 1, requestId: "confirm", operation: "completed",
        dispatchId: "66666666-6666-4666-8666-666666666666", exitCode: 0,
      });
      fixture.progress("predecessor-queue", "resumed");
      setup.mockInput.pressEscape();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), waiting);
      assert.doesNotMatch(setup.captureCharFrame(), /FINISHED|Automatic work resumed|CANCELLED \/ NOT STARTED/);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
      assert.equal(fixture.calls.some((call) => call.startsWith("cancel-child:")), false);
      fixture.progress(fixture.queueId(), "waiting-authority", "automatic-starting");
      await setup.flush();
      assert.match(setup.captureCharFrame(), waiting);
      assert.doesNotMatch(setup.captureCharFrame(), /Automatic work resumed/);
      fixture.progress(fixture.queueId(), "resumed");
      await setup.flush();
      assert.match(setup.captureCharFrame(), ended === "cancelled" ? /CANCELLED \/ NOT STARTED/ : /NOT STARTED \/ READY TO START/);
      assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
    }, { broker: fixture.broker, height: 32 });
  }
});

test("Simple and Advanced retain the global broker diagnostic without a queue or false automatic success", async (context) => {
  for (const width of [70, 100, 140]) for (const advanced of [false, true]) {
    await withSimpleRenderer(context, async (setup) => {
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      const frame = setup.captureCharFrame();
      assert.match(frame, /BROKER FAILURE: automatic-startup-failed/);
      assert.match(frame, /OPERATIONAL/);
      assert.doesNotMatch(frame, /Automatic work resumed|STARTED|FINISHED/);
      if (!advanced) {
        for (const label of ["m Start agent", "h History", "a Advanced", "q Quit"]) assert.ok(frame.includes(label));
      }
    }, { width, height: 8, launchMode: "operational", brokerFailure: () => "automatic-startup-failed: startup not confirmed" });
  }
});

test("Busy UI preserves finished or failed manual outcomes while automatic restart is pending or hard-blocked", { timeout: 20_000 }, async (context) => {
  for (const advanced of [false, true]) for (const result of ["unreported", "failed"]) {
    for (const code of ["schedule-interrupted", "launch-failed", "automatic-policy-changed", "termination-failed", "automatic-startup-failed", "automatic-worker-failed"]) {
      const fixture = await busyFixture();
      await withSimpleRenderer(context, async (setup, reducer) => {
        if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
        await openBusy(setup);
        setup.mockInput.pressEnter();
        await setup.flush();
        const accepted = fixture.acceptance(fixture.queueId());
        fixture.accept(accepted);
        if (result === "failed") {
          reducer.apply(parseAgentEvent({
            ...simpleLiveEvent("scheduled-outcome", 104), eventType: "work.completed",
            repositoryIdentity: fixture.summary().repositoryIdentity,
            dispatch: { schemaVersion: 1, dispatchId: accepted.dispatchId, ownership: "tui", forceAnalysis: true },
            data: { result: "failed", reason: "Delivery failed", summary: "Actual manual failure" },
          }));
        }
        fixture.terminal({ schemaVersion: 1, requestId: "terminal", operation: "completed", dispatchId: accepted.dispatchId, exitCode: 0 });
        await setup.flush();
        const headline = result === "failed" ? /FAILED/ : /FINISHED \/ OUTCOME UNKNOWN/;
        assert.match(setup.captureCharFrame(), headline);
        assert.match(setup.captureCharFrame(), /Waiting for automatic resumption/);
        setup.mockInput.pressEscape();
        setup.mockInput.pressEnter();
        await setup.flush();
        assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
        fixture.progress(fixture.queueId(), "blocked", code);
        await setup.flush();
        assert.match(setup.captureCharFrame(), headline);
        assert.match(setup.captureCharFrame(), new RegExp(`Scheduling blocked: ${code}`));
        fixture.progress("unrelated", "resumed");
        setup.mockInput.pressEscape();
        await setup.flush();
        assert.doesNotMatch(setup.captureCharFrame(), /Automatic work resumed/);
        fixture.progress(fixture.queueId(), "resumed");
        await setup.flush();
        assert.match(setup.captureCharFrame(), headline);
        if (code === "schedule-interrupted") {
          assert.match(setup.captureCharFrame(), /Automatic work resumed/);
          assert.match(setup.captureCharFrame(), /Enter or Esc: close/);
          assert.doesNotMatch(setup.captureCharFrame(), /waiting for confirmed scheduling-slot release/);
          setup.mockInput.pressEscape();
          await setup.flush();
          assert.doesNotMatch(setup.captureCharFrame(), /START AGENT BY PR ID/);
        } else {
          assert.match(setup.captureCharFrame(), /Scheduling slot blocked/);
          assert.doesNotMatch(setup.captureCharFrame(), /Automatic work resumed|Enter or Esc: close/);
          setup.mockInput.pressEscape();
          setup.mockInput.pressEnter();
          setup.mockInput.pressKey("m");
          await setup.flush();
          assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
        }
        assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
        assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
      }, { broker: fixture.broker, height: 32 });
    }
  }
});

test("Busy UI cancellation acknowledgment followed by failed resumption retains the slot", async (context) => {
  for (const code of ["schedule-interrupted", "launch-failed", "automatic-policy-changed", "termination-failed", "automatic-startup-failed", "automatic-worker-failed"]) {
    const fixture = await busyFixture();
    await withSimpleRenderer(context, async (setup) => {
      await openBusy(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      setup.mockInput.pressKey("c");
      await setup.flush();
      fixture.progress(fixture.queueId(), "blocked", code);
      setup.mockInput.pressEscape();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /START AGENT BY PR ID/);
      assert.doesNotMatch(setup.captureCharFrame(), /CANCELLED \/ NOT STARTED/);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
      fixture.progress(fixture.queueId(), "resumed");
      await setup.flush();
      assert.match(setup.captureCharFrame(), code === "schedule-interrupted" ? /CANCELLED \/ NOT STARTED/ : /STATUS UNKNOWN/);
      assert.equal(fixture.calls.some((call) => call.startsWith("cancel-child:")), false);
    }, { broker: fixture.broker, height: 32 });
  }
});

test("Busy UI buffers blocked and released before confirmation returns, then ignores the old queue during fresh preview", async (context) => {
  const fixture = await busyFixture();
  const confirm = fixture.broker.confirmRun!;
  fixture.broker.confirmRun = async (prepared) => {
    const queued = await confirm(prepared);
    fixture.updateSummary({ prSnapshot: { ...fixture.summary().prSnapshot, title: "Revalidated source" } });
    fixture.progress(queued.queueId, "blocked", "source-changed");
    fixture.progress(queued.queueId, "resumed");
    return queued;
  };
  await withSimpleRenderer(context, async (setup) => {
    await openBusy(setup);
    setup.mockInput.pressEnter();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
    assert.match(setup.captureCharFrame(), /Revalidated source/);
    assert.equal(fixture.calls.filter((call) => call === "describe").length, 2);
    assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
    fixture.accept(fixture.acceptance(fixture.queueId()));
    fixture.progress(fixture.queueId(), "blocked", "termination-failed");
    fixture.progress(fixture.queueId(), "resumed");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /NOT STARTED \/ READY TO START/);
    assert.doesNotMatch(setup.captureCharFrame(), /STATUS UNKNOWN|FINISHED/);
  }, { broker: fixture.broker });
});

test("Busy UI cancellation race retains accepted work, including acceptance after not-queued", async (context) => {
  for (const earlyAcceptance of [false, true]) {
    const fixture = await busyFixture();
    fixture.broker.cancelQueued = async (queueId) => {
      fixture.calls.push(`cancel-queued:${queueId}`);
      if (earlyAcceptance) fixture.accept(fixture.acceptance(queueId));
      throw new BrokerRejectionError("not-queued", "The queued request has moved on.");
    };
    await withSimpleRenderer(context, async (setup) => {
      await openBusy(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      setup.mockInput.pressKey("c");
      await setup.flush();
      if (!earlyAcceptance) {
        assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
        fixture.accept(fixture.acceptance(fixture.queueId()));
        await setup.flush();
      }
      assert.match(setup.captureCharFrame(), /STARTED/);
      assert.match(setup.captureCharFrame(), /Waiting for first progress/);
      assert.doesNotMatch(setup.captureCharFrame(), /CANCELLED/);
      assert.equal(fixture.calls.some((call) => call.startsWith("cancel-child:")), false);
      setup.mockInput.pressKey("c");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /CANCELLED/);
      assert.equal(fixture.calls.filter((call) => call.startsWith("cancel-child:")).length, 1);
    }, { broker: fixture.broker, height: 32 });
  }
});

test("Busy UI hard scheduling failures and lost confirmation prevent closing, redispatch and false resume success", async (context) => {
  for (const kind of ["termination-failed", "automatic-policy-changed", "automatic-startup-failed", "automatic-worker-failed", "transport"] as const) {
    const fixture = await busyFixture();
    if (kind === "transport") fixture.broker.confirmRun = async () => { throw new Error("Lost confirmation response"); };
    await withSimpleRenderer(context, async (setup) => {
      await openBusy(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      if (kind !== "transport") fixture.progress(fixture.queueId(), "blocked", kind);
      await setup.flush();
      assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
      setup.mockInput.pressEscape();
      setup.mockInput.pressEnter();
      setup.mockInput.pressKey("m");
      setup.mockInput.pressKey("a");
      fixture.progress(fixture.queueId(), "resumed");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
      assert.doesNotMatch(setup.captureCharFrame(), /CANCELLED|FINISHED|LIVE AGENTS/);
      assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
      assert.equal(fixture.calls.some((call) => call.startsWith("cancel-child:") || call.startsWith("cancel-queued:")), false);
    }, { broker: fixture.broker });
  }
});

test("Busy UI unknown blocked codes stay q-only after resumed in both modes and retain manual outcomes", { timeout: 20_000 }, async (context) => {
  for (const advanced of [false, true]) for (const code of ["future-provider-error", "launch-failed", "already-running"]) {
    for (const outcome of ["queued", "finished", "failed"]) {
      const fixture = await busyFixture();
      await withSimpleRenderer(context, async (setup, reducer) => {
        if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
        await openBusy(setup);
        setup.mockInput.pressEnter();
        await setup.flush();
        if (outcome !== "queued") {
          const accepted = fixture.acceptance(fixture.queueId());
          fixture.accept(accepted);
          if (outcome === "failed") reducer.apply(parseAgentEvent({
            ...simpleLiveEvent("unknown-block-outcome", 104), eventType: "work.completed",
            repositoryIdentity: fixture.summary().repositoryIdentity,
            dispatch: { schemaVersion: 1, dispatchId: accepted.dispatchId, ownership: "tui", forceAnalysis: true },
            data: { result: "failed", reason: "Delivery failed", summary: "Original manual outcome retained" },
          }));
          fixture.terminal({ schemaVersion: 1, requestId: "terminal", operation: "completed",
            dispatchId: accepted.dispatchId, exitCode: 0 });
        }
        fixture.progress(fixture.queueId(), "blocked", code);
        await setup.flush();
        const headline = outcome === "queued" ? /STATUS UNKNOWN/ : outcome === "finished" ? /FINISHED \/ OUTCOME UNKNOWN/ : /FAILED/;
        assert.match(setup.captureCharFrame(), headline);
        assert.match(setup.captureCharFrame(), new RegExp(`Scheduling blocked: ${code}`));
        fixture.progress(fixture.queueId(), "resumed");
        setup.mockInput.pressEscape();
        setup.mockInput.pressEnter();
        for (const key of ["m", "a", "c"]) setup.mockInput.pressKey(key);
        await setup.flush();
        assert.match(setup.captureCharFrame(), headline);
        assert.match(setup.captureCharFrame(), /Scheduling slot blocked \| q: quit and stop/);
        assert.doesNotMatch(setup.captureCharFrame(), /Automatic work resumed|READY TO START|Enter or Esc: close|retry queued cancel/);
        if (outcome === "failed") assert.match(setup.captureCharFrame(), /Original manual outcome retained/);
        assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
        assert.equal(fixture.preparations.length, 1);
        assert.equal(fixture.calls.filter((call) => call.startsWith("confirm:")).length, 1);
        assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
        assert.equal(fixture.calls.some((call) => call.startsWith("cancel-child:") || call.startsWith("cancel-queued:")), false);
      }, { broker: fixture.broker, height: 32 });
    }
  }
});

test("Busy UI 70x8 choices and full permissions scroll safely in both modes without changing PreviewOnly", async (context) => {
  for (const advanced of [false, true]) {
    const fixture = await busyFixture();
    fixture.updateSummary({ capabilities: [], mandatoryDenies: ["EnableApprovalVote", "EnablePush"],
      dynamicConstraints: ["This intent remains preview-only. " + "No mutations may be made. ".repeat(8) + "BUSYCONSTRAINTEND"] });
    await withSimpleRenderer(context, async (setup) => {
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      await openBusy(setup);
      let observed = setup.captureCharFrame();
      for (let index = 0; index < 35; index++) {
        setup.mockInput.pressKey("\u001b[6~");
        await setup.flush();
        const frame = setup.captureCharFrame();
        observed += frame;
        assert.match(frame, /Enter: Replace \/ run now/);
        assert.match(frame, /Esc: Back/);
        assert.match(frame, /PREVIEW/);
      }
      assert.match(observed, /No PR mutations allowed/);
      assert.match(observed, /BUSYCONSTRAINTEND/);
      assert.match(observed, /configured\/reviewer \/ PR #104/);
      assert.match(observed, /Completed comments and pushes are not undone/);
      if (advanced) assert.match(observed, /Not allowed: Approval vote, Code pushes/);
      setup.mockInput.pressTab();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /> Run next/);
      setup.mockInput.pressTab();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /> Back/);
      setup.mockInput.pressArrow("down");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /> Replace \/ run now/);
      setup.mockInput.pressEnter();
      await setup.flush();
      fixture.accept(fixture.acceptance(fixture.queueId()));
      await setup.flush();
      assert.match(setup.captureCharFrame(), /STARTED/);
      assert.deepEqual(fixture.summary().capabilities, []);
    }, { broker: fixture.broker, width: 70, height: 8, launchMode: "preview" });
  }
});

test("Busy UI cannot confirm before the proposal frame and an expired manual-work binding requires fresh Enter", async (context) => {
  const fixture = await busyFixture("review-handler");
  const prepare = fixture.broker.prepareRun!;
  let release!: () => void;
  fixture.broker.prepareRun = async (...args) => {
    const value = await prepare(...args);
    value.conflict.kind = "manual";
    return new Promise<RunPrepared>((resolve) => { release = () => resolve(value); });
  };
  await withSimpleRenderer(context, async (setup) => {
    await openBusy(setup, "review-handler");
    const frame = setup.renderer.frameId;
    release();
    for (let index = 0; index < 5; index++) await Promise.resolve();
    assert.equal(setup.renderer.frameId, frame);
    setup.mockInput.pressEnter();
    assert.equal(fixture.calls.some((call) => call.startsWith("confirm:")), false);
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Current manual Review Handler: PR #888/);
    fixture.preparations[0]!.expiresAtUtc = new Date(Date.now() - 1_000).toISOString();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /CHECKING OWNED WORK/);
    assert.equal(fixture.preparations.length, 2);
    assert.equal(fixture.calls.some((call) => call.startsWith("confirm:")), false);
    release();
    await setup.flush();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /QUEUED \/ NOT STARTED/);
    assert.equal(fixture.calls.filter((call) => call.startsWith("confirm:")).length, 1);
    assert.ok(fixture.calls.includes(`confirm:${fixture.preparations[1]!.confirmationToken}`));
  }, { broker: fixture.broker, height: 32 });
});

test("Busy UI mismatched acceptance never attaches a stream or invents a started run", async (context) => {
  const fixture = await busyFixture();
  const reducer = new OperationsReducer();
  const register = reducer.registerLocalStream.bind(reducer);
  let registrations = 0;
  reducer.registerLocalStream = (...args) => { registrations++; return register(...args); };
  await withSimpleRenderer(context, async (setup) => {
    await openBusy(setup);
    setup.mockInput.pressEnter();
    await setup.flush();
    fixture.accept(fixture.acceptance("unknown-queue"));
    await setup.flush();
    assert.match(setup.captureCharFrame(), /QUEUED \/ NOT STARTED/);
    const wrongRepository = { ...fixture.summary().repositoryIdentity, repositoryId: "999", key: "v1:github:999" };
    fixture.accept(fixture.acceptance(fixture.queueId(), { repositoryIdentity: wrongRepository }));
    await setup.flush();
    assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
    fixture.accept(fixture.acceptance(fixture.queueId()));
    setup.mockInput.pressEscape();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
    assert.equal(registrations, 0);
    assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
  }, { broker: fixture.broker, reducer });
});

test("Busy UI successful queue-cancel response cannot overwrite already accepted terminal work", async (context) => {
  const fixture = await busyFixture();
  const cancel = fixture.broker.cancelQueued!;
  fixture.broker.cancelQueued = async (queueId) => {
    const accepted = fixture.acceptance(queueId);
    fixture.accept(accepted);
    fixture.terminal({ schemaVersion: 1, requestId: "fast", operation: "completed", dispatchId: accepted.dispatchId, exitCode: 0 });
    return cancel(queueId);
  };
  await withSimpleRenderer(context, async (setup) => {
    await openBusy(setup);
    setup.mockInput.pressEnter();
    await setup.flush();
    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /FINISHED \/ OUTCOME UNKNOWN/);
    assert.doesNotMatch(setup.captureCharFrame(), /Queued request cancelled|Use c to cancel|CANCELLED/);
  }, { broker: fixture.broker });
});

test("Busy UI retirement flags contradictory cancellation acknowledgment and acceptance without losing the child", { timeout: 20_000 }, async (context) => {
  for (const advanced of [false, true]) for (const order of ["before-ack", "after-ack", "after-release"]) {
    const fixture = await busyFixture();
    const cancel = fixture.broker.cancelQueued!;
    fixture.broker.cancelQueued = async (queueId) => {
      if (order === "before-ack") fixture.accept(fixture.acceptance(queueId));
      return cancel(queueId);
    };
    await withSimpleRenderer(context, async (setup) => {
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      await openBusy(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      setup.mockInput.pressKey("c");
      await setup.flush();
      if (order === "after-release") {
        fixture.progress(fixture.queueId(), "resumed");
        await setup.flush();
        assert.match(setup.captureCharFrame(), /CANCELLED \/ NOT STARTED/);
      }
      if (order !== "before-ack") fixture.accept(fixture.acceptance(fixture.queueId()));
      await setup.flush();
      assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
      assert.match(setup.captureCharFrame(), /inconsistent/);
      assert.match(setup.captureCharFrame(), /accepted run/);
      fixture.terminal({ schemaVersion: 1, requestId: "actual", operation: "completed",
        dispatchId: fixture.acceptance(fixture.queueId()).dispatchId, exitCode: 0 });
      await setup.flush();
      assert.match(setup.captureCharFrame(), /FINISHED \/ OUTCOME UNKNOWN/);
      assert.match(setup.captureCharFrame(), /inconsistent/);
      fixture.progress(fixture.queueId(), "resumed");
      for (const key of ["c", "m", "a"]) setup.mockInput.pressKey(key);
      setup.mockInput.pressEscape();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /FINISHED \/ OUTCOME UNKNOWN/);
      assert.match(setup.captureCharFrame(), /q: quit and stop/);
      assert.doesNotMatch(setup.captureCharFrame(), /CANCELLED \/ NOT STARTED|Enter or Esc: close|Use c to cancel/);
      assert.equal(fixture.calls.some((call) => call.startsWith("cancel-child:")), false);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
      assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
    }, { broker: fixture.broker, height: 32 });
  }
});

test("Busy UI retirement preserves buffered accepted completion when broker failure precedes confirmation continuation", { timeout: 20_000 }, async (context) => {
  for (const advanced of [false, true]) {
    const fixture = await busyFixture();
    const confirm = fixture.broker.confirmRun!;
    let release!: () => void;
    let failure = "";
    fixture.broker.confirmRun = async (prepared) => {
      const queued = await confirm(prepared);
      return new Promise<RunQueued>((resolve) => { release = () => resolve(queued); });
    };
    await withSimpleRenderer(context, async (setup) => {
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      await openBusy(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      const accepted = fixture.acceptance(fixture.queueId());
      fixture.accept(accepted);
      fixture.terminal({ schemaVersion: 1, requestId: "confirm", operation: "completed",
        dispatchId: accepted.dispatchId, exitCode: 0 });
      fixture.progress(fixture.queueId(), "blocked", "automatic-startup-failed");
      failure = "automatic-startup-failed: reviewer initialization failed";
      await waitForFrame(setup, /BROKER FAILURE: automatic-startup-failed/);
      release();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /FINISHED \/ OUTCOME UNKNOWN/);
      assert.match(setup.captureCharFrame(), /outcome was not reported/);
      assert.match(setup.captureCharFrame(), /BROKER FAILURE: automatic-startup-failed/);
      fixture.progress(fixture.queueId(), "resumed");
      setup.mockInput.pressEscape();
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), /FINISHED \/ OUTCOME UNKNOWN/);
      assert.doesNotMatch(setup.captureCharFrame(), /Automatic work resumed|Enter or Esc: close/);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
    }, { broker: fixture.broker, brokerFailure: () => failure, height: 32 });
  }
});

test("Busy UI retirement preserves actual manual outcomes and holds broker failures q-only after completion", { timeout: 20_000 }, async (context) => {
  for (const advanced of [false, true]) {
    for (const code of ["automatic-policy-changed", "automatic-startup-failed", "automatic-worker-failed", "launch-failed"]) {
      const fixture = await busyFixture();
      let failure = "";
      await withSimpleRenderer(context, async (setup, reducer) => {
        if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
        await openBusy(setup);
        setup.mockInput.pressEnter();
        await setup.flush();
        const accepted = fixture.acceptance(fixture.queueId());
        fixture.accept(accepted);
        const failed = code === "automatic-worker-failed";
        if (failed) reducer.apply(parseAgentEvent({
          ...simpleLiveEvent("retirement-outcome", 104), eventType: "work.completed",
          repositoryIdentity: fixture.summary().repositoryIdentity,
          dispatch: { schemaVersion: 1, dispatchId: accepted.dispatchId, ownership: "tui", forceAnalysis: true },
          data: { result: "failed", reason: "Delivery failed", summary: "Original manual failure preserved" },
        }));
        fixture.terminal({ schemaVersion: 1, requestId: "terminal", operation: "completed", dispatchId: accepted.dispatchId, exitCode: 0 });
        fixture.progress(fixture.queueId(), "blocked", code);
        failure = `${code}: automatic admission unavailable`;
        await waitForFrame(setup, /BROKER FAILURE:/);
        const headline = failed ? /FAILED/ : /FINISHED \/ OUTCOME UNKNOWN/;
        assert.match(setup.captureCharFrame(), headline);
        if (failed) assert.match(setup.captureCharFrame(), /Original manual failure preserved/);
        fixture.progress(fixture.queueId(), "resumed");
        setup.mockInput.pressEscape();
        setup.mockInput.pressEnter();
        setup.mockInput.pressKey("m");
        await setup.flush();
        assert.match(setup.captureCharFrame(), headline);
        assert.match(setup.captureCharFrame(), /q: quit and stop/);
        assert.doesNotMatch(setup.captureCharFrame(), /Automatic work resumed|Enter or Esc: close/);
        assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
        assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
      }, { broker: fixture.broker, brokerFailure: () => failure, height: 32 });
    }
  }
});

test("Busy UI retirement keeps every soft-blocked queue bound for a later hard resumption failure", async (context) => {
  for (const code of ["schedule-repreview-required", "schedule-expired", "schedule-stale", "schedule-interrupted",
    "source-changed", "policy-changed", "pr-state-changed", "repository-mismatch"]) {
    const fixture = await busyFixture();
    await withSimpleRenderer(context, async (setup) => {
      await openBusy(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      fixture.progress(fixture.queueId(), "blocked", code);
      fixture.progress(fixture.queueId(), "waiting-authority", "automatic-starting");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /BLOCKED \/ WAITING FOR SLOT RELEASE/);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
      fixture.progress(fixture.queueId(), "blocked", "automatic-policy-changed");
      fixture.progress(fixture.queueId(), "resumed");
      setup.mockInput.pressEscape();
      setup.mockInput.pressEnter();
      setup.mockInput.pressKey("m");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
      assert.match(setup.captureCharFrame(), /automatic-policy-changed/);
      assert.equal(fixture.calls.filter((call) => call === "describe").length, 1);
      assert.equal(fixture.preparations.length, 1);
    }, { broker: fixture.broker, height: 32 });
  }
});

test("Busy UI broker loss holds pending work unknown until normal shutdown and removes both subscriptions", async (context) => {
  for (const phase of ["queued", "confirming", "cleanup"]) {
    const confirmationPending = phase === "confirming";
    const fixture = await busyFixture();
    let failure = "";
    let release!: () => void;
    if (confirmationPending) {
      const confirm = fixture.broker.confirmRun!;
      fixture.broker.confirmRun = async (prepared) => {
        await new Promise<void>((resolve) => { release = resolve; });
        return confirm(prepared);
      };
    }
    fixture.broker.shutdown = async () => { fixture.calls.push("shutdown"); };
    await withSimpleRenderer(context, async (setup) => {
      await openBusy(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      if (phase === "cleanup") {
        setup.mockInput.pressKey("c");
        await setup.flush();
        assert.match(setup.captureCharFrame(), /CANCELLATION ACKNOWLEDGED \/ CLEANUP PENDING/);
      }
      failure = "Scheduling transport closed";
      await waitForFrame(setup, /STATUS UNKNOWN/);
      if (confirmationPending) {
        failure = "";
        release();
        await setup.flush();
        assert.match(setup.captureCharFrame(), /STATUS UNKNOWN/);
      }
      setup.mockInput.pressEscape();
      setup.mockInput.pressEnter();
      setup.mockInput.pressKey("m");
      await setup.flush();
      assert.equal(fixture.calls.filter((call) => call.startsWith("dispatch:")).length, 1);
      setup.mockInput.pressKey("q");
      for (let index = 0; index < 5; index++) await Promise.resolve();
      assert.equal(setup.renderer.isDestroyed, true);
      assert.equal(fixture.calls.filter((call) => call === "shutdown").length, 1);
      assert.equal(fixture.progressListeners.size, 0);
      assert.equal(fixture.acceptedListeners.size, 0);
    }, { broker: fixture.broker, brokerFailure: () => failure });
  }
});

test("Simple optional instructions treat mode keys as data and do not add a required confirmation step", async (context) => {
  const { broker, calls } = await startFixture();
  let promptSent = "";
  const dispatch = broker.dispatch;
  broker.dispatch = async (summary, prompt) => { promptSent = prompt; return dispatch(summary, prompt); };
  await withSimpleRenderer(context, async (setup) => {
    await openManualAndDescribe(setup);
    setup.mockInput.pressKey("p");
    await setup.mockInput.typeText("a");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Optional instructions \(1\/512 characters\)/);
    setup.mockInput.pressEnter();
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.equal(calls.filter((call) => call.operation === "dispatch").length, 0);
    assert.match(setup.captureCharFrame(), /Instructions: a/);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.equal(promptSent, "a");
    assert.equal(calls.filter((call) => call.operation === "dispatch").length, 1);
  }, { broker });
});

test("Simple cancelled reads cannot resurrect a preview, and invalid whole input never reaches the broker", async (context) => {
  const { broker, calls } = await startFixture();
  const describe = broker.describe;
  let release!: () => void;
  broker.describe = async (...args) => { await new Promise<void>((resolve) => { release = resolve; }); return describe(...args); };
  await withSimpleRenderer(context, async (setup) => {
    setup.mockInput.pressKey("m");
    await setup.mockInput.typeText("2147483648");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /1\.\.2147483647/);
    assert.deepEqual(calls, []);
    setup.mockInput.pressKey("u", { ctrl: true });
    await setup.mockInput.typeText("104");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Preparing preview/);
    setup.mockInput.pressKey("a");
    setup.mockInput.pressEnter();
    setup.mockInput.pressEscape();
    await setup.flush();
    release();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
    assert.doesNotMatch(setup.captureCharFrame(), /READY TO START/);
    assert.equal(calls.filter((call) => call.operation === "dispatch").length, 0);
  }, { broker });
});

test("Simple PreviewOnly exposes no mutation grants and blocks widening even if offered by the broker", async (context) => {
  const { broker, calls } = createWideningBrokerFixture();
  await withSimpleRenderer(context, async (setup) => {
    assert.match(setup.captureCharFrame(), /PREVIEW ONLY/);
    await openManualAndDescribe(setup);
    assert.match(setup.captureCharFrame(), /No PR mutations allowed/);
    setup.mockInput.pressKey("w");
    setup.mockInput.pressKey("c");
    setup.mockInput.pressKey("y");
    setup.mockInput.pressKey("a");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Capability widening is in Advanced/);
    assert.deepEqual(calls, ["describe"]);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.equal(calls.filter((call) => call === "dispatch").length, 1);
    assert.match(setup.captureCharFrame(), /PREVIEW ONLY/);
  }, { broker, launchMode: "preview", width: 70 });
});

test("Simple exact manual progress remains visible after its instance leaves Live, and cancellation stays explicit", async (context) => {
  const { broker, summaryFor } = await startFixture();
  let listener: ((value: DispatchTerminal) => void) | undefined;
  broker.subscribeTerminal = (value) => { listener = value; return () => { listener = undefined; }; };
  let cancelCount = 0;
  broker.cancel = async (dispatchId) => {
    cancelCount++;
    return { schemaVersion: 1, requestId: "cancel", operation: "cancelled", dispatchId, result: "cancelled-cooperative" };
  };
  await withSimpleRenderer(context, async (setup, reducer) => {
    await openManualAndDescribe(setup);
    setup.mockInput.pressEnter();
    await setup.flush();
    const summary = summaryFor(104, "reviewer");
    const event = (instanceId: string, sequence: number, data: Record<string, unknown>, dispatchId: string) => parseAgentEvent({
      ...simpleLiveEvent(instanceId, 104, sequence), eventType: "phase.changed", data,
      repositoryIdentity: summary.repositoryIdentity,
      dispatch: { schemaVersion: 1, dispatchId, ownership: "tui", forceAnalysis: true },
    });
    reducer.apply(event("unrelated", 1, { phase: "Wrong dispatch phase" }, "99999999-9999-4999-8999-999999999999"));
    reducer.apply(event("selected-manual", 1, { phase: "Exact manual phase" }, "44444444-4444-4444-8444-444444444444"));
    await waitForFrame(setup, /Exact manual phase/);
    assert.doesNotMatch(setup.captureCharFrame(), /Wrong dispatch phase|PID/);
    const selected = reducer.get("reviewer:selected-manual")!;
    selected.lastHeartbeatMs = selected.lastEventMs = Date.now() - 60_000;
    const dismissal = reducer.dismissalFor("reviewer:selected-manual");
    assert.ok(dismissal);
    assert.equal(reducer.dismissInstance(dismissal), true);
    assert.equal(reducer.list(Date.now(), undefined, "live").some((row) => row.instanceId === "selected-manual"), false);
    await new Promise((resolve) => setTimeout(resolve, 1_050));
    await waitForFrame(setup, /Exact manual phase/);
    assert.match(setup.captureCharFrame(), /STARTED/);
    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.equal(cancelCount, 1);
    assert.match(setup.captureCharFrame(), /CANCELLED/);
    assert.match(setup.captureCharFrame(), /broker observed child exit/);
    listener?.({ schemaVersion: 1, requestId: "wrong", operation: "completed", dispatchId: "unrelated", exitCode: 1 });
    await setup.flush();
    assert.match(setup.captureCharFrame(), /CANCELLED/);
  }, { broker, width: 70 });
});

for (const result of ["unreported", "failed"]) {
  test(`Simple terminal ${result} outcome never infers success from exit zero`, async (context) => {
    const { broker, summaryFor } = await startFixture();
    let listener: ((value: DispatchTerminal) => void) | undefined;
    broker.subscribeTerminal = (value) => { listener = value; return () => { listener = undefined; }; };
    await withSimpleRenderer(context, async (setup, reducer) => {
      await openManualAndDescribe(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      if (result === "failed") {
        reducer.apply(parseAgentEvent({
          ...simpleLiveEvent("terminal-manual", 104), eventType: "work.completed",
          repositoryIdentity: summaryFor(104, "reviewer").repositoryIdentity,
          dispatch: { schemaVersion: 1, dispatchId: "44444444-4444-4444-8444-444444444444", ownership: "tui", forceAnalysis: true },
          data: { result: "failed", reason: "Delivery unavailable", summary: "No findings delivered" },
        }));
      }
      listener?.({ schemaVersion: 1, requestId: "terminal", operation: "completed",
        dispatchId: "44444444-4444-4444-8444-444444444444", exitCode: 0 });
      await waitForFrame(setup, result === "failed" ? /FAILED/ : /FINISHED \/ OUTCOME UNKNOWN/);
      assert.match(setup.captureCharFrame(), result === "failed" ? /Delivery unavailable/ : /outcome was not reported/);
      assert.match(setup.captureCharFrame(), /Enter or Esc: close/);
    }, { broker, width: 70 });
  });
}

test("Simple legacy exited History retains an unknown outcome without canonical identity or process chrome", async (context) => {
  const reducer = new OperationsReducer();
  reducer.apply(parseAgentEvent({
    schemaVersion: 2, instanceId: "legacy-private-id", processId: 42, agent: "reviewer", sequence: 1,
    timestamp: new Date().toISOString(), eventType: "agent.started", data: { repository: "Legacy repository" },
  }));
  const state = reducer.get("reviewer:legacy-private-id")!;
  state.exitObservedMs = Date.now();
  await withSimpleRenderer(context, async (setup) => {
    setup.mockInput.pressKey("h");
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Legacy repository/);
    assert.match(setup.captureCharFrame(), /Interrupted \/ outcome unknown/);
    assert.doesNotMatch(setup.captureCharFrame(), /legacy-private-id|PID|v1:github/);
  }, { reducer, width: 70 });
});

for (const failure of [
  { kind: "busy", error: new BrokerRejectionError("already-running", "state-contended: repository state is busy"), headline: /NOT STARTED \/ REQUEST FAILED/, detail: /Another Reviewer is using/ },
  { kind: "uncertain", error: new BrokerRejectionError("termination-failed", "Unconfirmed child exit"), headline: /START STATUS UNKNOWN/, detail: /child exit is unconfirmed/ },
]) {
  test(`Simple ${failure.kind} startup remains truthful and does not offer unimplemented busy choices`, async (context) => {
    const { broker, calls } = await startFixture();
    const dispatch = broker.dispatch;
    broker.dispatch = async (summary, prompt) => { await dispatch(summary, prompt); throw failure.error; };
    await withSimpleRenderer(context, async (setup) => {
      await openManualAndDescribe(setup);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.match(setup.captureCharFrame(), failure.headline);
      assert.match(setup.captureCharFrame(), failure.detail);
      assert.doesNotMatch(setup.captureCharFrame(), /Replace|Run next|FINISHED|CANCELLED/);
      setup.mockInput.pressKey("a");
      setup.mockInput.pressEnter();
      setup.mockInput.pressEscape();
      await setup.flush();
      assert.equal(calls.filter((call) => call.operation === "dispatch").length, 1);
      if (failure.kind === "uncertain") assert.match(setup.captureCharFrame(), failure.headline);
      else assert.match(setup.captureCharFrame(), /LIVE AGENTS/);
    }, { broker, width: 70, height: 16 });
  });
}

test("Live only defaults, Delete persistence, and Shift+Delete restore work at every supported width", async (context) => {
  for (const width of [70, 100, 140]) {
    const root = await mkdtemp(join(tmpdir(), "devpilot-dismissal-renderer-"));
    const storage = new FileDismissalStorage(root);
    const old = parseAgentEvent({
      schemaVersion: 2, agent: "reviewer", instanceId: "old-instance", processId: 42,
      sequence: 1, timestamp: new Date(Date.now() - 60_000).toISOString(),
      eventType: "agent.started", data: { repository: "repo" },
    });
    try {
      for (let launch = 0; launch < 2; launch++) {
        const fixture = createFixture();
        const reducer = new OperationsReducer(await storage.load());
        reducer.apply(old);
        reducer.apply(parseAgentEvent({ ...old, instanceId: "waiting-instance", timestamp: new Date().toISOString() }));
        reducer.apply(parseAgentEvent({
          ...old, instanceId: "waiting-instance", sequence: 2, timestamp: new Date().toISOString(),
          eventType: "agent.waiting", data: { kind: "cycle", delayMilliseconds: 900_000 },
        }));
        const history = createSettingsHistory();
        let setup: TestRendererSetup | undefined;
        try {
          setup = await renderAdvanced(() => <App reducer={reducer} tailer={fixture.tailer} history={history}
            dismissalStorage={storage} />, { width, height: 32, kittyKeyboard: true });
          await setup.renderOnce();
          assert.match(setup.captureCharFrame(), /INSTANCES 1/);
          assert.match(setup.captureCharFrame(), /Live only 1/);
          assert.match(setup.captureCharFrame(), /l Live/);
          assert.match(setup.captureCharFrame(), /Del/);
          setup.mockInput.pressKey("DELETE");
          await setup.flush();
          assert.match(setup.captureCharFrame(), /Live agents cannot be dismissed/);
          assert.equal((await storage.load()).length, launch);

          setup.mockInput.pressKey("l");
          await setup.flush();
          assert.match(setup.captureCharFrame(), new RegExp(`INSTANCES ${launch === 0 ? 2 : 1}`));
          if (launch === 0) {
            setup.mockInput.pressKey("DELETE");
            await waitForFrame(setup, /Instance dismissed across Watch restarts/);
            assert.match(setup.captureCharFrame(), /INSTANCES 1/);
            assert.equal((await storage.load()).length, 1);
          } else {
            setup.mockInput.pressKey("DELETE", { shift: true });
            await waitForFrame(setup, /1 dismissed instance\(s\) restored/);
            assert.match(setup.captureCharFrame(), /INSTANCES 2/);
            assert.deepEqual(await storage.load(), []);
          }
          assert.equal(history.list().length, 1, "instance dismissal never hides PR history");
          assert.ok(reducer.get("reviewer:old-instance"), "raw instance data is retained");
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
      }
    } finally { await rm(root, { recursive: true, force: true }); }
  }
});

test("a failed dismissal save leaves the row visible and reports a persistent display-state error", async (context) => {
  const fixture = createFixture();
  const storage: DismissalStorage = {
    save: async () => { throw new Error("storage unavailable"); },
    restoreAll: async () => 0,
  };
  let setup: TestRendererSetup | undefined;
  try {
    setup = await renderAdvanced(() => <App reducer={fixture.reducer} tailer={fixture.tailer}
      dismissalStorage={storage} />, { width: 140, height: 32, kittyKeyboard: true });
    await setup.renderOnce();
    setup.mockInput.pressKey("l");
    await setup.flush();
    setup.mockInput.pressKey("DELETE");
    await waitForFrame(setup, /Dismissal could not be saved; instance kept visible/);
    assert.match(setup.captureCharFrame(), /DISPLAY STATE: Could not save dismissal: storage unavailable/);
    assert.match(setup.captureCharFrame(), /INSTANCES 1/);
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

async function automationFixture() {
  const seed = await startFixture();
  const calls: string[] = [];
  let status: AutomationStatus = {
    schemaVersion: 1, requestId: "automation", operation: "automation-status", automationVersion: 1,
    available: true, scope: "current-launcher",
    agents: [
      { role: "reviewer", continuous: true, intervalSeconds: 900, state: "waiting", canScanNow: true },
      { role: "review-handler", continuous: true, intervalSeconds: 900, state: "waiting", canScanNow: true },
    ],
  };
  let result: ScanNowResult = {
    schemaVersion: 1, requestId: "scan", operation: "scan-now-result", automationVersion: 1, scope: "current-launcher",
    results: [{ role: "reviewer", outcome: "requested" }, { role: "review-handler", outcome: "requested" }],
  };
  const broker: DispatchBroker = {
    ...seed.broker,
    getAutomationStatus: async () => {
      calls.push("status");
      return { ...status, agents: status.agents.map((agent) => ({ ...agent })) };
    },
    scanNow: async () => { calls.push("scan"); return result; },
  };
  return {
    broker, calls, status: () => status, result: () => result,
    setStatus: (value: AutomationStatus) => { status = value; },
    setResults: (values: ScanNowResult["results"]) => { result = { ...result, results: values }; },
  };
}

test("Auto polling presentation uses negotiated intervals and role-specific results without a next-scan deadline", async () => {
  const fixture = await automationFixture();
  assert.equal(automationStatusText(fixture.status()), "Auto: Both / every 15m / waiting");
  const agents = fixture.status().agents;
  assert.equal(automationStatusText({ ...fixture.status(), agents: [
    { ...agents[0]!, intervalSeconds: 61, state: "scanning" },
    { ...agents[1]!, continuous: false, intervalSeconds: null, state: "stopped", canScanNow: false },
  ] }), "Auto: Reviewer every 61s scanning; Handler once stopped");
  fixture.setResults([{ role: "reviewer", outcome: "requested" }, { role: "review-handler", outcome: "already-running" }]);
  assert.equal(scanNowResultText(fixture.result()), "Scan: Reviewer wake requested; Handler already working");
  assert.doesNotMatch(automationStatusText(fixture.status()), /Next|countdown|PID/);
});

test("Auto polling status and Scan now fit both main modes at 70, 100 and 140 by 8 without changing authority", { timeout: 20_000 }, async (context) => {
  for (const width of [70, 100, 140]) for (const advanced of [false, true]) {
    const fixture = await automationFixture();
    const reducer = new OperationsReducer();
    reducer.apply(simpleLiveEvent("automatic-visible", 104));
    await withSimpleRenderer(context, async (setup) => {
      await waitForFrame(setup, /Auto: Both \/ every 15m \/ waiting/);
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      let frame = setup.captureCharFrame();
      assert.match(frame, /Auto: Both \/ every 15m \/ waiting/);
      assert.match(frame, /OPERATIONAL/);
      assert.match(frame, /r Scan now/);
      if (!advanced) {
        assert.match(frame, /Reviewer \| PR #104/);
        for (const label of ["m Start agent", "h History", "a Advanced", "q Quit"]) assert.ok(frame.includes(label));
        assert.doesNotMatch(frame, /FOCUS|INSPECTOR|PID/);
      }
      setup.mockInput.pressKey("r");
      await setup.flush();
      frame = setup.captureCharFrame();
      assert.match(frame, /Reviewer wake requested; Handler wake requested/);
      assert.match(frame, /r Scan now/);
      assert.match(frame, /Auto: Both \/ every 15m \/ waiting/);
      assert.doesNotMatch(frame, /STARTED|Next scan/);
      assert.equal(fixture.calls.filter((call) => call === "scan").length, 1);
      assert.equal(fixture.calls.filter((call) => call === "status").length, 2);
    }, { broker: fixture.broker, reducer, width, height: 8, launchMode: "operational" });
  }
});

test("Auto polling Scan now reports mixed requested, busy, manual-priority and unavailable roles without hiding its key", async (context) => {
  for (const results of [
    [{ role: "reviewer", outcome: "requested" }, { role: "review-handler", outcome: "already-running" }],
    [{ role: "reviewer", outcome: "manual-priority" }, { role: "review-handler", outcome: "unavailable" }],
    [{ role: "reviewer", outcome: "already-running" }, { role: "review-handler", outcome: "already-running" }],
  ] satisfies ScanNowResult["results"][]) {
    const fixture = await automationFixture();
    fixture.setResults(results);
    fixture.setStatus({ ...fixture.status(), agents: fixture.status().agents.map((agent) => ({
      ...agent, state: "scanning", canScanNow: false,
    })) });
    await withSimpleRenderer(context, async (setup) => {
      await waitForFrame(setup, /Auto: Both \/ every 15m \/ scanning/);
      setup.mockInput.pressKey("r");
      await setup.flush();
      assert.ok(setup.captureCharFrame().includes(scanNowResultText(fixture.result())));
      assert.match(setup.captureCharFrame(), /r Scan now/);
      assert.doesNotMatch(setup.captureCharFrame(), /STARTED|QUEUED/);
      assert.equal(fixture.calls.filter((call) => call === "scan").length, 1);
    }, { broker: fixture.broker, width: 70, height: 8 });
  }
});

test("Auto polling deduplicates repeated Scan now keys and refreshes status after the actual response", async (context) => {
  const fixture = await automationFixture();
  let release!: () => void;
  fixture.broker.scanNow = async () => {
    fixture.calls.push("scan");
    return new Promise<ScanNowResult>((resolve) => { release = () => resolve(fixture.result()); });
  };
  await withSimpleRenderer(context, async (setup) => {
    await waitForFrame(setup, /Auto: Both/);
    setup.mockInput.pressKey("\u001b[114;1:2u");
    await setup.flush();
    assert.equal(fixture.calls.includes("scan"), false);
    setup.mockInput.pressKey("r");
    setup.mockInput.pressKey("r");
    setup.mockInput.pressKey("\u001b[114;1:2u");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Scan request already pending/);
    assert.equal(fixture.calls.filter((call) => call === "scan").length, 1);
    assert.equal(fixture.calls.filter((call) => call === "status").length, 1);
    release();
    await setup.flush();
    assert.equal(fixture.calls.filter((call) => call === "status").length, 2);
    assert.match(setup.captureCharFrame(), /wake requested/);
  }, { broker: fixture.broker });
});

test("Auto polling absent or unsupported control reports unavailable with no action in footer, palette or help", async (context) => {
  for (const unsupported of [false, true]) {
    const fixture = await automationFixture();
    if (unsupported) fixture.setStatus({ ...fixture.status(), available: false, scope: null, agents: [] });
    else { delete fixture.broker.getAutomationStatus; delete fixture.broker.scanNow; }
    await withSimpleRenderer(context, async (setup) => {
      await waitForFrame(setup, /Auto: unavailable/);
      assert.doesNotMatch(setup.captureCharFrame(), /Auto: OFF|r Scan now/);
      setup.mockInput.pressKey("r");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /Scan now unavailable/);
      setup.mockInput.pressKey("p", { ctrl: true });
      await setup.flush();
      assert.doesNotMatch(setup.captureCharFrame(), /> Scan now|  Scan now/);
      setup.mockInput.pressEscape();
      setup.mockInput.pressKey("?");
      await setup.flush();
      assert.doesNotMatch(setup.captureCharFrame(), /r Scan now/);
      assert.equal(fixture.calls.filter((call) => call === "status").length, unsupported ? 1 : 0);
      assert.equal(fixture.calls.includes("scan"), false);
    }, { broker: fixture.broker, launchMode: "observe" });
  }
});

test("Auto polling palettes and help expose Scan now in both modes without capturing overlay r", async (context) => {
  for (const advanced of [false, true]) {
    const fixture = await automationFixture();
    await withSimpleRenderer(context, async (setup) => {
      await waitForFrame(setup, /Auto: Both/);
      if (advanced) { setup.mockInput.pressKey("a"); await setup.flush(); }
      setup.mockInput.pressKey("?");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /r Scan now/);
      setup.mockInput.pressKey("r");
      setup.mockInput.pressEscape();
      setup.mockInput.pressKey("p", { ctrl: true });
      setup.mockInput.pressKey("r");
      setup.mockInput.pressArrow("up");
      await setup.flush();
      assert.match(setup.captureCharFrame(), /> Scan now/);
      assert.equal(fixture.calls.includes("scan"), false);
      setup.mockInput.pressEnter();
      await setup.flush();
      assert.equal(fixture.calls.filter((call) => call === "scan").length, 1);
      assert.doesNotMatch(setup.captureCharFrame(), /DASHBOARD COMMANDS/);
    }, { broker: fixture.broker, width: 70, height: 8 });
  }
});

test("Auto polling is sequential and discards an old poll before a post-scan refresh without changing open details", { timeout: 20_000 }, async (context) => {
  const fixture = await automationFixture();
  const reducer = new OperationsReducer();
  reducer.apply(simpleLiveEvent("poll-pinned", 104));
  let queries = 0;
  let active = 0;
  let maximumActive = 0;
  let release!: () => void;
  fixture.broker.getAutomationStatus = async () => {
    queries++;
    maximumActive = Math.max(maximumActive, ++active);
    try {
      if (queries === 2) return await new Promise<AutomationStatus>((resolve) => {
        release = () => resolve({ ...fixture.status(), available: false, scope: null, agents: [] });
      });
      return fixture.status();
    } finally { active--; }
  };
  await withSimpleRenderer(context, async (setup) => {
    await waitForFrame(setup, /Auto: Both/);
    setup.mockInput.pressEnter();
    await setup.flush();
    await new Promise((resolve) => setTimeout(resolve, 5_100));
    assert.equal(queries, 2);
    await new Promise((resolve) => setTimeout(resolve, 5_100));
    assert.equal(queries, 2, "an unresolved read never starts another poll");
    fixture.setStatus({ ...fixture.status(), agents: fixture.status().agents.map((agent) => ({
      ...agent, state: "scanning", canScanNow: false,
    })) });
    setup.mockInput.pressKey("r");
    await setup.flush();
    assert.equal(queries, 2, "post-scan refresh waits for the older read to settle");
    release();
    await setup.flush();
    assert.equal(queries, 3);
    assert.equal(maximumActive, 1);
    assert.match(setup.captureCharFrame(), /Auto: Both \/ every 15m \/ scanning/);
    assert.match(setup.captureCharFrame(), /DETAILS/);
    assert.match(setup.captureCharFrame(), /contoso\/repo \/ PR #104/);
    assert.match(setup.captureCharFrame(), /r Scan now/);
  }, { broker: fixture.broker, reducer });
});

test("Auto polling ignores query and scan responses after quit without scheduling another read", async (context) => {
  for (const operation of ["status", "scan"]) {
    const fixture = await automationFixture();
    let release!: () => void;
    if (operation === "status") fixture.broker.getAutomationStatus = async () => {
      fixture.calls.push("status");
      return new Promise<AutomationStatus>((resolve) => { release = () => resolve(fixture.status()); });
    };
    else fixture.broker.scanNow = async () => {
      fixture.calls.push("scan");
      return new Promise<ScanNowResult>((resolve) => { release = () => resolve(fixture.result()); });
    };
    await withSimpleRenderer(context, async (setup) => {
      if (operation === "scan") {
        await waitForFrame(setup, /Auto: Both/);
        setup.mockInput.pressKey("r");
      }
      await setup.flush();
      setup.mockInput.pressKey("q");
      for (let index = 0; index < 5; index++) await Promise.resolve();
      assert.equal(setup.renderer.isDestroyed, true);
      release();
      for (let index = 0; index < 5; index++) await Promise.resolve();
      assert.equal(fixture.calls.filter((call) => call === "status").length, 1);
      assert.equal(fixture.calls.filter((call) => call === "scan").length, operation === "scan" ? 1 : 0);
    }, { broker: fixture.broker });
  }
});

test("Auto polling ignores pre-scan unavailable and error responses that settle before the scan response", { timeout: 20_000 }, async (context) => {
  for (const oldOutcome of ["unavailable", "error"]) {
    const fixture = await automationFixture();
    let queries = 0;
    let active = 0;
    let maximumActive = 0;
    let settleOld!: () => void;
    let completeScan!: () => void;
    fixture.broker.getAutomationStatus = async () => {
      queries++;
      maximumActive = Math.max(maximumActive, ++active);
      try {
        if (queries === 2) return await new Promise<AutomationStatus>((resolve, reject) => {
          settleOld = () => oldOutcome === "unavailable"
            ? resolve({ ...fixture.status(), available: false, scope: null, agents: [] })
            : reject(new Error("Obsolete status read failed"));
        });
        return fixture.status();
      } finally { active--; }
    };
    fixture.broker.scanNow = async () => {
      fixture.calls.push("scan");
      return new Promise<ScanNowResult>((resolve) => { completeScan = () => resolve(fixture.result()); });
    };
    await withSimpleRenderer(context, async (setup) => {
      await waitForFrame(setup, /Auto: Both \/ every 15m \/ waiting/);
      await new Promise((resolve) => setTimeout(resolve, 5_100));
      assert.equal(queries, 2);
      assert.equal(active, 1);
      setup.mockInput.pressKey("r");
      await setup.flush();
      assert.equal(fixture.calls.filter((call) => call === "scan").length, 1);
      assert.equal(queries, 2);
      settleOld();
      await setup.flush();
      assert.equal(active, 0, "the obsolete read still releases its real single-flight slot");
      assert.equal(queries, 2, "no fresh read starts before the scan finishes");
      assert.match(setup.captureCharFrame(), /Auto: Both \/ every 15m \/ waiting/);
      assert.match(setup.captureCharFrame(), /r Scan now/);
      assert.doesNotMatch(setup.captureCharFrame(), /Auto: unavailable|Obsolete status read failed|AUTO POLLING:/);
      fixture.setStatus({ ...fixture.status(), agents: fixture.status().agents.map((agent) => ({
        ...agent, state: "scanning", canScanNow: false,
      })) });
      completeScan();
      await setup.flush();
      assert.equal(queries, 3, "scan completion obtains a fresh status after the older read settled");
      assert.equal(maximumActive, 1);
      assert.match(setup.captureCharFrame(), /Auto: Both \/ every 15m \/ scanning/);
      assert.match(setup.captureCharFrame(), /Reviewer wake requested; Handler wake requested/);
      assert.match(setup.captureCharFrame(), /r Scan now/);
    }, { broker: fixture.broker, width: 70, height: 8 });
  }
});

test("Auto polling query errors disable control then recover on a bounded healthy retry; scan failures remain explicit", { timeout: 15_000 }, async (context) => {
  const fixture = await automationFixture();
  let queries = 0;
  fixture.broker.getAutomationStatus = async () => {
    queries++;
    if (queries === 1) throw new Error("Fixture status read failed");
    return fixture.status();
  };
  fixture.broker.scanNow = async () => { fixture.calls.push("scan"); throw new Error("Fixture wake failed"); };
  await withSimpleRenderer(context, async (setup) => {
    await waitForFrame(setup, /AUTO POLLING: Status unavailable/);
    assert.match(setup.captureCharFrame(), /Auto: unavailable/);
    setup.mockInput.pressKey("r");
    await setup.flush();
    assert.equal(fixture.calls.includes("scan"), false);
    await new Promise((resolve) => setTimeout(resolve, 5_100));
    await waitForFrame(setup, /Auto: Both/);
    assert.equal(queries, 2);
    setup.mockInput.pressKey("r");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /AUTO POLLING: Scan now failed: Fixture wake failed/);
    assert.match(setup.captureCharFrame(), /r Scan now/);
    assert.equal(queries, 3);
    assert.equal(fixture.calls.filter((call) => call === "scan").length, 1);
  }, { broker: fixture.broker, width: 70, height: 8 });
});

test("Auto polling fatal broker failure stops reads and disables Scan now without hiding the shortcut or failure", { timeout: 15_000 }, async (context) => {
  const fixture = await automationFixture();
  let failure = "";
  await withSimpleRenderer(context, async (setup) => {
    await waitForFrame(setup, /Auto: Both/);
    failure = "automatic-worker-failed: reviewer exited";
    await waitForFrame(setup, /BROKER FAILURE: automatic-worker-failed/);
    setup.mockInput.pressKey("r");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /r Scan now/);
    assert.match(setup.captureCharFrame(), /Auto: unavailable/);
    await new Promise((resolve) => setTimeout(resolve, 5_100));
    assert.equal(fixture.calls.filter((call) => call === "status").length, 1);
    assert.equal(fixture.calls.includes("scan"), false);
    failure = "";
    setup.mockInput.pressKey("r");
    await setup.flush();
    assert.equal(fixture.calls.includes("scan"), false, "a failed broker is never restarted by the UI");
  }, { broker: fixture.broker, brokerFailure: () => failure, width: 70, height: 8 });
});

test("Auto polling leaves manual input, rendered confirmation and terminal progress unchanged in PreviewOnly", async (context) => {
  const fixture = await automationFixture();
  let release!: () => void;
  fixture.broker.getAutomationStatus = async () => new Promise<AutomationStatus>((resolve) => {
    release = () => resolve(fixture.status());
  });
  const describe = fixture.broker.describe;
  fixture.broker.describe = async (...args) => ({ ...await describe(...args), capabilities: [], mandatoryDenies: ["EnablePush", "EnableApprovalVote"] });
  let terminal: ((value: DispatchTerminal) => void) | undefined;
  fixture.broker.subscribeTerminal = (listener) => { terminal = listener; return () => { terminal = undefined; }; };
  await withSimpleRenderer(context, async (setup) => {
    await openManualAndDescribe(setup);
    setup.mockInput.pressKey("p");
    await setup.mockInput.typeText("r");
    release();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Optional instructions \(1\/512 characters\)/);
    assert.doesNotMatch(setup.captureCharFrame(), /r Scan now/);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /Instructions: r/);
    assert.match(setup.captureCharFrame(), /No PR mutations allowed/);
    setup.mockInput.pressEnter();
    await setup.flush();
    assert.match(setup.captureCharFrame(), /STARTED/);
    setup.mockInput.pressKey("r");
    terminal?.({ schemaVersion: 1, requestId: "terminal", operation: "completed",
      dispatchId: "44444444-4444-4444-8444-444444444444", exitCode: 0 });
    await setup.flush();
    assert.match(setup.captureCharFrame(), /FINISHED \/ OUTCOME UNKNOWN/);
    assert.match(setup.captureCharFrame(), /PREVIEW ONLY/);
    assert.equal(fixture.calls.includes("scan"), false);
  }, { broker: fixture.broker, launchMode: "preview", width: 70 });
});

test("Auto polling r remains filter text and Settings refresh rather than Scan now", async (context) => {
  const fixture = await automationFixture();
  let profiles = 0;
  const profile = fixture.broker.profile;
  fixture.broker.profile = async (...args) => { profiles++; return profile(...args); };
  await withSimpleRenderer(context, async (setup) => {
    await waitForFrame(setup, /Auto: Both/);
    setup.mockInput.pressKey("a");
    setup.mockInput.pressKey("f", { shift: true });
    setup.mockInput.pressKey("/");
    await setup.mockInput.typeText("r");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /filter: r/);
    assert.equal(fixture.calls.includes("scan"), false);
    setup.mockInput.pressEscape();
    setup.mockInput.pressKey("s");
    await setup.flush();
    const before = profiles;
    setup.mockInput.pressKey("r");
    await setup.flush();
    assert.equal(profiles, before + 1);
    assert.equal(fixture.calls.includes("scan"), false);
  }, { broker: fixture.broker, history: createSettingsHistory(), height: 32 });
});
