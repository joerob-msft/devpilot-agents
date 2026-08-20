#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Holds the boundary a future C# coordinator has to sit behind: it consumes the
    published stage contracts, and it may not contain prompt or verdict logic.

.DESCRIPTION
    The coordinator is not ported. That is the point of running this now: the
    rule that decides what a port is allowed to be has to exist BEFORE the port,
    or it is written afterwards to describe whatever was already built.

    What this suite asserts today, in force:

      * The two schemas a coordinator would consume - the stage envelope and the
        stage producer contract table - exist, parse, carry no BOM, and describe
        exactly the twelve boundaries the running code declares. A schema that
        drifted from the table would hand a generated consumer a shape no
        producer publishes.

      * Those schemas are SCHEMA. They carry no prompt text, no model name, no
        temperature, no threshold, no endpoint. A coordinator generated from them
        cannot acquire prompt or verdict logic by reading them.

      * Every stage kind in the schema is a registered contract with a matching
        contract version, and every registered stage kind is in the schema.

    What this suite asserts the moment a port lands, and vacuously until then:

      * Any C# source that mentions a reviewer stage kind must also name the
        schema it consumes, so a coordinator reads the contract rather than
        re-deriving a shape by hand.

      * No C# source may contain prompt text, model selection, severity
        arbitration, verdict arbitration, or an HTTP client aimed at a model
        provider. The coordinator sequences stages; it does not decide review
        outcomes.

    No model, no network, no write.

.EXAMPLE
    ./tools/Test-ReviewerCoordinatorContract.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'src\Agents\reviewer\StageProducers.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Assert-Coordinator {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) { [void]$script:failures.Add($Message) }
}

function Read-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "'$Path' starts with a UTF-8 BOM."
    }
    return ([System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -Depth 32)
}

$schemaRoot = Join-Path $repoRoot 'src\Agents\reviewer\schemas'
$envelopeSchemaPath = Join-Path $schemaRoot 'reviewer.stage-envelope.v1.json'
$contractSchemaPath = Join-Path $schemaRoot 'reviewer.stage-producer-contracts.v1.json'

foreach ($path in @($envelopeSchemaPath, $contractSchemaPath)) {
    Assert-Coordinator (Test-Path -LiteralPath $path -PathType Leaf) `
        "A future coordinator has nothing to consume: '$path' is missing."
}
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
    Write-Host "FAIL - $($failures.Count) of $checks coordinator contract checks failed."
    exit 1
}

$envelopeSchema = Read-JsonDocument -Path $envelopeSchemaPath
$contractSchema = Read-JsonDocument -Path $contractSchemaPath

# ---------------------------------------------------------------------------
# The envelope a coordinator would parse is the envelope the writer emits.
# ---------------------------------------------------------------------------

$expectedEnvelopeFields = [string[]]@('envelopeVersion', 'kind', 'contractVersion', 'form', 'depth', 'payload')
$schemaEnvelopeFields = [string[]]@($envelopeSchema.required)
foreach ($field in $expectedEnvelopeFields) {
    Assert-Coordinator ($schemaEnvelopeFields -ccontains $field) `
        "The stage envelope schema does not require '$field'; a generated consumer would accept an envelope the reader refuses."
}
Assert-Coordinator ($schemaEnvelopeFields.Count -eq $expectedEnvelopeFields.Count) `
    "The stage envelope schema requires $($schemaEnvelopeFields.Count) field(s), not $($expectedEnvelopeFields.Count)."
Assert-Coordinator (-not [bool]$envelopeSchema.additionalProperties) `
    "The stage envelope schema tolerates unknown fields; the reader does not, so a generated consumer would disagree with the producer."

# ---------------------------------------------------------------------------
# The table a coordinator would generate from is the table in force.
# ---------------------------------------------------------------------------

$liveRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in (Get-ReviewerStageProducerContract)) { [void]$liveRows.Add($row) }
$schemaRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in $contractSchema.boundaries) { [void]$schemaRows.Add($row) }

Assert-Coordinator ($liveRows.Count -eq 12) `
    "The running stage producer table declares $($liveRows.Count) boundaries, not 12."
Assert-Coordinator ($schemaRows.Count -eq $liveRows.Count) `
    "The stage producer schema describes $($schemaRows.Count) boundaries, the running table declares $($liveRows.Count)."

