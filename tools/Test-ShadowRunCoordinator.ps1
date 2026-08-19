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

function Invoke-CoordinatorRaw {
    <#
    .SYNOPSIS
        Runs the coordinator with arbitrary arguments, for the argument faults a
        well-formed request path cannot reach.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $argv = [System.Collections.Generic.List[string]]::new()
    [void]$argv.Add($script:CoordinatorDll)
    foreach ($argument in $Arguments) { [void]$argv.Add($argument) }
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & dotnet @argv 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function Get-ExchangeResult {
    <#
    .SYNOPSIS
        Reads a child result out of a run's exchange directory by step name.

    .DESCRIPTION
        Each scenario mints its own correlation id, so the file stem is not
        knowable from the fixture; the step suffix is.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Step)
    $found = @(Get-ChildItem -LiteralPath (Join-Path $Root 'coordinator\exchange') -File -Filter "*-$Step.result.json")
    if ($found.Count -ne 1) {
        throw "The exchange directory under '$Root' holds $($found.Count) results for step '$Step'; expected one."
    }
    return (Get-Content -LiteralPath $found[0].FullName -Raw | ConvertFrom-Json -Depth 16)
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
            'truncated', 'partial', 'wrongCorrelation', 'stdoutPrologue', 'wrongStep',
            'strayDirectory', 'wrongRequestDigest', 'publishThenDie', 'mutateResult')][string]$Fault,
        [string]$StrayDirectory = '',
        [string]$RealAdapter = '',
        [string]$DieOnStep = 'corpusSeal',
        [string]$MutateStep = '',
        [string]$MutateProperty = '',
        [string]$MutateValue = ''
    )
    $path = Join-Path $ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $body = @'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$fault = '__FAULT__'
$stray = '__STRAY__'
$real = '__REAL__'
$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -Depth 24
$resultPath = [string]$request.resultPath
$correlationId = [string]$request.correlationId
$step = [string]$request.step
$digest = [string]$request.childRequestSha256
if ($fault -eq 'mutateResult') {
    # Everything the reviewed child would do, then a single field of the result
    # rewritten. What the coordinator sees is a genuine, correlated, correctly
    # digested result that disagrees with its own record about one fact.
    & $real -RequestPath $RequestPath
    if ($step -eq '__MUTATESTEP__') {
        $document = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 24
        $document.'__MUTATEPROPERTY__' = '__MUTATEVALUE__'
        $rewritten = (ConvertTo-Json -InputObject $document -Depth 24 -Compress:$false)
        $encoder = [System.Text.UTF8Encoding]::new($false, $true)
        [System.IO.File]::WriteAllBytes($resultPath, $encoder.GetBytes($rewritten))
    }
    exit 0
}
if ($fault -eq 'publishThenDie') {
    # Do the real work, including the durable side effect, then vanish exactly
    # the way a killed child does: no result for the coordinator to commit.
    & $real -RequestPath $RequestPath
    if ($step -eq '__DIESTEP__') {
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
        exit 9
    }
    # The real adapter throws on failure, so reaching here means it succeeded and
    # has already written the result the coordinator will read.
    exit 0
}
if ($fault -eq 'nonzero') { Write-Host 'child refuses'; exit 7 }
if ($fault -eq 'hang') { Start-Sleep -Seconds 600; exit 0 }
if ($fault -eq 'missing') { exit 0 }
$utf8 = [System.Text.UTF8Encoding]::new(($fault -eq 'bom'), $true)
if ($fault -eq 'wrongCorrelation') { $correlationId = 'shadow-not-this-run' }
if ($fault -eq 'wrongStep') { $step = 'someOtherStep' }
if ($fault -eq 'wrongRequestDigest') { $digest = ('0' * 64) }
$payload = [ordered]@{
    contractVersion = 'devpilot.shadow-run-coordinator.child-result.v1'
    kind = 'shadow-run-coordinator-child-result'
    correlationId = $correlationId
    step = $step
    childRequestSha256 = $digest
    ok = $true
}
if ($fault -eq 'strayDirectory') {
    # Twelve well-formed artifacts, published somewhere the request never named.
    [void](New-Item -ItemType Directory -Force -Path $stray)
    $payload['artifactDirectory'] = $stray
    $payload['publishedCount'] = 12
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
    $rendered = ((((($body -replace '__FAULT__', $Fault) -replace '__STRAY__', ($StrayDirectory -replace '\\', '\\')) `
                    -replace '__REAL__', ($RealAdapter -replace '\\', '\\')) -replace '__DIESTEP__', $DieOnStep) `
            -replace '__MUTATESTEP__', $MutateStep) -replace '__MUTATEPROPERTY__', $MutateProperty
    $rendered = $rendered -replace '__MUTATEVALUE__', $MutateValue
    Set-Content -LiteralPath $path -Encoding utf8NoBOM -Value $rendered
}

function New-SlotStubAdapter {
    <#
    .SYNOPSIS
        Replaces the sandbox build's child adapter with one that performs every
        PREPARATION step for real and synthesizes the three slot steps.

    .DESCRIPTION
        The one place this suite stands something in, and the reason is that the
        alternative is not a cheaper test but a different test: a real slot runs
        the reviewer, and the reviewer calls models. What is under test here is
        the typed lifecycle - authorization, durable identity, supervision,
        restart, and the refusals - and every one of those is C#'s own. So the
        preparation steps still run through the reviewed adapter, the run set is
        still really declared and really signed, the launch token is still the
        published one, and only the slot's own execution is stood in for.

        The stub's plan is deliberately NOT a real qualification plan. It reports
        a digest of its own, so a scenario that tampered with the plan is a
        scenario the coordinator refuses on its own committed digest rather than
        on anything the qualification tools would have said.

        What the stub never does is invoke a model, and the suite asserts that
        rather than trusting this comment: the verify step reports a census of
        attempt records, and the audit is checked for a zero model count.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolkitCopy,
        [Parameter(Mandatory)][string]$RealAdapter,
        [Parameter(Mandatory)][ValidateSet('complete', 'failed', 'timedOut', 'noTerminal', 'hang',
            'nonzeroNoTerminal', 'wrongSlot', 'wrongSetId', 'contradictoryTimeout',
            'writableTerminal', 'secondAttempt')][string]$Mode,
        [int]$SlotTimeoutSeconds = 900,
        [int]$ProgressTimeoutSeconds = 0,
        [int]$PerCallTimeoutSeconds = 300,
        # How long the stub's slot stays alive after publishing its attempt
        # record. A kill-mid-slot test needs a child that is genuinely still
        # running when its coordinator dies, and a slot that finishes in
        # milliseconds would make that a race the suite usually loses.
        [int]$RunDelaySeconds = 0
    )
    $path = Join-Path $ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $body = @'
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$mode = '__MODE__'
$real = '__REAL__'
$slotTimeoutSeconds = __SLOTTIMEOUT__
$progressTimeoutSeconds = __PROGRESSTIMEOUT__
$perCallTimeoutSeconds = __PERCALLTIMEOUT__
$runDelaySeconds = __RUNDELAY__

$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -Depth 24
$step = [string]$request.step
$resultPath = [string]$request.resultPath
$correlationId = [string]$request.correlationId
$childRequestSha256 = [string]$request.childRequestSha256

# Preparation is not stood in for. Only the slot is.
if (-not $step.StartsWith('slot')) {
    $global:LASTEXITCODE = 0
    & $real -RequestPath $RequestPath
    exit ([int]$global:LASTEXITCODE)
}

function Write-StubResult {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Fields)
    $payload = [ordered]@{
        contractVersion = 'devpilot.shadow-run-coordinator.child-result.v1'
        kind = 'shadow-run-coordinator-child-result'
        correlationId = $correlationId
        step = $step
        childRequestSha256 = $childRequestSha256
        ok = $true
    }
    foreach ($key in @($Fields.Keys)) { $payload[[string]$key] = $Fields[$key] }
    $text = ConvertTo-Json -InputObject $payload -Depth 12 -Compress:$false
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $resultPath -Parent))
    [IO.File]::WriteAllBytes($resultPath, ([Text.UTF8Encoding]::new($false, $true)).GetBytes($text))
}

