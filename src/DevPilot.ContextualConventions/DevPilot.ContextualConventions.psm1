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
    'named-call-arguments',
    'xml-summary-layout',
    'duplicate-constant-declarations',
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

function Test-ContextualEquivalentGroupRepresentativeSelection {
    param(
        [Parameter(Mandatory)]$Invocation,
        [Parameter(Mandatory)]$Method
    )

    $lambda = $Invocation.Parent
    if ($lambda -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.SimpleLambdaExpressionSyntax] -or
        $lambda.Body -ne $Invocation) {
        return $false
    }
    $groupParameter = [string]$lambda.Parameter.Identifier.ValueText
    if ([string]::IsNullOrWhiteSpace($groupParameter) -or
        [string]$Invocation.Expression.Expression.ToString() -cne
            $groupParameter) {
        return $false
    }
    $select = $lambda.Parent.Parent.Parent
    if ($select -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -or
        $select.Expression -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -or
        [string]$select.Expression.Name.Identifier.ValueText -cne 'Select') {
        return $false
    }
    $groupBy = $select.Expression.Expression
    if ($groupBy -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -or
        $groupBy.Expression -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -or
        [string]$groupBy.Expression.Name.Identifier.ValueText -cne 'GroupBy' -or
        $groupBy.ArgumentList.Arguments.Count -lt 1) {
        return $false
    }
    $keySelector = $groupBy.ArgumentList.Arguments[0].Expression
    if ($keySelector -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.SimpleLambdaExpressionSyntax]) {
        return $false
    }
    $keyParameter = [string]$keySelector.Parameter.Identifier.ValueText
    if ([string]$keySelector.Body.ToString() -ceq $keyParameter -and
        $groupBy.ArgumentList.Arguments.Count -eq 1) {
        $sourceName = [string]$groupBy.Expression.Expression.ToString()
        $sourceParameter = @(
            $Method.ParameterList.Parameters |
                Where-Object {
                    [string]$_.Identifier.ValueText -ceq $sourceName
                } |
                Select-Object -First 1)
        if ($sourceParameter.Count -eq 1 -and
            $null -ne $sourceParameter[0].Type) {
            $sourceType = [string]$sourceParameter[0].Type.ToString()
            $scalar = '(?:bool|byte|sbyte|short|ushort|int|uint|long|' +
                'ulong|char|decimal|double|float|string|Boolean|Byte|' +
                'SByte|Int16|UInt16|Int32|UInt32|Int64|UInt64|Char|' +
                'Decimal|Double|Single|String)'
            return $sourceType -match (
                "^(?:System\.)?$scalar\[\]$") -or
                $sourceType -match (
                    '^(?:(?:System\.)?Collections\.Generic\.)?' +
                    '(?:IEnumerable|IReadOnlyCollection|IReadOnlyList|' +
                    "ICollection|IList|List|HashSet)<\s*$scalar\s*>$")
        }
        return $false
    }
    if ($keySelector.Body -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -or
        [string]$keySelector.Body.Expression.ToString() -cne $keyParameter -or
        [string]$keySelector.Body.Name.Identifier.ValueText -cne 'Display' -or
        $groupBy.ArgumentList.Arguments.Count -ne 2 -or
        [string]$groupBy.ArgumentList.Arguments[1].Expression.ToString() -cne
            'StringComparer.OrdinalIgnoreCase') {
        return $false
    }
    $sourceSelect = $groupBy.Expression.Expression
    if ($sourceSelect -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -or
        $sourceSelect.Expression -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -or
        [string]$sourceSelect.Expression.Name.Identifier.ValueText -cne 'Select' -or
        $sourceSelect.ArgumentList.Arguments.Count -ne 1) {
        return $false
    }
    $sourceSelector = $sourceSelect.ArgumentList.Arguments[0].Expression
    if ($sourceSelector -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.SimpleLambdaExpressionSyntax] -or
        $sourceSelector.Body -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax]) {
        return $false
    }
    $factory = $sourceSelector.Body
    return [string]$factory.Expression.ToString() -match
        '^(?:Microsoft\.CodeAnalysis\.)?MetadataReference\.CreateFromFile$' -and
        $factory.ArgumentList.Arguments.Count -eq 1 -and
        [string]$factory.ArgumentList.Arguments[0].Expression.ToString() -ceq
            [string]$sourceSelector.Parameter.Identifier.ValueText
}

function Test-ContextualGroupRepresentativeSelection {
    param([Parameter(Mandatory)]$Invocation)

    $lambda = $Invocation.Parent
    if ($lambda -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.SimpleLambdaExpressionSyntax] -or
        $lambda.Body -ne $Invocation) {
        return $false
    }
    $groupParameter = [string]$lambda.Parameter.Identifier.ValueText
    if ([string]$Invocation.Expression.Expression.ToString() -cne
        $groupParameter) {
        return $false
    }
    $select = $lambda.Parent.Parent.Parent
    return $select -is [
        Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -and
        $select.Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -and
        [string]$select.Expression.Name.Identifier.ValueText -ceq 'Select' -and
        $select.Expression.Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -and
        $select.Expression.Expression.Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -and
        [string]$select.Expression.Expression.Expression.Name.
            Identifier.ValueText -ceq 'GroupBy'
}

function Test-ContextualSynchronousAssertionCallback {
    param(
        [Parameter(Mandatory)]$Invocation,
        [Parameter(Mandatory)]$Method
    )
    if ([string]$Method.Modifiers.ToString() -match '\basync\b') {
        return $false
    }
    $lambda = @(
        $Invocation.Ancestors() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.ParenthesizedLambdaExpressionSyntax] -or
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.SimpleLambdaExpressionSyntax]
            } |
            Select-Object -First 1)
    if ($lambda.Count -ne 1) {
        return $false
    }
    $assertion = $lambda[0].Parent.Parent.Parent
    return $assertion -is [
        Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -and
        [string]$assertion.Expression.ToString() -match
            '^(?:Assert\.)?ThrowsException(?:<[^>]+>)?$'
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

function Get-ContextualNormalizedTypeName {
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [AllowNull()]$ContextNode
    )
    $value = ($TypeName -replace '\s+', '') -replace '^global::', ''
    if ($value.EndsWith('?')) {
        return 'System.Nullable<' +
            (Get-ContextualNormalizedTypeName `
                -TypeName $value.Substring(
                    0, $value.Length - 1) `
                -ContextNode $ContextNode) + '>'
    }
    if ($value -match '^(?:System\.)?Nullable<(?<inner>.+)>$') {
        return 'System.Nullable<' +
            (Get-ContextualNormalizedTypeName `
                -TypeName $Matches.inner `
                -ContextNode $ContextNode) + '>'
    }
    switch -CaseSensitive ($value) {
        'string' { return 'System.String' }
        'System.String' { return 'System.String' }
        'bool' { return 'System.Boolean' }
        'System.Boolean' { return 'System.Boolean' }
        'byte' { return 'System.Byte' }
        'System.Byte' { return 'System.Byte' }
        'sbyte' { return 'System.SByte' }
        'System.SByte' { return 'System.SByte' }
        'short' { return 'System.Int16' }
        'System.Int16' { return 'System.Int16' }
        'ushort' { return 'System.UInt16' }
        'System.UInt16' { return 'System.UInt16' }
        'int' { return 'System.Int32' }
        'System.Int32' { return 'System.Int32' }
        'uint' { return 'System.UInt32' }
        'System.UInt32' { return 'System.UInt32' }
        'long' { return 'System.Int64' }
        'System.Int64' { return 'System.Int64' }
        'ulong' { return 'System.UInt64' }
        'System.UInt64' { return 'System.UInt64' }
        'char' { return 'System.Char' }
        'System.Char' { return 'System.Char' }
        'decimal' { return 'System.Decimal' }
        'System.Decimal' { return 'System.Decimal' }
        'double' { return 'System.Double' }
        'System.Double' { return 'System.Double' }
        'float' { return 'System.Single' }
        'System.Single' { return 'System.Single' }
        'object' { return 'System.Object' }
        'System.Object' { return 'System.Object' }
        'System.Uri' { return 'System.Uri' }
        'System.StringComparison' {
            return 'System.StringComparison'
        }
    }
    $systemNames = @{
        String = 'System.String'
        Boolean = 'System.Boolean'
        Byte = 'System.Byte'
        SByte = 'System.SByte'
        Int16 = 'System.Int16'
        UInt16 = 'System.UInt16'
        Int32 = 'System.Int32'
        UInt32 = 'System.UInt32'
        Int64 = 'System.Int64'
        UInt64 = 'System.UInt64'
        Char = 'System.Char'
        Decimal = 'System.Decimal'
        Double = 'System.Double'
        Single = 'System.Single'
        Object = 'System.Object'
        Uri = 'System.Uri'
        StringComparison = 'System.StringComparison'
    }
    if ($systemNames.ContainsKey($value) -and
        $null -ne $ContextNode) {
        $root = $ContextNode.GetLocation().
            SourceTree.GetRoot()
        $usings = @($root.Usings)
        foreach ($ancestor in $ContextNode.Ancestors()) {
            if ($ancestor -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.BaseNamespaceDeclarationSyntax]) {
                $usings += @($ancestor.Usings)
            }
        }
        $systemImported = @($usings | Where-Object {
                $null -eq $_.Alias -and
                [string]$_.Name.ToString() -ceq
                    'System'
            }).Count -gt 0
        $shadowed = @($root.DescendantNodes() |
            Where-Object {
                (($_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]) -or
                    ($_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.EnumDeclarationSyntax])) -and
                [string]$_.Identifier.ValueText -ceq
                    $value
            }).Count -gt 0 -or
            @($usings | Where-Object {
                    $null -ne $_.Alias -and
                    [string]$_.Alias.Name.Identifier.ValueText -ceq
                        $value
                }).Count -gt 0
        if ($systemImported -and -not $shadowed) {
            return [string]$systemNames[$value]
        }
    }
    return $value
}

