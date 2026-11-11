// Pure-Node half of the DevPilot Operations canvas: bridge discovery, repository matching, and a
// per-canvas-instance loopback server that serves ui/ and proxies to the dashboard's canvas bridge.
// Kept free of @github/copilot-sdk so it can be exercised directly with node.
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as watchLauncher from "./watch-launcher.mjs";

const UI_DIR = join(dirname(fileURLToPath(import.meta.url)), "ui");
const DISCOVERY_FILE = "canvas-bridge.v1.json";
const WATCH_ID = /^\d{8}T\d{6}Z-[0-9a-f]{8}$/;
const MAX_BODY_BYTES = 16 * 1024;
const STATUS_TIMEOUT_MS = 15_000;
const REVIEW_TIMEOUT_MS = 180_000;
const LAUNCH_PREVIEW_TTL_MS = 5 * 60_000;
const LAUNCH_ATTACH_TIMEOUT_MS = 120_000;
const PROXIED_POSTS = new Set([
  "/api/scan-now",
  "/api/review/describe",
  "/api/review/dispatch",
  "/api/review/prepare-run",
  "/api/review/confirm-run",
  "/api/review/cancel-queued",
  "/api/review/cancel",
]);
const STATIC = {
  "/app.js": ["app.js", "text/javascript; charset=utf-8"],
  "/styles.css": ["styles.css", "text/css; charset=utf-8"],
};
const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'";

export function defaultWatchRoot(env = process.env) {
  if (process.platform === "win32") {
    const localAppData = env.LOCALAPPDATA || join(homedir(), "AppData", "Local");
    return join(localAppData, "DevPilot", "watch");
  }
  const base = env.XDG_STATE_HOME || join(homedir(), ".local", "state");
  return join(base, "devpilot", "watch");
}

export function normalizePath(value) {
  if (!value) return "";
  const resolved = resolve(String(value)).replace(/[\\/]+$/, "");
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

function processAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

export function findBridges(watchRoot) {
  if (!existsSync(watchRoot)) return [];
  const bridges = [];
  for (const entry of readdirSync(watchRoot, { withFileTypes: true })) {
    if (!entry.isDirectory() || !WATCH_ID.test(entry.name)) continue;
    const file = join(watchRoot, entry.name, DISCOVERY_FILE);
    if (!existsSync(file)) continue;
    try {
      const discovery = JSON.parse(readFileSync(file, "utf8"));
      if (discovery?.schemaVersion !== 1 || typeof discovery.url !== "string" || typeof discovery.token !== "string") continue;
      if (!/^http:\/\/127\.0\.0\.1:\d+\/$/.test(discovery.url)) continue;
      if (!processAlive(discovery.dashboardPid)) continue;
      bridges.push({ ...discovery, watchId: entry.name });
    } catch {
      // A half-written or foreign file is simply not a candidate.
    }
  }
  return bridges.sort((a, b) => String(b.startedAtUtc).localeCompare(String(a.startedAtUtc)));
}

function git(cwd, args) {
  return new Promise((resolveGit) => {
    execFile("git", ["-C", cwd, ...args], { timeout: 5_000, windowsHide: true }, (error, stdout) => {
      resolveGit(error ? "" : String(stdout).trim());
    });
  });
}

// Used only when git itself is unavailable: nearest ancestor holding .git, plus the main checkout
// when that .git is a worktree pointer file.
function findRepositoryRootsWithoutGit(workingDirectory) {
  const roots = [];
  let current = resolve(workingDirectory);
  for (;;) {
    const marker = join(current, ".git");
    if (existsSync(marker)) {
      roots.push(normalizePath(current));
      try {
        const pointer = /^gitdir:\s*(.+)$/m.exec(readFileSync(marker, "utf8"))?.[1]?.trim();
        const match = pointer && /^(.*)[\\/]\.git[\\/]worktrees[\\/][^\\/]+$/i.exec(resolve(current, pointer));
        if (match) roots.push(normalizePath(match[1]));
      } catch {
        // A .git directory (EISDIR) is a normal checkout.
      }
      return roots;
    }
    const parent = dirname(current);
    if (parent === current) return roots;
    current = parent;
  }
}

// A Copilot app session often runs in its own worktree, so both the worktree root and the main
// checkout (parent of the common .git directory) are accepted as "this repository".
export async function repositoryRoots(workingDirectory) {
  if (!workingDirectory) return [];
  const [toplevel, commonDir] = await Promise.all([
    git(workingDirectory, ["rev-parse", "--show-toplevel"]),
    git(workingDirectory, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
  ]);
  if (!toplevel) return findRepositoryRootsWithoutGit(workingDirectory);
  const roots = new Set();
  if (toplevel) roots.add(normalizePath(toplevel));
  if (commonDir && basename(commonDir).toLowerCase() === ".git") roots.add(normalizePath(dirname(commonDir)));
  return [...roots];
}

export function selectBridge(bridges, roots) {
  return bridges.find((bridge) => roots.includes(normalizePath(bridge.consumerRepositoryRoot))) ?? null;
}

function publicBridge(bridge) {
  return bridge && {
    watchId: bridge.watchId,
    consumerRepositoryRoot: bridge.consumerRepositoryRoot,
    launchMode: bridge.launchMode,
    headless: bridge.headless === true,
    startedAtUtc: bridge.startedAtUtc,
    dashboardPid: bridge.dashboardPid,
  };
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    ...headers,
  });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
}

