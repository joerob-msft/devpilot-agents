function Assert-FleetCliEvent {
    param([object]$Event, [string]$Channel)
    if ($Event -isnot [System.Management.Automation.PSCustomObject] -or
        -not $Event.PSObject.Properties['type'] -or $Event.type -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Event.type)) {
        throw "Invalid $Channel event envelope."
    }
    if ($Event.type.StartsWith('tool.execution', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Tool execution observed in tool-disabled profile ($Channel)."
    }
    if ($Event.type -eq 'assistant.message') {
        if (-not $Event.PSObject.Properties['data'] -or
            $Event.data -isnot [System.Management.Automation.PSCustomObject] -or
            -not $Event.data.PSObject.Properties['content'] -or $Event.data.content -isnot [string]) {
            throw "Invalid $Channel assistant message."
        }
        if ($Event.data.PSObject.Properties['toolRequests'] -and $null -ne $Event.data.toolRequests -and
            @($Event.data.toolRequests).Count -gt 0) {
            throw "Tool request observed in tool-disabled profile ($Channel)."
        }
    }
}

function Get-FleetCliOutcome {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionJournalText,
        [Parameter(Mandatory)][string]$SessionId
    )
    # Audit the complete, private journal. Never use its unredacted text as the model answer.
    $journalIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $journalAnswers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $starts = 0
    $shutdowns = 0
    foreach ($line in ($SessionJournalText -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = ConvertFrom-Json -InputObject $line -ErrorAction Stop }
        catch { throw "Invalid private session journal JSON: $($_.Exception.Message)" }
        Assert-FleetCliEvent -Event $event -Channel 'journal'
        if (-not $event.PSObject.Properties['id'] -or $event.id -isnot [string] -or
            [string]::IsNullOrWhiteSpace($event.id) -or -not $journalIds.Add($event.id)) {
            throw 'Missing or duplicate private journal event identity.'
        }
        if ($event.type -eq 'session.start') {
            $starts++
            if (-not $event.PSObject.Properties['data'] -or -not $event.data -or
                -not $event.data.PSObject.Properties['sessionId'] -or $event.data.sessionId -cne $SessionId) {
                throw 'Private journal session binding mismatch.'
            }
        }
        elseif ($event.type -eq 'session.shutdown') { $shutdowns++ }
        elseif ($event.type -eq 'assistant.message') { [void]$journalAnswers.Add($event.id) }
    }
    if ($starts -ne 1 -or $shutdowns -ne 1 -or $journalAnswers.Count -eq 0) {
        throw 'Private journal lacks one session start/shutdown or a completed model message.'
    }

    $accepted = [Collections.Generic.List[string]]::new()
    $stdoutAnswers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $omittedEchoes = 0
    $results = 0
    $lastType = $null
    $lineNumber = 0
    foreach ($line in ($StdOutText -split "`r?`n")) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $lastType = $null
        try { $event = ConvertFrom-Json -InputObject $trimmed -ErrorAction Stop }
        catch {
            # CLI masking can break JSON quoting inside echoed input. Only these exact
            # non-result envelopes may be omitted, after the independent journal audit.
            if ($trimmed -cmatch '^\{"type":"(?:user\.message|system\.message)","data":') {
                $omittedEchoes++
                continue
            }
            throw "Invalid CLI stdout JSON at record ${lineNumber}: $($_.Exception.Message)"
        }
        Assert-FleetCliEvent -Event $event -Channel 'stdout'
        $lastType = $event.type
        if ($event.type -eq 'assistant.message') {
            if (-not $event.PSObject.Properties['id'] -or $event.id -isnot [string] -or
                -not $journalAnswers.Contains($event.id) -or -not $stdoutAnswers.Add($event.id)) {
                throw 'CLI answer event identity is missing, duplicated, or absent from the private journal.'
            }
        }
        elseif ($event.type -eq 'result') {
            $results++
            if (-not $event.PSObject.Properties['sessionId'] -or $event.sessionId -cne $SessionId) {
                throw 'CLI result session binding mismatch.'
            }
        }
        $accepted.Add($trimmed)
    }
    if ($results -ne 1 -or $lastType -ne 'result' -or -not $stdoutAnswers.SetEquals($journalAnswers)) {
        throw 'CLI stdout lacks one final result or the complete set of journal-bound answer events.'
    }
    $outcome = Get-AgentCliJsonOutcome -StdOutText ($accepted.ToArray() -join "`n")
    if (-not $outcome -or -not $outcome.ModelActuallyRan -or $outcome.ExitCode -ne 0) {
        throw 'Missing successful structured CLI outcome.'
    }
    $outcome.TransportNote = if ($omittedEchoes -gt 0) {
        "Omitted $omittedEchoes malformed input/context echo record(s) from CLI stdout. The private session journal was audited independently; model answers and result/tool records remained strict. Redaction was not disabled."
    } else { $null }
    return $outcome
}
