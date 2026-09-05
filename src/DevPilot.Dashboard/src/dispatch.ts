import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { isAbsolute } from "node:path";
import { AGENTS, parseRepositoryIdentity, type AgentRole, type RepositoryIdentityV1 } from "./domain.js";

export const DISPATCH_PROTOCOL_MAX_BYTES = 65_536;

export interface BrokerLaunchDescriptor {
  executablePath: string;
  scriptPath: string;
  descriptorPath: string;
}

export interface PullRequestSnapshotV1 {
  schemaVersion: 1;
  pullRequestId: number;
  sourceCommit: string;
  sourceRef: string;
  targetRef: string;
  active: boolean;
  draft: boolean;
  author: string;
  title: string;
}

// operational-default is the un-narrowed, checked-in ceiling; machine/user/repo-worktree/pr match
// the outside-repository capability-override store's scopes (broad-to-narrow -- see
// Resolve-AgentEffectiveCapabilitySettings); kill-switch (PR3) marks every capability when the
// emergency override-disable sentinel is active, superseding whatever the store would otherwise
// report. Every value the broker can legitimately put on the wire must be listed here, or a real,
// correctly-narrowed profile/summary response is rejected outright by provenanceField below.
export const KNOWN_PROVENANCE = ["operational-default", "machine", "user", "repo-worktree", "pr", "kill-switch"] as const;
export type CapabilityProvenance = (typeof KNOWN_PROVENANCE)[number];

// PR3: the four persisted-narrowing scopes an operator can directly edit -- the same broad-to-narrow
// set KNOWN_PROVENANCE's machine/user/repo-worktree/pr values name, but as a closed request-side enum
// (never 'operational-default'/'kill-switch', which are provenance OUTCOMES, not editable targets).
export const NARROWING_SCOPES = ["machine", "user", "repo-worktree", "pr"] as const;
export type NarrowingScope = (typeof NARROWING_SCOPES)[number];

// Fixed action enum: 'off' narrows; 'inherit' resets that one capability back to whatever a
// broader scope (or the operational default) already provides. There is no 'on' -- this store is
// narrow-only by construction, never a path to widen a capability (see issue #105 charter).
export const NARROWING_ACTIONS = ["off", "inherit"] as const;
export type NarrowingAction = (typeof NARROWING_ACTIONS)[number];

// PR4 interactive widening protocol (issue #105): the checked-in delegation policy grants at most
// ONE capability per role (Get-AgentHarnessCapabilityDescriptor's delegableDefaultOff) -- there is
// no wildcard/allow-any escape hatch on the broker (Test-AgentDelegationAllows), so the client
// holds the identical closed mapping and rejects any other value outright, whether it is a
// capability the operator requests to widen or one a broker response claims is delegable. See
// assertDelegableCapability/assertDelegableAvailable below.
export const DELEGABLE_CAPABILITY_BY_ROLE: Record<AgentRole, string> = {
  reviewer: "EnableApprovalVote",
  "review-handler": "EnableAutoComplete",
};

export interface CapabilitySummary {
  schemaVersion: 1;
  requestId: string;
  operation: "capability-summary";
  role: AgentRole;
  dispatchDraftId: string;
  repositoryIdentity: RepositoryIdentityV1;
  prSnapshot: PullRequestSnapshotV1;
  capabilityPolicyDigest: string;
  prStateFingerprint: string;
  capabilities: string[];
  mandatoryDenies: string[];
  dynamicConstraints: string[];
  // Additive PR1 profile fields -- see Get-AgentHarnessCapabilityDescriptor. delegableAvailable is
  // empty unless the checked-in delegation policy explicitly allows this role's one delegable
  // capability for this repository (issue #105 PR4); the shipped policy ships with an empty
  // allowlist for every role, so this is @() in production until a CODEOWNERS-approved policy
  // change names a repository key. See DELEGABLE_CAPABILITY_BY_ROLE/assertDelegableAvailable.
  absoluteDenies: string[];
  allowedManualCapabilities: string[];
  delegableAvailable: string[];
  provenance: Record<string, CapabilityProvenance>;
  // PR3: true when the emergency kill switch is currently masking every persisted override for
  // this machine+user. capabilities/mandatoryDenies/provenance above already reflect that (ceiling
  // defaults, provenance 'kill-switch') -- this flag lets the UI additionally explain WHY.
  killSwitchActive: boolean;
  // PR3: ISO-8601 UTC timestamp for when the kill switch's short TTL (broker-enforced, recommended
  // 1 hour) expires, or null when the kill switch is inactive. Always present on the wire from a
  // PR3-or-newer broker (never silently optional here) -- see editingAvailable below for how a
  // pre-PR3 broker missing this entirely is instead detected and handled.
  killSwitchExpiresAtUtc: string | null;
  // Derived, not broker-authored: true only when allowedManualCapabilities, provenance, and
  // killSwitchActive were ALL actually present on the wire (i.e. this broker is new enough to
  // support narrowing/kill-switch editing at all). A capability marker for the UI to decide
  // whether to offer the editor -- never a trust signal about the (possibly-defaulted) field
  // values themselves, and never used to imply a broker-old response is a "trusted editable
  // profile".
  editingAvailable: boolean;
}

// Read-only effective-capability-profile inspection (PR1 issue #105): the Settings TUI's dedicated,
// side-effect-free counterpart to CapabilitySummary. The broker's `profile` operation never
// allocates a dispatchDraftId/config snapshot/$drafts entry, so this type intentionally has no
// dispatchDraftId/capabilityPolicyDigest/prStateFingerprint -- none is meaningful without a config
// snapshot to bind it to, and a distinct type is safer here than fake/optional draft identifiers
// that could be mistaken for something dispatch() can actually consume.
export interface CapabilityProfile {
  schemaVersion: 1;
  requestId: string;
  operation: "capability-profile";
  role: AgentRole;
  repositoryIdentity: RepositoryIdentityV1;
  prSnapshot: PullRequestSnapshotV1;
  capabilities: string[];
  mandatoryDenies: string[];
  dynamicConstraints: string[];
  absoluteDenies: string[];
  allowedManualCapabilities: string[];
  delegableAvailable: string[];
  provenance: Record<string, CapabilityProvenance>;
  killSwitchActive: boolean;
  killSwitchExpiresAtUtc: string | null;
  editingAvailable: boolean;
}

// PR3: the {capabilities, mandatoryDenies, provenance} triple describing one resolved effective
// profile -- shared shape for both the CURRENT (pre-change) and PROPOSED (post-hypothetical-change)
// halves of a narrowing preview, so a diff is always comparing two values of the identical type.
export interface CapabilityNarrowingEffect {
  capabilities: string[];
  mandatoryDenies: string[];
  provenance: Record<string, CapabilityProvenance>;
}