function Get-ContextualNamedCallLanguageState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    $contents = [Collections.Generic.List[string]]::new()
    foreach ($file in $SnapshotFiles) {
        if ($file -isnot [Collections.IDictionary]) {
            continue
        }
        if ($file.Contains('projectContext') -and
            $file.projectContext -is [Collections.IDictionary] -and
            [string]$file.projectContext.state -ceq 'complete' -and
            $file.projectContext.content -is [string]) {
            [void]$contents.Add(
                [string]$file.projectContext.content)
        }
        if ([string]$file.state -ceq 'complete' -and
            [string]$file.path -imatch '\.csproj$' -and
            $file.content -is [string]) {
            [void]$contents.Add([string]$file.content)
        }
    }
    $versions = @(@(
            foreach ($content in $contents) {
            foreach ($match in [regex]::Matches(
                    $content,
                    '(?is)<LangVersion(?:\s+Condition\s*=\s*["''][^"'']+["''])?\s*>\s*(?<value>[^<]+)\s*</LangVersion>')) {
                if ($match.Value -match '(?i)Condition\s*=') {
                    return [pscustomobject]@{
                        State = 'unknown'
                        Reason =
                            'project-language-version-conditional'
                    }
                }
                $match.Groups['value'].Value.Trim()
            }
        }) | Sort-Object -Unique)
    if ($versions.Count -eq 0) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'project-language-version-unknown'
        }
    }
    if ($versions.Count -ne 1) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'project-language-version-ambiguous'
        }
    }
    $version = [string]$versions[0]
    if ($version -in @(
            'latest', 'latestMajor', 'preview', 'default')) {
        return [pscustomobject]@{
            State = 'supported'
            Version = $version
        }
    }
    $parsed = 0.0
    if (-not [double]::TryParse(
            $version,
            [Globalization.NumberStyles]::AllowDecimalPoint,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed)) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'project-language-version-unrecognized'
        }
    }
    return [pscustomobject]@{
        State = $(if ($parsed -ge 4.0) {
                'supported'
            } else { 'unsupported' })
        Version = $version
        Reason = $(if ($parsed -lt 4.0) {
                'named-arguments-language-version-unsupported'
            } else { $null })
    }
}

function Get-ContextualNamedCallSignatures {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    $signatures = [Collections.Generic.List[object]]::new()
    $files = [Collections.Generic.List[object]]::new()
    [void]$files.Add([pscustomobject]@{
            path = $Path
            root = $Root
        })
    foreach ($file in $SnapshotFiles) {
        if ($file -isnot [Collections.IDictionary] -or
            [string]$file.state -cne 'complete' -or
            [string]$file.path -inotmatch '\.cs$' -or
            $file.content -isnot [string] -or
            [string]$file.path -ieq $Path) {
            continue
        }
        $tree = [
            Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText(
                [string]$file.content)
        if (@($tree.GetDiagnostics() | Where-Object {
                    $_.Severity -eq [
                        Microsoft.CodeAnalysis.DiagnosticSeverity]::Error
                }).Count -gt 0) {
            continue
        }
        [void]$files.Add([pscustomobject]@{
                path = [string]$file.path
                root = $tree.GetRoot()
            })
    }
    foreach ($file in $files) {
        foreach ($node in @($file.root.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -or
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax]
                })) {
            if ($node -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -and
                $null -ne $node.ExplicitInterfaceSpecifier) {
                continue
            }
            $type = @($node.Ancestors() | Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
                } | Select-Object -First 1)
            if ($type.Count -ne 1) {
                continue
            }
            $parameters = @(
                foreach ($parameter in @(
                        $node.ParameterList.Parameters)) {
                    [ordered]@{
                        name =
                            [string]$parameter.Identifier.ValueText
                        type = Get-ContextualNormalizedTypeName `
                            -TypeName ([string]$parameter.Type) `
                            -ContextNode $parameter
                        modifier =
                            [string]$parameter.Modifiers.ToString()
                        optional =
                            $null -ne $parameter.Default
                        params =
                            @($parameter.Modifiers | Where-Object {
                                    [string]$_.Text -ceq 'params'
                                }).Count -gt 0
                    }
                })
            $namespace = @($type[0].Ancestors() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.BaseNamespaceDeclarationSyntax]
                } |
                Select-Object -First 1)
            $namespaceName = if ($namespace.Count -eq 1) {
                [string]$namespace[0].Name.ToString()
            }
            else { '' }
            $genericParameters =
                [Collections.Generic.List[string]]::new()
            if ($null -ne
                $type[0].TypeParameterList) {
                foreach ($parameter in @(
                        $type[0].TypeParameterList.
                            Parameters)) {
                    [void]$genericParameters.Add(
                        [string]$parameter.
                            Identifier.ValueText)
                }
            }
            if ($node -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -and
                $null -ne $node.TypeParameterList) {
                foreach ($parameter in @(
                        $node.TypeParameterList.
                            Parameters)) {
                    [void]$genericParameters.Add(
                        [string]$parameter.
                            Identifier.ValueText)
                }
            }
            $requiredCount = @($parameters | Where-Object {
                    -not [bool]$_['optional'] -and
                    -not [bool]$_['params']
                }).Count
            [void]$signatures.Add([pscustomobject]@{
                    Kind = $(if ($node -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax]) {
                            'constructor'
                        } else { 'method' })
                    Name = [string]$node.Identifier.ValueText
                    Container =
                        [string]$type[0].Identifier.ValueText
                    Namespace = $namespaceName
                    FullContainer = $(if (
                        [string]::IsNullOrWhiteSpace(
                            $namespaceName)) {
                            [string]$type[0].Identifier.ValueText
                        }
                        else {
                            "$namespaceName.$(
                                [string]$type[0].Identifier.ValueText)"
                        })
                    IsStatic = @($node.Modifiers |
                        Where-Object {
                            [string]$_.Text -ceq 'static'
                        }).Count -gt 0
                    GenericParameters = @(
                        $genericParameters |
                            Sort-Object -Unique)
                    RequiredCount = $requiredCount
                    MaximumCount = $parameters.Count
                    HasParams = @($parameters |
                        Where-Object {
                            [bool]$_['params']
                        }).Count -gt 0
                    Parameters = $parameters
                    Path = [string]$file.path
                })
        }
    }
    return $signatures.ToArray()
}

