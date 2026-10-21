import fs from "node:fs";

const args = process.argv.slice(2);
const logPath = process.env.DEVPILOT_STALE_PR_FAKE_AZ_LOG;
if (!logPath) {
  throw new Error("Fake Azure CLI log path was not configured.");
}
const inputIndex = args.indexOf("--in-file");
if (inputIndex < 0 || inputIndex + 1 >= args.length) {
  throw new Error("Fake Azure CLI expected --in-file.");
}
const inputPath = args[inputIndex + 1];
const bytes = fs.readFileSync(inputPath);
const record = {
  arguments: args,
  inputPath,
  inputExistsDuringProcess: fs.existsSync(inputPath),
  bodyBase64: bytes.toString("base64"),
  bodyLength: bytes.length,
};
fs.writeFileSync(logPath, JSON.stringify(record), { encoding: "utf8" });

const requestedExit = process.env.DEVPILOT_STALE_PR_FAKE_AZ_EXIT;
if (requestedExit) {
  const exitCode = Number.parseInt(requestedExit, 10);
  if (!Number.isInteger(exitCode) || exitCode === 0) {
    throw new Error("Fake Azure CLI exit code was invalid.");
  }
  process.stdout.write("RAW-SECRET-MARKER-STDOUT\n");
  process.exit(exitCode);
}
process.stdout.write('{"status":"abandoned"}\n');
