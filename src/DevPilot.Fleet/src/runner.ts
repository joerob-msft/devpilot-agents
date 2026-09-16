import { EventEmitter } from "node:events";
import { randomBytes } from "node:crypto";
import type { Attempt, Execution, Executor, Manifest, Prepared, SwarmRun } from "./contracts.js";
import { terminal } from "./contracts.js";
import { hash, loadManifest, prepare, prepareSynthesis, readBounded, revision, scopedFile, validateResult } from "./manifest.js";
import { atomicJson, Store } from "./store.js";
import path from "node:path";
import { readRejectedAnswer } from "./result-diagnostics.js";

const id = () => randomBytes(16).toString("hex");
const now = () => new Date().toISOString();
export class Fleet extends EventEmitter {
  manifest: Manifest;
  readonly active = new Map<string, Execution>();
  fatal: string | undefined;
  closing = false;
  private timer: NodeJS.Timeout | undefined;
  constructor(readonly store: Store, private executor: Executor) {
    super();
    this.manifest = loadManifest(store.repository);
    this.syncSchedules();
  }
  private syncSchedules(): void {
    const previous = this.store.state.schedules;
    this.store.state.schedules = Object.fromEntries(this.manifest.agents.map(a => [a.id, {
      enabled: previous[a.id]?.enabled ?? false,
      everyMinutes: a.schedule.everyMinutes,
      nextAt: previous[a.id]?.nextAt ?? Date.now() + a.schedule.everyMinutes * 60000,
    }]));
    this.commit();
  }
  private commit(): void {
    try { this.store.save(); }
    catch (error) {
      this.fatal = `Persistence failure; admission stopped: ${error instanceof Error ? error.message : String(error)}`;
      for (const execution of this.active.values()) execution.cancel();
      this.emit("changed");
      throw error;
    }
    this.emit("changed");
  }
  private assertAdmission(count = 1): void {
    if (this.fatal || this.closing) throw new Error(this.fatal ?? "Fleet is shutting down");
    if (this.store.state.attempts.some(a => a.status === "unknown")) throw new Error("Unconfirmed cleanup blocks admission");
    const reserved = this.store.state.swarms.filter(s => !terminal(s.status) && !s.synthesisId).length;
    if (this.store.state.attempts.length + reserved + count > 200) throw new Error("POC retained-attempt limit (200) reached. Admission stopped; archive state offline.");
    if (Object.keys(this.store.state.requests).length >= 200) throw new Error("POC request limit reached");
  }
  reload(): void {
    this.assertAdmission(0);
    if (this.active.size || this.store.state.attempts.some(a => !terminal(a.status))) throw new Error("Wait for admitted work before reloading definitions");
    const manifest = loadManifest(this.store.repository);
    // Validate all assets before replacing the live catalog.
    for (const agent of manifest.agents) prepare(this.store.repository, manifest, agent);
    for (const swarm of manifest.swarms) prepareSynthesis(this.store.repository, swarm);
    this.manifest = manifest;
    this.syncSchedules();
  }
  preview(agentId: string): Prepared {
    const agent = this.manifest.agents.find(a => a.id === agentId);
    if (!agent) throw new Error("Unknown agent");
    return prepare(this.store.repository, this.manifest, agent);
  }
  rejectedAnswer(attemptId: string) {
    if (!/^[a-f0-9]{32}$/.test(attemptId)) throw new Error("Invalid attempt id");
    const attempt = this.store.state.attempts.find(a => a.id === attemptId);
    if (!attempt || attempt.status !== "invalid_result") throw new Error("Only a known rejected attempt has a rejected-answer view");
    return {
      attemptId, status: attempt.status, originalError: attempt.error,
      ...readRejectedAnswer(path.join(this.store.directory, "runs", attempt.id), attempt.nonce, attempt.prepared.packet.inputHash),
    };
  }
  private available(agentId: string): void {
    if (this.store.state.attempts.some(a => a.agentId === agentId && (!terminal(a.status) || a.status === "unknown"))) {
      throw new Error(`Agent ${agentId} already has admitted work`);
    }
  }
  private existing(requestId: string, target: string): string | undefined {
    if (!/^[a-zA-Z0-9_-]{16,80}$/.test(requestId)) throw new Error("Invalid request id");
    const previous = this.store.state.requests[requestId];
    if (previous && previous.target !== target) throw new Error("Request id was already bound to another target");
    return previous?.runId;
  }
  private attempt(prepared: Prepared, runId: string, kind: Attempt["kind"]): Attempt {
    return { id: id(), runId, kind, agentId: prepared.agentId, nonce: id(), status: "queued", createdAt: now(), prepared };
  }
  runAgent(agentId: string, requestId: string): string {
    const existing = this.existing(requestId, `agent:${agentId}`);
    if (existing) return existing;
    this.assertAdmission();
    this.available(agentId);
    const runId = id();
    const attempt = this.attempt(this.preview(agentId), runId, "agent");
    this.store.state.attempts.push(attempt);
    this.store.state.requests[requestId] = { target: `agent:${agentId}`, runId };
    this.commit();
    this.pump();
    return runId;
  }
  runSwarm(recipeId: string, requestId: string): string {
    const existing = this.existing(requestId, `swarm:${recipeId}`);
    if (existing) return existing;
    const recipe = this.manifest.swarms.find(s => s.id === recipeId);
    if (!recipe) throw new Error("Unknown swarm");
    this.assertAdmission(recipe.workers.length + 1);
    for (const worker of recipe.workers) this.available(worker);
    const prepared = recipe.workers.map(worker => this.preview(worker));
    const synthesis = prepareSynthesis(this.store.repository, recipe);
    if (prepared.some(p => p.packet.revision !== synthesis.packet.revision)) throw new Error("Repository revision changed while preparing swarm inputs");
    const sharedFiles = new Map<string, string>();
    for (const worker of prepared) {
      for (const file of worker.packet.files) {
        const previous = sharedFiles.get(file.path);
        if (previous && previous !== file.sha256) throw new Error("Shared input changed while preparing swarm");
        sharedFiles.set(file.path, file.sha256);
      }
    }
    const runId = id();
    const attempts = prepared.map(p => this.attempt(p, runId, "worker"));
    const swarm: SwarmRun = { id: runId, recipeId, requestId, workers: attempts.map(a => a.id),
      synthesis, status: "queued", createdAt: now() };
    this.store.state.attempts.push(...attempts);
    this.store.state.swarms.push(swarm);
    this.store.state.requests[requestId] = { target: `swarm:${recipeId}`, runId };
    this.commit();
    this.pump();
    return runId;
  }
  cancel(runId: string): void {
    const attempts = this.store.state.attempts.filter(a => a.runId === runId);
    if (!attempts.length) throw new Error("Unknown run");
    const swarm = this.store.state.swarms.find(s => s.id === runId);
    if (swarm) swarm.cancelRequested = true;
    for (const attempt of attempts) {
      if (terminal(attempt.status)) continue;
      attempt.cancelRequested = true;
      if (attempt.status === "queued") { attempt.status = "cancelled"; attempt.endedAt = now(); }
    }
    this.commit();
    for (const attempt of attempts) this.active.get(attempt.id)?.cancel();
    this.advanceSwarms();
  }
  schedule(agentId: string, enabled: boolean): void {
    this.assertAdmission(0);
    if (!Object.hasOwn(this.store.state.schedules, agentId)) throw new Error("Unknown agent");
    const schedule = this.store.state.schedules[agentId]!;
    schedule.enabled = enabled;
    schedule.nextAt = Date.now() + schedule.everyMinutes * 60000;
    this.commit();
  }
  tick(time = Date.now()): void {
    if (this.fatal || this.closing) return;
    for (const [agentId, schedule] of Object.entries(this.store.state.schedules)) {
      if (!schedule.enabled || schedule.nextAt > time) continue;
      schedule.nextAt = time + schedule.everyMinutes * 60000;
      this.commit();
      if (this.store.state.attempts.some(a => a.agentId === agentId && !terminal(a.status))) continue;
      try { this.runAgent(agentId, id()); }
      catch (error) {
        schedule.enabled = false;
        this.emit("diagnostic", `Schedule ${agentId} disabled: ${error instanceof Error ? error.message : String(error)}`);
        this.commit();
      }
    }
  }
  start(): void {
    this.timer = setInterval(() => {
      try { this.tick(); } catch (error) { this.fatal = String(error); this.emit("changed"); }
    }, 1000);
  }
  private pump(): void {
    if (this.fatal || this.closing || this.store.state.attempts.some(a => a.status === "unknown")) return;
    while (this.active.size < 2) {
      const attempt = this.store.state.attempts.find(a => a.status === "queued");
      if (!attempt) break;
      attempt.status = "running";
      attempt.startedAt = now();
      const swarm = this.store.state.swarms.find(s => s.id === attempt.runId);
      if (swarm) swarm.status = "running";
      this.commit();
      let execution: Execution;
      try {
        execution = this.executor(attempt, this.store.attemptDirectory(attempt.id));
      } catch (error) {
        attempt.status = "failed"; attempt.error = String(error); attempt.endedAt = now();
        this.commit();
        continue;
      }
      this.active.set(attempt.id, execution);
      void execution.done.then(outcome => {
        this.active.delete(attempt.id);
        Object.assign(attempt, outcome, { endedAt: now() });
        if (outcome.status === "succeeded") {
          try {
            attempt.result = validateResult(outcome.result, attempt.nonce, attempt.prepared.packet.inputHash);
          } catch (error) { attempt.status = "invalid_result"; delete attempt.result; attempt.error = String(error); }
          if (attempt.result) atomicJson(path.join(this.store.attemptDirectory(attempt.id), "result.json"), attempt.result);
        }
        this.commit();
        this.advanceSwarms();
        this.pump();
      }).catch(error => {
        this.active.delete(attempt.id);
        attempt.status = "unknown"; attempt.error = String(error);
        this.fatal = `Execution or persistence failed: ${String(error)}`;
        this.emit("changed");
        try { this.store.save(); } catch (saveError) { this.emit("diagnostic", String(saveError)); }
      });
    }
    this.advanceSwarms();
  }
  private advanceSwarms(): void {
    let changed = false;
    for (const swarm of this.store.state.swarms) {
      if (terminal(swarm.status)) continue;
      const workers = this.store.state.attempts.filter(a => swarm.workers.includes(a.id));
      if (workers.some(a => !terminal(a.status))) continue;
      if (swarm.synthesisId) {
        const synthesis = this.store.state.attempts.find(a => a.id === swarm.synthesisId)!;
        if (terminal(synthesis.status)) { swarm.status = synthesis.status; changed = true; }
        continue;
      }
      if (swarm.cancelRequested || workers.some(a => a.status !== "succeeded")) {
        swarm.status = swarm.cancelRequested ? "cancelled" : "blocked"; changed = true; continue;
      }
      if (this.closing || this.fatal) continue;
      const files = workers.map(worker => {
        const content = JSON.stringify({ attemptId: worker.id, agentId: worker.agentId,
          revision: worker.prepared.packet.revision, inputHash: worker.prepared.packet.inputHash, result: worker.result });
        return { path: `artifacts/${worker.id}.json`, content, sha256: hash(content) };
      });
      const prepared = structuredClone(swarm.synthesis);
      prepared.packet.files = files;
      prepared.packet.inputHash = hash(JSON.stringify({ revision: prepared.packet.revision, files }));
      const attempt = this.attempt(prepared, swarm.id, "synthesis");
      swarm.synthesisId = attempt.id;
      this.store.state.attempts.push(attempt);
      changed = true;
    }
    if (changed) {
      this.commit();
      if (!this.closing && !this.fatal) queueMicrotask(() => {
        try { this.pump(); } catch (error) { this.fatal = String(error); this.emit("changed"); }
      });
    }
  }
  snapshot() {
    let currentRevision: string | null = null;
    try { currentRevision = revision(this.store.repository); } catch (error) { this.emit("diagnostic", `Revision unavailable: ${String(error)}`); }
    const currentHashes = new Map<string, string | null>();
    for (const attempt of this.store.state.attempts.filter(a => a.kind !== "synthesis")) {
      for (const file of attempt.prepared.packet.files) {
        if (currentHashes.has(file.path)) continue;
        try { currentHashes.set(file.path, hash(readBounded(scopedFile(this.store.repository, file.path), 65536))); }
        catch { currentHashes.set(file.path, null); } // Missing/unsafe files are explicitly stale, not successful reads.
      }
    }
    const stale = (attempt: Attempt): boolean | null => {
      if (currentRevision === null) return null;
      if (currentRevision !== attempt.prepared.packet.revision) return true;
      if (attempt.kind === "synthesis") {
        return this.store.state.attempts.filter(a => a.runId === attempt.runId && a.kind === "worker")
          .some(worker => worker.prepared.packet.files.some(file => currentHashes.get(file.path) !== file.sha256));
      }
      return attempt.prepared.packet.files.some(file => currentHashes.get(file.path) !== file.sha256);
    };
    return {
      repository: this.store.repository, currentRevision, stateDirectory: this.store.directory,
      manifest: this.manifest, schedules: this.store.state.schedules, fatal: this.fatal,
      active: this.active.size, limit: 2, closing: this.closing,
      attempts: this.store.state.attempts.map(full => {
        const { prepared, nonce: _nonce, ...attempt } = full;
        return { ...attempt, revision: prepared.packet.revision, inputHash: prepared.packet.inputHash,
        promptHash: prepared.promptHash, files: prepared.packet.files.map(({ content: _content, ...file }) => file),
        stale: stale(full) };
      }),
      swarms: this.store.state.swarms.map(({ synthesis: _synthesis, ...swarm }) => swarm),
    };
  }
  async close(): Promise<void> {
    this.closing = true;
    if (this.timer) clearInterval(this.timer);
    for (const schedule of Object.values(this.store.state.schedules)) schedule.enabled = false;
    for (const runId of new Set(this.store.state.attempts.filter(a => !terminal(a.status)).map(a => a.runId))) this.cancel(runId);
    await Promise.all([...this.active.values()].map(execution => execution.done));
    this.commit();
    if (this.store.state.attempts.some(a => a.status === "unknown")) {
      throw new Error("Unconfirmed cleanup: ownership lock retained. Inspect the recorded bridge processes.");
    }
    this.store.close();
  }
}
