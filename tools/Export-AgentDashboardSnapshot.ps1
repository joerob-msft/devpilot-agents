#requires -Version 7.0

<#
.SYNOPSIS
    Exports privacy-safe dashboard metrics from local reviewer agent JSONL logs.

.DESCRIPTION
    Reads reviewer and review-handler cycle metadata, keeps only bounded numeric,
    boolean, date, vote, and pull-request fields, and writes one aggregate JSON
    snapshot. Raw comments, prompts, identities, repository names, commits, file
    paths, and local paths are never copied to the snapshot.

    Exact duplicate log events are ignored. Distinct-PR metrics are deduplicated
    by pull-request id within the requested period.
#>
[CmdletBinding()]
param(
    [string[]]$ReviewerLogPath = @(),

    [string[]]$ReviewHandlerLogPath = @(),

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [datetime]$PeriodStart = ([datetime]::UtcNow.Date.AddDays(-27)),

    [datetime]$PeriodEnd = ([datetime]::UtcNow.Date.AddDays(1)),

    [ValidatePattern('^[a-f0-9]{24}$')]
    [string]$InstallationEpochId,

    [ValidatePattern('^[a-f0-9]{24}$')]
    [string]$PublisherId,

    [string]$InstallationStatePath,

    [datetime]$GeneratedAt = [datetime]::UtcNow,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-ExporterDashboardConfig {
    param([string]$ConfigPath, [Parameter(Mandatory)][string]$RepoRoot)

    $resolved = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath
    } else {
        Join-Path $RepoRoot 'dashboard\dashboard-config.json'
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $null }
    try {
        $raw = (New-Object System.Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($resolved))
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Dashboard config '$resolved' is not valid UTF-8 JSON."
    }
    if ($config -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Dashboard config '$resolved' must be a JSON object."
    }
    $kindProp = $config.PSObject.Properties['kind']
    $kind = if ($kindProp) { [string]$kindProp.Value } else { '' }
    if ($kind -cne 'devpilot-agent-dashboard-config') {
        throw "Dashboard config '$resolved' has an unsupported kind '$kind'."
    }
    $schemaProp = $config.PSObject.Properties['schemaVersion']
    $schemaVersion = if ($schemaProp) { $schemaProp.Value } else { $null }
    if ($null -eq $schemaVersion -or [int]$schemaVersion -ne 1) {
        throw "Dashboard config '$resolved' has an unsupported schemaVersion."
    }
    $windowProp = $config.PSObject.Properties['reportingWindow']
    $window = if ($windowProp) { $windowProp.Value } else { $null }
    if ($null -eq $window) { throw "Dashboard config '$resolved' must include 'reportingWindow'." }
    $policyProp = if ($window -is [System.Management.Automation.PSCustomObject]) { $window.PSObject.Properties['policy'] } else { $null }
    $policy = if ($policyProp) { [string]$policyProp.Value } else { '' }
    if ($policy -cne 'calendar-month') {
        throw "Dashboard config '$resolved' has unsupported reportingWindow.policy '$policy'. Supported: calendar-month."
    }
    $yearProp  = if ($window -is [System.Management.Automation.PSCustomObject]) { $window.PSObject.Properties['year']  } else { $null }
    $monthProp = if ($window -is [System.Management.Automation.PSCustomObject]) { $window.PSObject.Properties['month'] } else { $null }
    if ($null -eq $yearProp -or $null -eq $monthProp) {
        throw "Dashboard config '$resolved' calendar-month policy requires 'year' and 'month'."
    }
    $yearInt = [int]$yearProp.Value; $monthInt = [int]$monthProp.Value
    if ($yearInt -lt 2020 -or $yearInt -gt 2100 -or $monthInt -lt 1 -or $monthInt -gt 12) {
        throw "Dashboard config '$resolved' has an invalid year ($yearInt) or month ($monthInt)."
    }
    $periodStart = [datetime]::new($yearInt, $monthInt, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return [pscustomobject]@{ PeriodStart = $periodStart; PeriodEnd = $periodStart.AddMonths(1) }
}

function Get-DashboardValue {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }

    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    return $Default
}

function Test-DashboardHasValue {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        return $null -ne $Object.PSObject.Properties[$Name]
    }
    return $false
}

function ConvertTo-DashboardUtc {
    param([Parameter(Mandatory)][datetime]$Value)
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
        return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    return $Value.ToUniversalTime()
}

