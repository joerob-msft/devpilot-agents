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
$script:ReviewerConstructMaxPerFile = 30
$script:ReviewerConstructMaxTotal = 120
$script:ReviewerConstructMaxArguments = 24
$script:ReviewerConstructMaxLineLength = 4096
$script:ReviewerConstructMaxSpanLines = 80
$script:ReviewerConstructMaxAttributes = 12
$script:ReviewerConstructMaxAttributeNames = 40
# Statement keywords that are followed by a parenthesised expression or a call.
# They have a declaration's shape and a call's shape and are neither.
$script:ReviewerConstructStatementKeywords = @(
    'return', 'throw', 'new', 'await', 'yield', 'else', 'case', 'using', 'lock',
    'default', 'if', 'while', 'for', 'foreach', 'switch', 'catch', 'fixed'
)
# Small next to the specialist's whole input bound on purpose: the construct
# block is an index into source the model already has, not a second copy of it.
$script:ReviewerConstructMaxPayloadBytes = 32768
$script:ReviewerConstructUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Test-ReviewerConstructStatementKeyword {
    <#
        True when a line starts with a statement keyword. `if (`, `while (`,
        `await Foo(` and `return Bar(` all have the shape of a declaration or of
        a call and are neither; enumerating them puts constructs in front of a
        rule about how ARGUMENTS are passed that have no arguments at all, and
        a model may then anchor a finding on an `if`.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $trimmed = $Text.TrimStart()
    foreach ($keyword in $script:ReviewerConstructStatementKeywords) {
        if (-not $trimmed.StartsWith($keyword, [StringComparison]::Ordinal)) { continue }
        if ($trimmed.Length -eq $keyword.Length) { return $true }
        $next = $trimmed[$keyword.Length]
        # `iffy(` is not `if (`. Only a non-identifier character after the
        # keyword makes it a keyword.
        if (-not ([char]::IsLetterOrDigit($next) -or $next -eq '_')) { return $true }
    }
    return $false
}

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
    $commentLines = [System.Collections.Generic.HashSet[int]]::new()
    $inBlockComment = $false
    $inVerbatim = $false
    $truncated = $false
    $lineNumber = 0

    foreach ($rawLine in @($Lines)) {
        $line = [string]$rawLine
        $lineNumber++
        $hasComment = $inBlockComment
        if ($line.Length -gt $script:ReviewerConstructMaxLineLength) {
            # A line longer than any real source line is not worth scanning and
            # is not worth guessing about either.
            $truncated = $true
            [void]$masked.Add(' ' * $line.Length)
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
                $hasComment = $true
                [void]$out.Append(' ' * ($line.Length - $i))
                $i = $line.Length
                continue
            }
            if ($ch -eq '/' -and $next -eq '*') { $inBlockComment = $true; $hasComment = $true; [void]$out.Append('  '); $i += 2; continue }
            if ($ch -eq '@' -and $next -eq '"') { $inVerbatim = $true; [void]$out.Append('  '); $i += 2; continue }
            if ($ch -eq '"' -and $next -eq '"' -and ($i + 2 -lt $line.Length) -and $line[$i + 2] -eq '"') {
                # A raw string literal. Masking it as an ordinary string would
                # end the literal at the first line break and scan its body as
                # code, which manufactures constructs out of documentation. The
                # multi-line form is not tracked across lines here, so the file
                # is reported as only partly understood instead.
                $truncated = $true
                [void]$out.Append(' ' * ($line.Length - $i))
                $i = $line.Length
                continue
            }
            if ($ch -eq '"') {
                # Ordinary string, possibly interpolated. Interpolation holes can
                # contain arbitrary code; masking the whole literal is the
                # conservative choice - a construct inside a hole is not
                # enumerated rather than enumerated wrongly.
                [void]$out.Append(' ')
                $i++
                while ($i -lt $line.Length) {
                    if ($line[$i] -eq '\') {
                        # Two characters unless the escape is the last one on
                        # the line: appending two spaces for one character would
                        # make the masked line longer than the raw line and
                        # break the column identity this function promises.
                        $span = [Math]::Min(2, $line.Length - $i)
                        [void]$out.Append(' ' * $span)
                        $i += $span
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
                    if ($line[$i] -eq '\') {
                        $span = [Math]::Min(2, $line.Length - $i)
                        [void]$out.Append(' ' * $span)
                        $i += $span
                        continue
                    }
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
        if ($hasComment) { [void]$commentLines.Add($lineNumber) }
    }
    return @{
        Lines = $masked.ToArray()
        CommentLines = $commentLines
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

        The walk stops at the first line that was never delivered. Source
        arrives as slices with gaps between them, and a walk that treated a gap
        as blank source would happily adopt a closing bracket from unrelated
        code thirty lines away and report a confident, fabricated argument
        shape - which is exactly the kind of wrong answer this whole layer
        exists to prevent.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ChangedLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines,
        [AllowEmptyCollection()][int[]]$DeliveredLines = @(),
        # The same per-line declaration index the declarations use, so a method
        # signature is recognised by exactly one rule rather than two.
        [AllowNull()][AllowEmptyCollection()][object[]]$DeclarationIndex = @()
    )
    $changed = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in @($ChangedLines)) { [void]$changed.Add([int]$line) }
    $delivered = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in @($DeliveredLines)) { [void]$delivered.Add([int]$line) }
    $deliveryKnown = ($delivered.Count -gt 0)
    $found = [System.Collections.Generic.List[object]]::new()
    $truncated = $false

    for ($index = 0; $index -lt $MaskedLines.Count; $index++) {
        if ($found.Count -ge $script:ReviewerConstructMaxPerFile) { $truncated = $true; break }
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
        # A declaration's parameter list has the same shape as a call: a name,
        # an open paren, and a wrap. It is not a call, and a rule about how
        # arguments are passed does not reach it. Every run so far has produced
        # candidates on declaration signatures that cross-verification then had
        # to throw out one at a time - wasted work at best, and noise on a pull
        # request at worst. Declarations are enumerated already, as `dc`.
        if ($null -ne $DeclarationIndex[$index]) { continue }
        # `if (`, `while (`, `foreach (` are not calls either, and the
        # declaration recogniser deliberately excludes them, so they would
        # otherwise arrive here unfiltered.
        if (Test-ReviewerConstructStatementKeyword -Text $masked) { continue }

        # Walk forward to the matching close paren, bounded. A RAW copy of the
        # same span is kept alongside the masked one: masking blanks string and
        # char literals, so `Log(` + `"text");` masks to an argument list that
        # looks empty. Deciding "no arguments" off the masked text would erase
        # every call whose only argument is a literal.
        $body = [System.Text.StringBuilder]::new()
        $rawBody = [System.Text.StringBuilder]::new()
        [void]$body.Append($masked.Substring($openIndex + 1))
        $rawLine = [string]$Lines[$index]
        if ($openIndex + 1 -le $rawLine.Length) { [void]$rawBody.Append($rawLine.Substring($openIndex + 1)) }
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
        $crossedGap = $false
        for ($scan = $index + 1; $scan -lt $MaskedLines.Count; $scan++) {
            if ($deliveryKnown -and -not $delivered.Contains($scan + 1)) { $crossedGap = $true; break }
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
            $scanRaw = [string]$Lines[$scan]
            [void]$rawBody.Append("`n")
            if ($consumed -le $scanRaw.Length) { [void]$rawBody.Append($scanRaw.Substring(0, $consumed)) }
            else { [void]$rawBody.Append($scanRaw) }
            $endLine = $scan + 1
            if ($closed) { break }
        }

        $argumentText = $body.ToString()
        $split = Split-ReviewerConstructArguments -Text $argumentText
        $named = ""
        $argumentCount = 0
        $status = "known"
        if (-not $closed) { $status = "unknown" }
        elseif ($crossedGap) { $status = "unknown" }
        elseif (-not $split.Ok) { $status = "unknown" }
        else {
            $arguments = @($split.Arguments)
            # A lone empty argument is a no-argument call - but only when the
            # RAW span is empty too. Masked-empty with raw content is a single
            # literal argument, which is a real argument.
            if ($arguments.Count -eq 1 -and -not ([string]$arguments[0].Text).Trim() -and -not $rawBody.ToString().Trim()) { $arguments = @() }
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
    return @{ Constructs = @($found.ToArray()); Truncated = $truncated }
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
        [Parameter(Mandatory)][int]$Index,
        # The delivered-line set, already built. Taking the SET rather than the
        # list matters: this is called once per line of a file, and rebuilding a
        # hash set per call turned enumeration into an O(lines x delivered)
        # walk - twenty-seven seconds for one ordinary file, minutes for a large
        # one, on the mandatory path of every review.
        $Delivered = $null
    )
    if ($Index -lt 0 -or $Index -ge $MaskedLines.Count) { return $null }
    if ($null -ne $Delivered -and $Delivered.Count -gt 0 -and -not $Delivered.Contains($Index + 1)) { return $null }
    $masked = ([string]$MaskedLines[$Index]).Trim()
    if (-not $masked) { return $null }
    # An attribute group on the same line as the declaration is still a
    # declaration. Skipping those lines undercounts exactly the attribute a
    # rule is asking about.
    $inlineAttributes = [System.Collections.Generic.List[string]]::new()
    while ($masked.StartsWith('[')) {
        $close = $masked.IndexOf(']')
        if ($close -lt 0) { return $null }
        foreach ($match in [regex]::Matches($masked.Substring(0, $close + 1), '\[\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)')) {
            [void]$inlineAttributes.Add(($match.Groups[1].Value -replace '\s+', ''))
        }
        $masked = $masked.Substring($close + 1).Trim()
        if (-not $masked) { return $null }
    }
    if ($masked -notmatch '^[A-Za-z_][A-Za-z0-9_<>,\[\]\.\s]*\s([A-Za-z_][A-Za-z0-9_]*)\s*(\(|\{|=>|$)') { return $null }
    $name = $Matches[1]
    # Statement keywords that happen to be followed by a call look like
    # declarations to a shape test. Counting them inflates the declaration set
    # and dilutes the per-file attribute ratio a rule turns on.
    if (Test-ReviewerConstructStatementKeyword -Text $masked) { return $null }

    $attributes = [System.Collections.Generic.List[string]]::new()
    foreach ($attribute in $inlineAttributes) { [void]$attributes.Add($attribute) }
    $truncated = $false
    for ($above = $Index - 1; $above -ge 0; $above--) {
        # A blank line in the file image is either genuinely blank or a line the
        # transport never delivered - the image is sparse. Walking through it
        # would attach an attribute fifty undelivered lines away to this
        # declaration, and the whole point of these attributes is that they are
        # facts. Stop at the first line that is not a delivered attribute line.
        if ($null -ne $Delivered -and $Delivered.Count -gt 0 -and -not $Delivered.Contains($above + 1)) { break }
        $line = ([string]$MaskedLines[$above]).Trim()
        if (-not $line) { break }
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
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines,
        # The per-line declaration index, built once for the file. Recognising
        # each line here instead would mean walking the file three times over
        # and rebuilding a delivered-line set on every call.
        [AllowNull()][AllowEmptyCollection()][object[]]$DeclarationIndex = @()
    )
    $changed = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in @($ChangedLines)) { [void]$changed.Add([int]$line) }
    $found = [System.Collections.Generic.List[object]]::new()
    $truncated = $false

    # Attribute names that appear on UNCHANGED declarations in this file. A rule
    # about an attribute needs to know whether the file already uses it: a
    # changed declaration missing something several unchanged neighbours carry
    # is a different situation from one missing something nobody here has ever
    # used, and those two deserve opposite answers. Purely a shape fact - it
    # says an attribute is present there and absent here, never that either is
    # wrong.
    $unchangedAttributes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $attributesTruncated = $false
    for ($scan = 0; $scan -lt $DeclarationIndex.Count; $scan++) {
        if ($changed.Contains($scan + 1)) { continue }
        $neighbour = $DeclarationIndex[$scan]
        if ($null -eq $neighbour) { continue }
        foreach ($attribute in @($neighbour.Attributes)) {
            if ($unchangedAttributes.Count -ge $script:ReviewerConstructMaxAttributeNames) { $attributesTruncated = $true; break }
            [void]$unchangedAttributes.Add($attribute)
        }
    }

    for ($index = 0; $index -lt $DeclarationIndex.Count; $index++) {
        if ($found.Count -ge $script:ReviewerConstructMaxPerFile) { $truncated = $true; break }
        $lineNumber = $index + 1
        if (-not $changed.Contains($lineNumber)) { continue }
        $declaration = $DeclarationIndex[$index]
        if ($null -eq $declaration) { continue }

        # Nearest unchanged declaration above and below, by the same test. The
        # walk stops at the first undelivered line: a neighbour on the far side
        # of a gap nobody read is not this declaration's neighbour, and calling
        # it one would make the precedent a guess dressed as a fact.
        $siblingAttributes = [System.Collections.Generic.List[string]]::new()
        $siblingCount = 0
        foreach ($direction in @(-1, 1)) {
            $scan = $index + $direction
            while ($scan -ge 0 -and $scan -lt $DeclarationIndex.Count) {
                # A gap the transport never delivered ends the walk. The index
                # holds $null both for "not a declaration" and for "not
                # delivered", so undelivered lines are distinguished by the
                # delivered set the index was built with - which is why the walk
                # stops at the first line that is neither changed nor a
                # declaration rather than scanning past it indefinitely.
                if (-not $changed.Contains($scan + 1)) {
                    $neighbour = $DeclarationIndex[$scan]
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
        $absent = [string[]]@(@($unchangedAttributes) | Where-Object { @($declaration.Attributes) -cnotcontains $_ })
        [Array]::Sort($absent, [StringComparer]::Ordinal)

        [void]$found.Add([pscustomobject][ordered]@{
                kind = "declaration"
                path = $Path
                line = $lineNumber
                endLine = $lineNumber
                name = $declaration.Name
                attributes = @($declaration.Attributes)
                siblingAttributes = @($sortedSiblings)
                absentHere = @($absent)
                siblingCount = $siblingCount
                # `absentHere` stops being a complete statement once the
                # file-wide attribute set hit its cap: "absent nowhere else"
                # would then mean "the wrapper stopped counting", which a rule
                # reasoning from it must not be told silently.
                status = $(if ([bool]$declaration.Truncated -or $attributesTruncated) { "unknown" } else { "known" })
            })
    }
    return @{ Constructs = @($found.ToArray()); Truncated = $truncated }
}

function Get-ReviewerConstructAttributeFrequency {
    <#
        How often each attribute name appears across every delivered
        declaration-shaped line in a file, changed or not.

        Nearest-neighbour precedent is not enough on its own, and the change set
        that motivated this proves it: in one test file the attribute a rule
        asks for sits on five declarations just past the changed block, and in
        another it appears nowhere at all. Those two files deserve opposite
        answers, and which one a reviewer gives should not depend on which slice
        it happened to read. A count over what was read is a fact; sampling is
        not. Lines the transport never delivered are not counted, because a
        denominator that includes lines nobody read is not a fact either.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$DeclarationIndex = @()
    )
    $counts = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $declarationCount = 0
    for ($index = 0; $index -lt $DeclarationIndex.Count; $index++) {
        $declaration = $DeclarationIndex[$index]
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

function Get-ReviewerConstructDeclarationIndex {
    <#
        Recognises every line of a file once and returns the result per line,
        $null where the line is not a delivered declaration.

        Built once per file because three separate things need it - the changed
        declarations, their nearest unchanged neighbours, and the file-wide
        attribute count - and recognising each line three times, rebuilding a
        delivered-line set on every call, turned enumeration into tens of
        seconds for an ordinary file and minutes for a large one. This runs on
        every review, before the model does.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines,
        [AllowEmptyCollection()][int[]]$DeliveredLines = @()
    )
    $delivered = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in @($DeliveredLines)) { [void]$delivered.Add([int]$line) }
    $index = [object[]]::new($MaskedLines.Count)
    for ($position = 0; $position -lt $MaskedLines.Count; $position++) {
        $index[$position] = Get-ReviewerConstructDeclarationAt -MaskedLines $MaskedLines -Index $position -Delivered $delivered
    }
    # `, $index` so a one-line file stays an array, and never $null: an empty
    # file yields an empty index, which every caller iterates zero times.
    if ($null -eq $index) { $index = [object[]]::new(0) }
    return , $index
}

function Get-ReviewerConstructMember {
    <#
        Reads an optional member off either a hashtable or an object without
        tripping StrictMode. `DeliveredLines` is genuinely optional - a caller
        that does not know which lines were delivered gets the whole file
        treated as reachable - and an absent optional must not be an error.
    #>
    param([Parameter(Mandatory)]$Container, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Container) { return $null }
    if ($Container -is [System.Collections.IDictionary]) {
        if ($Container.Contains($Name)) { return $Container[$Name] }
        return $null
    }
    $property = $Container.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-ReviewerChangedComments {
    <#
        Contiguous runs of changed comment lines, one construct per run.

        A rule about documentation - what a doc block has to say, how it spells
        something, whether it exists at all - has nowhere to anchor if the only
        constructs are calls and declarations. The nearest declaration can be
        a hundred lines away, and a comment anchored on it is a comment about
        the wrong thing.

        Nothing here reads the comment's text or knows what a doc comment is.
        It knows only that these lines carry comment content and that they
        changed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ChangedLines,
        [Parameter(Mandatory)]$CommentLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines
    )
    $changed = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in @($ChangedLines)) { [void]$changed.Add([int]$line) }
    $found = [System.Collections.Generic.List[object]]::new()
    $truncated = $false

    $lineNumber = 1
    while ($lineNumber -le $MaskedLines.Count) {
        if (-not ($changed.Contains($lineNumber) -and $CommentLines.Contains($lineNumber))) {
            $lineNumber++
            continue
        }
        if ($found.Count -ge $script:ReviewerConstructMaxPerFile) { $truncated = $true; break }
        $start = $lineNumber
        $end = $lineNumber
        while (($end + 1) -le $MaskedLines.Count -and
            $changed.Contains($end + 1) -and $CommentLines.Contains($end + 1) -and
            ($end + 1 - $start) -lt $script:ReviewerConstructMaxSpanLines) {
            $end++
        }
        [void]$found.Add([pscustomobject][ordered]@{
                kind = "comment"
                path = $Path
                line = $start
                endLine = $end
                status = "known"
            })
        $lineNumber = $end + 1
    }
    return @{ Constructs = @($found.ToArray()); Truncated = $truncated }
}

function Get-ReviewerChangedAssignments {
    <#
        Changed lines that assign to something that already exists.

        Deliberately narrow: a target, a single `=` that is not part of a
        comparison or a compound operator, and a target that is a plain name or
        member/index path rather than a declaration with a type in front of it.
        A declaration with an initializer is a declaration, not a reassignment,
        and calling it one would invent violations of an immutability rule that
        the code does not commit.

        Whether reassigning is wrong here is the transported rule's business.
        This only says: this changed line writes to this name.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ChangedLines,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$MaskedLines
    )
    $changed = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in @($ChangedLines)) { [void]$changed.Add([int]$line) }
    $found = [System.Collections.Generic.List[object]]::new()
    $truncated = $false

    for ($index = 0; $index -lt $MaskedLines.Count; $index++) {
        if ($found.Count -ge $script:ReviewerConstructMaxPerFile) { $truncated = $true; break }
        $lineNumber = $index + 1
        if (-not $changed.Contains($lineNumber)) { continue }
        $masked = ([string]$MaskedLines[$index]).Trim()
        if (-not $masked) { continue }

        # An assignment STATEMENT ends in a semicolon. Object and collection
        # initializer entries do not, and neither does the last one before the
        # closing brace - which is how initialization gets mistaken for
        # reassignment. A write whose right-hand side spans lines is missed by
        # this, which is the conservative direction.
        if (-not $masked.EndsWith(";")) { continue }
        if ($masked -notmatch '^([A-Za-z_][A-Za-z0-9_]*(?:\s*(?:\.|\?\.)\s*[A-Za-z_][A-Za-z0-9_]*|\s*\[[^\[\]]*\])*)\s*=([^=].*|)$') { continue }
        $target = ($Matches[1] -replace '\s+', '')
        $rest = [string]$Matches[2]
        # `=>` is a lambda or an expression-bodied member, not an assignment.
        if ($rest.StartsWith(">")) { continue }
        # A leading type token means this line DECLARES the name.
        $before = $masked.Substring(0, $masked.IndexOf('='))
        if ($before.Trim() -cne $Matches[1].Trim()) { continue }
        foreach ($keyword in @("var", "const", "readonly", "static", "public", "private", "protected", "internal")) {
            if ($target -ceq $keyword) { $target = "" ; break }
        }
        if (-not $target) { continue }

        [void]$found.Add([pscustomobject][ordered]@{
                kind = "assignment"
                path = $Path
                line = $lineNumber
                endLine = $lineNumber
                target = $target
                status = "known"
            })
    }
    return @{ Constructs = @($found.ToArray()); Truncated = $truncated }
}

