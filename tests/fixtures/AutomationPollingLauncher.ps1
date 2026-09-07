param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Toolkit, [string]$Mode)
$ErrorActionPreference = 'Stop'
Import-Module "$Toolkit\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
$env:DEVPILOT_SCHEDULING_FIXTURE = $Root
$env:LOCALAPPDATA = Join-Path $Root 'appdata'
$watch = Resolve-AgentTrustedRoot -Path (Join-Path $Root 'watch') -Kind watch-state -RepositoryRoot $Toolkit -Create
$durable = Resolve-AgentTrustedRoot -Path (Join-Path $Root 'durable') -Kind durable-state -RepositoryRoot $Toolkit -Create
$leases = Resolve-AgentTrustedRoot -Path (Join-Path $Root 'leases') -Kind lease -RepositoryRoot $Toolkit -Create
$roles = @{}
$workers = @()
foreach ($role in @('reviewer', 'review-handler')) {
    $scriptName = if ($role -ceq 'reviewer') { 'Start-ReviewerAgent.ps1' } else { 'Start-ReviewHandlerAgent.ps1' }
    $script = Join-Path $Toolkit "src\Agents\$role\$scriptName"
    $roleState = Join-Path $watch $role
    New-Item -ItemType Directory -Path $roleState -Force | Out-Null
    $policy = Get-AgentHarnessCapabilityDescriptor -Role $role -PreviewOnly
    $roles[$role] = @{
        enabled = $true; scriptPath = $script; configFile = "$Toolkit\config\agent.json"; configRoot = "$Toolkit\config"
        capabilities = @(); mandatoryDenies = @($policy.absoluteDenies); absoluteDenies = @($policy.absoluteDenies)
    }
    $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script, '-ConfigFile', "$Toolkit\config\agent.json",
        '-StateDir', $roleState, '-DurableStateRoot', $durable, '-LeaseRoot', $leases,
        '-AgentName', "$role-fixture", '-OperatorAlias', 'fixture', '-OutputMode', 'Json')
    if ($Mode -ceq 'once') { $argv += '-Once' } else { $argv += @('-IntervalSeconds', '900') }
    $workers += @{ role = $role; continuous = ($Mode -cne 'once'); arguments = $argv }
}
$descriptor = @{
    schemaVersion = 1; ownerProcessId = $PID; stateRoot = $watch; durableStateRoot = $durable; leaseRoot = $leases
    operatorAlias = 'fixture'; roles = $roles
}
if ($Mode -cne 'unavailable') {
    $descriptor.launcherControl = @{
        schemaVersion = 1; sessionId = [Guid]::NewGuid().ToString('D')
        ownerStartIdentity = Get-AgentProcessStartIdentity (Get-Process -Id $PID); automaticWorkers = $workers
    }
}
$path = Join-Path $watch 'broker.descriptor.v1.json'
[IO.File]::WriteAllText($path, (ConvertTo-AgentCanonicalJson $descriptor))
$dashboard = Join-Path $Toolkit 'src\DevPilot.Dashboard'
& "$dashboard\node_modules\bun\bin\bun.exe" --conditions=browser "$dashboard\dist\src\index.js" --launch-mode preview `
    --state-dir $watch --broker-executable (Resolve-AgentPwshPath) `
    --broker-script "$Toolkit\tools\Invoke-DevPilotAgentDispatch.ps1" --broker-descriptor $path
if ($LASTEXITCODE -ne 0) { throw "Polling fixture dashboard failed: $LASTEXITCODE" }
