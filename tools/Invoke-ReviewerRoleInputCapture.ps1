#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Supervises a NO-MODEL production role input/prompt capture and independently
    verifies that it launched nothing.

.DESCRIPTION
    Drives Start-ReviewerAgent.ps1's -CaptureRoleInputRole mode, which executes
    the exact current sealed planning / context / prompt construction for ONE
    role and model and stops at the exact production model boundary. This
    supervisor adds the outside half of the guarantee:

      * it validates every input before the child starts - strict schema, a
        recursive oracle/expected-decision KEY scan, and a recursive oracle /
        expected PATH scan, so an answer key can reach the run neither as data
        nor as a file name;
      * it re-resolves the declared full ref and HEAD from the git object store
        itself (never by running git) and fails closed on any disagreement;
      * it scrubs provider credentials out of the environment the child
        inherits, so a live read or write is not merely unused but impossible;
      * it wires the production-test-only offline telemetry sink and afterwards
        proves from that telemetry that ZERO model, agency or provider child
        processes started and that ZERO live reads or writes occurred;
      * it independently re-verifies the published bundle - schema, per-file
        length and SHA-256, recursive read-only, zero side effects, exactly one
        boundary hit, and identity/role/model agreement with what was requested.

    It never acquires a transcript, never runs a model, never writes to any
    provider, and never promotes anything: a capture is private research
    evidence taken from a permanently non-promotable sealed snapshot.

    -Preflight performs every readiness check and leaves the filesystem
    byte-for-byte untouched: no output root, no lease, no plan, no token, no
    process and no model. -VerifyOnly re-verifies an already published bundle.

.EXAMPLE
    ./tools/Invoke-ReviewerRoleInputCapture.ps1 -Role generalist `
        -Model claude-opus-5 -CaptureRequestFile ./bundle/capture-request.json `
        -ConfigFile ./bundle/config/reviewer.config.json `
        -ReplayRoot ./bundle/replay -ReplaySnapshotName synthetic-pr `
        -ReplayManifestDigest <64-hex> -PullRequestId 4242 `
        -ExpectedHeadCommit <40-hex> -ExpectedRef refs/heads/main `
        -OutputRoot ./captures/bpm-generalist
#>
[CmdletBinding(DefaultParameterSetName = 'Capture')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [ValidateSet('generalist', 'specialist', 'verifier')][string]$Role,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [string]$Model,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [string]$CaptureRequestFile,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [string]$ConfigFile,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [string]$ReplayRoot,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [string]$ReplaySnapshotName,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ReplayManifestDigest,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHeadCommit,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [ValidatePattern('^refs/[A-Za-z0-9._/-]+$')][string]$ExpectedRef,

    [Parameter(Mandatory, ParameterSetName = 'Capture')]
    [Parameter(Mandatory, ParameterSetName = 'Preflight')]
    [Parameter(Mandatory, ParameterSetName = 'Verify')]
    [string]$OutputRoot,

    # HMAC key kept outside the published bundle. Capture may create the default
    # private key; Preflight and VerifyOnly never create one.
    [Parameter(ParameterSetName = 'Capture')]
    [Parameter(ParameterSetName = 'Preflight')]
    [Parameter(ParameterSetName = 'Verify')]
    [string]$SealKeyPath,

    # Verifier role only: the independently captured discovery candidate the
    # cross-check is about, and the sealed discovery result marker it came from.
    [Parameter(ParameterSetName = 'Capture')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string]$CandidateInputFile,
    [Parameter(ParameterSetName = 'Capture')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string]$DiscoveryMarkerFile,

    # The surrounding configured model set the production orchestration needs in
    # order to build the exact input for the one captured role.
    [Parameter(ParameterSetName = 'Capture')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string]$SecondGeneralistModel,
    [Parameter(ParameterSetName = 'Capture')]
    [Parameter(ParameterSetName = 'Preflight')]
    [string]$ConventionSpecialistModel,

    # Optional legacy benchmark projection to re-materialize alongside the
    # capture. Read-only: every sealed resource is re-verified by hash and length.
    [Parameter(ParameterSetName = 'Capture')]
    [string]$LegacyProjectionFile,

    [Parameter(ParameterSetName = 'Preflight')][switch]$Preflight,
    [Parameter(Mandatory, ParameterSetName = 'Verify')][switch]$VerifyOnly,

    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 300,
    [ValidateRange(10, 3600)][int]$ActivityTimeoutSeconds = 120,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8 = [Text.UTF8Encoding]::new($false, $true)
$SchemaDir = Join-Path $RepoRoot 'src\Agents\reviewer\acquisition\v1'
$ReviewerScript = Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
$HarnessModule = Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'

# Provider credentials are removed from THIS process before the child starts, so
# the child cannot perform a live read or write even if some path tried to.
$SensitiveEnvironmentVariables = @(
    'AZURE_DEVOPS_EXT_PAT', 'AZURE_DEVOPS_PAT', 'SYSTEM_ACCESSTOKEN', 'ADO_PAT',
    'GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_PAT', 'COPILOT_TOKEN'
)

# A path or key that even LOOKS like an answer key is refused. The scan is over
# the WHOLE path, recursively, so an oracle cannot arrive as a parent directory.
$ForbiddenPathTokens = @(
    'oracle', 'expected-oracle', 'expectedsemantic', 'expected-semantic',
    'groundtruth', 'ground-truth', 'answerkey', 'answer-key', 'adjudication',
    'golden-decision', 'goldendecision', 'expected-decision', 'expecteddecision'
)

function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Utf8.GetBytes($Text)))).ToLowerInvariant()
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CaptureSealKeyPath {
    if ($SealKeyPath) { return [IO.Path]::GetFullPath($SealKeyPath) }
    return (Join-Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.devpilot') 'reviewer-role-input-capture-seal.key')
}

function Get-CaptureSealKey {
    param([switch]$Create)
    $path = Get-CaptureSealKeyPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if (-not $Create) {
            throw "The capture seal key '$path' does not exist; supply an existing -SealKeyPath."
        }
        $parent = Split-Path $path -Parent
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        try { & icacls $path /inheritance:r /grant:r "$($env:USERNAME):(R,W)" *> $null } catch { }
    }
    $key = [IO.File]::ReadAllBytes($path)
    if ($key.Length -ne 32) { throw "The capture seal key '$path' must contain exactly 32 bytes." }
    return , $key
}

