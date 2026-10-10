BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $validator = Join-Path $root 'tools\Test-DevPilotVersion.ps1'
    $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
    $parsedVersion = [version]$version
    $versionLine = '{0}.{1}' -f $parsedVersion.Major, $parsedVersion.Minor
    $differentTag = 'v{0}.{1}.{2}' -f $parsedVersion.Major, $parsedVersion.Minor, ($parsedVersion.Build + 1)
}

Describe 'DevPilot toolkit version source' {
    It 'keeps every published version surface aligned to VERSION' {
        $result = & $validator -ExpectedVersion $version -ExpectedTag "v$version"
        $result.Version | Should -Be $version
        $result.VersionLine | Should -Be $versionLine
        $result.ChannelTag | Should -Be "v$versionLine"
    }

    It 'rejects a requested immutable tag that does not match VERSION' {
        { & $validator -ExpectedTag $differentTag } | Should -Throw '*does not match VERSION*'
    }
}
