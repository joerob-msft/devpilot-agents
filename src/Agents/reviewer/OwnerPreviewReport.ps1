#!/usr/bin/env pwsh
<#
    The capability-scoped reading of one convention-specialist result.

    This layer previews ONE convention: bpm-test-ownership@1. Everything here
    exists to keep that scope honest in the only place a human actually reads -
    the report - because the failure this guards against is not a wrong verdict.
    It is a correct verdict about one rule being read as a statement about a
    pull request.

    So there is deliberately no `passed`, no vote, no severity and no total. The
    counts are the capability's own vocabulary and nothing else:

      violation  the rule reached the declaration and it lacks the owner attribute
      compliant  the rule reached the declaration and it carries one
      unknown    the required context could not be established

    `checked` is violations plus compliant, and `unknown` is never folded into
    either. That separation is the whole point: "nobody could tell" and "this one
    is fine" are the two answers a reader must never confuse, and a count that
    added them would make them indistinguishable at exactly the moment someone
    decides whether to act.

    The v4 marker is read directly. Convert-ReviewerConventionSpecialistV4Marker
    is deliberately NOT used: it rewrites a marker into the v3 candidate shape
    that delivery, gates and reconciliation consume, and it needs the wrapper's
    convention plan, resolved sources and change entries to do it. This layer
    delivers nothing, so asking for that shape would mean carrying inputs it has
    no other use for, to derive fields nobody here reads.
#>

Set-StrictMode -Version Latest

$script:OwnerPreviewCapability = 'bpm-test-ownership@1'
$script:OwnerPreviewVerdicts = @('violation', 'compliant', 'unknown')

function Get-OwnerPreviewMarkerValue {
    <#
        One property off a marker object, or a default.

        Markers arrive as PSCustomObject from the parser and as hashtables from
        tests that build them literally. Reading both through one accessor keeps
        every caller below from having to know which it got.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Container,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()]$Default = $null
    )
    if ($null -eq $Container) { return $Default }
    if ($Container -is [System.Collections.IDictionary]) {
        if ($Container.Contains($Key)) { return $Container[$Key] }
        return $Default
    }
    $property = $Container.PSObject.Properties[$Key]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-OwnerPreviewArray {
    <#
        A property read as a real array.

        Returned through a leading comma so a single element or an empty set
        survives the pipeline as a collection rather than being unwrapped into a
        scalar or a null - the shape hazard this repository's analyzer exists to
        catch.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Container,
        [Parameter(Mandatory)][string]$Key
    )
    $value = Get-OwnerPreviewMarkerValue -Container $Container -Key $Key -Default $null
    if ($null -eq $value) { return , @() }
    if ($value -is [string]) { return , @($value) }
    if ($value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $value) { [void]$items.Add($item) }
        return , $items.ToArray()
    }
    return , @($value)
}

