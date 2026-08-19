#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline suite for the typed shadow run coordinator: a real preparation to
    run-set-ready, restart at every transition, the child fault matrix, and the
    PowerShell rollback differential.

.DESCRIPTION
    Everything here runs offline. No model is launched, no slot is started, and
    nothing is written outside a temporary sandbox.

    The suite deliberately does NOT stub the corpus sealer or the qualification
    tools. The coordinator's entire claim is that it prepares real evidence
    without launching a model, and a suite built on stand-ins would prove only
    that the stand-ins behave.

    Faults are injected by replacing the child ADAPTER in the sandbox build,
    never by teaching the coordinator a test mode. A coordinator with a test mode
    is a coordinator whose tested path is not its shipping path.

.PARAMETER RepoRoot
    The toolkit under test. Defaults to this script's repository.

.PARAMETER KeepSandbox
    Leave the sandbox in place for inspection after the run.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$KeepSandbox
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Checks = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:PwshPath = (Get-Process -Id $PID).Path

function Assert-Coordinator {
    param([Parameter(Mandatory)][AllowNull()]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:Checks++
    if (-not $Condition) {
        [void]$script:Failures.Add($Message)
        Write-Host "  FAIL - $Message" -ForegroundColor Red
    }
}

function Get-CoordinatorState {
    param([Parameter(Mandatory)][string]$OutputRoot)
    $path = Join-Path $OutputRoot 'coordinator\state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 24)
}

function Invoke-Coordinator {
    <#
    .SYNOPSIS
        Runs the coordinator and returns its exit code with its console text.

    .DESCRIPTION
        The console text is captured only so a refusal can be read back in an
        assertion. The coordinator's contracts are files, and this suite reads
        them as files everywhere it checks behaviour.
    #>
    param(
        [Parameter(Mandatory)][string]$RequestPath,
        [string]$HaltAfter,
        [string]$Target
    )
    $argv = [System.Collections.Generic.List[string]]::new()
    [void]$argv.Add($script:CoordinatorDll)
    [void]$argv.Add('--request'); [void]$argv.Add($RequestPath)
    if ($HaltAfter) { [void]$argv.Add('--halt-after'); [void]$argv.Add($HaltAfter) }
    if ($Target) { [void]$argv.Add('--target'); [void]$argv.Add($Target) }
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & dotnet @argv 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function New-CoordinatorRequestVariant {
    <#
    .SYNOPSIS
        Writes a copy of the request with one section replaced, so a refusal can
        be provoked without rebuilding the sandbox.
    #>
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutate,
        [switch]$AsBom,
        [switch]$AsTruncated
    )
    $request = Get-Content -LiteralPath $BasePath -Raw | ConvertFrom-Json -Depth 24
    & $Mutate $request
    # The serializer's output and the string this function may then truncate are
    # kept apart: measuring the length of a raw command result is exactly the
    # flattening hazard the boundary rules exist to prevent.
    $json = ConvertTo-Json -InputObject $request -Depth 24 -Compress:$false
    $text = [string]$json
    if ($AsTruncated) { $text = $text.Substring(0, [Math]::Max(1, [int]($text.Length / 2))) }
    $path = Join-Path (Split-Path $BasePath -Parent) "request-$Name.json"
    $encoding = [System.Text.UTF8Encoding]::new([bool]$AsBom, $true)
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes($text)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

function Set-CoordinatorOutputRoot {
    <#
    .SYNOPSIS
        Points a request at a FRESH output root.

    .DESCRIPTION
        A fresh root per scenario is not tidiness: the coordinator refuses to
        reuse a root whose state disagrees with the request, and a failed
        preparation's root must never be recycled into a passing one.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$Root)
    $Request.output.root = $Root
}

function New-FaultyChildAdapter {
    <#
    .SYNOPSIS
        Replaces the sandbox build's child adapter with one that misbehaves in a
        named way, leaving the coordinator entirely unmodified.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolkitCopy,
        [Parameter(Mandatory)][ValidateSet('nonzero', 'hang', 'missing', 'malformed', 'bom',
            'truncated', 'partial', 'wrongCorrelation', 'stdoutPrologue', 'wrongStep')][string]$Fault
    )
    $path = Join-Path $ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $body = @'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$fault = '__FAULT__'
$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -Depth 24
$resultPath = [string]$request.resultPath
$correlationId = [string]$request.correlationId
$step = [string]$request.step
if ($fault -eq 'nonzero') { Write-Host 'child refuses'; exit 7 }
if ($fault -eq 'hang') { Start-Sleep -Seconds 600; exit 0 }
if ($fault -eq 'missing') { exit 0 }
$utf8 = [System.Text.UTF8Encoding]::new(($fault -eq 'bom'), $true)
if ($fault -eq 'wrongCorrelation') { $correlationId = 'shadow-not-this-run' }
if ($fault -eq 'wrongStep') { $step = 'someOtherStep' }
$payload = [ordered]@{
    contractVersion = 'devpilot.shadow-run-coordinator.child-result.v1'
    kind = 'shadow-run-coordinator-child-result'
    correlationId = $correlationId
    step = $step
    ok = $true
}
$text = ConvertTo-Json -InputObject $payload -Depth 8
if ($fault -eq 'malformed') { $text = '{ this is not json' }
if ($fault -eq 'truncated') { $text = $text.Substring(0, [int]($text.Length / 2)) }
if ($fault -eq 'stdoutPrologue') {
    Write-Output '{"contractVersion":"devpilot.shadow-run-coordinator.child-result.v1","ok":true}'
    Write-Output 'REVIEWER_QUALIFICATION_PRELAUNCH_V1 {}'
}
[void](New-Item -ItemType Directory -Force -Path (Split-Path $resultPath -Parent))
[System.IO.File]::WriteAllBytes($resultPath, ($utf8.GetPreamble() + $utf8.GetBytes($text)))
exit 0
'@
    Set-Content -LiteralPath $path -Encoding utf8NoBOM -Value ($body -replace '__FAULT__', $Fault)
}

function Restore-ChildAdapter {
    param([Parameter(Mandatory)][string]$ToolkitCopy, [Parameter(Mandatory)][string]$RepoRoot)
    Copy-Item -Force (Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1') `
        (Join-Path $ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1')
}

function Get-DescendantPwshCount {
    <#
    .SYNOPSIS
        Counts PowerShell processes this suite is responsible for, which is how an
        orphaned child would show up.
    .DESCRIPTION
        Scoped by the sandbox token rather than by start time. A start-time window
        counts every unrelated shell that happened to open on a shared machine,
        which turns an orphan check into a report on whatever else the host is
        doing; the sandbox token appears only in a command line this suite
        launched, so what it counts is only ever ours.
    #>
    param([Parameter(Mandatory)][string]$SandboxToken)
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and [string]$_.CommandLine -like "*$SandboxToken*" })
    return $processes.Count
}

# ---------------------------------------------------------------------------
# Build the coordinator offline, from the repository under test.
# ---------------------------------------------------------------------------
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("shadow-coordinator-" + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Force -Path $sandbox)
$sandboxToken = Split-Path $sandbox -Leaf
# The tree is photographed before anything runs. Asserting a clean tree instead
# would report the operator's own work in progress as damage this suite did,
# which is the one thing the check must never confuse.
$repoStatusBefore = (& git -C $RepoRoot status --porcelain -- 'src' 'docs' 'samples' 2>&1 | Out-String).Trim()

try {
    Write-Host '1/12 offline restore and build' -ForegroundColor Cyan
    $project = Join-Path $RepoRoot 'tools\ShadowRunCoordinator\ShadowRunCoordinator.csproj'
    Assert-Coordinator (Test-Path -LiteralPath $project -PathType Leaf) `
        'The shadow run coordinator project is missing.'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $offlineSource = Join-Path $sandbox 'nuget-empty'
    $packages = Join-Path $sandbox 'nuget-packages'
    [void](New-Item -ItemType Directory -Force -Path $offlineSource)
    & dotnet restore $project --source $offlineSource --packages $packages -p:NuGetAudit=false `
        --nologo --verbosity quiet | Out-Null
    Assert-Coordinator ($LASTEXITCODE -eq 0) 'The coordinator did not restore from an empty offline feed.'
    & dotnet build $project --configuration Release --no-restore --nologo --verbosity quiet | Out-Null
    Assert-Coordinator ($LASTEXITCODE -eq 0) 'The coordinator did not build offline.'
    $script:CoordinatorDll = Join-Path $RepoRoot 'tools\ShadowRunCoordinator\bin\Release\net10.0\ShadowRunCoordinator.dll'
    Assert-Coordinator (Test-Path -LiteralPath $script:CoordinatorDll -PathType Leaf) `
        'The coordinator assembly was not produced.'

    # -----------------------------------------------------------------------
    Write-Host '2/12 sandbox, sealed corpus and typed request' -ForegroundColor Cyan
    Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    . (Join-Path $RepoRoot 'src\Agents\reviewer\SourceTransport.ps1')
    . (Join-Path $RepoRoot 'src\Agents\reviewer\CorpusSeal.ps1')
    . (Join-Path $RepoRoot 'tools\CorpusSealFixture.ps1')
    . (Join-Path $RepoRoot 'tools\ShadowCoordinatorFixture.ps1')

    $fixture = New-ShadowCoordinatorFixture -Sandbox (Join-Path $sandbox 'fixture') -ToolkitRoot $RepoRoot
    Assert-Coordinator (Test-Path -LiteralPath $fixture.RequestPath -PathType Leaf) `
        'The fixture did not write a coordinator request.'
    # The prompt binding is computed in PowerShell here and in C# inside the
    # coordinator. Agreement is a cross-implementation canonicalization check,
    # and a disagreement would surface as a refusal on the very first transition.
    Assert-Coordinator ($fixture.Request.digests.promptSha256 -cmatch '^[0-9a-f]{64}$') `
        'The request does not bind a prompt-asset digest.'

    # -----------------------------------------------------------------------
    Write-Host '3/12 restart at every transition' -ForegroundColor Cyan
    $states = @('requestValidated', 'corpusValidated', 'recipePlanned', 'snapshotValidateOnly',
        'snapshotSealed', 'snapshotVerified', 'runSetDeclared', 'runSetVerified')
    $expectedSequence = 0
    foreach ($state in $states) {
        $expectedSequence++
        $halted = Invoke-Coordinator -RequestPath $fixture.RequestPath -HaltAfter $state
        Assert-Coordinator ($halted.ExitCode -eq 9) `
            "Halting after '$state' did not report a deliberate halt (exit $($halted.ExitCode))."
        $durable = Get-CoordinatorState -OutputRoot $fixture.OutputRoot
        Assert-Coordinator ($durable -and $durable.state -ceq $state) `
            "The durable state after halting at '$state' is '$(if ($durable) { $durable.state } else { 'none' })'."
        Assert-Coordinator ($durable -and [int]$durable.sequence -eq $expectedSequence) `
            "The sequence after '$state' is $(if ($durable) { $durable.sequence } else { 'none' }), not $expectedSequence."

        # Resuming to the SAME state must do nothing at all: no new sequence, no
        # second child launch. This is the property that makes a kill safe.
        $again = Invoke-Coordinator -RequestPath $fixture.RequestPath -Target $state
        Assert-Coordinator ($again.ExitCode -eq 0) `
            "Resuming to an already-reached '$state' failed (exit $($again.ExitCode))."
        Assert-Coordinator ($again.Output -match "skip $state") `
            "Resuming to an already-reached '$state' did not report it as already recorded."
        $repeat = Get-CoordinatorState -OutputRoot $fixture.OutputRoot
        Assert-Coordinator ([int]$repeat.sequence -eq $expectedSequence) `
            "Resuming to an already-reached '$state' advanced the sequence to $($repeat.sequence)."
    }

    Write-Host '4/12 preparation reaches run-set-ready' -ForegroundColor Cyan
    $final = Invoke-Coordinator -RequestPath $fixture.RequestPath
    Assert-Coordinator ($final.ExitCode -eq 0) "The preparation did not reach run-set-ready (exit $($final.ExitCode)): $($final.Output)"
    $durable = Get-CoordinatorState -OutputRoot $fixture.OutputRoot
    Assert-Coordinator ($durable.state -ceq 'runSetReady' -and [int]$durable.sequence -eq 9) `
        "The durable state is '$($durable.state)' at sequence $($durable.sequence)."
    Assert-Coordinator (@($durable.transitions).Count -eq 9) `
        "The state records $(@($durable.transitions).Count) transitions rather than nine."

    # A completed preparation replayed is a no-op, including the child that
    # cannot be run twice: a second declaration into the same qualification root
    # is refused by the qualification tool itself.
    $replay = Invoke-Coordinator -RequestPath $fixture.RequestPath
    Assert-Coordinator ($replay.ExitCode -eq 0) 'Replaying a completed preparation failed.'
    $afterReplay = Get-CoordinatorState -OutputRoot $fixture.OutputRoot
    Assert-Coordinator ([int]$afterReplay.sequence -eq 9) `
        "Replaying a completed preparation advanced the sequence to $($afterReplay.sequence)."

    # -----------------------------------------------------------------------
    Write-Host '5/12 audit indexes all twelve stage artifacts' -ForegroundColor Cyan
    $auditPath = Join-Path $fixture.OutputRoot 'coordinator\audit.json'
    Assert-Coordinator (Test-Path -LiteralPath $auditPath -PathType Leaf) 'The coordinator wrote no audit.'
    $audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json -Depth 32
    Assert-Coordinator ([int]$audit.modelInvocationCount -eq 0 -and [int]$audit.slotLaunchCount -eq 0) `
        'The audit does not record a preparation that launched nothing.'
    $planned = $audit.stages.recipePlanned
    Assert-Coordinator ([int]$planned.publishedCount -eq 12) `
        "The preparation published $($planned.publishedCount) stage artifacts rather than twelve."
    Assert-Coordinator ([int]$planned.rereadCount -eq 12) `
        "The coordinator re-read $($planned.rereadCount) stage artifacts rather than twelve."
    Assert-Coordinator ([int]$planned.boundaryCount -eq 12) `
        "The producer-contract schema declares $($planned.boundaryCount) boundaries rather than twelve."
    $stages = @(@($planned.artifacts) | ForEach-Object { [string]$_.stage })
    Assert-Coordinator (@($stages | Sort-Object -Unique).Count -eq 12) `
        'The audit does not index twelve distinct stages.'
    foreach ($artifact in @($planned.artifacts)) {
        Assert-Coordinator ([string]$artifact.sha256 -cmatch '^[0-9a-f]{64}$') `
            "Stage artifact '$($artifact.name)' is indexed without a digest."
        Assert-Coordinator ([int]$artifact.envelopeVersion -eq 1) `
            "Stage artifact '$($artifact.name)' is indexed at envelope version $($artifact.envelopeVersion)."
    }
    Assert-Coordinator ([int]$audit.stages.runSetReady.slotAttemptCount -eq 0) `
        'The preparation observed a slot attempt.'

    # -----------------------------------------------------------------------
    Write-Host '6/12 rollback differential against the PowerShell path' -ForegroundColor Cyan
    # The same preparation, driven entirely by the existing PowerShell entry
    # point. Byte-identical artifacts are what makes the default rollback real
    # rather than declared: the coordinator changes who calls, not what happens.
    $rollbackRoot = Join-Path $sandbox 'rollback'
    [void](New-Item -ItemType Directory -Force -Path $rollbackRoot)
    . (Join-Path $RepoRoot 'src\Agents\reviewer\ShadowPreparation.ps1')
    # The same changed paths the coordinator plans from its request. Derived here
    # the same way rather than read back from the coordinator, so a change to
    # either side shows up as a differential failure instead of being absorbed.
    $preparedPaths = @(
        "/prepared/$($fixture.Identity.PullRequestId)/iteration-$($fixture.Identity.IterationId)/source.ps1",
        "/prepared/$($fixture.Identity.PullRequestId)/iteration-$($fixture.Identity.IterationId)/target.ps1"
    )
    $rollback = Invoke-ReviewerShadowPreparation -Directory $rollbackRoot -ChangedPath $preparedPaths
    Assert-Coordinator ([int]$rollback.PublishedCount -eq 12) `
        "The PowerShell path published $($rollback.PublishedCount) artifacts rather than twelve."
    $coordinatorArtifacts = @(Get-ChildItem -LiteralPath (Join-Path $fixture.OutputRoot 'stage-artifacts') `
            -Filter '*.stage.json' -File | Sort-Object -Property Name -CaseSensitive)
    $rollbackArtifacts = @(Get-ChildItem -LiteralPath $rollbackRoot -Filter '*.stage.json' -File |
            Sort-Object -Property Name -CaseSensitive)
    Assert-Coordinator ($coordinatorArtifacts.Count -eq $rollbackArtifacts.Count) `
        "The two paths published $($coordinatorArtifacts.Count) and $($rollbackArtifacts.Count) artifacts."
    for ($index = 0; $index -lt [Math]::Min($coordinatorArtifacts.Count, $rollbackArtifacts.Count); $index++) {
        $left = $coordinatorArtifacts[$index]
        $right = $rollbackArtifacts[$index]
        Assert-Coordinator ($left.Name -ceq $right.Name) `
            "Artifact $index is named '$($left.Name)' on the coordinator path and '$($right.Name)' on the PowerShell path."
        $leftHash = (Get-FileHash -LiteralPath $left.FullName -Algorithm SHA256).Hash
        $rightHash = (Get-FileHash -LiteralPath $right.FullName -Algorithm SHA256).Hash
        Assert-Coordinator ($leftHash -ceq $rightHash) `
            "Artifact '$($left.Name)' differs between the coordinator path and the PowerShell rollback path."
    }

    # -----------------------------------------------------------------------
    Write-Host '7/12 request boundary: unknown, missing, scalar, null, BOM, truncated' -ForegroundColor Cyan
    # Built through a list rather than an @(...) literal: the mutators set fields
    # to $null on purpose, and inside an array expression that reads as an array
    # that can carry a null element. It cannot -- the nulls are inside script
    # blocks -- but saying so in the shape of the code is better than arguing.
    $variants = [Collections.Generic.List[hashtable]]::new()
    [void]$variants.Add(@{ Name = 'unknown'; Mutate = { param($r) $r | Add-Member -NotePropertyName 'unexpected' -NotePropertyValue 'x' }; Match = 'unexpected' })
    [void]$variants.Add(@{ Name = 'unknown-nested'; Mutate = { param($r) $r.subject | Add-Member -NotePropertyName 'extra' -NotePropertyValue 1 }; Match = 'extra' })
    [void]$variants.Add(@{ Name = 'missing'; Mutate = { param($r) $r.PSObject.Properties.Remove('corpus') }; Match = 'corpus' })
    [void]$variants.Add(@{ Name = 'scalar-section'; Mutate = { param($r) $r.corpus = 'not-an-object' }; Match = 'corpus' })
    [void]$variants.Add(@{ Name = 'null-section'; Mutate = { param($r) $r.corpus = $null }; Match = 'corpus' })
    [void]$variants.Add(@{ Name = 'scalar-int'; Mutate = { param($r) $r.subject.pullRequestId = 'not-a-number' }; Match = 'pullRequestId' })
    [void]$variants.Add(@{ Name = 'null-string'; Mutate = { param($r) $r.qualification.operatorAlias = $null }; Match = 'operatorAlias' })
    [void]$variants.Add(@{ Name = 'short-hex'; Mutate = { param($r) $r.toolkit.head = 'abc' }; Match = 'head' })
    [void]$variants.Add(@{ Name = 'upper-hex'; Mutate = { param($r) $r.digests.configSha256 = ($r.digests.configSha256).ToUpperInvariant() }; Match = 'configSha256' })
    [void]$variants.Add(@{ Name = 'wrong-contract'; Mutate = { param($r) $r.contractVersion = 'devpilot.shadow-run-coordinator.request.v2' }; Match = 'contractVersion' })
    [void]$variants.Add(@{ Name = 'wrong-kind'; Mutate = { param($r) $r.kind = 'something-else' }; Match = 'kind' })
    [void]$variants.Add(@{ Name = 'run-count-low'; Mutate = { param($r) $r.qualification.plannedRunCount = 1 }; Match = 'plannedRunCount' })
    [void]$variants.Add(@{ Name = 'run-count-high'; Mutate = { param($r) $r.qualification.plannedRunCount = 17 }; Match = 'plannedRunCount' })
    [void]$variants.Add(@{ Name = 'bad-correlation'; Mutate = { param($r) $r.correlationId = 'has spaces' }; Match = 'correlationId' })
    foreach ($variant in $variants) {
        $path = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name $variant.Name -Mutate $variant.Mutate
        $result = Invoke-Coordinator -RequestPath $path
        Assert-Coordinator ($result.ExitCode -eq 2) `
            "The '$($variant.Name)' request was not refused as a contract failure (exit $($result.ExitCode))."
        Assert-Coordinator ($result.Output -match [regex]::Escape($variant.Match)) `
            "The '$($variant.Name)' refusal does not name '$($variant.Match)'."
    }
    $bomPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'bom' `
        -Mutate { param($r) } -AsBom
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $bomPath).ExitCode -eq 2) `
        'A request carrying a byte-order mark was not refused.'
    $truncatedPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'truncated' `
        -Mutate { param($r) } -AsTruncated
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $truncatedPath).ExitCode -eq 2) `
        'A truncated request was not refused.'
    $emptyPath = Join-Path (Split-Path $fixture.RequestPath -Parent) 'request-empty.json'
    [System.IO.File]::WriteAllBytes($emptyPath, [byte[]]::new(0))
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $emptyPath).ExitCode -eq 2) `
        'An empty request file was not refused.'
    $arrayPath = Join-Path (Split-Path $fixture.RequestPath -Parent) 'request-array.json'
    Set-Content -LiteralPath $arrayPath -Encoding utf8NoBOM -Value '[]'
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $arrayPath).ExitCode -eq 2) `
        'A request that is an array rather than an object was not refused.'
    Assert-Coordinator ((Invoke-Coordinator -RequestPath (Join-Path $sandbox 'no-such-request.json')).ExitCode -eq 2) `
        'A missing request file was not refused.'

    # -----------------------------------------------------------------------
    Write-Host '8/12 stale head, stale identity and tampered state' -ForegroundColor Cyan
    $staleHeadPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-head' -Mutate {
        param($r)
        $r.toolkit.head = ('f' * 40)
        Set-CoordinatorOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-head')
    }
    $staleHead = Invoke-Coordinator -RequestPath $staleHeadPath
    Assert-Coordinator ($staleHead.ExitCode -eq 2 -and $staleHead.Output -match 'head') `
        'A request binding a head the build is not at was accepted.'

    $staleDigestPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-digest' -Mutate {
        param($r)
        $r.digests.schemaSha256 = ('1' * 64)
        Set-CoordinatorOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-digest')
    }
    $staleDigest = Invoke-Coordinator -RequestPath $staleDigestPath
    Assert-Coordinator ($staleDigest.ExitCode -eq 2 -and $staleDigest.Output -match 'schema') `
        'A request binding a stale schema digest was accepted.'

    $staleCorpusPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-corpus' -Mutate {
        param($r)
        $r.corpus.indexSha256 = ('2' * 64)
        Set-CoordinatorOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-corpus')
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $staleCorpusPath).ExitCode -ne 0) `
        'A request binding a corpus index digest the corpus does not have was accepted.'

    # A state file edited on disk must not be resumed from.
    $tamperRoot = Join-Path $sandbox 'out-tamper'
    $tamperPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'tamper' -Mutate {
        param($r) Set-CoordinatorOutputRoot -Request $r -Root $tamperRoot
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $tamperPath -HaltAfter 'requestValidated').ExitCode -eq 9) `
        'The tamper scenario did not reach its first halt.'
    $statePath = Join-Path $tamperRoot 'coordinator\state.json'
    $stateText = Get-Content -LiteralPath $statePath -Raw
    Set-Content -LiteralPath $statePath -Encoding utf8NoBOM `
        -Value ($stateText -replace '"sequence":\s*1', '"sequence": 5')
    $tampered = Invoke-Coordinator -RequestPath $tamperPath
    Assert-Coordinator ($tampered.ExitCode -eq 2) `
        "An edited state file was resumed from (exit $($tampered.ExitCode))."

    # A state file belonging to another correlation must not be adopted.
    $foreignRoot = Join-Path $sandbox 'out-foreign'
    $foreignPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'foreign' -Mutate {
        param($r) Set-CoordinatorOutputRoot -Request $r -Root $foreignRoot
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $foreignPath -HaltAfter 'requestValidated').ExitCode -eq 9) `
        'The foreign-correlation scenario did not reach its first halt.'
    $foreignRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'foreign-second' -Mutate {
        param($r)
        Set-CoordinatorOutputRoot -Request $r -Root $foreignRoot
        $r.correlationId = 'shadow-a-different-run'
    }
    $foreign = Invoke-Coordinator -RequestPath $foreignRequest
    Assert-Coordinator ($foreign.ExitCode -eq 2) `
        "A state file from another correlation was adopted (exit $($foreign.ExitCode))."

    # -----------------------------------------------------------------------
    Write-Host '9/12 single-run lease' -ForegroundColor Cyan
    $leaseRoot = Join-Path $sandbox 'out-lease'
    $leasePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'lease' -Mutate {
        param($r) Set-CoordinatorOutputRoot -Request $r -Root $leaseRoot
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $leasePath -HaltAfter 'requestValidated').ExitCode -eq 9) `
        'The lease scenario did not reach its first halt.'
    # A lease held by a process that is demonstrably alive - this one - must stop
    # a second coordinator. Liveness is decided from the recorded identity, never
    # from what a process is running.
    $self = Get-Process -Id $PID
    $leaseFile = Join-Path $leaseRoot 'coordinator\run.lease'
    $leaseRecord = [ordered]@{
        contractVersion = 'devpilot.shadow-run-coordinator.lease.v1'
        correlationId = $fixture.CorrelationId
        processId = $PID
        processStartedAtUtc = $self.StartTime.ToUniversalTime().ToString('o')
        acquiredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Set-Content -LiteralPath $leaseFile -Encoding utf8NoBOM `
        -Value (ConvertTo-Json -InputObject $leaseRecord -Depth 6 -Compress:$false)
    $conflict = Invoke-Coordinator -RequestPath $leasePath
    Assert-Coordinator ($conflict.ExitCode -eq 3) `
        "A coordinator ran against a root leased by a live process (exit $($conflict.ExitCode))."

    # The same lease naming a process identity that cannot be live is abandoned
    # residue, and must NOT wedge the root forever.
    $leaseRecord.processStartedAtUtc = ([DateTime]::UtcNow.AddDays(-3650)).ToString('o')
    Set-Content -LiteralPath $leaseFile -Encoding utf8NoBOM `
        -Value (ConvertTo-Json -InputObject $leaseRecord -Depth 6 -Compress:$false)
    $recovered = Invoke-Coordinator -RequestPath $leasePath -HaltAfter 'corpusValidated'
    Assert-Coordinator ($recovered.ExitCode -eq 9) `
        "An abandoned lease wedged the output root (exit $($recovered.ExitCode))."

    # -----------------------------------------------------------------------
    Write-Host '10/12 child fault matrix' -ForegroundColor Cyan
    $faults = @(
        @{ Name = 'nonzero'; Expect = 4 },
        @{ Name = 'missing'; Expect = 4 },
        @{ Name = 'malformed'; Expect = 4 },
        @{ Name = 'bom'; Expect = 4 },
        @{ Name = 'truncated'; Expect = 4 },
        @{ Name = 'partial'; Expect = 4 },
        @{ Name = 'wrongCorrelation'; Expect = 4 },
        @{ Name = 'wrongStep'; Expect = 4 }
    )
    # GetNewClosure captures variables, not function definitions, so the function
    # is captured explicitly and invoked through the reference. Calling it by name
    # from inside the closure would resolve against whatever scope runs it later.
    $setOutputRoot = ${function:Set-CoordinatorOutputRoot}
    foreach ($fault in $faults) {
        New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault $fault.Name
        $faultRoot = Join-Path $sandbox "out-fault-$($fault.Name)"
        $faultRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "fault-$($fault.Name)" -Mutate {
            param($r) & $setOutputRoot -Request $r -Root $faultRoot
        }.GetNewClosure()
        $result = Invoke-Coordinator -RequestPath $faultRequest
        Assert-Coordinator ($result.ExitCode -eq $fault.Expect) `
            "The '$($fault.Name)' child fault produced exit $($result.ExitCode) rather than $($fault.Expect)."
        $durable = Get-CoordinatorState -OutputRoot $faultRoot
        # The first child is invoked by the recipePlanned transition, so the two
        # transitions before it legitimately commit first. What must never happen
        # is a state at or past the transition whose child failed: that would mean
        # a partial child result was accepted as evidence.
        $reached = if ($durable) { [string]$durable.state } else { 'none' }
        Assert-Coordinator ($reached -cin @('none', 'requestValidated', 'corpusValidated')) `
            "The '$($fault.Name)' child fault left the state at '$reached'."
    }

    # A child that writes a valid result AND chatters contract-shaped text on
    # standard output must still succeed: stdout is not a contract surface.
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'stdoutPrologue'
    $chatterRoot = Join-Path $sandbox 'out-fault-stdout'
    $chatterRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'fault-stdout' -Mutate {
        param($r) Set-CoordinatorOutputRoot -Request $r -Root $chatterRoot
    }
    $chatter = Invoke-Coordinator -RequestPath $chatterRequest
    # The stand-in answers no expected field, so it fails as a partial result -
    # NOT by having its standard output believed.
    Assert-Coordinator ($chatter.ExitCode -eq 4 -and $chatter.Output -notmatch 'REVIEWER_QUALIFICATION_PRELAUNCH_V1') `
        'A child result was taken from standard output rather than from the result file.'

    # A hanging child must be bounded, killed with its tree, and leave nothing.
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'hang'
    $hangRoot = Join-Path $sandbox 'out-fault-hang'
    $hangRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'fault-hang' -Mutate {
        param($r)
        Set-CoordinatorOutputRoot -Request $r -Root $hangRoot
        $r.children.timeoutSeconds = 5
    }
    $before = Get-DescendantPwshCount -SandboxToken $sandboxToken
    $hang = Invoke-Coordinator -RequestPath $hangRequest
    Assert-Coordinator ($hang.ExitCode -eq 4) `
        "A hanging child was not bounded by the configured timeout (exit $($hang.ExitCode))."
    Start-Sleep -Seconds 2
    $after = Get-DescendantPwshCount -SandboxToken $sandboxToken
    Assert-Coordinator ($after -le $before) `
        "A bounded child left $($after - $before) process(es) behind."
    Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot

    # -----------------------------------------------------------------------
    Write-Host '11/12 killed mid-transition' -ForegroundColor Cyan
    # A real external kill, not a cooperative halt: the coordinator is stopped
    # while a child is running, and the root must still converge.
    $killRoot = Join-Path $sandbox 'out-kill'
    $killRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'kill' -Mutate {
        param($r) Set-CoordinatorOutputRoot -Request $r -Root $killRoot
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'dotnet'
    foreach ($argument in @($script:CoordinatorDll, '--request', $killRequest)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $victim = [Diagnostics.Process]::Start($startInfo)
    Start-Sleep -Seconds 6
    if (-not $victim.HasExited) { $victim.Kill($true) }
    [void]$victim.WaitForExit(30000)
    $afterKill = Get-CoordinatorState -OutputRoot $killRoot
    Assert-Coordinator ($null -eq $afterKill -or $afterKill.PSObject.Properties['state']) `
        'A killed coordinator left a state file that cannot be read.'
    $resumed = Invoke-Coordinator -RequestPath $killRequest
    Assert-Coordinator ($resumed.ExitCode -eq 0) `
        "A killed preparation did not resume to run-set-ready (exit $($resumed.ExitCode)): $($resumed.Output)"
    $resumedState = Get-CoordinatorState -OutputRoot $killRoot
    Assert-Coordinator ($resumedState.state -ceq 'runSetReady' -and [int]$resumedState.sequence -eq 9) `
        "The resumed preparation ended at '$($resumedState.state)' sequence $($resumedState.sequence)."
    $killAudit = Get-Content -LiteralPath (Join-Path $killRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 32
    Assert-Coordinator ([int]$killAudit.stages.runSetReady.slotAttemptCount -eq 0) `
        'The resumed preparation observed a slot attempt.'
    $declared = @(Get-ChildItem -LiteralPath (Join-Path $killRoot 'qualification\runset') -Filter 'runset-*.json' `
            -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.sig' })
    Assert-Coordinator ($declared.Count -eq 1) `
        "The resumed preparation left $($declared.Count) declared run sets rather than one."

    # -----------------------------------------------------------------------
    Write-Host '12/12 no orphans, no external writes' -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    $orphans = Get-DescendantPwshCount -SandboxToken $sandboxToken
    Assert-Coordinator ($orphans -eq 0) "The suite left $orphans PowerShell process(es) running."
    $repoStatusAfter = (& git -C $RepoRoot status --porcelain -- 'src' 'docs' 'samples' 2>&1 | Out-String).Trim()
    Assert-Coordinator ($repoStatusAfter -ceq $repoStatusBefore) `
        "The suite modified tracked toolkit content. Before:`n$repoStatusBefore`nAfter:`n$repoStatusAfter"
}
finally {
    if ($KeepSandbox) { Write-Host "sandbox retained at $sandbox" -ForegroundColor DarkGray }
    else { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($script:Failures.Count -gt 0) {
    Write-Host "Shadow run coordinator: $($script:Failures.Count) of $($script:Checks) check(s) failed." -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Shadow run coordinator: $($script:Checks) check(s) passed." -ForegroundColor Green
exit 0
