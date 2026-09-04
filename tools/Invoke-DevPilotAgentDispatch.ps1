#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DescriptorPath,
    [ValidateRange(1024, 65536)][int]$MaximumLineBytes = 65536,
    [ValidateRange(1, 3600)][int]$DraftLifetimeSeconds = 600
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
$accepting = $true

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
    param([string]$Role)
    if ($Role -notin @('reviewer', 'review-handler') -or -not $descriptor.roles.ContainsKey($Role)) {
        throw '[role-not-allowed] The requested manual role is not configured.'
    }
    $roleDescriptor = $descriptor.roles[$Role]
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
    foreach ($id in @($drafts.Keys)) {
        $draft = $drafts[$id]
        if ($draft.Consumed -or ($now - $draft.CreatedAt).TotalSeconds -le $DraftLifetimeSeconds) {
            continue
        }
        Remove-DraftResidue $draft
        $drafts.Remove($id)
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

function Invoke-Describe {
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
        $draftId = [Guid]::NewGuid().ToString('D')
        $capabilities = @($roleDescriptor.capabilities | Sort-Object -Unique)
        $mandatoryDenies = @($roleDescriptor.mandatoryDenies | Sort-Object -Unique)
        $harnessRole = Get-AgentHarnessCapabilityDescriptor -Role $role
        # Additive, read-only profile fields (PR1): delegableAvailable is always empty here because no
        # delegation/widening policy exists yet (PR2+ scope) -- everything is decided by the checked-in
        # operational-default ceiling, so every named capability's provenance is 'operational-default'.
        $absoluteDenies = @($harnessRole.absoluteDenies | Sort-Object -Unique)
        $allowedManualCapabilities = @($harnessRole.allowedManualCapabilities | Sort-Object -Unique)
        $delegableAvailable = @()
        $provenance = [ordered]@{}
        foreach ($name in @($allowedManualCapabilities + $mandatoryDenies + $absoluteDenies | Sort-Object -Unique)) {
            $provenance[$name] = 'operational-default'
        }
        $snapshot = New-ConfigSnapshot $roleDescriptor $provider $draftId
        $policy = [ordered]@{
            schemaVersion = 1; repositoryIdentity = $identity; role = $role
            capabilities = $capabilities; mandatoryDenies = $mandatoryDenies
            configSnapshotSha256 = $snapshot.SnapshotSha256
        }
        $policyDigest = Get-AgentCanonicalDigest $policy
        $prFingerprint = Get-AgentCanonicalDigest ([ordered]@{
                schemaVersion = 1; repositoryKey = $identity.key; pullRequestId = $prId
                sourceCommit = $pr.sourceCommit; sourceRef = $pr.sourceRef; targetRef = $pr.targetRef
                active = $pr.active; draft = $pr.draft; author = $pr.author
            })
        $drafts[$draftId] = @{
            CreatedAt = [DateTime]::UtcNow; Consumed = $false; Role = $role; PullRequestId = $prId
            RepositoryIdentity = $identity; PrSnapshot = $pr; Policy = $policy
            PolicyDigest = $policyDigest; PrFingerprint = $prFingerprint
            Snapshot = $snapshot; RoleDescriptor = $roleDescriptor
            PromptGuard = $null; Guardian = $null; GuardianToken = $null
        }
        Write-DispatchProtocolMessage @{
            schemaVersion = 1; requestId = [string]$Request.requestId; operation = 'capability-summary'
            dispatchDraftId = $draftId; repositoryIdentity = $identity; prSnapshot = $pr
            capabilityPolicyDigest = $policyDigest; prStateFingerprint = $prFingerprint
            capabilities = $capabilities; mandatoryDenies = $mandatoryDenies; dynamicConstraints = $constraints
            absoluteDenies = $absoluteDenies; allowedManualCapabilities = $allowedManualCapabilities
            delegableAvailable = $delegableAvailable; provenance = $provenance
        }
    }
    finally { if ($provider.Session) { Close-AgentMcpSession $provider.Session } }
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
    $manifest = [ordered]@{
        schemaVersion = 1; dispatchId = $dispatchId; role = $draft.Role
        repositoryKey = $identity.key; pullRequestId = $draft.PullRequestId
        capabilityPolicyDigest = $draft.PolicyDigest; prStateFingerprint = $draft.PrFingerprint
        policy = $draft.Policy; runtimeRoot = $draft.Snapshot.RuntimeRoot
        operatorPromptPath = $promptPath; startupPipe = $pipeName; eventLogDirectory = $eventDir
        prStateFingerprintSourceCommit = $draft.PrSnapshot.sourceCommit
        cancellationNonce = $cancellationNonce
        cancellationRequestPath = (Join-Path $draft.Snapshot.RuntimeRoot 'cancel.requested.json')
        cancellationAcknowledgementPath = (Join-Path $draft.Snapshot.RuntimeRoot 'cancel.acknowledged.json')
    }
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-AgentCanonicalJson $manifest), [Text.UTF8Encoding]::new($false))
    $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', [string]$expectedRoleScripts[$draft.Role],
        '-ConfigFile', $draft.Snapshot.SnapshotPath, '-RepoPath', [string]$draft.RoleDescriptor.repositoryRoot,
        '-StateDir', (Join-Path $draft.Snapshot.RuntimeRoot 'agent'),
        '-EventLogDirectory', $eventDir,
        '-DurableStateRoot', $durableRoot, '-LeaseRoot', $leaseRoot, '-OperatorAlias', [string]$descriptor.operatorAlias,
        '-PullRequestId', [string]$draft.PullRequestId, '-Once', '-ForceAnalysis',
        '-OutputMode', 'Json', '-ManualDispatchManifest', $manifestPath)
    foreach ($capability in @($draft.Policy.capabilities)) {
        $args += "-$capability"
    }
    $diagnostics = Join-Path $draft.Snapshot.Root 'diagnostics'
    $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList $args `
        -StandardOutputPath (Join-Path $diagnostics 'stdout.log') -StandardErrorPath (Join-Path $diagnostics 'stderr.log') `
        -WorkingDirectory $toolkitRoot
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
            if ($startupCode -notin @('already-running', 'delivery-pending')) {
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
                -not $requestIds.Add($requestId)) { throw '[invalid-request] requestId is malformed or duplicated.' }
            switch ([string]$request.operation) {
                'describe' { Invoke-Describe $request }
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
