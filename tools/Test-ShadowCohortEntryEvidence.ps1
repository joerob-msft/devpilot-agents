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
    [ValidateSet('requestValidated', 'corpusValidated', 'recipePlanned', 'runSetReady')]
    [string]$PreflightTarget = 'recipePlanned'
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
        MinCoveragePercent = 100
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
            # One reviewer prompt asset, because the coordinator binds a run to
            # the set of them and refuses a toolkit that ships none.
            [IO.File]::WriteAllBytes(
                (Join-Path $toolkit 'src/Agents/reviewer/review-cycle.prompt.md'),
                [System.Text.UTF8Encoding]::new($false).GetBytes("# fixture review cycle`n"))
            & git add -A | Out-Null
            & git commit --quiet -m 'fixture' | Out-Null
            $toolkitHead = ([string](& git rev-parse HEAD)).Trim()
        }
        finally { Pop-Location }
    }

    # -- reviewer configuration and rule bundle --------------------------
    $configPath = Join-Path $Sandbox 'reviewer.config.json'
    Write-CohortEntryJsonFile -Path $configPath -Value ([ordered]@{
            repository = [ordered]@{
                organization = $state.Organization
                project = $state.Project
                name = $state.RepositoryName
                id = $state.RepositoryId
            }
            review = [ordered]@{ $state.ConfigTargetKeyName = $state.ConfigTargetRefName }
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
    Write-CohortEntryJsonFile -Path $requestPath -WithBom:$state.RequestWithBom -Value ([ordered]@{
            schemaVersion = 1
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
                plannedRunCount = 2
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
        })

    return [pscustomobject][ordered]@{
        Sandbox = $Sandbox
        RequestPath = $requestPath
        OutputRoot = $outputRoot
        SealKeyPath = $sealKeyPath
        ConfigPath = $configPath
        Toolkit = $toolkit
        ToolkitHead = $toolkitHead
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
    Assert-CohortEntry -Name 'coverage reached the declared floor' -Condition ($result.CoveragePercent -eq 100)

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

Invoke-CohortEntryCase -Name 'a snapshot missing the get_changes diff variant' -ExpectedCode 'CE300' -Mutate {
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
Assert-CohortEntry -Name 'coverage under the declared floor refuses CE403' `
    -Condition ((Get-CohortEntryRefusalCode -Action {
            Measure-ReviewerCohortEntryCoverage -Census $gapCensus -CoveredCount 1 -MinimumPercent 100
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
# Cross-implementation parity: the prompt-asset digest this builder binds into
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
    Write-Host "preflight: $PreflightTarget with zero models" -ForegroundColor Cyan
    $preflightSandbox = New-CohortEntrySandbox -Name 'preflight'
    try {
        $realToolkit = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $preflightFixture = New-CohortEntryFixture -Sandbox $preflightSandbox -RealToolkitRoot $realToolkit
        $preflightResult = New-ReviewerCohortEntryEvidence -RequestPath $preflightFixture.RequestPath
        $preparationRoot = ($preflightResult.Root.TrimEnd('\', '/') + '.preparation')
        $reached = Invoke-ReviewerCohortEntryPreflight `
            -Request (Read-ReviewerCohortEntryRequest -Path $preflightFixture.RequestPath) `
            -CoordinatorRequestPath (Join-Path $preflightResult.Root 'entry/coordinator-request.json') `
            -PreparationOutputRoot $preparationRoot -Target $PreflightTarget
        Assert-CohortEntry -Name "the typed preflight reaches $PreflightTarget" -Condition ($reached -ceq $PreflightTarget)
        $preflightIntents = @(Get-ChildItem -LiteralPath (Join-Path $preparationRoot 'coordinator/intents') -File -Force -Filter '*.intent.json' -ErrorAction SilentlyContinue)
        $preflightSlotIntents = @($preflightIntents | Where-Object {
                $intent = [IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json -Depth 16
                [string]$intent.slotName -or [string]$intent.setId -or [string]$intent.expectedTerminalPath
            })
        Assert-CohortEntry -Name 'the preflight launched no slot' -Condition ($preflightSlotIntents.Count -eq 0)
        Assert-CohortEntry -Name 'the preflight launched only read-only preparation children' `
            -Condition (@($preflightIntents | Where-Object { [string]$_.Name -notmatch 'stagePreparation|corpusSealValidate|snapshotValidate' }).Count -eq 0)
        Assert-CohortEntry -Name 'the preflight started no model' -Condition ($preflightResult.ModelStarts -eq 0)
        Assert-CohortEntry -Name 'the preflight wrote nothing to a provider' -Condition ($preflightResult.ProviderWrites -eq 0)
        Assert-CohortEntry -Name 'the preflight left the sealed package intact' `
            -Condition (Assert-ReviewerCohortEntryPublished -Root $preflightResult.Root -SealKeyPath $preflightFixture.SealKeyPath)
        Assert-CohortEntry -Name 'the preflight wrote outside the sealed package' `
            -Condition ((Test-Path -LiteralPath $preparationRoot -PathType Container) -and
                (-not (Test-ReviewerCohortEntryPathWithin -Candidate $preparationRoot -Root $preflightResult.Root)))

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
        $entryNode = [IO.File]::ReadAllText((Join-Path $preflightResult.Root 'entry/cohort-entry.json')) | ConvertFrom-Json -Depth 32
        $cohortDll = Join-Path $realToolkit 'tools/ShadowRunCoordinator/bin/Release/net10.0/ShadowRunCoordinator.dll'
        if (Test-Path -LiteralPath $cohortDll -PathType Leaf) {
            $manifestPath = Join-Path $preflightSandbox 'cohort-manifest.json'
            $manifest = [ordered]@{
                contractVersion = 'devpilot.shadow-cohort.manifest.v3'
                kind = 'shadow-cohort-run'
                cohortId = 'cohort-entry-evidence-acceptance'
                correlationId = [string]((([IO.File]::ReadAllText((Join-Path $preflightResult.Root 'entry/coordinator-request.json')) | ConvertFrom-Json -Depth 32)).correlationId)
                toolkit = [ordered]@{
                    repositoryRoot = $realToolkit
                    head = (& git -C $realToolkit rev-parse HEAD).Trim()
                    requiredRef = 'refs/heads/main'
                }
                execution = [ordered]@{
                    concurrency = 1
                    stopPolicy = 'failFast'
                    authorizationKind = 'PreviewOnly'
                    commandPath = 'dotnet'
                    argumentPrefix = [string[]]@($cohortDll)
                    target = 'runSetReady'
                    entryTimeoutSeconds = 120
                }
                budgets = [ordered]@{
                    maxPullRequests = 1
                    # Taken FROM the entry: the entry's plan estimate is what a
                    # real review of this subject would consume, and a manifest
                    # whose ceiling is below its own sealed estimates is refused
                    # before it starts. Nothing is consumed here - --rebuild-index
                    # starts nothing - but the ceiling still has to be coherent.
                    maxModelStarts = [int]$entryNode.planEstimate.modelStarts
                    maxVerifierAssignments = [int]$entryNode.planEstimate.verifierAssignments
                    maxWallClockSeconds = [int]$entryNode.planEstimate.wallClockSeconds
                    providerWriteBudget = 0
                }
                journal = [ordered]@{ root = (Join-Path $preflightSandbox 'cohort-journal') }
                audit = [ordered]@{ indexPath = (Join-Path $preflightSandbox 'cohort-index/index.json') }
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
            Assert-CohortEntry -Name 'the shipping cohort manifest reader accepts the published entry verbatim' `
                -Condition ($acceptance -match 'no cohort journal')
            Assert-CohortEntry -Name 'the shipping cohort reader refuses nothing about the entry itself' `
                -Condition ($acceptance -notmatch 'entry\s+\d+|entryId|ordinal|planEstimate|ruleBundle|subject')
        }
    }
    finally { if (-not $KeepSandbox) { Remove-CohortEntrySandbox -Path $preflightSandbox } else { Write-Host "sandbox kept: $preflightSandbox" } }
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