async function readBody(req) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > MAX_BODY_BYTES) throw Object.assign(new Error("body-too-large"), { status: 413 });
    chunks.push(chunk);
  }
  if (!total) return "{}";
  const text = Buffer.concat(chunks).toString("utf8");
  try {
    JSON.parse(text);
  } catch {
    throw Object.assign(new Error("invalid-json"), { status: 400 });
  }
  return text;
}

export class CanvasInstanceServer {
  constructor({ workingDirectory, watchRoot = defaultWatchRoot(), log = () => {}, launcher = watchLauncher }) {
    this.workingDirectory = workingDirectory || "";
    this.watchRoot = watchRoot;
    this.log = log;
    this.nonce = randomBytes(24).toString("base64url");
    this.server = undefined;
    this.host = "";
    this.url = "";
    this.bridge = null;
    this.pinnedWatchId = "";
    this.roots = undefined;
    this.prefill = null;
    this.launcher = launcher;
    this.launchPreview = null;
    this.launch = null;
  }

  async start() {
    this.server = createServer((req, res) => {
      this.handle(req, res).catch((error) =>
        send(res, error?.status ?? 500, { error: "canvas-error", detail: String(error?.message ?? error) }));
    });
    await new Promise((resolveListen, reject) => {
      this.server.once("error", reject);
      this.server.listen(0, "127.0.0.1", resolveListen);
    });
    this.host = `127.0.0.1:${this.server.address().port}`;
    this.url = `http://${this.host}/`;
    return this.url;
  }

  close() {
    if (!this.server) return;
    this.server.closeAllConnections();
    this.server.close();
    this.server = undefined;
  }

  setPrefill(pullRequestId, role) {
    this.prefill = { pullRequestId, role: role === "review-handler" ? "review-handler" : "reviewer", at: Date.now() };
  }

  async connection() {
    this.roots ??= await repositoryRoots(this.workingDirectory);
    const bridges = findBridges(this.watchRoot);
    let bridge = this.pinnedWatchId ? bridges.find((item) => item.watchId === this.pinnedWatchId) ?? null : null;
    if (!bridge) {
      this.pinnedWatchId = "";
      bridge = selectBridge(bridges, this.roots);
    }
    this.bridge = bridge;
    // The main checkout (last root) owns .github\copilot\agents for Watch; session worktrees match too.
    const repositoryRoot = this.roots[this.roots.length - 1] ?? "";
    if (bridge && this.launch) this.launch = null;
    return {
      state: bridge ? "connected" : "no-bridge",
      workingDirectory: this.workingDirectory,
      repositoryRoots: this.roots,
      watchRoot: this.watchRoot,
      bridge: publicBridge(bridge),
      others: bridges.filter((item) => item !== bridge).map(publicBridge),
      command: `cd "${repositoryRoot || "<consumer repository>"}"; pwsh -File <devpilot-agents>\\tools\\Watch-DevPilotAgents.ps1 -Golden -CanvasBridge`,
      launcher: bridge ? null : this.launcherState(repositoryRoot),
      launch: this.launchState(),
    };
  }

