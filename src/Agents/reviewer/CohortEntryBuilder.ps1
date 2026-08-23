#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The orchestrator that turns one operator request into one immutable typed
    cohort-entry evidence package, with no model launch anywhere in it.

.DESCRIPTION
    This is the file an operator's tool calls. Everything it needs was decided in
    CohortEntryEvidence.ps1 and everything it stores was shaped by
    CohortEntryPackage.ps1; what happens here is the ORDER, which is itself part
    of the contract:

      1  the toolkit is the toolkit the request pinned
      2  the reviewer configuration is this subject's configuration
      3  the rule bundle declaration is the declaration it says it is
      4  the candidate identity is admissible
      5  the census is taken, and only then does the plan learn what to read
      6  every planned read is issued, once, through the reviewed seam
      7  the identity is re-read and must not have moved
      8  the package is assembled and published atomically
      9  optionally, the typed coordinator is driven to runSetReady, with no slot

    Step 5 is why the plan cannot be written down in full at the start and why it
    is nevertheless CLOSED: it is extended exactly once, from evidence that was
    itself captured under the plan, and re-checked against the read ceiling
    before a single file read is issued.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CohortEntryPackage.ps1')

# The exact list the reviewer scrubs from every live MCP child, restated here
# because this builder opens its own session and a shorter list would leave a
# credential reachable from a child that is supposed to be able to read and
# nothing else. Kept ordinal and explicit so a new name has to be added in both
# places deliberately rather than inherited by accident.
$script:ReviewerCohortEntrySensitiveEnvironmentVariables = @(
    'AZURE_DEVOPS_EXT_PAT', 'SYSTEM_ACCESSTOKEN',
    'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN'
)

function Assert-ReviewerCohortEntryToolkit {
    <#
    .SYNOPSIS
        Requires the toolkit on disk to be exactly the commit and ref the request
        pinned.

    .DESCRIPTION
        Read out of the git object store rather than from a recorded file,
        because the question is not what the operator believed the toolkit was
        when they wrote the request - it is what the toolkit IS at the moment
        this evidence is being built. A package built from a working tree that
        moved since the request was written attributes its results to a commit
        that never produced them.
    #>
    param([Parameter(Mandatory)]$Request)

    if (-not (Test-Path -LiteralPath $Request.ToolkitRoot -PathType Container)) {
        New-ReviewerCohortEntryRefusal -Code 'CE200' -Detail "The toolkit root '$($Request.ToolkitRoot)' does not exist."
    }
    $head = ''
    try {
        $head = ([string](& git -C $Request.ToolkitRoot rev-parse HEAD 2>$null)).Trim()
    }
    catch {
        New-ReviewerCohortEntryRefusal -Code 'CE200' -Detail "The toolkit root '$($Request.ToolkitRoot)' is not a readable git repository."
    }
    if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[0-9a-f]{40}$') {
        New-ReviewerCohortEntryRefusal -Code 'CE200' -Detail "The toolkit root '$($Request.ToolkitRoot)' did not resolve a HEAD commit."
    }
    if ($head -cne $Request.ToolkitHead) {
        New-ReviewerCohortEntryRefusal -Code 'CE200' `
            -Detail "The toolkit is at $head and the request pins $($Request.ToolkitHead)."
    }
    $refCommit = ([string](& git -C $Request.ToolkitRoot rev-parse --verify --quiet "$($Request.RequiredRef)^{commit}" 2>$null)).Trim()
    if ($refCommit -cnotmatch '^[0-9a-f]{40}$') {
        New-ReviewerCohortEntryRefusal -Code 'CE201' -Detail "The required ref '$($Request.RequiredRef)' does not resolve in the toolkit."
    }
    if ($refCommit -cne $Request.ToolkitHead) {
        New-ReviewerCohortEntryRefusal -Code 'CE201' `
            -Detail "The required ref '$($Request.RequiredRef)' resolves to $refCommit and the request pins $($Request.ToolkitHead)."
    }
    # HEAD naming the pinned commit is not the same statement as the assets on
    # disk BEING that commit. Everything downstream - the prompt-asset digest,
    # the stage-contract digest, the capture surfaces themselves - is read from
    # the working tree, so an uncommitted edit produces evidence attributed to a
    # commit that never contained it. Only tracked files matter: an untracked
    # scratch file changes nothing that is read, and refusing it would make the
    # builder unusable in the working directories operators actually have.
    $dirty = [string[]]@(& git -C $Request.ToolkitRoot status --porcelain --untracked-files=no -- 'src' 'tools' 2>$null |
            Where-Object { $null -ne $_ -and ([string]$_).Trim() -cne '' } | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE200' -Detail "The toolkit root '$($Request.ToolkitRoot)' would not report its working-tree state."
    }
    if ($dirty.Count -gt 0) {
        $shown = @($dirty | Select-Object -First 5 | ForEach-Object { ([string]$_).Trim() })
        New-ReviewerCohortEntryRefusal -Code 'CE213' `
            -Detail ("The toolkit working tree carries $($dirty.Count) tracked modification(s) under src/ or tools/, " +
                "so its assets are not commit $head`: $($shown -join '; ').")
    }
    return $head
}