$schemaByStage = @{}
foreach ($row in $schemaRows) { $schemaByStage[[string]$row.stage] = $row }
foreach ($row in $liveRows) {
    $stage = [string]$row.Stage
    if (-not $schemaByStage.ContainsKey($stage)) {
        Assert-Coordinator $false "Stage '$stage' is in force but absent from the schema a coordinator would consume."
        continue
    }
    $schemaRow = $schemaByStage[$stage]
    Assert-Coordinator ([string]$schemaRow.kind -ceq [string]$row.Kind) `
        "Stage '$stage' publishes kind '$($row.Kind)' but the schema names '$($schemaRow.kind)'."
    $contract = Get-ReviewerStageContract -Kind ([string]$row.Kind)
    Assert-Coordinator ([int]$schemaRow.contractVersion -eq [int]$contract.ContractVersion) `
        "Stage '$stage' is at contract version $($contract.ContractVersion) but the schema declares $($schemaRow.contractVersion)."
    $schemaFields = [string[]]@($schemaRow.requiredFields)
    $liveFields = [string[]]@($row.RequiredFields)
    Assert-Coordinator (($schemaFields -join ',') -ceq ($liveFields -join ',')) `
        "Stage '$stage' requires [$($liveFields -join ', ')] but the schema requires [$($schemaFields -join ', ')]."
    $schemaCollections = [string[]]@($schemaRow.collectionFields)
    $liveCollections = [string[]]@($row.CollectionFields)
    Assert-Coordinator (($schemaCollections -join ',') -ceq ($liveCollections -join ',')) `
        "Stage '$stage' declares collection fields [$($liveCollections -join ', ')] but the schema declares [$($schemaCollections -join ', ')]."
}
foreach ($stage in $schemaByStage.Keys) {
    $known = @($liveRows | Where-Object { [string]$_.Stage -ceq $stage })
    Assert-Coordinator ($known.Count -eq 1) `
        "The schema describes stage '$stage', which is not a boundary in force."
}

# ---------------------------------------------------------------------------
# The schemas are schema. A coordinator generated from them cannot learn a
# prompt, a model, or a threshold, because none is written down here.
# ---------------------------------------------------------------------------

# Deliberately narrow and mechanical. Words like "severity" legitimately appear
# in a boundary's prose summary - the verdict stage is ABOUT severity - so what
# is forbidden is the machinery of deciding, not the vocabulary of describing.
$forbiddenSchemaTokens = [string[]]@(
    'systemPrompt', 'system_prompt', 'promptText', 'temperature', 'maxTokens',
    'max_tokens', 'topP', 'endpoint', 'apiKey', 'api_key', 'gpt-', 'claude-',
    'threshold', 'You are a'
)
foreach ($path in @($envelopeSchemaPath, $contractSchemaPath)) {
    $text = [IO.File]::ReadAllText($path)
    foreach ($token in $forbiddenSchemaTokens) {
        Assert-Coordinator (-not $text.Contains($token)) `
            "'$(Split-Path $path -Leaf)' mentions '$token'; the contract a coordinator consumes must be shape, not judgement."
    }
}

# ---------------------------------------------------------------------------
# What a port is allowed to be. Vacuous until a coordinator exists, in force the
# moment one does - which is the only order in which this rule means anything.
# ---------------------------------------------------------------------------

$csharpFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.cs' -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.FullName -notlike '*\obj\*' -and [string]$_.FullName -notlike '*\bin\*' })

# Recorded, not asserted: this is the honest statement of what has been ported
# so far, and it is what makes the rules below vacuous today.
Write-Host "coordinator-contract: $($csharpFiles.Count) C# source file(s) in tree; stage boundaries in force: $($liveRows.Count)."

$stageKinds = [string[]]@($liveRows | ForEach-Object { [string]$_.Kind })
$forbiddenCoordinatorTokens = [string[]]@(
    'systemPrompt', 'SystemPrompt', 'PromptTemplate', 'ChatCompletion', 'temperature',
    'HttpClient', 'AcceptCandidate', 'CorrectSeverity', 'DecideVerdict', 'RenderPrompt',
    # The machinery of judging a supervised run's OUTPUT. A coordinator that
    # supervises a slot sees findings, candidates, severities and verdicts go
    # past; the rule is that it may carry none of the code that forms an opinion
    # about any of them.
    'RejectCandidate', 'ScoreCandidate', 'RankCandidate', 'AssignSeverity', 'SeverityOf',
    'ComputeVerdict', 'VerdictOf', 'ModelClient', 'InvokeModel', 'CallModel', 'Completions',
    'OpenAI', 'Anthropic',
    # Delivery. Slice two supervises a preview-only run and writes to no provider,
    # so the names a provider write would need are forbidden outright rather than
    # left to review.
    'PostComment', 'CreateComment', 'PublishComment', 'WriteComment', 'CreateThread',
    'UpdatePullRequest', 'http://', 'https://',
    # Slice three adds a second slot and a reconciliation, and both bring a new
    # way for judgement to arrive. A model name written down in C# would be a
    # choice this program made; the names reach it only inside the signed
    # request's opaque argument list, are forwarded verbatim and are never
    # compared, so no literal one may appear here.
    'gpt-', 'claude-', 'gemini', 'o3-', 'ModelName', 'modelName', 'ReviewerModel',
    # The reconciliation's own vocabulary. Its census is copied across by
    # position; a coordinator that named one of these counters would be a
    # coordinator that had a rule about it.
    'StableRow', 'stableRow', 'UnstableRow', 'unstableRow',
    'AgreedCandidate', 'agreedCandidate', 'CandidateText', 'FindingText', 'findingText',
    # The switch that turns disagreement into a failure is the reviewed tool's to
    # own. Asking for it would be asking the comparison to form the opinion this
    # program is forbidden to hold.
    'FailOnDisagreement',
    # The reviewed comparison and reconciliation are reached through the child
    # adapter's step contract, never by name. Naming one would be this program
    # deciding how the comparison is invoked.
    'Compare-ReviewerReplayRuns', 'Resolve-ReviewerRunReconciliation',
    # The delivery decision arrives the same way, through a step name. The
    # reviewed evaluation, its gate library and its policy are never named here.
    'New-ReviewerGateDecision', 'Save-ReviewerGateDecision', 'DeliveryGates',
    # The delivery slice adds a whole vocabulary of judgement, and none of it may
    # cross into C#. The coordinator carries a status word and a census of
    # integers; a name from this list would be a name it had a rule about.
    'DeliverPreview', 'PromoteCandidate', 'CastVote', 'ApprovePullRequest',
    'UnattendedComment', 'unattendedComment', 'HumanPromotable', 'humanPromotable',
    'ImportantOrHigher', 'importantOrHigher', 'EligiblePreview', 'eligiblePreview',
    'NoFindings', 'noFindings', 'Withheld', 'withheld', 'Degraded', 'degraded'
)
foreach ($file in $csharpFiles) {
    $text = [IO.File]::ReadAllText($file.FullName)
    $mentionsStage = $false
    foreach ($kind in $stageKinds) {
        if ($text.Contains($kind)) { $mentionsStage = $true }
    }
    if ($mentionsStage) {
        Assert-Coordinator ($text.Contains('reviewer.stage-envelope.v1.json') -or
            $text.Contains('reviewer.stage-producer-contracts.v1.json')) `
            "'$($file.Name)' consumes a reviewer stage kind without naming the schema it consumes; a coordinator reads the published contract rather than re-deriving its shape."
    }
    foreach ($token in $forbiddenCoordinatorTokens) {
        Assert-Coordinator (-not $text.Contains($token)) `
            "'$($file.Name)' mentions '$token'; a coordinator sequences stages and must not carry prompt or verdict logic."
    }
}