// Non-mutating preview/diff (PR3): never writes anything, never allocates a dispatch draft/config
// snapshot. previewToken + storeFingerprint bind this exact hypothetical mutation to the broker's
// in-memory record of it; applyNarrowing must echo both back unchanged, and the broker re-verifies
// repository/worktree/PR/source-commit/store-fingerprint identity before ever writing.
export interface CapabilityNarrowingPreview {
  schemaVersion: 1;
  requestId: string;
  operation: "narrowing-preview";
  state: "previewed";
  role: AgentRole;
  repositoryIdentity: RepositoryIdentityV1;
  prSnapshot: PullRequestSnapshotV1;
  scope: NarrowingScope;
  capability: string;
  action: NarrowingAction;
  previewToken: string;
  storeFingerprint: string;
  expiresAtUtc: string;
  killSwitchActive: boolean;
  changed: boolean;
  current: CapabilityNarrowingEffect;
  proposed: CapabilityNarrowingEffect;
}

export interface CapabilityNarrowingApplied {
  schemaVersion: 1;
  requestId: string;
  operation: "narrowing-applied";
  state: "applied";
  // PR3 echo-validation (mirrors CapabilityNarrowingPreview's own role/previewToken): the broker
  // must echo back the exact role and previewToken it was given so applyNarrowing() can verify the
  // response describes the same mutation that was requested, rather than trusting operation name
  // matching alone.
  role: AgentRole;
  scope: NarrowingScope;
  capability: string;
  action: NarrowingAction;
  previewToken: string;
}

export interface KillSwitchApplied {
  schemaVersion: 1;
  requestId: string;
  operation: "kill-switch-applied";
  // Broker-authored role (mirrors CapabilitySummary/CapabilityProfile's roleField) so
  // setKillSwitch() can reject a response describing a different role than what was requested.
  role: AgentRole;
  enabled: boolean;
  // PR3 completion (issue #105): the same short-TTL expiry CapabilityProfile/CapabilitySummary
  // already report, echoed here too so the UI can display it immediately after toggling without
  // waiting for the caller's own follow-up profile() refresh. Always present (never optional) --
  // unlike the profile/summary fields above, setKillSwitch is a PR3-only operation with no
  // legacy broker to be lenient about; null only when the switch is now OFF.
  killSwitchExpiresAtUtc: string | null;
}

// Shared blast-radius shape for describe-widening/confirm-widening-preview's responses (issue
// #105 PR4): mirrors Resolve-AgentWideningEffectiveDiff exactly. addedCapabilities/removedDenies
// restate the single capability the grant would add/un-deny (never trusted as "whatever the
// broker says changed" -- callers still bind against the specific capability they requested).
// pairedCapability is non-null only for the reviewer role's EnableApprovalVote (its paired
// capability is EnableFindingComments); pairedCapabilityActive is true whenever no pairing is
// required, or false if the pairing capability is not currently active (in which case minting is
// refused server-side).
export interface WideningEffectiveDiff {
  addedCapabilities: string[];
  removedDenies: string[];
  pairedCapability: string | null;
  pairedCapabilityActive: boolean;
}

interface WideningChallengeStageFields {
  dispatchDraftId: string;
  capability: string;
  challenge: string;
  effectiveDiff: WideningEffectiveDiff;
  expiresAtUtc: string;
  generation: number;
}

// describe-widening's response (issue #105 PR4): the broker has staged an unminted widening
// attempt in memory for this draft/capability and issued a single-use challenge1 -- confirming it
// (confirmWideningPreview) is the operator's FIRST explicit confirmation. Never itself a grant.
export interface WideningPreview extends WideningChallengeStageFields {
  schemaVersion: 1;
  requestId: string;
  operation: "widening-preview";
  state: "previewed";
}

// confirm-widening-preview's response (issue #105 PR4): a fresh challenge2 plus the same
// effectiveDiff restated as the full blast-radius summary -- confirming THIS (confirmWideningMint)
// is the operator's FINAL, terminal-commitment confirmation; there is no third stage.
export interface WideningSummary extends WideningChallengeStageFields {
  schemaVersion: 1;
  requestId: string;
  operation: "widening-summary";
  state: "awaiting-final-confirmation";
}

// confirm-widening-mint's response (issue #105 PR4): the grant now exists in the broker's
// in-memory draft state only (never yet dispatched). capabilities/mandatoryDenies/
// capabilityPolicyDigest are the WIDENED policy -- callers must merge these into their
// CapabilitySummary in place so a subsequent dispatch() binds against the exact widened digest
// the broker now expects (see dispatch()'s own capabilityPolicyDigest binding check). Minting
// never dispatches by itself -- the caller must still drive the existing confirm/confirm-final
// dispatch gate.
export interface WideningMinted {
  schemaVersion: 1;
  requestId: string;
  operation: "widening-minted";
  state: "minted";
  dispatchDraftId: string;
  capability: string;
  capabilities: string[];
  mandatoryDenies: string[];
  capabilityPolicyDigest: string;
  effectiveDiff: WideningEffectiveDiff;
  grantExpiresAtUtc: string;
  generation: number;
}

// cancel-widening's response (issue #105 PR4): the broker has torn down whatever widening/grant
// state existed for this draft (previewed, awaiting final confirmation, or already minted) and
// rebuilt the UNWIDENED policy fresh from the persisted capability-override store. Callers must
// merge these fields back into their CapabilitySummary exactly like WideningMinted's fields, so a
// subsequent dispatch() (if ever attempted) binds against the correct, un-widened digest.
export interface WideningCancelled {
  schemaVersion: 1;
  requestId: string;
  operation: "widening-cancelled";
  state: "cancelled";
  dispatchDraftId: string;
  capabilities: string[];
  mandatoryDenies: string[];
  capabilityPolicyDigest: string;
  delegableAvailable: string[];
  generation: number;
}

export interface DispatchAccepted {
  schemaVersion: 1;
  requestId: string;
  operation: "accepted";
  dispatchId: string;
  repositoryIdentity: RepositoryIdentityV1;
  pullRequestId: number;
  role: AgentRole;
  capabilityPolicyDigest: string;
  prStateFingerprint: string;
  childProcessId: number;
  eventLogPath: string;
}

export interface DispatchRejected {
  schemaVersion: 1;
  requestId: string;
  operation: "rejected";
  code: string;
  detail: string;
}

export interface DispatchTerminal {
  schemaVersion: 1;
  requestId: string;
  operation: "completed" | "cancelled";
  dispatchId: string;
  exitCode?: number;
  result?: string;
  handleReleaseObserved?: boolean;
}

type BrokerResponse =
  | CapabilitySummary
  | CapabilityProfile
  | CapabilityNarrowingPreview
  | CapabilityNarrowingApplied
  | KillSwitchApplied
  | WideningPreview
  | WideningSummary
  | WideningMinted
  | WideningCancelled
  | DispatchAccepted
  | DispatchRejected
  | DispatchTerminal
  | { schemaVersion: 1; requestId: string; operation: "shutdown-complete" };

