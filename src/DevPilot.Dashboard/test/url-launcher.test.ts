import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  WINDOWS_ASSOCIATION_ARGUMENTS_ENVIRONMENT_NAME,
  WINDOWS_ASSOCIATION_LAUNCHER_ENVIRONMENT_NAME,
  WINDOWS_URL_ENVIRONMENT_NAME,
  createUrlLaunchPlan,
  executeUrlLaunchPlan,
  safeHttpUrl,
  type UrlLaunchPlan,
} from "../src/url-launcher.js";

const metacharacterUrl =
  "https://dev.azure.com/example/Project%20Name/_git/repo/pullrequest/42?_a=files&discussionId=100&path=%2Ftests%2FWidget%20Tests.cs&query=%E6%9D%B1%E4%BA%AC";

test("Windows launch plan passes the validated URL only through environment data", () => {
  const normalized = safeHttpUrl(metacharacterUrl);
  assert.ok(normalized);
  const plan = createUrlLaunchPlan(metacharacterUrl, {
    platform: "win32",
    environment: { PATH: "fixture-path", KEEP: "fixture-value" },
    windowsPowerShellExecutable: "C:\\PowerShell\\pwsh.exe",
  });
  assert.equal(plan.command, "C:\\PowerShell\\pwsh.exe");
  assert.deepEqual(plan.args.slice(0, 4), ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command"]);
  assert.equal(plan.args.length, 5);
  assert.doesNotMatch(plan.args[4]!, /dev\.azure\.com|discussionId|Widget/);
  assert.equal(plan.options.shell, false);
  assert.equal(plan.options.detached, false);
  assert.equal(plan.completion, "exit");
  assert.equal(plan.options.env?.[WINDOWS_URL_ENVIRONMENT_NAME], normalized);
  assert.equal(plan.options.env?.KEEP, "fixture-value");
  assert.equal(plan.options.env?.[WINDOWS_ASSOCIATION_LAUNCHER_ENVIRONMENT_NAME], undefined);
  assert.equal(plan.options.env?.[WINDOWS_ASSOCIATION_ARGUMENTS_ENVIRONMENT_NAME], undefined);
});

test("macOS and Linux launch plans retain detached direct opener behavior", () => {
  for (const [platform, command] of [["darwin", "open"], ["linux", "xdg-open"]] as const) {
    const plan = createUrlLaunchPlan(metacharacterUrl, { platform });
    assert.equal(plan.command, command);
    assert.deepEqual(plan.args, [safeHttpUrl(metacharacterUrl)]);
    assert.equal(plan.options.detached, true);
    assert.equal(plan.options.shell, false);
    assert.equal(plan.completion, "spawn");
  }
});

test("URL launch execution rejects spawn errors, nonzero exits, and timeouts", async () => {
  const missing: UrlLaunchPlan = {
    command: join(tmpdir(), `missing-url-launcher-${Date.now()}.exe`),
    args: [],
    options: { shell: false, stdio: "ignore" },
    completion: "exit",
    timeoutMilliseconds: 2_000,
  };
  await assert.rejects(executeUrlLaunchPlan(missing), /ENOENT|not found/i);

  const nonzero: UrlLaunchPlan = {
    command: process.execPath,
    args: ["-e", "process.exit(7)"],
    options: { shell: false, stdio: "ignore" },
    completion: "exit",
    timeoutMilliseconds: 5_000,
  };
  await assert.rejects(executeUrlLaunchPlan(nonzero), /exited with code 7/);

  const timeout: UrlLaunchPlan = {
    command: process.execPath,
    args: ["-e", "setTimeout(() => {}, 10000)"],
    options: { shell: false, stdio: "ignore" },
    completion: "exit",
    timeoutMilliseconds: 100,
  };
  await assert.rejects(executeUrlLaunchPlan(timeout), /timed out after 100 ms/);
});

test("Windows shell-association integration preserves metacharacter URL data and exit status", {
  skip: process.platform !== "win32",
}, async () => {
  const root = await mkdtemp(join(tmpdir(), "devpilot-url-launch-"));
  const output = join(root, "opened-url.txt");
  const fixture = join(process.cwd(), "test", "fixtures", "url-association-child.mjs");
  try {
    const plan = createUrlLaunchPlan(metacharacterUrl, {
      platform: "win32",
      windowsPowerShellExecutable: "pwsh.exe",
      windowsAssociationLauncher: {
        command: process.execPath,
        args: [fixture],
        environment: {
          DEVPILOT_DASHBOARD_URL_TEST_OUTPUT: output,
          DEVPILOT_DASHBOARD_URL_TEST_EXIT: "0",
        },
      },
    });
    assert.equal(plan.options.env?.[WINDOWS_ASSOCIATION_LAUNCHER_ENVIRONMENT_NAME], process.execPath);
    assert.equal(
      plan.options.env?.[WINDOWS_ASSOCIATION_ARGUMENTS_ENVIRONMENT_NAME],
      JSON.stringify([fixture]),
    );
    await executeUrlLaunchPlan(plan);
    assert.equal(await readFile(output, "utf8"), safeHttpUrl(metacharacterUrl));

    const failed = createUrlLaunchPlan(metacharacterUrl, {
      platform: "win32",
      windowsPowerShellExecutable: "pwsh.exe",
      windowsAssociationLauncher: {
        command: process.execPath,
        args: [fixture],
        environment: {
          DEVPILOT_DASHBOARD_URL_TEST_OUTPUT: output,
          DEVPILOT_DASHBOARD_URL_TEST_EXIT: "9",
        },
      },
    });
    await assert.rejects(executeUrlLaunchPlan(failed), /exited with code 9/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
