param(
    [string]$ConfigFile, [string]$RepoPath, [string]$StateDir, [string]$EventLogDirectory,
    [string]$DurableStateRoot, [string]$LeaseRoot, [string]$OperatorAlias,
    [int]$PullRequestId, [switch]$Once, [switch]$ForceAnalysis, [switch]$IncludeOwnPullRequests, [string]$OutputMode,
    [string]$ManualDispatchManifest,
    [switch]$EnableFindingComments, [switch]$EnableThreadReplies, [switch]$EnableSummaryComment
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
# This replaces only the provider/agent workload, not the broker issuer or startup checks.
Assert-AgentManualDispatchEarlyContext -ManifestPath $ManualDispatchManifest
$config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
if ($config.startupTestMode -eq 'early-exit') {
    [Console]::Error.WriteLine('[startup-test-failure] isolated child failed before readiness')
    exit 23
}
if ($config.startupTestMode -eq 'termination-failed') {
    $secret = Receive-AgentBrokerAttestationSecret
    [Array]::Clear($secret, 0, $secret.Length)
    $manifest = Get-Content -LiteralPath $ManualDispatchManifest -Raw | ConvertFrom-Json -AsHashtable
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $manifest.startupPipe, [IO.Pipes.PipeDirection]::Out)
    try {
        $pipe.Connect(10000)
        $writer = [IO.StreamWriter]::new($pipe)
        $writer.WriteLine((ConvertTo-AgentCanonicalJson @{
                    schemaVersion = 1; operation = 'rejected'; dispatchId = $manifest.dispatchId
                    code = 'launch-failed'; detail = 'startup-test-failure with a still-running child'
                }))
        $writer.Flush()
        Start-Sleep -Seconds 90
    }
    finally { $pipe.Dispose() }
    exit 24
}
$identity = Resolve-AgentProviderRepositoryIdentity (New-AgentProviderContext -Provider GitHub `
        -Organization 'startup-fixture' -RepositoryName 'repository')
$context = Get-AgentDurableStateContext -DurableStateRoot $DurableStateRoot -RepositoryIdentity $identity -Role reviewer -Create
$eventPath = Join-Path $EventLogDirectory 'startup-fixture.jsonl'
try {
    $prompt = Enter-AgentManualDispatchStartup -ManifestPath $ManualDispatchManifest `
        -RepositoryIdentity $identity -RepositoryRoot $RepoPath -DurableContext $context -LeaseRoot $LeaseRoot `
        -Role reviewer -EventLogPath $eventPath -BoundCapabilities @{
            EnableFindingComments = [bool]$EnableFindingComments
            EnableThreadReplies = [bool]$EnableThreadReplies
            EnableSummaryComment = [bool]$EnableSummaryComment
            EnableApprovalVote = $false
        }
    if ($prompt -cne 'isolated startup context') { throw 'Startup context did not round trip.' }
    $manifest = Get-Content -LiteralPath $ManualDispatchManifest -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::WriteAllText($eventPath, (ConvertTo-AgentCanonicalJson @{
                dispatchId = $manifest.dispatchId; processId = $PID; startupVerified = $true
                includeOwnPullRequests = [bool]$IncludeOwnPullRequests
                attestationHandleCleared = [string]::IsNullOrEmpty($env:DEVPILOT_BROKER_ATTESTATION_HANDLE)
            }), [Text.UTF8Encoding]::new($false))
    if ($config.startupTestMode -in @('wait', 'eof-termination-failed', 'shutdown-termination-failed')) { Start-Sleep -Seconds 90 }
}
catch {
    [IO.File]::WriteAllText((Join-Path $EventLogDirectory 'startup-test-error.txt'),
        "$($_.Exception.Message)`n$($_.ScriptStackTrace)", [Text.UTF8Encoding]::new($false))
    throw
}
finally { Exit-AgentManualDispatchAuthority }
