#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ReviewerFactSchemaVersion = 1
$script:ReviewerFactPlanVersion = 1
$script:ReviewerFactExtractorVersion = "review-facts-v1"
$script:ReviewerFactUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:ReviewerFactStates = @("true", "false", "unknown", "notApplicable")
$script:ReviewerFactUnknownReasons = @(
    "", "transportFailed", "absent", "unprovable", "truncated", "capExceeded",
    "malformed", "snapshotMoved"
)
$script:ReviewerFactDomains = @("metadata", "cloudTest", "fanOut", "threads", "changes")

function Get-ReviewerFactValue {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        $containsKey = $Object.PSObject.Methods["ContainsKey"]
        if (($containsKey -and $Object.ContainsKey($Name)) -or
            (-not $containsKey -and $Object.Contains($Name))) { return $Object[$Name] }
        return $Default
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    return $Default
}

function Assert-ReviewerFactStrictText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Where = "fact text")
    try { [void]$script:ReviewerFactUtf8.GetByteCount($Text) }
    catch { throw "$Where contains invalid Unicode: $($_.Exception.Message)" }
}

function Get-ReviewerFactSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Assert-ReviewerFactStrictText -Text $Text -Where "SHA-256 input"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($script:ReviewerFactUtf8.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function ConvertTo-ReviewerFactCanonicalJson {
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 32) { throw "Fact canonical JSON exceeded the maximum object depth of 32." }
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) {
        Assert-ReviewerFactStrictText -Text $Value -Where "canonical JSON string"
        return ConvertTo-Json -InputObject $Value -Compress
    }
    if ($Value -is [System.Collections.IDictionary] -or
        $Value -is [System.Management.Automation.PSCustomObject]) {
        $names = [System.Collections.Generic.List[string]]::new()
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) {
                if ($key -isnot [string]) { throw "Fact canonical JSON object keys must be strings." }
                [void]$names.Add($key)
            }
        }
        else {
            foreach ($property in $Value.PSObject.Properties) { [void]$names.Add($property.Name) }
        }
        $names.Sort([StringComparer]::Ordinal)
        $parts = [System.Collections.Generic.List[string]]::new()
        $prior = $null
        foreach ($name in $names) {
            if ($null -ne $prior -and [string]::Equals($prior, $name, [StringComparison]::Ordinal)) {
                throw "Fact canonical JSON object keys must be unique."
            }
            $prior = $name
            $encodedName = ConvertTo-ReviewerFactCanonicalJson -Value $name -Depth ($Depth + 1)
            $encodedValue = ConvertTo-ReviewerFactCanonicalJson `
                -Value (Get-ReviewerFactValue -Object $Value -Name $name) -Depth ($Depth + 1)
            [void]$parts.Add($encodedName + ":" + $encodedValue)
        }
        return "{" + ($parts.ToArray() -join ",") + "}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-ReviewerFactCanonicalJson -Value $item -Depth ($Depth + 1)))
        }
        return "[" + ($items.ToArray() -join ",") + "]"
    }
    throw "Fact canonical JSON does not support values of type '$($Value.GetType().FullName)'."
}

function Get-ReviewerFactObjectSha256 {
    param([Parameter(Mandatory)]$Value)
    return Get-ReviewerFactSha256 -Text (ConvertTo-ReviewerFactCanonicalJson -Value $Value)
}

function New-ReviewerFactEvidence {
    param(
        [Parameter(Mandatory)][string]$SourceType,
        [AllowEmptyString()][string]$Path = "",
        [ValidateRange(0, [int]::MaxValue)][int]$LineStart = 0,
        [ValidateRange(0, [int]::MaxValue)][int]$LineEnd = 0,
        [AllowEmptyString()][string]$Field = "",
        [AllowEmptyString()][string]$Sha256 = ""
    )
    if ($LineEnd -gt 0 -and $LineEnd -lt $LineStart) { throw "Evidence lineEnd cannot precede lineStart." }
    if ($Sha256 -and $Sha256 -notmatch '^[0-9a-f]{64}$') { throw "Evidence SHA-256 must be lowercase 64-hex." }
    return [pscustomobject][ordered]@{
        sourceType = $SourceType
        path        = $Path
        lineStart   = $LineStart
        lineEnd     = $LineEnd
        field       = $Field
        sha256      = $Sha256
    }
}

function New-ReviewerFact {
    param(
        [Parameter(Mandatory)][ValidateSet("metadata", "cloudTest", "fanOut", "threads", "changes")][string]$Domain,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][ValidateSet("true", "false", "unknown", "notApplicable")][string]$State,
        [AllowEmptyString()][string]$UnknownReason = "",
        $Value = $null,
        [object[]]$Evidence = @(),
        [Parameter(Mandatory)][ValidateSet(
            "wrapper-observed", "source-commit", "target-policy", "untrusted-author-controlled"
        )][string]$TrustTier
    )
    foreach ($text in @($Domain, $Kind, $Subject, $UnknownReason, $TrustTier)) {
        Assert-ReviewerFactStrictText -Text $text
    }
    if ($State -eq "unknown") {
        if ($UnknownReason -notin $script:ReviewerFactUnknownReasons -or -not $UnknownReason) {
            throw "Unknown facts require a closed-vocabulary unknownReason."
        }
    }
    elseif ($UnknownReason) { throw "Only unknown facts may carry unknownReason." }

    $orderedEvidence = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Evidence)) { [void]$orderedEvidence.Add($item) }
    $evidenceComparison = [System.Comparison[object]] {
        param($left, $right)
        $leftKey = ConvertTo-ReviewerFactCanonicalJson -Value $left
        $rightKey = ConvertTo-ReviewerFactCanonicalJson -Value $right
        return [StringComparer]::Ordinal.Compare($leftKey, $rightKey)
    }
    $orderedEvidence.Sort($evidenceComparison)
    $identity = [ordered]@{
        domain   = $Domain
        kind     = $Kind
        subject  = $Subject
        evidence = @($orderedEvidence.ToArray() | ForEach-Object {
                [ordered]@{
                    sourceType = $_.sourceType
                    path = $_.path
                    lineStart = $_.lineStart
                    lineEnd = $_.lineEnd
                    field = $_.field
                }
            })
    }
    $input = [ordered]@{
        state         = $State
        unknownReason = $UnknownReason
        value         = $Value
        evidence      = $orderedEvidence.ToArray()
    }
    return [pscustomobject][ordered]@{
        id            = "rf1:" + (Get-ReviewerFactObjectSha256 -Value $identity)
        domain        = $Domain
        kind          = $Kind
        subject       = $Subject
        state         = $State
        unknownReason = $UnknownReason
        value         = $Value
        evidence      = $orderedEvidence.ToArray()
        provenance    = [pscustomobject][ordered]@{
            extractorVersion = $script:ReviewerFactExtractorVersion
            inputSha256      = Get-ReviewerFactObjectSha256 -Value $input
            trustTier        = $TrustTier
        }
    }
}

function New-ReviewerFactDomainResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet("complete", "notApplicable", "failed")][string]$Status,
        [object[]]$Facts = @(),
        [AllowEmptyString()][string]$ErrorCode = "",
        [AllowEmptyString()][string]$ErrorMessage = ""
    )
    return [pscustomobject][ordered]@{
        name         = $Name
        status       = $Status
        errorCode    = $ErrorCode
        errorMessage = $ErrorMessage
        factCount    = @($Facts).Count
        facts        = @($Facts)
    }
}

function Get-ReviewerFactEnvelopeStatus {
    param($Envelope)
    if ($null -eq $Envelope) { return "failed" }
    $status = [string](Get-ReviewerFactValue -Object $Envelope -Name "Status" -Default "failed")
    if ($status -notin @("available", "failed", "truncated", "notApplicable")) {
        throw "Fact domain envelope status '$status' is unsupported."
    }
    return $status
}

function New-ReviewerFactUnavailableDomain {
    param([string]$Domain, $Envelope)
    $status = Get-ReviewerFactEnvelopeStatus -Envelope $Envelope
    if ($status -eq "notApplicable") {
        return New-ReviewerFactDomainResult -Name $Domain -Status "notApplicable"
    }
    $code = [string](Get-ReviewerFactValue -Object $Envelope -Name "ErrorCode" -Default $status)
    $reason = if ($status -eq "truncated") { "truncated" }
        elseif ($code -in $script:ReviewerFactUnknownReasons -and $code) { $code }
        elseif ($code -match 'Transport|timeout|credential') { "transportFailed" }
        else { "malformed" }
    $message = [string](Get-ReviewerFactValue -Object $Envelope -Name "Error" -Default "Domain input was unavailable.")
    $fact = New-ReviewerFact -Domain $Domain -Kind "domainAvailability" -Subject $Domain `
        -State "unknown" -UnknownReason $reason -Value ([ordered]@{ errorCode = $code }) `
        -TrustTier "wrapper-observed"
    return New-ReviewerFactDomainResult -Name $Domain -Status "failed" -Facts @($fact) `
        -ErrorCode $code -ErrorMessage $message
}

