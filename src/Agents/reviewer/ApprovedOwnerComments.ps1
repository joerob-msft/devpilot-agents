#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ApprovedOwnerCapability = 'bpm-test-ownership@1'
$script:ApprovedOwnerWriterVersion = 1
$script:ApprovedOwnerDedupePrefix = 'devpilot-owner-comment:v1'

function Get-ApprovedOwnerValue {
    param($Container, [string]$Name, $Default = $null)
    if ($null -eq $Container) { return $Default }
    if ($Container -is [Collections.IDictionary]) {
        if ($Container.Contains($Name)) { return $Container[$Name] }
        return $Default
    }
    $property = $Container.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-ApprovedOwnerSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant()
}

function ConvertTo-ApprovedOwnerCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    $value = $Path.Trim().Replace('\', '/')
    if (-not $value.StartsWith('/')) { $value = "/$value" }
    if ($value -match '[\x00-\x1f\x7f]' -or $value.Contains('..')) {
        throw "Construct path '$Path' is unsafe."
    }
    return $value
}

function ConvertTo-ApprovedOwnerMarkdownCode {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return (($Text -replace '[\x00-\x1f\x7f]', ' ') -replace '`', '｀').Trim()
}

function Get-ApprovedOwnerFindingId {
    param(
        [Parameter(Mandatory)][string]$HeadKey,
        [Parameter(Mandatory)][string]$RuleRef,
        [Parameter(Mandatory)][string]$ConstructId,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Symbol
    )
    [void]$HeadKey
    [void]$Path
    [void]$Symbol
    return "$script:ApprovedOwnerCapability`:$RuleRef`:$ConstructId"
}

function Get-ApprovedOwnerDedupeKey {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$RuleRef,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Symbol
    )
    $subject = $Evidence.Subject.subject
    $rule = @($Evidence.Subject.rule.sections)[0]
    $ruleIdentity = @(
        [string]$rule.repositoryId, [string]$rule.path, [string]$rule.section,
        [string]$rule.commit, [string]$rule.sha256, $RuleRef
    ) -join '|'
    $material = @(
        $script:ApprovedOwnerCapability
        [string]$script:ApprovedOwnerWriterVersion
        ([string]$subject.repositoryId).ToLowerInvariant()
        [string][int]$subject.pullRequestId
        ([string]$subject.sourceCommit).ToLowerInvariant()
        $ruleIdentity.ToLowerInvariant()
        (ConvertTo-ApprovedOwnerCanonicalPath $Path).ToLowerInvariant()
        $Symbol
    ) -join "`n"
    return Get-ApprovedOwnerSha256 -Text $material
}

function Format-ApprovedOwnerComment {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$Selection
    )
    $rule = @($Evidence.Subject.rule.sections)[0]
    $path = ConvertTo-ApprovedOwnerMarkdownCode ([string]$Selection.path)
    $symbol = ConvertTo-ApprovedOwnerMarkdownCode ([string]$Selection.symbol)
    $rulePath = ConvertTo-ApprovedOwnerMarkdownCode ([string]$rule.path)
    $section = ConvertTo-ApprovedOwnerMarkdownCode ([string]$rule.section)
    return @(
        '**Owner attribute missing**'
        ''
        "Method ``$symbol`` at ``$path`:$([int]$Selection.line)`` is a changed MSTest method and has no ``Owner`` attribute."
        ''
        'Suggested fix: add `[Owner("<owner-alias>")]` to this test method.'
        ''
        "Rule: ``$rulePath`` / ``$section`` at ``$([string]$rule.commit)`` (SHA-256 ``$([string]$rule.sha256)``)."
        ''
        "<!-- ${script:ApprovedOwnerDedupePrefix}:$([string]$Selection.dedupeKey) -->"
    ) -join "`n"
}

