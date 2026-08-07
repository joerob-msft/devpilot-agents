# Reconciling repeated runs of the same frozen input.
#
# A single replay is one observation. The model inside it is not deterministic,
# so a rule that reads `compliant` once and `violation` the next time has not
# told us anything we can act on - and picking whichever run looks better is the
# most flattering thing a reviewer could possibly do to itself.
#
# So: run it more than once, and let disagreement collapse to `unknown`. Never
# to the interesting answer, never to the majority, never to the first. If two
# runs of identical input disagree about an anchor, the honest report of that
# anchor is that we do not know, and the disagreement is written down where a
# reader can see both readings.
#
# This file is pure. It takes sealed specialist manifests that someone else has
# already read and verified, and returns an object. It opens no file, calls no
# model, and reaches no network.

Set-StrictMode -Version Latest

$script:ReviewerRunReconciliationKind = "reviewer.run-reconciliation"
$script:ReviewerRunReconciliationVersion = 1

# A key separator that cannot appear in the fields it joins. `|` looked fine
# until you notice `ruleSourceId` is schema-allowed any printable ASCII, so one
# pipe in a rule id would let a model choose where the report says its comment
# landed.
$script:ReviewerRunReconciliationSeparator = [string][char]0x1f

# The status a finished specialist pass writes. Not "ok" - a pass that ran to
# completion is `complete`, and a pass that fell over is `degraded`.
$script:ReviewerRunReconciliationOkStatus = "complete"

if (-not (Get-Command Get-ReviewerConventionSpecialistSha256 -ErrorAction SilentlyContinue)) {
    throw "RunReconciliation.ps1 requires ConventionSpecialist.ps1 to be dot-sourced first."
}

# The fields that have to be identical before two runs are even comparable.
# These are the inputs: the same PR at the same commit, judged by the same
# script, the same specialist library, the same prompt, the same plans, the same
# model. Anything else and we are comparing two different questions.
$script:ReviewerRunReconciliationBindingFields = @(
    "prId",
    "sourceCommit",
    "organization",
    "project",
    "repositoryId",
    "model",
    "configSha256",
    "scriptSha256",
    "specialistLibrarySha256",
    "promptSha256",
    "conventionPlanSha256",
    "factPlanSha256"
)

# Without these a run has no identity at all, and two empty strings compare
# equal - which is exactly how a manifest with no binding would reconcile with
# anything.
$script:ReviewerRunReconciliationRequiredFields = @(
    "prId", "sourceCommit", "configSha256", "scriptSha256",
    "specialistLibrarySha256", "promptSha256"
)

function Get-ReviewerRunReconciliationValue {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name, [AllowNull()]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-ReviewerRunReconciliationIdList {
    param([AllowNull()]$Value)
    # Ordinal sort, because the comparison below is a set comparison and the
    # order a model happened to write ids in is not a difference.
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($Value)) {
        $text = [string]$id
        if ($text) { [void]$ids.Add($text) }
    }
    $array = $ids.ToArray()
    [Array]::Sort($array, [StringComparer]::Ordinal)
    return , @($array)
}

function Get-ReviewerRunReconciliationBinding {
    param([Parameter(Mandatory)]$Manifest)
    $binding = [ordered]@{}
    foreach ($field in $script:ReviewerRunReconciliationBindingFields) {
        $binding[$field] = [string](Get-ReviewerRunReconciliationValue $Manifest $field "")
    }
    # WHICH frozen recording was replayed is part of the question. Two runs of
    # two different snapshots of the same commit are not repetitions.
    $replay = Get-ReviewerRunReconciliationValue $Manifest "replay" $null
    $binding["snapshotId"] = [string](Get-ReviewerRunReconciliationValue $replay "snapshotId" "")
    $binding["manifestDigest"] = [string](Get-ReviewerRunReconciliationValue $replay "manifestDigest" "")
    # The enumerated construct table too, because the ids are positional: `mi14`
    # names the fourteenth invocation, so the same name would silently mean two
    # different lines if the tables differed.
    #
    # Hash the WHOLE table as its producer wrote it. A hand-picked field list
    # here is a second copy of a schema that lives somewhere else, and when the
    # two drift the binding quietly stops binding - which is not a failure
    # anybody would notice, because everything still reconciles.
    $coverage = Get-ReviewerRunReconciliationValue $Manifest "ruleCoverage" $null
    $binding["constructs"] = ConvertTo-ReviewerConventionSpecialistCanonicalJson `
        -Value @(Get-ReviewerRunReconciliationValue $coverage "changedConstructs" @())
    $missing = @(@($script:ReviewerRunReconciliationRequiredFields) | Where-Object { -not $binding[$_] })
    if (-not $binding["snapshotId"] -or -not $binding["manifestDigest"]) { $missing += "replay identity" }
    return @{
        Sha256 = Get-ReviewerConventionSpecialistSha256 `
            -Text (ConvertTo-ReviewerConventionSpecialistCanonicalJson -Value $binding)
        Missing = @($missing)
    }
}

