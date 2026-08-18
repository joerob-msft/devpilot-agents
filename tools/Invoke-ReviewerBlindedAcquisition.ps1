#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generic blinded transcript acquisition runner (outer supervisor).

.DESCRIPTION
    Captures EXACTLY ONE blinded model transcript for one declared reviewer role
    (generalist | specialist | verifier) against a sealed, non-promotable replay
    snapshot, reusing the production reviewer's EXACT prompt construction,
    result-marker parser, schemas, scan windows, retry classification/accounting,
    sealed routing and model subprocess boundary. It:

      * accepts exactly one blinded fixture projection, one digest-bound
        non-promotable sealed replay snapshot, one explicit role, one supported
        model id (validated through the module registry), the expected commit /
        full ref / RepoPath, an output root, and a cryptographically random
        authorization token;
      * REFUSES to load or accept any oracle / expected-decision material, by
        strict schema PLUS a recursive forbidden-key scan;
      * authors a single authorized acquisition plan that binds the projection
        SHA-256, the snapshot digest, the authorization token SHA-256 (never the
        token) and, for the verifier, the independently captured discovery
        candidate and its cluster hash;
      * holds an atomic CreateNew launch lease (no resume / replacement /
        automatic next role);
      * runs the exact current build/clean/ref checks;
      * scrubs Azure DevOps write-provider credentials from the reviewer child
        while preserving the GitHub credential Copilot itself authenticates with;
      * supervises the reviewer child with DIRECT stdout/stderr files, a per-call
        and a total deadline, an activity watchdog, a bounded drain, recursive
        owned-tree cancellation and exit code 124 on timeout, identifying the
        child by PID/handle (never by command-text matching);
      * seals an immutable, canonical, oracle-free transcript package whose
        manifest binds every file's length + SHA-256 and the pack/snapshot
        identity, and verifies from direct telemetry that no provider process or
        write path ran. Test-only stub runs additionally prove no real model ran.

    It never performs a provider / Azure DevOps / GitHub write, vote, comment, or
    promotion. Replay is permanently preview-only with no live fallback. A
    production acquisition launches the one explicitly authorized model; the
    deterministic test mode launches only the pinned offline stub adapter.

.NOTES
    This tool only orchestrates and seals. The exact production prompt/parser/
    subprocess path executes inside Start-ReviewerAgent.ps1 under its gated
    -AcquireTranscriptRole acquisition mode, so no logic is duplicated here.
#>
[CmdletBinding(DefaultParameterSetName = 'Acquire')]
param(
    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [ValidateSet('generalist', 'specialist', 'verifier')]
    [string]$Role,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [string]$FixtureProjectionFile,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [string]$Model,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [string]$ConfigFile,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [string]$ReplayRoot,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [string]$ReplaySnapshotName,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ReplayManifestDigest,

    [Parameter(ParameterSetName = 'Acquire')]
    [string]$OfflineModelAdapterManifest,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedReviewerBaseCommit,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int]$PullRequestId,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHeadCommit,

    [Parameter(ParameterSetName = 'Acquire', Mandatory)]
    [string]$ExpectedRef,

    [Parameter(ParameterSetName = 'Acquire')]
    [string]$CandidateInputFile,

    # The verifier role also requires the SEALED discovery transcript package the
    # candidate was extracted from. Its seal, recursive inventory, result marker
    # and exact identity are validated here; the discovery result marker is then
    # handed to the child and its digests are bound into the plan. The verifier's
    # single generalist pass is rebuilt from this sealed evidence, never truth.
    [Parameter(ParameterSetName = 'Acquire')]
    [string]$DiscoveryPackageRoot,

    # Optional explicit pin for a trusted earlier reviewer build that produced the
    # independent discovery package. Without it, the package must match this build.
    [Parameter(ParameterSetName = 'Acquire')]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$DiscoverySourceScriptSha256,

    # Optional authenticated replay root for the discovery package's exact source
    # snapshot. This is required only when source and verifier are sibling benchmark
    # materializations of the same independently sealed replay.
    [Parameter(ParameterSetName = 'Acquire')]
    [string]$DiscoveryReplayRoot,

    # Cross-check model set for every role. The reviewer's
    # convention specialist and reciprocal cross-verification are intrinsically a
    # multi-model orchestration: the cycle is configured with a generalist model
    # pair plus a convention specialist model, exactly as production runs it. The
    # acquisition -Model names the ONE role/model whose transcript is captured and
    # sealed; these name the surrounding configured models the cycle needs to build
    # the exact production input for that one role. A generalist capture is its
    # discovery model and still requires the configured second pass.
    [Parameter(ParameterSetName = 'Acquire')]
    [string]$SecondGeneralistModel,

    [Parameter(ParameterSetName = 'Acquire')]
    [string]$DiscoveryGeneralistModel,

    [Parameter(ParameterSetName = 'Acquire')]
    [string]$ConventionSpecialistModel,

    [Parameter(ParameterSetName = 'Acquire')]
    [string]$ConventionVerifierModel,

    # A cryptographically random authorization token. Omit to have one minted
    # here from a CSPRNG. Only its SHA-256 is ever persisted.
    [Parameter(ParameterSetName = 'Acquire')]
    [string]$AuthorizationToken,

    [Parameter(ParameterSetName = 'Acquire')]
    [string]$OperatorAlias = 'acquisition-operator',

    [Parameter(ParameterSetName = 'Acquire')]
    [ValidateRange(5, 3600)]
    [int]$PerCallTimeoutSeconds = 60,

    [Parameter(ParameterSetName = 'Acquire')]
    [ValidateRange(10, 7200)]
    [int]$TotalTimeoutSeconds = 300,

    [Parameter(ParameterSetName = 'Acquire')]
    [ValidateRange(10, 3600)]
    [int]$ActivityTimeoutSeconds = 120,

    # Production requires a clean worktree at the expected commit. Test harnesses
    # run inside a dirty development tree, so this narrowly relaxes ONLY the
    # porcelain-clean assertion; the exact HEAD/ref/ancestor checks still run.
    [Parameter(ParameterSetName = 'Acquire')]
    [switch]$AllowDirtyWorktree,

    # Test-only switch. When present, execution is pinned to the repository's
    # sealed offline stub adapter (deterministic subprocess only). Without it,
    # NO offline adapter is wired and the reviewer would use its real production
    # model boundary - which this harness never launches. The offline adapter
    # manifest may select a stub BEHAVIOR but can never swap the pinned script.
    [Parameter(ParameterSetName = 'Acquire')]
    [switch]$UseOfflineStubAdapter,

    # Validate the complete acquisition declaration and emit typed readiness JSON
    # without minting a token or plan, taking a lease, creating state, or starting
    # any process. This deliberately remains in the Acquire parameter set so the
    # exact same required inputs and validation path are exercised.
    [Parameter(ParameterSetName = 'Acquire')]
    [switch]$Preflight,

    [Parameter(Mandatory)]
    [string]$OutputRoot,

    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),

    [string]$SealKeyPath,

    # Re-verify an already-sealed package instead of acquiring a new one.
    [Parameter(ParameterSetName = 'Verify', Mandatory)]
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8 = [System.Text.UTF8Encoding]::new($false, $true)

# The reviewer child is the Copilot path, not an MCP/provider child. Copilot
# authenticates with the first available GitHub credential in
# COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN precedence, so stripping that
# family here prevents the authorized model subprocess from starting. ADO
# credentials are write-provider authority the reviewer/Copilot path never
# needs, and remain scrubbed. Start-ReviewerAgent applies its stricter
# $McpSensitiveEnvironmentVariables boundary to every MCP/tool child, removing
# both credential families there.
$CopilotSensitiveEnvironmentVariables = @(
    'AZURE_DEVOPS_EXT_PAT', 'SYSTEM_ACCESSTOKEN'
)

$ReviewerScript = Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
$SchemaDir = Join-Path $RepoRoot 'src\Agents\reviewer\acquisition\v1'
. (Join-Path $RepoRoot 'src\Agents\reviewer\AcquisitionPackage.ps1')
$HarnessModule = Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1'

# ---------------------------------------------------------------------------
# Deterministic helpers
# ---------------------------------------------------------------------------

function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Utf8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-CanonicalJsonElement {
    # Canonicalize a parsed System.Text.Json element: object keys sorted ordinally,
    # arrays preserved in order, strings/numbers kept EXACTLY as parsed (System.Text.Json
    # never coerces an ISO-8601 string into a DateTime, unlike ConvertFrom-Json).
    param([System.Text.Json.JsonElement]$Element, [int]$Depth = 0)
    if ($Depth -gt 64) { throw "Canonical JSON exceeded depth 64." }
    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $props = @($Element.EnumerateObject())
            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($p in $props) { [void]$names.Add($p.Name) }
            $names.Sort([StringComparer]::Ordinal)
            $map = @{}
            foreach ($p in $props) { $map[$p.Name] = $p.Value }
            $parts = foreach ($n in $names) {
                (ConvertTo-Json -InputObject $n -Compress) + ':' + (ConvertTo-CanonicalJsonElement -Element $map[$n] -Depth ($Depth + 1))
            }
            return '{' + ($parts -join ',') + '}'
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $parts = foreach ($item in $Element.EnumerateArray()) { ConvertTo-CanonicalJsonElement -Element $item -Depth ($Depth + 1) }
            return '[' + ($parts -join ',') + ']'
        }
        ([System.Text.Json.JsonValueKind]::String) { return (ConvertTo-Json -InputObject $Element.GetString() -Compress) }
        ([System.Text.Json.JsonValueKind]::Number) { return $Element.GetRawText() }
        ([System.Text.Json.JsonValueKind]::True) { return 'true' }
        ([System.Text.Json.JsonValueKind]::False) { return 'false' }
        ([System.Text.Json.JsonValueKind]::Null) { return 'null' }
        default { return $Element.GetRawText() }
    }
}

function ConvertTo-CanonicalJsonText {
    # Deterministic JSON for sealing, computed from JSON TEXT so string values are
    # preserved byte-for-byte. Idempotent: canonical text re-canonicalizes to itself.
    param([Parameter(Mandatory)][string]$JsonText)
    $doc = [System.Text.Json.JsonDocument]::Parse($JsonText)
    try { return (ConvertTo-CanonicalJsonElement -Element $doc.RootElement) }
    finally { $doc.Dispose() }
}

function ConvertTo-AcquisitionCanonicalJson {
    # Canonicalize an in-memory object graph by first rendering it to JSON text
    # (which never carries live DateTime instances in these manifests) and then
    # running the text canonicalizer. Kept as the ergonomic entry point.
    param($Value)
    return (ConvertTo-CanonicalJsonText -JsonText (ConvertTo-Json -InputObject $Value -Depth 64 -Compress))
}

