#!/usr/bin/env pwsh
<#
.SYNOPSIS
    End-to-end checks for the offline replay qualification wrapper: the derived
    generalist pairing, the constructed slot commands, and the argument binding
    that has to succeed BEFORE a run set may be declared.

.DESCRIPTION
    Offline and deterministic. No model is launched, no network call is made,
    no repository host is contacted, and every fixture is either the committed
    synthetic replay snapshot or something this script builds in a sandbox it
    owns and deletes.

    The two defects these checks exist for both killed a slot before any model
    ran, after a run set had already been sealed:

      * a slot naming a model version the agent's startup validation no longer
        accepted, and
      * a slot that omitted -RepoPath, leaving the agent to resolve the
        reviewed repository from a config that lives outside one.

    So the checks below drive the real construction, run it through the real
    Start-ReviewerAgent.ps1 up to that agent's own model-launch boundary (its
    -QualificationPrelaunch mode, which validates everything and exits before
    it creates any state), and prove that tampering with either of those two
    things fails there rather than in a spoiled qualification set. They also
    prove the declaration is sealed under a digest of the exact plan, and that
    a slot's single attempt is consumed before its child process starts.

.EXAMPLE
    ./tools/Test-ReviewerReplayQualification.ps1
#>
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $RepoRoot "src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
. (Join-Path $RepoRoot "src\Agents\reviewer\QualificationPreflight.ps1")
. (Join-Path $RepoRoot "src\Agents\reviewer\ReplayQualification.ps1")

$script:Checks = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:PwshPath = if ((Get-Process -Id $PID).Path) { (Get-Process -Id $PID).Path } else { "pwsh" }

function Assert-Qualification {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:Checks++
    if (-not $Condition) {
        [void]$script:Failures.Add($Message)
        Write-Host "  FAIL - $Message" -ForegroundColor Red
    }
}

function Assert-QualificationThrows {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message,
        [string]$Match
    )
    $script:Checks++
    try {
        & $Action | Out-Null
        [void]$script:Failures.Add($Message)
        Write-Host "  FAIL - $Message" -ForegroundColor Red
    }
    catch {
        if ($Match -and [string]$_.Exception.Message -notmatch $Match) {
            [void]$script:Failures.Add("$Message (threw for another reason: $($_.Exception.Message))")
            Write-Host "  FAIL - $Message (wrong reason: $($_.Exception.Message))" -ForegroundColor Red
        }
    }
}

