import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { execFile } from "node:child_process";
import {
  lstat,
  open,
  readFile,
  readdir,
  realpath,
  stat,
} from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const DEFAULT_MAX_FILE_BYTES = 1_048_576;
const DEFAULT_MAX_FILES = 2_000;
const DEFAULT_MAX_HISTORY = 500;
const DEFAULT_MAX_SCAN_MS = 5_000;
const DEFAULT_STALE_MINUTES = 120;
const MAX_TEXT = 512;

type JsonRecord = Record<string, unknown>;

export type ReportingHealth = "healthy" | "degraded" | "disabled" | "stale" | "unknown";
export type FindingState = "wouldCreate" | "wouldUpdate" | "noOp" | "unknown";
export type DeliveryMode = "automatic" | "manual";

export interface ReportingBudgets {
  maxFileBytes: number;
  maxFiles: number;
  maxHistory: number;
  maxScanMilliseconds: number;
}

export interface ReportingConfiguration {
  schemaVersion: 1;
  kind: "devpilot-owner-reporting-config";
  roots: {
    state: string;
    toolkit: string;
    config: string;
    delivery?: string;
    manual?: string;
    runner?: string;
  };
  files: {
    toolkitConfig: string;
    lastRun?: string;
    scheduledLog?: string;
  };
  expectedToolkit?: {
    head: string;
    tree: string;
  };
  azureDevOps?: {
    organizationUrl: string;
    projectId: string;
    projectName: string;
    repositoryId: string;
  };
  scheduledTaskName?: string;
  scheduledTaskPath?: string;
  refreshIntervalSeconds: number;
  staleAfterMinutes: number;
  budgets: ReportingBudgets;
}

export interface TaskHealth {
  available: boolean;
  enabled: boolean | null;
  state: string;
  lastRunUtc: string | null;
  nextRunUtc: string | null;
  lastResult: number | null;
  diagnostic: string;
}

export interface ToolkitHealth {
  expectedHead: string;
  expectedTree: string;
  actualHead: string;
  actualTree: string;
  matches: boolean | null;
  automaticEnabled: boolean | null;
  policyId: string;
  maxCreatesPerRun: number | null;
  maxCreatesPerPullRequest: number | null;
  diagnostic: string;
}

export interface RunSummary {
  runId: string;
  occurredUtc: string;
  health: string;
  durationMilliseconds: number | null;
  attempts: number;
  modelCalls: number | null;
  ownerCompleted: number;
  ownerFailed: number;
  relationCompleted: number;
  relationFailed: number;
  queuePending: number;
  queuePosted: number;
  providerWrites: number;
  modelWrites: number;
  deliveryOutcome: string;
  diagnostic: string;
}

export interface FindingSummary {
  id: string;
  capability: string;
  pullRequestId: number;
  rule: string;
  severity: string;
  state: FindingState;
  path: string;
  line: number;
  symbol: string;
  reason: string;
  sourceCommit: string;
  sourceFreshness: "current" | "stale" | "unknown";
  updatedUtc: string;
  url: string | null;
}

export interface RelationSummary {
  id: string;
  capability: string;
  pullRequestId: number;
  rule: string;
  state: string;
  path: string;
  line: number;
  symbol: string;
  reason: string;
  updatedUtc: string;
  writerEligible: false;
  url: string | null;
}

export interface DeliverySummary {
  id: string;
  mode: DeliveryMode;
  action: string;
  outcome: string;
  occurredUtc: string;
  pullRequestId: number;
  threadId: number | null;
  commentId: number | null;
  prUrl: string | null;
  commentUrl: string | null;
  path: string;
  line: number;
  symbol: string;
  rule: string;
  runId: string;
  eventId: string;
  providerWriteState: string;
  providerWrites: number;
  modelWrites: number;
  body: string | null;
  bodySha256: string;
  bodyStatus: "verified" | "digest-only" | "unavailable";
  diagnostic: string;
}

export interface FailureSummary {
  id: string;
  category:
    | "diagnostic"
    | "ambiguous-write"
    | "invalid-signature"
    | "drift"
    | "stale-head"
    | "task-failure"
    | "recovery-needed"
    | "missing-data";
  occurredUtc: string;
  health: ReportingHealth;
  pullRequestId: number;
  runId: string;
  message: string;
}

export interface QuarantineSummary {
  file: string;
  reason: string;
  occurredUtc: string;
}

export interface OverallServiceHealth {
  status: ReportingHealth;
  lastSuccessfulRunUtc: string | null;
  lastSuccessfulRunAgeMinutes: number | null;
  nextRunUtc: string | null;
  providerWrites: number;
  modelWrites: number;
  reason: string;
}

export interface ReportingSnapshot {
  generatedAtUtc: string;
  dataTimestampUtc: string | null;
  overall: OverallServiceHealth;
  task: TaskHealth;
  toolkit: ToolkitHealth;
  runs: RunSummary[];
  findings: FindingSummary[];
  deliveries: DeliverySummary[];
  failures: FailureSummary[];
  relations: RelationSummary[];
  quarantine: QuarantineSummary[];
  diagnostics: string[];
  truncated: boolean;
}

export interface AzureDevOpsLinkInput {
  organizationUrl: string;
  projectName: string;
  expectedProjectId: string;
  expectedRepositoryId: string;
  projectId: string;
  repositoryId: string;
  pullRequestId: number;
  threadId?: number | null;
  commentId?: number | null;
  path?: string;
  line?: number;
}

export interface ReportingAdapterOptions {
  now?: () => number;
  taskReader?: (taskName: string, taskPath?: string) => Promise<TaskHealth>;
  keyPermissionChecker?: (path: string, root: string) => Promise<boolean>;
}

interface SignedPayload {
  payload: JsonRecord;
  file: string;
}

interface StateObservation {
  identity: string;
  observation: JsonRecord;
  declaration: JsonRecord | null;
  record: JsonRecord | null;
  indexRecord: JsonRecord | null;
  telemetry: JsonRecord | null;
  file: string;
}

interface ScanContext {
  config: ReportingConfiguration;
  guard: RootGuard;
  deadline: number;
  filesRead: number;
  truncated: boolean;
  quarantine: QuarantineSummary[];
  diagnostics: string[];
  keyPermissionChecker: (path: string, root: string) => Promise<boolean>;
}

function asRecord(value: unknown): JsonRecord {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as JsonRecord
    : {};
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function boundedText(value: unknown, max = MAX_TEXT): string {
  return typeof value === "string"
    ? value.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, " ")
      .replace(/\s+/g, " ").trim().slice(0, max)
    : "";
}

function integer(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : fallback;
}

function nullableInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : null;
}

function safeCount(value: unknown): number {
  return Math.max(0, integer(value));
}

