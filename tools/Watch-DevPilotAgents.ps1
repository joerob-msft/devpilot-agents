#requires -Version 7.0

<#
.SYNOPSIS
    Launches DevPilot agents and observes them in one dashboard.

.DESCRIPTION
    Starts the reviewer, review-handler, or both in isolated child processes
    and observes their event streams. Runs are preview-only unless Operational
    is passed. Operational binds the agents' fixed production capability set;
    notification delivery remains independently opt-in per role. By default
    each selected agent runs one cycle. Continuous keeps the agents cycling
    until the dashboard exits, then stops every process tree owned by this
    launcher. AttachOnly observes an existing state root without launching an
    agent.

    Golden selects the recommended full workstation setup in one switch: both
    agents, cycling continuously, operational, both manual dashboard roles with
    manual reviewer writes and the review-handler code-update tier. It never
    enables Teams notifications, the reviewer approval vote, or review-handler
    auto-complete. PreviewOnly is a terminal ceiling that outranks every other
    switch, including Golden: it strips every write and notification capability
    from the automatic agents and from both manual broker roles, and locks the
    delegable capability so no grant can ever widen it back for that launch.
    Once forces a single cycle even under Golden.

.EXAMPLE
    .\tools\Watch-DevPilotAgents.ps1 -Agent Both -Continuous

.EXAMPLE
    .\tools\Watch-DevPilotAgents.ps1 -Agent ReviewHandler -Continuous -IntervalSeconds 60

.EXAMPLE
    .\tools\Watch-DevPilotAgents.ps1 -Golden

.EXAMPLE
    .\tools\Watch-DevPilotAgents.ps1 -Golden -PreviewOnly

.EXAMPLE
    .\tools\Watch-DevPilotAgents.ps1 -AttachOnly -StateDir C:\DevPilot\watch
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low', DefaultParameterSetName = 'Launch')]
param(
    [Parameter(ParameterSetName = 'Launch')]
    [ValidateSet('Reviewer', 'ReviewHandler', 'Both')]
    [string]$Agent = 'Both',

    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [switch]$AttachOnly,

    [Parameter(ParameterSetName = 'Launch')]
    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [ValidateNotNullOrEmpty()]
    [string]$StateDir,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateNotNullOrEmpty()]
    [string]$DurableStateRoot,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateNotNullOrEmpty()]
    [string]$LeaseRoot,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateNotNullOrEmpty()]
    [string]$ReviewerConfigFile,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateNotNullOrEmpty()]
    [string]$ReviewHandlerConfigFile,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(0, 2147483647)]
    [int]$ReviewerPullRequestId = 0,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(0, 2147483647)]
    [int]$ReviewHandlerPullRequestId = 0,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Continuous,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Once,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Golden,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$PreviewOnly,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Operational,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableReviewerTeamsNotifications,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableReviewHandlerTeamsNotifications,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableReviewHandlerCodeUpdates,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableManualReviewer,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableManualReviewHandler,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableManualReviewerWrites,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableManualReviewHandlerCodeUpdates,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(30, 86400)]
    [int]$IntervalSeconds = 900,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$OperatorAlias,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ReviewerAgentName,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ReviewHandlerAgentName,

    [Parameter(ParameterSetName = 'Launch')]
    [string]$ReviewerModel,

    [Parameter(ParameterSetName = 'Launch')]
    [string]$ReviewHandlerModel,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$IncludeOwnPullRequests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolkitRoot = Split-Path $PSScriptRoot -Parent
$harnessManifest = Join-Path $toolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
Import-Module $harnessManifest -Force
$dashboardLauncher = Join-Path $PSScriptRoot 'Start-DevPilotDashboard.ps1'
$reviewerScript = Join-Path $toolkitRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
$reviewHandlerScript = Join-Path $toolkitRoot 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1'
# Sourced from the harness's single-source-of-truth descriptor rather than declared here, so this
# script can never independently drift from the broker/child ceilings (see
# Get-AgentHarnessCapabilityDescriptor).
$reviewerCapabilityDescriptor = Get-AgentHarnessCapabilityDescriptor -Role reviewer
$reviewHandlerCapabilityDescriptor = Get-AgentHarnessCapabilityDescriptor -Role review-handler
$reviewerOperationalCapabilities = @($reviewerCapabilityDescriptor.operationalTiers.base)
$reviewHandlerOperationalCapabilities = @($reviewHandlerCapabilityDescriptor.operationalTiers.base)
$reviewHandlerCodeUpdateCapabilities = @($reviewHandlerCapabilityDescriptor.operationalTiers.codeUpdate)
# The one capability each role is never granted by default (and the only one delegation could ever
# widen) is always denied for both the automatic and the manual ceiling.
$reviewerMandatoryDenies = @($reviewerCapabilityDescriptor.delegableDefaultOff)
$reviewHandlerMandatoryDenies = @($reviewHandlerCapabilityDescriptor.delegableDefaultOff)
# The terminal preview-only lock for each role, projected by the same single-source-of-truth
# descriptor (issue #114). Nothing is declared here either: a preview launch can only ever lock
# names the harness already knows this role could otherwise be granted.
$reviewerPreviewAbsoluteDenies = @((Get-AgentHarnessCapabilityDescriptor -Role reviewer -PreviewOnly).absoluteDenies)
$reviewHandlerPreviewAbsoluteDenies = @((Get-AgentHarnessCapabilityDescriptor -Role review-handler -PreviewOnly).absoluteDenies)

function Close-OwnedAgentProcess {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$Role
    )
    $Process.Refresh()
    if ($Process.HasExited) { return }
    Write-Host "Stopping $Role PID $($Process.Id)." -ForegroundColor Yellow
    try {
        $Process.Kill($true)
    }
    catch [System.InvalidOperationException] {
        $Process.Refresh()
        if (-not $Process.HasExited) { throw }
    }
    if (-not $Process.WaitForExit(5000)) {
        throw "$Role PID $($Process.Id) could not be stopped."
    }
}