function Get-ReviewerRunReconciliationCandidateKey {
    param([Parameter(Mandatory)]$Candidate)
    # A candidate's own id (`c1`, `c2`) is whatever order the model wrote them
    # in and means nothing across runs. What identifies a candidate is what it
    # points at: which rule, which file, which line, which anchor.
    $rulePart = [string](Get-ReviewerRunReconciliationValue $Candidate "ruleSourceId" "")
    $path = ([string](Get-ReviewerRunReconciliationValue $Candidate "filePath" "")).TrimStart("/")
    $line = [string](Get-ReviewerRunReconciliationValue $Candidate "line" "0")
    $anchorKind = [string](Get-ReviewerRunReconciliationValue $Candidate "anchorKind" "")
    return @{
        Key = (@($rulePart, $anchorKind, $path, $line) -join $script:ReviewerRunReconciliationSeparator)
        RuleSourceId = $rulePart
        AnchorKind = $anchorKind
        FilePath = $path
        Line = $line
    }
}

function Test-ReviewerRunReconciliationSetsEqual {
    param([AllowNull()]$Left, [AllowNull()]$Right)
    # Both sides arrive already ordinal-sorted from the reading. Re-sorting here
    # would be six extra sorts per disagreeing part per run pair, for nothing.
    $a = @($Left)
    $b = @($Right)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ([string]::CompareOrdinal([string]$a[$i], [string]$b[$i]) -ne 0) { return $false }
    }
    return $true
}

function Get-ReviewerRunReconciliationDifference {
    param([AllowNull()]$Left, [AllowNull()]$Right)
    $a = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Left), [StringComparer]::Ordinal)
    $b = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Right), [StringComparer]::Ordinal)
    $onlyLeft = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($Left)) { if (-not $b.Contains([string]$id)) { [void]$onlyLeft.Add([string]$id) } }
    $onlyRight = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($Right)) { if (-not $a.Contains([string]$id)) { [void]$onlyRight.Add([string]$id) } }
    return @{ OnlyLeft = @($onlyLeft.ToArray()); OnlyRight = @($onlyRight.ToArray()) }
}

