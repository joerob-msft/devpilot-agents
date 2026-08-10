#Requires -Version 7.0

Set-StrictMode -Version Latest

function ConvertTo-ReviewerQualificationDiagnostic {
    param([AllowEmptyString()][string]$Value)

    $sanitized = [regex]::Replace($Value, '[\x00-\x1f\x7f]+', ' ')
    $sanitized = [regex]::Replace($sanitized, '\s+', ' ').Trim()
    if ($sanitized.Length -gt 2048) {
        $sanitized = $sanitized.Substring(0, 2048) + "..."
    }
    if (-not $sanitized) { return "<no stderr>" }
    return $sanitized
}

function Invoke-ReviewerQualificationGit {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $gitCommand = Get-Command -Name git -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        & $gitCommand.Source -C $RepositoryPath @Arguments 1> $stdoutFile 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stdout = [IO.File]::ReadAllText($stdoutFile)
        $stderr = [IO.File]::ReadAllText($stderrFile)
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0) {
        $diagnostic = ConvertTo-ReviewerQualificationDiagnostic -Value $stderr
        $command = ConvertTo-ReviewerQualificationDiagnostic -Value ($Arguments -join " ")
        throw "git $command failed with exit code ${exitCode}: $diagnostic"
    }
    return [string[]]@($stdout -split '\r?\n' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Read-ReviewerQualificationSingleOutput {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Output,
        [Parameter(Mandatory)][string]$Operation
    )

    $lines = @($Output | Where-Object { $null -ne $_ })
    if ($lines.Count -ne 1) {
        throw "Qualification $Operation expected exactly one nonempty stdout line; received $($lines.Count)."
    }
    return $lines[0]
}

function Read-ReviewerQualificationBranchOutput {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Output)

    $lines = @($Output | Where-Object { $null -ne $_ })
    if ($lines.Count -gt 1) {
        throw "Qualification branch read expected at most one nonempty stdout line; received $($lines.Count)."
    }
    if ($lines.Count -eq 0) { return $null }
    return $lines[0]
}

function Assert-ReviewerQualificationNoOutput {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Output,
        [Parameter(Mandatory)][string]$Operation
    )

    $lines = @($Output | Where-Object { $null -ne $_ })
    if ($lines.Count -ne 0) {
        throw "Qualification $Operation expected no stdout; received $($lines.Count) nonempty line(s)."
    }
}

function Get-ReviewerQualificationGitState {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$RequiredRef
    )

    $headOutput = @(Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
            -Arguments @("rev-parse", "--verify", "HEAD"))
    $head = Read-ReviewerQualificationSingleOutput -Output $headOutput -Operation "HEAD read"
    if ($head -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Qualification HEAD read returned an invalid object ID."
    }

    $refOutput = @(Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
            -Arguments @("rev-parse", "--verify", "--end-of-options", "$RequiredRef^{commit}"))
    $resolvedRef = Read-ReviewerQualificationSingleOutput -Output $refOutput `
        -Operation "required-ref read"
    if ($resolvedRef -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Qualification required-ref read returned an invalid object ID."
    }

    $dirty = @(Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
            -Arguments @("status", "--porcelain=v1", "--untracked-files=normal"))
    $branchOutput = @(Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
            -Arguments @("branch", "--show-current"))
    $branch = Read-ReviewerQualificationBranchOutput -Output $branchOutput

    return [pscustomobject][ordered]@{
        head = $head.ToLowerInvariant()
        requiredRefCommit = $resolvedRef.ToLowerInvariant()
        dirty = [string[]]$dirty
        branch = $branch
    }
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
    if (-not $RequiredRef.StartsWith("refs/", [StringComparison]::Ordinal)) {
        throw "Qualification required ref '$RequiredRef' must be an unambiguous full ref name under refs/."
    }
    try {
        $refFormatOutput = @(Invoke-ReviewerQualificationGit -RepositoryPath $RepositoryPath `
                -Arguments @("check-ref-format", $RequiredRef))
        Assert-ReviewerQualificationNoOutput -Output $refFormatOutput `
            -Operation "required-ref syntax check"
    }
    catch {
        $diagnostic = ConvertTo-ReviewerQualificationDiagnostic -Value $_.Exception.Message
        throw "Qualification required ref '$RequiredRef' is invalid: $diagnostic"
    }

    $initial = Get-ReviewerQualificationGitState -RepositoryPath $RepositoryPath `
        -RequiredRef $RequiredRef
    if ($initial.head -cne $ExpectedCommit) {
        throw "Qualification HEAD '$($initial.head)' does not match expected commit '$ExpectedCommit'."
    }
    if ($initial.requiredRefCommit -cne $ExpectedCommit) {
        throw "Qualification ref '$RequiredRef' resolves to '$($initial.requiredRefCommit)', not expected commit '$ExpectedCommit'."
    }
    if ($initial.dirty.Count -ne 0) {
        throw "Qualification worktree is dirty."
    }
    $detached = [string]::IsNullOrEmpty($initial.branch)
    if ($Mode -eq "LiveDeployment") {
        if ($detached) {
            throw "Live deployment qualification refuses detached HEAD."
        }
        if (-not $ExpectedBranch) {
            throw "Live deployment qualification requires -ExpectedBranch."
        }
        if ($initial.branch -cne $ExpectedBranch) {
            throw "Live deployment branch '$($initial.branch)' does not match expected branch '$ExpectedBranch'."
        }
    }

    $final = Get-ReviewerQualificationGitState -RepositoryPath $RepositoryPath `
        -RequiredRef $RequiredRef
    if ($final.head -cne $initial.head -or
        $final.requiredRefCommit -cne $initial.requiredRefCommit -or
        ($final.dirty -join "`0") -cne ($initial.dirty -join "`0") -or
        $final.branch -cne $initial.branch) {
        throw "Qualification Git identity changed during preflight."
    }

    return [pscustomobject][ordered]@{
        mode = $Mode
        head = $initial.head
        requiredRef = $RequiredRef
        requiredRefCommit = $initial.requiredRefCommit
        branchState = if ($detached) { "detached" } else { "attached" }
        currentBranch = if ($detached) { $null } else { $initial.branch }
        clean = $true
    }
}
