#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1"
Import-Module "$PSScriptRoot\..\OwnerObservationContract\OwnerObservationContract.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psd1" -Force
Import-Module "$PSScriptRoot\..\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1" -Force

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
$script:OwnerV1WriterCapability = 'bpm-test-ownership@1'
$script:OwnerV1WriterVersion = 1
$script:OwnerV1WriterRuleRef = 'rs0'
$script:OwnerV1WriterMarkerPrefix = 'devpilot-owner-comment:v1'
$script:NamedAreEqualCapability = 'bpm-named-areequal-arguments@1'
$script:NamedAreEqualDigest = 'v1:sha256:7ed3583591b43dbb351292ea9a37a53fc32fc9f0fd3403c821e3209310598e3a'
$script:NamedAreEqualMarkerPrefix = 'devpilot-named-areequal:v1'
$script:NamedAreEqualPolicyDigest = 'v1:sha256:8b9fa35bd2bc96e9f0dbfc878806b540603ab4f255ddf41bf120311913b831f4'
$script:ContextualCapability = 'bpm-contextual-conventions@1'
$script:ContextualDigest = 'v1:sha256:9c3496bd7a22a5f4cf09fa993e1aaad7f386efd7010e73a5cedf6bbd19de9130'
$script:ContextualMarkerPrefix = 'devpilot-contextual-convention:v1'
$script:ContextualPolicyDigest = 'v1:sha256:275a62e22d849913ea0da332fdb07dfb6ebed155231236c7704b94f4fb031938'
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

function Get-OwnerV1WriterSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                [Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant()
}

function ConvertTo-OwnerV1WriterPath {
    param([Parameter(Mandatory)][string]$Path)

    $normalized = ConvertTo-OwnerRepositoryPath -Path $Path
    if ($normalized.Length -gt 1023 -or $normalized -match '[|`<>]') {
        throw 'Owner finding path is not compatible with the approved v1 writer path contract.'
    }
    return '/' + $normalized
}

function ConvertTo-OwnerV1WriterMarkdownCode {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return (($Text -replace '[\x00-\x1f\x7f]', ' ') -replace '`', '｀').Trim()
}

function ConvertTo-OwnerCommentLink {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url
    )
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.UserInfo -or
        $Url -match '[\x00-\x20\x7f<>]' -or
        [string]::IsNullOrWhiteSpace($Name) -or
        $Name.Length -gt 1024 -or $Name -match '[\x00-\x1f\x7f]') {
        throw 'Comment references require a bounded label and an absolute HTTPS URL.'
    }
    $label = $Name -replace '([\\`*_\[\]<>])', '\$1'
    $target = $uri.AbsoluteUri.Replace('(', '%28').Replace(')', '%29').
        Replace('[', '%5B').Replace(']', '%5D')
    return "[$label]($target)"
}

function Get-OwnerCommentRepositoryUrl {
    param([Parameter(Mandatory)][object]$Contract)
    $presentation = Get-OwnerV2Member -Value $Contract -Name CommentPresentation
    $provider = Get-OwnerV2Member -Value $presentation -Name subjectProvider
    if ($null -eq $provider) { return $null }
    if ([string](Get-OwnerV2Member -Value $provider -Name repositoryId) -cne
            [string]$Contract.Request.RepositoryId -or
        [string](Get-OwnerV2Member -Value $provider -Name projectId) -cne
            [string]$Contract.Request.ProjectId) {
        throw 'Comment source links must use the bound subject repository and project.'
    }
    $organization = [string](Get-OwnerV2Member -Value $provider -Name organization)
    $uri = $null
    if (-not [uri]::TryCreate($organization, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or
        $uri.Fragment -or $organization -match '[\x00-\x20\x7f<>]') {
        throw 'Comment source links require the configured HTTPS organization URL.'
    }
    return $uri.AbsoluteUri.TrimEnd('/') + '/' +
        [uri]::EscapeDataString([string]$Contract.Request.ProjectId) +
        '/_git/' + [uri]::EscapeDataString([string]$Contract.Request.RepositoryId)
}

function Assert-OwnerCommentReferenceKeys {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string[]]$Keys
    )
    if ($Value -isnot [Collections.IDictionary] -or
        $Value.Count -ne $Keys.Count -or
        @($Value.Keys | Where-Object { $_ -cnotin $Keys }).Count -gt 0) {
        throw [ArgumentException]::new('Comment citation metadata has unknown or missing schema keys.')
    }
}

function Assert-OwnerCommentRuleReferences {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$References,
        [AllowNull()][object]$Repository,
        [Parameter(Mandatory)]
        [ValidateSet('owner', 'named-areequal', 'contextual-conventions')]
        [string]$Delivery
    )
    if ($null -eq $References) { return }
    $allowed = @(switch ($Delivery) {
        owner { @('owner') }
        named-areequal { @('named-areequal') }
        contextual-conventions { @(Get-ContextualConventionRuleIds) }
    })
    if ($References -isnot [Collections.IDictionary] -or
        $References.Count -gt $allowed.Count -or
        @($References.Keys | Where-Object { $_ -cnotin $allowed }).Count -gt 0) {
        throw [ArgumentException]::new('Comment citations must be keyed by existing delivery rule IDs.')
    }
    if ($References.Count -eq 0) { return }
    Assert-OwnerCommentReferenceKeys -Value $Repository `
        -Keys @('organization', 'projectName', 'repositoryName')
    $organization = $Repository.organization
    if ($organization -isnot [string] -or
        $organization -cnotmatch '^https://(?:dev\.azure\.com/[A-Za-z0-9][A-Za-z0-9-]*|[A-Za-z0-9][A-Za-z0-9-]*\.visualstudio\.com(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)?)/?$') {
        throw [ArgumentException]::new('Comment citations require an explicitly configured Azure DevOps organization.')
    }
    foreach ($name in @('projectName', 'repositoryName')) {
        $value = $Repository[$name]
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or
            $value -cne $value.Trim() -or $value.Length -gt 256 -or
            $value -match '[\\/?#%\x00-\x1f\x7f]' -or $value -cin @('.', '..')) {
            throw [ArgumentException]::new('Comment citation repository and project names must be canonical single segments.')
        }
    }
    $expectedBase = $organization.TrimEnd('/') + '/' +
        [uri]::EscapeDataString($Repository.projectName) + '/_git/' +
        [uri]::EscapeDataString($Repository.repositoryName)
    foreach ($reference in $References.Values) {
        Assert-OwnerCommentReferenceKeys -Value $reference -Keys @('label', 'links')
        if ($reference.label -isnot [string] -or
            $reference.label -cnotin @('EngHub rules', 'Rule references') -or
            $reference.links -isnot [array] -or
            $reference.links.Count -lt 1 -or $reference.links.Count -gt 8) {
            throw [ArgumentException]::new('Comment citations require a supported label and one to eight links.')
        }
        foreach ($link in $reference.links) {
            Assert-OwnerCommentReferenceKeys -Value $link -Keys @('name', 'url')
            $url = $link.url
            $uri = $null
            if ($link.name -isnot [string] -or [string]::IsNullOrWhiteSpace($link.name) -or
                $link.name.Length -gt 1024 -or $link.name -match '[\x00-\x1f\x7f]' -or
                $url -isnot [string] -or $url.Length -gt 8192 -or
                $url -match '[\\\x00-\x20\x7f<>]' -or
                $url -match '%(?![0-9a-fA-F]{2})' -or
                -not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -cne 'https' -or $uri.Fragment -or $uri.UserInfo -or
                -not $url.StartsWith($expectedBase + '?', [StringComparison]::Ordinal)) {
                throw [ArgumentException]::new('Comment citation links must use the exact configured Azure DevOps repository and no fragment or user information.')
            }
            $query = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $parts = $uri.Query.TrimStart('?').Split('&')
            if ($parts.Count -ne 3) {
                throw [ArgumentException]::new('Comment citation queries require exactly one version, path, and line.')
            }
            foreach ($part in $parts) {
                $pair = $part.Split('=', 2)
                if ($pair.Count -ne 2 -or $pair[0] -cnotin @('version', 'path', 'line') -or
                    $query.ContainsKey($pair[0])) {
                    throw [ArgumentException]::new('Comment citation queries contain duplicate or unexpected keys.')
                }
                $query.Add($pair[0], [uri]::UnescapeDataString($pair[1]))
            }
            $line = 0
            $path = $query['path']
            if ($query['version'] -cnotmatch '^GC[0-9a-f]{40}$' -or
                $query['line'] -cnotmatch '^[1-9][0-9]*$' -or
                -not [int]::TryParse($query['line'], [ref]$line) -or
                $path.Length -gt 1024 -or -not $path.StartsWith('/') -or
                $path -match '[\\%?#`<>|\x00-\x1f\x7f]' -or
                @($path.Substring(1).Split('/') | Where-Object { $_ -cin @('', '.', '..') }).Count -gt 0) {
                throw [ArgumentException]::new('Comment citation links require an exact source commit, canonical rooted path, and positive line.')
            }
        }
    }
}

function Format-OwnerCommentRuleReference {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$Name
    )
    $presentation = Get-OwnerV2Member -Value $Contract -Name CommentPresentation
    $references = Get-OwnerV2Member -Value $presentation -Name ruleReferences
    $repository = Get-OwnerV2Member -Value $presentation -Name ruleRepository
    $delivery = if ($RuleId -cin @('owner', 'named-areequal')) { $RuleId } else { 'contextual-conventions' }
    try {
        Assert-OwnerCommentRuleReferences -References $references -Repository $repository -Delivery $delivery
    }
    catch [ArgumentException] {
        Write-Warning 'Invalid comment citations were omitted; use the readable rule name and correct the citation configuration.'
        return "**Rule:** $Name."
    }
    $reference = Get-OwnerV2Member -Value $references -Name $RuleId
    if ($null -eq $reference) { return "**Rule:** $Name." }
    $label = $reference.label
    $rendered = foreach ($link in $reference.links) {
        ConvertTo-OwnerCommentLink -Name $link.name -Url $link.url
    }
    return "**${label}:** " + ($rendered -join '; ') + '.'
}

function Format-OwnerCommentOccurrences {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int[]]$Lines,
        [ValidateSet('Changed-line occurrences', 'File-header location', 'Related source occurrences')]
        [string]$Label = 'Changed-line occurrences'
    )
    $path = ConvertTo-OwnerV1WriterPath -Path $Path
    $repositoryUrl = Get-OwnerCommentRepositoryUrl -Contract $Contract
    $locations = foreach ($line in $Lines) {
        if ($line -lt 1 -or $line -gt 200000) {
            throw 'Comment occurrences require exact positive source lines.'
        }
        if ($repositoryUrl) {
            $url = $repositoryUrl + '?version=GC' +
                [string]$Contract.Request.SourceCommit +
                '&path=' + [uri]::EscapeDataString($path) + "&line=$line"
            ConvertTo-OwnerCommentLink -Name "$($path.TrimStart('/')):$line" -Url $url
        }
        else {
            "``$(ConvertTo-OwnerV1WriterMarkdownCode $path):$line``"
        }
    }
    return @("**${Label}:**") +
        @($locations | ForEach-Object { "- $_" }) -join "`n"
}

function Get-OwnerV1WriterMarkerKey {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][Collections.IDictionary]$Finding
    )

    $request = $Contract.Request
    $anchor = Get-OwnerV2Member -Value $Finding -Name anchor
    if ($anchor -isnot [Collections.IDictionary]) {
        throw 'Owner finding has no canonical writer anchor.'
    }
    $path = ConvertTo-OwnerV1WriterPath -Path (
        [string](Get-OwnerV2Member -Value $anchor -Name path)
    )
    $line = [int](Get-OwnerV2Member -Value $anchor -Name line)
    $symbol = [string](Get-OwnerV2Member -Value $anchor -Name symbol)
    if ($line -lt 1 -or [string]::IsNullOrWhiteSpace($symbol)) {
        throw 'Owner finding has an incomplete canonical writer anchor.'
    }
    $rulePath = ConvertTo-OwnerV1WriterPath -Path $request.RulePath
    $ruleIdentity = @(
        [string]$request.RuleRepositoryId,
        $rulePath,
        [string]$request.RuleSection,
        [string]$request.RuleCommit,
        ([string]$request.RuleHash).Substring(10),
        $script:OwnerV1WriterRuleRef
    ) -join '|'
    $material = @(
        $script:OwnerV1WriterCapability
        [string]$script:OwnerV1WriterVersion
        ([string]$request.RepositoryId).ToLowerInvariant()
        [string][long]$request.PullRequestId
        ([string]$request.SourceCommit).ToLowerInvariant()
        $ruleIdentity.ToLowerInvariant()
        $path.ToLowerInvariant()
        [string]$line
        $symbol
    ) -join "`n"
    return Get-OwnerV1WriterSha256 -Text $material
}

function Format-OwnerV1WriterComment {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][Collections.IDictionary]$Finding,
        [Parameter(Mandatory)][string]$MarkerKey,
        [switch]$Legacy
    )

    $request = $Contract.Request
    $anchor = Get-OwnerV2Member -Value $Finding -Name anchor
    $path = ConvertTo-OwnerV1WriterMarkdownCode (
        ConvertTo-OwnerV1WriterPath -Path (
            [string](Get-OwnerV2Member -Value $anchor -Name path)
        )
    )
    $symbol = ConvertTo-OwnerV1WriterMarkdownCode (
        [string](Get-OwnerV2Member -Value $anchor -Name symbol)
    )
    $rulePath = ConvertTo-OwnerV1WriterMarkdownCode (
        ConvertTo-OwnerV1WriterPath -Path $request.RulePath
    )
    $section = ConvertTo-OwnerV1WriterMarkdownCode ([string]$request.RuleSection)
    if (-not $Legacy) {
        return @(
            '**Add an Owner attribute to this changed test method**'
            ''
            (Format-OwnerCommentRuleReference -Contract $Contract `
                -RuleId owner -Name 'Changed MSTest methods require an Owner attribute')
            ''
            "Changed MSTest method ``$symbol`` has no ``Owner`` attribute. Add ``[Owner(`"<owner-alias>`")]`` to this test method."
            ''
            (Format-OwnerCommentOccurrences -Contract $Contract -Path $path `
                -Lines @([int](Get-OwnerV2Member -Value $anchor -Name line)))
            ''
            "<!-- ${script:OwnerV1WriterMarkerPrefix}:$MarkerKey -->"
        ) -join "`n"
    }
    return @(
        '**Owner attribute missing**'
        ''
        "Method ``$symbol`` at ``$path`:$([int](Get-OwnerV2Member -Value $anchor -Name line))`` is a changed MSTest method and has no ``Owner`` attribute."
        ''
        'Suggested fix: add `[Owner("<owner-alias>")]` to this test method.'
        ''
        "Rule: ``$rulePath`` / ``$section`` at ``$([string]$request.RuleCommit)`` (SHA-256 ``$(([string]$request.RuleHash).Substring(10))``)."
        ''
        "<!-- ${script:OwnerV1WriterMarkerPrefix}:$MarkerKey -->"
    ) -join "`n"
}

function Get-NamedAreEqualMarkerKey {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][Collections.IDictionary]$Finding
    )

    $request = $Contract.Request
    if ([string]$request.CapabilityId -cne $script:NamedAreEqualCapability -or
        [string]$request.RuleSection -cne $script:NamedAreEqualCapability) {
        throw 'Named AreEqual arguments require their independently bound rule.'
    }
    $anchor = $Finding.anchor
    $source = $Finding.binding.source.representation
    $lines = @($Finding.affectedCallLines)
    if ($anchor -isnot [Collections.IDictionary] -or
        $source -isnot [Collections.IDictionary] -or
        [string]$Finding.disposition -cne 'violation' -or
        [string]$Finding.constructRef -cnotmatch '^construct:[0-9a-f]{64}$' -or
        [string]$source.constructIdentity -cne [string]$Finding.constructRef -or
        [string]$source.path -cne [string]$anchor.path -or
        [string]$source.symbol -cne [string]$anchor.symbol -or
        [int]$source.startLine -ne [int]$anchor.line -or
        [int]$source.endLine -ne [int]$anchor.line -or
        [int]$anchor.line -lt 1 -or
        ([string]$anchor.symbol).Length -gt 256 -or
        [string]$anchor.symbol -cnotmatch
            '^[\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}_][\p{L}\p{N}_]*)*$' -or
        [int]$Finding.affectedCallCount -lt 1 -or
        [int]$Finding.affectedCallCount -gt 256 -or
        $lines.Count -ne [int]$Finding.affectedCallCount -or
        $Finding.callListTruncated -isnot [bool] -or
        [bool]$Finding.callListTruncated -ne
            ([int]$Finding.affectedCallCount -gt 12) -or
        [int]$lines[0] -ne [int]$anchor.line) {
        throw 'Named AreEqual finding has no bounded changed method and call anchors.'
    }
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ([int]$lines[$index] -le [int]$lines[$index - 1] -or
            [int]$lines[$index] -gt 200000) {
            throw 'Named AreEqual call anchors are not strictly ordered.'
        }
    }
    $material = @(
        $script:NamedAreEqualMarkerPrefix
        [string]$request.RepositoryId
        [string]$request.PullRequestId
        [string]$request.SourceCommit
        [string]$request.RuleRepositoryId
        (ConvertTo-OwnerV1WriterPath -Path $request.RulePath)
        [string]$request.RuleSection
        [string]$request.RuleCommit
        [string]$request.RuleHash
        (ConvertTo-OwnerV1WriterPath -Path ([string]$anchor.path))
        [string]$anchor.line
        [string]$anchor.symbol
    ) -join "`n"
    return Get-OwnerV1WriterSha256 -Text $material
}