function Resolve-WatchLaunchPolicy {
    <#
        issue #114: the ONE place that turns the operator's switches into the effective launch
        policy. Everything downstream -- the automatic agents' argv, the broker descriptor's manual
        role entries, the pre-spawn disclosure, and the dashboard's LaunchMode -- is derived from
        this single result, so an automatic child and a manual (broker-dispatched) child of the same
        launch can never end up with different ceilings.

        Pure: no file system, no process, no host output. Every conflicting or impossible switch
        combination is reported as an actionable failure string rather than thrown, so the caller
        can aggregate them with the rest of its static preflight and report all of them at once.

        Precedence, applied in this order:
          1. Golden supplies defaults only (operational, continuous, both manual roles, manual
             reviewer writes, the review-handler code-update tier). It never enables Teams
             notifications, the reviewer approval vote, or review-handler auto-complete.
          2. Explicit switches override those defaults (-Once overrides Golden's continuity).
          3. PreviewOnly is terminal and applied LAST: it strips every write/notification
             capability from the automatic argv and from both manual role entries, and records the
             role's whole lockable capability set (including its one delegable capability) as
             absolute denies for the life of the launch. Combining it with an EXPLICIT switch that
             asks for a write is a conflict, never a silent strip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Reviewer', 'ReviewHandler', 'Both')][string]$Agent,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExplicitParameters,
        [bool]$Golden,
        [bool]$PreviewOnly,
        [bool]$Operational,
        [bool]$Continuous,
        [bool]$Once,
        [bool]$EnableReviewerTeamsNotifications,
        [bool]$EnableReviewHandlerTeamsNotifications,
        [bool]$EnableReviewHandlerCodeUpdates,
        [bool]$EnableManualReviewer,
        [bool]$EnableManualReviewHandler,
        [bool]$EnableManualReviewerWrites,
        [bool]$EnableManualReviewHandlerCodeUpdates,
        [int]$ReviewerPullRequestId,
        [int]$ReviewHandlerPullRequestId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewerOperationalCapabilities,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewHandlerOperationalCapabilities,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewHandlerCodeUpdateCapabilities,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ReviewerMandatoryDenies,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ReviewHandlerMandatoryDenies,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewerPreviewAbsoluteDenies,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReviewHandlerPreviewAbsoluteDenies
    )
    $failures = [Collections.Generic.List[string]]::new()
    $explicit = { param([string]$Name) return @($ExplicitParameters) -ccontains $Name }

    if ((& $explicit 'Operational') -and (& $explicit 'PreviewOnly')) {
        [void]$failures.Add('-PreviewOnly cannot be combined with -Operational: preview is a terminal ceiling, not a mode that can be partially relaxed. Drop one of the two switches.')
    }
    if ((& $explicit 'Continuous') -and (& $explicit 'Once')) {
        [void]$failures.Add('-Once cannot be combined with -Continuous: choose exactly one cycling mode.')
    }

    $operational = -not $PreviewOnly -and ($Operational -or $Golden)
    $continuous = if ($Once) { $false } elseif ($Continuous) { $true } else { [bool]$Golden }
    $launchReviewer = $Agent -in @('Reviewer', 'Both')
    $launchReviewHandler = $Agent -in @('ReviewHandler', 'Both')
    if ($Golden -and (& $explicit 'Agent') -and $Agent -ne 'Both') {
        [void]$failures.Add("-Golden always launches both agents and cannot be combined with -Agent $Agent.")
    }

    if ($continuous -and ($ReviewerPullRequestId -gt 0 -or $ReviewHandlerPullRequestId -gt 0)) {
        [void]$failures.Add('A pull request ID cannot be combined with -Continuous because that would repeatedly process one pull request. Add -Once to process it exactly once.')
    }
    if ((& $explicit 'ReviewerPullRequestId') -and $ReviewerPullRequestId -le 0) {
        [void]$failures.Add('ReviewerPullRequestId must be greater than zero when explicitly provided.')
    }
    if ((& $explicit 'ReviewHandlerPullRequestId') -and $ReviewHandlerPullRequestId -le 0) {
        [void]$failures.Add('ReviewHandlerPullRequestId must be greater than zero when explicitly provided.')
    }
    if ((& $explicit 'ReviewerPullRequestId') -and -not $launchReviewer) {
        [void]$failures.Add('-ReviewerPullRequestId requires -Agent Reviewer or -Agent Both.')
    }
    if ((& $explicit 'ReviewHandlerPullRequestId') -and -not $launchReviewHandler) {
        [void]$failures.Add('-ReviewHandlerPullRequestId requires -Agent ReviewHandler or -Agent Both.')
    }
    if ($EnableReviewerTeamsNotifications -and -not $launchReviewer) {
        [void]$failures.Add('-EnableReviewerTeamsNotifications requires -Agent Reviewer or -Agent Both.')
    }
    if ($EnableReviewHandlerTeamsNotifications -and -not $launchReviewHandler) {
        [void]$failures.Add('-EnableReviewHandlerTeamsNotifications requires -Agent ReviewHandler or -Agent Both.')
    }
    if ((& $explicit 'EnableReviewHandlerCodeUpdates') -and -not $launchReviewHandler) {
        [void]$failures.Add('-EnableReviewHandlerCodeUpdates requires -Agent ReviewHandler or -Agent Both.')
    }
    # Only EXPLICIT side-effect switches are a conflict. Golden's own implied writes are not: they
    # are defaults, and -PreviewOnly is documented to override them.
    $explicitSideEffects = @('EnableReviewerTeamsNotifications', 'EnableReviewHandlerTeamsNotifications',
        'EnableReviewHandlerCodeUpdates') | Where-Object { & $explicit $_ }
    if (-not $operational -and @($explicitSideEffects).Count -gt 0) {
        [void]$failures.Add('Notifications and review-handler code updates require -Operational. Preview runs never enable side effects.')
    }
    $explicitManualWrites = @('EnableManualReviewerWrites', 'EnableManualReviewHandlerCodeUpdates') |
        Where-Object { & $explicit $_ }
    if ($PreviewOnly -and @($explicitManualWrites).Count -gt 0) {
        [void]$failures.Add("-PreviewOnly cannot be combined with $(@($explicitManualWrites | ForEach-Object { "-$_" }) -join ', '): a preview launch grants no manual write capability at all.")
    }

    # Golden turns on the manual (dashboard-dispatched) role for each agent it actually launches;
    # an explicit -EnableManual* switch stays independent of -Agent, exactly as before.
    $manualReviewer = $EnableManualReviewer -or ($Golden -and $launchReviewer)
    $manualReviewHandler = $EnableManualReviewHandler -or ($Golden -and $launchReviewHandler)
    $manualReviewerWrites = -not $PreviewOnly -and ($EnableManualReviewerWrites -or ($Golden -and $manualReviewer))
    $manualReviewHandlerCodeUpdates = -not $PreviewOnly -and
        ($EnableManualReviewHandlerCodeUpdates -or ($Golden -and $manualReviewHandler))
    $reviewHandlerCodeUpdates = $operational -and ($EnableReviewHandlerCodeUpdates -or ($Golden -and $launchReviewHandler))

    # Every set below starts as a real empty array and is only ever added to, so an "off" set is a
    # genuine empty array rather than a statement that produced no output.
    $reviewerAutomatic = @()
    if ($operational -and $launchReviewer) { $reviewerAutomatic = @($ReviewerOperationalCapabilities) }
    $reviewHandlerAutomatic = @()
    if ($operational -and $launchReviewHandler) {
        $reviewHandlerAutomatic = @($ReviewHandlerOperationalCapabilities)
        if ($reviewHandlerCodeUpdates) { $reviewHandlerAutomatic += @($ReviewHandlerCodeUpdateCapabilities) }
    }
    $reviewerAbsoluteDenies = @()
    $reviewHandlerAbsoluteDenies = @()
    if ($PreviewOnly) {
        $reviewerAbsoluteDenies = @($ReviewerPreviewAbsoluteDenies | Sort-Object -Unique)
        $reviewHandlerAbsoluteDenies = @($ReviewHandlerPreviewAbsoluteDenies | Sort-Object -Unique)
    }
    $reviewerManualCapabilities = @()
    if ($manualReviewerWrites) { $reviewerManualCapabilities = @($ReviewerOperationalCapabilities) }
    # Historically the manual review-handler's base (reply/requeue) tier was unconditional. It stays
    # unconditional outside a preview launch; a preview launch strips it like every other write.
    $reviewHandlerManualCapabilities = @()
    if (-not $PreviewOnly) {
        $reviewHandlerManualCapabilities = @($ReviewHandlerOperationalCapabilities)
        if ($manualReviewHandlerCodeUpdates) {
            $reviewHandlerManualCapabilities += @($ReviewHandlerCodeUpdateCapabilities)
        }
    }
    # A live broker is authority-bearing even when its initial capability set is empty: Settings
    # may still grant a non-terminally-denied capability. Only PreviewOnly makes that path inert.
    $hasManualAuthority = -not $PreviewOnly -and ($manualReviewer -or $manualReviewHandler)

    return [ordered]@{
        Agent = $Agent
        LaunchReviewer = $launchReviewer
        LaunchReviewHandler = $launchReviewHandler
        Golden = [bool]$Golden
        PreviewOnly = [bool]$PreviewOnly
        Operational = $operational
        Continuous = $continuous
        LaunchMode = $(if ($operational -or $hasManualAuthority) { 'operational' } else { 'preview' })
        ReviewHandlerCodeUpdates = $reviewHandlerCodeUpdates
        ReviewerTeamsNotifications = $operational -and $EnableReviewerTeamsNotifications
        ReviewHandlerTeamsNotifications = $operational -and $EnableReviewHandlerTeamsNotifications
        Reviewer = [ordered]@{
            Role = 'reviewer'
            AutomaticCapabilities = @($reviewerAutomatic)
            ManualEnabled = $manualReviewer
            ManualWrites = $manualReviewerWrites
            ManualCapabilities = @($reviewerManualCapabilities)
            MandatoryDenies = @(@($ReviewerMandatoryDenies) + $reviewerAbsoluteDenies | Sort-Object -Unique)
            AbsoluteDenies = @($reviewerAbsoluteDenies)
        }
        ReviewHandler = [ordered]@{
            Role = 'review-handler'
            AutomaticCapabilities = @($reviewHandlerAutomatic)
            ManualEnabled = $manualReviewHandler
            ManualWrites = $manualReviewHandlerCodeUpdates
            ManualCapabilities = @($reviewHandlerManualCapabilities)
            MandatoryDenies = @(@($ReviewHandlerMandatoryDenies) + $reviewHandlerAbsoluteDenies | Sort-Object -Unique)
            AbsoluteDenies = @($reviewHandlerAbsoluteDenies)
        }
        Failures = @($failures.ToArray())
    }
}

