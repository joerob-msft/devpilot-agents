#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Verifies the typed cohort-entry evidence builder against exact wrapper-
    contract fixtures, and sabotages one fixture per historical operator
    assembly incident.

.DESCRIPTION
    Every sabotage case in this suite is a defect that has actually been shipped
    in a hand-assembled Gate5 cohort entry. The suite exists to make each of them
    a named, catalogued refusal instead of a plausible package:

      BOM                  a request round-tripped through an editor that added
                           a byte-order mark, whose recorded digest then
                           described nothing.
      raw repository shape a repo_repository response with a flat 'project' -
                           the raw provider body - where the reviewer reads a
                           reduced identity with a nested projectReference.
      commit aliases       a witness carrying an invented flat 'sourceCommit'
                           instead of the nested lastMergeSourceCommit.commitId.
      singleton arrays     a change set whose single entry was written as an
                           object rather than a one-element array.
      exact-key null       a required field present but null, which every
                           "does the key exist" check passes.
      missing variant      a snapshot that recorded get_changes but not its
                           diff-bearing variant, leaving a read unanswerable.
      resource URI         a file payload served under a URI the wrapper never
                           requested.
      config target        a reviewer configuration validating a branch other
                           than the one the pull request merges into.
      ordinal order        a census in provider paging order rather than in its
                           declared ordinal order.
      read-only source     a published package whose bytes were changed after it
                           was sealed.

    THE SUITE STARTS NO MODEL AND MAKES NO NETWORK CALL. Every fixture is a
    sealed local replay snapshot; a replay has no live seam behind it, so a read
    this builder was not supposed to make cannot silently succeed.
#>
[CmdletBinding()]
param(
    [switch]$IncludePreflight,
    [switch]$KeepSandbox,
    [ValidateSet('requestValidated', 'corpusValidated', 'recipePlanned', 'snapshotValidateOnly',
        'snapshotVerified', 'runSetReady')]
    [string]$PreflightTarget = 'snapshotVerified'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Checks = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1') -Force
. (Join-Path $repoRoot 'src/Agents/reviewer/CohortEntryBuilder.ps1')

$script:Utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Assert-CohortEntry {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Condition
    )
    $script:Checks++
    if (-not $Condition) {
        [void]$script:Failures.Add($Name)
        Write-Host "  FAIL $Name" -ForegroundColor Red
        return
    }
    Write-Host "  ok   $Name" -ForegroundColor DarkGray
}

function Get-CohortEntryRefusalCode {
    <#
    .SYNOPSIS
        The catalogue code one script block refuses under, or '' when it did not
        refuse at all.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action | Out-Null
        return ''
    }
    catch {
        return (Get-ReviewerCohortEntryErrorCode -Message ([string]$_.Exception.Message))
    }
}

function Test-CohortEntryRefusal {
    <#
    .SYNOPSIS
        True when one script block refuses under exactly the expected code.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    return ((Get-CohortEntryRefusalCode -Action $Action) -ceq $Code)
}

function Test-CohortEntryAccepts {
    <#
    .SYNOPSIS
        True when one script block refuses under nothing at all.
    #>
    param([Parameter(Mandatory, Position = 0)][scriptblock]$Action)
    return ((Get-CohortEntryRefusalCode -Action $Action) -ceq '')
}

function Write-CohortEntryJsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$WithBom
    )
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent))
    $text = ConvertTo-Json -InputObject $Value -Depth 32
    $bytes = $script:Utf8.GetBytes($text)
    if ($WithBom) { $bytes = [byte[]]@(0xEF, 0xBB, 0xBF) + $bytes }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-CohortEntryBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function New-CohortEntryTextEnvelope {
    <#
    .SYNOPSIS
        The exact text-content JSON-RPC envelope an MCP text tool answers with.
    #>
    param([Parameter(Mandatory)]$Value)
    $text = ConvertTo-Json -InputObject $Value -Depth 32 -Compress
    return $script:Utf8.GetBytes((ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
                    jsonrpc = '2.0'
                    result = [ordered]@{ content = @([ordered]@{ type = 'text'; text = $text }) }
                })))
}

function New-CohortEntryResourceEnvelope {
    <#
    .SYNOPSIS
        The exact embedded-resource envelope an MCP file read answers with.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$MimeType
    )
    $blob = [Convert]::ToBase64String($script:Utf8.GetBytes($Text))
    return $script:Utf8.GetBytes((ConvertTo-Json -Depth 10 -Compress -InputObject ([ordered]@{
                    jsonrpc = '2.0'
                    result = [ordered]@{
                        content = @([ordered]@{
                                type = 'resource'
                                resource = [ordered]@{ uri = $Uri; mimeType = $MimeType; blob = $blob }
                            })
                    }
                })))
}

function Write-CohortEntrySnapshot {
    <#
    .SYNOPSIS
        Seals one replay snapshot from a list of exact recorded reads, and
        returns its manifest digest.

    .DESCRIPTION
        The manifest digest is computed exactly as the loader recomputes it, so a
        fixture this function writes is a fixture the production loader accepts
        without any test-only allowance.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SnapshotName,
        [Parameter(Mandatory)][object[]]$Reads,
        [Parameter(Mandatory)][hashtable]$Binding
    )
    $snapshot = Join-Path $Root $SnapshotName
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $snapshot 'payloads'))
    $resources = [System.Collections.Generic.List[object]]::new()
    $summaries = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($read in $Reads) {
        $index++
        $relative = "payloads/r$($index.ToString('000', [Globalization.CultureInfo]::InvariantCulture)).json"
        [IO.File]::WriteAllBytes((Join-Path $snapshot $relative), [byte[]]$read.Bytes)
        $key = Get-AgentReplayRequestKey -Name $read.Tool -Arguments $read.Arguments
        $sha = Get-CohortEntryBytesSha256 -Bytes ([byte[]]$read.Bytes)
        [void]$resources.Add([ordered]@{
                tool = $read.Tool
                arguments = $read.Arguments
                requestSha256 = $key.Key
                payloadFile = $relative
                payloadSha256 = $sha
                payloadByteLength = [int]$read.Bytes.Length
            })
        [void]$summaries.Add([ordered]@{
                tool = $read.Tool
                requestSha256 = $key.Key
                payloadFile = $relative
                payloadSha256 = $sha
                payloadByteLength = [long]$read.Bytes.Length
                arguments = $read.Arguments
            })
    }
    $bindingBlock = [ordered]@{
        organization = $Binding.Organization
        project = $Binding.Project
        repositoryId = $Binding.RepositoryId
        pullRequestId = $Binding.PullRequestId
        sourceCommit = $Binding.SourceCommit
        targetCommit = $Binding.TargetCommit
        changeSetSha256 = $Binding.ChangeSetSha256
    }
    $zero = '0' * 64
    $bindingsBlock = [ordered]@{ configSha256 = $zero; scriptSha256 = $zero; promptSha256 = $zero; models = @() }
    $capturedUtc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $digestInput = [ordered]@{
        schemaVersion = 1
        kind = 'agent-replay-snapshot'
        snapshotId = $SnapshotName
        capturedUtc = $capturedUtc
        provider = 'ado'
        binding = $bindingBlock
        bindings = $bindingsBlock
        resources = [object[]]$summaries.ToArray()
    }
    $digestBytes = @($script:Utf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $digestInput)))
    $digest = Get-CohortEntryBytesSha256 -Bytes $digestBytes
    $manifest = [ordered]@{
        schemaVersion = 1
        kind = 'agent-replay-snapshot'
        snapshotId = $SnapshotName
        capturedUtc = $capturedUtc
        provider = 'ado'
        binding = $bindingBlock
        bindings = $bindingsBlock
        resources = [object[]]$resources.ToArray()
        manifestDigest = $digest
    }
    Write-CohortEntryJsonFile -Path (Join-Path $snapshot 'manifest.json') -Value $manifest
    return $digest
}

function Get-CohortEntryGitLine {
    <#
    .SYNOPSIS
        One line of git output, or the empty string when git wrote nothing.

    .DESCRIPTION
        A command that writes nothing at all yields PowerShell's automation null,
        and casting THAT to [string] produces $null rather than '' - so the direct
        cast turns 'git resolved nothing' into a null-reference crash. Joining out
        of an explicitly null-filtered array keeps the empty answer an empty
        answer, which is what every caller here has to be able to read.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $emitted = [string[]]@(& git @Arguments 2>$null | Where-Object { $null -ne $_ })
    return [string]::Join('', $emitted).Trim()
}

$script:CohortEntryCreatedRefs = @()

function Get-CohortEntryToolkitRef {
    <#
    .SYNOPSIS
        A ref that actually resolves to the checkout's head commit.

    .DESCRIPTION
        'rev-parse --abbrev-ref HEAD' answers the literal word 'HEAD' on a
        detached checkout, and 'refs/heads/HEAD' resolves nowhere - which is what
        every hosted pull_request run gets, because the runner checks out a merge
        commit rather than a branch. Pinning that ref made the builder refuse its
        own toolkit on CI while passing on every developer machine.

        A ref pointing AT the head is asked for first, so an attached checkout
        still pins the branch it is on. When no ref points at it - a detached
        merge commit that exists only in the runner's clone - one is CREATED at
        that commit, under a name of this fixture's own. 'HEAD' itself would
        resolve, but the request schema requires a ref path, so pinning it would
        trade a crash for a malformed-field refusal in the same scenario.

        A created ref is RECORDED, because this helper also runs against the real
        checkout the suite lives in - and in a worktree a ref lands in the shared
        common store, visible to every other worktree and holding the commit
        against gc forever. A fixture leaves nothing behind in a repository it
        did not make, so Remove-CohortEntryCreatedRef takes each one back.

        The name is unique per call and the creation states an all-zero expected
        old value, so it can only ever SUCCEED against a name nothing holds. A
        fixed name would let this overwrite a ref another worktree or a
        concurrent run was already using, and the cleanup - which can only check
        the value it wrote - would then delete a ref it did not create.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][string]$Head
    )
    $branch = Get-CohortEntryGitLine -Arguments @('-C', $ToolkitRoot, 'rev-parse', '--abbrev-ref', 'HEAD')
    if ($branch -cne 'HEAD' -and $branch -cne '') {
        $branchRef = "refs/heads/$branch"
        $resolved = Get-CohortEntryGitLine -Arguments @('-C', $ToolkitRoot, 'rev-parse', '--verify', '--quiet',
            "$branchRef^{commit}")
        if ($resolved -ceq $Head) { return $branchRef }
    }
    $pointing = [string[]]@(& git -C $ToolkitRoot for-each-ref --points-at $Head --format='%(refname)' 2>$null |
            Where-Object { $null -ne $_ -and ([string]$_).Trim() -cne '' })
    if ($pointing.Count -gt 0) { return ([string]$pointing[0]).Trim() }
    $created = 'refs/cohort-entry-fixture/' + [guid]::NewGuid().ToString('N')
    # The all-zero old value is git's way of saying 'this must not exist yet'.
    # Creation is therefore also the ownership proof the deletion rests on - so
    # the CREATE's own exit status is what is checked, not merely that the name
    # now resolves to the right commit. A name that already existed at this very
    # commit resolves identically while belonging to somebody else, and deleting
    # it later on the strength of that reading would take another holder's ref.
    & git -C $ToolkitRoot update-ref $created $Head ('0' * 40) 2>&1 | Out-Null
    $createdOk = ($LASTEXITCODE -eq 0)
    # Recorded the moment the create succeeds, BEFORE the read below. Ownership
    # is established by that exit status; a ref another process moves in between
    # would otherwise be created, owned, and then thrown away with nothing left
    # to retry it or name it.
    if ($createdOk) {
        $script:CohortEntryCreatedRefs += , [pscustomobject]@{ Root = $ToolkitRoot; Ref = $created; Commit = $Head }
    }
    $createdCommit = Get-CohortEntryGitLine -Arguments @('-C', $ToolkitRoot, 'rev-parse', '--verify', '--quiet',
        "$created^{commit}")
    if (-not $createdOk -or $createdCommit -cne $Head) {
        throw "No ref points at '$Head' in '$ToolkitRoot' and one could not be created there."
    }
    return $created
}

function Remove-CohortEntryCreatedRef {
    <#
    .SYNOPSIS
        Deletes every ref this fixture created, and only those.

    .DESCRIPTION
        Each name was created against an all-zero expected old value, so nothing
        else held it at creation time; the delete then states the commit it is
        expected to still hold. A ref something else moved in the meantime is
        left alone rather than removed on the strength of its name.

        A delete that does not take - a lock, a permission, a ref another process
        moved - keeps its record rather than dropping it, so a later call retries
        it and the suite can say what it left behind. Silently clearing the record
        would turn a failed cleanup into a fixture that holds a commit in an
        operator's repository against gc forever, with nothing left to say so.
    #>
    $remaining = @()
    foreach ($record in $script:CohortEntryCreatedRefs) {
        & git -C $record.Root update-ref -d $record.Ref $record.Commit 2>&1 | Out-Null
        # Asked for RAW, unpeeled: a ref moved to a tag or a blob no longer
        # answers '<ref>^{commit}', and reading absence from that would drop the
        # record while the ref itself still sits there pinning an object.
        $still = Get-CohortEntryGitLine -Arguments @('-C', $record.Root, 'rev-parse', '--verify', '--quiet',
            $record.Ref)
        if ($still -cne '') { $remaining += , $record }
    }
    $script:CohortEntryCreatedRefs = @($remaining)
}

function Set-CohortEntryV3RuleState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)

    $eAcute = [char]0x00E9
    $lambda = [char]0x03BB
    $State.SchemaVersion = 3
    $State.RuleRepositoryId = '99999999-8888-7777-6666-555555555555'
    $State.RuleSection = "## Claim ownership - caf$eAcute"
    $State.RuleText = (
        "# Engineering guidance`r`n`r`n" +
        "Whole-file preface with $lambda.`r`n`r`n" +
        "$($State.RuleSection)`r`n`r`n" +
        "Owner Ren$eAcute reviews this rule.`r`n`r`n" +
        "### Examples`r`n`r`n" +
        "Preserve CRLF and UTF-8 bytes in the corpus.`r`n`r`n" +
        "## Unrelated rule`r`n`r`n" +
        "This text is outside the pinned section.`r`n")
}

