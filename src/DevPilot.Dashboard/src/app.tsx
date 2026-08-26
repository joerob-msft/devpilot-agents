import { For, Show, createEffect, createMemo, createSignal, onCleanup } from "solid-js";
import { Portal, useKeyboard, useRenderer, useTerminalDimensions } from "@opentui/solid";
import { decideLayout } from "./layout.js";
import { age, duration, eventSummary, line, roleLabel, shortCommit, shortId, statusColor } from "./format.js";
import { liveElapsedMilliseconds, OperationsReducer } from "./reducer.js";
import type { AgentRole, BlockedWarning, Completion, InstanceState } from "./domain.js";
import type { EventTailer } from "./tailer.js";

const COLORS = {
  bg: "#101319",
  panel: "#171b23",
  panelAlt: "#1d222c",
  border: "#303744",
  text: "#d8dee9",
  muted: "#7f899a",
  accent: "#75baff",
  warning: "#f0b45a",
  error: "#ff6b6b",
  ok: "#61d6a7",
};

type Overlay = "none" | "events" | "palette" | "help";
type RoleFilter = "all" | AgentRole;

interface AppProps {
  reducer: OperationsReducer;
  tailer: EventTailer;
}

function Panel(props: {
  title: string;
  width?: number | `${number}%`;
  children: unknown;
  borderColor?: string;
  flexGrow?: number;
}) {
  const dimensions = {
    ...(props.width === undefined ? {} : { width: props.width }),
    ...(props.flexGrow === undefined ? {} : { flexGrow: props.flexGrow }),
  };
  return (
    <box
      title={` ${props.title} `}
      border
      borderStyle="single"
      borderColor={props.borderColor ?? COLORS.border}
      backgroundColor={COLORS.panel}
      {...dimensions}
      paddingX={1}
      overflow="hidden"
    >
      {props.children}
    </box>
  );
}

function Empty() {
  return (
    <box flexGrow={1} alignItems="center" justifyContent="center">
      <text fg={COLORS.muted}>Waiting for DevPilot event streams...</text>
    </box>
  );
}

function Rail(props: {
  instances: InstanceState[];
  selected: number;
  now: number;
  compact?: boolean;
}) {
  return (
    <Panel title={`INSTANCES ${props.instances.length}`} width={props.compact ? "100%" : 31}>
      <Show when={props.instances.length} fallback={<Empty />}>
        <scrollbox flexGrow={1} scrollY>
          <For each={props.instances}>
            {(instance, index) => {
              const selected = () => index() === props.selected;
              return (
                <box
                  backgroundColor={selected() ? COLORS.panelAlt : COLORS.panel}
                  paddingX={1}
                  paddingY={0}
                  marginBottom={1}
                  border={selected() ? ["left"] : false}
                  borderColor={statusColor(instance.status)}
                  flexDirection="column"
                >
                  <text fg={statusColor(instance.status)}>
                    {selected() ? "> " : "  "}
                    {instance.status.toUpperCase()}
                  </text>
                  <text fg={COLORS.text}>
                    {roleLabel(instance.agent)} {shortId(instance.instanceId)}
                  </text>
                  <text fg={COLORS.muted}>{line(instance.repository || "repository unknown", 25)}</text>
                  <text fg={COLORS.muted}>
                    {instance.pullRequestId ? `PR ${instance.pullRequestId}` : `cycle ${instance.cycleNumber || "-"}`} |{" "}
                    {age(instance.lastEventMs, props.now)}
                  </text>
                </box>
              );
            }}
          </For>
        </scrollbox>
      </Show>
    </Panel>
  );
}

function WarningBlock(props: { instance: InstanceState }) {
  return (
    <Show when={props.instance.blocked}>
      {(blocked: () => BlockedWarning) => (
        <box
          border
          borderStyle="single"
          borderColor={COLORS.warning}
          backgroundColor="#282117"
          height={blocked().nextRetry ? 5 : 4}
          paddingX={1}
          flexDirection="column"
          marginBottom={1}
        >
          <text height={1} fg={COLORS.warning}>BLOCKED: {line(blocked().reason, 100)}</text>
          <text height={1} fg={COLORS.text}>
            Outstanding: {blocked().outstanding.join(", ") || "not reported"} | Retryable:{" "}
            {blocked().retryable ? "yes" : "no"}
          </text>
          <Show when={blocked().nextRetry}>
            <text height={1} fg={COLORS.muted}>Next retry: {blocked().nextRetry}</text>
          </Show>
        </box>
      )}
    </Show>
  );
}