function Get-ReviewerConstructBudget {
    <#
        Splits a total construct budget across kinds so no kind is starved by a
        kind that happens to be enumerated first. Kinds that need less than an
        even share release the remainder to the others, which is the only split
        that never leaves budget unused while a kind goes without.
    #>
    param([Parameter(Mandatory)][hashtable]$Counts, [Parameter(Mandatory)][int]$Total)
    $names = [string[]]@($Counts.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    # Ordinal, and stable by construction: this order decides how many
    # constructs of each kind are selected, and therefore what `mi7` means.
    # Sort-Object is neither guaranteed stable nor culture-free, and every other
    # order this file depends on is already ordinal for that reason.
    $order = [string[]]@($names)
    [Array]::Sort([int[]]@(@($order) | ForEach-Object { [int]$Counts[$_] }), $order)
    $allocation = @{}
    $remaining = $Total
    $left = @($order).Count
    foreach ($name in $order) {
        $share = if ($left -gt 0) { [int][Math]::Floor($remaining / $left) } else { 0 }
        $take = [Math]::Min([int]$Counts[$name], $share)
        $allocation[$name] = $take
        $remaining -= $take
        $left--
    }
    return $allocation
}

function Get-ReviewerConstructIdRanges {
    <#
        Compresses a run of construct ids of one kind into inclusive ranges.

        The accounting section has to be able to say "all of them" in a field
        short enough to survive the marker's length bound. Without this, a
        complete answer over a large change set is literally unwritable, and an
        unwritable answer is the same as no checklist at all.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ids)
    $items = @($Ids)
    if ($items.Count -eq 0) { return "" }
    $parts = [System.Collections.Generic.List[string]]::new()
    $runStart = $items[0]
    $previous = $items[0]
    for ($i = 1; $i -le $items.Count; $i++) {
        $current = if ($i -lt $items.Count) { [string]$items[$i] } else { "" }
        $contiguous = $false
        if ($current) {
            $previousMatch = [regex]::Match($previous, '^([a-z]{2})([0-9]+)$')
            $currentMatch = [regex]::Match($current, '^([a-z]{2})([0-9]+)$')
            if ($previousMatch.Success -and $currentMatch.Success -and
                $previousMatch.Groups[1].Value -ceq $currentMatch.Groups[1].Value -and
                ([int]$currentMatch.Groups[2].Value - [int]$previousMatch.Groups[2].Value) -eq 1) {
                $contiguous = $true
            }
        }
        if (-not $contiguous) {
            if ($runStart -ceq $previous) { [void]$parts.Add($runStart) }
            else { [void]$parts.Add("$runStart-$previous") }
            $runStart = $current
        }
        $previous = $current
    }
    return ($parts -join ",")
}

