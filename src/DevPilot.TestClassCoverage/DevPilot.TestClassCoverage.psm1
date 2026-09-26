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
    param([string]$Text)
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

function Resolve-CoverageAttribute {
    param(
        [string]$Name, [string]$Namespace, [string]$ShortName,
        [string]$FullName, [object[]]$Usings, [string[]]$DeclaredNames,
        [string]$ContainingSymbol
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'other' }
    $bare = $Name -replace 'Attribute$', ''
    $short = $ShortName -replace 'Attribute$', ''
    $full = $FullName -replace 'Attribute$', ''
    $applicable = @($Usings | Where-Object {
            $_.scope -eq '' -or $Namespace -eq $_.scope -or
            $Namespace.StartsWith("$($_.scope).", [StringComparison]::Ordinal)
        })
    $resolved = $bare -replace '^global::', ''
    if ($bare -match '^global::') {
        return $(if ($resolved -ceq $full) { 'yes' } else { 'other' })
    }
    $first = ($bare -split '\.|::')[0]
    $aliases = @($applicable | Where-Object { $_.alias -ceq $first })
    if ($aliases.Count -gt 0) {
        if ($aliases.Count -ne 1) { return 'unknown' }
        $target = [string]$aliases[0].target
        if ($target -notmatch '^(global::)?[A-Za-z_][\w]*(\.[A-Za-z_][\w]*)*$') { return 'unknown' }
        $tail = $bare.Substring($first.Length) -replace '^::', '.'
        $resolved = (($target -replace '^global::', '') + $tail) -replace 'Attribute$', ''
        if ($resolved -ceq $full) { return 'yes' }
        if ($bare -ceq $short -or $resolved.EndsWith(".$short", [StringComparison]::Ordinal)) {
            return 'unknown'
        }
        return 'other'
    }
    if ($bare -ceq $full) { return 'yes' }
    if ($bare -ceq $short) {
        $targetNamespace = $full.Substring(0, $full.LastIndexOf('.'))
        $imports = @($applicable | Where-Object { $_.import -ceq $targetNamespace })
        if ($imports.Count -gt 0 -or
            $Namespace -ceq $targetNamespace) {
            $competingImports = @($applicable | Where-Object {
                    $_.import -and $_.import -cne $targetNamespace -and
                    ("$($_.import).$short" -cin $DeclaredNames -or
                        "$($_.import).${short}Attribute" -cin $DeclaredNames)
                })
            if ($competingImports.Count) { return 'unknown' }
            $container = $ContainingSymbol
            while ($container) {
                if ("$container.$short" -cin $DeclaredNames -or
                    "$container.${short}Attribute" -cin $DeclaredNames) { return 'unknown' }
                $dot = $container.LastIndexOf('.')
                if ($dot -lt 0) { break }
                $container = $container.Substring(0, $dot)
            }
            if ($short -cin $DeclaredNames -or "${short}Attribute" -cin $DeclaredNames) {
                return 'unknown'
            }
            return 'yes'
        }
        return 'unknown'
    }
    if ($bare.EndsWith(".$short", [StringComparison]::Ordinal) -or
        $bare.EndsWith("::$short", [StringComparison]::Ordinal)) { return 'unknown' }
    return 'other'
}