function booleanOrNull(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function normalizeTimestamp(value: unknown): string | null {
  const text = boundedText(value, 80);
  if (!text) return null;
  const normalized = /^utc:/i.test(text) ? text.slice(4) :
    /^\d{8}T\d{6}Z$/.test(text)
      ? `${text.slice(0, 4)}-${text.slice(4, 6)}-${text.slice(6, 8)}T${text.slice(9, 11)}:${text.slice(11, 13)}:${text.slice(13, 15)}Z`
      : text;
  const timestamp = Date.parse(normalized);
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null;
}

function latestTimestamp(values: Array<string | null>): string | null {
  return values.filter((value): value is string => value !== null)
    .sort((left, right) => Date.parse(right) - Date.parse(left))[0] ?? null;
}

function digestText(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function digestBytes(value: Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function isHex(value: string, length: number): boolean {
  return new RegExp(`^[0-9a-f]{${length}}$`).test(value);
}

function canonicalJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new Error("canonical JSON accepts only safe integers");
    return String(value);
  }

  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const source = value as JsonRecord;
    return `{${Object.keys(source).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(source[key])}`).join(",")}}`;
  }
  throw new Error(`canonical JSON does not support ${typeof value}`);
}

function assertJsonShape(value: unknown, depth = 0, counter = { nodes: 0 }): void {
  counter.nodes++;
  if (counter.nodes > 20_000) throw new Error("JSON node budget exceeded");
  if (depth > 32) throw new Error("JSON depth budget exceeded");
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    if (typeof value === "string" && value.length > 262_144) throw new Error("JSON string budget exceeded");
    return;
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new Error("JSON numbers must be safe integers");
    return;
  }
  if (Array.isArray(value)) {
    if (value.length > 2_000) throw new Error("JSON array budget exceeded");
    value.forEach((item) => assertJsonShape(item, depth + 1, counter));
    return;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value as JsonRecord);
    if (entries.length > 200) throw new Error("JSON object-key budget exceeded");
    entries.forEach(([key, item]) => {
      if (key.length > 256) throw new Error("JSON key budget exceeded");
      assertJsonShape(item, depth + 1, counter);
    });
    return;
  }
  throw new Error("JSON contains an unsupported value");
}

function exactKeys(value: JsonRecord, keys: string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function ensureAbsolute(value: unknown, name: string): string {
  const text = boundedText(value, 2_048);
  if (!text || !isAbsolute(text)) throw new Error(`${name} must be an absolute path`);
  if (process.platform === "win32" &&
      (/^[\\/]{2}/.test(text) || /^\\\\[?.]\\/.test(text))) {
    throw new Error(`${name} must be a local drive path, not a UNC or device path`);
  }
  return resolve(text);
}

function optionalAbsolute(value: unknown, name: string): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  return ensureAbsolute(value, name);
}

function parseBudgets(value: unknown): ReportingBudgets {
  const raw = asRecord(value);
  const bounded = (name: string, fallback: number, minimum: number, maximum: number): number => {
    const parsed = integer(raw[name], fallback);
    if (parsed < minimum || parsed > maximum) throw new Error(`budgets.${name} is outside the supported range`);
    return parsed;
  };
  return {
    maxFileBytes: bounded("maxFileBytes", DEFAULT_MAX_FILE_BYTES, 1_024, 8_388_608),
    maxFiles: bounded("maxFiles", DEFAULT_MAX_FILES, 10, 10_000),
    maxHistory: bounded("maxHistory", DEFAULT_MAX_HISTORY, 10, 2_000),
    maxScanMilliseconds: bounded("maxScanMilliseconds", DEFAULT_MAX_SCAN_MS, 250, 30_000),
  };
}

export function parseReportingConfiguration(value: unknown): ReportingConfiguration {
  const raw = asRecord(value);
  if (raw.schemaVersion !== 1 || raw.kind !== "devpilot-owner-reporting-config") {
    throw new Error("reporting config has an unsupported schema or kind");
  }
  const roots = asRecord(raw.roots);
  const files = asRecord(raw.files);
  const expected = asRecord(raw.expectedToolkit);
  const azure = asRecord(raw.azureDevOps);
  const refreshIntervalSeconds = integer(raw.refreshIntervalSeconds, 30);
  const staleAfterMinutes = integer(raw.staleAfterMinutes, DEFAULT_STALE_MINUTES);
  if (refreshIntervalSeconds < 5 || refreshIntervalSeconds > 3_600) {
    throw new Error("refreshIntervalSeconds must be in 5..3600");
  }
  if (staleAfterMinutes < 1 || staleAfterMinutes > 43_200) {
    throw new Error("staleAfterMinutes must be in 1..43200");
  }
  const expectedToolkit = Object.keys(expected).length ? {
    head: boundedText(expected.head, 40),
    tree: boundedText(expected.tree, 40),
  } : undefined;
  if (expectedToolkit && (!isHex(expectedToolkit.head, 40) || !isHex(expectedToolkit.tree, 40))) {
    throw new Error("expectedToolkit head and tree must be lowercase 40-character hex");
  }
  const azureDevOps = Object.keys(azure).length ? {
    organizationUrl: boundedText(azure.organizationUrl, 256),
    projectId: boundedText(azure.projectId, 128),
    projectName: boundedText(azure.projectName, 256),
    repositoryId: boundedText(azure.repositoryId, 128),
  } : undefined;
  if (azureDevOps) {
    buildAzureDevOpsLinks({
      ...azureDevOps,
      expectedProjectId: azureDevOps.projectId,
      expectedRepositoryId: azureDevOps.repositoryId,
      pullRequestId: 1,
    });
  }
  const deliveryRoot = optionalAbsolute(roots.delivery, "roots.delivery");
  const manualRoot = optionalAbsolute(roots.manual, "roots.manual");
  const runnerRoot = optionalAbsolute(roots.runner, "roots.runner");
  const lastRun = optionalAbsolute(files.lastRun, "files.lastRun");
  const scheduledLog = optionalAbsolute(files.scheduledLog, "files.scheduledLog");
  const scheduledTaskName = boundedText(raw.scheduledTaskName, 256);
  const scheduledTaskPath = boundedText(raw.scheduledTaskPath, 256);
  if (scheduledTaskName && (
    /[*?\[\]\\/]/.test(scheduledTaskName) ||
    typeof raw.scheduledTaskName === "string" &&
      /[\u0000-\u001f\u007f]/.test(raw.scheduledTaskName)
  )) {
    throw new Error("scheduledTaskName must be an exact task name without wildcards or path separators");
  }
  if (scheduledTaskPath && (!scheduledTaskPath.startsWith("\\") || !scheduledTaskPath.endsWith("\\") ||
      /[\u0000-\u001f\u007f]/.test(scheduledTaskPath))) {
    throw new Error("scheduledTaskPath must be a normalized Task Scheduler path");
  }
  return {
    schemaVersion: 1,
    kind: "devpilot-owner-reporting-config",
    roots: {
      state: ensureAbsolute(roots.state, "roots.state"),
      toolkit: ensureAbsolute(roots.toolkit, "roots.toolkit"),
      config: ensureAbsolute(roots.config, "roots.config"),
      ...(deliveryRoot ? { delivery: deliveryRoot } : {}),
      ...(manualRoot ? { manual: manualRoot } : {}),
      ...(runnerRoot ? { runner: runnerRoot } : {}),
    },
    files: {
      toolkitConfig: ensureAbsolute(files.toolkitConfig, "files.toolkitConfig"),
      ...(lastRun ? { lastRun } : {}),
      ...(scheduledLog ? { scheduledLog } : {}),
    },
    ...(expectedToolkit ? { expectedToolkit } : {}),
    ...(azureDevOps ? { azureDevOps } : {}),
    ...(scheduledTaskName ? { scheduledTaskName } : {}),
    ...(scheduledTaskPath ? { scheduledTaskPath } : {}),
    refreshIntervalSeconds,
    staleAfterMinutes,
    budgets: parseBudgets(raw.budgets),
  };
}

class RootGuard {
  readonly roots: string[];

  constructor(roots: string[]) {
    this.roots = [...new Set(roots.map((root) => resolve(root)))];
  }

  rootFor(path: string): string {
    const full = resolve(path);
    const candidates = this.roots.filter((root) => {
      const child = relative(root, full);
      return child === "" || (!child.startsWith(`..${sep}`) && child !== ".." && !isAbsolute(child));
    }).sort((left, right) => right.length - left.length);
    const root = candidates[0];
    if (!root) throw new Error("path is outside configured roots");
    return root;
  }

  async assertSafe(path: string, expect: "file" | "directory"): Promise<string> {
    const full = resolve(path);
    const root = this.rootFor(full);
    const rootInfo = await lstat(root);
    if (rootInfo.isSymbolicLink()) throw new Error("configured root is a link or reparse point");
    const child = relative(root, full);
    let current = root;
    for (const part of child.split(sep).filter(Boolean)) {
      current = join(current, part);
      const info = await lstat(current);
      if (info.isSymbolicLink()) throw new Error("path contains a link or reparse point");
    }
    const actualRoot = await realpath(root);
    const actual = await realpath(full);
    const realChild = relative(actualRoot, actual);
    if (realChild.startsWith(`..${sep}`) || realChild === ".." || isAbsolute(realChild)) {
      throw new Error("resolved path escaped configured root");
    }
    const info = await stat(full);
    if (expect === "file" && !info.isFile()) throw new Error("path is not a file");
    if (expect === "directory" && !info.isDirectory()) throw new Error("path is not a directory");
    return full;
  }
}

async function readBoundedFile(context: ScanContext, path: string, root: string): Promise<Buffer> {
  if (Date.now() > context.deadline) throw new Error("reporting scan time budget exceeded");
  const full = resolve(path);
  if (context.guard.rootFor(full) !== resolve(root)) throw new Error("path is not under the expected configured root");
  await context.guard.assertSafe(full, "file");
  if (++context.filesRead > context.config.budgets.maxFiles) {
    context.truncated = true;
    throw new Error("reporting file-count budget exceeded");
  }
  const info = await stat(full);
  if (info.size > context.config.budgets.maxFileBytes) throw new Error("file exceeds reporting byte budget");
  return readFile(full);
}

async function readJson(context: ScanContext, path: string, root: string): Promise<JsonRecord> {
  const bytes = await readBoundedFile(context, path, root);
  const value: unknown = JSON.parse(bytes.toString("utf8"));
  assertJsonShape(value);
  return asRecord(value);
}

async function listFiles(
  context: ScanContext,
  root: string,
  start: string,
  predicate: (path: string) => boolean,
): Promise<string[]> {
  const safeStart = await context.guard.assertSafe(start, "directory");
  const result: string[] = [];
  const pending = [safeStart];
  while (pending.length) {
    if (Date.now() > context.deadline) {
      context.truncated = true;
      break;
    }
    const directory = pending.shift()!;
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name, "en"))) {
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        context.quarantine.push({ file: relative(root, path), reason: "link or reparse point rejected", occurredUtc: "" });
        continue;
      }
      if (entry.isDirectory()) pending.push(path);
      else if (entry.isFile() && predicate(path)) {
        result.push(path);
        if (result.length >= context.config.budgets.maxFiles) {
          context.truncated = true;
          return result;
        }
      }
    }
  }
  return result;
}

async function defaultKeyPermissionChecker(
  path: string,
  root: string,
  toolkitRoot: string,
  guard: RootGuard,
): Promise<boolean> {
  if (process.platform !== "win32") {
    const info = await stat(path);
    return (info.mode & 0o077) === 0;
  }
  const harness = join(toolkitRoot, "src", "DevPilot.AgentHarness", "DevPilot.AgentHarness.psd1");
  if (guard.rootFor(harness) !== resolve(toolkitRoot)) return false;
  try {
    await guard.assertSafe(harness, "file");
  } catch {
    return false;
  }
  const script = [
    "$ErrorActionPreference='Stop'",
    "Import-Module -Name $env:DEVPILOT_REPORT_HARNESS -Force",
    "[void](Assert-AgentTrustedFile -Path $env:DEVPILOT_REPORT_KEY -AllowedRoot $env:DEVPILOT_REPORT_ROOT -Private)",
    "'true'",
  ].join(";");
  try {
    const { stdout } = await execFileAsync("pwsh", ["-NoProfile", "-NonInteractive", "-Command", script], {
      env: {
        ...process.env,
        DEVPILOT_REPORT_KEY: path,
        DEVPILOT_REPORT_ROOT: root,
        DEVPILOT_REPORT_HARNESS: harness,
      },
      timeout: 5_000,
      maxBuffer: 8 * 1_024,
      windowsHide: true,
    });
    return stdout.trim().split(/\r?\n/).at(-1) === "true";
  } catch {
    return false;
  }
}

async function assertPrivateKey(path: string, context: ScanContext, root: string): Promise<Buffer> {
  const bytes = await readBoundedFile(context, path, root);
  if (bytes.length !== 32) throw new Error("HMAC key must be exactly 32 bytes");
  if (!await context.keyPermissionChecker(path, root)) {
    throw new Error("HMAC key permissions are not restrictive");
  }
  return bytes;
}

function verifyEnvelope(bytes: Buffer, key: Buffer): JsonRecord {
  const envelopeValue: unknown = JSON.parse(bytes.toString("utf8"));
  assertJsonShape(envelopeValue);
  const envelope = asRecord(envelopeValue);
  if (!exactKeys(envelope, ["schemaVersion", "kind", "signatureAlg", "manifestJson", "signature"]) ||
      envelope.schemaVersion !== 1 || envelope.kind !== "owner-v2-comment-signed-envelope" ||
      envelope.signatureAlg !== "HMACSHA256") {
    throw new Error("unsupported signed envelope");
  }
  const manifestJson = typeof envelope.manifestJson === "string" ? envelope.manifestJson : "";
  const signature = typeof envelope.signature === "string" ? envelope.signature : "";
  if (!isHex(signature, 64)) throw new Error("invalid signature encoding");
  const expected = createHmac("sha256", key).update(manifestJson, "utf8").digest();
  const actual = Buffer.from(signature, "hex");
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new Error("signature verification failed");
  }
  const payload: unknown = JSON.parse(manifestJson);
  assertJsonShape(payload);
  if (canonicalJson(payload) !== manifestJson) throw new Error("manifest JSON is not canonical");
  return asRecord(payload);
}

async function readSignedDirectory(
  context: ScanContext,
  root: string,
  directory: string,
  key: Buffer,
): Promise<SignedPayload[]> {
  try {
    await context.guard.assertSafe(directory, "directory");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      context.diagnostics.push(
        `${relative(root, directory) || "."} unavailable: ${
          boundedText(error instanceof Error ? error.message : String(error), 180)}`,
      );
    }
    return [];
  }
  const files = await listFiles(context, root, directory, (path) => path.toLowerCase().endsWith(".json"));
  const payloads: SignedPayload[] = [];
  for (const file of files) {
    try {
      const bytes = await readBoundedFile(context, file, root);
      payloads.push({ payload: verifyEnvelope(bytes, key), file });
    } catch (error) {
      context.quarantine.push({
        file: relative(root, file),
        reason: boundedText(error instanceof Error ? error.message : String(error), 240),
        occurredUtc: "",
      });
    }
  }
  return payloads;
}

function parseTaskJson(value: unknown): TaskHealth {
  const raw = asRecord(value);
  return {
    available: raw.available === true,
    enabled: booleanOrNull(raw.enabled),
    state: boundedText(raw.state, 80) || "unknown",
    lastRunUtc: normalizeTimestamp(raw.lastRunUtc),
    nextRunUtc: normalizeTimestamp(raw.nextRunUtc),
    lastResult: nullableInteger(raw.lastResult),
    diagnostic: boundedText(raw.diagnostic, 240),
  };
}

export async function readWindowsScheduledTask(taskName: string, taskPath?: string): Promise<TaskHealth> {
  if (process.platform !== "win32") {
    return {
      available: false, enabled: null, state: "unsupported",
      lastRunUtc: null, nextRunUtc: null, lastResult: null,
      diagnostic: "Windows Scheduled Tasks are unavailable on this platform.",
    };
  }
  const script = [
    "$ErrorActionPreference='Stop'",
    "$tasks=@(Get-ScheduledTask -TaskName $env:DEVPILOT_REPORT_TASK -ErrorAction Stop)",
    "if($env:DEVPILOT_REPORT_TASK_PATH){$tasks=@($tasks | Where-Object TaskPath -CEQ $env:DEVPILOT_REPORT_TASK_PATH)}",
    "if($tasks.Count -ne 1){throw 'Configured scheduled task identity is missing or ambiguous.'}",
    "$task=$tasks[0]",
    "$info=Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop",
    "[ordered]@{available=$true;enabled=([string]$task.State -ne 'Disabled');state=[string]$task.State;",
    "lastRunUtc=$(if($info.LastRunTime -gt [datetime]::MinValue){$info.LastRunTime.ToUniversalTime().ToString('o')}else{$null});",
    "nextRunUtc=$(if($info.NextRunTime -gt [datetime]::MinValue){$info.NextRunTime.ToUniversalTime().ToString('o')}else{$null});",
    "lastResult=[int]$info.LastTaskResult;diagnostic=''} | ConvertTo-Json -Compress",
  ].join(";");
  try {
    const { stdout } = await execFileAsync("pwsh", ["-NoProfile", "-NonInteractive", "-Command", script], {
      env: {
        ...process.env,
        DEVPILOT_REPORT_TASK: taskName,
        DEVPILOT_REPORT_TASK_PATH: taskPath ?? "",
      },
      timeout: 5_000,
      maxBuffer: 64 * 1_024,
      windowsHide: true,
    });
    const value: unknown = JSON.parse(stdout);
    assertJsonShape(value);
    return parseTaskJson(value);
  } catch (error) {
    return {
      available: false, enabled: null, state: "unavailable",
      lastRunUtc: null, nextRunUtc: null, lastResult: null,
      diagnostic: boundedText(error instanceof Error ? error.message : String(error), 240),
    };
  }
}

function validateOpaqueId(value: string, name: string): string {
  if (!value || value.length > 128 || !/^[A-Za-z0-9._-]+$/.test(value)) {
    throw new Error(`${name} is malformed`);
  }
  return value;
}

function validateOrganizationUrl(value: string): URL {
  const parsed = new URL(value);
  if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error("Azure DevOps organization URL is malformed");
  }
  const host = parsed.hostname.toLowerCase();
  if (host !== "dev.azure.com" && !host.endsWith(".visualstudio.com")) {
    throw new Error("Azure DevOps organization host is unsupported");
  }
  if (host === "dev.azure.com" && parsed.pathname.split("/").filter(Boolean).length !== 1) {
    throw new Error("dev.azure.com organization URL must contain exactly one organization segment");
  }
  if (host.endsWith(".visualstudio.com") && parsed.pathname !== "/" && parsed.pathname !== "") {
    throw new Error("visualstudio.com organization URL cannot contain a path");
  }
  parsed.pathname = parsed.pathname.replace(/\/+$/, "");
  return parsed;
}

export function buildAzureDevOpsLinks(input: AzureDevOpsLinkInput): { prUrl: string; commentUrl: string | null } {
  const organization = validateOrganizationUrl(input.organizationUrl);
  const projectId = validateOpaqueId(input.projectId, "projectId");
  const repositoryId = validateOpaqueId(input.repositoryId, "repositoryId");
  if (projectId !== validateOpaqueId(input.expectedProjectId, "expectedProjectId") ||
      repositoryId !== validateOpaqueId(input.expectedRepositoryId, "expectedRepositoryId")) {
    throw new Error("Azure DevOps identity is foreign");
  }
  if (!Number.isSafeInteger(input.pullRequestId) || input.pullRequestId < 1) {
    throw new Error("pullRequestId is malformed");
  }
  const projectName = boundedText(input.projectName, 256);
  if (!projectName || /[\u0000-\u001f\u007f]/.test(projectName)) throw new Error("projectName is malformed");
  const base = `${organization.toString().replace(/\/$/, "")}/${encodeURIComponent(projectName)}` +
    `/_git/${encodeURIComponent(repositoryId)}/pullrequest/${input.pullRequestId}`;
  const pr = new URL(base);
  pr.searchParams.set("_a", "files");
  const threadId = input.threadId ?? null;
  const commentId = input.commentId ?? null;
  if (threadId !== null && (!Number.isSafeInteger(threadId) || threadId < 1)) throw new Error("threadId is malformed");
  if (commentId !== null && (!Number.isSafeInteger(commentId) || commentId < 1)) throw new Error("commentId is malformed");
  if (threadId === null) return { prUrl: pr.toString(), commentUrl: null };
  const comment = new URL(pr);
  comment.searchParams.set("discussionId", String(threadId));
  if (commentId !== null) comment.searchParams.set("commentId", String(commentId));
  const path = boundedText(input.path, 1_024);
  if (path) {
    if (path.startsWith("/") || path.includes("..") || path.includes("\\") || /[\u0000-\u001f\u007f]/.test(path)) {
      throw new Error("file path is malformed");
    }
    comment.searchParams.set("path", `/${path}`);
    if (input.line !== undefined) {
      if (!Number.isSafeInteger(input.line) || input.line < 1) throw new Error("line is malformed");
      comment.searchParams.set("line", String(input.line));
      comment.searchParams.set("lineEnd", String(input.line));
    }
  }
  return { prUrl: pr.toString(), commentUrl: comment.toString() };
}

function requiredCount(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${name} must be a non-negative safe integer`);
  }
  return value;
}