function Get-OwnerPreviewCapabilityCounts {
    <#
        The capability's verdict census, taken from the marker the model actually
        produced.

        Every construct the model returned a verdict for is counted exactly once,
        under exactly the verdict it was given. A verdict outside the closed set
        is counted as `unrecognized` rather than silently mapped onto one of the
        three: a marker this build does not understand must not be able to
        inflate `compliant`.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Marker)

    $violations = [System.Collections.Generic.List[object]]::new()
    $unknowns = [System.Collections.Generic.List[object]]::new()
    $compliantCount = 0
    $unrecognizedCount = 0

    $rows = Get-OwnerPreviewArray -Container $Marker -Key 'assessments'
    foreach ($row in $rows) {
        $ruleRef = [string](Get-OwnerPreviewMarkerValue -Container $row -Key 'ruleRef' -Default '')
        $notesByConstruct = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $notes = Get-OwnerPreviewArray -Container $row -Key 'notes'
        foreach ($note in $notes) {
            $noteRef = [string](Get-OwnerPreviewMarkerValue -Container $note -Key 'constructRef' -Default '')
            if ($noteRef -ne '' -and -not $notesByConstruct.ContainsKey($noteRef)) {
                $notesByConstruct[$noteRef] = $note
            }
        }

        $constructs = Get-OwnerPreviewArray -Container $row -Key 'constructs'
        foreach ($construct in $constructs) {
            $constructRef = [string](Get-OwnerPreviewMarkerValue -Container $construct -Key 'constructRef' -Default '')
            $verdict = [string](Get-OwnerPreviewMarkerValue -Container $construct -Key 'verdict' -Default '')
            switch -CaseSensitive ($verdict) {
                'violation' {
                    $entry = [ordered]@{ ruleRef = $ruleRef; constructRef = $constructRef }
                    if ($notesByConstruct.ContainsKey($constructRef)) {
                        $note = $notesByConstruct[$constructRef]
                        $rationale = [string](Get-OwnerPreviewMarkerValue -Container $note -Key 'rationale' -Default '')
                        $suggestion = [string](Get-OwnerPreviewMarkerValue -Container $note -Key 'suggestion' -Default '')
                        if ($rationale -ne '') { $entry['rationale'] = $rationale }
                        if ($suggestion -ne '') { $entry['suggestion'] = $suggestion }
                    }
                    [void]$violations.Add([pscustomobject]$entry)
                    break
                }
                'compliant' { $compliantCount++; break }
                'unknown' {
                    [void]$unknowns.Add([pscustomobject][ordered]@{
                            ruleRef = $ruleRef; constructRef = $constructRef
                        })
                    break
                }
                default { $unrecognizedCount++ }
            }
        }
    }

    $risks = [System.Collections.Generic.List[string]]::new()
    $riskEntries = Get-OwnerPreviewArray -Container $Marker -Key 'residualRisks'
    foreach ($risk in $riskEntries) {
        $text = if ($risk -is [string]) { [string]$risk } else {
            [string](Get-OwnerPreviewMarkerValue -Container $risk -Key 'text' -Default '')
        }
        if ($text -ne '') { [void]$risks.Add($text) }
    }

    $withheldEntries = Get-OwnerPreviewArray -Container $Marker -Key 'withheld'
    $violationCount = $violations.Count
    $unknownCount = $unknowns.Count

    return [pscustomobject][ordered]@{
        Checked          = $violationCount + $compliantCount
        Violations       = $violationCount
        Compliant        = $compliantCount
        Unknown          = $unknownCount
        Unrecognized     = $unrecognizedCount
        Rows             = @($rows).Count
        Withheld         = @($withheldEntries).Count
        ResidualRisks    = $risks.ToArray()
        ViolationEntries = $violations.ToArray()
        UnknownEntries   = $unknowns.ToArray()
    }
}

