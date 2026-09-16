BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    . "$PSScriptRoot\..\src\DevPilot.Fleet\bridge\FleetProtocol.ps1"
    $schema = @{
        Keys = @('nonce', 'summary')
        Fields = @{
            nonce = @{ Type = 'exact'; Expected = 'bound' }
            summary = @{ Type = 'string'; MaxLength = 100 }
        }
    }
}

Describe 'Fleet result framing' {
    It 'accepts the same bound schema in prefixed and complete bare object forms' {
        $json = '{"nonce":"bound","summary":"Evidence"}'
        (ConvertFrom-FleetAnswer -Answer $json -Schema $schema).summary | Should -BeExactly 'Evidence'
        (ConvertFrom-FleetAnswer -Answer "FLEET_RESULT: $json" -Schema $schema).summary | Should -BeExactly 'Evidence'
    }
    It 'rejects wrong binding, extra keys, conflicting markers and concatenated objects' {
        ConvertFrom-FleetAnswer -Answer '{"nonce":"wrong","summary":"Evidence"}' -Schema $schema | Should -BeNullOrEmpty
        ConvertFrom-FleetAnswer -Answer '{"nonce":"bound","summary":"Evidence","extra":1}' -Schema $schema | Should -BeNullOrEmpty
        ConvertFrom-FleetAnswer -Answer '{"nonce":"bound","summary":"A"}{"nonce":"bound","summary":"B"}' -Schema $schema | Should -BeNullOrEmpty
        ConvertFrom-FleetAnswer -Answer 'FLEET_RESULT: {"nonce":"bound","summary":"A"} FLEET_RESULT: {"nonce":"bound","summary":"B"}' -Schema $schema | Should -BeNullOrEmpty
    }
    It 'rejects the same extra-field regression fixture as the TypeScript host' {
        $fixture = Get-Content -LiteralPath "$PSScriptRoot\..\src\DevPilot.Fleet\test\fixtures\rejected-extra-field.json" -Raw
        $resultSchema = New-FleetResultSchema -Nonce ('a' * 32) -InputHash ('b' * 64)
        ConvertFrom-FleetAnswer -Answer $fixture -Schema $resultSchema | Should -BeNullOrEmpty
        ConvertFrom-FleetAnswer -Answer "FLEET_RESULT:$fixture" -Schema $resultSchema | Should -BeNullOrEmpty
        $valid = @{ schemaVersion = 1; nonce = 'a' * 32; inputHash = 'b' * 64; summary = 'Evidence'; findings = @() } |
            ConvertTo-Json -Compress
        (ConvertFrom-FleetAnswer -Answer $valid -Schema $resultSchema).summary | Should -BeExactly 'Evidence'
    }
}
