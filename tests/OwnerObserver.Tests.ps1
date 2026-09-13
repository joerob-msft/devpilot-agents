BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ModulePath = Join-Path $script:RepoRoot 'src/OwnerObserver/OwnerObserver.psd1'
    $script:OwnerV2OrchestratorModulePath = Join-Path $script:RepoRoot `
        'src/DevPilot.OwnerOrchestrator/DevPilot.OwnerOrchestrator.psd1'
    $script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures/owner-observer'
    $script:OwnerV2FixturePath = Join-Path $PSScriptRoot `
        'fixtures/owner-orchestrator/generic-cohort.json'
    Import-Module $script:ModulePath -Force

    function Write-OwnerObserverTestText {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
        $directory = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
    }

    function Write-OwnerObserverTestSignedRecord {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)]$Payload,
            [Parameter(Mandatory)][byte[]]$Key
        )
        $canonical = ConvertTo-OwnerObserverCanonicalJson -Value $Payload
        $envelope = [ordered]@{
            schemaVersion = 1
            kind = 'reviewer-owner-preview-signed-record'
            payload = $Payload
            hmac = Get-OwnerObserverHmac -Text $canonical -Key $Key
        }
        Write-OwnerObserverTestText -Path $Path `
            -Text (ConvertTo-OwnerObserverCanonicalJson -Value $envelope)
    }

    function New-OwnerObserverV1Fixture {
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$WithoutArtifact,
            [switch]$ArtifactOutsideRoot,
            [ValidateRange(0, 512)][int]$ViolationCount = 1,
            [ValidateRange(0, 512)][int]$UnknownCount = 1,
            [ValidateRange(0, 100)][int]$AuditCount = 1,
            [ValidateRange(0, [int]::MaxValue)][int]$AnchorLine = 12
        )
        $stateRoot = Join-Path $Root 'state'
        $subjectRoot = Join-Path $Root 'subjects'
        $queueHeadKey = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        $statusHeadKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        [byte[]]$key = 1..32
        Write-OwnerObserverTestText -Path (Join-Path $stateRoot 'keys/ledger.key') `
            -Text ([Convert]::ToBase64String($key))

        $statusSource = Join-Path $script:FixtureRoot 'v1-status.json'
        $statusPath = Join-Path (Join-Path (Join-Path $subjectRoot 'runs') $statusHeadKey) `
            'owner-preview-status.json'
        $statusText = [IO.File]::ReadAllText($statusSource, [Text.UTF8Encoding]::new($false, $true))
        $status = $statusText | ConvertFrom-Json -Depth 64 -AsHashtable
        if ($ViolationCount -ne 1 -or $UnknownCount -ne 1) {
            $status.violations = @(
                for ($index = 1; $index -le $ViolationCount; $index++) {
                    [ordered]@{
                        ruleRef = 'rs0'
                        constructRef = "dc$index"
                    }
                })
            $status.unknowns = @(
                for ($index = 1; $index -le $UnknownCount; $index++) {
                    [ordered]@{
                        ruleRef = 'rs0'
                        constructRef = "unknown$index"
                    }
                })
            $status.counts.checked = $ViolationCount
            $status.counts.violations = $ViolationCount
            $status.counts.compliant = 0
            $status.counts.unknown = $UnknownCount
            $statusText = $status | ConvertTo-Json -Depth 64
        }
        Write-OwnerObserverTestText -Path $statusPath -Text $statusText
        $statusBytes = [IO.File]::ReadAllBytes($statusPath)
        $statusSha = ([Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($statusBytes))).ToLowerInvariant()

        $artifactPath = if ($ArtifactOutsideRoot) {
            Join-Path $Root 'outside/attempt-001.json'
        }
        else {
            Join-Path (Join-Path (Join-Path $stateRoot 'artifacts') $queueHeadKey) 'attempt-001.json'
        }
        $artifact = [ordered]@{
            schemaVersion = 1
            kind = 'reviewer-owner-preview-queue-artifact'
            capability = 'test-ownership@1'
            headKey = $queueHeadKey
            attempt = 1
            subjectRoot = $subjectRoot
            statusSha256 = $statusSha
            createdUtc = '20260901T000000Z'
        }
        Write-OwnerObserverTestSignedRecord -Path $artifactPath -Payload $artifact -Key $key

        $record = [ordered]@{
            headKey = $queueHeadKey
            capability = 'test-ownership@1'
            state = 'completed'
            subject = $status.subject
            rule = $status.rule
            terminal = $status.terminal
            counts = $status.counts
            attempts = 1
            modelAttempts = 1
            startCount = 1
            latencyMs = 1200
            providerWriteCount = 0
            writeToolInvocations = 0
            generalistModelStarts = 0
            artifact = $(if ($WithoutArtifact) { '' } else { $artifactPath })
        }
        $index = [ordered]@{
            schemaVersion = 1
            kind = 'reviewer-owner-preview-queue-index'
            capability = 'test-ownership@1'
            generatedUtc = '20260901T000000Z'
            records = @($record)
        }
        $indexPath = Join-Path $stateRoot 'index/current.json'
        Write-OwnerObserverTestSignedRecord -Path $indexPath -Payload $index -Key $key

        for ($auditIndex = 1; $auditIndex -le $AuditCount; $auditIndex++) {
            $invocationId = 'sample-invocation-{0:d3}' -f $auditIndex
            $intent = [ordered]@{
                schemaVersion = 1
                kind = 'reviewer-approved-owner-comment-intent'
                capability = 'test-ownership@1'
                writerVersion = 1
                invocationId = $invocationId
                headKey = $statusHeadKey
                publish = $false
                approveUpdate = $false
                reason = 'Sanitized fixture.'
                selections = @(
                    [ordered]@{
                        constructId = 'dc1'
                        findingId = 'test-ownership@1:rs0:dc1'
                        dedupeKey = "sample-dedupe-$auditIndex"
                        path = 'src/WidgetTests.cs'
                        line = $AnchorLine
                        symbol = 'CreatesWidget'
                        body = 'Synthetic fixture body.'
                        bodySha256 = '7777777777777777777777777777777777777777777777777777777777777777'
                    }
                )
                createdUtc = '20260901T000000Z'
            }
            $outcome = [ordered]@{
                schemaVersion = 1
                kind = 'reviewer-approved-owner-comment-outcome'
                invocationId = $invocationId
                headKey = $statusHeadKey
                status = 'completed'
                providerWrites = 0
                results = @(
                    [ordered]@{
                        findingId = 'test-ownership@1:rs0:dc1'
                        outcome = 'noOp'
                        dedupeKey = "sample-dedupe-$auditIndex"
                    }
                )
                createdUtc = '20260901T000000Z'
            }
            Write-OwnerObserverTestSignedRecord `
                -Path (Join-Path (Join-Path (Join-Path $stateRoot 'approved-comments/intents') $statusHeadKey) "$invocationId.json") `
                -Payload $intent -Key $key
            Write-OwnerObserverTestSignedRecord `
                -Path (Join-Path (Join-Path (Join-Path $stateRoot 'approved-comments/outcomes') $statusHeadKey) "$invocationId.json") `
                -Payload $outcome -Key $key
        }

        return [pscustomobject]@{
            StateRoot = $stateRoot
            SubjectRoot = $subjectRoot
            QueueHeadKey = $queueHeadKey
            IndexPath = $indexPath
            ArtifactPath = $artifactPath
            Key = $key
        }
    }
}

Describe 'Owner observer normalized contract' {
    It 'matches the frozen v1 canonical HMAC vector' {
        $payload = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $payload.Add('Zebra', 'last')
        $payload.Add('apple', 'lower')
        $payload.Add('Apple', 'upper')
        $payload.Add('_underscore', 'under')
        $payload.Add('1number', 1)
        $payload.Add('artifact_id', 'snake')
        $payload.Add('artifactId', 'camel')
        $payload.Add('artifact-id', 'dash')
        $payload.Add('control', "line`n$([char]0x7f)")
        # This pins the producer's executed PowerShell behavior, including its
        # culture comparison treating DEL like the backspace switch arm.
        $expectedCanonical = '{"1number":1,"Apple":"upper","Zebra":"last","_underscore":"under","apple":"lower","artifact-id":"dash","artifactId":"camel","artifact_id":"snake","control":"line\n\b"}'
        [byte[]]$key = 1..32

        $canonical = ConvertTo-OwnerObserverCanonicalJson -Value $payload

        $canonical | Should -BeExactly $expectedCanonical
        (Get-OwnerObserverHmac -Text $canonical -Key $key) |
            Should -BeExactly '48b4338c5c934aea09e0d7e6c62c179634b226af0e005f751746864417640ede'
    }

    It 'rejects signed v1 text with an ambiguous legacy canonical representation' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'ambiguous')
        $envelope = Get-Content -LiteralPath $fixture.IndexPath -Raw |
            ConvertFrom-Json -Depth 64 -AsHashtable
        $envelope.payload.note = "alpha$([char]0x200b)beta"
        $envelope.hmac = Get-OwnerObserverHmac `
            -Text (ConvertTo-OwnerObserverCanonicalJson -Value $envelope.payload) `
            -Key $fixture.Key
        $text = (ConvertTo-OwnerObserverCanonicalJson -Value $envelope).Replace(
            'alpha\bbeta',
            "alpha$([char]0x200b)beta")
        Write-OwnerObserverTestText -Path $fixture.IndexPath `
            -Text $text

        { Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey } |
            Should -Throw '*canonical HMAC representation is ambiguous*'
    }

    It 'rejects unexpected unsigned v1 envelope fields' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'envelope')
        $envelope = Get-Content -LiteralPath $fixture.IndexPath -Raw |
            ConvertFrom-Json -Depth 64 -AsHashtable
        $envelope.note = 'unsigned'
        Write-OwnerObserverTestText -Path $fixture.IndexPath `
            -Text (ConvertTo-OwnerObserverCanonicalJson -Value $envelope)

        { Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey } |
            Should -Throw '*envelope has unexpected fields*'
    }

    It 'parses and validates a future normalized implementation' {
        $path = (Resolve-Path (Join-Path $script:FixtureRoot 'v2-outcome.json')).Path
        $outcome = Read-OwnerNormalizedObservation -Path $path

        $outcome.implementation.id | Should -Be 'owner-v2-fixture'
        $outcome.sourceArtifacts[-1].kind | Should -Be 'normalized-owner-output'
        Test-OwnerObservation -Observation $outcome | Should -BeTrue
    }

    It 'preserves a maximum-sized normalized provenance set without throwing' {
        $outcome = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'v2-outcome.json') -Raw |
            ConvertFrom-Json -Depth 64 -AsHashtable
        $outcome.sourceArtifacts = @(
            for ($index = 0; $index -lt 64; $index++) {
                [ordered]@{
                    kind = "source-$index"
                    sha256 = ('{0:x64}' -f $index)
                    signature = 'not-applicable'
                }
            })
        $path = Join-Path $TestDrive 'maximum-provenance.json'
        Write-OwnerObserverTestText -Path $path -Text ($outcome | ConvertTo-Json -Depth 64)

        $read = Read-OwnerNormalizedObservation -Path $path

        $read.sourceArtifacts | Should -HaveCount 64
        $read.sourceArtifacts.kind | Should -Not -Contain 'normalized-owner-output'
        $read.validationErrors | Should -Contain `
            'Source artifact digests exceeded the 64-entry observation limit; provenance is incomplete.'
        Test-OwnerObservation -Observation $read | Should -BeTrue
    }

    It 'preserves the provenance warning when normalized error capacity is full' {
        $outcome = Get-Content -LiteralPath (Join-Path $script:FixtureRoot 'v2-outcome.json') -Raw |
            ConvertFrom-Json -Depth 64 -AsHashtable
        $outcome.sourceArtifacts = @(
            for ($index = 0; $index -lt 64; $index++) {
                [ordered]@{
                    kind = "source-$index"
                    sha256 = ('{0:x64}' -f $index)
                    signature = 'verified'
                }
            })
        $outcome.validationErrors = @(for ($index = 0; $index -lt 32; $index++) { "error-$index" })
        $path = Join-Path $TestDrive 'full-provenance-and-errors.json'
        Write-OwnerObserverTestText -Path $path -Text ($outcome | ConvertTo-Json -Depth 64)

        $read = Read-OwnerNormalizedObservation -Path $path

        $read.sourceArtifacts | Should -HaveCount 64
        $read.validationErrors | Should -HaveCount 32
        $read.validationErrors | Should -Contain `
            'Source artifact digests exceeded the 64-entry observation limit; provenance is incomplete.'
        Test-OwnerObservation -Observation $read | Should -BeTrue
    }

    It 'ingests the persisted Owner v2 artifact without mutating it' {
        Import-Module $script:OwnerV2OrchestratorModulePath -Force
        $stateRoot = Join-Path $TestDrive 'owner-v2-state'
        $manifestPath = Join-Path $TestDrive 'owner-v2-cohort.json'
        Write-OwnerObserverTestText -Path $manifestPath `
            -Text ([IO.File]::ReadAllText(
                $script:OwnerV2FixturePath,
                [Text.UTF8Encoding]::new($false, $true)))
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        [void](Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath)
        $artifact = Get-ChildItem -LiteralPath $stateRoot -Recurse -Filter '*.json' |
            Where-Object {
                $_.FullName -match [regex]::Escape(
                    [IO.Path]::DirectorySeparatorChar + 'observations' +
                    [IO.Path]::DirectorySeparatorChar)
            } |
            Select-Object -First 1
        $before = [IO.File]::ReadAllBytes($artifact.FullName)

        $outcome = Read-OwnerNormalizedObservation -Path $artifact.FullName

        [Convert]::ToBase64String([IO.File]::ReadAllBytes($artifact.FullName)) |
            Should -BeExactly ([Convert]::ToBase64String($before))
        $outcome.implementation.id | Should -Be 'owner-v2-preview'
        $outcome.effects.providerWrites | Should -Be 0
        $outcome.effects.writeToolInvocations | Should -Be 0
        @($outcome.sourceArtifacts | Where-Object kind -EQ 'normalized-owner-output') |
            Should -HaveCount 1
        Test-OwnerObservation -Observation $outcome | Should -BeTrue
    }

    It 'requires callers to state missing details as unknown' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'unknown') -WithoutArtifact
        $outcome = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey

        $outcome.findingsComplete | Should -Be 'unknown'
        $outcome.findings | Should -HaveCount 0
        $outcome.lifecycle.completed | Should -BeTrue
        $outcome.validationErrors | Should -HaveCount 1
        $outcome.validationErrors[0] | Should -Match 'no signed artifact'
    }

    It 'bounds and redacts diagnostics' {
        $diagnostic = ConvertTo-OwnerObserverDiagnostic `
            -Text ('token=super-secret C:\private\evidence.json user@example.test ' + ('x' * 800))

        $diagnostic | Should -Not -Match 'super-secret'
        $diagnostic | Should -Not -Match 'private'
        $diagnostic | Should -Not -Match 'example.test'
        $diagnostic.Length | Should -BeLessOrEqual 512
    }
}

