#requires -Version 7.0

Set-StrictMode -Version Latest

class ReviewerConventionEnvironmentException : System.Exception {
    ReviewerConventionEnvironmentException([string]$message, [System.Exception]$innerException) :
        base($message, $innerException) {}
}

$script:ReviewerConventionPackSchemaVersion = 1
$script:ReviewerConventionPlanVersion = 1
$script:ReviewerConventionMaxPacks = 32
$script:ReviewerConventionMaxGlobsPerPack = 64
$script:ReviewerConventionMaxRepositorySourcesPerPack = 16
$script:ReviewerConventionMaxPackBytes = 131072
$script:ReviewerConventionMaxTotalBytes = 131072
$script:ReviewerConventionMaxPathLength = 1024
$script:ReviewerConventionUtf8 = New-Object System.Text.UTF8Encoding($false)

function Get-ReviewerConventionValue {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            $value = $Object[$Name]
            if ($value -is [System.Array]) { return , $value }
            return $value
        }
        return $Default
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) {
            if ($property.Value -is [System.Array]) { return , $property.Value }
            return $property.Value
        }
    }
    return $Default
}

function Assert-ReviewerConventionExactKeys {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string[]]$Required,
        [Parameter(Mandatory)][string]$Where
    )
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$Where must be a JSON object."
    }
    $names = @($Object.PSObject.Properties.Name)
    $unknown = @($names | Where-Object { $Allowed -cnotcontains $_ })
    if ($unknown.Count -gt 0) { throw "$Where contains unknown key(s): $($unknown -join ', ')." }
    $missing = @($Required | Where-Object { $names -cnotcontains $_ })
    if ($missing.Count -gt 0) { throw "$Where is missing required key(s): $($missing -join ', ')." }
}

function Get-ReviewerConventionStrictInt {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where,
        [long]$Min,
        [long]$Max
    )
    $value = Get-ReviewerConventionValue -Object $Object -Name $Name
    if ($null -eq $value -or $value -is [bool] -or -not ($value -is [int] -or $value -is [long])) {
        throw "$Where.$Name must be a JSON integer."
    }
    $number = [long]$value
    if ($number -lt $Min -or $number -gt $Max) {
        throw "$Where.$Name must be in the range $Min..$Max."
    }
    return [int]$number
}

function Get-ReviewerConventionStrictBoolean {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where
    )
    $value = Get-ReviewerConventionValue -Object $Object -Name $Name
    if ($value -isnot [bool]) { throw "$Where.$Name must be a JSON boolean." }
    return [bool]$value
}

function Get-ReviewerConventionStringArray {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where,
        [int]$MinCount = 0,
        [int]$MaxCount = 64,
        [int]$MaxLength = 1024
    )
    $value = Get-ReviewerConventionValue -Object $Object -Name $Name
    if ($null -eq $value -or $value -is [string] -or $value -is [System.Management.Automation.PSCustomObject]) {
        throw "$Where.$Name must be a JSON array."
    }
    $items = @($value)
    if ($items.Count -lt $MinCount -or $items.Count -gt $MaxCount) {
        throw "$Where.$Name must contain $MinCount..$MaxCount entries."
    }
    $result = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $items.Count; $index++) {
        if ($items[$index] -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$items[$index])) {
            throw "$Where.${Name}[$index] must be a non-empty JSON string."
        }
        $text = [string]$items[$index]
        if ($text.Length -gt $MaxLength) { throw "$Where.${Name}[$index] exceeds $MaxLength characters." }
        [void]$result.Add($text)
    }
    return $result.ToArray()
}

function ConvertTo-ReviewerConventionRelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Where = "changed path"
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt $script:ReviewerConventionMaxPathLength -or
        $Path -match '[\x00-\x1f\x7f]' -or $Path -match '^[A-Za-z]:' -or
        $Path.StartsWith("\\", [StringComparison]::Ordinal) -or $Path.StartsWith("//", [StringComparison]::Ordinal)) {
        throw "$Where is not a safe repository-relative path."
    }
    $normalized = $Path.Replace('\', '/')
    if ($normalized.StartsWith("/", [StringComparison]::Ordinal)) { $normalized = $normalized.Substring(1) }
    $segments = @($normalized.Split('/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq "" -or $_ -eq "." -or $_ -eq ".." }).Count -gt 0) {
        throw "$Where contains an empty or dot segment."
    }
    return ($segments -join '/')
}

function Test-ReviewerConventionRepositorySourcePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt $script:ReviewerConventionMaxPathLength -or
        -not $Path.StartsWith("/", [StringComparison]::Ordinal) -or $Path.Contains('\') -or
        $Path -match '[\x00-\x1f\x7f?#]') {
        return $false
    }
    try { $relative = ConvertTo-ReviewerConventionRelativePath -Path $Path -Where "repository source path" }
    catch { return $false }
    $extension = [System.IO.Path]::GetExtension($relative)
    return @(".md", ".txt") -ccontains $extension
}