function Get-ContextualNamedCallSignature {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Signatures
    )
    if ($null -eq $Node.ArgumentList) {
        return [pscustomobject]@{
            State = 'not-applicable'
        }
    }
    $arguments = @($Node.ArgumentList.Arguments)
    if ($arguments.Count -lt 1) {
        return [pscustomobject]@{
            State = 'not-applicable'
        }
    }
    $kind = 'method'
    $name = ''
    $container = ''
    $receiverKind = 'none'
    if ($Node -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax]) {
        $expression = $Node.Expression
        $expressionText =
            ([string]$expression.ToString()) -replace '^global::', ''
        $knownStringReceiver = $expressionText -match
                '^(?:string|System\.String)\.Equals$' -or
            ($expressionText -ceq 'String.Equals' -and
                (Get-ContextualNormalizedTypeName `
                    -TypeName String `
                    -ContextNode $Node) -ceq
                    'System.String')
        if ($knownStringReceiver -and
            $arguments.Count -in @(2, 3)) {
            $parameters = @(
                [ordered]@{
                    name = 'a'
                    type = 'System.String'
                    modifier = ''
                    optional = $false
                    params = $false
                },
                [ordered]@{
                    name = 'b'
                    type = 'System.String'
                    modifier = ''
                    optional = $false
                    params = $false
                })
            if ($arguments.Count -eq 3) {
                $parameters += [ordered]@{
                    name = 'comparisonType'
                    type = 'System.StringComparison'
                    modifier = ''
                    optional = $false
                    params = $false
                }
            }
            return [pscustomobject]@{
                State = 'resolved'
                Signature = [pscustomobject]@{
                    Kind = 'method'
                    Name = 'Equals'
                    Container = 'String'
                    GenericParameters = @()
                    Parameters = $parameters
                    Path = 'known-bcl'
                }
            }
        }
        if ($expression -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) {
            $name = [string]$expression.Name.Identifier.ValueText
            $receiver = [string]$expression.Expression.ToString()
            if ($receiver -ceq 'this') {
                $receiverKind = 'instance'
                $owner = @($Node.Ancestors() | Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
                    } | Select-Object -First 1)
                if ($owner.Count -eq 1) {
                    $container =
                        [string]$owner[0].Identifier.ValueText
                }
            }
            elseif ($receiver -ceq 'base') {
                $receiverKind = 'instance'
                $owner = @($Node.Ancestors() | Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
                    } | Select-Object -First 1)
                if ($owner.Count -ne 1 -or
                    $null -eq $owner[0].BaseList -or
                    $owner[0].BaseList.Types.Count -ne 1) {
                    return [pscustomobject]@{
                        State = 'unknown'
                        Reason = 'call-receiver-type-unproven'
                    }
                }
                else {
                    $container = (
                        [string]$owner[0].BaseList.Types[0].Type.ToString() `
                            -split '\.')[-1]
                }
            }
            else {
                $receiverKind = 'static'
                if ($expression.Expression -isnot [
                        Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax] -and
                    $expression.Expression -isnot [
                        Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -and
                    $expression.Expression -isnot [
                        Microsoft.CodeAnalysis.CSharp.Syntax.AliasQualifiedNameSyntax]) {
                    return [pscustomobject]@{
                        State = 'unknown'
                        Reason = 'call-receiver-type-unproven'
                    }
                }
                $receiver = $receiver -replace '^global::', ''
                $container = ($receiver -split '\.')[-1]
                $method = @($Node.Ancestors() | Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -or
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax]
                    } | Select-Object -First 1)
                $shadowed = $false
                if ($method.Count -eq 1) {
                    $shadowed =
                        @($method[0].ParameterList.Parameters |
                            Where-Object {
                                [string]$_.Identifier.ValueText -ceq
                                    $container
                            }).Count -gt 0 -or
                        @($method[0].DescendantNodes() |
                            Where-Object {
                                $_ -is [
                                    Microsoft.CodeAnalysis.CSharp.Syntax.VariableDeclaratorSyntax] -and
                                [string]$_.Identifier.ValueText -ceq
                                    $container
                            }).Count -gt 0
                }
                $owner = @($Node.Ancestors() | Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
                    } | Select-Object -First 1)
                if ($owner.Count -eq 1) {
                    $shadowed = $shadowed -or
                        @($owner[0].Members | Where-Object {
                                ($_ -is [
                                        Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax] -and
                                    @($_.Declaration.Variables |
                                        Where-Object {
                                            [string]$_.Identifier.ValueText -ceq
                                                $container
                                        }).Count -gt 0) -or
                                ($_ -is [
                                        Microsoft.CodeAnalysis.CSharp.Syntax.PropertyDeclarationSyntax] -and
                                    [string]$_.Identifier.ValueText -ceq
                                        $container)
                            }).Count -gt 0
                }
                $usings = @($Root.Usings)
                foreach ($ancestor in $Node.Ancestors()) {
                    if ($ancestor -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.BaseNamespaceDeclarationSyntax]) {
                        $usings += @($ancestor.Usings)
                    }
                }
                $shadowed = $shadowed -or
                    @($usings | Where-Object {
                            $null -ne $_.Alias -and
                            [string]$_.Alias.Name.Identifier.ValueText -ceq
                                $container
                        }).Count -gt 0
                if ($shadowed) {
                    return [pscustomobject]@{
                        State = 'unknown'
                        Reason = 'call-receiver-type-unproven'
                    }
                }
            }
        }
        elseif ($expression -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax] -or
            $expression -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.GenericNameSyntax]) {
            $name = [string]$expression.Identifier.ValueText
            $owner = @($Node.Ancestors() | Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
                } | Select-Object -First 1)
            if ($owner.Count -eq 1) {
                $container =
                    [string]$owner[0].Identifier.ValueText
            }
        }
        if ($name -ceq 'AreEqual' -and
            [string]$expression.ToString() -match
                '(?:^|\.)Assert\.AreEqual$') {
            return [pscustomobject]@{
                State = 'excluded'
                Reason = 'mstest-areequal-owned-by-named-rule'
            }
        }
    }
    elseif ($Node -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.ObjectCreationExpressionSyntax]) {
        $kind = 'constructor'
        $container =
            ([string]$Node.Type.ToString() -split '\.')[-1]
        $name = $container
    }
    elseif ($Node -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorInitializerSyntax]) {
        $kind = 'constructor'
        $owner = @($Node.Ancestors() | Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
            } | Select-Object -First 1)
        if ($owner.Count -ne 1) {
            return [pscustomobject]@{
                State = 'unknown'
                Reason = 'constructor-container-unproven'
            }
        }
        if ([string]$Node.ThisOrBaseKeyword.Text -ceq 'this') {
            $container =
                [string]$owner[0].Identifier.ValueText
        }
        else {
            if ($null -eq $owner[0].BaseList) {
                return [pscustomobject]@{
                    State = 'unknown'
                    Reason = 'base-constructor-type-unproven'
                }
            }
            $bases = @($owner[0].BaseList.Types)
            if ($bases.Count -ne 1) {
                return [pscustomobject]@{
                    State = 'unknown'
                    Reason = 'base-constructor-type-unproven'
                }
            }
            $container =
                ([string]$bases[0].Type.ToString() -split '\.')[-1]
        }
        $name = $container
    }
    else {
        return [pscustomobject]@{
            State = 'not-applicable'
        }
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'call-target-unproven'
        }
    }
    $candidates = @($Signatures | Where-Object {
            [string]$_.Kind -ceq $kind -and
            [string]$_.Name -ceq $name -and
            [int]$_.RequiredCount -le $arguments.Count -and
            ([bool]$_.HasParams -or
                [int]$_.MaximumCount -ge $arguments.Count)
        })
    if (-not [string]::IsNullOrWhiteSpace($container)) {
        $contained = @($candidates | Where-Object {
                [string]$_.Container -ceq $container -and
                ($(if ($receiverKind -ceq 'static') {
                        [bool]$_.IsStatic
                    }
                    elseif ($receiverKind -ceq 'instance') {
                        -not [bool]$_.IsStatic
                    }
                    else { $true }))
            })
        if ($receiverKind -ceq 'static' -and
            $contained.Count -gt 0) {
            $receiverText = (
                [string]$Node.Expression.Expression.ToString()) `
                -replace '^global::', ''
            $exact = @($contained | Where-Object {
                    [string]$_.FullContainer -ceq
                        $receiverText
                })
            if ($exact.Count -eq 1) {
                $contained = $exact
            }
            elseif ($receiverText -ceq $container) {
                $namespaces = @($contained.Namespace |
                    Sort-Object -Unique)
                if ($namespaces.Count -gt 1) {
                    return [pscustomobject]@{
                        State = 'unknown'
                        Reason = 'call-receiver-type-unproven'
                    }
                }
            }
            else {
                return [pscustomobject]@{
                    State = 'unknown'
                    Reason = 'call-receiver-type-unproven'
                }
            }
        }
        if ($contained.Count -gt 0) {
            $candidates = $contained
        }
        else {
            return [pscustomobject]@{
                State = 'unknown'
                Reason = 'call-receiver-type-unproven'
            }
        }
    }
    if ($candidates.Count -ne 1) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = $(if ($candidates.Count -gt 1) {
                    'selected-overload-ambiguous'
                } else { 'selected-overload-unavailable' })
        }
    }
    if ([bool]$candidates[0].HasParams) {
        return [pscustomobject]@{
            State = 'unknown'
            Reason = 'expanded-params-binding-unproven'
        }
    }
    return [pscustomobject]@{
        State = 'resolved'
        Signature = $candidates[0]
    }
}

function Test-ContextualConstantSyntax {
    param(
        [Parameter(Mandatory)]$Expression,
        [AllowEmptyCollection()]
        [string[]]$KnownNames = @()
    )
    if ($Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.LiteralExpressionSyntax] -or
        $Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.DefaultExpressionSyntax]) {
        return $true
    }
    if ($Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.ParenthesizedExpressionSyntax]) {
        return Test-ContextualConstantSyntax `
            -Expression $Expression.Expression `
            -KnownNames $KnownNames
    }
    if ($Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.PrefixUnaryExpressionSyntax] -and
        [string]$Expression.OperatorToken.Text -in @(
            '+', '-', '~', '!')) {
        return Test-ContextualConstantSyntax `
            -Expression $Expression.Operand `
            -KnownNames $KnownNames
    }
    if ($Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.BinaryExpressionSyntax]) {
        return (Test-ContextualConstantSyntax `
                -Expression $Expression.Left `
                -KnownNames $KnownNames) -and
            (Test-ContextualConstantSyntax `
                -Expression $Expression.Right `
                -KnownNames $KnownNames)
    }
    if ($Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -and
        [string]$Expression.Expression.ToString() -ceq 'nameof') {
        return $true
    }
    $text = [string]$Expression.ToString()
    return $text -cin $KnownNames
}

