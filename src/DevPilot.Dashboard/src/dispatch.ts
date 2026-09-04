import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { isAbsolute } from "node:path";
import { AGENTS, parseRepositoryIdentity, type AgentRole, type RepositoryIdentityV1 } from "./domain.js";

export const DISPATCH_PROTOCOL_MAX_BYTES = 65_536;

export interface BrokerLaunchDescriptor {
  executablePath: string;
  scriptPath: string;
  descriptorPath: string;
}

export interface PullRequestSnapshotV1 {
  schemaVersion: 1;
  pullRequestId: number;
  sourceCommit: string;
  sourceRef: string;
  targetRef: string;
  active: boolean;
  draft: boolean;
  author: string;
  title: string;
}

export const KNOWN_PROVENANCE = ["operational-default"] as const;
export type CapabilityProvenance = (typeof KNOWN_PROVENANCE)[number];

export interface CapabilitySummary {
  schemaVersion: 1;
  requestId: string;
  operation: "capability-summary";
  role: AgentRole;
  dispatchDraftId: string;
  repositoryIdentity: RepositoryIdentityV1;
  prSnapshot: PullRequestSnapshotV1;
  capabilityPolicyDigest: string;
  prStateFingerprint: string;
  capabilities: string[];
  mandatoryDenies: string[];
  dynamicConstraints: string[];
  // Additive PR1 profile fields -- see Get-AgentHarnessCapabilityDescriptor. delegableAvailable is
  // always empty in this release: no delegation/widening policy exists yet (PR2+ scope).
  absoluteDenies: string[];
  allowedManualCapabilities: string[];
  delegableAvailable: string[];
  provenance: Record<string, CapabilityProvenance>;
}

// Read-only effective-capability-profile inspection (PR1 issue #105): the Settings TUI's dedicated,
// side-effect-free counterpart to CapabilitySummary. The broker's `profile` operation never
// allocates a dispatchDraftId/config snapshot/$drafts entry, so this type intentionally has no
// dispatchDraftId/capabilityPolicyDigest/prStateFingerprint -- none is meaningful without a config
// snapshot to bind it to, and a distinct type is safer here than fake/optional draft identifiers
// that could be mistaken for something dispatch() can actually consume.
export interface CapabilityProfile {
  schemaVersion: 1;
  requestId: string;
  operation: "capability-profile";
  role: AgentRole;
  repositoryIdentity: RepositoryIdentityV1;
  prSnapshot: PullRequestSnapshotV1;
  capabilities: string[];
  mandatoryDenies: string[];
  dynamicConstraints: string[];
  absoluteDenies: string[];
  allowedManualCapabilities: string[];
  delegableAvailable: string[];
  provenance: Record<string, CapabilityProvenance>;
}

export interface DispatchAccepted {
  schemaVersion: 1;
  requestId: string;
  operation: "accepted";
  dispatchId: string;
  repositoryIdentity: RepositoryIdentityV1;
  pullRequestId: number;
  role: AgentRole;
  capabilityPolicyDigest: string;
  prStateFingerprint: string;
  childProcessId: number;
  eventLogPath: string;
}

export interface DispatchRejected {
  schemaVersion: 1;
  requestId: string;
  operation: "rejected";
  code: string;
  detail: string;
}

export interface DispatchTerminal {
  schemaVersion: 1;
  requestId: string;
  operation: "completed" | "cancelled";
  dispatchId: string;
  exitCode?: number;
  result?: string;
  handleReleaseObserved?: boolean;
}

type BrokerResponse =
  | CapabilitySummary
  | CapabilityProfile
  | DispatchAccepted
  | DispatchRejected
  | DispatchTerminal
  | { schemaVersion: 1; requestId: string; operation: "shutdown-complete" };

interface PendingRequest {
  resolve: (response: BrokerResponse) => void;
  reject: (error: Error) => void;
}

export class BrokerRejectionError extends Error {
  constructor(
    readonly code: string,
    readonly detail: string,
  ) {
    super(detail ? `${code}: ${detail}` : code);
    this.name = "BrokerRejectionError";
  }
}