function New-CohortEntryFixture {
    <#
    .SYNOPSIS
        A complete, exact, self-consistent fixture: a toolkit repository, a
        reviewer configuration, a pinned rule bundle, a sealed snapshot and a
        versioned operator request.

    .DESCRIPTION
        -Mutate receives the fixture's mutable parts before anything is sealed,
        so a sabotage case changes ONE thing and inherits every other property
        from the exact fixture. A sabotage that had to restate the whole fixture
        would drift from it, and would eventually pass for the wrong reason.
    #>
    param(
        [Parameter(Mandatory)][string]$Sandbox,
        [scriptblock]$Mutate,
        [string]$RealToolkitRoot = ''
    )
    $organization = 'fabrikam'
    $project = 'Contoso'
    $repositoryName = 'toolkit'
    $repositoryId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $pullRequestId = 4242
    $sourceCommit = 'a' * 40
    $commonCommit = 'b' * 40
    $targetCommit = 'c' * 40
    $ruleCommit = 'd' * 40
    $targetRefName = 'refs/heads/main'

    $state = [ordered]@{
        Organization = $organization
        Project = $project
        RepositoryName = $repositoryName
        RepositoryId = $repositoryId
        PullRequestId = $pullRequestId
        SourceCommit = $sourceCommit
        CommonCommit = $commonCommit
        TargetCommit = $targetCommit
        RuleCommit = $ruleCommit
        TargetRefName = $targetRefName
        ConfigTargetRefName = 'refs/heads/main'
        ConfigTargetKeyName = 'targetRefName'
        RepositoryBody = [ordered]@{
            id = $repositoryId
            name = $repositoryName
            projectReference = [ordered]@{ id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; name = $project }
        }
        PullRequestBody = [ordered]@{
            pullRequestId = $pullRequestId
            status = 'active'
            isDraft = $false
            targetRefName = $targetRefName
            sourceRefName = 'refs/heads/feature'
            lastMergeSourceCommit = [ordered]@{ commitId = $sourceCommit }
            lastMergeTargetCommit = [ordered]@{ commitId = $targetCommit }
            lastMergeCommit = [ordered]@{ commitId = $commonCommit }
        }
        BranchBody = [ordered]@{ name = $targetRefName; objectId = $targetCommit }
        ChangesBody = [ordered]@{
            iterationId = 3
            # The wrapper answers these on EVERY change response and writes them
            # as zero to mean "there is no next page". A fixture without them is
            # a shape no provider produces, and a completeness check written
            # against it can pass while refusing every real capture.
            nextSkip = 0
            nextTop = 0
            changes = @(
                [ordered]@{ changeId = 1; changeType = 'Edit'; item = [ordered]@{ path = '/src/a.ps1'; isFolder = $false } },
                [ordered]@{ changeId = 2; changeType = 'Add'; item = [ordered]@{ path = '/src/b.ps1'; isFolder = $false } },
                [ordered]@{ changeId = 3; changeType = 'Delete'; item = [ordered]@{ path = '/src/z-old.ps1'; isFolder = $false } }
            )
        }
        # The diff variant answers the SAME change set with line blocks attached.
        # Served as its own body so a sabotage case can move a span without also
        # moving the census the span belongs to.
        DiffChangesBody = [ordered]@{
            iterationId = 3
            nextSkip = 0
            nextTop = 0
            changes = @(
                [ordered]@{
                    changeId = 1; changeType = 'Edit'; item = [ordered]@{ path = '/src/a.ps1'; isFolder = $false }
                    diff = [ordered]@{
                        path = '/src/a.ps1'
                        lineDiffBlocks = @(
                            [ordered]@{ changeType = 0; originalLineNumberStart = 1; originalLinesCount = 1; modifiedLineNumberStart = 1; modifiedLinesCount = 1 },
                            [ordered]@{ changeType = 1; originalLineNumberStart = 0; originalLinesCount = 0; modifiedLineNumberStart = 2; modifiedLinesCount = 2 }
                        )
                    }
                },
                [ordered]@{
                    changeId = 2; changeType = 'Add'; item = [ordered]@{ path = '/src/b.ps1'; isFolder = $false }
                    diff = [ordered]@{
                        path = '/src/b.ps1'
                        lineDiffBlocks = @(
                            [ordered]@{ changeType = 1; originalLineNumberStart = 0; originalLinesCount = 0; modifiedLineNumberStart = 1; modifiedLinesCount = 2 }
                        )
                    }
                },
                [ordered]@{ changeId = 3; changeType = 'Delete'; item = [ordered]@{ path = '/src/z-old.ps1'; isFolder = $false } }
            )
        }
        # The live wrapper answers a BARE array of threads, so that is what the
        # default fixture is. The envelope shapes are exercised as separate cases.
        ThreadsBody = @(
            [ordered]@{ id = 1; status = 'active'; comments = @([ordered]@{ id = 1; content = 'a comment' }) }
        )
        FileTexts = [ordered]@{
            '/src/a.ps1' = "function A {`n    'right hand'`n}`n"
            '/src/b.ps1' = "function B {`n    'added'`n}`n"
        }
        BaselineTexts = [ordered]@{ '/src/a.ps1' = "function A { 'left hand' }`n" }
        RuleText = "# Review rules`n`nOne pinned section.`n"
        RuleOrganization = $organization
        RuleProject = $project
        RuleRepositoryId = $repositoryId
        RuleSection = '## Review rules'
        RuleReadRepositoryOverride = ''
        RealToolkitRoot = $RealToolkitRoot
        RuleServedText = ''
        RuleResourceUri = ''
        OmitDiffVariant = $false
        # The thread read the fixture RECORDS. It defaults to the one production
        # value so the sealed corpus answers the plan exactly; a sabotage moves
        # it to prove that a corpus recorded one thread off the live cycle's own
        # read is refused rather than silently replayed.
        ThreadListTop = (Get-ReviewerThreadListTop)
        # The other four keys of the same recorded read, so a sabotage can move
        # exactly one of them and prove each is matched on its own.
        ThreadReadProjectOverride = ''
        ThreadReadRepositoryOverride = ''
        ThreadReadPullRequestOverride = 0
        # What the operator REQUEST caps threads at, as opposed to what the read
        # asks for. They are different numbers with different owners.
        MaxThreads = (Get-ReviewerThreadListTop)
        # The change reads the fixture RECORDS, on the same footing as the thread
        # read above: the production page by default, plus the include flags and
        # the key spellings, so a sabotage can move exactly one and prove each is
        # matched on its own.
        ChangeListTop = (Get-ReviewerChangeListTop)
        ChangeReadProjectOverride = ''
        ChangeReadRepositoryOverride = ''
        ChangeReadPullRequestOverride = 0
        ChangeReadIncludeDiffs = $true
        ChangeReadIncludeLineContent = $true
        ChangeReadTopAsString = $false
        RequestWithBom = $false
        MaxChangedFiles = 50
        MaxFileBytes = 65536
        MaxSiblingFiles = 1
        MinCoveragePercent = 60
        # -- v2 execution plan -------------------------------------------
        # Off by default, so every case written before the plan existed keeps
        # exercising the v1 preparation-only request byte for byte.
        SchemaVersion = 1
        WithExecutionPlan = $false
        ConfigDeclaresModels = $true
        ConfigVerificationEnabled = $true
        # A raw override, so a case can write the STRING "false" the way a hand
        # edited reviewer configuration would - which PowerShell reads as $true.
        ConfigVerificationEnabledRaw = $null
        ConfigSpecialistModel = ''
        ConfigVerifierModel = ''
        MutateExecutionPlan = $null
        MutateRequest = $null
        ExecutionPlanIsNull = $false
        PlannedRunCount = 2
        # The four attempt factors the fixture runner declares, and from which
        # the shipping producer derives this fixture's bound. Deliberately not
        # the production numbers.
        FixtureGeneralistAttempts = 2
        FixtureSpecialistAttempts = 3
        FixtureVerifierAttempts = 1
        FixtureVerifierCeiling = 7
        FixtureVerifierPolicyRuns = 5
        # Names the shipping agent instead of the fixture one. A run set
        # declaration pins the toolkit repository the reviewer script lives in
        # and refuses a script outside it, so the single case that declares a
        # real set has to name the real agent - and gets the real bound with it.
        UseRealReviewerScript = $false
    }
    if ($Mutate) { & $Mutate $state }

    # -- toolkit ---------------------------------------------------------
    # The preflight proof needs the REAL toolkit, because runSetReady is reached
    # by the typed coordinator that lives in it. Every other case is served by a
    # throwaway repository so the suite never depends on this checkout's history.
    $toolkit = ''
    $toolkitHead = ''
    $toolkitRef = 'refs/heads/fixture'
    if ($state.RealToolkitRoot) {
        $toolkit = [string]$state.RealToolkitRoot
        $toolkitHead = ([string](& git -C $toolkit rev-parse HEAD)).Trim()
        $toolkitRef = Get-CohortEntryToolkitRef -ToolkitRoot $toolkit -Head $toolkitHead
    }
    else {
        $toolkit = Join-Path $Sandbox 'toolkit'
        [void](New-Item -ItemType Directory -Force -Path $toolkit)
        Push-Location $toolkit
        try {
            & git init --quiet --initial-branch=fixture . 2>&1 | Out-Null
            & git config user.email 'fixture@example.invalid' | Out-Null
            & git config user.name 'Fixture' | Out-Null
            Set-Content -LiteralPath (Join-Path $toolkit 'README.md') -Value 'fixture toolkit' -NoNewline
            # The REAL stage producer contract schema, copied byte for byte. The
            # coordinator request binds its digest, so a fixture that invented a
            # stand-in would prove the binding against a file nobody ships.
            $schemaDir = Join-Path $toolkit 'src/Agents/reviewer/schemas'
            [void](New-Item -ItemType Directory -Force -Path $schemaDir)
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../src/Agents/reviewer/schemas/reviewer.stage-producer-contracts.v1.json') `
                -Destination (Join-Path $schemaDir 'reviewer.stage-producer-contracts.v1.json') -Force
            # The REAL source-transport policy, byte for byte. The builder puts
            # these bytes in the corpus and the seal derives the transport
            # artifact under them; a fixture stand-in would prove the derivation
            # against rules the production sealer never applies.
            $policyDir = Join-Path $toolkit 'src/Agents/reviewer/source/v1'
            [void](New-Item -ItemType Directory -Force -Path $policyDir)
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../src/Agents/reviewer/source/v1/policy.json') `
                -Destination (Join-Path $policyDir 'policy.json') -Force
            # One reviewer prompt asset, because the coordinator binds a run to
            # the set of them and refuses a toolkit that ships none.
            [IO.File]::WriteAllBytes(
                (Join-Path $toolkit 'src/Agents/reviewer/review-cycle.prompt.md'),
                [System.Text.UTF8Encoding]::new($false).GetBytes("# fixture review cycle`n"))
            # The REAL model-start bound producer and the REAL sources it derives
            # from, copied byte for byte. The builder does not compute a bound; it
            # invokes this producer out of the toolkit the request pins, so a
            # fixture toolkit that shipped a stand-in producer would prove the
            # binding against arithmetic nobody runs.
            $harnessSource = Join-Path $PSScriptRoot '../src/DevPilot.AgentHarness'
            $harnessTarget = Join-Path $toolkit 'src/DevPilot.AgentHarness'
            [void](New-Item -ItemType Directory -Force -Path $harnessTarget)
            Copy-Item -Path (Join-Path $harnessSource '*') -Destination $harnessTarget -Recurse -Force
            foreach ($module in @('QualificationPreflight.ps1', 'ReplayQualification.ps1', 'ModelStartCensus.ps1',
                    'ModelStartCensusManifest.ps1', 'ReviewerBaseContract.ps1')) {
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../src/Agents/reviewer/$module") `
                    -Destination (Join-Path $toolkit "src/Agents/reviewer/$module") -Force
            }
            $toolsTarget = Join-Path $toolkit 'tools'
            [void](New-Item -ItemType Directory -Force -Path $toolsTarget)
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'New-ShadowModelStartBound.ps1') `
                -Destination (Join-Path $toolsTarget 'New-ShadowModelStartBound.ps1') -Force
            & git add -A | Out-Null
            & git commit --quiet -m 'fixture' | Out-Null
            $toolkitHead = ([string](& git rev-parse HEAD)).Trim()
        }
        finally { Pop-Location }
    }

    # -- reviewer configuration and rule bundle --------------------------
    # The models the plan will be checked against are DERIVED from the shared
    # registry here too, by family rather than by name. A fixture that wrote
    # 'claude-opus-5' would go stale the day the registry moves and would then
    # be testing that the builder accepts a retired model.
    $registryPair = [string[]]@()
    $fixtureSpecialist = ''
    $fixtureVerifier = ''
    if ($state.WithExecutionPlan -or $state.ConfigSpecialistModel -or $state.ConfigVerifierModel) {
        # Read through the production registry accessor rather than importing the
        # harness again here, so the fixture exercises the same flattening the
        # builder does instead of a private copy that could drift from it.
        $registry = Get-ReviewerCohortEntryModelRegistry
        $supportedModels = [string[]]@($registry.Supported)
        $registryPair = [string[]]@($registry.GeneralistPair)
        $fixtureSpecialist = [string](@($supportedModels | Where-Object { $_ -cmatch '^claude-sonnet-' }) | Select-Object -First 1)
        $fixtureVerifier = [string](@($supportedModels | Where-Object { $_ -cmatch '^gpt-' -and $_ -cnotmatch '(?:-mini|-codex)' }) | Select-Object -First 1)
    }
    $reviewSection = [ordered]@{ $state.ConfigTargetKeyName = $state.ConfigTargetRefName }
    if (($state.WithExecutionPlan -or $state.ConfigSpecialistModel) -and $state.ConfigDeclaresModels) {
        $specialistForConfig = if ($state.ConfigSpecialistModel) { [string]$state.ConfigSpecialistModel } else { $fixtureSpecialist }
        $verifierForConfig = if ($state.ConfigVerifierModel) { [string]$state.ConfigVerifierModel } else { $fixtureVerifier }
        $reviewSection['conventionSpecialistModel'] = $specialistForConfig
        $verificationEnabledValue = if ($null -ne $state.ConfigVerificationEnabledRaw) {
            $state.ConfigVerificationEnabledRaw
        }
        else { [bool]$state.ConfigVerificationEnabled }
        $reviewSection['verification'] = [ordered]@{
            enabled = $verificationEnabledValue
            conventionVerifierModel = $verifierForConfig
        }
    }
    $configPath = Join-Path $Sandbox 'reviewer.config.json'
    $configValue = [ordered]@{
        repository = [ordered]@{
            organization = $state.Organization
            project = $state.Project
            name = $state.RepositoryName
            id = $state.RepositoryId
        }
        review = $reviewSection
    }
    if ($state.UseRealReviewerScript) {
        # A run set declaration loads this file through the agent's own loader,
        # which needs the whole shape rather than the handful of keys the builder
        # reads. The shipped sample is that shape, so the one case that declares
        # a real set starts from it instead of from a second hand-written copy
        # that could drift from what the agent actually accepts.
        $sampleRead = @(([IO.File]::ReadAllText((Join-Path $toolkit 'samples/reviewer-ado.config.json'))) |
                ConvertFrom-Json -Depth 32 -AsHashtable)
        $sample = [hashtable]$sampleRead[0]
        # The sample's convention sources name the sample's own organization, and
        # the agent refuses a source outside the reviewed repository's. The
        # section cannot simply go, because naming a convention specialist
        # requires it - so it is rewritten to this fixture's organization, with
        # a pack whose globs match nothing. The catalogue is then present and
        # consistent while selecting no pack, which keeps this case about the
        # launch authorization rather than about convention transport.
        $sample['repoConventions'] = [ordered]@{
            conventionDocPaths = @()
            customRules = ''
            conventionPacks = [ordered]@{
                schemaVersion = 1
                requireAllSourcesReferenced = $true
                authoritativeSources = [ordered]@{
                    transportVersion = 1
                    maxTotalBytes = 1024
                    sources = @(
                        [ordered]@{
                            name = 'fixture-source'
                            organization = $state.Organization
                            project = $state.Project
                            repositoryId = '22222222-2222-3333-4444-555555555555'
                            path = '/docs/conventions.md'
                            branch = 'main'
                            maxBytes = 1024
                        }
                    )
                }
                packs = @(
                    [ordered]@{
                        name = 'fixture-pack'
                        priority = 100
                        changedPathGlobs = @('never-matches/**/*.nope')
                        authoritativeSourceRefs = @('fixture-source')
                        repositorySources = @([ordered]@{ path = '/docs/rules/review.md'; maxBytes = 1024 })
                        maxBytes = 4096
                    }
                )
            }
        }
        foreach ($key in @($configValue.Keys)) {
            if ($key -ceq 'review') {
                foreach ($reviewKey in @($reviewSection.Keys)) {
                    if ($reviewKey -ceq 'verification' -and $sample['review'].ContainsKey('verification')) {
                        # Merged rather than replaced: the fixture states which
                        # models verify and whether verification runs, and the
                        # sample states the shape the agent's loader requires.
                        foreach ($inner in @($reviewSection[$reviewKey].Keys)) {
                            $sample['review']['verification'][$inner] = $reviewSection[$reviewKey][$inner]
                        }
                        continue
                    }
                    $sample['review'][$reviewKey] = $reviewSection[$reviewKey]
                }
            }
            else { $sample[$key] = $configValue[$key] }
        }
        $configValue = $sample
    }
    Write-CohortEntryJsonFile -Path $configPath -Value $configValue

    $rulePath = '/docs/rules/review.md'
    $pinnedRuleText = [string]$state.RuleText
    if ([int]$state.SchemaVersion -ge 3) {
        $cut = Get-ReviewerMarkdownSection -Text ([string]$state.RuleText) -Heading ([string]$state.RuleSection)
        if (-not $cut.Found) { throw "The v3 fixture rule text does not contain '$($state.RuleSection)'." }
        $pinnedRuleText = [string]$cut.Text
    }
    $ruleBytes = $script:Utf8.GetBytes($pinnedRuleText)
    $declarationPath = Join-Path $Sandbox 'rule-bundle.json'
    Write-CohortEntryJsonFile -Path $declarationPath -Value ([ordered]@{
            sourceKind = 'pinnedRepositorySections'
            sections = @([ordered]@{ path = $rulePath; commit = $state.RuleCommit })
        })
    $declarationSha = (Get-FileHash -LiteralPath $declarationPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $sealKeyPath = Join-Path $Sandbox 'seal.key'
    $keyBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($keyBytes)
    [IO.File]::WriteAllBytes($sealKeyPath, $script:Utf8.GetBytes('raw:' + [Convert]::ToBase64String($keyBytes)))
    $runSetKeyPath = Join-Path $Sandbox 'runset.key'
    [IO.File]::WriteAllBytes($runSetKeyPath, $script:Utf8.GetBytes('raw:' + [Convert]::ToBase64String($keyBytes)))

    # -- the sealed snapshot ---------------------------------------------
    # The wrapper answers an embedded resource under the repository-relative
    # PATH. The fixture answers under the same URI a live wrapper does, so a
    # fixture that passes is evidence about the live contract rather than about
    # a URI the fixture invented for itself.
    $uriFor = {
        param([string]$Path)
        $Path
    }
    $reads = [System.Collections.Generic.List[object]]::new()
    [void]$reads.Add(@{
            Tool = 'repo_pull_request'
            Arguments = [ordered]@{ action = 'get'; project = $state.Project; repositoryId = $state.RepositoryName; pullRequestId = $state.PullRequestId }
            Bytes = (New-CohortEntryTextEnvelope -Value $state.PullRequestBody)
        })
    [void]$reads.Add(@{
            Tool = 'repo_repository'
            Arguments = [ordered]@{ action = 'get'; project = $state.Project; repositoryNameOrId = $state.RepositoryId }
            Bytes = (New-CohortEntryTextEnvelope -Value $state.RepositoryBody)
        })
    [void]$reads.Add(@{
            Tool = 'repo_branch'
            Arguments = [ordered]@{ action = 'get'; project = $state.Project; repositoryId = $state.RepositoryId; branchName = 'main' }
            Bytes = (New-CohortEntryTextEnvelope -Value $state.BranchBody)
        })
    $changeProject = $(if ($state.ChangeReadProjectOverride) { $state.ChangeReadProjectOverride } else { $state.Project })
    $changeRepository = $(if ($state.ChangeReadRepositoryOverride) { $state.ChangeReadRepositoryOverride } else { $state.RepositoryName })
    $changePr = $(if ([int]$state.ChangeReadPullRequestOverride -gt 0) { [int]$state.ChangeReadPullRequestOverride } else { $state.PullRequestId })
    $changeTop = $(if ($state.ChangeReadTopAsString) { [string]$state.ChangeListTop } else { [int]$state.ChangeListTop })
    [void]$reads.Add(@{
            Tool = 'repo_pull_request'
            Arguments = [ordered]@{ action = 'get_changes'; project = $changeProject; repositoryId = $changeRepository; pullRequestId = $changePr; top = $changeTop }
            Bytes = (New-CohortEntryTextEnvelope -Value $state.ChangesBody)
        })
    if (-not $state.OmitDiffVariant) {
        $diffArguments = [ordered]@{ action = 'get_changes'; project = $changeProject; repositoryId = $changeRepository; pullRequestId = $changePr }
        if ($state.ChangeReadIncludeDiffs) { $diffArguments['includeDiffs'] = $true }
        if ($state.ChangeReadIncludeLineContent) { $diffArguments['includeLineContent'] = $true }
        $diffArguments['top'] = $changeTop
        [void]$reads.Add(@{
                Tool = 'repo_pull_request'
                Arguments = $diffArguments
                Bytes = (New-CohortEntryTextEnvelope -Value $state.DiffChangesBody)
            })
    }
    [void]$reads.Add(@{
            Tool = (Get-ReviewerThreadListToolName)
            Arguments = [ordered]@{
                action = 'list'
                project = $(if ($state.ThreadReadProjectOverride) { $state.ThreadReadProjectOverride } else { $state.Project })
                repositoryId = $(if ($state.ThreadReadRepositoryOverride) { $state.ThreadReadRepositoryOverride } else { $state.RepositoryName })
                pullRequestId = $(if ([int]$state.ThreadReadPullRequestOverride -gt 0) { [int]$state.ThreadReadPullRequestOverride } else { $state.PullRequestId })
                top = $state.ThreadListTop
            }
            Bytes = (New-CohortEntryTextEnvelope -Value $state.ThreadsBody)
        })
    foreach ($path in @($state.FileTexts.Keys)) {
        [void]$reads.Add(@{
                Tool = 'repo_file'
                Arguments = [ordered]@{ action = 'get_content'; project = $state.Project; repositoryId = $state.RepositoryId; path = $path; versionType = 'Commit'; version = $state.SourceCommit }
                Bytes = (New-CohortEntryResourceEnvelope -Text ([string]$state.FileTexts[$path]) -Uri (& $uriFor $path) -MimeType 'text/plain')
            })
    }
    foreach ($path in @($state.BaselineTexts.Keys)) {
        [void]$reads.Add(@{
                Tool = 'repo_file'
                Arguments = [ordered]@{ action = 'get_content'; project = $state.Project; repositoryId = $state.RepositoryId; path = $path; versionType = 'Commit'; version = $state.CommonCommit }
                Bytes = (New-CohortEntryResourceEnvelope -Text ([string]$state.BaselineTexts[$path]) -Uri (& $uriFor $path) -MimeType 'text/plain')
            })
    }
    $ruleUri = if ($state.RuleResourceUri) { [string]$state.RuleResourceUri } else { (& $uriFor $rulePath) }
    $ruleServed = if ($state.RuleServedText) { [string]$state.RuleServedText } else { [string]$state.RuleText }
    $ruleReadRepositoryId = if ($state.RuleReadRepositoryOverride) {
        [string]$state.RuleReadRepositoryOverride
    }
    elseif ([int]$state.SchemaVersion -ge 3) { [string]$state.RuleRepositoryId }
    else { [string]$state.RepositoryId }
    [void]$reads.Add(@{
            Tool = 'repo_file'
            Arguments = [ordered]@{ action = 'get_content'; project = $state.Project; repositoryId = $ruleReadRepositoryId; path = $rulePath; versionType = 'Commit'; version = $state.RuleCommit }
            Bytes = (New-CohortEntryResourceEnvelope -Text $ruleServed -Uri $ruleUri -MimeType 'text/plain')
        })

    $replayRoot = Join-Path $Sandbox 'replay'
    [void](New-Item -ItemType Directory -Force -Path $replayRoot)
    $manifestDigest = Write-CohortEntrySnapshot -Root $replayRoot -SnapshotName 'fixture' -Reads ([object[]]$reads.ToArray()) `
        -Binding @{
        Organization = $state.Organization
        Project = $state.Project
        RepositoryId = $state.RepositoryId
        PullRequestId = $state.PullRequestId
        SourceCommit = $state.SourceCommit
        TargetCommit = $state.TargetCommit
        ChangeSetSha256 = '0' * 64
    }

    # -- the operator request --------------------------------------------
    $outputRoot = Join-Path $Sandbox 'private/entry'
    $requestPath = Join-Path $Sandbox 'entry-request.json'
    $executionPlan = $null
    if ($state.WithExecutionPlan) {
        # A real file, hashed for real: the plan pins the reviewed script by
        # digest and the builder re-hashes what is on disk.
        #
        # It also DECLARES its attempt bounds the way the shipping runner does,
        # because the model-start bound is read out of the runner's own sources.
        # The numbers are deliberately not the production ones: a fixture that
        # reused them could not tell a bound that was derived from one that was
        # written down. The suite recomputes the expected total from these same
        # four factors, so the assertion proves the formula rather than a total.
        $reviewerScriptPath = Join-Path $Sandbox 'Start-ReviewerAgent.fixture.ps1'
        [IO.File]::WriteAllBytes($reviewerScriptPath, $script:Utf8.GetBytes(@(
                    'param()'
                    '# fixture reviewer entry point'
                    "`$script:ReviewerMarkerRetryAttempts = $($state.FixtureGeneralistAttempts)"
                    "`$script:ReviewerConventionSpecialistMarkerRetryAttempts = $($state.FixtureSpecialistAttempts)"
                    'switch ($role) {'
                    "    'verifier' { $($state.FixtureVerifierAttempts) }"
                    '}'
                    ''
                ) -join "`n"))
        if ($state.UseRealReviewerScript) {
            $reviewerScriptPath = [string]([IO.Path]::GetFullPath(
                    (Join-Path $toolkit 'src\Agents\reviewer\Start-ReviewerAgent.ps1')))
        }
        # The two siblings the runner bound is read from: the launch ceiling the
        # runner narrows policy by, and the policy that states how many verifier
        # launches one run may make.
        [IO.File]::WriteAllBytes((Join-Path $Sandbox 'CrossVerification.ps1'), $script:Utf8.GetBytes(@(
                    "`$script:ReviewerVerificationMaxVerifierRuns = $($state.FixtureVerifierCeiling)"
                    ''
                ) -join "`n"))
        $policyDirectory = Join-Path $Sandbox 'verification/v1'
        [void](New-Item -ItemType Directory -Force -Path $policyDirectory)
        [IO.File]::WriteAllBytes((Join-Path $policyDirectory 'policy.json'),
            $script:Utf8.GetBytes("{`n  `"maxVerifierRuns`": $($state.FixtureVerifierPolicyRuns)`n}`n"))
        # No token path is written here, and none may be: the builder derives the
        # one path a launch authorization can occupy from the output root, and
        # refuses a request that names its own. A fixture that supplied one would
        # be testing the defect this contract exists to remove.
        $executionPlan = [ordered]@{
            shadowSlotsEnabled = $true
            reviewerScript = [ordered]@{
                path = $reviewerScriptPath
                sha256 = (Get-FileHash -LiteralPath $reviewerScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            models = [ordered]@{
                generalistPairSource = 'derivedFromSupportedModelRegistry'
                generalistPair = [object[]]@($registryPair)
                conventionSpecialistModel = $fixtureSpecialist
                conventionVerifierModel = $fixtureVerifier
            }
            timeouts = [ordered]@{
                perCallTimeoutSeconds = 900
                slotTimeoutSeconds = 5400
                progressTimeoutSeconds = 1200
                supervisionGraceSeconds = 120
            }
            slots = @(
                [ordered]@{
                    name = 'slot1'
                    stateDirName = 'slot1-state'
                    terminalName = 'slot1-terminal.json'
                    modelPlan = [ordered]@{ bindSealedArguments = $false; opaqueArguments = @() }
                },
                [ordered]@{
                    name = 'slot2'
                    stateDirName = 'slot2-state'
                    terminalName = 'slot2-terminal.json'
                    modelPlan = [ordered]@{ bindSealedArguments = $false; opaqueArguments = @() }
                }
            )
            reconciliation = [ordered]@{
                reconciliationEnabled = $true
                outputDirName = 'reconciliation'
            }
            delivery = [ordered]@{
                deliveryEnabled = $true
                authorizationKind = 'PreviewOnly'
                outputDirName = 'delivery'
                commentsEnabled = $false
                votesEnabled = $false
                gatesEnabled = $false
                providerWriteBudget = 0
            }
        }
        if ($state.MutateExecutionPlan) { & $state.MutateExecutionPlan $executionPlan $state }
    }
    $ruleRequestSection = [ordered]@{
        path = $rulePath
        commit = $state.RuleCommit
        sha256 = (Get-CohortEntryBytesSha256 -Bytes $ruleBytes)
        byteLength = $ruleBytes.Length
    }
    if ([int]$state.SchemaVersion -ge 3) {
        $ruleRequestSection = [ordered]@{
            organization = [string]$state.RuleOrganization
            project = [string]$state.RuleProject
            repositoryId = [string]$state.RuleRepositoryId
            path = $rulePath
            commit = $state.RuleCommit
            section = [string]$state.RuleSection
            sha256 = (Get-CohortEntryBytesSha256 -Bytes $ruleBytes)
            byteLength = $ruleBytes.Length
        }
    }
    $requestBody = [ordered]@{
            schemaVersion = $state.SchemaVersion
            kind = 'reviewer-cohort-entry-evidence-request'
            correlationId = 'fixture-entry-001'
            toolkit = [ordered]@{ repositoryRoot = $toolkit; head = $toolkitHead; requiredRef = $toolkitRef }
            subject = [ordered]@{
                organization = $state.Organization
                project = $state.Project
                repositoryId = $state.RepositoryId
                repositoryName = $state.RepositoryName
                pullRequestId = $state.PullRequestId
                targetRefName = $state.TargetRefName
            }
            reviewer = [ordered]@{
                configPath = $configPath
                repositoryPath = $toolkit
                operatorAlias = 'fixture-operator'
                powerShellPath = (Get-Process -Id $PID).Path
                childTimeoutSeconds = 600
                plannedRunCount = $state.PlannedRunCount
                runSetKeyPath = $runSetKeyPath
            }
            ruleBundle = [ordered]@{
                sourceKind = 'pinnedRepositorySections'
                declarationPath = $declarationPath
                declarationSha256 = $declarationSha
                sections = @($ruleRequestSection)
            }
            capture = [ordered]@{
                mode = 'replay'
                replayRoot = $replayRoot
                replaySnapshotName = 'fixture'
                replayManifestDigest = $manifestDigest
            }
            coverage = [ordered]@{
                maxChangedFiles = $state.MaxChangedFiles
                maxFileBytes = $state.MaxFileBytes
                maxSiblingFiles = $state.MaxSiblingFiles
                maxThreads = $state.MaxThreads
                minChangedPathCoveragePercent = $state.MinCoveragePercent
            }
            output = [ordered]@{
                root = $outputRoot
                entryId = 'fixture-entry'
                ordinal = 1
                sealKeyPath = $sealKeyPath
            }
        }
    if ($state.ExecutionPlanIsNull) { [void]$requestBody.Add('executionPlan', $null) }
    elseif ($null -ne $executionPlan) { [void]$requestBody.Add('executionPlan', $executionPlan) }
        if ($state.MutateRequest) { & $state.MutateRequest $requestBody $state }
        Write-CohortEntryJsonFile -Path $requestPath -WithBom:$state.RequestWithBom -Value $requestBody

    return [pscustomobject][ordered]@{
        Sandbox = $Sandbox
        RequestPath = $requestPath
        OutputRoot = $outputRoot
        SealKeyPath = $sealKeyPath
        ConfigPath = $configPath
        Toolkit = $toolkit
        ToolkitHead = $toolkitHead
        FixtureBoundFactors = [pscustomobject]@{
            GeneralistAttemptsPerPass = [int]$state.FixtureGeneralistAttempts
            SpecialistAttempts = [int]$state.FixtureSpecialistAttempts
            VerifierAttemptsPerLaunch = [int]$state.FixtureVerifierAttempts
            VerifierCeiling = [int]$state.FixtureVerifierCeiling
            VerifierPolicyRuns = [int]$state.FixtureVerifierPolicyRuns
        }
        GeneralistPair = $registryPair
        SpecialistModel = $fixtureSpecialist
        VerifierModel = $fixtureVerifier
        State = $state
    }
}

function New-CohortEntrySandbox {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path ([IO.Path]::GetTempPath()) ("cohort-entry-$Name-" + [guid]::NewGuid().ToString('n'))
    [void](New-Item -ItemType Directory -Force -Path $path)
    return $path
}

function Remove-CohortEntrySandbox {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File | ForEach-Object {
        $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-CohortEntryCase {
    <#
    .SYNOPSIS
        Runs one sabotage case end to end in its own sandbox and reports the code
        it refused under.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedCode,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutate,
        # Builds WITHOUT the preparation-only acknowledgement, for the one case
        # that is about that acknowledgement being required.
        [switch]$ClaimingCohortReady,
        # A refusal that arrives AFTER the package was published has to take the
        # package with it, or it leaves a sealed, read-only, seal-verifiable
        # directory that a manifest could name and a cohort would accept.
        [switch]$RequireOutputRootWithdrawn
    )
    $sandbox = New-CohortEntrySandbox -Name 'sabotage'
    try {
        $fixture = New-CohortEntryFixture -Sandbox $sandbox -Mutate $Mutate
        $observed = Get-CohortEntryRefusalCode -Action {
            if ($ClaimingCohortReady) { New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath }
            else { New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath -PreparationOnly }
        }
        # An empty expectation is a case that must be ACCEPTED. Those matter as
        # much as the refusals: a check that refuses something the reviewer would
        # have run is a false refusal, not a stricter check.
        $label = if ($ExpectedCode) { "refuses $ExpectedCode" } else { 'is accepted' }
        Assert-CohortEntry -Name "$Name $label (observed '$observed')" -Condition ($observed -ceq $ExpectedCode)
        if ($RequireOutputRootWithdrawn) {
            $standing = @(Get-ChildItem -LiteralPath $fixture.OutputRoot -Force -ErrorAction SilentlyContinue)
            Assert-CohortEntry -Name "$Name leaves no published package behind" -Condition ($standing.Count -eq 0)
        }
    }
    finally { Remove-CohortEntrySandbox -Path $sandbox }
}

Write-Host 'Typed cohort-entry evidence builder' -ForegroundColor Cyan

# -------------------------------------------------------------------------
Write-Host 'catalogue and contract' -ForegroundColor Cyan
$catalog = Get-ReviewerCohortEntryErrorCatalog
Assert-CohortEntry -Name 'every catalogued code is CEnnn' `
    -Condition (@($catalog.Keys | Where-Object { [string]$_ -cnotmatch '^CE[0-9]{3}$' }).Count -eq 0)
Assert-CohortEntry -Name 'the raw-repository-shape refusal is its own code' -Condition ($catalog.Contains('CE203'))
Assert-CohortEntry -Name 'an uncatalogued code cannot be raised' `
    -Condition ((Get-CohortEntryRefusalCode -Action { New-ReviewerCohortEntryRefusal -Code 'CE999' -Detail 'x' }) -ceq 'CE000')

$schemaPath = Join-Path $repoRoot 'src/Agents/reviewer/schemas/reviewer.cohort-entry-evidence-request.v1.json'
Assert-CohortEntry -Name 'the versioned request schema is present' -Condition (Test-Path -LiteralPath $schemaPath -PathType Leaf)
$schemaText = [IO.File]::ReadAllText($schemaPath)
$schema = $schemaText | ConvertFrom-Json -Depth 32

function Get-CohortEntrySchemaPropertyName {
    <#
    .SYNOPSIS
        Every field name the schema declares, at any depth.

    .DESCRIPTION
        Names only. The schema's own prose says in so many words that it carries
        no oracle, so a scan over the raw text would flag the very sentence that
        promises the property this check is verifying.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Node)
    $names = [System.Collections.Generic.List[string]]::new()
    if ($Node -isnot [System.Management.Automation.PSCustomObject]) { return [string[]]$names.ToArray() }
    foreach ($property in $Node.PSObject.Properties) {
        if ($property.Name -ceq 'properties' -and $property.Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($declared in $property.Value.PSObject.Properties) {
                [void]$names.Add([string]$declared.Name)
                foreach ($nested in (Get-CohortEntrySchemaPropertyName -Node $declared.Value)) { [void]$names.Add($nested) }
            }
            continue
        }
        foreach ($nested in (Get-CohortEntrySchemaPropertyName -Node $property.Value)) { [void]$names.Add($nested) }
    }
    return [string[]]$names.ToArray()
}

$schemaNames = [string[]]@(Get-CohortEntrySchemaPropertyName -Node $schema)
Assert-CohortEntry -Name 'the request schema declares fields at all' -Condition ($schemaNames.Count -gt 20)
Assert-CohortEntry -Name 'the request schema declares no oracle field' `
    -Condition (@($schemaNames | Where-Object { $_ -imatch 'expected|oracle|groundTruth|answerKey|verdict|severity|finding' }).Count -eq 0)
Assert-CohortEntry -Name 'the request schema is closed' -Condition ($schemaText -match '"additionalProperties"\s*:\s*false')

# -------------------------------------------------------------------------
Write-Host 'architecture: the builder can never write' -ForegroundColor Cyan
$surfaceFiles = @(
    (Join-Path $repoRoot 'src/Agents/reviewer/CohortEntryEvidence.ps1'),
    (Join-Path $repoRoot 'src/Agents/reviewer/CohortEntryPackage.ps1'),
    (Join-Path $repoRoot 'src/Agents/reviewer/CohortEntryBuilder.ps1'),
    (Join-Path $repoRoot 'tools/New-ShadowCohortEntryEvidence.ps1')
)
foreach ($file in $surfaceFiles) {
    $body = [IO.File]::ReadAllText($file)
    $name = Split-Path $file -Leaf
    Assert-CohortEntry -Name "$name names no write tool" -Condition ($body -inotmatch 'repo_pull_request_write|repo_wiki_write|_write\b')
    # The question is whether a credential is READ, not whether its name appears:
    # the builder has to NAME the provider tokens in order to strip them from the
    # tool child's environment, and a test that refused the name would forbid the
    # very scrub it wants. So this looks for an actual read - $env:NAME, or the
    # env: drive - and the scrub list is asserted separately below.
    Assert-CohortEntry -Name "$name reads no credential" `
        -Condition ($body -inotmatch '\$env:(AZURE_DEVOPS_EXT_PAT|SYSTEM_ACCESSTOKEN|GH_TOKEN|GITHUB_TOKEN|COPILOT_GITHUB_TOKEN)|env:\\(AZURE_DEVOPS_EXT_PAT|SYSTEM_ACCESSTOKEN)|Personal Access Token')
    Assert-CohortEntry -Name "$name starts no model" -Condition ($body -inotmatch 'copilot\s+-p|Start-CopilotAgent|--allow-all-tools')
}
$builderBody = [IO.File]::ReadAllText((Join-Path $repoRoot 'src/Agents/reviewer/CohortEntryBuilder.ps1'))
$evidenceBody = [IO.File]::ReadAllText((Join-Path $repoRoot 'src/Agents/reviewer/CohortEntryEvidence.ps1'))
$sourceTransportBody = [IO.File]::ReadAllText((Join-Path $repoRoot 'src/Agents/reviewer/SourceTransport.ps1'))
$reviewerAgentBody = [IO.File]::ReadAllText((Join-Path $repoRoot 'src/Agents/reviewer/Start-ReviewerAgent.ps1'))
$factPolicyForThreads = Get-Content -LiteralPath (Join-Path $repoRoot 'src/Agents/reviewer/facts/v1/policy.json') -Raw |
    ConvertFrom-Json -Depth 32
foreach ($secretName in @('AZURE_DEVOPS_EXT_PAT', 'SYSTEM_ACCESSTOKEN', 'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) {
    Assert-CohortEntry -Name "the live session scrubs $secretName from the tool child" `
        -Condition ($builderBody -cmatch [regex]::Escape("'$secretName'"))
}
Assert-CohortEntry -Name 'the live session narrows the tool child to the repos toolset' `
    -Condition ($builderBody -cmatch "-Toolsets\s+@\('repos'\)")
Assert-CohortEntry -Name 'the live session passes its scrub list to the session opener' `
    -Condition ($builderBody -cmatch '-EnvironmentVariablesToRemove\s+\$script:ReviewerCohortEntrySensitiveEnvironmentVariables')

# A refusal code nobody can raise is not a refusal. The catalogue is the
# operator-facing contract, so every code in it has to have a site that raises
# it, and CE000 is the catalogue's own fallback for an uncatalogued code.
$productionBodies = ''
foreach ($file in $surfaceFiles) { $productionBodies += [IO.File]::ReadAllText($file) }
$unraisedCodes = [string[]]@(
    $catalog.Keys |
        Where-Object { [string]$_ -cne 'CE000' } |
        Where-Object { $productionBodies -cnotmatch ("-Code\s+'" + [regex]::Escape([string]$_) + "'") } |
        ForEach-Object { [string]$_ }
)
Assert-CohortEntry -Name "every catalogued refusal has a site that raises it ($($unraisedCodes -join ', '))" `
    -Condition ($unraisedCodes.Count -eq 0)

# Span evidence is keyed by path, and the census keeps /Src/A.ps1 and /src/a.ps1
# apart because it compares ordinally. A case-insensitive accumulator would
# merge them and hand one file the other's spans - already validated, against
# the wrong file's line count, so nothing downstream would notice.
Assert-CohortEntry -Name 'the span accumulator is keyed ordinally' `
    -Condition ($builderBody -cmatch '\$spanEvidence\s*=\s*\[System\.Collections\.Specialized\.OrderedDictionary\]::new\(\[StringComparer\]::Ordinal\)')
$plainPlan = @(Get-ReviewerCohortEntryIdentityReadPlan -Request ([pscustomobject]@{
            Project = 'Contoso'; RepositoryName = 'toolkit'; RepositoryId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            PullRequestId = 1; TargetRefName = 'refs/heads/main'; MaxThreads = 200; MaxChangedFiles = 300
        }))
Assert-CohortEntry -Name 'the planned change reads are the shared change-list requests, tool and all' `
    -Condition (
        $(
            $planChangeReads = @($plainPlan | Where-Object { $_.Arguments['action'] -ceq 'get_changes' })
            $sharedPlainChange = New-ReviewerChangeListRequest -Project 'Contoso' -RepositoryName 'toolkit' -PullRequestId 1
            $sharedDiffChange = New-ReviewerChangeListRequest -Project 'Contoso' -RepositoryName 'toolkit' -PullRequestId 1 -IncludeDiffs
            $sharedChangeReads = @($sharedPlainChange, $sharedDiffChange)
            $changeMismatches = 0
            if ($planChangeReads.Count -ne $sharedChangeReads.Count) { $changeMismatches++ }
            else {
                for ($i = 0; $i -lt $sharedChangeReads.Count; $i++) {
                    $planned = $planChangeReads[$i]
                    $shared = $sharedChangeReads[$i]
                    if ($planned.Tool -cne $shared.Name) { $changeMismatches++; continue }
                    if ((($planned.Arguments.Keys | ForEach-Object { [string]$_ }) -join ',') -cne
                        (($shared.Arguments.Keys | ForEach-Object { [string]$_ }) -join ',')) { $changeMismatches++; continue }
                    foreach ($key in $shared.Arguments.Keys) {
                        if ([string]$planned.Arguments[$key] -cne [string]$shared.Arguments[$key]) { $changeMismatches++ }
                        if ($planned.Arguments[$key].GetType() -ne $shared.Arguments[$key].GetType()) { $changeMismatches++ }
                    }
                }
            }
            $changeMismatches -eq 0
        ))

# THE thread-read contract. A replay answers the arguments it recorded and never
# falls through to a live read, so the builder's thread read has to be the live
# cycle's thread read - name, keys, values and all. A shadow slot once died
# mid-cycle because the builder asked for cap+1 threads (right for the change
# reads, which are its own) while the reviewer asked for the production page.
# These assertions compare the plan against the SHARED constructor and against
# the live agent's own source text, so restating the vector in either place
# fails here rather than in a slot.
$threadPlanRead = @($plainPlan | Where-Object { $_.Id -ceq 'threads' })[0]
$sharedThreadRequest = New-ReviewerThreadListRequest -Project 'Contoso' -RepositoryName 'toolkit' -PullRequestId 1
Assert-CohortEntry -Name 'the planned thread read is the shared thread-list request, tool and all' `
    -Condition (
        $threadPlanRead.Tool -ceq $sharedThreadRequest.Name -and
        (($threadPlanRead.Arguments.Keys | ForEach-Object { [string]$_ }) -join ',') -ceq
        (($sharedThreadRequest.Arguments.Keys | ForEach-Object { [string]$_ }) -join ',') -and
        (@($sharedThreadRequest.Arguments.Keys | Where-Object {
                    [string]$threadPlanRead.Arguments[$_] -cne [string]$sharedThreadRequest.Arguments[$_]
                }).Count -eq 0))
# Built again under a cap that is NOT the production page, so "asks for the page"
# and "asks for the cap plus one" are two different numbers and the assertion can
# actually tell them apart. Under a 200-thread fixture the two coincide at the
# first conjunct and the check proves nothing.
$offCapPlan = @(Get-ReviewerCohortEntryIdentityReadPlan -Request ([pscustomobject]@{
            Project = 'Contoso'; RepositoryName = 'toolkit'; RepositoryId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            PullRequestId = 1; TargetRefName = 'refs/heads/main'; MaxThreads = 50; MaxChangedFiles = 42
        }))
$offCapThreadRead = @($offCapPlan | Where-Object { $_.Id -ceq 'threads' })[0]
Assert-CohortEntry -Name 'the planned thread read asks for the production page, not the declared cap plus one' `
    -Condition ([int]$threadPlanRead.Arguments['top'] -eq (Get-ReviewerThreadListTop) -and
        [int]$offCapThreadRead.Arguments['top'] -eq (Get-ReviewerThreadListTop) -and
        [int]$offCapThreadRead.Arguments['top'] -ne 51 -and
        [int]$offCapThreadRead.Arguments['top'] -ne 50)
# and the change reads, which are no longer the builder's to shape either, stop
# tracking it. Under a 42-file cap "the production page", "the cap" and "the cap
# plus one" are three different numbers, so this can tell them apart.
Assert-CohortEntry -Name 'the planned change reads ask for the production page, not the declared cap plus one' `
    -Condition (@($offCapPlan | Where-Object { $_.Arguments['action'] -ceq 'get_changes' } |
            Where-Object {
                [int]$_.Arguments['top'] -ne (Get-ReviewerChangeListTop) -or
                [int]$_.Arguments['top'] -eq 43 -or [int]$_.Arguments['top'] -eq 42
            }).Count -eq 0 -and
        @($offCapPlan | Where-Object { $_.Arguments['action'] -ceq 'get_changes' }).Count -eq 2)
# The value itself, pinned, and pinned against the transport limit it has to
# equal. The flat read's page and the paginated contract's accumulation bound are
# the same bound: if they drift, the two reads answer different change sets for
# the same subject.
Assert-CohortEntry -Name 'the shared change page is the production 1000 and equals the transport limit' `
    -Condition ((Get-ReviewerChangeListTop) -eq 1000 -and
        $sourceTransportBody -cmatch '\$script:ReviewerSourceChangeLimit\s*=\s*1000\b')
# The value itself, pinned. 200 is what the shipping fact policy caps threads at
# and what the live cycle asks for; a change to either is a change to the corpus
# every existing entry was built under, so it is not allowed to happen quietly.
Assert-CohortEntry -Name 'the shared thread page is the production 200' `
    -Condition ((Get-ReviewerThreadListTop) -eq 200 -and
        [int]$factPolicyForThreads.threads.maxThreads -eq (Get-ReviewerThreadListTop))
# The live agent must not carry its own copy of the vector. Two copies is how the
# first one drifted: the reviewer's literal and the builder's cap+1 were each
# individually defensible and jointly fatal.
#
# Read the agent's syntax tree rather than its text. A text guard can only ban
# the byte shape of the code that was already deleted; every plausible way to
# reintroduce the read - different quoting, a hoisted variable, the tool name
# behind the accessor - writes different bytes and the same tree. This walks
# every Invoke-AgentMcpTool call and refuses any that names the thread tool for
# a list action. The action=create write elsewhere in the file is a different
# contract; its arguments are assembled in a variable, so the walk resolves the
# variable against the hashtable literals assigned to it inside the same
# function rather than waving through anything it cannot read inline.
$reviewerAgentAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'src/Agents/reviewer/Start-ReviewerAgent.ps1'), [ref]$null, [ref]$null)
$threadListActionInHashtable = {
    param($hashtableAst)
    foreach ($pair in $hashtableAst.KeyValuePairs) {
        if ([string]$pair.Item1.Extent.Text -notmatch 'action') { continue }
        if ([string]$pair.Item2.Extent.Text -match 'list') { return $true }
    }
    return $false
}
# The same walk, asked about a different tool and a different action. Written
# once and called twice, because a second copy of it is exactly the duplication
# these guards exist to catch.
function Get-InlineMcpReads {
    param(
        [Parameter(Mandatory)]$Ast,
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][scriptblock]$ActionMatcher
    )
    # The wrapper is reached two ways: by name, and through a function reference
    # captured into a variable so a closure can carry it. Both are the same call
    # and both must be walked - the second is what the aggregate readers use, so
    # a walk that only knows the first is blind to exactly the sites this change
    # converted.
    # An argument vector reaches the wrapper wearing whatever parentheses and
    # casts the call site needed - ([hashtable]$request.Arguments) is the shape
    # this change produces everywhere. Peel those off on the tree rather than
    # off the text: a text peel has to anticipate the spacing and the nesting,
    # and gets the answer wrong in the safe direction, which here means calling
    # a converted site inline and burying the guard in false alarms.
    $unwrapAst = {
        param($node)
        while ($true) {
            if ($node -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $inner = @($node.Pipeline.PipelineElements)[0]
                if ($inner -isnot [System.Management.Automation.Language.CommandExpressionAst]) { break }
                $node = $inner.Expression
                continue
            }
            if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) { $node = $node.Child; continue }
            break
        }
        return $node
    }
    $invokerVariables = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in @($Ast.FindAll({
                    param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst]
                }, $true))) {
        if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        if ([string]$assignment.Right.Extent.Text -notmatch '\$\{?function:Invoke-AgentMcpTool\}?') { continue }
        [void]$invokerVariables.Add([string]$assignment.Left.VariablePath.UserPath)
    }
    return @(
        $Ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                if ([string]$node.GetCommandName() -ceq 'Invoke-AgentMcpTool') { return $true }
                $first = @($node.CommandElements)[0]
                if ($first -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
                return $invokerVariables.Contains([string]$first.VariablePath.UserPath)
            }, $true) |
            Where-Object {
                $elements = @($_.CommandElements)
                $argumentsAst = $null
                $nameAst = $null
                for ($i = 0; $i -lt $elements.Count - 1; $i++) {
                    if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                    switch ([string]$elements[$i].ParameterName) {
                        'Arguments' { $argumentsAst = (& $unwrapAst $elements[$i + 1]) }
                        'Name' { $nameAst = (& $unwrapAst $elements[$i + 1]) }
                    }
                }
                # A call that names a DIFFERENT tool outright is a different
                # contract and is left alone. Anything whose tool cannot be read
                # is inspected rather than waved through, because "unreadable"
                # is what every bypass looks like.
                if ($nameAst -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    [string]$nameAst.Value -cne $ToolName) { return $false }
                # Both halves taken from one shared-constructor result is the
                # shape this change exists to produce.
                if ($nameAst -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $argumentsAst -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    [string]$nameAst.Member.Extent.Text -eq 'Name' -and
                    [string]$argumentsAst.Member.Extent.Text -eq 'Arguments' -and
                    [string]$nameAst.Expression.Extent.Text -ceq [string]$argumentsAst.Expression.Extent.Text) { return $false }
                if ($argumentsAst -is [System.Management.Automation.Language.HashtableAst]) {
                    return (& $ActionMatcher $argumentsAst)
                }
                if ($argumentsAst -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $true }
                $scope = $_
                while ($null -ne $scope -and
                    $scope -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $scope -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $scope = $scope.Parent }
                if ($null -eq $scope) { return $true }
                $variableName = [string]$argumentsAst.VariablePath.UserPath
                # A vector that arrives as a PARAMETER is not authored here, so
                # this is not the site that could restate it. The paginated
                # contract's own invoker is exactly this shape.
                $parameters = @()
                if ($scope -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    if ($null -ne $scope.Body.ParamBlock) { $parameters += @($scope.Body.ParamBlock.Parameters) }
                    if ($null -ne $scope.Parameters) { $parameters += @($scope.Parameters) }
                }
                elseif ($null -ne $scope.ScriptBlock.ParamBlock) { $parameters = @($scope.ScriptBlock.ParamBlock.Parameters) }
                foreach ($parameter in @($parameters | Where-Object { $null -ne $_ })) {
                    if ([string]$parameter.Name.VariablePath.UserPath -eq $variableName) { return $false }
                }
                $assignments = @($scope.FindAll({
                            param($inner)
                            if ($inner -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { return $false }
                            return ([string]$inner.Left.Extent.Text -match
                                ('^\$' + [regex]::Escape($variableName) + '(\[|\.|$)'))
                        }, $true))
                # A hashtable filled in after it was created cannot be read off
                # its literal alone. Only the key that decides the contract
                # matters: a later write to 'action' - or to a key that cannot be
                # read at all - defeats the literal and is flagged, while the
                # anchor fields the thread WRITE fills in conditionally are not
                # the action and leave the answer intact.
                foreach ($assignment in $assignments) {
                    if ($assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                    $keyAst = $null
                    if ($assignment.Left -is [System.Management.Automation.Language.IndexExpressionAst]) {
                        $keyAst = (& $unwrapAst $assignment.Left.Index)
                    }
                    elseif ($assignment.Left -is [System.Management.Automation.Language.MemberExpressionAst]) {
                        $keyAst = $assignment.Left.Member
                    }
                    if ($keyAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $true }
                    if ([string]$keyAst.Value -match 'action') { return $true }
                }
                $seeded = @($assignments |
                        ForEach-Object { $_.Right.Find({
                                    param($inner) $inner -is [System.Management.Automation.Language.HashtableAst]
                                }, $true) } |
                        Where-Object { $null -ne $_ })
                if ($seeded.Count -eq 0) { return $true }
                return (@($seeded | Where-Object { & $ActionMatcher $_ }).Count -gt 0)
            })
}
$inlineThreadListReads = @(Get-InlineMcpReads -Ast $reviewerAgentAst `
        -ToolName (Get-ReviewerThreadListToolName) -ActionMatcher $threadListActionInHashtable)
Assert-CohortEntry -Name "the live reviewer builds its thread reads through the shared constructor only ($($inlineThreadListReads.Count) inline)" `
    -Condition (
        ([regex]::Matches($reviewerAgentBody, 'New-ReviewerThreadListRequest\s+-Project').Count -ge 2) -and
        ($inlineThreadListReads.Count -eq 0))
# and neither may the builder. Counted, not shape-matched: any new mention moves
# the number whatever quotes it wears. CohortEntryEvidence.ps1 keeps exactly one,
# in the prose above the read plan; the builder names it nowhere.
Assert-CohortEntry -Name 'the builder restates neither the thread tool name nor its page size' `
    -Condition (
        ([regex]::Matches($evidenceBody, 'repo_pull_request_thread').Count -eq 1) -and
        ([regex]::Matches($builderBody, 'repo_pull_request_thread').Count -eq 0) -and
        ($evidenceBody -cnotmatch '(?m)top\s*=\s*\(?\s*\$Request\.MaxThreads'))
# "Exactly once" means across every file that could author it, not just inside
# the one that does. A restated page in the agent or the builder is the failure
# this whole change exists to prevent, so that is where it is looked for.
$threadPageRestatements = 0
foreach ($restatementBody in @($reviewerAgentBody, $evidenceBody, $builderBody)) {
    $threadPageRestatements += [regex]::Matches($restatementBody, '\btop\s*=\s*200\b').Count
}
Assert-CohortEntry -Name "the shared thread page size is written down exactly once ($threadPageRestatements restatements)" `
    -Condition ($threadPageRestatements -eq 0 -and
        [regex]::Matches($sourceTransportBody, '(?m)^\s*return\s+200\b').Count -eq 1)
# The two thread ceilings are different failures with opposite operator answers -
# "edit maxThreads in your request" versus "this subject is too large to build an
# entry from" - so they carry different codes and each is raised in exactly one
# band. Collapsing them would leave callers, which match on the code, unable to
# tell a fixable request from an unbuildable subject.
Assert-CohortEntry -Name 'the request thread ceiling and the full-page evidence carry different codes' `
    -Condition (
        ($evidenceBody -cmatch "-Code\s+'CE113'") -and
        ($evidenceBody -cnotmatch "-Code\s+'CE408'") -and
        ($builderBody -cmatch "-Code\s+'CE408'") -and
        ($builderBody -cnotmatch "-Code\s+'CE113'"))
# The same three guards for the change reads, which failed the same way one
# shadow later: the reviewer's own literal and the builder's cap+1 were each
# defensible alone and jointly fatal, and a slot died in convention planning on a
# read it could prove it needed and could not get.
$getChangesActionInHashtable = {
    param($hashtableAst)
    foreach ($pair in $hashtableAst.KeyValuePairs) {
        if ([string]$pair.Item1.Extent.Text -notmatch 'action') { continue }
        if ([string]$pair.Item2.Extent.Text -match 'get_changes') { return $true }
    }
    return $false
}
$inlineGetChangesReads = @(Get-InlineMcpReads -Ast $reviewerAgentAst `
        -ToolName (Get-ReviewerChangeListToolName) -ActionMatcher $getChangesActionInHashtable)
