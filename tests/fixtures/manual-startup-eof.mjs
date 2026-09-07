import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

const [executable, script, descriptor, expectedExitCode, mode] = process.argv.slice(2);
const broker = spawn(executable, ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", script, "-DescriptorPath", descriptor],
  { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] });
const exited = once(broker, "exit");
broker.stderr.resume();
const lines = createInterface({ input: broker.stdout })[Symbol.asyncIterator]();
const request = (operation, fields = {}) => broker.stdin.write(`${JSON.stringify({
  schemaVersion: 1, requestId: randomUUID(), operation, ...fields,
})}\n`);
try {
  request("describe", { repositoryKey: "v1:github:114", pullRequestId: 114, role: "reviewer" });
  const summary = JSON.parse((await lines.next()).value);
  assert.equal(summary.operation, "capability-summary");
  request("dispatch", {
    repositoryKey: summary.repositoryIdentity.key, pullRequestId: 114, role: summary.role,
    dispatchDraftId: summary.dispatchDraftId, capabilityPolicyDigest: summary.capabilityPolicyDigest,
    prStateFingerprint: summary.prStateFingerprint, operatorPrompt: "isolated startup context",
  });
  const accepted = JSON.parse((await lines.next()).value);
  assert.equal(accepted.operation, "accepted");
  if (mode === "shutdown-termination-failed") request("shutdown");
  else broker.stdin.end();
  // The outer finally must stop its own live child without leaking a Boolean.
  // Also verify an explicit shutdown cannot claim success after failed containment.
  let rejectedShutdown = false;
  for await (const line of { [Symbol.asyncIterator]: () => lines }) {
    const frame = JSON.parse(line);
    assert.equal(frame.schemaVersion, 1);
    assert.notEqual(frame.operation, "shutdown-complete", "failed containment cannot acknowledge shutdown");
    if (frame.operation === "rejected" && frame.code === "termination-failed") rejectedShutdown = true;
  }
  assert.equal(rejectedShutdown, mode === "shutdown-termination-failed");
  const [code] = await exited;
  assert.equal(code, Number(expectedExitCode));
  assert.throws(() => process.kill(accepted.childProcessId, 0), "owned child must exit on broker EOF");
  console.log("startup-eof-verified");
} finally {
  if (broker.exitCode === null) broker.kill();
}
