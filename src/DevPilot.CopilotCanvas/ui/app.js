// DevPilot Operations canvas UI. Talks only to its own loopback extension server (same origin).
const nonce = document.querySelector('meta[name="devpilot-nonce"]').content;
const $ = (id) => document.getElementById(id);
const POLL_MS = 1500;
const MAX_PROMPT = 512;
const ROLE_LABEL = { reviewer: "Reviewer", "review-handler": "Review Handler" };
const BUSY = new Set(["already-running", "state-contended"]);
const REPREVIEW = new Set(["unknown-draft", "source-changed", "policy-changed", "pr-state-changed",
  "schedule-repreview-required", "schedule-expired"]);
const ERROR_TEXT = {
  "already-running": "Another run holds this PR's work lease or the repository state.",
  "state-contended": "Another agent is using this repository's state.",
  "source-changed": "The PR source changed after the preview. Preview it again.",
  "policy-changed": "The capability policy changed. Preview it again.",
  "pr-state-changed": "The PR state changed. Preview it again.",
  "delivery-pending": "Reviewer delivery is pending for this PR; resolve it before redispatch.",
  "mcp-unavailable": "Azure DevOps MCP was unavailable; no agent was started.",
  "launch-failed": "The broker could not safely launch the agent.",
  "role-not-allowed": "This role is not enabled by the Golden watch.",
  "schedule-stale": "Current work changed. Review the new proposal.",
  "schedule-expired": "The proposal expired. Preview again.",
  "schedule-repreview-required": "A fresh preview is required.",
  "scheduling-unavailable": "Replace / Run next is not available for this watch.",
  "unknown-draft": "The preview expired. Preview the PR again.",
  "invalid-prompt": "Instructions must be at most 512 characters without control characters.",
  "invalid-pull-request-id": "Enter a PR number between 1 and 2147483647.",
  "launch-repreview-required": "Preview the launch plan again before starting.",
  "terminal-owned": "This watch runs in a terminal. Quit its dashboard from that terminal to stop it.",
  "invalid-history-key": "That history entry is no longer valid. Refresh the view.",
  "unknown-history-key": "That history entry is no longer available.",
  "history-unavailable": "PR history is not available from this watch version.",
};

const state = {
  connection: null, data: null, view: "live", selected: "", modal: null, noticeTimer: 0, refreshError: false,
  idsOpen: false, detailSig: "",
  launchUi: { previewOnly: false, plan: null, busy: false, error: "", armed: false, armScheduled: false, key: "", since: 0 },
};

class ApiError extends Error {
  constructor(status, code, detail) {
    super(detail || code || `HTTP ${status}`);
    this.status = status;
    this.code = code || "";
    this.detail = detail || "";
  }
}

async function api(path, body) {
  const init = { method: body === undefined ? "GET" : "POST", headers: { "x-canvas-nonce": nonce } };
  if (body !== undefined) {
    init.headers["content-type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  const response = await fetch(path, init);
  const json = await response.json().catch(() => ({}));
  if (!response.ok) throw new ApiError(response.status, json.error, json.detail);
  return json;
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function duration(ms) {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) return "—";
  const seconds = Math.max(0, Math.round(ms / 1000));
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h) return `${h}h ${String(m).padStart(2, "0")}m`;
  if (m) return `${m}m ${String(s).padStart(2, "0")}s`;
  return `${s}s`;
}

function clock(ms) {
  return ms ? new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }) : "";
}

// Time only for today; date and time otherwise, so History entries from earlier days are unambiguous.
function when(ms) {
  if (!ms) return "";
  const date = new Date(ms);
  if (date.toDateString() === new Date().toDateString()) return clock(ms);
  return date.toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

function safeUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:" ? url.href : "";
  } catch {
    return "";
  }
}

function errorText(error) {
  if (!(error instanceof ApiError)) return String(error?.message ?? error);
  if (error.status >= 500 && !error.code.startsWith("invalid")) {
    return `Status unknown (${error.detail || error.code}). Check the Watch dashboard before retrying.`;
  }
  const label = ERROR_TEXT[error.code] ?? `Rejected: ${error.code || error.status}`;
  return error.detail && !label.includes(error.detail) ? `${label} ${error.detail}` : label;
}

function notice(text) {
  const node = $("notice");
  node.textContent = text;
  node.hidden = false;
  clearTimeout(state.noticeTimer);
  state.noticeTimer = setTimeout(() => { node.hidden = true; }, 5_000);
}

// Errors stay until dismissed (or, for polling errors, until polling recovers).
function showError(text, fromRefresh = false) {
  state.refreshError = fromRefresh;
  $("error-text").textContent = text;
  $("error").hidden = false;
}

function clearError() {
  state.refreshError = false;
  $("error").hidden = true;
}

// Elements carrying data-since show a live elapsed counter without re-rendering their section.
function tick() {
  for (const node of document.querySelectorAll("[data-since]")) {
    node.textContent = duration(Date.now() - Number(node.dataset.since));
  }
}

function since(startMs) {
  return el("span", { "data-since": String(startMs) }, duration(Date.now() - startMs));
}

// ---------------------------------------------------------------------------------------------
// Polling: fast while something is running, slower when idle, paused while the canvas is hidden.
// ---------------------------------------------------------------------------------------------

let pollTimer = 0;
let polling = false;

function pollDelay() {
  const { connection, data } = state;
  if (connection?.launch?.state === "starting" || state.launchUi.busy) return 1_500;
  if (!data) return 5_000;
  const active = data.runs?.some((run) => !run.terminal) || data.queued?.length ||
    (state.view === "live" && data.instances?.some((item) => item.status === "running" || item.status === "waiting"));
  return active ? 1_500 : 4_000;
}

