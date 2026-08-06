#requires -Version 7.0

<#
    Deterministic enumeration of the CONSTRUCTS a change set actually changed.

    Why this exists: a rule that was transported and then checked against one
    model-chosen anchor has not been checked. The specialist's own accounting
    said "named parameters: compliant" for a change set that contained four
    multi-line calls whose last argument was positional - because it looked at
    a different call and stopped. Nothing in the contract could tell the
    difference between "checked all of them" and "checked one".

    So the wrapper enumerates the constructs itself, deterministically, and the
    accounting has to name every one of them. What a construct MEANS is still
    the model's judgement against the transported rule text: nothing here knows
    what a test is, what an owner attribute is, or which language it is reading.
    It reports shapes - a call that spans lines and whether each of its
    arguments is syntactically named; a declaration and which attributes sit on
    it - and lets the rule decide whether those shapes matter.

    Everything is bounded, and anything it cannot parse confidently is reported
    as `unknown` rather than guessed at, because a construct silently dropped is
    the exact failure this exists to prevent.
#>

Set-StrictMode -Version Latest

$script:ReviewerConstructVersion = 1
$script:ReviewerConstructMaxPerFile = 64
$script:ReviewerConstructMaxTotal = 200
$script:ReviewerConstructMaxArguments = 24
$script:ReviewerConstructMaxLineLength = 4096
$script:ReviewerConstructMaxSpanLines = 80
$script:ReviewerConstructMaxAttributes = 12
$script:ReviewerConstructMaxAttributeNames = 40
$script:ReviewerConstructUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Get-ReviewerConstructMaskedLines {
    <#
        Returns each line with comment, string and character-literal content
        replaced by spaces, so the structural scan never sees a bracket, comma
        or colon that was only ever text. Positions are preserved exactly, so a
        column in the masked line is the same column in the original.

        Handles line comments, block comments, ordinary strings with escapes,
        verbatim strings (doubled quotes), and character literals. An
        unterminated block comment or string masks to end of input rather than
        re-entering code, which is the fail-closed direction: constructs after
        it are simply not enumerated, and the caller reports the file as
        partially understood.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $masked = [System.Collections.Generic.List[string]]::new()
    $inBlockComment = $false
    $inVerbatim = $false
    $truncated = $false

    foreach ($rawLine in @($Lines)) {
        $line = [string]$rawLine
        if ($line.Length -gt $script:ReviewerConstructMaxLineLength) {
            # A line longer than any real source line is not worth scanning and
            # is not worth guessing about either.
            $truncated = $true
            [void]$masked.Add(' ' * [Math]::Min($line.Length, $script:ReviewerConstructMaxLineLength))
            continue
        }
        $out = [System.Text.StringBuilder]::new($line.Length)
        $i = 0
        while ($i -lt $line.Length) {
            $ch = $line[$i]
            $next = if ($i + 1 -lt $line.Length) { $line[$i + 1] } else { [char]0 }

            if ($inBlockComment) {
                if ($ch -eq '*' -and $next -eq '/') { $inBlockComment = $false; [void]$out.Append('  '); $i += 2 }
                else { [void]$out.Append(' '); $i++ }
                continue
            }
            if ($inVerbatim) {
                if ($ch -eq '"') {
                    if ($next -eq '"') { [void]$out.Append('  '); $i += 2; continue }
                    $inVerbatim = $false; [void]$out.Append(' '); $i++; continue
                }
                [void]$out.Append(' '); $i++
                continue
            }
            if ($ch -eq '/' -and $next -eq '/') {
                [void]$out.Append(' ' * ($line.Length - $i))
                $i = $line.Length
                continue
            }
            if ($ch -eq '/' -and $next -eq '*') { $inBlockComment = $true; [void]$out.Append('  '); $i += 2; continue }
            if ($ch -eq '@' -and $next -eq '"') { $inVerbatim = $true; [void]$out.Append('  '); $i += 2; continue }
            if ($ch -eq '"') {
                # Ordinary string, possibly interpolated. Interpolation holes can
                # contain arbitrary code; masking the whole literal is the
                # conservative choice - a construct inside a hole is not
                # enumerated rather than enumerated wrongly.
                [void]$out.Append(' ')
                $i++
                while ($i -lt $line.Length) {
                    if ($line[$i] -eq '\') {
                        [void]$out.Append('  ')
                        $i += 2
                        continue
                    }
                    if ($line[$i] -eq '"') { [void]$out.Append(' '); $i++; break }
                    [void]$out.Append(' ')
                    $i++
                }
                continue
            }
            if ($ch -eq "'") {
                [void]$out.Append(' ')
                $i++
                while ($i -lt $line.Length) {
                    if ($line[$i] -eq '\') { [void]$out.Append('  '); $i += 2; continue }
                    if ($line[$i] -eq "'") { [void]$out.Append(' '); $i++; break }
                    [void]$out.Append(' ')
                    $i++
                }
                continue
            }
            [void]$out.Append($ch)
            $i++
        }
        [void]$masked.Add($out.ToString())
    }
    return @{
        Lines = $masked.ToArray()
        Truncated = ($truncated -or $inBlockComment -or $inVerbatim)
    }
}

function Split-ReviewerConstructArguments {
    <#
        Splits an argument list at top-level commas only - not inside nested
        parentheses, brackets, braces, or a generic argument list.

        Generics are the awkward case: `<` and `>` are also comparison
        operators. Depth is only taken when a `<` is preceded by an identifier
        character and the segment closes on the same argument, which is the
        shape a generic argument list actually has; anything else is treated as
        an operator. When that heuristic cannot be applied cleanly the whole
        list is reported unsplittable, and the construct becomes `unknown`.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $parts = [System.Collections.Generic.List[object]]::new()
    $depth = 0
    $angle = 0
    $start = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        switch ($ch) {
            '(' { $depth++; continue }
            '[' { $depth++; continue }
            '{' { $depth++; continue }
            ')' { $depth--; continue }
            ']' { $depth--; continue }
            '}' { $depth--; continue }
            '<' {
                $prev = if ($i -gt 0) { $Text[$i - 1] } else { [char]0 }
                if ([char]::IsLetterOrDigit($prev) -or $prev -eq '_') { $angle++ }
                continue
            }
            '>' { if ($angle -gt 0) { $angle-- }; continue }
            ',' {
                if ($depth -eq 0 -and $angle -eq 0) {
                    [void]$parts.Add(@{ Text = $Text.Substring($start, $i - $start); Offset = $start })
                    $start = $i + 1
                }
                continue
            }
        }
        if ($depth -lt 0) { return @{ Ok = $false; Arguments = @() } }
    }
    if ($depth -ne 0 -or $angle -ne 0) { return @{ Ok = $false; Arguments = @() } }
    [void]$parts.Add(@{ Text = $Text.Substring($start); Offset = $start })
    return @{ Ok = $true; Arguments = @($parts.ToArray()) }
}