function Select-ReviewerConstructsAcrossFiles {
    <#
        Takes up to -Limit constructs of one kind, round-robin across the files
        they came from, then restores path-and-line order for numbering.

        Straight truncation would give the whole budget to whichever files sort
        first and nothing at all to the rest. On a change set where the tests
        sort last, that means an ownership or assertion rule is judged against
        no test anchor whatsoever while the row still reads as an answer - the
        exact silent miss this enumeration exists to prevent.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Constructs,
        [Parameter(Mandatory)][int]$Limit
    )
    $items = @($Constructs)
    if ($Limit -le 0) { return @{ Constructs = @(); Truncated = ($items.Count -gt 0) } }
    if ($items.Count -le $Limit) { return @{ Constructs = $items; Truncated = $false } }

    $byPath = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($item in $items) {
        $path = [string]$item.path
        if (-not $byPath.Contains($path)) { $byPath[$path] = [System.Collections.Generic.List[object]]::new() }
        [void]$byPath[$path].Add($item)
    }
    $taken = [System.Collections.Generic.List[object]]::new()
    $round = 0
    while ($taken.Count -lt $Limit) {
        $addedThisRound = $false
        foreach ($path in @($byPath.Keys)) {
            if ($taken.Count -ge $Limit) { break }
            $list = $byPath[$path]
            if ($round -ge $list.Count) { continue }
            [void]$taken.Add($list[$round])
            $addedThisRound = $true
        }
        if (-not $addedThisRound) { break }
        $round++
    }
    # Back into path-then-line order so ids read down the change set.
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($path in @($byPath.Keys)) {
        $forPath = @(@($taken) | Where-Object { [string]$_.path -ceq $path })
        foreach ($item in @($forPath | Sort-Object -Property @{ Expression = { [int]$_.line } }, @{ Expression = { [int]$_.endLine } })) {
            [void]$ordered.Add($item)
        }
    }
    return @{ Constructs = @($ordered.ToArray()); Truncated = $true }
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
    # Ordinal, not Sort-Object: culture-aware ordering would give the same change
    # set different construct ids on different hosts, and an id that means one
    # thing here and another there is worse than no id.
    $paths = [string[]]@(@($Files) | ForEach-Object { [string]$_.Path })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $paths) {
        foreach ($file in @($Files)) {
            if ([string]$file.Path -ceq $path -and -not $ordered.Contains($file)) { [void]$ordered.Add($file); break }
        }
    }
    $invocations = [System.Collections.Generic.List[object]]::new()
    $declarations = [System.Collections.Generic.List[object]]::new()
    $comments = [System.Collections.Generic.List[object]]::new()
    $assignments = [System.Collections.Generic.List[object]]::new()
    $partialFiles = [System.Collections.Generic.List[string]]::new()
    $fileSummaries = [System.Collections.Generic.List[object]]::new()
    $perFileTruncated = $false

    foreach ($file in $ordered) {
        $path = [string]$file.Path
        $lines = @($file.Lines)
        $changedLines = @($file.ChangedLines)
        if ($lines.Count -eq 0 -or $changedLines.Count -eq 0) { continue }
        $maskResult = Get-ReviewerConstructMaskedLines -Lines $lines
        if ([bool]$maskResult.Truncated) { [void]$partialFiles.Add($path) }
        # Assign first, then read. These helpers return a hashtable so the
        # truncation flag travels with the constructs; @(f x) in expression
        # position would keep an outer wrapper instead of unrolling it.
        $deliveredLines = @(@(Get-ReviewerConstructMember -Container $file -Name 'DeliveredLines') | Where-Object { $null -ne $_ })
        $declarationIndex = Get-ReviewerConstructDeclarationIndex -MaskedLines $maskResult.Lines -DeliveredLines $deliveredLines
        $fileInvocations = Get-ReviewerChangedInvocations -Path $path -Lines $lines -ChangedLines $changedLines -MaskedLines $maskResult.Lines -DeliveredLines $deliveredLines -DeclarationIndex $declarationIndex
        foreach ($construct in @($fileInvocations.Constructs)) { [void]$invocations.Add($construct) }
        $fileDeclarations = Get-ReviewerChangedDeclarations -Path $path -ChangedLines $changedLines -MaskedLines $maskResult.Lines -DeclarationIndex $declarationIndex
        foreach ($construct in @($fileDeclarations.Constructs)) { [void]$declarations.Add($construct) }
        $fileComments = Get-ReviewerChangedComments -Path $path -ChangedLines $changedLines -CommentLines $maskResult.CommentLines -MaskedLines $maskResult.Lines
        foreach ($construct in @($fileComments.Constructs)) { [void]$comments.Add($construct) }
        $fileAssignments = Get-ReviewerChangedAssignments -Path $path -ChangedLines $changedLines -MaskedLines $maskResult.Lines
        foreach ($construct in @($fileAssignments.Constructs)) { [void]$assignments.Add($construct) }
        if ([bool]$fileInvocations.Truncated -or [bool]$fileDeclarations.Truncated -or
            [bool]$fileComments.Truncated -or [bool]$fileAssignments.Truncated) {
            $perFileTruncated = $true
        }
        $frequency = Get-ReviewerConstructAttributeFrequency -DeclarationIndex $declarationIndex
        [void]$fileSummaries.Add([pscustomobject][ordered]@{
                path = $path
                declarationCount = [int]$frequency.DeclarationCount
                attributeFrequency = @($frequency.Attributes)
            })
    }

    # Fair split, not first-come. Filling the budget with whichever kind happens
    # to be emitted first would starve a whole kind on a change set that leans
    # one way - which is exactly the change set where the starved kind's rule
    # most needs its anchors.
    $sets = [ordered]@{
        invocation = $invocations
        declaration = $declarations
        comment = $comments
        assignment = $assignments
    }
    $prefixes = @{ invocation = "mi"; declaration = "dc"; comment = "cm"; assignment = "as" }
    $counts = @{}
    foreach ($kind in $sets.Keys) { $counts[$kind] = @($sets[$kind]).Count }

    # Allocate, emit, and if the payload is too large, shrink the WHOLE budget
    # and allocate again. Trimming the tail of a single flat list instead would
    # delete whichever kind happens to be emitted last, which is the same
    # starvation the fair split exists to prevent - and it would delete it
    # silently, leaving a scope that looks complete and is not.
    $effectiveTotal = $MaxTotal
    $truncated = $false
    $constructs = @()
    while ($true) {
        $budget = Get-ReviewerConstructBudget -Counts $counts -Total $effectiveTotal
        $result = [System.Collections.Generic.List[object]]::new()
        $capped = $false
        foreach ($kind in @($sets.Keys)) {
            $selection = Select-ReviewerConstructsAcrossFiles -Constructs @($sets[$kind]) -Limit ([int]$budget[$kind])
            if ([bool]$selection.Truncated) { $capped = $true }
            $index = 0
            foreach ($construct in @($selection.Constructs)) {
                $memberName = switch ($kind) {
                    "invocation" { "callee" }
                    "declaration" { "name" }
                    "assignment" { "target" }
                    default { "name" }
                }
                # Only the keys that mean something for this kind. Carrying an
                # empty `argumentNaming` on a comment costs bytes that come
                # straight out of the budget the pinned source needs, and it
                # invites a reader to think the field was measured and found
                # empty rather than never applicable.
                $record = [ordered]@{
                    constructId = ("{0}{1}" -f $prefixes[$kind], $index)
                    kind = $kind
                    path = [string]$construct.path
                    line = [int]$construct.line
                    endLine = [int]$construct.endLine
                }
                if ($kind -cne "comment") {
                    $record["name"] = [string](Get-ReviewerConstructMember -Container $construct -Name $memberName)
                }
                if ($kind -ceq "invocation") {
                    $record["argumentCount"] = [int](Get-ReviewerConstructMember -Container $construct -Name "argumentCount")
                    $record["argumentNaming"] = [string](Get-ReviewerConstructMember -Container $construct -Name "argumentNaming")
                }
                if ($kind -ceq "declaration") {
                    $record["attributes"] = @(Get-ReviewerConstructMember -Container $construct -Name "attributes")
                    $record["siblingAttributes"] = @(Get-ReviewerConstructMember -Container $construct -Name "siblingAttributes")
                    # Attribute names on unchanged declarations elsewhere in
                    # this file that this one does not carry. A fact, not a
                    # verdict: whether that matters is the rule's business.
                    $record["absentHere"] = @(Get-ReviewerConstructMember -Container $construct -Name "absentHere")
                }
                $record["status"] = [string]$construct.status
                [void]$result.Add([pscustomobject]$record)
                $index++
            }
        }
        $constructs = @($result.ToArray())
        if ($capped) { $truncated = $true }
        if ($constructs.Count -eq 0) { break }
        $payload = ($constructs | ConvertTo-Json -Depth 8 -Compress)
        if ([System.Text.Encoding]::UTF8.GetByteCount($payload) -le $script:ReviewerConstructMaxPayloadBytes) { break }
        $next = [int][Math]::Floor($effectiveTotal * 3 / 4)
        if ($next -ge $effectiveTotal) { $next = $effectiveTotal - 1 }
        if ($next -lt 1) { $constructs = @(); $truncated = $true; break }
        $effectiveTotal = $next
        $truncated = $true
    }

    $idsByKind = [ordered]@{}
    foreach ($kind in @($sets.Keys)) {
        $kindIds = [string[]]@(@($constructs | Where-Object { [string]$_.kind -ceq $kind } | ForEach-Object { [string]$_.constructId }))
        $idsByKind[$kind] = Get-ReviewerConstructIdRanges -Ids $kindIds
    }
    return @{
        Version = $script:ReviewerConstructVersion
        Constructs = $constructs
        Files = @($fileSummaries.ToArray())
        IdRangesByKind = $idsByKind
        Truncated = ($truncated -or $perFileTruncated)
        PartiallyUnderstoodFiles = @($partialFiles.ToArray())
    }
}