function Get-WatchTrustRemediation {
    <#
        Copy/paste remediation for exactly ONE unsafe path. This launcher never repairs an ACL or
        a mode itself: silently widening or narrowing an operator's own file permissions is a
        change they never asked for, and the failure it hides (a toolkit or config file another
        principal can write) is precisely the one this preflight exists to surface.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows) {
        $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        return @(
            "icacls `"$Path`" /inheritance:r",
            "icacls `"$Path`" /grant:r `"${account}:(F)`" `"SYSTEM:(F)`" `"BUILTIN\Administrators:(F)`""
        )
    }
    return @("chown `"`$(id -un)`" '$Path'", "chmod go-w '$Path'")
}

function Get-PriorWatchStateDir {
    <#
        issue #114: the most recent prior launch state roots, so the dashboard can show history
        beside the current run. Every candidate is independently re-verified before it is offered:
        it must be a direct child of the canonical watch root with this launcher's own launch-id
        shape, must not be (or traverse) a link/reparse point, and must still carry the private
        watch-state ownership/ACL -- all asserted by Resolve-AgentTrustedRoot, never assumed from
        the fact that this launcher created it earlier. Durable-state and lease roots are excluded
        structurally: they are passed in as ExcludedRoots and can never appear in the result.

        An unsafe or unreadable prior root is a warning and an exclusion, never fatal: history is a
        convenience, and one poisoned leftover directory must not block a launch.
    #>
    param(
        [Parameter(Mandatory)][string]$WatchRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentStateDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExcludedRoots,
        [ValidateRange(1, 100)][int]$MaximumCount = 20
    )
    $root = [IO.Path]::GetFullPath($WatchRoot)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return , @() }
    $selected = [Collections.Generic.List[string]]::new()
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$' } |
        Sort-Object -Property Name -Descending)
    foreach ($candidate in $candidates) {
        if ($selected.Count -ge $MaximumCount) { break }
        $path = [IO.Path]::GetFullPath($candidate.FullName)
        if (-not (Test-AgentPathWithin -Path $path -Root $root)) { continue }
        if ($CurrentStateDir -and (Test-AgentPathWithin -Path $path -Root $CurrentStateDir)) { continue }
        $overlapsReservedRoot = $false
        foreach ($other in @($ExcludedRoots)) {
            if (-not $other) { continue }
            if ((Test-AgentPathWithin -Path $path -Root $other) -or (Test-AgentPathWithin -Path $other -Root $path)) {
                $overlapsReservedRoot = $true
                break
            }
        }
        if ($overlapsReservedRoot) { continue }
        try {
            $trusted = Resolve-AgentTrustedRoot -Path $path -Kind watch-state -RepositoryRoot $RepositoryRoot `
                -DisallowedRoots @($ExcludedRoots)
        }
        catch {
            Write-Warning "Excluding prior launch history '$path' from the dashboard: $($_.Exception.Message)"
            continue
        }
        [void]$selected.Add($trusted)
    }
    return , @($selected.ToArray())
}

function Assert-WatchManualRolePolicy {
    <#
        In-memory validation of one manual role entry BEFORE any state root, descriptor file, or
        child process exists. Mirrors the broker's own Assert-RoleCapabilityPolicy exactly, so a
        descriptor this launcher would be unable to serve is never written to disk in the first
        place.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [Parameter(Mandatory)][Collections.IDictionary]$RoleEntry
    )
    $harnessRole = Get-AgentHarnessCapabilityDescriptor -Role $Role
    $lockable = @(@($harnessRole.allowedManualCapabilities) + @($harnessRole.delegableDefaultOff))
    $capabilities = @($RoleEntry.capabilities)
    $mandatoryDenies = @($RoleEntry.mandatoryDenies)
    $absoluteDenies = @($RoleEntry.absoluteDenies)
    if ($mandatoryDenies -cnotcontains $harnessRole.delegableDefaultOff -or
        @($capabilities | Where-Object { $harnessRole.allowedManualCapabilities -cnotcontains $_ }).Count -gt 0 -or
        @($capabilities | Where-Object { $mandatoryDenies -ccontains $_ }).Count -gt 0 -or
        @($absoluteDenies | Where-Object { $lockable -cnotcontains $_ }).Count -gt 0 -or
        @($absoluteDenies | Where-Object { $capabilities -ccontains $_ }).Count -gt 0 -or
        @($absoluteDenies | Where-Object { $mandatoryDenies -cnotcontains $_ }).Count -gt 0) {
        throw "The manual '$Role' capability policy this launcher built is inconsistent; refusing to write a broker descriptor."
    }
}

if ($AttachOnly) {
    $StateDir = [IO.Path]::GetFullPath($StateDir)
    $StateDir = Resolve-AgentTrustedRoot -Path $StateDir -Kind watch-state `
        -RepositoryRoot ([IO.Path]::GetFullPath($toolkitRoot)) -Create
    $global:LASTEXITCODE = 0
    & $dashboardLauncher -StateDir $StateDir -ValidateOnly
    if ($LASTEXITCODE -ne 0) { throw "Dashboard preflight failed with code $LASTEXITCODE." }
    & $dashboardLauncher -StateDir $StateDir
    if ($LASTEXITCODE -ne 0) { throw "Dashboard exited with code $LASTEXITCODE." }
    return
}

# ---------------------------------------------------------------------------
# Static preflight (issue #114). Nothing below this block creates a state root, a durable/lease
# root, a broker descriptor, or a child process: every switch conflict, trust failure, and missing
# input is resolved and AGGREGATED first, so one run reports every actionable problem instead of
# one per invocation, and a rejected launch leaves no residue at all.
# ---------------------------------------------------------------------------
$launch = Resolve-WatchLaunchPolicy -Agent $Agent -ExplicitParameters @($PSBoundParameters.Keys) `
    -Golden:$Golden -PreviewOnly:$PreviewOnly -Operational:$Operational -Continuous:$Continuous -Once:$Once `
    -EnableReviewerTeamsNotifications:$EnableReviewerTeamsNotifications `
    -EnableReviewHandlerTeamsNotifications:$EnableReviewHandlerTeamsNotifications `
    -EnableReviewHandlerCodeUpdates:$EnableReviewHandlerCodeUpdates `
    -EnableManualReviewer:$EnableManualReviewer -EnableManualReviewHandler:$EnableManualReviewHandler `
    -EnableManualReviewerWrites:$EnableManualReviewerWrites `
    -EnableManualReviewHandlerCodeUpdates:$EnableManualReviewHandlerCodeUpdates `
    -ReviewerPullRequestId $ReviewerPullRequestId -ReviewHandlerPullRequestId $ReviewHandlerPullRequestId `
    -ReviewerOperationalCapabilities $reviewerOperationalCapabilities `
    -ReviewHandlerOperationalCapabilities $reviewHandlerOperationalCapabilities `
    -ReviewHandlerCodeUpdateCapabilities $reviewHandlerCodeUpdateCapabilities `
    -ReviewerMandatoryDenies $reviewerMandatoryDenies -ReviewHandlerMandatoryDenies $reviewHandlerMandatoryDenies `
    -ReviewerPreviewAbsoluteDenies $reviewerPreviewAbsoluteDenies `
    -ReviewHandlerPreviewAbsoluteDenies $reviewHandlerPreviewAbsoluteDenies
$launchReviewer = $launch.LaunchReviewer
$launchReviewHandler = $launch.LaunchReviewHandler
$preflightFailures = [Collections.Generic.List[string]]::new()
$preflightRemediation = [Collections.Generic.List[string]]::new()
foreach ($failure in @($launch.Failures)) { [void]$preflightFailures.Add($failure) }

function Add-WatchTrustedFileFailure {
    <#
        Records ONE trusted-file failure plus its scoped, copy/paste remediation instead of throwing
        immediately, so the operator sees every unsafe path in a single run. Never repairs anything.
    #>
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord
    )
    [void]$preflightFailures.Add("$Description is not trusted: $($ErrorRecord.Exception.Message)")
    [void]$preflightRemediation.Add("$Description ($Path):")
    foreach ($command in Get-WatchTrustRemediation -Path $Path) { [void]$preflightRemediation.Add("    $command") }
}

