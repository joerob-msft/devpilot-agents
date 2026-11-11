#requires -Version 7.0

<#
.SYNOPSIS
    Installs the DevPilot Operations canvas as a user-level GitHub Copilot extension.

.DESCRIPTION
    Copies src\DevPilot.CopilotCanvas to <Copilot home>\extensions\devpilot-ops so the canvas is
    available in every Copilot app (or CLI) session, without committing anything into consumer
    repositories. Reload extensions afterwards (ask Copilot to reload extensions, or restart the
    app), then open the "DevPilot Operations" canvas in a session for a consumer repository.

    The install also records toolkit.json: the DevPilot toolkit whose Watch-DevPilotAgents.ps1
    the canvas runs when you click Start (-Golden -Headless -CanvasBridge). A watch started in a
    terminal with -Golden -CanvasBridge is attached the same way.

.PARAMETER Destination
    Override the install folder. Defaults to $env:COPILOT_HOME\extensions\devpilot-ops, or
    ~\.copilot\extensions\devpilot-ops when COPILOT_HOME is not set.

.PARAMETER ToolkitRoot
    The DevPilot toolkit the canvas Start button launches. Defaults to the toolkit containing this
    script. Point it at a hardened toolkit install when this checkout fails the Watch trust preflight.

.PARAMETER Uninstall
    Remove a previously installed copy instead of installing.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination,
    [string]$ToolkitRoot,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\DevPilot.CopilotCanvas'
$ToolkitRoot = [IO.Path]::GetFullPath($(if ($ToolkitRoot) { $ToolkitRoot } else { Split-Path $PSScriptRoot -Parent }))
$watchScript = Join-Path $ToolkitRoot 'tools\Watch-DevPilotAgents.ps1'
if (-not $Uninstall -and -not (Test-Path -LiteralPath $watchScript -PathType Leaf)) {
    throw "'$ToolkitRoot' is not a DevPilot toolkit: $watchScript was not found."
}
if (-not $Destination) {
    $copilotHome = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $Destination = Join-Path (Join-Path $copilotHome 'extensions') 'devpilot-ops'
}
$Destination = [IO.Path]::GetFullPath($Destination)
$marker = Join-Path $Destination 'canvas-server.mjs'

if (Test-Path -LiteralPath $Destination) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw "Refusing to replace '$Destination': it does not look like a DevPilot canvas install."
    }
    if ($PSCmdlet.ShouldProcess($Destination, 'Remove previous DevPilot canvas install')) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
}
if ($Uninstall) {
    Write-Host "DevPilot canvas removed from $Destination." -ForegroundColor Cyan
    return
}
if ($PSCmdlet.ShouldProcess($Destination, 'Install DevPilot canvas')) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in @('extension.mjs', 'canvas-server.mjs', 'watch-launcher.mjs', 'ui')) {
        Copy-Item -LiteralPath (Join-Path $source $item) -Destination $Destination -Recurse -Force
    }
    $versionPath = Join-Path $ToolkitRoot 'VERSION'
    $toolkit = [ordered]@{
        schemaVersion = 1
        toolkitRoot = $ToolkitRoot
        version = $(if (Test-Path -LiteralPath $versionPath -PathType Leaf) { (Get-Content -LiteralPath $versionPath -Raw).Trim() } else { '' })
    }
    [IO.File]::WriteAllText((Join-Path $Destination 'toolkit.json'), ($toolkit | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Host "DevPilot canvas installed to $Destination." -ForegroundColor Cyan
    Write-Host "Start launches: $watchScript$(if ($toolkit.version) { " (v$($toolkit.version))" })"
    Write-Host 'Reload Copilot extensions (or restart the app), then open the "DevPilot Operations" canvas.'
}
