#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deterministic proof that an offline CORPUS SEAL is a valid replay
    qualification snapshot: it drives the real qualification plan to the agent's
    own model-launch boundary.

.DESCRIPTION
    Two production capabilities were each proven on their own, but never
    together:

      * CorpusSeal.ps1 turns an immutable research corpus into a non-promotable
        offlineCorpusSeal snapshot (Test-CorpusReplaySeal.ps1 proves the loader
        accepts it and serves its payloads back byte-exact), and
      * ReplayQualification.ps1 launches a 2N all-or-none preflight that stops
        every slot at Start-ReviewerAgent.ps1's own model-launch boundary
        (Test-ReviewerReplayQualification.ps1 proves that with a snapshot built
        by Save-AgentReplaySnapshot.ps1).

    Nothing asserted that a snapshot MINTED BY THE CORPUS SEAL is accepted by
    the qualification PLAN and reaches that boundary. That is the composition a
    corpus-sampled pull request (e.g. one whose capture recorded no model
    output, only pinned content) must satisfy before any distinct-model blind
    discovery run may launch. This test seals a synthetic corpus with the
    toolkit-policy route, then qualifies that seal end to end.

    Offline and deterministic. No model launches, no host is contacted, no ADO
    write occurs, and every fixture is built in a sandbox this script owns and
    deletes. The seal is permanently non-promotable and the plan runs
    preview-only.

.EXAMPLE
    ./tools/Test-CorpusSealQualification.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot "src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
. (Join-Path $repoRoot "src\Agents\reviewer\SourceTransport.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\CorpusSeal.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\QualificationPreflight.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\ReplayQualification.ps1")

$script:checks = 0
$script:failures = 0
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Assert-Composition {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Condition)
    $script:checks++
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor DarkGreen }
    else { $script:failures++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

function Invoke-SandboxGit {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    # Hermetic: never let inherited hooks (init.templateDir / core.hooksPath) or
    # commit signing run an external process that would spoil determinism.
    $emptyHooks = Join-Path ([IO.Path]::GetTempPath()) "reviewer-empty-hooks-noop"
    New-Item -ItemType Directory -Force -Path $emptyHooks | Out-Null
    & git -C $Path -c "core.hooksPath=$emptyHooks" -c "commit.gpgsign=false" @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed in $Path." }
}

function Write-CorpusFile {
    param([string]$Root, [string]$Relative, [string]$Text)
    $full = $Root
    foreach ($segment in ($Relative -split '/')) { $full = Join-Path $full $segment }
    New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
    [System.IO.File]::WriteAllBytes($full, $utf8.GetBytes($Text))
    return $full
}

function Get-FileSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Synthetic corpus identity. The repository NAME is what the reviewer passes as
# repositoryId on its first bounded read, so the seal's pull-request get is
# keyed on the name (never the GUID) and carries no organization - exactly the
# request shape the qualification plan forces and then matches.
# ---------------------------------------------------------------------------
$org = "contoso"
$project = "widgets"
$repositoryName = "gadgets"
$repositoryId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
$pullRequestId = 5251
$iterationId = 1
$sourceCommit = "1111111111111111111111111111111111111111"
$commonCommit = "2222222222222222222222222222222222222222"
$targetCommit = "3333333333333333333333333333333333333333"

$alphaPath = "/src/alpha.txt"
$betaPath = "/src/beta.txt"
$deletedPath = "/src/gone.txt"
$alphaText = (1..40 | ForEach-Object { "alpha line $_" }) -join "`n"
$betaText = (1..24 | ForEach-Object { "beta line $_" }) -join "`n"

# Multiple change entries keep every serialized corpus array an array: a
# single-element PowerShell array round-trips through ConvertTo-Json as a bare
# object, which the sealer rejects.
$changeSet = [ordered]@{
    changeEntries = @(
        [ordered]@{ item = [ordered]@{ path = $alphaPath; isFolder = $false }; changeType = "edit" },
        [ordered]@{ item = [ordered]@{ path = $betaPath; isFolder = $false }; changeType = "add" },
        [ordered]@{ item = [ordered]@{ path = $deletedPath; isFolder = $false }; changeType = "delete" }
    )
}
$changeSetText = $changeSet | ConvertTo-Json -Depth 12
$changeSetSha = Get-ReviewerSourceChangeIdentityDigest -Response ($changeSetText | ConvertFrom-Json -Depth 12)

$spanEvidence = @(
    [ordered]@{
        path = $alphaPath
        hunks = @(
            [ordered]@{ oldStart = 3; oldCount = 4; newStart = 3; newCount = 4 },
            [ordered]@{ oldStart = 19; oldCount = 2; newStart = 20; newCount = 2 }
        )
    },
    [ordered]@{
        path = $betaPath
        hunks = @([ordered]@{ oldStart = 0; oldCount = 0; newStart = 1; newCount = 24 })
    },
    [ordered]@{
        path = $deletedPath
        hunks = @([ordered]@{ oldStart = 1; oldCount = 9; newStart = 0; newCount = 0 })
    }
)
$spanEvidenceText = ConvertTo-Json -InputObject $spanEvidence -Depth 12

$identityText = ([ordered]@{
        pullRequestId = $pullRequestId
        iterationId = $iterationId
        repositoryId = $repositoryId
        sourceCommit = $sourceCommit
        commonCommit = $commonCommit
        targetCommit = $targetCommit
        status = "active"
        isDraft = $false
    } | ConvertTo-Json -Depth 6)
$endIdentityText = ([ordered]@{
        pullRequestId = $pullRequestId
        iterationId = $iterationId
        sourceCommit = $sourceCommit
        targetCommit = $targetCommit
        status = "active"
        isDraft = $false
        matchesInitialCapture = $true
    } | ConvertTo-Json -Depth 6)

$prGetText = ([ordered]@{ pullRequestId = $pullRequestId; title = "synthetic"; status = "active" } | ConvertTo-Json -Depth 6)
$threadsText = ([ordered]@{ value = @(); count = 0 } | ConvertTo-Json -Depth 6)
$siblingText = "sibling evidence"
$rulesText = ([ordered]@{ rules = @("no bare catch") } | ConvertTo-Json -Depth 6)
$threadEvidenceText = ([ordered]@{ threads = @() } | ConvertTo-Json -Depth 6)
$factsText = ([ordered]@{ facts = @("alpha is edited") } | ConvertTo-Json -Depth 6)

$policyBytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "src\Agents\reviewer\source\v1\policy.json"))
$policyText = $utf8.GetString($policyBytes)
$policySha = (Get-ReviewerCorpusSealSha256 -Bytes ($utf8.GetBytes($policyText)))