function Get-ReviewerFactLineNumber {
    param([string]$Text, [int]$Index)
    if ($Index -lt 0) { return 0 }
    $line = 1
    for ($i = 0; $i -lt $Index -and $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "`n") { $line++ }
    }
    return $line
}

function Get-ReviewerMetadataFacts {
    param([Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)]$Policy)
    if ((Get-ReviewerFactEnvelopeStatus $Envelope) -ne "available") {
        return New-ReviewerFactUnavailableDomain -Domain "metadata" -Envelope $Envelope
    }
    $pr = Get-ReviewerFactValue $Envelope "Data"
    $prId = [int](Get-ReviewerFactValue $pr "pullRequestId" 0)
    $path = "pull-request:" + [System.Convert]::ToString($prId, [Globalization.CultureInfo]::InvariantCulture)
    $descriptionValue = Get-ReviewerFactValue $pr "description" $null
    $facts = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $descriptionValue) {
        foreach ($name in @($Policy.requiredSections)) {
            [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind "requiredSectionPresent" -Subject ([string]$name) `
                    -State unknown -UnknownReason absent -Value $null -TrustTier "untrusted-author-controlled"))
        }
    }
    else {
        $description = [string]$descriptionValue
        Assert-ReviewerFactStrictText -Text $description -Where "PR description"
        $headings = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
        $lines = @($description -split "`r?`n", 0, "RegexMatch")
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$') {
                $heading = $Matches[1].Trim()
                if (-not $headings.ContainsKey($heading)) { $headings.Add($heading, $index + 1) }
            }
        }
        foreach ($nameValue in @($Policy.requiredSections)) {
            $name = [string]$nameValue
            $present = $headings.ContainsKey($name)
            $evidence = @()
            if ($present) {
                $evidence = @(New-ReviewerFactEvidence -SourceType "pullRequestDescription" -Path $path `
                        -LineStart $headings[$name] -LineEnd $headings[$name] -Field ("heading:" + $name) `
                        -Sha256 (Get-ReviewerFactSha256 -Text $description))
            }
            [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind "requiredSectionPresent" -Subject $name `
                    -State $(if ($present) { "true" } else { "false" }) -Value ([ordered]@{ heading = $name }) `
                    -Evidence $evidence -TrustTier "untrusted-author-controlled"))
        }
        foreach ($tagNameValue in @($Policy.tagNames)) {
            $tagName = [string]$tagNameValue
            $pattern = '(?im)^\s*(?:[-*]\s*)?\[?' + [regex]::Escape($tagName) + '\]?\s*:\s*(\S.*)$'
            $match = [regex]::Match($description, $pattern)
            $tagPresent = $match.Success
            $tagEvidence = @()
            $tagValue = $null
            if ($tagPresent) {
                $observed = ConvertTo-ReviewerFactSanitizedSubstance -Text $match.Groups[1].Value.Trim()
                $tagValue = (Limit-ReviewerFactUtf8Text -Text $observed `
                        -MaxBytes ([int]$Policy.maxObservedValueBytes)).Text
                $lineNumber = Get-ReviewerFactLineNumber -Text $description -Index $match.Index
                $tagEvidence = @(New-ReviewerFactEvidence -SourceType "pullRequestDescription" -Path $path `
                        -LineStart $lineNumber -LineEnd $lineNumber -Field ("tag:" + $tagName) `
                        -Sha256 (Get-ReviewerFactSha256 -Text $description))
            }
            [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind "tagPresent" -Subject $tagName `
                    -State $(if ($tagPresent) { "true" } else { "false" }) `
                    -Value ([ordered]@{ observedValue = $tagValue }) -Evidence $tagEvidence `
                    -TrustTier "untrusted-author-controlled"))
        }
        $markers = [System.Collections.Generic.List[string]]::new()
        $checkLines = [System.Collections.Generic.List[int]]::new()
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s*[-*+]\s+\[([^\]])\]\s+') {
                [void]$markers.Add($Matches[1])
                [void]$checkLines.Add($index + 1)
            }
        }
        $markerCounts = [System.Collections.Generic.List[object]]::new()
        $orderedMarkers = [System.Collections.Generic.List[string]]::new()
        foreach ($marker in $markers) {
            if (-not $orderedMarkers.Contains($marker)) { [void]$orderedMarkers.Add($marker) }
        }
        $orderedMarkers.Sort([StringComparer]::Ordinal)
        foreach ($marker in $orderedMarkers) {
            [void]$markerCounts.Add([pscustomobject][ordered]@{
                    marker = $marker
                    count = @($markers | Where-Object {
                            [string]::Equals($_, $marker, [StringComparison]::Ordinal)
                        }).Count
                })
        }
        [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind "checklistPresent" -Subject "description" `
                -State $(if ($markers.Count -gt 0) { "true" } else { "false" }) `
                -Value ([ordered]@{ itemCount = $markers.Count }) -TrustTier "untrusted-author-controlled"))
        [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind "checklistSelectionMarkers" -Subject "description" `
                -State $(if ($markers.Count -gt 0) { "true" } else { "notApplicable" }) `
                -Value $markerCounts.ToArray() -TrustTier "untrusted-author-controlled"))

        $begin = [string]$Policy.changelogBegin
        $end = [string]$Policy.changelogEnd
        $beginAt = $description.IndexOf($begin, [StringComparison]::Ordinal)
        $endAt = $(if ($beginAt -ge 0) { $description.IndexOf($end, $beginAt + $begin.Length, [StringComparison]::Ordinal) } else { -1 })
        $delimiters = ($beginAt -ge 0 -and $endAt -ge 0)
        [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind "changelogDelimitersPresent" -Subject "description" `
                -State $(if ($delimiters) { "true" } else { "false" }) `
                -Value ([ordered]@{ beginCount = ([regex]::Matches($description, [regex]::Escape($begin))).Count; endCount = ([regex]::Matches($description, [regex]::Escape($end))).Count }) `
                -TrustTier "untrusted-author-controlled"))
        if ($delimiters) {
            $content = $description.Substring($beginAt + $begin.Length, $endAt - ($beginAt + $begin.Length))
            $structuralContent = $content -replace '[\s\u00a0\u200b\ufeff]', ''
            [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind "changelogContentObserved" -Subject "description" `
                    -State $(if ($structuralContent.Length -gt 0) { "true" } else { "false" }) `
                    -Value ([ordered]@{ decodedBytes = $script:ReviewerFactUtf8.GetByteCount($content); structuralCharacterCount = $structuralContent.Length }) `
                    -Evidence @(New-ReviewerFactEvidence -SourceType "pullRequestDescription" -Path $path `
                        -LineStart (Get-ReviewerFactLineNumber $description $beginAt) `
                        -LineEnd (Get-ReviewerFactLineNumber $description $endAt) -Field "changelog" `
                        -Sha256 (Get-ReviewerFactSha256 -Text $content)) -TrustTier "untrusted-author-controlled"))
        }
        else {
            [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind "changelogContentObserved" -Subject "description" `
                    -State "unknown" -UnknownReason absent -Value $null -TrustTier "untrusted-author-controlled"))
        }
    }

    foreach ($field in @(
            @{ Name = "linkedWorkItemCount"; Kind = "linkedWorkItemCount" },
            @{ Name = "isDraft"; Kind = "draftState" },
            @{ Name = "autoCompleteSetBy"; Kind = "autoCompleteState" }
        )) {
        $raw = Get-ReviewerFactValue $pr $field.Name $null
        if ($null -eq $raw) {
            [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind $field.Kind -Subject $path `
                    -State unknown -UnknownReason absent -Value $null -TrustTier "wrapper-observed"))
        }
        else {
            $value = if ($field.Name -eq "autoCompleteSetBy") { [bool]($null -ne $raw -and [string]$raw -ne "") } else { $raw }
            [void]$facts.Add((New-ReviewerFact -Domain metadata -Kind $field.Kind -Subject $path `
                    -State true -Value $value `
                    -Evidence @(New-ReviewerFactEvidence -SourceType "pullRequestApi" -Path $path -Field $field.Name) `
                    -TrustTier "wrapper-observed"))
        }
    }
    return New-ReviewerFactDomainResult -Name metadata -Status complete -Facts $facts.ToArray()
}

function Test-ReviewerFactPathPattern {
    param([string]$Path, [string]$Pattern)
    $normalizedPath = $Path.TrimStart("/", "\").Replace("\", "/")
    $normalizedPattern = $Pattern.Replace("\", "/")
    $escaped = [regex]::Escape($normalizedPattern)
    $escaped = $escaped.Replace('\*\*/', '(?:.*/)?').Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')
    return [regex]::IsMatch($normalizedPath, "^" + $escaped + "$", [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function ConvertFrom-ReviewerFactCloudTestManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    Assert-ReviewerFactStrictText -Text $Content -Where "CloudTest manifest"
    $entries = [System.Collections.Generic.List[object]]::new()
    $extension = [IO.Path]::GetExtension($Path)
    if ([string]::Equals($extension, ".json", [StringComparison]::OrdinalIgnoreCase)) {
        $document = $Content | ConvertFrom-Json -Depth 32
        $rawEntries = Get-ReviewerFactValue $document "Execution" $null
        if ($null -eq $rawEntries) { $rawEntries = Get-ReviewerFactValue $document "Executions" $null }
        if ($null -eq $rawEntries) { throw "CloudTest JSON manifest has no exact Execution or Executions field." }
        $executionIndex = 0
        foreach ($entry in @($rawEntries)) {
            $assembly = [string](Get-ReviewerFactValue $entry "assembly" "")
            if (-not $assembly) { $assembly = [string](Get-ReviewerFactValue $entry "Assembly" "") }
            if (-not $assembly) { throw "CloudTest Execution entry has no explicit assembly." }
            $categories = @(Get-ReviewerFactValue $entry "categories" @())
            if ($categories.Count -eq 0) {
                $category = [string](Get-ReviewerFactValue $entry "category" "")
                if (-not $category) { $category = [string](Get-ReviewerFactValue $entry "Category" "") }
                if ($category) { $categories = @($category) }
            }
            [void]$entries.Add([pscustomobject][ordered]@{
                    path            = $Path
                    assembly        = $assembly
                    categories      = @($categories | ForEach-Object { [string]$_ })
                    filter          = [string](Get-ReviewerFactValue $entry "filter" (Get-ReviewerFactValue $entry "Filter" ""))
                    targetFramework = [string](Get-ReviewerFactValue $entry "targetFramework" (Get-ReviewerFactValue $entry "TargetFramework" ""))
                    line            = 0
                    index           = $executionIndex
                })
            $executionIndex++
        }
    }
    elseif ([string]::Equals($extension, ".xml", [StringComparison]::OrdinalIgnoreCase)) {
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create([IO.StringReader]::new($Content), $settings)
        try {
            $executionIndex = 0
            while ($reader.Read()) {
                if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or
                    -not [string]::Equals($reader.LocalName, "Execution", [StringComparison]::Ordinal)) { continue }
                $assembly = [string]$reader.GetAttribute("Assembly")
                if (-not $assembly) { throw "CloudTest XML Execution element has no explicit Assembly attribute." }
                $category = [string]$reader.GetAttribute("Category")
                $lineInfo = [System.Xml.IXmlLineInfo]$reader
                [void]$entries.Add([pscustomobject][ordered]@{
                        path            = $Path
                        assembly        = $assembly
                        categories      = $(if ($category) { @($category -split '\s*[,;]\s*') } else { @() })
                        filter          = [string]$reader.GetAttribute("Filter")
                        targetFramework = [string]$reader.GetAttribute("TargetFramework")
                        line            = $(if ($lineInfo.HasLineInfo()) { $lineInfo.LineNumber } else { 0 })
                        index           = $executionIndex
                    })
                $executionIndex++
            }
        }
        finally { $reader.Dispose() }
    }
    else { throw "CloudTest manifest '$Path' has an unsupported format." }
    return $entries.ToArray()
}

function Get-ReviewerCloudTestFacts {
    param([Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)]$Policy)
    if ((Get-ReviewerFactEnvelopeStatus $Envelope) -ne "available") {
        return New-ReviewerFactUnavailableDomain -Domain cloudTest -Envelope $Envelope
    }
    $data = Get-ReviewerFactValue $Envelope "Data"
    $changeSetObserved = [bool](Get-ReviewerFactValue $data "ChangeSetObserved" $false)
    if (-not $changeSetObserved) {
        return New-ReviewerFactUnavailableDomain -Domain cloudTest -Envelope @{
            Status = "failed"; ErrorCode = "unprovable"; Error = "CloudTest applicability requires an observed change set."
        }
    }
    $files = @(Get-ReviewerFactValue $data "ChangedFiles" @())
    $manifests = @(Get-ReviewerFactValue $data "Manifests" @())
    $claims = @(Get-ReviewerFactValue $data "Claims" @())
    $facts = [System.Collections.Generic.List[object]]::new()
    $testFiles = @($files | Where-Object {
            $path = [string](Get-ReviewerFactValue $_ "Path" "")
            @($Policy.testPathGlobs | Where-Object { Test-ReviewerFactPathPattern -Path $path -Pattern ([string]$_) }).Count -gt 0
        })
    $projects = @($files | Where-Object {
            $extension = [IO.Path]::GetExtension([string](Get-ReviewerFactValue $_ "Path" ""))
            @($Policy.projectExtensions | Where-Object { [string]::Equals([string]$_, $extension, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        })
    foreach ($file in @($testFiles + $projects)) {
        $path = [string](Get-ReviewerFactValue $file "Path" "")
        [void]$facts.Add((New-ReviewerFact -Domain cloudTest -Kind $(if ($projects -contains $file) { "changedTestProject" } else { "changedTestFile" }) `
                -Subject $path -State true -Value ([ordered]@{ path = $path }) `
                -Evidence @(New-ReviewerFactEvidence -SourceType "changeSet" -Path $path) -TrustTier "wrapper-observed"))
    }
    $executions = [System.Collections.Generic.List[object]]::new()
    foreach ($manifest in $manifests) {
        $path = [string](Get-ReviewerFactValue $manifest "Path" "")
        $content = [string](Get-ReviewerFactValue $manifest "Content" "")
        foreach ($execution in @(ConvertFrom-ReviewerFactCloudTestManifest -Path $path -Content $content)) {
            [void]$executions.Add($execution)
            $executionIdentity = Get-ReviewerFactObjectSha256 -Value ([ordered]@{
                assembly = $execution.assembly
                categories = @($execution.categories)
                filter = $execution.filter
                targetFramework = $execution.targetFramework
            })
            $assemblyObservation = Get-ReviewerFactBoundedObservation -Text $execution.assembly `
                -MaxBytes ([int]$Policy.maxObservedValueBytes)
            $filterObservation = Get-ReviewerFactBoundedObservation -Text $execution.filter `
                -MaxBytes ([int]$Policy.maxObservedValueBytes)
            $frameworkObservation = Get-ReviewerFactBoundedObservation -Text $execution.targetFramework `
                -MaxBytes ([int]$Policy.maxObservedValueBytes)
            $categoryObservations = @($execution.categories | ForEach-Object {
                    Get-ReviewerFactBoundedObservation -Text ([string]$_) `
                        -MaxBytes ([int]$Policy.maxObservedValueBytes)
                })
            [void]$facts.Add((New-ReviewerFact -Domain cloudTest -Kind "executionEntry" `
                    -Subject ($path + "#" + $executionIdentity) -State true `
                    -Value ([ordered]@{
                        assembly = $assemblyObservation.text
                        assemblySha256 = Get-ReviewerFactSha256 -Text $execution.assembly
                        categories = @($categoryObservations | ForEach-Object { $_.text })
                        categorySha256 = @($execution.categories | ForEach-Object {
                                Get-ReviewerFactSha256 -Text ([string]$_)
                            })
                        filter = $filterObservation.text
                        filterSha256 = Get-ReviewerFactSha256 -Text $execution.filter
                        targetFramework = $frameworkObservation.text
                        targetFrameworkSha256 = Get-ReviewerFactSha256 -Text $execution.targetFramework
                    }) -Evidence @(New-ReviewerFactEvidence -SourceType "sourceCommitFile" -Path $path `
                        -LineStart $execution.line -LineEnd $execution.line -Field "Execution" `
                        -Sha256 (Get-ReviewerFactSha256 -Text $content)) -TrustTier "source-commit"))
            $truncatedFields = [System.Collections.Generic.List[string]]::new()
            if ($assemblyObservation.truncated) { [void]$truncatedFields.Add("assembly") }
            if ($filterObservation.truncated) { [void]$truncatedFields.Add("filter") }
            if ($frameworkObservation.truncated) { [void]$truncatedFields.Add("targetFramework") }
            for ($categoryIndex = 0; $categoryIndex -lt $categoryObservations.Count; $categoryIndex++) {
                if ($categoryObservations[$categoryIndex].truncated) {
                    [void]$truncatedFields.Add("categories[" + [string]$categoryIndex + "]")
                }
            }
            if ($truncatedFields.Count -gt 0) {
                [void]$facts.Add((New-ReviewerFact -Domain cloudTest -Kind "observedValueTruncated" `
                        -Subject ($path + "#" + $executionIdentity) -State true `
                        -Value ([ordered]@{
                            fields = $truncatedFields.ToArray()
                            maxBytesPerValue = [int]$Policy.maxObservedValueBytes
                        }) -TrustTier "wrapper-observed"))
            }
        }
    }
    $corpusComplete = [bool](Get-ReviewerFactValue $data "ManifestCorpusComplete" $false)
    foreach ($claim in $claims) {
        $assembly = [string](Get-ReviewerFactValue $claim "assembly" "")
        $category = [string](Get-ReviewerFactValue $claim "category" "")
        $subject = $assembly + $(if ($category) { ":" + $category } else { "" })
        $sameAssembly = @($executions | Where-Object {
                [string]::Equals($_.assembly, $assembly, [StringComparison]::OrdinalIgnoreCase)
            })
        $included = $false
        $allExplicitlyExclude = ($sameAssembly.Count -gt 0)
        foreach ($execution in $sameAssembly) {
            $required = @($execution.categories)
            $filter = [string]$execution.filter
            if ($filter -match '^\s*(?:TestCategory|Category)\s*=\s*([A-Za-z0-9_.-]+)\s*$') {
                $required += @($Matches[1])
            }
            elseif ($filter) {
                $allExplicitlyExclude = $false
                continue
            }
            if ($required.Count -eq 0 -or @($required | Where-Object {
                        [string]::Equals([string]$_, $category, [StringComparison]::OrdinalIgnoreCase)
                    }).Count -gt 0) {
                $included = $true
                $allExplicitlyExclude = $false
            }
        }
        if ($included) {
            $state = "true"; $reason = ""; $classification = "definitelyGated"
        }
        elseif ($corpusComplete -and $allExplicitlyExclude) {
            $state = "false"; $reason = ""; $classification = "definitelyNotGated"
        }
        else {
            $state = "unknown"; $reason = "unprovable"; $classification = "unknown"
        }
        [void]$facts.Add((New-ReviewerFact -Domain cloudTest -Kind "claimedTestGating" -Subject $subject `
                -State $state -UnknownReason $reason -Value ([ordered]@{
                    classification = $classification
                    assembly = $assembly
                    category = $category
                    manifestCorpusComplete = $corpusComplete
                }) -TrustTier "wrapper-observed"))
    }
    if ($testFiles.Count -eq 0 -and $projects.Count -eq 0 -and $claims.Count -eq 0 -and $manifests.Count -eq 0) {
        [void]$facts.Add((New-ReviewerFact -Domain cloudTest -Kind "domainApplicability" -Subject cloudTest `
                -State notApplicable -Value ([ordered]@{ observedChangedFileCount = $files.Count }) `
                -TrustTier "wrapper-observed"))
        return New-ReviewerFactDomainResult -Name cloudTest -Status notApplicable -Facts $facts.ToArray()
    }
    return New-ReviewerFactDomainResult -Name cloudTest -Status complete -Facts $facts.ToArray()
}

function Get-ReviewerFactIdentifiers {
    param([Parameter(Mandatory)]$File)
    $path = [string](Get-ReviewerFactValue $File "Path" "")
    $content = [string](Get-ReviewerFactValue $File "Content" "")
    Assert-ReviewerFactStrictText -Text $content -Where "settings/resource content"
    $records = [System.Collections.Generic.List[object]]::new()
    $extension = [IO.Path]::GetExtension($path)
    if ([string]::Equals($extension, ".json", [StringComparison]::OrdinalIgnoreCase)) {
        $root = $content | ConvertFrom-Json -Depth 32
        function Add-ReviewerFactJsonIdentifiers {
            param($Node, [string]$Prefix)
            if ($Node -is [System.Management.Automation.PSCustomObject]) {
                foreach ($property in $Node.PSObject.Properties) {
                    $identifier = $(if ($Prefix) { $Prefix + "." + $property.Name } else { $property.Name })
                    [void]$records.Add([pscustomobject]@{
                            Identifier = $identifier
                            Line = 0
                            Field = "jsonProperty"
                        })
                    Add-ReviewerFactJsonIdentifiers -Node $property.Value -Prefix $identifier
                }
            }
            elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
                $arrayIndex = 0
                foreach ($item in $Node) {
                    Add-ReviewerFactJsonIdentifiers -Node $item -Prefix ($Prefix + "[" + [string]$arrayIndex + "]")
                    $arrayIndex++
                }
            }
        }
        Add-ReviewerFactJsonIdentifiers -Node $root -Prefix ""
    }
    elseif ([string]::Equals($extension, ".resx", [StringComparison]::OrdinalIgnoreCase)) {
        foreach ($match in [regex]::Matches($content, '<data\s+[^>]*\bname\s*=\s*"([^"]+)"', "IgnoreCase,CultureInvariant")) {
            [void]$records.Add([pscustomobject]@{
                    Identifier = $match.Groups[1].Value
                    Line = Get-ReviewerFactLineNumber $content $match.Index
                    Field = "data@name"
                })
        }
    }
    elseif ($extension -in @(".config", ".xml")) {
        foreach ($match in [regex]::Matches($content, '<add\s+[^>]*\b(?:key|name)\s*=\s*"([^"]+)"', "IgnoreCase,CultureInvariant")) {
            [void]$records.Add([pscustomobject]@{
                    Identifier = $match.Groups[1].Value
                    Line = Get-ReviewerFactLineNumber $content $match.Index
                    Field = "add@keyOrName"
                })
        }
    }
    return $records.ToArray()
}

