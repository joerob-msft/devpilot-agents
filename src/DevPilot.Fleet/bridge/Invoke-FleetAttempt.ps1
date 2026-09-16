[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$ExecutorPath,
    [Parameter(Mandatory)][int]$OwnerPid,
    [Parameter(Mandatory)][long]$OwnerCreatedAt,
    [Parameter(Mandatory)][string]$LockPath,
    [Parameter(Mandatory)][string]$OwnerToken
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'FleetProtocol.ps1')
$directory = Split-Path -Parent $RequestPath
$outcomePath = Join-Path $directory 'outcome.json'
$cleanupConfirmed = $true

function Write-FleetJson {
    param([string]$Path, [object]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $Path, $true)
}

try {
    if (-not $IsWindows) { throw 'The live fleet executor is Windows-only until Linux containment is qualified.' }
    [void](Assert-AgentTrustedFile -Path $RequestPath -AllowedRoot $directory -Private)
    if ((Get-Item -LiteralPath $RequestPath).Length -gt 262144) { throw 'Request exceeds 256 KiB.' }
    $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    $parent = Get-Process -Id $OwnerPid
    if ($parent.StartTime.ToUniversalTime() -gt [DateTimeOffset]::FromUnixTimeMilliseconds($OwnerCreatedAt).UtcDateTime) {
        throw 'Fleet parent PID has been reused.'
    }
    $claim = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
    if ($claim.token -cne $OwnerToken -or $claim.pid -ne $OwnerPid) { throw 'Fleet ownership changed before admission.' }
    if ($request.timeoutSeconds -isnot [long] -and $request.timeoutSeconds -isnot [int]) { throw 'Invalid timeout.' }
    if ($request.timeoutSeconds -lt 10 -or $request.timeoutSeconds -gt 600) { throw 'Invalid timeout.' }
    if ($request.nonce -notmatch '^[a-f0-9]{32}$' -or $request.inputHash -notmatch '^[a-f0-9]{64}$') { throw 'Invalid request binding.' }
    if ($request.prompt -isnot [string] -or $request.prompt.Length -gt 200000) { throw 'Invalid prompt.' }
    Write-FleetJson -Path (Join-Path $directory 'bridge.json') -Value @{
        pid = $PID; startedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    }
    $homePath = Join-Path $directory 'cli-home'
    $workPath = Join-Path $directory 'workspace'
    [void][IO.Directory]::CreateDirectory($homePath)
    [void][IO.Directory]::CreateDirectory($workPath)
    Write-FleetJson -Path (Join-Path $homePath 'config.json') -Value @{
        disableAllHooks = $true; 'ide.autoConnect' = $false
    }

    # Carry authentication in memory, never a copied user configuration, plugin, or login cache.
    if ([string]::IsNullOrWhiteSpace($env:COPILOT_GITHUB_TOKEN)) {
        $gh = (Get-Command gh -CommandType Application | Select-Object -First 1).Source
        $cleanupConfirmed = $false
        $auth = Invoke-TimedProcess -FilePath $gh -ArgumentList @('auth', 'token') `
            -CaptureStdOut -CaptureStdErr -ContainDescendants -MaxOutputCharacters 8192 -TimeoutSeconds 20
        $cleanupConfirmed = $true
        if ($auth.ExitCode -ne 0 -or $auth.TimedOut -or $auth.OutputLimitExceeded -or -not $auth.StdOut.Trim()) {
            throw 'Authentication unavailable. Set COPILOT_GITHUB_TOKEN or authenticate gh before serving.'
        }
        $env:COPILOT_GITHUB_TOKEN = $auth.StdOut.Trim()
    }
    $env:COPILOT_HOME = $homePath
    $remove = @(Get-ChildItem Env: | Where-Object {
        ($_.Name -match '^(AGENCY_|COPILOT_|OTEL_|NODE_OPTIONS$|USE_TGREP|BASH_ENV$|ENV$)') -and
        $_.Name -notin @('COPILOT_GITHUB_TOKEN', 'COPILOT_HOME')
    } | Select-Object -ExpandProperty Name)
    $arguments = @(
        '--available-tools=__devpilot_no_tools__',
        '--deny-tool=shell, write, read',
        '--disable-builtin-mcps', '--no-custom-instructions', '--no-ask-user',
        '--no-auto-update', '--no-remote-export', '--disallow-temp-dir',
        '--output-format', 'json', '--silent'
    )
    $cancelPath = Join-Path $directory 'cancel'
    $probe = {
        $parent.Refresh()
        if ($parent.HasExited -or (Test-Path -LiteralPath $cancelPath)) { return $true }
        $current = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
        return $current.token -cne $OwnerToken
    }.GetNewClosure()
    $parent.Refresh()
    if ($parent.HasExited -or (Test-Path -LiteralPath $cancelPath)) {
        Write-FleetJson -Path $outcomePath -Value @{ status = 'cancelled'; cleanupConfirmed = $true }
        exit 0
    }
    $cleanupConfirmed = $false
    $process = Invoke-TimedProcess -FilePath $ExecutorPath -ArgumentList $arguments `
        -WorkingDirectory $workPath -StandardInputContent $request.prompt `
        -EnvironmentVariablesToRemove $remove -CaptureStdOut -CaptureStdErr `
        -ContainDescendants -CancellationProbe $probe -MaxOutputCharacters 1048576 `
        -TimeoutSeconds ([int]$request.timeoutSeconds)
    $cleanupConfirmed = $true
    $status = 'failed'
    $errorText = $null
    $result = $null
    $model = $null
    if ($process.OutputLimitExceeded) { $errorText = 'Executor output exceeded 1,048,576 characters per stream.' }
    elseif ($process.Cancelled) { $status = 'cancelled' }
    elseif ($process.TimedOut) { $status = 'timed_out' }
    elseif ($process.ExitCode -ne 0) { $errorText = "Executor exited $($process.ExitCode). Check local authentication and CLI compatibility." }
    else {
        $outcome = Get-AgentCliJsonOutcome -StdOutText $process.StdOut
        if (-not $outcome -or -not $outcome.ModelActuallyRan -or $outcome.ExitCode -ne 0) {
            throw 'Missing successful structured CLI outcome.'
        }
        # Availability filtering is the enforcement; reject any evidence it was bypassed.
        foreach ($line in ($process.StdOut -split "`r?`n")) {
            if (-not $line.Trim().StartsWith('{')) { continue }
            $event = $line | ConvertFrom-Json
            if ($event.type -like 'tool.execution*') { throw 'Tool execution observed in tool-disabled profile.' }
        }
        $schema = New-FleetResultSchema -Nonce $request.nonce -InputHash $request.inputHash
        $result = ConvertFrom-FleetAnswer -Answer $outcome.Answer -Schema $schema
        $model = $outcome.Model
        if ($null -eq $result) {
            $status = 'invalid_result'
            $errorText = 'Missing, malformed, or conflicting result. Bounded answer retained in answer.txt.'
            [IO.File]::WriteAllText((Join-Path $directory 'answer.txt'),
                $outcome.Answer.Substring(0, [Math]::Min(65536, $outcome.Answer.Length)), [Text.UTF8Encoding]::new($false))
        }
        else { $status = 'succeeded' }
    }
    Write-FleetJson -Path $outcomePath -Value @{
        status = $status; result = $result; model = $model; error = $errorText; cleanupConfirmed = $cleanupConfirmed
    }
}
catch {
    Write-FleetJson -Path $outcomePath -Value @{
        status = $(if ($cleanupConfirmed) { 'failed' } else { 'unknown' })
        error = $_.Exception.Message; cleanupConfirmed = $cleanupConfirmed
    }
    exit 1
}