$corpusFiles = [ordered]@{
    "identity.json" = $identityText
    "end-identity.json" = $endIdentityText
    "changes-authoritative.json" = $changeSetText
    "exact-spans.json" = $spanEvidenceText
    "files/alpha.txt" = $alphaText
    "files/beta.txt" = $betaText
    "live/pr-get.json" = $prGetText
    "live/threads.json" = $threadsText
    "live/changes.json" = $changeSetText
    "evidence/sibling.txt" = $siblingText
    "evidence/rules.json" = $rulesText
    "evidence/threads.json" = $threadEvidenceText
    "evidence/facts.json" = $factsText
    "policy/source-v1.json" = $policyText
}

function New-SyntheticCorpus {
    param([Parameter(Mandatory)][string]$Root)
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $corpusFiles.Keys) {
        $text = [string]$corpusFiles[$relative]
        $null = Write-CorpusFile -Root $Root -Relative $relative -Text $text
        $bytes = $utf8.GetBytes($text)
        [void]$entries.Add([ordered]@{
                path = $relative
                sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
                length = $bytes.Length
            })
    }
    $identities = [ordered]@{}
    $identities["$pullRequestId"] = [ordered]@{
        pullRequestId = $pullRequestId
        iteration = $iterationId
        source = $sourceCommit
        common = $commonCommit
        target = $targetCommit
        status = "active"
        isDraft = $false
    }
    $index = [ordered]@{
        kind = "private-immutable-non-promotable-research-corpus"
        repository = "$org/$project/$repositoryName"
        payloadCount = $entries.Count
        identities = $identities
        payloads = @($entries.ToArray())
    }
    $indexPath = Join-Path $Root "corpus-index.json"
    [System.IO.File]::WriteAllBytes($indexPath, $utf8.GetBytes(($index | ConvertTo-Json -Depth 12)))
    return (Get-FileSha -Path $indexPath)
}

function New-BoundDeclaration {
    param([string]$Relative, [string]$Text)
    $bytes = $utf8.GetBytes($Text)
    return [ordered]@{
        corpusPath = $Relative
        sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
        byteLength = $bytes.Length
    }
}

