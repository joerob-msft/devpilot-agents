#requires -Version 7.0

<#
.SYNOPSIS
    Builds a dependency-free static dashboard from sanitized agent snapshots.

.DESCRIPTION
    Selects the newest snapshot for each installation epoch, validates every
    metric against the snapshot's per-PR summaries, combines distinct-PR and
    weekly activity, optionally adds aggregate comment outcomes, and writes one
    self-contained HTML file.
#>
[CmdletBinding()]
param(
    [string[]]$SnapshotPath = @((Join-Path (Split-Path $PSScriptRoot -Parent) 'dashboard-data')),

    [string]$CommentOutcomePath,

    [string]$RosterPath,

    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dashboard-data\index.html'),

    [ValidateRange(1, 100)]
    [int]$RecentPullRequestCount = 12,

    [ValidateRange(1, 720)]
    [int]$StaleAfterHours = 48,

    [string]$ConfigPath,

    [datetime]$GeneratedAt = [datetime]::UtcNow
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-DashboardConfig {
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
    $kind = [string](Get-DashboardValue -Object $config -Name 'kind' -Default '')
    if ($kind -cne 'devpilot-agent-dashboard-config') {
        throw "Dashboard config '$resolved' has an unsupported kind '$kind'."
    }
    $schemaVersion = Get-DashboardValue -Object $config -Name 'schemaVersion'
    if ($null -eq $schemaVersion -or [int]$schemaVersion -ne 1) {
        throw "Dashboard config '$resolved' has an unsupported schemaVersion."
    }
    $window = Get-DashboardValue -Object $config -Name 'reportingWindow'
    if ($null -eq $window) { throw "Dashboard config '$resolved' must include 'reportingWindow'." }
    $policy = [string](Get-DashboardValue -Object $window -Name 'policy' -Default '')
    if ($policy -cne 'calendar-month') {
        throw "Dashboard config '$resolved' has unsupported reportingWindow.policy '$policy'. Supported: calendar-month."
    }
    $yearVal = Get-DashboardValue -Object $window -Name 'year'
    $monthVal = Get-DashboardValue -Object $window -Name 'month'
    if ($null -eq $yearVal -or $null -eq $monthVal) {
        throw "Dashboard config '$resolved' calendar-month policy requires 'year' and 'month'."
    }
    $yearInt = [int]$yearVal; $monthInt = [int]$monthVal
    if ($yearInt -lt 2020 -or $yearInt -gt 2100 -or $monthInt -lt 1 -or $monthInt -gt 12) {
        throw "Dashboard config '$resolved' has an invalid year ($yearInt) or month ($monthInt)."
    }
    $staleVal = Get-DashboardValue -Object $config -Name 'staleAfterHours'
    if ($null -ne $staleVal -and ([int]$staleVal -lt 1 -or [int]$staleVal -gt 720)) {
        throw "Dashboard config '$resolved' staleAfterHours must be 1–720."
    }
    $periodStart = [datetime]::new($yearInt, $monthInt, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return [pscustomobject]@{
        PeriodStart     = $periodStart
        PeriodEnd       = $periodStart.AddMonths(1)
        StaleAfterHours = if ($null -ne $staleVal) { [int]$staleVal } else { $null }
    }
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

function Get-DashboardStrictInt {
    param($Value, [Parameter(Mandatory)][string]$Where, [int]$Min = 0)

    if ($null -eq $Value -or $Value -is [bool] -or
        -not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
            $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal])) {
        throw "$Where must be an integer."
    }
    $asDecimal = [decimal]$Value
    if ($asDecimal -ne [decimal]::Floor($asDecimal) -or $asDecimal -lt $Min -or $asDecimal -gt [int]::MaxValue) {
        throw "$Where must be an integer between $Min and $([int]::MaxValue)."
    }
    return [int]$asDecimal
}

function Get-DashboardStrictBool {
    param($Value, [Parameter(Mandatory)][string]$Where)
    if ($Value -isnot [bool]) { throw "$Where must be a JSON boolean." }
    return [bool]$Value
}

function Get-DashboardRosterString {
    param($Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where, [int]$MaxLength = 100, [switch]$AllowEmpty)
    $value = Get-DashboardValue -Object $Object -Name $Name
    if ($value -isnot [string] -or $value.Length -gt $MaxLength -or
        (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($value)) -or $value -match '[\x00-\x1f]') {
        throw "$Where.$Name must be a bounded plain string."
    }
    return $value.Trim()
}

function Get-DashboardRosterStringArray {
    param($Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where, [int]$MaxLength = 320)
    $value = Get-DashboardValue -Object $Object -Name $Name -Default @()
    if ($null -eq $value) { return @() }
    if ($value -is [System.Management.Automation.PSCustomObject]) { throw "$Where.$Name must be an array of strings." }
    $items = if ($value -is [string]) { @($value) } else { @($value) }
    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item) -or
            $item.Length -gt $MaxLength -or $item -match '[\x00-\x1f]') {
            throw "$Where.$Name entries must be bounded plain strings."
        }
        $normalized = $item.Trim()
        if (-not $seen.Add($normalized)) { throw "$Where.$Name contains duplicate '$normalized'." }
        [void]$result.Add($normalized)
    }
    return $result.ToArray()
}

