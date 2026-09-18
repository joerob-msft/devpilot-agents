BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $validator = Join-Path $root 'tools\Test-DevPilotVersion.ps1'
}

Describe 'DevPilot toolkit version source' {
    It 'keeps every published version surface aligned to VERSION' {
        $result = & $validator -ExpectedVersion '0.4.0' -ExpectedTag 'v0.4.0'
        $result.Version | Should -Be '0.4.0'
        $result.VersionLine | Should -Be '0.4'
        $result.ChannelTag | Should -Be 'v0.4'
    }

    It 'rejects a requested immutable tag that does not match VERSION' {
        { & $validator -ExpectedTag 'v0.4.1' } | Should -Throw '*does not match VERSION*'
    }
}