function Test-ReviewerConstructArgumentNamed {
    <#
        True when an argument is SYNTACTICALLY named: an identifier followed by
        a single colon at the argument's top level.

        Deliberately narrow. A conditional's `? :`, a namespace `::`, a label,
        and a colon inside a nested call are all not this. Nothing here knows
        what the name means - only whether the caller wrote one.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $trimmed = $Text.Trim()
    if (-not $trimmed) { return $false }
    if ($trimmed -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*:') { return $false }
    $colon = $trimmed.IndexOf(':')
    if ($colon -lt 0) { return $false }
    # `::` is a qualified name, not an argument name.
    if ($colon + 1 -lt $trimmed.Length -and $trimmed[$colon + 1] -eq ':') { return $false }
    # A `?` before the colon means the colon belongs to a conditional.
    if ($trimmed.Substring(0, $colon).IndexOf('?') -ge 0) { return $false }
    return $true
}

function Get-ReviewerChangedInvocations {
    <#
        Every invocation in this file that OPENS on a changed line and spans
        more than one line. "Opens on a changed line" is the rule because that
        is the line the pull request is responsible for; a call whose opening
        line is untouched is not this change's construct even if an argument
        below it moved.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ChangedLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines
    )
    $changed = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in @($ChangedLines)) { [void]$changed.Add([int]$line) }
    $found = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $MaskedLines.Count; $index++) {
        if ($found.Count -ge $script:ReviewerConstructMaxPerFile) { break }
        $lineNumber = $index + 1
        if (-not $changed.Contains($lineNumber)) { continue }
        $masked = [string]$MaskedLines[$index]

        # The opening paren of a call that does not close on this line. Scanned
        # right to left so the OUTERMOST unclosed call on the line wins: for
        # `Outer(Inner(a), ` the construct is Outer, and Inner is a nested call
        # inside one of its arguments.
        $depth = 0
        $openIndex = -1
        for ($column = $masked.Length - 1; $column -ge 0; $column--) {
            $ch = $masked[$column]
            if ($ch -eq ')') { $depth++ ; continue }
            if ($ch -ne '(') { continue }
            if ($depth -gt 0) { $depth--; continue }
            $before = $masked.Substring(0, $column).TrimEnd()
            if ($before -match '[A-Za-z0-9_>\]]$') { $openIndex = $column }
        }
        if ($openIndex -lt 0) { continue }

        $calleeText = $masked.Substring(0, $openIndex).TrimEnd()
        $callee = ""
        if ($calleeText -match '([A-Za-z_][A-Za-z0-9_]*)\s*(<[^<>]*>)?$') { $callee = $Matches[1] }
        if (-not $callee) { continue }

        # Walk forward to the matching close paren, bounded.
        $body = [System.Text.StringBuilder]::new()
        [void]$body.Append($masked.Substring($openIndex + 1))
        $depth = 1
        $endLine = $lineNumber
        $closed = $false
        for ($column = $openIndex + 1; $column -lt $masked.Length; $column++) {
            $ch = $masked[$column]
            if ($ch -eq '(') { $depth++ }
            elseif ($ch -eq ')') { $depth-- ; if ($depth -eq 0) { $closed = $true; break } }
        }
        if ($closed) { continue }  # single-line call: not a multi-line construct

        $spanLines = 1
        for ($scan = $index + 1; $scan -lt $MaskedLines.Count; $scan++) {
            $spanLines++
            if ($spanLines -gt $script:ReviewerConstructMaxSpanLines) { break }
            $scanLine = [string]$MaskedLines[$scan]
            [void]$body.Append("`n")
            $consumed = $scanLine.Length
            for ($column = 0; $column -lt $scanLine.Length; $column++) {
                $ch = $scanLine[$column]
                if ($ch -eq '(') { $depth++ }
                elseif ($ch -eq ')') {
                    $depth--
                    if ($depth -eq 0) { $consumed = $column; $closed = $true; break }
                }
            }
            [void]$body.Append($scanLine.Substring(0, $consumed))
            $endLine = $scan + 1
            if ($closed) { break }
        }

        $argumentText = $body.ToString()
        $split = Split-ReviewerConstructArguments -Text $argumentText
        $named = ""
        $argumentCount = 0
        $status = "known"
        if (-not $closed) { $status = "unknown" }
        elseif (-not $split.Ok) { $status = "unknown" }
        else {
            $arguments = @($split.Arguments)
            # A lone empty argument is a no-argument call.
            if ($arguments.Count -eq 1 -and -not ([string]$arguments[0].Text).Trim()) { $arguments = @() }
            $argumentCount = $arguments.Count
            if ($argumentCount -gt $script:ReviewerConstructMaxArguments) { $status = "unknown" }
            else {
                $flags = [System.Text.StringBuilder]::new()
                foreach ($argument in $arguments) {
                    [void]$flags.Append($(if (Test-ReviewerConstructArgumentNamed -Text ([string]$argument.Text)) { 'n' } else { 'p' }))
                }
                $named = $flags.ToString()
            }
        }

        [void]$found.Add([pscustomobject][ordered]@{
                kind = "invocation"
                path = $Path
                line = $lineNumber
                endLine = $endLine
                callee = $callee
                argumentCount = $argumentCount
                # One character per argument, in order: 'n' syntactically named,
                # 'p' positional. Empty when the shape could not be established.
                argumentNaming = $named
                status = $status
            })
    }
    return , $found.ToArray()
}