function Get-ContextualNamedCallConstants {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    $constants = [Collections.Generic.List[object]]::new()
    $files = [Collections.Generic.List[object]]::new()
    [void]$files.Add([pscustomobject]@{
            path = $Path
            root = $Root
            current = $true
        })
    foreach ($file in $SnapshotFiles) {
        if ($file -isnot [Collections.IDictionary] -or
            [string]$file.state -cne 'complete' -or
            [string]$file.path -inotmatch '\.cs$' -or
            $file.content -isnot [string] -or
            [string]$file.path -ieq $Path) {
            continue
        }
        $tree = [
            Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText(
                [string]$file.content)
        if (@($tree.GetDiagnostics() | Where-Object {
                    $_.Severity -eq [
                        Microsoft.CodeAnalysis.DiagnosticSeverity]::Error
                }).Count -gt 0) {
            continue
        }
        [void]$files.Add([pscustomobject]@{
                path = [string]$file.path
                root = $tree.GetRoot()
                current = $false
            })
    }
    foreach ($file in $files) {
        $known = [Collections.Generic.List[string]]::new()
        foreach ($enum in @($file.root.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.EnumDeclarationSyntax]
                })) {
            foreach ($member in @($enum.Members)) {
                $qualified =
                    [string]$enum.Identifier.ValueText +
                    '.' +
                    [string]$member.Identifier.ValueText
                [void]$known.Add($qualified)
                [void]$constants.Add([pscustomobject]@{
                        Kind = 'enum'
                        Name =
                            [string]$member.Identifier.ValueText
                        QualifiedName = $qualified
                        Container =
                            [string]$enum.Identifier.ValueText
                        Path = [string]$file.path
                        Current = [bool]$file.current
                        Declaration = $member
                    })
            }
        }
        foreach ($field in @($file.root.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax] -and
                    @($_.Modifiers | Where-Object {
                            [string]$_.Text -ceq 'const'
                        }).Count -gt 0
                })) {
            $owner = @($field.Ancestors() | Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
                } | Select-Object -First 1)
            if ($owner.Count -ne 1) {
                continue
            }
            foreach ($variable in @(
                    $field.Declaration.Variables)) {
                if ($null -eq $variable.Initializer -or
                    -not (Test-ContextualConstantSyntax `
                        -Expression $variable.Initializer.Value `
                        -KnownNames $known.ToArray())) {
                    continue
                }
                $qualified =
                    [string]$owner[0].Identifier.ValueText +
                    '.' +
                    [string]$variable.Identifier.ValueText
                [void]$known.Add(
                    [string]$variable.Identifier.ValueText)
                [void]$known.Add($qualified)
                [void]$constants.Add([pscustomobject]@{
                        Kind = 'field'
                        Name =
                            [string]$variable.Identifier.ValueText
                        QualifiedName = $qualified
                        Container =
                            [string]$owner[0].Identifier.ValueText
                        Path = [string]$file.path
                        Current = [bool]$file.current
                        Declaration = $variable
                    })
            }
        }
        if (-not [bool]$file.current) {
            continue
        }
        foreach ($local in @($file.root.DescendantNodes() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.LocalDeclarationStatementSyntax] -and
                    @($_.Modifiers | Where-Object {
                            [string]$_.Text -ceq 'const'
                        }).Count -gt 0
                })) {
            $method = @($local.Ancestors() | Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -or
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax]
                } | Select-Object -First 1)
            if ($method.Count -ne 1) {
                continue
            }
            foreach ($variable in @(
                    $local.Declaration.Variables)) {
                if ($null -eq $variable.Initializer -or
                    -not (Test-ContextualConstantSyntax `
                        -Expression $variable.Initializer.Value `
                        -KnownNames $known.ToArray())) {
                    continue
                }
                [void]$known.Add(
                    [string]$variable.Identifier.ValueText)
                [void]$constants.Add([pscustomobject]@{
                        Kind = 'local'
                        Name =
                            [string]$variable.Identifier.ValueText
                        QualifiedName = ''
                        Container = ''
                        Path = [string]$file.path
                        Current = $true
                        MethodStart =
                            [int]$method[0].SpanStart
                        ScopeStart =
                            [int]$local.Parent.SpanStart
                        ScopeEnd =
                            [int]$local.Parent.Span.End
                        Declaration = $variable
                    })
            }
        }
    }
    return $constants.ToArray()
}