function New-SealRecipe {
    param([Parameter(Mandatory)][string]$IndexSha256, [Parameter(Mandatory)][int]$PayloadCount)
    return [ordered]@{
        schemaVersion = 1
        kind = "reviewer-offline-corpus-seal-recipe"
        snapshotId = "pr$pullRequestId-i1-offlinecorpusseal"
        provider = "azuredevops"
        capturedUtc = "20260101T000000Z"
        nonPromotable = $true
        sealKind = "offlineCorpusSeal"
        corpus = [ordered]@{ indexSha256 = $IndexSha256; payloadCount = $PayloadCount }
        binding = [ordered]@{
            organization = $org
            project = $project
            repositoryId = $repositoryId
            repositoryName = $repositoryName
            pullRequestId = $pullRequestId
            iterationId = $iterationId
            sourceCommit = $sourceCommit
            commonCommit = $commonCommit
            targetCommit = $targetCommit
            changeSetSha256 = $changeSetSha
        }
        capture = [ordered]@{
            identity = (New-BoundDeclaration -Relative "identity.json" -Text $identityText)
            endIdentity = (New-BoundDeclaration -Relative "end-identity.json" -Text $endIdentityText)
            statusAtCapture = "active"
            isDraft = $false
            mode = "offlineCorpusCapture"
            livePostReadRaceCheck = "notPerformed"
        }
        bindings = [ordered]@{
            configSha256 = ("a" * 64)
            scriptSha256 = ("b" * 64)
            promptSha256 = ("c" * 64)
            models = @("model-one", "model-two")
        }
        hashes = [ordered]@{
            policySha256 = $policySha
            configSha256 = ("a" * 64)
            scriptSha256 = ("b" * 64)
            schemaSha256 = ("d" * 64)
            promptSha256 = ("c" * 64)
        }
        changeSet = [ordered]@{
            authoritative = (New-BoundDeclaration -Relative "changes-authoritative.json" -Text $changeSetText)
            spanEvidence = (New-BoundDeclaration -Relative "exact-spans.json" -Text $spanEvidenceText)
            digestOrder = @($alphaPath, $betaPath, $deletedPath)
        }
        changedFiles = @(
            [ordered]@{
                path = $alphaPath
                changeKinds = @("edit")
                rightHand = (New-BoundDeclaration -Relative "files/alpha.txt" -Text $alphaText)
                spans = @([ordered]@{ start = 3; count = 4 }, [ordered]@{ start = 20; count = 2 })
            },
            [ordered]@{
                path = $betaPath
                changeKinds = @("add")
                rightHand = (New-BoundDeclaration -Relative "files/beta.txt" -Text $betaText)
                spans = @([ordered]@{ start = 1; count = 24 })
            }
        )
        sourceCensus = [ordered]@{
            authoritativeChangedPathCount = 3
            rightHandCoveredPathCount = 2
            noRightHandPaths = @($deletedPath)
        }
        evidence = [ordered]@{
            siblings = @((New-BoundDeclaration -Relative "evidence/sibling.txt" -Text $siblingText))
            rules = @((New-BoundDeclaration -Relative "evidence/rules.json" -Text $rulesText))
            threads = @((New-BoundDeclaration -Relative "evidence/threads.json" -Text $threadEvidenceText))
            facts = @((New-BoundDeclaration -Relative "evidence/facts.json" -Text $factsText))
        }
        sourceTransport = [ordered]@{
            kind = "derivedFromCorpus"
            mode = "mcpFlat"
            artifactFile = "source-transport.json"
            policy = [pscustomobject][ordered]@{
                toolkitPath = "src/Agents/reviewer/source/v1/policy.json"
                sha256 = $policySha
                byteLength = $policyBytes.Length
            }
            blockNonce = "SEALNONCE0001"
            capturedArtifact = $null
            expected = [ordered]@{
                artifactSha256 = ("0" * 64)
                artifactByteLength = 2
                blockSha256 = ("0" * 64)
                coverageRecordSha256 = ("0" * 64)
                gateOk = $true
                gateReasonCodes = @()
            }
        }
        resources = @(
            [ordered]@{
                tool = "repo_pull_request"
                arguments = [ordered]@{ action = "get"; project = $project; repositoryId = $repositoryName; pullRequestId = $pullRequestId }
                envelope = "mcpTextContent"
                payloadFile = "payloads/pr-get.json"
                corpusPayload = (New-BoundDeclaration -Relative "live/pr-get.json" -Text $prGetText)
                resourceUri = ""
                mimeType = ""
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = "repo_pull_request"
                arguments = [ordered]@{ action = "get_changes"; project = $project; repositoryId = $repositoryName; pullRequestId = $pullRequestId; iterationId = $iterationId; top = 1000 }
                envelope = "mcpTextContent"
                payloadFile = "payloads/changes.json"
                corpusPayload = (New-BoundDeclaration -Relative "live/changes.json" -Text $changeSetText)
                resourceUri = ""
                mimeType = ""
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = "repo_pull_request_thread"
                arguments = [ordered]@{ action = "list"; project = $project; repositoryId = $repositoryName; pullRequestId = $pullRequestId; top = 200 }
                envelope = "mcpTextContent"
                payloadFile = "payloads/threads.json"
                corpusPayload = (New-BoundDeclaration -Relative "live/threads.json" -Text $threadsText)
                resourceUri = ""
                mimeType = ""
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = "repo_file"
                arguments = [ordered]@{ action = "get_content"; project = $project; version = $sourceCommit; versionType = "Commit"; repositoryId = $repositoryId; path = $alphaPath }
                envelope = "mcpResourceContent"
                payloadFile = "payloads/alpha.json"
                corpusPayload = (New-BoundDeclaration -Relative "files/alpha.txt" -Text $alphaText)
                resourceUri = "ado://$org/$project/$repositoryId$alphaPath"
                mimeType = "text/plain"
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = "repo_file"
                arguments = [ordered]@{ action = "get_content"; project = $project; version = $sourceCommit; versionType = "Commit"; repositoryId = $repositoryId; path = $betaPath }
                envelope = "mcpTextContent"
                payloadFile = "payloads/beta.json"
                corpusPayload = (New-BoundDeclaration -Relative "files/beta.txt" -Text $betaText)
                resourceUri = ""
                mimeType = ""
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            }
        )
    }
}

