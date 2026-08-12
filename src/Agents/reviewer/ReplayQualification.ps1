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
        [string]$ConventionSpecialistModel = "",
        [string]$ConventionVerifierModel = ""
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
    #>
    param([Parameter(Mandatory)]$Plan)

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
            if ([bool]$resolved.stateDirExists) {
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