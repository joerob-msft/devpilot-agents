#requires -Version 7.0

<#
.SYNOPSIS
    Collects aggregate outcomes for reviewer-agent finding threads.

.DESCRIPTION
    Discovers pull requests with posted comments from sanitized dashboard
    snapshots, reads their Azure DevOps pull-request state and threads, and
    counts only threads whose first non-deleted comment is a signed reviewer
    finding. Human-authored threads that later received an agent assessment and
    reviewer summary threads are intentionally excluded.

    Output contains counts only. No comment text, identity, repository name,
    file path, or local path is written.

    Use -FixturePath for a fully offline validation run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$SnapshotPath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$Organization,

    [string]$Project,

    [string]$RepositoryName,

    [string]$RosterPath,

    [string]$AgencyPath,

    [string]$FixturePath,

    [ValidateRange(5, 120)]
    [int]$McpTimeoutSeconds = 120,

    [datetime]$GeneratedAt = [datetime]::UtcNow
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$reviewerSignature = '-- automated review by the devpilot reviewer agent; reply here if this is wrong.'

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
        return [pscustomobject]@{
            People = @(); PersonById = @{}; PublisherToPerson = @{}
            AdoIdToPerson = @{}; AdoUniqueNameToPerson = @{}; ContentSha256 = $null
        }
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
    $adoIdToPerson = @{}
    $adoUniqueNameToPerson = @{}
    foreach ($person in @(Get-DashboardValue -Object $roster -Name 'people' -Default @())) {
        if ($person -isnot [System.Management.Automation.PSCustomObject]) { throw "Dashboard roster '$Path'.people must contain objects." }
        $personId = Get-DashboardRosterString -Object $person -Name 'personId' -Where "'$Path'.people" -MaxLength 64
        if ($personId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $personById.ContainsKey($personId)) {
            throw "Dashboard roster '$Path' has an invalid or duplicate personId '$personId'."
        }
        $displayName = Get-DashboardRosterString -Object $person -Name 'displayName' -Where "'$Path'.people[$personId]"
        $team = Get-DashboardRosterString -Object $person -Name 'team' -Where "'$Path'.people[$personId]" -AllowEmpty
        $publisherIds = @(Get-DashboardRosterStringArray -Object $person -Name 'publisherIds' -Where "'$Path'.people[$personId]" -MaxLength 24)
        $adoIdentityIds = @(Get-DashboardRosterStringArray -Object $person -Name 'adoIdentityIds' -Where "'$Path'.people[$personId]")
        $adoUniqueNames = @(Get-DashboardRosterStringArray -Object $person -Name 'adoUniqueNames' -Where "'$Path'.people[$personId]")
        foreach ($publisherId in $publisherIds) {
            if ($publisherId -cnotmatch '^[a-f0-9]{24}$' -or $publisherToPerson.ContainsKey($publisherId)) {
                throw "Dashboard roster '$Path' has an invalid or duplicate publisherId."
            }
            $publisherToPerson[$publisherId] = $personId
        }
        foreach ($identityId in $adoIdentityIds) {
            if ($adoIdToPerson.ContainsKey($identityId)) { throw "Dashboard roster '$Path' maps one ADO identity ID more than once." }
            $adoIdToPerson[$identityId] = $personId
        }
        foreach ($uniqueName in $adoUniqueNames) {
            if ($adoUniqueNameToPerson.ContainsKey($uniqueName)) { throw "Dashboard roster '$Path' maps one ADO unique name more than once." }
            $adoUniqueNameToPerson[$uniqueName] = $personId
        }
        $normalized = [pscustomobject]@{
            PersonId = $personId; DisplayName = $displayName; Team = $team
            PublisherIds = $publisherIds; AdoIdentityIds = $adoIdentityIds; AdoUniqueNames = $adoUniqueNames
        }
        $personById[$personId] = $normalized
        [void]$people.Add($normalized)
    }
    return [pscustomobject]@{
        People = $people.ToArray(); PersonById = $personById; PublisherToPerson = $publisherToPerson
        AdoIdToPerson = $adoIdToPerson; AdoUniqueNameToPerson = $adoUniqueNameToPerson
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
            Write-Warning "Dashboard snapshot path '$candidate' does not exist; continuing without it."
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
    if ((Get-DashboardStrictInt -Value (Get-DashboardValue -Object $snapshot -Name 'schemaVersion') -Where "'$Path'.schemaVersion" -Min 1) -ne 2) {
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
    $prIds = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($row in $rows) {
        if ($row -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Dashboard snapshot '$Path'.pullRequests must contain only objects."
        }
        $prId = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $row -Name 'prId') `
            -Where "'$Path'.pullRequests.prId" -Min 1
        $posted = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $row -Name 'postedComments') `
            -Where "'$Path'.pullRequests[$prId].postedComments"
        if ($posted -gt 0) { [void]$prIds.Add($prId) }
    }
    return [pscustomobject]@{
        Path                = $Path
        InstallationEpochId = $installationId
        PublisherId         = $publisherId
        GeneratedAt         = $generatedAt
        PeriodStart         = $periodStart
        PeriodEnd           = $periodEnd
        ContentSha256       = Get-DashboardBytesSha256 -Bytes $bytes
        CommentedPrIds      = $prIds
    }
}

