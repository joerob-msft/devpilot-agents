#Requires -Version 7.0

<#
.SYNOPSIS
    OPERATOR-ONLY tool that builds, preflights, declares and runs an offline
    replay qualification set for the reviewer.

.DESCRIPTION
    A qualification run set is sealed BEFORE its runs exist, so a declaration
    made against an invocation that cannot start spoils the set. Every time that
    has happened the cause was the invocation, not the review: one slot named a
    model the agent's startup validation no longer accepted, its replacement
    omitted -RepoPath so the agent could not resolve the reviewed repository
    from a config that lives outside one, and a later set opened its cycle with
    a repository-wide pull-request list the bounded sealed snapshot does not
    carry, and one sealed snapshot recorded captured REST bodies instead of tool
    results, so it loaded and bound perfectly and no reader could consume it.
    All died before a model was ever launched - after the set had been
    declared.

    So this tool constructs the COMPLETE argument vector for every slot,
    validates everything the agent validates at startup, and then runs that
    exact vector through the AGENT ITSELF, which stops at its own model-launch
    boundary: after its config load, model resolution, replay snapshot load,
    -RepoPath resolution and the run's first source read against the snapshot,
    and before it creates any state, opens any session or launches any model.
    Only then may a run set be declared, and the declaration is sealed under a
    digest of the whole plan - every slot's argv included - so a slot can never
    run against a declaration made for a different set of commands. There is
    exactly one constructed argv per slot: the preflight and the child process
    consume the same array, so a passing preflight cannot be describing a
    different command than the one that runs.

    This tool never writes to a repository host, never contacts Azure DevOps,
    and never launches a model itself. Preflight creates no agent state; the
    only file it writes is the report an operator explicitly asks for. The
    replay it drives is permanently preview-only: every delivery, promotion and
    gate switch is refused by construction, and the constructed command is
    re-checked for them.

.PARAMETER Mode
    Preflight  - validate and print the exact commands, by running each of them
                 through the agent's own startup up to its model-launch
                 boundary. It creates no state, contacts nothing and launches
                 no model; the only file it writes is the report you ask for
                 with -PreflightReportPath. The default, because the safe thing
                 to do first is look.
    Declare    - preflight, then seal the run-set declaration under a digest of
                 this exact plan.
    RunSlot    - preflight, verify the sealed declaration under the run-set key,
                 require its plan digest to be this plan's, consume the slot's
                 one attempt, then run exactly one slot in its own state
                 directory.

.PARAMETER RepoPath
    The repository the agent operates on. ALWAYS passed to the slot, never
    inferred: a qualification config normally lives outside the reviewed
    repository, and the agent's fallback resolution fails there.

.PARAMETER ExpectedCommit / -RequiredRef
    The reviewer build under qualification. Offline replay requires a clean
    worktree, this exact HEAD, and this full ref resolving to the same commit;
    an app-created worktree's generated branch name is not required to match.

.PARAMETER SlotTimeoutSeconds
    Signed hard wall-clock deadline for one complete slot. The default is 3600
    seconds; it bounds every generalist, specialist, verification and drain
    stage together even if an inner timeout or child pipe handling fails.

.PARAMETER ProgressTimeoutSeconds
    Signed maximum interval without state-file activity after the child creates
    its state directory. Zero derives the interval from the largest configured
    model-call timeout plus 120 seconds, capped by SlotTimeoutSeconds.

.EXAMPLE
    ./tools/Invoke-ReviewerReplayQualification.ps1 -Mode Preflight `
        -RepoPath <reviewed repo> -ConfigFile <config outside the repo> `
        -OperatorAlias <alias> -PullRequestId <id> `
        -ReplayRoot <replay root> -ReplaySnapshotName <snapshot> `
        -ReplayManifestDigest <digest> -QualificationRoot <out> `
        -ExpectedCommit <40-hex> -RequiredRef refs/heads/<accepted layer>

.EXAMPLE
    ./tools/Invoke-ReviewerReplayQualification.ps1 -Mode Declare `
        -RunSetKeyPath <state>/artifact-signing.key -Purpose "closure at 6c913f0" ...

.EXAMPLE
    ./tools/Invoke-ReviewerReplayQualification.ps1 -Mode RunSlot -Slot slot1 ...
#>