function Test-ReviewerConventionGlob {
    param([string]$Glob)
    if ([string]::IsNullOrWhiteSpace($Glob) -or $Glob.Length -gt $script:ReviewerConventionMaxPathLength -or
        $Glob -notmatch '^[\x20-\x7e]+$' -or $Glob.StartsWith("/", [StringComparison]::Ordinal) -or
        $Glob.Contains('\') -or $Glob.Contains("//") -or $Glob.EndsWith("/", [StringComparison]::Ordinal) -or
        $Glob.Contains("..")) {
        return $false
    }
    foreach ($unsupported in @("[", "]", "{", "}", "(", ")", "!", "+", "@", "^", '$', "|")) {
        if ($Glob.Contains($unsupported, [StringComparison]::Ordinal)) { return $false }
    }
    $segments = @($Glob.Split('/'))
    if ($segments.Count -eq 0 -or $segments.Count -gt 64 -or
        @($segments | Where-Object { $_ -eq "" -or $_ -eq "." -or $_ -eq ".." }).Count -gt 0) {
        return $false
    }
    if ($Glob -ceq "**") { return $false }
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = $segments[$index]
        if ($segment.Contains("**") -and $segment -cne "**") { return $false }
        if ($index -gt 0 -and $segment -ceq "**" -and $segments[$index - 1] -ceq "**") { return $false }
    }
    return $true
}

