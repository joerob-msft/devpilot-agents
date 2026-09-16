import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { noLinks, scopedFile } from "./manifest.js";
import type { Manifest } from "./contracts.js";

export function scaffold(repository: string, input = "README.md"): void {
  scopedFile(repository, input);
  const folder = path.join(repository, ".devpilot");
  if (existsSync(folder)) throw new Error(".devpilot already exists; refusing to overwrite repository configuration");
  noLinks(repository);
  const manifest: Manifest = {
    schemaVersion: 1,
    inputProfiles: { "repo-packet": { files: [input] } },
    agents: [
      { id: "repo-efficiency", prompt: ".devpilot/prompts/repo-efficiency.md", inputProfile: "repo-packet",
        timeoutSeconds: 600, schedule: { enabled: false, everyMinutes: 60 } },
      { id: "toolkit-maintainer", prompt: ".devpilot/prompts/toolkit-maintainer.md", inputProfile: "repo-packet",
        timeoutSeconds: 600, schedule: { enabled: false, everyMinutes: 60 } },
    ],
    swarms: [{ id: "improvement-review", workers: ["repo-efficiency", "toolkit-maintainer"],
      synthesisPrompt: ".devpilot/prompts/synthesis.md" }],
  };
  mkdirSync(path.join(folder, "prompts"), { recursive: true });
  writeFileSync(path.join(folder, "fleet.json"), JSON.stringify(manifest, null, 2) + "\n", { flag: "wx" });
  writeFileSync(path.join(folder, "prompts", "repo-efficiency.md"),
    "# Repository efficiency\n\nReview the supplied files for agent navigation, instruction clarity, and build/test discoverability. " +
    "Return up to three specific improvements with exact packet evidence. Do not invent missing source or claim tests ran.\n", { flag: "wx" });
  writeFileSync(path.join(folder, "prompts", "toolkit-maintainer.md"),
    "# Toolkit maintainer\n\nReview the supplied files for maintainability, operational clarity, and safe extension points. " +
    "Return up to three concrete proposals backed by packet evidence. Do not modify code or your own runtime.\n", { flag: "wx" });
  writeFileSync(path.join(folder, "prompts", "synthesis.md"),
    "# Synthesis\n\nCombine the supplied worker result artifacts into one prioritized improvement proposal. " +
    "Deduplicate overlapping findings, preserve disagreements and missing context, and cite worker artifact paths. " +
    "Do not claim independent verification of worker statements.\n", { flag: "wx" });
}
