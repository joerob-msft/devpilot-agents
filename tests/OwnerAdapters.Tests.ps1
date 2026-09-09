BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force

    function Get-TestOwnerDigest {
        param([Parameter(Mandatory)][string]$Text)

        return 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
        ).ToLowerInvariant()
    }

    function Copy-TestOwnerValue {
        param([Parameter(Mandatory)][object]$Value)

        return ConvertFrom-Json -InputObject (
            ConvertTo-Json -InputObject $Value -Depth 32 -Compress
        ) -AsHashtable -Depth 32
    }

    function New-TestOwnerContract {
        param(
            [string]$SourceCommit = ('a' * 40),
            [string]$TargetCommit = ('b' * 40),
            [string]$TargetRef = 'refs/heads/main',
            [object]$Limits = (New-OwnerAdapterLimits)
        )

        $ruleText = 'require review'
        return New-OwnerAcquisitionContract `
            -RepositoryId 'repository-example' `
            -ProjectId 'project-example' `
            -PullRequestId 42 `
            -SourceCommit $SourceCommit `
            -TargetCommit $TargetCommit `
            -TargetRef $TargetRef `
            -RuleRepositoryId 'rules-example' `
            -RulePath '.config/owner-rules.md' `
            -RuleCommit ('c' * 40) `
            -RuleSection 'review-policy' `
            -RuleHash (Get-TestOwnerDigest $ruleText) `
            -RuleLength ([Text.Encoding]::UTF8.GetByteCount($ruleText)) `
            -ConfigId 'config-example' `
            -ConfigDigest (Get-TestOwnerDigest 'config') `
            -CapabilityId 'capability-example' `
            -CapabilityDigest (Get-TestOwnerDigest 'capability') `
            -Limits $Limits
    }

    function New-TestOwnerChange {
        param(
            [Parameter(Mandatory)][string]$Path,
            [ValidateSet('added', 'modified', 'deleted', 'renamed')][string]$ChangeType = 'modified',
            [AllowNull()][string]$OldPath = $null,
            [bool]$IsBinary = $false,
            [string]$SpanState = 'complete',
            [AllowEmptyCollection()][object[]]$Spans
        )

        $effectiveSpans = if ($PSBoundParameters.ContainsKey('Spans')) {
            [object[]]$Spans
        }
        else {
            [object[]]@(
                [ordered]@{
                    startLine = 1
                    endLine = 3
                    state = $SpanState
                    sourceDigest = Get-TestOwnerDigest "span:$Path"
                }
            )
        }
        $change = [ordered]@{
            path = $Path
            changeType = $ChangeType
            isBinary = $IsBinary
            sourceDigest = Get-TestOwnerDigest "change:$Path"
            spans = [object[]]$effectiveSpans
        }
        if (-not [string]::IsNullOrEmpty($OldPath)) {
            $change['oldPath'] = $OldPath
        }
        return $change
    }

    function New-TestOwnerFile {
        param(
            [Parameter(Mandatory)][string]$Path,
            [AllowNull()][object]$Content,
            [string]$State = 'complete',
            [bool]$Truncated = $false,
            [AllowNull()][object]$SourceDigest = $null,
            [AllowNull()][object]$ByteLength = $null,
            [AllowNull()][string]$UnavailableReason = $null
        )

        $length = if ($null -ne $ByteLength) {
            $ByteLength
        }
        elseif ($null -eq $Content) {
            0
        }
        else {
            [Text.Encoding]::UTF8.GetByteCount([string]$Content)
        }
        $digest = if ($null -ne $SourceDigest) {
            $SourceDigest
        }
        elseif ($null -eq $Content) {
            Get-TestOwnerDigest "unavailable:$Path"
        }
        else {
            Get-TestOwnerDigest ([string]$Content)
        }
        $file = [ordered]@{
            schemaVersion = 1
            repositoryId = 'repository-example'
            projectId = 'project-example'
            pullRequestId = 42
            sourceCommit = ('a' * 40)
            targetCommit = ('b' * 40)
            targetRef = 'refs/heads/main'
            path = $Path
            state = $State
            byteLength = $length
            truncated = $Truncated
            content = if ($null -eq $Content) { $null } else { [string]$Content }
            sourceDigest = [string]$digest
        }
        if (-not [string]::IsNullOrEmpty($UnavailableReason)) {
            $file['unavailableReason'] = $UnavailableReason
        }
        return $file
    }

    function New-TestOwnerPackage {
        param(
            [object[]]$Changes,
            [object[]]$Files,
            [object[]]$Pages,
            [string]$RuleState = 'complete',
            [AllowNull()][string]$RuleContent = 'require review',
            [string]$SubjectAfterDigest = (Get-TestOwnerDigest 'subject')
        )

        if ($null -eq $Changes) {
            $Changes = @(
                New-TestOwnerChange -Path 'src/zeta.ps1'
                New-TestOwnerChange -Path 'src/alpha.ps1' -ChangeType added
            )
        }
        if ($null -eq $Files) {
            $Files = @(
                New-TestOwnerFile -Path 'src/zeta.ps1' -Content "Write-Output 'zeta'"
                New-TestOwnerFile -Path 'src/alpha.ps1' -Content "Write-Output 'alpha'"
            )
        }
        if ($null -eq $Pages) {
            $Pages = @(
                [ordered]@{
                    schemaVersion = 1
                    repositoryId = 'repository-example'
                    projectId = 'project-example'
                    pullRequestId = 42
                    sourceCommit = ('a' * 40)
                    targetCommit = ('b' * 40)
                    targetRef = 'refs/heads/main'
                    pageOrdinal = 0
                    continuationToken = $null
                    nextToken = $null
                    state = 'complete'
                    sourceDigest = Get-TestOwnerDigest 'page:0'
                    changes = $Changes
                }
            )
        }

        $subject = [ordered]@{
            schemaVersion = 1
            repositoryId = 'repository-example'
            projectId = 'project-example'
            pullRequestId = 42
            sourceCommit = ('a' * 40)
            targetCommit = ('b' * 40)
            targetRef = 'refs/heads/main'
            changedFileCount = $Changes.Count
            state = 'complete'
            sourceDigest = Get-TestOwnerDigest 'subject'
        }
        $subjectAfter = Copy-TestOwnerValue $subject
        $subjectAfter['sourceDigest'] = $SubjectAfterDigest
        return [ordered]@{
            schemaVersion = 1
            semantics = 'owner-acquisition-v1'
            contractDigest = 'v1:sha256:7a6f3a79b5b87e38c8ca92a19886fff1f814336e331da8136c860f4f101d85b5'
            subjectBefore = $subject
            changePages = $Pages
            rule = [ordered]@{
                schemaVersion = 1
                repositoryId = 'repository-example'
                projectId = 'project-example'
                pullRequestId = 42
                sourceCommit = ('a' * 40)
                targetCommit = ('b' * 40)
                targetRef = 'refs/heads/main'
                ruleRepositoryId = 'rules-example'
                rulePath = '.config/owner-rules.md'
                ruleCommit = ('c' * 40)
                ruleSection = 'review-policy'
                ruleHash = Get-TestOwnerDigest 'require review'
                ruleLength = [Text.Encoding]::UTF8.GetByteCount('require review')
                state = $RuleState
                content = $RuleContent
                sourceDigest = Get-TestOwnerDigest 'rule-artifact'
            }
            files = $Files
            subjectAfter = $subjectAfter
        }
    }

    function New-TestOwnerProvider {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Package,
            [string]$ThrowOperation = ''
        )

        $state = @{
            SubjectReads = 0
            Operations = [Collections.Generic.List[string]]::new()
            WriteCount = 0
        }
        $capturedPackage = $Package
        $capturedThrowOperation = $ThrowOperation
        $provider = New-OwnerReadOnlyProviderAdapter -Name 'fixture-provider' -Handler {
            param($operation, $arguments)
            [void]$state.Operations.Add($operation)
            if ($operation -ceq $capturedThrowOperation) {
                throw 'sensitive provider fixture detail'
            }
            switch ($operation) {
                'GetSubject' {
                    $result = if ($state.SubjectReads -eq 0) {
                        $capturedPackage.subjectBefore
                    }
                    else {
                        $capturedPackage.subjectAfter
                    }
                    $state.SubjectReads++
                    return $result
                }
                'GetChangedFilesPage' {
                    return $capturedPackage.changePages[[int]$arguments.pageOrdinal]
                }
                'GetRule' {
                    return $capturedPackage.rule
                }
                'GetFile' {
                    return @(
                        $capturedPackage.files |
                            Where-Object { [string]$_.path -ceq [string]$arguments.path }
                    )[0]
                }
                default {
                    $state.WriteCount++
                    throw 'unexpected operation'
                }
            }
        }.GetNewClosure()
        return [pscustomobject]@{
            Adapter = $provider
            State = $state
        }
    }

    function New-TestOwnerCapabilityAdapter {
        return New-OwnerPipelineAdapter -Stage capability -Name 'fixture-capability' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @(
                    @{
                        assessmentId = 'all-evidence'
                        evidenceUnitIds = @($context.evidence.evidenceUnits.unitId)
                        state = 'complete'
                        findings = @()
                    }
                )
            }
        }
    }

    function Invoke-TestOwnerReplay {
        param(
            [Parameter(Mandatory)][object]$Contract,
            [Parameter(Mandatory)][Collections.IDictionary]$Package
        )

        $fixture = New-OwnerReplayFixture -Package $Package
        return Invoke-OwnerReviewPipeline `
            -Binding $Contract.Binding `
            -AcquisitionAdapter (New-OwnerReplayAcquisitionAdapter `
                -Contract $Contract `
                -Fixture $fixture `
                -ExpectedPayloadDigest $fixture.PayloadDigest) `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)
    }
}

Describe 'Owner acquisition contracts' {
    It 'creates immutable identities that bind every production input partition' {
        $contract = New-TestOwnerContract
        { $contract.Request.SourceCommit = ('d' * 40) } | Should -Throw
        { $contract.Limits.MaximumFiles = 1 } | Should -Throw
        { $contract.Binding.HeadKey = 'changed' } | Should -Throw

        $changedTarget = New-TestOwnerContract -TargetCommit ('d' * 40)
        $changedLimits = New-TestOwnerContract -Limits (
            New-OwnerAdapterLimits -MaximumBytes 100000 -MaximumReads 100
        )
        $changedRule = New-OwnerAcquisitionContract `
            -RepositoryId 'repository-example' `
            -ProjectId 'project-example' `
            -PullRequestId 42 `
            -SourceCommit ('a' * 40) `
            -TargetCommit ('b' * 40) `
            -TargetRef 'refs/heads/main' `
            -RuleRepositoryId 'rules-example' `
            -RulePath '.config/owner-rules.md' `
            -RuleCommit ('c' * 40) `
            -RuleSection 'different-section' `
            -RuleHash (Get-TestOwnerDigest 'require review') `
            -RuleLength 14 `
            -ConfigId 'config-example' `
            -ConfigDigest (Get-TestOwnerDigest 'config') `
            -CapabilityId 'capability-example' `
            -CapabilityDigest (Get-TestOwnerDigest 'capability')

        $contract.Binding.BindingId | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        $changedTarget.Binding.BindingId | Should -Not -Be $contract.Binding.BindingId
        $changedRule.Binding.BindingId | Should -Not -Be $contract.Binding.BindingId
        $changedLimits.Binding.BindingId | Should -Not -Be $contract.Binding.BindingId
        $contract.Binding.AuthorizationKey | Should -Be 'authority:preview-only'
    }

    It 'rejects malformed commits, digests, refs, and unsafe rule paths' {
        { New-TestOwnerContract -SourceCommit 'HEAD' } | Should -Throw
        { New-TestOwnerContract -TargetRef 'main' } | Should -Throw
        { New-OwnerAdapterLimits -MaximumFiles 255 } | Should -Throw
        {
            New-TestOwnerContract -Limits (
                [DevPilot.OwnerAdapters.OwnerAdapterLimits]::new(255, 1000, 20, 4)
            )
        } | Should -Throw
        {
            New-TestOwnerContract -Limits (
                New-OwnerAdapterLimits -MaximumBytes 10
            )
        } | Should -Throw
        {
            New-OwnerAcquisitionContract `
                -RepositoryId repository -ProjectId project -PullRequestId 1 `
                -SourceCommit ('a' * 40) -TargetCommit ('b' * 40) -TargetRef refs/heads/main `
                -RuleRepositoryId rules -RulePath '../rules.md' -RuleCommit ('c' * 40) `
                -RuleSection section -RuleHash 'not-a-digest' -RuleLength 1 `
                -ConfigId config -ConfigDigest (Get-TestOwnerDigest config) `
                -CapabilityId capability -CapabilityDigest (Get-TestOwnerDigest capability)
        } | Should -Throw
    }

    It 'rejects forged contract tags whose request or limits do not match the binding' {
        $real = New-TestOwnerContract
        $request = $real.Request
        $forgedRequest = [DevPilot.OwnerAdapters.OwnerAcquisitionRequest]::new(
            'other-repository',
            $request.ProjectId,
            99,
            $request.SourceCommit,
            $request.TargetCommit,
            $request.TargetRef,
            $request.RuleRepositoryId,
            $request.RulePath,
            $request.RuleCommit,
            $request.RuleSection,
            $request.RuleHash,
            $request.RuleLength,
            $request.ConfigId,
            $request.ConfigDigest,
            $request.CapabilityId,
            $request.CapabilityDigest)
        $forged = [pscustomobject][ordered]@{
            SchemaVersion = 1
            Request = $forgedRequest
            Limits = [DevPilot.OwnerAdapters.OwnerAdapterLimits]::new(255, 1000, 20, 4)
            Binding = $real.Binding
        }
        $forged.PSTypeNames.Insert(0, 'DevPilot.OwnerAdapters.AcquisitionContract')
        $provider = New-TestOwnerProvider -Package (New-TestOwnerPackage)

        {
            New-OwnerProductionAcquisitionAdapter -Contract $forged -Provider $provider.Adapter
        } | Should -Throw
    }
}

Describe 'Owner production and replay acquisition' {
    It 'produces the exact same facade envelope, digest, stage order, and zero-write preview' {
        $contract = New-TestOwnerContract
        $package = New-TestOwnerPackage
        $provider = New-TestOwnerProvider -Package $package
        $liveAdapter = New-OwnerProductionAcquisitionAdapter `
            -Contract $contract -Provider $provider.Adapter
        $live = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter $liveAdapter `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)
        $replay = Invoke-TestOwnerReplay -Contract $contract -Package $package

        ($live.snapshot | ConvertTo-Json -Depth 32 -Compress) |
            Should -Be ($replay.snapshot | ConvertTo-Json -Depth 32 -Compress)
        ($live.evidence | ConvertTo-Json -Depth 32 -Compress) |
            Should -Be ($replay.evidence | ConvertTo-Json -Depth 32 -Compress)
        $live.evidence.evidenceDigest | Should -Be $replay.evidence.evidenceDigest
        @($live.evidence.evidenceUnits.unitId) | Should -Be @(
            'file:000000', 'file:000001', 'identity', 'rule'
        )
        @($live.stages.name) -join ' -> ' | Should -Be (
            'Acquire snapshot -> Build evidence -> Run capability -> ' +
            'Validate findings -> Preview -> Authorize delivery')
        $live.preview.writeAllowed | Should -BeFalse
        $live.delivery.writeCount | Should -Be 0
        $provider.State.WriteCount | Should -Be 0
        @($provider.State.Operations) | Should -Not -Contain 'write'

        $identity = $live.evidence.evidenceUnits | Where-Object unitId -CEQ identity
        $identity.data.repositoryId | Should -Be 'repository-example'
        $identity.data.projectId | Should -Be 'project-example'
        $identity.data.pullRequestId | Should -Be 42
        $identity.data.sourceCommit | Should -Be ('a' * 40)
        $identity.data.targetCommit | Should -Be ('b' * 40)
        $identity.data.targetRef | Should -Be 'refs/heads/main'
        $identity.data.configId | Should -Be 'config-example'
        $identity.data.capabilityId | Should -Be 'capability-example'
        $identity.data.sourceArtifactDigests.Count | Should -Be 7
    }

    It 'canonicalizes ordinal paths and preserves deterministic evidence digests' {
        $contract = New-TestOwnerContract
        $forward = New-TestOwnerPackage
        $reverse = Copy-TestOwnerValue $forward
        [array]::Reverse($reverse.changePages[0].changes)
        [array]::Reverse($reverse.files)

        $forwardResult = Invoke-TestOwnerReplay -Contract $contract -Package $forward
        $reverseResult = Invoke-TestOwnerReplay -Contract $contract -Package $reverse

        @($reverseResult.evidence.evidenceUnits |
                Where-Object { $_.unitId -like 'file:*' } |
                ForEach-Object { $_.data.path }) |
            Should -Be @('src/alpha.ps1', 'src/zeta.ps1')
        $forwardResult.evidence.evidenceDigest | Should -Be $reverseResult.evidence.evidenceDigest
    }

    It 'rejects stale source head, target identity, and authoritative rule identity' -TestCases @(
        @{
            Case = 'source head'
            Mutate = {
                param($package)
                $package.subjectAfter.sourceCommit = ('d' * 40)
            }
        }
        @{
            Case = 'target commit'
            Mutate = {
                param($package)
                $package.changePages[0].targetCommit = ('d' * 40)
            }
        }
        @{
            Case = 'target ref'
            Mutate = {
                param($package)
                $package.files[0].targetRef = 'refs/heads/other'
            }
        }
        @{
            Case = 'rule commit'
            Mutate = {
                param($package)
                $package.rule.ruleCommit = ('d' * 40)
            }
        }
        @{
            Case = 'rule hash'
            Mutate = {
                param($package)
                $package.rule.ruleHash = Get-TestOwnerDigest 'different'
            }
        }
    ) {
        param($Case, $Mutate)
        $package = New-TestOwnerPackage
        & $Mutate $package

        $result = Invoke-TestOwnerReplay -Contract (New-TestOwnerContract) -Package $package

        $result.state | Should -Be 'failed'
        $result.stages[0].state | Should -Be 'failed'
        @($result.diagnostics.code) | Should -Contain 'adapter-failed'
    }

    It 'keeps incomplete spans, files, and rules unknown without shrinking the denominator' -TestCases @(
        @{
            Case = 'span'
            Mutate = {
                param($package)
                $package.changePages[0].changes[0].spans[0].state = 'incomplete'
            }
        }
        @{
            Case = 'file'
            Mutate = {
                param($package)
                $package.files[0].state = 'incomplete'
                $package.files[0].content = $null
                $package.files[0].byteLength = 20
                $package.files[0].sourceDigest = Get-TestOwnerDigest 'unavailable'
            }
        }
        @{
            Case = 'rule'
            Mutate = {
                param($package)
                $package.rule.state = 'incomplete'
                $package.rule.content = $null
            }
        }
    ) {
        param($Case, $Mutate)
        $package = New-TestOwnerPackage
        & $Mutate $package

        $contract = New-TestOwnerContract
        $fixture = New-OwnerReplayFixture -Package $package
        $adapter = New-OwnerReplayAcquisitionAdapter -Contract $contract `
            -Fixture $fixture -ExpectedPayloadDigest $fixture.PayloadDigest
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter $adapter `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)
        $result.state | Should -Be 'unknown'
        $result.snapshot.state | Should -Be 'unknown'
        $result.evidence.evidenceUnits.Count | Should -Be 4
        @($result.validation.unitCoverage.state) | Should -Contain 'unknown'
        $result.delivery.writeCount | Should -Be 0
    }

    It 'retains deletion, rename, binary, oversize, and truncated evidence explicitly' {
        $changes = @(
            New-TestOwnerChange -Path 'src/deleted.txt' -ChangeType deleted -Spans @()
            New-TestOwnerChange -Path 'src/renamed.txt' -ChangeType renamed `
                -OldPath 'src/old-name.txt' -Spans @()
            New-TestOwnerChange -Path 'assets/image.bin' -IsBinary $true -Spans @()
            New-TestOwnerChange -Path 'src/oversize.txt'
            New-TestOwnerChange -Path 'src/truncated.txt'
        )
        $files = @(
            New-TestOwnerFile -Path 'src/deleted.txt' -Content $null -State complete `
                -SourceDigest $changes[0].sourceDigest
            New-TestOwnerFile -Path 'src/renamed.txt' -Content 'renamed'
            New-TestOwnerFile -Path 'assets/image.bin' -Content $null -State unknown `
                -SourceDigest $changes[2].sourceDigest
            New-TestOwnerFile -Path 'src/oversize.txt' -Content $null -State unknown `
                -SourceDigest (Get-TestOwnerDigest oversize) -ByteLength 9000000 `
                -UnavailableReason oversize
            New-TestOwnerFile -Path 'src/truncated.txt' -Content 'part' -State incomplete `
                -Truncated $true -ByteLength 100 -SourceDigest (Get-TestOwnerDigest 'full-artifact')
        )
        $contract = New-TestOwnerContract
        $fixture = New-OwnerReplayFixture -Package (
            New-TestOwnerPackage -Changes $changes -Files $files
        )
        $adapter = New-OwnerReplayAcquisitionAdapter -Contract $contract -Fixture $fixture `
            -ExpectedPayloadDigest $fixture.PayloadDigest
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter $adapter `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)
        $result.state | Should -Be 'unknown'
        $fileUnits = @($result.evidence.evidenceUnits | Where-Object unitId -Like 'file:*')
        $fileUnits.Count | Should -Be 5
        ($fileUnits | Where-Object { $_.data.changeType -eq 'deleted' }).state | Should -Be 'complete'
        $renameUnit = $fileUnits | Where-Object { $_.data.changeType -eq 'renamed' }
        $renameUnit.data.oldPath |
            Should -Be 'src/old-name.txt'
        $renameUnit.state | Should -Be 'unknown'
        $renameUnit.data.unknownReason | Should -Be 'spans-missing'
        ($fileUnits | Where-Object { $_.data.isBinary }).state | Should -Be 'unknown'
        ($fileUnits | Where-Object { $_.data.isBinary }).data.unknownReason | Should -Be 'binary'
        ($fileUnits | Where-Object { $_.data.path -eq 'src/oversize.txt' }).data.byteLength |
            Should -Be 9000000
        ($fileUnits | Where-Object { $_.data.path -eq 'src/oversize.txt' }).data.unknownReason |
            Should -Be 'oversize'
        ($fileUnits | Where-Object { $_.data.truncated }).state | Should -Be 'unknown'
        ($fileUnits | Where-Object { $_.data.truncated }).data.unknownReason |
            Should -Be 'truncated'
    }

    It 'handles bounded pagination and rejects races or broken continuation chains' {
        $changes = @(
            New-TestOwnerChange -Path 'src/alpha.ps1' -ChangeType added
            New-TestOwnerChange -Path 'src/zeta.ps1'
        )
        $pages = @(
            [ordered]@{
                schemaVersion = 1; repositoryId = 'repository-example'; projectId = 'project-example'
                pullRequestId = 42; sourceCommit = ('a' * 40); targetCommit = ('b' * 40)
                targetRef = 'refs/heads/main'; pageOrdinal = 0; continuationToken = $null
                nextToken = 'page-2'; state = 'complete'; sourceDigest = Get-TestOwnerDigest 'page:0'
                changes = @($changes[0])
            }
            [ordered]@{
                schemaVersion = 1; repositoryId = 'repository-example'; projectId = 'project-example'
                pullRequestId = 42; sourceCommit = ('a' * 40); targetCommit = ('b' * 40)
                targetRef = 'refs/heads/main'; pageOrdinal = 1; continuationToken = 'page-2'
                nextToken = $null; state = 'complete'; sourceDigest = Get-TestOwnerDigest 'page:1'
                changes = @($changes[1])
            }
        )
        $package = New-TestOwnerPackage -Changes $changes -Pages $pages
        $provider = New-TestOwnerProvider -Package $package
        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerContract).Binding `
            -AcquisitionAdapter (New-OwnerProductionAcquisitionAdapter `
                -Contract (New-TestOwnerContract) -Provider $provider.Adapter) `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)

        $result.state | Should -Be 'complete'
        @($provider.State.Operations | Where-Object { $_ -eq 'GetChangedFilesPage' }).Count | Should -Be 2

        $raced = New-TestOwnerPackage -SubjectAfterDigest (Get-TestOwnerDigest 'changed-subject')
        (Invoke-TestOwnerReplay -Contract (New-TestOwnerContract) -Package $raced).state |
            Should -Be 'failed'

        $broken = Copy-TestOwnerValue $package
        $broken.changePages[1].continuationToken = 'wrong-token'
        (Invoke-TestOwnerReplay -Contract (New-TestOwnerContract) -Package $broken).state |
            Should -Be 'failed'
    }

    It 'rejects duplicate, unsafe, malformed, mixed, and out-of-denominator paths' -TestCases @(
        @{
            Case = 'case duplicate'
            Mutate = {
                param($package)
                $package.changePages[0].changes[1].path = 'SRC/ZETA.PS1'
                $package.files[1].path = 'SRC/ZETA.PS1'
            }
        }
        @{
            Case = 'unsafe path'
            Mutate = {
                param($package)
                $package.changePages[0].changes[0].path = '../secret.txt'
                $package.files[0].path = '../secret.txt'
            }
        }
        @{
            Case = 'malformed boolean'
            Mutate = {
                param($package)
                $package.changePages[0].changes[0].isBinary = 'false'
            }
        }
        @{
            Case = 'mixed file head'
            Mutate = {
                param($package)
                $package.files[0].sourceCommit = ('d' * 40)
            }
        }
        @{
            Case = 'extra file'
            Mutate = {
                param($package)
                $package.files += New-TestOwnerFile -Path 'src/extra.ps1' -Content extra
            }
        }
        @{
            Case = 'misleading deleted reason'
            Mutate = {
                param($package)
                $package.files[0].state = 'unknown'
                $package.files[0].content = $null
                $package.files[0].byteLength = 20
                $package.files[0].sourceDigest = Get-TestOwnerDigest unavailable
                $package.files[0].unavailableReason = 'deleted'
            }
        }
    ) {
        param($Case, $Mutate)
        $package = New-TestOwnerPackage
        & $Mutate $package

        (Invoke-TestOwnerReplay -Contract (New-TestOwnerContract) -Package $package).state |
            Should -Be 'failed'
    }

    It 'fails closed when the file cap is exceeded' {
        $contract = New-TestOwnerContract -Limits (New-OwnerAdapterLimits -MaximumFiles 1)
        $result = Invoke-TestOwnerReplay -Contract $contract -Package (New-TestOwnerPackage)

        $result.state | Should -Be 'failed'
        $result.evidence | Should -BeNullOrEmpty
    }

    It 'preserves unknown units when byte and read caps stop further file acquisition' -TestCases @(
        @{
            Case = 'bytes'
            Limits = {
                $firstBytes = [Text.Encoding]::UTF8.GetByteCount("Write-Output 'zeta'")
                $ruleBytes = [Text.Encoding]::UTF8.GetByteCount('require review')
                New-OwnerAdapterLimits -MaximumBytes ($ruleBytes + $firstBytes) `
                    -MaximumReads 20 -MaximumDiagnostics 1
            }
        }
        @{
            Case = 'reads'
            Limits = {
                New-OwnerAdapterLimits -MaximumBytes 1000 -MaximumReads 5 -MaximumDiagnostics 1
            }
        }
    ) {
        param($Case, $Limits)
        $contract = New-TestOwnerContract -Limits (& $Limits)
        $provider = New-TestOwnerProvider -Package (New-TestOwnerPackage)
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter (New-OwnerProductionAcquisitionAdapter `
                -Contract $contract -Provider $provider.Adapter) `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)

        $result.state | Should -Be 'unknown'
        @($result.evidence.evidenceUnits | Where-Object state -EQ unknown).Count | Should -Be 1
        $result.diagnostics.Count | Should -Be 1
        @($provider.State.Operations | Where-Object { $_ -eq 'GetFile' }).Count | Should -Be 1
        $provider.State.SubjectReads | Should -Be 2
        $provider.State.WriteCount | Should -Be 0
    }

    It 'degrades provider content that exceeds its byte hint instead of losing the denominator' {
        $ruleBytes = [Text.Encoding]::UTF8.GetByteCount('require review')
        $contract = New-TestOwnerContract -Limits (
            New-OwnerAdapterLimits -MaximumBytes ($ruleBytes + 5) -MaximumReads 20
        )
        $provider = New-TestOwnerProvider -Package (New-TestOwnerPackage)
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter (New-OwnerProductionAcquisitionAdapter `
                -Contract $contract -Provider $provider.Adapter) `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)

        $result.state | Should -Be 'unknown'
        $fileUnits = @($result.evidence.evidenceUnits | Where-Object unitId -Like 'file:*')
        $fileUnits.Count | Should -Be 2
        @($fileUnits.data.unknownReason | Select-Object -Unique) | Should -Be @('oversize')
        @($provider.State.Operations | Where-Object { $_ -eq 'GetFile' }).Count | Should -Be 2
        $provider.State.SubjectReads | Should -Be 2
    }

    It 'degrades an oversize authoritative rule read to explicit unknown evidence' {
        $ruleBytes = [Text.Encoding]::UTF8.GetByteCount('require review')
        $contract = New-TestOwnerContract -Limits (
            New-OwnerAdapterLimits -MaximumBytes $ruleBytes -MaximumReads 20
        )
        $package = New-TestOwnerPackage
        $package.rule.content = 'provider ignored the rule byte hint'
        $provider = New-TestOwnerProvider -Package $package
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter (New-OwnerProductionAcquisitionAdapter `
                -Contract $contract -Provider $provider.Adapter) `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)

        $result.state | Should -Be 'unknown'
        $ruleUnit = $result.evidence.evidenceUnits | Where-Object unitId -CEQ rule
        $ruleUnit.state | Should -Be 'unknown'
        $ruleUnit.data.unknownReason | Should -Be 'oversize'
        $ruleUnit.data.content | Should -BeNullOrEmpty
        $provider.State.SubjectReads | Should -Be 2
    }

    It 'isolates provider exceptions and never exposes their details' {
        $contract = New-TestOwnerContract
        $provider = New-TestOwnerProvider -Package (New-TestOwnerPackage) -ThrowOperation GetRule
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter (New-OwnerProductionAcquisitionAdapter `
                -Contract $contract -Provider $provider.Adapter) `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)

        $result.state | Should -Be 'failed'
        ($result.diagnostics | ConvertTo-Json -Compress) | Should -Not -Match 'sensitive provider fixture detail'
        $provider.State.WriteCount | Should -Be 0
    }

    It 'rejects mutated provider contracts and replay semantic divergence' {
        $contract = New-TestOwnerContract
        $provider = New-TestOwnerProvider -Package (New-TestOwnerPackage)
        $provider.Adapter.Operations = @('GetSubject', 'write')
        {
            New-OwnerProductionAcquisitionAdapter -Contract $contract -Provider $provider.Adapter
        } | Should -Throw

        $fixture = New-OwnerReplayFixture -Package (New-TestOwnerPackage)
        $divergent = [DevPilot.OwnerAdapters.OwnerReplayFixture]::new(
            'benchmark-projection-v1',
            $fixture.PayloadJson,
            $fixture.PayloadDigest,
            $fixture.SealDigest)
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter (New-OwnerReplayAcquisitionAdapter `
                -Contract $contract -Fixture $divergent `
                -ExpectedPayloadDigest $fixture.PayloadDigest) `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)
        $result.state | Should -Be 'failed'

        $substitute = New-OwnerReplayFixture -Package (
            New-TestOwnerPackage -SubjectAfterDigest (Get-TestOwnerDigest 'different-subject')
        )
        {
            New-OwnerReplayAcquisitionAdapter -Contract $contract -Fixture $substitute `
                -ExpectedPayloadDigest $fixture.PayloadDigest
        } | Should -Throw
    }

    It 're-applies fixture bounds even when a caller bypasses the fixture factory' {
        $package = New-TestOwnerPackage
        $package.changePages[0].changes[0].spans = @(
            1..1025 | ForEach-Object {
                [ordered]@{
                    startLine = $_
                    endLine = $_
                    state = 'complete'
                    sourceDigest = Get-TestOwnerDigest "span:$_"
                }
            }
        )
        $payloadJson = ConvertTo-Json -InputObject $package -Depth 32 -Compress
        $payloadDigest = Get-TestOwnerDigest $payloadJson
        $contractDigest = 'v1:sha256:7a6f3a79b5b87e38c8ca92a19886fff1f814336e331da8136c860f4f101d85b5'
        $sealJson = (
            '{"contractDigest":"' + $contractDigest +
            '","payloadDigest":"' + $payloadDigest +
            '","semantics":"owner-acquisition-v1"}'
        )
        $fixture = [DevPilot.OwnerAdapters.OwnerReplayFixture]::new(
            'owner-acquisition-v1',
            $payloadJson,
            $payloadDigest,
            (Get-TestOwnerDigest $sealJson))
        $contract = New-TestOwnerContract
        $result = Invoke-OwnerReviewPipeline `
            -Binding $contract.Binding `
            -AcquisitionAdapter (New-OwnerReplayAcquisitionAdapter `
                -Contract $contract -Fixture $fixture `
                -ExpectedPayloadDigest $payloadDigest) `
            -CapabilityAdapter (New-TestOwnerCapabilityAdapter)

        $result.state | Should -Be 'failed'
        @($result.diagnostics.code) | Should -Contain 'adapter-failed'
    }
}

Describe 'Owner adapter module surface' {
    It 'exports only the layer-two contract and acquisition adapters' {
        @(Get-Command -Module DevPilot.OwnerAdapters).Name | Sort-Object | Should -Be @(
            'New-OwnerAcquisitionContract',
            'New-OwnerAdapterLimits',
            'New-OwnerProductionAcquisitionAdapter',
            'New-OwnerReadOnlyProviderAdapter',
            'New-OwnerReplayAcquisitionAdapter',
            'New-OwnerReplayFixture'
        )
        Test-ModuleManifest "$PSScriptRoot\..\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" |
            Should -Not -BeNullOrEmpty
    }
}