function Read-DashboardRoster {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ People = @(); PersonById = @{}; PublisherToPerson = @{}; ContentSha256 = $null }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Dashboard roster '$Path' does not exist." }
    $bytes = [IO.File]::ReadAllBytes($Path)
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        $roster = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "Dashboard roster '$Path' is not valid UTF-8 JSON." }
    if ([string](Get-DashboardValue -Object $roster -Name 'kind' -Default '') -cne 'devpilot-agent-dashboard-roster' -or
        (Get-DashboardStrictInt -Value (Get-DashboardValue -Object $roster -Name 'schemaVersion') -Where "'$Path'.schemaVersion" -Min 1) -ne 1) {
        throw "Dashboard roster '$Path' has an unsupported kind or schema version."
    }
    $people = New-Object System.Collections.Generic.List[object]
    $personById = @{}
    $publisherToPerson = @{}
    $adoIds = @{}
    $adoNames = @{}
    foreach ($person in @(Get-DashboardValue -Object $roster -Name 'people' -Default @())) {
        if ($person -isnot [System.Management.Automation.PSCustomObject]) { throw "Dashboard roster '$Path'.people must contain objects." }
        $personId = Get-DashboardRosterString -Object $person -Name 'personId' -Where "'$Path'.people" -MaxLength 64
        if ($personId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $personById.ContainsKey($personId)) {
            throw "Dashboard roster '$Path' has an invalid or duplicate personId '$personId'."
        }
        $displayName = Get-DashboardRosterString -Object $person -Name 'displayName' -Where "'$Path'.people[$personId]"
        $team = Get-DashboardRosterString -Object $person -Name 'team' -Where "'$Path'.people[$personId]" -AllowEmpty
        $publisherIds = @(Get-DashboardRosterStringArray -Object $person -Name 'publisherIds' -Where "'$Path'.people[$personId]" -MaxLength 24)
        foreach ($publisherId in $publisherIds) {
            if ($publisherId -cnotmatch '^[a-f0-9]{24}$' -or $publisherToPerson.ContainsKey($publisherId)) {
                throw "Dashboard roster '$Path' has an invalid or duplicate publisherId."
            }
            $publisherToPerson[$publisherId] = $personId
        }
        foreach ($identityId in @(Get-DashboardRosterStringArray -Object $person -Name 'adoIdentityIds' -Where "'$Path'.people[$personId]")) {
            if ($adoIds.ContainsKey($identityId)) { throw "Dashboard roster '$Path' maps one ADO identity ID more than once." }
            $adoIds[$identityId] = $personId
        }
        foreach ($uniqueName in @(Get-DashboardRosterStringArray -Object $person -Name 'adoUniqueNames' -Where "'$Path'.people[$personId]")) {
            if ($adoNames.ContainsKey($uniqueName)) { throw "Dashboard roster '$Path' maps one ADO unique name more than once." }
            $adoNames[$uniqueName] = $personId
        }
        $normalized = [pscustomobject]@{
            PersonId = $personId; DisplayName = $displayName; Team = $team; PublisherIds = $publisherIds
        }
        $personById[$personId] = $normalized
        [void]$people.Add($normalized)
    }
    return [pscustomobject]@{
        People = $people.ToArray(); PersonById = $personById; PublisherToPerson = $publisherToPerson
        ContentSha256 = Get-DashboardBytesSha256 -Bytes $bytes
    }
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

function ConvertTo-DashboardUtc {
    param([Parameter(Mandatory)][datetime]$Value)
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
        return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    return $Value.ToUniversalTime()
}