Assert-CohortEntry -Name "the live reviewer builds its change reads through the shared constructor only ($($inlineGetChangesReads.Count) inline)" `
    -Condition (
        ([regex]::Matches($reviewerAgentBody, 'New-ReviewerChangeListRequest\s+-Project').Count -eq 5) -and
        ($inlineGetChangesReads.Count -eq 0))
# and the stronger statement the call-site walk cannot make on its own. A walk
# can always be routed around - through a wrapper, a splat, a hashtable filled in
# after it was built - so this asks a question with no such escapes: does a
# hashtable naming this action EXIST anywhere in the file, reached or not? The
# action string is unique to this one contract, so the answer is exact, and the
# only way past it is to compute the string, which is not a thing this code does
# anywhere.
$getChangesLiterals = @{}
foreach ($scannedFile in @(
        'src/Agents/reviewer/Start-ReviewerAgent.ps1',
        'src/Agents/reviewer/CohortEntryEvidence.ps1',
        'src/Agents/reviewer/CohortEntryBuilder.ps1')) {
    $scannedAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot $scannedFile), [ref]$null, [ref]$null)
    $getChangesLiterals[$scannedFile] = @($scannedAst.FindAll({
                param($node) $node -is [System.Management.Automation.Language.HashtableAst]
            }, $true) | Where-Object { & $getChangesActionInHashtable $_ }).Count
}
Assert-CohortEntry -Name "no change-read vector is written outside the shared constructor ($(($getChangesLiterals.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))" `
    -Condition (@($getChangesLiterals.Values | Where-Object { $_ -ne 0 }).Count -eq 0)
# and the same scan finds the one in the library, so it is not passing by
# looking for something that never existed.
$transportChangeAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'src/Agents/reviewer/SourceTransport.ps1'), [ref]$null, [ref]$null)
$transportGetChangesLiterals = @(
    $transportChangeAst.FindAll({
            param($node) $node -is [System.Management.Automation.Language.HashtableAst]
        }, $true) | Where-Object { & $getChangesActionInHashtable $_ })
Assert-CohortEntry -Name "the change-read vector is written in the library that owns it ($($transportGetChangesLiterals.Count))" `
    -Condition ($transportGetChangesLiterals.Count -ge 1)
# Other actions on the same tool are a different contract and must stay
# reachable, so the walk has to discriminate on the ACTION rather than the tool.
# If it did not, this count would be zero and the guard above would be passing
# for the wrong reason.
Assert-CohortEntry -Name 'the change-read guard leaves the other repo_pull_request actions alone' `
    -Condition (@(Get-InlineMcpReads -Ast $reviewerAgentAst -ToolName (Get-ReviewerChangeListToolName) `
                -ActionMatcher { param($hashtableAst) $true }).Count -gt 0)
# A guard that has never been shown to fail is a guard nobody has read. Every
# bypass the walk was built to catch is stated here as code and fed through it,
# so "0 inline" above means the walk looked and found nothing rather than the
# walk being blind. Three of these - the ampersand-invoked reference, the tool
# name behind a variable, the hashtable filled in after it was built - are shapes
# an earlier version of this walk waved through, which is why they are written
# down rather than remembered.
$guardBypassCases = @(
    @{ Name = 'a plain named call with an inline vector'; Expect = 1; Body = @'
function Probe { Invoke-AgentMcpTool -Session $s -Name 'repo_pull_request' -Arguments @{ action = 'get_changes'; top = 61 } }
'@ },
    @{ Name = 'the wrapper reached through a function reference'; Expect = 1; Body = @'
function Probe { $i = ${function:Invoke-AgentMcpTool}
    & $i -Session $s -Name 'repo_pull_request' -Arguments @{ action = 'get_changes'; top = 61 } }
'@ },
    @{ Name = 'a vector filled in after it was created'; Expect = 1; Body = @'
function Probe { $a = @{}
    $a['action'] = 'get_changes'
    Invoke-AgentMcpTool -Session $s -Name 'repo_pull_request' -Arguments $a }
'@ },
    @{ Name = 'the tool name hidden behind a variable'; Expect = 1; Body = @'
function Probe { $t = 'repo_pull_request'
    Invoke-AgentMcpTool -Session $s -Name $t -Arguments @{ action = 'get_changes'; top = 61 } }
'@ },
    @{ Name = 'a vector hoisted into a local'; Expect = 1; Body = @'
function Probe { $v = @{ action = 'get_changes'; top = 61 }
    Invoke-AgentMcpTool -Session $s -Name 'repo_pull_request' -Arguments $v }
'@ },
    @{ Name = 'a key computed at run time'; Expect = 1; Body = @'
function Probe { $v = @{ top = 61 }
    $k = 'act' + 'ion'
    $v[$k] = 'get_changes'
    Invoke-AgentMcpTool -Session $s -Name 'repo_pull_request' -Arguments $v }
'@ },
    @{ Name = 'the converted shared-constructor site'; Expect = 0; Body = @'
function Probe { $r = New-ReviewerChangeListRequest -Project $p -RepositoryName $n -PullRequestId $i
    Invoke-AgentMcpTool -Session $s -Name $r.Name -Arguments ([hashtable]$r.Arguments) }
'@ },
    @{ Name = 'a different action on the same tool'; Expect = 0; Body = @'
function Probe { Invoke-AgentMcpTool -Session $s -Name 'repo_pull_request' -Arguments @{ action = 'get_pull_request'; pullRequestId = 1 } }
'@ },
    @{ Name = 'a vector that arrives as a parameter'; Expect = 0; Body = @'
function Probe { param($Arguments)
    Invoke-AgentMcpTool -Session $s -Name 'repo_pull_request' -Arguments $Arguments }
'@ })
$guardBypassMisses = [System.Collections.Generic.List[object]]::new()
foreach ($guardBypassCase in $guardBypassCases) {
    $bypassAst = [System.Management.Automation.Language.Parser]::ParseInput(
        [string]$guardBypassCase.Body, [ref]$null, [ref]$null)
    $bypassHits = @(Get-InlineMcpReads -ToolName (Get-ReviewerChangeListToolName) `
            -ActionMatcher $getChangesActionInHashtable -Ast $bypassAst)
    if ($bypassHits.Count -ne $guardBypassCase.Expect) { [void]$guardBypassMisses.Add($guardBypassCase) }
}
Assert-CohortEntry -Name "the read guard answers every known bypass shape correctly ($($guardBypassCases.Count - $guardBypassMisses.Count)/$($guardBypassCases.Count)$(if ($guardBypassMisses.Count) { ': ' + (($guardBypassMisses | ForEach-Object { $_.Name }) -join '; ') }))" `
    -Condition ($guardBypassMisses.Count -eq 0)
# The optional-field reader answers the same way over both shapes the JSON
# reader can hand back, and over either capitalisation. A field this build
# refuses on is not a field it may miss because the provider capitalised it, and
# an ordered dictionary - what -AsHashtable returns - does not agree with a
# property bag about that unless it is made to.
$optionalShapes = @(
    @{ Label = 'a property bag'; Object = ([pscustomobject][ordered]@{ nextSkip = 7 }) },
    @{ Label = 'an ordered dictionary'; Object = ([ordered]@{ nextSkip = 7 }) },
    @{ Label = 'a hashtable'; Object = (@{ nextSkip = 7 }) })
$optionalMisreads = @($optionalShapes | Where-Object {
        (Get-ReviewerCohortEntryOptionalValue -Object $_.Object -Name 'nextSkip') -ne 7 -or
        (Get-ReviewerCohortEntryOptionalValue -Object $_.Object -Name 'NEXTSKIP') -ne 7 -or
        $null -ne (Get-ReviewerCohortEntryOptionalValue -Object $_.Object -Name 'nextSkipped')
    })
Assert-CohortEntry -Name "an optional provider field reads the same over every shape and capitalisation ($($optionalShapes.Count - $optionalMisreads.Count)/$($optionalShapes.Count))" `
    -Condition ($optionalMisreads.Count -eq 0 -and
        $null -eq (Get-ReviewerCohortEntryOptionalValue -Object $null -Name 'nextSkip'))
# Neither the evidence plan nor the builder may spell the action at all: both now
# take the whole vector from the shared constructor, so a quoted 'get_changes'
# anywhere in either file is a second author.
Assert-CohortEntry -Name 'the builder restates neither change-read variant' `
    -Condition (
        ([regex]::Matches($evidenceBody, "['`"]get_changes['`"]").Count -eq 0) -and
        ([regex]::Matches($builderBody, "['`"]get_changes['`"]").Count -eq 0) -and
        ($evidenceBody -cnotmatch '(?m)top\s*=\s*\(?\s*\$Request\.MaxChangedFiles'))
$changePageRestatements = 0
foreach ($restatementBody in @($reviewerAgentBody, $evidenceBody, $builderBody,
        [IO.File]::ReadAllText((Join-Path $repoRoot 'src/Agents/reviewer/ConventionPacks.ps1')))) {
    $changePageRestatements += [regex]::Matches($restatementBody, '\btop\s*=\s*1000\b').Count
    $changePageRestatements += [regex]::Matches($restatementBody, '-Limit\s+1000\b').Count
    $changePageRestatements += [regex]::Matches($restatementBody, '\$Limit\s*=\s*1000\b').Count
}
Assert-CohortEntry -Name "the shared change page size is written down exactly once ($changePageRestatements restatements)" `
    -Condition ($changePageRestatements -eq 0 -and
        [regex]::Matches($sourceTransportBody, '(?m)^\s*return\s+1000\b').Count -eq 1)
# The request schema states the same ceiling a second time, in a language the
# reader cannot call into. So it is compared here instead: a schema that admits
# a cap the reader refuses turns a fixable request into an unexplained failure
# one layer down.
foreach ($schemaVersionName in @('v1', 'v2', 'v3')) {
    $capSchema = Get-Content -LiteralPath (Join-Path $repoRoot `
            "src/Agents/reviewer/schemas/reviewer.cohort-entry-evidence-request.$schemaVersionName.json") -Raw |
        ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name "the $schemaVersionName request schema caps maxChangedFiles at the reviewer's own page" `
        -Condition ([int]$capSchema.properties.coverage.properties.maxChangedFiles.maximum -eq (Get-ReviewerChangeListTop))
}
$v2RequestSchema = Get-Content -LiteralPath (Join-Path $repoRoot `
        'src/Agents/reviewer/schemas/reviewer.cohort-entry-evidence-request.v2.json') -Raw |
    ConvertFrom-Json -Depth 64