[CmdletBinding()]
param(
    [ValidateSet("Preflight", "Declare", "RunSlot")][string]$Mode = "Preflight",
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$ConfigFile,
    [Parameter(Mandatory)][string]$OperatorAlias,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$PullRequestId,
    [Parameter(Mandatory)][string]$ReplayRoot,
    [Parameter(Mandatory)][string]$ReplaySnapshotName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}\z')][string]$ReplayManifestDigest,
    [Parameter(Mandatory)][string]$QualificationRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}\z')][string]$ExpectedCommit,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}\z')][string]$RequiredRef,
    [string]$ReviewerScriptPath = "",
    [string]$ToolkitRepositoryPath = "",
    [ValidateRange(2, 16)][int]$SlotCount = 2,
    [string]$ConventionSpecialistModel = "",
    [string]$ConventionVerifierModel = "",
    [ValidateRange(30, 7200)][int]$CycleTimeoutSeconds = 1800,
    [ValidateRange(30, 3600)][int]$ConventionSpecialistTimeoutSeconds = 900,
    [ValidateRange(30, 3600)][int]$VerificationTimeoutSeconds = 900,
    [ValidateRange(1, 14400)][int]$SlotTimeoutSeconds = 3600,
    [ValidateRange(0, 14400)][int]$ProgressTimeoutSeconds = 0,
    [ValidatePattern('^slot([1-9]|1[0-6])\z')][string]$Slot = "",
    [string]$RunSetKeyPath = "",
    [string]$Purpose = "",
    [string]$PreflightReportPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$toolkitRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $toolkitRoot "src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
. (Join-Path $toolkitRoot "src\Agents\reviewer\QualificationPreflight.ps1")
. (Join-Path $toolkitRoot "src\Agents\reviewer\ReplayQualification.ps1")

if (-not $ReviewerScriptPath) {
    $ReviewerScriptPath = Join-Path $toolkitRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"
}

