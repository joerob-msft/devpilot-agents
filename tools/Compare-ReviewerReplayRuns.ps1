<#
.SYNOPSIS
    Compares several replay runs of the same frozen input and reports only what
    they agree on.

.DESCRIPTION
    A replay is deterministic in its inputs and not in its model. Run the same
    snapshot twice and the specialist may word a rule differently, or read an
    anchor differently, and either run on its own looks like a result.

    This reads the sealed specialist artifacts from two or more such runs and
    collapses them. Anything the runs disagree about becomes `unknown`, and any
    candidate comment that not every run proposed is withheld. There is no
    majority vote and no tie-break: disagreement is the answer.

    The output is an evaluation artifact. It is sealed under the replay key, so
    it can never verify against the promotion path, and it says so in its own
    text.

.EXAMPLE
    ./tools/Compare-ReviewerReplayRuns.ps1 -ArtifactPath run1.json, run2.json `
        -KeyPath ~/.devpilot/state/artifact-signing.key -OutputDirectory ./out
#>
[CmdletBinding(DefaultParameterSetName = "Compare")]
param(
    [Parameter(Mandatory, ParameterSetName = "Compare")][string[]]$ArtifactPath,
    [Parameter(Mandatory)][string[]]$KeyPath,
    [Parameter(Mandatory, ParameterSetName = "Declare")][switch]$DeclareRunSet,
    [Parameter(Mandatory, ParameterSetName = "Declare")][string]$SnapshotName,
    [Parameter(Mandatory, ParameterSetName = "Declare")]
    [ValidatePattern('^[0-9a-fA-F]{64}\z')][string]$SnapshotManifestDigest,
    [Parameter(ParameterSetName = "Declare")][ValidateRange(2, 16)][int]$PlannedRunCount = 2,
    [Parameter(ParameterSetName = "Declare")][string]$Purpose = "",
    [string]$RunSetPath = "",
    [string]$OutputDirectory = "",
    [ValidateRange(2, 16)][int]$RequiredRunCount = 2,
    [switch]$FailOnDisagreement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$reviewerRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "src\Agents\reviewer"
. (Join-Path $reviewerRoot "ConventionSpecialist.ps1")
. (Join-Path $reviewerRoot "RunReconciliation.ps1")

function Get-ReviewerReplayRunMasterKey {
    <#
        Reads a signing key the reviewer already created.

        Deliberately read-only. The reviewer's own reader mints a key when the
        file is absent; here that would be silently wrong - a reconciliation
        against a freshly-invented key verifies nothing, and would fail with a
        signature error that reads like tampering instead of "you pointed at
        the wrong state directory".
    #>
    param([Parameter(Mandatory)][string]$Path)
    # A signing key is 32 bytes plus a short format prefix. Reading an operator
    # typo that happens to be a gigabyte is nobody''s idea of a good time.
    $info = Get-Item -LiteralPath $Path
    if ($info.Length -gt 8192) { throw "The signing key at $Path is $($info.Length) bytes; a key file is a single short line." }
    $line = ([IO.File]::ReadAllText($Path)).Trim()
    $format = $(if ($IsWindows) { "dpapi" } else { "raw" })
    $separator = $line.IndexOf(":")
    if ($separator -gt 0) {
        $format = $line.Substring(0, $separator)
        $line = $line.Substring($separator + 1)
    }
    $stored = [Convert]::FromBase64String($line)
    switch ($format) {
        "raw" { return , $stored }
        "dpapi" {
            try {
                return , [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $stored, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            }
            catch { throw "The signing key at $Path could not be decrypted for this user: $($_.Exception.Message)" }
        }
        default { throw "The signing key at $Path declares an unknown storage format '$format'." }
    }
}

# One key for all runs, or one per run in the same order. Repeats are naturally
# run in isolated state directories - that is what keeps them independent - and
# each of those mints its own signing key, so insisting on a single key would
# mean either sharing state between runs or not comparing them at all.
$keyPaths = @($KeyPath)
if ($keyPaths.Count -ne 1 -and $keyPaths.Count -ne @($ArtifactPath).Count) {
    throw "Supply one -KeyPath for all runs, or exactly one per -ArtifactPath (got $($keyPaths.Count) keys for $(@($ArtifactPath).Count) artifacts)."
}

$replayKeys = @()
foreach ($path in $keyPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Artifact signing key '$path' does not exist."
    }
    $master = Get-ReviewerReplayRunMasterKey -Path (Resolve-Path -LiteralPath $path).ProviderPath
    if ($master.Length -lt 32) { throw "Artifact signing key '$path' is too short." }
    # Replay artifacts are sealed under a derived key precisely so they cannot
    # verify against the promotion path. Derive the same label here; a manifest
    # that only verifies under the RAW key is a live-run artifact and has no
    # business in a replay reconciliation.
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($master)
    try {
        $replayKeys += , $hmac.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes("devpilot.reviewer.replay.artifact.v1"))
    }
    finally { $hmac.Dispose() }
}

$manifests = @()
$index = 0
$declaredRuns = [System.Collections.Generic.List[object]]::new()

# The qualification set is declared BEFORE the runs exist, and sealed. That is
# the whole point: an operator who picks which runs to compare after seeing
# their results has not reconciled anything, they have chosen an answer. The
# declaration fixes the snapshot, the digest and how many runs will count, and
# the comparison below refuses anything that does not match it.
if ($DeclareRunSet) {
    if (-not $OutputDirectory) { throw "-DeclareRunSet requires -OutputDirectory to write the sealed declaration into." }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -LiteralPath $OutputDirectory -Force)
    }
    $setId = [Guid]::NewGuid().ToString("N")
    $declaration = [pscustomobject][ordered]@{
        kind = $script:ReviewerRunReconciliationSetKind
        artifactVersion = $script:ReviewerRunReconciliationVersion
        status = "ok"
        setId = $setId
        snapshotName = $SnapshotName
        snapshotManifestDigest = $SnapshotManifestDigest.ToLowerInvariant()
        plannedRunCount = $PlannedRunCount
        purpose = $Purpose
        promotable = $false
        declaredAt = [DateTime]::UtcNow.ToString("o")
    }
    $path = Save-ReviewerConventionSpecialistPreview -Directory $OutputDirectory `
        -BaseName "runset-$setId" -Manifest $declaration -MasterKey $replayKeys[0]
    Write-Host "Declared qualification run set $setId for snapshot '$SnapshotName' ($PlannedRunCount runs)." -ForegroundColor DarkCyan
    Write-Host "Sealed declaration: $path" -ForegroundColor DarkCyan
    Write-Output $path
    exit 0
}