function Get-DashboardBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function Get-DashboardSnapshotSetSha256 {
    param([object[]]$Snapshots)
    $hashes = @($Snapshots | ForEach-Object { [string]$_.ContentSha256 } | Sort-Object)
    $material = "devpilot.dashboard.snapshot-set.v1`n$($hashes -join "`n")"
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($material)))).ToLowerInvariant()
}

function ConvertFrom-DashboardDate {
    param($Value, [Parameter(Mandatory)][string]$Where)

    if ($Value -isnot [string]) { throw "$Where must use yyyy-MM-dd." }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        throw "$Where '$Value' must use yyyy-MM-dd."
    }
    return [datetime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
}

function Get-DashboardIntArray {
    param($Value, [Parameter(Mandatory)][string]$Where)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        throw "$Where must be an array of positive integers."
    }
    $result = New-Object System.Collections.Generic.List[int]
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($item in @($Value)) {
        $number = Get-DashboardStrictInt -Value $item -Where $Where -Min 1
        if (-not $seen.Add($number)) { throw "$Where contains duplicate pull request $number." }
        [void]$result.Add($number)
    }
    return $result.ToArray()
}

function Test-DashboardIntSetEquals {
    param([int[]]$Expected, [Parameter(Mandatory)]$Actual)
    if (@($Expected).Count -ne $Actual.Count) { return $false }
    foreach ($value in @($Expected)) {
        if (-not $Actual.Contains([int]$value)) { return $false }
    }
    return $true
}

function Resolve-DashboardSnapshotFiles {
    param([string[]]$Path)

    $files = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($Path)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $items = @()
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($candidate)) {
            $items = @(Get-ChildItem -Path $candidate -File -ErrorAction SilentlyContinue)
        }
        elseif (Test-Path -LiteralPath $candidate -PathType Container) {
            $items = @(Get-ChildItem -LiteralPath $candidate -File -Filter '*.snapshot.json')
        }
        elseif (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $items = @(Get-Item -LiteralPath $candidate)
        }
        else {
            Write-Warning "Dashboard snapshot path '$candidate' does not exist; the dashboard will use the snapshots that are available."
            continue
        }
        foreach ($item in $items) {
            $fullPath = [IO.Path]::GetFullPath($item.FullName)
            if ($seen.Add($fullPath)) { [void]$files.Add($fullPath) }
        }
    }
    return $files.ToArray()
}

function Read-DashboardSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        $snapshot = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Dashboard snapshot '$Path' is not valid UTF-8 JSON."
    }
    if ($snapshot -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Dashboard snapshot '$Path' must contain one JSON object."
    }
    if ([string](Get-DashboardValue -Object $snapshot -Name 'kind' -Default '') -cne 'devpilot-agent-dashboard-snapshot') {
        throw "Dashboard snapshot '$Path' has an unsupported kind."
    }
    if ((Get-DashboardStrictInt -Value (Get-DashboardValue -Object $snapshot -Name 'schemaVersion') `
            -Where "'$Path'.schemaVersion" -Min 1) -ne 2) {
        throw "Dashboard snapshot '$Path' uses an unsupported schema; regenerate it with the schema-v2 exporter."
    }
    $installationId = [string](Get-DashboardValue -Object $snapshot -Name 'installationEpochId' -Default '')
    if ($installationId -cnotmatch '^[a-f0-9]{24}$') {
        throw "Dashboard snapshot '$Path'.installationEpochId is invalid."
    }
    $publisherId = [string](Get-DashboardValue -Object $snapshot -Name 'publisherId' -Default '')
    if ($publisherId -cnotmatch '^[a-f0-9]{24}$') { throw "Dashboard snapshot '$Path'.publisherId is invalid." }

    $generatedAt = ConvertFrom-DashboardTimestamp -Value (Get-DashboardValue -Object $snapshot -Name 'generatedAt') `
        -Where "'$Path'.generatedAt"
    $periodStart = ConvertFrom-DashboardTimestamp -Value (Get-DashboardValue -Object $snapshot -Name 'periodStart') `
        -Where "'$Path'.periodStart"
    $periodEnd = ConvertFrom-DashboardTimestamp -Value (Get-DashboardValue -Object $snapshot -Name 'periodEnd') `
        -Where "'$Path'.periodEnd"
    if ($periodStart -ge $periodEnd) { throw "Dashboard snapshot '$Path' has an invalid period." }

    $rows = @(Get-DashboardValue -Object $snapshot -Name 'pullRequests' -Default @())
    if ($rows.Count -gt 10000) { throw "Dashboard snapshot '$Path' has more than 10000 pull-request rows." }
    $normalizedRows = New-Object System.Collections.Generic.List[object]
    $rowIds = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($row in $rows) {
        if ($row -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Dashboard snapshot '$Path'.pullRequests must contain only objects."
        }
        $prId = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $row -Name 'prId') `
            -Where "'$Path'.pullRequests.prId" -Min 1
        if (-not $rowIds.Add($prId)) { throw "Dashboard snapshot '$Path' contains duplicate pull request $prId." }
        $date = ConvertFrom-DashboardDate -Value (Get-DashboardValue -Object $row -Name 'date') `
            -Where "'$Path'.pullRequests[$prId].date"
        $vote = [string](Get-DashboardValue -Object $row -Name 'vote' -Default 'none')
        if ($vote -notin @('none', 'Approved', 'ApprovedWithSuggestions', 'WaitingForAuthor')) {
            throw "Dashboard snapshot '$Path'.pullRequests[$prId].vote '$vote' is unsupported."
        }
        $voteAtValue = Get-DashboardValue -Object $row -Name 'voteAt'
        $voteAt = if ($null -ne $voteAtValue) {
            ConvertFrom-DashboardTimestamp -Value $voteAtValue -Where "'$Path'.pullRequests[$prId].voteAt"
        }
        else { $null }
        if (($vote -eq 'none') -ne ($null -eq $voteAt)) {
            throw "Dashboard snapshot '$Path'.pullRequests[$prId] must pair a non-none vote with voteAt."
        }
        $reviewed = Get-DashboardStrictBool -Value (Get-DashboardValue -Object $row -Name 'reviewed') `
            -Where "'$Path'.pullRequests[$prId].reviewed"
        $reviewAtValue = Get-DashboardValue -Object $row -Name 'reviewAt'
        $reviewAt = if ($null -ne $reviewAtValue) {
            ConvertFrom-DashboardTimestamp -Value $reviewAtValue -Where "'$Path'.pullRequests[$prId].reviewAt"
        }
        else { $null }
        if ($reviewed -ne ($null -ne $reviewAt)) {
            throw "Dashboard snapshot '$Path'.pullRequests[$prId] must pair reviewed=true with reviewAt."
        }
        $findingCount = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $row -Name 'findings') `
            -Where "'$Path'.pullRequests[$prId].findings"
        if (-not $reviewed -and $findingCount -ne 0) {
            throw "Dashboard snapshot '$Path'.pullRequests[$prId] cannot report findings without a review."
        }
        [void]$normalizedRows.Add([pscustomobject]@{
                PrId           = $prId
                Date           = $date
                Reviewed       = $reviewed
                ReviewAt       = $reviewAt
                Findings       = $findingCount
                PostedComments = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $row -Name 'postedComments') `
                    -Where "'$Path'.pullRequests[$prId].postedComments"
                Vote           = $vote
                VoteAt         = $voteAt
                Approved       = Get-DashboardStrictBool -Value (Get-DashboardValue -Object $row -Name 'approved') `
                    -Where "'$Path'.pullRequests[$prId].approved"
                CommitPushed   = Get-DashboardStrictBool -Value (Get-DashboardValue -Object $row -Name 'commitPushed') `
                    -Where "'$Path'.pullRequests[$prId].commitPushed"
                AutoComplete   = Get-DashboardStrictBool -Value (Get-DashboardValue -Object $row -Name 'autoComplete') `
                    -Where "'$Path'.pullRequests[$prId].autoComplete"
            })
    }

    $weeklyRows = @(Get-DashboardValue -Object $snapshot -Name 'weeklyActivity' -Default @())
    if ($weeklyRows.Count -gt 520) { throw "Dashboard snapshot '$Path' has too many weekly rows." }
    $normalizedWeeks = New-Object System.Collections.Generic.List[object]
    $weekKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($week in $weeklyRows) {
        if ($week -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Dashboard snapshot '$Path'.weeklyActivity must contain only objects."
        }
        $weekDate = ConvertFrom-DashboardDate -Value (Get-DashboardValue -Object $week -Name 'weekStart') `
            -Where "'$Path'.weeklyActivity.weekStart"
        $weekKey = $weekDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        if (-not $weekKeys.Add($weekKey)) { throw "Dashboard snapshot '$Path' contains duplicate week $weekKey." }
        $reviewedIds = @(Get-DashboardIntArray -Value (Get-DashboardValue -Object $week -Name 'reviewedPrIds' -Default @()) `
                -Where "'$Path'.weeklyActivity[$weekKey].reviewedPrIds")
        $approvedIds = @(Get-DashboardIntArray -Value (Get-DashboardValue -Object $week -Name 'approvedPrIds' -Default @()) `
                -Where "'$Path'.weeklyActivity[$weekKey].approvedPrIds")
        $pushedIds = @(Get-DashboardIntArray -Value (Get-DashboardValue -Object $week -Name 'commitPushedPrIds' -Default @()) `
                -Where "'$Path'.weeklyActivity[$weekKey].commitPushedPrIds")
        $autoIds = @(Get-DashboardIntArray -Value (Get-DashboardValue -Object $week -Name 'autoCompletedPrIds' -Default @()) `
                -Where "'$Path'.weeklyActivity[$weekKey].autoCompletedPrIds")
        $declaredReviewed = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $week -Name 'prsReviewed') `
            -Where "'$Path'.weeklyActivity[$weekKey].prsReviewed"
        $declaredApproved = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $week -Name 'prsApproved') `
            -Where "'$Path'.weeklyActivity[$weekKey].prsApproved"
        $declaredPushed = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $week -Name 'prsWithCommitsPushed') `
            -Where "'$Path'.weeklyActivity[$weekKey].prsWithCommitsPushed"
        $declaredAuto = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $week -Name 'prsAutoCompleted') `
            -Where "'$Path'.weeklyActivity[$weekKey].prsAutoCompleted"
        if ($declaredReviewed -ne $reviewedIds.Count -or $declaredApproved -ne $approvedIds.Count -or
            $declaredPushed -ne $pushedIds.Count -or $declaredAuto -ne $autoIds.Count) {
            throw "Dashboard snapshot '$Path'.weeklyActivity[$weekKey] counts do not match its PR id arrays."
        }
        foreach ($referencedId in @($reviewedIds + $approvedIds + $pushedIds + $autoIds)) {
            if (-not $rowIds.Contains([int]$referencedId)) {
                throw "Dashboard snapshot '$Path'.weeklyActivity[$weekKey] references missing pull request $referencedId."
            }
        }
        [void]$normalizedWeeks.Add([pscustomobject]@{
                WeekStart          = $weekDate
                CommentsPosted     = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $week -Name 'commentsPosted') `
                    -Where "'$Path'.weeklyActivity[$weekKey].commentsPosted"
                ReviewedPrIds      = [int[]]$reviewedIds
                ApprovedPrIds      = [int[]]$approvedIds
                CommitPushedPrIds  = [int[]]$pushedIds
                AutoCompletedPrIds = [int[]]$autoIds
            })
    }

    $computedReviewed = @($normalizedRows | Where-Object Reviewed).Count
    $computedComments = 0
    foreach ($row in $normalizedRows) { $computedComments += [int]$row.PostedComments }
    $computedApproved = @($normalizedRows | Where-Object Approved).Count
    $computedPushed = @($normalizedRows | Where-Object CommitPushed).Count
    $computedAuto = @($normalizedRows | Where-Object AutoComplete).Count
    $weeklyComments = 0
    $weeklyReviewed = New-Object 'System.Collections.Generic.HashSet[int]'
    $weeklyApproved = New-Object 'System.Collections.Generic.HashSet[int]'
    $weeklyPushed = New-Object 'System.Collections.Generic.HashSet[int]'
    $weeklyAuto = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($week in $normalizedWeeks) {
        $weeklyComments += [int]$week.CommentsPosted
        foreach ($prId in $week.ReviewedPrIds) { [void]$weeklyReviewed.Add([int]$prId) }
        foreach ($prId in $week.ApprovedPrIds) { [void]$weeklyApproved.Add([int]$prId) }
        foreach ($prId in $week.CommitPushedPrIds) { [void]$weeklyPushed.Add([int]$prId) }
        foreach ($prId in $week.AutoCompletedPrIds) { [void]$weeklyAuto.Add([int]$prId) }
    }
    $expectedReviewedIds = @($normalizedRows | Where-Object Reviewed | ForEach-Object PrId | Sort-Object)
    $expectedApprovedIds = @($normalizedRows | Where-Object Approved | ForEach-Object PrId | Sort-Object)
    $expectedPushedIds = @($normalizedRows | Where-Object CommitPushed | ForEach-Object PrId | Sort-Object)
    $expectedAutoIds = @($normalizedRows | Where-Object AutoComplete | ForEach-Object PrId | Sort-Object)
    if ($weeklyComments -ne $computedComments -or
        -not (Test-DashboardIntSetEquals -Expected $expectedReviewedIds -Actual $weeklyReviewed) -or
        -not (Test-DashboardIntSetEquals -Expected $expectedApprovedIds -Actual $weeklyApproved) -or
        -not (Test-DashboardIntSetEquals -Expected $expectedPushedIds -Actual $weeklyPushed) -or
        -not (Test-DashboardIntSetEquals -Expected $expectedAutoIds -Actual $weeklyAuto)) {
        throw "Dashboard snapshot '$Path' weekly activity does not reconcile with its pull-request rows."
    }
    $declared = @{
        prsReviewed          = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $snapshot -Name 'prsReviewed') -Where "'$Path'.prsReviewed"
        commentsPosted       = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $snapshot -Name 'commentsPosted') -Where "'$Path'.commentsPosted"
        prsApproved          = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $snapshot -Name 'prsApproved') -Where "'$Path'.prsApproved"
        prsWithCommitsPushed = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $snapshot -Name 'prsWithCommitsPushed') -Where "'$Path'.prsWithCommitsPushed"
        prsAutoCompleted     = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $snapshot -Name 'prsAutoCompleted') -Where "'$Path'.prsAutoCompleted"
    }
    if ($declared.prsReviewed -ne $computedReviewed -or $declared.commentsPosted -ne $computedComments -or
        $declared.prsApproved -ne $computedApproved -or $declared.prsWithCommitsPushed -ne $computedPushed -or
        $declared.prsAutoCompleted -ne $computedAuto) {
        throw "Dashboard snapshot '$Path' aggregate metrics do not match its pull-request rows."
    }

    $normalizedRuns = New-Object System.Collections.Generic.List[object]
    $runIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($run in @(Get-DashboardValue -Object $snapshot -Name 'reviewRuns' -Default @())) {
        if ($run -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Dashboard snapshot '$Path'.reviewRuns must contain objects."
        }
        $runId = [string](Get-DashboardValue -Object $run -Name 'runId' -Default '')
        if ($runId -cnotmatch '^[a-f0-9]{64}$' -or -not $runIds.Add($runId)) {
            throw "Dashboard snapshot '$Path'.reviewRuns contains an invalid or duplicate runId."
        }
        $runAt = ConvertFrom-DashboardTimestamp -Value (Get-DashboardValue -Object $run -Name 'timestamp') `
            -Where "'$Path'.reviewRuns[$runId].timestamp"
        if ($runAt -lt $periodStart -or $runAt -ge $periodEnd) {
            throw "Dashboard snapshot '$Path'.reviewRuns[$runId] falls outside its reporting period."
        }
        $runPrValue = Get-DashboardValue -Object $run -Name 'prId'
        $runPrId = if ($null -eq $runPrValue) { $null } else {
            Get-DashboardStrictInt -Value $runPrValue -Where "'$Path'.reviewRuns[$runId].prId" -Min 1
        }
        $status = [string](Get-DashboardValue -Object $run -Name 'status' -Default '')
        $runType = [string](Get-DashboardValue -Object $run -Name 'runType' -Default '')
        if ($status -notin @('completed', 'failed') -or $runType -notin @('preview', 'posting', 'failed') -or
            (($status -eq 'failed') -ne ($runType -eq 'failed'))) {
            throw "Dashboard snapshot '$Path'.reviewRuns[$runId] has an invalid status or runType."
        }
        $critical = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $run -Name 'critical') -Where "'$Path'.reviewRuns[$runId].critical"
        $important = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $run -Name 'important') -Where "'$Path'.reviewRuns[$runId].important"
        $suggestion = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $run -Name 'suggestion') -Where "'$Path'.reviewRuns[$runId].suggestion"
        $findings = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $run -Name 'findings') -Where "'$Path'.reviewRuns[$runId].findings"
        if ($findings -ne ($critical + $important + $suggestion)) {
            throw "Dashboard snapshot '$Path'.reviewRuns[$runId] finding total is inconsistent."
        }
        $recommendedVote = [string](Get-DashboardValue -Object $run -Name 'recommendedVote' -Default '')
        if ($recommendedVote -notin @('none', 'approve', 'approveWithSuggestions', 'waitForAuthor')) {
            throw "Dashboard snapshot '$Path'.reviewRuns[$runId] has an invalid recommended vote."
        }
        $castVote = [string](Get-DashboardValue -Object $run -Name 'castVote' -Default '')
        if ($castVote -notin @('none', 'Approved', 'ApprovedWithSuggestions', 'WaitingForAuthor')) {
            throw "Dashboard snapshot '$Path'.reviewRuns[$runId] has an invalid cast vote."
        }
        [void]$normalizedRuns.Add([pscustomobject]@{
                RunId = $runId; Timestamp = $runAt; PrId = $runPrId; Status = $status; RunType = $runType
                Findings = $findings; Critical = $critical; Important = $important; Suggestion = $suggestion
                CommentsAdded = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $run -Name 'commentsAdded') -Where "'$Path'.reviewRuns[$runId].commentsAdded"
                RecommendedVote = $recommendedVote; CastVote = $castVote
            })
    }

    return [pscustomobject]@{
        Path                = $Path
        InstallationEpochId = $installationId
        PublisherId         = $publisherId
        GeneratedAt         = $generatedAt
        PeriodStart         = $periodStart
        PeriodEnd           = $periodEnd
        ContentSha256       = Get-DashboardBytesSha256 -Bytes $bytes
        PullRequests        = $normalizedRows.ToArray()
        WeeklyActivity      = $normalizedWeeks.ToArray()
        ReviewRuns          = $normalizedRuns.ToArray()
    }
}