$v3RequestSchema = Get-Content -LiteralPath (Join-Path $repoRoot `
        'src/Agents/reviewer/schemas/reviewer.cohort-entry-evidence-request.v3.json') -Raw |
    ConvertFrom-Json -Depth 64
$v2RuleSchema = $v2RequestSchema.properties.ruleBundle.properties.sections.items
$v3RuleSchema = $v3RequestSchema.properties.ruleBundle.properties.sections.items
Assert-CohortEntry -Name 'the v2 rule-section schema remains the original four-field contract' `
    -Condition (
        ((@($v2RuleSchema.required) | Sort-Object -CaseSensitive) -join ',') -ceq
        ((@('byteLength', 'commit', 'path', 'sha256') | Sort-Object -CaseSensitive) -join ',') -and
        -not $v2RuleSchema.properties.PSObject.Properties['repositoryId'] -and
        -not $v2RuleSchema.properties.PSObject.Properties['section'])
Assert-CohortEntry -Name 'the v3 rule-section schema requires its explicit source binding and heading' `
    -Condition (
        ((@($v3RuleSchema.required) | Sort-Object -CaseSensitive) -join ',') -ceq
        ((@('organization', 'project', 'repositoryId', 'path', 'commit', 'section', 'sha256', 'byteLength') |
                Sort-Object -CaseSensitive) -join ','))
# and the two change ceilings are two failures with opposite answers, exactly as
# the thread pair is: CE402 says the operator authorized fewer files than this
# subject has, CE409 says nobody can tell how many it has.
Assert-CohortEntry -Name 'the changed-file cap and the full-page evidence carry different codes' `
    -Condition (
        ($evidenceBody -cmatch "-Code\s+'CE402'") -and
        ($evidenceBody -cmatch "-Code\s+'CE409'") -and
        ([regex]::Matches($evidenceBody, "-Code\s+'CE402'").Count -eq 1))
Assert-CohortEntry -Name 'the identity plan reads the repository by GUID under repositoryNameOrId' `
    -Condition (@($plainPlan | Where-Object { $_.Tool -ceq 'repo_repository' })[0].Arguments['repositoryNameOrId'] -ceq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
Assert-CohortEntry -Name 'the identity plan reads the pull request by repository NAME' `
    -Condition (@($plainPlan | Where-Object { $_.Id -ceq 'candidate-identity' })[0].Arguments['repositoryId'] -ceq 'toolkit')
Assert-CohortEntry -Name 'the identity plan reads the branch by repository GUID' `
    -Condition (@($plainPlan | Where-Object { $_.Tool -ceq 'repo_branch' })[0].Arguments['repositoryId'] -ceq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
Assert-CohortEntry -Name 'the identity plan issues BOTH get_changes variants' `
    -Condition (@($plainPlan | Where-Object { $_.Tool -ceq 'repo_pull_request' -and $_.Arguments['action'] -ceq 'get_changes' }).Count -eq 2)
Assert-CohortEntry -Name 'the identity plan never records repo_search_commits' `
    -Condition (@($plainPlan | Where-Object { $_.Tool -ceq 'repo_search_commits' }).Count -eq 0)

# -------------------------------------------------------------------------
# Plan closure. A re-read is legitimate - the builder asks its identity question
# twice on purpose - but it has to be DECLARED as a re-read of a named earlier
# read, and it has to ask exactly the same question. Anything else is either an
# accidental duplicate request key (two answers, one key, one of them
# unreachable) or a second question wearing the first one's name.
Write-Host 'plan closure: declared re-reads only' -ForegroundColor Cyan
$duplicateArgs = [ordered]@{ action = 'get'; project = 'Contoso'; repositoryId = 'toolkit'; pullRequestId = 1 }
$closedPlan = [object[]]@(
    (New-ReviewerCohortEntryRead -Id 'first' -Tool 'repo_pull_request' -Role 'identity' -Arguments $duplicateArgs `
        -Envelope 'mcpTextContent' -PayloadFile 'payloads/a.json'),
    (New-ReviewerCohortEntryRead -Id 'second' -Tool 'repo_pull_request' -Role 'identity' -Arguments $duplicateArgs `
        -Envelope 'mcpTextContent' -PayloadFile 'payloads/b.json' -DuplicateOf 'first')
)
Assert-CohortEntry -Name 'a declared re-read of the identical argument vector is accepted' `
    -Condition (Test-CohortEntryAccepts { Assert-ReviewerCohortEntryPlanIsClosed -Plan $closedPlan })
$undeclaredPlan = [object[]]@(
    $closedPlan[0],
    (New-ReviewerCohortEntryRead -Id 'second' -Tool 'repo_pull_request' -Role 'identity' -Arguments $duplicateArgs `
        -Envelope 'mcpTextContent' -PayloadFile 'payloads/b.json')
)
Assert-CohortEntry -Name 'an undeclared duplicate request key is refused as CE309' `
    -Condition (Test-CohortEntryRefusal -Code 'CE309' -Action { Assert-ReviewerCohortEntryPlanIsClosed -Plan $undeclaredPlan })
$divergentPlan = [object[]]@(
    $closedPlan[0],
    (New-ReviewerCohortEntryRead -Id 'second' -Tool 'repo_pull_request' -Role 'identity' `
        -Arguments ([ordered]@{ action = 'get'; project = 'Contoso'; repositoryId = 'toolkit'; pullRequestId = 2 }) `
        -Envelope 'mcpTextContent' -PayloadFile 'payloads/b.json' -DuplicateOf 'first')
)
Assert-CohortEntry -Name 'a re-read that asks a different question is refused as CE309' `
    -Condition (Test-CohortEntryRefusal -Code 'CE309' -Action { Assert-ReviewerCohortEntryPlanIsClosed -Plan $divergentPlan })
$forwardPlan = [object[]]@(
    (New-ReviewerCohortEntryRead -Id 'second' -Tool 'repo_pull_request' -Role 'identity' -Arguments $duplicateArgs `
        -Envelope 'mcpTextContent' -PayloadFile 'payloads/b.json' -DuplicateOf 'first'),
    $closedPlan[0]
)
Assert-CohortEntry -Name 'a re-read declared before the read it repeats is refused as CE309' `
    -Condition (Test-CohortEntryRefusal -Code 'CE309' -Action { Assert-ReviewerCohortEntryPlanIsClosed -Plan $forwardPlan })
$repeatedIdPlan = [object[]]@($closedPlan[0], $closedPlan[0])
Assert-CohortEntry -Name 'the same read id declared twice is refused as CE309' `
    -Condition (Test-CohortEntryRefusal -Code 'CE309' -Action { Assert-ReviewerCohortEntryPlanIsClosed -Plan $repeatedIdPlan })

# The same read performed twice is not the same statement as the same read
# planned twice: the corpus would carry two answers under one key.
$oneRead = [object[]]@($closedPlan[0])
$twiceCaptured = [object[]]@(
    [pscustomobject]@{ Read = $closedPlan[0] },
    [pscustomobject]@{ Read = $closedPlan[0] }
)
Assert-CohortEntry -Name 'a planned read performed twice is refused as CE301' `
    -Condition (Test-CohortEntryRefusal -Code 'CE301' -Action {
            Assert-ReviewerCohortEntryReadsComplete -Plan $oneRead -Captured $twiceCaptured
        })
Assert-CohortEntry -Name 'a planned read performed once is accepted' `
    -Condition (Test-CohortEntryAccepts {
            Assert-ReviewerCohortEntryReadsComplete -Plan $oneRead -Captured ([object[]]@($twiceCaptured[0]))
        })

$transportArgs = @(Get-ReviewerCohortEntrySourceTransportArgument -ArtifactPath 'C:/tmp/artifact.json' -Request ([pscustomobject]@{
            ToolkitRoot = 'C:/toolkit'; ReviewerConfigPath = 'C:/cfg.json'; ReviewerRepositoryPath = 'C:/repo'; PullRequestId = 7
        }))
Assert-CohortEntry -Name 'the source-transport capture is the no-model capture switch' -Condition ($transportArgs -ccontains '-CaptureSourceTransportOnly')
Assert-CohortEntry -Name 'the source-transport capture runs once' -Condition ($transportArgs -ccontains '-Once')
Assert-CohortEntry -Name 'the source-transport capture names its pull request explicitly' -Condition ($transportArgs -ccontains '-PullRequestId')

# -------------------------------------------------------------------------
Write-Host 'exact wrapper fixture: the happy path' -ForegroundColor Cyan
$sandbox = New-CohortEntrySandbox -Name 'exact'
try {
    $fixture = New-CohortEntryFixture -Sandbox $sandbox
    $result = New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath -PreparationOnly

    Assert-CohortEntry -Name 'the package publishes' -Condition (Test-Path -LiteralPath $result.Root -PathType Container)
    Assert-CohortEntry -Name 'it starts no model' -Condition ($result.ModelStarts -eq 0)
    Assert-CohortEntry -Name 'it writes to no provider' -Condition ($result.ProviderWrites -eq 0)
    Assert-CohortEntry -Name 'the iteration is the one the change set reported' -Condition ($result.IterationId -eq 3)
    Assert-CohortEntry -Name 'the source commit is the nested lastMergeSourceCommit' -Condition ($result.SourceCommit -ceq ('a' * 40))
    Assert-CohortEntry -Name 'the census carries every changed path once' -Condition ($result.CensusCount -eq 3)
    # 2 of 3 changed paths carry content: the third is a delete and has none.
    # A constant here would mean the floor was measuring a set against itself.
    Assert-CohortEntry -Name 'coverage counts the deleted path against the whole census' -Condition ($result.CoveragePercent -eq 66)

    $entryPath = Join-Path $result.Root 'entry/cohort-entry.json'
    Assert-CohortEntry -Name 'the manifest entry is published' -Condition (Test-Path -LiteralPath $entryPath -PathType Leaf)
    $entry = [IO.File]::ReadAllText($entryPath) | ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name 'the entry declares its ordinal' -Condition ($entry.ordinal -eq 1)
    Assert-CohortEntry -Name 'the entry targetRefName is fully qualified' -Condition ([string]$entry.subject.targetRefName -ceq 'refs/heads/main')
    Assert-CohortEntry -Name 'the entry pins its request digest' -Condition ([string]$entry.request.sha256 -cmatch '^[0-9a-f]{64}$')
    Assert-CohortEntry -Name 'the entry pins a model-start bound' -Condition ([string]$entry.planEstimate.modelStartBound.sha256 -cmatch '^[0-9a-f]{64}$')
    Assert-CohortEntry -Name 'the entry carries no expected finding' `
        -Condition (([IO.File]::ReadAllText($entryPath)) -inotmatch 'expectedFinding|oracle|groundTruth')

    $coordinatorPath = Join-Path $result.Root 'entry/coordinator-request.json'
    $coordinator = [IO.File]::ReadAllText($coordinatorPath) | ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name 'the coordinator request declares the v2 contract' `
        -Condition ([string]$coordinator.contractVersion -ceq 'devpilot.shadow-run-coordinator.request.v2')
    Assert-CohortEntry -Name 'the coordinator request declares no slots' -Condition ($null -eq $coordinator.PSObject.Properties['slots'])
    Assert-CohortEntry -Name 'the coordinator request pins the same source commit' `
        -Condition ([string]$coordinator.subject.sourceCommit -ceq $result.SourceCommit)

    $witness = [IO.File]::ReadAllText((Join-Path $result.Root 'entry/identity-witness.json')) | ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name 'the witness records both identity reads' -Condition ([int]$witness.capture.identityReReads -eq 1)
    Assert-CohortEntry -Name 'the witness census is in ascending ordinal order' `
        -Condition ((@($witness.census | ForEach-Object { [string]$_.path }) -join '|') -ceq '/src/a.ps1|/src/b.ps1|/src/z-old.ps1')

    # Span evidence, end to end: extracted from the diff variant by the
    # reviewer's own right-hand extractor, then validated against the file this
    # build actually captured. Context blocks contribute nothing; a delete-only
    # entry has no right hand at all.
    $spanA = @(@($witness.census | Where-Object { [string]$_.path -ceq '/src/a.ps1' })[0].spans)
    Assert-CohortEntry -Name 'the witness carries one right-hand span for the edited file' -Condition ($spanA.Count -eq 1)
    Assert-CohortEntry -Name 'the span is the ADD block, not the context block' `
        -Condition ([int]$spanA[0].start -eq 2 -and [int]$spanA[0].count -eq 2)
    $spanB = @(@($witness.census | Where-Object { [string]$_.path -ceq '/src/b.ps1' })[0].spans)
    Assert-CohortEntry -Name 'the added file carries its whole-file span' `
        -Condition ($spanB.Count -eq 1 -and [int]$spanB[0].start -eq 1 -and [int]$spanB[0].count -eq 2)
    $spanZ = @(@($witness.census | Where-Object { [string]$_.path -ceq '/src/z-old.ps1' })[0].spans)
    Assert-CohortEntry -Name 'the deleted file carries no right-hand span' -Condition ($spanZ.Count -eq 0)

    $corpusIndex = Join-Path $result.Root 'corpus/corpus-index.json'
    Assert-CohortEntry -Name 'the corpus index is published' -Condition (Test-Path -LiteralPath $corpusIndex -PathType Leaf)
    Assert-CohortEntry -Name 'the corpus index digest is the one the request pins' `
        -Condition ((Get-FileHash -LiteralPath $corpusIndex -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $result.CorpusIndexSha256)

    $recipe = [IO.File]::ReadAllText((Join-Path $result.Root 'entry/corpus-seal-recipe.json')) | ConvertFrom-Json -Depth 32
    $fileResources = @($recipe.resources | Where-Object { [string]$_.tool -ceq 'repo_file' })
    Assert-CohortEntry -Name 'every file resource declares an embedded-resource envelope' `
        -Condition (@($fileResources | Where-Object { [string]$_.envelope -cne 'mcpResourceContent' }).Count -eq 0)
    Assert-CohortEntry -Name 'every file resource declares the wrapper-requested URI' `
        -Condition (@($fileResources | Where-Object { [string]$_.resourceUri -cne [string]$_.arguments.path }).Count -eq 0)
    Assert-CohortEntry -Name 'no resource is declared twice' `
        -Condition ((@($recipe.resources).Count) -eq (@($recipe.resources | ForEach-Object { (Get-AgentReplayRequestKey -Name $_.tool -Arguments $_.arguments).Key } | Sort-Object -Unique).Count)

    )

    # THE assertion the shadow #10 failure was missing. A slot resolves a read by
    # its request KEY, and a key that is not in the published corpus is a cycle
    # that stops: a replay never falls through to a live read. So compute the key
    # the LIVE cycle will compute, from the shared constructor and this subject's
    # own identity, and require the corpus the builder just published to answer
    # it. Comparing the recipe's arguments against a restatement here would only
    # prove the restatement matched; comparing keys proves the reviewer can read.
    $liveThreadRequest = New-ReviewerThreadListRequest -Project $fixture.State.Project `
        -RepositoryName $fixture.State.RepositoryName -PullRequestId $fixture.State.PullRequestId
    $liveThreadKey = (Get-AgentReplayRequestKey -Name $liveThreadRequest.Name `
            -Arguments ([hashtable]$liveThreadRequest.Arguments)).Key
    $recipeThreadKeys = [string[]]@($recipe.resources |
            Where-Object { [string]$_.tool -ceq (Get-ReviewerThreadListToolName) } |
            ForEach-Object { (Get-AgentReplayRequestKey -Name $_.tool -Arguments $_.arguments).Key })
    Assert-CohortEntry -Name 'the published corpus answers the exact thread read the live cycle issues' `
        -Condition ($recipeThreadKeys -ccontains $liveThreadKey)
    Assert-CohortEntry -Name 'the published corpus declares exactly one thread read' `
        -Condition ($recipeThreadKeys.Count -eq 1)

    # ------------------------------------------------------------------
    # The PRODUCTION corpus seal contract. The builder used to emit a recipe
    # of its own invention that nothing in the tree read, so an entry could be
    # published, accepted by a cohort manifest and only refused by the sealer
    # four states into a run. Everything below is checked against the shipping
    # sealer rather than against a restatement of what it wants.
    # ------------------------------------------------------------------
    $recipePath = Join-Path $result.Root 'entry/corpus-seal-recipe.json'
    $recipeKeys = [string[]]@($recipe.PSObject.Properties.Name)
    Assert-CohortEntry -Name 'the recipe is the recipe the shipping sealer reads' `
        -Condition ([string]$recipe.kind -ceq 'reviewer-offline-corpus-seal-recipe')
    Assert-CohortEntry -Name 'the recipe carries none of the builder-only fields the sealer refused' `
        -Condition (@($recipeKeys | Where-Object { $_ -cin @('corpusRoot', 'correlationId', 'subject') }).Count -eq 0)
    Assert-CohortEntry -Name 'the recipe declares exactly the production key set' `
        -Condition ((($recipeKeys | Sort-Object -CaseSensitive) -join ',') -ceq ((@(
                    'binding', 'bindings', 'capture', 'capturedUtc', 'changeSet', 'changedFiles', 'corpus', 'evidence',
                    'hashes', 'kind', 'nonPromotable', 'provider', 'resources', 'schemaVersion', 'sealKind', 'snapshotId',
                    'sourceCensus', 'sourceTransport') | Sort-Object -CaseSensitive) -join ','))
    Assert-CohortEntry -Name 'the recipe binds a start identity and an end identity payload' `
        -Condition ([string]$recipe.capture.identity.corpusPath -cne [string]$recipe.capture.endIdentity.corpusPath -and
            [string]$recipe.capture.identity.corpusPath -and [string]$recipe.capture.endIdentity.corpusPath)

    function Get-CohortEntryCorpusPayload {
        param([Parameter(Mandatory)][string]$CorpusRoot, [Parameter(Mandatory)][string]$CorpusPath)
        $full = $CorpusRoot
        foreach ($segment in @($CorpusPath -split '/')) { $full = Join-Path $full $segment }
        return ([IO.File]::ReadAllText($full) | ConvertFrom-Json -Depth 32)
    }
    $corpusRootPath = Join-Path $result.Root 'corpus'
    $startIdentity = Get-CohortEntryCorpusPayload -CorpusRoot $corpusRootPath -CorpusPath ([string]$recipe.capture.identity.corpusPath)
    $endIdentity = Get-CohortEntryCorpusPayload -CorpusRoot $corpusRootPath -CorpusPath ([string]$recipe.capture.endIdentity.corpusPath)
    Assert-CohortEntry -Name 'the start identity payload is FLAT and carries every field the seal binds by name' `
        -Condition (@(@('commonCommit', 'isDraft', 'iterationId', 'pullRequestId', 'repositoryId', 'sourceCommit', 'status', 'targetCommit') |
                Where-Object { -not $startIdentity.PSObject.Properties[$_] }).Count -eq 0)
    Assert-CohortEntry -Name 'the start identity payload names no alias the seal would not read' `
        -Condition (-not $startIdentity.PSObject.Properties['lastMergeSourceCommit'])
    Assert-CohortEntry -Name 'the identity payloads carry no read timestamp to drift on' `
        -Condition (@(@(@($startIdentity.PSObject.Properties.Name) + @($endIdentity.PSObject.Properties.Name)) |
                Where-Object { $_ -match '(?i)utc|timestamp|readAt' }).Count -eq 0)
    Assert-CohortEntry -Name 'the end identity states that it matches the start of capture' `
        -Condition ([bool]$endIdentity.matchesInitialCapture)
    Assert-CohortEntry -Name 'the two identity reads agree on the source commit byte for byte' `
        -Condition ([string]$endIdentity.sourceCommit -ceq [string]$startIdentity.sourceCommit)

    # The census the seal derives spans from, in the sealer's own hunk form.
    # This is the same span evidence the witness publishes - one derivation,
    # rendered once - so a builder that hand-mapped an alias here would put the
    # recipe and its own witness at odds.
    $censusPayload = @(Get-CohortEntryCorpusPayload -CorpusRoot $corpusRootPath `
            -CorpusPath ([string]$recipe.changeSet.spanEvidence.corpusPath))
    $censusA = @($censusPayload | Where-Object { [string]$_.path -ceq '/src/a.ps1' })[0]
    Assert-CohortEntry -Name 'the span evidence payload is in the canonical newStart/newCount form' `
        -Condition ($censusA.hunks[0].PSObject.Properties['newStart'] -and $censusA.hunks[0].PSObject.Properties['newCount'])
    Assert-CohortEntry -Name 'the span evidence hunk is the span the witness publishes' `
        -Condition ([int]$censusA.hunks[0].newStart -eq [int]$spanA[0].start -and
            [int]$censusA.hunks[0].newCount -eq [int]$spanA[0].count)
    Assert-CohortEntry -Name 'the span evidence names no path with no right hand to show' `
        -Condition (@($censusPayload | Where-Object { [string]$_.path -ceq '/src/z-old.ps1' }).Count -eq 0)

    # The acceptance claim, run through the SHIPPING sealer script, in a child
    # process, exactly as the coordinator's snapshotValidateOnly stage runs it.
    function Invoke-CohortEntrySealValidate {
        param(
            [Parameter(Mandatory)][string]$CorpusRoot,
            [Parameter(Mandatory)][string]$CorpusIndexSha256,
            [Parameter(Mandatory)][string]$RecipePath,
            [Parameter(Mandatory)][string]$ReplayRoot
        )
        $previous = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        try {
            $output = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Save-CorpusReplaySeal.ps1') `
                -CorpusRoot $CorpusRoot -CorpusIndexSha256 $CorpusIndexSha256 `
                -Recipe $RecipePath -ReplayRoot $ReplayRoot -ValidateOnly 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ([string[]]@($output) -join "`n") }
        }
        finally { $PSNativeCommandUseErrorActionPreference = $previous }
    }
    $validated = Invoke-CohortEntrySealValidate -CorpusRoot $corpusRootPath -CorpusIndexSha256 $result.CorpusIndexSha256 `
        -RecipePath $recipePath -ReplayRoot (Join-Path $sandbox 'replay-accept')
    Assert-CohortEntry -Name 'the shipping sealer validates the builder-produced entry' -Condition ($validated.ExitCode -eq 0)
    Assert-CohortEntry -Name 'the shipping sealer wrote nothing under -ValidateOnly' `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $sandbox 'replay-accept') -PathType Container))

    # Sabotage. Each case is the SAME entry with one thing changed, re-indexed
    # with the production index writer so the refusal under test is the seal
    # contract and never a corpus integrity check standing in front of it.
    function Invoke-CohortEntrySealSabotage {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][scriptblock]$Mutate,
            [Parameter(Mandatory)][string]$Expected
        )
        $scratch = Join-Path $sandbox ("seal-" + [Guid]::NewGuid().ToString('n').Substring(0, 8))
        [void](New-Item -ItemType Directory -Force -Path $scratch)
        Copy-Item -LiteralPath $corpusRootPath -Destination (Join-Path $scratch 'corpus') -Recurse -Force
        Copy-Item -LiteralPath $recipePath -Destination (Join-Path $scratch 'recipe.json') -Force
        foreach ($file in @(Get-ChildItem -LiteralPath $scratch -Recurse -File -Force)) {
            $file.Attributes = [IO.FileAttributes]::Normal
        }
        $scratchCorpus = Join-Path $scratch 'corpus'
        $scratchRecipe = Join-Path $scratch 'recipe.json'
        $context = [pscustomobject]@{
            CorpusRoot = $scratchCorpus
            RecipePath = $scratchRecipe
            Recipe = ([IO.File]::ReadAllText($scratchRecipe) | ConvertFrom-Json -Depth 32)
        }
        & $Mutate $context
        # Re-mint the index over whatever the mutation left behind, in the exact
        # bytes New-ReviewerCohortEntryCorpus mints, so the sealer's integrity
        # check passes and its CONTRACT check is what speaks.
        $indexPath = Join-Path $scratchCorpus 'corpus-index.json'
        $existingIndex = [IO.File]::ReadAllText($indexPath) | ConvertFrom-Json -Depth 32
        $payloadFiles = @(Get-ChildItem -LiteralPath $scratchCorpus -Recurse -File -Force |
                Where-Object { $_.FullName -cne ([IO.Path]::GetFullPath($indexPath)) })
        $relatives = [string[]]@($payloadFiles | ForEach-Object {
                ([string]$_.FullName).Substring(([string]([IO.Path]::GetFullPath($scratchCorpus))).Length + 1).Replace('\', '/')
            })
        [Array]::Sort($relatives, [StringComparer]::Ordinal)
        $entries = @($relatives | ForEach-Object {
                $full = $scratchCorpus
                foreach ($segment in @($_ -split '/')) { $full = Join-Path $full $segment }
                $bytes = [IO.File]::ReadAllBytes($full)
                [ordered]@{ path = $_; sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes); length = $bytes.Length }
            })
        $rebuilt = [ordered]@{
            kind = 'private-immutable-non-promotable-research-corpus'
            repository = [string]$existingIndex.repository
            payloadCount = $entries.Count
            identities = $existingIndex.identities
            payloads = [object[]]$entries
        }
        [IO.File]::WriteAllBytes($indexPath, $script:Utf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $rebuilt)))
        $rebuiltIndexSha = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        # The recipe binds the index it was written for. Re-binding it here is what
        # makes every case below a statement about the SEAL contract rather than
        # about corpus integrity, which is already proven elsewhere.
        if ($context.Recipe.PSObject.Properties['corpus']) {
            $context.Recipe.corpus.indexSha256 = $rebuiltIndexSha
            $context.Recipe.corpus.payloadCount = $entries.Count
        }
        Write-CohortEntryJsonFile -Path $scratchRecipe -Value $context.Recipe
        $sabotaged = Invoke-CohortEntrySealValidate -CorpusRoot $scratchCorpus `
            -CorpusIndexSha256 $rebuiltIndexSha `
            -RecipePath $scratchRecipe -ReplayRoot (Join-Path $scratch 'replay')
        Assert-CohortEntry -Name $Name -Condition ($sabotaged.ExitCode -ne 0 -and $sabotaged.Text -clike "*$Expected*")
    }
    function Set-CohortEntryScratchPayload {
        param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$CorpusPath, [Parameter(Mandatory)]$Value)
        $full = $Context.CorpusRoot
        foreach ($segment in @($CorpusPath -split '/')) { $full = Join-Path $full $segment }
        $bytes = $script:Utf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $Value))
        [IO.File]::WriteAllBytes($full, $bytes)
        return $bytes
    }
    $startIdentityPath = [string]$recipe.capture.identity.corpusPath
    $endIdentityPath = [string]$recipe.capture.endIdentity.corpusPath
    $spanEvidencePath = [string]$recipe.changeSet.spanEvidence.corpusPath

    Invoke-CohortEntrySealSabotage -Name 'a recipe carrying an extra field is refused by the sealer' `
        -Expected 'unexpected field' -Mutate {
        param($ctx) $ctx.Recipe | Add-Member -NotePropertyName 'corpusRoot' -NotePropertyValue 'C:/somewhere'
    }
    Invoke-CohortEntrySealSabotage -Name 'a recipe that binds no start identity is refused by the sealer' `
        -Expected 'identity' -Mutate {
        param($ctx) $ctx.Recipe.capture.PSObject.Properties.Remove('identity')
    }
    Invoke-CohortEntrySealSabotage -Name 'a start identity payload naming an alias instead of the field is refused' `
        -Expected "omits 'sourceCommit'" -Mutate {
        param($ctx)
        $payload = Get-CohortEntryCorpusPayload -CorpusRoot $ctx.CorpusRoot -CorpusPath $startIdentityPath
        $aliased = [ordered]@{}
        foreach ($property in @($payload.PSObject.Properties)) {
            if ($property.Name -ceq 'sourceCommit') { $aliased['lastMergeSourceCommit'] = $property.Value }
            else { $aliased[$property.Name] = $property.Value }
        }
        $bytes = [byte[]](Set-CohortEntryScratchPayload -Context $ctx -CorpusPath $startIdentityPath -Value $aliased)
        $ctx.Recipe.capture.identity.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
        $ctx.Recipe.capture.identity.byteLength = $bytes.Length
    }
    Invoke-CohortEntrySealSabotage -Name 'an end identity whose source commit drifted mid-capture is refused' `
        -Expected 'moved while it was being captured' -Mutate {
        param($ctx)
        $payload = Get-CohortEntryCorpusPayload -CorpusRoot $ctx.CorpusRoot -CorpusPath $endIdentityPath
        $drifted = [ordered]@{}
        foreach ($property in @($payload.PSObject.Properties)) { $drifted[$property.Name] = $property.Value }
        $drifted['sourceCommit'] = ('d' * 40)
        $bytes = [byte[]](Set-CohortEntryScratchPayload -Context $ctx -CorpusPath $endIdentityPath -Value $drifted)
        $ctx.Recipe.capture.endIdentity.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
        $ctx.Recipe.capture.endIdentity.byteLength = $bytes.Length
    }
    Invoke-CohortEntrySealSabotage -Name 'a census in lineDiffBlocks form rather than hunks is refused' `
        -Expected 'hunks' -Mutate {
        param($ctx)
        $payload = @(Get-CohortEntryCorpusPayload -CorpusRoot $ctx.CorpusRoot -CorpusPath $spanEvidencePath)
        $bytes = [byte[]](Set-CohortEntryScratchPayload -Context $ctx -CorpusPath $spanEvidencePath -Value ([object[]]@(
                    $payload | ForEach-Object {
                        [ordered]@{
                            path = [string]$_.path
                            lineDiffBlocks = [object[]]@(@($_.hunks) | ForEach-Object {
                                    [ordered]@{ mLine = [int]$_.newStart; mLinesCount = [int]$_.newCount }
                                })
                        }
                    })))
        $ctx.Recipe.changeSet.spanEvidence.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
        $ctx.Recipe.changeSet.spanEvidence.byteLength = $bytes.Length
    }
    Invoke-CohortEntrySealSabotage -Name 'a census hunk that is not the span the changed file declares is refused' `
        -Expected 'span evidence derives' -Mutate {
        param($ctx)
        $payload = @(Get-CohortEntryCorpusPayload -CorpusRoot $ctx.CorpusRoot -CorpusPath $spanEvidencePath)
        $bytes = [byte[]](Set-CohortEntryScratchPayload -Context $ctx -CorpusPath $spanEvidencePath -Value ([object[]]@(
                    $payload | ForEach-Object {
                        [ordered]@{
                            path = [string]$_.path
                            hunks = [object[]]@(@($_.hunks) | ForEach-Object {
                                    [ordered]@{ newStart = ([int]$_.newStart + 1); newCount = [int]$_.newCount }
                                })
                        }
                    })))
        $ctx.Recipe.changeSet.spanEvidence.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
        $ctx.Recipe.changeSet.spanEvidence.byteLength = $bytes.Length
    }
    Invoke-CohortEntrySealSabotage -Name 'a census rendered as one object rather than a list is refused' `
        -Expected 'must be a JSON array' -Mutate {
        param($ctx)
        $payload = @(Get-CohortEntryCorpusPayload -CorpusRoot $ctx.CorpusRoot -CorpusPath $spanEvidencePath)
        $bytes = [byte[]](Set-CohortEntryScratchPayload -Context $ctx -CorpusPath $spanEvidencePath -Value ([ordered]@{
                    path = [string]$payload[0].path
                    hunks = [object[]]@(@($payload[0].hunks) | ForEach-Object {
                            [ordered]@{ newStart = [int]$_.newStart; newCount = [int]$_.newCount }
                        })
                }))
        $ctx.Recipe.changeSet.spanEvidence.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
        $ctx.Recipe.changeSet.spanEvidence.byteLength = $bytes.Length
    }
    Invoke-CohortEntrySealSabotage -Name 'a digest order that is not the order the change set names is refused' `
        -Expected 'order' -Mutate {
        param($ctx)
        $order = [string[]]@($ctx.Recipe.changeSet.digestOrder)
        $ctx.Recipe.changeSet.digestOrder = [string[]]@($order[($order.Count - 1)..0])
    }

    Assert-CohortEntry -Name 'the published package re-verifies' `
        -Condition (Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath)

    $sample = Join-Path $result.Root 'entry/cohort-entry.json'
    Assert-CohortEntry -Name 'a published file is read-only' `
        -Condition (((Get-Item -LiteralPath $sample -Force).Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)

    # A package whose bytes changed after it was sealed must not re-verify. The
    # read-only bit is put back so the refusal is about the BYTES, not the flag.
    $sampleBytes = [IO.File]::ReadAllBytes($sample)
    (Get-Item -LiteralPath $sample -Force).Attributes = [IO.FileAttributes]::Normal
    Add-Content -LiteralPath $sample -Value ' '
    (Get-Item -LiteralPath $sample -Force).Attributes = [IO.FileAttributes]::ReadOnly
    Assert-CohortEntry -Name 'a mutated published package refuses CE503' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath
            }) -ceq 'CE503')
    # Put the sealed bytes back, and prove the seal is a function of the bytes
    # rather than a one-way tripwire: the same package verifies again.
    (Get-Item -LiteralPath $sample -Force).Attributes = [IO.FileAttributes]::Normal
    [IO.File]::WriteAllBytes($sample, $sampleBytes)
    (Get-Item -LiteralPath $sample -Force).Attributes = [IO.FileAttributes]::ReadOnly
    Assert-CohortEntry -Name 'the restored package verifies again' `
        -Condition (Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath)

    # The inventory and its seal cannot inventory themselves, so they are the two
    # files an editor would leave writable in order to re-seal a package they had
    # changed. Both are checked by name.
    $inventoryPath = Join-Path $result.Root 'inventory.json'
    (Get-Item -LiteralPath $inventoryPath -Force).Attributes = [IO.FileAttributes]::Normal
    Assert-CohortEntry -Name 'a writable inventory refuses CE502' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath
            }) -ceq 'CE502')
    (Get-Item -LiteralPath $inventoryPath -Force).Attributes = [IO.FileAttributes]::ReadOnly

    $sealPath = Join-Path $result.Root 'inventory.seal'
    (Get-Item -LiteralPath $sealPath -Force).Attributes = [IO.FileAttributes]::Normal
    Assert-CohortEntry -Name 'a writable inventory seal refuses CE502' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath
            }) -ceq 'CE502')
    (Get-Item -LiteralPath $sealPath -Force).Attributes = [IO.FileAttributes]::ReadOnly
    Assert-CohortEntry -Name 'the re-frozen package verifies again' `
        -Condition (Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath)

    # A file the inventory does not name, planted next to files it does. The file
    # COUNT is unchanged in the substitution sense only if something was also
    # removed - so this is the cheaper half of the same defect, and it is the
    # half a count-only check would still catch. The set comparison catches both.
    $plantedPath = Join-Path $result.Root 'entry/planted.json'
    [IO.File]::WriteAllText($plantedPath, '{}')
    Assert-CohortEntry -Name 'an unlisted file inside a sealed package refuses CE503' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath
            }) -ceq 'CE503')
    (Get-Item -LiteralPath $plantedPath -Force).Attributes = [IO.FileAttributes]::Normal
    Remove-Item -LiteralPath $plantedPath -Force

    # A doctored inventory that names a path OUTSIDE the package. Re-sealed with
    # the real key, so the seal authenticates it and the only thing standing
    # between the verifier and a file in another directory is the path-shape
    # check. Substitution is exact: one recorded path swapped, count unchanged.
    $realInventoryBytes = [IO.File]::ReadAllBytes($inventoryPath)
    $realSealBytes = [IO.File]::ReadAllBytes($sealPath)
    $doctored = [IO.File]::ReadAllText($inventoryPath).Replace('"entry/cohort-entry.json"', '"../outside.json"')
    (Get-Item -LiteralPath $inventoryPath -Force).Attributes = [IO.FileAttributes]::Normal
    (Get-Item -LiteralPath $sealPath -Force).Attributes = [IO.FileAttributes]::Normal
    [IO.File]::WriteAllBytes($inventoryPath, [Text.UTF8Encoding]::new($false).GetBytes($doctored))
    $reseal = [System.Security.Cryptography.HMACSHA256]::new((Get-ReviewerCohortEntrySealKey -Path $fixture.SealKeyPath))
    try {
        [IO.File]::WriteAllBytes($sealPath, [Text.UTF8Encoding]::new($false).GetBytes(
                [Convert]::ToHexString($reseal.ComputeHash([IO.File]::ReadAllBytes($inventoryPath))).ToLowerInvariant()))
    }
    finally { $reseal.Dispose() }
    (Get-Item -LiteralPath $inventoryPath -Force).Attributes = [IO.FileAttributes]::ReadOnly
    (Get-Item -LiteralPath $sealPath -Force).Attributes = [IO.FileAttributes]::ReadOnly
    Assert-CohortEntry -Name 'an authentically sealed inventory naming a path outside the package refuses CE506' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath
            }) -ceq 'CE506')
    (Get-Item -LiteralPath $inventoryPath -Force).Attributes = [IO.FileAttributes]::Normal
    (Get-Item -LiteralPath $sealPath -Force).Attributes = [IO.FileAttributes]::Normal
    [IO.File]::WriteAllBytes($inventoryPath, $realInventoryBytes)
    [IO.File]::WriteAllBytes($sealPath, $realSealBytes)
    (Get-Item -LiteralPath $inventoryPath -Force).Attributes = [IO.FileAttributes]::ReadOnly
    (Get-Item -LiteralPath $sealPath -Force).Attributes = [IO.FileAttributes]::ReadOnly
    Assert-CohortEntry -Name 'the package verifies once the real inventory is back' `
        -Condition (Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath)

    # The output root already holds a package, so a second build must refuse.
    Assert-CohortEntry -Name 'a second build into an occupied root refuses CE500' `
        -Condition ((Get-CohortEntryRefusalCode -Action { New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath -PreparationOnly }) -ceq 'CE500')
}
finally { Remove-CohortEntrySandbox -Path $sandbox }

# -------------------------------------------------------------------------
# A toolkit that ships no source-transport policy cannot produce a sealable
# entry, because the seal derives its transport artifact UNDER that policy.
# Refusing at build time is the whole point: the alternative is an entry that
# publishes, is accepted by a manifest and dies four coordinator states later.
$sandbox = New-CohortEntrySandbox -Name 'no-policy'
try {
    $fixture = New-CohortEntryFixture -Sandbox $sandbox
    $policyPath = Join-Path $fixture.Toolkit 'src/Agents/reviewer/source/v1/policy.json'
    Remove-Item -LiteralPath $policyPath -Force
    # Committed, so the toolkit tree is CLEAN and the refusal under test is the
    # missing policy rather than the dirty-tree guard standing in front of it.
    [void](& git -C $fixture.Toolkit add -A 2>&1)
    [void](& git -C $fixture.Toolkit -c user.name=fixture -c user.email=fixture@local commit -m 'drop policy' --quiet 2>&1)
    $noPolicyHead = ([string](& git -C $fixture.Toolkit rev-parse HEAD)).Trim()
    $noPolicyRequest = [IO.File]::ReadAllText($fixture.RequestPath) | ConvertFrom-Json -Depth 32
    $noPolicyRequest.toolkit.head = $noPolicyHead
    Write-CohortEntryJsonFile -Path $fixture.RequestPath -Value $noPolicyRequest
    $noPolicyCode = Get-CohortEntryRefusalCode -Action { New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath -PreparationOnly }
    Assert-CohortEntry -Name "a pinned toolkit shipping no source-transport policy refuses CE803 (observed '$noPolicyCode')" `
        -Condition ($noPolicyCode -ceq 'CE803')
}
finally { Remove-CohortEntrySandbox -Path $sandbox }

# -------------------------------------------------------------------------
# ONE changed file is an ordinary pull request, and the shape where a census
# built through the pipeline stops being a list: PowerShell unrolls a one-element
# array, the canonical writer renders a JSON object, and the sealer refuses a
# census that is not an array. The default fixture carries two right-hand paths,
# so only a deliberately single-path build sees it.
Write-Host 'a single changed file still censuses as a list' -ForegroundColor Cyan
$sandbox = New-CohortEntrySandbox -Name 'one-file'
try {
    $oneFile = New-CohortEntryFixture -Sandbox $sandbox -Mutate {
        param($state)
        $state.ChangesBody = [ordered]@{
            iterationId = 3
            changes = @(
                [ordered]@{ changeId = 1; changeType = 'Edit'; item = [ordered]@{ path = '/src/a.ps1'; isFolder = $false } }
            )
        }
        $state.DiffChangesBody = [ordered]@{
            iterationId = 3
            changes = @(
                [ordered]@{
                    changeId = 1; changeType = 'Edit'; item = [ordered]@{ path = '/src/a.ps1'; isFolder = $false }
                    diff = [ordered]@{
                        path = '/src/a.ps1'
                        lineDiffBlocks = @(
                            [ordered]@{ changeType = 0; originalLineNumberStart = 1; originalLinesCount = 1; modifiedLineNumberStart = 1; modifiedLinesCount = 1 },
                            [ordered]@{ changeType = 1; originalLineNumberStart = 0; originalLinesCount = 0; modifiedLineNumberStart = 2; modifiedLinesCount = 2 }
                        )
                    }
                }
            )
        }
        $state.FileTexts = [ordered]@{ '/src/a.ps1' = "function A {`n    'right hand'`n}`n" }
    }
    $oneResult = New-ReviewerCohortEntryEvidence -RequestPath $oneFile.RequestPath -PreparationOnly
    $oneCorpusRoot = Join-Path ([string]$oneResult.Root) 'corpus'
    $oneCensusText = [IO.File]::ReadAllText((Join-Path $oneCorpusRoot 'census/right-hand-hunks.json'))
    Assert-CohortEntry -Name 'a one-path census is still a JSON array' `
        -Condition ($oneCensusText.TrimStart().StartsWith('['))
    $oneCensus = @($oneCensusText | ConvertFrom-Json -Depth 20)
    Assert-CohortEntry -Name 'the one-path census names the one right-hand path' `
        -Condition (@($oneCensus).Count -eq 1 -and [string]@($oneCensus)[0].path -ceq '/src/a.ps1')
    $oneRecipePath = Join-Path ([string]$oneResult.Root) 'entry/corpus-seal-recipe.json'
    $oneIndexSha = [string]$oneResult.CorpusIndexSha256
    $oneSeal = Invoke-CohortEntrySealValidate -CorpusRoot $oneCorpusRoot -CorpusIndexSha256 $oneIndexSha `
        -RecipePath $oneRecipePath -ReplayRoot (Join-Path $sandbox 'one-file-replay')
    Assert-CohortEntry -Name 'the shipping sealer accepts a single-file entry' `
        -Condition ($oneSeal.ExitCode -eq 0)
}
finally { if (-not $KeepSandbox) { Remove-CohortEntrySandbox -Path $sandbox } else { Write-Host "sandbox kept: $sandbox" } }