function Format-NamedAreEqualComment {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][Collections.IDictionary]$Finding,
        [Parameter(Mandatory)][string]$MarkerKey,
        [switch]$Legacy
    )

    if ($MarkerKey -cne (Get-NamedAreEqualMarkerKey `
            -Contract $Contract -Finding $Finding)) {
        throw 'Named AreEqual marker does not match the bound method finding.'
    }
    $request = $Contract.Request
    $path = ConvertTo-OwnerV1WriterMarkdownCode (
        ConvertTo-OwnerV1WriterPath -Path ([string]$Finding.anchor.path))
    $symbol = ConvertTo-OwnerV1WriterMarkdownCode ([string]$Finding.anchor.symbol)
    $count = [int]$Finding.affectedCallCount
    $sample = @($Finding.affectedCallLines | Select-Object -First 12)
    $lineSummary = $sample -join ', '
    if ($count -gt $sample.Count) {
        $lineSummary += " (first 12 of $count)"
    }
    $rulePath = ConvertTo-OwnerV1WriterMarkdownCode (
        ConvertTo-OwnerV1WriterPath -Path $request.RulePath)
    if (-not $Legacy) {
        return @(
            '**Use named arguments for Assert.AreEqual in this test method**'
            ''
            (Format-OwnerCommentRuleReference -Contract $Contract `
                -RuleId named-areequal -Name 'Name every supplied Assert.AreEqual argument')
            ''
            "Method ``$symbol`` contains $count changed positional ``Assert.AreEqual`` call(s). Name every supplied argument according to the selected overload, commonly ``expected:`` and ``actual:`` (and ``delta:`` or ``message:`` when supplied). Preserve argument order and values."
            ''
            (Format-OwnerCommentOccurrences -Contract $Contract -Path $path -Lines $sample)
            $(if ($count -gt $sample.Count) {
                "Showing the first 12 of $count changed calls."
            })
            ''
            "<!-- ${script:NamedAreEqualMarkerPrefix}:$MarkerKey -->"
        ) | Where-Object { $null -ne $_ } | Join-String -Separator "`n"
    }
    return @(
        '**Use named arguments for Assert.AreEqual in this test method**'
        ''
        "Method ``$symbol`` contains $count changed positional ``Assert.AreEqual`` call(s) at ``$path`` (lines $lineSummary). This comment is anchored at the first changed call, line $([int]$Finding.anchor.line)."
        ''
        'Name every supplied argument according to the selected overload. For MSTest, this commonly includes `expected:` and `actual:` (and further supplied arguments such as `delta:` or `message:`). Preserve the existing argument order and values.'
        ''
        "Convention: ``$rulePath`` / ``$([string]$request.RuleSection)`` at ``$([string]$request.RuleCommit)`` (SHA-256 ``$(([string]$request.RuleHash).Substring(10))``)."
        ''
        "<!-- ${script:NamedAreEqualMarkerPrefix}:$MarkerKey -->"
    ) -join "`n"
}

function Get-ContextualConventionMarkerKey {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Finding
    )
    $request = $Contract.Request
    if ([string]$request.CapabilityId -cne
            $script:ContextualCapability -or
        [string]$request.RuleSection -cne
            $script:ContextualCapability -or
        [string]$Finding.ruleId -cnotin @(
            Get-ContextualConventionRuleIds) -or
        [string]$Finding.disposition -cne 'violation') {
        throw 'Contextual convention finding is not bound to the fixed capability.'
    }
    $anchor = $Finding.anchor
    $fileHeaderScope = [string](Get-OwnerV2Member -Value $anchor -Name scope) -ceq 'file-header'
    if (($fileHeaderScope -ne ([string]$Finding.ruleId -ceq 'file-copyright-header')) -or
        ($fileHeaderScope -and (
            [int]$anchor.line -ne 1 -or
            [string]$anchor.symbol -cne 'copyright-header' -or
            $Finding.fileHeader -isnot [Collections.IDictionary] -or
            [string]$Finding.fileHeader.path -cne [string]$anchor.path -or
            [string]$Finding.fileHeader.sourceCommit -cne [string]$request.SourceCommit -or
            [string]$Finding.fileHeader.targetCommit -cne [string]$request.TargetCommit -or
            [string]$Finding.fileHeader.origin -cnotin @('introduced', 'pre-existing')))) {
        throw 'Copyright finding has no exact changed-file header binding.'
    }
    $pullRequestScope =
        $anchor -is
            [Collections.IDictionary] -and
        [string](Get-OwnerV2Member `
            -Value $anchor -Name scope) -ceq
            'pull-request' -and
        [string](Get-OwnerV2Member `
            -Value $anchor -Name subject) -ceq
            'description'
    if ($anchor -isnot [Collections.IDictionary] -or
        (-not $pullRequestScope -and (
            [int]$anchor.line -lt 1 -or
            [string]::IsNullOrWhiteSpace(
                [string]$anchor.path) -or
            [string]::IsNullOrWhiteSpace(
                [string]$anchor.symbol)))) {
        throw 'Contextual convention finding has no precise changed anchor.'
    }
    $material = if ($pullRequestScope) {
        if ([string]$Finding.ruleId -cne
                'pr-template-compliance' -or
            [string]$Finding.issueIdentity -cnotmatch
                '^v1:sha256:[0-9a-f]{64}$') {
            throw 'Contextual PR finding has no stable issue identity.'
        }
        @(
            $script:ContextualMarkerPrefix
            [string]$request.RepositoryId
            [string]$request.PullRequestId
            [string]$Finding.ruleId
            [string]$Finding.issueIdentity
        ) -join "`n"
    }
    else {
        @(
            $script:ContextualMarkerPrefix
            [string]$request.RepositoryId
            [string]$request.PullRequestId
            [string]$request.SourceCommit
            [string]$request.RuleHash
            [string]$Finding.ruleId
            (ConvertTo-OwnerV1WriterPath -Path (
                [string]$anchor.path))
            [string][int]$anchor.line
            [string]$anchor.symbol
            [string]$Finding.constructRef
        ) -join "`n"
    }
    return Get-OwnerV1WriterSha256 -Text $material
}

function Format-ContextualConventionComment {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Finding,
        [Parameter(Mandatory)][string]$MarkerKey
    )
    if ($MarkerKey -cne (
        Get-ContextualConventionMarkerKey `
            -Contract $Contract -Finding $Finding)) {
        throw 'Contextual convention marker does not match its finding.'
    }
    $pullRequestScope =
        [string](Get-OwnerV2Member `
            -Value $Finding.anchor `
            -Name scope) -ceq
            'pull-request'
    $policy = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'Policy\contextual-conventions.v1.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $rule = @($policy.rules | Where-Object { $_.id -ceq [string]$Finding.ruleId })[0]
    $ruleName = [string]$rule.name
    $ruleReference = Format-OwnerCommentRuleReference -Contract $Contract `
        -RuleId ([string]$Finding.ruleId) -Name $ruleName
    $summary = ConvertTo-OwnerV1WriterMarkdownCode (
        [string]$Finding.evidence)
    if ([string]::IsNullOrWhiteSpace($summary) -or
        $summary.Length -gt 512) {
        throw 'Contextual convention evidence summary is invalid.'
    }
    if ($pullRequestScope) {
        $source =
            $Finding.binding.source.representation
        if ($source -isnot
                [Collections.IDictionary] -or
            [string]$source.scope -cne
                'pull-request' -or
            [string]$source.subject -cne
                'description' -or
            @($Finding.missingSections).Count -lt 1) {
            throw 'Contextual PR finding binding is invalid.'
        }
        $missing = @($Finding.missingSections |
            ForEach-Object {
                ConvertTo-OwnerV1WriterMarkdownCode `
                    ([string]$_)
            }) -join ', '
        $templatePath =
            ConvertTo-OwnerV1WriterMarkdownCode (
                ConvertTo-OwnerV1WriterPath `
                    -Path ([string]$source.template.path))
        $repositoryUrl = Get-OwnerCommentRepositoryUrl -Contract $Contract
        $templateLink = if ($repositoryUrl) {
            ConvertTo-OwnerCommentLink -Name $templatePath -Url (
                $repositoryUrl + '?version=GC' + [string]$source.template.commit +
                '&path=' + [uri]::EscapeDataString($templatePath))
        }
        else { "``$templatePath``" }
        return @(
            '**Complete the required pull request template sections**'
            ''
            $ruleReference
            ''
            "$summary"
            ''
            "Missing or placeholder-only sections: $missing."
            ''
            "**Effective template:** $templateLink"
            ''
            'This is a PR-wide description issue; no code line is implicated.'
            ''
            '<details><summary>Template provenance</summary>'
            ''
            "Effective template: ``$templatePath`` from ``$([string]$source.template.ref)`` (blob ``$([string]$source.template.blob)``; SHA-256 ``$([string]$source.template.contentSha256)``)."
            ''
            '</details>'
            ''
            "<!-- ${script:ContextualMarkerPrefix}:$MarkerKey -->"
        ) -join "`n"
    }
    $path = ConvertTo-OwnerV1WriterMarkdownCode (
        ConvertTo-OwnerV1WriterPath -Path (
            [string]$Finding.anchor.path))
    if ([string](Get-OwnerV2Member -Value $Finding.anchor -Name scope) -ceq 'file-header') {
        $origin = if ([string]$Finding.fileHeader.origin -ceq 'pre-existing') {
            'This omission also exists in the comparison base. It is a **pre-existing, nonblocking convention issue**, not a regression introduced by this PR.'
        }
        else {
            'This PR introduces the omission (a new file or removal of an existing header). This is a nonblocking convention finding.'
        }
        return @(
            '**Add the standard copyright header to this file**'
            ''
            $ruleReference
            ''
            "Start ``$path`` with the standard three-line Microsoft header before code."
            ''
            'Use dash separator comments around `// Copyright (c) Microsoft Corporation.  All rights reserved.` No year or annual rollover is required.'
            ''
            $origin
            ''
            'File-header anchor: line 1 of a file in the current changed-file inventory; this is not a claim that line 1 changed.'
            ''
            (Format-OwnerCommentOccurrences -Contract $Contract -Path $path -Lines @(1) `
                -Label 'File-header location')
            ''
            "<!-- ${script:ContextualMarkerPrefix}:$MarkerKey -->"
        ) -join "`n"
    }
    $symbol = ConvertTo-OwnerV1WriterMarkdownCode (
        [string]$Finding.anchor.symbol)
    return @(
        "**$ruleName**"
        ''
        $ruleReference
        ''
        "$summary"
        ''
        "Changed construct: ``$symbol``."
        ''
        (Format-OwnerCommentOccurrences -Contract $Contract -Path $path `
            -Lines @([int]$Finding.anchor.line))
        $(if ([string]$Finding.ruleId -ceq 'reused-string-literals') {
            ''
            foreach ($group in @($Finding.relatedUses | Group-Object { [string]$_.path })) {
                Format-OwnerCommentOccurrences -Contract $Contract -Path $group.Name `
                    -Lines @($group.Group | ForEach-Object { [int]$_.line } |
                        Sort-Object -Unique) -Label 'Related source occurrences'
            }
        })
        ''
        "<!-- ${script:ContextualMarkerPrefix}:$MarkerKey -->"
    ) -join "`n"
}

function Test-ContextualRuleBindingShape {
    param([AllowNull()][object]$Value)
    if ($Value -isnot
        [Collections.IDictionary]) {
        return $false
    }
    $keys = @($Value.Keys |
        ForEach-Object { [string]$_ } |
        Sort-Object -CaseSensitive)
    return (
        ($keys -join "`n") -ceq
            "hash`nlength" -and
        [string]$Value.hash -cmatch
            '^v1:sha256:[0-9a-f]{64}$' -and
        [long]$Value.length -gt 0)
}

function Test-ContextualRuleIdSet {
    param([AllowNull()][object]$Values)
    $ids = @($Values)
    $registered = @(
        Get-ContextualConventionRuleIds)
    return (
        $ids.Count -ge 1 -and
        $ids.Count -le 64 -and
        @($ids |
            Sort-Object -Unique `
                -CaseSensitive).Count -eq
            $ids.Count -and
        @($ids | Where-Object {
                [string]$_ -cnotmatch
                    '^[a-z][a-z0-9-]{0,127}$' -or
                [string]$_ -cnotin
                    $registered
            }).Count -eq 0)
}

function Test-ContextualPriorRuleCompatibility {
    param(
        [AllowNull()][object]$Compatibility,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$PriorRule,
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$RuleId
    )
    if ($Compatibility -isnot
            [Collections.IDictionary]) {
        return $false
    }
    $schema = [int]$Compatibility.
        schemaVersion
    $expectedKeys = if ($schema -eq 1) {
        @(
            'currentRule',
            'kind',
            'previousRule',
            'schemaVersion',
            'unchangedRuleIds')
    }
    elseif ($schema -eq 2) {
        @(
            'currentRule',
            'kind',
            'previousRules',
            'schemaVersion')
    }
    else { @() }
    $actualKeys = @($Compatibility.Keys |
        ForEach-Object { [string]$_ } |
        Sort-Object -CaseSensitive)
    if ($expectedKeys.Count -eq 0 -or
        ($actualKeys -join "`n") -cne
            ($expectedKeys -join "`n") -or
        [string]$Compatibility.kind -cne
            'contextual-additive-rule-history-compatibility' -or
        -not (Test-ContextualRuleBindingShape `
            $Compatibility.currentRule) -or
        [string]$Compatibility.currentRule.hash -cne
            [string]$Request.RuleHash -or
        [long]$Compatibility.currentRule.length -ne
            [long]$Request.RuleLength) {
        return $false
    }
    $previousEntries = if (
        $schema -eq 1) {
        if (-not (
                Test-ContextualRuleBindingShape `
                    $Compatibility.previousRule) -or
            -not (
                Test-ContextualRuleIdSet `
                    $Compatibility.unchangedRuleIds)) {
            return $false
        }
        @([ordered]@{
                rule =
                    $Compatibility.previousRule
                unchangedRuleIds =
                    $Compatibility.unchangedRuleIds
            })
    }
    else {
        $values = @(
            $Compatibility.previousRules)
        if ($values.Count -lt 1 -or
            $values.Count -gt 8) {
            return $false
        }
        $bindings =
            [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal)
        foreach ($entry in $values) {
            if ($entry -isnot
                    [Collections.IDictionary]) {
                return $false
            }
            $entryKeys = @($entry.Keys |
                ForEach-Object {
                    [string]$_
                } |
                Sort-Object -CaseSensitive)
            if (($entryKeys -join "`n") -cne
                    "rule`nunchangedRuleIds" -or
                -not (
                    Test-ContextualRuleBindingShape `
                        $entry.rule) -or
                -not (
                    Test-ContextualRuleIdSet `
                        $entry.unchangedRuleIds)) {
                return $false
            }
            $key = [string]$entry.rule.hash +
                '|' +
                [string][long]$entry.rule.length
            if (-not $bindings.Add($key) -or
                ([string]$entry.rule.hash -ceq
                        [string]$Compatibility.
                            currentRule.hash -and
                    [long]$entry.rule.length -eq
                        [long]$Compatibility.
                            currentRule.length)) {
                return $false
            }
        }
        $values
    }
    foreach ($entry in $previousEntries) {
        if (-not (Test-ContextualConventionPriorRuleIds -Rule $entry.rule -RuleIds @($entry.unchangedRuleIds))) {
            return $false
        }
        $unchanged = @(
            $entry.unchangedRuleIds)
        if ([string]$entry.rule.hash -ceq
                [string]$PriorRule.hash -and
            [long]$entry.rule.length -eq
                [long]$PriorRule.length -and
            [string]$RuleId -cin
                $unchanged) {
            return $true
        }
    }
    return $false
}

function Test-ContextualDuplicateConstantHumanCoverage {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Evidence
    )
    if ($Body -cnotmatch
        '(?i)\b(?:duplicat\w*|consolidat\w*|reconcil\w*|common\s+declar\w*|shared\s+constant\w*)\b') {
        return $false
    }
    $tokens =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches(
            $Evidence,
            '(?<name>[A-Za-z_][A-Za-z0-9_]*)="(?<value>[^"]{1,256})"')) {
        [void]$tokens.Add(
            [string]$match.Groups[
                'name'].Value)
        [void]$tokens.Add(
            [string]$match.Groups[
                'value'].Value)
    }
    foreach ($token in $tokens) {
        if ([regex]::IsMatch(
                $Body,
                '(?i)(?<![A-Za-z0-9_])' +
                [regex]::Escape($token) +
                '(?![A-Za-z0-9_])')) {
            return $true
        }
    }
    return $false
}

function Test-ContextualExceptionNamingHumanCoverage {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Variable
    )
    $name = '(?<![A-Za-z0-9_])' +
        [regex]::Escape($Variable) + '(?![A-Za-z0-9_])'
    return (
        $Variable -cmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$' -and
        $Body -cmatch $name -and
        $Body -match '(?i)\b(?:catch|generic|System\.Exception)\b' -and
        $Body -notmatch '(?i)\b(?:do\s+not|don''t|never)\s+(?:rename|name|use)\b' -and
        ($Body -match (
                '(?is)\b(?:rename|name)\b[^\r\n.]{0,256}' +
                $name + '[^\r\n.]{0,80}\b(?:to|as)\s+[`''"]*ex\b') -or
            $Body -match (
                '(?i)\buse\s+[`''"]*ex[`''"]*\s+for\b[^\r\n.]{0,128}\b(?:generic|catch)\b')))
}

function Test-ContextualFindingThreadRange {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Finding,
        [Parameter(Mandatory)][object]$Thread,
        [string]$Body = '',
        [string]$SourceCommit = ''
    )
    if ([string]$Finding.ruleId -ceq 'reused-string-literals' -and
        $null -ne $Thread.anchor) {
        $sameUse = @($Finding.relatedUses | Where-Object {
            [string]$_.path -ieq [string]$Thread.anchor.path -and
            [int]$Thread.anchor.line -ge [int]$_.line -and
            [int]$Thread.anchor.line -le [int]$_.endLine
        }).Count -gt 0
        if ($sameUse -or -not $Body) { return $sameUse }
        return @($Finding.relatedUses | Where-Object {
            [string]$_.path -ieq [string]$Thread.anchor.path
        }).Count -gt 0 -and (
            (Test-ContextualReusedStringHumanCoverage -Body $Body -Finding $Finding) -or
            (Test-ContextualReusedStringCitation -Body $Body -Finding $Finding -SourceCommit $SourceCommit))
    }
    if ($null -eq $Thread.anchor -or
        [string]$Thread.anchor.path -ine [string]$Finding.anchor.path) {
        return $false
    }
    if ([string]$Finding.ruleId -ceq 'file-copyright-header' -and $Body) {
        return [regex]::IsMatch($Body,
            '(?:copyright[\s\S]{0,160}header|header[\s\S]{0,160}copyright)',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if ([int]$Thread.anchor.line -eq [int]$Finding.anchor.line) { return $true }
    $indentation = Get-OwnerV2Member -Value $Finding -Name indentationContext
    if ([string]$Finding.ruleId -ceq 'block-body-indentation' -and
        $indentation -is [Collections.IDictionary] -and
        [int]$indentation.blockStartLine -gt 0 -and
        [int]$indentation.blockStartLine -lt [int]$indentation.statementLine -and
        [int]$indentation.blockEndLine -ge [int]$indentation.statementLine -and
        [int]$Finding.anchor.line -in @(
            [int]$indentation.statementLine, [int]$indentation.blockStartLine) -and
        [int]$Thread.anchor.line -eq [int]$indentation.blockStartLine) {
        return $true
    }
    $span = Get-OwnerV2Member -Value (Get-OwnerV2Member -Value $Finding -Name binding) -Name span
    return [string]$Finding.ruleId -ceq 'duplicate-constant-declarations' -and
        $span -is [Collections.IDictionary] -and
        [int]$Thread.anchor.line -ge [int]$span.startLine -and
        [int]$Thread.anchor.line -le [int]$span.endLine
}

function Test-ContextualFindingHumanCoverage {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Finding,
        [Parameter(Mandatory)][string]$Body,
        [bool]$SameAnchor
    )
    switch ([string]$Finding.ruleId) {
        'generic-exception-naming' {
            return Test-ContextualExceptionNamingHumanCoverage -Body $Body -Variable ([string]$Finding.anchor.symbol)
        }
        'reused-string-literals' {
            return Test-ContextualReusedStringHumanCoverage -Body $Body -Finding $Finding
        }
        'block-body-indentation' {
            return $Body -match '(?i)\bindent(?:ation|ed|ing)?\b' -and
                $Body -match '(?i)\b(?:body|block|statements)\b'
        }
        'duplicate-constant-declarations' {
            return $SameAnchor -or
                (Test-ContextualDuplicateConstantHumanCoverage -Body $Body -Evidence ([string]$Finding.evidence))
        }
        default { return $true }
    }
}

