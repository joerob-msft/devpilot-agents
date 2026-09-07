[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$StateDir = @(),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$EventLogPath = @(),

    [Parameter(DontShow)]
    [string]$BrokerDescriptorPath,

    [Parameter(DontShow)]
    [ValidateSet('observe', 'preview', 'operational')]
    [string]$LaunchMode = 'observe',

    [Parameter(DontShow)]
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$dashboardRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'src' 'DevPilot.Dashboard')))
$toolkitRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path (Join-Path (Join-Path $toolkitRoot 'src') 'DevPilot.AgentHarness') 'DevPilot.AgentHarness.psd1') -Force
$packagePath = Join-Path $dashboardRoot 'package.json'
$lockPath = Join-Path $dashboardRoot 'package-lock.json'
$entryPath = Join-Path (Join-Path (Join-Path $dashboardRoot 'dist') 'src') 'index.js'
$bunExecutable = if ($IsWindows) { 'bun.exe' } else { 'bun' }
$nodeModulesPath = Join-Path $dashboardRoot 'node_modules'
$bunPath = Join-Path (Join-Path (Join-Path $nodeModulesPath 'bun') 'bin') $bunExecutable
$brokerScriptPath = Join-Path $PSScriptRoot 'Invoke-DevPilotAgentDispatch.ps1'

function Stop-DashboardLaunch {
    param([Parameter(Mandatory)][string]$Message, [string[]]$Instructions = @())
    Write-Error $Message -ErrorAction Continue
    foreach ($instruction in $Instructions) {
        Write-Host "  $instruction" -ForegroundColor Yellow
    }
    exit 1
}

if (-not $ValidateOnly -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
    Stop-DashboardLaunch 'DevPilot Operations requires an interactive terminal; input or output is redirected.'
}

if ($StateDir.Count -eq 0 -and $EventLogPath.Count -eq 0) {
    Stop-DashboardLaunch 'Provide at least one -StateDir or -EventLogPath.'
}

$width = try { [Console]::WindowWidth } catch { 0 }
if (-not $ValidateOnly -and $width -lt 60) {
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
    @('@opentui', 'core', 'package.json'),
    @('@opentui', 'solid', 'package.json'),
    @('solid-js', 'package.json'),
    @('bun', 'package.json')
)
$missingDependencies = @($requiredDependencies | Where-Object {
        $candidate = $nodeModulesPath
        foreach ($segment in $_) { $candidate = Join-Path $candidate $segment }
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)
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
    $installedManifestPath = $nodeModulesPath
    foreach ($segment in @($dependencyName -split '/') + @('package.json')) {
        $installedManifestPath = Join-Path $installedManifestPath $segment
    }
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

$descriptor = $null
if ($BrokerDescriptorPath) {
    $descriptor = (Resolve-Path -LiteralPath $BrokerDescriptorPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $descriptor -PathType Leaf)) {
        Stop-DashboardLaunch 'The trusted broker descriptor is unavailable.'
    }
    if (-not (Test-Path -LiteralPath $brokerScriptPath -PathType Leaf)) {
        Stop-DashboardLaunch 'The trusted broker executable is unavailable.'
    }
    try {
        $descriptorData = Get-Content -LiteralPath $descriptor -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
        $descriptorStateRoot = Resolve-AgentTrustedRoot -Path ([IO.Path]::GetFullPath([string]$descriptorData.stateRoot)) `
            -Kind watch-state -RepositoryRoot ([IO.Path]::GetFullPath($toolkitRoot))
        [void](Assert-AgentTrustedFile -Path $descriptor -AllowedRoot $descriptorStateRoot `
            -ExpectedPath (Join-Path $descriptorStateRoot 'broker.descriptor.v1.json') -Private)
        [void](Assert-AgentTrustedFile -Path ([IO.Path]::GetFullPath($brokerScriptPath)) `
            -AllowedRoot $toolkitRoot -ExpectedPath (Join-Path (Join-Path $toolkitRoot 'tools') 'Invoke-DevPilotAgentDispatch.ps1'))
        Assert-AgentDashboardLaunchAuthority -LaunchMode $LaunchMode -BrokerDescriptor $descriptorData
    }
    catch {
        Stop-DashboardLaunch "The broker authority descriptor is not trusted: $($_.Exception.Message)"
    }
}

if ($ValidateOnly) { return }

$arguments = New-Object System.Collections.Generic.List[string]
[void]$arguments.Add('--conditions=browser')
[void]$arguments.Add($entryPath)
[void]$arguments.Add('--launch-mode')
[void]$arguments.Add($LaunchMode)
foreach ($path in $StateDir) {
    [void]$arguments.Add('--state-dir')
    [void]$arguments.Add([IO.Path]::GetFullPath($path))
}
foreach ($path in $EventLogPath) {
    [void]$arguments.Add('--event-log')
    [void]$arguments.Add([IO.Path]::GetFullPath($path))
}
if ($descriptor) {
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    [void]$arguments.Add('--broker-executable')
    [void]$arguments.Add([IO.Path]::GetFullPath($pwsh))
    [void]$arguments.Add('--broker-script')
    [void]$arguments.Add([IO.Path]::GetFullPath($brokerScriptPath))
    [void]$arguments.Add('--broker-descriptor')
    [void]$arguments.Add([IO.Path]::GetFullPath($descriptor))
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