async function refresh() {
  try {
    const result = await api(`/api/state?view=${encodeURIComponent(state.view)}`);
    state.connection = result.connection;
    state.data = result.data;
    if (state.refreshError) clearError();
    render();
    if (result.prefill && !$("modal").open && state.data) {
      openModal(result.prefill.pullRequestId, result.prefill.role);
      api("/api/prefill/clear", {}).catch(() => {});
    }
  } catch (error) {
    showError(`Canvas error: ${errorText(error)}`, true);
  }
}

async function loop() {
  clearTimeout(pollTimer);
  if (polling) return;
  polling = true;
  try {
    await refresh();
  } finally {
    polling = false;
  }
  if (!document.hidden) pollTimer = setTimeout(loop, pollDelay());
}

// ---------------------------------------------------------------------------------------------
// Page rendering. Sections are patched in place so polling keeps focus, scroll, selection and
// open <details>.
// ---------------------------------------------------------------------------------------------

function automationChips(automation) {
  if (!automation) return [];
  if (!automation.available) {
    return [el("span", { class: "chip" }, automation.error ? `Automation unavailable (${automation.error})` : "Automation unavailable")];
  }
  return automation.agents.map((agent) => {
    const parts = [`${ROLE_LABEL[agent.role] ?? agent.role}: ${agent.state}`];
    if (agent.continuous && agent.intervalSeconds) parts.push(`every ${Math.round(agent.intervalSeconds / 60)}m`);
    const retryAt = agent.state === "retrying" && agent.retryAtUtc ? Date.parse(agent.retryAtUtc) : NaN;
    if (Number.isFinite(retryAt)) parts.push(`retry in ${duration(Math.max(0, retryAt - Date.now()))}`);
    return el("span", { class: `chip ${agent.state}` }, parts.join(" · "));
  });
}

function repositoryName(path) {
  return String(path || "").split(/[\\/]/).filter(Boolean).pop() || "(unknown repository)";
}

function render() {
  const { connection, data } = state;
  const connected = Boolean(data);
  const mode = $("mode");
  mode.hidden = !connected;
  if (connected) {
    mode.textContent = data.launchMode === "operational" ? "OPERATIONAL" : data.launchMode === "preview" ? "PREVIEW ONLY" : "OBSERVE ONLY";
    mode.className = `badge ${data.launchMode}`;
  }
  const started = connection?.bridge?.startedAtUtc ? Date.parse(connection.bridge.startedAtUtc) : NaN;
  const subtitle = $("subtitle");
  subtitle.title = connected ? `${data.consumerRepositoryRoot} · dashboard PID ${data.dashboardPid}` : "";
  subtitle.textContent = connected
    ? [repositoryName(data.consumerRepositoryRoot), Number.isFinite(started) ? `started ${when(started)}` : "",
      data.headless ? "running from this canvas" : "running in a terminal"].filter(Boolean).join(" · ")
    : connection?.workingDirectory ? `Session folder: ${connection.workingDirectory}` : "";
  const automation = $("automation");
  const chipsKey = connected ? JSON.stringify(data.automation) : "";
  if (automation.dataset.sig !== chipsKey || data?.automation?.agents?.some((agent) => agent.state === "retrying")) {
    automation.dataset.sig = chipsKey;
    automation.replaceChildren(...(connected ? automationChips(data.automation) : []));
  }
  // With no watch there is nothing to scan, review or view: the launch panel's Start is the only action.
  $("scan").hidden = !connected;
  $("scan").disabled = !connected || !data.automation?.available || !data.automation.agents.some((agent) => agent.canScanNow);
  $("review").hidden = !connected;
  $("review").disabled = !connected || data.launchMode === "observe";
  $("stop").hidden = !connected;
  $("stop").title = connected && data.headless !== true ? "This watch runs in a terminal; quit it there." : "";
  $("tabs").hidden = !connected;
  for (const tab of document.querySelectorAll("#tabs [role=tab]")) {
    const selected = tab.dataset.view === state.view;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
    if (selected) $("main").setAttribute("aria-labelledby", tab.id);
  }
  renderDisconnected();
  renderRuns();
  renderMain();
}

function renderDisconnected() {
  const { connection, data } = state;
  const section = $("disconnected");
  section.hidden = Boolean(data);
  if (data || !connection) return;
  $("disconnected-title").textContent = connection.state === "no-bridge"
    ? "No Golden watch for this repository"
    : `Lost connection to the Golden watch (${connection.error || connection.state})`;
  $("command").textContent = connection.command;
  // Default the terminal fallback open only when canvas Start is unavailable; never fight the user's toggle.
  const startAvailable = Boolean(connection.launcher?.available);
  if (state.launchUi.startAvailable !== startAvailable) {
    state.launchUi.startAvailable = startAvailable;
    $("manual-start").open = !startAvailable;
  }
  renderLaunch(connection);
  const others = $("others");
  const othersKey = JSON.stringify(connection.others ?? []);
  if (others.dataset.sig === othersKey) return;
  others.dataset.sig = othersKey;
  others.replaceChildren();
  if (connection.others?.length) {
    others.append(el("p", { class: "muted small", text: "Other running watches on this machine:" }));
    for (const other of connection.others) {
      others.append(el("div", { class: "run" },
        el("span", {}, `${other.consumerRepositoryRoot || "(unknown repository)"} · ${other.launchMode} · started ${new Date(other.startedAtUtc).toLocaleString()}`),
        el("button", { type: "button", onclick: () => connectTo(other.watchId) }, "Connect anyway")));
    }
  }
}

async function connectTo(watchId) {
  try {
    await api("/api/connect", { watchId });
    await refresh();
  } catch (error) {
    showError(errorText(error));
  }
}

// ---------------------------------------------------------------------------------------------
// Start / Stop the Golden watch: Start watch… -> -WhatIf launch plan -> (render-gated) Confirm start.
// Only a click here can start or stop a watch; no agent action exists for either.
// ---------------------------------------------------------------------------------------------

async function copyText(text, label) {
  try {
    await navigator.clipboard.writeText(text);
    notice(`${label} copied.`);
  } catch {
    showError(`Could not copy the ${label.toLowerCase()}. Select it in the panel instead.`);
  }
}

