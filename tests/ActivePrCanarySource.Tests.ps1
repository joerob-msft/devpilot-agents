#requires -Version 7.0
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
    Import-Module (Join-Path $repo 'src\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1') -Force
    $module = Get-Module DevPilot.ActivePrCanary
    $script:sourceKey = 'b' * 64
    $script:sourceSelector = [ordered]@{
        schemaVersion = 1; kind = 'private-canary-source-selector'
        organization = 'example-org'; projectName = 'ExampleSource'
        repositoryName = 'ExamplePolicyRepo'; signature = ''
    }
    $script:sourceSelector.signature = & $module {
        param($Selector, $Key) Get-CanarySignature $Selector $Key
    } $script:sourceSelector $script:sourceKey
    $script:originalCoverageSource = & $module {
        @{ hash = $script:CoverageDocumentHash
            length = $script:CoverageDocumentLength }
    }
    $lines = @('## Test coverage') + @('A convention.') * 219 +
        @('Exclude every test-project class.', '',
            'Remove redundant method exclusions.', '', '## Other convention', 'Unrelated.')
    $document = $lines -join "`n"
    $digest = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($document))).ToLowerInvariant()
    & $module {
        param($Hash, $Length)
        $script:CoverageDocumentHash = $Hash
        $script:CoverageDocumentLength = $Length
    } $digest ([Text.Encoding]::UTF8.GetByteCount($document))

    function Get-CoverageSourceCase {
        $id = '44444444-4444-4444-4444-444444444444'
        $commit = '7e6620ec40c9bc37c5a5e13d506053b0139c9206'
        $path = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
        $section = & $module {
            param($Text)
            Get-CanarySection $Text '## Test coverage'
        } $document
        $sectionHash = 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($section))).ToLowerInvariant()
        $sources = @{}
        foreach ($rule in @(
                @{ id = 'bpm-test-class-coverage@2'; line = 221 },
                @{ id = 'bpm-redundant-method-coverage@2'; line = 223 })) {
            $lineHash = 'v1:sha256:' + [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($lines[$rule.line - 1]))
            ).ToLowerInvariant()
            $declaration = [ordered]@{
                ruleId = $rule.id; repositoryId = $id
                commit = $commit; path = $path.Substring(1)
                section = '## Test coverage'; sectionHash = $sectionHash
                policyLine = $rule.line; policyLineHash = $lineHash
            }
            $canonical = ConvertTo-AgentCanonicalJson -InputObject $declaration
            $declarationHash = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
            $sources[$rule.id] = @{
                approved = $true; ruleId = $rule.id
                organization = 'example-org'
                projectName = 'ExampleSource'; repositoryName = 'ExamplePolicyRepo'
                repositoryId = $id; commit = $commit; path = $path
                provenance = 'unmerged-reviewed-pr'; reviewedPullRequestId = 17307009
                reviewedHead = $commit
                documentHash = 'v1:sha256:' + $digest
                declarationDigest = 'v1:sha256:' + $declarationHash
            }
        }
        $state = @{ calls = 0; content = $document }
        $provider = {
            param($operation, $request)
            if ($operation -cne 'RuleSource') { throw 'unexpected provider operation' }
            $state.calls++
            return @{ content = $state.content; projectName = $request.projectName
                repositoryName = $request.repositoryName
                repositoryId = $request.repositoryId; commit = $request.commit
                path = $request.path }
        }.GetNewClosure()
        return @{ sources = $sources; state = $state; provider = $provider }
    }
}
AfterAll {
    & (Get-Module DevPilot.ActivePrCanary) {
        param($Hash, $Length)
        $script:CoverageDocumentHash = $Hash
        $script:CoverageDocumentLength = $Length
    } $script:originalCoverageSource.hash $script:originalCoverageSource.length
}
Describe 'Immutable unmerged coverage source binding' {
    It 'returns two distinct declaration digests without asserting a current head or signing' {
        $c = Get-CoverageSourceCase
        $result = Assert-CanaryCoverageSource -ApprovedSources $c.sources `
            -Provider $c.provider -SourceSelector $script:sourceSelector `
            -SourceSelectorKey $script:sourceKey -Run
        (@($result.Keys) -join ',') | Should -Be (
            @('schemaVersion', 'state', 'provenance', 'reviewCaution',
                'reviewedPullRequestId', 'reviewedHead', 'headVerified',
                'repositoryId', 'commit', 'path', 'documentHash',
                'declarations') -join ',')
        $result.state | Should -Be 'immutable-candidate-only'
        $result.provenance | Should -Be 'unmerged-reviewed-pr'
        $result.reviewCaution | Should -Be 'pending-human-review; not-master-authority'
        $result.headVerified | Should -BeFalse
        $result.declarations.Count | Should -Be 2
        $result.declarations[0].ruleId | Should -Be 'bpm-test-class-coverage@2'
        $result.declarations[1].ruleId | Should -Be 'bpm-redundant-method-coverage@2'
        $result.declarations[0].declarationDigest |
            Should -Not -Be $result.declarations[1].declarationDigest
        $c.state.calls | Should -Be 1
    }
    It 'defaults off without source reads or private state' {
        $c = Get-CoverageSourceCase
        $result = Assert-CanaryCoverageSource -ApprovedSources $c.sources `
            -Provider $c.provider
        $result.state | Should -Be 'disabled'
        $result.providerReads | Should -Be 0
        $result.providerWrites | Should -Be 0
        $c.state.calls | Should -Be 0
    }
    It 'rejects missing approval, swapped identity, changed head and master provenance before reads' {
        foreach ($failure in @('missing', 'swapped', 'head', 'provenance',
                'wrong-rule', 'declaration')) {
            $c = Get-CoverageSourceCase
            $rule = $c.sources['bpm-redundant-method-coverage@2']
            switch ($failure) {
                missing { $rule.approved = $false }
                swapped { $rule.repositoryId = '55555555-5555-5555-5555-555555555555' }
                head { $rule.reviewedHead = 'a' * 40 }
                provenance { $rule.provenance = 'master' }
                'wrong-rule' { $rule.ruleId = 'bpm-test-class-coverage@2' }
                declaration { $rule.declarationDigest = 'v1:sha256:' + ('0' * 64) }
            }
            { Assert-CanaryCoverageSource -ApprovedSources $c.sources `
                    -Provider $c.provider -SourceSelector $script:sourceSelector `
                    -SourceSelectorKey $script:sourceKey -Run } | Should -Throw
            if ($failure -ne 'declaration') { $c.state.calls | Should -Be 0 }
        }
    }
    It 'rejects changed raw-source text and a misplaced coverage section' {
        $c = Get-CoverageSourceCase
        $c.state.content = $c.state.content.Replace(
            'Exclude every test-project class.', 'Include every test-project class.')
        { Assert-CanaryCoverageSource -ApprovedSources $c.sources `
                -Provider $c.provider -SourceSelector $script:sourceSelector `
                -SourceSelectorKey $script:sourceKey -Run } | Should -Throw '*coverage-source-bytes-mismatch*'
        $c = Get-CoverageSourceCase
        $c.state.content = $c.state.content.Replace(
            'Exclude every test-project class.', "## Unexpected`nTest class text.")
        $rebound = [Text.Encoding]::UTF8.GetBytes($c.state.content)
        & (Get-Module DevPilot.ActivePrCanary) {
            param($Bytes)
            $script:CoverageDocumentHash = Get-CanaryHash $Bytes
            $script:CoverageDocumentLength = $Bytes.Length
        } $rebound
        $c.sources.Values | ForEach-Object {
            $_.documentHash = 'v1:sha256:' + (
                & (Get-Module DevPilot.ActivePrCanary) { $script:CoverageDocumentHash })
        }
        { Assert-CanaryCoverageSource -ApprovedSources $c.sources `
                -Provider $c.provider -SourceSelector $script:sourceSelector `
                -SourceSelectorKey $script:sourceKey -Run } | Should -Throw '*coverage-source-section-mismatch*'
    }
}