# -------------------------------------------------------------------------
Write-Host 'sabotage: one case per historical assembly incident' -ForegroundColor Cyan

Invoke-CohortEntryCase -Name 'a request carrying a byte-order mark' -ExpectedCode 'CE101' -Mutate {
    param($state) $state.RequestWithBom = $true
}

# The toolkit head is read from git, but everything downstream is read from the
# WORKING TREE. A tracked edit that is not in the pinned commit produces evidence
# attributed to a commit that never contained the code that produced it.
Write-Host 'sabotage: an uncommitted toolkit edit' -ForegroundColor Cyan
$dirtySandbox = New-CohortEntrySandbox -Name 'dirty'
try {
    $dirtyFixture = New-CohortEntryFixture -Sandbox $dirtySandbox
    $dirtyToolkit = Join-Path $dirtySandbox 'toolkit'
    $promptPath = Join-Path $dirtyToolkit 'src/Agents/reviewer/review-cycle.prompt.md'
    [IO.File]::WriteAllBytes($promptPath,
        [Text.UTF8Encoding]::new($false).GetBytes("# fixture review cycle`nedited after the commit`n"))
    Assert-CohortEntry -Name 'a tracked uncommitted toolkit edit refuses CE213' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                New-ReviewerCohortEntryEvidence -RequestPath $dirtyFixture.RequestPath -PreparationOnly
            }) -ceq 'CE213')
    # An UNTRACKED file changes nothing the builder reads and must not refuse,
    # or the builder is unusable in the working directories operators have.
    [IO.File]::WriteAllBytes($promptPath,
        [Text.UTF8Encoding]::new($false).GetBytes("# fixture review cycle`n"))
    [IO.File]::WriteAllText((Join-Path $dirtyToolkit 'src/scratch.tmp'), 'scratch')
    Assert-CohortEntry -Name 'an untracked scratch file in the toolkit is accepted' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                New-ReviewerCohortEntryEvidence -RequestPath $dirtyFixture.RequestPath -PreparationOnly
            }) -ceq '')
}
finally { Remove-CohortEntrySandbox -Path $dirtySandbox }

# A hosted pull_request run checks out a MERGE COMMIT, not a branch, so the
# checkout is detached. Two separate defects met there and only there: the
# fixture pinned 'refs/heads/HEAD', which resolves nowhere, and the builder read
# git's empty answer with a direct [string] cast - which yields $null for a
# command that wrote nothing - so the ref that did not resolve crashed with a
# null-reference instead of raising the catalogued CE201. The suite passed on
# every attached developer checkout and failed on every hosted one.
Write-Host 'sabotage: a detached checkout and a ref that resolves nowhere' -ForegroundColor Cyan
$detachedSandbox = New-CohortEntrySandbox -Name 'detached'
try {
    $detachedFixture = New-CohortEntryFixture -Sandbox $detachedSandbox
    $detachedToolkit = Join-Path $detachedSandbox 'toolkit'
    $detachedHead = Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', 'HEAD')

    # The unresolvable ref must be REFUSED, by code, rather than crash.
    $detachedRequestPath = Join-Path $detachedSandbox 'unresolvable-ref-request.json'
    $detachedRequest = ([IO.File]::ReadAllText($detachedFixture.RequestPath)) | ConvertFrom-Json -Depth 32
    $detachedRequest.toolkit.requiredRef = 'refs/heads/HEAD'
    [IO.File]::WriteAllBytes($detachedRequestPath,
        $script:Utf8.GetBytes([string]($detachedRequest | ConvertTo-Json -Depth 32 -Compress)))
    $unresolvableCode = Get-CohortEntryRefusalCode -Action {
        New-ReviewerCohortEntryEvidence -RequestPath $detachedRequestPath -PreparationOnly
    }
    Assert-CohortEntry -Name 'a required ref that resolves nowhere refuses CE201 rather than crashing' `
        -Condition ($unresolvableCode -ceq 'CE201')

    # And the ref this suite derives has to resolve on a detached checkout, which
    # is the state every hosted run is in.
    & git -C $detachedToolkit checkout --quiet --detach $detachedHead 2>&1 | Out-Null
    $abbrev = Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--abbrev-ref', 'HEAD')
    Assert-CohortEntry -Name 'the fixture toolkit really is detached' -Condition ($abbrev -ceq 'HEAD')
    $detachedBuildCode = Get-CohortEntryRefusalCode -Action {
        New-ReviewerCohortEntryEvidence -RequestPath $detachedFixture.RequestPath -PreparationOnly
    }
    Assert-CohortEntry -Name 'a build against a detached toolkit is not refused' `
        -Condition ($detachedBuildCode -ceq '')
    $derivedRef = Get-CohortEntryToolkitRef -ToolkitRoot $detachedToolkit -Head $detachedHead
    $derivedCommit = Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--verify', '--quiet',
        "$derivedRef^{commit}")
    Assert-CohortEntry -Name 'the ref derived for a detached checkout resolves to its head' `
        -Condition ($derivedCommit -ceq $detachedHead)
    Assert-CohortEntry -Name 'the ref derived for a detached checkout is never refs/heads/HEAD' `
        -Condition ($derivedRef -cne 'refs/heads/HEAD')

    # The runner's case exactly: a commit no ref points at, because the merge
    # commit it checks out exists only in its own clone.
    & git -C $detachedToolkit commit --quiet --allow-empty -m 'detached tip' 2>&1 | Out-Null
    $tip = Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', 'HEAD')
    # A ref another worktree or a concurrent run already holds is not this
    # fixture's to take. The squatter sits on the name a fixed-name fixture
    # would have used, pointing at a DIFFERENT commit, and is planted BEFORE the
    # derivation below so the derivation actually has to route around an
    # occupied name - a squatter planted afterwards would leave that property
    # untested and survive cleanup even under the fixed-name code.
    $squatter = 'refs/cohort-entry-fixture/head'
    & git -C $detachedToolkit update-ref $squatter $detachedHead 2>&1 | Out-Null
    $tipRef = Get-CohortEntryToolkitRef -ToolkitRoot $detachedToolkit -Head $tip
    $tipCommit = Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--verify', '--quiet',
        "$tipRef^{commit}")
    Assert-CohortEntry -Name 'a head no ref points at still derives a ref that resolves to it' `
        -Condition ($tipCommit -ceq $tip -and $tip -cne $detachedHead)

    # Resolving is not the property that matters: the derived ref has to be a
    # value a REQUEST can carry. 'HEAD' resolves and is refused as malformed, so
    # the only assertion that covers the runner's case is a build pinned to it.
    $tipRequestPath = Join-Path $detachedSandbox 'derived-ref-request.json'
    $tipRequest = ([IO.File]::ReadAllText($detachedFixture.RequestPath)) | ConvertFrom-Json -Depth 32
    $tipRequest.toolkit.requiredRef = $tipRef
    $tipRequest.toolkit.head = $tip
    # A fresh output root: the build above already populated the fixture's, and a
    # destination that already holds evidence is refused on its own terms (CE500),
    # which would mask whatever this case is actually asking about.
    $tipRequest.output.root = Join-Path $detachedSandbox 'private/derived-ref-entry'
    [IO.File]::WriteAllBytes($tipRequestPath,
        $script:Utf8.GetBytes([string]($tipRequest | ConvertTo-Json -Depth 32 -Compress)))
    $tipBuildCode = Get-CohortEntryRefusalCode -Action {
        New-ReviewerCohortEntryEvidence -RequestPath $tipRequestPath -PreparationOnly
    }
    Assert-CohortEntry -Name "a request pinned to the derived ref is accepted, not refused as malformed (observed '$tipBuildCode')" `
        -Condition ($tipBuildCode -ceq '')
    # A delete that does not take keeps its record. The ref is moved out from
    # under the fixture here - exactly what a concurrent holder would do - so the
    # value-checked delete refuses it. A cleanup that cleared its records anyway
    # would leave that ref sitting in a repository the fixture did not make, with
    # nothing left to retry it or name it.
    & git -C $detachedToolkit update-ref $tipRef $detachedHead 2>&1 | Out-Null
    Remove-CohortEntryCreatedRef
    Assert-CohortEntry -Name 'a ref moved out from under the fixture is neither deleted nor forgotten' `
        -Condition (@($script:CohortEntryCreatedRefs).Count -eq 1 -and
            (Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--verify', '--quiet',
                "$tipRef^{commit}")) -ceq $detachedHead)
    # Put it back at the value the fixture recorded, so the cleanup below is the
    # one actually under test rather than a second refusal.
    & git -C $detachedToolkit update-ref $tipRef $tip 2>&1 | Out-Null

    # Moved to a NON-COMMIT object. The value-checked delete still refuses, and a
    # cleanup that read absence from '<ref>^{commit}' would see nothing there and
    # forget the record while the ref went on pinning that object forever.
    $tipTree = Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', 'HEAD^{tree}')
    & git -C $detachedToolkit update-ref $tipRef $tipTree 2>&1 | Out-Null
    $tipTreeHeld = Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--verify', '--quiet',
        $tipRef)
    Assert-CohortEntry -Name 'a fixture ref can be pointed at a non-commit object at all' `
        -Condition ($tipTreeHeld -ceq $tipTree -and $tipTree -cne $tip)
    Remove-CohortEntryCreatedRef
    Assert-CohortEntry -Name 'a ref moved to a non-commit object is neither deleted nor forgotten' `
        -Condition (@($script:CohortEntryCreatedRefs).Count -eq 1 -and
            (Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--verify', '--quiet',
                $tipRef)) -ceq $tipTree)
    & git -C $detachedToolkit update-ref $tipRef $tip 2>&1 | Out-Null

    # Nothing this fixture created in a repository it did not make is left
    # behind - a ref in a worktree lands in the shared common store and holds
    # its commit against gc forever. Removed here rather than at the end of the
    # suite, so a case that throws still cleans up after itself.
    #
    # The name is unique per call and the creation states an all-zero old value,
    # so the occupied name planted above is never overwritten - and the cleanup,
    # which can only check the value it wrote, can never delete a ref it did not
    # create.
    Assert-CohortEntry -Name 'the derived ref takes a name of its own rather than a shared one' `
        -Condition ($tipRef -cne $squatter -and $tipRef -cmatch '^refs/cohort-entry-fixture/[0-9a-f]{32}$')
    $createdBefore = @($script:CohortEntryCreatedRefs).Count
    Remove-CohortEntryCreatedRef
    Assert-CohortEntry -Name 'the fixture created a ref for the head no ref pointed at' -Condition ($createdBefore -ge 1)
    $tipAfterRemoval = Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--verify', '--quiet',
        "$tipRef^{commit}")
    Assert-CohortEntry -Name 'the ref the fixture created is taken back, leaving the repository as it was' `
        -Condition ($tipAfterRemoval -ceq '' -and @($script:CohortEntryCreatedRefs).Count -eq 0)
    Assert-CohortEntry -Name 'a ref the fixture did not create survives its cleanup' `
        -Condition ((Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--verify', '--quiet',
                "$squatter^{commit}")) -ceq $detachedHead)
    Assert-CohortEntry -Name 'taking the ref back leaves the commit itself alone' `
        -Condition ((Get-CohortEntryGitLine -Arguments @('-C', $detachedToolkit, 'rev-parse', '--verify', '--quiet',
                "$tip^{commit}")) -ceq $tip)
}
finally { Remove-CohortEntryCreatedRef; Remove-CohortEntrySandbox -Path $detachedSandbox }

Invoke-CohortEntryCase -Name 'a RAW repository body with a flat project' -ExpectedCode 'CE203' -Mutate {
    param($state)
    $state.RepositoryBody = [ordered]@{
        id = $state.RepositoryId
        name = $state.RepositoryName
        project = [ordered]@{ id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; name = $state.Project }
    }
}

Invoke-CohortEntryCase -Name 'a repository identity for another repository' -ExpectedCode 'CE204' -Mutate {
    param($state) $state.RepositoryBody.id = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
}

Invoke-CohortEntryCase -Name 'an invented flat sourceCommit alias' -ExpectedCode 'CE210' -Mutate {
    param($state)
    $body = [ordered]@{}
    foreach ($key in @($state.PullRequestBody.Keys)) {
        if ($key -ceq 'lastMergeSourceCommit') { continue }
        $body[$key] = $state.PullRequestBody[$key]
    }
    $body['sourceCommit'] = $state.SourceCommit
    $state.PullRequestBody = $body
}

Invoke-CohortEntryCase -Name 'a common-commit alias in place of lastMergeCommit' -ExpectedCode 'CE210' -Mutate {
    param($state)
    $body = [ordered]@{}
    foreach ($key in @($state.PullRequestBody.Keys)) {
        if ($key -ceq 'lastMergeCommit') { continue }
        $body[$key] = $state.PullRequestBody[$key]
    }
    $body['commonCommit'] = $state.CommonCommit
    $state.PullRequestBody = $body
}

Invoke-CohortEntryCase -Name 'an exact key present but null' -ExpectedCode 'CE210' -Mutate {
    param($state) $state.PullRequestBody.lastMergeSourceCommit = $null
}

Invoke-CohortEntryCase -Name 'a thread list in the {value:[...]} envelope' -ExpectedCode '' -Mutate {
    param($state) $state.ThreadsBody = [ordered]@{ value = @([ordered]@{ id = 1; comments = @() }) }
}

Invoke-CohortEntryCase -Name 'a thread list in the {threads:[...]} envelope' -ExpectedCode '' -Mutate {
    param($state) $state.ThreadsBody = [ordered]@{ threads = @([ordered]@{ id = 1; comments = @() }) }
}

Invoke-CohortEntryCase -Name 'a thread list answered as one bare thread object' -ExpectedCode 'CE210' -Mutate {
    param($state) $state.ThreadsBody = [ordered]@{ id = 1; status = 'active' }
}

Invoke-CohortEntryCase -Name 'a change set written as a singleton object' -ExpectedCode 'CE210' -Mutate {
    param($state)
    $state.ChangesBody = [ordered]@{
        iterationId = 3
        changes = [ordered]@{ changeId = 1; changeType = 'Edit'; item = [ordered]@{ path = '/src/a.ps1' } }
    }
}

# The raw Azure DevOps iteration-changes shape names its collection
# 'changeEntries' and puts the path one level up. The wrapper contract names it
# 'changes' and puts the path under 'item'. Interpreting one as the other is the
# raw-versus-contract confusion, and it is refused by name rather than coped with.
Invoke-CohortEntryCase -Name 'a change set in the raw provider changeEntries shape' -ExpectedCode 'CE203' -Mutate {
    param($state)
    $state.ChangesBody = [ordered]@{
        iterationId = 3
        changeEntries = @([ordered]@{ changeTrackingId = 1; changeType = 'edit'; item = [ordered]@{ path = '/src/a.ps1' } })
    }
}

Invoke-CohortEntryCase -Name 'a change entry carrying a bare path instead of an item' -ExpectedCode 'CE210' -Mutate {
    param($state)
    $state.ChangesBody.changes = @([ordered]@{ changeId = 1; changeType = 'Edit'; path = '/src/a.ps1' })
}

# A span list that walks off the end of the file it claims to describe. The diff
# and the file arrive on two independent reads, so nothing but this check
# compares them - and a reviewer handed such a span slices bytes that are not the
# bytes the span names.
Invoke-CohortEntryCase -Name 'a right-hand span running past the end of the captured file' -ExpectedCode 'CE404' -Mutate {
    param($state)
    $state.DiffChangesBody.changes[0].diff.lineDiffBlocks[1].modifiedLinesCount = 40
}

Invoke-CohortEntryCase -Name 'a right-hand span starting past the end of the captured file' -ExpectedCode 'CE404' -Mutate {
    param($state)
    $state.DiffChangesBody.changes[0].diff.lineDiffBlocks[1].modifiedLineNumberStart = 90
}

Invoke-CohortEntryCase -Name 'a change set carrying no changed path at all' -ExpectedCode 'CE407' -Mutate {
    param($state)
    $state.ChangesBody = [ordered]@{ iterationId = 3; changes = @() }
}

# The two get_changes variants are DIFFERENT reads, and a snapshot that recorded
# only the plain one is a snapshot with a hole in it. CE307 rather than CE300:
# the read was planned AND issued, and the replay refused to reach the provider
# for it. CE300 is the other shape - a planned read that was never issued at all
# - and an operator matching on the code has to be able to tell them apart.
Invoke-CohortEntryCase -Name 'a snapshot missing the get_changes diff variant' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.OmitDiffVariant = $true
}

# THE shadow #10 defect, as a test. The corpus recorded the thread list under
# top=201 - one above the operator's cap, which is the right instinct for a read
# the builder owns and the wrong one for a read it does not - while the live
# cycle asks for the production page. The slot reached its first cycle, asked for
# threads, got nothing, and died before a single model start. It must not be
# possible to publish that corpus again: same code, same shape, refused at build.
Invoke-CohortEntryCase -Name 'a corpus recording the thread list one above the reviewer page' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ThreadListTop = (Get-ReviewerThreadListTop) + 1
}

Invoke-CohortEntryCase -Name 'a corpus recording the thread list one below the reviewer page' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ThreadListTop = (Get-ReviewerThreadListTop) - 1
}

# The identity keys of the same read, each on its own, because a corpus that got
# the page right and the project wrong fails exactly as fatally and an operator
# has to see which key moved.
Invoke-CohortEntryCase -Name 'a corpus recording the thread list under another project' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ThreadReadProjectOverride = 'OtherProject'
}

Invoke-CohortEntryCase -Name 'a corpus recording the thread list under the repository GUID' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ThreadReadRepositoryOverride = $state.RepositoryId
}

Invoke-CohortEntryCase -Name 'a corpus recording the thread list for another pull request' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ThreadReadPullRequestOverride = ([int]$state.PullRequestId + 1)
}

# The cap policy, stated where it is decided. The read asks for the production
# page, so a cap ABOVE that page is a ceiling this build could never watch being
# crossed - it would call a truncated census complete. A request the operator can
# fix by editing JSON gets the request band; the evidence band below means the
# subject itself is too large and no edit helps.
Invoke-CohortEntryCase -Name 'a request capping threads above the page the reviewer asks for' -ExpectedCode 'CE113' -Mutate {
    param($state) $state.MaxThreads = (Get-ReviewerThreadListTop) + 1
}

# And a list that FILLS the page proves nothing either way, so it is refused
# rather than assumed complete.
Invoke-CohortEntryCase -Name 'a thread list that exactly fills the reviewer page' -ExpectedCode 'CE408' -Mutate {
    param($state)
    $state.MaxThreads = (Get-ReviewerThreadListTop)
    $state.ThreadsBody = [ordered]@{ value = @(1..(Get-ReviewerThreadListTop) | ForEach-Object {
                [ordered]@{ id = $_; status = 'active'; comments = @([ordered]@{ id = $_; content = "c$_"; commentType = 'text' }) }
            }) }
}

# THE shadow #10 defect the SECOND time, in the read next door. The corpus
# recorded both change reads at the operator cap plus one - the same defensible
# instinct, the same fatal result - while the live convention planner asked for
# the production page. That slot got PAST the corrected thread read, printed its
# scope, computed its coverage, and died on this. Same code, same shape, refused
# at build so the corpus cannot be published again.
Invoke-CohortEntryCase -Name 'a corpus recording the change reads at the operator cap plus one' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeListTop = ([int]$state.MaxChangedFiles + 1)
}

Invoke-CohortEntryCase -Name 'a corpus recording the change reads one above the reviewer page' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeListTop = (Get-ReviewerChangeListTop) + 1
}

Invoke-CohortEntryCase -Name 'a corpus recording the change reads one below the reviewer page' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeListTop = (Get-ReviewerChangeListTop) - 1
}

# The page as a STRING. It replays through any comparison that stringifies and
# fails the one the wrapper actually keys on, which is the whole request object -
# so a corpus that looks right in a diff answers nothing.
Invoke-CohortEntryCase -Name 'a corpus recording the change page as a string' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeReadTopAsString = $true
}

# The include flags are what make the diff-bearing read a DIFFERENT read. Drop
# either one and the recorded key is the plain read's key wearing the diff read's
# payload, so the diff read itself goes unanswered.
Invoke-CohortEntryCase -Name 'a corpus recording the diff variant without includeDiffs' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeReadIncludeDiffs = $false
}

Invoke-CohortEntryCase -Name 'a corpus recording the diff variant without includeLineContent' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeReadIncludeLineContent = $false
}

# The identity keys of the change reads, each on its own, for the same reason the
# thread read's are checked one at a time.
Invoke-CohortEntryCase -Name 'a corpus recording the change reads under another project' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeReadProjectOverride = 'OtherProject'
}

Invoke-CohortEntryCase -Name 'a corpus recording the change reads under the repository GUID' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeReadRepositoryOverride = $state.RepositoryId
}

Invoke-CohortEntryCase -Name 'a corpus recording the change reads for another pull request' -ExpectedCode 'CE307' -Mutate {
    param($state) $state.ChangeReadPullRequestOverride = ([int]$state.PullRequestId + 1)
}

# The change-set cap policy, on the same footing as the thread one. Above the
# operator's ceiling is CE402 and the operator can fix it by editing JSON; at the
# reviewer's page, or with a stated continuation, nobody can say what the change
# set is and CE409 says so.
Invoke-CohortEntryCase -Name 'a change set carrying more paths than the request caps' -ExpectedCode 'CE402' -Mutate {
    param($state)
    $state.MaxChangedFiles = 1
    $state.ChangesBody.changes = @(
        [ordered]@{ changeId = 1; changeType = 'Edit'; item = [ordered]@{ path = '/src/a.ps1' } },
        [ordered]@{ changeId = 2; changeType = 'Edit'; item = [ordered]@{ path = '/src/b.ps1' } })
}

Invoke-CohortEntryCase -Name 'a change set that exactly fills the reviewer page' -ExpectedCode 'CE409' -Mutate {
    param($state)
    $state.MaxChangedFiles = (Get-ReviewerChangeListTop)
    # Raised so the page-fill refusal is what this case observes. At the default
    # cap a thousand-entry response trips the byte ceiling first, and the case
    # would pass for a reason that has nothing to do with the page.
    $state.MaxFileBytes = 1048576
    $state.ChangesBody.changes = @(1..(Get-ReviewerChangeListTop) | ForEach-Object {
            [ordered]@{ changeId = $_; changeType = 'Edit'; item = [ordered]@{ path = "/src/f$_.ps1" } }
        })
}

Invoke-CohortEntryCase -Name 'a change set stating that another page follows it' -ExpectedCode 'CE409' -Mutate {
    param($state) $state.ChangesBody['continuationToken'] = '1001'
}

Invoke-CohortEntryCase -Name 'a change set stating it has more changes' -ExpectedCode 'CE409' -Mutate {
    param($state) $state.ChangesBody['hasMoreChanges'] = $true
}

Invoke-CohortEntryCase -Name 'a change set naming the skip a next page would start at' -ExpectedCode 'CE409' -Mutate {
    param($state) $state.ChangesBody['nextSkip'] = 3
}

Invoke-CohortEntryCase -Name 'a change set naming the size a next page would have' -ExpectedCode 'CE409' -Mutate {
    param($state) $state.ChangesBody['nextTop'] = 1000
}

Invoke-CohortEntryCase -Name 'a change set whose page position is not a number' -ExpectedCode 'CE210' -Mutate {
    param($state) $state.ChangesBody['nextSkip'] = 'more'
}

# The other half of the same rule, and the half that matters most: the wrapper
# writes these fields on EVERY response, so a check that refuses on their
# presence refuses every well-formed capture. The transport's own binding
# requires nextSkip and nextTop to be zero exactly when there is no next page,
# and that is the reading used here.
Invoke-CohortEntryCase -Name 'a change set whose page position is the zero that means no next page' -ExpectedCode '' -Mutate {
    param($state)
    $state.ChangesBody['nextSkip'] = 0
    $state.ChangesBody['nextTop'] = 0
}

Invoke-CohortEntryCase -Name 'a change set stating it has no more changes' -ExpectedCode '' -Mutate {
    param($state) $state.ChangesBody['hasMoreChanges'] = $false
}

Invoke-CohortEntryCase -Name 'a change set carrying an empty continuation token' -ExpectedCode '' -Mutate {
    param($state) $state.ChangesBody['continuationToken'] = ''
}

Invoke-CohortEntryCase -Name 'a file served under a URI nobody requested' -ExpectedCode 'CE304' -Mutate {
    param($state) $state.RuleResourceUri = '/docs/rules/OTHER.md'
}

# The synthetic 'ado://<org>/<project>/<repoId><path>' form is the offline
# corpus-seal RECORD's provenance URI, not the URI the wrapper answers under.
# Serving it here is the exact confusion that refused every live read once.
Invoke-CohortEntryCase -Name 'a file served under the corpus-seal provenance URI form' -ExpectedCode 'CE304' -Mutate {
    param($state) $state.RuleResourceUri = "ado://$($state.Organization)/$($state.Project)/$($state.RepositoryId)/docs/rules/RULES.md"
}

Invoke-CohortEntryCase -Name 'a rule section that drifted from its pin' -ExpectedCode 'CE310' -Mutate {
    param($state) $state.RuleServedText = $state.RuleText + "an unpinned extra line`n"
}

Invoke-CohortEntryCase -Name 'a v3 rule binding whose repository response is recorded under another request key' `
    -ExpectedCode 'CE307' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.RuleReadRepositoryOverride = $state.RuleRepositoryId
    $state.RuleRepositoryId = $state.RepositoryId
}

Invoke-CohortEntryCase -Name 'a v3 rule section missing its repository binding' -ExpectedCode 'CE104' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.MutateRequest = {
        param($request) $request.ruleBundle.sections[0].Remove('repositoryId')
    }
}

Invoke-CohortEntryCase -Name 'a v3 rule section with a non-GUID repository binding' -ExpectedCode 'CE106' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.MutateRequest = {
        param($request) $request.ruleBundle.sections[0].repositoryId = 'engineering-guidance'
    }
}

Invoke-CohortEntryCase -Name 'a v3 rule section with a whitespace-only ATX heading' -ExpectedCode 'CE106' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.MutateRequest = {
        param($request) $request.ruleBundle.sections[0].section = '##   '
    }
}

Invoke-CohortEntryCase -Name 'a v3 rule section crossing organizations' -ExpectedCode 'CE114' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.MutateRequest = {
        param($request) $request.ruleBundle.sections[0].organization = 'another-account'
    }
}

Invoke-CohortEntryCase -Name 'a v3 rule section crossing projects' -ExpectedCode 'CE114' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.MutateRequest = {
        param($request) $request.ruleBundle.sections[0].project = 'another-project'
    }
}

Invoke-CohortEntryCase -Name 'a duplicate v3 rule-section binding' -ExpectedCode 'CE110' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.MutateRequest = {
        param($request)
        $section = $request.ruleBundle.sections[0]
        $request.ruleBundle.sections = @($section, $section)
    }
}

Invoke-CohortEntryCase -Name 'an ambiguous v3 ATX rule heading' -ExpectedCode 'CE310' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.RuleServedText = (
        $state.RuleText + "`r`n" + $state.RuleSection + "`r`n`r`n" +
        "A second section with the same exact heading.`r`n")
}

Invoke-CohortEntryCase -Name 'a tampered Unicode v3 rule section' -ExpectedCode 'CE310' -Mutate {
    param($state)
    Set-CohortEntryV3RuleState -State $state
    $state.RuleServedText = $state.RuleText.Replace(([string][char]0x00E9), 'e')
}

Invoke-CohortEntryCase -Name 'a configuration validating another target branch' -ExpectedCode 'CE211' -Mutate {
    param($state) $state.ConfigTargetRefName = 'refs/heads/release/8.0'
}

# The reviewer reads config.review.targetRefName and requires a full refs/heads
# ref. A cohort entry that accepted a short branch name, or the invented spelling
# 'targetBranch', would validate against a configuration the reviewer itself
# refuses to start on - which is the exact alias defect this builder exists to
# stop an operator re-making by hand.
Invoke-CohortEntryCase -Name 'a configuration spelling its target targetBranch' -ExpectedCode 'CE211' -Mutate {
    param($state) $state.ConfigTargetKeyName = 'targetBranch'
}

Invoke-CohortEntryCase -Name 'a configuration carrying a short target branch name' -ExpectedCode 'CE211' -Mutate {
    param($state) $state.ConfigTargetRefName = 'main'
}

Invoke-CohortEntryCase -Name 'a pull request that is still a draft' -ExpectedCode 'CE207' -Mutate {
    param($state) $state.PullRequestBody.isDraft = $true
}

Invoke-CohortEntryCase -Name 'a pull request that is no longer active' -ExpectedCode 'CE208' -Mutate {
    param($state) $state.PullRequestBody.status = 'abandoned'
}

# The live wrapper answers 'Active' with a capital A. The reviewer's own
# eligibility rule has always compared that case-insensitively, so a cohort
# entry that refused it would refuse a pull request the reviewer would run.
Invoke-CohortEntryCase -Name 'a pull request the provider spells Active' -ExpectedCode '' -Mutate {
    param($state) $state.PullRequestBody.status = 'Active'
}

Invoke-CohortEntryCase -Name 'a pull request retargeted away from the declared ref' -ExpectedCode 'CE206' -Mutate {
    param($state) $state.PullRequestBody.targetRefName = 'refs/heads/release'
}

# A branch that has moved past the merge this pull request was last built
# against is the NORMAL state of an active repository, and refusing it would
# refuse every real entry. What is refused is a branch read that does not
# resolve: a wrong name, or something that is not one 40-hex commit.
Invoke-CohortEntryCase -Name 'a target branch that moved past the pull request' -ExpectedCode '' -Mutate {
    param($state) $state.BranchBody.objectId = '9' * 40
}

Invoke-CohortEntryCase -Name 'a branch read that answered for another branch' -ExpectedCode 'CE205' -Mutate {
    param($state) $state.BranchBody.name = 'release'
}

Invoke-CohortEntryCase -Name 'a branch read whose commit is not 40 hex' -ExpectedCode 'CE205' -Mutate {
    param($state) $state.BranchBody.objectId = 'not-a-commit'
}

Invoke-CohortEntryCase -Name 'a pull request whose last merged target is not 40 hex' -ExpectedCode 'CE210' -Mutate {
    param($state) $state.PullRequestBody.lastMergeTargetCommit.commitId = 'deadbeef'
}

Invoke-CohortEntryCase -Name 'a change set naming one path twice' -ExpectedCode 'CE401' -Mutate {
    param($state)
    $state.ChangesBody.changes = @(
        [ordered]@{ changeId = 1; changeType = 'Edit'; item = [ordered]@{ path = '/src/a.ps1' } },
        [ordered]@{ changeId = 2; changeType = 'Delete'; item = [ordered]@{ path = '/src/a.ps1' } }
    )
}

Invoke-CohortEntryCase -Name 'a changed path that escapes the repository' -ExpectedCode 'CE111' -Mutate {
    param($state)
    $state.ChangesBody.changes = @([ordered]@{ changeId = 1; changeType = 'Edit'; item = [ordered]@{ path = '/../outside.ps1' } })
}

# Through the WHOLE builder, not through the measurement function: the fixture
# reaches 66% because one of its three changed paths is a delete, so a floor of
# 90 has to refuse. This is the case that would have caught the floor being
# wired to a set divided by itself, which no direct call on the measurement
# function can catch.
Invoke-CohortEntryCase -Name 'a coverage floor above what the subject carries' -ExpectedCode 'CE403' -Mutate {
    param($state) $state.MinCoveragePercent = 90
}

# The same subject with no delete in it reaches 100 and passes the same floor,
# so the refusal above is about the subject rather than about the floor being
# unreachable in general.
Invoke-CohortEntryCase -Name 'a coverage floor a fully-covered subject reaches' -ExpectedCode '' -Mutate {
    param($state)
    $state.MinCoveragePercent = 100
    $state.ChangesBody.changes = @($state.ChangesBody.changes[0], $state.ChangesBody.changes[1])
    $state.DiffChangesBody.changes = @($state.DiffChangesBody.changes[0], $state.DiffChangesBody.changes[1])
}

# -------------------------------------------------------------------------
Write-Host 'census ordering is checked as a value, not trusted' -ForegroundColor Cyan
$pagedCensus = [object[]]@(
    [pscustomobject]@{ Ordinal = 1; Path = 'src/b.ps1'; ChangeType = 'add'; HasRightHand = $true },
    [pscustomobject]@{ Ordinal = 2; Path = 'src/a.ps1'; ChangeType = 'edit'; HasRightHand = $true }
)
Assert-CohortEntry -Name 'a census in provider paging order refuses CE400' `
    -Condition ((Get-CohortEntryRefusalCode -Action { Assert-ReviewerCohortEntryCensusOrder -Census $pagedCensus }) -ceq 'CE400')
