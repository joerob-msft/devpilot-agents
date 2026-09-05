#requires -Version 7.0

<#
.SYNOPSIS
    Launches a reviewer and opens the dashboard on that run.

.DESCRIPTION
    Compatibility wrapper for Watch-DevPilotAgents.ps1 -Agent Reviewer.
    Legacy behavior is pinned here rather than inherited: when neither -Continuous nor -Once is
    passed, -Once is forwarded explicitly, so this wrapper stays a single preview cycle no matter
    what the shared launcher's own default becomes.
#>
[CmdletBinding(DefaultParameterSetName = 'Launch')]
param(
    [Parameter(ParameterSetName = 'Launch')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigFile,

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
    [ValidateRange(0, 2147483647)]
    [int]$PullRequestId = 0,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Continuous,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Once,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$PreviewOnly,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Operational,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableTeamsNotifications,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableManualDispatch,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$EnableManualWrites,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidateRange(30, 86400)]
    [int]$IntervalSeconds = 900,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$OperatorAlias,

    [Parameter(ParameterSetName = 'Launch')]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$AgentName,

    [Parameter(ParameterSetName = 'Launch')]
    [string]$Model,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$IncludeOwnPullRequests
)

if ($PSBoundParameters.ContainsKey('PullRequestId') -and $PullRequestId -le 0) {
    throw 'PullRequestId must be greater than zero when explicitly provided.'
}

$parameters = @{}
if ($AttachOnly) { $parameters.AttachOnly = $true }
else { $parameters.Agent = 'Reviewer' }
if ($StateDir) { $parameters.StateDir = $StateDir }
if ($DurableStateRoot) { $parameters.DurableStateRoot = $DurableStateRoot }
if ($LeaseRoot) { $parameters.LeaseRoot = $LeaseRoot }
if ($ConfigFile) { $parameters.ReviewerConfigFile = $ConfigFile }
if ($PSBoundParameters.ContainsKey('PullRequestId')) { $parameters.ReviewerPullRequestId = $PullRequestId }
if ($Continuous) { $parameters.Continuous = $true }
if (-not $AttachOnly -and ($Once -or -not $Continuous)) { $parameters.Once = $true }
if ($PreviewOnly) { $parameters.PreviewOnly = $true }
if ($Operational) { $parameters.Operational = $true }
if ($EnableTeamsNotifications) { $parameters.EnableReviewerTeamsNotifications = $true }
if ($EnableManualDispatch) { $parameters.EnableManualReviewer = $true }
if ($EnableManualWrites) { $parameters.EnableManualReviewerWrites = $true }
if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $parameters.IntervalSeconds = $IntervalSeconds }
if ($OperatorAlias) { $parameters.OperatorAlias = $OperatorAlias }
if ($AgentName) { $parameters.ReviewerAgentName = $AgentName }
if ($Model) { $parameters.ReviewerModel = $Model }
if ($IncludeOwnPullRequests) { $parameters.IncludeOwnPullRequests = $true }

& (Join-Path $PSScriptRoot 'Watch-DevPilotAgents.ps1') @parameters
exit $LASTEXITCODE