function Get-AcquisitionForbiddenKeyHits {
    # Recursive forbidden-key scan: defence in depth behind the strict schema so
    # no oracle / expected-decision / answer-key / ground-truth / adjudication /
    # golden label can reach an acquisition input.
    param([Parameter(Mandatory)][AllowNull()]$Node, [string]$Path = '$', [int]$Depth = 0)
    if ($Depth -gt 64) { throw "Forbidden-key scan exceeded depth 64." }
    $hits = [System.Collections.Generic.List[string]]::new()
    $deniedExact = @(
        'oracle', 'oraclehash', 'expected', 'expecteddecision', 'expectedsemanticsha256',
        'expecteddelivery', 'expecteddeliveryeligibility', 'groundtruth', 'ground_truth',
        'answerkey', 'answer', 'adjudication', 'golden', 'goldendecision', 'verdicttruth',
        'correctness', 'deliveryeligibility', 'label', 'labels', 'truth', 'decision'
    )
    $deniedSubstring = @('oracle', 'groundtruth', 'answerkey', 'adjudication', 'goldendecision',
        'expecteddecision', 'expectedsemantic', 'expecteddelivery')
    $keys = @()
    if ($Node -is [System.Collections.IDictionary]) { $keys = @($Node.Keys | ForEach-Object { [string]$_ }) }
    elseif ($Node -is [System.Management.Automation.PSCustomObject]) { $keys = @($Node.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($key in $keys) {
        $lower = ([string]$key).ToLowerInvariant()
        $isHit = ($deniedExact -contains $lower)
        if (-not $isHit) { foreach ($sub in $deniedSubstring) { if ($lower.Contains($sub)) { $isHit = $true; break } } }
        if ($isHit) { [void]$hits.Add("$Path.$key") }
        if ($Node -is [System.Collections.IDictionary]) { $child = $Node[$key] } else { $child = $Node.PSObject.Properties[$key].Value }
        foreach ($h in (Get-AcquisitionForbiddenKeyHits -Node $child -Path "$Path.$key" -Depth ($Depth + 1))) { [void]$hits.Add($h) }
    }
    if ($Node -isnot [string] -and $Node -is [System.Collections.IEnumerable]) {
        $index = 0
        foreach ($item in @($Node)) {
            foreach ($h in (Get-AcquisitionForbiddenKeyHits -Node $item -Path "$Path[$index]" -Depth ($Depth + 1))) { [void]$hits.Add($h) }
            $index++
        }
    }
    return $hits.ToArray()
}

function Assert-AcquisitionNoForbiddenKeys {
    param([Parameter(Mandatory)][AllowNull()]$Node, [Parameter(Mandatory)][string]$Surface)
    $hits = @(Get-AcquisitionForbiddenKeyHits -Node $Node)
    if ($hits.Count -gt 0) {
        throw "$Surface carries forbidden oracle/expected-decision field(s): $($hits -join ', '). Acquisition inputs are stimulus only."
    }
}

function Assert-AcquisitionSchema {
    param([Parameter(Mandatory)][string]$JsonText, [Parameter(Mandatory)][string]$SchemaName, [Parameter(Mandatory)][string]$Surface)
    $schemaPath = Join-Path $SchemaDir $SchemaName
    $schemaErrors = $null
    if (-not (Test-Json -Json $JsonText -SchemaFile $schemaPath -ErrorVariable schemaErrors -ErrorAction SilentlyContinue)) {
        $detail = ''
        if ($schemaErrors) { $detail = ' Details: ' + (($schemaErrors | ForEach-Object { $_.ToString() }) -join '; ') }
        throw "$Surface failed its versioned schema ($SchemaName).$detail"
    }
}

function Get-AcquisitionGitLayout {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $dotGit = Join-Path $RepositoryRoot '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) {
        return [pscustomobject]@{ GitDirectory = (Resolve-Path -LiteralPath $dotGit).Path; CommonDirectory = (Resolve-Path -LiteralPath $dotGit).Path }
    }
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) {
        throw "RepoPath '$RepositoryRoot' is not a git worktree."
    }
    $pointer = [IO.File]::ReadAllText($dotGit, $Utf8).Trim()
    if ($pointer -notmatch '^gitdir:\s*(.+)$') { throw "RepoPath '$RepositoryRoot' has an invalid .git pointer." }
    $gitDirectory = $Matches[1]
    if (-not [IO.Path]::IsPathRooted($gitDirectory)) {
        $gitDirectory = Join-Path $RepositoryRoot $gitDirectory
    }
    $gitDirectory = [IO.Path]::GetFullPath($gitDirectory)
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
        throw "RepoPath '$RepositoryRoot' points to a missing git directory."
    }
    $commonDirectory = $gitDirectory
    $commonPointer = Join-Path $gitDirectory 'commondir'
    if (Test-Path -LiteralPath $commonPointer -PathType Leaf) {
        $commonValue = [IO.File]::ReadAllText($commonPointer, $Utf8).Trim()
        $commonDirectory = if ([IO.Path]::IsPathRooted($commonValue)) {
            [IO.Path]::GetFullPath($commonValue)
        }
        else { [IO.Path]::GetFullPath((Join-Path $gitDirectory $commonValue)) }
    }
    if (-not (Test-Path -LiteralPath $commonDirectory -PathType Container)) {
        throw "RepoPath '$RepositoryRoot' points to a missing common git directory."
    }
    return [pscustomobject]@{ GitDirectory = $gitDirectory; CommonDirectory = $commonDirectory }
}

function Resolve-AcquisitionGitRef {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$Ref,
        [int]$Depth = 0
    )
    if ($Depth -gt 8 -or $Ref -notmatch '^refs/[A-Za-z0-9._/-]+$' -or
        $Ref -match '(^|/)\.\.?(/|$)|//|[\\]') {
        throw "Git ref '$Ref' is not a safe full ref."
    }
    foreach ($root in @([string]$Layout.GitDirectory, [string]$Layout.CommonDirectory) | Select-Object -Unique) {
        $candidate = Join-Path $root ($Ref -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $value = [IO.File]::ReadAllText($candidate, $Utf8).Trim()
            if ($value -match '^ref:\s*(refs/.+)$') {
                return Resolve-AcquisitionGitRef -Layout $Layout -Ref $Matches[1] -Depth ($Depth + 1)
            }
            if ($value -match '^[0-9a-fA-F]{40}$') { return $value.ToLowerInvariant() }
            throw "Git ref '$Ref' does not contain a commit object id."
        }
    }
    $packedRefs = Join-Path ([string]$Layout.CommonDirectory) 'packed-refs'
    if (Test-Path -LiteralPath $packedRefs -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($packedRefs, $Utf8)) {
            if ($line.StartsWith('#') -or $line.StartsWith('^')) { continue }
            $parts = $line.Split(' ', 2, [StringSplitOptions]::RemoveEmptyEntries)
            if ($parts.Count -eq 2 -and $parts[1] -ceq $Ref -and $parts[0] -match '^[0-9a-fA-F]{40}$') {
                return $parts[0].ToLowerInvariant()
            }
        }
    }
    throw "Expected ref '$Ref' does not resolve to a commit in this worktree."
}

function Get-AcquisitionGitHead {
    param([Parameter(Mandatory)]$Layout)
    $headPath = Join-Path ([string]$Layout.GitDirectory) 'HEAD'
    if (-not (Test-Path -LiteralPath $headPath -PathType Leaf)) { throw 'Git HEAD is missing.' }
    $headValue = [IO.File]::ReadAllText($headPath, $Utf8).Trim()
    if ($headValue -match '^ref:\s*(refs/.+)$') {
        return Resolve-AcquisitionGitRef -Layout $Layout -Ref $Matches[1]
    }
    if ($headValue -match '^[0-9a-fA-F]{40}$') { return $headValue.ToLowerInvariant() }
    throw 'Git HEAD does not contain a commit object id or symbolic ref.'
}

function Get-AcquisitionSealKeyPath {
    if ($SealKeyPath) { return $SealKeyPath }
    $dir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.devpilot'
    if (-not $Preflight) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir 'reviewer-acquisition-seal.key')
}

function Get-AcquisitionSealKey {
    $path = Get-AcquisitionSealKeyPath
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Preflight) {
            throw "Preflight will not create the acquisition seal key '$path'; supply an existing -SealKeyPath."
        }
        $bytes = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        [IO.File]::WriteAllBytes($path, $bytes)
        try { & icacls $path /inheritance:r /grant:r "$($env:USERNAME):(R,W)" *> $null } catch { }
    }
    return [IO.File]::ReadAllBytes($path)
}

