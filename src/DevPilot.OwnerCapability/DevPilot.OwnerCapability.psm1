#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1"
Import-Module "$PSScriptRoot\..\OwnerObservationContract\OwnerObservationContract.psd1" -Force

$limitsTypeName = 'DevPilot.OwnerCapability.OwnerV2CapabilityLimits'
if (-not ($limitsTypeName -as [type])) {
    Add-Type -TypeDefinition @'
namespace DevPilot.OwnerCapability
{
    public sealed class OwnerV2CapabilityLimits
    {
        public int MaximumFiles { get; }
        public int MaximumSemanticUnits { get; }
        public int MaximumSnippetCharacters { get; }
        public int MaximumDiagnostics { get; }

        public OwnerV2CapabilityLimits(
            int maximumFiles,
            int maximumSemanticUnits,
            int maximumSnippetCharacters,
            int maximumDiagnostics)
        {
            MaximumFiles = maximumFiles;
            MaximumSemanticUnits = maximumSemanticUnits;
            MaximumSnippetCharacters = maximumSnippetCharacters;
            MaximumDiagnostics = maximumDiagnostics;
        }
    }
}
'@
}

$script:OwnerV2Semantics = 'owner-mstest-owner-capability-v2'
$script:OwnerV2RunnerSemantics = 'owner-mstest-owner-judgment-v2'
$script:OwnerV2States = @('complete', 'incomplete', 'unknown')
$script:OwnerV2Judgments = @('compliant', 'violation', 'unknown')
$script:OwnerV2DigestPattern = '^v1:sha256:[0-9a-f]{64}$'
$script:OwnerV2CommitPattern = '^[0-9a-f]{40}$'
$script:OwnerV2AttributePattern = (
    '(?i)(?:^|[^A-Za-z0-9_])(?<name>TestClass|TestMethod|DataTestMethod|Owner)' +
    '(?:Attribute)?(?=\s*(?:\(|,|\]|\z))'
)

function Assert-OwnerV2Text {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 512
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -cne $Value.Trim() -or
        $Value.Length -gt $MaximumLength -or
        $Value -match '[\r\n]') {
        throw "$Name must be non-empty, trimmed, single-line text no longer than $MaximumLength characters."
    }
}

function Get-OwnerV2Digest {
    param([Parameter(Mandatory)][object]$Value)

    $text = if ($Value -is [string]) {
        $Value
    }
    else {
        ConvertTo-Json -InputObject $Value -Depth 16 -Compress
    }
    return 'v1:sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))
    ).ToLowerInvariant()
}

function Get-OwnerV2Member {
    param(
        [Parameter()][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -is [Collections.IDictionary] -and $Value.Contains($Name)) {
        return $Value[$Name]
    }
    if ($null -ne $Value) {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Add-OwnerV2Diagnostic {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Diagnostics,
        [Parameter(Mandatory)][DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][AllowNull()][string]$UnitId
    )

    if ($Diagnostics.Count -ge $Limits.MaximumDiagnostics) { return }
    $entry = [ordered]@{
        code = $Code
        message = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($UnitId)) {
        $entry['unitId'] = $UnitId
    }
    [void]$Diagnostics.Add($entry)
}

function New-OwnerV2CapabilityLimits {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 128)][int]$MaximumFiles = 128,
        [ValidateRange(1, 127)][int]$MaximumSemanticUnits = 127,
        [ValidateRange(256, 8000)][int]$MaximumSnippetCharacters = 4000,
        [ValidateRange(1, 4)][int]$MaximumDiagnostics = 4
    )

    return [DevPilot.OwnerCapability.OwnerV2CapabilityLimits]::new(
        $MaximumFiles,
        $MaximumSemanticUnits,
        $MaximumSnippetCharacters,
        $MaximumDiagnostics)
}

function New-OwnerSemanticRunner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Handler,
        [scriptblock]$TelemetryProvider
    )

    Assert-OwnerV2Text -Value $Name -Name Name -MaximumLength 128
    $runner = [pscustomobject][ordered]@{
        Name = $Name
        Semantics = $script:OwnerV2RunnerSemantics
        Handler = $Handler
    }
    if ($TelemetryProvider) {
        $runner | Add-Member -NotePropertyName TelemetryProvider -NotePropertyValue $TelemetryProvider
    }
    $runner.PSTypeNames.Insert(0, 'DevPilot.OwnerCapability.SemanticRunner')
    return $runner
}

function Test-OwnerV2Runner {
    param([Parameter(Mandatory)][object]$Runner)

    if ($Runner -isnot [pscustomobject] -or
        $Runner.PSTypeNames -cnotcontains 'DevPilot.OwnerCapability.SemanticRunner' -or
        $Runner.Semantics -cne $script:OwnerV2RunnerSemantics -or
        $Runner.Handler -isnot [scriptblock] -or
        ($null -ne $Runner.PSObject.Properties['TelemetryProvider'] -and
            $Runner.TelemetryProvider -isnot [scriptblock])) {
        throw 'Expected a semantic runner created by New-OwnerSemanticRunner.'
    }
}

function Get-OwnerV2Attributes {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $maskedText = Remove-OwnerV2StringLiterals -Text $Text
    $maskedText = Remove-OwnerV2AttributeArguments -Text $maskedText
    $names = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($maskedText, $script:OwnerV2AttributePattern)) {
        $name = switch -Regex ($match.Groups['name'].Value) {
            '^(?i)testclass$' { 'TestClass'; break }
            '^(?i)testmethod$' { 'TestMethod'; break }
            '^(?i)datatestmethod$' { 'DataTestMethod'; break }
            '^(?i)owner$' { 'Owner'; break }
        }
        if ($null -ne $name) { [void]$names.Add($name) }
    }
    return @($names)
}

function Remove-OwnerV2AttributeArguments {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $result = [Text.StringBuilder]::new($Text.Length)
    $depth = 0
    foreach ($character in $Text.ToCharArray()) {
        if ($character -eq '(') {
            $depth++
            [void]$result.Append($character)
        }
        elseif ($character -eq ')') {
            if ($depth -gt 0) { $depth-- }
            [void]$result.Append($character)
        }
        elseif ($depth -gt 0 -and $character -ne "`n" -and $character -ne "`r") {
            [void]$result.Append(' ')
        }
        else {
            [void]$result.Append($character)
        }
    }
    return $result.ToString()
}

