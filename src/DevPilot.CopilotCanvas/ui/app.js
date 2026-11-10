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
};

const state = { connection: null, data: null, view: "current", selected: "", modal: null, noticeTimer: 0 };

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

function notice(text, isError = false) {
  const node = $("notice");
  node.textContent = text;
  node.classList.toggle("error", isError);
  node.hidden = false;
  clearTimeout(state.noticeTimer);
  state.noticeTimer = setTimeout(() => { node.hidden = true; }, isError ? 10_000 : 5_000);
}

// ---------------------------------------------------------------------------------------------
// Polling and page rendering
// ---------------------------------------------------------------------------------------------

async function refresh() {
  try {
    const result = await api(`/api/state?view=${encodeURIComponent(state.view)}`);
    state.connection = result.connection;
    state.data = result.data;
    render();
    if (result.prefill && !$("modal").open && state.data) {
      openModal(result.prefill.pullRequestId, result.prefill.role);
      api("/api/prefill/clear", {}).catch(() => {});
    }
  } catch (error) {
    notice(`Canvas error: ${errorText(error)}`, true);
  }
}

async function loop() {
  await refresh();
  setTimeout(loop, POLL_MS);
}

function automationText(automation) {
  if (!automation) return "";
  if (!automation.available) return automation.error ? `Automation: unavailable (${automation.error})` : "Automation: unavailable";
  return "Automation: " + automation.agents.map((agent) => {
    let text = `${ROLE_LABEL[agent.role] ?? agent.role} ${agent.state}`;
    if (agent.continuous && agent.intervalSeconds) text += ` · every ${Math.round(agent.intervalSeconds / 60)}m`;
    if (agent.state === "retrying" && agent.retryAtUtc) text += ` · retry ${clock(Date.parse(agent.retryAtUtc))}`;
    return text;
  }).join("  |  ");
}

function render() {
  const { connection, data } = state;
  const connected = Boolean(data);
  const mode = $("mode");
  mode.hidden = !connected;
  if (connected) {
    const label = data.launchMode === "operational" ? "OPERATIONAL" : data.launchMode === "preview" ? "PREVIEW ONLY" : "OBSERVE ONLY";
    mode.textContent = label;
    mode.className = `badge ${data.launchMode}`;
  }
  $("subtitle").textContent = connected
    ? `Repository: ${data.consumerRepositoryRoot || "(unknown)"} · dashboard PID ${data.dashboardPid}`
    : connection?.workingDirectory ? `Session folder: ${connection.workingDirectory}` : "";
  $("automation").textContent = connected ? automationText(data.automation) : "";
  $("scan").disabled = !connected || !data.automation?.available || !data.automation.agents.some((agent) => agent.canScanNow);
  $("review").disabled = !connected || data.launchMode === "observe";
  renderDisconnected();
  renderRuns();
  renderInstances();
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
  const others = $("others");
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
    notice(errorText(error), true);
  }
}

function renderRuns() {
  const data = state.data;
  const section = $("runs");
  const list = $("runs-list");
  const runs = data?.runs ?? [];
  const queued = data?.queued ?? [];
  section.hidden = runs.length + queued.length === 0;
  list.replaceChildren();
  for (const item of queued) {
    list.append(el("div", { class: "run" },
      el("div", {},
        el("strong", {}, `${ROLE_LABEL[item.role]} · PR #${item.pullRequestId}`),
        el("div", { class: "small muted" }, `Queued (${item.mode === "next" ? "run next" : "replace"}) · ${item.state}${item.code ? ` · ${item.code}` : ""}`)),
      el("button", { type: "button", class: "danger", onclick: () => cancelQueued(item.queueId) }, "Cancel")));
  }
  for (const run of [...runs].reverse()) {
    const open = !run.terminal;
    const latest = run.latest && !run.latest.startsWith(run.detail) ? run.latest : "";
    list.append(el("div", { class: "run" },
      el("div", {},
        el("strong", {}, `${ROLE_LABEL[run.role]} · PR #${run.pullRequestId} · ${run.headline}`),
        el("div", { class: "small muted" }, [run.detail, latest, `elapsed ${run.elapsed}`].filter(Boolean).join(" · "))),
      open ? el("button", { type: "button", class: "danger", onclick: () => cancelRun(run.dispatchId) }, "Cancel") : null));
  }
}

async function cancelRun(dispatchId) {
  if (!confirm("Cancel this run? The agent process will be stopped.")) return;
  try {
    await api("/api/review/cancel", { dispatchId });
    notice("Cancellation requested.");
  } catch (error) {
    notice(errorText(error), true);
  }
  refresh();
}

