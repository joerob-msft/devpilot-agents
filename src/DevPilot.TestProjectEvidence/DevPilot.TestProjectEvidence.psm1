# This module never executes MSBuild or reads the local filesystem. Its input inventory
# and blob reader must already have been pinned to and verified against SourceCommit.
# The supported graph is explicit Compile/PropertyGroup/Import XML without an SDK,
# or the uncustomized Microsoft.NET.Sdk default C# glob with a literal IsTestProject.
# Non-C# projects and unaccounted .props/.targets/.projitems cannot be ruled out.
function Assert-Evidence {
    param([bool]$Valid)
    if (-not $Valid) { throw 'project-identity-unknown' }
}

function Get-Field {
    param([object]$Value, [string]$Name)
    Assert-Evidence ($Value -is [System.Collections.IDictionary] -and $Value.Contains($Name))
    return $Value[$Name]
}

function Assert-InventoryPath {
    param([string]$Value, [bool]$AllowRoot = $false)
    Assert-Evidence ($null -ne $Value -and $Value.Length -le 2048 -and
        $Value.StartsWith('/') -and
        ($AllowRoot -or $Value -ne '/') -and $Value -notmatch '[\\\x00-\x1f:*?"<>|]' -and
        $Value -notmatch '//' -and ($Value -eq '/' -or
            ($Value -notmatch '/$' -and $Value -notmatch '(^|/)\.{1,2}(/|$)')))
}

function Resolve-ProjectPath {
    param([string]$Value, [string]$BaseDirectory)
    Assert-Evidence (-not [string]::IsNullOrWhiteSpace($Value) -and
        $Value.Length -le 2048 -and $Value -notmatch '^//' -and
        $Value -notmatch '[\x00-\x1f:%@]' -and $Value -notmatch '^[a-zA-Z]+:' -and
        $Value -notmatch '^\\\\')
    $value = $Value.Replace('\', '/')
    if (-not $value.StartsWith('/')) { $value = "$BaseDirectory/$value" }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $value.Split('/')) {
        if ($part -eq '' -or $part -eq '.') { continue }
        if ($part -eq '..') {
            Assert-Evidence ($parts.Count -gt 0)
            $parts.RemoveAt($parts.Count - 1)
        } else {
            Assert-Evidence ($part -notmatch '[:"<>|]')
            $parts.Add($part)
        }
    }
    return '/' + ($parts -join '/')
}

function Expand-ProjectValue {
    param([string]$Value, [hashtable]$Properties)
    Assert-Evidence ($Value -notmatch '[@%]\(' -and $Value -notmatch '\$\[')
    $expanded = $Value
    for ($n = 0; $n -lt 32; $n++) {
        $match = [regex]::Match($expanded, '\$\(([^()]*)\)')
        if (-not $match.Success) {
            Assert-Evidence ($expanded -notmatch '\$\(')
            return $expanded
        }
        Assert-Evidence ($Properties.ContainsKey($match.Groups[1].Value))
        $expanded = $expanded.Substring(0, $match.Index) +
            [string]$Properties[$match.Groups[1].Value] +
            $expanded.Substring($match.Index + $match.Length)
        Assert-Evidence ($expanded.Length -le 65536)
    }
    throw 'project-identity-unknown'
}

function Test-ProjectCondition {
    param([string]$Condition, [hashtable]$Properties)
    if ([string]::IsNullOrWhiteSpace($Condition)) { return $true }
    $condition = Expand-ProjectValue $Condition $Properties
    if ($condition -match '^\s*''([^'']*)''\s*(==|!=)\s*''([^'']*)''\s*$') {
        $equal = $Matches[1] -ieq $Matches[3]
        if ($Matches[2] -eq '==') { return $equal }
        return -not $equal
    }
    if ($condition -match '^\s*(true|false)\s*$') { return $Matches[1] -ieq 'true' }
    throw 'project-identity-unknown'
}

function Assert-Attributes {
    param([System.Xml.XmlElement]$Element, [string[]]$Allowed)
    Assert-Evidence ($Element.NamespaceURI -eq '')
    foreach ($attribute in $Element.Attributes) {
        Assert-Evidence ($attribute.NamespaceURI -eq '' -and $attribute.Name -cin $Allowed)
    }
}

function Get-AttributeValue {
    param([System.Xml.XmlElement]$Element, [string]$Name)
    if ($Element.HasAttribute($Name)) { return $Element.GetAttribute($Name) }
    return $null
}