# ---------------------------------------------------------------------------
# 1. Plan and preflight. Every mode runs this first, and a failure here happens
#    before anything is declared, written or launched.
# ---------------------------------------------------------------------------
$plan = New-ReviewerReplayQualificationPlan -RepoPath $RepoPath -ConfigFile $ConfigFile `
    -OperatorAlias $OperatorAlias -PullRequestId $PullRequestId `
    -ReplayRoot $ReplayRoot -ReplaySnapshotName $ReplaySnapshotName `
    -ReplayManifestDigest $ReplayManifestDigest -QualificationRoot $QualificationRoot `
    -ReviewerScriptPath $ReviewerScriptPath -ToolkitRepositoryPath $ToolkitRepositoryPath `
    -ExpectedCommit $ExpectedCommit -RequiredRef $RequiredRef -SlotCount $SlotCount `
    -ConventionSpecialistModel $ConventionSpecialistModel `
    -ConventionVerifierModel $ConventionVerifierModel `
    -CycleTimeoutSeconds $CycleTimeoutSeconds `
    -ConventionSpecialistTimeoutSeconds $ConventionSpecialistTimeoutSeconds `
    -VerificationTimeoutSeconds $VerificationTimeoutSeconds `
    -SlotTimeoutSeconds $SlotTimeoutSeconds -ProgressTimeoutSeconds $ProgressTimeoutSeconds
$evidence = Assert-ReviewerReplayQualificationPlan -Plan $plan
$planDigest = Get-ReviewerQualificationPlanDigest -Plan $plan

$report = [pscustomobject][ordered]@{
    kind                 = "reviewer.replay-qualification.preflight.v1"
    mode                 = $Mode
    generatedAtUtc       = [DateTime]::UtcNow.ToString("o")
    planDigest           = $planDigest
    reviewerScriptPath   = $plan.ReviewerScriptPath
    reviewerScriptSha256 = $plan.ReviewerScriptSha256
    toolkitRepository    = $plan.ToolkitRepositoryPath
    gitIdentity          = $plan.GitIdentity
    repoPath             = $plan.RepoPath
    configFile           = $plan.ConfigFile
    configSha256         = $plan.ConfigSha256
    promptFile           = $plan.PromptFilePath
    operatorAlias        = $plan.OperatorAlias
    pullRequestId        = $plan.PullRequestId
    models               = $plan.Models
    verificationPreview  = $plan.VerificationPreview
    snapshot             = $plan.Snapshot
    deliveryMode         = $plan.DeliveryMode
    promotable           = $plan.Promotable
    qualificationRoot    = $plan.QualificationRoot
    slots                = @(@($plan.Slots) | ForEach-Object {
            [pscustomobject][ordered]@{
                name        = $_.Name
                stateDir    = $_.StateDir
                arguments   = [string[]]$_.Arguments
                commandText = $_.CommandText
            }
        })
    bindingEvidence      = @($evidence)
}

Write-Host "Preflight OK - $($plan.SlotCount) slot(s) reached the agent's model-launch boundary." -ForegroundColor Green
Write-Host "  plan digest    : $planDigest" -ForegroundColor DarkGray
Write-Host "  reviewer build : $($plan.GitIdentity.head) ($($plan.GitIdentity.requiredRef), $($plan.GitIdentity.branchState))" -ForegroundColor DarkGray
Write-Host "  generalists    : $($plan.Models.First) + $($plan.Models.Second)" -ForegroundColor DarkGray
Write-Host "  specialist     : $($plan.Models.ConventionSpecialist)" -ForegroundColor DarkGray
Write-Host "  snapshot       : $($plan.Snapshot.Name) ($($plan.Snapshot.ManifestDigest.Substring(0, 12)), PR $($plan.Snapshot.PullRequestId), nonPromotable=$($plan.Snapshot.NonPromotable))" -ForegroundColor DarkGray
$firstEvidence = @($evidence)[0]
Write-Host ("  first read     : $($firstEvidence.SourceProbeTool)/$($firstEvidence.SourceProbeAction) " +
    "repositoryId=$($firstEvidence.SourceProbeRepositoryId) PR $($firstEvidence.SourceProbePullRequestId) " +
    "(recorded as $($firstEvidence.SourceProbeRequestSha256.Substring(0, 12)))") -ForegroundColor DarkGray
foreach ($plannedSlot in @($plan.Slots)) {
    Write-Host "  $($plannedSlot.Name): $($plannedSlot.CommandText)" -ForegroundColor DarkCyan
}

if ($PreflightReportPath) {
    $reportPath = Get-ReviewerQualificationFullPath -Path $PreflightReportPath -Purpose "preflight report"
    $reportDir = Split-Path -Parent $reportPath
    if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $reportDir)
    }
    $json = ConvertTo-Json -InputObject $report -Depth 12
    [IO.File]::WriteAllText($reportPath, $json, [Text.UTF8Encoding]::new($false))
    Write-Host "Preflight report: $reportPath" -ForegroundColor DarkGray
}

if ($Mode -ceq "Preflight") {
    Write-Output $report
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Shared declaration bookkeeping. The declaration is the sealed record of
#    which snapshot, which digest and how many runs the set is; a slot may only
#    run against one that matches the plan it was preflighted from.
# ---------------------------------------------------------------------------
$runSetDirectory = $plan.RunSetDirectory
$compareTool = Join-Path $toolkitRoot "tools\Compare-ReviewerReplayRuns.ps1"
if (-not (Test-Path -LiteralPath $compareTool -PathType Leaf)) {
    throw "Run-set tool '$compareTool' does not exist."
}

function Get-ExistingRunSetPath {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Directory -Filter "runset-*.json" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*.sig" } |
            ForEach-Object { $_.FullName })
}

if ($Mode -ceq "Declare") {
    if (-not $RunSetKeyPath) {
        throw "-Mode Declare requires -RunSetKeyPath naming the existing signing key the declaration is sealed under."
    }
    $keyPath = Get-ReviewerQualificationFullPath -Path $RunSetKeyPath -Purpose "run-set key"
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        throw "Run-set signing key '$keyPath' does not exist."
    }
    $existing = @(Get-ExistingRunSetPath -Directory $runSetDirectory)
    if ($existing.Count -gt 0) {
        # A second declaration in the same root is how a spoiled set gets
        # quietly replaced by a friendlier one. Refuse and name what is there.
        throw ("A run set is already declared under '$runSetDirectory': $($existing -join ', '). " +
            "Declare exactly one set per qualification root; start a new root for a new set.")
    }
    [void](New-Item -ItemType Directory -Force -Path $runSetDirectory)
    $declared = & $compareTool -DeclareRunSet -SnapshotName $plan.Snapshot.Name `
        -SnapshotManifestDigest $plan.Snapshot.ManifestDigest -PlannedRunCount $plan.SlotCount `
        -PlanDigest $planDigest -Purpose $Purpose -KeyPath $keyPath -OutputDirectory $runSetDirectory
    $declaredPath = @($declared | Where-Object { $_ -is [string] } | Select-Object -Last 1)
    Write-Host "Declared run set after a passing preflight: $declaredPath" -ForegroundColor Green
    Write-Output $declaredPath
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Slot execution. One slot, one state directory, one attempt.
# ---------------------------------------------------------------------------
if (-not $Slot) { throw "-Mode RunSlot requires -Slot (for example, slot1)." }
$target = @(@($plan.Slots) | Where-Object { $_.Name -ceq $Slot }) | Select-Object -First 1
if (-not $target) {
    throw "Slot '$Slot' is not part of this $($plan.SlotCount)-slot plan."
}
if (-not $RunSetKeyPath) {
    throw ("-Mode RunSlot requires -RunSetKeyPath. The declaration decides whether this slot may run at all, so " +
        "it is verified cryptographically rather than read as text.")
}
$runSetKeyPath = Get-ReviewerQualificationFullPath -Path $RunSetKeyPath -Purpose "run-set key"
if (-not (Test-Path -LiteralPath $runSetKeyPath -PathType Leaf)) {
    throw "Run-set signing key '$runSetKeyPath' does not exist."
}
$declarations = @(Get-ExistingRunSetPath -Directory $runSetDirectory)
if ($declarations.Count -ne 1) {
    throw ("Expected exactly one sealed run-set declaration under '$runSetDirectory' before a slot runs; " +
        "found $($declarations.Count). Declare the set first (-Mode Declare).")
}
# Verified under the key, by the tool that seals declarations, BEFORE anything
# in it is believed. An envelope parsed as text is a file anybody could have
# written; a signature check is the only thing that makes it a declaration.
$verifiedOutput = & $compareTool -VerifyRunSet -RunSetPath $declarations[0] -KeyPath $runSetKeyPath
$verifiedJson = @(@($verifiedOutput) |
        Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith("{") } |
        Select-Object -Last 1)
if (@($verifiedJson).Count -ne 1) {
    throw "Verification of '$($declarations[0])' returned no manifest; the declaration did not verify under '$runSetKeyPath'."
}
$declaration = [string]$verifiedJson[0] | ConvertFrom-Json
if ([string]$declaration.snapshotName -cne [string]$plan.Snapshot.Name -or
    [string]$declaration.snapshotManifestDigest -cne [string]$plan.Snapshot.ManifestDigest) {
    throw ("The sealed declaration names snapshot '$($declaration.snapshotName)' at digest " +
        "$($declaration.snapshotManifestDigest); this plan replays '$($plan.Snapshot.Name)' at " +
        "$($plan.Snapshot.ManifestDigest). A slot never runs against a declaration it does not match.")
}
if ([int]$declaration.plannedRunCount -ne [int]$plan.SlotCount) {
    throw ("The sealed declaration plans $([int]$declaration.plannedRunCount) run(s) and this plan has " +
        "$($plan.SlotCount) slot(s).")
}
# The declaration was sealed FOR a plan, not merely for a snapshot. Same
# snapshot, different models - or a different reviewed repository, or a
# different agent build - is a different qualification wearing this one's seal.
$declaredPlanDigest = ""
if ($declaration.PSObject.Properties["planDigest"]) { $declaredPlanDigest = [string]$declaration.planDigest }
if (-not $declaredPlanDigest) {
    throw ("The sealed declaration $($declaration.setId) carries no plan digest, so it cannot say which commands " +
        "it authorized. Declare a new set with this build of the tool.")
}
if ($declaredPlanDigest -cne $planDigest) {
    throw ("The sealed declaration $($declaration.setId) was made for plan $declaredPlanDigest and this plan " +
        "hashes to $planDigest. Every slot of a set runs the plan that was declared.")
}

# An attempted slot is immutable. Any state at all - even an empty directory
# somebody created by hand - means this slot's identity is already spoken for.
$attemptPath = Join-Path $plan.RunDirectory "$($target.Name)-attempt.json"
if (Test-Path -LiteralPath $attemptPath) {
    throw ("Slot '$($target.Name)' has already been attempted: '$attemptPath' exists. An attempt is consumed when " +
        "it is made, whether or not the run started; qualify into a fresh root.")
}
if (Test-Path -LiteralPath $target.StateDir) {
    throw ("Slot state directory '$($target.StateDir)' already exists. A slot is attempted once; " +
        "use a fresh qualification root rather than re-running it.")
}
foreach ($outputPath in @($target.ConsolePath, $target.ErrorPath, $target.ExitPath, $target.TerminalPath)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw ("Slot output '$outputPath' already exists. A slot is attempted once; use a fresh qualification " +
            "root rather than overwriting terminal evidence.")
    }
}
[void](New-Item -ItemType Directory -Force -Path $plan.RunDirectory)
# The attempt is consumed HERE, before the child exists, and in run accounting
# rather than in the agent's state directory. A slot whose process fails to
# start leaves no agent state at all - and an attempt recorded only by that
# state would be an attempt nobody could see, free to be quietly retried until
# one of them started. Created exclusively, so two runners racing for the same
# slot cannot both win, and read-only afterwards.
$attempt = [pscustomobject][ordered]@{
    kind          = "reviewer.replay-qualification.attempt.v1"
    slot          = $target.Name
    setId         = [string]$declaration.setId
    planDigest    = $planDigest
    declaration   = $declarations[0]
    snapshotName  = $plan.Snapshot.Name
    snapshotDigest = $plan.Snapshot.ManifestDigest
    stateDir      = $target.StateDir
    commandText   = $target.CommandText
    arguments     = [string[]]@($target.Arguments)
    slotTimeoutSeconds = [int]$plan.SlotTimeoutSeconds
    progressTimeoutSeconds = [int]$plan.ProgressTimeoutSeconds
    attemptedAtUtc = [DateTime]::UtcNow.ToString("o")
}
$attemptJson = ConvertTo-Json -InputObject $attempt -Depth 8
try {
    $attemptStream = [IO.File]::Open($attemptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
}
catch [IO.IOException] {
    throw ("Slot '$($target.Name)' has already been attempted: '$attemptPath' exists. An attempt is consumed when " +
        "it is made, whether or not the run started; qualify into a fresh root.")
}
try {
    $attemptBytes = [Text.UTF8Encoding]::new($false).GetBytes($attemptJson)
    $attemptStream.Write($attemptBytes, 0, $attemptBytes.Length)
}
finally { $attemptStream.Dispose() }
Set-ItemProperty -LiteralPath $attemptPath -Name IsReadOnly -Value $true
Write-Host "Attempt recorded (immutable): $attemptPath" -ForegroundColor DarkGray

# The state directory is the agent's to create. Pre-creating it here would put
# an empty directory in the world for a slot whose process never started, and
# the next reader cannot tell that from a run that began and died.

$pwshPath = Get-ReviewerQualificationPwshPath
Write-Host "Running $($target.Name): $($target.CommandText)" -ForegroundColor Cyan
# THE preflighted array, unchanged. Nothing rebuilds a similar command here.
$processArguments = @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $plan.ReviewerScriptPath) +
    [string[]]@($target.Arguments)
$run = Invoke-TimedProcess -FilePath $pwshPath -ArgumentList $processArguments `
    -CaptureStdOut -CaptureStdErr -WorkingDirectory $plan.QualificationRoot `
    -TimeoutSeconds ([int]$plan.SlotTimeoutSeconds) -ProgressPath $target.StateDir `
    -ProgressTimeoutSeconds ([int]$plan.ProgressTimeoutSeconds)