function ConvertTo-DashboardPrStatus {
    param($Value, [Parameter(Mandatory)][int]$PrId)

    $normalized = ([string]$Value).Trim().ToLowerInvariant().Replace('_', '').Replace('-', '').Replace(' ', '')
    switch ($normalized) {
        { $_ -in @('1', 'active') } { return 'active' }
        { $_ -in @('2', 'abandoned') } { return 'abandoned' }
        { $_ -in @('3', 'completed') } { return 'completed' }
        default { throw "Pull request $PrId returned unsupported status '$Value'." }
    }
}

function ConvertTo-DashboardThreadStatus {
    param($Value)

    $normalized = ([string]$Value).Trim().ToLowerInvariant().Replace('_', '').Replace('-', '').Replace(' ', '')
    switch ($normalized) {
        { $_ -in @('2', 'fixed') } { return 'fixed' }
        { $_ -in @('3', 'wontfix') } { return 'wontFix' }
        { $_ -in @('4', 'closed') } { return 'closed' }
        { $_ -in @('5', 'bydesign') } { return 'byDesign' }
        { $_ -in @('1', 'active') } { return 'active' }
        { $_ -in @('6', 'pending') } { return 'pending' }
        default { return 'unknown' }
    }
}

function Get-DashboardReviewerFindingThread {
    param([Parameter(Mandatory)]$Thread)

    $comments = @(
        @(Get-DashboardValue -Object $Thread -Name 'comments' -Default @()) |
            Where-Object { (Get-DashboardValue -Object $_ -Name 'isDeleted' -Default $false) -ne $true } |
            Sort-Object { Get-DashboardStrictInt -Value (Get-DashboardValue -Object $_ -Name 'id' -Default 0) -Where 'thread comment id' }
    )
    if ($comments.Count -eq 0) { return $null }

    $content = [string](Get-DashboardValue -Object $comments[0] -Name 'content' -Default '')
    if ($content.IndexOf($reviewerSignature, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $content -notmatch '^\s*\*\*\[(CRITICAL|IMPORTANT|SUGGESTION)\]\*\*') {
        return $null
    }
    $publishedValue = Get-DashboardValue -Object $comments[0] -Name 'publishedDate'
    if ($null -eq $publishedValue) { $publishedValue = Get-DashboardValue -Object $Thread -Name 'publishedDate' }
    if ($null -eq $publishedValue) {
        throw 'A reviewer finding thread did not expose its publication timestamp; refusing an unscoped outcome count.'
    }
    $author = Get-DashboardValue -Object $comments[0] -Name 'author'
    return [pscustomobject]@{
        PublishedAt      = ConvertFrom-DashboardTimestamp -Value $publishedValue -Where 'reviewer finding publication time'
        AuthorIdentityId = [string](Get-DashboardValue -Object $author -Name 'id' -Default '')
        AuthorUniqueName = [string](Get-DashboardValue -Object $author -Name 'uniqueName' -Default '')
    }
}

function Test-DashboardTimestampInRanges {
    param([Parameter(Mandatory)][datetime]$TimestampUtc, [object[]]$Ranges)
    foreach ($range in @($Ranges)) {
        if ($TimestampUtc -ge [datetime]$range.Start -and $TimestampUtc -lt [datetime]$range.End) { return $true }
    }
    return $false
}

function Get-DashboardPagedThreads {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][int]$PrId
    )

    $all = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $pageSize = 200
    for ($page = 0; $page -lt 20; $page++) {
        $raw = @(
            Invoke-AgentMcpTool -Session $Session -Name 'repo_pull_request_thread' -Arguments @{
                action        = 'list'
                project       = $Project
                repositoryId  = $RepositoryName
                pullRequestId = $PrId
                top           = $pageSize
                skip          = ($page * $pageSize)
            }
        )
        if ($raw.Count -gt $pageSize) {
            throw "ADO returned more than $pageSize threads for pull request $PrId in one page."
        }
        foreach ($thread in $raw) {
            $threadId = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $thread -Name 'id') `
                -Where "pull request $PrId thread id" -Min 1
            if ($seen.Add($threadId)) { [void]$all.Add($thread) }
        }
        if ($raw.Count -lt $pageSize) { return $all.ToArray() }
    }
    throw "ADO thread listing for pull request $PrId filled every configured page; refusing a truncated outcome count."
}

function Write-DashboardJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $tempPath = "$fullPath.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$fullPath.bak-$PID-$([guid]::NewGuid().ToString('N'))"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($tempPath, (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine), $utf8)
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
$prIds = New-Object 'System.Collections.Generic.HashSet[int]'
$prPeriods = @{}
foreach ($snapshot in $selectedSnapshots) {
    foreach ($prId in $snapshot.CommentedPrIds) {
        [void]$prIds.Add([int]$prId)
        $key = [string]$prId
        if (-not $prPeriods.ContainsKey($key)) { $prPeriods[$key] = New-Object System.Collections.Generic.List[object] }
        [void]$prPeriods[$key].Add([pscustomobject]@{ Start = $snapshot.PeriodStart; End = $snapshot.PeriodEnd })
    }
}

$fixtureByPr = @{}
if ($FixturePath) {
    if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
        throw "Outcome fixture '$FixturePath' does not exist."
    }
    try {
        $fixture = Get-Content -LiteralPath $FixturePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Outcome fixture '$FixturePath' is not valid JSON."
    }
    foreach ($fixturePr in @(Get-DashboardValue -Object $fixture -Name 'pullRequests' -Default @())) {
        $fixturePrId = Get-DashboardStrictInt -Value (Get-DashboardValue -Object $fixturePr -Name 'prId') `
            -Where "'$FixturePath'.pullRequests.prId" -Min 1
        if ($fixtureByPr.ContainsKey([string]$fixturePrId)) {
            throw "Outcome fixture '$FixturePath' contains duplicate pull request $fixturePrId."
        }
        $fixtureByPr[[string]$fixturePrId] = $fixturePr
    }
}
else {
    foreach ($required in @(
            @{ Name = 'Organization'; Value = $Organization },
            @{ Name = 'Project'; Value = $Project },
            @{ Name = 'RepositoryName'; Value = $RepositoryName }
        )) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
            throw "$($required.Name) is required unless FixturePath is used."
        }
    }
}

