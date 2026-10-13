#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot `
    '..\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psd1') -Force

$script:RuleIds = @(
    'exception-logging',
    'exception-propagation',
    'type-based-decisions',
    'explicit-string-comparison',
    'collection-cardinality',
    'cheap-validation',
    'async-all-the-way',
    'async-io',
    'async-wait-sync',
    'http-client-lifetime',
    'thread-safe-immutable',
    'cache-streaming',
    'typed-contracts',
    'json-contracts',
    'api-errors',
    'secret-redaction',
    'dependency-fanout',
    'test-class-code-coverage'
)

function Get-ContextualConventionRuleIds {
    return @($script:RuleIds)
}

function New-ContextualOutcome {
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)]
        [ValidateSet('compliant', 'violation', 'unknown')]
        [string]$State,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Path,
        [int]$Line = 0,
        [int]$EndLine = 0,
        [string]$Symbol = 'file',
        [string]$Evidence = ''
    )
    $outcome = [ordered]@{
        ruleId = $RuleId
        state = $State
        reason = $Reason
        path = $Path
        line = $Line
        endLine = $EndLine
        symbol = $Symbol
        evidence = $Evidence
    }
    if ($State -ceq 'violation') {
        $collector = Get-Variable -Name contextualCandidateOutcomes `
            -Scope 1 -ErrorAction SilentlyContinue
        if ($null -ne $collector -and
            $collector.Value -is [Collections.Generic.List[object]]) {
            [void]$collector.Value.Add($outcome)
        }
    }
    return $outcome
}

function Test-ContextualChangedLine {
    param([int]$Line, [object[]]$Spans)
    return @($Spans | Where-Object {
            $Line -ge [int]$_.startLine -and
            $Line -le [int]$_.endLine
        }).Count -gt 0
}

function Get-ContextualTokenModel {
    param([Parameter(Mandatory)][string]$Content)
    $scan = & (Get-Module DevPilot.TestClassCoverage) {
        param($Text)
        Get-CoverageTokens -Text $Text -IncludeLiteralTokens
    } $Content
    $tokens = @($scan.tokens)
    $lines = [ordered]@{}
    foreach ($token in $tokens) {
        $line = [string][int]$token.line
        if (-not $lines.Contains($line)) {
            $lines[$line] =
                [Collections.Generic.List[string]]::new()
        }
        [void]$lines[$line].Add([string]$token.text)
    }
    $stack = [Collections.Generic.Stack[string]]::new()
    $pairs = @{
        ')' = '('
        ']' = '['
        '}' = '{'
    }
    $unbalanced = $false
    foreach ($token in $tokens) {
        $text = [string]$token.text
        if ($text -in @('(', '[', '{')) {
            $stack.Push($text)
        }
        elseif ($pairs.Contains($text)) {
            if ($stack.Count -eq 0 -or
                $stack.Pop() -cne $pairs[$text]) {
                $unbalanced = $true
                break
            }
        }
    }
    return [ordered]@{
        tokens = $tokens
        lines = $lines
        malformed = [bool](
            $scan.unterminated -or $scan.conditional -or
            $unbalanced -or $stack.Count -gt 0)
    }
}

function Find-ContextualTokenSequence {
    param(
        [Parameter(Mandatory)][object[]]$Tokens,
        [Parameter(Mandatory)][string[]]$Sequence,
        [Parameter(Mandatory)][object[]]$Spans
    )
    for ($index = 0;
        $index -le $Tokens.Count - $Sequence.Count;
        $index++) {
        $matched = $true
        for ($offset = 0;
            $offset -lt $Sequence.Count;
            $offset++) {
            if ([string]$Tokens[
                    $index + $offset].text -cne
                $Sequence[$offset]) {
                $matched = $false
                break
            }
        }
        if ($matched -and
            (Test-ContextualChangedLine `
                -Line ([int]$Tokens[$index].line) `
                -Spans $Spans)) {
            return $Tokens[$index]
        }
    }
    return $null
}

function Get-ContextualLineText {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Lines,
        [Parameter(Mandatory)][int]$Line
    )
    $key = [string]$Line
    if (-not $Lines.Contains($key)) {
        return ''
    }
    return @($Lines[$key]) -join ' '
}

function Find-ContextualChangedLine {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Lines,
        [Parameter(Mandatory)][object[]]$Spans,
        [Parameter(Mandatory)][scriptblock]$Predicate
    )
    foreach ($key in @($Lines.Keys |
            Sort-Object { [int]$_ })) {
        $line = [int]$key
        if (-not (Test-ContextualChangedLine `
                -Line $line -Spans $Spans)) {
            continue
        }
        $text = Get-ContextualLineText `
            -Lines $Lines -Line $line
        if (& $Predicate $text) {
            return [ordered]@{
                line = $line
                text = $text
            }
        }
    }
    return $null
}

function Get-ContextualCSharpOutcomes {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Spans
    )
    $model = Get-ContextualTokenModel -Content $Content
    $tokens = @($model.tokens)
    $lines = $model.lines
    $joined = @($tokens.text) -join ' '
    $contextualCandidateOutcomes =
        [Collections.Generic.List[object]]::new()
    $results = [ordered]@{}
    foreach ($rule in $script:RuleIds) {
        $results[$rule] = New-ContextualOutcome `
            -RuleId $rule -State compliant `
            -Reason 'no-applicable-violation' `
            -Path $Path
    }

    $logLine = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '(Logger\s*\.\s*(?:Error|Critical)|\.\s*LogError)\s*\(' -and
        $text -match
            '\b(?:ex|exception)\s*\.\s*Message\b' -and
        $text -notmatch
            '\bexception\s*:\s*(?:ex|exception)\b'
    }
    if ($null -ne $logLine) {
        $results['exception-logging'] =
            New-ContextualOutcome `
                -RuleId exception-logging `
                -State violation `
                -Reason exception-object-not-logged `
                -Path $Path -Line $logLine.line `
                -EndLine $logLine.line `
                -Evidence (
                    'The logger receives exception text ' +
                    'but not the caught exception object.')
    }
    elseif ($joined -match
        '\bexception\s*:\s*(?:ex|exception)\b') {
        $results['exception-logging'] =
            New-ContextualOutcome `
                -RuleId exception-logging `
                -State compliant `
                -Reason terminal-exception-log `
                -Path $Path
    }

    $throwToken = Find-ContextualTokenSequence `
        -Tokens $tokens `
        -Sequence @('throw', 'ex', ';') `
        -Spans $Spans
    if ($null -ne $throwToken) {
        $results['exception-propagation'] =
            New-ContextualOutcome `
                -RuleId exception-propagation `
                -State violation `
                -Reason throw-expression-resets-stack `
                -Path $Path -Line ([int]$throwToken.line) `
                -EndLine ([int]$throwToken.line) `
                -Evidence (
                    'Rethrow the active exception with ' +
                    'a bare throw statement.')
    }
    else {
        $catchLine = Find-ContextualChangedLine `
            -Lines $lines -Spans $Spans -Predicate {
            param($text)
            $text -match
                'catch\s*\(\s*(?:System\s*\.\s*)?Exception\b' -and
            $text -notmatch
                'when\s*\(\s*!\s*\w+\s*\.\s*IsFatal\s*\('
        }
        if ($null -ne $catchLine -and
            $joined -notmatch
                'catch\s*\([^)]*Exception[^)]*\)\s*\{\s*throw\s*;') {
            $results['exception-propagation'] =
                New-ContextualOutcome `
                    -RuleId exception-propagation `
                    -State violation `
                    -Reason fatal-exception-filter-missing `
                    -Path $Path -Line $catchLine.line `
                    -EndLine $catchLine.line `
                    -Evidence (
                        'A generic catch handles fatal ' +
                        'exceptions without a when filter.')
        }
    }

    $messageDecision = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '\b(?:if|switch)\b.*\b(?:ex|exception)\s*\.\s*(?:Message|StackTrace)\b'
    }
    if ($null -ne $messageDecision) {
        $results['type-based-decisions'] =
            New-ContextualOutcome `
                -RuleId type-based-decisions `
                -State violation `
                -Reason exception-text-controls-behavior `
                -Path $Path -Line $messageDecision.line `
                -EndLine $messageDecision.line `
                -Evidence (
                    'Branch on an exception type or typed ' +
                    'status instead of exception text.')
    }

    $stringVariables =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
    for ($index = 0;
        $index -lt $tokens.Count - 1; $index++) {
        if ([string]$tokens[$index].text -ceq
                'string' -and
            [string]$tokens[$index + 1].text -cmatch
                '^@?[\p{L}_][\p{L}\p{N}_]*$') {
            [void]$stringVariables.Add(
                ([string]$tokens[$index + 1].text).
                    TrimStart('@'))
        }
    }
    $stringComparison = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        if ($text -match
            'StringComparison\s*\.|EqualsOrdinalInsensitively') {
            return $false
        }
        foreach ($name in $stringVariables) {
            if ($text -match (
                    "(?:\b$([regex]::Escape($name))\b\s*" +
                    "(?:=\s*=|!\s*=)|(?:=\s*=|!\s*=)\s*" +
                    "\b$([regex]::Escape($name))\b)")) {
                return $true
            }
        }
        return $text -match
            '\b(?:string|String)\s*\.\s*Equals\s*\([^,]+,[^,\)]+\)'
    }
    if ($null -ne $stringComparison) {
        $results['explicit-string-comparison'] =
            New-ContextualOutcome `
                -RuleId explicit-string-comparison `
                -State violation `
                -Reason string-comparison-not-explicit `
                -Path $Path -Line $stringComparison.line `
                -EndLine $stringComparison.line `
                -Evidence (
                    'Use explicit StringComparison semantics ' +
                    'or the canonical ordinal helper.')
    }

    $firstLine = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '\.\s*First(?:OrDefault)?\s*\(' -or
        $text -match '\[\s*0\s*\]'
    }
    if ($null -ne $firstLine) {
        if ($joined -match
            '\.\s*OrderBy' -or
            $joined -match
            '\.\s*Count\s*(?:==|!=)\s*1' -or
            $joined -match
            '\.\s*Single(?:OrDefault)?\s*\(') {
            $results['collection-cardinality'] =
                New-ContextualOutcome `
                    -RuleId collection-cardinality `
                    -State compliant `
                    -Reason ordered-or-cardinality-validated `
                    -Path $Path -Line $firstLine.line `
                    -EndLine $firstLine.line
        }
        elseif ($joined -match
            '\.\s*Where\s*\(' -or
            $joined -match '\.\s*ToList\s*\(') {
            $results['collection-cardinality'] =
                New-ContextualOutcome `
                    -RuleId collection-cardinality `
                    -State violation `
                    -Reason ambiguous-first-selection `
                    -Path $Path -Line $firstLine.line `
                    -EndLine $firstLine.line `
                    -Evidence (
                        'Validate unique cardinality and use ' +
                        'Single, or order selection deliberately.')
        }
        else {
            $results['collection-cardinality'] =
                New-ContextualOutcome `
                    -RuleId collection-cardinality `
                    -State unknown `
                    -Reason collection-origin-or-order-unknown `
                    -Path $Path -Line $firstLine.line `
                    -EndLine $firstLine.line
        }
    }

    $validatorLine = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match '(?i)validat\w*\s*='
    }
    if ($null -ne $validatorLine) {
        if ($joined -match
            '(?i)validat\w*\s*=.*(?:await|Async\s*\(|File\s*\.|HttpClient|Repository\s*\.)') {
            $results['cheap-validation'] =
                New-ContextualOutcome `
                    -RuleId cheap-validation `
                    -State violation `
                    -Reason validation-delegate-does-io-or-heavy-work `
                    -Path $Path -Line $validatorLine.line `
                    -EndLine $validatorLine.line `
                    -Evidence (
                        'Keep request validation delegates to ' +
                        'cheap in-memory sanity checks.')
        }
        else {
            $results['cheap-validation'] =
                New-ContextualOutcome `
                    -RuleId cheap-validation `
                    -State compliant `
                    -Reason validation-delegate-is-in-memory `
                    -Path $Path -Line $validatorLine.line `
                    -EndLine $validatorLine.line
        }
    }

    $resultLine = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match '\.\s*(?:Result|Wait)\b'
    }
    if ($null -ne $resultLine -and
        $joined -match '\b\w+Async\b') {
        $results['async-all-the-way'] =
            New-ContextualOutcome `
                -RuleId async-all-the-way `
                -State violation `
                -Reason task-blocking `
                -Path $Path -Line $resultLine.line `
                -EndLine $resultLine.line `
                -Evidence (
                    'Await asynchronous work rather than ' +
                    'blocking on Result or Wait.')
    }

    $syncIo = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '\bFile\s*\.\s*(?:ReadAllText|ReadAllBytes|WriteAllText|WriteAllBytes)\s*\(' -or
        $text -match
            '\.\s*(?:ReadToEnd|Read|Write)\s*\('
    }
    if ($null -ne $syncIo -and
        $joined -match '\basync\b') {
        $results['async-io'] =
            New-ContextualOutcome `
                -RuleId async-io -State violation `
                -Reason synchronous-io-in-async-method `
                -Path $Path -Line $syncIo.line `
                -EndLine $syncIo.line `
                -Evidence (
                    'Use the supported asynchronous I/O API.')
    }

    $blockingWait = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '\bThread\s*\.\s*Sleep\s*\(' -or
        $text -match '\.\s*WaitOne\s*\('
    }
    if ($null -ne $blockingWait -and
        $joined -match '\basync\b') {
        $results['async-wait-sync'] =
            New-ContextualOutcome `
                -RuleId async-wait-sync `
                -State violation `
                -Reason blocking-wait-in-async-context `
                -Path $Path -Line $blockingWait.line `
                -EndLine $blockingWait.line `
                -Evidence (
                    'Use Task.Delay with cancellation or an ' +
                    'async-compatible synchronization primitive.')
    }

    $httpLine = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match '\bnew\s+HttpClient\s*\('
    }
    if ($null -ne $httpLine) {
        $systemHttpClient =
            $joined -match
                '\busing\s+System\s*\.\s*Net\s*\.\s*Http\s*;' -or
            $joined -match
                '\bnew\s+System\s*\.\s*Net\s*\.\s*Http\s*\.\s*HttpClient\s*\('
        $shared = $joined -match
            '\bstatic\s+readonly\s+HttpClient\b' -or
            $joined -match '\bIHttpClientFactory\b'
        $results['http-client-lifetime'] = if (
            -not $systemHttpClient) {
            New-ContextualOutcome `
                -RuleId http-client-lifetime `
                -State unknown `
                -Reason http-client-type-unproven `
                -Path $Path -Line $httpLine.line `
                -EndLine $httpLine.line
        }
        else {
            New-ContextualOutcome `
                -RuleId http-client-lifetime `
                -State $(if ($shared) {
                    'compliant'
                } else { 'violation' }) `
                -Reason $(if ($shared) {
                    'shared-or-factory-managed-client'
                } else {
                    'request-path-http-client-construction'
                }) `
                -Path $Path -Line $httpLine.line `
                -EndLine $httpLine.line `
                -Evidence $(if ($shared) { '' } else {
                    'Reuse a shared HttpClient or obtain one ' +
                    'from IHttpClientFactory.'
                })
        }
    }

    $lazyLine = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '\bif\s*\([^)]*\b\w+\s*=\s*=\s*null' -or
        $text -match '\?\?='
    }
    if ($null -ne $lazyLine -and
        $joined -match '\bstatic\b' -and
        $joined -notmatch
            '\b(?:Lazy|Interlocked|lock)\b') {
        $results['thread-safe-immutable'] =
            New-ContextualOutcome `
                -RuleId thread-safe-immutable `
                -State violation `
                -Reason unsynchronized-shared-initialization `
                -Path $Path -Line $lazyLine.line `
                -EndLine $lazyLine.line `
                -Evidence (
                    'Use Lazy<T>, Interlocked, or a proven ' +
                    'synchronization boundary for shared state.')
    }

    $reflectionMatches = @(
        foreach ($key in @($lines.Keys |
                Sort-Object { [int]$_ })) {
            $line = [int]$key
            $text = Get-ContextualLineText `
                -Lines $lines -Line $line
            if ($text -match
                '\.\s*Get(?:Method|Methods|Property|Properties|CustomAttributes)\s*\(') {
                [ordered]@{
                    line = $line
                    text = $text
                }
            }
        })
    $reflectionLine = @($reflectionMatches |
        Where-Object {
            Test-ContextualChangedLine `
                -Line $_.line -Spans $Spans
        } | Select-Object -First 1)
    $reflectionRepeated =
        ([regex]::Matches(
                $joined,
                '\.\s*Get(?:Method|Methods|Property|Properties|CustomAttributes)\s*\(')).Count -gt 1 -or
        $joined -match
            '\b(?:for|foreach|while)\s*\([^)]*\).*Get(?:Method|Methods|Property|Properties|CustomAttributes)'
    if ($reflectionLine.Count -gt 0 -and
        $reflectionRepeated) {
        $cached = $joined -match
            '\bstatic\s+readonly\b.*\.\s*Get'
        $results['cache-streaming'] =
            New-ContextualOutcome `
                -RuleId cache-streaming `
                -State $(if ($cached) {
                    'compliant'
                } else { 'violation' }) `
                -Reason $(if ($cached) {
                    'expensive-work-cached'
                } else {
                    'repeated-reflection-not-cached'
                }) `
                -Path $Path -Line $reflectionLine[0].line `
                -EndLine $reflectionLine[0].line `
                -Evidence $(if ($cached) { '' } else {
                    'Cache repeated reflection or metadata ' +
                    'lookup results.'
                })
    }
    $bufferLine = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '\.\s*(?:ReadAsByteArrayAsync|ReadAsStringAsync|ReadToEndAsync)\s*\('
    }
    if ($null -ne $bufferLine -and
        $joined -match
            '(?i)(?:ContentLength|Length)\s*(?:>|>=)\s*(?:1048576|1_048_576|[2-9][0-9]{6,})') {
        $results['cache-streaming'] =
            New-ContextualOutcome `
                -RuleId cache-streaming `
                -State violation `
                -Reason proven-large-payload-fully-buffered `
                -Path $Path -Line $bufferLine.line `
                -EndLine $bufferLine.line `
                -Evidence (
                    'Stream the payload instead of fully buffering ' +
                    'a response proven to exceed the large-payload bound.')
    }

    $jObjectVariables =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
    for ($index = 0;
        $index -lt $tokens.Count - 1; $index++) {
        if ([string]$tokens[$index].text -ceq
                'JObject' -and
            [string]$tokens[$index + 1].text -cmatch
                '^@?[\p{L}_][\p{L}\p{N}_]*$') {
            [void]$jObjectVariables.Add(
                ([string]$tokens[$index + 1].text).
                    TrimStart('@'))
        }
    }
    foreach ($name in $jObjectVariables) {
        $count = ([regex]::Matches(
                $joined,
                "\b$([regex]::Escape($name))\s*\[\s*__literal__\s*\]")).Count
        if ($count -ge 2 -and
            $joined -notmatch '(?i)dynamic|extension') {
            $line = @($tokens | Where-Object {
                    [string]$_.text -ceq $name -and
                    (Test-ContextualChangedLine `
                        -Line ([int]$_.line) `
                        -Spans $Spans)
                } | Select-Object -First 1)
            $results['typed-contracts'] =
                New-ContextualOutcome `
                    -RuleId typed-contracts `
                    -State violation `
                    -Reason fixed-contract-accessed-by-json-keys `
                    -Path $Path `
                    -Line $(if ($line.Count) {
                        [int]$line[0].line
                    } else { 0 }) `
                    -Evidence (
                        'Declare and deserialize a typed ' +
                        'contract instead of repeatedly indexing known JSON fields.')
            break
        }
    }
    if ($joined -match
        '\[\s*JsonObject\s*\]|\[\s*JsonProperty') {
        $typeOptIn = $joined -match
            '\[\s*JsonObject\s*\(\s*MemberSerialization\s*\.\s*OptIn\s*\)\s*\]'
        $propertyLine = Find-ContextualChangedLine `
            -Lines $lines -Spans $Spans -Predicate {
            param($text)
            $text -match
                '\bpublic\s+[\w<>\[\]\?]+\s+\w+\s*\{\s*get\s*;'
        }
        if ($null -ne $propertyLine -and
            -not $typeOptIn -and
            $propertyLine.text -notmatch
                'JsonProperty|JsonIgnore|JsonInclude|JsonPropertyName|DataMember|IgnoreDataMember') {
            $results['json-contracts'] =
                New-ContextualOutcome `
                    -RuleId json-contracts `
                    -State violation `
                    -Reason json-property-not-declared `
                    -Path $Path -Line $propertyLine.line `
                    -EndLine $propertyLine.line `
                    -Evidence (
                        'Declare the serialized wire property ' +
                        'explicitly or ignore it deliberately.')
        }
    }

    $apiError = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '\bnew\s+(?:Exception|InvalidOperationException)\s*\('
    }
    if ($null -ne $apiError -and
        ($joined -match
            'Controller|ApiEngine|\[\s*Http') -and
        $joined -notmatch
            'ErrorResponseMessage|GenerateResponseMessageFromException') {
        $results['api-errors'] =
            New-ContextualOutcome `
                -RuleId api-errors -State violation `
                -Reason nonstandard-api-error-path `
                -Path $Path -Line $apiError.line `
                -EndLine $apiError.line `
                -Evidence (
                    'Use the repository actionable API error contract.')
    }

    $secretLine = Find-ContextualChangedLine `
        -Lines $lines -Spans $Spans -Predicate {
        param($text)
        $text -match
            '(?i)\b(?:response|result)\s*\.\s*(?:password|secret|token|authorization|connectionString|apiKey)\s*='
    }
    if ($null -ne $secretLine) {
        $redacted = $secretLine.text -match
            '(?i)Redact|Mask|Sanitize'
        $rhsSensitive = $secretLine.text -match
            '(?i)=.*\b(?:password|secret|token|authorization|connectionString|apiKey)\b'
        $coldCache = $joined -match
            '(?i)\b(?:cache|cached|metadata)\b.*(?:=\s*=\s*null|is\s+null|miss)'
        if ($redacted) {
            $results['secret-redaction'] =
                New-ContextualOutcome `
                    -RuleId secret-redaction `
                    -State compliant `
                    -Reason response-value-redacted `
                    -Path $Path -Line $secretLine.line `
                    -EndLine $secretLine.line
        }
        elseif ($rhsSensitive -and $coldCache) {
            $results['secret-redaction'] =
                New-ContextualOutcome `
                    -RuleId secret-redaction `
                    -State violation `
                    -Reason cold-cache-sensitive-value-reaches-response `
                    -Path $Path -Line $secretLine.line `
                    -EndLine $secretLine.line `
                    -Evidence (
                        'Redact the sensitive field on the ' +
                        'proven cache-miss response path.')
        }
        else {
            $results['secret-redaction'] =
                New-ContextualOutcome `
                    -RuleId secret-redaction `
                    -State unknown `
                    -Reason sensitive-flow-or-cache-path-unproven `
                    -Path $Path -Line $secretLine.line `
                    -EndLine $secretLine.line
        }
    }

    if ($model.malformed) {
        foreach ($rule in $script:RuleIds) {
            if ([string]$results[$rule].state -cne
                'unknown') {
                $results[$rule].state = 'unknown'
                $results[$rule].reason =
                    'csharp-syntax-incomplete'
                $results[$rule].evidence = ''
            }
        }
    }
    return @($script:RuleIds | ForEach-Object {
            $results[$_]
        })
}