$gapCensus = [object[]]@(
    [pscustomobject]@{ Ordinal = 1; Path = 'src/a.ps1'; ChangeType = 'edit'; HasRightHand = $true },
    [pscustomobject]@{ Ordinal = 3; Path = 'src/b.ps1'; ChangeType = 'add'; HasRightHand = $true }
)
Assert-CohortEntry -Name 'a census with an ordinal gap refuses CE400' `
    -Condition ((Get-CohortEntryRefusalCode -Action { Assert-ReviewerCohortEntryCensusOrder -Census $gapCensus }) -ceq 'CE400')
$coverageCensus = [object[]]@(
    [pscustomobject]@{ Ordinal = 1; Path = 'src/a.ps1'; ChangeType = 'edit'; HasRightHand = $true },
    [pscustomobject]@{ Ordinal = 2; Path = 'src/b.ps1'; ChangeType = 'delete'; HasRightHand = $false }
)
Assert-CohortEntry -Name 'coverage under the declared floor refuses CE403' `
    -Condition ((Get-CohortEntryRefusalCode -Action {
            Measure-ReviewerCohortEntryCoverage -Census $coverageCensus -CoveredCount 1 -MinimumPercent 100
        }) -ceq 'CE403')
Assert-CohortEntry -Name 'coverage is the covered share of the WHOLE census' `
    -Condition ((Measure-ReviewerCohortEntryCoverage -Census $coverageCensus -CoveredCount 1 -MinimumPercent 50).Percent -eq 50)
Assert-CohortEntry -Name 'a right-hand path without its payload refuses CE403' `
    -Condition ((Get-CohortEntryRefusalCode -Action {
            Measure-ReviewerCohortEntryCoverage -Census $coverageCensus -CoveredCount 0 -MinimumPercent 1
        }) -ceq 'CE403')
Assert-CohortEntry -Name 'an overlapping span refuses CE404' `
    -Condition ((Get-CohortEntryRefusalCode -Action {
            Get-ReviewerCohortEntrySpanEvidence -Path 'src/a.ps1' -LineCount 20 -Spans @(
                [pscustomobject]@{ start = 1; count = 5 }, [pscustomobject]@{ start = 3; count = 2 })
        }) -ceq 'CE404')

# -------------------------------------------------------------------------
Write-Host 'the plan cannot reach outside the read ceiling' -ForegroundColor Cyan
$writeRead = New-ReviewerCohortEntryRead -Id 'write' -Tool 'repo_pull_request_write' -Role 'identity' `
    -Arguments ([ordered]@{ action = 'create_comment' }) -Envelope 'mcpTextContent' -PayloadFile 'payloads/x.json'
Assert-CohortEntry -Name 'a write tool in the plan refuses CE308' `
    -Condition ((Get-CohortEntryRefusalCode -Action { Assert-ReviewerCohortEntryPlanIsClosed -Plan @($writeRead) }) -ceq 'CE308')
$duplicate = @($plainPlan[0], $plainPlan[0])
Assert-CohortEntry -Name 'one read key planned twice refuses CE309' `
    -Condition ((Get-CohortEntryRefusalCode -Action { Assert-ReviewerCohortEntryPlanIsClosed -Plan $duplicate }) -ceq 'CE309')

# A plan is a closed set in BOTH directions. A read that was planned and never
# performed leaves the reviewer a corpus with a hole; a read that was performed
# and never planned puts bytes nobody authorized into a private package.
$capturedShape = { param($ids) [object[]]@($ids | ForEach-Object { [pscustomobject]@{ Read = [pscustomobject]@{ Id = $_ } } }) }
$planShape = { param($ids) [object[]]@($ids | ForEach-Object { [pscustomobject]@{ Id = $_ } }) }
$planAB = @(& $planShape @('a', 'b'))
$planA = @(& $planShape @('a'))
$capturedA = @(& $capturedShape @('a'))
$capturedAB = @(& $capturedShape @('a', 'b'))
Assert-CohortEntry -Name 'a planned read nobody performed refuses CE300' `
    -Condition ((Get-CohortEntryRefusalCode -Action {
            Assert-ReviewerCohortEntryReadsComplete -Plan $planAB -Captured $capturedA
        }) -ceq 'CE300')
Assert-CohortEntry -Name 'a performed read nobody planned refuses CE301' `
    -Condition ((Get-CohortEntryRefusalCode -Action {
            Assert-ReviewerCohortEntryReadsComplete -Plan $planA -Captured $capturedAB
        }) -ceq 'CE301')

# -------------------------------------------------------------------------
Write-Host 'the entry feeds the typed cohort runner without translation' -ForegroundColor Cyan
$sandbox = New-CohortEntrySandbox -Name 'typed'
try {
    $fixture = New-CohortEntryFixture -Sandbox $sandbox
    $result = New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath -PreparationOnly
    $entry = [IO.File]::ReadAllText((Join-Path $result.Root 'entry/cohort-entry.json')) | ConvertFrom-Json -Depth 32

    # The C# reader's required field set, taken from CohortEntry.Read. The entry
    # is asserted to satisfy it AS PUBLISHED, with nothing in between rewriting
    # it - which is the whole claim this deliverable makes.
    foreach ($name in @('ordinal', 'entryId', 'request', 'output', 'subject', 'digests', 'ruleBundle', 'planEstimate')) {
        Assert-CohortEntry -Name "the entry carries '$name'" -Condition ($null -ne $entry.PSObject.Properties[$name])
    }
    foreach ($name in @('organization', 'project', 'repository', 'pullRequestId', 'iterationId',
            'sourceCommit', 'commonCommit', 'targetCommit', 'targetRefName')) {
        Assert-CohortEntry -Name "the entry subject carries '$name'" -Condition ($null -ne $entry.subject.PSObject.Properties[$name])
    }
    Assert-CohortEntry -Name 'the entry request path is rooted' -Condition ([IO.Path]::IsPathRooted([string]$entry.request.path))
    Assert-CohortEntry -Name 'the entry output root is rooted' -Condition ([IO.Path]::IsPathRooted([string]$entry.output.root))
    Assert-CohortEntry -Name 'the entry model-start bound path is rooted' `
        -Condition ([IO.Path]::IsPathRooted([string]$entry.planEstimate.modelStartBound.path))
    Assert-CohortEntry -Name 'the entry request path points at the published request' `
        -Condition (Test-Path -LiteralPath ([string]$entry.request.path) -PathType Leaf)
    Assert-CohortEntry -Name 'the entry request digest matches the published request' `
        -Condition ((Get-FileHash -LiteralPath ([string]$entry.request.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$entry.request.sha256)
    Assert-CohortEntry -Name 'the entry model-start bound digest matches the published artifact' `
        -Condition ((Get-FileHash -LiteralPath ([string]$entry.planEstimate.modelStartBound.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$entry.planEstimate.modelStartBound.sha256)
}
finally { Remove-CohortEntrySandbox -Path $sandbox }

# -------------------------------------------------------------------------
# v2: the optional execution plan, and the complete coordinator request it
# makes the builder emit FROM CREATION.
# -------------------------------------------------------------------------
Write-Host 'v2 execution plan: the complete request, emitted before it is hashed' -ForegroundColor Cyan

# The registry accessor is the single place a model name enters the builder, and
# it reads a list the harness returns with a unary comma. Wrapping that call in
# @() and casting to [string[]] silently collapses twenty models into one joined
# 295-character string, and every membership check then refuses every real
# model. Assert the shape here rather than discovering it as a mystery CE704.
$v2Registry = Get-ReviewerCohortEntryModelRegistry
Assert-CohortEntry -Name 'the model registry returns discrete model identifiers' `
    -Condition (@($v2Registry.Supported).Count -ge 4 -and
        @(@($v2Registry.Supported) | Where-Object { [string]$_ -match '\s' }).Count -eq 0)
Assert-CohortEntry -Name 'the generalist pair is two discrete registry members' `
    -Condition (@($v2Registry.GeneralistPair).Count -eq 2 -and
        @(@($v2Registry.GeneralistPair) | Where-Object { @($v2Registry.Supported) -ccontains [string]$_ }).Count -eq 2)

$v2SchemaPath = Join-Path $repoRoot 'src/Agents/reviewer/schemas/reviewer.cohort-entry-evidence-request.v2.json'
Assert-CohortEntry -Name 'the v2 request schema is present' -Condition (Test-Path -LiteralPath $v2SchemaPath -PathType Leaf)
$v2SchemaText = [IO.File]::ReadAllText($v2SchemaPath)
$v2Schema = $v2SchemaText | ConvertFrom-Json -Depth 64
$v2Names = [string[]]@(Get-CohortEntrySchemaPropertyName -Node $v2Schema)
Assert-CohortEntry -Name 'the v2 schema declares no oracle field' `
    -Condition (@($v2Names | Where-Object { $_ -imatch 'expected|oracle|groundTruth|answerKey|verdict|severity|finding' }).Count -eq 0)
Assert-CohortEntry -Name 'the v2 schema declares the execution plan' -Condition ($v2Names -ccontains 'executionPlan')
Assert-CohortEntry -Name 'the v2 schema keeps the execution plan optional' `
    -Condition (@($v2Schema.required) -cnotcontains 'executionPlan')
# The strongest statement this contract makes is that a write-enabled plan is
# not merely refused - it cannot be SPELLED. That is what 'const' does, so the
# test checks the const and not a prose promise about it.
$v2Delivery = $v2Schema.properties.executionPlan.properties.delivery.properties
foreach ($capability in @('commentsEnabled', 'votesEnabled', 'gatesEnabled')) {
    Assert-CohortEntry -Name "the v2 schema fixes delivery $capability to false" `
        -Condition ($v2Delivery.$capability.PSObject.Properties['const'] -and ([bool]$v2Delivery.$capability.const -eq $false))
}
Assert-CohortEntry -Name 'the v2 schema fixes the provider write budget to zero' `
    -Condition ([int]$v2Delivery.providerWriteBudget.const -eq 0)
Assert-CohortEntry -Name 'the v2 schema fixes the delivery authorization to PreviewOnly' `
    -Condition ([string]$v2Delivery.authorizationKind.const -ceq 'PreviewOnly')
Assert-CohortEntry -Name 'the v2 schema declares exactly two slots' `
    -Condition (([int]$v2Schema.properties.executionPlan.properties.slots.minItems -eq 2) -and
        ([int]$v2Schema.properties.executionPlan.properties.slots.maxItems -eq 2))
# Named by a leaf component, never by a path: that is what makes an output
# directory unable to point anywhere but under the preparation root.
foreach ($section in @('reconciliation', 'delivery')) {
    $ref = [string]$v2Schema.properties.executionPlan.properties.$section.properties.outputDirName.'$ref'
    Assert-CohortEntry -Name "the v2 schema names the $section output by a path component" `
        -Condition ($ref -ceq '#/definitions/pathComponent')
}

# -- v1 is unchanged, and cannot grow slots ---------------------------------
$v1Sandbox = New-CohortEntrySandbox -Name 'v1-noslot'
try {
    $v1Fixture = New-CohortEntryFixture -Sandbox $v1Sandbox
    $v1Result = New-ReviewerCohortEntryEvidence -RequestPath $v1Fixture.RequestPath -PreparationOnly
    $v1Request = [IO.File]::ReadAllText((Join-Path $v1Result.Root 'entry/coordinator-request.json')) | ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name 'a v1 request still emits no slots section' `
        -Condition (-not $v1Request.PSObject.Properties['slots'])
    Assert-CohortEntry -Name 'a v1 entry reports no declared slot' -Condition ($v1Result.DeclaredSlots -eq 0)
    Assert-CohortEntry -Name 'a v1 entry keeps the v2 model-start bound contract' `
        -Condition ($v1Result.ModelStartBoundKind -ceq 'devpilot.shadow-cohort.model-start-bound.v2')
}
finally { Remove-CohortEntrySandbox -Path $v1Sandbox }

# -- v2 without a plan is v1 -------------------------------------------------
$v2BareSandbox = New-CohortEntrySandbox -Name 'v2-bare'
try {
    $v2BareFixture = New-CohortEntryFixture -Sandbox $v2BareSandbox -Mutate {
        param($s)
        $s.SchemaVersion = 2
        # v2 has no rule-source binding. Even if fixture state knows another
        # repository, neither the request nor its replay read may reinterpret it.
        $s.RuleRepositoryId = '99999999-8888-7777-6666-555555555555'
    }
    $v2BareParsed = Read-ReviewerCohortEntryRequest -Path $v2BareFixture.RequestPath
    $v2BareResult = New-ReviewerCohortEntryEvidence -RequestPath $v2BareFixture.RequestPath -PreparationOnly
    $v2BareRequest = [IO.File]::ReadAllText((Join-Path $v2BareResult.Root 'entry/coordinator-request.json')) | ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name 'a v2 request without a plan emits no slots section' `
        -Condition (-not $v2BareRequest.PSObject.Properties['slots'])
    Assert-CohortEntry -Name 'a v2 request without a plan reports schema version 2' -Condition ($v2BareResult.SchemaVersion -eq 2)
    Assert-CohortEntry -Name 'a v2 rule read keeps its historical subject-repository binding' `
        -Condition (
            [string]@($v2BareParsed.RuleSections)[0].RepositoryId -ceq [string]$v2BareParsed.RepositoryId -and
            [string]@($v2BareParsed.RuleSections)[0].Section -ceq '')
}
finally { Remove-CohortEntrySandbox -Path $v2BareSandbox }

# -- v3 binds a cross-repository section while sealing the whole file -----------
$v3Sandbox = New-CohortEntrySandbox -Name 'v3-cross-repo'
try {
    $v3Fixture = New-CohortEntryFixture -Sandbox $v3Sandbox -Mutate {
        param($s)
        Set-CohortEntryV3RuleState -State $s
        $s.MutateRequest = {
            param($request, $state)
            $heading = '## Unrelated rule'
            $cut = Get-ReviewerMarkdownSection -Text ([string]$state.RuleText) -Heading $heading
            $bytes = $script:Utf8.GetBytes([string]$cut.Text)
            $second = [ordered]@{
                organization = [string]$state.RuleOrganization
                project = [string]$state.RuleProject
                repositoryId = [string]$state.RuleRepositoryId
                path = '/docs/rules/review.md'
                commit = [string]$state.RuleCommit
                section = $heading
                sha256 = (Get-CohortEntryBytesSha256 -Bytes $bytes)
                byteLength = $bytes.Length
            }
            $request.ruleBundle.sections = @($request.ruleBundle.sections[0], $second)
        }
    }
    $v3Parsed = Read-ReviewerCohortEntryRequest -Path $v3Fixture.RequestPath
    $v3Result = New-ReviewerCohortEntryEvidence -RequestPath $v3Fixture.RequestPath -PreparationOnly
    $v3Recipe = [IO.File]::ReadAllText((Join-Path $v3Result.Root 'entry/corpus-seal-recipe.json')) |
        ConvertFrom-Json -Depth 64
    $v3RequestBody = [IO.File]::ReadAllText($v3Fixture.RequestPath) | ConvertFrom-Json -Depth 64
    $v3RuleRequest = @($v3RequestBody.ruleBundle.sections)[0]
    $v3RuleResource = @($v3Recipe.resources | Where-Object {
            [string]$_.tool -ceq 'repo_file' -and
            [string]$_.arguments.path -ceq '/docs/rules/review.md' -and
            [string]$_.arguments.version -ceq [string]$v3Fixture.State.RuleCommit
        })[0]
    $v3RuleReference = @($v3Recipe.evidence.rules)[0]
    $v3Witness = [IO.File]::ReadAllText((Join-Path $v3Result.Root 'entry/identity-witness.json')) |
        ConvertFrom-Json -Depth 64
    $v3RuleCorpusPath = Join-Path (Join-Path $v3Result.Root 'corpus') `
        (([string]$v3RuleReference.corpusPath) -replace '/', [IO.Path]::DirectorySeparatorChar)
    $v3WholeBytes = [IO.File]::ReadAllBytes($v3RuleCorpusPath)
    $v3ExpectedWholeBytes = $script:Utf8.GetBytes([string]$v3Fixture.State.RuleText)
    $v3Cut = Get-ReviewerMarkdownSection -Text ([string]$v3Fixture.State.RuleText) `
        -Heading ([string]$v3Fixture.State.RuleSection)
    $v3CutBytes = $script:Utf8.GetBytes([string]$v3Cut.Text)
    $v3ExpectedArguments = [ordered]@{
        action = 'get_content'
        project = $v3Fixture.State.Project
        repositoryId = $v3Fixture.State.RuleRepositoryId
        path = '/docs/rules/review.md'
        versionType = 'Commit'
        version = $v3Fixture.State.RuleCommit
    }
    $v3SubjectArguments = [ordered]@{}
    foreach ($pair in $v3ExpectedArguments.GetEnumerator()) { $v3SubjectArguments[$pair.Key] = $pair.Value }
    $v3SubjectArguments.repositoryId = $v3Fixture.State.RepositoryId
    $v3ExpectedKey = (Get-AgentReplayRequestKey -Name 'repo_file' -Arguments $v3ExpectedArguments).Key
    $v3SubjectKey = (Get-AgentReplayRequestKey -Name 'repo_file' -Arguments $v3SubjectArguments).Key
    $v3RecipeKeys = [string[]]@($v3Recipe.resources | ForEach-Object {
            (Get-AgentReplayRequestKey -Name ([string]$_.tool) -Arguments $_.arguments).Key
        })

    Assert-CohortEntry -Name 'a v3 cross-repository rule fixture builds successfully' `
        -Condition ($v3Result.SchemaVersion -eq 3)
    Assert-CohortEntry -Name 'a v3 rule section retains its explicit repository and heading' `
        -Condition (
            @($v3Parsed.RuleSections).Count -eq 2 -and
            [string]@($v3Parsed.RuleSections)[0].RepositoryId -ceq [string]$v3Fixture.State.RuleRepositoryId -and
            [string]@($v3Parsed.RuleSections)[0].RepositoryId -cne [string]$v3Parsed.RepositoryId -and
            [string]@($v3Parsed.RuleSections)[0].Section -ceq [string]$v3Fixture.State.RuleSection)
    Assert-CohortEntry -Name 'two v3 sections in one file share one whole-file provider read' `
        -Condition (
            @($v3Recipe.resources | Where-Object {
                    [string]$_.tool -ceq 'repo_file' -and
                    [string]$_.arguments.path -ceq '/docs/rules/review.md' -and
                    [string]$_.arguments.version -ceq [string]$v3Fixture.State.RuleCommit
                }).Count -eq 1 -and
            @($v3Recipe.evidence.rules).Count -eq 1)
    Assert-CohortEntry -Name 'the v3 rule read is issued against the authoritative repository' `
        -Condition ([string]$v3RuleResource.arguments.repositoryId -ceq [string]$v3Fixture.State.RuleRepositoryId)
    Assert-CohortEntry -Name 'the v3 corpus answers the authoritative rule request key, not the subject key' `
        -Condition ($v3RecipeKeys -ccontains $v3ExpectedKey -and $v3RecipeKeys -cnotcontains $v3SubjectKey)
    Assert-CohortEntry -Name 'the v3 corpus preserves the exact whole-file UTF-8 and CRLF bytes' `
        -Condition (
            [Convert]::ToHexString($v3WholeBytes) -ceq [Convert]::ToHexString($v3ExpectedWholeBytes) -and
            [string]$v3Fixture.State.RuleText -cmatch "`r`n" -and
            $v3WholeBytes.Length -gt $v3CutBytes.Length)
    Assert-CohortEntry -Name 'the v3 section pin is the shared extractor cut with UTF-8 byte accounting' `
        -Condition (
            [string]$v3RuleRequest.sha256 -ceq (Get-CohortEntryBytesSha256 -Bytes $v3CutBytes) -and
            [int]$v3RuleRequest.byteLength -eq $v3CutBytes.Length -and
            $v3CutBytes.Length -gt ([string]$v3Cut.Text).Length)
    Assert-CohortEntry -Name 'the v3 sealed rule reference binds the whole provider file, not the cut' `
        -Condition (
            [string]$v3RuleReference.sha256 -ceq (Get-CohortEntryBytesSha256 -Bytes $v3ExpectedWholeBytes) -and
            [int]$v3RuleReference.byteLength -eq $v3ExpectedWholeBytes.Length)
    Assert-CohortEntry -Name 'the v3 identity witness records each rule repository and heading' `
        -Condition (
            @($v3Witness.ruleBundle.sections).Count -eq 2 -and
            @($v3Witness.ruleBundle.sections | Where-Object {
                    [string]$_.repositoryId -ceq [string]$v3Fixture.State.RuleRepositoryId -and
                    [string]$_.section
                }).Count -eq 2)
}
finally { Remove-CohortEntrySandbox -Path $v3Sandbox }

# -- v2 with a plan: the whole declaration, in the hashed region -------------
$v2Sandbox = New-CohortEntrySandbox -Name 'v2-plan'
try {
    $v2Fixture = New-CohortEntryFixture -Sandbox $v2Sandbox -Mutate {
        param($s) $s.SchemaVersion = 2; $s.WithExecutionPlan = $true
    }
    $v2Result = New-ReviewerCohortEntryEvidence -RequestPath $v2Fixture.RequestPath -PreparationOnly
    $v2RequestPath = Join-Path $v2Result.Root 'entry/coordinator-request.json'
    $v2RequestText = [IO.File]::ReadAllText($v2RequestPath)
    $v2Request = $v2RequestText | ConvertFrom-Json -Depth 32

    Assert-CohortEntry -Name 'a v2 plan emits a slots section' -Condition ([bool]$v2Request.PSObject.Properties['slots'])
    Assert-CohortEntry -Name 'the emitted request enables shadow slots' -Condition ([bool]$v2Request.slots.shadowSlotsEnabled)
    $v2Declared = @($v2Request.slots.declared)
    Assert-CohortEntry -Name 'the emitted request declares exactly two slots' -Condition ($v2Declared.Count -eq 2)
    Assert-CohortEntry -Name 'the emitted slots are named slot1 then slot2, in order' `
        -Condition (([string]$v2Declared[0].name -ceq 'slot1') -and ([string]$v2Declared[1].name -ceq 'slot2'))
    Assert-CohortEntry -Name 'both emitted slots launch the identical reviewer script' `
        -Condition ([string]$v2Declared[0].reviewerScriptPath -ceq [string]$v2Declared[1].reviewerScriptPath)
    Assert-CohortEntry -Name 'the emitted slots hold distinct state directories' `
        -Condition ([string]$v2Declared[0].stateDirName -cne [string]$v2Declared[1].stateDirName)
    Assert-CohortEntry -Name 'the emitted slots hold distinct terminal artifacts' `
        -Condition ([string]$v2Declared[0].terminalName -cne [string]$v2Declared[1].terminalName)
    Assert-CohortEntry -Name 'the emitted request pins the exact toolkit head' `
        -Condition ([string]$v2Request.toolkit.head -ceq $v2Fixture.ToolkitHead)
    Assert-CohortEntry -Name 'the emitted qualification plans exactly the declared slot count' `
        -Condition ([int]$v2Request.qualification.plannedRunCount -eq $v2Declared.Count)

    Assert-CohortEntry -Name 'the emitted request enables reconciliation' -Condition ([bool]$v2Request.slots.reconciliation.reconciliationEnabled)
    Assert-CohortEntry -Name 'the emitted reconciliation requires both runs' `
        -Condition ([int]$v2Request.slots.reconciliation.requiredRunCount -eq 2)
    Assert-CohortEntry -Name 'the emitted delivery is PreviewOnly' `
        -Condition ([string]$v2Request.slots.delivery.authorizationKind -ceq 'PreviewOnly')
    foreach ($capability in @('commentsEnabled', 'votesEnabled', 'gatesEnabled')) {
        Assert-CohortEntry -Name "the emitted delivery leaves $capability false" `
            -Condition ([bool]$v2Request.slots.delivery.$capability -eq $false)
    }
    Assert-CohortEntry -Name 'the emitted delivery budgets no provider write' `
        -Condition ([int]$v2Request.slots.delivery.providerWriteBudget -eq 0)
    $v2Preparation = [IO.Path]::GetFullPath([string]$v2Request.output.root)
    foreach ($directory in @([string]$v2Request.slots.reconciliation.outputDirectory, [string]$v2Request.slots.delivery.outputDirectory)) {
        Assert-CohortEntry -Name "the emitted output '$([IO.Path]::GetFileName($directory))' is under the preparation root" `
            -Condition (Test-ReviewerCohortEntryPathWithin -Candidate $directory -Root $v2Preparation)
    }
    Assert-CohortEntry -Name 'the emitted reconciliation and delivery outputs are distinct' `
        -Condition ([string]$v2Request.slots.reconciliation.outputDirectory -cne [string]$v2Request.slots.delivery.outputDirectory)
    Assert-CohortEntry -Name 'no emitted output escapes into the sealed package' `
        -Condition (-not (Test-ReviewerCohortEntryPathWithin -Candidate $v2Preparation -Root $v2Result.Root))

    # The load-bearing ordering claim. The slots are INSIDE the bytes the entry
    # pins, so there is no "after the hash" for a slot to be added in.
    $v2Entry = [IO.File]::ReadAllText((Join-Path $v2Result.Root 'entry/cohort-entry.json')) | ConvertFrom-Json -Depth 32
    $v2FileSha = (Get-FileHash -LiteralPath $v2RequestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-CohortEntry -Name 'the entry pins the digest of the request that already carries its slots' `
        -Condition (([string]$v2Entry.request.sha256 -ceq $v2FileSha) -and ($v2RequestText -cmatch '"slots"'))
    $augmented = $v2RequestText | ConvertFrom-Json -Depth 32
    $augmented.slots.declared = @(@($augmented.slots.declared) + @($augmented.slots.declared[0]))
    $augmentedBytes = [byte[]]@($script:Utf8.GetBytes((ConvertTo-Json -InputObject $augmented -Depth 32)))
    $augmentedSha = Get-CohortEntryBytesSha256 -Bytes $augmentedBytes
    Assert-CohortEntry -Name 'a slot added after the hash no longer matches the pinned digest' `
        -Condition ($augmentedSha -cne [string]$v2Entry.request.sha256)

    # ---------------------------------------------------------------------
    # The bound. DERIVED by the shipping producer over the request that was
    # actually emitted, never synthesized here. The expected totals are
    # recomputed from the same four attempt factors the fixture runner
    # declares, so this asserts the FORMULA rather than a number: a builder
    # that went back to writing the slot count down would fail every one of
    # these even though two slots is still two slots.
    # ---------------------------------------------------------------------
    $v2Bound = [IO.File]::ReadAllText((Join-Path $v2Result.Root 'entry/model-start-bound.json')) | ConvertFrom-Json -Depth 32
    $factors = $v2Fixture.FixtureBoundFactors
    $expectedLaunches = [Math]::Min([int]$factors.VerifierPolicyRuns, [int]$factors.VerifierCeiling)
    $expectedPerSlot = (2 * [int]$factors.GeneralistAttemptsPerPass) + [int]$factors.SpecialistAttempts +
        ($expectedLaunches * [int]$factors.VerifierAttemptsPerLaunch)
    $expectedStarts = $expectedPerSlot * 2
    $expectedAssignments = $expectedLaunches * 2
    Assert-CohortEntry -Name 'the bound is the kind the cohort runner reads' `
        -Condition ([string]$v2Bound.kind -ceq 'devpilot.shadow-cohort.model-start-bound.v2')
    Assert-CohortEntry -Name 'the bound binds the digest of the request this entry emitted' `
        -Condition ([string]$v2Bound.requestSha256 -ceq [string]$v2Entry.request.sha256)
    Assert-CohortEntry -Name 'the bound binds the toolkit head this entry pins' `
        -Condition ([string]$v2Bound.toolkitHead -ceq $v2Fixture.ToolkitHead)
    Assert-CohortEntry -Name 'the bound binds the reviewer configuration the request sealed' `
        -Condition ([string]$v2Bound.reviewerConfigSha256 -ceq [string]$v2Request.digests.configSha256)
    Assert-CohortEntry -Name 'the bound counts the two slots the request declared' `
        -Condition (([int]$v2Bound.declaredSlotCount -eq 2) -and ([int]$v2Bound.plannedRunCount -eq 2))
    Assert-CohortEntry -Name 'the bound multiplies the runner attempt factors rather than the slot count' `
        -Condition ([int]$v2Bound.maxRealModelStarts -eq $expectedStarts)
    Assert-CohortEntry -Name 'the bound is far above the slot count it was once mistaken for' `
        -Condition ([int]$v2Bound.maxRealModelStarts -gt [int]$v2Bound.declaredSlotCount)
    Assert-CohortEntry -Name 'the bound splits its total across generalist, specialist and verifier' `
        -Condition (([int]$v2Bound.byRole.generalist -eq (2 * [int]$factors.GeneralistAttemptsPerPass * 2)) -and
            ([int]$v2Bound.byRole.specialist -eq ([int]$factors.SpecialistAttempts * 2)) -and
            ([int]$v2Bound.byRole.verifier -eq ($expectedLaunches * [int]$factors.VerifierAttemptsPerLaunch * 2)))
    Assert-CohortEntry -Name 'the bound derives verifier assignments from the launch ceiling' `
        -Condition ([int]$v2Bound.maxVerifierAssignments -eq $expectedAssignments)
    Assert-CohortEntry -Name 'the bound records a per-slot derivation for each declared slot' `
        -Condition ((@($v2Bound.slots).Count -eq 2) -and
            (@($v2Bound.slots | Where-Object { [int]$_.maxRealModelStarts -eq $expectedPerSlot }).Count -eq 2))
    Assert-CohortEntry -Name 'the bound records that verification was authorized' `
        -Condition ([bool]$v2Bound.verificationAuthorized)
    Assert-CohortEntry -Name 'the bound carries no supervision or model assignment the runner would ignore' `
        -Condition ((-not $v2Bound.PSObject.Properties['supervision']) -and
            (-not $v2Bound.PSObject.Properties['assignment']))

    # The estimate a cohort budgets against is TAKEN FROM the derived maxima, so
    # "the estimate is an upper bound" holds by construction. The cohort runner
    # refuses an entry that estimates below its own sealed bound, and that is the
    # refusal a slot-count estimate would have walked into.
    Assert-CohortEntry -Name "the manifest entry's plan estimate is the derived bound" `
        -Condition (([int]$v2Entry.planEstimate.modelStarts -eq [int]$v2Bound.maxRealModelStarts) -and
            ([int]$v2Entry.planEstimate.verifierAssignments -eq [int]$v2Bound.maxVerifierAssignments))
    Assert-CohortEntry -Name "the manifest entry's plan estimate is never below the bound" `
        -Condition (([int]$v2Entry.planEstimate.modelStarts -ge [int]$v2Bound.maxRealModelStarts) -and
            ([int]$v2Entry.planEstimate.verifierAssignments -ge [int]$v2Bound.maxVerifierAssignments))
    Assert-CohortEntry -Name 'the plan estimate is non-zero and finite' `
        -Condition (([int]$v2Entry.planEstimate.modelStarts -gt 0) -and
            ([int]$v2Entry.planEstimate.verifierAssignments -gt 0) -and
            ([int]$v2Entry.planEstimate.modelStarts -lt 65536))
    Assert-CohortEntry -Name 'the builder reports the derived maxima to its operator' `
        -Condition ((([int]$v2Result.MaxRealModelStarts) -eq $expectedStarts) -and
            (([int]$v2Result.MaxVerifierAssignments) -eq $expectedAssignments) -and
            ([string]$v2Result.ModelStartBoundKind -ceq 'devpilot.shadow-cohort.model-start-bound.v2'))
    Assert-CohortEntry -Name 'the wall clock estimate covers both slots, the reconciliation and the delivery' `
        -Condition ([int]$v2Entry.planEstimate.wallClockSeconds -eq ((5400 + 120) * 4))
    Assert-CohortEntry -Name 'the v2 build started no model' -Condition ($v2Result.ModelStarts -eq 0)
    Assert-CohortEntry -Name 'the v2 build wrote nothing to a provider' -Condition ($v2Result.ProviderWrites -eq 0)
    # The builder mints no launch authorization, so the one path a launch
    # authorization can occupy must still be empty after a complete build - and
    # the entry must say so rather than claim a readiness it cannot substantiate.
    $v2Prep = $v2Result.Root.TrimEnd('\', '/') + '.preparation'
    $v2Token = Join-Path (Join-Path $v2Prep 'qualification/runset') 'launch-authorization.token'
    Assert-CohortEntry -Name 'the builder minted no launch authorization' `
        -Condition (-not (Test-Path -LiteralPath $v2Token))
    Assert-CohortEntry -Name 'a preparation-only build does not claim to be cohort-ready' `
        -Condition (-not $v2Result.CohortReady)
    $v2Emitted = [IO.File]::ReadAllText((Join-Path (Join-Path $v2Result.Root 'entry') 'coordinator-request.json')) |
        ConvertFrom-Json -Depth 32
    $v2Stamped = [string[]]@(@($v2Emitted.slots.declared | ForEach-Object { [string]$_.launchAuthorizationTokenPath }) +
        @([string]$v2Emitted.slots.reconciliation.launchAuthorizationTokenPath,
            [string]$v2Emitted.slots.delivery.launchAuthorizationTokenPath))
    Assert-CohortEntry -Name 'the emitted request derives one launch authorization for both slots, the reconciliation and the delivery' `
        -Condition (($v2Stamped.Count -eq 4) -and (@($v2Stamped | Sort-Object -Unique).Count -eq 1))
    Assert-CohortEntry -Name 'the derived launch authorization sits where the run set declaration publishes one' `
        -Condition ([IO.Path]::GetFullPath($v2Stamped[0]) -ceq [IO.Path]::GetFullPath($v2Token))
    Assert-CohortEntry -Name 'the derived launch authorization is outside the sealed package' `
        -Condition (-not ([IO.Path]::GetFullPath($v2Stamped[0]).StartsWith(
                [IO.Path]::GetFullPath($v2Result.Root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)))
    Assert-CohortEntry -Name 'the published v2 package is sealed and read-only' `
        -Condition (Assert-ReviewerCohortEntryPublished -Root $v2Result.Root -SealKeyPath $v2Fixture.SealKeyPath)
}
finally { Remove-CohortEntrySandbox -Path $v2Sandbox }

# -- sabotage: every way an execution plan can be wrong ----------------------
Write-Host 'v2 execution plan: sabotage' -ForegroundColor Cyan
$withPlan = {
    param($MutatePlan)
    return {
        param($s)
        $s.SchemaVersion = 2
        $s.WithExecutionPlan = $true
        if ($MutatePlan) { $s.MutateExecutionPlan = $MutatePlan }
    }.GetNewClosure()
}

Invoke-CohortEntryCase -ExpectedCode '' -Name 'an exact execution plan' -Mutate (& $withPlan $null)
Invoke-CohortEntryCase -ExpectedCode 'CE700' -Name 'an execution plan declared at schema version 1' -Mutate {
    param($s) $s.SchemaVersion = 1; $s.WithExecutionPlan = $true
}
Invoke-CohortEntryCase -ExpectedCode 'CE701' -Name 'a plan that disables shadow slots' `
    -Mutate (& $withPlan { param($p, $s) $p.shadowSlotsEnabled = $false })
Invoke-CohortEntryCase -ExpectedCode 'CE701' -Name 'a plan that disables reconciliation' `
    -Mutate (& $withPlan { param($p, $s) $p.reconciliation.reconciliationEnabled = $false })
Invoke-CohortEntryCase -ExpectedCode 'CE701' -Name 'a plan that disables delivery' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.deliveryEnabled = $false })
Invoke-CohortEntryCase -ExpectedCode 'CE702' -Name 'a plan that declares one slot' `
    -Mutate (& $withPlan { param($p, $s) $p.slots = @($p.slots[0]) })
Invoke-CohortEntryCase -ExpectedCode 'CE702' -Name 'a plan that declares three slots' `
    -Mutate (& $withPlan { param($p, $s) $p.slots = @($p.slots[0], $p.slots[1], $p.slots[1]) })
Invoke-CohortEntryCase -ExpectedCode 'CE702' -Name 'a plan that declares its slots out of order' `
    -Mutate (& $withPlan { param($p, $s) $p.slots = @($p.slots[1], $p.slots[0]) })
Invoke-CohortEntryCase -ExpectedCode 'CE708' -Name 'two slots sharing one state directory' `
    -Mutate (& $withPlan { param($p, $s) $p.slots[1].stateDirName = $p.slots[0].stateDirName })
Invoke-CohortEntryCase -ExpectedCode 'CE708' -Name 'two slots sharing one state directory in another case' `
    -Mutate (& $withPlan { param($p, $s) $p.slots[1].stateDirName = ([string]$p.slots[0].stateDirName).ToUpperInvariant() })
Invoke-CohortEntryCase -ExpectedCode 'CE708' -Name 'a reconciliation output that collides with a slot state directory' `
    -Mutate (& $withPlan { param($p, $s) $p.reconciliation.outputDirName = [string]$p.slots[0].stateDirName })
Invoke-CohortEntryCase -ExpectedCode 'CE713' -Name 'a delivery output that collides with the reconciliation output' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.outputDirName = [string]$p.reconciliation.outputDirName })
Invoke-CohortEntryCase -ExpectedCode 'CE707' -Name 'a delivery authorized to do more than preview' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.authorizationKind = 'Full' })
Invoke-CohortEntryCase -ExpectedCode 'CE707' -Name 'a delivery that enables comments' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.commentsEnabled = $true })
Invoke-CohortEntryCase -ExpectedCode 'CE707' -Name 'a delivery that enables votes' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.votesEnabled = $true })
Invoke-CohortEntryCase -ExpectedCode 'CE707' -Name 'a delivery that enables gates' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.gatesEnabled = $true })
Invoke-CohortEntryCase -ExpectedCode 'CE707' -Name 'a delivery that budgets a provider write' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.providerWriteBudget = 1 })
Invoke-CohortEntryCase -ExpectedCode 'CE703' -Name 'a reviewer script that is not on disk' `
    -Mutate (& $withPlan { param($p, $s) $p.reviewerScript.path = (Join-Path (Split-Path ([string]$p.reviewerScript.path) -Parent) 'absent.ps1') })
Invoke-CohortEntryCase -ExpectedCode 'CE703' -Name 'a reviewer script whose bytes disagree with its pin' `
    -Mutate (& $withPlan { param($p, $s) $p.reviewerScript.sha256 = ('f' * 64) })