function renderLaunch(connection) {
  const ui = state.launchUi;
  const { launcher, launch } = connection;
  const key = JSON.stringify({
    launcher, launch: launch && { state: launch.state, pid: launch.pid, logTail: launch.logTail },
    previewOnly: ui.previewOnly, plan: ui.plan && [ui.plan.launchToken, ui.plan.ok, ui.plan.output],
    busy: ui.busy, error: ui.error, armed: ui.armed,
  });
  if (key === ui.key) return;
  ui.key = key;
  const root = $("launch");
  root.replaceChildren();
  if (!launcher) return;
  if (!launcher.available) {
    root.append(el("p", { class: "muted" }, `Starting from the canvas is unavailable: ${launcher.reason}`));
    return;
  }
  if (launch?.state === "starting") {
    root.append(el("p", { role: "status" }, el("span", { class: "spinner", "aria-hidden": "true" }),
      `Starting the ${launch.previewOnly ? "preview-only " : ""}Golden watch (PID ${launch.pid})… `, since(Date.now() - launch.elapsedMs)),
    el("p", { class: "muted small" }, `${launch.kind === "repository" ? "Installing or verifying the toolkit can take several minutes. " : ""}This canvas connects when it is ready.`),
    el("p", { class: "muted small" }, `Log: ${launch.logPath}`));
    if (launch.logTail) root.append(el("pre", { class: "plan" }, launch.logTail));
    return;
  }
  if (launch?.state === "failed") {
    root.append(el("p", { class: "error-text", role: "alert" }, "The Golden watch did not start."),
      el("p", { class: "muted small" }, `Log: ${launch.logPath}`),
      el("div", { class: "launch-row" },
        el("button", { type: "button", onclick: () => copyText(launch.logPath, "Log path") }, "Copy log path"),
        launch.logTail ? el("button", { type: "button", onclick: () => copyText(launch.logTail, "Log output") }, "Copy log output") : null));
    if (launch.logTail) root.append(el("pre", { class: "plan" }, launch.logTail));
  }
  root.append(
    el("p", { class: "muted" }, "Start this repository's Golden watch from here, without a terminal. It keeps running while the Copilot app is open, even if you close this canvas, until you stop it here. Quitting the app stops it and its agents."),
    el("div", { class: "muted small" }, `Repository: ${launcher.repositoryRoot}`),
    launcher.kind === "repository"
      ? el("div", { class: "muted small" }, `Runs: ${launcher.script} (installs or updates the DevPilot toolkit per this repository's lock, prepares config and state, applies its defaults)`)
      : el("div", { class: "muted small" }, `Toolkit: ${launcher.toolkitRoot}${launcher.version ? ` (v${launcher.version})` : ""}`),
    launcher.note ? el("div", { class: "muted small" }, launcher.note) : null,
    el("div", { class: "launch-row" },
      el("label", {},
        el("input", {
          type: "checkbox", id: "launch-preview-only", checked: ui.previewOnly, disabled: ui.busy,
          onchange: (event) => { Object.assign(ui, { previewOnly: event.target.checked, plan: null, error: "", armed: false }); renderLaunch(state.connection); },
        }),
        "Preview only (no writes, notifications or grants for the lifetime of this watch)")));
  if (ui.error) root.append(el("p", { class: "error-text", role: "alert" }, ui.error));
  if (ui.busy && !ui.plan) {
    root.append(el("p", { role: "status" }, el("span", { class: "spinner", "aria-hidden": "true" }),
      "Checking the launch plan… ", since(ui.since)));
    return;
  }
  if (!ui.plan) {
    root.append(el("div", { class: "launch-row" },
      el("button", { type: "button", class: "primary", id: "launch-begin", onclick: previewLaunch }, "Start watch…"),
      el("span", { class: "muted small" }, "Shows the launch plan first; nothing starts until you confirm.")));
    return;
  }
  root.append(el("h3", {}, ui.plan.ok ? "Launch plan" : "This watch cannot start yet"),
    el("pre", { class: "plan" }, ui.plan.output || "(no output)"));
  if (!ui.plan.ok) {
    root.append(el("p", { class: "error-text" }, "Fix the problems above, then try again."),
      el("div", { class: "launch-row" }, el("button", { type: "button", onclick: previewLaunch }, "Check again")));
    return;
  }
  root.append(el("div", { class: "launch-row" },
    el("button", { type: "button", onclick: () => { Object.assign(ui, { plan: null, armed: false }); renderLaunch(state.connection); } }, "Back"),
    el("button", { type: "button", class: "primary", id: "launch-start", disabled: !ui.armed || ui.busy, onclick: startWatch },
      ui.busy ? "Starting…" : ui.plan.previewOnly ? "Confirm start (preview only)" : "Confirm start"),
    el("span", { class: "muted small" }, ui.plan.command)));
  // Like the review Start button: clickable only after the plan it confirms has painted.
  if (!ui.armed && !ui.armScheduled) {
    ui.armScheduled = true;
    requestAnimationFrame(() => requestAnimationFrame(() => {
      ui.armScheduled = false;
      ui.armed = true;
      renderLaunch(state.connection);
    }));
  }
}

async function previewLaunch() {
  const ui = state.launchUi;
  if (ui.busy) return;
  Object.assign(ui, { busy: true, plan: null, error: "", armed: false, since: Date.now() });
  renderLaunch(state.connection);
  try {
    ui.plan = await api("/api/watch/preview", { previewOnly: ui.previewOnly });
  } catch (error) {
    ui.error = errorText(error);
  } finally {
    ui.busy = false;
    renderLaunch(state.connection);
  }
}

async function startWatch() {
  const ui = state.launchUi;
  if (ui.busy || !ui.armed || !ui.plan?.ok) return;
  ui.busy = true;
  renderLaunch(state.connection);
  try {
    await api("/api/watch/start", { launchToken: ui.plan.launchToken });
    Object.assign(ui, { plan: null, error: "", armed: false });
    notice("Starting the Golden watch…");
  } catch (error) {
    Object.assign(ui, { plan: null, armed: false, error: errorText(error) });
  } finally {
    ui.busy = false;
    await loop();
  }
}

