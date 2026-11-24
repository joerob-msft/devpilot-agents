// Node tests for the Copilot app canvas: the canvas-started Golden watch launcher and the
// instance server's Start/Stop gating. Run: node --test ./tests/CopilotCanvas.Tests.mjs
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { CanvasInstanceServer, healthTitle, launchFailureCause } from "../src/DevPilot.CopilotCanvas/canvas-server.mjs";
import * as launcher from "../src/DevPilot.CopilotCanvas/watch-launcher.mjs";

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

function temp(prefix) {
  return mkdtempSync(join(tmpdir(), prefix));
}

test("the canvas prefers the repository's own Start-DevPilot.ps1 when it supports the canvas, else the recorded toolkit", async () => {
  const extensionDir = temp("canvas-ext-");
  const repo = temp("canvas-repo-");
  try {
    assert.equal(launcher.readToolkit(extensionDir).available, false);
    writeFileSync(join(extensionDir, "toolkit.json"), JSON.stringify({ schemaVersion: 1, toolkitRoot: "relative\\path" }));
    assert.equal(launcher.readToolkit(extensionDir).available, false);
    writeFileSync(join(extensionDir, "toolkit.json"), JSON.stringify({ schemaVersion: 1, toolkitRoot: repositoryRoot, version: "9.9.9" }));
    const toolkit = launcher.readToolkit(extensionDir);
    assert.equal(toolkit.available, true);
    assert.equal(toolkit.watchScript, join(repositoryRoot, "tools", "Watch-DevPilotAgents.ps1"));

    // No repository script: the recorded toolkit's Watch -Golden.
    let entrypoint = await launcher.resolveEntrypoint(repo, { extensionDir });
    assert.equal(entrypoint.kind, "toolkit");
    const toolkitBase = ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", toolkit.watchScript, "-Golden", "-Headless", "-CanvasBridge"];
    assert.deepEqual(launcher.entrypointArguments(entrypoint), toolkitBase);
    assert.deepEqual(launcher.entrypointArguments(entrypoint, { previewOnly: true, whatIf: true }), [...toolkitBase, "-PreviewOnly", "-WhatIf"]);

    // A repository script without both switches is not used (real pwsh parameter probe; never executed).
    const script = join(repo, "Start-DevPilot.ps1");
    writeFileSync(script, "[CmdletBinding()] param([switch]$CanvasBridge) throw 'must not run'\n");
    entrypoint = await launcher.resolveEntrypoint(repo, { extensionDir });
    assert.equal(entrypoint.kind, "toolkit");
    assert.match(entrypoint.repositoryNote, /does not declare -CanvasBridge and -Headless/);

    // A supporting repository script wins, with only the canvas switches added.
    writeFileSync(script, "[CmdletBinding(SupportsShouldProcess)] param([switch]$CanvasBridge, [switch]$Headless, [switch]$PreviewOnly) throw 'must not run'\n");
    entrypoint = await launcher.resolveEntrypoint(repo, { extensionDir });
    assert.equal(entrypoint.kind, "repository");
    assert.equal(entrypoint.script, script);
    assert.deepEqual(launcher.entrypointArguments(entrypoint, { previewOnly: true, whatIf: true }),
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", script, "-CanvasBridge", "-Headless", "-PreviewOnly", "-WhatIf"]);
  } finally {
    rmSync(extensionDir, { recursive: true, force: true });
    rmSync(repo, { recursive: true, force: true });
  }
});
test("Start spawns the watch with output in a launch log and no terminal, and preview uses -WhatIf", async () => {
  const logDirectory = temp("canvas-log-");
  const entrypoint = { kind: "toolkit", script: "C:\\toolkit\\tools\\Watch-DevPilotAgents.ps1" };
  const calls = [];
  const spawnImpl = (file, args, options) => {
    calls.push({ file, args, options });
    const child = new EventEmitter();
    child.pid = 4321;
    child.unref = () => { child.unrefed = true; };
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.kill = () => {};
    calls.at(-1).child = child;
    setImmediate(() => {
      child.stdout.emit("data", "\u001b[36mDevPilot launch plan\u001b[0m\r\n  Mode : PREVIEW ONLY\r\n");
      child.emit("close", 0);
    });
    return child;
  };
  try {
    const launch = launcher.startLaunch({ entrypoint, repositoryRoot: "C:\\repo", previewOnly: false, logDirectory, spawnImpl, now: () => 0 });
    assert.equal(launch.pid, 4321);
    assert.ok(existsSync(launch.logPath));
    assert.equal(calls[0].options.detached, undefined);
    assert.equal(calls[0].options.windowsHide, true);
    assert.equal(calls[0].child.unrefed, true);
    assert.equal(calls[0].options.shell, false);
    assert.equal(calls[0].options.cwd, "C:\\repo");
    assert.equal(calls[0].options.stdio[0], "ignore");
    assert.equal(calls[0].args.includes("-WhatIf"), false);
    assert.equal(calls[0].args.includes("-PreviewOnly"), false);

    const preview = await launcher.previewLaunch({ entrypoint, repositoryRoot: "C:\\repo", previewOnly: true, spawnImpl });
    assert.equal(preview.ok, true);
    assert.equal(preview.output, "DevPilot launch plan\n  Mode : PREVIEW ONLY\n");
    assert.deepEqual(calls[1].args.slice(-2), ["-PreviewOnly", "-WhatIf"]);
    assert.equal(calls[1].options.detached, undefined);

    // A spawn failure is recorded on the launch instead of crashing the extension.
    const failing = launcher.startLaunch({
      entrypoint, repositoryRoot: "C:\\missing", previewOnly: false, logDirectory, now: () => 1,
      spawnImpl: () => {
        const child = new EventEmitter();
        setImmediate(() => child.emit("error", new Error("spawn pwsh ENOENT")));
        return child;
      },
    });
    await new Promise((resolveWait) => setImmediate(resolveWait));
    assert.equal(failing.pid, 0);
    assert.match(failing.error, /ENOENT/);
  } finally {
    rmSync(logDirectory, { recursive: true, force: true });
  }
});

async function startBridgeStub() {
  const shutdowns = [];
  const server = createServer((req, res) => {
    if (req.method === "POST" && req.url === "/v1/shutdown") shutdowns.push(req.headers.authorization);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(req.url === "/v1/shutdown" ? { stopping: true } : {
      schemaVersion: 1, launchMode: "operational", headless: true, consumerRepositoryRoot: repositoryRoot,
      dashboardPid: process.pid, view: "live", automation: { available: false }, instances: [], runs: [], queued: [],
    }));
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  return { server, shutdowns, url: `http://127.0.0.1:${server.address().port}/` };
}

test("the canvas server starts a watch only from a fresh human-previewed plan and stops only a headless watch", async () => {
  const watchRoot = temp("canvas-watch-");
  const previews = [];
  const starts = [];
  const fakeLauncher = {
    ...launcher,
    resolveEntrypoint: async (root) => ({
      available: true, kind: "toolkit", script: "C:\\toolkit\\tools\\Watch-DevPilotAgents.ps1", repositoryRoot: root,
      toolkitRoot: "C:\\toolkit", version: "9.9.9", repositoryNote: "",
    }),
    previewLaunch: async (options) => { previews.push(options); return { ok: true, exitCode: 0, output: "DevPilot launch plan" }; },
    startLaunch: (options) => { starts.push(options); return { pid: process.pid, logPath: join(watchRoot, "launch.log"), startedAt: Date.now(), previewOnly: options.previewOnly }; },
    logTail: () => "",
  };
  const server = new CanvasInstanceServer({ workingDirectory: repositoryRoot, watchRoot, launcher: fakeLauncher });
  const bridge = await startBridgeStub();
  await server.start();
  const nonceHtml = await (await fetch(server.url)).text();
  const nonce = /name="devpilot-nonce" content="([^"]+)"/.exec(nonceHtml)[1];
  const post = async (path, body, headers = {}) => {
    const response = await fetch(new URL(path, server.url), {
      method: "POST", headers: { "content-type": "application/json", "x-canvas-nonce": nonce, ...headers }, body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() };
  };
  try {
    const state = await (await fetch(new URL("/api/state", server.url), { headers: { "x-canvas-nonce": nonce } })).json();
    assert.equal(state.connection.state, "no-bridge");
    assert.equal(state.connection.launcher.available, true);

    assert.equal((await post("/api/watch/start", { launchToken: "guess" })).body.error, "launch-repreview-required");
    assert.equal((await post("/api/watch/preview", { previewOnly: true }, { "x-canvas-nonce": "wrong" })).status, 403);
    const preview = await post("/api/watch/preview", { previewOnly: true });
    assert.equal(preview.status, 200);
    assert.equal(preview.body.ok, true);
    assert.equal(previews[0].previewOnly, true);
    assert.equal(starts.length, 0);

    const started = await post("/api/watch/start", { launchToken: preview.body.launchToken });
    assert.equal(started.status, 200);
    assert.equal(starts.length, 1);
    assert.equal(starts[0].previewOnly, true);
    assert.equal(starts[0].repositoryRoot, preview.body.repositoryRoot);
    assert.equal(starts[0].entrypoint.script, "C:\\toolkit\\tools\\Watch-DevPilotAgents.ps1");
    assert.equal(previews[0].entrypoint.kind, "toolkit");
    assert.equal((await post("/api/watch/start", { launchToken: preview.body.launchToken })).status, 409);

    // A terminal-owned watch cannot be stopped from the canvas; a headless one can.
    const watchDirectory = join(watchRoot, "20261110T000000Z-0123abcd");
    mkdirSync(watchDirectory);
    const discovery = {
      schemaVersion: 1, url: bridge.url, token: "bridge-token", dashboardPid: process.pid,
      consumerRepositoryRoot: preview.body.repositoryRoot, launchMode: "operational", headless: false,
      startedAtUtc: new Date().toISOString(),
    };
    writeFileSync(join(watchDirectory, "canvas-bridge.v1.json"), JSON.stringify(discovery));
    assert.equal((await post("/api/watch/stop", {})).body.error, "terminal-owned");
    writeFileSync(join(watchDirectory, "canvas-bridge.v1.json"), JSON.stringify({ ...discovery, headless: true }));
    assert.equal((await post("/api/watch/preview", { previewOnly: false })).status, 409);
    const stopped = await post("/api/watch/stop", {});
    assert.equal(stopped.status, 200);
    assert.deepEqual(bridge.shutdowns, ["Bearer bridge-token"]);
    assert.equal(JSON.parse(readFileSync(join(watchDirectory, "canvas-bridge.v1.json"), "utf8")).headless, true);
  } finally {
    server.close();
    bridge.server.closeAllConnections();
    bridge.server.close();
    rmSync(watchRoot, { recursive: true, force: true });
  }
});

test("a failed launch surfaces the model preflight line, else the last Error/Exception line", () => {
  const preflight = [
    "🤖 Agency banner",
    "DevPilot model preflight failed for model 'gpt-x': Error: No supported model available. Choose a supported model (copilot --help) or pass -SkipModelPreflight.",
    "At line:1 char:1",
    "Exception: rethrown",
  ].join("\n");
  assert.match(launchFailureCause(preflight), /^DevPilot model preflight failed for model 'gpt-x'/);
  assert.equal(launchFailureCause("starting\nSystem.IO.IOException: disk full\ndone"), "System.IO.IOException: disk full");
  assert.equal(launchFailureCause("all good"), "");
  assert.equal(launchFailureCause(undefined), "");
});

test("the canvas title flags failing or stuck agents and tolerates missing health", () => {
  assert.equal(healthTitle(null), "DevPilot Operations");
  assert.equal(healthTitle([{ role: "reviewer", state: "healthy" }]), "DevPilot Operations");
  assert.equal(healthTitle([{ role: "reviewer", state: "failing" }, { role: "review-handler", state: "stuck" }, null]),
    "⚠ DevPilot Operations · Reviewer failing · Review Handler stuck");
});
// ---------------------------------------------------------------------------------------------
// Render guard: ui/app.js runs in a vm against a minimal DOM built from ui/index.html, fed bridge
// payloads whose optional fields are all null or missing. No rendered text or title/aria-label may
// contain "null", "undefined", "NaN" or "Invalid Date".
// ---------------------------------------------------------------------------------------------

const UI_DIR = join(repositoryRoot, "src", "DevPilot.CopilotCanvas", "ui");
const BAD_TEXT = /\b(null|undefined|NaN)\b|Invalid Date/;

class FakeNode {
  constructor() { this.parentNode = null; }
  get isConnected() {
    let node = this;
    while (node.parentNode) node = node.parentNode;
    return node.isDocumentRoot === true;
  }
  remove() {
    if (!this.parentNode) return;
    const siblings = this.parentNode.childNodes;
    siblings.splice(siblings.indexOf(this), 1);
    this.parentNode = null;
  }
}

class FakeText extends FakeNode {
  constructor(data) { super(); this.data = data; }
  get textContent() { return this.data; }
}

const camelToData = (name) => `data-${name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`;

function parseSelector(selector) {
  return selector.trim().split(/\s+/).map((part) => {
    const compound = { tag: "", id: "", classes: [], attrs: [] };
    for (const [token] of part.matchAll(/#[\w-]+|\.[\w-]+|\[[^\]]+\]|^[\w-]+/g)) {
      if (token.startsWith("#")) compound.id = token.slice(1);
      else if (token.startsWith(".")) compound.classes.push(token.slice(1));
      else if (token.startsWith("[")) {
        const [, name, value] = /^\[([\w-]+)(?:=["']?([^"'\]]*)["']?)?\]$/.exec(token);
        compound.attrs.push([name, value]);
      } else compound.tag = token.toLowerCase();
    }
    return compound;
  });
}

function matchesCompound(node, compound) {
  if (!(node instanceof FakeElement)) return false;
  if (compound.tag && node.tagName.toLowerCase() !== compound.tag) return false;
  if (compound.id && node.getAttribute("id") !== compound.id) return false;
  const classes = (node.getAttribute("class") ?? "").split(/\s+/);
  if (compound.classes.some((name) => !classes.includes(name))) return false;
  return compound.attrs.every(([name, value]) => node.hasAttribute(name) && (value === undefined || node.getAttribute(name) === value));
}

function matchesSelector(node, selector) {
  const compounds = parseSelector(selector);
  if (!matchesCompound(node, compounds.at(-1))) return false;
  let index = compounds.length - 2;
  for (let parent = node.parentNode; parent && index >= 0; parent = parent.parentNode) {
    if (matchesCompound(parent, compounds[index])) index -= 1;
  }
  return index < 0;
}

class FakeElement extends FakeNode {
  constructor(document, tagName) {
    super();
    this.ownerDocument = document;
    this.tagName = tagName.toUpperCase();
    this.attributes = new Map();
    this.childNodes = [];
    this.listeners = {};
    this.scrollTop = 0;
    this.open = false;
    const attributes = this.attributes;
    this.dataset = new Proxy({}, {
      get: (_, name) => typeof name === "string" ? attributes.get(camelToData(name)) : undefined,
      set: (_, name, value) => { attributes.set(camelToData(name), String(value)); return true; },
    });
    this.classList = {
      contains: (name) => (this.className || "").split(/\s+/).includes(name),
      toggle: (name, force) => {
        const set = new Set((this.className || "").split(/\s+/).filter(Boolean));
        const on = force ?? !set.has(name);
        if (on) set.add(name); else set.delete(name);
        this.className = [...set].join(" ");
      },
    };
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  hasAttribute(name) { return this.attributes.has(name); }
  removeAttribute(name) { this.attributes.delete(name); }
  get id() { return this.getAttribute("id") ?? ""; }
  get className() { return this.getAttribute("class") ?? ""; }
  set className(value) { this.setAttribute("class", value); }
  get title() { return this.getAttribute("title") ?? ""; }
  set title(value) { this.setAttribute("title", value); }
  get hidden() { return this.hasAttribute("hidden"); }
  set hidden(value) { if (value) this.setAttribute("hidden", ""); else this.removeAttribute("hidden"); }
  get children() { return this.childNodes.filter((node) => node instanceof FakeElement); }
  get childElementCount() { return this.children.length; }
  get textContent() { return this.childNodes.map((node) => node.textContent).join(""); }
  set textContent(value) {
    this.replaceChildren();
    // Like the DOM: null clears, anything else (including undefined) is stringified.
    if (value !== null) this.append(String(value));
  }
  append(...nodes) {
    for (const item of nodes) {
      const node = item instanceof FakeNode ? item : new FakeText(String(item));
      node.remove();
      node.parentNode = this;
      this.childNodes.push(node);
    }
  }
  replaceChildren(...nodes) {
    for (const node of this.childNodes) node.parentNode = null;
    this.childNodes = [];
    this.append(...nodes);
  }
  after(node) {
    const parent = this.parentNode;
    node.remove();
    parent.childNodes.splice(parent.childNodes.indexOf(this) + 1, 0, node);
    node.parentNode = parent;
  }
  contains(node) {
    for (let current = node; current; current = current.parentNode) if (current === this) return true;
    return false;
  }
  *descendants() {
    for (const node of this.childNodes) {
      if (node instanceof FakeElement) {
        yield node;
        yield* node.descendants();
      }
    }
  }
  querySelectorAll(selector) { return [...this.descendants()].filter((node) => matchesSelector(node, selector)); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  matches(selector) { return matchesSelector(this, selector); }
  closest(selector) {
    for (let node = this; node instanceof FakeElement; node = node.parentNode) if (node.matches(selector)) return node;
    return null;
  }
  addEventListener(type, listener) { (this.listeners[type] ??= []).push(listener); }
  dispatch(type, extra = {}) {
    const event = { type, target: this, repeat: false, preventDefault() {}, stopPropagation() {}, ...extra };
    for (const listener of this.listeners[type] ?? []) listener(event);
    this[`on${type}`]?.(event);
  }
  click() { this.dispatch("click"); }
  focus() { this.ownerDocument.activeElement = this; }
  showModal() { this.open = true; }
  close() { this.open = false; this.onclose?.(); }
}

const VOID_TAGS = new Set(["meta", "link", "input", "br", "img"]);

function fakeDocument(html) {
  const document = {
    title: "", hidden: false, activeElement: null,
    createElement: (tag) => new FakeElement(document, tag),
    createTextNode: (text) => new FakeText(String(text)),
    addEventListener() {},
  };
  const root = new FakeElement(document, "html");
  root.isDocumentRoot = true;
  const stack = [root];
  for (const [, close, tag, attributes, text] of html.matchAll(/<(\/?)([a-zA-Z][\w-]*)([^>]*)>|([^<]+)/g)) {
    if (text !== undefined) {
      if (text.trim()) stack.at(-1).append(text);
      continue;
    }
    const name = tag.toLowerCase();
    if (close) {
      while (stack.length > 1 && stack.pop().tagName.toLowerCase() !== name) { /* unwind */ }
      continue;
    }
    const node = new FakeElement(document, name);
    for (const [, key, value] of attributes.matchAll(/([\w:-]+)(?:="([^"]*)")?/g)) node.setAttribute(key, value ?? "");
    stack.at(-1).append(node);
    if (!VOID_TAGS.has(name) && !attributes.trim().endsWith("/")) stack.push(node);
  }
  document.documentElement = root;
  document.body = root.querySelector("body");
  document.getElementById = (id) => root.querySelector(`#${id}`);
  document.querySelector = (selector) => root.querySelector(selector);
  document.querySelectorAll = (selector) => root.querySelectorAll(selector);
  return document;
}

const settle = async () => { for (let i = 0; i < 20; i += 1) await new Promise((resolveTick) => setImmediate(resolveTick)); };

async function loadCanvas(respond) {
  const { runInNewContext } = await import("node:vm");
  const document = fakeDocument(readFileSync(join(UI_DIR, "index.html"), "utf8"));
  const fetch = async (path, init = {}) => {
    const body = init.body ? JSON.parse(init.body) : undefined;
    const value = await respond(String(path), body);
    return { ok: true, status: 200, json: async () => value };
  };
  runInNewContext(readFileSync(join(UI_DIR, "app.js"), "utf8"), {
    document, fetch, URL, Node: FakeNode, Element: FakeElement, console, JSON, Promise,
    setTimeout: () => 0, clearTimeout: () => {}, setInterval: () => 0,
    requestAnimationFrame: (callback) => { queueMicrotask(() => callback(0)); return 0; },
    navigator: { clipboard: { writeText: async () => {} } },
  }, { filename: "app.js" });
  await settle();
  return document;
}

function assertNoBadText(document, label) {
  const problems = [];
  const visit = (node, path) => {
    for (const child of node.childNodes) {
      if (child instanceof FakeText) {
        if (BAD_TEXT.test(child.data)) problems.push(`${path}: text "${child.data}"`);
        continue;
      }
      const where = `${path}>${child.tagName.toLowerCase()}${child.id ? `#${child.id}` : ""}`;
      for (const name of ["title", "aria-label", "value", "placeholder"]) {
        const value = child.getAttribute(name);
        if (value !== null && BAD_TEXT.test(value)) problems.push(`${where}: ${name}="${value}"`);
      }
      visit(child, where);
    }
  };
  visit(document.documentElement, "");
  if (BAD_TEXT.test(document.title)) problems.push(`document.title "${document.title}"`);
  assert.deepEqual(problems, [], `${label} rendered null-like text`);
}

async function clickEveryRow(document, label) {
  for (const row of document.querySelectorAll("[role=option]")) {
    row.click();
    await settle();
    assertNoBadText(document, `${label} (selected ${row.textContent.slice(0, 40)})`);
  }
}

const NULL_COMPLETION = {
  result: null, reason: null, summary: null, failureDetail: null, failureKind: null, failureLogPath: null,
  findings: { critical: null, important: null, suggestion: null }, delivered: [null], previewArtifact: null,
  timestampMs: null, elapsedMilliseconds: null,
};

function nullData(view) {
  return {
    schemaVersion: 1, launchMode: null, headless: null, consumerRepositoryRoot: null, dashboardPid: null,
    toolkitVersion: null, toolkitCommit: null, toolkitRoot: null, view,
    automation: { available: true, agents: [null, { role: null, state: null, continuous: true, intervalSeconds: null, retryAtUtc: null }] },
    health: [null,
      { role: null, state: "failing", consecutiveFailures: null, cause: null, failingSinceUtc: null, lastSuccessUtc: "not a date",
        notifications: { failuresSinceSuccess: null, warning: true, latestReason: null } },
      { role: "reviewer", state: "stuck", stuck: [{ pullRequestId: null, repeatCount: null, nextAttemptUtc: null, outcome: null }] }],
    instances: [
      { key: "empty-fields", agent: null, status: null, phase: null, pullRequestId: null, pullRequestTitle: null, pullRequestUrl: null,
        pullRequestAuthor: null, repository: null, completion: NULL_COMPLETION, blocked: { reason: null, nextRetry: null },
        waiting: { kind: null, delayMilliseconds: null }, heartbeatAgeMilliseconds: null, phaseElapsedMilliseconds: null,
        totalElapsedMilliseconds: null, lastEventMs: null, timeline: null, threadCount: null, actionableThreadCount: null,
        changedFileCount: null, modelActivity: null, candidateStory: null, sourceBranch: null, targetBranch: null,
        instanceId: null, processId: NaN, sessionNamespace: null, sourceCommit: null },
      { key: "missing", status: "stale" },
      { key: "failed", agent: "reviewer", status: "failed", pullRequestId: 7,
        completion: { ...NULL_COMPLETION, result: "failed", failureDetail: "boom", timestampMs: NaN, failureLogPath: "C:\\log.txt" },
        timeline: [null, { timestampMs: null, text: null }, { timestampMs: 8.64e16, text: "far future" }] },
    ],
    historyAvailable: true,
    ...(view === "history" ? {
      pullRequests: [
        { key: "h-empty", pullRequestId: null, title: null, repository: null, lastSeenMs: null, url: null, author: null,
          sourceBranch: null, targetBranch: null, reviewer: { result: null, status: null, resultAtMs: null, statusAtMs: null, failureDetail: null },
          reviewHandler: null },
        { key: "h-missing" },
      ],
      hiddenPullRequestCount: null,
    } : {}),
    recentPullRequests: null,
    runs: [{ dispatchId: "d1", role: null, pullRequestId: null, headline: null, detail: null, latest: null, elapsed: null, terminal: null }],
    queued: [{ queueId: "q1", mode: null, role: null, pullRequestId: null, state: null, code: null }],
    notRun: [{ queueId: "n1", mode: null, role: null, pullRequestId: null, retiredAtUtc: null }],
  };
}

function nullConnection(extra = {}) {
  return {
    state: "connected", error: null, workingDirectory: null, command: null, canvasVersion: null,
    bridge: { startedAtUtc: null, launchMode: null, toolkitVersion: null, toolkitCommit: null },
    others: [], launcher: null, launch: null, ...extra,
  };
}

test("the canvas renders null or missing bridge fields without null-like text, in Live, History and every detail", async () => {
  for (const automation of [undefined, { available: false, error: null }, { available: true, agents: null }]) {
    const document = await loadCanvas((path) => {
      const view = path.includes("view=history") ? "history" : "live";
      const data = nullData(view);
      if (automation) data.automation = automation;
      return { connection: nullConnection(), data, prefill: null };
    });
    assertNoBadText(document, "live");
    await clickEveryRow(document, "live");
    document.getElementById("tab-history").click();
    await settle();
    assert.ok(document.querySelectorAll("[role=option]").length >= 2, "history rows rendered");
    assertNoBadText(document, "history");
    await clickEveryRow(document, "history");
  }
});

test("the no-watch canvas renders null launcher, launch and other-watch fields without null-like text", async () => {
  const launcher = { available: true, repositoryRoot: null, kind: "repository", script: null, toolkitRoot: null, version: null, note: null };
  const launch = { pid: null, previewOnly: null, elapsedMs: null, kind: null, logPath: null, logTail: null, failureCause: null };
  const others = [{ watchId: null, consumerRepositoryRoot: null, launchMode: null, startedAtUtc: null }];
  const connections = [
    { state: "no-bridge", launcher, others },
    { state: "disconnected", launcher: { available: false, reason: null }, others: null },
    { state: "no-bridge", launcher: { ...launcher, kind: "toolkit" }, launch: { ...launch, state: "starting" } },
    { state: "no-bridge", launcher, launch: { ...launch, state: "failed" } },
    { state: "no-bridge", launcher, launch: { ...launch, state: "starting", logTail: "Verified toolkit release: v0.5.15 @ 0123456789abcdef0123456789abcdef01234567" } },
  ];
  for (const connection of connections) {
    const document = await loadCanvas(() => ({ connection: nullConnection({ bridge: null, ...connection }), data: null, prefill: null }));
    assertNoBadText(document, `no-watch ${connection.state}/${connection.launch?.state ?? "idle"}`);
  }

  // The launch plan shows its toolkit version, with a refresh hint inside the channel cooldown.
  const document = await loadCanvas((path) => path === "/api/watch/preview"
    ? { ok: true, output: "DevPilot launch plan\nVerified toolkit within the six-hour channel cooldown: v0.5.15\n", command: null, previewOnly: null, launchToken: null }
    : { connection: nullConnection({ state: "no-bridge", bridge: null, launcher }), data: null, prefill: null });
  document.getElementById("launch-begin").click();
  await settle();
  const text = document.getElementById("launch").textContent;
  assert.match(text, /Toolkit for this launch: v0\.5\.15/);
  assert.match(text, /newer release may exist.*Install-DevPilotAgents\.ps1 -SetupDashboard -Refresh/);
  assertNoBadText(document, "launch plan");
});

test("the canvas header shows the watch toolkit and canvas versions and flags an older canvas", async () => {
  const commit = "0123456789abcdef0123456789abcdef01234567";
  const document = await loadCanvas(() => ({
    connection: nullConnection({ canvasVersion: "0.5.12" }),
    data: { ...nullData("live"), launchMode: "operational", toolkitVersion: "0.5.15", toolkitCommit: commit, toolkitRoot: "C:\\toolkits\\x" },
    prefill: null,
  }));
  const badge = document.getElementById("toolkit-version");
  assert.equal(badge.hidden, false);
  assert.equal(badge.textContent, "v0.5.15");
  assert.match(badge.title, new RegExp(`commit ${commit}`));
  assert.equal(document.getElementById("canvas-version").textContent, "canvas v0.5.12");
  const hint = document.getElementById("version-hint");
  assert.equal(hint.hidden, false);
  assert.match(hint.textContent, /Canvas v0\.5\.12 is older than the watch toolkit v0\.5\.15.*Install-DevPilotCanvas\.ps1/);

  const same = await loadCanvas(() => ({
    connection: nullConnection({ canvasVersion: "v0.5.15" }), data: { ...nullData("live"), toolkitVersion: "0.5.15" }, prefill: null,
  }));
  assert.equal(same.getElementById("version-hint").hidden, true);
  assertNoBadText(same, "matching versions");
});
