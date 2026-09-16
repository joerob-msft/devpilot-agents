import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import path from "node:path";
import { diagnoseRejectedAnswer, readRejectedAnswer, rejectedResultError, rejectedAnswerCharacterLimit } from "../src/result-diagnostics.js";
import { validateResult } from "../src/manifest.js";
import { buildPrompt } from "../src/executor.js";
import { fixture, until } from "./helpers.js";

const rejected = readFileSync(new URL("../../test/fixtures/rejected-extra-field.json", import.meta.url), "utf8");
const nonce = "a".repeat(32), inputHash = "b".repeat(64);

test("the extra-field regression is diagnosed precisely without accepting or changing it", () => {
  const original: unknown = JSON.parse(rejected);
  const before = JSON.stringify(original);
  assert.throws(() => validateResult(original, nonce, inputHash), /findings\[1\]\.path_note: unexpected field/);
  assert.match(diagnoseRejectedAnswer(rejected, nonce, inputHash), /findings\[1\]\.path_note: unexpected field/);
  assert.match(diagnoseRejectedAnswer(`FLEET_RESULT:${rejected}`, nonce, inputHash), /findings\[1\]\.path_note/);
  assert.equal(JSON.stringify(original), before);
});

test("binding and framing failures stay failures, including otherwise valid retained JSON", () => {
  assert.match(diagnoseRejectedAnswer(rejected, "wrong", inputHash), /nonce: result binding mismatch/);
  assert.match(diagnoseRejectedAnswer(rejected, nonce, "wrong"), /inputHash: result binding mismatch/);
  assert.match(diagnoseRejectedAnswer(`${rejected}${rejected}`, nonce, inputHash), /one complete JSON object/);
  assert.match(diagnoseRejectedAnswer(`FLEET_RESULT:${rejected} FLEET_RESULT:{"other":1}`, nonce, inputHash), /one complete JSON object/);
  const valid = JSON.stringify({ schemaVersion: 1, nonce, inputHash, summary: "Evidence", findings: [] });
  assert.match(diagnoseRejectedAnswer(valid, nonce, inputHash), /Original rejection retained/);
});

test("rejected-answer reads are bounded and refuse symlinks; missing diagnostics do not imply unknown cleanup", async () => {
  const f = fixture(), file = path.join(f.state, "answer.txt");
  try {
    assert.match(rejectedResultError(f.state, nonce, inputHash), /retained answer unavailable/);
    writeFileSync(file, rejected);
    assert.match(readRejectedAnswer(f.state, nonce, inputHash).diagnostic, /path_note/);
    assert.equal(readRejectedAnswer(f.state, nonce, inputHash).limitReached, false);
    writeFileSync(file, "x".repeat(rejectedAnswerCharacterLimit + 1));
    const capped = readRejectedAnswer(f.state, nonce, inputHash);
    assert.equal(capped.answer.length, rejectedAnswerCharacterLimit);
    assert.equal(capped.limitReached, true);
    assert.match(capped.diagnostic, /may be incomplete/);
    writeFileSync(file, "x".repeat(rejectedAnswerCharacterLimit * 4 + 1));
    assert.throws(() => readRejectedAnswer(f.state, nonce, inputHash), /exceeds/);
    const linked = path.join(f.repo, "linked");
    symlinkSync(f.state, linked, process.platform === "win32" ? "junction" : "dir");
    assert.throws(() => readRejectedAnswer(linked, nonce, inputHash), /Linked/);
    rmSync(linked);
  } finally { await f.close(); }
});

test("the host repeats the exact result contract after untrusted packet content", async () => {
  const f = fixture();
  try {
    f.fleet.runAgent("repo-efficiency", "prompt-contract-request");
    await until(() => f.store.state.attempts[0]?.status === "succeeded");
    const attempt = f.store.state.attempts[0]!;
    const prompt = buildPrompt(attempt);
    const tail = prompt.slice(prompt.indexOf("END INPUT PACKET."));
    assert.match(tail, /exactly title, evidence, recommendation/);
    assert.match(tail, /Do not add path_note/);
    assert.equal(JSON.parse(tail.split("\n").at(-1)!).nonce, attempt.nonce);
  } finally { await f.close(); }
});