function Get-ProjectChildren {
    param([System.Xml.XmlNode]$Element)
    foreach ($node in $Element.ChildNodes) {
        if ($node -is [System.Xml.XmlElement]) { $node; continue }
        Assert-Evidence ($node -is [System.Xml.XmlComment] -or
            (($node -is [System.Xml.XmlCharacterData]) -and
                [string]::IsNullOrWhiteSpace($node.Value)))
    }
}

function Assert-TextOnly {
    param([System.Xml.XmlElement]$Element)
    foreach ($node in $Element.ChildNodes) {
        Assert-Evidence ($node -is [System.Xml.XmlText] -or
            $node -is [System.Xml.XmlWhitespace] -or
            $node -is [System.Xml.XmlSignificantWhitespace])
    }
}

function Get-BlobText {
    param([string]$Path, [hashtable]$State)
    $entry = $State.Inventory[$Path]
    Assert-Evidence ($null -ne $entry -and $entry.gitObjectType -ceq 'blob' -and
        $entry.path -ceq $Path)
    if ($State.Text.ContainsKey($Path)) { return $State.Text[$Path] }
    $content = & $State.ReadItem $entry.path $entry.objectId
    Assert-Evidence ($content -is [string] -and $content.Length -le 1048576)
    $State.ReadCharacters += $content.Length
    Assert-Evidence ($State.ReadCharacters -le 8388608)
    $State.Text[$Path] = $content
    return $content
}

function Get-ItemPatternMatches {
    param([string]$Pattern, [string]$Directory, [hashtable]$State)
    $State.PatternCount++
    Assert-Evidence ($State.PatternCount -le 256 -and
        $Pattern -notmatch '^[\s]*$' -and $Pattern -notmatch '[\{\}\[\]]')
    $resolved = Resolve-ProjectPath $Pattern $Directory
    if ($resolved -notmatch '[*?]') {
        $entry = $State.Inventory[$resolved]
        Assert-Evidence ($null -ne $entry -and $entry.gitObjectType -ceq 'blob' -and
            $entry.path -ceq $resolved)
        return ,@($entry.path)
    }
    $wildcard = $resolved.IndexOfAny([char[]]@('*', '?'))
    $fixedDirectory = $resolved.Substring(0,
        $resolved.LastIndexOf('/', $wildcard) + 1)
    foreach ($link in $State.Gitlinks) {
        Assert-Evidence (-not $link.StartsWith($fixedDirectory,
                [StringComparison]::OrdinalIgnoreCase) -and
            -not $fixedDirectory.StartsWith("$link/",
                [StringComparison]::OrdinalIgnoreCase))
    }
    $segments = $resolved.Substring(1).Split('/')
    Assert-Evidence ($segments.Count -le 64)
    $regexParts = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $segments.Length; $index++) {
        $segment = $segments[$index]
        if ($segment -eq '**') {
            if ($index -eq $segments.Length - 1) { $regexParts.Add('.*') }
            else { $regexParts.Add('(?:[^/]+/)*') }
        } else {
            Assert-Evidence ($segment -notmatch '\*\*')
            $regexParts.Add(([regex]::Escape($segment)).Replace('\*', '[^/]*').Replace('\?', '[^/]'))
            $regexParts.Add('/')
        }
    }
    $regex = '^/' + ($regexParts -join '')
    if ($regex.EndsWith('/')) { $regex = $regex.Substring(0, $regex.Length - 1) }
    $regex += '$'
    $result = [System.Collections.Generic.List[string]]::new()
    $State.Comparisons += $State.SourceFiles.Count
    Assert-Evidence ($State.Comparisons -le 2000000)
    $matcher = [regex]::new($regex,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant,
        [TimeSpan]::FromMilliseconds(50))
    $caseInsensitiveMatcher = [regex]::new($regex,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase,
        [TimeSpan]::FromMilliseconds(50))
    foreach ($candidate in $State.SourceFiles) {
        if ($caseInsensitiveMatcher.IsMatch($candidate)) {
            Assert-Evidence ($matcher.IsMatch($candidate))
            $result.Add($candidate)
        }
    }
    return ,$result.ToArray()
}

function Get-CompileMatches {
    param([string]$Value, [string]$Directory, [hashtable]$State, [hashtable]$Properties)
    $result = [System.Collections.Generic.List[string]]::new()
    $expanded = Expand-ProjectValue $Value $Properties
    foreach ($pattern in $expanded.Split(';')) {
        Assert-Evidence (-not [string]::IsNullOrWhiteSpace($pattern))
        foreach ($match in (Get-ItemPatternMatches $pattern $Directory $State)) {
            $result.Add($match)
        }
    }
    return ,$result.ToArray()
}