function Test-ContextualReusedStringHumanCoverage {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][Collections.IDictionary]$Finding
    )
    if ($Body -inotmatch '\bconstants?\b' -or
        $Body -inotmatch '\b(?:re-?us\w*|shar\w*|declar\w*|hardcod\w*)\b' -or
        @($Finding.literalValues).Count -eq 0) {
        return $false
    }
    foreach ($value in @($Finding.literalValues)) {
        if ([string]::IsNullOrWhiteSpace([string]$value) -or
            -not [regex]::IsMatch($Body,
                '(?<![\p{L}\p{N}_])' + [regex]::Escape([string]$value) + '(?![\p{L}\p{N}_])')) {
            return $false
        }
    }
    return $true
}

function Test-ContextualReusedStringCitation {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][Collections.IDictionary]$Finding,
        [Parameter(Mandatory)][string]$SourceCommit
    )
    foreach ($match in [regex]::Matches($Body, 'https?://[^\s)<>]+')) {
        $uri = $null
        if (-not [Uri]::TryCreate($match.Value, [UriKind]::Absolute, [ref]$uri)) {
            continue
        }
        $query = @{}
        foreach ($part in $uri.Query.TrimStart('?').Split('&')) {
            $pair = $part.Split('=', 2)
            if ($pair.Count -eq 2) {
                $query[[Uri]::UnescapeDataString($pair[0])] =
                    [Uri]::UnescapeDataString($pair[1])
            }
        }
        [int]$line = 0
        if ([string]$query.version -cne "GC$SourceCommit" -or
            -not [int]::TryParse([string]$query.line, [ref]$line)) {
            continue
        }
        if (@($Finding.relatedUses | Where-Object {
                    [string]$_.path -ieq ([string]$query.path).TrimStart('/') -and
                    $line -ge [int]$_.line -and $line -le [int]$_.endLine
                }).Count -gt 0) {
            return $true
        }
    }
    return $false
}

