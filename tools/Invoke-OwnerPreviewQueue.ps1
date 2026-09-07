#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs and manages the declared hourly Owner preview queue.

.DESCRIPTION
    One invocation processes at most one declared pull request head. It creates no
    Copilot app session or worktree: Task Scheduler starts this script directly
    from a stable ordinary checkout, and this script calls Layer 1 prepare-run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('run', 'status', 'requeue', 'install', 'disable', 'uninstall', 'task-status', 'install-dry-run')]
    [string]$Action,

    [Parameter(Mandatory)][string]$ConfigFile,
    [string]$StateRoot = '',
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$InstanceName = '',
    [ValidatePattern('^$|^[0-9a-f]{64}$')][string]$HeadKey = '',
    [string]$Reason = '',
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $RepoRoot 'src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1') -Force
. (Join-Path $RepoRoot 'src/Agents/reviewer/CorpusSeal.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/AcquisitionPackage.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewSubject.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewReport.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewQueue.ps1')

function Write-OwnerPreviewQueueSummary {
    param([Parameter(Mandatory)]$Value)
    Write-Output (ConvertTo-Json -InputObject $Value -Depth 16 -Compress)
}

function Assert-OwnerPreviewQueueTaskSupport {
    foreach ($name in @(
            'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskPrincipal',
            'New-ScheduledTaskSettingsSet', 'Register-ScheduledTask', 'Get-ScheduledTask',
            'Disable-ScheduledTask', 'Unregister-ScheduledTask')) {
        if ($null -eq (Get-Command $name -ErrorAction SilentlyContinue)) {
            throw "Windows Task Scheduler command '$name' is unavailable."
        }
    }
}

