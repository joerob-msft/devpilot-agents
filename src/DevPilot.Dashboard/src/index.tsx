import { createCliRenderer } from "@opentui/core";
import { render } from "@opentui/solid";
import { App, type LaunchMode } from "./app.js";
import { CanvasBridge } from "./canvas-bridge.js";
import { DispatchClient, type BrokerLaunchDescriptor } from "./dispatch.js";
import { PullRequestHistoryProjection } from "./history.js";
import { createDashboardLifecycle, type DashboardLifecycle } from "./lifecycle.js";
import { OperationsReducer } from "./reducer.js";
import { EventTailer } from "./tailer.js";
import { FileDismissalStorage } from "./dismissals.js";
import packageInfo from "../package.json" with { type: "json" };

interface Arguments {
  stateDirectories: string[];
  eventLogPaths: string[];
  broker: BrokerLaunchDescriptor | null;
  launchMode: LaunchMode;
  headless: boolean;
  viewStateDirectory?: string;
}

export function parseArguments(argv: string[]): Arguments {
  const result: Arguments = {
    stateDirectories: [],
    eventLogPaths: [],
    broker: null,
    launchMode: "observe",
    headless: false,
  };
  const broker: Partial<BrokerLaunchDescriptor> = {};
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (argument === "--state-dir" || argument === "--event-log") {
      const value = argv[++index];
      if (!value) throw new Error(`${argument} requires a path`);
      if (argument === "--state-dir") result.stateDirectories.push(value);
      else result.eventLogPaths.push(value);
    } else if (argument === "--view-state-dir") {
      const value = argv[++index];
      if (!value) throw new Error("--view-state-dir requires a path");
      result.viewStateDirectory = value;
    } else if (argument === "--launch-mode") {
      const value = argv[++index];
      if (value !== "observe" && value !== "preview" && value !== "operational") {
        throw new Error("--launch-mode requires observe, preview, or operational");
      }
      result.launchMode = value;
    } else if (argument === "--headless") {
      if (result.headless) throw new Error("--headless may be given only once");
      result.headless = true;
    } else if (argument === "--broker-executable" || argument === "--broker-script" || argument === "--broker-descriptor") {
      const value = argv[++index];
      if (!value) throw new Error(`${argument} requires a path`);
      if (argument === "--broker-executable") broker.executablePath = value;
      else if (argument === "--broker-script") broker.scriptPath = value;
      else broker.descriptorPath = value;
    } else if (argument === "--help" || argument === "-h") {
      process.stdout.write(
        "Usage: npm start -- [--state-dir <path>]... [--event-log <path>]... [--launch-mode <observe|preview|operational>]\n" +
          "  [--headless] runs the trusted broker and canvas bridge without a terminal UI (Watch -Headless only).\n" +
          "  [--view-state-dir <path>] overrides local dashboard dismissal storage only.\n" +
          "Observe DevPilot reviewer and review-handler JSONL event streams.\n",
      );
      process.exitCode = 0;
      return result;
    } else if (argument?.startsWith("-")) {
      throw new Error(`unknown argument: ${argument}`);
    } else if (argument) {
      result.stateDirectories.push(argument);
    }
  }
  const brokerValues = Object.values(broker);
  if (brokerValues.length && brokerValues.length !== 3) throw new Error("all trusted broker arguments are required together");
  if (brokerValues.length === 3) result.broker = broker as BrokerLaunchDescriptor;
  if (result.headless && !result.broker) throw new Error("--headless requires the trusted broker arguments");
  if (!result.stateDirectories.length && !result.eventLogPaths.length && process.exitCode === undefined) {
    throw new Error("provide at least one --state-dir or --event-log path");
  }
  return result;
}

