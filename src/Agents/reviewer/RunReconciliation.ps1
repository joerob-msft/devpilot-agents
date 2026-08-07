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
$script:ReviewerRunReconciliationSetKind = "reviewer.run-reconciliation-set"
$script:ReviewerRunReconciliationVersion = 1

function Read-ReviewerRunReconciliationSet {
    <#
        Reads a sealed qualification-set declaration.

        Separate from the specialist preview reader because the kind is
        different, and because a declaration that verified as a run artifact
        would be a declaration somebody could have written afterwards.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [ValidateRange(1024, 16777216)][int]$MaxBytes = 1048576
    )
    # Bounded. The path is operator-supplied, and a declaration is a few hundred
    # bytes; reading a gigabyte because somebody named the wrong file is a
    # self-inflicted wound with no upside.
    $info = Get-Item -LiteralPath $Path
    if ($info.Length -gt $MaxBytes) {
        throw "The qualification run set at $Path is $($info.Length) bytes; the cap is $MaxBytes."
    }
    $envelope = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $manifestJson = [string](Get-ReviewerConventionSpecialistValue $envelope "manifestJson" "")
    $signature = [string](Get-ReviewerConventionSpecialistValue $envelope "signature" "")
    $key = Get-ReviewerConventionSpecialistDomainKey -MasterKey $MasterKey -Domain preview
    if (-not $manifestJson -or
        -not (Test-ReviewerConventionSpecialistSignature -Json $manifestJson -Key $key -Signature $signature)) {
        throw "Qualification run-set signature verification failed."
    }
    $set = $manifestJson | ConvertFrom-Json -Depth 8
    if ([string](Get-ReviewerConventionSpecialistValue $set "kind" "") -cne $script:ReviewerRunReconciliationSetKind) {
        throw "That artifact is not a qualification run-set declaration."
    }
    foreach ($field in @("setId", "snapshotName", "snapshotManifestDigest", "plannedRunCount")) {
        if (-not (Get-ReviewerConventionSpecialistValue $set $field "")) {
            throw "The qualification run set is missing '$field'."
        }
    }
    return $set
}

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
    "factPlanSha256",
    # Schema and code identity. `scriptSha256`, `specialistLibrarySha256` and
    # `promptSha256` together ARE the head identity as far as this pass is
    # concerned - they are what the reviewer was when it ran, which is a
    # stronger statement than a commit id, because a commit id says nothing
    # about a dirty worktree. `artifactVersion` and `kind` pin the shape those
    # hashes are recorded in, so a schema change cannot make two differently
    # shaped manifests compare equal.
    "artifactVersion",
    "kind"
)

# Without these a run has no identity at all, and two empty strings compare
# equal - which is exactly how a manifest with no binding would reconcile with
# anything.
$script:ReviewerRunReconciliationRequiredFields = @(
    "prId", "sourceCommit", "model", "configSha256", "scriptSha256",
    "specialistLibrarySha256", "promptSha256", "conventionPlanSha256", "factPlanSha256",
    "artifactVersion", "kind"
)

function Add-ReviewerRunReconciliationProblem {
    <#
        Records a problem as a structure, not a sentence.

        The digest has to be the same whichever order the runs were listed in,
        and a sentence carrying "run 3" is not - so the digest used to rewrite
        positions into nonces by substring surgery. That is wrong twice: a
        group written in input order still differs, and any "run 1" the text
        did not put there gets rewritten too. The `Code` and the run NONCES are
        what the digest reads; the sentence is only ever shown to a person.
    #>
    param(
        [Parameter(Mandatory)]$Problems,
        [Parameter(Mandatory)][string]$Code,
        [AllowEmptyCollection()][int[]]$Runs = @(),
        [Parameter(Mandatory)][string]$Text
    )
    [void]$Problems.Add([pscustomobject][ordered]@{ code = $Code; runs = @($Runs); text = $Text })
}

function Get-ReviewerRunReconciliationProblemText {
    param([AllowNull()]$Problems)
    return , [string[]]@(@($Problems) | ForEach-Object { [string]$_.text })
}