function Resolve-ReviewerRunReconciliation {
    <#
    .SYNOPSIS
        Collapses several runs of identical input into one conservative reading.
    .DESCRIPTION
        Every rule row and every candidate is compared across all runs. Anything
        the runs do not agree on becomes `unknown` (rules) or withheld
        (candidates), and the readings that disagreed are recorded verbatim.

        One run is not a reconciliation. Passing a single manifest is allowed -
        an operator may want the shape - but the result is marked unreconciled
        and nothing in it may be read as stable.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Manifests,
        [ValidateRange(2, 16)][int]$RequiredRunCount = 2
    )
    $runs = @($Manifests)
    if ($runs.Count -lt 1) { throw "Reconciliation needs at least one run manifest." }
    if ($runs.Count -gt 16) { throw "Reconciliation accepts at most 16 run manifests." }

    $problems = [System.Collections.Generic.List[string]]::new()
    $runSummaries = [System.Collections.Generic.List[object]]::new()

    # Same question, asked more than once. Two conditions, and they pull in
    # opposite directions on purpose: the BINDING must match (or the runs are
    # not about the same code), and the NONCE must differ (or the "two runs" are
    # one run counted twice, which would let a single favourable observation
    # launder itself into a stable result).
    $binding = $null
    $nonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $runIndex = 0
    foreach ($manifest in $runs) {
        $runIndex++
        $bindingResult = Get-ReviewerRunReconciliationBinding -Manifest $manifest
        $runBinding = [string]$bindingResult.Sha256
        # Two runs with no binding at all would compare equal, which is the one
        # way an empty manifest reconciles with anything.
        if (@($bindingResult.Missing).Count -gt 0) {
            [void]$problems.Add("run $runIndex is missing binding fields: " + (@($bindingResult.Missing) -join ", "))
        }
        if ($null -eq $binding) { $binding = $runBinding }
        elseif ([string]::CompareOrdinal($binding, $runBinding) -ne 0) {
            [void]$problems.Add("run $runIndex was produced from different inputs than run 1")
        }
        $replay = Get-ReviewerRunReconciliationValue $manifest "replay" $null
        $nonce = [string](Get-ReviewerRunReconciliationValue $replay "replayNonce" "")
        if (-not $nonce) { [void]$problems.Add("run $runIndex is not a replay artifact and carries no nonce") }
        elseif (-not $nonces.Add($nonce)) { [void]$problems.Add("run $runIndex reuses the nonce of an earlier run") }
        if ($null -ne $replay -and [bool](Get-ReviewerRunReconciliationValue $replay "promotable" $false)) {
            [void]$problems.Add("run $runIndex claims to be promotable")
        }
        $status = [string](Get-ReviewerRunReconciliationValue $manifest "status" "")
        if ($status -cne $script:ReviewerRunReconciliationOkStatus) {
            [void]$problems.Add("run $runIndex finished $status rather than $($script:ReviewerRunReconciliationOkStatus)")
        }
        $coverage = Get-ReviewerRunReconciliationValue $manifest "ruleCoverage" $null
        if ($null -eq $coverage) { [void]$problems.Add("run $runIndex has no rule accounting to reconcile") }
        $complete = [bool](Get-ReviewerRunReconciliationValue $coverage "complete" $false)
        # A hole agrees with everything. A rule NO row covered never enters the
        # comparison at all - it is not a disagreement, it is an absence, and
        # two absences look exactly like two runs concurring. So the holes are
        # named as problems, one kind at a time.
        #
        # A row the wrapper DEGRADED is not a hole: it arrives with status
        # `unknown` and reconciles like any other reading. Refusing the whole
        # comparison because some row honestly degraded would throw away the
        # rows that did not.
        foreach ($hole in @(
                @{ Field = "missing"; Text = "accounted for no row at all for" },
                @{ Field = "duplicates"; Text = "accounted twice for" },
                @{ Field = "unknown"; Text = "wrote a row for a rule never transported to it:" },
                @{ Field = "unaccountedCandidates"; Text = "proposed candidates with no accounting row:" })) {
            $ids = @(Get-ReviewerRunReconciliationValue $coverage $hole.Field @())
            if ($ids.Count -gt 0) {
                [void]$problems.Add("run $runIndex $($hole.Text) " + ((@($ids) | Select-Object -First 8) -join ", "))
            }
        }
        if ($null -ne $coverage -and [bool](Get-ReviewerRunReconciliationValue $coverage "constructsIncomplete" $false)) {
            # A short anchor table means both runs were asked about less code
            # than the change set contains, so agreement between them is
            # agreement about a subset nobody chose.
            [void]$problems.Add("run $runIndex enumerated an incomplete construct table")
        }
        [void]$runSummaries.Add([pscustomobject][ordered]@{
                run = $runIndex
                replayNonce = $nonce
                status = $status
                complete = $complete
                rowCount = @(Get-ReviewerRunReconciliationValue $coverage "rows" @()).Count
                candidateCount = @(Get-ReviewerRunReconciliationValue $manifest "candidates" @()).Count
            })
    }

    # Index each run's rows by `ruleRef`. That is a POSITION in the request
    # list, which sounds fragile until you notice the binding already pins the
    # config and both plan hashes - so the request list is identical across the
    # runs being compared, and the position is exactly as stable as the rule.
    # `ruleSourceId` alone is not a key: one source can legitimately be
    # transported under two refs, and keying on it turns that into a phantom
    # duplicate. The source id and hash are compared per row instead, so a run
    # whose rs2 is about a different rule than the other's rs2 disagrees rather
    # than being silently lined up.
    $byRun = [System.Collections.Generic.List[object]]::new()
    $ruleKeys = [System.Collections.Generic.List[string]]::new()
    $seenRuleKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($manifest in $runs) {
        $coverage = Get-ReviewerRunReconciliationValue $manifest "ruleCoverage" $null
        $index = [ordered]@{}
        foreach ($row in @(Get-ReviewerRunReconciliationValue $coverage "rows" @())) {
            $key = [string](Get-ReviewerRunReconciliationValue $row "ruleRef" "")
            if (-not $key) { $key = "source:" + [string](Get-ReviewerRunReconciliationValue $row "ruleSourceId" "") }
            # A run that lists the same ref twice has already failed its own
            # duplicate check upstream; here it just means we cannot line the
            # rows up, so treat the second as a disagreement with the first.
            if ($index.Contains($key)) {
                [void]$problems.Add("a run accounted for rule '$key' more than once")
                continue
            }
            $index[$key] = $row
            if ($seenRuleKeys.Add($key)) { [void]$ruleKeys.Add($key) }
        }
        [void]$byRun.Add($index)
    }
    $sortedRuleKeys = @($ruleKeys.ToArray())
    [Array]::Sort($sortedRuleKeys, [StringComparer]::Ordinal)

    $rows = [System.Collections.Generic.List[object]]::new()
    $stableCount = 0
    $unstableCount = 0
    foreach ($key in $sortedRuleKeys) {
        $rawStatuses = [System.Collections.Generic.List[string]]::new()
        $readings = [System.Collections.Generic.List[object]]::new()
        $reference = $null
        $agreed = $true
        $disagreements = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $byRun.Count; $i++) {
            $row = $(if ($byRun[$i].Contains($key)) { $byRun[$i][$key] } else { $null })
            if ($null -eq $row) {
                [void]$rawStatuses.Add("absent")
                [void]$readings.Add([pscustomobject][ordered]@{
                        run = $i + 1; status = "absent"; violating = @(); compliant = @()
                        notInReach = @(); unknown = @(); candidateId = ""; degradedReason = "the run did not account for this rule at all"
                    })
                $agreed = $false
                [void]$disagreements.Add("run $($i + 1) did not account for this rule")
                continue
            }
            $reading = [pscustomobject][ordered]@{
                run = $i + 1
                status = [string](Get-ReviewerRunReconciliationValue $row "status" "")
                violating = @(Get-ReviewerRunReconciliationIdList (Get-ReviewerRunReconciliationValue $row "violatingConstructs" @()))
                compliant = @(Get-ReviewerRunReconciliationIdList (Get-ReviewerRunReconciliationValue $row "compliantConstructs" @()))
                notInReach = @(Get-ReviewerRunReconciliationIdList (Get-ReviewerRunReconciliationValue $row "notInReachConstructs" @()))
                unknown = @(Get-ReviewerRunReconciliationIdList (Get-ReviewerRunReconciliationValue $row "unknownConstructs" @()))
                candidateId = [string](Get-ReviewerRunReconciliationValue $row "candidateId" "")
                degradedReason = [string](Get-ReviewerRunReconciliationValue $row "degradedReason" "")
                ruleRef = [string](Get-ReviewerRunReconciliationValue $row "ruleRef" "")
                ruleSourceId = [string](Get-ReviewerRunReconciliationValue $row "ruleSourceId" "")
                ruleSourceSha256 = [string](Get-ReviewerRunReconciliationValue $row "ruleSourceSha256" "")
            }
            # A row with no status at all is not a reading two runs can share.
            # Left alone, two blank statuses compare equal and reconcile to a
            # stable empty string, which prints as a row that agreed on nothing.
            if (-not $reading.status) {
                $agreed = $false
                [void]$disagreements.Add("run $($reading.run) gave this rule no status")
            }
            [void]$rawStatuses.Add($(if ($reading.status) { $reading.status } else { "(none)" }))
            [void]$readings.Add($reading)
            if ($null -eq $reference) { $reference = $reading; continue }
            # Same slot, different rule. The refs line up positionally, so this
            # is the check that the position still means what it meant.
            if ([string]::CompareOrdinal($reference.ruleSourceId, $reading.ruleSourceId) -ne 0 -or
                [string]::CompareOrdinal($reference.ruleSourceSha256, $reading.ruleSourceSha256) -ne 0) {
                $agreed = $false
                [void]$disagreements.Add("run $($reading.run) accounted for a different rule in this slot " +
                    "($($reference.ruleSourceId) vs $($reading.ruleSourceId))")
            }
            if ([string]::CompareOrdinal($reference.status, $reading.status) -ne 0) {
                $agreed = $false
                [void]$disagreements.Add("run 1 read $($reference.status) and run $($reading.run) read $($reading.status)")
            }
            # Agreeing on the word while disagreeing about which anchors carry
            # it is still disagreement. `violation as2` and `violation as7` are
            # two different findings wearing one status.
            foreach ($part in @(
                    @{ Name = "violating"; Left = $reference.violating; Right = $reading.violating },
                    @{ Name = "compliant"; Left = $reference.compliant; Right = $reading.compliant },
                    @{ Name = "out of reach"; Left = $reference.notInReach; Right = $reading.notInReach },
                    @{ Name = "unknown"; Left = $reference.unknown; Right = $reading.unknown })) {
                if (-not (Test-ReviewerRunReconciliationSetsEqual $part.Left $part.Right)) {
                    $agreed = $false
                    $diff = Get-ReviewerRunReconciliationDifference $part.Left $part.Right
                    $detail = @()
                    if (@($diff.OnlyLeft).Count -gt 0) { $detail += "only run 1: " + ((@($diff.OnlyLeft) | Select-Object -First 12) -join ",") }
                    if (@($diff.OnlyRight).Count -gt 0) { $detail += "only run $($reading.run): " + ((@($diff.OnlyRight) | Select-Object -First 12) -join ",") }
                    [void]$disagreements.Add("the $($part.Name) anchors differ (" + ($detail -join "; ") + ")")
                }
            }
        }
        # The whole point. Disagreement does not resolve to the interesting
        # reading, or the common one, or the first one. It resolves to `unknown`.
        $reconciled = $(if ($agreed -and $null -ne $reference) { $reference.status } else { "unknown" })
        $stable = [bool]($agreed -and $null -ne $reference)
        if ($stable) { $stableCount++ } else { $unstableCount++ }
        [void]$rows.Add([pscustomobject][ordered]@{
                ruleSourceId = $(if ($null -ne $reference) { [string]$reference.ruleSourceId } else { "" })
                ruleRef = $key
                reconciledStatus = $reconciled
                stable = $stable
                rawStatuses = @($rawStatuses.ToArray())
                disagreements = @($disagreements.ToArray())
                readings = @($readings.ToArray())
                violatingConstructs = @($(if ($stable) { $reference.violating } else { @() }))
                notInReachConstructs = @($(if ($stable) { $reference.notInReach } else { @() }))
            })
    }

    # Candidates. A proposed comment is only worth showing if every run of the
    # same input proposed it. One run out of two is a coin toss with a citation.
    $candidateKeys = [System.Collections.Generic.List[string]]::new()
    $candidateFields = [ordered]@{}
    $seenCandidateKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $candidatesByRun = [System.Collections.Generic.List[object]]::new()
    foreach ($manifest in $runs) {
        $index = [ordered]@{}
        foreach ($candidate in @(Get-ReviewerRunReconciliationValue $manifest "candidates" @())) {
            $identity = Get-ReviewerRunReconciliationCandidateKey -Candidate $candidate
            $key = [string]$identity.Key
            if (-not $index.Contains($key)) { $index[$key] = $candidate }
            if ($seenCandidateKeys.Add($key)) {
                [void]$candidateKeys.Add($key)
                # Keep the parts. Rebuilding them by splitting the key back
                # apart puts an attacker-chosen file and line in the report the
                # moment a rule id contains the separator.
                $candidateFields[$key] = $identity
            }
        }
        [void]$candidatesByRun.Add($index)
    }
    $sortedCandidateKeys = @($candidateKeys.ToArray())
    [Array]::Sort($sortedCandidateKeys, [StringComparer]::Ordinal)

    $candidates = [System.Collections.Generic.List[object]]::new()
    $agreedCandidateCount = 0
    foreach ($key in $sortedCandidateKeys) {
        $present = [System.Collections.Generic.List[int]]::new()
        $absent = [System.Collections.Generic.List[int]]::new()
        $example = $null
        for ($i = 0; $i -lt $candidatesByRun.Count; $i++) {
            if ($candidatesByRun[$i].Contains($key)) {
                [void]$present.Add($i + 1)
                if ($null -eq $example) { $example = $candidatesByRun[$i][$key] }
            }
            else { [void]$absent.Add($i + 1) }
        }
        $inEveryRun = ($absent.Count -eq 0)
        if ($inEveryRun) { $agreedCandidateCount++ }
        $identity = $candidateFields[$key]
        [void]$candidates.Add([pscustomobject][ordered]@{
                key = $key
                ruleSourceId = [string]$identity.RuleSourceId
                anchorKind = [string]$identity.AnchorKind
                filePath = [string]$identity.FilePath
                line = [string]$identity.Line
                presentInRuns = @($present.ToArray())
                absentInRuns = @($absent.ToArray())
                inEveryRun = $inEveryRun
                disposition = $(if ($inEveryRun) { "agreed" } else { "withheldRunDisagreement" })
                severity = [string](Get-ReviewerRunReconciliationValue $example "severity" "")
                comment = [string](Get-ReviewerRunReconciliationValue $example "comment" "")
            })
    }

    # A run count below what the operator asked for is not a pass with a caveat.
    # It is an unreconciled observation, and it says so.
    $enoughRuns = ($runs.Count -ge $RequiredRunCount)
    if (-not $enoughRuns) {
        [void]$problems.Add("only $($runs.Count) run(s) supplied; $RequiredRunCount are required before any status may be called stable")
    }
    $reconciled = [bool]($enoughRuns -and $problems.Count -eq 0)
    if (-not $reconciled) {
        # Comparable-input failures make every per-row comparison meaningless,
        # so nothing survives as stable.
        foreach ($row in $rows) {
            $row.reconciledStatus = "unknown"
            $row.stable = $false
            $row.violatingConstructs = @()
            $row.notInReachConstructs = @()
        }
        foreach ($candidate in $candidates) {
            if ($candidate.disposition -ceq "agreed") { $candidate.disposition = "withheldUnreconciled" }
            $candidate.inEveryRun = $false
        }
        $stableCount = 0
        $unstableCount = @($rows).Count
        $agreedCandidateCount = 0
    }

    return [pscustomobject][ordered]@{
        kind = $script:ReviewerRunReconciliationKind
        version = $script:ReviewerRunReconciliationVersion
        reconciled = $reconciled
        promotable = $false
        runCount = $runs.Count
        requiredRunCount = $RequiredRunCount
        inputBindingSha256 = [string]$binding
        problems = @($problems.ToArray())
        runs = @($runSummaries.ToArray())
        stableRowCount = $stableCount
        unstableRowCount = $unstableCount
        rows = @($rows.ToArray())
        agreedCandidateCount = $agreedCandidateCount
        candidates = @($candidates.ToArray())
    }
}

