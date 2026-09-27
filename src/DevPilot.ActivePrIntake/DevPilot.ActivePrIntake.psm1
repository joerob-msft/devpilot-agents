#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.TestProjectEvidence\DevPilot.TestProjectEvidence.psd1')

function Assert-IntakeNumber {
    param($Value, [string]$Name, [int]$Minimum, [int]$Maximum)
    if ($Value -is [bool] -or $null -eq $Value -or
        [string]$Value -cnotmatch '^(0|[1-9][0-9]*)$') {
        throw "Invalid $Name."
    }
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or
        $number -lt $Minimum -or $number -gt $Maximum) {
        throw "Invalid $Name."
    }
    return $number
}

function Get-IntakeDigest {
    param($Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 32 -Compress
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))
    ).ToLowerInvariant()
}

function Assert-IntakeConfig {
    param([Collections.IDictionary]$Config)
    $guidPattern = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
    if ($Config.schemaVersion -ne 1 -or $Config.readOnly -cne $true -or
        $Config.dryRun -cne $true -or $Config.enabled -isnot [bool] -or
        [string]$Config.organization -cnotmatch '^https://(?:dev\.azure\.com/[A-Za-z0-9_-]+|[A-Za-z0-9_-]+\.visualstudio\.com)/?$' -or
        [string]$Config.identityResource -cnotmatch '^https://[A-Za-z0-9-]+\.vssps\.visualstudio\.com/?$' -or
        [string]$Config.projectName -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$Config.projectId -cnotmatch $guidPattern -or
        [string]$Config.repositoryId -cnotmatch $guidPattern -or
        [string]$Config.expectedAccount.id -cnotmatch $guidPattern -or
        [string]$Config.expectedAccount.descriptor -cnotmatch '^\S{1,512}$' -or
        [string]$Config.expectedAccount.uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        [string]$Config.automationMarker -cnotmatch '^\[[A-Za-z0-9_.:-]{1,64}\]$') {
        throw 'Intake requires a pinned organization/project/repository/account, dryRun and readOnly.'
    }
    foreach ($setting in @(
            @('pageSize', 1, 200), @('maxPages', 1, 1000),
            @('maxPullRequests', 1, 10000), @('maxHeadsPerRun', 1, 10000),
            @('maxReads', 1, 30000), @('maxSeconds', 1, 3600),
            @('maxChangedFiles', 1, 2000), @('maxChangedLines', 1, 100000),
            @('maxFileBytes', 1, 1048576), @('maxTotalBytes', 1, 16777216),
            @('maxDiffCells', 1, 4000000),
            @('maxThreads', 1, 1000), @('maxComments', 1, 10000)
        )) {
        [void](Assert-IntakeNumber $Config.limits[$setting[0]] $setting[0] $setting[1] $setting[2])
    }
    if ($null -ne $Config['projectEvidence']) {
        $scope = $Config.projectEvidence
        if ($scope -isnot [Collections.IDictionary] -or
            $scope.schemaVersion -ne 1 -or $scope.enabled -isnot [bool]) {
            throw 'Invalid project evidence configuration.'
        }
        [void](Assert-IntakeNumber $scope.maxTreeEntries maxTreeEntries 1 10000)
        [void](Assert-IntakeNumber $scope.maxProjects maxProjects 1 32)
    }
    if ($null -ne $Config['pagination'] -and
        ($Config.pagination -isnot [Collections.IDictionary] -or
            $Config.pagination.mode -cne 'created-time-keyset')) {
        throw 'Invalid intake pagination mode.'
    }
    if ($Config.rules -isnot [array] -or $Config.rules.Count -eq 0 -or
        $Config.rules.Count -gt 32) { throw 'A bounded generic rule registry is required.' }
    if ([int]$Config.limits.maxPullRequests * $Config.rules.Count -gt 20000) {
        throw 'The configured cohort envelope exceeds its durable size budget.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rule in $Config.rules) {
        if ([string]$rule.id -cnotmatch '^[a-zA-Z0-9_.@-]{1,100}$' -or
            [string]$rule.capability -cnotmatch '^[a-zA-Z0-9_.@-]{1,100}$' -or
            -not $ids.Add([string]$rule.id)) { throw 'Invalid or repeated rule registry entry.' }
    }
}

function Invoke-IntakeRead {
    param([scriptblock]$Provider, [string]$Operation, [Collections.IDictionary]$Arguments,
        [Collections.IDictionary]$Config, [ref]$Reads, [Diagnostics.Stopwatch]$Clock)
    if ($Operation -cnotin @('Identity', 'ListPage', 'Head', 'Changes', 'Discussions')) {
        throw 'provider-contract'
    }
    if ($Reads.Value -ge [int]$Config.limits.maxReads) { throw 'read-budget' }
    if ($Clock.Elapsed.TotalSeconds -ge [int]$Config.limits.maxSeconds) { throw 'time-budget' }
    $Reads.Value++
    $Arguments.remainingReads = [int]$Config.limits.maxReads - $Reads.Value
    $Arguments.timeoutMilliseconds = [Math]::Max(1,
        [int]([int]$Config.limits.maxSeconds * 1000 - $Clock.ElapsedMilliseconds))
    $answer = & $Provider $Operation $Arguments
    if ($Clock.Elapsed.TotalSeconds -ge [int]$Config.limits.maxSeconds) { throw 'time-budget' }
    if ($answer -isnot [Collections.IDictionary]) { throw 'provider-contract' }
    if ($null -ne $answer['readCount']) {
        $additional = Assert-IntakeNumber $answer.readCount readCount 0 30000
        if ($additional -gt $Arguments.remainingReads) { throw 'read-budget' }
        $Reads.Value += $additional
    }
    return $answer
}

function Get-IntakeLineTokens {
    param([string]$Content)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Content, '[^\r\n]*(?:\r\n|\r|\n|$)')) {
        if ($match.Length -gt 0) { $lines.Add($match.Value) }
    }
    return ,$lines.ToArray()
}

function Get-IntakeLineDelta {
    param([string]$Old, [string]$New, [int]$MaxCells, [int]$MaxLines,
        [DateTime]$Deadline)
    if ([DateTime]::UtcNow -ge $Deadline) { throw 'time-budget' }
    $before = Get-IntakeLineTokens $Old
    $after = Get-IntakeLineTokens $New
    $n = $before.Count
    $m = $after.Count
    if ($n + $m -gt $MaxLines) { throw 'diff-budget' }
    $prefix = 0
    while ($prefix -lt [Math]::Min($n, $m) -and
        [string]::Equals($before[$prefix], $after[$prefix],
            [StringComparison]::Ordinal)) {
        if ($prefix % 256 -eq 0 -and [DateTime]::UtcNow -ge $Deadline) {
            throw 'time-budget'
        }
        $prefix++
    }
    $suffix = 0
    while ($n - $suffix -gt $prefix -and $m - $suffix -gt $prefix -and
        [string]::Equals($before[$n - $suffix - 1], $after[$m - $suffix - 1],
            [StringComparison]::Ordinal)) {
        if ($suffix % 256 -eq 0 -and [DateTime]::UtcNow -ge $Deadline) {
            throw 'time-budget'
        }
        $suffix++
    }
    $oldCount = $n - $prefix - $suffix
    $newCount = $m - $prefix - $suffix
    $cells = [long]($oldCount + 1) * ($newCount + 1)
    if ($cells -gt $MaxCells) { throw 'diff-budget' }
    $width = $newCount + 1
    $table = [int[]]::new([int]$cells)
    for ($i = $oldCount - 1; $i -ge 0; $i--) {
        if ([DateTime]::UtcNow -ge $Deadline) { throw 'time-budget' }
        for ($j = $newCount - 1; $j -ge 0; $j--) {
            if ($j % 256 -eq 0 -and [DateTime]::UtcNow -ge $Deadline) {
                throw 'time-budget'
            }
            $at = $i * $width + $j
            $table[$at] = if ([string]::Equals($before[$prefix + $i], $after[$prefix + $j],
                    [StringComparison]::Ordinal)) {
                1 + $table[$at + $width + 1]
            } else {
                [Math]::Max($table[$at + $width], $table[$at + 1])
            }
        }
    }
    $spans = [Collections.Generic.List[object]]::new()
    $i = 0
    $j = 0
    $added = 0
    $deleted = 0
    $start = 0
    while ($i -lt $oldCount -or $j -lt $newCount) {
        if ([DateTime]::UtcNow -ge $Deadline) { throw 'time-budget' }
        if ($i -lt $oldCount -and $j -lt $newCount -and
            [string]::Equals($before[$prefix + $i], $after[$prefix + $j],
                [StringComparison]::Ordinal)) {
            if ($start -gt 0) {
                $spans.Add([ordered]@{ startLine = $start; endLine = $prefix + $j })
                $start = 0
            }
            $i++; $j++
        }
        elseif ($i -lt $oldCount -and ($j -eq $newCount -or
                $table[($i + 1) * $width + $j] -ge $table[$i * $width + $j + 1])) {
            $deleted++; $i++
        }
        else {
            if ($start -eq 0) { $start = $prefix + $j + 1 }
            $added++; $j++
        }
    }
    if ($start -gt 0) {
        $spans.Add([ordered]@{ startLine = $start; endLine = $prefix + $j })
    }
    return @{ addedLines = $added; deletedLines = $deleted
        newLineCount = $m; spans = @($spans.ToArray())
        cells = [int]$cells }
}

function Assert-IntakeBlob {
    param([Collections.IDictionary]$Item, [string]$Path, [string]$ObjectId,
        [int]$MaxBytes)
    if ([string]$Item.path -cne $Path -or $Item.gitObjectType -cne 'blob' -or
        $Item['isFolder'] -eq $true -or $Item['isSymLink'] -eq $true -or
        $Item.contentMetadata -isnot [Collections.IDictionary] -or
        $Item.contentMetadata['isBinary'] -eq $true -or
        [string]$Item.contentMetadata.contentType -cnotmatch
            '^(?:text/[^;\s]+|application/(?:json|xml|javascript|[^/;\s]+\+(?:json|xml)))(?:;\s*charset=[\w-]+)?$' -or
        $Item.contentMetadata.encoding -notin @(65001, '65001', 1252, '1252') -or
        $Item.content -isnot [string] -or
        [string]$Item.objectId -cnotmatch '^[a-fA-F0-9]{40}$' -or
        [string]$Item.objectId -ine $ObjectId) { throw 'invalid-item' }
    if ($Item.content -cmatch '[\x00-\x08\x0b\x0c\x0e-\x1f]') {
        throw 'unsupported-change'
    }
    try {
        $encoding = if ([int]$Item.contentMetadata.encoding -eq 65001) {
            [Text.UTF8Encoding]::new($false, $true)
        } else {
            [Text.Encoding]::GetEncoding(1252, [Text.EncoderFallback]::ExceptionFallback,
                [Text.DecoderFallback]::ExceptionFallback)
        }
        $bytes = $encoding.GetBytes($Item.content)
    }
    catch { throw 'invalid-item' }
    $verified = $false
    $withBom = $false
    foreach ($candidate in @($bytes, [byte[]](@(239, 187, 191) + $bytes))) {
        if ($withBom -and [int]$Item.contentMetadata.encoding -ne 65001) { break }
        if ($candidate.Length -gt $MaxBytes) { throw 'byte-budget' }
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($candidate.Length)`0")
        $payload = [byte[]]::new($header.Length + $candidate.Length)
        [Array]::Copy($header, $payload, $header.Length)
        [Array]::Copy($candidate, 0, $payload, $header.Length, $candidate.Length)
        if ([Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($payload)) -ieq
            $ObjectId) {
            $verified = $true
            break
        }
        $withBom = $true
    }
    if (-not $verified) { throw 'invalid-item' }
    return @{ text = if ($withBom) { [string][char]0xfeff + $Item.content } else {
            $Item.content
        }; bytes = $candidate.Length }
}

function Assert-IntakeRawBlob {
    param([byte[]]$Bytes, [string]$ObjectId, [int]$MaxBytes)
    if ($null -eq $Bytes -or $Bytes.Length -gt $MaxBytes -or
        [string]$ObjectId -cnotmatch '^[a-fA-F0-9]{40}$') {
        throw 'invalid-item'
    }
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $actual = [Convert]::ToHexString(
        [Security.Cryptography.SHA1]::HashData([byte[]]($header + $Bytes))
    ).ToLowerInvariant()
    if ($actual -ine $ObjectId) { throw 'invalid-item' }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    }
    catch { throw 'unsupported-change' }
    if ($text -cmatch '[\x00-\x08\x0b\x0c\x0e-\x1f]' -or
        $text.StartsWith("version https://git-lfs.github.com/spec/v1`n")) {
        throw 'unsupported-change'
    }
    return @{ text = $text; bytes = $Bytes.Length }
}

