import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { isAbsolute } from "node:path";
import type { AgentRole, RepositoryIdentityV1 } from "./domain.js";

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

function parseResponse(line: string): BrokerResponse {
  const record = asRecord(JSON.parse(line));
  if (record.schemaVersion !== 1) throw new Error("unsupported broker protocol version");
  const requestId = stringField(record, "requestId");
  const operation = stringField(record, "operation");
  if (!["capability-summary", "accepted", "rejected", "completed", "cancelled", "shutdown-complete"].includes(operation)) {
    throw new Error("unknown broker response operation");
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
    return this.request<Omit<CapabilitySummary, "role">>({
      schemaVersion: 1,
      operation: "describe",
      repositoryKey,
      pullRequestId,
      role,
    }, "capability-summary").then((response) => ({ ...response, role }));
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