$stdout = [string]$run.StdOut
$stderr = [string]$run.StdErr
$exitCode = if ([bool]$run.TimedOut) { 124 } else { [int]$run.ExitCode }
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($target.ConsolePath, $stdout, $utf8)
[IO.File]::WriteAllText($target.ErrorPath, $stderr, $utf8)
[IO.File]::WriteAllText($target.ExitPath, "$exitCode", $utf8)
$terminal = [pscustomobject][ordered]@{
    kind                   = "reviewer.replay-qualification.terminal.v1"
    slot                   = $target.Name
    setId                  = [string]$declaration.setId
    planDigest             = $planDigest
    status                 = $(if ([bool]$run.TimedOut) { "timedOut" } elseif ($exitCode -eq 0) { "complete" } else { "failed" })
    exitCode               = $exitCode
    timedOut               = [bool]$run.TimedOut
    timeoutReason          = [string]$run.TimeoutReason
    childProcessId         = [int]$run.ProcessId
    startedAtUtc           = [string]$run.StartedAtUtc
    endedAtUtc             = [string]$run.EndedAtUtc
    lastProgressUtc        = [string]$run.LastProgressUtc
    slotTimeoutSeconds     = [int]$plan.SlotTimeoutSeconds
    progressTimeoutSeconds = [int]$plan.ProgressTimeoutSeconds
}
$terminalBytes = $utf8.GetBytes((ConvertTo-Json -InputObject $terminal -Depth 5))
$terminalStream = [IO.File]::Open($target.TerminalPath, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $terminalStream.Write($terminalBytes, 0, $terminalBytes.Length) }
finally { $terminalStream.Dispose() }
Set-ItemProperty -LiteralPath $target.TerminalPath -Name IsReadOnly -Value $true
Write-Host $stdout
if ($stderr) { Write-Host $stderr -ForegroundColor DarkYellow }
if ([bool]$run.TimedOut) {
    Write-Warning ("$($target.Name) terminated at its $($run.TimeoutReason) boundary; immutable evidence is at " +
        "'$($target.TerminalPath)'.")
}
Write-Host "$($target.Name) exited $exitCode; console at $($target.ConsolePath)." -ForegroundColor DarkGray
exit $exitCode
