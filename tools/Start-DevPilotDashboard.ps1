[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$StateDir = @(),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$EventLogPath = @()
)

$ErrorActionPreference = 'Stop'
$dashboardRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\DevPilot.Dashboard'))
$packagePath = Join-Path $dashboardRoot 'package.json'
$lockPath = Join-Path $dashboardRoot 'package-lock.json'
$entryPath = Join-Path $dashboardRoot 'dist\src\index.js'
$bunPath = Join-Path $dashboardRoot 'node_modules\bun\bin\bun.exe'

function Stop-DashboardLaunch {
    param([Parameter(Mandatory)][string]$Message, [string[]]$Instructions = @())
    Write-Error $Message -ErrorAction Continue
    foreach ($instruction in $Instructions) {
        Write-Host "  $instruction" -ForegroundColor Yellow
    }
    exit 1
}

if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    Stop-DashboardLaunch 'DevPilot Operations requires an interactive terminal; input or output is redirected.'
}

if ($StateDir.Count -eq 0 -and $EventLogPath.Count -eq 0) {
    Stop-DashboardLaunch 'Provide at least one -StateDir or -EventLogPath.'
}

$width = try { [Console]::WindowWidth } catch { 0 }
if ($width -lt 60) {
    Stop-DashboardLaunch "DevPilot Operations requires a terminal width of at least 60 columns (current: $width)." @(
        'Resize the terminal and run the launcher again.'
    )
}

$node = Get-Command node -ErrorAction SilentlyContinue
$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $node -or -not $npm) {
    Stop-DashboardLaunch 'Node.js and npm were not both found on PATH.' @(
        'Install Node.js 24 or newer, then open a new terminal.'
    )
}

$nodeVersionText = (& $node.Source --version 2>$null)
$nodeVersion = if ($nodeVersionText -match '^v(\d+)\.(\d+)\.(\d+)') {
    [Version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}
else {
    [Version]::new(0, 0, 0)
}
if ($nodeVersion -lt [Version]::new(24, 0, 0)) {
    Stop-DashboardLaunch "The dashboard build requires Node.js 24 or newer (found '$nodeVersionText')." @(
        'Install Node.js 24 or newer, then open a new terminal.'
    )
}

if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    Stop-DashboardLaunch 'The dashboard package or lockfile is missing.' @(
        "Expected package: $packagePath"
    )
}

$requiredDependencies = @(
    '@opentui\core\package.json',
    '@opentui\solid\package.json',
    'solid-js\package.json',
    'bun\package.json'
)
$missingDependencies = @($requiredDependencies | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path (Join-Path $dashboardRoot 'node_modules') $_) -PathType Leaf)
    })
if ($missingDependencies.Count -gt 0) {
    Stop-DashboardLaunch 'Dashboard dependencies are not installed.' @(
        "Set-Location '$dashboardRoot'",
        '$env:npm_config_cache = "$PWD\.npm-cache"',
        'npm install'
    )
}

$manifest = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
foreach ($dependencyName in @('@opentui/core', '@opentui/solid', 'solid-js', 'bun')) {
    $relativeManifest = ($dependencyName -replace '/', '\') + '\package.json'
    $installedManifestPath = Join-Path (Join-Path $dashboardRoot 'node_modules') $relativeManifest
    $installedManifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
    $expectedVersion = if ($manifest.dependencies.PSObject.Properties[$dependencyName]) {
        [string]$manifest.dependencies.$dependencyName
    }
    else {
        [string]$manifest.devDependencies.$dependencyName
    }
    if ([string]$installedManifest.version -ne $expectedVersion) {
        Stop-DashboardLaunch "Dashboard dependency '$dependencyName' is not at the locked version." @(
            "Expected $expectedVersion; found $($installedManifest.version).",
            "Set-Location '$dashboardRoot'",
            'npm install'
        )
    }
}

if (-not (Test-Path -LiteralPath $bunPath -PathType Leaf)) {
    Stop-DashboardLaunch 'The locked Bun runtime is missing.' @(
        "Set-Location '$dashboardRoot'",
        'npm install'
    )
}

$ffiProbe = $null
$ffiExitCode = 0
Push-Location $dashboardRoot
try {
    $ffiProbe = & $bunPath --conditions=browser -e `
        "import { resolveRenderLib } from '@opentui/core'; resolveRenderLib();" 2>&1
    $ffiExitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($ffiExitCode -ne 0) {
    Stop-DashboardLaunch 'The OpenTUI native renderer is not ready for this Node.js runtime.' @(
        ([string]($ffiProbe -join [Environment]::NewLine)),
        "Set-Location '$dashboardRoot'",
        'npm install'
    )
}

if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
    Stop-DashboardLaunch 'The dashboard has not been built.' @(
        "Set-Location '$dashboardRoot'",
        'npm run build'
    )
}

$sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $dashboardRoot 'src') -File -Recurse) +
    @(Get-Item -LiteralPath (Join-Path $dashboardRoot 'build.mjs'), $packagePath)
$newestSource = ($sourceFiles | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
$buildTime = (Get-Item -LiteralPath $entryPath).LastWriteTimeUtc
if ($newestSource -gt $buildTime) {
    Stop-DashboardLaunch 'The dashboard build is older than its source.' @(
        "Set-Location '$dashboardRoot'",
        'npm run build'
    )
}

$arguments = New-Object System.Collections.Generic.List[string]
[void]$arguments.Add('--conditions=browser')
[void]$arguments.Add($entryPath)
foreach ($path in $StateDir) {
    [void]$arguments.Add('--state-dir')
    [void]$arguments.Add([IO.Path]::GetFullPath($path))
}
foreach ($path in $EventLogPath) {
    [void]$arguments.Add('--event-log')
    [void]$arguments.Add([IO.Path]::GetFullPath($path))
}

Push-Location $dashboardRoot
try {
    & $bunPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Dashboard exited with code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