# ---------------------------------------------------------------------------
# Where a supervised slot's budget is allowed to come from.
# ---------------------------------------------------------------------------
# A request that could name its own slot deadlines could give itself an
# unbounded run by writing a larger number in a file it also authored. The
# budgets therefore come from the signed qualification plan, and the ONE number
# the request contributes is the supervision grace. Asserted structurally rather
# than left to review, because the difference between the two is a single field.
$requestContract = Join-Path $repoRoot 'tools\ShadowRunCoordinator\CoordinatorRequest.cs'
if (Test-Path -LiteralPath $requestContract -PathType Leaf) {
    $requestText = [IO.File]::ReadAllText($requestContract)
    foreach ($budget in @('slotTimeoutSeconds', 'progressTimeoutSeconds', 'perCallTimeoutSeconds')) {
        Assert-Coordinator (-not $requestText.Contains($budget)) `
            "The typed request contract reads '$budget'; a supervised slot's budget must come from the signed plan, not from the request."
    }
    Assert-Coordinator ($requestText.Contains('supervisionGraceSeconds')) `
        'The typed request contract no longer carries the supervision grace, which is the one budget a caller may set.'

    # ---------------------------------------------------------------------
    # Exactly two slots, declared from creation.
    # ---------------------------------------------------------------------
    # A set whose size could change between its declaration and its comparison
    # is a set whose comparison is over an unknown number of runs. The count is
    # therefore a constant in the contract rather than a length read off the
    # request, and the names are positional, so a request cannot rename its way
    # into a different set.
    Assert-Coordinator ($requestText -match 'DeclaredSlotCount\s*=\s*2\b') `
        'The typed request contract does not fix the declared slot count at two.'
    Assert-Coordinator ($requestText.Contains('DeclaredSlotNames')) `
        'The typed request contract does not name its declared slots.'
    foreach ($slotName in @('slot1', 'slot2')) {
        Assert-Coordinator ($requestText.Contains($slotName)) `
            "The typed request contract does not declare '$slotName'."
    }
    # And no dynamic membership: nothing in the contract may add a slot.
    foreach ($growth in @('AddSlot', 'AppendSlot', 'slotCount =', 'ResizeSlot')) {
        Assert-Coordinator (-not $requestText.Contains($growth)) `
            "The typed request contract reads '$growth'; the declared set is fixed at creation and never grows."
    }
}

# ---------------------------------------------------------------------------
# A delivery exists, and no transition in it can write.
# ---------------------------------------------------------------------------
# The earlier slices asserted the absence of a delivery. That claim has been
# spent: there are now five delivery transitions. What replaces it is the
# stronger claim the absence was standing in for - that every one of them is
# preview-only, that the enumeration names them all, and that no name a provider
# write would need appears anywhere in the enumeration. The forbidden-token sweep
# above already applies the write vocabulary to this file along with every other,
# so this section adds the positive half: the five states are present, in order,
# and nothing in the file offers a sixth.
$stateContract = Join-Path $repoRoot 'tools\ShadowRunCoordinator\CoordinatorState.cs'
if (Test-Path -LiteralPath $stateContract -PathType Leaf) {
    $stateText = [IO.File]::ReadAllText($stateContract)
    foreach ($required in @('Slot1TerminalVerified', 'Slot2TerminalVerified',
            'ReconciliationAuthorized', 'ReconciliationRunning', 'ReconciliationVerified',
            'DeliveryAuthorized', 'DeliveryLaunching', 'DeliveryRunning',
            'DeliveryTerminalObserved', 'DeliveryTerminalVerified')) {
        Assert-Coordinator ($stateText.Contains($required)) `
            "The coordinator state enumeration does not carry '$required'."
    }
    # The five are the whole of the delivery. A sixth transition - anything that
    # named a publish, a post or a promotion - would be a write-enabled state,
    # and there is no such thing in this machine.
    foreach ($writeState in @('DeliveryPublish', 'DeliveryPosted', 'DeliveryWritten',
            'DeliveryPromoted', 'DeliveryCommitted', 'Published to', 'ProviderWrite')) {
        Assert-Coordinator (-not $stateText.Contains($writeState)) `
            "The coordinator state enumeration reads '$writeState'; no delivery transition in this machine may write."
    }
    # The delivery is the last rank, so a state added after it would be a state
    # the machine reaches with a decision already sealed behind it.
    Assert-Coordinator ($stateText -match 'DeliveryRank\s*=\s*31\b') `
        'The coordinator state enumeration does not close its rank table at the delivery.'
}

# The comparison's result is carried, never read. The one function that copies
# the census across must not compare a name to anything, so the file that holds
# it is asserted to contain the carrier and none of the counters.
$machineContract = Join-Path $repoRoot 'tools\ShadowRunCoordinator\PreparationMachine.cs'
if (Test-Path -LiteralPath $machineContract -PathType Leaf) {
    $machineText = [IO.File]::ReadAllText($machineContract)
    Assert-Coordinator ($machineText.Contains('ReadOpaqueCounts')) `
        'The coordinator does not carry the comparison census through a single opaque reader.'
    Assert-Coordinator ($machineText.Contains('RequireEverySlotVerified')) `
        'The coordinator does not gate its reconciliation on every declared slot.'
    Assert-Coordinator ($machineText.Contains('RequirePredecessorVerified')) `
        'The coordinator does not gate a later slot on its predecessor.'
    # One definition of "may not write", applied wherever a capability is
    # reported, and one definition of "wrote nothing", applied wherever a count
    # is. A build that wanted to permit a write would have to change these two
    # methods, and this suite reads their names.
    Assert-Coordinator ($machineText.Contains('RequireNoWriteCapability')) `
        'The coordinator does not refuse a reported write capability through a single method.'
    Assert-Coordinator ($machineText.Contains('RequireZeroWrites')) `
        'The coordinator does not refuse a reported write through a single method.'
    # The refusal is applied at all three points a capability is reported: the
    # plan the authorization is committed against, the probe taken immediately
    # before the irreversible step, and the sealed decision.
    $capabilityChecks = ([regex]::Matches($machineText, 'RequireNoWriteCapability\(')).Count
    Assert-Coordinator ($capabilityChecks -ge 4) `
        "The coordinator applies its write-capability refusal $capabilityChecks time(s); it is declared once and applied at authorization, at prelaunch and at verification."
    $writeChecks = ([regex]::Matches($machineText, 'RequireZeroWrites\(')).Count
    Assert-Coordinator ($writeChecks -ge 4) `
        "The coordinator applies its zero-write refusal $writeChecks time(s); it belongs on every result that reports a count."
    # Preview-only is a literal the coordinator compares against, not a default
    # it falls back to.
    Assert-Coordinator ($machineText.Contains('PreviewOnlyKind')) `
        'The coordinator does not pin the one authorization kind it performs.'
}

# The one kind is defined once, in the request contract, and there is no second
# value anywhere for a caller to select.
if (Test-Path -LiteralPath $requestContract -PathType Leaf) {
    $requestText = [IO.File]::ReadAllText($requestContract)
    Assert-Coordinator ($requestText -match 'PreviewOnlyKind\s*=\s*"PreviewOnly"') `
        'The typed request contract does not define the single preview-only authorization kind.'
    foreach ($writeKind in @('"Write"', '"Publish"', '"Unattended"', '"Promote"', 'WriteEnabled')) {
        Assert-Coordinator (-not $requestText.Contains($writeKind)) `
            "The typed request contract offers '$writeKind' as an authorization; preview-only is the only kind this coordinator performs."
    }
    # A budget that could be raised is a budget. The range is fixed at zero
    # through zero, so there is no number a request can write that permits one.
    Assert-Coordinator ($requestText.Contains('providerWriteBudget')) `
        'The typed request contract does not require a delivery to declare its provider write budget.'
}

# ---------------------------------------------------------------------------
# Strict versioned files, and nothing on stdout.
# ---------------------------------------------------------------------------
# Every step boundary in this machine is a file with a version in it. A step that
# exchanged a bare shape would be a step whose reader and writer could drift, and
# a step that answered on stdout would be a step whose answer any console write
# in any loaded module could corrupt.
$childAdapter = Join-Path $repoRoot 'tools\Invoke-ShadowCoordinatorChild.ps1'
if (Test-Path -LiteralPath $childAdapter -PathType Leaf) {
    $childText = [IO.File]::ReadAllText($childAdapter)
    foreach ($contract in @(
            'devpilot.shadow-run-coordinator.child-result.v1',
            'devpilot.shadow-run-coordinator.child-request.v1',
            'devpilot.shadow-run-coordinator.reconciliation-request.v1',
            'devpilot.shadow-run-coordinator.reconciliation-summary.v1',
            'devpilot.shadow-run-coordinator.delivery-request.v1',
            'devpilot.shadow-run-coordinator.delivery-summary.v1')) {
        Assert-Coordinator ($childText.Contains($contract)) `
            "The child adapter does not name the versioned contract '$contract'."
    }
    # The C# and the PowerShell must be talking about the same documents. A
    # version bumped on one side only is the drift the versions exist to catch.
    if (Test-Path -LiteralPath $machineContract -PathType Leaf) {
        foreach ($shared in @(
                'devpilot.shadow-run-coordinator.delivery-request.v1',
                'devpilot.shadow-run-coordinator.delivery-summary.v1')) {
            Assert-Coordinator ($machineText.Contains($shared)) `
                "The coordinator does not name the versioned contract '$shared' that its child writes."
        }
    }
    # Nothing contractual goes to stdout. Write-Output and a bare ConvertTo-Json
    # at statement level are the two ways it could, and neither appears.
    foreach ($stdout in @('Write-Output', 'Write-Information')) {
        Assert-Coordinator (-not $childText.Contains($stdout)) `
            "The child adapter uses '$stdout'; its answer travels in a result file, never on a stream a module can share."
    }
    foreach ($line in @($childText -split "`n")) {
        $trimmed = $line.Trim()
        Assert-Coordinator (-not ($trimmed -match '^ConvertTo-Json\b')) `
            'The child adapter emits JSON at statement level, which would place a contractual document on stdout.'
    }
    # The delivery steps exist, are four, and are reached by name.
    foreach ($step in @('deliveryPlan', 'deliveryPrelaunch', 'deliveryRun', 'deliveryVerify')) {
        Assert-Coordinator ($childText.Contains("'^$step`$'")) `
            "The child adapter has no dispatch arm for the '$step' step."
    }
    # A dot-source inside a function body defines its names in that body's scope and
    # loses them on return, so a delivery step that loaded the reviewed gate library
    # through a plain call would run with none of it and fail only against a real
    # reviewer tree - which no stub in the suite can reach. Every load of that library
    # is therefore required to be dotted, statically, here.
    $undottedImports = @()
    foreach ($line in @($childText -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\.?\s*Import-ShadowChildDeliverySource\b' -and $trimmed -notmatch '^\.\s') {
            $undottedImports += $trimmed
        }
    }
    Assert-Coordinator ($undottedImports.Count -eq 0) `
        ("The child adapter loads the reviewed delivery libraries without dot-sourcing the load: '" +
            ($undottedImports -join "', '") + "'. Those names would not survive the call.")
    $dottedImports = @($childText -split "`n" | Where-Object { $_.Trim() -match '^\.\s+Import-ShadowChildDeliverySource\b' })
    Assert-Coordinator ($dottedImports.Count -ge 3) `
        "The child adapter's delivery steps do not each dot-source the reviewed gate library; $($dottedImports.Count) of 3 do."
    # The adapter that evaluates a preview-only decision must hold no way to
    # write to a provider, in the same way the coordinator holds none.
    foreach ($write in @('Invoke-RestMethod', 'Invoke-WebRequest', 'System.Net.Http',
            'az repos pr', 'PostComment', 'CreateThread')) {
        Assert-Coordinator (-not $childText.Contains($write)) `
            "The child adapter reads '$write'; the delivery it evaluates is preview-only and reaches no provider."
    }
}

