#Requires -Version 7.0

<#
    Offline replay QUALIFICATION planning.

    A qualification run set is declared and sealed BEFORE its runs exist, on
    purpose: an operator who picks which runs to compare after seeing them has
    chosen an answer rather than reconciled anything. The cost of that ordering
    is that a declaration made against an invocation that cannot start is a
    spoiled set - and the four ways it has actually been spoiled were all
    invocation or evidence defects, not review defects:

      * a slot naming a model the agent's startup validation no longer accepts
        (a wrapper that had written a model version down for itself),
      * a slot that omitted -RepoPath, so the agent tried to resolve the
        reviewed repository from a config that lives outside one and threw,
      * a run whose first source read was a repository-wide pull-request list
        that the bounded, sealed snapshot deliberately does not carry, and
      * a sealed snapshot whose recorded responses were captured REST bodies
        rather than tool results, which loads and binds perfectly and which no
        reader can consume (now refused when the snapshot is loaded, here and
        in the agent, rather than at the read that needs it).

    All four died before a model was ever launched, after the set had been
    declared. So this library builds the COMPLETE argument vector for every
    slot, validates every input the agent will validate at startup, and then
    runs that exact vector through the AGENT ITSELF up to the agent's own
    model-launch boundary - where the agent also issues the run's first source
    read against the sealed snapshot - all before the caller is allowed to
    declare anything. There is exactly one constructed argv per slot; the
    preflight and the real invocation consume the same array, so a preflight
    that passes cannot be describing a different command than the one that runs.

    Nothing here writes a file, launches a model, or opens a network
    connection. The one child process it starts is the agent in its own
    prelaunch mode, which validates and exits before it creates anything.
#>

Set-StrictMode -Version Latest

$script:ReviewerQualificationRefusedSwitches = @(
    "-EnableFindingComments", "-EnableSummaryComment", "-EnableApprovalVote",
    "-EnableVerifiedCommentGate", "-EnableVerifiedSuggestionGate", "-EnableVerifiedApprovalGate",
    "-PromotePreview", "-PromoteVerifiedPreview", "-CaptureSourceTransportArtifactPath",
    "-CaptureSourceTransportOnly", "-DryRun", "-IncludeOwnPullRequests"
)
# The agent's own prelaunch marker. The boundary is inside the agent, not in
# anything this library generates: a stand-in built from copied parameter
# metadata would bind the argv and still miss every check the agent's body
# performs after binding, which is where both real defects actually landed.
$script:ReviewerQualificationPrelaunchMarker = "REVIEWER_QUALIFICATION_PRELAUNCH_V1"
$script:ReviewerQualificationPrelaunchSwitch = "-QualificationPrelaunch"
$script:ReviewerQualificationPlanDigestKind = "reviewer.replay-qualification.plan.v1"

# --- Typed qualification faults ------------------------------------------
# The classification of a published run set as CORRUPT is a decision, and a
# decision must not be made by reading English. Matching an exception message
# against words like 'corrupt' or 'tampered' means the verdict depends on
# prose that was written to be read by a person, and on text this code does not
# own: a qualification root at C:\work\corrupt-repro\ or a run-set directory
# whose absolute path carries the word 'tampered' interpolates into a perfectly
# benign message - "Expected exactly one sealed run-set declaration under
# 'C:\work\corrupt-repro\runset'" - and the reader calls a healthy set corrupt.
# Reworded messages break it the other way, silently, by declaring a genuinely
# corrupt set healthy.
#
# So every fault this library raises about a published set carries a CODE, set
# on the exception's Data and again as the error id, and the corrupt/not-corrupt
# question is answered by membership in a list that lives here beside the
# throws. Messages stay exactly as they were - they are for people - and no
# reader has to parse them.
$script:ReviewerQualificationFaultCodeKey = "reviewerQualificationFaultCode"

# The faults that mean the PUBLISHED SET ITSELF is unusable: an envelope that no
# longer verifies, a verification that could not be performed, an inventory that
# a complete publish always carries and this one does not, or a token that is
# not a token. Each is a property of the published bytes alone.
$script:ReviewerQualificationCorruptFaultCodes = @(
    "declarationSignatureUnverified",
    "declarationVerificationFaulted",
    "publishedTokenMissing",
    "publishedTokenMalformed",
    "launchTokenMalformed"
)

# Named here so that every caller spells them the same way, and so that reading
# this block is enough to see which faults are deliberately NOT corruption.
# 'declarationVerificationUnavailable' is the important one: a verifier that
# could not be RUN - no tool at that path, no key file, an unreadable file -
# says something about this machine and nothing about the published bytes, and
# reporting it as corruption would put the verdict back on something other than
# the set itself. 'planReconstructionFailed' is a fault in rebuilding the
# CALLER'S plan, which a healthy published set cannot be blamed for.
$script:ReviewerQualificationVerificationUnavailableFaultCode = "declarationVerificationUnavailable"
$script:ReviewerQualificationPlanReconstructionFaultCode = "planReconstructionFailed"

function New-ReviewerQualificationFault {
    <#
        Builds a terminating error that carries a machine-readable code as well
        as its human message. Thrown with 'throw', it reaches the caller's catch
        with the code on $_.Exception.Data and on $_.FullyQualifiedErrorId, and
        with the message byte-for-byte unchanged - so a caller that classifies
        by code and an operator who reads the text see the same event.

        When the fault is a re-raise of one that crossed a tool boundary, the
        original goes in as the inner exception. That is not decoration: the code
        reader below walks the inner chain, so a code carried by a fault that was
        wrapped on its way out - by this function or by the engine - is still
        found, and an operator reading the fault still has the original beneath
        it rather than a message copied away from its cause.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        $InnerError = $null
    )
    $inner = $null
    if ($InnerError -is [Management.Automation.ErrorRecord]) { $inner = $InnerError.Exception }
    elseif ($InnerError -is [Exception]) { $inner = $InnerError }
    if ($null -eq $inner) { $exception = [InvalidOperationException]::new($Message) }
    else { $exception = [InvalidOperationException]::new($Message, $inner) }
    $exception.Data[$script:ReviewerQualificationFaultCodeKey] = $Code
    return [Management.Automation.ErrorRecord]::new(
        $exception, $Code, [Management.Automation.ErrorCategory]::InvalidData, $null)
}

function Get-ReviewerQualificationFaultCode {
    <#
        Reads the code off a caught error, following the inner-exception chain
        because a fault raised inside a called tool arrives wrapped. Returns the
        empty string when the error carries no code, which is the conservative
        answer: an unclassified fault is never treated as corruption.
    #>
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return "" }
    $exception = $null
    if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $exception = $ErrorRecord.Exception }
    elseif ($ErrorRecord -is [Exception]) { $exception = $ErrorRecord }
    $depth = 0
    while ($null -ne $exception -and $depth -lt 16) {
        if ($null -ne $exception.Data -and $exception.Data.Contains($script:ReviewerQualificationFaultCodeKey)) {
            return [string]$exception.Data[$script:ReviewerQualificationFaultCodeKey]
        }
        $exception = $exception.InnerException
        $depth++
    }
    return ""
}

function Test-ReviewerQualificationCorruptFaultCode {
    <#
        The single answer to "does this fault mean the published set is
        corrupt". Kept here, beside the throws that raise the codes, so adding a
        fault and classifying it are one edit rather than two files apart.
    #>
    param([AllowEmptyString()][string]$Code)
    if ([string]::IsNullOrEmpty($Code)) { return $false }
    return [bool]($script:ReviewerQualificationCorruptFaultCodes -ccontains $Code)
}

function Get-ReviewerQualificationFullPath {
    <#
        Normalizes an operator path to a rooted, separator-stable full path
        WITHOUT requiring it to exist. Existence is a separate question with a
        separate error message; a half-normalized path is how a value ends up
        being compared one way and passed another.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Purpose
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Qualification $Purpose path is empty; it must be supplied explicitly."
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -match '[\r\n\t]') {
        throw "Qualification $Purpose path contains control characters."
    }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        throw ("Qualification $Purpose path '$Path' is relative. Every path a qualification slot carries is " +
            "resolved once, here, so the same string means the same directory in this process and in the child.")
    }
    $full = [IO.Path]::GetFullPath($expanded)
    if ($full.Length -gt 3) { $full = $full.TrimEnd([IO.Path]::DirectorySeparatorChar) }
    return $full
}

