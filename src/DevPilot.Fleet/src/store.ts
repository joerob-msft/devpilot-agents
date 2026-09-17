import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import path from "node:path";
import type { State } from "./contracts.js";
import { noLinks, object, readBounded, text, validateResult } from "./manifest.js";

export function atomicJson(file: string, value: unknown): void {
  const bytes = JSON.stringify(value);
  if (Buffer.byteLength(bytes) > 40 * 1024 * 1024) throw new Error("Fleet state exceeds 40 MiB; admission stopped");
  const temp = `${file}.${randomBytes(6).toString("hex")}.tmp`;
  const fd = openSync(temp, "wx", 0o600);
  try { writeFileSync(fd, bytes); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(temp, file);
}
export function processExists(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ESRCH") return false;
    throw error;
  }
}
export class Store {
  state: State;
  readonly token = randomBytes(24).toString("hex");
  readonly createdAt = Date.now();
  readonly lockPath: string;
  readonly file: string;
  private closed = false;
  constructor(readonly directory: string, readonly repository: string) {
    noLinks(directory);
    this.lockPath = path.join(directory, "owner.json");
    this.file = path.join(directory, "state.json");
    let fd: number;
    try { fd = openSync(this.lockPath, "wx", 0o600); }
    catch (error) {
      if (error instanceof Error && "code" in error && error.code === "EEXIST") {
        throw new Error("Fleet ownership exists. Stop the other server or use `recover` after it and its workers have exited.");
      }
      throw error;
    }
    try {
      writeFileSync(fd, JSON.stringify({ pid: process.pid, token: this.token, createdAt: this.createdAt }));
      fsyncSync(fd);
    } finally { closeSync(fd); }
    try {
      this.state = existsSync(this.file) ? readState(this.file, repository) : {
        schemaVersion: 1, repository, attempts: [], swarms: [], requests: {}, schedules: {},
      };
      // Restart never replays admitted work or re-enables schedules.
      for (const attempt of this.state.attempts) {
        if (attempt.status === "running" || attempt.status === "queued") {
          attempt.status = "interrupted";
          attempt.error = "Server restarted. No automatic retry; inspect the retained attempt before resubmitting.";
          attempt.endedAt = new Date().toISOString();
        }
      }
      for (const swarm of this.state.swarms) {
        if (swarm.status === "queued" || swarm.status === "running") swarm.status = "interrupted";
      }
      for (const schedule of Object.values(this.state.schedules)) schedule.enabled = false;
      this.save();
    } catch (error) { this.close(); throw error; }
  }
  save(): void {
    if (this.closed) throw new Error("Store is closed");
    atomicJson(this.file, this.state);
  }
  attemptDirectory(id: string): string {
    if (!/^[a-f0-9]{32}$/.test(id)) throw new Error("Invalid attempt id");
    const folder = path.join(this.directory, "runs", id);
    mkdirSync(folder, { recursive: true, mode: 0o700 });
    noLinks(folder);
    return folder;
  }
  close(): void {
    if (this.closed) return;
    this.closed = true;
    const owner = JSON.parse(readFileSync(this.lockPath, "utf8"));
    if (owner.token !== this.token) throw new Error("Cannot release another fleet owner's lock");
    unlinkSync(this.lockPath);
  }
}
function readState(file: string, repository: string): State {
  noLinks(file);
  const value: unknown = JSON.parse(readBounded(file, 40 * 1024 * 1024));
  assertState(value, repository);
  return value;
}
function assertState(input: unknown, repository: string): asserts input is State {
  const value = object(input, "state");
  if (value.schemaVersion !== 1 || value.repository !== repository ||
      !Array.isArray(value.attempts) || value.attempts.length > 200 ||
      !Array.isArray(value.swarms) || value.swarms.length > 100) throw new Error("Invalid or mismatched fleet state");
  const statuses = ["queued", "running", "succeeded", "failed", "cancelled", "timed_out",
    "invalid_result", "interrupted", "unknown", "blocked"];
  const checkId = (value: unknown) => {
    if (typeof value !== "string" || !/^[a-f0-9]{32}$/.test(value)) throw new Error("Invalid persisted ID");
    return value;
  };
  const checkPrepared = (input: unknown) => {
    const prepared = object(input, "prepared");
    text(prepared.agentId, 80, "agentId"); text(prepared.prompt, 16384, "prompt"); text(prepared.promptHash, 64, "promptHash");
    if (typeof prepared.timeoutSeconds !== "number" || !Number.isInteger(prepared.timeoutSeconds) ||
        prepared.timeoutSeconds < 10 || prepared.timeoutSeconds > 600) throw new Error("Invalid persisted deadline");
    const packet = object(prepared.packet, "packet");
    text(packet.revision, 64, "revision");
    if (typeof packet.inputHash !== "string" || !/^[a-f0-9]{64}$/.test(packet.inputHash) ||
        !Array.isArray(packet.files) || packet.files.length > 20) throw new Error("Invalid packet");
    for (const entry of packet.files) {
      const file = object(entry, "packet file");
      text(file.path, 240, "path"); text(file.sha256, 64, "sha256");
      if (typeof file.content !== "string" || Buffer.byteLength(file.content) > 65536) throw new Error("Invalid packet content");
    }
    return packet;
  };
  const ids = new Set<string>();
  for (const entry of value.attempts) {
    const item = object(entry, "attempt");
    const id = checkId(item.id);
    if (ids.has(id)) throw new Error("Duplicate persisted attempt");
    ids.add(id); checkId(item.runId); checkId(item.nonce);
    text(item.agentId, 80, "agentId"); text(item.createdAt, 40, "createdAt");
    if (typeof item.status !== "string" || !statuses.includes(item.status) ||
        !["agent", "worker", "synthesis"].includes(String(item.kind))) throw new Error("Corrupt attempt state");
    const packet = checkPrepared(item.prepared);
    if (item.transportNote !== undefined) text(item.transportNote, 1000, "transportNote");
    if (item.result !== undefined) validateResult(item.result, String(item.nonce), String(packet.inputHash));
    if (item.status === "succeeded" && !item.result) throw new Error("Successful attempt lacks a result");
  }
  for (const entry of value.swarms) {
    const swarm = object(entry, "swarm");
    checkId(swarm.id); text(swarm.recipeId, 48, "recipeId"); text(swarm.requestId, 80, "requestId");
    text(swarm.createdAt, 40, "createdAt"); checkPrepared(swarm.synthesis);
    if (!Array.isArray(swarm.workers) || swarm.workers.length < 2 || swarm.workers.length > 3 ||
        swarm.workers.some(id => !ids.has(checkId(id))) ||
        typeof swarm.status !== "string" || !statuses.includes(swarm.status)) throw new Error("Corrupt swarm state");
    if (swarm.synthesisId !== undefined && !ids.has(checkId(swarm.synthesisId))) throw new Error("Missing synthesis attempt");
  }
  for (const entry of Object.values(object(value.schedules, "schedules"))) {
    const schedule = object(entry, "schedule");
    if (typeof schedule.enabled !== "boolean" || typeof schedule.nextAt !== "number" || !Number.isFinite(schedule.nextAt) ||
        typeof schedule.everyMinutes !== "number" || !Number.isInteger(schedule.everyMinutes) ||
        schedule.everyMinutes < 1 || schedule.everyMinutes > 1440) throw new Error("Corrupt schedule state");
  }
  const requests = object(value.requests, "requests");
  if (Object.keys(requests).length > 200) throw new Error("Too many persisted requests");
  for (const entry of Object.values(requests)) {
    const request = object(entry, "request");
    checkId(request.runId); text(request.target, 80, "target");
  }
}
export function recover(directory: string, repository: string): void {
  noLinks(directory);
  const lock = path.join(directory, "owner.json");
  if (existsSync(lock)) {
    const claim = object(JSON.parse(readBounded(lock, 4096)), "owner");
    if (!Number.isInteger(claim.pid) || Number(claim.pid) <= 0) throw new Error("Invalid owner PID; manual inspection required");
    if (processExists(Number(claim.pid))) throw new Error("Owner PID is still present; recovery refused");
  }
  const state = readState(path.join(directory, "state.json"), repository);
  for (const attempt of state.attempts) {
    const bridge = path.join(directory, "runs", attempt.id, "bridge.json");
    if (existsSync(bridge)) {
      noLinks(bridge);
      const claim = object(JSON.parse(readBounded(bridge, 4096)), "bridge");
      if (!Number.isInteger(claim.pid) || Number(claim.pid) <= 0) throw new Error("Invalid bridge PID");
      if (processExists(Number(claim.pid))) throw new Error(`Attempt ${attempt.id} bridge PID is present; recovery refused`);
    }
    if (attempt.status === "unknown") {
      throw new Error(`Attempt ${attempt.id} has unconfirmed cleanup. Inspect its process tree; do not automatically recover.`);
    }
  }
  if (existsSync(lock)) unlinkSync(lock);
}
