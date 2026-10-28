BeforeAll {
    $path = (Resolve-Path "$PSScriptRoot\..\src\Agents\reviewer\Start-ReviewerAgent.ps1").Path
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Reviewer parse errors: $errors" }
    foreach ($name in @(
        'Get-ReviewerHashValue', 'Test-ReviewerHasKey', 'Get-ReviewerCanonicalJson',
        'Get-ReviewerNormalizedDocumentText', 'Get-ReviewerTextSha256', 'ConvertTo-ReviewerHashtable',
        'ConvertTo-ReviewerSafeMarkdownText', 'ConvertTo-ReviewerTableCell', 'Get-ReviewerFindingSummaryText',
        'Format-ReviewerFindingComment', 'Format-ReviewerThreadReply', 'Format-ReviewerSummaryComment',
        'Get-ReviewerSeverityCounts', 'Get-ReviewerCommentFingerprint', 'Get-ReviewerFindingFingerprint',
        'Get-ReviewerExistingFingerprints', 'Get-ReviewerThreadReplyFingerprint',
        'Get-ReviewerExistingThreadReplyFingerprints', 'Get-ReviewerWritesRequested',
        'Get-ReviewerPublishableCount', 'Test-ReviewerShouldPostSummary', 'Get-ReviewerFindingThreadStatus',
        'Get-ReviewerSummaryThreadStatus', 'Get-ReviewerDeliveryItemKey', 'New-ReviewerDeliveryPayload',
        'Get-ReviewerDeliveryBody', 'Test-ReviewerPayloadMatchesPreview', 'Get-ReviewerPromotionPayload',
        'Write-ReviewerAtomicFile', 'Write-ReviewerPreview', 'Get-ReviewerArtifactSignature',
        'Test-ReviewerArtifactSignature', 'Invoke-ReviewerDelivery', 'Get-ReviewerAlias',
        'Get-ReviewerSummaryMarker', 'Get-ReviewerSummaryTarget', 'Set-ReviewerSummaryComment'
    )) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $definition) { throw "Missing helper $name" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function Get-ReviewerArtifactSigningKey { param([string]$KeyPath) return ,$script:testKey }
    function Test-ReviewerDeliveryStillValid { param($Session, $PrId, $ExpectedSourceCommit) }
    function Get-ReviewerAuthorUpn { param($Pr) return '' }
    function Get-ReviewerAuthorMentionIdentity { param($Pr) return @{ Id = ''; DisplayName = '' } }
    function Get-ReviewerPullRequestThreads { param($Session, $PrId) return $script:threads }
    function Add-ReviewerThread { param($Session, $PrId, $Content, $FilePath, $Line, $Status) }
    function Invoke-AgentMcpTool { param($Session, $Name, [switch]$RawText, $Arguments) }

    function ConvertTo-TestLegacyReview {
        param($Review)
        $marker = Get-ReviewerSummaryMarker -Content $Review.Result.DeliveryPayload.summary
        $Review.Preview = $Review.Preview.Replace("`n`n$marker", '')
        $Review.Result.DeliveryPayload.summary = $Review.Result.DeliveryPayload.summary.Replace("`n`n$marker", '')
        $Review.Manifest.artifactVersion = 6
        $Review.Manifest.PSObject.Properties.Remove('renderedDelivery')
        $Review.Manifest.previewSha256 = Get-ReviewerTextSha256 (Get-ReviewerNormalizedDocumentText $Review.Preview)
    }

    function New-TestSummaryThread {
        param([string]$Content, [int]$ThreadId = 90, [string]$Owner = 'operator@example.test', [string]$Status = 'Active')
        return @{
            threadId = $ThreadId; status = $Status; filePath = ''; line = 0
            comments = @(@{
                commentId = 1; authorUniqueName = $Owner; content = $Content
                publishedDate = '2026-09-01T12:00:00Z'; isDeleted = $false
            })
        }
    }

    function New-TestReview {
        $result = Write-ReviewerPreview -PrId 42 -SourceCommit ('a' * 40) -PrTitle 'Recovery fixture' `
            -Summary $script:marker.summary -Presentation $script:presentation -AllFindings $script:findings `
            -Postable $script:findings -ThreadReplies $script:replies -RecommendedVote none -Marker $script:marker -Quiet
        $envelope = Get-Content -LiteralPath $result.ArtifactPath -Raw | ConvertFrom-Json
        return @{
            Result = $result
            Envelope = $envelope
            Manifest = ($envelope.manifestJson | ConvertFrom-Json)
            Preview = (Get-Content -LiteralPath $result.MarkdownPath -Raw)
        }
    }
}