function ConvertTo-RecipeObject {
    param([Parameter(Mandatory)]$Recipe)
    return (($Recipe | ConvertTo-Json -Depth 24) | ConvertFrom-Json -Depth 24)
}

function Resolve-ExpectedHashes {
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][hashtable]$Index)
    foreach ($resource in $Recipe.resources) {
        $payload = Get-ReviewerCorpusSealPayload -Index $Index -Path ([string]$resource.corpusPayload.corpusPath)
        $bytes = New-ReviewerCorpusSealEnvelope -Envelope ([string]$resource.envelope) -Payload $payload `
            -ResourceUri ([string]$resource.resourceUri) -MimeType ([string]$resource.mimeType)
        $resource.expected.payloadSha256 = Get-ReviewerCorpusSealSha256 -Bytes $bytes
        $resource.expected.payloadByteLength = $bytes.Length
    }
    return $Recipe
}

function Get-SealDerivedDigest {
    # Re-derive the transport artifact the way the seal does, using the SAME
    # production functions the sealer uses, so the fixture can declare the real
    # digests without copying any logic.
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][hashtable]$Index, [Parameter(Mandatory)][string]$Which)
    $policySource = ($utf8.GetString($policyBytes) | ConvertFrom-Json -Depth 24)
    $policyProperties = [ordered]@{}
    foreach ($property in $policySource.PSObject.Properties) {
        if ($property.Name -ceq "_note") { continue }
        $policyProperties[$property.Name] = $property.Value
    }
    $policy = New-ReviewerSourceTransportPolicy -Policy ([pscustomobject]$policyProperties)
    $spans = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $kinds = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $rightHand = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($file in $Recipe.changedFiles) {
        $path = [string]$file.path
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($span in $file.spans) {
            [void]$list.Add(@{ Start = [int]$span.start; End = [int]$span.start + [int]$span.count - 1 })
        }
        $spans[$path] = @($list.ToArray())
        $rightHand[$path] = Get-ReviewerCorpusSealPayload -Index $Index -Path ([string]$file.rightHand.corpusPath)
    }
    $authoritativeJson = ($utf8.GetString(
            (Get-ReviewerCorpusSealPayload -Index $Index -Path ([string]$Recipe.changeSet.authoritative.corpusPath)).Bytes) |
            ConvertFrom-Json -Depth 24)
    $authoritativeKinds = Get-ReviewerSourceChangeKindsByPath -Response $authoritativeJson
    $authoritativePaths = [string[]]@(Get-ReviewerSourceRawChangedPaths -Response $authoritativeJson |
            ForEach-Object { ConvertTo-ReviewerSourcePath -Path ([string]$_) })
    foreach ($path in $authoritativePaths) {
        if (-not $spans.Contains($path)) { $spans[$path] = @() }
        $kinds[$path] = [string[]]@(@($authoritativeKinds[$path]) | ForEach-Object { [string]$_ } |
                Sort-Object -CaseSensitive -Unique)
    }
    $reader = {
        param([string]$path)
        if (-not $rightHand.ContainsKey($path)) { return $null }
        $entry = $rightHand[$path]
        return [pscustomobject]@{
            Text = $utf8.GetString($entry.Bytes)
            ByteLength = [int]$entry.ByteLength
            Sha256 = [string]$entry.Sha256
            MimeType = "text/plain"
        }
    }.GetNewClosure()
    $report = New-ReviewerSourceTransportReport -CommitSha $sourceCommit `
        -ChangedPaths $authoritativePaths `
        -SpansByPath $spans -Policy $policy -Reader $reader -ChangeKindsByPath $kinds `
        -RecoveryBaseCommit $commonCommit -RecoveryIterationId $iterationId
    $nonce = [string]$Recipe.sourceTransport.blockNonce
    $blockText = Format-ReviewerSealedSourceBlock -Report $report -NonceFactory { $nonce }.GetNewClosure()
    switch ($Which) {
        "block" { return (Get-ReviewerSourceSha256 -Text $blockText) }
        "coverage" {
            $record = ConvertTo-ReviewerSourceCoverageRecord -Report $report -PolicySha256 $policySha
            return (Get-ReviewerSourceSha256 -Text (ConvertTo-AgentReplayCanonicalJson -Value $record))
        }
        "reasons" {
            $gate = Test-ReviewerSourceCoverageGate -Report $report -Policy $policy
            return [string[]]@($gate.ReasonCodes)
        }
    }
    throw "Unknown derived digest '$Which'."
}