// One confirmation pattern for every destructive action; the confirm button is render-gated.
function confirmAction(title, text, okLabel) {
  const dialog = $("confirm");
  $("confirm-title").textContent = title;
  $("confirm-text").textContent = text;
  const ok = $("confirm-ok");
  ok.textContent = okLabel;
  return new Promise((resolveConfirm) => {
    const finish = (value) => {
      ok.onclick = null;
      $("confirm-cancel").onclick = null;
      dialog.onclose = null;
      if (dialog.open) dialog.close();
      resolveConfirm(value);
    };
    ok.onclick = () => finish(true);
    $("confirm-cancel").onclick = () => finish(false);
    dialog.onclose = () => finish(false);
    dialog.showModal();
    gate(ok);
    $("confirm-cancel").focus();
  });
}

async function stopWatch() {
  const data = state.data;
  if (!data) return;
  if (data.headless !== true) {
    showError(ERROR_TEXT["terminal-owned"]);
    return;
  }
  if (!await confirmAction("Stop the Golden watch?", "The watch and any agents it is running will be stopped. You can start it again from this canvas.", "Stop watch")) return;
  const button = $("stop");
  button.disabled = true;
  try {
    await api("/api/watch/stop", {});
    notice("Stopping the Golden watch and its agents…");
  } catch (error) {
    showError(errorText(error));
  } finally {
    button.disabled = false;
    await refresh();
  }
}

// Reuses unchanged row nodes (by data-key/data-sig) and only reorders when needed, so polling keeps
// focus and scroll; update() refreshes the cheap per-poll parts (elapsed, selection) in place.
function patchList(container, items, keyOf, sigOf, build, update) {
  const existing = new Map();
  for (const node of container.children) if (node.dataset.key) existing.set(node.dataset.key, node);
  const active = document.activeElement;
  const focusKey = active && container.contains(active) ? active.closest("[data-key]")?.dataset.key ?? "" : "";
  const focusIndex = focusKey ? [...(existing.get(focusKey)?.querySelectorAll("button") ?? [])].indexOf(active) : -1;
  const next = items.map((item) => {
    const key = keyOf(item);
    const sig = sigOf(item);
    const old = existing.get(key);
    const node = old && old.dataset.sig === sig ? old : build(item);
    node.dataset.key = key;
    node.dataset.sig = sig;
    update?.(node, item);
    return node;
  });
  const current = [...container.children];
  if (current.length !== next.length || current.some((node, index) => node !== next[index])) {
    const scroll = container.scrollTop;
    container.replaceChildren(...next);
    container.scrollTop = scroll;
  }
  if (focusKey && !container.contains(document.activeElement)) {
    const node = next.find((item) => item.dataset.key === focusKey);
    const target = node?.matches("button") ? node : node?.querySelectorAll("button")[Math.max(0, focusIndex)];
    target?.focus({ preventScroll: true });
  }
}

function renderRuns() {
  const data = state.data;
  const runs = data?.runs ?? [];
  const queued = data?.queued ?? [];
  $("runs").hidden = runs.length + queued.length === 0;
  const items = [
    ...queued.map((item) => ({ kind: "queued", key: `q:${item.queueId}`, item })),
    ...[...runs].reverse().map((run) => ({ kind: "run", key: `r:${run.dispatchId}`, item: run })),
  ];
  patchList($("runs-list"), items, (entry) => entry.key, (entry) => JSON.stringify(entry.item), (entry) => {
    if (entry.kind === "queued") {
      const item = entry.item;
      return el("div", { class: "run" },
        el("div", {},
          el("strong", {}, `${ROLE_LABEL[item.role]} · PR #${item.pullRequestId}`),
          el("div", { class: "small muted" }, `Queued (${item.mode === "next" ? "run next" : "replace"}) · ${item.state}${item.code ? ` · ${item.code}` : ""}`)),
        el("button", { type: "button", class: "danger", onclick: () => cancelQueued(item.queueId) }, "Cancel"));
    }
    const run = entry.item;
    const latest = run.latest && !run.latest.startsWith(run.detail) ? run.latest : "";
    return el("div", { class: "run" },
      el("div", {},
        el("strong", {}, `${ROLE_LABEL[run.role]} · PR #${run.pullRequestId} · ${run.headline}`),
        el("div", { class: "small muted" }, [run.detail, latest, `elapsed ${run.elapsed}`].filter(Boolean).join(" · "))),
      run.terminal ? null : el("button", { type: "button", class: "danger", onclick: () => cancelRun(run.dispatchId) }, "Cancel"));
  });
}

async function cancelRun(dispatchId) {
  if (!await confirmAction("Cancel this run?", "The agent process will be stopped.", "Cancel run")) return;
  try {
    await api("/api/review/cancel", { dispatchId });
    notice("Cancellation requested.");
  } catch (error) {
    showError(errorText(error));
  }
  refresh();
}

async function cancelQueued(queueId) {
  if (!await confirmAction("Cancel this queued run?", "It will not start.", "Cancel queued run")) return;
  try {
    await api("/api/review/cancel-queued", { queueId });
    notice("Queued run cancelled.");
  } catch (error) {
    showError(errorText(error));
  }
  refresh();
}

// ---------------------------------------------------------------------------------------------
// Live and History
// ---------------------------------------------------------------------------------------------

const ELAPSED_FIELDS = new Set(["phaseElapsedMilliseconds", "totalElapsedMilliseconds", "heartbeatAgeMilliseconds", "status"]);

function stableSig(item) {
  return JSON.stringify(item, (key, value) => ELAPSED_FIELDS.has(key) ? undefined : value);
}

function select(key) {
  state.selected = key;
  renderMain();
}

