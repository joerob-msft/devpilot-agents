import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import type { Agent, Manifest, Packet, Prepared, Result, Swarm } from "./contracts.js";

export const hash = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
const idPattern = /^[a-z][a-z0-9-]{0,47}$/;
export function object(value: unknown, where: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${where}: expected object`);
  return value as Record<string, unknown>;
}
export function keys(value: Record<string, unknown>, allowed: string[], where: string): void {
  const unexpected = Object.keys(value).find(k => !allowed.includes(k));
  const missing = allowed.find(k => !Object.hasOwn(value, k));
  if (unexpected !== undefined || missing !== undefined) {
    const key = unexpected ?? missing!;
    const field = /^[a-zA-Z_][a-zA-Z0-9_]{0,79}$/.test(key) ? `.${key}` : `[${JSON.stringify(key).slice(0, 120)}]`;
    throw new Error(`${where}${field}: ${unexpected !== undefined ? "unexpected" : "missing"} field; expected exactly ${allowed.join(", ")}`);
  }
}
export function text(value: unknown, max: number, where: string): string {
  if (typeof value !== "string" || !value.trim() || value.length > max ||
      /[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(value)) throw new Error(`${where}: invalid text`);
  return value;
}
function identifier(value: unknown): string {
  const id = text(value, 48, "id");
  if (!idPattern.test(id)) throw new Error(`Invalid id: ${id}`);
  return id;
}
function integer(value: unknown, min: number, max: number, where: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    throw new Error(`${where}: expected integer ${min}..${max}`);
  }
  return value;
}
function list(value: unknown, max: number, where: string): unknown[] {
  if (!Array.isArray(value) || value.length > max) throw new Error(`${where}: expected array, max ${max}`);
  return value;
}
export function noLinks(file: string): void {
  let cursor = path.resolve(file);
  while (true) {
    if (lstatSync(cursor).isSymbolicLink()) throw new Error(`Linked path is not allowed: ${cursor}`);
    const parent = path.dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
}
export function repositoryRoot(value: string): string {
  const root = realpathSync(value);
  noLinks(path.resolve(value));
  const gitRoot = execFileSync("git", ["-C", root, "rev-parse", "--show-toplevel"], {
    encoding: "utf8", timeout: 10000, maxBuffer: 8192, windowsHide: true,
  }).trim();
  if (realpathSync(gitRoot).toLowerCase() !== root.toLowerCase()) {
    throw new Error("--repo must name the repository/worktree root");
  }
  return root;
}
export function revision(root: string): string {
  return execFileSync("git", ["-C", root, "rev-parse", "HEAD"], {
    encoding: "utf8", timeout: 10000, maxBuffer: 8192, windowsHide: true,
  }).trim();
}
export function scopedFile(root: string, relative: string): string {
  if (relative.includes("\\") || relative.includes(":") || relative.startsWith("/") ||
      relative.split("/").some(p => !p || p === "." || p === "..")) {
    throw new Error(`Expected safe repository-relative slash path: ${relative}`);
  }
  const file = path.join(root, ...relative.split("/"));
  noLinks(file);
  if (!lstatSync(file).isFile()) throw new Error(`Not a regular file: ${relative}`);
  return file;
}
export function readBounded(file: string, limit: number): string {
  if (lstatSync(file).size > limit) throw new Error(`File exceeds ${limit} bytes: ${file}`);
  const bytes = readFileSync(file);
  if (bytes.length > limit) throw new Error(`File grew past ${limit} bytes: ${file}`);
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}
export function parseManifest(input: unknown): Manifest {
  const root = object(input, "manifest");
  keys(root, ["schemaVersion", "inputProfiles", "agents", "swarms"], "manifest");
  if (root.schemaVersion !== 1) throw new Error("Unsupported manifest schemaVersion");
  const profiles = object(root.inputProfiles, "inputProfiles");
  if (Object.keys(profiles).length > 16) throw new Error("Too many input profiles");
  const inputProfiles: Manifest["inputProfiles"] = Object.create(null);
  for (const [name, value] of Object.entries(profiles)) {
    identifier(name);
    const profile = object(value, name);
    keys(profile, ["files"], name);
    const files = list(profile.files, 20, `${name}.files`).map(f => text(f, 240, "input path"));
    if (!files.length || new Set(files).size !== files.length) throw new Error("Input files must be nonempty and unique");
    inputProfiles[name] = { files };
  }
  const agents = list(root.agents, 32, "agents").map(value => {
    const agent = object(value, "agent");
    keys(agent, ["id", "prompt", "inputProfile", "timeoutSeconds", "schedule"], "agent");
    const schedule = object(agent.schedule, "schedule");
    keys(schedule, ["enabled", "everyMinutes"], "schedule");
    if (schedule.enabled !== false) throw new Error("Manifest schedule.enabled must be false; enable schedules explicitly in the website");
    const inputProfile = identifier(agent.inputProfile);
    if (!inputProfiles[inputProfile]) throw new Error(`Unknown input profile: ${inputProfile}`);
    return {
      id: identifier(agent.id), prompt: text(agent.prompt, 240, "prompt"), inputProfile,
      timeoutSeconds: integer(agent.timeoutSeconds, 10, 600, "timeoutSeconds"),
      schedule: { enabled: schedule.enabled, everyMinutes: integer(schedule.everyMinutes, 1, 1440, "everyMinutes") },
    };
  });
  if (!agents.length || new Set(agents.map(a => a.id)).size !== agents.length) throw new Error("Agents must be nonempty and unique");
  const swarms = list(root.swarms, 16, "swarms").map(value => {
    const swarm = object(value, "swarm");
    keys(swarm, ["id", "workers", "synthesisPrompt"], "swarm");
    const workers = list(swarm.workers, 3, "workers").map(identifier);
    if (workers.length < 2 || new Set(workers).size !== workers.length ||
        workers.some(id => !agents.some(a => a.id === id))) throw new Error("Swarm requires 2..3 unique known workers");
    return { id: identifier(swarm.id), workers, synthesisPrompt: text(swarm.synthesisPrompt, 240, "synthesisPrompt") };
  });
  if (new Set(swarms.map(s => s.id)).size !== swarms.length) throw new Error("Duplicate swarm id");
  return { schemaVersion: 1, inputProfiles, agents, swarms };
}
export function loadManifest(root: string): Manifest {
  return parseManifest(JSON.parse(readBounded(scopedFile(root, ".devpilot/fleet.json"), 65536)));
}
function inputFile(root: string, name: string): Packet["files"][number] {
  const parts = name.toLowerCase().split("/");
  if (parts.some(p => p.startsWith(".") && p !== ".github") ||
      /(?:secret|credential|token|private[-_]?key)/i.test(name) ||
      !/\.(?:md|txt|json|ya?ml|ts|tsx|js|mjs|cs|ps1|psm1|psd1|xml|props|csproj|sln|py|go|rs|toml)$/i.test(name)) {
    throw new Error(`Input path is outside the POC source-file policy: ${name}`);
  }
  const content = readBounded(scopedFile(root, name), 65536);
  if (content.includes("\0") || /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/.test(content)) {
    throw new Error(`Input looks binary or contains credential material: ${name}`);
  }
  return { path: name, sha256: hash(content), content };
}
export function prepare(root: string, manifest: Manifest, agent: Agent): Prepared {
  const profile = manifest.inputProfiles[agent.inputProfile];
  if (!profile) throw new Error(`Unknown profile: ${agent.inputProfile}`);
  const files = profile.files.map(name => inputFile(root, name));
  if (files.reduce((sum, file) => sum + Buffer.byteLength(file.content), 0) > 131072) throw new Error("Input packet exceeds 128 KiB");
  const rev = revision(root);
  const packet = { revision: rev, inputHash: hash(JSON.stringify({ revision: rev, files })), files };
  const prompt = readBounded(scopedFile(root, agent.prompt), 16384);
  text(prompt, 16384, "prompt content");
  return { agentId: agent.id, prompt, promptHash: hash(prompt), timeoutSeconds: agent.timeoutSeconds, packet };
}
export function prepareSynthesis(root: string, swarm: Swarm): Prepared {
  const prompt = readBounded(scopedFile(root, swarm.synthesisPrompt), 16384);
  text(prompt, 16384, "synthesis prompt");
  const rev = revision(root);
  return { agentId: `${swarm.id}-synthesis`, prompt, promptHash: hash(prompt), timeoutSeconds: 600,
    packet: { revision: rev, inputHash: hash(rev), files: [] } };
}
export function validateResult(value: unknown, nonce: string, inputHash: string): Result {
  const result = object(value, "result");
  keys(result, ["schemaVersion", "nonce", "inputHash", "summary", "findings"], "result");
  if (result.schemaVersion !== 1) throw new Error("schemaVersion: expected 1");
  if (result.nonce !== nonce) throw new Error("nonce: result binding mismatch");
  if (result.inputHash !== inputHash) throw new Error("inputHash: result binding mismatch");
  const findings = list(result.findings, 8, "findings").map((value, index) => {
    const where = `findings[${index}]`;
    const finding = object(value, where);
    keys(finding, ["title", "evidence", "recommendation"], where);
    return { title: text(finding.title, 200, `${where}.title`), evidence: text(finding.evidence, 1500, `${where}.evidence`),
      recommendation: text(finding.recommendation, 1500, `${where}.recommendation`) };
  });
  return { schemaVersion: 1, nonce, inputHash, summary: text(result.summary, 4000, "summary"), findings };
}