function Get-ReviewerFactBoundedObservation {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateRange(1, 65536)][int]$MaxBytes
    )
    $sanitized = ConvertTo-ReviewerFactSanitizedSubstance -Text $Text
    $bounded = Limit-ReviewerFactUtf8Text -Text $sanitized -MaxBytes $MaxBytes
    return [pscustomobject][ordered]@{
        text = $bounded.Text
        originalBytes = $script:ReviewerFactUtf8.GetByteCount($Text)
        retainedBytes = $bounded.ByteLength
        truncated = [bool]$bounded.Truncated
    }
}

function Get-ReviewerFanOutFacts {
    param([Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)]$Policy)
    if ((Get-ReviewerFactEnvelopeStatus $Envelope) -ne "available") {
        return New-ReviewerFactUnavailableDomain -Domain fanOut -Envelope $Envelope
    }
    $data = Get-ReviewerFactValue $Envelope "Data"
    $changeSetObserved = [bool](Get-ReviewerFactValue $data "ChangeSetObserved" $false)
    if (-not $changeSetObserved) {
        return New-ReviewerFactUnavailableDomain -Domain fanOut -Envelope @{
            Status = "failed"; ErrorCode = "unprovable"; Error = "Fan-out applicability requires an observed change set."
        }
    }
    $files = @(Get-ReviewerFactValue $data "ChangedFiles" @())
    $surfaceFiles = @(Get-ReviewerFactValue $data "SurfaceFiles" @())
    $precedents = @(Get-ReviewerFactValue $data "Precedents" @())
    $facts = [System.Collections.Generic.List[object]]::new()
    $identifierRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $path = [string](Get-ReviewerFactValue $file "Path" "")
        foreach ($record in @(Get-ReviewerFactIdentifiers -File $file)) {
            $entry = [pscustomobject]@{ Path = $path; Identifier = $record.Identifier; Line = $record.Line; Field = $record.Field }
            [void]$identifierRecords.Add($entry)
            $identifierHash = Get-ReviewerFactSha256 -Text $record.Identifier
            $identifierObservation = Get-ReviewerFactBoundedObservation -Text $record.Identifier `
                -MaxBytes ([int]$Policy.maxObservedValueBytes)
            [void]$facts.Add((New-ReviewerFact -Domain fanOut -Kind "changedIdentifier" `
                    -Subject ($path + "#" + $identifierHash) -State true `
                    -Value ([ordered]@{
                        identifier = $identifierObservation.text
                        identifierSha256 = $identifierHash
                        path = $path
                    }) `
                    -Evidence @(New-ReviewerFactEvidence -SourceType "sourceCommitFile" -Path $path `
                        -LineStart $record.Line -LineEnd $record.Line -Field $record.Field `
                        -Sha256 (Get-ReviewerFactSha256 -Text ([string](Get-ReviewerFactValue $file "Content" "")))) `
                    -TrustTier "source-commit"))
            if ($identifierObservation.truncated) {
                [void]$facts.Add((New-ReviewerFact -Domain fanOut -Kind "observedValueTruncated" `
                        -Subject ($path + "#" + $identifierHash) -State true `
                        -Value ([ordered]@{
                            field = "identifier"
                            originalBytes = $identifierObservation.originalBytes
                            retainedBytes = $identifierObservation.retainedBytes
                            maxBytes = [int]$Policy.maxObservedValueBytes
                        }) -TrustTier "wrapper-observed"))
            }
        }
    }
    foreach ($entry in $identifierRecords) {
        $namespace = [IO.Path]::GetDirectoryName($entry.Path).Replace("\", "/")
        $surfaceNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($rule in @($Policy.companionRules)) {
            $identifierPattern = [string](Get-ReviewerFactValue $rule "identifierPattern" "")
            $pathPattern = [string](Get-ReviewerFactValue $rule "pathPattern" "")
            if ($identifierPattern -and -not [regex]::IsMatch(
                    $entry.Identifier, $identifierPattern, "CultureInvariant", [TimeSpan]::FromMilliseconds(250))) { continue }
            if ($pathPattern -and -not (Test-ReviewerFactPathPattern -Path $entry.Path -Pattern $pathPattern)) { continue }
            foreach ($surface in @(Get-ReviewerFactValue $rule "surfaces" @())) { [void]$surfaceNames.Add([string]$surface) }
        }
        foreach ($precedent in $precedents) {
            if ([string]::Equals([string](Get-ReviewerFactValue $precedent "namespace" ""), $namespace, [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string](Get-ReviewerFactValue $precedent "identifier" ""), $entry.Identifier, [StringComparison]::Ordinal)) {
                foreach ($surface in @(Get-ReviewerFactValue $precedent "surfaces" @())) { [void]$surfaceNames.Add([string]$surface) }
            }
        }
        $orderedSurfaces = [System.Collections.Generic.List[string]]::new()
        foreach ($surface in $surfaceNames) { [void]$orderedSurfaces.Add($surface) }
        $orderedSurfaces.Sort([StringComparer]::Ordinal)
        foreach ($surface in $orderedSurfaces) {
            $surfaceRecord = @($surfaceFiles | Where-Object {
                    [string]::Equals([string](Get-ReviewerFactValue $_ "Path" ""), $surface, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)
            if ($surfaceRecord.Count -eq 0) {
                $state = "unknown"; $reason = "unprovable"; $exists = $null
            }
            else {
                $existsRaw = Get-ReviewerFactValue $surfaceRecord[0] "Exists" $null
                if ($null -eq $existsRaw) { $state = "unknown"; $reason = "unprovable"; $exists = $null }
                else { $exists = [bool]$existsRaw; $state = $(if ($exists) { "true" } else { "false" }); $reason = "" }
            }
            $identifierObservation = Get-ReviewerFactBoundedObservation -Text $entry.Identifier `
                -MaxBytes ([int]$Policy.maxObservedValueBytes)
            $identifierHash = Get-ReviewerFactSha256 -Text $entry.Identifier
            [void]$facts.Add((New-ReviewerFact -Domain fanOut -Kind "companionSurfacePresent" `
                    -Subject ($namespace + "#" + $identifierHash + "#" + $surface) -State $state -UnknownReason $reason `
                    -Value ([ordered]@{ identifier = $identifierObservation.text; identifierSha256 = $identifierHash; namespace = $namespace; surface = $surface; exists = $exists }) `
                    -TrustTier "target-policy"))
        }
    }
    if ($identifierRecords.Count -eq 0) {
        [void]$facts.Add((New-ReviewerFact -Domain fanOut -Kind "domainApplicability" -Subject fanOut `
                -State notApplicable -Value ([ordered]@{ observedChangedFileCount = $files.Count }) -TrustTier "wrapper-observed"))
        return New-ReviewerFactDomainResult -Name fanOut -Status notApplicable -Facts $facts.ToArray()
    }
    return New-ReviewerFactDomainResult -Name fanOut -Status complete -Facts $facts.ToArray()
}