function Remove-OwnerV2StringLiterals {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $result = [Text.StringBuilder]::new($Text.Length)
    $quote = [char]0
    $verbatim = $false
    $escaped = $false
    $rawDelimiterLength = 0
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($rawDelimiterLength -gt 0) {
            $quoteRun = 0
            while ($index + $quoteRun -lt $Text.Length -and
                $Text[$index + $quoteRun] -eq [char]34) {
                $quoteRun++
            }
            if ($quoteRun -ge $rawDelimiterLength) {
                [void]$result.Append((' ' * $rawDelimiterLength) -join '')
                $index += $rawDelimiterLength - 1
                $rawDelimiterLength = 0
            }
            else {
                [void]$result.Append($(if ($character -eq "`n" -or $character -eq "`r") {
                            $character
                        }
                        else {
                            ' '
                        }))
            }
            continue
        }
        if ($quote -eq [char]0) {
            if ($character -eq [char]34) {
                $isVerbatimPrefix = $false
                if ($index -gt 0 -and $Text[$index - 1] -eq '@') {
                    $isVerbatimPrefix = $true
                }
                elseif ($index -gt 1 -and $Text[$index - 1] -eq '$' -and
                    $Text[$index - 2] -eq '@') {
                    $isVerbatimPrefix = $true
                }
                $quoteRun = 0
                while ($index + $quoteRun -lt $Text.Length -and
                    $Text[$index + $quoteRun] -eq [char]34) {
                    $quoteRun++
                }
                if (-not $isVerbatimPrefix -and $quoteRun -ge 3) {
                    $rawDelimiterLength = $quoteRun
                    [void]$result.Append((' ' * $quoteRun) -join '')
                    $index += $quoteRun - 1
                    continue
                }
            }
            if ($character -eq '"' -or $character -eq "'") {
                $quote = $character
                $verbatim = $false
                if ($character -eq [char]34) {
                    if ($index -gt 0 -and $Text[$index - 1] -eq '@') {
                        $verbatim = $true
                    }
                    elseif ($index -gt 1 -and $Text[$index - 1] -eq '$' -and
                        $Text[$index - 2] -eq '@') {
                        $verbatim = $true
                    }
                }
                [void]$result.Append(' ')
            }
            else {
                [void]$result.Append($character)
            }
            continue
        }

        [void]$result.Append($(if ($character -eq "`n" -or $character -eq "`r") { $character } else { ' ' }))
        if ($verbatim) {
            if ($character -eq '"' -and $index + 1 -lt $Text.Length -and $Text[$index + 1] -eq '"') {
                $index++
                [void]$result.Append(' ')
            }
            elseif ($character -eq '"') {
                $quote = [char]0
                $verbatim = $false
            }
        }
        elseif ($escaped) {
            $escaped = $false
        }
        elseif ($character -eq [char]92) {
            $escaped = $true
        }
        elseif ($character -eq $quote) {
            $quote = [char]0
        }
    }
    return $result.ToString()
}

function Remove-OwnerV2Comments {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ref]$InBlockComment,
        [Parameter(Mandatory)][ref]$InVerbatimString,
        [Parameter(Mandatory)][ref]$RawDelimiterLength
    )

    $result = [Text.StringBuilder]::new($Text.Length)
    $quote = [char]0
    $verbatim = $false
    $escaped = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        if ($RawDelimiterLength.Value -gt 0) {
            $quoteRun = 0
            while ($index + $quoteRun -lt $Text.Length -and
                $Text[$index + $quoteRun] -eq [char]34) {
                $quoteRun++
            }
            if ($quoteRun -ge $RawDelimiterLength.Value) {
                [void]$result.Append((' ' * $RawDelimiterLength.Value) -join '')
                $index += $RawDelimiterLength.Value - 1
                $RawDelimiterLength.Value = 0
            }
            else {
                [void]$result.Append(' ')
            }
            continue
        }
        if ($InVerbatimString.Value) {
            if ($character -eq '"' -and $next -eq '"') {
                [void]$result.Append('  ')
                $index++
            }
            elseif ($character -eq '"') {
                $InVerbatimString.Value = $false
                [void]$result.Append($character)
            }
            else {
                [void]$result.Append(' ')
            }
            continue
        }
        if ($InBlockComment.Value) {
            if ($character -eq '*' -and $next -eq '/') {
                $InBlockComment.Value = $false
                $index++
                [void]$result.Append('  ')
            }
            else {
                [void]$result.Append(' ')
            }
            continue
        }

        if ($quote -ne [char]0) {
            [void]$result.Append($character)
            if ($verbatim) {
                if ($character -eq '"' -and $next -eq '"') {
                    $index++
                    [void]$result.Append($next)
                }
                elseif ($character -eq '"') {
                    $quote = [char]0
                    $verbatim = $false
                }
            }
            elseif ($escaped) {
                $escaped = $false
            }
            elseif ($character -eq [char]92) {
                $escaped = $true
            }
            elseif ($character -eq $quote) {
                $quote = [char]0
            }
            continue
        }

        if ($character -eq '/' -and $next -eq '/') {
            [void]$result.Append(' ', $Text.Length - $index)
            break
        }
        if ($character -eq '/' -and $next -eq '*') {
            $InBlockComment.Value = $true
            $index++
            [void]$result.Append('  ')
            continue
        }
        if ($character -eq [char]34) {
            $isVerbatimPrefix = $false
            if ($index -gt 0 -and $Text[$index - 1] -eq '@') {
                $isVerbatimPrefix = $true
            }
            elseif ($index -gt 1 -and $Text[$index - 1] -eq '$' -and
                $Text[$index - 2] -eq '@') {
                $isVerbatimPrefix = $true
            }
            $quoteRun = 0
            while ($index + $quoteRun -lt $Text.Length -and
                $Text[$index + $quoteRun] -eq [char]34) {
                $quoteRun++
            }
            if (-not $isVerbatimPrefix -and $quoteRun -ge 3) {
                $RawDelimiterLength.Value = $quoteRun
                [void]$result.Append((' ' * $quoteRun) -join '')
                $index += $quoteRun - 1
                continue
            }
        }
        if ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            $verbatim = $false
            if ($character -eq [char]34) {
                if ($index -gt 0 -and $Text[$index - 1] -eq '@') {
                    $verbatim = $true
                }
                elseif ($index -gt 1 -and $Text[$index - 1] -eq '$' -and
                    $Text[$index - 2] -eq '@') {
                    $verbatim = $true
                }
            }
        }
        [void]$result.Append($character)
    }
    if ($quote -eq [char]34 -and $verbatim) {
        $InVerbatimString.Value = $true
    }
    return $result.ToString()
}