function requiredTimestamp(value: unknown, name: string): string {
  const timestamp = normalizeTimestamp(value);
  if (!timestamp) throw new Error(`${name} must be a valid timestamp`);
  return timestamp;
}

function requiredRunId(value: unknown, name: string): string {
  const id = boundedText(value, 128);
  if (!id || !/^[A-Za-z0-9._-]+$/.test(id)) throw new Error(`${name} is invalid`);
  return id;
}

function requiredHealth(value: unknown, name: string): string {
  const health = boundedText(value, 40);
  if (!["healthy", "partial", "refused", "disabled"].includes(health)) {
    throw new Error(`${name} is unsupported`);
  }
  return health;
}

function parseRecordCounts(value: unknown, name: string): {
  completed: number;
  failed: number;
  attempts: number;
} {
  const records = asArray(value).map(asRecord);
  let completed = 0;
  let failed = 0;
  let attempts = 0;
  for (const [index, record] of records.entries()) {
    const state = boundedText(record.state, 40);
    if (!["pending", "running", "completed", "incomplete", "unknown"].includes(state)) {
      throw new Error(`${name}[${index}].state is unsupported`);
    }
    attempts += requiredCount(record.attempts, `${name}[${index}].attempts`);
    if (state === "completed") completed++;
    else failed++;
  }
  return { completed, failed, attempts };
}

