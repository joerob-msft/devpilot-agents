import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { EventTailer } from "../src/tailer.js";

const [root, eventLogPath] = process.argv.slice(2);
if (!root || !eventLogPath) throw new Error("tailer process fixture requires root and event log paths");

const tailer = new EventTailer({
  stateDirectories: [],
  eventLogPaths: [eventLogPath],
  pollMilliseconds: 20,
  onEvent: (event) => {
    if (event.sequence === 1) {
      void writeFile(join(root, "ready"), "", "utf8");
    } else if (event.sequence === 2) {
      void writeFile(join(root, "observed"), "", "utf8").then(() => tailer.stop());
    }
  },
  onDiagnostic: () => {},
});

tailer.start();
