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
        }
    }
    $previews = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name | ForEach-Object { [string]$_.FullName })
    $nonces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($previews)) {
        $envelope = $null
        try {
            $envelope = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -Depth 64
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

    .OUTPUTS
        An object carrying the total, the per-role breakdown, and an explicit
        completeness flag. 'complete' false means a role that was enabled left no
        evidence to count; the caller must treat the census as unproven rather
        than as the zero it would otherwise read as.
    #>
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv
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
    # evidence; a run that WAS authorized and left none is not. The distinction is
    # the whole value of the flag: without it, an unfinished verification phase and
    # a phase that launched nothing report the same zero.
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