$repositoryRoot = [IO.Path]::GetFullPath($toolkitRoot)
$defaultConfigRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) '.github\copilot\agents'))
$reviewerScriptPath = [IO.Path]::GetFullPath($reviewerScript)
$reviewHandlerScriptPath = [IO.Path]::GetFullPath($reviewHandlerScript)
try {
    $reviewerScript = Assert-AgentTrustedFile -Path $reviewerScriptPath `
        -AllowedRoot $repositoryRoot -ExpectedPath (Join-Path $repositoryRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1')
}
catch { Add-WatchTrustedFileFailure -Description 'Reviewer agent script' -Path $reviewerScriptPath -ErrorRecord $_ }
try {
    $reviewHandlerScript = Assert-AgentTrustedFile -Path $reviewHandlerScriptPath `
        -AllowedRoot $repositoryRoot -ExpectedPath (Join-Path $repositoryRoot 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1')
}
catch { Add-WatchTrustedFileFailure -Description 'Review-handler agent script' -Path $reviewHandlerScriptPath -ErrorRecord $_ }

function Resolve-WatchRoleConfigFile {
    <#
        Resolves and validates one role's config file exactly as before -- a config passed
        explicitly may live anywhere the operator trusts, a defaulted one must live under the
        consumer repository's own agent config root -- but records failures for aggregation instead
        of throwing on the first one.
    #>
    param(
        [Parameter(Mandatory)][string]$Description,
        [AllowEmptyString()][string]$ConfiguredPath,
        [Parameter(Mandatory)][string]$DefaultFileName,
        [Parameter(Mandatory)][bool]$Explicit
    )
    $path = [IO.Path]::GetFullPath($(if ($ConfiguredPath) { $ConfiguredPath } else { Join-Path $defaultConfigRoot $DefaultFileName }))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [void]$preflightFailures.Add("$Description config was not found: $path")
        return $path
    }
    try {
        return Assert-AgentTrustedFile -Path $path -AllowedRoot $(if ($Explicit) { '' } else { $defaultConfigRoot })
    }
    catch {
        Add-WatchTrustedFileFailure -Description "$Description config" -Path $path -ErrorRecord $_
        return $path
    }
}

