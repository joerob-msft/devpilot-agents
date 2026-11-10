// DevPilot Operations canvas for the GitHub Copilot app.
// Attaches to this repository's Golden watch (a terminal `Watch-DevPilotAgents.ps1 -Golden -CanvasBridge`
// or a headless one the user started from this canvas). Starting or stopping a watch and starting a
// run always need a human click in the canvas; no agent action can do any of them.
// Never use console.log here: stdout is the extension JSON-RPC channel.
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
    const canStartWatch = connection.launcher?.available === true && connection.launch?.state !== "starting";
    return {
      connected: false,
      state: connection.state,
      error: connection.error ?? "",
      repositoryRoots: connection.repositoryRoots,
      canStartWatch,
      watchLaunch: connection.launch ? { state: connection.launch.state, logPath: connection.launch.logPath } : null,
      howToStart: canStartWatch
        ? "Ask the user to open the DevPilot Operations canvas, preview the launch plan and click Start. Agents cannot start a watch."
        : connection.launcher?.reason ? `${connection.launcher.reason} Or run in a terminal: ${connection.command}` : connection.command,
      otherWatches: connection.others,
    };
  }
  return {
    connected: true,
    consumerRepositoryRoot: data.consumerRepositoryRoot,
    launchMode: data.launchMode,
    watchHeadless: data.headless === true,
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
      description: "Start, watch and stop this repository's DevPilot Golden watch (reviewer/review-handler agents) and stage a PR review that the user confirms.",
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
          status: connection.state === "connected"
            ? `${connection.bridge?.launchMode ?? ""} watch${connection.bridge?.headless ? " (canvas)" : ""}`.trim()
            : "No watch",
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