function Test-OwnerV2ChangedRange {
    param(
        [Parameter(Mandatory)][int]$StartLine,
        [Parameter(Mandatory)][int]$EndLine,
        [Parameter(Mandatory)][object[]]$Spans
    )

    foreach ($span in $Spans) {
        $state = [string](Get-OwnerV2Member -Value $span -Name state)
        $spanStart = Get-OwnerV2Member -Value $span -Name startLine
        $spanEnd = Get-OwnerV2Member -Value $span -Name endLine
        if ($state -cne 'complete' -or $spanStart -isnot [int] -or $spanEnd -isnot [int]) {
            continue
        }
        if ($StartLine -le $spanEnd -and $EndLine -ge $spanStart) { return $true }
    }
    return $false
}

function Split-OwnerV2AttributePrefix {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $offset = 0
    while ($offset -lt $Text.Length -and [char]::IsWhiteSpace($Text[$offset])) { $offset++ }
    if ($offset -ge $Text.Length -or $Text[$offset] -ne '[') {
        return [pscustomobject]@{ Complete = $true; AttributeText = ''; Remainder = $Text }
    }

    $start = $offset
    $depth = 0
    $quote = [char]0
    $verbatim = $false
    $escaped = $false
    for ($index = $offset; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($quote -ne [char]0) {
            if ($verbatim) {
                if ($character -eq '"' -and $index + 1 -lt $Text.Length -and $Text[$index + 1] -eq '"') {
                    $index++
                }
                elseif ($character -eq '"') {
                    $quote = [char]0
                    $verbatim = $false
                }
            }
            elseif ($escaped) {
                $escaped = $false
            }
            elseif ($character -eq [char]92) {
                $escaped = $true
            }
            elseif ($character -eq $quote) {
                $quote = [char]0
            }
            continue
        }
        if ($character -eq '"' -or $character -eq "'") {
            $quote = $character
            $verbatim = $false
            if ($character -eq [char]34) {
                if ($index -gt 0 -and $Text[$index - 1] -eq '@') {
                    $verbatim = $true
                }
                elseif ($index -gt 1 -and $Text[$index - 1] -eq '$' -and
                    $Text[$index - 2] -eq '@') {
                    $verbatim = $true
                }
            }
        }
        elseif ($character -eq '[') {
            $depth++
        }
        elseif ($character -eq ']') {
            $depth--
            if ($depth -eq 0) {
                return [pscustomobject]@{
                    Complete = $true
                    AttributeText = $Text.Substring($start, $index - $start + 1)
                    Remainder = $Text.Substring($index + 1)
                }
            }
        }
    }
    return [pscustomobject]@{ Complete = $false; AttributeText = ''; Remainder = '' }
}

function Get-OwnerV2FileConstructs {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$FileData,
        [Parameter(Mandatory)][DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits
    )

    $content = Get-OwnerV2Member -Value $FileData -Name content
    $spansValue = Get-OwnerV2Member -Value $FileData -Name spans
    $spans = @($spansValue | Where-Object { $null -ne $_ })
    if ($content -isnot [string] -or $spans.Count -eq 0) { return @() }

    $lines = [regex]::Split($content, '\r?\n')
    $constructs = [Collections.Generic.List[object]]::new()
    $pendingAttributeText = ''
    $attributeBuffer = ''
    $attributeStartLine = 0
    $inBlockComment = $false
    $inVerbatimString = $false
    $rawDelimiterLength = 0

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lineNumber = $index + 1
        $working = Remove-OwnerV2Comments -Text ([string]$lines[$index]) `
            -InBlockComment ([ref]$inBlockComment) `
            -InVerbatimString ([ref]$inVerbatimString) `
            -RawDelimiterLength ([ref]$rawDelimiterLength)

        if (-not [string]::IsNullOrEmpty($attributeBuffer)) {
            $attributeBuffer += "`n$working"
            $split = Split-OwnerV2AttributePrefix -Text $attributeBuffer
            if (-not $split.Complete) { continue }
            $pendingAttributeText = if ([string]::IsNullOrEmpty($pendingAttributeText)) {
                $split.AttributeText
            }
            else {
                $pendingAttributeText + "`n" + $split.AttributeText
            }
            $working = $split.Remainder
            $attributeBuffer = ''
        }

        while ($working.TrimStart().StartsWith('[')) {
            if ($attributeStartLine -eq 0) { $attributeStartLine = $lineNumber }
            $split = Split-OwnerV2AttributePrefix -Text $working
            if (-not $split.Complete) {
                $attributeBuffer = $working
                $working = ''
                break
            }
            $pendingAttributeText = if ([string]::IsNullOrEmpty($pendingAttributeText)) {
                $split.AttributeText
            }
            else {
                $pendingAttributeText + "`n" + $split.AttributeText
            }
            $working = $split.Remainder
        }
        if (-not [string]::IsNullOrEmpty($attributeBuffer)) { continue }

        if ([string]::IsNullOrWhiteSpace($working)) { continue }
        if ([string]::IsNullOrEmpty($pendingAttributeText)) {
            $unconsumedAttributes = @(Get-OwnerV2Attributes -Text $working)
            $hasUnconsumedTestMethod = $unconsumedAttributes -contains 'TestMethod' -or
                $unconsumedAttributes -contains 'DataTestMethod'
            if ($hasUnconsumedTestMethod -and
                (Test-OwnerV2ChangedRange -StartLine $lineNumber -EndLine $lineNumber -Spans $spans)) {
                [void]$constructs.Add([ordered]@{
                        kind = 'method'
                        name = 'unrecognized'
                        startLine = $lineNumber
                        declarationLine = $lineNumber
                        attributes = @($unconsumedAttributes)
                        hasOwner = $unconsumedAttributes -contains 'Owner'
                        snippet = $working.Trim()
                        bounded = $working.Length -le $Limits.MaximumSnippetCharacters
                        recognized = $false
                    })
            }
            continue
        }

        $attributes = Get-OwnerV2Attributes -Text $pendingAttributeText
        $kind = $null
        $name = $null
        $recognized = $true
        $trailingAttributes = @()
        $declarationMatch = $null
        $detectionText = Remove-OwnerV2StringLiterals -Text $working
        $classMatch = [regex]::Match(
            $detectionText,
            '^\s*(?:(?:public|private|protected|internal|static|sealed|abstract|partial)\s+)*' +
            'class\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)')
        if ($classMatch.Success) {
            $kind = 'class'
            $name = $classMatch.Groups['name'].Value
            $declarationMatch = $classMatch
        }
        else {
            $methodMatch = [regex]::Match(
                $detectionText,
                '^\s*(?:(?:public|private|protected|internal|static|virtual|override|abstract|' +
                'sealed|async|extern|new|partial)\s+)*(?:[A-Za-z_][A-Za-z0-9_.<>\[\],?]*\s+)+' +
                '(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]+>\s*)?\(')
            if ($methodMatch.Success) {
                $kind = 'method'
                $name = $methodMatch.Groups['name'].Value
                $declarationMatch = $methodMatch
            }
        }
        if ($null -ne $declarationMatch) {
            $trailingAttributes = @(
                Get-OwnerV2Attributes -Text (
                    $detectionText.Substring($declarationMatch.Index + $declarationMatch.Length)
                )
            )
        }
        else {
            $trailingAttributes = @(Get-OwnerV2Attributes -Text $detectionText)
        }

        $isTestMethod = $attributes -contains 'TestMethod' -or $attributes -contains 'DataTestMethod'
        $isAdvisoryClass = (($attributes -contains 'TestClass') -or
            ($null -ne $kind -and $kind -ceq 'class' -and $attributes -contains 'Owner'))
        if ($kind -ceq 'class' -and $isTestMethod -and -not $isAdvisoryClass) {
            $recognized = $false
            $kind = 'method'
            $name = 'unrecognized'
        }
        if ($null -eq $kind -and ($isTestMethod -or $isAdvisoryClass)) {
            $recognized = $false
            $kind = if ($isTestMethod) { 'method' } else { 'class' }
            $name = 'unrecognized'
        }

        if ($null -ne $kind) {
            $startLine = if ($attributeStartLine -gt 0) { $attributeStartLine } else { $lineNumber }
            $isChanged = Test-OwnerV2ChangedRange -StartLine $startLine -EndLine $lineNumber -Spans $spans
            $isEligibleConstruct = if ($kind -ceq 'method') {
                $isTestMethod
            }
            elseif ($kind -ceq 'class') {
                $isAdvisoryClass
            }
            else {
                $false
            }
            if ($isChanged -and $isEligibleConstruct) {
                $snippet = $pendingAttributeText + "`n" + $working.Trim()
                [void]$constructs.Add([ordered]@{
                        kind = $kind
                        name = $name
                        startLine = $startLine
                        declarationLine = $lineNumber
                        attributes = @($attributes)
                        hasOwner = $attributes -contains 'Owner'
                        snippet = $snippet
                        bounded = $snippet.Length -le $Limits.MaximumSnippetCharacters
                        recognized = $recognized
                    })
            }
        }
        if (($trailingAttributes -contains 'TestMethod' -or
                $trailingAttributes -contains 'DataTestMethod') -and
            (Test-OwnerV2ChangedRange -StartLine $lineNumber -EndLine $lineNumber -Spans $spans)) {
            [void]$constructs.Add([ordered]@{
                    kind = 'method'
                    name = 'unrecognized'
                    startLine = $lineNumber
                    declarationLine = $lineNumber
                    attributes = @($trailingAttributes)
                    hasOwner = $trailingAttributes -contains 'Owner'
                    snippet = $working.Trim()
                    bounded = $working.Length -le $Limits.MaximumSnippetCharacters
                    recognized = $false
                })
        }

        $pendingAttributeText = ''
        $attributeStartLine = 0
    }

    if (-not [string]::IsNullOrEmpty($pendingAttributeText) -or
        -not [string]::IsNullOrEmpty($attributeBuffer)) {
        $residualText = $pendingAttributeText + "`n" + $attributeBuffer
        $attributes = Get-OwnerV2Attributes -Text $residualText
        $isTestMethod = $attributes -contains 'TestMethod' -or $attributes -contains 'DataTestMethod'
        $isAdvisoryClass = $attributes -contains 'TestClass' -or $attributes -contains 'Owner'
        if (($isTestMethod -or $isAdvisoryClass) -and
            (Test-OwnerV2ChangedRange -StartLine $attributeStartLine -EndLine $lines.Count -Spans $spans)) {
            [void]$constructs.Add([ordered]@{
                    kind = if ($isTestMethod) { 'method' } else { 'class' }
                    name = 'unrecognized'
                    startLine = $attributeStartLine
                    declarationLine = $lines.Count
                    attributes = @($attributes)
                    hasOwner = $attributes -contains 'Owner'
                    snippet = $residualText
                    bounded = $residualText.Length -le $Limits.MaximumSnippetCharacters
                    recognized = $false
                })
        }
    }

    return @($constructs)
}

