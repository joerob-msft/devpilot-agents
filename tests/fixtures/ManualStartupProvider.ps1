# Loaded only into a TestDrive copy of the module. Every non-fixture endpoint/verb fails closed.
function Invoke-AgentGitHubApi {
    param([string]$Path, [string]$Method = 'GET', [hashtable]$Body, [int]$TimeoutSeconds, [switch]$RawText)
    if ($Method -cne 'GET' -or $Body) { throw 'The startup fixture forbids provider mutations.' }
    $response = switch -CaseSensitive ($Path) {
        'repos/startup-fixture/repository' { '{"id":114,"full_name":"startup-fixture/repository","name":"repository"}' }
        'repos/startup-fixture/repository/pulls/114' {
            '{"number":114,"state":"open","draft":false,"title":"isolated startup","base":{"ref":"main"},"head":{"ref":"fixture","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"user":{"login":"fixture"}}'
        }
        'repos/startup-fixture/repository/pulls/114/reviews?per_page=100' { '[]' }
        default { throw 'The startup fixture forbids non-fixture provider endpoints.' }
    }
    if ($RawText) { return $response }
    return $response | ConvertFrom-Json
}
