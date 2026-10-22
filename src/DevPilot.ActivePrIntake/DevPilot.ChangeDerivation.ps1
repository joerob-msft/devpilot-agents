#requires -Version 7.0

Set-StrictMode -Version Latest

function Test-DevPilotDerivationInteger {
    param(
        [AllowNull()][object]$Value,
        [long]$Minimum = 0
    )

    return $Value -isnot [bool] -and
        ($Value -is [int] -or
            $Value -is [long]) -and
        [long]$Value -ge $Minimum
}

function Get-DevPilotUtf8Digest {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [ordered]@{
        bytes = $bytes
        byteLength = [long]$bytes.Length
        sha256 = 'v1:sha256:' +
            [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    $bytes)).ToLowerInvariant()
    }
}

function Assert-DevPilotSafeRepositoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path -cne $Path.Trim() -or
        $Path.Length -gt 1024 -or
        $Path -match '[\x00-\x1f\x7f]') {
        throw 'change-derivation-path-invalid'
    }
    $normalized = $Path.Replace('\', '/')
    if ($normalized.StartsWith('/') -or
        $normalized -match '^[A-Za-z]:' -or
        $normalized.Contains('//')) {
        throw 'change-derivation-path-invalid'
    }
    $segments = @($normalized.Split('/'))
    if ($segments.Count -eq 0 -or
        @($segments | Where-Object {
                $_ -cin @('', '.', '..')
            }).Count -gt 0) {
        throw 'change-derivation-path-invalid'
    }
    return $normalized
}

function Assert-DevPilotChangeInventory {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Changes
    )

    if (-not $Changes.Contains('changedFiles') -or
        -not (Test-DevPilotDerivationInteger `
            -Value $Changes.changedFiles) -or
        -not $Changes.Contains('changedLines') -or
        -not (Test-DevPilotDerivationInteger `
            -Value $Changes.changedLines) -or
        $Changes.entries -isnot [array] -or
        [long]$Changes.changedFiles -ne
            @($Changes.entries).Count -or
        ([long]$Changes.changedFiles -eq 0 -and
            [long]$Changes.changedLines -ne 0)) {
        throw 'change-inventory-invalid'
    }
    $lineCount = 0L
    foreach ($entry in @($Changes.entries)) {
        if ($entry -isnot [Collections.IDictionary] -or
            $entry.spans -isnot [array]) {
            throw 'change-inventory-invalid'
        }
        foreach ($span in @($entry.spans)) {
            if ($span -isnot
                    [Collections.IDictionary] -or
                -not (Test-DevPilotDerivationInteger `
                    -Value $span.startLine `
                    -Minimum 1) -or
                -not (Test-DevPilotDerivationInteger `
                    -Value $span.endLine `
                    -Minimum 1) -or
                [long]$span.startLine -gt
                    [int]::MaxValue -or
                [long]$span.endLine -gt
                    [int]::MaxValue -or
                [long]$span.endLine -lt
                    [long]$span.startLine) {
                throw 'change-inventory-span-invalid'
            }
            $lineCount +=
                [long]$span.endLine -
                [long]$span.startLine + 1
        }
    }
    if ($lineCount -ne
        [long]$Changes.changedLines) {
        throw 'change-inventory-line-count-mismatch'
    }
}

function Get-DevPilotZeroAddedLineModifiedTextProof {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceContent,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TargetContent
    )

    if ($SourceContent.IndexOf([char]0) -ge 0 -or
        $TargetContent.IndexOf([char]0) -ge 0) {
        return $null
    }
    $normalizedSource = $SourceContent.Replace("`r`n", "`n")
    $normalizedTarget = $TargetContent.Replace("`r`n", "`n")
    if ($normalizedSource.IndexOf([char]"`r") -ge 0 -or
        $normalizedTarget.IndexOf([char]"`r") -ge 0) {
        return $null
    }
    if ($SourceContent -ceq $TargetContent) {
        return 'identical-content'
    }
    if ($normalizedSource -ceq $normalizedTarget) {
        return 'normalized-line-ending-only'
    }
    if ($normalizedSource.Length -gt 0 -and
        ($normalizedSource.EndsWith("`n") -ne
            $normalizedTarget.EndsWith("`n"))) {
        return $null
    }
    $sourceLines = @(if ($normalizedSource.Length -eq 0) {
            @()
        }
        else {
            $normalizedSource.Split("`n")
        })
    $targetLines = @(if ($normalizedTarget.Length -eq 0) {
            @()
        }
        else {
            $normalizedTarget.Split("`n")
        })
    if ($sourceLines.Count -ge $targetLines.Count -or
        $targetLines.Count -gt 200000) {
        return $null
    }
    $sourceIndex = 0
    for ($targetIndex = 0;
        $targetIndex -lt $targetLines.Count -and
        $sourceIndex -lt $sourceLines.Count;
        $targetIndex++) {
        if ($targetLines[$targetIndex] -ceq
            $sourceLines[$sourceIndex]) {
            $sourceIndex++
        }
    }
    if ($sourceIndex -eq $sourceLines.Count) {
        return 'deletion-only'
    }
    return $null
}