async function cancelQueued(queueId) {
  try {
    await api("/api/review/cancel-queued", { queueId });
    notice("Queued run cancelled.");
  } catch (error) {
    notice(errorText(error), true);
  }
  refresh();
}

function renderInstances() {
  const data = state.data;
  const main = $("main");
  main.hidden = !data;
  if (!data) return;
  const list = $("list");
  const instances = data.instances;
  if (!instances.some((item) => item.key === state.selected)) state.selected = instances[0]?.key ?? "";
  list.replaceChildren();
  if (!instances.length) list.append(el("p", { class: "muted", text: `No ${state.view} agent instances yet.` }));
  for (const item of instances) {
    list.append(el("button", {
      type: "button",
      class: `row${item.key === state.selected ? " selected" : ""}`,
      onclick: () => { state.selected = item.key; renderInstances(); },
    },
    el("div", { class: "line" },
      el("strong", {}, ROLE_LABEL[item.agent] ?? item.agent),
      el("span", { class: `status ${item.status}` }, item.status)),
    el("div", { class: "sub" }, item.pullRequestId ? `PR #${item.pullRequestId} ${item.pullRequestTitle}` : item.repository || "No PR selected"),
    el("div", { class: "sub" }, `${item.phase || "—"} · ${duration(item.phaseElapsedMilliseconds)}`)));
  }
  renderDetail(instances.find((item) => item.key === state.selected));
}

function field(label, value) {
  return value === "" || value === null || value === undefined ? [] : [el("dt", {}, label), el("dd", {}, value)];
}

function renderDetail(item) {
  const detail = $("detail");
  detail.replaceChildren();
  if (!item) return;
  const link = safeUrl(item.pullRequestUrl);
  const completion = item.completion;
  detail.append(
    el("h3", {}, item.pullRequestId ? `PR #${item.pullRequestId} ${item.pullRequestTitle}` : ROLE_LABEL[item.agent]),
    el("div", { class: "small muted" }, `${ROLE_LABEL[item.agent]} · ${item.status} · instance ${item.instanceId.slice(0, 8)} · PID ${item.processId}`),
    el("dl", {},
      field("Phase", `${item.phase || "—"} · ${duration(item.phaseElapsedMilliseconds)} (total ${duration(item.totalElapsedMilliseconds)})`),
      field("Heartbeat", item.heartbeatAgeMilliseconds === null ? "" : `${duration(item.heartbeatAgeMilliseconds)} ago`),
      field("Model", item.modelActivity),
      field("Repository", item.repository),
      field("Author", item.pullRequestAuthor),
      field("Branches", item.sourceBranch ? `${item.sourceBranch} → ${item.targetBranch}` : ""),
      field("Threads", item.threadCount ? `${item.actionableThreadCount}/${item.threadCount} actionable · ${item.changedFileCount} files` : ""),
      field("Candidates", item.candidateStory),
      field("Blocked", item.blocked ? `${item.blocked.reason}${item.blocked.nextRetry ? ` · retry ${item.blocked.nextRetry}` : ""}` : ""),
      field("Waiting", item.waiting ? `${item.waiting.kind} · ${duration(item.waiting.delayMilliseconds)}` : ""),
      completion ? field("Result", `${completion.result}${completion.reason ? ` · ${completion.reason}` : ""}`) : [],
      completion ? field("Findings", `${completion.findings.critical} critical · ${completion.findings.important} important · ${completion.findings.suggestion} suggestion`) : [],
      completion ? field("Delivered", completion.delivered.join(", ")) : [],
      completion ? field("Summary", completion.summary) : [],
      completion ? field("Preview", completion.previewArtifact) : []),
    link ? el("p", {}, el("a", { href: link, target: "_blank", rel: "noopener noreferrer" }, "Open pull request ↗")) : null,
    el("h2", {}, "Timeline"),
    el("ul", { class: "timeline" },
      [...item.timeline].reverse().map((event) => el("li", {}, el("time", {}, clock(event.timestampMs)), event.text))));
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
  body.append(
    el("p", { class: "muted small" }, "The repository comes from this watch's agent config. Previewing never starts anything."),
    el("div", { class: "field" }, el("label", { for: "pr" }, "Pull request ID"), input),
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
$("review").addEventListener("click", () => openModal());
$("scan").addEventListener("click", async () => {
  $("scan").disabled = true;
  try {
    const result = await api("/api/scan-now", {});
    notice("Scan now: " + result.results.map((item) => `${ROLE_LABEL[item.role]} ${item.outcome}`).join(", "));
  } catch (error) {
    notice(errorText(error), true);
  }
  refresh();
});
$("view").addEventListener("change", () => {
  state.view = $("view").value;
  refresh();
});

loop();
