#!/usr/bin/env pwsh
<#
    Deterministic tests for the offline corpus seal.

    Everything here runs against a SYNTHETIC corpus this script builds in a
    sandbox: the tests must prove the tool's behaviour, not the contents of any
    particular private capture, and they must be runnable by anyone.

    Two things are proven:

      1. parity  - sealing the same recipe over the same corpus twice produces
                   byte-identical output, and the production replay loader serves
                   the sealed payloads back unchanged;
      2. refusal - every way a corpus or a recipe can be wrong is refused BEFORE
                   anything is written.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot "src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
. (Join-Path $repoRoot "src\Agents\reviewer\SourceTransport.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\CorpusSeal.ps1")

$script:checks = 0
$script:failures = 0
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Assert-Seal {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Condition)
    $script:checks++
    if ($Condition) { Write-Host "  PASS  $Name" -ForegroundColor DarkGreen }
    else { $script:failures++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

function Assert-SealThrows {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script,
        [Parameter(Mandatory)][string]$Match
    )
    $script:checks++
    try {
        & $Script | Out-Null
        $script:failures++
        Write-Host "  FAIL  $Name (no refusal)" -ForegroundColor Red
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match $Match) { Write-Host "  PASS  $Name" -ForegroundColor DarkGreen }
        else {
            $script:failures++
            Write-Host "  FAIL  $Name (refused with: $message)" -ForegroundColor Red
        }
    }
}

function New-SealSandbox {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("corpus-seal-" + [Guid]::NewGuid().ToString("N").Substring(0, 12))
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Write-CorpusFile {
    param([string]$Root, [string]$Relative, [string]$Text)
    $full = $Root
    foreach ($segment in ($Relative -split '/')) { $full = Join-Path $full $segment }
    New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent) | Out-Null
    [System.IO.File]::WriteAllBytes($full, ([System.Text.UTF8Encoding]::new($false, $true)).GetBytes($Text))
    return $full
}

function Get-FileSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Synthetic corpus
# ---------------------------------------------------------------------------
$org = "contoso"
$project = "widgets"
$repositoryName = "gadgets"
$repositoryId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
$pullRequestId = 4242
$iterationId = 1
$sourceCommit = "1111111111111111111111111111111111111111"
$commonCommit = "2222222222222222222222222222222222222222"
$targetCommit = "3333333333333333333333333333333333333333"
$otherPullRequestId = 4343

$alphaPath = "/src/alpha.txt"
$betaPath = "/src/beta.txt"
$deletedPath = "/src/gone.txt"

$alphaText = (1..40 | ForEach-Object { "alpha line $_" }) -join "`n"
$betaText = (1..24 | ForEach-Object { "beta line $_" }) -join "`n"

$changeSet = [ordered]@{
    changeEntries = @(
        [ordered]@{ item = [ordered]@{ path = $alphaPath; isFolder = $false }; changeType = "edit" },
        [ordered]@{ item = [ordered]@{ path = $betaPath; isFolder = $false }; changeType = "add" },
        [ordered]@{ item = [ordered]@{ path = $deletedPath; isFolder = $false }; changeType = "delete" }
    )
}
$changeSetText = $changeSet | ConvertTo-Json -Depth 12
$changeSetSha = Get-ReviewerSourceChangeIdentityDigest -Response ($changeSetText | ConvertFrom-Json -Depth 12)

# The captured hunk census the seal DERIVES right-hand spans from. The recipe
# restates the same spans, but the recipe is never the source: a recipe that
# could name its own spans could seal one file's bytes and address another's
# lines, and every hash in the snapshot would still agree with itself.
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
        # A pure deletion: right-hand count zero, so it contributes no span at all.
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
# The END of capture. It is what proves the pull request did not move WHILE it
# was being read, so every field it carries that the binding can be checked
# against is checked - not only the pull request id.
$endIdentityText = ([ordered]@{
        pullRequestId = $pullRequestId
        iterationId = $iterationId
        sourceCommit = $sourceCommit
        targetCommit = $targetCommit
        status = "active"
        isDraft = $false
        matchesInitialCapture = $true
    } | ConvertTo-Json -Depth 6)
$otherIdentityText = ([ordered]@{
        pullRequestId = $otherPullRequestId
        iterationId = $iterationId
        repositoryId = $repositoryId
        sourceCommit = $sourceCommit
        commonCommit = $commonCommit
        targetCommit = $targetCommit
        status = "active"
        isDraft = $false
    } | ConvertTo-Json -Depth 6)

$prGetText = ([ordered]@{ pullRequestId = $pullRequestId; title = "synthetic"; status = "active" } | ConvertTo-Json -Depth 6)
$threadsText = ([ordered]@{ value = @(); count = 0 } | ConvertTo-Json -Depth 6)
$siblingText = "sibling evidence"
$rulesText = ([ordered]@{ rules = @("no bare catch") } | ConvertTo-Json -Depth 6)
$threadEvidenceText = ([ordered]@{ threads = @() } | ConvertTo-Json -Depth 6)
$factsText = ([ordered]@{ facts = @("alpha is edited") } | ConvertTo-Json -Depth 6)

$policyBytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "src\Agents\reviewer\source\v1\policy.json"))
# The policy is a CORPUS payload, not a toolkit file. The production sealer will
# not read one from the working tree at all: bytes the index does not pin cannot
# be part of a deterministic seal, because the same recipe and the same corpus
# would then produce different snapshots on different checkouts.
$policyText = $utf8.GetString($policyBytes)
$policySha = (Get-ReviewerCorpusSealSha256 -Bytes ($utf8.GetBytes($policyText)))

$corpusFiles = [ordered]@{
    "identity.json" = $identityText
    "end-identity.json" = $endIdentityText
    "other-identity.json" = $otherIdentityText
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
    "unindexed-extra.json" = '{"stray":true}'
}

function New-SyntheticCorpus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$OtherIdentity,
        [string]$Repository = "$org/$project/$repositoryName",
        [hashtable]$Overrides = @{}
    )
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $corpusFiles.Keys) {
        $text = if ($Overrides.ContainsKey($relative)) { [string]$Overrides[$relative] } else { [string]$corpusFiles[$relative] }
        $null = Write-CorpusFile -Root $Root -Relative $relative -Text $text
        # 'unindexed-extra.json' exists on disk but is deliberately never indexed,
        # so a recipe that names it exercises the extra-payload refusal.
        if ($relative -ceq "unindexed-extra.json") { continue }
        $bytes = ([System.Text.UTF8Encoding]::new($false, $true)).GetBytes($text)
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
    if ($OtherIdentity) {
        $identities["$pullRequestId"].source = "9999999999999999999999999999999999999999"
    }
    $index = [ordered]@{
        kind = "private-immutable-non-promotable-research-corpus"
        repository = $Repository
        payloadCount = $entries.Count
        identities = $identities
        payloads = @($entries.ToArray())
    }
    $indexPath = Join-Path $Root "corpus-index.json"
    [System.IO.File]::WriteAllBytes($indexPath,
        ([System.Text.UTF8Encoding]::new($false, $true)).GetBytes(($index | ConvertTo-Json -Depth 12)))
    return (Get-FileSha -Path $indexPath)
}