function Resolve-ApprovedOwnerLayer1Status {
    param(
        [Parameter(Mandatory)][string]$SubjectRoot,
        [Parameter(Mandatory)][string]$StatusSha256
    )
    if ($StatusSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The signed queue artifact has an invalid Owner preview status digest.'
    }

    $safeSubjectRoot = Assert-OwnerPreviewQueueSafePath -Path $SubjectRoot -Where 'Owner preview subject root'
    $root = Resolve-ReviewerCorpusSealRealPath -Path $safeSubjectRoot -RejectReparsePoints
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "The signed queue artifact subject root '$SubjectRoot' is not a directory."
    }
    $runs = Resolve-ReviewerCorpusSealRealPath -Path (Join-Path $root 'runs') -RejectReparsePoints
    if (-not (Test-Path -LiteralPath $runs -PathType Container) -or
        -not (Test-ReviewerCorpusSealPathWithin -Path $runs -Boundary $root)) {
        throw "The Owner preview runs directory under '$SubjectRoot' is missing or unsafe."
    }

    $statusMatches = @()
    foreach ($child in @(Get-ChildItem -LiteralPath $runs -Directory -Force -ErrorAction Stop)) {
        if ($child.Name -cnotmatch '^[0-9a-f]{64}$') {
            throw "The Owner preview runs directory contains unsafe child '$($child.Name)'."
        }
        $childPath = Resolve-ReviewerCorpusSealRealPath -Path $child.FullName -RejectReparsePoints
        if (-not (Test-ReviewerCorpusSealPathWithin -Path $childPath -Boundary $runs) -or
            -not [string]::Equals(
                [IO.Path]::GetFullPath((Split-Path -Parent $childPath)).TrimEnd('\', '/'),
                [IO.Path]::GetFullPath($runs).TrimEnd('\', '/'),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "The Owner preview run '$($child.Name)' escapes its direct runs child path."
        }

        $statusPath = Join-Path $childPath 'owner-preview-status.json'
        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { continue }
        $resolvedStatusPath = Resolve-ReviewerCorpusSealRealPath -Path $statusPath -RejectReparsePoints
        if (-not (Test-ReviewerCorpusSealPathWithin -Path $resolvedStatusPath -Boundary $childPath) -or
            -not [string]::Equals(
                [IO.Path]::GetFullPath((Split-Path -Parent $resolvedStatusPath)).TrimEnd('\', '/'),
                [IO.Path]::GetFullPath($childPath).TrimEnd('\', '/'),
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "The Owner preview status under '$($child.Name)' escapes its run directory."
        }
        [byte[]]$statusBytes = [IO.File]::ReadAllBytes($resolvedStatusPath)
        $digest = ([Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($statusBytes))).ToLowerInvariant()
        if ($digest -ceq $StatusSha256) {
            $match = [pscustomobject]@{
                    HeadKey = [string]$child.Name
                    Path = $resolvedStatusPath
                    Bytes = $statusBytes
                }
            $statusMatches += $match
        }
    }
    if ($statusMatches.Count -eq 0) {
        throw 'No direct Owner preview run has the status digest from the signed queue artifact.'
    }
    if ($statusMatches.Count -ne 1) {
        throw 'Multiple direct Owner preview runs have the status digest from the signed queue artifact.'
    }
    return $statusMatches[0]
}

function Read-ApprovedOwnerEvidence {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$HeadKey,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $root = Resolve-OwnerPreviewQueueStateRoot -StateRoot $StateRoot -InstanceName ''
    $key = Get-OwnerPreviewQueueKey -StateRoot $root
    $ledger = Read-OwnerPreviewQueueLedger -StateRoot $root -Key $key
    if (-not $ledger.records.Contains($HeadKey)) { throw "No signed ledger record exists for HeadKey '$HeadKey'." }
    $record = $ledger.records[$HeadKey]
    if ([string]$record.state -cne 'completed' -or [string]$record.terminal.status -cne 'completed') {
        throw "HeadKey '$HeadKey' is not a completed preview."
    }
    if ([int]$record.providerWriteCount -ne 0 -or [int]$record.writeToolInvocations -ne 0) {
        throw "HeadKey '$HeadKey' did not complete as a zero-write preview."
    }
    $artifactPath = [string](Get-ApprovedOwnerValue $record 'artifact' '')
    if (-not $artifactPath) { throw "HeadKey '$HeadKey' has no signed queue artifact." }
    $artifact = Read-OwnerPreviewQueueSignedFile -Path $artifactPath -Key $key
    if ([int]$artifact.schemaVersion -ne 1 -or
        [string]$artifact.kind -cne 'reviewer-owner-preview-queue-artifact' -or
        [string]$artifact.capability -cne $script:ApprovedOwnerCapability -or
        [string]$artifact.headKey -cne $HeadKey) {
        throw 'The signed queue artifact has the wrong capability, version, or HeadKey.'
    }

    $subjectRoot = [string]$artifact.subjectRoot
    $resolvedStatus = Resolve-ApprovedOwnerLayer1Status -SubjectRoot $subjectRoot `
        -StatusSha256 ([string]$artifact.statusSha256)
    $layer1HeadKey = [string]$resolvedStatus.HeadKey
    $subjectsRoot = Resolve-ReviewerCorpusSealRealPath -Path (Join-Path $subjectRoot 'subjects') -RejectReparsePoints
    $subjectDirectory = Resolve-ReviewerCorpusSealRealPath -Path (
        Join-Path $subjectsRoot $layer1HeadKey) -RejectReparsePoints
    $subjectPath = Resolve-ReviewerCorpusSealRealPath -Path (
        Join-Path $subjectDirectory 'subject.json') -RejectReparsePoints
    if (-not (Test-Path -LiteralPath $subjectPath -PathType Leaf) -or
        -not (Test-ReviewerCorpusSealPathWithin -Path $subjectDirectory -Boundary $subjectsRoot) -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath((Split-Path -Parent $subjectDirectory)).TrimEnd('\', '/'),
            [IO.Path]::GetFullPath($subjectsRoot).TrimEnd('\', '/'),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath((Split-Path -Parent $subjectPath)).TrimEnd('\', '/'),
            [IO.Path]::GetFullPath($subjectDirectory).TrimEnd('\', '/'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "The prepared subject '$layer1HeadKey' is missing or escapes its direct subject path."
    }
    [byte[]]$subjectBytes = [IO.File]::ReadAllBytes($subjectPath)
    $subject = Read-OwnerPreviewSubject -Root $subjectRoot -HeadKey $layer1HeadKey -SubjectBytes $subjectBytes
    if ([int]$subject.schemaVersion -ne 1 -or
        [string]$subject.kind -cne 'reviewer-owner-preview-subject' -or
        [string]$subject.capability -cne $script:ApprovedOwnerCapability -or
        [string]$subject.headKey -cne $layer1HeadKey) {
        throw 'The prepared subject has the wrong capability or HeadKey.'
    }
    $statusText = [Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$resolvedStatus.Bytes)
    if (-not (Test-Json -Json $statusText -SchemaFile (
                Join-Path $RepoRoot 'src/Agents/reviewer/schemas/reviewer.owner-preview-status.v1.json'
            ) -ErrorAction SilentlyContinue)) {
        throw 'The Owner preview status failed its versioned schema.'
    }
    $status = $statusText | ConvertFrom-Json -Depth 64 -AsHashtable
    if ([int]$status.schemaVersion -ne 1 -or
        [string]$status.capability -cne $script:ApprovedOwnerCapability -or
        [string]$status.headKey -cne $layer1HeadKey -or
        [string]$status.terminal.status -cne 'completed' -or
        [int]$status.spend.providerWriteCount -ne 0 -or [int]$status.spend.writeToolInvocations -ne 0) {
        throw 'The Owner preview status is not a completed, capability-matched, zero-write result.'
    }
    if ([string]$status.subjectKey -cne [string]$subject.subjectKey -or
        [string]$status.subject.organization -cne [string]$subject.subject.organization -or
        [string]$status.subject.project -cne [string]$subject.subject.project -or
        [string]$status.subject.repositoryId -cne [string]$subject.subject.repositoryId -or
        [string]$status.subject.repositoryName -cne [string]$subject.subject.repositoryName -or
        [int]$status.subject.pullRequestId -ne [int]$subject.subject.pullRequestId -or
        [int]$status.subject.iterationId -ne [int]$subject.subject.iterationId -or
        [string]$status.subject.sourceCommit -cne [string]$subject.subject.sourceCommit -or
        [string]$status.subject.targetCommit -cne [string]$subject.subject.targetCommit -or
        [string]$status.snapshot.snapshotId -cne [string]$subject.snapshot.snapshotId -or
        [string]$status.snapshot.manifestDigest -cne [string]$subject.snapshot.manifestDigest -or
        [string]$status.snapshot.sealKind -cne [string]$subject.snapshot.sealKind -or
        [bool]$status.snapshot.nonPromotable -ne [bool]$subject.snapshot.nonPromotable) {
        throw 'The Owner preview status is bound to a different prepared subject.'
    }

    $packageRoot = Resolve-ReviewerCorpusSealRealPath -Path (
        Join-Path (Join-Path (Split-Path -Parent ([string]$resolvedStatus.Path)) 'acquisition') 'package'
    ) -RejectReparsePoints
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container) -or
        -not (Test-ReviewerCorpusSealPathWithin -Path $packageRoot `
            -Boundary (Split-Path -Parent ([string]$resolvedStatus.Path)))) {
        throw "The acquisition package for Layer 1 head '$layer1HeadKey' is missing or unsafe."
    }
    $sealKey = Join-Path (Join-Path (Join-Path $root 'keys') 'layer1') 'acquisition-seal.key'
    $package = Assert-ReviewerAcquisitionTranscriptPackage -PackageRoot $packageRoot -SealKeyPath $sealKey `
        -SchemaPath (Join-Path $RepoRoot 'src/Agents/reviewer/acquisition/v1/transcript-package.schema.json') -RequireCaptured
    $projection = Get-ApprovedOwnerValue $package.Core 'sourceProjection'
    $coverage = Get-ApprovedOwnerValue $projection 'ruleCoverage'
    $binding = Get-ApprovedOwnerValue $projection 'binding'
    $digests = Get-ApprovedOwnerValue $projection 'digests'
    if ([string](Get-ApprovedOwnerValue $projection 'sourceRole' '') -cne 'specialist' -or
        $null -eq $coverage -or -not [bool](Get-ApprovedOwnerValue $coverage 'complete' $false) -or
        [bool](Get-ApprovedOwnerValue $coverage 'constructsIncomplete' $true)) {
        throw 'The signed acquisition package has incomplete or foreign specialist rule coverage.'
    }
    if ([string]$package.Core.snapshotIdentity.sourceCommit -ine [string]$subject.subject.sourceCommit -or
        [string]$package.Core.snapshotIdentity.targetCommit -ine [string]$subject.subject.targetCommit -or
        [int]$package.Core.snapshotIdentity.prId -ne [int]$subject.subject.pullRequestId -or
        [string]$package.Core.snapshotIdentity.repositoryId -ine [string]$subject.subject.repositoryId -or
        [string]$package.Core.snapshotIdentity.project -cne [string]$subject.subject.project -or
        [string]$package.Core.snapshotIdentity.snapshotName -cne [string]$subject.snapshot.snapshotId -or
        [string]$package.Core.snapshotIdentity.manifestDigest -cne [string]$subject.snapshot.manifestDigest -or
        -not [bool]$package.Core.snapshotIdentity.nonPromotable -or
        [string](Get-ApprovedOwnerValue $projection 'sourceModel' '') -cne [string]$subject.model -or
        [int](Get-ApprovedOwnerValue $binding 'prId' 0) -ne [int]$subject.subject.pullRequestId -or
        [string](Get-ApprovedOwnerValue $binding 'repositoryId' '') -ine [string]$subject.subject.repositoryId -or
        [string](Get-ApprovedOwnerValue $binding 'project' '') -cne [string]$subject.subject.project -or
        [string](Get-ApprovedOwnerValue $binding 'sourceCommit' '') -ine [string]$subject.subject.sourceCommit -or
        [string](Get-ApprovedOwnerValue $binding 'targetCommit' '') -ine [string]$subject.subject.targetCommit -or
        [string](Get-ApprovedOwnerValue $digests 'configSha256' '') -cne [string]$subject.configSha256) {
        throw 'The signed acquisition package is bound to a different pull request head.'
    }
    $rule = @($subject.rule.sections)
    if ($rule.Count -ne 1 -or
        [string]$status.rule.path -cne [string]$rule[0].path -or
        [string]$status.rule.section -cne [string]$rule[0].section -or
        [string]$status.rule.commit -ine [string]$rule[0].commit -or
        [string]$status.rule.sha256 -ine [string]$rule[0].sha256 -or
        [int]$status.rule.byteLength -ne [int]$rule[0].byteLength) {
        throw 'The status rule provenance does not match the prepared subject.'
    }
    return [pscustomobject]@{
        StateRoot = $root; Key = $key; Ledger = $ledger; Record = $record
        Artifact = $artifact; Layer1HeadKey = $layer1HeadKey
        Subject = $subject; Status = $status; Package = $package
        Coverage = $coverage
    }
}

function Resolve-ApprovedOwnerSelections {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string[]]$ConstructId,
        [Parameter(Mandatory)][string[]]$FindingId
    )
    if ($ConstructId.Count -lt 1 -or $ConstructId.Count -gt 5 -or $FindingId.Count -ne $ConstructId.Count) {
        throw 'Supply one to five ConstructId values and the same number of exact FindingId values.'
    }
    $constructs = @($Evidence.Coverage.changedConstructs)
    $rows = @($Evidence.Coverage.rows)
    $statusViolations = @($Evidence.Status.violations)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $selected = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $ConstructId.Count; $index++) {
        $id = [string]$ConstructId[$index]
        if (-not $seen.Add($id)) { throw "ConstructId '$id' was selected more than once." }
        $matches = @($constructs | Where-Object { [string]$_.constructId -ceq $id })
        if ($matches.Count -ne 1) { throw "ConstructId '$id' is unknown or ambiguous." }
        $construct = $matches[0]
        if ([string]$construct.kind -cne 'declaration' -or [string]$construct.status -cne 'known') {
            throw "ConstructId '$id' is a helper, invocation, comment, unknown, or incomplete construct."
        }
        $attributes = @($construct.attributes | ForEach-Object { ([string]$_) -replace 'Attribute$', '' })
        if (@($attributes | Where-Object { $_ -ieq 'TestClass' }).Count -gt 0) {
            throw "ConstructId '$id' is a TestClass; class ownership is advisory/shadow-only."
        }
        if (@($attributes | Where-Object { $_ -ieq 'TestMethod' -or $_ -ieq 'DataTestMethod' }).Count -eq 0) {
            throw "ConstructId '$id' is not a TestMethod or DataTestMethod."
        }
        if (@($attributes | Where-Object { $_ -ieq 'Owner' }).Count -gt 0) {
            throw "ConstructId '$id' already carries Owner."
        }
        $violations = @($statusViolations | Where-Object { [string]$_.constructRef -ceq $id })
        if ($violations.Count -ne 1) { throw "ConstructId '$id' is not one exact completed violation." }
        $ruleRef = [string]$violations[0].ruleRef
        $coverageRows = @($rows | Where-Object {
                [string]$_.ruleRef -ceq $ruleRef -and
                [string]$_.ruleSourceSha256 -ieq [string]@($Evidence.Subject.rule.sections)[0].sha256 -and
                @($_.violatingConstructs | Where-Object { [string]$_ -ceq $id }).Count -eq 1
            })
        if ($coverageRows.Count -ne 1) { throw "ConstructId '$id' lacks one complete violating rule row." }
        $path = ConvertTo-ApprovedOwnerCanonicalPath ([string]$construct.path)
        $selection = [ordered]@{
            constructId = $id; ruleRef = $ruleRef; path = $path
            line = [int]$construct.line; symbol = [string]$construct.name
        }
        $selection.findingId = Get-ApprovedOwnerFindingId -HeadKey ([string]$Evidence.Subject.headKey) `
            -RuleRef $ruleRef -ConstructId $id -Path $path -Symbol ([string]$selection.symbol)
        if ([string]$FindingId[$index] -cne [string]$selection.findingId) {
            throw "FindingId for ConstructId '$id' is not exact."
        }
        $selection.dedupeKey = Get-ApprovedOwnerDedupeKey -Evidence $Evidence -RuleRef $ruleRef `
            -Path $path -Symbol ([string]$selection.symbol)
        $selection.body = Format-ApprovedOwnerComment -Evidence $Evidence -Selection $selection
        [void]$selected.Add([pscustomobject]$selection)
    }
    return , $selected.ToArray()
}

function Get-ApprovedOwnerThreadIndex {
    param([AllowEmptyCollection()][object[]]$Threads = @())
    $index = @{}
    foreach ($thread in @($Threads)) {
        $threadId = [int](Get-ApprovedOwnerValue $thread 'threadId' (Get-ApprovedOwnerValue $thread 'id' 0))
        $status = [string](Get-ApprovedOwnerValue $thread 'status' '')
        foreach ($comment in @(Get-ApprovedOwnerValue $thread 'comments' @())) {
            $body = [string](Get-ApprovedOwnerValue $comment 'content' '')
            $match = [regex]::Match($body, '<!--\s*devpilot-owner-comment:v1:([0-9a-f]{64})\s*-->')
            if (-not $match.Success) { continue }
            $key = $match.Groups[1].Value
            if (-not $index.ContainsKey($key)) { $index[$key] = [Collections.Generic.List[object]]::new() }
            [void]$index[$key].Add([pscustomobject]@{ threadId = $threadId; status = $status; body = $body })
        }
    }
    return $index
}

function Test-ApprovedOwnerLiveBinding {
    param([Parameter(Mandatory)]$Evidence, [Parameter(Mandatory)][scriptblock]$Provider)
    $subject = $Evidence.Subject.subject
    $pr = & $Provider 'GetPullRequest' @{ pullRequestId = [int]$subject.pullRequestId }
    if ($null -eq $pr -or [string](Get-ApprovedOwnerValue $pr 'status' '') -ine 'active' -or
        [bool](Get-ApprovedOwnerValue $pr 'isDraft' $false)) { throw 'The pull request is absent, non-active, or draft.' }
    $repository = Get-ApprovedOwnerValue $pr 'repository'
    $repoId = [string](Get-ApprovedOwnerValue $repository 'id' (Get-ApprovedOwnerValue $pr 'repositoryId' ''))
    if ($repoId -ine [string]$subject.repositoryId) { throw 'The live pull request repository does not match the signed subject.' }
    $source = Get-ApprovedOwnerValue $pr 'lastMergeSourceCommit'
    $target = Get-ApprovedOwnerValue $pr 'lastMergeTargetCommit'
    if ([string](Get-ApprovedOwnerValue $source 'commitId' '') -ine [string]$subject.sourceCommit -or
        [string](Get-ApprovedOwnerValue $target 'commitId' '') -ine [string]$subject.targetCommit -or
        [string](Get-ApprovedOwnerValue $pr 'sourceRefName' '') -cne [string]$Evidence.Subject.sourceRefName -or
        [string](Get-ApprovedOwnerValue $pr 'targetRefName' '') -cne [string]$subject.targetRefName) {
        throw 'The live pull request source commit/ref or target commit/ref is stale or foreign.'
    }
    $branch = & $Provider 'GetBranch' @{ refName = [string]$Evidence.Subject.sourceRefName }
    $branchCommit = [string](Get-ApprovedOwnerValue (Get-ApprovedOwnerValue $branch 'commit') 'commitId' (
            Get-ApprovedOwnerValue $branch 'objectId' ''))
    if ($branchCommit -ine [string]$subject.sourceCommit) { throw 'The live source ref head does not match the signed subject.' }
    return $pr
}

function Assert-ApprovedOwnerAnchors {
    param([Parameter(Mandatory)][object[]]$Selections, [Parameter(Mandatory)]$Changes)
    [Collections.IDictionary]$spans = @{}
    if ($Changes -is [Collections.IDictionary] -and $Changes.Contains('SpansByPath')) {
        $spans = $Changes.SpansByPath
    }
    else { $spans = Get-ReviewerSourceChangedSpans -Response $Changes }
    foreach ($selection in $Selections) {
        $entries = @($spans.GetEnumerator() | Where-Object {
                [string]::Equals([string]$_.Key, [string]$selection.path, [StringComparison]::OrdinalIgnoreCase)
            })
        if ($entries.Count -ne 1) { throw "Anchor path '$($selection.path)' is absent or case-ambiguous in the live change set." }
        $line = [int]$selection.line
        if (@($entries[0].Value | Where-Object {
                    $line -ge [int]$_.startLine -and $line -le [int]$_.endLine
                }).Count -ne 1) {
            throw "Anchor '$($selection.path):$line' is not one live changed right-hand line."
        }
    }
}

function Get-ApprovedOwnerThreadEntries {
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$Key)
    if (-not $Index.ContainsKey($Key)) { return , @() }
    return , @($Index.GetEnumerator() | Where-Object { [string]$_.Key -ceq $Key } |
        ForEach-Object { @($_.Value) })
}

function Write-ApprovedOwnerAudit {
    param([string]$StateRoot, [string]$HeadKey, [string]$InvocationId, [string]$Phase, $Payload, [byte[]]$Key)
    $path = Join-Path (Join-Path (Join-Path (Join-Path $StateRoot 'approved-comments') $Phase) $HeadKey) "$InvocationId.json"
    Write-OwnerPreviewQueueImmutableRecord -Path $path -Payload $Payload -Key $Key
    return $path
}

function Repair-ApprovedOwnerInterruptedAudits {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$ThreadIndex
    )
    $headKey = [string]$Evidence.Subject.headKey
    $intentRoot = Join-Path (Join-Path (Join-Path $Evidence.StateRoot 'approved-comments') 'intents') $headKey
    $outcomeRoot = Join-Path (Join-Path (Join-Path $Evidence.StateRoot 'approved-comments') 'outcomes') $headKey
    $reconciled = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $intentRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $outcomePath = Join-Path $outcomeRoot $file.Name
        if (Test-Path -LiteralPath $outcomePath -PathType Leaf) {
            [void](Read-OwnerPreviewQueueSignedFile -Path $outcomePath -Key $Evidence.Key)
            continue
        }
        $intent = Read-OwnerPreviewQueueSignedFile -Path $file.FullName -Key $Evidence.Key
        if ([string]$intent.kind -cne 'reviewer-approved-owner-comment-intent' -or
            [string]$intent.headKey -cne $headKey) {
            throw "Interrupted audit intent '$($file.FullName)' has a foreign identity."
        }
        $present = 0
        foreach ($selection in @($intent.selections)) {
            $key = [string]$selection.dedupeKey
            if ($ThreadIndex.ContainsKey($key) -and
                @($ThreadIndex[$key] | Where-Object {
                        (Get-ApprovedOwnerSha256 -Text ([string]$_.body)) -ceq [string]$selection.bodySha256
                    }).Count -gt 0) { $present++ }
        }
        $payload = [ordered]@{
            schemaVersion = 1; kind = 'reviewer-approved-owner-comment-outcome'
            invocationId = [string]$intent.invocationId; headKey = $headKey
            status = $(if ($present -eq @($intent.selections).Count) { 'reconciled' } else { 'interrupted' })
            providerWrites = 0; confirmedFromThreadSearch = $present
            createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        Write-OwnerPreviewQueueImmutableRecord -Path $outcomePath -Payload $payload -Key $Evidence.Key
        [void]$reconciled.Add($payload)
    }
    return , $reconciled.ToArray()
}

function Invoke-ApprovedOwnerComment {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string[]]$ConstructId,
        [Parameter(Mandatory)][string[]]$FindingId,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)][string]$Reason,
        [switch]$Publish,
        [switch]$ApproveUpdate
    )
    if ([string]::IsNullOrWhiteSpace($Reason) -or $Reason.Length -gt 1024 -or
        $Reason -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') {
        throw 'Reason must be 1-1024 printable characters.'
    }
    $selections = Resolve-ApprovedOwnerSelections -Evidence $Evidence -ConstructId $ConstructId -FindingId $FindingId
    [void](Test-ApprovedOwnerLiveBinding -Evidence $Evidence -Provider $Provider)
    $changes = & $Provider 'GetChanges' @{ pullRequestId = [int]$Evidence.Subject.subject.pullRequestId; iterationId = [int]$Evidence.Subject.subject.iterationId }
    Assert-ApprovedOwnerAnchors -Selections $selections -Changes $changes
    $threads = @(& $Provider 'ListThreads' @{ pullRequestId = [int]$Evidence.Subject.subject.pullRequestId })
    [hashtable]$threadIndex = Get-ApprovedOwnerThreadIndex -Threads $threads
    $reconciled = Repair-ApprovedOwnerInterruptedAudits -Evidence $Evidence -ThreadIndex $threadIndex

    $invocationId = [guid]::NewGuid().ToString('N')
    $intent = [ordered]@{
        schemaVersion = 1; kind = 'reviewer-approved-owner-comment-intent'
        capability = $script:ApprovedOwnerCapability; writerVersion = $script:ApprovedOwnerWriterVersion
        invocationId = $invocationId; headKey = [string]$Evidence.Subject.headKey
        publish = [bool]$Publish; approveUpdate = [bool]$ApproveUpdate; reason = $Reason
        selections = @($selections | ForEach-Object {
                [ordered]@{ constructId = $_.constructId; findingId = $_.findingId; dedupeKey = $_.dedupeKey
                    path = $_.path; line = $_.line; symbol = $_.symbol; body = $_.body
                    bodySha256 = Get-ApprovedOwnerSha256 $_.body }
            })
        createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    }
    $intentPath = Write-ApprovedOwnerAudit -StateRoot $Evidence.StateRoot -HeadKey ([string]$Evidence.Subject.headKey) `
        -InvocationId $invocationId -Phase 'intents' -Payload $intent -Key $Evidence.Key
    $writes = 0
    $results = [Collections.Generic.List[object]]::new()
    try {
        foreach ($selection in $selections) {
            $existing = Get-ApprovedOwnerThreadEntries -Index $threadIndex -Key ([string]$selection.dedupeKey)
            $exact = @($existing | Where-Object { [string]$_.body -ceq [string]$selection.body })
            $collisions = @($existing | Where-Object { [string]$_.body -cne [string]$selection.body -and [string]$_.status -ine 'fixed' })
            if ($exact.Count -gt 0) {
                [void]$results.Add([pscustomobject]@{ findingId = $selection.findingId; outcome = 'noOp'; body = $selection.body; dedupeKey = $selection.dedupeKey })
                continue
            }
            if ($collisions.Count -gt 0 -and -not $ApproveUpdate) {
                throw "Dedupe collision for finding '$($selection.findingId)'; rerun with explicit -ApproveUpdate after reviewing the proposed body."
            }
            if (-not $Publish) {
                [void]$results.Add([pscustomobject]@{ findingId = $selection.findingId; outcome = $(if ($collisions.Count) { 'wouldUpdate' } else { 'wouldCreate' }); body = $selection.body; dedupeKey = $selection.dedupeKey })
                continue
            }
            [void](Test-ApprovedOwnerLiveBinding -Evidence $Evidence -Provider $Provider)
            $freshChanges = & $Provider 'GetChanges' @{
                pullRequestId = [int]$Evidence.Subject.subject.pullRequestId
                iterationId = [int]$Evidence.Subject.subject.iterationId
            }
            Assert-ApprovedOwnerAnchors -Selections @($selection) -Changes $freshChanges
            foreach ($collision in $collisions) {
                & $Provider 'UpdateStatus' @{ pullRequestId = [int]$Evidence.Subject.subject.pullRequestId; threadId = [int]$collision.threadId; status = 'Fixed' } | Out-Null
                $writes++
            }
            & $Provider 'CreateThread' @{
                pullRequestId = [int]$Evidence.Subject.subject.pullRequestId
                content = [string]$selection.body; filePath = [string]$selection.path; line = [int]$selection.line
            } | Out-Null
            $writes++
            $fresh = @(& $Provider 'ListThreads' @{ pullRequestId = [int]$Evidence.Subject.subject.pullRequestId })
            [hashtable]$confirmed = Get-ApprovedOwnerThreadIndex -Threads $fresh
            $confirmedEntries = Get-ApprovedOwnerThreadEntries -Index $confirmed -Key ([string]$selection.dedupeKey)
            if (@($confirmedEntries | Where-Object { [string]$_.body -ceq [string]$selection.body }).Count -lt 1) {
                throw "The provider write for finding '$($selection.findingId)' was not confirmed by read-only thread search."
            }
            [void]$results.Add([pscustomobject]@{ findingId = $selection.findingId; outcome = $(if ($collisions.Count) { 'updated' } else { 'created' }); body = $selection.body; dedupeKey = $selection.dedupeKey })
        }
        $outcome = [ordered]@{
            schemaVersion = 1; kind = 'reviewer-approved-owner-comment-outcome'
            invocationId = $invocationId; headKey = [string]$Evidence.Subject.headKey
            status = 'completed'; providerWrites = $writes; results = $results.ToArray()
            createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        $outcomePath = Write-ApprovedOwnerAudit -StateRoot $Evidence.StateRoot -HeadKey ([string]$Evidence.Subject.headKey) `
            -InvocationId $invocationId -Phase 'outcomes' -Payload $outcome -Key $Evidence.Key
        return [pscustomobject]@{ mode = $(if ($Publish) { 'publish' } else { 'dryRun' }); providerWrites = $writes
            intentPath = $intentPath; outcomePath = $outcomePath; reconciledAudits = @($reconciled)
            results = $results.ToArray() }
    }
    catch {
        $failure = [ordered]@{
            schemaVersion = 1; kind = 'reviewer-approved-owner-comment-outcome'
            invocationId = $invocationId; headKey = [string]$Evidence.Subject.headKey
            status = 'failed'; providerWrites = $writes; diagnostic = [string]$_.Exception.Message
            results = $results.ToArray(); createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        [void](Write-ApprovedOwnerAudit -StateRoot $Evidence.StateRoot -HeadKey ([string]$Evidence.Subject.headKey) `
                -InvocationId $invocationId -Phase 'outcomes' -Payload $failure -Key $Evidence.Key)
        throw
    }
}