interface PendingRequest {
  resolve: (response: BrokerResponse) => void;
  reject: (error: Error) => void;
}

export class BrokerRejectionError extends Error {
  constructor(
    readonly code: string,
    readonly detail: string,
  ) {
    super(detail ? `${code}: ${detail}` : code);
    this.name = "BrokerRejectionError";
  }
}

export interface DispatchClientOptions {
  onTerminal?: (event: DispatchTerminal) => void;
  onBrokerFailure?: (message: string) => void;
  onAcceptedEventPath?: (path: string) => void;
}

export interface DispatchBroker {
  describe(repositoryKey: string, pullRequestId: number, role: AgentRole): Promise<CapabilitySummary>;
  profile(repositoryKey: string, pullRequestId: number, role: AgentRole): Promise<CapabilityProfile>;
  // PR3 narrow-only edit protocol. previewNarrowing never mutates anything; applyNarrowing takes
  // the full CapabilityNarrowingPreview it was just given (mirroring dispatch(summary, ...) taking
  // the full CapabilitySummary) so the client never has to separately track the binding fields the
  // broker will re-verify. Callers must refresh via profile() after either succeeds -- neither
  // returns a full effective profile itself.
  previewNarrowing(
    repositoryKey: string,
    pullRequestId: number,
    role: AgentRole,
    scope: NarrowingScope,
    capability: string,
    action: NarrowingAction,
  ): Promise<CapabilityNarrowingPreview>;
  applyNarrowing(preview: CapabilityNarrowingPreview, repositoryKey: string, pullRequestId: number): Promise<CapabilityNarrowingApplied>;
  setKillSwitch(repositoryKey: string, role: AgentRole, enabled: boolean): Promise<KillSwitchApplied>;
  // PR4 interactive widening protocol (issue #105). Every method requires a live CapabilitySummary
  // (i.e. an outstanding manual-dispatch draft from describe()) -- there is no widening entry
  // point from the side-effect-free profile() RPC's CapabilityProfile, which has no
  // dispatchDraftId to bind against. describeWidening/confirmWideningPreview/confirmWideningMint
  // form one strictly-ordered, single-use, two-challenge confirmation chain per capability;
  // cancelWidening tears down whatever stage that chain is currently at (including an
  // already-minted grant) and requires the CURRENT draft generation the caller observed on the
  // most recent widening response -- it is never defaulted.
  describeWidening(summary: CapabilitySummary, capability: string): Promise<WideningPreview>;
  confirmWideningPreview(summary: CapabilitySummary, stage: WideningPreview): Promise<WideningSummary>;
  confirmWideningMint(summary: CapabilitySummary, stage: WideningSummary): Promise<WideningMinted>;
  cancelWidening(summary: CapabilitySummary, generation: number): Promise<WideningCancelled>;
  dispatch(summary: CapabilitySummary, operatorPrompt: string): Promise<DispatchAccepted>;
  cancel(dispatchId: string): Promise<DispatchTerminal>;
  shutdown(timeoutMilliseconds?: number): Promise<void>;
  subscribeTerminal(listener: (event: DispatchTerminal) => void): () => void;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("broker response must be an object");
  }
  return value as Record<string, unknown>;
}

function stringField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || !value || value.length > 4_096) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value;
}

// Broker-authored role (issue #105): the broker is the sole source of truth for which role a
// capability-summary/capability-profile response describes. Runtime-validated against the same
// known-role list the rest of the dashboard uses -- never client-stamped/overwritten, and a
// mismatch (missing, wrong type, or not a known role) fails closed here rather than trusting the
// wire value silently.
function roleField(record: Record<string, unknown>, name: string): AgentRole {
  const value = record[name];
  if (typeof value !== "string" || !(AGENTS as readonly string[]).includes(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value as AgentRole;
}

// repositoryIdentity/prSnapshot were previously spread straight from the untrusted record with no
// validation at all. repositoryIdentityField reuses domain.ts's canonical, already-bounded
// verified-identity parser (the same one AgentEvent.repositoryIdentity goes through) instead of
// duplicating that validation here.
function repositoryIdentityField(record: Record<string, unknown>, name: string): RepositoryIdentityV1 {
  const identity = parseRepositoryIdentity(record[name], true);
  if (!identity) throw new Error(`broker response ${name} is invalid`);
  return identity;
}

const MAX_PR_SNAPSHOT_TEXT_LENGTH = 4_096;

function boundedPrText(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || value.length > MAX_PR_SNAPSHOT_TEXT_LENGTH) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value;
}

function prSnapshotField(record: Record<string, unknown>, name: string): PullRequestSnapshotV1 {
  const value = record[name];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  const raw = value as Record<string, unknown>;
  if (raw.schemaVersion !== 1) throw new Error(`broker response ${name}.schemaVersion is invalid`);
  const pullRequestId = raw.pullRequestId;
  if (typeof pullRequestId !== "number" || !Number.isSafeInteger(pullRequestId) || pullRequestId <= 0) {
    throw new Error(`broker response ${name}.pullRequestId is invalid`);
  }
  if (typeof raw.active !== "boolean" || typeof raw.draft !== "boolean") {
    throw new Error(`broker response ${name} active/draft flags are invalid`);
  }
  return {
    schemaVersion: 1,
    pullRequestId,
    sourceCommit: boundedPrText(raw, "sourceCommit"),
    sourceRef: boundedPrText(raw, "sourceRef"),
    targetRef: boundedPrText(raw, "targetRef"),
    active: raw.active,
    draft: raw.draft,
    author: boundedPrText(raw, "author"),
    title: boundedPrText(raw, "title"),
  };
}

// Bounds mirror stringField's own per-item cap. The whole line is already bounded by
// DISPATCH_PROTOCOL_MAX_BYTES framing, but validating array shape explicitly here keeps this
// fail-closed independent of that outer framing check, and holds every capability-name array --
// legacy (capabilities/mandatoryDenies/dynamicConstraints) and PR1-additive alike -- to the same
// bounded-string-array contract before any UI code runs .join()/<For> over it.
const MAX_CAPABILITY_ARRAY_ITEMS = 256;
const MAX_CAPABILITY_ITEM_LENGTH = 4_096;

function stringArrayField(record: Record<string, unknown>, name: string): string[] {
  const value = record[name];
  if (
    !Array.isArray(value) ||
    value.length > MAX_CAPABILITY_ARRAY_ITEMS ||
    value.some((item) => typeof item !== "string" || item.length > MAX_CAPABILITY_ITEM_LENGTH)
  ) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value as string[];
}

const MAX_PROVENANCE_ENTRIES = 256;
const MAX_PROVENANCE_KEY_LENGTH = 128;
// Rejected outright rather than merely bounded: these keys shadow/attack object internals if ever
// forwarded into a prototype-carrying object or a lodash-style deep-set elsewhere in the pipeline.
const DANGEROUS_PROVENANCE_KEYS = new Set(["__proto__", "constructor", "prototype"]);

function provenanceField(record: Record<string, unknown>, name: string): Record<string, CapabilityProvenance> {
  const value = record[name];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length > MAX_PROVENANCE_ENTRIES) {
    throw new Error(`broker response ${name} has too many entries`);
  }
  // Object.create(null) has no prototype to hijack, so even a "__proto__" key that somehow slipped
  // past the explicit rejection below would land as a harmless own property instead of reaching
  // Object.prototype.
  const result: Record<string, CapabilityProvenance> = Object.create(null);
  for (const [key, entry] of entries) {
    if (DANGEROUS_PROVENANCE_KEYS.has(key) || key.length > MAX_PROVENANCE_KEY_LENGTH) {
      throw new Error(`broker response ${name} key is invalid`);
    }
    if (typeof entry !== "string" || !(KNOWN_PROVENANCE as readonly string[]).includes(entry)) {
      throw new Error(`broker response ${name}.${key} is invalid`);
    }
    result[key] = entry as CapabilityProvenance;
  }
  return result;
}