export interface DispatchClientOptions {
  onTerminal?: (event: DispatchTerminal) => void;
  onBrokerFailure?: (message: string) => void;
  onAcceptedEventPath?: (path: string) => void;
}

export interface DispatchBroker {
  describe(repositoryKey: string, pullRequestId: number, role: AgentRole): Promise<CapabilitySummary>;
  profile(repositoryKey: string, pullRequestId: number, role: AgentRole): Promise<CapabilityProfile>;
  dispatch(summary: CapabilitySummary, operatorPrompt: string): Promise<DispatchAccepted>;
  cancel(dispatchId: string): Promise<DispatchTerminal>;
  shutdown(timeoutMilliseconds?: number): Promise<void>;
  subscribeTerminal(listener: (event: DispatchTerminal) => void): () => void;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("broker response must be an object");
  }
  return value as Record<string, unknown>;
}

function stringField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || !value || value.length > 4_096) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value;
}

// Broker-authored role (issue #105): the broker is the sole source of truth for which role a
// capability-summary/capability-profile response describes. Runtime-validated against the same
// known-role list the rest of the dashboard uses -- never client-stamped/overwritten, and a
// mismatch (missing, wrong type, or not a known role) fails closed here rather than trusting the
// wire value silently.
function roleField(record: Record<string, unknown>, name: string): AgentRole {
  const value = record[name];
  if (typeof value !== "string" || !(AGENTS as readonly string[]).includes(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value as AgentRole;
}

// repositoryIdentity/prSnapshot were previously spread straight from the untrusted record with no
// validation at all. repositoryIdentityField reuses domain.ts's canonical, already-bounded
// verified-identity parser (the same one AgentEvent.repositoryIdentity goes through) instead of
// duplicating that validation here.
function repositoryIdentityField(record: Record<string, unknown>, name: string): RepositoryIdentityV1 {
  const identity = parseRepositoryIdentity(record[name], true);
  if (!identity) throw new Error(`broker response ${name} is invalid`);
  return identity;
}

const MAX_PR_SNAPSHOT_TEXT_LENGTH = 4_096;

function boundedPrText(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || value.length > MAX_PR_SNAPSHOT_TEXT_LENGTH) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value;
}

function prSnapshotField(record: Record<string, unknown>, name: string): PullRequestSnapshotV1 {
  const value = record[name];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  const raw = value as Record<string, unknown>;
  if (raw.schemaVersion !== 1) throw new Error(`broker response ${name}.schemaVersion is invalid`);
  const pullRequestId = raw.pullRequestId;
  if (typeof pullRequestId !== "number" || !Number.isSafeInteger(pullRequestId) || pullRequestId <= 0) {
    throw new Error(`broker response ${name}.pullRequestId is invalid`);
  }
  if (typeof raw.active !== "boolean" || typeof raw.draft !== "boolean") {
    throw new Error(`broker response ${name} active/draft flags are invalid`);
  }
  return {
    schemaVersion: 1,
    pullRequestId,
    sourceCommit: boundedPrText(raw, "sourceCommit"),
    sourceRef: boundedPrText(raw, "sourceRef"),
    targetRef: boundedPrText(raw, "targetRef"),
    active: raw.active,
    draft: raw.draft,
    author: boundedPrText(raw, "author"),
    title: boundedPrText(raw, "title"),
  };
}

// Bounds mirror stringField's own per-item cap. The whole line is already bounded by
// DISPATCH_PROTOCOL_MAX_BYTES framing, but validating array shape explicitly here keeps this
// fail-closed independent of that outer framing check, and holds every capability-name array --
// legacy (capabilities/mandatoryDenies/dynamicConstraints) and PR1-additive alike -- to the same
// bounded-string-array contract before any UI code runs .join()/<For> over it.
const MAX_CAPABILITY_ARRAY_ITEMS = 256;
const MAX_CAPABILITY_ITEM_LENGTH = 4_096;

function stringArrayField(record: Record<string, unknown>, name: string): string[] {
  const value = record[name];
  if (
    !Array.isArray(value) ||
    value.length > MAX_CAPABILITY_ARRAY_ITEMS ||
    value.some((item) => typeof item !== "string" || item.length > MAX_CAPABILITY_ITEM_LENGTH)
  ) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value as string[];
}

const MAX_PROVENANCE_ENTRIES = 256;
const MAX_PROVENANCE_KEY_LENGTH = 128;
// Rejected outright rather than merely bounded: these keys shadow/attack object internals if ever
// forwarded into a prototype-carrying object or a lodash-style deep-set elsewhere in the pipeline.
const DANGEROUS_PROVENANCE_KEYS = new Set(["__proto__", "constructor", "prototype"]);

function provenanceField(record: Record<string, unknown>, name: string): Record<string, CapabilityProvenance> {
  const value = record[name];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length > MAX_PROVENANCE_ENTRIES) {
    throw new Error(`broker response ${name} has too many entries`);
  }
  // Object.create(null) has no prototype to hijack, so even a "__proto__" key that somehow slipped
  // past the explicit rejection below would land as a harmless own property instead of reaching
  // Object.prototype.
  const result: Record<string, CapabilityProvenance> = Object.create(null);
  for (const [key, entry] of entries) {
    if (DANGEROUS_PROVENANCE_KEYS.has(key) || key.length > MAX_PROVENANCE_KEY_LENGTH) {
      throw new Error(`broker response ${name} key is invalid`);
    }
    if (typeof entry !== "string" || !(KNOWN_PROVENANCE as readonly string[]).includes(entry)) {
      throw new Error(`broker response ${name}.${key} is invalid`);
    }
    result[key] = entry as CapabilityProvenance;
  }
  return result;
}