function Get-TestClassCoverageConstructs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Spans,
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeUnchanged,
        [switch]$IncludeResolutionContext
    )

    if ([Text.Encoding]::UTF8.GetByteCount($Content) -ge 16MB -or $Spans.Count -gt 4096 -or
        $Path.Length -gt 2048) {
        throw 'C# coverage input exceeds the bounded content or span limit.'
    }
    $ranges = @(
        foreach ($span in $Spans) {
            $start = Get-CoverageMember $span startLine
            $end = Get-CoverageMember $span endLine
            $state = Get-CoverageMember $span state
            if ($start -isnot [int] -or $end -isnot [int] -or
                $start -lt 1 -or $end -lt $start -or $end -gt 200000 -or
                ($null -ne $state -and $state -cne 'complete')) {
                throw 'C# coverage span is incomplete or invalid.'
            }
            @{ start = $start; end = $end }
        }
    )
    if ($ranges.Count -eq 0 -or $Content.Length -eq 0) { return }
    $scan = Get-CoverageTokens -Text $Content
    if ($scan.unterminated -or $scan.conditional) {
        @{
            name = 'unrecognized'
            declarationLine = 0
            startLine = [int]$ranges[0].start
            endLine = [int]$ranges[0].end
            recognized = $false
            hasTestClass = $false
            hasExclude = $false
            reason = 'lexical-input-unknown'
            path = $Path
        }
        return
    }
    $tokens = $scan.tokens
    $tokenArray = $tokens.ToArray()
    $count = $tokens.Count
    $brackets = @{}
    $open = [Collections.Generic.Stack[int]]::new()
    for ($i = 0; $i -lt $count; $i++) {
        if ($tokens[$i].text -eq '[') { $open.Push($i) }
        elseif ($tokens[$i].text -eq ']' -and $open.Count -gt 0) {
            $brackets[$i] = $open.Pop()
        }
    }
    $scope = [Collections.Generic.List[object]]::new()
    $braceKinds = @{}
    $usings = [Collections.Generic.List[object]]::new()
    $classes = [Collections.Generic.List[object]]::new()
    $unknownDeclarations = [Collections.Generic.List[object]]::new()
    $fileNamespace = ''
    $modifiers = @('public', 'private', 'protected', 'internal', 'sealed',
        'abstract', 'static', 'partial', 'new', 'unsafe', 'file', 'readonly')
    for ($i = 0; $i -lt $count; $i++) {
        $t = [string]$tokens[$i].text
        if ($t -eq '}') {
            if ($scope.Count -gt 0) { $scope.RemoveAt($scope.Count - 1) }
            continue
        }
        if ($t -eq '{') {
            if ($braceKinds.ContainsKey($i)) { [void]$scope.Add($braceKinds[$i]) }
            else { [void]$scope.Add(@{ kind = 'other'; name = '' }) }
            continue
        }
        $nsParts = [Collections.Generic.List[string]]::new()
        if ($fileNamespace) { [void]$nsParts.Add($fileNamespace) }
        $classParts = [Collections.Generic.List[string]]::new()
        foreach ($item in $scope) {
            if ($item.kind -eq 'namespace') { [void]$nsParts.Add($item.name) }
            if ($item.kind -eq 'class') { [void]$classParts.Add($item.name) }
        }
        $namespace = $nsParts -join '.'
        if ($t -eq 'namespace') {
            $parts = [Collections.Generic.List[string]]::new()
            $j = $i + 1
            while ($j -lt $count -and $tokens[$j].text -notin @('{', ';') -and
                $j - $i -lt 64) {
                [void]$parts.Add([string]$tokens[$j].text); $j++
            }
            $name = $parts -join ''
            if ($name -match '^[\w]+(\.[\w]+)*$' -and $j -lt $count) {
                if ($tokens[$j].text -eq '{') {
                    $braceKinds[$j] = @{ kind = 'namespace'; name = $name }
                }
                elseif ($tokens[$j].text -eq ';') {
                    $fileNamespace = (@($namespace, $name) | Where-Object { $_ }) -join '.'
                }
            }
        }
        if ($t -eq 'using' -and -not ($scope | Where-Object { $_.kind -eq 'class' })) {
            $j = $i + 1
            if ($j -lt $count -and $tokens[$j].text -eq 'static') { continue }
            $alias = ''
            if ($j + 1 -lt $count -and $tokens[$j + 1].text -eq '=') {
                $alias = [string]$tokens[$j].text
                $j += 2
            }
            $parts = [Collections.Generic.List[string]]::new()
            while ($j -lt $count -and $tokens[$j].text -ne ';' -and $j - $i -lt 64) {
                [void]$parts.Add([string]$tokens[$j].text); $j++
            }
            if ($j -lt $count -and $tokens[$j].text -eq ';') {
                $target = $parts -join ''
                if ($alias) {
                    [void]$usings.Add(@{ scope = $namespace; alias = $alias; target = $target; import = '' })
                }
                else {
                    [void]$usings.Add(@{ scope = $namespace; alias = ''; target = ''; import = ($target -replace '^global::', '') })
                }
            }
        }
        if ($t -notin @('class', 'record', 'struct', 'interface', 'enum')) { continue }
        if ($t -in @('class', 'struct') -and $i -gt 0 -and $tokens[$i - 1].text -eq 'record') { continue }
        if ($i -gt 0 -and $tokens[$i - 1].text -in @(':', '.', '::', 'where')) { continue }
        $kind = $t
        if ($t -eq 'record' -and $i + 1 -lt $count -and $tokens[$i + 1].text -in @('class', 'struct')) {
            $kind = 'record'
        }
        $nameIndex = $i + 1
        if ($kind -eq 'record' -and $nameIndex -lt $count -and
            $tokens[$nameIndex].text -in @('class', 'struct')) { $nameIndex++ }
        if ($nameIndex -ge $count -or [string]$tokens[$nameIndex].text -cnotmatch '^@?[\p{L}_][\p{L}\p{N}_]*$') {
            continue
        }
        $className = [string]$tokens[$nameIndex].text -replace '^@', ''
        $before = $i - 1
        $isPartial = $false
        while ($before -ge 0 -and $tokens[$before].text -in $modifiers) {
            if ($tokens[$before].text -eq 'partial') { $isPartial = $true }
            $before--
        }
        $declarationStart = $before + 1
        $attrs = [Collections.Generic.List[object]]::new()
        while ($before -ge 0 -and $tokens[$before].text -eq ']' -and $brackets.ContainsKey($before)) {
            $first = [int]$brackets[$before]
            [void]$attrs.Insert(0, @{ first = [int]$tokens[$first].line
                    last = [int]$tokens[$before].line
                    names = @(Get-CoverageAttributeNames -Tokens $tokenArray -First $first -Last $before) })
            $before = $first - 1
            while ($before -ge 0 -and $tokens[$before].text -in $modifiers) { $before-- }
        }
        if ($attrs.Count -gt 0) { $declarationStart = $before + 1 }
        $j = $nameIndex + 1
        $angle = 0
        $paren = 0
        while ($j -lt $count -and $j - $i -lt 256 -and
            $tokens[$j].line - $tokens[$i].line -le 64) {
            $p = [string]$tokens[$j].text
            if ($p -eq '<') { $angle++ }
            elseif ($p -eq '>') { $angle-- }
            elseif ($p -eq '(') { $paren++ }
            elseif ($p -eq ')') { $paren-- }
            if ($angle -le 0 -and $paren -le 0 -and $p -in @('{', ';', '=>')) { break }
            $j++
        }
        if ($j -lt $count -and $tokens[$j].text -eq '{') {
            if ($kind -eq 'class') {
                $braceKinds[$j] = @{ kind = 'class'; name = $className }
            }
            else { $braceKinds[$j] = @{ kind = 'other'; name = '' } }
        }
        $name = (@($nsParts) + @($classParts) + @($className)) -join '.'
        $entry = @{ name = $name; namespace = $namespace; kind = $kind
            isPartial = $isPartial
            bodyOpen = $(if ($j -lt $count -and $tokens[$j].text -eq '{') { $j } else { -1 })
            declarationLine = [int]$tokens[$i].line
            first = [int]$tokens[$declarationStart].line
            last = $(if ($j -lt $count) { [int]$tokens[$j].line } else { [int]$tokens[$nameIndex].line })
            attrs = @($attrs); valid = ($j -lt $count -and $tokens[$j].text -eq '{') }
        if ($kind -eq 'class') { [void]$classes.Add($entry) }
        else { [void]$unknownDeclarations.Add($entry) }
    }
    $mstest = 'Microsoft.VisualStudio.TestTools.UnitTesting.TestClass'
    $exclude = 'System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage'
    $usingArray = $usings.ToArray()
    $declaredNames = @($classes | ForEach-Object name) +
        @($unknownDeclarations | ForEach-Object name)
    foreach ($entry in @($classes) + @($unknownDeclarations)) {
        $changed = Test-CoverageChanged $entry.first $entry.last $ranges
        foreach ($attr in $entry.attrs) {
            if (Test-CoverageChanged $attr.first $attr.last $ranges) { $changed = $true }
        }
        if (-not $changed -and -not $IncludeUnchanged) { continue }
        $testState = 'other'
        $excludeState = 'other'
        $container = $entry.name.Substring(0, [Math]::Max(0, $entry.name.LastIndexOf('.')))
        foreach ($attr in $entry.attrs) {
            foreach ($name in $attr.names) {
                $testResult = Resolve-CoverageAttribute $name $entry.namespace TestClass $mstest `
                    $usingArray $declaredNames $container
                $excludeResult = Resolve-CoverageAttribute $name $entry.namespace ExcludeFromCodeCoverage `
                    $exclude $usingArray $declaredNames $container
                if ($testResult -eq 'yes') { $testState = 'yes' }
                elseif ($testResult -eq 'unknown' -and $testState -ne 'yes') { $testState = 'unknown' }
                if ($excludeResult -eq 'yes') { $excludeState = 'yes' }
                elseif ($excludeResult -eq 'unknown' -and $excludeState -ne 'yes') { $excludeState = 'unknown' }
            }
        }
        if ($testState -eq 'other') { continue }
        $recognized = $entry.kind -eq 'class' -and $entry.valid -and
            $testState -eq 'yes' -and $excludeState -ne 'unknown' -and
            (-not $entry.isPartial -or $excludeState -eq 'yes') -and
            -not $scan.conditional -and -not $scan.unterminated
        $firstLine = $entry.first
        foreach ($attr in $entry.attrs) { $firstLine = [Math]::Min($firstLine, $attr.first) }
        $result = @{
            name = [string]$entry.name
            declarationLine = [int]$entry.declarationLine
            startLine = [int]$firstLine
            endLine = [int]$entry.last
            recognized = [bool]$recognized
            hasTestClass = [bool]($testState -eq 'yes')
            hasExclude = [bool]($excludeState -eq 'yes')
            isPartial = [bool]$entry.isPartial
            bodyOpen = [int]$entry.bodyOpen
            reason = $(if ($recognized -and $excludeState -eq 'yes') {
                    'class-level-coverage-exclusion-present'
                }
                elseif ($recognized) { 'class-level-coverage-exclusion-missing' }
                elseif ($entry.kind -ne 'class' -or -not $entry.valid) {
                    'class-declaration-unrecognized'
                }
                elseif ($entry.isPartial -and $excludeState -ne 'yes') {
                    'partial-class-coverage-unknown'
                }
                else { 'class-attribute-resolution-unknown' })
            path = $Path
        }
        if ($IncludeResolutionContext) {
            $result['namespace'] = $entry.namespace
            $result['usings'] = $usingArray
            $result['declaredNames'] = $declaredNames
        }
        $result
    }
}

