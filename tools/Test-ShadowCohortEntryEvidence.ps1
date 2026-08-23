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
        RealToolkitRoot = $RealToolkitRoot
        RuleServedText = ''
        RuleResourceUri = ''
        OmitDiffVariant = $false
        RequestWithBom = $false
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
        $branch = ([string](& git -C $toolkit rev-parse --abbrev-ref HEAD)).Trim()
        $toolkitRef = "refs/heads/$branch"
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
            foreach ($module in @('QualificationPreflight.ps1', 'ReplayQualification.ps1', 'ModelStartCensus.ps1')) {
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
    Write-CohortEntryJsonFile -Path $configPath -Value ([ordered]@{
            repository = [ordered]@{
                organization = $state.Organization
                project = $state.Project
                name = $state.RepositoryName
                id = $state.RepositoryId
            }
            review = $reviewSection
        })

    $rulePath = '/docs/rules/review.md'
    $ruleBytes = $script:Utf8.GetBytes($state.RuleText)
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
    [void]$reads.Add(@{
            Tool = 'repo_pull_request'
            Arguments = [ordered]@{ action = 'get_changes'; project = $state.Project; repositoryId = $state.RepositoryName; pullRequestId = $state.PullRequestId; top = 51 }
            Bytes = (New-CohortEntryTextEnvelope -Value $state.ChangesBody)
        })
    if (-not $state.OmitDiffVariant) {
        [void]$reads.Add(@{
                Tool = 'repo_pull_request'
                Arguments = [ordered]@{ action = 'get_changes'; project = $state.Project; repositoryId = $state.RepositoryName; pullRequestId = $state.PullRequestId; includeDiffs = $true; includeLineContent = $true; top = 51 }
                Bytes = (New-CohortEntryTextEnvelope -Value $state.DiffChangesBody)
            })
    }
    [void]$reads.Add(@{
            Tool = 'repo_pull_request_thread'
            Arguments = [ordered]@{ action = 'list'; project = $state.Project; repositoryId = $state.RepositoryName; pullRequestId = $state.PullRequestId; top = 201 }
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
    [void]$reads.Add(@{
            Tool = 'repo_file'
            Arguments = [ordered]@{ action = 'get_content'; project = $state.Project; repositoryId = $state.RepositoryId; path = $rulePath; versionType = 'Commit'; version = $state.RuleCommit }
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
        # Deliberately NOT created. The builder records the path and never mints,
        # reads or requires a launch authorization; a fixture that pre-created one
        # would be testing a builder that could launch itself.
        $tokenPath = Join-Path $Sandbox 'launch/authorization.token'
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
                    launchAuthorizationTokenPath = $tokenPath
                    modelPlan = [ordered]@{ bindSealedArguments = $false; opaqueArguments = @() }
                },
                [ordered]@{
                    name = 'slot2'
                    stateDirName = 'slot2-state'
                    terminalName = 'slot2-terminal.json'
                    launchAuthorizationTokenPath = $tokenPath
                    modelPlan = [ordered]@{ bindSealedArguments = $false; opaqueArguments = @() }
                }
            )
            reconciliation = [ordered]@{
                reconciliationEnabled = $true
                outputDirName = 'reconciliation'
                launchAuthorizationTokenPath = $tokenPath
            }
            delivery = [ordered]@{
                deliveryEnabled = $true
                authorizationKind = 'PreviewOnly'
                outputDirName = 'delivery'
                launchAuthorizationTokenPath = $tokenPath
                commentsEnabled = $false
                votesEnabled = $false
                gatesEnabled = $false
                providerWriteBudget = 0
            }
        }
        if ($state.MutateExecutionPlan) { & $state.MutateExecutionPlan $executionPlan $state }
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
                sections = @([ordered]@{
                        path = $rulePath
                        commit = $state.RuleCommit
                        sha256 = (Get-CohortEntryBytesSha256 -Bytes $ruleBytes)
                        byteLength = $ruleBytes.Length
                    })
            }
            capture = [ordered]@{
                mode = 'replay'
                replayRoot = $replayRoot
                replaySnapshotName = 'fixture'
                replayManifestDigest = $manifestDigest
            }
            coverage = [ordered]@{
                maxChangedFiles = 50
                maxFileBytes = 65536
                maxSiblingFiles = $state.MaxSiblingFiles
                maxThreads = 200
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
        [Parameter(Mandatory)][scriptblock]$Mutate
    )
    $sandbox = New-CohortEntrySandbox -Name 'sabotage'
    try {
        $fixture = New-CohortEntryFixture -Sandbox $sandbox -Mutate $Mutate
        $observed = Get-CohortEntryRefusalCode -Action { New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath }
        # An empty expectation is a case that must be ACCEPTED. Those matter as
        # much as the refusals: a check that refuses something the reviewer would
        # have run is a false refusal, not a stricter check.
        $label = if ($ExpectedCode) { "refuses $ExpectedCode" } else { 'is accepted' }
        Assert-CohortEntry -Name "$Name $label (observed '$observed')" -Condition ($observed -ceq $ExpectedCode)
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
Assert-CohortEntry -Name 'the change reads ask one above the declared cap so a truncated answer is visible' `
    -Condition (@($plainPlan | Where-Object { $_.Arguments['action'] -ceq 'get_changes' } |
            Where-Object { [int]$_.Arguments['top'] -ne 301 }).Count -eq 0)
Assert-CohortEntry -Name 'the thread read asks one above the declared thread cap' `
    -Condition ([int](@($plainPlan | Where-Object { $_.Id -ceq 'threads' })[0].Arguments['top']) -eq 201)
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
    $result = New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath

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
        -Condition ((Get-CohortEntryRefusalCode -Action { New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath }) -ceq 'CE500')
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
    $noPolicyCode = Get-CohortEntryRefusalCode -Action { New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath }
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
    $oneResult = New-ReviewerCohortEntryEvidence -RequestPath $oneFile.RequestPath
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
                New-ReviewerCohortEntryEvidence -RequestPath $dirtyFixture.RequestPath
            }) -ceq 'CE213')
    # An UNTRACKED file changes nothing the builder reads and must not refuse,
    # or the builder is unusable in the working directories operators have.
    [IO.File]::WriteAllBytes($promptPath,
        [Text.UTF8Encoding]::new($false).GetBytes("# fixture review cycle`n"))
    [IO.File]::WriteAllText((Join-Path $dirtyToolkit 'src/scratch.tmp'), 'scratch')
    Assert-CohortEntry -Name 'an untracked scratch file in the toolkit is accepted' `
        -Condition ((Get-CohortEntryRefusalCode -Action {
                New-ReviewerCohortEntryEvidence -RequestPath $dirtyFixture.RequestPath
            }) -ceq '')
}
finally { Remove-CohortEntrySandbox -Path $dirtySandbox }

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
    $result = New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath
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
    $v1Result = New-ReviewerCohortEntryEvidence -RequestPath $v1Fixture.RequestPath
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
    $v2BareFixture = New-CohortEntryFixture -Sandbox $v2BareSandbox -Mutate { param($s) $s.SchemaVersion = 2 }
    $v2BareResult = New-ReviewerCohortEntryEvidence -RequestPath $v2BareFixture.RequestPath
    $v2BareRequest = [IO.File]::ReadAllText((Join-Path $v2BareResult.Root 'entry/coordinator-request.json')) | ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name 'a v2 request without a plan emits no slots section' `
        -Condition (-not $v2BareRequest.PSObject.Properties['slots'])
    Assert-CohortEntry -Name 'a v2 request without a plan reports schema version 2' -Condition ($v2BareResult.SchemaVersion -eq 2)
}
finally { Remove-CohortEntrySandbox -Path $v2BareSandbox }