async function main(): Promise<void> {
  const args = parseArguments(process.argv.slice(2));
  if (process.exitCode !== undefined) return;
  // Opt-in Copilot canvas bridge (Watch -CanvasBridge). Read and cleared before the broker is
  // spawned so neither the broker nor its agent children inherit the bridge location.
  const canvasBridgeFile = process.env.DEVPILOT_CANVAS_BRIDGE_FILE ?? "";
  const consumerRepositoryRoot = process.env.DEVPILOT_CONSUMER_REPOSITORY_ROOT ?? "";
  delete process.env.DEVPILOT_CANVAS_BRIDGE_FILE;
  delete process.env.DEVPILOT_CONSUMER_REPOSITORY_ROOT;
  if (args.headless && !canvasBridgeFile) {
    throw new Error("--headless requires the canvas bridge (Watch -Headless -CanvasBridge)");
  }
  process.stdout.write(`DevPilot Operations v${packageInfo.version}${args.headless ? " (headless)" : ""}\n`);
  const dismissalStorage = new FileDismissalStorage(args.viewStateDirectory);
  let dismissalError = "";
  const reducer = await dismissalStorage.load()
    .then((records) => new OperationsReducer(records))
    .catch((error: unknown) => {
      dismissalError = `Could not load dismissed instances: ${error instanceof Error ? error.message : String(error)}`;
      return new OperationsReducer();
    });
  const history = new PullRequestHistoryProjection();
  let brokerFailure = "";
  let refresh = (): void => {};
  let stopHeadless: (code: number) => void = () => {};
  const tailer = new EventTailer({
    stateDirectories: args.stateDirectories,
    eventLogPaths: args.eventLogPaths,
    onEvent(event, source) {
      const changed = reducer.apply(event, source);
      const historyChanged = history.apply(event);
      if (changed || historyChanged) refresh();
    },
    onDiagnostic(diagnostic) {
      reducer.addSourceDiagnostic(diagnostic);
      refresh();
    },
    async onPoll() {
      if (await reducer.observeProcesses()) refresh();
    },
  });
  const broker = args.broker
    ? new DispatchClient(args.broker, {
        onAcceptedEventPath: (path) => tailer.registerEventLogPath(path),
        onLocalStreams: (streams) => {
          for (const stream of streams) {
            reducer.registerLocalStream(stream);
            tailer.registerEventLogPath(stream.eventLogPath);
          }
        },
        onTerminal: () => refresh(),
        onBrokerFailure: (message) => {
          brokerFailure = message;
          refresh();
          if (args.headless) {
            process.stderr.write(`DevPilot headless owner stopping: ${message}\n`);
            stopHeadless(1);
          }
        },
      })
    : undefined;
  const lifecycle = createDashboardLifecycle(tailer, broker);
  const canvasBridge = canvasBridgeFile && broker
    ? new CanvasBridge({
        discoveryFile: canvasBridgeFile, consumerRepositoryRoot, launchMode: args.launchMode, broker, reducer, tailer,
        onShutdown: args.headless ? () => stopHeadless(0) : undefined,
      })
    : undefined;
  const stopCanvasBridge = (): void => canvasBridge?.stop();
  process.once("exit", stopCanvasBridge);
  if (args.headless) {
    await runHeadlessOwner(lifecycle, stopCanvasBridge, (stop) => { stopHeadless = stop; }, async () => {
      tailer.start();
      await canvasBridge?.start();
    });
    return;
  }
  const renderer = await createCliRenderer({
    screenMode: "alternate-screen",
    clearOnShutdown: true,
    exitOnCtrlC: true,
    consoleMode: "disabled",
    backgroundColor: "#08090a",
    onDestroy: () => {
      stopCanvasBridge();
      lifecycle.onRendererDestroy();
    },
  });

  try {
    tailer.start();
    await canvasBridge?.start();
    await render(() => <App
      reducer={reducer}
      history={history}
      tailer={tailer}
      broker={broker}
      launchMode={args.launchMode}
      brokerFailure={() => brokerFailure}
      shutdownTailer={lifecycle.shutdownTailer}
      shutdownBroker={lifecycle.shutdownBroker}
      exitProcess={(code) => process.exit(code)}
      dismissalStorage={dismissalStorage}
      dismissalLoadError={dismissalError}
    />, renderer);
    refresh = () => renderer.requestRender();
  } catch (error) {
    stopCanvasBridge();
    await lifecycle.shutdownTailer();
    await lifecycle.shutdownBroker();
    if (!renderer.isDestroyed) renderer.destroy();
    throw error;
  }
}

// Canvas-started Golden owner: the same tailer, trusted broker and bridge as the TUI, with no
// renderer. It stays up until the canvas's Stop (POST /v1/shutdown), a signal, or broker failure.
async function runHeadlessOwner(
  lifecycle: DashboardLifecycle,
  stopCanvasBridge: () => void,
  registerStop: (stop: (code: number) => void) => void,
  start: () => Promise<void>,
): Promise<void> {
  let stopping = false;
  const stop = (code: number): void => {
    if (stopping) return;
    stopping = true;
    stopCanvasBridge();
    void Promise.allSettled([lifecycle.shutdownTailer(), lifecycle.shutdownBroker()])
      .finally(() => process.exit(code));
  };
  registerStop(stop);
  process.once("SIGINT", () => stop(0));
  process.once("SIGTERM", () => stop(0));
  try {
    await start();
  } catch (error) {
    stopCanvasBridge();
    await Promise.allSettled([lifecycle.shutdownTailer(), lifecycle.shutdownBroker()]);
    throw error;
  }
}

main().catch((error) => {
  process.stderr.write(`DevPilot dashboard failed: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