function completionLabel(instance: InstanceState): string {
  return instance.completion
    ? `${instance.completion.result}; delivered ${instance.completion.delivered || "n/a"}`
    : "work in progress";
}

function waitingLabel(instance: InstanceState): string {
  return instance.waiting
    ? `${instance.waiting.kind} in ${duration(instance.waiting.delayMilliseconds)}`
    : "no wait scheduled";
}

function FieldColumn(props: {
  label: string;
  value: string;
  detail?: string;
  valueColor?: string;
}) {
  return (
    <box flexDirection="column" flexGrow={1} minWidth={0} height={3}>
      <text height={1} fg={COLORS.muted}>{props.label}</text>
      <text height={1} fg={props.valueColor ?? COLORS.text}>{props.value}</text>
      <Show when={props.detail !== undefined}>
        <text height={1} fg={COLORS.muted}>{props.detail}</text>
      </Show>
    </box>
  );
}

function Detail(props: { instance: InstanceState | undefined; now: number }) {
  return (
    <Panel
      title={props.instance ? `${roleLabel(props.instance.agent)} / ${shortId(props.instance.instanceId)}` : "DETAIL"}
      flexGrow={1}
      borderColor={props.instance ? statusColor(props.instance.status) : COLORS.border}
    >
      <Show when={props.instance} fallback={<Empty />}>
        {(instance: () => InstanceState) => (
          <box flexDirection="column" flexGrow={1}>
            <WarningBlock instance={instance()} />
            <box flexDirection="row" gap={2} height={3} marginBottom={1}>
              <FieldColumn
                label="CURRENT PHASE"
                value={line(instance().phase, 60)}
                detail={`elapsed ${duration(liveElapsedMilliseconds(instance(), props.now))} | cycle ${instance().cycleNumber || "-"}`}
                valueColor={COLORS.accent}
              />
              <FieldColumn
                label="PULL REQUEST"
                value={instance().pullRequestId ? `#${instance().pullRequestId} ${line(instance().pullRequestTitle, 42)}` : "none selected"}
                detail={`commit ${shortCommit(instance().sourceCommit)}`}
              />
            </box>

            <box flexDirection="row" gap={2} height={3} marginBottom={1}>
              <FieldColumn
                label="CANDIDATES"
                value={`scanned ${instance().candidates.scanned} | selected ${instance().candidates.selected} | skipped ${instance().candidates.skipped}`}
              />
              <FieldColumn
                label="COMPLETION / NEXT WAIT"
                value={completionLabel(instance())}
                detail={waitingLabel(instance())}
                valueColor={instance().completion?.result === "failed" ? COLORS.error : COLORS.text}
              />
            </box>

            <box flexDirection="column" height={2} marginBottom={1}>
              <text height={1} fg={COLORS.muted}>RECENT CYCLES</text>
              <text height={1} fg={COLORS.text}>
                {instance().cycles.length
                  ? instance()
                      .cycles.slice(-4)
                      .map((cycle) => `#${cycle.cycleNumber} ${cycle.result} (${cycle.selected}/${cycle.scanned})`)
                      .join(" | ")
                  : "no completed cycles"}
              </text>
            </box>

            <Show when={instance().completion}>
              {(completion: () => Completion) => (
                <box
                  flexDirection="column"
                  height={completion().summary || completion().reason ? 3 : 2}
                  marginBottom={1}
                >
                  <text height={1} fg={COLORS.muted}>FINDINGS / DELIVERY</text>
                  <text height={1} fg={COLORS.text}>
                    critical {completion().findings.critical} | important {completion().findings.important} | suggestion{" "}
                    {completion().findings.suggestion}
                  </text>
                  <Show when={completion().summary || completion().reason}>
                    <text height={1} fg={completion().reason ? COLORS.warning : COLORS.muted}>
                      {line(completion().reason || completion().summary, 110)}
                    </text>
                  </Show>
                </box>
              )}
            </Show>

            <text height={1} fg={COLORS.muted}>TIMELINE (latest)</text>
            <scrollbox flexGrow={1} scrollY stickyScroll stickyStart="bottom">
              <For each={instance().timeline.slice(-30)}>
                {(event) => (
                  <text height={1} fg={event.level === "error" ? COLORS.error : event.level === "warning" ? COLORS.warning : COLORS.text}>
                    {new Date(event.timestampMs).toISOString().slice(11, 19)} {line(eventSummary(event), 112)}
                  </text>
                )}
              </For>
            </scrollbox>
          </box>
        )}
      </Show>
    </Panel>
  );
}

