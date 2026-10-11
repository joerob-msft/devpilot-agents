#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NamedAreEqualUnknownReasonCodes = @(
    'receiver-spelling-uncertain'
    'receiver-shadowing-uncertain'
    'source-structure-uncertain'
    'call-shape-uncertain'
    'changed-anchor-uncertain'
    'test-context-uncertain'
    'symbol-identity-uncertain'
    'argument-segment-empty'
    'argument-terminal-uncertain'
    'argument-leading-token-uncertain'
    'named-argument-value-missing'
    'argument-count-insufficient'
    'generic-angle-parse-uncertain'
    'same-line-call-ambiguity'
    'group-cardinality-exceeded'
)

function Add-NamedAreEqualUnknownReason {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Reasons,
        [Parameter(Mandatory)][string]$Code
    )
    if ($Code -cnotin $script:NamedAreEqualUnknownReasonCodes) {
        throw "Unrecognized Named AreEqual parser diagnostic code '$Code'."
    }
    [void]$Reasons.Add($Code)
}

function Get-NamedAreEqualUnknownReasonSummary {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Reasons
    )
    $counts = @{}
    foreach ($code in $Reasons) {
        if ($code -cnotin $script:NamedAreEqualUnknownReasonCodes) {
            throw "Unrecognized Named AreEqual parser diagnostic code '$code'."
        }
        if (-not $counts.ContainsKey($code)) { $counts[$code] = 0 }
        $counts[$code]++
    }
    return @(
        foreach ($code in $script:NamedAreEqualUnknownReasonCodes) {
            if ($counts.ContainsKey($code)) {
                [ordered]@{
                    code = $code
                    count = [int]$counts[$code]
                }
            }
        }
    )
}

function Get-CoverageMember {
    param([object]$Value, [string]$Name)
    if ($Value -is [Collections.IDictionary]) { return $Value[$Name] }
    if ($null -ne $Value) { return $Value.PSObject.Properties[$Name].Value }
    return $null
}

function Test-CoverageChanged {
    param([int]$First, [int]$Last, [object[]]$Ranges)
    foreach ($range in $Ranges) {
        if ($First -le $range.end -and $Last -ge $range.start) { return $true }
    }
    return $false
}

