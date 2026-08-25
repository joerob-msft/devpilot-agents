#Requires -Version 7.0

<#
.SYNOPSIS
    Runs the coordinator's atomic state publish checks.

.DESCRIPTION
    The checks themselves live in the coordinator binary, because the property
    under test is a real Windows file-sharing interaction between two real
    handles and cannot be reproduced from outside the process that publishes.
    This wrapper builds the tool and reports the result in the shape the rest of
    the suites use.

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
    $Scratch = Join-Path ([IO.Path]::GetTempPath()) ('atomic-publish-' + [Guid]::NewGuid().ToString('n'))
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
        & dotnet run --project $project -c Debug --no-build -- --selftest-atomic-publish $Scratch
        $exit = [int]$LASTEXITCODE
    }
    finally { $PSNativeCommandUseErrorActionPreference = $priorPreference }

    if ($exit -ne 0) {
        Write-Host "Atomic state publish checks FAILED (exit $exit)." -ForegroundColor Red
        exit 1
    }
    exit 0
}
finally {
    if ($owned) { Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
