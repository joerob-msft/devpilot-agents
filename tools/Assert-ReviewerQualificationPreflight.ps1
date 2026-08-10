#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$')][string]$RequiredRef,
    [Parameter(Mandatory)][ValidateSet("OfflineReplay", "LiveDeployment")][string]$Mode,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$')][string]$ExpectedBranch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\QualificationPreflight.ps1")

$arguments = @{
    RepositoryPath = $RepositoryPath
    ExpectedCommit = $ExpectedCommit
    RequiredRef = $RequiredRef
    Mode = $Mode
}
if ($ExpectedBranch) { $arguments["ExpectedBranch"] = $ExpectedBranch }
$result = Test-ReviewerQualificationGitIdentity @arguments
ConvertTo-Json -InputObject $result -Depth 4 -Compress

