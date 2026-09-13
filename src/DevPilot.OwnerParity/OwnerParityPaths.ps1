if ($IsWindows -and -not ('DevPilot.OwnerParity.NativePaths' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace DevPilot.OwnerParity
{
    [StructLayout(LayoutKind.Sequential)]
    public struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    public static class NativePaths
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint QueryDosDevice(
            string deviceName,
            StringBuilder targetPath,
            int maximumCharacterCount);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetLongPathName(
            string shortPath,
            StringBuilder longPath,
            int bufferLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle fileHandle,
            out ByHandleFileInformation fileInformation);
    }
}
'@
}

function Assert-OwnerParitySecureNoLinks {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and (
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $null -ne $item.LinkType)) {
            throw "Owner parity path '$Path' traverses a link or reparse point."
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-OwnerParitySecureNoSubstitutedDrive {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { return }
    $root = [IO.Path]::GetPathRoot($Path)
    if ($root -cnotmatch '^[A-Za-z]:\\$') { return }
    $target = [Text.StringBuilder]::new(32768)
    $length = [DevPilot.OwnerParity.NativePaths]::QueryDosDevice(
        $root.Substring(0, 2), $target, $target.Capacity)
    if ($length -eq 0) {
        throw "Owner parity path drive '$root' could not be resolved to a native device."
    }
    $nativeTarget = $target.ToString().Split([char]0, 2)[0]
    if ($nativeTarget.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Owner parity paths must not use a substituted drive.'
    }
}

function ConvertTo-OwnerParitySecureCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { return [IO.Path]::GetFullPath($Path) }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $suffix = [Collections.Generic.List[string]]::new()
    $existing = $fullPath
    $canonical = $null
    while ($null -eq $canonical) {
        if (Test-Path -LiteralPath $existing) {
            $longPath = [Text.StringBuilder]::new(32768)
            $length = [DevPilot.OwnerParity.NativePaths]::GetLongPathName(
                $existing, $longPath, $longPath.Capacity)
            if ($length -gt 0 -and $length -lt $longPath.Capacity) {
                $canonical = $longPath.ToString()
                break
            }
        }
        $leaf = Split-Path -Leaf $existing
        if ([string]::IsNullOrEmpty($leaf)) {
            throw "Owner parity path '$Path' has no resolvable canonical ancestor."
        }
        $suffix.Insert(0, $leaf)
        $parent = Split-Path -Parent $existing
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $existing) {
            throw "Owner parity path '$Path' has no resolvable canonical ancestor."
        }
        $existing = $parent
    }
    foreach ($leaf in $suffix) { $canonical = Join-Path $canonical $leaf }
    return [IO.Path]::GetFullPath($canonical)
}

function Resolve-OwnerParitySecurePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Any', 'File', 'Directory')][string]$Kind = 'Any',
        [switch]$AllowMissing
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Name must be a non-empty absolute path."
    }
    if ($IsWindows -and $Path -match '^(\\\\[?.]\\|\\\?\?\\)') {
        throw "$Name must not use a Windows device-path alias."
    }
    if ($IsWindows -and $Path -match '^[\\/]{2}') {
        throw "$Name must not use a Windows UNC path."
    }
    $provider = $null
    $drive = $null
    try {
        $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $Path, [ref]$provider, [ref]$drive)
    }
    catch {
        throw "$Name could not be resolved as a filesystem path."
    }
    if ($null -eq $provider -or $provider.Name -cne 'FileSystem') {
        throw "$Name must use the FileSystem provider."
    }
    if ($IsWindows -and $providerPath -match '^[\\/]{2}') {
        throw "$Name must not resolve to a Windows UNC path."
    }
    $full = ConvertTo-OwnerParitySecureCanonicalPath -Path $providerPath
    Assert-OwnerParitySecureNoSubstitutedDrive -Path $full
    Assert-OwnerParitySecureNoLinks -Path $full
    if (-not $AllowMissing) {
        $pathType = if ($Kind -eq 'File') {
            'Leaf'
        }
        elseif ($Kind -eq 'Directory') {
            'Container'
        }
        else {
            'Any'
        }
        if (-not (Test-Path -LiteralPath $full -PathType $pathType)) {
            throw "$Name does not exist."
        }
    }
    return $full
}