function Invoke-ProjectFile {
    param([string]$Path, [hashtable]$State, [hashtable]$Properties,
        [System.Collections.Generic.HashSet[string]]$Compiled,
        [System.Collections.Generic.HashSet[string]]$ImportStack,
        [hashtable]$SdkState, [bool]$IsRootProject = $false)
    Assert-Evidence ($ImportStack.Add($Path))
    try {
        Assert-Evidence ($Path -notmatch '(?i)(^|/)Directory\.Build\.(props|targets)$')
        $text = Get-BlobText $Path $State
        Assert-Evidence ($text -notmatch '<!(?:DOCTYPE|ENTITY)' -and $text -notmatch '<\?')
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 1048576
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($text), $settings)
        try {
            $document = [System.Xml.XmlDocument]::new()
            $document.XmlResolver = $null
            $document.Load($reader)
        } finally { $reader.Dispose() }
        $root = $document.DocumentElement
        Assert-Evidence ($null -ne $root -and $root.LocalName -ceq 'Project')
        if ($root.HasAttribute('Sdk')) {
            Assert-Evidence ($IsRootProject -and
                $root.GetAttribute('Sdk') -ceq 'Microsoft.NET.Sdk')
            Assert-Attributes $root @('Sdk')
            $SdkState.Enabled = $true
        } else {
            Assert-Attributes $root @()
        }
        $directory = $Path.Substring(0, $Path.LastIndexOf('/'))
        if ($directory -eq '') { $directory = '/' }
        $previousDirectory = $Properties['MSBuildThisFileDirectory']
        $previousFullPath = $Properties['MSBuildThisFileFullPath']
        $Properties['MSBuildThisFileDirectory'] = $directory.TrimEnd('/') + '/'
        $Properties['MSBuildThisFileFullPath'] = $Path
        try {
            foreach ($child in (Get-ProjectChildren $root)) {
                if ($SdkState.Enabled) {
                    # Model only the standard SDK implicit C# glob, never a customized SDK item graph.
                    Assert-Evidence ($child.LocalName -ceq 'PropertyGroup')
                    Assert-Attributes $child @()
                    foreach ($property in (Get-ProjectChildren $child)) {
                        Assert-Evidence ($property.LocalName -ceq 'IsTestProject')
                        Assert-Attributes $property @()
                        Assert-TextOnly $property
                        Assert-Evidence ($property.InnerText -match '^(?i:true|false)$')
                        $Properties['IsTestProject'] = $property.InnerText
                    }
                    continue
                }
                switch -CaseSensitive ($child.LocalName) {
                    PropertyGroup {
                        Assert-Attributes $child @('Condition')
                        if (-not (Test-ProjectCondition (Get-AttributeValue $child 'Condition') $Properties)) { break }
                        foreach ($property in (Get-ProjectChildren $child)) {
                            Assert-Attributes $property @('Condition')
                            Assert-Evidence ($property.LocalName -match '^[A-Za-z_][A-Za-z0-9_]*$' -and
                                $property.LocalName -notmatch '^MSBuild')
                            Assert-TextOnly $property
                            if (Test-ProjectCondition (Get-AttributeValue $property 'Condition') $Properties) {
                                $Properties[$property.LocalName] = Expand-ProjectValue $property.InnerText $Properties
                            }
                        }
                    }
                    ItemGroup {
                        Assert-Attributes $child @('Condition')
                        if (-not (Test-ProjectCondition (Get-AttributeValue $child 'Condition') $Properties)) { break }
                        foreach ($item in (Get-ProjectChildren $child)) {
                            Assert-Evidence ($item.LocalName -ceq 'Compile')
                            Assert-Attributes $item @('Include', 'Exclude', 'Remove', 'Condition', 'Link')
                            if (-not (Test-ProjectCondition (Get-AttributeValue $item 'Condition') $Properties)) { continue }
                            $include = Get-AttributeValue $item 'Include'
                            $exclude = Get-AttributeValue $item 'Exclude'
                            $remove = Get-AttributeValue $item 'Remove'
                            Assert-Evidence ((($null -ne $include) -xor ($null -ne $remove)) -and
                                ($null -eq $exclude -or $null -ne $include) -and
                                ($null -eq (Get-AttributeValue $item 'Link') -or $null -ne $include))
                            Assert-Evidence (-not ($item.HasAttribute('Link') -and
                                    @($item.ChildNodes | Where-Object {
                                            $_ -is [System.Xml.XmlElement] -and $_.LocalName -ceq 'Link'
                                        }).Count -gt 0))
                            if ($item.HasAttribute('Link')) {
                                $null = Expand-ProjectValue (Get-AttributeValue $item 'Link') $Properties
                            }
                            foreach ($metadata in (Get-ProjectChildren $item)) {
                                Assert-Evidence ($metadata.LocalName -ceq 'Link')
                                Assert-Attributes $metadata @()
                                Assert-TextOnly $metadata
                                $null = Expand-ProjectValue $metadata.InnerText $Properties
                            }
                            if ($null -ne $include) {
                                $excluded = [System.Collections.Generic.HashSet[string]]::new(
                                    [StringComparer]::OrdinalIgnoreCase)
                                if ($null -ne $exclude) {
                                    foreach ($found in (Get-CompileMatches $exclude $directory $State $Properties)) {
                                        $null = $excluded.Add($found)
                                    }
                                }
                                foreach ($found in (Get-CompileMatches $include $directory $State $Properties)) {
                                    if (-not $excluded.Contains($found)) { $null = $Compiled.Add($found) }
                                }
                            } else {
                                foreach ($found in (Get-CompileMatches $remove $directory $State $Properties)) {
                                    $null = $Compiled.Remove($found)
                                }
                            }
                        }
                    }
                    Import {
                        Assert-Attributes $child @('Project', 'Condition')
                        Assert-Evidence (@(Get-ProjectChildren $child).Count -eq 0)
                        if (-not (Test-ProjectCondition (Get-AttributeValue $child 'Condition') $Properties)) { break }
                        $import = Expand-ProjectValue (Get-AttributeValue $child 'Project') $Properties
                        Assert-Evidence ($import -notmatch '[*?;]' -and $import -notmatch '^\s*$')
                        $importPath = Resolve-ProjectPath $import $directory
                        Invoke-ProjectFile $importPath $State $Properties $Compiled $ImportStack $SdkState
                    }
                    default { throw 'project-identity-unknown' }
                }
            }
        } finally {
            $Properties['MSBuildThisFileDirectory'] = $previousDirectory
            $Properties['MSBuildThisFileFullPath'] = $previousFullPath
        }
    } finally { $null = $ImportStack.Remove($Path) }
}

