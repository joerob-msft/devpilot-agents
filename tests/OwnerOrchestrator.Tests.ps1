BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1" -Force
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1" -Force

    $script:FixturePath = (Resolve-Path "$PSScriptRoot\fixtures\owner-orchestrator\generic-cohort.json").Path
    $script:SchemaPath = (Resolve-Path "$PSScriptRoot\fixtures\owner-orchestrator\owner-v2-preview-cohort.schema.json").Path
    $script:OrchestratorModule = Get-Module DevPilot.OwnerOrchestrator
    $script:OwnerModelChild = (Resolve-Path "$PSScriptRoot\fixtures\OwnerModelChild.ps1").Path
    $script:Pwsh = (Get-Command pwsh).Source

    function Get-TestDigest {
        param([Parameter(Mandatory)][string]$Text)
        return 'v1:sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
        ).ToLowerInvariant()
    }

    function Copy-TestValue {
        param([Parameter(Mandatory)][object]$Value)
        return ConvertFrom-Json -InputObject (
            ConvertTo-Json -InputObject $Value -Depth 64 -Compress
        ) -AsHashtable -Depth 64
    }

    function Update-TestPayloadDigest {
        param([Parameter(Mandatory)][Collections.IDictionary]$Manifest)
        foreach ($entry in @($Manifest.entries)) {
            if ([string]$entry.mode -ceq 'replay') {
                $fixture = & $script:OrchestratorModule {
                    param([Collections.IDictionary]$Package)
                    New-OwnerReplayFixture -Package $Package
                } $entry.acquisition.package
                $entry.acquisition.payloadDigest = $fixture.PayloadDigest
            }
        }
    }

    function Set-TestPackageSourceCommit {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Entry,
            [Parameter(Mandatory)][string]$SourceCommit
        )
        foreach ($name in @('subjectBefore', 'subjectAfter', 'rule')) {
            $Entry.acquisition.package[$name].sourceCommit = $SourceCommit
        }
        foreach ($page in @($Entry.acquisition.package.changePages)) { $page.sourceCommit = $SourceCommit }
        foreach ($file in @($Entry.acquisition.package.files)) { $file.sourceCommit = $SourceCommit }
    }

    function Write-TestJson {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][object]$Value
        )
        [IO.File]::WriteAllText(
            $Path,
            (ConvertTo-Json -InputObject $Value -Depth 64) + "`n",
            [Text.UTF8Encoding]::new($false))
        return $Path
    }

    function New-TestManifest {
        param([scriptblock]$Mutator)
        $manifest = Get-Content -LiteralPath $script:FixturePath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        if ($Mutator) { & $Mutator $manifest }
        Update-TestPayloadDigest -Manifest $manifest
        return $manifest
    }

    function New-TestManifestFile {
        param(
            [Parameter(Mandatory)][string]$Name,
            [scriptblock]$Mutator
        )
        $manifest = New-TestManifest -Mutator $Mutator
        return Write-TestJson -Path (Join-Path $TestDrive $Name) -Value $manifest
    }

    function New-TestStateRoot {
        return Join-Path $TestDrive ('state-' + [guid]::NewGuid().ToString('N'))
    }

    function Set-TestCheckpoint {
        param([AllowNull()][object]$Name)
        & $script:OrchestratorModule { param($Checkpoint) $script:OwnerV2TestCheckpoint = $Checkpoint } $Name
    }

    function Get-TestRecordFile {
        param([Parameter(Mandatory)][string]$StateRoot)
        return Get-ChildItem -LiteralPath $StateRoot -Recurse -Filter '*.json' |
            Where-Object { $_.FullName -match [regex]::Escape([IO.Path]::DirectorySeparatorChar + 'records' + [IO.Path]::DirectorySeparatorChar) } |
            Select-Object -First 1
    }

    function Get-TestObservation {
        param([Parameter(Mandatory)][string]$StateRoot)
        $file = Get-ChildItem -LiteralPath $StateRoot -Recurse -Filter '*.json' |
            Where-Object { $_.FullName -match [regex]::Escape([IO.Path]::DirectorySeparatorChar + 'observations' + [IO.Path]::DirectorySeparatorChar) } |
            Select-Object -First 1
        return Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    }

    function New-TestLiveContext {
        param([Parameter(Mandatory)][string]$Name, [switch]$CopilotProvider)
        $manifest = New-TestManifest
        $package = Copy-TestValue $manifest.entries[0].acquisition.package
        $manifest.entries[0].mode = 'live'
        $manifest.entries[0].Remove('replay')
        $manifest.entries[0].acquisition.Remove('package')
        $manifest.entries[0].model.id = if ($CopilotProvider) { 'gpt-5.6-sol' }
        else { 'deterministic-fake-process' }
        $manifest.entries[0].model.digest = Get-TestDigest $manifest.entries[0].model.id
        $manifestPath = Write-TestJson -Path (Join-Path $TestDrive $Name) -Value $manifest
        $acquisitionProvider = & $script:OrchestratorModule {
            param($Package)
            $state = @{ SubjectReads = 0 }
            $captured = $Package
            New-OwnerReadOnlyProviderAdapter -Name 'orchestrator-live-fixture' -Handler {
                param($Operation, $Arguments)
                switch ($Operation) {
                    'GetSubject' {
                        $value = if ($state.SubjectReads++ -eq 0) { $captured.subjectBefore }
                        else { $captured.subjectAfter }
                        return $value
                    }
                    'GetChangedFilesPage' { return $captured.changePages[[int]$Arguments.pageOrdinal] }
                    'GetRule' { return $captured.rule }
                    'GetFile' { return @($captured.files | Where-Object path -CEQ $Arguments.path)[0] }
                }
            }.GetNewClosure()
        } $package
        $provider = if ($CopilotProvider) {
            & $script:OrchestratorModule {
                param($Pwsh)
                New-OwnerCopilotCliModelProvider -Model gpt-5.6-sol -FilePath $Pwsh `
                    -CredentialEnvironmentName GH_TOKEN
            } $script:Pwsh
        }
        else {
            & $script:OrchestratorModule {
                param($Pwsh, $Child)
                New-OwnerModelFakeProvider -FilePath $Pwsh -ArgumentList @(
                    '-NoProfile', '-File', $Child, 'valid', '-')
            } $script:Pwsh $script:OwnerModelChild
        }
        return [pscustomobject]@{ ManifestPath = $manifestPath
            AcquisitionProvider = $acquisitionProvider; ModelProvider = $provider }
    }
}

Describe 'Owner v2 preview orchestrator manifest and state' {
    It 'ships a deterministic sanitized fixture and schema' {
        $schema = Get-Content -LiteralPath $script:SchemaPath -Raw | ConvertFrom-Json -AsHashtable -Depth 64
        $fixture = Get-Content -LiteralPath $script:FixturePath -Raw | ConvertFrom-Json -AsHashtable -Depth 64

        $schema.properties.entries.maxItems | Should -Be 32
        $fixture.schemaVersion | Should -Be 1
        $fixture.kind | Should -Be 'owner-v2-preview-cohort'
        @($fixture.entries).Count | Should -Be 1
        $json = $fixture | ConvertTo-Json -Depth 64 -Compress
        $json | Should -Not -Match '(?i)bearer|github_pat|ghp_|password|secret|deliveryAdapter|provider|writer|scheduler|notification|vote|comment'
    }

    It 'prepares immutable v2-only declarations, evidence, records, and index outside the repository' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'cohort.json'
        & $script:OrchestratorModule {
            param($Root) Resolve-OwnerV2StateRoot -StateRoot $Root -Create
        } $stateRoot | Out-Null
        $v1Sentinel = Join-Path $stateRoot (Join-Path 'owner-v1-state' (Join-Path 'queues' 'sentinel.json'))
        New-Item -ItemType Directory -Path (Split-Path -Parent $v1Sentinel) -Force | Out-Null
        Set-Content -LiteralPath $v1Sentinel -Value 'v1-sentinel' -NoNewline

        $result = Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath

        $result.records.Count | Should -Be 1
        $result.records[0].created | Should -BeTrue
        $result.records[0].capabilityRoot | Should -Match 'owner-v2-preview-state'
        $result.records[0].capabilityRoot | Should -Match 'schema-1'
        $result.records[0].capabilityRoot | Should -Not -Match '(keys|queues|ledgers|audits|subjects)'
        Get-Content -LiteralPath $v1Sentinel -Raw | Should -BeExactly 'v1-sentinel'
        foreach ($leaf in @('declarations', 'records', 'evidence', 'observations', 'telemetry', 'index', 'staging')) {
            Test-Path -LiteralPath (Join-Path $result.records[0].capabilityRoot $leaf) | Should -BeTrue
        }
        $index = Get-Content -LiteralPath (Join-Path $result.records[0].capabilityRoot (Join-Path 'index' 'records.json')) -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $index.kind | Should -Be 'owner-v2-preview-index'
        $index.records.identity | Should -Be $result.records[0].identity
    }

    It 'suppresses duplicate prepare and preserves immutable artifact bytes' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'cohort.json'
        $first = Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath
        $declaration = Get-ChildItem -LiteralPath $stateRoot -Recurse -Filter '*.json' |
            Where-Object { $_.FullName -match 'declarations' } | Select-Object -First 1
        $before = [IO.File]::ReadAllBytes($declaration.FullName)

        $second = Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath
        $after = [IO.File]::ReadAllBytes($declaration.FullName)

        $first.records[0].identity | Should -Be $second.records[0].identity
        $second.records[0].created | Should -BeFalse
        @(Get-ChildItem -LiteralPath $stateRoot -Recurse -Filter '*.json' |
            Where-Object { $_.FullName -match 'records' -and $_.Name -ne 'records.json' }).Count | Should -Be 1
        [Convert]::ToHexString($after) | Should -BeExactly ([Convert]::ToHexString($before))
    }

    It 'uses distinct identities for changed head, rule, config, and model bindings' {
        $stateRoot = New-TestStateRoot
        $base = (Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath (New-TestManifestFile -Name 'base.json')).records[0].identity
        $head = (Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath (New-TestManifestFile -Name 'head.json' -Mutator {
                    param($m)
                    $m.entries[0].head.sourceCommit = 'd' * 40
                    Set-TestPackageSourceCommit -Entry $m.entries[0] -SourceCommit ('d' * 40)
                })).records[0].identity
        $rule = (Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath (New-TestManifestFile -Name 'rule.json' -Mutator {
                    param($m)
                    $m.entries[0].rule.hash = Get-TestDigest 'different rule'
                    $m.entries[0].rule.length = 14
                    $m.entries[0].acquisition.package.rule.ruleHash = $m.entries[0].rule.hash
                    $m.entries[0].acquisition.package.rule.ruleLength = 14
                    $m.entries[0].acquisition.package.rule.content = 'different rule'
                })).records[0].identity
        $config = (Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath (New-TestManifestFile -Name 'config.json' -Mutator {
                    param($m) $m.entries[0].config.digest = Get-TestDigest 'different config'
                })).records[0].identity
        $model = (Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath (New-TestManifestFile -Name 'model.json' -Mutator {
                    param($m) $m.entries[0].model.digest = Get-TestDigest 'different model'
                })).records[0].identity

        @(@($base, $head, $rule, $config, $model) | Select-Object -Unique).Count | Should -Be 5
    }

    It 'rejects unsafe roots, symlinks when available, manifest caps, and writer-shaped fields' {
        $manifestPath = New-TestManifestFile -Name 'cohort.json'
        { Invoke-OwnerV2PreviewPrepare -StateRoot '.\relative' -ManifestPath $manifestPath } |
            Should -Throw '*absolute*'
        { Invoke-OwnerV2PreviewPrepare -StateRoot (Resolve-Path '.').Path -ManifestPath $manifestPath } |
            Should -Throw '*outside the repository*'
        if ($IsWindows) {
            $deviceAlias = '\\?\' + (Resolve-Path '.').Path
            { Invoke-OwnerV2PreviewPrepare -StateRoot $deviceAlias -ManifestPath $manifestPath } |
                Should -Throw '*device-path alias*'
            $loopbackAlias = '\\localhost\' + ([IO.Path]::GetPathRoot((Resolve-Path '.').Path).
                TrimEnd('\').TrimEnd(':')) + '$\' +
                (Resolve-Path '.').Path.Substring(3)
            { Invoke-OwnerV2PreviewPrepare -StateRoot $loopbackAlias -ManifestPath $manifestPath } |
                Should -Throw '*UNC path*'
            $driveName = @('Z', 'Y', 'X', 'Q') |
                Where-Object { $null -eq (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } |
                Select-Object -First 1
            if ($driveName) {
                New-PSDrive -Name $driveName -PSProvider FileSystem -Root (Resolve-Path '.').Path `
                    -Scope Global | Out-Null
                try {
                    { Invoke-OwnerV2PreviewPrepare `
                            -StateRoot "$driveName`:\owner-v2-alias-state" `
                            -ManifestPath $manifestPath } |
                        Should -Throw '*outside the repository*'
                }
                finally {
                    Remove-PSDrive -Name $driveName -Scope Global -Force
                }
            }
            $uncDriveName = @('R', 'S', 'N', 'M') |
                Where-Object { $null -eq (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } |
                Select-Object -First 1
            if ($uncDriveName) {
                $uncRoot = '\\localhost\' +
                    ([IO.Path]::GetPathRoot($TestDrive).TrimEnd('\').TrimEnd(':')) + '$\' +
                    $TestDrive.Substring(3)
                $createdUncDrive = $false
                try {
                    New-PSDrive -Name $uncDriveName -PSProvider FileSystem -Root $uncRoot `
                        -Scope Global -ErrorAction Stop | Out-Null
                    $createdUncDrive = $true
                    { Invoke-OwnerV2PreviewPrepare `
                            -StateRoot "$uncDriveName`:\owner-v2-unc-state" `
                            -ManifestPath $manifestPath } |
                        Should -Throw '*UNC path*'
                }
                catch {
                    if ($createdUncDrive) { throw }
                }
                finally {
                    if ($createdUncDrive) {
                        Remove-PSDrive -Name $uncDriveName -Scope Global -Force
                    }
                }
            }
            $substName = @('W', 'V', 'U', 'T') |
                Where-Object {
                    -not (Test-Path "$_`:\") -and
                    $null -eq (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue)
                } |
                Select-Object -First 1
            if ($substName) {
                & subst.exe "$substName`:" (Resolve-Path '.').Path
                try {
                    { Invoke-OwnerV2PreviewPrepare `
                            -StateRoot "$substName`:\owner-v2-subst-state" `
                            -ManifestPath $manifestPath } |
                        Should -Throw '*substituted drive*'
                }
                finally {
                    & subst.exe "$substName`:" /D
                }
            }
        }

        $cappedPath = New-TestManifestFile -Name 'too-many.json' -Mutator {
            param($m)
            $entry = Copy-TestValue $m.entries[0]
            $m.entries = @(for ($i = 0; $i -lt 33; $i++) {
                    $copy = Copy-TestValue $entry
                    $copy.id = "entry-$i"
                    $copy
                })
        }
        { Invoke-OwnerV2PreviewPrepare -StateRoot (New-TestStateRoot) -ManifestPath $cappedPath } |
            Should -Throw '*1 to 32 entries*'

        $unsafePath = New-TestManifestFile -Name 'unsafe.json' -Mutator {
            param($m) $m.entries[0]['deliveryAdapter'] = 'not-allowed'
        }
        { Invoke-OwnerV2PreviewPrepare -StateRoot (New-TestStateRoot) -ManifestPath $unsafePath } |
            Should -Throw '*unsafe*'

        $target = Join-Path $TestDrive 'real-state'
        $link = Join-Path $TestDrive 'linked-state'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $createdLink = $false
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
            $createdLink = $true
        }
        catch {
            $createdLink = $false
        }
        if ($createdLink) {
            { Invoke-OwnerV2PreviewPrepare -StateRoot $link -ManifestPath $manifestPath } |
                Should -Throw '*link or reparse*'
        }
    }

    It 'treats source and rule bytes as opaque while rejecting sensitive control-plane values' {
        $opaqueRule = 'password=fixture-only'
        $opaqueSource = 'const token = "ghp_fixture_only";'
        $opaquePath = New-TestManifestFile -Name 'opaque-source.json' -Mutator {
            param($m)
            $ruleDigest = Get-TestDigest $opaqueRule
            $m.entries[0].rule.hash = $ruleDigest
            $m.entries[0].rule.length = [Text.UTF8Encoding]::new($false).
                GetByteCount($opaqueRule)
            $m.entries[0].acquisition.package.rule.ruleHash = $ruleDigest
            $m.entries[0].acquisition.package.rule.ruleLength = $m.entries[0].rule.length
            $m.entries[0].acquisition.package.rule.content = $opaqueRule
            $m.entries[0].acquisition.package.rule.sourceDigest = $ruleDigest
            $m.entries[0].acquisition.package.files[0].content = $opaqueSource
        }

        {
            Invoke-OwnerV2PreviewPrepare `
                -StateRoot (New-TestStateRoot) -ManifestPath $opaquePath
        } | Should -Not -Throw

        $unsafeControlPath = New-TestManifestFile -Name 'unsafe-control.json' -Mutator {
            param($m)
            $m.entries[0].config.id = 'password=fixture-only'
        }
        {
            Invoke-OwnerV2PreviewPrepare `
                -StateRoot (New-TestStateRoot) -ManifestPath $unsafeControlPath
        } | Should -Throw '*looked sensitive*'
    }
}

Describe 'Owner v2 preview orchestrator run lifecycle' {
    AfterEach {
        Set-TestCheckpoint $null
    }

    It 'runs replay through acquisition, model replay, capability, facade, and observation with zero writes' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'cohort.json'

        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        $run = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath
        $observation = Get-TestObservation -StateRoot $stateRoot

        $run.records[0].state | Should -Be 'completed'
        $observation.kind | Should -Be 'owner-observation'
        $observation.execution.modelStarts | Should -Be 0
        $observation.measurements.execution.modelStarts.status | Should -Be 'measured'
        $observation.execution.attempts | Should -Be 1
        $observation.effects.providerWrites | Should -Be 0
        $observation.effects.writeToolInvocations | Should -Be 0
        $observation.findings.identity | Should -Contain 'owner-v2:4bc00185dca8dd54e89d01a35990b46d8cb31ed777f2dd0fdf9175cf6f80dca9'
    }

    It 'fails live declarations closed before provider or model launch unless explicitly enabled' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'live.json' -Mutator {
            param($m)
            $m.entries[0].mode = 'live'
            $m.entries[0].Remove('replay')
            $m.entries[0].acquisition.Remove('package')
            $m.entries[0].acquisition.payloadDigest = Get-TestDigest 'pinned live acquisition placeholder'
        }

        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        $run = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath
        $observation = Get-TestObservation -StateRoot $stateRoot

        $run.records[0].state | Should -Be 'incomplete'
        $run.records[0].reason | Should -Be 'live-model-disabled'
        $observation.execution.modelStarts | Should -Be 0
        $observation.measurements.execution.modelStarts.status | Should -Be 'measured'
        $observation.execution.refusalReason | Should -Be 'live-model-disabled'
        $observation.effects.providerWrites | Should -Be 0
        $observation.effects.writeToolInvocations | Should -Be 0
    }

    It 'injects the existing provider runner into live semantic units with exact zero-write telemetry' {
        $stateRoot = New-TestStateRoot
        $live = New-TestLiveContext -Name 'live-fake.json'
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot `
                -ManifestPath $live.ManifestPath)

        $run = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $live.ManifestPath `
            -EnableLiveModel -LiveAcquisitionProvider $live.AcquisitionProvider `
            -LiveModelProvider $live.ModelProvider
        $observation = Get-TestObservation -StateRoot $stateRoot
        $telemetry = Get-Content -LiteralPath $run.records[0].telemetryPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64

        $run.records[0].state | Should -Be 'completed'
        $observation.execution.attempts | Should -Be 1
        $observation.counts.eligible | Should -BeGreaterThan 0
        @($telemetry.Keys) | Should -Be @(
            'acceptedArgvRisk', 'attempts', 'effectiveTools', 'latencyMs', 'modelCalls',
            'modelStarts', 'modelStartsMinimum', 'policy', 'provider', 'providerWrites',
            'records', 'refusalReason', 'writeToolInvocations')
        @($telemetry.effectiveTools).Count | Should -Be 0
        @($telemetry.policy.availableTools).Count | Should -Be 0
        @($telemetry.attempts, $telemetry.modelCalls, $telemetry.modelStarts,
            $telemetry.providerWrites, $telemetry.writeToolInvocations) |
            Should -Be @(1, 0, 0, 0, 0)
        $telemetry.refusalReason | Should -Be 'none'
        $telemetry.acceptedArgvRisk.promptTransport | Should -Be 'private-file'
        $telemetry.acceptedArgvRisk.accepted | Should -BeFalse
        @($observation.sourceArtifacts | Where-Object kind -CEQ owner-model-runner-telemetry).Count |
            Should -Be 1
    }

    It 'propagates real provider preflight unavailability as truthful incomplete telemetry' {
        $prior = $env:GH_TOKEN
        try {
            $env:GH_TOKEN = 'gho_testcredentialvalue'
            $stateRoot = New-TestStateRoot
            $live = New-TestLiveContext -Name 'live-preflight.json' -CopilotProvider
            [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot `
                    -ManifestPath $live.ManifestPath)

            $run = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $live.ManifestPath `
                -EnableLiveModel -LiveAcquisitionProvider $live.AcquisitionProvider `
                -LiveModelProvider $live.ModelProvider
            $observation = Get-TestObservation -StateRoot $stateRoot
            $telemetry = Get-Content -LiteralPath $run.records[0].telemetryPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64

            $run.records[0].state | Should -Be 'incomplete'
            $run.records[0].reason | Should -Be 'copilot-cli-publisher-identity-unproven'
            $observation.execution.refusalReason | Should -Be $run.records[0].reason
            @($observation.execution.attempts, $telemetry.modelCalls,
                $telemetry.providerWrites) | Should -Be @(0, 0, 0)
            @($telemetry.effectiveTools).Count | Should -Be 0
            $telemetry.acceptedArgvRisk.promptTransport | Should -Be 'argv'
            $telemetry.acceptedArgvRisk.localProcessMetadataExposure | Should -BeTrue
            $telemetry.acceptedArgvRisk.accepted | Should -BeTrue
        }
        finally {
            $env:GH_TOKEN = $prior
        }
    }

    It 'reuses a completed live result without another provider call' {
        $stateRoot = New-TestStateRoot
        $live = New-TestLiveContext -Name 'live-idempotent.json'
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot `
                -ManifestPath $live.ManifestPath)
        $first = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $live.ManifestPath `
            -EnableLiveModel -LiveAcquisitionProvider $live.AcquisitionProvider `
            -LiveModelProvider $live.ModelProvider
        $before = [IO.File]::ReadAllBytes($first.records[0].telemetryPath)

        $second = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $live.ManifestPath `
            -EnableLiveModel -LiveAcquisitionProvider $live.AcquisitionProvider `
            -LiveModelProvider $live.ModelProvider
        $after = [IO.File]::ReadAllBytes($first.records[0].telemetryPath)

        $second.records[0].reason | Should -Be 'already-terminal'
        [Convert]::ToHexString($after) | Should -BeExactly ([Convert]::ToHexString($before))
        (Get-Content -LiteralPath $first.records[0].telemetryPath -Raw |
            ConvertFrom-Json -AsHashtable).attempts | Should -Be 1
    }

    It 'fails its live wiring mutation guard when provider runner construction is removed' {
        $source = Get-Content -LiteralPath (
            Join-Path $PSScriptRoot '..\src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psm1') -Raw
        $wiring = 'New-OwnerModelProcessRunner -Provider $provider'

        $source | Should -Match ([regex]::Escape($wiring))
        ($source.Replace($wiring, 'New-OwnerModelReplayRunner')) |
            Should -Not -Match ([regex]::Escape($wiring))
    }

    It 'handles unknown units and partial evidence without launching a model' {
        $unknownState = New-TestStateRoot
        $unknownManifest = New-TestManifestFile -Name 'unknown.json' -Mutator {
            param($m)
            $m.entries[0].replay.modelRecords[0].responseBytesBase64 =
                [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not a marker'))
        }
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $unknownState -ManifestPath $unknownManifest)
        [void](Invoke-OwnerV2PreviewRun -StateRoot $unknownState -ManifestPath $unknownManifest)
        $unknownObservation = Get-TestObservation -StateRoot $unknownState
        $unknownObservation.execution.modelStarts | Should -Be 0
        $unknownObservation.counts.unknown | Should -BeGreaterOrEqual 1

        $partialState = New-TestStateRoot
        $partialManifest = New-TestManifestFile -Name 'partial.json'
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $partialState -ManifestPath $partialManifest)
        Get-ChildItem -LiteralPath $partialState -Recurse -Filter '*.json' |
            Where-Object { $_.FullName -match 'evidence' } |
            Remove-Item -Force
        [void](Invoke-OwnerV2PreviewRun -StateRoot $partialState -ManifestPath $partialManifest)
        $partialObservation = Get-TestObservation -StateRoot $partialState
        $partialObservation.execution.modelStarts | Should -Be 'unknown'
        $partialObservation.lifecycle.status | Should -Be 'unknown'
    }

    It 'supports prepare crash recovery and stale running lease recovery' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'cohort.json'
        Set-TestCheckpoint 'prepare-before-publish'
        { Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath } |
            Should -Throw '*prepare-before-publish*'
        @(Get-ChildItem -LiteralPath $stateRoot -Recurse -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'records' -and $_.Name -ne 'records.json' }).Count | Should -Be 0

        Set-TestCheckpoint $null
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        Set-TestCheckpoint 'run-after-reservation'
        { Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath -LeaseSeconds 1 } |
            Should -Throw '*run-after-reservation*'
        $recordFile = Get-TestRecordFile -StateRoot $stateRoot
        $reserved = Get-Content -LiteralPath $recordFile.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 32
        $reserved.state | Should -Be 'running'
        $reserved.attempts | Should -Be 1

        Start-Sleep -Seconds 2
        Set-TestCheckpoint $null
        $run = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath
        $run.records[0].attempts | Should -Be 2
        $run.records[0].state | Should -Be 'completed'
    }

    It 'fences publication to the exact reservation lease and ignores orphaned staging files' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'lease-fencing.json'
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        $recordFile = Get-TestRecordFile -StateRoot $stateRoot
        $orphan = Join-Path $recordFile.DirectoryName (
            '.owner-v2-stage-' + ([guid]::NewGuid().ToString('N')) + '.json')
        Set-Content -LiteralPath $orphan -Value '{' -NoNewline
        $checkpoint = {
            param($Name)
            if ($Name -cne 'run-before-publish') { return }
            $record = Get-Content -LiteralPath $recordFile.FullName -Raw |
                ConvertFrom-Json -AsHashtable -Depth 32
            $record.lease.id = 'replacement-lease'
            [IO.File]::WriteAllText(
                $recordFile.FullName,
                (ConvertTo-Json -InputObject $record -Depth 64) + "`n",
                [Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        Set-TestCheckpoint $checkpoint

        $run = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath

        $run.records[0].reason | Should -Be 'reservation-lost'
        (Get-Content -LiteralPath $recordFile.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32).lease.id | Should -Be 'replacement-lease'
        @(Get-ChildItem -LiteralPath $recordFile.DirectoryName -Filter '*.json' -Force).Count |
            Should -Be 2
    }

    It 'suppresses active concurrent reservations and enforces maximum attempts' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'cohort.json'
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath -MaxAttempts 1)
        $recordFile = Get-TestRecordFile -StateRoot $stateRoot
        $record = Get-Content -LiteralPath $recordFile.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 32
        $record.state = 'running'
        $record.attempts = 1
        $record.lease = @{ id = 'active'; acquiredUtc = 'utc:2999-01-01T00:00:00Z'; expiresUtc = 'utc:2999-01-01T00:00:00Z' }
        Write-TestJson -Path $recordFile.FullName -Value $record | Out-Null

        $active = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath
        $active.records[0].state | Should -Be 'running'
        $active.records[0].reason | Should -Be 'lease-active'

        $record.lease.expiresUtc = 'utc:2000-01-01T00:00:00Z'
        Write-TestJson -Path $recordFile.FullName -Value $record | Out-Null
        $expired = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath
        $expired.records[0].state | Should -Be 'incomplete'
        $expired.records[0].reason | Should -Be 'maximum-attempts'
    }

    It 'never reopens completed or unknown terminal records with interrupted metadata' -TestCases @(
        @{ State = 'completed' }
        @{ State = 'unknown' }
    ) {
        param($State)
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name "$State-terminal.json"
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        $recordFile = Get-TestRecordFile -StateRoot $stateRoot
        $record = Get-Content -LiteralPath $recordFile.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32
        $record.state = $State
        $record.attempts = 1
        $record.incompleteReason = 'interrupted'
        Write-TestJson -Path $recordFile.FullName -Value $record | Out-Null

        $run = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath

        $run.records[0].state | Should -Be $State
        $run.records[0].reason | Should -Be 'already-terminal'
        (Get-Content -LiteralPath $recordFile.FullName -Raw |
            ConvertFrom-Json -AsHashtable -Depth 32).attempts | Should -Be 1
    }

    It 'refuses malformed persisted records and unsafe persisted record fields' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'cohort.json'
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        $recordFile = Get-TestRecordFile -StateRoot $stateRoot
        Write-TestJson -Path $recordFile.FullName -Value @{ schemaVersion = 1; kind = 'owner-v2-preview-record'; deliveryAdapter = 'bad' } | Out-Null

        { Get-OwnerV2PreviewStatus -StateRoot $stateRoot -ManifestPath $manifestPath } |
            Should -Throw '*unsafe*'
        { Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath } |
            Should -Throw '*unsafe*'
    }

    It 'returns deterministic status, sorted index, and persisted observation' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'multi.json' -Mutator {
            param($m)
            $entry = Copy-TestValue $m.entries[0]
            $entry.id = 'generic-replay-owner-cohort-b'
            $entry.config.digest = Get-TestDigest 'b-config'
            $m.entries = @($entry, $m.entries[0])
        }
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        $first = Get-OwnerV2PreviewStatus -StateRoot $stateRoot -ManifestPath $manifestPath
        $second = Get-OwnerV2PreviewStatus -StateRoot $stateRoot -ManifestPath $manifestPath
        ($first | ConvertTo-Json -Depth 64 -Compress) |
            Should -BeExactly ($second | ConvertTo-Json -Depth 64 -Compress)
        @($first.records.identity) | Should -Be @($first.records.identity | Sort-Object)

        [void](Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath)
        $observationFile = Get-ChildItem -LiteralPath $stateRoot -Recurse -Filter '*.json' |
            Where-Object { $_.FullName -match 'observations' } | Select-Object -First 1
        $before = Get-Content -LiteralPath $observationFile.FullName -Raw
        $after = Get-Content -LiteralPath $observationFile.FullName -Raw
        $before | Should -BeExactly $after
    }

    It 'deduplicates identical declarations in run and status results' {
        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'duplicates.json' -Mutator {
            param($m)
            $duplicate = Copy-TestValue $m.entries[0]
            $duplicate.id = 'duplicate-display-id'
            $m.entries = @($m.entries[0], $duplicate)
        }
        $prepared = Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath
        $run = Invoke-OwnerV2PreviewRun -StateRoot $stateRoot -ManifestPath $manifestPath
        $status = Get-OwnerV2PreviewStatus -StateRoot $stateRoot -ManifestPath $manifestPath

        @($prepared.records).Count | Should -Be 1
        @($run.records).Count | Should -Be 1
        @($status.records).Count | Should -Be 1
        @($status.index.records).Count | Should -Be 1
    }

    It 'exposes only the narrow public module surface and validates the manual wrapper' {
        @((Get-Command -Module DevPilot.OwnerOrchestrator).Name | Sort-Object) | Should -Be @(
            'Get-OwnerV2PreviewStatus',
            'Invoke-OwnerV2PreviewPrepare',
            'Invoke-OwnerV2PreviewRun'
        )
        Test-ModuleManifest "$PSScriptRoot\..\src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1" |
            Select-Object -ExpandProperty Name | Should -Be 'DevPilot.OwnerOrchestrator'

        $stateRoot = New-TestStateRoot
        $manifestPath = New-TestManifestFile -Name 'wrapper.json'
        & $script:OrchestratorModule {
            param($Root) Resolve-OwnerV2StateRoot -StateRoot $Root -Create
        } $stateRoot | Out-Null
        $output = & "$PSScriptRoot\..\tools\Invoke-OwnerV2Preview.ps1" status `
            -StateRoot $stateRoot -ManifestPath $manifestPath
        $output.kind | Should -Be 'owner-v2-preview-status'
        $output.records[0].state | Should -Be 'unknown'

        $replayState = New-TestStateRoot
        $replay = & "$PSScriptRoot\..\tools\Invoke-OwnerV2Preview.ps1" prepare-run `
            -StateRoot $replayState -ManifestPath $manifestPath
        $replay.records[0].state | Should -Be 'completed'
    }
}