function Resolve-ExpectedSourceTransport {
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][hashtable]$Index)
    $probe = $null
    try {
        $null = New-ReviewerCorpusSealPlan -Index $Index -Recipe (ConvertTo-RecipeObject -Recipe $Recipe) -ToolkitRoot $repoRoot
    }
    catch { $probe = [string]$_.Exception.Message }
    if (-not $probe) { throw "Expected the placeholder source-transport expectations to be refused." }
    if ($probe -notmatch 'sealed source-transport artifact is ([0-9a-f]{64})/(\d+)') {
        throw "Could not learn the sealed source-transport digest from: $probe"
    }
    $Recipe.sourceTransport.expected.artifactSha256 = $Matches[1]
    $Recipe.sourceTransport.expected.artifactByteLength = [int]$Matches[2]
    foreach ($attempt in 1..8) {
        $message = $null
        try {
            $null = New-ReviewerCorpusSealPlan -Index $Index -Recipe (ConvertTo-RecipeObject -Recipe $Recipe) -ToolkitRoot $repoRoot
            return $Recipe
        }
        catch { $message = [string]$_.Exception.Message }
        if ($message -match 'does not hash to the recipe''s declared blockSha256') {
            $Recipe.sourceTransport.expected.blockSha256 = (Get-SealDerivedDigest -Recipe $Recipe -Index $Index -Which "block")
        }
        elseif ($message -match 'does not hash to the recipe''s declared coverageRecordSha256') {
            $Recipe.sourceTransport.expected.coverageRecordSha256 = (Get-SealDerivedDigest -Recipe $Recipe -Index $Index -Which "coverage")
        }
        elseif ($message -match 'gate says ok=(True|False)') {
            $Recipe.sourceTransport.expected.gateOk = ($Matches[1] -ceq "True")
        }
        elseif ($message -match 'gate reason codes differ') {
            $Recipe.sourceTransport.expected.gateReasonCodes = (Get-SealDerivedDigest -Recipe $Recipe -Index $Index -Which "reasons")
        }
        else { throw "Unexpected refusal while resolving source-transport expectations: $message" }
    }
    throw "Could not converge on the source-transport expectations."
}

