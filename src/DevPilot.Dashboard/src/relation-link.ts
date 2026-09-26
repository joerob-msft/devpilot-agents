import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { buildAzureDevOpsLinks, type RelationSummary, type ReportingConfiguration } from "./reporting.js";

const execFileAsync = promisify(execFile);
const ADO_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798";
type RecordValue = Record<string, unknown>;
export type RelationReadJson = (url: URL) => Promise<unknown>;

function record(value: unknown): RecordValue {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as RecordValue : {};
}

function sha(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{40}$/.test(value)) {
    throw new Error("Azure DevOps head commit is invalid");
  }
  return value;
}

function positive(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function filePath(value: string): string {
  if (!value || value.length > 1_024 || value.startsWith("/") || value.includes("\\") ||
      value.split("/").some((part) => !part || part === "." || part === "..") ||
      /[\u0000-\u001f\u007f?#]/.test(value)) {
    throw new Error("Relation file path is invalid");
  }
  return `/${value}`;
}

async function signedInReader(): Promise<RelationReadJson> {
  let token: string;
  try {
    const args = [
      "account", "get-access-token", "--resource", ADO_RESOURCE, "--query", "accessToken", "-o", "tsv",
    ];
    const windows = process.platform === "win32";
    const result = await execFileAsync(windows ? "cmd.exe" : "az", windows
      ? ["/d", "/s", "/c", `az ${args.join(" ")}`] : args, {
      windowsHide: true,
      timeout: 10_000,
      maxBuffer: 16_384,
    });
    token = result.stdout.trim();
    if (!/^[A-Za-z0-9_.-]+$/.test(token)) throw new Error("invalid token");
  } catch {
    throw new Error("Existing Azure DevOps sign-in is unavailable; no link was opened");
  }
  return async (url) => {
    let response: Response;
    try {
      response = await fetch(url, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
        redirect: "error",
        cache: "no-store",
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      throw new Error("Azure DevOps read failed; no link was opened");
    }
    if (!response.ok) {
      throw new Error(`Azure DevOps read returned HTTP ${response.status}; no link was opened`);
    }
    if (Number(response.headers.get("content-length")) > 2_097_152) {
      throw new Error("Azure DevOps response exceeds the read budget");
    }
    if (!response.body) throw new Error("Azure DevOps response has no body");
    const stream = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let bytes = 0;
    while (true) {
      const { done, value } = await stream.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 2_097_152) {
        await stream.cancel();
        throw new Error("Azure DevOps response exceeds the read budget");
      }
      chunks.push(value);
    }
    const text = new TextDecoder().decode(Buffer.concat(chunks));
    try {
      return JSON.parse(text) as unknown;
    } catch {
      throw new Error("Azure DevOps response was not JSON");
    }
  };
}

interface CurrentHead {
  iteration: number;
  source: string;
  target: string;
  ref: string;
}

function currentHead(prValue: unknown, iterationsValue: unknown, relation: RelationSummary,
  config: NonNullable<ReportingConfiguration["azureDevOps"]>): CurrentHead {
  const pr = record(prValue);
  const repository = record(pr.repository);
  if (pr.pullRequestId !== relation.pullRequestId || pr.status !== "active" || pr.isDraft !== false ||
      repository.id !== config.repositoryId || record(repository.project).id !== config.projectId ||
      pr.targetRefName !== relation.targetRef) {
    throw new Error("Azure DevOps PR identity, status, or target ref changed");
  }
  const iterations = record(iterationsValue);
  if (!Array.isArray(iterations.value) || !iterations.value.length ||
      iterations.value.some((entry) => !positive(record(entry).id))) {
    throw new Error("Current Azure DevOps iteration is unavailable");
  }
  const latest = record(iterations.value.at(-1));
  const iteration = latest.id;
  if (!positive(iteration) || iterations.value.some((entry) => (record(entry).id as number) > iteration)) {
    throw new Error("Current Azure DevOps iteration is ambiguous");
  }
  const source = sha(record(latest.sourceRefCommit).commitId);
  const target = sha(record(latest.targetRefCommit).commitId);
  if (source !== sha(record(pr.lastMergeSourceCommit).commitId) ||
      target !== sha(record(pr.lastMergeTargetCommit).commitId)) {
    throw new Error("Azure DevOps PR and latest iteration heads disagree");
  }
  return { iteration, source, target, ref: pr.targetRefName as string };
}

export async function resolveCurrentRelationLink(
  relation: RelationSummary,
  config: ReportingConfiguration,
  reader?: RelationReadJson,
): Promise<string> {
  const ado = config.azureDevOps;
  if (!ado || !relation.projectId || !relation.repositoryId ||
      relation.projectId !== ado.projectId || relation.repositoryId !== ado.repositoryId ||
      !positive(relation.pullRequestId) || !/^[0-9a-f]{40}$/.test(relation.sourceCommit) ||
      !/^[0-9a-f]{40}$/.test(relation.targetCommit) ||
      !/^refs\/heads\/[A-Za-z0-9._/-]+$/.test(relation.targetRef)) {
    throw new Error("Relation has no verified durable PR identity");
  }
  const path = filePath(relation.path);
  if (!positive(relation.line) || relation.line >= Number.MAX_SAFE_INTEGER) {
    throw new Error("Relation line is invalid");
  }
  const links = buildAzureDevOpsLinks({
    ...ado, expectedProjectId: ado.projectId, expectedRepositoryId: ado.repositoryId,
    projectId: relation.projectId, repositoryId: relation.repositoryId,
    pullRequestId: relation.pullRequestId,
  });
  const prUrl = new URL(links.prUrl);
  const repositoryApi = `${prUrl.origin}${prUrl.pathname.replace(/\/_git\/.*$/, "")}` +
    `/_apis/git/repositories/${encodeURIComponent(ado.repositoryId)}`;
  const pullRequestApi = `${repositoryApi}/pullRequests/${relation.pullRequestId}`;
  const request = (resource: string, params: Record<string, string> = {}): URL => {
    const url = new URL(resource);
    url.searchParams.set("api-version", "7.1");
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
    return url;
  };
  const read = reader ?? await signedInReader();
  const fetchHead = async () => {
    const pr = await read(request(pullRequestApi));
    const iterations = await read(request(`${pullRequestApi}/iterations`));
    return currentHead(pr, iterations, relation, ado);
  };
  const head = await fetchHead();
  let skip = 0;
  let matched = false;
  for (let page = 0; page < 20; page++) {
    const changes = record(await read(request(`${pullRequestApi}/iterations/${head.iteration}/changes`, {
      "$compareTo": "0", "$top": "2000", "$skip": String(skip),
    })));
    if (!Array.isArray(changes.changeEntries)) throw new Error("Iteration changes are unavailable");
    matched ||= changes.changeEntries.some((entry) => {
      const change = record(entry);
      return record(change.item).path === path && change.changeType !== "delete";
    });
    if (changes.nextSkip === 0 || (changes.nextSkip == null && changes.changeEntries.length < 2_000)) break;
    if (!positive(changes.nextSkip) || changes.nextSkip <= skip || page === 19) {
      throw new Error("Iteration changes pagination is invalid or incomplete");
    }
    skip = changes.nextSkip;
  }
  if (!matched) throw new Error("Relation file is absent from the current PR iteration");
  const item = record(await read(request(`${repositoryApi}/items`, {
    path,
    "versionDescriptor.versionType": "commit",
    "versionDescriptor.version": head.source,
    includeContent: "true",
    "$format": "json",
  })));
  if (item.path !== path || item.gitObjectType !== "blob" || typeof item.content !== "string" ||
      item.content.split("\n").length < relation.line ||
      !item.content.split("\n")[relation.line - 1]?.trim()) {
    throw new Error("Relation line is not anchored in the current source file");
  }
  const verified = await fetchHead();
  if (verified.iteration !== head.iteration || verified.source !== head.source ||
      verified.target !== head.target || verified.ref !== head.ref) {
    throw new Error("Azure DevOps PR head changed during verification");
  }
  const branch = verified.ref.slice("refs/heads/".length);
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  return `${prUrl.origin}${prUrl.pathname}?path=${encodedPath}&version=GB${encodeURIComponent(branch)}` +
    `&line=${relation.line}&lineEnd=${relation.line + 1}&lineStartColumn=1&lineEndColumn=1` +
    `&type=2&lineStyle=plain&_a=files&iteration=${verified.iteration}&base=0`;
}
