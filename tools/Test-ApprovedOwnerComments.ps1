#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $RepoRoot 'src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1') -Force
. (Join-Path $RepoRoot 'src/Agents/reviewer/CorpusSeal.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/AcquisitionPackage.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/SourceTransport.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewSubject.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewReport.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewQueue.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ApprovedOwnerComments.ps1')

$script:Checks = 0
$script:Failures = [Collections.Generic.List[string]]::new()

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:Checks++
    if ($Condition) { Write-Host "PASS - $Name" -ForegroundColor Green }
    else {
        [void]$script:Failures.Add("$Name$(if ($Detail) { ": $Detail" } else { '' })")
        Write-Host "FAIL - $Name $Detail" -ForegroundColor Red
    }
}

function Refuses {
    param([string]$Name, [scriptblock]$Action, [string]$Pattern)
    $message = ''
    try { & $Action | Out-Null } catch { $message = [string]$_.Exception.Message }
    Check $Name ($message -match $Pattern) $message
}

function New-Evidence {
    param(
        [string]$Kind = 'TestMethod',
        [string[]]$Attributes = @('TestMethod'),
        [string]$Status = 'known',
        [string]$Path = '/tests/WidgetTests.cs',
        [string]$Symbol = 'Creates_widget',
        [string]$ConstructId = 'dc0',
        [bool]$Complete = $true,
        [bool]$ConstructsIncomplete = $false
    )
    $head = '1' * 64
    return [pscustomobject]@{
        StateRoot = $script:TestRoot
        Key = [byte[]](1..32)
        Subject = [ordered]@{
            capability = 'bpm-test-ownership@1'; headKey = $head
            sourceRefName = 'refs/heads/feature/owner'
            subject = [ordered]@{
                organization = 'contoso'; project = 'Widgets'; repositoryId = '11111111-2222-3333-4444-555555555555'
                repositoryName = 'WidgetRepo'; pullRequestId = 117; iterationId = 4
                sourceCommit = ('a' * 40); targetCommit = ('b' * 40); targetRefName = 'refs/heads/main'
            }
            rule = [ordered]@{ sections = @([ordered]@{
                        repositoryId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                        branch = 'refs/heads/main'; path = '/docs/AutomatedTests.md'
                        section = '## Claim ownership'; commit = ('c' * 40); sha256 = ('d' * 64); byteLength = 123
                    }) }
        }
        Status = [ordered]@{
            capability = 'bpm-test-ownership@1'; headKey = $head
            violations = @([ordered]@{ ruleRef = 'rs0'; constructRef = $ConstructId })
        }
        Coverage = [ordered]@{
            complete = $Complete; constructsIncomplete = $ConstructsIncomplete
            changedConstructs = @([ordered]@{
                    constructId = $ConstructId; kind = $(if ($Kind -eq 'helper') { 'invocation' } else { 'declaration' })
                    path = $Path; line = 27; endLine = 27; name = $Symbol; attributes = $Attributes; status = $Status
                })
            rows = @([ordered]@{ ruleRef = 'rs0'; ruleSourceSha256 = ('d' * 64); violatingConstructs = @($ConstructId) })
        }
    }
}