function Read-DashboardCommentOutcomes {
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSnapshotSetSha256,
        $ExpectedRosterSha256,
        $ExpectedPeriodStart,
        $ExpectedPeriodEnd
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            Available = $false; Fixed = 0; WontFix = 0; ByDesign = 0; Closed = 0
            MergedUnresolved = 0; StillOpen = 0; Decided = 0; UsefulnessPercent = $null; LowVolume = $true
            PeopleById = @{}; UnmappedFindingThreads = 0
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warning "Comment outcome file '$Path' does not exist; usefulness will show as data accumulating."
        return [pscustomobject]@{
            Available = $false; Fixed = 0; WontFix = 0; ByDesign = 0; Closed = 0
            MergedUnresolved = 0; StillOpen = 0; Decided = 0; UsefulnessPercent = $null; LowVolume = $true
            PeopleById = @{}; UnmappedFindingThreads = 0
        }
    }

    try {
        $outcomes = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Comment outcome file '$Path' is not valid JSON."
    }
    if ([string](Get-DashboardValue -Object $outcomes -Name 'kind' -Default '') -cne 'devpilot-agent-dashboard-comment-outcomes') {
        throw "Comment outcome file '$Path' has an unsupported kind."
    }
    if ((Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'schemaVersion') `
            -Where "'$Path'.schemaVersion" -Min 1) -ne 2) {
        throw "Comment outcome file '$Path' uses an unsupported schema; regenerate it with the schema-v2 collector."
    }
    [void](ConvertFrom-DashboardTimestamp -Value (Get-DashboardValue -Object $outcomes -Name 'generatedAt') `
            -Where "'$Path'.generatedAt")
    $snapshotSetSha256 = [string](Get-DashboardValue -Object $outcomes -Name 'snapshotSetSha256' -Default '')
    if ($snapshotSetSha256 -cnotmatch '^[a-f0-9]{64}$' -or $snapshotSetSha256 -cne $ExpectedSnapshotSetSha256) {
        throw "Comment outcome file '$Path' was not collected from the current snapshot set."
    }
    $rosterSha256 = Get-DashboardValue -Object $outcomes -Name 'rosterSha256'
    if ($null -eq $ExpectedRosterSha256) {
        if ($null -ne $rosterSha256) { throw "Comment outcome file '$Path' was collected with a roster but this build was not." }
    }
    elseif ($rosterSha256 -isnot [string] -or $rosterSha256 -cne [string]$ExpectedRosterSha256) {
        throw "Comment outcome file '$Path' was not collected with the current roster."
    }
    $declaredPeriodStart = Get-DashboardValue -Object $outcomes -Name 'periodStart'
    $declaredPeriodEnd = Get-DashboardValue -Object $outcomes -Name 'periodEnd'
    if ($null -eq $ExpectedPeriodStart -or $null -eq $ExpectedPeriodEnd) {
        if ($null -ne $declaredPeriodStart -or $null -ne $declaredPeriodEnd) {
            throw "Comment outcome file '$Path' has a reporting period but the current snapshot set is empty."
        }
    }
    else {
        $outcomePeriodStart = ConvertFrom-DashboardTimestamp -Value $declaredPeriodStart -Where "'$Path'.periodStart"
        $outcomePeriodEnd = ConvertFrom-DashboardTimestamp -Value $declaredPeriodEnd -Where "'$Path'.periodEnd"
        if ($outcomePeriodStart -ne [datetime]$ExpectedPeriodStart -or $outcomePeriodEnd -ne [datetime]$ExpectedPeriodEnd) {
            throw "Comment outcome file '$Path' does not match the current snapshot reporting period."
        }
    }
    $available = Get-DashboardStrictBool -Value (Get-DashboardValue -Object $outcomes -Name 'available') `
        -Where "'$Path'.available"
    $fixed = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'fixed') -Where "'$Path'.fixed"
    $wontFix = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'wontFix') -Where "'$Path'.wontFix"
    $byDesign = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'byDesign') -Where "'$Path'.byDesign"
    $closed = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'closed') -Where "'$Path'.closed"
    $mergedUnresolved = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'mergedUnresolved') -Where "'$Path'.mergedUnresolved"
    $stillOpen = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'stillOpen') -Where "'$Path'.stillOpen"
    $decided = $fixed + $wontFix + $byDesign + $closed
    $declaredDecided = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'decided') -Where "'$Path'.decided"
    if ($declaredDecided -ne $decided) { throw "Comment outcome file '$Path'.decided does not match its outcome counts." }
    $expectedPercent = if ($decided -gt 0) { [int][Math]::Round(([double]$fixed * 100.0) / $decided) } else { $null }
    $declaredPercent = Get-DashboardValue -Object $outcomes -Name 'usefulnessPercent'
    if ($null -eq $expectedPercent) {
        if ($null -ne $declaredPercent) { throw "Comment outcome file '$Path'.usefulnessPercent must be null with no decided comments." }
    }
    elseif ((Get-DashboardStrictInt -Value $declaredPercent -Where "'$Path'.usefulnessPercent") -ne $expectedPercent) {
        throw "Comment outcome file '$Path'.usefulnessPercent does not match its outcome counts."
    }
    $peopleById = @{}
    foreach ($person in @(Get-DashboardValue -Object $outcomes -Name 'people' -Default @())) {
        $personId = Get-DashboardRosterString -Object $person -Name 'personId' -Where "'$Path'.people" -MaxLength 64
        if ($peopleById.ContainsKey($personId)) { throw "Comment outcome file '$Path' contains duplicate personId '$personId'." }
        $personFixed = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $person -Name 'fixed') -Where "'$Path'.people[$personId].fixed"
        $personWontFix = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $person -Name 'wontFix') -Where "'$Path'.people[$personId].wontFix"
        $personByDesign = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $person -Name 'byDesign') -Where "'$Path'.people[$personId].byDesign"
        $personClosed = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $person -Name 'closed') -Where "'$Path'.people[$personId].closed"
        $personDecided = $personFixed + $personWontFix + $personByDesign + $personClosed
        if ((Get-DashboardStrictInt -Value (Get-DashboardValue -Object $person -Name 'decided') -Where "'$Path'.people[$personId].decided") -ne $personDecided) {
            throw "Comment outcome file '$Path'.people[$personId].decided is inconsistent."
        }
        $peopleById[$personId] = [pscustomobject]@{
            PersonId = $personId; Fixed = $personFixed; WontFix = $personWontFix
            ByDesign = $personByDesign; Closed = $personClosed
            MergedUnresolved = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $person -Name 'mergedUnresolved') -Where "'$Path'.people[$personId].mergedUnresolved"
            StillOpen = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $person -Name 'stillOpen') -Where "'$Path'.people[$personId].stillOpen"
            Decided = $personDecided
            UsefulnessPercent = $(if ($personDecided -gt 0) { [int][Math]::Round(([double]$personFixed * 100.0) / $personDecided) } else { $null })
        }
    }

    return [pscustomobject]@{
        Available          = $available
        Fixed              = $fixed
        WontFix            = $wontFix
        ByDesign           = $byDesign
        Closed             = $closed
        MergedUnresolved   = $mergedUnresolved
        StillOpen          = $stillOpen
        Decided            = $decided
        UsefulnessPercent  = $expectedPercent
        LowVolume          = ($decided -lt 5)
        PeopleById         = $peopleById
        UnmappedFindingThreads = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $outcomes -Name 'unmappedFindingThreads') -Where "'$Path'.unmappedFindingThreads"
    }
}

function Write-DashboardTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $tempPath = "$fullPath.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$fullPath.bak-$PID-$([guid]::NewGuid().ToString('N'))"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($tempPath, $Content, $utf8)
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

$repoRoot = Split-Path $PSScriptRoot -Parent
$_dashConfig = Read-DashboardConfig -ConfigPath $ConfigPath -RepoRoot $repoRoot
if ($null -ne $_dashConfig -and $null -ne $_dashConfig.StaleAfterHours -and -not $PSBoundParameters.ContainsKey('StaleAfterHours')) { $StaleAfterHours = $_dashConfig.StaleAfterHours }

$snapshots = @(
    foreach ($path in @(Resolve-DashboardSnapshotFiles -Path $SnapshotPath)) {
        Read-DashboardSnapshot -Path $path
    }
)
$roster = Read-DashboardRoster -Path $RosterPath
$selectedSnapshots = @(
    $snapshots |
        Group-Object { "$($_.PublisherId)|$($_.InstallationEpochId)" } |
        ForEach-Object { $_.Group | Sort-Object GeneratedAt, Path -Descending | Select-Object -First 1 }
)
$rosterEnabled = $roster.People.Count -gt 0
if ($rosterEnabled) {
    foreach ($snapshot in $selectedSnapshots) {
        if (-not $roster.PublisherToPerson.ContainsKey([string]$snapshot.PublisherId)) {
            throw "Dashboard roster does not map publisher '$($snapshot.PublisherId)'."
        }
    }
}
$ignoredSnapshotCount = $snapshots.Count - $selectedSnapshots.Count
$periodStart = $null
$periodEnd = $null
if ($selectedSnapshots.Count -gt 0) {
    $periodStart = $selectedSnapshots[0].PeriodStart
    $periodEnd = $selectedSnapshots[0].PeriodEnd
    foreach ($snapshot in $selectedSnapshots) {
        if ($snapshot.PeriodStart -ne $periodStart -or $snapshot.PeriodEnd -ne $periodEnd) {
            throw 'All selected dashboard snapshots must use the same reporting period.'
        }
    }
}
$snapshotSetSha256 = Get-DashboardSnapshotSetSha256 -Snapshots $selectedSnapshots

$runRows = New-Object System.Collections.Generic.List[object]
$seenRunRows = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($snapshot in $selectedSnapshots) {
    $person = if ($rosterEnabled) {
        $personId = [string]$roster.PublisherToPerson[[string]$snapshot.PublisherId]
        $roster.PersonById[$personId]
    }
    else {
        [pscustomobject]@{ PersonId = 'unattributed'; DisplayName = 'Unattributed reviewer'; Team = '' }
    }
    foreach ($run in $snapshot.ReviewRuns) {
        $dedupeKey = "$($snapshot.PublisherId)|$($run.RunId)"
        if (-not $seenRunRows.Add($dedupeKey)) { continue }
        [void]$runRows.Add([ordered]@{
                runId = [string]$run.RunId
                timestamp = ([datetime]$run.Timestamp).ToString('o')
                displayName = [string]$person.DisplayName
                team = [string]$person.Team
                prId = $run.PrId
                status = [string]$run.Status
                runType = [string]$run.RunType
                findings = [int]$run.Findings
                critical = [int]$run.Critical
                important = [int]$run.Important
                suggestion = [int]$run.Suggestion
                commentsAdded = [int]$run.CommentsAdded
                recommendedVote = [string]$run.RecommendedVote
                castVote = [string]$run.CastVote
            })
    }
}

$operatorMaps = @{}
if ($rosterEnabled) {
    foreach ($person in $roster.People) {
        $operatorMaps[[string]$person.PersonId] = @{
            Person = $person
            Installations = (New-Object 'System.Collections.Generic.HashSet[string]')
            LastSnapshotAt = $null
            LastActivityAt = $null
            PullRequests = @{}
        }
    }
    foreach ($snapshot in $selectedSnapshots) {
        $personId = [string]$roster.PublisherToPerson[[string]$snapshot.PublisherId]
        $operator = $operatorMaps[$personId]
        [void]$operator.Installations.Add("$($snapshot.PublisherId)|$($snapshot.InstallationEpochId)")
        if ($null -eq $operator.LastSnapshotAt -or $snapshot.GeneratedAt -gt [datetime]$operator.LastSnapshotAt) {
            $operator.LastSnapshotAt = $snapshot.GeneratedAt
        }
        foreach ($row in $snapshot.PullRequests) {
            if (-not $row.Reviewed -and $row.PostedComments -eq 0 -and $row.Vote -eq 'none' -and -not $row.Approved) { continue }
            $key = [string]$row.PrId
            if (-not $operator.PullRequests.ContainsKey($key)) {
                $operator.PullRequests[$key] = @{
                    prId = [int]$row.PrId; date = [datetime]$row.Date
                    reviewed = $false; findings = 0; reviewAt = $null; reviewSnapshotAt = $null
                    postedComments = 0; approved = $false
                    vote = 'none'; voteAt = $null; voteSnapshotAt = $null
                }
            }
            $personPr = $operator.PullRequests[$key]
            if ($row.Date -gt [datetime]$personPr.date) { $personPr.date = $row.Date }
            $personPr.reviewed = [bool]$personPr.reviewed -or [bool]$row.Reviewed
            if ($row.Reviewed -and
                ($null -eq $personPr.reviewAt -or $row.ReviewAt -gt [datetime]$personPr.reviewAt -or
                    ($row.ReviewAt -eq [datetime]$personPr.reviewAt -and
                        ($null -eq $personPr.reviewSnapshotAt -or $snapshot.GeneratedAt -gt [datetime]$personPr.reviewSnapshotAt)))) {
                $personPr.findings = [int]$row.Findings
                $personPr.reviewAt = [datetime]$row.ReviewAt
                $personPr.reviewSnapshotAt = $snapshot.GeneratedAt
            }
            $personPr.postedComments = [int]$personPr.postedComments + [int]$row.PostedComments
            $personPr.approved = [bool]$personPr.approved -or [bool]$row.Approved
            if ($row.Vote -ne 'none' -and
                ($null -eq $personPr.voteAt -or $row.VoteAt -gt [datetime]$personPr.voteAt -or
                    ($row.VoteAt -eq [datetime]$personPr.voteAt -and
                        ($null -eq $personPr.voteSnapshotAt -or $snapshot.GeneratedAt -gt [datetime]$personPr.voteSnapshotAt)))) {
                $personPr.vote = [string]$row.Vote
                $personPr.voteAt = [datetime]$row.VoteAt
                $personPr.voteSnapshotAt = $snapshot.GeneratedAt
            }
            foreach ($candidate in @($row.ReviewAt, $row.VoteAt, $row.Date)) {
                if ($null -ne $candidate -and ($null -eq $operator.LastActivityAt -or $candidate -gt [datetime]$operator.LastActivityAt)) {
                    $operator.LastActivityAt = [datetime]$candidate
                }
            }
        }
    }
}

$aggregatePullRequests = @{}
foreach ($snapshot in $selectedSnapshots) {
    foreach ($row in $snapshot.PullRequests) {
        $key = [string]$row.PrId
        if (-not $aggregatePullRequests.ContainsKey($key)) {
            $aggregatePullRequests[$key] = @{
                prId             = [int]$row.PrId
                date             = [datetime]$row.Date
                reviewed         = $false
                findings         = 0
                reviewAt         = $null
                reviewSnapshotAt = $null
                postedComments   = 0
                vote             = 'none'
                voteAt           = $null
                voteSnapshotAt   = $null
                approved         = $false
                commitPushed     = $false
                autoComplete     = $false
            }
        }
        $aggregate = $aggregatePullRequests[$key]
        if ($row.Date -gt [datetime]$aggregate.date) { $aggregate.date = $row.Date }
        $aggregate.reviewed = [bool]$aggregate.reviewed -or [bool]$row.Reviewed
        if ($row.Reviewed -and
            ($null -eq $aggregate.reviewAt -or $row.ReviewAt -gt [datetime]$aggregate.reviewAt -or
                ($row.ReviewAt -eq [datetime]$aggregate.reviewAt -and
                    ($null -eq $aggregate.reviewSnapshotAt -or $snapshot.GeneratedAt -gt [datetime]$aggregate.reviewSnapshotAt)))) {
            $aggregate.findings = [int]$row.Findings
            $aggregate.reviewAt = [datetime]$row.ReviewAt
            $aggregate.reviewSnapshotAt = $snapshot.GeneratedAt
        }
        $aggregate.postedComments = [int]$aggregate.postedComments + [int]$row.PostedComments
        $aggregate.approved = [bool]$aggregate.approved -or [bool]$row.Approved
        $aggregate.commitPushed = [bool]$aggregate.commitPushed -or [bool]$row.CommitPushed
        $aggregate.autoComplete = [bool]$aggregate.autoComplete -or [bool]$row.AutoComplete
        if ($row.Vote -ne 'none') {
            if ($null -eq $aggregate.voteAt -or $row.VoteAt -gt [datetime]$aggregate.voteAt -or
                ($row.VoteAt -eq [datetime]$aggregate.voteAt -and
                    ($null -eq $aggregate.voteSnapshotAt -or $snapshot.GeneratedAt -gt [datetime]$aggregate.voteSnapshotAt))) {
                $aggregate.vote = [string]$row.Vote
                $aggregate.voteAt = [datetime]$row.VoteAt
                $aggregate.voteSnapshotAt = $snapshot.GeneratedAt
            }
        }
    }
}

$recentRows = @(
    foreach ($row in @($aggregatePullRequests.Values | Sort-Object @{ Expression = { $_.date }; Descending = $true }, prId | Select-Object -First $RecentPullRequestCount)) {
        [ordered]@{
            prId           = [int]$row.prId
            date           = ([datetime]$row.date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            findings       = [int]$row.findings
            postedComments = [int]$row.postedComments
            vote           = [string]$row.vote
            commitPushed   = [bool]$row.commitPushed
            autoComplete   = [bool]$row.autoComplete
        }
    }
)

$allPullRequests = @($aggregatePullRequests.Values)
$allCommentsPosted = 0
foreach ($row in $allPullRequests) { $allCommentsPosted += [int]$row.postedComments }
$metrics = [ordered]@{
    prsReviewed          = @($allPullRequests | Where-Object { $_.reviewed }).Count
    commentsPosted       = $allCommentsPosted
    prsApproved          = @($allPullRequests | Where-Object { $_.approved }).Count
    prsWithCommitsPushed = @($allPullRequests | Where-Object { $_.commitPushed }).Count
    prsAutoCompleted     = @($allPullRequests | Where-Object { $_.autoComplete }).Count
}

$aggregateWeeks = @{}
foreach ($snapshot in $selectedSnapshots) {
    foreach ($week in $snapshot.WeeklyActivity) {
        $key = $week.WeekStart.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        if (-not $aggregateWeeks.ContainsKey($key)) {
            $aggregateWeeks[$key] = @{
                weekStart          = $key
                reviewedPrIds      = (New-Object 'System.Collections.Generic.HashSet[int]')
                commentsPosted     = 0
                approvedPrIds      = (New-Object 'System.Collections.Generic.HashSet[int]')
                commitPushedPrIds  = (New-Object 'System.Collections.Generic.HashSet[int]')
                autoCompletedPrIds = (New-Object 'System.Collections.Generic.HashSet[int]')
            }
        }
        $aggregate = $aggregateWeeks[$key]
        foreach ($prId in $week.ReviewedPrIds) { [void]$aggregate.reviewedPrIds.Add([int]$prId) }
        foreach ($prId in $week.ApprovedPrIds) { [void]$aggregate.approvedPrIds.Add([int]$prId) }
        foreach ($prId in $week.CommitPushedPrIds) { [void]$aggregate.commitPushedPrIds.Add([int]$prId) }
        foreach ($prId in $week.AutoCompletedPrIds) { [void]$aggregate.autoCompletedPrIds.Add([int]$prId) }
        $aggregate.commentsPosted = [int]$aggregate.commentsPosted + [int]$week.CommentsPosted
    }
}
$weeklyActivity = @(
    foreach ($week in @($aggregateWeeks.Values | Sort-Object weekStart)) {
        [ordered]@{
            weekStart             = [string]$week.weekStart
            prsReviewed           = $week.reviewedPrIds.Count
            commentsPosted        = [int]$week.commentsPosted
            prsApproved           = $week.approvedPrIds.Count
            prsWithCommitsPushed  = $week.commitPushedPrIds.Count
            prsAutoCompleted      = $week.autoCompletedPrIds.Count
        }
    }
)

$outcomes = Read-DashboardCommentOutcomes -Path $CommentOutcomePath `
    -ExpectedSnapshotSetSha256 $snapshotSetSha256 -ExpectedRosterSha256 $roster.ContentSha256 `
    -ExpectedPeriodStart $periodStart -ExpectedPeriodEnd $periodEnd
$dataAsOf = if ($selectedSnapshots.Count -gt 0) {
    ($selectedSnapshots | Sort-Object GeneratedAt -Descending | Select-Object -First 1).GeneratedAt
}
else { $null }
$generatedAtUtc = ConvertTo-DashboardUtc -Value $GeneratedAt
$operators = @(
    foreach ($operator in @($operatorMaps.Values | Sort-Object { $_.Person.DisplayName })) {
        $person = $operator.Person
        $personPrs = @($operator.PullRequests.Values)
        $comments = 0
        $findings = 0
        foreach ($personPr in $personPrs) {
            $comments += [int]$personPr.postedComments
            $findings += [int]$personPr.findings
        }
        $history = @(
            foreach ($personPr in @($personPrs | Sort-Object @{ Expression = { $_.date }; Descending = $true }, prId)) {
                [ordered]@{
                    prId = [int]$personPr.prId
                    date = ([datetime]$personPr.date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                    findings = [int]$personPr.findings
                    postedComments = [int]$personPr.postedComments
                    vote = [string]$personPr.vote
                    reviewed = [bool]$personPr.reviewed
                    approved = [bool]$personPr.approved
                }
            }
        )
        $lastSnapshotAt = $operator.LastSnapshotAt
        [ordered]@{
            displayName = [string]$person.DisplayName
            team = [string]$person.Team
            status = $(if ($null -eq $lastSnapshotAt) { 'No snapshot' }
                elseif ($lastSnapshotAt -lt $generatedAtUtc.AddHours(-$StaleAfterHours)) { 'Stale' }
                else { 'Fresh' })
            installationCount = $operator.Installations.Count
            prsReviewed = @($personPrs | Where-Object { $_.reviewed }).Count
            findings = $findings
            commentsPosted = $comments
            prsApproved = @($personPrs | Where-Object { $_.approved }).Count
            lastActivityAt = $(if ($operator.LastActivityAt) { ([datetime]$operator.LastActivityAt).ToString('o') } else { $null })
            lastSnapshotAt = $(if ($lastSnapshotAt) { ([datetime]$lastSnapshotAt).ToString('o') } else { $null })
            history = [object[]]$history
        }
    }
)

$dashboardData = [ordered]@{
    generatedAt            = $generatedAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    dataAsOf               = $(if ($dataAsOf) { $dataAsOf.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
    periodStart            = $(if ($periodStart) { $periodStart.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
    periodEnd              = $(if ($periodEnd) { $periodEnd.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
    snapshotCount          = $selectedSnapshots.Count
    rosterEnabled          = $rosterEnabled
    ignoredSnapshotCount   = $ignoredSnapshotCount
    metrics                = $metrics
    quality                = [ordered]@{
        available         = $outcomes.Available
        fixed             = $outcomes.Fixed
        wontFix           = $outcomes.WontFix
        byDesign          = $outcomes.ByDesign
        closed            = $outcomes.Closed
        mergedUnresolved  = $outcomes.MergedUnresolved
        stillOpen         = $outcomes.StillOpen
        decided           = $outcomes.Decided
        usefulnessPercent = $outcomes.UsefulnessPercent
        lowVolume         = $outcomes.LowVolume
    }
    unmappedFindingThreads = $outcomes.UnmappedFindingThreads
    weeklyActivity         = [object[]]$weeklyActivity
    operators              = [object[]]$operators
    recentPullRequests     = [object[]]$recentRows
    runs                   = [object[]]@($runRows | Sort-Object @{ Expression = { $_.timestamp }; Descending = $true }, runId)
}

$dataJson = $dashboardData | ConvertTo-Json -Depth 12 -Compress
$dataJson = $dataJson.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e')

$_templatePath = Join-Path $repoRoot 'dashboard\index.html'
if (-not (Test-Path -LiteralPath $_templatePath -PathType Leaf)) { throw "Dashboard template '$_templatePath' does not exist. Ensure dashboard/index.html is present." }
$template = (New-Object System.Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($_templatePath))
$_placeholderCount = ([regex]::Matches($template, [regex]::Escape('__DASHBOARD_DATA__'))).Count
if ($_placeholderCount -ne 1) { throw "Dashboard template '$_templatePath' must have exactly one '__DASHBOARD_DATA__' placeholder; found $_placeholderCount." }
$html = $template.Replace('__DASHBOARD_DATA__', $dataJson)
Write-DashboardTextFile -Path $OutputPath -Content $html
Write-Host ("Dashboard written to '{0}' from {1} current snapshot(s)." -f `
        [IO.Path]::GetFullPath($OutputPath), $selectedSnapshots.Count) -ForegroundColor Green
