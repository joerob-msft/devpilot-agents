#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Derives the most model subprocess starts one sealed shadow-run request could
    make, and seals that bound to the request it was taken over.

.DESCRIPTION
    A cohort declares a global model-start ceiling before it launches anything.
    For that ceiling to mean something, the estimate it is checked against has to
    be an UPPER BOUND on what an entry can really spend - not a guess, and not a
    figure copied from what a quiet run happened to cost last time.

    This tool computes that bound on the reviewed side, where the meaning of a
    reviewer argument vector lives. The typed cohort runner never interprets one:
    it verifies this artifact's digest, verifies that the artifact was taken over
    the same sealed request the entry pins, and refuses to admit the entry unless
    the operator's declared estimate is at least the bound published here. So the
    model semantics stay on this side of the line and the arithmetic stays on
    that one.

    WHAT THE BOUND IS TAKEN OVER. The request's own pinned reviewer config and
    its declared slots, and nothing else that could have changed since:

      - the config file is re-hashed and must equal the digest the request pins,
        so the verification switch read here is the one the request sealed;
      - each declared slot's argument vector is built by THE reviewed builder the
        run itself will use, not by a second copy of its rules here;
      - the per-role attempt bounds and the cross-verifier launch ceiling are
        read out of the reviewer's own sources and policy asset.

    Model names are placeholders in the vector this builds. The bound does not
    depend on which model runs - only on how many launches the plan authorizes -
    and a tool that had to name a model to count launches would be a tool that
    could be wrong about a model it had not been told about.

.PARAMETER RequestPath
    The sealed shadow-run preparation request the bound is taken over.

.PARAMETER OutputPath
    Where to write the sealed bound artifact. Refused if it already exists,
    unless -Force is given: a bound silently rewritten in place is a bound whose
    provenance nobody can reconstruct.

.PARAMETER Force
    Replace an existing artifact at -OutputPath.

.OUTPUTS
    None on the success path. The artifact is the output; this tool prints
    nothing to stdout so that a caller cannot mistake a console line for a
    contract.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$BoundKind = 'devpilot.shadow-cohort.model-start-bound.v1'

function Get-BoundJsonProperty {
    <#
    .SYNOPSIS
        One required property of a parsed object, or a refusal naming it.
    #>
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where
    )
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        throw "The $Where declares no '$Name', so a model-start bound cannot be taken over it."
    }
    return $Object.$Name
}

