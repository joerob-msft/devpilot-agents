Describe 'Owner dependency module coexistence' {
    It 'preserves pre-imported Owner modules through <Target> (caller Force=<Force>)' -ForEach @(
        @{ Target = 'OwnerObservationContract'; Force = $false }
        @{ Target = 'OwnerObservationContract'; Force = $true }
        @{ Target = 'OwnerObserver'; Force = $false }
        @{ Target = 'OwnerObserver'; Force = $true }
        @{ Target = 'DevPilot.OwnerCapability'; Force = $false }
        @{ Target = 'DevPilot.OwnerCapability'; Force = $true }
        @{ Target = 'DevPilot.OwnerModelRunner'; Force = $false }
        @{ Target = 'DevPilot.OwnerModelRunner'; Force = $true }
        @{ Target = 'DevPilot.OwnerOrchestrator'; Force = $false }
        @{ Target = 'DevPilot.OwnerOrchestrator'; Force = $true }
        @{ Target = 'DevPilot.OwnerParity'; Force = $false }
        @{ Target = 'DevPilot.OwnerParity'; Force = $true }
        @{ Target = 'DevPilot.RelationEvidence'; Force = $false }
        @{ Target = 'DevPilot.RelationEvidence'; Force = $true }
    ) {
        param($Target, $Force)

        $repoRoot = Split-Path $PSScriptRoot -Parent
        $targetManifest = Join-Path $repoRoot "src\$Target\$Target.psd1"
        if (-not (Test-Path -LiteralPath $targetManifest -PathType Leaf)) {
            Set-ItResult -Skipped -Because "$Target is introduced by an upper stack layer."
            return
        }

        $harnessManifest = Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
        $contractManifest = Join-Path $repoRoot `
            'src\OwnerObservationContract\OwnerObservationContract.psd1'
        $pipelineManifest = Join-Path $repoRoot `
            'src\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1'
        $capabilityManifest = Join-Path $repoRoot `
            'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1'
        $observerManifest = Join-Path $repoRoot 'src\OwnerObserver\OwnerObserver.psd1'
        $orchestratorManifest = Join-Path $repoRoot `
            'src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1'
        $parityManifest = Join-Path $repoRoot 'src\DevPilot.OwnerParity\DevPilot.OwnerParity.psd1'
        $caseRoot = Join-Path $TestDrive (
            $Target.Replace('.', '-') + '-' + $Force.ToString().ToLowerInvariant())
        $probePath = Join-Path $caseRoot 'probe.ps1'
        [void](New-Item -ItemType Directory -Path $caseRoot -Force)
        Copy-Item -LiteralPath (
            Join-Path $repoRoot 'tests\fixtures\owner-orchestrator\generic-cohort.json'
        ) -Destination (Join-Path $caseRoot 'cohort.json')
        [IO.File]::WriteAllText($probePath, @'
param(
    [Parameter(Mandatory)][string]$HarnessManifest,
    [Parameter(Mandatory)][string]$ContractManifest,
    [Parameter(Mandatory)][string]$PipelineManifest,
    [Parameter(Mandatory)][string]$CapabilityManifest,
    [Parameter(Mandatory)][string]$ObserverManifest,
    [Parameter(Mandatory)][string]$OrchestratorManifest,
    [Parameter(Mandatory)][string]$ParityManifest,
    [Parameter(Mandatory)][string]$TargetManifest,
    [Parameter(Mandatory)][string]$TargetName,
    [Parameter(Mandatory)][string]$UseForce,
    [Parameter(Mandatory)][string]$CaseRoot,
    [Parameter(Mandatory)][string]$RepositoryRoot
)
$ErrorActionPreference = 'Stop'
Import-Module $HarnessManifest -Global
Import-Module $ContractManifest -Global
Import-Module $PipelineManifest -Global
Import-Module $CapabilityManifest -Global
Import-Module $ObserverManifest -Global
Import-Module $OrchestratorManifest -Global
Import-Module $ParityManifest -Global
$preservedCommands = [ordered]@{
    'DevPilot.AgentHarness' = 'Get-DevPilotAgentPath'
    'OwnerObservationContract' = 'New-OwnerMeasurement'
    'DevPilot.OwnerPipeline' = 'New-OwnerPipelineBinding'
    'DevPilot.OwnerCapability' = 'New-OwnerV2CapabilityAdapter'
    'OwnerObserver' = 'Test-OwnerObservation'
    'DevPilot.OwnerOrchestrator' = 'Get-OwnerV2PreviewStatus'
    'DevPilot.OwnerParity' = 'Test-OwnerParityPathIsolation'
}
$preservedApiHubCommands = @(
    'Invoke-AgentGitHubApi',
    'Get-AgentProviderPullRequestSnapshot',
    'Invoke-AgentWorkIqTool'
)
$beforeModules = @{}
$beforeCommands = @{}
foreach ($name in $preservedCommands.Keys) {
    $beforeModules[$name] = Get-Module $name
    $beforeCommands[$name] = Get-Command $preservedCommands[$name] -ErrorAction Stop
}
$beforeApiHubCommands = @{}
foreach ($name in $preservedApiHubCommands) {
    $beforeApiHubCommands[$name] = Get-Command $name -ErrorAction Stop
}

if ($UseForce -ceq 'true') {
    Import-Module $TargetManifest -Force
}
else {
    Import-Module $TargetManifest
}

$targetModule = Get-Module $TargetName
$targetCommands = @{
    'OwnerObservationContract' = 'New-OwnerMeasurement'
    'OwnerObserver' = 'Test-OwnerObservation'
    'DevPilot.OwnerCapability' = 'New-OwnerV2CapabilityAdapter'
    'DevPilot.OwnerModelRunner' = 'New-OwnerModelReplayRunner'
    'DevPilot.OwnerOrchestrator' = 'Get-OwnerV2PreviewStatus'
    'DevPilot.OwnerParity' = 'Test-OwnerParityPathIsolation'
    'DevPilot.RelationEvidence' = 'New-RelationEvidenceRequest'
}
$targetCommand = Get-Command $targetCommands[$TargetName] -ErrorAction SilentlyContinue
$modulesPreserved = $true
$commandsPreserved = $true
foreach ($name in $preservedCommands.Keys) {
    if ($name -ceq $TargetName) { continue }
    $afterModules = @(Get-Module $name)
    $afterCommand = Get-Command $preservedCommands[$name] -ErrorAction SilentlyContinue
    $modulesPreserved = $modulesPreserved -and
        $afterModules.Count -eq 1 -and
        [object]::ReferenceEquals($beforeModules[$name], $afterModules[0])
    $commandsPreserved = $commandsPreserved -and
        $null -ne $afterCommand -and
        [object]::ReferenceEquals($beforeCommands[$name].Module, $afterCommand.Module)
}
foreach ($name in $preservedApiHubCommands) {
    $afterCommand = Get-Command $name -ErrorAction SilentlyContinue
    $commandsPreserved = $commandsPreserved -and
        $null -ne $afterCommand -and
        [object]::ReferenceEquals($beforeApiHubCommands[$name].Module, $afterCommand.Module)
}
$lifecycleCompatible = $null
$commandWorked = switch ($TargetName) {
    'DevPilot.OwnerOrchestrator' {
        $stateRoot = Join-Path $CaseRoot 'state'
        $manifestPath = Join-Path $CaseRoot 'cohort.json'
        [void](Invoke-OwnerV2PreviewPrepare -StateRoot $stateRoot -ManifestPath $manifestPath)
        (Get-OwnerV2PreviewStatus -StateRoot $stateRoot -ManifestPath $manifestPath).kind -ceq `
            'owner-v2-preview-status'
    }
    'DevPilot.OwnerParity' {
        $v1Root = Join-Path $CaseRoot 'v1'
        $v2Root = Join-Path $CaseRoot 'v2'
        [void](New-Item -ItemType Directory -Path $v1Root -Force)
        $pathIsolated = (Test-OwnerParityPathIsolation `
                -V1StateRoot $v1Root `
                -V2StateRoot $v2Root `
                -RepositoryRoot $RepositoryRoot).isolated
        $lifecycle = & $targetModule {
            param($StateRoot, $ManifestPath)
            [void](Invoke-OwnerV2PreviewPrepare `
                    -StateRoot $StateRoot `
                    -ManifestPath $ManifestPath)
            Get-ChildItem -LiteralPath $StateRoot -Recurse -Filter '*.json' |
                Where-Object { $_.FullName -match 'evidence' } |
                Remove-Item -Force
            $run = Invoke-OwnerV2PreviewRun `
                -StateRoot $StateRoot `
                -ManifestPath $ManifestPath
            $observationFile = Get-ChildItem -LiteralPath $StateRoot -Recurse -Filter '*.json' |
                Where-Object { $_.FullName -match 'observations' } |
                Select-Object -First 1
            $observation = Get-Content -LiteralPath $observationFile.FullName -Raw |
                ConvertFrom-Json -AsHashtable -Depth 64
            [pscustomobject]@{
                RecordState = [string]$run.records[0].state
                Status = [string]$observation.lifecycle.status
                Completed = [string]$observation.lifecycle.completed
                Incomplete = [string]$observation.lifecycle.incomplete
                Pending = [string]$observation.lifecycle.pending
            }
        } (Join-Path $CaseRoot 'partial-state') (Join-Path $CaseRoot 'cohort.json')
        $lifecycleCompatible = $lifecycle.RecordState -ceq 'unknown' -and
            $lifecycle.Status -ceq 'unknown' -and
            $lifecycle.Completed -ceq 'unknown' -and
            $lifecycle.Incomplete -ceq 'unknown' -and
            $lifecycle.Pending -ceq 'unknown'
        $pathIsolated -and $lifecycleCompatible
    }
    default { $null -ne $targetCommand }
}

[pscustomobject]@{
    ModulesPreserved = $modulesPreserved
    CommandsPreserved = $commandsPreserved
    TargetLoaded = $null -ne $targetModule
    TargetCommandAvailable = $null -ne $targetCommand
    TargetCommandWorked = [bool]$commandWorked
    LifecycleCompatible = $lifecycleCompatible
} | ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($false))

        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive `
            -File $probePath `
            -HarnessManifest $harnessManifest `
            -ContractManifest $contractManifest `
            -PipelineManifest $pipelineManifest `
            -CapabilityManifest $capabilityManifest `
            -ObserverManifest $observerManifest `
            -OrchestratorManifest $orchestratorManifest `
            -ParityManifest $parityManifest `
            -TargetManifest $targetManifest `
            -TargetName $Target `
            -UseForce $Force.ToString().ToLowerInvariant() `
            -CaseRoot $caseRoot `
            -RepositoryRoot $repoRoot
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String)
        }
        $result = @($output | Select-Object -Last 1 | ConvertFrom-Json)

        $result | Should -HaveCount 1
        $result[0].ModulesPreserved | Should -BeTrue
        $result[0].CommandsPreserved | Should -BeTrue
        $result[0].TargetLoaded | Should -BeTrue
        $result[0].TargetCommandAvailable | Should -BeTrue
        $result[0].TargetCommandWorked | Should -BeTrue
        if ($Target -ceq 'DevPilot.OwnerParity') {
            $result[0].LifecycleCompatible | Should -BeTrue
        }
    }

    It 'preserves pre-imported modules through the live preview wrapper' {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $harnessManifest = Join-Path $repoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
        $observerManifest = Join-Path $repoRoot 'src\OwnerObserver\OwnerObserver.psd1'
        $parityManifest = Join-Path $repoRoot 'src\DevPilot.OwnerParity\DevPilot.OwnerParity.psd1'
        $wrapperPath = Join-Path $repoRoot 'tools\Invoke-OwnerV2Preview.ps1'
        $caseRoot = Join-Path $TestDrive 'live-preview-wrapper'
        $probePath = Join-Path $caseRoot 'probe.ps1'
        $manifestPath = Join-Path $caseRoot 'cohort.json'
        $stateRoot = Join-Path $caseRoot 'state'
        [void](New-Item -ItemType Directory -Path $caseRoot -Force)
        Copy-Item -LiteralPath (
            Join-Path $repoRoot 'tests\fixtures\owner-orchestrator\generic-cohort.json'
        ) -Destination $manifestPath
        [IO.File]::WriteAllText($probePath, @'
param(
    [Parameter(Mandatory)][string]$HarnessManifest,
    [Parameter(Mandatory)][string]$ObserverManifest,
    [Parameter(Mandatory)][string]$ParityManifest,
    [Parameter(Mandatory)][string]$WrapperPath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$StateRoot
)
$ErrorActionPreference = 'Stop'
Import-Module $HarnessManifest -Global
Import-Module $ObserverManifest -Global
Import-Module $ParityManifest -Global
$preservedCommands = [ordered]@{
    'DevPilot.AgentHarness' = 'Get-DevPilotAgentPath'
    'OwnerObserver' = 'Test-OwnerObservation'
    'DevPilot.OwnerParity' = 'Test-OwnerParityPathIsolation'
}
$beforeModules = @{}
$beforeCommands = @{}
foreach ($name in $preservedCommands.Keys) {
    $beforeModules[$name] = Get-Module $name
    $beforeCommands[$name] = Get-Command $preservedCommands[$name] -ErrorAction Stop
}

[void](& $WrapperPath prepare-run -StateRoot $StateRoot -ManifestPath $ManifestPath)
$status = & $WrapperPath status -StateRoot $StateRoot -ManifestPath $ManifestPath

$modulesPreserved = $true
$commandsPreserved = $true
foreach ($name in $preservedCommands.Keys) {
    $afterModules = @(Get-Module $name)
    $afterCommand = Get-Command $preservedCommands[$name] -ErrorAction SilentlyContinue
    $modulesPreserved = $modulesPreserved -and
        $afterModules.Count -eq 1 -and
        [object]::ReferenceEquals($beforeModules[$name], $afterModules[0])
    $commandsPreserved = $commandsPreserved -and
        $null -ne $afterCommand -and
        [object]::ReferenceEquals($beforeCommands[$name].Module, $afterCommand.Module)
}

[pscustomobject]@{
    ModulesPreserved = $modulesPreserved
    CommandsPreserved = $commandsPreserved
    StatusWorked = [string]$status.kind -ceq 'owner-v2-preview-status'
} | ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($false))

        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive `
            -File $probePath `
            -HarnessManifest $harnessManifest `
            -ObserverManifest $observerManifest `
            -ParityManifest $parityManifest `
            -WrapperPath $wrapperPath `
            -ManifestPath $manifestPath `
            -StateRoot $stateRoot
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String)
        }
        $result = @($output | Select-Object -Last 1 | ConvertFrom-Json)

        $result | Should -HaveCount 1
        $result[0].ModulesPreserved | Should -BeTrue
        $result[0].CommandsPreserved | Should -BeTrue
        $result[0].StatusWorked | Should -BeTrue
    }

    It 'preserves pre-imported modules through the relation wrapper (caller Force=<Force>)' -ForEach @(
        @{ Force = $false }
        @{ Force = $true }
    ) {
        param($Force)

        $repoRoot = Split-Path $PSScriptRoot -Parent
        $moduleNames = @(
            'DevPilot.AgentHarness',
            'OwnerObservationContract',
            'DevPilot.OwnerPipeline',
            'DevPilot.OwnerCapability',
            'DevPilot.OwnerAdapters',
            'DevPilot.OwnerModelRunner',
            'DevPilot.RelationEvidence',
            'DevPilot.OwnerOrchestrator',
            'OwnerObserver',
            'DevPilot.OwnerParity'
        )
        $manifests = @(
            foreach ($name in $moduleNames) {
                Join-Path $repoRoot "src\$name\$name.psd1"
            }
        )
        $orchestratorManifest = Join-Path $repoRoot `
            'src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1'
        $wrapperPath = Join-Path $repoRoot 'tools\Invoke-RelationV2Preview.ps1'
        $caseRoot = Join-Path $TestDrive "relation-wrapper-$($Force.ToString().ToLowerInvariant())"
        $probePath = Join-Path $caseRoot 'probe.ps1'
        $manifestPath = Join-Path $caseRoot 'cohort.json'
        $stateRoot = Join-Path $caseRoot 'state'
        [void](New-Item -ItemType Directory -Path $caseRoot -Force)
        [IO.File]::WriteAllText($probePath, @'
param(
    [Parameter(Mandatory)][string]$ManifestList,
    [Parameter(Mandatory)][string]$OrchestratorManifest,
    [Parameter(Mandatory)][string]$WrapperPath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$UseForce
)
$ErrorActionPreference = 'Stop'
foreach ($manifest in $ManifestList.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
    Import-Module $manifest -Global
}
$preservedCommands = [ordered]@{
    'DevPilot.AgentHarness' = 'Get-DevPilotAgentPath'
    'OwnerObservationContract' = 'New-OwnerMeasurement'
    'DevPilot.OwnerPipeline' = 'New-OwnerPipelineBinding'
    'DevPilot.OwnerCapability' = 'New-OwnerV2CapabilityAdapter'
    'DevPilot.OwnerAdapters' = 'New-OwnerProductionAcquisitionAdapter'
    'DevPilot.OwnerModelRunner' = 'New-RelationEvidenceModelProcessRunner'
    'DevPilot.RelationEvidence' = 'New-RelationEvidenceRequest'
    'DevPilot.OwnerOrchestrator' = 'Get-OwnerV2PreviewStatus'
    'OwnerObserver' = 'Test-OwnerObservation'
    'DevPilot.OwnerParity' = 'Test-OwnerParityPathIsolation'
}
$preservedApiHubCommands = @(
    'Invoke-AgentGitHubApi',
    'Get-AgentProviderPullRequestSnapshot',
    'Invoke-AgentWorkIqTool'
)
$beforeModules = @{}
$beforeCommands = @{}
foreach ($name in $preservedCommands.Keys) {
    $beforeModules[$name] = Get-Module $name
    $beforeCommands[$name] = Get-Command $preservedCommands[$name] -ErrorAction Stop
}
$beforeApiHubCommands = @{}
foreach ($name in $preservedApiHubCommands) {
    $beforeApiHubCommands[$name] = Get-Command $name -ErrorAction Stop
}

if ($UseForce -ceq 'true') {
    Import-Module $OrchestratorManifest -Force
}
else {
    Import-Module $OrchestratorManifest
}

$orchestrator = Get-Module DevPilot.OwnerOrchestrator
$selectors = @(
    [ordered]@{
        role = 'sanitizer'
        required = $true
        trigger = $true
        evidenceType = 'source'
        patterns = @([ordered]@{ kind = 'exact'; value = 'src/public-response.cs' })
    }
)
$configBody = [ordered]@{
    id = 'coexistence-routing-v1'
    claimId = 'cache-independent-sanitization'
    question = 'Does every cache state apply response sanitization?'
    severity = 'high'
    policy = 'preview-only'
    anchorRole = 'sanitizer'
    selectors = $selectors
}
$digest = {
    param($Value)
    & $orchestrator {
        param($InputValue)
        Get-OwnerV2Digest -Value $InputValue
    } $Value
}
$ruleText = 'Public response sanitization must not depend on cache metadata.'
$ruleHash = 'v1:sha256:' + [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ruleText))
).ToLowerInvariant()
$cohort = [ordered]@{
    schemaVersion = 1
    kind = 'relation-v2-preview-cohort'
    entries = @([ordered]@{
        id = 'coexistence-relation'
        subject = [ordered]@{
            repositoryId = 'repository-example'
            projectId = 'project-example'
            pullRequestId = 43
        }
        head = [ordered]@{ sourceCommit = 'a' * 40 }
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
            hash = $ruleHash
            length = [Text.Encoding]::UTF8.GetByteCount($ruleText)
        }
        capability = [ordered]@{
            id = 'relation-contextual-review-v1'
            digest = & $digest 'relation-contextual-review-v1'
        }
        model = [ordered]@{
            id = 'deterministic-fake-process'
            digest = & $digest 'deterministic-fake-process'
        }
        config = [ordered]@{} + $configBody + @{
            digest = & $digest $configBody
        }
    })
}
[IO.File]::WriteAllText(
    $ManifestPath,
    (ConvertTo-Json -InputObject $cohort -Depth 32),
    [Text.UTF8Encoding]::new($false))

[void](& $WrapperPath prepare-run -StateRoot $StateRoot `
        -ManifestPath $ManifestPath -MaxAttempts 1)
