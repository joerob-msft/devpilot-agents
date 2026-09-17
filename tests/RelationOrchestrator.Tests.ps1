BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1" -Force

    $script:Case = @(
        (Get-Content "$PSScriptRoot\fixtures\relation-evidence\generic-cases.json" -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32).cases |
            Where-Object id -CEQ 'cold-read'
    )[0]
    $script:RuleText =
        'Public responses requiring sensitive-field sanitization must apply it for every cache state.'
    $script:Child = (Resolve-Path "$PSScriptRoot\fixtures\OwnerModelChild.ps1").Path
    $script:Wrapper = (Resolve-Path "$PSScriptRoot\..\tools\Invoke-RelationV2Preview.ps1").Path
    $script:OrchestratorModule = Get-Module DevPilot.OwnerOrchestrator

    function Get-TestDigest {
        param([Parameter(Mandatory)][object]$Value)
        return & $script:OrchestratorModule {
            param($InputValue)
            Get-OwnerV2Digest -Value $InputValue
        } $Value
    }

    function Get-TestRawDigest {
        param([Parameter(Mandatory)][string]$Value)
        return 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))
        ).ToLowerInvariant()
    }

    function Write-TestJson {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
        [IO.File]::WriteAllText(
            $Path,
            (ConvertTo-Json -InputObject $Value -Depth 64) + "`n",
            [Text.UTF8Encoding]::new($false))
        return $Path
    }

    function New-TestRelationContext {
        param(
            [string]$Name = 'relation',
            [string]$MissingRole = '',
            [switch]$Oversize,
            [string]$SourceCommit = ('a' * 40),
            [string]$ConfigId = 'relation-routing-v1',
            [long]$PullRequestId = 43,
            [string]$EmptySpanRole = '',
            [string]$ModelMode = 'valid',
            [string]$ModelStatePath = '-'
        )
        $evidence = @(
            foreach ($item in @($script:Case.evidence)) {
                $roles = @($item.roles | ForEach-Object { [string]$_ })
                [ordered]@{
                    id = [string]$item.id
                    path = [string]$item.path
                    type = [string]$item.type
                    startLine = [int]$item.startLine
                    endLine = [int]$item.endLine
                    content = $(if ($Oversize -and $roles -ccontains 'projection') {
                            'x' * 10001
                        }
                        else {
                            [string]$item.content
                        })
                    roles = $roles
                }
            }
        )
        $selectors = @(
            foreach ($item in @($script:Case.evidence)) {
                foreach ($role in @($item.roles)) {
                    [ordered]@{
                        role = [string]$role
                        required = [string]$role -cne 'test-expectation'
                        trigger = [string]$role -ceq 'public-path'
                        evidenceType = [string]$item.type
                        patterns = @(
                            [ordered]@{ kind = 'exact'; value = [string]$item.path }
                        )
                    }
                }
            }
        ) | Sort-Object { [string]$_.role }
        if ($MissingRole) {
            @($selectors | Where-Object role -CEQ $MissingRole)[0].patterns[0].value =
                "missing/$MissingRole.txt"
        }
        $configBody = [ordered]@{
            id = $ConfigId
            claimId = 'cache-independent-response-sanitization'
            question = [string]$script:Case.question
            severity = 'high'
            policy = 'preview-only'
            anchorRole = 'sanitizer'
            selectors = @($selectors)
        }
        $config = [ordered]@{} + $configBody
        $config['digest'] = Get-TestDigest $configBody
        $manifest = [ordered]@{
            schemaVersion = 1
            kind = 'relation-v2-preview-cohort'
            entries = @(
                [ordered]@{
                    id = 'generic-relation-live'
                    subject = [ordered]@{
                        repositoryId = 'repository-example'
                        projectId = 'project-example'
                        pullRequestId = $PullRequestId
                    }
                    head = [ordered]@{ sourceCommit = $SourceCommit }
                    target = [ordered]@{
                        targetCommit = 'b' * 40
                        targetRef = 'refs/heads/main'
                    }
                    rule = [ordered]@{
                        id = 'public-response-sanitization-v1'
                        repositoryId = 'rules-example'
                        path = 'rules/public-response-sanitization.md'
                        commit = 'c' * 40
                        section = 'cache-independent-sanitization'
                        hash = Get-TestRawDigest $script:RuleText
                        length = [Text.Encoding]::UTF8.GetByteCount($script:RuleText)
                    }
                    capability = [ordered]@{
                        id = 'relation-contextual-review-v1'
                        digest = Get-TestDigest 'relation-contextual-review-v1'
                    }
                    model = [ordered]@{
                        id = 'deterministic-fake-process'
                        digest = Get-TestDigest 'deterministic-fake-process'
                    }
                    config = $config
                }
            )
        }
        $base = [ordered]@{
            schemaVersion = 1
            repositoryId = 'repository-example'
            projectId = 'project-example'
            pullRequestId = $PullRequestId
            sourceCommit = $SourceCommit
            targetCommit = 'b' * 40
            targetRef = 'refs/heads/main'
        }
        $filesByPath = @(
            foreach ($group in @($evidence | Group-Object { [string]$_.path })) {
                $items = @($group.Group)
                $content = @($items | ForEach-Object content) -join "`n"
                [ordered]@{
                    path = [string]$group.Name
                    content = $content
                    spans = @(
                        foreach ($item in $items) {
                            if ($EmptySpanRole -and
                                @($item.roles) -ccontains $EmptySpanRole) {
                                continue
                            }
                            [ordered]@{
                                startLine = [int]$item.startLine
                                endLine = [int]$item.endLine
                                state = 'complete'
                                sourceDigest = Get-TestDigest ([ordered]@{
                                        startLine = [int]$item.startLine
                                        endLine = [int]$item.endLine
                                    })
                            }
                        }
                    )
                }
            }
        )
        $changes = @(
            foreach ($item in $filesByPath) {
                [ordered]@{
                    path = [string]$item.path
                    changeType = 'modified'
                    isBinary = $false
                    sourceDigest = Get-TestDigest ([ordered]@{
                            path = [string]$item.path
                            content = [string]$item.content
                        })
                    spans = @($item.spans)
                }
            }
        )
        $subject = [ordered]@{} + $base
        $subject['changedFileCount'] = $changes.Count
        $subject['state'] = 'complete'
        $subject['sourceDigest'] = Get-TestDigest ([ordered]@{
                sourceCommit = $SourceCommit
                count = $changes.Count
            })
        $page = [ordered]@{} + $base
        $page['pageOrdinal'] = 0
        $page['continuationToken'] = $null
        $page['nextToken'] = $null
        $page['state'] = 'complete'
        $page['sourceDigest'] = Get-TestDigest $changes
        $page['changes'] = $changes
        $rule = [ordered]@{} + $base
        $rule['ruleRepositoryId'] = 'rules-example'
        $rule['rulePath'] = 'rules/public-response-sanitization.md'
        $rule['ruleCommit'] = 'c' * 40
        $rule['ruleSection'] = 'cache-independent-sanitization'
        $rule['ruleHash'] = Get-TestRawDigest $script:RuleText
        $rule['ruleLength'] = [Text.Encoding]::UTF8.GetByteCount($script:RuleText)
        $rule['state'] = 'complete'
        $rule['content'] = $script:RuleText
        $rule['sourceDigest'] = Get-TestRawDigest $script:RuleText
        $rule['unavailableReason'] = $null
        $files = @(
            foreach ($item in $filesByPath) {
                $file = [ordered]@{} + $base
                $file['path'] = [string]$item.path
                $file['state'] = 'complete'
                $file['byteLength'] = [Text.Encoding]::UTF8.GetByteCount([string]$item.content)
                $file['truncated'] = $false
                $file['content'] = [string]$item.content
                $file['sourceDigest'] = Get-TestRawDigest ([string]$item.content)
                $file['unavailableReason'] = $null
                $file
            }
        )
        $package = [ordered]@{
            subjectBefore = $subject
            changePages = @($page)
            rule = $rule
            files = $files
            subjectAfter = ([ordered]@{} + $subject)
        }
        $counts = [ordered]@{ reads = 0; writes = 0; subjects = 0 }
        $captured = $package
        $provider = & $script:OrchestratorModule {
            param($ProviderName, $ProviderCounts, $ProviderPackage)
            New-OwnerReadOnlyProviderAdapter -Name $ProviderName -Handler {
                param($Operation, $Arguments)
                $ProviderCounts.reads++
                switch ($Operation) {
                    'GetSubject' {
                        $value = if ($ProviderCounts.subjects++ % 2 -eq 0) {
                            $ProviderPackage.subjectBefore
                        }
                        else {
                            $ProviderPackage.subjectAfter
                        }
                        return $value
                    }
                    'GetChangedFilesPage' {
                        return $ProviderPackage.changePages[[int]$Arguments.pageOrdinal]
                    }
                    'GetRule' { return $ProviderPackage.rule }
                    'GetFile' {
                        return @($ProviderPackage.files |
                            Where-Object path -CEQ $Arguments.path)[0]
                    }
                }
            }.GetNewClosure()
        } "$Name-provider" $counts $captured
        $model = & $script:OrchestratorModule {
            param($Pwsh, $Child, $Mode, $StatePath)
            New-OwnerModelFakeProvider -FilePath $Pwsh `
                -ArgumentList @('-NoProfile', '-File', $Child, $Mode, $StatePath)
        } (Get-Command pwsh).Source $script:Child $ModelMode $ModelStatePath
        $manifestPath = Write-TestJson -Path (Join-Path $TestDrive "$Name.json") -Value $manifest
        return [pscustomobject]@{
            Manifest = $manifest
            ManifestPath = $manifestPath
            Provider = $provider
            Model = $model
            Counts = $counts
            Package = $package
        }
    }

    function New-TestRelationPreflight {
        param([Parameter(Mandatory)][bool]$Available, [Parameter(Mandatory)][string]$Reason)
        return [pscustomobject][ordered]@{
            available = $Available
            reason = $Reason
            modelIdentity = 'deterministic-fake-process'
            promptTransport = 'private-file'
            localProcessMetadataExposure = $false
            risk = 'none'
            effectiveTools = @()
        }
    }

    function Get-TestRelationObservation {
        param([Parameter(Mandatory)][string]$StateRoot)
        $file = Get-ChildItem -LiteralPath $StateRoot -Recurse -Filter '*.json' |
            Where-Object FullName -Match '[\\/]observations[\\/]' |
            Select-Object -First 1
        return Get-Content -LiteralPath $file.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
    }
}

Describe 'Scheduler-callable relation preview' {
    It 'validates bounded external routing and binds changed identities' {
        $context = New-TestRelationContext -Name manifest
        $root = Join-Path $TestDrive 'manifest-state'
        $first = Invoke-OwnerV2PreviewPrepare -StateRoot $root `
            -ManifestPath $context.ManifestPath
        $changedHead = New-TestRelationContext -Name changed-head -SourceCommit ('d' * 40)
        $headResult = Invoke-OwnerV2PreviewPrepare `
            -StateRoot (Join-Path $TestDrive 'changed-head-state') `
            -ManifestPath $changedHead.ManifestPath
        $changedConfig = New-TestRelationContext -Name changed-config `
            -ConfigId 'relation-routing-v2'
        $configResult = Invoke-OwnerV2PreviewPrepare `
            -StateRoot (Join-Path $TestDrive 'changed-config-state') `
            -ManifestPath $changedConfig.ManifestPath
        $changedRule = New-TestRelationContext -Name changed-rule
        $changedRule.Manifest.entries[0].rule.id = 'public-response-sanitization-v2'
        Write-TestJson -Path $changedRule.ManifestPath -Value $changedRule.Manifest | Out-Null
        $ruleResult = Invoke-OwnerV2PreviewPrepare `
            -StateRoot (Join-Path $TestDrive 'changed-rule-state') `
            -ManifestPath $changedRule.ManifestPath

        $first.records[0].stateDigest | Should -Not -Be $headResult.records[0].stateDigest
        $first.records[0].stateDigest | Should -Not -Be $configResult.records[0].stateDigest
        $first.records[0].stateDigest | Should -Not -Be $ruleResult.records[0].stateDigest
        $context.Manifest.entries[0].config.selectors.Count | Should -BeLessOrEqual 16
        (& $script:OrchestratorModule {
                Test-RelationV2PathPattern -Path 'src/other/FooUtils.cs' `
                    -Pattern @{ kind = 'suffix'; value = 'Utils.cs' }
            }) | Should -BeFalse
        (& $script:OrchestratorModule {
                Test-RelationV2PathPattern -Path 'src/other/Utils.cs' `
                    -Pattern @{ kind = 'suffix'; value = 'Utils.cs' }
            }) | Should -BeTrue
        {
            $invalidAnchor = New-TestRelationContext -Name invalid-anchor
            @($invalidAnchor.Manifest.entries[0].config.selectors |
                Where-Object role -CEQ 'sanitizer')[0].required = $false
            Write-TestJson -Path $invalidAnchor.ManifestPath `
                -Value $invalidAnchor.Manifest | Out-Null
            Invoke-OwnerV2PreviewPrepare `
                -StateRoot (Join-Path $TestDrive 'invalid-anchor-state') `
                -ManifestPath $invalidAnchor.ManifestPath
        } | Should -Throw '*required anchor role selector*'
        {
            $invalid = New-TestRelationContext -Name invalid
            $invalid.Manifest.entries[0].config.selectors[0].patterns[0].value = '../private.cs'
            Write-TestJson -Path $invalid.ManifestPath -Value $invalid.Manifest | Out-Null
            Invoke-OwnerV2PreviewPrepare -StateRoot (Join-Path $TestDrive 'invalid-state') `
                -ManifestPath $invalid.ManifestPath
        } | Should -Throw '*unsafe exact or glob-suffix pattern*'
        {
            $tooMany = New-TestRelationContext -Name too-many
            $tooMany.Manifest.entries = @(1..11 | ForEach-Object {
                    $copy = $tooMany.Manifest.entries[0] |
                        ConvertTo-Json -Depth 64 | ConvertFrom-Json -AsHashtable -Depth 64
                    $copy.id = "entry-$_"
                    $copy
                })
            Write-TestJson -Path $tooMany.ManifestPath -Value $tooMany.Manifest | Out-Null
            Invoke-OwnerV2PreviewPrepare -StateRoot (Join-Path $TestDrive 'too-many-state') `
                -ManifestPath $tooMany.ManifestPath
        } | Should -Throw '*1 to 10 entries*'
    }

    It 'runs provider to relation request to fake model and persists idempotent zero-write status' {
        $context = New-TestRelationContext -Name positive -MissingRole 'test-expectation'
        $root = Join-Path $TestDrive 'positive-state'
        $run = & $script:Wrapper prepare-run -StateRoot $root `
            -ManifestPath $context.ManifestPath -EnableLiveModel `
            -LiveAcquisitionProvider $context.Provider -LiveModelProvider $context.Model
        $reads = $context.Counts.reads
        $status = & $script:Wrapper status -StateRoot $root -ManifestPath $context.ManifestPath
        $again = & $script:Wrapper prepare-run -StateRoot $root `
            -ManifestPath $context.ManifestPath -EnableLiveModel `
            -LiveAcquisitionProvider $context.Provider -LiveModelProvider $context.Model
        $observation = Get-TestRelationObservation -StateRoot $root
        $telemetryFile = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' |
            Where-Object FullName -Match '[\\/]telemetry[\\/]' |
            Select-Object -First 1
        $telemetry = Get-Content -LiteralPath $telemetryFile.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64

        $run.records[0].state | Should -Be 'completed' -Because (
            $observation | ConvertTo-Json -Depth 16 -Compress)
        $again.records[0].reason | Should -Be 'already-terminal'
        $context.Counts.reads | Should -Be $reads
        $status.records[0].attempts | Should -Be 1
        $observation.counts.violations | Should -Be 1
        $observation.findings[0].data.citedEvidenceRefs.Count | Should -BeGreaterThan 0
        $observation.effects.effectiveTools.Count | Should -Be 0
        $observation.effects.providerWrites | Should -Be 0
        $observation.effects.writeToolInvocations | Should -Be 0
        $observation.effects.deliveryAuthorized | Should -BeFalse
        $observation.execution.cost.status | Should -Be 'unavailable'
        $observation.execution.records.Count | Should -Be 1
        $telemetry.acceptedArgvRisk.explicitlyEnabled | Should -BeTrue
        $telemetry.effectiveTools.Count | Should -Be 0
        $telemetry.providerWrites | Should -Be 0
        $observation.limitations | Should -Contain 'runtime-behavior-unverified'
        @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.request.json').Count |
            Should -Be 1
        @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.acquisition.json').Count |
            Should -Be 1
    }

    It 'retries a relation preflight failure once after repair and then stays terminal' {
        $root = Join-Path $TestDrive 'relation-preflight-repair-state'
        $counterPath = Join-Path $TestDrive 'relation-preflight-model-calls.txt'
        $context = New-TestRelationContext -Name relation-preflight-repair `
            -MissingRole 'test-expectation' -ModelMode count-valid `
            -ModelStatePath $counterPath
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $root `
                -ManifestPath $context.ManifestPath)
        $script:RelationPreflightInvocation = 0
        Mock Test-OwnerModelProviderPreflight -ModuleName DevPilot.OwnerOrchestrator {
            $script:RelationPreflightInvocation++
            if ($script:RelationPreflightInvocation -eq 1) {
                return New-TestRelationPreflight -Available $false `
                    -Reason process-containment-unavailable
            }
            New-TestRelationPreflight -Available $true -Reason fake-offline
        }

        $failed = Invoke-OwnerV2PreviewRun -StateRoot $root `
            -ManifestPath $context.ManifestPath -EnableLiveModel `
            -LiveAcquisitionProvider $context.Provider -LiveModelProvider $context.Model
        $recordFile = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' |
            Where-Object FullName -Match '[\\/]records[\\/]' | Select-Object -First 1
        $failedRecord = Get-Content -LiteralPath $recordFile.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        $repaired = Invoke-OwnerV2PreviewRun -StateRoot $root `
            -ManifestPath $context.ManifestPath -EnableLiveModel `
            -LiveAcquisitionProvider $context.Provider -LiveModelProvider $context.Model
        $third = Invoke-OwnerV2PreviewRun -StateRoot $root `
            -ManifestPath $context.ManifestPath -EnableLiveModel `
            -LiveAcquisitionProvider $context.Provider -LiveModelProvider $context.Model
        $completedRecord = Get-Content -LiteralPath $recordFile.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        $observation = Get-TestRelationObservation -StateRoot $root

        $failed.records[0].reason | Should -Be 'process-containment-unavailable'
        $failedRecord.modelExecutionState | Should -Be 'notAttempted'
        $repaired.records[0].state | Should -Be 'completed'
        $repaired.records[0].attempts | Should -Be 2
        $completedRecord.modelExecutionState | Should -Be 'attempted'
        [int](Get-Content -LiteralPath $counterPath -Raw) | Should -Be 1
        @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.attempt-*.json').Count |
            Should -Be 2
        $observation.effects.effectiveTools.Count | Should -Be 0
        $observation.effects.providerWrites | Should -Be 0
        $observation.effects.writeToolInvocations | Should -Be 0
        $third.records[0].reason | Should -Be 'already-terminal'
        [int](Get-Content -LiteralPath $counterPath -Raw) | Should -Be 1
    }

    It 'routes missing and oversize decisive evidence to unknown without model attempts' {
        foreach ($case in @(
                @{ Name = 'missing'; Context = New-TestRelationContext -Name missing `
                        -MissingRole 'cache-lookup'; Reason = 'relation-outcome-unknown' },
                @{ Name = 'oversize'; Context = New-TestRelationContext -Name oversize `
                        -Oversize; Reason = 'evidence-cap-exhausted' },
                @{ Name = 'empty-anchor'; Context = New-TestRelationContext -Name empty-anchor `
                        -EmptySpanRole 'sanitizer'; Reason = 'relation-outcome-unknown' }
            )) {
            $root = Join-Path $TestDrive "$($case.Name)-state"
            $run = & $script:Wrapper prepare-run -StateRoot $root `
                -ManifestPath $case.Context.ManifestPath -EnableLiveModel `
                -LiveAcquisitionProvider $case.Context.Provider `
                -LiveModelProvider $case.Context.Model
            $observation = Get-TestRelationObservation -StateRoot $root
            $telemetry = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' |
                Where-Object FullName -Match '[\\/]telemetry[\\/]' |
                Select-Object -First 1 |
                ForEach-Object {
                    Get-Content -LiteralPath $_.FullName -Raw |
                        ConvertFrom-Json -AsHashtable -Depth 64
                }

            $run.records[0].state | Should -Be 'unknown'
            $observation.counts.unknown | Should -Be 1
            $observation.validationErrors.Count | Should -Be 0
            $telemetry.attempts | Should -Be 0 -Because (
                $telemetry | ConvertTo-Json -Depth 16 -Compress)
            $telemetry.modelCalls | Should -Be 0
            $telemetry.providerWrites | Should -Be 0
            $case.Context.Counts.writes | Should -Be 0
            (& $script:Wrapper prepare-run -StateRoot $root `
                    -ManifestPath $case.Context.ManifestPath -EnableLiveModel `
                    -LiveAcquisitionProvider $case.Context.Provider `
                    -LiveModelProvider $case.Context.Model).records[0].reason |
                Should -Be 'already-terminal'
        }
    }

    It 'keeps Owner and relation scheduler runs independent under partial failure' {
        $relation = New-TestRelationContext -Name partial -MissingRole 'cache-lookup'
        $ownerFixturePath =
            (Resolve-Path "$PSScriptRoot\fixtures\owner-orchestrator\generic-cohort.json").Path
        $ownerManifestValue = Get-Content -LiteralPath $ownerFixturePath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        $ownerPackage = $ownerManifestValue.entries[0].acquisition.package
        $ownerManifestValue.entries[0].mode = 'live'
        $ownerManifestValue.entries[0].Remove('replay')
        $ownerManifestValue.entries[0].acquisition.Remove('package')
        $ownerManifestValue.entries[0].model.id = 'deterministic-fake-process'
        $ownerManifestValue.entries[0].model.digest = Get-TestDigest 'deterministic-fake-process'
        $ownerManifest = Write-TestJson -Path (Join-Path $TestDrive 'owner-live.json') `
            -Value $ownerManifestValue
        $packages = @{
            '42' = $ownerPackage
            '43' = $relation.Package
        }
        $subjectReads = @{ '42' = 0; '43' = 0 }
        $providerReads = [ordered]@{ count = 0 }
        $sharedProvider = & $script:OrchestratorModule {
            param($ProviderPackages, $SubjectReadCounts, $ReadCount)
            New-OwnerReadOnlyProviderAdapter -Name 'combined-live-provider' -Handler {
                param($Operation, $Arguments)
                $ReadCount.count++
                $id = [string]$Arguments.pullRequestId
                $package = $ProviderPackages[$id]
                switch ($Operation) {
                    'GetSubject' {
                        $value = if ($SubjectReadCounts[$id]++ % 2 -eq 0) {
                            $package.subjectBefore
                        }
                        else {
                            $package.subjectAfter
                        }
                        return $value
                    }
                    'GetChangedFilesPage' {
                        return $package.changePages[[int]$Arguments.pageOrdinal]
                    }
                    'GetRule' { return $package.rule }
                    'GetFile' {
                        return @($package.files |
                            Where-Object path -CEQ $Arguments.path)[0]
                    }
                }
            }.GetNewClosure()
        } $packages $subjectReads $providerReads
        $sharedModel = & $script:OrchestratorModule {
            param($Pwsh, $Child)
            New-OwnerModelFakeProvider -FilePath $Pwsh -ArgumentList @(
                '-NoProfile', '-File', $Child, 'valid', '-')
        } (Get-Command pwsh).Source $script:Child
        $ownerRoot = Join-Path $TestDrive 'combined-owner'
        $relationRoot = Join-Path $TestDrive 'combined-relation'
        $global:LASTEXITCODE = 0
        $owner = & "$PSScriptRoot\..\tools\Invoke-OwnerV2Preview.ps1" prepare-run `
            -StateRoot $ownerRoot -ManifestPath $ownerManifest -EnableLiveModel `
            -LiveAcquisitionProvider $sharedProvider -LiveModelProvider $sharedModel
        $failed = & $script:Wrapper prepare-run -StateRoot $relationRoot `
            -ManifestPath $relation.ManifestPath -EnableLiveModel `
            -LiveAcquisitionProvider $sharedProvider -LiveModelProvider $sharedModel

        $owner.records[0].state | Should -Be 'completed' -Because (
            (Get-TestRelationObservation -StateRoot $ownerRoot) |
                ConvertTo-Json -Depth 16 -Compress)
        $failed.records[0].state | Should -Be 'unknown'
        $failed.records[0].reason | Should -Be 'relation-outcome-unknown'
        $providerReads.count | Should -BeGreaterThan 4
        $LASTEXITCODE | Should -BeIn @(0, $null)
        $ownerRoot | Should -Not -Be $relationRoot
    }
}