function Invoke-SandboxGit {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    & git -C $Path @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed in $Path." }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("reviewer-qualification-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

try {
    # -- 1. The generalist pairing has exactly one source ---------------------
    Write-Host "1/11 derived generalist pairing" -ForegroundColor Cyan
    $pair = Get-AgentGeneralistModelPair
    $supported = Get-AgentSupportedModels
    Assert-Qualification (@($pair.Models).Count -eq 2 -and $pair.First -cne $pair.Second) `
        "The derived generalist pairing is not two distinct models."
    Assert-Qualification ($supported -ccontains $pair.First -and $supported -ccontains $pair.Second) `
        "The derived generalist pairing names a model outside the supported registry."
    Assert-Qualification ($pair.First -cmatch '^claude-opus-' -and $pair.Second -cmatch '^gpt-') `
        "The derived pairing is not one current Opus and one current GPT model."
    Assert-Qualification ($pair.SortedKey -ceq ((@($pair.Models) | Sort-Object) -join '|')) `
        "The sealed generalistPassModels key is not the sorted derived pairing."
    Assert-Qualification (Test-AgentGeneralistModelPair -Models @($pair.Second, $pair.First)) `
        "The pairing test rejected the derived pairing supplied in the other order."
    # The stale-version defect, stated directly: the retired Opus build is still
    # a supported model, and is still not the pairing.
    $retiredOpus = @($supported | Where-Object { $_ -cmatch '^claude-opus-' -and $_ -cne $pair.First }) |
        Select-Object -First 1
    Assert-Qualification ($retiredOpus -and -not (Test-AgentGeneralistModelPair -Models @($retiredOpus, $pair.Second))) `
        "A superseded Opus build was accepted as half of the current generalist pairing."
    Assert-QualificationThrows {
        Get-AgentGeneralistModelPair -SupportedModels @("claude-sonnet-5", "gemini-3.5-flash")
    } "A registry with no Opus generalist still produced a pairing." "carries no"

    # No consumer may write a model version down for itself: the reviewer must
    # carry zero model-id literals, so a registry edit cannot leave one behind.
    $reviewerScript = Join-Path $RepoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"
    $tokens = $null
    $parseErrors = $null
    $reviewerAst = [System.Management.Automation.Language.Parser]::ParseFile($reviewerScript, [ref]$tokens, [ref]$parseErrors)
    Assert-Qualification (@($parseErrors).Count -eq 0) "The reviewer script does not parse."
    $modelLiterals = @(@($tokens) |
            Where-Object { $_.Kind -eq "StringLiteral" -or $_.Kind -eq "StringExpandable" } |
            Where-Object { @($supported) -ccontains [string]$_.Value })
    Assert-Qualification ($modelLiterals.Count -eq 0) `
        ("The reviewer script hardcodes model id(s) instead of deriving them: " +
            (@(@($modelLiterals) | ForEach-Object { [string]$_.Value }) -join ', ') + ".")

    # The candidate-discovery read has one composer, and the prelaunch probe and
    # the cycle both call it. A probe that composed its own copy could preflight
    # a read the run never issues - and the run would then ask for a read no
    # bounded snapshot carries, which is the defect that spoiled a declared set.
    $composerDefinitions = @($reviewerAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq "Get-ReviewerCandidateSourceRequest"
            }, $true))
    $composerCalls = @($reviewerAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                [string]$node.GetCommandName() -ceq "Get-ReviewerCandidateSourceRequest"
            }, $true))
    Assert-Qualification ($composerDefinitions.Count -eq 1 -and $composerCalls.Count -ge 2) `
        "The candidate-discovery request is not composed once and shared by the prelaunch probe and the cycle."

    # -- 2. Sandbox: a clean reviewer build, a reviewed repo, a config --------
    Write-Host "2/11 sandbox reviewer build" -ForegroundColor Cyan
    $toolkitCopy = Join-Path $sandbox "toolkit"
    New-Item -ItemType Directory -Force -Path $toolkitCopy | Out-Null
    Copy-Item -Recurse -Force (Join-Path $RepoRoot "src") (Join-Path $toolkitCopy "src")
    Copy-Item -Recurse -Force (Join-Path $RepoRoot "tools") (Join-Path $toolkitCopy "tools")
    # A stand-in agent, committed into the sandbox build alongside the real one.
    # It exists for exactly one check that the real agent cannot serve without
    # launching a model: what happens to a slot whose child process fails at
    # startup. It answers the prelaunch seam truthfully from its own bound
    # parameters, and fails immediately in any other mode - creating nothing,
    # which is the point.
    $failingAgent = Join-Path $toolkitCopy "src\Agents\reviewer\FailingStartupAgent.test.ps1"
    Set-Content -LiteralPath $failingAgent -Encoding utf8NoBOM -Value @'
[CmdletBinding()]
param(
    [string]$RepoPath, [string]$ConfigFile, [string]$StateDir, [string]$OperatorAlias,
    [switch]$Once, [int]$PullRequestId, [string]$Model, [string]$SecondPassModel,
    [switch]$EnableConventionSpecialist, [string]$ConventionSpecialistModel,
    [switch]$EnableVerificationPreview, [string]$ConventionVerifierModel,
    [string]$ReplayRoot, [string]$ReplaySnapshotName, [string]$ReplayManifestDigest,
    [int]$CycleTimeoutSeconds, [int]$ConventionSpecialistTimeoutSeconds, [int]$VerificationTimeoutSeconds,
    [switch]$QualificationPrelaunch
)
Set-StrictMode -Version Latest
if (-not $QualificationPrelaunch) {
    # A startup failure strictly before any state exists.
    Write-Error "stand-in agent fails at startup"
    exit 9
}
Import-Module (Join-Path $PSScriptRoot "..\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force
$standInConfig = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
$standInProbeArguments = [ordered]@{
    action        = 'get'
    project       = [string]$standInConfig.repository.project
    repositoryId  = [string]$standInConfig.repository.name
    pullRequestId = $PullRequestId
}
$standInProbeKey = Get-AgentReplayRequestKey -Name "repo_pull_request" -Arguments $standInProbeArguments
$report = [ordered]@{
    seam = "reviewer.qualification-prelaunch.v1"
    agentScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    configFile = $ConfigFile
    configSha256 = (Get-FileHash -LiteralPath $ConfigFile -Algorithm SHA256).Hash.ToLowerInvariant()
    repoPath = $RepoPath
    plannedStateDir = $StateDir
    stateDirExists = [bool](Test-Path -LiteralPath $StateDir)
    model = $Model
    secondPassModel = $SecondPassModel
    isTwoPass = $true
    conventionSpecialist = [bool]$EnableConventionSpecialist
    conventionSpecialistModel = $ConventionSpecialistModel
    pullRequestId = $PullRequestId
    replayActive = $true
    replaySnapshotId = $ReplaySnapshotName
    replayManifestDigest = $ReplayManifestDigest.ToLowerInvariant()
    replayNonPromotable = $false
    deliveryAuthorization = "PreviewOnly"
    sourceProbeTool = "repo_pull_request"
    sourceProbeAction = "get"
    sourceProbeArguments = [pscustomobject]$standInProbeArguments
    sourceProbeRequestSha256 = $standInProbeKey.Key
    sourceProbePullRequestId = $PullRequestId
}
Write-Output ("REVIEWER_QUALIFICATION_PRELAUNCH_V1 " +
    (ConvertTo-Json -InputObject ([pscustomobject]$report) -Depth 6 -Compress))
exit 0
'@
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("init", "--quiet")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("config", "user.name", "Qualification Test")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("config", "user.email", "qualification@example.invalid")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("add", "--all")
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("commit", "--quiet", "-m", "reviewer build under qualification")
    $head = (& git -C $toolkitCopy rev-parse HEAD).Trim()
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("branch", "reviewer-layer", $head)
    # An app-created worktree's generated branch name is deliberately unrelated
    # to the accepted layer; the commit and the required ref are the identity.
    Invoke-SandboxGit -Path $toolkitCopy -Arguments @("checkout", "--quiet", "-b", "generated-app-worktree")

    $sandboxReviewerScript = Join-Path $toolkitCopy "src\Agents\reviewer\Start-ReviewerAgent.ps1"
    $sandboxTool = Join-Path $toolkitCopy "tools\Invoke-ReviewerReplayQualification.ps1"
    $committedReplayRoot = Join-Path $toolkitCopy "src\Agents\reviewer\testdata\replay-v1"

    $reviewedRepo = Join-Path $sandbox "reviewed-repo"
    New-Item -ItemType Directory -Force -Path $reviewedRepo | Out-Null
    $configDir = Join-Path $sandbox "qualification-inputs"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $qualificationRoot = Join-Path $sandbox "qualification-root"

    # A qualification config, like the real ones, lives OUTSIDE the reviewed
    # repository - which is exactly why -RepoPath cannot be left to inference.
    $config = Get-Content -LiteralPath (Join-Path $RepoRoot "samples\reviewer-ado.config.json") -Raw | ConvertFrom-Json
    $config.review.conventionSpecialistModel = "claude-sonnet-5"
    $config.review.verification.enabled = $true
    $config.review.verification.conventionVerifierModel = $pair.Second
    $configPath = Join-Path $configDir "qualification.config.json"
    Set-Content -LiteralPath $configPath -Value (ConvertTo-Json -InputObject $config -Depth 20) -Encoding utf8NoBOM

    # A snapshot sealed the way a real bounded one is: it carries the DIRECT
    # read for one named pull request and no repository-wide census, and its
    # recorded request is keyed on the repository identity this config actually
    # asks with (the configured repository NAME, which is what the agent passes
    # as repositoryId). A snapshot recorded under a different identity than the
    # config names cannot answer the run's first read - the defect this fixture
    # exists to keep closed, exercised as a refusal further down.
    $snapshotPrId = 4242
    $replayRoot = Join-Path $sandbox "replay-root"
    $snapshotName = "qualification-direct-get"
    $snapshotDir = Join-Path $replayRoot $snapshotName
    New-Item -ItemType Directory -Force -Path (Join-Path $snapshotDir "payloads") | Out-Null
    $recordedPullRequest = [ordered]@{
        pullRequestId = $snapshotPrId
        title         = "Synthetic pull request"
        status        = "active"
        sourceRefName = "refs/heads/feature"
        targetRefName = "refs/heads/main"
    }
    $recordedResponse = [ordered]@{
        jsonrpc = "2.0"
        id      = 1
        result  = [ordered]@{
            content = @([ordered]@{
                    type = "text"
                    text = (ConvertTo-Json -InputObject $recordedPullRequest -Depth 6 -Compress)
                })
        }
    }
    Set-Content -LiteralPath (Join-Path $snapshotDir "payloads\pr-get.json") -Encoding utf8NoBOM `
        -Value (ConvertTo-Json -InputObject $recordedResponse -Depth 10 -Compress)
    $recipePath = Join-Path $snapshotDir "recipe.json"
    Set-Content -LiteralPath $recipePath -Encoding utf8NoBOM -Value (ConvertTo-Json -Depth 10 -InputObject @(
            [ordered]@{
                tool        = "repo_pull_request"
                arguments   = [ordered]@{
                    action        = "get"
                    project       = [string]$config.repository.project
                    repositoryId  = [string]$config.repository.name
                    pullRequestId = $snapshotPrId
                }
                payloadFile = "payloads/pr-get.json"
            }))
    & (Join-Path $RepoRoot "tools\Save-AgentReplaySnapshot.ps1") -SnapshotPath $snapshotDir -Recipe $recipePath `
        -Organization ([string]$config.repository.organization) -Project ([string]$config.repository.project) `
        -RepositoryId ([string]$config.repository.id) -PullRequestId $snapshotPrId `
        -SourceCommit ("a" * 40) -TargetCommit ("b" * 40) -Models @($pair.First, $pair.Second) | Out-Null
    $snapshotManifest = Get-Content -LiteralPath (Join-Path $snapshotDir "manifest.json") -Raw | ConvertFrom-Json
    $digest = [string]$snapshotManifest.manifestDigest
    $recordedGetRequestSha256 = [string](@($snapshotManifest.resources |
                Where-Object { [string]$_.tool -ceq "repo_pull_request" -and [string]$_.arguments.action -ceq "get" })[0].requestSha256)
    Assert-Qualification (@($snapshotManifest.resources).Count -eq 1 -and $recordedGetRequestSha256) `
        "The synthetic bounded snapshot does not carry exactly the one direct-get response it is built from."

    $planArguments = @{
        RepoPath             = $reviewedRepo
        ConfigFile           = $configPath
        OperatorAlias        = "example-operator"
        PullRequestId        = $snapshotPrId
        ReplayRoot           = $replayRoot
        ReplaySnapshotName   = $snapshotName
        ReplayManifestDigest = $digest
        QualificationRoot    = $qualificationRoot
        ReviewerScriptPath   = $sandboxReviewerScript
        ExpectedCommit       = $head
        RequiredRef          = "refs/heads/reviewer-layer"
    }

    # -- 3. The plan validates before it constructs ---------------------------
    Write-Host "3/11 plan construction and normalization" -ForegroundColor Cyan
    $plan = New-ReviewerReplayQualificationPlan @planArguments
    Assert-Qualification (@($plan.Slots).Count -eq 2) "The default plan is not a two-slot plan."
    Assert-Qualification ($plan.RepoPath -ceq [IO.Path]::GetFullPath($reviewedRepo).TrimEnd([IO.Path]::DirectorySeparatorChar)) `
        "The plan did not normalize -RepoPath to a rooted, separator-stable full path."
    Assert-Qualification ($plan.Models.First -ceq $pair.First -and $plan.Models.Second -ceq $pair.Second) `
        "The plan did not select the derived generalist pairing."
    Assert-Qualification ($plan.Snapshot.ManifestDigest -ceq $digest.ToLowerInvariant() -and
        $plan.Snapshot.PullRequestId -eq $snapshotPrId) `
        "The plan did not load and bind the snapshot it was given."
    Assert-Qualification ($plan.Snapshot.ResourceCount -gt 0) "The plan reported a snapshot with no recorded reads."
    Assert-Qualification (-not $plan.Promotable -and $plan.DeliveryMode -ceq "previewOnly") `
        "The plan did not record the replay as non-promotable, preview-only work."
    Assert-Qualification ($plan.GitIdentity.head -ceq $head -and [bool]$plan.GitIdentity.clean -and
        $plan.GitIdentity.currentBranch -ceq "generated-app-worktree") `
        "The plan did not pin a clean reviewer build at the expected commit from a generated worktree branch."

    # -- 4. Both slot commands reach the AGENT'S model-launch boundary --------
    Write-Host "4/11 real prelaunch boundary" -ForegroundColor Cyan
    $evidence = Assert-ReviewerReplayQualificationPlan -Plan $plan
    Assert-Qualification (@($evidence).Count -eq 2) "Both slots were not validated."
    foreach ($item in @($evidence)) {
        Assert-Qualification ($item.Seam -ceq "reviewer.qualification-prelaunch.v1") `
            "$($item.Slot) did not stop at the agent's own prelaunch seam."
        Assert-Qualification ($item.AgentScriptSha256 -ceq $plan.ReviewerScriptSha256) `
            "$($item.Slot) was validated by an agent other than the pinned build."
        Assert-Qualification ($item.RepoPath -ceq $plan.RepoPath) `
            "$($item.Slot) did not resolve the normalized -RepoPath."
        Assert-Qualification ($item.Model -ceq $pair.First -and $item.SecondPassModel -ceq $pair.Second) `
            "$($item.Slot) did not resolve the supported current generalist pairing."
        Assert-Qualification ($item.SnapshotId -ceq $snapshotName -and
            $item.SnapshotManifestDigest -ceq $digest.ToLowerInvariant() -and
            $item.PullRequestId -eq $snapshotPrId) `
            "$($item.Slot) did not load and bind the snapshot inside the agent."
        # The run's FIRST source read, proven end to end: the agent issued a
        # bounded direct get keyed on the configured repository name, the
        # snapshot answered it with the pull request under qualification, and
        # the request it asked with is the one this snapshot actually records.
        Assert-Qualification ($item.SourceProbeTool -ceq "repo_pull_request" -and $item.SourceProbeAction -ceq "get") `
            "$($item.Slot) opened with '$($item.SourceProbeTool)/$($item.SourceProbeAction)' rather than a bounded direct get."
        Assert-Qualification ($item.SourceProbeRepositoryId -ceq [string]$config.repository.name) `
            "$($item.Slot) asked for its pull request under a repository identity the config does not name."
        Assert-Qualification ($item.SourceProbeRequestSha256 -ceq $recordedGetRequestSha256) `
            "$($item.Slot) opened with a read the sealed snapshot does not record."
        Assert-Qualification ($item.SourceProbePullRequestId -eq $snapshotPrId) `
            "$($item.Slot) did not resolve the pull request under qualification from the snapshot's recorded read."
        Assert-Qualification ($item.DeliveryAuthorization -ceq "PreviewOnly") `
            "$($item.Slot) resolved a delivery authorization other than preview-only."
        Assert-Qualification (-not $item.StateDirExists -and -not (Test-Path -LiteralPath $item.StateDir)) `
            "$($item.Slot) left state behind at its planned state directory."
    }
    Assert-Qualification (-not (Test-Path -LiteralPath $qualificationRoot)) `
        "Validating the plan created qualification state."
    # The boundary lives in the agent now; the generated stand-in seam that used
    # to be written into the machine's temp area is gone with it.
    Assert-Qualification (-not (Get-Command Get-ReviewerQualificationLaunchBoundarySeam -ErrorAction SilentlyContinue)) `
        "A generated launch-boundary seam still stands in for the agent's own startup."
    Assert-Qualification (@($plan.Slots)[0].StateDir -cne @($plan.Slots)[1].StateDir) `
        "The two slots share a state directory."
    foreach ($plannedSlot in @($plan.Slots)) {
        Assert-Qualification (@($plannedSlot.Arguments)[0] -ceq "-RepoPath") `
            "$($plannedSlot.Name) does not bind -RepoPath first and unconditionally."
        Assert-Qualification (@($plannedSlot.Arguments) -cnotcontains "-QualificationPrelaunch") `
            "$($plannedSlot.Name) carries the prelaunch switch into the real run."
        Assert-Qualification ($plannedSlot.CommandText -match '(?i)Start-ReviewerAgent\.ps1') `
            "$($plannedSlot.Name) command text does not name the reviewer script."
    }

    # The prelaunch mode is an earlier exit, never a new capability: it refuses
    # to combine with anything that delivers, promotes, captures or mutates.
    $prelaunchArguments = [string[]]@(@($plan.Slots)[0].Arguments)
    # -PromotePreview names an artifact rather than being a bare switch, so it is
    # supplied the way an operator would supply it.
    foreach ($forbiddenCombination in @(
            , @("-DryRun"),
            @("-PromotePreview", (Join-Path $sandbox "preview.json")),
            @("-EnableApprovalVote"),
            @("-ShowState"),
            @("-CaptureSourceTransportOnly"))) {
        $combined = @($prelaunchArguments) + @($forbiddenCombination)
        $output = & $script:PwshPath -NoLogo -NoProfile -NonInteractive -File $sandboxReviewerScript `
            @combined -QualificationPrelaunch 2>&1 | Out-String
        Assert-Qualification ($LASTEXITCODE -ne 0 -and $output -match "cannot be combined with") `
            "The agent accepted -QualificationPrelaunch together with $(@($forbiddenCombination)[0])."
    }
    Assert-Qualification (-not (Test-Path -LiteralPath (Join-Path (Join-Path $qualificationRoot "runs") "slot1-state"))) `
        "A refused prelaunch combination still created slot state."

    # -- 5. Tampering with the one constructed argv is caught -----------------
    Write-Host "5/11 constructed-command guards" -ForegroundColor Cyan
    function New-TamperedPlan {
        param([Parameter(Mandatory)][scriptblock]$Mutate)
        $copy = New-ReviewerReplayQualificationPlan @planArguments
        $slot = @($copy.Slots)[0]
        $slot.Arguments = [string[]](& $Mutate ([string[]]@($slot.Arguments)))
        return $copy
    }
    # The historical defect, reproduced exactly: a slot that omits -RepoPath.
    Assert-QualificationThrows {
        $tampered = New-TamperedPlan -Mutate {
            param([string[]]$Arguments)
            $index = [Array]::IndexOf($Arguments, "-RepoPath")
            return @($Arguments | Select-Object -Skip ($index + 2))
        }
        Assert-ReviewerReplayQualificationPlan -Plan $tampered
    } "A slot missing -RepoPath was accepted." "prelaunch did not reach|-RepoPath"
    # The other historical defect: a slot naming a superseded model version.
    Assert-QualificationThrows {
        $tampered = New-TamperedPlan -Mutate {
            param([string[]]$Arguments)
            $index = [Array]::IndexOf($Arguments, "-Model")
            $Arguments[$index + 1] = $retiredOpus
            return $Arguments
        }
        Assert-ReviewerReplayQualificationPlan -Plan $tampered
    } "A slot naming a superseded model was accepted." "prelaunch did not reach|generalist pairing"
    Assert-QualificationThrows {
        $tampered = New-TamperedPlan -Mutate {
            param([string[]]$Arguments)
            return @($Arguments) + @("-EnableFindingComments")
        }
        Assert-ReviewerReplayQualificationPlan -Plan $tampered
    } "A delivery switch survived into a replay qualification command." "offline replay\s+refuses"
    Assert-QualificationThrows {
        $tampered = New-TamperedPlan -Mutate {
            param([string[]]$Arguments)
            $index = [Array]::IndexOf($Arguments, "-PullRequestId")
            $Arguments[$index + 1] = "not-a-pull-request"
            return $Arguments
        }
        Assert-ReviewerReplayQualificationPlan -Plan $tampered
    } "A malformed -PullRequestId bound successfully." "."
    Assert-QualificationThrows {
        $tampered = New-TamperedPlan -Mutate {
            param([string[]]$Arguments)
            $index = [Array]::IndexOf($Arguments, "-ReplaySnapshotName")
            $Arguments[$index + 1] = "a snapshot name with spaces"
            return $Arguments
        }
        Assert-ReviewerReplayQualificationPlan -Plan $tampered
    } "A snapshot name the agent's own validation refuses bound successfully." "."

    # -- 6. Unsupported and missing inputs fail before anything is declared ---
    Write-Host "6/11 refusals before declaration" -ForegroundColor Cyan
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["RepoPath"] = Join-Path $sandbox "no-such-repository"
        New-ReviewerReplayQualificationPlan @bad
    } "A missing -RepoPath directory was accepted." "does not exist"
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["RepoPath"] = "relative\path"
        New-ReviewerReplayQualificationPlan @bad
    } "A relative -RepoPath was accepted." "is relative"
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["ReplayManifestDigest"] = "b" * 64
        New-ReviewerReplayQualificationPlan @bad
    } "A snapshot digest the operator did not vouch for was accepted." "does not match"
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["PullRequestId"] = $snapshotPrId + 1
        New-ReviewerReplayQualificationPlan @bad
    } "A pull request the snapshot was not captured for was accepted." "records pull request"
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["ExpectedCommit"] = "f" * 40
        New-ReviewerReplayQualificationPlan @bad
    } "A reviewer build other than the expected commit was accepted." "does not match expected commit"
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["ConventionSpecialistModel"] = $pair.First
        New-ReviewerReplayQualificationPlan @bad
    } "A specialist model equal to a generalist was accepted." "must differ"
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["ConventionSpecialistModel"] = "claude-opus-9.9"
        New-ReviewerReplayQualificationPlan @bad
    } "An unsupported specialist model was accepted." "unsupported model id"
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["QualificationRoot"] = Join-Path $toolkitCopy "qualification-output"
        New-ReviewerReplayQualificationPlan @bad
    } "A qualification root inside the reviewer build under qualification was accepted." "resolves inside"
    $mismatchedConfigPath = Join-Path $configDir "mismatched.config.json"
    $mismatchedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $mismatchedConfig.repository.project = "SomeOtherProject"
    Set-Content -LiteralPath $mismatchedConfigPath `
        -Value (ConvertTo-Json -InputObject $mismatchedConfig -Depth 20) -Encoding utf8NoBOM
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["ConfigFile"] = $mismatchedConfigPath
        New-ReviewerReplayQualificationPlan @bad
    } "A snapshot captured for another repository was accepted." "cannot be replayed under this configuration"
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["ConfigFile"] = Join-Path $configDir "absent.config.json"
        New-ReviewerReplayQualificationPlan @bad
    } "A missing config was accepted." "does not exist"

    # A snapshot that binds perfectly and still cannot answer the read the run
    # opens with. The committed synthetic fixture records its reads under the
    # repository GUID, while the agent asks with the configured repository NAME,
    # so a config that names the repository any other way is refused BEFORE the
    # run set is declared instead of dying in every slot afterwards.
    $committedManifest = Get-Content -LiteralPath (Join-Path $committedReplayRoot "synthetic-pr\manifest.json") -Raw |
        ConvertFrom-Json
    $identityConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $identityConfig.repository.organization = [string]$committedManifest.binding.organization
    $identityConfig.repository.project = [string]$committedManifest.binding.project
    $identityConfig.repository.id = [string]$committedManifest.binding.repositoryId
    $identityConfigPath = Join-Path $configDir "identity-mismatch.config.json"
    Set-Content -LiteralPath $identityConfigPath `
        -Value (ConvertTo-Json -InputObject $identityConfig -Depth 20) -Encoding utf8NoBOM
    $identityArguments = $planArguments.Clone()
    $identityArguments["ConfigFile"] = $identityConfigPath
    $identityArguments["ReplayRoot"] = $committedReplayRoot
    $identityArguments["ReplaySnapshotName"] = "synthetic-pr"
    $identityArguments["ReplayManifestDigest"] = [string]$committedManifest.manifestDigest
    $identityArguments["PullRequestId"] = [int]$committedManifest.binding.pullRequestId
    # It plans: every binding the plan checks agrees. Only running the agent's
    # own first read finds the mismatch, which is why the preflight does that.
    $identityPlan = New-ReviewerReplayQualificationPlan @identityArguments
    Assert-Qualification ($identityPlan.Snapshot.ManifestDigest -ceq ([string]$committedManifest.manifestDigest).ToLowerInvariant()) `
        "A snapshot whose recorded reads use another repository identity failed to plan for an unrelated reason."
    Assert-QualificationThrows {
        Assert-ReviewerReplayQualificationPlan -Plan $identityPlan
    } "A snapshot that cannot answer the run's first read was accepted." "no recorded response|records no response"
    Assert-Qualification (-not (Test-Path -LiteralPath (Join-Path $qualificationRoot "runset"))) `
        "A snapshot/config request-contract mismatch still reached a declaration."

    # -- 7. Preflight writes only the report an operator asks for -------------
    Write-Host "7/11 preflight mode" -ForegroundColor Cyan
    $reportPath = Join-Path $sandbox "preflight-report.json"
    $report = & $sandboxTool -Mode Preflight @planArguments -PreflightReportPath $reportPath
    Assert-Qualification (Test-Path -LiteralPath $reportPath -PathType Leaf) `
        "The preflight report was not written where it was asked for."
    Assert-Qualification (-not (Test-Path -LiteralPath $qualificationRoot)) `
        "Preflight created state; looking at a plan must not be a side effect."
    $reportObject = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    Assert-Qualification (@($reportObject.slots).Count -eq 2 -and
        @($reportObject.slots[0].arguments) -ccontains "-RepoPath" -and
        @($reportObject.slots[1].arguments) -ccontains "-RepoPath") `
        "The preflight report does not show -RepoPath on both slot commands."
    Assert-Qualification ([string]$reportObject.models.First -ceq $pair.First -and
        [string]$reportObject.models.Second -ceq $pair.Second) `
        "The preflight report does not name the derived generalist pairing."
    Assert-Qualification (@($report).Count -ge 1) "Preflight returned no report object to its caller."
    $planDigest = Get-ReviewerQualificationPlanDigest -Plan $plan
    Assert-Qualification ($planDigest -cmatch '^[0-9a-f]{64}\z' -and
        [string]$reportObject.planDigest -ceq $planDigest) `
        "The preflight report does not carry the canonical digest of this plan."
    # Same plan, same digest; one argument different, different digest.
    Assert-Qualification ((Get-ReviewerQualificationPlanDigest -Plan (New-ReviewerReplayQualificationPlan @planArguments)) -ceq $planDigest) `
        "The plan digest is not stable across two constructions of the same plan."
    $variantArguments = $planArguments.Clone()
    $variantArguments["CycleTimeoutSeconds"] = 1500
    $variantPlan = New-ReviewerReplayQualificationPlan @variantArguments
    $variantDigest = Get-ReviewerQualificationPlanDigest -Plan $variantPlan
    Assert-Qualification ($variantDigest -cne $planDigest) `
        "A plan whose slot argv differs hashes to the same digest."
    $argvTampered = New-ReviewerReplayQualificationPlan @planArguments
    @($argvTampered.Slots)[0].Arguments = [string[]](@(@($argvTampered.Slots)[0].Arguments) + @("-IncludeOwnPullRequests"))
    Assert-Qualification ((Get-ReviewerQualificationPlanDigest -Plan $argvTampered) -cne $planDigest) `
        "The plan digest does not cover the exact per-slot argument vector."

    # -- 8. Declaration happens only after a passing preflight ---------------
    Write-Host "8/11 declaration ordering and plan binding" -ForegroundColor Cyan
    $keyBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($keyBytes)
    $keyPath = Join-Path $sandbox "runset-signing.key"
    Set-Content -LiteralPath $keyPath -Value ("raw:" + [Convert]::ToBase64String($keyBytes)) -Encoding utf8NoBOM

    # A dirty reviewer build must stop the wrapper before the declaration is
    # ever reached - the spoiled-set failure mode, in the order it matters.
    $dirtyMarker = Join-Path $toolkitCopy "dirty.txt"
    Set-Content -LiteralPath $dirtyMarker -Value "dirty" -Encoding utf8NoBOM
    Assert-QualificationThrows {
        & $sandboxTool -Mode Declare @planArguments -RunSetKeyPath $keyPath -Purpose "must not be declared"
    } "A dirty reviewer build still reached the run-set declaration." "dirty"
    Assert-Qualification (-not (Test-Path -LiteralPath (Join-Path $qualificationRoot "runset"))) `
        "A refused preflight still created a run-set directory."
    Remove-Item -LiteralPath $dirtyMarker -Force

    $declaredPath = & $sandboxTool -Mode Declare @planArguments -RunSetKeyPath $keyPath `
        -Purpose "qualification wrapper self-check"
    $declaredPath = [string](@($declaredPath | Where-Object { $_ -is [string] } | Select-Object -Last 1))
    Assert-Qualification ($declaredPath -and (Test-Path -LiteralPath $declaredPath -PathType Leaf)) `
        "A passing preflight did not produce a sealed run-set declaration."
    $declarationEnvelope = Get-Content -LiteralPath $declaredPath -Raw | ConvertFrom-Json
    $declaration = [string]$declarationEnvelope.manifestJson | ConvertFrom-Json
    Assert-Qualification ([string]$declaration.snapshotName -ceq $snapshotName -and
        [string]$declaration.snapshotManifestDigest -ceq $digest.ToLowerInvariant() -and
        [int]$declaration.plannedRunCount -eq 2 -and -not [bool]$declaration.promotable) `
        "The declaration does not pin the preflighted snapshot, digest and run count as non-promotable."
    Assert-QualificationThrows {
        & $sandboxTool -Mode Declare @planArguments -RunSetKeyPath $keyPath -Purpose "second set"
    } "A second run set was declared into a root that already had one." "already declared"

    Assert-Qualification ([string]$declaration.planDigest -ceq $planDigest) `
        "The declaration is not sealed under the digest of the plan it was preflighted from."
    # The declaration verifies under its key, through the tool that seals it.
    $verifiedJson = & (Join-Path $toolkitCopy "tools\Compare-ReviewerReplayRuns.ps1") -VerifyRunSet `
        -RunSetPath $declaredPath -KeyPath $keyPath
    $verified = [string](@($verifiedJson | Where-Object { $_ -is [string] } | Select-Object -Last 1)) | ConvertFrom-Json
    Assert-Qualification ([string]$verified.planDigest -ceq $planDigest -and
        [string]$verified.snapshotName -ceq $snapshotName) `
        "Verifying the sealed declaration did not return the plan it was sealed for."
    $otherKeyPath = Join-Path $sandbox "other-signing.key"
    $otherKeyBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($otherKeyBytes)
    Set-Content -LiteralPath $otherKeyPath -Value ("raw:" + [Convert]::ToBase64String($otherKeyBytes)) -Encoding utf8NoBOM
    Assert-QualificationThrows {
        & (Join-Path $toolkitCopy "tools\Compare-ReviewerReplayRuns.ps1") -VerifyRunSet `
            -RunSetPath $declaredPath -KeyPath $otherKeyPath
    } "A declaration verified under a key it was not sealed with." "signature verification failed"

    # -- 9. Slot execution refuses what it must, without launching a model ---
    Write-Host "9/11 slot execution guards" -ForegroundColor Cyan
    Assert-QualificationThrows {
        & $sandboxTool -Mode RunSlot @planArguments -Slot "slot3" -RunSetKeyPath $keyPath
    } "A slot outside the declared plan was accepted." "not part of this"
    Assert-QualificationThrows {
        & $sandboxTool -Mode RunSlot @planArguments -Slot "slot1"
    } "A slot ran without the key that verifies its declaration." "requires -RunSetKeyPath"
    Assert-QualificationThrows {
        & $sandboxTool -Mode RunSlot @planArguments -Slot "slot1" -RunSetKeyPath $otherKeyPath
    } "A slot ran against a declaration that did not verify under the supplied key." "signature verification failed"
    # Same snapshot, same run count, different plan: the digest is what refuses.
    Assert-QualificationThrows {
        & $sandboxTool -Mode RunSlot @variantArguments -Slot "slot1" -RunSetKeyPath $keyPath
    } "A slot ran a plan the declaration was not sealed for." "was made for plan"
    # Any state at all, even an empty directory somebody created by hand.
    $occupied = Join-Path (Join-Path $qualificationRoot "runs") "slot1-state"
    New-Item -ItemType Directory -Force -Path $occupied | Out-Null
    Assert-QualificationThrows {
        & $sandboxTool -Mode RunSlot @planArguments -Slot "slot1" -RunSetKeyPath $keyPath
    } "An already-attempted slot was re-run into its own state directory." "already exists"
    Remove-Item -LiteralPath $occupied -Recurse -Force
    # A declaration for another snapshot, unsigned, must not be usable at all.
    $foreignRoot = Join-Path $sandbox "foreign-root"
    New-Item -ItemType Directory -Force -Path (Join-Path $foreignRoot "runset") | Out-Null
    $foreignDeclaration = [pscustomobject][ordered]@{
        kind = "reviewer.run-reconciliation-set"
        snapshotName = "some-other-snapshot"
        snapshotManifestDigest = ("c" * 64)
        plannedRunCount = 2
    }
    Set-Content -LiteralPath (Join-Path $foreignRoot "runset\runset-foreign.json") `
        -Value (ConvertTo-Json -InputObject $foreignDeclaration -Depth 6) -Encoding utf8NoBOM
    Assert-QualificationThrows {
        $bad = $planArguments.Clone()
        $bad["QualificationRoot"] = $foreignRoot
        & $sandboxTool -Mode RunSlot @bad -Slot "slot1" -RunSetKeyPath $keyPath
    } "A slot ran against an unsigned declaration." "signature verification failed"

    # -- 10. A slot's one attempt is consumed before its child starts --------
    Write-Host "10/11 attempt immutability" -ForegroundColor Cyan
    $attemptRoot = Join-Path $sandbox "attempt-root"
    $attemptArguments = $planArguments.Clone()
    $attemptArguments["QualificationRoot"] = $attemptRoot
    $attemptArguments["ReviewerScriptPath"] = $failingAgent
    $attemptDeclared = & $sandboxTool -Mode Declare @attemptArguments -RunSetKeyPath $keyPath `
        -Purpose "startup failure before any agent state"
    Assert-Qualification (@($attemptDeclared | Where-Object { $_ -is [string] }).Count -ge 1) `
        "The stand-in plan did not declare a run set."
    $attemptExit = 0
    try {
        & $sandboxTool -Mode RunSlot @attemptArguments -Slot "slot1" -RunSetKeyPath $keyPath 2>&1 | Out-Null
        $attemptExit = $LASTEXITCODE
    }
    catch { $attemptExit = 9 }
    $attemptMarker = Join-Path (Join-Path $attemptRoot "runs") "slot1-attempt.json"
    Assert-Qualification ($attemptExit -ne 0) "A failing slot startup reported success."
    Assert-Qualification (Test-Path -LiteralPath $attemptMarker -PathType Leaf) `
        "A slot whose child failed at startup left no record that its attempt was spent."
    Assert-Qualification (-not (Test-Path -LiteralPath (Join-Path (Join-Path $attemptRoot "runs") "slot1-state"))) `
        "A slot whose child failed at startup still created agent state."
    Assert-Qualification ((Get-Item -LiteralPath $attemptMarker).IsReadOnly) `
        "The attempt marker is writable; an attempt record that can be edited records nothing."
    $attemptRecord = Get-Content -LiteralPath $attemptMarker -Raw | ConvertFrom-Json
    Assert-Qualification ([string]$attemptRecord.slot -ceq "slot1" -and
        [string]$attemptRecord.planDigest -ceq (Get-ReviewerQualificationPlanDigest -Plan (New-ReviewerReplayQualificationPlan @attemptArguments)) -and
        @($attemptRecord.arguments) -ccontains "-RepoPath") `
        "The attempt marker does not record the exact plan and command it consumed."
    # And the spent attempt is what refuses the retry - not the missing state.
    Assert-QualificationThrows {
        & $sandboxTool -Mode RunSlot @attemptArguments -Slot "slot1" -RunSetKeyPath $keyPath
    } "A slot whose child failed to start was allowed a second attempt." "already been attempted"

    # -- 11. Nothing here ever reached a model or a network call -------------
    Write-Host "11/11 offline discipline" -ForegroundColor Cyan
    $libraryText = Get-Content -LiteralPath (Join-Path $RepoRoot "src\Agents\reviewer\ReplayQualification.ps1") -Raw
    foreach ($forbiddenCall in @("Invoke-RestMethod", "Invoke-WebRequest", "System.Net.Http")) {
        Assert-Qualification ($libraryText -notmatch [regex]::Escape($forbiddenCall)) `
            "The qualification library reaches for $forbiddenCall."
    }
    Assert-Qualification ($libraryText -match "QualificationPrelaunch") `
        "The qualification library no longer validates through the agent's prelaunch mode."
}
finally {
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures.Count -gt 0) {
    Write-Host "FAIL - $($script:Failures.Count) of $($script:Checks) qualification wrapper check(s) failed." -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Reviewer replay qualification checks passed ($script:Checks checks)." -ForegroundColor Green