function Get-ReviewerCohortEntryPromptAssetDigest {
    <#
    .SYNOPSIS
        The digest the typed coordinator binds a run's reviewer prompts by.

    .DESCRIPTION
        Recomputed here rather than copied from a fixture, and computed the same
        way the coordinator computes it: the ordinally sorted list of every
        '*.prompt.md' directly under src/Agents/reviewer, each reduced to its name
        and its digest, canonicalized and hashed. Only names and digests take
        part, so binding an entry to its prompts never reads prompt TEXT into
        anything. An entry that bound a value it invented would be refused by the
        coordinator at requestValidated, which is exactly where a wrong binding
        should stop.
    #>
    param([Parameter(Mandatory)][string]$ToolkitRoot)

    $directory = Join-Path $ToolkitRoot 'src/Agents/reviewer'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-ReviewerCohortEntryRefusal -Code 'CE200' -Detail "The toolkit holds no reviewer asset directory at '$directory'."
    }
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.prompt.md' -File |
            Sort-Object -Property Name -CaseSensitive)
    if ($files.Count -eq 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE200' -Detail "'$directory' holds no reviewer prompt asset to bind the entry to."
    }
    $list = @($files | ForEach-Object {
            [ordered]@{
                name = $_.Name
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
    $canonical = ConvertTo-AgentReplayCanonicalJson -Value $list
    $bytes = $script:ReviewerCohortEntryUtf8.GetBytes($canonical)
    return ([BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '').ToLowerInvariant()
}

function Assert-ReviewerCohortEntryRuleDeclaration {
    <#
    .SYNOPSIS
        Requires the pinned rule bundle declaration file to hash to the digest
        the request records for it.
    #>
    param([Parameter(Mandatory)]$Request)
    if (-not (Test-Path -LiteralPath $Request.RuleBundleDeclarationPath -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE112' -Detail "The rule bundle declaration '$($Request.RuleBundleDeclarationPath)' does not exist."
    }
    $observed = (Get-FileHash -LiteralPath $Request.RuleBundleDeclarationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($observed -cne $Request.RuleBundleDeclarationSha256) {
        New-ReviewerCohortEntryRefusal -Code 'CE112' `
            -Detail "The declaration hashes to $observed and the request records $($Request.RuleBundleDeclarationSha256)."
    }
    return $observed
}

function Assert-ReviewerCohortEntryRuleSection {
    <#
    .SYNOPSIS
        Requires one captured rule section's bytes to be exactly the bytes its
        pin declares, at the length it declares.

    .DESCRIPTION
        The rules are the only input to a review that the operator controls
        directly, so they are the input a reviewer's result is least able to
        defend on its own. A section that drifted by one byte from its pin is a
        different rule set, and a cohort that ran half its entries against one
        rule set and half against another is not a cohort.
    #>
    param(
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)]$Captured
    )
    if ([string]$Captured.Sha256 -cne [string]$Section.Sha256) {
        New-ReviewerCohortEntryRefusal -Code 'CE310' `
            -Detail "'$($Section.Path)' at $($Section.Commit) hashes to $([string]$Captured.Sha256) and the pin declares $([string]$Section.Sha256)."
    }
    if ([int]$Captured.ByteLength -ne [int]$Section.ByteLength) {
        New-ReviewerCohortEntryRefusal -Code 'CE310' `
            -Detail "'$($Section.Path)' is $([int]$Captured.ByteLength) bytes and the pin declares $([int]$Section.ByteLength)."
    }
}

function Get-ReviewerCohortEntrySourceTransportArgument {
    <#
    .SYNOPSIS
        The exact argument vector for the reviewer's own no-model source-
        transport capture.

    .DESCRIPTION
        Returned as a value rather than executed here so it can be asserted
        character by character in a test without starting anything. The reviewer
        refuses this mode without -Once and without an explicit -PullRequestId,
        and both are supplied here for that reason: a capture that fell back to
        the reviewer's polling loop would pick a pull request nobody named.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$ArtifactPath
    )
    $script = Join-Path $Request.ToolkitRoot 'src/Agents/reviewer/Start-ReviewerAgent.ps1'
    return [string[]]@(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-File', ([IO.Path]::GetFullPath($script)),
        '-ConfigPath', $Request.ReviewerConfigPath,
        '-RepositoryPath', $Request.ReviewerRepositoryPath,
        '-PullRequestId', ([string]$Request.PullRequestId),
        '-Once',
        '-CaptureSourceTransportOnly',
        '-CaptureSourceTransportArtifactPath', ([IO.Path]::GetFullPath($ArtifactPath))
    )
}

function Open-ReviewerCohortEntrySession {
    <#
    .SYNOPSIS
        Opens the read seam this capture runs over - a sealed replay snapshot or
        a live read-only wrapper session.

    .DESCRIPTION
        A replay is opened through the snapshot loader with the manifest digest
        the request pinned, so a snapshot that was edited after the operator
        recorded its digest cannot be replayed at all. A replay has NO live seam
        behind it: an unrecorded read fails rather than reaching the network,
        which is the property that makes a replayed package reproducible.
    #>
    param([Parameter(Mandatory)]$Request)
    if ($Request.CaptureMode -ceq 'replay') {
        $snapshot = New-AgentReplaySnapshot -ReplayRoot $Request.ReplayRoot -SnapshotName $Request.ReplaySnapshotName `
            -ExpectedManifestDigest $Request.ReplayManifestDigest
        return (Open-AgentMcpSession -AgencyPath 'replay' -Server 'ado' -ReplaySnapshot $snapshot)
    }
    $timeout = 30
    if ($Request.RequestTimeoutSeconds -gt 0) { $timeout = [Math]::Min(120, $Request.RequestTimeoutSeconds) }
    # The SAME toolset narrowing and the SAME credential scrub the reviewer's own
    # live sessions use, restated here as one list rather than left to the
    # harness default. The harness default is narrower, so relying on it would
    # leave a provider token reachable by a child this build claims cannot reach
    # one - a claim the architecture tests assert and an operator relies on.
    return (Open-AgentMcpSession -AgencyPath $Request.AgencyPath -Server 'ado' `
            -Organization $Request.Organization -Toolsets @('repos') -TimeoutSeconds $timeout `
            -EnvironmentVariablesToRemove $script:ReviewerCohortEntrySensitiveEnvironmentVariables)
}

function Get-ReviewerCohortEntrySiblingCensus {
    <#
    .SYNOPSIS
        The bounded set of side-by-side baseline reads this capture takes, in
        ordinal order.

    .DESCRIPTION
        A "sibling" here is the SAME path at the common commit - the left-hand
        side the right-hand side is a change to. Only edits qualify: an added
        path has no baseline, and asking for one would be a read the provider
        cannot answer, which in a replay is indistinguishable from a snapshot
        that forgot to record it.

        Chosen by ordinal position under the declared cap rather than by
        interest, because "interesting" is a judgement and this builder makes
        none. Two captures of one iteration therefore choose the same siblings.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Census,
        [Parameter(Mandatory)][int]$MaxSiblings
    )
    $eligible = [object[]]@($Census | Where-Object { [string]$_.ChangeType -ceq 'edit' })
    if ($MaxSiblings -le 0) { return [object[]]@() }
    if ($eligible.Count -le $MaxSiblings) { return $eligible }
    return [object[]]@($eligible[0..($MaxSiblings - 1)])
}

function New-ReviewerCohortEntryEvidence {
    <#
    .SYNOPSIS
        Builds and publishes one typed cohort-entry evidence package.

    .DESCRIPTION
        Returns the published root and the summary an operator reports from. It
        starts no model, requests no write tool, and consumes no slot: the only
        child it can start is the typed coordinator in a preparation target, and
        only when the caller asks for the preflight.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestPath,
        [switch]$Preflight,
        [ValidateSet('requestValidated', 'corpusValidated', 'recipePlanned', 'snapshotValidateOnly',
            'snapshotVerified', 'runSetReady')]
        [string]$PreflightTarget = 'snapshotVerified',
        # A bound derived elsewhere, for a build that runs where the producer
        # cannot. It is validated against this build's request and head exactly as
        # a freshly derived one is, so supplying it can only ever supply the same
        # answer sooner - never a different one.
        [string]$BoundArtifactPath = '',
        # Builds a slots-carrying entry that states it is NOT cohort-ready. The
        # launch authorization a run set publishes cannot exist until the run set
        # is declared, and declaring one needs an operator-held key - so without
        # this switch a slots-carrying build that did not reach runSetReady is
        # refused rather than published as though it could launch. This is how a
        # slots-carrying request is exercised on a machine that holds no key; the
        # entry it produces is refused by the cohort runner's pre-walk pass, by
        # the same rule, for the same reason.
        [switch]$PreparationOnly
    )

    $request = Read-ReviewerCohortEntryRequest -Path $RequestPath
    $toolkitHead = Assert-ReviewerCohortEntryToolkit -Request $request
    $configBinding = Get-ReviewerCohortEntryConfigBinding -ConfigPath $request.ReviewerConfigPath
    Assert-ReviewerCohortEntryConfigBinding -Binding $configBinding -Request $request
    # Checked BEFORE any read is issued. An execution plan that names a retired
    # model or a script that is not on disk is a plan that dies at slot startup;
    # discovering that after a whole corpus has been captured wastes the capture
    # and, worse, teaches an operator to expect a build to fail late.
    if ($null -ne $request.ExecutionPlan) {
        Assert-ReviewerCohortEntryExecutionPlanBinding -Plan $request.ExecutionPlan -Binding $configBinding
    }
    $declarationSha = Assert-ReviewerCohortEntryRuleDeclaration -Request $request

    $plan = [System.Collections.Generic.List[object]]::new()
    $identityReads = [object[]]@(Get-ReviewerCohortEntryIdentityReadPlan -Request $request)
    foreach ($read in $identityReads) { [void]$plan.Add($read) }
    # Declared HERE, before the first read is issued, and executed last. It is
    # the same question 'candidate-identity' asks, asked again after everything
    # else, so that the stability check covers every read between them. Declaring
    # it up front is what keeps the plan closed: a re-read issued outside the
    # plan is a read nobody authorized, however well-intentioned.
    $liveRead = New-ReviewerCohortEntryRead -Id 'live-identity' -Tool 'repo_pull_request' -Role 'identity' `
        -Arguments ([ordered]@{
            action = 'get'
            project = $request.Project
            repositoryId = $request.RepositoryName
            pullRequestId = $request.PullRequestId
        }) -Envelope 'mcpTextContent' -PayloadFile 'payloads/pr-get.json' -DuplicateOf 'candidate-identity'
    [void]$plan.Add($liveRead)
    Assert-ReviewerCohortEntryPlanIsClosed -Plan ([object[]]$plan.ToArray())

    $session = Open-ReviewerCohortEntrySession -Request $request
    $captured = [System.Collections.Generic.List[object]]::new()
    $identity = $null
    $liveIdentity = $null
    $iteration = $null
    $census = [object[]]@()
    $spanEvidence = [ordered]@{}
    $ruleReads = [System.Collections.Generic.List[object]]::new()
    try {
        $byId = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($read in $identityReads) {
            $record = Invoke-ReviewerCohortEntryRead -Session $session -Read $read -MaxBytes $request.MaxFileBytes
            [void]$captured.Add($record)
            $byId[[string]$read.Id] = $record
        }

        $identity = Get-ReviewerCohortEntryPullRequestIdentity -PullRequest $byId['candidate-identity'].Parsed -Request $request
        Assert-ReviewerCohortEntryRepositoryIdentity -Repository $byId['repository-identity'].Parsed `
            -ExpectedProject $request.Project -ExpectedRepositoryId $request.RepositoryId
        # The target branch is read to prove the declared ref RESOLVES - one
        # branch, the exact requested name, one 40-hex commit - and its tip is
        # recorded as the tip. It is deliberately NOT required to equal the pull
        # request's last merged target: on an active repository the branch moves
        # ahead of the merge the pull request was last built against, and every
        # real entry would be refused by that equality. What must hold is that the
        # pull request's own target commit is one 40-hex commit, which the identity
        # reader has already required under CE210 before this point.
        $targetBranchTip = Get-ReviewerCohortEntryBranchCommit -BranchResult $byId['target-branch'].Parsed `
            -ExpectedRefName $request.TargetRefName
        $targetCommit = $identity.TargetCommit
        $iteration = Get-ReviewerCohortEntryIterationBinding -Changes $byId['changes-plain'].Parsed -Identity $identity
        $census = @(Get-ReviewerCohortEntryChangedPathCensus -Changes $byId['changes-plain'].Parsed -Request $request)
        Assert-ReviewerCohortEntryCensusOrder -Census $census

        # The read asked for exactly the page the live cycle asks for, so it is
        # NOT a cap+1 probe and an answer that fills the page proves nothing: a
        # full page is what a truncated list and a complete-and-exactly-full list
        # both look like. Completeness is therefore accounted here - above the
        # operator's cap is CE406, at the reviewer's page is CE408 - rather than
        # assumed from a count.
        $threadRecords = @(Get-ReviewerCohortEntryThreadRecords -Threads $byId['threads'].Parsed)
        if ($threadRecords.Count -gt $request.MaxThreads) {
            New-ReviewerCohortEntryRefusal -Code 'CE406' `
                -Detail "The thread list carries at least $($threadRecords.Count) threads and the request caps them at $($request.MaxThreads)."
        }
        if ($threadRecords.Count -ge (Get-ReviewerThreadListTop)) {
            New-ReviewerCohortEntryRefusal -Code 'CE408' `
                -Detail ("The thread list came back with $($threadRecords.Count) threads, filling the page of " +
                    "$(Get-ReviewerThreadListTop) the reviewer's own read asks for, so it cannot be shown to be the whole list.")
        }

        # The plan is extended EXACTLY ONCE, from evidence captured under the
        # plan, and is re-checked against the read ceiling before any of it is
        # issued. There is no later extension: what is not planned here is not
        # readable at all for the rest of this build.
        $extension = [System.Collections.Generic.List[object]]::new()
        foreach ($record in $census) {
            if (-not [bool]$record.HasRightHand) { continue }
            $suffix = ([int]$record.Ordinal).ToString('000', [Globalization.CultureInfo]::InvariantCulture)
            [void]$extension.Add((Get-ReviewerCohortEntryFileRead -Request $request -Id "changed-$suffix" `
                        -ProviderPath ([string]$record.Path) -Commit $identity.SourceCommit -Role 'changedFile' `
                        -PayloadFile "payloads/file-$suffix.txt"))
        }
        # The sibling cap is a SAMPLE size, not a bound to refuse against: the
        # selector already takes the first N eligible rows in ordinal order, so
        # a subject with more edits than the cap is reviewed on a smaller,
        # deterministic baseline rather than refused. The caps that DO fail
        # closed - CE402 on changed files, CE406 on threads, CE305 on bytes -
        # bound counts the PROVIDER supplied, which is a different statement.
        $siblings = @(Get-ReviewerCohortEntrySiblingCensus -Census $census -MaxSiblings $request.MaxSiblingFiles)
        foreach ($record in $siblings) {
            $suffix = ([int]$record.Ordinal).ToString('000', [Globalization.CultureInfo]::InvariantCulture)
            [void]$extension.Add((Get-ReviewerCohortEntryFileRead -Request $request -Id "baseline-$suffix" `
                        -ProviderPath ([string]$record.Path) -Commit $identity.CommonCommit -Role 'sibling' `
                        -PayloadFile "payloads/baseline-$suffix.txt"))
        }
        $ruleOrdinal = 0
        foreach ($section in $request.RuleSections) {
            $ruleOrdinal++
            $suffix = $ruleOrdinal.ToString('000', [Globalization.CultureInfo]::InvariantCulture)
            $ruleRead = Get-ReviewerCohortEntryFileRead -Request $request -Id "rule-$suffix" `
                -ProviderPath ([string]$section.Path) -Commit ([string]$section.Commit) -Role 'rule' `
                -PayloadFile "payloads/rule-$suffix.txt"
            [void]$extension.Add($ruleRead)
            [void]$ruleReads.Add([pscustomobject]@{ Section = $section; ReadId = [string]$ruleRead.Id })
        }
        foreach ($read in $extension) { [void]$plan.Add($read) }
        Assert-ReviewerCohortEntryPlanIsClosed -Plan ([object[]]$plan.ToArray())

        foreach ($read in $extension) {
            $record = Invoke-ReviewerCohortEntryRead -Session $session -Read $read -MaxBytes $request.MaxFileBytes
            [void]$captured.Add($record)
            $byId[[string]$read.Id] = $record
        }

        foreach ($pin in $ruleReads) {
            Assert-ReviewerCohortEntryRuleSection -Section $pin.Section -Captured $byId[[string]$pin.ReadId]
        }

        # Span evidence, bound to the file it is a span OF. The spans come from
        # the reviewer's own right-hand extractor over the diff variant - not
        # from a second reading of the diff invented here - and each one is then
        # checked against the line count of the file this build actually read at
        # the source commit. That second half is the part a hand-assembled span
        # list never had: a span past the end of the file, or one overlapping the
        # span before it, makes the reviewer slice bytes that are not the bytes
        # the span claims, and nothing downstream would notice.
        # Materialized into a dictionary this scope constructs, rather than held
        # as the extractor's return value: an ordered dictionary that arrives as
        # a command result is a collection PowerShell is free to flatten, and
        # everything below indexes it by path.
        $spanMap = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach ($entry in (Get-ReviewerSourceChangedSpans -Response $byId['changes-diffs'].Parsed).GetEnumerator()) {
            $spanMap[[string]$entry.Key] = [object[]]@($entry.Value)
        }
        # Ordinal, like $spanMap above and like the census itself. A
        # case-insensitive dictionary would merge /Src/A.cs and /src/a.cs into
        # one entry, and the witness below would then hand one file the other's
        # spans - already validated, against the wrong file's line count.
        $spanEvidence = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        foreach ($record in $census) {
            if (-not [bool]$record.HasRightHand) { continue }
            $suffix = ([int]$record.Ordinal).ToString('000', [Globalization.CultureInfo]::InvariantCulture)
            $lineCount = Get-ReviewerCohortEntryLineCount -Text ([string]$byId["changed-$suffix"].Text)
            $raw = @(if ($spanMap.Contains([string]$record.Path)) { $spanMap[[string]$record.Path] } else { @() })
            $spanEvidence[[string]$record.Path] = [object[]]@(Get-ReviewerCohortEntrySpanEvidence `
                    -Spans ([object[]]@($raw | ForEach-Object {
                                [pscustomobject][ordered]@{ start = [int]$_.Start; count = ([int]$_.End - [int]$_.Start + 1) }
                            })) `
                    -LineCount $lineCount -Path ([string]$record.Path))
        }

        # Last, so the stability check covers every read above it. The read
        # itself was declared with the plan, before any of them was issued.
        $liveRecord = Invoke-ReviewerCohortEntryRead -Session $session -Read $liveRead -MaxBytes $request.MaxFileBytes
        [void]$captured.Add($liveRecord)
        $byId[[string]$liveRead.Id] = $liveRecord
        $liveIdentity = Get-ReviewerCohortEntryPullRequestIdentity -PullRequest $liveRecord.Parsed -Request $request
        Assert-ReviewerCohortEntryIdentityStable -Candidate $identity -Live $liveIdentity
    }
    finally {
        Close-AgentMcpSession -Session $session
    }

    Assert-ReviewerCohortEntryReadsComplete -Plan ([object[]]$plan.ToArray()) -Captured ([object[]]$captured.ToArray())

    # Covered means this census row's OWN path resolved to a payload this build
    # stored, checked row by row. A count taken off the plan would restate the
    # plan's cardinality, and would still be right if every payload had been
    # filed under the wrong path.
    $coveredCount = 0
    foreach ($record in $census) {
        if (-not [bool]$record.HasRightHand) { continue }
        $suffix = ([int]$record.Ordinal).ToString('000', [Globalization.CultureInfo]::InvariantCulture)
        $key = "changed-$suffix"
        if (-not $byId.ContainsKey($key)) { continue }
        if ([string]$byId[$key].Read.ProviderPath -cne [string]$record.Path) { continue }
        $coveredCount++
    }
    $coverage = Measure-ReviewerCohortEntryCoverage -Census $census -CoveredCount $coveredCount `
        -MinimumPercent $request.MinChangedPathCoveragePercent

    # ---- assembly -------------------------------------------------------
    # Everything is BUILT in staging and every path RECORDED inside the package
    # names where the package will finally live. A request that pointed at the
    # staging directory would validate once, during the build, and then name a
    # directory that no longer exists for every reader after it.
    $publishedRoot = [IO.Path]::GetFullPath($request.OutputRoot)
    $publishedEntryRoot = Join-Path $publishedRoot 'entry'
    $publishedCorpusRoot = Join-Path $publishedRoot 'corpus'
    $staging = Join-Path (Split-Path -Parent $request.OutputRoot) (".staging-$([guid]::NewGuid().ToString('n'))")
    [void](New-Item -ItemType Directory -Force -Path $staging)
    $corpusRoot = Join-Path $staging 'corpus'
    $evidenceRoot = Join-Path $staging 'entry'
    [void](New-Item -ItemType Directory -Force -Path $evidenceRoot)

    $corpusFiles = [ordered]@{}
    $resources = [System.Collections.Generic.List[object]]::new()
    $corpusPathByReadId = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $fileOrdinal = 0
    foreach ($record in $captured) {
        $envelopeBytes = Test-ReviewerCohortEntryEnvelopeRoundTrip -Captured $record
        # A declared re-read asks a question the corpus already answers. Storing
        # it again would put two resources under one request key into a corpus
        # whose replay loader resolves by request key, and the second one would
        # be unreachable - a resource nobody can serve, sealed as if it could be.
        if ([string]$record.Read.DuplicateOf) { continue }
        $fileOrdinal++
        $relative = Get-ReviewerCohortEntryCorpusRelativePath -Read $record.Read -Ordinal $fileOrdinal
        $corpusFiles[$relative] = [byte[]]$record.Bytes
        $corpusPathByReadId[[string]$record.Read.Id] = $relative
        [void]$resources.Add((New-ReviewerCohortEntryResourceDeclaration -Captured $record `
                    -CorpusRelativePath $relative -EnvelopeBytes $envelopeBytes))
    }

    # ---- the payloads the shipping sealer reads --------------------------
    # A corpus that carries only the provider's own responses is a corpus no
    # supported sealer can seal: the seal binds a FLAT identity, a right-hand
    # hunk census and the transport policy, and none of those is a shape any
    # provider response has. They are written from this build's own typed
    # declarations, and they are written HERE - before the index is minted -
    # because a payload added after the index is a payload outside the integrity
    # claim the whole seal rests on.
    $startIdentityCorpusPath = 'capture/start-identity.json'
    $endIdentityCorpusPath = 'capture/end-identity.json'
    $hunkCensusCorpusPath = 'census/right-hand-hunks.json'
    $policyCorpusPath = 'policy/source-transport-policy.json'
    $corpusFiles[$startIdentityCorpusPath] = $script:ReviewerCohortEntryUtf8.GetBytes(
        (ConvertTo-AgentReplayCanonicalJson -Value (New-ReviewerCohortEntryCaptureIdentityPayload `
                    -Request $request -Identity $identity -IterationId $iteration.IterationId)))
    $corpusFiles[$endIdentityCorpusPath] = $script:ReviewerCohortEntryUtf8.GetBytes(
        (ConvertTo-AgentReplayCanonicalJson -Value (New-ReviewerCohortEntryCaptureIdentityPayload `
                    -Request $request -Identity $liveIdentity -IterationId $iteration.IterationId -End)))
    # The census is a LIST even when one path changed. PowerShell unrolls an array
    # returned through the pipeline, so a single-file pull request would otherwise
    # canonicalize to a JSON object and the sealer would refuse the entry.
    $hunkCensus = [object[]]@(New-ReviewerCohortEntryHunkCensusPayload -SpanEvidence $spanEvidence)
    $corpusFiles[$hunkCensusCorpusPath] = $script:ReviewerCohortEntryUtf8.GetBytes(
        (ConvertTo-AgentReplayCanonicalJson -Value $hunkCensus))
    # The policy comes out of the pinned toolkit, as bytes, into the corpus. The
    # seal will derive under exactly these bytes, and putting them INSIDE the
    # index means the derivation is bound by the same integrity claim as the
    # content it runs over rather than by a checkout that has to still exist.
    $policySourcePath = Join-Path $request.ToolkitRoot 'src/Agents/reviewer/source/v1/policy.json'
    if (-not (Test-Path -LiteralPath $policySourcePath -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE803' `
            -Detail "The source-transport policy '$policySourcePath' does not exist in the pinned toolkit."
    }
    $corpusFiles[$policyCorpusPath] = [IO.File]::ReadAllBytes($policySourcePath)

    $rightHandCorpusPaths = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($record in $census) {
        if (-not [bool]$record.HasRightHand) { continue }
        $suffix = ([int]$record.Ordinal).ToString('000', [Globalization.CultureInfo]::InvariantCulture)
        $rightHandCorpusPaths[[string]$record.Path] = [string]$corpusPathByReadId["changed-$suffix"]
    }
    $siblingCorpusPaths = [string[]]@(@($siblings) | ForEach-Object {
            [string]$corpusPathByReadId["baseline-$(([int]$_.Ordinal).ToString('000', [Globalization.CultureInfo]::InvariantCulture))"]
        })
    $ruleCorpusPaths = [string[]]@(@($ruleReads) | ForEach-Object { [string]$corpusPathByReadId[[string]$_.ReadId] })

    $corpus = New-ReviewerCohortEntryCorpus -Root $corpusRoot -Files $corpusFiles -Request $request `
        -Identity $identity -IterationId $iteration.IterationId

    # The census the typed coordinator reads is a SET of paths in ordinal
    # ascending order - that is its contract, and it is a different statement
    # from this builder's ordinal census, which preserves the order the provider
    # declared. Both are published: this file for the coordinator, and the
    # ordered census in the identity witness for anyone auditing the assembly.
    #
    # The census is ALREADY ordinal-ascending and duplicate-free, proven by
    # Assert-ReviewerCohortEntryCensusOrder above. It is emitted as it stands
    # rather than re-sorted, because Sort-Object -CaseSensitive is culture-aware
    # and the C# reader compares with string.CompareOrdinal: on a culture where
    # the two disagree, a re-sort would produce an order the coordinator rejects
    # from a census that was correct before it was "helped".
    $changedPaths = [ordered]@{
        contractVersion = $script:ReviewerCohortEntryChangedPathsContract
        kind = 'shadow-run-coordinator-changed-paths'
        changedPaths = [object[]]@($census | ForEach-Object { [string]$_.Path })
    }
    $changedPathsPath = Join-Path $evidenceRoot 'changed-paths.json'
    [IO.File]::WriteAllBytes($changedPathsPath,
        $script:ReviewerCohortEntryUtf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $changedPaths)))

    $identityWitnessPath = Join-Path $evidenceRoot 'identity-witness.json'
    $identityWitness = [ordered]@{
        kind = $script:ReviewerCohortEntryPackageKind
        correlationId = $request.CorrelationId
        toolkitHead = $toolkitHead
        requiredRef = $request.RequiredRef
        candidate = [ordered]@{
            pullRequestId = $identity.PullRequestId
            status = $identity.Status
            isDraft = $identity.IsDraft
            targetRefName = $identity.TargetRefName
            sourceCommit = $identity.SourceCommit
            commonCommit = $identity.CommonCommit
            targetCommit = $identity.TargetCommit
        }
        live = [ordered]@{
            pullRequestId = $liveIdentity.PullRequestId
            status = $liveIdentity.Status
            isDraft = $liveIdentity.IsDraft
            targetRefName = $liveIdentity.TargetRefName
            sourceCommit = $liveIdentity.SourceCommit
            commonCommit = $liveIdentity.CommonCommit
            targetCommit = $liveIdentity.TargetCommit
        }
        iterationId = $iteration.IterationId
        # The tip the declared target ref resolved to at capture time. Recorded
        # rather than compared: it is how far the target had moved past the merge
        # this pull request was last built against, which a later reader needs and
        # cannot recover from the entry any other way.
        targetBranchTip = $targetBranchTip
        census = [object[]]@($census | ForEach-Object {
                $spans = [object[]]@(if ($spanEvidence.Contains([string]$_.Path)) { $spanEvidence[[string]$_.Path] } else { @() })
                [ordered]@{
                    ordinal = [int]$_.Ordinal
                    path = [string]$_.Path
                    changeType = [string]$_.ChangeType
                    hasRightHand = [bool]$_.HasRightHand
                    # Validated against the captured file, not copied from the
                    # diff. An empty list on a right-hand change is a real answer
                    # - a whole-file rewrite carries no admissible block - and is
                    # published as such rather than hidden.
                    spans = $spans
                }
            })
        coverage = [ordered]@{
            eligible = [int]$coverage.EligibleCount
            covered = [int]$coverage.CoveredCount
            percent = [int]$coverage.Percent
            floor = $request.MinChangedPathCoveragePercent
        }
        config = [ordered]@{
            path = $request.ReviewerConfigPath
            sha256 = $configBinding.Sha256
            validatedTargetRef = $configBinding.ValidatedTargetRef
        }
        ruleBundle = [ordered]@{
            sourceKind = $request.RuleBundleSourceKind
            declarationPath = $request.RuleBundleDeclarationPath
            declarationSha256 = $declarationSha
            sections = [object[]]@($request.RuleSections | ForEach-Object {
                    [ordered]@{ path = [string]$_.Path; commit = [string]$_.Commit; sha256 = [string]$_.Sha256; byteLength = [int]$_.ByteLength }
                })
        }
        capture = [ordered]@{
            mode = $request.CaptureMode
            readCount = $captured.Count
            identityReReads = 1
            modelStarts = 0
            providerWrites = 0
        }
        request = [ordered]@{ path = $request.RequestPath; sha256 = $request.RequestSha256 }
    }
    [IO.File]::WriteAllBytes($identityWitnessPath,
        $script:ReviewerCohortEntryUtf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $identityWitness)))

    # The stage producer contract schema is digested where the coordinator will
    # read it - in the toolkit - rather than restated by the operator. A request
    # that bound a digest of its own bytes would bind the wrong file, and the
    # typed reader would refuse it with a mismatch nobody could act on.
    $stageSchemaPath = Join-Path $request.ToolkitRoot 'src/Agents/reviewer/schemas/reviewer.stage-producer-contracts.v1.json'
    if (-not (Test-Path -LiteralPath $stageSchemaPath -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE200' -Detail "The stage producer contract schema '$stageSchemaPath' does not exist in the toolkit."
    }
    $stageSchemaSha = (Get-FileHash -LiteralPath $stageSchemaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $promptAssetSha = Get-ReviewerCohortEntryPromptAssetDigest -ToolkitRoot $request.ToolkitRoot

    # ---- the corpus seal recipe the shipping sealer consumes --------------
    # The production nineteen-key recipe, not a builder dialect of one. It is
    # written before the coordinator request so the request can bind its path and
    # digest, and self-validated below through the SAME importer and planner the
    # sealer runs - so "this entry is sealable" is a property this build proved,
    # not a hope the first coordinator to reach state 6 gets to test.
    $reviewerScriptSha = if ($null -ne $request.ExecutionPlan) {
        [string]$request.ExecutionPlan.ReviewerScriptSha256
    }
    else {
        # A preparation-only entry declares no reviewer script, so the script that
        # produced this evidence is the one bound: something real, digested where
        # it ran, rather than a placeholder that would bind nothing.
        (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    # Assigned, then narrowed. An `if` that yields an empty array yields NOTHING
    # through the pipeline, so a prep-only entry would hand a mandatory parameter
    # $null rather than the empty binding it means.
    $recipeModels = [string[]]@()
    if ($null -ne $request.ExecutionPlan) {
        $recipeModels = [string[]]@(@([string[]]@($request.ExecutionPlan.GeneralistPair) +
                [string]$request.ExecutionPlan.ConventionSpecialistModel +
                [string]$request.ExecutionPlan.ConventionVerifierModel) | Sort-Object -CaseSensitive -Unique)
    }
    $recipe = New-ReviewerCohortEntryOfflineSealRecipe -Request $request -Identity $identity `
        -IterationId $iteration.IterationId -Files $corpusFiles -Corpus $corpus `
        -Resources ([object[]]$resources.ToArray()) -SpanEvidence $spanEvidence `
        -RightHandCorpusPaths $rightHandCorpusPaths -ChangeSetResponse $byId['changes-plain'].Parsed `
        -ChangeSetCorpusPath ([string]$corpusPathByReadId['changes-plain']) `
        -SpanEvidenceCorpusPath $hunkCensusCorpusPath `
        -StartIdentityCorpusPath $startIdentityCorpusPath -EndIdentityCorpusPath $endIdentityCorpusPath `
        -PolicyCorpusPath $policyCorpusPath -SiblingCorpusPaths $siblingCorpusPaths `
        -RuleCorpusPaths $ruleCorpusPaths `
        -ThreadCorpusPaths ([string[]]@([string]$corpusPathByReadId['threads'])) `
        -ConfigSha256 $configBinding.Sha256 -ScriptSha256 $reviewerScriptSha -PromptSha256 $promptAssetSha `
        -SchemaSha256 $stageSchemaSha -Models $recipeModels `
        -CapturedUtc ([DateTime]::UtcNow.ToString('yyyyMMdd\THHmmss\Z', [Globalization.CultureInfo]::InvariantCulture))
    $recipePath = Join-Path $evidenceRoot 'corpus-seal-recipe.json'
    [IO.File]::WriteAllBytes($recipePath,
        $script:ReviewerCohortEntryUtf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $recipe)))
    [void](Assert-ReviewerCohortEntrySealable -CorpusRoot $corpusRoot -CorpusIndexSha256 $corpus.IndexSha256 `
            -RecipePath $recipePath -ToolkitRoot $request.ToolkitRoot)

    # The preparation root is a SIBLING of the package, never inside it. The
    # package is sealed and read-only the moment it is published; the coordinator
    # writes state, audit and a lease every time it runs, and a run that mutated
    # the thing it was verifying would break the seal it just checked. Derived by
    # the same function the request reader used, so the launch authorization the
    # plan carries and the run set this build declares cannot disagree.
    $preparationOutputRoot = Get-ReviewerCohortEntryPreparationRoot -OutputRoot $request.OutputRoot
    $coordinatorRequest = New-ReviewerCohortEntryCoordinatorRequest -Request $request -Identity $identity `
        -IterationId $iteration.IterationId -Corpus $corpus -CorpusRoot $publishedCorpusRoot `
        -RecipePath (Join-Path $publishedEntryRoot 'corpus-seal-recipe.json') `
        -ChangedPathsPath (Join-Path $publishedEntryRoot 'changed-paths.json') -ConfigSha256 $configBinding.Sha256 `
        -PromptSha256 $promptAssetSha -SchemaSha256 $stageSchemaSha `
        -PreparationOutputRoot $preparationOutputRoot
    $coordinatorRequestPath = Join-Path $evidenceRoot 'coordinator-request.json'
    [IO.File]::WriteAllBytes($coordinatorRequestPath,
        $script:ReviewerCohortEntryUtf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $coordinatorRequest)))
    $coordinatorRequestSha = (Get-FileHash -LiteralPath $coordinatorRequestPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $modelStartBoundPath = Join-Path $evidenceRoot 'model-start-bound.json'
    # DERIVED by the reviewed producer over the request that was actually
    # emitted, and published verbatim. Nothing about the bound is computed here:
    # a second arithmetic in this file would be a second answer, and the cohort
    # runner would have no way to tell which one it was holding.
    $executionPlan = $request.ExecutionPlan
    $derivedBound = New-ReviewerCohortEntryModelStartBound -ToolkitRoot $request.ToolkitRoot `
        -ToolkitHead $request.ToolkitHead -RequestPath $coordinatorRequestPath `
        -RequestSha256 $coordinatorRequestSha -OutputPath $modelStartBoundPath `
        -BoundArtifactPath $BoundArtifactPath
    # The declared slot count the producer read has to be the one this builder
    # emitted, or the two are describing different requests through the same file.
    $expectedSlotCount = if ($null -ne $executionPlan) { @($executionPlan.Slots).Count } else { 0 }
    if ($derivedBound.DeclaredSlotCount -ne $expectedSlotCount) {
        New-ReviewerCohortEntryRefusal -Code 'CE714' `
            -Detail "The derived model start bound counts $($derivedBound.DeclaredSlotCount) declared slot(s); this entry emitted $expectedSlotCount."
    }
    # The ESTIMATE is the ceiling a cohort budgets against, and the cohort runner
    # refuses an entry whose estimate is below its own sealed bound. Taking it
    # FROM the derived maxima makes "estimate is an upper bound" true by
    # construction rather than by an operator getting the arithmetic right.
    # A preparation-only entry declares no slots, so its bound is zero real model
    # starts and the run count it plans stays its published estimate.
    if ($null -ne $executionPlan) {
        $supervisedChildren = @($executionPlan.Slots).Count + 2
        $wallClock = ([long]$executionPlan.SlotTimeoutSeconds + [long]$executionPlan.SupervisionGraceSeconds) * $supervisedChildren
        $estimatedModelStarts = [int]$derivedBound.MaxRealModelStarts
        $estimatedVerifierAssignments = [int]$derivedBound.MaxVerifierAssignments
        $estimatedWallClockSeconds = [int]$wallClock
    }
    else {
        $estimatedModelStarts = [int]$request.PlannedRunCount
        $estimatedVerifierAssignments = [int]$request.PlannedRunCount
        $estimatedWallClockSeconds = [int]($request.ChildTimeoutSeconds * $request.PlannedRunCount)
    }
    # A zero estimate is a budget that authorizes nothing and passes every check
    # by being empty, which is the one way a bound can be wrong without anything
    # noticing. Asserted rather than assumed, because both branches above compute
    # it and only one of them is exercised by any given build.
    foreach ($pair in @(
            @{ Name = 'modelStarts'; Value = $estimatedModelStarts },
            @{ Name = 'verifierAssignments'; Value = $estimatedVerifierAssignments },
            @{ Name = 'wallClockSeconds'; Value = $estimatedWallClockSeconds })) {
        if ([int]$pair['Value'] -le 0) {
            New-ReviewerCohortEntryRefusal -Code 'CE712' `
                -Detail "The model start bound field '$($pair['Name'])' is '$($pair['Value'])'; a bound estimate is a positive 32-bit integer."
        }
    }
    # Below its own bound is exactly the under-declaration the cohort runner
    # refuses, and it is cheaper to refuse it here than after a cohort has been
    # assembled around it.
    if ($estimatedModelStarts -lt [int]$derivedBound.MaxRealModelStarts -or
        $estimatedVerifierAssignments -lt [int]$derivedBound.MaxVerifierAssignments) {
        New-ReviewerCohortEntryRefusal -Code 'CE714' `
            -Detail ("This entry estimates $estimatedModelStarts model start(s) and $estimatedVerifierAssignments verifier assignment(s) " +
                "against a derived bound of $($derivedBound.MaxRealModelStarts) and $($derivedBound.MaxVerifierAssignments).")
    }
    $modelStartBoundSha = [string]$derivedBound.Sha256

    $manifestEntry = New-ReviewerCohortEntryManifestEntry -Request $request -Identity $identity `
        -IterationId $iteration.IterationId `
        -CoordinatorRequestPath (Join-Path $publishedEntryRoot 'coordinator-request.json') `
        -CoordinatorRequestSha256 $coordinatorRequestSha `
        -PreparationOutputRoot $preparationOutputRoot `
        -ConfigSha256 $configBinding.Sha256 -PromptSha256 $promptAssetSha -SchemaSha256 $stageSchemaSha `
        -ModelStartBoundPath (Join-Path $publishedEntryRoot 'model-start-bound.json') `
        -ModelStartBoundSha256 $modelStartBoundSha `
        -EstimatedModelStarts $estimatedModelStarts -EstimatedVerifierAssignments $estimatedVerifierAssignments `
        -EstimatedWallClockSeconds $estimatedWallClockSeconds
    $entryPath = Join-Path $evidenceRoot 'cohort-entry.json'
    [IO.File]::WriteAllBytes($entryPath,
        $script:ReviewerCohortEntryUtf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $manifestEntry)))

    $published = Publish-ReviewerCohortEntryPackage -StagingRoot $staging -DestinationRoot $request.OutputRoot `
        -SealKeyPath $request.SealKeyPath

    $preflightState = 'notRequested'
    if ($Preflight) {
        $preflightState = Invoke-ReviewerCohortEntryPreflight -Request $request `
            -CoordinatorRequestPath (Join-Path (Join-Path $published 'entry') 'coordinator-request.json') `
            -PreparationOutputRoot $preparationOutputRoot -Target $PreflightTarget
    }

    # A slots-carrying entry is a claim that a cohort may LAUNCH it. Nothing in
    # the package can substantiate that claim on its own: the launch
    # authorization is minted by the run set declaration, which runs against the
    # published request and so cannot precede the publish. The claim is settled
    # here, on the real preparation, and an entry that cannot substantiate it is
    # WITHDRAWN - the package it published is deleted - rather than left on disk
    # where a manifest could name it. Otherwise a cohort would spend its one
    # authorized execution on a token that was never going to exist, and find out
    # at the first slot prelaunch.
    $launchAuthorization = $null
    $cohortReady = $false
    if ($null -ne $executionPlan) {
        if ($PreparationOnly) {
            # An explicit, recorded claim of NOT being ready. The entry is still
            # built and still sealed - that is how a slots-carrying request is
            # exercised without an operator key - but it carries no declared run
            # set, so a cohort that names it runs the preparation from scratch
            # and mints the authorization itself rather than trusting one.
            Write-Verbose "The entry declares $(@($executionPlan.Slots).Count) slot(s) and was built -PreparationOnly; it is not cohort-ready."
        }
        elseif ($preflightState -cne 'runSetReady') {
            Remove-ReviewerCohortEntryPublishedPackage -Root $published
            New-ReviewerCohortEntryRefusal -Code 'CE715' `
                -Detail ("The request declares $(@($executionPlan.Slots).Count) slot(s) and this build reached '$preflightState'; its package has been withdrawn. " +
                    "Run with -Preflight -PreflightTarget runSetReady so the preparation declares the run set and mints the launch authorization this entry names, " +
                    "or pass -PreparationOnly to build an entry that states it is not cohort-ready.")
        }
        else {
            try {
                $launchAuthorization = Assert-ReviewerCohortEntryLaunchAuthorization `
                    -PreparationOutputRoot $preparationOutputRoot -CoordinatorRequestSha256 $coordinatorRequestSha
            }
            catch {
                Remove-ReviewerCohortEntryPublishedPackage -Root $published
                throw
            }
            $cohortReady = $true
        }
    }

    return [pscustomobject][ordered]@{
        Root = $published
        EntryId = $request.EntryId
        Ordinal = $request.Ordinal
        PullRequestId = $request.PullRequestId
        IterationId = $iteration.IterationId
        SourceCommit = $identity.SourceCommit
        CommonCommit = $identity.CommonCommit
        TargetCommit = $identity.TargetCommit
        CensusCount = $census.Count
        ReadCount = $captured.Count
        CoveragePercent = [int]$coverage.Percent
        CorpusIndexSha256 = $corpus.IndexSha256
        CoordinatorRequestSha256 = $coordinatorRequestSha
        SchemaVersion = $request.SchemaVersion
        DeclaredSlots = $(if ($null -ne $executionPlan) { @($executionPlan.Slots).Count } else { 0 })
        ModelStartBoundKind = $script:ReviewerCohortEntryModelStartBoundKind
        BoundSlotCount = [int]$derivedBound.DeclaredSlotCount
        MaxRealModelStarts = [int]$derivedBound.MaxRealModelStarts
        MaxVerifierAssignments = [int]$derivedBound.MaxVerifierAssignments
        EstimatedModelStarts = $estimatedModelStarts
        EstimatedVerifierAssignments = $estimatedVerifierAssignments
        ModelStarts = 0
        ProviderWrites = 0
        PreflightState = $preflightState
        CohortReady = $cohortReady
        LaunchAuthorizationPath = $(if ($null -ne $launchAuthorization) { $launchAuthorization.TokenPath } else { $null })
        LaunchAuthorizationSha256 = $(if ($null -ne $launchAuthorization) { $launchAuthorization.TokenSha256 } else { $null })
        RunSetId = $(if ($null -ne $launchAuthorization) { $launchAuthorization.SetId } else { $null })
        RunSetSha256 = $(if ($null -ne $launchAuthorization) { $launchAuthorization.DeclarationSha256 } else { $null })
    }
}

function Invoke-ReviewerCohortEntryPreflight {
    <#
    .SYNOPSIS
        Drives the typed coordinator over the published request, as far as a
        no-model entry can be driven, and requires that it consumed nothing.

    .DESCRIPTION
        Reaching a preparation state proves the TYPED reader accepted this
        entry's request in full up to that point - every digest, every path,
        every qualification - without a single model start, slot lease or launch
        token. That is the only proof of acceptance obtainable with no models at
        all, and it is obtained by running the real coordinator rather than by
        re-implementing its reader.

        The default target is 'snapshotVerified', which is the furthest state a
        cohort-entry evidence package can reach ON ITS OWN: it covers
        requestValidated, corpusStaging, corpusPublished and corpusValidated
        through the typed C# corpus stager, the stage-artifact recipe, and then
        the OFFLINE CORPUS SEAL itself - validated, sealed and verified - because
        this builder now emits the production seal recipe the sealer reads. The
        one state beyond it, runSetDeclared, requires an operator-held LAUNCH
        AUTHORIZATION token; this builder mints none, which is the property that
        makes it a no-model tool. An operator who holds one passes -Target
        runSetReady and gets the whole preparation checked. Defaulting to
        runSetReady would make this function claim a proof it cannot produce from
        its own inputs.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$CoordinatorRequestPath,
        [Parameter(Mandatory)][string]$PreparationOutputRoot,
        [ValidateSet('requestValidated', 'corpusValidated', 'recipePlanned', 'snapshotValidateOnly',
            'snapshotVerified', 'runSetReady')]
        [string]$Target = 'snapshotVerified'
    )
    $projectPath = Join-Path $Request.ToolkitRoot 'tools/ShadowRunCoordinator/ShadowRunCoordinator.csproj'
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE600' -Detail "The typed coordinator project '$projectPath' does not exist."
    }
    # An ALREADY BUILT assembly is preferred over 'dotnet run', because
    # 'dotnet run' restores implicitly and a restore reaches the network. This
    # preflight must be runnable on a machine with no feed at all - the same
    # posture every other offline surface here holds - so a prebuilt assembly is
    # used when one exists and the project is only run directly as a fallback
    # for a developer who has not built yet.
    $assembly = Join-Path $Request.ToolkitRoot 'tools/ShadowRunCoordinator/bin/Release/net10.0/ShadowRunCoordinator.dll'
    if (Test-Path -LiteralPath $assembly -PathType Leaf) {
        $output = & dotnet $assembly --request $CoordinatorRequestPath --target $Target 2>&1
    }
    else {
        $output = & dotnet run --project $projectPath --configuration Release -- `
            --request $CoordinatorRequestPath --target $Target 2>&1
    }
    $exit = $LASTEXITCODE
    $text = [string]($output -join [Environment]::NewLine)
    if ($exit -ne 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE600' -Detail "The coordinator exited $exit. $text"
    }
    # The exit code alone is not the proof. The coordinator says which state it
    # reached, in one line, and that line is what is read - an exit of zero from
    # a deliberate halt short of the target is not an accepted entry.
    $reachedPattern = '(?m)^reached ' + [regex]::Escape($Target) + ' sequence=\d+\s*$'
    if ($text -cnotmatch $reachedPattern) {
        New-ReviewerCohortEntryRefusal -Code 'CE600' -Detail "The coordinator did not report reaching $Target. $text"
    }
    if ($text -cmatch '(?i)\bmodelStarts\b\s*[:=]\s*[1-9]') {
        New-ReviewerCohortEntryRefusal -Code 'CE601' -Detail "The coordinator reported a non-zero model start count. $text"
    }
    # Nothing was LAUNCHED AS A SLOT, checked where a launch would have left
    # something rather than where it would have said something. The coordinator
    # writes a launch intent before every child, including the short read-only
    # PowerShell tools that stage a corpus - those consume no slot, no model and
    # no token. A model run is the one that carries a slot: an intent with a slot
    # name, a set id or an expected terminal artifact is a run, and a
    # preparation-only preflight must not have produced one.
    $coordinatorRoot = Join-Path $PreparationOutputRoot 'coordinator'
    $intentRoot = Join-Path $coordinatorRoot 'intents'
    if (Test-Path -LiteralPath $intentRoot -PathType Container) {
        foreach ($intentFile in @(Get-ChildItem -LiteralPath $intentRoot -File -Force -Filter '*.intent.json')) {
            $intent = $null
            try { $intent = [IO.File]::ReadAllText($intentFile.FullName) | ConvertFrom-Json -Depth 16 }
            catch {
                New-ReviewerCohortEntryRefusal -Code 'CE601' `
                    -Detail "The launch intent '$($intentFile.Name)' is unreadable, so this preflight cannot state what it launched."
            }
            $slotName = [string]$intent.slotName
            $setId = [string]$intent.setId
            $terminal = [string]$intent.expectedTerminalPath
            # A SET ID ALONE IS NOT A LAUNCH. Once a run set is declared and
            # verified, the coordinator labels every subsequent launch - including
            # the read-only status child that confirms readiness - with the set it
            # belongs to. Refusing on that would make -PreflightTarget runSetReady
            # permanently unreachable and would report "launched slot '' of set X"
            # for a child that started nothing. What names a run is a SLOT: a slot
            # name, or the terminal artifact a slot is expected to publish.
            if ($slotName -or $terminal) {
                New-ReviewerCohortEntryRefusal -Code 'CE601' `
                    -Detail "The preflight launched slot '$slotName' of set '$setId' expecting '$terminal' in '$($intentFile.Name)'; a preparation-only run launches no slot."
            }
        }
    }
    return $Target
}
