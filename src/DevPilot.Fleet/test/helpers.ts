import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Attempt, ExecutionOutcome, Executor } from "../src/contracts.js";
import { scaffold } from "../src/scaffold.js";
import { Store } from "../src/store.js";
import { Fleet } from "../src/runner.js";

export function fixture(executor: Executor = immediate()) {
  const base = realpathSync(mkdtempSync(path.join(os.tmpdir(), "devpilot-fleet-test-")));
  const repo = path.join(base, "repo"), state = path.join(base, "state");
  mkdirSync(repo); mkdirSync(state, { mode: 0o700 });
  const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { stdio: "pipe", timeout: 10000 });
  git("init", "--quiet");
  writeFileSync(path.join(repo, "README.md"), "# Example repository\n\nBuild: npm run build\nTests: npm test\n");
  git("add", "README.md");
  git("-c", "user.name=Fleet Fixture", "-c", "user.email=fleet@example.invalid", "-c", "core.hooksPath=",
    "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Fixture");
  scaffold(repo);
  const store = new Store(state, repo);
  const fleet = new Fleet(store, executor);
  return { base, repo, state, git, store, fleet,
    async close() { await fleet.close(); rmSync(base, { recursive: true, force: true }); } };
}
export function success(attempt: Attempt): ExecutionOutcome {
  return { status: "succeeded", result: { schemaVersion: 1, nonce: attempt.nonce,
    inputHash: attempt.prepared.packet.inputHash, summary: `Result for ${attempt.agentId}`,
    findings: [{ title: "Clarify validation", evidence: "README.md: Tests: npm test", recommendation: "Document prerequisites." }] } };
}
export function immediate(): Executor {
  return attempt => ({ done: Promise.resolve(success(attempt)), cancel() {} });
}
export function controlled() {
  const running = new Map<string, { attempt: Attempt; complete: (outcome: ExecutionOutcome) => void; cancel: boolean }>();
  const executor: Executor = attempt => {
    let complete!: (outcome: ExecutionOutcome) => void;
    const done = new Promise<ExecutionOutcome>(resolve => { complete = resolve; });
    running.set(attempt.id, { attempt, complete, cancel: false });
    return { done, cancel() { running.get(attempt.id)!.cancel = true; } };
  };
  return { executor, running };
}
export async function until(condition: () => boolean, timeout = 3000) {
  const deadline = Date.now() + timeout;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("Condition did not settle");
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