function Resolve-ContextualConventionDiscussionReconciliation {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][object]$Contract,
        [AllowNull()]
        [DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]$Snapshot,
        [Parameter(Mandatory)][string]$FailureReason,
        [AllowEmptyCollection()]
        [object[]]$AuthenticatedPriorComments = @()
    )
    $counts = [ordered]@{
        created = 0
        updated = 0
        noOp = 0
        wouldCreate = 0
        wouldUpdate = 0
        unknown = 0
        humanCovered = 0
    }
    $available = $null -ne $Snapshot -and
        $Snapshot.State -ceq 'complete' -and
        $Snapshot.Digest -match
            $script:OwnerV2DigestPattern
    $discussionDigest = if ($available) {
        $Snapshot.Digest.Substring(10)
    }
    else { 'unknown' }
    $targetPattern =
        '<!--\s*devpilot-contextual-convention:v1:([0-9a-f]{64})\s*-->'
    $anyMarkerPattern =
        '<!--\s*devpilot-[a-z0-9-]+:v1:[0-9a-f]{64}\s*-->'
    foreach ($finding in @($Observation.findings)) {
        if ([string]$finding.ruleId -ceq 'reused-string-literals' -and
            (-not $finding.Contains('literalValues') -or
                -not $finding.Contains('relatedUses') -or
                @($finding.literalValues).Count -lt 1 -or
                @($finding.relatedUses).Count -lt 2)) {
            $finding.providerMarker = New-OwnerProviderMarker
            $finding.reconciliation = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason reused-string-proof-missing `
                -DiscussionDigest $discussionDigest -BodyDigest unknown
            $counts.unknown++
            continue
        }
        try {
            $marker =
                Get-ContextualConventionMarkerKey `
                    -Contract $Contract -Finding $finding
            $body =
                Format-ContextualConventionComment `
                    -Contract $Contract `
                    -Finding $finding -MarkerKey $marker
        }
        catch {
            $finding.providerMarker =
                New-OwnerProviderMarker
            $finding.reconciliation =
                New-OwnerV2DiscussionReconciliation `
                    -Classification unknown `
                    -Reason marker-derivation-failed `
                    -DiscussionDigest $discussionDigest `
                    -BodyDigest unknown
            $counts.unknown++
            continue
        }
        $bodyDigest =
            Get-OwnerV1WriterSha256 -Text $body
        if (-not $available) {
            $finding.providerMarker =
                New-OwnerProviderMarker
            $finding.reconciliation =
                New-OwnerV2DiscussionReconciliation `
                    -Classification unknown `
                    -Reason $FailureReason `
                    -DiscussionDigest unknown `
                    -BodyDigest $bodyDigest
            $counts.unknown++
            continue
        }
        $pullRequestScope =
            [string](Get-OwnerV2Member `
                -Value $finding.anchor `
                -Name scope) -ceq
                'pull-request'
        if ($pullRequestScope) {
            $markerEntries =
                [Collections.Generic.List[object]]::new()
            $priorReviewerEntries =
                [Collections.Generic.List[object]]::new()
            $foreign = $false
            $ambiguous = $false
            $humanCovered = $false
            $humanPartial = $false
            $currentMissing =
                @($finding.missingSections |
                    Sort-Object -Unique)
            $currentTemplate =
                $finding.binding.source.
                    representation.template
            foreach ($thread in @(
                    $Snapshot.Threads)) {
                $topLevelCurrent =
                    $null -eq $thread.anchor -and
                    -not [bool]$thread.isDeleted -and
                    -not [bool]$thread.isOutdated -and
                    [string]$thread.status -ceq
                        'active'
                foreach ($comment in @(
                        $thread.comments)) {
                    if ([string]$comment.commentType -cne
                            'text' -or
                        [bool]$comment.isDeleted) {
                        continue
                    }
                    $target = @(
                        [regex]::Matches(
                            [string]$comment.body,
                            $targetPattern) |
                            Where-Object {
                                $_.Groups[1].Value -ceq
                                    $marker
                            })
                    $allMarkers = @(
                        [regex]::Matches(
                            [string]$comment.body,
                            $targetPattern))
                    if ($target.Count -gt 0) {
                        if (-not $topLevelCurrent -or
                            [string]$comment.
                                reviewerIdentityState -ceq
                                'ambiguous') {
                            $ambiguous = $true
                        }
                        elseif (-not [bool]$comment.
                                reviewerOwned) {
                            $foreign = $true
                        }
                        else {
                            [void]$markerEntries.Add(
                                [pscustomobject]@{
                                    Thread = $thread
                                    Comment = $comment
                                    Count = $target.Count
                                })
                        }
                        continue
                    }
                    $body =
                        [string]$comment.body
                    $prTemplateBody =
                        $body -match
                            '\A\*\*Complete the required pull request template sections\*\*' -or
                        $body -match
                            '(?m)^Missing or placeholder-only sections:' -or
                        $body -match
                            '\A\*\*`?pr-template-compliance`?\*\*'
                    if ($null -ne $thread.anchor) {
                        if ($prTemplateBody) {
                            $ambiguous = $true
                        }
                        continue
                    }
                    if ($topLevelCurrent -and
                        [string]$comment.
                            reviewerIdentityState -ceq
                                'ambiguous') {
                        $ambiguous = $true
                        continue
                    }
                    $hasAnyDevPilotMarker =
                        [regex]::IsMatch(
                            $body,
                            $anyMarkerPattern)
                    if ($allMarkers.Count -gt 0 -or
                        $hasAnyDevPilotMarker -or
                        [bool]$comment.reviewerOwned) {
                        $missingMatches = @(
                            [regex]::Matches(
                                $body,
                                '(?m)^Missing or placeholder-only sections: (?<sections>(?:Problem|Solution|Validation)(?:, (?:Problem|Solution|Validation))*)\.$'))
                        $templateMatches = @(
                            [regex]::Matches(
                                $body,
                                '(?m)^Effective template: `(?<path>[^`\r\n]{1,1024})` from `(?<ref>refs/heads/[^`\r\n]+)` \(blob `(?<blob>[0-9a-f]{40})`; SHA-256 `(?<digest>[0-9a-f]{64})`\)\.$'))
                        $canonical =
                            $allMarkers.Count -eq 1 -and
                            -not ($hasAnyDevPilotMarker -and
                                $allMarkers.Count -eq 0) -and
                            $missingMatches.Count -eq 1 -and
                            $templateMatches.Count -eq 1 -and
                            $body -match
                                '\A\*\*Complete the required pull request template sections\*\*' -and
                            $body -match
                                '(?m)^This is a PR-wide description issue; no code line is implicated\.$'
                        if ([bool]$comment.reviewerOwned -and
                            [string]$comment.
                                reviewerIdentityState -ceq
                                    'matched' -and
                            $canonical) {
                            if (-not $topLevelCurrent) {
                                $ambiguous = $true
                                continue
                            }
                            $priorMissing = @(
                                $missingMatches[0].
                                    Groups['sections'].
                                    Value.Split(',') |
                                    ForEach-Object {
                                        $_.Trim()
                                    } |
                                    Sort-Object -Unique)
                            [void]$priorReviewerEntries.Add(
                                [pscustomobject]@{
                                    Thread = $thread
                                    Comment = $comment
                                    MissingSections =
                                        $priorMissing
                                    Template =
                                        [ordered]@{
                                            path =
                                                $templateMatches[0].
                                                    Groups['path'].Value.
                                                    TrimStart('/')
                                            ref =
                                                $templateMatches[0].
                                                    Groups['ref'].Value
                                            blob =
                                                $templateMatches[0].
                                                    Groups['blob'].Value
                                            contentSha256 =
                                                $templateMatches[0].
                                                    Groups['digest'].Value
                                        }
                                })
                        }
                        else {
                            $ambiguous = $true
                            if (-not [bool]$comment.
                                    reviewerOwned) {
                                $foreign = $true
                            }
                        }
                        continue
                    }
                    if ($topLevelCurrent -and
                        -not [bool]$comment.reviewerOwned) {
                        $humanBody =
                            [string]$comment.body
                        $templateCue =
                            $humanBody -match
                                '(?i)\b(?:pull\s+request|pr)\s+template\b'
                        $actionCue =
                            $humanBody -match
                                '(?i)\b(?:add|fill|include|missing|provide|complete|update)\w*\b'
                        if ($templateCue -and
                            $actionCue) {
                            $mentioned =
                                [Collections.Generic.HashSet[string]]::new(
                                    [StringComparer]::OrdinalIgnoreCase)
                            foreach ($section in @(
                                    'Problem',
                                    'Solution',
                                    'Validation')) {
                                if ($humanBody -match (
                                    '(?i)\b' +
                                    [regex]::Escape(
                                        $section) +
                                    '\b')) {
                                    [void]$mentioned.Add(
                                        $section)
                                }
                            }
                            $coversCurrent =
                                @($currentMissing |
                                    Where-Object {
                                        -not $mentioned.Contains(
                                            [string]$_)
                                    }).Count -eq 0
                            if ($coversCurrent) {
                                $humanCovered = $true
                            }
                            else {
                                $humanPartial = $true
                            }
                        }
                    }
                }
            }
            if ($ambiguous -or $foreign -or
                $markerEntries.Count -gt 1 -or
                ($markerEntries.Count -eq 1 -and
                    [int]$markerEntries[0].Count -ne 1) -or
                ($markerEntries.Count -eq 1 -and
                    $priorReviewerEntries.Count -gt 0) -or
                $priorReviewerEntries.Count -gt 1) {
                $finding.providerMarker =
                    New-OwnerProviderMarker `
                        -Value $marker `
                        -Integrity invalid
                $finding.reconciliation =
                    New-OwnerV2DiscussionReconciliation `
                        -Classification unknown `
                        -Reason duplicate-or-foreign-reviewer-marker `
                        -DiscussionDigest $discussionDigest `
                        -BodyDigest $bodyDigest `
                        -ThreadAvailability ambiguous
                $counts.unknown++
                continue
            }
            if ($markerEntries.Count -eq 1) {
                $entry = $markerEntries[0]
                $finding.providerMarker =
                    New-OwnerProviderMarker `
                        -Value $marker `
                        -Integrity verified
                $finding.reconciliation =
                    New-OwnerV2DiscussionReconciliation `
                        -Classification noOp `
                        -Reason exact-current-pr-wide-comment `
                        -DiscussionDigest $discussionDigest `
                        -BodyDigest $bodyDigest `
                        -ThreadAvailability available `
                        -ThreadId (
                            [long]$entry.Thread.threadId) `
                        -CommentId (
                            [long]$entry.Comment.commentId) `
                        -ThreadStatus (
                            [string]$entry.Thread.status)
                $counts.noOp++
                continue
            }
            if ($priorReviewerEntries.Count -eq 1) {
                $entry =
                    $priorReviewerEntries[0]
                $priorTemplate =
                    $entry.Template
                $sameTemplate =
                    [string]$priorTemplate.path -ceq
                        [string]$currentTemplate.path -and
                    [string]$priorTemplate.ref -ceq
                        [string]$currentTemplate.ref -and
                    [string]$priorTemplate.blob -ceq
                        [string]$currentTemplate.blob -and
                    [string]$priorTemplate.contentSha256 -ceq
                        [string]$currentTemplate.contentSha256
                $priorMissing =
                    [Collections.Generic.HashSet[string]]::new(
                        [StringComparer]::OrdinalIgnoreCase)
                foreach ($section in @(
                        $entry.MissingSections)) {
                    [void]$priorMissing.Add(
                        [string]$section)
                }
                $coversCurrent =
                    @($currentMissing |
                        Where-Object {
                            -not $priorMissing.Contains(
                                [string]$_)
                        }).Count -eq 0
                if (-not $sameTemplate -or
                    -not $coversCurrent) {
                    $finding.providerMarker =
                        New-OwnerProviderMarker `
                            -Value $marker `
                            -Integrity invalid
                    $finding.reconciliation =
                        New-OwnerV2DiscussionReconciliation `
                            -Classification unknown `
                            -Reason prior-pr-template-review-coverage-unproven `
                            -DiscussionDigest $discussionDigest `
                            -BodyDigest $bodyDigest `
                            -ThreadAvailability ambiguous
                    $counts.unknown++
                    continue
                }
                $finding.providerMarker =
                    New-OwnerProviderMarker `
                        -Value $marker `
                        -Integrity verified
                $finding.reconciliation =
                    New-OwnerV2DiscussionReconciliation `
                        -Classification noOp `
                        -Reason prior-pr-template-review-covers-current-missing-sections `
                        -DiscussionDigest $discussionDigest `
                        -BodyDigest $bodyDigest `
                        -ThreadAvailability available `
                        -ThreadId (
                            [long]$entry.Thread.threadId) `
                        -CommentId (
                            [long]$entry.Comment.commentId) `
                        -ThreadStatus (
                            [string]$entry.Thread.status)
                $counts.noOp++
                continue
            }
            if (-not $humanCovered -and
                $humanPartial) {
                $finding.providerMarker =
                    New-OwnerProviderMarker `
                        -Value $marker `
                        -Integrity invalid
                $finding.reconciliation =
                    New-OwnerV2DiscussionReconciliation `
                        -Classification unknown `
                        -Reason partial-human-pr-template-coverage `
                        -DiscussionDigest $discussionDigest `
                        -BodyDigest $bodyDigest `
                        -ThreadAvailability ambiguous
                $counts.unknown++
                continue
            }
            $classification = if (
                $humanCovered) {
                'humanCovered'
            }
            else { 'wouldCreate' }
            $finding.providerMarker =
                New-OwnerProviderMarker `
                    -Value $marker `
                    -Integrity verified
            $finding.reconciliation =
                New-OwnerV2DiscussionReconciliation `
                    -Classification $classification `
                    -Reason $(if ($humanCovered) {
                        'current-human-pr-template-review'
                    }
                    else {
                        'no-current-pr-template-review'
                    }) `
                    -DiscussionDigest $discussionDigest `
                    -BodyDigest $bodyDigest
            if ($humanCovered) {
                $counts.humanCovered++
            }
            else {
                $counts.wouldCreate++
            }
            continue
        }
        $authenticatedMatches =
            [Collections.Generic.List[object]]::new()
        $authenticatedPriorMarkerSeen =
            $false
        foreach ($proof in @(
                $AuthenticatedPriorComments)) {
            $ruleBindingMatches = $false
            if ($proof -is
                    [Collections.IDictionary] -and
                $proof.Contains('rule') -and
                $proof.rule -is
                    [Collections.IDictionary]) {
                $ruleBindingMatches =
                    [string]$proof.rule.hash -ceq
                        [string]$Contract.Request.RuleHash -and
                    [long]$proof.rule.length -eq
                        [long]$Contract.Request.RuleLength
                if (-not $ruleBindingMatches -and
                    $proof.Contains(
                        'ruleCompatibility')) {
                    $ruleBindingMatches =
                        Test-ContextualPriorRuleCompatibility `
                            -Compatibility (
                                $proof.ruleCompatibility) `
                            -PriorRule $proof.rule `
                            -Request $Contract.Request `
                            -RuleId (
                                [string]$finding.ruleId)
                }
            }
            if ($proof -isnot
                    [Collections.IDictionary] -or
                [string]$proof.kind -cne
                    'owner-v2-authenticated-prior-comment' -or
                [string]$proof.delivery -cne
                    'contextual-conventions' -or
                [string]$proof.capabilityId -cne
                    $script:ContextualCapability -or
                [string]$proof.subject.projectId -cne
                    [string]$Contract.Request.ProjectId -or
                [string]$proof.subject.repositoryId -cne
                    [string]$Contract.Request.RepositoryId -or
                [long]$proof.subject.pullRequestId -ne
                    [long]$Contract.Request.PullRequestId -or
                [string]$proof.subject.sourceCommit -cne
                    [string]$Contract.Request.SourceCommit -or
                [string]$proof.subject.targetCommit -cne
                    [string]$Contract.Request.TargetCommit -or
                [string]$proof.subject.targetRef -cne
                    [string]$Contract.Request.TargetRef -or
                [string]$proof.rule.repositoryId -cne
                    [string]$Contract.Request.RuleRepositoryId -or
                [string]$proof.rule.path -cne
                    [string]$Contract.Request.RulePath -or
                [string]$proof.rule.section -cne
                    [string]$Contract.Request.RuleSection -or
                -not $ruleBindingMatches -or
                [string]$proof.reviewerIdentityDigest -cne
                    [string]$Snapshot.
                        ReviewerIdentityDigest -or
                [string]$proof.selection.ruleId -cne
                    [string]$finding.ruleId -or
                [string]$proof.selection.path -ine
                    [string]$finding.anchor.path -or
                [int]$proof.selection.line -ne
                    [int]$finding.anchor.line -or
                [string]$proof.selection.symbol -cne
                    [string]$finding.anchor.symbol -or
                [string]$proof.selection.constructIdentity -cne
                    [string]$finding.binding.constructIdentity) {
                continue
            }
            $priorEntries =
                [Collections.Generic.List[object]]::new()
            foreach ($thread in @($Snapshot.Threads)) {
                foreach ($comment in @(
                        $thread.comments)) {
                    $priorMarkers = @(
                        [regex]::Matches(
                            [string]$comment.body,
                            $targetPattern) |
                            Where-Object {
                                $_.Groups[1].Value -ceq
                                    [string]$proof.selection.marker
                            })
                    if ($priorMarkers.Count -eq 0) {
                        continue
                    }
                    $authenticatedPriorMarkerSeen =
                        $true
                    if ($priorMarkers.Count -eq 1 -and
                        [regex]::Matches([string]$comment.body, $anyMarkerPattern).Count -eq 1 -and
                        [string]$comment.commentType -ceq
                            'text' -and
                        -not [bool]$comment.isDeleted -and
                        [bool]$comment.reviewerOwned -and
                        [string]$comment.reviewerIdentityState -ceq
                            'matched' -and
                        [long]$thread.threadId -eq
                            [long]$proof.event.threadId -and
                        [long]$comment.commentId -eq
                            [long]$proof.event.commentId -and
                        -not [bool]$thread.isDeleted -and
                        -not [bool]$thread.isOutdated -and
                        [string]$thread.status -ceq
                            'active' -and
                        [string]$thread.contextState -ceq
                            'current' -and
                        [string]$thread.sourceCommit -ceq
                            [string]$Contract.Request.SourceCommit -and
                        $null -ne $thread.anchor -and
                        [string]$thread.anchor.path -ieq
                            [string]$finding.anchor.path -and
                        [int]$thread.anchor.line -eq
                            [int]$finding.anchor.line -and
                        [string]$comment.body -ceq
                            [string]$proof.selection.body -and
                        (Get-OwnerV1WriterSha256 -Text (
                            [string]$comment.body)) -ceq
                            [string]$proof.selection.bodySha256) {
                        [void]$priorEntries.Add(
                            [pscustomobject]@{
                                Thread = $thread
                                Comment = $comment
                                Proof = $proof
                            })
                    }
                }
            }
            if ($priorEntries.Count -eq 1) {
                [void]$authenticatedMatches.Add(
                    $priorEntries[0])
            }
        }
        if ($authenticatedMatches.Count -eq 1) {
            $entry = $authenticatedMatches[0]
            $priorConflict = $false
            foreach ($thread in @(
                    $Snapshot.Threads)) {
                $sameAnchor = $null -ne
                        $thread.anchor -and
                    [string]$thread.anchor.path -ieq
                        [string]$finding.anchor.path -and
                    [int]$thread.anchor.line -eq
                        [int]$finding.anchor.line
                $sameFindingRange = Test-ContextualFindingThreadRange -Finding $finding -Thread $thread
                $currentThread =
                    -not [bool]$thread.isDeleted -and
                    -not [bool]$thread.isOutdated -and
                    [string]$thread.status -ceq
                        'active' -and
                    [string]$thread.contextState -ceq
                        'current' -and
                    [string]$thread.sourceCommit -ceq
                        [string]$Contract.Request.SourceCommit
                foreach ($comment in @(
                        $thread.comments)) {
                    if ([long]$thread.threadId -eq
                            [long]$entry.Thread.threadId -and
                        [long]$comment.commentId -eq
                            [long]$entry.Comment.commentId) {
                        continue
                    }
                    if ([string]$comment.commentType -cne
                            'text' -or
                        [bool]$comment.isDeleted) {
                        continue
                    }
                    $commentRelevant = Test-ContextualFindingThreadRange -Finding $finding -Thread $thread `
                        -Body ([string]$comment.body) -SourceCommit ([string]$Contract.Request.SourceCommit)
                    $currentContext = $currentThread -and $commentRelevant
                    if ([string]$finding.ruleId -ceq 'file-copyright-header' -and
                        $commentRelevant -and -not $currentThread) {
                        $priorConflict = $true
                        break
                    }
                    if (@([regex]::Matches(
                            [string]$comment.body,
                            $targetPattern) |
                            Where-Object {
                                $_.Groups[1].Value -ceq
                                    $marker -or
                                $_.Groups[1].Value -ceq
                                    [string]$entry.Proof.selection.marker
                            }).Count -gt 0) {
                        $priorConflict = $true
                        break
                    }
                    if ($currentContext -and (
                            [string]$comment.
                                reviewerIdentityState -ceq
                                'ambiguous' -or
                            [regex]::IsMatch(
                                [string]$comment.body,
                                $anyMarkerPattern) -or
                            ([string]$finding.ruleId -cin @('block-body-indentation', 'generic-exception-naming',
                                'reused-string-literals', 'file-copyright-header') -and [bool]$comment.reviewerOwned) -or
                            -not (Test-ContextualFindingHumanCoverage -Finding $finding `
                                -Body ([string]$comment.body) -SameAnchor $sameAnchor) -or
                            ([string]$finding.ruleId -ceq 'reused-string-literals' -and
                                -not $sameFindingRange -and
                                -not (Test-ContextualReusedStringCitation -Body ([string]$comment.body) `
                                    -Finding $finding -SourceCommit ([string]$Contract.Request.SourceCommit))))) {
                        $priorConflict = $true
                        break
                    }
                }
                if ($priorConflict) {
                    break
                }
            }
            if ($priorConflict) {
                $finding.providerMarker =
                    New-OwnerProviderMarker `
                        -Value $marker `
                        -Integrity invalid
                $finding.reconciliation =
                    New-OwnerV2DiscussionReconciliation `
                        -Classification unknown `
                        -Reason authenticated-prior-comment-conflict `
                        -DiscussionDigest $discussionDigest `
                        -BodyDigest $bodyDigest `
                        -ThreadAvailability ambiguous
                $counts.unknown++
                continue
            }
            $finding.providerMarker =
                New-OwnerProviderMarker `
                    -Value $marker `
                    -Integrity verified
            $finding.reconciliation =
                New-OwnerV2DiscussionReconciliation `
                    -Classification noOp `
                    -Reason authenticated-prior-reviewer-comment `
                    -DiscussionDigest $discussionDigest `
                    -BodyDigest $bodyDigest `
                    -ThreadAvailability available `
                    -ThreadId (
                        [long]$entry.Thread.threadId) `
                    -CommentId (
                        [long]$entry.Comment.commentId) `
                    -ThreadStatus (
                        [string]$entry.Thread.status)
            $counts.noOp++
            continue
        }
        if ($authenticatedPriorMarkerSeen) {
            $finding.providerMarker =
                New-OwnerProviderMarker `
                    -Value $marker `
                    -Integrity invalid
            $finding.reconciliation =
                New-OwnerV2DiscussionReconciliation `
                    -Classification unknown `
                    -Reason authenticated-prior-comment-mismatch `
                    -DiscussionDigest $discussionDigest `
                    -BodyDigest $bodyDigest `
                    -ThreadAvailability ambiguous
            $counts.unknown++
            continue
        }
        $matches =
            [Collections.Generic.List[object]]::new()
        $foreign = $false
        $ambiguous = $false
        $humanCurrent = $false
        $crossRule = $false
        $rangedHumanUnknown = $false
        $unmarkedReviewerCurrent = $false
        $markerlessReusedStringReviewer = $false
        foreach ($thread in @($Snapshot.Threads)) {
            $sameAnchor = $null -ne $thread.anchor -and
                [string]$thread.anchor.path -ieq
                    [string]$finding.anchor.path -and
                [int]$thread.anchor.line -eq
                    [int]$finding.anchor.line
            $sameFindingRange = Test-ContextualFindingThreadRange -Finding $finding -Thread $thread
            foreach ($comment in @($thread.comments)) {
                if ([string]$comment.commentType -cne
                        'text' -or
                    [bool]$comment.isDeleted) {
                    continue
                }
                $copyrightDiscussion =
                    [string]$finding.ruleId -ceq 'file-copyright-header' -and
                    $null -ne $thread.anchor -and
                    [string]$thread.anchor.path -ieq [string]$finding.anchor.path -and
                    [regex]::IsMatch([string]$comment.body,
                        '(?:copyright[\s\S]{0,160}header|header[\s\S]{0,160}copyright)',
                        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($copyrightDiscussion -and (
                    [bool]$thread.isDeleted -or [bool]$thread.isOutdated -or
                    [string]$thread.status -cne 'active' -or
                    [string]$thread.contextState -cne 'current' -or
                    [string]$thread.sourceCommit -cne [string]$Contract.Request.SourceCommit)) {
                    $ambiguous = $true
                    continue
                }
                $markerMatches = [regex]::Matches(
                    [string]$comment.body,
                    $targetPattern)
                $target = @($markerMatches |
                    Where-Object {
                        $_.Groups[1].Value -ceq
                            $marker
                    })
                if ($target.Count -gt 0) {
                    if ([string]$finding.ruleId -ceq 'file-copyright-header' -and (
                        -not $sameAnchor -or
                        [bool]$thread.isDeleted -or [bool]$thread.isOutdated -or
                        [string]$thread.status -cne 'active' -or
                        [string]$thread.contextState -cne 'current' -or
                        [string]$thread.sourceCommit -cne [string]$Contract.Request.SourceCommit)) {
                        $ambiguous = $true
                        continue
                    }
                    if ([string]$comment.
                        reviewerIdentityState -ceq
                            'ambiguous') {
                        $ambiguous = $true
                    }
                    elseif (-not [bool]$comment.
                        reviewerOwned) {
                        $foreign = $true
                    }
                    else {
                        [void]$matches.Add(
                            [pscustomobject]@{
                                Thread = $thread
                                Comment = $comment
                                Count = $target.Count
                            })
                    }
                    continue
                }
                $citedReusedString = [string]$finding.ruleId -ceq 'reused-string-literals' -and
                    $null -ne $thread.anchor -and
                    @($finding.relatedUses | Where-Object {
                        [string]$_.path -ieq [string]$thread.anchor.path
                    }).Count -gt 0 -and
                    (Test-ContextualReusedStringCitation -Body ([string]$comment.body) `
                        -Finding $finding -SourceCommit ([string]$Contract.Request.SourceCommit))
                $namedLiteralRequest = [string]$finding.ruleId -ceq 'reused-string-literals' -and
                    $null -ne $thread.anchor -and
                    @($finding.relatedUses | Where-Object {
                        [string]$_.path -ieq [string]$thread.anchor.path
                    }).Count -gt 0 -and
                    (Test-ContextualReusedStringHumanCoverage -Body ([string]$comment.body) -Finding $finding)
                if ((($sameFindingRange -and [string]$finding.ruleId -cne 'file-copyright-header') -or
                    $copyrightDiscussion -or $citedReusedString -or $namedLiteralRequest) -and
                    -not [bool]$thread.isDeleted -and
                    -not [bool]$thread.isOutdated -and
                    [string]$thread.status -ceq
                        'active' -and
                    [string]$thread.contextState -ceq
                        'current' -and
                    [string]$thread.sourceCommit -ceq
                        [string]$Contract.Request.
                            SourceCommit) {
                    if ([regex]::IsMatch(
                        [string]$comment.body,
                        $anyMarkerPattern)) {
                        $crossRule = $true
                    }
                    elseif ([string]$comment.
                        reviewerIdentityState -ceq
                            'ambiguous') {
                        $ambiguous = $true
                    }
                    elseif ([string]$finding.ruleId -ceq
                            'block-body-indentation' -and
                        [bool]$comment.reviewerOwned) {
                        $unmarkedReviewerCurrent = $true
                    }
                    elseif ([string]$finding.ruleId -ceq
                            'generic-exception-naming' -and (
                            [bool]$comment.reviewerOwned -or
                            -not (
                                Test-ContextualFindingHumanCoverage -Finding $finding -SameAnchor $sameAnchor `
                                    -Body ([string]$comment.body) `
                                ))) {
                        $crossRule = $true
                    }
                    elseif ($copyrightDiscussion -and [bool]$comment.reviewerOwned) {
                        $ambiguous = $true
                    }
                    elseif ([string]$finding.ruleId -ceq 'reused-string-literals' -and
                        [bool]$comment.reviewerOwned) {
                        $markerlessReusedStringReviewer = $true
                    }
                    elseif ([string]$finding.ruleId -ceq 'reused-string-literals' -and
                        -not $sameFindingRange -and -not $citedReusedString) {
                        $rangedHumanUnknown = $true
                    }
                    elseif ([string]$finding.ruleId -ceq 'reused-string-literals' -and
                        -not (Test-ContextualFindingHumanCoverage -SameAnchor $sameAnchor `
                            -Body ([string]$comment.body) -Finding $finding)) {
                        $rangedHumanUnknown = $true
                    }
                    elseif (-not $sameAnchor -and
                        [string]$finding.ruleId -ceq
                            'duplicate-constant-declarations' -and
                        -not (
                            Test-ContextualFindingHumanCoverage -Finding $finding -SameAnchor $sameAnchor `
                                -Body (
                                    [string]$comment.body))) {
                        $rangedHumanUnknown =
                            $true
                    }
                    elseif ([string]$finding.ruleId -ceq
                            'block-body-indentation' -and
                        -not (Test-ContextualFindingHumanCoverage -Finding $finding -SameAnchor $sameAnchor `
                            -Body ([string]$comment.body))) {
                        $rangedHumanUnknown = $true
                    }
                    else {
                        $humanCurrent = $true
                    }
                }
            }
        }
        if ($ambiguous -or $foreign -or
            $markerlessReusedStringReviewer -or
            $rangedHumanUnknown -or
            $unmarkedReviewerCurrent -or
            $matches.Count -gt 1 -or
            ($matches.Count -eq 1 -and
                [int]$matches[0].Count -ne 1)) {
            $finding.providerMarker =
                New-OwnerProviderMarker `
                    -Value $marker `
                    -Integrity invalid
            $finding.reconciliation =
                New-OwnerV2DiscussionReconciliation `
                    -Classification unknown `
                    -Reason $(if ($unmarkedReviewerCurrent) {
                            'unmarked-current-reviewer-comment'
                        }
                        elseif ($markerlessReusedStringReviewer) {
                            'existing-reviewer-comment-unproven'
                        }
                        elseif (
                            $rangedHumanUnknown -and
                            -not $ambiguous -and
                            -not $foreign -and
                            $matches.Count -eq 0) {
                            'ambiguous-ranged-human-review'
                        }
                        else {
                            'duplicate-or-foreign-reviewer-marker'
                        }) `
                    -DiscussionDigest $discussionDigest `
                    -BodyDigest $bodyDigest `
                    -ThreadAvailability ambiguous
            $counts.unknown++
            continue
        }
        if ($matches.Count -eq 1) {
            $entry = $matches[0]
            $sameBody =
                (Get-OwnerV1WriterSha256 -Text (
                    [string]$entry.Comment.body)) -ceq
                    $bodyDigest
            $finding.providerMarker =
                New-OwnerProviderMarker `
                    -Value $marker
            $finding.reconciliation =
                New-OwnerV2DiscussionReconciliation `
                    -Classification $(if ($sameBody) {
                        'noOp'
                    } else { 'unknown' }) `
                    -Reason $(if ($sameBody) {
                        'exact-current-comment'
                    } else {
                        'existing-comment-body-changed'
                    }) `
                    -DiscussionDigest $discussionDigest `
                    -BodyDigest $bodyDigest `
                    -ThreadAvailability available `
                    -ThreadId ([long]$entry.Thread.threadId) `
                    -CommentId (
                        [long]$entry.Comment.commentId) `
                    -ThreadStatus (
                        [string]$entry.Thread.status)
            if ($sameBody) {
                $counts.noOp++
            }
            else {
                $counts.unknown++
            }
            continue
        }
        if ($crossRule -or $ambiguous) {
            $classification = 'unknown'
            $reason = 'other-review-at-anchor'
            $counts.unknown++
        }
        elseif ($humanCurrent) {
            $classification = 'humanCovered'
            $reason = 'current-human-review-at-anchor'
            $counts.humanCovered++
        }
        else {
            $classification = 'wouldCreate'
            $reason = 'no-current-review-at-anchor'
            $counts.wouldCreate++
        }
        $finding.providerMarker =
            New-OwnerProviderMarker `
                -Value $marker -Integrity verified
        $finding.reconciliation =
            New-OwnerV2DiscussionReconciliation `
                -Classification $classification `
                -Reason $reason `
                -DiscussionDigest $discussionDigest `
                -BodyDigest $bodyDigest
    }
    $Observation.effects.dedupe = $counts
    $Observation.findingsComplete =
        [string]$Observation.lifecycle.status -ceq
            'completed' -and
        $counts.unknown -eq 0
    $artifacts =
        [Collections.Generic.List[object]]::new()
    foreach ($artifact in @(
            $Observation.sourceArtifacts)) {
        if ([string](Get-OwnerV2Member `
                -Value $artifact -Name kind) -cnotin @(
                'owner-v2-discussion-snapshot',
                'owner-v2-discussion-mapping',
                'owner-v2-discussion-reviewer-identity',
                'owner-v2-discussion-raw-page'
            )) {
            [void]$artifacts.Add($artifact)
        }
    }
    if ($available) {
        [void]$artifacts.Add([ordered]@{
                kind =
                    'owner-v2-discussion-snapshot'
                sha256 =
                    $Snapshot.Digest.Substring(10)
                signature = 'not-applicable'
            })
        if ([string]$Snapshot.MappingDigest -match
            $script:OwnerV2DigestPattern) {
            [void]$artifacts.Add([ordered]@{
                    kind =
                        'owner-v2-discussion-mapping'
                    sha256 = ([string]$Snapshot.
                        MappingDigest).Substring(10)
                    signature = 'not-applicable'
                })
        }
        if ([string]$Snapshot.
            ReviewerIdentityDigest -match
            $script:OwnerV2DigestPattern) {
            [void]$artifacts.Add([ordered]@{
                    kind =
                        'owner-v2-discussion-reviewer-identity'
                    sha256 = ([string]$Snapshot.
                        ReviewerIdentityDigest).
                        Substring(10)
                    signature = 'not-applicable'
                })
        }
        foreach ($rawDigest in @(
                $Snapshot.RawProvenanceDigests)) {
            if ([string]$rawDigest -match
                $script:OwnerV2DigestPattern) {
                [void]$artifacts.Add([ordered]@{
                        kind =
                            'owner-v2-discussion-raw-page'
                        sha256 = ([string]$rawDigest).
                            Substring(10)
                        signature =
                            'not-applicable'
                    })
            }
        }
    }
    $Observation.sourceArtifacts = @($artifacts)
    return $Observation
}