function parseCompositeScheduledRun(raw: JsonRecord): RunSummary {
  const completedUtc = requiredTimestamp(raw.completedUtc, "completedUtc");
  const toolkitHead = boundedText(raw.toolkitHead, 40);
  const toolkitTree = boundedText(raw.toolkitTree, 40);
  if (!isHex(toolkitHead, 40) || !isHex(toolkitTree, 40)) {
    throw new Error("scheduled run toolkit identity is invalid");
  }
  const owner = parseRecordCounts(raw.records, "records");
  const relation = parseRecordCounts(raw.relationRecords, "relationRecords");
  const operatorOutput = asRecord(raw.ownerOperatorOutput);
  const reconciliation = asRecord(operatorOutput.reconciliation);
  const delivery = asRecord(raw.ownerAutoDelivery);
  if (delivery.schemaVersion !== 1 || delivery.kind !== "owner-v2-automatic-delivery-result") {
    throw new Error("scheduled run automatic delivery result is unsupported");
  }
  const overallOutcome = boundedText(raw.overallOutcome, 40);
  if (!["success", "partial", "failure"].includes(overallOutcome)) {
    throw new Error("scheduled run overallOutcome is unsupported");
  }
  const deliveryHealth = requiredHealth(delivery.health, "ownerAutoDelivery.health");
  if (overallOutcome === "success" && owner.failed + relation.failed > 0) {
    throw new Error("successful scheduled run contains incomplete Owner or relation records");
  }
  requiredCount(reconciliation.wouldCreate, "reconciliation.wouldCreate");
  requiredCount(reconciliation.wouldUpdate, "reconciliation.wouldUpdate");
  const unknown = requiredCount(reconciliation.unknown, "reconciliation.unknown");
  const pending = requiredCount(delivery.remainingWouldCreate, "ownerAutoDelivery.remainingWouldCreate");
  const posted = requiredCount(reconciliation.noOp, "reconciliation.noOp") +
    requiredCount(reconciliation.created, "reconciliation.created") +
    requiredCount(reconciliation.updated, "reconciliation.updated");
  const incomplete = owner.failed + relation.failed > 0 || unknown > 0 || overallOutcome !== "success";
  const health = incomplete && deliveryHealth === "healthy"
    ? overallOutcome === "failure" ? "refused" : "partial"
    : incomplete && deliveryHealth === "disabled" ? "partial"
      : deliveryHealth;
  return {
    runId: requiredRunId(delivery.runId, "ownerAutoDelivery.runId"),
    occurredUtc: completedUtc,
    health,
    durationMilliseconds: null,
    attempts: owner.attempts + relation.attempts,
    modelCalls: null,
    ownerCompleted: owner.completed,
    ownerFailed: owner.failed,
    relationCompleted: relation.completed,
    relationFailed: relation.failed,
    queuePending: pending,
    queuePosted: posted,
    providerWrites: requiredCount(delivery.providerWrites, "ownerAutoDelivery.providerWrites"),
    modelWrites: requiredCount(delivery.modelWrites, "ownerAutoDelivery.modelWrites"),
    deliveryOutcome: deliveryHealth,
    diagnostic: "Model-call count is unavailable in owner-relation-v2-preview-scheduled-run v1.",
  };
}

function parseReportingRunProjection(raw: JsonRecord): RunSummary {
  const owner = asRecord(raw.owner);
  const relation = asRecord(raw.relation);
  const queue = asRecord(raw.queue);
  return {
    runId: requiredRunId(raw.runId, "runId"),
    occurredUtc: requiredTimestamp(raw.completedUtc, "completedUtc"),
    health: requiredHealth(raw.health, "health"),
    durationMilliseconds: nullableInteger(raw.durationMilliseconds),
    attempts: requiredCount(raw.attempts, "attempts"),
    modelCalls: requiredCount(raw.modelCalls, "modelCalls"),
    ownerCompleted: requiredCount(owner.completed, "owner.completed"),
    ownerFailed: requiredCount(owner.failed, "owner.failed"),
    relationCompleted: requiredCount(relation.completed, "relation.completed"),
    relationFailed: requiredCount(relation.failed, "relation.failed"),
    queuePending: requiredCount(queue.pending, "queue.pending"),
    queuePosted: requiredCount(queue.posted, "queue.posted"),
    providerWrites: requiredCount(raw.providerWrites, "providerWrites"),
    modelWrites: requiredCount(raw.modelWrites, "modelWrites"),
    deliveryOutcome: requiredHealth(raw.deliveryOutcome, "deliveryOutcome"),
    diagnostic: boundedText(raw.diagnostic, 240),
  };
}

function parseRun(value: unknown): RunSummary {
  const raw = asRecord(value);
  if (raw.schemaVersion !== 1) throw new Error("run schemaVersion is unsupported");
  if (raw.kind === "owner-relation-v2-preview-scheduled-run") return parseCompositeScheduledRun(raw);
  if (raw.kind === "devpilot-owner-reporting-run-projection") return parseReportingRunProjection(raw);
  throw new Error("run kind is unsupported");
}

async function readRunHistory(context: ScanContext): Promise<RunSummary[]> {
  const runs: RunSummary[] = [];
  const runnerRoot = context.config.roots.runner;
  const lastRun = context.config.files.lastRun;
  if (lastRun && runnerRoot) {
    try {
      runs.push(parseRun(await readJson(context, lastRun, runnerRoot)));
    } catch (error) {
      context.diagnostics.push(`last-run unavailable: ${boundedText(error instanceof Error ? error.message : String(error), 180)}`);
    }
  }
  const log = context.config.files.scheduledLog;
  if (log && runnerRoot) {
    try {
      const text = (await readBoundedFile(context, log, runnerRoot)).toString("utf8");
      const lines = text.split(/\r?\n/).filter(Boolean).slice(-context.config.budgets.maxHistory);
      lines.forEach((line, index) => {
        try {
          const value: unknown = JSON.parse(line);
          assertJsonShape(value);
          runs.push(parseRun(value));
        } catch {
          context.quarantine.push({ file: relative(runnerRoot, log), reason: `scheduled log line ${index + 1} is invalid`, occurredUtc: "" });
        }
      });
    } catch (error) {
      context.diagnostics.push(`scheduled log unavailable: ${boundedText(error instanceof Error ? error.message : String(error), 180)}`);
    }
  }
  const deduplicated = new Map<string, RunSummary>();
  for (const run of runs) {
    const key = `${run.runId}|${run.occurredUtc}`;
    deduplicated.set(key, run);
  }
  return [...deduplicated.values()]
    .sort((left, right) => Date.parse(right.occurredUtc || "1970-01-01") - Date.parse(left.occurredUtc || "1970-01-01") ||
      left.runId.localeCompare(right.runId))
    .slice(0, context.config.budgets.maxHistory);
}