# -- v2 with a plan: the whole declaration, in the hashed region -------------
$v2Sandbox = New-CohortEntrySandbox -Name 'v2-plan'
try {
    $v2Fixture = New-CohortEntryFixture -Sandbox $v2Sandbox -Mutate {
        param($s) $s.SchemaVersion = 2; $s.WithExecutionPlan = $true
    }
    $v2Result = New-ReviewerCohortEntryEvidence -RequestPath $v2Fixture.RequestPath
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
    # The builder mints no launch authorization, so the token the plan names must
    # still not exist after a complete build.
    Assert-CohortEntry -Name 'the builder minted no launch authorization' `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $v2Sandbox 'launch/authorization.token')))
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
Invoke-CohortEntryCase -ExpectedCode 'CE711' -Name 'a launch authorization inside the sealed package' `
    -Mutate (& $withPlan {
        param($p, $s)
        $inside = Join-Path (Join-Path (Split-Path ([string]$p.reviewerScript.path) -Parent) 'private/entry') 'authorization.token'
        $p.slots[0].launchAuthorizationTokenPath = $inside
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
    $boundResult = New-ReviewerCohortEntryEvidence -RequestPath $boundFixture.RequestPath
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
    $firstResult = New-ReviewerCohortEntryEvidence -RequestPath $underFixture.RequestPath
    $firstEntry = [IO.File]::ReadAllText((Join-Path $firstResult.Root 'entry/cohort-entry.json')) | ConvertFrom-Json -Depth 32
    $firstBound = [IO.File]::ReadAllText((Join-Path $firstResult.Root 'entry/model-start-bound.json')) | ConvertFrom-Json -Depth 32
    Assert-CohortEntry -Name 'a preparation-only entry derives a bound of zero real model starts' `
        -Condition (([int]$firstBound.maxRealModelStarts -eq 0) -and ([int]$firstBound.declaredSlotCount -eq 0))
    Assert-CohortEntry -Name 'a preparation-only entry still estimates the runs it plans' `
        -Condition ([int]$firstEntry.planEstimate.modelStarts -eq 2)

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
    $secondResult = New-ReviewerCohortEntryEvidence -RequestPath $underFixture.RequestPath -BoundArtifactPath $supplied
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
                New-ReviewerCohortEntryEvidence -RequestPath $underFixture.RequestPath -BoundArtifactPath $supplied
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
                New-ReviewerCohortEntryEvidence -RequestPath $underFixture.RequestPath -BoundArtifactPath $supplied
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
            $result = New-ReviewerCohortEntryEvidence -RequestPath $fixture.RequestPath
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
                    head = (& git -C $RealToolkitRoot rev-parse HEAD).Trim()
                    requiredRef = 'refs/heads/main'
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
                    try { return (& dotnet $cohortDll --cohort $walkPath --authorized-by 'cohort-entry-test' 2>&1 | Out-String) }
                    finally { $PSNativeCommandUseErrorActionPreference = $previous }
                }

                $walkAccepted = & $runWalk 'accepted' $entryNode
                Assert-CohortEntry -Name "${Label}: the derived bound survives RequireSealedModelStartBounds" `
                    -Condition ($walkAccepted -notmatch 'model start bound|bounds admit')
                Assert-CohortEntry -Name "${Label}: the cohort walked past the bound check and reached its entry" `
                    -Condition ($walkAccepted -match 'shadow-cohort-runner')

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
        finally { if (-not $KeepSandbox) { Remove-CohortEntrySandbox -Path $sandbox } else { Write-Host "sandbox kept: $sandbox" } }
    }

    Write-Host "preflight: $PreflightTarget with zero models" -ForegroundColor Cyan
    $realToolkit = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Invoke-CohortEntryPreflightVariant -Label 'v1' -RealToolkitRoot $realToolkit
    Invoke-CohortEntryPreflightVariant -Label 'v2' -RealToolkitRoot $realToolkit -WithExecutionPlan
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