function Get-DevPilotValidatedModifiedZeroSpanProof {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Entry,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Head,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Derivation
    )

    if ([string]$Derivation.state -cne 'complete' -or
        [string]$Entry.state -cne 'complete' -or
        ($Entry.Contains('isBinary') -and
            [bool]$Entry.isBinary) -or
        ($Entry.Contains('truncated') -and
            [bool]$Entry.truncated) -or
        ($Entry.Contains('unavailableReason') -and
            $null -ne $Entry.unavailableReason) -or
        [string]$Derivation.changeType -cne 'modified' -or
        [string]$Derivation.pathRelation -cne 'same-path' -or
        [string]$Derivation.sourceContentState -cne 'available' -or
        [string]$Derivation.targetContentState -cne 'available' -or
        [string]$Derivation.sourceContentSha256 -cnotmatch
            '^v1:sha256:[0-9a-f]{64}$' -or
        [string]$Derivation.targetContentSha256 -cnotmatch
            '^v1:sha256:[0-9a-f]{64}$' -or
        [long]$Derivation.spanCount -ne 0 -or
        [long]$Derivation.currentLineCount -ne 0 -or
        $Entry.content -isnot [string]) {
        return $null
    }
    $actualSource = Get-DevPilotUtf8Digest (
        [string]$Entry.content)
    if ([long]$Entry.byteLength -ne
            [long]$actualSource.byteLength -or
        [string]$Entry.sourceDigest -cne
            [string]$actualSource.sha256 -or
        [string]$Derivation.sourceContentSha256 -cne
            [string]$actualSource.sha256 -or
        [long]$Derivation.sourceByteLength -ne
            [long]$actualSource.byteLength) {
        throw 'change-derivation-content-mismatch'
    }
    if ([string]$Derivation.sourceContentSha256 -ceq
            [string]$Derivation.targetContentSha256 -and
        [long]$Derivation.sourceByteLength -eq
            [long]$Derivation.targetByteLength) {
        if ($Entry.Contains('comparison') -and
            $null -ne $Entry.comparison) {
            $comparison = $Entry.comparison
            if ($comparison -isnot [Collections.IDictionary] -or
                [string]$comparison.state -cne 'complete' -or
                [string]$comparison.targetState -cne 'present' -or
                ($comparison.Contains('truncated') -and
                    [bool]$comparison.truncated) -or
                [string]$comparison.path -cne [string]$Entry.path -or
                [string]$comparison.targetPath -cne [string]$Entry.path -or
                [string]$comparison.sourceCommit -cne
                    [string]$Head.sourceCommit -or
                [string]$comparison.targetCommit -cne
                    [string]$Head.targetCommit -or
                [string]$comparison.sourceDigest -cne
                    [string]$actualSource.sha256 -or
                $comparison.content -isnot [string]) {
                return $null
            }
            $actualTarget = Get-DevPilotUtf8Digest (
                [string]$comparison.content)
            if ([long]$comparison.byteLength -ne
                    [long]$actualTarget.byteLength -or
                [long]$Derivation.targetByteLength -ne
                    [long]$actualTarget.byteLength -or
                [string]$comparison.targetDigest -cne
                    [string]$actualTarget.sha256 -or
                [string]$Derivation.targetContentSha256 -cne
                    [string]$actualTarget.sha256) {
                return $null
            }
        }
        return 'identical-content'
    }
    $comparison = if ($Entry.Contains('comparison')) {
        $Entry.comparison
    }
    else {
        $null
    }
    if ($comparison -isnot [Collections.IDictionary] -or
        [string]$comparison.state -cne 'complete' -or
        [string]$comparison.targetState -cne 'present' -or
        ($comparison.Contains('truncated') -and
            [bool]$comparison.truncated) -or
        [string]$comparison.path -cne [string]$Entry.path -or
        [string]$comparison.targetPath -cne [string]$Entry.path -or
        [string]$comparison.sourceCommit -cne
            [string]$Head.sourceCommit -or
        [string]$comparison.targetCommit -cne
            [string]$Head.targetCommit -or
        [string]$comparison.sourceDigest -cne
            [string]$actualSource.sha256 -or
        $comparison.content -isnot [string]) {
        return $null
    }
    $actualTarget = Get-DevPilotUtf8Digest (
        [string]$comparison.content)
    if ([long]$comparison.byteLength -ne
            [long]$actualTarget.byteLength -or
        [long]$Derivation.targetByteLength -ne
            [long]$actualTarget.byteLength -or
        [string]$comparison.targetDigest -cne
            [string]$actualTarget.sha256 -or
        [string]$Derivation.targetContentSha256 -cne
            [string]$actualTarget.sha256) {
        return $null
    }
    return Get-DevPilotZeroAddedLineModifiedTextProof `
        -SourceContent ([string]$Entry.content) `
        -TargetContent ([string]$comparison.content)
}

