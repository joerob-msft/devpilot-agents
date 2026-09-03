import { createCliRenderer } from "@opentui/core";
import { render } from "@opentui/solid";
import { App } from "./app.js";
import { DispatchClient, type BrokerLaunchDescriptor } from "./dispatch.js";
import { PullRequestHistoryProjection } from "./history.js";
import { createDashboardLifecycle } from "./lifecycle.js";
import { OperationsReducer } from "./reducer.js";
import { EventTailer } from "./tailer.js";

interface Arguments {
  stateDirectories: string[];
  eventLogPaths: string[];
  broker: BrokerLaunchDescriptor | null;
}

export function parseArguments(argv: string[]): Arguments {
  const result: Arguments = { stateDirectories: [], eventLogPaths: [], broker: null };
  const broker: Partial<BrokerLaunchDescriptor> = {};
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (argument === "--state-dir" || argument === "--event-log") {
      const value = argv[++index];
      if (!value) throw new Error(`${argument} requires a path`);
      if (argument === "--state-dir") result.stateDirectories.push(value);
      else result.eventLogPaths.push(value);
    } else if (argument === "--broker-executable" || argument === "--broker-script" || argument === "--broker-descriptor") {
      const value = argv[++index];
      if (!value) throw new Error(`${argument} requires a path`);
      if (argument === "--broker-executable") broker.executablePath = value;
      else if (argument === "--broker-script") broker.scriptPath = value;
      else broker.descriptorPath = value;
    } else if (argument === "--help" || argument === "-h") {
      process.stdout.write(
        "Usage: npm start -- [--state-dir <path>]... [--event-log <path>]...\n" +
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
  if (!result.stateDirectories.length && !result.eventLogPaths.length && process.exitCode === undefined) {
    throw new Error("provide at least one --state-dir or --event-log path");
  }
  return result;
}

async function main(): Promise<void> {
  const args = parseArguments(process.argv.slice(2));
  if (process.exitCode !== undefined) return;
  const reducer = new OperationsReducer();
  const history = new PullRequestHistoryProjection();
  let brokerFailure = "";
  let refresh = (): void => {};
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
  });
  const broker = args.broker
    ? new DispatchClient(args.broker, {
        onAcceptedEventPath: (path) => tailer.registerEventLogPath(path),
        onTerminal: () => refresh(),
        onBrokerFailure: (message) => {
          brokerFailure = message;
          refresh();
        },
      })
    : undefined;
  const lifecycle = createDashboardLifecycle(tailer, broker);
  const renderer = await createCliRenderer({
    screenMode: "alternate-screen",
    clearOnShutdown: true,
    exitOnCtrlC: true,
    consoleMode: "disabled",
    backgroundColor: "#08090a",
    onDestroy: lifecycle.onRendererDestroy,
  });

  try {
    tailer.start();
    await render(() => <App
      reducer={reducer}
      history={history}
      tailer={tailer}
      broker={broker}
      brokerFailure={() => brokerFailure}
      shutdownBroker={lifecycle.shutdownBroker}
    />, renderer);
    refresh = () => renderer.requestRender();
  } catch (error) {
    await tailer.stop();
    await lifecycle.shutdownBroker();
    if (!renderer.isDestroyed) renderer.destroy();
    throw error;
  }
}

main().catch((error) => {
  process.stderr.write(`DevPilot dashboard failed: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
