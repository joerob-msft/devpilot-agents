#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DescriptorPath,
    [ValidateRange(1024, 65536)][int]$MaximumLineBytes = 65536,
    [ValidateRange(1, 3600)][int]$DraftLifetimeSeconds = 600,
    [ValidateRange(5, 300)][int]$NarrowingPreviewTtlSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$toolkitRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $toolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

$descriptorFullPath = [IO.Path]::GetFullPath($DescriptorPath)
$descriptorParent = Split-Path $descriptorFullPath -Parent
$trustedDescriptorRoot = Resolve-AgentTrustedRoot -Path $descriptorParent -Kind watch-state `
    -RepositoryRoot ([IO.Path]::GetFullPath($toolkitRoot))
$descriptorFullPath = Assert-AgentTrustedFile -Path $descriptorFullPath -AllowedRoot $trustedDescriptorRoot `
    -ExpectedPath (Join-Path $trustedDescriptorRoot 'broker.descriptor.v1.json') -Private
$descriptor = Get-Content -LiteralPath $descriptorFullPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
if ([int]$descriptor.schemaVersion -ne 1 -or [int]$descriptor.ownerProcessId -le 0) {
    throw 'Broker descriptor is malformed.'
}
# issue #105 PR5 (broker-issuer anchor): captured from the freshly-parsed, unmutated descriptor
# hashtable, BEFORE the per-role loop below rewrites roleDescriptor.scriptPath/configFile in
# place -- Assert-AgentBrokerProcessAnchor (child side) parses the same on-disk file the same way
# and must land on the identical digest. Also pins this broker's own live process identity and
# the content hash of the exact script currently running, both independent of anything a request
# supplies, so every per-dispatch manifest can carry a value the child can verify without ever
# trusting the manifest itself.
$descriptorDigest = Get-AgentCanonicalDigest -InputObject $descriptor
$brokerProcessStartIdentity = Get-AgentProcessStartIdentity -Process (Get-Process -Id $PID)
$brokerScriptSha256 = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($PSCommandPath))).ToLowerInvariant()
# issue #105 final headless-broker bypass fix: an ordinary headless caller can run this exact
# script directly and drive both interactive-widening challenge stages entirely themselves --
# those confirmations are anti-mistake safeguards, never human authentication, but must be
# structurally unreachable unless this broker's own immediate OS parent really is the trusted
# interactive Dashboard (Start-DevPilotDashboard.ps1's locked Bun runtime spawning this exact
# script -- see Test-AgentDashboardLaunchProvenance for the full anchor). Computed exactly once,
# here, before the request loop starts; never re-evaluated per-request. Baseline describe/
# profile/manual (unwidened) dispatch are completely unaffected by this value.
$interactiveWideningAvailable = Test-AgentDashboardLaunchProvenance -ToolkitRoot $toolkitRoot `
    -BrokerScriptPath $PSCommandPath -DescriptorPath $descriptorFullPath
$stateRoot = [IO.Path]::GetFullPath([string]$descriptor.stateRoot)
$durableRoot = [IO.Path]::GetFullPath([string]$descriptor.durableStateRoot)
$leaseRoot = [IO.Path]::GetFullPath([string]$descriptor.leaseRoot)
foreach ($root in @($stateRoot, $durableRoot, $leaseRoot)) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Trusted broker root does not exist: $root" }
}
if ($stateRoot -cne $trustedDescriptorRoot) { throw 'Broker descriptor state root does not match its trusted location.' }
$stateRoot = Resolve-AgentTrustedRoot -Path $stateRoot -Kind watch-state `
    -RepositoryRoot ([IO.Path]::GetFullPath($toolkitRoot))
$durableRoot = Resolve-AgentTrustedRoot -Path $durableRoot -Kind durable-state `
    -RepositoryRoot ([IO.Path]::GetFullPath($toolkitRoot)) -DisallowedRoots @($stateRoot)
$leaseRoot = Resolve-AgentTrustedRoot -Path $leaseRoot -Kind lease `
    -RepositoryRoot ([IO.Path]::GetFullPath($toolkitRoot)) -DisallowedRoots @($stateRoot, $durableRoot)
$expectedRoleScripts = @{
    reviewer = Join-Path $toolkitRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
    'review-handler' = Join-Path $toolkitRoot 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1'
}
foreach ($role in @($descriptor.roles.Keys)) {
    if ($role -notin @('reviewer', 'review-handler')) { throw "Broker descriptor contains unsupported role '$role'." }
    $roleDescriptor = $descriptor.roles[$role]
    $roleDescriptor.scriptPath = Assert-AgentTrustedFile -Path ([IO.Path]::GetFullPath([string]$roleDescriptor.scriptPath)) `
        -AllowedRoot $toolkitRoot -ExpectedPath $expectedRoleScripts[$role]
    $configRoot = [IO.Path]::GetFullPath([string]$roleDescriptor.configRoot)
    if (-not (Test-Path -LiteralPath $configRoot -PathType Container)) {
        throw "Broker configuration root does not exist: $configRoot"
    }
    $expectedConfigPath = [IO.Path]::GetFullPath([string]$roleDescriptor.configFile)
    $roleDescriptor.configRoot = $configRoot
    $roleDescriptor.configFile = Assert-AgentTrustedFile -Path $expectedConfigPath `
        -AllowedRoot $configRoot -ExpectedPath $expectedConfigPath
}
$writerGate = [object]::new()
$drafts = @{}
$children = @{}
$requestIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$requestIdOrder = [Collections.Generic.Queue[string]]::new()
# issue #105 PR4 (requirement 4): global requestId anti-replay tracking is bounded, not unbounded --
# a long-lived broker process must not grow $requestIds forever. Oldest ids are evicted once the
# tracked count exceeds this cap; replay protection only needs to hold for a request's realistic
# in-flight lifetime, not for the lifetime of the broker process.
[int]$MaxTrackedRequestIds = 8192
# issue #105 PR4: short TTL for each interactive widening confirmation step (describe-widening's
# challenge1, confirm-widening-preview's challenge2); a minted grant's own expiry is instead bound
# to the draft's own DraftLifetimeSeconds (a grant never outlives the draft it was minted for).
[int]$WideningChallengeTtlSeconds = 60
# PR3: in-memory-only preview bindings for the narrow-only settings editor (preview-narrowing /
# apply-narrowing). Never persisted, never a reusable proof -- a token is consumed (removed) the
# instant apply-narrowing succeeds, and any expired or otherwise-consumed token fails closed,
# requiring a fresh preview. Broker-local, exactly like $drafts.
$narrowingPreviews = @{}
$accepting = $true