function Get-CoverageTokens {
    param([string]$Text, [switch]$IncludeLiteralTokens)
    $tokens = [Collections.Generic.List[object]]::new()
    $length = $Text.Length
    $i = 0
    $line = 1
    $conditional = $false
    $unterminated = $false
    while ($i -lt $length) {
        $ch = $Text[$i]
        if ($ch -eq "`n" -or ($ch -eq "`r" -and
                ($i + 1 -ge $length -or $Text[$i + 1] -ne "`n"))) { $line++ }
        if ([char]::IsWhiteSpace($ch)) { $i++; continue }
        if ($ch -eq '#' -and ($i -eq 0 -or $Text[$i - 1] -eq "`n" -or
                $Text[$i - 1] -eq "`r" -or
                $Text.Substring([Math]::Max(0, $Text.LastIndexOf("`n", $i - 1) + 1),
                    $i - [Math]::Max(0, $Text.LastIndexOf("`n", $i - 1) + 1)).Trim().Length -eq 0)) {
            $begin = $i
            while ($i -lt $length -and $Text[$i] -ne "`n" -and $Text[$i] -ne "`r") { $i++ }
            if ($Text.Substring($begin, $i - $begin) -match '^#\s*(if|elif|else|endif|define|undef)\b') {
                $conditional = $true
            }
            continue
        }
        if ($ch -eq '/' -and $i + 1 -lt $length -and $Text[$i + 1] -eq '/') {
            $i += 2
            while ($i -lt $length -and $Text[$i] -ne "`n" -and $Text[$i] -ne "`r") { $i++ }
            continue
        }
        if ($ch -eq '/' -and $i + 1 -lt $length -and $Text[$i + 1] -eq '*') {
            $i += 2
            $closed = $false
            while ($i -lt $length) {
                if ($Text[$i] -eq '*' -and $i + 1 -lt $length -and $Text[$i + 1] -eq '/') {
                    $i += 2; $closed = $true; break
                }
                if ($Text[$i] -eq "`n" -or ($Text[$i] -eq "`r" -and
                        ($i + 1 -ge $length -or $Text[$i + 1] -ne "`n"))) { $line++ }
                $i++
            }
            if (-not $closed) { $unterminated = $true }
            continue
        }
        $prefix = $i
        while ($i -lt $length -and ($Text[$i] -eq '$' -or $Text[$i] -eq '@') -and
            $i - $prefix -lt 9) { $i++ }
        if ($i -lt $length -and $Text[$i] -eq '"' -or
            ($i -eq $prefix -and $ch -eq "'")) {
            $literalLine = $line
            $quote = $Text[$i]
            $interpolated = $Text.Substring($prefix, $i - $prefix).Contains('$')
            $verbatim = $Text.Substring($prefix, $i - $prefix).Contains('@')
            $run = 0
            if ($quote -eq '"') {
                while ($i + $run -lt $length -and $Text[$i + $run] -eq '"') { $run++ }
            }
            $raw = $run -ge 3
            $i += $(if ($raw) { $run } else { 1 })
            $closed = $false
            while ($i -lt $length) {
                $current = $Text[$i]
                if ($current -eq "`n" -or ($current -eq "`r" -and
                        ($i + 1 -ge $length -or $Text[$i + 1] -ne "`n"))) {
                    $line++
                    if (-not $raw -and -not $verbatim) { $unterminated = $true }
                }
                if ($raw -and $current -eq '"') {
                    $endRun = 0
                    while ($i + $endRun -lt $length -and $Text[$i + $endRun] -eq '"') { $endRun++ }
                    if ($endRun -ge $run) { $i += $endRun; $closed = $true; break }
                    $i += $endRun; continue
                }
                if ($interpolated -and $current -eq '{') {
                    if ($i + 1 -lt $length -and $Text[$i + 1] -eq '{') {
                        $i += 2; continue
                    }
                    $holeEnd = $Text.IndexOf('}', $i + 1,
                        [Math]::Min(4096, $length - $i - 1))
                    if ($holeEnd -lt 0 -or
                        $Text.Substring($i + 1, $holeEnd - $i - 1) -match '["'']|/\*|//') {
                        $unterminated = $true
                    }
                }
                if (-not $raw -and $current -eq '\' -and -not $verbatim) {
                    if ($i + 1 -lt $length -and $Text[$i + 1] -eq "`n") { $line++ }
                    $i += [Math]::Min(2, $length - $i); continue
                }
                if (-not $raw -and $current -eq $quote) {
                    if ($verbatim -and $i + 1 -lt $length -and $Text[$i + 1] -eq '"') {
                        $i += 2; continue
                    }
                    $i++; $closed = $true; break
                }
                $i++
            }
            if (-not $closed) { $unterminated = $true }
            if ($IncludeLiteralTokens) {
                [void]$tokens.Add(@{ text = '__literal__'; line = $literalLine })
            }
            continue
        }
        $i = $prefix
        $start = $i
        if ([char]::IsLetter($ch) -or $ch -eq '_' -or
            ($ch -eq '@' -and $i + 1 -lt $length -and
                ([char]::IsLetter($Text[$i + 1]) -or $Text[$i + 1] -eq '_'))) {
            $i++
            while ($i -lt $length -and ([char]::IsLetterOrDigit($Text[$i]) -or
                    $Text[$i] -eq '_' -or [char]::GetUnicodeCategory($Text[$i]) -eq
                    [Globalization.UnicodeCategory]::NonSpacingMark)) { $i++ }
        }
        elseif ([char]::IsDigit($ch)) {
            $i++
            while ($i -lt $length -and [char]::IsLetterOrDigit($Text[$i])) { $i++ }
        }
        else {
            $i++
            if ($ch -eq ':' -and $i -lt $length -and $Text[$i] -eq ':') { $i++ }
        }
        [void]$tokens.Add(@{ text = $Text.Substring($start, $i - $start); line = $line })
        if ($tokens.Count -gt 200000 -or $line -gt 200000) {
            throw 'C# coverage input exceeds the bounded token or line limit.'
        }
    }
    return @{ tokens = $tokens; conditional = $conditional; unterminated = $unterminated }
}