function Inspector(props: { instance: InstanceState | undefined }) {
  return (
    <Panel title="INSPECTOR" width={35}>
      <Show when={props.instance} fallback={<Empty />}>
        {(instance: () => InstanceState) => (
          <box flexDirection="column" gap={1}>
            <text fg={COLORS.muted}>SCOPE</text>
            <text fg={COLORS.text}>Organization: {line(instance().organization || "-", 20)}</text>
            <text fg={COLORS.text}>Project: {line(instance().project || "-", 25)}</text>
            <text fg={COLORS.text}>Repository: {line(instance().repository || "-", 22)}</text>
            <text fg={COLORS.text}>Target: {line(instance().target || "-", 26)}</text>
            <text fg={COLORS.text}>Operator: {line(instance().operator || "-", 24)}</text>
            <text fg={COLORS.muted}>CAPABILITIES</text>
            <text fg={COLORS.text}>Writes: {line(instance().writes || "not reported", 24)}</text>
            <text fg={COLORS.text}>Vote: {line(instance().vote || "not reported", 26)}</text>
            <text fg={COLORS.text}>{instance().capabilities.join(", ") || "not reported"}</text>
            <text fg={COLORS.muted}>LIFECYCLE</text>
            <text fg={statusColor(instance().status)}>
              {instance().lifecycle.toUpperCase()} / {instance().status.toUpperCase()}
            </text>
            <text fg={COLORS.text}>PID {instance().processId} | schema v{instance().schemaVersion}</text>
            <text fg={COLORS.text}>Last event {age(instance().lastEventMs)}</text>
            <text fg={COLORS.text}>Sequence {instance().lastSequence} | gaps {instance().gapCount}</text>
            <text fg={COLORS.text}>Duplicates ignored {instance().duplicateCount}</text>
            <text fg={COLORS.muted}>SOURCE HEALTH</text>
            <text fg={instance().sourceDiagnostics.length ? COLORS.warning : COLORS.ok}>
              {instance().sourceDiagnostics.length
                ? `${instance().sourceDiagnostics.length} bounded diagnostic(s)`
                : "stream healthy"}
            </text>
            <For each={instance().sourceDiagnostics.slice(-5)}>
              {(item) => <text fg={COLORS.warning}>{line(`${item.kind}: ${item.message}`, 31)}</text>}
            </For>
          </box>
        )}
      </Show>
    </Panel>
  );
}

function OverlayPanel(props: { title: string; children: unknown; width?: number; height?: number }) {
  const renderer = useRenderer();
  return (
    <Portal mount={renderer.root}>
      <box
        position="absolute"
        top="15%"
        left="15%"
        width={props.width ?? 70}
        height={props.height ?? 18}
        zIndex={100}
        border
        borderStyle="double"
        borderColor={COLORS.accent}
        backgroundColor="#111720"
        title={` ${props.title} `}
        padding={1}
        flexDirection="column"
      >
        {props.children}
      </box>
    </Portal>
  );
}