function Get-DashboardSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function ConvertFrom-DashboardTimestamp {
    param($Value, [Parameter(Mandatory)][string]$Where)

    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Where must be an ISO-8601 timestamp."
    }

    $parsed = [datetimeoffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetimeoffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        throw "$Where '$Value' is not a valid ISO-8601 timestamp."
    }
    return $parsed.UtcDateTime
}

function Get-DashboardLogInt {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where,
        [int]$Default = 0
    )

    $value = Get-DashboardValue -Object $Record -Name $Name
    if ($null -eq $value) { return $Default }
    if ($value -is [bool] -or
        -not ($value -is [byte] -or $value -is [int16] -or $value -is [int32] -or
            $value -is [int64] -or $value -is [double] -or $value -is [decimal])) {
        throw "$Where.$Name must be a non-negative integer."
    }
    $asDecimal = [decimal]$value
    if ($asDecimal -ne [decimal]::Floor($asDecimal) -or $asDecimal -lt 0 -or $asDecimal -gt [int]::MaxValue) {
        throw "$Where.$Name must be a non-negative integer no greater than $([int]::MaxValue)."
    }
    return [int]$asDecimal
}

function Get-DashboardLogBool {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where,
        [bool]$Default = $false
    )

    $value = Get-DashboardValue -Object $Record -Name $Name
    if ($null -eq $value) { return $Default }
    if ($value -isnot [bool]) { throw "$Where.$Name must be a JSON boolean." }
    return [bool]$value
}

function Get-DashboardLogString {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    $value = Get-DashboardValue -Object $Record -Name $Name
    if ($null -eq $value) { return $Default }
    if ($value -isnot [string]) { return [string]$value }
    return $value
}

function Resolve-DashboardLogFiles {
    param([string[]]$Path)

    $resolved = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($candidate in @($Path)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $items = @()
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($candidate)) {
            $items = @(Get-ChildItem -Path $candidate -File -ErrorAction SilentlyContinue)
        }
        elseif (Test-Path -LiteralPath $candidate -PathType Container) {
            $items = @(Get-ChildItem -LiteralPath $candidate -File -Filter '*.jsonl')
        }
        elseif (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $items = @(Get-Item -LiteralPath $candidate)
        }
        else {
            Write-Warning "Dashboard log path '$candidate' does not exist; continuing without it."
            continue
        }

        foreach ($item in $items) {
            $fullPath = [IO.Path]::GetFullPath($item.FullName)
            if ($seen.Add($fullPath)) { [void]$resolved.Add($fullPath) }
        }
    }
    return $resolved.ToArray()
}

function Get-DashboardStableLogLines {
    param([Parameter(Mandatory)][string]$Path)

    # Agents append metadata while snapshots may be exported. Open with
    # read/write sharing, copy the length visible at open time, and parse only
    # through the last complete newline so an in-flight append is deferred to
    # the next snapshot instead of blocking the writer or producing bad JSON.
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    )
    try {
        $length = $stream.Length
        if ($length -gt 256MB) {
            throw "Dashboard log '$Path' is too large to snapshot safely; rotate the JSONL log first."
        }
        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
    }
    finally {
        $stream.Dispose()
    }

    $lastNewline = -1
    for ($index = $offset - 1; $index -ge 0; $index--) {
        if ($bytes[$index] -eq 10) { $lastNewline = $index; break }
    }
    if ($lastNewline -lt 0) { return @() }

    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, 0, $lastNewline + 1)
    }
    catch {
        throw "Dashboard log '$Path' is not valid UTF-8."
    }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
}