function Get-ReviewerFactAuthorClass {
    param($Comment, [string[]]$BotSubstrings = @(), [string[]]$SystemSubstrings = @())
    $explicit = [string](Get-ReviewerFactValue $Comment "authorClass" "")
    if ($explicit -in @("human", "bot", "system", "agent", "unknown")) { return $explicit }
    $identity = ([string](Get-ReviewerFactValue $Comment "authorDisplayName" "")) + "`n" +
        ([string](Get-ReviewerFactValue $Comment "authorUniqueName" ""))
    foreach ($term in $SystemSubstrings) {
        if ($term -and $identity.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return "system" }
    }
    foreach ($term in $BotSubstrings) {
        if ($term -and $identity.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return "bot" }
    }
    if ($identity.Trim()) { return "human" }
    return "unknown"
}

function ConvertTo-ReviewerFactSanitizedSubstance {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Assert-ReviewerFactStrictText -Text $Text -Where "thread comment"
    $value = $Text -replace '[\u202a-\u202e\u2066-\u2069\u061c\u200e\u200f]', ''
    $value = $value -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', ' '
    $timeout = [TimeSpan]::FromMilliseconds(250)
    $value = [regex]::Replace($value, '<[^>]{0,2048}>', ' ', "CultureInvariant", $timeout)
    $value = [regex]::Replace($value, '!\[[^\]]*\]\([^)]+\)', ' ', "CultureInvariant", $timeout)
    $value = [regex]::Replace($value, '\[([^\]]+)\]\([^)]+\)', '$1', "CultureInvariant", $timeout)
    $credentialPattern = '(?i)\b(password|passwd|pwd|token|secret|api[-_]?key)\s*[:=]\s*[^\s,;]+'
    $tokenPattern = '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b'
    $value = [regex]::Replace($value, $credentialPattern, '$1=[REDACTED]', "CultureInvariant", $timeout)
    $value = [regex]::Replace($value, $tokenPattern, '[REDACTED]', "CultureInvariant", $timeout)
    $value = $value -replace '[`*~]', ''
    $value = $value -replace '[>#]', ' '
    $value = ([regex]::Replace($value, '\s+', ' ', "CultureInvariant", $timeout)).Trim()
    $value = [regex]::Replace($value, $credentialPattern, '$1=[REDACTED]', "CultureInvariant", $timeout)
    return [regex]::Replace($value, $tokenPattern, '[REDACTED]', "CultureInvariant", $timeout)
}