function Get-HmacHex {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][byte[]]$Key)
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try { return ([Convert]::ToHexString($hmac.ComputeHash($Utf8.GetBytes($Text)))).ToLowerInvariant() }
    finally { $hmac.Dispose() }
}

function Test-FixedTimeHex {
    param([string]$A, [string]$B)
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $diff = $diff -bor ([int][char]$A[$i] -bxor [int][char]$B[$i])
    }
    return ($diff -eq 0)
}

function Write-CaptureSeal {
    param(
        [Parameter(Mandatory)][string]$BundleRoot,
        [Parameter(Mandatory)][string]$SignedFile,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $signedPath = Join-Path $BundleRoot $SignedFile
    $text = [IO.File]::ReadAllText($signedPath, $Utf8)
    $seal = [ordered]@{
        schemaVersion = 1
        kind          = 'reviewer-production-role-input-capture-seal'
        algorithm     = 'HMACSHA256'
        signedFile    = $SignedFile
        signedSha256  = Get-Sha256Hex -Text $text
        manifestHmac  = Get-HmacHex -Text $text -Key $Key
    }
    $sealPath = Join-Path $BundleRoot 'capture-seal.json'
    [IO.File]::WriteAllText($sealPath, ($seal | ConvertTo-Json -Compress), $Utf8)
    $item = Get-Item -LiteralPath $sealPath -Force
    $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly
}

function Assert-SafePath {
    <#
        Refuse an oracle / expected-decision path anywhere in the ancestry of an
        input. A capture is stimulus only; nothing that could carry the answer is
        allowed to be named, let alone read.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Surface)
    $full = [IO.Path]::GetFullPath($Path)
    $probe = $full
    while ($probe) {
        $leaf = [IO.Path]::GetFileName($probe)
        if ($leaf) {
            $lower = $leaf.ToLowerInvariant()
            foreach ($token in $ForbiddenPathTokens) {
                if ($lower.Contains($token)) {
                    throw "$Surface resolves through '$leaf', which names an oracle or expected decision. A role input capture is stimulus only."
                }
            }
        }
        $next = [IO.Path]::GetDirectoryName($probe)
        if (-not $next -or $next -ceq $probe) { break }
        $probe = $next
    }
    return $full
}

function Get-ForbiddenKeyHits {
    <#
        Recursive forbidden-key scan, defence in depth BEHIND the strict schema.
        A dictionary is not walked as a sequence: PowerShell hands `@($dict)`
        back the same dictionary, which would recurse into itself forever.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Node, [string]$Path = '$', [int]$Depth = 0)
    if ($Depth -gt 64) { throw 'Role input capture forbidden-key scan exceeded depth 64.' }
    $hits = [Collections.Generic.List[string]]::new()
    $deniedExact = @(
        'oracle', 'oraclehash', 'expected', 'expecteddecision', 'expectedsemanticsha256',
        'expecteddelivery', 'expecteddeliveryeligibility', 'groundtruth', 'ground_truth',
        'answerkey', 'answer', 'adjudication', 'golden', 'goldendecision', 'verdicttruth',
        'correctness', 'deliveryeligibility', 'label', 'labels', 'truth', 'decision'
    )
    $deniedSubstring = @(
        'oracle', 'groundtruth', 'answerkey', 'adjudication', 'goldendecision',
        'expecteddecision', 'expectedsemantic', 'expecteddelivery'
    )
    $keys = @()
    if ($Node -is [Collections.IDictionary]) { $keys = @($Node.Keys | ForEach-Object { [string]$_ }) }
    elseif ($Node -is [Management.Automation.PSCustomObject]) { $keys = @($Node.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($key in $keys) {
        $lower = ([string]$key).ToLowerInvariant()
        $isHit = ($deniedExact -contains $lower)
        if (-not $isHit) { foreach ($sub in $deniedSubstring) { if ($lower.Contains($sub)) { $isHit = $true; break } } }
        if ($isHit) { [void]$hits.Add("$Path.$key") }
        $child = if ($Node -is [Collections.IDictionary]) { $Node[$key] } else { $Node.PSObject.Properties[$key].Value }
        foreach ($h in (Get-ForbiddenKeyHits -Node $child -Path "$Path.$key" -Depth ($Depth + 1))) { [void]$hits.Add($h) }
    }
    if ($Node -isnot [string] -and $Node -isnot [Collections.IDictionary] -and $Node -is [Collections.IEnumerable]) {
        $index = 0
        foreach ($item in @($Node)) {
            foreach ($h in (Get-ForbiddenKeyHits -Node $item -Path "$Path[$index]" -Depth ($Depth + 1))) { [void]$hits.Add($h) }
            $index++
        }
    }
    return $hits.ToArray()
}

function Assert-NoForbiddenKeys {
    param([Parameter(Mandatory)][AllowNull()]$Node, [Parameter(Mandatory)][string]$Surface)
    $hits = @(Get-ForbiddenKeyHits -Node $Node)
    if ($hits.Count -gt 0) {
        throw "$Surface carries forbidden oracle/expected-decision field(s): $($hits -join ', '). A role input capture is stimulus only."
    }
}

function Assert-Schema {
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$SchemaName, [Parameter(Mandatory)][string]$Surface)
    $schemaFile = Join-Path $SchemaDir $SchemaName
    if (-not (Test-Path -LiteralPath $schemaFile)) { throw "Schema '$SchemaName' is missing." }
    $schemaErrors = $null
    if (-not (Test-Json -Json $Json -SchemaFile $schemaFile -ErrorAction SilentlyContinue -ErrorVariable schemaErrors)) {
        throw "$Surface failed schema '$SchemaName': $(($schemaErrors | ForEach-Object { $_.ToString() }) -join '; ')"
    }
}