# ---------------------------------------------------------------------------
# The cohort scales the machine; it does not soften it.
# ---------------------------------------------------------------------------
# A cohort is the one place in this toolkit where a single operator action starts
# many preparations, so it is the one place where a quietly relaxed rule would be
# multiplied rather than noticed. The properties below are the ones a reviewer
# would have to re-derive by reading four files, so they are asserted instead:
# one entry at a time, preview-only, no write budget, and no path by which an
# entry that ended is attempted again.
$cohortManifestSource = Join-Path $repoRoot 'tools\ShadowRunCoordinator\CohortManifest.cs'
$cohortJournalSource = Join-Path $repoRoot 'tools\ShadowRunCoordinator\CohortJournal.cs'
$cohortAuditSource = Join-Path $repoRoot 'tools\ShadowRunCoordinator\CohortAudit.cs'
$cohortRunnerSource = Join-Path $repoRoot 'tools\ShadowRunCoordinator\CohortRunner.cs'
$cohortSources = @($cohortManifestSource, $cohortJournalSource, $cohortAuditSource, $cohortRunnerSource)
$cohortPresent = @($cohortSources | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if ($cohortPresent.Count -eq $cohortSources.Count) {
    $manifestText = [IO.File]::ReadAllText($cohortManifestSource)
    $journalText = [IO.File]::ReadAllText($cohortJournalSource)
    $cohortAuditText = [IO.File]::ReadAllText($cohortAuditSource)
    $runnerText = [IO.File]::ReadAllText($cohortRunnerSource)
    $cohortText = $manifestText + $journalText + $cohortAuditText + $runnerText

    # One at a time is a constant, not a default. A cohort that read its own
    # parallelism from the manifest could be given a larger number by the same
    # file it validates, and two preparations sharing one toolkit checkout is a
    # different experiment from the one this build has evidence for.
    Assert-Coordinator ($manifestText -match 'SupportedConcurrency\s*=\s*1\b') `
        'The cohort manifest does not fix its supported concurrency at one.'
    foreach ($parallel in @('Parallel.For', 'Task.WhenAll', 'ThreadPool', 'Parallel.ForEach', 'MaxDegreeOfParallelism')) {
        Assert-Coordinator (-not $cohortText.Contains($parallel)) `
            "The cohort reads '$parallel'; entries in this build are prepared one after another."
    }

    # The same single authorization kind the coordinator performs, pinned again
    # at the cohort boundary so a cohort cannot admit an entry the coordinator
    # would have refused.
    Assert-Coordinator ($manifestText -match 'PreviewOnlyKind\s*=\s*"PreviewOnly"') `
        'The cohort manifest does not pin the one authorization kind it admits.'
    Assert-Coordinator ($cohortText.Contains('RequireNoWriteCapability')) `
        'The cohort does not refuse a reported write capability through the coordinator''s own definition.'
    Assert-Coordinator ($cohortText.Contains('RequireZeroWrites')) `
        'The cohort does not refuse a reported write through the coordinator''s own definition.'
    Assert-Coordinator ($runnerText.Contains('RequireSlotSet') -and $runnerText.Contains('RequireDelivery')) `
        'The cohort admits an entry without checking that it declares the whole reviewed pipeline.'

    # An entry that ended is finished. Retrying it would run a second preparation
    # against a subject whose first preparation already produced evidence, and
    # replacing it would change what the cohort was authorized to do after the
    # operator authorized it.
    foreach ($retry in @('RetryEntry', 'RequeueEntry', 'ReplaceEntry', 'AddEntry', 'RemoveEntry',
            'RetryCount', 'MaxRetries', 'retryPolicy', 'Reattempt')) {
        Assert-Coordinator (-not $cohortText.Contains($retry)) `
            "The cohort reads '$retry'; an entry that ended is never attempted again and the declared set never changes."
    }
    Assert-Coordinator ($journalText.Contains('HasEnded')) `
        'The cohort journal has no single test for an entry that already ended.'

    # The ceiling is consulted before the entry that would cross it, using what
    # the cohort has actually spent. A ceiling checked afterwards is a ceiling
    # that has already been exceeded.
    Assert-Coordinator ($runnerText.Contains('DescribeBudgetStop')) `
        'The cohort has no single admission check against its global ceiling.'
    Assert-Coordinator ($runnerText.IndexOf('DescribeBudgetStop(journal)') -lt $runnerText.IndexOf('RunEntry(')) `
        'The cohort checks its global ceiling after starting the entry that would cross it.'

    # Every cohort document is versioned and every one of them is a file. Nothing
    # here answers on a stream.
    foreach ($contract in @('devpilot.shadow-cohort.manifest.v1', 'devpilot.shadow-cohort.journal.v1',
            'devpilot.shadow-cohort.index.v1', 'devpilot.shadow-cohort.launch-intent.v1',
            'devpilot.shadow-cohort.lease.v1')) {
        Assert-Coordinator ($cohortText.Contains($contract)) `
            "The cohort does not name the versioned contract '$contract'."
    }
    Assert-Coordinator ($cohortText.Contains('Console.Out.Write') -eq $false) `
        'The cohort writes to stdout; its documents travel in files and its progress on the error stream.'

    # The index is an accounting document, not a review. It may carry digests and
    # counts; it may not carry anything a reader could mistake for a judgement,
    # and it may not carry the subject it was taken over.
    foreach ($judgement in @('Verdict', 'Severity', 'Promotable', 'Finding', 'Confidence', 'Score', 'Rank(')) {
        Assert-Coordinator (-not $cohortAuditText.Contains($judgement)) `
            "The cohort summary reads '$judgement'; a cohort index reports what ran, never what was concluded."
    }
    foreach ($identity in @('"organization"', '"repository"', '"pullRequestId"', '"sourceCommit"')) {
        Assert-Coordinator (-not ($cohortAuditText -match [Regex]::Escape("Set($identity"))) `
            "The cohort index publishes $identity; an entry is identified in the index by digest alone."
    }

    # An entry whose evidence this build could not read is closed, not left open.
    # An entry recorded as running once its child is gone is an entry a later run
    # would read as resumable and start a second time.
    Assert-Coordinator ($journalText.Contains('EvidenceRefused')) `
        'The cohort journal has no ending for an entry whose published evidence was refused.'
    Assert-Coordinator ($runnerText.Contains('CohortEntryOutcomes.EvidenceRefused')) `
        'The cohort runner never closes an entry whose evidence it refused, so a resume could start it again.'
    Assert-Coordinator ($runnerText.Contains('EndedRefused')) `
        'The cohort runner walks past an entry whose evidence was refused instead of staying stopped.'

    # Liveness is decided from a process id AND a start time, because process ids
    # are recycled. A record that cannot answer "is it still running?" refuses
    # rather than answers no.
    Assert-Coordinator ($journalText -match 'ChildProcessId\s*<=\s*0') `
        'The cohort journal treats an unusable child identity as a dead child, which would permit a second launch.'
    Assert-Coordinator ($journalText.Contains('ChildStartedAtUtc')) `
        'The cohort journal records no child start time, so a recycled process id could pass for a live child.'

    # An index that claims to be rebuildable has to notice when the artifacts it
    # names have changed under it, or a removed audit would simply be re-signed
    # as an entry that never ran.
    Assert-Coordinator ($runnerText.Contains('RequireCommittedDigests')) `
        'The cohort index is rebuilt without checking the rebuilt summaries against the digests its journal committed.'
    Assert-Coordinator ($runnerText.Contains('DeriveOutcome')) `
        'A rebuilt cohort index does not derive its outcome from the journal, so a rebuild could launder a stop.'

    # A refusal's own words can name an output root, and an output root can encode
    # the subject it was taken over. The words go to the operator's log; the index
    # carries their digest.
    Assert-Coordinator ($cohortAuditText.Contains('terminalDetailSha256')) `
        'The cohort index publishes no digest of the refusal it reports.'
    Assert-Coordinator ($runnerText.Contains('PublishIndexOnFault')) `
        'The cohort publishes fault messages straight into its index instead of digesting them.'

    # An audit found standing in an entry's output root is only that entry's audit
    # if it says so. Otherwise a cohort would count evidence left there by
    # something else.
    Assert-Coordinator ($cohortAuditText.Contains('expectedCorrelationId')) `
        'The cohort reads an entry audit without binding it to the request that entry declared.'
    Assert-Coordinator ($cohortAuditText.Contains('RequireWriteCount')) `
        'The cohort reads its write counters leniently; an unreadable counter is not the zero the cohort has to prove.'

    # Binding an audit by the words inside it only proves it describes the right
    # entry. Anyone who could write that file could write those words, so the
    # cohort also checks the entry's own signature over it before believing a
    # single counter it reports.
    Assert-Coordinator ($cohortAuditText.Contains('RequireAuthentic')) `
        'The cohort trusts an entry audit it never authenticated, so an edited audit could report zero writes.'
    Assert-Coordinator ($cohortAuditText.Contains('FixedTimeEquals')) `
        'The cohort compares an audit signature with an ordinary comparison.'
    foreach ($pin in @('requestSha256', 'subjectSha256')) {
        Assert-Coordinator ($cohortAuditText.Contains($pin)) `
            "The cohort reads an entry audit without binding its $pin to the entry the manifest sealed."
    }

    # Where a cohort's own record lives cannot depend on the directory a run
    # started from, or a resume would read a different journal.
    Assert-Coordinator ($manifestText.Contains('RequireRootedPath')) `
        'The cohort manifest admits a relative journal or index path, so a resume could read a different record.'
    Assert-Coordinator ($manifestText.Contains('IsPathFullyQualified')) `
        'The cohort manifest admits a drive-relative path, which is rooted and still resolves against the current directory.'
    Assert-Coordinator ($manifestText.Contains('RequireIndexIsolated')) `
        'The cohort manifest admits an index declared over the journal or an entry output root, so publishing would destroy the record it was derived from.'
    foreach ($entryPath in @('RequestPath = CohortManifest.RequireRootedPath',
            'OutputRoot = CohortManifest.RequireRootedPath',
            'RuleBundlePath = CohortManifest.RequireRootedPath')) {
        Assert-Coordinator ($manifestText.Contains($entryPath)) `
            "The cohort manifest does not require '$entryPath'; the child is started in the toolkit checkout, so a path that is not fully qualified names one place in the parent and another in the child."
    }
    Assert-Coordinator ($runnerText.Contains('IsPathFullyQualified(request.OutputRoot)')) `
        'The cohort admits a sealed request whose own output root is not fully qualified, so the child would publish its evidence somewhere the parent never looks.'

    # A completion is a claim about what a preparation consumed and did not write.
    # A completion with no evidence behind it is not a cheap one, and a preparation
    # that ended some other way without evidence is not a free one either: the
    # ceiling admitted it on an estimate, so the estimate is what it costs.
    Assert-Coordinator ($runnerText.Contains('RequireEvidenceAccountedFor')) `
        'The cohort accepts a completed entry that published no audit, which the index would report as a preparation that ran and consumed nothing.'
    Assert-Coordinator ($runnerText -match 'RequireEvidenceAccountedFor\(entry, outcome, summary\)') `
        'The cohort decides whether an entry is accounted for somewhere other than on the summary it read, so the audit could vanish between the check and the reading.'
    Assert-Coordinator ($runnerText -match 'private static void RequireEvidenceAccountedFor\([^)]*\)\s*\{\s*if \(!string\.Equals\(summary\.AuditSha256') `
        'The cohort asks how an entry ended before it asks whether the entry left any evidence, so a crashed or killed preparation is carried into the index with a zero write count it never proved.'

    # A signed journal cannot be repaired by hand, so the writer may never commit
    # a record its own reader refuses: the only way out of that would be a fresh
    # root, which reopens every ended entry and re-launches subjects that ran.
    Assert-Coordinator ($journalText.Contains('RequireWritable')) `
        'The cohort journal commits records without first checking that its own reader would admit them.'
    # A journal is signed, so nothing in it can be corrected afterwards. The one
    # record this build never writes is an ordinary ending with no evidence behind
    # it, and a journal that holds one was not written by this build - reading it
    # would walk past a preparation on counters nothing published.
    Assert-Coordinator ($journalText -match 'state, CohortEntryStates\.Ended[\s\S]{0,200}auditSha256, "none"[\s\S]{0,200}EvidenceRefused') `
        'The cohort journal reader admits an ended record with no audit digest that is not the refusal itself, so a journal from somewhere else resumes as though its entries cost nothing.'
    Assert-Coordinator ($journalText -match 'record\.HasEnded\s*&&\s*string\.Equals\(record\.AuditSha256, "none"[\s\S]{0,120}!record\.EndedRefused') `
        'The cohort journal writer may commit an ended record with no audit digest that its own reader refuses, which would wedge a signed account.'
    Assert-Coordinator ($journalText -match 'ExitCode\s*=\s*StrictJson\.RequireInt\(node,\s*"exitCode",\s*label,\s*int\.MinValue') `
        'The cohort journal bounds the child exit code below what the operating system can report, so a hard-dying child would wedge it.'
    Assert-Coordinator ($runnerText.Contains('RecordedStartTime')) `
        'The cohort runner commits the raw child start time, which is empty when it cannot be read and unreadable once written.'
    Assert-Coordinator ($journalText.Contains('IsUsableStartTime')) `
        'The cohort journal admits a start time it cannot parse, so a malformed identity would decide whether a child is alive.'
    Assert-Coordinator ($cohortAuditText.Contains('RequireRepresentable')) `
        'The cohort narrows its ceiling counters with an unchecked cast, which would let a wrapped total disable the ceiling.'
    Assert-Coordinator ($journalText.Contains('HasRecordedWork')) `
        'The cohort journal cannot tell a mint that got no further from a journal somebody removed.'

    # The word a cohort publishes about itself is committed before it is published,
    # so a rebuild reports the record rather than inferring one from entry states
    # that cannot tell a ceiling stop from a killed runner.
    Assert-Coordinator ($journalText.Contains('RecordTerminal')) `
        'The cohort journal keeps no record of the word its index published, so a rebuild would have to guess one.'
    Assert-Coordinator ($runnerText.Contains('HasTerminal')) `
        'The cohort runner derives a published outcome without first reading the one its journal already recorded.'
    Assert-Coordinator ($runnerText -match 'journal\.RecordTerminal\([^)]*\);\s*\r?\n\s*try') `
        'The cohort runner commits the word it publishes inside the guard that swallows a failed write, so a cohort could exit successfully while its record still said something else.'

    # The operator alias arrives on the command line. A cohort whose authorization
    # could be read out of the manifest would be a cohort a scheduled task could
    # start by writing a file.
    $programContract = Join-Path $repoRoot 'tools\ShadowRunCoordinator\Program.cs'
    if (Test-Path -LiteralPath $programContract -PathType Leaf) {
        $programText = [IO.File]::ReadAllText($programContract)
        Assert-Coordinator ($programText.Contains('--authorized-by')) `
            'The entry point does not require a cohort to name the operator who started it.'
        Assert-Coordinator (-not $manifestText.Contains('authorizedBy')) `
            'The cohort manifest carries an operator alias; the authorization is an argument an operator types, not a field a file can hold.'
    }
}

# The rule above can only bite on files it can see. If the port ever lands
# somewhere this suite does not look, the suite would stay green while holding
# nothing, so the search root is asserted rather than assumed.
Assert-Coordinator (Test-Path -LiteralPath (Join-Path $repoRoot 'tools\SealParity\Program.cs') -PathType Leaf) `
    "The C# search did not find the one C# file known to be in this tree; the coordinator rules are not being applied to anything."

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
    Write-Host "FAIL - $($failures.Count) of $checks coordinator contract checks failed."
    exit 1
}
Write-Host "PASS - $checks coordinator contract checks."
exit 0
