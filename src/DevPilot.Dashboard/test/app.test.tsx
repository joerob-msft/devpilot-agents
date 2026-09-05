import assert from "node:assert/strict";
import test from "node:test";
import { testRender } from "@opentui/solid";
import type { TestRendererSetup } from "@opentui/core/testing";
import {
  App, BRAND_PLANE, HELP_LEGEND, appendPromptScalar, completionResultColor,
  printableKeySequence, safeHttpUrl, selectableCount,
} from "../src/app.js";
import { parseAgentEvent, type AgentRole } from "../src/domain.js";
import { OperationsReducer } from "../src/reducer.js";
import { EventTailer } from "../src/tailer.js";
import { PullRequestHistoryProjection } from "../src/history.js";
import { createDashboardLifecycle } from "../src/lifecycle.js";
import type {
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
  WideningCancelled,
  WideningMinted,
  WideningPreview,
  WideningSummary,
} from "../src/dispatch.js";
import { BrokerRejectionError } from "../src/dispatch.js";

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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} />, {
      width: 140,
      height: 32,
      kittyKeyboard: true,
    });
    await setup.renderOnce();
    setup.mockInput.pressKey("f");
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
    setup = await testRender(() => <App reducer={fixture.reducer} tailer={fixture.tailer} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={wrappedBroker} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
      width: 140, height: 32, kittyKeyboard: true,
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
    profile: async () => { throw new Error("not called"); },
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
  setup.mockInput.pressKey("f");
  await setup.flush();
  setup.mockInput.pressKey("m");
  await setup.flush();
  if (role === "review-handler") {
    setup.mockInput.pressTab();
    await setup.flush();
  }
  setup.mockInput.pressKey("d", { ctrl: true });
  await setup.flush();
}

test("manual dispatch widening: reviewer mints EnableApprovalVote via two explicit confirms, shows the paired EnableFindingComments requirement, never auto-dispatches, and the existing d/y gate dispatches the minted digest", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls, dispatchedSummaries } = createWideningBrokerFixture({ role: "reviewer" });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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

    setup.mockInput.pressKey("c");
    await setup.flush();
    assert.equal(calls.at(-1), "confirm-widening-preview");
    assert.match(setup.captureCharFrame(), /Final widening blast radius: EnableApprovalVote/);
    assert.match(setup.captureCharFrame(), /Single-use grant; expires/);
    assert.match(setup.captureCharFrame(), /Unavailable to headless\/direct\/watcher dispatch/);
    assert.match(setup.captureCharFrame(), /FINAL WIDENING CONFIRMATION: press y/);

    setup.mockInput.pressKey("y");
    await setup.flush();
    assert.equal(calls.at(-1), "confirm-widening-mint");
    assert.equal(calls.includes("dispatch"), false, "minting must never auto-dispatch");
    assert.match(setup.captureCharFrame(), /Widening grant minted and active for this draft/);
    assert.match(setup.captureCharFrame(), /vote-grant dispatch: skips forced fresh analysis/);
    assert.match(setup.captureCharFrame(), /Enabled: EnableApprovalVote/);

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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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
    setup = await testRender(() => <App reducer={fixture1.reducer} history={history1} tailer={fixture1.tailer} broker={emptyBroker} />, {
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
    setup2 = await testRender(() => <App reducer={fixture2.reducer} history={history2} tailer={fixture2.tailer} broker={killSwitchBroker} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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
    setup = await testRender(() => <App reducer={fixture.reducer} history={history} tailer={fixture.tailer} broker={broker} />, {
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
    assert.doesNotMatch(setup.captureCharFrame(), /MANUAL DISPATCH/);
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
  for (const width of [60, 80, 120]) {
    const fixture = createFixture();
    const history = createSettingsHistory();
    let setup: TestRendererSetup | undefined;
    try {
      setup = await testRender(() => (
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
      assert.match(initial, /f History/);
      assert.match(initial, /m launch/);

      setup.mockInput.pressKey("f");
      await setup.flush();
      const historyFrame = setup.captureCharFrame();
      assert.match(historyFrame, /PR history 1/);
      assert.match(historyFrame, /selected repo #104/);
      assert.match(historyFrame, /m launch/);
      assert.match(historyFrame, /Tab role/);
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

test("PreviewOnly chrome locks widening even when a broker reports a delegable capability", async (context) => {
  const fixture = createFixture();
  const history = createSettingsHistory();
  const { broker, calls } = createWideningBrokerFixture({
    role: "reviewer",
    delegableAvailable: ["EnableApprovalVote"],
  });
  let setup: TestRendererSetup | undefined;
  try {
    setup = await testRender(() => (
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

    await openManualAndDescribe(setup);
    assert.match(setup.captureCharFrame(), /Widening locked by PreviewOnly/);
    setup.mockInput.pressKey("w");
    await setup.flush();
    assert.equal(calls.includes("describe-widening:EnableApprovalVote"), false);

    setup.mockInput.pressEscape();
    await setup.flush();
    setup.mockInput.pressKey("s");
    await setup.flush();
    assert.match(setup.captureCharFrame(), /PreviewOnly is a terminal ceiling/);
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