function Read-DashboardLogRecords {
    param(
        [string[]]$Path,
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][datetime]$EndUtc,
        [switch]$IncludeBeforeStart
    )

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Resolve-DashboardLogFiles -Path $Path)) {
        $lineNumber = 0
        foreach ($line in @(Get-DashboardStableLogLines -Path $file)) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                    $record = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                    throw "Dashboard log '$file' line $lineNumber is not valid JSON."
            }
            if ($record -isnot [System.Management.Automation.PSCustomObject]) {
                    throw "Dashboard log '$file' line $lineNumber must contain one JSON object."
            }
            $timestamp = ConvertFrom-DashboardTimestamp -Value (Get-DashboardValue -Object $record -Name 'timestamp') `
                    -Where "'$file' line $lineNumber timestamp"
            if ($timestamp -ge $EndUtc) { continue }
            $inPeriod = $timestamp -ge $StartUtc
            if (-not $inPeriod -and -not $IncludeBeforeStart) { continue }
            [void]$records.Add([pscustomobject]@{
                        Record    = $record
                        Timestamp = $timestamp
                        Where     = "'$file' line $lineNumber"
                        InPeriod  = $inPeriod
                    })
        }
    }
    return $records.ToArray()
}

function Get-DashboardWeekStart {
    param([Parameter(Mandatory)][datetime]$TimestampUtc)
    $date = $TimestampUtc.Date
    $offset = (([int]$date.DayOfWeek + 6) % 7)
    return $date.AddDays(-$offset)
}

function Get-DashboardPrAggregate {
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][int]$PrId
    )

    $key = [string]$PrId
    if (-not $Map.ContainsKey($key)) {
        $Map[$key] = @{
            prId            = $PrId
            lastActivityAt  = $null
            latestReviewAt  = $null
            reviewed        = $false
            findings        = 0
            postedComments  = 0
            vote            = 'none'
            voteAt          = $null
            approved        = $false
            commitPushed    = $false
            autoComplete    = $false
        }
    }
    return $Map[$key]
}

function Get-DashboardWeekAggregate {
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][datetime]$TimestampUtc
    )

    $weekStart = Get-DashboardWeekStart -TimestampUtc $TimestampUtc
    $key = $weekStart.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    if (-not $Map.ContainsKey($key)) {
        $Map[$key] = @{
            weekStart             = $key
            reviewedPrIds         = (New-Object 'System.Collections.Generic.HashSet[int]')
            commentsPosted        = 0
            approvedPrIds         = (New-Object 'System.Collections.Generic.HashSet[int]')
            commitPushedPrIds     = (New-Object 'System.Collections.Generic.HashSet[int]')
            autoCompletedPrIds    = (New-Object 'System.Collections.Generic.HashSet[int]')
        }
    }
    return $Map[$key]
}

function Update-DashboardLastActivity {
    param(
        [Parameter(Mandatory)][hashtable]$Aggregate,
        [Parameter(Mandatory)][datetime]$TimestampUtc
    )

    if ($null -eq $Aggregate.lastActivityAt -or $TimestampUtc -gt [datetime]$Aggregate.lastActivityAt) {
        $Aggregate.lastActivityAt = $TimestampUtc
    }
}

function New-DashboardOpaqueId {
    $bytes = New-Object byte[] 12
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-DashboardInstallationIdentity {
    param(
        [string]$ExplicitInstallationId,
        [string]$ExplicitPublisherId,
        [string]$StatePath,
        [Parameter(Mandatory)][datetime]$GeneratedAtUtc,
        [Parameter(Mandatory)][string]$ResolvedOutputPath
    )

    if (-not $StatePath) {
        $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($base)) { $base = $HOME }
        if ([string]::IsNullOrWhiteSpace($base)) { $base = Split-Path $ResolvedOutputPath -Parent }
        $slotHash = (Get-DashboardSha256 -Text $ResolvedOutputPath.ToLowerInvariant()).Substring(0, 16)
        $StatePath = Join-Path $base "DevPilot.AgentDashboard\installation-epoch-$slotHash.json"
    }

    $fullStatePath = [IO.Path]::GetFullPath($StatePath)
    $epoch = $GeneratedAtUtc.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture)
    $state = $null
    if (Test-Path -LiteralPath $fullStatePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $fullStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Dashboard installation state '$fullStatePath' is not valid JSON."
        }
    }

    $storedEpoch = [string](Get-DashboardValue -Object $state -Name 'epoch' -Default '')
    $storedInstallationId = [string](Get-DashboardValue -Object $state -Name 'installationEpochId' -Default '')
    $storedPublisherId = [string](Get-DashboardValue -Object $state -Name 'publisherId' -Default '')

    $resolvedInstallationId = if ($ExplicitInstallationId) {
        $ExplicitInstallationId.ToLowerInvariant()
    }
    elseif ($storedEpoch -ceq $epoch -and $storedInstallationId -cmatch '^[a-f0-9]{24}$') {
        $storedInstallationId
    }
    else {
        New-DashboardOpaqueId
    }
    $resolvedPublisherId = if ($ExplicitPublisherId) {
        $ExplicitPublisherId.ToLowerInvariant()
    }
    elseif ($storedPublisherId -cmatch '^[a-f0-9]{24}$') {
        $storedPublisherId
    }
    else {
        New-DashboardOpaqueId
    }
    if ($resolvedInstallationId -cnotmatch '^[a-f0-9]{24}$') {
        throw 'InstallationEpochId must be 24 hexadecimal characters.'
    }
    if ($resolvedPublisherId -cnotmatch '^[a-f0-9]{24}$') {
        throw 'PublisherId must be 24 hexadecimal characters.'
    }

    $stateDocument = [ordered]@{
        schemaVersion       = 2
        epoch               = $epoch
        installationEpochId = $resolvedInstallationId
        publisherId         = $resolvedPublisherId
    }
    Write-DashboardJsonFile -Path $fullStatePath -Value $stateDocument
    return [pscustomobject]@{
        InstallationEpochId = $resolvedInstallationId
        PublisherId         = $resolvedPublisherId
        StatePath           = $fullStatePath
    }
}

function Write-DashboardJsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $tempPath = "$fullPath.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$fullPath.bak-$PID-$([guid]::NewGuid().ToString('N'))"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        $json = ($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine
        [IO.File]::WriteAllText($tempPath, $json, $utf8)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [IO.File]::Replace($tempPath, $fullPath, $backupPath)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        else {
            [IO.File]::Move($tempPath, $fullPath)
        }
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

# Apply config-driven period if CLI params were not explicitly set.
# This ensures 4–5 operators using the same dashboard-config.json produce
# byte-compatible PeriodStart/PeriodEnd even when run on different days.
$_exporterRepoRoot = Split-Path $PSScriptRoot -Parent
$_exporterConfig = Read-ExporterDashboardConfig -ConfigPath $ConfigPath -RepoRoot $_exporterRepoRoot
if ($null -ne $_exporterConfig) {
    if (-not $PSBoundParameters.ContainsKey('PeriodStart')) { $PeriodStart = $_exporterConfig.PeriodStart }
    if (-not $PSBoundParameters.ContainsKey('PeriodEnd'))   { $PeriodEnd   = $_exporterConfig.PeriodEnd }
}
$startUtc = ConvertTo-DashboardUtc -Value $PeriodStart
$endUtc   = ConvertTo-DashboardUtc -Value $PeriodEnd
$generatedAtUtc = ConvertTo-DashboardUtc -Value $GeneratedAt
if ($startUtc -ge $endUtc) { throw 'PeriodStart must be earlier than PeriodEnd.' }

$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
$identity = Get-DashboardInstallationIdentity -ExplicitInstallationId $InstallationEpochId `
    -ExplicitPublisherId $PublisherId -StatePath $InstallationStatePath `
    -GeneratedAtUtc $generatedAtUtc -ResolvedOutputPath $resolvedOutputPath
$epochId = [string]$identity.InstallationEpochId
$resolvedPublisherId = [string]$identity.PublisherId

$pullRequests = @{}
$weeks = @{}
$reviewerEvents = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$handlerEvents = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$deliveryPlans = @{}
$reviewRuns = New-Object System.Collections.Generic.List[object]
$runEvents = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)

foreach ($item in @(Read-DashboardLogRecords -Path $ReviewerLogPath -StartUtc $startUtc -EndUtc $endUtc `
            -IncludeBeforeStart | Sort-Object Timestamp, Where)) {
    $record = $item.Record
    $where = [string]$item.Where
    $result = (Get-DashboardLogString -Record $record -Name 'result').Trim().ToLowerInvariant()
    $mode = (Get-DashboardLogString -Record $record -Name 'mode').Trim().ToLowerInvariant()
    if ($result -eq 'failed') {
        if ([bool]$item.InPeriod -and $mode -eq 'live') {
            $failedPrId = Get-DashboardLogInt -Record $record -Name 'prId' -Where $where
            $failedFingerprint = @(
                $item.Timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture),
                $result,
                $failedPrId,
                (Get-DashboardLogString -Record $record -Name 'cycle'),
                $mode
            ) -join '|'
            if ($runEvents.Add($failedFingerprint)) {
                [void]$reviewRuns.Add([ordered]@{
                        runId = Get-DashboardSha256 -Text $failedFingerprint
                        timestamp = $item.Timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                        prId = $(if ($failedPrId -gt 0) { $failedPrId } else { $null })
                        status = 'failed'
                        runType = 'failed'
                        findings = 0
                        critical = 0
                        important = 0
                        suggestion = 0
                        commentsAdded = 0
                        recommendedVote = 'none'
                        castVote = 'none'
                    })
            }
        }
        continue
    }
    if ($result -notin @('reviewed', 'delivered', 'incomplete')) { continue }

    $prId = Get-DashboardLogInt -Record $record -Name 'prId' -Where $where
    if ($prId -le 0) { throw "$where.prId must be greater than zero for reviewer result '$result'." }

    $postedCount = Get-DashboardLogInt -Record $record -Name 'postedCount' -Where $where
    $threadRepliesPosted = Get-DashboardLogInt -Record $record -Name 'threadRepliesPosted' -Where $where
    $hasNewFindingCount = Test-DashboardHasValue -Object $record -Name 'newFindingCommentsPosted'
    $hasNewThreadReplyCount = Test-DashboardHasValue -Object $record -Name 'newThreadRepliesPosted'
    if ($hasNewFindingCount -ne $hasNewThreadReplyCount) {
        throw "$where must contain both newly-created comment counters or neither."
    }
    $newFindingCommentsPosted = if ($hasNewFindingCount) {
        Get-DashboardLogInt -Record $record -Name 'newFindingCommentsPosted' -Where $where
    }
    else { 0 }
    $newThreadRepliesPosted = if ($hasNewThreadReplyCount) {
        Get-DashboardLogInt -Record $record -Name 'newThreadRepliesPosted' -Where $where
    }
    else { 0 }
    $findingCount = Get-DashboardLogInt -Record $record -Name 'findingCount' -Where $where
    $criticalCount = Get-DashboardLogInt -Record $record -Name 'critical' -Where $where
    $importantCount = Get-DashboardLogInt -Record $record -Name 'important' -Where $where
    $suggestionCount = Get-DashboardLogInt -Record $record -Name 'suggestion' -Where $where
    if ($result -eq 'reviewed' -and $findingCount -ne ($criticalCount + $importantCount + $suggestionCount)) {
        throw "$where findingCount does not match its severity counts."
    }
    $rawRecommendedVote = (Get-DashboardLogString -Record $record -Name 'recommendedVote' -Default 'none').Trim()
    $recommendedVote = switch ($rawRecommendedVote.ToLowerInvariant()) {
        { $_ -in @('', 'none') } { 'none'; break }
        'approve' { 'approve'; break }
        'approvewithsuggestions' { 'approveWithSuggestions'; break }
        'waitforauthor' { 'waitForAuthor'; break }
        default { throw "$where.recommendedVote is not allowed." }
    }
    $rawVote = (Get-DashboardLogString -Record $record -Name 'castVote' -Default 'none').Trim()
    $castVote = switch ($rawVote.ToLowerInvariant()) {
        { $_ -in @('', 'none') } { 'none'; break }
        'approved' { 'Approved'; break }
        'approvedwithsuggestions' { 'ApprovedWithSuggestions'; break }
        'waitingforauthor' { 'WaitingForAuthor'; break }
        default { throw "$where.castVote is not an allowed reviewer vote." }
    }
    $sourceCommit = Get-DashboardLogString -Record $record -Name 'sourceCommit'
    $artifactPath = Get-DashboardLogString -Record $record -Name 'artifactPath'
    $eventFingerprint = @(
        $item.Timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture),
        $result,
        $prId,
        (Get-DashboardLogString -Record $record -Name 'cycle'),
        (Get-DashboardLogString -Record $record -Name 'mode'),
        $sourceCommit,
        $artifactPath,
        $findingCount,
        $postedCount,
        $threadRepliesPosted,
        $newFindingCommentsPosted,
        $newThreadRepliesPosted,
        $castVote,
        $recommendedVote,
        $criticalCount,
        $importantCount,
        $suggestionCount
    ) -join '|'
    if (-not $reviewerEvents.Add($eventFingerprint)) { continue }

    $planKey = if ($artifactPath) { "artifact|$artifactPath" } else { "legacy|$prId|$sourceCommit" }
    if (-not $deliveryPlans.ContainsKey($planKey)) {
        $deliveryPlans[$planKey] = @{ PostedCount = 0; ThreadRepliesPosted = 0 }
    }
    $plan = $deliveryPlans[$planKey]
    $commentsPostedDelta = if ($hasNewFindingCount) {
        $newFindingCommentsPosted + $newThreadRepliesPosted
    }
    else {
        [Math]::Max(0, $postedCount - [int]$plan.PostedCount) +
            [Math]::Max(0, $threadRepliesPosted - [int]$plan.ThreadRepliesPosted)
    }
    if ($postedCount -gt [int]$plan.PostedCount) { $plan.PostedCount = $postedCount }
    if ($threadRepliesPosted -gt [int]$plan.ThreadRepliesPosted) { $plan.ThreadRepliesPosted = $threadRepliesPosted }
    $voteIsNew = $castVote -ine 'none'
    if (-not [bool]$item.InPeriod) { continue }
    if ($result -ne 'reviewed' -and $commentsPostedDelta -eq 0 -and -not $voteIsNew) { continue }

    if ($result -eq 'reviewed' -and $mode -eq 'live') {
        $commentsEnabled = Get-DashboardLogBool -Record $record -Name 'commentsEnabled' -Where $where
        $threadRepliesEnabled = Get-DashboardLogBool -Record $record -Name 'threadRepliesEnabled' -Where $where
        $summaryEnabled = Get-DashboardLogBool -Record $record -Name 'summaryEnabled' -Where $where
        $voteEnabled = Get-DashboardLogBool -Record $record -Name 'voteEnabled' -Where $where
        $runFingerprint = "run|$eventFingerprint"
        if ($runEvents.Add($runFingerprint)) {
            [void]$reviewRuns.Add([ordered]@{
                    runId = Get-DashboardSha256 -Text $runFingerprint
                    timestamp = $item.Timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    prId = $prId
                    status = 'completed'
                    runType = $(if ($commentsEnabled -or $threadRepliesEnabled -or $summaryEnabled -or $voteEnabled) { 'posting' } else { 'preview' })
                    findings = $findingCount
                    critical = $criticalCount
                    important = $importantCount
                    suggestion = $suggestionCount
                    commentsAdded = $commentsPostedDelta
                    recommendedVote = $recommendedVote
                    castVote = $castVote
                })
        }
    }

    $pr = Get-DashboardPrAggregate -Map $pullRequests -PrId $prId
    $week = Get-DashboardWeekAggregate -Map $weeks -TimestampUtc $item.Timestamp
    Update-DashboardLastActivity -Aggregate $pr -TimestampUtc $item.Timestamp

    if ($result -eq 'reviewed') {
        $pr.reviewed = $true
        [void]$week.reviewedPrIds.Add($prId)
        if ($null -eq $pr.latestReviewAt -or $item.Timestamp -ge [datetime]$pr.latestReviewAt) {
            $pr.latestReviewAt = $item.Timestamp
            $pr.findings = $findingCount
        }
    }

    if ($commentsPostedDelta -gt 0) {
        $pr.postedComments = [int]$pr.postedComments + $commentsPostedDelta
        $week.commentsPosted = [int]$week.commentsPosted + $commentsPostedDelta
    }

    if ($voteIsNew) {
        if ($null -eq $pr.voteAt -or $item.Timestamp -ge [datetime]$pr.voteAt) {
            $pr.vote = $castVote
            $pr.voteAt = $item.Timestamp
        }
        if ($castVote -in @('Approved', 'ApprovedWithSuggestions')) {
            $pr.approved = $true
            [void]$week.approvedPrIds.Add($prId)
        }
    }
}

