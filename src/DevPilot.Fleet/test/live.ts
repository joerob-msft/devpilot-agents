import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { scaffold } from "../src/scaffold.js";
import { Store } from "../src/store.js";
import { Fleet } from "../src/runner.js";
import { createExecutor, packageRoot, resolveExecutor } from "../src/executor.js";
import { until } from "./helpers.js";

if (process.env.DEVPILOT_FLEET_LIVE !== "1") throw new Error("Opt in with DEVPILOT_FLEET_LIVE=1. This exercise consumes model usage.");
const base = realpathSync(mkdtempSync(path.join(os.tmpdir(), "devpilot-fleet-live-")));
const repo = path.join(base, "repo"), statePath = path.join(base, "state");
mkdirSync(repo);
writeFileSync(path.join(repo, "README.md"),
  "# Fleet live example\n\nA small public example project. Build: npm run build. Tests: npm test.\n" +
  "The documentation does not yet explain dependencies, ownership, or how to interpret failures.\n");
const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { stdio: "pipe" });
git("init", "--quiet"); git("add", "README.md");
git("-c", "user.name=Fleet Example", "-c", "user.email=fleet@example.invalid", "-c", "commit.gpgsign=false",
  "-c", "core.hooksPath=", "commit", "--quiet", "-m", "Example input");
scaffold(repo);
execFileSync("pwsh", ["-NoProfile", "-File", path.join(packageRoot, "bridge", "Initialize-FleetState.ps1"),
  "-Path", statePath, "-RepositoryRoot", repo], { stdio: "pipe" });
const store = new Store(statePath, repo);
const fleet = new Fleet(store, createExecutor(store, resolveExecutor()));
console.log(`Live artifacts: ${base}`);
try {
  fleet.runSwarm("improvement-review", "live-swarm-example-01");
  await until(() => ["succeeded", "blocked", "unknown", "failed"].includes(store.state.swarms[0]?.status ?? ""), 900000);
  console.log(JSON.stringify(fleet.snapshot().attempts.map(a => ({ agent: a.agentId, status: a.status, error: a.error, summary: a.result?.summary })), null, 2));
  if (store.state.swarms[0]?.status !== "succeeded") throw new Error("Live swarm did not succeed; artifacts retained for diagnosis");
} finally { await fleet.close(); }
