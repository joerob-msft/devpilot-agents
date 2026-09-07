# TestDrive copies only. No provider executable, arbitrary endpoint, or mutation is reachable.
function Resolve-AgentRepositoryRoot { param([string]$ConfigPath) return (Split-Path $ConfigPath -Parent) }
function Invoke-AgentGitHubApi {
    param([string]$Path, [string]$Method = 'GET', [hashtable]$Body, [int]$TimeoutSeconds, [switch]$RawText)
    if ($Method -cne 'GET' -or $Body) { throw 'Scheduling fixtures forbid provider mutations.' }
    if ($Path -ceq 'repos/scheduling-fixture/repository') {
        $response = '{"id":114,"full_name":"scheduling-fixture/repository","name":"repository"}'
    }
    elseif ($Path -cmatch '^repos/scheduling-fixture/repository/pulls/(114|115|116)$') {
        $number = [int]$Matches[1]
        if ($number -in @(115, 116) -and (Test-Path (Join-Path $env:DEVPILOT_SCHEDULING_FIXTURE 'delay-revalidation'))) {
            [IO.File]::WriteAllText((Join-Path $env:DEVPILOT_SCHEDULING_FIXTURE 'revalidating'), 'fixture')
            Start-Sleep -Seconds 2
        }
        $sha = if (Test-Path (Join-Path $env:DEVPILOT_SCHEDULING_FIXTURE 'source-changed')) { 'b' * 40 } else { 'a' * 40 }
        $response = ConvertTo-Json -Compress @{
            number = $number; state = 'open'; draft = $false; title = 'isolated scheduling'
            base = @{ ref = 'main' }; head = @{ ref = 'fixture'; sha = $sha }; user = @{ login = 'fixture' }
        }
    }
    elseif ($Path -cmatch '^repos/scheduling-fixture/repository/pulls/(114|115|116)/reviews\?per_page=100$') { $response = '[]' }
    else { throw 'Scheduling fixtures forbid non-fixture provider endpoints.' }
    if ($RawText) { return $response }
    return $response | ConvertFrom-Json
}