foreach ($item in @(Read-DashboardLogRecords -Path $ReviewHandlerLogPath -StartUtc $startUtc -EndUtc $endUtc | Sort-Object Timestamp, Where)) {
    $record = $item.Record
    $where = [string]$item.Where
    $result = (Get-DashboardLogString -Record $record -Name 'result').Trim().ToLowerInvariant()
    if ($result -ne 'handled') { continue }

    $prId = Get-DashboardLogInt -Record $record -Name 'prId' -Where $where
    if ($prId -le 0) { throw "$where.prId must be greater than zero for handler result 'handled'." }
    $commitsPushed = Get-DashboardLogInt -Record $record -Name 'commitsPushed' -Where $where
    $autoCompleted = Get-DashboardLogBool -Record $record -Name 'autoCompleted' -Where $where
    $eventFingerprint = @(
        $item.Timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture),
        $result,
        $prId,
        (Get-DashboardLogString -Record $record -Name 'cycle'),
        (Get-DashboardLogString -Record $record -Name 'sourceCommit'),
        $commitsPushed,
        $autoCompleted
    ) -join '|'
    if (-not $handlerEvents.Add($eventFingerprint)) { continue }

    $pr = Get-DashboardPrAggregate -Map $pullRequests -PrId $prId
    $week = Get-DashboardWeekAggregate -Map $weeks -TimestampUtc $item.Timestamp
    Update-DashboardLastActivity -Aggregate $pr -TimestampUtc $item.Timestamp
    if ($commitsPushed -gt 0) {
        $pr.commitPushed = $true
        [void]$week.commitPushedPrIds.Add($prId)
    }
    if ($autoCompleted) {
        $pr.autoComplete = $true
        [void]$week.autoCompletedPrIds.Add($prId)
    }
}