$counts = [ordered]@{
    fixed            = 0
    wontFix          = 0
    byDesign         = 0
    closed           = 0
    mergedUnresolved = 0
    stillOpen        = 0
}
$personCounts = @{}
foreach ($person in $roster.People) {
    $personCounts[[string]$person.PersonId] = [ordered]@{
        fixed = 0; wontFix = 0; byDesign = 0; closed = 0; mergedUnresolved = 0; stillOpen = 0
    }
}
$unmappedFindingThreads = 0
$threadsChecked = 0
$session = $null
try {
    if (-not $FixturePath -and $prIds.Count -gt 0) {
        $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
        Import-Module $manifest -Force
        if (-not $AgencyPath) {
            $agencyCommand = Get-Command agency -ErrorAction SilentlyContinue
            if (-not $agencyCommand) { throw "Agency CLI ('agency') was not found on PATH." }
            $AgencyPath = if ($agencyCommand.Path) { [string]$agencyCommand.Path } else { [string]$agencyCommand.Source }
        }
        $session = Open-AgentMcpSession -AgencyPath $AgencyPath -Server 'ado' -Organization $Organization `
            -Toolsets @('repos') -TimeoutSeconds $McpTimeoutSeconds
    }

    foreach ($prId in @($prIds | Sort-Object)) {
        $pullRequest = $null
        $threads = @()
        if ($FixturePath) {
            if (-not $fixtureByPr.ContainsKey([string]$prId)) {
                throw "Outcome fixture '$FixturePath' has no entry for pull request $prId."
            }
            $pullRequest = $fixtureByPr[[string]$prId]
            $threads = @(Get-DashboardValue -Object $pullRequest -Name 'threads' -Default @())
        }
        else {
            $pullRequest = Invoke-AgentMcpTool -Session $session -Name 'repo_pull_request' -Arguments @{
                action        = 'get'
                project       = $Project
                repositoryId  = $RepositoryName
                pullRequestId = $prId
            }
            $threads = @(Get-DashboardPagedThreads -Session $session -PrId $prId)
        }

        $prStatus = ConvertTo-DashboardPrStatus -Value (Get-DashboardValue -Object $pullRequest -Name 'status') -PrId $prId
        foreach ($thread in $threads) {
            $findingThread = Get-DashboardReviewerFindingThread -Thread $thread
            if ($null -eq $findingThread) { continue }
            $threadsChecked++
            if (-not (Test-DashboardTimestampInRanges -TimestampUtc $findingThread.PublishedAt -Ranges $prPeriods[[string]$prId])) {
                continue
            }
            $personId = $null
            if ($roster.People.Count -gt 0) {
                $byId = if ($findingThread.AuthorIdentityId -and $roster.AdoIdToPerson.ContainsKey($findingThread.AuthorIdentityId)) {
                    [string]$roster.AdoIdToPerson[$findingThread.AuthorIdentityId]
                } else { $null }
                $byUniqueName = if ($findingThread.AuthorUniqueName -and $roster.AdoUniqueNameToPerson.ContainsKey($findingThread.AuthorUniqueName)) {
                    [string]$roster.AdoUniqueNameToPerson[$findingThread.AuthorUniqueName]
                } else { $null }
                if ($byId -and $byUniqueName -and $byId -cne $byUniqueName) {
                    throw "A reviewer finding author maps to two different roster people."
                }
                $personId = if ($byId) { $byId } else { $byUniqueName }
                if (-not $personId) { $unmappedFindingThreads++ }
            }
            $threadStatus = ConvertTo-DashboardThreadStatus -Value (Get-DashboardValue -Object $thread -Name 'status' -Default 'unknown')
            if ($prStatus -eq 'completed') {
                if ($threadStatus -in @('fixed', 'wontFix', 'byDesign', 'closed')) {
                    $counts[$threadStatus] = [int]$counts[$threadStatus] + 1
                    if ($personId) { $personCounts[$personId][$threadStatus] = [int]$personCounts[$personId][$threadStatus] + 1 }
                }
                else {
                    $counts.mergedUnresolved = [int]$counts.mergedUnresolved + 1
                    if ($personId) { $personCounts[$personId].mergedUnresolved = [int]$personCounts[$personId].mergedUnresolved + 1 }
                }
            }
            elseif ($prStatus -eq 'active' -and $threadStatus -notin @('fixed', 'wontFix', 'byDesign', 'closed')) {
                $counts.stillOpen = [int]$counts.stillOpen + 1
                if ($personId) { $personCounts[$personId].stillOpen = [int]$personCounts[$personId].stillOpen + 1 }
            }
        }
    }
}
finally {
    if ($session) { Close-AgentMcpSession -Session $session }
}

$decided = [int]$counts.fixed + [int]$counts.wontFix + [int]$counts.byDesign + [int]$counts.closed
$usefulnessPercent = if ($decided -gt 0) { [int][Math]::Round(([double]$counts.fixed * 100.0) / $decided) } else { $null }
$generatedAtUtc = ConvertTo-DashboardUtc -Value $GeneratedAt
$peopleOutcomes = @(
    foreach ($person in @($roster.People | Sort-Object PersonId)) {
        $personId = [string]$person.PersonId
        $personCount = $personCounts[$personId]
        $personDecided = [int]$personCount.fixed + [int]$personCount.wontFix + [int]$personCount.byDesign + [int]$personCount.closed
        [ordered]@{
            personId = $personId
            fixed = [int]$personCount.fixed
            wontFix = [int]$personCount.wontFix
            byDesign = [int]$personCount.byDesign
            closed = [int]$personCount.closed
            mergedUnresolved = [int]$personCount.mergedUnresolved
            stillOpen = [int]$personCount.stillOpen
            decided = $personDecided
            usefulnessPercent = $(if ($personDecided -gt 0) { [int][Math]::Round(([double]$personCount.fixed * 100.0) / $personDecided) } else { $null })
        }
    }
)
$output = [ordered]@{
    kind                = 'devpilot-agent-dashboard-comment-outcomes'
    schemaVersion       = 2
    generatedAt         = $generatedAtUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    snapshotSetSha256   = $snapshotSetSha256
    rosterSha256        = $roster.ContentSha256
    periodStart         = $(if ($periodStart) { $periodStart.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
    periodEnd           = $(if ($periodEnd) { $periodEnd.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null })
    available           = $true
    pullRequestsChecked = $prIds.Count
    findingThreadsChecked = $threadsChecked
    fixed               = [int]$counts.fixed
    wontFix             = [int]$counts.wontFix
    byDesign            = [int]$counts.byDesign
    closed              = [int]$counts.closed
    mergedUnresolved    = [int]$counts.mergedUnresolved
    stillOpen           = [int]$counts.stillOpen
    decided             = $decided
    usefulnessPercent   = $usefulnessPercent
    lowVolume           = ($decided -lt 5)
    unmappedFindingThreads = $unmappedFindingThreads
    people              = [object[]]$peopleOutcomes
}

Write-DashboardJsonFile -Path $OutputPath -Value $output
Write-Host ("Comment outcomes written to '{0}' ({1} decided finding thread(s), {2} unresolved)." -f `
        [IO.Path]::GetFullPath($OutputPath), $decided, ([int]$counts.mergedUnresolved + [int]$counts.stillOpen)) -ForegroundColor Green
