Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SignoffReportDelivery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Prepared,
        [Parameter(Mandatory)][string]$AgencyPath,
        [switch]$EnableDelivery,
        [switch]$PreviewOnly
    )
    $config = $Prepared.config
    if ($PreviewOnly -or -not $EnableDelivery -or -not $config.enabled) {
        return @{ status = 'disabled'; reason = 'Explicit delivery authorization required; preview is terminal.' }
    }
    if ($config.privateOperatorDestination -ne $true -or $config.chatId -cnotmatch '^[A-Za-z0-9_:@.=-]{1,256}$') {
        throw 'An exact private study-operator chat destination is required.'
    }
    $toolkit = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $root = Resolve-AgentTrustedRoot -Path $config.stateRoot -Kind durable-state -RepositoryRoot $toolkit -Create
    $lock = Enter-AgentLock -Path (Join-Path $root 'report-delivery.lock') -AgentName 'signoff-report-dispatcher'
    if (-not $lock) { throw 'Report delivery is already owned.' }
    $session = $null
    $path = Join-Path $root "$($Prepared.eventKey).json"
    try {
        if (Test-Path -LiteralPath $path) {
            [void](Assert-AgentTrustedFile -Path $path -AllowedRoot $root -Private)
            $prior = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            return @{ status = $prior.status; reason = 'Prior send attempt exists; never resend automatically.' }
        }
        $record = @{ schemaVersion = 1; eventKey = $Prepared.eventKey; reportHash = $Prepared.reportHash
            chatId = $config.chatId; status = 'unknown'; messageId = $null }
        # Durable unknown-before-send survives process death and prevents duplicate delivery.
        [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $stream = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        $session = Open-AgentMcpSession -AgencyPath $AgencyPath -Server workiq -DeadlineUtc $deadline
        $parentUrl = "/chats/$($config.chatId)/messages"
        $html = '<p>' + [Net.WebUtility]::HtmlEncode([string]$Prepared.summary).Replace("`n", '</p><p>') + '</p>'
        $response = Invoke-AgentWorkIqTool -Session $session -Name create_entity -AllowedTools @('create_entity') `
            -AllowedPathPrefixes @($parentUrl) -Arguments @{
                parentUrl = $parentUrl; jsonBody = @{ body = @{ contentType = 'html'; content = $html } }
            } -DeadlineUtc $deadline
        if ($null -eq $response -or -not $response.PSObject.Properties['id'] -or
            $response.id -isnot [string] -or [string]::IsNullOrWhiteSpace($response.id)) {
            throw 'Delivery result is unknown; quarantined for operator reconciliation, never automatically retried.'
        }
        $record.status = 'confirmed'
        $record.messageId = $response.id
        $temporary = "$path.confirmed"
        [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $path, $true)
        return $record
    }
    finally {
        try { if ($session) { Close-AgentMcpSession -Session $session } }
        finally { $lock.Dispose() }
    }
}
Export-ModuleMember -Function Invoke-SignoffReportDelivery
