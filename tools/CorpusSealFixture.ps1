#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds a synthetic, employer-neutral research corpus and the matching seal
    recipe, so an offline suite can drive the real corpus sealer end to end.

.DESCRIPTION
    Test support, dot-sourced rather than run. It exists because the corpus
    sealer is the normative canonicalizer for snapshot evidence and must not be
    stubbed: a suite that faked a sealed snapshot would be testing its own fake.
    What is synthetic here is the corpus, not the sealing.

    Every digest the recipe declares is derived through the sealer's own
    production functions, or learned from the sealer's own refusal, rather than
    computed a second way. A fixture that re-implemented the derivation would
    agree with itself while disagreeing with the tool.

    Nothing here contacts a host, launches a model, or writes outside the root it
    is given.
#>

Set-StrictMode -Version Latest

$script:CorpusFixtureUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

function New-ReviewerCorpusFixtureIdentity {
    <#
    .SYNOPSIS
        The synthetic subject the corpus and its recipe both bind to.

    .DESCRIPTION
        Deliberately neutral names. The repository NAME is what a reviewer passes
        as repositoryId on its first bounded read, so the pull-request read is
        keyed on the name and never the identifier.
    #>
    param(
        [ValidateRange(1, 2147483647)][int]$PullRequestId = 5251,
        [ValidateRange(1, 4096)][int]$IterationId = 1
    )
    return [pscustomobject][ordered]@{
        Organization = 'contoso'
        Project = 'widgets'
        RepositoryName = 'gadgets'
        RepositoryId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        PullRequestId = $PullRequestId
        IterationId = $IterationId
        SourceCommit = '1' * 40
        CommonCommit = '2' * 40
        TargetCommit = '3' * 40
        AlphaPath = '/src/alpha.txt'
        BetaPath = '/src/beta.txt'
        DeletedPath = '/src/gone.txt'
    }
}

function Get-ReviewerCorpusFixtureContent {
    <#
    .SYNOPSIS
        Every payload the corpus holds, as text, keyed by its corpus-relative
        path. One place, so the index, the recipe and the files cannot drift.
    #>
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$ToolkitRoot
    )

    $alphaText = (1..40 | ForEach-Object { "alpha line $_" }) -join "`n"
    $betaText = (1..24 | ForEach-Object { "beta line $_" }) -join "`n"

    # Three change entries, so every serialized corpus array stays an array: a
    # single-element PowerShell array round-trips through ConvertTo-Json as a
    # bare object, which the sealer refuses.
    $changeSet = [ordered]@{
        changeEntries = @(
            [ordered]@{ item = [ordered]@{ path = $Identity.AlphaPath; isFolder = $false }; changeType = 'edit' },
            [ordered]@{ item = [ordered]@{ path = $Identity.BetaPath; isFolder = $false }; changeType = 'add' },
            [ordered]@{ item = [ordered]@{ path = $Identity.DeletedPath; isFolder = $false }; changeType = 'delete' }
        )
    }
    $changeSetText = $changeSet | ConvertTo-Json -Depth 12

    $spanEvidence = @(
        [ordered]@{
            path = $Identity.AlphaPath
            hunks = @(
                [ordered]@{ oldStart = 3; oldCount = 4; newStart = 3; newCount = 4 },
                [ordered]@{ oldStart = 19; oldCount = 2; newStart = 20; newCount = 2 }
            )
        },
        [ordered]@{
            path = $Identity.BetaPath
            hunks = @([ordered]@{ oldStart = 0; oldCount = 0; newStart = 1; newCount = 24 })
        },
        [ordered]@{
            path = $Identity.DeletedPath
            hunks = @([ordered]@{ oldStart = 1; oldCount = 9; newStart = 0; newCount = 0 })
        }
    )

    $identityText = ([ordered]@{
            pullRequestId = $Identity.PullRequestId
            iterationId = $Identity.IterationId
            repositoryId = $Identity.RepositoryId
            sourceCommit = $Identity.SourceCommit
            commonCommit = $Identity.CommonCommit
            targetCommit = $Identity.TargetCommit
            status = 'active'
            isDraft = $false
        } | ConvertTo-Json -Depth 6)
    $endIdentityText = ([ordered]@{
            pullRequestId = $Identity.PullRequestId
            iterationId = $Identity.IterationId
            sourceCommit = $Identity.SourceCommit
            targetCommit = $Identity.TargetCommit
            status = 'active'
            isDraft = $false
            matchesInitialCapture = $true
        } | ConvertTo-Json -Depth 6)

    $policyPath = Join-Path $ToolkitRoot 'src\Agents\reviewer\source\v1\policy.json'
    $policyBytes = [System.IO.File]::ReadAllBytes($policyPath)
    $policyText = $script:CorpusFixtureUtf8.GetString($policyBytes)

    $files = [ordered]@{
        'identity.json' = $identityText
        'end-identity.json' = $endIdentityText
        'changes-authoritative.json' = $changeSetText
        'exact-spans.json' = (ConvertTo-Json -InputObject $spanEvidence -Depth 12)
        'files/alpha.txt' = $alphaText
        'files/beta.txt' = $betaText
        'live/pr-get.json' = ([ordered]@{ pullRequestId = $Identity.PullRequestId; title = 'synthetic'; status = 'active' } | ConvertTo-Json -Depth 6)
        'live/threads.json' = ([ordered]@{ value = @(); count = 0 } | ConvertTo-Json -Depth 6)
        'live/changes.json' = $changeSetText
        'evidence/sibling.txt' = 'sibling evidence'
        'evidence/rules.json' = ([ordered]@{ rules = @('no bare catch') } | ConvertTo-Json -Depth 6)
        'evidence/threads.json' = ([ordered]@{ threads = @() } | ConvertTo-Json -Depth 6)
        'evidence/facts.json' = ([ordered]@{ facts = @('alpha is edited') } | ConvertTo-Json -Depth 6)
        'policy/source-v1.json' = $policyText
    }

    return [pscustomobject][ordered]@{
        Files = $files
        PolicyBytes = $policyBytes
        PolicySha256 = (Get-ReviewerCorpusSealSha256 -Bytes ($script:CorpusFixtureUtf8.GetBytes($policyText)))
        ChangeSetText = $changeSetText
        ChangeSetSha256 = (Get-ReviewerSourceChangeIdentityDigest -Response ($changeSetText | ConvertFrom-Json -Depth 12))
        AlphaText = $alphaText
        BetaText = $betaText
    }
}

