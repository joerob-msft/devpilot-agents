import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import path from "node:path";
import { fixture, until, controlled, success } from "./helpers.js";
import { loadManifest, parseManifest, prepare, validateResult, scopedFile } from "../src/manifest.js";
import { scaffold } from "../src/scaffold.js";
import { Store, recover } from "../src/store.js";
import { Fleet } from "../src/runner.js";
import type { State } from "../src/contracts.js";

test("scaffold and strict definitions reject overwrites, unknown keys, IDs and unsafe paths", async () => {
  const f = fixture();
  try {
    assert.throws(() => scaffold(f.repo), /already exists/);
    const input = JSON.parse(readFileSync(path.join(f.repo, ".devpilot", "fleet.json"), "utf8"));
    assert.throws(() => parseManifest({ ...input, executable: "arbitrary" }), /exactly/);
    input.agents[0].schedule.enabled = true;
    assert.throws(() => parseManifest(input), /enable schedules explicitly/);
    input.agents[0].schedule.enabled = false;
    input.agents[0].id = "__proto__";
    assert.throws(() => parseManifest(input), /Invalid id/);
    for (const name of ["../README.md", "/README.md", "C:/README.md", ".devpilot\\fleet.json"]) {
      assert.throws(() => scopedFile(f.repo, name), /safe/);
    }
    assert.throws(() => validateResult({ summary: "not bound" }, "x", "y"), /exactly/);
  } finally { await f.close(); }
});

test("packets bind content and revisions, reject secret paths, oversize files, and linked inputs", async () => {
  const f = fixture();
  try {
    const manifest = loadManifest(f.repo);
    const before = prepare(f.repo, manifest, manifest.agents[0]!);
    writeFileSync(path.join(f.repo, "README.md"), "# Edited but uncommitted\n");
    const after = prepare(f.repo, manifest, manifest.agents[0]!);
    assert.equal(before.packet.revision, after.packet.revision);
    assert.notEqual(before.packet.inputHash, after.packet.inputHash);
    manifest.inputProfiles["repo-packet"]!.files = [".env"];
    assert.throws(() => prepare(f.repo, manifest, manifest.agents[0]!), /policy/);
    manifest.inputProfiles["repo-packet"]!.files = ["README.md"];
    writeFileSync(path.join(f.repo, "README.md"), "x".repeat(65537));
    assert.throws(() => prepare(f.repo, manifest, manifest.agents[0]!), /exceeds/);
    symlinkSync(f.state, path.join(f.repo, "linked"), process.platform === "win32" ? "junction" : "dir");
    assert.throws(() => scopedFile(f.repo, "linked/state.json"), /Linked/);
    rmSync(path.join(f.repo, "linked"));
  } finally { await f.close(); }
});

test("a fresh prompt/entry executes without toolkit changes and dispatch is idempotent", async () => {
  const f = fixture();
  try {
    const file = path.join(f.repo, ".devpilot", "fleet.json");
    const manifest = JSON.parse(readFileSync(file, "utf8"));
    manifest.agents.push({ ...manifest.agents[0], id: "new-role", prompt: ".devpilot/prompts/new.md" });
    writeFileSync(path.join(f.repo, ".devpilot", "prompts", "new.md"), "Assess missing documentation.");
    writeFileSync(file, JSON.stringify(manifest));
    f.fleet.reload();
    const runId = f.fleet.runAgent("new-role", "new-role-request-01");
    assert.equal(f.fleet.runAgent("new-role", "new-role-request-01"), runId);
    assert.throws(() => f.fleet.runAgent("repo-efficiency", "new-role-request-01"), /another target/);
    await until(() => f.store.state.attempts[0]?.status === "succeeded");
    assert.equal(f.store.state.attempts.length, 1);
    assert.match(f.store.state.attempts[0]!.result!.summary, /new-role/);
    assert.ok(readFileSync(path.join(f.state, "runs", f.store.state.attempts[0]!.id, "result.json"), "utf8"));
  } finally { await f.close(); }
});

test("swarm runs two workers then synthesis over accepted artifacts under two slots", async () => {
  const c = controlled(), f = fixture(c.executor);
  try {
    const runId = f.fleet.runSwarm("improvement-review", "swarm-request-001");
    assert.equal(f.fleet.active.size, 2);
    assert.throws(() => f.fleet.runAgent("repo-efficiency", "overlap-request-01"), /admitted work/);
    const first = [...c.running.values()][0]!, second = [...c.running.values()][1]!;
    first.complete(success(first.attempt));
    await until(() => f.fleet.active.size === 1);
    assert.equal(f.store.state.attempts.length, 2);
    second.complete(success(second.attempt));
    await until(() => f.store.state.attempts.length === 3);
    const synthesis = f.store.state.attempts[2]!;
    assert.equal(synthesis.kind, "synthesis");
    assert.equal(synthesis.prepared.packet.files.length, 2);
    assert.match(synthesis.prepared.packet.files[0]!.content, /Result for/);
    c.running.get(synthesis.id)!.complete(success(synthesis));
    await until(() => f.store.state.swarms[0]!.status === "succeeded");
    assert.ok(f.store.state.attempts.every(a => a.runId === runId));
  } finally { await f.close(); }
});

