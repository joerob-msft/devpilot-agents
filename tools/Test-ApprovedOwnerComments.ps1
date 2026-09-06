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

    # Signed evidence checks use real queue HMACs and a narrow package-verifier
    # substitution; acquisition package HMAC coverage is already exercised by
    # Test-ReviewerBlindedAcquisition, while this verifies the new reader's joins.
    $state = Join-Path $script:TestRoot 'signed'
    [void](New-Item -ItemType Directory -Force -Path $state)
    $key = Get-OwnerPreviewQueueKey $state
    $head = '2' * 64
    $subjectRoot = Join-Path $state 'subjects-source'
    $subjectDir = Join-Path (Join-Path $subjectRoot 'subjects') $head
    $runDir = Join-Path (Join-Path $subjectRoot 'runs') $head
    [void](New-Item -ItemType Directory -Force -Path $subjectDir)
    [void](New-Item -ItemType Directory -Force -Path $runDir)
    $subject = (New-Evidence).Subject
    $subject.headKey = $head
    $subject.subjectKey = Get-OwnerPreviewSubjectKey contoso Widgets '11111111-2222-3333-4444-555555555555' 117
    $subject.configSha256 = 'e' * 64; $subject.toolkitHead = 'f' * 40; $subject.model = 'claude-sonnet-5'
    $subject.snapshot = [ordered]@{ manifestDigest = '3' * 64 }
    $subject.headKey = Get-OwnerPreviewHeadKey $subject.subjectKey $subject.subject.sourceCommit @($subject.rule.sections) `
        $subject.snapshot.manifestDigest $subject.model $subject.configSha256 $subject.toolkitHead
    $head = $subject.headKey
    $subjectDir = Join-Path (Join-Path $subjectRoot 'subjects') $head
    $runDir = Join-Path (Join-Path $subjectRoot 'runs') $head
    [void](New-Item -ItemType Directory -Force -Path $subjectDir)
    [void](New-Item -ItemType Directory -Force -Path $runDir)
    $subject.schemaVersion = 1; $subject.kind = 'reviewer-owner-preview-subject'
    [void](Write-OwnerPreviewJsonFile (Join-Path $subjectDir 'subject.json') $subject)
    $status = [ordered]@{
        schemaVersion = 1; kind = 'reviewer-owner-preview-status'; capability = 'bpm-test-ownership@1'
        subjectKey = $subject.subjectKey; headKey = $head; subject = $subject.subject
        rule = [ordered]@{ path = $subject.rule.sections[0].path; commit = $subject.rule.sections[0].commit
            sha256 = $subject.rule.sections[0].sha256; byteLength = 123; section = $subject.rule.sections[0].section }
        snapshot = [ordered]@{ snapshotId = 'snapshot'; manifestDigest = '3' * 64; sealKind = 'offlineCorpusSeal'; nonPromotable = $true }
        counts = [ordered]@{ checked = 1; violations = 1; compliant = 0; unknown = 0; notInReach = 0; notRouted = 0 }
        violations = @([ordered]@{ ruleRef = 'rs0'; constructRef = 'dc0' })
        terminal = [ordered]@{ status = 'completed'; markerStatus = 'success'; contractVersion = 4 }
        spend = [ordered]@{ attempts = 1; modelStarts = 1; providerWriteCount = 0; writeToolInvocations = 0; generalistModelStarts = 0 }
        createdUtc = '2026-09-06T00:00:00Z'
    }
    $statusPath = Join-Path $runDir 'owner-preview-status.json'
    [void](Write-OwnerPreviewJsonFile $statusPath $status)
    $artifactPath = Join-Path (Join-Path (Join-Path $state 'artifacts') $head) 'attempt-001.json'
    $artifact = [ordered]@{ schemaVersion = 1; kind = 'reviewer-owner-preview-queue-artifact'; capability = 'bpm-test-ownership@1'
        headKey = $head; attempt = 1; subjectRoot = $subjectRoot; statusSha256 = Get-OwnerPreviewFileSha256 $statusPath
        createdUtc = '20260906T000000Z' }
    Write-OwnerPreviewQueueImmutableRecord $artifactPath $artifact $key
    $ledger = New-OwnerPreviewQueueLedger
    $ledger.records[$head] = [ordered]@{ state = 'completed'; terminal = [ordered]@{ status = 'completed' }
        providerWriteCount = 0; writeToolInvocations = 0; artifact = $artifactPath }
    Save-OwnerPreviewQueueLedger $state $ledger $key
    $realPackageVerifier = ${function:Assert-ReviewerAcquisitionTranscriptPackage}
    function Assert-ReviewerAcquisitionTranscriptPackage {
        return [pscustomobject]@{ Core = [ordered]@{
                sourceProjection = [ordered]@{ sourceRole = 'specialist'; ruleCoverage = (New-Evidence).Coverage }
                snapshotIdentity = [ordered]@{ sourceCommit = 'a' * 40; prId = 117; repositoryId = '11111111-2222-3333-4444-555555555555' }
            } }
    }
    $read = Read-ApprovedOwnerEvidence $state $head $RepoRoot
    Check 'signed ledger artifact and status are accepted' ($read.Subject.headKey -ceq $head)
    Add-Content -LiteralPath $statusPath -Value ' '
    Refuses 'status digest tamper is refused' { Read-ApprovedOwnerEvidence $state $head $RepoRoot } 'digest'
    [void](Write-OwnerPreviewJsonFile $statusPath $status)
    $artifactEnvelope = Get-Content -LiteralPath $artifactPath -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::SetAttributes($artifactPath, [IO.FileAttributes]::Normal)
    $artifactEnvelope.hmac = '0' * 64
    [void](Write-OwnerPreviewJsonFile $artifactPath $artifactEnvelope)
    Refuses 'artifact HMAC tamper is refused' { Read-ApprovedOwnerEvidence $state $head $RepoRoot } 'HMAC'
    Set-Item -Path Function:Assert-ReviewerAcquisitionTranscriptPackage -Value $realPackageVerifier

    $ledgerPath = Join-Path $state 'ledger.json'
    $ledgerEnvelope = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
    $ledgerEnvelope.hmac = '0' * 64
    [void](Write-OwnerPreviewJsonFile $ledgerPath $ledgerEnvelope)
    Refuses 'ledger HMAC tamper is refused' { Read-ApprovedOwnerEvidence $state $head $RepoRoot } 'HMAC'
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