function New-OwnerV2DiscussionReconciliation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('wouldCreate', 'wouldUpdate', 'noOp', 'humanCovered', 'unknown')]
        [string]$Classification,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$DiscussionDigest,
        [Parameter(Mandatory)][string]$BodyDigest,
        [ValidateSet('none', 'available', 'ambiguous')][string]$ThreadAvailability = 'none',
        [long]$ThreadId = 0,
        [long]$CommentId = 0,
        [string]$ThreadStatus = 'unknown'
    )

    return [ordered]@{
        classification = $Classification
        reason = $Reason
        bodySha256 = $BodyDigest
        discussionSha256 = $DiscussionDigest
        thread = [ordered]@{
            availability = $ThreadAvailability
            threadId = $(if ($ThreadAvailability -ceq 'available') { $ThreadId } else { 'unknown' })
            commentId = $(if ($ThreadAvailability -ceq 'available') { $CommentId } else { 'unknown' })
            status = $(if ($ThreadAvailability -ceq 'available') { $ThreadStatus } else { 'unknown' })
        }
    }
}

function Resolve-NamedAreEqualDiscussionReconciliation {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][object]$Contract,
        [AllowNull()][DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]$Snapshot,
        [Parameter(Mandatory)][string]$FailureReason
    )

    $counts = [ordered]@{
        created = 0
        updated = 0
        noOp = 0
        wouldCreate = 0
        wouldUpdate = 0
        unknown = 0
        humanCovered = 0
    }
    $snapshotAvailable = $null -ne $Snapshot -and
        $Snapshot.State -ceq 'complete' -and
        $Snapshot.Digest -match $script:OwnerV2DigestPattern
    $discussionDigest = if ($snapshotAvailable) {
        $Snapshot.Digest.Substring(10)
    }
    else { 'unknown' }
    $targetPattern =
        '<!--\s*devpilot-named-areequal:v1:([0-9a-f]{64})\s*-->'
    $anyMarkerPattern =
        '<!--\s*devpilot-(?:owner-comment|test-class-coverage|redundant-method-coverage|named-areequal):v1:[0-9a-f]{64}\s*-->'

    foreach ($finding in @($Observation.findings)) {
        try {
            $marker = Get-NamedAreEqualMarkerKey `
                -Contract $Contract -Finding $finding
            $body = Format-NamedAreEqualComment `
                -Contract $Contract -Finding $finding -MarkerKey $marker
        }
        catch {
            $finding.providerMarker = New-OwnerProviderMarker
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason 'marker-derivation-failed' `
                -DiscussionDigest $discussionDigest -BodyDigest 'unknown'
            $counts.unknown++
            continue
        }
        $bodyDigest = Get-OwnerV1WriterSha256 -Text $body
        if (-not $snapshotAvailable) {
            $finding.providerMarker = New-OwnerProviderMarker
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason $FailureReason `
                -DiscussionDigest unknown -BodyDigest $bodyDigest
            $counts.unknown++
            continue
        }

        $markerEntries = [Collections.Generic.List[object]]::new()
        $foreignMarker = $false
        $ambiguousIdentity = $false
        foreach ($thread in @($Snapshot.Threads)) {
            foreach ($comment in @($thread.comments)) {
                if ([string]$comment.commentType -cne 'text' -or
                    [bool]$comment.isDeleted) {
                    continue
                }
                $matches = [regex]::Matches(
                    [string]$comment.body, $targetPattern)
                $target = @($matches | Where-Object {
                        $_.Groups[1].Value -ceq $marker
                    })
                if ($target.Count -eq 0) { continue }
                if ([string]$comment.reviewerIdentityState -ceq 'ambiguous') {
                    $ambiguousIdentity = $true
                    continue
                }
                if (-not [bool]$comment.reviewerOwned) {
                    $foreignMarker = $true
                    continue
                }
                [void]$markerEntries.Add([pscustomobject]@{
                        Thread = $thread
                        Comment = $comment
                        Count = $target.Count
                    })
            }
        }

        if ($ambiguousIdentity -or $foreignMarker -or
            $markerEntries.Count -gt 1 -or
            ($markerEntries.Count -eq 1 -and
                [int]$markerEntries[0].Count -ne 1)) {
            $finding.providerMarker = New-OwnerProviderMarker `
                -Value $marker -Integrity invalid
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason 'duplicate-or-foreign-reviewer-marker' `
                -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest `
                -ThreadAvailability ambiguous
            $counts.unknown++
            continue
        }

        if ($markerEntries.Count -eq 0) {
            $affected = @($finding.affectedCallLines)
            $currentHuman = [Collections.Generic.List[object]]::new()
            $historicalHuman = [Collections.Generic.List[object]]::new()
            $crossRuleMarker = $false
            $ambiguousHuman = $false
            foreach ($thread in @($Snapshot.Threads)) {
                if ($null -eq $thread.anchor -or
                    [string]$thread.anchor.path -ine [string]$finding.anchor.path -or
                    [int]$thread.anchor.line -notin $affected) {
                    continue
                }
                foreach ($comment in @($thread.comments)) {
                    if ([string]$comment.commentType -cne 'text' -or
                        [bool]$comment.isDeleted) {
                        continue
                    }
                    if ([regex]::IsMatch(
                            [string]$comment.body, $anyMarkerPattern)) {
                        if (-not [bool]$thread.isDeleted -and
                            -not [bool]$thread.isOutdated -and
                            [string]$thread.status -ceq 'active' -and
                            [string]$thread.contextState -ceq 'current' -and
                            [string]$thread.sourceCommit -ceq
                                [string]$Contract.Request.SourceCommit) {
                            $crossRuleMarker = $true
                        }
                        continue
                    }
                    $text = [string]$comment.body
                    $affirmative = $text -notmatch '\?' -and
                        $text -notmatch
                            '(?i)\b(?:do\s+not|don''t|shouldn''t|avoid|never)\s+(?:use|name|add)\b' -and
                        $text -match '(?i)\b(?:named|name|label|explicit)\b' -and
                        $text -match
                            '(?i)\b(?:arguments?|parameters?|expected|actual)\b' -and
                        ($text -match
                            '(?i)\b(?:AreEqual|assert|expected|actual)\b' -or
                            $text -match
                            '(?i)^\s*(?:please\s+)?(?:use|add|prefer)\s+(?:the\s+)?named\s+(?:arguments?|parameters?)\s*[.!]?\s*$')
                    if (-not $affirmative) { continue }
                    if ([string]$comment.reviewerIdentityState -ceq
                        'ambiguous') {
                        $ambiguousHuman = $true
                        continue
                    }
                    $current = -not [bool]$thread.isDeleted -and
                        -not [bool]$thread.isOutdated -and
                        [string]$thread.status -ceq 'active' -and
                        [string]$thread.contextState -ceq 'current' -and
                        [string]$thread.sourceCommit -ceq
                            [string]$Contract.Request.SourceCommit
                    if ($current) {
                        [void]$currentHuman.Add([pscustomobject]@{
                                Thread = $thread
                                Comment = $comment
                            })
                    }
                    else {
                        [void]$historicalHuman.Add([pscustomobject]@{
                                Thread = $thread
                                Comment = $comment
                            })
                    }
                }
            }
            if ($crossRuleMarker) {
                $classification = 'unknown'
                $reason = 'cross-rule-marker-at-anchor'
            }
            elseif ($ambiguousHuman) {
                $classification = 'unknown'
                $reason = 'human-reviewer-identity-ambiguous'
            }
            elseif ($currentHuman.Count -gt 0) {
                $classification = 'humanCovered'
                $reason = 'current-human-review-covers-method'
            }
            elseif ($historicalHuman.Count -gt 0) {
                $classification = 'unknown'
                $reason = 'historical-human-review-needs-review'
            }
            else {
                $classification = 'wouldCreate'
                $reason = 'reviewer-marker-not-found'
            }
            $integrity = if ($classification -cin @(
                    'wouldCreate', 'humanCovered')) {
                'verified'
            }
            else { 'invalid' }
            $finding.providerMarker = New-OwnerProviderMarker `
                -Value $marker -Integrity $integrity
            $matchedHuman = if ($classification -ceq 'humanCovered') {
                $currentHuman[0]
            }
            elseif ($reason -ceq 'historical-human-review-needs-review') {
                $historicalHuman[0]
            }
            else { $null }
            $arguments = @{
                Classification = $classification
                Reason = $reason
                DiscussionDigest = $discussionDigest
                BodyDigest = $bodyDigest
            }
            if ($null -ne $matchedHuman) {
                $arguments.ThreadAvailability = 'available'
                $arguments.ThreadId = [long]$matchedHuman.Thread.threadId
                $arguments.CommentId = [long]$matchedHuman.Comment.commentId
                $arguments.ThreadStatus = [string]$matchedHuman.Thread.status
            }
            $finding['reconciliation'] =
                New-OwnerV2DiscussionReconciliation @arguments
            $counts[$classification]++
            continue
        }

        $entry = $markerEntries[0]
        $thread = $entry.Thread
        $comment = $entry.Comment
        $trusted = $null -ne $thread.anchor -and
            [string]$thread.anchor.path -ieq [string]$finding.anchor.path -and
            [int]$thread.anchor.line -eq [int]$finding.anchor.line -and
            -not [bool]$thread.isDeleted -and
            -not [bool]$thread.isOutdated -and
            [string]$thread.status -ceq 'active' -and
            [string]$thread.contextState -ceq 'current' -and
            [string]$thread.sourceCommit -ceq
                [string]$Contract.Request.SourceCommit
        $legacyBody = Format-NamedAreEqualComment -Contract $Contract `
            -Finding $finding -MarkerKey $marker -Legacy
        $classification = if ($trusted -and (
            [string]$comment.body -ceq $body -or
            [string]$comment.body -ceq $legacyBody)) {
            'noOp'
        }
        else { 'unknown' }
        $reason = if ($classification -ceq 'noOp') {
            'reviewer-marker-body-current'
        }
        else { 'reviewer-marker-generation-unknown' }
        $finding.providerMarker = New-OwnerProviderMarker `
            -Value $marker -Integrity $(if ($classification -ceq 'noOp') {
                'verified'
            } else { 'invalid' })
        $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
            -Classification $classification -Reason $reason `
            -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest `
            -ThreadAvailability available -ThreadId ([long]$thread.threadId) `
            -CommentId ([long]$comment.commentId) `
            -ThreadStatus ([string]$thread.status)
        $counts[$classification]++
    }

    $Observation.effects.dedupe = $counts
    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @($Observation.sourceArtifacts)) {
        if ([string](Get-OwnerV2Member -Value $artifact -Name kind) -cnotin @(
                'owner-v2-discussion-snapshot',
                'owner-v2-discussion-mapping',
                'owner-v2-discussion-reviewer-identity',
                'owner-v2-discussion-raw-page'
            )) {
            [void]$artifacts.Add($artifact)
        }
    }
    if ($snapshotAvailable) {
        [void]$artifacts.Add([ordered]@{
                kind = 'owner-v2-discussion-snapshot'
                sha256 = $Snapshot.Digest.Substring(10)
                signature = 'not-applicable'
            })
        if ([string]$Snapshot.MappingDigest -match $script:OwnerV2DigestPattern) {
            [void]$artifacts.Add([ordered]@{
                    kind = 'owner-v2-discussion-mapping'
                    sha256 = ([string]$Snapshot.MappingDigest).Substring(10)
                    signature = 'not-applicable'
                })
        }
        if ([string]$Snapshot.ReviewerIdentityDigest -match
            $script:OwnerV2DigestPattern) {
            [void]$artifacts.Add([ordered]@{
                    kind = 'owner-v2-discussion-reviewer-identity'
                    sha256 =
                        ([string]$Snapshot.ReviewerIdentityDigest).Substring(10)
                    signature = 'not-applicable'
                })
        }
        foreach ($rawDigest in @($Snapshot.RawProvenanceDigests)) {
            if ([string]$rawDigest -match $script:OwnerV2DigestPattern) {
                [void]$artifacts.Add([ordered]@{
                        kind = 'owner-v2-discussion-raw-page'
                        sha256 = ([string]$rawDigest).Substring(10)
                        signature = 'not-applicable'
                    })
            }
        }
    }
    $Observation.sourceArtifacts = @($artifacts)
    return $Observation
}

