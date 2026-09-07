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
        -ExpectedCommit $head -RequiredRef "refs/heads/required-reviewer-layer" `
        -Mode OfflineReplay
    Assert-True ($offline.currentBranch -ceq "generated-app-worktree") `
        "Offline qualification did not accept the safe generated worktree branch."
    Assert-True ($offline.branchState -ceq "attached") `
        "Offline qualification did not report the attached branch state."
    $operatorResult = & (Join-Path $repoRoot "tools\Assert-ReviewerQualificationPreflight.ps1") `
        -RepositoryPath $tempRoot -ExpectedCommit $head `
        -RequiredRef "refs/heads/required-reviewer-layer" `
        -Mode OfflineReplay | ConvertFrom-Json
    Assert-True ([bool]$operatorResult.clean -and
        [string]$operatorResult.requiredRefCommit -ceq $head) `
        "The operator qualification preflight did not enforce the tested offline policy."

    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit ("f" * 40) `
            -RequiredRef "refs/heads/required-reviewer-layer" -Mode OfflineReplay
    } "does not match expected commit"

    Set-Content -LiteralPath (Join-Path $tempRoot "fixture.txt") -Value "two" -Encoding utf8NoBOM
    Invoke-Git $tempRoot @("add", "fixture.txt")
    Invoke-Git $tempRoot @("commit", "--quiet", "-m", "advance")
    $newHead = (& git -C $tempRoot rev-parse HEAD).Trim()
    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit $newHead `
            -RequiredRef "refs/heads/required-reviewer-layer" -Mode OfflineReplay
    } "resolves to"

    Invoke-Git $tempRoot @("branch", "-f", "required-reviewer-layer", $newHead)
    Set-Content -LiteralPath (Join-Path $tempRoot "dirty.txt") -Value "dirty" -Encoding utf8NoBOM
    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit $newHead `
            -RequiredRef "refs/heads/required-reviewer-layer" -Mode OfflineReplay
    } "dirty"
    Remove-Item -LiteralPath (Join-Path $tempRoot "dirty.txt")

    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit $newHead -RequiredRef "refs/heads/required-reviewer-layer" `
            -Mode LiveDeployment -ExpectedBranch "required-reviewer-layer"
    } "does not match expected branch"

    $live = Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
        -ExpectedCommit $newHead -RequiredRef "refs/heads/required-reviewer-layer" `
        -Mode LiveDeployment -ExpectedBranch "generated-app-worktree"
    Assert-True $live.clean "Live qualification did not preserve the clean-worktree requirement."

    Invoke-Git $tempRoot @("tag", "ambiguous-reviewer-layer", $head)
    Invoke-Git $tempRoot @("branch", "ambiguous-reviewer-layer", $newHead)
    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit $newHead -RequiredRef "ambiguous-reviewer-layer" `
            -Mode OfflineReplay
    } "unambiguous full ref"
    $warningSeparated = @(Invoke-ReviewerQualificationGit -RepositoryPath $tempRoot `
            -Arguments @("rev-parse", "--verify", "ambiguous-reviewer-layer^{commit}"))
    Assert-True ($warningSeparated.Count -eq 1 -and
        $warningSeparated[0] -match '^[0-9a-f]{40}$') `
        "Git stderr warning text contaminated a valid stdout object ID."
    $fullRef = Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
        -ExpectedCommit $newHead -RequiredRef "refs/heads/ambiguous-reviewer-layer" `
        -Mode OfflineReplay
    Assert-True ($fullRef.requiredRefCommit -ceq $newHead) `
        "A validated full branch ref did not resolve exactly."

    Invoke-Git $tempRoot @("config", "alias.warning-only",
        '!echo "warning: synthetic status warning" >&2')
    $warningOnly = @(Invoke-ReviewerQualificationGit -RepositoryPath $tempRoot `
            -Arguments @("warning-only"))
    Assert-True ($warningOnly.Count -eq 0) `
        "A successful stderr-only Git warning was parsed as dirty stdout."

    Assert-Throws {
        Read-ReviewerQualificationSingleOutput -Output @() -Operation "test scalar"
    } "exactly one nonempty stdout line"
    Assert-Throws {
        Read-ReviewerQualificationSingleOutput -Output @("one", "two") `
            -Operation "test scalar"
    } "exactly one nonempty stdout line"
    Assert-Throws {
        Read-ReviewerQualificationBranchOutput -Output @("one", "two")
    } "at most one nonempty stdout line"
    Assert-Throws {
        Assert-ReviewerQualificationNoOutput -Output @("unexpected") `
            -Operation "test no-output"
    } "expected no stdout"

    try {
        Invoke-ReviewerQualificationGit -RepositoryPath $tempRoot `
            -Arguments @("rev-parse", "--verify", "refs/heads/does-not-exist") | Out-Null
        throw "Expected a sanitized nonzero Git failure."
    }
    catch {
        Assert-True ($_.Exception.Message -match "failed with exit code" -and
            $_.Exception.Message -notmatch '[\r\n\x00-\x1f\x7f]') `
            "A nonzero Git failure did not produce a sanitized diagnostic."
    }

    Invoke-Git $tempRoot @("checkout", "--quiet", "--detach", $newHead)
    $detachedOffline = Test-ReviewerQualificationGitIdentity `
        -RepositoryPath $tempRoot -ExpectedCommit $newHead `
        -RequiredRef "refs/heads/required-reviewer-layer" -Mode OfflineReplay
    Assert-True ($detachedOffline.branchState -ceq "detached" -and
        $null -eq $detachedOffline.currentBranch) `
        "Detached offline qualification did not report its branch state truthfully."
    Assert-Throws {
        Test-ReviewerQualificationGitIdentity -RepositoryPath $tempRoot `
            -ExpectedCommit $newHead `
            -RequiredRef "refs/heads/required-reviewer-layer" `
            -Mode LiveDeployment -ExpectedBranch "generated-app-worktree"
    } "refuses detached HEAD"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host "Reviewer qualification preflight checks passed ($checks checks)."
