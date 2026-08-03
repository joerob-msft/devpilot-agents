#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Fails if employer-specific values have leaked out of configuration and into
    the toolkit's code, prompts, or fixtures.

.DESCRIPTION
    The premise of this repository is that it is generic: every organization-,
    repository-, or person-specific value lives in a consumer's config file,
    never in the toolkit itself. That claim is easy to make and easy to erode
    one commit at a time, so it is enforced mechanically here and in CI rather
    than left to code review.

    Exempt by design:
      samples/  - sample configs exist precisely to show filled-in real values
      tools/    - this checker necessarily contains the patterns it looks for
      .git/

.EXAMPLE
    ./tools/Test-NoEmployerSpecifics.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string[]]$ExcludePaths = @('samples', 'tools', '.git')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$rules = @(
    @{ Name = 'ADO organization'; Pattern = '\bmsazure\b' }
    @{ Name = 'Employer repo/product names'; Pattern = '\b(AAPT|Antares|ApiHub)\b' }
    @{ Name = 'Corporate email addresses'; Pattern = '[A-Za-z0-9._%+-]+@microsoft\.com' }
    @{ Name = 'Internal host names'; Pattern = '\b[a-z0-9-]+\.(visualstudio\.com|kusto\.windows\.net|azuresre\.ai)\b' }
    @{ Name = 'Resource GUIDs'; Pattern = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' }
    @{ Name = 'Employer-specific tech conventions'; Pattern = '\b(net462|NETFRAMEWORK)\b' }
    @{ Name = 'Hardcoded pipeline identifiers'; Pattern = '"pipelineId"\s*:\s*[1-9][0-9]{3,}' }
    # A real person's alias in toolkit code is as much of a leak as an org name;
    # it belongs in a consumer's config and on the command line, not in defaults,
    # examples, or fixtures.
    @{ Name = 'Real operator aliases'; Pattern = '\b(joerob|kimjihoon)\b' }
)

# The module manifest's GUID is the module's own identity, not a resource id.
$guidExemptLeaf = 'DevPilot.AgentHarness.psd1'
# Likewise, the manifest's Project/License/Help/Icon URIs are this repository's
# own address. They necessarily contain the owning account name.
$manifestUriLine = "^\s*(ProjectUri|LicenseUri|HelpInfoURI|IconUri)\s*="
# Obviously-synthetic GUIDs are test fixtures. A placeholder GUID is one where
# every dash-separated group is a repetition of a one- or two-character unit
# ("11111111-2222-3333-4444-555555555555", "aaaaaaaa-bbbb-cccc-dddd-eeee...",
# "12121212-3434-5656-..."). A real resource GUID essentially never is, so this
# stays tight while letting fixtures through.
function Test-SyntheticGuid {
    param([string]$Guid)
    foreach ($group in ($Guid -split '-')) {
        $isRepetition = $false
        foreach ($unitLength in 1, 2) {
            if ($group.Length % $unitLength -ne 0) { continue }
            $unit = $group.Substring(0, $unitLength)
            if ($group -eq ($unit * ($group.Length / $unitLength))) { $isRepetition = $true; break }
        }
        if (-not $isRepetition) { return $false }
    }
    return $true
}
# Sample configs are named after the consumer they demonstrate, so docs and CI
# have to be able to cite them by path. Only a literal samples/ path reference
# is exempt - the name on its own is still a leak.
$sampleReference = '(?:^|[\s"''`(/\\])samples[/\\][^\s"'']*'
$scanExtensions = @('.ps1', '.psm1', '.psd1', '.json', '.md', '.yml', '.yaml')

function Test-PathExcluded {
    param([string]$RelativePath, [string[]]$Excludes)
    foreach ($ex in $Excludes) {
        if ($RelativePath -like "$ex*" -or $RelativePath -like "*\$ex\*" -or $RelativePath -like "*/$ex/*") { return $true }
    }
    return $false
}

$findings = New-Object System.Collections.Generic.List[object]

foreach ($file in (Get-ChildItem -LiteralPath $RepoRoot -Recurse -File)) {
    $rel = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    if (Test-PathExcluded -RelativePath $rel -Excludes $ExcludePaths) { continue }
    if ($scanExtensions -notcontains $file.Extension) { continue }

    $lineNo = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        $lineNo++
        foreach ($rule in $rules) {
            if ($line -notmatch $rule.Pattern) { continue }
            $hit = $Matches[0]
            if ($rule.Name -eq 'Resource GUIDs') {
                if ($file.Name -eq $guidExemptLeaf) { continue }
                if (Test-SyntheticGuid -Guid $hit) { continue }
            }
            if ($file.Name -eq $guidExemptLeaf -and $line -match $manifestUriLine) { continue }
            # A citation of a sample file path is documentation, not a leak.
            if ($line -match $sampleReference -and $Matches[0] -like "*$hit*") { continue }
            $text = $line.Trim()
            if ($text.Length -gt 100) { $text = $text.Substring(0, 100) + '...' }
            [void]$findings.Add([pscustomobject]@{ File = $rel; Line = $lineNo; Rule = $rule.Name; Text = $text })
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host "PASS - no employer-specific values outside: $($ExcludePaths -join ', ')" -ForegroundColor Green
    exit 0
}

Write-Host "FAIL - $($findings.Count) employer-specific value(s) in toolkit code:" -ForegroundColor Red
$findings | Sort-Object File, Line | Format-Table -AutoSize
Write-Host "These belong in a consumer's config file (see samples/), not in the toolkit." -ForegroundColor Yellow
exit 1