function Get-HmacHex {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][byte[]]$Key)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try { return ([BitConverter]::ToString($hmac.ComputeHash($Utf8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hmac.Dispose() }
}

function Set-PathReadOnly {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly
    # Fail closed (blocker E): re-read the attributes and confirm the read-only
    # bit actually took. A seal that could not make an artifact immutable is not
    # a seal, so a failed attribute set throws rather than being silently ignored.
    $verify = Get-Item -LiteralPath $Path -Force
    if (($verify.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
        throw "Failed to mark '$Path' read-only while sealing; the immutability seal cannot be honored."
    }
}

# ---------------------------------------------------------------------------
# Telemetry evaluation (direct proof of no provider process or write)
# ---------------------------------------------------------------------------

function Get-TelemetrySummary {
    param([Parameter(Mandatory)][string]$TelemetryPath)
    $events = @()
    $fileExists = Test-Path -LiteralPath $TelemetryPath -PathType Leaf
    $sinkBytes = 0L
    $sinkSha256 = ''
    if ($fileExists) {
        $sinkBytes = [int64](Get-Item -LiteralPath $TelemetryPath).Length
        $sinkSha256 = Get-FileSha256Hex -Path $TelemetryPath
        $events = @(Get-Content -LiteralPath $TelemetryPath -Encoding UTF8 |
                Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 32 })
    }
    $processStarts = @($events | Where-Object { [string]$_.event -ceq 'process.started' })
    $realModelStarts = @($processStarts | Where-Object {
            $exe = ''
            if ($_.PSObject.Properties['data'] -and $_.data.PSObject.Properties['executable']) { $exe = [string]$_.data.executable }
            [IO.Path]::GetFileNameWithoutExtension($exe) -in @('agency', 'copilot')
        })
    $liveProcess = @($events | Where-Object { [string]$_.event -ceq 'provider.liveProcessStarted' })
    $liveWrite = @($events | Where-Object { [string]$_.event -ceq 'provider.liveWrite' })
    $writeTools = @($events | Where-Object { [string]$_.event -in @('tool.write', 'provider.write', 'delivery.posted') })
    return [ordered]@{
        mode                      = if ($UseOfflineStubAdapter) { 'production-test-only' } else { 'production' }
        fileExists                = $fileExists
        sinkBytes                 = $sinkBytes
        sinkSha256                = $sinkSha256
        totalEvents               = $events.Count
        modelSubprocessStarts     = $processStarts.Count
        realModelStarts           = $realModelStarts.Count
        providerLiveProcessStarts = $liveProcess.Count
        providerLiveWrites        = $liveWrite.Count
        writeToolInvocations      = $writeTools.Count
        zeroWriteVerified         = ($fileExists -and $events.Count -gt 0 -and
            $liveProcess.Count -eq 0 -and $liveWrite.Count -eq 0 -and
            $writeTools.Count -eq 0)
    }
}

# ---------------------------------------------------------------------------
# Package sealing and verification
# ---------------------------------------------------------------------------

function New-PackageFileTable {
    param([Parameter(Mandatory)][string]$PackageDir, [string[]]$Exclude = @())
    $rootFull = [IO.Path]::GetFullPath($PackageDir).TrimEnd('\', '/')
    $files = [System.Collections.Generic.List[object]]::new()
    # Recurse the WHOLE package tree so every file at any depth is bound. Relative
    # POSIX-style paths are recorded so a nested file cannot masquerade as bound
    # by basename alone.
    foreach ($file in @(Get-ChildItem -LiteralPath $PackageDir -File -Recurse -Force | Sort-Object FullName)) {
        $rel = ($file.FullName.Substring($rootFull.Length)).TrimStart('\', '/').Replace('\', '/')
        if ($Exclude -contains $rel) { continue }
        # A reparse point (symlink / junction) is not a real captured artifact and
        # could redirect a bound name at a remote target; refuse to seal one.
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to seal a package containing a reparse-point file: $rel"
        }
        [void]$files.Add([ordered]@{
                name   = $rel
                sha256 = Get-FileSha256Hex -Path $file.FullName
                bytes  = [int]$file.Length
            })
    }
    return , $files.ToArray()
}

function New-PackageDirectoryTable {
    # Recursively inventory every directory in the package (blocker E). Reparse
    # points and empty directories are refused outright: an empty directory
    # carries no evidence yet could smuggle in an unbound file after sealing, and
    # a reparse directory could redirect the whole subtree. Every retained
    # directory is bound by its relative POSIX path so an injected nested
    # directory is detected as unbound on verification.
    param([Parameter(Mandatory)][string]$PackageDir)
    $rootFull = [IO.Path]::GetFullPath($PackageDir).TrimEnd('\', '/')
    $dirs = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in @(Get-ChildItem -LiteralPath $PackageDir -Directory -Recurse -Force | Sort-Object FullName)) {
        $rel = ($dir.FullName.Substring($rootFull.Length)).TrimStart('\', '/').Replace('\', '/')
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to seal a package containing a reparse-point directory: $rel"
        }
        if (@(Get-ChildItem -LiteralPath $dir.FullName -Force).Count -eq 0) {
            throw "Refusing to seal a package containing an empty directory: $rel"
        }
        [void]$dirs.Add([ordered]@{ name = $rel })
    }
    return , $dirs.ToArray()
}

function Get-SealedDirectoryProblems {
    # Shared recursive directory verification (blocker E) for both the success
    # package and terminal evidence: every real directory must be bound, no
    # unbound/injected directory may exist at any depth, no directory may be a
    # reparse point, and no directory may be empty.
    param(
        [Parameter(Mandatory)][string]$PackageDir,
        [Parameter(Mandatory)][AllowNull()]$Manifest
    )
    $problems = [System.Collections.Generic.List[string]]::new()
    $bound = @{}
    $declared = @()
    if ($Manifest -and $Manifest.PSObject.Properties['directories']) { $declared = @($Manifest.directories) }
    foreach ($d in $declared) {
        $rel = [string]$d.name
        $bound[$rel] = $true
        if ($rel -match '(^|/)\.\.(/|$)' -or $rel -match '^([a-zA-Z]:|/|\\)') { [void]$problems.Add("illegal bound directory: $rel"); continue }
        $dirPath = Join-Path $PackageDir ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) { [void]$problems.Add("missing bound directory: $rel") }
    }
    $rootFull = [IO.Path]::GetFullPath($PackageDir).TrimEnd('\', '/')
    foreach ($dir in @(Get-ChildItem -LiteralPath $PackageDir -Directory -Recurse -Force)) {
        $rel = ($dir.FullName.Substring($rootFull.Length)).TrimStart('\', '/').Replace('\', '/')
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$problems.Add("reparse-point directory present: $rel"); continue }
        if (-not $bound.ContainsKey($rel)) { [void]$problems.Add("unbound directory present: $rel") }
        if (@(Get-ChildItem -LiteralPath $dir.FullName -Force).Count -eq 0) { [void]$problems.Add("empty directory present: $rel") }
    }
    return $problems.ToArray()
}

function Write-SealedPackage {
    param(
        [Parameter(Mandatory)][string]$PackageDir,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest
    )
    Assert-AcquisitionSchema -JsonText (ConvertTo-Json -InputObject $Manifest -Depth 32) `
        -SchemaName 'transcript-package.schema.json' -Surface 'The transcript package manifest'
    $canonical = ConvertTo-AcquisitionCanonicalJson -Value $Manifest
    $manifestPath = Join-Path $PackageDir 'transcript-package.json'
    $sealPath = Join-Path $PackageDir 'transcript-package.seal'
    [IO.File]::WriteAllText($manifestPath, $canonical, $Utf8)
    $key = Get-AcquisitionSealKey
    $seal = [ordered]@{
        schemaVersion  = 1
        kind           = 'reviewer-blinded-transcript-package-seal'
        manifestSha256 = Get-Sha256Hex -Text $canonical
        manifestHmac   = Get-HmacHex -Text $canonical -Key $key
        sealedUtc      = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($sealPath, (ConvertTo-Json -InputObject $seal -Depth 8), $Utf8)
    # -Force so a hidden or nested file is enumerated and sealed read-only too; a
    # file left writable would break the immutability seal. Set-PathReadOnly fails
    # closed, so any file that cannot be made read-only aborts the seal.
    foreach ($file in @(Get-ChildItem -LiteralPath $PackageDir -File -Recurse -Force)) { Set-PathReadOnly -Path $file.FullName }
    return $manifestPath
}

function Test-SealedPackage {
    # Read-only verification used by tamper / missing / cross-substitution tests.
    param([Parameter(Mandatory)][string]$PackageDir)
    try {
        [void](Assert-ReviewerAcquisitionTranscriptPackage -PackageRoot $PackageDir `
                -SealKeyPath (Get-AcquisitionSealKeyPath) `
                -SchemaPath (Join-Path $SchemaDir 'transcript-package.schema.json'))
        return @()
    }
    catch { return @([string]$_.Exception.Message) }
}

function Test-SealedTerminalEvidence {
    # Read-only verification of a tamper-evident terminal-evidence package
    # (timeout / crash / failed capture). Mirrors Test-SealedPackage: canonical
    # round-trip, SHA-256 + HMAC seal, recursive per-file length+SHA-256 bind,
    # and rejection of any unbound file at any depth.
    param([Parameter(Mandatory)][string]$PackageDir)
    $problems = [System.Collections.Generic.List[string]]::new()
    $manifestPath = Join-Path $PackageDir 'terminal-evidence.json'
    $sealPath = Join-Path $PackageDir 'terminal-evidence.seal'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @('missing terminal-evidence.json') }
    if (-not (Test-Path -LiteralPath $sealPath)) { return @('missing terminal-evidence.seal') }
    $canonical = [IO.File]::ReadAllText($manifestPath, $Utf8)
    $manifest = $canonical | ConvertFrom-Json -Depth 32
    if ((ConvertTo-CanonicalJsonText -JsonText $canonical) -cne $canonical) {
        [void]$problems.Add('terminal-evidence is not canonical (tampered)')
    }
    $seal = (Get-Content -LiteralPath $sealPath -Raw) | ConvertFrom-Json -Depth 8
    $key = Get-AcquisitionSealKey
    if ([string]$seal.manifestSha256 -cne (Get-Sha256Hex -Text $canonical)) { [void]$problems.Add('terminal-evidence SHA-256 seal mismatch') }
    if ([string]$seal.manifestHmac -cne (Get-HmacHex -Text $canonical -Key $key)) { [void]$problems.Add('terminal-evidence HMAC seal mismatch') }
    $bound = @{}
    foreach ($entry in @($manifest.files)) {
        $rel = [string]$entry.name
        $bound[$rel] = $entry
        if ($rel -match '(^|/)\.\.(/|$)' -or $rel -match '^([a-zA-Z]:|/|\\)') { [void]$problems.Add("illegal bound path: $rel"); continue }
        $filePath = Join-Path $PackageDir ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { [void]$problems.Add("missing bound file: $rel"); continue }
        if ((Get-FileSha256Hex -Path $filePath) -cne [string]$entry.sha256) { [void]$problems.Add("SHA-256 mismatch: $rel") }
        if ([int](Get-Item -LiteralPath $filePath -Force).Length -ne [int]$entry.bytes) { [void]$problems.Add("byte-length mismatch: $rel") }
    }
    $rootFull = [IO.Path]::GetFullPath($PackageDir).TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $PackageDir -File -Recurse -Force)) {
        $rel = ($file.FullName.Substring($rootFull.Length)).TrimStart('\', '/').Replace('\', '/')
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { [void]$problems.Add("reparse-point file present: $rel"); continue }
        if (($file.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) { [void]$problems.Add("writable file present (not read-only): $rel") }
        if ($rel -in @('terminal-evidence.json', 'terminal-evidence.seal')) { continue }
        if (-not $bound.ContainsKey($rel)) { [void]$problems.Add("unbound file present: $rel") }
    }
    foreach ($p in @(Get-SealedDirectoryProblems -PackageDir $PackageDir -Manifest $manifest)) { [void]$problems.Add($p) }
    return $problems.ToArray()
}

# ---------------------------------------------------------------------------
# Supervised child launch (direct files, deadlines, watchdog, tree kill, 124)
# ---------------------------------------------------------------------------

function Invoke-SupervisedReviewer {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath,
        [Parameter(Mandatory)][int]$TotalSeconds,
        [Parameter(Mandatory)][int]$ActivitySeconds,
        [hashtable]$Environment = @{},
        [string[]]$EnvironmentVariablesToRemove = @()
    )
    Import-Module $HarnessModule -Force -ErrorAction Stop
    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    foreach ($name in $Environment.Keys) { $psi.Environment[[string]$name] = [string]$Environment[$name] }
    foreach ($name in $EnvironmentVariablesToRemove) { [void]$psi.Environment.Remove($name) }

    # The environment belongs only to this ProcessStartInfo. In particular, the
    # production-test-only telemetry switch never mutates the supervisor's global
    # environment and cannot leak into a concurrent or later launch.
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $stdOutStream = [IO.FileStream]::new(
        $StdOutPath, [IO.FileMode]::Create, [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::Asynchronous)
    $stdErrStream = [IO.FileStream]::new(
        $StdErrPath, [IO.FileMode]::Create, [IO.FileAccess]::Write,
        [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::Asynchronous)
    try {
        if (-not $proc.Start()) { throw "Failed to start the reviewer child process." }
        $stdOutCopy = $proc.StandardOutput.BaseStream.CopyToAsync($stdOutStream)
        $stdErrCopy = $proc.StandardError.BaseStream.CopyToAsync($stdErrStream)
    }
    catch {
        $stdOutStream.Dispose()
        $stdErrStream.Dispose()
        $proc.Dispose()
        throw
    }
    $processId = [int]$proc.Id
    $startedUtc = [DateTime]::UtcNow
    $deadline = $startedUtc.AddSeconds($TotalSeconds)
    $lastActivityUtc = $startedUtc
    $lastLength = -1L
    $timedOut = $false
    $timeoutReason = ''
    while ($true) {
        # WaitForExit is the bounded clock (never Start-Sleep). It returns as soon
        # as the child exits, or after the small slice for a liveness check.
        if ($proc.WaitForExit(250)) { break }
        $nowUtc = [DateTime]::UtcNow
        if ($nowUtc -ge $deadline) { $timedOut = $true; $timeoutReason = 'totalDeadline'; break }
        $currentLength = 0L
        foreach ($p in @($StdOutPath, $StdErrPath)) {
            if (Test-Path -LiteralPath $p) { $currentLength += [int64](Get-Item -LiteralPath $p).Length }
        }
        if ($currentLength -ne $lastLength) { $lastLength = $currentLength; $lastActivityUtc = $nowUtc }
        elseif (($nowUtc - $lastActivityUtc).TotalSeconds -ge $ActivitySeconds) {
            $timedOut = $true; $timeoutReason = 'activityWatchdog'; break
        }
    }
    if ($timedOut) {
        # Recursive cancellation of the owned tree by PID/handle - never by
        # command-text matching. A hung grandchild dies with its parent.
        try { Stop-ProcessTree -Process $proc } catch { }
        [void]$proc.WaitForExit(5000)
    }
    $drainFailure = ''
    try {
        try {
            $drained = [Threading.Tasks.Task]::WaitAll(
                [Threading.Tasks.Task[]]@($stdOutCopy, $stdErrCopy), 5000)
            if (-not $drained) { $drainFailure = 'outputDrainDeadline' }
        }
        catch [AggregateException] {
            $drainFailure = 'outputDrainFailure'
        }
        if ($drainFailure -and -not $proc.HasExited) {
            try { Stop-ProcessTree -Process $proc } catch { }
            [void]$proc.WaitForExit(5000)
        }
    }
    finally {
        $stdOutStream.Dispose()
        $stdErrStream.Dispose()
    }
    $exitCode = -1
    if (-not $timedOut -and -not $drainFailure) {
        try { $exitCode = [int]$proc.ExitCode } catch { $exitCode = -1 }
    }
    $result = [ordered]@{
        ProcessId     = $processId
        ExitCode      = $exitCode
        TimedOut      = $timedOut
        TimeoutReason = $timeoutReason
        FailureReason = $drainFailure
        StartedUtc    = $startedUtc.ToString('o')
        EndedUtc      = [DateTime]::UtcNow.ToString('o')
    }
    $proc.Dispose()
    return $result
}

# ---------------------------------------------------------------------------
# Verify-only entry
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Verify') {
    $packageDir = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) 'package'
    if (-not (Test-Path -LiteralPath $packageDir)) { $packageDir = [IO.Path]::GetFullPath($OutputRoot) }
    # A package is EITHER a sealed transcript OR tamper-evident terminal evidence
    # (timeout/crash). Verify whichever kind is present; both are HMAC-authenticated.
    $isTerminal = Test-Path -LiteralPath (Join-Path $packageDir 'terminal-evidence.json')
    if ($isTerminal) {
        $problems = @(Test-SealedTerminalEvidence -PackageDir $packageDir)
        $label = 'terminal-evidence'
    }
    else {
        $problems = @(Test-SealedPackage -PackageDir $packageDir)
        $label = 'sealed transcript package'
    }
    if ($problems.Count -gt 0) {
        Write-Host ("FAIL: $label verification found $($problems.Count) problem(s):") -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
        exit 2
    }
    Write-Host "PASS: $label verified (manifest seal, recursive per-file length+SHA-256, no unbound files)." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Acquire
# ---------------------------------------------------------------------------

$outputRootFull = [IO.Path]::GetFullPath($OutputRoot)
$outputParent = [IO.Path]::GetDirectoryName($outputRootFull)
if (-not $outputParent -or -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "The acquisition output root's parent directory must already exist."
}

$outputLeaf = [IO.Path]::GetFileName($outputRootFull.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
$leaseKey = (Get-Sha256Hex -Text $outputRootFull).Substring(0, 16)
$leasePath = Join-Path $outputParent (".$outputLeaf.$leaseKey.acquisition.lease")
$leaseStream = $null
if (Test-Path -LiteralPath $leasePath) {
    throw "A launch lease already exists at '$leasePath'; acquisition never resumes, replaces or auto-advances a consumed lease."
}
if (Test-Path -LiteralPath $outputRootFull) {
    if (@(Get-ChildItem -LiteralPath $outputRootFull -Force).Count -gt 0) {
        throw "Acquisition output root '$outputRootFull' must be empty or new."
    }
}

$packageDir = Join-Path $outputRootFull 'package'
$workDir = Join-Path $outputRootFull 'work'
$stateDir = Join-Path $workDir 'reviewer-state'
$telemetryPath = Join-Path $workDir 'telemetry.jsonl'
$planPath = Join-Path $workDir 'acquisition-plan.json'
$stdOutPath = Join-Path $workDir 'reviewer-stdout.log'
$stdErrPath = Join-Path $workDir 'reviewer-stderr.log'

# Preserve Acquire's original consumed-identity semantics: its lease remains the
# first mutation and failed validation consumes that output identity. Preflight
# alone stays entirely before this boundary and creates nothing.
if (-not $Preflight) {
    try {
        $leaseStream = [IO.File]::Open($leasePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch {
        throw "A launch lease already exists at '$leasePath'; acquisition never resumes, replaces or auto-advances a consumed lease."
    }
    if (-not (Test-Path -LiteralPath $outputRootFull)) {
        New-Item -ItemType Directory -Path $outputRootFull | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $packageDir, $workDir, $stateDir | Out-Null
}

foreach ($needed in @($ReviewerScript, $ConfigFile, $FixtureProjectionFile, $HarnessModule)) {
    if (-not (Test-Path -LiteralPath $needed -PathType Leaf)) { throw "Required input '$needed' does not exist." }
}
if ($UseOfflineStubAdapter -and -not $OfflineModelAdapterManifest) {
    throw "-UseOfflineStubAdapter requires -OfflineModelAdapterManifest."
}
if (-not $UseOfflineStubAdapter -and $OfflineModelAdapterManifest) {
    throw "-OfflineModelAdapterManifest is test-only and requires -UseOfflineStubAdapter."
}
$reviewerScriptFull = (Resolve-Path -LiteralPath $ReviewerScript).Path
$configFull = (Resolve-Path -LiteralPath $ConfigFile).Path
$projectionFull = (Resolve-Path -LiteralPath $FixtureProjectionFile).Path
$adapterFull = if ($UseOfflineStubAdapter) {
    (Resolve-Path -LiteralPath $OfflineModelAdapterManifest).Path
}
else { '' }
$replayRootFull = (Resolve-Path -LiteralPath $ReplayRoot).Path

# -- Load, schema-gate and oracle-scan the blinded projection ----------------
$projectionText = [IO.File]::ReadAllText($projectionFull, $Utf8)
Assert-AcquisitionSchema -JsonText $projectionText -SchemaName 'fixture-projection.schema.json' -Surface 'The blinded fixture projection'
$projection = $projectionText | ConvertFrom-Json -Depth 64
Assert-AcquisitionNoForbiddenKeys -Node $projection -Surface 'The blinded fixture projection'
if ($projection.PSObject.Properties['specialist'] -and $projection.specialist) {
    foreach ($name in @('conventionPlanJson', 'factPlanJson')) {
        if (-not $projection.specialist.PSObject.Properties[$name] -or
            [string]::IsNullOrWhiteSpace([string]$projection.specialist.$name)) { continue }
        try { $decodedRoleJson = ([string]$projection.specialist.$name) | ConvertFrom-Json -Depth 64 -ErrorAction Stop }
        catch { throw "The blinded fixture projection specialist.$name is not valid JSON." }
        Assert-AcquisitionNoForbiddenKeys -Node $decodedRoleJson `
            -Surface "The blinded fixture projection specialist.$name decoded JSON"
    }
}
if ([string]$projection.role -cne $Role) { throw "The projection is role '$($projection.role)', not the requested '$Role'." }
$projectionSha256 = Get-Sha256Hex -Text $projectionText

# -- Validate the model through the shared module registry (fail fast, before
#    any lease or child launch). The same registry gate re-runs inside the child.
Import-Module $HarnessModule -Force -ErrorAction Stop
. (Join-Path $RepoRoot 'src\Agents\reviewer\SourceTransport.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\CrossVerification.ps1')
if (-not (Get-Command Assert-AgentSupportedModel -ErrorAction SilentlyContinue)) {
    throw "The agent harness does not export Assert-AgentSupportedModel; the model cannot be validated through the registry."
}
[void](Assert-AgentSupportedModel -Model $Model)

$discoveryGeneralistModel = if ($DiscoveryGeneralistModel) { $DiscoveryGeneralistModel } else { $Model }
if ($Role -ceq 'generalist' -and [string]$discoveryGeneralistModel -cne [string]$Model) {
    throw 'A generalist acquisition is the discovery generalist; -DiscoveryGeneralistModel may not differ from -Model.'
}
if ($Role -ceq 'specialist' -and
    (-not $PSBoundParameters.ContainsKey('DiscoveryGeneralistModel') -or
        [string]::IsNullOrWhiteSpace([string]$DiscoveryGeneralistModel))) {
    throw "Specialist acquisition requires -DiscoveryGeneralistModel (the configured generalist first-pass model)."
}
if (-not $SecondGeneralistModel) {
    throw "$Role acquisition requires -SecondGeneralistModel (the configured second generalist model)."
}
[void](Assert-AgentSupportedModel -Model $discoveryGeneralistModel)
[void](Assert-AgentSupportedModel -Model $SecondGeneralistModel)
$pairPrimaryModel = if ($Role -ceq 'verifier') { $Model } else { $discoveryGeneralistModel }
if ([string]$pairPrimaryModel -ceq [string]$SecondGeneralistModel) {
    throw "$Role acquisition requires two distinct configured generalist models."
}
if (-not (Test-AgentGeneralistModelPair -Models @($pairPrimaryModel, $SecondGeneralistModel))) {
    $requiredPair = Get-AgentGeneralistModelPair
    throw ("$Role acquisition requires the current configured generalist pairing: " +
        "$($requiredPair.First) and $($requiredPair.Second).")
}

if ($Role -eq 'verifier') {
    if (-not $ConventionSpecialistModel) { throw "Verifier acquisition requires -ConventionSpecialistModel (the configured convention specialist model)." }
    if ($ConventionVerifierModel -and ([string]$ConventionVerifierModel -cne [string]$Model)) {
        throw "Verifier acquisition captures exactly the authorized -Model '$Model'; a differing -ConventionVerifierModel '$ConventionVerifierModel' is refused."
    }
    [void](Assert-AgentSupportedModel -Model $ConventionSpecialistModel)
    if ([string]$Model -ceq [string]$ConventionSpecialistModel) {
        throw "The convention specialist '$ConventionSpecialistModel' cannot be a verifier; -Model must name one configured generalist."
    }
}

# -- Canonical target identity from the authoritative sealed replay Bound ------
# The sealed replay snapshot manifest is the single source of truth for the PR /
# repository / project / source+target commit / change-set the run reproduces.
# Read it, confirm its manifest digest is EXACTLY the operator-pinned digest, then
# cross-check the blinded projection's declared binding against it. The canonical
# target is bound into the signed plan so the child can require projection binding
# == sealed replay Bound == plan.target on every applicable field before any role
# launch (blocker 2). A projection that points at a different commit / PR / repo
# than the snapshot it is replayed against is refused HERE, before the lease is
# authored - caller-supplied projection identity can never override the snapshot.
$replayManifestPath = Join-Path (Join-Path $replayRootFull $ReplaySnapshotName) 'manifest.json'
if (-not (Test-Path -LiteralPath $replayManifestPath -PathType Leaf)) {
    throw "The sealed replay snapshot '$ReplaySnapshotName' has no manifest at '$replayManifestPath'."
}
$replayManifest = ([IO.File]::ReadAllText($replayManifestPath, $Utf8)) | ConvertFrom-Json -Depth 32
# Preflight must prove the complete replay is production-loadable without
# launching the child. Acquire deliberately leaves the pinned-digest enforcement
# to the child so a replay-load crash is sealed as terminal evidence.
$validatedReplay = if ($Preflight) {
    New-AgentReplaySnapshot -ReplayRoot $replayRootFull -SnapshotName $ReplaySnapshotName `
        -ExpectedManifestDigest $ReplayManifestDigest
}
else { $null }
if ($Preflight) {
    if (-not [bool]$validatedReplay.Classification.NonPromotable) {
        throw "Preflight requires a classified non-promotable replay snapshot."
    }
    $validatedConfig = Get-AgentConfig -Path $configFull -AgentDir (Split-Path $reviewerScriptFull -Parent) `
        -SupportedSchemaVersions @(1) -PromptFileField 'promptFile'
    $validationPrimaryModel = if ($Role -ceq 'specialist') { $DiscoveryGeneralistModel } else { $Model }
    $configurationValidationArgs = @{
        ConfigFile = $configFull
        OperatorAlias = $OperatorAlias
        ValidateConfigurationOnly = $true
        ValidateConfigurationRole = $Role
        Model = $validationPrimaryModel
    }
    $configurationValidationArgs['SecondPassModel'] = $SecondGeneralistModel
    if ($Role -cin @('specialist', 'verifier')) {
        $configurationValidationArgs['ConventionSpecialistModel'] =
            $(if ($Role -ceq 'specialist') { $Model } else { $ConventionSpecialistModel })
    }
    if ($Role -ceq 'verifier') {
        $configurationValidationArgs['ConventionVerifierModel'] = $Model
    }
    $configReadiness = @(& $reviewerScriptFull @configurationValidationArgs)
    $configReadyRecord = @($configReadiness | Where-Object {
            [string]$_.kind -ceq 'reviewer-configuration-readiness' -and [bool]$_.valid
        })
    if ($configReadyRecord.Count -ne 1) {
        throw 'Preflight did not receive exactly one successful production reviewer configuration validation record.'
    }
    if ([string]$configReadyRecord[0].project -cne [string]$validatedReplay.Binding.Project -or
        [string]$configReadyRecord[0].repositoryId -cne [string]$validatedReplay.Binding.RepositoryId) {
        throw 'Preflight config repository identity does not match the replay binding.'
    }
    $promptSha256 = Get-FileSha256Hex -Path ([string]$validatedConfig.PromptFilePath)
    foreach ($bindingCheck in @(
            @{ Name = 'config'; Recorded = [string]$validatedReplay.Bindings.ConfigSha256; Actual = (Get-FileSha256Hex -Path $configFull) },
            @{ Name = 'prompt'; Recorded = [string]$validatedReplay.Bindings.PromptSha256; Actual = $promptSha256 },
            @{ Name = 'script'; Recorded = [string]$validatedReplay.Bindings.ScriptSha256; Actual = (Get-FileSha256Hex -Path $reviewerScriptFull) })) {
        if ($bindingCheck.Recorded -cne ('0' * 64) -and $bindingCheck.Recorded -cne $bindingCheck.Actual) {
            throw "Preflight $($bindingCheck.Name) bytes do not match the replay manifest binding."
        }
    }
    if ([string]$validatedReplay.Classification.SealKind -ceq 'benchmarkPackMaterialization') {
        $materialization = $validatedReplay.Classification.Sidecar
        if ($null -eq $materialization) { throw 'Preflight benchmark-pack replay has no validated materialization sidecar.' }
        foreach ($identityCheck in @(
                @{ Name = 'fixtureId'; Actual = [string]$projection.fixtureId },
                @{ Name = 'role'; Actual = $Role },
                @{ Name = 'projectionSha256'; Actual = $projectionSha256 })) {
            if (-not $materialization.PSObject.Properties[$identityCheck.Name] -or
                [string]$materialization.PSObject.Properties[$identityCheck.Name].Value -cne
                    [string]$identityCheck.Actual) {
                throw "Preflight benchmark-pack materialization does not bind the supplied $($identityCheck.Name)."
            }
        }
        foreach ($sidecarCheck in @(
                @{ Name = 'configSha256'; Actual = (Get-FileSha256Hex -Path $configFull) },
                @{ Name = 'promptSha256'; Actual = $promptSha256 },
                @{ Name = 'reviewerScriptSha256'; Actual = (Get-FileSha256Hex -Path $reviewerScriptFull) })) {
            if (-not $materialization.PSObject.Properties[$sidecarCheck.Name] -or
                ([string]$materialization.PSObject.Properties[$sidecarCheck.Name].Value).ToLowerInvariant() -cne
                    ([string]$sidecarCheck.Actual).ToLowerInvariant()) {
                throw "Preflight benchmark-pack materialization does not bind the supplied $($sidecarCheck.Name)."
            }
        }
        if (-not $materialization.PSObject.Properties['secondGeneralistModel'] -or
            [string]$materialization.secondGeneralistModel -cne [string]$SecondGeneralistModel) {
            throw 'Preflight benchmark-pack materialization does not bind the supplied secondGeneralistModel.'
        }
    }
    $boundModels = @($validatedReplay.Bindings.Models)
    $requestedModels = @($Model, $DiscoveryGeneralistModel, $SecondGeneralistModel,
        $ConventionSpecialistModel, $ConventionVerifierModel) | Where-Object { $_ } | Select-Object -Unique
    foreach ($requestedModel in $requestedModels) {
        if ($boundModels.Count -gt 0 -and $boundModels -cnotcontains $requestedModel) {
            throw "Preflight model '$requestedModel' is not bound by the replay manifest."
        }
    }
}
# The pinned -ReplayManifestDigest is NOT re-enforced here: the child's
# New-AgentReplaySnapshot recomputes the sealed snapshot digest and fail-closed
# refuses (throwing, so the outer seals tamper-evident CRASH terminal evidence)
# whenever it disagrees with the pinned digest. Duplicating that enforcement in
# the outer would pre-empt the child's fail-closed refusal and rob the crash
# terminal-evidence path of its only trigger. The outer instead reads the
# manifest's Bound purely to AUTHOR the canonical target, and the child then
# re-validates plan.target == its sealed-replay-derived Bound before any launch,
# so a wrong snapshot can never reach a role invocation regardless.
$replayBound = $replayManifest.binding
$planTarget = [ordered]@{
    prId            = [int]$replayBound.pullRequestId
    repositoryId    = [string]$replayBound.repositoryId
    project         = [string]$replayBound.project
    sourceCommit    = ([string]$replayBound.sourceCommit).ToLowerInvariant()
    targetCommit    = ([string]$replayBound.targetCommit).ToLowerInvariant()
    changeSetDigest = ([string]$replayBound.changeSetSha256).ToLowerInvariant()
}
if ($PullRequestId -ne $planTarget.prId) {
    throw "The requested -PullRequestId $PullRequestId does not match the sealed replay Bound pull request $($planTarget.prId)."
}
$projBinding = $projection.binding
if ([int]$projBinding.prId -ne $planTarget.prId) {
    throw "The blinded projection binding PR ($([int]$projBinding.prId)) does not match the sealed replay Bound PR ($($planTarget.prId))."
}
if ([string]$projBinding.repositoryId -cne $planTarget.repositoryId) {
    throw "The blinded projection binding repositoryId does not match the sealed replay Bound repository."
}
if ([string]$projBinding.project -cne $planTarget.project) {
    throw "The blinded projection binding project does not match the sealed replay Bound project."
}
if (([string]$projBinding.sourceCommit).ToLowerInvariant() -cne $planTarget.sourceCommit) {
    throw "The blinded projection binding sourceCommit does not match the sealed replay Bound sourceCommit."
}
if (([string]$projBinding.targetCommit).ToLowerInvariant() -cne $planTarget.targetCommit) {
    throw "The blinded projection binding targetCommit does not match the sealed replay Bound targetCommit."
}
if (([string]$projBinding.changeSetDigest).ToLowerInvariant() -cne $planTarget.changeSetDigest) {
    throw "The blinded projection binding changeSetDigest does not match the sealed replay Bound change set."
}
# For the verifier, the role-scoped projection also declares target/changeset; it
# must agree with the same authoritative sealed replay Bound.
if ($Role -eq 'verifier' -and $projection.PSObject.Properties['verifier'] -and $projection.verifier) {
    if (([string]$projection.verifier.targetCommit).ToLowerInvariant() -cne $planTarget.targetCommit) {
        throw "The verifier projection targetCommit does not match the sealed replay Bound targetCommit."
    }
    if (([string]$projection.verifier.changeSetDigest).ToLowerInvariant() -cne $planTarget.changeSetDigest) {
        throw "The verifier projection changeSetDigest does not match the sealed replay Bound change set."
    }
}
$candidateSha256 = $null
$clusterHash = $null
$planCandidate = $null
$planDiscovery = $null
$discoveryMarkerPath = $null
$discoveryCorePath = $null
$discoveryCoreBytes = $null
$discoveryMarkerBytes = $null
if ($Role -eq 'verifier') {
    if (-not $CandidateInputFile -or -not (Test-Path -LiteralPath $CandidateInputFile -PathType Leaf)) {
        throw "The verifier role requires -CandidateInputFile naming an independently captured discovery candidate."
    }
    $candidateFull = (Resolve-Path -LiteralPath $CandidateInputFile).Path
    $candidateText = [IO.File]::ReadAllText($candidateFull, $Utf8)
    Assert-AcquisitionSchema -JsonText $candidateText -SchemaName 'discovery-candidate.schema.json' -Surface 'The discovery candidate input'
    $candidate = $candidateText | ConvertFrom-Json -Depth 64
    Assert-AcquisitionNoForbiddenKeys -Node $candidate -Surface 'The discovery candidate input'
    if ([string]$candidate.sourceFixtureId -ceq [string]$projection.fixtureId -and [string]$candidate.sourceRole -ceq 'verifier') {
        throw "The discovery candidate cannot itself be a verifier capture of the same fixture."
    }
    $candidateSha256 = Get-Sha256Hex -Text $candidateText
    $clusterHash = Get-Sha256Hex -Text (ConvertTo-CanonicalJsonText -JsonText $candidateText)
    $planCandidate = [ordered]@{
        candidateInputSha256 = $candidateSha256
        sourceFixtureId      = [string]$candidate.sourceFixtureId
        sourceModel          = [string]$candidate.sourceModel
        sourceRole           = [string]$candidate.sourceRole
        clusterId            = [string]$candidate.clusterId
        clusterHash          = $clusterHash
    }

    # -- Sealed discovery transcript provenance (blocker 3) -------------------
    # The candidate must be extracted from a SEALED, independently captured
    # discovery transcript package. Validate its seal / recursive inventory /
    # result marker and its exact identity, then bind its manifest digest, marker
    # digest and the candidate extraction hash into the plan. The child rebuilds
    # its single generalist pass from the discovery marker alone - never truth.
    if (-not $DiscoveryPackageRoot -or -not (Test-Path -LiteralPath $DiscoveryPackageRoot -PathType Container)) {
        throw "The verifier role requires -DiscoveryPackageRoot naming the sealed discovery transcript package the candidate was extracted from."
    }
    $discoveryPackage = Assert-ReviewerAcquisitionTranscriptPackage `
        -PackageRoot $DiscoveryPackageRoot -SealKeyPath (Get-AcquisitionSealKeyPath) `
        -SchemaPath (Join-Path $SchemaDir 'transcript-package.schema.json') -RequireCaptured
    $discoveryRootFull = [string]$discoveryPackage.Root
    [byte[]]$discoveryCoreBytes = $discoveryPackage.CoreBytes
    [byte[]]$discoveryMarkerBytes = $discoveryPackage.MarkerBytes
    $discoveryCore = $discoveryPackage.Core
    $discoverySourceRole = [string]$discoveryCore.role
    if ($discoverySourceRole -cnotin @('generalist', 'specialist')) {
        throw "The sealed discovery package is a '$discoverySourceRole' capture; a verifier requires an independent generalist or specialist discovery capture."
    }
    $discoveryModel = [string]$discoveryCore.requestedModel
    if ([string]$candidate.sourceModel -cne $discoveryModel) {
        throw "The discovery candidate's source model '$([string]$candidate.sourceModel)' does not match the sealed discovery package model '$discoveryModel'."
    }
    # Blocker 1: the source fixture is DERIVED from the sealed discovery package's own
    # capture-core evidence, never asserted by the operator. Require the candidate's
    # declared sourceFixtureId to equal the sealed package fixtureId, then bind the
    # PACKAGE-derived value (not caller metadata) into the signed plan.
    $discoveryFixtureId = [string]$(if ($discoveryCore.PSObject.Properties['fixtureId']) { $discoveryCore.fixtureId } else { '' })
    if ([string]::IsNullOrWhiteSpace($discoveryFixtureId)) {
        throw "The sealed discovery package capture-core is missing its fixtureId; the candidate source fixture cannot be proven from the package."
    }
    if ([string]$candidate.sourceFixtureId -cne $discoveryFixtureId) {
        throw "The discovery candidate's sourceFixtureId '$([string]$candidate.sourceFixtureId)' does not match the sealed discovery package fixtureId '$discoveryFixtureId'; the source fixture is established by the sealed package, never by candidate metadata."
    }
    if ([string]$candidate.sourceRole -cne $discoverySourceRole) {
        throw "The discovery candidate's source role '$([string]$candidate.sourceRole)' does not match its sealed '$discoverySourceRole' package."
    }
    $configuredGeneralists = @([string]$Model, [string]$SecondGeneralistModel)
    if ($discoverySourceRole -ceq 'generalist' -and
        $configuredGeneralists -cnotcontains $discoveryModel) {
        throw "The sealed generalist source model '$discoveryModel' is not one of the configured generalist pair."
    }
    if ($discoverySourceRole -ceq 'specialist' -and
        $discoveryModel -cne [string]$ConventionSpecialistModel) {
        throw "The sealed specialist source model '$discoveryModel' does not equal the configured convention specialist '$ConventionSpecialistModel'."
    }
    if ($configuredGeneralists -cnotcontains [string]$Model -or
        [string]$Model -ceq [string]$ConventionSpecialistModel) {
        throw "The authorized verifier '$Model' must be one of the configured generalists and never the convention specialist."
    }

    # The authenticated source must be the exact replay identity (or its
    # authenticated materialization lineage) plus current config/script/prompt.
    # This rejects a valid but stale or cross-fixture package.
    $sourceSnapshot = $discoveryCore.snapshotIdentity
    if (([string]$discoveryCore.digests.snapshotManifestDigest).ToLowerInvariant() -cne
        ([string]$sourceSnapshot.manifestDigest).ToLowerInvariant()) {
        throw "The sealed discovery package disagrees internally on its snapshot digest."
    }
    $sourceReplayDigestMatches = (
        ([string]$sourceSnapshot.manifestDigest).ToLowerInvariant() -ceq
        ([string]$ReplayManifestDigest).ToLowerInvariant())
    $authenticatedSourceReplay = $null
    if ($DiscoveryReplayRoot) {
        $discoveryReplayRootFull = (Resolve-Path -LiteralPath $DiscoveryReplayRoot -ErrorAction Stop).Path
        $authenticatedSourceReplay = New-AgentReplaySnapshot -ReplayRoot $discoveryReplayRootFull `
            -SnapshotName ([string]$sourceSnapshot.snapshotName) `
            -ExpectedManifestDigest ([string]$sourceSnapshot.manifestDigest)
    }
    if (-not $sourceReplayDigestMatches) {
        # A verifier commonly consumes the non-promotable replay materialized from
        # a role-input capture rather than the source replay that produced the
        # discovery package. Authenticate that lineage in both Preflight and the
        # real acquisition path. Omitting ExpectedManifestDigest here preserves
        # the child's terminal-evidence path for an operator-pinned digest mismatch.
        $lineageReplay = $validatedReplay
        if ($null -eq $lineageReplay) {
            $lineageReplay = New-AgentReplaySnapshot -ReplayRoot $replayRootFull `
                -SnapshotName $ReplaySnapshotName
        }
        if ([string]$lineageReplay.Classification.SealKind -ceq 'benchmarkPackMaterialization') {
            $lineageDigest = [string]$lineageReplay.Classification.Sidecar.sourceManifestDigest
            $sourceReplayDigestMatches = (
                $lineageDigest.ToLowerInvariant() -ceq
                ([string]$sourceSnapshot.manifestDigest).ToLowerInvariant())
            if (-not $sourceReplayDigestMatches -and $authenticatedSourceReplay -and
                [string]$authenticatedSourceReplay.Classification.SealKind -ceq 'benchmarkPackMaterialization') {
                $sourceLineageDigest =
                    [string]$authenticatedSourceReplay.Classification.Sidecar.sourceManifestDigest
                $sourceReplayDigestMatches = (
                    $lineageDigest.ToLowerInvariant() -ceq
                    $sourceLineageDigest.ToLowerInvariant())
            }
        }
    }
    if (-not $sourceReplayDigestMatches) {
        throw "The sealed discovery package snapshot digest does not match the verifier replay identity or its authenticated materialization lineage."
    }
    foreach ($identityCheck in @(
            @('snapshot name', [string]$sourceSnapshot.snapshotName, [string]$ReplaySnapshotName),
            @('PR', [string]$sourceSnapshot.prId, [string]$planTarget.prId),
            @('repository', [string]$sourceSnapshot.repositoryId, [string]$planTarget.repositoryId),
            @('project', [string]$sourceSnapshot.project, [string]$planTarget.project),
            @('source commit', [string]$sourceSnapshot.sourceCommit, [string]$planTarget.sourceCommit),
            @('target commit', [string]$sourceSnapshot.targetCommit, [string]$planTarget.targetCommit),
            @('change set', [string]$sourceSnapshot.changeSetDigest, [string]$planTarget.changeSetDigest))) {
        if (([string]$identityCheck[1]).ToLowerInvariant() -cne
            ([string]$identityCheck[2]).ToLowerInvariant()) {
            throw "The sealed discovery package $($identityCheck[0]) does not match the verifier replay identity."
        }
    }
    $sourcePromptPath = if ($discoverySourceRole -ceq 'specialist') {
        Join-Path (Split-Path $reviewerScriptFull -Parent) 'convention-review.prompt.md'
    }
    else {
        [string](Get-AgentConfig -Path $configFull -AgentDir (Split-Path $reviewerScriptFull -Parent) `
            -SupportedSchemaVersions @(1) -PromptFileField 'promptFile').PromptFilePath
    }
    $expectedDiscoveryScriptSha256 = if ($PSBoundParameters.ContainsKey('DiscoverySourceScriptSha256')) {
        $DiscoverySourceScriptSha256
    }
    else { Get-FileSha256Hex -Path $reviewerScriptFull }
    foreach ($digestCheck in @(
            @('config', [string]$discoveryCore.digests.configSha256, (Get-FileSha256Hex -Path $configFull)),
            @('script', [string]$discoveryCore.digests.scriptSha256, $expectedDiscoveryScriptSha256),
            @('prompt', [string]$discoveryCore.digests.promptSha256, (Get-FileSha256Hex -Path $sourcePromptPath)))) {
        if (([string]$digestCheck[1]).ToLowerInvariant() -cne
            ([string]$digestCheck[2]).ToLowerInvariant()) {
            throw "The sealed discovery package $($digestCheck[0]) digest is stale or mismatched."
        }
    }
    $discoveryManifestPath = Join-Path $discoveryRootFull 'transcript-package.json'
    $discoveryPackageManifestSha256 = [string]$discoveryPackage.ManifestSha256
    $discoveryCoreSha256 = [string]$discoveryPackage.CoreSha256
    $discoveryMarkerText = [string]$discoveryPackage.MarkerText
    $discoveryMarkerSha256 = [string]$discoveryPackage.MarkerSha256

    # -- Blocker 1: derive the result-marker prefix + FULL binding DIRECTLY from
    #    the sealed discovery marker. Caller-supplied candidate metadata can never
    #    establish provenance: it is validated to equal the sealed-marker-derived
    #    values, and the DERIVED values are what the signed plan binds. The child
    #    re-derives the same from the sealed marker and requires exact equality
    #    before the verifier launches.
    $discoveryPrefix = [string]$discoveryCore.resultMarkerPrefix
    if ([string]::IsNullOrWhiteSpace($discoveryPrefix)) {
        throw "The sealed discovery capture-core is missing its resultMarkerPrefix; provenance cannot be established."
    }
    $discoveryOutcome = Get-AgentCliJsonOutcome -StdOutText $discoveryMarkerText
    $discoveryAnswer = if ($discoveryOutcome -is [System.Collections.IDictionary] -and $discoveryOutcome.Contains('Answer') -and $discoveryOutcome['Answer']) {
        [string]$discoveryOutcome['Answer']
    }
    else { $discoveryMarkerText }
    $discoveryAnswer = $discoveryAnswer.Trim()
    $discoveryPrefixIdx = $discoveryAnswer.IndexOf($discoveryPrefix, [System.StringComparison]::Ordinal)
    if ($discoveryPrefixIdx -lt 0) {
        throw "The sealed discovery marker does not carry its recorded result-marker prefix; provenance cannot be established."
    }
    $discoveryBody = $discoveryAnswer.Substring($discoveryPrefixIdx + $discoveryPrefix.Length).Trim()
    $discoveryMarkerJson = $null
    try { $discoveryMarkerJson = $discoveryBody | ConvertFrom-Json -Depth 32 }
    catch { throw "The sealed discovery marker body is not valid JSON; provenance cannot be established." }
    $specialistCandidates = @()
    if ($discoverySourceRole -ceq 'specialist') {
        if ($discoveryPrefix -cne [string]$script:ReviewerConventionSpecialistMarkerPrefix) {
            throw "The sealed specialist package does not use the exact production convention result-marker prefix."
        }
        $specialistSchema = Get-ReviewerConventionSpecialistMarkerSchema `
            -ExpectedProject ([string]$planTarget.project) -ExpectedNonce ([string]$discoveryCore.nonce)
        $specialistOutcome = ConvertFrom-AgentResultMarkerOutcome `
            -StdOutText $discoveryMarkerText -MarkerPrefix $discoveryPrefix `
            -Schema $specialistSchema -ScanWindowChars (Get-ReviewerConventionSpecialistScanWindowChars)
        if ([string]$specialistOutcome.Status -cne 'success') {
            throw "The sealed specialist result marker failed the exact production schema: $([string]$specialistOutcome.Status)."
        }
        $discoveryMarkerJson = $specialistOutcome.Value
        $specialistCandidates = @(
            Get-ReviewerAuthenticatedSpecialistCandidates -Core $discoveryCore -Marker $discoveryMarkerJson)
    }
    $sourceDerivedCandidates = @(ConvertTo-ReviewerIndependentDiscoveryCandidates `
            -SourceRole $discoverySourceRole -SourceModel $discoveryModel `
            -Marker $discoveryMarkerJson -SpecialistCandidates $specialistCandidates)
    if ($sourceDerivedCandidates.Count -eq 0) {
        throw "The sealed discovery package yielded no production-derived candidates."
    }
    $sourceDerivedClusters = @(Get-ReviewerVerificationClusters -Candidates $sourceDerivedCandidates)
    $sourceDerivedPairs = @($sourceDerivedCandidates | ForEach-Object {
            "$([string]$_.candidateId)`n$([string]$_.candidateHash)" } | Sort-Object)
    $sourceProvidedPairs = @(@($candidate.candidates) | ForEach-Object {
            "$([string]$_.candidateId)`n$([string]$_.candidateHash)" } | Sort-Object)
    if (($sourceDerivedPairs -join '|') -cne ($sourceProvidedPairs -join '|')) {
        throw "The supplied discovery candidate set is not the exact production-derived projection of the authenticated source package."
    }
    $sourceClusterIds = @(@($sourceDerivedClusters | ForEach-Object { [string]$_.clusterId }) | Sort-Object -Unique)
    if ($sourceClusterIds.Count -ne 1 -or [string]$candidate.clusterId -cne $sourceClusterIds[0]) {
        throw "The supplied discovery candidate cluster does not match the production-derived source cluster."
    }
    if ($discoverySourceRole -ceq 'specialist') {
        $sourceDerivedById = @{}
        foreach ($item in $sourceDerivedCandidates) { $sourceDerivedById[[string]$item.candidateId] = $item }
        foreach ($item in @($candidate.candidates)) {
            $derivedItem = $sourceDerivedById[[string]$item.candidateId]
            if ($null -eq $derivedItem -or [string]$item.originKind -cne 'convention' -or
                [string]$item.originKind -cne [string]$derivedItem.originKind -or
                [string]$item.originModel -cne [string]$derivedItem.originModel -or
                [string]$item.originArtifactSha256 -cne [string]$derivedItem.originArtifactSha256) {
                throw "The specialist candidate's convention origin/provenance is missing or fabricated."
            }
        }
    }
    $derivedMarkerBinding = [ordered]@{
        prId         = [int]$discoveryMarkerJson.prId
        repositoryId = [string]$discoveryMarkerJson.repositoryId
        project      = [string]$discoveryMarkerJson.project
        sourceCommit = ([string]$discoveryMarkerJson.reviewedSourceCommit).ToLowerInvariant()
    }
    if ([string]$candidate.resultMarkerPrefix -cne $discoveryPrefix) {
        throw "The discovery candidate's resultMarkerPrefix does not match the sealed discovery marker; caller metadata cannot establish provenance."
    }
    $candBinding = $candidate.resultMarkerBinding
    if ([int]$candBinding.prId -ne $derivedMarkerBinding.prId -or
        [string]$candBinding.repositoryId -cne $derivedMarkerBinding.repositoryId -or
        [string]$candBinding.project -cne $derivedMarkerBinding.project -or
        ([string]$candBinding.sourceCommit).ToLowerInvariant() -cne $derivedMarkerBinding.sourceCommit) {
        throw "The discovery candidate's resultMarkerBinding does not match the sealed discovery marker; caller metadata cannot establish provenance."
    }
    # The discovery must be about the SAME target the verifier is replayed against
    # (fixture PR / repository / project / source commit).
    if ($derivedMarkerBinding.prId -ne $planTarget.prId -or
        $derivedMarkerBinding.repositoryId -cne $planTarget.repositoryId -or
        $derivedMarkerBinding.project -cne $planTarget.project -or
        $derivedMarkerBinding.sourceCommit -cne $planTarget.sourceCommit) {
        throw "The sealed discovery marker identity does not match the canonical target; the verifier discovery is for a different PR/commit."
    }
    $planDiscovery = [ordered]@{
        packageManifestSha256   = $discoveryPackageManifestSha256
        sourceCoreSha256         = $discoveryCoreSha256
        markerSha256            = $discoveryMarkerSha256
        sourceModel             = $discoveryModel
        sourceRole              = $discoverySourceRole
        sourceFixtureId         = $discoveryFixtureId
        candidateExtractionHash = $candidateSha256
        resultMarkerPrefix      = $discoveryPrefix
        resultMarkerBinding     = $derivedMarkerBinding
    }
}
elseif ($CandidateInputFile) {
    throw "-CandidateInputFile is only valid for the verifier role; a non-verifier acquisition must not consume a candidate."
}
elseif ($DiscoveryPackageRoot) {
    throw "-DiscoveryPackageRoot is only valid for the verifier role; a non-verifier acquisition must not consume a discovery package."
}

# -- Exact current build / clean / ref checks --------------------------------
if ($Preflight) {
    # Preflight cannot start even a git subprocess. Resolve HEAD and the full ref
    # directly from worktree/common-dir metadata; Acquire repeats these checks
    # through git and additionally proves cleanliness + base ancestry.
    $gitLayout = Get-AcquisitionGitLayout -RepositoryRoot $RepoRoot
    $head = Get-AcquisitionGitHead -Layout $gitLayout
    if ($head -cne $ExpectedHeadCommit.ToLowerInvariant() -and $head -cne $ExpectedHeadCommit) {
        throw "Worktree HEAD '$head' does not match the expected commit '$ExpectedHeadCommit'."
    }
    if ($ExpectedRef -notmatch '^refs/') {
        throw "Expected ref '$ExpectedRef' must be a full ref (refs/...); a bare name or commit id is not accepted."
    }
    $refCommit = Resolve-AcquisitionGitRef -Layout $gitLayout -Ref $ExpectedRef
    if ($refCommit -cne $head) {
        throw "Expected ref '$ExpectedRef' resolves to '$refCommit', not the worktree HEAD '$head'."
    }
    if ($refCommit -cne $ExpectedHeadCommit.ToLowerInvariant() -and $refCommit -cne $ExpectedHeadCommit) {
        throw "Expected ref '$ExpectedRef' resolves to '$refCommit', not the expected head commit '$ExpectedHeadCommit'."
    }
}
else {
    $priorOptionalLocks = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS')
    [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', '0')
    Push-Location $RepoRoot
    try {
        $head = (& git rev-parse HEAD 2>$null).Trim()
        if ($LASTEXITCODE -ne 0) { throw "RepoPath '$RepoRoot' is not a git worktree." }
        if ($head -cne $ExpectedHeadCommit.ToLowerInvariant() -and $head -cne $ExpectedHeadCommit) {
            throw "Worktree HEAD '$head' does not match the expected commit '$ExpectedHeadCommit'."
        }
        if (-not $AllowDirtyWorktree) {
            $porcelain = @(& git status --porcelain)
            if ($porcelain.Count -gt 0) { throw "Worktree is not clean; acquisition requires an exact, clean build." }
        }
        if ($ExpectedRef -notmatch '^refs/') {
            throw "Expected ref '$ExpectedRef' must be a full ref (refs/...); a bare name or commit id is not accepted."
        }
        $refCommit = (& git rev-parse --verify --quiet "$ExpectedRef^{commit}" 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $refCommit) { throw "Expected ref '$ExpectedRef' does not resolve to a commit in this worktree." }
        $refCommit = $refCommit.Trim()
        if ($refCommit -cne $head) {
            throw "Expected ref '$ExpectedRef' resolves to '$refCommit', not the worktree HEAD '$head'."
        }
        if ($refCommit -cne $ExpectedHeadCommit.ToLowerInvariant() -and $refCommit -cne $ExpectedHeadCommit) {
            throw "Expected ref '$ExpectedRef' resolves to '$refCommit', not the expected head commit '$ExpectedHeadCommit'."
        }
        & git merge-base --is-ancestor $ExpectedReviewerBaseCommit HEAD
        if ($LASTEXITCODE -ne 0) { throw "Expected reviewer base commit '$ExpectedReviewerBaseCommit' is not an ancestor of HEAD." }
    }
    finally {
        Pop-Location
        [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', $priorOptionalLocks)
    }
}

# -- Read-only Preflight -------------------------------------------------------
# Everything above is shared with Acquire. Nothing above creates a plan, token,
# lease, state directory, process, or model invocation. Validate the eventual
# plan shape with inert placeholders, then return one typed readiness document.
if ($Preflight) {
    if ($AuthorizationToken) {
        throw "Preflight does not accept or mint an authorization token."
    }
    $planProbe = [ordered]@{
        schemaVersion            = 1
        kind                     = 'reviewer-blinded-acquisition-plan'
        planId                   = ('0' * 32)
        createdUtc               = '2000-01-01T00:00:00.0000000Z'
        role                     = $Role
        model                    = $Model
        secondGeneralistModel    = $SecondGeneralistModel
        fixtureId                = [string]$projection.fixtureId
        fixtureProjectionSha256  = $projectionSha256
        snapshotName             = $ReplaySnapshotName
        snapshotManifestDigest   = $ReplayManifestDigest.ToLowerInvariant()
        expectedBaseCommit       = $ExpectedReviewerBaseCommit.ToLowerInvariant()
        expectedRef              = $ExpectedRef
        expectedHeadCommit       = $ExpectedHeadCommit.ToLowerInvariant()
        repoPath                 = (Resolve-Path -LiteralPath $RepoRoot).Path
        outputRoot               = $outputRootFull
        configSha256             = (Get-FileSha256Hex -Path $configFull)
        authorizationTokenSha256 = ('0' * 64)
        nonce                    = ('0' * 32)
        classification           = [ordered]@{
            blinded = $true; oracleFree = $true; nonPromotable = $true
            writesPermitted = $false; acquisitionOnly = $true
        }
    }
    if ($Role -eq 'verifier') { $planProbe['candidate'] = $planCandidate; $planProbe['discovery'] = $planDiscovery }
    $planProbe['target'] = $planTarget
    Assert-AcquisitionSchema -JsonText (ConvertTo-Json -InputObject $planProbe -Depth 32) `
        -SchemaName 'acquisition-plan.schema.json' -Surface 'The prospective acquisition plan'

    $readiness = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-blinded-acquisition-readiness'
        ready = $true
        role = $Role
        model = $Model
        secondGeneralistModel = $SecondGeneralistModel
        fixture = [ordered]@{
            id = [string]$projection.fixtureId
            projectionPath = $projectionFull
            projectionSha256 = $projectionSha256
        }
        replay = [ordered]@{
            root = $replayRootFull
            snapshotName = $ReplaySnapshotName
            manifestDigest = [string]$validatedReplay.ManifestDigest
            resourceCount = [int]$validatedReplay.ResourceCount
            payloadBytes = [long]$validatedReplay.PayloadBytes
            nonPromotable = [bool]$validatedReplay.Classification.NonPromotable
        }
        config = [ordered]@{
            path = $configFull
            sha256 = (Get-FileSha256Hex -Path $configFull)
        }
        repository = [ordered]@{
            path = (Resolve-Path -LiteralPath $RepoRoot).Path
            head = $head
            ref = $ExpectedRef
            baseCommit = $ExpectedReviewerBaseCommit.ToLowerInvariant()
        }
        candidate = if ($Role -eq 'verifier') {
            [ordered]@{
                path = $candidateFull
                sha256 = $candidateSha256
                clusterHash = $clusterHash
                discoveryPackageRoot = $discoveryRootFull
            }
        } else { $null }
        output = [ordered]@{
            root = $outputRootFull
            leasePath = $leasePath
            collisionFree = $true
        }
        checks = [ordered]@{
            exactHead = $true
            exactRef = $true
            exactRepoPath = $true
            bundleBound = $true
            projectionBound = $true
            replayLoadable = $true
            configBound = $true
            modelSupported = $true
            roleFit = $true
            candidateFit = $true
            planFit = $true
            noWrite = $true
        }
        sideEffects = [ordered]@{
            planFilesCreated = 0
            tokensMinted = 0
            leasesCreated = 0
            processesStarted = 0
            modelsStarted = 0
            providerWrites = 0
        }
    }
    $readinessJson = ConvertTo-AcquisitionCanonicalJson -Value $readiness
    Assert-AcquisitionSchema -JsonText $readinessJson -SchemaName 'acquisition-readiness.schema.json' `
        -Surface 'The acquisition readiness report'
    Write-Output $readinessJson
    exit 0
}

# -- Mint the authorization token (CSPRNG) and author the plan ---------------
Assert-AcquisitionSchema -JsonText $projectionText -SchemaName 'fixture-projection.schema.json' -Surface 'The blinded fixture projection'
if (-not $AuthorizationToken) {
    $tokenBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
    $AuthorizationToken = ([BitConverter]::ToString($tokenBytes)).Replace('-', '').ToLowerInvariant()
}
# A supplied authorization token must carry real entropy: acquisition is gated on a
# cryptographically random token, so a short or single-character value is refused.
if ($AuthorizationToken.Length -lt 32) {
    throw "The authorization token is too short ($($AuthorizationToken.Length) chars); a cryptographically random token of at least 32 characters is required."
}
if (@($AuthorizationToken.ToCharArray() | Sort-Object -Unique).Count -lt 8) {
    throw "The authorization token has too little entropy (fewer than 8 distinct characters); supply a cryptographically random token."
}
$authorizationTokenSha256 = Get-Sha256Hex -Text $AuthorizationToken
# The raw token is retained ONLY in this process's memory to hand to the child
# through a scrubbed environment variable at launch (never argv, never a file,
# never a log). Its SHA-256 is the only form that is ever persisted, and the
# inner acquisition gate constant-time verifies the env token against it before
# any model launch. $AuthorizationToken is cleared right after the child exits.

$planIdBytes = New-Object byte[] 16
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($planIdBytes)
$planId = ([BitConverter]::ToString($planIdBytes)).Replace('-', '').ToLowerInvariant()
$nonceBytes = New-Object byte[] 16
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonceBytes)
$planNonce = ([BitConverter]::ToString($nonceBytes)).Replace('-', '').ToLowerInvariant()

$plan = [ordered]@{
    schemaVersion            = 1
    kind                     = 'reviewer-blinded-acquisition-plan'
    planId                   = $planId
    createdUtc               = [DateTime]::UtcNow.ToString('o')
    role                     = $Role
    model                    = $Model
    secondGeneralistModel    = $SecondGeneralistModel
    fixtureId                = [string]$projection.fixtureId
    fixtureProjectionSha256  = $projectionSha256
    snapshotName             = $ReplaySnapshotName
    snapshotManifestDigest   = $ReplayManifestDigest.ToLowerInvariant()
    expectedBaseCommit       = $ExpectedReviewerBaseCommit.ToLowerInvariant()
    expectedRef              = $ExpectedRef
    expectedHeadCommit       = $ExpectedHeadCommit.ToLowerInvariant()
    repoPath                 = (Resolve-Path -LiteralPath $RepoRoot).Path
    outputRoot               = $outputRootFull
    configSha256             = (Get-FileSha256Hex -Path $configFull)
    authorizationTokenSha256 = $authorizationTokenSha256
    nonce                    = $planNonce
    classification           = [ordered]@{
        blinded         = $true
        oracleFree      = $true
        nonPromotable   = $true
        writesPermitted = $false
        acquisitionOnly = $true
    }
}
if ($Role -eq 'verifier') { $plan['candidate'] = $planCandidate; $plan['discovery'] = $planDiscovery }
$plan['target'] = $planTarget
$planJson = ConvertTo-Json -InputObject $plan -Depth 32
Assert-AcquisitionSchema -JsonText $planJson -SchemaName 'acquisition-plan.schema.json' -Surface 'The authored acquisition plan'
# CreateNew: the plan is authored exactly once. A losing concurrent invocation
# (which never reaches here, having failed the lease) could not overwrite it.
$planBytes = $Utf8.GetBytes($planJson)
$planStream = [IO.File]::Open($planPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $planStream.Write($planBytes, 0, $planBytes.Length); $planStream.Flush() }
finally { $planStream.Dispose() }

# -- Authenticated plan signature (blocker C) --------------------------------
# HMAC-SHA256 over the EXACT plan bytes with a key DERIVED from the authorization
# token (SHA-256 of the token). The child re-derives the same key from the env
# token and constant-time verifies this signature over the plan bytes, so every
# identity the plan binds (role, model, repoPath, outputRoot, config, refs,
# head, nonce, digests) is authenticated in one check. The sidecar carries only
# the signature - never the token - and is authored exactly once (CreateNew).
$planSigKey = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Utf8.GetBytes($AuthorizationToken))
$planSigJson = ConvertTo-Json -InputObject ([ordered]@{
        schemaVersion = 1
        kind          = 'reviewer-blinded-acquisition-plan-signature'
        algorithm     = 'HMACSHA256'
        signature     = (Get-HmacHex -Text $planJson -Key $planSigKey)
    }) -Depth 8
$planSigBytes = $Utf8.GetBytes($planSigJson)
$planSigStream = [IO.File]::Open("$planPath.sig", [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $planSigStream.Write($planSigBytes, 0, $planSigBytes.Length); $planSigStream.Flush() }
finally { $planSigStream.Dispose() }
$planSigKey = $null

$supervisorResult = $null
$terminalStatus = 'captureFailedTerminal'
$exitCode = 1
$childEnvironment = $null
$discoveryCoreLock = $null
$discoveryMarkerLock = $null
try {
    if ($Role -eq 'verifier') {
        # The authenticated package may live in a caller-controlled directory.
        # Give the child only supervisor-owned copies of the exact verified bytes,
        # and hold deny-write/delete handles until the child exits.
        $discoveryStage = Join-Path $workDir 'authenticated-discovery'
        New-Item -ItemType Directory -Path $discoveryStage | Out-Null
        $discoveryCorePath = Join-Path $discoveryStage 'capture-core.json'
        $discoveryMarkerPath = Join-Path $discoveryStage 'result-marker.txt'
        [IO.File]::WriteAllBytes($discoveryCorePath, $discoveryCoreBytes)
        [IO.File]::WriteAllBytes($discoveryMarkerPath, $discoveryMarkerBytes)
        (Get-Item -LiteralPath $discoveryCorePath -Force).Attributes = [IO.FileAttributes]::ReadOnly
        (Get-Item -LiteralPath $discoveryMarkerPath -Force).Attributes = [IO.FileAttributes]::ReadOnly
        $discoveryCoreLock = [IO.File]::Open(
            $discoveryCorePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $discoveryMarkerLock = [IO.File]::Open(
            $discoveryMarkerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    }
    $leaseBytes = $Utf8.GetBytes((ConvertTo-Json -InputObject ([ordered]@{
                    planId = $planId; role = $Role; model = $Model; pid = $PID
                    createdUtc = [DateTime]::UtcNow.ToString('o')
                }) -Depth 8))
    $leaseStream.Write($leaseBytes, 0, $leaseBytes.Length)
    $leaseStream.Flush()

    # The child's primary -Model is the generalist first-pass model for the cycle.
    # For the generalist and verifier roles that IS the captured acquisition model
    # ($Model); for the specialist role the captured model is the convention
    # specialist, so the primary generalist model is named separately.
    $childPrimaryModel = if ($Role -eq 'specialist') {
        if (-not $DiscoveryGeneralistModel) { throw "Specialist acquisition requires -DiscoveryGeneralistModel (the configured generalist first-pass model)." }
        $DiscoveryGeneralistModel
    } else { $Model }

    $reviewerArgs = @(
        '-NoProfile', '-File', $reviewerScriptFull,
        '-Once', '-RepoPath', $RepoRoot,
        '-ConfigFile', $configFull, '-StateDir', $stateDir,
        '-OperatorAlias', $OperatorAlias, '-PullRequestId', "$PullRequestId",
        '-Model', $childPrimaryModel, '-SecondPassModel', $SecondGeneralistModel,
        '-CycleTimeoutSeconds', "$PerCallTimeoutSeconds",
        '-ReplayRoot', $replayRootFull, '-ReplaySnapshotName', $ReplaySnapshotName,
        '-ReplayManifestDigest', $ReplayManifestDigest,
        '-ExpectedReviewerBaseCommit', $ExpectedReviewerBaseCommit.ToLowerInvariant(),
        '-AcquireTranscriptRole', $Role,
        '-AcquisitionPlanFile', $planPath,
        '-AcquisitionFixtureProjectionFile', $projectionFull,
        '-AcquisitionOutputRoot', $packageDir
    )
    # -- Role model wiring. Every role carries the hash-bound configured second
    #    generalist exactly once above. The generalist role captures a single
    #    static-projection model pass (no cycle). The specialist and verifier drive the EXACT
    #    production cycle under the replay session, so the child is configured with
    #    the surrounding cross-check model set the production orchestration needs to
    #    build the exact input for the one captured role.
    if ($Role -eq 'specialist') {
        $reviewerArgs += @(
            '-EnableConventionSpecialist', '-ConventionSpecialistModel', $Model,
            '-ConventionSpecialistTimeoutSeconds', "$PerCallTimeoutSeconds"
        )
    }
    elseif ($Role -eq 'verifier') {
        if (-not $ConventionSpecialistModel) { throw "Verifier acquisition requires -ConventionSpecialistModel (the configured convention specialist model)." }
        # Blocker B: the verifier captures EXACTLY the authorized -Model. A caller
        # may not redirect the captured verifier assignment to a different model
        # through -ConventionVerifierModel; a differing value is refused so the
        # plan.model, the launched assignment, and the captured/CLI model are one.
        if ($ConventionVerifierModel -and ([string]$ConventionVerifierModel -cne [string]$Model)) {
            throw "Verifier acquisition captures exactly the authorized -Model '$Model'; a differing -ConventionVerifierModel '$ConventionVerifierModel' is refused."
        }
        $effectiveConventionVerifier = $Model
        $reviewerArgs += @(
            '-EnableConventionSpecialist', '-ConventionSpecialistModel', $ConventionSpecialistModel,
            '-ConventionSpecialistTimeoutSeconds', "$PerCallTimeoutSeconds",
            '-EnableVerificationPreview', '-ConventionVerifierModel', $effectiveConventionVerifier,
            '-VerificationTimeoutSeconds', "$PerCallTimeoutSeconds"
        )
    }

    # Adapter containment: only the explicit test-only switch pins execution to
    # the repository's sealed offline stub adapter. Without it, no offline
    # adapter is wired and the reviewer would use its real production model
    # boundary (never exercised here). The manifest may select a stub behavior
    # but can never swap the executable/script.
    if ($UseOfflineStubAdapter) {
        $reviewerArgs += @(
            '-EnableOfflineModelAdapter', '-OfflineModelAdapterManifest', $adapterFull,
            '-OfflineTelemetryPath', $telemetryPath,
            '-AcquisitionTestOnlyOfflineAdapter'
        )
    }
    if ($Role -eq 'verifier') {
        $reviewerArgs += @('-AcquisitionCandidateInputFile', $candidateFull)
        # The discovery result marker is handed to the child as a file (never on
        # argv); the child re-verifies its SHA-256 against the plan's sealed
        # discovery binding before rebuilding the single generalist pass.
        $reviewerArgs += @('-AcquisitionDiscoveryMarkerFile', $discoveryMarkerPath)
        $reviewerArgs += @('-AcquisitionDiscoveryCoreFile', $discoveryCorePath)
    }

    # The real authorization token and telemetry wiring are child-scoped PSI
    # environment entries: never argv, never a file/log, and never global state in
    # this supervisor. The telemetry writer is environment-driven in both real and
    # deterministic adapter acquisitions; only adapter mode receives its required
    # -OfflineTelemetryPath compatibility parameter above.
    $childEnvironment = @{
        REVIEWER_ACQUISITION_TOKEN       = $AuthorizationToken
        DEVPILOT_OFFLINE_TELEMETRY_MODE = 'production-test-only'
        DEVPILOT_OFFLINE_TELEMETRY_PATH = $telemetryPath
    }
    $supervisorResult = Invoke-SupervisedReviewer -Arguments $reviewerArgs -StdOutPath $stdOutPath `
        -StdErrPath $stdErrPath -TotalSeconds $TotalTimeoutSeconds -ActivitySeconds $ActivityTimeoutSeconds `
        -Environment $childEnvironment -EnvironmentVariablesToRemove $CopilotSensitiveEnvironmentVariables
}
finally {
    # Drop the supervisor-held child environment and token references the instant
    # the child exits. Neither was ever installed in the supervisor environment.
    if ($null -ne $childEnvironment) { $childEnvironment.Clear() }
    $AuthorizationToken = $null
    if ($discoveryMarkerLock) { $discoveryMarkerLock.Dispose() }
    if ($discoveryCoreLock) { $discoveryCoreLock.Dispose() }
    if ($leaseStream) { $leaseStream.Dispose() }
}

# -- Telemetry proof (direct, independent of the child's own summary) --------
$telemetry = Get-TelemetrySummary -TelemetryPath $telemetryPath

# -- Finalize: seal on success, terminal evidence on timeout/crash -----------
$capturePath = Join-Path $packageDir 'capture-core.json'
if ($supervisorResult.TimedOut) {
    $terminalStatus = 'timeout'
    $exitCode = 124
}
elseif ([int]$supervisorResult.ExitCode -ne 0) {
    $terminalStatus = 'crash'
    $exitCode = [int]$supervisorResult.ExitCode
    if ($exitCode -eq 0) { $exitCode = 1 }
}
elseif (-not (Test-Path -LiteralPath $capturePath)) {
    $terminalStatus = 'captureFailedTerminal'
    $exitCode = 1
}
else {
    $exitCode = 0
}

# Copy the direct telemetry into the sealed package as immutable evidence.
if (Test-Path -LiteralPath $telemetryPath) { Copy-Item -LiteralPath $telemetryPath -Destination (Join-Path $packageDir 'telemetry.jsonl') -Force }

# Copy the direct supervisor stdout/stderr into the package as immutable terminal
# evidence (blocker E). Nested under a bound `supervisor/` subdirectory (blocker 4)
# so the recursive inventory binds a genuine nested artifact and the recursive
# read-only seal covers depth > 0. Present in BOTH the success and terminal
# packages so the raw child streams are always bound and sealed. Always
# materialize each file so its presence is bound even when the child emitted
# nothing on that stream (an empty directory is refused by the sealer).
$supervisorDir = Join-Path $packageDir 'supervisor'
New-Item -ItemType Directory -Force -Path $supervisorDir | Out-Null
foreach ($log in @(
        @{ Src = $stdOutPath; Dst = 'supervisor-stdout.log' },
        @{ Src = $stdErrPath; Dst = 'supervisor-stderr.log' })) {
    $dst = Join-Path $supervisorDir $log.Dst
    if (Test-Path -LiteralPath $log.Src) { Copy-Item -LiteralPath $log.Src -Destination $dst -Force }
    else { [IO.File]::WriteAllText($dst, '', $Utf8) }
}

$core = $null
$coreCreatedUtc = ''
$coreStartedUtc = ''
$coreEndedUtc = ''
if (Test-Path -LiteralPath $capturePath) {
    $coreRawText = Get-Content -LiteralPath $capturePath -Raw
    $core = $coreRawText | ConvertFrom-Json -Depth 64
    # ConvertFrom-Json coerces ISO-8601 strings into [datetime] (culture-formatted on
    # re-stringify), so read the timestamps straight from the JSON text to preserve
    # the exact 'date-time' encoding the package schema requires.
    $coreDoc = [System.Text.Json.JsonDocument]::Parse($coreRawText)
    try {
        $root = $coreDoc.RootElement
        $coreCreatedUtc = $root.GetProperty('createdUtc').GetString()
        $timingsEl = $root.GetProperty('timings')
        $coreStartedUtc = $timingsEl.GetProperty('startedUtc').GetString()
        $coreEndedUtc = $timingsEl.GetProperty('endedUtc').GetString()
    }
    finally { $coreDoc.Dispose() }
}

if ($exitCode -eq 0 -and $core) {
    # Fail closed if the sealed telemetry does not prove zero-write.
    if (-not $telemetry.zeroWriteVerified) {
        throw ("Direct telemetry did not prove zero-write: liveProcesses=$($telemetry.providerLiveProcessStarts), liveWrites=$($telemetry.providerLiveWrites), " +
            "writeTools=$($telemetry.writeToolInvocations).")
    }
    $terminalStatus = [string]$core.terminalStatus

    $fileTable = New-PackageFileTable -PackageDir $packageDir -Exclude @('transcript-package.json', 'transcript-package.seal')
    $manifest = [ordered]@{
        schemaVersion      = 1
        kind               = 'reviewer-blinded-transcript-package'
        planId             = [string]$core.planId
        role               = [string]$core.role
        reportedModel      = [string]$core.reportedModel
        requestedModel     = [string]$core.requestedModel
        secondGeneralistModel = [string]$core.secondGeneralistModel
        nonce              = [string]$core.nonce
        nonceSha256        = [string]$core.nonceSha256
        resultMarkerPrefix = [string]$core.resultMarkerPrefix
        files              = $fileTable
        directories        = (New-PackageDirectoryTable -PackageDir $packageDir)
        digests            = [ordered]@{}
        snapshotIdentity   = [ordered]@{
            snapshotName    = [string]$core.snapshotIdentity.snapshotName
            manifestDigest  = [string]$core.snapshotIdentity.manifestDigest
            prId            = [int]$core.snapshotIdentity.prId
            repositoryId    = [string]$core.snapshotIdentity.repositoryId
            project         = [string]$core.snapshotIdentity.project
            sourceCommit    = ([string]$core.snapshotIdentity.sourceCommit).ToLowerInvariant()
            targetCommit    = ([string]$core.snapshotIdentity.targetCommit).ToLowerInvariant()
            changeSetDigest = ([string]$core.snapshotIdentity.changeSetDigest).ToLowerInvariant()
            nonPromotable   = $true
        }
        attempts           = @()
        usage              = [ordered]@{
            reported             = [bool]$core.usage.reported
            premiumRequests      = $core.usage.premiumRequests
            totalApiDurationMs   = $core.usage.totalApiDurationMs
            sessionDurationMs    = $core.usage.sessionDurationMs
            totalNanoAiu         = $core.usage.totalNanoAiu
            totalPremiumRequests = $core.usage.totalPremiumRequests
            unavailable          = [bool]$core.usage.unavailable
        }
        telemetry          = $telemetry
        timings            = [ordered]@{
            startedUtc      = [string]$coreStartedUtc
            endedUtc        = [string]$coreEndedUtc
            totalDurationMs = [int]$core.timings.totalDurationMs
        }
        terminalStatus     = [string]$core.terminalStatus
        createdUtc         = [string]$coreCreatedUtc
    }
    foreach ($p in $core.digests.PSObject.Properties) { $manifest.digests[$p.Name] = ([string]$p.Value).ToLowerInvariant() }
    foreach ($a in @($core.attempts)) {
        $manifest.attempts += , [ordered]@{
            attempt      = [int]$a.attempt
            nonce        = [string]$a.nonce
            nonceSha256  = [string]$a.nonceSha256
            markerStatus = [string]$a.markerStatus
            retryable    = [bool]$a.retryable
            modelRan     = [bool]$a.modelRan
            exitCode     = [int]$a.exitCode
            timedOut     = [bool]$a.timedOut
            reason       = [string]$a.reason
            detail       = [string]$(if ($a.PSObject.Properties['detail']) { $a.detail } else { '' })
            durationMs   = [int]$a.durationMs
            usage        = [ordered]@{
                reported             = [bool]$a.usage.reported
                premiumRequests      = $a.usage.premiumRequests
                totalApiDurationMs   = $a.usage.totalApiDurationMs
                sessionDurationMs    = $a.usage.sessionDurationMs
                totalNanoAiu         = $a.usage.totalNanoAiu
                totalPremiumRequests = $a.usage.totalPremiumRequests
                unavailable          = [bool]$a.usage.unavailable
            }
        }
    }
    $manifestPath = Write-SealedPackage -PackageDir $packageDir -Manifest $manifest
    $verifyProblems = @(Test-SealedPackage -PackageDir $packageDir)
    if ($verifyProblems.Count -gt 0) { throw "Freshly sealed package failed self-verification: $($verifyProblems -join '; ')" }
    Write-Host ("PASS: sealed blinded transcript package role=$Role status=$terminalStatus " +
        "reportedModel='$([string]$core.reportedModel)' attempts=$(@($core.attempts).Count) " +
        "zeroWrite=$($telemetry.zeroWriteVerified) -> $manifestPath") -ForegroundColor Green
}
else {
    # Immutable, tamper-evident terminal evidence for a timeout/crash/failed
    # capture. Its recursive file table binds every artifact the failed run left
    # behind, and an HMAC seal authenticates the manifest exactly like the
    # success package - so a timeout/crash package is as tamper-evident as a
    # sealed transcript. Every terminal artifact is then marked read-only.
    $terminalPath = Join-Path $packageDir 'terminal-evidence.json'
    $terminalSealPath = Join-Path $packageDir 'terminal-evidence.seal'
    $terminalFileTable = New-PackageFileTable -PackageDir $packageDir -Exclude @('terminal-evidence.json', 'terminal-evidence.seal')
    $terminalManifest = [ordered]@{
        schemaVersion  = 1
        kind           = 'reviewer-blinded-transcript-terminal-evidence'
        planId         = $planId
        role           = $Role
        requestedModel = $Model
        secondGeneralistModel = $SecondGeneralistModel
        terminalStatus = $terminalStatus
        supervisor     = $supervisorResult
        telemetry      = $telemetry
        files          = $terminalFileTable
        directories    = (New-PackageDirectoryTable -PackageDir $packageDir)
        createdUtc     = [DateTime]::UtcNow.ToString('o')
    }
    $terminalCanonical = ConvertTo-AcquisitionCanonicalJson -Value $terminalManifest
    [IO.File]::WriteAllText($terminalPath, $terminalCanonical, $Utf8)
    $terminalKey = Get-AcquisitionSealKey
    $terminalSeal = [ordered]@{
        schemaVersion  = 1
        kind           = 'reviewer-blinded-transcript-terminal-evidence-seal'
        manifestSha256 = Get-Sha256Hex -Text $terminalCanonical
        manifestHmac   = Get-HmacHex -Text $terminalCanonical -Key $terminalKey
        sealedUtc      = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($terminalSealPath, (ConvertTo-Json -InputObject $terminalSeal -Depth 8), $Utf8)
    # Fail closed (blocker E): mark every terminal artifact read-only - the helper
    # throws if any attribute set does not take - then self-verify the sealed
    # terminal evidence exactly like the success package so an injected/unbound/
    # reparse/empty entry or a broken seal is caught here, not by a later reader.
    foreach ($f in @(Get-ChildItem -LiteralPath $packageDir -File -Recurse -Force)) { Set-PathReadOnly -Path $f.FullName }
    $terminalProblems = @(Test-SealedTerminalEvidence -PackageDir $packageDir)
    if ($terminalProblems.Count -gt 0) { throw "Freshly sealed terminal evidence failed self-verification: $($terminalProblems -join '; ')" }
    Write-Warning ("Blinded acquisition did not seal a transcript: status=$terminalStatus " +
        "exit=$exitCode timeoutReason='$([string]$supervisorResult.TimeoutReason)'. Terminal evidence at $terminalPath.")
}

if ($leaseStream) { try { $leaseStream.Dispose() } catch { } }
exit $exitCode