function Get-ContextualDependencyOutcome {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    if ($Path -notmatch
        '(?i)(?:\.csproj|\.props|packages\.config)$') {
        return New-ContextualOutcome `
            -RuleId dependency-fanout `
            -State compliant `
            -Reason no-applicable-violation `
            -Path $Path
    }
    $matches = [regex]::Matches(
        $Content,
        '(?i)(?:PackageReference\s+Include|package\s+id)\s*=\s*["''](?<id>[^"'']+)["'']')
    if ($matches.Count -eq 0) {
        return New-ContextualOutcome `
            -RuleId dependency-fanout `
            -State compliant `
            -Reason no-applicable-violation `
            -Path $Path
    }
    $packageId = $matches[0].Groups['id'].Value
    $projectDirectory = [IO.Path]::GetDirectoryName(
        $Path.Replace('/', '\'))
    $activePackageReference = $Path.EndsWith(
            '.csproj',
            [StringComparison]::OrdinalIgnoreCase) -and
        $Content -match
            '(?is)<RestoreProjectStyle>\s*PackageReference\s*</RestoreProjectStyle>'
    $companion = @($SnapshotFiles | Where-Object {
            [string]$_.path -cne $Path -and
            [IO.Path]::GetDirectoryName(
                ([string]$_.path).Replace('/', '\')) -ceq
                $projectDirectory -and
            (-not $activePackageReference -or
                -not ([string]$_.path).EndsWith(
                    'packages.config',
                    [StringComparison]::OrdinalIgnoreCase)) -and
            [string]$_.content -match
                [regex]::Escape($packageId)
        })
    if ($companion.Count -eq 0) {
        return New-ContextualOutcome `
            -RuleId dependency-fanout `
            -State unknown `
            -Reason affected-dependency-graph-not-present `
            -Path $Path -Line 1 -EndLine 1 `
            -Symbol $packageId
    }
    $versions = @(
        @([ordered]@{
                content = $Content
                path = $Path
            }) + @($companion) |
            ForEach-Object {
                [regex]::Matches(
                    [string]$_.content,
                    ('(?i)' +
                        [regex]::Escape($packageId) +
                        '[^\r\n>]{0,256}(?:Version\s*=\s*["'']|version\s*=\s*["''])(?<version>[^"'']+)')) |
                    ForEach-Object {
                        $_.Groups['version'].Value
                    }
            } | Sort-Object -Unique)
    if ($versions.Count -gt 1) {
        return New-ContextualOutcome `
            -RuleId dependency-fanout `
            -State violation `
            -Reason dependency-version-mismatch `
            -Path $Path -Line 1 -EndLine 1 `
            -Symbol $packageId `
            -Evidence (
                'The same changed dependency has inconsistent ' +
                'versions across proven affected surfaces.')
    }
    return New-ContextualOutcome `
        -RuleId dependency-fanout `
        -State compliant `
        -Reason changed-dependency-surfaces-consistent `
        -Path $Path -Line 1 -EndLine 1 `
        -Symbol $packageId
}

function Get-ContextualNodeLine {
    param([Parameter(Mandatory)]$Node)
    return [int](
        $Node.GetLocation().
            GetLineSpan().StartLinePosition.Line + 1)
}

function Test-ContextualNodeChanged {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][object[]]$Spans
    )
    $lineSpan = $Node.GetLocation().GetLineSpan()
    $first = [int]$lineSpan.StartLinePosition.Line + 1
    $last = [int]$lineSpan.EndLinePosition.Line + 1
    return @($Spans | Where-Object {
            $first -le [int]$_.endLine -and
            $last -ge [int]$_.startLine
        }).Count -gt 0
}

function Get-ContextualAncestor {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][type]$Type
    )
    return @($Node.AncestorsAndSelf() |
        Where-Object { $_ -is $Type } |
        Select-Object -First 1)
}

function Get-ContextualMethodTypeMap {
    param([AllowNull()]$Method)
    $types = @{}
    if ($null -eq $Method) {
        return $types
    }
    foreach ($parameter in @(
            $Method.ParameterList.Parameters)) {
        if ($null -ne $parameter.Type) {
            $types[[string]$parameter.Identifier.ValueText] =
                [string]$parameter.Type.ToString()
        }
    }
    foreach ($declaration in @(
            $Method.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.VariableDeclarationSyntax]
                })) {
        foreach ($variable in @(
                $declaration.Variables)) {
            $types[[string]$variable.Identifier.ValueText] =
                [string]$declaration.Type.ToString()
        }
    }
    return $types
}