Write-Host "Corpus seal -> replay qualification composition" -ForegroundColor Cyan
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("corpus-seal-qual-" + [Guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
try {
    # -- 1. Seal a synthetic corpus with the toolkit-policy route -------------
    Write-Host "1/3 seal a synthetic corpus" -ForegroundColor Cyan
    $corpusRoot = Join-Path $sandbox "corpus"
    $indexSha = New-SyntheticCorpus -Root $corpusRoot
    $index = Import-ReviewerCorpusIndex -CorpusRoot $corpusRoot -ExpectedIndexSha256 $indexSha
    $recipe = New-SealRecipe -IndexSha256 $indexSha -PayloadCount $index.PayloadCount
    $recipe = Resolve-ExpectedHashes -Recipe $recipe -Index $index
    $recipe = Resolve-ExpectedSourceTransport -Recipe $recipe -Index $index

    $replayRoot = Join-Path $sandbox "replay-root"
    $plan = New-ReviewerCorpusSealPlan -Index $index -Recipe (ConvertTo-RecipeObject -Recipe $recipe) -ToolkitRoot $repoRoot
    $seal = Save-ReviewerCorpusSeal -Plan $plan -ReplayRoot $replayRoot
    $snapshotName = [string]$recipe.snapshotId
    $manifestDigest = [string]$seal.ManifestDigest
    Assert-Composition -Name "the seal is a non-promotable offlineCorpusSeal" `
        -Condition ([bool]$seal.NonPromotable -and $seal.SealKind -ceq "offlineCorpusSeal" -and $seal.SchemaVersion -eq 2)

    $sidecar = (Get-Content -LiteralPath (Join-Path $seal.SnapshotPath "offline-corpus-seal.json") -Raw) | ConvertFrom-Json -Depth 24
    Assert-Composition -Name "the seal never contacted a live host" `
        -Condition ([int]$sidecar.liveSeamCount -eq 0 -and -not [bool]$sidecar.liveHostContacted -and
        [string]$sidecar.livePostReadRaceCheck -ceq "notPerformed")
    Assert-Composition -Name "the seal recorded the toolkit-policy provenance" `
        -Condition ([string]$sidecar.sourceTransport.policyProvenance -ceq "toolkitSealTime")

    # The production qualification loader accepts the seal and binds its identity.
    $loaded = New-AgentReplaySnapshot -ReplayRoot $replayRoot -SnapshotName $snapshotName -ExpectedManifestDigest $manifestDigest
    Assert-Composition -Name "the qualification loader binds the seal as non-promotable" `
        -Condition ([bool]$loaded.Classification.NonPromotable -and
        [string]$loaded.Classification.SealKind -ceq "offlineCorpusSeal" -and
        [int]$loaded.Binding.PullRequestId -eq $pullRequestId)

    # -- 2. Sandbox: a clean reviewer build, a reviewed repo, a config --------
    Write-Host "2/3 sandbox reviewer build + config" -ForegroundColor Cyan
    $toolkitCopy = Join-Path $sandbox "toolkit"
    New-Item -ItemType Directory -Force -Path $toolkitCopy | Out-Null
    Copy-Item -Recurse -Force (Join-Path $repoRoot "src") (Join-Path $toolkitCopy "src")
    Copy-Item -Recurse -Force (Join-Path $repoRoot "tools") (Join-Path $toolkitCopy "tools")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("init", "--quiet")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("config", "user.name", "Composition Test")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("config", "user.email", "composition@example.invalid")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("add", "--all")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("commit", "--quiet", "-m", "reviewer build under composition qualification")
    $head = (& git -C $toolkitCopy rev-parse HEAD).Trim()
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("branch", "reviewer-layer", $head)
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("checkout", "--quiet", "-b", "generated-app-worktree")
    $sandboxReviewerScript = Join-Path $toolkitCopy "src\Agents\reviewer\Start-ReviewerAgent.ps1"

    $reviewedRepo = Join-Path $sandbox "reviewed-repo"
    New-Item -ItemType Directory -Force -Path $reviewedRepo | Out-Null
    $qualificationRoot = Join-Path $sandbox "qualification-root"

    $pair = Get-AgentGeneralistModelPair
    $config = Get-Content -LiteralPath (Join-Path $repoRoot "samples\reviewer-ado.config.json") -Raw | ConvertFrom-Json
    $config.repository.organization = $org
    $config.repository.project = $project
    $config.repository.name = $repositoryName
    $config.repository.id = $repositoryId
    $config.review.conventionSpecialistModel = "claude-sonnet-5"
    $config.review.verification.enabled = $true
    $config.review.verification.conventionVerifierModel = $pair.Second
    $configPath = Join-Path $sandbox "qualification.config.json"
    Set-Content -LiteralPath $configPath -Value (ConvertTo-Json -InputObject $config -Depth 20) -Encoding utf8NoBOM

    # -- 3. The corpus seal qualifies to the model-launch boundary -----------
    Write-Host "3/3 drive the seal through the qualification plan" -ForegroundColor Cyan
    $qualPlan = New-ReviewerReplayQualificationPlan `
        -RepoPath $reviewedRepo -ConfigFile $configPath -OperatorAlias "example-operator" `
        -PullRequestId $pullRequestId -ReplayRoot $replayRoot -ReplaySnapshotName $snapshotName `
        -ReplayManifestDigest $manifestDigest -QualificationRoot $qualificationRoot `
        -ReviewerScriptPath $sandboxReviewerScript -ExpectedCommit $head -RequiredRef "refs/heads/reviewer-layer"

    Assert-Composition -Name "the plan is a two-slot, non-promotable, preview-only plan" `
        -Condition (@($qualPlan.Slots).Count -eq 2 -and -not $qualPlan.Promotable -and $qualPlan.DeliveryMode -ceq "previewOnly")
    Assert-Composition -Name "the plan bound the corpus seal it was given" `
        -Condition ($qualPlan.Snapshot.ManifestDigest -ceq $manifestDigest.ToLowerInvariant() -and
        [int]$qualPlan.Snapshot.PullRequestId -eq $pullRequestId -and $qualPlan.Snapshot.SealKind -ceq "offlineCorpusSeal" -and
        [bool]$qualPlan.Snapshot.NonPromotable)
    Assert-Composition -Name "the plan selected exactly the blind distinct generalist pairing" `
        -Condition ($qualPlan.Models.First -ceq $pair.First -and $qualPlan.Models.Second -ceq $pair.Second -and
        $pair.First -cmatch '^claude-opus-' -and $pair.Second -cmatch '^gpt-')

    $evidence = Assert-ReviewerReplayQualificationPlan -Plan $qualPlan
    Assert-Composition -Name "both slots reached the agent's own model-launch boundary" `
        -Condition (@($evidence).Count -eq 2)
    foreach ($item in @($evidence)) {
        Assert-Composition -Name "$($item.Slot): stopped at the prelaunch seam" `
            -Condition ($item.Seam -ceq "reviewer.qualification-prelaunch.v1")
        Assert-Composition -Name "$($item.Slot): bound the corpus seal inside the agent as non-promotable" `
            -Condition ($item.SnapshotId -ceq $snapshotName -and
            $item.SnapshotManifestDigest -ceq $manifestDigest.ToLowerInvariant() -and
            [int]$item.PullRequestId -eq $pullRequestId -and [bool]$item.NonPromotable)
        Assert-Composition -Name "$($item.Slot): resolved the blind distinct generalist pairing" `
            -Condition ($item.Model -ceq $pair.First -and $item.SecondPassModel -ceq $pair.Second)
        Assert-Composition -Name "$($item.Slot): opened with the sealed bounded direct get keyed on the repository name" `
            -Condition ($item.SourceProbeTool -ceq "repo_pull_request" -and $item.SourceProbeAction -ceq "get" -and
            $item.SourceProbeRepositoryId -ceq $repositoryName -and [int]$item.SourceProbePullRequestId -eq $pullRequestId)
        Assert-Composition -Name "$($item.Slot): the run's first read is a request the seal records" `
            -Condition ([bool](@($loaded.ServedKeys) -ccontains [string]$item.SourceProbeRequestSha256))
        Assert-Composition -Name "$($item.Slot): resolved preview-only delivery authorization" `
            -Condition ($item.DeliveryAuthorization -ceq "PreviewOnly")
        Assert-Composition -Name "$($item.Slot): left no state behind" `
            -Condition (-not $item.StateDirExists -and -not (Test-Path -LiteralPath $item.StateDir))
    }
    Assert-Composition -Name "qualifying the seal created no qualification state" `
        -Condition (-not (Test-Path -LiteralPath $qualificationRoot))
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "FAILED: $script:failures of $script:checks checks failed." -ForegroundColor Red
    exit 1
}
Write-Host "OK: all $script:checks checks passed." -ForegroundColor Green