  launcherState(repositoryRoot) {
    if (!repositoryRoot) return { available: false, reason: "This session folder is not inside a git repository." };
    const toolkit = this.launcher.readToolkit();
    if (!toolkit.available) return { available: false, reason: toolkit.reason, toolkitRoot: toolkit.toolkitRoot ?? "" };
    return {
      available: true, repositoryRoot, toolkitRoot: toolkit.toolkitRoot, version: toolkit.version,
      command: this.launcher.displayCommand(toolkit.watchScript, {}),
    };
  }

  launchState() {
    if (!this.launch) return null;
    const elapsed = Date.now() - this.launch.startedAt;
    let alive = false;
    try {
      alive = this.launch.pid > 0 && (process.kill(this.launch.pid, 0), true);
    } catch (error) {
      alive = error?.code === "EPERM";
    }
    const failed = Boolean(this.launch.error) || !alive || elapsed > LAUNCH_ATTACH_TIMEOUT_MS;
    const tail = failed || elapsed > 10_000 ? this.launcher.logTail(this.launch.logPath) : "";
    return {
      state: failed ? "failed" : "starting", pid: this.launch.pid, logPath: this.launch.logPath,
      previewOnly: this.launch.previewOnly, elapsedMs: elapsed,
      logTail: [this.launch.error, tail].filter(Boolean).join("\n"),
    };
  }

  async previewWatch(body) {
    const { previewOnly } = JSON.parse(body);
    const launch = this.launchState();
    if (launch?.state === "starting") throw Object.assign(new Error("A watch is already starting."), { status: 409 });
    if (launch) this.launch = null;
    const connection = await this.connection();
    if (connection.bridge) throw Object.assign(new Error("A watch is already running for this repository."), { status: 409 });
    if (!connection.launcher?.available) throw Object.assign(new Error(connection.launcher?.reason ?? "Start is unavailable."), { status: 409 });
    const toolkit = this.launcher.readToolkit();
    const repositoryRoot = connection.launcher.repositoryRoot;
    const result = await this.launcher.previewLaunch({ toolkit, repositoryRoot, previewOnly: previewOnly === true });
    this.launchPreview = result.ok
      ? { token: randomBytes(18).toString("base64url"), previewOnly: previewOnly === true, repositoryRoot,
          toolkitRoot: toolkit.toolkitRoot, expiresAt: Date.now() + LAUNCH_PREVIEW_TTL_MS }
      : null;
    return {
      ok: result.ok, exitCode: result.exitCode, output: result.output, previewOnly: previewOnly === true,
      repositoryRoot, toolkitRoot: toolkit.toolkitRoot, version: toolkit.version,
      command: this.launcher.displayCommand(toolkit.watchScript, { previewOnly: previewOnly === true }),
      launchToken: this.launchPreview?.token ?? "",
    };
  }

  async startWatch(body) {
    const { launchToken } = JSON.parse(body);
    const preview = this.launchPreview;
    this.launchPreview = null;
    if (!preview || typeof launchToken !== "string" || launchToken !== preview.token || Date.now() > preview.expiresAt) {
      throw Object.assign(new Error("Preview the launch plan again before starting."), { status: 409, code: "launch-repreview-required" });
    }
    const connection = await this.connection();
    if (connection.bridge) throw Object.assign(new Error("A watch is already running for this repository."), { status: 409 });
    if (connection.launch?.state === "starting") throw Object.assign(new Error("A watch is already starting."), { status: 409 });
    const toolkit = this.launcher.readToolkit();
    if (!toolkit.available || toolkit.toolkitRoot !== preview.toolkitRoot || connection.launcher?.repositoryRoot !== preview.repositoryRoot) {
      throw Object.assign(new Error("The toolkit or repository changed. Preview again."), { status: 409, code: "launch-repreview-required" });
    }
    this.launch = this.launcher.startLaunch({ toolkit, repositoryRoot: preview.repositoryRoot, previewOnly: preview.previewOnly });
    this.log(`Started a ${preview.previewOnly ? "preview-only " : ""}DevPilot Golden watch for ${preview.repositoryRoot} from the canvas (PID ${this.launch.pid}).`);
    return { started: true, pid: this.launch.pid, logPath: this.launch.logPath };
  }

  async stopWatch() {
    await this.connection();
    if (!this.bridge) throw Object.assign(new Error("No DevPilot watch is connected."), { status: 409 });
    if (this.bridge.headless !== true) {
      throw Object.assign(new Error("This watch is owned by a terminal. Quit its dashboard there."), { status: 409, code: "terminal-owned" });
    }
    const result = await this.callBridge("POST", "v1/shutdown", "{}", STATUS_TIMEOUT_MS);
    if (result.status === 200) this.log(`Stopped the DevPilot watch for ${this.bridge.consumerRepositoryRoot} from the canvas.`);
    return result;
  }

