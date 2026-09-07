param(
    [Parameter(Mandatory)][string]$FixtureRoot,
    [Parameter(Mandatory)][string]$DurableRoot,
    [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
    [ValidateSet('send', 'hold-root', 'crash-intent', 'crash-ack')][string]$Mode = 'send'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
$module = Get-Module DevPilot.AgentHarness
& $module {
    function script:Send-AgentMcpRequest {
        param($Session, $Method, $Params, $DeadlineUtc)
        if ($Method -cne 'tools/call' -or $Params.name -cne 'create_entity' -or
            $Params.arguments.parentUrl -cnotmatch '^/teams/fixture-team/channels/fixture-channel/messages(?:/fixture-root/replies)?$') {
            throw 'Fixture refused an unexpected operation.'
        }
        if ($Session.Mode -ceq 'crash-intent') { [Environment]::Exit(73) }
        [IO.File]::WriteAllText((Join-Path $Session.FixtureRoot "$($Session.Role).post.json"),
            (ConvertTo-Json -InputObject $Params -Depth 8 -Compress))
        if ($Session.Mode -ceq 'crash-ack') { [Environment]::Exit(74) }
        if ($Session.Mode -ceq 'hold-root') {
            [IO.File]::WriteAllText((Join-Path $Session.FixtureRoot 'root-post-entered'), 'ready')
            while (-not (Test-Path -LiteralPath (Join-Path $Session.FixtureRoot 'release-root'))) {
                if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw 'Fixture wait expired.' }
                Start-Sleep -Milliseconds 20
            }
        }
        $id = if ($Params.arguments.parentUrl.EndsWith('/replies')) { 'fixture-reply' } else { 'fixture-root' }
        return [pscustomobject]@{ structuredContent = [pscustomobject]@{ statusCode = 201; data = [pscustomobject]@{ id = $id } } }
    }
}
$session = @{ FixtureRoot = $FixtureRoot; Role = $Role; Mode = $Mode }
[IO.File]::WriteAllText((Join-Path $FixtureRoot "$Role.started"), 'ready')
$result = Send-AgentTeamsThreadedChannelMessage -Session $session -DurableStateRoot $DurableRoot `
    -RepositoryIdentity @{ key = 'v1:github:987654'; verified = $true } -Role $Role `
    -NotificationEvent completed -PullRequestId 103 -SourceCommit 'fixture-commit' `
    -TeamId fixture-team -ChannelId fixture-channel -Title 'Fixture title' -Body 'Fixture body'
$result | ConvertTo-Json -Depth 6 -Compress