# Consuming a declaration: the snapshot and digest each run replayed must be
# the ones that were named in advance, and there must be as many runs as were
# planned. Fewer is a set somebody trimmed; more is a set somebody topped up.
$runSet = $null
if ($RunSetPath) {
    $runSet = Read-ReviewerRunReconciliationSet -Path (Resolve-Path -LiteralPath $RunSetPath).ProviderPath -MasterKey $replayKeys[0]
    if (@($ArtifactPath).Count -ne [int]$runSet.plannedRunCount) {
        throw ("The declared run set $($runSet.setId) planned $([int]$runSet.plannedRunCount) run(s) but " +
            "$(@($ArtifactPath).Count) artifact(s) were supplied. A set chosen after the fact is not a qualification.")
    }
    $RequiredRunCount = [int]$runSet.plannedRunCount
}

foreach ($path in @($ArtifactPath)) {
    $resolved = (Resolve-Path -LiteralPath $path).ProviderPath
    $key = $(if ($replayKeys.Count -eq 1) { $replayKeys[0] } else { $replayKeys[$index] })
    $manifest = Read-ReviewerConventionSpecialistPreview -Path $resolved -MasterKey $key
    $replay = $manifest.PSObject.Properties["replay"]
    if ($null -eq $replay -or $null -eq $replay.Value) {
        throw "Artifact '$resolved' is not a replay artifact; live-run artifacts are not reconciled here."
    }
    if ($null -ne $runSet) {
        if ([string]$replay.Value.snapshotId -cne [string]$runSet.snapshotName -or
            [string]$replay.Value.manifestDigest -cne [string]$runSet.snapshotManifestDigest) {
            throw ("Artifact '$([IO.Path]::GetFileName($resolved))' replayed snapshot " +
                "'$($replay.Value.snapshotId)' at digest $($replay.Value.manifestDigest), which is not the " +
                "'$($runSet.snapshotName)' at $($runSet.snapshotManifestDigest) this run set declared.")
        }
    }
    # The run set is declared, not discovered. Every artifact that went in is
    # recorded by name, nonce and file hash, so a reader can tell whether the
    # comparison covered the runs it should have - rather than trusting that
    # nobody quietly left out the one that disagreed.
    [void]$declaredRuns.Add([pscustomobject][ordered]@{
            run = $declaredRuns.Count + 1
            artifactName = [IO.Path]::GetFileName($resolved)
            artifactSha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
            replayNonce = [string]$replay.Value.replayNonce
        })
    $manifests += $manifest
    $index++
}

