const byId = id => document.getElementById(id);
let state;
let selected;
let refreshTask;
let pendingRefresh = false;
const rejectedAnswers = new Map();
const expandedAnswers = new Set();
const element = (tag, text, className) => {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
};
const message = text => {
  byId("error").textContent = text;
  byId("error").classList.toggle("hidden", !text);
};
const status = value => element("span", value.replaceAll("_", " "), `status ${value}`);
const formatTime = value => value ? new Date(value).toLocaleString() : "Not recorded";
const button = (label, action, primary = false) => {
  const node = element("button", label, primary ? "primary" : "");
  node.type = "button";
  node.onclick = async () => {
    node.disabled = true;
    message("");
    try { await action(); } catch (error) { message(error.message); }
    finally { node.disabled = false; }
  };
  return node;
};
async function mutation(route, body) {
  const response = await fetch(route, { method: "POST", headers: {
    "Content-Type": "application/json", "X-Fleet-CSRF": state.csrfToken,
  }, body: JSON.stringify(body) });
  const value = await response.json();
  if (!response.ok) throw new Error(value.error || "Request failed");
  await refresh();
  return value;
}
async function run(kind, id) {
  const requestId = crypto.randomUUID().replaceAll("-", "");
  const value = await mutation("/api/run", { kind, id, requestId });
  selected = state.attempts.find(a => a.runId === value.runId)?.id;
  renderRuns();
}
async function preview(id) {
  const response = await fetch(`/api/preview?id=${encodeURIComponent(id)}`);
  const value = await response.json();
  if (!response.ok) throw new Error(value.error);
  byId("preview").textContent = JSON.stringify(value, null, 2);
  byId("previewSection").classList.remove("hidden");
  byId("previewSection").scrollIntoView({ behavior: "smooth", block: "nearest" });
}
async function inspectRejectedAnswer(id) {
  const response = await fetch(`/api/rejected-answer?id=${encodeURIComponent(id)}`);
  const value = await response.json();
  if (!response.ok) throw new Error(value.error || "Rejected answer unavailable");
  rejectedAnswers.set(id, value);
  expandedAnswers.add(id);
  if (selected === id) renderRuns();
}
function render() {
  byId("repository").textContent = state.repository;
  byId("capacity").textContent = `${state.active} / ${state.limit} new-runner slots active · ${state.attempts.length} retained attempts · source ${state.currentRevision?.slice(0, 12) || "unknown"}`;
  if (state.fatal) message(state.fatal);
  const agents = byId("agents");
  agents.replaceChildren();
  for (const agent of state.manifest.agents) {
    const card = element("article", undefined, "card");
    const latest = [...state.attempts].reverse().find(a => a.agentId === agent.id);
    const schedule = state.schedules[agent.id];
    card.append(element("h3", agent.id), status(latest?.status || "idle"));
    card.append(element("p", agent.prompt, "mono muted"));
    card.append(element("p", `Packet: ${state.manifest.inputProfiles[agent.inputProfile].files.join(", ")}`, "muted"));
    card.append(element("small", schedule?.enabled ?
      `Next: ${formatTime(schedule.nextAt)} · every ${schedule.everyMinutes} min` :
      `Schedule off · ${agent.timeoutSeconds}s attempt deadline`));
    const actions = element("div", undefined, "actions");
    actions.append(button("Preview", () => preview(agent.id)), button("Run now", () => run("agent", agent.id), true),
      button(schedule?.enabled ? "Disable schedule" : "Enable schedule",
        () => mutation("/api/schedule", { id: agent.id, enabled: !schedule?.enabled })));
    card.append(actions);
    agents.append(card);
  }
  const swarms = byId("swarms");
  swarms.replaceChildren();
  for (const swarm of state.manifest.swarms) {
    const card = element("article", undefined, "card");
    card.append(element("h3", swarm.id),
      element("p", `${swarm.workers.join(" + ")} → synthesis`),
      element("p", `${swarm.workers.length + 1} total model attempts. Synthesis waits for accepted worker results.`, "muted"),
      button("Run swarm", () => run("swarm", swarm.id), true));
    swarms.append(card);
  }
  if (!state.manifest.swarms.length) swarms.append(element("p", "No swarm recipes configured.", "muted"));
  renderRuns();
  const legacy = byId("legacy");
  legacy.replaceChildren();
  for (const stream of state.legacy.streams) {
    const card = element("article", undefined, "card");
    card.append(element("h3", stream.agent), element("p", stream.eventType),
      element("p", stream.instanceId, "mono"), element("p", `Last event: ${formatTime(stream.timestamp)}`),
      element("p", stream.message, "muted"));
    legacy.append(card);
  }
  if (!state.legacy.streams.length) legacy.append(element("p", "No legacy streams attached. Launch with --observe <event-file.jsonl> to monitor an existing agent without taking control.", "muted"));
  byId("diagnostics").textContent = [`Private state: ${state.stateDirectory}`, state.legacy.note,
    ...state.diagnostics, ...state.legacy.diagnostics].join("\n");
}
function renderRuns() {
  const runs = byId("runs");
  runs.replaceChildren();
  for (const attempt of [...state.attempts].reverse()) {
    const row = button("", () => { selected = attempt.id; renderRuns(); });
    row.className = `run ${selected === attempt.id ? "selected" : ""}`;
    row.append(element("strong", attempt.agentId), document.createTextNode(" · "), status(attempt.status),
      element("div", `${attempt.kind} · ${formatTime(attempt.createdAt)}`, "muted"));
    runs.append(row);
  }
  if (!state.attempts.length) runs.append(element("p", "No runs yet. Preview an agent's inputs and select Run now.", "muted"));
  const attempt = state.attempts.find(a => a.id === selected);
  if (!attempt) return;
  const detail = byId("detail");
  detail.replaceChildren();
  detail.append(element("h3", attempt.agentId), status(attempt.status));
  const seconds = attempt.startedAt ? Math.max(0, Math.round(((attempt.endedAt ? Date.parse(attempt.endedAt) : Date.now()) - Date.parse(attempt.startedAt)) / 1000)) : 0;
  detail.append(element("p", `Elapsed ${seconds}s · model ${attempt.model || "unknown"} · usage/cost unknown`, "muted"),
    element("p", `Run ${attempt.runId}\nAttempt ${attempt.id}`, "mono"),
    element("p", `Source ${attempt.revision}`, "mono"),
    element("p", `Input digest ${attempt.inputHash}`, "mono"));
  if (attempt.stale) detail.append(element("p", "STALE: repository revision or input files changed since admission. Packet hashes preserve the actual inputs.", "status interrupted"));
  if (attempt.stale === null) detail.append(element("p", "Current source revision unknown.", "status interrupted"));
  if (attempt.kind !== "agent") {
    const swarm = state.swarms.find(s => s.id === attempt.runId);
    if (swarm) detail.append(element("p", `Swarm ${swarm.recipeId}: ${swarm.status} · ${swarm.workers.length} workers + synthesis`, "muted"));
  }
  if (["queued", "running"].includes(attempt.status)) {
    detail.append(button(attempt.cancelRequested ? "Cancellation requested" : "Cancel run",
      () => mutation("/api/cancel", { runId: attempt.runId })));
  }
  if (attempt.error) detail.append(element("pre", attempt.error));
  if (attempt.status === "invalid_result") {
    const rejected = rejectedAnswers.get(attempt.id);
    if (!rejected) {
      detail.append(button("Inspect rejected answer", () => inspectRejectedAnswer(attempt.id)));
    } else {
      detail.append(element("p", `Schema detail: ${rejected.diagnostic}`, "status invalid_result"));
      const disclosure = element("details");
      disclosure.open = expandedAnswers.has(attempt.id);
      disclosure.ontoggle = () => {
        if (disclosure.open) expandedAnswers.add(attempt.id);
        else expandedAnswers.delete(attempt.id);
      };
      disclosure.append(element("summary", "Rejected model text - untrusted, read-only"),
        element("p", "For diagnosis only. This view does not repair, accept, or rerun the attempt.", "muted"));
      if (rejected.limitReached) disclosure.append(element("p", "Capture limit reached; this answer may be incomplete.", "muted"));
      disclosure.append(element("pre", rejected.answer));
      detail.append(disclosure);
    }
  }
  if (attempt.result) {
    detail.append(element("h2", "Result"), element("p", attempt.result.summary));
    for (const finding of attempt.result.findings) {
      const node = element("div", undefined, "finding");
      node.append(element("h3", finding.title), element("p", finding.evidence, "muted"), element("p", finding.recommendation));
      detail.append(node);
    }
    const disclosure = element("details");
    disclosure.append(element("summary", "Structured result artifact"), element("pre", JSON.stringify(attempt.result, null, 2)));
    detail.append(disclosure);
  }
  detail.append(element("h2", "Input evidence"), element("pre", JSON.stringify(attempt.files, null, 2)));
}
function refresh() {
  pendingRefresh = true;
  if (!refreshTask) {
    refreshTask = (async () => {
      do {
        pendingRefresh = false;
        const response = await fetch("/api/state");
        if (!response.ok) throw new Error("Host state unavailable");
        state = await response.json();
        render();
      } while (pendingRefresh);
    })().finally(() => { refreshTask = undefined; });
  }
  return refreshTask;
}
byId("reload").onclick = () => mutation("/api/reload", {}).catch(error => message(error.message));
refresh().catch(error => message(error.message));
const events = new EventSource("/api/events");
events.addEventListener("changed", () => {
  byId("connection").classList.add("hidden");
  refresh().catch(error => message(error.message));
});
events.onerror = () => {
  byId("connection").textContent = "Host connection interrupted. Status may be stale. Reconnecting; no work is being resubmitted.";
  byId("connection").classList.remove("hidden");
};
