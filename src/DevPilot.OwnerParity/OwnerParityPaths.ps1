if ($IsWindows -and -not ('DevPilot.OwnerParity.NativePaths' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;

namespace DevPilot.OwnerParity
{
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
