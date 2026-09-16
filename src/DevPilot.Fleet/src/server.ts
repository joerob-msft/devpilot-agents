import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { Fleet } from "./runner.js";
import { packageRoot } from "./executor.js";
import { keys, object, text } from "./manifest.js";
import { observeLegacy } from "./legacy-observer.js";

async function body(req: IncomingMessage): Promise<Record<string, unknown>> {
  if (req.headers["content-type"] !== "application/json") throw new Error("Expected application/json");
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let over = false;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > 8192) { over = true; reject(new Error("Request exceeds 8 KiB")); return; }
      if (!over) chunks.push(chunk);
    });
    req.on("end", () => {
      if (over) return;
      try { resolve(object(JSON.parse(Buffer.concat(chunks).toString("utf8")), "request")); } catch (error) { reject(error); }
    });
    req.on("error", reject);
  });
}
export async function serve(fleet: Fleet, port: number, legacyFiles: string[] = []) {
  const token = randomBytes(32).toString("hex");
  const clients = new Set<ServerResponse>();
  const diagnostics: string[] = [];
  fleet.on("diagnostic", (message: string) => { diagnostics.push(message); if (diagnostics.length > 20) diagnostics.shift(); });
  let origin = "";
  const json = (res: ServerResponse, status: number, value: unknown) => {
    res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify(value));
  };
  const server = createServer((req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    const nonce = randomBytes(16).toString("hex");
    res.setHeader("Content-Security-Policy", `default-src 'none'; script-src 'self' 'nonce-${nonce}'; style-src 'self' 'nonce-${nonce}'; connect-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`);
    if (req.headers.host !== new URL(origin).host ||
        (req.headers.origin && req.headers.origin !== origin) ||
        req.headers["sec-fetch-site"] === "cross-site") {
      json(res, 403, { error: "Loopback same-origin requests only" }); return;
    }
    void (async () => {
      const url = new URL(req.url ?? "/", origin);
      if (req.method === "GET") {
        if (url.pathname === "/api/state") {
          json(res, 200, { ...fleet.snapshot(), csrfToken: token, diagnostics,
            legacy: observeLegacy(legacyFiles), executor: "copilot: tool-disabled repository packet", progress: "Host state only; model/tool progress and cost unknown" });
        } else if (url.pathname === "/api/preview") {
          json(res, 200, fleet.preview(url.searchParams.get("id") ?? ""));
        } else if (url.pathname === "/api/rejected-answer") {
          json(res, 200, fleet.rejectedAnswer(url.searchParams.get("id") ?? ""));
        } else if (url.pathname === "/api/events") {
          if (clients.size >= 16) { json(res, 429, { error: "Too many event clients" }); return; }
          res.writeHead(200, { "Content-Type": "text/event-stream", Connection: "keep-alive" });
          res.write("event: changed\ndata: ready\n\n");
          clients.add(res);
          req.once("close", () => clients.delete(res));
        } else {
          const file = new Map([["/", "index.html"], ["/app.js", "app.js"]]).get(url.pathname);
          if (!file) { json(res, 404, { error: "Not found" }); return; }
          const content = readFileSync(path.join(packageRoot, "public", file), "utf8").replaceAll("{{NONCE}}", nonce);
          res.writeHead(200, { "Content-Type": file.endsWith(".js") ? "text/javascript; charset=utf-8" : "text/html; charset=utf-8" });
          res.end(content);
        }
        return;
      }
      if (req.method !== "POST") { json(res, 405, { error: "Method not allowed" }); return; }
      const csrf = req.headers["x-fleet-csrf"];
      if (req.headers.origin !== origin || typeof csrf !== "string" || !/^[a-f0-9]{64}$/.test(csrf) ||
          !timingSafeEqual(Buffer.from(csrf), Buffer.from(token))) {
        json(res, 403, { error: "Missing same-origin mutation token" }); return;
      }
      const input = await body(req);
      if (url.pathname === "/api/run") {
        keys(input, ["kind", "id", "requestId"], "run");
        const id = text(input.id, 48, "id"), requestId = text(input.requestId, 80, "requestId");
        if (input.kind !== "agent" && input.kind !== "swarm") throw new Error("Invalid run kind");
        const runId = input.kind === "agent" ? fleet.runAgent(id, requestId) : fleet.runSwarm(id, requestId);
        json(res, 202, { runId });
      } else if (url.pathname === "/api/cancel") {
        keys(input, ["runId"], "cancel");
        fleet.cancel(text(input.runId, 32, "runId")); json(res, 200, { requested: true });
      } else if (url.pathname === "/api/schedule") {
        keys(input, ["id", "enabled"], "schedule");
        if (typeof input.enabled !== "boolean") throw new Error("enabled must be boolean");
        fleet.schedule(text(input.id, 48, "id"), input.enabled); json(res, 200, { updated: true });
      } else if (url.pathname === "/api/reload") {
        keys(input, [], "reload");
        fleet.reload(); json(res, 200, { reloaded: true });
      } else json(res, 404, { error: "Not found" });
    })().catch(error => {
      if (!res.headersSent) json(res, 400, { error: error instanceof Error ? error.message : String(error) });
      else res.end();
    });
  });
  server.requestTimeout = 10000;
  server.headersTimeout = 10000;
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") { reject(new Error("Missing server address")); return; }
      origin = `http://127.0.0.1:${address.port}`;
      resolve();
    });
  });
  const broadcast = () => {
    for (const client of clients) {
      if (!client.write(`event: changed\ndata: ${Date.now()}\n\n`)) { clients.delete(client); client.end(); }
    }
  };
  fleet.on("changed", broadcast);
  const heartbeat = setInterval(broadcast, 5000);
  return {
    origin,
    async close() {
      clearInterval(heartbeat);
      fleet.off("changed", broadcast);
      for (const client of clients) client.end();
      clients.clear();
      await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    },
  };
}