function Test-ReviewerConventionSegmentMatch {
    param([Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Value)
    $patternIndex = 0
    $valueIndex = 0
    $starIndex = -1
    $retryValueIndex = -1
    while ($valueIndex -lt $Value.Length) {
        if ($patternIndex -lt $Pattern.Length -and
            ($Pattern[$patternIndex] -eq '?' -or
                [char]::ToUpperInvariant($Pattern[$patternIndex]) -eq [char]::ToUpperInvariant($Value[$valueIndex]))) {
            $patternIndex++
            $valueIndex++
            continue
        }
        if ($patternIndex -lt $Pattern.Length -and $Pattern[$patternIndex] -eq '*') {
            $starIndex = $patternIndex
            $retryValueIndex = $valueIndex
            $patternIndex++
            continue
        }
        if ($starIndex -ge 0) {
            $patternIndex = $starIndex + 1
            $retryValueIndex++
            $valueIndex = $retryValueIndex
            continue
        }
        return $false
    }
    while ($patternIndex -lt $Pattern.Length -and $Pattern[$patternIndex] -eq '*') { $patternIndex++ }
    return $patternIndex -eq $Pattern.Length
}

function Test-ReviewerConventionGlobMatch {
    param(
        [Parameter(Mandatory)][string]$Glob,
        [Parameter(Mandatory)][string]$Path
    )
    $patternSegments = @($Glob -split '/')
    $pathSegments = @($Path -split '/')
    $memo = @{}
    $visit = $null
    $visit = {
        param([int]$PatternIndex, [int]$PathIndex)
        $key = "$PatternIndex,$PathIndex"
        if ($memo.ContainsKey($key)) { return [bool]$memo[$key] }
        $matched = $false
        if ($PatternIndex -eq $patternSegments.Count) {
            $matched = ($PathIndex -eq $pathSegments.Count)
        }
        elseif ($patternSegments[$PatternIndex] -ceq "**") {
            $matched = (& $visit ($PatternIndex + 1) $PathIndex)
            if (-not $matched -and $PathIndex -lt $pathSegments.Count) {
                $matched = (& $visit $PatternIndex ($PathIndex + 1))
            }
        }
        elseif ($PathIndex -lt $pathSegments.Count -and
            (Test-ReviewerConventionSegmentMatch -Pattern $patternSegments[$PatternIndex] -Value $pathSegments[$PathIndex])) {
            $matched = (& $visit ($PatternIndex + 1) ($PathIndex + 1))
        }
        $memo[$key] = [bool]$matched
        return [bool]$matched
    }
    return (& $visit 0 0)
}

function Get-ReviewerConventionChangeTypes {
    param($Value)
    $types = New-Object System.Collections.Generic.List[string]
    if ($Value -is [int] -or $Value -is [long]) {
        $number = [long]$Value
        foreach ($entry in @(
                @{ Bit = 1; Name = "add" }, @{ Bit = 2; Name = "edit" },
                @{ Bit = 8; Name = "rename" }, @{ Bit = 16; Name = "delete" },
                @{ Bit = 1024; Name = "sourceRename" })) {
            if (($number -band [long]$entry.Bit) -ne 0) { [void]$types.Add([string]$entry.Name) }
        }
    }
    elseif ($Value -is [string]) {
        foreach ($part in ([string]$Value -split ',')) {
            $normalized = $part.Trim().ToLowerInvariant()
            if ($normalized) { [void]$types.Add($normalized) }
        }
    }
    if ($types.Count -eq 0) { [void]$types.Add("unknown") }
    return @($types.ToArray() | Select-Object -Unique)
}

function Get-ReviewerConventionChangeArray {
    param($Response)
    $node = $Response
    for ($depth = 0; $depth -lt 4; $depth++) {
        if ($null -eq $node) { break }
        if ($null -ne (Get-ReviewerConventionValue -Object $node -Name "item") -or
            $null -ne (Get-ReviewerConventionValue -Object $node -Name "path")) { break }
        $inner = $null
        foreach ($key in @("changeEntries", "changes", "value")) {
            $candidate = Get-ReviewerConventionValue -Object $node -Name $key
            if ($null -ne $candidate) { $inner = $candidate; break }
        }
        if ($null -eq $inner) { break }
        $node = $inner
    }
    return @($node)
}

function Test-ReviewerConventionResponseTruncated {
    param(
        [Parameter(Mandatory)]$Response,
        [int]$Limit = 1000
    )
    return @(Get-ReviewerConventionChangeArray -Response $Response).Count -ge $Limit
}

function ConvertTo-ReviewerConventionChangeSet {
    param([Parameter(Mandatory)]$Response)
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($change in @(Get-ReviewerConventionChangeArray -Response $Response)) {
        if ($null -eq $change) { continue }
        $item = Get-ReviewerConventionValue -Object $change -Name "item"
        $isFolder = [bool](Get-ReviewerConventionValue -Object $item -Name "isFolder" -Default $false)
        if ($isFolder) { continue }
        $current = [string](Get-ReviewerConventionValue -Object $item -Name "path" -Default "")
        if (-not $current) { $current = [string](Get-ReviewerConventionValue -Object $change -Name "path" -Default "") }
        $previous = [string](Get-ReviewerConventionValue -Object $change -Name "sourceServerItem" -Default "")
        if (-not $previous) { $previous = [string](Get-ReviewerConventionValue -Object $item -Name "sourceServerItem" -Default "") }
        $types = @(Get-ReviewerConventionChangeTypes -Value (Get-ReviewerConventionValue -Object $change -Name "changeType"))
        $isRename = @($types | Where-Object { $_ -in @("rename", "sourcerename") }).Count -gt 0
        $isDelete = @($types | Where-Object { $_ -eq "delete" }).Count -gt 0
        $paths = New-Object System.Collections.Generic.List[object]
        if ($current) {
            [void]$paths.Add([pscustomobject]@{
                    RawPath = $current
                    Role    = $(if ($isDelete) { "deleted" } else { "current" })
                })
        }
        if ($previous -and ($isRename -or $types -contains "unknown")) {
            [void]$paths.Add([pscustomobject]@{ RawPath = $previous; Role = "previous" })
        }
        foreach ($pathRecord in $paths) {
            $normalized = ConvertTo-ReviewerConventionRelativePath -Path $pathRecord.RawPath -Where "changed path '$($pathRecord.RawPath)'"
            [void]$records.Add([pscustomobject]@{
                    Path        = $normalized
                    OriginalPath = [string]$pathRecord.RawPath
                    Role        = [string]$pathRecord.Role
                    ChangeTypes = @($types)
                })
        }
    }
    $orderedList = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) { [void]$orderedList.Add($record) }
    $entryComparison = [System.Comparison[object]] {
        param($left, $right)
        $comparison = [StringComparer]::OrdinalIgnoreCase.Compare([string]$left.Path, [string]$right.Path)
        if ($comparison -eq 0) { $comparison = [StringComparer]::Ordinal.Compare([string]$left.Role, [string]$right.Role) }
        if ($comparison -eq 0) { $comparison = [StringComparer]::Ordinal.Compare([string]$left.OriginalPath, [string]$right.OriginalPath) }
        return $comparison
    }
    $orderedList.Sort($entryComparison)
    $ordered = $orderedList.ToArray()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $ordered) {
        $key = "$($entry.Path)`n$($entry.Role)"
        if ($seen.Add($key)) { [void]$result.Add($entry) }
    }
    return $result.ToArray()
}