function Get-StubSha256Text {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = ([Text.UTF8Encoding]::new($false, $true)).GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$qualificationRoot = [string]$request.qualificationRoot
$stubRoot = Join-Path $qualificationRoot 'stub'
$stateDir = Join-Path $stubRoot 'slot1-state'
$attemptPath = Join-Path $stubRoot 'slot1-attempt.json'
$terminalPath = Join-Path $stubRoot 'slot1-terminal.json'

# The run set identity is taken from the coordinator's own committed
# verification result rather than re-derived, because re-deriving it means
# re-verifying a signature this stub has no business re-implementing.
$exchange = Split-Path $resultPath -Parent
$verifyResult = Join-Path $exchange "$correlationId-runSetVerify.result.json"
if (-not (Test-Path -LiteralPath $verifyResult -PathType Leaf)) {
    throw "The stub adapter found no committed run-set verification to take a set identity from."
}
$setId = [string]((Get-Content -LiteralPath $verifyResult -Raw | ConvertFrom-Json -Depth 16).setId)

# Hashed from the PUBLISHED token, not from the one the request presents, so a
# request carrying the wrong token still fails the coordinator's comparison.
$publishedToken = Join-Path (Join-Path $qualificationRoot 'runset') 'launch-authorization.token'
$launchHash = Get-StubSha256Text -Text (([IO.File]::ReadAllText($publishedToken)).Trim())
$planDigest = Get-StubSha256Text -Text "stub-plan|$setId|$mode"

if ($step -eq 'slotPlan' -or $step -eq 'slotPrelaunch') {
    Write-StubResult -Fields ([ordered]@{
            setId = $setId
            planDigest = $planDigest
            launchAuthorizationHash = $launchHash
            reviewerScriptSha256 = (Get-FileHash -LiteralPath ([string]$request.reviewerScriptPath) -Algorithm SHA256).Hash.ToLowerInvariant()
            slotName = 'slot1'
            slotStateDir = [string]$stateDir
            slotTerminalPath = [string]$terminalPath
            slotAttemptExists = [bool](Test-Path -LiteralPath $attemptPath)
            slotTerminalExists = [bool](Test-Path -LiteralPath $terminalPath)
            slotTimeoutSeconds = $slotTimeoutSeconds
            progressTimeoutSeconds = $progressTimeoutSeconds
            perCallTimeoutSeconds = $perCallTimeoutSeconds
            head = [string](& git -C ([string]$request.toolkitRoot) rev-parse HEAD).Trim()
            requiredRef = [string]$request.requiredRef
            headClean = $true
            deliveryMode = 'PreviewOnly'
            promotable = $false
        })
    exit 0
}

if ($step -eq 'slotRun') {
    [void](New-Item -ItemType Directory -Force -Path $stubRoot)
    [void](New-Item -ItemType Directory -Force -Path $stateDir)
    # CreateNew, exactly as the reviewed slot runner does it: the attempt record
    # is the single-use marker, and a second attempt has to fail on the file
    # system rather than on a check something could skip.
    $attempt = [IO.File]::Open($attemptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $attemptBytes = ([Text.UTF8Encoding]::new($false, $true)).GetBytes("{`"slot`":`"slot1`",`"setId`":`"$setId`"}")
        $attempt.Write($attemptBytes, 0, $attemptBytes.Length)
    }
    finally { $attempt.Dispose() }
    if ($mode -eq 'secondAttempt') {
        # A second attempt record appearing behind the coordinator's back, which
        # is what a hand-run of the PowerShell path alongside it would leave.
        [IO.File]::WriteAllText((Join-Path $stubRoot 'slot2-attempt.json'), '{"slot":"slot2"}')
    }
    if ($mode -eq 'hang') { Start-Sleep -Seconds 600; exit 0 }
    if ($runDelaySeconds -gt 0) {
        # Touched rather than merely slept through, so a supervisor bounded by an
        # activity deadline sees the slot working rather than idle.
        $deadline = [DateTime]::UtcNow.AddSeconds($runDelaySeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            [IO.File]::WriteAllText((Join-Path $stateDir 'heartbeat.json'),
                ('{"atUtc":"' + [DateTime]::UtcNow.ToString('o') + '"}'))
            Start-Sleep -Milliseconds 500
        }
    }
    if ($mode -eq 'noTerminal') {
        Write-StubResult -Fields ([ordered]@{
                terminalWritten = $false
                terminalPath = [string]$terminalPath
                childExitCode = 0
                slotName = 'slot1'
                setId = $setId
                planDigest = $planDigest
            })
        exit 0
    }
    if ($mode -eq 'nonzeroNoTerminal') { exit 7 }

    $status = switch ($mode) {
        'failed' { 'failed' }
        'timedOut' { 'timedOut' }
        default { 'complete' }
    }
    $timedOut = ($status -eq 'timedOut')
    if ($mode -eq 'contradictoryTimeout') { $timedOut = $true }
    $terminal = [ordered]@{
        kind = 'reviewer.replay-qualification.terminal.v1'
        slot = $(if ($mode -eq 'wrongSlot') { 'slot2' } else { 'slot1' })
        setId = $(if ($mode -eq 'wrongSetId') { 'not-this-run-set' } else { $setId })
        planDigest = $planDigest
        status = $status
        exitCode = $(if ($status -eq 'complete') { 0 } else { 3 })
        timedOut = $timedOut
        childProcessId = $PID
        startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        endedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $terminalText = ConvertTo-Json -InputObject $terminal -Depth 8 -Compress:$false
    [IO.File]::WriteAllBytes($terminalPath, ([Text.UTF8Encoding]::new($false, $true)).GetBytes($terminalText))
    if ($mode -ne 'writableTerminal') {
        (Get-Item -LiteralPath $terminalPath).IsReadOnly = $true
    }
    Write-StubResult -Fields ([ordered]@{
            terminalWritten = $true
            terminalPath = [string]$terminalPath
            childExitCode = [int]$terminal.exitCode
            slotName = 'slot1'
            setId = $setId
            planDigest = $planDigest
        })
    # The reviewed runner propagates the reviewed run's own exit code, so a
    # failed slot exits non-zero with perfectly good evidence. Mirrored here so
    # the coordinator's "exit code is data" claim is actually exercised.
    exit ([int]$terminal.exitCode)
}

if ($step -eq 'slotVerify') {
    if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) {
        throw "Slot 'slot1' has no terminal evidence under '$stubRoot'."
    }
    $terminal = Get-Content -LiteralPath $terminalPath -Raw | ConvertFrom-Json -Depth 8
    $bytes = [IO.File]::ReadAllBytes($terminalPath)
    $attempts = @(Get-ChildItem -LiteralPath $stubRoot -Filter 'slot*-attempt.json' -File -ErrorAction SilentlyContinue)
    Write-StubResult -Fields ([ordered]@{
            terminalStatus = [string]$terminal.status
            terminalExitCode = [int]$terminal.exitCode
            terminalTimedOut = [bool]$terminal.timedOut
            terminalImmutable = [bool](Get-Item -LiteralPath $terminalPath).IsReadOnly
            terminalSetId = [string]$terminal.setId
            terminalPlanDigest = [string]$terminal.planDigest
            terminalSlot = [string]$terminal.slot
            terminalPath = [string]$terminalPath
            terminalSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            signatureVerified = $true
            inventoryVerified = $true
            slotAttemptCount = [int]$attempts.Count
            modelInvocationCount = 0
            deliveryMode = 'PreviewOnly'
            promotable = $false
        })
    exit 0
}
throw "'$step' is not a step this stub adapter performs."
'@
    $rendered = $body -replace '__MODE__', $Mode
    $rendered = $rendered -replace '__REAL__', ($RealAdapter -replace '\\', '\\')
    $rendered = $rendered -replace '__SLOTTIMEOUT__', [string]$SlotTimeoutSeconds
    $rendered = $rendered -replace '__PROGRESSTIMEOUT__', [string]$ProgressTimeoutSeconds
    $rendered = $rendered -replace '__PERCALLTIMEOUT__', [string]$PerCallTimeoutSeconds
    $rendered = $rendered -replace '__RUNDELAY__', [string]$RunDelaySeconds
    Set-Content -LiteralPath $path -Encoding utf8NoBOM -Value $rendered
}

function Restore-ChildAdapter {
    param([Parameter(Mandatory)][string]$ToolkitCopy, [Parameter(Mandatory)][string]$RepoRoot)
    Copy-Item -Force (Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1') `
        (Join-Path $ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1')
}

function Initialize-SlotRunSet {
    <#
    .SYNOPSIS
        Carries one slot scenario's output root to a real, signed run-set-ready and
        hands over the launch-authorization token the declaration published.

    .DESCRIPTION
        Preparation is always done by the reviewed adapter in a clean tree, and the
        reason is not tidiness: the reviewed declaration preflight refuses a dirty
        qualification worktree, and standing the adapter in IS a dirty worktree. So
        every slot scenario reaches run-set-ready for real first, and only then is
        the slot's own execution stood in for.
    #>
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$Label
    )
    Restore-ChildAdapter -ToolkitCopy $Fixture.ToolkitCopy -RepoRoot $RepositoryRoot
    $setup = Invoke-Coordinator -RequestPath $RequestPath -Target 'runSetReady'
    Assert-Coordinator ($setup.ExitCode -eq 0) `
        "The $Label setup did not reach run-set-ready (exit $($setup.ExitCode)).`n$($setup.Output)"
    [void](Publish-ShadowCoordinatorLaunchToken `
            -RunSetDirectory (Join-Path $OutputRoot 'qualification\runset') `
            -TokenPath $Fixture.LaunchTokenPath)
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
    # GetNewClosure captures variables, not function definitions, so the function
    # every scenario uses to repoint a request is captured once, here, and invoked
    # through the reference. Calling it by name from inside a closure would
    # resolve against whatever scope happens to run the closure later.
    $setOutputRoot = ${function:Set-CoordinatorOutputRoot}

    Write-Host '1/21 offline restore and build' -ForegroundColor Cyan
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
    Write-Host '2/21 sandbox, sealed corpus and typed request' -ForegroundColor Cyan
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
    Write-Host '3/21 restart at every transition' -ForegroundColor Cyan
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

    Write-Host '4/21 preparation reaches run-set-ready' -ForegroundColor Cyan
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
    Write-Host '5/21 audit indexes all twelve stage artifacts' -ForegroundColor Cyan
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
    Write-Host '6/21 stage publication parity with the PowerShell path' -ForegroundColor Cyan
    # The same stage publication, driven directly through the existing PowerShell
    # entry point instead of through the coordinator's child process. Byte
    # identical artifacts are what makes the rollback switch real at THIS seam:
    # the coordinator changes who calls the producers, not what they publish.
    #
    # Deliberately not called a full rollback differential, because it is not one.
    # It compares stage publication only. It does not re-run request validation,
    # sealing, verification, declaration or readiness through a second
    # orchestrator, so it catches serialization and path-passing drift across the
    # process adapter and nothing beyond that. The residual is recorded in
    # docs/shadow-run-coordinator.md rather than papered over here.
    $rollbackRoot = Join-Path $sandbox 'rollback'
    [void](New-Item -ItemType Directory -Force -Path $rollbackRoot)
    . (Join-Path $RepoRoot 'src\Agents\reviewer\ShadowPreparation.ps1')
    # The census the coordinator planned from, read from the file the request
    # declares rather than restated here, so the two arms cannot silently drift
    # apart on the one input that decides what gets published.
    $censusDocument = [IO.File]::ReadAllText($fixture.ChangedPathsPath) | ConvertFrom-Json -Depth 8
    $preparedPaths = [string[]]@($censusDocument.changedPaths)
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
    Write-Host '7/21 request boundary: unknown, missing, scalar, null, BOM, truncated' -ForegroundColor Cyan
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
    Write-Host '8/21 stale head, stale identity and tampered state' -ForegroundColor Cyan
    $staleHeadPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-head' -Mutate {
        param($r)
        $r.toolkit.head = ('f' * 40)
        & $setOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-head')
    }
    $staleHead = Invoke-Coordinator -RequestPath $staleHeadPath
    Assert-Coordinator ($staleHead.ExitCode -eq 2 -and $staleHead.Output -match 'head') `
        'A request binding a head the build is not at was accepted.'

    $staleDigestPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-digest' -Mutate {
        param($r)
        $r.digests.schemaSha256 = ('1' * 64)
        & $setOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-digest')
    }
    $staleDigest = Invoke-Coordinator -RequestPath $staleDigestPath
    Assert-Coordinator ($staleDigest.ExitCode -eq 2 -and $staleDigest.Output -match 'schema') `
        'A request binding a stale schema digest was accepted.'

    $staleCorpusPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stale-corpus' -Mutate {
        param($r)
        $r.corpus.indexSha256 = ('2' * 64)
        & $setOutputRoot -Request $r -Root (Join-Path $sandbox 'out-stale-corpus')
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $staleCorpusPath).ExitCode -ne 0) `
        'A request binding a corpus index digest the corpus does not have was accepted.'

    # A state file edited on disk must not be resumed from.
    $tamperRoot = Join-Path $sandbox 'out-tamper'
    $tamperPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'tamper' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $tamperRoot
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
        param($r) & $setOutputRoot -Request $r -Root $foreignRoot
    }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $foreignPath -HaltAfter 'requestValidated').ExitCode -eq 9) `
        'The foreign-correlation scenario did not reach its first halt.'
    $foreignRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'foreign-second' -Mutate {
        param($r)
        & $setOutputRoot -Request $r -Root $foreignRoot
        $r.correlationId = 'shadow-a-different-run'
    }
    $foreign = Invoke-Coordinator -RequestPath $foreignRequest
    Assert-Coordinator ($foreign.ExitCode -eq 2) `
        "A state file from another correlation was adopted (exit $($foreign.ExitCode))."

    # -----------------------------------------------------------------------
    Write-Host '9/21 single-run lease' -ForegroundColor Cyan
    $leaseRoot = Join-Path $sandbox 'out-lease'
    $leasePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'lease' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $leaseRoot
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
    Write-Host '10/21 child fault matrix' -ForegroundColor Cyan
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
    # GetNewClosure captures variables, not function definitions, so the function
    # is captured explicitly and invoked through the reference. Calling it by name
    # from inside the closure would resolve against whatever scope runs it later.
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
        param($r) & $setOutputRoot -Request $r -Root $chatterRoot
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
        & $setOutputRoot -Request $r -Root $hangRoot
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
    Write-Host '11/21 killed mid-transition' -ForegroundColor Cyan
    # A real external kill, not a cooperative halt: the coordinator is stopped
    # while a child is running, and the root must still converge.
    $killRoot = Join-Path $sandbox 'out-kill'
    $killRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'kill' -Mutate {
        param($r) & $setOutputRoot -Request $r -Root $killRoot
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
    Write-Host '12/21 pre-commit window: a published side effect is adopted' -ForegroundColor Cyan
    # The fault a control plane cannot test its way out of by halting: a child
    # completes a durable, NON-REPEATABLE side effect and the coordinator dies
    # before it can commit the transition. Every --halt-after case above stops
    # AFTER a commit, so none of them reach this window.
    #
    # Reproduced here in the harshest available form. The run is taken to a
    # sealed snapshot and a declared run set, and then the coordinator's entire
    # durable record is destroyed while the side effects are left standing. That
    # is strictly worse than the real window - the real one keeps its record and
    # loses only the last commit - so a run that recovers from this recovers from
    # that. Before the side effects became adoptable this wedged permanently:
    # the sealer refuses an existing snapshot id without -Force and the
    # qualification tool refuses a second declaration, so every later resume took
    # the identical path and failed identically.
    #
    # Case one is the real window, reproduced exactly: a child that completes its
    # durable side effect and then dies without leaving a result. The record
    # still says the PREVIOUS transition, so the resume re-enters a step whose
    # work is already on disk.
    $windowRoot = Join-Path $sandbox 'precommit-adopt'
    $windowPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'precommit-adopt' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $windowRoot }.GetNewClosure()
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'publishThenDie' `
        -RealAdapter (Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1')
    try {
        $lost = Invoke-Coordinator -RequestPath $windowPath
        Assert-Coordinator ($lost.ExitCode -eq 4) `
            "A child that published and then died was not reported as a child failure; it exited $($lost.ExitCode)."
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    $orphanSeal = @(Get-ChildItem -LiteralPath (Join-Path $windowRoot 'replay-root') -Directory -ErrorAction SilentlyContinue)
    Assert-Coordinator ($orphanSeal.Count -eq 1) `
        "The lost child left $($orphanSeal.Count) snapshots; the window under test needs exactly one."
    $orphanDigest = (Get-ChildItem -LiteralPath $orphanSeal[0].FullName -Recurse -File |
            Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|'
    $windowState = Get-Content -LiteralPath (Join-Path $windowRoot 'coordinator\state.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([string]$windowState.state -ceq 'snapshotValidateOnly') `
        "The record after the lost child reads '$($windowState.state)'; the window needs the seal uncommitted."

    # The resume must reach run-set-ready over the top of that orphaned seal.
    $windowResume = Invoke-Coordinator -RequestPath $windowPath
    Assert-Coordinator ($windowResume.ExitCode -eq 0) `
        "A resume over an orphaned seal did not recover; it exited $($windowResume.ExitCode).`n$($windowResume.Output)"
    $windowAudit = Get-Content -LiteralPath (Join-Path $windowRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([string]$windowAudit.finalState -ceq 'runSetReady') `
        "The recovered run reached '$($windowAudit.finalState)' rather than run-set-ready."
    Assert-Coordinator ([int]$windowAudit.modelInvocationCount -eq 0) `
        'The recovered run recorded a model invocation.'
    $sealedBefore = @(Get-ChildItem -LiteralPath (Join-Path $windowRoot 'replay-root') -Directory)
    Assert-Coordinator ($sealedBefore.Count -eq 1) `
        "The recovered run left $($sealedBefore.Count) snapshots rather than adopting the one already sealed."
    $sealedDigestParts = @(Get-ChildItem -LiteralPath $sealedBefore[0].FullName -Recurse -File |
            Sort-Object FullName | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    $sealedDigestBefore = [string]($sealedDigestParts -join '|')
    Assert-Coordinator ($sealedDigestBefore -ceq $orphanDigest) `
        'The recovered run rewrote the orphaned snapshot instead of adopting its bytes.'
    $sealAdopt = Get-ExchangeResult -Root $windowRoot -Step 'corpusSeal'
    Assert-Coordinator ([bool]$sealAdopt.adopted) `
        'The seal child resealed rather than adopting the snapshot its lost attempt had published.'
    $declaredBefore = @(Get-ChildItem -LiteralPath (Join-Path $windowRoot 'qualification') -Recurse -File `
            -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'runset-*' -and $_.Name -notlike '*.sig*' })
    Assert-Coordinator ($declaredBefore.Count -ge 1) `
        "The recovered run published $($declaredBefore.Count) run set files rather than at least one."

    # Case two is the harsher variant: the signed record itself is destroyed. A
    # run whose record is gone must NOT quietly re-derive one over standing side
    # effects - if it could, the record would not be load-bearing. It fails
    # closed instead, and says so.
    $wipedRoot = Join-Path $sandbox 'precommit-wiped-record'
    $wipedPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'precommit-wiped-record' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $wipedRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $wipedPath -Target 'snapshotSealed').ExitCode -eq 0) `
        'The wiped-record setup did not reach a sealed snapshot.'
    # First with the signing key left in place. A key is minted with the first
    # record, so a key without a record is proof a record was removed, and that
    # is caught before anything at all is mutated - not later, by happening to
    # trip over a standing side effect.
    $wipedAuditPath = Join-Path $wipedRoot 'coordinator\audit.json'
    $wipedAuditBefore = (Get-FileHash -LiteralPath $wipedAuditPath -Algorithm SHA256).Hash
    Remove-Item -LiteralPath (Join-Path $wipedRoot 'coordinator\state.json') -Force
    $keptKey = Invoke-Coordinator -RequestPath $wipedPath
    Assert-Coordinator ($keptKey.ExitCode -eq 2) `
        "A run whose record was removed under a standing key exited $($keptKey.ExitCode) rather than refusing.`n$($keptKey.Output)"
    Assert-Coordinator ($keptKey.Output -match 'signing key and .*, but no state record') `
        "The refusal did not name the missing record.`n$($keptKey.Output)"
    Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $wipedRoot 'coordinator\state.json'))) `
        'The refusing run wrote a fresh record over the destroyed one.'
    Assert-Coordinator ((Get-FileHash -LiteralPath $wipedAuditPath -Algorithm SHA256).Hash -ceq $wipedAuditBefore) `
        'The refusing run republished an audit for a preparation it refused to resume.'
    # Then with the key destroyed too, which is the closest an operator can get
    # to a genuinely fresh root over standing side effects. It still refuses,
    # because the snapshot the earlier attempt published is still there.
    Remove-Item -LiteralPath (Join-Path $wipedRoot 'coordinator\state.key') -Force -ErrorAction SilentlyContinue
    $wiped = Invoke-Coordinator -RequestPath $wipedPath
    Assert-Coordinator ($wiped.ExitCode -eq 2) `
        "A run whose signed record was destroyed exited $($wiped.ExitCode) rather than refusing.`n$($wiped.Output)"
    Assert-Coordinator ($wiped.Output -match 'replay-root|snapshot') `
        'The refusal did not name the standing side effect that contradicts the empty record.'

    # Case three: the same window on the OTHER non-repeatable side effect. The
    # qualification tool refuses a second declaration, so a declaration that
    # survives its coordinator has to be adoptable in its own right.
    #
    # This one is driven at the child directly rather than through a replaced
    # adapter. The qualification tool refuses to declare against a dirty
    # worktree, so swapping the adapter file - which is IN the toolkit - can
    # never reach the declaration step at all. Replaying the coordinator's own
    # child request against the pristine adapter is the faithful reproduction:
    # it is byte for byte the request the resumed coordinator would send.
    $declareRoot = Join-Path $sandbox 'precommit-declare'
    $declarePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'precommit-declare' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $declareRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $declarePath -HaltAfter 'runSetDeclared').ExitCode -eq 9) `
        'The declaration window setup did not halt after the declaration.'
    $orphanDeclared = @(Get-ChildItem -LiteralPath (Join-Path $declareRoot 'qualification\runset') -File `
            -Filter 'runset-*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.sig' })
    Assert-Coordinator ($orphanDeclared.Count -eq 1) `
        "The declaration window setup published $($orphanDeclared.Count) run sets rather than one."
    $firstDeclare = Get-ExchangeResult -Root $declareRoot -Step 'runSetDeclare'
    Assert-Coordinator (-not [bool]$firstDeclare.adopted) `
        'The first declaration reported itself as adopted; it had nothing to adopt.'

    # Replay the identical child request. A coordinator that died before its
    # commit sends exactly this again.
    $declareChildRequest = @(Get-ChildItem -LiteralPath (Join-Path $declareRoot 'coordinator\exchange') -File `
            -Filter '*-runSetDeclare.request.json')[0].FullName
    $replayResult = Join-Path $sandbox 'declare-replay.result.json'
    $replayRequest = Join-Path $sandbox 'declare-replay.request.json'
    $replayDocument = Get-Content -LiteralPath $declareChildRequest -Raw | ConvertFrom-Json -Depth 24
    $replayDocument.resultPath = $replayResult
    $replayText = (ConvertTo-Json -InputObject $replayDocument -Depth 24 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($replayRequest, ([Text.UTF8Encoding]::new($false)).GetBytes($replayText))
    $adapter = Join-Path $fixture.ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $replayOutput = & pwsh -NoProfile -File $adapter -RequestPath $replayRequest 2>&1 | Out-String
    $replayExit = $LASTEXITCODE
    Assert-Coordinator ($replayExit -eq 0) `
        "Replaying the declaration child against its own published run set exited $replayExit.`n$replayOutput"
    $replayed = Get-Content -LiteralPath $replayResult -Raw | ConvertFrom-Json -Depth 16
    Assert-Coordinator ([bool]$replayed.adopted) `
        'The declaration child declared a second run set rather than adopting the one already standing.'
    Assert-Coordinator ([string]$replayed.runSetPath -ceq [string]$firstDeclare.runSetPath) `
        'The adopted declaration is not the run set the first attempt published.'
    $declaredAfter = @(Get-ChildItem -LiteralPath (Join-Path $declareRoot 'qualification\runset') -File `
            -Filter 'runset-*.json' | Where-Object { $_.Name -notlike '*.sig' })
    Assert-Coordinator ($declaredAfter.Count -eq 1) `
        "The replayed declaration left $($declaredAfter.Count) run sets rather than adopting the single one."

    # And the coordinator itself still finishes over the top of it.
    $declareResume = Invoke-Coordinator -RequestPath $declarePath
    Assert-Coordinator ($declareResume.ExitCode -eq 0) `
        "A resume after the declaration window did not recover; it exited $($declareResume.ExitCode).`n$($declareResume.Output)"
    $declareAudit = Get-Content -LiteralPath (Join-Path $declareRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([string]$declareAudit.finalState -ceq 'runSetReady') `
        "The recovered declaration run reached '$($declareAudit.finalState)' rather than run-set-ready."
    Assert-Coordinator ([int]$declareAudit.slotLaunchCount -eq 0 -and [int]$declareAudit.modelInvocationCount -eq 0) `
        'The recovered declaration run recorded a slot or model launch.'
    Assert-Coordinator ($sealedDigestBefore.Length -gt 0 -and $declaredBefore.Count -ge 1) `
        'The first pre-commit window did not leave the evidence the later cases compare against.'

    # Case four: the same window on the stage publication. Its retry works by
    # sweeping the previous attempt's artifacts, and the directory it sweeps also
    # holds the ownership marker the stage switch requires. A sweep that takes the
    # marker with it makes the retry it exists to enable impossible.
    $stageRoot = Join-Path $sandbox 'precommit-stage'
    $stagePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'precommit-stage' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $stageRoot }.GetNewClosure()
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'publishThenDie' `
        -RealAdapter (Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1') -DieOnStep 'stagePreparation'
    try { $stageLost = Invoke-Coordinator -RequestPath $stagePath -Target 'recipePlanned' }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    Assert-Coordinator ($stageLost.ExitCode -ne 0) `
        'The stage window setup committed a transition whose child never returned a result.'
    $stageDirectory = Join-Path $stageRoot 'stage-artifacts'
    $orphanStage = @(Get-ChildItem -LiteralPath $stageDirectory -File -Filter '*.stage.json')
    Assert-Coordinator ($orphanStage.Count -eq 12) `
        "The lost stage attempt left $($orphanStage.Count) artifacts rather than twelve."
    Assert-Coordinator (Test-Path -LiteralPath (Join-Path $stageDirectory '.reviewer-stage-shadow.json')) `
        'The lost stage attempt left no ownership marker, so the window cannot be reproduced.'

    $stageResume = Invoke-Coordinator -RequestPath $stagePath -Target 'recipePlanned'
    Assert-Coordinator ($stageResume.ExitCode -eq 0) `
        "A resume over an orphaned stage publication exited $($stageResume.ExitCode).`n$($stageResume.Output)"
    $stageRetry = Get-ExchangeResult -Root $stageRoot -Step 'stagePreparation'
    Assert-Coordinator ([int]$stageRetry.discardedCount -eq 12) `
        "The retry discarded $($stageRetry.discardedCount) leftover artifacts rather than twelve."
    Assert-Coordinator ([int]$stageRetry.publishedCount -eq 12) `
        "The retry published $($stageRetry.publishedCount) artifacts rather than twelve."
    Assert-Coordinator (Test-Path -LiteralPath (Join-Path $stageDirectory '.reviewer-stage-shadow.json')) `
        'The retry swept away the ownership marker its own next retry would need.'
    $stageReservations = @(Get-ChildItem -LiteralPath $stageDirectory -File -Filter '*.reservation' `
            -ErrorAction SilentlyContinue)
    $orphanReservations = @($stageReservations | Where-Object {
            -not (Test-Path -LiteralPath ($_.FullName -replace '\.reservation$', '') -PathType Leaf) })
    Assert-Coordinator ($orphanReservations.Count -eq 0) `
        ("The retry left $($orphanReservations.Count) reservation(s) with no artifact: " +
        "$(($orphanReservations | ForEach-Object { $_.Name }) -join ', ')")
    Assert-Coordinator (@(Get-ChildItem -LiteralPath $stageDirectory -File -Filter '*.stage.json').Count -eq 12) `
        'The retry accumulated stage artifacts instead of replacing them.'
    # -----------------------------------------------------------------------
    Write-Host '13/21 resume integrity and the declared artifact directory' -ForegroundColor Cyan
    # A resumed run re-reads its child results from the exchange directory, which
    # carries no signature of its own. Without binding them to the digest the
    # signed record committed, a resume could adopt a snapshot or run set other
    # than the one its own record was committed against, and every downstream
    # check would be self-consistent and pass.
    $resumeRoot = Join-Path $sandbox 'resume-integrity'
    $resumePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'resume-integrity' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $resumeRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $resumePath -HaltAfter 'snapshotSealed').ExitCode -eq 9) `
        'The resume-integrity setup did not halt after the seal.'
    $sealResultPath = @(Get-ChildItem -LiteralPath (Join-Path $resumeRoot 'coordinator\exchange') -File `
            -Filter '*-corpusSeal.result.json')[0].FullName
    $sealDocument = Get-Content -LiteralPath $sealResultPath -Raw | ConvertFrom-Json -Depth 16
    $sealDocument.manifestSha256 = ('0' * 64)
    $editedText = (ConvertTo-Json -InputObject $sealDocument -Depth 16 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($sealResultPath, ([Text.UTF8Encoding]::new($false)).GetBytes($editedText))
    $resumeTampered = Invoke-Coordinator -RequestPath $resumePath
    Assert-Coordinator ($resumeTampered.ExitCode -eq 2) `
        "A resume against an edited child result exited $($resumeTampered.ExitCode) rather than refusing.`n$($resumeTampered.Output)"
    Assert-Coordinator ($resumeTampered.Output -match 'committed record binds') `
        'The refusal did not name the committed digest it was resuming against.'

    # A stage artifact edited after it was censused must not be inherited.
    $rehashRoot = Join-Path $sandbox 'resume-rehash'
    $rehashPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'resume-rehash' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $rehashRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $rehashPath -HaltAfter 'recipePlanned').ExitCode -eq 9) `
        'The rehash setup did not halt after the plan.'
    $censused = @(Get-ChildItem -LiteralPath (Join-Path $rehashRoot 'stage-artifacts') -Filter '*.stage.json' -File)[0]
    # The stage writer publishes read-only, which is a useful speed bump but not
    # a control: anything that can reach the file can clear the attribute first.
    Set-ItemProperty -LiteralPath $censused.FullName -Name IsReadOnly -Value $false
    Add-Content -LiteralPath $censused.FullName -Value ' '
    $rehashResume = Invoke-Coordinator -RequestPath $rehashPath
    Assert-Coordinator ($rehashResume.ExitCode -eq 2) `
        "A resume against an edited stage artifact exited $($rehashResume.ExitCode) rather than refusing.`n$($rehashResume.Output)"

    # The child does not get to say where it published.
    $strayRoot = Join-Path $sandbox 'stray-directory'
    $strayRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'stray-directory' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $strayRoot }.GetNewClosure()
    $strayTarget = Join-Path $sandbox 'stray-artifacts'
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'strayDirectory' -StrayDirectory $strayTarget
    try {
        $stray = Invoke-Coordinator -RequestPath $strayRequest
        Assert-Coordinator ($stray.ExitCode -eq 2) `
            "A child that published outside the declared root exited $($stray.ExitCode) rather than being refused.`n$($stray.Output)"
        Assert-Coordinator ($stray.Output -match 'the request declared') `
            'The refusal did not name the directory the request declared.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # A child result that does not bind the request that asked for the work.
    $digestRoot = Join-Path $sandbox 'wrong-request-digest'
    $digestRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'wrong-request-digest' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $digestRoot }.GetNewClosure()
    New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'wrongRequestDigest'
    try {
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $digestRequest).ExitCode -eq 4) `
            'A child result bound to the wrong request digest was accepted.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # A usage fault is a usage fault, not a stack trace.
    $usage = Invoke-CoordinatorRaw -Arguments @('--request')
    Assert-Coordinator ($usage.ExitCode -eq 2 -or $usage.ExitCode -eq 1) `
        "'--request' with no value exited $($usage.ExitCode), outside the documented set."
    Assert-Coordinator ($usage.Output -notmatch 'Unhandled exception') `
        'A missing option value escaped as an unhandled exception.'

    # -----------------------------------------------------------------------
    Write-Host '14/21 changed-path census boundary' -ForegroundColor Cyan
    # The census is declared by the caller and validated here, never synthesised.
    # Zero, one, many, duplicated, misordered, scalar, null and unknown all have
    # to have an answer, because the census reaches the published bytes.
    $censusCases = [Collections.Generic.List[hashtable]]::new()
    [void]$censusCases.Add(@{ Name = 'empty'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":[]}' })
    [void]$censusCases.Add(@{ Name = 'duplicate'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/a.ps1","/a.ps1"]}' })
    [void]$censusCases.Add(@{ Name = 'misordered'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/b.ps1","/a.ps1"]}' })
    [void]$censusCases.Add(@{ Name = 'scalar'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":"/a.ps1"}' })
    [void]$censusCases.Add(@{ Name = 'null'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":null}' })
    [void]$censusCases.Add(@{ Name = 'null-element'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/a.ps1",null]}' })
    [void]$censusCases.Add(@{ Name = 'unknown'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v1","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/a.ps1"],"extra":1}' })
    [void]$censusCases.Add(@{ Name = 'wrong-contract'; Body = '{"contractVersion":"devpilot.shadow-run-coordinator.changed-paths.v0","kind":"shadow-run-coordinator-changed-paths","changedPaths":["/a.ps1"]}' })
    [void]$censusCases.Add(@{ Name = 'array-root'; Body = '["/a.ps1"]' })
    foreach ($case in $censusCases) {
        $censusPath = Join-Path $sandbox "census-$($case.Name).json"
        [IO.File]::WriteAllBytes($censusPath, ([Text.UTF8Encoding]::new($false)).GetBytes([string]$case.Body))
        $censusRoot = Join-Path $sandbox "census-root-$($case.Name)"
        $censusRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "census-$($case.Name)" `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $censusRoot
                $r.corpus.changedPathsPath = $censusPath
            }.GetNewClosure()
        $censusResult = Invoke-Coordinator -RequestPath $censusRequest
        Assert-Coordinator ($censusResult.ExitCode -eq 2) `
            "A '$($case.Name)' changed-path census exited $($censusResult.ExitCode) rather than being refused."
    }
    $missingCensusRoot = Join-Path $sandbox 'census-root-missing'
    $missingCensus = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'census-missing' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $missingCensusRoot
            $r.corpus.changedPathsPath = (Join-Path $sandbox 'no-such-census.json')
        }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $missingCensus).ExitCode -eq 2) `
        'A missing changed-path census was not refused.'

    # -----------------------------------------------------------------------
    Write-Host '15/21 a declaration must belong to this preparation' -ForegroundColor Cyan
    # A signature proves a declaration was made under this output root's key. It
    # does NOT prove the declaration is about the snapshot this run sealed - one
    # key signs every declaration in a root, so a declaration left behind by an
    # earlier subject verifies perfectly and would otherwise be adopted, verified
    # and signed off as ready under a snapshot it has never heard of.
    $foreignRoot = Join-Path $sandbox 'foreign-declaration'
    $foreignPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'foreign-declaration' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $foreignRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $foreignPath -HaltAfter 'runSetDeclared').ExitCode -eq 9) `
        'The foreign-declaration setup did not halt after its declaration.'
    $foreignRunSetDirectory = Join-Path $foreignRoot 'qualification\runset'
    $foreignRunSet = @(Get-ChildItem -LiteralPath $foreignRunSetDirectory -File -Filter 'runset-*.json' |
            Where-Object { $_.Name -notlike '*.sig' })[0]

    # Rewrite the standing declaration so it names a different snapshot, and
    # re-sign it under the same key so the signature stays genuine. This is
    # exactly the shape of a run set an earlier subject would have left behind.
    $foreignRecord = Get-Content -LiteralPath $foreignRunSet.FullName -Raw | ConvertFrom-Json -Depth 24
    $foreignManifest = [string]$foreignRecord.manifestJson | ConvertFrom-Json -Depth 24
    $foreignManifest.snapshotName = 'pr9999-i1-someoneelsesnapshot'
    $foreignManifestJson = ConvertTo-Json -InputObject $foreignManifest -Depth 24 -Compress
    $foreignKeyText = (Get-Content -LiteralPath $fixture.RunSetKeyPath -Raw).Trim()
    $foreignKeyBytes = [Convert]::FromBase64String($foreignKeyText.Substring($foreignKeyText.IndexOf(':') + 1))
    $foreignHmac = [System.Security.Cryptography.HMACSHA256]::new($foreignKeyBytes)
    try {
        $foreignSignature = ([BitConverter]::ToString(
                $foreignHmac.ComputeHash(([Text.UTF8Encoding]::new($false)).GetBytes($foreignManifestJson))) -replace '-', '').ToLowerInvariant()
    }
    finally { $foreignHmac.Dispose() }
    $foreignRecord.manifestJson = $foreignManifestJson
    $foreignRecord.signature = $foreignSignature
    $foreignText = (ConvertTo-Json -InputObject $foreignRecord -Depth 24 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($foreignRunSet.FullName, ([Text.UTF8Encoding]::new($false)).GetBytes($foreignText))

    $foreignResume = Invoke-Coordinator -RequestPath $foreignPath
    Assert-Coordinator ($foreignResume.ExitCode -ne 0) `
        "A declaration bound to another snapshot was accepted; the run exited $($foreignResume.ExitCode)."
    $foreignState = Get-Content -LiteralPath (Join-Path $foreignRoot 'coordinator\state.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([string]$foreignState.state -cne 'runSetReady') `
        'A preparation signed run-set-ready over a declaration belonging to another subject.'

    # The child adapter refuses the same thing on its own, before the coordinator
    # ever sees it, so adoption is not the weak half of the pair.
    $foreignChildRequest = @(Get-ChildItem -LiteralPath (Join-Path $foreignRoot 'coordinator\exchange') -File `
            -Filter '*-runSetDeclare.request.json')[0].FullName
    $foreignReplayRequest = Join-Path $sandbox 'foreign-declare.request.json'
    $foreignReplayResult = Join-Path $sandbox 'foreign-declare.result.json'
    $foreignReplayDocument = Get-Content -LiteralPath $foreignChildRequest -Raw | ConvertFrom-Json -Depth 24
    $foreignReplayDocument.resultPath = $foreignReplayResult
    $foreignReplayText = (ConvertTo-Json -InputObject $foreignReplayDocument -Depth 24 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($foreignReplayRequest, ([Text.UTF8Encoding]::new($false)).GetBytes($foreignReplayText))
    $foreignAdapter = Join-Path $fixture.ToolkitCopy 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $foreignChildOutput = & pwsh -NoProfile -File $foreignAdapter -RequestPath $foreignReplayRequest 2>&1 | Out-String
    Assert-Coordinator ($LASTEXITCODE -ne 0) `
        "The child adopted a run set belonging to another preparation.`n$foreignChildOutput"
    Assert-Coordinator ($foreignChildOutput -match 'another preparation') `
        "The child's refusal did not say the declaration belongs elsewhere.`n$foreignChildOutput"

    # The coordinator does not take the child's word for which subject it just
    # verified. A result that is genuine in every other respect - correlated,
    # correctly digested, produced by the real child - but disagrees with the
    # record about the snapshot or the set is still refused, so the binding
    # survives a child that is merely wrong rather than hostile.
    $realAdapterPath = Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1'
    foreach ($binding in @(
            @{ Name = 'verify-snapshot'; Step = 'runSetVerify'; Property = 'snapshotName'
                Value = 'pr9999-i1-someoneelsesnapshot'; Target = 'runSetVerified'
                Expect = 'is bound to snapshot .pr9999-i1-someoneelsesnapshot.' },
            @{ Name = 'status-setid'; Step = 'runSetStatus'; Property = 'setId'
                Value = ('f' * 32); Target = 'runSetReady'
                Expect = 'status read reports run set .f{32}.' })) {
        $bindingRoot = Join-Path $sandbox ('binding-' + $binding.Name)
        $bindingRequest = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name ('binding-' + $binding.Name) `
            -Mutate { param($r) & $setOutputRoot -Request $r -Root $bindingRoot }.GetNewClosure()
        # The declaration is made first, with the pristine adapter: the
        # qualification tool refuses a dirty worktree, and replacing the adapter
        # is itself a worktree change, so a run that starts under a replaced
        # adapter can never reach a declaration to disagree about.
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $bindingRequest -HaltAfter 'runSetDeclared').ExitCode -eq 9) `
            "The $($binding.Name) setup did not halt after its declaration."
        New-FaultyChildAdapter -ToolkitCopy $fixture.ToolkitCopy -Fault 'mutateResult' -RealAdapter $realAdapterPath `
            -MutateStep $binding.Step -MutateProperty $binding.Property -MutateValue $binding.Value
        try { $bindingRun = Invoke-Coordinator -RequestPath $bindingRequest -Target $binding.Target }
        finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
        Assert-Coordinator ($bindingRun.ExitCode -eq 2) `
            ("A child result that renamed '$($binding.Property)' exited $($bindingRun.ExitCode) " +
            "rather than refusing.`n$($bindingRun.Output)")
        Assert-Coordinator ($bindingRun.Output -match $binding.Expect) `
            "The refusal did not name what it disagreed about.`n$($bindingRun.Output)"
        $bindingState = Get-Content -LiteralPath (Join-Path $bindingRoot 'coordinator\state.json') -Raw |
            ConvertFrom-Json -Depth 24
        Assert-Coordinator ([string]$bindingState.state -cne $binding.Target) `
            "The coordinator committed '$($binding.Target)' over a child result that contradicted its own record."
    }

    # A standing declaration is adopted only when it was made for THIS
    # qualification. Snapshot name, manifest digest and run count agreeing is not
    # enough: two preparations can differ in repository, config, operator, commit
    # or timeouts and still agree on all three.
    $donorRoot = Join-Path $sandbox 'plan-donor'
    $donorPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'plan-donor' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $donorRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $donorPath -HaltAfter 'runSetDeclared').ExitCode -eq 9) `
        'The plan-donor setup did not produce a declaration.'
    $borrowRoot = Join-Path $sandbox 'plan-borrower'
    $borrowPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'plan-borrower' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $borrowRoot
            # Same snapshot, same manifest, same run count - a different operator.
            $r.qualification.operatorAlias = 'someone-else'
        }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $borrowPath -Target 'snapshotVerified').ExitCode -eq 0) `
        'The plan-borrower setup did not reach a verified snapshot.'
    $donorQualification = Join-Path $donorRoot 'qualification'
    $borrowQualification = Join-Path $borrowRoot 'qualification'
    Remove-Item -Recurse -Force -LiteralPath $borrowQualification -ErrorAction SilentlyContinue
    Copy-Item -Recurse -Force -LiteralPath $donorQualification -Destination $borrowQualification
    $borrowRun = Invoke-Coordinator -RequestPath $borrowPath -Target 'runSetDeclared'
    Assert-Coordinator ($borrowRun.ExitCode -eq 4) `
        ("A declaration made for another qualification exited $($borrowRun.ExitCode) " +
        "rather than being refused.`n$($borrowRun.Output)")
    $borrowLogs = @(Get-ChildItem -LiteralPath (Join-Path $borrowRoot 'coordinator\logs') -File `
            -Filter '*-runSetDeclare.*.log')
    $borrowResults = @(Get-ChildItem -LiteralPath (Join-Path $borrowRoot 'coordinator\exchange') -File `
            -Filter '*-runSetDeclare.result.json' -ErrorAction SilentlyContinue)
    $borrowReason = (@($borrowLogs + $borrowResults | ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw
            })) -join "`n"
    Assert-Coordinator ($borrowReason -match 'belongs to another preparation') `
        "The refusal did not say the declaration was another preparation's.`n$borrowReason"
    Assert-Coordinator ($borrowReason -match 'was made for plan') `
        "The refusal did not name the plan the declaration was sealed under.`n$borrowReason"

    # -----------------------------------------------------------------------
    Write-Host '16/21 the audit says only what the record can support' -ForegroundColor Cyan
    # An audit whose counters come from this process cannot see work an earlier
    # process did, and a null count coerces to the reassuring zero in every
    # consumer that reads it. Both are properties of the durable record here.
    $auditRoot = Join-Path $sandbox 'audit-honesty'
    $auditPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'audit-honesty' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $auditRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $auditPath -Target 'snapshotVerified').ExitCode -eq 0) `
        'The audit-honesty setup did not reach a verified snapshot.'
    $shortAudit = Get-Content -LiteralPath (Join-Path $auditRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator (-not [bool]$shortAudit.invariantCountsObserved) `
        'A run stopped short of readiness claimed it had observed the invariant counts.'
    Assert-Coordinator (-not $shortAudit.PSObject.Properties['modelInvocationCount']) `
        'A run that never observed a model census still published one, which reads as zero.'
    Assert-Coordinator (-not $shortAudit.PSObject.Properties['slotLaunchCount']) `
        'A run that never observed a slot census still published one, which reads as zero.'
    $shortChildCount = [int]$shortAudit.childResultTransitionCount

    $auditResume = Invoke-Coordinator -RequestPath $auditPath
    Assert-Coordinator ($auditResume.ExitCode -eq 0) `
        "The audit-honesty resume exited $($auditResume.ExitCode).`n$($auditResume.Output)"
    $resumedAudit = Get-Content -LiteralPath (Join-Path $auditRoot 'coordinator\audit.json') -Raw | ConvertFrom-Json -Depth 24
    Assert-Coordinator ([bool]$resumedAudit.invariantCountsObserved) `
        'A completed run did not record that it had observed the invariant counts.'
    Assert-Coordinator ([int]$resumedAudit.slotLaunchCount -eq 0 -and [int]$resumedAudit.modelInvocationCount -eq 0) `
        'The completed audit recorded a slot or model launch.'
    $uninterruptedAudit = Get-Content -LiteralPath (Join-Path $fixture.OutputRoot 'coordinator\audit.json') -Raw |
        ConvertFrom-Json -Depth 24
    Assert-Coordinator ([int]$resumedAudit.childResultTransitionCount -eq [int]$uninterruptedAudit.childResultTransitionCount) `
        ("A resumed run counted $($resumedAudit.childResultTransitionCount) child-backed transition(s) and an " +
        "uninterrupted one counted $($uninterruptedAudit.childResultTransitionCount); the audit is not resume-invariant.")
    Assert-Coordinator ([int]$resumedAudit.childResultTransitionCount -gt $shortChildCount) `
        'The resumed audit did not grow its child-backed transition census.'

    # -----------------------------------------------------------------------
    Write-Host '17/21 a root that has done nothing is not wedged' -ForegroundColor Cyan
    # The refusal that protects a destroyed record must not be reachable by a
    # first attempt that simply failed. A run refused at requestValidated has
    # published nothing, so the same root with a corrected request has to work -
    # otherwise a mistyped digest costs an operator their output root for ever,
    # and the earliest point of the run becomes the one place a kill is fatal.
    $freshRoot = Join-Path $sandbox 'wedge-check'
    $badFirst = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'wedge-check-bad' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $freshRoot
            $r.toolkit.head = ('b' * 40)
        }.GetNewClosure()
    $wedgeFirst = Invoke-Coordinator -RequestPath $badFirst
    Assert-Coordinator ($wedgeFirst.ExitCode -eq 2) `
        "A request naming the wrong head exited $($wedgeFirst.ExitCode) rather than refusing."
    Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $freshRoot 'coordinator\state.json'))) `
        'A refused first attempt still wrote a state record.'
    $goodSecond = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'wedge-check-good' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $freshRoot }.GetNewClosure()
    $wedgeSecond = Invoke-Coordinator -RequestPath $goodSecond -Target 'corpusValidated'
    Assert-Coordinator ($wedgeSecond.ExitCode -eq 0) `
        ("A corrected request against a root whose first attempt was refused exited " +
        "$($wedgeSecond.ExitCode); the root is wedged.`n$($wedgeSecond.Output)")

    # The refusal still fires when the root holds work, which is the case it is
    # actually for.
    $wipedWork = Join-Path $sandbox 'wedge-check-work'
    $wipedWorkPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'wedge-check-work' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $wipedWork }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $wipedWorkPath -Target 'recipePlanned').ExitCode -eq 0) `
        'The standing-work setup did not publish any stage artifacts.'
    Remove-Item -LiteralPath (Join-Path $wipedWork 'coordinator\state.json') -Force
    $wipedWorkRun = Invoke-Coordinator -RequestPath $wipedWorkPath
    Assert-Coordinator ($wipedWorkRun.ExitCode -eq 2) `
        "A destroyed record over standing work exited $($wipedWorkRun.ExitCode) rather than refusing."
    Assert-Coordinator ($wipedWorkRun.Output -match 'signing key and .*, but no state record') `
        "The refusal did not name the work it found.`n$($wipedWorkRun.Output)"

    # The recipe is bound by content, not by path. A resume skips corpusValidated,
    # so without this the file could be rewritten between the validation that
    # blessed it and the seal that consumes it.
    $recipeRoot = Join-Path $sandbox 'recipe-binding'
    $recipeRequestPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'recipe-binding' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $recipeRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $recipeRequestPath -Target 'corpusValidated').ExitCode -eq 0) `
        'The recipe-binding setup did not validate its corpus.'
    $recipeDocument = Get-Content -LiteralPath $recipeRequestPath -Raw | ConvertFrom-Json -Depth 24
    $recipeFile = [string]$recipeDocument.corpus.recipePath
    $recipeOriginal = [IO.File]::ReadAllBytes($recipeFile)
    try {
        $recipeText = [Text.Encoding]::UTF8.GetString($recipeOriginal)
        [IO.File]::WriteAllBytes($recipeFile, ([Text.UTF8Encoding]::new($false)).GetBytes($recipeText + " `n"))
        $recipeRun = Invoke-Coordinator -RequestPath $recipeRequestPath -Target 'snapshotValidateOnly'
        Assert-Coordinator ($recipeRun.ExitCode -eq 2) `
            "A recipe rewritten after validation exited $($recipeRun.ExitCode) rather than refusing."
        Assert-Coordinator ($recipeRun.Output -match 'recipe .* now hashes to|changed under the preparation') `
            "The refusal did not name the changed recipe.`n$($recipeRun.Output)"
    }
    finally { [IO.File]::WriteAllBytes($recipeFile, $recipeOriginal) }
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $recipeRequestPath -Target 'snapshotValidateOnly').ExitCode -eq 0) `
        'The restored recipe did not let the preparation continue.'

    # A coordinator killed from outside cannot clean up after itself, so its child
    # outlives it. The next run must not write alongside that child.
    $liveRoot = Join-Path $sandbox 'live-child'
    $livePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'live-child' `
        -Mutate { param($r) & $setOutputRoot -Request $r -Root $liveRoot }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $livePath -Target 'recipePlanned').ExitCode -eq 0) `
        'The live-child setup did not reach a planned recipe.'
    $liveJournal = @(Get-ChildItem -LiteralPath (Join-Path $liveRoot 'coordinator\exchange') -File `
            -Filter '*.journal.json')[0]
    $survivor = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-Command', "Start-Sleep -Seconds 90 # $sandboxToken")
    try {
        $survivorStart = $survivor.StartTime.ToUniversalTime().ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        $liveEntry = Get-Content -LiteralPath $liveJournal.FullName -Raw | ConvertFrom-Json -Depth 16
        $liveEntry | Add-Member -NotePropertyName 'childProcessId' -NotePropertyValue $survivor.Id -Force
        $liveEntry | Add-Member -NotePropertyName 'childStartedAtUtc' -NotePropertyValue $survivorStart -Force
        $liveText = (ConvertTo-Json -InputObject $liveEntry -Depth 16 -Compress:$false) + "`n"
        [IO.File]::WriteAllBytes($liveJournal.FullName, ([Text.UTF8Encoding]::new($false)).GetBytes($liveText))
        $liveRun = Invoke-Coordinator -RequestPath $livePath
        Assert-Coordinator ($liveRun.ExitCode -eq 3) `
            "A run over a still-live recorded child exited $($liveRun.ExitCode) rather than reporting a conflict."
        Assert-Coordinator ($liveRun.Output -match 'still has a .* child') `
            "The conflict did not name the surviving child.`n$($liveRun.Output)"
    }
    finally {
        Stop-Process -Id $survivor.Id -Force -ErrorAction SilentlyContinue
        $survivor.WaitForExit(30000) | Out-Null
    }
    # And once that child is gone, the same root runs again: a liveness record is
    # a conflict while it is true and nothing at all afterwards.
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $livePath -Target 'snapshotValidateOnly').ExitCode -eq 0) `
        'The root stayed conflicted after its recorded child exited.'

    # The child hashes the recipe once on entry, and then reads it a second time
    # to decide whether an already published snapshot can be adopted. A swap in
    # between would steer adoption at bytes nothing bound, so that second read
    # carries the digest too. Exercised directly, because reproducing the window
    # end to end would mean racing the child.
    $adapterSource = Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1'
    $adapterAst = [Management.Automation.Language.Parser]::ParseFile($adapterSource, [ref]$null, [ref]$null)
    $lookupAst = $adapterAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-ShadowChildPublishedSnapshot'
        }, $true)
    Assert-Coordinator ($null -ne $lookupAst) 'The adapter no longer defines the published-snapshot lookup.'
    if ($lookupAst) {
        . ([scriptblock]::Create($lookupAst.Extent.Text))
        $script:ShadowChildUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $lookupRoot = Join-Path $sandbox 'adoption-binding'
        [void](New-Item -ItemType Directory -Force -Path $lookupRoot)
        $lookupRecipe = Join-Path $lookupRoot 'recipe.json'
        $lookupText = (ConvertTo-Json -InputObject ([pscustomobject]@{ snapshotId = 'planted-snapshot' }) -Depth 8) + "`n"
        [IO.File]::WriteAllBytes($lookupRecipe, ([Text.UTF8Encoding]::new($false)).GetBytes($lookupText))
        $lookupSha = (Get-FileHash -LiteralPath $lookupRecipe -Algorithm SHA256).Hash.ToLowerInvariant()

        $lookupError = ''
        try {
            [void](Get-ShadowChildPublishedSnapshot -RecipePath $lookupRecipe -RecipeSha256 ('0' * 64) `
                    -ReplayRoot $lookupRoot -ToolkitRoot $RepoRoot)
        }
        catch { $lookupError = [string]$_ }
        Assert-Coordinator ($lookupError -match 'hashes to .* and the request bound') `
            "The adoption lookup accepted a recipe the request never bound.`n$lookupError"

        # And the bound digest is the only thing that refuses: the same recipe,
        # correctly bound, gets as far as looking for a snapshot that is not there.
        $boundError = ''
        $boundResult = 'unset'
        try {
            $boundResult = Get-ShadowChildPublishedSnapshot -RecipePath $lookupRecipe -RecipeSha256 $lookupSha `
                -ReplayRoot $lookupRoot -ToolkitRoot $RepoRoot
        }
        catch { $boundError = [string]$_ }
        Assert-Coordinator (($boundError -eq '') -and ($null -eq $boundResult)) `
            "A correctly bound recipe did not survive the adoption lookup.`n$boundError"
    }

    # -----------------------------------------------------------------------
    Write-Host '18/21 slot authorization against the real qualification plan' -ForegroundColor Cyan
    # The one slot scenario that stands NOTHING in. The plan is built by the
    # production builder, bound to the signed declaration by the production
    # assertions, and the launch token is the one the declaration published. It
    # stops at slot1Authorized, which is the last state before anything runs, so
    # the whole check costs no model and no reviewer.
    $realAdapter = Join-Path $RepoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1'

    $authRoot = Join-Path $sandbox 'slot-authorize'
    $authPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-authorize' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $authRoot
            $r.slot.shadowSlotEnabled = $true
        }.GetNewClosure()
    Assert-Coordinator ((Invoke-Coordinator -RequestPath $authPath -Target 'runSetReady').ExitCode -eq 0) `
        'The slot-authorization setup did not reach run-set-ready.'
    $authRunSet = Join-Path $authRoot 'qualification\runset'

    # Refusals first, because none of them writes state: the same root serves
    # every one of them and then goes on to authorize for real.
    $noToken = Invoke-Coordinator -RequestPath $authPath -Target 'slot1Authorized'
    Assert-Coordinator ($noToken.ExitCode -eq 2) `
        "A launch authorized without a token exited $($noToken.ExitCode) rather than refusing."
    Assert-Coordinator ($noToken.Output -match 'launch-authorization token .* does not exist') `
        "The refusal did not name the missing token.`n$($noToken.Output)"

    [void](Publish-ShadowCoordinatorLaunchToken -RunSetDirectory $authRunSet `
            -TokenPath $fixture.LaunchTokenPath -Corrupt)
    $wrongToken = Invoke-Coordinator -RequestPath $authPath -Target 'slot1Authorized'
    Assert-Coordinator ($wrongToken.ExitCode -eq 2) `
        "A launch authorized on a token the set never published exited $($wrongToken.ExitCode)."
    Assert-Coordinator ($wrongToken.Output -match 'not the token the published run set carries') `
        "The refusal did not name the token mismatch.`n$($wrongToken.Output)"
    # And the refusal message publishes no digest, because a message that printed
    # both sides of a failed token comparison would be an oracle for guessing it.
    Assert-Coordinator ($wrongToken.Output -notmatch '[0-9a-f]{64}') `
        'The token refusal printed a 64-hex digest.'

    [void](Publish-ShadowCoordinatorLaunchToken -RunSetDirectory $authRunSet `
            -TokenPath $fixture.LaunchTokenPath)
    $disabledPath = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-disabled' `
        -Mutate { param($r) $r.slot.shadowSlotEnabled = $false }
    $disabled = Invoke-Coordinator -RequestPath $disabledPath -Target 'slot1Authorized'
    Assert-Coordinator ($disabled.ExitCode -eq 2) `
        "A slot target without the shadow flag exited $($disabled.ExitCode) rather than refusing."
    Assert-Coordinator ($disabled.Output -match "shadowSlotEnabled") `
        "The refusal did not name the disabled shadow flag.`n$($disabled.Output)"
    $slot2Path = New-CoordinatorRequestVariant -BasePath $authPath -Name 'slot-two' `
        -Mutate { param($r) $r.slot.name = 'slot2' }
    $slot2 = Invoke-Coordinator -RequestPath $slot2Path -Target 'slot1Authorized'
    Assert-Coordinator ($slot2.ExitCode -eq 2) `
        "A request naming slot2 exited $($slot2.ExitCode) rather than refusing."
    Assert-Coordinator ($slot2.Output -match 'supervises exactly one slot') `
        "The refusal did not say this build supervises one slot.`n$($slot2.Output)"

    # The default target is unchanged, which is what makes the rollback posture
    # real: a caller that does not ask for a slot never gets one.
    $defaultTarget = Invoke-Coordinator -RequestPath $authPath
    Assert-Coordinator ($defaultTarget.ExitCode -eq 0) 'A default-target run over a ready root failed.'
    $beforeAuthorize = Get-CoordinatorState -OutputRoot $authRoot
    Assert-Coordinator ($beforeAuthorize.state -ceq 'runSetReady') `
        "A default-target run advanced to '$($beforeAuthorize.state)'; the default must never launch."

    $authorized = Invoke-Coordinator -RequestPath $authPath -Target 'slot1Authorized'
    Assert-Coordinator ($authorized.ExitCode -eq 0) `
        "Authorizing a launch against the real plan failed (exit $($authorized.ExitCode)).`n$($authorized.Output)"
    $authState = Get-CoordinatorState -OutputRoot $authRoot
    Assert-Coordinator ($authState.state -ceq 'slot1Authorized' -and [int]$authState.sequence -eq 10) `
        "The durable state is '$($authState.state)' at sequence $($authState.sequence)."
    $authEvidence = @($authState.transitions | Where-Object { $_.state -ceq 'slot1Authorized' })[0].evidence
    Assert-Coordinator ([string]$authEvidence.planDigest -cmatch '^[0-9a-f]{64}$') `
        'The authorization committed no plan digest.'
    Assert-Coordinator ([string]$authEvidence.slotName -ceq 'slot1') `
        "The authorization names slot '$([string]$authEvidence.slotName)'."
    $readySetId = [string](@($beforeAuthorize.transitions | Where-Object { $_.state -ceq 'runSetVerified' })[0].evidence.setId)
    Assert-Coordinator ([string]$authEvidence.setId -ceq $readySetId) `
        'The authorization is not bound to the run set this preparation verified.'
    # The token's TEXT must appear nowhere durable. Its digest is the binding.
    $authStateText = [IO.File]::ReadAllText((Join-Path $authRoot 'coordinator\state.json'))
    $tokenText = ([IO.File]::ReadAllText($fixture.LaunchTokenPath)).Trim()
    Assert-Coordinator (-not $authStateText.Contains($tokenText)) `
        'The launch-authorization token was written into the durable state record.'
    Assert-Coordinator (-not $authorized.Output.Contains($tokenText)) `
        'The launch-authorization token was written to the console.'
    # Nothing was launched to get here.
    Assert-Coordinator (-not (Test-Path -LiteralPath (Join-Path $authRoot 'qualification\runs'))) `
        'Authorizing a launch created a run directory.'

    # -----------------------------------------------------------------------
    Write-Host '19/21 one supervised slot, halted and resumed at every slot state' -ForegroundColor Cyan
    $slotStates = @('slot1Authorized', 'slot1Launching', 'slot1Running', 'slot1TerminalObserved')
    $lifecycleRoot = Join-Path $sandbox 'slot-lifecycle'
    $lifecyclePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-lifecycle' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $lifecycleRoot
            $r.slot.shadowSlotEnabled = $true
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $lifecyclePath `
        -OutputRoot $lifecycleRoot -Label 'slot-lifecycle'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
    try {
        $expectedSequence = 9
        foreach ($state in $slotStates) {
            $expectedSequence++
            $halted = Invoke-Coordinator -RequestPath $lifecyclePath -HaltAfter $state -Target 'slot1TerminalVerified'
            Assert-Coordinator ($halted.ExitCode -eq 9) `
                "Halting after '$state' did not report a deliberate halt (exit $($halted.ExitCode)).`n$($halted.Output)"
            $durable = Get-CoordinatorState -OutputRoot $lifecycleRoot
            Assert-Coordinator ($durable -and $durable.state -ceq $state) `
                "The durable state after halting at '$state' is '$(if ($durable) { $durable.state } else { 'none' })'."
            Assert-Coordinator ($durable -and [int]$durable.sequence -eq $expectedSequence) `
                "The sequence after '$state' is $(if ($durable) { $durable.sequence } else { 'none' }), not $expectedSequence."

            # Resuming to a slot state already reached must not launch a second
            # time. The attempt record is single-use, so a second launch is not a
            # wasted run but an unrecoverable one.
            $again = Invoke-Coordinator -RequestPath $lifecyclePath -Target $state
            Assert-Coordinator ($again.ExitCode -eq 0) `
                "Resuming to an already-reached '$state' failed (exit $($again.ExitCode)).`n$($again.Output)"
            Assert-Coordinator ($again.Output -match "skip $state") `
                "Resuming to an already-reached '$state' did not report it as already recorded."
            $repeat = Get-CoordinatorState -OutputRoot $lifecycleRoot
            Assert-Coordinator ([int]$repeat.sequence -eq $expectedSequence) `
                "Resuming to an already-reached '$state' advanced the sequence to $($repeat.sequence)."
            $attempts = @(Get-ChildItem -LiteralPath (Join-Path $lifecycleRoot 'qualification\stub') `
                    -Filter 'slot*-attempt.json' -File -ErrorAction SilentlyContinue)
            Assert-Coordinator ($attempts.Count -le 1) `
                "After resuming at '$state' the run set carries $($attempts.Count) attempt records."
        }

        # The identity a resumed run would adopt has to be durable BEFORE the
        # wait, or a coordinator killed during an hour-long slot cannot name what
        # it left behind.
        $runningState = Get-CoordinatorState -OutputRoot $lifecycleRoot
        $runningEvidence = @($runningState.transitions | Where-Object { $_.state -ceq 'slot1Running' })[0].evidence
        Assert-Coordinator ([int]$runningEvidence.child.childProcessId -gt 0) `
            'The running record carries no child process id.'
        # Read as text, not through ConvertFrom-Json: PowerShell turns an ISO-8601
        # string into a DateTime, and what is under test here is the shape the
        # record actually carries.
        $runningRaw = [IO.File]::ReadAllText((Join-Path $lifecycleRoot 'coordinator\state.json'))
        Assert-Coordinator ($runningRaw -cmatch '"childStartedAtUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T[\d:.]+Z"') `
            'The running record carries no child start time, so a recycled pid could be mistaken for the child.'
        Assert-Coordinator ([string]$runningEvidence.child.childRequestSha256 -cmatch '^[0-9a-f]{64}$') `
            'The running record carries no child request digest.'

        $verified = Invoke-Coordinator -RequestPath $lifecyclePath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($verified.ExitCode -eq 0) `
            "The supervised slot did not reach a verified terminal (exit $($verified.ExitCode)).`n$($verified.Output)"
        $finalState = Get-CoordinatorState -OutputRoot $lifecycleRoot
        Assert-Coordinator ($finalState.state -ceq 'slot1TerminalVerified' -and [int]$finalState.sequence -eq 14) `
            "The durable state is '$($finalState.state)' at sequence $($finalState.sequence)."
        Assert-Coordinator (@($finalState.transitions).Count -eq 14) `
            "The state records $(@($finalState.transitions).Count) transitions rather than fourteen."

        $slotAudit = Get-Content -LiteralPath (Join-Path $lifecycleRoot 'coordinator\audit.json') -Raw |
            ConvertFrom-Json -Depth 32
        Assert-Coordinator ([bool]$slotAudit.slotSupervised) 'The audit does not record a supervised slot.'
        Assert-Coordinator ([int]$slotAudit.slotLaunchCount -eq 0) `
            ("The readiness census reports $($slotAudit.slotLaunchCount) attempt records at run-set-ready; " +
                'a ready run set is one where nothing has run yet.')
        Assert-Coordinator ([int]$slotAudit.modelInvocationCount -eq 0) `
            'The coordinator claims to have invoked a model.'
        Assert-Coordinator ([int]$slotAudit.providerWriteCount -eq 0 -and
            [string]$slotAudit.deliveryMode -ceq 'previewOnly') `
            'The audit does not record a preview-only run with no provider writes.'
        Assert-Coordinator ([string]$slotAudit.slotTerminalStatus -ceq 'complete') `
            "The audit reports terminal status '$([string]$slotAudit.slotTerminalStatus)'."
        Assert-Coordinator ([int]$slotAudit.slotAttemptCount -eq 1) `
            "The audit reports $($slotAudit.slotAttemptCount) slot attempts rather than one."
        Assert-Coordinator ([string]$slotAudit.slotTerminalSha256 -cmatch '^[0-9a-f]{64}$') `
            'The audit indexes the terminal evidence without a digest.'

        # Replaying a finished lifecycle is a no-op, including its single launch.
        $slotReplay = Invoke-Coordinator -RequestPath $lifecyclePath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($slotReplay.ExitCode -eq 0) 'Replaying a completed slot lifecycle failed.'
        Assert-Coordinator ([int](Get-CoordinatorState -OutputRoot $lifecycleRoot).sequence -eq 14) `
            'Replaying a completed slot lifecycle advanced the sequence.'
        $replayAttempts = @(Get-ChildItem -LiteralPath (Join-Path $lifecycleRoot 'qualification\stub') `
                -Filter 'slot*-attempt.json' -File)
        Assert-Coordinator ($replayAttempts.Count -eq 1) `
            "Replaying a completed slot lifecycle left $($replayAttempts.Count) attempt records."

        # -------------------------------------------------------------------
        # A killed coordinator, mid-slot, is the fault the two-phase supervisor
        # exists for. The child is left alive, the record already names it, and
        # the resumed run has to adopt it rather than start a second one.
        $killRoot = Join-Path $sandbox 'slot-kill'
        $killPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-kill' `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $killRoot
                $r.slot.shadowSlotEnabled = $true
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $killPath `
            -OutputRoot $killRoot -Label 'slot-kill'
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete' `
            -SlotTimeoutSeconds 300 -PerCallTimeoutSeconds 300 -RunDelaySeconds 30
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $killPath -HaltAfter 'slot1Launching' `
                    -Target 'slot1TerminalVerified').ExitCode -eq 9) `
            'The slot-kill setup did not halt with a launch due.'

        # Now run the launch in a process this suite can kill, and kill it while
        # the child is alive.
        $killJob = Start-Process -FilePath 'dotnet' -PassThru -WindowStyle Hidden -ArgumentList @(
            $script:CoordinatorDll, '--request', $killPath, '--target', 'slot1TerminalVerified')
        $killed = $false
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            while ([DateTime]::UtcNow -lt $deadline) {
                $probe = Get-CoordinatorState -OutputRoot $killRoot
                if ($probe -and $probe.state -ceq 'slot1Running') { break }
                Start-Sleep -Milliseconds 250
            }
            $atKill = Get-CoordinatorState -OutputRoot $killRoot
            Assert-Coordinator ($atKill -and $atKill.state -ceq 'slot1Running') `
                "The launch never recorded a running slot to kill (state '$(if ($atKill) { $atKill.state } else { 'none' })')."
            if (-not $killJob.HasExited) { Stop-Process -Id $killJob.Id -Force -ErrorAction SilentlyContinue }
            $killJob.WaitForExit(60000) | Out-Null
            $killed = $true
        }
        finally {
            if (-not $killed -and -not $killJob.HasExited) {
                Stop-Process -Id $killJob.Id -Force -ErrorAction SilentlyContinue
            }
        }
        $afterKill = Get-CoordinatorState -OutputRoot $killRoot
        Assert-Coordinator ($afterKill.state -ceq 'slot1Running') `
            "A coordinator killed mid-slot left the record at '$($afterKill.state)'."
        $resumed = Invoke-Coordinator -RequestPath $killPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($resumed.ExitCode -eq 0) `
            "The resumed run did not finish the slot it adopted (exit $($resumed.ExitCode)).`n$($resumed.Output)"
        Assert-Coordinator ($resumed.Output -match 'resume supervising recorded slot child') `
            "The resumed run did not report adopting the recorded child.`n$($resumed.Output)"
        $killAttempts = @(Get-ChildItem -LiteralPath (Join-Path $killRoot 'qualification\stub') `
                -Filter 'slot*-attempt.json' -File)
        Assert-Coordinator ($killAttempts.Count -eq 1) `
            "A kill and resume left $($killAttempts.Count) attempt records; the slot was launched twice."
        $killAudit = Get-Content -LiteralPath (Join-Path $killRoot 'coordinator\audit.json') -Raw |
            ConvertFrom-Json -Depth 32
        Assert-Coordinator ([bool]$killAudit.slotSupervision.observedAcrossRestart) `
            'The audit does not record that the observation crossed a restart.'

        # A resume that finds the attempt already spent but no running record is
        # the one case where relaunching would be catastrophic, so it refuses.
        $spentRoot = Join-Path $sandbox 'slot-spent'
        $spentPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-spent' `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $spentRoot
                $r.slot.shadowSlotEnabled = $true
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $spentPath `
            -OutputRoot $spentRoot -Label 'spent-authorization'
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $spentPath -HaltAfter 'slot1Launching' `
                    -Target 'slot1TerminalVerified').ExitCode -eq 9) `
            'The spent-authorization setup did not halt with a launch due.'
        # Something else consumes the single-use launch behind the coordinator.
        $spentStub = Join-Path $spentRoot 'qualification\stub'
        [void](New-Item -ItemType Directory -Force -Path $spentStub)
        [IO.File]::WriteAllText((Join-Path $spentStub 'slot1-attempt.json'), '{"slot":"slot1"}')
        $spentRun = Invoke-Coordinator -RequestPath $spentPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($spentRun.ExitCode -eq 2) `
            "A launch over a spent authorization exited $($spentRun.ExitCode) rather than refusing."
        Assert-Coordinator ($spentRun.Output -match 'already been used|single-use launch') `
            "The refusal did not name the spent authorization.`n$($spentRun.Output)"
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '20/21 slot terminal endings and the slot fault matrix' -ForegroundColor Cyan
    # Every case gets its own output root, because a slot's launch authorization
    # is single-use and a root that has spent it can never be reused.
    $slotCases = @(
        @{ Name = 'failed'; Mode = 'failed'; Exit = 5; State = 'slot1TerminalFailed'; Pattern = '' },
        @{ Name = 'timedout'; Mode = 'timedOut'; Exit = 5; State = 'slot1TerminalTimedOut'; Pattern = '' },
        @{ Name = 'noterminal'; Mode = 'noTerminal'; Exit = 2; State = 'slot1Running'
            Pattern = 'produced no terminal evidence' },
        @{ Name = 'nonzero'; Mode = 'nonzeroNoTerminal'; Exit = 4; State = 'slot1Running'
            Pattern = 'does not exist|left no result' },
        @{ Name = 'wrongslot'; Mode = 'wrongSlot'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'terminalSlot|is slot' },
        @{ Name = 'wrongsetid'; Mode = 'wrongSetId'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'terminalSetId|run set' },
        @{ Name = 'contradiction'; Mode = 'contradictoryTimeout'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'contradict each other' },
        @{ Name = 'writable'; Mode = 'writableTerminal'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'writable' },
        @{ Name = 'twoattempts'; Mode = 'secondAttempt'; Exit = 2; State = 'slot1TerminalObserved'
            Pattern = 'supervises exactly one' }
    )
    foreach ($case in $slotCases) {
        $caseRoot = Join-Path $sandbox "slot-$($case.Name)"
        $casePath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name "slot-$($case.Name)" `
            -Mutate {
                param($r)
                & $setOutputRoot -Request $r -Root $caseRoot
                $r.slot.shadowSlotEnabled = $true
            }.GetNewClosure()
        Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $casePath `
            -OutputRoot $caseRoot -Label "'$($case.Name)'"
        New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode $case.Mode
        try {
            $run = Invoke-Coordinator -RequestPath $casePath -Target 'slot1TerminalVerified'
            Assert-Coordinator ($run.ExitCode -eq $case.Exit) `
                "The '$($case.Name)' slot exited $($run.ExitCode) rather than $($case.Exit).`n$($run.Output)"
            $state = Get-CoordinatorState -OutputRoot $caseRoot
            Assert-Coordinator ($state -and $state.state -ceq $case.State) `
                "The '$($case.Name)' slot left the record at '$(if ($state) { $state.state } else { 'none' })' rather than '$($case.State)'."
            if ($case.Pattern) {
                Assert-Coordinator ($run.Output -match $case.Pattern) `
                    "The '$($case.Name)' refusal did not explain itself.`n$($run.Output)"
            }
            # Whatever happened, exactly one launch happened.
            $caseAttempts = @(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'qualification\stub') `
                    -Filter 'slot1-attempt.json' -File -ErrorAction SilentlyContinue)
            Assert-Coordinator ($caseAttempts.Count -eq 1) `
                "The '$($case.Name)' slot left $($caseAttempts.Count) slot1 attempt records."
        }
        finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }
    }

    # A child that never stops is stopped by the supervisor, and the kill leaves
    # no terminal evidence, so the run refuses rather than summarising a run it
    # ended itself. The plan's own budget is what bounds it.
    $hangRoot = Join-Path $sandbox 'slot-hang'
    $hangPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-hang' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $hangRoot
            $r.slot.shadowSlotEnabled = $true
            $r.slot.supervisionGraceSeconds = 30
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $hangPath `
        -OutputRoot $hangRoot -Label 'slot-hang'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'hang' `
        -SlotTimeoutSeconds 1 -PerCallTimeoutSeconds 1
    try {
        $hangRun = Invoke-Coordinator -RequestPath $hangPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($hangRun.ExitCode -eq 4) `
            "A hung slot exited $($hangRun.ExitCode) rather than reporting a stopped child.`n$($hangRun.Output)"
        Assert-Coordinator ($hangRun.Output -match 'hardDeadlineKill|activityDeadlineKill') `
            "The refusal did not name the deadline kill.`n$($hangRun.Output)"
        $hangState = Get-CoordinatorState -OutputRoot $hangRoot
        Assert-Coordinator ($hangState.state -ceq 'slot1Running') `
            "A hung slot left the record at '$($hangState.state)'."
        # The kill is a TREE kill: nothing the child started is still running.
        Start-Sleep -Seconds 2
        Assert-Coordinator ((Get-DescendantPwshCount -SandboxToken $sandboxToken) -eq 0) `
            'The deadline kill left a supervised child running.'
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # Terminal evidence rewritten between the observation and the verification.
    # The artifact is written read-only by its owner, so a changed digest is a
    # tamper rather than a race, and the run refuses on its own committed digest.
    $tamperRoot = Join-Path $sandbox 'slot-tamper'
    $tamperPath = New-CoordinatorRequestVariant -BasePath $fixture.RequestPath -Name 'slot-tamper' `
        -Mutate {
            param($r)
            & $setOutputRoot -Request $r -Root $tamperRoot
            $r.slot.shadowSlotEnabled = $true
        }.GetNewClosure()
    Initialize-SlotRunSet -Fixture $fixture -RepositoryRoot $RepoRoot -RequestPath $tamperPath `
        -OutputRoot $tamperRoot -Label 'slot-tamper'
    New-SlotStubAdapter -ToolkitCopy $fixture.ToolkitCopy -RealAdapter $realAdapter -Mode 'complete'
    try {
        Assert-Coordinator ((Invoke-Coordinator -RequestPath $tamperPath -HaltAfter 'slot1TerminalObserved' `
                    -Target 'slot1TerminalVerified').ExitCode -eq 9) `
            'The slot-tamper setup did not halt after observing terminal evidence.'
        $tamperTarget = Join-Path $tamperRoot 'qualification\stub\slot1-terminal.json'
        (Get-Item -LiteralPath $tamperTarget).IsReadOnly = $false
        $tamperText = [IO.File]::ReadAllText($tamperTarget)
        [IO.File]::WriteAllText($tamperTarget, $tamperText + ' ')
        (Get-Item -LiteralPath $tamperTarget).IsReadOnly = $true
        $tamperRun = Invoke-Coordinator -RequestPath $tamperPath -Target 'slot1TerminalVerified'
        Assert-Coordinator ($tamperRun.ExitCode -eq 2) `
            "Rewritten terminal evidence exited $($tamperRun.ExitCode) rather than refusing.`n$($tamperRun.Output)"
        Assert-Coordinator ($tamperRun.Output -match 'digests to .* and this run observed') `
            "The refusal did not name the changed evidence.`n$($tamperRun.Output)"
    }
    finally { Restore-ChildAdapter -ToolkitCopy $fixture.ToolkitCopy -RepoRoot $RepoRoot }

    # -----------------------------------------------------------------------
    Write-Host '21/21 no orphans, no external writes' -ForegroundColor Cyan
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









