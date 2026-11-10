#requires -Version 7.0

<#
.SYNOPSIS
    Installs the DevPilot Operations canvas (prototype) as a user-level GitHub Copilot extension.

.DESCRIPTION
    Copies src\DevPilot.CopilotCanvas to <Copilot home>\extensions\devpilot-ops so the canvas is
    available in every Copilot app (or CLI) session, without committing anything into consumer
    repositories. Reload extensions afterwards (ask Copilot to reload extensions, or restart the
    app), then open the "DevPilot Operations" canvas in a session for a repository whose Golden
    watch was started with:

        .\tools\Watch-DevPilotAgents.ps1 -Golden -CanvasBridge

.PARAMETER Destination
    Override the install folder. Defaults to $env:COPILOT_HOME\extensions\devpilot-ops, or
    ~\.copilot\extensions\devpilot-ops when COPILOT_HOME is not set.

.PARAMETER Uninstall
    Remove a previously installed copy instead of installing.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\DevPilot.CopilotCanvas'
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
    foreach ($item in @('extension.mjs', 'canvas-server.mjs', 'ui')) {
        Copy-Item -LiteralPath (Join-Path $source $item) -Destination $Destination -Recurse -Force
    }
    Write-Host "DevPilot canvas installed to $Destination." -ForegroundColor Cyan
    Write-Host 'Reload Copilot extensions (or restart the app), then open the "DevPilot Operations" canvas.'
}