function Get-ReviewerRunReconciliationValue {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name, [AllowNull()]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        # ContainsKey first: a generic Dictionary[string,object] binds
        # `.Contains` to the KeyValuePair overload, which is never true for a
        # bare key. Same probe order as the specialist's own helper - two
        # readers of the same manifests must not disagree about what it holds.
        if ($Object.PSObject.Methods["ContainsKey"]) {
            if ($Object.ContainsKey($Name)) { return $Object[$Name] }
            return $Default
        }
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
    #
    # Callers must cast to `[string[]]`, NOT wrap in `@()`. The `return , @()`
    # idiom keeps a single-element list a list, and `@()` around such a call
    # wraps the whole array as ONE element - which made every anchor id an
    # array rather than a string, so hashtable lookups compared by reference
    # and set comparisons compared the stringification of the whole set.
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($Value)) {
        $text = [string]$id
        if ($text) { [void]$ids.Add($text) }
    }
    $array = $ids.ToArray()
    [Array]::Sort($array, [StringComparer]::Ordinal)
    return , [string[]]$array
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

    $problems = [System.Collections.Generic.List[object]]::new()
    $runSummaries = [System.Collections.Generic.List[object]]::new()

    # Same question, asked more than once. Two conditions, and they pull in
    # opposite directions on purpose: the BINDING must match (or the runs are
    # not about the same code), and the NONCE must differ (or the "two runs" are
    # one run counted twice, which would let a single favourable observation
    # launder itself into a stable result).
    #
    # The bindings are grouped, not compared against run 1. Making one run the
    # reference means a single degraded run - which carries no construct table,
    # so binds differently - reads as "every other run disagrees with run 1",
    # and it also makes the report depend on the order the operator listed
    # them in.
    $bindingGroups = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $bindingOrder = [System.Collections.Generic.List[string]]::new()
    $nonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $runIndex = 0
    foreach ($manifest in $runs) {
        $runIndex++
        $bindingResult = Get-ReviewerRunReconciliationBinding -Manifest $manifest
        $runBinding = [string]$bindingResult.Sha256
        if (-not $bindingGroups.ContainsKey($runBinding)) {
            $bindingGroups[$runBinding] = [System.Collections.Generic.List[int]]::new()
            [void]$bindingOrder.Add($runBinding)
        }
        [void]$bindingGroups[$runBinding].Add($runIndex)
        # Two runs with no binding at all would compare equal, which is the one
        # way an empty manifest reconciles with anything.
        if (@($bindingResult.Missing).Count -gt 0) {
            Add-ReviewerRunReconciliationProblem -Problems $problems -Code "missingBindingFields" -Runs @($runIndex) -Text ("run $runIndex is missing binding fields: " + (@($bindingResult.Missing) -join ", "))
        }
        $replay = Get-ReviewerRunReconciliationValue $manifest "replay" $null
        $nonce = [string](Get-ReviewerRunReconciliationValue $replay "replayNonce" "")
        if (-not $nonce) { Add-ReviewerRunReconciliationProblem -Problems $problems -Code "noNonce" -Runs @($runIndex) -Text "run $runIndex is not a replay artifact and carries no nonce" }
        elseif (-not $nonces.Add($nonce)) { Add-ReviewerRunReconciliationProblem -Problems $problems -Code "nonceReused" -Runs @($runIndex) -Text "run $runIndex reuses the nonce of an earlier run" }
        if ($null -ne $replay -and [bool](Get-ReviewerRunReconciliationValue $replay "promotable" $false)) {
            Add-ReviewerRunReconciliationProblem -Problems $problems -Code "claimsPromotable" -Runs @($runIndex) -Text "run $runIndex claims to be promotable"
        }
        $status = [string](Get-ReviewerRunReconciliationValue $manifest "status" "")
        if ([string]::CompareOrdinal($status, $script:ReviewerRunReconciliationOkStatus) -ne 0) {
            Add-ReviewerRunReconciliationProblem -Problems $problems -Code "notComplete:$status" -Runs @($runIndex) -Text "run $runIndex finished $status rather than $($script:ReviewerRunReconciliationOkStatus)"
        }
        $coverage = Get-ReviewerRunReconciliationValue $manifest "ruleCoverage" $null
        if ($null -eq $coverage) { Add-ReviewerRunReconciliationProblem -Problems $problems -Code "noAccounting" -Runs @($runIndex) -Text "run $runIndex has no rule accounting to reconcile" }
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
                Add-ReviewerRunReconciliationProblem -Problems $problems -Code "hole:$($hole.Field)" -Runs @($runIndex) -Text ("run $runIndex $($hole.Text) " + ((@($ids) | Select-Object -First 8) -join ", "))
            }
        }
        if ($null -ne $coverage -and [bool](Get-ReviewerRunReconciliationValue $coverage "constructsIncomplete" $false)) {
            # A short anchor table means both runs were asked about less code
            # than the change set contains, so agreement between them is
            # agreement about a subset nobody chose.
            Add-ReviewerRunReconciliationProblem -Problems $problems -Code "constructsIncomplete" -Runs @($runIndex) -Text "run $runIndex enumerated an incomplete construct table"
        }
        # And the last term of the wrapper's own `Complete`: a pass where every
        # rule ruled every anchor out of reach is clean row by row and has
        # looked at nothing. Two of those agree perfectly about nothing.
        $enumerated = [int](Get-ReviewerRunReconciliationValue $coverage "enumeratedConstructCount" 0)
        $checked = [int](Get-ReviewerRunReconciliationValue $coverage "checkedConstructCount" 0)
        if ($null -ne $coverage -and $enumerated -gt 0 -and $checked -eq 0) {
            Add-ReviewerRunReconciliationProblem -Problems $problems -Code "weighedNothing" -Runs @($runIndex) -Text "run $runIndex weighed none of its $enumerated anchors"
        }
        [void]$runSummaries.Add([pscustomobject][ordered]@{
                run = $runIndex
                replayNonce = $nonce
                status = $status
                complete = $complete
                inputBindingSha256 = $runBinding
                rowCount = @(Get-ReviewerRunReconciliationValue $coverage "rows" @()).Count
                candidateCount = @(Get-ReviewerRunReconciliationValue $manifest "candidates" @()).Count
            })
    }

    # One binding, or none of this means anything. Reported as GROUPS so the
    # message says which runs went together rather than which ones differed
    # from whichever happened to be listed first.
    $sortedBindings = @($bindingOrder.ToArray())
    [Array]::Sort($sortedBindings, [StringComparer]::Ordinal)
    $binding = $(if (@($sortedBindings).Count -gt 0) { $sortedBindings[0] } else { "" })
    if (@($sortedBindings).Count -gt 1) {
        # Members named by NONCE and sorted, not by position. A group written as
        # "{run 3, run 4}" says something different when the operator lists the
        # same runs the other way round, and that difference reached the digest.
        $groupRuns = [System.Collections.Generic.List[int]]::new()
        $groupText = @(@($sortedBindings) | ForEach-Object {
                $members = @(@($bindingGroups[$_]) | ForEach-Object {
                        [void]$groupRuns.Add($_)
                        $nonce = [string]@($runSummaries.ToArray())[$_ - 1].replayNonce
                        $(if ($nonce) { $nonce } else { "unidentified" })
                    })
                [Array]::Sort($members, [StringComparer]::Ordinal)
                "{" + ((@($members) | ForEach-Object { "run:" + $_ }) -join ", ") + "} at " + $_.Substring(0, 12)
            })
        Add-ReviewerRunReconciliationProblem -Problems $problems -Code "mixedInputs:$(@($sortedBindings).Count)" `
            -Runs @($groupRuns.ToArray()) `
            -Text ("the runs were produced from $(@($sortedBindings).Count) different inputs: " + ($groupText -join "; "))
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
        # Ordinal, NOT [ordered]. An OrderedDictionary compares keys
        # case-insensitively, so `rs0` and `RS0` would be one slot. Insertion
        # order is not relied on; the key list is re-sorted ordinally below.
        $index = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($row in @(Get-ReviewerRunReconciliationValue $coverage "rows" @())) {
            $key = [string](Get-ReviewerRunReconciliationValue $row "ruleRef" "")
            if (-not $key) { $key = "source:" + [string](Get-ReviewerRunReconciliationValue $row "ruleSourceId" "") }
            # A run that lists the same ref twice has already failed its own
            # duplicate check upstream; here it just means we cannot line the
            # rows up, so treat the second as a disagreement with the first.
            if ($index.ContainsKey($key)) {
                Add-ReviewerRunReconciliationProblem -Problems $problems -Code "duplicateRuleRow" -Runs @() -Text "a run accounted for rule '$key' more than once"
                continue
            }
            $index[$key] = $row
            if ($seenRuleKeys.Add($key)) { [void]$ruleKeys.Add($key) }
        }
        [void]$byRun.Add($index)
    }
    $sortedRuleKeys = @($ruleKeys.ToArray())
    [Array]::Sort($sortedRuleKeys, [StringComparer]::Ordinal)


    # Per rule, and then per ANCHOR inside it.
    #
    # Comparing four id lists tells you THAT two runs disagreed. It does not
    # tell you which anchor they disagreed about, and "the violating anchors
    # differ" is not something a reader can act on. So each construct gets its
    # own reconciled verdict: every run's verdict for that id is collected, and
    # if they are not all the same the anchor is `unknown` with both readings
    # named. The rule's status is then derived from the anchors, exactly as the
    # wrapper derives a row's status from its partition.
    #
    # Nothing here reads run 1 as a reference. Every comparison is over the SET
    # of readings, so listing the runs in a different order cannot change the
    # outcome - which matters, because "whichever run you happened to put first"
    # is precisely the kind of favourable selection this exists to prevent.
    $rows = [System.Collections.Generic.List[object]]::new()
    $stableCount = 0
    $unstableCount = 0
    $verdictFields = [ordered]@{
        violation = "violating"
        compliant = "compliant"
        notInReach = "notInReach"
        unknown = "unknown"
    }
    foreach ($key in $sortedRuleKeys) {
        $rawStatuses = [System.Collections.Generic.List[string]]::new()
        $readings = [System.Collections.Generic.List[object]]::new()
        $disagreements = [System.Collections.Generic.List[string]]::new()
        $anchorVerdicts = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $anchorIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $distinctStatuses = [System.Collections.Generic.List[string]]::new()
        $distinctStatusSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $distinctRules = [System.Collections.Generic.List[string]]::new()
        $distinctRuleSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $anyAbsent = $false

        for ($i = 0; $i -lt $byRun.Count; $i++) {
            $run = $i + 1
            $row = $(if ($byRun[$i].ContainsKey($key)) { $byRun[$i][$key] } else { $null })
            if ($null -eq $row) {
                $anyAbsent = $true
                [void]$rawStatuses.Add("absent")
                [void]$readings.Add([pscustomobject][ordered]@{
                        run = $run; status = "absent"; violating = @(); compliant = @()
                        notInReach = @(); unknown = @(); candidateId = ""
                        degradedReason = "the run did not account for this rule at all"
                        ruleRef = $key; ruleSourceId = ""; ruleSourceSha256 = ""
                    })
                [void]$disagreements.Add("run $run did not account for this rule")
                continue
            }
            $reading = [pscustomobject][ordered]@{
                run = $run
                status = [string](Get-ReviewerRunReconciliationValue $row "status" "")
                violating = [string[]](Get-ReviewerRunReconciliationIdList (Get-ReviewerRunReconciliationValue $row "violatingConstructs" @()))
                compliant = [string[]](Get-ReviewerRunReconciliationIdList (Get-ReviewerRunReconciliationValue $row "compliantConstructs" @()))
                notInReach = [string[]](Get-ReviewerRunReconciliationIdList (Get-ReviewerRunReconciliationValue $row "notInReachConstructs" @()))
                unknown = [string[]](Get-ReviewerRunReconciliationIdList (Get-ReviewerRunReconciliationValue $row "unknownConstructs" @()))
                candidateId = [string](Get-ReviewerRunReconciliationValue $row "candidateId" "")
                degradedReason = [string](Get-ReviewerRunReconciliationValue $row "degradedReason" "")
                ruleRef = [string](Get-ReviewerRunReconciliationValue $row "ruleRef" "")
                ruleSourceId = [string](Get-ReviewerRunReconciliationValue $row "ruleSourceId" "")
                ruleSourceSha256 = [string](Get-ReviewerRunReconciliationValue $row "ruleSourceSha256" "")
            }
            [void]$readings.Add($reading)
            # A row with no status at all is not a reading anyone can share.
            # Left alone, two blanks compare equal and reconcile to a stable
            # empty string, which prints as a row that agreed about nothing.
            $statusWord = $(if ($reading.status) { $reading.status } else { "(none)" })
            [void]$rawStatuses.Add($statusWord)
            # Ordinal sets, not `-cnotcontains`. PowerShell's case-sensitive
            # operators are still CULTURE-sensitive, so a zero-weight character
            # - a soft hyphen, a zero-width space, the separator itself -
            # compares equal to nothing, and two different identities collapse
            # into one, silencing the disagreement they should have raised.
            if ($distinctStatusSet.Add($statusWord)) { [void]$distinctStatuses.Add($statusWord) }
            $ruleIdentity = $reading.ruleSourceId + $script:ReviewerRunReconciliationSeparator + $reading.ruleSourceSha256
            if ($distinctRuleSet.Add($ruleIdentity)) { [void]$distinctRules.Add($ruleIdentity) }

            foreach ($verdict in @($verdictFields.Keys)) {
                foreach ($id in @($reading.($verdictFields[$verdict]))) {
                    [void]$anchorIds.Add($id)
                    if (-not $anchorVerdicts.ContainsKey($id)) {
                        $anchorVerdicts[$id] = [System.Collections.Generic.Dictionary[int, string]]::new()
                    }
                    # A run that files one id under two verdicts already failed
                    # the wrapper's disjointness check; here it simply cannot be
                    # a single reading, so record the conflict.
                    if ($anchorVerdicts[$id].ContainsKey($run) -and $anchorVerdicts[$id][$run] -cne $verdict) {
                        $anchorVerdicts[$id][$run] = "conflicted"
                    }
                    elseif (-not $anchorVerdicts[$id].ContainsKey($run)) {
                        $anchorVerdicts[$id][$run] = $verdict
                    }
                }
            }
        }

        if (@($distinctRules).Count -gt 1) {
            [void]$disagreements.Add("the runs accounted for different rules in this slot: " +
                (@(@($distinctRules) | ForEach-Object { ($_ -split $script:ReviewerRunReconciliationSeparator)[0] }) -join " vs "))
        }
        if (@($distinctStatuses).Count -gt 1 -or $anyAbsent) {
            [void]$disagreements.Add("the runs read this rule as " + ((@($rawStatuses) | Sort-Object -Unique) -join " / "))
        }
        if ($distinctStatusSet.Contains("(none)")) {
            [void]$disagreements.Add("a run gave this rule no status at all")
        }

        # Now the anchors. Order-independent by construction: the id set is a
        # set, and each id's verdict is the single value every run gave it, or
        # `unknown`.
        $sortedAnchorIds = @($anchorIds)
        [Array]::Sort($sortedAnchorIds, [StringComparer]::Ordinal)
        $anchorRows = [System.Collections.Generic.List[object]]::new()
        $anchorStable = $true
        $normalizedViolating = [System.Collections.Generic.List[string]]::new()
        $normalizedNotInReach = [System.Collections.Generic.List[string]]::new()
        $normalizedWeighed = 0
        $anyAnchorUnknown = $false
        foreach ($id in $sortedAnchorIds) {
            $perRun = [System.Collections.Generic.List[string]]::new()
            $distinct = [System.Collections.Generic.List[string]]::new()
            $distinctSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            for ($i = 0; $i -lt $byRun.Count; $i++) {
                $run = $i + 1
                # A run that never mentioned this anchor gave it no verdict.
                # That is not silence to be filled in from another run; it is
                # exactly the omission the whole partition exists to catch.
                $verdict = $(if ($anchorVerdicts[$id].ContainsKey($run)) { [string]$anchorVerdicts[$id][$run] } else { "unaccounted" })
                [void]$perRun.Add($verdict)
                if ($distinctSet.Add($verdict)) { [void]$distinct.Add($verdict) }
            }
            $settled = (@($distinct).Count -eq 1 -and @($distinct)[0] -cne "conflicted" -and @($distinct)[0] -cne "unaccounted")
            $verdictFor = $(if ($settled) { @($distinct)[0] } else { "unknown" })
            if (-not $settled) {
                $anchorStable = $false
                $sortedDistinct = @($distinct)
                [Array]::Sort($sortedDistinct, [StringComparer]::Ordinal)
                [void]$disagreements.Add("anchor $id read as " + ($sortedDistinct -join " / "))
            }
            switch -CaseSensitive ($verdictFor) {
                "violation" { [void]$normalizedViolating.Add($id); $normalizedWeighed++ }
                "compliant" { $normalizedWeighed++ }
                "notInReach" { [void]$normalizedNotInReach.Add($id) }
                default { $anyAnchorUnknown = $true; $normalizedWeighed++ }
            }
            [void]$anchorRows.Add([pscustomobject][ordered]@{
                    constructId = $id
                    reconciledVerdict = $verdictFor
                    stable = $settled
                    perRunVerdicts = @($perRun.ToArray())
                })
        }

        # The rule's status comes from its anchors, the same way the wrapper
        # derives a row's status from its partition - and collapses outright if
        # the runs could not even agree what word to use, what rule this slot
        # was about, or whether the rule was accounted for at all.
        $statusAgreed = (@($distinctStatuses).Count -le 1 -and -not $anyAbsent -and
            @($distinctRules).Count -le 1 -and -not $distinctStatusSet.Contains("(none)"))
        $stable = [bool]($statusAgreed -and $anchorStable -and @($readings).Count -gt 0)
        $derived = $(if ($anyAnchorUnknown) { "unknown" }
            elseif ($normalizedViolating.Count -gt 0) { "violation" }
            elseif ($normalizedWeighed -eq 0) { "notApplicable" }
            else { "compliant" })
        $reconciledStatus = $(if (-not $stable) { "unknown" }
            elseif (@($distinctStatuses).Count -eq 1 -and @($distinctStatuses)[0] -cne $derived) {
                # Every run said the same word and the anchors say another. The
                # anchors decide, as they do inside a single run.
                [void]$disagreements.Add("every run said $(@($distinctStatuses)[0]) but the reconciled anchors say $derived")
                "unknown"
            }
            else { $derived })
        if ($reconciledStatus -cne $derived -or -not $stable) { $stable = $false }
        if ($stable) { $stableCount++ } else { $unstableCount++ }
        [void]$rows.Add([pscustomobject][ordered]@{
                ruleSourceId = $(if (@($distinctRules).Count -eq 1) { (@($distinctRules)[0] -split $script:ReviewerRunReconciliationSeparator)[0] } else { "" })
                ruleRef = $key
                reconciledStatus = $reconciledStatus
                stable = $stable
                rawStatuses = @($rawStatuses.ToArray())
                disagreements = @($disagreements.ToArray())
                readings = @($readings.ToArray())
                anchors = @($anchorRows.ToArray())
                violatingConstructs = @($(if ($stable) { $normalizedViolating.ToArray() } else { @() }))
                notInReachConstructs = @($(if ($stable) { $normalizedNotInReach.ToArray() } else { @() }))
            })
    }

    # Candidates. A proposed comment is only worth showing if every run of the
    # same input proposed it. One run out of two is a coin toss with a citation.
    #
    # A MULTISET per run, not a set. Two candidates can legitimately share the
    # anchor key - `prMetadata` candidates are all forced to file "" line 0, so
    # any two under one rule collide exactly - and a set silently dropped the
    # second. The dropped one was then neither agreed nor withheld: it did not
    # appear at all, and a run that proposed an extra important finding read as
    # fully agreeing with a run that did not.
    $candidateKeys = [System.Collections.Generic.List[string]]::new()
    # Ordinal, NOT [ordered]. An OrderedDictionary compares keys
    # case-insensitively, and `filePath` is model-authored and stored verbatim -
    # so `/src/Widget.cs` and `/src/widget.cs` collided, two disagreeing runs
    # read as agreed, and the surviving row printed one run's path beside the
    # other run's comment. Insertion order is not relied on; both key lists are
    # re-sorted ordinally below.
    $candidateFields = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $seenCandidateKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $candidatesByRun = [System.Collections.Generic.List[object]]::new()
    foreach ($manifest in $runs) {
        $index = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($candidate in @(Get-ReviewerRunReconciliationValue $manifest "candidates" @())) {
            $identity = Get-ReviewerRunReconciliationCandidateKey -Candidate $candidate
            $key = [string]$identity.Key
            if (-not $index.ContainsKey($key)) { $index[$key] = [System.Collections.Generic.List[object]]::new() }
            [void]$index[$key].Add($candidate)
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
        $counts = [System.Collections.Generic.List[int]]::new()
        $texts = [System.Collections.Generic.List[string]]::new()
        $textSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $severities = [System.Collections.Generic.List[string]]::new()
        $severitySet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $example = $null
        for ($i = 0; $i -lt $candidatesByRun.Count; $i++) {
            $bucket = $(if ($candidatesByRun[$i].ContainsKey($key)) { $candidatesByRun[$i][$key] } else { $null })
            $count = $(if ($null -eq $bucket) { 0 } else { $bucket.Count })
            [void]$counts.Add($count)
            if ($count -gt 0) {
                [void]$present.Add($i + 1)
                if ($null -eq $example) { $example = $bucket[0] }
                # The COMMENT and the SEVERITY are the claim. Two runs that
                # point at one line and say different things about it have not
                # agreed on a comment; showing one run's wording under the
                # `agreed` label is choosing whose review this is.
                foreach ($item in @($bucket)) {
                    $severity = [string](Get-ReviewerRunReconciliationValue $item "severity" "")
                    if ($severitySet.Add($severity)) { [void]$severities.Add($severity) }
                    $text = Get-ReviewerConventionSpecialistSha256 `
                        -Text (([string](Get-ReviewerRunReconciliationValue $item "comment" "")).Trim())
                    if ($textSet.Add($text)) { [void]$texts.Add($text) }
                }
            }
            else { [void]$absent.Add($i + 1) }
        }
        $sortedCounts = @($counts.ToArray())
        $sameCount = ((@($sortedCounts | Sort-Object -Unique)).Count -le 1)
        $inEveryRun = ($absent.Count -eq 0 -and $sameCount -and
            @($severities).Count -le 1 -and @($texts).Count -le 1)
        if ($inEveryRun) { $agreedCandidateCount++ }
        $disposition = $(if ($inEveryRun) { "agreed" }
            elseif ($absent.Count -gt 0) { "withheldRunDisagreement" }
            elseif (-not $sameCount) { "withheldCountDisagreement" }
            elseif (@($severities).Count -gt 1) { "withheldSeverityDisagreement" }
            else { "withheldTextDisagreement" })
        $identity = $candidateFields[$key]
        [void]$candidates.Add([pscustomobject][ordered]@{
                key = $key
                ruleSourceId = [string]$identity.RuleSourceId
                anchorKind = [string]$identity.AnchorKind
                filePath = [string]$identity.FilePath
                line = [string]$identity.Line
                presentInRuns = @($present.ToArray())
                absentInRuns = @($absent.ToArray())
                perRunCounts = @($counts.ToArray())
                distinctSeverities = @($severities.ToArray())
                distinctCommentCount = @($texts).Count
                inEveryRun = $inEveryRun
                disposition = $disposition
                severity = [string](Get-ReviewerRunReconciliationValue $example "severity" "")
                comment = [string](Get-ReviewerRunReconciliationValue $example "comment" "")
            })
    }

    # A run count below what the operator asked for is not a pass with a caveat.
    # It is an unreconciled observation, and it says so.
    $enoughRuns = ($runs.Count -ge $RequiredRunCount)
    if (-not $enoughRuns) {
        Add-ReviewerRunReconciliationProblem -Problems $problems -Code "tooFewRuns" -Runs @() -Text "only $($runs.Count) run(s) supplied; $RequiredRunCount are required before any status may be called stable"
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
            # The ANCHORS too. Leaving them settled meant a refused comparison
            # printed "1 settled, 0 unsettled" directly under "Reconciled:
            # False", and a machine consumer reading rows[].anchors saw a
            # settled violation nobody was entitled to.
            foreach ($anchor in @($row.anchors)) {
                $anchor.reconciledVerdict = "unknown"
                $anchor.stable = $false
            }
        }
        foreach ($candidate in $candidates) {
            if ($candidate.disposition -ceq "agreed") { $candidate.disposition = "withheldUnreconciled" }
            $candidate.inEveryRun = $false
        }
        $stableCount = 0
        $unstableCount = @($rows).Count
        $agreedCandidateCount = 0
    }

    $result = [pscustomobject][ordered]@{
        kind = $script:ReviewerRunReconciliationKind
        version = $script:ReviewerRunReconciliationVersion
        reconciled = $reconciled
        promotable = $false
        runCount = $runs.Count
        requiredRunCount = $RequiredRunCount
        inputBindingSha256 = [string]$binding
        problems = [string[]](Get-ReviewerRunReconciliationProblemText -Problems $problems)
        runs = @($runSummaries.ToArray())
        stableRowCount = $stableCount
        unstableRowCount = $unstableCount
        rows = @($rows.ToArray())
        agreedCandidateCount = $agreedCandidateCount
        candidates = @($candidates.ToArray())
    }
    # A digest over the OUTCOME, not the inputs, and specifically not over
    # anything that carries the order the runs were listed in. Two operators who
    # reconcile the same sealed runs must be able to compare one hex string and
    # know they read the same thing.
    $sortedNonces = @(@($runSummaries.ToArray()) | ForEach-Object { [string]$_.replayNonce })
    [Array]::Sort($sortedNonces, [StringComparer]::Ordinal)
    $sortedProblems = @(@($problems.ToArray()) | ForEach-Object {
            # Problems name runs by POSITION, which is the one thing that
            # changes when an operator lists the same runs the other way round.
            # For the digest, rewrite each position as the run's own nonce.
            $text = [string]$_
            for ($i = @($runSummaries.ToArray()).Count; $i -ge 1; $i--) {
                $nonce = [string]@($runSummaries.ToArray())[$i - 1].replayNonce
                $text = $text.Replace("run $i", "run:" + $(if ($nonce) { $nonce } else { "unidentified" }))
            }
            $text
        })
    [Array]::Sort($sortedProblems, [StringComparer]::Ordinal)
    $orderFree = [ordered]@{
        version = $script:ReviewerRunReconciliationVersion
        reconciled = $reconciled
        binding = [string]$binding
        runNonces = @($sortedNonces)
        problems = @($sortedProblems)
        rules = @(@($rows.ToArray()) | ForEach-Object {
                [ordered]@{
                    ruleRef = [string]$_.ruleRef
                    ruleSourceId = [string]$_.ruleSourceId
                    status = [string]$_.reconciledStatus
                    stable = [bool]$_.stable
                    anchors = @(@($_.anchors) | ForEach-Object {
                            [ordered]@{ id = [string]$_.constructId; verdict = [string]$_.reconciledVerdict; stable = [bool]$_.stable }
                        })
                }
            })
        candidates = @(@($candidates.ToArray()) | ForEach-Object {
                [ordered]@{
                    rule = [string]$_.ruleSourceId; path = [string]$_.filePath
                    line = [string]$_.line; disposition = [string]$_.disposition
                }
            })
    }
    $result | Add-Member -NotePropertyName reconciliationSha256 `
        -NotePropertyValue (Get-ReviewerConventionSpecialistSha256 `
            -Text (ConvertTo-ReviewerConventionSpecialistCanonicalJson -Value $orderFree)) -Force
    return $result
}

function Format-ReviewerRunReconciliationReport {
    param([Parameter(Mandatory)]$Reconciliation)
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("# Cross-run reconciliation (evaluation only - never promotable)")
    [void]$lines.Add("")
    [void]$lines.Add("Runs compared: $([int]$Reconciliation.runCount) (required: $([int]$Reconciliation.requiredRunCount))")
    [void]$lines.Add("Input binding: $([string]$Reconciliation.inputBindingSha256)")
    [void]$lines.Add("Reconciliation digest: $([string]$Reconciliation.reconciliationSha256)")
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
        $unsettled = @(@($row.anchors) | Where-Object { -not [bool]$_.stable })
        if (@($row.anchors).Count -gt 0) {
            [void]$lines.Add($(if ([bool]$Reconciliation.reconciled) {
                        "- Anchors: $(@($row.anchors).Count) enumerated by the runs, $(@($row.anchors).Count - $unsettled.Count) settled, $($unsettled.Count) unsettled"
                    }
                    else {
                        # Not "0 settled" as an arithmetic fact - "none settled",
                        # because the comparison was refused and settling was
                        # never on the table.
                        "- Anchors: $(@($row.anchors).Count) enumerated by the runs; none settled, because this is not a reconciliation"
                    }))
        }
        foreach ($anchor in @($unsettled | Select-Object -First 24)) {
            [void]$lines.Add("  - $([string]$anchor.constructId): $((@($anchor.perRunVerdicts)) -join ' / ') -> $([string]$anchor.reconciledVerdict)")
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