# A role's config is required only when that role runs automatically or its manual role was
# enabled -- unchanged from before, now including the roles Golden enables implicitly.
$reviewerConfigExplicit = $PSBoundParameters.ContainsKey('ReviewerConfigFile')
$reviewHandlerConfigExplicit = $PSBoundParameters.ContainsKey('ReviewHandlerConfigFile')
if ($launchReviewer -or $launch.Reviewer.ManualEnabled) {
    $ReviewerConfigFile = Resolve-WatchRoleConfigFile -Description 'Reviewer' -ConfiguredPath $ReviewerConfigFile `
        -DefaultFileName 'reviewer.config.json' -Explicit $reviewerConfigExplicit
}
if ($launchReviewHandler -or $launch.ReviewHandler.ManualEnabled) {
    $ReviewHandlerConfigFile = Resolve-WatchRoleConfigFile -Description 'Review-handler' -ConfiguredPath $ReviewHandlerConfigFile `
        -DefaultFileName 'review-handler.config.json' -Explicit $reviewHandlerConfigExplicit
}

$consumerRepositoryRoot = ''
$git = Get-Command git -ErrorAction SilentlyContinue
$configForRepository = if ($ReviewerConfigFile) { $ReviewerConfigFile } else { $ReviewHandlerConfigFile }
if ($git -and $configForRepository -and (Test-Path -LiteralPath $configForRepository -PathType Leaf)) {
    $toplevel = & $git.Source -C (Split-Path $configForRepository -Parent) rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $toplevel) { $consumerRepositoryRoot = ([string]$toplevel).Trim() }
}
if (-not $OperatorAlias) {
    $email = if ($git -and $consumerRepositoryRoot) {
        & $git.Source -C $consumerRepositoryRoot config user.email 2>$null
    }
    $candidate = if ($email) { ([string]$email).Trim().Split('@')[0] } else { ([string]$env:USERNAME).Trim() }
    if ($candidate -notmatch '^[A-Za-z0-9._-]+$') {
        [void]$preflightFailures.Add('Could not detect a safe operator alias. Configure git user.email or pass -OperatorAlias.')
    }
    else {
        $OperatorAlias = $candidate
    }
}

# Path shape of every trusted root is checked here, before any of them is created; the roots
# themselves are created only once the whole preflight has passed.
if (-not $StateDir) {
    $watchId = '{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $StateDir = Join-Path (Get-AgentDefaultWatchStateRoot) $watchId
}
if (-not $DurableStateRoot) { $DurableStateRoot = Get-AgentDefaultDurableStateRoot }
if (-not $LeaseRoot) { $LeaseRoot = Get-AgentDefaultLeaseRoot }
$StateDir = [IO.Path]::GetFullPath($StateDir)
$DurableStateRoot = [IO.Path]::GetFullPath($DurableStateRoot)
$LeaseRoot = [IO.Path]::GetFullPath($LeaseRoot)
foreach ($rootCheck in @(
        @{ Kind = 'watch-state'; Path = $StateDir },
        @{ Kind = 'durable-state'; Path = $DurableStateRoot },
        @{ Kind = 'lease'; Path = $LeaseRoot })) {
    if (Test-AgentPathWithin -Path $rootCheck.Path -Root $repositoryRoot) {
        [void]$preflightFailures.Add("$($rootCheck.Kind) root '$($rootCheck.Path)' must be outside the repository.")
    }
}
foreach ($rootPair in @(
        @($StateDir, $DurableStateRoot), @($StateDir, $LeaseRoot), @($DurableStateRoot, $LeaseRoot))) {
    if ((Test-AgentPathWithin -Path $rootPair[0] -Root $rootPair[1]) -or
        (Test-AgentPathWithin -Path $rootPair[1] -Root $rootPair[0])) {
        [void]$preflightFailures.Add("Trusted roots '$($rootPair[0])' and '$($rootPair[1])' must not contain one another.")
    }
}

# Validate the dashboard runtime and build before creating any trusted roots. Descriptor trust is
# validated again after transactional preparation, but missing Node/npm, dependencies, native
# renderer support, or built assets must fail here with no state residue.
if ($preflightFailures.Count -eq 0) {
    try {
        $global:LASTEXITCODE = 0
        & $dashboardLauncher -StateDir $StateDir -LaunchMode $launch.LaunchMode -ValidateOnly
        if ($LASTEXITCODE -ne 0) {
            [void]$preflightFailures.Add("Dashboard runtime preflight failed with code $LASTEXITCODE.")
        }
    }
    catch {
        [void]$preflightFailures.Add("Dashboard runtime preflight failed: $($_.Exception.Message)")
    }
}