$reconciliation = Resolve-ReviewerRunReconciliation -Manifests $manifests -RequiredRunCount $RequiredRunCount
# The declared run set goes in the report, so a reader can see which runs the
# comparison actually covered rather than trusting that nobody quietly dropped
# the one that disagreed.
$setLines = @("", "## Declared run set", "")
if ($null -ne $runSet) {
    $setLines += "Predeclared set $($runSet.setId), sealed $($runSet.declaredAt): snapshot '$($runSet.snapshotName)' at $($runSet.snapshotManifestDigest), $([int]$runSet.plannedRunCount) run(s)."
    $setLines += ""
}
else { $setLines += "No predeclared set; these runs were chosen by the operator at comparison time."; $setLines += "" }
foreach ($declared in @($declaredRuns.ToArray())) {
    $setLines += "- run $($declared.run): $($declared.artifactName) nonce $($declared.replayNonce) sha256 $($declared.artifactSha256)"
}
$report = (Format-ReviewerRunReconciliationReport -Reconciliation $reconciliation) -replace "`r`n", "`n"
$insertAt = $report.IndexOf("`n## Rules", [StringComparison]::Ordinal)
if ($insertAt -ge 0) { $report = $report.Substring(0, $insertAt) + "`n" + ($setLines -join "`n") + $report.Substring($insertAt) }
else { $report = $report + "`n" + ($setLines -join "`n") }

if ($OutputDirectory) {
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -LiteralPath $OutputDirectory -Force)
    }
    # Seconds alone collide when two comparisons run back to back, and the
    # second silently overwrites the first''s report.
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $reportPath = Join-Path $OutputDirectory "reconciliation-$stamp.md"
    [IO.File]::WriteAllText($reportPath, $report, [Text.UTF8Encoding]::new($false))
    # Sealed under the replay key, so this artifact is as unpromotable as the
    # runs that fed it.
    $sealed = Save-ReviewerConventionSpecialistPreview -Directory $OutputDirectory `
        -BaseName "reconciliation-$stamp" -Manifest ([pscustomobject][ordered]@{
            # Its own kind. Reusing the specialist preview's kind would make
            # this artifact byte-for-byte a valid run artifact if the operator
            # pointed -OutputDirectory at the previews directory.
            kind = $script:ReviewerRunReconciliationKind
            artifactVersion = $script:ReviewerRunReconciliationVersion
            status = "ok"
            reconciliation = $reconciliation
            declaredRunSet = @($declaredRuns.ToArray())
            reportPath = $reportPath
            reportSha256 = Get-ReviewerConventionSpecialistSha256 -Text $report
            promotable = $false
            createdAt = [DateTime]::UtcNow.ToString("o")
        }) -MasterKey $replayKeys[0]
    Write-Host "Reconciliation report: $reportPath" -ForegroundColor DarkCyan
    Write-Host "Sealed (non-promotable): $sealed" -ForegroundColor DarkCyan
}

Write-Output $report

if ($FailOnDisagreement) {
    if (-not [bool]$reconciliation.reconciled) { exit 2 }
    if ([int]$reconciliation.unstableRowCount -gt 0) { exit 3 }
    # A candidate only some runs proposed is disagreement too, and it is the
    # kind an operator most wants a non-zero exit for: every row can be stable
    # while the comment the reviewer would have posted appeared in one run.
    if ([int]$reconciliation.agreedCandidateCount -ne @($reconciliation.candidates).Count) { exit 4 }
}
exit 0