function Test-ReviewerQualificationPathWithin {
    <# Ordinal-case-insensitive containment on normalized full paths. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Container
    )
    $needle = $Path.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $root = $Container.TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($needle -eq $root) { return $true }
    return $needle.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-ReviewerQualificationPrelaunch {
    <#
        Runs one slot's EXACT argument vector through the real agent, with
        -QualificationPrelaunch appended, and returns what the agent resolved
        at its own model-launch boundary.

        This is the agent's startup path, not a stand-in for it: the same
        parameter binding, the same config load, the same model validation, the
        same replay snapshot load and binding checks, the same -RepoPath
        resolution, the same delivery-authorization mint. The agent stops
        immediately before it creates its state directory, which is the first
        thing it writes and is strictly earlier than any session, any host call
        and any model launch.

        Launched as 'pwsh -File <agent> <argv>' - the same way the slot itself
        is launched - because only that puts the same argv through the same
        command-line parsing. Splatting an array into a scriptblock binds
        positionally and would have accepted the very commands this exists to
        refuse.
    #>
    param(
        [Parameter(Mandatory)][string]$ReviewerScriptPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments
    )
    $resolved = (Resolve-Path -LiteralPath $ReviewerScriptPath).ProviderPath
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-ReviewerQualificationPwshPath
    foreach ($argument in @("-NoLogo", "-NoProfile", "-NonInteractive", "-File", $resolved)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    foreach ($argument in [string[]]@($Arguments)) { [void]$startInfo.ArgumentList.Add($argument) }
    # The ONLY difference between the preflighted command and the real one. It
    # subtracts: the agent validates everything and exits before it acts.
    [void]$startInfo.ArgumentList.Add($script:ReviewerQualificationPrelaunchSwitch)
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false

    $process = [Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    $marked = @(@($stdout -split "`n") | Where-Object { $_.StartsWith($script:ReviewerQualificationPrelaunchMarker) })
    if ($process.ExitCode -ne 0 -or $marked.Count -ne 1) {
        $diagnostic = ((($stderr + "`n" + $stdout) -split "`r?`n" | Where-Object { $_.Trim() }) -join " ").Trim()
        if (-not $diagnostic) { $diagnostic = "no diagnostic output." }
        throw ("Qualification prelaunch did not reach the agent's model-launch boundary: $diagnostic")
    }
    $payload = $marked[0].Substring($script:ReviewerQualificationPrelaunchMarker.Length).Trim()
    return ($payload | ConvertFrom-Json)
}
function Get-ReviewerQualificationPwshPath {
    <# The interpreter running this preflight is the one the slot will run
       under; resolving it any other way could preflight a different host. #>
    $path = (Get-Process -Id $PID).Path
    if ($path) { return $path }
    return "pwsh"
}

function New-ReviewerQualificationSlotArgument {
    <#
        THE one place a slot's argument vector is constructed. Preflight and
        the real invocation both consume what this returns; nothing rebuilds a
        "similar" command later.

        -RepoPath is bound FIRST and unconditionally. The agent can infer it
        from a config that sits inside the reviewed repository, but a
        qualification config normally does not - and the inference failure
        lands after the run set is already sealed.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$ConfigFile,
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$OperatorAlias,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$SecondPassModel,
        [Parameter(Mandatory)][string]$ConventionSpecialistModel,
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$ReplaySnapshotName,
        [Parameter(Mandatory)][string]$ReplayManifestDigest,
        [string]$ConventionVerifierModel = "",
        [switch]$EnableVerificationPreview,
        [int]$CycleTimeoutSeconds = 1800,
        [int]$ConventionSpecialistTimeoutSeconds = 900,
        [int]$VerificationTimeoutSeconds = 900
    )
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]@("-RepoPath", $RepoPath))
    $arguments.AddRange([string[]]@("-ConfigFile", $ConfigFile))
    $arguments.AddRange([string[]]@("-StateDir", $StateDir))
    $arguments.AddRange([string[]]@("-OperatorAlias", $OperatorAlias))
    $arguments.Add("-Once")
    $arguments.AddRange([string[]]@("-PullRequestId", [string]$PullRequestId))
    $arguments.AddRange([string[]]@("-Model", $Model))
    $arguments.AddRange([string[]]@("-SecondPassModel", $SecondPassModel))
    $arguments.Add("-EnableConventionSpecialist")
    $arguments.AddRange([string[]]@("-ConventionSpecialistModel", $ConventionSpecialistModel))
    if ($EnableVerificationPreview) {
        $arguments.Add("-EnableVerificationPreview")
        if ($ConventionVerifierModel) {
            $arguments.AddRange([string[]]@("-ConventionVerifierModel", $ConventionVerifierModel))
        }
    }
    $arguments.AddRange([string[]]@("-ReplayRoot", $ReplayRoot))
    $arguments.AddRange([string[]]@("-ReplaySnapshotName", $ReplaySnapshotName))
    $arguments.AddRange([string[]]@("-ReplayManifestDigest", $ReplayManifestDigest))
    $arguments.AddRange([string[]]@("-CycleTimeoutSeconds", [string]$CycleTimeoutSeconds))
    $arguments.AddRange([string[]]@("-ConventionSpecialistTimeoutSeconds", [string]$ConventionSpecialistTimeoutSeconds))
    $arguments.AddRange([string[]]@("-VerificationTimeoutSeconds", [string]$VerificationTimeoutSeconds))
    return [string[]]$arguments.ToArray()
}

function ConvertTo-ReviewerQualificationCommandText {
    <# Display only. Quoting is for a human reading the preflight report; the
       child process is started from the argument ARRAY, never from this. #>
    param(
        [Parameter(Mandatory)][string]$ReviewerScriptPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments
    )
    $quote = {
        param([string]$Value)
        if ($Value -match '[\s"'']') { return '"' + $Value.Replace('"', '\"') + '"' }
        return $Value
    }
    return (@(@("pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", $ReviewerScriptPath) + @($Arguments) |
            ForEach-Object { & $quote $_ }) -join " ")
}