function instanceRow(item) {
  const key = `i|${item.key}`;
  return el("button", { type: "button", class: "row", role: "option", onclick: () => select(key) },
    el("div", { class: "line" },
      el("strong", {}, ROLE_LABEL[item.agent] ?? item.agent),
      el("span", { class: "status" })),
    el("div", { class: "sub" }, item.pullRequestId ? `PR #${item.pullRequestId} ${item.pullRequestTitle}` : item.repository || "No PR selected"),
    el("div", { class: "sub elapsed" }));
}

function updateInstanceRow(node, item) {
  const key = `i|${item.key}`;
  node.classList.toggle("selected", key === state.selected);
  node.setAttribute("aria-selected", String(key === state.selected));
  const status = node.querySelector(".status");
  status.className = `status ${item.status}${item.status === "stale" ? " badge stale" : ""}`;
  status.textContent = item.status;
  status.title = item.status === "stale" && item.heartbeatAgeMilliseconds !== null
    ? `No heartbeat for ${duration(item.heartbeatAgeMilliseconds)}; the process may be hung or slow.` : "";
  const ended = ["completed", "exited", "failed"].includes(item.status);
  node.querySelector(".elapsed").textContent = ended
    ? `${item.phase || item.status} · ended ${when(item.lastEventMs)}`
    : `${item.phase || "—"} · ${duration(item.phaseElapsedMilliseconds)}`;
}

function outcomeText(role) {
  return role ? role.result || role.status || "" : "";
}

function historyRow(entry) {
  const key = `p|${entry.key}`;
  const outcomes = [
    entry.reviewer ? `Reviewer: ${outcomeText(entry.reviewer)}` : "",
    entry.reviewHandler ? `Review Handler: ${outcomeText(entry.reviewHandler)}` : "",
  ].filter(Boolean).join(" · ");
  return el("div", { class: "row-wrap" },
    el("button", { type: "button", class: "row", role: "option", onclick: () => select(key) },
      el("div", { class: "line" }, el("strong", {}, `PR #${entry.pullRequestId}`), el("span", { class: "small muted" }, when(entry.lastSeenMs))),
      el("div", { class: "sub" }, entry.title || entry.repository),
      el("div", { class: "sub" }, outcomes || "No outcome yet")),
    el("button", { type: "button", class: "hide", "aria-label": `Hide PR #${entry.pullRequestId} from history`, onclick: () => hideHistory(entry.key) }, "Hide"));
}

function updateHistoryRow(node, entry) {
  const selected = `p|${entry.key}` === state.selected;
  const row = node.querySelector(".row");
  row.classList.toggle("selected", selected);
  row.setAttribute("aria-selected", String(selected));
}

async function historyAction(path, body, message) {
  try {
    notice(message(await api(path, body)));
  } catch (error) {
    showError(errorText(error));
  }
  await refresh();
}

function hideHistory(key) {
  return historyAction("/api/history/hide", { key }, () => "Hidden from History. Use Restore hidden to bring it back.");
}

function renderHistoryTools(data) {
  const tools = $("history-tools");
  const hidden = data.hiddenPullRequestCount ?? 0;
  const sig = `${state.view}|${data.historyAvailable}|${hidden}|${data.pullRequests?.length ?? 0}`;
  tools.hidden = state.view !== "history" || !data.historyAvailable;
  if (tools.dataset.sig === sig) return;
  tools.dataset.sig = sig;
  tools.replaceChildren(
    el("button", { type: "button", disabled: !data.pullRequests?.length,
      onclick: () => historyAction("/api/history/clear", {}, (result) => `Cleared ${result.hidden} PR${result.hidden === 1 ? "" : "s"} from the History view. New activity appears again.`) },
    "Clear history view"),
    hidden ? el("button", { type: "button", onclick: () => historyAction("/api/history/restore", {}, (result) => `Restored ${result.restored} hidden PR${result.restored === 1 ? "" : "s"}.`) },
      `Restore hidden (${hidden})`) : null);
}

function renderMain() {
  const data = state.data;
  const main = $("main");
  main.hidden = !data;
  if (!data) return;
  const history = state.view === "history";
  const prHistory = history && data.historyAvailable === true;
  const instances = data.instances ?? [];
  const pullRequests = prHistory ? data.pullRequests ?? [] : [];
  renderHistoryTools(data);
  const keys = [...pullRequests.map((entry) => `p|${entry.key}`), ...instances.map((item) => `i|${item.key}`)];
  if (!keys.includes(state.selected)) state.selected = keys[0] ?? "";
  const list = $("list");
  list.setAttribute("aria-label", prHistory ? "Pull request history" : history ? "Exited agent processes" : "Live agent instances");
  if (prHistory) {
    patchList(list, pullRequests, (entry) => `p|${entry.key}`, (entry) => JSON.stringify(entry), historyRow, updateHistoryRow);
  } else {
    patchList(list, instances, (item) => `i|${item.key}`, stableSig, instanceRow, updateInstanceRow);
  }
  const empty = prHistory ? !pullRequests.length : !instances.length;
  let emptyNode = $("list-empty");
  if (empty && !emptyNode) {
    emptyNode = el("p", { id: "list-empty", class: "muted" });
    list.after(emptyNode);
  }
  if (emptyNode) {
    emptyNode.hidden = !empty;
    emptyNode.textContent = prHistory
      ? (data.hiddenPullRequestCount ? "All PR history is hidden. Use Restore hidden to show it." : "No pull request activity yet.")
      : history ? "No exited agent processes yet." : "No agents are running. Automation scans and manual runs appear here.";
  }
  $("exited").hidden = !prHistory || !instances.length;
  if (prHistory) {
    $("exited-summary").textContent = `Exited processes (${instances.length})`;
    patchList($("exited-list"), instances, (item) => `i|${item.key}`, stableSig, instanceRow, updateInstanceRow);
  }
  const selected = state.selected.startsWith("p|")
    ? { kind: "pr", item: pullRequests.find((entry) => `p|${entry.key}` === state.selected) }
    : { kind: "instance", item: instances.find((item) => `i|${item.key}` === state.selected) };
  renderDetail(selected);
}