// Constructs the PR1 additive profile fields from validated values only -- never spread/cast
// straight from the untrusted parsed record, unlike the rest of parseResponse's envelope fields.
function parseCapabilityProfileFields(record: Record<string, unknown>): Pick<
  CapabilitySummary,
  "absoluteDenies" | "allowedManualCapabilities" | "delegableAvailable" | "provenance"
> {
  const delegableAvailable = stringArrayField(record, "delegableAvailable");
  if (delegableAvailable.length > 0) {
    // No delegation/widening policy exists yet in this release (PR2+ scope) -- a non-empty value
    // here would mean the broker is claiming a capability policy that cannot exist in PR1.
    throw new Error("broker response delegableAvailable must be empty");
  }
  return {
    absoluteDenies: stringArrayField(record, "absoluteDenies"),
    allowedManualCapabilities: stringArrayField(record, "allowedManualCapabilities"),
    delegableAvailable,
    provenance: provenanceField(record, "provenance"),
  };
}

function parseResponse(line: string): BrokerResponse {
  const record = asRecord(JSON.parse(line));
  if (record.schemaVersion !== 1) throw new Error("unsupported broker protocol version");
  const requestId = stringField(record, "requestId");
  const operation = stringField(record, "operation");
  if (!["capability-summary", "capability-profile", "accepted", "rejected", "completed", "cancelled", "shutdown-complete"].includes(operation)) {
    throw new Error("unknown broker response operation");
  }
  if (operation === "capability-summary" || operation === "capability-profile") {
    const shared = {
      // Broker-authored role (issue #105) plus repositoryIdentity/prSnapshot, both of which used to
      // be spread straight from the untrusted record with no validation at all.
      role: roleField(record, "role"),
      repositoryIdentity: repositoryIdentityField(record, "repositoryIdentity"),
      prSnapshot: prSnapshotField(record, "prSnapshot"),
      // Legacy fields predate PR1's stricter parsing and were previously spread straight from the
      // untrusted record; validate them the same bounded-string-array way as the PR1-additive
      // fields so a malformed broker response fails closed here instead of throwing later out of
      // an unguarded UI .join()/<For>.
      capabilities: stringArrayField(record, "capabilities"),
      mandatoryDenies: stringArrayField(record, "mandatoryDenies"),
      dynamicConstraints: stringArrayField(record, "dynamicConstraints"),
      ...parseCapabilityProfileFields(record),
    };
    if (operation === "capability-summary") {
      return { ...record, requestId, operation, ...shared } as CapabilitySummary;
    }
    return { ...record, requestId, operation, ...shared } as CapabilityProfile;
  }
  return { ...record, requestId, operation } as BrokerResponse;
}