$pullRequestRows = @(
    foreach ($pr in @($pullRequests.Values | Sort-Object @{ Expression = { $_.lastActivityAt }; Descending = $true }, prId)) {
        [ordered]@{
            prId           = [int]$pr.prId
            date           = ([datetime]$pr.lastActivityAt).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            reviewed       = [bool]$pr.reviewed
            reviewAt       = $(if ($pr.latestReviewAt) {
                    ([datetime]$pr.latestReviewAt).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                }
                else { $null })
            findings       = [int]$pr.findings
            postedComments = [int]$pr.postedComments
            vote           = [string]$pr.vote
            voteAt         = $(if ($pr.voteAt) {
                    ([datetime]$pr.voteAt).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                }
                else { $null })
            approved       = [bool]$pr.approved
            commitPushed   = [bool]$pr.commitPushed
            autoComplete   = [bool]$pr.autoComplete
        }
    }
)

$weeklyRows = @(
    foreach ($week in @($weeks.Values | Sort-Object weekStart)) {
        $reviewedIds = @($week.reviewedPrIds | Sort-Object)
        $approvedIds = @($week.approvedPrIds | Sort-Object)
        $pushedIds = @($week.commitPushedPrIds | Sort-Object)
        $autoIds = @($week.autoCompletedPrIds | Sort-Object)
        [ordered]@{
            weekStart             = [string]$week.weekStart
            prsReviewed           = $reviewedIds.Count
            commentsPosted        = [int]$week.commentsPosted
            prsApproved           = $approvedIds.Count
            prsWithCommitsPushed  = $pushedIds.Count
            prsAutoCompleted      = $autoIds.Count
            reviewedPrIds         = [object[]]$reviewedIds
            approvedPrIds         = [object[]]$approvedIds
            commitPushedPrIds     = [object[]]$pushedIds
            autoCompletedPrIds    = [object[]]$autoIds
        }
    }
)