function Get-ReviewerConstructDeclarationAt {
    <#
        The declaration shape at one line, or $null. Split out so the changed
        set and the unchanged neighbours it is compared against are recognized
        by exactly the same rule - a precedent found by a looser test than the
        one that found the change would not be a precedent.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines,
        [Parameter(Mandatory)][int]$Index
    )
    if ($Index -lt 0 -or $Index -ge $MaskedLines.Count) { return $null }
    $masked = ([string]$MaskedLines[$Index]).Trim()
    if (-not $masked) { return $null }
    if ($masked.StartsWith('[')) { return $null }
    if ($masked -notmatch '^[A-Za-z_][A-Za-z0-9_<>,\[\]\.\s]*\s([A-Za-z_][A-Za-z0-9_]*)\s*(\(|\{|=>|$)') { return $null }
    $name = $Matches[1]
    if ($masked.StartsWith('return ') -or $masked.StartsWith('throw ') -or $masked.StartsWith('new ')) { return $null }

    $attributes = [System.Collections.Generic.List[string]]::new()
    $truncated = $false
    for ($above = $Index - 1; $above -ge 0; $above--) {
        $line = ([string]$MaskedLines[$above]).Trim()
        if (-not $line) { continue }
        if (-not $line.StartsWith('[')) { break }
        # The full dotted name, not its first segment: reporting
        # `System.Diagnostics.CodeAnalysis.SuppressMessage` as "System" tells a
        # reader nothing and could collide with an unrelated attribute.
        foreach ($match in [regex]::Matches($line, '\[\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)')) {
            if ($attributes.Count -ge $script:ReviewerConstructMaxAttributes) { $truncated = $true; break }
            [void]$attributes.Add(($match.Groups[1].Value -replace '\s+', ''))
        }
        if ($truncated) { break }
    }
    $sorted = [string[]]@($attributes.ToArray())
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return @{ Name = $name; Attributes = @($sorted); Truncated = $truncated }
}