function Get-ReviewerConventionSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($script:ReviewerConventionUtf8.GetBytes($Text))
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function New-ReviewerConventionEnvironmentException {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Exception]$InnerException
    )
    return [ReviewerConventionEnvironmentException]::new(
        "Convention transport operation '$Operation' failed: $($InnerException.Message)",
        $InnerException)
}

function Test-ReviewerConventionEnvironmentException {
    param([System.Exception]$Exception)
    return $Exception -is [ReviewerConventionEnvironmentException]
}

function Get-ReviewerConventionChangeSetDigest {
    param([object[]]$Entries = @())
    $lines = @($Entries | ForEach-Object {
            "$($_.Path)`t$($_.Role)`t$(@($_.ChangeTypes) -join ',')"
        })
    return Get-ReviewerConventionSha256 -Text (($lines -join "`n") + $(if ($lines.Count -gt 0) { "`n" } else { "" }))
}

function Test-ReviewerConventionCommitEqual {
    param([string]$Left, [string]$Right)
    return ($Left -match '^[0-9a-fA-F]{40}$' -and $Right -match '^[0-9a-fA-F]{40}$' -and
        [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase))
}

function Get-ReviewerConventionSourceIdentity {
    param([Parameter(Mandatory)]$Source)
    return ("{0}`n{1}`n{2}`n{3}`n{4}" -f
        [string](Get-ReviewerConventionValue $Source "Organization"),
        [string](Get-ReviewerConventionValue $Source "Project"),
        [string](Get-ReviewerConventionValue $Source "RepositoryId"),
        [string](Get-ReviewerConventionValue $Source "Branch"),
        [string](Get-ReviewerConventionValue $Source "Path")).ToUpperInvariant()
}