test("required worker failure blocks synthesis instead of producing a successful summary", async () => {
  const f = fixture(attempt => ({ done: Promise.resolve(attempt.agentId === "repo-efficiency" ?
    { status: "failed", error: "Fixture failure" } : success(attempt)), cancel() {} }));
  try {
    f.fleet.runSwarm("improvement-review", "failure-request-01");
    await until(() => f.store.state.swarms[0]?.status === "blocked");
    assert.equal(f.store.state.attempts.length, 2);
  } finally { await f.close(); }
});

test("cancellation keeps the slot and prevents replacement until execution confirms termination", async () => {
  const c = controlled(), f = fixture(c.executor);
  try {
    const run = f.fleet.runAgent("repo-efficiency", "cancel-request-01");
    const active = [...c.running.values()][0]!;
    f.fleet.cancel(run);
    assert.equal(active.cancel, true);
    assert.equal(f.fleet.active.size, 1);
    assert.throws(() => f.fleet.runAgent("repo-efficiency", "replacement-0001"), /admitted work/);
    active.complete({ status: "cancelled" });
    await until(() => f.fleet.active.size === 0);
    assert.equal(f.store.state.attempts[0]?.status, "cancelled");
  } finally { await f.close(); }
});

test("schedules are explicit, coalesce missed ticks, and do not overlap", async () => {
  const c = controlled(), f = fixture(c.executor);
  try {
    assert.equal(f.store.state.schedules["repo-efficiency"]!.enabled, false);
    assert.throws(() => f.fleet.schedule("constructor", true), /Unknown agent/);
    f.fleet.tick(Date.now() + 10_000_000);
    assert.equal(c.running.size, 0);
    f.fleet.schedule("repo-efficiency", true);
    f.fleet.tick(Date.now() + 10_000_000);
    assert.equal(c.running.size, 1);
    f.fleet.tick(Date.now() + 20_000_000);
    assert.equal(c.running.size, 1);
    const active = [...c.running.values()][0]!;
    active.complete(success(active.attempt));
    await until(() => !f.fleet.active.size);
  } finally { await f.close(); }
});

test("restart marks unfinished work interrupted, disables schedules, and preserves artifacts", async () => {
  const f = fixture();
  try {
    f.fleet.runAgent("repo-efficiency", "restart-request-01");
    await until(() => f.store.state.attempts[0]?.status === "succeeded");
    f.store.state.attempts[0]!.status = "running";
    f.store.state.attempts[0]!.transportNote = "Input echo omitted after independent journal audit.";
    f.store.state.schedules["repo-efficiency"]!.enabled = true;
    f.store.save();
    f.store.close();
    const restored = new Store(f.state, f.repo);
    assert.equal(restored.state.attempts[0]!.status, "interrupted");
    assert.equal(restored.state.attempts[0]!.transportNote, "Input echo omitted after independent journal audit.");
    assert.equal(restored.state.schedules["repo-efficiency"]!.enabled, false);
    assert.throws(() => new Store(f.state, f.repo), /ownership/);
    assert.throws(() => recover(f.state, f.repo), /still present/);
    const fleet = new Fleet(restored, () => { throw new Error("Restart must not execute"); });
    fleet.tick(Date.now() + 10_000_000);
    await fleet.close();
  } finally {
    // Original store was deliberately released without another executor.
    rmSync(f.base, { recursive: true, force: true });
  }
});

test("invalid result binding is not success; unconfirmed cleanup freezes admission", async () => {
  const f = fixture(attempt => ({ done: Promise.resolve({ ...success(attempt),
    result: { ...success(attempt).result!, nonce: "wrong" } }), cancel() {} }));
  try {
    f.fleet.runAgent("repo-efficiency", "invalid-request-01");
    await until(() => f.store.state.attempts[0]?.status === "invalid_result");
    f.store.state.attempts[0]!.status = "unknown";
    assert.throws(() => f.fleet.runAgent("toolkit-maintainer", "blocked-request-01"), /cleanup/);
    f.store.state.attempts[0]!.status = "failed";
  } finally { await f.close(); }
});

