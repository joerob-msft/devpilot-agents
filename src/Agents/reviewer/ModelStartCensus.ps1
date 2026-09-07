#Requires -Version 7.0

<#
.SYNOPSIS
    Counts the model subprocess starts a reviewer run ACTUALLY made, by role, and
    bounds the starts a reviewer run COULD make from the plan it was sealed with.

.DESCRIPTION
    Two answers to two different questions, kept in one file because they are the
    two halves of one accounting and must not drift apart:

      Get-ReviewerModelStartCensus  - what a finished run cost, read from that
                                      run's own published per-attempt evidence.
      Get-ReviewerModelStartBound   - the most a run under a given sealed plan
                                      could cost, read from the runner's own
                                      attempt and verifier bounds.

    Both are censuses of evidence, never estimates dressed as measurements, and
    both refuse rather than return a comfortable number they cannot support.

    WHY THIS FILE EXISTS. A cohort used to add up a per-slot figure named
    'modelInvocationCount' that was in fact a census of slot ATTEMPT RECORDS -
    one file per reviewer process, whatever that process then spent. A two-slot
    entry that started four real models (a generalist pair per slot) was
    therefore accounted as three, and would have been accounted as three had it
    started forty: a specialist launch and every cross-verifier launch were
    invisible to it. A budget computed over that figure is not a budget. This
    file counts the thing that costs money - one record per model subprocess the
    run actually started - and names it so that it can never again be confused
    with a count of reviewer processes.

    WHAT IS COUNTED. Exactly one start per published per-attempt record, per
    role:

      generalist  one 'model-attempt-accounting' record per attempt, which the
                  runner emits for every ACTUAL attempt including each retry.
      specialist  one 'specialist-attempt-accounting' record per attempt, on the
                  same terms.
      verifier    one distinct launch nonce per cross-verifier invocation, read
                  from the sealed verification decision preview. Assignments are
                  GROUPED - one launch serves every candidate in its cluster - so
                  forty assignments may be four processes, and it is the four
                  that this counts. The runner has no verifier retry loop, so a
                  launch is an attempt.

    WHAT IS NOT COUNTED, AND SAID SO. A start whose attempt record was never
    published - a child killed between the launch and the record - cannot be
    seen from the artifacts, because the evidence it would have left does not
    exist. That is a bounded and visible hole: the slot it happened in cannot
    have ended 'complete', so the entry carrying it is not a successful entry,
    and the census reports the basis it counted on rather than implying it saw
    everything. A pre-launch refusal is deliberately NOT counted: the runner
    emits no attempt record for a contract-fit refusal, because no process
    started and nothing was spent.

    NOTHING HERE READS A FINDING. Every record consulted is consulted for its
    role, its attempt number and its launch nonce hash. No severity, no verdict,
    no candidate text and no model output is read, and the model names that do
    appear are carried as opaque strings for the diagnostic breakdown only -
    nothing in this file compares one to a list or branches on which model ran.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ModelStartCensusManifest.ps1')

# How a census treats evidence it cannot authenticate. 'require' - the default,
# and the only value a budget should ever run under - reports an unauthenticated
# run INCOMPLETE, so the caller stops rather than budgeting against numbers
# nobody can vouch for. 'report' publishes the same verdict without letting it
# decide completeness, and exists so that a survey of historical runs sealed
# before authentication existed can say how many of them are unverifiable
# instead of failing to load at all.
#
# Neither mode ever lowers a count. Authentication decides whether a number may
# be RELIED ON, never what the number is; an unverified run is blocked, not
# cheap.
$script:ReviewerCensusAuthenticationModes = @('require', 'report')

# The three roles a reviewer run can start a model in. Fixed here so that a
# breakdown always carries all three keys: a role that did not run must report a
# zero it measured, never a key a reader has to guess the absence of.
$script:ReviewerModelStartRoles = @('generalist', 'specialist', 'verifier')

# The per-attempt record kinds the runner publishes, by role. These are the
# runner's own 'mode' words, matched case-sensitively and in full: a prefix match
# would fold 'model-attempt-accounting' together with any later record that
# happened to start the same way.
$script:ReviewerGeneralistAttemptMode = 'model-attempt-accounting'
$script:ReviewerSpecialistAttemptMode = 'specialist-attempt-accounting'
$script:ReviewerVerifierAttemptMode = 'verifier-attempt-accounting'

# The record the runner publishes in the last statement before a model
# subprocess can exist. It is the only witness of a launch whose accounting
# record was never reached - the harness raises telemetry, drains two output
# streams and writes standard input AFTER the process has been created, and any
# of those can throw into a handler that degrades. An intent without its
# accounting record is a start that happened and was never accounted for.
$script:ReviewerModelLaunchIntentMode = 'model-launch-intent'

# The nonce hash a verifier run record carries when nothing was launched for it -
# a budget preflight refusal marks every planned assignment degraded and writes
# this placeholder rather than inventing a nonce. Counting it would count a
# process that never started.
$script:ReviewerUnlaunchedVerifierNonce = ('0' * 64)

function New-ReviewerModelStartBreakdown {
    <#
    .SYNOPSIS
        A zeroed role breakdown, so every reader sees the same three keys.
    #>
    param()
    $breakdown = [ordered]@{}
    foreach ($role in @($script:ReviewerModelStartRoles)) {
        $breakdown[$role] = 0
    }
    return [pscustomobject]$breakdown
}

function Test-ReviewerModelStartArgvSwitch {
    <#
    .SYNOPSIS
        Whether a sealed argument vector carries one exact switch.
    .DESCRIPTION
        Case-sensitive and whole-token: '-EnableVerificationPreview' is not
        matched by a longer argument that contains it, and a value that happens
        to equal a switch name cannot be found by this because the caller passes
        the whole vector and a value sits in its own slot. The vector is the one
        the plan digest seals, so what is read here is what was authorized.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv,
        [Parameter(Mandatory)][string]$Name
    )
    foreach ($argument in @($Argv)) {
        if ([string]$argument -ceq $Name) {
            return $true
        }
    }
    return $false
}

# How much cycle log this census will read. See the refusal in
# Get-ReviewerModelStartLogRecord: 64 MB is orders of magnitude above what a real
# run writes, so it bounds a hostile or runaway log without ever being reachable
# by an honest one.
$script:ReviewerModelStartLogMaxBytes = 64MB