function New-BoundDeclaration {
    param([string]$Relative, [string]$Text)
    $bytes = ([System.Text.UTF8Encoding]::new($false, $true)).GetBytes($Text)
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
            policy = (New-BoundDeclaration -Relative "policy/source-v1.json" -Text $policyText)
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
                arguments = [ordered]@{ action = "get"; organization = $org; project = $project; repositoryId = $repositoryId; pullRequestId = $pullRequestId }
                envelope = "jsonRpcResult"
                payloadFile = "payloads/pr-get.json"
                corpusPayload = (New-BoundDeclaration -Relative "live/pr-get.json" -Text $prGetText)
                resourceUri = ""
                mimeType = ""
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = "repo_pull_request"
                arguments = [ordered]@{ action = "get_changes"; organization = $org; project = $project; repositoryId = $repositoryId; pullRequestId = $pullRequestId; iterationId = $iterationId }
                envelope = "jsonRpcResult"
                payloadFile = "payloads/changes.json"
                corpusPayload = (New-BoundDeclaration -Relative "live/changes.json" -Text $changeSetText)
                resourceUri = ""
                mimeType = ""
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = "repo_pull_request_thread"
                arguments = [ordered]@{ action = "list"; organization = $org; project = $project; repositoryId = $repositoryId; pullRequestId = $pullRequestId }
                envelope = "jsonRpcResult"
                payloadFile = "payloads/threads.json"
                corpusPayload = (New-BoundDeclaration -Relative "live/threads.json" -Text $threadsText)
                resourceUri = ""
                mimeType = ""
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = "repo_file"
                arguments = [ordered]@{ action = "get_content"; organization = $org; project = $project; repositoryId = $repositoryId; path = $alphaPath; version = $sourceCommit; versionType = "Commit" }
                envelope = "mcpResourceContent"
                payloadFile = "payloads/alpha.json"
                corpusPayload = (New-BoundDeclaration -Relative "files/alpha.txt" -Text $alphaText)
                resourceUri = "ado://$org/$project/$repositoryId$alphaPath"
                mimeType = "text/plain"
                expected = [ordered]@{ payloadSha256 = ("0" * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = "repo_file"
                arguments = [ordered]@{ action = "get_content"; organization = $org; project = $project; repositoryId = $repositoryId; path = $betaPath; version = $sourceCommit; versionType = "Commit" }
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

function Save-Recipe {
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][string]$Path)
    [System.IO.File]::WriteAllBytes($Path,
        ([System.Text.UTF8Encoding]::new($false, $true)).GetBytes(($Recipe | ConvertTo-Json -Depth 24)))
    return $Path
}

function Resolve-ExpectedHashes {
    <#
        Fills the recipe's independently declared expectations by asking the tool
        what the corpus actually produces. Tests are allowed to do this; a recipe
        author is not, which is precisely why the seal refuses when they disagree.
    #>
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

function Resolve-ExpectedSourceTransport {
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][hashtable]$Index, [Parameter(Mandatory)][string]$SandboxPath)
    # Round-trip through the tool once with placeholder expectations to learn the
    # real digests, then rewrite the recipe with them.
    $probe = $null
    try {
        $null = New-ReviewerCorpusSealPlan -Index $Index -Recipe (
            ($Recipe | ConvertTo-Json -Depth 24) | ConvertFrom-Json -Depth 24)
    }
    catch {
        $probe = [string]$_.Exception.Message
    }
    if (-not $probe) { throw "Expected the placeholder source-transport expectations to be refused." }
    if ($probe -notmatch 'sealed source-transport artifact is ([0-9a-f]{64})/(\d+)') {
        throw "Could not learn the sealed source-transport digest from: $probe"
    }
    $Recipe.sourceTransport.expected.artifactSha256 = $Matches[1]
    $Recipe.sourceTransport.expected.artifactByteLength = [int]$Matches[2]
    foreach ($attempt in 1..8) {
        $message = $null
        try {
            $null = New-ReviewerCorpusSealPlan -Index $Index -Recipe (
                ($Recipe | ConvertTo-Json -Depth 24) | ConvertFrom-Json -Depth 24)
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

function Get-SealDerivedDigest {
    <#
        Re-derives the transport artifact the same way the seal does, so the test
        fixture can state the real digests. This deliberately uses the production
        functions rather than a copy of their logic.
    #>
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][hashtable]$Index, [Parameter(Mandatory)][string]$Which)
    $policySource = ((([System.Text.UTF8Encoding]::new($false, $true)).GetString($policyBytes)) | ConvertFrom-Json -Depth 24)
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
    # Mirror production exactly: EVERY authoritative changed path is reported,
    # not only the ones carrying right-hand content, and the change kinds come
    # from the authoritative change set rather than from the recipe.
    $authoritativeJson = (([System.Text.UTF8Encoding]::new($false, $true)).GetString(
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
            Text = ([System.Text.UTF8Encoding]::new($false, $true)).GetString($entry.Bytes)
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

function ConvertTo-RecipeObject {
    param([Parameter(Mandatory)]$Recipe)
    return (($Recipe | ConvertTo-Json -Depth 24) | ConvertFrom-Json -Depth 24)
}

Write-Host "Offline corpus seal tests" -ForegroundColor Cyan
$sandbox = New-SealSandbox
try {
    $corpusRoot = Join-Path $sandbox "corpus"
    $indexSha = New-SyntheticCorpus -Root $corpusRoot
    $index = Import-ReviewerCorpusIndex -CorpusRoot $corpusRoot -ExpectedIndexSha256 $indexSha
    Assert-Seal -Name "corpus index opens with its exact digest" -Condition ($index.IndexSha256 -ceq $indexSha)

    $recipe = New-SealRecipe -IndexSha256 $indexSha -PayloadCount $index.PayloadCount
    $recipe = Resolve-ExpectedHashes -Recipe $recipe -Index $index
    $recipe = Resolve-ExpectedSourceTransport -Recipe $recipe -Index $index -SandboxPath $sandbox

    # -- seal / replay parity -------------------------------------------------
    $replayA = Join-Path $sandbox "replay-a"
    $replayB = Join-Path $sandbox "replay-b"
    $plan = New-ReviewerCorpusSealPlan -Index $index -Recipe (ConvertTo-RecipeObject -Recipe $recipe)
    $sealA = Save-ReviewerCorpusSeal -Plan $plan -ReplayRoot $replayA
    $planB = New-ReviewerCorpusSealPlan -Index $index -Recipe (ConvertTo-RecipeObject -Recipe $recipe)
    $sealB = Save-ReviewerCorpusSeal -Plan $planB -ReplayRoot $replayB

    Assert-Seal -Name "seal is deterministic (manifest digest)" -Condition ($sealA.ManifestDigest -ceq $sealB.ManifestDigest)
    Assert-Seal -Name "seal is deterministic (seal digest)" -Condition ($sealA.SealDigest -ceq $sealB.SealDigest)
    $filesA = @(Get-ChildItem -LiteralPath $sealA.SnapshotPath -Recurse -File | Sort-Object FullName)
    $filesB = @(Get-ChildItem -LiteralPath $sealB.SnapshotPath -Recurse -File | Sort-Object FullName)
    Assert-Seal -Name "seal writes the same file set twice" -Condition ($filesA.Count -eq $filesB.Count -and $filesA.Count -gt 0)
    $identical = $true
    for ($i = 0; $i -lt $filesA.Count; $i++) {
        if ((Get-FileSha -Path $filesA[$i].FullName) -cne (Get-FileSha -Path $filesB[$i].FullName)) { $identical = $false }
    }
    Assert-Seal -Name "every sealed byte is identical across seals" -Condition $identical
    Assert-Seal -Name "seal is schema v2" -Condition ($sealA.SchemaVersion -eq 2)
    Assert-Seal -Name "seal is non-promotable" -Condition ([bool]$sealA.NonPromotable -and $sealA.SealKind -ceq "offlineCorpusSeal")

    $sidecar = (Get-Content -LiteralPath (Join-Path $sealA.SnapshotPath "offline-corpus-seal.json") -Raw) | ConvertFrom-Json -Depth 24
    Assert-Seal -Name "sidecar records zero live seams" -Condition ([int]$sidecar.liveSeamCount -eq 0 -and -not [bool]$sidecar.liveHostContacted)
    Assert-Seal -Name "sidecar never claims a live post-read race check" `
        -Condition ([string]$sidecar.livePostReadRaceCheck -ceq "notPerformed")
    Assert-Seal -Name "sidecar has no promotion key domain" -Condition ($null -eq $sidecar.promotionKeyDomain)
    Assert-Seal -Name "sidecar records the full census" `
        -Condition ([int]$sidecar.census.authoritativeChangedPathCount -eq 3 -and [int]$sidecar.census.rightHandCoveredPathCount -eq 2)
    Assert-Seal -Name "sidecar records the policy provenance" `
        -Condition ([string]$sidecar.sourceTransport.policyProvenance -ceq "corpus")
    Assert-Seal -Name "sidecar names the indexed policy payload" `
        -Condition ([string]$sidecar.sourceTransport.policyReference -ceq "policy/source-v1.json")

    # -- the toolkit policy route, end to end --------------------------------
    # Same bytes, different origin. Everything the seal produces must be
    # identical EXCEPT the provenance it reports, because the artifact has to say
    # that these rules were chosen at seal time rather than recorded at capture.
    $toolkitSealRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $toolkitSealRecipe.snapshotId = "pr$pullRequestId-i1-offlinecorpusseal-toolkit"
    $toolkitSealRecipe.sourceTransport.policy = [pscustomobject][ordered]@{
        toolkitPath = "src/Agents/reviewer/source/v1/policy.json"
        sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $policyBytes)
        byteLength = $policyBytes.Length
    }
    $toolkitSealRecipe.hashes.policySha256 = (Get-ReviewerCorpusSealSha256 -Bytes $policyBytes)
    $replayToolkit = Join-Path $sandbox "replay-toolkit"
    New-Item -ItemType Directory -Force -Path $replayToolkit | Out-Null
    $toolkitPlanA = New-ReviewerCorpusSealPlan -Index $index -Recipe $toolkitSealRecipe -ToolkitRoot $repoRoot
    $toolkitSealA = Save-ReviewerCorpusSeal -Plan $toolkitPlanA -ReplayRoot $replayToolkit
    $replayToolkitB = Join-Path $sandbox "replay-toolkit-b"
    New-Item -ItemType Directory -Force -Path $replayToolkitB | Out-Null
    $toolkitPlanB = New-ReviewerCorpusSealPlan -Index $index -Recipe $toolkitSealRecipe -ToolkitRoot $repoRoot
    $toolkitSealB = Save-ReviewerCorpusSeal -Plan $toolkitPlanB -ReplayRoot $replayToolkitB
    Assert-Seal -Name "a toolkit-policy seal is deterministic" `
        -Condition ($toolkitSealA.ManifestDigest -ceq $toolkitSealB.ManifestDigest -and
        $toolkitSealA.SealDigest -ceq $toolkitSealB.SealDigest)
    $toolkitSidecar = (Get-Content -LiteralPath (Join-Path $toolkitSealA.SnapshotPath "offline-corpus-seal.json") -Raw) |
        ConvertFrom-Json -Depth 24
    Assert-Seal -Name "a toolkit-policy seal records provenance toolkitSealTime" `
        -Condition ([string]$toolkitSidecar.sourceTransport.policyProvenance -ceq "toolkitSealTime")
    Assert-Seal -Name "a toolkit-policy seal names the exact toolkit policy it read" `
        -Condition ([string]$toolkitSidecar.sourceTransport.policyReference -ceq "src/Agents/reviewer/source/v1/policy.json")
    Assert-Seal -Name "a toolkit-policy seal is still permanently non-promotable" `
        -Condition ([bool]$toolkitSidecar.nonPromotable -and [bool]$toolkitSealA.NonPromotable -and
        [string]$toolkitSidecar.livePostReadRaceCheck -ceq "notPerformed" -and [int]$toolkitSidecar.liveSeamCount -eq 0)
    Assert-Seal -Name "a toolkit-policy seal derives the same transport as the corpus policy" `
        -Condition ([string]$toolkitSidecar.sourceTransport.artifactSha256 -ceq [string]$sidecar.sourceTransport.artifactSha256)
    $toolkitLoaded = New-AgentReplaySnapshot -ReplayRoot $replayToolkit -SnapshotName $toolkitSealRecipe.snapshotId `
        -ExpectedManifestDigest $toolkitSealA.ManifestDigest
    Assert-Seal -Name "the production loader accepts a toolkit-policy seal as non-promotable" `
        -Condition ([bool]$toolkitLoaded.Classification.NonPromotable -and
        [string]$toolkitLoaded.Classification.SealKind -ceq "offlineCorpusSeal")

    # replay parity: the loader serves back exactly what was sealed
    $loaded = New-AgentReplaySnapshot -ReplayRoot $replayA -SnapshotName $recipe.snapshotId -ExpectedManifestDigest $sealA.ManifestDigest
    Assert-Seal -Name "the production loader accepts the seal" -Condition ($loaded.ResourceCount -eq @($recipe.resources).Count)
    $parity = $true
    foreach ($resource in $recipe.resources) {
        $response = Get-AgentReplayResponse -Snapshot $loaded -Name ([string]$resource.tool) `
            -Arguments (ConvertTo-RecipeObject -Recipe $resource).arguments
        $bytes = $utf8.GetBytes(($response | ConvertTo-Json -Depth 32 -Compress))
        if ($null -eq $response) { $parity = $false }
        if ((Get-ReviewerCorpusSealSha256 -Bytes $bytes).Length -ne 64) { $parity = $false }
    }
    Assert-Seal -Name "every sealed request replays" -Condition $parity

    $alphaResponse = Get-AgentReplayResponse -Snapshot $loaded -Name "repo_file" -Arguments (
        [pscustomobject][ordered]@{ action = "get_content"; organization = $org; project = $project
            repositoryId = $repositoryId; path = $alphaPath; version = $sourceCommit; versionType = "Commit"
        })
    $decoded = ConvertFrom-AgentMcpResourceContent -ToolResult $alphaResponse -MaxBytes 1048576 `
        -ExpectedUri "ado://$org/$project/$repositoryId$alphaPath"
    Assert-Seal -Name "replayed right-hand content is byte-exact" -Condition ([string]$decoded.Text -ceq $alphaText)

    # -- rejection classes ----------------------------------------------------
    Write-Host "Rejection classes" -ForegroundColor Cyan

    Assert-SealThrows -Name "wrong corpus index digest" -Match "does not match the expected" -Script {
        Import-ReviewerCorpusIndex -CorpusRoot $corpusRoot -ExpectedIndexSha256 ("f" * 64)
    }

    $tamperedRoot = Join-Path $sandbox "corpus-tampered"
    $null = New-SyntheticCorpus -Root $tamperedRoot
    # Re-index cleanly, then tamper the payload on disk so the index no longer describes it.
    $tamperedIndexSha = Get-FileSha -Path (Join-Path $tamperedRoot "corpus-index.json")
    $tamperedIndex = Import-ReviewerCorpusIndex -CorpusRoot $tamperedRoot -ExpectedIndexSha256 $tamperedIndexSha
    [System.IO.File]::WriteAllBytes((Join-Path $tamperedRoot "files\alpha.txt"), $utf8.GetBytes($alphaText + "`ntampered"))
    Assert-SealThrows -Name "tampered payload" -Match "does not match its indexed SHA-256|is \d+ bytes; the index records" -Script {
        Get-ReviewerCorpusSealPayload -Index $tamperedIndex -Path "files/alpha.txt"
    }

    $missingRoot = Join-Path $sandbox "corpus-missing"
    $null = New-SyntheticCorpus -Root $missingRoot
    $missingIndexSha = Get-FileSha -Path (Join-Path $missingRoot "corpus-index.json")
    $missingIndex = Import-ReviewerCorpusIndex -CorpusRoot $missingRoot -ExpectedIndexSha256 $missingIndexSha
    Remove-Item -LiteralPath (Join-Path $missingRoot "files\alpha.txt") -Force
    Assert-SealThrows -Name "missing payload" -Match "does not exist|Cannot find path" -Script {
        Get-ReviewerCorpusSealPayload -Index $missingIndex -Path "files/alpha.txt"
    }

    Assert-SealThrows -Name "extra unindexed payload" -Match "is not a member of the canonical corpus index" -Script {
        Get-ReviewerCorpusSealPayload -Index $index -Path "unindexed-extra.json"
    }

    foreach ($alias in @("files\alpha.txt", "./files/alpha.txt", "files//alpha.txt", "src/../files/alpha.txt", "/files/alpha.txt", "C:/files/alpha.txt")) {
        $captured = $alias
        Assert-SealThrows -Name "path aliasing refused: '$alias'" -Match "not a plain relative corpus path" -Script {
            Get-ReviewerCorpusSealPayload -Index $index -Path $captured
        }
    }

    $staleRoot = Join-Path $sandbox "corpus-stale"
    $staleIndexSha = New-SyntheticCorpus -Root $staleRoot -OtherIdentity
    $staleIndex = Import-ReviewerCorpusIndex -CorpusRoot $staleRoot -ExpectedIndexSha256 $staleIndexSha
    $staleRecipe = ConvertTo-RecipeObject -Recipe (New-SealRecipe -IndexSha256 $staleIndexSha -PayloadCount $staleIndex.PayloadCount)
    Assert-SealThrows -Name "stale identity" -Match "stale commit, a different iteration or another pull request" -Script {
        New-ReviewerCorpusSealPlan -Index $staleIndex -Recipe $staleRecipe
    }

    $crossRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $crossRecipe.binding.pullRequestId = $otherPullRequestId
    Assert-SealThrows -Name "cross-PR substitution (no captured identity)" -Match "carries no captured identity for pull request" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $crossRecipe
    }

    $swappedRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $swappedRecipe.capture.identity = (ConvertTo-RecipeObject -Recipe (New-BoundDeclaration -Relative "other-identity.json" -Text $otherIdentityText))
    Assert-SealThrows -Name "cross-PR substitution (foreign capture identity)" -Match "does not match the sealed binding" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $swappedRecipe
    }

    $censusRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $censusRecipe.sourceCensus.noRightHandPaths = @()
    $censusRecipe.sourceCensus.authoritativeChangedPathCount = 3
    Assert-SealThrows -Name "incomplete source census" -Match "source census is incomplete" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $censusRecipe
    }

    $countRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $countRecipe.sourceCensus.rightHandCoveredPathCount = 3
    Assert-SealThrows -Name "census count disagreement" -Match "census declares 3 covered path" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $countRecipe
    }

    $digestRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $digestRecipe.binding.changeSetSha256 = ("e" * 64)
    Assert-SealThrows -Name "wrong authoritative change-set digest" -Match "disagree about which files changed" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $digestRecipe
    }

    $orderRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $orderRecipe.changeSet.digestOrder = @($betaPath, $alphaPath, $deletedPath)
    Assert-SealThrows -Name "wrong change-set order" -Match "change-set order differs" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $orderRecipe
    }

    $shaRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $shaRecipe.resources[0].expected.payloadSha256 = ("1" * 64)
    Assert-SealThrows -Name "declared payload hash disagreement" -Match "does not describe what this corpus produces" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $shaRecipe
    }

    $lengthRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $lengthRecipe.resources[0].corpusPayload.byteLength = 7
    Assert-SealThrows -Name "declared corpus length disagreement" -Match "declares 7 byte" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $lengthRecipe
    }

    $dupRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $dupRecipe.resources[1].arguments = $dupRecipe.resources[0].arguments
    $dupRecipe.resources[1].payloadFile = "payloads/dup.json"
    Assert-SealThrows -Name "duplicate request" -Match "records the same 'repo_pull_request' request twice" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $dupRecipe
    }

    $dupFileRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $dupFileRecipe.resources[1].payloadFile = $dupFileRecipe.resources[0].payloadFile
    Assert-SealThrows -Name "duplicate payload file" -Match "writes two resources to" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $dupFileRecipe
    }

    $dupEvidenceRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $dupEvidenceRecipe.evidence.rules = @($dupEvidenceRecipe.evidence.siblings[0])
    Assert-SealThrows -Name "duplicate evidence resource" -Match "more than once" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $dupEvidenceRecipe
    }

    $writeRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $writeRecipe.resources[0].tool = "repo_pull_request"
    $writeRecipe.resources[0].arguments.action = "create"
    Assert-SealThrows -Name "write tool refused" -Match "a replay snapshot may only carry reads" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $writeRecipe
    }

    $promotableRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $promotableRecipe.nonPromotable = $false
    $promotablePath = Save-Recipe -Recipe $promotableRecipe -Path (Join-Path $sandbox "promotable.json")
    Assert-SealThrows -Name "promotable recipe refused" -Match "must declare nonPromotable = true" -Script {
        Import-ReviewerCorpusSealRecipe -Path $promotablePath
    }

    $namedRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $namedRecipe.snapshotId = "pr4242-i1-plain"
    Assert-SealThrows -Name "snapshot id must say offlinecorpusseal" -Match "must carry 'offlinecorpusseal'" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $namedRecipe
    }

    $raceRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $raceRecipe.capture.livePostReadRaceCheck = "performed"
    Assert-SealThrows -Name "claimed live race check refused" -Match "must record livePostReadRaceCheck = 'notPerformed'" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $raceRecipe
    }

    # Spans are DERIVED from indexed evidence; a recipe that restates them
    # differently is refused before anything about them is used.
    $spanRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $spanRecipe.changedFiles[0].spans = @(
        [pscustomobject]@{ start = 10; count = 5 },
        [pscustomobject]@{ start = 12; count = 2 }
    )
    Assert-SealThrows -Name "recipe spans that diverge from the evidence are refused" `
        -Match "authoritative span evidence derives" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $spanRecipe
    }

    $widenedRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $widenedRecipe.changedFiles[0].spans[0].count = 9
    Assert-SealThrows -Name "a widened span is refused even though it stays in order" `
        -Match "authoritative span evidence derives" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $widenedRecipe
    }

    $extraSpanRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $extraSpanRecipe.changedFiles[1].spans = @(
        [pscustomobject]@{ start = 1; count = 24 },
        [pscustomobject]@{ start = 40; count = 2 }
    )
    Assert-SealThrows -Name "an extra span the evidence does not derive is refused" `
        -Match "authoritative span evidence derives" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $extraSpanRecipe
    }

    $unknownFieldRecipe = ConvertTo-RecipeObject -Recipe $recipe
    Add-Member -InputObject $unknownFieldRecipe -MemberType NoteProperty -Name "extra" -Value 1
    $unknownPath = Save-Recipe -Recipe $unknownFieldRecipe -Path (Join-Path $sandbox "unknown.json")
    Assert-SealThrows -Name "unknown recipe field refused" -Match "carries unexpected field" -Script {
        Import-ReviewerCorpusSealRecipe -Path $unknownPath
    }

    # -- the toolkit policy alternative, fenced ------------------------------
    # Permitted, because a capture that recorded the transport's outputs but not
    # the policy document is the ordinary case and refusing it outright only makes
    # sealing impossible. Fenced, because a policy read from a working tree is a
    # weaker claim than one the capture recorded.
    $toolkitPolicyRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $toolkitPolicyRecipe.sourceTransport.policy = [pscustomobject][ordered]@{
        toolkitPath = "src/Agents/reviewer/source/v1/policy.json"
        sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $policyBytes)
        byteLength = $policyBytes.Length
    }
    $toolkitPolicyRecipe.hashes.policySha256 = (Get-ReviewerCorpusSealSha256 -Bytes $policyBytes)
    Assert-SealThrows -Name "a toolkit policy without a toolkit root is refused" `
        -Match "no toolkit root was supplied" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $toolkitPolicyRecipe
    }

    $escapingPolicyRecipe = ConvertTo-RecipeObject -Recipe $toolkitPolicyRecipe
    $escapingPolicyRecipe.sourceTransport.policy.toolkitPath = "src/Agents/reviewer/prompts/system.md"
    Assert-SealThrows -Name "a toolkit policy outside the source policy tree is refused" `
        -Match "must live strictly under" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $escapingPolicyRecipe -ToolkitRoot $repoRoot
    }

    $aliasPolicyRecipe = ConvertTo-RecipeObject -Recipe $toolkitPolicyRecipe
    $aliasPolicyRecipe.sourceTransport.policy.toolkitPath = "src/Agents/reviewer/source/../source/v1/policy.json"
    Assert-SealThrows -Name "an aliased toolkit policy path is refused" `
        -Match "not a plain relative forward-slashed path" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $aliasPolicyRecipe -ToolkitRoot $repoRoot
    }

    $wrongHashPolicyRecipe = ConvertTo-RecipeObject -Recipe $toolkitPolicyRecipe
    $wrongHashPolicyRecipe.sourceTransport.policy.sha256 = ("e" * 64)
    Assert-SealThrows -Name "a toolkit policy whose declared hash does not match is refused" `
        -Match "derives only under the exact policy bytes" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $wrongHashPolicyRecipe -ToolkitRoot $repoRoot
    }

    $wrongLengthPolicyRecipe = ConvertTo-RecipeObject -Recipe $toolkitPolicyRecipe
    $wrongLengthPolicyRecipe.sourceTransport.policy.byteLength = ([int]$policyBytes.Length + 1)
    Assert-SealThrows -Name "a toolkit policy whose declared length does not match is refused" `
        -Match "derives only under the exact policy bytes" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $wrongLengthPolicyRecipe -ToolkitRoot $repoRoot
    }

    $bothPolicyRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $bothPolicyRecipe.sourceTransport.policy = [pscustomobject][ordered]@{
        corpusPath = "policy/source-v1.json"
        toolkitPath = "src/Agents/reviewer/source/v1/policy.json"
        sha256 = $policySha
        byteLength = $policyBytes.Length
    }
    Assert-SealThrows -Name "naming both a corpus and a toolkit policy is refused" `
        -Match "exactly one policy" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $bothPolicyRecipe -ToolkitRoot $repoRoot
    }

    $noPolicyRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $noPolicyRecipe.sourceTransport.policy = [pscustomobject][ordered]@{
        sha256 = $policySha
        byteLength = $policyBytes.Length
    }
    Assert-SealThrows -Name "naming neither policy origin is refused" `
        -Match "corpusPath" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $noPolicyRecipe -ToolkitRoot $repoRoot
    }

    $unindexedPolicyRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $unindexedPolicyRecipe.sourceTransport.policy.corpusPath = "unindexed-extra.json"
    Assert-SealThrows -Name "policy payload outside the index refused" -Match "is not a member of the canonical corpus index" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $unindexedPolicyRecipe
    }

    $policyHashRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $policyHashRecipe.hashes.policySha256 = ("9" * 64)
    Assert-SealThrows -Name "policy hash disagreement refused" -Match "policySha256" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $policyHashRecipe
    }

    $transportRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $transportRecipe.sourceTransport.expected.artifactSha256 = ("7" * 64)
    Assert-SealThrows -Name "source transport artifact disagreement" -Match "the recipe declares" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $transportRecipe
    }

    $blockRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $blockRecipe.sourceTransport.blockNonce = "DIFFERENTNONCE"
    Assert-SealThrows -Name "changed block nonce changes the artifact" -Match "the recipe declares" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $blockRecipe
    }

    # -- no-write-on-refusal --------------------------------------------------
    $refuseRoot = Join-Path $sandbox "replay-refused"
    New-Item -ItemType Directory -Force -Path $refuseRoot | Out-Null
    try { $null = New-ReviewerCorpusSealPlan -Index $index -Recipe $censusRecipe } catch { }
    Assert-Seal -Name "a refused seal writes nothing" `
        -Condition (@(Get-ChildItem -LiteralPath $refuseRoot -Recurse -Force).Count -eq 0)

    $existingRoot = Join-Path $sandbox "replay-a"
    Assert-SealThrows -Name "existing snapshot is not silently replaced" -Match "already exists" -Script {
        Save-ReviewerCorpusSeal -Plan (New-ReviewerCorpusSealPlan -Index $index -Recipe (ConvertTo-RecipeObject -Recipe $recipe)) `
            -ReplayRoot $existingRoot
    }

    $nestedArtifactRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $nestedArtifactRecipe.snapshotId = "pr4242-i1-offlinecorpusseal-nested"
    $nestedArtifactRecipe.sourceTransport.artifactFile = "transport/source-transport.json"
    $nestedArtifactRoot = Join-Path $sandbox "replay-nested"
    $nestedResult = Save-ReviewerCorpusSeal `
        -Plan (New-ReviewerCorpusSealPlan -Index $index -Recipe $nestedArtifactRecipe) `
        -ReplayRoot $nestedArtifactRoot
    Assert-Seal -Name "nested source transport artifact path is created" `
        -Condition (Test-Path -LiteralPath (Join-Path $nestedResult.SnapshotPath "transport\source-transport.json") -PathType Leaf)

    # -- classification is a digest-bound invariant ---------------------------
    Write-Host "Classification binding" -ForegroundColor Cyan
    $classified = New-AgentReplaySnapshot -ReplayRoot $replayA -SnapshotName $recipe.snapshotId `
        -ExpectedManifestDigest $sealA.ManifestDigest
    Assert-Seal -Name "loader returns the non-promotable classification" `
        -Condition ([bool]$classified.Classification.NonPromotable -and
            [string]$classified.Classification.SealKind -ceq "offlineCorpusSeal")
    Assert-SealThrows -Name "a classified snapshot is refused by every promotable flow" -Match "non-promotable" -Script {
        Assert-AgentReplaySnapshotPromotable -Snapshot $classified -Operation "promotion"
    }

    $manifestPath = Join-Path $sealA.SnapshotPath "manifest.json"
    $sidecarPath = Join-Path $sealA.SnapshotPath "offline-corpus-seal.json"
    $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $sidecarBytes = [System.IO.File]::ReadAllBytes($sidecarPath)

    # Deleting the sidecar must break the LOAD, not merely be noticed later.
    Remove-Item -LiteralPath $sidecarPath -Force
    Assert-SealThrows -Name "deleting the sidecar fails the load" -Match "sidecar" -Script {
        New-AgentReplaySnapshot -ReplayRoot $replayA -SnapshotName $recipe.snapshotId `
            -ExpectedManifestDigest $sealA.ManifestDigest
    }
    # A single altered byte is enough: the manifest pins the sidecar's SHA-256.
    $alteredSidecar = [byte[]]::new($sidecarBytes.Length)
    [Array]::Copy($sidecarBytes, $alteredSidecar, $sidecarBytes.Length)
    $alteredSidecar[$alteredSidecar.Length - 1] = $alteredSidecar[$alteredSidecar.Length - 1] -bxor 0x20
    [System.IO.File]::WriteAllBytes($sidecarPath, $alteredSidecar)
    Assert-SealThrows -Name "altering the sidecar fails the load" -Match "does not match its recorded SHA-256" -Script {
        New-AgentReplaySnapshot -ReplayRoot $replayA -SnapshotName $recipe.snapshotId `
            -ExpectedManifestDigest $sealA.ManifestDigest
    }
    [System.IO.File]::WriteAllBytes($sidecarPath, $sidecarBytes)

    # Stripping the classification out of the manifest must break the digest,
    # so the label cannot be shed by editing the file that carries it.
    $strippedManifest = ($utf8.GetString($manifestBytes) | ConvertFrom-Json -Depth 24)
    $strippedManifest.PSObject.Properties.Remove("classification")
    [System.IO.File]::WriteAllBytes($manifestPath, $utf8.GetBytes(($strippedManifest | ConvertTo-Json -Depth 24)))
    Assert-SealThrows -Name "removing the classification breaks the manifest digest" -Match "digest" -Script {
        New-AgentReplaySnapshot -ReplayRoot $replayA -SnapshotName $recipe.snapshotId `
            -ExpectedManifestDigest $sealA.ManifestDigest
    }
    # A classification may only ever WITHDRAW promotability.
    $launderedManifest = ($utf8.GetString($manifestBytes) | ConvertFrom-Json -Depth 24)
    $launderedManifest.classification.nonPromotable = $false
    [System.IO.File]::WriteAllBytes($manifestPath, $utf8.GetBytes(($launderedManifest | ConvertTo-Json -Depth 24)))
    Assert-SealThrows -Name "a classification may not grant promotability" -Match "never grant it" -Script {
        New-AgentReplaySnapshot -ReplayRoot $replayA -SnapshotName $recipe.snapshotId
    }
    [System.IO.File]::WriteAllBytes($manifestPath, $manifestBytes)
    $restored = New-AgentReplaySnapshot -ReplayRoot $replayA -SnapshotName $recipe.snapshotId `
        -ExpectedManifestDigest $sealA.ManifestDigest
    Assert-Seal -Name "restoring the sidecar and manifest restores the load" `
        -Condition ([bool]$restored.Classification.NonPromotable)

    # -- authoritative completeness -------------------------------------------
    Write-Host "Authoritative completeness" -ForegroundColor Cyan
    $wrongKindRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $wrongKindRecipe.changedFiles[0].changeKinds = @("rename")
    Assert-SealThrows -Name "declared change kinds must match the change set" -Match "change kind" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $wrongKindRecipe
    }

    # A path the change set says is deleted may not be sealed WITH right-hand
    # content: the recipe does not get to invent source the change set denies.
    $deletedRightHandRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $deletedRightHandRecipe.changedFiles += (ConvertTo-RecipeObject -Recipe ([ordered]@{
                path = $deletedPath
                changeKinds = @("delete")
                rightHand = (New-BoundDeclaration -Relative "files/alpha.txt" -Text $alphaText)
                spans = @([ordered]@{ start = 1; count = 1 })
            }))
    $deletedRightHandRecipe.sourceCensus.rightHandCoveredPathCount = 3
    $deletedRightHandRecipe.sourceCensus.noRightHandPaths = @()
    Assert-SealThrows -Name "right-hand content for a deleted path refused" -Match "say it has none" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $deletedRightHandRecipe
    }

    # ...and conversely a content-bearing path may not be excused as source-free.
    $falseExcuseRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $falseExcuseRecipe.changedFiles = @($falseExcuseRecipe.changedFiles[0])
    $falseExcuseRecipe.sourceCensus.rightHandCoveredPathCount = 1
    $falseExcuseRecipe.sourceCensus.noRightHandPaths = @($betaPath, $deletedPath)
    Assert-SealThrows -Name "a content-bearing path may not be excused" -Match "do carry right-hand content" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $falseExcuseRecipe
    }

    # A malformed authoritative path is a refusal, not something to filter away.
    $malformedRoot = Join-Path $sandbox "corpus-malformed"
    $malformedChangeSet = ($changeSetText | ConvertFrom-Json -Depth 24)
    $malformedChangeSet.changeEntries[1].item.path = "   "
    $malformedText = ($malformedChangeSet | ConvertTo-Json -Depth 24)
    $malformedIndexSha = New-SyntheticCorpus -Root $malformedRoot -Overrides @{ "changes-authoritative.json" = $malformedText }
    $malformedIndex = Import-ReviewerCorpusIndex -CorpusRoot $malformedRoot -ExpectedIndexSha256 $malformedIndexSha
    $malformedRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $malformedRecipe.corpus.indexSha256 = $malformedIndexSha
    $malformedRecipe.corpus.payloadCount = $malformedIndex.PayloadCount
    $malformedRecipe.changeSet.authoritative.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes ($utf8.GetBytes($malformedText)))
    $malformedRecipe.changeSet.authoritative.byteLength = $utf8.GetBytes($malformedText).Length
    $malformedRecipe.binding.changeSetSha256 = Get-ReviewerSourceChangeIdentityDigest -Response (
        $malformedText | ConvertFrom-Json -Depth 24)
    Assert-SealThrows -Name "malformed authoritative path refused, not filtered" -Match "does not normalize" -Script {
        New-ReviewerCorpusSealPlan -Index $malformedIndex -Recipe $malformedRecipe
    }

    # -- cross-path / payload / span substitution -----------------------------
    Write-Host "Substitution rejection" -ForegroundColor Cyan
    # Swapping one path's sealed bytes for another indexed payload keeps every
    # hash self-consistent. What catches it is the recorded read: the capture's
    # own repo_file read of that path at the source commit returned different
    # bytes, and the seal will not present one file's content as another's.
    $swappedPayloadRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $swappedPayloadRecipe.changedFiles[0].rightHand = (ConvertTo-RecipeObject -Recipe (
            New-BoundDeclaration -Relative "files/beta.txt" -Text $betaText))
    Assert-SealThrows -Name "one path's bytes may not be sealed under another path" `
        -Match "cannot show one file's bytes as another's" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $swappedPayloadRecipe
    }

    # Removing the recorded read leaves the payload indexed and the hashes valid,
    # but nothing then proves the capture ever read that file at that commit.
    $noReadRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $noReadRecipe.resources = @($noReadRecipe.resources | Where-Object {
            -not ($_.tool -ceq "repo_file" -and [string]$_.arguments.path -ceq $alphaPath)
        })
    Assert-SealThrows -Name "sealed content with no recorded source read is refused" `
        -Match "records no read of that path at source commit" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $noReadRecipe
    }

    # A read of the right path at the WRONG commit is not a read of this
    # iteration's content, so it does not satisfy the binding either.
    $staleReadRecipe = ConvertTo-RecipeObject -Recipe $recipe
    foreach ($resource in $staleReadRecipe.resources) {
        if ($resource.tool -ceq "repo_file" -and [string]$resource.arguments.path -ceq $alphaPath) {
            $resource.arguments.version = $targetCommit
        }
    }
    Assert-SealThrows -Name "a source read at the wrong commit does not bind" `
        -Match "records no read of that path at source commit" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $staleReadRecipe
    }

    # ...nor does a read attributed to a different repository.
    $foreignRepoReadRecipe = ConvertTo-RecipeObject -Recipe $recipe
    foreach ($resource in $foreignRepoReadRecipe.resources) {
        if ($resource.tool -ceq "repo_file" -and [string]$resource.arguments.path -ceq $alphaPath) {
            $resource.arguments.repositoryId = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        }
    }
    Assert-SealThrows -Name "a source read from another repository does not bind" `
        -Match "records no read of that path at source commit" -Script {
        New-ReviewerCorpusSealPlan -Index $index -Recipe $foreignRepoReadRecipe
    }

    # Span evidence belonging to a different change set cannot be spliced in.
    $foreignSpanRoot = Join-Path $sandbox "corpus-foreign-spans"
    $foreignSpans = ($spanEvidenceText | ConvertFrom-Json -Depth 24)
    $foreignSpans[0].path = "/src/somewhere-else.txt"
    $foreignSpanText = ConvertTo-Json -InputObject $foreignSpans -Depth 24
    $foreignSpanIndexSha = New-SyntheticCorpus -Root $foreignSpanRoot -Overrides @{ "exact-spans.json" = $foreignSpanText }
    $foreignSpanIndex = Import-ReviewerCorpusIndex -CorpusRoot $foreignSpanRoot -ExpectedIndexSha256 $foreignSpanIndexSha
    $foreignSpanRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $foreignSpanRecipe.corpus.indexSha256 = $foreignSpanIndexSha
    $foreignSpanRecipe.corpus.payloadCount = $foreignSpanIndex.PayloadCount
    $foreignSpanRecipe.changeSet.spanEvidence.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes ($utf8.GetBytes($foreignSpanText)))
    $foreignSpanRecipe.changeSet.spanEvidence.byteLength = $utf8.GetBytes($foreignSpanText).Length
    Assert-SealThrows -Name "span evidence for a foreign path is refused" `
        -Match "which the authoritative change set does not carry" -Script {
        New-ReviewerCorpusSealPlan -Index $foreignSpanIndex -Recipe $foreignSpanRecipe
    }

    # Evidence that omits a content-bearing path cannot be completed by the recipe.
    $missingSpanRoot = Join-Path $sandbox "corpus-missing-spans"
    $missingSpans = @(($spanEvidenceText | ConvertFrom-Json -Depth 24) | Where-Object { [string]$_.path -cne $alphaPath })
    $missingSpanText = ConvertTo-Json -InputObject $missingSpans -Depth 24
    $missingSpanIndexSha = New-SyntheticCorpus -Root $missingSpanRoot -Overrides @{ "exact-spans.json" = $missingSpanText }
    $missingSpanIndex = Import-ReviewerCorpusIndex -CorpusRoot $missingSpanRoot -ExpectedIndexSha256 $missingSpanIndexSha
    $missingSpanRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $missingSpanRecipe.corpus.indexSha256 = $missingSpanIndexSha
    $missingSpanRecipe.corpus.payloadCount = $missingSpanIndex.PayloadCount
    $missingSpanRecipe.changeSet.spanEvidence.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes ($utf8.GetBytes($missingSpanText)))
    $missingSpanRecipe.changeSet.spanEvidence.byteLength = $utf8.GetBytes($missingSpanText).Length
    Assert-SealThrows -Name "span evidence missing a content-bearing path is refused" `
        -Match "cannot invent the lines it shows" -Script {
        New-ReviewerCorpusSealPlan -Index $missingSpanIndex -Recipe $missingSpanRecipe
    }

    # Malformed evidence is refused rather than partially adopted.
    $badHunkRoot = Join-Path $sandbox "corpus-bad-hunks"
    $badHunks = ($spanEvidenceText | ConvertFrom-Json -Depth 24)
    $badHunks[0].hunks[1].newStart = 4
    $badHunkText = ConvertTo-Json -InputObject $badHunks -Depth 24
    $badHunkIndexSha = New-SyntheticCorpus -Root $badHunkRoot -Overrides @{ "exact-spans.json" = $badHunkText }
    $badHunkIndex = Import-ReviewerCorpusIndex -CorpusRoot $badHunkRoot -ExpectedIndexSha256 $badHunkIndexSha
    $badHunkRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $badHunkRecipe.corpus.indexSha256 = $badHunkIndexSha
    $badHunkRecipe.corpus.payloadCount = $badHunkIndex.PayloadCount
    $badHunkRecipe.changeSet.spanEvidence.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes ($utf8.GetBytes($badHunkText)))
    $badHunkRecipe.changeSet.spanEvidence.byteLength = $utf8.GetBytes($badHunkText).Length
    Assert-SealThrows -Name "overlapping hunks in the evidence are refused" `
        -Match "not in strictly ascending, non-overlapping right-hand order" -Script {
        New-ReviewerCorpusSealPlan -Index $badHunkIndex -Recipe $badHunkRecipe
    }

    # -- output path collisions -----------------------------------------------
    Write-Host "Output collisions" -ForegroundColor Cyan
    foreach ($case in @(
            @{ Name = "artifact may not overwrite the manifest"; File = "manifest.json"; Match = "reserved snapshot file" },
            @{ Name = "artifact may not overwrite the sidecar"; File = "offline-corpus-seal.json"; Match = "reserved snapshot file" },
            @{ Name = "artifact may not collide with a payload"; File = "payloads/pr-get.json"; Match = "same file" },
            @{ Name = "artifact may not be an ancestor of a payload"; File = "payloads"; Match = "cannot be both" }
        )) {
        $collisionRecipe = ConvertTo-RecipeObject -Recipe $recipe
        $collisionRecipe.sourceTransport.artifactFile = [string]$case.File
        Assert-SealThrows -Name ([string]$case.Name) -Match ([string]$case.Match) -Script {
            New-ReviewerCorpusSealPlan -Index $index -Recipe $collisionRecipe
        }
    }

    # -- -Force preserves the existing snapshot on failure ---------------------
    $forceRoot = Join-Path $sandbox "replay-force"
    $forceSeal = Save-ReviewerCorpusSeal -Plan (New-ReviewerCorpusSealPlan -Index $index `
            -Recipe (ConvertTo-RecipeObject -Recipe $recipe)) -ReplayRoot $forceRoot
    $forceDigestBefore = Get-FileSha -Path (Join-Path $forceSeal.SnapshotPath "manifest.json")
    $forceFilesBefore = @(Get-ChildItem -LiteralPath $forceSeal.SnapshotPath -Recurse -File).Count
    $sabotagedPlan = New-ReviewerCorpusSealPlan -Index $index -Recipe (ConvertTo-RecipeObject -Recipe $recipe)
    # Make the load-validate step fail after everything has been staged, which is
    # the last moment at which a destructive -Force could still lose the original.
    $sabotagedPlan.CapturedUtc = "not-a-timestamp"
    $forceFailed = $false
    try { $null = Save-ReviewerCorpusSeal -Plan $sabotagedPlan -ReplayRoot $forceRoot -Force }
    catch { $forceFailed = $true }
    Assert-Seal -Name "-Force refuses a snapshot the loader would reject" -Condition $forceFailed
    Assert-Seal -Name "-Force preserves the existing snapshot on failure" `
        -Condition ((Test-Path -LiteralPath $forceSeal.SnapshotPath -PathType Container) -and
            (Get-FileSha -Path (Join-Path $forceSeal.SnapshotPath "manifest.json")) -ceq $forceDigestBefore -and
            @(Get-ChildItem -LiteralPath $forceSeal.SnapshotPath -Recurse -File).Count -eq $forceFilesBefore)
    Assert-Seal -Name "a failed publish leaves no staging directory behind" `
        -Condition (@(Get-ChildItem -LiteralPath $forceRoot -Directory -Force |
                Where-Object { $_.Name -like ".corpus-seal-*" }).Count -eq 0)
    $forceAgain = Save-ReviewerCorpusSeal -Plan (New-ReviewerCorpusSealPlan -Index $index `
            -Recipe (ConvertTo-RecipeObject -Recipe $recipe)) -ReplayRoot $forceRoot -Force
    Assert-Seal -Name "-Force republishes an identical snapshot on success" `
        -Condition ($forceAgain.ManifestDigest -ceq $forceSeal.ManifestDigest -and
            @(Get-ChildItem -LiteralPath $forceRoot -Directory -Force).Count -eq 1)

    # -- independent organization / project / repository binding ---------------
    # A recipe that bound only the repository GUID would happily present one
    # repository's evidence under another organization and project. The corpus
    # says which repository it was captured from, and all three parts of that
    # name have to agree with the recipe independently.
    Write-Host "Identity binding" -ForegroundColor Cyan
    function Set-BoundDeclaration {
        param([Parameter(Mandatory)]$Declaration, [Parameter(Mandatory)][string]$Text)
        $declarationBytes = ([System.Text.UTF8Encoding]::new($false, $true)).GetBytes($Text)
        $Declaration.sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $declarationBytes)
        $Declaration.byteLength = $declarationBytes.Length
    }

    foreach ($case in @(
            @{ Name = "cross-organization substitution refused"; Field = "organization"; Value = "fabrikam" },
            @{ Name = "cross-project substitution refused"; Field = "project"; Value = "sprockets" },
            @{ Name = "cross-repository substitution refused"; Field = "repositoryName"; Value = "doohickeys" }
        )) {
        $bindingRecipe = ConvertTo-RecipeObject -Recipe $recipe
        $bindingRecipe.binding.($case.Field) = [string]$case.Value
        Assert-SealThrows -Name ([string]$case.Name) -Match "the corpus index was captured from" -Script {
            New-ReviewerCorpusSealPlan -Index $index -Recipe $bindingRecipe
        }
    }

    $namelessRoot = Join-Path $sandbox "corpus-nameless"
    $namelessSha = New-SyntheticCorpus -Root $namelessRoot -Repository "contoso/widgets"
    Assert-SealThrows -Name "a corpus that will not name its repository is refused" `
        -Match "field 'repository' does not match its required shape" -Script {
        Import-ReviewerCorpusIndex -CorpusRoot $namelessRoot -ExpectedIndexSha256 $namelessSha
    }

    $foreignIdentity = ($identityText | ConvertFrom-Json -Depth 8)
    $foreignIdentity.repositoryId = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    $foreignIdentityText = ($foreignIdentity | ConvertTo-Json -Depth 8)
    $foreignIdentityRoot = Join-Path $sandbox "corpus-foreign-identity"
    $foreignIdentitySha = New-SyntheticCorpus -Root $foreignIdentityRoot -Overrides @{ "identity.json" = $foreignIdentityText }
    $foreignIdentityIndex = Import-ReviewerCorpusIndex -CorpusRoot $foreignIdentityRoot -ExpectedIndexSha256 $foreignIdentitySha
    $foreignIdentityRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $foreignIdentityRecipe.corpus.indexSha256 = $foreignIdentitySha
    $foreignIdentityRecipe.corpus.payloadCount = $foreignIdentityIndex.PayloadCount
    Set-BoundDeclaration -Declaration $foreignIdentityRecipe.capture.identity -Text $foreignIdentityText
    Assert-SealThrows -Name "a captured identity from another repository is refused" `
        -Match "'repositoryId' does not match the sealed binding" -Script {
        New-ReviewerCorpusSealPlan -Index $foreignIdentityIndex -Recipe $foreignIdentityRecipe
    }

    $noDraftIdentity = ($identityText | ConvertFrom-Json -Depth 8)
    $noDraftIdentity.PSObject.Properties.Remove("isDraft")
    $noDraftIdentityText = ($noDraftIdentity | ConvertTo-Json -Depth 8)
    $noDraftRoot = Join-Path $sandbox "corpus-no-draft"
    $noDraftSha = New-SyntheticCorpus -Root $noDraftRoot -Overrides @{ "identity.json" = $noDraftIdentityText }
    $noDraftIndex = Import-ReviewerCorpusIndex -CorpusRoot $noDraftRoot -ExpectedIndexSha256 $noDraftSha
    $noDraftRecipe = ConvertTo-RecipeObject -Recipe $recipe
    $noDraftRecipe.corpus.indexSha256 = $noDraftSha
    $noDraftRecipe.corpus.payloadCount = $noDraftIndex.PayloadCount
    Set-BoundDeclaration -Declaration $noDraftRecipe.capture.identity -Text $noDraftIdentityText
    Assert-SealThrows -Name "a captured identity that omits isDraft is refused" -Match "omits 'isDraft'" -Script {
        New-ReviewerCorpusSealPlan -Index $noDraftIndex -Recipe $noDraftRecipe
    }

    # The END of capture is what proves the pull request did not move during the
    # read, so a drifting or unverifiable end state is refused three ways.
    foreach ($case in @(
            @{
                Name = "an end-of-capture source commit that moved is refused"
                Match = "the pull request moved while it was being captured"
                Mutate = {
                    param($EndIdentity)
                    $EndIdentity.PSObject.Properties.Remove("sourceCommit")
                    Add-Member -InputObject $EndIdentity -MemberType NoteProperty `
                        -Name "lastMergeSourceCommit" -Value $targetCommit
                }
            },
            @{
                Name = "an end-of-capture status that moved is refused"
                Match = "the pull request moved while it was being captured"
                Mutate = { param($EndIdentity) $EndIdentity.status = "completed" }
            },
            @{
                Name = "an end-of-capture that declares its own drift is refused"
                Match = "matchesInitialCapture = false"
                Mutate = { param($EndIdentity) $EndIdentity.matchesInitialCapture = $false }
            },
            @{
                Name = "an end-of-capture with nothing checkable is refused"
                Match = "carries nothing the sealed binding can be checked against"
                Mutate = {
                    param($EndIdentity)
                    foreach ($name in @("sourceCommit", "targetCommit", "status", "isDraft", "matchesInitialCapture")) {
                        $EndIdentity.PSObject.Properties.Remove($name)
                    }
                }
            }
        )) {
        $endIdentity = ($endIdentityText | ConvertFrom-Json -Depth 8)
        & ([scriptblock]$case.Mutate) $endIdentity
        $mutatedEndText = ($endIdentity | ConvertTo-Json -Depth 8)
        $endRoot = Join-Path $sandbox ("corpus-end-" + [string]$script:checks)
        $endSha = New-SyntheticCorpus -Root $endRoot -Overrides @{ "end-identity.json" = $mutatedEndText }
        $endIndex = Import-ReviewerCorpusIndex -CorpusRoot $endRoot -ExpectedIndexSha256 $endSha
        $endRecipe = ConvertTo-RecipeObject -Recipe $recipe
        $endRecipe.corpus.indexSha256 = $endSha
        $endRecipe.corpus.payloadCount = $endIndex.PayloadCount
        Set-BoundDeclaration -Declaration $endRecipe.capture.endIdentity -Text $mutatedEndText
        Assert-SealThrows -Name ([string]$case.Name) -Match ([string]$case.Match) -Script {
            New-ReviewerCorpusSealPlan -Index $endIndex -Recipe $endRecipe
        }
    }

    # -- the recorded source read is held to its whole contract ----------------
    # A read that claims to be a source-commit content read has to say so
    # completely. Anything less lets sealed bytes hang off a read that never
    # named the commit, the project or the path they came from.
    Write-Host "Recorded source read contract" -ForegroundColor Cyan
    foreach ($required in @("action", "project", "versionType", "path")) {
        $omitRecipe = ConvertTo-RecipeObject -Recipe $recipe
        foreach ($resource in $omitRecipe.resources) {
            if ($resource.tool -ceq "repo_file" -and [string]$resource.arguments.path -ceq $alphaPath) {
                $resource.arguments.PSObject.Properties.Remove($required)
            }
        }
        Assert-SealThrows -Name "a source read that omits '$required' is refused" `
            -Match "omits '$required'|without an action" -Script {
            New-ReviewerCorpusSealPlan -Index $index -Recipe $omitRecipe
        }
    }

    foreach ($case in @(
            @{ Name = "a source read with the wrong action is refused"; Field = "action"; Value = "get"; Match = "declares action 'get'|outside the replay read ceiling" },
            @{ Name = "a source read attributed to another project is refused"; Field = "project"; Value = "sprockets"; Match = "names project 'sprockets'" },
            @{ Name = "a source read pinned to a branch is refused"; Field = "versionType"; Value = "Branch"; Match = "not 'Commit'" },
            @{ Name = "a source read attributed to another organization is refused"; Field = "organization"; Value = "fabrikam"; Match = "names organization 'fabrikam'" }
        )) {
        $argumentRecipe = ConvertTo-RecipeObject -Recipe $recipe
        foreach ($resource in $argumentRecipe.resources) {
            if ($resource.tool -ceq "repo_file" -and [string]$resource.arguments.path -ceq $alphaPath) {
                $resource.arguments.([string]$case.Field) = [string]$case.Value
            }
        }
        Assert-SealThrows -Name ([string]$case.Name) -Match ([string]$case.Match) -Script {
            New-ReviewerCorpusSealPlan -Index $index -Recipe $argumentRecipe
        }
    }

    # An alias is refused, not normalized: a read binds by the exact canonical
    # path or it does not bind at all.
    foreach ($alias in @("//src/alpha.txt", "/src/./alpha.txt", "\src\alpha.txt", "src/alpha.txt", "/SRC/alpha.txt")) {
        $aliasRecipe = ConvertTo-RecipeObject -Recipe $recipe
        foreach ($resource in $aliasRecipe.resources) {
            if ($resource.tool -ceq "repo_file" -and [string]$resource.arguments.path -ceq $alphaPath) {
                $resource.arguments.path = $alias
            }
        }
        Assert-SealThrows -Name "a source read path alias is refused: '$alias'" `
            -Match "never by an alias of one|records no read of that path at source" -Script {
            New-ReviewerCorpusSealPlan -Index $index -Recipe $aliasRecipe
        }
    }

    # -- replay-root containment cannot be bypassed by a reparse point ---------
    # The CLI's job here is to keep private pull-request evidence out of the
    # working tree. Textual path normalization alone cannot do that: a junction
    # named outside the repo can point straight back into it.
    Write-Host "Replay-root containment" -ForegroundColor Cyan
    # The plainest mistake of all is not a link at all: naming a directory inside
    # the repository. A direct library caller has to be refused for that too.
    $toolkitRootTarget = Join-Path $repoRoot "tools\corpus-seal-scratch"
    $toolkitRootRefusal = ""
    try {
        Save-ReviewerCorpusSeal -ReplayRoot $toolkitRootTarget `
            -Plan (New-ReviewerCorpusSealPlan -Index $index -Recipe (ConvertTo-RecipeObject -Recipe $recipe)) | Out-Null
    }
    catch { $toolkitRootRefusal = [string]$_.Exception.Message }
    Assert-Seal -Name "a replay root inside the toolkit tree is refused" `
        -Condition ($toolkitRootRefusal -match "inside the toolkit working tree")
    Assert-Seal -Name "the refused toolkit-root seal created nothing in the repository" `
        -Condition (-not (Test-Path -LiteralPath $toolkitRootTarget))
    Assert-SealThrows -Name "the replay-root guard itself refuses the toolkit tree" `
        -Match "inside the toolkit working tree" -Script {
        Assert-ReviewerCorpusSealReplayRoot -ReplayRoot $toolkitRootTarget -Stage "test"
    }

    # Target an existing repository directory rather than creating one, so the
    # test never writes into the working tree even when the guard is broken.
    $junctionSource = Join-Path $repoRoot "tools"
    $junctionPath = Join-Path $sandbox "outside-link"
    $junctionMade = $false
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionSource -ErrorAction Stop | Out-Null
        $junctionMade = $true
    }
    catch { }
    if ($junctionMade) {
        $sealTool = Join-Path $repoRoot "tools\Save-CorpusReplaySeal.ps1"
        $recipePath = Save-Recipe -Recipe (ConvertTo-RecipeObject -Recipe $recipe) -Path (Join-Path $sandbox "reparse.json")
        $output = & pwsh -NoProfile -File $sealTool -CorpusRoot $corpusRoot -CorpusIndexSha256 $indexSha `
            -Recipe $recipePath -ReplayRoot (Join-Path $junctionPath "seal") 2>&1
        Assert-Seal -Name "a reparse point in the replay root is refused" `
            -Condition ($LASTEXITCODE -ne 0 -and ([string]($output -join "`n")) -match "reparse point")
        Assert-Seal -Name "the refused reparse-point seal wrote nothing into the repository" `
            -Condition (-not (Test-Path -LiteralPath (Join-Path $junctionSource "seal")))

        # The guard has to hold for a DIRECT library call too. A safety property
        # only the CLI enforces is a safety property a direct caller does not
        # have, so Save-ReviewerCorpusSeal is handed the junction itself.
        $directRefusal = ""
        try {
            $directPlan = New-ReviewerCorpusSealPlan -Index $index -Recipe (ConvertTo-RecipeObject -Recipe $recipe)
            Save-ReviewerCorpusSeal -Plan $directPlan -ReplayRoot $junctionPath | Out-Null
        }
        catch { $directRefusal = [string]$_.Exception.Message }
        Assert-Seal -Name "a direct library call refuses a reparse-point replay root" `
            -Condition ($directRefusal -match "reparse point")
        Assert-Seal -Name "the refused direct call wrote nothing into the repository" `
            -Condition (-not (Test-Path -LiteralPath (Join-Path $junctionSource $recipe.snapshotId)))

        Remove-Item -LiteralPath $junctionPath -Force -Recurse -ErrorAction SilentlyContinue

        # Cleanup is the one path that runs even when everything else failed, so
        # it is exactly the path a link dropped into staging would exploit.
        $scratchRoot = Join-Path $sandbox "scratch"
        $scratchKeep = Join-Path $sandbox "scratch-target"
        New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null
        New-Item -ItemType Directory -Force -Path $scratchKeep | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $scratchKeep "keep.txt"), "keep")
        [System.IO.File]::WriteAllText((Join-Path $scratchRoot "scratch.txt"), "scratch")
        New-Item -ItemType Junction -Path (Join-Path $scratchRoot "link") -Target $scratchKeep | Out-Null
        Remove-ReviewerCorpusSealScratch -Path $scratchRoot
        Assert-Seal -Name "scratch cleanup removes the staging directory" `
            -Condition (-not (Test-Path -LiteralPath $scratchRoot))
        Assert-Seal -Name "scratch cleanup never deletes through a reparse point" `
            -Condition (Test-Path -LiteralPath (Join-Path $scratchKeep "keep.txt") -PathType Leaf)
    }
    else {
        Write-Host "  SKIP  reparse-point containment (junctions unavailable on this host)" -ForegroundColor Yellow
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:failures -gt 0) {
    Write-Host "$script:failures of $script:checks check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All $script:checks check(s) passed" -ForegroundColor Green