function Limit-ReviewerFactUtf8Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [ValidateRange(0, 1048576)][int]$MaxBytes)
    Assert-ReviewerFactStrictText -Text $Text -Where "bounded thread substance"
    $bytes = $script:ReviewerFactUtf8.GetByteCount($Text)
    if ($bytes -le $MaxBytes) { return [pscustomobject]@{ Text = $Text; ByteLength = $bytes; Truncated = $false } }
    $builder = [Text.StringBuilder]::new()
    $retainedBytes = 0
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = [string]$elements.Current
        $elementBytes = $script:ReviewerFactUtf8.GetByteCount($element)
        if ($retainedBytes + $elementBytes -gt $MaxBytes) { break }
        [void]$builder.Append($element)
        $retainedBytes += $elementBytes
    }
    $bounded = $builder.ToString()
    return [pscustomobject]@{ Text = $bounded; ByteLength = $script:ReviewerFactUtf8.GetByteCount($bounded); Truncated = $true }
}

function Get-ReviewerThreadFacts {
    param([Parameter(Mandatory)]$Envelope, [Parameter(Mandatory)]$Policy)
    if ((Get-ReviewerFactEnvelopeStatus $Envelope) -ne "available") {
        return New-ReviewerFactUnavailableDomain -Domain threads -Envelope $Envelope
    }
    $data = Get-ReviewerFactValue $Envelope "Data"
    $threads = @(Get-ReviewerFactValue $data "Threads" @())
    $complete = [bool](Get-ReviewerFactValue $data "Complete" $false)
    if (-not $complete -or $threads.Count -ge [int]$Policy.maxThreads) {
        return New-ReviewerFactUnavailableDomain -Domain threads -Envelope @{
            Status = "truncated"; ErrorCode = "threadSetIncomplete"; Error = "The thread set was not proven complete."
        }
    }
    $botTerms = @(Get-ReviewerFactValue $data "BotSubstrings" @())
    $systemTerms = @(Get-ReviewerFactValue $data "SystemSubstrings" @())
    $facts = [System.Collections.Generic.List[object]]::new()
    $totalRemaining = [int]$Policy.maxSubstanceBytesTotal
    $orderedThreads = [System.Collections.Generic.List[object]]::new()
    foreach ($thread in $threads) { [void]$orderedThreads.Add($thread) }
    $orderedThreads.Sort([System.Comparison[object]] {
            param($left, $right)
            $leftId = [int64](Get-ReviewerFactValue $left "threadId" 0)
            $rightId = [int64](Get-ReviewerFactValue $right "threadId" 0)
            return $leftId.CompareTo($rightId)
        })
    foreach ($thread in $orderedThreads) {
        $threadId = [int64](Get-ReviewerFactValue $thread "threadId" 0)
        $path = [string](Get-ReviewerFactValue $thread "filePath" "")
        $line = [int](Get-ReviewerFactValue $thread "line" 0)
        $status = [string](Get-ReviewerFactValue $thread "status" "unknown")
        $comments = @(Get-ReviewerFactValue $thread "comments" @())
        $rawParts = [System.Collections.Generic.List[string]]::new()
        $classes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($comment in $comments) {
            [void]$classes.Add((Get-ReviewerFactAuthorClass -Comment $comment -BotSubstrings $botTerms -SystemSubstrings $systemTerms))
            [void]$rawParts.Add([string](Get-ReviewerFactValue $comment "content" ""))
        }
        $raw = $rawParts.ToArray() -join "`n"
        Assert-ReviewerFactStrictText -Text $raw -Where "thread content"
        $contentHash = Get-ReviewerFactSha256 -Text (($raw -replace "`r`n", "`n"))
        $sanitized = ConvertTo-ReviewerFactSanitizedSubstance -Text $raw
        $threadCap = [Math]::Min([int]$Policy.maxSubstanceBytesPerThread, [Math]::Max(0, $totalRemaining))
        $bounded = Limit-ReviewerFactUtf8Text -Text $sanitized -MaxBytes $threadCap
        $totalRemaining -= $bounded.ByteLength
        $orderedClasses = [System.Collections.Generic.List[string]]::new()
        foreach ($class in $classes) { [void]$orderedClasses.Add($class) }
        $orderedClasses.Sort([StringComparer]::Ordinal)
        $fingerprint = Get-ReviewerFactObjectSha256 -Value ([ordered]@{
            status = $status; path = $path; line = $line
            authorClasses = $orderedClasses.ToArray(); contentSha256 = $contentHash
        })
        [void]$facts.Add((New-ReviewerFact -Domain threads -Kind "reviewThread" `
                -Subject ([System.Convert]::ToString($threadId, [Globalization.CultureInfo]::InvariantCulture)) `
                -State true -Value ([ordered]@{
                    fingerprint = $fingerprint
                    status = $status
                    authorClasses = $orderedClasses.ToArray()
                    filePath = $path
                    line = $line
                    commentCount = $comments.Count
                    contentSha256 = $contentHash
                    sanitizedSubstance = $bounded.Text
                    substanceBytes = $bounded.ByteLength
                    substanceTruncated = [bool]$bounded.Truncated
                    trustTier = "untrusted-author-controlled"
                }) -Evidence @(New-ReviewerFactEvidence -SourceType "pullRequestThreadApi" -Path $path `
                    -LineStart $line -LineEnd $line -Field ("thread:" + [string]$threadId) -Sha256 $contentHash) `
                -TrustTier "untrusted-author-controlled"))
        if ($bounded.Truncated) {
            [void]$facts.Add((New-ReviewerFact -Domain threads -Kind "threadSubstanceTruncated" `
                    -Subject ([string]$threadId) -State true `
                    -Value ([ordered]@{ maxBytes = $threadCap; retainedBytes = $bounded.ByteLength }) `
                    -TrustTier "wrapper-observed"))
        }
    }
    $threadSetDigest = Get-ReviewerFactObjectSha256 -Value @($orderedThreads | ForEach-Object {
            [ordered]@{
                threadId = [int64](Get-ReviewerFactValue $_ "threadId" 0)
                status = [string](Get-ReviewerFactValue $_ "status" "unknown")
                filePath = [string](Get-ReviewerFactValue $_ "filePath" "")
                line = [int](Get-ReviewerFactValue $_ "line" 0)
                commentHashes = @(@(Get-ReviewerFactValue $_ "comments" @()) | ForEach-Object {
                        Get-ReviewerFactSha256 -Text ([string](Get-ReviewerFactValue $_ "content" ""))
                    })
            }
        })
    [void]$facts.Add((New-ReviewerFact -Domain threads -Kind "threadSetComplete" -Subject threads `
            -State true -Value ([ordered]@{ threadCount = $threads.Count; threadSetDigest = $threadSetDigest }) `
            -TrustTier "wrapper-observed"))
    return New-ReviewerFactDomainResult -Name threads -Status complete -Facts $facts.ToArray()
}

function Get-ReviewerChangeFacts {
    param([Parameter(Mandatory)]$Envelope)
    if ((Get-ReviewerFactEnvelopeStatus $Envelope) -ne "available") {
        return New-ReviewerFactUnavailableDomain -Domain changes -Envelope $Envelope
    }
    $data = Get-ReviewerFactValue $Envelope "Data"
    $entries = @(Get-ReviewerFactValue $data "Entries" @())
    if ($entries.Count -eq 0) {
        return New-ReviewerFactUnavailableDomain -Domain changes -Envelope @{
            Status = "failed"; ErrorCode = "emptyChangeSet"; Error = "An active PR did not produce normalized file entries."
        }
    }
    $lines = @(Get-ReviewerFactValue $data "Lines" @())
    $facts = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $path = [string](Get-ReviewerFactValue $entry "Path" "")
        $role = [string](Get-ReviewerFactValue $entry "Role" "")
        $types = @(Get-ReviewerFactValue $entry "ChangeTypes" @())
        [void]$facts.Add((New-ReviewerFact -Domain changes -Kind "changedFile" -Subject ($path + "#" + $role) `
                -State true -Value ([ordered]@{ path = $path; role = $role; changeTypes = $types }) `
                -Evidence @(New-ReviewerFactEvidence -SourceType "pinnedChangeSet" -Path $path -Field $role) `
                -TrustTier "wrapper-observed"))
        $fileLines = @($lines | Where-Object {
                [string]::Equals([string](Get-ReviewerFactValue $_ "Path" ""), $path, [StringComparison]::OrdinalIgnoreCase)
            })
        if ($fileLines.Count -eq 0) {
            [void]$facts.Add((New-ReviewerFact -Domain changes -Kind "changedLineCoverage" -Subject $path `
                    -State unknown -UnknownReason unprovable -Value $null -TrustTier "wrapper-observed"))
        }
        else {
            foreach ($span in $fileLines) {
                $start = [int](Get-ReviewerFactValue $span "Start" 0)
                $end = [int](Get-ReviewerFactValue $span "End" $start)
                [void]$facts.Add((New-ReviewerFact -Domain changes -Kind "changedLineSpan" `
                        -Subject ($path + ":" + [string]$start + "-" + [string]$end) -State true `
                        -Value ([ordered]@{ path = $path; start = $start; end = $end }) `
                        -Evidence @(New-ReviewerFactEvidence -SourceType "pinnedChangeSet" -Path $path `
                            -LineStart $start -LineEnd $end -Field "right") -TrustTier "wrapper-observed"))
            }
        }
    }
    return New-ReviewerFactDomainResult -Name changes -Status complete -Facts $facts.ToArray()
}

function Sort-ReviewerFacts {
    param([object[]]$Facts)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($fact in @($Facts)) { [void]$list.Add($fact) }
    $list.Sort([System.Comparison[object]] {
            param($left, $right)
            foreach ($field in @("domain", "kind", "subject", "id")) {
                $comparison = [StringComparer]::Ordinal.Compare([string]$left.$field, [string]$right.$field)
                if ($comparison -ne 0) { return $comparison }
            }
            return 0
        })
    return $list.ToArray()
}

function Resolve-ReviewerFactIds {
    param([object[]]$Facts)
    $byId = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($fact in @(Sort-ReviewerFacts -Facts $Facts)) {
        $id = [string]$fact.id
        if (-not $byId.ContainsKey($id)) {
            $byId.Add($id, $fact)
            continue
        }
        $existing = ConvertTo-ReviewerFactCanonicalJson -Value $byId[$id]
        $candidate = ConvertTo-ReviewerFactCanonicalJson -Value $fact
        if (-not [string]::Equals($existing, $candidate, [StringComparison]::Ordinal)) {
            throw "Fact id '$id' collided across different fact values."
        }
    }
    return Sort-ReviewerFacts -Facts @($byId.Values)
}

function New-ReviewerFactPlan {
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)]$Hashes,
        [Parameter(Mandatory)]$Inputs,
        [Parameter(Mandatory)]$Policy
    )
    foreach ($name in @("organization", "project", "repositoryId", "sourceCommit", "targetCommit", "changeSetDigest")) {
        if (-not [string](Get-ReviewerFactValue $Binding $name "")) { throw "Fact plan binding '$name' is required." }
    }
    foreach ($name in @("sourceCommit", "targetCommit")) {
        if ([string](Get-ReviewerFactValue $Binding $name "") -notmatch '^[0-9a-f]{40}$') {
            throw "Fact plan binding '$name' must be lowercase 40-hex."
        }
    }
    if ([string](Get-ReviewerFactValue $Binding "changeSetDigest" "") -notmatch '^[0-9a-f]{64}$') {
        throw "Fact plan changeSetDigest must be lowercase 64-hex."
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $extractors = @(
        @{ Name = "metadata"; MaxFactBytes = [int]$Policy.metadata.maxFactBytes; Action = { Get-ReviewerMetadataFacts -Envelope (Get-ReviewerFactValue $Inputs "metadata") -Policy $Policy.metadata } },
        @{ Name = "cloudTest"; MaxFactBytes = [int]$Policy.cloudTest.maxFactBytes; Action = { Get-ReviewerCloudTestFacts -Envelope (Get-ReviewerFactValue $Inputs "cloudTest") -Policy $Policy.cloudTest } },
        @{ Name = "fanOut"; MaxFactBytes = [int]$Policy.fanOut.maxFactBytes; Action = { Get-ReviewerFanOutFacts -Envelope (Get-ReviewerFactValue $Inputs "fanOut") -Policy $Policy.fanOut } },
        @{ Name = "threads"; MaxFactBytes = [int]$Policy.threads.maxFactBytes; Action = { Get-ReviewerThreadFacts -Envelope (Get-ReviewerFactValue $Inputs "threads") -Policy $Policy.threads } },
        @{ Name = "changes"; MaxFactBytes = [int]$Policy.changes.maxFactBytes; Action = { Get-ReviewerChangeFacts -Envelope (Get-ReviewerFactValue $Inputs "changes") } }
    )
    foreach ($extractor in $extractors) {
        try {
            $domainResult = & $extractor.Action
            $domainBytes = $script:ReviewerFactUtf8.GetByteCount(
                (ConvertTo-ReviewerFactCanonicalJson -Value ([ordered]@{
                        name = $domainResult.name
                        status = $domainResult.status
                        errorCode = $domainResult.errorCode
                        errorMessage = $domainResult.errorMessage
                        facts = @($domainResult.facts)
                    })))
            if ($domainBytes -gt [int]$extractor.MaxFactBytes) {
                throw "Fact domain '$($extractor.Name)' requires $domainBytes bytes, above the versioned $($extractor.MaxFactBytes)-byte domain cap."
            }
            [void]$results.Add($domainResult)
        }
        catch {
            $errorCode = if ($_.Exception.Message -match 'invalid Unicode|malformed|has no exact|unsupported format|no explicit') {
                "malformed"
            }
            elseif ($_.Exception.Message -match 'above the versioned|exceeded') { "capExceeded" }
            else { "malformed" }
            $envelope = @{
                Status = "failed"
                ErrorCode = $errorCode
                Error = $_.Exception.Message
            }
            [void]$results.Add((New-ReviewerFactUnavailableDomain -Domain $extractor.Name -Envelope $envelope))
        }
    }
    $allFacts = Resolve-ReviewerFactIds -Facts @($results | ForEach-Object { @($_.facts) })
    $domainSummaries = @($results | ForEach-Object {
            [pscustomobject][ordered]@{
                name = $_.name
                status = $_.status
                errorCode = $_.errorCode
                errorMessage = $_.errorMessage
                factCount = $_.factCount
            }
        })
    $failedCount = @($domainSummaries | Where-Object { $_.status -eq "failed" }).Count
    $applicableCount = @($domainSummaries | Where-Object { $_.status -ne "notApplicable" }).Count
    $status = if ($failedCount -eq 0) { "complete" }
        elseif ($applicableCount -gt 0 -and $failedCount -ge $applicableCount) { "failed" }
        else { "partial" }
    $body = [pscustomobject][ordered]@{
        planVersion      = $script:ReviewerFactPlanVersion
        schemaVersion    = $script:ReviewerFactSchemaVersion
        extractorVersion = $script:ReviewerFactExtractorVersion
        status           = $status
        binding          = $Binding
        hashes           = $Hashes
        domains          = $domainSummaries
        facts            = $allFacts
        factCount        = $allFacts.Count
    }
    $canonical = ConvertTo-ReviewerFactCanonicalJson -Value $body
    $bytes = $script:ReviewerFactUtf8.GetByteCount($canonical)
    $maxBytes = [int](Get-ReviewerFactValue $Policy "maxPlanBytes" 0)
    if ($maxBytes -lt 1 -or $bytes -gt $maxBytes) {
        throw "Fact plan requires $bytes canonical bytes, above the versioned $maxBytes-byte cap."
    }
    return [pscustomobject][ordered]@{
        planVersion      = $body.planVersion
        schemaVersion    = $body.schemaVersion
        extractorVersion = $body.extractorVersion
        status           = $body.status
        binding          = $body.binding
        hashes           = $body.hashes
        domains          = $body.domains
        facts            = $body.facts
        factCount        = $body.factCount
        canonicalBytes   = $bytes
        planSha256       = Get-ReviewerFactSha256 -Text $canonical
    }
}

function Test-ReviewerFactPlanBinding {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$ExpectedBinding,
        [Parameter(Mandatory)]$ExpectedHashes
    )
    $actual = [ordered]@{
        binding = Get-ReviewerFactValue $Plan "binding"
        hashes = Get-ReviewerFactValue $Plan "hashes"
    }

    $expected = [ordered]@{ binding = $ExpectedBinding; hashes = $ExpectedHashes }
    return [string]::Equals(
        (ConvertTo-ReviewerFactCanonicalJson -Value $actual),
        (ConvertTo-ReviewerFactCanonicalJson -Value $expected),
        [StringComparison]::Ordinal)
}

function Test-ReviewerFactPlanIntegrity {
    param([Parameter(Mandatory)]$Plan)
    $body = [pscustomobject][ordered]@{
        planVersion      = Get-ReviewerFactValue $Plan "planVersion"
        schemaVersion    = Get-ReviewerFactValue $Plan "schemaVersion"
        extractorVersion = Get-ReviewerFactValue $Plan "extractorVersion"
        status           = Get-ReviewerFactValue $Plan "status"
        binding          = Get-ReviewerFactValue $Plan "binding"
        hashes           = Get-ReviewerFactValue $Plan "hashes"
        domains          = Get-ReviewerFactValue $Plan "domains"
        facts            = Get-ReviewerFactValue $Plan "facts"
        factCount        = Get-ReviewerFactValue $Plan "factCount"
    }
    $canonical = ConvertTo-ReviewerFactCanonicalJson -Value $body
    $bytes = $script:ReviewerFactUtf8.GetByteCount($canonical)
    $sha256 = Get-ReviewerFactSha256 -Text $canonical
    return (
        [int](Get-ReviewerFactValue $Plan "canonicalBytes" -1) -eq $bytes -and
        [string]::Equals([string](Get-ReviewerFactValue $Plan "planSha256" ""), $sha256, [StringComparison]::Ordinal)
    )
}

function Get-ReviewerFactPlanSignature {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([BitConverter]::ToString(
                $hmac.ComputeHash($script:ReviewerFactUtf8.GetBytes($Json)))).Replace("-", "").ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Test-ReviewerFactPlanSignature {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][byte[]]$Key,
        [AllowEmptyString()][string]$Signature = ""
    )
    if ($Signature -notmatch '^[0-9a-f]{64}$') { return $false }
    $expected = Get-ReviewerFactPlanSignature -Json $Json -Key $Key
    $left = [Convert]::FromHexString($expected)
    $right = [Convert]::FromHexString($Signature)
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($left, $right)
}

function Save-ReviewerFactPlanFile {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][byte[]]$Key
    )
    if (-not (Test-ReviewerFactPlanIntegrity -Plan $Plan)) {
        throw "A persisted fact plan failed its canonical byte/hash integrity check."
    }
    if ($BaseName -notmatch '^[A-Za-z0-9._-]+$') { throw "Fact plan base name is unsafe." }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Fact plan directory '$Directory' does not exist."
    }
    $path = Join-Path $Directory ($BaseName + ".json")
    $signaturePath = $path + ".sig"
    $json = $Plan | ConvertTo-Json -Depth 32 -Compress
    $signature = Get-ReviewerFactPlanSignature -Json $json -Key $Key
    $nonce = [Guid]::NewGuid().ToString("N")
    $tempPath = $path + "." + $nonce + ".tmp"
    $tempSignaturePath = $signaturePath + "." + $nonce + ".tmp"
    try {
        [IO.File]::WriteAllText($tempPath, $json, $script:ReviewerFactUtf8)
        [IO.File]::WriteAllText($tempSignaturePath, $signature, [Text.Encoding]::ASCII)
        Move-Item -LiteralPath $tempPath -Destination $path -Force
        Move-Item -LiteralPath $tempSignaturePath -Destination $signaturePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
        if (Test-Path -LiteralPath $tempSignaturePath) { Remove-Item -LiteralPath $tempSignaturePath -Force }
    }
    return $path
}

function Read-ReviewerFactPlanFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $signaturePath = $Path + ".sig"
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        -not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) {
        throw "Fact plan or its detached signature is missing."
    }
    $json = [IO.File]::ReadAllText($Path, $script:ReviewerFactUtf8)
    $signature = [IO.File]::ReadAllText($signaturePath, [Text.Encoding]::ASCII).Trim()
    if (-not (Test-ReviewerFactPlanSignature -Json $json -Key $Key -Signature $signature)) {
        throw "Fact plan signature verification failed."
    }
    if (-not (Test-Json -Json $json -SchemaFile $SchemaPath)) {
        throw "Fact plan failed the versioned JSON schema."
    }
    $plan = $json | ConvertFrom-Json -Depth 32
    if (-not (Test-ReviewerFactPlanIntegrity -Plan $plan)) {
        throw "Fact plan failed its canonical byte/hash integrity check."
    }
    return $plan
}