function Get-ContextualReceiverType {
    param(
        [Parameter(Mandatory)]$Expression,
        [AllowNull()]$Method
    )
    if ($Expression -is [
        Microsoft.CodeAnalysis.CSharp.Syntax.TypeOfExpressionSyntax]) {
        return 'System.Type'
    }
    if ($Expression -is [
        Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax]) {
        $types = Get-ContextualMethodTypeMap `
            -Method $Method
        $name = [string]$Expression.Identifier.ValueText
        if ($types.Contains($name)) {
            return [string]$types[$name]
        }
    }
    return [string]$Expression.ToString()
}

function Get-ContextualCoverageAttributeState {
    param(
        [Parameter(Mandatory)]$Type,
        [Parameter(Mandatory)]$Root
    )
    $namespace = 'System.Diagnostics.CodeAnalysis'
    $full = "$namespace.ExcludeFromCodeCoverage"
    $usingNodes = @($Root.Usings)
    foreach ($ancestor in @($Type.Ancestors())) {
        if ($ancestor -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.BaseNamespaceDeclarationSyntax]) {
            $usingNodes += @($ancestor.Usings)
        }
    }
    $imports = @($usingNodes | Where-Object {
            $null -eq $_.Alias
        } | ForEach-Object {
            ([string]$_.Name.ToString()) -replace '^global::', ''
        })
    $aliases = @{}
    foreach ($using in @($usingNodes | Where-Object {
                $null -ne $_.Alias
            })) {
        $aliases[[string]$using.Alias.Name.Identifier.ValueText] =
            ((([string]$using.Name.ToString()) -replace '^global::', '') `
                -replace 'Attribute$', '')
    }
    foreach ($list in @($Type.AttributeLists)) {
        if ($null -ne $list.Target) {
            continue
        }
        foreach ($attribute in @($list.Attributes)) {
            $name = ([string]$attribute.Name.ToString()) `
                -replace '^global::', '' `
                -replace 'Attribute$', ''
            if ($name -ceq $full) {
                return 'present'
            }
            $localShadow = @($Root.DescendantNodes() |
                Where-Object {
                    ($_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.ClassDeclarationSyntax] -or
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.StructDeclarationSyntax]) -and
                    [string]$_.Identifier.ValueText -cin @(
                        'ExcludeFromCodeCoverage',
                        'ExcludeFromCodeCoverageAttribute')
                }).Count -gt 0
            if ($name -ceq 'ExcludeFromCodeCoverage' -and
                -not $localShadow -and
                $namespace -cin $imports -and
                -not $aliases.ContainsKey(
                    'ExcludeFromCodeCoverage')) {
                return 'present'
            }
            $parts = $name -split '\.|::', 2
            if ($aliases.ContainsKey($parts[0])) {
                $resolved = [string]$aliases[$parts[0]]
                if ($parts.Count -gt 1) {
                    $resolved += '.' + $parts[1]
                }
                if ($resolved -ceq $full) {
                    return 'present'
                }
            }
        }
    }
    return 'missing'
}

