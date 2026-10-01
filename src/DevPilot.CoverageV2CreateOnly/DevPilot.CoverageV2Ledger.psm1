#requires -Version 7.0
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot `
        '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')

$script:LedgerRepositoryRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..'))
$script:LedgerRules = @(
    'bpm-test-class-coverage@2',
    'bpm-redundant-method-coverage@2'
)

function Assert-CoverageV2LedgerInput {
    param([string]$RepositoryId, [int]$PullRequestId,
        [string]$RuleId, [string]$RunId, [string]$Marker,
        [string]$FindingDigest, [byte[]]$Key)
    if ($RepositoryId -cnotmatch
            '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        $PullRequestId -lt 1 -or
        $RuleId -cnotin $script:LedgerRules -or
        $RunId -cnotmatch '^[A-Za-z0-9-]{1,80}$' -or
        $Marker -cnotmatch '^[a-f0-9]{64}$' -or
        $FindingDigest -cnotmatch '^[a-f0-9]{64}$' -or
        $null -eq $Key -or $Key.Length -ne 32) {
        throw 'coverage-v2-ledger-input-invalid'
    }
}

function Get-CoverageV2LedgerHmac {
    param([Collections.IDictionary]$Unsigned, [byte[]]$Key)
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return [Convert]::ToHexString($hmac.ComputeHash(
                [Text.Encoding]::UTF8.GetBytes(
                    (ConvertTo-AgentCanonicalJson -InputObject $Unsigned))
            )).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Assert-CoverageV2LedgerFixtureRoot {
    param([string]$Root)
    if (-not [IO.Path]::IsPathFullyQualified($Root) -or
        (Split-Path -Leaf $Root) -cnotmatch
            '^\.coverage-v2-ledger-test-[a-f0-9]{32}$' -or
        -not (Test-AgentPathWithin -Path $Root `
            -Root $script:LedgerRepositoryRoot) -or
        -not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw 'coverage-v2-ledger-fixture-root-invalid'
    }
    $item = Get-Item -LiteralPath $Root -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'coverage-v2-ledger-fixture-root-invalid'
    }
}

