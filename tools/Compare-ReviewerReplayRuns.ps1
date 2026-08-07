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
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$ArtifactPath,
    [Parameter(Mandatory)][string]$KeyPath,
    [string]$OutputDirectory = "",
    [ValidateRange(2, 16)][int]$RequiredRunCount = 2,
    [switch]$FailOnDisagreement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$reviewerRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "src\Agents\reviewer"
. (Join-Path $reviewerRoot "ConventionSpecialist.ps1")
. (Join-Path $reviewerRoot "RunReconciliation.ps1")

if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
    throw "Artifact signing key '$KeyPath' does not exist."
}
$master = [IO.File]::ReadAllBytes($KeyPath)
if ($master.Length -lt 32) { throw "Artifact signing key is too short." }

# Replay artifacts are sealed under a derived key precisely so they cannot
# verify against the promotion path. Derive the same label here; a manifest that
# only verifies under the RAW key is a live-run artifact and has no business in
# a replay reconciliation.
$hmac = [System.Security.Cryptography.HMACSHA256]::new($master)
try {
    $replayKey = $hmac.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes("devpilot.reviewer.replay.artifact.v1"))
}
finally { $hmac.Dispose() }

$manifests = @()
foreach ($path in @($ArtifactPath)) {
    $resolved = (Resolve-Path -LiteralPath $path).ProviderPath
    $manifest = Read-ReviewerConventionSpecialistPreview -Path $resolved -MasterKey $replayKey
    $replay = $manifest.PSObject.Properties["replay"]
    if ($null -eq $replay -or $null -eq $replay.Value) {
        throw "Artifact '$resolved' is not a replay artifact; live-run artifacts are not reconciled here."
    }
    $manifests += $manifest
}

$reconciliation = Resolve-ReviewerRunReconciliation -Manifests $manifests -RequiredRunCount $RequiredRunCount
$report = Format-ReviewerRunReconciliationReport -Reconciliation $reconciliation

if ($OutputDirectory) {
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
    }
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $reportPath = Join-Path $OutputDirectory "reconciliation-$stamp.md"
    [IO.File]::WriteAllText($reportPath, $report, [Text.UTF8Encoding]::new($false))
    # Sealed under the replay key, so this artifact is as unpromotable as the
    # runs that fed it.
    $sealed = Save-ReviewerConventionSpecialistPreview -Directory $OutputDirectory `
        -BaseName "reconciliation-$stamp" -Manifest ([pscustomobject][ordered]@{
            kind = $script:ReviewerConventionSpecialistArtifactKind
            artifactVersion = $script:ReviewerConventionSpecialistArtifactVersion
            status = "ok"
            reconciliation = $reconciliation
            reportPath = $reportPath
            reportSha256 = Get-ReviewerConventionSpecialistSha256 -Text $report
            promotable = $false
            createdAt = [DateTime]::UtcNow.ToString("o")
        }) -MasterKey $replayKey
    Write-Host "Reconciliation report: $reportPath" -ForegroundColor DarkCyan
    Write-Host "Sealed (non-promotable): $sealed" -ForegroundColor DarkCyan
}

Write-Output $report

if ($FailOnDisagreement -and -not [bool]$reconciliation.reconciled) { exit 2 }
if ($FailOnDisagreement -and [int]$reconciliation.unstableRowCount -gt 0) { exit 3 }
exit 0