function Get-GitLayout {
    <#
        Locate the git object store WITHOUT running git. A capture that shelled
        out to git would be starting a child process, which is exactly what this
        mode exists to prove it never does.
    #>
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $dotGit = Join-Path $RepositoryRoot '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) {
        $resolved = (Resolve-Path -LiteralPath $dotGit).Path
        $common = $resolved
        return [pscustomobject]@{ GitDirectory = $resolved; CommonDirectory = $common }
    }
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { throw "RepoRoot '$RepositoryRoot' is not a git worktree." }
    $pointer = [IO.File]::ReadAllText($dotGit, $Utf8).Trim()
    if ($pointer -notmatch '^gitdir:\s*(.+)$') { throw "RepoRoot '$RepositoryRoot' has an invalid .git pointer." }
    $gitDirectory = $Matches[1]
    if (-not [IO.Path]::IsPathRooted($gitDirectory)) { $gitDirectory = Join-Path $RepositoryRoot $gitDirectory }
    $gitDirectory = [IO.Path]::GetFullPath($gitDirectory)
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) { throw "RepoRoot '$RepositoryRoot' points to a missing git directory." }
    $commonDirectory = $gitDirectory
    $commonPointer = Join-Path $gitDirectory 'commondir'
    if (Test-Path -LiteralPath $commonPointer -PathType Leaf) {
        $commonValue = [IO.File]::ReadAllText($commonPointer, $Utf8).Trim()
        $commonDirectory = if ([IO.Path]::IsPathRooted($commonValue)) { [IO.Path]::GetFullPath($commonValue) }
        else { [IO.Path]::GetFullPath((Join-Path $gitDirectory $commonValue)) }
    }
    if (-not (Test-Path -LiteralPath $commonDirectory -PathType Container)) { throw "RepoRoot '$RepositoryRoot' points to a missing common git directory." }
    return [pscustomobject]@{ GitDirectory = $gitDirectory; CommonDirectory = $commonDirectory }
}

function Resolve-GitRef {
    param([Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$Ref, [int]$Depth = 0)
    if ($Depth -gt 8 -or $Ref -notmatch '^refs/[A-Za-z0-9._/-]+$' -or $Ref -match '(^|/)\.\.?(/|$)|//|[\\]') {
        throw "Git ref '$Ref' is not a safe full ref."
    }
    foreach ($root in @([string]$Layout.GitDirectory, [string]$Layout.CommonDirectory) | Select-Object -Unique) {
        $candidate = Join-Path $root ($Ref -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $value = [IO.File]::ReadAllText($candidate, $Utf8).Trim()
            if ($value -match '^ref:\s*(refs/.+)$') { return Resolve-GitRef -Layout $Layout -Ref $Matches[1] -Depth ($Depth + 1) }
            if ($value -match '^[0-9a-fA-F]{40}$') { return $value.ToLowerInvariant() }
            throw "Git ref '$Ref' does not contain a commit object id."
        }
    }
    $packedRefs = Join-Path ([string]$Layout.CommonDirectory) 'packed-refs'
    if (Test-Path -LiteralPath $packedRefs -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($packedRefs, $Utf8)) {
            if ($line.StartsWith('#') -or $line.StartsWith('^')) { continue }
            $parts = $line.Split(' ', 2, [StringSplitOptions]::RemoveEmptyEntries)
            if ($parts.Count -eq 2 -and $parts[1] -ceq $Ref -and $parts[0] -match '^[0-9a-fA-F]{40}$') { return $parts[0].ToLowerInvariant() }
        }
    }
    throw "Expected ref '$Ref' does not resolve to a commit in this worktree."
}

function Get-GitHead {
    param([Parameter(Mandatory)]$Layout)
    $headPath = Join-Path ([string]$Layout.GitDirectory) 'HEAD'
    if (-not (Test-Path -LiteralPath $headPath -PathType Leaf)) { throw 'Git HEAD is missing.' }
    $headValue = [IO.File]::ReadAllText($headPath, $Utf8).Trim()
    if ($headValue -match '^ref:\s*(refs/.+)$') { return Resolve-GitRef -Layout $Layout -Ref $Matches[1] }
    if ($headValue -match '^[0-9a-fA-F]{40}$') { return $headValue.ToLowerInvariant() }
    throw 'Git HEAD does not contain a commit object id or symbolic ref.'
}

function Get-TelemetryProof {
    <#
        Independent telemetry evidence for the zero-side-effect claim. A usable
        proof must be a present, parseable, non-empty sink and must contain at
        least one sealed replay serve. Missing or vacuous telemetry proves
        nothing and fails closed.

        This supersedes the earlier reading that an empty sink is the CORRECT
        outcome because a no-model capture "never opens a provider session and
        never serves a recorded read". That premise conflated the MODEL boundary
        with the REPLAY PROVIDER. A capture does stop before the model, but it
        reaches the boundary only by reading the sealed snapshot THROUGH the
        replay provider, so it necessarily records serves. Measured on the
        capture suite's three success paths, every published capture carries a
        non-zero sealedReplayServes against zero process, live-provider and
        write events, while every observed empty sink belonged to a run refused
        before it loaded the snapshot - never to a published capture. Requiring
        a serve therefore rejects vacuous "proof" without failing any honest
        capture, and the suite pins both directions.
    #>
    param([Parameter(Mandatory)][string]$TelemetryPath)
    if (-not (Test-Path -LiteralPath $TelemetryPath -PathType Leaf)) {
        throw 'Telemetry proof is missing: the child did not create its production-test-only sink.'
    }
    $events = @()
    try {
        $events = @(Get-Content -LiteralPath $TelemetryPath -Encoding UTF8 |
                Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 32 -ErrorAction Stop })
    }
    catch { throw "Telemetry proof is malformed: $($_.Exception.Message)" }
    if ($events.Count -eq 0) {
        throw 'Telemetry proof is empty and cannot establish a sealed replay execution.'
    }
    $processStarts = @($events | Where-Object { [string]$_.event -ceq 'process.started' })
    $modelStarts = @($processStarts | Where-Object {
            $exe = ''
            if ($_.PSObject.Properties['data'] -and $_.data.PSObject.Properties['executable']) { $exe = [string]$_.data.executable }
            [IO.Path]::GetFileNameWithoutExtension($exe) -in @('agency', 'copilot', 'pwsh', 'powershell')
        })
    $liveProcess = @($events | Where-Object { [string]$_.event -ceq 'provider.liveProcessStarted' })
    $liveWrite = @($events | Where-Object { [string]$_.event -ceq 'provider.liveWrite' })
    $writeTools = @($events | Where-Object { [string]$_.event -in @('tool.write', 'provider.write', 'delivery.posted') })
    $replayServes = @($events | Where-Object { [string]$_.event -ceq 'provider.replayServed' })
    if ($replayServes.Count -eq 0) {
        throw 'Telemetry proof contains no provider.replayServed event.'
    }
    return [ordered]@{
        fileExists               = $true
        parseError               = ''
        proofError               = ''
        totalEvents               = [int]$events.Count
        sealedReplayServes        = [int]$replayServes.Count
        childProcessStarts        = [int]$processStarts.Count
        modelOrAgencyStarts       = [int]$modelStarts.Count
        providerLiveProcessStarts = [int]$liveProcess.Count
        providerLiveWrites        = [int]$liveWrite.Count
        writeToolInvocations      = [int]$writeTools.Count
    }
}