try {
    $requestFull = [IO.Path]::GetFullPath($RequestPath)
    if (-not (Test-Path -LiteralPath $requestFull -PathType Leaf)) {
        throw "The sealed request '$requestFull' does not exist."
    }
    $requestBytes = [IO.File]::ReadAllBytes($requestFull)
    $requestSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($requestBytes)).ToLowerInvariant()
    $request = $null
    try {
        $request = [Text.UTF8Encoding]::new($false, $true).GetString($requestBytes) | ConvertFrom-Json -Depth 64
    }
    catch {
        throw "The sealed request '$requestFull' is not readable JSON: $($_.Exception.Message)"
    }

    $kind = [string](Get-BoundJsonProperty -Object $request -Name 'kind' -Where 'sealed request')
    if ($kind -cne 'shadow-run-preparation') {
        throw "The sealed request '$requestFull' declares kind '$kind', which is not a shadow-run preparation request."
    }
    $contractVersion = [string](Get-BoundJsonProperty -Object $request -Name 'contractVersion' -Where 'sealed request')
    if (-not $contractVersion.StartsWith('devpilot.shadow-run-coordinator.request.', [StringComparison]::Ordinal)) {
        throw "The sealed request '$requestFull' declares contract '$contractVersion', which this tool does not bound."
    }

    $toolkit = Get-BoundJsonProperty -Object $request -Name 'toolkit' -Where 'sealed request'
    $toolkitRoot = [string](Get-BoundJsonProperty -Object $toolkit -Name 'repositoryRoot' -Where 'sealed request toolkit')
    $toolkitHead = [string](Get-BoundJsonProperty -Object $toolkit -Name 'head' -Where 'sealed request toolkit')
    $qualification = Get-BoundJsonProperty -Object $request -Name 'qualification' -Where 'sealed request'
    $reviewerConfigPath = [string](Get-BoundJsonProperty -Object $qualification -Name 'reviewerConfigPath' `
            -Where 'sealed request qualification')
    $plannedRunCount = [int](Get-BoundJsonProperty -Object $qualification -Name 'plannedRunCount' `
            -Where 'sealed request qualification')
    $digests = Get-BoundJsonProperty -Object $request -Name 'digests' -Where 'sealed request'
    $pinnedConfigSha256 = ([string](Get-BoundJsonProperty -Object $digests -Name 'configSha256' `
                -Where 'sealed request digests')).ToLowerInvariant()

    if (-not (Test-Path -LiteralPath $reviewerConfigPath -PathType Leaf)) {
        throw ("The reviewer config '$reviewerConfigPath' the request pins does not exist, so the verification " +
            'authorization this bound depends on cannot be read.')
    }
    $configBytes = [IO.File]::ReadAllBytes($reviewerConfigPath)
    $configSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($configBytes)).ToLowerInvariant()
    if ($configSha256 -cne $pinnedConfigSha256) {
        throw ("The reviewer config '$reviewerConfigPath' hashes to $configSha256 and the request pins " +
            "$pinnedConfigSha256. A bound taken over a config the request did not seal would bound a different run.")
    }
    $config = $null
    try {
        $config = [Text.UTF8Encoding]::new($false, $true).GetString($configBytes) | ConvertFrom-Json -Depth 64
    }
    catch {
        throw "The reviewer config '$reviewerConfigPath' is not readable JSON: $($_.Exception.Message)"
    }

    # Read exactly as the reviewed plan builder reads it: an absent verification
    # block is a run that never verifies, and an absent 'enabled' inside a present
    # block is a config this tool refuses rather than reads as false.
    $verificationEnabled = $false
    $review = Get-BoundJsonProperty -Object $config -Name 'review' -Where 'reviewer config'
    if ($review.PSObject.Properties['verification']) {
        $verificationEnabled = [bool](Get-BoundJsonProperty -Object $review.verification -Name 'enabled' `
                -Where 'reviewer config review.verification')
    }

    $declaredSlots = @()
    if ($request.PSObject.Properties['slots'] -and $null -ne $request.slots) {
        $slots = $request.slots
        $enabled = [bool](Get-BoundJsonProperty -Object $slots -Name 'shadowSlotsEnabled' -Where 'sealed request slots')
        if ($enabled) {
            $declaredSlots = @(Get-BoundJsonProperty -Object $slots -Name 'declared' -Where 'sealed request slots')
        }
    }
    if (@($declaredSlots).Count -gt 0 -and @($declaredSlots).Count -ne $plannedRunCount) {
        throw ("The sealed request declares $(@($declaredSlots).Count) slot(s) and plans $plannedRunCount run(s). " +
            'A bound is refused over a request whose two statements of how many runs it makes disagree.')
    }

    Import-Module (Join-Path $toolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    . (Join-Path $toolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
    . (Join-Path $toolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
    . (Join-Path $toolkitRoot 'src\Agents\reviewer\ModelStartCensus.ps1')

    $total = 0
    $byRole = [ordered]@{ generalist = 0; specialist = 0; verifier = 0 }
    $slotBounds = @()
    foreach ($slot in @($declaredSlots)) {
        $slotName = [string](Get-BoundJsonProperty -Object $slot -Name 'name' -Where 'sealed request slot')
        $reviewerScriptPath = [string](Get-BoundJsonProperty -Object $slot -Name 'reviewerScriptPath' `
                -Where "sealed request slot '$slotName'")
        # The argument vector is built by the reviewed builder the run will use,
        # with placeholder model identifiers: the bound counts launches, and a
        # launch costs the same whichever model it names. Building it here rather
        # than describing it keeps this tool from drifting away from the vector
        # the run is actually given.
        $argv = New-ReviewerQualificationSlotArgument -RepoPath $toolkitRoot -ConfigFile $reviewerConfigPath `
            -StateDir $toolkitRoot -OperatorAlias 'bound' -PullRequestId 1 `
            -Model 'placeholder-generalist-first' -SecondPassModel 'placeholder-generalist-second' `
            -ConventionSpecialistModel 'placeholder-specialist' `
            -ConventionVerifierModel $(if ($verificationEnabled) { 'placeholder-verifier' } else { '' }) `
            -EnableVerificationPreview:$verificationEnabled `
            -ReplayRoot $toolkitRoot -ReplaySnapshotName 'bound' -ReplayManifestDigest ('0' * 64)
        $bound = Get-ReviewerModelStartBound -Argv ([string[]]$argv) -ReviewerScriptPath $reviewerScriptPath
        $total += [int]$bound.maxRealModelStarts
        $byRole['generalist'] += [int]$bound.byRole.generalist
        $byRole['specialist'] += [int]$bound.byRole.specialist
        $byRole['verifier'] += [int]$bound.byRole.verifier
        $slotBounds += [pscustomobject][ordered]@{
            name = $slotName
            maxRealModelStarts = [int]$bound.maxRealModelStarts
            byRole = $bound.byRole
            generalistPassCount = [int]$bound.generalistPassCount
            specialistAuthorized = [bool]$bound.specialistAuthorized
            verificationAuthorized = [bool]$bound.verificationAuthorized
            runnerBounds = $bound.runnerBounds
        }
    }

    $artifact = [ordered]@{
        kind = $BoundKind
        requestPath = [string]$requestFull
        requestSha256 = [string]$requestSha256
        toolkitHead = [string]$toolkitHead
        reviewerConfigSha256 = [string]$configSha256
        verificationAuthorized = [bool]$verificationEnabled
        declaredSlotCount = [int]@($declaredSlots).Count
        plannedRunCount = [int]$plannedRunCount
        maxRealModelStarts = [int]$total
        byRole = [pscustomobject]$byRole
        slots = @($slotBounds)
    }

    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    if ((Test-Path -LiteralPath $outputFull) -and -not $Force) {
        throw "A model-start bound already exists at '$outputFull'. Pass -Force to replace it deliberately."
    }
    $outputDirectory = Split-Path -Parent $outputFull
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
    }
    $json = ($artifact | ConvertTo-Json -Depth 12)
    [IO.File]::WriteAllText($outputFull, $json, [Text.UTF8Encoding]::new($false))
    exit 0
}
catch {
    [Console]::Error.WriteLine("New-ShadowModelStartBound: $($_.Exception.Message)")
    exit 1
}