$reviewedPrs = @($pullRequestRows | Where-Object { $_.reviewed })
$approvedPrs = @($pullRequestRows | Where-Object { $_.approved })
$pushedPrs = @($pullRequestRows | Where-Object { $_.commitPushed })
$autoCompletedPrs = @($pullRequestRows | Where-Object { $_.autoComplete })
$commentsPostedTotal = 0
foreach ($row in $pullRequestRows) { $commentsPostedTotal += [int]$row.postedComments }

$snapshot = [ordered]@{
    kind                       = 'devpilot-agent-dashboard-snapshot'
    schemaVersion              = 2
    generatedAt                = $generatedAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    installationEpochId        = $epochId
    publisherId                = $resolvedPublisherId
    periodStart                = $startUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    periodEnd                  = $endUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    prsReviewed                = $reviewedPrs.Count
    commentsPosted             = $commentsPostedTotal
    prsApproved                = $approvedPrs.Count
    prsWithCommitsPushed       = $pushedPrs.Count
    prsAutoCompleted           = $autoCompletedPrs.Count
    commentOutcomes            = [ordered]@{
        available        = $false
        fixed            = 0
        wontFix          = 0
        byDesign         = 0
        closed           = 0
        mergedUnresolved = 0
        stillOpen        = 0
    }
    weeklyActivity              = [object[]]$weeklyRows
    pullRequests                = [object[]]$pullRequestRows
    reviewRuns                  = [object[]]@($reviewRuns | Sort-Object @{ Expression = { $_.timestamp }; Descending = $true }, runId)
}

Write-DashboardJsonFile -Path $resolvedOutputPath -Value $snapshot
Write-Host ("Dashboard snapshot written to '{0}' ({1} reviewed PR(s), {2} posted comment(s), publisher {3})." -f `
        $resolvedOutputPath, $snapshot.prsReviewed, $snapshot.commentsPosted, $resolvedPublisherId) -ForegroundColor Green
