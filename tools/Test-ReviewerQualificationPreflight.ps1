#Requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\QualificationPreflight.ps1")

$checks = 0
function Assert-True([bool]$Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $script:checks++
    try { & $Action; throw "Expected failure matching '$Pattern'." }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
}
function Invoke-Git([string]$Path, [string[]]$Arguments) {
    & git -C $Path @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed." }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("reviewer-preflight-" + [guid]::NewGuid().ToString("N"))
try {
    [void](New-Item -ItemType Directory -Path $tempRoot)
    Invoke-Git $tempRoot @("init", "--quiet")
    Invoke-Git $tempRoot @("config", "user.name", "Reviewer Test")
    Invoke-Git $tempRoot @("config", "user.email", "reviewer@example.invalid")
    Set-Content -LiteralPath (Join-Path $tempRoot "fixture.txt") -Value "one" -Encoding utf8NoBOM
    Invoke-Git $tempRoot @("add", "fixture.txt")
    Invoke-Git $tempRoot @("commit", "--quiet", "-m", "fixture")
    $head = (& git -C $tempRoot rev-parse HEAD).Trim()
    Invoke-Git $tempRoot @("branch", "required-reviewer-layer", $head)
    Invoke-Git $tempRoot @("checkout", "--quiet", "-b", "generated-app-worktree")

    $offline = Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
        -ExpectedCommit $head -RequiredRef "required-reviewer-layer" -Mode OfflineReplay
    Assert-True ($offline.currentBranch -ceq "generated-app-worktree") `
        "Offline qualification did not accept the safe generated worktree branch."
    $operatorResult = & (Join-Path $repoRoot "tools\Assert-ReviewerQualificationPreflight.ps1") `
        -RepositoryPath $tempRoot -ExpectedCommit $head `
        -RequiredRef "required-reviewer-layer" -Mode OfflineReplay | ConvertFrom-Json
    Assert-True ([bool]$operatorResult.clean -and
        [string]$operatorResult.requiredRefCommit -ceq $head) `
        "The operator qualification preflight did not enforce the tested offline policy."

    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit ("f" * 40) -RequiredRef "required-reviewer-layer" -Mode OfflineReplay
    } "does not match expected commit"

    Set-Content -LiteralPath (Join-Path $tempRoot "fixture.txt") -Value "two" -Encoding utf8NoBOM
    Invoke-Git $tempRoot @("add", "fixture.txt")
    Invoke-Git $tempRoot @("commit", "--quiet", "-m", "advance")
    $newHead = (& git -C $tempRoot rev-parse HEAD).Trim()
    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit $newHead -RequiredRef "required-reviewer-layer" -Mode OfflineReplay
    } "resolves to"

    Invoke-Git $tempRoot @("branch", "-f", "required-reviewer-layer", $newHead)
    Set-Content -LiteralPath (Join-Path $tempRoot "dirty.txt") -Value "dirty" -Encoding utf8NoBOM
    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit $newHead -RequiredRef "required-reviewer-layer" -Mode OfflineReplay
    } "dirty"
    Remove-Item -LiteralPath (Join-Path $tempRoot "dirty.txt")

    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit $newHead -RequiredRef "required-reviewer-layer" `
            -Mode LiveDeployment -ExpectedBranch "required-reviewer-layer"
    } "does not match expected branch"

    $live = Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
        -ExpectedCommit $newHead -RequiredRef "required-reviewer-layer" `
        -Mode LiveDeployment -ExpectedBranch "generated-app-worktree"
    Assert-True $live.clean "Live qualification did not preserve the clean-worktree requirement."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host "Reviewer qualification preflight checks passed ($checks checks)."