function booleanField(record: Record<string, unknown>, name: string): boolean {
  const value = record[name];
  if (typeof value !== "boolean") throw new Error(`broker response ${name} is invalid`);
  return value;
}

// A canonical epoch-or-ISO killSwitchExpiresAtUtc is always short; bounding it far tighter than
// the generic MAX_PR_SNAPSHOT_TEXT_LENGTH is itself part of rejecting "arbitrary text" (issue #105
// PR3 completion) -- 40 characters comfortably fits every legal ISO-8601 UTC rendering (including
// fractional seconds) with room to spare.
const MAX_KILL_SWITCH_EXPIRY_TEXT_LENGTH = 40;
// Upper bound for an epoch-seconds killSwitchExpiresAtUtc, far tighter than
// Number.isSafeInteger's astronomically large +-2^53 span: the sentinel's own TTL is capped at 24h
// (see Enable-AgentCapabilityOverrideKillSwitch's ValidateRange), so a legitimate expiry is always
// within about a day of "now". Year 2200 leaves enormous headroom for clock skew while still
// rejecting a clearly-bogus value a malformed/hostile broker response could otherwise smuggle
// through as merely "a safe integer".
const MAX_KILL_SWITCH_EPOCH_SECONDS = 7_258_118_400; // 2200-01-01T00:00:00Z

// PR3's killSwitchExpiresAtUtc: null is a legitimate value (the kill switch is inactive) rather
// than a parse failure. The harness itself stores/emits this as a plain integer epoch-seconds
// count (see ConvertTo-AgentCanonicalEpochSeconds), but every existing fixture in this codebase's
// own test suite already emits a canonical ISO-8601 UTC string instead -- both are legal wire
// shapes for a PR3-or-newer broker, so this validates and normalizes either one to a single
// canonical ISO-8601 string. That keeps every downstream consumer (Date.parse in app.tsx's
// killSwitchExpiryLabel, and this field's own CapabilityProfile/CapabilitySummary/KillSwitchApplied
// type) dealing with exactly one shape regardless of which the broker actually sent. A string
// input must pass three independent gates -- a tight length bound, no control/non-printable
// characters, and a value Date.parse actually accepts as a timestamp -- rejecting control
// characters or arbitrary non-timestamp text outright rather than only softening on length. Once
// validated it is returned completely unchanged (never reformatted) so an already-canonical value
// still round-trips byte-for-byte; a numeric epoch has no pre-existing textual form to preserve,
// so it is normalized to one instead.
function nullableExpiryText(record: Record<string, unknown>, name: string): string | null {
  const value = record[name];
  if (value === null) return null;
  if (typeof value === "string") {
    if (value.length === 0 || value.length > MAX_KILL_SWITCH_EXPIRY_TEXT_LENGTH) {
      throw new Error(`broker response ${name} is invalid`);
    }
    if (/[\x00-\x1f\x7f]/.test(value)) throw new Error(`broker response ${name} is invalid`);
    if (Number.isNaN(Date.parse(value))) throw new Error(`broker response ${name} is invalid`);
    return value;
  }
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= MAX_KILL_SWITCH_EPOCH_SECONDS) {
    return new Date(value * 1000).toISOString();
  }
  throw new Error(`broker response ${name} is invalid`);
}

// Legacy-broker compatibility (issue #105 PR3 review): a schemaVersion-1 broker that predates the
// PR1/PR2/PR3-additive profile fields simply omits them from capability-summary/capability-profile
// responses -- schemaVersion here never bumps across those additions, so an old broker is legally
// still on the wire. These optionalXField helpers default a field ONLY when it is genuinely absent
// (`record[name] === undefined`); a field that IS present but malformed still throws via the
// underlying required-field parser, so this only softens absence, never corruption.
function optionalStringArrayField(record: Record<string, unknown>, name: string, fallback: string[]): string[] {
  return record[name] === undefined ? fallback : stringArrayField(record, name);
}

function optionalProvenanceField(record: Record<string, unknown>, name: string): Record<string, CapabilityProvenance> {
  return record[name] === undefined ? Object.create(null) : provenanceField(record, name);
}

function optionalBooleanField(record: Record<string, unknown>, name: string, fallback: boolean): boolean {
  return record[name] === undefined ? fallback : booleanField(record, name);
}

function optionalNullableExpiryText(record: Record<string, unknown>, name: string): string | null {
  return record[name] === undefined ? null : nullableExpiryText(record, name);
}

// Shared by parseCapabilityProfileFields (role known in-band from the same response) and
// cancelWidening (role known only from the caller's own CapabilitySummary, since widening-
// cancelled carries no role field of its own): delegableAvailable is either empty or exactly the
// one capability DELEGABLE_CAPABILITY_BY_ROLE names for this role. A cross-role value, an unknown
// name, or more than one entry all fail closed rather than being trusted.
function assertDelegableAvailable(role: AgentRole, delegableAvailable: string[], context: string): void {
  const expected = DELEGABLE_CAPABILITY_BY_ROLE[role];
  const valid = delegableAvailable.length === 0 || (delegableAvailable.length === 1 && delegableAvailable[0] === expected);
  if (!valid) throw new Error(`${context} delegableAvailable is not valid for role ${role}`);
}

// Client-side mirror of the broker's own role/capability check (Invoke-DescribeWidening) --
// rejected here, before a request is ever sent, rather than relying solely on the broker's own
// rejection round-trip.
function assertDelegableCapability(role: AgentRole, capability: string): void {
  if (capability !== DELEGABLE_CAPABILITY_BY_ROLE[role]) {
    throw new Error(`capability ${capability} is not delegable for role ${role}`);
  }
}