function Assert-CoverageV2LedgerFixtureDirectory {
    param([string]$Root, [string]$Path)
    if (-not (Test-AgentPathWithin -Path $Path -Root $Root) -or
        -not (Test-Path -LiteralPath $Path -PathType Container) -or
        ((Get-Item -LiteralPath $Path -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'coverage-v2-ledger-fixture-directory-invalid'
    }
}

function Get-CoverageV2LedgerBucket {
    param([string]$Root, [string]$RepositoryId, [int]$PullRequestId,
        [string]$RuleId)
    $rule = if ($RuleId -ceq $script:LedgerRules[0]) {
        'test-class'
    } else { 'redundant-method' }
    $prKey = "$RepositoryId-$PullRequestId"
    return [ordered]@{
        prKey = $prKey
        path = Join-Path (Join-Path $Root 'journal') "$prKey-$rule"
        lockPath = Join-Path (Join-Path $Root 'locks') 'global.lock'
    }
}

function Read-CoverageV2LedgerHistory {
    param([string]$Root, [string]$RepositoryId,
        [int]$PullRequestId, [string]$RuleId, [byte[]]$Key)
    $journalRoot = Join-Path $Root 'journal'
    Assert-CoverageV2LedgerFixtureDirectory $Root $journalRoot
    $directories = @(Get-ChildItem -LiteralPath $journalRoot -Directory -Force)
    if ($directories.Count -gt 2000 -or
        @(Get-ChildItem -LiteralPath $journalRoot -File -Force).Count -ne 0) {
        throw 'coverage-v2-ledger-history-unavailable'
    }
    $history = [Collections.Generic.List[object]]::new()
    $target = @()
    $pattern = '^(?<repository>[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})-(?<pr>[1-9][0-9]*)-(?<rule>test-class|redundant-method)$'
    foreach ($directory in $directories) {
        Assert-CoverageV2LedgerFixtureDirectory $Root $directory.FullName
        if (-not ($directory.Name -cmatch $pattern)) {
            throw 'coverage-v2-ledger-history-unavailable'
        }
        $repository = [string]$Matches.repository
        $pr = 0
        if (-not [int]::TryParse([string]$Matches.pr, [ref]$pr) -or
            $pr -lt 1) {
            throw 'coverage-v2-ledger-history-unavailable'
        }
        $scannedRule = if ($Matches.rule -ceq 'test-class') {
            $script:LedgerRules[0]
        } else { $script:LedgerRules[1] }
        $records = @(Read-CoverageV2LedgerJournal $directory.FullName `
                $repository $pr $scannedRule $Key)
        if ($records.Count -eq 0 -or
            $history.Count + $records.Count -gt 10000) {
            throw 'coverage-v2-ledger-history-unavailable'
        }
        foreach ($record in $records) { [void]$history.Add($record) }
        if ($repository -ceq $RepositoryId -and
            $pr -eq $PullRequestId -and $scannedRule -ceq $RuleId) {
            $target = $records
        }
    }
    return [ordered]@{ target = $target; all = $history.ToArray() }
}

function Read-CoverageV2LedgerJournal {
    param([string]$BucketPath, [string]$RepositoryId,
        [int]$PullRequestId, [string]$RuleId, [byte[]]$Key)
    $records = [Collections.Generic.List[object]]::new()
    $previousDigest = '0' * 64
    $reservations = @{}
    if (-not (Test-Path -LiteralPath $BucketPath -PathType Container)) {
        return @()
    }
    $files = @(Get-ChildItem -LiteralPath $BucketPath -Force -File |
            Sort-Object Name)
    if ($files.Count -gt 10000 -or
        @(Get-ChildItem -LiteralPath $BucketPath -Force -Directory).Count -ne 0) {
        throw 'coverage-v2-ledger-tampered'
    }
    foreach ($file in $files) {
        $sequence = $records.Count + 1
        if ($file.Name -cne $sequence.ToString('D8') + '.json' -or
            $file.Length -lt 1 -or $file.Length -gt 16384) {
            throw 'coverage-v2-ledger-tampered'
        }
        [void](Assert-AgentTrustedFile -Path $file.FullName `
                -AllowedRoot $BucketPath -Private)
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString(
                [IO.File]::ReadAllBytes($file.FullName))
            $record = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 24
        }
        catch { throw 'coverage-v2-ledger-tampered' }
        $names = @('schemaVersion', 'kind', 'bucket', 'sequence',
            'previousDigest', 'event', 'hmac')
        if ($record -isnot [Collections.IDictionary] -or
            $record.Count -ne $names.Count -or
            @($record.Keys | Where-Object { [string]$_ -cnotin $names }).Count -ne 0 -or
            $record.schemaVersion -cne 1 -or
            [string]$record.kind -cne 'coverage-v2-proof-neutral-ledger-event' -or
            $record.bucket -isnot [Collections.IDictionary] -or
            [string]$record.bucket.repositoryId -cne $RepositoryId -or
            [string]$record.bucket.pullRequestId -cne
                [string]$PullRequestId -or
            [string]$record.bucket.ruleId -cne $RuleId -or
            $record.sequence -cne $sequence -or
            [string]$record.previousDigest -cne $previousDigest -or
            [string]$record.hmac -cnotmatch '^[a-f0-9]{64}$' -or
            $record.event -isnot [Collections.IDictionary]) {
            throw 'coverage-v2-ledger-tampered'
        }
        $unsigned = [ordered]@{}
        foreach ($name in $names) {
            if ($name -cne 'hmac') { $unsigned[$name] = $record[$name] }
        }
        $expected = Get-CoverageV2LedgerHmac -Unsigned $unsigned -Key $Key
        if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                [Convert]::FromHexString([string]$record.hmac),
                [Convert]::FromHexString($expected)) -or
            $text -cne ((ConvertTo-AgentCanonicalJson -InputObject $record) + "`n")) {
            throw 'coverage-v2-ledger-tampered'
        }
        $event = $record.event
        if ((@($event.Keys | Sort-Object) -join ',') -cne
                (@(@('findingDigest', 'marker', 'operation', 'reservationId',
                            'runId') | Sort-Object) -join ',') -or
            $event.Count -ne 5 -or
            [string]$event.marker -cnotmatch '^[a-f0-9]{64}$' -or
            [string]$event.findingDigest -cnotmatch '^[a-f0-9]{64}$' -or
            [string]$event.runId -cnotmatch '^[A-Za-z0-9-]{1,80}$' -or
            [string]$event.reservationId -cnotmatch '^[a-f0-9]{64}$' -or
            [string]$event.operation -cnotin @(
                'reserved', 'attempted', 'readback-confirmed',
                'readback-missing', 'readback-ambiguous')) {
            throw 'coverage-v2-ledger-tampered'
        }
        $id = [string]$event.reservationId
        if ($event.operation -ceq 'reserved') {
            if ($reservations.ContainsKey($id) -or
                @($reservations.Values | Where-Object {
                        [string]$_.marker -ceq [string]$event.marker -or
                        [string]$_.findingDigest -ceq
                            [string]$event.findingDigest }).Count -ne 0) {
                throw 'coverage-v2-ledger-tampered'
            }
            $reservations[$id] = @{ marker = [string]$event.marker
                findingDigest = [string]$event.findingDigest
                runId = [string]$event.runId; state = 'reserved' }
        } else {
            if (-not $reservations.ContainsKey($id) -or
                [string]$reservations[$id].marker -cne
                    [string]$event.marker -or
                [string]$reservations[$id].findingDigest -cne
                    [string]$event.findingDigest -or
                [string]$reservations[$id].runId -cne
                    [string]$event.runId) {
                throw 'coverage-v2-ledger-tampered'
            }
            if ($event.operation -ceq 'attempted') {
                if ($reservations[$id].state -cne 'reserved') {
                    throw 'coverage-v2-ledger-tampered'
                }
                $reservations[$id].state = 'attempted'
            } else {
                if ($reservations[$id].state -cne 'attempted') {
                    throw 'coverage-v2-ledger-tampered'
                }
                $reservations[$id].state = [string]$event.operation
            }
        }
        [void]$records.Add($record)
        $previousDigest = Get-AgentCanonicalDigest -InputObject $record
    }
    return $records.ToArray()
}

