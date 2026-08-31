#Requires -Version 7.0

<#
.SYNOPSIS
    Proves that a reviewer run is audited against an execution identity minted
    OUTSIDE it, so a whole self-consistent evidence set replayed into a re-used
    run root can no longer pass as this run's accounting (finding F18, strong
    form).

.DESCRIPTION
    The census can refuse an evidence set that does not name an expected
    execution - that part already has tests. What it could not do until now is
    LEARN that expectation: the reviewer minted its own run identity inside the
    process being audited, and the only witness available to the auditing child
    was the records the run itself wrote. An attacker who can put a whole earlier
    generation of evidence back into the directory therefore satisfies every
    check, because everything in that set agrees with everything else.

    This suite proves the three links that close that gap, each against the
    SHIPPING code rather than a copy of it:

      1. The child adapter mints an expectation, reports it to the coordinator,
         and refuses - rather than silently weakening - when the copy it left for
         its own verify step has been removed, corrupted, or REWRITTEN to name a
         different execution than the coordinator committed.
      2. The reviewer adopts an execution identity handed to it by its launcher,
         and refuses to run at all under a malformed one.
      3. The census, given that expectation, refuses a self-consistent evidence
         set produced by a different execution in the same directory.

    No model is started and no reviewer run is performed: the adapter functions
    are lifted out by name, and the reviewer's adoption block is executed as the
    exact source text that ships in Start-ReviewerAgent.ps1.

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
$reviewerScript = Join-Path $RepoRoot 'src/Agents/reviewer/Start-ReviewerAgent.ps1'
foreach ($required in @($childScript, $reviewerScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "'$required' does not exist." }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('run-execution-nonce-' + [Guid]::NewGuid().ToString('n'))
[void](New-Item -ItemType Directory -Path $scratch -Force)
$utf8 = [Text.UTF8Encoding]::new($false)

$checks = 0
$failures = [Collections.Generic.List[string]]::new()
function Assert-Nonce {
    param([Parameter(Mandatory)][AllowNull()]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) {
        [void]$script:failures.Add($Message)
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
    else { Write-Host "  PASS  $Message" }
}

function Get-ThrownMessage {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try { & $Action | Out-Null }
    catch { return [string]$_.Exception.Message }
    return ''
}

function New-TestExecutionId {
    <#
    .SYNOPSIS
        One 32-hex identity, shaped exactly as the coordinator mints them.
    .DESCRIPTION
        The coordinator is the only thing that mints these now, so this suite has
        to stand in for it when it drives the adapter's helpers directly. Random
        for the same reason the coordinator's is: two of these must never collide,
        or a substitution check could pass by accident.
    #>
    return [string]([Convert]::ToHexString(
            [Security.Cryptography.RandomNumberGenerator]::GetBytes(16))).ToLowerInvariant()
}

# The adapter's own functions, lifted by name. This is the SAME code the child
# runs; a copy would only prove that the copy behaves.
$parseErrors = $null
$childAst = [Management.Automation.Language.Parser]::ParseFile($childScript, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "The child script did not parse: $($parseErrors -join '; ')" }
$wanted = @('Get-ShadowChildRunExecutionNoncePath', 'Write-ShadowChildRunExecutionExpectation',
    'Read-ShadowChildRunExecutionExpectation', 'Get-ShadowChildField',
    'Read-ShadowChildSigningMasterKey', 'Get-ShadowChildCensusMasterKey',
    'Invoke-ShadowChildSlotRun')
$found = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($definition in $childAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -ccontains [string]$definition.Name) {
        . ([scriptblock]::Create($definition.Extent.Text))
        [void]$found.Add([string]$definition.Name)
    }
}

try {
    Write-Host 'Run-execution expectation'
    foreach ($name in $wanted) {
        Assert-Nonce ($found.Contains($name)) "the child adapter exposes $name"
    }

    # --- 1. WHERE THE EXPECTATION LIVES, AND WHAT DECIDES IT. ---
    # The file lives in the coordinator's own exchange directory - the one this
    # adapter's request arrived in - rather than under the qualification tree the
    # reviewed run is handed a path into. That is worth doing and it is NOT
    # sufficient, which is what section 2b is about: the exchange root is a fixed
    # sibling of the qualification root, so a run that wants to escape the strong
    # witness can compute this path without ever being given it. The identity of
    # record therefore travels through the coordinator's signed state, and this
    # file only has to agree with it.
    $custodyRoot = Join-Path $scratch 'exchange'
    $qualificationRoot = Join-Path $scratch 'qualification'
    $runDirectory = Join-Path $qualificationRoot 'runs'
    $reviewerRunRoot = Join-Path $scratch 'state/replay/snapshot-a'
    [void](New-Item -ItemType Directory -Force -Path $custodyRoot)
    [void](New-Item -ItemType Directory -Force -Path $runDirectory)
    [void](New-Item -ItemType Directory -Force -Path $reviewerRunRoot)
    $noncePath = Get-ShadowChildRunExecutionNoncePath -CustodyRoot $custodyRoot -SetId 'set-a' -SlotName 'slot1'
    Assert-Nonce ($noncePath.StartsWith((Join-Path $custodyRoot 'run-execution'), [StringComparison]::Ordinal)) `
        "the expectation is kept under the coordinator's exchange directory: $noncePath"
    Assert-Nonce (-not $noncePath.StartsWith($reviewerRunRoot, [StringComparison]::OrdinalIgnoreCase)) `
        'the expectation is kept outside the reviewer run root the audited run writes'
    Assert-Nonce (-not $noncePath.StartsWith($qualificationRoot, [StringComparison]::OrdinalIgnoreCase)) `
        'the expectation is kept outside the qualification tree the reviewed run is handed a path into'

    # A path is built from the set and the slot, and from nothing else: a name
    # that is not a plain identifier is refused rather than resolved into a path
    # of its choosing. Both components, because either one would do.
    $traversal = Get-ThrownMessage {
        Get-ShadowChildRunExecutionNoncePath -CustodyRoot $custodyRoot -SetId '..\..\elsewhere' -SlotName 'slot1'
    }
    Assert-Nonce ($traversal -match 'plain identifier') `
        "a set identity carrying path separators is refused rather than resolved: '$traversal'"
    $slotTraversal = Get-ThrownMessage {
        Get-ShadowChildRunExecutionNoncePath -CustodyRoot $custodyRoot -SetId 'set-a' -SlotName '..\..\elsewhere'
    }
    Assert-Nonce ($slotTraversal -match 'plain identifier') `
        "a slot name carrying path separators is refused rather than resolved: '$slotTraversal'"

    # Set and slot are separate path segments. Hyphen-joined into one stem, set
    # 'a' slot 'b-slot1' and set 'a-b' slot 'slot1' name the same file, and an
    # encoding two identities collide in is not an identity.
    $collideLeft = Get-ShadowChildRunExecutionNoncePath -CustodyRoot $custodyRoot -SetId 'a' -SlotName 'b-slot1'
    $collideRight = Get-ShadowChildRunExecutionNoncePath -CustodyRoot $custodyRoot -SetId 'a-b' -SlotName 'slot1'
    Assert-Nonce ($collideLeft -cne $collideRight) `
        "two different set/slot pairs encode to two different paths: '$collideLeft' vs '$collideRight'"

    # The coordinator mints the identity; these stand in for it. Every write below
    # is handed one, because the adapter no longer has a way to invent its own.
    $minted = New-TestExecutionId
    $secondMint = New-TestExecutionId
    $otherSet = New-TestExecutionId

    # The census key has a second, external authority too. The reviewer receives
    # only a per-slot derivation through its launch environment; the verifier
    # derives the same bytes from the run-set key without trusting the run root.
    $runSetKeyPath = Join-Path $scratch 'runset-signing.key'
    $runSetMasterKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    [IO.File]::WriteAllText(
        $runSetKeyPath,
        ('raw:' + [Convert]::ToBase64String($runSetMasterKey)),
        [Text.Encoding]::ASCII)
    [byte[]]$derivedCensusKey = @(Get-ShadowChildCensusMasterKey -Path $runSetKeyPath -SetId 'set-a' `
            -SlotName 'slot1' -RunExecutionId $minted)
    [byte[]]$otherExecutionKey = @(Get-ShadowChildCensusMasterKey -Path $runSetKeyPath -SetId 'set-a' `
            -SlotName 'slot1' -RunExecutionId $secondMint)
    Assert-Nonce (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $derivedCensusKey, $otherExecutionKey)) `
        'a different execution identity derives a different census key'
    [byte[]]$otherSlotKey = @(Get-ShadowChildCensusMasterKey -Path $runSetKeyPath -SetId 'set-a' `
            -SlotName 'slot2' -RunExecutionId $minted)
    Assert-Nonce (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $derivedCensusKey, $otherSlotKey)) `
        'a different slot derives a different census key'

    # Execute the SHIPPING slot-run function, with only the reviewed tool behind
    # it replaced by a stand-in. This catches production wiring failures that a
    # source regex cannot: the context owns RunSetKeyPath (the plan deliberately
    # does not), the slot state directory must remain absent until the tool runs,
    # and both launcher-owned values must reach that process and be restored.
    $standInToolkit = Join-Path $scratch 'stand-in-toolkit'
    $standInModule = Join-Path $standInToolkit 'src/DevPilot.AgentHarness'
    $standInReviewer = Join-Path $standInToolkit 'src/Agents/reviewer'
    $standInTools = Join-Path $standInToolkit 'tools'
    foreach ($directory in @($standInModule, $standInReviewer, $standInTools)) {
        [void](New-Item -ItemType Directory -Force -Path $directory)
    }
    [IO.File]::WriteAllText(
        (Join-Path $standInModule 'DevPilot.AgentHarness.psd1'),
        "@{ RootModule = 'DevPilot.AgentHarness.psm1'; ModuleVersion = '1.0.0'; GUID = 'ebcb1713-45bd-4384-8680-5248e1f31380' }",
        $utf8)
    [IO.File]::WriteAllText((Join-Path $standInModule 'DevPilot.AgentHarness.psm1'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $standInReviewer 'QualificationPreflight.ps1'), '', $utf8)
    [IO.File]::WriteAllText(
        (Join-Path $standInReviewer 'ReplayQualification.ps1'),
        @'
function Resolve-ReviewerQualificationSlotTerminalPath {
    param([string]$RunDirectory, [string]$SlotName)
    return (Join-Path $RunDirectory "$SlotName-terminal.json")
}
'@,
        $utf8)
    $slotCapturePath = Join-Path $scratch 'slot-launch-capture.json'
    [IO.File]::WriteAllText(
        (Join-Path $standInTools 'Invoke-ReviewerReplayQualification.ps1'),
        @'
param(
    [string]$Mode, [string]$Slot, [string]$RepoPath, [string]$ConfigFile,
    [string]$OperatorAlias, [int]$PullRequestId, [string]$ReplayRoot,
    [string]$ReplaySnapshotName, [string]$ReplayManifestDigest,
    [string]$QualificationRoot, [string]$ExpectedCommit, [string]$RequiredRef,
    [string]$ReviewerScriptPath, [int]$SlotCount, [string]$RunSetKeyPath,
    [string]$LaunchAuthorizationTokenPath
)
$stateDir = Join-Path (Join-Path $QualificationRoot 'runs') "$Slot-state"
$capture = [ordered]@{
    stateDirExistedAtEntry = [bool](Test-Path -LiteralPath $stateDir)
    executionId = [string]$env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID
    censusMasterKey = [string]$env:DEVPILOT_REVIEWER_CENSUS_MASTER_KEY
}
[IO.File]::WriteAllText(
    [string]$env:DEVPILOT_TEST_SLOT_CAPTURE,
    (ConvertTo-Json -InputObject $capture -Depth 4 -Compress),
    [Text.UTF8Encoding]::new($false))
$runDirectory = Join-Path $QualificationRoot 'runs'
[void](New-Item -ItemType Directory -Force -Path $runDirectory)
[IO.File]::WriteAllText(
    (Join-Path $runDirectory "$Slot-terminal.json"),
    '{}',
    [Text.UTF8Encoding]::new($false))
'@,
        $utf8)
    $integrationQualificationRoot = Join-Path $scratch 'integration-qualification'
    $integrationStateDir = Join-Path (Join-Path $integrationQualificationRoot 'runs') 'slot1-state'
    $integrationPlan = [pscustomobject]@{
        RunDirectory = (Join-Path $integrationQualificationRoot 'runs')
        Snapshot = [pscustomobject]@{ Name = 'snapshot-a' }
    }
    $integrationTarget = [pscustomobject]@{
        Name = 'slot1'
        StateDir = $integrationStateDir
        TerminalPath = (Join-Path $integrationPlan.RunDirectory 'slot1-terminal.json')
        Arguments = @()
    }
    $script:NonceIntegrationContext = @{
        Plan = $integrationPlan
        PlanDigest = ('c' * 64)
        Target = $integrationTarget
        SetId = 'set-a'
        RunSetKeyPath = $runSetKeyPath
        ReviewerScriptPath = (Join-Path $standInReviewer 'Start-ReviewerAgent.ps1')
        AttemptPath = (Join-Path $scratch 'slot1-attempt.json')
        LaunchTokenPath = (Join-Path $scratch 'launch-token.txt')
    }
    function Get-ShadowChildSlotContext { return $script:NonceIntegrationContext }
    $integrationRequest = [pscustomobject]@{
        runExecutionId = $minted
        reviewerRepositoryPath = $RepoRoot
        reviewerConfigPath = (Join-Path $RepoRoot 'samples/reviewer-ado.config.json')
        operatorAlias = 'test'
        pullRequestId = 1
        replayRoot = $scratch
        snapshotName = 'snapshot-a'
        manifestDigest = ('a' * 64)
        qualificationRoot = $integrationQualificationRoot
        expectedCommit = ('b' * 40)
        requiredRef = 'refs/heads/test'
        plannedRunCount = 1
    }
    $env:DEVPILOT_TEST_SLOT_CAPTURE = $slotCapturePath
    $env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID = 'preserved-execution'
    $env:DEVPILOT_REVIEWER_CENSUS_MASTER_KEY = 'preserved-census'
    try {
        $integrationResult = Invoke-ShadowChildSlotRun -Request $integrationRequest `
            -ToolkitRoot $standInToolkit -CustodyRoot (Join-Path $scratch 'integration-exchange')
    }
    finally {
        $env:DEVPILOT_TEST_SLOT_CAPTURE = $null
    }
    $slotCapture = [IO.File]::ReadAllText($slotCapturePath) | ConvertFrom-Json
    Assert-Nonce (-not [bool]$slotCapture.stateDirExistedAtEntry) `
        'the shipping slot-run function leaves the slot state absent for the reviewed tool to create'
    Assert-Nonce ([string]$slotCapture.executionId -ceq $minted) `
        'the shipping slot-run function passes the coordinator execution identity to the reviewed tool'
    Assert-Nonce ([string]$slotCapture.censusMasterKey -ceq [Convert]::ToBase64String($derivedCensusKey)) `
        'the shipping slot-run function passes the externally derived census key to the reviewed tool'
    Assert-Nonce ([string]$env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID -ceq 'preserved-execution' -and
        [string]$env:DEVPILOT_REVIEWER_CENSUS_MASTER_KEY -ceq 'preserved-census') `
        'the shipping slot-run function restores both launcher environment values'
    Assert-Nonce ([bool]$integrationResult.terminalWritten) `
        'the shipping slot-run function reaches a terminal result with the stand-in reviewed tool'

    # A malformed identity is refused at the write, not carried into evidence.
    $badMint = Get-ThrownMessage {
        Write-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SlotName 'slot1' -SetId 'set-a' `
            -RunExecutionId 'NOT-HEX'
    }
    Assert-Nonce ($badMint -match 'not 32 lowercase hex') `
        "an identity the coordinator could not have minted is refused at the write: '$badMint'"

    [void](Write-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SlotName 'slot1' -SetId 'set-a' `
            -RunExecutionId $minted)
    Assert-Nonce (@(Get-ChildItem -LiteralPath $qualificationRoot -Recurse -Force).Count -eq 1) `
        'writing an expectation wrote nothing at all into the qualification tree'
    [void](Write-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SlotName 'slot2' -SetId 'set-a' `
            -RunExecutionId $secondMint)
    [void](Write-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SlotName 'slot1' -SetId 'set-b' `
            -RunExecutionId $otherSet)
    Assert-Nonce ((Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-a' `
                -SlotName 'slot2' -CommittedRunExecutionId $secondMint) -ceq $secondMint) `
        'two slots under one set keep two separate expectations'
    Assert-Nonce ((Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-b' `
                -SlotName 'slot1' -CommittedRunExecutionId $otherSet) -ceq $otherSet) `
        'two sets sharing one exchange root do not collide onto one slot expectation'

    # --- 2. READING IT BACK. ---
    Assert-Nonce ((Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-a' `
                -SlotName 'slot1' -CommittedRunExecutionId $minted) -ceq $minted) `
        'the verify step reads back exactly the expectation the run step minted'

    # ABSENCE IS A REFUSAL. Every slot this adapter launches is minted an
    # expectation before the reviewed tool starts, so a slot being verified with
    # no expectation is a fact about the expectation and not about the run.
    # Reading it as 'none' would select the weaker record-corroborated witness -
    # which accepts exactly the self-consistent replayed evidence set the
    # expectation exists to catch - and deleting one file would then be the
    # cheapest possible escape from the stronger one.
    $absent = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-a' -SlotName 'slot9' `
            -CommittedRunExecutionId $minted
    }
    Assert-Nonce ($absent -match 'no run-execution expectation') `
        "a slot with no expectation is refused rather than downgraded to the weak witness: '$absent'"
    $deletedPath = Get-ShadowChildRunExecutionNoncePath -CustodyRoot $custodyRoot -SetId 'set-b' -SlotName 'slot1'
    Remove-Item -LiteralPath $deletedPath -Force
    $deleted = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-b' -SlotName 'slot1' `
            -CommittedRunExecutionId $otherSet
    }
    Assert-Nonce ($deleted -match 'no run-execution expectation') `
        "deleting a minted expectation is refused, not read as 'never minted': '$deleted'"
    Assert-Nonce ((Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-b' `
                -SlotName 'slot1' -CommittedRunExecutionId '' -AllowMissing) -ceq '') `
        'only a caller that explicitly asks to audit an unlaunched tree reads absence as none'

    # --- 2b. THE FILE IS NOT THE AUTHORITY. ---
    # Two independent reviews of the previous revision demonstrated the same
    # attack: the exchange root is a fixed sibling of the qualification root under
    # one output root, so the audited run can COMPUTE this path even though it is
    # never handed it, and rewriting the record is strictly stronger than deleting
    # it - a deletion refuses, a rewrite would have re-pointed the whole audit at
    # an execution of the attacker's choosing. The identity of record now arrives
    # from the coordinator's signed state, and these are the checks that say so.
    $verifiedWithoutCommitted = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-a' -SlotName 'slot1' `
            -CommittedRunExecutionId ''
    }
    Assert-Nonce ($verifiedWithoutCommitted -match 'without the run-execution identity the coordinator committed') `
        "a verify step handed no committed identity refuses rather than trusting the copy on disk: '$verifiedWithoutCommitted'"
    foreach ($malformedCommitted in @('NOT-HEX', ($minted.ToUpperInvariant()), ($minted + "`n"))) {
        $refusedCommitted = Get-ThrownMessage {
            Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-a' -SlotName 'slot1' `
                -CommittedRunExecutionId $malformedCommitted
        }
        Assert-Nonce ($refusedCommitted -match 'without the run-execution identity the coordinator committed') `
            "a malformed committed identity is refused rather than compared: '$malformedCommitted'"
    }

    # THE SUBSTITUTION ITSELF. The attacker rewrites the copy on disk with a
    # perfectly well-formed record naming an older, cheaper execution whose whole
    # evidence set is still sitting in the re-used run root. Against the previous
    # revision this succeeded and the verify step went on to demand exactly the
    # execution the attacker chose.
    $substitutionRoot = Join-Path $scratch 'substitution/exchange'
    [void](New-Item -ItemType Directory -Force -Path $substitutionRoot)
    $committed = New-TestExecutionId
    [void](Write-ShadowChildRunExecutionExpectation -CustodyRoot $substitutionRoot -SlotName 'slot1' `
            -SetId 'set-a' -RunExecutionId $committed)
    $substitutionPath = Get-ShadowChildRunExecutionNoncePath -CustodyRoot $substitutionRoot -SetId 'set-a' `
        -SlotName 'slot1'
    $olderExecution = 'b' * 32
    [IO.File]::WriteAllText($substitutionPath, (ConvertTo-Json -InputObject ([ordered]@{
                    kind = 'shadow.child.run-execution.v1'; slot = 'slot1'; setId = 'set-a'
                    runExecutionId = $olderExecution
                }) -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $substituted = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $substitutionRoot -SetId 'set-a' -SlotName 'slot1' `
            -CommittedRunExecutionId $committed
    }
    Assert-Nonce ($substituted -match 'is a rewrite') `
        "a rewritten expectation naming another execution is refused rather than adopted: '$substituted'"
    Assert-Nonce ($substituted -match [regex]::Escape($olderExecution) -and $substituted -match [regex]::Escape($committed)) `
        'the refusal names both the identity on disk and the identity the coordinator committed'

    # And the shipping wiring, asserted against the source text rather than
    # described: the coordinator MINTS the identity and sends it down, the run step
    # echoes it, the coordinator requires that echo to match exactly, and the
    # verify step is handed the committed value.
    $childText = [IO.File]::ReadAllText($childScript)
    Assert-Nonce ($childText -match "Get-ShadowChildField -Request \`$Request -Name 'runExecutionId'") `
        'the shipping run step takes the identity from the request instead of minting one'
    Assert-Nonce ($childText -match '(?m)^\s*\[Parameter\(Mandatory\)\]\[string\]\$RunExecutionId') `
        'the shipping writer cannot be called without an identity the coordinator supplied'
    Assert-Nonce ($childText -match '(?m)^\s*runExecutionId = \[string\]\$runExecutionId') `
        'the shipping run step echoes that identity in its child result'
    Assert-Nonce ($childText -match "Get-ShadowChildField -Request \`$Request -Name 'expectedRunExecutionId'") `
        'the shipping verify step takes the identity of record from the child request'
    Assert-Nonce ($childText -match '-CommittedRunExecutionId \$committedRunExecutionId') `
        'the shipping verify step hands that identity to the reader as the authority'
    Assert-Nonce (([regex]::Matches(
                $childText,
                'Get-ShadowChildCensusMasterKey -Path \(\[string\]\$context\.RunSetKeyPath\)')).Count -eq 2 -and
        $childText -notmatch '\$plan\.RunSetKeyPath') `
        'the shipping run and verify steps derive from the key path held by the slot context'
    Assert-Nonce ($childText -match 'DEVPILOT_REVIEWER_CENSUS_MASTER_KEY = \[Convert\]::ToBase64String\(\$censusMasterKey\)') `
        'the shipping run step passes the derived census key only through the reviewed launch environment'
    Assert-Nonce (([regex]::Matches($childText, '-MasterKey \$censusMasterKey')).Count -eq 2) `
        'both shipping census verifiers receive the independently derived master key'
    $machinePath = Join-Path $RepoRoot 'tools/ShadowRunCoordinator/PreparationMachine.cs'
    $machineText = [IO.File]::ReadAllText($machinePath)
    Assert-Nonce ($machineText -match 'Convert\.ToHexString\(RandomNumberGenerator\.GetBytes\(16\)\)') `
        'the coordinator mints the run-execution identity itself'
    Assert-Nonce ($machineText -match 'childRequest\.Set\("runExecutionId", runExecutionId\)') `
        'the coordinator sends the minted identity down to the run step'
    Assert-Nonce ($machineText -match '\.Set\("runExecutionId", runExecutionId\)') `
        'the coordinator commits the run-execution identity with the launch it authorized'
    Assert-Nonce ($machineText -match 'RequireLiteral\(outcome\.Result, "runExecutionId", runExecutionId, label\)') `
        'the coordinator requires the run result to echo exactly the identity it minted'
    Assert-Nonce ($machineText -notmatch 'RequireHex\(outcome\.Result, "runExecutionId"') `
        'the coordinator no longer accepts any well-formed identity the child chose'
    Assert-Nonce ($machineText -match '\.Set\("expectedRunExecutionId", observedRunExecutionId\)') `
        'the coordinator hands the committed identity back to the verify step'

    # A slot that somehow reached the write twice must fail rather than replace
    # the expectation the first attempt is already being audited against.
    [string]$reMint = Get-ThrownMessage {
        Write-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SlotName 'slot1' -SetId 'set-a' `
            -RunExecutionId (New-TestExecutionId)
    }
    Assert-Nonce ($reMint.Length -gt 0) 'writing a second expectation for the same slot is refused'
    Assert-Nonce ((Read-ShadowChildRunExecutionExpectation -CustodyRoot $custodyRoot -SetId 'set-a' `
                -SlotName 'slot1' -CommittedRunExecutionId $minted) -ceq $minted) `
        'the refused second mint left the original expectation intact'

    # --- 3. TAMPERING WITH THE EXPECTATION IS A REFUSAL, NEVER A DOWNGRADE. ---
    # This is the whole attack surface the file introduces: if corrupting it fell
    # back to "no expectation", deleting one byte would be the cheapest way to
    # escape the stronger witness entirely.
    $tamperRoot = Join-Path $scratch 'tamper/exchange'
    [void](New-Item -ItemType Directory -Force -Path $tamperRoot)
    [void](Write-ShadowChildRunExecutionExpectation -CustodyRoot $tamperRoot -SlotName 'slot1' -SetId 'set-a' `
            -RunExecutionId (New-TestExecutionId))
    $tamperPath = Get-ShadowChildRunExecutionNoncePath -CustodyRoot $tamperRoot -SetId 'set-a' -SlotName 'slot1'
    [IO.File]::WriteAllText($tamperPath, '{ this is not json', [Text.UTF8Encoding]::new($false))
    $unreadable = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $tamperRoot -SetId 'set-a' -SlotName 'slot1' `
            -CommittedRunExecutionId ('a' * 32)
    }
    Assert-Nonce ($unreadable -match 'could not be read') `
        "an unreadable expectation is refused rather than treated as absent: '$unreadable'"

    [IO.File]::WriteAllText($tamperPath, (ConvertTo-Json -InputObject ([ordered]@{
                    kind = 'shadow.child.run-execution.v1'; slot = 'slot7'; setId = 'set-a'
                    runExecutionId = ('a' * 32)
                }) -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $wrongSlot = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $tamperRoot -SetId 'set-a' -SlotName 'slot1' `
            -CommittedRunExecutionId ('a' * 32)
    }
    Assert-Nonce ($wrongSlot -match "names slot 'slot7'") `
        "an expectation minted for another slot is refused: '$wrongSlot'"

    [IO.File]::WriteAllText($tamperPath, (ConvertTo-Json -InputObject ([ordered]@{
                    kind = 'shadow.child.run-execution.v1'; slot = 'slot1'; setId = 'set-z'
                    runExecutionId = ('a' * 32)
                }) -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $wrongSet = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $tamperRoot -SetId 'set-a' -SlotName 'slot1' `
            -CommittedRunExecutionId ('a' * 32)
    }
    Assert-Nonce ($wrongSet -match "names set 'set-z'") `
        "an expectation minted for another run set is refused: '$wrongSet'"

    [IO.File]::WriteAllText($tamperPath, (ConvertTo-Json -InputObject ([ordered]@{
                    kind = 'shadow.child.run-execution.v1'; slot = 'slot1'; setId = 'set-a'
                    runExecutionId = ''
                }) -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $blankId = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $tamperRoot -SetId 'set-a' -SlotName 'slot1' `
            -CommittedRunExecutionId ('a' * 32)
    }
    Assert-Nonce ($blankId -match '32-hex') `
        "an expectation emptied of its identity is refused rather than read as absent: '$blankId'"

    # .NET's '$' matches before a trailing newline, so an identity with one
    # appended would pass a '$'-anchored shape check and then fail every ordinal
    # comparison downstream - a false alarm on the one value the whole audit is
    # anchored to. Anchored with \z instead, which is what this proves.
    [IO.File]::WriteAllText($tamperPath, (ConvertTo-Json -InputObject ([ordered]@{
                    kind = 'shadow.child.run-execution.v1'; slot = 'slot1'; setId = 'set-a'
                    runExecutionId = (('a' * 32) + "`n")
                }) -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $trailingNewline = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $tamperRoot -SetId 'set-a' -SlotName 'slot1' `
            -CommittedRunExecutionId ('a' * 32)
    }
    Assert-Nonce ($trailingNewline -match '32-hex') `
        "an identity with a trailing newline is refused rather than read as 32 hex: '$trailingNewline'"

    [IO.File]::WriteAllText($tamperPath, (ConvertTo-Json -InputObject ([ordered]@{
                    kind = 'shadow.child.run-execution.v1'; slot = 'slot1'
                }) -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $notARecord = Get-ThrownMessage {
        Read-ShadowChildRunExecutionExpectation -CustodyRoot $tamperRoot -SetId 'set-a' -SlotName 'slot1' `
            -CommittedRunExecutionId ('a' * 32)
    }
    Assert-Nonce ($notARecord -match 'not a run-execution record') `
        "a file that is valid JSON but not an expectation is refused: '$notARecord'"

    # --- 4. THE REVIEWER ADOPTS WHAT ITS LAUNCHER NAMED. ---
    # The adoption block is executed as the exact source text that ships, located
    # by the assignment it opens with, so this cannot drift away from the
    # reviewer without the extraction failing outright.
    $reviewerText = [IO.File]::ReadAllText($reviewerScript)
    $reviewerParseErrors = $null
    $reviewerAst = [Management.Automation.Language.Parser]::ParseFile(
        $reviewerScript, [ref]$null, [ref]$reviewerParseErrors)
    if ($reviewerParseErrors) { throw "The reviewer script did not parse: $($reviewerParseErrors -join '; ')" }
    $launcherKeyDefinition = @($reviewerAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                [string]$node.Name -ceq 'Get-ReviewerLauncherCensusMasterKey'
            }, $true))
    Assert-Nonce ($launcherKeyDefinition.Count -eq 1) `
        'the reviewer exposes exactly one launcher census-key boundary'
    if ($launcherKeyDefinition.Count -eq 1) {
        . ([scriptblock]::Create($launcherKeyDefinition[0].Extent.Text))
        [byte[]]$adoptedCensusKey = @(Get-ReviewerLauncherCensusMasterKey `
                -EncodedKey ([Convert]::ToBase64String($derivedCensusKey)))
        Assert-Nonce ([Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                $derivedCensusKey, $adoptedCensusKey)) `
            'the reviewer adopts exactly the census key its launcher supplied'
        foreach ($badCensusKey in @('not-base64', [Convert]::ToBase64String([byte[]](1..31)))) {
            $badCensusKeyMessage = Get-ThrownMessage {
                Get-ReviewerLauncherCensusMasterKey -EncodedKey $badCensusKey
            }
            Assert-Nonce ($badCensusKeyMessage -match '32-byte|exactly 32') `
                "the reviewer refuses malformed launcher census key '$badCensusKey': '$badCensusKeyMessage'"
        }
    }
    Assert-Nonce ($reviewerText -match '\[byte\[\]\]\$launcherCensusMasterKey = \$script:ReviewerLauncherCensusMasterKey') `
        'the reviewer reads launcher census bytes directly without reshaping the byte array through the pipeline'
    Assert-Nonce ($reviewerText -match '\$hasLauncherCensusKey -or \$hasLocalCensusKey') `
        'the reviewer can seal a census from launcher custody without a run-root artifact key'
    Assert-Nonce ($reviewerText -match '\$env:DEVPILOT_REVIEWER_CENSUS_MASTER_KEY = \$null') `
        'the reviewer removes the census key from its environment before any model subprocess can inherit it'

    # Execute the exact shipping seal body, not a restatement. The block is found
    # through the typed assignment that consumes the launcher key, then run once
    # with launcher custody and once through the standalone local-key fallback.
    $sealKeyAssignment = $reviewerAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Extent.Text -cmatch '^\[byte\[\]\]\$launcherCensusMasterKey = \$script:ReviewerLauncherCensusMasterKey$'
        }, $true)
    Assert-Nonce ($null -ne $sealKeyAssignment) `
        'the shipping census-seal body was located through its typed launcher-key assignment'
    if ($null -ne $sealKeyAssignment) {
        $sealBodyText = $sealKeyAssignment.Parent.Extent.Text
        $sealBody = [scriptblock]::Create($sealBodyText.Substring(1, $sealBodyText.Length - 2))
        $sealRoot = Join-Path $scratch 'shipping-seal'
        [void](New-Item -ItemType Directory -Force -Path $sealRoot)
        $StateDir = $sealRoot
        $artifactKeyPath = Join-Path $sealRoot 'artifact-signing.key'
        $script:ReviewerRunId = $minted
        $script:CapturedCensusMasterKey = $null
        function Save-ReviewerModelStartCensusManifest {
            param(
                [string]$RunRoot,
                [byte[]]$MasterKey,
                [string]$RunExecutionId,
                [object[]]$Records
            )
            $script:CapturedCensusMasterKey = [byte[]]$MasterKey
            return [pscustomobject]@{ path = $RunRoot; runExecutionId = $RunExecutionId }
        }
        $script:ReviewerLauncherCensusMasterKey = [byte[]]$derivedCensusKey
        . $sealBody
        Assert-Nonce ($script:CapturedCensusMasterKey -is [byte[]] -and
            [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                $derivedCensusKey, $script:CapturedCensusMasterKey)) `
            'the exact shipping seal body passes the launcher key to the census manifest sealer'

        [byte[]]$script:LocalCensusMasterKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        function Get-ReviewerArtifactSigningKey { return $script:LocalCensusMasterKey }
        [IO.File]::WriteAllText($artifactKeyPath, 'local-key-present', $utf8)
        [byte[]]$script:ReviewerLauncherCensusMasterKey = @()
        $script:CapturedCensusMasterKey = $null
        . $sealBody
        Assert-Nonce ($script:CapturedCensusMasterKey -is [byte[]] -and
            [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                $script:LocalCensusMasterKey, $script:CapturedCensusMasterKey)) `
            'the exact shipping seal body retains the standalone local-key fallback'
        Remove-Item Function:\Save-ReviewerModelStartCensusManifest -ErrorAction SilentlyContinue
        Remove-Item Function:\Get-ReviewerArtifactSigningKey -ErrorAction SilentlyContinue
    }

    $adoptionMatch = [regex]::Match($reviewerText,
        '(?ms)^\$script:ReviewerRunId = \[string\]\$env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID.*?' +
        'cannot be audited against that expectation\.''\)\r?\n\}')
    Assert-Nonce ($adoptionMatch.Success) 'the reviewer''s run-identity adoption block was located in the shipping script'
    if ($adoptionMatch.Success) {
        $adoption = [scriptblock]::Create("Set-StrictMode -Version Latest`n" + $adoptionMatch.Value + "`n`$script:ReviewerRunId")

        $env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID = $minted
        try { $adopted = [string](& $adoption) } finally { $env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID = $null }
        Assert-Nonce ($adopted -ceq $minted) `
            "the reviewer adopts the execution identity its launcher named: got '$adopted', expected '$minted'"

        $env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID = $null
        $mintedA = [string](& $adoption)
        $mintedB = [string](& $adoption)
        Assert-Nonce ($mintedA -cmatch '^[0-9a-f]{32}\z' -and $mintedA -cne $mintedB) `
            'a reviewer launched with no named execution still mints a fresh identity of its own'

        # Quietly minting a different identity than the auditor expects would turn
        # every subsequent audit into a false alarm, so a malformed name stops the
        # run instead. The trailing-newline case is here because .NET's '$'
        # matches before one: anchored with '$' the reviewer would ADOPT that
        # value and then mismatch every ordinal comparison downstream.
        foreach ($bad in @('NOT-HEX', ($minted.ToUpperInvariant()), ($minted + '0'), ($minted + "`n"))) {
            $env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID = $bad
            try { $rejected = Get-ThrownMessage { & $adoption } } finally { $env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID = $null }
            Assert-Nonce ($rejected -match '32 lowercase hexadecimal') `
                "a reviewer named with the malformed identity '$bad' refuses to run: '$rejected'"
        }
    }

    # --- 5. THE EXPECTATION ACTUALLY BITES. ---
    # End of the chain: the census refuses evidence that does not name the
    # expected execution, and accepts the same shape of evidence when it does.
    # Everything above only matters because of this.
    . (Join-Path $RepoRoot 'src/Agents/reviewer/ModelStartCensus.ps1')
    . (Join-Path $RepoRoot 'src/Agents/reviewer/CrossVerification.ps1')
    $key = [byte[]]@(
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
        0x0f, 0x1e, 0x2d, 0x3c, 0x4b, 0x5a, 0x69, 0x78, 0x87, 0x96, 0xa5, 0xb4, 0xc3, 0xd2, 0xe1, 0xf0)
    $censusRoot = Join-Path $scratch 'census/run-root'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $censusRoot 'logs'))
    $utf8 = [Text.UTF8Encoding]::new($false)
    $logPath = Join-Path (Join-Path $censusRoot 'logs') 'reviewer.log.jsonl'
    $lines = @(
        (ConvertTo-Json -InputObject ([ordered]@{ mode = 'cycle-start'; cycle = 1; session = [ordered]@{ sessionId = $minted } }) -Depth 8 -Compress)
    )
    [IO.File]::WriteAllBytes($logPath, $utf8.GetBytes(($lines -join "`n") + "`n"))
    $records = @(Get-ReviewerModelStartLogRecord -LogPath $logPath)
    [void](Save-ReviewerModelStartCensusManifest -RunRoot $censusRoot -MasterKey $key `
            -RunExecutionId $minted -Records $records)

    $matching = Test-ReviewerModelStartCensusAuthenticity -RunRoot $censusRoot -MasterKey $key `
        -ExpectedRunExecutionId $minted
    Assert-Nonce ([bool]$matching.authenticated) `
        ('evidence sealed by the execution the launcher named is accepted: ' +
        "$(@($matching.objections) -join ' ')")

    # The replay: the SAME self-consistent set, audited by a launcher that named a
    # different execution. Nothing in the set is inconsistent - that is the point.
    $foreign = Test-ReviewerModelStartCensusAuthenticity -RunRoot $censusRoot -MasterKey $key `
        -ExpectedRunExecutionId $secondMint
    Assert-Nonce (-not [bool]$foreign.authenticated) `
        'a self-consistent evidence set produced by another execution was accepted as this run''s accounting'
    Assert-Nonce ((@($foreign.objections) -match 'execution this').Count -gt 0) `
        ('the foreign execution was refused for some reason other than its execution identity: ' +
        "$(@($foreign.objections) -join ' ')")

    # And the honest control for the weak witness: with no expectation named at
    # all, that same set passes. This is the exact gap the expectation closes, and
    # it is asserted rather than described so that the limit stays a measured
    # property of the design.
    $unaudited = Test-ReviewerModelStartCensusAuthenticity -RunRoot $censusRoot -MasterKey $key `
        -CorroborateExecutionFromRecords -Records $records
    Assert-Nonce ([bool]$unaudited.authenticated) `
        ('the record-corroborated witness changed its verdict on a self-consistent set, so this assertion no ' +
        'longer describes the gap it was written to describe')

    # The integrated normal-path control uses the same custody chain shipping
    # slot execution now uses: the run signs with the launcher-supplied key while both
    # verifiers authenticate with a fresh derivation from the run-set key.
    $productionExecution = New-TestExecutionId
    $productionRoot = Join-Path $scratch 'production-census/run-root'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $productionRoot 'logs'))
    $productionInputDir = Join-Path $productionRoot 'verification-inputs'
    $productionPreviewDir = Join-Path $productionRoot 'verification-previews'
    [void](New-Item -ItemType Directory -Force -Path $productionInputDir)
    [void](New-Item -ItemType Directory -Force -Path $productionPreviewDir)
    $productionLog = Join-Path (Join-Path $productionRoot 'logs') 'reviewer.log.jsonl'
    [IO.File]::WriteAllBytes(
        $productionLog,
        $utf8.GetBytes((ConvertTo-Json -InputObject ([ordered]@{
                        mode = 'cycle-start'
                        cycle = 1
                        session = [ordered]@{ sessionId = $productionExecution }
                    }) -Depth 8 -Compress) + "`n"))
    [byte[]]$productionMasterKey = @(Get-ShadowChildCensusMasterKey -Path $runSetKeyPath -SetId 'set-a' `
            -SlotName 'slot1' -RunExecutionId $productionExecution)
    $productionInputPath = Save-ReviewerVerificationInput -Manifest ([pscustomobject][ordered]@{
            kind = 'reviewer.verification.input.v1'
            artifactVersion = 1
            inputManifestSha256 = ('d' * 64)
        }) -Directory $productionInputDir -BaseName 'input' -MasterKey $productionMasterKey
    $productionInputArtifactSha = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [IO.File]::ReadAllBytes($productionInputPath))).ToLowerInvariant()
    [void](Save-ReviewerVerificationPreview -Manifest ([pscustomobject][ordered]@{
                kind = 'reviewer.verification.preview.v1'
                artifactVersion = 1
                status = 'complete'
                diagnostic = ''
                runExecutionId = $productionExecution
                inputArtifactPath = $productionInputPath
                inputManifestSha256 = ('d' * 64)
                inputArtifactSha256 = $productionInputArtifactSha
                assignments = @()
                verifierRuns = @()
            }) -Directory $productionPreviewDir -BaseName 'preview' -MasterKey $productionMasterKey `
        -CensusMasterKey $productionMasterKey -RunExecutionId $productionExecution)
    $productionRecords = @(Get-ReviewerModelStartLogRecord -LogPath $productionLog)
    [void](Save-ReviewerModelStartCensusManifest -RunRoot $productionRoot -MasterKey $productionMasterKey `
            -RunExecutionId $productionExecution -Records $productionRecords)
    $productionModelCensus = Get-ReviewerModelStartCensus -RunRoot $productionRoot -MasterKey $productionMasterKey `
        -Argv @('-EnableVerificationPreview') -ExpectedRunExecutionId $productionExecution `
        -CorroborateExecutionFromRecords
    $productionAssignmentCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $productionRoot `
        -MasterKey $productionMasterKey -Argv @('-EnableVerificationPreview') `
        -ExpectedRunExecutionId $productionExecution `
        -CorroborateExecutionFromRecords
    Assert-Nonce ([bool]$productionModelCensus.complete) `
        ('a normal externally keyed slot reports a complete model-start census: ' +
        [string]$productionModelCensus.incompleteReason)
    Assert-Nonce ([bool]$productionAssignmentCensus.complete) `
        ('a normal externally keyed slot reports a complete verifier-assignment census: ' +
        [string]$productionAssignmentCensus.incompleteReason)
}
finally {
    $env:DEVPILOT_REVIEWER_RUN_EXECUTION_ID = $null
    $env:DEVPILOT_REVIEWER_CENSUS_MASTER_KEY = $null
    $env:DEVPILOT_TEST_SLOT_CAPTURE = $null
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "Run-execution expectation: $($failures.Count) of $checks check(s) FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "Run-execution expectation: $checks check(s) passed."
exit 0
