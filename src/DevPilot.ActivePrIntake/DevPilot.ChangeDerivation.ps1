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
    $classification = if (-not $IsText) {
        'derivation-unknown'
    }
    elseif ($Deleted) {
        'deletion-only'
    }
    elseif ($normalizedChangeType -ceq
            'modified' -and
        -not $Renamed -and
        $Spans.Count -eq 0 -and
        $currentLineCount -eq 0 -and
        [Collections.StructuralComparisons]::
            StructuralEqualityComparer.Equals(
                $source.bytes,
                $target.bytes)) {
        'identical-content'
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
        return [ordered]@{
            classification = $classification
            knownEmptyIdentical = $false
            knownEmptyDeletedFile = $false
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
        if ([string]$derivation.state -cne
                'complete' -or
            $expectedChangeType -cne
                'modified' -or
            [string]$derivation.pathRelation -cne
                'same-path' -or
            [string]$derivation.sourceContentState -cne
                'available' -or
            [string]$derivation.targetContentState -cne
                'available' -or
            [string]$derivation.sourceContentSha256 -cnotmatch
                '^v1:sha256:[0-9a-f]{64}$' -or
            [string]$derivation.sourceContentSha256 -cne
                [string]$derivation.targetContentSha256 -or
            [long]$derivation.sourceByteLength -ne
                [long]$derivation.targetByteLength -or
            [long]$derivation.spanCount -ne 0 -or
            [long]$derivation.currentLineCount -ne 0) {
            throw 'change-derivation-identical-invalid'
        }
        return [ordered]@{
            classification = $classification
            knownEmptyIdentical = $true
            knownEmptyDeletedFile = $false
            forceUnknown = $false
        }
    }
    if ($classification -ceq
        'deletion-only') {
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
            forceUnknown = $false
        }
    }
    throw 'change-derivation-unsupported'
}