function Test-ContextualCompileTimeConstantArgument {
    param(
        [Parameter(Mandatory)]$Expression,
        [Parameter(Mandatory)]$CallNode,
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Constants
    )
    if (Test-ContextualConstantSyntax `
            -Expression $Expression) {
        return $true
    }
    $text = [string]$Expression.ToString()
    if ($Expression -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) {
        return @($Constants | Where-Object {
                [string]$_.QualifiedName -ceq $text
            }).Count -eq 1
    }
    if ($Expression -isnot [
            Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax]) {
        return $false
    }
    $name = [string]$Expression.Identifier.ValueText
    $method = @($CallNode.Ancestors() | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -or
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax]
        } | Select-Object -First 1)
    if ($method.Count -eq 1) {
        if (@($method[0].ParameterList.Parameters |
                Where-Object {
                    [string]$_.Identifier.ValueText -ceq
                        $name
                }).Count -gt 0) {
            return $false
        }
        $locals = @($method[0].DescendantNodes() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.VariableDeclaratorSyntax] -and
                [string]$_.Identifier.ValueText -ceq
                    $name -and
                [int]$_.SpanStart -lt
                    [int]$CallNode.SpanStart
            } | Sort-Object {
                -[int]$_.SpanStart
            })
        if ($locals.Count -gt 0) {
            return @($Constants | Where-Object {
                    [string]$_.Kind -ceq 'local' -and
                    [string]$_.Name -ceq $name -and
                    [int]$_.MethodStart -eq
                        [int]$method[0].SpanStart -and
                    [int]$_.Declaration.SpanStart -eq
                        [int]$locals[0].SpanStart -and
                    [int]$_.ScopeStart -le
                        [int]$CallNode.SpanStart -and
                    [int]$_.ScopeEnd -ge
                        [int]$CallNode.Span.End
                }).Count -eq 1
        }
    }
    $owner = @($CallNode.Ancestors() | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
        } | Select-Object -First 1)
    if ($owner.Count -ne 1) {
        return $false
    }
    $members = @($owner[0].Members | Where-Object {
            ($_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax] -and
                @($_.Declaration.Variables | Where-Object {
                        [string]$_.Identifier.ValueText -ceq $name
                    }).Count -gt 0) -or
            ($_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.PropertyDeclarationSyntax] -and
                [string]$_.Identifier.ValueText -ceq $name)
        })
    if ($members.Count -ne 1) {
        return $false
    }
    return @($Constants | Where-Object {
            [string]$_.Kind -ceq 'field' -and
            [bool]$_.Current -and
            [string]$_.Container -ceq
                [string]$owner[0].Identifier.ValueText -and
            [string]$_.Name -ceq $name
        }).Count -eq 1
}

function Test-ContextualNamedCallExpressionTree {
    param([Parameter(Mandatory)]$Node)
    $lambda = @($Node.Ancestors() | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.ParenthesizedLambdaExpressionSyntax] -or
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.SimpleLambdaExpressionSyntax]
        } | Select-Object -First 1)
    if ($lambda.Count -ne 1) {
        return $false
    }
    $outer = @($lambda[0].Ancestors() | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax]
        } | Select-Object -First 1)
    return $outer.Count -eq 1 -and
        [string]$outer[0].Expression.ToString() -match
            '(?:^|\.)(?:Setup|Verify|SetupGet|SetupSet)$'
}

function Get-ContextualNamedCallOutcome {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Spans,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Signatures,
        [Parameter(Mandatory)]$Language,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Constants
    )
    if (-not (Test-ContextualNodeChanged `
            -Node $Node -Spans $Spans)) {
        return $null
    }
    if ($null -eq $Node.ArgumentList) {
        return $null
    }
    $arguments = @($Node.ArgumentList.Arguments)
    if ($arguments.Count -lt 1) {
        return $null
    }
    $lineSpan = $Node.GetLocation().GetLineSpan()
    $first = [int]$lineSpan.StartLinePosition.Line + 1
    $last = [int]$lineSpan.EndLinePosition.Line + 1
    $anchors = @(
        foreach ($span in $Spans) {
            if ($first -le [int]$span.endLine -and
                $last -ge [int]$span.startLine) {
                [Math]::Max($first, [int]$span.startLine)
            }
        })
    if ($anchors.Count -eq 0) {
        return $null
    }
    $anchor = [int](
        $anchors | Measure-Object -Minimum).Minimum
    $allNamed = @($arguments | Where-Object {
            $null -ne $_.NameColon
        }).Count -eq $arguments.Count
    if ($allNamed) {
        return $null
    }
    $literalTrigger = @($arguments | Where-Object {
            Test-ContextualCompileTimeConstantArgument `
                -Expression $_.Expression `
                -CallNode $Node -Root $Root `
                -Constants $Constants
        }).Count -gt 0
    $argumentLines = @($arguments | ForEach-Object {
            [int]$_.GetLocation().GetLineSpan().
                StartLinePosition.Line + 1
        })
    $multilineTrigger = $arguments.Count -gt 1 -and
        @($argumentLines | Sort-Object -Unique).Count -eq
            $arguments.Count
    if ([string]$Language.State -cne 'supported' -and
        ($literalTrigger -or $multilineTrigger -or
            $arguments.Count -ge 2)) {
        return New-ContextualOutcome `
            -RuleId named-call-arguments `
            -State unknown `
            -Reason $(if ($Language.Reason) {
                    [string]$Language.Reason
                } else {
                    'project-language-version-unknown'
                }) `
            -Path $Path -Line $anchor `
            -EndLine $anchor `
            -Symbol 'unresolved-call'
    }
    $signatureResult =
        Get-ContextualNamedCallSignature `
            -Node $Node -Root $Root `
            -Signatures $Signatures
    if ([string]$signatureResult.State -ceq 'excluded' -or
        [string]$signatureResult.State -ceq 'not-applicable') {
        return $null
    }
    if ([string]$signatureResult.State -cne 'resolved') {
        if (-not $literalTrigger -and
            -not $multilineTrigger -and
            -not ($arguments.Count -ge 2 -and
                [string]$signatureResult.Reason -cin @(
                    'selected-overload-ambiguous',
                    'expanded-params-binding-unproven',
                    'generic-type-parameter-binding-unproven',
                    'call-receiver-type-unproven'))) {
            return $null
        }
        return New-ContextualOutcome `
            -RuleId named-call-arguments `
            -State unknown `
            -Reason ([string]$signatureResult.Reason) `
            -Path $Path -Line $anchor `
            -EndLine $anchor `
            -Symbol 'unresolved-call'
    }
    $signature = $signatureResult.Signature
    $parameters = @($signature.Parameters)
    if ($arguments.Count -ge 2 -and
        @($parameters | Where-Object {
                $parameterType = [string]$_['type']
                @($signature.GenericParameters |
                    Where-Object {
                        $parameterType -match (
                            '(?:^|[^A-Za-z0-9_])' +
                            [regex]::Escape([string]$_) +
                            '(?:$|[^A-Za-z0-9_])')
                    }).Count -gt 0
            }).Count -gt 0) {
        return New-ContextualOutcome `
            -RuleId named-call-arguments `
            -State unknown `
            -Reason generic-type-parameter-binding-unproven `
            -Path $Path -Line $anchor `
            -EndLine $anchor `
            -Symbol ([string]$signature.Name)
    }
    $mapped = [Collections.Generic.HashSet[int]]::new()
    foreach ($argument in $arguments) {
        $parameterIndex = -1
        if ($null -ne $argument.NameColon) {
            $name = [string]$argument.NameColon.Name.Identifier.ValueText
            $indices = @(for ($i = 0; $i -lt $parameters.Count; $i++) {
                    if ([string]$parameters[$i].name -ceq $name) {
                        $i
                    }
                })
            if ($indices.Count -ne 1 -or
                -not $mapped.Add([int]$indices[0])) {
                return New-ContextualOutcome `
                    -RuleId named-call-arguments `
                    -State unknown `
                    -Reason named-argument-binding-invalid `
                    -Path $Path -Line $anchor `
                    -EndLine $anchor `
                    -Symbol ([string]$signature.Name)
            }
            $parameterIndex = [int]$indices[0]
        }
        else {
            $next = @(0..($parameters.Count - 1) |
                Where-Object {
                    -not $mapped.Contains([int]$_)
                } | Select-Object -First 1)
            if ($next.Count -ne 1) {
                return New-ContextualOutcome `
                    -RuleId named-call-arguments `
                    -State unknown `
                    -Reason positional-argument-binding-invalid `
                    -Path $Path -Line $anchor `
                    -EndLine $anchor `
                    -Symbol ([string]$signature.Name)
            }
            $parameterIndex = [int]$next[0]
            [void]$mapped.Add($parameterIndex)
        }
        $argumentModifier =
            [string]$argument.RefKindKeyword.Text
        $parameterModifier =
            [string]$parameters[
                $parameterIndex].modifier
        if ($parameterModifier -match '\b(ref|out|in)\b') {
            $expectedModifier =
                [string]$Matches[1]
            if ($argumentModifier -cne
                $expectedModifier) {
                return New-ContextualOutcome `
                    -RuleId named-call-arguments `
                    -State unknown `
                    -Reason argument-modifier-binding-unproven `
                    -Path $Path -Line $anchor `
                    -EndLine $anchor `
                    -Symbol ([string]$signature.Name)
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace(
                $argumentModifier)) {
            return New-ContextualOutcome `
                -RuleId named-call-arguments `
                -State unknown `
                -Reason argument-modifier-binding-unproven `
                -Path $Path -Line $anchor `
                -EndLine $anchor `
                -Symbol ([string]$signature.Name)
        }
    }
    $mappedParameters = @($mapped | Sort-Object | ForEach-Object {
            $parameters[[int]$_]
        })
    $repeatedTypeTrigger = @($mappedParameters |
        Group-Object {
            [string]$_['type']
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace(
                [string]$_.Name) -and
            $_.Count -gt 1
        }).Count -gt 0
    if (-not $literalTrigger -and
        -not $multilineTrigger -and
        -not $repeatedTypeTrigger) {
        return $null
    }
    if (Test-ContextualNamedCallExpressionTree `
            -Node $Node) {
        return New-ContextualOutcome `
            -RuleId named-call-arguments `
            -State unknown `
            -Reason expression-tree-named-arguments-unproven `
            -Path $Path -Line $anchor `
            -EndLine $anchor `
            -Symbol ([string]$signature.Name)
    }
    $method = @($Node.Ancestors() | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -or
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax]
        } | Select-Object -First 1)
    $types = if ($method.Count -eq 1) {
        Get-ContextualMethodTypeMap -Method $method[0]
    }
    else { @{} }
    foreach ($argument in $arguments) {
        if ($argument.Expression -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax] -and
            $types.Contains(
                [string]$argument.Expression.Identifier.ValueText) -and
            [string]$types[
                [string]$argument.Expression.Identifier.ValueText] -ceq
                'dynamic') {
            return New-ContextualOutcome `
                -RuleId named-call-arguments `
                -State unknown `
                -Reason dynamic-argument-binding-unproven `
                -Path $Path -Line $anchor `
                -EndLine $anchor `
                -Symbol ([string]$signature.Name)
        }
    }
    $triggers = [Collections.Generic.List[string]]::new()
    if ($repeatedTypeTrigger) {
        [void]$triggers.Add('repeated-formal-type')
    }
    if ($multilineTrigger) {
        [void]$triggers.Add('one-argument-per-line')
    }
    if ($literalTrigger) {
        [void]$triggers.Add('compile-time-constant')
    }
    return New-ContextualOutcome `
        -RuleId named-call-arguments `
        -State $(if ($allNamed) {
                'compliant'
            } else { 'violation' }) `
        -Reason $(if ($allNamed) {
                'documented-trigger-arguments-named'
            } else {
                'documented-trigger-positional-arguments'
            }) `
        -Path $Path -Line $anchor `
        -EndLine $anchor `
        -Symbol ([string]$signature.Name) `
        -Evidence $(if ($allNamed) { '' } else {
            'Name every supplied argument because this call ' +
            'has: ' + ($triggers -join ', ') + '.'
        })
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
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
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
                -not $aliases.ContainsKey(
                    'ExcludeFromCodeCoverage')) {
                if ($namespace -cin $imports) {
                    return 'present'
                }
                foreach ($file in @($SnapshotFiles |
                        Where-Object {
                            [string]$_.state -ceq 'complete' -and
                            [string]$_.path -imatch '\.cs$' -and
                            $_.content -is [string]
                        })) {
                    $tree = [
                        Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText(
                            [string]$file.content)
                    $globalImports = @($tree.GetRoot().Usings |
                        Where-Object {
                            [string]$_.GlobalKeyword.Text -ceq
                                'global' -and
                            $null -eq $_.Alias
                        } | ForEach-Object {
                            ([string]$_.Name.ToString()) `
                                -replace '^global::', ''
                        })
                    if ($namespace -cin $globalImports) {
                        return 'present'
                    }
                }
                return 'ambiguous'
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
        $pattern = [
            System.Management.Automation.WildcardPattern]::new(
            ([string]$node.GetAttribute('Remove')).Replace('/', '\'),
            [System.Management.Automation.WildcardOptions]::IgnoreCase)
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
        $anchorLine = if (
            Test-ContextualChangedLine `
                -Line $identifierLine -Spans $Spans) {
            $identifierLine
        }
        else {
            [int]$changedLines[0]
        }
        $attributeState =
            Get-ContextualCoverageAttributeState `
                -Type $type -Root $Root `
                -SnapshotFiles $SnapshotFiles
        if ($attributeState -ceq 'present') {
            continue
        }
        if ($attributeState -ceq 'ambiguous') {
            [void]$outcomes.Add(
                (New-ContextualOutcome `
                    -RuleId test-class-code-coverage `
                    -State unknown `
                    -Reason coverage-attribute-binding-unproven `
                    -Path $Path -Line $anchorLine `
                    -EndLine $anchorLine `
                    -Symbol ([string]$type.Identifier.ValueText)))
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
                    -Path $Path -Line $anchorLine `
                    -EndLine $anchorLine `
                    -Symbol ([string]$type.Identifier.ValueText)))
            continue
        }
        [void]$outcomes.Add(
            (New-ContextualOutcome `
                -RuleId test-class-code-coverage `
                -State violation `
                -Reason test-class-coverage-exclusion-missing `
                -Path $Path -Line $anchorLine `
                -EndLine $anchorLine `
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

function Get-ContextualXmlSummaryLayoutOutcome {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Spans
    )
    if ($Path -imatch
            '(^|/)(?:obj|generated|Ignore-AddedForReferenceOnly)(/|$)|(?:\.g|\.designer)\.cs$' -or
        $Content -match
            '(?im)^\s*//\s*<auto-generated(?:\s|>)') {
        return New-ContextualOutcome `
            -RuleId xml-summary-layout `
            -State compliant `
            -Reason generated-code-excluded `
            -Path $Path
    }
    $lines = @($Content -split "`r?`n")
    foreach ($declaration in @($Root.DescendantNodes() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.MemberDeclarationSyntax]
            })) {
        foreach ($trivia in @(
                $declaration.GetLeadingTrivia())) {
            if (-not $trivia.HasStructure) {
                continue
            }
            $documentation = $trivia.GetStructure()
            if ($documentation -isnot [
                    Microsoft.CodeAnalysis.CSharp.Syntax.DocumentationCommentTriviaSyntax]) {
                continue
            }
            foreach ($summary in @(
                    $documentation.Content |
                        Where-Object {
                            $_ -is [
                                Microsoft.CodeAnalysis.CSharp.Syntax.XmlElementSyntax] -and
                            [string]$_.StartTag.Name.LocalName.ValueText -ceq
                                'summary'
                        })) {
                $span = $summary.GetLocation().GetLineSpan()
                $first =
                    [int]$span.StartLinePosition.Line + 1
                $last =
                    [int]$span.EndLinePosition.Line + 1
                $changed = @($Spans | Where-Object {
                        $first -le [int]$_.endLine -and
                        $last -ge [int]$_.startLine
                    })
                if ($changed.Count -eq 0) {
                    continue
                }
                if ($first -lt 1 -or
                    $last -gt $lines.Count -or
                    $first -gt $last) {
                    return New-ContextualOutcome `
                        -RuleId xml-summary-layout `
                        -State unknown `
                        -Reason xml-summary-source-span-unavailable `
                        -Path $Path -Line $first `
                        -EndLine $last
                }
                $opening = [string]$lines[$first - 1]
                $closing = [string]$lines[$last - 1]
                $openingStandalone = $opening -match
                    '^\s*///\s*<summary>\s*$'
                $closingStandalone = $closing -match
                    '^\s*///\s*</summary>\s*$'
                $bodyLines = @(
                    if ($last -gt $first + 1) {
                        $lines[$first..($last - 2)]
                    })
                $bodyStandalone =
                    $bodyLines.Count -gt 0 -and
                    @($bodyLines | Where-Object {
                            [string]$_ -cnotmatch
                                '^\s*///(?:\s|$)'
                        }).Count -eq 0
                if ($openingStandalone -and
                    $closingStandalone -and
                    $bodyStandalone) {
                    continue
                }
                $anchors = @(
                    foreach ($change in $changed) {
                        [Math]::Max(
                            $first,
                            [int]$change.startLine)
                    })
                $anchor = [int](
                    $anchors |
                        Measure-Object -Minimum).
                    Minimum
                $symbol = if (
                    $declaration.PSObject.Properties[
                        'Identifier']) {
                    [string]$declaration.Identifier.ValueText
                }
                else { 'declaration' }
                return New-ContextualOutcome `
                    -RuleId xml-summary-layout `
                    -State violation `
                    -Reason xml-summary-tags-not-standalone `
                    -Path $Path -Line $anchor `
                    -EndLine $anchor `
                    -Symbol $symbol `
                    -Evidence (
                        'Put summary tags on standalone /// lines ' +
                        'with the body on intervening /// lines.')
            }
        }
    }
    return New-ContextualOutcome `
        -RuleId xml-summary-layout `
        -State compliant `
        -Reason no-changed-nonstandard-summary-layout `
        -Path $Path
}

function Get-ContextualConstantProjectBinding {
    param([Parameter(Mandatory)]$File)
    if ($File -isnot [Collections.IDictionary] -or
        -not $File.Contains('projectContext') -or
        $File.projectContext -isnot
            [Collections.IDictionary] -or
        -not $File.projectContext.Contains('state') -or
        -not $File.projectContext.Contains('path') -or
        -not $File.projectContext.Contains('content') -or
        [string]$File.projectContext.state -cne
            'complete' -or
        [string]::IsNullOrWhiteSpace(
            [string]$File.projectContext.path) -or
        $File.projectContext.content -isnot [string]) {
        return [pscustomobject]@{
            State = 'unknown'
        }
    }
    $content = [string]$File.projectContext.content
    if ($content -match
        '(?is)<(?:IsTestProject|PackageReference\b[^>]*Include\s*=\s*["'']Microsoft\.NET\.Test\.Sdk["''])') {
        return [pscustomobject]@{
            State = 'test'
        }
    }
    if ($content -match
        '(?is)<(?:LangVersion|Compile|DefineConstants)\b[^>]*Condition\s*=') {
        return [pscustomobject]@{
            State = 'conditional'
        }
    }
    return [pscustomobject]@{
        State = 'complete'
        Path = [string]$File.projectContext.path
        Digest = $(if (
            $File.projectContext.Contains('sourceDigest') -and
            [string]$File.projectContext.sourceDigest -match
                '^v1:sha256:[0-9a-f]{64}$') {
                [string]$File.projectContext.sourceDigest
            }
            else {
                'v1:sha256:' +
                [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData(
                        [Text.Encoding]::UTF8.GetBytes(
                            $content))).ToLowerInvariant()
            })
    }
}

function Get-ContextualDuplicateConstantDeclarations {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    $declarations =
        [Collections.Generic.List[object]]::new()
    $files = [Collections.Generic.List[object]]::new()
    $currentFile = @($SnapshotFiles | Where-Object {
            $_ -is [Collections.IDictionary] -and
            [string]$_.path -ieq $Path
        })
    [void]$files.Add([pscustomobject]@{
            Path = $Path
            Root = $Root
            Current = $true
            Project = $(if ($currentFile.Count -eq 1) {
                    Get-ContextualConstantProjectBinding `
                        -File $currentFile[0]
                } else {
                    [pscustomobject]@{
                        State = 'unknown'
                    }
                })
        })
    foreach ($file in $SnapshotFiles) {
        if ($file -isnot [Collections.IDictionary] -or
            [string]$file.path -ieq $Path -or
            [string]$file.path -inotmatch '\.cs$' -or
            [string]$file.state -cne 'complete' -or
            $file.content -isnot [string]) {
            continue
        }
        if ([string]$file.path -imatch
                '(^|/)(?:obj|generated|Ignore-AddedForReferenceOnly)(/|$)|(?:\.g|\.designer)\.cs$' -or
            [string]$file.content -match
                '(?im)^\s*//\s*<auto-generated(?:\s|>)') {
            continue
        }
        $tree = [
            Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText(
                [string]$file.content)
        if (@($tree.GetDiagnostics() | Where-Object {
                    $_.Severity -eq [
                        Microsoft.CodeAnalysis.DiagnosticSeverity]::Error
                }).Count -gt 0) {
            continue
        }
        [void]$files.Add([pscustomobject]@{
                Path = [string]$file.path
                Root = $tree.GetRoot()
                Current = $false
                Project =
                    Get-ContextualConstantProjectBinding `
                        -File $file
            })
    }
    foreach ($file in $files) {
        foreach ($type in @(
                $file.Root.DescendantNodes() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.ClassDeclarationSyntax]
                    })) {
            $typeModifiers = @($type.Modifiers |
                ForEach-Object {
                    [string]$_.Text
                })
            if ('static' -cnotin $typeModifiers -or
                'internal' -cnotin $typeModifiers) {
                continue
            }
            $namespace = @($type.Ancestors() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.BaseNamespaceDeclarationSyntax]
                } | Select-Object -First 1)
            if ($namespace.Count -ne 1) {
                continue
            }
            $typeDocs =
                [string]$type.GetLeadingTrivia().
                    ToFullString()
            $contractTokens = @(
                [regex]::Matches(
                    $typeDocs,
                    '(?is)<c>\s*(?<token>[^<]{1,256})\s*</c>') |
                    ForEach-Object {
                        $_.Groups['token'].Value.Trim()
                    } | Sort-Object -Unique)
            foreach ($field in @(
                    $type.Members | Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax]
                    })) {
                $modifiers = @($field.Modifiers |
                    ForEach-Object {
                        [string]$_.Text
                    })
                if ('const' -cnotin $modifiers -or
                    'internal' -cnotin $modifiers -or
                    $field.Declaration.Type -isnot [
                        Microsoft.CodeAnalysis.CSharp.Syntax.PredefinedTypeSyntax] -or
                    [string]$field.Declaration.Type.Keyword.Text -cne
                        'string') {
                    continue
                }
                foreach ($variable in @(
                        $field.Declaration.Variables)) {
                    if ($null -eq $variable.Initializer -or
                        $variable.Initializer.Value -isnot [
                            Microsoft.CodeAnalysis.CSharp.Syntax.LiteralExpressionSyntax] -or
                        [string]$variable.Initializer.Value.Token.ValueText -ceq
                            '') {
                        continue
                    }
                    [void]$declarations.Add(
                        [pscustomobject]@{
                            Path = [string]$file.Path
                            Current =
                                [bool]$file.Current
                            Project = $file.Project
                            Namespace =
                                [string]$namespace[0].
                                    Name.ToString()
                            TypeName =
                                [string]$type.Identifier.ValueText
                            Name =
                                [string]$variable.Identifier.ValueText
                            ConstantType =
                                'System.String'
                            Value =
                                [string]$variable.Initializer.Value.
                                    Token.ValueText
                            Line =
                                Get-ContextualNodeLine `
                                    $variable
                            ContractTokens =
                                $contractTokens
                        })
                }
            }
        }
    }
    return $declarations.ToArray()
}

