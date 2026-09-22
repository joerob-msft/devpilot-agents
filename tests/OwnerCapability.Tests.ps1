BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force
    $script:OwnerCapabilityModule = Get-Module DevPilot.OwnerCapability

    $script:OwnerCapabilityId = 'owner-mstest-owner-v2'
    $script:OwnerRuleText = 'Changed MSTest methods require an Owner attribute.'
    $script:OwnerCapabilityDigest = $null
    $script:OwnerCases = (
        Get-Content "$PSScriptRoot\fixtures\owner-capability\owner-v2-cases.json" -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
    ).cases

    function Get-TestOwnerV2Digest {
        param([Parameter(Mandatory)][string]$Text)

        return 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
        ).ToLowerInvariant()
    }

    $script:OwnerCapabilityDigest = Get-TestOwnerV2Digest 'owner-mstest-owner-capability-v2'

    function Get-TestOwnerV2Case {
        param([Parameter(Mandatory)][string]$Id)

        return @($script:OwnerCases | Where-Object id -CEQ $Id)[0]
    }

    function New-TestOwnerV2Contract {
        param([string]$SourceCommit = ('a' * 40))

        return New-OwnerAcquisitionContract `
            -RepositoryId 'repository-example' `
            -ProjectId 'project-example' `
            -PullRequestId 42 `
            -SourceCommit $SourceCommit `
            -TargetCommit ('b' * 40) `
            -TargetRef 'refs/heads/main' `
            -RuleRepositoryId 'rules-example' `
            -RulePath '.config/owner-rules.md' `
            -RuleCommit ('c' * 40) `
            -RuleSection 'owner-policy' `
            -RuleHash (Get-TestOwnerV2Digest $script:OwnerRuleText) `
            -RuleLength ([Text.Encoding]::UTF8.GetByteCount($script:OwnerRuleText)) `
            -ConfigId 'owner-preview-config' `
            -ConfigDigest (Get-TestOwnerV2Digest 'owner-preview-config') `
            -CapabilityId $script:OwnerCapabilityId `
            -CapabilityDigest $script:OwnerCapabilityDigest
    }

    function New-TestOwnerV2Package {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Case,
            [Parameter(Mandatory)][object]$Contract,
            [ValidateSet('complete', 'span-incomplete', 'file-incomplete', 'rule-incomplete')]
            [string]$Variant = 'complete'
        )

        $request = $Contract.Request
        $content = @($Case.lines) -join "`n"
        $spans = @(
            foreach ($span in $Case.spans) {
                [ordered]@{
                    startLine = [int]$span.startLine
                    endLine = [int]$span.endLine
                    state = 'complete'
                    sourceDigest = Get-TestOwnerV2Digest (
                        "span:$($Case.id):$($span.startLine):$($span.endLine)"
                    )
                }
            }
        )
        if ($Variant -ceq 'span-incomplete') {
            $spans[0].state = 'incomplete'
        }
        $change = [ordered]@{
            path = [string]$Case.path
            changeType = 'modified'
            isBinary = $false
            sourceDigest = Get-TestOwnerV2Digest "change:$($Case.id)"
            spans = $spans
        }
        $identity = [ordered]@{
            schemaVersion = 1
            repositoryId = $request.RepositoryId
            projectId = $request.ProjectId
            pullRequestId = $request.PullRequestId
            sourceCommit = $request.SourceCommit
            targetCommit = $request.TargetCommit
            targetRef = $request.TargetRef
        }
        $subject = [ordered]@{} + $identity
        $subject['changedFileCount'] = 1
        $subject['state'] = 'complete'
        $subject['sourceDigest'] = Get-TestOwnerV2Digest "subject:$($request.SourceCommit)"
        $page = [ordered]@{} + $identity
        $page['pageOrdinal'] = 0
        $page['continuationToken'] = $null
        $page['nextToken'] = $null
        $page['state'] = 'complete'
        $page['sourceDigest'] = Get-TestOwnerV2Digest "page:$($Case.id)"
        $page['changes'] = @($change)
        $rule = [ordered]@{} + $identity
        $rule['ruleRepositoryId'] = $request.RuleRepositoryId
        $rule['rulePath'] = $request.RulePath
        $rule['ruleCommit'] = $request.RuleCommit
        $rule['ruleSection'] = $request.RuleSection
        $rule['ruleHash'] = $request.RuleHash
        $rule['ruleLength'] = $request.RuleLength
        $rule['state'] = if ($Variant -ceq 'rule-incomplete') { 'incomplete' } else { 'complete' }
        $rule['content'] = if ($Variant -ceq 'rule-incomplete') { $null } else { $script:OwnerRuleText }
        $rule['sourceDigest'] = Get-TestOwnerV2Digest 'owner-rule-source'
        $file = [ordered]@{} + $identity
        $file['path'] = [string]$Case.path
        $file['state'] = if ($Variant -ceq 'file-incomplete') { 'incomplete' } else { 'complete' }
        $file['byteLength'] = [Text.Encoding]::UTF8.GetByteCount($content)
        $file['truncated'] = $false
        $file['content'] = if ($Variant -ceq 'file-incomplete') { $null } else { $content }
        $file['sourceDigest'] = Get-TestOwnerV2Digest $content
        if ($Variant -ceq 'file-incomplete') {
            $file['unavailableReason'] = 'incomplete'
        }

        return [ordered]@{
            schemaVersion = 1
            semantics = 'owner-acquisition-v1'
            contractDigest = 'v1:sha256:7a6f3a79b5b87e38c8ca92a19886fff1f814336e331da8136c860f4f101d85b5'
            subjectBefore = $subject
            changePages = @($page)
            rule = $rule
            files = @($file)
            subjectAfter = ([ordered]@{} + $subject)
        }
    }

    function New-TestOwnerV2Runner {
        param([Collections.IDictionary]$Modes = @{})

        $requests = [Collections.Generic.List[object]]::new()
        $capturedModes = $Modes
        $runner = New-OwnerSemanticRunner -Name 'deterministic-offline-owner-runner' -Handler {
            param($request)
            $copy = ConvertFrom-Json -InputObject (
                ConvertTo-Json -InputObject $request -Depth 16 -Compress
            ) -AsHashtable -Depth 16
            [void]$requests.Add($copy)
            $mode = if ($capturedModes.Contains([string]$request.construct.name)) {
                [string]$capturedModes[[string]$request.construct.name]
            }
            else {
                'valid'
            }
            switch ($mode) {
                'malformed' {
                    return @{
                        schemaVersion = 2
                        executionUnitId = $request.executionUnitId
                        disposition = 'violation'
                    }
                }
                'omitted' { return }
                'duplicated' {
                    Write-Output @{
                        schemaVersion = 2
                        executionUnitId = $request.executionUnitId
                        judgment = 'violation'
                    }
                    Write-Output @{
                        schemaVersion = 2
                        executionUnitId = $request.executionUnitId
                        judgment = 'violation'
                    }
                    return
                }
                default {
                    $judgment = if (@($request.construct.attributes) -contains 'Owner') {
                        'compliant'
                    }
                    else {
                        'violation'
                    }
                    return @{
                        schemaVersion = 2
                        executionUnitId = $request.executionUnitId
                        judgment = $judgment
                    }
                }
            }
        }.GetNewClosure()
        return [pscustomobject]@{
            Runner = $runner
            Requests = $requests
        }
    }

    function Invoke-TestOwnerV2Case {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Case,
            [ValidateSet('complete', 'span-incomplete', 'file-incomplete', 'rule-incomplete')]
            [string]$Variant = 'complete',
            [string]$SourceCommit = ('a' * 40),
            [Collections.IDictionary]$RunnerModes = @{}
        )

        $contract = New-TestOwnerV2Contract -SourceCommit $SourceCommit
        $package = New-TestOwnerV2Package -Case $Case -Contract $contract -Variant $Variant
        $fixture = New-OwnerReplayFixture -Package $package
        $runner = New-TestOwnerV2Runner -Modes $RunnerModes
        $capabilityAdapter = New-OwnerV2CapabilityAdapter `
            -Runner $runner.Runner `
            -CapabilityId $script:OwnerCapabilityId `
            -CapabilityDigest $script:OwnerCapabilityDigest
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter (New-OwnerReplayAcquisitionAdapter `
                -Contract $contract `
                -Fixture $fixture `
                -ExpectedPayloadDigest $fixture.PayloadDigest) `
            -CapabilityAdapter $capabilityAdapter
        if ($null -eq $result.preview) {
            throw 'Pipeline did not reach the preview stage.'
        }
        return [pscustomobject]@{
            Contract = $contract
            Result = $result
            Requests = $runner.Requests
            Observation = ConvertTo-OwnerV2Observation -PipelineResult $result
        }
    }

    function Get-TestOwnerV1WriterComment {
        param(
            [Parameter(Mandatory)][object]$Contract,
            [Parameter(Mandatory)][Collections.IDictionary]$Finding
        )
        return & $script:OwnerCapabilityModule {
            param($BoundContract, $BoundFinding)
            $marker = Get-OwnerV1WriterMarkerKey `
                -Contract $BoundContract -Finding $BoundFinding
            [pscustomobject]@{
                Marker = $marker
                Body = Format-OwnerV1WriterComment `
                    -Contract $BoundContract -Finding $BoundFinding -MarkerKey $marker
            }
        } $Contract $Finding
    }

    function New-TestOwnerDiscussionSnapshot {
        param(
            [Parameter(Mandatory)][object]$Contract,
            [AllowEmptyCollection()][object[]]$Threads = @()
        )
        $request = $Contract.Request
        $page = [ordered]@{
            schemaVersion = 1
            repositoryId = $request.RepositoryId
            projectId = $request.ProjectId
            pullRequestId = $request.PullRequestId
            sourceCommit = $request.SourceCommit
            targetCommit = $request.TargetCommit
            targetRef = $request.TargetRef
            pageOrdinal = 0
            state = 'complete'
            sourceDigest = Get-TestOwnerV2Digest 'discussion-page'
            nextToken = $null
            threads = @($Threads)
        }
        $provider = New-OwnerReadOnlyProviderAdapter -Name 'owner-discussion-fixture' -Handler {
            param($Operation, $Arguments)
            if ($Operation -cne 'GetDiscussionPage' -or [int]$Arguments.pageOrdinal -ne 0) {
                throw 'unexpected discussion operation'
            }
            return $page
        }.GetNewClosure()
        return Get-OwnerDiscussionSnapshot -Contract $Contract -Provider $provider
    }

    function New-TestOwnerDiscussionThread {
        param(
            [Parameter(Mandatory)][object]$Contract,
            [Parameter(Mandatory)][Collections.IDictionary]$Finding,
            [Parameter(Mandatory)][string]$Body,
            [int]$ThreadId = 10,
            [int]$CommentId = 100,
            [string]$Status = 'active',
            [bool]$ReviewerOwned = $true,
            [bool]$ThreadDeleted = $false,
            [bool]$CommentDeleted = $false,
            [bool]$Outdated = $false,
            [AllowNull()][string]$SourceCommit = $null,
            [AllowNull()][string]$Path = $null,
            [int]$Line = 0
        )
        return [ordered]@{
            threadId = $ThreadId
            status = $Status
            isDeleted = $ThreadDeleted
            isOutdated = $Outdated
            sourceCommit = $(if ($PSBoundParameters.ContainsKey('SourceCommit')) {
                    $SourceCommit
                }
                else {
                    [string]$Contract.Request.SourceCommit
                })
            anchor = [ordered]@{
                path = $(if (-not [string]::IsNullOrWhiteSpace($Path)) {
                        $Path
                    }
                    else {
                        [string]$Finding.anchor.path
                    })
                line = $(if ($Line -gt 0) { $Line } else { [int]$Finding.anchor.line })
            }
            comments = @(
                [ordered]@{
                    commentId = $CommentId
                    commentType = 'text'
                    isDeleted = $CommentDeleted
                    reviewerOwned = $ReviewerOwned
                    body = $Body
                    bodyDigest = Get-TestOwnerV2Digest $Body
                }
            )
        }
    }
}

Describe 'Owner v2 semantic capability' {
    It 'pins the approved v1 writer marker and body bytes with a frozen golden' {
        $contract = New-TestOwnerV2Contract
        $finding = [ordered]@{
            anchor = [ordered]@{
                path = 'src/WidgetTests.cs'
                line = 7
                symbol = 'NeedsOwner'
            }
        }
        $actual = Get-TestOwnerV1WriterComment -Contract $contract -Finding $finding
        $expectedBody = @(
            '**Owner attribute missing**'
            ''
            'Method `NeedsOwner` at `/src/WidgetTests.cs:7` is a changed MSTest method and has no `Owner` attribute.'
            ''
            'Suggested fix: add `[Owner("<owner-alias>")]` to this test method.'
            ''
            'Rule: `/.config/owner-rules.md` / `owner-policy` at `cccccccccccccccccccccccccccccccccccccccc` (SHA-256 `33498ffae13dc90a8a3194dd5c8859906c7406e09b9ce14fe2f6482796529d19`).'
            ''
            '<!-- devpilot-owner-comment:v1:9642698498d4e90b0a84cf948cb521f68cae5a8f84718821fda7f722a7a6233c -->'
        ) -join "`n"

        $actual.Marker | Should -BeExactly (
            '9642698498d4e90b0a84cf948cb521f68cae5a8f84718821fda7f722a7a6233c'
        )
        $actual.Body | Should -BeExactly $expectedBody
    }

    It 'assesses only changed MSTest methods and keeps classes advisory and unknown' {
        $case = Get-TestOwnerV2Case -Id 'proven-owner-cases'
        $run = Invoke-TestOwnerV2Case -Case $case

        @($run.Result.stages.name) -join ' -> ' | Should -Be (
            'Acquire snapshot -> Build evidence -> Run capability -> ' +
            'Validate findings -> Preview -> Authorize delivery')
        @($run.Requests.construct.name) | Should -Be @($case.expectedRunnerMethods)
        @($run.Requests.construct.name) | Should -Not -Contain 'HelperMethod'
        @($run.Requests.construct.name) | Should -Not -Contain 'OutsideSpan'
        @($run.Requests.construct.kind | Select-Object -Unique) | Should -Be @('method')

        $run.Result.state | Should -Be 'unknown'
        $run.Result.preview.writeAllowed | Should -BeFalse
        $run.Result.delivery.state | Should -Be 'not-authorized'
        $run.Result.delivery.writeCount | Should -Be 0
        $run.Result.preview.findings.Count | Should -Be $case.expectedViolationCount
        @($run.Result.preview.findings.data.anchor.line | Sort-Object) |
            Should -Be @($case.expectedViolationLines)
        @($run.Result.validation.assessments |
                Where-Object assessmentId -Like 'class:*' |
                Where-Object state -CEQ unknown).Count |
            Should -Be $case.expectedClassUnknownCount
        @($run.Result.preview.findings.data.eligibility | Select-Object -Unique) |
            Should -Be @('changed-mstest-method')
        @($run.Result.preview.findings.data.anchor.symbol) | Should -Not -Contain 'WidgetTests'
        @($run.Result.preview.findings | ForEach-Object { @($_.evidenceUnitIds) -join ',' } |
                Select-Object -Unique) |
            Should -Be @('identity,rule,file:000000')

        $run.Observation.counts.checked | Should -Be 7
        $run.Observation.counts.violations | Should -Be 4
        $run.Observation.counts.unknown | Should -Be 0
        $run.Observation.counts.advisory | Should -Be 1
        $run.Observation.counts.uncovered | Should -Be 0
        @($run.Observation.outcomes | Where-Object state -CEQ advisory).Count | Should -Be 1
        @($run.Observation.outcomes | Where-Object writerEligible).Count | Should -Be 0
        $run.Observation.lifecycle.completed | Should -BeTrue
        $run.Observation.findingsComplete | Should -BeTrue
        $run.Observation.execution.attempts | Should -Be 4
        $run.Observation.execution.modelStarts | Should -Be 'unknown'
        $run.Observation.measurements.execution.modelStarts.status | Should -Be 'notMeasured'
        $run.Observation.effects.providerWrites | Should -Be 0
        $run.Observation.effects.writeToolInvocations | Should -Be 0
        $run.Observation.effects.dedupe.noOp | Should -Be 0
        $run.Observation.effects.dedupe.unknown | Should -BeGreaterThan 0
    }

    It 'preserves valid sibling findings when adjacent runner units are malformed, omitted, or duplicated' {
        $case = Get-TestOwnerV2Case -Id 'adjacent-response-failures'
        $run = Invoke-TestOwnerV2Case -Case $case -RunnerModes $case.runnerModes

        $run.Result.state | Should -Be 'unknown'
        @($run.Result.preview.findings.data.anchor.symbol | Sort-Object) |
            Should -Be @($case.expectedViolationMethods | Sort-Object)
        @($run.Result.validation.assessments |
                Where-Object assessmentId -Like 'method:*' |
                Where-Object state -CEQ unknown).Count |
            Should -Be $case.expectedRunnerUnknownCount
        @($run.Result.diagnostics.code) | Should -Contain 'runner-response-invalid'
        $run.Observation.counts.violations | Should -Be 3
        $run.Observation.counts.unknown | Should -Be 3
        $run.Observation.counts.advisory | Should -Be 1
        @($run.Observation.findings | Where-Object disposition -CEQ violation).Count |
            Should -Be 3
        @($run.Observation.outcomes | Where-Object state -CEQ unknown).Count |
            Should -Be 3
    }

    It 'keeps incomplete file, span, and rule evidence unknown without starting the runner' -TestCases @(
        @{ Variant = 'file-incomplete' }
        @{ Variant = 'span-incomplete' }
        @{ Variant = 'rule-incomplete' }
    ) {
        param($Variant)
        $case = Get-TestOwnerV2Case -Id 'proven-owner-cases'
        $run = Invoke-TestOwnerV2Case -Case $case -Variant $Variant

        $run.Result.state | Should -Be 'unknown'
        $run.Result.preview.findings.Count | Should -Be 0
        $run.Requests.Count | Should -Be 0
        @($run.Result.validation.unitCoverage.state | Select-Object -Unique) |
            Should -Be @('unknown')
        $run.Observation.counts.violations | Should -Be 0
        $run.Observation.findingsComplete | Should -BeFalse
        $run.Observation.counts.uncovered | Should -BeGreaterThan 0
        @($run.Observation.outcomes | Where-Object state -CEQ uncovered).Count | Should -BeGreaterThan 0
    }

    It 'produces stable wrapper identities and changes them when the bound head changes' {
        $case = Get-TestOwnerV2Case -Id 'proven-owner-cases'
        $first = Invoke-TestOwnerV2Case -Case $case
        $second = Invoke-TestOwnerV2Case -Case $case
        $changedHead = Invoke-TestOwnerV2Case -Case $case -SourceCommit ('d' * 40)

        @($first.Result.preview.findings.findingId) |
            Should -Be @($second.Result.preview.findings.findingId)
        @($first.Result.preview.findings.data.constructRef) |
            Should -Be @($second.Result.preview.findings.data.constructRef)
        @($first.Result.preview.findings.findingId) |
            Should -Not -Be @($changedHead.Result.preview.findings.findingId)
        @($first.Result.preview.findings.data.headCommit | Select-Object -Unique) |
            Should -Be @(('a' * 40))
        @($changedHead.Result.preview.findings.data.headCommit | Select-Object -Unique) |
            Should -Be @(('d' * 40))

        $sameNamed = @($first.Result.preview.findings |
                Where-Object { $_.data.anchor.symbol -ceq 'DuplicateName' })
        $sameNamed.Count | Should -Be 2
        @($sameNamed.findingId | Select-Object -Unique).Count | Should -Be 2
        @($sameNamed.data.anchor.line | Sort-Object) | Should -Be @(29, 32)
    }

    It 'keeps the runner judgment-only and preserves wrapper-owned atomic bindings' {
        $case = Get-TestOwnerV2Case -Id 'proven-owner-cases'
        $run = Invoke-TestOwnerV2Case -Case $case

        foreach ($request in $run.Requests) {
            @($request.Keys | Sort-Object) |
                Should -Be @('capability', 'construct', 'executionUnitId', 'rule', 'schemaVersion', 'semantics')
            (ConvertTo-Json $request -Depth 16 -Compress) |
                Should -Not -Match '(?i)write|authoriz|delivery|comment|vote|approval'
            @($request.construct.Keys | Sort-Object) |
                Should -Be @('attributes', 'kind', 'name', 'snippet')
        }
        foreach ($finding in $run.Result.preview.findings) {
            $finding.data.bindingId | Should -Be $run.Contract.Binding.BindingId
            $finding.data.evidenceDigest | Should -Be $run.Result.evidence.evidenceDigest
            $finding.data.capabilityId | Should -Be $script:OwnerCapabilityId
            $finding.data.ruleRef | Should -Match '^rule:[0-9a-f]{64}$'
            $finding.data.groupRef | Should -Be $finding.assessmentId
            @($finding.evidenceUnitIds) | Should -Be @('identity', 'rule', 'file:000000')
        }
    }

    It 'recognizes array signatures and comments while degrading unknown declarations explicitly' {
        $case = Get-TestOwnerV2Case -Id 'recognizer-compatibility'
        $run = Invoke-TestOwnerV2Case -Case $case

        @($run.Requests.construct.name) | Should -Be @($case.expectedRunnerMethods)
        @($run.Result.preview.findings.data.anchor.line | Sort-Object) |
            Should -Be @($case.expectedViolationLines)
        @($run.Result.validation.assessments |
                Where-Object assessmentId -Like 'method:n:*' |
                Where-Object state -CEQ unknown).Count |
            Should -Be $case.expectedUnrecognizedMethodCount
        @($run.Result.diagnostics.code) | Should -Contain 'construct-unrecognized'
        $run.Result.state | Should -Be 'unknown'
        $run.Observation.counts.violations | Should -Be 8
        $run.Observation.counts.unknown | Should -Be 1
        $run.Observation.counts.advisory | Should -Be 1
        @($run.Observation.outcomes | Where-Object state -CEQ unknown).Count | Should -Be 1
    }

    It 'rejects attribute-argument spoofing and masks multi-line verbatim string contents' {
        $case = Get-TestOwnerV2Case -Id 'lexical-spoofing'
        $run = Invoke-TestOwnerV2Case -Case $case

        @($run.Requests.construct.name) | Should -Be @($case.expectedRunnerMethods)
        foreach ($excluded in $case.excludedMethods) {
            @($run.Requests.construct.name) | Should -Not -Contain $excluded
        }
        @($run.Result.preview.findings.data.anchor.line | Sort-Object) |
            Should -Be @($case.expectedViolationLines)
        $run.Result.preview.findings.Count | Should -Be 4
        @($run.Result.preview.findings.data.anchor.symbol) |
            Should -Contain 'OwnerIdentifierArgument'
        @($run.Observation.outcomes | Where-Object { $_.binding.symbol -ceq 'comment' }).Count | Should -Be 0
        @($run.Result.diagnostics.code) | Should -Not -Contain 'construct-unrecognized'
    }

    It 'masks raw string contents and makes trailing same-line attributes explicit unknowns' {
        $case = Get-TestOwnerV2Case -Id 'raw-and-trailing-attributes'
        $run = Invoke-TestOwnerV2Case -Case $case

        @($run.Requests.construct.name) | Should -Be @($case.expectedRunnerMethods)
        foreach ($excluded in $case.excludedMethods) {
            @($run.Requests.construct.name) | Should -Not -Contain $excluded
        }
        @($run.Result.preview.findings.data.anchor.line | Sort-Object) |
            Should -Be @($case.expectedViolationLines)
        @($run.Result.validation.assessments |
                Where-Object assessmentId -Like 'method:n:*' |
                Where-Object state -CEQ unknown).Count |
            Should -Be $case.expectedUnrecognizedMethodCount
        @($run.Result.diagnostics.code) | Should -Contain 'construct-unrecognized'
        @($run.Observation.outcomes | Where-Object { $_.binding.symbol -ceq 'comment' }).Count | Should -Be 0
        $run.Observation.effects.dedupe.unknown |
            Should -BeGreaterOrEqual $run.Observation.counts.violations
    }

    It 'completes files without attributed constructs instead of failing the capability' {
        $case = Get-TestOwnerV2Case -Id 'no-attributed-constructs'
        foreach ($path in @('src/Plain.cs', 'docs/readme.md')) {
            $copy = ConvertFrom-Json -InputObject (
                ConvertTo-Json -InputObject $case -Depth 16 -Compress
            ) -AsHashtable -Depth 16
            $copy.path = $path
            $run = Invoke-TestOwnerV2Case -Case $copy

            $run.Result.state | Should -Be 'complete'
            $run.Requests.Count | Should -Be 0
            $run.Result.preview.findings.Count | Should -Be 0
            @($run.Result.validation.assessments |
                    Where-Object assessmentId -Like 'file:*').state |
                Should -Be @('complete')
            $run.Observation.lifecycle.completed | Should -BeTrue
            $run.Observation.findingsComplete | Should -BeTrue
            $run.Observation.counts.eligible | Should -Be 0
            $run.Observation.counts.advisory | Should -Be 0
            $run.Observation.counts.unknown | Should -Be 0
            $run.Observation.measurements.counts.eligible.status | Should -Be 'measured'
            $run.Observation.measurements.counts.eligible.value | Should -Be 0
        }
    }

    It 'completes class-only input as advisory without claiming method compliance' {
        $case = [ordered]@{
            id = 'class-only'
            path = 'src/ClassOnly.cs'
            lines = @('[TestClass]', '[Owner("advisory")]', 'public class ClassOnly {}')
            spans = @([ordered]@{ startLine = 1; endLine = 3 })
        }
        $run = Invoke-TestOwnerV2Case -Case $case

        $run.Observation.lifecycle.completed | Should -BeTrue
        $run.Observation.counts.checked | Should -Be 0
        $run.Observation.counts.eligible | Should -Be 0
        $run.Observation.counts.advisory | Should -Be 1
        $run.Observation.counts.violations | Should -Be 0
        $run.Observation.counts.unknown | Should -Be 0
        @($run.Observation.outcomes).Count | Should -Be 1
        $run.Observation.outcomes[0].state | Should -Be 'advisory'
        $run.Observation.outcomes[0].reason | Should -Be 'class-advisory-only'
        $run.Observation.outcomes[0].writerEligible | Should -BeFalse
    }

    It 'exposes ten stable non-eligible construct outcomes without widening method execution' {
        $case = Get-TestOwnerV2Case -Id 'non-eligible-unknown-parity'
        $first = Invoke-TestOwnerV2Case -Case $case
        $second = Invoke-TestOwnerV2Case -Case $case

        @($first.Requests.construct.name) | Should -Be @($case.expectedRunnerMethods)
        @($first.Observation.outcomes | Where-Object state -CEQ notEligible).Count |
            Should -Be $case.expectedNotEligibleCount
        @($first.Observation.outcomes | Where-Object reason -CEQ (
                    'owner-rule-applies-only-to-test-classes-and-methods'
                )).Count | Should -Be $case.expectedNotEligibleCount
        @($first.Observation.outcomes | Where-Object writerEligible).Count | Should -Be 0
        @($first.Observation.outcomes |
                Where-Object { $_.binding.symbol -ceq 'Format' }).Count |
            Should -Be 1
        @($first.Observation.outcomes |
                Where-Object state -CEQ notEligible |
                ForEach-Object identity) |
            Should -Be @($second.Observation.outcomes |
                Where-Object state -CEQ notEligible |
                ForEach-Object identity)
        @($first.Observation.outcomes |
                Where-Object state -CEQ notEligible |
                ForEach-Object semanticKey) |
            Should -Not -Contain 'unknown'
        $first.Observation.lifecycle.completed | Should -BeTrue
        $first.Observation.findingsComplete | Should -BeTrue
        $first.Observation.counts.unknown | Should -Be 0
        $first.Observation.counts.violations | Should -Be 1
    }

    It 'emits an incomplete all-unknown observation with explicit denominators' {
        $case = Get-TestOwnerV2Case -Id 'adjacent-response-failures'
        $modes = @{}
        foreach ($name in @(
                'ValidFirst', 'Malformed', 'ValidMiddle', 'Omitted', 'Duplicated', 'ValidLast')) {
            $modes[$name] = 'omitted'
        }
        $run = Invoke-TestOwnerV2Case -Case $case -RunnerModes $modes

        $run.Observation.lifecycle.completed | Should -BeFalse
        $run.Observation.counts.checked | Should -Be 0
        $run.Observation.counts.eligible | Should -Be 6
        $run.Observation.counts.advisory | Should -Be 1
        $run.Observation.counts.unknown | Should -Be 6
        $run.Observation.counts.uncovered | Should -Be 0
        $run.Observation.findings.Count | Should -Be 0
        @($run.Observation.outcomes | Where-Object state -CEQ unknown).Count |
            Should -Be 6
    }

    It 'accounts every preview finding in unknown dedupe outcomes' {
        foreach ($id in @('proven-owner-cases', 'recognizer-compatibility')) {
            $run = Invoke-TestOwnerV2Case -Case (Get-TestOwnerV2Case -Id $id)
            $run.Observation.effects.dedupe.unknown |
                Should -BeGreaterOrEqual $run.Observation.counts.violations
        }
    }

    It 'reconciles v1-compatible Owner markers without exposing discussions to the semantic runner' {
            $base = Invoke-TestOwnerV2Case -Case (Get-TestOwnerV2Case -Id 'proven-owner-cases')
            $finding = $base.Observation.findings[0]
            $writer = Get-TestOwnerV1WriterComment -Contract $base.Contract -Finding $finding

            $cases = @(
                [ordered]@{
                    Name = 'no matching thread'
                    Threads = @()
                    Classification = 'wouldCreate'
                    Reason = 'reviewer-marker-not-found'
                },
                [ordered]@{
                    Name = 'exact current reviewer comment'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body $writer.Body)
                    Classification = 'noOp'
                    Reason = 'reviewer-marker-body-current'
                },
                [ordered]@{
                    Name = 'stale reviewer body'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body (
                                "stale body`n<!-- devpilot-owner-comment:v1:$($writer.Marker) -->"
                            ))
                    Classification = 'wouldUpdate'
                    Reason = 'reviewer-marker-body-stale'
                },
                [ordered]@{
                    Name = 'quoted unrelated marker'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body (
                                $writer.Body + "`n<!-- devpilot-owner-comment:v1:$('f' * 64) -->"
                            ))
                    Classification = 'wouldUpdate'
                    Reason = 'reviewer-marker-body-stale'
                },
                [ordered]@{
                    Name = 'unrelated human comment'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body 'please consider this' -ReviewerOwned $false)
                    Classification = 'wouldCreate'
                    Reason = 'reviewer-marker-not-found'
                },
                [ordered]@{
                    Name = 'foreign copied marker'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body $writer.Body -ReviewerOwned $false)
                    Classification = 'wouldCreate'
                    Reason = 'reviewer-marker-not-found'
                },
                [ordered]@{
                    Name = 'closed reviewer thread'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body $writer.Body -Status closed)
                    Classification = 'wouldCreate'
                    Reason = 'reviewer-marker-thread-inactive'
                },
                [ordered]@{
                    Name = 'deleted reviewer thread'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body $writer.Body -ThreadDeleted $true)
                    Classification = 'wouldCreate'
                    Reason = 'reviewer-marker-thread-deleted'
                },
                [ordered]@{
                    Name = 'outdated reviewer thread'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body $writer.Body -Outdated $true)
                    Classification = 'wouldCreate'
                    Reason = 'reviewer-marker-thread-outdated'
                },
                [ordered]@{
                    Name = 'current-head mismatch'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body $writer.Body -SourceCommit ('d' * 40))
                    Classification = 'unknown'
                    Reason = 'reviewer-marker-source-mismatch'
                },
                [ordered]@{
                    Name = 'unreadable reviewer anchor'
                    Threads = @(New-TestOwnerDiscussionThread -Contract $base.Contract `
                            -Finding $finding -Body $writer.Body -Path 'src/a`b.cs')
                    Classification = 'unknown'
                    Reason = 'reviewer-marker-anchor-unreadable'
                }
            )

            foreach ($case in $cases) {
                $run = Invoke-TestOwnerV2Case -Case (Get-TestOwnerV2Case -Id 'proven-owner-cases')
                $snapshot = New-TestOwnerDiscussionSnapshot -Contract $run.Contract -Threads $case.Threads
                $beforeRequests = $run.Requests.Count
                $reconciled = Resolve-OwnerV2DiscussionReconciliation `
                    -Observation $run.Observation -Contract $run.Contract -Snapshot $snapshot
                $result = $reconciled.findings[0].reconciliation
                $result.classification | Should -Be $case.Classification -Because $case.Name
                $result.reason | Should -Be $case.Reason -Because $case.Name
                $run.Requests.Count | Should -Be $beforeRequests
                $reconciled.effects.providerWrites | Should -Be 0
                $reconciled.effects.writeToolInvocations | Should -Be 0
                $reconciled.findings[0].providerMarker.availability |
                    Should -Be 'available'
            }
        }

    It 'fails duplicate reviewer markers closed and keeps acquisition failures separate from semantic verdicts' {
            $run = Invoke-TestOwnerV2Case -Case (Get-TestOwnerV2Case -Id 'proven-owner-cases')
            $finding = $run.Observation.findings[0]
            $writer = Get-TestOwnerV1WriterComment -Contract $run.Contract -Finding $finding
            $threads = @(
                New-TestOwnerDiscussionThread -Contract $run.Contract -Finding $finding `
                    -Body $writer.Body -ThreadId 10 -CommentId 100
                New-TestOwnerDiscussionThread -Contract $run.Contract -Finding $finding `
                    -Body $writer.Body -ThreadId 11 -CommentId 101
            )
            $snapshot = New-TestOwnerDiscussionSnapshot -Contract $run.Contract -Threads $threads
            $duplicate = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $run.Observation -Contract $run.Contract -Snapshot $snapshot

            $duplicate.findings[0].reconciliation.classification | Should -Be 'unknown'
            $duplicate.findings[0].reconciliation.reason | Should -Be 'duplicate-reviewer-markers'
            $duplicate.findings[0].providerMarker.integrity | Should -Be 'invalid'

            $failedRun = Invoke-TestOwnerV2Case -Case (Get-TestOwnerV2Case -Id 'proven-owner-cases')
            $semanticDisposition = $failedRun.Observation.findings[0].disposition
            $semanticLifecycle = $failedRun.Observation.lifecycle.status
            $failed = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $failedRun.Observation -Contract $failedRun.Contract `
                -Snapshot $null -FailureReason discussion-acquisition-failed

            $failed.findings[0].disposition | Should -Be $semanticDisposition
            $failed.lifecycle.status | Should -Be $semanticLifecycle
            $failed.findings[0].reconciliation.classification | Should -Be 'unknown'
            $failed.findings[0].reconciliation.reason | Should -Be 'discussion-acquisition-failed'
            $failed.effects.providerWrites | Should -Be 0
            $failed.effects.writeToolInvocations | Should -Be 0
        }

        It 'does not turn findings from an incomplete semantic run into an actionable queue' {
            $run = Invoke-TestOwnerV2Case `
                -Case (Get-TestOwnerV2Case -Id 'adjacent-response-failures') `
                -RunnerModes @{ Malformed = 'omitted' }
            $snapshot = New-TestOwnerDiscussionSnapshot -Contract $run.Contract
            $unknownBefore = $run.Observation.effects.dedupe.unknown

            $result = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $run.Observation -Contract $run.Contract -Snapshot $snapshot

            $result.lifecycle.status | Should -Be 'incomplete'
            $result.counts.violations | Should -BeGreaterThan 0
            $result.effects.dedupe.unknown | Should -Be $unknownBefore
            $result.effects.dedupe.wouldCreate | Should -Be 0
            $result.findings[0].Contains('reconciliation') | Should -BeFalse
        }

        It 'is idempotent for the same semantic observation and discussion replay' {
            $first = Invoke-TestOwnerV2Case -Case (Get-TestOwnerV2Case -Id 'proven-owner-cases')
            $finding = $first.Observation.findings[0]
            $writer = Get-TestOwnerV1WriterComment -Contract $first.Contract -Finding $finding
            $snapshot = New-TestOwnerDiscussionSnapshot -Contract $first.Contract -Threads @(
                New-TestOwnerDiscussionThread -Contract $first.Contract -Finding $finding -Body $writer.Body
            )
            $second = Invoke-TestOwnerV2Case -Case (Get-TestOwnerV2Case -Id 'proven-owner-cases')

            $firstResult = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $first.Observation -Contract $first.Contract -Snapshot $snapshot
            $secondResult = Resolve-OwnerV2DiscussionReconciliation `
                -Observation $second.Observation -Contract $second.Contract -Snapshot $snapshot

            ($firstResult | ConvertTo-Json -Depth 64 -Compress) |
                Should -Be ($secondResult | ConvertTo-Json -Depth 64 -Compress)
    }

    It 'emits the narrow normalized observation shape documented by the independent observer layer' {
        $case = Get-TestOwnerV2Case -Id 'proven-owner-cases'
        $observation = (Invoke-TestOwnerV2Case -Case $case).Observation

        @($observation.Keys) | Should -Be @(
            'schemaVersion', 'kind', 'implementation', 'capability', 'subject', 'rule',
            'lifecycle', 'counts', 'findingsComplete', 'findings', 'outcomes', 'execution',
            'effects', 'measurements', 'sourceArtifacts', 'validationErrors'
        )
        $observation.schemaVersion | Should -Be 2
        $observation.kind | Should -Be 'owner-observation'
        $observation.capability | Should -Be $script:OwnerCapabilityId
        $observation.subject.headCommit | Should -Be ('a' * 40)
        $observation.rule.identity | Should -Match '^rule:[0-9a-f]{64}$'
        $observation.rule.sha256 | Should -Match '^[0-9a-f]{64}$'
        @($observation.findings.disposition | Select-Object -Unique | Sort-Object) |
            Should -Be @('violation')
        $observation.sourceArtifacts[0].sha256 | Should -Match '^[0-9a-f]{64}$'
        $observation.lifecycle.pending | Should -BeFalse
        $observation.effects.operatorIntervention | Should -BeTrue
    }
}

Describe 'Owner capability module surface' {
    It 'exports only the preview capability contract and adapter seam' {
        @((Get-Command -Module DevPilot.OwnerCapability).Name | Sort-Object) | Should -Be @(
            'ConvertTo-OwnerV2Observation',
            'New-OwnerSemanticRunner',
            'New-OwnerV2CapabilityAdapter',
            'New-OwnerV2CapabilityLimits',
            'Resolve-OwnerV2DiscussionReconciliation'
        )
    }
}