function Get-ContextualTestProject {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    $candidates = @($SnapshotFiles | Where-Object {
            [string]$_.state -ceq 'complete' -and
            [string]$_.path -imatch '\.csproj$' -and
            $Path.StartsWith(
                ([IO.Path]::GetDirectoryName(
                    ([string]$_.path).Replace(
                        '/', [IO.Path]::DirectorySeparatorChar)).
                    Replace(
                        [IO.Path]::DirectorySeparatorChar, '/') + '/'),
                [StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object {
            -([string]$_.path).Length
        })
    if ($candidates.Count -lt 1) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'test-project-evidence-missing'
        }
    }
    $directoryLength = [IO.Path]::GetDirectoryName(
        ([string]$candidates[0].path).Replace(
            '/', [IO.Path]::DirectorySeparatorChar)).Length
    $nearest = @($candidates | Where-Object {
            [IO.Path]::GetDirectoryName(
                ([string]$_.path).Replace(
                    '/', [IO.Path]::DirectorySeparatorChar)).Length -eq
                $directoryLength
        })
    if ($nearest.Count -ne 1) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'test-project-evidence-ambiguous'
        }
    }
    $content = [string]$nearest[0].content
    try {
        [xml]$xml = $content
    }
    catch {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'test-project-xml-invalid'
        }
    }
    $testNodes = @($xml.SelectNodes(
            '//*[local-name()="IsTestProject"]') |
        Where-Object {
            [string]$_.InnerText -match '^\s*true\s*$'
        })
    $sdkNodes = @($xml.SelectNodes(
            '//*[local-name()="PackageReference"]') |
        Where-Object {
            [string]$_.GetAttribute('Include') -ceq
                'Microsoft.NET.Test.Sdk'
        })
    if (@($testNodes + $sdkNodes | Where-Object {
                -not [string]::IsNullOrWhiteSpace(
                    [string]$_.GetAttribute('Condition'))
            }).Count -gt 0) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'test-project-condition-unproven'
        }
    }
    $isTest = $testNodes.Count -gt 0 -or
        $sdkNodes.Count -gt 0
    if (-not $isTest) {
        return [pscustomobject]@{
            State = 'not-test'
            Path = [string]$nearest[0].path
        }
    }
    $compileSetting = @($xml.SelectNodes(
            '//*[local-name()="EnableDefaultCompileItems"]') |
        Where-Object {
            [string]$_.InnerText -match '^\s*false\s*$'
        })
    if ($compileSetting.Count -gt 0) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'test-project-compile-membership-unproven'
        }
    }
    $projectDirectory = [IO.Path]::GetDirectoryName(
        ([string]$nearest[0].path).Replace(
            '/', [IO.Path]::DirectorySeparatorChar))
    $relative = [IO.Path]::GetRelativePath(
        $projectDirectory,
        $Path.Replace(
            '/', [IO.Path]::DirectorySeparatorChar)).
        Replace([IO.Path]::DirectorySeparatorChar, '\')
    foreach ($node in @($xml.SelectNodes(
            '//*[local-name()="Compile" and @Remove]'))) {
        $pattern = [WildcardPattern]::new(
            ([string]$node.GetAttribute('Remove')).Replace('/', '\'),
            [WildcardOptions]::IgnoreCase)
        if ($pattern.IsMatch($relative)) {
            return [pscustomobject]@{
                State = 'excluded'
                Path = [string]$nearest[0].path
            }
        }
    }
    return [pscustomobject]@{
        State = 'test'
        Path = [string]$nearest[0].path
    }
}

function Get-ContextualCoverageOutcomes {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Spans,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    $project = Get-ContextualTestProject `
        -Path $Path -SnapshotFiles $SnapshotFiles
    if ([string]$project.State -ceq 'unknown') {
        return , (New-ContextualOutcome `
            -RuleId test-class-code-coverage `
            -State unknown -Reason $project.Reason `
            -Path $Path)
    }
    if ([string]$project.State -cne 'test') {
        return , (New-ContextualOutcome `
            -RuleId test-class-code-coverage `
            -State compliant -Reason not-a-compiled-test-project-class `
            -Path $Path)
    }
    $types = @($Root.DescendantNodes() | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.ClassDeclarationSyntax] -or
            ($_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.RecordDeclarationSyntax] -and
                [string]$_.ClassOrStructKeyword.Text -cne 'struct')
        })
    $outcomes = [Collections.Generic.List[object]]::new()
    foreach ($type in $types) {
        $keywordLine = [int](
            $type.Keyword.GetLocation().
                GetLineSpan().StartLinePosition.Line + 1)
        $identifierLine = [int](
            $type.Identifier.GetLocation().
                GetLineSpan().StartLinePosition.Line + 1)
        $attributeLines = @($type.AttributeLists | ForEach-Object {
                Get-ContextualNodeLine $_
            })
        $headerLines = @($keywordLine..$identifierLine)
        $changedLines = @($attributeLines + $headerLines |
            Where-Object {
                Test-ContextualChangedLine `
                    -Line $_ -Spans $Spans
            } | Sort-Object -Unique)
        if ($changedLines.Count -lt 1) {
            continue
        }
        $attributeState =
            Get-ContextualCoverageAttributeState `
                -Type $type -Root $Root
        if ($attributeState -ceq 'present') {
            continue
        }
        if (@($type.Modifiers | Where-Object {
                    [string]$_.Text -ceq 'partial'
                }).Count -gt 0) {
            [void]$outcomes.Add(
                (New-ContextualOutcome `
                    -RuleId test-class-code-coverage `
                    -State unknown `
                    -Reason partial-class-coverage-attribute-unproven `
                    -Path $Path -Line $changedLines[0] `
                    -EndLine $changedLines[0] `
                    -Symbol ([string]$type.Identifier.ValueText)))
            continue
        }
        [void]$outcomes.Add(
            (New-ContextualOutcome `
                -RuleId test-class-code-coverage `
                -State violation `
                -Reason test-class-coverage-exclusion-missing `
                -Path $Path -Line $changedLines[0] `
                -EndLine $changedLines[0] `
                -Symbol ([string]$type.Identifier.ValueText) `
                -Evidence (
                    'Add System.Diagnostics.CodeAnalysis.' +
                    'ExcludeFromCodeCoverage to this test-project class.')))
    }
    if ($outcomes.Count -gt 0) {
        $definite = @($outcomes | Where-Object {
                [string]$_.state -ceq 'violation'
            })
        if ($definite.Count -gt 0) {
            return $definite
        }
        return $outcomes.ToArray()
    }
    return , (New-ContextualOutcome `
        -RuleId test-class-code-coverage `
        -State compliant -Reason no-changed-class-without-coverage-exclusion `
        -Path $Path)
}

function Get-ContextualRoslynOutcomes {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Spans,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    $tree = [
        Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::
        ParseText($Content)
    $root = $tree.GetRoot()
    $parseErrors = @($tree.GetDiagnostics() |
        Where-Object {
            $_.Severity -eq [
                Microsoft.CodeAnalysis.DiagnosticSeverity]::Error
        })
    $contextualCandidateOutcomes =
        [Collections.Generic.List[object]]::new()
    $results = [ordered]@{}
    foreach ($rule in $script:RuleIds) {
        $results[$rule] = New-ContextualOutcome `
            -RuleId $rule -State compliant `
            -Reason no-applicable-violation `
            -Path $Path
    }
    $coverageOutcomes = @(
        Get-ContextualCoverageOutcomes `
            -Root $root -Path $Path -Spans $Spans `
            -SnapshotFiles $SnapshotFiles)
    $nodes = @($root.DescendantNodes())
    $methods = @($nodes | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax]
        })
    $catches = @($nodes | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.CatchClauseSyntax]
        })

    foreach ($catch in $catches) {
        if (-not (Test-ContextualNodeChanged `
                -Node $catch -Spans $Spans)) {
            continue
        }
        $variable = [string]$catch.Declaration.
            Identifier.ValueText
        $logs = @($catch.Block.DescendantNodes() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -and
                [string]$_.Expression.ToString() -match
                    '(?:Logger\.(?:Error|Critical)|\.LogError)$'
            })
        $throws = @($catch.Block.DescendantNodes() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.ThrowStatementSyntax]
            })
        foreach ($log in $logs) {
            $arguments = @($log.ArgumentList.Arguments)
            $includesException = @($arguments |
                Where-Object {
                    [string]$_.Expression.ToString() -ceq
                        $variable
                }).Count -gt 0
            $messageOnly = @($arguments |
                Where-Object {
                    [string]$_.Expression.ToString() -ceq
                        "$variable.Message"
                }).Count -gt 0
            if (($messageOnly -and
                    -not $includesException) -or
                $throws.Count -gt 0) {
                $results['exception-logging'] =
                    New-ContextualOutcome `
                        -RuleId exception-logging `
                        -State violation `
                        -Reason $(if ($throws.Count) {
                            'log-and-rethrow'
                        }
                        else {
                            'exception-object-not-logged'
                        }) `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $log) `
                        -EndLine (Get-ContextualNodeLine $log) `
                        -Symbol (
                            [string]$catch.Declaration.Type) `
                        -Evidence (
                            'Log the exception exactly once and ' +
                            'pass the caught exception object.')
                break
            }
        }
        foreach ($throw in $throws) {
            if ($null -ne $throw.Expression -and
                [string]$throw.Expression.ToString() -ceq
                    $variable) {
                $results['exception-propagation'] =
                    New-ContextualOutcome `
                        -RuleId exception-propagation `
                        -State violation `
                        -Reason throw-expression-resets-stack `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $throw) `
                        -EndLine (Get-ContextualNodeLine $throw) `
                        -Symbol $variable `
                        -Evidence (
                            'Use a bare throw to preserve the stack.')
            }
        }
        $generic = [string]$catch.Declaration.Type -in @(
            'Exception', 'System.Exception')
        $filterText = if ($null -ne $catch.Filter) {
            [string]$catch.Filter.FilterExpression.ToString()
        }
        else { '' }
        $hasFilter = -not [string]::IsNullOrWhiteSpace($filterText)
        $fatalFiltered = $hasFilter -and
            $filterText -match '!\s*\w+\.IsFatal\s*\('
        $onlyThrow = $catch.Block.Statements.Count -eq 1 -and
            $catch.Block.Statements[0] -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.ThrowStatementSyntax] -and
            $null -eq $catch.Block.Statements[0].Expression
        if ($generic -and $hasFilter -and -not $fatalFiltered -and
            -not $onlyThrow) {
            $results['exception-propagation'] =
                New-ContextualOutcome `
                    -RuleId exception-propagation `
                    -State unknown `
                    -Reason typed-filter-fatal-semantics-unproven `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $catch) `
                    -EndLine (Get-ContextualNodeLine $catch) `
                    -Symbol $variable
        }
        elseif ($generic -and -not $hasFilter -and
            -not $onlyThrow) {
            $results['exception-propagation'] =
                New-ContextualOutcome `
                    -RuleId exception-propagation `
                    -State violation `
                    -Reason fatal-exception-filter-missing `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $catch) `
                    -EndLine (Get-ContextualNodeLine $catch) `
                    -Symbol $variable `
                    -Evidence (
                        'Let fatal exceptions escape through ' +
                        'the repository IsFatal catch filter.')
        }
        foreach ($decision in @(
                $catch.Block.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.IfStatementSyntax] -or
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.SwitchStatementSyntax]
                    })) {
            $condition = if ($decision -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.IfStatementSyntax]) {
                $decision.Condition
            }
            else {
                $decision.Expression
            }
            if ([string]$condition.ToString() -match
                "\b$([regex]::Escape($variable))\.(?:Message|StackTrace)\b") {
                $results['type-based-decisions'] =
                    New-ContextualOutcome `
                        -RuleId type-based-decisions `
                        -State violation `
                        -Reason exception-text-controls-behavior `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $condition) `
                        -EndLine (Get-ContextualNodeLine $condition) `
                        -Symbol $variable `
                        -Evidence (
                            'Use exception types or typed status ' +
                            'codes for behavior decisions.')
                break
            }
        }
    }

    foreach ($method in $methods) {
        $typeMap =
            Get-ContextualMethodTypeMap -Method $method
        $methodChanged = Test-ContextualNodeChanged `
            -Node $method -Spans $Spans
        if (-not $methodChanged) {
            continue
        }
        foreach ($binary in @(
                $method.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.BinaryExpressionSyntax] -and
                        [string]$_.OperatorToken.Text -in @(
                            '==', '!=')
                    })) {
            $left = [string]$binary.Left.ToString()
            $right = [string]$binary.Right.ToString()
            if ($left -ceq 'null' -or $right -ceq 'null') {
                continue
            }
            $leftString = $typeMap.Contains($left) -and
                [string]$typeMap[$left] -ceq 'string'
            $rightString = $typeMap.Contains($right) -and
                [string]$typeMap[$right] -ceq 'string'
            if ($leftString -or $rightString) {
                $results['explicit-string-comparison'] =
                    New-ContextualOutcome `
                        -RuleId explicit-string-comparison `
                        -State violation `
                        -Reason string-comparison-not-explicit `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $binary) `
                        -EndLine (Get-ContextualNodeLine $binary) `
                        -Symbol (
                            [string]$method.Identifier.ValueText) `
                        -Evidence (
                            'Use explicit StringComparison semantics.')
                break
            }
        }
        $exceptionParameters = @(
            $method.ParameterList.Parameters |
                Where-Object {
                    [string]$_.Type.ToString() -match
                        '(?:^|\.)Exception$'
                } |
                ForEach-Object {
                    [string]$_.Identifier.ValueText
                })
        foreach ($parameter in $exceptionParameters) {
            $textDecisions = @(
                $method.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.IfStatementSyntax] -and
                        [string]$_.Condition.ToString() -match
                            "\b$([regex]::Escape($parameter))\.(?:Message|StackTrace)\b"
                    })
            if ($textDecisions.Count -gt 0) {
                $results['type-based-decisions'] =
                    New-ContextualOutcome `
                        -RuleId type-based-decisions `
                        -State violation `
                        -Reason exception-text-controls-behavior `
                        -Path $Path `
                        -Line (
                            Get-ContextualNodeLine `
                                $textDecisions[0]) `
                        -EndLine (
                            Get-ContextualNodeLine `
                                $textDecisions[0]) `
                        -Symbol $parameter `
                        -Evidence (
                            'Use exception types or typed status ' +
                            'codes for behavior decisions.')
            }
        }
        foreach ($first in @(
                $method.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -and
                        [string]$_.Expression.ToString() -match
                            '\.First(?:OrDefault)?$'
                    })) {
            $predicateSelection = $first.ArgumentList.Arguments.Count -gt 0

            $receiver = if ($first.Expression -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) {
                [string]$first.Expression.Expression.ToString()
            }
            else {
                ''
            }
            if ([string]::IsNullOrWhiteSpace(
                    $receiver)) {
                continue
            }
            $offset = [Math]::Max(
                0,
                $first.SpanStart -
                $method.SpanStart)
            $priorText = [string]$method.ToString().
                Substring(
                    0,
                    [Math]::Min(
                        $method.ToString().Length,
                        $offset))
            $normalizedReceiver = $receiver.Replace('?.', '.')
            $normalizedMethodText = ([string]$method.ToString()).Replace('?.', '.')
            $predicateUniquenessProof = $predicateSelection -and
                $normalizedMethodText -match (
                    [regex]::Escape($normalizedReceiver) +
                    '(?:\.Values)?\.Single(?:OrDefault)?(?:<[^>]+>)?\s*\(')
            if ($predicateSelection -and -not $predicateUniquenessProof) {
                if (Test-ContextualNodeChanged -Node $first -Spans $Spans) {
                    $results['collection-cardinality'] =
                        New-ContextualOutcome `
                            -RuleId collection-cardinality `
                            -State unknown `
                            -Reason predicate-selection-cardinality-unproven `
                            -Path $Path `
                            -Line (Get-ContextualNodeLine $first) `
                            -EndLine (Get-ContextualNodeLine $first) `
                            -Symbol ([string]$method.Identifier.ValueText)
                }
                continue
            }
            $orderedSelection = $receiver -match
                '\.(?:OrderBy|OrderByDescending|ThenBy|ThenByDescending)\s*\(' -or
                $receiver -match '\.Split\s*\('
            if (-not $orderedSelection -and $receiver -match '^[A-Za-z_][A-Za-z0-9_]*$') {
                $orderedSelection = @(
                    $method.DescendantNodes() |
                        Where-Object {
                            $_ -is [
                                Microsoft.CodeAnalysis.CSharp.Syntax.VariableDeclaratorSyntax] -and
                            [string]$_.Identifier.ValueText -ceq $receiver -and
                            $_.SpanStart -lt $first.SpanStart -and
                            $null -ne $_.Initializer -and
                            [string]$_.Initializer.Value.ToString() -match
                                '\.(?:OrderBy|OrderByDescending|ThenBy|ThenByDescending)\s*\('
                        }).Count -gt 0
            }
            $validated = $priorText -match (
                "\b$([regex]::Escape($receiver))\." +
                '(?:Count\s*(?:\(\s*\))?\s*(?:==|!=)\s*1|' +
                'Single\s*\()')
            $positionalContractUnproven =
                $receiver -match '(?i)(?:Headers\.GetValues|HeaderValues|\.GetValues\s*\()' -or
                $receiver -match '\.OfType\s*<' -or
                $receiver -match '(?:^|\.)Triggers$' -or
                $priorText -match (
                    [regex]::Escape($receiver) + '\.Any\s*\(')
            if (-not $validated -and -not $orderedSelection -and
                $positionalContractUnproven) {
                if (Test-ContextualNodeChanged -Node $first -Spans $Spans) {
                    $results['collection-cardinality'] =
                        New-ContextualOutcome `
                            -RuleId collection-cardinality `
                            -State unknown `
                            -Reason positional-selection-cardinality-unproven `
                            -Path $Path `
                            -Line (Get-ContextualNodeLine $first) `
                            -EndLine (Get-ContextualNodeLine $first) `
                            -Symbol ([string]$method.Identifier.ValueText)
                }
                continue
            }
            if (-not $validated -and -not $orderedSelection) {
                $results['collection-cardinality'] =
                    New-ContextualOutcome `
                        -RuleId collection-cardinality `
                        -State violation `
                        -Reason arbitrary-first-selection `
                        -Path $Path `
                        -Line (
                            Get-ContextualNodeLine $first) `
                        -EndLine (
                            Get-ContextualNodeLine $first) `
                        -Symbol (
                            [string]$method.Identifier.ValueText) `
                        -Evidence (
                            'Validate cardinality before selecting an item.')
            }
        }
        foreach ($member in @(
                $method.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -and
                        [string]$_.Name.Identifier.ValueText -ceq
                            'Result'
                    })) {
            $receiverType = Get-ContextualReceiverType `
                -Expression $member.Expression `
                -Method $method
            if ($receiverType -match
                    '^(?:System\.)?Threading\.Tasks\.Task' -or
                [string]$member.Expression.ToString() -match
                    'Async\s*\(\s*\)$') {
                $results['async-all-the-way'] =
                    New-ContextualOutcome `
                        -RuleId async-all-the-way `
                        -State violation `
                        -Reason task-result-blocking `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $member) `
                        -EndLine (Get-ContextualNodeLine $member) `
                        -Symbol (
                            [string]$method.Identifier.ValueText) `
                        -Evidence (
                            'Await the Task instead of blocking on Result.')
            }
        }
        $invocations = @(
            $method.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax]
                })
        foreach ($invocation in $invocations) {
            $expression =
                [string]$invocation.Expression.ToString()
            if ($expression -match
                '^(?:(?:System\.)?IO\.)?File\.(?:ReadAllText|ReadAllBytes|WriteAllText|WriteAllBytes)$') {
                $results['async-io'] =
                    New-ContextualOutcome `
                        -RuleId async-io -State violation `
                        -Reason synchronous-io-in-async-method `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $invocation) `
                        -EndLine (Get-ContextualNodeLine $invocation) `
                        -Symbol (
                            [string]$method.Identifier.ValueText) `
                        -Evidence 'Use the supported asynchronous I/O API.'
            }
            if ($expression -match
                '^(?:System\.Threading\.)?Thread\.Sleep$' -or
                $expression -match '\.WaitOne$') {
                if ($method.Modifiers.ToString() -match '\basync\b') {
                    $results['async-wait-sync'] =
                        New-ContextualOutcome `
                            -RuleId async-wait-sync `
                            -State violation `
                            -Reason blocking-wait-in-async-context `
                            -Path $Path `
                            -Line (Get-ContextualNodeLine $invocation) `
                            -EndLine (Get-ContextualNodeLine $invocation) `
                            -Symbol (
                                [string]$method.Identifier.ValueText) `
                            -Evidence (
                                'Use an async-compatible wait with cancellation.')
                }
            }
        }
        foreach ($lambda in @(
                $method.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.AnonymousFunctionExpressionSyntax]
                    })) {
            $validationCallback = $false
            $argument = @($lambda.AncestorsAndSelf() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.ArgumentSyntax]
                } | Select-Object -First 1)
            if ($argument.Count -eq 1) {
                $argumentName = if ($null -ne $argument[0].NameColon) {
                    [string]$argument[0].NameColon.Name.Identifier.ValueText
                }
                else { '' }
                $invocation = @($argument[0].Ancestors() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax]
                    } | Select-Object -First 1)
                $invocationName = if ($invocation.Count -eq 1) {
                    [string]$invocation[0].Expression.ToString()
                }
                else { '' }
                $validationCallback = $argumentName -match
                    '(?i)^(?:validator|validation(?:Delegate|Callback)?)$' -or
                    $invocationName -match
                    '(?i)(?:^|\.)(?:Validate|ValidateAsync|RegisterValidation|SetValidator)$'
            }
            if (-not $validationCallback) {
                $declarator = @($lambda.AncestorsAndSelf() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.VariableDeclaratorSyntax]
                    } | Select-Object -First 1)
                $validationCallback = $declarator.Count -eq 1 -and
                    [string]$declarator[0].Identifier.ValueText -match
                        '(?i)validat'
            }
            if (-not $validationCallback) {
                continue
            }
            $lambdaInvocations = @(
                $lambda.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax]
                    })
            $expensive = @($lambdaInvocations |
                Where-Object {
                    [string]$_.Expression.ToString() -match
                        '(?:Async|^(?:System\.)?IO\.File\.|HttpClient|Database|Repository\.)'
                }).Count -gt 0 -or
                @($lambda.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.AwaitExpressionSyntax]
                    }).Count -gt 0
            $results['cheap-validation'] =
                New-ContextualOutcome `
                    -RuleId cheap-validation `
                    -State $(if ($expensive) {
                        'violation'
                    } else { 'compliant' }) `
                    -Reason $(if ($expensive) {
                        'validation-delegate-does-io-or-heavy-work'
                    } else {
                        'validation-delegate-is-in-memory'
                    }) `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $lambda) `
                    -EndLine (Get-ContextualNodeLine $lambda) `
                    -Symbol (
                        [string]$method.Identifier.ValueText) `
                    -Evidence $(if ($expensive) {
                        'Keep request validation delegates cheap.'
                    } else { '' })
        }
        $jObjectParameters = @($method.ParameterList.
            Parameters | Where-Object {
                [string]$_.Type.ToString() -in @(
                    'JObject',
                    'Newtonsoft.Json.Linq.JObject')
            } | ForEach-Object {
                [string]$_.Identifier.ValueText
            })
        foreach ($name in $jObjectParameters) {
            $accesses = @($method.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.ElementAccessExpressionSyntax] -and
                    [string]$_.Expression.ToString() -ceq
                        $name -and
                    $_.ArgumentList.Arguments.Count -eq 1 -and
                    $_.ArgumentList.Arguments[
                        0].Expression -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.LiteralExpressionSyntax]
                })
            if ($accesses.Count -ge 2 -and
                [string]$method.Identifier.ValueText -notmatch
                    '(?i)dynamic|extension') {
                $results['typed-contracts'] =
                    New-ContextualOutcome `
                        -RuleId typed-contracts `
                        -State violation `
                        -Reason fixed-contract-accessed-by-json-keys `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $accesses[0]) `
                        -EndLine (Get-ContextualNodeLine $accesses[0]) `
                        -Symbol (
                            [string]$method.Identifier.ValueText) `
                        -Evidence (
                            'Use a typed contract for the proven fixed JSON shape.')
            }
        }
        $reflection = @($invocations |
            Where-Object {
                if ($_.Expression -isnot [
                    Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) {
                    return $false
                }
                if ([string]$_.Expression.Name.
                    Identifier.ValueText -notmatch
                    '^Get(?:Method|Methods|Property|Properties|CustomAttributes)$') {
                    return $false
                }
                $receiver = $_.Expression.Expression
                if ($receiver -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.TypeOfExpressionSyntax]) {
                    return $true
                }
                return (Get-ContextualReceiverType `
                        -Expression $receiver `
                        -Method $method) -in @(
                            'Type',
                            'System.Type')
            })
        if ($reflection.Count -gt 1) {
            $results['cache-streaming'] =
                New-ContextualOutcome `
                    -RuleId cache-streaming `
                    -State violation `
                    -Reason repeated-reflection-not-cached `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $reflection[0]) `
                    -EndLine (Get-ContextualNodeLine $reflection[0]) `
                    -Symbol (
                        [string]$method.Identifier.ValueText) `
                    -Evidence 'Cache repeated reflection lookup results.'
        }
        $buffer = @($invocations | Where-Object {
                [string]$_.Expression.ToString() -match
                    '\.(?:ReadAsByteArrayAsync|ReadAsStringAsync|ReadToEndAsync)$'
            } | Select-Object -First 1)
        if ($buffer.Count -eq 1) {
            $bufferStatement = @($buffer[0].Ancestors() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.StatementSyntax]
                } | Select-Object -First 1)
            $priorLargeGuard = @($method.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.IfStatementSyntax] -and
                    $_.SpanStart -lt $buffer[0].SpanStart -and
                    [string]$_.Condition.ToString() -match
                        '(?i)(?:ContentLength|Length)\s*(?:>|>=)\s*(?:1048576|1_048_576|[2-9][0-9]{6,})'
                } | Select-Object -Last 1)
            $guardTerminates = $priorLargeGuard.Count -eq 1 -and
                @($priorLargeGuard[0].Statement.
                    DescendantNodesAndSelf() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.ThrowStatementSyntax] -or
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.ReturnStatementSyntax]
                    }).Count -gt 0
            if ($priorLargeGuard.Count -eq 1 -and
                -not $guardTerminates) {
                $results['cache-streaming'] =
                    New-ContextualOutcome `
                        -RuleId cache-streaming `
                        -State violation `
                        -Reason proven-large-payload-fully-buffered `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $buffer[0]) `
                        -EndLine (Get-ContextualNodeLine $buffer[0]) `
                        -Symbol (
                            [string]$method.Identifier.ValueText) `
                        -Evidence (
                            'Stream the payload proven to exceed the large bound.')
            }
        }
    }

    $localHttpClient = @($nodes | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax] -and
            [string]$_.Identifier.ValueText -ceq
                'HttpClient'
        }).Count -gt 0
    $usingSystemHttp = @($root.Usings |
        Where-Object {
            [string]$_.Name.ToString() -ceq
                'System.Net.Http'
        }).Count -gt 0
    foreach ($creation in @($nodes | Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.ObjectCreationExpressionSyntax] -and
                (Test-ContextualNodeChanged `
                    -Node $_ -Spans $Spans) -and
                [string]$_.Type.ToString() -match
                    '(?:^|\.)HttpClient$'
            })) {
        $fullType = [string]$creation.Type.ToString()
        if ($localHttpClient -and
            $fullType -ceq 'HttpClient') {
            $results['http-client-lifetime'] =
                New-ContextualOutcome `
                    -RuleId http-client-lifetime `
                    -State unknown `
                    -Reason http-client-type-shadowed `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $creation) `
                    -EndLine (Get-ContextualNodeLine $creation)
            continue
        }
        if ($fullType -cne
                'System.Net.Http.HttpClient' -and
            -not $usingSystemHttp) {
            $results['http-client-lifetime'] =
                New-ContextualOutcome `
                    -RuleId http-client-lifetime `
                    -State unknown `
                    -Reason http-client-type-unproven `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $creation) `
                    -EndLine (Get-ContextualNodeLine $creation)
            continue
        }
        $field = @($creation.Ancestors() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax]
            } | Select-Object -First 1)
        $constructor = @($creation.Ancestors() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax]
            } | Select-Object -First 1)
        $factory = $Content -match '\bIHttpClientFactory\b'
        if ($field.Count -eq 0 -and
            $constructor.Count -eq 0 -and
            -not $factory) {
            $results['http-client-lifetime'] =
                New-ContextualOutcome `
                    -RuleId http-client-lifetime `
                    -State violation `
                    -Reason request-path-http-client-construction `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $creation) `
                    -EndLine (Get-ContextualNodeLine $creation) `
                    -Evidence (
                        'Reuse System.Net.Http.HttpClient or use IHttpClientFactory.')
        }
    }

    $staticFields = @($nodes | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax] -and
            [string]$_.Modifiers.ToString() -match
                '\bstatic\b'
        } | ForEach-Object {
            $_.Declaration.Variables |
                ForEach-Object {
                    [string]$_.Identifier.ValueText
                }
        })
    foreach ($statement in @($nodes | Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.IfStatementSyntax] -and
                (Test-ContextualNodeChanged `
                    -Node $_ -Spans $Spans)
            })) {
        $condition = [string]$statement.Condition.ToString()
        foreach ($field in $staticFields) {
            if ($condition -notmatch (
                "\b$([regex]::Escape($field))\b\s*==\s*null")) {
                continue
            }
            $assigns = @($statement.Statement.
                DescendantNodesAndSelf() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.AssignmentExpressionSyntax] -and
                    [string]$_.Left.ToString() -match (
                        "(?:^|\.)$([regex]::Escape($field))$")
                }).Count -gt 0
            $synchronized = @($statement.Ancestors() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.LockStatementSyntax]
                }).Count -gt 0 -or
                [string]$statement.ToString() -match
                    '\bInterlocked\.'
            if ($assigns -and -not $synchronized) {
                $results['thread-safe-immutable'] =
                    New-ContextualOutcome `
                        -RuleId thread-safe-immutable `
                        -State violation `
                        -Reason unsynchronized-shared-initialization `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $statement) `
                        -EndLine (Get-ContextualNodeLine $statement) `
                        -Symbol $field `
                        -Evidence (
                            'Protect shared lazy initialization with Lazy<T>, Interlocked, or a lock.')
            }
        }
    }

    foreach ($type in @($nodes | Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.ClassDeclarationSyntax]
            })) {
        $typeText = [string]$type.AttributeLists.ToString()
        $properties = @($type.Members | Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.PropertyDeclarationSyntax]
            })
        $serialized = $typeText -match
                'JsonObject|DataContract' -or
            @($properties | Where-Object {
                    [string]$_.AttributeLists.ToString() -match
                        'JsonProperty|JsonIgnore|JsonInclude|JsonPropertyName|DataMember|IgnoreDataMember'
                }).Count -gt 0
        $optIn = $typeText -match
            'JsonObject\s*\(\s*MemberSerialization\.OptIn'
        if (-not $serialized -or $optIn) {
            continue
        }
        foreach ($property in $properties) {
            if (-not (Test-ContextualNodeChanged `
                    -Node $property -Spans $Spans)) {
                continue
            }
            $attributes =
                [string]$property.AttributeLists.ToString()
            if ($attributes -notmatch
                'JsonProperty|JsonIgnore|JsonInclude|JsonPropertyName|DataMember|IgnoreDataMember') {
                $results['json-contracts'] =
                    New-ContextualOutcome `
                        -RuleId json-contracts `
                        -State violation `
                        -Reason json-property-not-declared `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $property) `
                        -EndLine (Get-ContextualNodeLine $property) `
                        -Symbol (
                            [string]$type.Identifier.ValueText) `
                        -Evidence (
                            'Declare or ignore the serialized property deliberately.')
            }
        }
    }

    foreach ($method in $methods) {
        if (-not (Test-ContextualNodeChanged `
                -Node $method -Spans $Spans)) {
            continue
        }
        $api = [string]$method.AttributeLists.ToString() -match
                '\bHttp' -or
            @($method.Ancestors() | Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.ClassDeclarationSyntax] -and
                    [string]$_.Identifier.ValueText -match
                        'Controller|ApiEngine'
                }).Count -gt 0
        if ($api) {
            $badException = @($method.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.ObjectCreationExpressionSyntax] -and
                    [string]$_.Type.ToString() -in @(
                        'Exception',
                        'InvalidOperationException',
                        'System.InvalidOperationException')
                } | Select-Object -First 1)
            if ($badException.Count -eq 1 -and
                [string]$method.ToString() -notmatch
                    'ErrorResponseMessage|GenerateResponseMessageFromException') {
                $results['api-errors'] =
                    New-ContextualOutcome `
                        -RuleId api-errors `
                        -State violation `
                        -Reason nonstandard-api-error-path `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $badException[0]) `
                        -EndLine (Get-ContextualNodeLine $badException[0]) `
                        -Symbol (
                            [string]$method.Identifier.ValueText) `
                        -Evidence (
                            'Use the repository actionable API error contract.')
            }
        }
        foreach ($assignment in @(
                $method.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.AssignmentExpressionSyntax] -and
                        (Test-ContextualNodeChanged `
                            -Node $_ -Spans $Spans)
                    })) {
            $left = [string]$assignment.Left.ToString()
            $right = [string]$assignment.Right.ToString()
            if ($left -notmatch
                '(?i)(?:response|result)\.(?:password|secret|token|authorization|connectionString|apiKey)$') {
                continue
            }
            if ($right -match '(?i)Redact|Mask|Sanitize') {
                $results['secret-redaction'] =
                    New-ContextualOutcome `
                        -RuleId secret-redaction `
                        -State compliant `
                        -Reason response-value-redacted `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $assignment) `
                        -EndLine (Get-ContextualNodeLine $assignment)
                continue
            }
            if ($right -notmatch
                '(?i)(?:password|secret|token|authorization|connectionString|apiKey)') {
                $results['secret-redaction'] =
                    New-ContextualOutcome `
                        -RuleId secret-redaction `
                        -State unknown `
                        -Reason sensitive-source-unproven `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $assignment) `
                        -EndLine (Get-ContextualNodeLine $assignment)
                continue
            }
            $cacheBranch = @($assignment.Ancestors() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.IfStatementSyntax] -and
                    [string]$_.Condition.ToString() -match
                        '(?i)(?:cache|cached|metadata).*(?:==\s*null|is\s+null|miss)'
                } | Select-Object -First 1)
            if ($cacheBranch.Count -eq 1) {
                $results['secret-redaction'] =
                    New-ContextualOutcome `
                        -RuleId secret-redaction `
                        -State violation `
                        -Reason cold-cache-sensitive-value-reaches-response `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $assignment) `
                        -EndLine (Get-ContextualNodeLine $assignment) `
                        -Symbol (
                            [string]$method.Identifier.ValueText) `
                        -Evidence (
                            'Redact the sensitive field on the proven cache-miss response path.')
            }
            else {
                $results['secret-redaction'] =
                    New-ContextualOutcome `
                        -RuleId secret-redaction `
                        -State unknown `
                        -Reason cold-cache-path-unproven `
                        -Path $Path `
                        -Line (Get-ContextualNodeLine $assignment) `
                        -EndLine (Get-ContextualNodeLine $assignment)
            }
        }
    }

    foreach ($rule in $script:RuleIds) {
        $changedCandidates = @($contextualCandidateOutcomes |
            Where-Object { [string]$_.ruleId -ceq $rule } |
            Where-Object {
                $candidate = $_
                $first = [int]$candidate.line
                $last = [Math]::Max($first, [int]$candidate.endLine)
                @($Spans | Where-Object {
                        $first -le [int]$_.endLine -and
                        $last -ge [int]$_.startLine
                    }).Count -gt 0
            })
        if ($changedCandidates.Count -gt 0) {
            $results[$rule] = $changedCandidates[-1]
            continue
        }
        $outcome = $results[$rule]
        if ([string]$outcome.state -ceq 'violation') {
            $outcome.state = 'compliant'
            $outcome.reason = 'candidate-outside-changed-spans'
            $outcome.evidence = ''
        }
    }

    if ($parseErrors.Count -gt 0) {
        foreach ($rule in $script:RuleIds) {
            $results[$rule].state = 'unknown'
            $results[$rule].reason =
                'csharp-syntax-incomplete'
            $results[$rule].evidence = ''
        }
        $coverageOutcomes = @(
            New-ContextualOutcome `
                -RuleId test-class-code-coverage `
                -State unknown `
                -Reason csharp-syntax-incomplete `
                -Path $Path)
    }
    $baseOutcomes = @($script:RuleIds | Where-Object {
            $_ -cne 'test-class-code-coverage'
        } | ForEach-Object {
            $results[$_]
        })
    return @($baseOutcomes + $coverageOutcomes)
}

function Get-ContextualConventionOutcomes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Spans,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$SnapshotFiles
    )
    if ([Text.Encoding]::UTF8.GetByteCount($Content) -gt
            16MB -or
        $Spans.Count -gt 4096 -or
        $SnapshotFiles.Count -gt 64) {
        throw 'Contextual convention input exceeded its bounded limits.'
    }
    $outcomes = if ($Path.EndsWith(
            '.cs',
            [StringComparison]::OrdinalIgnoreCase)) {
        Get-ContextualRoslynOutcomes `
            -Content $Content -Path $Path -Spans $Spans `
            -SnapshotFiles $SnapshotFiles
    }
    else {
        @($script:RuleIds | ForEach-Object {
                New-ContextualOutcome `
                    -RuleId $_ -State compliant `
                    -Reason no-applicable-violation `
                    -Path $Path
            })
    }
    $dependency = Get-ContextualDependencyOutcome `
        -Content $Content -Path $Path `
        -SnapshotFiles $SnapshotFiles
    $outcomes = @($outcomes | ForEach-Object {
            if ([string]$_.ruleId -ceq
                'dependency-fanout') {
                $dependency
            }
            else {
                $_
            }
        })
    if ($outcomes.Count -lt $script:RuleIds.Count -or
        @($outcomes | Where-Object {
                [string]$_.ruleId -cnotin
                    $script:RuleIds
            }).Count -gt 0 -or
        @($outcomes.ruleId | Sort-Object -Unique).Count -ne
            $script:RuleIds.Count) {
        throw 'Contextual analyzer returned an invalid rule set.'
    }
    return $outcomes
}

Export-ModuleMember -Function @(
    'Get-ContextualConventionOutcomes',
    'Get-ContextualConventionRuleIds'
)
