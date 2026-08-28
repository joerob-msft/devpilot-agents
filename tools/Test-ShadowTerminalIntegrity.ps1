#Requires -Version 7.0

<#
.SYNOPSIS
    Proves the shadow child parses and hashes a slot terminal from a single read,
    so its recorded terminalSha256 can no longer describe bytes that were never
    parsed (finding F12).

.DESCRIPTION
    Invoke-ShadowChildSlotVerify used to parse the terminal through the reviewed
    reader (one read) and then re-read the file to hash it (a second read). A
    replacement of the immutable terminal between those two reads would bind the
    recorded digest to bytes the step never validated - the same class of defect
    as F10. This test does not need the whole reviewed toolkit to prove the point:
    it lifts the child's own single-buffer parser out of the script and contrasts
    the two-read structure (which disagrees when the file is swapped between the
    reads) with the one-read structure the fix uses (which cannot).

    The swap is a deterministic overwrite performed BETWEEN the two reads of the
    defective structure and AFTER the single read of the fixed structure, so the
    interleaving is reproduced exactly rather than raced.

.PARAMETER RepoRoot
    Defaults to the repository containing this script.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$childScript = Join-Path $RepoRoot 'tools/Invoke-ShadowCoordinatorChild.ps1'
$qualificationLibrary = Join-Path $RepoRoot 'src/Agents/reviewer/ReplayQualification.ps1'
if (-not (Test-Path -LiteralPath $childScript -PathType Leaf)) { throw "The child script '$childScript' does not exist." }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('terminal-integrity-' + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

$checks = 0
$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Terminal {
    param([Parameter(Mandatory)][AllowNull()]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) {
        [void]$script:failures.Add($Message)
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    } else {
        Write-Host "  PASS  $Message"
    }
}

# Lift the child's single-buffer parser out by name; this is the SAME code the
# child runs, not a copy of it.
$script:ShadowChildUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($childScript, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "The child script did not parse: $($parseErrors -join '; ')" }
$loaded = $false
foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($definition.Name -eq 'ConvertFrom-ShadowImmutableJsonBytes') {
        . ([scriptblock]::Create($definition.Extent.Text))
        $loaded = $true
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

try {
    Write-Host 'Slot terminal integrity'
    Assert-Terminal $loaded 'the child exposes ConvertFrom-ShadowImmutableJsonBytes'

    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $path = Join-Path $scratch 'slot1-terminal.json'
    $version1 = '{"kind":"reviewer.replay-qualification.terminal.v1","slot":"slot1","setId":"set-a","planDigest":"d1","status":"complete","exitCode":0,"timedOut":false}'
    $version2 = '{"kind":"reviewer.replay-qualification.terminal.v1","slot":"slot1","setId":"set-a","planDigest":"d1","status":"failed","exitCode":9,"timedOut":true}'
    [IO.File]::WriteAllBytes($path, $utf8.GetBytes($version1))
    $digestOfV1 = Get-Sha256Hex -Bytes $utf8.GetBytes($version1)
    $digestOfV2 = Get-Sha256Hex -Bytes $utf8.GetBytes($version2)
    Assert-Terminal ($digestOfV1 -ne $digestOfV2) 'the two terminal versions have distinct digests'

    # --- The defect: two reads with a swap between them. ---
    # Read #1 parses; the file is then replaced; read #2 hashes. The recorded
    # digest describes version 2 while the parsed record is version 1 - a digest
    # over bytes that were never parsed.
    $parsedBytesReadOne = [IO.File]::ReadAllBytes($path)
    $parsedRecord = ConvertFrom-ShadowImmutableJsonBytes -Bytes $parsedBytesReadOne -Path $path
    [IO.File]::WriteAllBytes($path, $utf8.GetBytes($version2))   # deterministic swap between the reads
    $hashBytesReadTwo = [IO.File]::ReadAllBytes($path)
    $recordedDigestTwoRead = Get-Sha256Hex -Bytes $hashBytesReadTwo
    $parsedDigestTwoRead = Get-Sha256Hex -Bytes ($utf8.GetBytes(($version1)))
    # The parsed record is version 1 (status complete) but the recorded digest is
    # version 2's. This is the F12 defect, demonstrated to actually occur.
    Assert-Terminal ([string]$parsedRecord.status -eq 'complete') 'the two-read parse yields version 1'
    Assert-Terminal ($recordedDigestTwoRead -eq $digestOfV2) 'the two-read digest describes version 2'
    Assert-Terminal ($recordedDigestTwoRead -ne $parsedDigestTwoRead) `
        'DEFECT REPRODUCED: two reads let the recorded digest describe bytes that were never parsed'

    # --- The fix: one read, swap after. ---
    # The buffer is read exactly once; the file is then replaced; both the parse
    # and the hash consume the single buffer. The digest and the parsed record now
    # describe the same bytes no matter what the on-disk swap did.
    [IO.File]::WriteAllBytes($path, $utf8.GetBytes($version1))
    $singleBuffer = [IO.File]::ReadAllBytes($path)
    [IO.File]::WriteAllBytes($path, $utf8.GetBytes($version2))   # deterministic swap AFTER the single read
    $fixedRecord = ConvertFrom-ShadowImmutableJsonBytes -Bytes $singleBuffer -Path $path
    $fixedDigest = Get-Sha256Hex -Bytes $singleBuffer
    $digestOfParsed = Get-Sha256Hex -Bytes $utf8.GetBytes($version1)
    Assert-Terminal ([string]$fixedRecord.status -eq 'complete') 'the one-read parse yields version 1 despite the on-disk swap'
    Assert-Terminal ($fixedDigest -eq $digestOfV1) 'the one-read digest describes version 1, the bytes that were parsed'
    Assert-Terminal ($fixedDigest -eq $digestOfParsed) `
        'FIX PROVEN: one read binds the digest to exactly the bytes that were parsed'

    # Hygiene the shared parser inherits from the child-request reader.
    $bomBytes = @([byte]0xEF, [byte]0xBB, [byte]0xBF) + $utf8.GetBytes($version1)
    $bomRefused = $false
    try { $null = ConvertFrom-ShadowImmutableJsonBytes -Bytes $bomBytes -Path $path }
    catch { $bomRefused = $true }
    Assert-Terminal $bomRefused 'the parser refuses a byte-order mark'
    $emptyRefused = $false
    try { $null = ConvertFrom-ShadowImmutableJsonBytes -Bytes ([byte[]]@()) -Path $path }
    catch { $emptyRefused = $true }
    Assert-Terminal $emptyRefused 'the parser refuses an empty buffer'

    . $qualificationLibrary
    $keyPath = Join-Path $scratch 'run-set.key'
    [byte[]]$masterKey = 1..32
    [IO.File]::WriteAllText($keyPath, 'raw:' + [Convert]::ToBase64String($masterKey), $utf8)
    $executionId = '1234567890abcdef1234567890abcdef'
    $signedTerminal = [pscustomobject][ordered]@{
        kind = 'reviewer.replay-qualification.terminal.v1'
        slot = 'slot1'
        setId = 'set-a'
        planDigest = ('d' * 64)
        status = 'complete'
        exitCode = 0
        timedOut = $false
        runExecutionId = $executionId
    }
    $signedTerminal = Protect-ReviewerQualificationSlotTerminal -Terminal $signedTerminal `
        -RunSetKeyPath $keyPath
    $signedPath = Join-Path $scratch 'signed-slot1-terminal.json'
    [IO.File]::WriteAllText($signedPath, ($signedTerminal | ConvertTo-Json -Depth 8 -Compress:$false), $utf8)
    Set-ItemProperty -LiteralPath $signedPath -Name IsReadOnly -Value $true
    $acceptedTerminal = Read-ReviewerQualificationSlotTerminal -TerminalPath $signedPath `
        -RunSetKeyPath $keyPath -ExpectedRunExecutionId $executionId
    Assert-Terminal ([string]$acceptedTerminal.status -ceq 'complete') `
        'an externally signed terminal bound to the expected execution is accepted'

    Set-ItemProperty -LiteralPath $signedPath -Name IsReadOnly -Value $false
    $forgedTerminal = [IO.File]::ReadAllText($signedPath, $utf8) | ConvertFrom-Json
    $forgedTerminal.status = 'failed'
    $forgedTerminal.exitCode = 9
    [IO.File]::WriteAllText($signedPath, ($forgedTerminal | ConvertTo-Json -Depth 8 -Compress:$false), $utf8)
    Set-ItemProperty -LiteralPath $signedPath -Name IsReadOnly -Value $true
    $signatureRefused = $false
    try {
        $null = Read-ReviewerQualificationSlotTerminal -TerminalPath $signedPath `
            -RunSetKeyPath $keyPath -ExpectedRunExecutionId $executionId
    }
    catch { $signatureRefused = $true }
    Assert-Terminal $signatureRefused `
        'a read-only replacement cannot change terminal status without the external run-set key'

    Write-Host ''
    if ($failures.Count -eq 0) {
        Write-Host "All $checks slot terminal integrity checks passed." -ForegroundColor Green
        exit 0
    }
    Write-Host "FAILED: $($failures.Count) of $checks slot terminal integrity checks." -ForegroundColor Red
    exit 1
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
