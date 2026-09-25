BeforeAll {
    $script:repo = Split-Path $PSScriptRoot -Parent
    $script:entry = Join-Path $script:repo 'src\Agents\signoff-observer\Start-SignoffObserver.ps1'
    $script:python = if ($env:DEVPILOT_SIGNOFF_TEST_PYTHON) { $env:DEVPILOT_SIGNOFF_TEST_PYTHON } else { 'python' }
    Import-Module (Join-Path $script:repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    Import-Module (Join-Path $script:repo 'src\Agents\signoff-observer\ReportDelivery.psm1') -Force
    $script:private = Resolve-AgentTrustedRoot -Path (Join-Path $TestDrive 'private') -Kind durable-state -RepositoryRoot $script:repo -Create
    $script:collector = Join-Path $script:private 'collector.ps1'
    @'
param($ConfigFile, $RequestPath, $OutputPath, $LocalToolkitRoot)
$ErrorActionPreference = 'Stop'
$request = Get-Content $RequestPath -Raw | ConvertFrom-Json
$bundle = Get-Content (Join-Path $LocalToolkitRoot 'samples\signoff\complete.bundle.json') -Raw | ConvertFrom-Json
$now = [DateTime]::UtcNow.ToString('o')
$bundle.label = $null
$bundle.reconstruction.status = 'CURRENT_SNAPSHOT'
$bundle.provenance.cutoff = $now
$bundle.provenance.exportedAt = $now
$p = $bundle.provenance
$page = @{
    schemaVersion = 1; studyId = $request.studyId; captureId = $request.captureId
    page = @{ cursor = $null; nextCursor = $null; complete = $true }
    window = @{ startedAt = $request.startedAt; completedAt = $now }
    inventory = @(@{ familyId = $bundle.familyId; pullRequestId = $p.pullRequestId; targetRef = $p.targetRef
        state = 'ACTIVE'; isDraft = $false; sourceCommit = $p.sourceCommit; targetCommit = $p.targetCommit })
    snapshots = @(@{ bundle = $bundle; observation = @{ capturedAt = $now; state = 'ACTIVE'
        baselineDecision = 'NOT_APPROVED'; stable = $true; eligibilityReasons = @() } })
    outcomes = @(); gaps = @()
}
[IO.File]::WriteAllText($OutputPath, ($page | ConvertTo-Json -Depth 40))
'@ | Set-Content -LiteralPath $script:collector
    $script:collectorConfig = Join-Path $script:private 'collector.json'
    '{}' | Set-Content $script:collectorConfig
    function New-TestObserverConfig([string]$Name, [string]$Mode = 'collection-only') {
        $config = @{
            schemaVersion = 1; studyId = $Name; stateRoot = (Join-Path $script:private $Name)
            collector = @{ scriptPath = $script:collector; configPath = $script:collectorConfig
                scriptSha256 = (Get-FileHash $script:collector).Hash.ToLowerInvariant()
                configSha256 = (Get-FileHash $script:collectorConfig).Hash.ToLowerInvariant() }
            evaluation = @{ mode = $Mode; model = $null; fixturePath = $null; runtimePath = $null
                deadlineSeconds = 2; maxAttempts = 1; maxAiCredits = 30; dailyLimit = 2; studyLimit = 3; exploratory = $false }
            pollSeconds = 30; maxPages = 2; maxItems = 25
        }
        if ($Mode -eq 'offline') {
            $config.evaluation.model = 'fixture-v1'
            $config.evaluation.fixturePath = Join-Path $script:repo 'samples\signoff\responses.json'
        }
        $path = Join-Path $script:private "$Name.json"
        $config | ConvertTo-Json -Depth 10 | Set-Content $path
        return $path
    }
}

Describe 'Sign-off observer contained adapter and role ceiling' {
    It 'validates through a real subprocess using exported trust helpers' {
        $config = New-TestObserverConfig 'validation'
        $result = & pwsh -NoProfile -File $script:entry -ConfigFile $config -PythonPath $script:python -ValidateOnly
        $LASTEXITCODE | Should -Be 0
        ($result | ConvertFrom-Json).valid | Should -BeTrue
        Test-Path (Join-Path $script:private 'validation\observer.sqlite') | Should -BeFalse
    }

    It 'runs collection-only once without model admissions' -Skip:(-not $IsWindows) {
        $config = New-TestObserverConfig 'collect'
        & pwsh -NoProfile -File $script:entry -ConfigFile $config -PythonPath $script:python -Once -PreviewOnly
        $LASTEXITCODE | Should -Be 0
        $report = Get-Content (Join-Path $script:private 'collect\reports\latest.json') -Raw | ConvertFrom-Json
        $report.admissions | Should -Be 0
        $report.authorization | Should -Be 'NONE'
        $report.latest[0].status | Should -Be 'COLLECTION_ONLY'
    }

    It 'persists one offline prediction across actual worker restarts' -Skip:(-not $IsWindows) {
        $config = New-TestObserverConfig 'offline' 'offline'
        & pwsh -NoProfile -File $script:entry -ConfigFile $config -PythonPath $script:python -Once
        $LASTEXITCODE | Should -Be 0
        $reportPath = Join-Path $script:private 'offline\reports\latest.json'
        $before = Get-Content $reportPath -Raw | ConvertFrom-Json
        & pwsh -NoProfile -File $script:entry -ConfigFile $config -PythonPath $script:python -Once
        $LASTEXITCODE | Should -Be 0
        $after = Get-Content $reportPath -Raw | ConvertFrom-Json
        $after.admissions | Should -Be 1
        $after.latest[0].recommendation | Should -Be 'APPROVE'
        $after.deadline | Should -Be $before.deadline
        $after.livePolicyAgreement.eligible | Should -Be 0
    }

    It 'rejects cancellation explicitly under containment' -Skip:(-not $IsWindows) {
        $config = New-TestObserverConfig 'cancelled'
        $cancel = Join-Path $script:private 'cancel.txt'
        New-Item $cancel -ItemType File | Out-Null
        & pwsh -NoProfile -File $script:entry -ConfigFile $config -PythonPath $script:python -Once -CancelFile $cancel 2>$null
        $LASTEXITCODE | Should -Be 130
    }

    It 'returns nonzero and retains private diagnostics for a failed collector' -Skip:(-not $IsWindows) {
        $configPath = New-TestObserverConfig 'collector-failed'
        $failingScript = Join-Path $script:private 'failing-collector.ps1'
        '[Console]::Error.WriteLine("synthetic collector unavailable"); exit 42' | Set-Content $failingScript
        $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        $config.collector.scriptPath = $failingScript
        $config.collector.scriptSha256 = (Get-FileHash $failingScript).Hash.ToLowerInvariant()
        $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
        & pwsh -NoProfile -File $script:entry -ConfigFile $configPath -PythonPath $script:python -Once
        $LASTEXITCODE | Should -Be 2
        $root = Join-Path $script:private 'collector-failed'
        $report = Get-Content (Join-Path $root 'reports\latest.json') -Raw | ConvertFrom-Json
        $report.gaps.code | Should -Contain 'CAPTURE_FAILED'
        $report.gaps.code | Should -Contain 'INVENTORY_INCOMPLETE'
        $receipt = @(Get-ChildItem (Join-Path $root 'captures') -Filter collector.stderr.log -Recurse)
        $receipt.Count | Should -Be 1
        Get-Content $receipt.FullName -Raw | Should -Match 'synthetic collector unavailable'
        $events = Get-ChildItem (Join-Path $root 'logs\events\signoff-observer') -Filter '*.jsonl' |
            Get-Content | ConvertFrom-Json
        ($events | Where-Object eventType -eq 'observer.updated').data.collectionStatus | Should -Be 'incomplete'
    }

    It 'never grants observer mutations or manual delegation, including outside preview' {
        foreach ($preview in @($false, $true)) {
            $descriptor = Get-AgentHarnessCapabilityDescriptor -Role signoff-observer -PreviewOnly:$preview
            $descriptor.operationalTiers.base.Count | Should -Be 0
            $descriptor.allowedManualCapabilities.Count | Should -Be 0
            $descriptor.delegableDefaultOff.Count | Should -Be 0
            foreach ($deny in @('EnableApprovalVote', 'EnableAutoComplete', 'EnablePush', 'EnableTeamsNotifications', 'EnableTeamsPrReferenceWrites')) {
                $descriptor.absoluteDenies | Should -Contain $deny
            }
        }
        (Get-AgentHarnessCapabilityDescriptor -Role reviewer).operationalTiers.base | Should -Contain 'EnableFindingComments'
        (Get-AgentHarnessCapabilityDescriptor -Role review-handler).delegableDefaultOff | Should -Be 'EnableAutoComplete'
    }

    It 'rejects Golden/manual observer-only selection before config or process access' {
        $watch = Join-Path $script:repo 'tools\Watch-DevPilotAgents.ps1'
        { & $watch -Agent SignoffObserver -ObserverConfigFile missing -Golden } | Should -Throw '*does not accept -Golden*'
        { & $watch -Agent SignoffObserver -ObserverConfigFile missing -EnableManualReviewer } | Should -Throw '*does not accept*'
        { & $watch -Agent SignoffObserver -ObserverConfigFile missing -Operational } | Should -Throw '*does not accept*'
    }

    It 'uses separate study lease and contains owned children without broker registration' {
        $text = Get-Content $script:entry -Raw
        $text | Should -Match '-ContainDescendants'
        $text | Should -Not -Match 'Invoke-AgentMcpTool|Enter-AgentWorkLease|Set-AgentProvider'
        $watch = Get-Content (Join-Path $script:repo 'tools\Watch-DevPilotAgents.ps1') -Raw
        $watch | Should -Match "\[string\]\`$Agent = 'Both'"
        $watch | Should -Match "Role -ne 'signoff-observer'"
        $owner = Get-Content (Join-Path $script:repo 'tools\Watch-SignoffObserver.ps1') -Raw
        $owner | Should -Match 'Stop-AgentProcessContainment'
        $owner | Should -Match '-LaunchMode observe'
    }
}

Describe 'Separate WorkIQ report authorization and unknown-send quarantine' {
    BeforeEach {
        $script:prepared = @{
            config = @{ enabled = $true; privateOperatorDestination = $true; chatId = '19:operator@thread.v2'
                stateRoot = (Join-Path $script:private ([guid]::NewGuid().ToString('N'))) }
            eventKey = 'a' * 64; reportHash = 'b' * 64; summary = '<untrusted> & advisory'
        }
        Mock -ModuleName ReportDelivery Open-AgentMcpSession { @{ fake = $true } }
        Mock -ModuleName ReportDelivery Close-AgentMcpSession {}
        Mock -ModuleName ReportDelivery Invoke-AgentWorkIqTool { [pscustomobject]@{ id = 'message-id' } }
    }

    It 'defaults off and makes PreviewOnly terminal even with explicit authorization' {
        (Invoke-SignoffReportDelivery -Prepared $script:prepared -AgencyPath unused).status | Should -Be 'disabled'
        (Invoke-SignoffReportDelivery -Prepared $script:prepared -AgencyPath unused -EnableDelivery -PreviewOnly).status | Should -Be 'disabled'
        Should -Invoke -ModuleName ReportDelivery Open-AgentMcpSession -Times 0
    }

    It 'sends only escaped operator summary to the exact trusted destination once' {
        (Invoke-SignoffReportDelivery -Prepared $script:prepared -AgencyPath unused -EnableDelivery).status | Should -Be 'confirmed'
        (Invoke-SignoffReportDelivery -Prepared $script:prepared -AgencyPath unused -EnableDelivery).status | Should -Be 'confirmed'
        Should -Invoke -ModuleName ReportDelivery Invoke-AgentWorkIqTool -Times 1 -ParameterFilter {
            $Name -eq 'create_entity' -and $Arguments.parentUrl -eq '/chats/19:operator@thread.v2/messages' -and
            $Arguments.jsonBody.body.content -match '&lt;untrusted&gt; &amp;' -and $AllowedTools.Count -eq 1
        }
    }

    It 'quarantines a failed or unknown send and refuses automatic duplicate delivery' {
        Mock -ModuleName ReportDelivery Invoke-AgentWorkIqTool { throw 'Transport disconnected after send.' }
        { Invoke-SignoffReportDelivery -Prepared $script:prepared -AgencyPath unused -EnableDelivery } | Should -Throw '*Transport*'
        (Invoke-SignoffReportDelivery -Prepared $script:prepared -AgencyPath unused -EnableDelivery).status | Should -Be 'unknown'
        Should -Invoke -ModuleName ReportDelivery Invoke-AgentWorkIqTool -Times 1
    }

    It 'rejects destination path injection before opening WorkIQ' {
        $script:prepared.config.chatId = '../another/messages'
        { Invoke-SignoffReportDelivery -Prepared $script:prepared -AgencyPath unused -EnableDelivery } | Should -Throw '*destination*'
        Should -Invoke -ModuleName ReportDelivery Open-AgentMcpSession -Times 0
    }
}