Invoke-CohortEntryCase -ExpectedCode 'CE704' -Name 'a model the registry does not carry' `
    -Mutate (& $withPlan { param($p, $s) $p.models.conventionSpecialistModel = 'claude-opus-0.1' })
Invoke-CohortEntryCase -ExpectedCode 'CE705' -Name 'a generalist pair declared in the wrong order' `
    -Mutate (& $withPlan { param($p, $s) $p.models.generalistPair = @($p.models.generalistPair[1], $p.models.generalistPair[0]) })
Invoke-CohortEntryCase -ExpectedCode 'CE705' -Name 'a specialist that is one of the two generalists' `
    -Mutate (& $withPlan { param($p, $s) $p.models.conventionSpecialistModel = [string]$p.models.generalistPair[0] })
Invoke-CohortEntryCase -ExpectedCode 'CE705' -Name 'a generalist pair of one model' `
    -Mutate (& $withPlan { param($p, $s) $p.models.generalistPair = @([string]$p.models.generalistPair[0]) })
Invoke-CohortEntryCase -ExpectedCode 'CE706' -Name 'a specialist the reviewer configuration does not configure' -Mutate {
    param($s)
    $s.SchemaVersion = 2
    $s.WithExecutionPlan = $true
    $s.ConfigSpecialistModel = 'claude-haiku-4.5'
}
Invoke-CohortEntryCase -ExpectedCode 'CE706' -Name 'a plan whose reviewer configuration disables verification' -Mutate {
    param($s)
    $s.SchemaVersion = 2
    $s.WithExecutionPlan = $true
    $s.ConfigVerificationEnabled = $false
}
Invoke-CohortEntryCase -ExpectedCode 'CE706' -Name 'a plan whose reviewer configuration names no models at all' -Mutate {
    param($s)
    $s.SchemaVersion = 2
    $s.WithExecutionPlan = $true
    $s.ConfigDeclaresModels = $false
}
# PowerShell reads the STRING "false" as $true. Without a strict read the
# pairing check below would see verification enabled, seal the entry, and the
# reviewer agent would then refuse the same configuration at startup.
Invoke-CohortEntryCase -ExpectedCode 'CE211' -Name 'a reviewer configuration that spells verification.enabled as a string' -Mutate {
    param($s)
    $s.SchemaVersion = 2
    $s.WithExecutionPlan = $true
    $s.ConfigVerificationEnabledRaw = 'false'
}
Invoke-CohortEntryCase -ExpectedCode 'CE211' -Name 'a reviewer configuration that spells verification.enabled as a number' -Mutate {
    param($s)
    $s.SchemaVersion = 2
    $s.WithExecutionPlan = $true
    $s.ConfigVerificationEnabledRaw = 1
}
# The shipping SlotAuthorization.RequireLeafName refuses ANY component holding
# '..', not just '.' and '..' themselves. A name this reader let through would
# be captured, sealed and published before the coordinator refused to load it.
Invoke-CohortEntryCase -ExpectedCode 'CE106' -Name 'a slot state directory holding a parent-directory hop' `
    -Mutate (& $withPlan { param($p, $s) $p.slots[0].stateDirName = 's1..x' })
Invoke-CohortEntryCase -ExpectedCode 'CE106' -Name 'a slot terminal name holding a parent-directory hop' `
    -Mutate (& $withPlan { param($p, $s) $p.slots[1].terminalName = 't2..x' })
Invoke-CohortEntryCase -ExpectedCode 'CE106' -Name 'a reconciliation output holding a parent-directory hop' `
    -Mutate (& $withPlan { param($p, $s) $p.reconciliation.outputDirName = 'recon..x' })
Invoke-CohortEntryCase -ExpectedCode 'CE106' -Name 'a delivery output holding a parent-directory hop' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.outputDirName = 'deliver..x' })
# A present property whose value is null. Left uncaught this fails on a
# mandatory parameter binding, which has no catalogued code and exits 1 rather
# than the 8 an operator scripts against.
Invoke-CohortEntryCase -ExpectedCode 'CE700' -Name 'a request whose executionPlan is null' -Mutate {
    param($s)
    $s.SchemaVersion = 2
    $s.ExecutionPlanIsNull = $true
}
Invoke-CohortEntryCase -ExpectedCode 'CE709' -Name 'a plan whose slot count is not the planned run count' -Mutate {
    param($s)
    $s.SchemaVersion = 2
    $s.WithExecutionPlan = $true
    $s.PlannedRunCount = 3
}
Invoke-CohortEntryCase -ExpectedCode 'CE710' -Name 'a per-call timeout that outlives the slot supervising it' `
    -Mutate (& $withPlan { param($p, $s) $p.timeouts.perCallTimeoutSeconds = 7200 })
Invoke-CohortEntryCase -ExpectedCode 'CE715' -ClaimingCohortReady -RequireOutputRootWithdrawn `
    -Name 'a slots-carrying build that declared no run set' -Mutate (& $withPlan { param($p, $s) })
Invoke-CohortEntryCase -ExpectedCode 'CE716' -Name 'a slot naming its own launch authorization' `
    -Mutate (& $withPlan {
        param($p, $s)
        # The exact shape every request written before this contract carried, and
        # the exact defect it caused: a path nothing was ever going to publish,
        # accepted at build, detected at the first prelaunch.
        $p.slots[0]['launchAuthorizationTokenPath'] = 'C:\operator\launch\authorization.token'
    })
Invoke-CohortEntryCase -ExpectedCode 'CE716' -Name 'a reconciliation naming its own launch authorization' `
    -Mutate (& $withPlan {
        param($p, $s)
        $p.reconciliation['launchAuthorizationTokenPath'] = 'C:\operator\launch\authorization.token'
    })
Invoke-CohortEntryCase -ExpectedCode 'CE716' -Name 'a delivery naming its own launch authorization' `
    -Mutate (& $withPlan {
        param($p, $s)
        $p.delivery['launchAuthorizationTokenPath'] = 'C:\operator\launch\authorization.token'
    })
Invoke-CohortEntryCase -ExpectedCode 'CE308' -Name 'a model plan carrying a fault-injection argument' `
    -Mutate (& $withPlan {
        param($p, $s)
        $p.slots[0].modelPlan.bindSealedArguments = $true
        $p.slots[0].modelPlan.opaqueArguments = @('-FaultInjectionMode', 'terminal')
    })
Invoke-CohortEntryCase -ExpectedCode 'CE106' -Name 'a model plan that binds sealed arguments and declares none' `
    -Mutate (& $withPlan { param($p, $s) $p.slots[0].modelPlan.bindSealedArguments = $true })
Invoke-CohortEntryCase -ExpectedCode 'CE105' -Name 'an execution plan carrying a field this contract does not declare' `
    -Mutate (& $withPlan { param($p, $s) $p['launchImmediately'] = $true })
Invoke-CohortEntryCase -ExpectedCode 'CE104' -Name 'an execution plan that omits its delivery' `
    -Mutate (& $withPlan { param($p, $s) $p.Remove('delivery') })