function Get-ReviewerModelStartLogRecord {
    <#
    .SYNOPSIS
        Every record in one run's cycle log, or a refusal.
    .DESCRIPTION
        The log is read once, as bytes, and every non-blank line must parse. A
        line that does not parse is a truncated or edited log, and a census that
        skipped it would report a number smaller than the run's own evidence
        supports while looking exactly like a clean count.
    #>
    param([Parameter(Mandatory)][string]$LogPath)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        throw ("The reviewer cycle log '$LogPath' does not exist, so the model starts this run made cannot be counted. " +
            'An absent log is not a zero.')
    }
    # A CEILING, NOT A BUDGET. The whole log is held in memory and parsed line by
    # line, and this function is now called more than once per audit, so a log
    # large enough to exhaust the auditing process would stop the census - and a
    # census that never finishes is a cohort that never accounts for its spend.
    # The bound is set far above what a real run produces (a few thousand records
    # of a few hundred bytes) so that no honest run can reach it, and crossing it
    # is a REFUSAL rather than a truncation: reading part of a log and counting
    # what is in it is exactly the undercount this unit exists to prevent.
    $length = [long]([IO.FileInfo]::new($LogPath)).Length
    if ($length -gt $script:ReviewerModelStartLogMaxBytes) {
        throw ("The reviewer cycle log '$LogPath' is $length bytes, beyond the " +
            "$($script:ReviewerModelStartLogMaxBytes)-byte bound this census reads. A log that cannot be read in " +
            'full is refused rather than counted in part.')
    }
    $text = ''
    try {
        $text = [IO.File]::ReadAllText($LogPath, [Text.UTF8Encoding]::new($false, $true))
    }
    catch {
        throw "The reviewer cycle log '$LogPath' could not be read as UTF-8 text: $($_.Exception.Message)"
    }
    $records = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in @($text -split "`n")) {
        $lineNumber++
        $trimmed = ([string]$line).Trim()
        if ($trimmed.Length -eq 0) { continue }
        $record = $null
        try {
            $record = $trimmed | ConvertFrom-Json -Depth 32
        }
        catch {
            throw ("The reviewer cycle log '$LogPath' carries an unparsable record at line $lineNumber. " +
                'A census is refused rather than taken over a log this build cannot read in full.')
        }
        if ($null -eq $record) { continue }
        [void]$records.Add($record)
    }
    return $records.ToArray()
}

function Measure-ReviewerModelStartAttemptRecord {
    <#
    .SYNOPSIS
        How many of a run's log records are per-attempt records of one mode that
        actually launched a subprocess.
    .DESCRIPTION
        A record whose 'processStarted' is explicitly false is a refusal that
        happened BEFORE any launch - an input refused for size, for instance -
        and nothing was spent on it. Counting it would spend a budget on a
        process that never existed and could retire a cohort early.

        A record that carries no 'processStarted' at all is counted, because a
        run published by a build that predates the field cannot prove it did not
        launch, and the only safe direction for a ceiling is upward.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][string]$Mode
    )
    $count = 0
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        if (-not $record.PSObject.Properties['mode']) { continue }
        if ([string]$record.mode -cne $Mode) { continue }
        if ($record.PSObject.Properties['processStarted'] -and -not [bool]$record.processStarted) { continue }
        $count++
    }
    return [int]$count
}

function Measure-ReviewerModelLaunchIntent {
    <#
    .SYNOPSIS
        How many launch intents one run published for one role.
    .DESCRIPTION
        An intent is written immediately before the create call and nothing
        between the two can fail, so this is a floor on the subprocesses that
        role really started. It is compared against the accounting records
        rather than added to them: a launch that completed normally publishes
        both, and counting both would double every start.

        A build that publishes no intents at all reports zero here and is
        measured by its accounting records alone, exactly as before.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][string]$CensusRole
    )
    $count = 0
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        if (-not $record.PSObject.Properties['mode']) { continue }
        if ([string]$record.mode -cne $script:ReviewerModelLaunchIntentMode) { continue }
        if (-not $record.PSObject.Properties['censusRole']) { continue }
        if ([string]$record.censusRole -cne $CensusRole) { continue }
        $count++
    }
    return [int]$count
}

function Get-ReviewerVerifierLaunchNonce {
    <#
    .SYNOPSIS
        The distinct launch nonces the sealed verification previews record.
    .DESCRIPTION
        One nonce is minted per cross-verifier invocation and repeated onto every
        assignment that invocation served, so the distinct non-placeholder nonces
        across a run's previews are its verifier launches. Counting assignment
        records instead would multiply one process by the number of candidates it
        was given - the exact over-count that grouping exists to avoid - and
        counting previews would collapse several launches into one.

        Reads the signed envelope's manifest text only. It does not verify the
        signature: this is a census of a run's own artifacts inside that run's
        own state directory, and the coordinator that consumes the census signs
        the audit the number is published in.
    #>
    param([Parameter(Mandatory)][string]$RunRoot)
    $directory = Join-Path $RunRoot 'verification-previews'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return [pscustomobject][ordered]@{
            evidencePresent = $false
            launchCount = 0
            previewCount = 0
            previewSnapshot = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        }
    }
    $previews = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name | ForEach-Object { [string]$_.FullName })
    $nonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    # WHAT IS COUNTED MUST BE WHAT IS AUTHENTICATED, here for the same reason it
    # is in the assignment census: each preview is read into bytes exactly once,
    # and the caller hands this snapshot to the authenticity check so it verifies
    # these bytes rather than whatever is on disk by the time it runs. Reading
    # twice would let a writer present a thinner preview to the counting read and
    # restore the attested bytes before the hashing read.
    $previewSnapshot = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($path in @($previews)) {
        [byte[]]$previewBytes = $null
        try { $previewBytes = [IO.File]::ReadAllBytes($path) }
        catch {
            throw ("The sealed verification preview '$path' could not be read: $($_.Exception.Message) " +
                'The verifier launches of a run whose preview cannot be read are not counted as none.')
        }
        [string]$previewText = ''
        try { $previewText = ([Text.UTF8Encoding]::new($false, $true)).GetString($previewBytes) }
        catch {
            throw ("The sealed verification preview '$path' is not the UTF-8 its run wrote: $($_.Exception.Message) " +
                'The verifier launches of a run whose preview cannot be read are not counted as none.')
        }
        $previewSnapshot[[string](Split-Path -Leaf $path)] = [pscustomobject][ordered]@{
            sha256 = [string]([Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($previewBytes))).ToLowerInvariant()
            text = $previewText
        }
        $envelope = $null
        try {
            $envelope = $previewText | ConvertFrom-Json -Depth 64
        }
        catch {
            throw ("The sealed verification preview '$path' could not be read: $($_.Exception.Message) " +
                'The verifier launches of a run whose preview cannot be read are not counted as none.')
        }
        if ($null -eq $envelope -or -not $envelope.PSObject.Properties['manifestJson']) {
            throw "The sealed verification preview '$path' carries no manifest, so its verifier launches cannot be counted."
        }
        $manifest = $null
        try {
            $manifest = [string]$envelope.manifestJson | ConvertFrom-Json -Depth 64
        }
        catch {
            throw "The sealed verification preview '$path' carries a manifest this build cannot parse."
        }
        if ($null -eq $manifest -or -not $manifest.PSObject.Properties['verifierRuns']) {
            throw ("The sealed verification preview '$path' publishes no 'verifierRuns', so the launches it stands on " +
                'cannot be counted.')
        }
        foreach ($run in @($manifest.verifierRuns)) {
            if ($null -eq $run) { continue }
            if (-not $run.PSObject.Properties['nonceSha256']) {
                throw ("A verifier run record in '$path' carries no launch nonce, so the launch it describes cannot " +
                    'be told apart from any other.')
            }
            $nonce = [string]$run.nonceSha256
            if ($nonce.Length -eq 0 -or $nonce -ceq $script:ReviewerUnlaunchedVerifierNonce) { continue }
            [void]$nonces.Add($nonce)
        }
    }
    return [pscustomobject][ordered]@{
        evidencePresent = $true
        launchCount = [int]$nonces.Count
        previewCount = [int]@($previews).Count
        previewSnapshot = $previewSnapshot
    }
}