function Get-IntakeSourceTree {
    param([scriptblock]$Read, [string[]]$Route, [string]$Commit,
        [int]$MaxEntries)
    $commitResponse = & $Read 'commits' ($Route + @("commitId=$Commit")) @() 65536
    if ([string]$commitResponse.commitId -ine $Commit -or
        [string]$commitResponse.treeId -cnotmatch '^[a-fA-F0-9]{40}$') {
        throw 'project-identity-unknown'
    }
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@{ path = ''; objectId = ([string]$commitResponse.treeId).ToLowerInvariant() })
    $entries = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($queue.Count -gt 0) {
        if ($entries.Count + $queue.Count -gt $MaxEntries) {
            throw 'project-identity-unknown'
        }
        $directory = $queue.Dequeue()
        $tree = & $Read 'trees' ($Route + @("sha1=$($directory.objectId)")) @(
            'recursive=false') 2097152
        if ([string]$tree.objectId -ine [string]$directory.objectId -or
            $tree['treeEntries'] -isnot [array] -or
            $tree.treeEntries.Count + $entries.Count -gt $MaxEntries) {
            throw 'project-identity-unknown'
        }
        $raw = [IO.MemoryStream]::new()
        try {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $tree.treeEntries) {
                if ($item -isnot [Collections.IDictionary] -or
                    [string]$item.relativePath -cnotmatch '^[^/\\?#\x00-\x1f]{1,255}$' -or
                    $item.relativePath -in @('.', '..') -or
                    -not $names.Add([string]$item.relativePath) -or
                    [string]$item.objectId -cnotmatch '^[a-fA-F0-9]{40}$') {
                    throw 'project-identity-unknown'
                }
                $mode = [string]$item.mode
                $kind = [string]$item.gitObjectType
                if (($kind -ceq 'tree' -and $mode -cne '40000') -or
                    ($kind -ceq 'blob' -and $mode -cnotin @('100644', '100755')) -or
                    $kind -cnotin @('blob', 'tree')) {
                    throw 'project-identity-unknown'
                }
                $path = "$($directory.path)/$($item.relativePath)"
                if ($path.Length -gt 2048 -or -not $seen.Add($path)) {
                    throw 'project-identity-unknown'
                }
                $oid = ([string]$item.objectId).ToLowerInvariant()
                $prefix = [Text.Encoding]::UTF8.GetBytes("$mode $($item.relativePath)`0")
                $raw.Write($prefix, 0, $prefix.Length)
                $hash = [Convert]::FromHexString($oid)
                $raw.Write($hash, 0, $hash.Length)
                $entries.Add(@{ path = $path; objectId = $oid; gitObjectType = $kind })
                if ($kind -ceq 'tree') {
                    $queue.Enqueue(@{ path = $path; objectId = $oid })
                }
            }
            $bytes = $raw.ToArray()
            if ($null -ne $tree['size'] -and [string]$tree.size -cne
                [string]$bytes.Length) { throw 'project-identity-unknown' }
            $header = [Text.Encoding]::ASCII.GetBytes("tree $($bytes.Length)`0")
            $digest = [Convert]::ToHexString(
                [Security.Cryptography.SHA1]::HashData([byte[]]($header + $bytes))
            ).ToLowerInvariant()
            if ($digest -cne [string]$directory.objectId) {
                throw 'project-identity-unknown'
            }
        }
        finally { $raw.Dispose() }
    }
    return @{ rootTreeId = ([string]$commitResponse.treeId).ToLowerInvariant()
        entries = @($entries.ToArray()) }
}

function Assert-IntakeProjectScope {
    param([Collections.IDictionary]$Scope, [object[]]$Sources,
        [string]$RepositoryId, [string]$SourceCommit, [int]$MaxFiles)
    if ($null -eq $Scope -or $Scope.schemaVersion -ne 1 -or
        $Scope.kind -cne 'source-bound-project-scope-summary-v1' -or
        $Scope.repositoryId -ine $RepositoryId -or
        $Scope.sourceCommit -ine $SourceCommit -or
        $Scope.complete -isnot [bool] -or $Scope.files -isnot [array] -or
        $Scope.files.Count -gt $MaxFiles) {
        throw 'project-identity-unknown'
    }
    $expected = @($Sources | Where-Object { $_.path -cmatch '\.cs$' })
    if ($Scope.files.Count -ne $expected.Count -or
        ($Scope.complete -and $expected.Count -gt 0 -and
            [string]$Scope.rootTreeId -cnotmatch '^[a-f0-9]{40}$') -or
        ($null -ne $Scope.rootTreeId -and
            [string]$Scope.rootTreeId -cnotmatch '^[a-f0-9]{40}$')) {
        throw 'project-identity-unknown'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $incomplete = $false
    foreach ($receipt in $Scope.files) {
        if ($receipt -isnot [Collections.IDictionary] -or
            [string]$receipt.pathDigest -cnotmatch '^[a-f0-9]{64}$' -or
            -not $seen.Add([string]$receipt.pathDigest) -or
            [string]$receipt.objectId -cnotmatch '^[a-f0-9]{40}$' -or
            $receipt.status -cnotin @('complete', 'unknown') -or
            ($receipt.status -ceq 'complete' -and
                [string]$receipt.attestationDigest -cnotmatch '^[a-f0-9]{64}$') -or
            ($receipt.status -ceq 'unknown' -and
                $null -ne $receipt.attestationDigest)) {
            throw 'project-identity-unknown'
        }
        $source = @($expected | Where-Object {
                (Get-IntakeDigest $_.path) -ceq $receipt.pathDigest -and
                $_.objectId -ceq $receipt.objectId
            })
        if ($source.Count -ne 1 -or
            ($receipt.status -ceq 'complete' -and
                ($source[0].projectEvidence -isnot [Collections.IDictionary] -or
                    (Get-IntakeDigest $source[0].projectEvidence) -cne
                        $receipt.attestationDigest)) -or
            ($receipt.status -ceq 'unknown' -and
                $null -ne $source[0]['projectEvidence'])) {
            throw 'project-identity-unknown'
        }
        if ($receipt.status -ceq 'unknown') { $incomplete = $true }
    }
    if ($Scope.complete -eq $incomplete) { throw 'project-identity-unknown' }
}

function Get-IntakePass {
    param([scriptblock]$Provider, [Collections.IDictionary]$Config,
        [ref]$Reads, [Diagnostics.Stopwatch]$Clock, [int]$Pass,
        [string]$Cutoff)
    $seen = @{}
    $duplicates = 0
    $offset = 0
    $size = [int]$Config.limits.pageSize
    $total = $null
    $keyset = $null -ne $Config['pagination']
    $cursor = $Cutoff
    $shortPage = $false
    for ($page = 0; $page -lt [int]$Config.limits.maxPages; $page++) {
        $request = @{ pass = $Pass; skip = $offset; top = $size }
        if ($keyset) {
            $request.skip = 0
            $request.top = $size + 1
            $request.maxTime = $cursor
        }
        $raw = Invoke-IntakeRead $Provider 'ListPage' $request $Config $Reads $Clock
        if ($raw.items -isnot [array] -or $null -eq $raw.count -or
            (Assert-IntakeNumber $raw.count count 0 $request.top) -ne $raw.items.Count) {
            throw 'invalid-page'
        }
        if ($keyset) {
            if ($raw.items.Count -eq 0) {
                return @{ seen = $seen; duplicates = $duplicates; pages = $page + 1 }
            }
            if ($shortPage) { throw 'missing-page' }
            $windowTime = [DateTimeOffset]::Parse($cursor,
                [Globalization.CultureInfo]::InvariantCulture)
            $times = [Collections.Generic.List[DateTimeOffset]]::new()
            foreach ($item in $raw.items) {
                $date = [DateTimeOffset]::MinValue
                if ($item -isnot [Collections.IDictionary] -or
                    [string]$item.creationDate -cnotmatch
                        '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{1,7}Z$' -or
                    -not [DateTimeOffset]::TryParseExact(
                        [string]$item.creationDate, 'yyyy-MM-ddTHH:mm:ss.FFFFFFFK',
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::None, [ref]$date) -or
                    $date -ge $windowTime -or
                    ($times.Count -gt 0 -and $date -gt $times[$times.Count - 1])) {
                    throw 'mutable-page'
                }
                $times.Add($date)
            }
            $take = [Math]::Min($size, $raw.items.Count)
            if ($raw.items.Count -gt $size -and
                $times[$size] -eq $times[$size - 1]) {
                throw 'page-cursor-collision'
            }
            $raw.items = @($raw.items | Select-Object -First $take)
            $raw.count = $take
            $cursor = $times[$take - 1].UtcDateTime.ToString('o')
            $shortPage = $times.Count -lt ($size + 1)
            if ($seen.Count + $take -gt [int]$Config.limits.maxPullRequests) {
                throw 'pr-budget'
            }
        }
        if ($null -ne $raw['totalCount']) {
            if (-not $keyset) {
                $declared = Assert-IntakeNumber $raw['totalCount'] totalCount 0 10000
                if ($null -ne $total -and $total -ne $declared) { throw 'mutable-page' }
                $total = $declared
                if ($total -gt [int]$Config.limits.maxPullRequests) { throw 'pr-budget' }
            }
        }
        foreach ($item in $raw.items) {
            if ($item -isnot [Collections.IDictionary]) { throw 'invalid-page' }
            $id = Assert-IntakeNumber $item.pullRequestId pullRequestId 1 ([int]::MaxValue)
            if ([string]$item.status -cne 'active' -or $item.isDraft -isnot [bool] -or
                [string]$item.targetRef -cnotmatch '^refs/heads/[^~^:?*\[\\]+$' -or
                ([string]$item.targetRef).Length -gt 512) {
                throw 'invalid-page'
            }
            $value = [ordered]@{
                pullRequestId = $id
                status = 'active'
                isDraft = [bool]$item.isDraft
                targetRef = [string]$item.targetRef
            }
            $key = [string]$id
            $digest = Get-IntakeDigest $value
            if ($seen.ContainsKey($key)) {
                if ($keyset) { throw 'mutable-page' }
                $duplicates++
                if ($seen[$key].digest -cne $digest) { throw 'mutable-page' }
            }
            else { $seen[$key] = @{ digest = $digest; value = $value } }
        }
        if ($seen.Count -gt [int]$Config.limits.maxPullRequests) { throw 'pr-budget' }
        if ($keyset) { continue }
        $offset += $raw.items.Count
        if ($null -ne $total -and $offset -gt $total) { throw 'mutable-page' }
        if ($raw.items.Count -eq 0) {
            if ($duplicates -gt 0 -and $null -eq $total) { throw 'missing-page' }
            if ($null -ne $total -and ($offset -ne $total -or $seen.Count -ne $total)) {
                throw 'missing-page'
            }
            return @{ seen = $seen; duplicates = $duplicates; pages = $page + 1 }
        }
        if ($null -ne $total -and $offset -eq $total) {
            if ($seen.Count -ne $total) { throw 'missing-page' }
            return @{ seen = $seen; duplicates = $duplicates; pages = $page + 1 }
        }
    }
    throw 'page-budget'
}

function Assert-IntakeHead {
    param([Collections.IDictionary]$Head, [int]$Id, [Collections.IDictionary]$Config)
    if ((Assert-IntakeNumber $Head.pullRequestId pullRequestId 1 ([int]::MaxValue)) -ne $Id -or
        [string]$Head.repositoryId -ine [string]$Config.repositoryId -or
        [string]$Head.projectId -ine [string]$Config.projectId -or
        [string]$Head.status -cnotin @('active', 'completed', 'abandoned') -or
        $Head.isDraft -isnot [bool] -or
        [string]$Head.sourceRef -cnotmatch '^refs/heads/[^~^:?*\[\\]+$' -or
        [string]$Head.targetRef -cnotmatch '^refs/heads/[^~^:?*\[\\]+$' -or
        ([string]$Head.sourceRef).Length -gt 512 -or
        ([string]$Head.targetRef).Length -gt 512 -or
        [string]$Head.sourceCommit -cnotmatch '^[a-fA-F0-9]{40}$' -or
        [string]$Head.targetCommit -cnotmatch '^[a-fA-F0-9]{40}$' -or
        [string]$Head.commonCommit -cnotmatch '^[a-fA-F0-9]{40}$') {
        throw 'invalid-head'
    }
    [void](Assert-IntakeNumber $Head.iterationId iterationId 1 ([int]::MaxValue))
    return [ordered]@{
        repositoryId = ([string]$Head.repositoryId).ToLowerInvariant()
        projectId = ([string]$Head.projectId).ToLowerInvariant()
        pullRequestId = $Id
        sourceRef = [string]$Head.sourceRef
        targetRef = [string]$Head.targetRef
        sourceCommit = ([string]$Head.sourceCommit).ToLowerInvariant()
        targetCommit = ([string]$Head.targetCommit).ToLowerInvariant()
        commonCommit = ([string]$Head.commonCommit).ToLowerInvariant()
        iterationId = [int]$Head.iterationId
        status = [string]$Head.status
        isDraft = [bool]$Head.isDraft
    }
}

function Get-IntakeDiscussionCounts {
    param([Collections.IDictionary]$Response, [Collections.IDictionary]$Config,
        [Collections.IDictionary]$Head)
    if ($Response.threads -isnot [array] -or $Response.threads.Count -gt
        [int]$Config.limits.maxThreads -or $null -eq $Response.count -or
        (Assert-IntakeNumber $Response.count threadCount 0 2000) -ne
        $Response.threads.Count) { throw 'invalid-discussions' }
    $uniqueThreads = [Collections.Generic.List[object]]::new()
    $threadIds = [Collections.Generic.HashSet[int]]::new()
    $uniqueCommentCount = 0
    foreach ($rawThread in $Response.threads) {
        if ($rawThread -isnot [Collections.IDictionary]) { throw 'invalid-discussions' }
        $threadId = Assert-IntakeNumber $rawThread.id threadId 1 ([int]::MaxValue)
        if (-not $threadIds.Add($threadId) -or $rawThread.comments -isnot [array]) {
            throw 'mutable-discussions'
        }
        $copy = [ordered]@{}
        foreach ($name in $rawThread.Keys) { $copy[[string]$name] = $rawThread[$name] }
        $distinct = [Collections.Generic.List[object]]::new()
        $commentDigests = @{}
        foreach ($comment in $rawThread.comments) {
            if ($comment -isnot [Collections.IDictionary]) { throw 'invalid-discussions' }
            $commentId = Assert-IntakeNumber $comment.id commentId 1 ([int]::MaxValue)
            $digest = Get-IntakeDigest $comment
            if ($commentDigests.ContainsKey($commentId)) {
                if ($commentDigests[$commentId] -cne $digest) {
                    throw 'mutable-discussions'
                }
                continue
            }
            $commentDigests[$commentId] = $digest
            $uniqueCommentCount++
            if ($uniqueCommentCount -gt [int]$Config.limits.maxComments) {
                throw 'comment-budget'
            }
            [void]$distinct.Add($comment)
        }
        $copy.comments = @($distinct)
        [void]$uniqueThreads.Add($copy)
    }
    $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
        -Id ([string]$Config.expectedAccount.id) `
        -Descriptor ([string]$Config.expectedAccount.descriptor) `
        -UniqueName ([string]$Config.expectedAccount.uniqueName)
    $rawResponse = [ordered]@{
        count = $uniqueThreads.Count
        value = @($uniqueThreads)
    }
    $typed = @{}
    $pageSize = 200
    for ($ordinal = 0; $ordinal -lt [Math]::Max(1,
            [int][Math]::Ceiling($uniqueThreads.Count / $pageSize)); $ordinal++) {
        $page = ConvertTo-OwnerAzureDevOpsDiscussionPage `
            -Arguments ([ordered]@{
                repositoryId = $Head.repositoryId
                projectId = $Head.projectId
                pullRequestId = $Head.pullRequestId
                sourceCommit = $Head.sourceCommit
                targetCommit = $Head.targetCommit
                targetRef = $Head.targetRef
                pageOrdinal = $ordinal
                pageSize = $pageSize
                continuationToken = if ($ordinal -eq 0) { $null } else {
                    "skip:$($ordinal * $pageSize)"
                }
            }) -RawResponse $rawResponse -CurrentIteration @{
                id = $Head.iterationId
                sourceCommit = $Head.sourceCommit
                targetCommit = $Head.targetCommit
            } -ReviewerIdentity $reviewer
        foreach ($thread in $page.threads) {
            foreach ($comment in $thread.comments) {
                $typed["$($thread.threadId):$($comment.commentId)"] = @{
                    contextState = $thread.contextState
                    comment = $comment
                }
            }
        }
    }
    $keys = @{}
    $human = 0
    $automation = 0
    $ambiguous = 0
    $outdated = 0
    $currentAnchored = 0
    foreach ($thread in $Response.threads) {
        $threadId = Assert-IntakeNumber $thread.id threadId 1 ([int]::MaxValue)
        if ($thread.comments -isnot [array]) { throw 'invalid-discussions' }
        foreach ($comment in $thread.comments) {
            $commentId = Assert-IntakeNumber $comment.id commentId 1 ([int]::MaxValue)
            $key = "$threadId`:$commentId"
            $body = $comment['content']
            if ($null -ne $body -and ([string]$body).Length -gt 65536) {
                throw 'invalid-discussions'
            }
            $author = $comment['author']
            if ($author -isnot [Collections.IDictionary]) { $author = @{} }
            $marker = ([string]$body).Contains([string]$Config.automationMarker)
            $fingerprint = Get-IntakeDigest @($marker, [string]$body,
                [string]$author['id'], [string]$author['uniqueName'],
                $thread['threadContext'], $thread['pullRequestThreadContext'])
            if ($keys.ContainsKey($key)) {
                if ($keys[$key] -cne $fingerprint) { throw 'mutable-discussions' }
                continue
            }
            $keys[$key] = $fingerprint
            if ($keys.Count -gt [int]$Config.limits.maxComments) { throw 'comment-budget' }
            $mapped = $typed[$key]
            if ($null -eq $mapped) { throw 'invalid-discussions' }
            if ($mapped.comment.isDeleted -or $mapped.comment.commentType -cne 'text') {
                continue
            }
            if ($mapped.contextState -ceq 'outdated') {
                $outdated++
                $ambiguous++
                continue
            }
            $context = $thread['threadContext']
            if ($mapped.contextState -ceq 'current' -and
                $context -is [Collections.IDictionary] -and
                $context['filePath'] -and
                ($context['rightFileStart'] -isnot [Collections.IDictionary] -or
                    $context['rightFileEnd'] -isnot [Collections.IDictionary] -or
                    $null -eq $context['rightFileStart']['line'] -or
                    $context['rightFileStart']['line'] -ne
                    $context['rightFileEnd']['line'])) {
                $ambiguous++
                continue
            }
            if ($mapped.contextState -ceq 'ambiguous' -or
                $mapped.comment.reviewerIdentityState -ceq 'ambiguous' -or
                $null -eq $body -or $null -eq $author['id']) {
                $ambiguous++
                continue
            }
            if ($mapped.contextState -ceq 'current') {
                $currentAnchored++
            }
            if ($marker -and $mapped.comment.reviewerOwned) { $automation++ }
            else { $human++ }
        }
    }
    return [ordered]@{
        human = $human
        automation = $automation
        ambiguous = $ambiguous
        outdated = $outdated
        currentAnchored = $currentAnchored
    }
}