function Get-CoverageAttributeNames {
    param([object[]]$Tokens, [int]$First, [int]$Last)
    $names = [Collections.Generic.List[string]]::new()
    $segment = $First + 1
    $paren = 0
    $bracket = 0
    for ($i = $segment; $i -le $Last; $i++) {
        $text = if ($i -eq $Last) { ',' } else { $Tokens[$i].text }
        if ($text -eq '(') { $paren++ }
        elseif ($text -eq ')') { $paren-- }
        elseif ($text -eq '[') { $bracket++ }
        elseif ($text -eq ']') { $bracket-- }
        if ($text -eq ',' -and $paren -eq 0 -and $bracket -eq 0) {
            $parts = [Collections.Generic.List[string]]::new()
            for ($j = $segment; $j -lt $i; $j++) {
                $part = [string]$Tokens[$j].text
                if ($part -eq '(' -or $part -eq '[') { break }
                [void]$parts.Add(($part -replace '^@(?=[\p{L}_])', ''))
            }
            $name = $parts -join ''
            if ($name -match '^(assembly|module|field|property|method|return|param|type):') {
                $name = ''
            }
            [void]$names.Add($name)
            $segment = $i + 1
        }
    }
    return @($names)
}

function Test-NamedAreEqualTestAttribute {
    param(
        [object[]]$Tokens, [hashtable]$Pairs, [int]$First, [int]$Last,
        [string]$ShortName, [bool]$HasMstestImport, [hashtable]$Aliases
    )
    $full = "Microsoft.VisualStudio.TestTools.UnitTesting.$ShortName"
    for ($i = $First; $i -le $Last; $i++) {
        if ($Tokens[$i].text -ne '[' -or -not $Pairs.ContainsKey($i) -or
            $Pairs[$i] -gt $Last) { continue }
        foreach ($attribute in @(Get-CoverageAttributeNames -Tokens $Tokens `
                -First $i -Last $Pairs[$i])) {
            $name = ([string]$attribute -replace 'Attribute$', '')
            if ($name -ceq $full -or $name -ceq "global::$full") { return $true }
            if ($name -ceq $ShortName -and $HasMstestImport -and
                -not $Aliases.ContainsKey($ShortName)) { return $true }
            $pieces = $name -split '\.|::', 2
            if ($Aliases.ContainsKey($pieces[0])) {
                $suffix = if ($pieces.Count -gt 1) { '.' + $pieces[1] } else { '' }
                if (($Aliases[$pieces[0]] + $suffix) -ceq $full) { return $true }
            }
        }
        $i = [int]$Pairs[$i]
    }
    return $false
}

function Get-NamedAreEqualConstructs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Spans,
        [Parameter(Mandatory)][string]$Path
    )
    if ([Text.Encoding]::UTF8.GetByteCount($Content) -ge 16MB -or
        $Spans.Count -gt 4096 -or $Path.Length -gt 2048) {
        throw 'C# coverage input exceeds the bounded content or span limit.'
    }
    $ranges = @(
        foreach ($span in $Spans) {
            $first = Get-CoverageMember $span startLine
            $last = Get-CoverageMember $span endLine
            $state = Get-CoverageMember $span state
            if ($first -isnot [int] -or $last -isnot [int] -or $first -lt 1 -or
                $last -lt $first -or $last -gt 200000 -or
                ($null -ne $state -and $state -cne 'complete')) {
                throw 'C# coverage span is incomplete or invalid.'
            }
            @{ start = $first; end = $last }
        }
    )
    if ($ranges.Count -eq 0 -or -not $Content) { return }
    $scan = Get-CoverageTokens -Text $Content -IncludeLiteralTokens
    $tokens = $scan.tokens.ToArray()
    $pairs = @{}
    $stack = [Collections.Generic.Stack[int]]::new()
    $closing = @{ ')' = '('; ']' = '['; '}' = '{' }
    $malformed = [bool]($scan.unterminated -or $scan.conditional)
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $text = [string]$tokens[$i].text
        if ($text -in @('(', '[', '{')) { $stack.Push($i) }
        elseif ($closing.ContainsKey($text)) {
            if ($stack.Count -eq 0 -or $tokens[$stack.Peek()].text -cne $closing[$text]) {
                $malformed = $true
                break
            }
            $opener = $stack.Pop()
            $pairs[$opener] = $i
            $pairs[$i] = $opener
        }
    }
    if ($stack.Count) { $malformed = $true }

    $mstestNamespace = 'Microsoft.VisualStudio.TestTools.UnitTesting'
    $imports = [Collections.Generic.List[string]]::new()
    $aliases = @{}
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $t = [string]$tokens[$i].text
        if ($t -ne 'using' -or $i + 1 -ge $tokens.Count) { continue }
        $j = $i + 1
        $isStatic = $tokens[$j].text -eq 'static'
        if ($isStatic) { $j++ }
        $parts = [Collections.Generic.List[string]]::new()
        while ($j -lt $tokens.Count -and $tokens[$j].text -ne ';' -and
            $j - $i -lt 64 -and $tokens[$j].text -notin @('{', '}')) {
            [void]$parts.Add([string]$tokens[$j].text); $j++
        }
        if ($j -ge $tokens.Count -or $tokens[$j].text -ne ';') { continue }
        $value = $parts -join ''
        if ($value -match '^(@?[\p{L}_][\p{L}\p{N}_]*)=(.+)$') {
            $key = $Matches[1] -replace '^@', ''
            $aliases[$key] = $Matches[2] -replace '^global::', ''
        }
        elseif (-not $isStatic) { [void]$imports.Add(($value -replace '^global::', '')) }
    }

    $scope = [Collections.Generic.List[object]]::new()
    $fileNamespace = ''
    $location = @{}
    $methodSymbols = @{}
    $assertShadowed = $aliases.ContainsKey('Assert')
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $text = [string]$tokens[$i].text
        if ($text -eq '}') {
            if ($scope.Count) { $scope.RemoveAt($scope.Count - 1) }
            continue
        }
        $location[$i] = @($scope)
        if ($text -eq 'namespace') {
            $j = $i + 1
            $parts = [Collections.Generic.List[string]]::new()
            while ($j -lt $tokens.Count -and $j - $i -lt 64 -and
                $tokens[$j].text -notin @('{', ';')) {
                [void]$parts.Add([string]$tokens[$j].text); $j++
            }
            if ($j -lt $tokens.Count -and $tokens[$j].text -eq ';' -and
                ($parts -join '') -match '^[\w]+(\.[\w]+)*$') {
                $fileNamespace = $parts -join ''
            }
        }
        if ($text -ne '{') { continue }
        $begin = $i - 1
        while ($begin -ge 0 -and $tokens[$begin].text -notin @(';', '{', '}')) { $begin-- }
        $header = @($tokens[($begin + 1)..($i - 1)] | ForEach-Object text) -join ' '
        $kind = 'other'
        $name = ''
        if ($header -match '\bnamespace\s+([\w]+(?:\s*\.\s*[\w]+)*)\s*$') {
            $kind = 'namespace'
            $name = $Matches[1] -replace '\s+', ''
        }
        elseif ($header -match '\b(class|struct|record)\s+(@?[\p{L}_][\p{L}\p{N}_]*)\b') {
            $kind = 'type'
            $name = $Matches[2] -replace '^@', ''
            if ($name -ceq 'Assert') { $assertShadowed = $true }
            $testClass = Test-NamedAreEqualTestAttribute -Tokens $tokens -Pairs $pairs `
                -First ($begin + 1) -Last ($i - 1) -ShortName TestClass `
                -HasMstestImport ($mstestNamespace -cin $imports) -Aliases $aliases
        }
        elseif ($scope.Count -gt 0 -and $scope[$scope.Count - 1].kind -eq 'type') {
            $rightParen = -1
            for ($j = $i - 1; $j -gt $begin; $j--) {
                if ($tokens[$j].text -eq ')') { $rightParen = $j; break }
            }
            if ($rightParen -gt 0 -and $pairs.ContainsKey($rightParen)) {
                $openParen = [int]$pairs[$rightParen]
                $nameIndex = $openParen - 1
                if ($nameIndex -ge 0 -and $tokens[$nameIndex].text -eq '>') {
                    $level = 1
                    $nameIndex--
                    while ($nameIndex -gt $begin -and $level -gt 0) {
                        if ($tokens[$nameIndex].text -eq '>') { $level++ }
                        if ($tokens[$nameIndex].text -eq '<') { $level-- }
                        $nameIndex--
                    }
                }
                if ($nameIndex -gt $begin -and
                    [string]$tokens[$nameIndex].text -cmatch '^@?[\p{L}_][\p{L}\p{N}_]*$' -and
                    $tokens[$nameIndex - 1].text -notin @('.', '::', 'new', '=') -and
                    $header -notmatch '\b(?:if|while|for|foreach|switch|catch|lock|using)\s*\(') {
                    $kind = 'method'
                    $name = [string]$tokens[$nameIndex].text -replace '^@', ''
                    $declarationLine = [int]$tokens[$nameIndex].line
                    $testMethod = (Test-NamedAreEqualTestAttribute -Tokens $tokens -Pairs $pairs `
                            -First ($begin + 1) -Last ($openParen - 1) -ShortName TestMethod `
                            -HasMstestImport ($mstestNamespace -cin $imports) -Aliases $aliases) -or
                        (Test-NamedAreEqualTestAttribute -Tokens $tokens -Pairs $pairs `
                            -First ($begin + 1) -Last ($openParen - 1) -ShortName DataTestMethod `
                            -HasMstestImport ($mstestNamespace -cin $imports) -Aliases $aliases)
                    $parts = @($fileNamespace) + @($scope | Where-Object {
                            $_.kind -in @('namespace', 'type')
                        } | ForEach-Object name) + @($name)
                    $methodSymbol = (@($parts | Where-Object { $_ }) -join '.')
                    if (-not $methodSymbols.ContainsKey($methodSymbol)) {
                        $methodSymbols[$methodSymbol] = 0
                    }
                    $methodSymbols[$methodSymbol]++
                }
            }
        }
        [void]$scope.Add(@{ kind = $kind; name = $name
            isTestClass = [bool]($kind -eq 'type' -and $testClass)
            isTestMethod = [bool]($kind -eq 'method' -and $testMethod)
            declarationLine = $(if ($kind -eq 'method') { $declarationLine } else { 0 })
            end = $(if ($pairs.ContainsKey($i)) { [int]$tokens[$pairs[$i]].line } else { [int]$tokens[$i].line }) })
    }
    for ($i = 1; $i -lt $tokens.Count - 1; $i++) {
        if ([string]$tokens[$i].text -cne 'Assert') { continue }
        $previous = [string]$tokens[$i - 1].text
        $next = [string]$tokens[$i + 1].text
        if ($next -eq '.' -and $i + 2 -lt $tokens.Count -and
            [string]$tokens[$i + 2].text -ceq 'AreEqual') {
            continue
        }
        if ($previous -cin @(
                'class', 'struct', 'record', 'interface', 'enum', 'var') -or
            ($previous -cmatch '^@?[\p{L}_][\p{L}\p{N}_]*$' -and
                $next -in @('=', '=>', ';', ',', ')', '{', '('))) {
            $assertShadowed = $true
            break
        }
    }

    $groups = @{}
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i].text -cne 'AreEqual' -or $i -lt 2 -or
            $tokens[$i - 1].text -ne '.') { continue }
        $receiverEnd = $i - 2
        $receiverStart = $receiverEnd
        while ($receiverStart -ge 2 -and $tokens[$receiverStart - 1].text -in @('.', '::') -and
            [string]$tokens[$receiverStart - 2].text -cmatch '^@?[\p{L}_][\p{L}\p{N}_]*$') {
            $receiverStart -= 2
        }
        $receiver = @($tokens[$receiverStart..$receiverEnd] | ForEach-Object text) -join ''
        if ($receiver -notmatch '(^|\.|::)Assert$' -and
            -not $aliases.ContainsKey($receiver)) { continue }
        $start = [int]$tokens[$receiverStart].line
        $openParen = $i + 1
        if ($openParen -lt $tokens.Count -and $tokens[$openParen].text -eq '<') {
            $level = 1
            $openParen++
            while ($openParen -lt $tokens.Count -and $level -gt 0 -and
                $openParen - $i -lt 128) {
                if ($tokens[$openParen].text -eq '<') { $level++ }
                if ($tokens[$openParen].text -eq '>') { $level-- }
                $openParen++
            }
        }
        $callValid = $openParen -lt $tokens.Count -and $tokens[$openParen].text -eq '(' -and
            $pairs.ContainsKey($openParen)
        $end = if ($callValid) { [int]$tokens[$pairs[$openParen]].line } else { [int]$tokens[$i].line }
        if (-not (Test-CoverageChanged $start $end $ranges)) { continue }
        $contexts = @($location[$i])
        $method = @($contexts | Where-Object kind -eq 'method' | Select-Object -Last 1)
        $symbolParts = [Collections.Generic.List[string]]::new()
        if ($fileNamespace) { [void]$symbolParts.Add($fileNamespace) }
        foreach ($entry in $contexts) {
            if ($entry.kind -in @('namespace', 'type', 'method')) {
                [void]$symbolParts.Add([string]$entry.name)
            }
        }
        $symbol = $symbolParts -join '.'
        $exactSpelling = $receiver -ceq 'Assert' -and
            ($receiverStart -eq 0 -or $tokens[$receiverStart - 1].text -notin @('.', '::', '?', '!'))
        $testClass = @($contexts | Where-Object { $_.kind -eq 'type' -and $_.isTestClass })
        $exactAnchor = Test-CoverageChanged $start $start $ranges
        $unknownReasons = [Collections.Generic.List[string]]::new()
        if (-not $exactSpelling) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'receiver-spelling-uncertain'
        }
        if ($assertShadowed) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'receiver-shadowing-uncertain'
        }
        if ($malformed) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'source-structure-uncertain'
        }
        if (-not $callValid) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'call-shape-uncertain'
        }
        if (-not $exactAnchor) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'changed-anchor-uncertain'
        }
        if ($method.Count -ne 1) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'test-context-uncertain'
        }
        else {
            if (-not $method[0].isTestMethod) {
                Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                    -Code 'test-context-uncertain'
            }
            if ($method[0].declarationLine -lt 1) {
                Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                    -Code 'test-context-uncertain'
            }
        }
        if ($testClass.Count -ne 1) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'test-context-uncertain'
        }
        if ($symbol.Length -eq 0 -or $symbol.Length -gt 256) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'symbol-identity-uncertain'
        }
        if ($symbol -cnotmatch
            '^([\p{L}_][\p{L}\p{N}_]*\.)*[\p{L}_][\p{L}\p{N}_]*$') {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'symbol-identity-uncertain'
        }
        if (-not $methodSymbols.ContainsKey($symbol) -or
            $methodSymbols[$symbol] -ne 1) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'symbol-identity-uncertain'
        }
        $known = $unknownReasons.Count -eq 0
        $positional = $false
        $argumentCount = 0
        $nestedAngles = 0
        if ($callValid) {
            $segment = $openParen + 1
            $closeParen = [int]$pairs[$openParen]
            for ($j = $segment; $j -le $closeParen; $j++) {
                $t = if ($j -eq $closeParen) { ',' } else { [string]$tokens[$j].text }
                if ($t -eq '<') {
                    $angleEnd = $j + 1
                    $depth = 1
                    while ($angleEnd -lt $closeParen -and $depth -gt 0 -and
                        $angleEnd - $j -lt 128) {
                        if ($tokens[$angleEnd].text -eq '<') { $depth++ }
                        elseif ($tokens[$angleEnd].text -eq '>') { $depth-- }
                        elseif ($tokens[$angleEnd].text -notmatch '^[\w@]+$|^(\.|::|,|\?|\[|\])$') { break }
                        $angleEnd++
                    }
                    if ($depth -eq 0) { $nestedAngles++ }
                }
                elseif ($t -eq '>' -and $nestedAngles -gt 0) { $nestedAngles-- }
                if ($t -eq ',' -and $nestedAngles -eq 0) {
                    if ($j -gt $segment) {
                        $argumentCount++
                        if ($tokens[$j - 1].text -in @(':', '.', '?', '+', '-', '*', '/', '=', '=>')) {
                            $known = $false
                            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                                -Code 'argument-terminal-uncertain'
                        }
                    }
                    if ($j -eq $segment) {
                        $known = $false
                        Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                            -Code 'argument-segment-empty'
                    }
                    elseif ($segment + 1 -ge $j -or
                        [string]$tokens[$segment].text -cnotmatch '^@?[\p{L}_][\p{L}\p{N}_]*$' -or
                        $tokens[$segment + 1].text -ne ':') {
                        $positional = $true
                        if ($tokens[$segment].text -in @(':', '.', '?', '+', '-', '*', '/', '=')) {
                            $known = $false
                            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                                -Code 'argument-leading-token-uncertain'
                        }
                    }
                    elseif ($segment + 2 -ge $j) {
                        $known = $false
                        Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                            -Code 'named-argument-value-missing'
                    }
                    $segment = $j + 1
                }
                elseif ($t -in @('(', '[', '{') -and $pairs.ContainsKey($j)) {
                    $j = [int]$pairs[$j]
                }
            }
        }
        if (-not $callValid) {
            $known = $false
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'call-shape-uncertain'
        }
        if ($argumentCount -lt 2) {
            $known = $false
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'argument-count-insufficient'
        }
        if ($nestedAngles -ne 0) {
            $known = $false
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'generic-angle-parse-uncertain'
        }
        $key = if ($method.Count -eq 1 -and $symbol.Length -le 256) {
            "$symbol`:$($method[0].declarationLine)"
        } else { "unknown:$start" }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [Collections.Generic.List[object]]::new()
        }
        [void]$groups[$key].Add(@{ name = $(if ($symbol.Length -gt 0 -and
                    $symbol.Length -le 256) { $symbol } else { 'unrecognized' })
            declarationLine = $(if ($method.Count -eq 1) { [int]$method[0].declarationLine } else { 0 })
            start = $start; end = $end; known = [bool]$known
            positional = [bool]$positional
            unknownReasons = @($unknownReasons) })
    }
    foreach ($key in @($groups.Keys | Sort-Object)) {
        $calls = @($groups[$key] | Sort-Object start, end)
        $distinctLines = @($calls | ForEach-Object start | Sort-Object -Unique)
        $ambiguousLine = $distinctLines.Count -ne $calls.Count
        $unknownReasons = [Collections.Generic.List[string]]::new()
        foreach ($call in $calls) {
            foreach ($code in @($call.unknownReasons)) {
                Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                    -Code ([string]$code)
            }
        }
        if ($ambiguousLine) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'same-line-call-ambiguity'
        }
        if ($calls.Count -gt 256) {
            Add-NamedAreEqualUnknownReason -Reasons $unknownReasons `
                -Code 'group-cardinality-exceeded'
        }
        $allKnown = $calls.Count -le 256 -and -not $ambiguousLine -and
            @($calls | Where-Object { -not $_.known }).Count -eq 0
        $violations = @($calls | Where-Object positional)
        $reported = $calls
        if ($allKnown -and $violations.Count) { $reported = $violations }
        $lines = @($reported | ForEach-Object start | Sort-Object -Unique | Select-Object -First 256)
        $anchor = $reported[0]
        $result = [ordered]@{
            name = [string]$calls[0].name
            declarationLine = [int]$calls[0].declarationLine
            startLine = [int]$lines[0]
            endLine = [int]$anchor.end
            recognized = [bool]$allKnown
            hasPositional = [bool]($allKnown -and $violations.Count -gt 0)
            affectedCallCount = [int]$lines.Count
            affectedCallLines = $lines
            callListTruncated = [bool]($lines.Count -gt 12)
            reason = $(if ($ambiguousLine) { 'same-line-call-ambiguity' }
                elseif (-not $allKnown) { 'named-areequal-call-unknown' }
                elseif ($violations.Count) { 'positional-areequal-arguments' }
                else { 'named-areequal-arguments' })
            path = $Path
        }
        if (-not $allKnown) {
            $result.unknownReasonCounts =
                @(Get-NamedAreEqualUnknownReasonSummary -Reasons $unknownReasons)
        }
        $result
    }
}

Export-ModuleMember -Function Get-NamedAreEqualConstructs