function Format-ReviewerRunReconciliationReport {
    param([Parameter(Mandatory)]$Reconciliation)
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("# Cross-run reconciliation (evaluation only - never promotable)")
    [void]$lines.Add("")
    [void]$lines.Add("Runs compared: $([int]$Reconciliation.runCount) (required: $([int]$Reconciliation.requiredRunCount))")
    [void]$lines.Add("Input binding: $([string]$Reconciliation.inputBindingSha256)")
    [void]$lines.Add("Reconciled: $([bool]$Reconciliation.reconciled)")
    if (@($Reconciliation.problems).Count -gt 0) {
        [void]$lines.Add("")
        [void]$lines.Add("## Why this is not a reconciliation")
        foreach ($problem in @($Reconciliation.problems)) { [void]$lines.Add("- $problem") }
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Rules")
    [void]$lines.Add("Stable: $([int]$Reconciliation.stableRowCount); collapsed to unknown by disagreement: $([int]$Reconciliation.unstableRowCount)")
    foreach ($row in @($Reconciliation.rows)) {
        [void]$lines.Add("")
        [void]$lines.Add("### $([string]$row.ruleRef) $([string]$row.ruleSourceId)")
        [void]$lines.Add("- Reconciled status: $([string]$row.reconciledStatus) (stable: $([bool]$row.stable))")
        [void]$lines.Add("- Raw per-run statuses: $((@($row.rawStatuses)) -join ', ')")
        if (@($row.violatingConstructs).Count -gt 0) {
            [void]$lines.Add("- Violating anchors: $((@($row.violatingConstructs)) -join ', ')")
        }
        foreach ($disagreement in @($row.disagreements)) { [void]$lines.Add("- Disagreement: $disagreement") }
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Candidates")
    [void]$lines.Add("Proposed by every run: $([int]$Reconciliation.agreedCandidateCount) of $(@($Reconciliation.candidates).Count)")
    foreach ($candidate in @($Reconciliation.candidates)) {
        [void]$lines.Add("- [$([string]$candidate.disposition)] $([string]$candidate.filePath):$([string]$candidate.line) " +
            "rule $([string]$candidate.ruleSourceId); runs $((@($candidate.presentInRuns)) -join ',')" +
            $(if (@($candidate.absentInRuns).Count -gt 0) { "; absent in $((@($candidate.absentInRuns)) -join ',')" } else { "" }))
    }
    [void]$lines.Add("")
    [void]$lines.Add("This reconciliation is an evaluation artifact. It cannot authorize delivery,")
    [void]$lines.Add("promote a candidate, or be used as evidence that any comment may be posted.")
    return ($lines.ToArray() -join "`n")
}