// Constructs the PR1 additive profile fields from validated values only -- never spread/cast
// straight from the untrusted parsed record, unlike the rest of parseResponse's envelope fields.
function parseCapabilityProfileFields(record: Record<string, unknown>, role: AgentRole): Pick<
  CapabilitySummary,
  | "absoluteDenies"
  | "allowedManualCapabilities"
  | "delegableAvailable"
  | "provenance"
  | "killSwitchActive"
  | "killSwitchExpiresAtUtc"
  | "editingAvailable"
> {
  // editingAvailable is a capability marker, not a trust decision about content: it reflects
  // whether the broker is new enough to have SENT these fields at all, computed from raw presence
  // BEFORE any fallback is applied -- never from the (possibly-defaulted) values below.
  const editingAvailable =
    record.allowedManualCapabilities !== undefined &&
    record.provenance !== undefined &&
    record.killSwitchActive !== undefined;
  const delegableAvailable = optionalStringArrayField(record, "delegableAvailable", []);
  // issue #105 PR4: delegableAvailable may now legitimately be non-empty, but only ever the exact
  // one capability the checked-in delegation policy can ever name for this role -- never a
  // cross-role value, an unknown name, or more than one entry (see DELEGABLE_CAPABILITY_BY_ROLE).
  assertDelegableAvailable(role, delegableAvailable, "broker response");
  return {
    absoluteDenies: optionalStringArrayField(record, "absoluteDenies", []),
    allowedManualCapabilities: optionalStringArrayField(record, "allowedManualCapabilities", []),
    delegableAvailable,
    provenance: optionalProvenanceField(record, "provenance"),
    killSwitchActive: optionalBooleanField(record, "killSwitchActive", false),
    killSwitchExpiresAtUtc: optionalNullableExpiryText(record, "killSwitchExpiresAtUtc"),
    editingAvailable,
  };
}

const CAPABILITY_NAME_PATTERN = /^[A-Za-z][A-Za-z0-9]*$/;

function capabilityNameField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || value.length > MAX_CAPABILITY_ITEM_LENGTH || !CAPABILITY_NAME_PATTERN.test(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value;
}

function narrowingScopeField(record: Record<string, unknown>, name: string): NarrowingScope {
  const value = record[name];
  if (typeof value !== "string" || !(NARROWING_SCOPES as readonly string[]).includes(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value as NarrowingScope;
}

function narrowingActionField(record: Record<string, unknown>, name: string): NarrowingAction {
  const value = record[name];
  if (typeof value !== "string" || !(NARROWING_ACTIONS as readonly string[]).includes(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value as NarrowingAction;
}

function narrowingEffectField(record: Record<string, unknown>, name: string): CapabilityNarrowingEffect {
  const value = record[name];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  const raw = value as Record<string, unknown>;
  return {
    capabilities: stringArrayField(raw, "capabilities"),
    mandatoryDenies: stringArrayField(raw, "mandatoryDenies"),
    provenance: provenanceField(raw, "provenance"),
  };
}

const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function guidField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || !GUID_RE.test(value)) throw new Error(`broker response ${name} is invalid`);
  return value;
}

// Matches Test-AgentWideningChallengeShape exactly (24 random bytes as lowercase hex) -- a
// single-use, short-TTL confirmation token, never a long-lived secret, but still validated to its
// exact shape rather than treated as an arbitrary bounded string.
const CHALLENGE_RE = /^[0-9a-f]{48}$/;

function challengeField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || !CHALLENGE_RE.test(value)) throw new Error(`broker response ${name} is invalid`);
  return value;
}

// Matches Get-AgentCanonicalDigest's output shape exactly (lowercase SHA-256 hex).
const HEX64_RE = /^[0-9a-f]{64}$/;

function hex64Field(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || !HEX64_RE.test(value)) throw new Error(`broker response ${name} is invalid`);
  return value;
}

// Draft-scoped monotonically-increasing counter (WideningGeneration) -- never negative and never
// remotely close to this ceiling in practice; bounded generously rather than tightly so a
// legitimate long-lived draft's counter is never rejected.
const MAX_WIDENING_GENERATION = 1_000_000;

function generationField(record: Record<string, unknown>, name: string): number {
  const value = record[name];
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > MAX_WIDENING_GENERATION) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return value;
}

const MAX_WIDENING_DIFF_ITEMS = 32;

function capabilityNameArrayField(record: Record<string, unknown>, name: string): string[] {
  const values = stringArrayField(record, name);
  if (values.length > MAX_WIDENING_DIFF_ITEMS || values.some((value) => !CAPABILITY_NAME_PATTERN.test(value))) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return values;
}

function effectiveDiffField(record: Record<string, unknown>, name: string): WideningEffectiveDiff {
  const value = record[name];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`broker response ${name} is invalid`);
  }
  const raw = value as Record<string, unknown>;
  const pairedCapabilityRaw = raw.pairedCapability;
  let pairedCapability: string | null;
  if (pairedCapabilityRaw === null) {
    pairedCapability = null;
  } else if (typeof pairedCapabilityRaw === "string" && CAPABILITY_NAME_PATTERN.test(pairedCapabilityRaw)) {
    pairedCapability = pairedCapabilityRaw;
  } else {
    throw new Error(`broker response ${name}.pairedCapability is invalid`);
  }
  return {
    addedCapabilities: capabilityNameArrayField(raw, "addedCapabilities"),
    removedDenies: capabilityNameArrayField(raw, "removedDenies"),
    pairedCapability,
    pairedCapabilityActive: booleanField(raw, "pairedCapabilityActive"),
  };
}

const MAX_WIDENING_TIMESTAMP_LENGTH = 40;

// expiresAtUtc is PowerShell's [DateTime]::ToString('o') round-trip format -- always a string on
// the wire, unlike grantExpiresAtUtc below (which the harness emits as a plain epoch-seconds
// integer). Bounded the same way nullableExpiryText already bounds its own string branch, but
// required: this field is never null/absent on a widening-preview/-summary response.
function requiredIsoTimestampField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_WIDENING_TIMESTAMP_LENGTH) {
    throw new Error(`broker response ${name} is invalid`);
  }
  if (/[\x00-\x1f\x7f]/.test(value)) throw new Error(`broker response ${name} is invalid`);
  if (Number.isNaN(Date.parse(value))) throw new Error(`broker response ${name} is invalid`);
  return value;
}

// grantExpiresAtUtc is ConvertTo-AgentCanonicalEpochSeconds's output -- always a plain epoch-
// seconds integer on the wire (never a string), mirroring killSwitchExpiresAtUtc's own numeric
// branch and bounded by the identical far-future ceiling (issue #105 PR3's
// MAX_KILL_SWITCH_EPOCH_SECONDS) so a clearly-bogus value can never be smuggled through as merely
// "a safe integer". Normalized to an ISO string so every consumer (Date.parse in app.tsx) deals
// with one shape regardless of which numeric/string convention a given field happens to use.
const MAX_GRANT_EPOCH_SECONDS = 7_258_118_400; // 2200-01-01T00:00:00Z