export function App(props: AppProps) {
  const renderer = useRenderer();
  const dimensions = useTerminalDimensions();
  const [now, setNow] = createSignal(Date.now());
  const [revision, setRevision] = createSignal(0);
  const [selected, setSelected] = createSignal(0);
  const [detailOpen, setDetailOpen] = createSignal(false);
  const [railOpen, setRailOpen] = createSignal(true);
  const [inspectorOpen, setInspectorOpen] = createSignal(dimensions().width >= 120);
  const [overlay, setOverlay] = createSignal<Overlay>("none");
  const [role, setRole] = createSignal<RoleFilter>("all");
  const [eventWarningsOnly, setEventWarningsOnly] = createSignal(false);
  const [paletteIndex, setPaletteIndex] = createSignal(0);
  const palette = ["Open overview", "Open detail", "Toggle inspector", "Next warning", "Show help"];

  const refreshTimer = setInterval(() => {
    setNow(Date.now());
    setRevision((value) => value + 1);
  }, 1000);
  onCleanup(() => clearInterval(refreshTimer));

  const instances = createMemo(() => {
    revision();
    const selectedRole = role();
    return props.reducer.list(now(), selectedRole === "all" ? undefined : selectedRole);
  });
  const current = createMemo(() => instances()[Math.min(selected(), Math.max(0, instances().length - 1))]);
  const layout = createMemo(() => decideLayout(dimensions().width, detailOpen(), inspectorOpen(), railOpen()));
  const counts = createMemo(() => {
    revision();
    return props.reducer.counts(now());
  });
  const footer = createMemo(() => {
    const longCounts = `FAILED ${counts().failed} | BLOCKED ${counts().blocked} | RUNNING ${counts().running} | WAITING ${counts().waiting} | COMPLETED ${counts().completed} | STALE ${counts().stale}`;
    const shortCounts = `F ${counts().failed}  B ${counts().blocked}  R ${counts().running}  W ${counts().waiting}  C ${counts().completed}  S ${counts().stale}`;
    const wideHint = "arrows/jk select | Enter detail | Esc overview | Tab role | i/e overlays | Ctrl+P | ? | q";
    if (dimensions().width >= longCounts.length + wideHint.length + 4) {
      return { counts: longCounts, hint: wideHint };
    }
    if (dimensions().width >= 100) {
      return { counts: shortCounts, hint: "arrows/jk | Enter | Tab role | i/e | ? | q" };
    }
    if (dimensions().width >= 75) {
      return { counts: shortCounts, hint: "Enter detail | ? | q" };
    }
    return {
      counts: `F${counts().failed} B${counts().blocked} R${counts().running}`,
      hint: "Enter | ? | q",
    };
  });

  createEffect(() => {
    if (selected() >= instances().length) setSelected(Math.max(0, instances().length - 1));
  });

  function move(delta: number): void {
    if (!instances().length) return;
    setSelected((value) => (value + delta + instances().length) % instances().length);
  }

  function nextWarning(): void {
    if (!instances().length) return;
    const start = selected();
    for (let offset = 1; offset <= instances().length; offset++) {
      const index = (start + offset) % instances().length;
      const candidate = instances()[index];
      if (candidate && (candidate.status === "failed" || candidate.status === "blocked" || candidate.sourceDiagnostics.length > 0)) {
        setSelected(index);
        setDetailOpen(true);
        return;
      }
    }
  }

  function executePalette(): void {
    switch (paletteIndex()) {
      case 0:
        setDetailOpen(false);
        break;
      case 1:
        setDetailOpen(true);
        break;
      case 2:
        setInspectorOpen((value) => !value);
        break;
      case 3:
        nextWarning();
        break;
      case 4:
        setOverlay("help");
        return;
    }
    setOverlay("none");
  }

  useKeyboard((key) => {
    if (key.ctrl && key.name === "p") {
      setOverlay("palette");
      setPaletteIndex(0);
      return;
    }
    if (overlay() === "palette") {
      if (key.name === "escape") setOverlay("none");
      else if (key.name === "up" || key.name === "k") setPaletteIndex((value) => (value + palette.length - 1) % palette.length);
      else if (key.name === "down" || key.name === "j") setPaletteIndex((value) => (value + 1) % palette.length);
      else if (key.name === "return") executePalette();
      return;
    }
    if (overlay() === "events") {
      if (key.name === "escape") setOverlay("none");
      else if (key.name === "left" || key.name === "right" || key.name === "e") setEventWarningsOnly((value) => !value);
      return;
    }
    if (overlay() === "help") {
      if (key.name === "escape" || key.name === "?") setOverlay("none");
      return;
    }
    if (key.name === "q") {
      void props.tailer.stop().finally(() => renderer.destroy());
    } else if (key.name === "up" || key.name === "k") move(-1);
    else if (key.name === "down" || key.name === "j") move(1);
    else if (key.name === "return") setDetailOpen(true);
    else if (key.name === "escape") {
      if (layout().inspectorOverlay) setInspectorOpen(false);
      else setDetailOpen(false);
    }
    else if (key.name === "b") {
      if (layout().mode === "compact") setDetailOpen(false);
      else setRailOpen((value) => !value);
    }
    else if (key.name === "i") setInspectorOpen((value) => !value);
    else if (key.name === "e") setOverlay("events");
    else if (key.name === "w") nextWarning();
    else if (key.name === "?") setOverlay("help");
    else if (key.name === "tab") {
      const values: RoleFilter[] = ["all", "reviewer", "review-handler"];
      const direction = key.shift ? -1 : 1;
      setRole((value) => values[(values.indexOf(value) + direction + values.length) % values.length] ?? "all");
      setSelected(0);
    }
  });

  const overlayEvents = createMemo(() => {
    const events = current()?.timeline ?? [];
    return (eventWarningsOnly() ? events.filter((item) => item.level === "warning" || item.level === "error") : events).slice(-40);
  });
  const diagnostics = createMemo(() => {
    revision();
    return props.reducer.globalDiagnostics();
  });

  return (
    <box width="100%" height="100%" flexDirection="column" backgroundColor={COLORS.bg}>
      <box height={1} paddingX={1} flexDirection="row" justifyContent="space-between" backgroundColor={COLORS.panelAlt}>
        <text fg={COLORS.accent}>DEVPILOT OPERATIONS</text>
        <text fg={COLORS.muted}>OBSERVE ONLY | role: {role().toUpperCase()} | {layout().mode.toUpperCase()}</text>
      </box>
      <box flexGrow={1} flexDirection="row" gap={1} padding={1} overflow="hidden">
        <Show when={layout().showRail}>
          <Rail instances={instances()} selected={selected()} now={now()} compact={layout().mode === "compact"} />
        </Show>
        <Show when={layout().showDetail}>
          <Detail instance={current()} now={now()} />
        </Show>
        <Show when={layout().showInspector && !layout().inspectorOverlay}>
          <Inspector instance={current()} />
        </Show>
      </box>
      <Show when={diagnostics().length > 0}>
        <box height={1} paddingX={1} backgroundColor="#282117">
          <text fg={COLORS.warning}>
            SOURCE WARNING: {line(diagnostics().at(-1)?.message ?? "event source error", Math.max(20, dimensions().width - 20))}
          </text>
        </box>
      </Show>
      <box height={1} paddingX={1} flexDirection="row" justifyContent="space-between" backgroundColor={COLORS.panelAlt}>
        <text fg={COLORS.text}>
          {footer().counts}
        </text>
        <text fg={COLORS.muted}>{footer().hint}</text>
      </box>

      <Show when={layout().showInspector && layout().inspectorOverlay}>
        <OverlayPanel title="INSPECTOR" width={58} height={25}>
          <Inspector instance={current()} />
        </OverlayPanel>
      </Show>
      <Show when={overlay() === "events"}>
        <OverlayPanel title={`EVENTS - ${eventWarningsOnly() ? "WARNINGS" : "ALL"} (left/right filter)`} width={88} height={28}>
          <scrollbox flexGrow={1} scrollY stickyScroll stickyStart="bottom">
            <For each={overlayEvents()} fallback={<text fg={COLORS.muted}>No matching events.</text>}>
              {(event) => (
                <text fg={event.level === "error" ? COLORS.error : event.level === "warning" ? COLORS.warning : COLORS.text}>
                  {new Date(event.timestampMs).toISOString()} {line(eventSummary(event), 68)}
                </text>
              )}
            </For>
          </scrollbox>
        </OverlayPanel>
      </Show>
      <Show when={overlay() === "palette"}>
        <OverlayPanel title="COMMAND PALETTE - READ ONLY" width={60} height={14}>
          <For each={palette}>
            {(command, index) => (
              <text fg={index() === paletteIndex() ? COLORS.accent : COLORS.text}>
                {index() === paletteIndex() ? "> " : "  "}{command}
              </text>
            )}
          </For>
          <text fg={COLORS.muted}>Up/Down select | Enter run | Esc dismiss</text>
        </OverlayPanel>
      </Show>
      <Show when={overlay() === "help"}>
        <OverlayPanel title="HELP - OBSERVE MODE" width={72} height={19}>
          <text fg={COLORS.text}>Up/Down or j/k  Select an instance</text>
          <text fg={COLORS.text}>Enter            Open detail</text>
          <text fg={COLORS.text}>Esc / b          Overview / instance rail</text>
          <text fg={COLORS.text}>Tab / Shift+Tab  Cycle all, reviewer, review-handler</text>
          <text fg={COLORS.text}>i                Inspector</text>
          <text fg={COLORS.text}>e                Events overlay; arrows change filter</text>
          <text fg={COLORS.text}>w                Next warning or failed instance</text>
          <text fg={COLORS.text}>Ctrl+P           Command palette</text>
          <text fg={COLORS.text}>?                Help</text>
          <text fg={COLORS.text}>q                Quit</text>
          <text fg={COLORS.warning}>No process controls or write actions are available.</text>
        </OverlayPanel>
      </Show>
    </box>
  );
}