function Write-TestApprovedOwnerAcquisitionPackage {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$SealKeyPath,
        [Parameter(Mandatory)]$Subject
    )
    [void](New-Item -ItemType Directory -Force -Path $PackageRoot)
    $keyRoot = Split-Path -Parent $SealKeyPath
    [void](New-Item -ItemType Directory -Force -Path $keyRoot)
    $key = [byte[]](33..64)
    [IO.File]::WriteAllBytes($SealKeyPath, $key)

    $nonce = '0123456789abcdef'
    $usage = [ordered]@{
        reported = $false
        premiumRequests = $null
        totalApiDurationMs = $null
        sessionDurationMs = $null
        totalNanoAiu = $null
        totalPremiumRequests = $null
        unavailable = $true
    }
    $attempt = [ordered]@{
        attempt = 1
        nonce = $nonce
        nonceSha256 = '1' * 64
        markerStatus = 'success'
        retryable = $false
        modelRan = $true
        exitCode = 0
        timedOut = $false
        reason = ''
        detail = ''
        durationMs = 1
        usage = $usage
    }
    $snapshotIdentity = [ordered]@{
        snapshotName = [string]$Subject.snapshot.snapshotId
        manifestDigest = [string]$Subject.snapshot.manifestDigest
        prId = [int]$Subject.subject.pullRequestId
        repositoryId = [string]$Subject.subject.repositoryId
        project = [string]$Subject.subject.project
        sourceCommit = [string]$Subject.subject.sourceCommit
        targetCommit = [string]$Subject.subject.targetCommit
        changeSetDigest = '2' * 64
        nonPromotable = $true
    }
    $core = [ordered]@{
        role = 'specialist'
        requestedModel = [string]$Subject.model
        reportedModel = [string]$Subject.model
        secondGeneralistModel = 'gpt-5.6-sol'
        conventionSpecialistEnabled = $true
        conventionSpecialistModel = [string]$Subject.model
        nonce = $nonce
        resultMarkerPrefix = 'CONVENTION_REVIEW_RESULT_V4:'
        terminalStatus = 'captured'
        attempts = @($attempt)
        timings = [ordered]@{
            startedUtc = '2026-09-06T00:00:00Z'
            endedUtc = '2026-09-06T00:00:00.001Z'
            totalDurationMs = 1
        }
        snapshotIdentity = $snapshotIdentity
        sourceProjection = [ordered]@{
            sourceRole = 'specialist'
            sourceModel = [string]$Subject.model
            binding = [ordered]@{
                prId = [int]$Subject.subject.pullRequestId
                repositoryId = [string]$Subject.subject.repositoryId
                project = [string]$Subject.subject.project
                sourceCommit = [string]$Subject.subject.sourceCommit
                targetCommit = [string]$Subject.subject.targetCommit
            }
            digests = [ordered]@{ configSha256 = [string]$Subject.configSha256 }
            ruleCoverage = (New-Evidence).Coverage
        }
    }
    $coreText = ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText (
        $core | ConvertTo-Json -Depth 64 -Compress)
    $markerText = 'CONVENTION_REVIEW_RESULT_V4: {}'
    $corePath = Join-Path $PackageRoot 'capture-core.json'
    $markerPath = Join-Path $PackageRoot 'result-marker.txt'
    [IO.File]::WriteAllText($corePath, $coreText, $script:ReviewerAcquisitionPackageUtf8)
    [IO.File]::WriteAllText($markerPath, $markerText, $script:ReviewerAcquisitionPackageUtf8)

    $manifest = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-blinded-transcript-package'
        planId = '0123456789abcdef'
        role = [string]$core.role
        reportedModel = [string]$core.reportedModel
        requestedModel = [string]$core.requestedModel
        secondGeneralistModel = [string]$core.secondGeneralistModel
        conventionSpecialistEnabled = [bool]$core.conventionSpecialistEnabled
        conventionSpecialistModel = [string]$core.conventionSpecialistModel
        nonce = $nonce
        nonceSha256 = '1' * 64
        resultMarkerPrefix = [string]$core.resultMarkerPrefix
        files = @(
            [ordered]@{
                name = 'capture-core.json'
                sha256 = Get-ReviewerAcquisitionPackageFileSha256 -Path $corePath
                bytes = [long]@(Get-Item -LiteralPath $corePath)[0].Length
            },
            [ordered]@{
                name = 'result-marker.txt'
                sha256 = Get-ReviewerAcquisitionPackageFileSha256 -Path $markerPath
                bytes = [long]@(Get-Item -LiteralPath $markerPath)[0].Length
            }
        )
        directories = @()
        digests = [ordered]@{
            fixtureProjectionSha256 = '3' * 64
            requestSha256 = '4' * 64
            inputSha256 = '5' * 64
            promptSha256 = '6' * 64
            schemaSha256 = '7' * 64
            configSha256 = [string]$Subject.configSha256
            scriptSha256 = '8' * 64
            snapshotManifestDigest = [string]$Subject.snapshot.manifestDigest
        }
        snapshotIdentity = $snapshotIdentity
        attempts = @($attempt)
        usage = $usage
        telemetry = [ordered]@{
            mode = 'production-test-only'
            fileExists = $true
            sinkBytes = 1
            sinkSha256 = '9' * 64
            totalEvents = 1
            modelSubprocessStarts = 1
            realModelStarts = 0
            providerLiveProcessStarts = 0
            providerLiveWrites = 0
            writeToolInvocations = 0
            zeroWriteVerified = $true
        }
        timings = $core.timings
        terminalStatus = [string]$core.terminalStatus
        createdUtc = '2026-09-06T00:00:00Z'
    }
    $manifestText = ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText (
        $manifest | ConvertTo-Json -Depth 64 -Compress)
    $manifestPath = Join-Path $PackageRoot 'transcript-package.json'
    [IO.File]::WriteAllText($manifestPath, $manifestText, $script:ReviewerAcquisitionPackageUtf8)
    $seal = [ordered]@{
        kind = 'reviewer-blinded-transcript-package-seal'
        manifestHmac = Get-ReviewerAcquisitionPackageHmac -Text $manifestText -Key $key
        manifestSha256 = Get-ReviewerAcquisitionPackageTextSha256 -Text $manifestText
        schemaVersion = 1
        sealedUtc = '2026-09-06T00:00:00Z'
    }
    $sealText = ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText (
        $seal | ConvertTo-Json -Depth 8 -Compress)
    $sealPath = Join-Path $PackageRoot 'transcript-package.seal'
    [IO.File]::WriteAllText($sealPath, $sealText, $script:ReviewerAcquisitionPackageUtf8)
    foreach ($path in @($corePath, $markerPath, $manifestPath, $sealPath)) {
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::ReadOnly)
    }
}

