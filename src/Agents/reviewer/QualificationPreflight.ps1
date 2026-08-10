#Requires -Version 7.0

Set-StrictMode -Version Latest

function Invoke-ReviewerQualificationGit {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = @(& git -C $RepositoryPath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return , [string[]]$output
}

function Test-ReviewerQualificationGitIdentity {
    <#
      Offline qualification and replay may run in an app-created worktree whose
      generated local branch name is unrelated to the accepted reviewer layer.
      Exact commit, required-ref resolution, and cleanliness are the security
      identity. Live deployment additionally retains its branch-name binding.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$')][string]$RequiredRef,
        [Parameter(Mandatory)][ValidateSet("OfflineReplay", "LiveDeployment")][string]$Mode,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$')][string]$ExpectedBranch
    )
    if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
        throw "Qualification repository '$RepositoryPath' does not exist."
    }
    $headOutput = Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
        -Arguments @("rev-parse", "--verify", "HEAD")
    $head = ([string]$headOutput[0]).Trim().ToLowerInvariant()
    if ($head -cne $ExpectedCommit) {
        throw "Qualification HEAD '$head' does not match expected commit '$ExpectedCommit'."
    }
    $refOutput = Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
        -Arguments @("rev-parse", "--verify", "$RequiredRef^{commit}")
    $resolvedRef = ([string]$refOutput[0]).Trim().ToLowerInvariant()
    if ($resolvedRef -cne $ExpectedCommit) {
        throw "Qualification ref '$RequiredRef' resolves to '$resolvedRef', not expected commit '$ExpectedCommit'."
    }
    $dirty = @((Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
                -Arguments @("status", "--porcelain=v1", "--untracked-files=normal")) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($dirty.Count -ne 0) {
        throw "Qualification worktree is dirty."
    }
    $branchOutput = Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
        -Arguments @("branch", "--show-current")
    $branch = ([string]$branchOutput[0]).Trim()
    if ($Mode -eq "LiveDeployment") {
        if (-not $ExpectedBranch) {
            throw "Live deployment qualification requires -ExpectedBranch."
        }
        if ($branch -cne $ExpectedBranch) {
            throw "Live deployment branch '$branch' does not match expected branch '$ExpectedBranch'."
        }
    }
    return [pscustomobject][ordered]@{
        mode = $Mode
        head = $head
        requiredRef = $RequiredRef
        requiredRefCommit = $resolvedRef
        currentBranch = $branch
        clean = $true
    }
}