$status = & $WrapperPath status -StateRoot $StateRoot -ManifestPath $ManifestPath

$modulesPreserved = $true
$commandsPreserved = $true
foreach ($name in $preservedCommands.Keys) {
    if ($UseForce -ceq 'true' -and $name -ceq 'DevPilot.OwnerOrchestrator') {
        continue
    }
    $afterModules = @(Get-Module $name)
    $afterCommand = Get-Command $preservedCommands[$name] -ErrorAction SilentlyContinue
    $modulesPreserved = $modulesPreserved -and
        $afterModules.Count -eq 1 -and
        [object]::ReferenceEquals($beforeModules[$name], $afterModules[0])
    $commandsPreserved = $commandsPreserved -and
        $null -ne $afterCommand -and
        [object]::ReferenceEquals($beforeCommands[$name].Module, $afterCommand.Module)
}
foreach ($name in $preservedApiHubCommands) {
    $afterCommand = Get-Command $name -ErrorAction SilentlyContinue
    $commandsPreserved = $commandsPreserved -and
        $null -ne $afterCommand -and
        [object]::ReferenceEquals($beforeApiHubCommands[$name].Module, $afterCommand.Module)
}

[pscustomobject]@{
    ModulesPreserved = $modulesPreserved
    CommandsPreserved = $commandsPreserved
    StatusWorked = [string]$status.kind -ceq 'owner-v2-preview-status'
    RecordState = [string]$status.records[0].state
} | ConvertTo-Json -Compress
'@, [Text.UTF8Encoding]::new($false))

        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-File', $probePath,
            '-ManifestList', ($manifests -join ';'),
            '-OrchestratorManifest', $orchestratorManifest,
            '-WrapperPath', $wrapperPath,
            '-ManifestPath', $manifestPath,
            '-StateRoot', $stateRoot,
            '-UseForce', $Force.ToString().ToLowerInvariant()
        )
        $output = & (Get-Process -Id $PID).Path @arguments
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String)
        }
        $result = @($output | Select-Object -Last 1 | ConvertFrom-Json)

        $result | Should -HaveCount 1
        $result[0].ModulesPreserved | Should -BeTrue
        $result[0].CommandsPreserved | Should -BeTrue
        $result[0].StatusWorked | Should -BeTrue
        $result[0].RecordState | Should -Be 'incomplete'
    }
}
