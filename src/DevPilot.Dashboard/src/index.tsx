import { createCliRenderer } from "@opentui/core";
import { render } from "@opentui/solid";
import { App } from "./app.js";
import { OperationsReducer } from "./reducer.js";
import { EventTailer } from "./tailer.js";

interface Arguments {
  stateDirectories: string[];
  eventLogPaths: string[];
}

export function parseArguments(argv: string[]): Arguments {
  const result: Arguments = { stateDirectories: [], eventLogPaths: [] };
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (argument === "--state-dir" || argument === "--event-log") {
      const value = argv[++index];
      if (!value) throw new Error(`${argument} requires a path`);
      if (argument === "--state-dir") result.stateDirectories.push(value);
      else result.eventLogPaths.push(value);
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
  if (!result.stateDirectories.length && !result.eventLogPaths.length && process.exitCode === undefined) {
    throw new Error("provide at least one --state-dir or --event-log path");
  }
  return result;
}

async function main(): Promise<void> {
  const args = parseArguments(process.argv.slice(2));
  if (process.exitCode !== undefined) return;
  const reducer = new OperationsReducer();
  let refresh = (): void => {};
  const tailer = new EventTailer({
    stateDirectories: args.stateDirectories,
    eventLogPaths: args.eventLogPaths,
    onEvent(event, source) {
      if (reducer.apply(event, source)) refresh();
    },
    onDiagnostic(diagnostic) {
      reducer.addSourceDiagnostic(diagnostic);
      refresh();
    },
  });
  const renderer = await createCliRenderer({
    screenMode: "alternate-screen",
    clearOnShutdown: true,
    exitOnCtrlC: true,
    consoleMode: "disabled",
    backgroundColor: "#101319",
    onDestroy: () => void tailer.stop(),
  });

  try {
    tailer.start();
    await render(() => <App reducer={reducer} tailer={tailer} />, renderer);
    refresh = () => renderer.requestRender();
  } catch (error) {
    await tailer.stop();
    if (!renderer.isDestroyed) renderer.destroy();
    throw error;
  }
}

main().catch((error) => {
  process.stderr.write(`DevPilot dashboard failed: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