function Invoke-OwnerV2Judgment {
    param(
        [Parameter(Mandatory)][object]$Runner,
        [Parameter(Mandatory)][Collections.IDictionary]$Request
    )

    $beforeDigest = Get-OwnerV2Digest -Value $Request
    try {
        $handler = $Runner.Handler
        $values = @(& $handler ([pscustomobject]$Request))
        $afterDigest = Get-OwnerV2Digest -Value $Request
        if ($afterDigest -cne $beforeDigest -or
            $values.Count -ne 1 -or
            $values[0] -isnot [Collections.IDictionary]) {
            return [pscustomobject]@{ Valid = $false; Judgment = 'unknown'; Failure = 'runner-response-invalid' }
        }
        $response = $values[0]
        $keys = @($response.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        if ($keys.Count -ne 3 -or
            ($keys -join '|') -cne 'executionUnitId|judgment|schemaVersion' -or
            $response['schemaVersion'] -ne 2 -or
            [string]$response['executionUnitId'] -cne [string]$Request['executionUnitId'] -or
            [string]$response['judgment'] -cnotin $script:OwnerV2Judgments) {
            return [pscustomobject]@{ Valid = $false; Judgment = 'unknown'; Failure = 'runner-response-invalid' }
        }
        return [pscustomobject]@{
            Valid = $true
            Judgment = [string]$response['judgment']
            Failure = $null
        }
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Judgment = 'unknown'; Failure = 'runner-failed' }
    }
}

function New-OwnerV2UnknownEvidenceAssessments {
    param(
        [Parameter(Mandatory)][object[]]$EvidenceUnits,
        [Parameter(Mandatory)][string]$BindingId
    )

    return @(
        foreach ($unit in $EvidenceUnits) {
            $unitId = [string](Get-OwnerV2Member -Value $unit -Name unitId)
            if ([string]::IsNullOrWhiteSpace($unitId)) { continue }
            $prefix = if ($unitId -like 'file:*') { 'file' } else { 'evidence' }
            [ordered]@{
                assessmentId = $prefix + ':' + (Get-OwnerV2Digest -Value "$BindingId|$unitId").Substring(10)
                evidenceUnitIds = @($unitId)
                state = 'unknown'
                findings = @()
            }
        }
    )
}