function Resolve-OwnerV2DiscussionReconciliation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][object]$Contract,
        [AllowNull()][DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]$Snapshot,
        [ValidatePattern('^[a-z][a-z0-9-]{0,127}$')]
        [string]$FailureReason = 'discussion-acquisition-unavailable',
        [AllowEmptyCollection()]
        [object[]]$AuthenticatedPriorComments = @()
    )

    $Observation.sourceArtifacts = @($Observation.sourceArtifacts | Where-Object {
        [string](Get-OwnerV2Member -Value $_ -Name kind) -cne
            'owner-v2-comment-presentation'
    })
    if ($null -ne (Get-OwnerV2Member -Value $Contract -Name CommentPresentation)) {
        $Observation.sourceArtifacts += [ordered]@{
            kind = 'owner-v2-comment-presentation'
            sha256 = Get-OwnerV1WriterSha256 -Text 'owner-v2-comment-presentation:subject-provider-links-v1'
            signature = 'not-applicable'
        }
    }
    if ([string](Get-OwnerV2Member -Value $Observation -Name capability) -ceq
        $script:NamedAreEqualCapability) {
        return Resolve-NamedAreEqualDiscussionReconciliation `
            -Observation $Observation -Contract $Contract -Snapshot $Snapshot `
            -FailureReason $FailureReason
    }
    if ([string](Get-OwnerV2Member -Value $Observation -Name capability) -ceq
        $script:ContextualCapability) {
        return Resolve-ContextualConventionDiscussionReconciliation `
            -Observation $Observation -Contract $Contract `
            -Snapshot $Snapshot -FailureReason $FailureReason `
            -AuthenticatedPriorComments $AuthenticatedPriorComments
    }

    $findings = @($Observation.findings)
    if ($findings.Count -eq 0 -or
        [string]$Observation.lifecycle.status -cne 'completed') {
        return $Observation
    }
    $counts = [ordered]@{
        created = 0
        updated = 0
        noOp = 0
        wouldCreate = 0
        wouldUpdate = 0
        unknown = 0
    }
    $snapshotAvailable = $null -ne $Snapshot -and
        $Snapshot.State -ceq 'complete' -and
        $Snapshot.Digest -match $script:OwnerV2DigestPattern
    $discussionDigest = if ($snapshotAvailable) {
        $Snapshot.Digest.Substring(10)
    }
    else {
        'unknown'
    }
    $allMarkerPattern = '<!--\s*devpilot-owner-comment:v1:([0-9a-f]{64})\s*-->'

    foreach ($finding in $findings) {
        $markerKey = $null
        $body = $null
        try {
            $markerKey = Get-OwnerV1WriterMarkerKey -Contract $Contract -Finding $finding
            $body = Format-OwnerV1WriterComment -Contract $Contract -Finding $finding `
                -MarkerKey $markerKey
        }
        catch {
            $finding.providerMarker = New-OwnerProviderMarker
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason 'marker-derivation-failed' `
                -DiscussionDigest $discussionDigest -BodyDigest 'unknown'
            $counts.unknown++
            continue
        }

        $bodyDigest = Get-OwnerV1WriterSha256 -Text $body
        if (-not $snapshotAvailable) {
            $finding.providerMarker = New-OwnerProviderMarker
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason $FailureReason `
                -DiscussionDigest 'unknown' -BodyDigest $bodyDigest
            $counts.unknown++
            continue
        }

        $candidates = [Collections.Generic.List[object]]::new()
        $ambiguousReviewerMarkers = 0
        foreach ($thread in @($Snapshot.Threads)) {
            foreach ($comment in @($thread.comments)) {
                $matches = [regex]::Matches([string]$comment.body, $allMarkerPattern)
                $targetMatches = @($matches | Where-Object {
                        $_.Groups[1].Value -ceq $markerKey
                    })
                if ($targetMatches.Count -eq 0 -or
                    [string]$comment.commentType -cne 'text' -or
                    [bool]$comment.isDeleted) {
                    continue
                }
                if ([string]$comment.reviewerIdentityState -ceq 'ambiguous') {
                    $ambiguousReviewerMarkers += $targetMatches.Count
                    continue
                }
                if ([bool]$comment.reviewerOwned) {
                    [void]$candidates.Add([pscustomobject]@{
                        Thread = $thread
                        Comment = $comment
                        MarkerCount = $targetMatches.Count
                    })
                }
            }
        }

        if ($ambiguousReviewerMarkers -gt 0) {
            $finding.providerMarker = New-OwnerProviderMarker -Value $markerKey -Integrity invalid
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason 'reviewer-marker-owner-ambiguous' `
                -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest `
                -ThreadAvailability ambiguous
            $counts.unknown++
            continue
        }
        if ($candidates.Count -eq 0) {
            $finding.providerMarker = New-OwnerProviderMarker -Value $markerKey -Integrity verified
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification wouldCreate -Reason 'reviewer-marker-not-found' `
                -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest
            $counts.wouldCreate++
            continue
        }
        if ($candidates.Count -ne 1 -or [int]$candidates[0].MarkerCount -ne 1) {
            $finding.providerMarker = New-OwnerProviderMarker -Value $markerKey -Integrity invalid
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason 'duplicate-reviewer-markers' `
                -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest `
                -ThreadAvailability ambiguous
            $counts.unknown++
            continue
        }

        $candidate = $candidates[0]
        $thread = $candidate.Thread
        $comment = $candidate.Comment
        $anchor = Get-OwnerV2Member -Value $finding -Name anchor
        $expectedPath = ConvertTo-OwnerV1WriterPath -Path (
            [string](Get-OwnerV2Member -Value $anchor -Name path)
        )
        try {
            $actualPath = if ($null -ne $thread.anchor) {
                ConvertTo-OwnerV1WriterPath -Path ([string]$thread.anchor.path)
            }
            else {
                ''
            }
        }
        catch {
            $finding.providerMarker = New-OwnerProviderMarker -Value $markerKey -Integrity invalid
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason 'reviewer-marker-anchor-unreadable' `
                -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest `
                -ThreadAvailability available -ThreadId ([long]$thread.threadId) `
                -CommentId ([long]$comment.commentId) -ThreadStatus ([string]$thread.status)
            $counts.unknown++
            continue
        }
        $trusted = [string]::Equals(
            $expectedPath,
            $actualPath,
            [StringComparison]::OrdinalIgnoreCase
        ) -and
            [int]$thread.anchor.line -eq [int](Get-OwnerV2Member -Value $anchor -Name line)
        if (-not $trusted) {
            $finding.providerMarker = New-OwnerProviderMarker -Value $markerKey -Integrity invalid
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason 'reviewer-marker-owner-or-anchor-mismatch' `
                -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest `
                -ThreadAvailability available -ThreadId ([long]$thread.threadId) `
                -CommentId ([long]$comment.commentId) -ThreadStatus ([string]$thread.status)
            $counts.unknown++
            continue
        }
        if ([string]$thread.contextState -ceq 'ambiguous') {
            $finding.providerMarker = New-OwnerProviderMarker -Value $markerKey -Integrity invalid
            $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
                -Classification unknown -Reason 'reviewer-marker-context-ambiguous' `
                -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest `
                -ThreadAvailability available -ThreadId ([long]$thread.threadId) `
                -CommentId ([long]$comment.commentId) -ThreadStatus ([string]$thread.status)
            $counts.unknown++
            continue
        }
        $classification = $null
        $reason = $null
        if ([bool]$thread.isDeleted) {
            $classification = 'wouldCreate'
            $reason = 'reviewer-marker-thread-deleted'
        }
        elseif ([bool]$thread.isOutdated) {
            $classification = 'wouldCreate'
            $reason = 'reviewer-marker-thread-outdated'
        }
        elseif ([string]$thread.status -cin @('fixed', 'closed', 'resolved')) {
            $classification = 'wouldCreate'
            $reason = 'reviewer-marker-thread-inactive'
        }
        elseif ([string]$thread.status -cne 'active') {
            $classification = 'unknown'
            $reason = 'reviewer-marker-thread-status-unknown'
        }
        elseif ([string]$comment.body -ceq $body -or
            [string]$comment.body -ceq (
                Format-OwnerV1WriterComment -Contract $Contract `
                    -Finding $finding -MarkerKey $markerKey -Legacy)) {
            $classification = 'noOp'
            $reason = 'reviewer-marker-body-current'
        }
        else {
            $classification = 'wouldUpdate'
            $reason = 'reviewer-marker-body-stale'
        }
        $integrity = if ($classification -ceq 'unknown') { 'invalid' } else { 'verified' }
        $finding.providerMarker = New-OwnerProviderMarker -Value $markerKey -Integrity $integrity
        $finding['reconciliation'] = New-OwnerV2DiscussionReconciliation `
            -Classification $classification -Reason $reason `
            -DiscussionDigest $discussionDigest -BodyDigest $bodyDigest `
            -ThreadAvailability available -ThreadId ([long]$thread.threadId) `
            -CommentId ([long]$comment.commentId) -ThreadStatus ([string]$thread.status)
        $counts[$classification]++
    }

    $Observation.effects.dedupe = $counts
    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($artifact in @($Observation.sourceArtifacts)) {
        if ([string](Get-OwnerV2Member -Value $artifact -Name kind) -cnotin @(
                'owner-v2-discussion-snapshot',
                'owner-v2-discussion-mapping',
                'owner-v2-discussion-reviewer-identity',
                'owner-v2-discussion-raw-page'
            )) {
            [void]$artifacts.Add($artifact)
        }
    }
    if ($snapshotAvailable) {
        [void]$artifacts.Add([ordered]@{
                kind = 'owner-v2-discussion-snapshot'
                sha256 = $Snapshot.Digest.Substring(10)
                signature = 'not-applicable'
            })
        if ([string]$Snapshot.MappingDigest -match $script:OwnerV2DigestPattern) {
            [void]$artifacts.Add([ordered]@{
                    kind = 'owner-v2-discussion-mapping'
                    sha256 = ([string]$Snapshot.MappingDigest).Substring(10)
                    signature = 'not-applicable'
                })
        }
        if ([string]$Snapshot.ReviewerIdentityDigest -match $script:OwnerV2DigestPattern) {
            [void]$artifacts.Add([ordered]@{
                    kind = 'owner-v2-discussion-reviewer-identity'
                    sha256 = ([string]$Snapshot.ReviewerIdentityDigest).Substring(10)
                    signature = 'not-applicable'
                })
        }
        foreach ($rawDigest in @($Snapshot.RawProvenanceDigests)) {
            if ([string]$rawDigest -match $script:OwnerV2DigestPattern) {
                [void]$artifacts.Add([ordered]@{
                        kind = 'owner-v2-discussion-raw-page'
                        sha256 = ([string]$rawDigest).Substring(10)
                        signature = 'not-applicable'
                    })
            }
        }
    }
    $Observation.sourceArtifacts = @($artifacts)
    return $Observation
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

function Get-OwnerV2NonEligibleConstructs {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$FileData,
        [Parameter(Mandatory)][DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits
    )

    $content = Get-OwnerV2Member -Value $FileData -Name content
    $spans = @((Get-OwnerV2Member -Value $FileData -Name spans) | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name state) -ceq 'complete'
        })
    if ($content -isnot [string] -or $spans.Count -eq 0) { return @() }

    $lines = [regex]::Split($content, '\r?\n')
    $maskedLines = [Collections.Generic.List[string]]::new()
    $inBlockComment = $false
    $inVerbatimString = $false
    $rawDelimiterLength = 0
    $commentLines = [Collections.Generic.HashSet[int]]::new()
    foreach ($line in $lines) {
        $lineNumber = $maskedLines.Count + 1
        $wasInVerbatimString = $inVerbatimString
        $startsInMaskedRegion = $inBlockComment -or $wasInVerbatimString -or $rawDelimiterLength -gt 0
        $withoutComments = Remove-OwnerV2Comments -Text ([string]$line) `
            -InBlockComment ([ref]$inBlockComment) `
            -InVerbatimString ([ref]$inVerbatimString) `
            -RawDelimiterLength ([ref]$rawDelimiterLength)
        if ($wasInVerbatimString -and -not $inVerbatimString) {
            $withoutComments = $withoutComments -replace '"', ' '
        }
        if (-not $startsInMaskedRegion -and ([string]$line).TrimStart().StartsWith('//')) {
            [void]$commentLines.Add($lineNumber)
        }
        [void]$maskedLines.Add((Remove-OwnerV2StringLiterals -Text $withoutComments))
    }

    $constructs = [Collections.Generic.List[object]]::new()
    $lineNumber = 1
    while ($lineNumber -le $lines.Count) {
        if (-not $commentLines.Contains($lineNumber) -or
            -not (Test-OwnerV2ChangedRange -StartLine $lineNumber -EndLine $lineNumber -Spans $spans)) {
            $lineNumber++
            continue
        }
        $startLine = $lineNumber
        while ($lineNumber + 1 -le $lines.Count -and
            $commentLines.Contains($lineNumber + 1) -and
            (Test-OwnerV2ChangedRange -StartLine ($lineNumber + 1) -EndLine ($lineNumber + 1) -Spans $spans)) {
            $lineNumber++
        }
        [void]$constructs.Add([ordered]@{
                kind = 'comment'
                name = 'comment'
                startLine = $startLine
                declarationLine = $lineNumber
                attributes = @()
                hasOwner = $false
                snippet = (@($lines[($startLine - 1)..($lineNumber - 1)]) -join "`n")
                bounded = $true
                recognized = $true
            })
        $lineNumber++
    }

    for ($index = 0; $index -lt $maskedLines.Count; $index++) {
        $startLine = $index + 1
        if (-not (Test-OwnerV2ChangedRange -StartLine $startLine -EndLine $startLine -Spans $spans)) {
            continue
        }
        $masked = ([string]$maskedLines[$index]).Trim()
        if ($masked.EndsWith(';') -and
            $masked -match '^([A-Za-z_][A-Za-z0-9_]*(?:\s*(?:\.|\?\.)\s*[A-Za-z_][A-Za-z0-9_]*|\s*\[[^\[\]]*\])*)\s*=([^=].*|)$' -and
            -not ([string]$Matches[2]).StartsWith('>')) {
            $target = ($Matches[1] -replace '\s+', '')
            [void]$constructs.Add([ordered]@{
                    kind = 'assignment'
                    name = $target
                    startLine = $startLine
                    declarationLine = $startLine
                    attributes = @()
                    hasOwner = $false
                    snippet = ([string]$lines[$index]).Trim()
                    bounded = $masked.Length -le $Limits.MaximumSnippetCharacters
                    recognized = $true
                })
        }

        $depth = 0
        $openIndex = -1
        for ($column = $masked.Length - 1; $column -ge 0; $column--) {
            if ($masked[$column] -eq ')') { $depth++; continue }
            if ($masked[$column] -ne '(') { continue }
            if ($depth -gt 0) { $depth--; continue }
            $before = $masked.Substring(0, $column).TrimEnd()
            if ($before -match '[A-Za-z0-9_>\]]$') { $openIndex = $column }
        }
        if ($openIndex -lt 0) { continue }
        $calleeText = $masked.Substring(0, $openIndex).TrimEnd()
        if ($calleeText -notmatch '([A-Za-z_][A-Za-z0-9_]*)\s*(<[^<>]*>)?$') { continue }
        $callee = $Matches[1]
        if ($callee -in @('if', 'for', 'foreach', 'while', 'switch', 'using', 'lock', 'catch')) {
            continue
        }
        $depth = 1
        $closed = $false
        for ($column = $openIndex + 1; $column -lt $masked.Length; $column++) {
            if ($masked[$column] -eq '(') { $depth++ }
            elseif ($masked[$column] -eq ')') {
                $depth--
                if ($depth -eq 0) { $closed = $true; break }
            }
        }
        if ($closed) { continue }
        $endLine = $startLine
        for ($scan = $index + 1; $scan -lt $maskedLines.Count; $scan++) {
            $scanLine = [string]$maskedLines[$scan]
            foreach ($character in $scanLine.ToCharArray()) {
                if ($character -eq '(') { $depth++ }
                elseif ($character -eq ')') {
                    $depth--
                    if ($depth -eq 0) { $closed = $true; break }
                }
            }
            $endLine = $scan + 1
            if ($closed -or $endLine - $startLine -ge 64) { break }
        }
        if (-not $closed) { continue }
        $snippet = @($lines[$index..($endLine - 1)]) -join "`n"
        [void]$constructs.Add([ordered]@{
                kind = 'invocation'
                name = $callee
                startLine = $startLine
                declarationLine = $endLine
                attributes = @()
                hasOwner = $false
                snippet = $snippet
                bounded = $snippet.Length -le $Limits.MaximumSnippetCharacters
                recognized = $true
            })
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
                data = [ordered]@{
                    state = 'uncovered'
                    reason = 'required-evidence-unavailable'
                    constructRef = 'evidence:' + (Get-OwnerV2Digest -Value "$BindingId|$unitId").Substring(10)
                }
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
                    data = [ordered]@{
                        state = 'uncovered'
                        reason = 'file-evidence-unavailable'
                        constructRef = 'file:' + (Get-OwnerV2Digest -Value "$bindingId|$fileUnitId").Substring(10)
                    }
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
                    data = [ordered]@{
                        state = 'uncovered'
                        reason = 'semantic-unit-cap-exhausted'
                        constructRef = 'file:' + (Get-OwnerV2Digest -Value "$bindingId|$fileUnitId").Substring(10)
                    }
                    findings = @()
                })
            continue
        }
        $semanticUnitCount += $constructs.Count
        $constructs += @(Get-OwnerV2NonEligibleConstructs -FileData $fileData -Limits $Limits)

        foreach ($construct in $constructs) {
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

            if ($construct.kind -notin @('method', 'class')) {
                [void]$assessments.Add([ordered]@{
                        assessmentId = $assessmentId
                        evidenceUnitIds = $atomicEvidenceIds
                        state = 'complete'
                        data = [ordered]@{
                            state = 'notEligible'
                            reason = 'owner-rule-applies-only-to-test-classes-and-methods'
                            constructRef = $constructRef
                            path = $path
                            startLine = [int]$construct.startLine
                            endLine = [int]$construct.declarationLine
                            symbol = [string]$construct.name
                        }
                        findings = @()
                    })
                continue
            }
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
                        data = [ordered]@{
                            state = $(if ($construct.kind -ceq 'class') { 'advisory' } else { 'unknown' })
                            reason = $(if ($construct.kind -ceq 'class') {
                                    'class-advisory-only'
                                }
                                elseif (-not [bool]$construct.bounded) {
                                    'construct-snippet-unbounded'
                                }
                                else {
                                    'construct-unrecognized'
                                })
                            constructRef = $constructRef
                            path = $path
                            startLine = [int]$construct.startLine
                            endLine = [int]$construct.declarationLine
                            symbol = [string]$construct.name
                        }
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
                    data = $(if ($assessmentState -ceq 'unknown') {
                            [ordered]@{
                                state = 'unknown'
                                reason = $(if ($judgment.Failure) {
                                        [string]$judgment.Failure
                                    }
                                    else {
                                        'semantic-judgment-unknown'
                                    })
                                constructRef = $constructRef
                                path = $path
                                startLine = [int]$construct.startLine
                                endLine = [int]$construct.declarationLine
                                symbol = [string]$construct.name
                            }
                        }
                        else { $null })
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

function Invoke-NamedAreEqualCapabilityResponse {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$CapabilityDigest,
        [Parameter(Mandatory)]
        [DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits
    )

    $binding = Get-OwnerV2Member -Value $Context -Name binding
    $evidence = Get-OwnerV2Member -Value $Context -Name evidence
    $bindingId = [string](Get-OwnerV2Member -Value $binding -Name BindingId)
    $evidenceDigest = [string](Get-OwnerV2Member -Value $evidence -Name evidenceDigest)
    $units = @(Get-OwnerV2Member -Value $evidence -Name evidenceUnits)
    if ([string]::IsNullOrWhiteSpace($bindingId) -or
        [string](Get-OwnerV2Member -Value $evidence -Name bindingId) -cne
            $bindingId -or
        $evidenceDigest -cnotmatch $script:OwnerV2DigestPattern) {
        throw 'Named AreEqual capability did not preserve the facade evidence binding.'
    }
    $identityUnits = @($units | Where-Object {
            [string]$_.unitId -ceq 'identity'
        })
    $ruleUnits = @($units | Where-Object {
            [string]$_.unitId -ceq 'rule'
        })
    $files = @($units | Where-Object {
            [string]$_.unitId -like 'file:*'
        } | Sort-Object { [string]$_.unitId })
    $diagnostics = [Collections.Generic.List[object]]::new()
    $policyPath = Join-Path $PSScriptRoot `
        'Policy\named-areequal-arguments.v1.txt'
    $policyText = [IO.File]::ReadAllText(
        $policyPath, [Text.UTF8Encoding]::new($false))
    $policyDigest = Get-OwnerV2Digest -Value $policyText
    if ($policyDigest -cne $script:NamedAreEqualPolicyDigest) {
        throw 'Named AreEqual policy no longer matches the pinned source-backed version.'
    }
    $controlsComplete =
        $identityUnits.Count -eq 1 -and
        $ruleUnits.Count -eq 1 -and
        [string]$identityUnits[0].state -ceq 'complete' -and
        [string]$ruleUnits[0].state -ceq 'complete' -and
        [string]$identityUnits[0].data.capabilityId -ceq
            $script:NamedAreEqualCapability -and
        [string]$identityUnits[0].data.capabilityDigest -ceq
            $CapabilityDigest -and
        [string]$ruleUnits[0].data.section -ceq
            $script:NamedAreEqualCapability -and
        [string]$ruleUnits[0].data.hash -ceq $policyDigest -and
        [string]$ruleUnits[0].data.content -ceq $policyText -and
        $files.Count -le $Limits.MaximumFiles
    if (-not $controlsComplete) {
        Add-OwnerV2Diagnostic -Diagnostics $diagnostics -Limits $Limits `
            -Code 'named-areequal-rule-evidence-unknown' `
            -Message 'The independently pinned named-argument policy, identity, or bounded files are unavailable.'
        return [ordered]@{
            schemaVersion = 1
            bindingId = $bindingId
            state = 'unknown'
            assessments = New-OwnerV2UnknownEvidenceAssessments `
                -EvidenceUnits $units -BindingId $bindingId
            diagnostics = @($diagnostics)
        }
    }

    $ruleData = $ruleUnits[0].data
    $ruleRef = 'rule:' + (Get-OwnerV2Digest -Value ([ordered]@{
                repositoryId = $ruleData.repositoryId
                path = $ruleData.path
                commit = $ruleData.commit
                section = $ruleData.section
                hash = $ruleData.hash
            })).Substring(10)
    $assessments = [Collections.Generic.List[object]]::new()
    [void]$assessments.Add([ordered]@{
            assessmentId =
                'binding:' + (Get-OwnerV2Digest -Value "$bindingId|$ruleRef").
                    Substring(10)
            evidenceUnitIds = @('identity', 'rule')
            state = 'complete'
            findings = @()
        })
    $constructCount = 0
    foreach ($file in $files) {
        $id = [string]$file.unitId
        $data = $file.data
        $path = [string](Get-OwnerV2Member -Value $data -Name path)
        $evidenceIds = @('identity', 'rule', $id)
        $spans = if ($data -is [Collections.IDictionary]) {
            @(Get-OwnerV2Member -Value $data -Name spans)
        }
        else { @() }
        if ([string]$file.state -cne 'complete' -or
            $data -isnot [Collections.IDictionary] -or
            $data.content -isnot [string] -or
            [string]::IsNullOrWhiteSpace($path) -or
            ($path.EndsWith('.cs', [StringComparison]::OrdinalIgnoreCase) -and
                ($spans.Count -eq 0 -or
                    @($spans | Where-Object {
                            [string]$_.state -cne 'complete'
                        }).Count -gt 0))) {
            [void]$assessments.Add([ordered]@{
                    assessmentId =
                        'file:' + (Get-OwnerV2Digest -Value "$bindingId|$id").
                            Substring(10)
                    evidenceUnitIds = $evidenceIds
                    state = 'unknown'
                    data = [ordered]@{
                        state = 'uncovered'
                        reason = 'file-evidence-unavailable'
                        constructRef =
                            'file:' + (Get-OwnerV2Digest `
                                -Value "$bindingId|$id").Substring(10)
                    }
                    findings = @()
                })
            continue
        }
        $constructs = @()
        if ($path.EndsWith('.cs', [StringComparison]::OrdinalIgnoreCase)) {
            $constructs = @(Get-NamedAreEqualConstructs `
                    -Content ([string]$data.content) -Spans $spans -Path $path)
        }
        if ($constructCount + $constructs.Count -gt
            $Limits.MaximumSemanticUnits) {
            Add-OwnerV2Diagnostic -Diagnostics $diagnostics -Limits $Limits `
                -Code 'named-areequal-construct-cap-exhausted' `
                -Message 'Changed assertion methods exceed the bounded construct capacity.' `
                -UnitId $id
            [void]$assessments.Add([ordered]@{
                    assessmentId =
                        'file:' + (Get-OwnerV2Digest -Value "$bindingId|$id").
                            Substring(10)
                    evidenceUnitIds = $evidenceIds
                    state = 'unknown'
                    data = [ordered]@{
                        state = 'uncovered'
                        reason = 'named-areequal-construct-cap-exhausted'
                        constructRef =
                            'file:' + (Get-OwnerV2Digest `
                                -Value "$bindingId|$id").Substring(10)
                    }
                    findings = @()
                })
            continue
        }
        $constructCount += $constructs.Count
        if ($constructs.Count -eq 0) {
            [void]$assessments.Add([ordered]@{
                    assessmentId =
                        'file:' + (Get-OwnerV2Digest -Value "$bindingId|$id").
                            Substring(10)
                    evidenceUnitIds = $evidenceIds
                    state = 'complete'
                    findings = @()
                })
        }
        foreach ($construct in $constructs) {
            $material = [ordered]@{
                bindingId = $bindingId
                evidenceDigest = $evidenceDigest
                capabilityId = $script:NamedAreEqualCapability
                capabilityDigest = $CapabilityDigest
                ruleRef = $ruleRef
                evidenceUnitId = $id
                path = $path
                name = [string]$construct.name
                startLine = [int]$construct.startLine
                declarationLine = [int]$construct.declarationLine
                endLine = [int]$construct.endLine
                recognized = [bool]$construct.recognized
                affectedCallCount = [int]$construct.affectedCallCount
                affectedCallLines = @($construct.affectedCallLines)
            }
            $digest = (Get-OwnerV2Digest -Value $material).Substring(10)
            $constructRef = "construct:$digest"
            $assessmentId = "method:n:$digest"
            $resolved = [bool]$construct.recognized -and
                -not [string]::IsNullOrWhiteSpace([string]$construct.name) -and
                [int]$construct.declarationLine -ge 1
            $state = if (-not $resolved) {
                'unknown'
            }
            elseif ([bool]$construct.hasPositional) {
                'violation'
            }
            else { 'compliant' }
            $finding = @()
            if ($state -ceq 'violation') {
                $findingData = [ordered]@{
                    disposition = 'violation'
                    eligibility = 'changed-assert-areequal-test-method'
                    capabilityId = $script:NamedAreEqualCapability
                    bindingId = $bindingId
                    evidenceDigest = $evidenceDigest
                    ruleRef = $ruleRef
                    constructRef = $constructRef
                    groupRef = $assessmentId
                    headCommit = [string]$identityUnits[0].data.sourceCommit
                    anchor = [ordered]@{
                        path = $path
                        line = [int]$construct.startLine
                        symbol = [string]$construct.name
                    }
                    affectedCallCount = [int]$construct.affectedCallCount
                    affectedCallLines = @($construct.affectedCallLines)
                    callListTruncated = [bool]$construct.callListTruncated
                }
                $finding = @([ordered]@{
                        findingId = 'named-areequal-v2:' +
                            (Get-OwnerV2Digest -Value ([ordered]@{
                                    bindingId = $bindingId
                                    capabilityId =
                                        $script:NamedAreEqualCapability
                                    ruleRef = $ruleRef
                                    constructRef = $constructRef
                                    disposition = 'violation'
                                })).Substring(10)
                        summary =
                            'Changed Assert.AreEqual calls in this test method require named arguments.'
                        data = $findingData
                    })
            }
            $outcomeData = if ($state -ceq 'violation') {
                $null
            }
            else {
                [ordered]@{
                    state = $state
                    reason = [string]$construct.reason
                    constructRef = $constructRef
                    path = $path
                    startLine = [int]$construct.startLine
                    endLine = [int]$construct.endLine
                    symbol = $(if ($resolved) {
                            [string]$construct.name
                        } else { 'unrecognized' })
                    affectedCallCount = [int]$construct.affectedCallCount
                }
            }
            [void]$assessments.Add([ordered]@{
                    assessmentId = $assessmentId
                    evidenceUnitIds = $evidenceIds
                    state = $(if ($state -ceq 'unknown') {
                            'unknown'
                        } else { 'complete' })
                    data = $outcomeData
                    findings = $finding
                })
        }
    }
    return [ordered]@{
        schemaVersion = 1
        bindingId = $bindingId
        state = $(if (@($assessments | Where-Object {
                        $_.state -ceq 'unknown'
                    }).Count) {
                'unknown'
            }
            else { 'complete' })
        assessments = @($assessments)
        diagnostics = @($diagnostics)
    }
}

function New-NamedAreEqualCapabilityAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest,
        [DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits =
            (New-OwnerV2CapabilityLimits)
    )

    if ($CapabilityId -cne $script:NamedAreEqualCapability -or
        $CapabilityDigest -cne $script:NamedAreEqualDigest) {
        throw 'Named AreEqual capability identity or digest is invalid.'
    }
    $capturedDigest = $CapabilityDigest
    $capturedLimits = $Limits
    $command = Get-Command Invoke-NamedAreEqualCapabilityResponse `
        -CommandType Function
    return New-OwnerPipelineAdapter -Stage capability `
        -Name 'named-areequal-v1-capability' -Handler {
        param($context)
        return & $command -Context $context `
            -CapabilityDigest $capturedDigest -Limits $capturedLimits
    }.GetNewClosure()
}

function Invoke-ContextualConventionsCapabilityResponse {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$CapabilityDigest,
        [Parameter(Mandatory)]
        [DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits
    )
    $binding = Get-OwnerV2Member `
        -Value $Context -Name binding
    $evidence = Get-OwnerV2Member `
        -Value $Context -Name evidence
    $bindingId = [string](Get-OwnerV2Member `
            -Value $binding -Name BindingId)
    $evidenceDigest = [string](Get-OwnerV2Member `
            -Value $evidence -Name evidenceDigest)
    $units = @(Get-OwnerV2Member `
            -Value $evidence -Name evidenceUnits)
    $identityUnits = @($units | Where-Object {
            [string]$_.unitId -ceq 'identity'
        })
    $ruleUnits = @($units | Where-Object {
            [string]$_.unitId -ceq 'rule'
        })
    $files = @($units | Where-Object {
            [string]$_.unitId -like 'file:*'
        } | Sort-Object { [string]$_.unitId })
    $pullRequests = @($units | Where-Object {
            [string]$_.unitId -ceq
                'pull-request'
        })
    $diagnostics =
        [Collections.Generic.List[object]]::new()
    $policyPath = Join-Path $PSScriptRoot `
        'Policy\contextual-conventions.v1.json'
    $policyText = [IO.File]::ReadAllText(
        $policyPath,
        [Text.UTF8Encoding]::new($false))
    $policyDigest =
        Get-OwnerV2Digest -Value $policyText
    $controlsComplete =
        -not [string]::IsNullOrWhiteSpace($bindingId) -and
        [string](Get-OwnerV2Member `
            -Value $evidence -Name bindingId) -ceq
                $bindingId -and
        $evidenceDigest -cmatch
            $script:OwnerV2DigestPattern -and
        $identityUnits.Count -eq 1 -and
        $ruleUnits.Count -eq 1 -and
        $pullRequests.Count -le 1 -and
        [string]$identityUnits[0].state -ceq
            'complete' -and
        [string]$ruleUnits[0].state -ceq
            'complete' -and
        [string]$identityUnits[0].data.
            capabilityId -ceq
                $script:ContextualCapability -and
        [string]$identityUnits[0].data.
            capabilityDigest -ceq
                $CapabilityDigest -and
        [string]$ruleUnits[0].data.section -ceq
            $script:ContextualCapability -and
        [string]$ruleUnits[0].data.hash -ceq
            $policyDigest -and
        [string]$ruleUnits[0].data.content -ceq
            $policyText -and
        $policyDigest -ceq
            $script:ContextualPolicyDigest -and
        $files.Count -le $Limits.MaximumFiles
    if (-not $controlsComplete) {
        Add-OwnerV2Diagnostic `
            -Diagnostics $diagnostics -Limits $Limits `
            -Code contextual-rule-evidence-unknown `
            -Message (
                'The independently pinned contextual rule ' +
                'bundle, identity, or bounded files are unavailable.')
        return [ordered]@{
            schemaVersion = 1
            bindingId = $bindingId
            state = 'unknown'
            assessments =
                New-OwnerV2UnknownEvidenceAssessments `
                    -EvidenceUnits $units `
                    -BindingId $bindingId
            diagnostics = @($diagnostics)
        }
    }
    $ruleData = $ruleUnits[0].data
    $ruleRef = 'rule:' +
        (Get-OwnerV2Digest -Value ([ordered]@{
                repositoryId =
                    $ruleData.repositoryId
                path = $ruleData.path
                commit = $ruleData.commit
                section = $ruleData.section
                hash = $ruleData.hash
            })).Substring(10)
    $assessments =
        [Collections.Generic.List[object]]::new()
    [void]$assessments.Add([ordered]@{
            assessmentId = 'binding:' +
                (Get-OwnerV2Digest -Value (
                    "$bindingId|$ruleRef")).
                Substring(10)
            evidenceUnitIds = @('identity', 'rule')
            state = 'complete'
            findings = @()
        })
    $pullRequestUnit = if (
        $pullRequests.Count -eq 1) {
        $pullRequests[0]
    }
    else {
        [ordered]@{
            state = 'complete'
            data = [ordered]@{
                applicable = $false
            }
        }
    }
    $pullRequestRuleId =
        'pr-template-compliance'
    if (-not [bool]$pullRequestUnit.data.
            applicable) {
        $notApplicableDigest = (
            Get-OwnerV2Digest -Value (
                "$bindingId|$ruleRef|$pullRequestRuleId|not-applicable")).
            Substring(10)
        [void]$assessments.Add([ordered]@{
                assessmentId =
                    "method:c:$notApplicableDigest"
                evidenceUnitIds =
                    @('identity', 'rule', 'pull-request')
                state = 'complete'
                data = $null
                findings = @()
            })
    }
    elseif ([string]$pullRequestUnit.state -cne
            'complete' -or
        $pullRequestUnit.data -isnot
            [Collections.IDictionary]) {
        $withheldDigest = (
            Get-OwnerV2Digest -Value (
                "$bindingId|$ruleRef|$pullRequestRuleId|withheld")).
            Substring(10)
        [void]$assessments.Add([ordered]@{
                assessmentId =
                    "method:c:$withheldDigest"
                evidenceUnitIds =
                    @('identity', 'rule', 'pull-request')
                state = 'unknown'
                data = [ordered]@{
                    state = 'unknown'
                    reason =
                        'pr-template-proof-withheld'
                    constructRef =
                        "construct:$withheldDigest"
                    ruleId =
                        $pullRequestRuleId
                }
                findings = @()
            })
    }
    else {
        $metadata = [ordered]@{
            state = 'complete'
            title =
                [string]$pullRequestUnit.data.title
            description =
                [string]$pullRequestUnit.data.description
            descriptionDigest =
                [string]$pullRequestUnit.data.descriptionDigest
            template =
                $pullRequestUnit.data.template
        }
        $templateOutcome =
            Get-ContextualPullRequestTemplateOutcome `
                -Metadata $metadata
        $templateMaterial = [ordered]@{
            bindingId = $bindingId
            evidenceDigest = $evidenceDigest
            capabilityId =
                $script:ContextualCapability
            capabilityDigest =
                $CapabilityDigest
            ruleRef = $ruleRef
            ruleId = $pullRequestRuleId
            evidenceUnitId = 'pull-request'
            descriptionDigest =
                [string]$metadata.descriptionDigest
            templatePath =
                [string]$metadata.template.path
            templateRef =
                [string]$metadata.template.configurationRef
            templateCommit =
                [string]$metadata.template.configurationCommit
            templateBlob =
                [string]$metadata.template.blob
            templateContentDigest =
                [string]$metadata.template.contentDigest
            state =
                [string]$templateOutcome.state
            reason =
                [string]$templateOutcome.reason
            missingSections =
                @($templateOutcome.missingSections)
        }
        $templateDigest = (
            Get-OwnerV2Digest `
                -Value $templateMaterial).
            Substring(10)
        $templateConstructRef =
            "construct:$templateDigest"
        $templateAssessmentId =
            "method:c:$templateDigest"
        $templateFinding = @()
        $templateOutcomeData = $null
        $templateAssessmentState = 'complete'
        if ([string]$templateOutcome.state -ceq
            'violation') {
            $issueMaterial = [ordered]@{
                repositoryId =
                    [string]$identityUnits[0].data.repositoryId
                pullRequestId =
                    [long]$identityUnits[0].data.pullRequestId
                ruleId = $pullRequestRuleId
                missingSections =
                    @($templateOutcome.missingSections |
                        Sort-Object)
                templatePath =
                    [string]$metadata.template.path
                templateRef =
                    [string]$metadata.template.configurationRef
                templateBlob =
                    [string]$metadata.template.blob
                templateContentDigest =
                    [string]$metadata.template.contentDigest
            }
            $issueIdentity = 'v1:sha256:' +
                (Get-OwnerV2Digest `
                    -Value $issueMaterial).
                Substring(10)
            $findingData = [ordered]@{
                disposition = 'violation'
                eligibility =
                    'pull-request-template-compliance'
                capabilityId =
                    $script:ContextualCapability
                bindingId = $bindingId
                evidenceDigest = $evidenceDigest
                ruleRef = $ruleRef
                ruleId = $pullRequestRuleId
                constructRef =
                    $templateConstructRef
                groupRef =
                    $templateAssessmentId
                headCommit =
                    [string]$identityUnits[0].data.sourceCommit
                anchor = [ordered]@{
                    scope = 'pull-request'
                    subject = 'description'
                }
                issueIdentity =
                    $issueIdentity
                missingSections =
                    @($templateOutcome.missingSections)
                descriptionSha256 =
                    ([string]$metadata.descriptionDigest).
                        Substring(10)
                template = [ordered]@{
                    path =
                        [string]$metadata.template.path
                    ref =
                        [string]$metadata.template.configurationRef
                    commit =
                        [string]$metadata.template.configurationCommit
                    blob =
                        [string]$metadata.template.blob
                    contentSha256 =
                        ([string]$metadata.template.contentDigest).
                            Substring(10)
                }
                evidence =
                    [string]$templateOutcome.evidence
                reason =
                    [string]$templateOutcome.reason
            }
            $templateFinding = @(
                [ordered]@{
                    findingId =
                        'contextual-v1:' +
                        (Get-OwnerV2Digest -Value (
                            [ordered]@{
                                bindingId = $bindingId
                                capabilityId =
                                    $script:ContextualCapability
                                ruleId =
                                    $pullRequestRuleId
                                constructRef =
                                    $templateConstructRef
                                disposition =
                                    'violation'
                            })).Substring(10)
                    summary =
                        [string]$templateOutcome.evidence
                    data = $findingData
                })
        }
        elseif ([string]$templateOutcome.state -ceq
            'unknown') {
            $templateAssessmentState = 'unknown'
            $templateOutcomeData = [ordered]@{
                state = 'unknown'
                reason =
                    [string]$templateOutcome.reason
                constructRef =
                    $templateConstructRef
                ruleId = $pullRequestRuleId
            }
        }
        [void]$assessments.Add([ordered]@{
                assessmentId =
                    $templateAssessmentId
                evidenceUnitIds =
                    @('identity', 'rule', 'pull-request')
                state =
                    $templateAssessmentState
                data = $templateOutcomeData
                findings = $templateFinding
            })
    }
    $snapshotFiles = [Collections.Generic.List[object]]::new()
    $snapshotPaths =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $context = Get-OwnerV2Member `
            -Value $file.data -Name projectContext
        $sourceState = Get-OwnerV2Member -Value $file.data -Name sourceState
        if ($null -eq $sourceState) { $sourceState = [string]$file.state }
        $snapshotFile = [ordered]@{
                path = [string]$file.data.path
                content = $(if (
                    [string]$sourceState -ceq 'complete' -and
                    $file.data.content -is [string]) {
                    [string]$file.data.content
                } else { '' })
                state = [string]$file.state
                spans = @($file.data.spans)
                sourceState = $(if (
                    [bool](Get-OwnerV2Member -Value $file.data -Name truncated) -or
                    [bool](Get-OwnerV2Member -Value $file.data -Name isBinary)) {
                    'unknown'
                } else { [string]$sourceState })
                changeType = [string](Get-OwnerV2Member -Value $file.data -Name changeType)
                fileHeader = Get-OwnerV2Member -Value $file.data -Name fileHeader
                sourceCommit = [string]$identityUnits[0].data.sourceCommit
                targetCommit = [string]$identityUnits[0].data.targetCommit
                oldPath = Get-OwnerV2Member -Value $file.data -Name oldPath
                comparison = Get-OwnerV2Member -Value $file.data -Name comparison
            }
        if ([bool](Get-OwnerV2Member -Value $file.data -Name contextOnly)) {
            $snapshotFile['contextOnly'] = $true
        }
        if ($context -is
                [Collections.IDictionary]) {
            $snapshotFile['projectContext'] =
                $context
        }
        [void]$snapshotFiles.Add(
            $snapshotFile)
        [void]$snapshotPaths.Add(
            [string]$file.data.path)
        if ($context -is
                [Collections.IDictionary] -and
            [string]$context.state -ceq 'complete' -and
            -not $snapshotPaths.Contains(
                [string]$context.path)) {
            [void]$snapshotFiles.Add(
                [ordered]@{
                    path = [string]$context.path
                    content = [string]$context.content
                    state = 'complete'
                    spans = @()
                    contextOnly = $true
                })
            [void]$snapshotPaths.Add(
                [string]$context.path)
        }
    }
    $withheldRules =
        [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
    $semanticCount = 0
    foreach ($file in $files) {
        $id = [string]$file.unitId
        $data = $file.data
        $path = [string]$data.path
        $evidenceIds = @('identity', 'rule', $id)
        if ([bool](Get-OwnerV2Member -Value $data -Name contextOnly)) {
            continue
        }
        $ordinaryFileComplete = @($data.spans).Count -gt 0 -and
            [string]$file.state -ceq 'complete' -and
            $data -is [Collections.IDictionary] -and
            $data.content -is [string]
        if (-not $ordinaryFileComplete -and @($data.spans).Count -gt 0) {
            foreach ($ruleId in @(
                    Get-ContextualConventionRuleIds |
                    Where-Object {
                        $_ -cne
                            'pr-template-compliance' -and $_ -cne 'file-copyright-header'
                    })) {
                [void]$withheldRules.Add(
                    [string]$ruleId)
            }
        }
        $outcomes = if ($ordinaryFileComplete) {
            Get-ContextualConventionOutcomes `
                -Content ([string]$data.content) `
                -Path $path -Spans @($data.spans) `
                -SnapshotFiles $snapshotFiles.ToArray()
        }
        else {
            Get-ContextualCopyrightHeaderOutcome -Content ([string]$data.content) `
                -Path $path -SnapshotFiles $snapshotFiles.ToArray()
        }
        foreach ($outcome in $outcomes) {
            $state = [string]$outcome.state
            $ruleId = [string]$outcome.ruleId
            if ($ruleId -ceq
                'pr-template-compliance') {
                continue
            }
            if ($state -ceq 'unknown') {
                [void]$withheldRules.Add($ruleId)
                continue
            }
            if ($state -cne 'violation') {
                continue
            }
            $semanticCount++
            if ($semanticCount -gt
                $Limits.MaximumSemanticUnits) {
                Add-OwnerV2Diagnostic `
                    -Diagnostics $diagnostics `
                    -Limits $Limits `
                    -Code contextual-construct-cap-exhausted `
                    -Message (
                        'Contextual findings exceed the bounded ' +
                        'semantic capacity.') -UnitId $id
                [void]$withheldRules.Add($ruleId)
                continue
            }
            $material = [ordered]@{
                bindingId = $bindingId
                evidenceDigest = $evidenceDigest
                capabilityId =
                    $script:ContextualCapability
                capabilityDigest = $CapabilityDigest
                ruleRef = $ruleRef
                ruleId = $ruleId
                evidenceUnitId = $id
                path = $path
                line = [int]$outcome.line
                endLine = [int]$outcome.endLine
                symbol = [string]$outcome.symbol
                reason = [string]$outcome.reason
            }
            if ($ruleId -ceq 'block-body-indentation') {
                $material['indentationContext'] =
                    $outcome.indentationContext
            }
            if ($ruleId -ceq 'file-copyright-header') {
                $material['fileHeader'] = $outcome.fileHeader
            }
            if ($ruleId -ceq 'reused-string-literals') {
                # Cluster identity is order-independent; finding data still pins the complete evidence.
                $material = [ordered]@{
                    repositoryId = [string]$identityUnits[0].data.repositoryId
                    sourceCommit = [string]$identityUnits[0].data.sourceCommit
                    targetCommit = [string]$identityUnits[0].data.targetCommit
                    ruleHash = [string]$ruleData.hash
                    ruleId = $ruleId
                    path = $path
                    line = [int]$outcome.line
                    endLine = [int]$outcome.endLine
                    symbol = [string]$outcome.symbol
                    reason = [string]$outcome.reason
                    literalValues = @($outcome.literalValues)
                    relatedUses = @($outcome.relatedUses)
                    occurrenceCounts = $outcome.occurrenceCounts
                }
            }
            $digest = (Get-OwnerV2Digest `
                    -Value $material).Substring(10)
            $constructRef = "construct:$digest"
            $assessmentId = "method:c:$digest"
            $findingData = [ordered]@{
                disposition = 'violation'
                eligibility =
                    'changed-contextual-convention'
                capabilityId =
                    $script:ContextualCapability
                bindingId = $bindingId
                evidenceDigest = $evidenceDigest
                ruleRef = $ruleRef
                ruleId = $ruleId
                constructRef = $constructRef
                groupRef = $assessmentId
                headCommit = [string]$identityUnits[
                    0].data.sourceCommit
                anchor = [ordered]@{
                    path = $path
                    line = [int]$outcome.line
                    endLine =
                        [int]$outcome.endLine
                    symbol =
                        [string]$outcome.symbol
                }
                evidence =
                    [string]$outcome.evidence
                reason = [string]$outcome.reason
            }
            if ($ruleId -ceq 'block-body-indentation') {
                $findingData['indentationContext'] =
                    $outcome.indentationContext
            }
            if ($ruleId -ceq 'file-copyright-header') {
                $findingData.eligibility = 'changed-file-copyright-header'
                $findingData.anchor['scope'] = 'file-header'
                $findingData['fileHeader'] = $outcome.fileHeader
            }
            if ($ruleId -ceq 'reused-string-literals') {
                $findingData['literalValues'] = @($outcome.literalValues)
                $findingData['relatedUses'] = @($outcome.relatedUses)
                $findingData['occurrenceCounts'] = $outcome.occurrenceCounts
            }
            $findingEvidenceIds = $evidenceIds
            if ($ruleId -ceq 'reused-string-literals') {
                $findingEvidenceIds = @('identity', 'rule') + @(
                    $files | Where-Object {
                        [string]$_.data.path -imatch '\.cs$'
                    } | ForEach-Object { [string]$_.unitId })
            }
            [void]$assessments.Add([ordered]@{
                assessmentId = $assessmentId
                evidenceUnitIds = $findingEvidenceIds
                state = 'complete'
                findings = @([ordered]@{
                            findingId =
                                'contextual-v1:' +
                                (Get-OwnerV2Digest -Value (
                                    [ordered]@{
                                        bindingId =
                                            $bindingId
                                        capabilityId =
                                            $script:ContextualCapability
                                        ruleId = $ruleId
                                        constructRef =
                                            $constructRef
                                        disposition =
                                            'violation'
                                    })).Substring(10)
                            summary =
                                [string]$outcome.evidence
                            data = $findingData
                        })
                })
        }
    }
    foreach ($ruleId in @($withheldRules |
            Sort-Object)) {
        $digest = (Get-OwnerV2Digest -Value (
                "$bindingId|$ruleRef|$ruleId|withheld")).
            Substring(10)
        [void]$assessments.Add([ordered]@{
                assessmentId = "method:c:$digest"
                evidenceUnitIds = @('identity', 'rule')
                state = $(if ($ruleId -ceq 'generic-exception-naming') {
                    'unknown'
                }
                else { 'complete' })
                data = [ordered]@{
                    state = $(if ($ruleId -cin @('generic-exception-naming', 'reused-string-literals')) {
                        'unknown'
                    }
                    else { 'advisory' })
                    reason =
                        'contextual-proof-withheld'
                    constructRef = "construct:$digest"
                    ruleId = $ruleId
                }
                findings = @()
            })
    }
    return [ordered]@{
        schemaVersion = 1
        bindingId = $bindingId
        state = 'complete'
        assessments = @($assessments)
        diagnostics = @($diagnostics)
    }
}

function New-ContextualConventionsCapabilityAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest,
        [DevPilot.OwnerCapability.OwnerV2CapabilityLimits]$Limits =
            (New-OwnerV2CapabilityLimits)
    )
    if ($CapabilityId -cne
            $script:ContextualCapability -or
        $CapabilityDigest -cne
            $script:ContextualDigest) {
        throw 'Contextual capability identity or digest is invalid.'
    }
    $capturedDigest = $CapabilityDigest
    $capturedLimits = $Limits
    $command = Get-Command `
        Invoke-ContextualConventionsCapabilityResponse `
        -CommandType Function
    return New-OwnerPipelineAdapter `
        -Stage capability `
        -Name contextual-conventions-v1-capability `
        -Handler {
            param($context)
            return & $command -Context $context `
                -CapabilityDigest $capturedDigest `
                -Limits $capturedLimits
        }.GetNewClosure()
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
    $capabilityId = [string](Get-OwnerV2Member -Value $identity -Name capabilityId)
    $namedAreEqual = $capabilityId -ceq $script:NamedAreEqualCapability
    $contextual = $capabilityId -ceq
        $script:ContextualCapability
    $methodAssessments = @($assessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name assessmentId) -like
                $(if ($namedAreEqual) {
                    'method:n:*'
                }
                elseif ($contextual) {
                    'method:c:*'
                }
                else { 'method:*' })
        })
    $outcomeAssessments = @($assessments | Where-Object {
            $null -ne (Get-OwnerV2Member -Value $_ -Name data)
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
        $pullRequestScope =
            [string](Get-OwnerV2Member `
                -Value $anchor -Name scope) -ceq
                'pull-request'
        $binding = if ($pullRequestScope) {
            $template = Get-OwnerV2Member `
                -Value $data -Name template
            New-OwnerCanonicalPullRequestBinding `
                -DescriptionSha256 (
                    [string](Get-OwnerV2Member `
                        -Value $data `
                        -Name descriptionSha256)) `
                -TemplatePath (
                    [string](Get-OwnerV2Member `
                        -Value $template -Name path)) `
                -TemplateRef (
                    [string](Get-OwnerV2Member `
                        -Value $template -Name ref)) `
                -TemplateCommit (
                    [string](Get-OwnerV2Member `
                        -Value $template -Name commit)) `
                -TemplateBlob (
                    [string](Get-OwnerV2Member `
                        -Value $template -Name blob)) `
                -TemplateContentSha256 (
                    [string](Get-OwnerV2Member `
                        -Value $template `
                        -Name contentSha256)) `
                -ConstructIdentity $constructRef
        }
        else {
            New-OwnerCanonicalAnchor `
                -Path ([string](Get-OwnerV2Member -Value $anchor -Name path)) `
                -StartLine ([int](Get-OwnerV2Member -Value $anchor -Name line)) `
                -EndLine $(if ($null -ne (
                            Get-OwnerV2Member `
                                -Value $anchor `
                                -Name endLine)) {
                        [int](Get-OwnerV2Member `
                            -Value $anchor `
                            -Name endLine)
                    }
                    else {
                        [int](Get-OwnerV2Member `
                            -Value $anchor `
                            -Name line)
                    }) `
                -Symbol ([string](Get-OwnerV2Member -Value $anchor -Name symbol)) `
                -ConstructIdentity $constructRef
        }
        $normalizedFinding = [ordered]@{
                identity = [string](Get-OwnerV2Member -Value $finding -Name findingId)
                semanticKey = Get-OwnerSemanticFindingKey `
                    -Subject $observationSubject -Rule $observationRule `
                    -Capability ([string](Get-OwnerV2Member -Value $identity -Name capabilityId)) `
                    -Binding $binding
                providerMarker = New-OwnerProviderMarker
                disposition = 'violation'
                ruleRef = [string](Get-OwnerV2Member -Value $data -Name ruleRef)
                constructRef = $constructRef
                anchor = $(if ($pullRequestScope) {
                    [ordered]@{
                        scope = 'pull-request'
                        subject = 'description'
                    }
                }
                else {
                    [ordered]@{
                        path = [string](Get-OwnerV2Member -Value $anchor -Name path)
                        line = [int](Get-OwnerV2Member -Value $anchor -Name line)
                        symbol = [string](Get-OwnerV2Member -Value $anchor -Name symbol)
                    }
                })
                binding = $binding
            }
        if ($namedAreEqual) {
            $normalizedFinding.affectedCallCount =
                [int](Get-OwnerV2Member -Value $data -Name affectedCallCount)
            $normalizedFinding.affectedCallLines =
                @(Get-OwnerV2Member -Value $data -Name affectedCallLines)
            $normalizedFinding.callListTruncated =
                [bool](Get-OwnerV2Member -Value $data -Name callListTruncated)
        }
        elseif ($contextual) {
            $normalizedFinding.ruleId =
                [string](Get-OwnerV2Member `
                    -Value $data -Name ruleId)
            $normalizedFinding.evidence =
                [string](Get-OwnerV2Member `
                    -Value $data -Name evidence)
            $normalizedFinding.reason =
                [string](Get-OwnerV2Member `
                    -Value $data -Name reason)
            if ($normalizedFinding.ruleId -ceq
                    'block-body-indentation') {
                $normalizedFinding.indentationContext =
                    Get-OwnerV2Member `
                        -Value $data -Name indentationContext
            }
            if ([string](Get-OwnerV2Member -Value $anchor -Name scope) -ceq 'file-header') {
                $normalizedFinding.anchor['scope'] = 'file-header'
                $normalizedFinding['fileHeader'] = Get-OwnerV2Member -Value $data -Name fileHeader
            }
            if ([string]$normalizedFinding.ruleId -ceq 'reused-string-literals') {
                $normalizedFinding['literalValues'] =
                    @(Get-OwnerV2Member -Value $data -Name literalValues)
                $normalizedFinding['relatedUses'] =
                    @(Get-OwnerV2Member -Value $data -Name relatedUses)
                $normalizedFinding['occurrenceCounts'] =
                    Get-OwnerV2Member -Value $data -Name occurrenceCounts
            }
            if ($pullRequestScope) {
                $normalizedFinding.issueIdentity =
                    [string](Get-OwnerV2Member `
                        -Value $data `
                        -Name issueIdentity)
                $normalizedFinding.missingSections =
                    @(Get-OwnerV2Member `
                        -Value $data `
                        -Name missingSections)
            }
        }
        [void]$normalizedFindings.Add($normalizedFinding)
    }
    $normalizedOutcomes = [Collections.Generic.List[object]]::new()
    foreach ($assessment in $outcomeAssessments) {
        $assessmentId = [string](Get-OwnerV2Member -Value $assessment -Name assessmentId)
        $outcome = Get-OwnerV2Member -Value $assessment -Name data
        $outcomeState = [string](Get-OwnerV2Member -Value $outcome -Name state)
        $outcomeReason = [string](Get-OwnerV2Member -Value $outcome -Name reason)
        $constructRef = [string](Get-OwnerV2Member -Value $outcome -Name constructRef)
        $path = [string](Get-OwnerV2Member -Value $outcome -Name path)
        $startLine = Get-OwnerV2Member -Value $outcome -Name startLine
        $endLine = Get-OwnerV2Member -Value $outcome -Name endLine
        $symbol = [string](Get-OwnerV2Member -Value $outcome -Name symbol)
        $binding = if (-not [string]::IsNullOrWhiteSpace($path) -and
            $startLine -is [int] -and $endLine -is [int] -and
            -not [string]::IsNullOrWhiteSpace($symbol)) {
            New-OwnerCanonicalAnchor -Path $path -StartLine $startLine -EndLine $endLine `
                -Symbol $symbol -ConstructIdentity $constructRef
        }
        else {
            'unknown'
        }
        $semanticKey = if ($binding -is [Collections.IDictionary]) {
            Get-OwnerSemanticFindingKey -Subject $observationSubject -Rule $observationRule `
                -Capability ([string](Get-OwnerV2Member -Value $identity -Name capabilityId)) `
                -Binding $binding
        }
        else {
            'unknown'
        }
        $normalizedOutcome = [ordered]@{
                identity = 'owner-v2-outcome:' + (Get-OwnerV2Digest -Value ([ordered]@{
                            bindingId = [string](Get-OwnerV2Member -Value $validation -Name bindingId)
                            capabilityId = [string](Get-OwnerV2Member -Value $identity -Name capabilityId)
                            ruleRef = $ruleRef
                            assessmentId = $assessmentId
                            state = $outcomeState
                            reason = $outcomeReason
                        })).Substring(10)
                semanticKey = $semanticKey
                providerMarker = New-OwnerProviderMarker
                disposition = 'unknown'
                state = $outcomeState
                reason = $outcomeReason
                ruleRef = $ruleRef
                constructRef = $constructRef
                binding = $binding
                writerEligible = $false
            }
        if ($namedAreEqual) {
            $normalizedOutcome.affectedCallCount =
                [int](Get-OwnerV2Member -Value $outcome -Name affectedCallCount)
        }
        elseif ($contextual) {
            $normalizedOutcome.ruleId =
                [string](Get-OwnerV2Member `
                    -Value $outcome -Name ruleId)
        }
        [void]$normalizedOutcomes.Add($normalizedOutcome)
    }
    $sortedFindings = @($normalizedFindings | Sort-Object identity)
    $sortedOutcomes = @($normalizedOutcomes | Sort-Object identity)
    $unknownCount = @($sortedOutcomes | Where-Object state -CEQ 'unknown').Count
    $eligibleCount = $methodAssessments.Count
    $advisoryCount = @($sortedOutcomes | Where-Object state -CEQ 'advisory').Count
    $checkedCount = @($methodAssessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name state) -ceq 'complete'
        }).Count
    $runnerAttemptCount = @($methodAssessments | Where-Object {
            [string](Get-OwnerV2Member -Value $_ -Name assessmentId) -like 'method:r:*'
        }).Count
    $deterministic = $namedAreEqual -or $contextual
    $modelStarts = $(if ($deterministic) { 0 } else { 'unknown' })
    $modelStartsReason = $(if ($deterministic) {
            'deterministic-rule-no-model'
        } else { 'runner-telemetry-not-requested' })
    $latencyMs = $(if ($deterministic) { 0 } else { 'unknown' })
    $refusalReason = $(if ($deterministic) { 'none' } else { 'unknown' })
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
            ($modelStartsValue -is [string] -and [string]$modelStartsValue -cne 'unknown') -or
            ($modelStartsValue -isnot [string] -and
                $modelStartsValue -isnot [int] -and $modelStartsValue -isnot [long]) -or
            ($modelStartsValue -isnot [string] -and (
                [long]$modelStartsValue -lt 0 -or
                [long]$modelStartsValue -gt [long]$attemptsValue)) -or
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
        $modelStarts = if ($modelStartsValue -is [string]) {
            $modelStartsReason = 'model-start-indeterminate'
            'unknown'
        }
        else {
            [int]$modelStartsValue
        }
        $latencyMs = [long]$latencyValue
        $refusalReason = [string]$refusalValue
    }
    $uncoveredCount = @($sortedOutcomes | Where-Object state -CEQ 'uncovered').Count
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
        outcomes = $sortedOutcomes
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
                        if ($modelStartsReason -ceq 'model-start-indeterminate') {
                            New-OwnerMeasurement -Status unavailable -Reason $modelStartsReason
                        }
                        else {
                            New-OwnerMeasurement -Status notMeasured -Reason $modelStartsReason
                        }
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
    'Assert-OwnerCommentRuleReferences',
    'ConvertTo-OwnerV2Observation',
    'Format-ContextualConventionComment',
    'Format-NamedAreEqualComment',
    'Format-OwnerV1WriterComment',
    'Get-ContextualConventionMarkerKey',
    'Get-NamedAreEqualMarkerKey',
    'Get-OwnerV1WriterMarkerKey',
    'New-ContextualConventionsCapabilityAdapter',
    'New-NamedAreEqualCapabilityAdapter',
    'New-OwnerSemanticRunner',
    'New-OwnerV2CapabilityAdapter',
    'New-OwnerV2CapabilityLimits',
    'Resolve-OwnerV2DiscussionReconciliation'
)
