#Requires -Version 7.0

<#
.SYNOPSIS
    Proves the shadow child recomputes childRequestSha256 the same way the
    coordinator does, and refuses a request whose fields were altered while the
    supplied digest was left untouched (finding F11).

.DESCRIPTION
    The coordinator (C#) computes the child request digest over its own canonical
    form; the child (PowerShell) must reproduce that digest to refuse a tampered
    request without a shared key. A second implementation of a canonical form is
    exactly the kind of thing that drifts silently, so this test does not trust
    the two to agree: it has the coordinator EMIT real child requests carrying the
    digest it computed, then loads the child's own canonicaliser and verifier and
    checks that every emitted request passes and that a tampered one is refused.

.PARAMETER RepoRoot
    Defaults to the repository containing this script.

.PARAMETER Scratch
    Where the emitted requests are written. Defaults to a temporary directory.
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
$childScript = Join-Path $RepoRoot 'tools/Invoke-ShadowCoordinatorChild.ps1'
if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw "The coordinator project '$project' does not exist." }
if (-not (Test-Path -LiteralPath $childScript -PathType Leaf)) { throw "The child script '$childScript' does not exist." }

$owned = $false
if ([string]::IsNullOrWhiteSpace($Scratch)) {
    $Scratch = Join-Path ([IO.Path]::GetTempPath()) ('child-integrity-' + [Guid]::NewGuid().ToString('n'))
    $owned = $true
}
New-Item -ItemType Directory -Path $Scratch -Force | Out-Null

$checks = 0
$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Integrity {
    param([Parameter(Mandatory)][AllowNull()]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) {
        [void]$script:failures.Add($Message)
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    } else {
        Write-Host "  PASS  $Message"
    }
}

# The child script owns the mandatory RequestPath parameter and a main body, so it
# cannot simply be dot-sourced. Its verifier and canonicaliser are lifted out by
# name through the parser instead, which keeps this test measuring the SAME code
# the child runs rather than a copy of it.
$script:ShadowChildRequestContract = 'devpilot.shadow-run-coordinator.child-request.v1'
$script:ShadowChildUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$wanted = @(
    'ConvertTo-ShadowCanonicalScalarText',
    'ConvertTo-ShadowCanonicalText',
    'Get-ShadowChildRequestDigest',
    'Read-ShadowChildRequest',
    'Get-ShadowChildField',
    'Test-ShadowChildPathEquals',
    'Assert-ShadowChildRequestAuthority'
)
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($childScript, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "The child script did not parse: $($parseErrors -join '; ')" }
$found = [System.Collections.Generic.HashSet[string]]::new()
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $definition.Name) {
        . ([scriptblock]::Create($definition.Extent.Text))
        [void]$found.Add($definition.Name)
    }
}

try {
    Write-Host 'Child request integrity'
    Assert-Integrity ($found.Count -eq $wanted.Count) "the child exposes every function under test ($($found -join ', '))"

    Write-Host 'Building ShadowRunCoordinator...'
    $priorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $build = & dotnet build $project -c Debug --nologo -v quiet 2>&1
        if ([int]$LASTEXITCODE -ne 0) {
            $build | ForEach-Object { Write-Host $_ }
            throw "dotnet build failed with exit code $LASTEXITCODE."
        }
        & dotnet run --project $project -c Debug --no-build -- --selftest-emit-child-requests $Scratch | Out-Null
        if ([int]$LASTEXITCODE -ne 0) { throw "emitting sample child requests failed with exit code $LASTEXITCODE." }
    }
    finally { $PSNativeCommandUseErrorActionPreference = $priorPreference }

    $emitted = @(Get-ChildItem -LiteralPath $Scratch -Filter '*.request.json' -File)
    Assert-Integrity ($emitted.Count -ge 5) "the coordinator emitted the sample requests (found $($emitted.Count))"

    # Every request the coordinator wrote must pass the child's recompute. A single
    # divergence in the canonical form - an escape, a sort, a number - fails here.
    foreach ($file in $emitted) {
        $accepted = $false
        $reason = ''
        try {
            $null = Read-ShadowChildRequest -Path $file.FullName
            $accepted = $true
        }
        catch { $reason = $_.Exception.Message }
        Assert-Integrity $accepted "the child recompute matches the coordinator digest for '$($file.Name)'$(if ($reason) { " :: $reason" })"
    }

    # The tamper case: alter a field value in a request the coordinator signed,
    # leave its childRequestSha256 untouched, and prove the child refuses. Without
    # the recompute this alteration would sail through and be echoed into a result.
    $plain = Join-Path $Scratch 'plain.request.json'
    $original = [IO.File]::ReadAllText($plain)
    Assert-Integrity ($original.Contains('reviewer-a')) 'the sample request holds the field the tamper case rewrites'
    $tampered = $original.Replace('reviewer-a', 'reviewer-b')
    $tamperPath = Join-Path $Scratch 'tampered.request.json'
    [IO.File]::WriteAllBytes($tamperPath, $script:ShadowChildUtf8.GetBytes($tampered))
    $refused = $false
    $refusalMessage = ''
    try { $null = Read-ShadowChildRequest -Path $tamperPath }
    catch { $refused = $true; $refusalMessage = $_.Exception.Message }
    Assert-Integrity $refused 'the child refuses a request whose field was altered under an untouched digest'
    Assert-Integrity ($refusalMessage -like '*integrity check*') "the refusal names the integrity check ($refusalMessage)"

    # Recomputing the public digest is not authority. Rewrite the result and
    # toolkit paths, recompute childRequestSha256 so the self-check passes, then
    # prove the independently supplied launch values refuse it before either path
    # can be used.
    $originalRequest = Read-ShadowChildRequest -Path $plain
    $authorityRequest = $originalRequest | ConvertTo-Json -Depth 32 | ConvertFrom-Json -Depth 32
    $authorityRequest | Add-Member -NotePropertyName toolkitRoot -NotePropertyValue $RepoRoot -Force
    $authorityRequest.childRequestSha256 = Get-ShadowChildRequestDigest -Request $authorityRequest
    $expectedDigest = [string]$authorityRequest.childRequestSha256
    $expectedResult = [string]$authorityRequest.resultPath
    $expectedToolkit = [string]$authorityRequest.toolkitRoot
    $forgedRequest = $authorityRequest | ConvertTo-Json -Depth 32 | ConvertFrom-Json -Depth 32
    $forgedRequest.resultPath = Join-Path $Scratch 'attacker\result.json'
    $forgedRequest.toolkitRoot = Join-Path $Scratch 'attacker-toolkit'
    $forgedRequest.childRequestSha256 = Get-ShadowChildRequestDigest -Request $forgedRequest
    Assert-Integrity ([string]$forgedRequest.childRequestSha256 -cne $expectedDigest) `
        'the recomputed forged request has a different coordinator-held identity'
    $forgeryRefused = $false
    try {
        $null = Assert-ShadowChildRequestAuthority -Request $forgedRequest -RequestPath $plain `
            -ExpectedRequestSha256 $expectedDigest -ExpectedResultPath $expectedResult `
            -ExpectedToolkitRoot $expectedToolkit
    }
    catch { $forgeryRefused = $true }
    Assert-Integrity $forgeryRefused `
        'a self-consistent forged digest cannot authorize request-controlled toolkit or result paths'

    Write-Host ''
    if ($failures.Count -eq 0) {
        Write-Host "All $checks child request integrity checks passed." -ForegroundColor Green
        exit 0
    }
    Write-Host "FAILED: $($failures.Count) of $checks child request integrity checks." -ForegroundColor Red
    exit 1
}
finally {
    if ($owned) { Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