function validateLaunch(descriptor: BrokerLaunchDescriptor): void {
  for (const [name, value] of Object.entries(descriptor)) {
    if (!value || !isAbsolute(value) || /[\r\n\u0000]/.test(value)) {
      throw new Error(`${name} must be an absolute trusted path`);
    }
  }
}

function frame(request: Record<string, unknown>): Buffer {
  const bytes = Buffer.from(`${JSON.stringify(request)}\n`, "utf8");
  if (bytes.length > DISPATCH_PROTOCOL_MAX_BYTES) {
    throw new Error("broker request exceeds the 65,536-byte JSONL limit");
  }
  return bytes;
}

export class DispatchClient implements DispatchBroker {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly pending = new Map<string, PendingRequest>();
  private readonly decoder = new TextDecoder("utf-8", { fatal: true });
  private buffered = "";
  private bufferedBytes = 0;
  private closed = false;
  private shutdownPromise: Promise<void> | undefined;
  private readonly terminalListeners = new Set<(event: DispatchTerminal) => void>();

  constructor(
    descriptor: BrokerLaunchDescriptor,
    private readonly options: DispatchClientOptions = {},
  ) {
    validateLaunch(descriptor);
    this.child = spawn(
      descriptor.executablePath,
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-File",
        descriptor.scriptPath,
        "-DescriptorPath",
        descriptor.descriptorPath,
      ],
      {
        shell: false,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    this.child.stdout.on("data", (chunk: Buffer) => this.consume(chunk));
    this.child.stderr.on("data", () => {
      // Broker diagnostics are intentionally not surfaced because they may contain trusted paths.
    });
    this.child.once("error", (error) => this.fail(`broker failed to start: ${error.message}`));
    this.child.once("exit", (code, signal) => {
      if (!this.closed) this.fail(`broker exited unexpectedly (${signal ?? code ?? "unknown"})`);
    });
  }

  describe(repositoryKey: string, pullRequestId: number, role: AgentRole): Promise<CapabilitySummary> {
    return this.request<CapabilitySummary>({
      schemaVersion: 1,
      operation: "describe",
      repositoryKey,
      pullRequestId,
      role,
    }, "capability-summary").then((response) => {
      // The broker's role is authoritative (issue #105) and is never client-stamped/overwritten;
      // a response for a different role than what was requested is rejected rather than trusted.
      if (response.role !== role) {
        throw new Error("broker capability-summary role does not match the requested role");
      }
      return response;
    });
  }

  profile(repositoryKey: string, pullRequestId: number, role: AgentRole): Promise<CapabilityProfile> {
    return this.request<CapabilityProfile>({
      schemaVersion: 1,
      operation: "profile",
      repositoryKey,
      pullRequestId,
      role,
    }, "capability-profile").then((response) => {
      if (response.role !== role) {
        throw new Error("broker capability-profile role does not match the requested role");
      }
      return response;
    });
  }

  dispatch(summary: CapabilitySummary, operatorPrompt: string): Promise<DispatchAccepted> {
    return this.request({
      schemaVersion: 1,
      operation: "dispatch",
      repositoryKey: summary.repositoryIdentity.key,
      pullRequestId: summary.prSnapshot.pullRequestId,
      role: summary.role,
      dispatchDraftId: summary.dispatchDraftId,
      capabilityPolicyDigest: summary.capabilityPolicyDigest,
      prStateFingerprint: summary.prStateFingerprint,
      operatorPrompt,
    }, "accepted");
  }

  cancel(dispatchId: string): Promise<DispatchTerminal> {
    return this.request({
      schemaVersion: 1,
      operation: "cancel",
      dispatchId,
    }, ["cancelled", "completed"]);
  }

  shutdown(timeoutMilliseconds = 12_000): Promise<void> {
    if (this.shutdownPromise) return this.shutdownPromise;
    if (this.closed) return Promise.resolve();
    this.shutdownPromise = (async () => {
      try {
        await Promise.race([
          this.request({ schemaVersion: 1, operation: "shutdown" }, "shutdown-complete"),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error("broker shutdown timed out")), timeoutMilliseconds)),
        ]);
      } finally {
        this.closed = true;
        this.child.stdin.end();
        if (this.child.exitCode === null && this.child.signalCode === null) this.child.kill();
        await Promise.race([
          new Promise<void>((resolve) => {
            if (this.child.exitCode !== null || this.child.signalCode !== null) resolve();
            else this.child.once("exit", () => resolve());
          }),
          new Promise<void>((resolve) => setTimeout(resolve, 2_000)),
        ]);
      }
    })();
    return this.shutdownPromise;
  }

  subscribeTerminal(listener: (event: DispatchTerminal) => void): () => void {
    this.terminalListeners.add(listener);
    return () => this.terminalListeners.delete(listener);
  }

  private request<T>(
    body: Record<string, unknown>,
    expected: string | string[],
  ): Promise<T> {
    if (this.closed) return Promise.reject(new Error("broker is closed"));
    const requestId = randomUUID();
    const bytes = frame({ ...body, requestId });
    return new Promise<T>((resolve, reject) => {
      this.pending.set(requestId, {
        resolve: (response) => {
          if (response.operation === "rejected") {
            reject(new BrokerRejectionError(response.code, response.detail));
          } else if (!(Array.isArray(expected) ? expected.includes(response.operation) : response.operation === expected)) {
            reject(new Error(`unexpected broker response ${response.operation}`));
          } else {
            resolve(response as T);
          }
        },
        reject,
      });
      this.child.stdin.write(bytes, (error) => {
        if (!error) return;
        this.pending.delete(requestId);
        reject(new Error(`broker request failed: ${error.message}`));
      });
    });
  }

  private consume(chunk: Buffer): void {
    this.bufferedBytes += chunk.length;
    if (this.bufferedBytes > DISPATCH_PROTOCOL_MAX_BYTES && !chunk.includes(0x0a)) {
      this.fail("broker emitted an oversized JSONL frame");
      return;
    }
    try {
      this.buffered += this.decoder.decode(chunk, { stream: true });
    } catch {
      this.fail("broker emitted invalid UTF-8");
      return;
    }
    let newline = this.buffered.indexOf("\n");
    while (newline >= 0) {
      const line = this.buffered.slice(0, newline).replace(/\r$/, "");
      this.buffered = this.buffered.slice(newline + 1);
      this.bufferedBytes = Buffer.byteLength(this.buffered, "utf8");
      if (Buffer.byteLength(`${line}\n`, "utf8") > DISPATCH_PROTOCOL_MAX_BYTES) {
        this.fail("broker emitted an oversized JSONL frame");
        return;
      }
      if (line) this.route(line);
      newline = this.buffered.indexOf("\n");
    }
    if (this.bufferedBytes > DISPATCH_PROTOCOL_MAX_BYTES) {
      this.fail("broker emitted an oversized JSONL frame");
    }
  }

  private route(line: string): void {
    let response: BrokerResponse;
    try {
      response = parseResponse(line);
    } catch {
      this.fail("broker emitted an invalid protocol frame");
      return;
    }
    const pending = this.pending.get(response.requestId);
    if (response.operation === "completed" || response.operation === "cancelled") {
      this.options.onTerminal?.(response);
      for (const listener of this.terminalListeners) listener(response);
    }
    if (pending) {
      this.pending.delete(response.requestId);
      pending.resolve(response);
    }
    if (response.operation === "accepted") {
      this.options.onAcceptedEventPath?.(response.eventLogPath);
    }
  }

  private fail(message: string): void {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) pending.reject(new Error(message));
    this.pending.clear();
    this.options.onBrokerFailure?.(message);
  }
}