function field(label, value, id) {
  return value === "" || value === null || value === undefined ? [] : [el("dt", {}, label), el("dd", id ? { id } : {}, value)];
}

function prLink(url) {
  const link = safeUrl(url);
  return link ? el("a", { class: "pr-link", href: link, target: "_blank", rel: "noopener noreferrer" }, "Open pull request ↗") : null;
}

function idsSection(rows) {
  const details = el("details", { ontoggle: (event) => { state.idsOpen = event.target.open; } },
    el("summary", { class: "muted small" }, "Identifiers"),
    el("dl", { class: "small" }, rows));
  details.open = state.idsOpen;
  return details;
}

function renderDetail(selection) {
  const detail = $("detail");
  const item = selection.item;
  const sig = item ? `${selection.kind}|${selection.kind === "pr" ? JSON.stringify(item) : stableSig(item)}` : "";
  if (sig !== state.detailSig) {
    state.detailSig = sig;
    detail.replaceChildren();
    if (item && selection.kind === "pr") renderPrDetail(detail, item);
    else if (item) renderInstanceDetail(detail, item);
  }
  if (item && selection.kind === "instance") {
    const phase = $("d-phase");
    if (phase) phase.textContent = `${item.phase || "—"} · ${duration(item.phaseElapsedMilliseconds)} (total ${duration(item.totalElapsedMilliseconds)})`;
    const heartbeat = $("d-heartbeat");
    if (heartbeat) heartbeat.textContent = item.heartbeatAgeMilliseconds === null ? "—" : `${duration(item.heartbeatAgeMilliseconds)} ago`;
    const status = $("d-status");
    if (status) status.textContent = `${ROLE_LABEL[item.agent]} · ${item.status}`;
  }
}

function roleOutcome(label, role) {
  if (!role) return [];
  const parts = [role.result ? `${role.result}${role.resultAtMs ? ` (${when(role.resultAtMs)})` : ""}` : ""];
  if (role.status && role.status !== role.result) parts.push(`latest: ${role.status}${role.statusAtMs ? ` (${when(role.statusAtMs)})` : ""}`);
  return field(label, parts.filter(Boolean).join(" · "));
}

function renderPrDetail(detail, entry) {
  detail.append(
    el("h2", { class: "dialog-title" }, `PR #${entry.pullRequestId} ${entry.title}`),
    prLink(entry.url),
    el("dl", {},
      roleOutcome("Reviewer", entry.reviewer),
      roleOutcome("Review Handler", entry.reviewHandler),
      field("Last activity", when(entry.lastSeenMs)),
      field("Author", entry.author),
      field("Branches", entry.sourceBranch ? `${entry.sourceBranch} → ${entry.targetBranch}` : ""),
      field("Repository", entry.repository)),
    state.data?.launchMode !== "observe"
      ? el("div", { class: "launch-row" }, el("button", { type: "button", onclick: () => openModal(entry.pullRequestId) }, "Review this PR…"))
      : null,
    idsSection(field("History key", entry.key)));
}

function renderInstanceDetail(detail, item) {
  const completion = item.completion;
  const headline = completion
    ? `${completion.result}${completion.reason ? ` · ${completion.reason}` : ""}`
    : item.blocked ? `Blocked · ${item.blocked.reason}` : item.status === "stale" ? "Stale · no recent heartbeat" : item.phase || item.status;
  detail.append(
    el("h2", { class: "dialog-title" }, item.pullRequestId ? `PR #${item.pullRequestId} ${item.pullRequestTitle}` : ROLE_LABEL[item.agent]),
    el("div", { class: "small muted", id: "d-status" }, `${ROLE_LABEL[item.agent]} · ${item.status}`),
    el("p", { class: "outcome" }, headline),
    completion?.summary ? el("p", {}, completion.summary) : null,
    prLink(item.pullRequestUrl),
    el("dl", {},
      completion ? field("Findings", `${completion.findings.critical} critical · ${completion.findings.important} important · ${completion.findings.suggestion} suggestion`) : [],
      completion ? field("Delivered", completion.delivered.join(", ")) : [],
      completion ? field("Preview", completion.previewArtifact) : [],
      field("Phase", "—", "d-phase"),
      field("Heartbeat", "—", "d-heartbeat"),
      field("Model", item.modelActivity),
      field("Author", item.pullRequestAuthor),
      field("Branches", item.sourceBranch ? `${item.sourceBranch} → ${item.targetBranch}` : ""),
      field("Threads", item.threadCount ? `${item.actionableThreadCount}/${item.threadCount} actionable · ${item.changedFileCount} files` : ""),
      field("Candidates", item.candidateStory),
      field("Blocked", item.blocked ? `${item.blocked.reason}${item.blocked.nextRetry ? ` · retry ${item.blocked.nextRetry}` : ""}` : ""),
      field("Waiting", item.waiting ? `${item.waiting.kind} · ${duration(item.waiting.delayMilliseconds)}` : ""),
      field("Repository", item.repository)),
    idsSection([
      field("Instance", item.instanceId), field("Process", String(item.processId)),
      field("Session", item.sessionNamespace), field("Commit", item.sourceCommit), field("Key", item.key)]),
    el("h3", {}, "Timeline"),
    el("ul", { class: "timeline" },
      [...item.timeline].reverse().map((event) => el("li", {}, el("time", {}, when(event.timestampMs)), event.text))));
}

// ---------------------------------------------------------------------------------------------
// Review a PR modal: target -> preview -> (explicit, render-gated) Start; busy -> proposal -> Confirm
// ---------------------------------------------------------------------------------------------

function openModal(pullRequestId = "", role = "reviewer") {
  state.modal = { step: "target", pullRequestId: String(pullRequestId || ""), role, prompt: "", draft: null, proposal: null, error: "", inFlight: false, message: "" };
  renderModal();
  if (!$("modal").open) $("modal").showModal();
}