if ($preflightFailures.Count -gt 0) {
    if ($preflightRemediation.Count -gt 0) {
        Write-Host 'Fix the unsafe path(s) with exactly these commands, then run the launcher again:' -ForegroundColor Yellow
        foreach ($line in $preflightRemediation) { Write-Host "  $line" -ForegroundColor Yellow }
    }
    throw ("Launch preflight failed with $($preflightFailures.Count) problem(s):`n" +
        ((@($preflightFailures) | ForEach-Object { "  - $_" }) -join "`n"))
}

# In-memory broker descriptor: built and validated before a single directory exists.
$manualRoles = [ordered]@{}
if ($launch.Reviewer.ManualEnabled) {
    $reviewerCapabilities = @($launch.Reviewer.ManualCapabilities)
    $manualRoles.reviewer = [ordered]@{
        enabled = $true; configFile = $ReviewerConfigFile
        configRoot = (Split-Path $ReviewerConfigFile -Parent); scriptPath = $reviewerScript
        capabilities = $reviewerCapabilities
        mandatoryDenies = @($launch.Reviewer.MandatoryDenies)
        absoluteDenies = @($launch.Reviewer.AbsoluteDenies)
    }
    Assert-WatchManualRolePolicy -Role reviewer -RoleEntry $manualRoles.reviewer
}
if ($launch.ReviewHandler.ManualEnabled) {
    $handlerCapabilities = @($launch.ReviewHandler.ManualCapabilities)
    $manualRoles.'review-handler' = [ordered]@{
        enabled = $true; configFile = $ReviewHandlerConfigFile
        configRoot = (Split-Path $ReviewHandlerConfigFile -Parent); scriptPath = $reviewHandlerScript
        capabilities = $handlerCapabilities
        mandatoryDenies = @($launch.ReviewHandler.MandatoryDenies)
        absoluteDenies = @($launch.ReviewHandler.AbsoluteDenies)
    }
    Assert-WatchManualRolePolicy -Role review-handler -RoleEntry $manualRoles.'review-handler'
}

# ---------------------------------------------------------------------------
# Pre-spawn disclosure: exactly what this launch is about to be allowed to do, printed before any
# root, descriptor, or child exists -- and printed unchanged under -WhatIf, which then stops here.
# ---------------------------------------------------------------------------
$automaticRoleNames = @(@(
        $(if ($launchReviewer) { 'reviewer' }), $(if ($launchReviewHandler) { 'review-handler' })) |
    Where-Object { $_ })
$manualRoleNames = @($manualRoles.Keys)
$enabledWrites = [Collections.Generic.List[string]]::new()
foreach ($role in @($launch.Reviewer, $launch.ReviewHandler)) {
    foreach ($capability in @($role.AutomaticCapabilities)) { [void]$enabledWrites.Add("$($role.Role) automatic: $capability") }
    foreach ($capability in @($role.ManualCapabilities)) {
        if ($role.Role -cin $manualRoleNames) { [void]$enabledWrites.Add("$($role.Role) manual: $capability") }
    }
}
if ($launch.ReviewerTeamsNotifications) { [void]$enabledWrites.Add('reviewer automatic: Teams notifications') }
if ($launch.ReviewHandlerTeamsNotifications) { [void]$enabledWrites.Add('review-handler automatic: Teams notifications') }
$defaultDenials = [Collections.Generic.List[string]]::new()
foreach ($role in @($launch.Reviewer, $launch.ReviewHandler)) {
    foreach ($capability in @($role.MandatoryDenies)) {
        $suffix = if (@($role.AbsoluteDenies) -ccontains $capability) { ' (absolute, non-delegable)' } else { ' (default off)' }
        [void]$defaultDenials.Add("$($role.Role): $capability$suffix")
    }
}
Write-Host 'DevPilot launch plan' -ForegroundColor Cyan
Write-Host "  Consumer repository : $(if ($consumerRepositoryRoot) { $consumerRepositoryRoot } else { '(not a git repository)' })"
Write-Host "  Operator            : $OperatorAlias"
Write-Host "  Mode                : $(if ($launch.LaunchMode -eq 'operational') { 'OPERATIONAL' } else { 'PREVIEW ONLY' })"
Write-Host "  Automatic roles     : $(if ($automaticRoleNames.Count -gt 0) { $automaticRoleNames -join ', ' } else { 'none' })"
Write-Host "  Manual (broker) roles: $(if ($manualRoleNames.Count -gt 0) { $manualRoleNames -join ', ' } else { 'none' })"
Write-Host "  Cycling             : $(if ($launch.Continuous) { "continuous, every $IntervalSeconds second(s)" } else { 'one cycle' })"
Write-Host "  Watch state root    : $StateDir"
Write-Host "  Enabled writes      : $(if ($enabledWrites.Count -gt 0) { $enabledWrites -join '; ' } else { 'none' })"
Write-Host "  Default denials     : $(if ($defaultDenials.Count -gt 0) { $defaultDenials -join '; ' } else { 'none' })"
if ($launch.LaunchMode -eq 'operational') {
    Write-Host '  Preview alternative : re-run this exact command with -PreviewOnly to observe the same agents with every write, notification, and grant permanently disabled.' -ForegroundColor Yellow
}
else {
    Write-Host '  Preview alternative : already preview-only; no write can be enabled or granted for the lifetime of this launch.'
}

if (-not $PSCmdlet.ShouldProcess($StateDir, "Create watch state and launch DevPilot agents ($($launch.LaunchMode))")) {
    return
}