function requiredEpochSecondsField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > MAX_GRANT_EPOCH_SECONDS) {
    throw new Error(`broker response ${name} is invalid`);
  }
  return new Date(value * 1000).toISOString();
}

function parseResponse(line: string): BrokerResponse {
  const record = asRecord(JSON.parse(line));
  if (record.schemaVersion !== 1) throw new Error("unsupported broker protocol version");
  const requestId = stringField(record, "requestId");
  const operation = stringField(record, "operation");
  if (
    ![
      "capability-summary",
      "capability-profile",
      "narrowing-preview",
      "narrowing-applied",
      "kill-switch-applied",
      "widening-preview",
      "widening-summary",
      "widening-minted",
      "widening-cancelled",
      "accepted",
      "rejected",
      "completed",
      "cancelled",
      "shutdown-complete",
    ].includes(operation)
  ) {
    throw new Error("unknown broker response operation");
  }
  if (operation === "capability-summary" || operation === "capability-profile") {
    // Computed once so it can also be threaded into parseCapabilityProfileFields's role-aware
    // delegableAvailable validation below, rather than parsed twice or read back off the
    // not-yet-constructed `shared` object.
    const role = roleField(record, "role");
    const shared = {
      // Broker-authored role (issue #105) plus repositoryIdentity/prSnapshot, both of which used to
      // be spread straight from the untrusted record with no validation at all.
      role,
      repositoryIdentity: repositoryIdentityField(record, "repositoryIdentity"),
      prSnapshot: prSnapshotField(record, "prSnapshot"),
      // Legacy fields predate PR1's stricter parsing and were previously spread straight from the
      // untrusted record; validate them the same bounded-string-array way as the PR1-additive
      // fields so a malformed broker response fails closed here instead of throwing later out of
      // an unguarded UI .join()/<For>.
      capabilities: stringArrayField(record, "capabilities"),
      mandatoryDenies: stringArrayField(record, "mandatoryDenies"),
      dynamicConstraints: stringArrayField(record, "dynamicConstraints"),
      ...parseCapabilityProfileFields(record, role),
    };
    if (operation === "capability-summary") {
      return { ...record, requestId, operation, ...shared } as CapabilitySummary;
    }
    return { ...record, requestId, operation, ...shared } as CapabilityProfile;
  }
  if (operation === "widening-preview" || operation === "widening-summary") {
    const expectedState = operation === "widening-preview" ? "previewed" : "awaiting-final-confirmation";
    const stateValue = stringField(record, "state");
    if (stateValue !== expectedState) throw new Error("broker response state is invalid");
    const shared = {
      dispatchDraftId: guidField(record, "dispatchDraftId"),
      capability: capabilityNameField(record, "capability"),
      challenge: challengeField(record, "challenge"),
      effectiveDiff: effectiveDiffField(record, "effectiveDiff"),
      expiresAtUtc: requiredIsoTimestampField(record, "expiresAtUtc"),
      generation: generationField(record, "generation"),
    };
    if (operation === "widening-preview") {
      return { schemaVersion: 1, requestId, operation, state: "previewed", ...shared } satisfies WideningPreview;
    }
    return { schemaVersion: 1, requestId, operation, state: "awaiting-final-confirmation", ...shared } satisfies WideningSummary;
  }
  if (operation === "widening-minted") {
    const stateValue = stringField(record, "state");
    if (stateValue !== "minted") throw new Error("broker response state is invalid");
    return {
      schemaVersion: 1,
      requestId,
      operation,
      state: "minted",
      dispatchDraftId: guidField(record, "dispatchDraftId"),
      capability: capabilityNameField(record, "capability"),
      capabilities: stringArrayField(record, "capabilities"),
      mandatoryDenies: stringArrayField(record, "mandatoryDenies"),
      capabilityPolicyDigest: hex64Field(record, "capabilityPolicyDigest"),
      effectiveDiff: effectiveDiffField(record, "effectiveDiff"),
      grantExpiresAtUtc: requiredEpochSecondsField(record, "grantExpiresAtUtc"),
      generation: generationField(record, "generation"),
    } satisfies WideningMinted;
  }
  if (operation === "widening-cancelled") {
    const stateValue = stringField(record, "state");
    if (stateValue !== "cancelled") throw new Error("broker response state is invalid");
    return {
      schemaVersion: 1,
      requestId,
      operation,
      state: "cancelled",
      dispatchDraftId: guidField(record, "dispatchDraftId"),
      capabilities: stringArrayField(record, "capabilities"),
      mandatoryDenies: stringArrayField(record, "mandatoryDenies"),
      capabilityPolicyDigest: hex64Field(record, "capabilityPolicyDigest"),
      delegableAvailable: stringArrayField(record, "delegableAvailable"),
      generation: generationField(record, "generation"),
    } satisfies WideningCancelled;
  }
  if (operation === "narrowing-preview") {
    const stateValue = stringField(record, "state");
    if (stateValue !== "previewed") throw new Error("broker response state is invalid");
    return {
      schemaVersion: 1,
      requestId,
      operation,
      state: "previewed",
      role: roleField(record, "role"),
      repositoryIdentity: repositoryIdentityField(record, "repositoryIdentity"),
      prSnapshot: prSnapshotField(record, "prSnapshot"),
      scope: narrowingScopeField(record, "scope"),
      capability: capabilityNameField(record, "capability"),
      action: narrowingActionField(record, "action"),
      previewToken: stringField(record, "previewToken"),
      storeFingerprint: stringField(record, "storeFingerprint"),
      expiresAtUtc: boundedPrText(record, "expiresAtUtc"),
      killSwitchActive: booleanField(record, "killSwitchActive"),
      changed: booleanField(record, "changed"),
      current: narrowingEffectField(record, "current"),
      proposed: narrowingEffectField(record, "proposed"),
    } satisfies CapabilityNarrowingPreview;
  }
  if (operation === "narrowing-applied") {
    const stateValue = stringField(record, "state");
    if (stateValue !== "applied") throw new Error("broker response state is invalid");
    return {
      schemaVersion: 1,
      requestId,
      operation,
      state: "applied",
      role: roleField(record, "role"),
      scope: narrowingScopeField(record, "scope"),
      capability: capabilityNameField(record, "capability"),
      action: narrowingActionField(record, "action"),
      previewToken: stringField(record, "previewToken"),
    } satisfies CapabilityNarrowingApplied;
  }
  if (operation === "kill-switch-applied") {
    return {
      schemaVersion: 1,
      requestId,
      operation,
      role: roleField(record, "role"),
      enabled: booleanField(record, "enabled"),
      killSwitchExpiresAtUtc: nullableExpiryText(record, "killSwitchExpiresAtUtc"),
    } satisfies KillSwitchApplied;
  }
  return { ...record, requestId, operation } as BrokerResponse;
}

function validateLaunch(descriptor: BrokerLaunchDescriptor): void {
  for (const [name, value] of Object.entries(descriptor)) {
    if (!value || !isAbsolute(value) || /[\r\n\u0000]/.test(value)) {
      throw new Error(`${name} must be an absolute trusted path`);
    }
  }
}