function Invoke-CoverageV2LedgerFixture {
    param([string]$Root, [byte[]]$Key,
        [string]$RepositoryId, [int]$PullRequestId, [string]$RuleId,
        [string]$RunId, [string]$Marker, [string]$FindingDigest,
        [ValidateSet('Reserve', 'Attempt', 'Readback', 'Inspect')]
        [string]$Operation,
        [ValidateSet('confirmed', 'missing', 'ambiguous')]
        [string]$ReadbackState = 'ambiguous')
    Assert-CoverageV2LedgerFixtureRoot $Root
    Assert-CoverageV2LedgerInput $RepositoryId $PullRequestId `
        $RuleId $RunId $Marker $FindingDigest $Key
    $bucket = Get-CoverageV2LedgerBucket $Root $RepositoryId `
        $PullRequestId $RuleId
    foreach ($subdirectory in @('locks', 'journal')) {
        $path = Join-Path $Root $subdirectory
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $path -ErrorAction Stop)
        }
        Assert-CoverageV2LedgerFixtureDirectory $Root $path
    }
    $lock = $null
    try {
        try {
            $lock = [IO.File]::Open($bucket.lockPath,
                [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
                [IO.FileShare]::None)
        }
        catch [IO.IOException] { throw 'coverage-v2-ledger-busy-or-stale-lock' }
        $lock.WriteByte(1)
        $lock.Flush($true)
        $scanned = Read-CoverageV2LedgerHistory $Root `
            $RepositoryId $PullRequestId $RuleId $Key
        $records = @($scanned.target)
        $id = Get-AgentCanonicalDigest -InputObject @(
            $RepositoryId, $PullRequestId, $RuleId, $RunId,
            $Marker, $FindingDigest)
        $reserved = @($records | Where-Object {
                [string]$_.event.operation -ceq 'reserved'
            })
        $matching = @($records | Where-Object {
                [string]$_.event.reservationId -ceq $id
            })
        if ($Operation -ceq 'Inspect') {
            return [ordered]@{ state = 'proof-neutral-not-authority'
                reservationCount = $reserved.Count; eventCount = $records.Count
                events = @($matching | ForEach-Object {
                        [string]$_.event.operation }) }
        }
        if ($Operation -ceq 'Reserve') {
            if (@($reserved | Where-Object {
                        [string]$_.event.marker -ceq $Marker -or
                        [string]$_.event.findingDigest -ceq
                            $FindingDigest }).Count -ne 0 -or
                $matching.Count -ne 0) {
                throw 'coverage-v2-ledger-retry-forbidden'
            }
            $runReservations = @($scanned.all | Where-Object {
                    [string]$_.bucket.repositoryId -ceq $RepositoryId -and
                    [string]$_.bucket.ruleId -ceq $RuleId -and
                    [string]$_.event.operation -ceq 'reserved' -and
                    [string]$_.event.runId -ceq $RunId
                })
            if ($reserved.Count -ge 5 -or
                $runReservations.Count -ge 2) {
                throw 'coverage-v2-ledger-budget-exhausted'
            }
            $eventOperation = 'reserved'
        } else {
            if ($matching.Count -eq 0 -or
                @($matching | Where-Object {
                        [string]$_.event.operation -ceq 'reserved'
                    }).Count -ne 1) {
                throw 'coverage-v2-ledger-reservation-unavailable'
            }
            $last = [string]$matching[-1].event.operation
            if ($Operation -ceq 'Attempt') {
                if ($last -cne 'reserved') {
                    throw 'coverage-v2-ledger-retry-forbidden'
                }
                $eventOperation = 'attempted'
            } else {
                if ($last -cne 'attempted') {
                    throw 'coverage-v2-ledger-readback-not-pending'
                }
                $eventOperation = 'readback-' + $ReadbackState
            }
        }
        $previous = if ($records.Count -eq 0) {
            '0' * 64
        } else {
            Get-AgentCanonicalDigest -InputObject $records[-1]
        }
        $unsigned = [ordered]@{
            schemaVersion = 1
            kind = 'coverage-v2-proof-neutral-ledger-event'
            bucket = [ordered]@{ repositoryId = $RepositoryId
                pullRequestId = $PullRequestId; ruleId = $RuleId }
            sequence = $records.Count + 1
            previousDigest = $previous
            event = [ordered]@{ findingDigest = $FindingDigest
                marker = $Marker; operation = $eventOperation
                reservationId = $id; runId = $RunId }
        }
        $record = [ordered]@{}
        foreach ($name in $unsigned.Keys) { $record[$name] = $unsigned[$name] }
        $record.hmac = Get-CoverageV2LedgerHmac $unsigned $Key
        if (-not (Test-Path -LiteralPath $bucket.path -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $bucket.path `
                    -ErrorAction Stop)
        }
        Assert-CoverageV2LedgerFixtureDirectory $Root $bucket.path
        $path = Join-Path $bucket.path (
            $unsigned.sequence.ToString('D8') + '.json')
        $bytes = [Text.Encoding]::UTF8.GetBytes(
            (ConvertTo-AgentCanonicalJson -InputObject $record) + "`n")
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes); $stream.Flush($true) }
        finally { $stream.Dispose() }
        [void](Assert-AgentTrustedFile -Path $path `
                -AllowedRoot $bucket.path -Private)
        return [ordered]@{ state = 'proof-neutral-not-authority'
            recorded = $eventOperation; reservationId = $id
            reservationCount = $reserved.Count +
                [int]($eventOperation -ceq 'reserved') }
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
            Remove-Item -LiteralPath $bucket.lockPath -Force
        }
    }
}

function Invoke-CoverageV2TrustedLedger {
    param([string]$Root, [Collections.IDictionary]$Authority)
    # The read-only canary has no signed per-finding issuer or trusted consumer.
    # No real root, lock, key, generation, or journal may be created here.
    throw 'coverage-v2-signed-finding-authority-unavailable'
}

Export-ModuleMember -Function @()
