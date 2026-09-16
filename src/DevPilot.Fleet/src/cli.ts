import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { parseArgs } from "node:util";
import { hash, repositoryRoot } from "./manifest.js";
import { scaffold } from "./scaffold.js";
import { Store, recover } from "./store.js";
import { Fleet } from "./runner.js";
import { createExecutor, packageRoot, resolveExecutor } from "./executor.js";
import { serve } from "./server.js";

async function main() {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      repo: { type: "string", default: "." }, port: { type: "string", default: "4317" },
      input: { type: "string", default: "README.md" }, state: { type: "string" },
      observe: { type: "string", multiple: true, default: [] }, help: { type: "boolean", default: false },
    },
  });
  const command = positionals[0];
  if (values.help || !command) {
    console.log("DevPilot Fleet POC\n  init --repo <root> [--input README.md]\n  serve --repo <root> [--port 4317] [--observe <legacy.jsonl>]\n  recover --repo <root> (only after owner and all workers have exited)\n  --state <private-directory> overrides host storage; never share it between repositories.");
    return;
  }
  if (positionals.length !== 1 || !["init", "serve", "recover"].includes(command)) throw new Error("Expected init, serve, or recover");
  const repo = repositoryRoot(path.resolve(values.repo));
  if (command === "init") {
    scaffold(repo, values.input);
    console.log("Created .devpilot\\fleet.json and prompts. Review the input files before running. No schedules enabled.");
    return;
  }
  const state = path.resolve(values.state ?? path.join(os.homedir(), ".devpilot", "fleet", hash(repo).slice(0, 24)));
  execFileSync("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-File",
    path.join(packageRoot, "bridge", "Initialize-FleetState.ps1"), "-Path", state, "-RepositoryRoot", repo],
  { encoding: "utf8", timeout: 20000, maxBuffer: 8192, windowsHide: true });
  if (command === "recover") {
    recover(state, repo);
    console.log("Inactive ownership cleared. Restart marks unfinished work interrupted and leaves schedules disabled.");
    return;
  }
  const port = Number(values.port);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("Invalid port");
  if (values.observe.length > 8) throw new Error("At most 8 explicit legacy event files");
  const executable = resolveExecutor();
  const store = new Store(state, repo);
  let fleet: Fleet;
  let website: Awaited<ReturnType<typeof serve>>;
  try {
    fleet = new Fleet(store, createExecutor(store, executable));
    website = await serve(fleet, port, values.observe.map(file => path.resolve(file)));
  } catch (error) { store.close(); throw error; }
  fleet.on("diagnostic", message => console.error(message));
  fleet.start();
  console.log(`DevPilot Fleet: ${website.origin}\nRepository: ${repo}\nPrivate state: ${state}\nExecutor: ${executable}\nTool-disabled packet analysis. Operator authentication; no cloud hosting or unattended service guarantee.\nKeep this terminal open. Ctrl+C cancels admitted work and drains before exiting.`);
  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true;
    try { await website.close(); await fleet.close(); }
    catch (error) { console.error(String(error)); process.exitCode = 1; }
  };
  process.once("SIGINT", () => { void close(); });
  process.once("SIGTERM", () => { void close(); });
}
main().catch(error => { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; });