function closeModal() {
  state.modal = null;
  if ($("modal").open) $("modal").close();
}

function setStep(step, extra = {}) {
  Object.assign(state.modal, { step }, extra);
  renderModal();
}

// A start/confirm button only becomes clickable after the frame showing what it confirms has painted,
// mirroring the TUI's previewRendered guard against buffered or repeated input.
function gate(button) {
  button.disabled = true;
  requestAnimationFrame(() => requestAnimationFrame(() => { if (button.isConnected) button.disabled = false; }));
  return button;
}

function renderModal() {
  const m = state.modal;
  const body = $("modal-body");
  body.replaceChildren();
  if (!m) return;
  body.append(el("h3", { id: "modal-title" }, "Review a PR"));
  if (m.error) body.append(el("p", { class: "error-text" }, m.error));
  if (m.step === "target") return renderTarget(body, m);
  if (m.step === "loading") return body.append(el("p", { class: "muted" }, m.message || "Working…"));
  if (m.step === "preview") return renderPreview(body, m);
  if (m.step === "busy") return renderBusy(body, m);
  if (m.step === "proposal") return renderProposal(body, m);
}

function renderTarget(body, m) {
  const input = el("input", { id: "pr", inputmode: "numeric", autocomplete: "off", value: m.pullRequestId, placeholder: "e.g. 12345" });
  input.addEventListener("input", () => { m.pullRequestId = input.value.trim(); });
  input.addEventListener("keydown", (event) => { if (event.key === "Enter" && !event.repeat) { event.preventDefault(); preview(); } });
  const role = el("select", { id: "role" },
    el("option", { value: "reviewer", selected: m.role === "reviewer" }, "Reviewer"),
    el("option", { value: "review-handler", selected: m.role === "review-handler" }, "Review Handler"));
  role.addEventListener("change", () => { m.role = role.value; });
  const recent = (state.data?.recentPullRequests ?? []).filter((item) => Number.isSafeInteger(item.pullRequestId));
  const suggestions = recent.length
    ? el("div", { class: "suggestions", "aria-label": "Recent pull requests" },
      el("span", { class: "small muted" }, "Recent:"),
      recent.map((item) => el("button", {
        type: "button", title: item.title,
        onclick: () => { m.pullRequestId = String(item.pullRequestId); input.value = m.pullRequestId; input.focus(); },
      }, `#${item.pullRequestId}`)))
    : null;
  body.append(
    el("p", { class: "muted small" }, "The repository comes from this watch's agent config. Previewing never starts anything."),
    el("div", { class: "field" }, el("label", { for: "pr" }, "Pull request ID"), input, suggestions),
    el("div", { class: "field" }, el("label", { for: "role" }, "Agent"), role),
    el("div", { class: "buttons" },
      el("button", { type: "button", onclick: closeModal }, "Cancel"),
      el("button", { type: "button", class: "primary", onclick: preview }, "Preview")));
  setTimeout(() => input.focus(), 0);
}

function renderPreview(body, m) {
  const d = m.draft;
  const pr = d.pullRequest;
  const prompt = el("textarea", { id: "prompt", rows: 3, placeholder: "Optional instructions for this run" });
  prompt.value = m.prompt;
  const count = el("span", { class: "small muted" }, `${Array.from(m.prompt).length}/${MAX_PROMPT}`);
  prompt.addEventListener("input", () => {
    const scalars = Array.from(prompt.value);
    if (scalars.length > MAX_PROMPT) prompt.value = scalars.slice(0, MAX_PROMPT).join("");
    m.prompt = prompt.value;
    count.textContent = `${Array.from(m.prompt).length}/${MAX_PROMPT}`;
  });
  const start = gate(el("button", { type: "button", class: "primary", onclick: start_ }, `Start ${ROLE_LABEL[d.role]}`));
  body.append(
    el("p", { class: "small" }, el("strong", {}, "NOT STARTED"), " · review the target, then click Start."),
    el("dl", {},
      field("Repository", `${d.repository.slug} (${d.repository.provider})`),
      field("Pull request", `#${pr.pullRequestId} ${pr.title}`),
      field("Author", pr.author),
      field("Source", `${pr.sourceRef} @ ${pr.sourceCommit.slice(0, 12)}`),
      field("Target", pr.targetRef),
      field("State", `${pr.active ? "active" : "not active"}${pr.draft ? " · draft" : ""}`),
      field("Agent", ROLE_LABEL[d.role])),
    el("div", { class: "field" }, el("label", {}, "Allowed"),
      el("div", { class: "chips" }, d.capabilities.length ? d.capabilities.map((name) => el("span", { class: "chip" }, name)) : el("span", { class: "muted small" }, "Preview only (no writes)"))),
    el("div", { class: "field" }, el("label", {}, "Not allowed"),
      el("div", { class: "chips" }, d.mandatoryDenies.map((name) => el("span", { class: "chip" }, name)))),
    d.dynamicConstraints.length ? el("p", { class: "small muted" }, `Constraints: ${d.dynamicConstraints.join("; ")}`) : null,
    d.killSwitchActive ? el("p", { class: "error-text small" }, "Kill switch active: capability overrides are masked.") : null,
    el("div", { class: "field" }, el("label", { for: "prompt" }, "Instructions (optional) "), prompt, count),
    el("div", { class: "buttons" },
      el("button", { type: "button", onclick: closeModal }, "Cancel"),
      start));
}

function renderBusy(body, m) {
  body.append(
    el("p", {}, m.message || "Another run is using this PR or repository."),
    el("p", { class: "small muted" }, "Choose how to schedule this run. Choosing an option only prepares a proposal; nothing is stopped until you confirm."),
    el("div", { class: "buttons" },
      el("button", { type: "button", onclick: closeModal }, "Back"),
      el("button", { type: "button", onclick: () => prepare("next") }, "Run next"),
      el("button", { type: "button", class: "primary", onclick: () => prepare("replace") }, "Replace and run now")));
}

