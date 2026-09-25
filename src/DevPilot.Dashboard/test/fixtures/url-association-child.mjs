import { writeFileSync } from "node:fs";

writeFileSync(
  process.env.DEVPILOT_DASHBOARD_URL_TEST_OUTPUT,
  process.env.DEVPILOT_DASHBOARD_OPEN_URL ?? "",
  "utf8",
);
process.exitCode = Number(process.env.DEVPILOT_DASHBOARD_URL_TEST_EXIT ?? "0");