function New-ReviewerReplayQualificationPlan {
    <#
        Validates every input a qualification slot depends on and returns the
        complete, preflighted plan. Throws on the first thing that would have
        failed at slot startup, so a caller reaching the end of this function
        holds a set of commands that are known to bind.

        Validated here, in this order:
          reviewer build identity (clean worktree, exact commit, required ref)
          -> reviewer script and prompt closure
          -> config (through the agent's OWN loader)
          -> models (supported, derived generalist pair, distinct roles)
          -> replay snapshot (loads, digest matches, binds to this config and
             this pull request, promotability recorded)
          -> paths (reviewed repo, qualification root, per-slot state)
          -> argument construction and binding to the model-launch boundary.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$ConfigFile,
        [Parameter(Mandatory)][string]$OperatorAlias,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$ReplaySnapshotName,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}\z')][string]$ReplayManifestDigest,
        [Parameter(Mandatory)][string]$QualificationRoot,
        [Parameter(Mandatory)][string]$ReviewerScriptPath,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}\z')][string]$ExpectedCommit,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}\z')][string]$RequiredRef,
        [string]$ToolkitRepositoryPath = "",
        [ValidateRange(2, 16)][int]$SlotCount = 2,
        [ValidateRange(30, 7200)][int]$CycleTimeoutSeconds = 1800,
        [ValidateRange(30, 3600)][int]$ConventionSpecialistTimeoutSeconds = 900,
        [ValidateRange(30, 3600)][int]$VerificationTimeoutSeconds = 900,
        [ValidateRange(1, 14400)][int]$SlotTimeoutSeconds = 3600,
        [ValidateRange(0, 14400)][int]$ProgressTimeoutSeconds = 0,
        [string]$ConventionSpecialistModel = "",
        [string]$ConventionVerifierModel = "",
        # SHA-256 (lowercase hex) of the run set's single-use launch-authorization
        # token. Empty during a pure -Mode Preflight look; a declaration mints the
        # token and seals its hash here so the plan digest - and therefore the
        # sealed declaration - can only be reproduced by a slot that presents the
        # matching token. A stale, wrong or absent token yields a different digest
        # and is refused before any model launch.
        [ValidatePattern('^([0-9a-f]{64})?\z')][string]$LaunchAuthorizationHash = ""
    )

    if ($OperatorAlias -notmatch '^[A-Za-z0-9._-]+\z') {
        throw "Qualification -OperatorAlias '$OperatorAlias' is not a safe alias."
    }

    # -- reviewer build -------------------------------------------------------
    $scriptPath = Get-ReviewerQualificationFullPath -Path $ReviewerScriptPath -Purpose "reviewer script"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Qualification reviewer script '$scriptPath' does not exist."
    }
    $reviewerDir = Split-Path -Parent $scriptPath
    $toolkitRoot = if ($ToolkitRepositoryPath) {
        Get-ReviewerQualificationFullPath -Path $ToolkitRepositoryPath -Purpose "toolkit repository"
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $reviewerDir "..\..\..")).TrimEnd([IO.Path]::DirectorySeparatorChar)
    }
    if (-not (Test-ReviewerQualificationPathWithin -Path $scriptPath -Container $toolkitRoot)) {
        throw ("Qualification reviewer script '$scriptPath' does not live inside the toolkit repository " +
            "'$toolkitRoot' whose identity is being pinned.")
    }
    # The identity of the build under qualification. Offline replay accepts an
    # app-created worktree's generated branch name; the commit, the required
    # ref and a clean tree are what actually bind.
    $gitIdentity = Test-ReviewerQualificationGitIdentity -RepositoryPath $toolkitRoot `
        -ExpectedCommit $ExpectedCommit -RequiredRef $RequiredRef -Mode OfflineReplay

    # -- config, through the agent's own loader -------------------------------
    $configPath = Get-ReviewerQualificationFullPath -Path $ConfigFile -Purpose "config file"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Qualification config '$configPath' does not exist or is not a regular file."
    }
    # Get-AgentConfig is what the agent itself calls, with the same agent
    # directory, so a config this accepts is a config that will load - prompt
    # file included, which is otherwise a startup failure after declaration.
    $configLoad = Get-AgentConfig -Path $configPath -AgentDir $reviewerDir -SupportedSchemaVersions @(1) `
        -PromptFileField "promptFile"
    $cfg = $configLoad.Raw
    $repository = Get-AgentConfigObject -Object $cfg -Name "repository" -Where "config"
    $cfgOrganization = Get-AgentConfigString -Object $repository -Name "organization" -Where "config.repository" `
        -MaxLength 64 -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    $cfgProject = Get-AgentConfigString -Object $repository -Name "project" -Where "config.repository" -MaxLength 128
    $cfgRepositoryId = Get-AgentConfigString -Object $repository -Name "id" -Where "config.repository" -MaxLength 36 `
        -Pattern '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $reviewCfg = Get-AgentConfigObject -Object $cfg -Name "review" -Where "config"
    # Both blocks are optional in the agent's own loader; a qualification that
    # demanded them would refuse configs the agent accepts.
    $cfgSpecialistModel = ""
    if ($reviewCfg.PSObject.Properties["conventionSpecialistModel"]) {
        $cfgSpecialistModel = Get-AgentConfigString -Object $reviewCfg -Name "conventionSpecialistModel" `
            -Where "config.review" -MaxLength 64 -AllowEmpty
    }
    $cfgVerificationEnabled = $false
    $cfgVerifierModel = ""
    if ($reviewCfg.PSObject.Properties["verification"]) {
        $verificationCfg = Get-AgentConfigObject -Object $reviewCfg -Name "verification" -Where "config.review"
        $cfgVerificationEnabled = Get-AgentConfigBool -Object $verificationCfg -Name "enabled" `
            -Where "config.review.verification"
        $cfgVerifierModel = Get-AgentConfigString -Object $verificationCfg -Name "conventionVerifierModel" `
            -Where "config.review.verification" -MaxLength 64 -AllowEmpty
    }

    # -- models ---------------------------------------------------------------
    # Derived, never named here: the wrapper that named its own Opus version is
    # exactly the defect this closes.
    $pair = Get-AgentGeneralistModelPair
    $selectedSpecialist = if ($ConventionSpecialistModel) { $ConventionSpecialistModel } else { [string]$cfgSpecialistModel }
    if (-not $selectedSpecialist) {
        throw ("Qualification requires a convention-specialist model: pass -ConventionSpecialistModel or set " +
            "config.review.conventionSpecialistModel. The CLI default is never used for this pass.")
    }
    $selectedSpecialist = Assert-AgentSupportedModel -ModelId $selectedSpecialist -Where "convention specialist model"
    if (@($pair.Models) -ccontains $selectedSpecialist) {
        throw ("The convention-specialist discovery model '$selectedSpecialist' must differ from both generalist " +
            "cross-check models ($($pair.Models -join ', ')).")
    }
    $verificationRequested = [bool]$cfgVerificationEnabled
    $selectedVerifier = if ($ConventionVerifierModel) { $ConventionVerifierModel } else { [string]$cfgVerifierModel }
    if ($verificationRequested) {
        if (-not $selectedVerifier) {
            throw ("Verification preview requires an explicit -ConventionVerifierModel or " +
                "config.review.verification.conventionVerifierModel.")
        }
        $selectedVerifier = Assert-AgentSupportedModel -ModelId $selectedVerifier -Where "convention verifier model"
    }
    elseif ($ConventionVerifierModel) {
        throw ("-ConventionVerifierModel was supplied but config.review.verification.enabled is false; the agent " +
            "would refuse the pairing at startup.")
    }
    else { $selectedVerifier = "" }

    # -- replay snapshot ------------------------------------------------------
    $replayRootPath = Get-ReviewerQualificationFullPath -Path $ReplayRoot -Purpose "replay root"
    if (-not (Test-Path -LiteralPath $replayRootPath -PathType Container)) {
        throw "Qualification replay root '$replayRootPath' does not exist."
    }
    # Loads every payload, re-hashes it, and refuses a manifest whose digest is
    # not the one the operator vouched for - the same load the slot will do.
    $snapshot = New-AgentReplaySnapshot -ReplayRoot $replayRootPath -SnapshotName $ReplaySnapshotName `
        -ExpectedManifestDigest $ReplayManifestDigest
    $binding = $snapshot.Binding
    if ([string]$binding.Organization -cne $cfgOrganization -or
        [string]$binding.Project -cne $cfgProject -or
        [string]$binding.RepositoryId -cne $cfgRepositoryId) {
        throw ("Replay snapshot '$ReplaySnapshotName' was captured for " +
            "$($binding.Organization)/$($binding.Project)/$($binding.RepositoryId) and cannot be replayed under " +
            "this configuration ($cfgOrganization/$cfgProject/$cfgRepositoryId).")
    }
    if ([int]$binding.PullRequestId -ne $PullRequestId) {
        throw ("Replay snapshot '$ReplaySnapshotName' records pull request $($binding.PullRequestId), not " +
            "$PullRequestId. A replay never selects its own candidate.")
    }
    $classification = $snapshot.Classification
    $nonPromotable = [bool]$classification.NonPromotable
    $configSha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $scriptSha256 = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # -- paths ----------------------------------------------------------------
    $repoPathFull = Get-ReviewerQualificationFullPath -Path $RepoPath -Purpose "reviewed repository"
    if (-not (Test-Path -LiteralPath $repoPathFull -PathType Container)) {
        throw ("Qualification -RepoPath '$repoPathFull' does not exist. The agent resolves the reviewed " +
            "repository from the config's own location when this is omitted, which fails for a qualification " +
            "config that lives outside a repository - after the run set has been declared.")
    }
    $qualificationRootFull = Get-ReviewerQualificationFullPath -Path $QualificationRoot -Purpose "qualification root"
    $effectiveProgressTimeoutSeconds = if ($ProgressTimeoutSeconds -gt 0) {
        $ProgressTimeoutSeconds
    }
    else {
        [Math]::Min($SlotTimeoutSeconds,
            ([Math]::Max($CycleTimeoutSeconds,
                    [Math]::Max($ConventionSpecialistTimeoutSeconds, $VerificationTimeoutSeconds)) + 120))
    }
    if ($effectiveProgressTimeoutSeconds -gt $SlotTimeoutSeconds) {
        throw ("Qualification progress timeout ($effectiveProgressTimeoutSeconds seconds) exceeds the slot hard " +
            "deadline ($SlotTimeoutSeconds seconds).")
    }
    foreach ($forbidden in @(
            @{ Path = $toolkitRoot; Name = "the toolkit repository under qualification" },
            @{ Path = $repoPathFull; Name = "the reviewed repository" },
            @{ Path = $replayRootPath; Name = "the replay root" })) {
        if (Test-ReviewerQualificationPathWithin -Path $qualificationRootFull -Container $forbidden.Path) {
            throw ("Qualification output root '$qualificationRootFull' resolves inside $($forbidden.Name) " +
                "('$($forbidden.Path)'). Qualification state must live outside it: writing there dirties the " +
                "worktree whose cleanliness this run's identity depends on.")
        }
    }

    # -- slots ----------------------------------------------------------------
    $slots = @(for ($index = 1; $index -le $SlotCount; $index++) {
            $slotName = "slot$index"
            $slotStateDir = Join-Path (Join-Path $qualificationRootFull "runs") "$slotName-state"
            $arguments = New-ReviewerQualificationSlotArgument -RepoPath $repoPathFull -ConfigFile $configPath `
                -StateDir $slotStateDir -OperatorAlias $OperatorAlias -PullRequestId $PullRequestId `
                -Model $pair.First -SecondPassModel $pair.Second `
                -ConventionSpecialistModel $selectedSpecialist `
                -ConventionVerifierModel $selectedVerifier `
                -EnableVerificationPreview:$verificationRequested `
                -ReplayRoot $replayRootPath -ReplaySnapshotName $ReplaySnapshotName `
                -ReplayManifestDigest $ReplayManifestDigest.ToLowerInvariant() `
                -CycleTimeoutSeconds $CycleTimeoutSeconds `
                -ConventionSpecialistTimeoutSeconds $ConventionSpecialistTimeoutSeconds `
                -VerificationTimeoutSeconds $VerificationTimeoutSeconds
            [pscustomobject][ordered]@{
                Name        = $slotName
                StateDir    = $slotStateDir
                ConsolePath = Join-Path (Join-Path $qualificationRootFull "runs") "$slotName-console.txt"
                ErrorPath   = Join-Path (Join-Path $qualificationRootFull "runs") "$slotName-stderr.txt"
                ExitPath    = Join-Path (Join-Path $qualificationRootFull "runs") "$slotName-exit.txt"
                TerminalPath = Join-Path (Join-Path $qualificationRootFull "runs") "$slotName-terminal.json"
                Arguments   = [string[]]$arguments
                CommandText = ConvertTo-ReviewerQualificationCommandText -ReviewerScriptPath $scriptPath `
                    -Arguments $arguments
            }
        })

    return [pscustomobject][ordered]@{
        ReviewerScriptPath  = $scriptPath
        ReviewerScriptSha256 = $scriptSha256
        ToolkitRepositoryPath = $toolkitRoot
        GitIdentity         = $gitIdentity
        RepoPath            = $repoPathFull
        ConfigFile          = $configPath
        ConfigSha256        = $configSha256
        PromptFilePath      = $configLoad.PromptFilePath
        Organization        = $cfgOrganization
        Project             = $cfgProject
        RepositoryId        = $cfgRepositoryId
        OperatorAlias       = $OperatorAlias
        PullRequestId       = $PullRequestId
        Models              = [pscustomobject][ordered]@{
            First             = $pair.First
            Second            = $pair.Second
            SortedKey         = $pair.SortedKey
            ConventionSpecialist = $selectedSpecialist
            ConventionVerifier = $selectedVerifier
        }
        VerificationPreview = $verificationRequested
        Snapshot            = [pscustomobject][ordered]@{
            Name           = $snapshot.SnapshotId
            ReplayRoot     = $replayRootPath
            ManifestDigest = $snapshot.ManifestDigest
            SchemaVersion  = $snapshot.SchemaVersion
            ResourceCount  = $snapshot.ResourceCount
            PullRequestId  = [int]$binding.PullRequestId
            SourceCommit   = [string]$binding.SourceCommit
            SealKind       = [string]$classification.SealKind
            NonPromotable  = $nonPromotable
        }
        QualificationRoot   = $qualificationRootFull
        RunSetDirectory     = Join-Path $qualificationRootFull "runset"
        RunDirectory        = Join-Path $qualificationRootFull "runs"
        # Replay is permanently preview-only, and a classified snapshot has
        # additionally withdrawn its own promotability. Both are recorded so a
        # reader of this plan cannot mistake the result for a deliverable one.
        DeliveryMode        = "previewOnly"
        Promotable          = $false
        SlotCount           = $SlotCount
        SlotTimeoutSeconds  = $SlotTimeoutSeconds
        ProgressTimeoutSeconds = $effectiveProgressTimeoutSeconds
        LaunchAuthorizationHash = $LaunchAuthorizationHash.ToLowerInvariant()
        Slots               = @($slots)
    }
}

function Assert-ReviewerReplayQualificationPlan {
    <#
        The gate a caller must pass before it is allowed to declare a run set.
        Re-checks the constructed argv itself - it is the artifact everything
        downstream depends on - and then runs every slot's exact argv through
        the REAL agent up to its own model-launch boundary.

        What comes back is what the agent resolved, so the checks below compare
        the plan against the agent's answer rather than against a copy of the
        agent's parameter block. A model the registry no longer supports, a
        -RepoPath the agent cannot resolve, a snapshot that does not bind to
        this config or this pull request, or a snapshot that cannot answer the
        read the run opens with: each of them fails here, and each of them is a
        failure that previously surfaced only after the run set had been sealed.

        Returns per-slot evidence.

        When -TargetSlot is supplied the no-resume (state-already-exists) check
        is enforced only for that slot. A sequential set runs slot1, then slot2;
        by the time slot2 preflights, slot1 legitimately has state, and only the
        slot being launched must be pristine. With no -TargetSlot (the Declare
        preflight) every slot must be stateless, which is what a fresh set is.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$TargetSlot = "")

    if (@($Plan.Slots).Count -lt 2) {
        throw "A qualification of fewer than two slots is not a reconciliation."
    }
    # Loaded once, here, so the probe the agent reports can be looked up in the
    # snapshot THIS process planned against rather than taken on the child's
    # word. A snapshot keyed on a repository identity the config does not name -
    # the exact shape of the defect that killed a declared set before any model
    # ran - has no such recorded read, and fails here.
    $snapshot = New-AgentReplaySnapshot -ReplayRoot ([string]$Plan.Snapshot.ReplayRoot) `
        -SnapshotName ([string]$Plan.Snapshot.Name) -ExpectedManifestDigest ([string]$Plan.Snapshot.ManifestDigest)
    $servedKeys = @($snapshot.ServedKeys)
    $evidence = @(foreach ($plannedSlot in @($Plan.Slots)) {
            $arguments = [string[]]@($plannedSlot.Arguments)
            $refused = @($arguments | Where-Object { @($script:ReviewerQualificationRefusedSwitches) -ccontains $_ })
            if ($refused.Count -gt 0) {
                throw ("Constructed qualification command for $($plannedSlot.Name) carries switch(es) an offline replay " +
                    "refuses: $($refused -join ', ').")
            }
            if (@($arguments) -ccontains $script:ReviewerQualificationPrelaunchSwitch) {
                throw ("Constructed qualification command for $($plannedSlot.Name) carries " +
                    "$($script:ReviewerQualificationPrelaunchSwitch). The preflight adds it; a slot that carried " +
                    "it would validate itself and exit instead of running.")
            }
            $resolved = Invoke-ReviewerQualificationPrelaunch -ReviewerScriptPath $Plan.ReviewerScriptPath `
                -Arguments $arguments
            foreach ($required in @("seam", "repoPath", "plannedStateDir", "stateDirExists", "configFile",
                    "configSha256", "model", "secondPassModel", "isTwoPass", "conventionSpecialist",
                    "conventionSpecialistModel", "pullRequestId", "replayActive", "replaySnapshotId",
                    "replayManifestDigest", "deliveryAuthorization", "agentScriptSha256",
                    "sourceProbeTool", "sourceProbeAction", "sourceProbeArguments",
                    "sourceProbeRequestSha256", "sourceProbePullRequestId")) {
                if (-not $resolved.PSObject.Properties[$required]) {
                    throw "The agent's prelaunch report for $($plannedSlot.Name) is missing '$required'."
                }
            }
            if ([string]$resolved.seam -cne "reviewer.qualification-prelaunch.v1") {
                throw "$($plannedSlot.Name) reached an unexpected prelaunch seam '$($resolved.seam)'."
            }
            # The build that answered has to be the build that was pinned, or the
            # preflight describes a different agent than the one under qualification.
            if ([string]$resolved.agentScriptSha256 -cne [string]$Plan.ReviewerScriptSha256) {
                throw ("$($plannedSlot.Name) was validated by an agent whose script hashes to " +
                    "$($resolved.agentScriptSha256), not the pinned $($Plan.ReviewerScriptSha256).")
            }
            if ([string]$resolved.repoPath -cne [string]$Plan.RepoPath) {
                throw ("$($plannedSlot.Name) resolved -RepoPath as '$($resolved.repoPath)' rather than the " +
                    "normalized '$($Plan.RepoPath)'.")
            }
            # The agent puts replay state under the slot's directory rather than
            # in it, so containment is the check: this slot's state must be the
            # slot's own, and no other slot's.
            if (-not (Test-ReviewerQualificationPathWithin -Path ([string]$resolved.plannedStateDir) `
                        -Container ([string]$plannedSlot.StateDir))) {
                throw ("$($plannedSlot.Name) would run in '$($resolved.plannedStateDir)' rather than under the " +
                    "planned '$($plannedSlot.StateDir)'.")
            }
            if ([bool]$resolved.stateDirExists -and
                ($TargetSlot -eq "" -or [string]$plannedSlot.Name -ceq $TargetSlot)) {
                throw ("$($plannedSlot.Name) already has state at '$($resolved.plannedStateDir)'. A slot is " +
                    "attempted once; qualify into a fresh root.")
            }
            if ([string]$resolved.configFile -cne [string]$Plan.ConfigFile -or
                [string]$resolved.configSha256 -cne [string]$Plan.ConfigSha256) {
                throw "$($plannedSlot.Name) loaded a different config than the one this plan hashed."
            }
            if ([string]$resolved.model -cne [string]$Plan.Models.First -or
                [string]$resolved.secondPassModel -cne [string]$Plan.Models.Second) {
                throw ("$($plannedSlot.Name) resolved the generalist pairing as " +
                    "'$($resolved.model)'/'$($resolved.secondPassModel)' rather than the supported " +
                    "'$($Plan.Models.First)'/'$($Plan.Models.Second)'.")
            }
            if (-not [bool]$resolved.isTwoPass) {
                throw "$($plannedSlot.Name) resolved to a single generalist pass; a qualification cross-checks two."
            }
            if (-not [bool]$resolved.conventionSpecialist -or
                [string]$resolved.conventionSpecialistModel -cne [string]$Plan.Models.ConventionSpecialist) {
                throw ("$($plannedSlot.Name) resolved the convention specialist as " +
                    "'$($resolved.conventionSpecialistModel)' (enabled=$($resolved.conventionSpecialist)) rather " +
                    "than '$($Plan.Models.ConventionSpecialist)'.")
            }
            if ([int]$resolved.pullRequestId -ne [int]$Plan.PullRequestId) {
                throw "$($plannedSlot.Name) resolved -PullRequestId $($resolved.pullRequestId), not $($Plan.PullRequestId)."
            }
            if (-not [bool]$resolved.replayActive) {
                throw "$($plannedSlot.Name) did not resolve to an offline replay; a qualification never runs live."
            }
            if ([string]$resolved.replaySnapshotId -cne [string]$Plan.Snapshot.Name -or
                [string]$resolved.replayManifestDigest -cne [string]$Plan.Snapshot.ManifestDigest) {
                throw ("$($plannedSlot.Name) loaded snapshot '$($resolved.replaySnapshotId)' at digest " +
                    "$($resolved.replayManifestDigest), not the planned '$($Plan.Snapshot.Name)' at " +
                    "$($Plan.Snapshot.ManifestDigest).")
            }
            if ([string]$resolved.deliveryAuthorization -cne "PreviewOnly") {
                throw ("$($plannedSlot.Name) resolved delivery authorization " +
                    "'$($resolved.deliveryAuthorization)'; an offline replay is preview-only by construction.")
            }
            # -- the run's FIRST source read, proven against this snapshot ------
            # A slot that binds perfectly still dies before any model if the
            # snapshot cannot answer the read the cycle opens with. The agent
            # issues that exact read at its prelaunch boundary and reports it;
            # this recomputes the request key from the reported arguments and
            # looks it up in the snapshot, so neither side is trusted alone.
            if ([string]$resolved.sourceProbeTool -cne "repo_pull_request" -or
                [string]$resolved.sourceProbeAction -cne "get") {
                throw ("$($plannedSlot.Name) probed its source with " +
                    "'$($resolved.sourceProbeTool)/$($resolved.sourceProbeAction)'. A qualification names its pull " +
                    "request, so the run's first read must be the bounded direct get - never a repository-wide list.")
            }
            $probeArguments = $resolved.sourceProbeArguments
            $probeKeys = @(@($probeArguments.PSObject.Properties.Name) | Sort-Object)
            if (($probeKeys -join ",") -cne "action,project,pullRequestId,repositoryId") {
                throw ("$($plannedSlot.Name) probed its source with argument(s) " +
                    "'$($probeKeys -join ", ")' rather than the bounded direct-get argument set.")
            }
            if ([string]$probeArguments.project -cne [string]$Plan.Project -or
                [int]$probeArguments.pullRequestId -ne [int]$Plan.PullRequestId) {
                throw ("$($plannedSlot.Name) probed for " +
                    "$($probeArguments.project)/PR $($probeArguments.pullRequestId) rather than the planned " +
                    "$($Plan.Project)/PR $($Plan.PullRequestId).")
            }
            $recomputedKey = Get-AgentReplayRequestKey -Name ([string]$resolved.sourceProbeTool) -Arguments ([ordered]@{
                    action        = [string]$probeArguments.action
                    project       = [string]$probeArguments.project
                    repositoryId  = [string]$probeArguments.repositoryId
                    pullRequestId = [int]$probeArguments.pullRequestId
                })
            if ([string]$recomputedKey.Key -cne [string]$resolved.sourceProbeRequestSha256) {
                throw ("$($plannedSlot.Name) reported a source-probe request key that does not hash its own " +
                    "reported arguments.")
            }
            if (@($servedKeys) -cnotcontains [string]$resolved.sourceProbeRequestSha256) {
                throw ("Snapshot '$($Plan.Snapshot.Name)' records no response for the read " +
                    "$($plannedSlot.Name) opens with (repositoryId '$($probeArguments.repositoryId)', " +
                    "pull request $($probeArguments.pullRequestId)). A snapshot sealed around a different " +
                    "repository identity than this config names cannot answer it, and the run would fail before " +
                    "a model launched.")
            }
            if ([int]$resolved.sourceProbePullRequestId -ne [int]$Plan.PullRequestId) {
                throw ("$($plannedSlot.Name) resolved pull request $($resolved.sourceProbePullRequestId) from the " +
                    "snapshot's recorded read, not the planned $($Plan.PullRequestId).")
            }
            [pscustomobject][ordered]@{
                Slot                 = $plannedSlot.Name
                Seam                 = [string]$resolved.seam
                AgentScriptSha256    = [string]$resolved.agentScriptSha256
                RepoPath             = [string]$resolved.repoPath
                StateDir             = [string]$resolved.plannedStateDir
                StateDirExists       = [bool]$resolved.stateDirExists
                Model                = [string]$resolved.model
                SecondPassModel      = [string]$resolved.secondPassModel
                ConventionSpecialistModel = [string]$resolved.conventionSpecialistModel
                PullRequestId        = [int]$resolved.pullRequestId
                SnapshotId           = [string]$resolved.replaySnapshotId
                SnapshotManifestDigest = [string]$resolved.replayManifestDigest
                NonPromotable        = [bool]$resolved.replayNonPromotable
                DeliveryAuthorization = [string]$resolved.deliveryAuthorization
                SourceProbeTool      = [string]$resolved.sourceProbeTool
                SourceProbeAction    = [string]$resolved.sourceProbeAction
                SourceProbeRepositoryId = [string]$probeArguments.repositoryId
                SourceProbeRequestSha256 = [string]$resolved.sourceProbeRequestSha256
                SourceProbePullRequestId = [int]$resolved.sourceProbePullRequestId
            }
        })
    $stateDirs = @(@($evidence) | ForEach-Object { $_.StateDir.ToLowerInvariant() })
    if (@($stateDirs | Sort-Object -Unique).Count -ne @($stateDirs).Count) {
        throw "Two qualification slots share a state directory; repeats are only independent in separate state."
    }
    return @($evidence)
}

function Get-ReviewerQualificationPlanDigest {
    <#
        A canonical digest of the WHOLE plan: every slot's exact argument
        vector, the normalized reviewed-repository path, the config and agent
        script hashes, the toolkit build identity, the models, the timeouts (in
        the argv) and the snapshot.

        The declaration is sealed under this, so a slot cannot later be run
        against a declaration that was sealed for a different plan - a
        different model pairing, a different repository, a different agent
        build, a different snapshot - which is precisely the substitution a
        snapshot-and-count-only declaration could not see.

        Canonical by construction rather than by post-processing: the shape is
        fixed and ordered here, carries no floating point and no timestamps,
        and every value is a string, an int or a bool. Two hosts building the
        same plan therefore serialize the same bytes.
    #>
    param([Parameter(Mandatory)]$Plan)
    $document = [ordered]@{
        kind = $script:ReviewerQualificationPlanDigestKind
        agentScriptPath = [string]$Plan.ReviewerScriptPath
        agentScriptSha256 = [string]$Plan.ReviewerScriptSha256
        toolkitRepositoryPath = [string]$Plan.ToolkitRepositoryPath
        toolkitHead = [string]$Plan.GitIdentity.head
        toolkitRequiredRef = [string]$Plan.GitIdentity.requiredRef
        toolkitBranchState = [string]$Plan.GitIdentity.branchState
        toolkitClean = [bool]$Plan.GitIdentity.clean
        repoPath = [string]$Plan.RepoPath
        configFile = [string]$Plan.ConfigFile
        configSha256 = [string]$Plan.ConfigSha256
        promptFile = [string]$Plan.PromptFilePath
        organization = [string]$Plan.Organization
        project = [string]$Plan.Project
        repositoryId = [string]$Plan.RepositoryId
        operatorAlias = [string]$Plan.OperatorAlias
        pullRequestId = [int]$Plan.PullRequestId
        modelFirst = [string]$Plan.Models.First
        modelSecond = [string]$Plan.Models.Second
        modelConventionSpecialist = [string]$Plan.Models.ConventionSpecialist
        modelConventionVerifier = [string]$Plan.Models.ConventionVerifier
        verificationPreview = [bool]$Plan.VerificationPreview
        snapshotName = [string]$Plan.Snapshot.Name
        snapshotReplayRoot = [string]$Plan.Snapshot.ReplayRoot
        snapshotManifestDigest = [string]$Plan.Snapshot.ManifestDigest
        snapshotPullRequestId = [int]$Plan.Snapshot.PullRequestId
        snapshotSealKind = [string]$Plan.Snapshot.SealKind
        snapshotNonPromotable = [bool]$Plan.Snapshot.NonPromotable
        qualificationRoot = [string]$Plan.QualificationRoot
        deliveryMode = [string]$Plan.DeliveryMode
        promotable = [bool]$Plan.Promotable
        slotCount = [int]$Plan.SlotCount
        slotTimeoutSeconds = [int]$Plan.SlotTimeoutSeconds
        progressTimeoutSeconds = [int]$Plan.ProgressTimeoutSeconds
        launchAuthorizationHash = [string]$Plan.LaunchAuthorizationHash
        slots = @(@($Plan.Slots) | ForEach-Object {
                [ordered]@{
                    name = [string]$_.Name
                    stateDir = [string]$_.StateDir
                    arguments = [string[]]@($_.Arguments)
                }
            })
    }
    $json = ConvertTo-Json -InputObject $document -Depth 8 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-ReviewerQualificationLaunchTokenHash {
    <#
        The launch-authorization token is a run-set-scoped secret minted at
        declaration. Its SHA-256 is what the plan digest seals; a slot that
        cannot present the token cannot reproduce the digest and is refused
        before it consumes its attempt or starts a child.
    #>
    param([Parameter(Mandatory)][string]$Token)
    $trimmed = $Token.Trim()
    if ($trimmed -notmatch '^[0-9a-f]{64}\z') {
        throw (New-ReviewerQualificationFault -Code "launchTokenMalformed" `
                -Message "Launch-authorization token is malformed; expected 64 lowercase hex characters.")
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($trimmed)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Resolve-ReviewerQualificationSlotTerminalPath {
    <#
        Resolves one slot's immutable terminal-evidence file by an ORDINAL,
        case-exact match on the physical directory entry name. A constructed-path
        open (Join-Path + Get-Content) is case-insensitive on Windows, so a
        physical 'Slot1-terminal.json' would be opened in place of the expected
        'slot1-terminal.json' and silently accepted; enumerating the directory and
        comparing the real entry name ordinally refuses that alias. Reconciliation
        and status share this resolver so neither can resolve a slot the other
        would not. A case-variant duplicate - possible only on a case-sensitive
        volume - is ambiguous slot evidence and is refused fail-closed. Returns
        $null when no exact entry exists (the slot has no terminal to a reader).
    #>
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$SlotName
    )
    if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) { return $null }
    $expectedName = "$SlotName-terminal.json"
    $all = @(Get-ChildItem -LiteralPath $RunDirectory -File -Filter "*-terminal.json" -ErrorAction SilentlyContinue)
    # Candidates are matched case-INSENSITIVELY first: any entry that differs
    # from the expected name only by case is an ALIAS of this slot's evidence.
    # More than one such alias (possible only on a case-sensitive volume) is
    # ambiguous slot evidence and is refused rather than one variant chosen.
    $aliases = @($all |
            Where-Object { [string]::Equals($_.Name, $expectedName, [StringComparison]::OrdinalIgnoreCase) })
    if ($aliases.Count -gt 1) {
        throw ("Multiple case-variant terminal files resolve to '$expectedName' under '$RunDirectory'; " +
            "ambiguous slot evidence is refused rather than one variant chosen.")
    }
    if ($aliases.Count -eq 0) { return $null }
    # Exactly one candidate: it must match the requested name ORDINALLY. A single
    # differently-cased alias (e.g. a physical 'Slot1-terminal.json' for the
    # requested 'slot1') is NOT opened in the expected slot's place - to a reader
    # the requested slot then has no case-exact terminal.
    if (-not [string]::Equals($aliases[0].Name, $expectedName, [StringComparison]::Ordinal)) {
        return $null
    }
    return $aliases[0].FullName
}

function Read-ReviewerQualificationSlotTerminal {
    <#
        Reads one slot's immutable terminal evidence. A terminal record that is
        absent, writable, or unparsable is not evidence a reader may act on.
    #>
    param([Parameter(Mandatory)][string]$TerminalPath)
    if (-not (Test-Path -LiteralPath $TerminalPath -PathType Leaf)) {
        return $null
    }
    if (-not (Get-Item -LiteralPath $TerminalPath).IsReadOnly) {
        throw "Slot terminal evidence '$TerminalPath' is writable; immutable terminal evidence is required."
    }
    return (Get-Content -LiteralPath $TerminalPath -Raw | ConvertFrom-Json)
}

function Test-ReviewerQualificationRecordedProcessAlive {
    <#
        Liveness for exactly one recorded child PID, disambiguated by start time
        so a reused PID cannot be mistaken for the qualification's own child.
        Never scans the process table by command text - a status or gate that
        matched command text would match its own inspecting shell.

        Conservative by construction: a PID that is present but whose start time
        cannot be read is reported ALIVE, not dead. This gate exists to refuse a
        reconciliation while a model process might still live; an unreadable
        identity is an unknown, and an unknown must not be resolved in the
        direction that lets reconciliation proceed.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$StartedAtUtc = "",
        [string]$EndedAtUtc = ""
    )
    if ($ProcessId -le 0) { return $false }
    $candidate = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $candidate) { return $false }
    try { $candidateStartUtc = $candidate.StartTime.ToUniversalTime() } catch { return $true }
    $lowerBound = [DateTime]::MinValue
    $upperBound = [DateTime]::MaxValue
    if ($StartedAtUtc) { $lowerBound = ([DateTimeOffset]::Parse($StartedAtUtc)).UtcDateTime.AddSeconds(-2) }
    if ($EndedAtUtc) { $upperBound = ([DateTimeOffset]::Parse($EndedAtUtc)).UtcDateTime.AddSeconds(2) }
    return ($candidateStartUtc -ge $lowerBound -and $candidateStartUtc -le $upperBound)
}

function Assert-ReviewerQualificationTerminalBoundToDeclaration {
    <#
        A terminal record is only evidence of THIS run set's slot when it names
        this set and the plan this set declared. A fabricated or stale terminal
        from another set or plan - even a correctly immutable one - is refused.
        The terminal must also name the very slot it was read as, so one slot's
        proof cannot be copied onto another slot's path. Set/plan binding no-ops
        when no expected identity is supplied (there is nothing to bind against
        yet), so a caller that has not verified a declaration is explicit about
        it rather than silently trusting the file; the slot-name check always
        runs, because a terminal always names its own slot.
    #>
    param(
        [Parameter(Mandatory)]$Terminal,
        [Parameter(Mandatory)][string]$SlotName,
        [string]$ExpectedSetId = "",
        [string]$ExpectedPlanDigest = ""
    )
    # A terminal records the slot it belongs to. One genuine slot's terminal
    # copied onto another slot's path would still carry its original slot name,
    # so a terminal whose own slot field disagrees with the path it was read
    # from is a cross-slot forgery and is refused before any identity binding.
    if ([string]$Terminal.slot -cne $SlotName) {
        throw ("Terminal evidence read as '$SlotName' records slot '$([string]$Terminal.slot)'. A terminal " +
            "copied from another slot is never accepted; each slot's proof names itself.")
    }
    if ($ExpectedSetId -and [string]$Terminal.setId -cne $ExpectedSetId) {
        throw ("Terminal evidence for '$SlotName' names run set '$([string]$Terminal.setId)', not the verified " +
            "'$ExpectedSetId'. A terminal from another set is never accepted as this set's proof.")
    }
    if ($ExpectedPlanDigest -and [string]$Terminal.planDigest -cne $ExpectedPlanDigest) {
        throw ("Terminal evidence for '$SlotName' was recorded for plan $([string]$Terminal.planDigest), not the " +
            "verified $ExpectedPlanDigest. A terminal from another plan is never accepted as this set's proof.")
    }
}

function Assert-ReviewerQualificationSlotPredecessorComplete {
    <#
        A slot never runs ahead of its predecessor. Slot N (N > 1) requires slot
        N-1 to have recorded an immutable, successful terminal result, bound to
        this verified set and plan, with its recorded child no longer alive: the
        run set advances one authorized, proven slot at a time and never launches
        a replacement or a later slot after a failure, a timeout, or while the
        predecessor's process might still live.
    #>
    param(
        [Parameter(Mandatory)][string]$SlotName,
        [Parameter(Mandatory)][string]$RunDirectory,
        [string]$ExpectedSetId = "",
        [string]$ExpectedPlanDigest = ""
    )
    if ($SlotName -notmatch '^slot([0-9]+)\z') {
        throw "Slot name '$SlotName' is not of the form slotN."
    }
    $ordinal = [int]$Matches[1]
    if ($ordinal -le 1) { return }
    $predecessor = "slot$($ordinal - 1)"
    $predecessorTerminalPath = Resolve-ReviewerQualificationSlotTerminalPath -RunDirectory $RunDirectory -SlotName $predecessor
    if (-not $predecessorTerminalPath) {
        throw ("Slot '$SlotName' cannot start before '$predecessor' records an immutable successful terminal " +
            "result: no case-exact '$predecessor-terminal.json' exists under '$RunDirectory'. One authorized slot proceeds at a time.")
    }
    $predecessorTerminal = Read-ReviewerQualificationSlotTerminal -TerminalPath $predecessorTerminalPath
    Assert-ReviewerQualificationTerminalBoundToDeclaration -Terminal $predecessorTerminal -SlotName $predecessor `
        -ExpectedSetId $ExpectedSetId -ExpectedPlanDigest $ExpectedPlanDigest
    if ([string]$predecessorTerminal.status -cne "complete") {
        throw ("Slot '$SlotName' requires '$predecessor' to have completed successfully; its immutable terminal " +
            "status is '$([string]$predecessorTerminal.status)'. A later slot never follows a failed or timed-out one.")
    }
    if (Test-ReviewerQualificationRecordedProcessAlive -ProcessId ([int]$predecessorTerminal.childProcessId) `
            -StartedAtUtc ([string]$predecessorTerminal.startedAtUtc) -EndedAtUtc ([string]$predecessorTerminal.endedAtUtc)) {
        throw ("Slot '$SlotName' cannot start while '$predecessor' recorded child " +
            "$([int]$predecessorTerminal.childProcessId) is still running. One slot's process ends before the next begins.")
    }
}

function Assert-ReviewerQualificationReconciliationReady {
    <#
        Reconciliation is the only step that reads across slots, so it is the
        step most tempted to proceed on a partial set. It requires every slot to
        have a complete, immutable terminal result - bound to this verified set
        and plan - and no recorded child still alive: both terminal-success slots
        and no live model process.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$ExpectedSetId = "",
        [string]$ExpectedPlanDigest = ""
    )
    $runDirectory = [string]$Plan.RunDirectory
    $reconciled = [System.Collections.Generic.List[object]]::new()
    foreach ($slot in @($Plan.Slots)) {
        $terminalPath = Resolve-ReviewerQualificationSlotTerminalPath -RunDirectory $runDirectory -SlotName ([string]$slot.Name)
        $terminal = if ($terminalPath) { Read-ReviewerQualificationSlotTerminal -TerminalPath $terminalPath } else { $null }
        if (-not $terminal) {
            throw (New-ReviewerQualificationFault -Code "reconciliationSlotTerminalAbsent" -Message (
                    "Reconciliation requires every slot to have a terminal result; '$($slot.Name)' has no case-exact " +
                    "'$($slot.Name)-terminal.json' under '$runDirectory'. Run and complete all $($Plan.SlotCount) slots first."))
        }
        Assert-ReviewerQualificationTerminalBoundToDeclaration -Terminal $terminal -SlotName ([string]$slot.Name) `
            -ExpectedSetId $ExpectedSetId -ExpectedPlanDigest $ExpectedPlanDigest
        if ([string]$terminal.status -cne "complete") {
            throw (New-ReviewerQualificationFault -Code "reconciliationSlotNotComplete" -Message (
                    "Reconciliation requires every slot to have completed successfully; '$($slot.Name)' terminated " +
                    "'$([string]$terminal.status)'. A partial or failed set is never reconciled."))
        }
        if (Test-ReviewerQualificationRecordedProcessAlive -ProcessId ([int]$terminal.childProcessId) `
                -StartedAtUtc ([string]$terminal.startedAtUtc) -EndedAtUtc ([string]$terminal.endedAtUtc)) {
            throw (New-ReviewerQualificationFault -Code "reconciliationSlotChildAlive" -Message (
                    "Reconciliation refuses a live model process: '$($slot.Name)' recorded child " +
                    "$([int]$terminal.childProcessId) is still running. No reconciliation while a slot's process lives."))
        }
        [void]$reconciled.Add([pscustomobject][ordered]@{
                slot           = [string]$slot.Name
                status         = [string]$terminal.status
                exitCode       = [int]$terminal.exitCode
                childProcessId = [int]$terminal.childProcessId
            })
    }
    return @($reconciled)
}

function Get-VerifiedRunSetDeclaration {
    <#
        Reads the single sealed run-set declaration under a qualification root and
        verifies it under the run-set signing key BEFORE anything in it is
        believed. An envelope parsed as text is a file anybody could have written;
        a signature check is the only thing that makes it a declaration - and it
        is also what detects a truncated or corrupted published declaration, since
        a partial or altered envelope no longer verifies. This is the SIGNATURE
        boundary only: it returns the verified declaration object and its path and
        throws solely when there is not exactly one declaration or the signature
        does not verify. Whether that authentic declaration MATCHES this plan
        (snapshot, run count, full plan digest) is a separate question answered by
        Assert-ReviewerQualificationDeclarationMatchesPlan, so a caller can tell a
        corrupt/tampered declaration (signature failure) apart from a benign
        plan-input mismatch (wrong count, snapshot, models, repo, timeouts). The
        coordinator's Declare/RunSlot/Reconcile paths and the status reader all
        call this one copy, so none can accept a declaration another would reject.
    #>
    param(
        [Parameter(Mandatory)][string]$RunSetDirectory,
        [Parameter(Mandatory)][string]$CompareTool,
        [Parameter(Mandatory)][string]$RunSetKeyPath
    )
    $declarationPaths = @()
    if (Test-Path -LiteralPath $RunSetDirectory -PathType Container) {
        $declarationPaths = @(Get-ChildItem -LiteralPath $RunSetDirectory -Filter "runset-*.json" -File `
                -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.sig" } |
                ForEach-Object { $_.FullName })
    }
    if ($declarationPaths.Count -ne 1) {
        throw (New-ReviewerQualificationFault -Code "declarationCountNotOne" -Message (
                "Expected exactly one sealed run-set declaration under '$RunSetDirectory'; " +
                "found $($declarationPaths.Count). Declare the set first (-Mode Declare)."))
    }
    # The verifier is a separate tool and it throws its own refusal when the
    # signature does not hold. Caught and re-raised with a code here, because a
    # fault that crosses a tool boundary untyped is a fault the caller can only
    # classify by reading its text - which is exactly what this contract exists
    # to stop. The message is carried through unchanged and the original becomes
    # the inner exception, so a typed fault raised inside the tool is still
    # readable through the wrapper and nothing is lost by the re-raise.
    #
    # Two codes, not one, and the split is the whole point. A verifier that RAN
    # and refused is evidence about the published bytes. A verifier that could
    # not be run at all - a tool path that does not resolve, a key file that is
    # missing or unreadable, a locked file - is evidence about this machine, and
    # calling that corruption would put the verdict back where this contract took
    # it from: on something other than the bytes. The inputs are proven first so
    # the ordinary operator error (a mistyped -RunSetKeyPath) never reaches the
    # catch at all.
    foreach ($required in @(
            @{ Path = [string]$CompareTool; What = "The run-set comparison tool" },
            @{ Path = [string]$RunSetKeyPath; What = "The run-set signing key" })) {
        $requiredPath = [string]$required.Path
        $requiredWhat = [string]$required.What
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw (New-ReviewerQualificationFault -Code "declarationVerificationUnavailable" -Message (
                    "$requiredWhat at '$requiredPath' does not exist, so the declaration under " +
                    "'$RunSetDirectory' could not be verified. This says nothing about the published set."))
        }
    }
    try {
        $verifiedOutput = & $CompareTool -VerifyRunSet -RunSetPath $declarationPaths[0] -KeyPath $RunSetKeyPath
    }
    catch [Management.Automation.CommandNotFoundException] {
        throw (New-ReviewerQualificationFault -Code "declarationVerificationUnavailable" `
                -Message ([string]$_.Exception.Message) -InnerError $_)
    }
    catch [IO.IOException] {
        throw (New-ReviewerQualificationFault -Code "declarationVerificationUnavailable" `
                -Message ([string]$_.Exception.Message) -InnerError $_)
    }
    catch [UnauthorizedAccessException] {
        throw (New-ReviewerQualificationFault -Code "declarationVerificationUnavailable" `
                -Message ([string]$_.Exception.Message) -InnerError $_)
    }
    catch {
        throw (New-ReviewerQualificationFault -Code "declarationVerificationFaulted" `
                -Message ([string]$_.Exception.Message) -InnerError $_)
    }
    $verifiedJson = @(@($verifiedOutput) |
            Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith("{") } |
            Select-Object -Last 1)
    if (@($verifiedJson).Count -ne 1) {
        throw (New-ReviewerQualificationFault -Code "declarationSignatureUnverified" -Message (
                "Verification of '$($declarationPaths[0])' returned no manifest; the declaration did not verify " +
                "under '$RunSetKeyPath'. A published declaration that no longer verifies is corrupt or tampered and is never launchable."))
    }
    $declaration = [string]$verifiedJson[0] | ConvertFrom-Json
    return [pscustomobject]@{ Declaration = $declaration; Path = $declarationPaths[0] }
}

function Assert-ReviewerQualificationDeclarationMatchesPlan {
    <#
        Given a signature-verified declaration and a plan, refuses the declaration
        unless it was sealed FOR this plan. Same snapshot, different models - or a
        different reviewed repository, a different agent build, different timeouts,
        a different operator - is a different qualification wearing this one's
        seal, and snapshot-and-count alone cannot see it. When an ExpectedPlanDigest
        is supplied (the caller reproduces it from the token that sealed the set:
        a slot presents its token, reconciliation reads the published one), the
        declaration's own sealed digest must equal it exactly, binding EVERY plan
        input. This is the plan-identity boundary, kept apart from the signature
        boundary so a plan-input mismatch is never mislabeled a signature failure.
    #>
    param(
        [Parameter(Mandatory)]$Declaration,
        [Parameter(Mandatory)]$Plan,
        [string]$ExpectedPlanDigest = ""
    )
    if ([string]$Declaration.snapshotName -cne [string]$Plan.Snapshot.Name -or
        [string]$Declaration.snapshotManifestDigest -cne [string]$Plan.Snapshot.ManifestDigest) {
        throw (New-ReviewerQualificationFault -Code "declarationSnapshotMismatch" -Message (
                "The sealed declaration names snapshot '$($Declaration.snapshotName)' at digest " +
                "$($Declaration.snapshotManifestDigest); this plan replays '$($Plan.Snapshot.Name)' at " +
                "$($Plan.Snapshot.ManifestDigest). A slot never runs against a declaration it does not match."))
    }
    if ([int]$Declaration.plannedRunCount -ne [int]$Plan.SlotCount) {
        throw (New-ReviewerQualificationFault -Code "declarationRunCountMismatch" -Message (
                "The sealed declaration plans $([int]$Declaration.plannedRunCount) run(s) and this plan has " +
                "$($Plan.SlotCount) slot(s)."))
    }
    $declaredPlanDigest = ""
    if ($Declaration.PSObject.Properties["planDigest"]) { $declaredPlanDigest = [string]$Declaration.planDigest }
    if (-not $declaredPlanDigest) {
        throw (New-ReviewerQualificationFault -Code "declarationPlanDigestAbsent" -Message (
                "The sealed declaration $($Declaration.setId) carries no plan digest, so it cannot say which commands " +
                "it authorized. Declare a new set with this build of the tool."))
    }
    if ($ExpectedPlanDigest -and $declaredPlanDigest -cne $ExpectedPlanDigest) {
        throw (New-ReviewerQualificationFault -Code "declarationPlanDigestMismatch" -Message (
                "The sealed declaration $($Declaration.setId) was made for plan $declaredPlanDigest and this plan " +
                "hashes to $ExpectedPlanDigest. Every slot of a set runs the plan that was declared - the reviewed " +
                "repository, the models, the timeouts and every other plan input, not the snapshot and slot count alone."))
    }
}

function Assert-ReviewerQualificationPublishedInventory {
    <#
        A published run set is complete or it is nothing. Directory.Move makes the
        namespace flip atomic against process death and concurrent publishers, but
        it is NOT a power-loss fsync barrier: a host or filesystem crash mid-write
        can leave a runset directory whose files are present in the namespace yet
        truncated or missing. The signature check catches a corrupt declaration;
        this check catches an incomplete INVENTORY - the launch-authorization
        token a complete publish always carries. A runset directory missing its
        token, or carrying a malformed one, is classified as a corrupt published
        set: not reconcilable, not launchable, and never silently treated as a
        valid set. Recoverability after arbitrary host/filesystem loss is NOT
        claimed; such a set is reported corrupt and a new root is declared.
        Returns the validated 64-hex token text so the caller can reproduce the
        plan digest the set was sealed under without re-reading the file.
    #>
    param([Parameter(Mandatory)][string]$RunSetDirectory)
    $tokenPath = Join-Path $RunSetDirectory "launch-authorization.token"
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        throw (New-ReviewerQualificationFault -Code "publishedTokenMissing" -Message (
                "The published run set under '$RunSetDirectory' is missing its launch-authorization token; " +
                "the publish is incomplete or corrupt. A partial published set is never reconcilable or launchable."))
    }
    $tokenText = ([IO.File]::ReadAllText($tokenPath)).Trim()
    if ($tokenText -notmatch '^[0-9a-f]{64}\z') {
        throw (New-ReviewerQualificationFault -Code "publishedTokenMalformed" -Message (
                "The published launch-authorization token under '$RunSetDirectory' is malformed (expected 64 " +
                "lowercase hex characters); the published set is corrupt and never reconcilable or launchable."))
    }
    return $tokenText
}

function Assert-ReviewerQualificationSetReconcilable {
    <#
        The single shared pre-model readiness gate for a declared run set. The
        coordinator's Reconcile mode calls it and acts on the result; the status
        reader calls it inside a try/catch and reports the outcome. Because both
        run the SAME sequence over the SAME reconstructed plan, status can never
        report a set reconciliation-ready that Reconcile would reject, nor the
        reverse, for the same authenticated inputs. It verifies the sealed
        declaration under the key (the signature boundary, which also detects a
        corrupt/truncated one), confirms the published inventory is complete and
        reads the launch token it carries, reproduces THIS plan's full digest with
        that token and requires it to equal the declaration's sealed digest - so a
        divergence in any plan input (repository, models, timeouts, operator, ...)
        and not just snapshot and slot count is refused - and binds every slot's
        immutable terminal to the verified set and plan with no live child.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$CompareTool,
        [Parameter(Mandatory)][string]$RunSetKeyPath
    )
    # Signature boundary: the declaration is authentic (or the set is corrupt).
    $verified = Get-VerifiedRunSetDeclaration -RunSetDirectory ([string]$Plan.RunSetDirectory) `
        -CompareTool $CompareTool -RunSetKeyPath $RunSetKeyPath
    # Inventory boundary: a complete publish carries its launch token. Reading it
    # here lets reconciliation - which holds no token of its own - reproduce the
    # exact plan digest the set was sealed under.
    $publishedToken = Assert-ReviewerQualificationPublishedInventory -RunSetDirectory ([string]$Plan.RunSetDirectory)
    $publishedTokenHash = Get-ReviewerQualificationLaunchTokenHash -Token $publishedToken
    $originalHash = [string]$Plan.LaunchAuthorizationHash
    $currentDigest = ""
    try {
        $Plan.LaunchAuthorizationHash = $publishedTokenHash
        $currentDigest = Get-ReviewerQualificationPlanDigest -Plan $Plan
    }
    finally {
        $Plan.LaunchAuthorizationHash = $originalHash
    }
    # Plan-identity boundary: bind the FULL plan, not snapshot and count alone.
    Assert-ReviewerQualificationDeclarationMatchesPlan -Declaration $verified.Declaration -Plan $Plan `
        -ExpectedPlanDigest $currentDigest
    $slots = Assert-ReviewerQualificationReconciliationReady -Plan $Plan `
        -ExpectedSetId ([string]$verified.Declaration.setId) `
        -ExpectedPlanDigest ([string]$verified.Declaration.planDigest)
    return [pscustomobject]@{ Declaration = $verified.Declaration; Slots = @($slots) }
}