function renderProposal(body, m) {
  const p = m.proposal;
  const conflict = `${p.conflict.kind} run${p.conflict.pullRequestId ? ` for PR #${p.conflict.pullRequestId}` : ""}`;
  const text = p.mode === "replace"
    ? `Replace: the current ${conflict} will be stopped, then this run starts.`
    : `Run next: this run starts after the current ${conflict} finishes.`;
  body.append(
    el("p", {}, text),
    el("p", { class: "small muted" }, `Proposal expires at ${clock(Date.parse(p.expiresAtUtc))}.`),
    el("div", { class: "buttons" },
      el("button", { type: "button", onclick: () => setStep("busy", { error: "" }) }, "Back"),
      gate(el("button", { type: "button", class: "primary", onclick: confirmProposal }, p.mode === "replace" ? "Confirm replace" : "Confirm run next"))));
}

async function preview() {
  const m = state.modal;
  if (!m || m.inFlight) return;
  const pullRequestId = /^[0-9]{1,10}$/.test(m.pullRequestId) ? Number(m.pullRequestId) : NaN;
  if (!Number.isSafeInteger(pullRequestId) || pullRequestId < 1 || pullRequestId > 2147483647) {
    setStep("target", { error: ERROR_TEXT["invalid-pull-request-id"] });
    return;
  }
  m.inFlight = true;
  setStep("loading", { error: "", message: `Resolving PR #${pullRequestId} and its capabilities…` });
  try {
    const draft = await api("/api/review/describe", { pullRequestId, role: m.role });
    if (state.modal !== m) return;
    setStep("preview", { draft, error: "" });
  } catch (error) {
    if (state.modal === m) setStep("target", { error: errorText(error) });
  } finally {
    m.inFlight = false;
  }
}

async function start_() {
  const m = state.modal;
  if (!m || m.inFlight || m.step !== "preview") return;
  m.inFlight = true;
  setStep("loading", { message: "Starting… the broker is re-validating the PR and policy." });
  try {
    const result = await api("/api/review/dispatch", { dispatchDraftId: m.draft.dispatchDraftId, operatorPrompt: m.prompt });
    closeModal();
    notice(`Started ${ROLE_LABEL[m.draft.role]} for PR #${m.draft.pullRequest.pullRequestId} (child PID ${result.childProcessId}).`);
    refresh();
  } catch (error) {
    if (state.modal !== m) return;
    if (error instanceof ApiError && BUSY.has(error.code) && m.draft.schedulingAvailable) {
      setStep("busy", { error: "", message: errorText(error) });
    } else {
      setStep("target", { error: errorText(error), draft: null });
    }
  } finally {
    m.inFlight = false;
  }
}

async function prepare(mode) {
  const m = state.modal;
  if (!m || m.inFlight) return;
  m.inFlight = true;
  setStep("loading", { error: "", message: "Checking current work. Nothing is being stopped." });
  try {
    const proposal = await api("/api/review/prepare-run", { dispatchDraftId: m.draft.dispatchDraftId, mode, operatorPrompt: m.prompt });
    if (state.modal === m) setStep("proposal", { proposal });
  } catch (error) {
    if (state.modal !== m) return;
    if (error instanceof ApiError && REPREVIEW.has(error.code)) setStep("target", { error: errorText(error), draft: null });
    else setStep("busy", { error: errorText(error) });
  } finally {
    m.inFlight = false;
  }
}

async function confirmProposal() {
  const m = state.modal;
  if (!m || m.inFlight || m.step !== "proposal") return;
  if (Date.now() >= Date.parse(m.proposal.expiresAtUtc)) {
    await prepare(m.proposal.mode);
    return;
  }
  m.inFlight = true;
  const mode = m.proposal.mode;
  setStep("loading", { message: "Confirming…" });
  try {
    await api("/api/review/confirm-run", { confirmationToken: m.proposal.confirmationToken });
    closeModal();
    notice(mode === "replace" ? "Replacing current work; your run starts next." : "Queued to run next.");
    refresh();
  } catch (error) {
    if (state.modal !== m) return;
    m.inFlight = false;
    if (error instanceof ApiError && error.code === "schedule-stale") await prepare(mode);
    else if (error instanceof ApiError && REPREVIEW.has(error.code)) setStep("target", { error: errorText(error), draft: null });
    else setStep("busy", { error: errorText(error) });
  } finally {
    m.inFlight = false;
  }
}


// ---------------------------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------------------------

$("modal").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && event.repeat) {
    event.preventDefault();
    event.stopPropagation();
  }
}, true);
$("modal").addEventListener("cancel", (event) => {
  if (state.modal?.inFlight) event.preventDefault();
  else state.modal = null;
});
$("modal-close").addEventListener("click", () => { if (!state.modal?.inFlight) closeModal(); });
$("error-dismiss").addEventListener("click", clearError);
$("review").addEventListener("click", () => openModal());
$("stop").addEventListener("click", stopWatch);
$("scan").addEventListener("click", async () => {
  $("scan").disabled = true;
  try {
    const result = await api("/api/scan-now", {});
    notice("Scan now: " + result.results.map((item) => `${ROLE_LABEL[item.role]} ${item.outcome}`).join(", "));
  } catch (error) {
    showError(errorText(error));
  }
  refresh();
});
for (const tab of document.querySelectorAll("#tabs [role=tab]")) {
  tab.addEventListener("click", () => {
    if (state.view === tab.dataset.view) return;
    state.view = tab.dataset.view;
    state.selected = "";
    render();
    loop();
  });
  tab.addEventListener("keydown", (event) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    const other = tab.dataset.view === "live" ? $("tab-history") : $("tab-live");
    other.focus();
    other.click();
  });
}
document.addEventListener("visibilitychange", () => {
  if (document.hidden) clearTimeout(pollTimer);
  else loop();
});
setInterval(tick, 1_000);

loop();