function Get-ContextualDuplicateConstantOutcome {
    param(
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Spans,
        [Parameter(Mandatory)][object[]]$SnapshotFiles
    )
    if ($Path -imatch
            '(^|/)(?:obj|generated|Ignore-AddedForReferenceOnly)(/|$)|(?:\.g|\.designer)\.cs$' -or
        $Content -match
            '(?im)^\s*//\s*<auto-generated(?:\s|>)') {
        return New-ContextualOutcome `
            -RuleId duplicate-constant-declarations `
            -State compliant `
            -Reason generated-code-excluded `
            -Path $Path
    }
    $declarations =
        @(Get-ContextualDuplicateConstantDeclarations `
            -Root $Root -Path $Path `
            -SnapshotFiles $SnapshotFiles)
    $changed = @($declarations |
        Where-Object {
            [bool]$_.Current -and
            (Test-ContextualChangedLine `
                -Line ([int]$_.Line) `
                -Spans $Spans)
        })
    if ($changed.Count -eq 0) {
        return New-ContextualOutcome `
            -RuleId duplicate-constant-declarations `
            -State compliant `
            -Reason no-changed-eligible-constant `
            -Path $Path
    }
    $violations =
        [Collections.Generic.List[object]]::new()
    $unknowns =
        [Collections.Generic.List[object]]::new()
    foreach ($candidate in $changed) {
        foreach ($comparison in @(
                $declarations | Where-Object {
                    -not [bool]$_.Current -and
                    [string]$_.Name -ceq
                        [string]$candidate.Name -and
                    [string]$_.ConstantType -ceq
                        [string]$candidate.ConstantType -and
                    [string]$_.Value -ceq
                        [string]$candidate.Value
                })) {
            $projectProven =
                [string]$candidate.Project.State -ceq
                    'complete' -and
                [string]$comparison.Project.State -ceq
                    'complete' -and
                [string]$candidate.Project.Path -ieq
                    [string]$comparison.Project.Path -and
                [string]$candidate.Project.Digest -ceq
                    [string]$comparison.Project.Digest
            $sameNamespace =
                [string]$candidate.Namespace -ceq
                    [string]$comparison.Namespace
            $sharedContract = @(
                $candidate.ContractTokens |
                    Where-Object {
                        [string]$_ -cin
                            @($comparison.ContractTokens)
                    })
            if ($projectProven -and
                $sameNamespace -and
                $sharedContract.Count -gt 0) {
                [void]$violations.Add([pscustomobject]@{
                        Candidate = $candidate
                        Comparison = $comparison
                        Contract =
                            [string]$sharedContract[0]
                    })
            }
            else {
                [void]$unknowns.Add([pscustomobject]@{
                        Candidate = $candidate
                        Comparison = $comparison
                    })
            }
        }
    }
    if ($violations.Count -gt 0) {
        $ordered = @($violations | Sort-Object {
                [int]$_.Candidate.Line
            })
        $first = $ordered[0]
        $lastLine = [int](
            $ordered.Candidate.Line |
                Measure-Object -Maximum).Maximum
        $names = @($ordered.Candidate.Name |
            Sort-Object -Unique)
        return New-ContextualOutcome `
            -RuleId duplicate-constant-declarations `
            -State violation `
            -Reason duplicate-shared-contract-constants `
            -Path $Path `
            -Line ([int]$first.Candidate.Line) `
            -EndLine $lastLine `
            -Symbol ([string]$first.Candidate.TypeName) `
            -Evidence (
                'Consolidate duplicated constants ' +
                ($names -join ', ') +
                ' for shared contract ' +
                [string]$first.Contract + '.')
    }
    if ($unknowns.Count -gt 0) {
        $first = @($unknowns | Sort-Object {
                [int]$_.Candidate.Line
            })[0]
        return New-ContextualOutcome `
            -RuleId duplicate-constant-declarations `
            -State unknown `
            -Reason duplicate-constant-relation-unproven `
            -Path $Path `
            -Line ([int]$first.Candidate.Line) `
            -EndLine ([int]$first.Candidate.Line) `
            -Symbol ([string]$first.Candidate.TypeName)
    }
    return New-ContextualOutcome `
        -RuleId duplicate-constant-declarations `
        -State compliant `
        -Reason no-matching-constant-declaration `
        -Path $Path
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
    $xmlSummaryOutcome =
        Get-ContextualXmlSummaryLayoutOutcome `
            -Root $root -Content $Content `
            -Path $Path -Spans $Spans
    $results['xml-summary-layout'] =
        $xmlSummaryOutcome
    if ([string]$xmlSummaryOutcome.state -ceq
        'violation') {
        [void]$contextualCandidateOutcomes.Add(
            $xmlSummaryOutcome)
    }
    $duplicateConstantOutcome =
        Get-ContextualDuplicateConstantOutcome `
            -Root $root -Content $Content `
            -Path $Path -Spans $Spans `
            -SnapshotFiles $SnapshotFiles
    $results['duplicate-constant-declarations'] =
        $duplicateConstantOutcome
    if ([string]$duplicateConstantOutcome.state -ceq
        'violation') {
        [void]$contextualCandidateOutcomes.Add(
            $duplicateConstantOutcome)
    }
    $nodes = @($root.DescendantNodes())
    $methods = @($nodes | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax]
        })
    $catches = @($nodes | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.CatchClauseSyntax]
        })
    $namedCallLanguage =
        Get-ContextualNamedCallLanguageState `
            -Path $Path `
            -SnapshotFiles $SnapshotFiles
    $namedCallSignatures =
        @(Get-ContextualNamedCallSignatures `
            -Root $root -Path $Path `
            -SnapshotFiles $SnapshotFiles)
    $namedCallConstants =
        @(Get-ContextualNamedCallConstants `
            -Root $root -Path $Path `
            -SnapshotFiles $SnapshotFiles)
    $callNodes = @(
        $nodes | Where-Object {
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax] -or
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.ObjectCreationExpressionSyntax] -or
            $_ -is [
                Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorInitializerSyntax]
        })
    foreach ($call in $callNodes) {
        $outcome = Get-ContextualNamedCallOutcome `
            -Node $call -Root $root `
            -Path $Path -Spans $Spans `
            -Signatures $namedCallSignatures `
            -Language $namedCallLanguage `
            -Constants $namedCallConstants
        if ($null -eq $outcome) {
            continue
        }
        if ([string]$outcome.state -ceq 'violation') {
            [void]$contextualCandidateOutcomes.Add(
                $outcome)
            $results['named-call-arguments'] =
                $outcome
        }
        elseif ([string]$results[
                'named-call-arguments'].state -ceq
                'compliant') {
            $results['named-call-arguments'] =
                $outcome
        }
    }

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
            if (-not $predicateSelection -and
                (Test-ContextualEquivalentGroupRepresentativeSelection `
                    -Invocation $first -Method $method)) {
                if (Test-ContextualNodeChanged -Node $first -Spans $Spans) {
                    $results['collection-cardinality'] =
                        New-ContextualOutcome `
                            -RuleId collection-cardinality `
                            -State compliant `
                            -Reason equivalent-group-representative-dedup `
                            -Path $Path `
                            -Line (Get-ContextualNodeLine $first) `
                            -EndLine (Get-ContextualNodeLine $first) `
                            -Symbol ([string]$method.Identifier.ValueText)
                }
                continue
            }
            if (-not $predicateSelection -and
                (Test-ContextualGroupRepresentativeSelection `
                    -Invocation $first)) {
                if (Test-ContextualNodeChanged -Node $first -Spans $Spans) {
                    $results['collection-cardinality'] =
                        New-ContextualOutcome `
                            -RuleId collection-cardinality `
                            -State unknown `
                            -Reason group-representative-equivalence-unproven `
                            -Path $Path `
                            -Line (Get-ContextualNodeLine $first) `
                            -EndLine (Get-ContextualNodeLine $first) `
                            -Symbol ([string]$method.Identifier.ValueText)
                }
                continue
            }
            $orderedSelection = $receiver -match
                '\.(?:OrderBy|OrderByDescending|ThenBy|ThenByDescending)\s*\(' -or
                $receiver -match '\.Split\s*\(' -or
                $receiver -match '\.Statements$'
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
                if (Test-ContextualSynchronousAssertionCallback `
                    -Invocation $invocation -Method $method) {
                    if (Test-ContextualNodeChanged `
                        -Node $invocation -Spans $Spans) {
                        $results['async-io'] =
                            New-ContextualOutcome `
                                -RuleId async-io -State unknown `
                                -Reason assertion-callback-io-context-unproven `
                                -Path $Path `
                                -Line (Get-ContextualNodeLine $invocation) `
                                -EndLine (Get-ContextualNodeLine $invocation) `
                                -Symbol (
                                    [string]$method.Identifier.ValueText)
                    }
                    continue
                }
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
    $getHttpUsingContext = {
        param([Parameter(Mandatory)]$Node)
        $applicable = [Collections.Generic.List[object]]::new()
        foreach ($using in @($root.Usings)) {
            [void]$applicable.Add($using)
        }
        foreach ($namespace in @($Node.Ancestors() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.BaseNamespaceDeclarationSyntax]
                })) {
            foreach ($using in @($namespace.Usings)) {
                [void]$applicable.Add($using)
            }
        }
        $aliases = @{}
        foreach ($using in @($applicable |
                Where-Object {
                    $null -ne $_.Alias
                })) {
            $aliases[
                [string]$using.Alias.Name.Identifier.ValueText
            ] = ([string]$using.Name.ToString()) -replace
                '^global::', ''
        }
        return [ordered]@{
            usingSystemHttp = @($applicable |
                Where-Object {
                    $null -eq $_.Alias -and
                    (([string]$_.Name.ToString()) -replace
                        '^global::', '') -ceq
                        'System.Net.Http'
                }).Count -gt 0
            aliases = $aliases
        }
    }.GetNewClosure()
    $resolveHttpClientType = {
        param(
            [Parameter(Mandatory)][string]$TypeText,
            [Parameter(Mandatory)]$Node
        )
        $normalized = $TypeText -replace '^global::', ''
        $usingContext =
            & $getHttpUsingContext $Node
        if ($normalized -ceq
            'System.Net.Http.HttpClient') {
            return 'system'
        }
        if ($usingContext.aliases.ContainsKey(
                $normalized)) {
            return $(if (
                [string]$usingContext.aliases[
                    $normalized] -ceq
                    'System.Net.Http.HttpClient'
            ) {
                'system'
            }
            else { 'unknown' })
        }
        if ($normalized -ceq 'HttpClient') {
            if ($localHttpClient) {
                return 'shadowed'
            }
            if ([bool]$usingContext.usingSystemHttp) {
                return 'system'
            }
            return 'unknown'
        }
        if ($normalized -match
            '(?:^|\.)HttpClient$') {
            return 'unknown'
        }
        return 'not-http-client'
    }.GetNewClosure()
    $getCreationType = {
        param([Parameter(Mandatory)]$Creation)
        if ($Creation -is [
            Microsoft.CodeAnalysis.CSharp.Syntax.ObjectCreationExpressionSyntax]) {
            return [string]$Creation.Type.ToString()
        }
        $declaration = @($Creation.Ancestors() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.VariableDeclarationSyntax]
            } | Select-Object -First 1)
        if ($declaration.Count -eq 1) {
            return [string]$declaration[0].Type.ToString()
        }
        return ''
    }.GetNewClosure()
    foreach ($creation in @($nodes | Where-Object {
                ($_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.ObjectCreationExpressionSyntax] -or
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.ImplicitObjectCreationExpressionSyntax]) -and
                (Test-ContextualNodeChanged `
                    -Node $_ -Spans $Spans)
            })) {
        $fullType =
            & $getCreationType $creation
        if ([string]::IsNullOrWhiteSpace(
                $fullType)) {
            continue
        }
        $httpMethod = @($creation.Ancestors() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax]
            } | Select-Object -First 1)
        $httpConstructor = @($creation.Ancestors() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax]
            } | Select-Object -First 1)
        $httpSymbol = if ($httpMethod.Count -eq 1) {
            [string]$httpMethod[0].Identifier.ValueText
        }
        elseif ($httpConstructor.Count -eq 1) {
            [string]$httpConstructor[0].Identifier.ValueText
        }
        else { 'file' }
        $typeState =
            & $resolveHttpClientType $fullType $creation
        if ($typeState -ceq
            'not-http-client') {
            continue
        }
        if ($typeState -ceq 'shadowed') {
            $results['http-client-lifetime'] =
                New-ContextualOutcome `
                    -RuleId http-client-lifetime `
                    -State unknown `
                    -Reason http-client-type-shadowed `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $creation) `
                    -EndLine (Get-ContextualNodeLine $creation) `
                    -Symbol $httpSymbol
            continue
        }
        if ($typeState -cne 'system') {
            $results['http-client-lifetime'] =
                New-ContextualOutcome `
                    -RuleId http-client-lifetime `
                    -State unknown `
                    -Reason http-client-type-unproven `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $creation) `
                    -EndLine (Get-ContextualNodeLine $creation) `
                    -Symbol $httpSymbol
            continue
        }
        $field = @($creation.Ancestors() |
            Where-Object {
                $_ -is [
                    Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax]
            } | Select-Object -First 1)
        $constructor = $httpConstructor
        $customHandler =
            $creation.ArgumentList.Arguments.Count -gt 0
        $sharedField = $field.Count -eq 1 -and
            [string]$field[0].Modifiers.ToString() -match
                '\bstatic\b' -and
            [string]$field[0].Modifiers.ToString() -match
                '\breadonly\b' -and
            (& $resolveHttpClientType (
                [string]$field[0].Declaration.Type.ToString()
            ) $field[0]) -ceq 'system'
        $staticConstructorAssignment = $false
        if ($constructor.Count -eq 1 -and
            [string]$constructor[0].Modifiers.ToString() -match
                '\bstatic\b') {
            $containingType = @(
                $constructor[0].Ancestors() |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax]
                    } |
                    Select-Object -First 1)
            $sameTypeStaticReadonlyClients = if (
                $containingType.Count -eq 1
            ) {
                @($containingType[0].Members |
                    Where-Object {
                        $_ -is [
                            Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax] -and
                        [string]$_.Modifiers.ToString() -match
                            '\bstatic\b' -and
                        [string]$_.Modifiers.ToString() -match
                            '\breadonly\b' -and
                        (& $resolveHttpClientType (
                            [string]$_.Declaration.Type.ToString()
                        ) $_) -ceq 'system'
                    } | ForEach-Object {
                        $_.Declaration.Variables |
                            ForEach-Object {
                                [string]$_.Identifier.ValueText
                            }
                    })
            }
            else { @() }
            $assignment = @($creation.Ancestors() |
                Where-Object {
                    $_ -is [
                        Microsoft.CodeAnalysis.CSharp.Syntax.AssignmentExpressionSyntax]
                } | Select-Object -First 1)
            if ($assignment.Count -eq 1) {
                $target = ([string]$assignment[0].Left.ToString()).
                    Split('.')[-1]
                $staticConstructorAssignment =
                    $target -cin
                        $sameTypeStaticReadonlyClients
            }
        }
        if ($sharedField -or
            $staticConstructorAssignment) {
            $results['http-client-lifetime'] =
                New-ContextualOutcome `
                    -RuleId http-client-lifetime `
                    -State compliant `
                    -Reason shared-http-client-singleton `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $creation) `
                    -EndLine (Get-ContextualNodeLine $creation) `
                    -Symbol $httpSymbol
            continue
        }
        if ($customHandler) {
            $results['http-client-lifetime'] =
                New-ContextualOutcome `
                    -RuleId http-client-lifetime `
                    -State unknown `
                    -Reason custom-handler-lifetime-unproven `
                    -Path $Path `
                    -Line (Get-ContextualNodeLine $creation) `
                    -EndLine (Get-ContextualNodeLine $creation) `
                    -Symbol $httpSymbol
            continue
        }
        $results['http-client-lifetime'] =
            New-ContextualOutcome `
                -RuleId http-client-lifetime `
                -State violation `
                -Reason request-path-http-client-construction `
                -Path $Path `
                -Line (Get-ContextualNodeLine $creation) `
                -EndLine (Get-ContextualNodeLine $creation) `
                -Symbol $httpSymbol `
                -Evidence (
                    'Reuse System.Net.Http.HttpClient or use IHttpClientFactory.')
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
            $results[$rule] = if ($rule -cin @(
                    'http-client-lifetime',
                    'named-call-arguments')) {
                @($changedCandidates |
                    Sort-Object {
                        [int]$_.line
                    })[0]
            }
            else {
                $changedCandidates[-1]
            }
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