function Get-ActivePrDiscussionCounts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Response,
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][Collections.IDictionary]$Head)
    Assert-IntakeConfig $Config
    $verified = Assert-IntakeHead $Head ([int]$Head.pullRequestId) $Config
    return Get-IntakeDiscussionCounts $Response $Config $verified
}

function Get-ActivePrDiscussionSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Response,
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][Collections.IDictionary]$Head,
        [Parameter(Mandatory)][object]$Contract)
    Assert-IntakeConfig $Config
    $verified = Assert-IntakeHead $Head ([int]$Head.pullRequestId) $Config
    $request = $Contract.Request
    if ([string]$request.RepositoryId -ine $verified.repositoryId -or
        [string]$request.ProjectId -ine $verified.projectId -or
        [long]$request.PullRequestId -ne $verified.pullRequestId -or
        [string]$request.SourceCommit -cne $verified.sourceCommit -or
        [string]$request.TargetCommit -cne $verified.targetCommit -or
        [string]$request.TargetRef -cne $verified.targetRef) {
        throw 'discussion-head-mismatch'
    }
    [void](Get-IntakeDiscussionCounts $Response $Config $verified)
    $threads = [Collections.Generic.List[object]]::new()
    foreach ($thread in $Response.threads) {
        $copy = [ordered]@{}
        foreach ($name in $thread.Keys) { $copy[[string]$name] = $thread[$name] }
        $unique = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[int]]::new()
        foreach ($comment in $thread.comments) {
            if ($seen.Add([int]$comment.id)) { [void]$unique.Add($comment) }
        }
        $copy.comments = @($unique)
        [void]$threads.Add($copy)
    }
    $raw = [ordered]@{ count = $threads.Count; value = @($threads) }
    $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
        -Id ([string]$Config.expectedAccount.id) `
        -Descriptor ([string]$Config.expectedAccount.descriptor) `
        -UniqueName ([string]$Config.expectedAccount.uniqueName)
    $convertPage = Get-Command ConvertTo-OwnerAzureDevOpsDiscussionPage
    $handler = {
        param($operation, $arguments)
        if ($operation -cne 'GetDiscussionPage') { throw 'unsupported-read' }
        & $convertPage -Arguments $arguments -RawResponse $raw `
            -CurrentIteration @{ id = $verified.iterationId
                sourceCommit = $verified.sourceCommit
                targetCommit = $verified.targetCommit } -ReviewerIdentity $reviewer
    }.GetNewClosure()
    $adapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
        -Name 'bounded-rule-discussions' -ReviewerIdentity $reviewer -Handler $handler
    $limits = New-OwnerDiscussionLimits -MaximumPages 10 -PageSize 200 `
        -MaximumThreads ([int]$Config.limits.maxThreads) `
        -MaximumComments ([int]$Config.limits.maxComments) -MaximumBytes 16777216
    $snapshot = Get-OwnerDiscussionSnapshot -Contract $Contract -Provider $adapter `
        -Limits $limits -RequireAzureDevOpsProvenance
    if ($snapshot.CurrentIterationId -ne $verified.iterationId -or
        $snapshot.ThreadCount -ne $threads.Count) { throw 'invalid-discussions' }
    return $snapshot
}

function Get-IntakePriorObservation {
    param($Previous, [int]$Id, [string]$RuleId, [string]$Capability,
        [string]$CurrentDigest, [string]$ConfigDigest)
    if ($null -eq $Previous -or
        [string]$Previous.binding.configDigest -cne $ConfigDigest) { return $null }
    foreach ($oldHead in @($Previous.heads)) {
        if ([int]$oldHead.pullRequestId -ne $Id) { continue }
        foreach ($oldRule in @($oldHead.rules)) {
            if ([string]$oldRule.id -cne $RuleId -or
                [string]$oldRule.capability -cne $Capability) { continue }
            $source = $null
            $generation = ''
            if ([string]$oldRule.state -ceq 'evaluated' -and
                [string]$oldRule.observationDigest -cmatch '^[a-f0-9]{64}$' -and
                [string]$oldHead.declarationDigest -cmatch '^[a-f0-9]{64}$') {
                $source = [string]$oldHead.declarationDigest
                $generation = [string]$Previous.generation
            }
            elseif ($oldRule['priorObservation'] -is [Collections.IDictionary] -and
                [string]$oldRule.priorObservation.declarationDigest -cmatch '^[a-f0-9]{64}$') {
                $source = [string]$oldRule.priorObservation.declarationDigest
                $generation = [string]$oldRule.priorObservation.generation
            }
            if ($null -ne $source) {
                return [ordered]@{
                    state = if ($source -cne $CurrentDigest) { 'stale' } else { 'previous-only' }
                    declarationDigest = $source
                    generation = $generation
                }
            }
        }
    }
    return $null
}

function Get-IntakeRuleIdentity {
    param([Collections.IDictionary]$Head, [string]$RuleId,
        [string]$CapabilityId, [string]$ConfigDigest)
    return Get-IntakeDigest ([ordered]@{
            schemaVersion = 1
            repositoryId = $Head.repositoryId
            projectId = $Head.projectId
            pullRequestId = $Head.pullRequestId
            sourceCommit = $Head.sourceCommit
            targetCommit = $Head.targetCommit
            commonCommit = $Head.commonCommit
            targetRef = $Head.targetRef
            iterationId = $Head.iterationId
            ruleId = $RuleId
            capabilityId = $CapabilityId
            configDigest = $ConfigDigest
        })
}

function Test-IntakeStateRootReadOnly {
    param([string]$Path, [string]$RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'Durable state root must be an absolute path.'
    }
    $root = [IO.Path]::GetFullPath($Path)
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $relative = [IO.Path]::GetRelativePath($repository, $root)
    if ($relative -eq '.' -or
        ($relative -ne '..' -and
            -not $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)") -and
            -not [IO.Path]::IsPathFullyQualified($relative))) {
        throw 'Durable state root must be outside the repository.'
    }
    $candidate = $root
    while ($candidate) {
        $item = Get-Item -LiteralPath $candidate -Force `
            -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Durable state root path contains a link.'
            }
            if ($candidate -eq $root) {
                [void](Resolve-AgentTrustedRoot -Path $root -Kind durable-state `
                        -RepositoryRoot $repository)
            }
        }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if (-not $parent -or $parent -eq $candidate) { break }
        $candidate = $parent
    }
    return $root
}

function New-IntakeDisabledSummary {
    param([Collections.IDictionary]$Config)
    $rules = @($Config.rules | ForEach-Object {
            [ordered]@{
                capabilityId = [string]$_.capability
                ruleId = [string]$_.id
                discovered = $null
                eligible = $null
                evaluated = 0
                skipped = 0
                error = 0
                pending = 0
                gaps = @('default-off', 'inventory-unknown')
            }
        })
    return [ordered]@{
        schemaVersion = 1
        kind = 'active-pr-intake-cohort'
        generation = $null
        generationOrdinal = $null
        generationFile = $null
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        observedUtc = [DateTime]::UtcNow.ToString('o')
        binding = [ordered]@{
            organization = [string]$Config.organization
            projectId = ([string]$Config.projectId).ToLowerInvariant()
            repositoryId = ([string]$Config.repositoryId).ToLowerInvariant()
            configDigest = Get-IntakeDigest $Config
        }
        mode = 'dry-run-read-only'
        writerEligible = $false
        autoPost = $false
        state = 'disabled'
        populationKnown = $false
        inventory = [ordered]@{
            state = 'unknown'
            consistency = 'two-pass-reconciled-no-atomic-snapshot'
            active = $null
            discovered = $null
            eligible = $null
            excludedOtherTargets = $null
            nonDraftExcludedOtherTargets = $null
            draft = $null
            nonDraft = $null
            byTargetRef = $null
            gaps = @('default-off')
        }
        denominators = [ordered]@{
            active = 0; nonDraft = 0; draft = 0; eligible = 0
            outOfPolicy = 0; byTargetRef = @{}
        }
        counts = [ordered]@{
            discovered = 0; attempted = 0; evaluated = 0; evaluatedRules = 0
            skipped = 0; error = 0; deferred = 0
        }
        gaps = @('default-off', 'inventory-unknown')
        gapCounts = [ordered]@{
            enumerationUnknown = 0; duplicateEntries = 0; deferred = 0
            unknownHeads = 0; unknownRules = 0; staleRules = 0; drift = 0
        }
        pages = [ordered]@{ first = 0; second = 0 }
        cursor = [ordered]@{ nextPullRequestId = $null }
        heads = @()
        rules = $rules
        unmetCapabilities = @()
        reasonCodes = @('default-off')
        readCount = 0
    }
}