function Get-ReviewerVerifierAssignmentCensus {
    <#
    .SYNOPSIS
        The cross-verifier ASSIGNMENTS one reviewer run actually stood on, by
        verifier model.

    .DESCRIPTION
        A second census, of a second unit, kept beside the model-start census
        because the two are routinely confused and must never again be added to
        each other.

        WHAT AN ASSIGNMENT IS. The verification contract's own identity: one
        candidate paired with one required reciprocal verifier model. The
        reviewed side mints it as 'assignmentId' - a digest over the cluster, the
        candidate hash and the target model - and requires exactly one assignment
        per candidate per required model. So a run with eleven ready candidates
        and two required models has twenty-two assignments, whatever the number
        of processes that then served them.

        WHY IT IS NOT A COUNT OF PROCESSES. Assignments are GROUPED: one launch
        can serve every candidate in its cluster. Counting processes therefore
        under-reports the work a verification phase was asked to do, and counting
        terminal states - which is what the defect this replaces did - reports a
        number bounded by the number of states the walk has, so forty assignments
        and four assignments both came out as four. The grouped process starts
        are still counted here, separately and by a name that says what they are,
        because they are a useful diagnostic and a useless budget.

        WHAT IS READ. The run's own sealed verification previews, and only their
        'assignments' arrays. Distinct assignment ids across every preview, so a
        run that seals more than one preview - a retry that re-seals, a phase
        that seals in parts - is counted once per distinct assignment rather than
        once per appearance. Nothing here reads a decision, a verdict, a severity
        or any candidate text; the verifier model names are carried as opaque
        strings for the breakdown and are compared to no list.

        WHAT IS REFUSED. A preview that cannot be read, carries no manifest,
        publishes no 'assignments', or carries an assignment without an id or
        without a verifier model. None of those is a zero: a run whose evidence
        cannot be read has an unknown assignment count, and the caller must stop
        rather than budget against it.

    .PARAMETER RunRoot
        The run's own directory - '<slot state dir>/replay/<snapshot name>'.

    .PARAMETER Argv
        The sealed argument vector, which says whether the run was authorized to
        verify at all. A run never authorized is complete with zero; a run
        authorized that left no preview is incomplete.

    .PARAMETER MasterKey
        The run's artifact signing key. Without it the previews read here are
        believed for their shape alone, which is what this census no longer does.

    .PARAMETER AuthenticationMode
        'require' (default) reports an unauthenticated run incomplete. 'report'
        publishes the verdict without letting it decide completeness.

    .PARAMETER ExpectedRunExecutionId
        The execution this census was asked to audit, supplied from OUTSIDE the
        run root. A manifest sealed by any other execution - an earlier, cheaper
        run in the same re-used directory, for instance - is refused.

    .PARAMETER CorroborateExecutionFromRecords
        The explicit alternative for a caller that cannot know the execution it
        is auditing: the manifest is corroborated against the execution stamped
        on the accounting records under this run root. Weaker, and stated in the
        call rather than reached by omitting a parameter. One of the two is
        required; there is no silent third behaviour.
    #>
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv,
        [byte[]]$MasterKey,
        [AllowEmptyString()][string]$ExpectedRunExecutionId = '',
        [switch]$CorroborateExecutionFromRecords,
        [ValidateSet('require', 'report')][string]$AuthenticationMode = 'require'
    )
    if (-not (Test-Path -LiteralPath $RunRoot -PathType Container)) {
        throw ("The run root '$RunRoot' does not exist, so the verifier assignments made under it cannot be counted. " +
            'A missing run root is refused rather than counted as a run that verified nothing.')
    }
    $verificationEnabled = Test-ReviewerModelStartArgvSwitch -Argv @($Argv) -Name '-EnableVerificationPreview'
    $directory = Join-Path $RunRoot 'verification-previews'
    $evidencePresent = [bool](Test-Path -LiteralPath $directory -PathType Container)
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $nonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $byModel = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    # Which verifier model each identity was minted against. An identity is a
    # digest over the cluster, the candidate and the model, so the same id under
    # two models cannot both be true and one of the two previews is wrong about
    # what was assigned.
    $idModel = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $previewCount = 0
    $evidenceLostPreviewCount = 0
    # The bytes of every preview this census actually counted, by name. Handed to
    # the authenticity check so it verifies these bytes rather than whatever is on
    # disk by the time it runs.
    $previewSnapshot = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($evidencePresent) {
        $previews = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property Name | ForEach-Object { [string]$_.FullName })
        $previewCount = [int]@($previews).Count
        # WHAT IS COUNTED MUST BE WHAT IS AUTHENTICATED. Each preview is read
        # into bytes exactly once here, and both the parse below and the digest
        # the authenticity check later compares against the sealed manifest come
        # from that single buffer. Reading twice - once to count, once to hash -
        # would let a writer present a preview with fewer assignments to the
        # counting read and restore the genuine attested bytes before the
        # hashing read, producing a signed, self-consistent UNDERCOUNT. That is
        # the one direction this census must never be pushed in.
        foreach ($path in @($previews)) {
            [byte[]]$previewBytes = $null
            try { $previewBytes = [IO.File]::ReadAllBytes($path) }
            catch {
                throw ("The sealed verification preview '$path' could not be read: $($_.Exception.Message) " +
                    'The verifier assignments of a run whose preview cannot be read are not counted as none.')
            }
            [string]$previewText = ''
            try { $previewText = ([Text.UTF8Encoding]::new($false, $true)).GetString($previewBytes) }
            catch {
                throw ("The sealed verification preview '$path' is not the UTF-8 its run wrote: $($_.Exception.Message) " +
                    'The verifier assignments of a run whose preview cannot be read are not counted as none.')
            }
            $previewSnapshot[[string](Split-Path -Leaf $path)] = [pscustomobject][ordered]@{
                sha256 = [string]([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData($previewBytes))).ToLowerInvariant()
                text = $previewText
            }
            $envelope = $null
            try {
                $envelope = $previewText | ConvertFrom-Json -Depth 64
            }
            catch {
                throw ("The sealed verification preview '$path' could not be read: $($_.Exception.Message) " +
                    'The verifier assignments of a run whose preview cannot be read are not counted as none.')
            }
            if ($null -eq $envelope -or -not $envelope.PSObject.Properties['manifestJson']) {
                throw "The sealed verification preview '$path' carries no manifest, so its verifier assignments cannot be counted."
            }
            $manifest = $null
            try {
                $manifest = [string]$envelope.manifestJson | ConvertFrom-Json -Depth 64
            }
            catch {
                throw "The sealed verification preview '$path' carries a manifest this build cannot parse."
            }
            if ($null -eq $manifest -or -not $manifest.PSObject.Properties['assignments']) {
                throw ("The sealed verification preview '$path' publishes no 'assignments', so the verifier work it " +
                    'stands on cannot be counted.')
            }
            if ($null -eq $manifest.assignments) {
                throw ("The sealed verification preview '$path' publishes a null 'assignments', which is not the same as " +
                    'a run that was assigned nothing and is not counted as one.')
            }
            # Whether this preview is a complete record of what the phase was
            # assigned, judged on the RECORD and never on the review's own
            # conclusion. The seal reports 'degraded' for four ordinary reasons -
            # a verifier invocation that timed out, a degraded specialist, a
            # degraded convention plan, a withheld authoritative source - and in
            # every one of them the full assignment list is still sealed. Reading
            # that word as lost evidence would stop a whole cohort on a run that
            # measured perfectly.
            #
            # What does distinguish the reviewed side's evidence-loss writer is
            # the tuple it is forced to pass: a non-empty diagnostic, an empty
            # input artifact path and an all-zero input manifest digest. It is
            # the only caller that can produce any of the three, and it is the
            # one that seals an EMPTY assignment list and lets the run end
            # normally.
            foreach ($required in @('diagnostic', 'inputArtifactPath', 'inputManifestSha256')) {
                if (-not $manifest.PSObject.Properties[$required] -or $null -eq $manifest.$required) {
                    throw ("The sealed verification preview '$path' publishes no '$required', so this build cannot tell a " +
                        'complete record of what the phase was assigned from one that lost it.')
                }
            }
            $previewDiagnostic = [string]$manifest.diagnostic
            $previewInputPath = [string]$manifest.inputArtifactPath
            $previewInputDigest = [string]$manifest.inputManifestSha256
            if ($previewInputDigest -cnotmatch '^[0-9a-f]{64}$') {
                throw ("The sealed verification preview '$path' carries an input manifest digest that is not a lowercase " +
                    'SHA-256, so the record it stands on cannot be identified.')
            }
            if ($previewDiagnostic.Length -gt 0 -or $previewInputPath.Length -eq 0 -or
                $previewInputDigest -ceq ('0' * 64)) {
                $evidenceLostPreviewCount++
            }
            $previewAssignmentRowCount = 0
            $previewNonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($assignment in @($manifest.assignments)) {
                if ($null -eq $assignment) {
                    throw ("The sealed verification preview '$path' carries a null entry among its assignments, so the " +
                        'set it publishes cannot be told apart from a shorter one.')
                }
                if (-not $assignment.PSObject.Properties['assignmentId']) {
                    throw ("A verifier assignment in '$path' carries no 'assignmentId', so it cannot be told apart " +
                        'from any other and the run''s assignment count is unknown.')
                }
                if (-not $assignment.PSObject.Properties['verifierModel']) {
                    throw ("A verifier assignment in '$path' names no 'verifierModel', so the reciprocal breakdown " +
                        'this census publishes cannot be taken over it.')
                }
                $id = [string]$assignment.assignmentId
                if ($id.Length -eq 0) {
                    throw "A verifier assignment in '$path' carries an empty 'assignmentId'."
                }
                if ($id -cnotmatch '^va1:[0-9a-f]{64}$') {
                    throw ("A verifier assignment in '$path' carries the identity '$id', which is not the " +
                        'digest-over-cluster-candidate-and-model shape the reviewed side mints. A census cannot count ' +
                        'identities it cannot recognise.')
                }
                $model = [string]$assignment.verifierModel
                if ($model.Length -eq 0) {
                    throw "A verifier assignment in '$path' names an empty 'verifierModel'."
                }
                # Counted per row, before the cross-preview dedupe, because this
                # is what THIS pass published and it is what this pass's launches
                # are measured against.
                $previewAssignmentRowCount++
                if ($idModel.ContainsKey($id)) {
                    if ([string]$idModel[$id] -cne $model) {
                        throw ("The assignment '$id' is published in '$path' against verifier model '$model' and elsewhere " +
                            "against '$([string]$idModel[$id])'. An assignment identity is a digest over the model it names, " +
                            'so the two cannot both be true and the run''s assignment set is unknown.')
                    }
                    continue
                }
                $idModel[$id] = $model
                [void]$ids.Add($id)
                if ($byModel.ContainsKey($model)) { $byModel[$model] = [int]$byModel[$model] + 1 }
                else { $byModel[$model] = 1 }
            }
            # The grouped launches the same previews record, kept apart. One
            # nonce is minted per cross-verifier invocation and repeated onto
            # every assignment it served, so this is the process census and never
            # the assignment census.
            if ($manifest.PSObject.Properties['verifierRuns']) {
                foreach ($run in @($manifest.verifierRuns)) {
                    if ($null -eq $run) { continue }
                    if (-not $run.PSObject.Properties['nonceSha256']) { continue }
                    $nonce = [string]$run.nonceSha256
                    if ($nonce.Length -eq 0 -or $nonce -ceq $script:ReviewerUnlaunchedVerifierNonce) { continue }
                    [void]$nonces.Add($nonce)
                    [void]$previewNonces.Add($nonce)
                }
            }
            # Within ONE pass a launch is grouped by cluster and model and its
            # nonce is stamped onto every assignment it served, so a pass can
            # never mint more distinct launches than it published assignment
            # rows. Deliberately checked per preview and never over the run's
            # totals: identities are content digests and dedupe across passes
            # while nonces are minted fresh, so a re-verification of the same
            # candidates legitimately leaves the totals with more launches than
            # assignments.
            if ($previewNonces.Count -gt $previewAssignmentRowCount) {
                throw ("The sealed verification preview '$path' records $($previewNonces.Count) distinct verifier " +
                    "launch(es) against $previewAssignmentRowCount assignment row(s). One pass stamps each launch onto " +
                    'the assignments it served, so that preview contradicts itself.')
            }
        }
    }

    $complete = $true
    $incompleteReason = ''
    if ($verificationEnabled -and -not $evidencePresent) {
        $complete = $false
        $incompleteReason = ('The run was authorized to cross-verify and published no verification preview, so the ' +
            'assignments it may have stood on cannot be counted.')
    }
    elseif ($verificationEnabled -and $previewCount -eq 0) {
        $complete = $false
        $incompleteReason = ('The run was authorized to cross-verify and its preview directory holds nothing. The ' +
            'directory is created before any review work happens, so its existence witnesses nothing.')
    }
    elseif ($verificationEnabled -and $evidenceLostPreviewCount -gt 0) {
        # The dangerous case, and the reason completeness is not judged on the
        # file's existence. The reviewed side's fault path seals a preview with
        # an EMPTY assignment list and returns normally, so the run still ends
        # cleanly while the only witness to what it was assigned is gone.
        # Charged as unmeasured rather than measured at zero. Counted over EVERY
        # preview, not merely required of one: a run that sealed a good pass and
        # then lost the next one is exactly as unmeasured as one that lost its
        # only pass.
        $complete = $false
        $incompleteReason = ("The run sealed $evidenceLostPreviewCount verification preview(s) that record a lost " +
            'cross-verification rather than a set of assignments, so what those passes stood on is unknown rather ' +
            'than none.')
    }
    $breakdown = [System.Collections.Generic.List[object]]::new()
    foreach ($model in @([string[]]@($byModel.Keys) | Sort-Object -CaseSensitive)) {
        [void]$breakdown.Add([pscustomobject][ordered]@{
                verifierModel = [string]$model
                assignmentCount = [int]$byModel[$model]
            })
    }
    # Same rule as the start census: authenticity can block, never discount. The
    # assignment identities counted above stay exactly as counted; what an
    # unauthenticated run loses is the right to be called a complete measurement.
    #
    # The accounting records are read here even though this census counts
    # previews, because they carry the execution stamp the manifest is
    # corroborated against. Without them a caller relying on the record witness
    # would have no witness at all.
    [object[]]$executionWitnessRecords = @()
    if ($CorroborateExecutionFromRecords) {
        # Best effort on purpose. An unreadable or absent log is not an error
        # here - this census counts previews, not records - it simply leaves the
        # witness empty, and an empty witness is already an objection below. The
        # run is reported unproven rather than the whole census being refused
        # over a unit it does not measure.
        try {
            $executionWitnessRecords = @(Get-ReviewerModelStartLogRecord -LogPath (
                    Join-Path (Join-Path $RunRoot 'logs') 'reviewer.log.jsonl'))
        }
        catch { $executionWitnessRecords = @() }
    }
    $authenticity = Test-ReviewerModelStartCensusAuthenticity -RunRoot $RunRoot -MasterKey $MasterKey `
        -Records $executionWitnessRecords -ExpectedRunExecutionId $ExpectedRunExecutionId `
        -CorroborateExecutionFromRecords:$CorroborateExecutionFromRecords `
        -PreviewSnapshot $previewSnapshot
    if ($AuthenticationMode -ceq 'require' -and -not $authenticity.authenticated) {
        $complete = $false
        $authenticationDetail = (@($authenticity.objections) -join ' ')
        $incompleteReason = (("The verification previews under this run root are not authenticated " +
                "($([string]$authenticity.basis)), so the assignments read from them are unproven. ") + $authenticationDetail).Trim() +
        $(if ($incompleteReason.Length -gt 0) { " $incompleteReason" } else { '' })
    }
    return [pscustomobject][ordered]@{
        censusVersion = 1
        runRoot = [string]([IO.Path]::GetFullPath($RunRoot))
        realVerifierAssignments = [int]$ids.Count
        byVerifierModel = ([object[]]@($breakdown))
        # Diagnostic only; no budget is ever checked against it. Grouping pushes it
        # below the assignment count within a pass, but re-verification mints fresh
        # nonces against identities that dedupe, so no ordering holds in aggregate.
        verifierProcessStarts = [int]$nonces.Count
        complete = [bool]$complete
        incompleteReason = [string]$incompleteReason
        verificationAuthorized = [bool]$verificationEnabled
        verificationPreviewCount = [int]$previewCount
        verificationEvidenceLostPreviewCount = [int]$evidenceLostPreviewCount
        authenticated = [bool]$authenticity.authenticated
        authenticationBasis = [string]$authenticity.basis
        authenticationMode = [string]$AuthenticationMode
        authenticationObjections = ([string[]]@($authenticity.objections))
        basis = 'sealedVerificationPreviewAssignments'
    }
}

function Get-ReviewerVerifierAssignmentBound {
    <#
    .SYNOPSIS
        The most cross-verifier assignments one sealed run could stand on.

    .DESCRIPTION
        Read from the runner's own bounds, never restated. The reviewed side
        requires exactly one assignment per ready candidate per required
        reciprocal model and refuses a plan whose required assignment count
        exceeds the effective verifier ceiling, so that ceiling IS the per-run
        assignment cap: the candidate cap and the two configured reciprocal
        models are already multiplied into it upstream.

        A run not authorized to verify is bounded at zero, which is a reading
        from the sealed vector rather than an assumption.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv,
        [Parameter(Mandatory)][string]$ReviewerScriptPath
    )
    $runner = Get-ReviewerModelStartRunnerBound -ReviewerScriptPath $ReviewerScriptPath
    $verificationEnabled = Test-ReviewerModelStartArgvSwitch -Argv @($Argv) -Name '-EnableVerificationPreview'
    $maximum = [int]$(if ($verificationEnabled) { [int]$runner.maxVerifierLaunches } else { 0 })
    return [pscustomobject][ordered]@{
        boundVersion = 1
        maxVerifierAssignments = [int]$maximum
        verificationAuthorized = [bool]$verificationEnabled
        runnerBounds = $runner
    }
}

function Get-ReviewerModelStartCensus {
    <#
    .SYNOPSIS
        The model subprocess starts one reviewer run actually made, by role.

    .PARAMETER RunRoot
        The run's own directory - '<slot state dir>/replay/<snapshot name>' - the
        one the reviewer writes its logs and sealed previews into.

    .PARAMETER Argv
        The sealed argument vector that run was launched with. It says which
        roles were authorized at all, which is what turns an absent artifact into
        either 'that role was never enabled' or 'evidence this census needs is
        missing'.

    .PARAMETER MasterKey
        The run's artifact signing key. The census manifest is signed under a key
        derived from it, so without this nothing in the run root can be
        authenticated and the census says so rather than trusting file shapes.

    .PARAMETER AuthenticationMode
        'require' (default) reports an unauthenticated run incomplete. 'report'
        publishes the same verdict without letting it decide completeness.

    .PARAMETER ExpectedRunExecutionId
        The execution this census was asked to audit, supplied from OUTSIDE the
        run root. A manifest sealed by any other execution is refused, which is
        what stops an earlier run's cheaper attestation being left in a re-used
        directory and re-presented as this run's.

    .PARAMETER CorroborateExecutionFromRecords
        The explicit alternative for a caller that cannot know the execution it
        is auditing: the manifest is corroborated against the execution stamped
        on the accounting records it is counting. One of the two is required.

    .OUTPUTS
        An object carrying the total, the per-role breakdown, and an explicit
        completeness flag. 'complete' false means a role that was enabled left no
        evidence to count, or that the evidence present is not the evidence the
        run attested to; the caller must treat the census as unproven rather
        than as the zero it would otherwise read as.
    #>
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv,
        [byte[]]$MasterKey,
        [AllowEmptyString()][string]$ExpectedRunExecutionId = '',
        [switch]$CorroborateExecutionFromRecords,
        [ValidateSet('require', 'report')][string]$AuthenticationMode = 'require'
    )
    if (-not (Test-Path -LiteralPath $RunRoot -PathType Container)) {
        throw ("The run root '$RunRoot' does not exist, so the model starts made under it cannot be counted. " +
            'A missing run root is refused rather than counted as a run that spent nothing.')
    }
    $logPath = Join-Path (Join-Path $RunRoot 'logs') 'reviewer.log.jsonl'
    $records = @(Get-ReviewerModelStartLogRecord -LogPath $logPath)

    $breakdown = New-ReviewerModelStartBreakdown
    # Two witnesses per role, and the larger wins. The accounting record is
    # written after the subprocess returns and knows whether one was created;
    # the launch intent is written before it can exist and survives a throw
    # anywhere in between. Neither alone is a floor: the accounting record
    # misses a launch that never came back, and the intent misses nothing but
    # cannot say a pre-launch refusal spent nothing - which is why the refusals
    # publish no intent at all.
    $breakdown.generalist = [int][Math]::Max(
        (Measure-ReviewerModelStartAttemptRecord -Records $records -Mode $script:ReviewerGeneralistAttemptMode),
        (Measure-ReviewerModelLaunchIntent -Records $records -CensusRole 'generalist'))
    $breakdown.specialist = [int][Math]::Max(
        (Measure-ReviewerModelStartAttemptRecord -Records $records -Mode $script:ReviewerSpecialistAttemptMode),
        (Measure-ReviewerModelLaunchIntent -Records $records -CensusRole 'specialist'))

    $verificationEnabled = Test-ReviewerModelStartArgvSwitch -Argv @($Argv) -Name '-EnableVerificationPreview'
    $verifier = Get-ReviewerVerifierLaunchNonce -RunRoot $RunRoot
    # Two independent witnesses of the same launches, and the larger one wins.
    #
    # The per-attempt log record is written as soon as each verifier subprocess
    # returns, so it is monotonic and survives an interrupted phase, a phase that
    # threw after its launches, and the degraded fallback that seals a preview
    # with an EMPTY run list. The sealed preview's distinct launch nonces are the
    # second witness and are kept as a cross-check, because a build that somehow
    # sealed launches it never logged must not be read as having made none.
    $verifierLogged = Measure-ReviewerModelStartAttemptRecord -Records $records `
        -Mode $script:ReviewerVerifierAttemptMode
    $verifierIntended = Measure-ReviewerModelLaunchIntent -Records $records -CensusRole 'verifier'
    $breakdown.verifier = [int][Math]::Max(
        [int][Math]::Max([int]$verifier.launchCount, [int]$verifierLogged),
        [int]$verifierIntended)

    # A run that was never authorized to verify is complete without verification
    # evidence; a run that WAS authorized and left no preview DIRECTORY at all is
    # not. What this flag records is the directory, not its contents: an existing
    # but empty directory passes here and is caught downstream, where the
    # assignment census refuses a preview set that accounts for no assignment. The
    # distinction is the whole value of the flag: without it, an unfinished
    # verification phase and a phase that launched nothing report the same zero.
    $complete = $true
    $incompleteReason = ''
    if ($verificationEnabled -and -not $verifier.evidencePresent) {
        $complete = $false
        $incompleteReason = ('The run was authorized to cross-verify and published no verification preview, so the ' +
            'verifier launches it may have made cannot be counted.')
    }
    # A run that published cycle records and no generalist attempt record has
    # either refused before its first launch or lost the evidence of it. Which of
    # the two it is cannot be told from here - it is told by whether the run
    # ENDED cleanly, which is the caller's to know - so this reports the fact and
    # the caller decides. Flagging it incomplete here would turn every legitimate
    # pre-launch refusal into a stop for the whole cohort that entry was part of.

    # Authenticity is decided LAST and folded into completeness, never into the
    # counts. An unauthenticated run keeps every start this census could see -
    # blocking must never be able to make a run look cheaper than its own
    # evidence says it was - and is reported as unproven so the caller stops.
    $authenticity = Test-ReviewerModelStartCensusAuthenticity -RunRoot $RunRoot -MasterKey $MasterKey `
        -Records $records -CompareRecordInventory -ExpectedRunExecutionId $ExpectedRunExecutionId `
        -CorroborateExecutionFromRecords:$CorroborateExecutionFromRecords `
        -PreviewSnapshot $verifier.previewSnapshot
    if ($AuthenticationMode -ceq 'require' -and -not $authenticity.authenticated) {
        $complete = $false
        $authenticationDetail = (@($authenticity.objections) -join ' ')
        $incompleteReason = (("The accounting artifacts under this run root are not authenticated " +
                "($([string]$authenticity.basis)), so the starts counted from them are unproven. ") + $authenticationDetail).Trim() +
        $(if ($incompleteReason.Length -gt 0) { " $incompleteReason" } else { '' })
    }

    $total = [int]$breakdown.generalist + [int]$breakdown.specialist + [int]$breakdown.verifier
    return [pscustomobject][ordered]@{
        censusVersion = 1
        runRoot = [string]([IO.Path]::GetFullPath($RunRoot))
        realModelStarts = [int]$total
        byRole = $breakdown
        complete = [bool]$complete
        incompleteReason = [string]$incompleteReason
        verificationAuthorized = [bool]$verificationEnabled
        verificationPreviewCount = [int]$verifier.previewCount
        # Whether a sealed preview exists at all, which is the only on-disk
        # witness a verifier launch ever leaves. The launch loop accumulates its
        # records in memory and seals them once, at the end of the phase, so a run
        # interrupted mid-phase can have started every launch its policy allowed
        # and left this false with the count at zero. Whoever bounds the
        # unmeasured gap needs to know that, and cannot read it from the count.
        verificationSealed = [bool]([int]$verifier.previewCount -gt 0)
        logRecordCount = [int]@($records).Count
        authenticated = [bool]$authenticity.authenticated
        authenticationBasis = [string]$authenticity.basis
        authenticationMode = [string]$AuthenticationMode
        authenticationObjections = ([string[]]@($authenticity.objections))
        authenticatedPreviewCount = [int]$authenticity.previewsVerified
        authenticatedInputCount = [int]$authenticity.inputsVerified
        basis = 'publishedAttemptRecords'
    }
}

function Get-ReviewerModelStartRunnerBound {
    <#
    .SYNOPSIS
        The runner's own attempt and verifier bounds, read from the runner.
    .DESCRIPTION
        Read out of the reviewer's own sources rather than restated here, because
        a bound restated in a second file is a bound that silently stops being
        the runner's the first time the runner changes. Each value is matched by
        an anchored pattern that must occur exactly once; anything else - absent,
        renamed, or now written in two places - is refused, because a default
        substituted at this point would be a ceiling nobody set.
    #>
    param([Parameter(Mandatory)][string]$ReviewerScriptPath)
    if (-not (Test-Path -LiteralPath $ReviewerScriptPath -PathType Leaf)) {
        throw "The reviewer script '$ReviewerScriptPath' does not exist, so its attempt bounds cannot be read."
    }
    $scriptDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ReviewerScriptPath))
    $runnerText = [IO.File]::ReadAllText($ReviewerScriptPath, [Text.UTF8Encoding]::new($false, $true))

    $readOne = {
        param([string]$Pattern, [string]$What, [string]$Text, [string]$Source)
        $matched = @([regex]::Matches($Text, $Pattern))
        if (@($matched).Count -ne 1) {
            throw ("The $What could not be read from '$Source': the pattern it is declared by occurs " +
                "$(@($matched).Count) time(s) and exactly one is required. A bound this build cannot read is " +
                'refused rather than defaulted.')
        }
        return [int]@($matched)[0].Groups['value'].Value
    }

    $generalistAttempts = & $readOne '(?m)^\$script:ReviewerMarkerRetryAttempts\s*=\s*(?<value>\d+)\s*$' `
        'generalist attempt bound' $runnerText $ReviewerScriptPath
    $specialistAttempts = & $readOne '(?m)^\$script:ReviewerConventionSpecialistMarkerRetryAttempts\s*=\s*(?<value>\d+)\s*$' `
        'specialist attempt bound' $runnerText $ReviewerScriptPath
    # The verifier's bound is structural - the runner has no verifier retry loop -
    # and the runner states it as one arm of its own role/attempt mapping. Read
    # that arm rather than assume the structure, so a verifier retry introduced
    # later cannot leave this bound quietly saying one.
    $verifierAttempts = & $readOne "(?m)^\s*'verifier'\s*\{\s*(?<value>\d+)\s*\}\s*$" `
        'verifier attempt bound' $runnerText $ReviewerScriptPath

    $libraryPath = Join-Path $scriptDirectory 'CrossVerification.ps1'
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        throw "The cross-verification library '$libraryPath' does not exist, so the verifier launch ceiling cannot be read."
    }
    $libraryText = [IO.File]::ReadAllText($libraryPath, [Text.UTF8Encoding]::new($false, $true))
    $verifierCeiling = & $readOne '(?m)^\$script:ReviewerVerificationMaxVerifierRuns\s*=\s*(?<value>\d+)\s*$' `
        'verifier launch ceiling' $libraryText $libraryPath

    $policyPath = Join-Path (Join-Path (Join-Path $scriptDirectory 'verification') 'v1') 'policy.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        throw "The verification policy '$policyPath' does not exist, so the verifier launch bound cannot be read."
    }
    $policy = $null
    try {
        $policy = [IO.File]::ReadAllText($policyPath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -Depth 32
    }
    catch {
        throw "The verification policy '$policyPath' could not be read: $($_.Exception.Message)"
    }
    if ($null -eq $policy -or -not $policy.PSObject.Properties['maxVerifierRuns']) {
        throw "The verification policy '$policyPath' declares no 'maxVerifierRuns', so the verifier launch bound is unavailable."
    }
    $policyRuns = [int]$policy.maxVerifierRuns
    if ($policyRuns -lt 1) {
        throw "The verification policy '$policyPath' declares $policyRuns verifier run(s), which is not a bound this build can use."
    }
    # The runner narrows policy by its own ceiling and never widens it, so the
    # effective bound is the smaller of the two - exactly as the runner computes
    # it when it builds its effective policy.
    $maxVerifierLaunches = [Math]::Min($policyRuns, $verifierCeiling)

    # Whether this runner leaves a per-launch, monotonic record of each verifier
    # subprocess. It decides how large the unmeasured gap of a verification phase
    # can be: with the record, a phase can hide at most the one launch in flight,
    # exactly as the other two roles do; without it, the only witness is the
    # end-of-phase sealed preview, which the degraded fallback writes EMPTY, so a
    # phase can hide every launch it made behind a complete-looking zero. Read
    # from the runner rather than assumed, so this build cannot claim the tighter
    # bound over a runner that does not publish the record.
    #
    # Counted over the runner's string LITERALS, not its text. A raw-text match
    # would also count the mode named in a comment - including the comments this
    # change added - and would then grant the tighter bound to a runner whose
    # emitter had been deleted and only described.
    $runnerTokens = $null
    $runnerParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput(
        $runnerText, [ref]$runnerTokens, [ref]$runnerParseErrors)
    $verifierAttemptRecordCount = @(@($runnerTokens) | Where-Object {
            $_ -is [System.Management.Automation.Language.StringToken] -and
            [string]$_.Value -ceq $script:ReviewerVerifierAttemptMode
        }).Count

    return [pscustomobject][ordered]@{
        generalistAttemptsPerPass = [int]$generalistAttempts
        specialistAttempts = [int]$specialistAttempts
        verifierAttemptsPerLaunch = [int]$verifierAttempts
        maxVerifierLaunches = [int]$maxVerifierLaunches
        verifierPolicyRuns = [int]$policyRuns
        verifierCeiling = [int]$verifierCeiling
        verifierLaunchRecorded = [bool]($verifierAttemptRecordCount -eq 1)
        reviewerScriptPath = [string]([IO.Path]::GetFullPath($ReviewerScriptPath))
        verificationPolicyPath = [string]([IO.Path]::GetFullPath($policyPath))
    }
}

function Get-ReviewerModelStartBound {
    <#
    .SYNOPSIS
        The most model subprocess starts one sealed run could make.

    .DESCRIPTION
        An upper bound, not a prediction. It is deliberately far above what a
        quiet review costs, because the number it protects against is the loud
        one: a change set that produces candidates starts a specialist and a
        cross-verifier launch per cluster, and a ceiling set to the quiet cost
        would be a ceiling that only holds while nothing is found.

        Every factor is read from the sealed argument vector or from the runner's
        own bounds. Nothing here is configurable at this layer, and nothing is
        defaulted: a factor that cannot be read is a refusal.

    .PARAMETER Argv
        The sealed argument vector for one run.

    .PARAMETER ReviewerScriptPath
        The runner the sealed vector names, whose attempt and verifier bounds are
        the ones this run would be held to.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv,
        [Parameter(Mandatory)][string]$ReviewerScriptPath
    )
    $runner = Get-ReviewerModelStartRunnerBound -ReviewerScriptPath $ReviewerScriptPath

    # One generalist pass per declared generalist model. The first is mandatory:
    # a vector that names no model is not a plan this bound can be taken over.
    if (-not (Test-ReviewerModelStartArgvSwitch -Argv @($Argv) -Name '-Model')) {
        throw ('The sealed argument vector names no -Model, so the generalist passes it would run cannot be counted. ' +
            'A bound is refused rather than taken over a plan this build cannot read.')
    }
    $passCount = 1
    if (Test-ReviewerModelStartArgvSwitch -Argv @($Argv) -Name '-SecondPassModel') { $passCount = 2 }
    $specialistEnabled = Test-ReviewerModelStartArgvSwitch -Argv @($Argv) -Name '-EnableConventionSpecialist'
    $verificationEnabled = Test-ReviewerModelStartArgvSwitch -Argv @($Argv) -Name '-EnableVerificationPreview'

    $breakdown = New-ReviewerModelStartBreakdown
    $breakdown.generalist = [int]($passCount * [int]$runner.generalistAttemptsPerPass)
    $breakdown.specialist = [int]$(if ($specialistEnabled) { [int]$runner.specialistAttempts } else { 0 })
    $breakdown.verifier = [int]$(if ($verificationEnabled) {
            [int]$runner.maxVerifierLaunches * [int]$runner.verifierAttemptsPerLaunch
        }
        else { 0 })
    $total = [int]$breakdown.generalist + [int]$breakdown.specialist + [int]$breakdown.verifier

    return [pscustomobject][ordered]@{
        boundVersion = 1
        maxRealModelStarts = [int]$total
        byRole = $breakdown
        generalistPassCount = [int]$passCount
        specialistAuthorized = [bool]$specialistEnabled
        verificationAuthorized = [bool]$verificationEnabled
        runnerBounds = $runner
    }
}

function Get-ReviewerModelStartUnmeasuredAllowance {
    <#
    .SYNOPSIS
        How many real model starts a run may have made that its own evidence
        cannot account for.

    .DESCRIPTION
        A run that ended cleanly published everything it was going to publish, so
        its census is exact and this is zero. A run that failed, timed out or was
        killed may have spent more than it recorded, and the ceiling it is checked
        against has to be checked against the upper bound rather than the floor.

        The gap is normally one. Every role publishes its accounting record as
        soon as the subprocess returns, the record is fatal to write, and the
        reviewer is single-threaded, so at most one launch can be in flight when
        the run stops. A run that ended cleanly therefore has no gap at all.

        That holds for the verifier role only while the runner publishes a
        per-launch record. Against a runner that does not - one whose only
        witness is the end-of-phase sealed preview, whose run list is
        accumulated in memory and serialized once - the whole role is unmeasured
        and stays unmeasured however the run ended: the degraded fallback seals
        an EMPTY preview and returns normally, so 'complete' with a sealed zero
        and 'complete' having launched every run the policy allowed are the same
        artifact. Whatever the seal could not prove is charged. Charging one
        there, or nothing because the run ended well, would rebuild for that role
        exactly the unbounded under-count this accounting exists to remove.

        Capped at what the run's own sealed plan could still spend, so the total
        this build charges never exceeds the bound the cohort proved before it
        started.

    .PARAMETER Census
        The census taken over the run, or $null when the run left evidence this
        build could not read at all.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv,
        [Parameter(Mandatory)][string]$ReviewerScriptPath,
        [Parameter(Mandatory)][bool]$RunEndedComplete,
        $Census
    )
    if ($RunEndedComplete -and $null -ne $Census -and
        -not [bool]$Census.verificationAuthorized) {
        # Nothing left unmeasured: the run ended cleanly, every role it was
        # authorized to run records each launch fatally, and it was not
        # authorized to cross-verify at all.
        return [int]0
    }
    $bound = Get-ReviewerModelStartBound -Argv @($Argv) -ReviewerScriptPath $ReviewerScriptPath
    if ($null -eq $Census) {
        # Nothing about this run could be counted, so everything its plan admits
        # is unaccounted. Charged in full rather than refused: an interrupted slot
        # is an outcome the cohort carries, and the entry's sealed bound already
        # holds this number.
        return [int]$bound.maxRealModelStarts
    }
    # One launch can be in flight when a run stops; none can be when it ended.
    $allowance = [int]$(if ($RunEndedComplete) { 0 } else { 1 })
    if ([bool]$bound.verificationAuthorized -and -not [bool]$bound.runnerBounds.verifierLaunchRecorded) {
        # An unmeasured role, charged for whatever its seal could not prove -
        # however the run ended, because a complete run's seal is exactly as
        # capable of reading zero for a phase that launched everything.
        $sealed = [int]$Census.byRole.verifier
        $unproven = [int]$bound.byRole.verifier - $sealed
        if ($unproven -gt 0) { $allowance += $unproven }
    }
    $unspent = [int]$bound.maxRealModelStarts - [int]$Census.realModelStarts
    if ($unspent -lt 0) { $unspent = 0 }
    if ($allowance -gt $unspent) { $allowance = $unspent }
    return [int]$allowance
}

function Get-ReviewerVerifierAssignmentUnmeasuredAllowance {
    <#
    .SYNOPSIS
        How many cross-verifier assignments a run may have stood on that its own
        evidence cannot account for.

    .DESCRIPTION
        The assignment counterpart of the model-start allowance, and charged on
        the same terms and for the same reason: a ceiling checked against a
        measured floor is not a ceiling.

        A run that ended cleanly and sealed its previews has published every
        assignment it was given, so nothing is unaccounted. A run that failed,
        timed out or was killed may have been given assignments it never sealed -
        the phase accumulates them in memory and seals once at the end - so the
        whole of what its plan admits and its seal did not prove is charged.

        Capped at what the run's own sealed plan could still admit, so the total
        charged never exceeds the bound the cohort proved before it started.

    .PARAMETER Census
        The assignment census taken over the run, or $null when the run left
        evidence this build could not read at all.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv,
        [Parameter(Mandatory)][string]$ReviewerScriptPath,
        [Parameter(Mandatory)][bool]$RunEndedComplete,
        $Census
    )
    $bound = Get-ReviewerVerifierAssignmentBound -Argv @($Argv) -ReviewerScriptPath $ReviewerScriptPath
    if (-not [bool]$bound.verificationAuthorized) {
        # A run never authorized to cross-verify could stand on no assignment,
        # however it ended. That is a reading of the sealed vector, not an
        # assumption about the run.
        return [int]0
    }
    if ($null -eq $Census) {
        return [int]$bound.maxVerifierAssignments
    }
    if ($RunEndedComplete -and [bool]$Census.complete) {
        return [int]0
    }
    $unproven = [int]$bound.maxVerifierAssignments - [int]$Census.realVerifierAssignments
    if ($unproven -lt 0) { $unproven = 0 }
    return [int]$unproven
}