function Test-CaptureBundle {
    <#
        Independent verification of a published bundle. Everything the manifest
        claims is recomputed from the bytes on disk; nothing is taken on trust.
        Returns the list of problems, empty when the bundle verifies.
    #>
    param(
        [Parameter(Mandatory)][string]$BundleRoot,
        [Parameter(Mandatory)][byte[]]$SealKey,
        [hashtable]$Expected = @{}
    )
    $problems = [Collections.Generic.List[string]]::new()
    $manifestPath = Join-Path $BundleRoot 'capture-manifest.json'
    $blockedPath = Join-Path $BundleRoot 'capture-blocked.json'
    $sealPath = Join-Path $BundleRoot 'capture-seal.json'
    $signedFile = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { 'capture-manifest.json' }
        elseif (Test-Path -LiteralPath $blockedPath -PathType Leaf) { 'capture-blocked.json' }
        else { '' }
    if (-not $signedFile) {
        [void]$problems.Add('the bundle publishes neither a capture manifest nor a typed blocker')
        return $problems.ToArray()
    }
    $signedPath = Join-Path $BundleRoot $signedFile
    $signedText = [IO.File]::ReadAllText($signedPath, $Utf8)
    if (-not (Test-Path -LiteralPath $sealPath -PathType Leaf)) {
        [void]$problems.Add('the bundle is missing capture-seal.json')
    }
    else {
        try {
            $seal = [IO.File]::ReadAllText($sealPath, $Utf8) | ConvertFrom-Json -Depth 8
            $sealKeys = @($seal.PSObject.Properties.Name | Sort-Object)
            $expectedSealKeys = @('algorithm', 'kind', 'manifestHmac', 'schemaVersion', 'signedFile', 'signedSha256')
            if (($sealKeys -join "`n") -cne ($expectedSealKeys -join "`n") -or
                [int]$seal.schemaVersion -ne 1 -or
                [string]$seal.kind -cne 'reviewer-production-role-input-capture-seal' -or
                [string]$seal.algorithm -cne 'HMACSHA256' -or
                [string]$seal.signedFile -cne $signedFile -or
                [string]$seal.signedSha256 -notmatch '^[0-9a-f]{64}$' -or
                [string]$seal.manifestHmac -notmatch '^[0-9a-f]{64}$') {
                [void]$problems.Add('capture-seal.json has an invalid or unexpected shape')
            }
            else {
                if (-not (Test-FixedTimeHex -A ([string]$seal.signedSha256) -B (Get-Sha256Hex -Text $signedText))) {
                    [void]$problems.Add('capture signed-file SHA-256 seal mismatch')
                }
                if (-not (Test-FixedTimeHex -A ([string]$seal.manifestHmac) -B (Get-HmacHex -Text $signedText -Key $SealKey))) {
                    [void]$problems.Add('capture manifest HMAC seal mismatch')
                }
            }
        }
        catch { [void]$problems.Add("capture-seal.json could not be verified: $($_.Exception.Message)") }
    }

    $rootItem = Get-Item -LiteralPath $BundleRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [void]$problems.Add('bundle root is a reparse point')
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $BundleRoot -Directory -Recurse -Force)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $relativeDirectory = [IO.Path]::GetRelativePath($BundleRoot, $directory.FullName).Replace('\', '/')
            [void]$problems.Add("bundle contains a reparse-point directory: $relativeDirectory")
        }
    }
    $onDisk = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $BundleRoot -File -Recurse -Force)) {
        $rel = [IO.Path]::GetRelativePath($BundleRoot, $file.FullName).Replace('\', '/')
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            [void]$problems.Add("bundle contains a reparse-point file: $rel")
            continue
        }
        if (($file.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
            [void]$problems.Add("bundle file is not read-only: $rel")
        }
        $onDisk[$rel] = $file
    }

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        try { Assert-Schema -Json $signedText -SchemaName 'role-input-capture-blocked.schema.json' -Surface 'The typed blocker' }
        catch { [void]$problems.Add($_.Exception.Message) }
        [void]$onDisk.Remove('capture-blocked.json')
        [void]$onDisk.Remove('capture-seal.json')
        foreach ($unbound in @($onDisk.Keys)) { [void]$problems.Add("typed blocker carries an unbound file: $unbound") }
        return $problems.ToArray()
    }
    $manifestText = $signedText
    try { Assert-Schema -Json $manifestText -SchemaName 'role-input-capture.schema.json' -Surface 'The capture manifest' }
    catch { [void]$problems.Add($_.Exception.Message) }
    $manifest = $manifestText | ConvertFrom-Json -Depth 64

    foreach ($entry in @($manifest.files)) {
        $rel = [string]$entry.path
        if (-not $onDisk.ContainsKey($rel)) { [void]$problems.Add("bound file is missing: $rel"); continue }
        $file = $onDisk[$rel]
        if ([long]$file.Length -ne [long]$entry.byteLength) { [void]$problems.Add("bound file length changed: $rel") }
        if ((Get-FileSha256Hex -Path $file.FullName) -cne [string]$entry.sha256) { [void]$problems.Add("bound file content changed: $rel") }
        [void]$onDisk.Remove($rel)
    }
    [void]$onDisk.Remove('capture-manifest.json')
    [void]$onDisk.Remove('capture-seal.json')
    foreach ($unbound in @($onDisk.Keys)) { [void]$problems.Add("bundle carries an unbound file: $unbound") }

    if (-not [bool]$manifest.ready) { [void]$problems.Add('manifest is not marked ready') }
    if ([int]$manifest.launch.boundaryHits -ne 1) { [void]$problems.Add('the exact model boundary was not reached exactly once') }
    foreach ($counter in @($manifest.sideEffects.PSObject.Properties)) {
        if ([int]$counter.Value -ne 0) { [void]$problems.Add("declared side effect '$($counter.Name)' is $($counter.Value), expected 0") }
    }
    if (-not [bool]$manifest.snapshot.nonPromotable) { [void]$problems.Add('the sealed snapshot is not marked non-promotable') }
    if (-not [bool]$manifest.classification.nonPromotable) { [void]$problems.Add('the bundle is not classified non-promotable') }
    if ([bool]$manifest.classification.writesPermitted) { [void]$problems.Add('the bundle claims writes are permitted') }

    # The prompt file must BE the recorded stimulus, byte for byte.
    $promptPath = Join-Path $BundleRoot 'role-input-prompt.txt'
    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) { [void]$problems.Add('the exact prompt bytes are missing') }
    else {
        $promptBytes = [IO.File]::ReadAllBytes($promptPath)
        if ([int]$promptBytes.Length -ne [int]$manifest.promptBytes) { [void]$problems.Add('the recorded prompt byte count disagrees with the prompt file') }
        $promptSha = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($promptBytes))).ToLowerInvariant()
        if ($promptSha -cne [string]$manifest.hashes.inputSha256) { [void]$problems.Add('the recorded prompt SHA-256 disagrees with the prompt file') }
    }
    foreach ($key in @($Expected.Keys)) {
        $actual = switch ($key) {
            'role' { [string]$manifest.role }
            'model' { [string]$manifest.model }
            'prId' { [int]$manifest.identities.prId }
            'snapshotManifestDigest' { [string]$manifest.hashes.snapshotManifestDigest }
            'ref' { [string]$manifest.build.ref }
            'head' { [string]$manifest.build.head }
            default { $null }
        }
        if ("$actual" -cne "$($Expected[$key])") {
            [void]$problems.Add("manifest '$key' is '$actual' but '$($Expected[$key])' was requested")
        }
    }
    return $problems.ToArray()
}

