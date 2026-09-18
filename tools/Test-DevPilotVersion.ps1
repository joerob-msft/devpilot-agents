#!/usr/bin/env pwsh
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string]$ExpectedVersion,
    [ValidatePattern('^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string]$ExpectedTag
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
$versionPath = Join-Path $root 'VERSION'
$version = (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw "VERSION must contain one stable semantic version, found '$version'."
}
$versionLine = "$($Matches[1]).$($Matches[2])"
$immutableTag = "v$version"
$channelTag = "v$versionLine"

if ($ExpectedVersion -and $version -cne $ExpectedVersion) {
    throw "VERSION '$version' does not match requested release '$ExpectedVersion'."
}
if ($ExpectedTag -and $immutableTag -cne $ExpectedTag) {
    throw "Immutable tag '$ExpectedTag' does not match VERSION '$version'."
}

$manifestPath = Join-Path $root 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
if ([string]$manifest.ModuleVersion -cne $version) {
    throw "Harness ModuleVersion '$($manifest.ModuleVersion)' does not match VERSION '$version'."
}

$packagePath = Join-Path $root 'src\DevPilot.Dashboard\package.json'
$package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 |
    ConvertFrom-Json -AsHashtable -ErrorAction Stop
if ([string]$package.version -cne $version) {
    throw "Dashboard package version '$($package.version)' does not match VERSION '$version'."
}

$lockPath = Join-Path $root 'src\DevPilot.Dashboard\package-lock.json'
$lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -AsHashtable -ErrorAction Stop
if ([string]$lock.version -cne $version -or [string]$lock.packages[''].version -cne $version) {
    throw "Dashboard package-lock root versions do not match VERSION '$version'."
}

$metadataPath = Join-Path $root 'release\release-metadata.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -AsHashtable -ErrorAction Stop
$expectedMetadata = [ordered]@{
    schemaVersion = 1
    toolkitVersion = $version
    versionLine = $versionLine
    immutableTag = $immutableTag
    channelTag = $channelTag
}
$metadataKeys = (($metadata.Keys | Sort-Object) -join "`0")
$expectedMetadataKeys = (($expectedMetadata.Keys | Sort-Object) -join "`0")
if ($metadataKeys -cne $expectedMetadataKeys) {
    throw 'Release metadata contains missing or unknown fields.'
}
foreach ($name in $expectedMetadata.Keys) {
    if ([string]$metadata[$name] -cne [string]$expectedMetadata[$name]) {
        throw "Release metadata '$name' value '$($metadata[$name])' does not match '$($expectedMetadata[$name])'."
    }
}

[pscustomobject]@{
    Version = $version
    VersionLine = $versionLine
    ImmutableTag = $immutableTag
    ChannelTag = $channelTag
}