Describe 'Owner v1 read-only adapter' {
    It 'verifies signed queue, artifact and audit shapes and normalizes findings' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'complete')
        $outcome = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey

        $outcome.implementation.id | Should -Be 'owner-v1-external'
        $outcome.lifecycle.status | Should -Be 'completed'
        $outcome.counts.checked | Should -Be 2
        $outcome.counts.violations | Should -Be 1
        $outcome.counts.unknown | Should -Be 1
        $outcome.counts.uncovered | Should -Be 3
        $outcome.findings | Should -HaveCount 2
        $finding = $outcome.findings | Where-Object identity -EQ 'test-ownership@1:rs0:dc1'
        $finding.anchor.path | Should -Be 'src/WidgetTests.cs'
        $finding.anchor.line | Should -Be 12
        $outcome.effects.providerWrites | Should -Be 0
        $outcome.effects.dedupe.noOp | Should -Be 1
        $outcome.effects.operatorIntervention | Should -BeTrue
        $outcome.validationErrors | Should -HaveCount 0
        @($outcome.sourceArtifacts | Where-Object signature -EQ 'verified') | Should -HaveCount 4
        Test-OwnerObservation -Observation $outcome | Should -BeTrue
    }

    It 'rejects a tampered signed index' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'tamper')
        $envelope = Get-Content -LiteralPath $fixture.IndexPath -Raw | ConvertFrom-Json -Depth 64 -AsHashtable
        $envelope.hmac = '0000000000000000000000000000000000000000000000000000000000000000'
        Write-OwnerObserverTestText -Path $fixture.IndexPath `
            -Text (ConvertTo-OwnerObserverCanonicalJson -Value $envelope)

        { Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey } |
            Should -Throw '*failed HMAC verification*'
    }

    It 'refuses an artifact path outside the declared state root' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'escape') -ArtifactOutsideRoot
        $outcome = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey

        $outcome.findingsComplete | Should -Be 'unknown'
        $outcome.validationErrors[0] | Should -Match 'outside its allowed root'
        $outcome.effects.providerWrites | Should -Be 'unknown'
        $outcome.effects.operatorIntervention | Should -Be 'unknown'
        @($outcome.effects.dedupe.Values | Select-Object -Unique) | Should -Be @('unknown')
    }

    It 'does not consume a digest-matching status with the wrong contract identity' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'foreign-status')
        $statusPath = Get-ChildItem -LiteralPath $fixture.SubjectRoot -Recurse `
            -Filter 'owner-preview-status.json' | Select-Object -First 1
        $status = Get-Content -LiteralPath $statusPath.FullName -Raw |
            ConvertFrom-Json -Depth 64 -AsHashtable
        $status.kind = 'foreign-owner-status'
        $status.counts.checked = 999
        Write-OwnerObserverTestText -Path $statusPath.FullName `
            -Text ($status | ConvertTo-Json -Depth 64)
        $statusSha = ([Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [IO.File]::ReadAllBytes($statusPath.FullName)))).ToLowerInvariant()
        $artifactEnvelope = Get-Content -LiteralPath $fixture.ArtifactPath -Raw |
            ConvertFrom-Json -Depth 64 -AsHashtable
        $artifactEnvelope.payload.statusSha256 = $statusSha
        $artifactEnvelope.hmac = Get-OwnerObserverHmac `
            -Text (ConvertTo-OwnerObserverCanonicalJson -Value $artifactEnvelope.payload) `
            -Key $fixture.Key
        Write-OwnerObserverTestText -Path $fixture.ArtifactPath `
            -Text (ConvertTo-OwnerObserverCanonicalJson -Value $artifactEnvelope)

        $outcome = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey

        $outcome.validationErrors | Should -Contain `
            'Owner v1 preview status has the wrong payload kind or version.'
        $outcome.counts.checked | Should -Be 2
        $outcome.findings | Should -HaveCount 0
        $outcome.findingsComplete | Should -Be 'unknown'
        $outcome.effects.providerWrites | Should -Be 'unknown'
    }

    It 'degrades zero-line audit anchors to unknown' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'zero-line') -AnchorLine 0
        $outcome = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey

        ($outcome.findings | Where-Object identity -EQ 'test-ownership@1:rs0:dc1').anchor |
            Should -Be 'unknown'
        Test-OwnerObservation -Observation $outcome | Should -BeTrue
    }

    It 'signals observer-side finding truncation' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'finding-cap') `
            -ViolationCount 512 -UnknownCount 1 -AuditCount 0
        $outcome = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey

        $outcome.findings | Should -HaveCount 512
        $outcome.findingsComplete | Should -BeFalse
        $outcome.validationErrors | Should -Contain `
            'Findings exceeded the 512-entry normalized observation limit; finding parity is incomplete.'
    }

    It 'signals source artifact digest truncation' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'artifact-cap') -AuditCount 40
        $outcome = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey

        $outcome.sourceArtifacts | Should -HaveCount 64
        $outcome.validationErrors | Should -Contain `
            'Source artifact digests exceeded the 64-entry observation limit; provenance is incomplete.'
    }

    It 'requires absolute observation roots' {
        { Read-OwnerV1Observation -StateRoot '.\relative' } |
            Should -Throw '*absolute path*'
    }

    It 'rejects observation roots reached through a link' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'real-root')
        $target = Split-Path -Parent $fixture.StateRoot
        $link = Join-Path $TestDrive 'linked-root'
        if ($IsWindows) {
            [void](New-Item -ItemType Junction -Path $link -Target $target)
        }
        else {
            [void](New-Item -ItemType SymbolicLink -Path $link -Target $target)
        }

        { Read-OwnerV1Observation -StateRoot (Join-Path $link 'state') -HeadKey $fixture.QueueHeadKey } |
            Should -Throw '*link or reparse point*'
    }
}