async function readStateObservations(context: ScanContext): Promise<StateObservation[]> {
  const root = context.config.roots.state;
  let files: string[] = [];
  try {
    files = await listFiles(context, root, root, (path) =>
      path.toLowerCase().endsWith(".json") &&
      path.split(/[\\/]/).at(-2)?.toLowerCase() === "observations");
  } catch (error) {
    context.diagnostics.push(`state root unavailable: ${boundedText(error instanceof Error ? error.message : String(error), 180)}`);
    return [];
  }
  const observations: StateObservation[] = [];
  const indexCache = new Map<string, JsonRecord | null>();
  for (const file of files) {
    const identity = file.split(/[\\/]/).at(-1)?.replace(/\.json$/i, "") ?? "";
    if (!isHex(identity, 64)) continue;
    try {
      const observation = await readJson(context, file, root);
      const capabilityRoot = dirname(dirname(file));
      const declarationPath = join(capabilityRoot, "declarations", `${identity}.json`);
      const recordPath = join(capabilityRoot, "records", `${identity}.json`);
      const telemetryPath = join(capabilityRoot, "telemetry", `${identity}.json`);
      const indexPath = join(capabilityRoot, "index", "records.json");
      let declaration: JsonRecord | null = null;
      let record: JsonRecord | null = null;
      let telemetry: JsonRecord | null = null;
      let indexRecord: JsonRecord | null = null;
      try { declaration = await readJson(context, declarationPath, root); } catch { /* explicit in projection */ }
      try { record = await readJson(context, recordPath, root); } catch { /* explicit in projection */ }
      try { telemetry = await readJson(context, telemetryPath, root); } catch { /* optional for pre-model states */ }
      try {
        let index: JsonRecord | null;
        if (indexCache.has(indexPath)) {
          index = indexCache.get(indexPath) ?? null;
        } else {
          try {
            index = await readJson(context, indexPath, root);
          } catch (error) {
            index = null;
            if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
              context.quarantine.push({
                file: relative(root, indexPath),
                reason: boundedText(error instanceof Error ? error.message : String(error), 240),
                occurredUtc: "",
              });
            }
          }
          indexCache.set(indexPath, index);
        }
        indexRecord = asArray(index?.records).map(asRecord)
          .find((candidate) => boundedText(candidate.identity, 64) === identity) ?? null;
      } catch { /* missing or malformed index leaves index consistency unavailable */ }
      observations.push({ identity, observation, declaration, record, indexRecord, telemetry, file });
    } catch (error) {
      context.quarantine.push({
        file: relative(root, file),
        reason: boundedText(error instanceof Error ? error.message : String(error), 240),
        occurredUtc: "",
      });
    }
  }
  return observations;
}

function findingAnchor(finding: JsonRecord): { path: string; line: number; symbol: string } {
  const anchor = asRecord(finding.anchor);
  return {
    path: boundedText(anchor.path ?? finding.path, 1_024),
    line: safeCount(anchor.line ?? finding.line),
    symbol: boundedText(anchor.symbol ?? finding.symbol, 256),
  };
}

function observationTimestamp(state: StateObservation): string {
  return normalizeTimestamp(state.record?.updatedUtc ?? state.observation.updatedUtc ??
    asRecord(state.observation.lifecycle).completedUtc) ?? "";
}

function projectState(
  observations: StateObservation[],
  latestHeads: Map<number, string>,
  config: ReportingConfiguration,
): { findings: FindingSummary[]; relations: RelationSummary[]; failures: FailureSummary[] } {
  const findings: FindingSummary[] = [];
  const relations: RelationSummary[] = [];
  const failures: FailureSummary[] = [];
  for (const state of observations) {
    const observation = state.observation;
    const kind = boundedText(observation.kind, 80);
    const subject = asRecord(observation.subject);
    const rule = asRecord(observation.rule);
    const capabilityValue = observation.capability;
    const capability = typeof capabilityValue === "string" ? boundedText(capabilityValue, 160) :
      boundedText(asRecord(capabilityValue).id, 160);
    const pullRequestId = safeCount(subject.pullRequestId);
    const sourceCommit = boundedText(subject.headCommit ?? subject.sourceCommit, 40);
    const updatedUtc = observationTimestamp(state);
    const lifecycle = asRecord(observation.lifecycle);
    const recordState = boundedText(state.record?.state, 40);
    const indexState = boundedText(state.indexRecord?.state, 40);
    if (!state.declaration || !state.record) {
      failures.push({
        id: `state-binding-missing:${state.identity}`, category: "missing-data",
        occurredUtc: updatedUtc, health: "degraded", pullRequestId, runId: "",
        message: `Durable ${!state.declaration && !state.record ? "declaration and record are" :
          !state.declaration ? "declaration is" : "record is"} unavailable for this observation.`,
      });
    }
    if (recordState && indexState && recordState !== indexState) {
      failures.push({
        id: `index-drift:${state.identity}`, category: "drift",
        occurredUtc: updatedUtc, health: "degraded", pullRequestId, runId: "",
        message: "Owner record and durable index state do not match.",
      });
    }
    if (recordState && recordState !== "completed") {
      failures.push({
        id: `state:${state.identity}`, category: recordState === "unknown" ? "diagnostic" : "recovery-needed",
        occurredUtc: updatedUtc, health: "degraded", pullRequestId, runId: "",
        message: boundedText(state.record?.incompleteReason ?? lifecycle.status ?? "Owner state is incomplete.", 240),
      });
    }
    if (kind === "relation-evidence-observation") {
      for (const item of asArray(observation.findings)) {
        const finding = asRecord(item);
        const anchor = findingAnchor(finding);
        const links = safeLinks(
          config,
          boundedText(subject.projectId, 128),
          boundedText(subject.repositoryId, 128),
          pullRequestId,
          null,
          null,
          anchor.path,
          anchor.line,
        );
        relations.push({
          id: boundedText(finding.identity ?? finding.findingId, 160) || `relation:${state.identity}:${relations.length}`,
          capability, pullRequestId,
          rule: boundedText(rule.id ?? rule.section ?? rule.path, 256),
          state: boundedText(finding.state ?? finding.disposition, 80) || "unknown",
          ...anchor,
          reason: boundedText(finding.reason ?? finding.explanation, 240),
          updatedUtc,
          writerEligible: false,
          url: links.prUrl,
        });
      }
      continue;
    }
    if (kind !== "owner-observation") continue;
    for (const item of asArray(observation.findings)) {
      const finding = asRecord(item);
      const reconciliation = asRecord(finding.reconciliation);
      const classification = boundedText(reconciliation.classification, 40);
      const stateValue: FindingState = classification === "wouldCreate" || classification === "wouldUpdate" ||
        classification === "noOp" ? classification : "unknown";
      const anchor = findingAnchor(finding);
      const latest = latestHeads.get(pullRequestId);
      const prLinks = safeLinks(
        config,
        boundedText(subject.projectId, 128),
        boundedText(subject.repositoryId, 128),
        pullRequestId,
        null,
        null,
        anchor.path,
        anchor.line,
      );
      const thread = asRecord(reconciliation.thread);
      const threadId = nullableInteger(thread.threadId);
      const commentId = nullableInteger(thread.commentId);
      const authoritativePostedThread = stateValue === "noOp" &&
        isHex(boundedText(reconciliation.bodySha256, 64), 64) &&
        boundedText(thread.availability, 40) === "available" &&
        boundedText(thread.status, 40) === "active" &&
        threadId !== null &&
        commentId !== null;
      const commentLinks = authoritativePostedThread
        ? safeLinks(
            config,
            boundedText(subject.projectId, 128),
            boundedText(subject.repositoryId, 128),
            pullRequestId,
            threadId,
            commentId,
            anchor.path,
            anchor.line,
          )
        : null;
      findings.push({
        id: boundedText(finding.identity ?? finding.findingId, 160) || `owner:${state.identity}:${findings.length}`,
        capability, pullRequestId,
        rule: boundedText(rule.id ?? rule.section ?? rule.path, 256),
        severity: boundedText(finding.severity ?? finding.disposition, 80) || "unknown",
        state: stateValue,
        ...anchor,
        reason: boundedText(reconciliation.reason ?? finding.reason, 240),
        sourceCommit,
        sourceFreshness: !latest || !sourceCommit ? "unknown" : latest === sourceCommit ? "current" : "stale",
        updatedUtc,
        url: commentLinks?.commentUrl ?? prLinks.prUrl,
      });
      if (stateValue === "unknown") {
        failures.push({
          id: `finding:${state.identity}:${findings.length}`, category: "diagnostic",
          occurredUtc: updatedUtc, health: "degraded", pullRequestId, runId: "",
          message: boundedText(reconciliation.reason, 240) || "Finding reconciliation is unknown.",
        });
      }
    }
  }
  findings.sort((left, right) => Date.parse(right.updatedUtc || "1970-01-01") - Date.parse(left.updatedUtc || "1970-01-01") ||
    left.pullRequestId - right.pullRequestId || left.id.localeCompare(right.id));
  relations.sort((left, right) => Date.parse(right.updatedUtc || "1970-01-01") - Date.parse(left.updatedUtc || "1970-01-01") ||
    left.pullRequestId - right.pullRequestId || left.id.localeCompare(right.id));
  return { findings, relations, failures };
}

function toolkitProjection(
  toolkitConfig: JsonRecord | null,
  expected: ReportingConfiguration["expectedToolkit"],
  policy: JsonRecord | null,
  diagnostic: string,
): ToolkitHealth {
  const toolkit = asRecord(toolkitConfig?.toolkit);
  const automatic = toolkitConfig ? toolkitConfig.autoCreateOwnerComments : undefined;
  const policyLimits = asRecord(policy?.limits);
  const actualHead = boundedText(toolkit.head, 40);
  const actualTree = boundedText(toolkit.tree, 40);
  const expectedHead = expected?.head ?? "";
  const expectedTree = expected?.tree ?? "";
  const matches = expected
    ? actualHead === expectedHead && actualTree === expectedTree
    : actualHead && actualTree ? null : false;
  return {
    expectedHead, expectedTree, actualHead, actualTree, matches,
    automaticEnabled: automatic === false || automatic === undefined ? false :
      asRecord(automatic).enabled === true ? true : null,
    policyId: boundedText(policy?.policyId, 128),
    maxCreatesPerRun: nullableInteger(policyLimits.maxCreatesPerRun),
    maxCreatesPerPullRequest: nullableInteger(policyLimits.maxCreatesPerPullRequest),
    diagnostic,
  };
}