# ---------------------------------------------------------------------------
# Transactional preparation. Everything created from here on is tracked so a dashboard preflight
# failure can undo exactly what THIS invocation created and nothing else.
# ---------------------------------------------------------------------------
$watchStateRoot = [IO.Path]::GetFullPath((Get-AgentDefaultWatchStateRoot))
# Enumerated BEFORE the current state root exists, so the current launch can never appear in its
# own history and the newest prior launch is never displaced by it.
$priorStateDirs = Get-PriorWatchStateDir -WatchRoot $watchStateRoot -RepositoryRoot $repositoryRoot `
    -CurrentStateDir $StateDir -ExcludedRoots @($DurableStateRoot, $LeaseRoot)
$stateDirCreatedHere = $false
$durableStateRootCreatedHere = $false
$leaseRootCreatedHere = $false

function Remove-LaunchPreparationResidue {
    <#
        Removes ONLY roots this invocation created. Shared durable-state and lease roots are
        removed only while still empty; a concurrently populated root is left intact.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DescriptorPath)
    if ($DescriptorPath -and (Test-Path -LiteralPath $DescriptorPath -PathType Leaf)) {
        Remove-Item -LiteralPath $DescriptorPath -Force -ErrorAction Stop
    }
    foreach ($root in @(
            @{ Path = $LeaseRoot; Kind = 'lease'; CreatedHere = $leaseRootCreatedHere },
            @{ Path = $DurableStateRoot; Kind = 'durable-state'; CreatedHere = $durableStateRootCreatedHere })) {
        if (-not $root.CreatedHere -or -not (Test-Path -LiteralPath $root.Path -PathType Container)) { continue }
        [void](Resolve-AgentTrustedRoot -Path $root.Path -Kind $root.Kind -RepositoryRoot $repositoryRoot)
        if (@(Get-ChildItem -LiteralPath $root.Path -Force).Count -eq 0) {
            Remove-Item -LiteralPath $root.Path -Force -ErrorAction Stop
        }
    }
    if ($stateDirCreatedHere -and (Test-Path -LiteralPath $StateDir -PathType Container)) {
        [void](Resolve-AgentTrustedRoot -Path $StateDir -Kind watch-state -RepositoryRoot $repositoryRoot)
        if (@(Get-ChildItem -LiteralPath $StateDir -Force).Count -eq 0) {
            Remove-Item -LiteralPath $StateDir -Force -ErrorAction Stop
        }
    }
}

$brokerDescriptorPath = ''
try {
    $StateDir = Resolve-AgentTrustedRoot -Path $StateDir -Kind watch-state `
        -RepositoryRoot $repositoryRoot -Create -CreatedByCaller ([ref]$stateDirCreatedHere)
    $DurableStateRoot = Resolve-AgentTrustedRoot -Path $DurableStateRoot `
        -Kind durable-state -RepositoryRoot $repositoryRoot -DisallowedRoots @($StateDir) -Create `
        -CreatedByCaller ([ref]$durableStateRootCreatedHere)
    $LeaseRoot = Resolve-AgentTrustedRoot -Path $LeaseRoot `
        -Kind lease -RepositoryRoot $repositoryRoot -DisallowedRoots @($StateDir, $DurableStateRoot) -Create `
        -CreatedByCaller ([ref]$leaseRootCreatedHere)
}
catch {
    $preparationError = $_
    try {
        Remove-LaunchPreparationResidue -DescriptorPath ''
    }
    catch {
        Write-Warning "Could not fully remove launch preparation residue: $($_.Exception.Message)"
    }
    throw $preparationError
}

