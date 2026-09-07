#Requires -Version 7.0
<#
.SYNOPSIS
    Chooses the next Gate5 shadow subjects from a candidate list, excluding every
    pull request the durable account already holds.

.DESCRIPTION
    A thin, honest wrapper. The exclusion itself is decided by the shipping
    coordinator against the signed registry, because that is the only place the
    registry's canonical form and its HMAC are implemented; a second implementation
    here would be a second opinion about what the account says, and an account with
    two readers is not an account.

    Nothing here launches a review, reaches a network, or writes to a provider. It
    reads a candidate list the caller supplies, reads the account, and writes a
    selection file.

.PARAMETER RegistryPath
    The durable account. Lives outside the repository.

.PARAMETER CandidatePath
    A devpilot.shadow-cohort.candidates.v1 JSON file listing the pull requests an
    operator is willing to run, in preference order.

.PARAMETER OutputPath
    Where the selection is written.

.PARAMETER Count
    How many unspent subjects to choose. Defaults to 1.

.PARAMETER AcceptUnstartedRegistry
    Select against an account file that does not exist yet. Nothing is excluded,
    and the acknowledgement is written into the selection file. Without it a
    registry path with no file at it is refused, because a mistyped path would
    otherwise hand back pull requests that have already been spent.

.PARAMETER Configuration
    Which build of the coordinator to use. Defaults to Release.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [Parameter(Mandatory)][string]$CandidatePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1, 64)][int]$Count = 1,
    [switch]$AcceptUnresolvedDefects,
    [switch]$AcceptUnstartedRegistry,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repoRoot 'tools\ShadowRunCoordinator\ShadowRunCoordinator.csproj'
if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
    throw "The coordinator project was not found at '$project'."
}

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
& dotnet build $project --configuration $Configuration --nologo --verbosity quiet | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The coordinator did not build.' }

$dll = Join-Path $repoRoot ("tools\ShadowRunCoordinator\bin\{0}\net10.0\ShadowRunCoordinator.dll" -f $Configuration)
if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw "The coordinator assembly was not produced at '$dll'." }

$argv = [System.Collections.Generic.List[string]]::new()
[void]$argv.Add($dll)
[void]$argv.Add('--select-subjects')
[void]$argv.Add('--registry'); [void]$argv.Add($RegistryPath)
[void]$argv.Add('--candidates'); [void]$argv.Add($CandidatePath)
[void]$argv.Add('--out'); [void]$argv.Add($OutputPath)
[void]$argv.Add('--select-count'); [void]$argv.Add($Count.ToString([Globalization.CultureInfo]::InvariantCulture))
if ($AcceptUnresolvedDefects.IsPresent) { [void]$argv.Add('--accept-unresolved-defects') }
if ($AcceptUnstartedRegistry.IsPresent) { [void]$argv.Add('--accept-unstarted-registry') }

$previous = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
try {
    & dotnet @argv
    $exit = $LASTEXITCODE
}
finally { $PSNativeCommandUseErrorActionPreference = $previous }

if ($exit -ne 0) { throw "Selection failed with exit code $exit." }
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) { throw 'Selection reported success and wrote no file.' }

# The selection is the file. What is returned here is a convenience for a human
# at a prompt and is never a contract: nothing downstream parses this object.
$selection = Get-Content -LiteralPath $OutputPath -Raw -Encoding utf8 | ConvertFrom-Json
Write-Host ("selection {0}: {1} chosen, {2} excluded, registry revision {3}." -f `
    $OutputPath, $selection.selectedCount, @($selection.excluded).Count, $selection.registryRevision) -ForegroundColor Cyan
return $selection