function findObservationFinding(
  observations: Map<string, StateObservation>,
  identity: string,
  findingId: string,
): JsonRecord | null {
  const observation = observations.get(identity)?.observation;
  if (!observation) return null;
  for (const item of asArray(observation.findings)) {
    const finding = asRecord(item);
    if (boundedText(finding.identity ?? finding.findingId, 160) === findingId) return finding;
  }
  return null;
}

function selectionMatchesEvent(selection: JsonRecord, event: JsonRecord): boolean {
  const finding = asRecord(event.finding);
  return boundedText(selection.findingId, 160) === boundedText(finding.findingId, 160) &&
    boundedText(selection.marker, 64) === boundedText(finding.marker, 64) &&
    boundedText(selection.path, 1_024) === boundedText(finding.path, 1_024) &&
    safeCount(selection.line) === safeCount(finding.line) &&
    boundedText(selection.symbol, 256) === boundedText(finding.symbol, 256);
}

async function formatterDigest(context: ScanContext): Promise<string> {
  const path = join(context.config.roots.toolkit, "src", "DevPilot.OwnerCapability", "DevPilot.OwnerCapability.psm1");
  try {
    return digestBytes(await readBoundedFile(context, path, context.config.roots.toolkit));
  } catch {
    return "";
  }
}

function deriveBody(
  event: JsonRecord,
  intent: JsonRecord | undefined,
  observations: Map<string, StateObservation>,
  toolkit: ToolkitHealth,
  localFormatterDigest: string,
): { body: string | null; digest: string; status: DeliverySummary["bodyStatus"] } {
  if (!intent || intent.kind !== "owner-v2-service-create-intent") {
    return { body: null, digest: "", status: "unavailable" };
  }
  const finding = asRecord(event.finding);
  const identity = boundedText(finding.stateIdentity, 64);
  const selection = asArray(intent.selections).map(asRecord).find((candidate) => selectionMatchesEvent(candidate, event));
  if (!selection) return { body: null, digest: "", status: "unavailable" };
  const hasBody = typeof selection.body === "string" && selection.body.length > 0;
  const body = hasBody ? selection.body as string : "";
  const bodySha256 = boundedText(selection.bodySha256, 64);
  const implementation = asRecord(intent.implementation);
  const implementationHead = boundedText(implementation.toolkitHead, 40);
  const implementationTree = boundedText(implementation.toolkitTree, 40);
  const implementationFormatter = boundedText(implementation.formatterSha256, 64);
  const observationFinding = findObservationFinding(observations, identity, boundedText(finding.findingId, 160));
  const observedDigest = boundedText(asRecord(observationFinding?.reconciliation).bodySha256, 64);
  const bindingsMatch = hasBody &&
    isHex(bodySha256, 64) && digestText(body) === bodySha256 &&
    observedDigest === bodySha256 &&
    isHex(toolkit.actualHead, 40) && implementationHead === toolkit.actualHead &&
    isHex(toolkit.actualTree, 40) && implementationTree === toolkit.actualTree &&
    isHex(localFormatterDigest, 64) && implementationFormatter === localFormatterDigest;
  return bindingsMatch
    ? { body, digest: bodySha256, status: "verified" }
    : { body: null, digest: bodySha256 || observedDigest, status: bodySha256 || observedDigest ? "digest-only" : "unavailable" };
}

function safeLinks(
  config: ReportingConfiguration,
  projectId: string,
  repositoryId: string,
  pullRequestId: number,
  threadId: number | null,
  commentId: number | null,
  path: string,
  line: number,
): { prUrl: string | null; commentUrl: string | null; diagnostic: string } {
  if (!config.azureDevOps) return { prUrl: null, commentUrl: null, diagnostic: "Azure DevOps link identity is not configured." };
  try {
    const links = buildAzureDevOpsLinks({
      organizationUrl: config.azureDevOps.organizationUrl,
      projectName: config.azureDevOps.projectName,
      expectedProjectId: config.azureDevOps.projectId,
      expectedRepositoryId: config.azureDevOps.repositoryId,
      projectId,
      repositoryId,
      pullRequestId,
      threadId,
      commentId,
      path,
      line,
    });
    return { ...links, diagnostic: "" };
  } catch (error) {
    return { prUrl: null, commentUrl: null, diagnostic: boundedText(error instanceof Error ? error.message : String(error), 180) };
  }
}

function eventOccurred(event: JsonRecord): string {
  return normalizeTimestamp(event.occurredUtc ?? event.createdUtc) ?? "";
}

function automaticDeliveries(
  events: SignedPayload[],
  intents: SignedPayload[],
  observations: Map<string, StateObservation>,
  toolkit: ToolkitHealth,
  localFormatterDigest: string,
  config: ReportingConfiguration,
): { deliveries: DeliverySummary[]; failures: FailureSummary[]; latestHeads: Map<number, string> } {
  const deliveries: DeliverySummary[] = [];
  const failures: FailureSummary[] = [];
  const latestHeads = new Map<number, { timestamp: number; commit: string }>();
  const intentByRun = new Map(intents
    .filter(({ payload }) => payload.kind === "owner-v2-service-create-intent")
    .map(({ payload }) => [boundedText(payload.runId, 128), payload]));
  const grouped = new Map<string, SignedPayload[]>();
  for (const event of events) {
    const id = boundedText(event.payload.eventId, 128);
    if (!grouped.has(id)) grouped.set(id, []);
    grouped.get(id)!.push(event);
  }
  for (const [eventId, group] of grouped) {
    if (!eventId || group.length !== 1) continue;
    const event = group[0]!.payload;
    if (event.schemaVersion !== 1 || event.kind !== "owner-v2-delivery-event") continue;
    const subject = asRecord(event.subject);
    const finding = asRecord(event.finding);
    const pullRequestId = safeCount(subject.pullRequestId);
    const runId = boundedText(event.runId, 128);
    const occurredUtc = eventOccurred(event);
    const sourceCommit = boundedText(subject.sourceCommit, 40);
    const previous = latestHeads.get(pullRequestId);
    if (sourceCommit && (!previous || Date.parse(occurredUtc || "1970-01-01") > previous.timestamp)) {
      latestHeads.set(pullRequestId, { timestamp: Date.parse(occurredUtc || "1970-01-01"), commit: sourceCommit });
    }
    const path = boundedText(finding.path, 1_024);
    const line = safeCount(finding.line);
    const threadId = nullableInteger(event.threadId);
    const commentId = nullableInteger(event.commentId);
    const links = safeLinks(config, boundedText(subject.projectId, 128), boundedText(subject.repositoryId, 128),
      pullRequestId, threadId, commentId, path, line);
    const derived = deriveBody(event, intentByRun.get(runId), observations, toolkit, localFormatterDigest);
    const eventDiagnostic = asRecord(event.diagnostic);
    const diagnostic = boundedText(eventDiagnostic.message, 240) || links.diagnostic;
    const diagnosticCode = boundedText(eventDiagnostic.code, 80);
    const outcome = boundedText(event.outcome, 120) || "unknown";
    deliveries.push({
      id: `automatic:${eventId}`, mode: "automatic",
      action: boundedText(event.action, 80) || "unknown", outcome, occurredUtc, pullRequestId,
      threadId, commentId, prUrl: links.prUrl, commentUrl: links.commentUrl,
      path, line, symbol: boundedText(finding.symbol, 256), rule: "",
      runId, eventId,
      providerWriteState: boundedText(event.providerWriteState, 80) || "unknown",
      providerWrites: safeCount(event.providerWriteCount),
      modelWrites: safeCount(event.modelWriteCount),
      body: derived.body, bodySha256: derived.digest, bodyStatus: derived.status,
      diagnostic,
    });
    if (outcome === "ambiguous-post-write" || boundedText(event.providerWriteState, 80) === "unknown") {
      failures.push({
        id: `ambiguous:${eventId}`, category: "ambiguous-write", occurredUtc, health: "degraded",
        pullRequestId, runId, message: diagnostic || "Provider write state is ambiguous.",
      });
    } else if (outcome === "refused") {
      failures.push({
        id: `refused:${eventId}`,
        category: /stale.*head|head.*stale/.test(diagnosticCode) ? "stale-head" : "drift",
        occurredUtc, health: "degraded",
        pullRequestId, runId, message: diagnostic || "Automatic delivery was refused.",
      });
    } else if (outcome === "operator-review-required") {
      failures.push({
        id: `recovery:${eventId}`, category: "recovery-needed", occurredUtc, health: "degraded",
        pullRequestId, runId, message: diagnostic || "Operator review is required.",
      });
    }
  }
  return {
    deliveries,
    failures,
    latestHeads: new Map([...latestHeads].map(([pr, value]) => [pr, value.commit])),
  };
}

