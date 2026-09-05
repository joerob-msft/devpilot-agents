import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const [modulePath, executablePath, scriptPath, descriptorPath, mode] = process.argv.slice(2);
const { DispatchClient, BrokerRejectionError } = await import(pathToFileURL(modulePath).href);
let resolveTerminal, rejectTerminal;
const terminal = new Promise((resolve, reject) => {
  resolveTerminal = resolve;
  rejectTerminal = reject;
  setTimeout(() => reject(new Error("startup terminal event timed out")), 45_000).unref();
});
// Register before dispatch: completion can follow acceptance in the same stdout chunk.
const client = new DispatchClient({ executablePath, scriptPath, descriptorPath }, {
  onBrokerFailure: (message) => rejectTerminal(new Error(message)),
  onTerminal: resolveTerminal,
});
terminal.catch(() => {});
try {
  const summary = await client.describe("v1:github:114", 114, "reviewer");
  assert.deepEqual(summary.mandatoryDenies, ["EnableApprovalVote"]);
  if (mode === "success") {
    const accepted = await client.dispatch(summary, "isolated startup context");
    assert.equal(accepted.operation, "accepted");
    const completed = await terminal;
    assert.equal(completed.operation, "completed");
    assert.equal(completed.dispatchId, accepted.dispatchId);
    assert.equal(completed.exitCode, 0);
    const event = JSON.parse(await readFile(accepted.eventLogPath, "utf8"));
    assert.equal(event.dispatchId, accepted.dispatchId);
    assert.equal(event.processId, accepted.childProcessId);
    assert.equal(event.startupVerified, true);
    assert.equal(event.attestationHandleCleared, true);
  } else {
    await assert.rejects(client.dispatch(summary, "isolated startup context"), (error) => {
      assert.ok(error instanceof BrokerRejectionError, error.message);
      assert.equal(error.code, mode === "contention" ? "already-running" :
        mode === "termination-failed" ? "termination-failed" : "launch-failed");
      assert.match(error.message, mode === "contention" ? /lease-contended/ : /startup-test-failure/);
      return true;
    });
    // A typed rejection must not poison the connection or obscure the next request.
    assert.equal((await client.profile("v1:github:114", 114, "reviewer")).operation, "capability-profile");
    if (mode === "termination-failed") {
      const runtime = join(dirname(descriptorPath), "manual-dispatch", summary.dispatchDraftId, "runtime");
      const files = await readdir(runtime);
      assert.ok(files.includes("dispatch-manifest.json"), "live-child state must remain owned");
      assert.ok(!files.includes("operator-context.txt"), "failed startup must revoke operator context");
    }
  }
  console.log(`startup-${mode}-verified`);
} finally {
  await client.shutdown();
}