function ConvertTo-ReviewerConventionPackPolicy {
    param(
        [Parameter(Mandatory)]$RawPolicy,
        [Parameter(Mandatory)][hashtable]$AuthoritativeSourcePolicy,
        [hashtable]$RepositoryBinding = @{
            Organization = "x"; Project = "x"; RepositoryId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            TargetRef = "refs/heads/main"
        }
    )
    Assert-ReviewerConventionExactKeys -Object $RawPolicy `
        -Allowed @("note", "schemaVersion", "requireAllSourcesReferenced", "authoritativeSources", "packs") `
        -Required @("schemaVersion", "requireAllSourcesReferenced", "authoritativeSources", "packs") `
        -Where "config.repoConventions.conventionPacks"
    $schemaVersion = Get-ReviewerConventionStrictInt -Object $RawPolicy -Name "schemaVersion" `
        -Where "config.repoConventions.conventionPacks" -Min 1 -Max 2147483647
    if ($schemaVersion -ne $script:ReviewerConventionPackSchemaVersion) {
        throw "config.repoConventions.conventionPacks.schemaVersion $schemaVersion is unsupported (expected $script:ReviewerConventionPackSchemaVersion)."
    }
    $requireAll = Get-ReviewerConventionStrictBoolean -Object $RawPolicy -Name "requireAllSourcesReferenced" `
        -Where "config.repoConventions.conventionPacks"
    $sources = @($AuthoritativeSourcePolicy.Sources)
    $sourceByName = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $sourceIdentity = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in $sources) {
        $name = [string](Get-ReviewerConventionValue $source "Name")
        if (-not $name -or $name -notmatch '^[a-z][a-z0-9-]{0,63}$') {
            throw "Every convention-pack authoritative source must have an exact lowercase name."
        }
        if ($sourceByName.ContainsKey($name)) { throw "Convention-pack authoritative source name '$name' is duplicated." }
        if (-not $sourceIdentity.Add((Get-ReviewerConventionSourceIdentity -Source $source))) {
            throw "Convention-pack authoritative source '$name' duplicates another canonical repository/branch/path definition."
        }
        $sourceByName.Add($name, $source)
    }

    $rawPacks = Get-ReviewerConventionValue -Object $RawPolicy -Name "packs"
    if ($null -eq $rawPacks -or $rawPacks -is [string] -or $rawPacks -is [System.Management.Automation.PSCustomObject]) {
        throw "config.repoConventions.conventionPacks.packs must be a JSON array."
    }
    $items = @($rawPacks)
    if ($items.Count -lt 1 -or $items.Count -gt $script:ReviewerConventionMaxPacks) {
        throw "config.repoConventions.conventionPacks.packs must contain 1..$script:ReviewerConventionMaxPacks entries."
    }
    $packs = New-Object System.Collections.Generic.List[hashtable]
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $definitions = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $usedSourceNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $where = "config.repoConventions.conventionPacks.packs[$index]"
        Assert-ReviewerConventionExactKeys -Object $item `
            -Allowed @("note", "name", "priority", "changedPathGlobs", "authoritativeSourceRefs", "repositorySources", "maxBytes") `
            -Required @("name", "priority", "changedPathGlobs", "authoritativeSourceRefs", "repositorySources", "maxBytes") `
            -Where $where
        $name = [string](Get-ReviewerConventionValue -Object $item -Name "name")
        if ($name -notmatch '^[a-z][a-z0-9-]{0,63}$') { throw "$where.name must be an exact lowercase pack name." }
        if (-not $names.Add($name)) { throw "$where.name '$name' duplicates an earlier pack." }
        $priority = Get-ReviewerConventionStrictInt -Object $item -Name "priority" -Where $where -Min 0 -Max 10000
        $globs = @(Get-ReviewerConventionStringArray -Object $item -Name "changedPathGlobs" -Where $where `
                -MinCount 1 -MaxCount $script:ReviewerConventionMaxGlobsPerPack)
        $globSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($glob in $globs) {
            if (-not (Test-ReviewerConventionGlob -Glob $glob)) { throw "$where.changedPathGlobs contains unsupported glob '$glob'." }
            if (-not $globSeen.Add($glob)) { throw "$where.changedPathGlobs duplicates '$glob'." }
        }
        $sourceRefs = @(Get-ReviewerConventionStringArray -Object $item -Name "authoritativeSourceRefs" -Where $where `
                -MinCount 0 -MaxCount 16 -MaxLength 64)
        $refSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($sourceRef in $sourceRefs) {
            if ($sourceRef -notmatch '^[a-z][a-z0-9-]{0,63}$') { throw "$where.authoritativeSourceRefs contains invalid source name '$sourceRef'." }
            if (-not $sourceByName.ContainsKey($sourceRef)) { throw "$where.authoritativeSourceRefs names unknown source '$sourceRef'." }
            if (-not $refSeen.Add($sourceRef)) { throw "$where.authoritativeSourceRefs duplicates '$sourceRef'." }
            [void]$usedSourceNames.Add($sourceRef)
        }
        $rawLocal = Get-ReviewerConventionValue -Object $item -Name "repositorySources"
        if ($null -eq $rawLocal -or $rawLocal -is [string] -or $rawLocal -is [System.Management.Automation.PSCustomObject]) {
            throw "$where.repositorySources must be a JSON array."
        }
        $localItems = @($rawLocal)
        if ($localItems.Count -gt $script:ReviewerConventionMaxRepositorySourcesPerPack) {
            throw "$where.repositorySources exceeds $script:ReviewerConventionMaxRepositorySourcesPerPack entries."
        }
        $localSources = New-Object System.Collections.Generic.List[hashtable]
        $localSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($localIndex = 0; $localIndex -lt $localItems.Count; $localIndex++) {
            $local = $localItems[$localIndex]
            $localWhere = "$where.repositorySources[$localIndex]"
            Assert-ReviewerConventionExactKeys -Object $local -Allowed @("path", "maxBytes") `
                -Required @("path", "maxBytes") -Where $localWhere
            $path = [string](Get-ReviewerConventionValue -Object $local -Name "path")
            if (-not (Test-ReviewerConventionRepositorySourcePath -Path $path)) {
                throw "$localWhere.path must be a canonical absolute .md or .txt repository path."
            }
            if (-not $localSeen.Add($path)) { throw "$localWhere.path '$path' duplicates an earlier repository source." }
            $sourceMaxBytes = Get-ReviewerConventionStrictInt -Object $local -Name "maxBytes" -Where $localWhere `
                -Min 1 -Max $script:ReviewerConventionMaxPackBytes
            [void]$localSources.Add(@{ Path = $path; MaxBytes = $sourceMaxBytes })
        }
        if ($sourceRefs.Count + $localSources.Count -eq 0) {
            throw "$where is empty; every pack must reference at least one convention source."
        }
        $maxBytes = Get-ReviewerConventionStrictInt -Object $item -Name "maxBytes" -Where $where `
            -Min 1 -Max $script:ReviewerConventionMaxPackBytes

        $declaredContentBytes = 0
        foreach ($sourceRef in $sourceRefs) { $declaredContentBytes += [int]$sourceByName[$sourceRef].MaxBytes }
        foreach ($local in $localSources) { $declaredContentBytes += [int]$local.MaxBytes }
        $minimalSources = New-Object System.Collections.Generic.List[object]
        foreach ($sourceRef in $sourceRefs) {
            $configuredSource = $sourceByName[$sourceRef]
            [void]$minimalSources.Add([ordered]@{
                    sourceId = $sourceRef; trustTier = "pinned-external"
                    organization = [string]$configuredSource.Organization
                    project = [string]$configuredSource.Project
                    repositoryId = [string]$configuredSource.RepositoryId
                    path = [string]$configuredSource.Path
                    ref = "refs/heads/$($configuredSource.Branch)"
                    commitSha = ("a" * 40); sha256 = ("a" * 64)
                    mimeType = "text/markdown"; byteLength = 1
                })
        }
        foreach ($local in $localSources) {
            [void]$minimalSources.Add([ordered]@{
                    sourceId = "repo:" + ([string]$local.Path).ToLowerInvariant()
                    trustTier = "repo-target"
                    organization = [string]$RepositoryBinding.Organization
                    project = [string]$RepositoryBinding.Project
                    repositoryId = [string]$RepositoryBinding.RepositoryId
                    path = [string]$local.Path
                    ref = [string]$RepositoryBinding.TargetRef
                    commitSha = ("a" * 40); sha256 = ("a" * 64)
                    mimeType = "text/markdown"; byteLength = 1
                })
        }
        $minimalDescriptor = [ordered]@{
            name         = $name
            priority     = $priority
            matchedPaths = @("x")
            matchedGlobs = @($globs[0])
            sources      = $minimalSources.ToArray()
        }
        $minimumProvenanceBytes = $script:ReviewerConventionUtf8.GetByteCount(($minimalDescriptor | ConvertTo-Json -Depth 8 -Compress))
        if ($declaredContentBytes + $minimumProvenanceBytes -gt $maxBytes) {
            throw "$where.maxBytes cannot fit the declared source maxima plus required provenance ($declaredContentBytes + $minimumProvenanceBytes bytes)."
        }
        $definition = (@($globs) -join "`n") + "`0" + (@($sourceRefs) -join "`n") + "`0" +
            (@($localSources | ForEach-Object { "$($_.Path):$($_.MaxBytes)" }) -join "`n") + "`0$maxBytes"
        if (-not $definitions.Add($definition)) { throw "$where ambiguously duplicates an earlier pack definition." }
        [void]$packs.Add(@{
                Name                    = $name
                Priority                = $priority
                ChangedPathGlobs        = @($globs)
                AuthoritativeSourceRefs = @($sourceRefs)
                RepositorySources       = $localSources.ToArray()
                MaxBytes                = $maxBytes
            })
    }
    if ($requireAll) {
        $unused = @($sourceByName.Keys | Where-Object { -not $usedSourceNames.Contains($_) })
        if ($unused.Count -gt 0) { throw "Convention-pack authoritative source(s) have zero use: $($unused -join ', ')." }
    }
    $orderedPackList = New-Object System.Collections.Generic.List[object]
    foreach ($pack in $packs) { [void]$orderedPackList.Add($pack) }
    $packComparison = [System.Comparison[object]] {
        param($left, $right)
        $comparison = ([int]$left.Priority).CompareTo([int]$right.Priority)
        if ($comparison -eq 0) { $comparison = [StringComparer]::Ordinal.Compare([string]$left.Name, [string]$right.Name) }
        return $comparison
    }
    $orderedPackList.Sort($packComparison)
    $orderedPacks = $orderedPackList.ToArray()
    return @{
        SchemaVersion                    = $schemaVersion
        RequireAllSourcesReferenced      = $requireAll
        AuthoritativeSourcePolicy        = $AuthoritativeSourcePolicy
        Packs                            = $orderedPacks
        MaxTotalBytes                    = $script:ReviewerConventionMaxTotalBytes
    }
}

function Select-ReviewerConventionPacks {
    param(
        [Parameter(Mandatory)][hashtable]$Policy,
        [object[]]$ChangeEntries = @()
    )
    $selected = New-Object System.Collections.Generic.List[object]
    $withheld = New-Object System.Collections.Generic.List[object]
    foreach ($pack in @($Policy.Packs)) {
        $matches = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @($ChangeEntries)) {
            $matchedGlobs = @($pack.ChangedPathGlobs | Where-Object {
                    Test-ReviewerConventionGlobMatch -Glob $_ -Path ([string]$entry.Path)
                })
            if ($matchedGlobs.Count -gt 0) {
                [void]$matches.Add([pscustomobject][ordered]@{
                        path        = [string]$entry.Path
                        role        = [string]$entry.Role
                        changeTypes = @($entry.ChangeTypes)
                        globs       = @($matchedGlobs)
                    })
            }
        }
        if ($matches.Count -gt 0) {
            [void]$selected.Add([pscustomobject]@{ Pack = $pack; Matches = $matches.ToArray() })
        }
        else {
            [void]$withheld.Add([pscustomobject][ordered]@{
                    name = $pack.Name
                    reason = "no changed path matched"
                })
        }
    }
    return @{
        Selected = $selected.ToArray()
        Withheld = $withheld.ToArray()
    }
}

function Get-ReviewerConventionSourceRequests {
    param([Parameter(Mandatory)][hashtable]$Selection)
    $sourceNames = New-Object System.Collections.Generic.List[string]
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $repositorySources = New-Object System.Collections.Generic.List[object]
    $seenPaths = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($selectionItem in @($Selection.Selected)) {
        foreach ($sourceRef in @($selectionItem.Pack.AuthoritativeSourceRefs)) {
            if ($seenNames.Add([string]$sourceRef)) { [void]$sourceNames.Add([string]$sourceRef) }
        }
        foreach ($source in @($selectionItem.Pack.RepositorySources)) {
            $path = [string]$source.Path
            $maxBytes = [int]$source.MaxBytes
            if ($seenPaths.ContainsKey($path)) {
                if ($seenPaths[$path] -ne $maxBytes) {
                    throw "Repository source '$path' has conflicting maxBytes across selected packs."
                }
                continue
            }
            $seenPaths.Add($path, $maxBytes)
            [void]$repositorySources.Add($source)
        }
    }
    return @{
        AuthoritativeSourceNames = $sourceNames.ToArray()
        RepositorySources       = $repositorySources.ToArray()
    }
}

function New-ReviewerConventionContextPlan {
    param(
        [Parameter(Mandatory)][hashtable]$Policy,
        [Parameter(Mandatory)][hashtable]$Selection,
        [Parameter(Mandatory)][hashtable]$Binding,
        [object[]]$AuthoritativeSnapshots = @(),
        [object[]]$RepositorySnapshots = @(),
        [Parameter(Mandatory)][string]$ScriptSha256,
        [Parameter(Mandatory)][string]$ConfigSha256
    )
    $snapshots = @(@($AuthoritativeSnapshots) + @($RepositorySnapshots))
    $snapshotById = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($snapshot in $snapshots) {
        $sourceId = [string](Get-ReviewerConventionValue $snapshot "SourceId")
        if (-not $sourceId -or $snapshotById.ContainsKey($sourceId)) {
            throw "Resolved convention source ids must be non-empty and unique."
        }
        $snapshotById.Add($sourceId, $snapshot)
    }
    $selectedPlans = New-Object System.Collections.Generic.List[object]
    $totalBytes = 0
    foreach ($selectionItem in @($Selection.Selected)) {
        $pack = $selectionItem.Pack
        $sourceIds = New-Object System.Collections.Generic.List[string]
        foreach ($sourceRef in @($pack.AuthoritativeSourceRefs)) { [void]$sourceIds.Add([string]$sourceRef) }
        foreach ($local in @($pack.RepositorySources)) {
            [void]$sourceIds.Add("repo:" + ([string]$local.Path).ToLowerInvariant())
        }
        $resolved = New-Object System.Collections.Generic.List[object]
        foreach ($sourceId in $sourceIds) {
            if (-not $snapshotById.ContainsKey($sourceId)) {
                throw "Selected pack '$($pack.Name)' did not resolve source '$sourceId'."
            }
            $snapshot = $snapshotById[$sourceId]
            [void]$resolved.Add([pscustomobject][ordered]@{
                    sourceId      = $sourceId
                    trustTier     = [string](Get-ReviewerConventionValue $snapshot "TrustTier")
                    organization  = [string](Get-ReviewerConventionValue $snapshot "Organization")
                    project       = [string](Get-ReviewerConventionValue $snapshot "Project")
                    repositoryId  = [string](Get-ReviewerConventionValue $snapshot "RepositoryId")
                    path          = [string](Get-ReviewerConventionValue $snapshot "Path")
                    ref           = [string](Get-ReviewerConventionValue $snapshot "Ref")
                    commitSha     = [string](Get-ReviewerConventionValue $snapshot "CommitSha")
                    sha256        = [string](Get-ReviewerConventionValue $snapshot "Sha256")
                    mimeType      = [string](Get-ReviewerConventionValue $snapshot "MimeType")
                    byteLength    = [int](Get-ReviewerConventionValue $snapshot "ByteLength")
                })
        }
        $matchedPaths = @($selectionItem.Matches | ForEach-Object {
                [pscustomobject][ordered]@{
                    path = $_.path; role = $_.role; changeTypes = @($_.changeTypes); globs = @($_.globs)
                }
            })
        $descriptor = [ordered]@{
            name         = $pack.Name
            priority     = [int]$pack.Priority
            matchedPaths = $matchedPaths
            sources      = $resolved.ToArray()
        }
        $descriptorJson = $descriptor | ConvertTo-Json -Depth 10 -Compress
        $provenanceBytes = $script:ReviewerConventionUtf8.GetByteCount($descriptorJson)
        $contentBytes = [int](($resolved | Measure-Object -Property byteLength -Sum).Sum)
        $packBytes = $provenanceBytes + $contentBytes
        if ($packBytes -gt [int]$pack.MaxBytes) {
            throw "Selected pack '$($pack.Name)' requires $packBytes bytes, above its $($pack.MaxBytes)-byte cap; no source was truncated."
        }
        $totalBytes += $packBytes
        if ($totalBytes -gt [int]$Policy.MaxTotalBytes) {
            throw "Selected convention packs require $totalBytes bytes, above the code-defined $($Policy.MaxTotalBytes)-byte total cap; no source was truncated."
        }
        [void]$selectedPlans.Add([pscustomobject][ordered]@{
                name            = $pack.Name
                priority        = [int]$pack.Priority
                matchedPaths    = $matchedPaths
                sources         = $resolved.ToArray()
                contentBytes    = $contentBytes
                provenanceBytes = $provenanceBytes
                contextBytes    = $packBytes
                maxBytes        = [int]$pack.MaxBytes
                status          = "selected"
                reason          = ""
            })
    }
    return [pscustomobject][ordered]@{
        planVersion       = $script:ReviewerConventionPlanVersion
        schemaVersion     = [int]$Policy.SchemaVersion
        status            = "ready"
        failureReason     = ""
        environmentFault  = $false
        scriptSha256      = $ScriptSha256.ToLowerInvariant()
        configSha256      = $ConfigSha256.ToLowerInvariant()
        organization      = [string]$Binding.Organization
        project           = [string]$Binding.Project
        repositoryId      = [string]$Binding.RepositoryId
        pullRequestId     = [int]$Binding.PullRequestId
        sourceCommit      = [string]$Binding.SourceCommit
        targetCommit      = [string]$Binding.TargetCommit
        changeSetDigest   = [string]$Binding.ChangeSetDigest
        selectedPacks     = $selectedPlans.ToArray()
        withheldPacks     = @($Selection.Withheld)
        totalContextBytes = $totalBytes
        maxTotalBytes     = [int]$Policy.MaxTotalBytes
    }
}