function Format-OwnerPreviewHeadline {
    <#
        The one sentence a human reads first.

        Phrased entirely in the capability's own terms. It says what was checked
        and what was found, and it cannot be read as a statement about the pull
        request, because it never mentions one.
    #>
    param([Parameter(Mandatory)]$Counts)
    $violationWord = if ([int]$Counts.Violations -eq 1) { 'violation' } else { 'violations' }
    $declarationWord = if ([int]$Counts.Checked -eq 1) { 'declaration' } else { 'declarations' }
    return ("{0} - checked {1} {2}; {3} {4}; {5} unknown" -f `
            $script:OwnerPreviewCapability, [int]$Counts.Checked, $declarationWord,
        [int]$Counts.Violations, $violationWord, [int]$Counts.Unknown)
}

function New-OwnerPreviewStatus {
    <#
        The status document, built to reviewer.owner-preview-status.v1.json.

        `terminal.status` is decided from how the pass ENDED, never from what it
        found. A refused, truncated or absent marker produces `incomplete` or
        `blocked` with zero counts - which is not the same document as a
        completed pass that found nothing, and must never be able to look like
        one.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Subject,
        [Parameter(Mandatory)][hashtable]$Rule,
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [Parameter(Mandatory)][ValidateSet('completed', 'incomplete', 'blocked')][string]$TerminalStatus,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MarkerStatus,
        [AllowNull()]$Counts = $null,
        [AllowEmptyString()][string]$SubjectKey = '',
        [AllowEmptyString()][string]$HeadKey = '',
        [AllowEmptyString()][string]$Diagnostic = '',
        [AllowEmptyString()][string]$Field = '',
        [AllowEmptyString()][string]$SpecialistModel = '',
        [ValidateRange(0, 3)][int]$ModelStarts = 0,
        [ValidateRange(0, [int]::MaxValue)][int]$DurationMs = 0
    )

    $status = [ordered]@{
        schemaVersion = 1
        kind          = 'reviewer-owner-preview-status'
        capability    = $script:OwnerPreviewCapability
    }
    if ($SubjectKey -ne '') { $status['subjectKey'] = $SubjectKey }
    if ($HeadKey -ne '') { $status['headKey'] = $HeadKey }
    $status['subject'] = $Subject
    $status['rule'] = $Rule
    $status['snapshot'] = $Snapshot

    if ($null -eq $Counts) {
        $status['counts'] = [ordered]@{ checked = 0; violations = 0; compliant = 0; unknown = 0 }
    }
    else {
        $status['counts'] = [ordered]@{
            checked       = [int]$Counts.Checked
            violations    = [int]$Counts.Violations
            compliant     = [int]$Counts.Compliant
            unknown       = [int]$Counts.Unknown
            rows          = [int]$Counts.Rows
            withheld      = [int]$Counts.Withheld
            residualRisks = @($Counts.ResidualRisks).Count
        }
        $status['violations'] = @($Counts.ViolationEntries)
        $status['unknowns'] = @($Counts.UnknownEntries)
        $status['residualRisks'] = @($Counts.ResidualRisks)
    }

    $terminal = [ordered]@{
        status          = $TerminalStatus
        markerStatus    = $(if ($MarkerStatus -eq '') { 'absent' } else { $MarkerStatus })
        contractVersion = 4
    }
    if ($Diagnostic -ne '') { $terminal['diagnostic'] = $Diagnostic }
    if ($Field -ne '') { $terminal['field'] = $Field }
    $status['terminal'] = $terminal

    # Const zero in the schema, and stated here rather than measured, because
    # this build ships no code path that could raise them. A number derived from
    # a counter would invite the reader to believe the counter.
    $spend = [ordered]@{
        modelStarts           = $ModelStarts
        providerWriteCount    = 0
        writeToolInvocations  = 0
        generalistModelStarts = 0
    }
    if ($SpecialistModel -ne '') { $spend['specialistModel'] = $SpecialistModel }
    if ($DurationMs -gt 0) { $spend['durationMs'] = $DurationMs }
    $status['spend'] = $spend
    $status['createdUtc'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    return $status
}

function Get-OwnerPreviewMarkerNonce {
    <#
        The nonce the marker itself carries.

        The schema binds a marker to the nonce the wrapper issued. Acquisition
        issued it and sealed the transcript around it, so it is read back from
        the marker rather than re-invented here; a mismatch is then the schema's
        refusal to make, not this function's.
    #>
    param([Parameter(Mandatory)][string]$MarkerText)
    $match = [regex]::Match($MarkerText, '"nonce"\s*:\s*"([A-Za-z0-9._-]{8,128})"')
    if (-not $match.Success) {
        throw "The result marker carries no readable nonce; it cannot be bound to the run that asked for it."
    }
    return $match.Groups[1].Value
}

function New-OwnerPreviewOutcome {
    <#
        The status document for one prepared subject and one result marker.

        Pure, and kept in this library rather than in the operator script, so it
        can be exercised directly. A decision this consequential - whether a pass
        counts as completed - should not be reachable only by running the whole
        chain.

        The terminal state is decided from how the pass ENDED, never from what it
        found. A refused, truncated or absent marker produces incomplete with no
        counts, which is a different document from a completed pass that found
        nothing, and must never be able to look like one.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Subject,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MarkerText
    )
    $subjectIdentity = $Subject.subject
    $ruleSection = @($Subject.rule.sections)[0]
    $ruleBlock = @{
        path       = [string]$ruleSection.path
        commit     = [string]$ruleSection.commit
        sha256     = [string]$ruleSection.sha256
        byteLength = [int]$ruleSection.byteLength
    }
    $sectionLabel = [string](Get-OwnerPreviewMarkerValue -Container $ruleSection -Key 'section' -Default '')
    if ($sectionLabel -ne '') { $ruleBlock['section'] = $sectionLabel }

    $subjectBlock = @{
        organization   = [string]$subjectIdentity.organization
        project        = [string]$subjectIdentity.project
        repositoryId   = [string]$subjectIdentity.repositoryId
        repositoryName = [string]$subjectIdentity.repositoryName
        pullRequestId  = [int]$subjectIdentity.pullRequestId
        iterationId    = [int]$subjectIdentity.iterationId
        sourceCommit   = [string]$subjectIdentity.sourceCommit
        targetCommit   = [string]$subjectIdentity.targetCommit
    }
    $snapshotBlock = @{
        snapshotId     = [string]$Subject.snapshot.snapshotId
        manifestDigest = [string]$Subject.snapshot.manifestDigest
        sealKind       = [string]$Subject.snapshot.sealKind
        nonPromotable  = $true
    }
    $subjectKey = [string]$Subject.subjectKey
    $headKey = [string]$Subject.headKey
    $model = [string]$Subject.model

    if ($MarkerText -eq '') {
        return (New-OwnerPreviewStatus -Subject $subjectBlock -Rule $ruleBlock -Snapshot $snapshotBlock `
                -TerminalStatus 'incomplete' -MarkerStatus 'absent' -SubjectKey $subjectKey `
                -HeadKey $headKey -SpecialistModel $model -ModelStarts 1 `
                -Diagnostic 'The pass produced no version 4 result marker.')
    }

    $schema = $null
    $outcome = $null
    $readFailure = ''
    try {
        # A marker this layer cannot even read is an INCOMPLETE pass, not an
        # error for the operator to interpret. Anything thrown between here and
        # a parsed result means the same thing: no verdicts were established.
        $schema = Get-ReviewerConventionSpecialistMarkerSchema `
            -ExpectedProject ([string]$subjectIdentity.project) `
            -ExpectedNonce (Get-OwnerPreviewMarkerNonce -MarkerText $MarkerText) -ContractVersion 4
        $outcome = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome -StdOutText $MarkerText `
            -Schema $schema -ContractVersion 4
    }
    catch {
        $readFailure = [string]$_.Exception.Message
    }
    if ($readFailure -ne '') {
        return (New-OwnerPreviewStatus -Subject $subjectBlock -Rule $ruleBlock -Snapshot $snapshotBlock `
                -TerminalStatus 'incomplete' -MarkerStatus 'unreadable' -SubjectKey $subjectKey `
                -HeadKey $headKey -SpecialistModel $model -ModelStarts 1 -Diagnostic $readFailure)
    }

    $outcomeStatus = [string]$outcome.Status
    if ($outcomeStatus -ceq 'success') {
        $counts = Get-OwnerPreviewCapabilityCounts -Marker $outcome.Value
        return (New-OwnerPreviewStatus -Subject $subjectBlock -Rule $ruleBlock -Snapshot $snapshotBlock `
                -TerminalStatus 'completed' -MarkerStatus $outcomeStatus -Counts $counts `
                -SubjectKey $subjectKey -HeadKey $headKey -SpecialistModel $model -ModelStarts 1)
    }
    $field = [string](Get-OwnerPreviewMarkerValue -Container $outcome -Key 'Field' -Default '')
    return (New-OwnerPreviewStatus -Subject $subjectBlock -Rule $ruleBlock -Snapshot $snapshotBlock `
            -TerminalStatus 'incomplete' -MarkerStatus $outcomeStatus -SubjectKey $subjectKey `
            -HeadKey $headKey -SpecialistModel $model -ModelStarts 1 -Field $field `
            -Diagnostic 'The result marker did not satisfy the version 4 contract.')
}