function Write-ReviewerCorpusFixtureRoot {
    <#
    .SYNOPSIS
        Writes the corpus to disk and mints its index. Returns the index digest,
        which is the only thing the sealer will accept as proof of the index.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Content
    )
    [void](New-Item -ItemType Directory -Force -Path $Root)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $Content.Files.Keys) {
        $text = [string]$Content.Files[$relative]
        $full = $Root
        foreach ($segment in ($relative -split '/')) { $full = Join-Path $full $segment }
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent))
        $bytes = $script:CorpusFixtureUtf8.GetBytes($text)
        [System.IO.File]::WriteAllBytes($full, $bytes)
        [void]$entries.Add([ordered]@{
                path = $relative
                sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
                length = $bytes.Length
            })
    }
    $identities = [ordered]@{}
    $identities["$($Identity.PullRequestId)"] = [ordered]@{
        pullRequestId = $Identity.PullRequestId
        iteration = $Identity.IterationId
        source = $Identity.SourceCommit
        common = $Identity.CommonCommit
        target = $Identity.TargetCommit
        status = 'active'
        isDraft = $false
    }
    $index = [ordered]@{
        kind = 'private-immutable-non-promotable-research-corpus'
        repository = "$($Identity.Organization)/$($Identity.Project)/$($Identity.RepositoryName)"
        payloadCount = $entries.Count
        identities = $identities
        payloads = @($entries.ToArray())
    }
    $indexPath = Join-Path $Root 'corpus-index.json'
    [System.IO.File]::WriteAllBytes($indexPath,
        $script:CorpusFixtureUtf8.GetBytes(($index | ConvertTo-Json -Depth 12 -Compress:$false)))
    return (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-ReviewerCorpusFixtureBinding {
    param([Parameter(Mandatory)][string]$Relative, [Parameter(Mandatory)][string]$Text)
    $bytes = $script:CorpusFixtureUtf8.GetBytes($Text)
    return [ordered]@{
        corpusPath = $Relative
        sha256 = (Get-ReviewerCorpusSealSha256 -Bytes $bytes)
        byteLength = $bytes.Length
    }
}

function New-ReviewerCorpusFixtureRecipe {
    <#
    .SYNOPSIS
        The private seal recipe, with placeholder expectations that the
        resolution pass below replaces with derived truth.
    #>
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Content,
        [Parameter(Mandatory)][string]$IndexSha256,
        [Parameter(Mandatory)][int]$PayloadCount
    )
    $files = $Content.Files
    return [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-offline-corpus-seal-recipe'
        snapshotId = "pr$($Identity.PullRequestId)-i$($Identity.IterationId)-offlinecorpusseal"
        provider = 'azuredevops'
        capturedUtc = '20260101T000000Z'
        nonPromotable = $true
        sealKind = 'offlineCorpusSeal'
        corpus = [ordered]@{ indexSha256 = $IndexSha256; payloadCount = $PayloadCount }
        binding = [ordered]@{
            organization = $Identity.Organization
            project = $Identity.Project
            repositoryId = $Identity.RepositoryId
            repositoryName = $Identity.RepositoryName
            pullRequestId = $Identity.PullRequestId
            iterationId = $Identity.IterationId
            sourceCommit = $Identity.SourceCommit
            commonCommit = $Identity.CommonCommit
            targetCommit = $Identity.TargetCommit
            changeSetSha256 = $Content.ChangeSetSha256
        }
        capture = [ordered]@{
            identity = (New-ReviewerCorpusFixtureBinding -Relative 'identity.json' -Text ([string]$files['identity.json']))
            endIdentity = (New-ReviewerCorpusFixtureBinding -Relative 'end-identity.json' -Text ([string]$files['end-identity.json']))
            statusAtCapture = 'active'
            isDraft = $false
            mode = 'offlineCorpusCapture'
            livePostReadRaceCheck = 'notPerformed'
        }
        bindings = [ordered]@{
            configSha256 = ('a' * 64)
            scriptSha256 = ('b' * 64)
            promptSha256 = ('c' * 64)
            models = @('model-one', 'model-two')
        }
        hashes = [ordered]@{
            policySha256 = $Content.PolicySha256
            configSha256 = ('a' * 64)
            scriptSha256 = ('b' * 64)
            schemaSha256 = ('d' * 64)
            promptSha256 = ('c' * 64)
        }
        changeSet = [ordered]@{
            authoritative = (New-ReviewerCorpusFixtureBinding -Relative 'changes-authoritative.json' -Text ([string]$files['changes-authoritative.json']))
            spanEvidence = (New-ReviewerCorpusFixtureBinding -Relative 'exact-spans.json' -Text ([string]$files['exact-spans.json']))
            digestOrder = @($Identity.AlphaPath, $Identity.BetaPath, $Identity.DeletedPath)
        }
        changedFiles = @(
            [ordered]@{
                path = $Identity.AlphaPath
                changeKinds = @('edit')
                rightHand = (New-ReviewerCorpusFixtureBinding -Relative 'files/alpha.txt' -Text $Content.AlphaText)
                spans = @([ordered]@{ start = 3; count = 4 }, [ordered]@{ start = 20; count = 2 })
            },
            [ordered]@{
                path = $Identity.BetaPath
                changeKinds = @('add')
                rightHand = (New-ReviewerCorpusFixtureBinding -Relative 'files/beta.txt' -Text $Content.BetaText)
                spans = @([ordered]@{ start = 1; count = 24 })
            }
        )
        sourceCensus = [ordered]@{
            authoritativeChangedPathCount = 3
            rightHandCoveredPathCount = 2
            noRightHandPaths = @($Identity.DeletedPath)
        }
        evidence = [ordered]@{
            siblings = @((New-ReviewerCorpusFixtureBinding -Relative 'evidence/sibling.txt' -Text ([string]$files['evidence/sibling.txt'])))
            rules = @((New-ReviewerCorpusFixtureBinding -Relative 'evidence/rules.json' -Text ([string]$files['evidence/rules.json'])))
            threads = @((New-ReviewerCorpusFixtureBinding -Relative 'evidence/threads.json' -Text ([string]$files['evidence/threads.json'])))
            facts = @((New-ReviewerCorpusFixtureBinding -Relative 'evidence/facts.json' -Text ([string]$files['evidence/facts.json'])))
        }
        sourceTransport = [ordered]@{
            kind = 'derivedFromCorpus'
            mode = 'mcpFlat'
            artifactFile = 'source-transport.json'
            policy = [pscustomobject][ordered]@{
                toolkitPath = 'src/Agents/reviewer/source/v1/policy.json'
                sha256 = $Content.PolicySha256
                byteLength = $Content.PolicyBytes.Length
            }
            blockNonce = 'SEALNONCE0001'
            capturedArtifact = $null
            expected = [ordered]@{
                artifactSha256 = ('0' * 64)
                artifactByteLength = 2
                blockSha256 = ('0' * 64)
                coverageRecordSha256 = ('0' * 64)
                gateOk = $true
                gateReasonCodes = @()
            }
        }
        resources = @(
            [ordered]@{
                tool = 'repo_pull_request'
                arguments = [ordered]@{ action = 'get'; project = $Identity.Project; repositoryId = $Identity.RepositoryName; pullRequestId = $Identity.PullRequestId }
                envelope = 'mcpTextContent'
                payloadFile = 'payloads/pr-get.json'
                corpusPayload = (New-ReviewerCorpusFixtureBinding -Relative 'live/pr-get.json' -Text ([string]$files['live/pr-get.json']))
                resourceUri = ''
                mimeType = ''
                expected = [ordered]@{ payloadSha256 = ('0' * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = 'repo_pull_request'
                arguments = [ordered]@{ action = 'get_changes'; project = $Identity.Project; repositoryId = $Identity.RepositoryName; pullRequestId = $Identity.PullRequestId; iterationId = $Identity.IterationId; top = 1000 }
                envelope = 'mcpTextContent'
                payloadFile = 'payloads/changes.json'
                corpusPayload = (New-ReviewerCorpusFixtureBinding -Relative 'live/changes.json' -Text ([string]$files['live/changes.json']))
                resourceUri = ''
                mimeType = ''
                expected = [ordered]@{ payloadSha256 = ('0' * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = 'repo_pull_request_thread'
                arguments = [ordered]@{ action = 'list'; project = $Identity.Project; repositoryId = $Identity.RepositoryName; pullRequestId = $Identity.PullRequestId; top = 200 }
                envelope = 'mcpTextContent'
                payloadFile = 'payloads/threads.json'
                corpusPayload = (New-ReviewerCorpusFixtureBinding -Relative 'live/threads.json' -Text ([string]$files['live/threads.json']))
                resourceUri = ''
                mimeType = ''
                expected = [ordered]@{ payloadSha256 = ('0' * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = 'repo_file'
                arguments = [ordered]@{ action = 'get_content'; project = $Identity.Project; version = $Identity.SourceCommit; versionType = 'Commit'; repositoryId = $Identity.RepositoryId; path = $Identity.AlphaPath }
                envelope = 'mcpResourceContent'
                payloadFile = 'payloads/alpha.json'
                corpusPayload = (New-ReviewerCorpusFixtureBinding -Relative 'files/alpha.txt' -Text $Content.AlphaText)
                resourceUri = "ado://$($Identity.Organization)/$($Identity.Project)/$($Identity.RepositoryId)$($Identity.AlphaPath)"
                mimeType = 'text/plain'
                expected = [ordered]@{ payloadSha256 = ('0' * 64); payloadByteLength = 2 }
            },
            [ordered]@{
                tool = 'repo_file'
                arguments = [ordered]@{ action = 'get_content'; project = $Identity.Project; version = $Identity.SourceCommit; versionType = 'Commit'; repositoryId = $Identity.RepositoryId; path = $Identity.BetaPath }
                envelope = 'mcpTextContent'
                payloadFile = 'payloads/beta.json'
                corpusPayload = (New-ReviewerCorpusFixtureBinding -Relative 'files/beta.txt' -Text $Content.BetaText)
                resourceUri = ''
                mimeType = ''
                expected = [ordered]@{ payloadSha256 = ('0' * 64); payloadByteLength = 2 }
            }
        )
    }
}

function ConvertTo-ReviewerCorpusFixtureRecipeObject {
    param([Parameter(Mandatory)]$Recipe)
    return (($Recipe | ConvertTo-Json -Depth 24) | ConvertFrom-Json -Depth 24)
}

function Resolve-ReviewerCorpusFixtureExpectation {
    <#
    .SYNOPSIS
        Replaces the recipe's placeholder expectations with what the sealer's own
        planner says they must be.

    .DESCRIPTION
        The planner refuses a wrong expectation and names the right one in the
        refusal. Learning them that way rather than recomputing them means the
        fixture cannot declare a digest the sealer disagrees with: if the
        derivation ever changed, this would stop converging instead of silently
        agreeing with a stale copy.
    #>
    param(
        [Parameter(Mandatory)]$Recipe,
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Content
    )

    foreach ($resource in $Recipe.resources) {
        $payload = Get-ReviewerCorpusSealPayload -Index $Index -Path ([string]$resource.corpusPayload.corpusPath)
        $bytes = [byte[]](New-ReviewerCorpusSealEnvelope -Envelope ([string]$resource.envelope) -Payload $payload `
                -ResourceUri ([string]$resource.resourceUri) -MimeType ([string]$resource.mimeType))
        $resource.expected.payloadSha256 = Get-ReviewerCorpusSealSha256 -Bytes $bytes
        $resource.expected.payloadByteLength = $bytes.Length
    }

    $probe = $null
    try {
        $null = New-ReviewerCorpusSealPlan -Index $Index `
            -Recipe (ConvertTo-ReviewerCorpusFixtureRecipeObject -Recipe $Recipe) -ToolkitRoot $ToolkitRoot
    }
    catch { $probe = [string]$_.Exception.Message }
    if (-not $probe) { throw 'Expected the placeholder source-transport expectations to be refused.' }
    if ($probe -notmatch 'sealed source-transport artifact is ([0-9a-f]{64})/(\d+)') {
        throw "Could not learn the sealed source-transport digest from: $probe"
    }
    $Recipe.sourceTransport.expected.artifactSha256 = $Matches[1]
    $Recipe.sourceTransport.expected.artifactByteLength = [int]$Matches[2]

    foreach ($attempt in 1..8) {
        $message = $null
        try {
            $null = New-ReviewerCorpusSealPlan -Index $Index `
                -Recipe (ConvertTo-ReviewerCorpusFixtureRecipeObject -Recipe $Recipe) -ToolkitRoot $ToolkitRoot
            return $Recipe
        }
        catch { $message = [string]$_.Exception.Message }
        if ($message -match 'does not hash to the recipe''s declared blockSha256') {
            $Recipe.sourceTransport.expected.blockSha256 = (Get-ReviewerCorpusFixtureDerivedValue `
                    -Recipe $Recipe -Index $Index -Identity $Identity -Content $Content -Which 'block')
        }
        elseif ($message -match 'does not hash to the recipe''s declared coverageRecordSha256') {
            $Recipe.sourceTransport.expected.coverageRecordSha256 = (Get-ReviewerCorpusFixtureDerivedValue `
                    -Recipe $Recipe -Index $Index -Identity $Identity -Content $Content -Which 'coverage')
        }
        elseif ($message -match 'gate says ok=(True|False)') {
            $Recipe.sourceTransport.expected.gateOk = ($Matches[1] -ceq 'True')
        }
        elseif ($message -match 'gate reason codes differ') {
            $Recipe.sourceTransport.expected.gateReasonCodes = (Get-ReviewerCorpusFixtureDerivedValue `
                    -Recipe $Recipe -Index $Index -Identity $Identity -Content $Content -Which 'reasons')
        }
        else { throw "Unexpected refusal while resolving source-transport expectations: $message" }
    }
    throw 'Could not converge on the source-transport expectations.'
}

function Get-ReviewerCorpusFixtureDerivedValue {
    <#
    .SYNOPSIS
        Re-derives one transport value through the SAME production functions the
        sealer uses, so the fixture declares real digests without copying logic.
    #>
    param(
        [Parameter(Mandatory)]$Recipe,
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Content,
        [Parameter(Mandatory)][ValidateSet('block', 'coverage', 'reasons')][string]$Which
    )
    $policySource = ($script:CorpusFixtureUtf8.GetString($Content.PolicyBytes) | ConvertFrom-Json -Depth 24)
    $policyProperties = [ordered]@{}
    foreach ($property in $policySource.PSObject.Properties) {
        if ($property.Name -ceq '_note') { continue }
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
    $authoritativeJson = ($script:CorpusFixtureUtf8.GetString(
            (Get-ReviewerCorpusSealPayload -Index $Index -Path ([string]$Recipe.changeSet.authoritative.corpusPath)).Bytes) |
            ConvertFrom-Json -Depth 24)
    # Copied into a dictionary declared here rather than bound straight from the
    # command: this map is indexed by path below, and a variable that holds a raw
    # command result is the shape that flattens to a scalar when the result is a
    # single item.
    $authoritativeKinds = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($kindEntry in (Get-ReviewerSourceChangeKindsByPath -Response $authoritativeJson).GetEnumerator()) {
        $authoritativeKinds[$kindEntry.Key] = $kindEntry.Value
    }
    $authoritativePaths = [string[]]@(Get-ReviewerSourceRawChangedPaths -Response $authoritativeJson |
            ForEach-Object { ConvertTo-ReviewerSourcePath -Path ([string]$_) })
    foreach ($path in $authoritativePaths) {
        if (-not $spans.Contains($path)) { $spans[$path] = @() }
        $kinds[$path] = [string[]]@(@($authoritativeKinds[$path]) | ForEach-Object { [string]$_ } |
                Sort-Object -CaseSensitive -Unique)
    }
    $utf8 = $script:CorpusFixtureUtf8
    $reader = {
        param([string]$path)
        if (-not $rightHand.ContainsKey($path)) { return $null }
        $entry = $rightHand[$path]
        return [pscustomobject]@{
            Text = $utf8.GetString($entry.Bytes)
            ByteLength = [int]$entry.ByteLength
            Sha256 = [string]$entry.Sha256
            MimeType = 'text/plain'
        }
    }.GetNewClosure()
    $report = New-ReviewerSourceTransportReport -CommitSha $Identity.SourceCommit `
        -ChangedPaths $authoritativePaths -SpansByPath $spans -Policy $policy -Reader $reader `
        -ChangeKindsByPath $kinds -RecoveryBaseCommit $Identity.CommonCommit `
        -RecoveryIterationId $Identity.IterationId
    switch ($Which) {
        'block' {
            $nonce = [string]$Recipe.sourceTransport.blockNonce
            $blockText = Format-ReviewerSealedSourceBlock -Report $report -NonceFactory { $nonce }.GetNewClosure()
            return (Get-ReviewerSourceSha256 -Text $blockText)
        }
        'coverage' {
            $record = ConvertTo-ReviewerSourceCoverageRecord -Report $report -PolicySha256 $Content.PolicySha256
            return (Get-ReviewerSourceSha256 -Text (ConvertTo-AgentReplayCanonicalJson -Value $record))
        }
        'reasons' {
            $gate = Test-ReviewerSourceCoverageGate -Report $report -Policy $policy
            return [string[]]@($gate.ReasonCodes)
        }
    }
    throw "Unknown derived value '$Which'."
}

function New-ReviewerCorpusSealFixture {
    <#
    .SYNOPSIS
        Builds the corpus and writes the resolved recipe, ready to hand to
        tools/Save-CorpusReplaySeal.ps1.

    .PARAMETER Root
        A directory OUTSIDE the toolkit repository. The sealer refuses a corpus
        inside it, which is the guard that keeps private evidence uncommitted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ToolkitRoot
    )
    $identity = New-ReviewerCorpusFixtureIdentity
    $content = Get-ReviewerCorpusFixtureContent -Identity $identity -ToolkitRoot $ToolkitRoot

    $corpusRoot = Join-Path $Root 'corpus'
    $indexSha = Write-ReviewerCorpusFixtureRoot -Root $corpusRoot -Identity $identity -Content $content
    $index = Import-ReviewerCorpusIndex -CorpusRoot $corpusRoot -ExpectedIndexSha256 $indexSha

    $recipe = New-ReviewerCorpusFixtureRecipe -Identity $identity -Content $content `
        -IndexSha256 $indexSha -PayloadCount $index.PayloadCount
    $recipe = Resolve-ReviewerCorpusFixtureExpectation -Recipe $recipe -Index $index `
        -ToolkitRoot $ToolkitRoot -Identity $identity -Content $content

    $recipePath = Join-Path $Root 'seal-recipe.json'
    [System.IO.File]::WriteAllBytes($recipePath,
        $script:CorpusFixtureUtf8.GetBytes(($recipe | ConvertTo-Json -Depth 24 -Compress:$false)))

    return [pscustomobject][ordered]@{
        Identity = $identity
        CorpusRoot = [string]([IO.Path]::GetFullPath($corpusRoot))
        CorpusIndexSha256 = $indexSha
        RecipePath = [string]([IO.Path]::GetFullPath($recipePath))
        SnapshotName = [string]$recipe.snapshotId
    }
}