function manualDeliveries(
  intents: SignedPayload[],
  outcomes: SignedPayload[],
  observations: Map<string, StateObservation>,
  config: ReportingConfiguration,
): { deliveries: DeliverySummary[]; failures: FailureSummary[] } {
  const deliveries: DeliverySummary[] = [];
  const failures: FailureSummary[] = [];
  const intentByInvocation = new Map(intents
    .filter(({ payload }) => payload.kind === "owner-v2-comment-intent")
    .map(({ payload }) => [boundedText(payload.invocationId, 128), payload]));
  for (const { payload: outcome } of outcomes.filter(({ payload }) => payload.kind === "owner-v2-comment-outcome")) {
    const invocationId = boundedText(outcome.invocationId, 128);
    const intent = intentByInvocation.get(invocationId);
    const identity = boundedText(outcome.stateIdentity ?? intent?.stateIdentity, 64);
    const state = observations.get(identity);
    const subject = asRecord(state?.observation.subject);
    const declarationSubject = asRecord(state?.declaration?.subject);
    const pullRequestId = safeCount(subject.pullRequestId ?? declarationSubject.pullRequestId);
    const projectId = boundedText(subject.projectId ?? declarationSubject.projectId, 128);
    const repositoryId = boundedText(subject.repositoryId ?? declarationSubject.repositoryId, 128);
    const occurredUtc = eventOccurred(outcome);
    const results = asArray(outcome.results).map(asRecord);
    const selections = asArray(intent?.selections).map(asRecord);
    const rows = results.length ? results : selections.map((selection) => ({
      findingId: selection.findingId,
      outcome: intent?.publish === true ? "unknown" : "dryRun",
      marker: selection.marker,
      bodySha256: selection.bodySha256,
      providerWrites: 0,
    }));
    rows.forEach((result, index) => {
      const findingId = boundedText(result.findingId, 160);
      const selection = selections.find((candidate) => boundedText(candidate.findingId, 160) === findingId);
      const observed = findObservationFinding(observations, identity, findingId);
      const anchor = selection ? {
        path: boundedText(selection.path, 1_024),
        line: safeCount(selection.line),
        symbol: boundedText(selection.symbol, 256),
      } : findingAnchor(observed ?? {});
      const reconciliation = asRecord(observed?.reconciliation);
      const writeOutcome = boundedText(result.outcome ?? outcome.status, 120) || "unknown";
      const linkEligible = intent?.publish === true &&
        boundedText(outcome.status, 80) === "completed" &&
        safeCount(result.providerWrites) > 0 &&
        ["created", "updated"].includes(writeOutcome);
      const thread = asRecord(reconciliation.thread);
      const nestedThreadId = nullableInteger(thread.threadId);
      const nestedCommentId = nullableInteger(thread.commentId);
      const flatThreadId = nullableInteger(reconciliation.threadId);
      const flatCommentId = nullableInteger(reconciliation.commentId);
      const nestedPresent = Object.keys(thread).length > 0;
      const flatPresent = reconciliation.threadId !== undefined || reconciliation.commentId !== undefined;
      let threadId: number | null = null;
      let commentId: number | null = null;
      let linkBindingDiagnostic = "";
      if (linkEligible) {
        const observedAnchor = findingAnchor(observed ?? {});
        const selectionDigest = boundedText(selection?.bodySha256, 64);
        const resultDigest = boundedText(result.bodySha256, 64);
        const observedDigest = boundedText(reconciliation.bodySha256, 64);
        const selectionMarker = boundedText(selection?.marker, 64);
        const resultMarker = boundedText(result.marker, 64);
        const anchorMatches = Boolean(selection) &&
          anchor.path === observedAnchor.path &&
          anchor.line === observedAnchor.line &&
          anchor.symbol === observedAnchor.symbol;
        if (!selection || !observed || !anchorMatches ||
            !isHex(selectionDigest, 64) || !isHex(resultDigest, 64) ||
            selectionDigest !== resultDigest || selectionDigest !== observedDigest ||
            !isHex(selectionMarker, 64) || selectionMarker !== resultMarker) {
          linkBindingDiagnostic = "Manual comment link binding is incomplete or mismatched.";
        } else if (nestedPresent) {
          if (boundedText(thread.availability, 40) !== "available" ||
              nestedThreadId === null || nestedCommentId === null) {
            linkBindingDiagnostic = "Manual comment nested thread identity is unavailable or malformed.";
          } else if (flatPresent && (flatThreadId !== nestedThreadId || flatCommentId !== nestedCommentId)) {
            linkBindingDiagnostic = "Manual comment thread identity is ambiguous across nested and legacy fields.";
          } else {
            threadId = nestedThreadId;
            commentId = nestedCommentId;
          }
        } else if (flatPresent) {
          if (flatThreadId === null || flatCommentId === null) {
            linkBindingDiagnostic = "Legacy manual comment thread identity is incomplete.";
          } else {
            threadId = flatThreadId;
            commentId = flatCommentId;
          }
        } else {
          linkBindingDiagnostic = "Manual comment thread identity is unavailable.";
        }
      }
      const links = safeLinks(config, projectId, repositoryId, pullRequestId, threadId, commentId, anchor.path, anchor.line);
      const body = typeof selection?.body === "string" ? selection.body : "";
      const digest = boundedText(selection?.bodySha256 ?? result.bodySha256, 64);
      const bodyVerified = body && isHex(digest, 64) && digestText(body) === digest;
      deliveries.push({
        id: `manual:${invocationId}:${index}`, mode: "manual",
        action: intent?.publish === true ? "publish" : "preview",
        outcome: writeOutcome,
        occurredUtc, pullRequestId, threadId, commentId,
        prUrl: links.prUrl, commentUrl: links.commentUrl,
        ...anchor,
        rule: boundedText(asRecord(state?.observation.rule).id ?? asRecord(state?.declaration?.rule).section, 256),
        runId: invocationId, eventId: "",
        providerWriteState: outcome.providerWrites === "unknown" ? "unknown" :
          safeCount(result.providerWrites) > 0 ? "confirmed" : "none",
        providerWrites: safeCount(result.providerWrites),
        modelWrites: 0,
        body: bodyVerified ? body : null,
        bodySha256: digest,
        bodyStatus: bodyVerified ? "verified" : digest ? "digest-only" : "unavailable",
        diagnostic: boundedText(outcome.diagnostic, 240) || linkBindingDiagnostic || links.diagnostic,
      });
    });
    if (boundedText(outcome.status, 80) === "failed" || outcome.providerWrites === "unknown") {
      failures.push({
        id: `manual-failure:${invocationId}`,
        category: outcome.providerWrites === "unknown" ? "ambiguous-write" : "diagnostic",
        occurredUtc, health: "degraded", pullRequestId, runId: invocationId,
        message: boundedText(outcome.diagnostic, 240) || "Manual delivery did not complete cleanly.",
      });
    }
  }
  return { deliveries, failures };
}

function quarantineFailures(quarantine: QuarantineSummary[]): FailureSummary[] {
  return quarantine.map((item, index) => ({
    id: `quarantine:${index}:${item.file}`,
    category: "invalid-signature",
    occurredUtc: item.occurredUtc,
    health: "degraded",
    pullRequestId: 0,
    runId: "",
    message: `${boundedText(item.file, 120)}: ${boundedText(item.reason, 180)}`,
  }));
}

function deduplicateSignedPayloads(
  payloads: SignedPayload[],
  root: string,
  label: string,
  id: (payload: JsonRecord) => string,
  context: ScanContext,
): SignedPayload[] {
  const grouped = new Map<string, SignedPayload[]>();
  for (const item of payloads) {
    const identity = id(item.payload) || "(missing)";
    if (!grouped.has(identity)) grouped.set(identity, []);
    grouped.get(identity)!.push(item);
  }
  return [...grouped.entries()].flatMap(([identity, group]) => {
    if (identity !== "(missing)" && group.length === 1) return group;
    for (const item of group) {
      context.quarantine.push({
        file: relative(root, item.file),
        reason: identity === "(missing)" ? `${label} has no identity` : `duplicate ${label} identity '${identity}'`,
        occurredUtc: eventOccurred(item.payload),
      });
    }
    return [];
  });
}

function overallHealth(
  task: TaskHealth,
  toolkit: ToolkitHealth,
  runs: RunSummary[],
  deliveries: DeliverySummary[],
  failures: FailureSummary[],
  now: number,
  staleAfterMinutes: number,
): OverallServiceHealth {
  const successful = runs.filter((run) => run.health === "healthy")
    .sort((left, right) => Date.parse(right.occurredUtc || "1970-01-01") - Date.parse(left.occurredUtc || "1970-01-01"))[0];
  const lastSuccessfulRunUtc = successful?.occurredUtc || null;
  const ageMinutes = lastSuccessfulRunUtc ? Math.max(0, Math.floor((now - Date.parse(lastSuccessfulRunUtc)) / 60_000)) : null;
  const providerWrites = deliveries.reduce((sum, row) => sum + row.providerWrites, 0);
  const modelWrites = deliveries.reduce((sum, row) => sum + row.modelWrites, 0);
  if (toolkit.automaticEnabled === false || task.enabled === false) {
    return {
      status: "disabled", lastSuccessfulRunUtc, lastSuccessfulRunAgeMinutes: ageMinutes,
      nextRunUtc: task.nextRunUtc, providerWrites, modelWrites,
      reason: toolkit.automaticEnabled === false ? "Automatic Owner delivery is disabled by policy." : "Scheduled task is disabled.",
    };
  }
  if (failures.length || toolkit.matches === false || task.lastResult !== null && task.lastResult !== 0) {
    return {
      status: "degraded", lastSuccessfulRunUtc, lastSuccessfulRunAgeMinutes: ageMinutes,
      nextRunUtc: task.nextRunUtc, providerWrites, modelWrites,
      reason: failures[0]?.message || toolkit.diagnostic || "Scheduled task reported a failure.",
    };
  }
  if (ageMinutes === null || ageMinutes > staleAfterMinutes) {
    return {
      status: "stale", lastSuccessfulRunUtc, lastSuccessfulRunAgeMinutes: ageMinutes,
      nextRunUtc: task.nextRunUtc, providerWrites, modelWrites,
      reason: ageMinutes === null ? "No successful scheduled run is available." : "The last successful run is stale.",
    };
  }
  if (!task.available || toolkit.automaticEnabled === null) {
    return {
      status: "unknown", lastSuccessfulRunUtc, lastSuccessfulRunAgeMinutes: ageMinutes,
      nextRunUtc: task.nextRunUtc, providerWrites, modelWrites,
      reason: task.diagnostic || toolkit.diagnostic || "Service state is incomplete.",
    };
  }
  return {
    status: "healthy", lastSuccessfulRunUtc, lastSuccessfulRunAgeMinutes: ageMinutes,
    nextRunUtc: task.nextRunUtc, providerWrites, modelWrites,
    reason: "Scheduled task, policy, signed delivery feed, and recent runs are healthy.",
  };
}