function frame(request: Record<string, unknown>): Buffer {
  const bytes = Buffer.from(`${JSON.stringify(request)}\n`, "utf8");
  if (bytes.length > DISPATCH_PROTOCOL_MAX_BYTES) {
    throw new Error("broker request exceeds the 65,536-byte JSONL limit");
  }
  return bytes;
}

export class DispatchClient implements DispatchBroker {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly pending = new Map<string, PendingRequest>();
  private readonly decoder = new TextDecoder("utf-8", { fatal: true });
  private buffered = "";
  private bufferedBytes = 0;
  private closed = false;
  private shutdownPromise: Promise<void> | undefined;
  private readonly terminalListeners = new Set<(event: DispatchTerminal) => void>();

  constructor(
    descriptor: BrokerLaunchDescriptor,
    private readonly options: DispatchClientOptions = {},
  ) {
    validateLaunch(descriptor);
    this.child = spawn(
      descriptor.executablePath,
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-File",
        descriptor.scriptPath,
        "-DescriptorPath",
        descriptor.descriptorPath,
      ],
      {
        shell: false,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    this.child.stdout.on("data", (chunk: Buffer) => this.consume(chunk));
    this.child.stderr.on("data", () => {
      // Broker diagnostics are intentionally not surfaced because they may contain trusted paths.
    });
    this.child.once("error", (error) => this.fail(`broker failed to start: ${error.message}`));
    this.child.once("exit", (code, signal) => {
      if (!this.closed) this.fail(`broker exited unexpectedly (${signal ?? code ?? "unknown"})`);
    });
  }

  describe(repositoryKey: string, pullRequestId: number, role: AgentRole): Promise<CapabilitySummary> {
    return this.request<CapabilitySummary>({
      schemaVersion: 1,
      operation: "describe",
      repositoryKey,
      pullRequestId,
      role,
    }, "capability-summary").then((response) => {
      // The broker's role is authoritative (issue #105) and is never client-stamped/overwritten;
      // a response for a different role than what was requested is rejected rather than trusted.
      if (response.role !== role) {
        throw new Error("broker capability-summary role does not match the requested role");
      }
      return response;
    });
  }

  profile(repositoryKey: string, pullRequestId: number, role: AgentRole): Promise<CapabilityProfile> {
    return this.request<CapabilityProfile>({
      schemaVersion: 1,
      operation: "profile",
      repositoryKey,
      pullRequestId,
      role,
    }, "capability-profile").then((response) => {
      if (response.role !== role) {
        throw new Error("broker capability-profile role does not match the requested role");
      }
      return response;
    });
  }

  previewNarrowing(
    repositoryKey: string,
    pullRequestId: number,
    role: AgentRole,
    scope: NarrowingScope,
    capability: string,
    action: NarrowingAction,
  ): Promise<CapabilityNarrowingPreview> {
    return this.request<CapabilityNarrowingPreview>({
      schemaVersion: 1,
      operation: "preview-narrowing",
      repositoryKey,
      pullRequestId,
      role,
      scope,
      capability,
      action,
    }, "narrowing-preview").then((response) => {
      if (response.role !== role || response.scope !== scope || response.capability !== capability || response.action !== action) {
        throw new Error("broker narrowing-preview does not match the requested mutation");
      }
      return response;
    });
  }

  applyNarrowing(preview: CapabilityNarrowingPreview, repositoryKey: string, pullRequestId: number): Promise<CapabilityNarrowingApplied> {
    return this.request<CapabilityNarrowingApplied>({
      schemaVersion: 1,
      operation: "apply-narrowing",
      repositoryKey,
      pullRequestId,
      role: preview.role,
      scope: preview.scope,
      capability: preview.capability,
      action: preview.action,
      previewToken: preview.previewToken,
      storeFingerprint: preview.storeFingerprint,
    }, "narrowing-applied").then((response) => {
      // Mirrors previewNarrowing()'s own echo-validation: the broker must echo back the exact
      // binding it was just given, so a response describing a different mutation is rejected
      // client-side rather than trusted.
      if (
        response.role !== preview.role ||
        response.scope !== preview.scope ||
        response.capability !== preview.capability ||
        response.action !== preview.action ||
        response.previewToken !== preview.previewToken
      ) {
        throw new Error("broker narrowing-applied does not match the requested mutation");
      }
      return response;
    });
  }

  setKillSwitch(repositoryKey: string, role: AgentRole, enabled: boolean): Promise<KillSwitchApplied> {
    return this.request<KillSwitchApplied>({
      schemaVersion: 1,
      operation: "set-kill-switch",
      repositoryKey,
      role,
      enabled,
    }, "kill-switch-applied").then((response) => {
      if (response.role !== role || response.enabled !== enabled) {
        throw new Error("broker kill-switch-applied does not match the requested mutation");
      }
      return response;
    });
  }

  describeWidening(summary: CapabilitySummary, capability: string): Promise<WideningPreview> {
    // Client-side gate (defense in depth): the broker independently enforces the identical
    // role/capability check (Invoke-DescribeWidening) and rejects with [widening-invalid] --
    // rejecting here first avoids a pointless round-trip for a request that can never succeed.
    // Returned as a rejected promise (never a synchronous throw) so this method's calling
    // contract stays uniformly promise-returning, exactly like the `this.closed` guard in
    // request() below -- a synchronous throw here would break a caller doing
    // `client.describeWidening(...).catch(...)` instead of try/await.
    try {
      assertDelegableCapability(summary.role, capability);
    } catch (error) {
      return Promise.reject(error);
    }
    return this.request<WideningPreview>({
      schemaVersion: 1,
      operation: "describe-widening",
      repositoryKey: summary.repositoryIdentity.key,
      pullRequestId: summary.prSnapshot.pullRequestId,
      role: summary.role,
      dispatchDraftId: summary.dispatchDraftId,
      capability,
    }, "widening-preview").then((response) => {
      if (response.dispatchDraftId !== summary.dispatchDraftId || response.capability !== capability) {
        throw new Error("broker widening-preview does not match the requested draft/capability");
      }
      return response;
    });
  }

  confirmWideningPreview(summary: CapabilitySummary, stage: WideningPreview): Promise<WideningSummary> {
    return this.request<WideningSummary>({
      schemaVersion: 1,
      operation: "confirm-widening-preview",
      repositoryKey: summary.repositoryIdentity.key,
      pullRequestId: summary.prSnapshot.pullRequestId,
      role: summary.role,
      dispatchDraftId: summary.dispatchDraftId,
      capability: stage.capability,
      challenge: stage.challenge,
    }, "widening-summary").then((response) => {
      if (response.dispatchDraftId !== summary.dispatchDraftId || response.capability !== stage.capability) {
        throw new Error("broker widening-summary does not match the requested draft/capability");
      }
      return response;
    });
  }

  confirmWideningMint(summary: CapabilitySummary, stage: WideningSummary): Promise<WideningMinted> {
    return this.request<WideningMinted>({
      schemaVersion: 1,
      operation: "confirm-widening-mint",
      repositoryKey: summary.repositoryIdentity.key,
      pullRequestId: summary.prSnapshot.pullRequestId,
      role: summary.role,
      dispatchDraftId: summary.dispatchDraftId,
      capability: stage.capability,
      challenge: stage.challenge,
    }, "widening-minted").then((response) => {
      if (response.dispatchDraftId !== summary.dispatchDraftId || response.capability !== stage.capability) {
        throw new Error("broker widening-minted does not match the requested draft/capability");
      }
      return response;
    });
  }

  cancelWidening(summary: CapabilitySummary, generation: number): Promise<WideningCancelled> {
    // Never defaulted (issue #105 PR4 review): the caller must supply the exact generation from
    // the most recent widening response it observed. An omitted/non-integer/negative value is
    // rejected here, before the request is ever sent, mirroring the identical invariant the
    // broker's own cancel-widening handler enforces server-side (ConvertTo-AgentSafeIntegralNumber).
    if (!Number.isSafeInteger(generation) || generation < 0) {
      // Same rationale as describeWidening's guard above: a rejected promise, never a synchronous
      // throw, so this method's calling contract stays uniformly promise-returning.
      return Promise.reject(new Error("cancelWidening requires an exact, non-negative generation"));
    }
    return this.request<WideningCancelled>({
      schemaVersion: 1,
      operation: "cancel-widening",
      repositoryKey: summary.repositoryIdentity.key,
      pullRequestId: summary.prSnapshot.pullRequestId,
      role: summary.role,
      dispatchDraftId: summary.dispatchDraftId,
      generation,
    }, "widening-cancelled").then((response) => {
      if (response.dispatchDraftId !== summary.dispatchDraftId) {
        throw new Error("broker widening-cancelled does not match the requested draft");
      }
      assertDelegableAvailable(summary.role, response.delegableAvailable, "broker widening-cancelled");
      return response;
    });
  }

  dispatch(summary: CapabilitySummary, operatorPrompt: string): Promise<DispatchAccepted> {
    return this.request({
      schemaVersion: 1,
      operation: "dispatch",
      repositoryKey: summary.repositoryIdentity.key,
      pullRequestId: summary.prSnapshot.pullRequestId,
      role: summary.role,
      dispatchDraftId: summary.dispatchDraftId,
      capabilityPolicyDigest: summary.capabilityPolicyDigest,
      prStateFingerprint: summary.prStateFingerprint,
      operatorPrompt,
    }, "accepted");
  }

  cancel(dispatchId: string): Promise<DispatchTerminal> {
    return this.request({
      schemaVersion: 1,
      operation: "cancel",
      dispatchId,
    }, ["cancelled", "completed"]);
  }

  shutdown(timeoutMilliseconds = 12_000): Promise<void> {
    if (this.shutdownPromise) return this.shutdownPromise;
    if (this.closed) return Promise.resolve();
    this.shutdownPromise = (async () => {
      try {
        await Promise.race([
          this.request({ schemaVersion: 1, operation: "shutdown" }, "shutdown-complete"),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error("broker shutdown timed out")), timeoutMilliseconds)),
        ]);
      } finally {
        this.closed = true;
        this.child.stdin.end();
        if (this.child.exitCode === null && this.child.signalCode === null) this.child.kill();
        await Promise.race([
          new Promise<void>((resolve) => {
            if (this.child.exitCode !== null || this.child.signalCode !== null) resolve();
            else this.child.once("exit", () => resolve());
          }),
          new Promise<void>((resolve) => setTimeout(resolve, 2_000)),
        ]);
      }
    })();
    return this.shutdownPromise;
  }

  subscribeTerminal(listener: (event: DispatchTerminal) => void): () => void {
    this.terminalListeners.add(listener);
    return () => this.terminalListeners.delete(listener);
  }

  private request<T>(
    body: Record<string, unknown>,
    expected: string | string[],
  ): Promise<T> {
    if (this.closed) return Promise.reject(new Error("broker is closed"));
    const requestId = randomUUID();
    const bytes = frame({ ...body, requestId });
    return new Promise<T>((resolve, reject) => {
      this.pending.set(requestId, {
        resolve: (response) => {
          if (response.operation === "rejected") {
            reject(new BrokerRejectionError(response.code, response.detail));
          } else if (!(Array.isArray(expected) ? expected.includes(response.operation) : response.operation === expected)) {
            reject(new Error(`unexpected broker response ${response.operation}`));
          } else {
            resolve(response as T);
          }
        },
        reject,
      });
      this.child.stdin.write(bytes, (error) => {
        if (!error) return;
        this.pending.delete(requestId);
        reject(new Error(`broker request failed: ${error.message}`));
      });
    });
  }

  private consume(chunk: Buffer): void {
    this.bufferedBytes += chunk.length;
    if (this.bufferedBytes > DISPATCH_PROTOCOL_MAX_BYTES && !chunk.includes(0x0a)) {
      this.fail("broker emitted an oversized JSONL frame");
      return;
    }
    try {
      this.buffered += this.decoder.decode(chunk, { stream: true });
    } catch {
      this.fail("broker emitted invalid UTF-8");
      return;
    }
    let newline = this.buffered.indexOf("\n");
    while (newline >= 0) {
      const line = this.buffered.slice(0, newline).replace(/\r$/, "");
      this.buffered = this.buffered.slice(newline + 1);
      this.bufferedBytes = Buffer.byteLength(this.buffered, "utf8");
      if (Buffer.byteLength(`${line}\n`, "utf8") > DISPATCH_PROTOCOL_MAX_BYTES) {
        this.fail("broker emitted an oversized JSONL frame");
        return;
      }
      if (line) this.route(line);
      newline = this.buffered.indexOf("\n");
    }
    if (this.bufferedBytes > DISPATCH_PROTOCOL_MAX_BYTES) {
      this.fail("broker emitted an oversized JSONL frame");
    }
  }

  private route(line: string): void {
    let response: BrokerResponse;
    try {
      response = parseResponse(line);
    } catch {
      this.fail("broker emitted an invalid protocol frame");
      return;
    }
    const pending = this.pending.get(response.requestId);
    if (response.operation === "completed" || response.operation === "cancelled") {
      this.options.onTerminal?.(response);
      for (const listener of this.terminalListeners) listener(response);
    }
    if (pending) {
      this.pending.delete(response.requestId);
      pending.resolve(response);
    }
    if (response.operation === "accepted") {
      this.options.onAcceptedEventPath?.(response.eventLogPath);
    }
  }

  private fail(message: string): void {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) pending.reject(new Error(message));
    this.pending.clear();
    this.options.onBrokerFailure?.(message);
  }
}