Invoke-CohortEntryCase -ExpectedCode 'CE106' -Name 'a delivery capability written as a string rather than a boolean' `
    -Mutate (& $withPlan { param($p, $s) $p.delivery.commentsEnabled = 'false' })

# -------------------------------------------------------------------------
# The bound the builder publishes is not the builder's to invent. It is taken
# from the reviewed producer over the request that was emitted, and a bound that
# does not bind THIS request at THIS head is refused rather than published -
# because the entry that carries it is a budget, and a budget nobody derived is
# the under-declaration the cohort runner exists to stop.
# -------------------------------------------------------------------------
Write-Host 'model-start bound: derivation, injection and sabotage' -ForegroundColor Cyan
$boundSandbox = New-CohortEntrySandbox -Name 'bound'
try {
    $boundFixture = New-CohortEntryFixture -Sandbox $boundSandbox -Mutate {
        param($s) $s.SchemaVersion = 2; $s.WithExecutionPlan = $true
    }
    $boundResult = New-ReviewerCohortEntryEvidence -RequestPath $boundFixture.RequestPath -PreparationOnly
    $boundEntry = [IO.File]::ReadAllText((Join-Path $boundResult.Root 'entry/cohort-entry.json')) | ConvertFrom-Json -Depth 32
    $derivedPath = Join-Path $boundResult.Root 'entry/model-start-bound.json'
    $derivedText = [IO.File]::ReadAllText($derivedPath)
    $emittedRequestPath = Join-Path $boundResult.Root 'entry/coordinator-request.json'
    $emittedRequestSha = [string]$boundEntry.request.sha256

    # The validator, exercised against what a PRODUCER published. A stub producer
    # stands in for the reviewed one so the artifact that comes back can be made
    # to say anything: what is under test is the builder re-reading the file it
    # was handed rather than the arguments it passed.
    $stubToolkits = 0
    $checkDerived = {
        param([scriptblock]$MutateBound, [int]$ProducerExit = 0)
        $stubToolkits++
        $stubRoot = Join-Path $boundSandbox ("stub-toolkit-$stubToolkits")
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $stubRoot 'tools'))
        $parsed = $derivedText | ConvertFrom-Json -Depth 32
        if ($MutateBound) { & $MutateBound $parsed }
        $sourceText = [string]($parsed | ConvertTo-Json -Depth 12)
        $sourceBytes = [byte[]]@($script:Utf8.GetBytes($sourceText))
        [IO.File]::WriteAllBytes((Join-Path $stubRoot 'tools/bound-source.json'), $sourceBytes)
        $stubProducer = @(
            'param([string]$RequestPath, [string]$OutputPath, [switch]$Force)',
            "if ($ProducerExit -ne 0) { [Console]::Error.Write('stub producer refused'); exit $ProducerExit }",
            'Copy-Item -LiteralPath (Join-Path $PSScriptRoot ''bound-source.json'') -Destination $OutputPath -Force',
            'exit 0',
            ''
        ) -join "`n"
        $stubBytes = [byte[]]@($script:Utf8.GetBytes($stubProducer))
        [IO.File]::WriteAllBytes((Join-Path $stubRoot 'tools/New-ShadowModelStartBound.ps1'), $stubBytes)
        $destination = Join-Path $boundSandbox ("published-$stubToolkits.json")
        return (Get-CohortEntryRefusalCode -Action {
                $null = New-ReviewerCohortEntryModelStartBound -ToolkitRoot $stubRoot `
                    -ToolkitHead $boundFixture.ToolkitHead -RequestPath $emittedRequestPath `
                    -RequestSha256 $emittedRequestSha -OutputPath $destination
            })
    }

    Assert-CohortEntry -Name 'a published bound that binds this request and head is accepted' `
        -Condition ((& $checkDerived $null) -ceq '')
    Assert-CohortEntry -Name 'a producer that refuses leaves the entry unbounded and CE714' `
        -Condition ((& $checkDerived $null 3) -ceq 'CE714')
    Assert-CohortEntry -Name 'a published bound wearing the v3 kind the runner never reads is refused as CE714' `
        -Condition ((& $checkDerived { param($b) $b.kind = 'devpilot.shadow-cohort.model-start-bound.v3' }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a published bound with no toolkit head is refused as CE714' `
        -Condition ((& $checkDerived { param($b) $b.PSObject.Properties.Remove('toolkitHead') }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a published bound taken at a different head is refused as CE714' `
        -Condition ((& $checkDerived { param($b) $b.toolkitHead = ('f' * 40) }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a published bound taken over a different request is refused as CE714' `
        -Condition ((& $checkDerived { param($b) $b.requestSha256 = ('0' * 64) }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a published bound with no maximum is refused as CE714' `
        -Condition ((& $checkDerived { param($b) $b.PSObject.Properties.Remove('maxRealModelStarts') }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a published bound whose maximum is not a number is refused as CE714' `
        -Condition ((& $checkDerived { param($b) $b.maxRealModelStarts = 'many' }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a published bound with no verifier assignment maximum is refused as CE714' `
        -Condition ((& $checkDerived { param($b) $b.PSObject.Properties.Remove('maxVerifierAssignments') }) -ceq 'CE714')

    # A supplied bound is an EXPECTATION, not a substitute. The producer runs
    # either way and the supplied file has to be what it produced, because every
    # field that binds a bound to a build - kind, request digest, head, slot
    # count - is copyable out of a legitimate artifact while the maxima under
    # them are rewritten. Nothing downstream would catch that: the estimate is
    # taken FROM the maxima and the cohort sizes its ceiling from the same file,
    # so a lowered bound would be discovered only after the models had run.
    $checkSupplied = {
        param([scriptblock]$MutateBound, [switch]$Verbatim)
        $supplied = Join-Path $boundSandbox ('supplied-' + [guid]::NewGuid().ToString('n') + '.json')
        if ($Verbatim) {
            $verbatimBytes = [byte[]]@([IO.File]::ReadAllBytes($derivedPath))
            [IO.File]::WriteAllBytes($supplied, $verbatimBytes)
        }
        else {
            $parsed = $derivedText | ConvertFrom-Json -Depth 32
            if ($MutateBound) { & $MutateBound $parsed }
            $suppliedText = [string]($parsed | ConvertTo-Json -Depth 12)
            $suppliedBytes = [byte[]]@($script:Utf8.GetBytes($suppliedText))
            [IO.File]::WriteAllBytes($supplied, $suppliedBytes)
        }
        $destination = Join-Path $boundSandbox ('supplied-published-' + [guid]::NewGuid().ToString('n') + '.json')
        return (Get-CohortEntryRefusalCode -Action {
                $null = New-ReviewerCohortEntryModelStartBound -ToolkitRoot $boundFixture.Toolkit `
                    -ToolkitHead $boundFixture.ToolkitHead -RequestPath $emittedRequestPath `
                    -RequestSha256 $emittedRequestSha -OutputPath $destination -BoundArtifactPath $supplied
            })
    }

    Assert-CohortEntry -Name 'a supplied bound that is the one this build derives is accepted' `
        -Condition ((& $checkSupplied -Verbatim) -ceq '')
    Assert-CohortEntry -Name 'a supplied bound understating its maxima behind intact bindings is refused as CE714' `
        -Condition ((& $checkSupplied {
                param($b)
                $b.maxRealModelStarts = 4
                $b.maxVerifierAssignments = 4
            }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a supplied bound overstating its maxima behind intact bindings is refused as CE714' `
        -Condition ((& $checkSupplied {
                param($b)
                $b.maxRealModelStarts = 65000
                $b.maxVerifierAssignments = 65000
            }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a supplied bound saying the same thing in different bytes is accepted' `
        -Condition ((& $checkSupplied $null) -ceq '')
    # A supplied bound that parses to something falsy - `null`, `false`, `0`,
    # `[]`, `""` - is well-formed JSON and is exactly what a truncated or
    # half-written artifact looks like. Skipping the comparison for those would
    # be a gate reporting success without running, so each is refused.
    foreach ($falsy in @('null', 'false', '0', '[]', '""')) {
        $falsyPath = Join-Path $boundSandbox ('falsy-' + [guid]::NewGuid().ToString('n') + '.json')
        $falsyBytes = [byte[]]@($script:Utf8.GetBytes($falsy))
        [IO.File]::WriteAllBytes($falsyPath, $falsyBytes)
        Assert-CohortEntry -Name "a supplied bound that is the JSON literal $falsy is refused as CE714" `
            -Condition ((Get-CohortEntryRefusalCode -Action {
                    $null = New-ReviewerCohortEntryModelStartBound -ToolkitRoot $boundFixture.Toolkit `
                        -ToolkitHead $boundFixture.ToolkitHead -RequestPath $emittedRequestPath `
                        -RequestSha256 $emittedRequestSha `
                        -OutputPath (Join-Path $boundSandbox ('falsy-out-' + [guid]::NewGuid().ToString('n') + '.json')) `
                        -BoundArtifactPath $falsyPath
                }) -ceq 'CE714')
    }
    Assert-CohortEntry -Name 'a supplied bound that does not exist is refused as CE714' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                $null = New-ReviewerCohortEntryModelStartBound -ToolkitRoot $boundFixture.Toolkit `
                    -ToolkitHead $boundFixture.ToolkitHead -RequestPath $emittedRequestPath `
                    -RequestSha256 $emittedRequestSha -OutputPath (Join-Path $boundSandbox 'never.json') `
                    -BoundArtifactPath (Join-Path $boundSandbox 'absent-bound.json')
            }) -ceq 'CE714')
    # A toolkit that does not ship the producer cannot be bounded, and a build
    # over it is refused rather than given a number this file made up. A supplied
    # bound does not rescue it: with nothing to derive there is nothing to agree
    # with, which is exactly the case a pre-derived file would be asserted into.
    $strippedToolkit = Join-Path $boundSandbox 'stripped'
    [void](New-Item -ItemType Directory -Force -Path $strippedToolkit)
    Assert-CohortEntry -Name 'a toolkit that ships no bound producer is refused as CE714' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                $null = New-ReviewerCohortEntryModelStartBound -ToolkitRoot $strippedToolkit `
                    -ToolkitHead $boundFixture.ToolkitHead -RequestPath $emittedRequestPath `
                    -RequestSha256 $emittedRequestSha -OutputPath (Join-Path $boundSandbox 'never2.json')
            }) -ceq 'CE714')
    Assert-CohortEntry -Name 'a supplied bound over a toolkit shipping no producer is refused as CE714' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                $null = New-ReviewerCohortEntryModelStartBound -ToolkitRoot $strippedToolkit `
                    -ToolkitHead $boundFixture.ToolkitHead -RequestPath $emittedRequestPath `
                    -RequestSha256 $emittedRequestSha -OutputPath (Join-Path $boundSandbox 'never3.json') `
                    -BoundArtifactPath $derivedPath
            }) -ceq 'CE714')
}
finally { Remove-CohortEntrySandbox -Path $boundSandbox }

# An entry whose estimate sits below its own derived bound is the exact
# under-declaration the cohort runner refuses at Walk(). It is cheaper to refuse
# it at build time, so a preparation-only entry handed a slots-derived bound is
# refused rather than published with a budget it cannot honour.
$underSandbox = New-CohortEntrySandbox -Name 'under'
try {
    $underFixture = New-CohortEntryFixture -Sandbox $underSandbox
    # Built once to learn the digest of the request these inputs emit, then the
    # package is discarded and built again with a bound supplied against that
    # exact digest. Identical inputs emit an identical request, so the supplied
    # bound binds the second build as tightly as the first.
    $firstResult = New-ReviewerCohortEntryEvidence -RequestPath $underFixture.RequestPath -PreparationOnly
    $firstEntry = [IO.File]::ReadAllText((Join-Path $firstResult.Root 'entry/cohort-entry.json')) | ConvertFrom-Json -Depth 32
    $firstBound = [IO.File]::ReadAllText((Join-Path $firstResult.Root 'entry/model-start-bound.json')) | ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name 'a preparation-only entry derives a bound of zero real model starts' `
        -Condition (([int]$firstBound.maxRealModelStarts -eq 0) -and ([int]$firstBound.declaredSlotCount -eq 0))
    # A preparation-only entry is authorized to start ZERO models and to make
    # ZERO verifier assignments, and that is exactly what it must publish. It
    # used to publish PlannedRunCount (2) for both units, which reserved model
    # spend in the cohort budget for an entry that can spend none - every other
    # entry then competed against a reservation that could never be drawn on.
    # The planned runs are real work and are accounted as their own unit.
    Assert-CohortEntry -Name 'a preparation-only entry publishes the zero model-start budget it is bound to' `
        -Condition (([int]$firstEntry.planEstimate.modelStarts -eq 0) -and
            ([int]$firstEntry.planEstimate.modelStarts -eq [int]$firstBound.maxRealModelStarts))
    Assert-CohortEntry -Name 'a preparation-only entry publishes the zero verifier-assignment budget it is bound to' `
        -Condition (([int]$firstEntry.planEstimate.verifierAssignments -eq 0) -and
            ([int]$firstEntry.planEstimate.verifierAssignments -eq [int]$firstBound.maxVerifierAssignments))
    Assert-CohortEntry -Name 'a preparation-only entry accounts its planned runs as preparation, not as model starts' `
        -Condition ([int]$firstResult.PreparationRunCount -eq 2)
    Assert-CohortEntry -Name 'a preparation-only entry still declares the wall clock its preparation occupies' `
        -Condition ([int]$firstEntry.planEstimate.wallClockSeconds -gt 0)

    $supplied = Join-Path $underSandbox 'supplied.json'
    # Read the bytes out rather than copying the file: a published package is
    # read-only, and a copy of it carries that attribute to the destination.
    $firstBoundBytes = [byte[]]@([IO.File]::ReadAllBytes((Join-Path $firstResult.Root 'entry/model-start-bound.json')))
    [IO.File]::WriteAllBytes($supplied, $firstBoundBytes)
    Remove-CohortEntrySandbox -Path $firstResult.Root
    # Identical inputs emit an identical request, and an identical request
    # derives an identical bound. That reproducibility is what makes supplying a
    # bound meaningful at all: the second build states what the first did, or it
    # refuses.
    $secondResult = New-ReviewerCohortEntryEvidence -RequestPath $underFixture.RequestPath -PreparationOnly -BoundArtifactPath $supplied
    Assert-CohortEntry -Name 'a rebuild derives the same bound it was handed and is accepted' `
        -Condition ($null -ne $secondResult -and (Test-Path -LiteralPath (Join-Path $secondResult.Root 'entry/model-start-bound.json') -PathType Leaf))
    Remove-CohortEntrySandbox -Path $secondResult.Root

    # The same file with its maxima rewritten and every binding left intact.
    # Nothing downstream would catch this: the estimate is taken from the maxima
    # and the cohort sizes its ceiling from the same file, so a bound nobody
    # derived would be discovered only after the models had run.
    $firstBound.maxRealModelStarts = 270
    $firstBound.maxVerifierAssignments = 256
    $overstatedText = [string]($firstBound | ConvertTo-Json -Depth 12)
    $overstatedBytes = [byte[]]@($script:Utf8.GetBytes($overstatedText))
    [IO.File]::WriteAllBytes($supplied, $overstatedBytes)
    Assert-CohortEntry -Name 'a supplied bound this build does not derive is refused as CE714' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                New-ReviewerCohortEntryEvidence -RequestPath $underFixture.RequestPath -PreparationOnly -BoundArtifactPath $supplied
            }) -ceq 'CE714')

    # The same supplied bound, with the slot count it never declared. Two files
    # describing different requests through one path is refused rather than
    # reconciled.
    $firstBound.maxRealModelStarts = 0
    $firstBound.maxVerifierAssignments = 0
    $firstBound.declaredSlotCount = 2
    $miscountedText = [string]($firstBound | ConvertTo-Json -Depth 12)
    $miscountedBytes = [byte[]]@($script:Utf8.GetBytes($miscountedText))
    [IO.File]::WriteAllBytes($supplied, $miscountedBytes)
    Assert-CohortEntry -Name 'a supplied bound counting slots this entry never declared is refused as CE714' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                New-ReviewerCohortEntryEvidence -RequestPath $underFixture.RequestPath -PreparationOnly -BoundArtifactPath $supplied
            }) -ceq 'CE714')
}
finally { Remove-CohortEntrySandbox -Path $underSandbox }

# -------------------------------------------------------------------------

# a coordinator request is computed HERE in PowerShell, but the coordinator
# recomputes it in C# and refuses a mismatch. Two implementations of one digest
# is exactly the drift this deliverable exists to remove, so the two are
# compared directly against the SAME real toolkit, not against a fixture.
# -------------------------------------------------------------------------
Write-Host 'parity: prompt-asset digest against the coordinator fixture' -ForegroundColor Cyan
. (Join-Path $PSScriptRoot 'ShadowCoordinatorFixture.ps1')
$parityToolkit = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$builderPromptDigest = Get-ReviewerCohortEntryPromptAssetDigest -ToolkitRoot $parityToolkit
$coordinatorPromptDigest = Get-ShadowCoordinatorPromptAssetDigest -ToolkitRoot $parityToolkit
Assert-CohortEntry -Name 'the prompt-asset digest is a lower-case sha256' `
    -Condition ($builderPromptDigest -cmatch '^[0-9a-f]{64}$')
Assert-CohortEntry -Name 'the builder and the coordinator agree on the prompt-asset digest' `
    -Condition ($builderPromptDigest -ceq $coordinatorPromptDigest)

# -------------------------------------------------------------------------
# The no-model acceptance proof: the typed coordinator, over a package this
# builder published, driven to the last state before anything is launched.
# -------------------------------------------------------------------------
if ($IncludePreflight) {
    function Invoke-CohortEntryPreflightVariant {
        <#
        .SYNOPSIS
            One end-to-end no-model proof: build, drive the typed coordinator to
            the last state before a launch, then hand the published entry to the
            SHIPPING cohort reader.

        .DESCRIPTION
            Run once for a v1 request and once for a v2 request carrying an
            execution plan, because the claim under test is that BOTH shapes are
            accepted verbatim - the v2 entry with its two declared slots inside
            the hashed region, and the v1 entry unchanged beside it.
        #>
        param(
            [Parameter(Mandatory)][string]$Label,
            [Parameter(Mandatory)][string]$RealToolkitRoot,
            [switch]$WithExecutionPlan
        )
        $sandbox = New-CohortEntrySandbox -Name "preflight-$Label"
        try {
            $mutate = if ($WithExecutionPlan) { { param($s) $s.SchemaVersion = 2; $s.WithExecutionPlan = $true } } else { $null }
            $fixture = if ($mutate) {
                New-CohortEntryFixture -Sandbox $sandbox -RealToolkitRoot $RealToolkitRoot -Mutate $mutate
            }
            else { New-CohortEntryFixture -Sandbox $sandbox -RealToolkitRoot $RealToolkitRoot }
            $result = New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath -PreparationOnly
            $preparationRoot = ($result.Root.TrimEnd('\', '/') + '.preparation')
            $coordinatorRequestPath = Join-Path $result.Root 'entry/coordinator-request.json'
            $coordinatorRequest = [IO.File]::ReadAllText($coordinatorRequestPath) | ConvertFrom-Json -Depth 32
            if ($WithExecutionPlan) {
                Assert-CohortEntry -Name "${Label}: the request handed to the coordinator already carries two slots" `
                    -Condition (@($coordinatorRequest.slots.declared).Count -eq 2)
            }
            $reached = Invoke-ReviewerCohortEntryPreflight `
                -Request (Read-ReviewerCohortEntryRequest -Path $fixture.RequestPath) `
                -CoordinatorRequestPath $coordinatorRequestPath `
                -PreparationOutputRoot $preparationRoot -Target $PreflightTarget
            Assert-CohortEntry -Name "${Label}: the typed preflight reaches $PreflightTarget" -Condition ($reached -ceq $PreflightTarget)
            $preflightIntents = @(Get-ChildItem -LiteralPath (Join-Path $preparationRoot 'coordinator/intents') -File -Force -Filter '*.intent.json' -ErrorAction SilentlyContinue)
            $preflightSlotIntents = @($preflightIntents | Where-Object {
                    $intent = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json -Depth 16
                    # A set identifier alone is NOT a launch. Once the run set is
                    # verified the coordinator stamps its setId on every subsequent
                    # child, including the read-only status probe, so counting it
                    # here would call any run-set-ready preflight a slot launch.
                    [string]$intent.slotName -or [string]$intent.expectedTerminalPath
                })
            Assert-CohortEntry -Name "${Label}: the preflight launched no slot" -Condition ($preflightSlotIntents.Count -eq 0)
            Assert-CohortEntry -Name "${Label}: the preflight launched only read-only preparation children" `
                -Condition (@($preflightIntents | Where-Object {
                        [string]$_.Name -notmatch 'stagePreparation|corpusSealValidate|corpusSeal|snapshotValidate|runSetDeclare|runSetVerify'
                    }).Count -eq 0)
            Assert-CohortEntry -Name "${Label}: the preflight started no model" -Condition ($result.ModelStarts -eq 0)
            Assert-CohortEntry -Name "${Label}: the preflight wrote nothing to a provider" -Condition ($result.ProviderWrites -eq 0)
            Assert-CohortEntry -Name "${Label}: the preflight left the sealed package intact" `
                -Condition (Assert-ReviewerCohortEntryPublished -Root $result.Root -SealKeyPath $fixture.SealKeyPath)
            Assert-CohortEntry -Name "${Label}: the preflight wrote outside the sealed package" `
                -Condition ((Test-Path -LiteralPath $preparationRoot -PathType Container) -and
                    (-not (Test-ReviewerCohortEntryPathWithin -Candidate $preparationRoot -Root $result.Root)))

            # The claim "accepted directly by the cohort manifest, without
            # translation" is checked against the SHIPPING C# reader rather than
            # against a PowerShell restatement of what that reader wants. The entry
            # node is the published cohort-entry.json verbatim - copied, not
            # rebuilt - and the manifest around it is the minimum a manifest is.
            #
            # --rebuild-index is used because it is the one cohort verb that starts
            # nothing at all. CohortManifest.Load runs first and validates the
            # manifest and every entry field strictly; only afterwards does the
            # runner discover it has no journal to rebuild from. So the exact
            # refusal "there is no cohort journal ... to rebuild an index from" is
            # proof that everything before it - the whole entry - was accepted.
            # Any OTHER refusal is the entry being rejected, and fails this check.
            $entryNode = [IO.File]::ReadAllText((Join-Path $result.Root 'entry/cohort-entry.json')) | ConvertFrom-Json -Depth 32
            $cohortDll = Join-Path $RealToolkitRoot 'tools/ShadowRunCoordinator/bin/Release/net10.0/ShadowRunCoordinator.dll'
            if (Test-Path -LiteralPath $cohortDll -PathType Leaf) {
                $manifestPath = Join-Path $sandbox 'cohort-manifest.json'
                $toolkitBlock = [ordered]@{
                    repositoryRoot = $RealToolkitRoot
                    head = [string]$coordinatorRequest.toolkit.head
                    # The ref and head THIS entry pins, not names a checkout might
                    # not be standing on. A cohort that disagrees with its entry
                    # about either is refused before it looks at anything else -
                    # which is a real check, and not the one any assertion here is
                    # about.
                    requiredRef = [string]$coordinatorRequest.qualification.requiredRef
                }
                # Taken FROM the entry: the entry's plan estimate is what a real
                # review of this subject would consume, and a manifest whose
                # ceiling is below its own sealed estimates is refused before it
                # starts. Nothing is consumed here - the walk below starts a stub
                # - but the ceiling still has to be coherent.
                $budgetsBlock = [ordered]@{
                    maxPullRequests = 1
                    maxModelStarts = [int]$entryNode.planEstimate.modelStarts
                    maxVerifierAssignments = [int]$entryNode.planEstimate.verifierAssignments
                    maxWallClockSeconds = [int]$entryNode.planEstimate.wallClockSeconds
                    providerWriteBudget = 0
                }
                $manifest = [ordered]@{
                    contractVersion = 'devpilot.shadow-cohort.manifest.v3'
                    kind = 'shadow-cohort-run'
                    cohortId = 'cohort-entry-evidence-acceptance'
                    correlationId = [string]$coordinatorRequest.correlationId
                    toolkit = $toolkitBlock
                    execution = [ordered]@{
                        concurrency = 1
                        stopPolicy = 'failFast'
                        authorizationKind = 'PreviewOnly'
                        commandPath = 'dotnet'
                        argumentPrefix = [string[]]@($cohortDll)
                        target = 'runSetReady'
                        entryTimeoutSeconds = 120
                    }
                    budgets = $budgetsBlock
                    journal = [ordered]@{ root = (Join-Path $sandbox 'cohort-journal') }
                    audit = [ordered]@{ indexPath = (Join-Path $sandbox 'cohort-index/index.json') }
                    entries = @($entryNode)
                }
                Write-CohortEntryJsonFile -Path $manifestPath -Value $manifest
                $previousNative = $PSNativeCommandUseErrorActionPreference
                $PSNativeCommandUseErrorActionPreference = $false
                $acceptance = ''
                try {
                    $acceptance = (& dotnet $cohortDll --cohort $manifestPath --authorized-by 'cohort-entry-test' --rebuild-index 2>&1 | Out-String)
                }
                finally { $PSNativeCommandUseErrorActionPreference = $previousNative }
                Assert-CohortEntry -Name "${Label}: the shipping cohort manifest reader accepts the published entry verbatim" `
                    -Condition ($acceptance -match 'no cohort journal')
                Assert-CohortEntry -Name "${Label}: the shipping cohort reader refuses nothing about the entry itself" `
                    -Condition ($acceptance -notmatch 'entry\s+\d+|entryId|ordinal|planEstimate|ruleBundle|subject')

                # --------------------------------------------------------
                # PAST the reader, into Walk(). RequireSealedModelStartBounds
                # is only reached by a cohort that actually walks, and
                # --rebuild-index never does - which is precisely why a
                # builder that published an unreadable bound passed every
                # acceptance check for as long as it did. This run has a
                # journal and a key, starts a stub rather than a preparation,
                # and therefore reaches the one check that reads the bound.
                # --------------------------------------------------------
                $stubPath = Join-Path $sandbox 'stub-preparation.ps1'
                [IO.File]::WriteAllBytes($stubPath, $script:Utf8.GetBytes(@(
                            'param([Parameter(ValueFromRemainingArguments = $true)]$Rest)'
                            '# Starts nothing and publishes nothing. Its entry ends unsuccessfully,'
                            '# which is after the bound check and therefore proves the bound passed.'
                            'exit 0'
                            ''
                        ) -join "`n"))
                $walkExecution = [ordered]@{
                    concurrency = 1
                    stopPolicy = 'failFast'
                    authorizationKind = 'PreviewOnly'
                    commandPath = (Get-Process -Id $PID).Path
                    argumentPrefix = [string[]]@('-NoProfile', '-NonInteractive', '-File', $stubPath)
                    target = 'runSetReady'
                    entryTimeoutSeconds = 120
                }
                $runWalk = {
                    param([string]$Name, $EntryNode)
                    $walkManifest = [ordered]@{
                        contractVersion = 'devpilot.shadow-cohort.manifest.v3'
                        kind = 'shadow-cohort-test-run'
                        cohortId = 'cohort-entry-evidence-walk'
                        correlationId = [string]$coordinatorRequest.correlationId
                        toolkit = $toolkitBlock
                        execution = $walkExecution
                        budgets = $budgetsBlock
                        journal = [ordered]@{ root = (Join-Path $sandbox "walk-journal-$Name") }
                        audit = [ordered]@{ indexPath = (Join-Path $sandbox "walk-index-$Name/index.json") }
                        entries = @($EntryNode)
                    }
                    $walkPath = Join-Path $sandbox "walk-manifest-$Name.json"
                    Write-CohortEntryJsonFile -Path $walkPath -Value $walkManifest
                    $previous = $PSNativeCommandUseErrorActionPreference
                    $PSNativeCommandUseErrorActionPreference = $false
                    try {
                        $text = (& dotnet $cohortDll --cohort $walkPath --authorized-by 'cohort-entry-test' 2>&1 | Out-String)
                        # The exit code is what separates a pre-walk refusal from a
                        # walk that reached its entry. Output alone cannot: the
                        # runner prints its banner before either happens.
                        $script:WalkExitCode = $LASTEXITCODE
                        [IO.File]::WriteAllText((Join-Path $sandbox "walk-output-$Name.txt"), "exit=$script:WalkExitCode`n$text")
                        return $text
                    }
                    finally { $PSNativeCommandUseErrorActionPreference = $previous }
                }

                if ($WithExecutionPlan) {
                    # Every assertion below is about an entry whose preparation
                    # has ALREADY declared its run set: before that point the
                    # declaration has not minted an authorization yet, and a
                    # cohort demanding one would refuse every entry that had not
                    # run. This preparation stopped short of declaring, so its
                    # recorded state is advanced to the point the question starts
                    # being answerable. Only the state name matters here; the
                    # cohort refuses the entry before it reads anything else.
                    $walkStatePath = Join-Path ($result.Root.TrimEnd('\', '/') + '.preparation') 'coordinator/state.json'
                    $walkState = ([IO.File]::ReadAllText($walkStatePath)) | ConvertFrom-Json -Depth 32
                    $walkState.state = 'runSetDeclared'
                    [IO.File]::WriteAllBytes($walkStatePath,
                        $script:Utf8.GetBytes([string]($walkState | ConvertTo-Json -Depth 32 -Compress)))
                }

                $walkAccepted = & $runWalk 'accepted' $entryNode
                Assert-CohortEntry -Name "${Label}: the derived bound survives RequireSealedModelStartBounds" `
                    -Condition ($walkAccepted -notmatch 'model start bound|bounds admit')
                if ($WithExecutionPlan) {
                    # A slots-carrying entry built -PreparationOnly names a launch
                    # authorization no declaration has published yet. That entry is
                    # not runnable, and the cohort has to say so BEFORE it starts
                    # anything - which is the whole correction here. The walk that
                    # reaches its entry is asserted below only for the
                    # preparation-only shape, because this one must not.
                    Assert-CohortEntry -Name "${Label}: a cohort refuses an entry whose launch authorization was never published" `
                        -Condition ($walkAccepted -match 'with its slots authorized by')
                    # The refusal has to arrive before the entry is started, not
                    # after. Two independent witnesses, because the runner's
                    # startup banner is printed either way and proves nothing: the
                    # per-entry line the walk writes when it begins an attempt is
                    # absent, and the run ended non-zero without publishing an
                    # index for the entry to be recorded in.
                    Assert-CohortEntry -Name "${Label}: that refusal happens before any entry starts" `
                        -Condition ($walkAccepted -notmatch 'attempt 1 subject=')
                    Assert-CohortEntry -Name "${Label}: the refused walk ends non-zero" `
                        -Condition ($script:WalkExitCode -ne 0)
                }
                else {
                    # A v1 entry authorizes no launch, so the cohort refuses it for
                    # having no slots - which is a refusal from PAST both pre-walk
                    # gates. Asserting that exact refusal is what proves the bound
                    # check and the authorization check both admitted it; asserting
                    # the runner's startup banner would prove nothing, because the
                    # banner is printed before either gate runs.
                    Assert-CohortEntry -Name "${Label}: the cohort walked past the bound and authorization checks" `
                        -Condition ($walkAccepted -match "carries no 'slots' section")
                }

                if ($WithExecutionPlan) {
                    # The positive half, and the sabotages that share its shape. A
                    # token is written at the one derived path - which is what a
                    # real declaration would have published there - and the cohort
                    # walks past the check it was refused by a moment ago.
                    $walkRunSet = Join-Path ($result.Root.TrimEnd('\', '/') + '.preparation') 'qualification/runset'
                    [void](New-Item -ItemType Directory -Force -Path $walkRunSet)
                    $walkToken = Join-Path $walkRunSet 'launch-authorization.token'
                    $writeWalkToken = { param([string]$Text) [IO.File]::WriteAllBytes($walkToken, $script:Utf8.GetBytes($Text)) }
                    & $writeWalkToken ('a' * 64)
                    Assert-CohortEntry -Name "${Label}: a published launch authorization lets the cohort reach its entry" `
                        -Condition ((& $runWalk 'authorized' $entryNode) -notmatch 'with its slots authorized by')
                    & $writeWalkToken ('a' * 63)
                    Assert-CohortEntry -Name "${Label}: a launch authorization of the wrong length is refused" `
                        -Condition ((& $runWalk 'shorttoken' $entryNode) -match 'not the 64 lowercase hex characters')
                    & $writeWalkToken (('A' * 64))
                    Assert-CohortEntry -Name "${Label}: a launch authorization that is not lowercase hex is refused" `
                        -Condition ((& $runWalk 'uppertoken' $entryNode) -match 'not the 64 lowercase hex characters')
                    # Substituted after everything else about the entry was
                    # published and sealed. The cohort still sees a well-formed
                    # token here; what refuses it is the reviewed prelaunch, which
                    # reproduces the run set plan only from the token that was
                    # minted into it. This asserts the cohort does not pretend to
                    # settle that question itself.
                    & $writeWalkToken ('b' * 64)
                    Assert-CohortEntry -Name "${Label}: a substituted well-formed token is left for the prelaunch to refuse" `
                        -Condition ((& $runWalk 'substituted' $entryNode) -notmatch 'with its slots authorized by')
                    Remove-Item -LiteralPath $walkToken -Force
                    Assert-CohortEntry -Name "${Label}: a launch authorization removed after publication is refused" `
                        -Condition ((& $runWalk 'removedtoken' $entryNode) -match 'with its slots authorized by')
                }

                # The exact defect this fix exists for: an entry whose estimate
                # is its slot count while its bound admits every attempt those
                # slots may make. Nothing else about the entry changes. Only a
                # variant that declares slots has a bound to fall short of; a
                # preparation-only entry proves nothing here, because a bound of
                # zero real model starts is one no estimate can sit below.
                if ($WithExecutionPlan) {
                    $understated = ([IO.File]::ReadAllText((Join-Path $result.Root 'entry/cohort-entry.json'))) | ConvertFrom-Json -Depth 32
                    $understated.planEstimate.modelStarts = 2
                    $understated.planEstimate.verifierAssignments = 2
                    $walkUnderstated = & $runWalk 'understated' $understated
                    Assert-CohortEntry -Name "${Label}: an entry estimating its slot count is refused against its own bound" `
                        -Condition ($walkUnderstated -match 'model start\(s\) and its sealed bound|verifier assignment\(s\) and its')
                }

                # A bound wearing a kind this builder invented is not loadable at
                # all, which is why the placeholder never became an under-declared
                # budget - it became an unrunnable cohort instead.
                $tamperedBound = Join-Path $sandbox 'tampered-bound.json'
                $tamperedShape = ([IO.File]::ReadAllText((Join-Path $result.Root 'entry/model-start-bound.json'))) | ConvertFrom-Json -Depth 32
                $tamperedShape.kind = 'devpilot.shadow-cohort.model-start-bound.v3'
                $tamperedText = [string]($tamperedShape | ConvertTo-Json -Depth 12)
                $tamperedBytes = [byte[]]@($script:Utf8.GetBytes($tamperedText))
                [IO.File]::WriteAllBytes($tamperedBound, $tamperedBytes)
                $tamperedEntry = ([IO.File]::ReadAllText((Join-Path $result.Root 'entry/cohort-entry.json'))) | ConvertFrom-Json -Depth 32
                $tamperedEntry.planEstimate.modelStartBound.path = $tamperedBound
                $tamperedEntry.planEstimate.modelStartBound.sha256 =
                    (Get-FileHash -LiteralPath $tamperedBound -Algorithm SHA256).Hash.ToLowerInvariant()
                $walkTampered = & $runWalk 'tampered' $tamperedEntry
                Assert-CohortEntry -Name "${Label}: a bound wearing an invented kind is refused at Walk" `
                    -Condition ($walkTampered -match "model start bound")
            }
        }
        finally {
            Remove-CohortEntryCreatedRef
            if (-not $KeepSandbox) { Remove-CohortEntrySandbox -Path $sandbox } else { Write-Host "sandbox kept: $sandbox" }
        }
    }

    Write-Host "preflight: $PreflightTarget with zero models" -ForegroundColor Cyan
    $realToolkit = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Invoke-CohortEntryPreflightVariant -Label 'v1' -RealToolkitRoot $realToolkit
    Invoke-CohortEntryPreflightVariant -Label 'v2' -RealToolkitRoot $realToolkit -WithExecutionPlan
    # The suite runs against the real checkout here, and on a detached one - every
    # hosted run - the fixture has to create a ref to pin. It does not get to keep
    # it: in a worktree that ref is visible to every sibling worktree and holds the
    # commit against gc, which is a fixture editing the repository it is testing.
    Assert-CohortEntry -Name 'the preflight leaves no fixture ref behind in the real checkout' `
        -Condition ((Get-CohortEntryGitLine -Arguments @('-C', $realToolkit, 'for-each-ref',
                '--format=%(refname)', 'refs/cohort-entry-fixture')) -ceq '')

    # ------------------------------------------------------------------
    # The whole claim, in one run: a slots-carrying build that DECLARES its
    # own run set, mints its own launch authorization through the reviewed
    # qualification tool, and comes back cohort-ready - then is handed to
    # the shipping cohort runner, which walks past the check that refuses
    # every entry above and starts the entry's own preparation.
    #
    # Nothing here is hand-written. The token is the one the declaration
    # published, so this is also the only place the derived path is proved
    # to be the published path by construction rather than by comparison.
    # ------------------------------------------------------------------
    Write-Host 'cohort-ready: a builder-produced entry that declared its own run set' -ForegroundColor Cyan
    $readySandbox = New-CohortEntrySandbox -Name 'cohort-ready'
    try {
        $readyFixture = New-CohortEntryFixture -Sandbox $readySandbox -RealToolkitRoot $realToolkit `
            -Mutate { param($s) $s.SchemaVersion = 2; $s.WithExecutionPlan = $true; $s.UseRealReviewerScript = $true }
        $readyResult = New-ReviewerCohortEntryEvidence -RequestPath $readyFixture.RequestPath `
            -Preflight -PreflightTarget 'runSetReady'
        Assert-CohortEntry -Name 'a build that reached runSetReady reports itself cohort-ready' `
            -Condition ([bool]$readyResult.CohortReady)
        Assert-CohortEntry -Name 'the build reports the run set it declared' `
            -Condition (([string]$readyResult.RunSetId) -cmatch '^[0-9a-f]{32}$')
        Assert-CohortEntry -Name 'the build reports the digest of the authorization it bound to' `
            -Condition (([string]$readyResult.LaunchAuthorizationSha256) -cmatch '^[0-9a-f]{64}$')
        $readyPrep = $readyResult.Root.TrimEnd('\', '/') + '.preparation'
        $readyToken = Join-Path (Join-Path $readyPrep 'qualification/runset') 'launch-authorization.token'
        Assert-CohortEntry -Name 'the declaration published its authorization at the derived path' `
            -Condition (([string]$readyResult.LaunchAuthorizationPath) -ceq $readyToken)
        Assert-CohortEntry -Name 'the published authorization exists and is read-only' `
            -Condition ((Test-Path -LiteralPath $readyToken -PathType Leaf) -and
                (Get-Item -LiteralPath $readyToken -Force).IsReadOnly)
        $readyEmitted = [IO.File]::ReadAllText((Join-Path $readyResult.Root 'entry/coordinator-request.json')) |
            ConvertFrom-Json -Depth 32
        Assert-CohortEntry -Name 'both slots carry the authorization the declaration actually published' `
            -Condition (@($readyEmitted.slots.declared | Where-Object {
                        ([string]$_.launchAuthorizationTokenPath) -ceq $readyToken
                    }).Count -eq 2)
        Assert-CohortEntry -Name 'the build started no model reaching runSetReady' `
            -Condition (($readyResult.ModelStarts -eq 0) -and ($readyResult.ProviderWrites -eq 0))

        $readyDll = Join-Path $realToolkit 'tools/ShadowRunCoordinator/bin/Release/net10.0/ShadowRunCoordinator.dll'
        if (Test-Path -LiteralPath $readyDll -PathType Leaf) {
            $readyEntry = [IO.File]::ReadAllText((Join-Path $readyResult.Root 'entry/cohort-entry.json')) |
                ConvertFrom-Json -Depth 32
            $readyStub = Join-Path $readySandbox 'ready-stub.ps1'
            [IO.File]::WriteAllBytes($readyStub, $script:Utf8.GetBytes(@(
                        'param([Parameter(ValueFromRemainingArguments = $true)]$Rest)'
                        '# Stands in for the entry preparation. Starts no model and'
                        '# publishes no terminal, so the entry ends unsuccessfully - which'
                        '# is AFTER the launch authorization check this run is about.'
                        'exit 0'
                        ''
                    ) -join "`n"))
            $readyManifest = [ordered]@{
                contractVersion = 'devpilot.shadow-cohort.manifest.v3'
                kind = 'shadow-cohort-test-run'
                cohortId = 'cohort-entry-ready'
                correlationId = [string]$readyEmitted.correlationId
                toolkit = [ordered]@{
                    repositoryRoot = $realToolkit
                    head = [string]$readyEmitted.toolkit.head
                    requiredRef = [string]$readyEmitted.qualification.requiredRef
                }
                execution = [ordered]@{
                    concurrency = 1
                    stopPolicy = 'failFast'
                    authorizationKind = 'PreviewOnly'
                    commandPath = (Get-Process -Id $PID).Path
                    argumentPrefix = [string[]]@('-NoProfile', '-NonInteractive', '-File', $readyStub)
                    target = 'runSetReady'
                    entryTimeoutSeconds = 120
                }
                budgets = [ordered]@{
                    maxPullRequests = 1
                    maxModelStarts = [int]$readyEntry.planEstimate.modelStarts
                    maxVerifierAssignments = [int]$readyEntry.planEstimate.verifierAssignments
                    maxWallClockSeconds = [int]$readyEntry.planEstimate.wallClockSeconds
                    providerWriteBudget = 0
                }
                journal = [ordered]@{ root = (Join-Path $readySandbox 'ready-journal') }
                audit = [ordered]@{ indexPath = (Join-Path $readySandbox 'ready-index/index.json') }
                entries = @($readyEntry)
            }
            $readyManifestPath = Join-Path $readySandbox 'ready-manifest.json'
            Write-CohortEntryJsonFile -Path $readyManifestPath -Value $readyManifest
            $previousReady = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
            $readyExit = 0
            try {
                $readyWalk = (& dotnet $readyDll --cohort $readyManifestPath --authorized-by 'cohort-entry-test' 2>&1 | Out-String)
                $readyExit = $LASTEXITCODE
            }
            finally { $PSNativeCommandUseErrorActionPreference = $previousReady }
            Write-Verbose "ready walk exit=$readyExit`n$readyWalk"
            [IO.File]::WriteAllText((Join-Path $readySandbox 'ready-walk-output.txt'), "exit=$readyExit`n$readyWalk")
            Assert-CohortEntry -Name 'the cohort accepts a builder-produced entry that declared its own run set' `
                -Condition ($readyWalk -notmatch 'with its slots authorized by|not the 64 lowercase hex')
            # NOT the startup banner: that is printed before the pre-walk pass runs
            # and so is printed by a refusal too. The per-entry attempt line is
            # written only from inside the entry loop, which is past every
            # pre-walk check.
            Assert-CohortEntry -Name 'the cohort walked past every pre-walk check and started the entry' `
                -Condition ($readyWalk -match "attempt 1 subject=")
            Assert-CohortEntry -Name 'the cohort recorded that entry in its journal' `
                -Condition (@(Get-ChildItem -LiteralPath (Join-Path $readySandbox 'ready-journal') -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)
            Assert-CohortEntry -Name 'the cohort walk started no model' `
                -Condition ($readyWalk -match 'modelStarts=0' -and $readyWalk -notmatch 'modelStarts=[1-9]')
        }
    }
    finally {
        Remove-CohortEntryCreatedRef
        if (-not $KeepSandbox) { Remove-CohortEntrySandbox -Path $readySandbox } else { Write-Host "sandbox kept: $readySandbox" }
    }
    Assert-CohortEntry -Name 'the cohort-ready proof leaves no fixture ref behind in the real checkout' `
        -Condition ((Get-CohortEntryGitLine -Arguments @('-C', $realToolkit, 'for-each-ref',
                '--format=%(refname)', 'refs/cohort-entry-fixture')) -ceq '')
}

# -------------------------------------------------------------------------
Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "$($script:Failures.Count) of $($script:Checks) checks failed:" -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "All $($script:Checks) cohort-entry evidence checks passed." -ForegroundColor Green
exit 0