function Get-RedundantMethodCoverageConstructs {
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
    $safeContent = $Content
    if ($Content -match '(?m)^\s*#\s*(?:if|elif|else|endif|define|undef)\b') {
        $lines = [regex]::Split($Content, '(?<=\n)')
        $sanitized = [Collections.Generic.List[string]]::new()
        $inside = $false
        $aliasCount = 0
        $safe = $true
        foreach ($line in $lines) {
            if ($line -match '^\s*#\s*if\b') {
                if ($inside) { $safe = $false; break }
                $inside = $true
                $aliasCount = 0
            }
            elseif ($line -match '^\s*#\s*endif\b') {
                if (-not $inside -or $aliasCount -ne 1) { $safe = $false; break }
                $inside = $false
            }
            elseif ($inside) {
                if ($line -notmatch '^\s*using\s+(?<alias>[A-Za-z_]\w*)\s*=\s*(?:global::)?(?<target>[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*;\s*$' -or
                    $Matches.alias -in @('TestClass', 'TestMethod', 'DataTestMethod',
                        'ExcludeFromCodeCoverage') -or
                    $Matches.target -match '^(?:Microsoft\.VisualStudio\.TestTools\.UnitTesting|System\.Diagnostics\.CodeAnalysis)(?:\.|$)' -or
                    $Matches.target -match '(?:^|\.)(?:TestClass|TestMethod|DataTestMethod|ExcludeFromCodeCoverage)(?:Attribute)?$') {
                    $safe = $false; break
                }
                $aliasCount++
            }
            elseif ($line -match '^\s*#\s*(?:elif|else|endif|define|undef)\b') {
                $safe = $false; break
            }
            if ($inside -or $line -match '^\s*#\s*endif\b') {
                [void]$sanitized.Add(([regex]::Match($line, '\r?\n$')).Value)
            }
            else { [void]$sanitized.Add($line) }
        }
        if ($safe -and -not $inside) { $safeContent = $sanitized -join '' }
    }
    $scan = Get-CoverageTokens -Text $safeContent
    $tokens = $scan.tokens.ToArray()
    $stack = [Collections.Generic.Stack[string]]::new()
    $pairs = @{ '}' = '{'; ')' = '('; ']' = '[' }
    $malformed = [bool]($scan.unterminated -or $scan.conditional)
    foreach ($token in $tokens) {
        $text = [string]$token.text
        if ($text -in @('{', '(', '[')) { $stack.Push($text) }
        elseif ($pairs.ContainsKey($text)) {
            if ($stack.Count -eq 0 -or $stack.Pop() -cne $pairs[$text]) {
                $malformed = $true
                break
            }
        }
    }
    if ($stack.Count -gt 0) { $malformed = $true }
    if ($malformed) {
        if ($Spans.Count -gt 0) {
            @{ name = 'unrecognized'; declarationLine = 0
                startLine = [int]$Spans[0].startLine
                endLine = [int]$Spans[0].endLine
                recognized = $false; hasExclude = $false
                reason = 'lexical-input-unknown'; path = $Path }
        }
        return
    }
    $classes = @(Get-TestClassCoverageConstructs -Content $safeContent -Spans $Spans `
        -Path $Path -IncludeUnchanged -IncludeResolutionContext)
    if ($classes.Count -eq 0) { return }
    $ranges = @($Spans | ForEach-Object {
        @{ start = [int]$_.startLine; end = [int]$_.endLine }
    })
    foreach ($class in $classes) {
        if (-not $class.hasTestClass -or $class.bodyOpen -lt 0) { continue }
        $candidates = [Collections.Generic.List[object]]::new()
        $depth = 1
        for ($i = $class.bodyOpen + 1; $i -lt $tokens.Count -and $depth -gt 0; $i++) {
            $text = [string]$tokens[$i].text
            if ($text -eq '{') { $depth++; continue }
            if ($text -eq '}') { $depth--; continue }
            if ($depth -ne 1 -or $text -ne '[') { continue }
            $first = $i
            $attributes = [Collections.Generic.List[object]]::new()
            while ($i -lt $tokens.Count -and $tokens[$i].text -eq '[') {
                $begin = $i
                $level = 1
                while ($i + 1 -lt $tokens.Count -and $level -gt 0) {
                    $i++
                    if ($tokens[$i].text -eq '[') { $level++ }
                    if ($tokens[$i].text -eq ']') { $level-- }
                }
                if ($level -ne 0) { break }
                [void]$attributes.Add(@{ first = [int]$tokens[$begin].line
                    last = [int]$tokens[$i].line
                    names = @(Get-CoverageAttributeNames -Tokens $tokens -First $begin -Last $i) })
                $i++
            }
            if ($i -ge $tokens.Count -or $attributes.Count -eq 0) { break }
            $header = $i
            $paren = -1
            $end = $i
            while ($end -lt $tokens.Count -and $end - $header -lt 256 -and
                [int]$tokens[$end].line - [int]$tokens[$first].line -le 64) {
                $part = [string]$tokens[$end].text
                if ($part -eq '(' -and $paren -lt 0) { $paren = $end }
                if ($part -in @('{', '}', ';', '=>')) { break }
                $end++
            }
            $methodName = if ($paren -gt $header -and
                [string]$tokens[$paren - 1].text -match '^@?[\p{L}_][\p{L}\p{N}_]*$') {
                [string]$tokens[$paren - 1].text -replace '^@', ''
            } else { '' }
            $test = 'other'
            $exclude = 'other'
            $excludeAttribute = $null
            $excludeCount = 0
            $mixed = $false
            $classNamespace = [string]$class.namespace
            foreach ($attr in $attributes) {
                foreach ($name in $attr.names) {
                    foreach ($short in @('TestMethod', 'DataTestMethod')) {
                        $resolved = Resolve-CoverageAttribute $name $classNamespace $short `
                            "Microsoft.VisualStudio.TestTools.UnitTesting.$short" `
                            $class.usings $class.declaredNames ([string]$class.name)
                        if ($resolved -eq 'yes') { $test = 'yes' }
                        elseif ($resolved -eq 'unknown' -and $test -ne 'yes') { $test = 'unknown' }
                    }
                    $resolved = Resolve-CoverageAttribute $name $classNamespace `
                        ExcludeFromCodeCoverage System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverage `
                        $class.usings $class.declaredNames ([string]$class.name)
                    if ($resolved -eq 'yes') {
                        $exclude = 'yes'
                        $excludeCount++
                        $excludeAttribute = $attr
                        if ($attr.names.Count -ne 1) { $mixed = $true }
                    }
                    elseif ($resolved -eq 'unknown' -and $exclude -ne 'yes') {
                        $exclude = 'unknown'
                    }
                }
            }
            if ($exclude -eq 'other') { $i--; continue }
            if ($exclude -eq 'yes' -and -not (Test-CoverageChanged `
                    $excludeAttribute.first $excludeAttribute.last $ranges)) { $i--; continue }
            if ($exclude -eq 'unknown' -and -not (Test-CoverageChanged `
                    $tokens[$first].line $tokens[$i - 1].line $ranges)) { $i--; continue }
            $exactChangedAnchor = $exclude -eq 'yes' -and
                (Test-CoverageChanged $excludeAttribute.first $excludeAttribute.first $ranges)
            $valid = $methodName -and $methodName.Length -le 128 -and
                $class.name.Length -le 256 -and $end -lt $tokens.Count -and
                $tokens[$end].text -in @('{', '=>') -and
                $methodName -cne ($class.name -split '\.')[-1]
            [void]$candidates.Add(@{
                name = $methodName
                startLine = $(if ($excludeAttribute) { [int]$excludeAttribute.first } else { [int]$tokens[$first].line })
                endLine = $(if ($excludeAttribute) { [int]$excludeAttribute.last } else { [int]$tokens[$i - 1].line })
                recognized = [bool]($valid -and $class.recognized -and
                    -not $class.isPartial -and $test -eq 'yes' -and
                    $exclude -eq 'yes' -and $excludeCount -eq 1 -and
                    $exactChangedAnchor -and -not $mixed)
            })
            $i--
        }
        if ($candidates.Count -eq 0) { continue }
        $ordered = @($candidates | Sort-Object startLine, endLine)
        $attributeLines = @($ordered | ForEach-Object startLine | Sort-Object -Unique)
        $allKnown = $candidates.Count -le 256 -and
            @($classes | Where-Object { $_.name -ceq $class.name }).Count -eq 1 -and
            $attributeLines.Count -eq $candidates.Count -and
            @($candidates | Where-Object { -not $_.recognized }).Count -eq 0
        $names = @()
        if ($allKnown) {
            $names = @($ordered | ForEach-Object name | Select-Object -Unique -First 12)
        }
        @{
            name = [string]$class.name
            declarationLine = [int]$class.declarationLine
            startLine = [int]$ordered[0].startLine
            endLine = [int]$ordered[0].endLine
            recognized = [bool]$allKnown
            hasExclude = [bool]$class.hasExclude
            affectedMethodCount = $(if ($allKnown) { [int]$candidates.Count } else { 0 })
            affectedMethods = $names
            affectedAttributeLines = $(if ($allKnown) { $attributeLines } else { @() })
            methodListTruncated = [bool]($allKnown -and $candidates.Count -gt $names.Count)
            reason = $(if (-not $allKnown) { 'method-coverage-containment-unknown' }
                elseif ($class.hasExclude) { 'redundant-method-coverage-exclusion' }
                else { 'class-level-coverage-exclusion-absent' })
            path = $Path
        }
    }
}

Export-ModuleMember -Function Get-TestClassCoverageConstructs, Get-RedundantMethodCoverageConstructs