try {
    if ($manualRoles.Count -gt 0) {
        $brokerDescriptorPath = Join-Path $StateDir 'broker.descriptor.v1.json'
        $brokerDescriptor = [ordered]@{
            schemaVersion = 1; ownerProcessId = $PID; stateRoot = $StateDir
            durableStateRoot = $DurableStateRoot; leaseRoot = $LeaseRoot
            operatorAlias = $OperatorAlias; roles = $manualRoles
        }
        if (Test-Path -LiteralPath $brokerDescriptorPath) {
            [void](Assert-AgentTrustedFile -Path $brokerDescriptorPath -AllowedRoot $StateDir -Private)
        }
        [IO.File]::WriteAllText($brokerDescriptorPath,
            (ConvertTo-AgentCanonicalJson $brokerDescriptor), [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($brokerDescriptorPath,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $brokerDescriptorPath = Assert-AgentTrustedFile -Path $brokerDescriptorPath -AllowedRoot $StateDir -Private
    }
    $global:LASTEXITCODE = 0
    # Current run first, then the most recent trusted prior launches; the dashboard renders them in
    # this order. Durable-state and lease roots are structurally excluded by Get-PriorWatchStateDir.
    $dashboardParameters = @{ StateDir = @(@($StateDir) + @($priorStateDirs)); LaunchMode = $launch.LaunchMode }
    if ($brokerDescriptorPath) {
        $dashboardParameters.BrokerDescriptorPath = $brokerDescriptorPath
    }
    & $dashboardLauncher @dashboardParameters -ValidateOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Dashboard preflight failed with code $LASTEXITCODE; no agent was started."
    }
}
catch {
    $preparationError = $_
    try {
        Remove-LaunchPreparationResidue -DescriptorPath $brokerDescriptorPath
    }
    catch {
        Write-Warning "Could not fully remove launch preparation residue: $($_.Exception.Message)"
    }
    throw $preparationError
}

$sessionSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
if (-not $ReviewerAgentName) { $ReviewerAgentName = "reviewer-watch-$sessionSuffix" }
if (-not $ReviewHandlerAgentName) { $ReviewHandlerAgentName = "review-handler-watch-$sessionSuffix" }

$specs = New-Object System.Collections.Generic.List[object]
if ($launchReviewer) {
    [void]$specs.Add([pscustomobject]@{
        Role = 'reviewer'
        Script = $reviewerScript
        ConfigFile = $ReviewerConfigFile
        StateDir = (Join-Path $StateDir 'reviewer')
        AgentName = $ReviewerAgentName
        PullRequestId = $ReviewerPullRequestId
        Model = $ReviewerModel
        IncludeOwn = [bool]$IncludeOwnPullRequests
        Capabilities = @($launch.Reviewer.AutomaticCapabilities)
        TeamsNotifications = $launch.ReviewerTeamsNotifications
    })
}
if ($launchReviewHandler) {
    [void]$specs.Add([pscustomobject]@{
        Role = 'review-handler'
        Script = $reviewHandlerScript
        ConfigFile = $ReviewHandlerConfigFile
        StateDir = (Join-Path $StateDir 'review-handler')
        AgentName = $ReviewHandlerAgentName
        PullRequestId = $ReviewHandlerPullRequestId
        Model = $ReviewHandlerModel
        IncludeOwn = $false
        Capabilities = @($launch.ReviewHandler.AutomaticCapabilities)
        TeamsNotifications = $launch.ReviewHandlerTeamsNotifications
    })
}

$pwsh = Resolve-AgentPwshPath
$children = New-Object System.Collections.Generic.List[object]
try {
    foreach ($spec in $specs) {
        New-Item -ItemType Directory -Force -Path $spec.StateDir | Out-Null
        $childArguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $spec.Script,
            '-ConfigFile', $spec.ConfigFile, '-StateDir', $spec.StateDir,
            '-DurableStateRoot', $DurableStateRoot, '-LeaseRoot', $LeaseRoot,
            '-AgentName', $spec.AgentName, '-OperatorAlias', $OperatorAlias,
            '-OutputMode', 'Json'
        )
        # Typed equivalent of the prior child parameter: OutputMode = 'Json'
        if ($launch.Continuous) {
            $childArguments += @('-IntervalSeconds', [string]$IntervalSeconds)
        }
        else {
            $childArguments += '-Once'
            # Typed equivalent of the prior child parameter: Once = $true
        }
        if ($spec.PullRequestId -gt 0) { $childArguments += @('-PullRequestId', [string]$spec.PullRequestId) }
        if ($spec.Model) { $childArguments += @('-Model', $spec.Model) }
        if ($spec.IncludeOwn) { $childArguments += '-IncludeOwnPullRequests' }
        # Both the automatic capability set and the Teams opt-in come from the one resolved launch
        # policy (Resolve-WatchLaunchPolicy), which has already applied Golden's defaults and the
        # terminal preview-only ceiling -- so an automatic child can never be granted something the
        # same launch's manual broker role is denied, or the reverse.
        foreach ($capability in @($spec.Capabilities)) {
            $childArguments += "-$capability"
        }
        if ($spec.TeamsNotifications) {
            $childArguments += '-EnableTeamsNotifications'
        }

        $stdoutPath = Join-Path $StateDir "$($spec.Role).stdout.jsonl"
        $stderrPath = Join-Path $StateDir "$($spec.Role).stderr.log"
        $owned = if (-not $launch.Continuous -and -not $launch.Operational) {
            New-AgentPersistentRedirectedProcess -FilePath $pwsh -ArgumentList $childArguments `
                -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath -WorkingDirectory $toolkitRoot
        }
        else {
            New-AgentRedirectedProcess -FilePath $pwsh -ArgumentList $childArguments `
                -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath -WorkingDirectory $toolkitRoot
        }
        $process = $owned.Process
        [void]$children.Add([pscustomobject]@{
            Role = $spec.Role
            Process = $process
            Owned = $owned
            StdErrPath = $stderrPath
        })
        Write-Host "Watching $($spec.Role) PID $($process.Id)." -ForegroundColor Cyan
    }
}
catch {
    foreach ($child in $children) {
        Close-OwnedAgentProcess -Process $child.Process -Role $child.Role
        [void](Complete-AgentRedirectedProcess -Child $child.Owned)
    }
    throw
}

Write-Host "Shared state root: $StateDir" -ForegroundColor Cyan
if ($launch.LaunchMode -eq 'operational') {
    Write-Information 'OPERATIONAL: this launch authorizes pull-request mutations. See the launch plan above for the exact automatic and manual capabilities.' -InformationAction Continue
    Write-Information "Review-handler code updates: $([bool]$launch.ReviewHandlerCodeUpdates) (code changes, local validation, session resume, and push)." -InformationAction Continue
    Write-Information "Teams notifications: reviewer=$([bool]$launch.ReviewerTeamsNotifications) review-handler=$([bool]$launch.ReviewHandlerTeamsNotifications)." -InformationAction Continue
    Write-Warning 'Closing the dashboard immediately stops owned agent process trees. Quit while agents are waiting when possible to avoid interrupting an in-flight operation.'
}
else {
    Write-Information 'PREVIEW ONLY: no code changes, pushes, replies, comments, summaries, votes, requeues, auto-complete, or notifications are enabled.' -InformationAction Continue
}
if ($launch.Continuous) {
    Write-Host "Agents will scan every $IntervalSeconds second(s) until the dashboard exits." -ForegroundColor Green
}

$startupFailure = $null
foreach ($child in $children) {
    $null = $child.Process.WaitForExit(3000)
    $child.Process.Refresh()
    if ($child.Process.HasExited -and $child.Process.ExitCode -ne 0) {
        $startupFailure = $child
        break
    }
}
if ($startupFailure) {
    foreach ($child in $children) {
        Close-OwnedAgentProcess -Process $child.Process -Role $child.Role
        [void](Complete-AgentRedirectedProcess -Child $child.Owned)
    }
    Write-Error "$($startupFailure.Role) exited during startup with code $($startupFailure.Process.ExitCode). Diagnostics: $($startupFailure.StdErrPath)"
    exit $startupFailure.Process.ExitCode
}

$dashboardCompletedNormally = $false
$agentsStoppedByDashboard = $false
try {
    $global:LASTEXITCODE = 0
    & $dashboardLauncher @dashboardParameters
    if ($LASTEXITCODE -ne 0) { throw "Dashboard exited with code $LASTEXITCODE." }
    $dashboardCompletedNormally = $true
}
finally {
    if (-not $dashboardCompletedNormally -or $launch.Continuous -or $launch.Operational) {
        foreach ($child in $children) {
            Close-OwnedAgentProcess -Process $child.Process -Role $child.Role
            [void](Complete-AgentRedirectedProcess -Child $child.Owned)
        }
        $agentsStoppedByDashboard = $true
    }
    else {
        $running = @($children | Where-Object {
            $_.Process.Refresh()
            -not $_.Process.HasExited
        })
        if ($running.Count -gt 0) {
            Write-Host "$($running.Count) preview agent(s) are still running." -ForegroundColor Yellow
            Write-Host "Reattach with: .\tools\Watch-DevPilotAgents.ps1 -AttachOnly -StateDir '$StateDir'" -ForegroundColor Yellow
        }
    }
}

if ($agentsStoppedByDashboard -and $dashboardCompletedNormally) { exit 0 }
foreach ($child in $children) {
    $child.Process.Refresh()
    if ($child.Process.HasExited) {
        [void](Complete-AgentRedirectedProcess -Child $child.Owned)
    }
}
$failedChild = @($children | Where-Object {
    $_.Process.Refresh()
    $_.Process.HasExited -and $_.Process.ExitCode -ne 0
} | Select-Object -First 1)
if ($failedChild.Count -gt 0) { exit $failedChild[0].Process.ExitCode }
