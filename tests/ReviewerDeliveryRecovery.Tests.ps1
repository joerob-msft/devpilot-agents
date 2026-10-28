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
        'Test-ReviewerArtifactSignature', 'Invoke-ReviewerDelivery'
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
        $review.Manifest.artifactVersion = 6
        $review.Manifest.PSObject.Properties.Remove('renderedDelivery')
        $legacy = Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker `
            -SameBuild $false -VerifiedPreviewText $review.Preview
        $legacy.comments.Count | Should -Be $Count
        $legacy.replies.Count | Should -Be $Count
    }

    It 'recovers a legacy plan only when all rendered bodies match its verified original preview' {
        $review = New-TestReview
        $review.Manifest.artifactVersion = 6
        $review.Manifest.PSObject.Properties.Remove('renderedDelivery')
        $payload = Get-ReviewerPromotionPayload -Manifest $review.Manifest -Marker $script:marker `
            -SameBuild $false -VerifiedPreviewText $review.Preview
        $payload.summary | Should -Be $review.Result.DeliveryPayload.summary
        $payload.comments.Count | Should -Be 2
        $payload.replies.Count | Should -Be 1
    }

    It 'leaves a legacy plan blocked when its renderer changed or its verified preview is unavailable' {
        $review = New-TestReview
        $review.Manifest.artifactVersion = 6
        $review.Manifest.PSObject.Properties.Remove('renderedDelivery')
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
            @{ filePath = ''; line = 0; comments = @(@{ content = $payload.summary }) }
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
}