function Register-BrokerRequestId {
    <#
        Bounded anti-replay set (issue #105 PR4 requirement 4): returns $false (caller must reject)
        if Id was already registered; otherwise registers it and evicts the oldest tracked id once
        the bound is exceeded, keeping memory bounded across a long-lived broker process.
    #>
    param([Parameter(Mandatory)][string]$Id)
    if (-not $requestIds.Add($Id)) { return $false }
    $requestIdOrder.Enqueue($Id)
    while ($requestIdOrder.Count -gt $MaxTrackedRequestIds) { [void]$requestIds.Remove($requestIdOrder.Dequeue()) }
    return $true
}

function Get-OptionalMember {
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Write-DispatchProtocolMessage {
    param([Parameter(Mandatory)][hashtable]$Message)
    $line = ConvertTo-AgentCanonicalJson -InputObject $Message
    $bytes = $utf8.GetByteCount($line) + 1
    if ($bytes -gt $MaximumLineBytes) { throw 'Protocol output exceeds the line limit.' }
    [Threading.Monitor]::Enter($writerGate)
    try {
        [Console]::Out.WriteLine($line)
        [Console]::Out.Flush()
    }
    finally { [Threading.Monitor]::Exit($writerGate) }
}

function Write-Rejection {
    param([string]$RequestId, [string]$Code, [string]$Detail = '')
    $safeDetail = ($Detail -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]', '?')
    if ($safeDetail.Length -gt 1024) { $safeDetail = $safeDetail.Substring(0, 1024) }
    Write-DispatchProtocolMessage @{
        schemaVersion = 1; requestId = $RequestId; operation = 'rejected'
        code = $Code; detail = $safeDetail
    }
}

function Get-RoleDescriptor {
    # Exact-case role validation (issue #105 PR3 completion): this is the ONE shared lookup behind
    # describe/profile/preview-narrowing (via Get-BrokerCapabilityProfile) and, redundantly but
    # harmlessly, apply-narrowing/set-kill-switch's own independent -cnotin pre-checks -- so fixing
    # it here makes all five request-facing operations reject 'Reviewer'/'REVIEWER' consistently.
    # Plain PowerShell '-notin' and Hashtable key lookup (ContainsKey/the indexer) are BOTH
    # case-insensitive by default, so 'Reviewer' would otherwise silently resolve to the same role
    # as 'reviewer'. '-cnotin' rejects any non-exact-case role before $descriptor.roles is ever
    # consulted, and filtering .Keys with '-ceq' (rather than trusting ContainsKey/the indexer,
    # both case-insensitive on this Hashtable) is what actually retrieves the entry -- so no future
    # change to either check alone could reintroduce the casing bypass.
    param([string]$Role)
    $roleKeys = @($descriptor.roles.Keys | Where-Object { $_ -ceq $Role })
    if ($Role -cnotin @('reviewer', 'review-handler') -or $roleKeys.Count -ne 1) {
        throw '[role-not-allowed] The requested manual role is not configured.'
    }
    $roleDescriptor = $descriptor.roles[$roleKeys[0]]
    if (-not [bool]$roleDescriptor.enabled) { throw '[role-not-allowed] The requested manual role is disabled.' }
    $harnessRole = Get-AgentHarnessCapabilityDescriptor -Role $Role
    $allowedCapabilities = $harnessRole.allowedManualCapabilities
    $requiredDeny = $harnessRole.delegableDefaultOff
    $capabilities = @($roleDescriptor.capabilities)
    $mandatoryDenies = @($roleDescriptor.mandatoryDenies)
    if ($mandatoryDenies -cnotcontains $requiredDeny -or
        @($capabilities | Where-Object { $mandatoryDenies -ccontains $_ }).Count -gt 0 -or
        @($capabilities | Where-Object { $allowedCapabilities -cnotcontains $_ }).Count -gt 0) {
        throw '[role-not-allowed] The configured manual capability policy is inconsistent.'
    }
    return $roleDescriptor
}

function Remove-DraftResidue {
    param([Parameter(Mandatory)][hashtable]$Draft)
    if ($Draft.ContainsKey('PromptGuard') -and $Draft['PromptGuard']) {
        $Draft['PromptGuard'].Dispose()
        $Draft['PromptGuard'] = $null
    }
    if ($Draft.ContainsKey('Guardian') -and $Draft['Guardian']) {
        $terminalPath = Join-Path $Draft.Snapshot.RuntimeRoot "guardian-$($Draft.GuardianToken).terminal.json"
        [IO.File]::WriteAllText($terminalPath, (ConvertTo-AgentCanonicalJson ([ordered]@{
                    schemaVersion = 1; operation = 'terminal-handoff'; token = [string]$Draft.GuardianToken
                })), [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($terminalPath,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        [void]$Draft['Guardian'].Process.WaitForExit(5000)
        $Draft['Guardian'].Process.Refresh()
        if (-not $Draft['Guardian'].Process.HasExited) {
            Stop-ProcessTree $Draft['Guardian'].Process
            [void]$Draft['Guardian'].Process.WaitForExit(5000)
        }
        [void](Complete-AgentRedirectedProcess $Draft['Guardian'])
        $Draft['Guardian'] = $null
    }
    $draftRoot = [IO.Path]::GetFullPath([string]$Draft.Snapshot.Root)
    $manualRoot = [IO.Path]::GetFullPath((Join-Path $stateRoot 'manual-dispatch'))
    Remove-AgentContainedDirectory -Path $draftRoot -AllowedRoot $manualRoot `
        -LeafPattern '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

function Remove-ExpiredDrafts {
    $now = [DateTime]::UtcNow
    # issue #105 PR4 requirement 7: a CONSUMED draft that never made it into (or already left)
    # $children means Invoke-Dispatch failed/threw somewhere after marking it Consumed -- before,
    # during, or after child launch. Invoke-Dispatch's own catch block best-effort-cleans the most
    # common failure point immediately; this is the unconditional backstop (runs every loop tick,
    # ~every 100ms) that guarantees no consumed draft, and no sealed grant artifact under its
    # runtime root, is EVER left behind indefinitely regardless of which failure path produced it.
    $activeDraftIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $children.Values) { [void]$activeDraftIds.Add([string]$entry.DraftId) }
    foreach ($id in @($drafts.Keys)) {
        $draft = $drafts[$id]
        if ($draft.Consumed) {
            if (-not $activeDraftIds.Contains($id)) {
                if ($draft.Widening -and $draft.Widening.Stage -ceq 'minted') {
                    Remove-AgentWideningGrantArtifact -RuntimeRoot $draft.Snapshot.RuntimeRoot
                }
                Remove-DraftResidue $draft
                $drafts.Remove($id)
            }
            continue
        }
        if (($now - $draft.CreatedAt).TotalSeconds -le $DraftLifetimeSeconds) {
            continue
        }
        Remove-DraftResidue $draft
        $drafts.Remove($id)
    }
}

function Remove-ExpiredNarrowingPreviews {
    $now = [DateTime]::UtcNow
    foreach ($token in @($narrowingPreviews.Keys)) {
        if ($now -ge $narrowingPreviews[$token].ExpiresAtUtc) { $narrowingPreviews.Remove($token) }
    }
}

function Open-BrokerProvider {
    param([hashtable]$RoleDescriptor)
    $configurationRoot = [IO.Path]::GetFullPath([string]$RoleDescriptor.configRoot)
    $expectedConfigPath = [IO.Path]::GetFullPath([string]$RoleDescriptor.configFile)
    $configPath = Assert-AgentTrustedFile -Path ([IO.Path]::GetFullPath([string]$RoleDescriptor.configFile)) `
        -AllowedRoot $configurationRoot -ExpectedPath $expectedConfigPath
    $repositoryRootValue = Get-OptionalMember $RoleDescriptor 'repositoryRoot'
    $repositoryRoot = if ($repositoryRootValue) {
        [IO.Path]::GetFullPath([string]$repositoryRootValue)
    }
    else {
        Resolve-AgentRepositoryRoot -ConfigPath $configPath
    }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 50 -ErrorAction Stop
    $repository = $config.repository
    $provider = [string]$config.provider
    if ($provider -eq 'GitHub') {
        $context = New-AgentProviderContext -Provider GitHub -Organization ([string]$repository.organization) `
            -RepositoryName ([string]$repository.name) -TimeoutSeconds 10
        return @{ ConfigPath = $configPath; Config = $config; Context = $context; Session = $null; RepositoryRoot = $repositoryRoot }
    }
    $agency = Get-Command agency -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $session = Open-AgentMcpSession -AgencyPath $agency.Source -Server ado `
        -Organization ([string]$repository.organization) -Toolsets @('repos') -TimeoutSeconds 10
    $invoker = {
        param($Name, $Arguments, $RawText)
        Invoke-AgentMcpTool -Session $session -Name $Name -Arguments $Arguments -RawText:$RawText
    }.GetNewClosure()
    $context = New-AgentProviderContext -Provider AzureDevOps -Organization ([string]$repository.organization) `
        -Project ([string]$repository.project) -RepositoryName ([string]$repository.name) `
        -RepositoryId ([string]$repository.id) -McpInvoker $invoker -TimeoutSeconds 10
    return @{ ConfigPath = $configPath; Config = $config; Context = $context; Session = $session; RepositoryRoot = $repositoryRoot }
}

function Get-BrokerPullRequest {
    param([hashtable]$Provider, [int]$PullRequestId)
    if ($Provider.Context.Provider -eq 'GitHub') {
        return Get-AgentProviderPullRequestSnapshot -Context $Provider.Context -PullRequestId $PullRequestId
    }
    return & $Provider.Context.McpInvoker 'repo_pull_request' @{
        action = 'get'; orgName = $Provider.Context.Organization; project = $Provider.Context.Project
        repositoryId = $Provider.Context.RepositoryName; pullRequestId = $PullRequestId
    } $false
}

function ConvertTo-BrokerPrSnapshot {
    param($PullRequest, [int]$PullRequestId)
    $sourceCommitValue = Get-OptionalMember $PullRequest 'sourceCommitId'
    $sourceCommit = [string]$(if ($sourceCommitValue) { $sourceCommitValue } else {
            Get-OptionalMember (Get-OptionalMember $PullRequest 'lastMergeSourceCommit') 'commitId'
        })
    $sourceRefValue = Get-OptionalMember $PullRequest 'sourceRefName'
    $sourceRef = [string]$(if ($sourceRefValue) { $sourceRefValue } else {
            Get-OptionalMember (Get-OptionalMember $PullRequest 'head') 'ref'
        })
    $targetRefValue = Get-OptionalMember $PullRequest 'targetRefName'
    $targetRef = [string]$(if ($targetRefValue) { $targetRefValue } else {
            Get-OptionalMember (Get-OptionalMember $PullRequest 'base') 'ref'
        })
    $status = [string]$PullRequest.status
    return [ordered]@{
        schemaVersion = 1; pullRequestId = $PullRequestId
        sourceCommit = $sourceCommit.ToLowerInvariant()
        sourceRef = $sourceRef; targetRef = $targetRef
        active = $status -in @('active', 'open')
        draft = [bool](Get-OptionalMember $PullRequest 'isDraft')
        author = [string]$(if (Get-OptionalMember $PullRequest 'authorAlias') {
                Get-OptionalMember $PullRequest 'authorAlias'
            } elseif (Get-OptionalMember $PullRequest 'createdBy') {
                Get-OptionalMember (Get-OptionalMember $PullRequest 'createdBy') 'id'
            } else {
                Get-OptionalMember (Get-OptionalMember $PullRequest 'user') 'login'
            })
        title = [string]$PullRequest.title
    }
}

function New-ConfigSnapshot {
    param([hashtable]$RoleDescriptor, [hashtable]$Provider, [string]$DraftId)
    $root = Join-Path (Join-Path $stateRoot 'manual-dispatch') $DraftId
    $configRoot = Join-Path (Join-Path $root 'runtime') 'config'
    New-Item -ItemType Directory -Path $configRoot -Force -ErrorAction Stop | Out-Null
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($root, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        [IO.File]::SetUnixFileMode((Split-Path $configRoot -Parent), [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        [IO.File]::SetUnixFileMode($configRoot, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    $snapshotPath = Join-Path $configRoot 'agent.config.snapshot.json'
    $snapshotBytes = [IO.File]::ReadAllBytes($Provider.ConfigPath)
    [IO.File]::WriteAllBytes($snapshotPath, $snapshotBytes)
    if ($IsWindows) {
        (Get-Item -LiteralPath $snapshotPath).IsReadOnly = $true
    }
    else {
        [IO.File]::SetUnixFileMode($snapshotPath, [IO.UnixFileMode]::UserRead)
        [IO.File]::SetUnixFileMode($configRoot, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserExecute)
    }
    return @{
        Root = $root; RuntimeRoot = (Split-Path $configRoot -Parent); SnapshotPath = $snapshotPath
        SnapshotLength = $snapshotBytes.Length
        SnapshotSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($snapshotBytes)).ToLowerInvariant()
    }
}

function Get-BrokerNarrowingEffect {
    # Shared provenance/partition builder reused by Get-BrokerCapabilityProfile (the live effective
    # profile) and Invoke-PreviewNarrowing (a hypothetical hop over the same live data) -- exactly
    # ONE place decides how a resolved override turns into {capabilities, mandatoryDenies,
    # provenance}, so a preview's "proposed" effect can never drift from what describe/profile/apply
    # would themselves compute for the identical override.
    param(
        [Parameter(Mandatory)][hashtable]$RoleDescriptor,
        [Parameter(Mandatory)][string[]]$AllowedManualCapabilities,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AbsoluteDenies,
        [Parameter(Mandatory)][hashtable]$Override
    )
    $mandatoryDeniesBase = @($RoleDescriptor.mandatoryDenies | Sort-Object -Unique)
    $provenance = [ordered]@{}
    foreach ($name in @($AllowedManualCapabilities + $mandatoryDeniesBase + $AbsoluteDenies | Sort-Object -Unique)) {
        $provenance[$name] = 'operational-default'
    }
    $partition = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $RoleDescriptor -PersistedNarrowing $Override.Settings
    if ([bool]$Override.KillSwitchActive) {
        # Emergency lever (PR3): every capability's provenance reads 'kill-switch', not
        # 'operational-default' -- the operator can see overrides exist but are being ignored,
        # distinct from a genuinely empty store.
        foreach ($name in @($provenance.Keys | Sort-Object)) { $provenance[$name] = 'kill-switch' }
    }
    else {
        foreach ($name in @($Override.Provenance.Keys)) { $provenance[$name] = $Override.Provenance[$name] }
    }
    return @{ capabilities = $partition.capabilities; mandatoryDenies = $partition.mandatoryDenies; provenance = $provenance }
}

function Get-BrokerCapabilityProfile {
    # Shared, side-effect-free profile builder for describe (capability-summary) and the read-only
    # profile operation (capability-profile): role/PR validation, provider reads, dynamic
    # constraints, and the capability ceiling. Never allocates a dispatchDraftId, config snapshot,
    # RuntimeRoot, or $drafts entry -- callers decide independently whether to allocate one
    # (Invoke-Describe only). On failure, closes the provider session itself before rethrowing;
    # on success, the caller owns closing Provider.Session once it is done with it.
    param([hashtable]$Request)
    Remove-ExpiredDrafts
    $role = [string]$Request.role
    $prId = [int]$Request.pullRequestId
    if ($prId -le 0) { throw '[invalid-request] pullRequestId must be positive.' }
    $roleDescriptor = Get-RoleDescriptor $role
    $provider = Open-BrokerProvider $roleDescriptor
    try {
        $roleDescriptor['repositoryRoot'] = $provider.RepositoryRoot
        $identity = Resolve-AgentProviderRepositoryIdentity -Context $provider.Context
        if ([string]$Request.repositoryKey -cne [string]$identity.key) { throw '[repository-mismatch] Repository key does not match the provider.' }
        $pr = ConvertTo-BrokerPrSnapshot -PullRequest (Get-BrokerPullRequest $provider $prId) -PullRequestId $prId
        if (-not $pr.active -or $pr.draft) { throw '[pr-state-changed] Pull request is not active and ready.' }
        $constraints = @()
        if ($role -eq 'reviewer') {
            $durableContext = Get-AgentDurableStateContext -DurableStateRoot $durableRoot `
                -RepositoryIdentity $identity -Role reviewer
            $records = Get-AgentDurableRecordsSnapshot -Context $durableContext
            if (Test-AgentReviewerDeliveryPending -Records $records -PullRequestId $prId `
                    -SourceCommit $pr.sourceCommit) {
                $constraints += 'delivery-pending'
            }
        }
        $capabilities = @($roleDescriptor.capabilities | Sort-Object -Unique)
        $mandatoryDenies = @($roleDescriptor.mandatoryDenies | Sort-Object -Unique)
        $harnessRole = Get-AgentHarnessCapabilityDescriptor -Role $role
        $absoluteDenies = @($harnessRole.absoluteDenies | Sort-Object -Unique)
        $allowedManualCapabilities = @($harnessRole.allowedManualCapabilities | Sort-Object -Unique)
        # issue #105 PR4: delegableAvailable reflects the checked-in delegation policy for THIS
        # role/repository -- never a wildcard, since the schema has no allow-any escape hatch. The
        # shipped policy ships with an empty allowlist for every role, so this is always @() until a
        # CODEOWNERS-approved policy change explicitly names a repository key (see
        # delegation.policy.v1.json). issue #105 PR4 requirement 3/9: an unavailable/unloadable
        # policy (missing file, real-checkout ACL failure, corrupt content) fails CLOSED for
        # delegation only -- delegableAvailable stays @() -- while this profile/describe RPC itself
        # keeps working normally; only the widening endpoints reject distinctly for that condition.
        $delegationPolicy = Get-AgentDelegationPolicyOrNull -ToolkitRoot $toolkitRoot
        $delegableAvailable = @()
        if ($delegationPolicy -and
            (Test-AgentDelegationAllows -Policy $delegationPolicy -Role $role -Capability $harnessRole.delegableDefaultOff -RepositoryKey $identity.key)) {
            $delegableAvailable = @($harnessRole.delegableDefaultOff)
        }
        # PR2: narrow the operational-default ceiling by any persisted, outside-repository
        # capability override. Overrides can only ever remove an active capability, never add one
        # (Resolve-AgentCapabilityPolicyPartition). A resolution failure (corrupt/stale/expired/
        # oversized/unsafe-path override record) fails this whole describe/profile call closed
        # rather than silently falling back to the un-narrowed ceiling -- that fallback would be a
        # silent widening from the operator's own last-known-good intent.
        #
        # Holds the same capability-override lock every PR3 writer (Set-AgentCapabilityOverrideSetting,
        # Enable-/Disable-AgentCapabilityOverrideKillSwitch) takes before its atomic replace, so a
        # cooperating writer's delete/rename can never interleave with this
        # read. A file that still vanishes out from under us while the lock is held (Resolve-
        # AgentEffectiveCapabilitySettings surfaces this as the distinct [stable-read-unstable]
        # signal, never as ordinary "invalid"/corrupt content) is retried exactly once under the
        # SAME lock acquisition; if it still cannot be read, that same distinct, explicitly-
        # retryable failure is what this call fails closed with -- it is never reinterpreted as
        # "no override" (that would silently widen the effective ceiling) or as malformed content.
        $ceilingCapabilities = $capabilities
        $ceilingMandatoryDenies = $mandatoryDenies
        $capabilityLock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $provider.RepositoryRoot -TimeoutMilliseconds 2000
        if (-not $capabilityLock.Acquired) { throw "[already-running] $($capabilityLock.Reason)" }
        try {
            $override = $null
            for ($resolveAttempt = 1; $resolveAttempt -le 2; $resolveAttempt++) {
                try {
                    $override = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity `
                        -RepositoryRoot $provider.RepositoryRoot -PullRequestId $prId -CurrentSourceCommit $pr.sourceCommit
                    break
                }
                catch {
                    if ($resolveAttempt -ge 2 -or $_.Exception.Message -notmatch '^\[stable-read-unstable\]') { throw }
                }
            }
        }
        finally {
            Exit-AgentLock $capabilityLock.Stream
        }
        $effect = Get-BrokerNarrowingEffect -RoleDescriptor $roleDescriptor -AllowedManualCapabilities $allowedManualCapabilities `
            -AbsoluteDenies $absoluteDenies -Override $override
        $capabilities = $effect.capabilities
        $mandatoryDenies = $effect.mandatoryDenies
        $provenance = $effect.provenance
    }
    catch {
        if ($provider.Session) { Close-AgentMcpSession $provider.Session }
        throw
    }
    return @{
        Role = $role; RoleDescriptor = $roleDescriptor; Provider = $provider; PullRequestId = $prId
        Identity = $identity; Pr = $pr; Constraints = $constraints
        Capabilities = $capabilities; MandatoryDenies = $mandatoryDenies
        CeilingCapabilities = $ceilingCapabilities; CeilingMandatoryDenies = $ceilingMandatoryDenies
        AbsoluteDenies = $absoluteDenies; AllowedManualCapabilities = $allowedManualCapabilities
        DelegableAvailable = $delegableAvailable; Provenance = $provenance
        Override = $override
    }
}

function Invoke-Describe {
    param([hashtable]$Request)
    $profile = Get-BrokerCapabilityProfile $Request
    $role = $profile.Role
    $roleDescriptor = $profile.RoleDescriptor
    $provider = $profile.Provider
    try {
        $draftId = [Guid]::NewGuid().ToString('D')
        $snapshot = New-ConfigSnapshot $roleDescriptor $provider $draftId
        $policy = [ordered]@{
            schemaVersion = 1; repositoryIdentity = $profile.Identity; role = $role
            capabilities = $profile.Capabilities; mandatoryDenies = $profile.MandatoryDenies
            ceilingCapabilities = $profile.CeilingCapabilities; ceilingMandatoryDenies = $profile.CeilingMandatoryDenies
            configSnapshotSha256 = $snapshot.SnapshotSha256
        }
        $policyDigest = Get-AgentCanonicalDigest $policy
        $prFingerprint = Get-AgentCanonicalDigest ([ordered]@{
                schemaVersion = 1; repositoryKey = $profile.Identity.key; pullRequestId = $profile.PullRequestId
                sourceCommit = $profile.Pr.sourceCommit; sourceRef = $profile.Pr.sourceRef; targetRef = $profile.Pr.targetRef
                active = $profile.Pr.active; draft = $profile.Pr.draft; author = $profile.Pr.author
            })
        $drafts[$draftId] = @{
            CreatedAt = [DateTime]::UtcNow; Consumed = $false; Role = $role; PullRequestId = $profile.PullRequestId
            RepositoryIdentity = $profile.Identity; PrSnapshot = $profile.Pr; Policy = $policy
            PolicyDigest = $policyDigest; PrFingerprint = $prFingerprint
            Snapshot = $snapshot; RoleDescriptor = $roleDescriptor
            PromptGuard = $null; Guardian = $null; GuardianToken = $null
            # issue #105 PR4: no widening requested yet. Widening is set only by describe-widening
            # and cleared back to $null by cancel-widening/Invoke-TerminalDraftFailure-style resets;
            # WideningGeneration increments on every widening state transition so cancel-widening can
            # detect and reject a stale request bound to an already-superseded widening attempt.
            Widening = $null; WideningGeneration = 0
        }
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'capability-summary'
            dispatchDraftId = $draftId; role = $role; repositoryIdentity = $profile.Identity; prSnapshot = $profile.Pr
            capabilityPolicyDigest = $policyDigest; prStateFingerprint = $prFingerprint
            capabilities = $profile.Capabilities; mandatoryDenies = $profile.MandatoryDenies; dynamicConstraints = $profile.Constraints
            absoluteDenies = $profile.AbsoluteDenies; allowedManualCapabilities = $profile.AllowedManualCapabilities
            delegableAvailable = $profile.DelegableAvailable; provenance = $profile.Provenance
            killSwitchActive = [bool]$profile.Override.KillSwitchActive
            killSwitchExpiresAtUtc = $profile.Override.KillSwitchExpiresAtUtc
        }
    }
    finally { if ($provider.Session) { Close-AgentMcpSession $provider.Session } }
}

function Invoke-Profile {
    # Read-only effective-capability-profile inspection (PR1): the Settings TUI's dedicated broker
    # RPC. Shares Get-BrokerCapabilityProfile with Invoke-Describe for the common role/repository/PR
    # reads and capability ceiling, but never allocates a dispatchDraftId, config snapshot,
    # RuntimeRoot, or $drafts entry -- repeated or overlapping calls (refresh, close/reopen) leave
    # no broker-side residue. Omits dispatchDraftId/capabilityPolicyDigest/prStateFingerprint
    # entirely: none is meaningful without a config snapshot to bind it to.
    param([hashtable]$Request)
    $profile = Get-BrokerCapabilityProfile $Request
    $provider = $profile.Provider
    try {
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'capability-profile'
            role = $profile.Role; repositoryIdentity = $profile.Identity; prSnapshot = $profile.Pr
            capabilities = $profile.Capabilities; mandatoryDenies = $profile.MandatoryDenies; dynamicConstraints = $profile.Constraints
            absoluteDenies = $profile.AbsoluteDenies; allowedManualCapabilities = $profile.AllowedManualCapabilities
            delegableAvailable = $profile.DelegableAvailable; provenance = $profile.Provenance
            killSwitchActive = [bool]$profile.Override.KillSwitchActive
            killSwitchExpiresAtUtc = $profile.Override.KillSwitchExpiresAtUtc
        }
    }
    finally { if ($provider.Session) { Close-AgentMcpSession $provider.Session } }
}

function Invoke-PreviewNarrowing {
    # PR3: non-mutating preview/diff for a single hypothetical scope-file edit. Never writes
    # anything, never creates a dispatch draft/snapshot. Returns the CURRENT effective profile and
    # the PROPOSED effective profile if the requested {scope, capability, action} were applied,
    # resolved back-to-back under ONE capability-override lock acquisition (issue #105 PR3 review:
    # current/proposed/storeFingerprint must all come from the identical locked snapshot, never
    # from two separate lock acquisitions a concurrent writer could interleave between), and a
    # short-lived, single-use previewToken binding this exact mutation to the exact repository/
    # worktree/PR-fingerprint/role/store-fingerprint apply-narrowing must re-verify before it is
    # allowed to write.
    param([hashtable]$Request)
    $scope = [string]$Request.scope
    if ($scope -cnotin @('machine', 'user', 'repo-worktree', 'pr')) { throw '[narrowing-invalid] scope is not a recognized value.' }
    $action = [string]$Request.action
    if ($action -cnotin @('off', 'inherit')) { throw '[narrowing-invalid] action is not a recognized value.' }
    $capability = [string]$Request.capability
    if ($capability -cnotmatch '^[A-Za-z][A-Za-z0-9]*$') { throw '[narrowing-invalid] capability is not a recognized value.' }
    $profile = Get-BrokerCapabilityProfile $Request
    $provider = $profile.Provider
    try {
        if ($capability -cnotin @($profile.AllowedManualCapabilities)) {
            throw "[narrowing-invalid] capability is not a recognized manually-selectable capability for role '$($profile.Role)'."
        }
        $worktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $provider.RepositoryRoot
        $hypothetical = @{ Scope = $scope; Capability = $capability; Action = $action }
        $capabilityLock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $provider.RepositoryRoot -TimeoutMilliseconds 2000
        if (-not $capabilityLock.Acquired) { throw "[already-running] $($capabilityLock.Reason)" }
        try {
            for ($resolveAttempt = 1; $resolveAttempt -le 2; $resolveAttempt++) {
                try {
                    # Single locked snapshot: current and proposed are resolved back-to-back inside
                    # the SAME lock acquisition, so neither can ever observe a different underlying
                    # file state than the other -- and storeFingerprint below is derived from this
                    # identical currentOverride read, never from a separate, earlier acquisition.
                    $currentOverride = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $profile.Identity `
                        -RepositoryRoot $provider.RepositoryRoot -PullRequestId $profile.PullRequestId -CurrentSourceCommit $profile.Pr.sourceCommit
                    $proposedOverride = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $profile.Identity `
                        -RepositoryRoot $provider.RepositoryRoot -PullRequestId $profile.PullRequestId `
                        -CurrentSourceCommit $profile.Pr.sourceCommit -HypotheticalOverride $hypothetical
                    break
                }
                catch {
                    if ($resolveAttempt -ge 2 -or $_.Exception.Message -notmatch '^\[stable-read-unstable\]') { throw }
                }
            }
        }
        finally {
            Exit-AgentLock $capabilityLock.Stream
        }
        if ([bool]$currentOverride.KillSwitchActive) {
            # Fail-closed (issue #105 PR3 review): the kill switch makes every persisted override
            # inert, so a preview computed while it is active would show a "proposed" effect that
            # could never actually take hold -- and, worse, a subsequent apply would still be free
            # to WRITE a hidden override that only takes effect once the kill switch is later
            # disabled. Reject outright; the UI never even opens the editor in this state (see
            # tryOpenNarrowingEditor), so reaching here means the kill switch was toggled on
            # concurrently after the editor was already open.
            throw '[narrowing-kill-switch-active] Editing is unavailable while the kill switch is active.'
        }
        $currentEffect = Get-BrokerNarrowingEffect -RoleDescriptor $profile.RoleDescriptor `
            -AllowedManualCapabilities $profile.AllowedManualCapabilities -AbsoluteDenies $profile.AbsoluteDenies `
            -Override $currentOverride
        $proposedEffect = Get-BrokerNarrowingEffect -RoleDescriptor $profile.RoleDescriptor `
            -AllowedManualCapabilities $profile.AllowedManualCapabilities -AbsoluteDenies $profile.AbsoluteDenies `
            -Override $proposedOverride
        $storeFingerprint = Get-AgentCanonicalDigest -InputObject $currentOverride.FileFingerprints
        # Full PR-state binding (issue #105 PR3 review): a digest of every PR field apply-narrowing
        # re-derives and re-checks at the mutation boundary, not just sourceCommit -- see
        # Invoke-ApplyNarrowing's prFingerprint recheck.
        $prFingerprint = Get-AgentCanonicalDigest ([ordered]@{
                schemaVersion = 1; repositoryKey = $profile.Identity.key; pullRequestId = $profile.PullRequestId
                sourceCommit = $profile.Pr.sourceCommit; sourceRef = $profile.Pr.sourceRef; targetRef = $profile.Pr.targetRef
                active = $profile.Pr.active; draft = $profile.Pr.draft; author = $profile.Pr.author
            })
        $token = [Guid]::NewGuid().ToString('D')
        $expiresAtUtc = [DateTime]::UtcNow.AddSeconds($NarrowingPreviewTtlSeconds)
        $narrowingPreviews[$token] = @{
            ExpiresAtUtc = $expiresAtUtc; RepositoryKey = $profile.Identity.key; WorktreeId = $worktreeId
            PullRequestId = $profile.PullRequestId; PrFingerprint = $prFingerprint
            Role = $profile.Role; Scope = $scope; Capability = $capability; Action = $action
            StoreFingerprint = $storeFingerprint
        }
        $currentJson = ConvertTo-AgentCanonicalJson ([ordered]@{
                capabilities = $currentEffect.capabilities; mandatoryDenies = $currentEffect.mandatoryDenies; provenance = $currentEffect.provenance
            })
        $proposedJson = ConvertTo-AgentCanonicalJson ([ordered]@{
                capabilities = $proposedEffect.capabilities; mandatoryDenies = $proposedEffect.mandatoryDenies
                provenance = $proposedEffect.provenance
            })
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'narrowing-preview'
            state = 'previewed'; role = $profile.Role; repositoryIdentity = $profile.Identity; prSnapshot = $profile.Pr
            scope = $scope; capability = $capability; action = $action
            previewToken = $token; storeFingerprint = $storeFingerprint; expiresAtUtc = $expiresAtUtc.ToString('o')
            killSwitchActive = [bool]$currentOverride.KillSwitchActive; changed = ($currentJson -cne $proposedJson)
            current = @{ capabilities = $currentEffect.capabilities; mandatoryDenies = $currentEffect.mandatoryDenies; provenance = $currentEffect.provenance }
            proposed = @{
                capabilities = $proposedEffect.capabilities; mandatoryDenies = $proposedEffect.mandatoryDenies
                provenance = $proposedEffect.provenance
            }
        }
    }
    finally { if ($provider.Session) { Close-AgentMcpSession $provider.Session } }
}

function Invoke-ApplyNarrowing {
    # PR3: the only mutating operation the dashboard can drive. Requires an exact, still-valid
    # previewToken -- role/scope/capability/action/storeFingerprint must match the bound preview
    # exactly, the token must not have expired, and the live store fingerprint re-derived HERE,
    # under the same exclusive lock the write itself uses, must still match what was bound at
    # preview time. Any mismatch fails closed with a code that requires a fresh preview; the token
    # is consumed (removed) the instant a write succeeds, so it can never be replayed.
    param([hashtable]$Request)
    $token = [string]$Request.previewToken
    if ($token -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or -not $narrowingPreviews.ContainsKey($token)) {
        throw '[narrowing-stale] Preview token is unknown, already consumed, or malformed; re-preview and try again.'
    }
    $bound = $narrowingPreviews[$token]
    if ([DateTime]::UtcNow -ge $bound.ExpiresAtUtc) {
        $narrowingPreviews.Remove($token)
        throw '[narrowing-expired] Preview has expired; re-preview and try again.'
    }
    $role = [string]$Request.role
    $scope = [string]$Request.scope
    $capability = [string]$Request.capability
    $action = [string]$Request.action
    $storeFingerprint = [string]$Request.storeFingerprint
    if ($role -cnotin @('reviewer', 'review-handler') -or $scope -cnotin @('machine', 'user', 'repo-worktree', 'pr') -or
        $action -cnotin @('off', 'inherit') -or $capability -cnotmatch '^[A-Za-z][A-Za-z0-9]*$') {
        throw '[narrowing-invalid] role, scope, capability, or action is not a recognized value.'
    }
    if ($role -cne $bound.Role -or $scope -cne $bound.Scope -or $capability -cne $bound.Capability -or
        $action -cne $bound.Action -or $storeFingerprint -cne $bound.StoreFingerprint) {
        throw '[narrowing-stale] Apply request does not match the previewed mutation; re-preview and try again.'
    }
    $roleDescriptor = Get-RoleDescriptor $role
    $provider = Open-BrokerProvider $roleDescriptor
    try {
        $roleDescriptor['repositoryRoot'] = $provider.RepositoryRoot
        $identity = Resolve-AgentProviderRepositoryIdentity -Context $provider.Context
        if ([string]$Request.repositoryKey -cne [string]$identity.key -or $identity.key -cne $bound.RepositoryKey) {
            throw '[repository-mismatch] Repository identity changed since the preview.'
        }
        $worktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $provider.RepositoryRoot
        if ($worktreeId -cne $bound.WorktreeId) { throw '[narrowing-stale] Worktree changed since the preview; re-preview and try again.' }
        $prId = [int]$Request.pullRequestId
        if ($prId -ne $bound.PullRequestId) { throw '[narrowing-stale] Pull request changed since the preview; re-preview and try again.' }
        $pr = ConvertTo-BrokerPrSnapshot -PullRequest (Get-BrokerPullRequest $provider $prId) -PullRequestId $prId
        # Full PR-state revalidation at the mutation boundary (issue #105 PR3 review): re-checking
        # active/non-draft here, not just at preview time, is required -- Get-BrokerCapabilityProfile's
        # own [pr-state-changed] guard only ever ran against the PREVIEW-time read. A PR that was
        # merged, closed, or converted to draft between preview and apply must still be rejected here.
        if (-not $pr.active -or $pr.draft) { throw '[pr-state-changed] Pull request is not active and ready.' }
        # Compares the FULL PR fingerprint (sourceCommit, sourceRef, targetRef, active, draft,
        # author), not just sourceCommit, against the identical digest Invoke-PreviewNarrowing bound
        # -- a retarget or author change with an unchanged sourceCommit must still be caught.
        $prFingerprint = Get-AgentCanonicalDigest ([ordered]@{
                schemaVersion = 1; repositoryKey = $identity.key; pullRequestId = $prId
                sourceCommit = $pr.sourceCommit; sourceRef = $pr.sourceRef; targetRef = $pr.targetRef
                active = $pr.active; draft = $pr.draft; author = $pr.author
            })
        if ($prFingerprint -cne $bound.PrFingerprint) { throw '[narrowing-stale] Pull request changed since the preview; re-preview and try again.' }
        $harnessRole = Get-AgentHarnessCapabilityDescriptor -Role $role
        if ($capability -cnotin @($harnessRole.allowedManualCapabilities)) {
            throw "[narrowing-invalid] capability is not a recognized manually-selectable capability for role '$role'."
        }
        $allAllowedCapabilities = [Collections.Generic.List[string]]::new()
        foreach ($knownRole in @('reviewer', 'review-handler')) {
            foreach ($name in @((Get-AgentHarnessCapabilityDescriptor -Role $knownRole).allowedManualCapabilities)) {
                if (-not $allAllowedCapabilities.Contains($name)) { [void]$allAllowedCapabilities.Add($name) }
            }
        }
        $capabilityLock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $provider.RepositoryRoot -TimeoutMilliseconds 2000
        if (-not $capabilityLock.Acquired) { throw "[already-running] $($capabilityLock.Reason)" }
        try {
            $liveOverride = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $identity -RepositoryRoot $provider.RepositoryRoot `
                -PullRequestId $prId -CurrentSourceCommit $pr.sourceCommit
            if ([bool]$liveOverride.KillSwitchActive) {
                # Fail-closed (issue #105 PR3 review): mirrors Invoke-PreviewNarrowing's own check.
                # In practice a kill switch flipped on since the preview already changes
                # FileFingerprints (see below) and would be caught as [narrowing-stale] anyway, but
                # this gives the dashboard the precise, actionable rejection code instead of a
                # generic staleness message.
                throw '[narrowing-kill-switch-active] Editing is unavailable while the kill switch is active.'
            }
            $liveFingerprint = Get-AgentCanonicalDigest -InputObject $liveOverride.FileFingerprints
            if ($liveFingerprint -cne $storeFingerprint) {
                throw '[narrowing-stale] The capability-override store changed since the preview; re-preview and try again.'
            }
            Set-AgentCapabilityOverrideSetting -RepositoryIdentity $identity -RepositoryRoot $provider.RepositoryRoot `
                -PullRequestId $prId -CurrentSourceCommit $pr.sourceCommit -Scope $scope -Capability $capability `
                -Action $action -AllowedCapabilities @($allAllowedCapabilities.ToArray())
        }
        finally {
            Exit-AgentLock $capabilityLock.Stream
        }
        $narrowingPreviews.Remove($token)
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'narrowing-applied'
            state = 'applied'; role = $role; scope = $scope; capability = $capability; action = $action
            previewToken = $token
        }
    }
    finally { if ($provider.Session) { Close-AgentMcpSession $provider.Session } }
}

function Invoke-SetKillSwitch {
    # PR3 emergency operational lever. Requires only role + repositoryKey (no PR/draft binding --
    # the kill switch is a machine-wide baseline, not scoped to any one pull request). Toggling
    # takes effect for the NEXT profile()/describe()/dispatch() resolution only; it can never affect
    # an already-running child, which never re-reads persisted settings after its own startup.
    param([hashtable]$Request)
    $enabledValue = Get-OptionalMember $Request 'enabled'
    if ($enabledValue -isnot [bool]) { throw '[narrowing-invalid] enabled must be a boolean.' }
    $role = [string]$Request.role
    # Exact-case role validation (issue #105 PR3 review): Get-RoleDescriptor's own lookup goes
    # through a case-insensitive PowerShell -in check and hashtable key lookup, unlike every other
    # per-request field in this protocol. Invoke-ApplyNarrowing has its own independent, explicit
    # -cnotin check as a second layer; this endpoint had none, so it is validated here explicitly,
    # before ever calling Get-RoleDescriptor.
    if ($role -cnotin @('reviewer', 'review-handler')) { throw '[narrowing-invalid] role is not a recognized value.' }
    $roleDescriptor = Get-RoleDescriptor $role
    $provider = Open-BrokerProvider $roleDescriptor
    try {
        $roleDescriptor['repositoryRoot'] = $provider.RepositoryRoot
        $identity = Resolve-AgentProviderRepositoryIdentity -Context $provider.Context
        if ([string]$Request.repositoryKey -cne [string]$identity.key) { throw '[repository-mismatch] Repository key does not match the provider.' }
        $capabilityLock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $provider.RepositoryRoot -TimeoutMilliseconds 2000
        if (-not $capabilityLock.Acquired) { throw "[already-running] $($capabilityLock.Reason)" }
        $state = $null
        try {
            if ($enabledValue) { [void](Enable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $provider.RepositoryRoot) }
            else { Disable-AgentCapabilityOverrideKillSwitch -RepositoryRoot $provider.RepositoryRoot }
            # Read back the ACTUAL sentinel state under the SAME lock acquisition (issue #105 PR3
            # completion) -- never a second, separately-locked read, and never the request's own
            # `enabled` value -- so the response can never acknowledge a transition that did not
            # really happen, even if another process were racing for the lock immediately after
            # release. Enable-/Disable- either succeed (leaving the state consistent with the
            # requested transition) or throw (e.g. a malformed pre-existing sentinel), so this read
            # is the one place that turns "the write call didn't throw" into a verified fact.
            $state = Get-AgentCapabilityOverrideKillSwitchState -RepositoryRoot $provider.RepositoryRoot
        }
        finally {
            Exit-AgentLock $capabilityLock.Stream
        }
        if ($state.Active -ne $enabledValue) {
            throw "[kill-switch-transition-failed] Requested enabled=$enabledValue but the kill switch is actually $([bool]$state.Active)."
        }
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'kill-switch-applied'
            role = $role; enabled = [bool]$state.Active; killSwitchExpiresAtUtc = $state.ExpiresAtUtc
        }
    }
    finally { if ($provider.Session) { Close-AgentMcpSession $provider.Session } }
}

# ---------------------------------------------------------------------------
# issue #105 PR4: interactive-only, draft-bound capability widening protocol. Delegation
# eligibility is decided ENTIRELY by the checked-in delegation.policy.v1.json (shipped empty --
# safe default, no grant possible until a CODEOWNERS-approved policy change populates it) and the
# role's own single delegableDefaultOff capability; nothing here ever widens beyond that one name.
# No provider/network round trip: identity/PR are already provider-verified and bound on the draft
# from describe() time, so these four operations only ever touch the local delegation-policy file
# and the local capability-override store (both already bounded, small, synchronous reads
# elsewhere in this broker) -- keeping the interactive confirmation loop responsive.
# ---------------------------------------------------------------------------

function Get-DraftWideningCandidate {
    <#
        Resolves the draft's CURRENT (no grant) and WIDENED (Capability granted) capability
        partitions from a single fresh, lock-held read of the capability-override store -- current
        and widened can never observe different underlying file state than each other, exactly like
        Invoke-PreviewNarrowing's own current/proposed pairing.
    #>
    param([Parameter(Mandatory)][hashtable]$Draft, [Parameter(Mandatory)][string]$Capability)
    $capabilityLock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $Draft.RoleDescriptor.repositoryRoot -TimeoutMilliseconds 2000
    if (-not $capabilityLock.Acquired) { throw "[already-running] $($capabilityLock.Reason)" }
    try {
        $override = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                $override = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $Draft.RepositoryIdentity `
                    -RepositoryRoot $Draft.RoleDescriptor.repositoryRoot -PullRequestId $Draft.PullRequestId `
                    -CurrentSourceCommit $Draft.PrSnapshot.sourceCommit
                break
            }
            catch {
                if ($attempt -ge 2 -or $_.Exception.Message -notmatch '^\[stable-read-unstable\]') { throw }
            }
        }
    }
    finally { Exit-AgentLock $capabilityLock.Stream }
    if ([bool]$override.KillSwitchActive) {
        throw '[narrowing-kill-switch-active] Widening is unavailable while the kill switch is active.'
    }
    $current = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $Draft.RoleDescriptor -PersistedNarrowing $override.Settings
    $widened = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $Draft.RoleDescriptor -PersistedNarrowing $override.Settings -GrantCapability $Capability
    return @{ Override = $override; Current = $current; Widened = $widened }
}

function Assert-AgentWideningRequestBinding {
    param([Parameter(Mandatory)][hashtable]$Request, [Parameter(Mandatory)][hashtable]$Draft)
    if ($Draft.Consumed) { throw '[invalid-request] dispatchDraftId has already been consumed.' }
    if (([DateTime]::UtcNow - $Draft.CreatedAt).TotalSeconds -gt $DraftLifetimeSeconds) { throw '[invalid-request] dispatchDraftId has expired.' }
    if ([string]$Request.role -cne $Draft.Role -or [int]$Request.pullRequestId -ne $Draft.PullRequestId -or
        [string]$Request.repositoryKey -cne $Draft.RepositoryIdentity.key) {
        throw '[invalid-request] Widening request binding does not match its draft.'
    }
}

function Resolve-DraftWideningDraft {
    param([hashtable]$Request)
    $draftId = [string](Get-OptionalMember $Request 'dispatchDraftId')
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParseExact($draftId, 'D', [ref]$parsed) -or -not $drafts.ContainsKey($draftId)) {
        throw '[invalid-request] dispatchDraftId is unknown or malformed.'
    }
    return @{ DraftId = $draftId; Draft = $drafts[$draftId] }
}

function Add-AgentConsumedWideningChallenge {
    <#
        Per-draft bounded consumed-challenge ring, max 8 (issue #105 PR4 requirement 4): rejects an
        exact replay of any challenge this draft's widening flow has ever issued and consumed, not
        merely one matching the CURRENT stage name -- a restarted flow (a fresh describe-widening
        call) issues a new challenge at the same stage name, and an old, already-consumed challenge
        for an earlier attempt must still never be replayable.
    #>
    param([Parameter(Mandatory)][hashtable]$Widening, [Parameter(Mandatory)][string]$Challenge)
    if ($Widening.ConsumedChallenges.Contains($Challenge)) { throw '[widening-replay] Challenge has already been consumed.' }
    $Widening.ConsumedChallenges.Add($Challenge)
    while ($Widening.ConsumedChallenges.Count -gt 8) { $Widening.ConsumedChallenges.RemoveAt(0) }
}

function Assert-AgentInteractiveWideningAvailable {
    <#
        issue #105 final headless-broker bypass fix: gates every interactive-widening RPC
        (describe-widening/confirm-widening-preview/confirm-widening-mint/cancel-widening) and,
        separately, dispatch of an already-minted grant (see Invoke-Dispatch). $interactiveWideningAvailable
        is computed exactly once, at broker startup, by Test-AgentDashboardLaunchProvenance -- it
        never changes for the life of this broker process. Placed FIRST in every gated operation,
        before any other request validation, so a direct-pwsh caller is rejected identically
        regardless of whether the rest of their request would otherwise have been valid.
    #>
    if (-not $interactiveWideningAvailable) {
        throw '[widening-interactive-required] Interactive widening requires a broker process launched by the trusted Dashboard.'
    }
}

function Invoke-DescribeWidening {
    param([hashtable]$Request)
    Assert-AgentInteractiveWideningAvailable
    $resolved = Resolve-DraftWideningDraft $Request
    $draftId = $resolved.DraftId; $draft = $resolved.Draft
    Assert-AgentWideningRequestBinding -Request $Request -Draft $draft
    # issue #105 PR4 requirement 4: once a grant is minted, describe-widening must never silently
    # clobber it with a fresh (unminted) widening-preview stage -- that would discard a live grant
    # an operator might still intend to dispatch. Require an explicit cancel-widening first.
    if ($draft.Widening -and $draft.Widening.Stage -ceq 'minted') {
        throw '[widening-invalid] A widening grant is already minted for this draft; dispatch it or cancel-widening before describing a different widening.'
    }
    $capability = [string]$Request.capability
    $harnessRole = Get-AgentHarnessCapabilityDescriptor -Role $draft.Role
    if ($capability -cnotmatch '^[A-Za-z][A-Za-z0-9]*$' -or $capability -cne $harnessRole.delegableDefaultOff) {
        throw "[widening-invalid] capability is not the recognized delegable capability for role '$($draft.Role)'."
    }
    $delegationPolicy = Get-AgentDelegationPolicyOrThrow -ToolkitRoot $toolkitRoot
    if (-not (Test-AgentDelegationAllows -Policy $delegationPolicy -Role $draft.Role -Capability $capability -RepositoryKey $draft.RepositoryIdentity.key)) {
        throw '[delegation-not-allowed] The checked-in delegation policy does not permit this capability for this repository.'
    }
    $candidate = Get-DraftWideningCandidate -Draft $draft -Capability $capability
    $diff = Resolve-AgentWideningEffectiveDiff -Current $candidate.Current -Widened $candidate.Widened -Role $draft.Role -GrantCapability $capability
    $challenge = New-AgentWideningChallenge
    $expiresAtUtc = [DateTime]::UtcNow.AddSeconds($WideningChallengeTtlSeconds)
    $draft.Widening = @{
        Capability = $capability; Stage = 'widening-preview'; Challenge = $challenge; ExpiresAtUtc = $expiresAtUtc
        ConsumedChallenges = [Collections.Generic.List[string]]::new()
        DelegationPolicyPathHash = $delegationPolicy.PathHash; DelegationPolicyContentSha256 = $delegationPolicy.ContentSha256
        GrantNonce = $null; MintedAtUtc = $null; GrantExpiresAtUtc = $null
    }
    $draft.WideningGeneration++
    Write-DispatchProtocolMessage @{
        schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'widening-preview'
        state = 'previewed'; dispatchDraftId = $draftId; capability = $capability; challenge = $challenge
        effectiveDiff = $diff; expiresAtUtc = $expiresAtUtc.ToString('o'); generation = $draft.WideningGeneration
    }
}

function Invoke-ConfirmWideningPreview {
    param([hashtable]$Request)
    Assert-AgentInteractiveWideningAvailable
    $resolved = Resolve-DraftWideningDraft $Request
    $draftId = $resolved.DraftId; $draft = $resolved.Draft
    Assert-AgentWideningRequestBinding -Request $Request -Draft $draft
    $capability = [string]$Request.capability
    $challenge = [string]$Request.challenge
    $w = $draft.Widening
    if (-not $w -or $w.Stage -cne 'widening-preview' -or $w.Capability -cne $capability) {
        throw '[widening-invalid] No widening preview is pending for this capability.'
    }
    if ([DateTime]::UtcNow -ge $w.ExpiresAtUtc) { throw '[widening-expired] Widening preview challenge has expired.' }
    if (-not (Test-AgentWideningChallengeShape -Challenge $challenge) -or $challenge -cne $w.Challenge) {
        throw '[widening-invalid] Challenge does not match the pending widening preview.'
    }
    Add-AgentConsumedWideningChallenge -Widening $w -Challenge $challenge
    $delegationPolicy = Get-AgentDelegationPolicyOrThrow -ToolkitRoot $toolkitRoot
    if ($delegationPolicy.PathHash -cne $w.DelegationPolicyPathHash -or $delegationPolicy.ContentSha256 -cne $w.DelegationPolicyContentSha256 -or
        -not (Test-AgentDelegationAllows -Policy $delegationPolicy -Role $draft.Role -Capability $capability -RepositoryKey $draft.RepositoryIdentity.key)) {
        $draft.Widening = $null; $draft.WideningGeneration++
        throw '[delegation-not-allowed] The checked-in delegation policy changed and no longer permits this capability.'
    }
    $candidate = Get-DraftWideningCandidate -Draft $draft -Capability $capability
    $diff = Resolve-AgentWideningEffectiveDiff -Current $candidate.Current -Widened $candidate.Widened -Role $draft.Role -GrantCapability $capability
    $newChallenge = New-AgentWideningChallenge
    $expiresAtUtc = [DateTime]::UtcNow.AddSeconds($WideningChallengeTtlSeconds)
    $w.Stage = 'widening-summary'; $w.Challenge = $newChallenge; $w.ExpiresAtUtc = $expiresAtUtc
    $draft.WideningGeneration++
    Write-DispatchProtocolMessage @{
        schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'widening-summary'
        state = 'awaiting-final-confirmation'; dispatchDraftId = $draftId; capability = $capability; challenge = $newChallenge
        effectiveDiff = $diff; expiresAtUtc = $expiresAtUtc.ToString('o'); generation = $draft.WideningGeneration
    }
}

function Invoke-ConfirmWideningMint {
    param([hashtable]$Request)
    Assert-AgentInteractiveWideningAvailable
    $resolved = Resolve-DraftWideningDraft $Request
    $draftId = $resolved.DraftId; $draft = $resolved.Draft
    Assert-AgentWideningRequestBinding -Request $Request -Draft $draft
    $capability = [string]$Request.capability
    $challenge = [string]$Request.challenge
    $w = $draft.Widening
    if (-not $w -or $w.Stage -cne 'widening-summary' -or $w.Capability -cne $capability) {
        throw '[widening-invalid] No widening confirmation is pending for this capability.'
    }
    if ([DateTime]::UtcNow -ge $w.ExpiresAtUtc) { throw '[widening-expired] Widening confirmation challenge has expired.' }
    if (-not (Test-AgentWideningChallengeShape -Challenge $challenge) -or $challenge -cne $w.Challenge) {
        throw '[widening-invalid] Challenge does not match the pending widening confirmation.'
    }
    Add-AgentConsumedWideningChallenge -Widening $w -Challenge $challenge
    $delegationPolicy = Get-AgentDelegationPolicyOrThrow -ToolkitRoot $toolkitRoot
    if ($delegationPolicy.PathHash -cne $w.DelegationPolicyPathHash -or $delegationPolicy.ContentSha256 -cne $w.DelegationPolicyContentSha256 -or
        -not (Test-AgentDelegationAllows -Policy $delegationPolicy -Role $draft.Role -Capability $capability -RepositoryKey $draft.RepositoryIdentity.key)) {
        $draft.Widening = $null; $draft.WideningGeneration++
        throw '[delegation-not-allowed] The checked-in delegation policy changed and no longer permits this capability.'
    }
    $candidate = Get-DraftWideningCandidate -Draft $draft -Capability $capability
    $diff = Resolve-AgentWideningEffectiveDiff -Current $candidate.Current -Widened $candidate.Widened -Role $draft.Role -GrantCapability $capability
    if (-not $diff.pairedCapabilityActive) {
        throw "[widening-invalid] $($diff.pairedCapability) must already be active before $capability can be granted."
    }
    $grantNonce = New-AgentNonce
    $grantExpiresAtUtc = $draft.CreatedAt.AddSeconds($DraftLifetimeSeconds)
    $w.Stage = 'minted'; $w.GrantNonce = $grantNonce; $w.MintedAtUtc = [DateTime]::UtcNow; $w.GrantExpiresAtUtc = $grantExpiresAtUtc
    $w.DelegationPolicyPathHash = $delegationPolicy.PathHash; $w.DelegationPolicyContentSha256 = $delegationPolicy.ContentSha256
    # Update the draft's own bound policy/digest to the WIDENED partition -- exactly the same
    # ordered-field shape Invoke-Describe used, so dispatch()'s existing capabilityPolicyDigest
    # binding check keeps working unmodified against this new, wider value.
    $draft.Policy = [ordered]@{
        schemaVersion = 1; repositoryIdentity = $draft.RepositoryIdentity; role = $draft.Role
        capabilities = $candidate.Widened.capabilities; mandatoryDenies = $candidate.Widened.mandatoryDenies
        ceilingCapabilities = $draft.Policy.ceilingCapabilities; ceilingMandatoryDenies = $draft.Policy.ceilingMandatoryDenies
        configSnapshotSha256 = $draft.Policy.configSnapshotSha256
    }
    $draft.PolicyDigest = Get-AgentCanonicalDigest $draft.Policy
    $draft.WideningGeneration++
    Write-DispatchProtocolMessage @{
        schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'widening-minted'
        state = 'minted'; dispatchDraftId = $draftId; capability = $capability
        capabilities = $draft.Policy.capabilities; mandatoryDenies = $draft.Policy.mandatoryDenies
        capabilityPolicyDigest = $draft.PolicyDigest; effectiveDiff = $diff
        grantExpiresAtUtc = (ConvertTo-AgentCanonicalEpochSeconds $grantExpiresAtUtc); generation = $draft.WideningGeneration
    }
}

function Invoke-CancelWidening {
    param([hashtable]$Request)
    Assert-AgentInteractiveWideningAvailable
    $resolved = Resolve-DraftWideningDraft $Request
    $draftId = $resolved.DraftId; $draft = $resolved.Draft
    Assert-AgentWideningRequestBinding -Request $Request -Draft $draft
    # issue #105 PR4 requirement 12: generation must be an exact, present, safe integer -- never
    # defaulted. A request that omits it (Get-OptionalMember returns $null, and PowerShell's own
    # [int64] cast on $null silently coerces to 0) must never be treated as if it explicitly named
    # generation 0; that would let an omitted-generation request slip through whenever a draft's
    # WideningGeneration happens to still be 0.
    $requestedGeneration = ConvertTo-AgentSafeIntegralNumber (Get-OptionalMember $Request 'generation')
    if ($null -eq $requestedGeneration) {
        throw '[invalid-request] generation must be an exact, present, safe integer.'
    }
    if ($requestedGeneration -ne [int64]$draft.WideningGeneration) {
        throw '[widening-stale] Widening state has moved on; re-open the widening panel and try again.'
    }
    $harnessRole = Get-AgentHarnessCapabilityDescriptor -Role $draft.Role
    # Cancel must stay usable even when the delegation policy cannot be loaded (issue #105 PR4
    # requirement 3/9) -- an operator must always be able to cancel a stuck/unwanted widening
    # attempt; only the delegableAvailable hint in the response degrades to empty.
    $delegationPolicyForCancel = Get-AgentDelegationPolicyOrNull -ToolkitRoot $toolkitRoot
    $delegableAvailable = @()
    if ($delegationPolicyForCancel -and
        (Test-AgentDelegationAllows -Policy $delegationPolicyForCancel -Role $draft.Role -Capability $harnessRole.delegableDefaultOff -RepositoryKey $draft.RepositoryIdentity.key)) {
        $delegableAvailable = @($harnessRole.delegableDefaultOff)
    }
    $capabilityLock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $draft.RoleDescriptor.repositoryRoot -TimeoutMilliseconds 2000
    if (-not $capabilityLock.Acquired) { throw "[already-running] $($capabilityLock.Reason)" }
    try {
        $override = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $draft.RepositoryIdentity `
            -RepositoryRoot $draft.RoleDescriptor.repositoryRoot -PullRequestId $draft.PullRequestId -CurrentSourceCommit $draft.PrSnapshot.sourceCommit
    }
    finally { Exit-AgentLock $capabilityLock.Stream }
    $unwidened = Resolve-AgentCapabilityPolicyPartition -RoleDescriptor $draft.RoleDescriptor -PersistedNarrowing $override.Settings
    $draft.Widening = $null
    $draft.Policy = [ordered]@{
        schemaVersion = 1; repositoryIdentity = $draft.RepositoryIdentity; role = $draft.Role
        capabilities = $unwidened.capabilities; mandatoryDenies = $unwidened.mandatoryDenies
        ceilingCapabilities = $draft.Policy.ceilingCapabilities; ceilingMandatoryDenies = $draft.Policy.ceilingMandatoryDenies
        configSnapshotSha256 = $draft.Policy.configSnapshotSha256
    }
    $draft.PolicyDigest = Get-AgentCanonicalDigest $draft.Policy
    $draft.WideningGeneration++
    Write-DispatchProtocolMessage @{
        schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'widening-cancelled'
        state = 'cancelled'; dispatchDraftId = $draftId
        capabilities = $draft.Policy.capabilities; mandatoryDenies = $draft.Policy.mandatoryDenies
        capabilityPolicyDigest = $draft.PolicyDigest; delegableAvailable = $delegableAvailable
        generation = $draft.WideningGeneration
    }
}

function Publish-ProtectedPrompt {
    param([hashtable]$Draft, [string]$Text)
    $validated = Test-AgentOperatorPrompt -Prompt $Text
    $runtimeRoot = $Draft.Snapshot.RuntimeRoot
    $promptPath = Join-Path $runtimeRoot 'operator-context.txt'
    $tempPath = Join-Path $runtimeRoot ("prompt-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    $bytes = $utf8.GetBytes($validated.Text)
    $guardian = $null
    $guardianCompletion = $null
    try {
        if (-not $IsWindows) {
            $token = -join ((1..32) | ForEach-Object { '{0:x}' -f [Security.Cryptography.RandomNumberGenerator]::GetInt32(0, 16) })
            $guardianDiagnostics = Join-Path $runtimeRoot 'guardian-diagnostics'
            $guardian = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                (Join-Path $PSScriptRoot 'Invoke-DevPilotPromptGuardian.ps1'),
                '-RuntimeRoot', $runtimeRoot, '-BrokerProcessId', [string]$PID,
                '-BrokerStartIdentity',
                (Get-AgentProcessStartIdentity -Process ([Diagnostics.Process]::GetCurrentProcess())),
                '-Token', $token
            ) -StandardOutputPath "$guardianDiagnostics.stdout" -StandardErrorPath "$guardianDiagnostics.stderr"
            $readyPath = Join-Path $runtimeRoot "guardian-$token.ready"
            $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $readyPath)) {
                if ($guardian.Process.HasExited -or [DateTime]::UtcNow -ge $readyDeadline) {
                    if (-not $guardian.Process.HasExited) {
                        Stop-ProcessTree $guardian.Process
                        [void]$guardian.Process.WaitForExit(5000)
                    }
                    $guardianCompletion = Complete-AgentRedirectedProcess $guardian
                    throw "[launch-failed] Prompt guardian did not become ready: $($guardianCompletion.SafeErrorTail)"
                }
                Start-Sleep -Milliseconds 25
            }
        }
        $options = [IO.FileOptions]::WriteThrough
        $share = [IO.FileShare]::None
        if ($IsWindows) {
            $options = $options -bor [IO.FileOptions]::DeleteOnClose
            $share = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
        }
        $stream = [IO.FileStream]::new($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            $share, 4096, $options)
        try {
            if (-not $IsWindows) { [IO.File]::SetUnixFileMode($tempPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
            if (-not $IsWindows) {
                $registration = Join-Path $runtimeRoot "guardian-$token.json"
                [IO.File]::WriteAllText($registration, (ConvertTo-AgentCanonicalJson @{
                            token = $token
                            paths = @((Split-Path -Leaf $tempPath), (Split-Path -Leaf $promptPath))
                        }), [Text.UTF8Encoding]::new($false))
                [IO.File]::SetUnixFileMode($registration, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
                $registeredPath = Join-Path $runtimeRoot "guardian-$token.registered"
                $registeredDeadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Test-Path -LiteralPath $registeredPath)) {
                    if ($guardian.Process.HasExited -or [DateTime]::UtcNow -ge $registeredDeadline) {
                        if (-not $guardian.Process.HasExited) {
                            Stop-ProcessTree $guardian.Process
                            [void]$guardian.Process.WaitForExit(5000)
                        }
                        $guardianCompletion = Complete-AgentRedirectedProcess $guardian
                        throw "[launch-failed] Prompt guardian did not register the protected identity: $($guardianCompletion.SafeErrorTail)"
                    }
                    Start-Sleep -Milliseconds 25
                }
            }
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            [IO.File]::Move($tempPath, $promptPath)
            if ($IsWindows) {
                $Draft['PromptGuard'] = $stream
                $stream = $null
            }
        }
        finally { if ($stream) { $stream.Dispose() } }
        if ($guardian) {
            $Draft['Guardian'] = $guardian
            $Draft['GuardianToken'] = $token
        }
        return $promptPath
    }
    catch {
        Remove-Item -LiteralPath $tempPath, $promptPath -Force -ErrorAction SilentlyContinue
        if ($guardian) {
            $guardian.Process.Refresh()
            if (-not $guardian.Process.HasExited) {
                Stop-ProcessTree $guardian.Process
                [void]$guardian.Process.WaitForExit(5000)
            }
            if (-not $guardianCompletion) {
                $guardianCompletion = Complete-AgentRedirectedProcess $guardian
            }
        }
        throw
    }
    finally { if ($bytes.Length) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Invoke-Dispatch {
    param([hashtable]$Request)
    $draftId = [string](Get-OptionalMember $Request 'dispatchDraftId')
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParseExact($draftId, 'D', [ref]$parsed) -or -not $drafts.ContainsKey($draftId)) {
        throw '[invalid-request] dispatchDraftId is unknown or malformed.'
    }
    $draft = $drafts[$draftId]
    if ($draft.Consumed) { throw '[invalid-request] dispatchDraftId has already been consumed.' }
    $draft.Consumed = $true
    if (([DateTime]::UtcNow - $draft.CreatedAt).TotalSeconds -gt $DraftLifetimeSeconds) {
        throw '[invalid-request] dispatchDraftId has expired.'
    }
    foreach ($binding in @(
            @('role', $draft.Role), @('pullRequestId', $draft.PullRequestId),
            @('repositoryKey', $draft.RepositoryIdentity.key),
            @('capabilityPolicyDigest', $draft.PolicyDigest), @('prStateFingerprint', $draft.PrFingerprint))) {
        if ([string]$Request[$binding[0]] -cne [string]$binding[1]) { throw '[invalid-request] Dispatch binding does not match its draft.' }
    }
    $snapshotBytes = [IO.File]::ReadAllBytes($draft.Snapshot.SnapshotPath)
    $snapshotHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($snapshotBytes)).ToLowerInvariant()
    if ($snapshotBytes.Length -ne $draft.Snapshot.SnapshotLength -or $snapshotHash -cne $draft.Snapshot.SnapshotSha256) {
        throw '[policy-changed] Config snapshot changed after describe.'
    }
    $snapshotRoleDescriptor = @{} + $draft.RoleDescriptor
    $snapshotRoleDescriptor.configFile = $draft.Snapshot.SnapshotPath
    $snapshotRoleDescriptor.configRoot = Split-Path $draft.Snapshot.SnapshotPath -Parent
    $provider = Open-BrokerProvider $snapshotRoleDescriptor
    try {
        $identity = Resolve-AgentProviderRepositoryIdentity $provider.Context
        if ([string]$identity.key -cne [string]$draft.RepositoryIdentity.key) { throw '[repository-mismatch] Repository identity changed.' }
        $livePr = ConvertTo-BrokerPrSnapshot (Get-BrokerPullRequest $provider $draft.PullRequestId) $draft.PullRequestId
        if ([string]$livePr.sourceCommit -cne [string]$draft.PrSnapshot.sourceCommit -or
            [string]$livePr.sourceRef -cne [string]$draft.PrSnapshot.sourceRef) { throw '[source-changed] Pull request source changed.' }
        $liveFingerprint = Get-AgentCanonicalDigest ([ordered]@{
                schemaVersion = 1; repositoryKey = $identity.key; pullRequestId = $draft.PullRequestId
                sourceCommit = $livePr.sourceCommit; sourceRef = $livePr.sourceRef; targetRef = $livePr.targetRef
                active = $livePr.active; draft = $livePr.draft; author = $livePr.author
            })
        if ($liveFingerprint -cne $draft.PrFingerprint) { throw '[pr-state-changed] Pull request state changed.' }
    }
    finally { if ($provider.Session) { Close-AgentMcpSession $provider.Session } }

    # issue #105 PR4: dispatch-time revalidation of a minted widening grant. The mint step (§
    # Invoke-ConfirmWideningMint) is in-memory only -- this is the FIRST point a grant can be acted
    # on, so it is re-verified in full, fresh, right before the sealed artifact/child are created.
    $grantCapability = if ($draft.Widening -and $draft.Widening.Stage -ceq 'minted') { $draft.Widening.Capability } else { $null }
    if ($grantCapability) {
        # issue #105 final headless-broker bypass fix: $interactiveWideningAvailable is invariant
        # for the life of this broker process, so a minted grant can only ever exist here if it
        # was already true throughout describe-widening/confirm-widening-preview/-mint above --
        # this is defense-in-depth, never reachable through the normal request sequence, but
        # dispatch of an already-minted grant must still independently require it rather than
        # trust that the earlier gates were never bypassed by a future code change.
        if (-not $interactiveWideningAvailable) {
            $draft.Widening = $null; $draft.WideningGeneration++
            throw '[widening-interactive-required] Interactive widening requires a broker process launched by the trusted Dashboard.'
        }
        if ([DateTime]::UtcNow -ge $draft.Widening.GrantExpiresAtUtc) { throw '[grant-invalidated] Widening grant has expired.' }
        # issue #105 PR4 CRITICAL-1: recheck the kill switch at dispatch preflight too (not only at
        # child startup) -- an operator who flips it on any time after mint, even before the child
        # is ever launched, must have the grant invalidated and dispatch rejected, not silently
        # honored just because the mint-time check already passed.
        $killSwitchLock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $draft.RoleDescriptor.repositoryRoot -TimeoutMilliseconds 2000
        if (-not $killSwitchLock.Acquired) { throw "[already-running] $($killSwitchLock.Reason)" }
        try {
            $dispatchKillSwitchState = Get-AgentCapabilityOverrideKillSwitchState -RepositoryRoot $draft.RoleDescriptor.repositoryRoot
        }
        finally { Exit-AgentLock $killSwitchLock.Stream }
        if ($dispatchKillSwitchState.Active) {
            $draft.Widening = $null; $draft.WideningGeneration++
            throw '[grant-invalidated] Capability-override kill switch is active; the widening grant has been invalidated.'
        }
        $liveDelegationPolicy = Get-AgentDelegationPolicyOrThrow -ToolkitRoot $toolkitRoot
        if ($liveDelegationPolicy.PathHash -cne $draft.Widening.DelegationPolicyPathHash -or
            $liveDelegationPolicy.ContentSha256 -cne $draft.Widening.DelegationPolicyContentSha256 -or
            -not (Test-AgentDelegationAllows -Policy $liveDelegationPolicy -Role $draft.Role -Capability $grantCapability -RepositoryKey $identity.key)) {
            throw '[grant-invalidated] Delegation policy changed since the grant was minted.'
        }
        # issue #105 PR4 requirement 10: reassert the SAME two dispatch-blocking conditions
        # mint-time already checked, live, right before launch -- narrowing/override state can
        # change in the window between mint and dispatch. Shares Get-DraftWideningCandidate's
        # single fresh, lock-held resolution so current/widened can never disagree with what
        # describe-widening/confirm-widening-mint themselves would compute right now.
        $dispatchCandidate = Get-DraftWideningCandidate -Draft $draft -Capability $grantCapability
        $dispatchDiff = Resolve-AgentWideningEffectiveDiff -Current $dispatchCandidate.Current -Widened $dispatchCandidate.Widened -Role $draft.Role -GrantCapability $grantCapability
        if (-not $dispatchDiff.pairedCapabilityActive) {
            $draft.Widening = $null; $draft.WideningGeneration++
            throw "[grant-invalidated] $($dispatchDiff.pairedCapability) is no longer active; the widening grant has been invalidated."
        }
        if ($draft.Role -eq 'review-handler' -and $grantCapability -ceq 'EnableAutoComplete') {
            $handlerDurableContext = Get-AgentDurableStateContext -DurableStateRoot $durableRoot -RepositoryIdentity $identity -Role review-handler
            $handledStateSnapshot = Get-AgentDurableRecordsSnapshot -Context $handlerDurableContext
            if (Test-AgentAutoCompleteGrantWouldBeNoOp -HandledState $handledStateSnapshot -PullRequestId $draft.PullRequestId) {
                throw '[grant-noop] Forced redispatch already has prior delivery state; the auto-complete grant would be a no-op.'
            }
        }
    }

    $dispatchId = [Guid]::NewGuid().ToString('D')
    $promptPath = Publish-ProtectedPrompt $draft ([string]$Request.operatorPrompt)
    $pipeName = New-AgentPipeName
    $pipe = [IO.Pipes.NamedPipeServerStream]::new($pipeName, [IO.Pipes.PipeDirection]::InOut, 1,
        [IO.Pipes.PipeTransmissionMode]::Byte,
        [IO.Pipes.PipeOptions]::Asynchronous -bor [IO.Pipes.PipeOptions]::CurrentUserOnly)
    $eventDir = Join-Path (Join-Path (Join-Path $stateRoot 'logs') 'events') $draft.Role
    New-Item -ItemType Directory -Path $eventDir -Force | Out-Null
    $manifestPath = Join-Path $draft.Snapshot.RuntimeRoot 'dispatch-manifest.json'
    $cancellationNonce = New-AgentNonce
    $draft['CancellationNonce'] = $cancellationNonce
    # issue #105 PR4 CRITICAL-2 hardening: mint the ephemeral, broker-only attestation secret and
    # anonymous-pipe channel for THIS dispatch attempt. Computed from the broker's own in-memory
    # draft/grant state, never from anything the manifest will later echo back -- the child
    # independently re-derives the identical fields from its own live state
    # (Enter-AgentManualDispatchStartup) and the two digests must match exactly.
    $attestationSecret = New-AgentBrokerAttestationSecret
    $attestationPipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::Out, [IO.HandleInheritability]::Inheritable)
    $attestationWorktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $draft.RoleDescriptor.repositoryRoot
    $brokerAttestationDigest = Get-AgentAttestationDigest -DispatchId $dispatchId -Role $draft.Role `
        -RepositoryKey $identity.key -WorktreeId $attestationWorktreeId -PullRequestId $draft.PullRequestId `
        -SourceCommit $draft.PrSnapshot.sourceCommit -CapabilityPolicyDigest $draft.PolicyDigest `
        -GrantCapability $grantCapability `
        -GrantNonce $(if ($grantCapability) { $draft.Widening.GrantNonce } else { $null }) `
        -GrantExpiresAtUtc $(if ($grantCapability) { ConvertTo-AgentCanonicalEpochSeconds $draft.Widening.GrantExpiresAtUtc } else { $null })
    if ($grantCapability) {
        # issue #105 PR4: seal the grant SELECTION into the child's own runtime root -- a
        # selection, never an authority (ANT-2); the child independently re-derives and re-verifies
        # every field below from its own live state before ever acting on it (§ Enter-
        # AgentManualDispatchStartup).
        [void](New-AgentWideningGrantArtifact -RuntimeRoot $draft.Snapshot.RuntimeRoot -DraftId $draftId -DispatchId $dispatchId `
                -Capability $grantCapability -Role $draft.Role -RepositoryKey $identity.key `
                -WorktreeId (Get-AgentWorktreeIdentity -RepositoryRoot $draft.RoleDescriptor.repositoryRoot) `
                -PullRequestId $draft.PullRequestId -SourceCommit $draft.PrSnapshot.sourceCommit `
                -PolicyPathHash $draft.Widening.DelegationPolicyPathHash -PolicyContentSha256 $draft.Widening.DelegationPolicyContentSha256 `
                -GrantNonce $draft.Widening.GrantNonce -ExpiresAtUtc (ConvertTo-AgentCanonicalEpochSeconds $draft.Widening.GrantExpiresAtUtc))
    }
    $manifest = [ordered]@{
        schemaVersion = 1; dispatchId = $dispatchId; role = $draft.Role
        repositoryKey = $identity.key; pullRequestId = $draft.PullRequestId
        capabilityPolicyDigest = $draft.PolicyDigest; prStateFingerprint = $draft.PrFingerprint
        policy = $draft.Policy; runtimeRoot = $draft.Snapshot.RuntimeRoot
        dispatchDraftId = $draftId; grantCapability = $grantCapability
        operatorPromptPath = $promptPath; startupPipe = $pipeName; eventLogDirectory = $eventDir
        prStateFingerprintSourceCommit = $draft.PrSnapshot.sourceCommit
        cancellationNonce = $cancellationNonce
        cancellationRequestPath = (Join-Path $draft.Snapshot.RuntimeRoot 'cancel.requested.json')
        cancellationAcknowledgementPath = (Join-Path $draft.Snapshot.RuntimeRoot 'cancel.acknowledged.json')
        # issue #105 PR5 (broker-issuer anchor): every value below is derived from THIS broker's
        # own live process/trusted descriptor -- computed once at script startup, never from
        # $Request/$draft -- so Assert-AgentBrokerProcessAnchor (child side) can bind this exact
        # dispatch to a real, verified broker ancestor instead of trusting the manifest alone.
        brokerProcessId = $PID; brokerProcessStartIdentity = $brokerProcessStartIdentity
        brokerDescriptorPath = $descriptorFullPath; brokerDescriptorDigest = $descriptorDigest
        brokerScriptSha256 = $brokerScriptSha256
    }
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-AgentCanonicalJson $manifest), [Text.UTF8Encoding]::new($false))
    # issue #105 PR4 requirement 6: -ForceAnalysis is omitted ONLY for a reviewer's valid
    # vote-grant dispatch -- forcing an already-reviewed PR's analysis while a vote is granted risks
    # a duplicate/stale-analysis vote. Every other combination (unwidened reviewer, any
    # review-handler dispatch including an auto-complete grant) keeps -ForceAnalysis exactly as
    # before, so Start-ReviewHandlerAgent.ps1's own $forcedRedispatchReadOnly safety valve is
    # unaffected -- see the grant-noop preflight above, which is what actually protects that path.
    $includeForceAnalysis = -not ($draft.Role -eq 'reviewer' -and $grantCapability -ceq 'EnableApprovalVote')
    $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', [string]$expectedRoleScripts[$draft.Role],
        '-ConfigFile', $draft.Snapshot.SnapshotPath, '-RepoPath', [string]$draft.RoleDescriptor.repositoryRoot,
        '-StateDir', (Join-Path $draft.Snapshot.RuntimeRoot 'agent'),
        '-EventLogDirectory', $eventDir,
        '-DurableStateRoot', $durableRoot, '-LeaseRoot', $leaseRoot, '-OperatorAlias', [string]$descriptor.operatorAlias,
        '-PullRequestId', [string]$draft.PullRequestId, '-Once')
    if ($includeForceAnalysis) { $args += '-ForceAnalysis' }
    $args += @('-OutputMode', 'Json', '-ManualDispatchManifest', $manifestPath)
    foreach ($capability in @($draft.Policy.capabilities)) {
        $args += "-$capability"
    }
    $diagnostics = Join-Path $draft.Snapshot.Root 'diagnostics'
    # issue #105 PR5 requirement 7: everything from child creation through the pipe write/flush is
    # its own try/catch so a failure ANYWHERE in this sequence (e.g. the child executable fails to
    # start, or the pipe write fails because the child never even reached the point of inheriting
    # the handle) still disposes attestationPipe and clears attestationSecret -- previously a
    # failure here left both leaked until process exit (known limitation, now closed): neither was
    # covered by the try/finally that only starts below, once the child is already known to exist.
    $child = $null
    try {
        $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList $args `
            -StandardOutputPath (Join-Path $diagnostics 'stdout.log') -StandardErrorPath (Join-Path $diagnostics 'stderr.log') `
            -WorkingDirectory $toolkitRoot `
            -AdditionalEnvironmentVariables @{ DEVPILOT_BROKER_ATTESTATION_HANDLE = $attestationPipe.GetClientHandleAsString() }
        # The broker's own copy of the CLIENT-side handle must be released immediately once it has
        # been duplicated into the child at process-creation time -- and only a process the OS
        # itself handed this exact inherited handle to can ever open it; a forged manifest plus a
        # same-named fake pipe can never obtain it. The secret is written once, right away, so the
        # child can read it as soon as it reaches Receive-AgentBrokerAttestationSecret.
        $attestationPipe.DisposeLocalCopyOfClientHandle()
        $attestationPipe.Write($attestationSecret, 0, $attestationSecret.Length)
        $attestationPipe.Flush()
    }
    catch {
        $attestationPipe.Dispose()
        [Array]::Clear($attestationSecret, 0, $attestationSecret.Length)
        if ($child) { Stop-ProcessTree $child.Process; [void]$child.Process.WaitForExit(5000); [void](Complete-AgentRedirectedProcess $child) }
        if ($grantCapability) { Remove-AgentWideningGrantArtifact -RuntimeRoot $draft.Snapshot.RuntimeRoot }
        Remove-Item -LiteralPath $promptPath -Force -ErrorAction SilentlyContinue
        throw
    }
    $containment = $null
    $completionResult = $null
    try {
        $containment = New-AgentProcessContainment -Process $child.Process
        if (-not $IsWindows -and $draft.ContainsKey('GuardianToken') -and $draft['GuardianToken']) {
            $registration = Join-Path $draft.Snapshot.RuntimeRoot "guardian-$($draft['GuardianToken']).json"
            $guardianRecord = Get-Content -LiteralPath $registration -Raw -Encoding UTF8 |
                ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $guardianRecord['childProcessId'] = $child.Process.Id
            $guardianRecord['childLeaderStartIdentity'] = $containment.LeaderStartIdentity
            $registrationTemp = "$registration.new"
            [IO.File]::WriteAllText($registrationTemp, (ConvertTo-AgentCanonicalJson $guardianRecord), [Text.UTF8Encoding]::new($false))
            [IO.File]::SetUnixFileMode($registrationTemp, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
            [IO.File]::Move($registrationTemp, $registration, $true)
        }
        $connect = $pipe.WaitForConnectionAsync()
        $connectDeadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not $connect.IsCompleted) {
            $child.Process.Refresh()
            if ($child.Process.HasExited) {
                $completionResult = Complete-AgentRedirectedProcess $child
                throw "[launch-failed] Child exited before readiness (exit $($completionResult.ExitCode)): $($completionResult.SafeErrorTail)"
            }
            if ([DateTime]::UtcNow -ge $connectDeadline) {
                throw '[launch-failed] Child readiness timed out.'
            }
            Start-Sleep -Milliseconds 25
        }
        $connect.GetAwaiter().GetResult()
        $reader = [IO.StreamReader]::new($pipe, $utf8, $false, 1024, $true)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.AutoFlush = $true
        $readyTask = $reader.ReadLineAsync()
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not $readyTask.IsCompleted) {
            $child.Process.Refresh()
            if ($child.Process.HasExited) {
                $completionResult = Complete-AgentRedirectedProcess $child
                throw "[launch-failed] Child exited during readiness (exit $($completionResult.ExitCode)): $($completionResult.SafeErrorTail)"
            }
            if ([DateTime]::UtcNow -ge $readyDeadline) {
                throw '[launch-failed] Child readiness timed out.'
            }
            Start-Sleep -Milliseconds 25
        }
        $ready = $readyTask.Result | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ([string]$ready.operation -ceq 'rejected') {
            if ([string]$ready.dispatchId -cne $dispatchId) {
                throw '[launch-failed] Child rejection identity mismatch.'
            }
            $startupCode = [string](Get-OptionalMember $ready 'code')
            if ($startupCode -notin @('already-running', 'delivery-pending', 'grant-invalidated', 'grant-noop')) {
                $startupCode = 'launch-failed'
            }
            $startupDetail = [string](Get-OptionalMember $ready 'detail')
            if ($startupCode -eq 'already-running' -and
                $startupDetail -notin @('lease-contended', 'state-contended')) {
                $startupDetail = 'authority-contended'
            }
            throw "[$startupCode] $startupDetail"
        }
        if ([string]$ready.operation -cne 'ready' -or [string]$ready.dispatchId -cne $dispatchId -or
            [int]$ready.processId -ne $child.Process.Id) { throw '[launch-failed] Child readiness identity mismatch.' }
        $readyCapabilities = @(Get-OptionalMember $ready 'boundCapabilities')
        $readyDenies = @(Get-OptionalMember $ready 'enforcedDenies')
        if ((ConvertTo-AgentCanonicalJson @($readyCapabilities | Sort-Object -Unique)) -cne
                (ConvertTo-AgentCanonicalJson @($draft.Policy.capabilities | Sort-Object -Unique)) -or
            (ConvertTo-AgentCanonicalJson @($readyDenies | Sort-Object -Unique)) -cne
                (ConvertTo-AgentCanonicalJson @($draft.Policy.mandatoryDenies | Sort-Object -Unique))) {
            throw '[launch-failed] Child capability attestation does not match the dispatch policy.'
        }
        # issue #105 PR4 CRITICAL-2 hardening: the broker-origin attestation is the one check that
        # a caller-authored manifest/artifact plus a same-named fake pipe cannot satisfy. The child
        # can only have produced a valid attestationProof if it actually read SecretBytes -- which
        # never left this broker process except through the anonymous-pipe handle inherited by the
        # exact child this broker itself spawned above. attestationDigest is recomputed here from
        # the broker's OWN in-memory draft/grant state (never trusted from the child's message) and
        # must match exactly before the proof is even considered.
        $readyAttestationNonce = [string](Get-OptionalMember $ready 'attestationNonce')
        $readyAttestationDigest = [string](Get-OptionalMember $ready 'attestationDigest')
        $readyAttestationProof = [string](Get-OptionalMember $ready 'attestationProof')
        $expectedAttestationProof = Get-AgentAttestationProof -SecretBytes $attestationSecret -Nonce $readyAttestationNonce -Digest $brokerAttestationDigest
        if ($readyAttestationDigest -cne $brokerAttestationDigest -or $readyAttestationProof -cne $expectedAttestationProof) {
            throw '[broker-attestation-failed] Child broker-origin attestation could not be verified.'
        }
        $eventPath = [IO.Path]::GetFullPath([string]$ready.eventLogPath)
        if (-not (Test-AgentPathWithin -Path $eventPath -Root $eventDir) -or
            [IO.Path]::GetExtension($eventPath) -cne '.jsonl') {
            throw '[launch-failed] Child event path escaped the canonical log directory.'
        }
        if ($draft.ContainsKey('PromptGuard') -and $draft['PromptGuard']) {
            $draft['PromptGuard'].Dispose()
            $draft['PromptGuard'] = $null
        }
        if (Test-Path -LiteralPath $promptPath) { throw '[launch-failed] Child did not remove the operator prompt.' }
        $writer.WriteLine((ConvertTo-AgentCanonicalJson ([ordered]@{
                    schemaVersion = 1; operation = 'proceed'; dispatchId = $dispatchId
                })))
        if ($grantCapability) {
            # issue #105 PR4: the handshake concluded successfully -- the sealed grant-selection
            # artifact has done its job (the child already independently re-verified it under its
            # own capability-override lock before sending ready) and must not linger for the
            # remaining lifetime of the running child.
            Remove-AgentWideningGrantArtifact -RuntimeRoot $draft.Snapshot.RuntimeRoot
        }
        $attestationPipe.Dispose()
        [Array]::Clear($attestationSecret, 0, $attestationSecret.Length)
        $children[$dispatchId] = @{
            Child = $child; RequestId = [string]$Request.requestId; Pipe = $pipe
            Draft = $draft; DraftId = $draftId; Containment = $containment
        }
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'accepted'
            dispatchId = $dispatchId; repositoryIdentity = $identity; pullRequestId = $draft.PullRequestId
            role = $draft.Role; capabilityPolicyDigest = $draft.PolicyDigest
            prStateFingerprint = $draft.PrFingerprint; childProcessId = $child.Process.Id; eventLogPath = $eventPath
        }
    }
    catch {
        if ($containment) { Stop-AgentProcessContainment $containment $child.Process }
        else { Stop-ProcessTree $child.Process; [void]$child.Process.WaitForExit(5000) }
        if (-not $completionResult) { [void](Complete-AgentRedirectedProcess $child) }
        Close-AgentProcessContainment $containment
        $pipe.Dispose()
        $attestationPipe.Dispose()
        [Array]::Clear($attestationSecret, 0, $attestationSecret.Length)
        # issue #105 PR4 requirement 7: a grant artifact already sealed for THIS dispatch attempt
        # must never survive a failed/abandoned handshake -- Remove-ExpiredDrafts provides an
        # unconditional backstop, but cleaning it up immediately here (write/start/ready/proceed all
        # failed the same way) avoids leaving a sealed selection on disk for even one extra poll
        # interval.
        if ($grantCapability) { Remove-AgentWideningGrantArtifact -RuntimeRoot $draft.Snapshot.RuntimeRoot }
        Remove-Item -LiteralPath $promptPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Complete-ExitedChildren {
    foreach ($id in @($children.Keys)) {
        $entry = $children[$id]
        $entry.Child.Process.Refresh()
        if (-not $entry.Child.Process.HasExited) { continue }
        if (-not (Test-AgentProcessContainmentExited -Containment $entry.Containment -Process $entry.Child.Process)) {
            continue
        }
        $result = Complete-AgentRedirectedProcess $entry.Child
        $entry.Pipe.Dispose()
        Close-AgentProcessContainment $entry.Containment
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = $entry.RequestId; operation = 'completed'
            dispatchId = $id; exitCode = $result.ExitCode
        }
        $children.Remove($id)
        Remove-DraftResidue $entry.Draft
        $drafts.Remove([string]$entry.DraftId)
    }
}

function Stop-BrokerChild {
    param([string]$DispatchId, [string]$RequestId, [switch]$BrokerShutdown)
    if (-not $children.ContainsKey($DispatchId)) { Write-Rejection $RequestId 'not-owner'; return }
    $entry = $children[$DispatchId]
    $cancelPath = Join-Path ([string]$entry.Draft.Snapshot.RuntimeRoot) 'cancel.requested.json'
    $cancelAckPath = Join-Path ([string]$entry.Draft.Snapshot.RuntimeRoot) 'cancel.acknowledged.json'
    $cancelRequest = [ordered]@{
        schemaVersion = 1; operation = 'cancel'; dispatchId = $DispatchId
        nonce = [string]$entry.Draft.CancellationNonce
    }
    [IO.File]::WriteAllText($cancelPath, (ConvertTo-AgentCanonicalJson $cancelRequest), [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($cancelPath,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    [void]$entry.Child.Process.WaitForExit(5000)
    $treeExited = Test-AgentProcessContainmentExited -Containment $entry.Containment -Process $entry.Child.Process
    $cooperative = $false
    $acknowledgementPresent = Test-Path -LiteralPath $cancelAckPath -PathType Leaf
    if ($treeExited -and $acknowledgementPresent) {
        try {
            [void](Assert-AgentTrustedFile -Path $cancelAckPath `
                -AllowedRoot ([string]$entry.Draft.Snapshot.RuntimeRoot) -Private)
            $ack = Get-Content -LiteralPath $cancelAckPath -Raw -Encoding UTF8 |
                ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
            $cooperative = (
                [int]$ack.schemaVersion -eq 1 -and
                [string]$ack.operation -ceq 'cancel-acknowledged' -and
                [string]$ack.dispatchId -ceq $DispatchId -and
                [string]$ack.nonce -ceq [string]$entry.Draft.CancellationNonce -and
                [int]$ack.processId -eq $entry.Child.Process.Id)
        }
        catch [Management.Automation.RuntimeException] {
            Write-Warning "Cancellation acknowledgement was rejected; forcing containment: $($_.Exception.Message)"
        }
        catch [IO.IOException] {
            Write-Warning "Cancellation acknowledgement could not be read; forcing containment: $($_.Exception.Message)"
        }
        catch [UnauthorizedAccessException] {
            Write-Warning "Cancellation acknowledgement access was denied; forcing containment: $($_.Exception.Message)"
        }
    }
    $graceOutcome = Get-AgentCancellationOutcome `
        -AcknowledgementPresent $acknowledgementPresent `
        -AuthenticatedAcknowledgement $cooperative `
        -TreeExitedDuringGrace $treeExited `
        -ForcedContainmentSucceeded $false
    if ($graceOutcome.Result -eq 'completed') {
        $natural = Complete-AgentRedirectedProcess $entry.Child
        Close-AgentProcessContainment $entry.Containment
        $entry.Pipe.Dispose()
        $children.Remove($DispatchId)
        Remove-DraftResidue $entry.Draft
        $drafts.Remove([string]$entry.DraftId)
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = $RequestId; operation = 'completed'
            dispatchId = $DispatchId; exitCode = $natural.ExitCode
            handleReleaseObserved = $true
        }
        return
    }
    $terminated = $false
    if ($graceOutcome.Result -ne 'cancelled-cooperative') {
        $terminated = Stop-AgentProcessContainment $entry.Containment $entry.Child.Process
        $treeExited = [bool]$terminated
    }
    $outcome = Get-AgentCancellationOutcome `
        -AcknowledgementPresent $acknowledgementPresent `
        -AuthenticatedAcknowledgement ($graceOutcome.Result -eq 'cancelled-cooperative') `
        -TreeExitedDuringGrace ($graceOutcome.Result -eq 'cancelled-cooperative') `
        -ForcedContainmentSucceeded ($graceOutcome.Result -ne 'cancelled-cooperative' -and $terminated)
    if ($outcome.Result -eq 'termination-failed') {
        Write-Rejection $RequestId 'termination-failed' 'Contained process tree did not exit within the bounded termination period.'
        return
    }
    [void](Complete-AgentRedirectedProcess $entry.Child)
    Close-AgentProcessContainment $entry.Containment
    $entry.Pipe.Dispose()
    $children.Remove($DispatchId)
    Remove-DraftResidue $entry.Draft
    $drafts.Remove([string]$entry.DraftId)
    Write-DispatchProtocolMessage @{
        schemaVersion = 1
        requestId = $(if ($BrokerShutdown) { $entry.RequestId } else { $RequestId })
        operation = $outcome.Operation
        dispatchId = $DispatchId
        result = $outcome.Result
        handleReleaseObserved = $outcome.HandleReleaseObserved
    }
}

try {
    $readTask = [Console]::In.ReadLineAsync()
    while ($accepting) {
        Complete-ExitedChildren
        Remove-ExpiredDrafts
        Remove-ExpiredNarrowingPreviews
        if ($null -eq (Get-Process -Id ([int]$descriptor.ownerProcessId) -ErrorAction SilentlyContinue)) { break }
        if (-not $readTask.Wait(100)) { continue }
        $line = $readTask.Result
        if ($null -eq $line) { break }
        $requestId = ''
        $request = $null
        try {
            if ($utf8.GetByteCount($line) + 1 -gt $MaximumLineBytes) { throw '[invalid-request] Protocol line is too large.' }
            $request = $line | ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
            if ([int]$request.schemaVersion -ne 1) { throw '[invalid-request] Unsupported protocol version.' }
            $requestId = [string]$request.requestId
            if ($requestId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
                -not (Register-BrokerRequestId -Id $requestId)) { throw '[invalid-request] requestId is malformed or duplicated.' }
            switch ([string]$request.operation) {
                'describe' { Invoke-Describe $request }
                'profile' { Invoke-Profile $request }
                'preview-narrowing' { Invoke-PreviewNarrowing $request }
                'apply-narrowing' { Invoke-ApplyNarrowing $request }
                'set-kill-switch' { Invoke-SetKillSwitch $request }
                'describe-widening' { Invoke-DescribeWidening $request }
                'confirm-widening-preview' { Invoke-ConfirmWideningPreview $request }
                'confirm-widening-mint' { Invoke-ConfirmWideningMint $request }
                'cancel-widening' { Invoke-CancelWidening $request }
                'dispatch' { Invoke-Dispatch $request }
                'cancel' { Stop-BrokerChild ([string]$request.dispatchId) $requestId }
                'shutdown' {
                    $accepting = $false
                    foreach ($id in @($children.Keys)) { Stop-BrokerChild $id $requestId -BrokerShutdown }
                    Write-DispatchProtocolMessage @{ schemaVersion = 1; requestId = $requestId; operation = 'shutdown-complete' }
                }
                default { throw '[invalid-request] Unknown operation.' }
            }
        }
        catch {
            $message = $_.Exception.Message
            $code = if ($message -match '^\[([a-z-]+)\]') { $Matches[1] } else { 'launch-failed' }
            Write-Rejection $requestId $code $message
            $failedDraftId = [string](Get-OptionalMember $request 'dispatchDraftId')
            if ($failedDraftId -and $drafts.ContainsKey($failedDraftId)) {
                $failedDraft = $drafts[$failedDraftId]
                Remove-DraftResidue $failedDraft
                $drafts.Remove($failedDraftId)
            }
        }
        if ($accepting) {
            $readTask = [Console]::In.ReadLineAsync()
        }
    }
}
finally {
    foreach ($id in @($children.Keys)) {
        $entry = $children[$id]
        Stop-AgentProcessContainment $entry.Containment $entry.Child.Process
        [void](Complete-AgentRedirectedProcess $entry.Child)
        Close-AgentProcessContainment $entry.Containment
        $entry.Pipe.Dispose()
    }
    foreach ($draft in @($drafts.Values)) {
        Remove-DraftResidue $draft
    }
}