function emptyTask(diagnostic: string): TaskHealth {
  return {
    available: false, enabled: null, state: "unavailable",
    lastRunUtc: null, nextRunUtc: null, lastResult: null, diagnostic,
  };
}

export class LocalReportingAdapter {
  readonly configPath: string;
  private readonly options: ReportingAdapterOptions;
  private cachedRefreshIntervalMs = 30_000;

  constructor(configPath: string, options: ReportingAdapterOptions = {}) {
    this.configPath = resolve(configPath);
    this.options = options;
  }

  get refreshIntervalMilliseconds(): number {
    return this.cachedRefreshIntervalMs;
  }

  async read(): Promise<ReportingSnapshot> {
    const now = this.options.now?.() ?? Date.now();
    const configInfo = await lstat(this.configPath);
    if (!configInfo.isFile() || configInfo.isSymbolicLink()) {
      throw new Error("reporting config must be a regular file, not a link or reparse point");
    }
    if (configInfo.size > DEFAULT_MAX_FILE_BYTES) throw new Error("reporting config exceeds the byte budget");
    const configValue: unknown = JSON.parse(await readFile(this.configPath, "utf8"));
    assertJsonShape(configValue);
    const config = parseReportingConfiguration(configValue);
    this.cachedRefreshIntervalMs = config.refreshIntervalSeconds * 1_000;
    const roots = Object.values(config.roots).filter((value): value is string => Boolean(value));
    const guard = new RootGuard(roots);
    const context: ScanContext = {
      config,
      guard,
      deadline: Date.now() + config.budgets.maxScanMilliseconds,
      filesRead: 0,
      truncated: false,
      quarantine: [],
      diagnostics: [],
      keyPermissionChecker: this.options.keyPermissionChecker ??
        ((path, root) => defaultKeyPermissionChecker(path, root, config.roots.toolkit, guard)),
    };
    const taskReader = this.options.taskReader ?? readWindowsScheduledTask;
    const task = config.scheduledTaskName
      ? await taskReader(config.scheduledTaskName, config.scheduledTaskPath)
      : emptyTask("Scheduled task name is not configured.");

    let toolkitConfig: JsonRecord | null = null;
    let toolkitDiagnostic = "";
    try {
      toolkitConfig = await readJson(context, config.files.toolkitConfig, config.roots.config);
    } catch (error) {
      toolkitDiagnostic = boundedText(error instanceof Error ? error.message : String(error), 240);
    }

    const observations = await readStateObservations(context);
    const observationMap = new Map(observations.map((state) => [state.identity, state]));
    const runs = await readRunHistory(context);
    let policy: JsonRecord | null = null;
    let automaticEvents: SignedPayload[] = [];
    let automaticIntents: SignedPayload[] = [];
    let manualIntents: SignedPayload[] = [];
    let manualOutcomes: SignedPayload[] = [];

    if (config.roots.delivery) {
      const root = config.roots.delivery;
      try {
        const key = await assertPrivateKey(join(root, "keys", "owner-v2-service-authorization.hmac"), context, root);
        automaticEvents = await readSignedDirectory(context, root, join(root, "events"), key);
        automaticIntents = await readSignedDirectory(context, root, join(root, "intents"), key);
        const automatic = asRecord(toolkitConfig?.autoCreateOwnerComments);
        const policyPath = boundedText(automatic.policyPath, 2_048);
        if (policyPath) {
          try {
            const bytes = await readBoundedFile(context, policyPath, root);
            const configuredDigest = boundedText(automatic.policySha256, 64);
            if (configuredDigest && digestBytes(bytes) !== configuredDigest) throw new Error("policy digest does not match toolkit config");
            policy = verifyEnvelope(bytes, key);
          } catch (error) {
            toolkitDiagnostic = boundedText(error instanceof Error ? error.message : String(error), 240);
          }
        }
      } catch (error) {
        context.diagnostics.push(`automatic delivery feed unavailable: ${boundedText(error instanceof Error ? error.message : String(error), 180)}`);
      }
    }
    if (config.roots.manual) {
      const root = config.roots.manual;
      try {
        const key = await assertPrivateKey(join(root, "keys", "owner-v2-comment-approval.hmac"), context, root);
        manualIntents = await readSignedDirectory(context, root, join(root, "intents"), key);
        manualOutcomes = await readSignedDirectory(context, root, join(root, "outcomes"), key);
      } catch (error) {
        context.diagnostics.push(`manual audit feed unavailable: ${boundedText(error instanceof Error ? error.message : String(error), 180)}`);
      }
    }

    if (config.roots.delivery) {
      automaticEvents = deduplicateSignedPayloads(
        automaticEvents, config.roots.delivery, "delivery eventId",
        (payload) => boundedText(payload.eventId, 128), context,
      );
      automaticIntents = deduplicateSignedPayloads(
        automaticIntents, config.roots.delivery, "automatic runId",
        (payload) => boundedText(payload.runId, 128), context,
      );
    }
    if (config.roots.manual) {
      manualIntents = deduplicateSignedPayloads(
        manualIntents, config.roots.manual, "manual intent invocationId",
        (payload) => boundedText(payload.invocationId, 128), context,
      );
      manualOutcomes = deduplicateSignedPayloads(
        manualOutcomes, config.roots.manual, "manual outcome invocationId",
        (payload) => boundedText(payload.invocationId, 128), context,
      );
    }
    const toolkit = toolkitProjection(toolkitConfig, config.expectedToolkit, policy, toolkitDiagnostic);
    const localFormatterDigest = await formatterDigest(context);
    const automatic = automaticDeliveries(
      automaticEvents, automaticIntents, observationMap, toolkit, localFormatterDigest, config,
    );
    const projected = projectState(observations, automatic.latestHeads, config);
    const manual = manualDeliveries(manualIntents, manualOutcomes, observationMap, config);
    const deliveries = [...automatic.deliveries, ...manual.deliveries]
      .sort((left, right) => Date.parse(right.occurredUtc || "1970-01-01") - Date.parse(left.occurredUtc || "1970-01-01") ||
        left.id.localeCompare(right.id))
      .slice(0, config.budgets.maxHistory);
    const failures = [
      ...projected.failures,
      ...automatic.failures,
      ...manual.failures,
      ...quarantineFailures(context.quarantine),
      ...context.diagnostics.map((message, index): FailureSummary => ({
        id: `missing-data:${index}`,
        category: "missing-data",
        occurredUtc: "",
        health: "degraded",
        pullRequestId: 0,
        runId: "",
        message,
      })),
    ].sort((left, right) => Date.parse(right.occurredUtc || "1970-01-01") - Date.parse(left.occurredUtc || "1970-01-01") ||
      left.id.localeCompare(right.id)).slice(0, config.budgets.maxHistory);
    if (toolkit.matches === false) {
      failures.unshift({
        id: "toolkit-drift", category: "drift", occurredUtc: "",
        health: "degraded", pullRequestId: 0, runId: "",
        message: "Configured toolkit head/tree does not match the expected deployment identity.",
      });
    }
    if (task.lastResult !== null && task.lastResult !== 0) {
      failures.unshift({
        id: "scheduled-task-failure", category: "task-failure", occurredUtc: task.lastRunUtc ?? "",
        health: "degraded", pullRequestId: 0, runId: "",
        message: `Scheduled task last result was ${task.lastResult}.`,
      });
    }
    const overall = overallHealth(task, toolkit, runs, deliveries, failures, now, config.staleAfterMinutes);
    const dataTimestampUtc = latestTimestamp([
      task.lastRunUtc,
      ...runs.map((run) => run.occurredUtc || null),
      ...projected.findings.map((finding) => finding.updatedUtc || null),
      ...projected.relations.map((relation) => relation.updatedUtc || null),
      ...deliveries.map((delivery) => delivery.occurredUtc || null),
    ]);
    return {
      generatedAtUtc: new Date(now).toISOString(),
      dataTimestampUtc,
      overall,
      task,
      toolkit,
      runs,
      findings: projected.findings.slice(0, config.budgets.maxHistory),
      deliveries,
      failures,
      relations: projected.relations.slice(0, config.budgets.maxHistory),
      quarantine: context.quarantine.slice(0, config.budgets.maxHistory),
      diagnostics: context.diagnostics.slice(0, 50),
      truncated: context.truncated,
    };
  }
}