function New-DevPilotChangeDerivation {
    param(
        [Parameter(Mandatory)][string]$ChangeType,
        [Parameter(Mandatory)][bool]$IsText,
        [Parameter(Mandatory)][bool]$Deleted,
        [Parameter(Mandatory)][bool]$Renamed,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceContent,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TargetContent,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Spans,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit
    )

    $normalizedChangeType = switch -Regex ($ChangeType) {
        '^add$' { 'added'; break }
        '^edit$' { 'modified'; break }
        '^delete$' { 'deleted'; break }
        'rename' { 'renamed'; break }
        default { 'unsupported' }
    }
    $source = Get-DevPilotUtf8Digest $SourceContent
    $target = Get-DevPilotUtf8Digest $TargetContent
    $currentLineCount = 0L
    foreach ($span in $Spans) {
        $currentLineCount +=
            [long]$span.endLine -
            [long]$span.startLine + 1
    }
    $zeroAddedProof = if ($IsText -and
        -not $Deleted -and
        $normalizedChangeType -ceq 'modified' -and
        -not $Renamed -and
        $Spans.Count -eq 0 -and
        $currentLineCount -eq 0) {
        if ([Collections.StructuralComparisons]::
            StructuralEqualityComparer.Equals(
                $source.bytes,
                $target.bytes)) {
            'identical-content'
        }
        else {
            Get-DevPilotZeroAddedLineModifiedTextProof `
                -SourceContent $SourceContent `
                -TargetContent $TargetContent
        }
    }
    else {
        $null
    }
    $classification = if (-not $IsText) {
        'derivation-unknown'
    }
    elseif ($Deleted) {
        'deletion-only'
    }
    elseif ($zeroAddedProof -in @(
            'identical-content',
            'normalized-line-ending-only')) {
        'identical-content'
    }
    elseif ($zeroAddedProof -ceq 'deletion-only') {
        'deletion-only'
    }
    elseif ($Spans.Count -gt 0 -and
        $currentLineCount -gt 0) {
        'current-lines'
    }
    else {
        'derivation-unknown'
    }
    return [ordered]@{
        schemaVersion = 1
        kind = 'devpilot-current-line-derivation-v1'
        producer = 'active-pr-intake-v1'
        state = $(if ($IsText) {
                'complete'
            }
            else {
                'unknown'
            })
        classification = $classification
        changeType = $normalizedChangeType
        pathRelation = $(if ($Renamed) {
                'renamed'
            }
            else {
                'same-path'
            })
        sourceCommit = $SourceCommit
        targetCommit = $TargetCommit
        sourceContentState = $(if ($Deleted) {
                'absent-deleted'
            }
            elseif ($IsText) {
                'available'
            }
            else {
                'unavailable'
            })
        targetContentState = $(if ($Deleted) {
                'not-read-deleted'
            }
            elseif ($IsText) {
                'available'
            }
            else {
                'unavailable'
            })
        sourceContentSha256 = $(if ($IsText) {
                [string]$source.sha256
            }
            else {
                'unknown'
            })
        targetContentSha256 = $(if (
            $IsText -and -not $Deleted
        ) {
                [string]$target.sha256
            }
            else {
                'unknown'
            })
        sourceByteLength = $(if ($IsText) {
                [long]$source.byteLength
            }
            else {
                0L
            })
        targetByteLength = $(if (
            $IsText -and -not $Deleted
        ) {
                [long]$target.byteLength
            }
            else {
                0L
            })
        spanCount = [long]$Spans.Count
        currentLineCount = $currentLineCount
    }
}