function Invoke-OwnerV2CapabilityResponse {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$Runner,
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest,
        [Parameter(Mandatory)][DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits
    )

    $binding = Get-OwnerV2Member -Value $Context -Name binding
    $evidence = Get-OwnerV2Member -Value $Context -Name evidence
    $bindingId = [string](Get-OwnerV2Member -Value $binding -Name BindingId)
    $evidenceBindingId = [string](Get-OwnerV2Member -Value $evidence -Name bindingId)
    $evidenceDigest = [string](Get-OwnerV2Member -Value $evidence -Name evidenceDigest)
    $evidenceUnits = @(Get-OwnerV2Member -Value $evidence -Name evidenceUnits)
    if ([string]::IsNullOrWhiteSpace($bindingId) -or
        $evidenceBindingId -cne $bindingId -or
        $evidenceDigest -cnotmatch $script:OwnerV2DigestPattern) {
        throw 'Capability context did not preserve the facade binding and evidence digest.'
    }

    $diagnostics = [Collections.Generic.List[object]]::new()
    $identityUnit = @($evidenceUnits | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name unitId) -ceq 'identity'
        })
    $ruleUnit = @($evidenceUnits | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name unitId) -ceq 'rule'
        })
    $fileUnits = @($evidenceUnits | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name unitId) -like 'file:*'
        } | Sort-Object { [string](Get-OwnerV2Member -Value $_ -Name unitId) })

    $identityData = if ($identityUnit.Count -eq 1) {
        Get-OwnerV2Member -Value $identityUnit[0] -Name data
    }
    else { $null }
    $ruleData = if ($ruleUnit.Count -eq 1) {
        Get-OwnerV2Member -Value $ruleUnit[0] -Name data
    }
    else { $null }
    $controlsComplete = (
        $identityUnit.Count -eq 1 -and
        [string](Get-OwnerV2Member -Value $identityUnit[0] -Name state) -ceq 'complete' -and
        $ruleUnit.Count -eq 1 -and
        [string](Get-OwnerV2Member -Value $ruleUnit[0] -Name state) -ceq 'complete' -and
        [string](Get-OwnerV2Member -Value $identityData -Name capabilityId) -ceq $CapabilityId -and
        [string](Get-OwnerV2Member -Value $identityData -Name capabilityDigest) -ceq $CapabilityDigest -and
        [string](Get-OwnerV2Member -Value $identityData -Name sourceCommit) -cmatch $script:OwnerV2CommitPattern -and
        [string](Get-OwnerV2Member -Value $ruleData -Name hash) -cmatch $script:OwnerV2DigestPattern -and
        (Get-OwnerV2Member -Value $ruleData -Name content) -is [string]
    )
    if (-not $controlsComplete -or $fileUnits.Count -gt $Limits.MaximumFiles) {
        Add-OwnerV2Diagnostic -Diagnostics $diagnostics -Limits $Limits `
            -Code 'capability-evidence-unknown' `
            -Message 'Required identity, rule, or bounded file evidence was incomplete or unknown.'
        return [ordered]@{
            schemaVersion = 1
            bindingId = $bindingId
            state = 'unknown'
            assessments = New-OwnerV2UnknownEvidenceAssessments `
                -EvidenceUnits $evidenceUnits -BindingId $bindingId
            diagnostics = @($diagnostics)
        }
    }

    $ruleRef = 'rule:' + (Get-OwnerV2Digest -Value ([ordered]@{
                repositoryId = Get-OwnerV2Member -Value $ruleData -Name repositoryId
                path = Get-OwnerV2Member -Value $ruleData -Name path
                commit = Get-OwnerV2Member -Value $ruleData -Name commit
                section = Get-OwnerV2Member -Value $ruleData -Name section
                hash = Get-OwnerV2Member -Value $ruleData -Name hash
            })).Substring(10)
    $assessments = [Collections.Generic.List[object]]::new()
    [void]$assessments.Add([ordered]@{
            assessmentId = 'binding:' + (Get-OwnerV2Digest -Value "$bindingId|$ruleRef").Substring(10)
            evidenceUnitIds = @('identity', 'rule')
            state = 'complete'
            findings = @()
        })

    $semanticUnitCount = 0
    foreach ($fileUnit in $fileUnits) {
        $fileUnitId = [string](Get-OwnerV2Member -Value $fileUnit -Name unitId)
        $fileState = [string](Get-OwnerV2Member -Value $fileUnit -Name state)
        $fileData = Get-OwnerV2Member -Value $fileUnit -Name data
        $path = [string](Get-OwnerV2Member -Value $fileData -Name path)
        $atomicEvidenceIds = @('identity', 'rule', $fileUnitId)
        if ($fileState -cne 'complete' -or [string]::IsNullOrWhiteSpace($path)) {
            [void]$assessments.Add([ordered]@{
                    assessmentId = 'file:' + (Get-OwnerV2Digest -Value "$bindingId|$fileUnitId").Substring(10)
                    evidenceUnitIds = $atomicEvidenceIds
                    state = 'unknown'
                    findings = @()
                })
            continue
        }

        $constructs = @(if ($path.EndsWith('.cs', [StringComparison]::OrdinalIgnoreCase)) {
            @(Get-OwnerV2FileConstructs -FileData $fileData -Limits $Limits)
        }
        else {
            @()
        })
        if ($constructs.Count -eq 0) {
            [void]$assessments.Add([ordered]@{
                    assessmentId = 'file:' + (Get-OwnerV2Digest -Value "$bindingId|$fileUnitId").Substring(10)
                    evidenceUnitIds = $atomicEvidenceIds
                    state = 'complete'
                    findings = @()
                })
            continue
        }
        if ($semanticUnitCount + $constructs.Count -gt $Limits.MaximumSemanticUnits) {
            Add-OwnerV2Diagnostic -Diagnostics $diagnostics -Limits $Limits `
                -Code 'semantic-unit-cap-exhausted' `
                -Message 'A file exceeded the remaining bounded semantic-unit capacity.' `
                -UnitId $fileUnitId
            [void]$assessments.Add([ordered]@{
                    assessmentId = 'file:' + (Get-OwnerV2Digest -Value "$bindingId|$fileUnitId").Substring(10)
                    evidenceUnitIds = $atomicEvidenceIds
                    state = 'unknown'
                    findings = @()
                })
            continue
        }

        foreach ($construct in $constructs) {
            $semanticUnitCount++
            $constructMaterial = [ordered]@{
                bindingId = $bindingId
                evidenceDigest = $evidenceDigest
                capabilityId = $CapabilityId
                capabilityDigest = $CapabilityDigest
                ruleRef = $ruleRef
                evidenceUnitId = $fileUnitId
                path = $path
                kind = $construct.kind
                name = $construct.name
                startLine = $construct.startLine
                declarationLine = $construct.declarationLine
                attributes = @($construct.attributes)
                hasOwner = [bool]$construct.hasOwner
                recognized = [bool]$construct.recognized
                snippet = $construct.snippet
            }
            $constructDigest = (Get-OwnerV2Digest -Value $constructMaterial).Substring(10)
            $constructRef = 'construct:' + $constructDigest
            $assessmentId = "$($construct.kind):n:$constructDigest"

            if ($construct.kind -ceq 'class' -or
                -not [bool]$construct.bounded -or
                -not [bool]$construct.recognized) {
                if (-not [bool]$construct.recognized) {
                    Add-OwnerV2Diagnostic -Diagnostics $diagnostics -Limits $Limits `
                        -Code 'construct-unrecognized' `
                        -Message "Changed attributed construct at '$fileUnitId' could not be recognized and remains unknown." `
                        -UnitId $fileUnitId
                }
                [void]$assessments.Add([ordered]@{
                        assessmentId = $assessmentId
                        evidenceUnitIds = $atomicEvidenceIds
                        state = 'unknown'
                        findings = @()
                    })
                continue
            }
            if ([bool]$construct.hasOwner) {
                    [void]$assessments.Add([ordered]@{
                            assessmentId = $assessmentId
                            evidenceUnitIds = $atomicEvidenceIds
                            state = 'complete'
                            findings = @()
                        })
                    continue
            }

            $assessmentId = "method:r:$constructDigest"
            $executionUnitId = 'unit:' + (Get-OwnerV2Digest -Value ([ordered]@{
                            semantics = $script:OwnerV2RunnerSemantics
                        construct = $constructMaterial
                    })).Substring(10)
            $request = [ordered]@{
                schemaVersion = 2
                semantics = $script:OwnerV2RunnerSemantics
                executionUnitId = $executionUnitId
                capability = [ordered]@{
                    id = $CapabilityId
                    digest = $CapabilityDigest
                }
                rule = [ordered]@{
                    ref = $ruleRef
                    content = [string](Get-OwnerV2Member -Value $ruleData -Name content)
                }
                construct = [ordered]@{
                    kind = 'method'
                    name = [string]$construct.name
                    attributes = @($construct.attributes)
                    snippet = [string]$construct.snippet
                }
            }
            $judgment = Invoke-OwnerV2Judgment -Runner $Runner -Request $request
            if (-not $judgment.Valid) {
                Add-OwnerV2Diagnostic -Diagnostics $diagnostics -Limits $Limits `
                    -Code $judgment.Failure `
                    -Message "Semantic unit '$executionUnitId' returned no usable judgment and remains unknown." `
                    -UnitId $executionUnitId
            }
            $assessmentState = if ($judgment.Valid -and $judgment.Judgment -cne 'unknown') {
                'complete'
            }
            else {
                'unknown'
            }
            $findings = @()
            if ($assessmentState -ceq 'complete' -and $judgment.Judgment -ceq 'violation') {
                $findingId = 'owner-v2:' + (Get-OwnerV2Digest -Value ([ordered]@{
                            bindingId = $bindingId
                            capabilityId = $CapabilityId
                            ruleRef = $ruleRef
                            constructRef = $constructRef
                            disposition = 'violation'
                        })).Substring(10)
                $findings = @(
                    [ordered]@{
                        findingId = $findingId
                        summary = 'Changed MSTest method lacks an Owner attribute.'
                        data = [ordered]@{
                            disposition = 'violation'
                            eligibility = 'changed-mstest-method'
                            capabilityId = $CapabilityId
                            bindingId = $bindingId
                            evidenceDigest = $evidenceDigest
                            ruleRef = $ruleRef
                            constructRef = $constructRef
                            groupRef = $assessmentId
                            headCommit = [string](Get-OwnerV2Member -Value $identityData -Name sourceCommit)
                            anchor = [ordered]@{
                                path = $path
                                line = [int]$construct.declarationLine
                                symbol = [string]$construct.name
                            }
                        }
                    }
                )
            }
            [void]$assessments.Add([ordered]@{
                    assessmentId = $assessmentId
                    evidenceUnitIds = $atomicEvidenceIds
                    state = $assessmentState
                    findings = $findings
                })
        }
    }

    $assessmentStates = @($assessments | ForEach-Object { $_['state'] })
    return [ordered]@{
        schemaVersion = 1
        bindingId = $bindingId
        state = if ($assessmentStates -contains 'unknown') { 'unknown' } else { 'complete' }
        assessments = @($assessments)
        diagnostics = @($diagnostics)
    }
}