function Get-TestProjectGraphEvidence {
    param(
        [string]$RepositoryId,
        [string]$SourceCommit,
        [string]$Path,
        [string]$ObjectId,
        [object[]]$Entries,
        [scriptblock]$ReadItem,
        [int]$MaxProjects = 128,
        [int]$MaxFiles = 10000
    )
    try {
        Assert-Evidence ($RepositoryId -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -and
            $SourceCommit -match '^[0-9a-fA-F]{40}$' -and
            $ObjectId -match '^[0-9a-fA-F]{40}$' -and $null -ne $ReadItem -and
            $MaxProjects -gt 0 -and $MaxProjects -le 512 -and
            $MaxFiles -gt 0 -and $MaxFiles -le 100000 -and
            $null -ne $Entries -and $Entries.Count -le $MaxFiles)
        Assert-InventoryPath $Path
        Assert-Evidence ($Path -match '(?i)\.cs$')
        $inventory = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
        $projects = [System.Collections.Generic.List[string]]::new()
        $sourceFiles = [System.Collections.Generic.List[string]]::new()
        $auxiliaryFiles = [System.Collections.Generic.List[string]]::new()
        $gitlinks = [System.Collections.Generic.List[string]]::new()
        $pathCharacters = 0
        foreach ($entry in $Entries) {
            $entryPath = Get-Field $entry 'path'
            $entryObjectId = Get-Field $entry 'objectId'
            $type = Get-Field $entry 'gitObjectType'
            Assert-Evidence ($entryPath -is [string] -and $entryObjectId -is [string] -and
                $entryObjectId -match '^[0-9a-fA-F]{40}$' -and
                $type -cin @('blob', 'tree', 'commit'))
            Assert-InventoryPath $entryPath ($type -ceq 'tree')
            if ($type -ceq 'commit') {
                Assert-Evidence ($entry.mode -ceq '160000' -and
                    $entryPath -notmatch '(?i)\.(?:cs|csproj|props|targets|projitems)$')
                $gitlinks.Add($entryPath)
            }
            $pathCharacters += $entryPath.Length
            Assert-Evidence ($pathCharacters -le 4194304)
            Assert-Evidence (-not $inventory.ContainsKey($entryPath))
            $inventory[$entryPath] = @{ path = $entryPath; objectId = $entryObjectId
                gitObjectType = $type }
            if ($type -ceq 'blob') {
                if ($entryPath -match '(?i)\.(?:[a-z0-9]*proj)$') {
                    Assert-Evidence ($entryPath -match '(?i)\.csproj$')
                    $projects.Add($entryPath)
                }
                if ($entryPath -match '(?i)\.(?:props|targets|projitems)$') {
                    $auxiliaryFiles.Add($entryPath)
                }
                if ($entryPath -match '(?i)\.cs$') { $sourceFiles.Add($entryPath) }
            }
        }
        Assert-Evidence ($projects.Count -gt 0 -and $projects.Count -le $MaxProjects -and
            $inventory.ContainsKey($Path) -and $inventory[$Path].gitObjectType -ceq 'blob' -and
            $inventory[$Path].objectId -ieq $ObjectId -and
            $inventory[$Path].path -ceq $Path)
        $state = @{ Inventory = $inventory; SourceFiles = $sourceFiles.ToArray()
            Gitlinks = $gitlinks.ToArray()
            ReadItem = $ReadItem; Text = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
            ReadCharacters = 0; PatternCount = 0; Comparisons = 0 }
        $owners = [System.Collections.Generic.List[object]]::new()
        $hasSdkProject = $false
        foreach ($project in $projects) {
            $directory = $project.Substring(0, $project.LastIndexOf('/'))
            if ($directory -eq '') { $directory = '/' }
            $ancestor = $directory
            while ($true) {
                foreach ($name in @('Directory.Build.props', 'Directory.Build.targets')) {
                    if ($inventory.ContainsKey(($ancestor.TrimEnd('/') + '/' + $name))) {
                        throw 'project-identity-unknown'
                    }
                }
                if ($ancestor -eq '/') { break }
                $ancestor = $ancestor.Substring(0, $ancestor.LastIndexOf('/'))
                if ($ancestor -eq '') { $ancestor = '/' }
            }
            $properties = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
            $properties['MSBuildProjectDirectory'] = $directory
            $properties['MSBuildProjectFullPath'] = $project
            $properties['MSBuildProjectName'] = [System.IO.Path]::GetFileNameWithoutExtension($project)
            $compiled = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $stack = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $sdkState = @{ Enabled = $false }
            Invoke-ProjectFile $project $state $properties $compiled $stack $sdkState $true
            if ($sdkState.Enabled) {
                $hasSdkProject = $true
                Assert-Evidence ($properties.ContainsKey('IsTestProject'))
                $prefix = $directory.TrimEnd('/') + '/'
                foreach ($link in $gitlinks) {
                    Assert-Evidence (-not $link.StartsWith($prefix,
                            [StringComparison]::OrdinalIgnoreCase))
                }
                if ($Path.StartsWith($prefix, [StringComparison]::Ordinal)) {
                    $relative = $Path.Substring($prefix.Length)
                    Assert-Evidence ($relative -notmatch '(?i)(^|/)(?:bin|obj|\.[^/]+)(/|$)')
                    $null = $compiled.Add($Path)
                }
            }
            if ($compiled.Contains($Path)) {
                $isTest = $false
                if ($properties.ContainsKey('IsTestProject')) {
                    Assert-Evidence ($properties['IsTestProject'] -match '^(?i:true|false)$')
                    $isTest = $properties['IsTestProject'] -ieq 'true'
                }
                $owners.Add(@{ path = $project; objectId = $inventory[$project].objectId
                    compileIncluded = $true; isTestProject = [bool]$isTest })
            }
        }
        Assert-Evidence (-not ($hasSdkProject -and $auxiliaryFiles.Count -gt 0))
        foreach ($auxiliary in $auxiliaryFiles) {
            Assert-Evidence ($state.Text.ContainsKey($auxiliary))
        }
        Assert-Evidence ($owners.Count -gt 0)
        $sorted = @($owners | Sort-Object { $_.path })
        return @{
            schemaVersion = 1
            kind = 'source-bound-evaluated-project-graph-v1'
            complete = $true
            repositoryId = $RepositoryId
            sourceCommit = $SourceCommit
            path = $inventory[$Path].path
            objectId = $inventory[$Path].objectId
            projects = $sorted
        }
    } catch {
        throw 'project-identity-unknown'
    }
}

Export-ModuleMember -Function Get-TestProjectGraphEvidence