Describe 'Owner parity report' {
    It 'deterministically reports retained, lost and new findings and latency' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'parity')
        $baseline = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey
        $candidate = Read-OwnerNormalizedObservation `
            -Path (Resolve-Path (Join-Path $script:FixtureRoot 'v2-outcome.json')).Path

        $report = Compare-OwnerObservations -Baseline $baseline -Candidate $candidate

        $report.findings.retained | Should -Be @('test-ownership@1:rs0:dc1')
        $report.findings.lost | Should -Be @('test-ownership@1:rs0:dc2')
        $report.findings.new | Should -Be @('test-ownership@1:rs0:dc3')
        $report.binding.matches | Should -BeTrue
        $report.writes.matches | Should -BeTrue
        $report.completion.regression | Should -BeFalse
        $report.latency.deltaMs | Should -Be -300
        $report.latency.comparison | Should -Be 'faster'
        $report.parity | Should -BeFalse
    }

    It 'reports completion, count, binding and write regressions' {
        $fixture = New-OwnerObserverV1Fixture -Root (Join-Path $TestDrive 'regression')
        $baseline = Read-OwnerV1Observation -StateRoot $fixture.StateRoot -HeadKey $fixture.QueueHeadKey
        $candidate = $baseline | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64 -AsHashtable
        $candidate.implementation.id = 'owner-v2-fixture'
        $candidate.subject.headCommit = '9999999999999999999999999999999999999999'
        $candidate.lifecycle.status = 'incomplete'
        $candidate.lifecycle.completed = $false
        $candidate.lifecycle.incomplete = $true
        $candidate.counts.checked = 1
        $candidate.counts.unknown = 2
        $candidate.effects.providerWrites = 1

        $report = Compare-OwnerObservations -Baseline $baseline -Candidate $candidate

        $report.binding.mismatches | Should -Contain 'subject.headCommit'
        $report.regressions.status | Should -BeTrue
        $report.regressions.counts | Should -Contain 'checked-decreased'
        $report.regressions.counts | Should -Contain 'unknown-increased'
        $report.writes.mismatches | Should -Contain 'providerWrites'
        $report.completion.regression | Should -BeTrue
    }

    It 'uses ordinal finding ordering across cultures' {
        $path = (Resolve-Path (Join-Path $script:FixtureRoot 'v2-outcome.json')).Path
        $baseline = Read-OwnerNormalizedObservation -Path $path
        $candidate = Read-OwnerNormalizedObservation -Path $path
        $baseline.findings = @(
            [ordered]@{ identity = 'z'; disposition = 'violation'; ruleRef = 'r'; constructRef = 'z'; anchor = 'unknown' },
            [ordered]@{ identity = 'A'; disposition = 'violation'; ruleRef = 'r'; constructRef = 'A'; anchor = 'unknown' },
            [ordered]@{ identity = '_'; disposition = 'violation'; ruleRef = 'r'; constructRef = '_'; anchor = 'unknown' }
        )
        $candidate.findings = @($baseline.findings)
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
            $english = (Compare-OwnerObservations -Baseline $baseline -Candidate $candidate).findings.retained
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('da-DK')
            $danish = (Compare-OwnerObservations -Baseline $baseline -Candidate $candidate).findings.retained
        }
        finally {
            [Globalization.CultureInfo]::CurrentCulture = $originalCulture
        }

        $english | Should -Be @('A', '_', 'z')
        $danish | Should -Be $english
    }

    It 'treats finding identity casing as semantically distinct' {
        $path = (Resolve-Path (Join-Path $script:FixtureRoot 'v2-outcome.json')).Path
        $baseline = Read-OwnerNormalizedObservation -Path $path
        $candidate = Read-OwnerNormalizedObservation -Path $path
        $candidate.findings[0].identity = $candidate.findings[0].identity.ToUpperInvariant()

        $report = Compare-OwnerObservations -Baseline $baseline -Candidate $candidate

        $report.findings.retained | Should -Not -Contain $baseline.findings[0].identity
        $report.findings.lost | Should -Contain $baseline.findings[0].identity
        $report.findings.new | Should -Contain $candidate.findings[0].identity
        $report.parity | Should -BeFalse
    }

    It 'degrades parity when findings lack comparable identities' {
        $path = (Resolve-Path (Join-Path $script:FixtureRoot 'v2-outcome.json')).Path
        $baseline = Read-OwnerNormalizedObservation -Path $path
        $candidate = Read-OwnerNormalizedObservation -Path $path
        $baseline.findings[0].identity = 'unknown'
        $candidate.findings[0].identity = 'unknown'
        $baseline.findings[0].constructRef = 'construct:baseline'
        $candidate.findings[0].constructRef = 'construct:candidate'

        $report = Compare-OwnerObservations -Baseline $baseline -Candidate $candidate

        $report.parity | Should -Be 'unknown'
    }

    It 'degrades parity instead of throwing on duplicate finding identities' {
        $path = (Resolve-Path (Join-Path $script:FixtureRoot 'v2-outcome.json')).Path
        $baseline = Read-OwnerNormalizedObservation -Path $path
        $candidate = Read-OwnerNormalizedObservation -Path $path
        $duplicate = $baseline.findings[0] | ConvertTo-Json -Depth 16 |
            ConvertFrom-Json -Depth 16 -AsHashtable
        $duplicate.disposition = 'unknown'
        $baseline.findings = @($baseline.findings) + @($duplicate)

        { $script:duplicateReport = Compare-OwnerObservations `
                -Baseline $baseline -Candidate $candidate } | Should -Not -Throw
        $script:duplicateReport.parity | Should -Be 'unknown'
    }

    It 'preserves unknown lifecycle state instead of reporting a regression' {
        $path = (Resolve-Path (Join-Path $script:FixtureRoot 'v2-outcome.json')).Path
        $baseline = Read-OwnerNormalizedObservation -Path $path
        $candidate = Read-OwnerNormalizedObservation -Path $path
        $candidate.lifecycle.status = 'unknown'
        $candidate.lifecycle.completed = 'unknown'
        $candidate.lifecycle.incomplete = 'unknown'
        $candidate.lifecycle.pending = 'unknown'

        $report = Compare-OwnerObservations -Baseline $baseline -Candidate $candidate

        $report.parity | Should -Be 'unknown'
        $report.regressions.status | Should -Be 'unknown'
        $report.completion.regression | Should -Be 'unknown'
    }
}

Describe 'Owner observer safety surface' {
    It 'contains no provider, model or file-write commands' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:RepoRoot 'src/OwnerObserver/OwnerObserver.psm1') -Raw

        $source | Should -Not -Match '\bInvoke-(RestMethod|WebRequest)\b'
        $source | Should -Not -Match '\bStart-Process\b'
        $source | Should -Not -Match '\b(Set|Add)-Content\b'
        $source | Should -Not -Match '\b(New|Remove|Move|Copy)-Item\b'
        $source | Should -Not -Match '\b(copilot|gh|az)\b'
    }
}