# ---------------------------------------------------------------------------
# Verify-only entry
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Verify') {
    $bundleRoot = [IO.Path]::GetFullPath($OutputRoot)
    if (-not (Test-Path -LiteralPath $bundleRoot -PathType Container)) { throw "The capture bundle '$bundleRoot' does not exist." }
    $sealKey = Get-CaptureSealKey
    $problems = @(Test-CaptureBundle -BundleRoot $bundleRoot -SealKey $sealKey)
    if ($problems.Count -gt 0) {
        Write-Host "FAIL: capture bundle verification found $($problems.Count) problem(s):" -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
        exit 2
    }
    $kind = if (Test-Path -LiteralPath (Join-Path $bundleRoot 'capture-blocked.json') -PathType Leaf) {
        'typed blocker (schema, HMAC/SHA seal, recursive read-only/reparse-free, exact two-file inventory)'
    }
    else { 'capture bundle (schema, HMAC/SHA seal, bound-file hashes/lengths, recursive read-only/reparse-free, one declared boundary hit)' }
    Write-Host "PASS: $kind verified." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Readiness: everything both Preflight and Capture must agree on
# ---------------------------------------------------------------------------

$repoFull = [IO.Path]::GetFullPath($RepoRoot)
$requestFull = Assert-SafePath -Path $CaptureRequestFile -Surface 'The role input capture request'
$configFull = Assert-SafePath -Path $ConfigFile -Surface 'The reviewer configuration'
$replayFull = Assert-SafePath -Path $ReplayRoot -Surface 'The sealed replay root'
$outputFull = Assert-SafePath -Path $OutputRoot -Surface 'The capture output root'
foreach ($required in @($requestFull, $configFull, $ReviewerScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required input '$required' does not exist." }
}
if (-not (Test-Path -LiteralPath $replayFull -PathType Container)) { throw "The sealed replay root '$replayFull' does not exist." }
$candidateFull = ''
if ($CandidateInputFile) { $candidateFull = Assert-SafePath -Path $CandidateInputFile -Surface 'The discovery candidate input' }
$markerFull = ''
if ($DiscoveryMarkerFile) { $markerFull = Assert-SafePath -Path $DiscoveryMarkerFile -Surface 'The discovery result marker' }
$legacyFull = ''
if ($LegacyProjectionFile) { $legacyFull = Assert-SafePath -Path $LegacyProjectionFile -Surface 'The legacy benchmark projection' }

# The verifier cross-checks a candidate produced by an INDEPENDENT run. Without
# one there is nothing to cross-check and the role would have to invent its own
# subject, so the requirement is structural rather than advisory.
if ($Role -ceq 'verifier' -and -not $candidateFull) {
    throw 'A verifier role input capture requires -CandidateInputFile: the cross-check subject must come from an independent capture, never from the verifier itself.'
}
# The verifier's subject must also be traceable to the sealed discovery result it
# was extracted from, so the capture cannot cross-check a candidate that no
# sealed discovery ever produced.
if ($Role -ceq 'verifier' -and -not $markerFull) {
    throw 'A verifier role input capture requires -DiscoveryMarkerFile: the candidate must be traceable to the sealed discovery result marker it came from.'
}
if ($Role -cne 'verifier' -and ($candidateFull -or $markerFull)) {
    throw "A $Role role input capture takes no discovery candidate or marker; those belong to the verifier role alone."
}

$requestText = [IO.File]::ReadAllText($requestFull, $Utf8)
Assert-Schema -Json $requestText -SchemaName 'role-input-capture-request.schema.json' -Surface 'The role input capture request'
$captureRequest = $requestText | ConvertFrom-Json -Depth 64
Assert-NoForbiddenKeys -Node $captureRequest -Surface 'The role input capture request'
if ([string]$captureRequest.role -cne $Role) {
    throw "The capture request declares role '$([string]$captureRequest.role)' but '$Role' was requested."
}
if ([string]$captureRequest.model -cne $Model) {
    throw "The capture request declares model '$([string]$captureRequest.model)' but '$Model' was requested."
}
if ([int]$captureRequest.identity.prId -ne $PullRequestId) {
    throw "The capture request is bound to PR $([int]$captureRequest.identity.prId) but PR $PullRequestId was requested."
}

$layout = Get-GitLayout -RepositoryRoot $repoFull
$refCommit = Resolve-GitRef -Layout $layout -Ref $ExpectedRef
$headCommit = Get-GitHead -Layout $layout
$expectedHead = $ExpectedHeadCommit.ToLowerInvariant()
if ($refCommit -cne $expectedHead) { throw "Ref '$ExpectedRef' resolves to $refCommit, not the declared head $expectedHead." }
if ($headCommit -cne $expectedHead) { throw "HEAD is $headCommit, not the declared head $expectedHead." }

Import-Module $HarnessModule -Force -ErrorAction Stop
$snapshot = New-AgentReplaySnapshot -ReplayRoot $replayFull -SnapshotName $ReplaySnapshotName `
    -ExpectedManifestDigest $ReplayManifestDigest.ToLowerInvariant()
if (-not [bool]$snapshot.Classification.NonPromotable) {
    throw "Replay snapshot '$ReplaySnapshotName' is promotable; a role input capture runs only against a permanently non-promotable sealed snapshot."
}
if ([int]$snapshot.Binding.PullRequestId -ne $PullRequestId) {
    throw "The sealed snapshot is bound to PR $([int]$snapshot.Binding.PullRequestId) but PR $PullRequestId was requested."
}
if ([string]$captureRequest.snapshot.name -cne $ReplaySnapshotName -or
    ([string]$captureRequest.snapshot.manifestDigest).ToLowerInvariant() -cne $ReplayManifestDigest.ToLowerInvariant()) {
    throw 'The capture request snapshot identity does not match the selected replay snapshot.'
}
$precheckedConfigObject = [IO.File]::ReadAllText($configFull, $Utf8) | ConvertFrom-Json -Depth 64
Assert-NoForbiddenKeys -Node $precheckedConfigObject -Surface 'The reviewer configuration'
if (([string]$captureRequest.snapshot.configSha256).ToLowerInvariant() -cne (Get-FileSha256Hex -Path $configFull)) {
    throw 'The capture request configSha256 does not match the selected reviewer configuration.'
}
foreach ($pair in @(
        @('repositoryId', [string]$captureRequest.identity.repositoryId, [string]$snapshot.Binding.RepositoryId),
        @('project', [string]$captureRequest.identity.project, [string]$snapshot.Binding.Project),
        @('organization', [string]$captureRequest.identity.organization, [string]$snapshot.Binding.Organization),
        @('source', [string]$captureRequest.identity.source, [string]$snapshot.Binding.SourceCommit),
        @('target', [string]$captureRequest.identity.target, [string]$snapshot.Binding.TargetCommit),
        @('changeSet', [string]$captureRequest.identity.changeSet, [string]$snapshot.Binding.ChangeSetSha256))) {
    if (([string]$pair[1]).ToLowerInvariant() -cne ([string]$pair[2]).ToLowerInvariant()) {
        throw "The capture request $($pair[0]) does not match the sealed replay snapshot."
    }
}
if ($snapshot.Binding.Contains('CommonCommit') -and
    ([string]$captureRequest.identity.common).ToLowerInvariant() -cne ([string]$snapshot.Binding.CommonCommit).ToLowerInvariant()) {
    throw 'The capture request common does not match the sealed replay snapshot.'
}
if ($snapshot.Binding.Contains('IterationId') -and
    [int]$captureRequest.identity.iteration -ne [int]$snapshot.Binding.IterationId) {
    throw 'The capture request iteration does not match the sealed replay snapshot.'
}
if (@($snapshot.Bindings.Models) -cnotcontains $Model) {
    throw "Model '$Model' is not among the models the sealed snapshot was captured for."
}

# The reviewer configuration is the third identity the capture is bound to, next
# to the request and the sealed snapshot. It is operator-supplied and is NOT
# covered by a fixture schema, so it gets its own recursive oracle key scan, and
# its repository identity must match the snapshot the stimulus was sealed from.
# Capturing role input for one repository out of another repository's config
# would silently produce a prompt no production run could ever have issued.
$configObject = [IO.File]::ReadAllText($configFull, $Utf8) | ConvertFrom-Json -Depth 64
Assert-NoForbiddenKeys -Node $configObject -Surface 'The reviewer configuration'
$configRepositoryId = ''
if ($configObject.PSObject.Properties.Name -ccontains 'repository' -and
    $configObject.repository.PSObject.Properties.Name -ccontains 'id') {
    $configRepositoryId = [string]$configObject.repository.id
}
$snapshotRepositoryId = [string]$snapshot.Binding.RepositoryId
if ($configRepositoryId -and $snapshotRepositoryId -and $configRepositoryId -cne $snapshotRepositoryId) {
    throw "The reviewer configuration is bound to repository '$configRepositoryId' but the sealed snapshot is bound to '$snapshotRepositoryId'."
}

$readiness = [ordered]@{
    schemaVersion  = 1
    kind           = 'reviewer-role-input-capture-readiness'
    ready          = $true
    role           = $Role
    model          = $Model
    prId           = $PullRequestId
    fixtureId      = [string]$captureRequest.fixtureId
    snapshot       = [ordered]@{
        name           = $ReplaySnapshotName
        manifestDigest = $ReplayManifestDigest.ToLowerInvariant()
        nonPromotable  = $true
        sealKind       = [string]$snapshot.Classification.SealKind
        resourceCount  = [int]$snapshot.ResourceCount
    }
    build          = [ordered]@{ repoRoot = $repoFull; head = $expectedHead; ref = $ExpectedRef }
    classification = [ordered]@{ private = $true; oracleFree = $true; nonPromotable = $true; writesPermitted = $false }
    sideEffects    = [ordered]@{
        outputRootsCreated = 0; leasesCreated = 0; planFilesCreated = 0; tokensMinted = 0
        processesStarted   = 0; modelsStarted = 0; providerReads = 0; providerWrites = 0
    }
}

if ($Preflight) {
    [void](Get-CaptureSealKey)
    Write-Output (($readiness | ConvertTo-Json -Depth 32 -Compress))
    exit 0
}

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

$outputParent = [IO.Path]::GetDirectoryName($outputFull)
if (-not $outputParent -or -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "The capture output root's parent directory must already exist."
}
$outputLockPath = Join-Path $outputParent ('.' + [IO.Path]::GetFileName($outputFull) + '.capture.lock')
$outputLock = $null
try {
    $outputLock = [IO.FileStream]::new(
        $outputLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
}
catch [IO.IOException] {
    throw "The capture output lock '$outputLockPath' is already held; another capture for this output is in progress."
}

try {
if (Test-Path -LiteralPath $outputFull) { throw "The capture output root '$outputFull' already exists; a capture never overwrites." }
$captureSealKey = Get-CaptureSealKey -Create

$runId = [Guid]::NewGuid().ToString('N')
$workRoot = Join-Path $outputParent ('.' + [IO.Path]::GetFileName($outputFull) + ".capture-work-$runId")
New-Item -ItemType Directory -Path $workRoot | Out-Null
$publicationStaging = Join-Path $outputParent ('.' + [IO.Path]::GetFileName($outputFull) + ".capture-staging-$runId")
$telemetryPath = Join-Path $workRoot 'telemetry.jsonl'
$stdOutPath = Join-Path $workRoot 'child.stdout.log'
$stdErrPath = Join-Path $workRoot 'child.stderr.log'
$stateDir = Join-Path $workRoot 'state'

$reviewerArgs = @(
    '-NoProfile', '-File', $ReviewerScript,
    '-Once', '-RepoPath', $repoFull,
    '-ConfigFile', $configFull, '-StateDir', $stateDir,
    '-OperatorAlias', 'role-input-capture', '-PullRequestId', "$PullRequestId",
    '-Model', $Model, '-CycleTimeoutSeconds', "$TimeoutSeconds",
    '-ReplayRoot', $replayFull, '-ReplaySnapshotName', $ReplaySnapshotName,
    '-ReplayManifestDigest', $ReplayManifestDigest.ToLowerInvariant(),
    '-CaptureRoleInputRole', $Role, '-CaptureRoleInputModel', $Model,
    '-CaptureRoleInputOutputRoot', $publicationStaging,
    '-CaptureRoleInputExpectedRef', $ExpectedRef,
    '-CaptureRoleInputExpectedHeadCommit', $expectedHead,
    '-CaptureRoleInputRequestFile', $requestFull
)
if ($legacyFull) { $reviewerArgs += @('-CaptureRoleInputLegacyProjectionFile', $legacyFull) }
if ($Role -cne 'generalist') {
    if (-not $SecondGeneralistModel) { throw "A $Role role input capture requires -SecondGeneralistModel (the second configured generalist model)." }
    if (-not $ConventionSpecialistModel) { throw "A $Role role input capture requires -ConventionSpecialistModel (the configured convention specialist model)." }
    $reviewerArgs += @(
        '-SecondPassModel', $SecondGeneralistModel,
        '-EnableConventionSpecialist', '-ConventionSpecialistModel', $ConventionSpecialistModel,
        '-ConventionSpecialistTimeoutSeconds', "$TimeoutSeconds"
    )
}
if ($Role -ceq 'verifier') {
    $reviewerArgs += @(
        '-EnableVerificationPreview', '-ConventionVerifierModel', $Model,
        '-VerificationTimeoutSeconds', "$TimeoutSeconds",
        '-AcquisitionCandidateInputFile', $candidateFull
    )
    if ($markerFull) { $reviewerArgs += @('-AcquisitionDiscoveryMarkerFile', $markerFull) }
}

$removedEnvironment = @{}
$savedTelemetryMode = $env:DEVPILOT_OFFLINE_TELEMETRY_MODE
$savedTelemetryPath = $env:DEVPILOT_OFFLINE_TELEMETRY_PATH
$childExitCode = -1
$supervision = $null
try {
    foreach ($name in $SensitiveEnvironmentVariables) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $value) { $removedEnvironment[$name] = $value; [Environment]::SetEnvironmentVariable($name, $null) }
    }
    # The offline telemetry sink is wired through the environment rather than
    # through -OfflineTelemetryPath, because passing that switch would request
    # the offline model ADAPTER - and a capture refuses an adapter outright:
    # there is no subprocess to stub when nothing is ever launched.
    $env:DEVPILOT_OFFLINE_TELEMETRY_MODE = 'production-test-only'
    $env:DEVPILOT_OFFLINE_TELEMETRY_PATH = $telemetryPath

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $proc = Start-Process -FilePath $pwshPath -ArgumentList $reviewerArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdOutPath -RedirectStandardError $stdErrPath
    $startedUtc = [DateTime]::UtcNow
    $deadline = $startedUtc.AddSeconds($TimeoutSeconds)
    $lastActivityUtc = $startedUtc
    $lastLength = -1L
    $timedOut = $false
    while ($true) {
        if ($proc.WaitForExit(250)) { break }
        $nowUtc = [DateTime]::UtcNow
        if ($nowUtc -ge $deadline) { $timedOut = $true; break }
        $currentLength = 0L
        foreach ($p in @($stdOutPath, $stdErrPath)) {
            if (Test-Path -LiteralPath $p) { $currentLength += [int64](Get-Item -LiteralPath $p).Length }
        }
        if ($currentLength -ne $lastLength) { $lastLength = $currentLength; $lastActivityUtc = $nowUtc }
        elseif (($nowUtc - $lastActivityUtc).TotalSeconds -ge $ActivityTimeoutSeconds) { $timedOut = $true; break }
    }
    if ($timedOut) {
        try { Stop-ProcessTree -Process $proc } catch { }
        [void]$proc.WaitForExit(5000)
    }
    else { try { $childExitCode = [int]$proc.ExitCode } catch { $childExitCode = -1 } }
    $supervision = [ordered]@{
        exitCode   = $childExitCode
        timedOut   = $timedOut
        startedUtc = $startedUtc.ToString('o')
        endedUtc   = [DateTime]::UtcNow.ToString('o')
    }
}
finally {
    foreach ($name in $removedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $removedEnvironment[$name]) }
    $env:DEVPILOT_OFFLINE_TELEMETRY_MODE = $savedTelemetryMode
    $env:DEVPILOT_OFFLINE_TELEMETRY_PATH = $savedTelemetryPath
}

$telemetryFailure = ''
try { $telemetry = Get-TelemetryProof -TelemetryPath $telemetryPath }
catch {
    $telemetryFailure = [string]$_.Exception.Message
    $telemetry = [ordered]@{
        fileExists = [bool](Test-Path -LiteralPath $telemetryPath -PathType Leaf)
        parseError = ''
        proofError = $telemetryFailure
        totalEvents = 0
        sealedReplayServes = 0
        childProcessStarts = 0
        modelOrAgencyStarts = 0
        providerLiveProcessStarts = 0
        providerLiveWrites = 0
        writeToolInvocations = 0
    }
}
$telemetryComplete = ($telemetry.fileExists -and -not $telemetry.parseError -and -not $telemetry.proofError -and
    $telemetry.totalEvents -gt 0 -and $telemetry.sealedReplayServes -gt 0)
$telemetryShowsNoSideEffects = ($telemetry.childProcessStarts -eq 0 -and $telemetry.modelOrAgencyStarts -eq 0 -and
    $telemetry.providerLiveProcessStarts -eq 0 -and $telemetry.providerLiveWrites -eq 0 -and
    $telemetry.writeToolInvocations -eq 0)
$zeroProcessProven = ($telemetryComplete -and $telemetryShowsNoSideEffects)

$childStdErr = if (Test-Path -LiteralPath $stdErrPath) { [IO.File]::ReadAllText($stdErrPath, $Utf8).Trim() } else { '' }
$captured = ($childExitCode -eq 0)
$problems = @()
if ($telemetryFailure) {
    $problems = @($problems) + @($telemetryFailure)
}
if (-not $telemetryShowsNoSideEffects) {
    $problems = @($problems) + @("telemetry proves a side effect occurred: $(($telemetry.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')")
}
$published = $false
try {
    if ($zeroProcessProven -and (Test-Path -LiteralPath $publicationStaging -PathType Container)) {
        $signedFile = if (Test-Path -LiteralPath (Join-Path $publicationStaging 'capture-manifest.json') -PathType Leaf) {
            'capture-manifest.json'
        }
        elseif (Test-Path -LiteralPath (Join-Path $publicationStaging 'capture-blocked.json') -PathType Leaf) {
            'capture-blocked.json'
        }
        else { '' }
        if (-not $signedFile) {
            $problems = @($problems) + @('the child publication carries neither a capture manifest nor a typed blocker')
        }
        else {
            Write-CaptureSeal -BundleRoot $publicationStaging -SignedFile $signedFile -Key $captureSealKey
            $expected = if ($captured) {
                @{
                    role = $Role; model = $Model; prId = $PullRequestId
                    snapshotManifestDigest = $ReplayManifestDigest.ToLowerInvariant()
                    ref = $ExpectedRef; head = $expectedHead
                }
            }
            else { @{} }
            $problems = @($problems) + @(Test-CaptureBundle -BundleRoot $publicationStaging -SealKey $captureSealKey -Expected $expected)
            if ($problems.Count -eq 0) {
                if (Test-Path -LiteralPath $outputFull) {
                    $problems = @($problems) + @("the capture output root '$outputFull' appeared during publication; it was not overwritten")
                }
                else {
                    [IO.Directory]::Move($publicationStaging, $outputFull)
                    $published = $true
                }
            }
        }
    }
    elseif ($captured) {
        $problems = @($problems) + @('the child reported success but published no staging bundle')
    }
}
finally {
    if (-not $published -and (Test-Path -LiteralPath $publicationStaging)) {
        Get-ChildItem -LiteralPath $publicationStaging -File -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Attributes = [IO.FileAttributes]::Normal } catch { } }
        Remove-Item -LiteralPath $publicationStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$result = [ordered]@{
    schemaVersion   = 1
    kind            = 'reviewer-role-input-capture-result'
    ready           = ($captured -and $problems.Count -eq 0)
    role            = $Role
    model           = $Model
    outputRoot      = $outputFull
    supervision     = $supervision
    telemetry       = $telemetry
    zeroSideEffects = $zeroProcessProven
    problems        = @($problems)
}
Write-Output (($result | ConvertTo-Json -Depth 32 -Compress))
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    if ($childStdErr) { Write-Host "  $childStdErr" -ForegroundColor Red }
    exit 2
}
if (-not $captured) {
    $blockerPath = Join-Path $outputFull 'capture-blocked.json'
    if (Test-Path -LiteralPath $blockerPath -PathType Leaf) {
        Write-Host "Role input capture did not reach the model boundary (child exit $childExitCode); a typed blocker was published to $blockerPath." -ForegroundColor Yellow
    }
    else {
        # The run failed a gate BEFORE the capture driver could publish anything,
        # so there is deliberately no bundle at all: a refused capture leaves the
        # filesystem exactly as it found it rather than a half-written record.
        Write-Host "Role input capture was refused before it could publish anything (child exit $childExitCode); no bundle exists at $outputFull." -ForegroundColor Yellow
    }
    if ($childStdErr) { Write-Host "  $childStdErr" -ForegroundColor Yellow }
    exit 3
}
Write-Host "Role input capture verified: role=$Role model=$Model, zero model/agency/provider processes, zero live reads or writes." -ForegroundColor Green
exit 0
}
finally {
    if ($null -ne $outputLock) { $outputLock.Dispose() }
}
