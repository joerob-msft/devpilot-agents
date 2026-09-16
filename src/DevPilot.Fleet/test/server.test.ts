import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fixture, until } from "./helpers.js";
import { serve } from "../src/server.js";
import { observeLegacy } from "../src/legacy-observer.js";
import { object } from "../src/manifest.js";

test("loopback API protects mutations, rejects hostile origins and serves themed static content", async () => {
  const f = fixture(), web = await serve(f.fleet, 0);
  try {
    const response = await fetch(web.origin);
    assert.equal(response.status, 200);
    const html = await response.text();
    assert.match(html, /--cp-bg:/);
    assert.match(html, /data-theme/);
    assert.doesNotMatch(html, /\{\{NONCE\}\}/);
    assert.match(response.headers.get("content-security-policy")!, /frame-ancestors 'none'/);
    const state = await (await fetch(`${web.origin}/api/state`)).json();
    const payload = { kind: "agent", id: "repo-efficiency", requestId: "http-request-0001" };
    const post = (headers: Record<string, string>) => fetch(`${web.origin}/api/run`, {
      method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(payload),
    });
    assert.equal((await post({})).status, 403);
    assert.equal((await post({ Origin: web.origin, "X-Fleet-CSRF": "\u00e9".repeat(64) })).status, 403);
    assert.equal((await post({ Origin: "https://attacker.invalid", "X-Fleet-CSRF": state.csrfToken })).status, 403);
    assert.equal((await post({ Origin: web.origin, "X-Fleet-CSRF": state.csrfToken })).status, 202);
    await until(() => f.store.state.attempts[0]?.status === "succeeded");
    assert.equal((await post({ Origin: web.origin, "X-Fleet-CSRF": state.csrfToken })).status, 202);
    assert.equal(f.store.state.attempts.length, 1);
    const rebound = await new Promise<number | undefined>((resolve, reject) => {
      const req = http.get(`${web.origin}/api/state`, { headers: { Host: "evil.invalid" } }, res => {
        res.resume(); resolve(res.statusCode);
      });
      req.once("error", reject);
    });
    assert.equal(rebound, 403);
    assert.equal((await fetch(`${web.origin}/../../package.json`)).status, 404);
    const invalid = await fetch(`${web.origin}/api/run`, {
      method: "POST", headers: { "Content-Type": "application/json", Origin: web.origin, "X-Fleet-CSRF": state.csrfToken },
      body: JSON.stringify({ ...payload, executable: "bad" }),
    });
    assert.equal(invalid.status, 400);
    const oversized = await fetch(`${web.origin}/api/run`, {
      method: "POST", headers: { "Content-Type": "application/json", Origin: web.origin, "X-Fleet-CSRF": state.csrfToken },
      body: JSON.stringify({ ...payload, id: "x".repeat(8192) }),
    });
    assert.equal(oversized.status, 400);
    assert.equal(f.store.state.attempts.length, 1);
    assert.equal((await fetch(`${web.origin}/api/state`, { headers: { "Sec-Fetch-Site": "cross-site" } })).status, 403);
    const events = await fetch(`${web.origin}/api/events`);
    const reader = events.body!.getReader();
    const first = await reader.read();
    assert.match(new TextDecoder().decode(first.value), /event: changed/);
    await reader.cancel();
  } finally { await web.close(); await f.close(); }
});

test("legacy observation preserves producer identity and reports malformed and missing streams", async () => {
  const f = fixture();
  try {
    const file = path.join(f.state, "legacy.jsonl");
    const event = { agent: "reviewer", instanceId: "test-stream", sequence: 1,
      eventType: "agent.started", timestamp: new Date().toISOString(), message: "Observation" };
    writeFileSync(file, JSON.stringify(event) + "\n" + JSON.stringify({ ...event, sequence: 2 }) + "\ninvalid\n{partial");
    const observed = observeLegacy([file, path.join(f.state, "absent.jsonl")]);
    assert.equal(observed.streams.length, 1);
    assert.equal(observed.streams[0]?.sequence, 2);
    assert.ok(observed.diagnostics.some(d => d.includes("malformed")));
    assert.ok(observed.diagnostics.some(d => d.includes("absent")));
  } finally { await f.close(); }
});

test("rejected-answer API diagnoses legacy attempts read-only and cannot serve arbitrary files", async () => {
  const f = fixture(), web = await serve(f.fleet, 0);
  try {
    f.fleet.runAgent("repo-efficiency", "rejected-view-request");
    await until(() => f.store.state.attempts[0]?.status === "succeeded");
    const attempt = f.store.state.attempts[0]!;
    const url = `${web.origin}/api/rejected-answer?id=${attempt.id}`;
    assert.equal((await fetch(url)).status, 400);
    attempt.status = "invalid_result";
    attempt.error = "Missing, malformed, or conflicting result.";
    delete attempt.result;
    f.store.save();
    const result = object(JSON.parse(readFileSync(new URL("../../test/fixtures/rejected-extra-field.json", import.meta.url), "utf8")), "fixture");
    result.nonce = attempt.nonce;
    result.inputHash = attempt.prepared.packet.inputHash;
    result.summary = "<script>throw new Error('untrusted model text')</script>";
    const answer = `FLEET_RESULT:${JSON.stringify(result)}`;
    const file = path.join(f.store.attemptDirectory(attempt.id), "answer.txt");
    writeFileSync(file, answer);
    const persisted = readFileSync(f.store.file, "utf8");
    const response = await fetch(url);
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type")!, /application\/json/);
    const value = await response.json();
    assert.match(value.diagnostic, /findings\[1\]\.path_note: unexpected field/);
    assert.equal(value.answer, answer);
    assert.equal(value.originalError, attempt.error);
    assert.equal(value.status, "invalid_result");
    assert.equal(readFileSync(file, "utf8"), answer);
    assert.equal(readFileSync(f.store.file, "utf8"), persisted);
    assert.equal((await fetch(url, { headers: { Origin: "https://attacker.invalid" } })).status, 403);
    assert.equal((await fetch(`${web.origin}/api/rejected-answer?id=..%2Fowner.json`)).status, 400);
    assert.equal((await fetch(`${web.origin}/api/rejected-answer?id=${"0".repeat(32)}`)).status, 400);
    assert.equal((await fetch(`${web.origin}/runs/${attempt.id}/answer.txt`)).status, 404);
  } finally { await web.close(); await f.close(); }
});