function Invoke-ActivePrIntake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [int[]]$CanaryPullRequestIds,
        [switch]$Run
    )
    Assert-IntakeConfig $Config
    if ($PSBoundParameters.ContainsKey('CanaryPullRequestIds')) {
        if ($CanaryPullRequestIds.Count -lt 1 -or $CanaryPullRequestIds.Count -gt 2 -or
            @($CanaryPullRequestIds | Where-Object { $_ -lt 1 }).Count -gt 0 -or
            @($CanaryPullRequestIds | Select-Object -Unique).Count -ne
                $CanaryPullRequestIds.Count) {
            throw 'invalid-canary-selection'
        }
    }
    $StateRoot = Test-IntakeStateRootReadOnly -Path $StateRoot `
        -RepositoryRoot $RepositoryRoot
    if (-not $Run -or -not $Config.enabled) {
        return New-IntakeDisabledSummary -Config $Config
    }
    $root = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
        -RepositoryRoot $RepositoryRoot -Create
    $root = Resolve-AgentTrustedRoot -Path (Join-Path $root 'active-pr-intake-v1') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $generationRoot = Resolve-AgentTrustedRoot -Path (Join-Path $root 'generations') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $lock = [IO.File]::Open((Join-Path $root 'cohort.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $path = Join-Path $root 'cohort.json'
        $previous = $null
        if (Test-Path -LiteralPath $path) {
            $file = Get-Item -LiteralPath $path -Force
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or $file.Length -gt 8388608) {
                throw 'Untrusted previous intake state.'
            }
            $previousJson = Get-Content -LiteralPath $path -Raw
            $previous = $previousJson | ConvertFrom-Json -AsHashtable -Depth 32
            if ($previous.schemaVersion -ne 1 -or
                $previous.kind -cne 'active-pr-intake-cohort' -or
                [string]$previous.generation -cnotmatch '^[a-f0-9]{32}$' -or
                $previous.generationOrdinal -isnot [long] -and
                $previous.generationOrdinal -isnot [int] -or
                $previous.generationOrdinal -lt 1 -or
                $previous.generationOrdinal -ge [int]::MaxValue) {
                throw 'Invalid previous intake state.'
            }
            $generationName = "$($previous.generation).json"
            if ([string]$previous.generationFile -cne
                (Join-Path 'generations' $generationName)) {
                throw 'Previous intake generation binding is invalid.'
            }
            $immutable = Join-Path $generationRoot $generationName
            if (-not (Test-Path -LiteralPath $immutable -PathType Leaf)) {
                throw 'Previous immutable intake generation is missing.'
            }
            $immutableFile = Get-Item -LiteralPath $immutable -Force
            if ($immutableFile.Attributes -band [IO.FileAttributes]::ReparsePoint -or
                $immutableFile.Length -gt 8388608 -or
                (Get-Content -LiteralPath $immutable -Raw) -cne $previousJson) {
                throw 'Previous immutable intake generation differs from latest snapshot.'
            }
            if ([string]$previous.binding.organization -cne [string]$Config.organization -or
                [string]$previous.binding.projectId -ine [string]$Config.projectId -or
                [string]$previous.binding.repositoryId -ine [string]$Config.repositoryId) {
                throw 'Intake state is bound to a different repository.'
            }
        }
        $envelope = [ordered]@{
            schemaVersion = 1
            kind = 'active-pr-intake-cohort'
            generation = [guid]::NewGuid().ToString('N')
            generationOrdinal = if ($previous) {
                [int]$previous.generationOrdinal + 1
            } else { 1 }
            generationFile = $null
            createdAtUtc = [DateTime]::UtcNow.ToString('o')
            observedUtc = $null
            binding = [ordered]@{
                organization = [string]$Config.organization
                projectId = ([string]$Config.projectId).ToLowerInvariant()
                repositoryId = ([string]$Config.repositoryId).ToLowerInvariant()
                configDigest = Get-IntakeDigest $Config
            }
            mode = 'dry-run-read-only'
            writerEligible = $false
            autoPost = $false
            state = 'unknown'
            populationKnown = $false
            inventory = [ordered]@{
                state = 'unknown'
                consistency = 'two-pass-reconciled-no-atomic-snapshot'
                active = $null
                discovered = $null
                eligible = $null
                excludedOtherTargets = $null
                nonDraftExcludedOtherTargets = $null
                draft = $null
                nonDraft = $null
                byTargetRef = $null
                gaps = @()
            }
            denominators = [ordered]@{ active = 0; nonDraft = 0; draft = 0; eligible = 0; outOfPolicy = 0; byTargetRef = @{} }
            counts = [ordered]@{ discovered = 0; attempted = 0; evaluated = 0; evaluatedRules = 0; skipped = 0; error = 0; deferred = 0 }
            gaps = [ordered]@{ enumerationUnknown = 0; duplicateEntries = 0
                deferred = 0; unknownHeads = 0; unknownRules = 0
                staleRules = 0; drift = 0 }
            pages = [ordered]@{ first = 0; second = 0 }
            cursor = [ordered]@{ nextPullRequestId = $null }
            heads = @()
            rules = @()
            unmetCapabilities = @()
            reasonCodes = @()
        }
        $envelope.generationFile = Join-Path 'generations' "$($envelope.generation).json"
        $reasons = [Collections.Generic.List[string]]::new()
        $heads = [Collections.Generic.List[object]]::new()
        $reads = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $cutoff = [DateTime]::UtcNow.ToString('o')
        try {
                $identity = Invoke-IntakeRead $Provider Identity @{} $Config ([ref]$reads) $clock
                if ([string]$identity.id -ine [string]$Config.expectedAccount.id -or
                    [string]$identity.uniqueName -ine [string]$Config.expectedAccount.uniqueName -or
                    [string]$identity.descriptor -cne [string]$Config.expectedAccount.descriptor) {
                    throw 'account-mismatch'
                }
                $first = Get-IntakePass $Provider $Config ([ref]$reads) $clock 1 $cutoff
                $envelope.pages.first = $first.pages
                $second = Get-IntakePass $Provider $Config ([ref]$reads) $clock 2 $cutoff
                $envelope.pages.second = $second.pages
                $envelope.gaps.duplicateEntries = $first.duplicates + $second.duplicates
                if ($first.seen.Count -ne $second.seen.Count) { throw 'mutable-page' }
                foreach ($key in $first.seen.Keys) {
                    if (-not $second.seen.ContainsKey($key) -or
                        $first.seen[$key].digest -cne $second.seen[$key].digest) {
                        throw 'mutable-page'
                    }
                }
                $envelope.populationKnown = $true
                $envelope.inventory.state = 'complete'
                if ($null -ne $Config['pagination']) {
                    $envelope.inventory.cutoffUtc = $cutoff
                }
                $envelope.inventory.gaps = @('no-atomic-snapshot-token')
                $ids = @($first.seen.Keys | ForEach-Object { [int]$_ } | Sort-Object)
                $envelope.denominators.active = $ids.Count
                foreach ($id in $ids) {
                    $item = $first.seen[[string]$id].value
                    $ref = [string]$item.targetRef
                    if (-not $envelope.denominators.byTargetRef.ContainsKey($ref)) {
                        $envelope.denominators.byTargetRef[$ref] =
                            [ordered]@{ active = 0; nonDraft = 0; draft = 0 }
                    }
                    $bucket = $envelope.denominators.byTargetRef[$ref]
                    $bucket.active++
                    if ($item.isDraft) { $bucket.draft++; $envelope.denominators.draft++ }
                    else {
                        $bucket.nonDraft++; $envelope.denominators.nonDraft++
                        if ($ref -ceq 'refs/heads/master') { $envelope.denominators.eligible++ }
                        else { $envelope.denominators.outOfPolicy++ }
                    }
                }
                $nonDraftIds = @($ids | Where-Object {
                        -not $first.seen[[string]$_].value.isDraft
                    })
                $envelope.counts.discovered = $nonDraftIds.Count
                $envelope.inventory.discovered = $nonDraftIds.Count
                $envelope.inventory.active = $envelope.denominators.active
                $envelope.inventory.eligible = $envelope.denominators.eligible
                $envelope.inventory.excludedOtherTargets = @(
                    $nonDraftIds | Where-Object {
                        $first.seen[[string]$_].value.targetRef -cne 'refs/heads/master'
                    }
                ).Count
                $envelope.inventory.nonDraftExcludedOtherTargets =
                    $envelope.denominators.outOfPolicy
                $envelope.inventory.draft = $envelope.denominators.draft
                $envelope.inventory.nonDraft = $envelope.denominators.nonDraft
                $envelope.inventory.byTargetRef = $envelope.denominators.byTargetRef
                if ($envelope.gaps.duplicateEntries -gt 0) {
                    $envelope.inventory.gaps += 'duplicate-list-entries-reconciled'
                }
                $eligible = @($ids | Where-Object {
                        $item = $first.seen[[string]$_].value
                        -not $item.isDraft -and $item.targetRef -ceq 'refs/heads/master'
                    })
                if ($PSBoundParameters.ContainsKey('CanaryPullRequestIds')) {
                    foreach ($canaryId in $CanaryPullRequestIds) {
                        if ($canaryId -notin $eligible) {
                            throw 'canary-not-in-complete-eligible-inventory'
                        }
                    }
                }
                $start = 0
                if ($previous -and $previous.binding.configDigest -ceq $envelope.binding.configDigest -and
                    $null -ne $previous.cursor.nextPullRequestId -and $eligible.Count -gt 0) {
                    $target = Assert-IntakeNumber $previous.cursor.nextPullRequestId cursor 1 ([int]::MaxValue)
                    while ($start -lt $eligible.Count -and $eligible[$start] -lt $target) { $start++ }
                    if ($start -eq $eligible.Count) { $start = 0 }
                }
                $selected = [Collections.Generic.HashSet[int]]::new()
                $selectedOrder = [Collections.Generic.List[int]]::new()
                $limit = if ($PSBoundParameters.ContainsKey('CanaryPullRequestIds')) {
                    $CanaryPullRequestIds.Count
                } else {
                    [Math]::Min($eligible.Count, [int]$Config.limits.maxHeadsPerRun)
                }
                if ($PSBoundParameters.ContainsKey('CanaryPullRequestIds')) {
                    foreach ($candidate in $CanaryPullRequestIds) {
                        [void]$selected.Add($candidate)
                        $selectedOrder.Add($candidate)
                    }
                } else {
                    for ($n = 0; $n -lt $limit; $n++) {
                        $candidate = $eligible[($start + $n) % $eligible.Count]
                        [void]$selected.Add($candidate)
                        $selectedOrder.Add($candidate)
                    }
                }
                if ($eligible.Count -gt 0 -and
                    -not $PSBoundParameters.ContainsKey('CanaryPullRequestIds')) {
                    $envelope.cursor.nextPullRequestId =
                        $eligible[($start + $limit) % $eligible.Count]
                }
                $processingOrder = @($selectedOrder.ToArray()) +
                    @($nonDraftIds | Where-Object { -not $selected.Contains($_) })
                foreach ($id in $processingOrder) {
                    $item = $first.seen[[string]$id].value
                    $entry = [ordered]@{
                        pullRequestId = $id
                        targetRef = $item.targetRef
                        declaration = $null
                        declarationDigest = $null
                        state = 'pending'
                        reasonCode = 'not-selected'
                        discussion = $null
                        lineEvidence = $null
                        lineEvidenceDigest = $null
                        projectEvidence = $null
                        projectEvidenceDigest = $null
                        rules = @($Config.rules | ForEach-Object {
                                [ordered]@{ id = [string]$_.id; capability = [string]$_.capability
                                    state = 'pending'; reasonCode = 'not-selected'
                                    observationDigest = $null; observation = $null
                                    priorObservation = $null; writerEligible = $false
                                    identityDigest = $null }
                            })
                    }
                    if ($item.targetRef -cne 'refs/heads/master') {
                        $entry.state = 'skipped'
                        $entry.reasonCode = 'target-out-of-policy'
                        foreach ($ruleResult in $entry.rules) {
                            $ruleResult.state = 'skipped'
                            $ruleResult.reasonCode = $entry.reasonCode
                        }
                        $envelope.counts.skipped++
                    }
                    elseif (-not $selected.Contains($id)) {
                        $envelope.counts.deferred++
                        $envelope.gaps.deferred++
                    }
                    else {
                        $envelope.counts.attempted++
                        try {
                            $before = Assert-IntakeHead (
                                Invoke-IntakeRead $Provider Head @{ pullRequestId = $id } $Config ([ref]$reads) $clock
                            ) $id $Config
                            $entry.targetRef = $before.targetRef
                            $entry.declaration = $before
                            $entry.declarationDigest = Get-IntakeDigest $before
                            foreach ($ruleResult in $entry.rules) {
                                $ruleResult.identityDigest = Get-IntakeRuleIdentity `
                                    $before $ruleResult.id $ruleResult.capability `
                                    $envelope.binding.configDigest
                            }
                            if ($before.status -cne 'active' -or $before.isDraft -or
                                $before.targetRef -cne 'refs/heads/master') {
                                $entry.state = 'unknown'
                                $entry.reasonCode = 'head-left-policy-drift'
                                foreach ($ruleResult in $entry.rules) {
                                    $ruleResult.state = 'unknown'
                                    $ruleResult.reasonCode = 'head-left-policy-drift'
                                }
                                $envelope.counts.error++
                                $envelope.gaps.unknownHeads++
                                $envelope.gaps.unknownRules += $Config.rules.Count
                                $envelope.gaps.drift++
                            }
                            else {
                                foreach ($ruleResult in $entry.rules) {
                                    $ruleResult.priorObservation = Get-IntakePriorObservation `
                                        $previous $id $ruleResult.id $ruleResult.capability `
                                        $entry.declarationDigest $envelope.binding.configDigest
                                }
                                try {
                                $changes = Invoke-IntakeRead $Provider Changes @{
                                    pullRequestId = $id; iterationId = $before.iterationId
                                    sourceCommit = $before.sourceCommit
                                    targetCommit = $before.targetCommit
                                    commonCommit = $before.commonCommit
                                    includeProjectEvidence = ($null -ne $Config['projectEvidence'] -and
                                        $Config.projectEvidence.enabled -ceq $true)
                                    includeEvaluationFiles = ($null -ne $Config['projectEvidence'] -and
                                        $Config.projectEvidence.enabled -ceq $true)
                                } $Config ([ref]$reads) $clock
                                $files = Assert-IntakeNumber $changes.changedFiles changedFiles 0 100000
                                if ($files -gt [int]$Config.limits.maxChangedFiles) { throw 'file-budget' }
                                $lines = $null
                                if ($null -ne $changes['changedLines']) {
                                    $lines = Assert-IntakeNumber $changes.changedLines changedLines 0 1000000
                                    if ($lines -gt [int]$Config.limits.maxChangedLines) { throw 'line-budget' }
                                }
                                $evidence = $null
                                if ($null -ne $lines) {
                                    if ($files -eq 0 -or $lines -eq 0) {
                                        throw 'unsupported-change'
                                    }
                                    if ($null -eq $changes['files']) {
                                        throw 'line-count-unavailable'
                                    }
                                    if ($changes.files -isnot [array] -or
                                        $changes.files.Count -ne $files -or
                                        $changes['baseCommit'] -cne $before.commonCommit) {
                                        throw 'invalid-change'
                                    }
                                    $added = 0
                                    $deleted = 0
                                    $seenPaths = [Collections.Generic.HashSet[string]]::new(
                                        [StringComparer]::Ordinal)
                                    foreach ($file in $changes.files) {
                                        if ($file -isnot [Collections.IDictionary] -or
                                            [string]$file.pathDigest -cnotmatch '^[a-f0-9]{64}$' -or
                                            -not $seenPaths.Add([string]$file.pathDigest) -or
                                            $file.spans -isnot [array] -or
                                            $file.spans.Count -gt [int]$Config.limits.maxChangedLines) {
                                            throw 'invalid-change'
                                        }
                                        $plus = Assert-IntakeNumber $file.addedLines addedLines 0 1000000
                                        $minus = Assert-IntakeNumber $file.deletedLines deletedLines 0 1000000
                                        $newCount = Assert-IntakeNumber $file.newLineCount newLineCount 0 1000000
                                        if ($plus + $minus -eq 0 -or
                                            [string]$file.changeType -cnotin @(
                                                'add', 'edit', 'delete', 'rename') -or
                                            ($file.changeType -ceq 'add' -and $minus -ne 0) -or
                                            ($file.changeType -ceq 'delete' -and
                                                ($plus -ne 0 -or $newCount -ne 0)) -or
                                            ($file.changeType -ceq 'rename' -and
                                                [string]$file.originalPathDigest -cnotmatch
                                                '^[a-f0-9]{64}$')) {
                                            throw 'invalid-change'
                                        }
                                        $covered = 0
                                        $end = 0
                                        foreach ($span in $file.spans) {
                                            if ($span -isnot [Collections.IDictionary]) { throw 'invalid-change' }
                                            $start = Assert-IntakeNumber $span.startLine startLine 1 1000000
                                            $last = Assert-IntakeNumber $span.endLine endLine $start 1000000
                                            if ($start -le $end -or $last -gt $newCount) { throw 'invalid-change' }
                                            $covered += $last - $start + 1
                                            $end = $last
                                        }
                                        if ($covered -ne $plus) { throw 'invalid-change' }
                                        $added += $plus
                                        $deleted += $minus
                                    }
                                    if ($added + $deleted -ne $lines) { throw 'invalid-change' }
                                    $evidence = [ordered]@{
                                        generation = $envelope.generation
                                        declarationDigest = $entry.declarationDigest
                                        configDigest = $envelope.binding.configDigest
                                        baseCommit = $before.commonCommit
                                        changedFiles = $files
                                        changedLines = $lines
                                        addedLines = $added
                                        deletedLines = $deleted
                                        files = $changes.files
                                    }
                                }
                                $discussion = Invoke-IntakeRead $Provider Discussions @{
                                    pullRequestId = $id; iterationId = $before.iterationId
                                } $Config ([ref]$reads) $clock
                                $entry.discussion = Get-IntakeDiscussionCounts $discussion $Config $before
                                if ($null -eq $lines) {
                                    throw 'line-count-unavailable'
                                }
                                if ($evidence) {
                                    $entry.lineEvidence = $evidence
                                    $entry.lineEvidenceDigest = Get-IntakeDigest $evidence
                                }
                                if ($null -ne $Config['projectEvidence'] -and
                                    $Config.projectEvidence.enabled -ceq $true) {
                                    $scope = $changes['projectEvidence']
                                    if ($changes.evaluationFiles -isnot [array]) {
                                        throw 'project-identity-unknown'
                                    }
                                    $nonDeleted = @($changes.files | Where-Object {
                                            $_.changeType -cne 'delete'
                                        })
                                    if ($changes.evaluationFiles.Count -ne
                                        $nonDeleted.Count) {
                                        throw 'project-identity-unknown'
                                    }
                                    foreach ($source in $changes.evaluationFiles) {
                                        if ($source -isnot [Collections.IDictionary] -or
                                            [string]$source.path -cnotmatch
                                                '^/[^?#\x00-\x1f]{1,2048}$' -or
                                            [string]$source.objectId -cnotmatch
                                                '^[a-f0-9]{40}$' -or
                                            @($nonDeleted | Where-Object {
                                                    $_.pathDigest -ceq
                                                        (Get-IntakeDigest $source.path)
                                                }).Count -ne 1) {
                                            throw 'project-identity-unknown'
                                        }
                                    }
                                    Assert-IntakeProjectScope $scope $changes.evaluationFiles `
                                        $before.repositoryId $before.sourceCommit $files
                                    $entry.projectEvidence = [ordered]@{
                                        schemaVersion = 1
                                        kind = 'source-bound-project-scope-summary-v1'
                                        generation = $envelope.generation
                                        declarationDigest = $entry.declarationDigest
                                        repositoryId = $before.repositoryId
                                        sourceCommit = $before.sourceCommit
                                        rootTreeId = $scope.rootTreeId
                                        complete = $scope.complete
                                        files = $scope.files
                                    }
                                    $entry.projectEvidenceDigest =
                                        Get-IntakeDigest $entry.projectEvidence
                                }
                                $entry.rules = @()
                                foreach ($rule in $Config.rules) {
                                    $result = [ordered]@{
                                        id = [string]$rule.id
                                        capability = [string]$rule.capability
                                        state = 'pending'
                                        reasonCode = 'no-evaluator'
                                        observationDigest = $null
                                        observation = $null
                                        priorObservation = Get-IntakePriorObservation `
                                            $previous $id ([string]$rule.id) ([string]$rule.capability) `
                                            $entry.declarationDigest $envelope.binding.configDigest
                                        writerEligible = $false
                                        identityDigest = Get-IntakeRuleIdentity `
                                            $before ([string]$rule.id) ([string]$rule.capability) `
                                            $envelope.binding.configDigest
                                    }
                                    if ($result.priorObservation) {
                                        $result.reasonCode = if ($result.priorObservation.state -ceq 'stale') {
                                            'stale-observation'
                                        } else { 'no-new-observation' }
                                    }
                                    if ($entry.discussion.ambiguous -gt 0) {
                                        $result.state = 'unknown'
                                        $result.reasonCode = 'ambiguous-discussion'
                                    }
                                    $entry.rules += $result
                                }
                                }
                                finally {
                                    $after = Assert-IntakeHead (
                                        Invoke-IntakeRead $Provider Head @{ pullRequestId = $id } $Config ([ref]$reads) $clock
                                    ) $id $Config
                                    if ((Get-IntakeDigest $before) -cne (Get-IntakeDigest $after)) {
                                        throw 'head-drift'
                                    }
                                }
                                $envelope.counts.evaluatedRules += @(
                                    $entry.rules | Where-Object state -eq 'evaluated'
                                ).Count
                                $envelope.gaps.unknownRules += @(
                                    $entry.rules | Where-Object state -eq 'unknown'
                                ).Count
                                $envelope.gaps.staleRules += @(
                                    $entry.rules | Where-Object {
                                        $_.priorObservation -and
                                        $_.priorObservation.state -ceq 'stale' -and
                                        $_.state -cne 'evaluated'
                                    }
                                ).Count
                                $entry.state = 'pending'
                                $entry.reasonCode = 'rules-incomplete'
                            }
                        }
                        catch {
                            $reason = [string]$_.Exception.Message
                            if ($reason -cnotin @('invalid-head', 'head-inconsistent',
                                    'head-drift', 'file-budget',
                                    'line-budget', 'line-count-unavailable',
                                    'account-mismatch',
                                    'change-list-truncated', 'change-page-budget',
                                    'invalid-discussions',
                                    'mutable-discussions', 'comment-budget', 'invalid-evaluator',
                                    'invalid-observation', 'read-budget', 'time-budget',
                                    'invalid-change', 'invalid-item', 'byte-budget',
                                    'diff-budget', 'change-list-truncated', 'unsupported-change',
                                    'project-identity-unknown')) {
                                $reason = 'provider-inaccessible'
                            }
                            $entry.state = 'unknown'
                            $entry.reasonCode = $reason
                            $entry.lineEvidence = $null
                            $entry.lineEvidenceDigest = $null
                            $entry.projectEvidence = $null
                            $entry.projectEvidenceDigest = $null
                            $entry.rules = @($Config.rules | ForEach-Object {
                                    [ordered]@{ id = [string]$_.id; capability = [string]$_.capability
                                        state = 'unknown'; reasonCode = $reason
                                        observationDigest = $null; observation = $null
                                        writerEligible = $false
                                        identityDigest = if ($entry.declaration) {
                                            Get-IntakeRuleIdentity $entry.declaration `
                                                ([string]$_.id) ([string]$_.capability) `
                                                $envelope.binding.configDigest
                                        } else { $null }
                                        priorObservation = if ($entry.declarationDigest) {
                                            Get-IntakePriorObservation $previous $id ([string]$_.id) `
                                                ([string]$_.capability) $entry.declarationDigest `
                                                $envelope.binding.configDigest
                                        } else { $null } }
                                })
                            $envelope.counts.error++
                            $envelope.gaps.unknownHeads++
                            $envelope.gaps.unknownRules += $Config.rules.Count
                            $envelope.gaps.staleRules += @(
                                $entry.rules | Where-Object {
                                    $_.priorObservation -and
                                    $_.priorObservation.state -ceq 'stale'
                                }
                            ).Count
                            if ($reason -ceq 'head-drift') { $envelope.gaps.drift++ }
                        }
                    }
                    [void]$heads.Add($entry)
                }
                $envelope.state = if ($envelope.counts.error -gt 0 -or
                    $envelope.counts.deferred -gt 0 -or
                    $envelope.gaps.unknownRules -gt 0 -or
                    $envelope.gaps.staleRules -gt 0) {
                    'partial'
                } else { 'enumerated' }
        }
        catch {
            $reason = [string]$_.Exception.Message
            if ($reason -cnotin @('account-mismatch', 'invalid-page', 'mutable-page',
                    'page-cursor-collision',
                    'canary-not-in-complete-eligible-inventory',
                    'missing-page', 'page-budget', 'pr-budget', 'read-budget',
                    'time-budget')) { $reason = 'page-inaccessible' }
            $envelope.gaps.enumerationUnknown = 1
            $envelope.counts.error = 1
            $envelope.state = 'unknown'
            [void]$reasons.Add($reason)
        }
        $envelope.reasonCodes = @($reasons)
        if ($envelope.inventory.state -ceq 'unknown') {
            $envelope.inventory.gaps = @($reasons)
        }
        foreach ($head in $heads) {
            $head.sourceCommit = if ($head.declaration) {
                [string]$head.declaration.sourceCommit
            } else { $null }
            $head.targetCommit = if ($head.declaration) {
                [string]$head.declaration.targetCommit
            } else { $null }
            $head.iterationId = if ($head.declaration) {
                [int]$head.declaration.iterationId
            } else { $null }
            $head.status = if ($head.state -ceq 'evaluated') {
                'pending'
            } else { [string]$head.state }
            $head.evaluationStatus = [string]$head.state
            $head.reason = [string]$head.reasonCode
            foreach ($rule in $head.rules) {
                $rule.ruleId = [string]$rule.id
                $rule.capabilityId = [string]$rule.capability
                $rule.status = [string]$rule.state
                $rule.observationDeclarationDigest = if ($rule.state -ceq 'evaluated') {
                    [string]$head.declarationDigest
                } else { $null }
                $rule.observationGeneration = if ($rule.state -ceq 'evaluated') {
                    [string]$envelope.generation
                } else { $null }
                $rule.observationIdentityDigest = if ($rule.state -ceq 'evaluated') {
                    [string]$rule.identityDigest
                } else { $null }
            }
        }
        $envelope.heads = @($heads | Sort-Object { [int]$_['pullRequestId'] })
        if (@($envelope.heads | Where-Object {
                    $_.state -ceq 'unknown' -and -not $_.lineEvidence
                }).Count -gt 0) {
            $envelope.unmetCapabilities = @('changed-line-counts')
        }
        $aggregate = [Collections.Generic.List[object]]::new()
        foreach ($configuredRule in $Config.rules) {
            $ruleHeads = @($envelope.heads | ForEach-Object {
                    @($_.rules | Where-Object {
                            $_.id -ceq [string]$configuredRule.id
                        })
                })
            $ruleGaps = [Collections.Generic.List[string]]::new()
            if ($envelope.inventory.state -cne 'complete') {
                [void]$ruleGaps.Add('inventory-unknown')
            }
            foreach ($ruleResult in $ruleHeads) {
                if ($ruleResult.status -cne 'evaluated' -and
                    $ruleResult.status -cne 'skipped' -and
                    -not [string]::IsNullOrEmpty([string]$ruleResult.reasonCode) -and
                    -not $ruleGaps.Contains([string]$ruleResult.reasonCode)) {
                    [void]$ruleGaps.Add([string]$ruleResult.reasonCode)
                }
                if ($ruleResult.priorObservation -and
                    $ruleResult.priorObservation.state -ceq 'stale' -and
                    $ruleResult.status -cne 'evaluated' -and
                    -not $ruleGaps.Contains('stale-observation')) {
                    [void]$ruleGaps.Add('stale-observation')
                }
            }
            [void]$aggregate.Add([ordered]@{
                    capabilityId = [string]$configuredRule.capability
                    ruleId = [string]$configuredRule.id
                    discovered = $envelope.inventory.discovered
                    eligible = $envelope.inventory.eligible
                    evaluated = @($ruleHeads | Where-Object status -eq 'evaluated').Count
                    skipped = @($ruleHeads | Where-Object status -eq 'skipped').Count
                    error = @($ruleHeads | Where-Object status -eq 'unknown').Count
                    pending = @($ruleHeads | Where-Object status -eq 'pending').Count
                    gaps = @($ruleGaps | Sort-Object -Unique)
                })
        }
        $envelope.rules = @($aggregate)
        $gapCodes = [Collections.Generic.List[string]]::new()
        foreach ($reason in @($envelope.inventory.gaps) + @($reasons)) {
            if ($reason -and -not $gapCodes.Contains([string]$reason)) {
                [void]$gapCodes.Add([string]$reason)
            }
        }
        foreach ($pair in @(
                @('enumerationUnknown', 'inventory-unknown'),
                @('duplicateEntries', 'duplicate-list-entries-reconciled'),
                @('deferred', 'deferred'),
                @('unknownHeads', 'unknown-heads'),
                @('unknownRules', 'unknown-rules'),
                @('staleRules', 'stale-observation'),
                @('drift', 'head-drift')
            )) {
            if ($envelope.gaps[$pair[0]] -gt 0 -and
                -not $gapCodes.Contains([string]$pair[1])) {
                [void]$gapCodes.Add([string]$pair[1])
            }
        }
        if (@($aggregate | Where-Object { $_.pending -gt 0 }).Count -gt 0 -and
            -not $gapCodes.Contains('pending-rules')) {
            [void]$gapCodes.Add('pending-rules')
        }
        if (@($envelope.heads | Where-Object reasonCode -eq 'line-count-unavailable').Count -gt 0 -and
            -not $gapCodes.Contains('line-count-unavailable')) {
            [void]$gapCodes.Add('line-count-unavailable')
        }
        $envelope.gapCounts = $envelope.gaps
        $envelope.gaps = @($gapCodes | Sort-Object -Unique)
        $envelope.observedUtc = [DateTime]::UtcNow.ToString('o')
        $envelope.readCount = $reads
        $serialized = ConvertTo-Json -InputObject $envelope -Depth 32
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($serialized)
        if ($bytes.Length -gt 8388608) { throw 'Intake envelope exceeds its durable size budget.' }
        $generationPath = Join-Path $generationRoot "$($envelope.generation).json"
        $generationTemp = Join-Path $generationRoot (
            "staging-$([guid]::NewGuid().ToString('N')).json")
        try {
            $stream = [IO.File]::Open($generationTemp, 'CreateNew', 'Write', 'None')
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
            [IO.File]::Move($generationTemp, $generationPath)
        }
        finally {
            if (Test-Path -LiteralPath $generationTemp) {
                Remove-Item -LiteralPath $generationTemp -Force
            }
        }
        $temp = Join-Path $root ("cohort-$([guid]::NewGuid().ToString('N')).json")
        try {
            [IO.File]::WriteAllBytes($temp, $bytes)
            [IO.File]::Move($temp, $path, $true)
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        return $envelope
    }
    finally { $lock.Dispose() }
}

function New-ActivePrAzureDevOpsProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Config,
        [string]$AzureCliPath = 'az', [switch]$Bootstrap,
        [scriptblock]$RawGet, [switch]$VerifyReadPrincipal)
    if ($Bootstrap) {
        if ([string]$Config.organization -cnotmatch
                '^https://(?:dev\.azure\.com/[A-Za-z0-9_-]+|[A-Za-z0-9_-]+\.visualstudio\.com)/?$' -or
            [string]$Config.identityResource -cnotmatch
                '^https://[A-Za-z0-9-]+\.vssps\.visualstudio\.com/?$' -or
            [string]$Config.projectName -cnotmatch '^[\w .-]{1,128}$' -or
            [string]$Config.repositoryId -cnotmatch
                '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [string]$Config.repositoryName -cnotmatch '^[A-Za-z0-9._-]{1,128}$') {
            throw 'bootstrap-repository-invalid'
        }
    } else {
        Assert-IntakeConfig $Config
    }
    $org = [string]$Config.organization
    $project = [string]$Config.projectName
    $projectId = [string]$Config.projectId
    $repo = [string]$Config.repositoryId
    $identityResource = [string]$Config.identityResource
    $maxFiles = [int]$Config.limits.maxChangedFiles
    $maxThreads = [int]$Config.limits.maxThreads
    $parseNumber = ${function:Assert-IntakeNumber}
    $readCeiling = [int]$Config.limits.maxReads
    $transportReads = [pscustomobject]@{ Count = 0 }
    $invoke = {
        param([string]$Area, [string]$Resource, [string[]]$Route,
            [string[]]$Query, [DateTime]$Deadline,
            [int]$MaxOutputBytes = 16777216)
        if ($transportReads.Count -ge $readCeiling) { throw 'read-budget' }
        $transportReads.Count++
        $argv = if ($Area -eq 'token') {
            @('account', 'get-access-token', '--resource', $identityResource,
                '--output', 'json', '--only-show-errors')
        } elseif ($Area -eq 'connection') {
            @('rest', '--method', 'get',
                '--url', "$($org.TrimEnd('/'))/_apis/connectionData?api-version=7.1-preview.1",
                '--resource', $identityResource,
                '-o', 'json', '--only-show-errors')
        } elseif ($Area -eq 'devopsConnection') {
            @('devops', 'invoke', '--organization', $org, '--area', 'location',
                '--resource', 'connectionData', '--http-method', 'GET',
                '--api-version', '7.1', '-o', 'json', '--only-show-errors')
        } else {
            @('devops', 'invoke', '--organization', $org, '--area', $Area,
                '--resource', $Resource, '--http-method', 'GET', '--api-version', '7.1',
                '-o', 'json', '--only-show-errors')
        }
        if ($Route.Count) { $argv += @('--route-parameters') + $Route }
        if ($Query.Count) { $argv += @('--query-parameters') + $Query }
        $tool = Get-Command -Name $AzureCliPath -CommandType Application,ExternalScript `
            -ErrorAction Stop | Select-Object -First 1
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $extension = [IO.Path]::GetExtension($tool.Source)
        if ($extension -in @('.cmd', '.bat')) {
            if ($tool.Source -match '[%!"&|<>^]') { throw 'read-inaccessible' }
            $start.FileName = $env:ComSpec
            $quoted = @($argv | ForEach-Object {
                    if ($_ -match '[%!"&|<>^]') { throw 'read-inaccessible' }
                    '"' + $_ + '"'
                })
            $start.Arguments = ('/d /s /c ""{0}" {1}"' -f $tool.Source, ($quoted -join ' '))
        }
        elseif ($extension -eq '.ps1') {
            $start.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
            foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $tool.Source) + $argv) {
                $start.ArgumentList.Add($arg)
            }
        }
        else {
            $start.FileName = $tool.Source
            foreach ($arg in $argv) { $start.ArgumentList.Add($arg) }
        }
        $remaining = [int][Math]::Max(1, ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            if (-not $process.Start()) { throw 'read-inaccessible' }
            $outputBuffer = [byte[]]::new(8192)
            $errorBuffer = [byte[]]::new(4096)
            $output = [IO.MemoryStream]::new()
            try {
                $outputRead = $process.StandardOutput.BaseStream.ReadAsync(
                    $outputBuffer, 0, $outputBuffer.Length)
                $errorRead = $process.StandardError.BaseStream.ReadAsync(
                    $errorBuffer, 0, $errorBuffer.Length)
                $errorBytes = 0
                while ($null -ne $outputRead -or $null -ne $errorRead) {
                    if ([DateTime]::UtcNow -ge $Deadline) {
                        if (-not $process.HasExited) { $process.Kill($true) }
                        throw 'time-budget'
                    }
                    $pending = [Collections.Generic.List[Threading.Tasks.Task]]::new()
                    if ($null -ne $outputRead) { $pending.Add($outputRead) }
                    if ($null -ne $errorRead) { $pending.Add($errorRead) }
                    $remaining = [int][Math]::Max(1,
                        ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
                    $next = [Threading.Tasks.Task]::WhenAny($pending.ToArray())
                    if (-not $next.Wait($remaining)) {
                        if (-not $process.HasExited) { $process.Kill($true) }
                        throw 'time-budget'
                    }
                    $completed = $next.GetAwaiter().GetResult()
                    if ([object]::ReferenceEquals($completed, $outputRead)) {
                        $n = $outputRead.GetAwaiter().GetResult()
                        if ($n -eq 0) { $outputRead = $null }
                        else {
                            if ($output.Length + $n -gt $MaxOutputBytes) {
                                if (-not $process.HasExited) { $process.Kill($true) }
                                throw 'byte-budget'
                            }
                            $output.Write($outputBuffer, 0, $n)
                            $outputRead = $process.StandardOutput.BaseStream.ReadAsync(
                                $outputBuffer, 0, $outputBuffer.Length)
                        }
                    }
                    else {
                        $n = $errorRead.GetAwaiter().GetResult()
                        if ($n -eq 0) { $errorRead = $null }
                        else {
                            $errorBytes += $n
                            if ($errorBytes -gt 65536) {
                                if (-not $process.HasExited) { $process.Kill($true) }
                                throw 'read-budget'
                            }
                            $errorRead = $process.StandardError.BaseStream.ReadAsync(
                                $errorBuffer, 0, $errorBuffer.Length)
                        }
                    }
                }
                $text = [Text.UTF8Encoding]::new($false, $true).GetString(
                    $output.ToArray())
            }
            finally { $output.Dispose() }
            $remaining = [int][Math]::Max(1,
                ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $process.WaitForExit($remaining)) {
                if (-not $process.HasExited) { $process.Kill($true) }
                throw 'time-budget'
            }
            if ($process.ExitCode -ne 0) { throw 'read-inaccessible' }
        }
        finally { $process.Dispose() }
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'read-inaccessible' }
        try { return ($text | ConvertFrom-Json -AsHashtable -Depth 32) }
        catch { throw 'read-inaccessible' }
    }.GetNewClosure()
    $rawCredential = [pscustomobject]@{ Token = $null }
    $rawIdentityVerified = $false
    if ($null -eq $RawGet) {
        $RawGet = {
            param([string]$Operation, [Collections.IDictionary]$RawRequest)
            $deadline = [DateTime]$RawRequest.deadline
            if ($null -eq $rawCredential.Token) {
                $credential = & $invoke 'token' 'accessToken' @() @() $deadline 16384
                if ([string]$credential.accessToken -cnotmatch
                        '^[A-Za-z0-9._~+/=-]{100,8192}$' -or
                    [string]$credential.tokenType -ine 'Bearer') {
                    throw 'read-inaccessible'
                }
                $rawCredential.Token = [string]$credential.accessToken
            }
            $itemProject = $project
            $itemRepo = $repo
            if ($Operation -ceq 'Item' -and
                $null -ne $RawRequest['projectName']) {
                $itemProject = [string]$RawRequest.projectName
                $itemRepo = [string]$RawRequest.repositoryId
                if ($itemProject -cnotmatch '^[\w .-]{1,128}$' -or
                    $itemRepo -cnotmatch
                        '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') {
                    throw 'read-inaccessible'
                }
            }
            $base = "$($org.TrimEnd('/'))/$([Uri]::EscapeDataString($itemProject))" +
                "/_apis/git/repositories/$itemRepo/items"
            $url = if ($Operation -ceq 'Identity') {
                "$($org.TrimEnd('/'))/_apis/connectionData?api-version=7.1-preview.1"
            } elseif ($Operation -ceq 'Item' -and
                [string]$RawRequest.path -cmatch '^/[^?#\\\x00-\x1f]{1,2048}$' -and
                [string]$RawRequest.commit -cmatch '^[a-fA-F0-9]{40}$') {
                "$base`?path=$([Uri]::EscapeDataString([string]$RawRequest.path))" +
                    "&versionDescriptor.version=$($RawRequest.commit)" +
                    '&versionDescriptor.versionType=commit&api-version=7.1'
            } elseif ($Operation -ceq 'Commit' -and
                [string]$RawRequest.commit -cmatch '^[a-fA-F0-9]{40}$') {
                "$($org.TrimEnd('/'))/$([Uri]::EscapeDataString($project))" +
                    "/_apis/git/repositories/$repo/commits/$($RawRequest.commit)?api-version=7.1"
            } elseif ($Operation -ceq 'Tree' -and
                [string]$RawRequest.treeId -cmatch '^[a-fA-F0-9]{40}$') {
                "$($org.TrimEnd('/'))/$([Uri]::EscapeDataString($project))" +
                    "/_apis/git/repositories/$repo/trees/$($RawRequest.treeId)" +
                    '?recursive=false&api-version=7.1'
            } else { throw 'read-inaccessible' }
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler)
            $request = [Net.Http.HttpRequestMessage]::new(
                [Net.Http.HttpMethod]::Get, $url)
            $request.Headers.Authorization =
                [Net.Http.Headers.AuthenticationHeaderValue]::new(
                    'Bearer', $rawCredential.Token)
            $request.Headers.Accept.ParseAdd($(if ($Operation -ceq 'Item') {
                        'application/octet-stream'
                    } else { 'application/json' }))
            $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $cancel = [Threading.CancellationTokenSource]::new($remaining)
            try {
                $response = $client.SendAsync($request,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                    $cancel.Token).GetAwaiter().GetResult()
                try {
                    if (-not $response.IsSuccessStatusCode) {
                        throw 'read-inaccessible'
                    }
                    $limit = if ($Operation -ceq 'Item') {
                        [int]$RawRequest.maxBytes
                    } else { 65536 }
                    if ($null -ne $response.Content.Headers.ContentLength -and
                        $response.Content.Headers.ContentLength -gt $limit) {
                        throw 'byte-budget'
                    }
                    $stream = $response.Content.ReadAsStreamAsync(
                        $cancel.Token).GetAwaiter().GetResult()
                    $buffer = [byte[]]::new(8192)
                    $output = [IO.MemoryStream]::new()
                    try {
                        while (($n = $stream.ReadAsync($buffer, 0, $buffer.Length,
                                    $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
                            if ($output.Length + $n -gt $limit) { throw 'byte-budget' }
                            $output.Write($buffer, 0, $n)
                        }
                        $bytes = $output.ToArray()
                    }
                    finally { $output.Dispose() }
                    if ($Operation -ceq 'Item') { return @{ bytes = $bytes } }
                    try {
                        $identity = [Text.UTF8Encoding]::new($false, $true).GetString(
                            $bytes) | ConvertFrom-Json -AsHashtable -Depth 8
                    }
                    catch { throw 'read-inaccessible' }
                    if ($Operation -cne 'Identity') { return $identity }
                    return @{ id = $identity.authenticatedUser.id
                        descriptor = $identity.authenticatedUser.subjectDescriptor
                        uniqueName = $identity.authenticatedUser.uniqueName }
                }
                finally { $response.Dispose() }
            }
            catch [OperationCanceledException] { throw 'time-budget' }
            catch [Net.Http.HttpRequestException] { throw 'read-inaccessible' }
            finally {
                $cancel.Dispose()
                $request.Dispose()
                $client.Dispose()
                $handler.Dispose()
            }
        }.GetNewClosure()
    }
    $assertNumber = ${function:Assert-IntakeNumber}
    $assertBlob = ${function:Assert-IntakeBlob}
    $assertRawBlob = ${function:Assert-IntakeRawBlob}
    $sourceTree = ${function:Get-IntakeSourceTree}
    $projectGraph = Get-Command Get-TestProjectGraphEvidence -ErrorAction Stop
    $lineDelta = ${function:Get-IntakeLineDelta}
    $digest = ${function:Get-IntakeDigest}
    $principal = [pscustomobject]@{ Verified = $false }
    $handler = {
        param([string]$Operation, [Collections.IDictionary]$Request)
        if ($Bootstrap -and $Operation -cnotin @('Identity', 'Metadata')) {
            throw 'bootstrap-read-not-allowed'
        }
        if ($VerifyReadPrincipal -and $Operation -cne 'Identity' -and
            -not $principal.Verified) { throw 'account-mismatch' }
        $budget = if ($null -ne $Request['timeoutMilliseconds']) {
            [int]$Request.timeoutMilliseconds
        } else { [int]$Config.limits.maxSeconds * 1000 }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($budget)
        switch -CaseSensitive ($Operation) {
            Identity {
                $principal.Verified = $false
                $r = & $invoke 'connection' 'connectionData' @() @() $deadline
                $user = $r.authenticatedUser
                $name = [string]$user.uniqueName
                if (-not $name -and
                    [string]$user.descriptor -cmatch '\\(?<upn>[^\\\s]+@[^\\\s]+)$') {
                    $name = $Matches.upn
                }
                if ($VerifyReadPrincipal) {
                    $other = & $invoke 'devopsConnection' 'connectionData' @() @() $deadline
                    $patUser = $other.authenticatedUser
                    $rawUser = if ($Bootstrap) { $null } else {
                        & $RawGet 'Identity' @{ deadline = $deadline }
                    }
                    if ([string]$user.id -cnotmatch
                            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
                        [string]$user.subjectDescriptor -cnotmatch '^\S{1,512}$' -or
                        [string]$name -cnotmatch '^[^@\s]+@[^@\s]+$' -or
                        [string]$patUser.id -ine [string]$user.id -or
                        [string]$patUser.subjectDescriptor -cne
                            [string]$user.subjectDescriptor -or
                        [string]$patUser.uniqueName -ine $name -or
                        (-not $Bootstrap -and
                            ($rawUser -isnot [Collections.IDictionary] -or
                                [string]$rawUser.id -ine [string]$user.id -or
                                [string]$rawUser.descriptor -cne
                                    [string]$user.subjectDescriptor -or
                                [string]$rawUser.uniqueName -ine $name))) {
                        throw 'account-mismatch'
                    }
                    $principal.Verified = $true
                }
                return @{ id = $user.id; descriptor = $user.subjectDescriptor
                    uniqueName = $name }
            }
            Metadata {
                $name = [string]$Request.repositoryName
                if ($name -cnotmatch '^[A-Za-z0-9._-]{1,128}$') {
                    throw 'repository-mismatch'
                }
                $p = & $invoke 'core' 'projects' @("projectId=$project") @() $deadline
                $r = & $invoke 'git' 'repositories' @(
                    "project=$project", "repositoryId=$repo") @() $deadline
                if ([string]$p.id -cnotmatch
                        '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
                    ($projectId -and [string]$p.id -ine $projectId) -or
                    [string]$p.name -cne $project -or
                    [string]$r.id -ine $repo -or
                    [string]$r.name -cne $name -or
                    [string]$r.project.id -ine [string]$p.id) {
                    throw 'repository-mismatch'
                }
                return @{ projectId = $p.id; projectName = $p.name
                    repositoryId = $r.id; repositoryName = $r.name }
            }
            RuleSource {
                $sourceProject = [string]$Request.projectName
                $sourceRepo = [string]$Request.repositoryId
                $commit = [string]$Request.commit
                $path = [string]$Request.path
                if ($sourceProject -cnotmatch '^[\w .-]{1,128}$' -or
                    $sourceRepo -cnotmatch
                        '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
                    $commit -cnotmatch '^[a-f0-9]{40}$' -or
                    $path -cnotin @(
                        '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md',
                        '/src/DevPilot.OwnerCapability/Policy/test-class-coverage.v1.txt',
                        '/src/DevPilot.OwnerCapability/Policy/redundant-method-coverage.v1.txt',
                        '/src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
                    )) {
                    throw 'rule-source-invalid'
                }
                $metadata = & $invoke 'git' 'repositories' @(
                    "project=$sourceProject", "repositoryId=$sourceRepo") @() $deadline
                if ([string]$metadata.id -ine $sourceRepo -or
                    [string]$metadata.project.id -cnotmatch
                        '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
                    [string]$metadata.project.name -cne $sourceProject -or
                    [string]$metadata.name -cne [string]$Request.repositoryName) {
                    throw 'rule-source-mismatch'
                }
                $item = & $invoke 'git' 'items' @(
                    "project=$sourceProject", "repositoryId=$sourceRepo") @(
                    "path=$path", "versionDescriptor.version=$commit",
                    'versionDescriptor.versionType=commit', 'includeContent=false',
                    'includeContentMetadata=true') $deadline 1048576
                if ([string]$item.path -cne $path -or
                    [string]$item.gitObjectType -cne 'blob' -or
                    $item['isFolder'] -eq $true -or
                    $item['isSymLink'] -eq $true -or
                    [string]$item.objectId -cnotmatch '^[a-fA-F0-9]{40}$') {
                    throw 'invalid-item'
                }
                $raw = & $RawGet 'Item' @{
                    projectName = $sourceProject; repositoryId = $sourceRepo
                    commit = $commit; path = $path; maxBytes = 262144
                    deadline = $deadline
                }
                if ($raw -isnot [Collections.IDictionary] -or
                    $raw.bytes -isnot [byte[]]) { throw 'invalid-item' }
                $blob = & $assertRawBlob $raw.bytes ([string]$item.objectId) 262144
                return @{ content = $blob.text; repositoryId = $metadata.id
                    repositoryName = $metadata.name; projectName = $metadata.project.name
                    commit = $commit; path = $path }
            }
            ListPage {
                $query = @('searchCriteria.status=active',
                    "searchCriteria.repositoryId=$repo",
                    "`$skip=$($Request.skip)", "`$top=$($Request.top)")
                if ($null -ne $Config['pagination']) {
                    if ($Request.skip -ne 0 -or $Request.top -gt 201 -or
                        [string]$Request.maxTime -cnotmatch
                            '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z$') {
                        throw 'invalid-page'
                    }
                    $query += 'searchCriteria.queryTimeRangeType=created'
                    $query += "searchCriteria.maxTime=$($Request.maxTime)"
                }
                $r = & $invoke 'git' 'pullRequests' @(
                    "project=$project", "repositoryId=$repo") $query $deadline
                if ($null -ne $Config['pagination'] -and
                    ($r['value'] -isnot [array] -or
                        $null -eq $r['count'])) {
                    throw 'invalid-page'
                }
                $items = @($r.value | ForEach-Object {
                        if ([string]$_.repository.id -ine $repo -or
                            [string]$_.repository.project.id -ine $projectId) {
                            throw 'repository-mismatch'
                        }
                        @{ pullRequestId = $_.pullRequestId; status = $_.status
                            isDraft = $_.isDraft; targetRef = $_.targetRefName
                            creationDate = if ($null -ne $_.creationDate) {
                                ([DateTimeOffset]$_.creationDate).UtcDateTime.ToString('o')
                            } else { $null } }
                    })
                if ($null -ne $r['count'] -and $r['count'] -ne $items.Count) {
                    throw 'page-count-mismatch'
                }
                return @{ items = $items; count = $items.Count }
            }
            Head {
                $id = [int]$Request.pullRequestId
                if ($null -ne $Request['remainingReads'] -and
                    $Request.remainingReads -lt 3) { throw 'read-budget' }
                $r = & $invoke 'git' 'pullRequests' @(
                    "project=$project", "repositoryId=$repo", "pullRequestId=$id") @() $deadline
                $iterations = & $invoke 'git' 'pullRequestIterations' @(
                    "project=$project", "repositoryId=$repo", "pullRequestId=$id") @() $deadline
                $list = @($iterations.value)
                if ($list.Count -eq 0 -or $list.Count -gt 200) { throw 'iteration-inaccessible' }
                $last = $list | Sort-Object { [int]$_.id } | Select-Object -Last 1
                if (($null -ne $r['lastMergeSourceCommit'] -and
                        [string]$r.lastMergeSourceCommit.commitId -ine
                        [string]$last.sourceRefCommit.commitId) -or
                    ($null -ne $r['lastMergeTargetCommit'] -and
                        [string]$r.lastMergeTargetCommit.commitId -ine
                        [string]$last.targetRefCommit.commitId)) {
                    throw 'head-inconsistent'
                }
                foreach ($pair in @(
                        @([string]$r.sourceRefName, [string]$last.sourceRefCommit.commitId),
                        @([string]$r.targetRefName, [string]$last.targetRefCommit.commitId)
                    )) {
                    if ($pair[0] -cnotmatch '^refs/heads/[^~^:?*\[\\]+$' -or
                        $pair[1] -cnotmatch '^[a-fA-F0-9]{40}$') { throw 'head-inconsistent' }
                    $refs = & $invoke 'git' 'refs' @(
                        "project=$project", "repositoryId=$repo") @(
                        "filter=$($pair[0].Substring(5))", '$top=100') $deadline
                    if ($refs['value'] -isnot [array]) { throw 'head-inconsistent' }
                    $exact = @($refs.value | Where-Object { $_.name -ceq $pair[0] })
                    if ($exact.Count -ne 1 -or
                        [string]$exact[0].objectId -ine $pair[1]) {
                        throw 'head-inconsistent'
                    }
                }
                return @{ pullRequestId = $r.pullRequestId
                    repositoryId = $r.repository.id; projectId = $r.repository.project.id
                    status = $r.status; isDraft = $r.isDraft
                    sourceRef = $r.sourceRefName; targetRef = $r.targetRefName
                    sourceCommit = $last.sourceRefCommit.commitId
                    targetCommit = $last.targetRefCommit.commitId
                    commonCommit = $last.commonRefCommit.commitId; iterationId = $last.id
                    readCount = 3 }
            }
            Changes {
                $id = [int]$Request.pullRequestId
                $iteration = [int]$Request.iterationId
                $remaining = if ($null -eq $Request['remainingReads']) {
                    [int]$Config.limits.maxReads
                } else {
                    & $assertNumber $Request.remainingReads remainingReads 0 30000
                }
                $counter = @{ used = 0 }
                $rawEnabled = $Request['includeProjectEvidence'] -ceq $true
                $rawTransport = $RawGet
                $rawVerifier = $assertRawBlob
                $graphLimits = $Config.limits
                $graphCommit = [string]$Request.sourceCommit
                $readRaw = {
                    param([string]$Operation, [Collections.IDictionary]$RawRequest)
                    if ($counter.used -ge $remaining) { throw 'read-budget' }
                    $counter.used++
                    $RawRequest.deadline = $deadline
                    $result = & $rawTransport $Operation $RawRequest
                    if ($result -isnot [Collections.IDictionary]) {
                        throw 'read-inaccessible'
                    }
                    return $result
                }.GetNewClosure()
                if ($rawEnabled -and -not $rawIdentityVerified) {
                    $identity = & $readRaw 'Identity' @{}
                    if ([string]$identity.id -ine [string]$Config.expectedAccount.id -or
                        [string]$identity.descriptor -cne
                            [string]$Config.expectedAccount.descriptor -or
                        [string]$identity.uniqueName -ine
                            [string]$Config.expectedAccount.uniqueName) {
                        throw 'account-mismatch'
                    }
                    $rawIdentityVerified = $true
                }
                $read = {
                    param($Resource, $Route, $Query, [int]$Cap)
                    if ($counter.used -ge $remaining) { throw 'read-budget' }
                    $counter.used++
                    return & $invoke 'git' $Resource $Route $Query $deadline $Cap
                }
                $route = @("project=$project", "repositoryId=$repo")
                $changeRoute = $route + @("pullRequestId=$id", "iterationId=$iteration")
                $skip = 0
                $seenChanges = [Collections.Generic.HashSet[int]]::new()
                $entries = [Collections.Generic.List[object]]::new()
                $declaredTotal = $null
                $pageSize = [Math]::Min(100, $maxFiles + 1)
                $complete = $false
                for ($page = 0; $page -lt [int]$Config.limits.maxPages; $page++) {
                    $r = & $read 'pullRequestIterationChanges' $changeRoute @(
                        "`$top=$pageSize", "`$skip=$skip", '$compareTo=0') 16777216
                    if ($r['changeEntries'] -isnot [array]) {
                        throw 'change-list-truncated'
                    }
                    $pageEntries = @($r.changeEntries)
                    if ($pageEntries.Count -gt $pageSize) { throw 'change-list-truncated' }
                    if ($null -ne $r['count'] -and
                        (& $parseNumber $r['count'] changeCount 0 $pageSize) -ne
                        $pageEntries.Count) { throw 'change-list-truncated' }
                    if ($null -ne $r['totalCount']) {
                        $total = & $parseNumber $r['totalCount'] totalChanges 0 100000
                        if ($null -ne $declaredTotal -and $total -ne $declaredTotal) {
                            throw 'change-list-truncated'
                        }
                        if ($total -gt $maxFiles) { throw 'file-budget' }
                        $declaredTotal = $total
                    }
                    if ($pageEntries.Count -eq 0) {
                        if (($null -ne $declaredTotal -and
                                $seenChanges.Count -ne $declaredTotal) -or
                            ($null -ne $r['nextSkip'] -and
                                (& $parseNumber $r['nextSkip'] nextSkip 0 100000) -gt
                                $skip)) {
                            throw 'change-list-truncated'
                        }
                        $complete = $true
                        break
                    }
                    foreach ($entry in $pageEntries) {
                        if ($entry -isnot [Collections.IDictionary] -or
                            $null -eq $entry['changeTrackingId']) {
                            throw 'change-list-truncated'
                        }
                        $trackingId = & $parseNumber $entry['changeTrackingId'] `
                            changeTrackingId 1 ([int]::MaxValue)
                        if (-not $seenChanges.Add($trackingId)) {
                            throw 'change-list-truncated'
                        }
                        $entries.Add($entry)
                    }
                    if ($seenChanges.Count -gt $maxFiles) { throw 'file-budget' }
                    $next = $skip + $pageEntries.Count
                    if ($null -ne $r['nextSkip']) {
                        $nextSkip = & $parseNumber $r['nextSkip'] nextSkip 0 100000
                        if ($nextSkip -ne 0 -and $nextSkip -ne $next) {
                            throw 'change-list-truncated'
                        }
                    }
                    if ($null -ne $declaredTotal -and $seenChanges.Count -gt
                        $declaredTotal) { throw 'change-list-truncated' }
                    $skip = $next
                }
                if (-not $complete) { throw 'change-page-budget' }
                if ($null -eq $Request['sourceCommit'] -and
                    $null -eq $Request['targetCommit'] -and
                    $null -eq $Request['commonCommit']) {
                    return @{ changedFiles = $seenChanges.Count; changedLines = $null
                        readCount = $counter.used }
                }
                foreach ($commit in @('sourceCommit', 'targetCommit', 'commonCommit')) {
                    if ([string]$Request[$commit] -cnotmatch '^[a-fA-F0-9]{40}$') {
                        throw 'invalid-change'
                    }
                }
                if ($entries.Count -eq 0) { throw 'unsupported-change' }
                $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $results = [Collections.Generic.List[object]]::new()
                $evaluationFiles = [Collections.Generic.List[object]]::new()
                $totalBytes = 0
                $totalLines = 0
                $cellsLeft = [int]$Config.limits.maxDiffCells
                foreach ($change in $entries) {
                    if ($change -isnot [Collections.IDictionary] -or
                        $change.item -isnot [Collections.IDictionary] -or
                        [string]$change.item.path -cnotmatch '^/[^?#\x00-\x1f]{1,2048}$' -or
                        -not $seen.Add([string]$change.item.path)) {
                        throw 'invalid-change'
                    }
                    $path = [string]$change.item.path
                    $kind = [string]$change.changeType
                    if ($kind -cnotin @('add', 'edit', 'delete', 'rename')) {
                        throw 'unsupported-change'
                    }
                    if ($kind -ne 'delete' -and
                        [string]$change.item.objectId -cnotmatch '^[a-fA-F0-9]{40}$') {
                        throw 'invalid-change'
                    }
                    if ($kind -eq 'rename' -and
                        ([string]$change.originalPath -cnotmatch '^/[^?#\x00-\x1f]{1,2048}$' -or
                            [string]$change.originalPath -ceq $path)) {
                        throw 'unsupported-change'
                    }
                    $oldPath = if ($kind -eq 'rename') { [string]$change.originalPath } else { $path }
                    $old = ''
                    $new = ''
                    $cap = [Math]::Min([int]$Config.limits.maxFileBytes,
                        [int]$Config.limits.maxTotalBytes - $totalBytes)
                    if ($cap -lt 1) { throw 'byte-budget' }
                    if ($kind -ne 'add') {
                        $item = & $read 'items' $route @(
                            "path=$oldPath", "versionDescriptor.version=$($Request.commonCommit)",
                            'versionDescriptor.versionType=commit',
                            "includeContent=$(!$rawEnabled)",
                            'includeContentMetadata=true') ($cap * 6 + 65536)
                        $blob = if ($rawEnabled) {
                            if ([string]$item.path -cne $oldPath -or
                                [string]$item.gitObjectType -cne 'blob' -or
                                [string]$item.objectId -cnotmatch '^[a-fA-F0-9]{40}$') {
                                throw 'invalid-item'
                            }
                            $raw = & $readRaw 'Item' @{ path = $oldPath
                                commit = [string]$Request.commonCommit; maxBytes = $cap }
                            & $assertRawBlob $raw.bytes `
                                ([string]$item.objectId) $cap
                        } else {
                            & $assertBlob $item $oldPath ([string]$item.objectId) $cap
                        }
                        if ($change.item['originalObjectId'] -and
                            [string]$change.item.originalObjectId -ine [string]$item.objectId) {
                            throw 'invalid-item'
                        }
                        $old = $blob.text
                        $totalBytes += $blob.bytes
                    }
                    if ($kind -ne 'delete') {
                        $cap = [Math]::Min([int]$Config.limits.maxFileBytes,
                            [int]$Config.limits.maxTotalBytes - $totalBytes)
                        if ($cap -lt 1) { throw 'byte-budget' }
                        $blob = if ($rawEnabled) {
                            $raw = & $readRaw 'Item' @{ path = $path
                                commit = [string]$Request.sourceCommit; maxBytes = $cap }
                            & $assertRawBlob $raw.bytes `
                                ([string]$change.item.objectId) $cap
                        } else {
                            $item = & $read 'items' $route @(
                                "path=$path",
                                "versionDescriptor.version=$($Request.sourceCommit)",
                                'versionDescriptor.versionType=commit',
                                'includeContent=true', 'includeContentMetadata=true') `
                                ($cap * 6 + 65536)
                            & $assertBlob $item $path ([string]$change.item.objectId) $cap
                        }
                        $new = $blob.text
                        $totalBytes += $blob.bytes
                    }
                    if ($old.StartsWith("version https://git-lfs.github.com/spec/v1`n") -or
                        $new.StartsWith("version https://git-lfs.github.com/spec/v1`n")) {
                        throw 'unsupported-change'
                    }
                    $delta = & $lineDelta $old $new $cellsLeft `
                        ([int]$Config.limits.maxChangedLines * 2) $deadline
                    $cellsLeft -= $delta.cells
                    $totalLines += $delta.addedLines + $delta.deletedLines
                    if ($totalLines -gt [int]$Config.limits.maxChangedLines) {
                        throw 'line-budget'
                    }
                    if ($delta.addedLines + $delta.deletedLines -eq 0) {
                        throw 'unsupported-change'
                    }
                    $results.Add([ordered]@{
                            pathDigest = & $digest $path
                            originalPathDigest = if ($kind -eq 'rename') {
                                & $digest $oldPath
                            } else { $null }
                            changeType = $kind
                            addedLines = $delta.addedLines
                            deletedLines = $delta.deletedLines
                            newLineCount = $delta.newLineCount
                            spans = @($delta.spans)
                        })
                    if (($Request['includeEvaluationFiles'] -ceq $true -or
                            $Request['includeProjectEvidence'] -ceq $true) -and
                        $kind -ne 'delete') {
                        $evaluationFiles.Add(@{ path = $path; content = $new
                            objectId = ([string]$change.item.objectId).ToLowerInvariant() })
                    }
                }
                $scopeSummary = $null
                if ($Request['includeProjectEvidence'] -ceq $true) {
                    $sourceFiles = @($evaluationFiles.ToArray() | Where-Object {
                            $_.path -cmatch '\.cs$'
                        })
                    $scopeReceipts = [Collections.Generic.List[object]]::new()
                    $tree = $null
                    if ($sourceFiles.Count -gt 0) {
                        try {
                            $readGraph = {
                                param([string]$Resource, [string[]]$GraphRoute,
                                    [string[]]$Query, [int]$Cap)
                                $name = if ($Resource -ceq 'commits') {
                                    'commitId'
                                } elseif ($Resource -ceq 'trees') {
                                    'sha1'
                                } else { throw 'project-identity-unknown' }
                                $matching = @($GraphRoute | Where-Object {
                                        $_ -clike "$name=*"
                                    })
                                if ($matching.Count -ne 1) {
                                    throw 'project-identity-unknown'
                                }
                                $id = ($matching[0] -split '=', 2)[1]
                                if ([string]$id -cnotmatch '^[a-fA-F0-9]{40}$') {
                                    throw 'project-identity-unknown'
                                }
                                if ($Resource -ceq 'commits') {
                                    return & $readRaw 'Commit' @{
                                        commit = $id; maxBytes = $Cap }
                                }
                                return & $readRaw 'Tree' @{
                                    treeId = $id; maxBytes = $Cap }
                            }.GetNewClosure()
                            $tree = & $sourceTree $readGraph $route `
                                ([string]$Request.sourceCommit) `
                                $(if ($null -ne $Config['projectEvidence']) {
                                        [int]$Config.projectEvidence.maxTreeEntries
                                    } else { 4096 })
                        }
                        catch {
                            if ($_.Exception.Message -cnotin @(
                                    'project-identity-unknown', 'read-inaccessible',
                                    'byte-budget', 'read-budget', 'time-budget')) { throw }
                        }
                    }
                    $graphBudget = @{ used = 0 }
                    $graphCache = @{}
                    foreach ($source in $sourceFiles) {
                        $receipt = [ordered]@{
                            pathDigest = & $digest $source.path
                            objectId = $source.objectId
                            status = 'unknown'
                            attestationDigest = $null
                        }
                        if ($null -ne $tree) {
                            $readGraphItem = {
                                param([string]$ItemPath, [string]$ItemId)
                                $key = "$ItemPath|$ItemId"
                                if ($graphCache.ContainsKey($key)) {
                                    return $graphCache[$key]
                                }
                                $cap = [Math]::Min([int]$graphLimits.maxFileBytes,
                                    [int]$graphLimits.maxTotalBytes - $graphBudget.used)
                                if ($cap -lt 1) { throw 'byte-budget' }
                                $raw = & $readRaw 'Item' @{ path = $ItemPath
                                    commit = $graphCommit
                                    maxBytes = $cap }
                                $blob = & $rawVerifier $raw.bytes $ItemId $cap
                                $graphBudget.used += $blob.bytes
                                $graphCache[$key] = $blob.text
                                return $blob.text
                            }.GetNewClosure()
                            try {
                                $proof = & $projectGraph `
                                    -RepositoryId $repo `
                                    -SourceCommit ([string]$Request.sourceCommit) `
                                    -Path $source.path -ObjectId $source.objectId `
                                    -Entries $tree.entries -ReadItem $readGraphItem `
                                    -MaxProjects $(if ($null -ne $Config['projectEvidence']) {
                                            [int]$Config.projectEvidence.maxProjects
                                        } else { 32 }) `
                                    -MaxFiles $(if ($null -ne $Config['projectEvidence']) {
                                            [int]$Config.projectEvidence.maxTreeEntries
                                        } else { 4096 })
                                $source.projectEvidence = $proof
                                $receipt.status = 'complete'
                                $receipt.attestationDigest = & $digest $proof
                            }
                            catch {
                                if ($_.Exception.Message -cnotin @(
                                        'project-identity-unknown', 'invalid-item',
                                        'read-inaccessible', 'byte-budget', 'read-budget',
                                        'time-budget', 'unsupported-change')) { throw }
                            }
                        }
                        $scopeReceipts.Add($receipt)
                    }
                    $scopeSummary = [ordered]@{
                        schemaVersion = 1
                        kind = 'source-bound-project-scope-summary-v1'
                        repositoryId = $repo.ToLowerInvariant()
                        sourceCommit = ([string]$Request.sourceCommit).ToLowerInvariant()
                        rootTreeId = if ($null -ne $tree) { $tree.rootTreeId } else { $null }
                        complete = (@($scopeReceipts | Where-Object status -NE 'complete').Count -eq 0)
                        files = @($scopeReceipts.ToArray())
                    }
                }
                $answer = @{ changedFiles = $entries.Count; changedLines = $totalLines
                    baseCommit = ([string]$Request.commonCommit).ToLowerInvariant()
                    files = @($results.ToArray()); readCount = $counter.used }
                if ($Request['includeEvaluationFiles'] -ceq $true) {
                    $answer.evaluationFiles = @($evaluationFiles.ToArray())
                }
                if ($null -ne $scopeSummary) { $answer.projectEvidence = $scopeSummary }
                return $answer
            }
            Discussions {
                $id = [int]$Request.pullRequestId
                $r = & $invoke 'git' 'pullRequestThreads' @(
                    "project=$project", "repositoryId=$repo", "pullRequestId=$id") @() $deadline
                if ($r['value'] -isnot [array] -or $null -eq $r['count'] -or
                    $null -ne $r['continuationToken'] -or $null -ne $r['nextLink'] -or
                    $r.value.Count -gt $maxThreads -or
                    (& $parseNumber $r.count threadCount 0 $maxThreads) -ne
                        $r.value.Count) {
                    throw 'discussion-list-truncated'
                }
                return @{ threads = @($r.value); count = $r.value.Count }
            }
            default { throw 'unsupported-operation' }
        }
    }.GetNewClosure()
    return $handler
}

Export-ModuleMember -Function Invoke-ActivePrIntake, New-ActivePrAzureDevOpsProvider, Get-ActivePrDiscussionCounts, Get-ActivePrDiscussionSnapshot