function New-SignedEvidenceFixture {
    param(
        [string]$QueueHeadKey = '',
        [string]$ArtifactStatusSha256 = '',
        [scriptblock]$MutateStatus,
        [switch]$CreateValidPackage
    )
    $state = Join-Path $script:TestRoot ("signed-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Force -Path $state)
    $key = Get-OwnerPreviewQueueKey $state
    $subjectRoot = Join-Path $state 'subjects-source'

    $subject = (New-Evidence).Subject
    $subject.subjectKey = Get-OwnerPreviewSubjectKey contoso Widgets '11111111-2222-3333-4444-555555555555' 117
    $subject.configSha256 = 'e' * 64
    $subject.toolkitHead = 'f' * 40
    $subject.model = 'claude-sonnet-5'
    $subject.snapshot = [ordered]@{
        snapshotId = 'snapshot'
        manifestDigest = '3' * 64
        sealKind = 'offlineCorpusSeal'
        nonPromotable = $true
    }
    $subject.headKey = Get-OwnerPreviewHeadKey $subject.subjectKey $subject.subject.sourceCommit @($subject.rule.sections) `
        $subject.snapshot.manifestDigest $subject.model $subject.configSha256 $subject.toolkitHead
    $layer1HeadKey = [string]$subject.headKey
    $subject.schemaVersion = 1
    $subject.kind = 'reviewer-owner-preview-subject'
    $subjectDir = Join-Path (Join-Path $subjectRoot 'subjects') $layer1HeadKey
    $runDir = Join-Path (Join-Path $subjectRoot 'runs') $layer1HeadKey
    [void](New-Item -ItemType Directory -Force -Path $subjectDir)
    [void](New-Item -ItemType Directory -Force -Path $runDir)
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $runDir 'acquisition/package'))
    [void](Write-OwnerPreviewJsonFile (Join-Path $subjectDir 'subject.json') $subject)

    $status = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-owner-preview-status'
        capability = 'bpm-test-ownership@1'
        subjectKey = $subject.subjectKey
        headKey = $layer1HeadKey
        subject = [ordered]@{
            organization = $subject.subject.organization
            project = $subject.subject.project
            repositoryId = $subject.subject.repositoryId
            repositoryName = $subject.subject.repositoryName
            pullRequestId = $subject.subject.pullRequestId
            iterationId = $subject.subject.iterationId
            sourceCommit = $subject.subject.sourceCommit
            targetCommit = $subject.subject.targetCommit
        }
        rule = [ordered]@{
            path = $subject.rule.sections[0].path
            commit = $subject.rule.sections[0].commit
            sha256 = $subject.rule.sections[0].sha256
            byteLength = $subject.rule.sections[0].byteLength
            section = $subject.rule.sections[0].section
        }
        snapshot = [ordered]@{
            snapshotId = $subject.snapshot.snapshotId
            manifestDigest = $subject.snapshot.manifestDigest
            sealKind = $subject.snapshot.sealKind
            nonPromotable = $subject.snapshot.nonPromotable
        }
        counts = [ordered]@{ checked = 1; violations = 1; compliant = 0; unknown = 0; notInReach = 0; notRouted = 0 }
        violations = @([ordered]@{ ruleRef = 'rs0'; constructRef = 'dc0' })
        terminal = [ordered]@{ status = 'completed'; markerStatus = 'success'; contractVersion = 4 }
        spend = [ordered]@{
            attempts = 1
            modelStarts = 1
            providerWriteCount = 0
            writeToolInvocations = 0
            generalistModelStarts = 0
        }
        createdUtc = '2026-09-06T00:00:00Z'
    }
    if ($null -ne $MutateStatus) { & $MutateStatus $status $layer1HeadKey }
    $statusPath = Join-Path $runDir 'owner-preview-status.json'
    [void](Write-OwnerPreviewJsonFile $statusPath $status)

    $queueHeadKey = if ($QueueHeadKey) { $QueueHeadKey } else { $layer1HeadKey }
    $statusSha256 = if ($ArtifactStatusSha256) {
        $ArtifactStatusSha256
    }
    else {
        Get-OwnerPreviewFileSha256 $statusPath
    }
    $artifactPath = Join-Path (Join-Path (Join-Path $state 'artifacts') $queueHeadKey) 'attempt-001.json'
    $artifact = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-owner-preview-queue-artifact'
        capability = 'bpm-test-ownership@1'
        headKey = $queueHeadKey
        attempt = 1
        subjectRoot = $subjectRoot
        statusSha256 = $statusSha256
        createdUtc = '20260906T000000Z'
    }
    Write-OwnerPreviewQueueImmutableRecord $artifactPath $artifact $key
    $ledger = New-OwnerPreviewQueueLedger
    $ledger.records[$queueHeadKey] = [ordered]@{
        state = 'completed'
        terminal = [ordered]@{ status = 'completed' }
        providerWriteCount = 0
        writeToolInvocations = 0
        artifact = $artifactPath
    }
    Save-OwnerPreviewQueueLedger $state $ledger $key
    $acquisitionKeyPath = Get-OwnerPreviewSealKeyPath -Name 'acquisition' `
        -SealKeyRoot (Join-Path (Join-Path $state 'keys') 'layer1')
    if ($CreateValidPackage) {
        Write-TestApprovedOwnerAcquisitionPackage -PackageRoot (Join-Path $runDir 'acquisition/package') `
            -SealKeyPath $acquisitionKeyPath -Subject $subject
    }
    return [pscustomobject]@{
        State = $state
        Key = $key
        AcquisitionKeyPath = $acquisitionKeyPath
        SubjectRoot = $subjectRoot
        QueueHeadKey = $queueHeadKey
        Layer1HeadKey = $layer1HeadKey
        RunDir = $runDir
        Status = $status
        StatusPath = $statusPath
        ArtifactPath = $artifactPath
    }
}

function New-FakeProvider {
    param([switch]$FailCreate, [switch]$Stale, [switch]$Foreign, [switch]$BadAnchor)
    $script:ProviderCalls = [Collections.Generic.List[string]]::new()
    $script:ProviderThreads = [Collections.Generic.List[object]]::new()
    $script:ProviderFailCreate = [bool]$FailCreate
    $script:ProviderStale = [bool]$Stale
    $script:ProviderForeign = [bool]$Foreign
    $script:ProviderBadAnchor = [bool]$BadAnchor
    return {
        param([string]$Action, [hashtable]$Arguments)
        [void]$script:ProviderCalls.Add($Action)
        switch ($Action) {
            'GetPullRequest' {
                return [ordered]@{
                    status = 'active'; isDraft = $false
                    repository = [ordered]@{ id = $(if ($script:ProviderForeign) { '99999999-9999-9999-9999-999999999999' } else { '11111111-2222-3333-4444-555555555555' }) }
                    sourceRefName = 'refs/heads/feature/owner'; targetRefName = 'refs/heads/main'
                    lastMergeSourceCommit = [ordered]@{ commitId = $(if ($script:ProviderStale) { '9' * 40 } else { 'a' * 40 }) }
                    lastMergeTargetCommit = [ordered]@{ commitId = 'b' * 40 }
                }
            }
            'GetBranch' { return [ordered]@{ objectId = $(if ($script:ProviderStale) { '9' * 40 } else { 'a' * 40 }) } }
            'GetChanges' {
                $path = if ($script:ProviderBadAnchor) { '/tests/Other.cs' } else { '/TESTS/WIDGETTESTS.CS' }
                return [ordered]@{ SpansByPath = [ordered]@{ $path = @([ordered]@{ startLine = 27; endLine = 27 }) } }
            }
            'ListThreads' { return $script:ProviderThreads.ToArray() }
            'CreateThread' {
                if ($script:ProviderFailCreate) { throw 'fake provider create failure' }
                [void]$script:ProviderThreads.Add([ordered]@{
                        id = 100 + $script:ProviderThreads.Count; status = 'active'
                        filePath = [string]$Arguments.filePath; line = [int]$Arguments.line
                        comments = @([ordered]@{ content = [string]$Arguments.content })
                    })
                return 'created'
            }
            'UpdateStatus' {
                foreach ($thread in $script:ProviderThreads) {
                    if ([int](Get-ApprovedOwnerValue $thread 'id' 0) -eq [int]$Arguments.threadId) {
                        $thread.status = 'fixed'
                    }
                }
                return 'updated'
            }
            default { throw "unexpected fake action $Action" }
        }
    }
}

$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($local)) { $local = $HOME }
$script:TestRoot = Join-Path (Join-Path $local 'DevPilotTests') ("approved-owner-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Force -Path $script:TestRoot)

try {
    $evidence = New-Evidence
    $productionCoverage = Resolve-ReviewerConventionSpecialistRuleCoverage -Rows @([ordered]@{
            ruleRef = 'rs0'; ruleSourceSha256 = ('d' * 64); status = 'violation'; scope = 'declaration'
            violatingConstructs = 'dc0'; compliantConstructs = ''; notInReachConstructs = ''; unknownConstructs = ''
            violatingChangedFileTargets = ''; codeEvidence = 'changed method'; siblingStatus = 'notRequired'
            siblingEvidence = ''; candidateId = ''; notes = ''
        }) -ResolvedSources @([ordered]@{
            PackName = 'bpm-test-ownership'; SourceId = 'claim-owner'; Sha256 = ('d' * 64)
            Section = '## Claim ownership'; Text = "## Claim ownership`nUse Owner."
        }) -AcceptedCandidates @() -Constructs @([ordered]@{
            constructId = 'dc0'; kind = 'declaration'; path = '/tests/WidgetTests.cs'
            line = 27; endLine = 27; name = 'Creates_widget'; attributes = @('TestMethod'); status = 'known'
        })
    Check 'production coverage preserves method eligibility facts' (
        [string]$productionCoverage.Constructs[0].status -ceq 'known' -and
        @($productionCoverage.Constructs[0].attributes).Count -eq 1 -and
        [string]$productionCoverage.Constructs[0].attributes[0] -ceq 'TestMethod')
    $finding = Get-ApprovedOwnerFindingId -HeadKey $evidence.Subject.headKey -RuleRef 'rs0' `
        -ConstructId 'dc0' -Path '/tests/WidgetTests.cs' -Symbol 'Creates_widget'

    $provider = New-FakeProvider
    $dry = Invoke-ApprovedOwnerComment -Evidence $evidence -ConstructId dc0 -FindingId $finding `
        -Provider $provider -Reason 'human checked preview'
    Check 'valid dry-run proposes exact body' ($dry.mode -ceq 'dryRun' -and $dry.providerWrites -eq 0 -and
        @($dry.results).Count -eq 1 -and [string]$dry.results[0].outcome -ceq 'wouldCreate' -and
        [string]$dry.results[0].body -match 'Owner attribute missing')
    Check 'dry-run performs zero provider writes' (@($script:ProviderCalls | Where-Object { $_ -in @('CreateThread', 'UpdateStatus') }).Count -eq 0)

    $provider = New-FakeProvider
    $write = Invoke-ApprovedOwnerComment -Evidence $evidence -ConstructId dc0 -FindingId $finding `
        -Provider $provider -Reason 'approved after code inspection' -Publish
    Check 'exact fake write is confirmed' ($write.providerWrites -eq 1 -and $write.results[0].outcome -ceq 'created' -and
        @($script:ProviderCalls | Where-Object { $_ -ceq 'CreateThread' }).Count -eq 1)
    Check 'fixed body has no global review fields' ($write.results[0].body -notmatch '(?i)severity|vote|passed|summary|rationale')
    Check 'fixed body carries authoritative provenance' ($write.results[0].body -match 'AutomatedTests\.md' -and
        $write.results[0].body -match ('c' * 40) -and $write.results[0].body -match ('d' * 64))

    Refuses 'TestClass is advisory-only' {
        $x = New-Evidence -Attributes @('TestClass'); $id = Get-ApprovedOwnerFindingId $x.Subject.headKey rs0 dc0 $x.Coverage.changedConstructs[0].path $x.Coverage.changedConstructs[0].name
        Resolve-ApprovedOwnerSelections $x @('dc0') @($id)
    } 'TestClass'
    Refuses 'helper is refused' {
        $x = New-Evidence -Kind helper -Attributes @(); Resolve-ApprovedOwnerSelections $x @('dc0') @('x')
    } 'helper|invocation'
    Refuses 'unknown construct is refused' {
        $x = New-Evidence -Status unknown; Resolve-ApprovedOwnerSelections $x @('dc0') @('x')
    } 'unknown|incomplete'
    Refuses 'withheld finding is refused' {
        $x = New-Evidence; $x.Status.violations = @(); Resolve-ApprovedOwnerSelections $x @('dc0') @('x')
    } 'not one exact completed violation'
    Refuses 'existing Owner is refused' {
        $x = New-Evidence -Attributes @('TestMethod','Owner'); Resolve-ApprovedOwnerSelections $x @('dc0') @('x')
    } 'already carries Owner'
    $dataTest = New-Evidence -Attributes @('DataTestMethod')
    $dataId = Get-ApprovedOwnerFindingId $dataTest.Subject.headKey rs0 dc0 $dataTest.Coverage.changedConstructs[0].path $dataTest.Coverage.changedConstructs[0].name
    $dataSelection = Resolve-ApprovedOwnerSelections $dataTest @('dc0') @($dataId)
    Check 'DataTestMethod is eligible' (@($dataSelection).Count -eq 1)
    Refuses 'rule provenance mismatch is refused' {
        $x = New-Evidence; $x.Coverage.rows[0].ruleSourceSha256 = '0' * 64
        Resolve-ApprovedOwnerSelections $x @('dc0') @('x')
    } 'rule row'
    Refuses 'incomplete coverage is refused' {
        $x = New-Evidence -Complete:$false; $x.Coverage = $null
        Resolve-ApprovedOwnerSelections $x @('dc0') @('x')
    } 'null|property|coverage'
    Refuses 'tampered finding id is refused' {
        Resolve-ApprovedOwnerSelections $evidence @('dc0') @('bpm-test-ownership@1:rs0:dc9')
    } 'not exact'
    Refuses 'foreign repository is refused' {
        $p = New-FakeProvider -Foreign; Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $p 'approved'
    } 'repository'
    Refuses 'stale source head is refused' {
        $p = New-FakeProvider -Stale; Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $p 'approved'
    } 'stale|foreign'
    Refuses 'missing live changed-line anchor is refused' {
        $p = New-FakeProvider -BadAnchor; Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $p 'approved'
    } 'Anchor path'
    Refuses 'selection cap is enforced' {
        Resolve-ApprovedOwnerSelections $evidence @('dc0','dc1','dc2','dc3','dc4','dc5') @('a','b','c','d','e','f')
    } 'one to five'

    $injected = New-Evidence -Path '/tests/[x](bad).cs' -Symbol 'Bad`n`# heading'
    $injectedId = Get-ApprovedOwnerFindingId $injected.Subject.headKey rs0 dc0 $injected.Coverage.changedConstructs[0].path $injected.Coverage.changedConstructs[0].name
    $injectedSelections = Resolve-ApprovedOwnerSelections $injected @('dc0') @($injectedId)
    $selection = @($injectedSelections)[0]
    Check 'Markdown injection is neutralized' ($selection.body -notmatch "`n# heading" -and $selection.body -notmatch 'Bad`n')

    $provider = New-FakeProvider
    $caseDry = Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $provider 'case check'
    Check 'path case is canonical for live anchor' ($caseDry.results[0].outcome -ceq 'wouldCreate')

    $provider = New-FakeProvider
    $previewSelections = Resolve-ApprovedOwnerSelections $evidence @('dc0') @($finding)
    $preview = @($previewSelections)[0]
    [void]$script:ProviderThreads.Add([ordered]@{ id = 7; status = 'active'; comments = @([ordered]@{ content = $preview.body }) })
    $duplicate = Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $provider 'dedupe'
    Check 'same dedupe key and body is a no-op' ($duplicate.providerWrites -eq 0 -and $duplicate.results[0].outcome -ceq 'noOp')

    $provider = New-FakeProvider
    [void]$script:ProviderThreads.Add([ordered]@{ id = 8; status = 'active'; comments = @([ordered]@{
                    content = "different`n<!-- devpilot-owner-comment:v1:$($preview.dedupeKey) -->"
                }) })
    Refuses 'dedupe collision is refused' {
        Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $provider 'collision'
    } 'collision'
    $updated = Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $provider 'approved update' -Publish -ApproveUpdate
    Check 'explicit approved update closes collision and creates exact body' ($updated.providerWrites -eq 2 -and
        $updated.results[0].outcome -ceq 'updated' -and
        @($script:ProviderCalls | Where-Object { $_ -ceq 'UpdateStatus' }).Count -eq 1)

    Refuses 'provider failure is audited and surfaced' {
        $p = New-FakeProvider -FailCreate
        Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $p 'approved' -Publish
    } 'fake provider create failure'

    $provider = New-FakeProvider
    [void]$script:ProviderThreads.Add([ordered]@{ id = 9; status = 'active'; comments = @([ordered]@{ content = $preview.body }) })
    $oldId = [guid]::NewGuid().ToString('N')
    $oldIntent = [ordered]@{
        schemaVersion = 1; kind = 'reviewer-approved-owner-comment-intent'; invocationId = $oldId
        headKey = $evidence.Subject.headKey; selections = @([ordered]@{
                dedupeKey = $preview.dedupeKey; bodySha256 = Get-ApprovedOwnerSha256 $preview.body
            })
    }
    [void](Write-ApprovedOwnerAudit $evidence.StateRoot $evidence.Subject.headKey $oldId 'intents' $oldIntent $evidence.Key)
    $recovery = Invoke-ApprovedOwnerComment $evidence @('dc0') @($finding) $provider 'reconcile'
    Check 'interrupted intent is reconciled by read-only thread search' (@($recovery.reconciledAudits).Count -eq 1 -and
        [string]$recovery.reconciledAudits[0].status -ceq 'reconciled')

    $schedulerText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'tools/Invoke-OwnerPreviewQueue.ps1'))
    $queueText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewQueue.ps1'))
    Check 'hourly scheduler cannot invoke writer' ($schedulerText -notmatch 'ApprovedOwnerComment' -and
        $queueText -notmatch 'ApprovedOwnerComment' -and
        $schedulerText.Contains("ValidateSet('run', 'status', 'requeue'"))
    $commandText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'tools/Invoke-ApprovedOwnerComment.ps1'))
    Check 'operator command requires explicit approval and defaults dry-run' ($commandText -match '\[Parameter\(Mandatory\)\]\[switch\]\$Approve' -and
        $commandText -match '\[switch\]\$Publish' -and $commandText -notmatch 'ConfigFile')

    $productionKey = New-SignedEvidenceFixture -QueueHeadKey ('9' * 64) -CreateValidPackage
    $productionRead = Read-ApprovedOwnerEvidence $productionKey.State $productionKey.QueueHeadKey $RepoRoot
    Check 'production acquisition key filename verifies distinct queue and Layer1 evidence' (
        [IO.Path]::GetFileName($productionKey.AcquisitionKeyPath) -ceq 'owner-preview-acquisition.key' -and
        $productionRead.Layer1HeadKey -ceq $productionKey.Layer1HeadKey -and
        $productionRead.Layer1HeadKey -cne $productionKey.QueueHeadKey -and
        [Convert]::ToBase64String([byte[]]$productionKey.Key) -cne
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($productionKey.AcquisitionKeyPath)))

    $wrongProductionKey = New-SignedEvidenceFixture -QueueHeadKey ('8' * 64) -CreateValidPackage
    [IO.File]::WriteAllBytes($wrongProductionKey.AcquisitionKeyPath, ([byte[]](65..96)))
    Refuses 'wrong production acquisition key is refused' {
        Read-ApprovedOwnerEvidence $wrongProductionKey.State $wrongProductionKey.QueueHeadKey $RepoRoot
    } 'HMAC seal does not match'

    $missingProductionKey = New-SignedEvidenceFixture -QueueHeadKey ('7' * 64) -CreateValidPackage
    Remove-Item -LiteralPath $missingProductionKey.AcquisitionKeyPath -Force
    Refuses 'missing production acquisition key is refused' {
        Read-ApprovedOwnerEvidence $missingProductionKey.State $missingProductionKey.QueueHeadKey $RepoRoot
    } 'owner-preview-acquisition\.key'

    $alternateProductionKey = New-SignedEvidenceFixture -QueueHeadKey ('6' * 64) -CreateValidPackage
    Move-Item -LiteralPath $alternateProductionKey.AcquisitionKeyPath `
        -Destination (Join-Path (Split-Path -Parent $alternateProductionKey.AcquisitionKeyPath) 'acquisition-seal.key')
    Refuses 'alternate acquisition key filename is not an ambiguous fallback' {
        Read-ApprovedOwnerEvidence $alternateProductionKey.State $alternateProductionKey.QueueHeadKey $RepoRoot
    } 'owner-preview-acquisition\.key'

    # Signed evidence checks use real queue HMACs and a narrow package-verifier
    # substitution; acquisition package HMAC coverage is already exercised by
    # Test-ReviewerBlindedAcquisition, while this verifies the new reader's joins.
    $realPackageVerifier = ${function:Assert-ReviewerAcquisitionTranscriptPackage}
    function Assert-ReviewerAcquisitionTranscriptPackage {
        return [pscustomobject]@{ Core = [ordered]@{
                sourceProjection = [ordered]@{
                    sourceRole = 'specialist'
                    sourceModel = 'claude-sonnet-5'
                    binding = [ordered]@{
                        prId = 117
                        repositoryId = '11111111-2222-3333-4444-555555555555'
                        project = 'Widgets'
                        sourceCommit = 'a' * 40
                        targetCommit = 'b' * 40
                    }
                    digests = [ordered]@{ configSha256 = 'e' * 64 }
                    ruleCoverage = (New-Evidence).Coverage
                }
                snapshotIdentity = [ordered]@{
                    snapshotName = 'snapshot'
                    manifestDigest = '3' * 64
                    sourceCommit = 'a' * 40
                    targetCommit = 'b' * 40
                    prId = 117
                    repositoryId = '11111111-2222-3333-4444-555555555555'
                    project = 'Widgets'
                    nonPromotable = $true
                }
            } }
    }

    $sameKey = New-SignedEvidenceFixture
    $read = Read-ApprovedOwnerEvidence $sameKey.State $sameKey.QueueHeadKey $RepoRoot
    Check 'old same-key signed evidence remains valid' (
        $read.Artifact.headKey -ceq $sameKey.QueueHeadKey -and
        $read.Layer1HeadKey -ceq $sameKey.Layer1HeadKey -and
        $read.Subject.headKey -ceq $sameKey.Layer1HeadKey)

    $distinct = New-SignedEvidenceFixture -QueueHeadKey ('9' * 64)
    $decoyHead = '8' * 64
    $decoyRun = Join-Path (Join-Path $distinct.SubjectRoot 'runs') $decoyHead
    [void](New-Item -ItemType Directory -Force -Path $decoyRun)
    [void](Write-OwnerPreviewJsonFile (Join-Path $decoyRun 'owner-preview-status.json') ([ordered]@{ decoy = $true }))
    $read = Read-ApprovedOwnerEvidence $distinct.State $distinct.QueueHeadKey $RepoRoot
    Check 'signed digest resolves a distinct Layer1 head from the queue head' (
        $read.Artifact.headKey -ceq $distinct.QueueHeadKey -and
        $read.Layer1HeadKey -ceq $distinct.Layer1HeadKey -and
        $read.Layer1HeadKey -cne $distinct.QueueHeadKey)
    Check 'status digest chooses the correct direct runs child' (
        $read.Status.headKey -ceq $distinct.Layer1HeadKey)

    $missing = New-SignedEvidenceFixture -QueueHeadKey ('7' * 64) -ArtifactStatusSha256 ('0' * 64)
    Refuses 'zero matching status digests are refused' {
        Read-ApprovedOwnerEvidence $missing.State $missing.QueueHeadKey $RepoRoot
    } 'No direct.*status digest'

    $multiple = New-SignedEvidenceFixture -QueueHeadKey ('6' * 64)
    $duplicateRun = Join-Path (Join-Path $multiple.SubjectRoot 'runs') ('5' * 64)
    [void](New-Item -ItemType Directory -Force -Path $duplicateRun)
    Copy-Item -LiteralPath $multiple.StatusPath -Destination (Join-Path $duplicateRun 'owner-preview-status.json')
    Refuses 'multiple matching status digests are refused' {
        Read-ApprovedOwnerEvidence $multiple.State $multiple.QueueHeadKey $RepoRoot
    } 'Multiple direct.*status digest'

    $unsafe = New-SignedEvidenceFixture -QueueHeadKey ('4' * 64)
    [void](New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $unsafe.SubjectRoot 'runs') 'not-a-head-key'))
    Refuses 'unsafe direct runs child is refused' {
        Read-ApprovedOwnerEvidence $unsafe.State $unsafe.QueueHeadKey $RepoRoot
    } 'unsafe child'

    $reparse = New-SignedEvidenceFixture -QueueHeadKey ('3' * 64)
    $junctionTarget = Join-Path $script:TestRoot ("escaped-run-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Force -Path $junctionTarget)
    Copy-Item -LiteralPath $reparse.StatusPath -Destination (Join-Path $junctionTarget 'owner-preview-status.json')
    $junctionPath = Join-Path (Join-Path $reparse.SubjectRoot 'runs') ('4' * 64)
    [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget)
    Refuses 'reparse-point direct child cannot escape the runs root' {
        Read-ApprovedOwnerEvidence $reparse.State $reparse.QueueHeadKey $RepoRoot
    } 'reparse point'

    $headMismatch = New-SignedEvidenceFixture -QueueHeadKey ('2' * 64) -MutateStatus {
        param($statusValue, $layer1HeadKey)
        [void]$layer1HeadKey
        $statusValue.headKey = '1' * 64
    }
    Refuses 'status HeadKey must match its direct runs directory' {
        Read-ApprovedOwnerEvidence $headMismatch.State $headMismatch.QueueHeadKey $RepoRoot
    } 'capability-matched|HeadKey'

    $malformed = New-SignedEvidenceFixture -QueueHeadKey ('1' * 64) -MutateStatus {
        param($statusValue, $layer1HeadKey)
        [void]$layer1HeadKey
        [void]$statusValue.Remove('terminal')
    }
    Refuses 'matched status must satisfy its versioned schema' {
        Read-ApprovedOwnerEvidence $malformed.State $malformed.QueueHeadKey $RepoRoot
    } 'versioned schema'

    Add-Content -LiteralPath $sameKey.StatusPath -Value ' '
    Refuses 'status digest tamper is refused' {
        Read-ApprovedOwnerEvidence $sameKey.State $sameKey.QueueHeadKey $RepoRoot
    } 'digest'
    [void](Write-OwnerPreviewJsonFile $sameKey.StatusPath $sameKey.Status)
    $artifactEnvelope = Get-Content -LiteralPath $sameKey.ArtifactPath -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::SetAttributes($sameKey.ArtifactPath, [IO.FileAttributes]::Normal)
    $artifactEnvelope.hmac = '0' * 64
    [void](Write-OwnerPreviewJsonFile $sameKey.ArtifactPath $artifactEnvelope)
    Refuses 'artifact HMAC tamper is refused' {
        Read-ApprovedOwnerEvidence $sameKey.State $sameKey.QueueHeadKey $RepoRoot
    } 'HMAC'
    Set-Item -Path Function:Assert-ReviewerAcquisitionTranscriptPackage -Value $realPackageVerifier

    $ledgerPath = Join-Path $sameKey.State 'ledger.json'
    $ledgerEnvelope = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
    $ledgerEnvelope.hmac = '0' * 64
    [void](Write-OwnerPreviewJsonFile $ledgerPath $ledgerEnvelope)
    Refuses 'ledger HMAC tamper is refused' {
        Read-ApprovedOwnerEvidence $sameKey.State $sameKey.QueueHeadKey $RepoRoot
    } 'HMAC'
}
finally {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -gt 0) {
    Write-Host "Approved Owner comments: $($script:Failures.Count) of $($script:Checks) checks failed." -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Approved Owner comments: all $($script:Checks) checks passed." -ForegroundColor Green