function New-OwnerPreviewScheduledTaskParts {
    param([Parameter(Mandatory)]$Plan)
    $actionPart = New-ScheduledTaskAction -Execute ([string]$Plan.execute) -Argument ([string]$Plan.arguments) `
        -WorkingDirectory ([string]$Plan.workingDirectory)
    $triggerPart = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(1)) `
        -RepetitionInterval ([TimeSpan]::FromHours(1))
    $principalPart = New-ScheduledTaskPrincipal -UserId ([string]$Plan.principal.userId) `
        -LogonType Interactive -RunLevel Limited
    $settingsPart = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::FromMinutes(55))
    return [pscustomobject]@{
        Action = $actionPart
        Trigger = $triggerPart
        Principal = $principalPart
        Settings = $settingsPart
    }
}

try {
    $configPath = Assert-OwnerPreviewQueueSafePath -Path $ConfigFile -Where 'Queue configuration'
    $config = Read-OwnerPreviewQueueConfig -Path $configPath -RepoRoot $RepoRoot
    if ($InstanceName -ne '' -and $InstanceName -cne [string]$config.instanceName) {
        throw "-InstanceName '$InstanceName' does not match queue configuration instance '$($config.instanceName)'."
    }
    $instance = [string]$config.instanceName
    $root = Resolve-OwnerPreviewQueueStateRoot -StateRoot $StateRoot -InstanceName $instance
    [void](New-Item -ItemType Directory -Force -Path $root)

    switch ($Action) {
        'run' {
            [void](Assert-OwnerPreviewQueueStableToolkit -Config $config)
            $lock = Enter-AgentLock -Path (Join-Path $root 'queue.lock') -AgentName "owner-preview-$instance"
            try {
                Write-OwnerPreviewQueueSummary -Value (Invoke-OwnerPreviewQueueTick -Config $config -StateRoot $root)
            }
            finally { Exit-AgentLock -Stream $lock }
            break
        }
        'status' {
            $key = Get-OwnerPreviewQueueKey -StateRoot $root
            $index = Read-OwnerPreviewQueueSignedFile -Path (Join-Path (Join-Path $root 'index') 'current.json') -Key $key
            if ($null -eq $index) {
                Write-OwnerPreviewQueueSummary -Value ([ordered]@{
                        action = 'status'; capability = $script:OwnerPreviewQueueCapability; records = @()
                    })
            }
            else { Write-OwnerPreviewQueueSummary -Value $index }
            break
        }
        'requeue' {
            if ($HeadKey -eq '') { throw '-HeadKey is required for -Action requeue.' }
            if ([string]::IsNullOrWhiteSpace($Reason)) { throw '-Reason is required for -Action requeue.' }
            $lock = Enter-AgentLock -Path (Join-Path $root 'queue.lock') -AgentName "owner-preview-$instance"
            try {
                $audit = Invoke-OwnerPreviewQueueRequeue -StateRoot $root -HeadKey $HeadKey -Reason $Reason
                Write-OwnerPreviewQueueSummary -Value ([ordered]@{
                        action = 'requeue'; headKey = $HeadKey; state = 'pending'; audit = $audit
                    })
            }
            finally { Exit-AgentLock -Stream $lock }
            break
        }
        'install-dry-run' {
            [void](Assert-OwnerPreviewQueueStableToolkit -Config $config)
            Write-OwnerPreviewQueueSummary -Value ([ordered]@{
                    action = 'install-dry-run'
                    task = Get-OwnerPreviewQueueTaskPlan -Config $config -ConfigFile $configPath -StateRoot $root
                    createsAppSession = $false
                    createsWorktree = $false
                })
            break
        }
        'install' {
            [void](Assert-OwnerPreviewQueueStableToolkit -Config $config)
            Assert-OwnerPreviewQueueTaskSupport
            $plan = Get-OwnerPreviewQueueTaskPlan -Config $config -ConfigFile $configPath -StateRoot $root
            $parts = New-OwnerPreviewScheduledTaskParts -Plan $plan
            [void](Register-ScheduledTask -TaskName ([string]$plan.taskName) -Action $parts.Action `
                    -Trigger $parts.Trigger -Principal $parts.Principal -Settings $parts.Settings -Force)
            Write-OwnerPreviewQueueSummary -Value ([ordered]@{ action = 'install'; taskName = $plan.taskName; installed = $true })
            break
        }
        'task-status' {
            Assert-OwnerPreviewQueueTaskSupport
            $plan = Get-OwnerPreviewQueueTaskPlan -Config $config -ConfigFile $configPath -StateRoot $root
            $task = Get-ScheduledTask -TaskName ([string]$plan.taskName) -ErrorAction SilentlyContinue
            Write-OwnerPreviewQueueSummary -Value ([ordered]@{
                    action = 'task-status'
                    taskName = $plan.taskName
                    installed = ($null -ne $task)
                    state = $(if ($null -ne $task) { [string]$task.State } else { 'Absent' })
                })
            break
        }
        'disable' {
            Assert-OwnerPreviewQueueTaskSupport
            $plan = Get-OwnerPreviewQueueTaskPlan -Config $config -ConfigFile $configPath -StateRoot $root
            $task = Get-ScheduledTask -TaskName ([string]$plan.taskName) -ErrorAction SilentlyContinue
            if ($null -ne $task) { [void](Disable-ScheduledTask -TaskName ([string]$plan.taskName)) }
            Write-OwnerPreviewQueueSummary -Value ([ordered]@{
                    action = 'disable'; taskName = $plan.taskName; installed = ($null -ne $task); statePreserved = $true
                })
            break
        }
        'uninstall' {
            Assert-OwnerPreviewQueueTaskSupport
            $plan = Get-OwnerPreviewQueueTaskPlan -Config $config -ConfigFile $configPath -StateRoot $root
            $task = Get-ScheduledTask -TaskName ([string]$plan.taskName) -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                Unregister-ScheduledTask -TaskName ([string]$plan.taskName) -Confirm:$false
            }
            Write-OwnerPreviewQueueSummary -Value ([ordered]@{
                    action = 'uninstall'; taskName = $plan.taskName; removed = ($null -ne $task); statePreserved = $true
                })
        }
    }
}
catch {
    Write-Error ([string]$_.Exception.Message)
    exit 1
}