function Get-ReviewerChangedDeclarations {
    <#
        Every declaration-looking line that CHANGED, together with the
        attribute names attached to it immediately above, and the attribute
        names on its nearest UNCHANGED declaration neighbours in the same file.

        "Declaration-looking" is a shape, not a language concept: a line that
        introduces a named thing and is not itself a statement continuation.
        Attribute names are reported verbatim; what an attribute means is
        entirely the transported rule's business. The neighbour sets are the
        deterministic half of a precedent argument - whether the surrounding
        code already does the thing the rule asks for is a fact, and it should
        not depend on which slice a model happened to look at.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ChangedLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines
    )
    $changed = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in @($ChangedLines)) { [void]$changed.Add([int]$line) }
    $found = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $MaskedLines.Count; $index++) {
        if ($found.Count -ge $script:ReviewerConstructMaxPerFile) { break }
        $lineNumber = $index + 1
        if (-not $changed.Contains($lineNumber)) { continue }
        $declaration = Get-ReviewerConstructDeclarationAt -MaskedLines $MaskedLines -Index $index
        if ($null -eq $declaration) { continue }

        # Nearest unchanged declaration above and below, by the same test.
        $siblingAttributes = [System.Collections.Generic.List[string]]::new()
        $siblingCount = 0
        foreach ($direction in @(-1, 1)) {
            $scan = $index + $direction
            while ($scan -ge 0 -and $scan -lt $MaskedLines.Count) {
                if (-not $changed.Contains($scan + 1)) {
                    $neighbour = Get-ReviewerConstructDeclarationAt -MaskedLines $MaskedLines -Index $scan
                    if ($null -ne $neighbour) {
                        $siblingCount++
                        foreach ($attribute in @($neighbour.Attributes)) {
                            if ($siblingAttributes.Count -ge $script:ReviewerConstructMaxAttributes) { break }
                            if ($siblingAttributes -cnotcontains $attribute) { [void]$siblingAttributes.Add($attribute) }
                        }
                        break
                    }
                }
                $scan += $direction
            }
        }
        $sortedSiblings = [string[]]@($siblingAttributes.ToArray())
        [Array]::Sort($sortedSiblings, [StringComparer]::Ordinal)

        [void]$found.Add([pscustomobject][ordered]@{
                kind = "declaration"
                path = $Path
                line = $lineNumber
                endLine = $lineNumber
                name = $declaration.Name
                attributes = @($declaration.Attributes)
                siblingAttributes = @($sortedSiblings)
                siblingCount = $siblingCount
                status = $(if ([bool]$declaration.Truncated) { "unknown" } else { "known" })
            })
    }
    return , $found.ToArray()
}

function Get-ReviewerConstructAttributeFrequency {
    <#
        How often each attribute name appears across ALL declaration-shaped
        lines in a file, changed or not.

        Nearest-neighbour precedent is not enough on its own, and the change set
        that motivated this proves it: in one test file the attribute a rule
        asks for sits on five declarations just past the changed block, and in
        another it appears nowhere at all. Those two files deserve opposite
        answers, and which one a reviewer gives should not depend on which slice
        it happened to read. A count over the whole file is a fact; sampling is
        not.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines)
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $declarationCount = 0
    for ($index = 0; $index -lt $MaskedLines.Count; $index++) {
        $declaration = Get-ReviewerConstructDeclarationAt -MaskedLines $MaskedLines -Index $index
        if ($null -eq $declaration) { continue }
        $declarationCount++
        foreach ($attribute in @($declaration.Attributes)) {
            if ($counts.ContainsKey($attribute)) { $counts[$attribute] = $counts[$attribute] + 1 }
            elseif ($counts.Count -lt $script:ReviewerConstructMaxAttributeNames) { $counts[$attribute] = 1 }
        }
    }
    $names = [string[]]@($counts.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $names) {
        [void]$rows.Add([pscustomobject][ordered]@{ attribute = $name; declarations = [int]$counts[$name] })
    }
    return @{ DeclarationCount = $declarationCount; Attributes = @($rows.ToArray()) }
}