function Get-DevPilotChangeDerivationDisposition {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Entry,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Head
    )

    $derivation = if ($Entry.Contains(
            'derivation')) {
        $Entry.derivation
    }
    else {
        $null
    }
    if ($derivation -isnot
            [Collections.IDictionary] -or
        -not (Test-DevPilotDerivationInteger `
            -Value $derivation.schemaVersion `
            -Minimum 1) -or
        [long]$derivation.schemaVersion -ne 1 -or
        [string]$derivation.kind -cne
            'devpilot-current-line-derivation-v1' -or
        [string]$derivation.producer -cne
            'active-pr-intake-v1' -or
        [string]$derivation.sourceCommit -cne
            [string]$Head.sourceCommit -or
        [string]$derivation.targetCommit -cne
            [string]$Head.targetCommit -or
        [string]$derivation.classification -cnotin @(
            'identical-content',
            'deletion-only',
            'current-lines',
            'derivation-unknown') -or
        [string]$derivation.state -cnotin @(
            'complete', 'unknown') -or
        [string]$derivation.pathRelation -cnotin @(
            'same-path', 'renamed') -or
        [string]$derivation.changeType -cnotin @(
            'added', 'modified', 'deleted',
            'renamed', 'unsupported') -or
        $Entry.spans -isnot [array]) {
        throw 'change-derivation-unavailable'
    }
    foreach ($value in @(
            $Entry.byteLength,
            $derivation.sourceByteLength,
            $derivation.targetByteLength,
            $derivation.spanCount,
            $derivation.currentLineCount)) {
        if (-not (Test-DevPilotDerivationInteger `
                -Value $value)) {
            throw 'change-derivation-count-invalid'
        }
    }
    $expectedChangeType = switch -Regex (
        [string]$Entry.changeType) {
        '^add$' { 'added'; break }
        '^edit$' { 'modified'; break }
        '^delete$' { 'deleted'; break }
        'rename' { 'renamed'; break }
        default { 'unsupported' }
    }
    [void](Assert-DevPilotSafeRepositoryPath `
            -Path ([string]$Entry.path))
    $hasOldPath = $Entry.Contains('oldPath')
    if ($hasOldPath) {
        [void](Assert-DevPilotSafeRepositoryPath `
                -Path ([string]$Entry.oldPath))
    }
    if ([string]$derivation.changeType -cne
            $expectedChangeType -or
        ([string]$derivation.pathRelation -ceq
            'renamed') -ne
        ($expectedChangeType -ceq 'renamed') -or
        ([string]$derivation.pathRelation -ceq
            'same-path' -and $hasOldPath) -or
        ([string]$derivation.pathRelation -ceq
            'renamed' -and (
                -not $hasOldPath -or
                [string]::IsNullOrWhiteSpace(
                    [string]$Entry.oldPath))) -or
        [long]$derivation.spanCount -ne
            @($Entry.spans).Count) {
        throw 'change-derivation-inconsistent'
    }
    $classification =
        [string]$derivation.classification
    if ($classification -ceq
        'derivation-unknown') {
        $migratedProof =
            Get-DevPilotValidatedModifiedZeroSpanProof `
                -Entry $Entry -Head $Head `
                -Derivation $derivation
        if ($migratedProof -in @(
                'identical-content',
                'normalized-line-ending-only')) {
            return [ordered]@{
                classification = 'identical-content'
                knownEmptyIdentical = (
                    $migratedProof -ceq 'identical-content')
                knownEmptyDeletedFile = $false
                knownEmptyZeroAddedLines = $true
                forceUnknown = $false
            }
        }
        if ($migratedProof -ceq 'deletion-only') {
            return [ordered]@{
                classification = 'deletion-only'
                knownEmptyIdentical = $false
                knownEmptyDeletedFile = $false
                knownEmptyZeroAddedLines = $true
                forceUnknown = $false
            }
        }
        return [ordered]@{
            classification = $classification
            knownEmptyIdentical = $false
            knownEmptyDeletedFile = $false
            knownEmptyZeroAddedLines = $false
            forceUnknown = $true
        }
    }
    $actualContent = if ($Entry.content -is
            [string]) {
        Get-DevPilotUtf8Digest (
            [string]$Entry.content)
    }
    else {
        $null
    }
    if ($expectedChangeType -cne
        'deleted') {
        if ([string]$Entry.state -cne
                'complete' -or
            $null -eq $actualContent -or
            [long]$Entry.byteLength -ne
                [long]$actualContent.byteLength -or
            [string]$Entry.sourceDigest -cne
                [string]$actualContent.sha256 -or
            [string]$derivation.sourceContentSha256 -cne
                [string]$actualContent.sha256 -or
            [long]$derivation.sourceByteLength -ne
                [long]$actualContent.byteLength) {
            throw 'change-derivation-content-mismatch'
        }
    }
    $currentLineCount = 0L
    foreach ($span in @($Entry.spans)) {
        if ($span -isnot
                [Collections.IDictionary] -or
            -not (Test-DevPilotDerivationInteger `
                -Value $span.startLine `
                -Minimum 1) -or
            -not (Test-DevPilotDerivationInteger `
                -Value $span.endLine `
                -Minimum 1) -or
            [long]$span.startLine -gt
                [int]::MaxValue -or
            [long]$span.endLine -gt
                [int]::MaxValue -or
            [long]$span.endLine -lt
                [long]$span.startLine) {
            throw 'change-derivation-span-invalid'
        }
        $currentLineCount +=
            [long]$span.endLine -
            [long]$span.startLine + 1
    }
    if ([long]$derivation.currentLineCount -ne
        $currentLineCount) {
        throw 'change-derivation-line-count-mismatch'
    }
    if ($classification -ceq
        'identical-content') {
        $identicalProof =
            Get-DevPilotValidatedModifiedZeroSpanProof `
                -Entry $Entry -Head $Head `
                -Derivation $derivation
        if ($identicalProof -notin @(
                'identical-content',
                'normalized-line-ending-only')) {
            throw 'change-derivation-identical-invalid'
        }
        return [ordered]@{
            classification = $classification
            knownEmptyIdentical = (
                $identicalProof -ceq 'identical-content')
            knownEmptyDeletedFile = $false
            knownEmptyZeroAddedLines = $true
            forceUnknown = $false
        }
    }
    if ($classification -ceq
        'deletion-only') {
        if ($expectedChangeType -ceq 'modified') {
            $deletionProof =
                Get-DevPilotValidatedModifiedZeroSpanProof `
                    -Entry $Entry -Head $Head `
                    -Derivation $derivation
            if ($deletionProof -cne 'deletion-only') {
                throw 'change-derivation-deleted-invalid'
            }
            return [ordered]@{
                classification = $classification
                knownEmptyIdentical = $false
                knownEmptyDeletedFile = $false
                knownEmptyZeroAddedLines = $true
                forceUnknown = $false
            }
        }
        $emptyDigest = [string](
            Get-DevPilotUtf8Digest '').sha256
        if ($expectedChangeType -cne
                'deleted' -or
            [string]$derivation.state -cne
                'complete' -or
            [string]$Entry.state -cne
                'complete' -or
            $Entry.content -isnot [string] -or
            [string]$Entry.content -cne '' -or
            [long]$Entry.byteLength -ne 0 -or
            [string]$Entry.sourceDigest -cne
                $emptyDigest -or
            [string]$derivation.pathRelation -cne
                'same-path' -or
            [string]$derivation.sourceContentState -cne
                'absent-deleted' -or
            [string]$derivation.targetContentState -cne
                'not-read-deleted' -or
            [string]$derivation.sourceContentSha256 -cne
                $emptyDigest -or
            [string]$derivation.targetContentSha256 -cne
                'unknown' -or
            [long]$derivation.sourceByteLength -ne 0 -or
            [long]$derivation.targetByteLength -ne 0 -or
            [long]$derivation.spanCount -ne 0 -or
            [long]$derivation.currentLineCount -ne 0) {
            throw 'change-derivation-deleted-invalid'
        }
        return [ordered]@{
            classification = $classification
            knownEmptyIdentical = $false
            knownEmptyDeletedFile = $true
            knownEmptyZeroAddedLines = $true
            forceUnknown = $false
        }
    }
    if ($classification -ceq
        'current-lines') {
        if ([string]$derivation.state -cne
                'complete' -or
            [long]$derivation.spanCount -lt 1 -or
            [long]$derivation.currentLineCount -lt 1) {
            throw 'change-derivation-current-lines-invalid'
        }
        return [ordered]@{
            classification = $classification
            knownEmptyIdentical = $false
            knownEmptyDeletedFile = $false
            knownEmptyZeroAddedLines = $false
            forceUnknown = $false
        }
    }
    throw 'change-derivation-unsupported'
}