test("dirty and missing inputs mark worker and synthesis evidence stale without a HEAD change", async () => {
  const f = fixture();
  try {
    f.fleet.runSwarm("improvement-review", "stale-swarm-request");
    await until(() => f.store.state.swarms[0]?.status === "succeeded");
    const before = f.fleet.snapshot();
    assert.equal(before.attempts.length, 3);
    assert.ok(before.attempts.every(a => a.stale === false));
    writeFileSync(path.join(f.repo, "README.md"), "# Changed inputs\n");
    const dirty = f.fleet.snapshot();
    assert.equal(dirty.currentRevision, before.currentRevision);
    assert.ok(dirty.attempts.every(a => a.stale === true));
    rmSync(path.join(f.repo, "README.md"));
    assert.ok(f.fleet.snapshot().attempts.every(a => a.stale === true));
  } finally { await f.close(); }
});

test("swarm cancellation drains both workers without creating synthesis", async () => {
  const c = controlled(), f = fixture(c.executor);
  try {
    const runId = f.fleet.runSwarm("improvement-review", "cancel-swarm-request");
    f.fleet.cancel(runId);
    assert.equal(f.fleet.active.size, 2);
    assert.ok([...c.running.values()].every(worker => worker.cancel));
    for (const worker of c.running.values()) worker.complete({ status: "cancelled" });
    await until(() => f.store.state.swarms[0]?.status === "cancelled");
    assert.equal(f.store.state.attempts.length, 2);
    assert.equal(f.fleet.active.size, 0);
  } finally {
    for (const worker of c.running.values()) worker.complete({ status: "cancelled" });
    await f.close();
  }
});

test("admission reserves pending synthesis capacity at the retained-attempt limit", async () => {
  const c = controlled(), f = fixture(c.executor);
  try {
    f.fleet.runAgent("repo-efficiency", "history-seed-request");
    const seed = [...c.running.values()][0]!;
    seed.complete(success(seed.attempt));
    await until(() => f.fleet.active.size === 0);
    for (let index = 1; index < 197; index++) {
      const copy = structuredClone(seed.attempt);
      copy.id = copy.runId = index.toString(16).padStart(32, "0");
      f.store.state.attempts.push(copy);
    }
    f.fleet.manifest.agents.push({ ...f.fleet.manifest.agents[0]!, id: "extra-role" });
    f.fleet.runSwarm("improvement-review", "history-swarm-request");
    assert.equal(f.store.state.attempts.length, 199);
    assert.throws(() => f.fleet.runAgent("extra-role", "history-overflow-request"), /retained-attempt limit/);
    for (const worker of c.running.values()) worker.complete(success(worker.attempt));
    await until(() => f.store.state.attempts.length === 200);
    const synthesis = f.store.state.attempts[199]!;
    assert.equal(synthesis.kind, "synthesis");
    c.running.get(synthesis.id)!.complete(success(synthesis));
    await until(() => f.store.state.swarms[0]?.status === "succeeded");
    assert.equal(f.store.state.attempts.length, 200);
  } finally {
    for (const worker of c.running.values()) worker.complete({ status: "cancelled" });
    await f.close();
  }
});

test("corrupt persisted state refuses startup and releases only the newly acquired lock", async () => {
  const f = fixture();
  try {
    f.fleet.runAgent("repo-efficiency", "corrupt-state-request");
    await until(() => f.store.state.attempts[0]?.status === "succeeded");
    await f.fleet.close();
    const original = structuredClone(f.store.state);
    const cases: Array<(state: State) => void> = [
      state => { Reflect.set(state.attempts[0]!.prepared.packet, "files", "invalid"); },
      state => { state.attempts.push(state.attempts[0]!); },
      state => { delete state.attempts[0]!.result; },
      state => { state.attempts[0]!.prepared.timeoutSeconds = -1; },
      state => { state.repository = "another-repo"; },
      state => { Reflect.set(state.attempts[0]!, "transportNote", { unexpected: true }); },
      state => { state.attempts[0]!.transportNote = "x".repeat(1001); },
    ];
    for (const corrupt of cases) {
      const state = structuredClone(original);
      corrupt(state);
      writeFileSync(path.join(f.state, "state.json"), JSON.stringify(state));
      assert.throws(() => new Store(f.state, f.repo), /Invalid|Corrupt|Duplicate|lacks|transportNote/);
      assert.equal(existsSync(path.join(f.state, "owner.json")), false);
    }
  } finally {
    if (!f.fleet.closing) await f.fleet.close();
    rmSync(f.base, { recursive: true, force: true });
  }
});