function Format-OwnerPreviewReport {
    <#
        The whole human-readable report.

        Self-sufficient on purpose: anything summarising this document - a person
        or an agent - can only be as complete as the document is, so the rule
        bytes, the sealed input and the terminal state are all stated here rather
        than left in a JSON file beside it.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Status)

    $lines = [System.Collections.Generic.List[string]]::new()
    $subject = $Status['subject']
    $rule = $Status['rule']
    $snapshot = $Status['snapshot']
    $counts = $Status['counts']
    $terminal = $Status['terminal']

    [void]$lines.Add("# Owner convention preview")
    [void]$lines.Add("")
    [void]$lines.Add(("PR {0} in {1}/{2} at source commit {3}." -f `
                $subject['pullRequestId'], $subject['organization'], $subject['project'],
            $subject['sourceCommit']))
    [void]$lines.Add("")

    $terminalStatus = [string]$terminal['status']
    if ($terminalStatus -ceq 'completed') {
        $countsObject = [pscustomobject][ordered]@{
            Checked = $counts['checked']; Violations = $counts['violations']; Unknown = $counts['unknown']
        }
        [void]$lines.Add((Format-OwnerPreviewHeadline -Counts $countsObject))
    }
    else {
        # No counts sentence at all for a pass that did not complete. A "checked
        # 0" line beside a failure reads like a clean result to anyone skimming.
        [void]$lines.Add(("{0} - the pass ended '{1}'; no verdicts were recorded." -f `
                    $script:OwnerPreviewCapability, $terminalStatus))
        if ($terminal.Contains('diagnostic')) {
            [void]$lines.Add(("Diagnostic: {0}" -f $terminal['diagnostic']))
        }
    }

    [void]$lines.Add("")
    [void]$lines.Add("## Rule")
    [void]$lines.Add(("- Path: {0}" -f $rule['path']))
    if ($rule.Contains('section')) { [void]$lines.Add(("- Section: {0}" -f $rule['section'])) }
    [void]$lines.Add(("- Commit: {0}" -f $rule['commit']))
    [void]$lines.Add(("- SHA-256: {0} ({1} byte(s))" -f $rule['sha256'], $rule['byteLength']))

    if ($terminalStatus -ceq 'completed' -and $Status.Contains('violations')) {
        $violationEntries = @($Status['violations'])
        if ($violationEntries.Count -gt 0) {
            [void]$lines.Add("")
            [void]$lines.Add("## Violations")
            foreach ($entry in $violationEntries) {
                $ruleRef = [string](Get-OwnerPreviewMarkerValue -Container $entry -Key 'ruleRef' -Default '')
                $constructRef = [string](Get-OwnerPreviewMarkerValue -Container $entry -Key 'constructRef' -Default '')
                [void]$lines.Add(("- {0} / {1}" -f $ruleRef, $constructRef))
                $rationale = [string](Get-OwnerPreviewMarkerValue -Container $entry -Key 'rationale' -Default '')
                if ($rationale -ne '') { [void]$lines.Add(("  - {0}" -f $rationale)) }
            }
        }
        $unknownEntries = @($Status['unknowns'])
        if ($unknownEntries.Count -gt 0) {
            [void]$lines.Add("")
            [void]$lines.Add("## Unknown")
            [void]$lines.Add("Context could not be established for these. They are not findings and they are not compliant.")
            foreach ($entry in $unknownEntries) {
                $ruleRef = [string](Get-OwnerPreviewMarkerValue -Container $entry -Key 'ruleRef' -Default '')
                $constructRef = [string](Get-OwnerPreviewMarkerValue -Container $entry -Key 'constructRef' -Default '')
                [void]$lines.Add(("- {0} / {1}" -f $ruleRef, $constructRef))
            }
        }
        $riskEntries = @($Status['residualRisks'])
        if ($riskEntries.Count -gt 0) {
            [void]$lines.Add("")
            [void]$lines.Add("## Residual risks")
            foreach ($risk in $riskEntries) { [void]$lines.Add(("- {0}" -f [string]$risk)) }
        }
    }

    [void]$lines.Add("")
    [void]$lines.Add("## Evidence")
    [void]$lines.Add(("- Sealed input: {0} (manifest digest {1})" -f `
                $snapshot['snapshotId'], $snapshot['manifestDigest']))
    [void]$lines.Add(("- Classification: {0}, non-promotable" -f $snapshot['sealKind']))
    [void]$lines.Add(("- Model starts: {0}; provider writes: {1}; write tool invocations: {2}" -f `
                $Status['spend']['modelStarts'], $Status['spend']['providerWriteCount'],
            $Status['spend']['writeToolInvocations']))
    [void]$lines.Add("")
    [void]$lines.Add("This preview reports one convention. It is not a review of the pull request, and it carries no vote.")
    return ($lines.ToArray() -join [Environment]::NewLine)
}