function Test-OwnerParitySecurePathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function ConvertTo-OwnerParityRelativePath {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Name
        )
        if ([string]::IsNullOrWhiteSpace($Path) -or $Path -cne $Path.Trim() -or
            [IO.Path]::IsPathFullyQualified($Path) -or $Path -match '^[\\/]' -or
            $Path -match '^[A-Za-z]:' -or $Path -match '[\x00-\x1f\x7f]') {
            throw "$Name must be a safe relative filesystem path."
        }
        $normalized = $Path.Replace('/', [IO.Path]::DirectorySeparatorChar).
            Replace('\', [IO.Path]::DirectorySeparatorChar)
        $segments = @($normalized.Split([IO.Path]::DirectorySeparatorChar))
        if ($segments.Count -eq 0 -or
            @($segments | Where-Object { -not $_ -or $_ -in @('.', '..') }).Count -gt 0) {
            throw "$Name contains ambiguous or traversing path segments."
        }
        return $segments -join [IO.Path]::DirectorySeparatorChar
    }

    function Get-OwnerParityFileIdentity {
        param([Parameter(Mandatory)][IO.FileStream]$Stream)
        if (-not $IsWindows) { return 'unavailable' }
        $information = [DevPilot.OwnerParity.ByHandleFileInformation]::new()
        if (-not [DevPilot.OwnerParity.NativePaths]::GetFileInformationByHandle(
                $Stream.SafeFileHandle, [ref]$information)) {
            throw 'Owner parity could not read the file identity.'
        }
        return ('{0:x8}:{1:x8}{2:x8}' -f
            $information.VolumeSerialNumber,
            $information.FileIndexHigh,
            $information.FileIndexLow)
    }

    function Read-OwnerParityExactFile {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][object]$Reference,
            [AllowEmptyString()][string]$ExpectedBinding = '',
            [switch]$AllowGrowth
        )
        $relative = ConvertTo-OwnerParityRelativePath `
            -Path ([string]$Reference.relativePath) -Name reference.relativePath
        if ($ExpectedBinding -and [string]$Reference.binding -cne $ExpectedBinding) {
            throw "Exact byte reference '$($Reference.id)' has the wrong immutable binding."
        }
        $resolvedRoot = Resolve-OwnerParitySecurePath -Path $Root -Name referenceRoot -Kind Directory
        $path = Resolve-OwnerParitySecurePath `
            -Path (Join-Path $resolvedRoot $relative) -Name referencedFile -Kind File
        if (-not (Test-OwnerParitySecurePathWithin -Path $path -Root $resolvedRoot)) {
            throw "Referenced file '$relative' escaped its declared root."
        }
        $share = if ($AllowGrowth) {
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        }
        else {
            [IO.FileShare]::Read
        }
        $stream = [IO.FileStream]::new(
            $path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            $share,
            65536,
            [IO.FileOptions]::SequentialScan)
        try {
            $identity = Get-OwnerParityFileIdentity -Stream $stream
            $lengthBefore = $stream.Length
            if ($lengthBefore -gt 64MB) {
                throw "Referenced file '$relative' exceeds the 64 MiB limit."
            }
            $bytes = [byte[]]::new([int]$lengthBefore)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($read -eq 0) { throw "Referenced file '$relative' was truncated during read." }
                $offset += $read
            }
            if ($stream.Length -ne $lengthBefore) {
                throw "Referenced file '$relative' changed length during read."
            }
        }
        finally {
            $stream.Dispose()
        }
        Assert-OwnerParitySecureNoLinks -Path $path
        $postPath = Resolve-OwnerParitySecurePath -Path $path -Name referencedFile -Kind File
        if ($postPath -cne $path) {
            throw "Referenced file '$relative' was substituted during read."
        }
        $sha256 = ([Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
        return [pscustomobject][ordered]@{
            id = [string]$Reference.id
            relativePath = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
            path = $path
            length = [long]$bytes.Length
            sha256 = $sha256
            identity = $identity
            bytes = $bytes
        }
    }

    function Read-OwnerParityReferenceSet {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$References,
            [switch]$SkipExpected
        )
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $paths = [Collections.Generic.HashSet[string]]::new(
            $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
        $values = [Collections.Generic.List[object]]::new()
        foreach ($reference in $References) {
            $id = [string]$reference.id
            if (-not $ids.Add($id)) { throw "Exact byte reference id '$id' is duplicated." }
            $expectedBinding = 'critical:' + (
                (ConvertTo-OwnerParityRelativePath `
                    -Path ([string]$reference.relativePath) -Name reference.relativePath).
                    Replace([IO.Path]::DirectorySeparatorChar, '/'))
            $value = Read-OwnerParityExactFile `
                -Root $Root -Reference $reference -ExpectedBinding $expectedBinding
            if (-not $paths.Add([string]$value.relativePath)) {
                throw "Exact byte reference path '$($value.relativePath)' is duplicated or case-colliding."
            }
            if (-not $SkipExpected) {
                if ([long]$reference.length -ne [long]$value.length) {
                    throw "Exact byte reference '$id' has the wrong length."
                }
                if ([string]$reference.sha256 -cne [string]$value.sha256) {
                    throw "Exact byte reference '$id' has the wrong SHA-256."
                }
            }
            if ([string]::IsNullOrWhiteSpace([string]$reference.binding)) {
                throw "Exact byte reference '$id' has no immutable binding."
            }
            [void]$values.Add($value)
        }
        return @($values)
    }

    function Get-OwnerParityAttestationSnapshot {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][object]$Attestation,
            [switch]$ValidateVolatileBaseline
        )
        $resolvedRoot = Resolve-OwnerParitySecurePath -Path $Root -Name attestationRoot -Kind Directory
        $critical = @(Read-OwnerParityReferenceSet `
                -Root $resolvedRoot -References @($Attestation.critical) `
                -SkipExpected:(-not $ValidateVolatileBaseline))
        $knownPaths = [Collections.Generic.HashSet[string]]::new(
            $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
        foreach ($item in $critical) { [void]$knownPaths.Add([string]$item.relativePath) }
        $volatile = [Collections.Generic.List[object]]::new()
        foreach ($reference in @($Attestation.volatile)) {
            if ($reference.affectsParityInputs -ne $false) {
                throw "Volatile reference '$($reference.id)' must explicitly attest no parity-input effect."
            }
            $value = Read-OwnerParityExactFile -Root $resolvedRoot -Reference $reference -AllowGrowth
            if (-not $knownPaths.Add([string]$value.relativePath)) {
                throw "Attestation path '$($value.relativePath)' is duplicated or case-colliding."
            }
            if ($ValidateVolatileBaseline -and
                ([long]$reference.expectedPrefixLength -ne $value.length -or
                    [string]$reference.expectedPrefixSha256 -cne [string]$value.sha256)) {
                throw "Volatile reference '$($reference.id)' does not match its expected initial prefix."
            }
            [void]$volatile.Add($value)
        }
        $actualPaths = @(
            Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Force |
                ForEach-Object {
                    Assert-OwnerParitySecureNoLinks -Path $_.FullName
                    $_.FullName.Substring($resolvedRoot.Length).TrimStart(
                        [IO.Path]::DirectorySeparatorChar,
                        [IO.Path]::AltDirectorySeparatorChar).
                        Replace([IO.Path]::DirectorySeparatorChar, '/')
                })
        foreach ($path in $actualPaths) {
            if (-not $knownPaths.Contains([string]$path)) {
                throw "Unexpected attestation file '$path' is present."
            }
        }
        if ($actualPaths.Count -ne $knownPaths.Count) {
            throw 'One or more attested files are missing.'
        }
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'owner-parity-read-only-attestation'
            root = $resolvedRoot
            critical = @($critical | ForEach-Object {
                    [ordered]@{
                        id = $_.id
                        relativePath = $_.relativePath
                        length = $_.length
                        sha256 = $_.sha256
                        identity = $_.identity
                        contentBytesBase64 = [Convert]::ToBase64String($_.bytes)
                    }
                })
            volatile = @($volatile | ForEach-Object {
                    [ordered]@{
                        id = $_.id
                        relativePath = $_.relativePath
                        length = $_.length
                        sha256 = $_.sha256
                        identity = $_.identity
                        contentBytesBase64 = [Convert]::ToBase64String($_.bytes)
                    }
                })
        }
    }

    function Compare-OwnerParityAttestationSnapshots {
        param(
            [Parameter(Mandatory)][object]$Before,
            [Parameter(Mandatory)][object]$After,
            [Parameter(Mandatory)][object]$Attestation
        )
        $differences = [Collections.Generic.List[string]]::new()
        $beforeCritical = @{}; foreach ($item in @($Before.critical)) { $beforeCritical[$item.id] = $item }
        $afterCritical = @{}; foreach ($item in @($After.critical)) { $afterCritical[$item.id] = $item }
        foreach ($reference in @($Attestation.critical)) {
            $id = [string]$reference.id
            if (-not $beforeCritical.ContainsKey($id) -or -not $afterCritical.ContainsKey($id) -or
                [long]$beforeCritical[$id].length -ne [long]$afterCritical[$id].length -or
                [string]$beforeCritical[$id].sha256 -cne [string]$afterCritical[$id].sha256 -or
                ([string]$beforeCritical[$id].identity -cne 'unavailable' -and
                    [string]$beforeCritical[$id].identity -cne [string]$afterCritical[$id].identity)) {
                [void]$differences.Add("critical:$id")
            }
        }
        $beforeVolatile = @{}; foreach ($item in @($Before.volatile)) { $beforeVolatile[$item.id] = $item }
        $afterVolatile = @{}; foreach ($item in @($After.volatile)) { $afterVolatile[$item.id] = $item }
        foreach ($reference in @($Attestation.volatile)) {
            $id = [string]$reference.id
            if (-not $beforeVolatile.ContainsKey($id) -or -not $afterVolatile.ContainsKey($id)) {
                [void]$differences.Add("volatile:$id`:missing")
                continue
            }
            $left = $beforeVolatile[$id]
            $right = $afterVolatile[$id]
            if ([long]$right.length -lt [long]$left.length) {
                [void]$differences.Add("volatile:$id`:truncated")
                continue
            }
            if ([long]$right.length - [long]$left.length -gt [long]$reference.maximumGrowthBytes) {
                [void]$differences.Add("volatile:$id`:growth")
            }
            if ([string]$left.identity -cne 'unavailable' -and
                [string]$left.identity -cne [string]$right.identity) {
                [void]$differences.Add("volatile:$id`:replaced")
            }
            $prefix = [Convert]::FromBase64String([string]$left.contentBytesBase64)
            $afterBytes = [Convert]::FromBase64String([string]$right.contentBytesBase64)
            $afterPrefixHash = if ($afterBytes.Length -ge $prefix.Length) {
                $prefixCopy = [byte[]]::new($prefix.Length)
                [Array]::Copy($afterBytes, 0, $prefixCopy, 0, $prefix.Length)
                ([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData($prefixCopy))).ToLowerInvariant()
            }
            else { '' }
            if ($afterBytes.Length -lt $prefix.Length -or
                $afterPrefixHash -cne [string]$left.sha256) {
                [void]$differences.Add("volatile:$id`:prefix")
            }
        }

    return [pscustomobject][ordered]@{
        unchanged = $differences.Count -eq 0
        differences = @($differences)
        before = $Before
        after = $After
    }
}

function New-OwnerParityImmutableSnapshotRoot {
    param(
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][object]$Snapshot
    )
    $root = Resolve-OwnerParitySecurePath `
        -Path $DestinationRoot -Name snapshotRoot -AllowMissing
    if (Test-Path -LiteralPath $root) {
        throw 'Owner parity immutable snapshot root already exists.'
    }
    [void](New-Item -ItemType Directory -Path $root)
    foreach ($item in @($Snapshot.critical) + @($Snapshot.volatile)) {
        $relative = ConvertTo-OwnerParityRelativePath `
            -Path ([string]$item.relativePath) -Name snapshot.relativePath
        $path = Join-Path $root $relative
        $directory = Split-Path -Parent $path
        [void](New-Item -ItemType Directory -Path $directory -Force)
        $bytes = [Convert]::FromBase64String([string]$item.contentBytesBase64)
        $stream = [IO.FileStream]::new(
            $path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            65536,
            [IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
    }
    return Resolve-OwnerParitySecurePath -Path $root -Name snapshotRoot -Kind Directory
}

function Remove-OwnerParitySnapshotContent {
    param([Parameter(Mandatory)][object]$Snapshot)
    foreach ($item in @($Snapshot.critical) + @($Snapshot.volatile)) {
        [void]$item.PSObject.Properties.Remove('contentBytesBase64')
    }
}

function Write-OwnerParitySecureText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $resolved = Resolve-OwnerParitySecurePath -Path $Path -Name outputPath -AllowMissing
    $directory = Resolve-OwnerParitySecurePath `
        -Path (Split-Path -Parent $resolved) -Name outputDirectory -Kind Directory
    if (-not (Test-OwnerParitySecurePathWithin -Path $resolved -Root $directory)) {
        throw 'Owner parity output escaped its validated directory.'
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    $stage = Join-Path $directory ('.owner-parity-stage-' + [guid]::NewGuid().ToString('N'))
    $stream = [IO.FileStream]::new(
        $stage,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    try {
        [IO.File]::Move($stage, $resolved, $true)
        [void](Resolve-OwnerParitySecurePath -Path $resolved -Name outputPath -Kind File)
    }
    finally {
        if (Test-Path -LiteralPath $stage -PathType Leaf) {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        }
    }
    return $resolved
}