Describe 'sealed reviewer delivery across builds' {
    BeforeEach {
        $script:ReviewerSignatureFooter = '-- automated fixture review'
        $script:ReviewerSummaryHeading = '## Code Review Summary'
        $script:ReviewerThreadReplyHeading = 'Reviewer agent assessment'
        $script:ReviewerSeverities = @('critical', 'important', 'suggestion')
        $script:Organization = 'example-org'
        $script:ExpectedProject = 'ExampleProject'
        $script:OperatorAlias = 'operator'
        $script:RepositoryName = 'example-repository'
        $script:cfgRepoId = [Guid]::NewGuid().ToString()
        $script:ScriptSelfSha256 = 'a' * 64
        $script:ResultMarkerPrefix = 'FIXTURE_REVIEW_RESULT'
        $script:EffectiveMaxFindings = 12
        $script:previewDir = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:previewDir)
        $script:ManualDispatchManifest = $null
        $script:pendingArtifactDir = $null
        $script:artifactKeyPath = ''
        $script:testKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        $script:presentation = @{
            RecommendationRationale = ''; ScopeItems = @(); Strengths = @(); RolloutItems = @()
            ValidationItems = @(); SkillsApplied = @(); SecurityReviewApplied = $false
            SecuritySummary = ''; RiskLevel = 'low'; FindingLimitReached = $false; OmittedFindingCount = 0
        }
        $script:findings = @(
            @{ severity = 'important'; filePath = '/src/a.cs'; line = 10; comment = 'First finding.' }
            @{ severity = 'suggestion'; filePath = '/src/b.cs'; line = 20; comment = 'Second finding.' }
        )
        $script:replies = @(@{ threadId = 7; commentId = 3; disposition = 'agree'; comment = 'Assessment.' })
        $script:marker = @{ schemaVersion = 3; summary = 'Stored review.'; findings = $script:findings; recommendedVote = 'none' }
        $script:threads = @()
        $script:failBeforeUpdate = $false
        $script:failAfterUpdate = $false
        Mock Test-ReviewerDeliveryStillValid { return @{ Ok = $true; Pr = @{ status = 'active' } } }
        Mock Add-ReviewerThread {
            param($Session, $PrId, $Content, $FilePath, $Line, $Status)
            $script:threads += New-TestSummaryThread -Content $Content -ThreadId 100 -Status $Status
            return @{ Error = ''; Anchored = $false }
        }
        Mock Invoke-AgentMcpTool {
            param($Session, $Name, [switch]$RawText, $Arguments)
            if ($script:failBeforeUpdate) { throw 'Synthetic pre-write failure.' }
            $thread = $script:threads | Where-Object threadId -eq $Arguments.threadId
            if ($Arguments.action -eq 'update') { $thread.comments[0].content = $Arguments.content }
            elseif ($Arguments.action -eq 'update_status') { $thread.status = $Arguments.status }
            else { throw 'Unexpected write action.' }
            if ($script:failAfterUpdate) { throw 'Synthetic transport closure after write.' }
        }
        Mock Write-Host {}
    }

    It 'seals the exact initial delivery text and reuses it when renderers change' {
        $review = New-TestReview
        $review.Manifest.artifactVersion | Should -Be 7
        Test-ReviewerArtifactSignature -ManifestJson $review.Envelope.manifestJson -Key $script:testKey `
            -Signature $review.Envelope.signature | Should -BeTrue
        $script:ReviewerSignatureFooter = '-- a later build with different formatting'
        $payload = Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker -SameBuild $false
        $body = Get-ReviewerDeliveryBody -Payload $payload -Kind finding -Item $script:findings[0]
        $body | Should -Be $review.Result.DeliveryPayload.comments[(Get-ReviewerDeliveryItemKey -Kind finding -Item $script:findings[0])]
        $body | Should -Not -Match 'a later build'
        $payload.summary | Should -Be $review.Result.DeliveryPayload.summary
        $replyBody = Get-ReviewerDeliveryBody -Payload $payload -Kind reply -Item $script:replies[0]
        $replyBody | Should -Match '-- automated fixture review'
        $threads = @(@{ threadId = 7; comments = @(@{ content = $replyBody }) })
        $fingerprints = Get-ReviewerExistingThreadReplyFingerprints -Threads $threads -DeliveryPayload $payload
        $fingerprints.Contains((Get-ReviewerThreadReplyFingerprint -ThreadId 7 -Content $replyBody)) | Should -BeTrue
    }

    It 'rejects payload tampering through the existing artifact seal' {
        $review = New-TestReview
        $review.Manifest.renderedDelivery.summary = 'Changed after sealing.'
        $modified = Get-ReviewerCanonicalJson -Value $review.Manifest
        Test-ReviewerArtifactSignature -ManifestJson $modified -Key $script:testKey `
            -Signature $review.Envelope.signature | Should -BeFalse
    }

    It 'round-trips <Count> approved items in both new and legacy plans' -ForEach @(@{ Count = 0 }, @{ Count = 1 }) {
        $script:findings = @($script:findings | Select-Object -First $Count)
        $script:replies = @($script:replies | Select-Object -First $Count)
        $script:marker.findings = $script:findings
        $review = New-TestReview
        $payload = Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker -SameBuild $false
        $payload.comments.Count | Should -Be $Count
        $payload.replies.Count | Should -Be $Count
        ConvertTo-TestLegacyReview $review
        $legacy = Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker `
            -SameBuild $false -VerifiedPreviewText $review.Preview
        $legacy.comments.Count | Should -Be $Count
        $legacy.replies.Count | Should -Be $Count
    }

    It 'recovers a legacy plan only when all rendered bodies match its verified original preview' {
        $review = New-TestReview
        ConvertTo-TestLegacyReview $review
        $payload = Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker `
            -SameBuild $false -VerifiedPreviewText $review.Preview
        $payload.summary | Should -Be $review.Result.DeliveryPayload.summary
        $payload.comments.Count | Should -Be 2
        $payload.replies.Count | Should -Be 1
    }

    It 'leaves a legacy plan blocked when its renderer changed or its verified preview is unavailable' {
        $review = New-TestReview
        ConvertTo-TestLegacyReview $review
        { Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker -SameBuild $false } |
            Should -Throw '*Legacy delivery text cannot be verified*'
        $script:ReviewerSignatureFooter = '-- changed rendering'
        { Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker `
            -SameBuild $false -VerifiedPreviewText $review.Preview } | Should -Throw '*Legacy delivery text cannot be verified*'
    }

    It 'rejects missing and extra payload items rather than silently dropping an approved finding' {
        $review = New-TestReview
        $key = Get-ReviewerDeliveryItemKey -Kind finding -Item $script:findings[0]
        $review.Manifest.renderedDelivery.comments.PSObject.Properties.Remove($key)
        { Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker -SameBuild $false } |
            Should -Throw '*does not contain the approved item*'
        $review.Manifest.renderedDelivery.comments | Add-Member -NotePropertyName $key -NotePropertyValue 'Restored fixture body.'
        $review.Manifest.renderedDelivery.comments | Add-Member -NotePropertyName unexpected -NotePropertyValue 'Extra comment.'
        { Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker -SameBuild $false } |
            Should -Throw '*does not match the approved item set*'
    }

    It 'resumes partial delivery without duplicating an already posted finding or summary after an upgrade' {
        $review = New-TestReview
        $script:ReviewerSignatureFooter = '-- a later build'
        $payload = Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker -SameBuild $false
        $script:threads = @(
            @{ filePath = '/src/a.cs'; line = 10; comments = @(@{ content = (Get-ReviewerDeliveryBody -Payload $payload -Kind finding -Item $script:findings[0]) }) }
            (New-TestSummaryThread -Content $payload.summary)
        )
        $script:EnableFindingComments = $true
        $script:EnableThreadReplies = $false
        $script:EnableSummaryComment = $true
        $script:EnableApprovalVote = $false
        Mock Test-ReviewerDeliveryStillValid { return @{ Ok = $true; Pr = @{ status = 'active' } } }
        Mock Add-ReviewerThread {
            param($Session, $PrId, $Content, $FilePath, $Line, $Status)
            $script:threads += @{ filePath = $FilePath; line = $Line; comments = @(@{ content = $Content }) }
            return @{ Error = ''; Anchored = $true }
        }
        $arguments = @{
            Session = @{}; PrId = 42; SourceCommit = ('a' * 40); Postable = $script:findings
            SummaryText = $script:marker.summary; Presentation = $script:presentation
            Counts = (Get-ReviewerSeverityCounts -Findings $script:findings); ReportedFindingCount = 2
            RecommendedVote = 'none'; ChangeSetKnown = $true; DeliveryPayload = $payload
        }
        $result = Invoke-ReviewerDelivery @arguments -ExistingFingerprints (Get-ReviewerExistingFingerprints -Threads $script:threads)
        $result.Delivered | Should -BeTrue
        $result.PostedCount | Should -Be 2
        Should -Invoke Add-ReviewerThread -Times 1 -Exactly -ParameterFilter { $FilePath -eq '/src/b.cs' }
        $retry = Invoke-ReviewerDelivery @arguments -ExistingFingerprints (Get-ReviewerExistingFingerprints -Threads $script:threads)
        $retry.Delivered | Should -BeTrue
        Should -Invoke Add-ReviewerThread -Times 1 -Exactly
    }

    It 'does not publish a sealed payload when the source commit changed' {
        $review = New-TestReview
        $script:EnableFindingComments = $true
        $script:EnableThreadReplies = $false
        $script:EnableSummaryComment = $true
        $script:EnableApprovalVote = $false
        Mock Test-ReviewerDeliveryStillValid { return @{ Ok = $false; Terminal = $true; Reason = 'source changed' } }
        Mock Add-ReviewerThread {}
        $result = Invoke-ReviewerDelivery -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -SummaryText 'Stored review.' -Counts (Get-ReviewerSeverityCounts -Findings $script:findings) `
            -RecommendedVote none -Postable $script:findings -ExistingFingerprints (Get-ReviewerExistingFingerprints -Threads @()) `
            -ChangeSetKnown $true -DeliveryPayload $review.Result.DeliveryPayload
        $result.Aborted | Should -BeTrue
        $result.TerminalAbort | Should -BeTrue
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'creates one owned summary and skips reworded summaries with unchanged review results' {
        $review = New-TestReview
        $first = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $first.Delivered | Should -BeTrue
        $reworded = $review.Result.DeliveryPayload.summary.Replace('Stored review.', 'Equivalent findings, different prose.')
        $second = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $reworded -ReportedFindingCount 2
        $second.Delivered | Should -BeTrue
        $script:threads.Count | Should -Be 1
        $script:threads[0].comments[0].content | Should -Be $review.Result.DeliveryPayload.summary
        Should -Invoke Add-ReviewerThread -Times 1 -Exactly
        Should -Invoke Invoke-AgentMcpTool -Times 0
    }

    It 'updates the same summary when <Change> changes, including after a fresh wrapper pass' -ForEach @(
        @{ Change = 'recommendation' }, @{ Change = 'source commit' }, @{ Change = 'thread context' }
    ) {
        $review = New-TestReview
        $script:threads = @((New-TestSummaryThread $review.Result.DeliveryPayload.summary))
        $source = if ($Change -eq 'source commit') { 'b' * 40 } else { 'a' * 40 }
        $vote = if ($Change -eq 'recommendation') { 'waitForAuthor' } else { 'none' }
        $context = if ($Change -eq 'thread context') { 'human thread status changed' } else { '' }
        $next = New-ReviewerDeliveryPayload -Summary 'Updated review.' -Presentation $script:presentation `
            -Findings $script:findings -Postable $script:findings -ThreadReplies $script:replies `
            -RecommendedVote $vote -Counts (Get-ReviewerSeverityCounts $script:findings) -Reported 2 -Publishable 2 `
            -PrId 42 -SourceCommit $source -SummaryContext $context
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit $source `
            -Content $next.summary -ReportedFindingCount 2
        $result.Delivered | Should -BeTrue
        $script:threads[0].threadId | Should -Be 90
        $script:threads[0].comments[0].content | Should -Be $next.summary
        Should -Invoke Invoke-AgentMcpTool -Times 1 -Exactly -ParameterFilter { $Arguments.action -eq 'update' }
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'adopts the latest automation-only legacy summary without altering older summaries' {
        $review = New-TestReview
        $legacy = $review.Result.DeliveryPayload.summary.Replace("`n`n$(Get-ReviewerSummaryMarker $review.Result.DeliveryPayload.summary)", '')
        $script:threads = @((New-TestSummaryThread $legacy -ThreadId 80), (New-TestSummaryThread $legacy -ThreadId 90))
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $result.Delivered | Should -BeTrue
        $script:threads[0].comments[0].content | Should -Be $legacy
        Should -Invoke Invoke-AgentMcpTool -Times 1 -ParameterFilter { $Arguments.action -eq 'update' -and $Arguments.threadId -eq 90 }
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'never edits another operator summary even when its marker and content match' {
        $review = New-TestReview
        $script:threads = @((New-TestSummaryThread $review.Result.DeliveryPayload.summary -Owner 'other@example.test'))
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $result.Delivered | Should -BeTrue
        $script:threads[0].comments[0].authorUniqueName | Should -Be 'other@example.test'
        Should -Invoke Invoke-AgentMcpTool -Times 0
        Should -Invoke Add-ReviewerThread -Times 1
    }

    It 'preserves human discussion and does not create a replacement summary beside it' {
        $review = New-TestReview
        $script:threads = @((New-TestSummaryThread $review.Result.DeliveryPayload.summary))
        $script:threads[0].comments += @{ commentId = 2; authorUniqueName = 'human@example.test'; content = 'Please discuss this.' }
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $result.Delivered | Should -BeFalse
        $result.Error | Should -Match 'discussion'
        Should -Invoke Invoke-AgentMcpTool -Times 0
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'fails closed when different provider identities share the configured operator alias' {
        $review = New-TestReview
        $script:threads = @(
            (New-TestSummaryThread $review.Result.DeliveryPayload.summary -Owner 'operator@example.test')
            (New-TestSummaryThread $review.Result.DeliveryPayload.summary -ThreadId 91 -Owner 'operator@other.test')
        )
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $result.Delivered | Should -BeFalse
        $result.Error | Should -Match 'Multiple provider identities'
        Should -Invoke Invoke-AgentMcpTool -Times 0
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'retains the actionable summary error in the delivery outcome' {
        $review = New-TestReview
        $script:threads = @((New-TestSummaryThread $review.Result.DeliveryPayload.summary))
        $script:threads[0].comments += @{ commentId = 2; authorUniqueName = 'human@example.test'; content = 'Please discuss this.' }
        $script:EnableFindingComments = $false
        $script:EnableThreadReplies = $false
        $script:EnableSummaryComment = $true
        $script:EnableApprovalVote = $false
        $result = Invoke-ReviewerDelivery -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -SummaryText $script:marker.summary -Presentation $script:presentation -Counts (Get-ReviewerSeverityCounts $script:findings) `
            -RecommendedVote none -ExistingFingerprints (Get-ReviewerExistingFingerprints -Threads $script:threads) `
            -ChangeSetKnown $true -DeliveryPayload $review.Result.DeliveryPayload
        $result.Delivered | Should -BeFalse
        $result.Reason | Should -Match 'discussion'
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'confirms an update after transport uncertainty and never creates a fallback duplicate' {
        $review = New-TestReview
        $legacy = $review.Result.DeliveryPayload.summary.Replace("`n`n$(Get-ReviewerSummaryMarker $review.Result.DeliveryPayload.summary)", '')
        $script:threads = @((New-TestSummaryThread $legacy))
        $script:failAfterUpdate = $true
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $result.Delivered | Should -BeTrue
        $retry = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $retry.Delivered | Should -BeTrue
        Should -Invoke Invoke-AgentMcpTool -Times 1 -Exactly
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'keeps failed updates retryable without falling back to create' {
        $review = New-TestReview
        $legacy = $review.Result.DeliveryPayload.summary.Replace("`n`n$(Get-ReviewerSummaryMarker $review.Result.DeliveryPayload.summary)", '')
        $script:threads = @((New-TestSummaryThread $legacy))
        $script:failBeforeUpdate = $true
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $result.Delivered | Should -BeFalse
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'does not update a summary after the bound source changes' {
        $review = New-TestReview
        $script:threads = @()
        Mock Test-ReviewerDeliveryStillValid { return @{ Ok = $false; Reason = 'source changed' } }
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $review.Result.DeliveryPayload.summary -ReportedFindingCount 2
        $result.Delivered | Should -BeFalse
        Should -Invoke Invoke-AgentMcpTool -Times 0
        Should -Invoke Add-ReviewerThread -Times 0
    }

    It 'does not overwrite <Change> arriving during the source recheck' -ForEach @(
        @{ Change = 'human discussion' }, @{ Change = 'a newer summary' }
    ) {
        $review = New-TestReview
        $script:concurrentContent = $review.Result.DeliveryPayload.summary
        $script:threads = @((New-TestSummaryThread $script:concurrentContent.Replace('Stored review.', 'Earlier prose.')))
        $script:concurrentChange = $Change
        Mock Test-ReviewerDeliveryStillValid {
            if ($script:concurrentChange -eq 'human discussion') {
                $script:threads[0].comments += @{ commentId = 2; authorUniqueName = 'human@example.test'; content = 'New discussion.' }
            }
            else {
                $script:threads += New-TestSummaryThread $script:concurrentContent -ThreadId 101
            }
            return @{ Ok = $true }
        }
        $unmarked = $script:concurrentContent.Replace("`n`n$(Get-ReviewerSummaryMarker $script:concurrentContent)", '')
        $result = Set-ReviewerSummaryComment -Session @{} -PrId 42 -SourceCommit ('a' * 40) `
            -Content $unmarked -ReportedFindingCount 2
        $result.Delivered | Should -BeFalse
        Should -Invoke Invoke-AgentMcpTool -Times 0
        Should -Invoke Add-ReviewerThread -Times 0
    }
}
