// DevPilot Operations canvas for the GitHub Copilot app (prototype).
// Attaches to a Golden watch started with `Watch-DevPilotAgents.ps1 -Golden -CanvasBridge` for the
// session's repository. Starting work always needs a human click in the canvas; no agent action
// can start a run. Never use console.log here: stdout is the extension JSON-RPC channel.
import { createCanvas, joinSession } from "@github/copilot-sdk/extension";
import { CanvasInstanceServer } from "./canvas-server.mjs";

const servers = new Map();
let session;

function log(message, level = "info") {
  try {
    const result = session?.log(message, { level, ephemeral: true });
    result?.catch?.(() => {});
  } catch {
    // Logging is best effort.
  }
}

async function ensureServer(ctx) {
  let server = servers.get(ctx.instanceId);
  if (!server) {
    server = new CanvasInstanceServer({ workingDirectory: ctx.session?.workingDirectory || process.cwd(), log });
    await server.start();
    servers.set(ctx.instanceId, server);
  }
  return server;
}

function applyPrefill(server, input) {
  const pullRequestId = Number(input?.pullRequestId);
  if (Number.isSafeInteger(pullRequestId) && pullRequestId > 0) server.setPrefill(pullRequestId, input?.role);
}

function summarize(state) {
  const { connection, data } = state;
  if (!data) {
    return {
      connected: false,
      state: connection.state,
      error: connection.error ?? "",
      repositoryRoots: connection.repositoryRoots,
      howToStart: connection.command,
      otherWatches: connection.others,
    };
  }
  return {
    connected: true,
    consumerRepositoryRoot: data.consumerRepositoryRoot,
    launchMode: data.launchMode,
    automation: data.automation,
    instances: data.instances.map((item) => ({
      agent: item.agent,
      status: item.status,
      pullRequestId: item.pullRequestId || null,
      title: item.pullRequestTitle,
      phase: item.phase,
      phaseElapsedSeconds: Math.round(item.phaseElapsedMilliseconds / 1000),
      completion: item.completion ? { result: item.completion.result, summary: item.completion.summary } : null,
      blocked: item.blocked?.reason ?? null,
    })),
    canvasRuns: data.runs.map((run) => ({
      role: run.role, pullRequestId: run.pullRequestId, headline: run.headline, detail: run.detail, elapsed: run.elapsed,
    })),
    queued: data.queued,
  };
}

session = await joinSession({
  canvases: [
    createCanvas({
      id: "devpilot-ops",
      displayName: "DevPilot Operations",
      description: "Watch DevPilot reviewer/review-handler agents for this repository's Golden watch and stage a PR review that the user confirms.",
      inputSchema: {
        type: "object",
        properties: {
          pullRequestId: { type: "integer", minimum: 1, description: "Optional PR to pre-fill in the Review a PR form." },
          role: { type: "string", enum: ["reviewer", "review-handler"] },
        },
        additionalProperties: false,
      },
      actions: [
        {
          name: "get_status",
          description: "Read the connected DevPilot watch: automation state, agent instances, and runs started from this canvas.",
          inputSchema: {
            type: "object",
            properties: { view: { type: "string", enum: ["current", "live", "history"] } },
            additionalProperties: false,
          },
          handler: async (ctx) => summarize(await (await ensureServer(ctx)).state(ctx.input?.view ?? "current")),
        },
        {
          name: "prepare_review",
          description: "Pre-fill the canvas 'Review a PR' form. This never starts work: the user must preview and click Start in the canvas.",
          inputSchema: {
            type: "object",
            properties: {
              pullRequestId: { type: "integer", minimum: 1 },
              role: { type: "string", enum: ["reviewer", "review-handler"] },
            },
            required: ["pullRequestId"],
            additionalProperties: false,
          },
          handler: async (ctx) => {
            const server = await ensureServer(ctx);
            applyPrefill(server, ctx.input);
            return {
              ok: true,
              message: `The DevPilot canvas form is pre-filled with PR ${ctx.input?.pullRequestId}. Ask the user to review the preview and click Start; nothing has been started.`,
            };
          },
        },
      ],
      open: async (ctx) => {
        const server = await ensureServer(ctx);
        applyPrefill(server, ctx.input);
        const { connection } = await server.state("live").catch(() => ({ connection: { state: "error" } }));
        return {
          title: "DevPilot Operations",
          status: connection.state === "connected" ? `${connection.bridge?.launchMode ?? ""} watch`.trim() : "No watch",
          url: server.url,
        };
      },
      onClose: async (ctx) => {
        servers.get(ctx.instanceId)?.close();
        servers.delete(ctx.instanceId);
      },
    }),
  ],
});