function New-OwnerV2CapabilityAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Runner,
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest,
        [DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits = (New-OwnerV2CapabilityLimits),
        [string]$Name = 'owner-v2-semantic-capability'
    )

    Test-OwnerV2Runner -Runner $Runner
    Assert-OwnerV2Text -Value $CapabilityId -Name CapabilityId -MaximumLength 256
    Assert-OwnerV2Text -Value $Name -Name Name -MaximumLength 128
    if ($CapabilityDigest -cnotmatch $script:OwnerV2DigestPattern) {
        throw 'CapabilityDigest must be a lowercase v1 SHA-256 digest.'
    }
    $capturedRunner = $Runner
    $capturedCapabilityId = $CapabilityId
    $capturedCapabilityDigest = $CapabilityDigest
    $capturedLimits = $Limits
    $invokeCommand = Get-Command Invoke-OwnerV2CapabilityResponse -CommandType Function
    return New-OwnerPipelineAdapter -Stage capability -Name $Name -Handler {
        param($context)
        return & $invokeCommand `
            -Context $context `
            -Runner $capturedRunner `
            -CapabilityId $capturedCapabilityId `
            -CapabilityDigest $capturedCapabilityDigest `
            -Limits $capturedLimits
    }.GetNewClosure()
}

function ConvertTo-OwnerV2Observation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$PipelineResult,
        [object]$Runner,
        [string]$ImplementationId = 'owner-v2-preview',
        [string]$ImplementationVersion = '0.1'
    )

    Assert-OwnerV2Text -Value $ImplementationId -Name ImplementationId -MaximumLength 128
    Assert-OwnerV2Text -Value $ImplementationVersion -Name ImplementationVersion -MaximumLength 64
    $evidence = Get-OwnerV2Member -Value $PipelineResult -Name evidence
    $validation = Get-OwnerV2Member -Value $PipelineResult -Name validation
    $preview = Get-OwnerV2Member -Value $PipelineResult -Name preview
    if ($null -eq $evidence -or $null -eq $validation -or $null -eq $preview) {
        throw 'A completed facade result with evidence, validation, and preview is required.'
    }

    $units = @(Get-OwnerV2Member -Value $evidence -Name evidenceUnits)
    $identityMatches = @($units | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name unitId) -ceq 'identity'
        } | Select-Object -First 1)
    $ruleMatches = @($units | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name unitId) -ceq 'rule'
        } | Select-Object -First 1)
    $identityUnit = if ($identityMatches.Count -eq 1) { $identityMatches[0] } else { $null }
    $ruleUnit = if ($ruleMatches.Count -eq 1) { $ruleMatches[0] } else { $null }
    if ($null -eq $identityUnit -or $null -eq $ruleUnit) {
        throw 'The facade result did not contain the normalized identity and rule evidence units.'
    }
    $identity = Get-OwnerV2Member -Value $identityUnit -Name data
    $rule = Get-OwnerV2Member -Value $ruleUnit -Name data
    $assessments = @(Get-OwnerV2Member -Value $validation -Name assessments)
    $methodAssessments = @($assessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name assessmentId) -like 'method:*'
        })
    $classAssessments = @($assessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name assessmentId) -like 'class:*'
        })
    $unknownFileAssessments = @($assessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name assessmentId) -like 'file:*' -and
            [string](Get-OwnerV2Member -Value $_ -Name state) -ceq 'unknown'
        })
    $unknownEvidenceAssessments = @($assessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name assessmentId) -like 'evidence:*' -and
            [string](Get-OwnerV2Member -Value $_ -Name state) -ceq 'unknown'
        })
    $previewFindings = @(Get-OwnerV2Member -Value $preview -Name findings)
    $ruleHash = [string](Get-OwnerV2Member -Value $rule -Name hash)
    $ruleSha = if ($ruleHash -match $script:OwnerV2DigestPattern) { $ruleHash.Substring(10) } else { 'unknown' }
    $ruleRef = if ($previewFindings.Count -gt 0) {
        [string](Get-OwnerV2Member -Value (
                Get-OwnerV2Member -Value $previewFindings[0] -Name data
            ) -Name ruleRef)
    }
    else {
        'rule:' + (Get-OwnerV2Digest -Value ([ordered]@{
                    repositoryId = Get-OwnerV2Member -Value $rule -Name repositoryId
                    path = Get-OwnerV2Member -Value $rule -Name path
                    commit = Get-OwnerV2Member -Value $rule -Name commit
                    section = Get-OwnerV2Member -Value $rule -Name section
                    hash = $ruleHash
                })).Substring(10)
    }
    $observationSubject = [ordered]@{
        pullRequestId = Get-OwnerV2Member -Value $identity -Name pullRequestId
        repositoryId = [string](Get-OwnerV2Member -Value $identity -Name repositoryId)
        headCommit = [string](Get-OwnerV2Member -Value $identity -Name sourceCommit)
        targetCommit = [string](Get-OwnerV2Member -Value $identity -Name targetCommit)
        targetRef = [string](Get-OwnerV2Member -Value $identity -Name targetRef)
    }
    $observationRule = [ordered]@{
        identity = $ruleRef
        path = ConvertTo-OwnerRepositoryPath `
            -Path ([string](Get-OwnerV2Member -Value $rule -Name path))
        section = [string](Get-OwnerV2Member -Value $rule -Name section)
        commit = [string](Get-OwnerV2Member -Value $rule -Name commit)
        sha256 = $ruleSha
    }

    $normalizedFindings = [Collections.Generic.List[object]]::new()
    foreach ($finding in $previewFindings) {
        $data = Get-OwnerV2Member -Value $finding -Name data
        $anchor = Get-OwnerV2Member -Value $data -Name anchor
        $constructRef = [string](Get-OwnerV2Member -Value $data -Name constructRef)
        $binding = New-OwnerCanonicalAnchor `
            -Path ([string](Get-OwnerV2Member -Value $anchor -Name path)) `
            -StartLine ([int](Get-OwnerV2Member -Value $anchor -Name line)) `
            -EndLine ([int](Get-OwnerV2Member -Value $anchor -Name line)) `
            -Symbol ([string](Get-OwnerV2Member -Value $anchor -Name symbol)) `
            -ConstructIdentity $constructRef
        [void]$normalizedFindings.Add([ordered]@{
                identity = [string](Get-OwnerV2Member -Value $finding -Name findingId)
                semanticKey = Get-OwnerSemanticFindingKey `
                    -Subject $observationSubject -Rule $observationRule `
                    -Capability ([string](Get-OwnerV2Member -Value $identity -Name capabilityId)) `
                    -Binding $binding
                providerMarker = New-OwnerProviderMarker
                disposition = 'violation'
                ruleRef = [string](Get-OwnerV2Member -Value $data -Name ruleRef)
                constructRef = $constructRef
                anchor = [ordered]@{
                    path = [string](Get-OwnerV2Member -Value $anchor -Name path)
                    line = [int](Get-OwnerV2Member -Value $anchor -Name line)
                    symbol = [string](Get-OwnerV2Member -Value $anchor -Name symbol)
                }
                binding = $binding
            })
    }
    foreach ($assessment in @($methodAssessments | Where-Object {
                [string](Get-OwnerV2Member -Value $_ -Name state) -ceq 'unknown'
            })) {
        $assessmentId = [string](Get-OwnerV2Member -Value $assessment -Name assessmentId)
        [void]$normalizedFindings.Add([ordered]@{
                identity = 'unknown:' + $assessmentId
                semanticKey = 'unknown'
                providerMarker = New-OwnerProviderMarker
                disposition = 'unknown'
                ruleRef = $ruleRef
                constructRef = 'construct:' + ($assessmentId -split ':')[-1]
                anchor = 'unknown'
                binding = 'unknown'
            })
    }
    $sortedFindings = @($normalizedFindings | Sort-Object identity)
    $unknownCount = @($methodAssessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name state) -ceq 'unknown'
        }).Count
    $eligibleCount = $methodAssessments.Count
    $advisoryCount = $classAssessments.Count
    $checkedCount = @($methodAssessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name state) -ceq 'complete'
        }).Count
    $runnerAttemptCount = @($methodAssessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name assessmentId) -like 'method:r:*'
        }).Count
    $modelStarts = 'unknown'
    $latencyMs = 'unknown'
    $refusalReason = 'unknown'
    if ($null -ne $Runner) {
        Test-OwnerV2Runner -Runner $Runner
        if ($null -eq $Runner.PSObject.Properties['TelemetryProvider']) {
            throw 'The supplied semantic runner does not expose observation telemetry.'
        }
        $telemetryValues = @(& $Runner.TelemetryProvider)
        if ($telemetryValues.Count -ne 1 -or
            $telemetryValues[0] -isnot [Collections.IDictionary]) {
            throw 'Semantic runner telemetry violated the observation contract.'
        }
        $telemetry = $telemetryValues[0]
        $attemptsValue = Get-OwnerV2Member -Value $telemetry -Name attempts
        $modelStartsValue = Get-OwnerV2Member -Value $telemetry -Name modelStarts
        $latencyValue = Get-OwnerV2Member -Value $telemetry -Name latencyMs
        $refusalValue = Get-OwnerV2Member -Value $telemetry -Name refusalReason
        if ($attemptsValue -is [bool] -or
            $attemptsValue -isnot [int] -and $attemptsValue -isnot [long] -or
            [long]$attemptsValue -lt 0 -or [long]$attemptsValue -gt 1024 -or
            $modelStartsValue -is [bool] -or
            $modelStartsValue -isnot [int] -and $modelStartsValue -isnot [long] -or
            [long]$modelStartsValue -lt 0 -or [long]$modelStartsValue -gt [long]$attemptsValue -or
            $latencyValue -is [bool] -or
            $latencyValue -isnot [int] -and $latencyValue -isnot [long] -or
            [long]$latencyValue -lt 0 -or [long]$latencyValue -gt 86400000 -or
            $refusalValue -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$refusalValue) -or
            [string]$refusalValue -cne ([string]$refusalValue).Trim() -or
            ([string]$refusalValue).Length -gt 128 -or
            [string]$refusalValue -match '[\r\n]') {
            throw 'Semantic runner telemetry contained invalid aggregate values.'
        }
        $runnerAttemptCount = [int]$attemptsValue
        $modelStarts = [int]$modelStartsValue
        $latencyMs = [long]$latencyValue
        $refusalReason = [string]$refusalValue
    }
    $uncoveredCount = $unknownFileAssessments.Count + $unknownEvidenceAssessments.Count
    $pipelineState = [string](Get-OwnerV2Member -Value $PipelineResult -Name state)
    # Class assessments are advisory-only; completion reflects eligible methods and coverage.
    $completed = $pipelineState -cne 'failed' -and
        $unknownCount -eq 0 -and $uncoveredCount -eq 0
    $diagnostics = @(Get-OwnerV2Member -Value $PipelineResult -Name diagnostics)
    $validationErrors = @(
        foreach ($diagnostic in $diagnostics | Select-Object -First 32) {
            $code = [string](Get-OwnerV2Member -Value $diagnostic -Name code)
            $message = [string](Get-OwnerV2Member -Value $diagnostic -Name message)
            $text = if ([string]::IsNullOrWhiteSpace($code)) { $message } else { "$code`: $message" }
            if ($text.Length -gt 512) { $text.Substring(0, 512) } else { $text }
        }
    )
    $evidenceDigest = [string](Get-OwnerV2Member -Value $evidence -Name evidenceDigest)
    $artifactDigest = if ($evidenceDigest -match $script:OwnerV2DigestPattern) {
        $evidenceDigest.Substring(10)
    }
    else {
        (Get-OwnerV2Digest -Value $evidenceDigest).Substring(10)
    }

    return [ordered]@{
        schemaVersion = 2
        kind = 'owner-observation'
        implementation = [ordered]@{
            id = $ImplementationId
            version = $ImplementationVersion
        }
        capability = [string](Get-OwnerV2Member -Value $identity -Name capabilityId)
        subject = $observationSubject
        rule = $observationRule
        lifecycle = [ordered]@{
            status = if ($completed) { 'completed' } elseif ($pipelineState -ceq 'failed') { 'blocked' } else { 'incomplete' }
            prepared = $true
            completed = $completed
            incomplete = -not $completed
            pending = $false
        }
        counts = [ordered]@{
            checked = $checkedCount
            eligible = $eligibleCount
            advisory = $advisoryCount
            violations = $previewFindings.Count
            unknown = $unknownCount
            uncovered = $uncoveredCount
        }
        findingsComplete = $completed
        findings = $sortedFindings
        execution = [ordered]@{
            attempts = $runnerAttemptCount
            modelStarts = $modelStarts
            latencyMs = $latencyMs
            refusalReason = $refusalReason
            incompleteReason = if ($completed) { 'unknown' } else { 'semantic-or-evidence-unknown' }
        }
        effects = [ordered]@{
            providerWrites = 0
            writeToolInvocations = 0
            dedupe = [ordered]@{
                created = 0
                updated = 0
                noOp = if ($completed -and $previewFindings.Count -eq 0) { 1 } else { 0 }
                wouldCreate = 0
                wouldUpdate = 0
                unknown = if ($completed) {
                    $previewFindings.Count
                }
                else {
                    [Math]::Max(1, $previewFindings.Count + $unknownCount + $uncoveredCount)
                }
            }
            operatorIntervention = $true
        }
        measurements = [ordered]@{
            counts = [ordered]@{
                checked = New-OwnerMeasurement -Status measured -Value $checkedCount
                eligible = New-OwnerMeasurement -Status measured -Value $eligibleCount
                advisory = New-OwnerMeasurement -Status measured -Value $advisoryCount
                violations = New-OwnerMeasurement -Status measured -Value $previewFindings.Count
                unknown = New-OwnerMeasurement -Status measured -Value $unknownCount
                uncovered = New-OwnerMeasurement -Status measured -Value $uncoveredCount
            }
            execution = [ordered]@{
                attempts = New-OwnerMeasurement -Status measured -Value $runnerAttemptCount
                modelStarts = $(if ($modelStarts -is [string]) {
                        New-OwnerMeasurement -Status notMeasured -Reason 'runner-telemetry-not-requested'
                    }
                    else {
                        New-OwnerMeasurement -Status measured -Value $modelStarts
                    })
                latencyMs = $(if ($latencyMs -is [string]) {
                        New-OwnerMeasurement -Status notMeasured -Reason 'runner-telemetry-not-requested'
                    }
                    else {
                        New-OwnerMeasurement -Status measured -Value $latencyMs
                    })
            }
            effects = [ordered]@{
                providerWrites = New-OwnerMeasurement -Status measured -Value 0
                writeToolInvocations = New-OwnerMeasurement -Status measured -Value 0
                operatorIntervention = New-OwnerMeasurement -Status measured -Value $true
            }
        }
        sourceArtifacts = @(
            [ordered]@{
                kind = 'owner-v2-evidence-envelope'
                sha256 = $artifactDigest
                signature = 'not-applicable'
            }
        )
        validationErrors = $validationErrors
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-OwnerV2Observation',
    'New-OwnerSemanticRunner',
    'New-OwnerV2CapabilityAdapter',
    'New-OwnerV2CapabilityLimits'
)
