#Requires -Version 7.0

<#
.SYNOPSIS
    Runs the coordinator's bounded child-wait checks (finding F9).

.DESCRIPTION
    The property under test is that a timed-out child's kill is followed only by
    bounded waits, and that an unconfirmed stop is recorded as an honest
    abandoned/uncertain terminal rather than a false 'killed'. The checks live in
    the coordinator binary because they start real child processes; this wrapper
    only builds and reports them.

.PARAMETER RepoRoot
    Defaults to the repository containing this script.

.PARAMETER Scratch
    Where the checks may write. Defaults to a temporary directory, removed after.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$Scratch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$project = Join-Path $RepoRoot 'tools/ShadowRunCoordinator/ShadowRunCoordinator.csproj'
if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
    throw "The coordinator project '$project' does not exist."
}

$owned = $false
if ([string]::IsNullOrWhiteSpace($Scratch)) {
    $Scratch = Join-Path ([IO.Path]::GetTempPath()) ('child-wait-' + [Guid]::NewGuid().ToString('n'))
    $owned = $true
}
New-Item -ItemType Directory -Path $Scratch -Force | Out-Null

try {
    Write-Host 'Building ShadowRunCoordinator...'
    $priorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $build = & dotnet build $project -c Debug --nologo -v quiet 2>&1
        if ([int]$LASTEXITCODE -ne 0) {
            $build | ForEach-Object { Write-Host $_ }
            throw "dotnet build failed with exit code $LASTEXITCODE."
        }
        & dotnet run --project $project -c Debug --no-build -- --selftest-child-wait $Scratch
        $exit = [int]$LASTEXITCODE
    }
    finally { $PSNativeCommandUseErrorActionPreference = $priorPreference }

    if ($exit -ne 0) {
        Write-Host "Bounded child wait checks FAILED (exit $exit)." -ForegroundColor Red
        exit 1
    }
    exit 0
}
finally {
    if ($owned) { Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