  async callBridge(method, path, body, timeoutMs) {
    if (!this.bridge) throw Object.assign(new Error("No DevPilot watch is connected."), { status: 409 });
    const response = await fetch(new URL(path, this.bridge.url), {
      method,
      headers: { authorization: `Bearer ${this.bridge.token}`, ...(body ? { "content-type": "application/json" } : {}) },
      body,
      signal: AbortSignal.timeout(timeoutMs),
    });
    return { status: response.status, body: await response.json().catch(() => ({ error: "invalid-bridge-response" })) };
  }

  async state(view) {
    const connection = await this.connection();
    let data = null;
    if (this.bridge) {
      try {
        const result = await this.callBridge("GET", `v1/status?view=${encodeURIComponent(view || "current")}`,
          undefined, STATUS_TIMEOUT_MS);
        if (result.status === 200) {
          data = result.body;
        } else {
          connection.state = "error";
          connection.error = result.body?.error ?? `HTTP ${result.status}`;
        }
      } catch (error) {
        connection.state = "disconnected";
        connection.error = String(error?.message ?? error);
        this.bridge = null;
      }
    }
    return { connection, data, prefill: this.prefill };
  }

  async handle(req, res) {
    if (req.headers.host !== this.host) return send(res, 403, { error: "invalid-host" });
    const url = new URL(req.url ?? "/", `http://${this.host}`);
    if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
      const html = readFileSync(join(UI_DIR, "index.html"), "utf8").replace("__DEVPILOT_NONCE__", this.nonce);
      return send(res, 200, html, { "content-type": "text/html; charset=utf-8", "content-security-policy": CSP });
    }
    if (req.method === "GET" && Object.hasOwn(STATIC, url.pathname)) {
      const [file, type] = STATIC[url.pathname];
      return send(res, 200, readFileSync(join(UI_DIR, file), "utf8"), { "content-type": type });
    }
    if (!url.pathname.startsWith("/api/")) return send(res, 404, { error: "not-found" });
    if (req.headers["x-canvas-nonce"] !== this.nonce) return send(res, 403, { error: "invalid-nonce" });
    if (req.method === "GET" && url.pathname === "/api/state") {
      return send(res, 200, await this.state(url.searchParams.get("view")));
    }
    if (req.method !== "POST") return send(res, 405, { error: "method-not-allowed" });
    if (req.headers.origin && req.headers.origin !== `http://${this.host}`) return send(res, 403, { error: "invalid-origin" });
    if (!/^application\/json(\s*;|$)/i.test(req.headers["content-type"] ?? "")) return send(res, 415, { error: "json-required" });
    const body = await readBody(req);
    if (url.pathname === "/api/prefill/clear") {
      this.prefill = null;
      return send(res, 200, { ok: true });
    }
    if (url.pathname === "/api/connect") {
      const { watchId } = JSON.parse(body);
      if (!findBridges(this.watchRoot).some((item) => item.watchId === watchId)) return send(res, 404, { error: "unknown-watch" });
      this.pinnedWatchId = watchId;
      return send(res, 200, { ok: true });
    }
    try {
      if (url.pathname === "/api/watch/preview") return send(res, 200, await this.previewWatch(body));
      if (url.pathname === "/api/watch/start") return send(res, 200, await this.startWatch(body));
      if (url.pathname === "/api/watch/stop") {
        const result = await this.stopWatch();
        return send(res, result.status, result.body);
      }
    } catch (error) {
      if (!error?.status) throw error;
      return send(res, error.status, { error: error.code ?? "watch-unavailable", detail: String(error.message) });
    }
    if (!PROXIED_POSTS.has(url.pathname)) return send(res, 404, { error: "not-found" });
    await this.connection();
    const result = await this.callBridge("POST", `v1/${url.pathname.slice("/api/".length)}`, body, REVIEW_TIMEOUT_MS);
    if (result.status === 200 && url.pathname === "/api/review/dispatch") {
      this.log(`Started DevPilot run ${result.body?.dispatchId ?? ""} from the canvas.`);
    }
    return send(res, result.status, result.body);
  }
}