function Get-ReviewerChangedConstructs {
    <#
        The deterministic construct set for one change set. Files are processed
        in ordinal path order and constructs numbered in that order, so the same
        change set always produces the same ids - an anchor that means something
        different between two runs would be worse than no anchor at all.

        -Files takes @{ Path; Lines; ChangedLines } per delivered file.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [int]$MaxTotal = $script:ReviewerConstructMaxTotal
    )
    $ordered = @(@($Files) | Sort-Object -Property @{ Expression = { [string]$_.Path } })
    $invocations = [System.Collections.Generic.List[object]]::new()
    $declarations = [System.Collections.Generic.List[object]]::new()
    $partialFiles = [System.Collections.Generic.List[string]]::new()
    $fileSummaries = [System.Collections.Generic.List[object]]::new()

    foreach ($file in $ordered) {
        $path = [string]$file.Path
        $lines = @($file.Lines)
        $changedLines = @($file.ChangedLines)
        if ($lines.Count -eq 0 -or $changedLines.Count -eq 0) { continue }
        $maskResult = Get-ReviewerConstructMaskedLines -Lines $lines
        if ([bool]$maskResult.Truncated) { [void]$partialFiles.Add($path) }
        # Assign first, then wrap. These helpers return `, @(...)` so a
        # single-element result stays a list, and @(f x) in expression position
        # would keep that outer wrapper instead of unrolling it.
        $fileInvocations = Get-ReviewerChangedInvocations -Path $path -Lines $lines -ChangedLines $changedLines -MaskedLines $maskResult.Lines
        foreach ($construct in @($fileInvocations)) { [void]$invocations.Add($construct) }
        $fileDeclarations = Get-ReviewerChangedDeclarations -Path $path -ChangedLines $changedLines -MaskedLines $maskResult.Lines
        foreach ($construct in @($fileDeclarations)) { [void]$declarations.Add($construct) }
        $frequency = Get-ReviewerConstructAttributeFrequency -MaskedLines $maskResult.Lines
        [void]$fileSummaries.Add([pscustomobject][ordered]@{
                path = $path
                declarationCount = [int]$frequency.DeclarationCount
                attributeFrequency = @($frequency.Attributes)
            })
    }

    $result = [System.Collections.Generic.List[object]]::new()
    $truncated = $false
    $invocationIndex = 0
    foreach ($construct in $invocations) {
        if ($result.Count -ge $MaxTotal) { $truncated = $true; break }
        [void]$result.Add([pscustomobject][ordered]@{
                constructId = "mi$invocationIndex"
                kind = "invocation"
                path = $construct.path
                line = [int]$construct.line
                endLine = [int]$construct.endLine
                callee = [string]$construct.callee
                argumentCount = [int]$construct.argumentCount
                argumentNaming = [string]$construct.argumentNaming
                attributes = @()
                siblingAttributes = @()
                status = [string]$construct.status
            })
        $invocationIndex++
    }
    $declarationIndex = 0
    foreach ($construct in $declarations) {
        if ($result.Count -ge $MaxTotal) { $truncated = $true; break }
        [void]$result.Add([pscustomobject][ordered]@{
                constructId = "dc$declarationIndex"
                kind = "declaration"
                path = $construct.path
                line = [int]$construct.line
                endLine = [int]$construct.endLine
                callee = [string]$construct.name
                argumentCount = 0
                argumentNaming = ""
                attributes = @($construct.attributes)
                siblingAttributes = @($construct.siblingAttributes)
                status = [string]$construct.status
            })
        $declarationIndex++
    }

    return @{
        Version = $script:ReviewerConstructVersion
        Constructs = $result.ToArray()
        Files = @($fileSummaries.ToArray())
        InvocationIds = @(@($result | Where-Object { [string]$_.kind -ceq "invocation" } | ForEach-Object { [string]$_.constructId }))
        DeclarationIds = @(@($result | Where-Object { [string]$_.kind -ceq "declaration" } | ForEach-Object { [string]$_.constructId }))
        Truncated = $truncated
        PartiallyUnderstoodFiles = @($partialFiles.ToArray())
    }
}
