#requires -Version 7.0

<#
.SYNOPSIS
    Launches a preview-only review-handler and opens the dashboard on that run.

.DESCRIPTION
    Compatibility wrapper for Watch-DevPilotAgents.ps1 -Agent ReviewHandler.
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
    [ValidateRange(0, 2147483647)]
    [int]$PullRequestId = 0,

    [Parameter(ParameterSetName = 'Launch')]
    [switch]$Continuous,

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
    [string]$Model
)

$parameters = @{}
if ($AttachOnly) { $parameters.AttachOnly = $true }
else { $parameters.Agent = 'ReviewHandler' }
if ($StateDir) { $parameters.StateDir = $StateDir }
if ($ConfigFile) { $parameters.ReviewHandlerConfigFile = $ConfigFile }
if ($PullRequestId -gt 0) { $parameters.ReviewHandlerPullRequestId = $PullRequestId }
if ($Continuous) { $parameters.Continuous = $true }
if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $parameters.IntervalSeconds = $IntervalSeconds }
if ($OperatorAlias) { $parameters.OperatorAlias = $OperatorAlias }
if ($AgentName) { $parameters.ReviewHandlerAgentName = $AgentName }
if ($Model) { $parameters.ReviewHandlerModel = $Model }

& (Join-Path $PSScriptRoot 'Watch-DevPilotAgents.ps1') @parameters
exit $LASTEXITCODE
