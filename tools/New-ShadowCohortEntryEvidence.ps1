#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds one immutable typed cohort-entry evidence package from one versioned
    operator request, with no model launch and no provider write.

.DESCRIPTION
    This tool is deliberately thin. Every rule it enforces lives in the reviewed
    surfaces under src/Agents/reviewer, where the meaning of a wrapper-contract
    response, an ordinal census and a corpus envelope already lives; a second
    copy of any of those rules here would be a second thing to keep in step, and
    keeping two copies in step by hand is the class of defect this whole
    deliverable exists to remove.

    What this tool adds is the operator seam: it resolves the request path, runs
    the build, maps a catalogued refusal onto a stable process exit code, and
    prints one machine-readable summary line so an operator's own automation can
    read what was produced without parsing prose.

    IT LAUNCHES NO MODEL. With -Preflight it starts the typed coordinator over
    the published request and drives it to a preparation state only, refusing if
    any launch intent names a slot or an expected terminal artifact.

.PARAMETER RequestPath
    The versioned operator request, validated against
    src/Agents/reviewer/schemas/reviewer.cohort-entry-evidence-request.v1.json, or
    ...-request.v2.json when it carries an executionPlan.

.PARAMETER Preflight
    Additionally drive the typed coordinator over the published request, proving
    the typed reader accepts the entry with zero slots, zero models and zero
    launch tokens consumed.

.PARAMETER PreflightTarget
    How far the typed preflight is driven. Defaults to recipePlanned, which is
    the furthest preparation state a cohort-entry package reaches FROM ITS OWN
    INPUTS: the next state, snapshotValidateOnly, additionally requires an
    offline corpus seal recipe, which is a separate producer this builder does
    not emit. Pass runSetReady only when an operator has supplied that recipe.

.PARAMETER BoundArtifactPath
    A model-start bound derived earlier by tools/New-ShadowModelStartBound.ps1,
    stated as the answer this build is expected to reach. It does NOT stand in
    for the derivation: the producer runs either way, what gets published is
    always what this build derived, and the supplied file has to state the same
    kind, request digest, toolkit head, slot count and maxima. Anything else is
    refused (CE714), including a build whose toolkit ships no producer to agree
    with. Supplying a bound proves a build reproduces a number; it never
    asserts one.

.PARAMETER VerifyOnly
    Do not build. Re-verify an already published package at the request's output
    root: every inventoried file present at its recorded digest and length,
    read-only, and authenticated under the request's seal key.

.OUTPUTS
    One JSON summary line on stdout. Exit codes:
      0  the package was published (and, with -Preflight, reached its target)
      1  the tool was used incorrectly
      2  the request does not satisfy its contract          (CE1xx)
      3  the subject identity is inadmissible or drifted    (CE2xx)
      4  the evidence capture is not exact                  (CE3xx)
      5  the census or coverage is not admissible           (CE4xx)
      6  the package could not be published or re-verified  (CE5xx)
      7  the typed preflight did not reach its target       (CE6xx)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [switch]$Preflight,
    [ValidateSet('requestValidated', 'corpusValidated', 'recipePlanned', 'snapshotValidateOnly',
        'snapshotVerified', 'runSetReady')]
    [string]$PreflightTarget = 'snapshotVerified',
    [string]$BoundArtifactPath = '',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1') -Force
. (Join-Path $repoRoot 'src/Agents/reviewer/CohortEntryBuilder.ps1')

function Get-CohortEntryExitCode {
    <#
    .SYNOPSIS
        The process exit code one catalogued refusal maps to.

    .DESCRIPTION
        Grouped by the refusal's hundreds digit rather than given one code per
        condition, because a process exit code is one byte and the catalogue is
        not. The exact condition is always in the message; the exit code only has
        to tell an operator's automation WHICH STAGE refused, so it can decide
        whether to fix a request, wait for a pull request to settle, or re-record
        a snapshot.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Code)
    switch -CaseSensitive -Regex ($Code) {
        '^CE1' { return 2 }
        '^CE2' { return 3 }
        '^CE3' { return 4 }
        '^CE4' { return 5 }
        '^CE5' { return 6 }
        '^CE6' { return 7 }
        '^CE7' { return 8 }
        '^CE8' { return 9 }
    }
    return 1
}

try {
    $full = [IO.Path]::GetFullPath($RequestPath)
    if ($VerifyOnly) {
        $request = Read-ReviewerCohortEntryRequest -Path $full
        [void](Assert-ReviewerCohortEntryPublished -Root $request.OutputRoot -SealKeyPath $request.SealKeyPath)
        Write-Output (ConvertTo-Json -Depth 6 -Compress -InputObject ([ordered]@{
                    verified = $true
                    root = $request.OutputRoot
                    entryId = $request.EntryId
                    modelStarts = 0
                    providerWrites = 0
                }))
        exit 0
    }

    $result = New-ReviewerCohortEntryEvidence -RequestPath $full -Preflight:$Preflight `
        -PreflightTarget $PreflightTarget -BoundArtifactPath $BoundArtifactPath
    Write-Output (ConvertTo-Json -Depth 6 -Compress -InputObject ([ordered]@{
                published = $true
                root = $result.Root
                entryId = $result.EntryId
                ordinal = $result.Ordinal
                pullRequestId = $result.PullRequestId
                iterationId = $result.IterationId
                sourceCommit = $result.SourceCommit
                commonCommit = $result.CommonCommit
                targetCommit = $result.TargetCommit
                censusCount = $result.CensusCount
                readCount = $result.ReadCount
                coveragePercent = $result.CoveragePercent
                corpusIndexSha256 = $result.CorpusIndexSha256
                coordinatorRequestSha256 = $result.CoordinatorRequestSha256
                modelStarts = $result.ModelStarts
                providerWrites = $result.ProviderWrites
                preflightState = $result.PreflightState
                modelStartBoundKind = $result.ModelStartBoundKind
                maxRealModelStarts = $result.MaxRealModelStarts
                maxVerifierAssignments = $result.MaxVerifierAssignments
            }))
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    $code = Get-ReviewerCohortEntryErrorCode -Message $message
    Write-Error $message
    exit (Get-CohortEntryExitCode -Code $code)
}
