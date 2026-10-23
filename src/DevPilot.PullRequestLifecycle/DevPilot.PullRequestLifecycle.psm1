#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot `
        '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
. (Join-Path $PSScriptRoot `
    '..\Agents\reviewer\ApprovedOwnerV2Comments.ps1')

$script:RootName = 'stale-pr-lifecycle-v1'
$script:KeyName = 'stale-pr-lifecycle-service-authorization.hmac'
$script:PolicyKind = 'stale-pr-lifecycle-v1-service-authorization-policy'
$script:TargetRef = 'refs/heads/master'
$script:MaxCacheRecordBytes = 65536L
$script:MaxActivityProofFilesPerPr = 64
$script:MaxActivityProofHistoryEntriesPerPr = 65
$script:MaxActivityProofTotalBytesPerPr = 1048576L
$script:MaxCachedPushFilesPerPr = 256
$script:MaxCachedPushTotalBytesPerPr = 4194304L

function Test-StalePrNonBoolInteger {
    param(
        [AllowNull()]$Value,
        [long]$Minimum = 1L,
        [long]$Maximum = [int]::MaxValue
    )
    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }
    if ($Value -isnot [byte] -and
        $Value -isnot [int16] -and
        $Value -isnot [int32] -and
        $Value -isnot [int64]) {
        return $false
    }
    $numeric = [long]$Value
    return ($numeric -ge $Minimum -and $numeric -le $Maximum)
}

function Test-StalePrSafeId {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return ($Value -cmatch '^[0-9a-zA-Z._-]{1,128}$')
}

function Get-StalePrDigest {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    return Get-ApprovedOwnerV2Digest $Value
}

function ConvertTo-StalePrUtc {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )
    $parsed = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
        [Globalization.DateTimeStyles]::AdjustToUniversal
    if ([DateTime]::TryParseExact(
            $Value,
            [string[]]@(
                'yyyyMMddTHHmmssfffffffZ',
                'yyyyMMddTHHmmssZ'),
            [Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    if (-not [DateTime]::TryParse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref]$parsed)) {
        throw "Invalid stale PR $Name."
    }
    return $parsed.ToUniversalTime()
}

function Get-StalePrFailureReason {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $exception = $ErrorRecord.Exception
    $messages = [Collections.Generic.List[string]]::new()
    while ($null -ne $exception) {
        if ($exception.Data.Contains('stalePrReason') -and
            [string]$exception.Data['stalePrReason'] -cin @(
                'stale-pr-read-budget-exhausted',
                'stale-pr-deadline-exhausted')) {
            return [string]$exception.Data['stalePrReason']
        }
        [void]$messages.Add([string]$exception.Message)
        $exception = $exception.InnerException
    }
    foreach ($known in @(
            'stale-pr-read-budget-exhausted',
            'stale-pr-deadline-exhausted'
        )) {
        if (@($messages | Where-Object {
                    [string]$_ -ceq $known -or
                    [string]$_ -clike "*$known*"
                }).Count -gt 0) {
            return $known
        }
    }
    return [string]$ErrorRecord.Exception.Message
}

function Get-StalePrBudgetDiagnostic {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()]$Budget = $null
    )
    $reason = Get-StalePrFailureReason $ErrorRecord
    if ($reason -cnotin @(
            'stale-pr-read-budget-exhausted',
            'stale-pr-deadline-exhausted')) {
        return $null
    }
    $diagnostic = [ordered]@{
        reason = $reason
        kind = 'unknown'
        readCount = $null
        readCeiling = $null
        responseBytes = $null
        responseByteCeiling = 16777216
        deadlineUtc = $null
    }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        foreach ($entry in @(
                @{ Data = 'stalePrBudgetKind'; Output = 'kind' }
                @{ Data = 'stalePrReadCount'; Output = 'readCount' }
                @{ Data = 'stalePrReadCeiling'; Output = 'readCeiling' }
                @{ Data = 'stalePrResponseBytes'; Output = 'responseBytes' }
                @{ Data = 'stalePrDeadlineUtc'; Output = 'deadlineUtc' }
            )) {
            if ($exception.Data.Contains($entry.Data)) {
                $diagnostic[$entry.Output] =
                    $exception.Data[$entry.Data]
            }
        }
        $exception = $exception.InnerException
    }
    if ($null -ne $Budget) {
        if ($null -eq $diagnostic.readCount -and
            $null -ne $Budget.PSObject.Properties['Count']) {
            $diagnostic.readCount = [int]$Budget.Count
        }
        if ($null -eq $diagnostic.readCeiling -and
            $null -ne $Budget.PSObject.Properties['Ceiling']) {
            $diagnostic.readCeiling = [int]$Budget.Ceiling
        }
        if ($null -eq $diagnostic.deadlineUtc -and
            $null -ne $Budget.PSObject.Properties['DeadlineUtc'] -and
            $Budget.DeadlineUtc -is [DateTime]) {
            $diagnostic.deadlineUtc = (
                [DateTime]$Budget.DeadlineUtc).ToString('o')
        }
        if ([string]$diagnostic.kind -ceq 'unknown') {
            if ($reason -ceq 'stale-pr-deadline-exhausted') {
                $diagnostic.kind = 'deadline'
            }
            elseif ($null -ne $diagnostic.readCount -and
                $null -ne $diagnostic.readCeiling -and
                [int]$diagnostic.readCount -ge
                    [int]$diagnostic.readCeiling) {
                $diagnostic.kind = 'read-count'
            }
        }
    }
    return $diagnostic
}

function Get-StalePrWriteDiagnostic {
    param(
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )
    $kind = 'provider-write-failed'
    $httpStatus = $null
    $serverErrorCode = $null
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.Data.Contains('stalePrFailureKind')) {
            $candidate = [string]$exception.Data[
                'stalePrFailureKind']
            if ($candidate -cin @(
                    'http-request-failed',
                    'provider-write-failed')) {
                $kind = $candidate
            }
        }

        if ($exception.Data.Contains('stalePrHttpStatus')) {
            $candidateStatus = 0
            if ([int]::TryParse(
                    [string]$exception.Data[
                        'stalePrHttpStatus'],
                    [ref]$candidateStatus)) {
                $httpStatus = $candidateStatus
            }
        }
        if ($exception.Data.Contains('stalePrServerErrorCode')) {
            $candidateCode = [string]$exception.Data[
                'stalePrServerErrorCode']
            if ($candidateCode -cin @(
                    'GitPullRequestNotFoundException',
                    'InvalidArgumentValueException',
                    'UnauthorizedRequestException')) {
                $serverErrorCode = $candidateCode
            }
        }
        $exception = $exception.InnerException
    }
    return [ordered]@{
        kind = $kind
        httpStatus = $httpStatus
        serverErrorCode = $serverErrorCode
    }
}

function Get-StalePrAzureCliLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$AzureCliPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $commands = @(Get-Command $AzureCliPath `
        -CommandType Application -ErrorAction Stop)
    if ($commands.Count -ne 1) {
        throw 'stale-pr-token-command-invalid'
    }
    $tool = Get-Item -LiteralPath $commands[0].Source -Force
    if ($tool.Attributes -band
            [IO.FileAttributes]::ReparsePoint -or
        $tool.Name -cne 'az.cmd' -or
        $tool.Length -gt 4096) {
        throw 'stale-pr-token-command-invalid'
    }
    $lines = @(Get-Content -LiteralPath $tool.FullName |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object {
            $_ -and -not $_.StartsWith('::')
        })
    $expected = @(
        '@IF EXIST "%~dp0\..\python.exe" (',
        'SET AZ_INSTALLER=MSI',
        '"%~dp0\..\python.exe" -IBm azure.cli %*',
        ') ELSE (',
        'echo Failed to load python executable.',
        'exit /b 1',
        ')'
    )
    if ($lines.Count -ne $expected.Count) {
        throw 'stale-pr-token-command-invalid'
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($lines[$index] -cne $expected[$index]) {
            throw 'stale-pr-token-command-invalid'
        }
    }
    $python = Join-Path (
        Split-Path -Parent (
            Split-Path -Parent $tool.FullName)
    ) 'python.exe'
    $pythonItem = Get-Item -LiteralPath $python -Force `
        -ErrorAction SilentlyContinue
    if ($null -eq $pythonItem -or
        $pythonItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
        throw 'stale-pr-token-command-invalid'
    }
    return [ordered]@{
        fileName = $pythonItem.FullName
        argumentList = [string[]]@(
            '-X', 'utf8', '-I', '-B', '-m', 'azure.cli'
        ) + $Arguments
    }
}

function Invoke-StalePrTokenProcess {
    param(
        [Parameter(Mandatory)][string]$AzureCliPath,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc
    )
    $stopTree = {
        param([int]$RootProcessId)
        $processes = @(Get-CimInstance `
            -ClassName Win32_Process `
            -ErrorAction SilentlyContinue)
        $children = @{}
        foreach ($item in $processes) {
            $parent = [int]$item.ParentProcessId
            if (-not $children.ContainsKey($parent)) {
                $children[$parent] =
                    [Collections.Generic.List[int]]::new()
            }
            [void]$children[$parent].Add(
                [int]$item.ProcessId)
        }
        $discovered =
            [Collections.Generic.HashSet[int]]::new()
        [void]$discovered.Add($RootProcessId)
        $ordered =
            [Collections.Generic.List[int]]::new()
        [void]$ordered.Add($RootProcessId)
        for ($index = 0;
            $index -lt $ordered.Count;
            $index++) {
            $parentId = $ordered[$index]
            if ($children.ContainsKey($parentId)) {
                foreach ($childId in $children[$parentId]) {
                    if ($discovered.Add($childId)) {
                        [void]$ordered.Add($childId)
                    }
                }
            }
        }
        for ($index = $ordered.Count - 1;
            $index -ge 0;
            $index--) {
            Stop-Process -Id $ordered[$index] -Force `
                -ErrorAction SilentlyContinue
        }
    }.GetNewClosure()
    $arguments = @(
        'account', 'get-access-token',
        '--resource',
        '499b84ac-1321-427f-aa17-267ca6975798',
        '--only-show-errors',
        '-o', 'json'
    )
    $plan = Get-StalePrAzureCliLaunchPlan `
        -AzureCliPath $AzureCliPath `
        -Arguments $arguments
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [string]$plan.fileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    [void]$start.Environment.Remove('AZURE_DEVOPS_EXT_PAT')
    [void]$start.Environment.Remove('SYSTEM_ACCESSTOKEN')
    $start.Environment['AZ_INSTALLER'] = 'MSI'
    foreach ($argument in $plan.argumentList) {
        [void]$start.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $output = [IO.MemoryStream]::new()
    $error = [IO.MemoryStream]::new()
    $processId = 0
    try {
        if (-not $process.Start()) {
            throw 'stale-pr-token-unavailable'
        }
        $processId = $process.Id
        $outputBuffer = [byte[]]::new(8192)
        $errorBuffer = [byte[]]::new(4096)
        $outputRead =
            $process.StandardOutput.BaseStream.ReadAsync(
                $outputBuffer, 0, $outputBuffer.Length)
        $errorRead =
            $process.StandardError.BaseStream.ReadAsync(
                $errorBuffer, 0, $errorBuffer.Length)
        while ($null -ne $outputRead -or
            $null -ne $errorRead) {
            if ([DateTime]::UtcNow -ge $DeadlineUtc) {
                & $stopTree `
                    -RootProcessId $processId
                throw 'stale-pr-deadline-exhausted'
            }
            $pending =
                [Collections.Generic.List[Threading.Tasks.Task]]::new()
            if ($null -ne $outputRead) {
                [void]$pending.Add($outputRead)
            }
            if ($null -ne $errorRead) {
                [void]$pending.Add($errorRead)
            }
            $remaining = [int][Math]::Floor(
                ($DeadlineUtc - [DateTime]::UtcNow).
                    TotalMilliseconds)
            if ($remaining -le 0) {
                & $stopTree `
                    -RootProcessId $processId
                throw 'stale-pr-deadline-exhausted'
            }
            $next = [Threading.Tasks.Task]::WhenAny(
                $pending.ToArray())
            if (-not $next.Wait($remaining)) {
                & $stopTree `
                    -RootProcessId $processId
                throw 'stale-pr-deadline-exhausted'
            }
            $completed = $next.GetAwaiter().GetResult()
            if ([object]::ReferenceEquals(
                    $completed, $outputRead)) {
                $count = $outputRead.GetAwaiter().GetResult()
                if ($count -eq 0) {
                    $outputRead = $null
                }
                else {
                    if ($output.Length + $count -gt 1048576) {
                        & $stopTree `
                            -RootProcessId $processId
                        throw 'stale-pr-token-response-too-large'
                    }
                    $output.Write($outputBuffer, 0, $count)
                    $outputRead =
                        $process.StandardOutput.BaseStream.ReadAsync(
                            $outputBuffer, 0, $outputBuffer.Length)
                }
            }
            else {
                $count = $errorRead.GetAwaiter().GetResult()
                if ($count -eq 0) {
                    $errorRead = $null
                }
                else {
                    if ($error.Length + $count -gt 65536) {
                        & $stopTree `
                            -RootProcessId $processId
                        throw 'stale-pr-token-response-too-large'
                    }
                    $error.Write($errorBuffer, 0, $count)
                    $errorRead =
                        $process.StandardError.BaseStream.ReadAsync(
                            $errorBuffer, 0, $errorBuffer.Length)
                }
            }
        }
        $remaining = [int][Math]::Floor(
            ($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remaining -le 0 -or
            -not $process.WaitForExit($remaining)) {
            & $stopTree `
                -RootProcessId $processId
            throw 'stale-pr-deadline-exhausted'
        }
        if ($process.ExitCode -ne 0) {
            throw 'stale-pr-token-unavailable'
        }
        $text = [Text.UTF8Encoding]::new(
            $false, $true).GetString(
                $output.ToArray())
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw 'stale-pr-token-unavailable'
        }
        return $text |
            ConvertFrom-Json -AsHashtable -Depth 16
    }
    finally {
        $output.Dispose()
        $error.Dispose()
        $process.Dispose()
    }
}

function Invoke-StalePrTokenInvokerBounded {
    param(
        [Parameter(Mandatory)][scriptblock]$TokenInvoker,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )
    $powershell = [PowerShell]::Create()
    try {
        $runner = @'
param($CallbackText, $Deadline, $Timeout)
$callback = [scriptblock]::Create($CallbackText)
& $callback $Deadline $Timeout
'@
        [void]$powershell.AddScript($runner).
            AddArgument($TokenInvoker.ToString()).
            AddArgument($DeadlineUtc).
            AddArgument($TimeoutMilliseconds)
        $async = $powershell.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne(
                $TimeoutMilliseconds)) {
            $powershell.Stop()
            throw 'stale-pr-deadline-exhausted'
        }
        $output = @($powershell.EndInvoke($async))
        if ($powershell.HadErrors) {
            throw 'stale-pr-token-unavailable'
        }
        if ($output.Count -ne 1) {
            throw 'stale-pr-token-unavailable'
        }
        return $output[0]
    }
    finally {
        $powershell.Dispose()
    }
}


function Get-StalePrLifecycleConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Config
    )
    $name = 'stalePullRequestLifecycle'
    if (-not $Config.Contains($name) -or
        $Config[$name] -is [bool] -and
        -not [bool]$Config[$name]) {
        return [pscustomobject][ordered]@{
            Enabled = $false
            DeliveryRoot = ''
            PolicyPath = ''
            PolicySha256 = ''
        }
    }
    $value = $Config[$name]
    if ($value -is [bool] -or
        $value -isnot [Collections.IDictionary]) {
        throw "$name requires an exact signed policy binding."
    }
    Assert-ApprovedOwnerV2ExactKeys -Value $value -Name $name -Expected @(
        'enabled', 'deliveryRoot', 'policyPath', 'policySha256'
    )
    if ($value.enabled -isnot [bool] -or
        -not [bool]$value.enabled -or
        -not [IO.Path]::IsPathFullyQualified(
            [string]$value.deliveryRoot) -or
        -not [IO.Path]::IsPathFullyQualified(
            [string]$value.policyPath) -or
        [string]$value.policySha256 -cnotmatch
            '^[0-9a-f]{64}$') {
        throw "$name binding is invalid."
    }
    return [pscustomobject][ordered]@{
        Enabled = $true
        DeliveryRoot =
            [IO.Path]::GetFullPath([string]$value.deliveryRoot)
        PolicyPath =
            [IO.Path]::GetFullPath([string]$value.policyPath)
        PolicySha256 = [string]$value.policySha256
    }
}

function Initialize-StalePrLifecycleRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DeliveryRoot,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $base = Resolve-AgentTrustedRoot -Path $DeliveryRoot `
        -Kind durable-state -RepositoryRoot $RepoRoot -Create
    $root = Resolve-AgentTrustedRoot `
        -Path (Join-Path $base $script:RootName) `
        -Kind durable-state -RepositoryRoot $RepoRoot -Create
    foreach ($leaf in @(
            'keys', 'policies', 'intents', 'outcomes', 'events', 'locks'
        )) {
        $path = Join-Path $root $leaf
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path | Out-Null
        }
    }
    $keyPath = Join-Path $root "keys\$script:KeyName"
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        [IO.File]::WriteAllBytes($keyPath, $bytes)
    }
    [void](Assert-AgentTrustedFile `
        -Path $keyPath -AllowedRoot $root -Private)
    return [pscustomobject][ordered]@{
        Root = $root
        KeyPath = $keyPath
    }
}

function Get-StalePrLifecycleKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LifecycleRoot)
    $path = Join-Path $LifecycleRoot "keys\$script:KeyName"
    [void](Assert-AgentTrustedFile `
        -Path $path -AllowedRoot $LifecycleRoot -Private)
    $key = [IO.File]::ReadAllBytes($path)
    if ($key.Length -ne 32) {
        throw 'Stale PR lifecycle key must be exactly 32 bytes.'
    }
    return $key
}

function Get-StalePrImplementation {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$GitPath,
        [switch]$AllowDirty
    )
    $head = (& $GitPath --no-optional-locks -C $RepoRoot `
        rev-parse HEAD 2>$null).Trim()
    $tree = (& $GitPath --no-optional-locks -C $RepoRoot `
        show -s --format=%T HEAD 2>$null).Trim()
    if ($head -cnotmatch '^[0-9a-f]{40}$' -or
        $tree -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Stale PR lifecycle toolkit revision is unavailable.'
    }
    $status = @(& $GitPath --no-optional-locks -C $RepoRoot `
        status --porcelain=v1 2>$null)
    if (-not $AllowDirty -and
        @($status | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }).Count -ne 0) {
        throw 'Stale PR lifecycle policy requires a clean toolkit checkout.'
    }
    $files = [ordered]@{
        lifecycleModuleSha256 = Join-Path $RepoRoot `
            'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psm1'
        lifecycleManifestSha256 = Join-Path $RepoRoot `
            'src\DevPilot.PullRequestLifecycle\DevPilot.PullRequestLifecycle.psd1'
        activePrIntakeSha256 = Join-Path $RepoRoot `
            'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psm1'
        sharedAcquisitionToolSha256 = Join-Path $RepoRoot `
            'tools\Invoke-SharedReviewAcquisition.ps1'
        authorizationToolSha256 = Join-Path $RepoRoot `
            'tools\Invoke-StalePrLifecycleAuthorization.ps1'
    }
    $result = [ordered]@{
        toolkitHead = $head
        toolkitTree = $tree
    }
    foreach ($entry in $files.GetEnumerator()) {
        $result[[string]$entry.Key] =
            Get-ApprovedOwnerV2FileSha256 $entry.Value
    }
    return $result
}

function New-StalePrLifecyclePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$GitPath = 'git',
        [ValidatePattern('^[a-z0-9][a-z0-9_.-]{2,63}$')]
        [string]$PolicyId = 'azureux-bpm-stale-pr-lifecycle-v1',
        [ValidateRange(1, 1)][int]$MaxAbandonsPerRun = 1,
        [switch]$EnableAbandonmentExplanation,
        [Parameter(DontShow)][switch]$AllowDirty,
        [string]$CreatedUtc =
            ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
    )
    $policy = [ordered]@{
        schemaVersion = 1
        kind = $script:PolicyKind
        enabled = $true
        policyId = $PolicyId
        actor = [ordered]@{
            id = ([string]$Config.expectedAccount.id).ToLowerInvariant()
            descriptor = [string]$Config.expectedAccount.descriptor
            uniqueName =
                ([string]$Config.expectedAccount.uniqueName).ToLowerInvariant()
        }
        repository = [ordered]@{
            projectId = ([string]$Config.projectId).ToLowerInvariant()
            repositoryId =
                ([string]$Config.repositoryId).ToLowerInvariant()
        }
        scope = [ordered]@{
            status = 'active'
            drafts = $false
            targetRef = $script:TargetRef
        }
        threshold = [ordered]@{
            calendarYears = 1
            creationComparison = 'strictly-before'
            activityComparison = 'at-or-before'
        }
        activity = [ordered]@{
            sourcePushes = $true
            iterations = $true
            commentsRepliesEdits = $true
            everyActor = $true
            commitAuthoredOrCommitterDates = $false
            metadataEdits = $false
            votes = $false
            statuses = $false
            excludedSystemEvents = $false
        }
        authority = [ordered]@{
            action = 'status:abandoned'
            maxAbandonsPerRun = $MaxAbandonsPerRun
            maxCandidatesPerRun = 200
            deleteSourceBranch = $false
            merge = $false
            workItems = $false
            votes = $false
            labels = $false
            titleOrDescription = $false
            commentsOrThreads = $false
            notifications = $false
            modelAuthorization = $false
        }
        transition = [ordered]@{
            optimisticConcurrency = 'unavailable'
            checkedPrewriteReread = $true
            retryAmbiguousPatch = $false
            confirmedReadbackRequired = $true
        }
        implementation = Get-StalePrImplementation `
            -RepoRoot $RepoRoot -GitPath $GitPath `
            -AllowDirty:$AllowDirty
        createdUtc = $CreatedUtc
    }
    if ($EnableAbandonmentExplanation) {
        $policy.authority['abandonmentExplanation'] = [ordered]@{
            action = 'comment:create-after-confirmed-abandonment'
            template = 'stale-abandonment-explanation-v1'
            maxPerRun = 1
            maxPerTransition = 1
            exactReadbackRequired = $true
            retryAmbiguousPost = $false
        }
    }
    return $policy
}

function Test-StalePrExplanationAuthority {
    param([AllowNull()][Collections.IDictionary]$Policy)
    if ($null -eq $Policy -or
        -not $Policy.authority.Contains('abandonmentExplanation')) {
        return $false
    }
    $grant = $Policy.authority.abandonmentExplanation
    if ($grant -isnot [Collections.IDictionary]) {
        throw 'Stale PR explanation authority is invalid.'
    }
    Assert-ApprovedOwnerV2ExactKeys -Value $grant -Name explanation -Expected @(
        'action', 'template', 'maxPerRun', 'maxPerTransition',
        'exactReadbackRequired', 'retryAmbiguousPost'
    )
    if ([string]$grant.action -cne
            'comment:create-after-confirmed-abandonment' -or
        [string]$grant.template -cne 'stale-abandonment-explanation-v1' -or
        $grant.maxPerRun -is [bool] -or
        [string]$grant.maxPerRun -cne '1' -or
        $grant.maxPerTransition -is [bool] -or
        [string]$grant.maxPerTransition -cne '1' -or
        $grant.exactReadbackRequired -isnot [bool] -or
        -not $grant.exactReadbackRequired -or
        $grant.retryAmbiguousPost -isnot [bool] -or
        $grant.retryAmbiguousPost -or
        [int]$Policy.authority.maxAbandonsPerRun -ne 1 -or
        [bool]$Policy.authority.commentsOrThreads) {
        throw 'Stale PR explanation authority is invalid.'
    }
    return $true
}

function Write-StalePrLifecyclePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][byte[]]$Key
    )
    return Write-ApprovedOwnerV2SignedRecord `
        -Path $Path -Payload $Policy -Key $Key
}

function Read-StalePrLifecyclePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Key
    )
    return Read-ApprovedOwnerV2SignedRecord -Path $Path -Key $Key
}

function Assert-StalePrLifecyclePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Policy,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$GitPath = 'git'
    )
    if ([int]$Policy.schemaVersion -ne 1 -or
        [string]$Policy.kind -cne $script:PolicyKind -or
        $Policy.enabled -isnot [bool] -or
        -not [bool]$Policy.enabled -or
        [string]$Policy.repository.projectId -ine
            [string]$Config.projectId -or
        [string]$Policy.repository.repositoryId -ine
            [string]$Config.repositoryId -or
        [string]$Policy.actor.id -ine
            [string]$Config.expectedAccount.id -or
        [string]$Policy.actor.descriptor -cne
            [string]$Config.expectedAccount.descriptor -or
        [string]$Policy.actor.uniqueName -ine
            [string]$Config.expectedAccount.uniqueName -or
        [string]$Policy.scope.status -cne 'active' -or
        [bool]$Policy.scope.drafts -or
        [string]$Policy.scope.targetRef -cne $script:TargetRef -or
        [int]$Policy.threshold.calendarYears -ne 1 -or
        [string]$Policy.threshold.creationComparison -cne
            'strictly-before' -or
        [string]$Policy.threshold.activityComparison -cne
            'at-or-before' -or
        -not [bool]$Policy.activity.sourcePushes -or
        -not [bool]$Policy.activity.iterations -or
        -not [bool]$Policy.activity.commentsRepliesEdits -or
        -not [bool]$Policy.activity.everyActor -or
        [bool]$Policy.activity.commitAuthoredOrCommitterDates -or
        [bool]$Policy.activity.metadataEdits -or
        [bool]$Policy.activity.votes -or
        [bool]$Policy.activity.statuses -or
        [bool]$Policy.activity.excludedSystemEvents -or
        [string]$Policy.authority.action -cne
            'status:abandoned' -or
        [int]$Policy.authority.maxAbandonsPerRun -lt 1 -or
        [int]$Policy.authority.maxAbandonsPerRun -gt 2 -or
        [int]$Policy.authority.maxCandidatesPerRun -lt 1 -or
        [int]$Policy.authority.maxCandidatesPerRun -gt 200 -or
        @(
            'deleteSourceBranch', 'merge', 'workItems', 'votes',
            'labels', 'titleOrDescription', 'commentsOrThreads',
            'notifications', 'modelAuthorization'
        | Where-Object { [bool]$Policy.authority[$_] }).Count -ne 0 -or
        [string]$Policy.transition.optimisticConcurrency -cne
            'unavailable' -or
        -not [bool]$Policy.transition.checkedPrewriteReread -or
        [bool]$Policy.transition.retryAmbiguousPatch -or
        -not [bool]$Policy.transition.confirmedReadbackRequired) {
        throw 'Stale PR lifecycle policy is invalid.'
    }
    if ((Get-StalePrDigest $Policy.implementation) -cne
        (Get-StalePrDigest (
            Get-StalePrImplementation `
                -RepoRoot $RepoRoot -GitPath $GitPath))) {
        throw 'Stale PR lifecycle implementation binding changed.'
    }
    [void](Test-StalePrExplanationAuthority $Policy)
}

function Get-StalePrEvidenceBinding {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Evidence
    )
    return [ordered]@{
        projectId = [string]$Evidence.projectId
        repositoryId = [string]$Evidence.repositoryId
        pullRequestId = [long]$Evidence.pullRequestId
        status = [string]$Evidence.status
        isDraft = [bool]$Evidence.isDraft
        sourceRef = [string]$Evidence.sourceRef
        targetRef = [string]$Evidence.targetRef
        sourceCommit = [string]$Evidence.sourceCommit
        targetCommit = [string]$Evidence.targetCommit
        iterationId = [int]$Evidence.iterationId
        creationUtc = (
            ConvertTo-StalePrUtc `
                -Value ([string]$Evidence.creationUtc) `
                -Name creationUtc).
            ToString('yyyyMMddTHHmmssfffffffZ')
        latestActivityUtc = (
            ConvertTo-StalePrUtc `
                -Value ([string]$Evidence.latestActivityUtc) `
                -Name latestActivityUtc).
            ToString('yyyyMMddTHHmmssfffffffZ')
        activityDigest = [string]$Evidence.activityDigest
    }
}

function Assert-StalePrEvidence {
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Evidence,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Policy
    )
    if ([string]$Evidence.projectId -ine
            [string]$Policy.repository.projectId -or
        [string]$Evidence.repositoryId -ine
            [string]$Policy.repository.repositoryId -or
        [long]$Evidence.pullRequestId -lt 1 -or
        [string]$Evidence.status -cnotin @(
            'active', 'abandoned', 'completed') -or
        $Evidence.isDraft -isnot [bool] -or
        [string]$Evidence.sourceRef -cnotmatch '^refs/heads/.+' -or
        [string]$Evidence.targetRef -cnotmatch '^refs/heads/.+' -or
        [string]$Evidence.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$Evidence.targetCommit -cnotmatch '^[0-9a-f]{40}$' -or
        [int]$Evidence.iterationId -lt 0 -or
        [string]$Evidence.activityDigest -cnotmatch
            '^v1:sha256:[0-9a-f]{64}$' -or
        $Evidence.complete -isnot [bool]) {
        throw 'Stale PR lifecycle evidence is malformed.'
    }
    [void](ConvertTo-StalePrUtc `
        -Value ([string]$Evidence.creationUtc) -Name creationUtc)
    [void](ConvertTo-StalePrUtc `
        -Value ([string]$Evidence.latestActivityUtc) `
        -Name latestActivityUtc)
}

function Write-StalePrSignedRecord {
    param(
        [Parameter(Mandatory)][string]$LifecycleRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Payload,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $path = Join-Path $LifecycleRoot $RelativePath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    [void](Write-ApprovedOwnerV2SignedRecord `
        -Path $path -Payload $Payload -Key $Key)
    return $path
}

function Read-StalePrCachedPushDate {
    param(
        [AllowNull()][string]$LifecycleRoot,
        [AllowNull()][byte[]]$Key,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)][int]$IterationId,
        [Parameter(Mandatory)][long]$PushId,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit,
        [AllowNull()][Nullable[DateTime]]$DeadlineUtc = $null,
        [AllowNull()][scriptblock]$UtcNowProvider = $null
    )
    if ([string]::IsNullOrWhiteSpace($LifecycleRoot) -or
        $null -eq $Key -or $Key.Length -ne 32 -or
        -not (Test-StalePrSafeId $ProjectId) -or
        -not (Test-StalePrSafeId $RepositoryId) -or
        $PullRequestId -lt 1 -or $IterationId -lt 1 -or $PushId -lt 1 -or
        $SourceCommit -cnotmatch '^[0-9a-fA-F]{40}$' -or
        $TargetCommit -cnotmatch '^[0-9a-fA-F]{40}$') {
        return $null
    }
    $getNow = if ($null -ne $UtcNowProvider) {
        $UtcNowProvider
    }
    else {
        { [DateTime]::UtcNow }
    }
    if ($null -ne $DeadlineUtc -and
        (& $getNow) -ge [DateTime]$DeadlineUtc) {
        throw 'stale-pr-deadline-exhausted'
    }
    $pushRoot = Join-Path $LifecycleRoot ("pushes\$PullRequestId")
    if (-not (Test-AgentPathWithin -Root $LifecycleRoot -Path $pushRoot)) {
        return $null
    }
    $path = Join-Path $pushRoot ("push-$PushId-iter-$IterationId.json")
    if (-not (Test-AgentPathWithin -Root $pushRoot -Path $path) -or
        (Test-Path -LiteralPath $path -PathType Container) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $itemInfo = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($itemInfo.PSIsContainer -or
            [long]$itemInfo.Length -lt 1L -or
            [long]$itemInfo.Length -gt $script:MaxCacheRecordBytes) {
            return $null
        }
        $record = Read-StalePrLifecyclePolicy -Path $path -Key $Key
        Assert-ApprovedOwnerV2ExactKeys -Value $record `
            -Name pushDateRecord -Expected @(
                'schemaVersion', 'kind', 'projectId', 'repositoryId',
                'pullRequestId', 'iterationId', 'pushId',
                'sourceCommit', 'targetCommit', 'occurredUtc'
            )
        if (-not (Test-StalePrNonBoolInteger `
                -Value $record.schemaVersion -Minimum 1 -Maximum 1) -or
            [string]$record.kind -cne 'stale-pr-push-date-v1' -or
            -not (Test-StalePrSafeId ([string]$record.projectId)) -or
            -not (Test-StalePrSafeId ([string]$record.repositoryId)) -or
            [string]$record.projectId -ine $ProjectId -or
            [string]$record.repositoryId -ine $RepositoryId -or
            -not (Test-StalePrNonBoolInteger `
                -Value $record.pullRequestId `
                -Minimum 1 -Maximum ([long]::MaxValue)) -or
            [long]$record.pullRequestId -ne $PullRequestId -or
            -not (Test-StalePrNonBoolInteger `
                -Value $record.iterationId -Minimum 1) -or
            [int]$record.iterationId -ne $IterationId -or
            -not (Test-StalePrNonBoolInteger `
                -Value $record.pushId `
                -Minimum 1 -Maximum ([long]::MaxValue)) -or
            [long]$record.pushId -ne $PushId -or
            [string]$record.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
            [string]$record.targetCommit -cnotmatch '^[0-9a-f]{40}$' -or
            [string]$record.sourceCommit -ine $SourceCommit -or
            [string]$record.targetCommit -ine $TargetCommit) {
            return $null
        }
        $occurredUtc = ConvertTo-StalePrUtc `
            -Value ([string]$record.occurredUtc) -Name occurredUtc
        return $occurredUtc.ToString('o')
    }
    catch {
        return $null
    }
}

function Write-StalePrCachedPushDate {
    param(
        [AllowNull()][string]$LifecycleRoot,
        [AllowNull()][byte[]]$Key,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)][int]$IterationId,
        [Parameter(Mandatory)][long]$PushId,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit,
        [Parameter(Mandatory)][string]$OccurredUtc,
        [AllowNull()][Nullable[DateTime]]$DeadlineUtc = $null,
        [AllowNull()][scriptblock]$UtcNowProvider = $null
    )
    if ([string]::IsNullOrWhiteSpace($LifecycleRoot) -or
        $null -eq $Key -or $Key.Length -ne 32) {
        return
    }
    $getNow = if ($null -ne $UtcNowProvider) {
        $UtcNowProvider
    }
    else {
        { [DateTime]::UtcNow }
    }
    if ($null -ne $DeadlineUtc -and
        (& $getNow) -ge [DateTime]$DeadlineUtc) {
        throw 'stale-pr-deadline-exhausted'
    }
    if (-not (Test-StalePrSafeId $ProjectId) -or
        -not (Test-StalePrSafeId $RepositoryId) -or
        $PullRequestId -lt 1 -or $IterationId -lt 1 -or $PushId -lt 1 -or
        $SourceCommit -cnotmatch '^[0-9a-fA-F]{40}$' -or
        $TargetCommit -cnotmatch '^[0-9a-fA-F]{40}$') {
        throw 'stale-pr-push-cache-write-failed'
    }
    $pushRoot = Join-Path $LifecycleRoot ("pushes\$PullRequestId")
    if (-not (Test-AgentPathWithin -Root $LifecycleRoot -Path $pushRoot)) {
        throw 'stale-pr-push-cache-write-failed'
    }
    $relativePath = (
        "pushes\$PullRequestId\push-$PushId-iter-$IterationId.json")
    $path = Join-Path $LifecycleRoot $relativePath
    if (-not (Test-AgentPathWithin -Root $pushRoot -Path $path)) {
        throw 'stale-pr-push-cache-write-failed'
    }
    if (Test-Path -LiteralPath $pushRoot -PathType Leaf) {
        throw 'stale-pr-push-cache-write-failed'
    }
    if (Test-Path -LiteralPath $path -PathType Container) {
        throw 'stale-pr-push-cache-write-failed'
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existingUtc = Read-StalePrCachedPushDate `
            -LifecycleRoot $LifecycleRoot `
            -Key $Key `
            -ProjectId $ProjectId `
            -RepositoryId $RepositoryId `
            -PullRequestId $PullRequestId `
            -IterationId $IterationId `
            -PushId $PushId `
            -SourceCommit $SourceCommit `
            -TargetCommit $TargetCommit `
            -DeadlineUtc $DeadlineUtc `
            -UtcNowProvider $UtcNowProvider
        if ([string]::IsNullOrWhiteSpace($existingUtc)) {
            throw 'stale-pr-push-cache-write-failed'
        }
        $expectedUtc = (ConvertTo-StalePrUtc `
            -Value $OccurredUtc -Name occurredUtc).ToString('o')
        if ($existingUtc -cne $expectedUtc) {
            throw 'stale-pr-push-cache-write-failed'
        }
        return
    }
    try {
        if (Test-Path -LiteralPath $pushRoot -PathType Container) {
            $entryCount = 0
            $totalBytes = 0L
            $enumOptions = [IO.EnumerationOptions]::new()
            $enumOptions.RecurseSubdirectories = $false
            $enumOptions.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
            foreach ($entryPath in [IO.Directory]::EnumerateFileSystemEntries($pushRoot, '*', $enumOptions)) {
                if ($null -ne $DeadlineUtc -and
                    (& $getNow) -ge [DateTime]$DeadlineUtc) {
                    throw 'stale-pr-deadline-exhausted'
                }
                $entryCount++
                if ($entryCount -ge $script:MaxCachedPushFilesPerPr) {
                    throw 'stale-pr-push-cache-write-failed'
                }
                if (-not (Test-AgentPathWithin -Root $pushRoot -Path $entryPath) -or
                    (Test-Path -LiteralPath $entryPath -PathType Container)) {
                    throw 'stale-pr-push-cache-write-failed'
                }
                $entryInfo = [IO.FileInfo]::new($entryPath)
                if (-not $entryInfo.Exists -or
                    (($entryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
                    $entryInfo.Name -cnotmatch '^push-[0-9]+-iter-[0-9]+\.json$' -or
                    [long]$entryInfo.Length -lt 1L -or
                    [long]$entryInfo.Length -gt $script:MaxCacheRecordBytes) {
                    throw 'stale-pr-push-cache-write-failed'
                }
                $totalBytes += [long]$entryInfo.Length
                if ($totalBytes -gt $script:MaxCachedPushTotalBytesPerPr) {
                    throw 'stale-pr-push-cache-write-failed'
                }
            }
        }
        $normalizedUtc = (ConvertTo-StalePrUtc `
            -Value $OccurredUtc -Name occurredUtc).
            ToString('yyyyMMddTHHmmssfffffffZ')
        $payload = [ordered]@{
            schemaVersion = 1
            kind = 'stale-pr-push-date-v1'
            projectId = $ProjectId.ToLowerInvariant()
            repositoryId = $RepositoryId.ToLowerInvariant()
            pullRequestId = [long]$PullRequestId
            iterationId = [int]$IterationId
            pushId = [long]$PushId
            sourceCommit = $SourceCommit.ToLowerInvariant()
            targetCommit = $TargetCommit.ToLowerInvariant()
            occurredUtc = $normalizedUtc
        }
        [void](Write-StalePrSignedRecord `
            -LifecycleRoot $LifecycleRoot `
            -RelativePath $relativePath `
            -Payload $payload `
            -Key $Key)
    }
    catch {
        if ($_.Exception.Message -ceq 'stale-pr-deadline-exhausted') {
            throw
        }
        throw 'stale-pr-push-cache-write-failed'
    }
}

function Get-StalePrActivityProofState {
    param(
        [AllowNull()][string]$LifecycleRoot,
        [Parameter(Mandatory)][long]$PullRequestId,
        [AllowNull()][byte[]]$Key,
        [AllowNull()][Nullable[DateTime]]$DeadlineUtc = $null,
        [AllowNull()][scriptblock]$UtcNowProvider = $null
    )
    if ([string]::IsNullOrWhiteSpace($LifecycleRoot) -or
        $null -eq $Key -or $Key.Length -ne 32 -or
        $PullRequestId -lt 1) {
        return [ordered]@{
            valid = $false
            maxSequence = 0L
            latest = $null
        }
    }
    $getNow = if ($null -ne $UtcNowProvider) {
        $UtcNowProvider
    }
    else {
        { [DateTime]::UtcNow }
    }
    if ($null -ne $DeadlineUtc -and
        (& $getNow) -ge [DateTime]$DeadlineUtc) {
        throw 'stale-pr-deadline-exhausted'
    }
    $proofRoot = Join-Path $LifecycleRoot (
        "activity-proofs\$PullRequestId")
    if (-not (Test-AgentPathWithin -Root $LifecycleRoot -Path $proofRoot)) {
        return [ordered]@{
            valid = $false
            maxSequence = 0L
            latest = $null
        }
    }
    if (Test-Path -LiteralPath $proofRoot -PathType Leaf) {
        return [ordered]@{
            valid = $false
            maxSequence = 0L
            latest = $null
        }
    }
    if (-not (Test-Path -LiteralPath $proofRoot -PathType Container)) {
        return [ordered]@{
            valid = $true
            maxSequence = 0L
            latest = $null
        }
    }
    $boundedEntries = [Collections.Generic.List[object]]::new()
    try {
        $enumOptions = [IO.EnumerationOptions]::new()
        $enumOptions.RecurseSubdirectories = $false
        $enumOptions.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
        foreach ($entryPath in [IO.Directory]::EnumerateFileSystemEntries($proofRoot, '*', $enumOptions)) {
            if ($null -ne $DeadlineUtc -and
                (& $getNow) -ge [DateTime]$DeadlineUtc) {
                throw 'stale-pr-deadline-exhausted'
            }
            if (-not (Test-AgentPathWithin -Root $proofRoot -Path $entryPath) -or
                (Test-Path -LiteralPath $entryPath -PathType Container)) {
                return [ordered]@{
                    valid = $false
                    maxSequence = 0L
                    latest = $null
                }
            }
            $entryInfo = [IO.FileInfo]::new($entryPath)
            if (-not $entryInfo.Exists -or
                (($entryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                return [ordered]@{
                    valid = $false
                    maxSequence = 0L
                    latest = $null
                }
            }
            [void]$boundedEntries.Add($entryInfo)
            if ($boundedEntries.Count -gt $script:MaxActivityProofHistoryEntriesPerPr) {
                return [ordered]@{
                    valid = $false
                    maxSequence = 0L
                    latest = $null
                }
            }
        }
    }
    catch {
        if ($_.Exception.Message -ceq 'stale-pr-deadline-exhausted') {
            throw
        }
        return [ordered]@{
            valid = $false
            maxSequence = 0L
            latest = $null
        }
    }
    if ($boundedEntries.Count -eq 0) {
        return [ordered]@{
            valid = $true
            maxSequence = 0L
            latest = $null
        }
    }
    $entries = @($boundedEntries | Sort-Object Name)
    $records = [Collections.Generic.List[object]]::new()
    $totalBytes = 0L
    foreach ($entry in $entries) {
        if ($null -ne $DeadlineUtc -and
            (& $getNow) -ge [DateTime]$DeadlineUtc) {
            throw 'stale-pr-deadline-exhausted'
        }
        if (-not (Test-AgentPathWithin -Root $proofRoot -Path $entry.FullName) -or
            $entry.Name -cnotmatch '^seq-(?<seq>[0-9]{8})-(?<suffix>[0-9a-f]{16}|withheld)\.json$' -or
            [long]$entry.Length -lt 1L -or
            [long]$entry.Length -gt $script:MaxCacheRecordBytes) {
            return [ordered]@{
                valid = $false
                maxSequence = 0L
                latest = $null
            }
        }
        $fileSequence = [long]$Matches['seq']
        $fileSuffix = [string]$Matches['suffix']
        $totalBytes += [long]$entry.Length
        if ($totalBytes -gt $script:MaxActivityProofTotalBytesPerPr) {
            return [ordered]@{
                valid = $false
                maxSequence = 0L
                latest = $null
            }
        }
        try {
            $record = Read-StalePrLifecyclePolicy `
                -Path $entry.FullName -Key $Key
            Assert-ApprovedOwnerV2ExactKeys -Value $record `
                -Name activityProof -Expected @(
                    'schemaVersion', 'kind', 'sequence',
                    'pullRequestId', 'state', 'policyDigest',
                    'evidenceDigest', 'subject'
                )
            if (-not (Test-StalePrNonBoolInteger `
                    -Value $record.schemaVersion -Minimum 1 -Maximum 1) -or
                [string]$record.kind -cne 'stale-pr-activity-proof-v1' -or
                -not (Test-StalePrNonBoolInteger `
                    -Value $record.sequence `
                    -Minimum 1 -Maximum $script:MaxActivityProofHistoryEntriesPerPr) -or
                ([long]$record.sequence -gt $script:MaxActivityProofFilesPerPr -and
                    [string]$record.state -cne 'withheld') -or
                [long]$record.sequence -ne $fileSequence -or
                -not (Test-StalePrNonBoolInteger `
                    -Value $record.pullRequestId `
                    -Minimum 1 -Maximum ([long]::MaxValue)) -or
                [long]$record.pullRequestId -ne $PullRequestId -or
                [string]$record.policyDigest -cnotmatch
                    '^v1:sha256:[0-9a-f]{64}$' -or
                [string]$record.evidenceDigest -cnotmatch
                    '^v1:sha256:[0-9a-f]{64}$' -or
                $record.subject -isnot [Collections.IDictionary] -or
                [string]$record.state -cnotin @(
                    'recent-activity', 'withheld')) {
                return [ordered]@{
                    valid = $false
                    maxSequence = 0L
                    latest = $null
                }
            }
            if ([string]$record.state -ceq 'withheld') {
                if ($fileSuffix -cne 'withheld') {
                    return [ordered]@{
                        valid = $false
                        maxSequence = 0L
                        latest = $null
                    }
                }
            }
            else {
                $expectedShortHash = ([string]$record.evidenceDigest).Substring(
                    'v1:sha256:'.Length, 16)
                if ($fileSuffix -cne $expectedShortHash) {
                    return [ordered]@{
                        valid = $false
                        maxSequence = 0L
                        latest = $null
                    }
                }
            }
            Assert-ApprovedOwnerV2ExactKeys -Value $record.subject `
                -Name activityProofSubject -Expected @(
                    'projectId', 'repositoryId', 'pullRequestId',
                    'status', 'isDraft', 'sourceRef', 'targetRef',
                    'sourceCommit', 'targetCommit', 'iterationId',
                    'creationUtc', 'latestActivityUtc', 'activityDigest'
                )
            if (-not (Test-StalePrSafeId ([string]$record.subject.projectId)) -or
                -not (Test-StalePrSafeId ([string]$record.subject.repositoryId)) -or
                -not (Test-StalePrNonBoolInteger `
                    -Value $record.subject.pullRequestId `
                    -Minimum 1 -Maximum ([long]::MaxValue)) -or
                [long]$record.subject.pullRequestId -ne $PullRequestId -or
                $record.subject.isDraft -isnot [bool] -or
                -not (Test-StalePrNonBoolInteger `
                    -Value $record.subject.iterationId -Minimum 1) -or
                [string]$record.subject.sourceCommit -cnotmatch
                    '^[0-9a-f]{40}$' -or
                [string]$record.subject.targetCommit -cnotmatch
                    '^[0-9a-f]{40}$' -or
                [string]$record.subject.activityDigest -cnotmatch
                    '^v1:sha256:[0-9a-f]{64}$') {
                return [ordered]@{
                    valid = $false
                    maxSequence = 0L
                    latest = $null
                }
            }
            $expectedBinding = Get-StalePrEvidenceBinding $record.subject
            if ((Get-StalePrDigest $expectedBinding) -cne
                [string]$record.evidenceDigest) {
                return [ordered]@{
                    valid = $false
                    maxSequence = 0L
                    latest = $null
                }
            }
            [void]$records.Add($record)
        }
        catch {
            return [ordered]@{
                valid = $false
                maxSequence = 0L
                latest = $null
            }
        }
    }
    $ordered = @($records | Sort-Object { [long]$_.sequence })
    for ($idx = 0; $idx -lt $ordered.Count; $idx++) {
        if ([long]$ordered[$idx].sequence -ne ($idx + 1)) {
            return [ordered]@{
                valid = $false
                maxSequence = 0L
                latest = $null
            }
        }
    }
    $latest = $ordered[-1]
    return [ordered]@{
        valid = $true
        maxSequence = [long]$latest.sequence
        latest = $latest
    }
}

function Get-StalePrCachedActivityProof {
    param(
        [AllowNull()][string]$LifecycleRoot,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][DateTime]$CutoffUtc,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][string]$PolicyDigest,
        [AllowNull()][byte[]]$Key,
        [AllowNull()][Nullable[DateTime]]$DeadlineUtc = $null,
        [AllowNull()][scriptblock]$UtcNowProvider = $null
    )
    if ($null -eq $Item -or $PullRequestId -lt 1) {
        return $null
    }
    $state = Get-StalePrActivityProofState `
        -LifecycleRoot $LifecycleRoot `
        -PullRequestId $PullRequestId `
        -Key $Key `
        -DeadlineUtc $DeadlineUtc `
        -UtcNowProvider $UtcNowProvider
    if (-not [bool]$state.valid -or $null -eq $state.latest) {
        return $null
    }
    $record = $state.latest
    if ([string]$record.state -cne 'recent-activity' -or
        [string]$record.policyDigest -cne $PolicyDigest -or
        $record.subject -isnot [Collections.IDictionary]) {
        return $null
    }
    try {
        $subject = [ordered]@{} + $record.subject
        $subject['complete'] = $true
        Assert-StalePrEvidence `
            -Evidence $subject -Policy $Policy
        $binding = Get-StalePrEvidenceBinding $subject
        $expectedDigest = Get-StalePrDigest $binding
        if ([string]$record.evidenceDigest -cne $expectedDigest) {
            return $null
        }
        if ([long]$subject.pullRequestId -ne $PullRequestId -or
            [string]$subject.status -cne 'active' -or
            [bool]$subject.isDraft -or
            [string]$subject.targetRef -cne
                [string]$Policy.scope.targetRef) {
            return $null
        }
        $itemDict = if ($Item -is [Collections.IDictionary]) {
            $Item
        }
        else { $null }
        $requiredFields = @(
            'projectId', 'repositoryId', 'pullRequestId',
            'status', 'isDraft', 'sourceRef', 'targetRef',
            'sourceCommit', 'targetCommit', 'iterationId',
            'creationUtc', 'latestActivityUtc', 'activityDigest'
        )
        $itemValues = @{}
        foreach ($fieldName in $requiredFields) {
            $hasProp = if ($null -ne $itemDict) {
                $itemDict.Contains($fieldName) -and
                    $null -ne $itemDict[$fieldName]
            }
            else {
                $null -ne $Item.PSObject.Properties[$fieldName] -and
                    $null -ne $Item.PSObject.Properties[$fieldName].Value
            }
            if (-not $hasProp) {
                return $null
            }
            $itemValues[$fieldName] = if ($null -ne $itemDict) {
                $itemDict[$fieldName]
            }
            else {
                $Item.PSObject.Properties[$fieldName].Value
            }
        }
        if (-not (Test-StalePrSafeId ([string]$itemValues['projectId'])) -or
            -not (Test-StalePrSafeId ([string]$itemValues['repositoryId'])) -or
            -not (Test-StalePrNonBoolInteger `
                -Value $itemValues['pullRequestId'] `
                -Minimum 1 -Maximum ([long]::MaxValue)) -or
            [long]$itemValues['pullRequestId'] -ne $PullRequestId -or
            $itemValues['isDraft'] -isnot [bool] -or
            [bool]$itemValues['isDraft'] -or
            [string]$itemValues['status'] -cne 'active' -or
            [string]$itemValues['targetRef'] -cne
                [string]$Policy.scope.targetRef -or
            [string]$itemValues['projectId'] -ine
                [string]$subject.projectId -or
            [string]$itemValues['repositoryId'] -ine
                [string]$subject.repositoryId -or
            [string]$itemValues['sourceRef'] -cne
                [string]$subject.sourceRef -or
            [string]$itemValues['sourceCommit'] -cnotmatch
                '^[0-9a-fA-F]{40}$' -or
            [string]$itemValues['targetCommit'] -cnotmatch
                '^[0-9a-fA-F]{40}$' -or
            [string]$itemValues['sourceCommit'] -ine
                [string]$subject.sourceCommit -or
            [string]$itemValues['targetCommit'] -ine
                [string]$subject.targetCommit -or
            -not (Test-StalePrNonBoolInteger `
                -Value $itemValues['iterationId'] -Minimum 1) -or
            [int]$itemValues['iterationId'] -ne
                [int]$subject.iterationId -or
            [string]$itemValues['activityDigest'] -cnotmatch
                '^v1:sha256:[0-9a-f]{64}$' -or
            [string]$itemValues['activityDigest'] -cne
                [string]$subject.activityDigest) {
            return $null
        }
        $subjectCreationUtc = ConvertTo-StalePrUtc `
            -Value ([string]$subject.creationUtc) `
            -Name creationUtc
        $itemCreationUtc = ConvertTo-StalePrUtc `
            -Value ([string]$itemValues['creationUtc']) `
            -Name creationUtc
        $subjectLatestActivityUtc = ConvertTo-StalePrUtc `
            -Value ([string]$subject.latestActivityUtc) `
            -Name latestActivityUtc
        $itemActivityUtc = ConvertTo-StalePrUtc `
            -Value ([string]$itemValues['latestActivityUtc']) `
            -Name latestActivityUtc
        if ($subjectCreationUtc -ne $itemCreationUtc -or
            $subjectCreationUtc -ge $CutoffUtc -or
            $subjectLatestActivityUtc -ne $itemActivityUtc -or
            $subjectLatestActivityUtc -le $CutoffUtc) {
            return $null
        }
        return $record
    }
    catch {
        return $null
    }
}

function Write-StalePrActivityProof {
    param(
        [AllowNull()][string]$LifecycleRoot,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Evidence,
        [Parameter(Mandatory)][string]$PolicyDigest,
        [AllowNull()][byte[]]$Key,
        [AllowNull()][Nullable[DateTime]]$DeadlineUtc = $null,
        [AllowNull()][scriptblock]$UtcNowProvider = $null
    )
    if ([string]::IsNullOrWhiteSpace($LifecycleRoot) -or
        $null -eq $Key -or $Key.Length -ne 32 -or
        $PullRequestId -lt 1 -or
        $PolicyDigest -cnotmatch '^v1:sha256:[0-9a-f]{64}$') {
        throw 'stale-pr-activity-proof-write-failed'
    }
    $state = Get-StalePrActivityProofState `
        -LifecycleRoot $LifecycleRoot `
        -PullRequestId $PullRequestId `
        -Key $Key `
        -DeadlineUtc $DeadlineUtc `
        -UtcNowProvider $UtcNowProvider
    if (-not [bool]$state.valid) {
        throw 'stale-pr-activity-proof-write-failed'
    }
    try {
        if (-not (Test-StalePrSafeId ([string]$Evidence.projectId)) -or
            -not (Test-StalePrSafeId ([string]$Evidence.repositoryId)) -or
            -not (Test-StalePrNonBoolInteger `
                -Value $Evidence.pullRequestId `
                -Minimum 1 -Maximum ([long]::MaxValue)) -or
            [long]$Evidence.pullRequestId -ne $PullRequestId -or
            [string]$Evidence.status -cne 'active' -or
            $Evidence.isDraft -isnot [bool] -or
            [bool]$Evidence.isDraft -or
            [string]$Evidence.sourceRef -cnotmatch '^refs/heads/.+' -or
            [string]$Evidence.sourceRef -ceq $script:TargetRef -or
            [string]$Evidence.targetRef -cne $script:TargetRef -or
            [string]$Evidence.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
            [string]$Evidence.targetCommit -cnotmatch '^[0-9a-f]{40}$' -or
            -not (Test-StalePrNonBoolInteger `
                -Value $Evidence.iterationId -Minimum 1) -or
            [string]$Evidence.activityDigest -cnotmatch
                '^v1:sha256:[0-9a-f]{64}$') {
            throw 'stale-pr-activity-proof-write-failed'
        }
        $binding = Get-StalePrEvidenceBinding $Evidence
        $evidenceDigest = Get-StalePrDigest $binding
        if ($null -ne $state.latest -and
            [string]$state.latest.state -ceq 'recent-activity' -and
            [string]$state.latest.policyDigest -ceq $PolicyDigest -and
            [string]$state.latest.evidenceDigest -ceq $evidenceDigest) {
            return
        }
        $nextSequence = [long]$state.maxSequence + 1L
        if ($nextSequence -gt $script:MaxActivityProofFilesPerPr) {
            if ([string]$state.latest.state -ceq 'recent-activity') {
                Disable-StalePrCachedActivityProof `
                    -LifecycleRoot $LifecycleRoot `
                    -PullRequestId $PullRequestId `
                    -PolicyDigest $PolicyDigest `
                    -Key $Key `
                    -DeadlineUtc $DeadlineUtc `
                    -UtcNowProvider $UtcNowProvider
            }
            return
        }
        $shortHash = $evidenceDigest.Substring(
            'v1:sha256:'.Length, 16)
        $payload = [ordered]@{
            schemaVersion = 1
            kind = 'stale-pr-activity-proof-v1'
            sequence = $nextSequence
            pullRequestId = [long]$PullRequestId
            state = 'recent-activity'
            policyDigest = $PolicyDigest
            evidenceDigest = $evidenceDigest
            subject = $binding
        }
        $relativePath = (
            "activity-proofs\$PullRequestId\" +
            "seq-$('{0:D8}' -f $nextSequence)-$shortHash.json")
        $fullPath = Join-Path $LifecycleRoot $relativePath
        $proofRoot = Join-Path $LifecycleRoot ("activity-proofs\$PullRequestId")
        if (-not (Test-AgentPathWithin -Root $LifecycleRoot -Path $proofRoot) -or
            -not (Test-AgentPathWithin -Root $proofRoot -Path $fullPath) -or
            (Test-Path -LiteralPath $fullPath)) {
            throw 'stale-pr-activity-proof-write-failed'
        }
        [void](Write-StalePrSignedRecord `
            -LifecycleRoot $LifecycleRoot `
            -RelativePath $relativePath `
            -Payload $payload `
            -Key $Key)
    }
    catch {
        if ($_.Exception.Message -ceq 'stale-pr-deadline-exhausted') {
            throw
        }
        throw 'stale-pr-activity-proof-write-failed'
    }
}

function Disable-StalePrCachedActivityProof {
    param(
        [AllowNull()][string]$LifecycleRoot,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)][string]$PolicyDigest,
        [AllowNull()][byte[]]$Key,
        [AllowNull()][Nullable[DateTime]]$DeadlineUtc = $null,
        [AllowNull()][scriptblock]$UtcNowProvider = $null
    )
    if ([string]::IsNullOrWhiteSpace($LifecycleRoot) -or
        $null -eq $Key -or $Key.Length -ne 32 -or
        $PullRequestId -lt 1 -or
        $PolicyDigest -cnotmatch '^v1:sha256:[0-9a-f]{64}$') {
        throw 'stale-pr-activity-proof-invalidation-failed'
    }
    $state = Get-StalePrActivityProofState `
        -LifecycleRoot $LifecycleRoot `
        -PullRequestId $PullRequestId `
        -Key $Key `
        -DeadlineUtc $DeadlineUtc `
        -UtcNowProvider $UtcNowProvider
    if (-not [bool]$state.valid) {
        throw 'stale-pr-activity-proof-invalidation-failed'
    }
    if ($null -eq $state.latest -or
        [string]$state.latest.state -cne 'recent-activity') {
        return
    }
    try {
        $nextSequence = [long]$state.maxSequence + 1L
        if ($nextSequence -gt $script:MaxActivityProofHistoryEntriesPerPr) {
            throw 'stale-pr-activity-proof-invalidation-failed'
        }
        $payload = [ordered]@{
            schemaVersion = 1
            kind = 'stale-pr-activity-proof-v1'
            sequence = $nextSequence
            pullRequestId = [long]$PullRequestId
            state = 'withheld'
            policyDigest = $PolicyDigest
            evidenceDigest = [string]$state.latest.evidenceDigest
            subject = [ordered]@{} + $state.latest.subject
        }
        $relativePath = (
            "activity-proofs\$PullRequestId\" +
            "seq-$('{0:D8}' -f $nextSequence)-withheld.json")
        $fullPath = Join-Path $LifecycleRoot $relativePath
        $proofRoot = Join-Path $LifecycleRoot ("activity-proofs\$PullRequestId")
        if (-not (Test-AgentPathWithin -Root $LifecycleRoot -Path $proofRoot) -or
            -not (Test-AgentPathWithin -Root $proofRoot -Path $fullPath) -or
            (Test-Path -LiteralPath $fullPath)) {
            throw 'stale-pr-activity-proof-invalidation-failed'
        }
        [void](Write-StalePrSignedRecord `
            -LifecycleRoot $LifecycleRoot `
            -RelativePath $relativePath `
            -Payload $payload `
            -Key $Key)
    }
    catch {
        if ($_.Exception.Message -ceq 'stale-pr-deadline-exhausted') {
            throw
        }
        throw 'stale-pr-activity-proof-invalidation-failed'
    }
}

function Get-StalePrPriorWriteBlock {
    param(
        [Parameter(Mandatory)][string]$LifecycleRoot,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $intentRoot = Join-Path $LifecycleRoot `
        "intents\$PullRequestId"
    foreach ($intentFile in @(Get-ChildItem `
            -LiteralPath $intentRoot -Filter '*.json' -File `
            -ErrorAction SilentlyContinue)) {
        [void](Read-StalePrLifecyclePolicy `
            -Path $intentFile.FullName -Key $Key)
        $outcomePath = Join-Path $LifecycleRoot (
            "outcomes\$PullRequestId\$($intentFile.Name)")
        if (-not (Test-Path -LiteralPath $outcomePath `
                -PathType Leaf)) {
            return 'prior-intent-unresolved'
        }
        $outcome = Read-StalePrLifecyclePolicy `
            -Path $outcomePath -Key $Key
        if ([string]$outcome.providerWriteState -ceq
                'unknown' -or
            [string]$outcome.outcome -ceq
                'ambiguous-post-write') {
            return 'prior-ambiguous-write'
        }
    }
    $explanationRoot = Join-Path $LifecycleRoot `
        "explanations\intents\$PullRequestId"
    foreach ($intentFile in @(Get-ChildItem -LiteralPath $explanationRoot `
            -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $explanationIntent = Read-StalePrLifecyclePolicy `
            -Path $intentFile.FullName -Key $Key
        $confirmationPath = Join-Path $LifecycleRoot (
            "explanations\confirmations\$PullRequestId\$($intentFile.Name)")
        if (Test-Path -LiteralPath $confirmationPath -PathType Leaf) {
            $confirmation = Read-StalePrLifecyclePolicy `
                -Path $confirmationPath -Key $Key
            if ([string]$confirmation.state -cne 'confirmed' -or
                [string]$confirmation.identity -cne
                    [string]$explanationIntent.identity -or
                [string]$confirmation.intentDigest -cne
                    (Get-StalePrDigest $explanationIntent)) {
                return 'prior-explanation-confirmation-invalid'
            }
            continue
        }
        $outcomePath = Join-Path $LifecycleRoot (
            "explanations\outcomes\$PullRequestId\$($intentFile.Name)")
        if (-not (Test-Path -LiteralPath $outcomePath -PathType Leaf)) {
            return 'prior-explanation-intent-unresolved'
        }
        $outcome = Read-StalePrLifecyclePolicy -Path $outcomePath -Key $Key
        if ([string]$outcome.state -cne 'confirmed') {
            return 'prior-ambiguous-explanation'
        }
    }
    return ''
}

function New-StalePrAzureDevOpsProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Config,
        [AllowNull()][Collections.IDictionary]$Policy,
        [string]$AzureCliPath = 'az',
        [Parameter(DontShow)]
        [AllowNull()][scriptblock]$TokenInvoker,
        [Parameter(DontShow)]
        [AllowNull()][scriptblock]$HttpInvoker,
        [Parameter(DontShow)]
        [AllowNull()][scriptblock]$UtcNowProvider
    )
    $organization = [string]$Config.organization
    $projectName = [string]$Config.projectName
    $projectId = ([string]$Config.projectId).ToLowerInvariant()
    $repositoryId =
        ([string]$Config.repositoryId).ToLowerInvariant()
    $actor = $Config.expectedAccount
    $explanationAuthorized = Test-StalePrExplanationAuthority $Policy
    $writeState = [pscustomobject]@{
        StatusAttempts = 0
        PullRequestId = 0L
        StatusIntentId = ''
        Confirmed = $false
        ExplanationAttempts = 0
        ApprovedContent = ''
    }
    $configuredReadCeilings = @(
        [int]$Config.subjectProvider.maximumReads
        [int]$Config.limits.maxReads
    )
    if ($configuredReadCeilings.Count -ne 2 -or
        @($configuredReadCeilings |
            Where-Object { $_ -lt 1 }).Count -ne 0 -or
        [int]$Config.limits.maxSeconds -lt 1) {
        throw 'stale-pr-provider-budget-invalid'
    }
    $readCeiling = [int](
        @($configuredReadCeilings + @(128)) |
            Measure-Object -Minimum).
        Minimum
    $maximumSeconds = [Math]::Min(240, [int]$Config.limits.maxSeconds)
    $getUtcNow = if ($null -ne $UtcNowProvider) {
        [scriptblock]$UtcNowProvider
    }
    else {
        { [DateTime]::UtcNow }
    }
    $runBudget = [pscustomobject]@{
        Count = 0
        Ceiling = $readCeiling
        ExplanationCount = 0
        DeadlineUtc = (& $getUtcNow).
            AddSeconds($maximumSeconds)
    }
    $lastObservedUtcNow = [pscustomobject]@{
        Value = ([DateTime]$runBudget.DeadlineUtc).AddSeconds(-$maximumSeconds)
    }
    $peekUtcNow = if ($null -ne $UtcNowProvider) {
        { [DateTime]$lastObservedUtcNow.Value }.GetNewClosure()
    }
    else {
        { [DateTime]::UtcNow }
    }
    $providerPushDates = @{}
    $cacheState = [pscustomobject]@{
        LifecycleRoot = ''
        Key = $null
        CutoffUtc = $null
        Stage = 'decision'
        UtcNowProvider = $peekUtcNow
    }
    $convertUtcCommand =
        ${function:ConvertTo-StalePrUtc}
    $digestCommand =
        ${function:Get-StalePrDigest}
    $failureReasonCommand =
        ${function:Get-StalePrFailureReason}
    $canonicalJsonCommand =
        ${function:ConvertTo-ApprovedOwnerV2CanonicalJson}
    $readCachedPushDateCommand =
        ${function:Read-StalePrCachedPushDate}
    $writeCachedPushDateCommand =
        ${function:Write-StalePrCachedPushDate}
    $tokenProcessCommand =
        (Get-Command Invoke-StalePrTokenProcess `
            -CommandType Function).ScriptBlock
    $boundedTokenInvokerCommand =
        (Get-Command Invoke-StalePrTokenInvokerBounded `
            -CommandType Function).ScriptBlock
    $organizationUri = [Uri]$organization
    if ($organizationUri.Scheme -cne 'https' -or
        $organizationUri.Host -cne 'dev.azure.com' -or
        $organizationUri.AbsolutePath.Trim('/') -cne
            $organizationUri.Segments[-1].Trim('/')) {
        throw 'stale-pr-organization-uri-invalid'
    }
    $organizationBase = $organization.TrimEnd('/')
    $tokenState = [pscustomobject]@{
        AccessToken = ''
    }
    $newBudgetFailure = {
        param(
            [string]$Reason,
            [string]$Kind,
            $Budget,
            [AllowNull()][object]$ResponseBytes
        )
        $failure =
            [InvalidOperationException]::new($Reason)
        $failure.Data['stalePrReason'] = $Reason
        $failure.Data['stalePrBudgetKind'] = $Kind
        $failure.Data['stalePrReadCount'] =
            [int]$Budget.Count
        $failure.Data['stalePrReadCeiling'] =
            $readCeiling
        if ($null -ne $ResponseBytes) {
            $failure.Data['stalePrResponseBytes'] =
                [long]$ResponseBytes
        }
        $failure.Data['stalePrDeadlineUtc'] =
            ([DateTime]$Budget.DeadlineUtc).
                ToString('o')
        return $failure
    }.GetNewClosure()
    $getAccessToken = {
        param([DateTime]$DeadlineUtc)
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$tokenState.AccessToken)) {
            return [string]$tokenState.AccessToken
        }
        $nowBeforeToken = & $getUtcNow
        $lastObservedUtcNow.Value = $nowBeforeToken
        $remainingMilliseconds = [int][Math]::Floor(
            ($DeadlineUtc - $nowBeforeToken).
                TotalMilliseconds)
        if ($remainingMilliseconds -le 0) {
            throw (& $newBudgetFailure `
                    -Reason 'stale-pr-deadline-exhausted' `
                    -Kind 'deadline' -Budget $runBudget `
                    -ResponseBytes $null)
        }
        $response = if ($null -ne $TokenInvoker) {
            & $boundedTokenInvokerCommand `
                -TokenInvoker $TokenInvoker `
                -DeadlineUtc $DeadlineUtc `
                -TimeoutMilliseconds $remainingMilliseconds
        }
        else {
            & $tokenProcessCommand `
                -AzureCliPath $AzureCliPath `
                -DeadlineUtc $DeadlineUtc
        }
        $token = if ($response -is
                [Collections.IDictionary]) {
            [string]$response.accessToken
        }
        else { [string]$response }
        if ($token -cnotmatch '^\S{100,}$') {
            throw 'stale-pr-token-unavailable'
        }
        $tokenState.AccessToken = $token
        return $token
    }.GetNewClosure()
    $invokeHttp = {
        param(
            [Parameter(Mandatory)][uri]$Uri,
            [Parameter(Mandatory)]
            [ValidateSet('GET', 'PATCH', 'POST')]
            [string]$Method,
            [Parameter(Mandatory)]$Budget,
            [AllowNull()][byte[]]$Body = $null
        )
        if ($Uri.Scheme -cne 'https' -or
            $Uri.Host -cne $organizationUri.Host -or
            -not $Uri.AbsolutePath.StartsWith(
                $organizationUri.AbsolutePath.TrimEnd('/') + '/',
                [StringComparison]::Ordinal)) {
            throw 'stale-pr-http-uri-invalid'
        }
        if ($Method -ceq 'GET' -and
            [int]$Budget.Count -ge $readCeiling) {
            throw (& $newBudgetFailure `
                    -Reason 'stale-pr-read-budget-exhausted' `
                    -Kind 'read-count' -Budget $Budget `
                    -ResponseBytes $null)
        }
        $nowBeforeHttp = & $getUtcNow
        $lastObservedUtcNow.Value = $nowBeforeHttp
        if ($nowBeforeHttp -ge
            [DateTime]$Budget.DeadlineUtc) {
            throw (& $newBudgetFailure `
                    -Reason 'stale-pr-deadline-exhausted' `
                    -Kind 'deadline' -Budget $Budget `
                    -ResponseBytes $null)
        }
        if ($Method -ceq 'GET') {
            $Budget.Count++
        }
        $token = & $getAccessToken (
            [DateTime]$Budget.DeadlineUtc)
        $afterTokenUtc = & $getUtcNow
        $lastObservedUtcNow.Value = $afterTokenUtc
        if ($afterTokenUtc -ge
            [DateTime]$Budget.DeadlineUtc) {
            throw (& $newBudgetFailure `
                    -Reason 'stale-pr-deadline-exhausted' `
                    -Kind 'deadline' -Budget $Budget `
                    -ResponseBytes $null)
        }
        $remaining =
            ([DateTime]$Budget.DeadlineUtc -
                $afterTokenUtc).TotalSeconds
        if ($remaining -le 0) {
            throw (& $newBudgetFailure `
                    -Reason 'stale-pr-deadline-exhausted' `
                    -Kind 'deadline' -Budget $Budget `
                    -ResponseBytes $null)
        }
        $remainingSeconds = [int][Math]::Max(
            1,
            [Math]::Ceiling($remaining))
        $request = @{
            Uri = $Uri
            Method = $Method
            Headers = @{
                Authorization = ('Bearer ' + $token)
            }
            TimeoutSec = $remainingSeconds
            UseBasicParsing = $true
        }
        if ($Method -cne 'GET') {
            if ($null -eq $Body) {
                throw 'stale-pr-write-body-invalid'
            }
            $request.Body = $Body
            $request.ContentType = 'application/json'
        }
        try {
            $response = if ($null -ne $HttpInvoker) {
                & $HttpInvoker $request
            }
            else {
                Invoke-WebRequest @request
            }
        }
        catch {
            $failure = [InvalidOperationException]::new(
                'stale-pr-provider-inaccessible')
            $failure.Data['stalePrFailureKind'] =
                'http-request-failed'
            if ($null -ne $_.Exception.PSObject.Properties['Response'] -and
                $null -ne $_.Exception.Response) {
                $failure.Data['stalePrHttpStatus'] =
                    [int]$_.Exception.Response.StatusCode
            }
            if ($_.Exception.Data.Contains(
                    'serverErrorCode')) {
                $failure.Data['stalePrServerErrorCode'] =
                    [string]$_.Exception.Data[
                        'serverErrorCode']
            }
            throw $failure
        }
        $nowAfterHttp = & $getUtcNow
        $lastObservedUtcNow.Value = $nowAfterHttp
        if ($nowAfterHttp -ge
            [DateTime]$Budget.DeadlineUtc) {
            throw (& $newBudgetFailure `
                    -Reason 'stale-pr-deadline-exhausted' `
                    -Kind 'deadline' -Budget $Budget `
                    -ResponseBytes $null)
        }
        if ($response -is [Collections.IDictionary]) {
            return $response
        }
        if ([long]$response.RawContentLength -lt 0 -or
            [long]$response.RawContentLength -gt 16777216) {
            throw (& $newBudgetFailure `
                    -Reason 'stale-pr-read-budget-exhausted' `
                    -Kind 'response-size' -Budget $Budget `
                    -ResponseBytes (
                        [long]$response.RawContentLength))
        }
        try {
            return ([string]$response.Content).
                TrimStart([char]0xFEFF) |
                ConvertFrom-Json -AsHashtable -Depth 100
        }
        catch {
            throw 'stale-pr-response-invalid'
        }
    }.GetNewClosure()
    $read = {
        param(
            [string]$RelativePathAndQuery,
            [long]$PullRequestId,
            [Parameter(Mandatory)]$Budget
        )
        $uri = [Uri](
            $organizationBase + '/' +
            [Uri]::EscapeDataString($projectName) +
            '/_apis/git/repositories/' +
            [Uri]::EscapeDataString($repositoryId) +
            '/pullRequests/' +
            [Uri]::EscapeDataString(
                [string]$PullRequestId) +
            $RelativePathAndQuery)
        return & $invokeHttp `
            -Uri $uri -Method GET -Budget $Budget
    }.GetNewClosure()
    $readPush = {
        param(
            [long]$PushId,
            [Parameter(Mandatory)]$Budget
        )
        $uri = [Uri](
            $organizationBase + '/' +
            [Uri]::EscapeDataString($projectName) +
            '/_apis/git/repositories/' +
            [Uri]::EscapeDataString($repositoryId) +
            '/pushes/' +
            [Uri]::EscapeDataString([string]$PushId) +
            '?includeRefUpdates=false&includeCommits=false' +
            '&api-version=7.1')
        return & $invokeHttp `
            -Uri $uri -Method GET -Budget $Budget
    }.GetNewClosure()
    $readEvidence = {
        param([long]$PullRequestId)
        $pushDates = @{}
        $cachedPushEntries = [Collections.Generic.List[object]]::new()
        $pr = & $read '?api-version=7.1' `
            $PullRequestId $runBudget
        if ($pr.repository -isnot [Collections.IDictionary] -or
            [string]$pr.repository.id -ine $repositoryId -or
            $pr.repository.project -isnot
                [Collections.IDictionary] -or
            [string]$pr.repository.project.id -ine $projectId) {
            throw 'stale-pr-repository-mismatch'
        }
        $iterations = & $read '/iterations?api-version=7.1' `
            $PullRequestId $runBudget
        $threads = & $read '/threads?api-version=7.1' `
            $PullRequestId $runBudget
        if ($null -ne $iterations.continuation_token -or
            [int]$iterations.count -ne @($iterations.value).Count -or
            $null -ne $threads.continuation_token -or
            [int]$threads.count -ne @($threads.value).Count) {
            throw 'stale-pr-history-incomplete'
        }
        $orderedIterations = @($iterations.value |
            Sort-Object { [int]$_.id })
        $latest = if ($orderedIterations.Count -gt 0) {
            $orderedIterations[-1]
        }
        else { $null }
        $sourceCommit = if ($null -ne $latest) {
            [string]$latest.sourceRefCommit.commitId
        }
        else {
            [string]$pr.lastMergeSourceCommit.commitId
        }
        $targetCommit = if ($null -ne $latest) {
            [string]$latest.targetRefCommit.commitId
        }
        else {
            [string]$pr.lastMergeTargetCommit.commitId
        }
        if ($sourceCommit -cnotmatch '^[0-9a-fA-F]{40}$' -or
            $targetCommit -cnotmatch '^[0-9a-fA-F]{40}$') {
            throw 'stale-pr-head-unknown'
        }
        $sourceRef = [string]$pr.sourceRefName
        if ($sourceRef -cnotmatch
            '^refs/heads/(?<filter>.+)$') {
            throw 'stale-pr-source-ref-invalid'
        }
        $refsUri = [Uri](
            $organizationBase + '/' +
            [Uri]::EscapeDataString($projectName) +
            '/_apis/git/repositories/' +
            [Uri]::EscapeDataString($repositoryId) +
            '/refs?filter=' +
            [Uri]::EscapeDataString(
                "heads/$($Matches.filter)") +
            '&includeStatuses=false&peelTags=false' +
            '&api-version=7.1')
        $refs = & $invokeHttp `
            -Uri $refsUri -Method GET -Budget $runBudget
        $matchingRefs = @($refs.value | Where-Object {
                [string]$_.name -ceq $sourceRef -and
                [string]$_.objectId -cmatch
                    '^[0-9a-fA-F]{40}$'
            })
        if ($null -ne $refs.continuation_token -or
            [int]$refs.count -ne @($refs.value).Count -or
            $matchingRefs.Count -ne 1 -or
            [string]$matchingRefs[0].objectId -ine
                $sourceCommit) {
            throw 'stale-pr-source-ref-inconsistent'
        }
        $creationUtc = & $convertUtcCommand `
            -Value ([string]$pr.creationDate) `
            -Name creationDate
        $isPrewrite = ([string]$cacheState.Stage -ceq 'prewrite')
        $hasCutoff = (-not $isPrewrite -and $null -ne $cacheState.CutoffUtc)
        $cutoffUtc = if ($hasCutoff) {
            [DateTime]$cacheState.CutoffUtc
        }
        else { [DateTime]::MaxValue }
        $hasRecentWitness = ($hasCutoff -and $creationUtc -gt $cutoffUtc)
        $iterationMeta = [Collections.Generic.List[object]]::new()
        for ($iterIndex = 0;
            $iterIndex -lt $orderedIterations.Count;
            $iterIndex++) {
            $iteration = $orderedIterations[$iterIndex]
            $iterDates = [ordered]@{}
            foreach ($name in @('createdDate', 'updatedDate')) {
                if ([string]::IsNullOrWhiteSpace(
                        [string]$iteration[$name])) {
                    throw 'stale-pr-iteration-time-unknown'
                }
                $parsedIterUtc = & $convertUtcCommand `
                    -Value ([string]$iteration[$name]) `
                    -Name $name
                if ($hasCutoff -and $parsedIterUtc -gt $cutoffUtc) {
                    $hasRecentWitness = $true
                }
                $iterDates[$name] = $parsedIterUtc.ToString('o')
            }
            $pushMeta = $null
            if ($null -ne $iteration.push) {
                if ($iteration.push.pushId -is [bool]) {
                    throw 'stale-pr-push-time-unknown'
                }
                $pushId = [long]$iteration.push.pushId
                if ($pushId -lt 1) {
                    throw 'stale-pr-push-time-unknown'
                }
                $iterId = [int]$iteration.id
                $iterSourceCommit = if (
                    $iteration.sourceRefCommit -is
                        [Collections.IDictionary] -and
                    [string]$iteration.sourceRefCommit.commitId -cmatch
                        '^[0-9a-fA-F]{40}$'
                ) {
                    ([string]$iteration.sourceRefCommit.commitId).
                        ToLowerInvariant()
                }
                else { $sourceCommit.ToLowerInvariant() }
                $iterTargetCommit = if (
                    $iteration.targetRefCommit -is
                        [Collections.IDictionary] -and
                    [string]$iteration.targetRefCommit.commitId -cmatch
                        '^[0-9a-fA-F]{40}$'
                ) {
                    ([string]$iteration.targetRefCommit.commitId).
                        ToLowerInvariant()
                }
                else { $targetCommit.ToLowerInvariant() }
                $inlinePushIso = $null
                $rawInlinePushDate = [string]$iteration.push.date
                if (-not [string]::IsNullOrWhiteSpace($rawInlinePushDate)) {
                    try {
                        $inlinePushUtc = & $convertUtcCommand `
                            -Value $rawInlinePushDate -Name pushDate
                    }
                    catch {
                        throw 'stale-pr-push-time-unknown'
                    }
                    if ($hasCutoff -and $inlinePushUtc -gt $cutoffUtc) {
                        $hasRecentWitness = $true
                    }
                    $inlinePushIso = $inlinePushUtc.ToString('o')
                }
                $pushMeta = [ordered]@{
                    IterationId = $iterId
                    PushId = $pushId
                    PushKey = [string]$pushId
                    ProviderPushKey = (
                        "$projectId|$repositoryId|$PullRequestId|" +
                        "$iterId|$pushId|$iterSourceCommit|$iterTargetCommit")
                    SourceCommit = $iterSourceCommit
                    TargetCommit = $iterTargetCommit
                    InlinePushUtc = $inlinePushIso
                }
            }
            [void]$iterationMeta.Add([ordered]@{
                    IterationId = [int]$iteration.id
                    CreatedUtc = $iterDates['createdDate']
                    UpdatedUtc = $iterDates['updatedDate']
                    Push = $pushMeta
                })
        }
        $commentActivities = [Collections.Generic.List[object]]::new()
        foreach ($thread in @($threads.value)) {
            if ($thread.comments -isnot [array]) {
                throw 'stale-pr-comments-incomplete'
            }
            foreach ($comment in @($thread.comments)) {
                $type = [string]$comment.commentType
                if ($type -ceq 'system') { continue }
                if ($type -cnotin @('text', 'codeChange')) {
                    throw 'stale-pr-comment-type-unknown'
                }
                foreach ($name in @(
                        'publishedDate', 'lastUpdatedDate',
                        'lastContentUpdatedDate'
                    )) {
                    if ([string]::IsNullOrWhiteSpace(
                            [string]$comment[$name])) {
                        throw 'stale-pr-comment-time-unknown'
                    }
                    $commentUtc = & $convertUtcCommand `
                        -Value ([string]$comment[$name]) `
                        -Name $name
                    if ($hasCutoff -and $commentUtc -gt $cutoffUtc) {
                        $hasRecentWitness = $true
                    }
                    [void]$commentActivities.Add([ordered]@{
                            kind = $(if (
                                [int]$comment.parentCommentId -gt 0
                            ) { "reply-$name" } else {
                                "comment-$name"
                            })
                            threadId = [long]$thread.id
                            commentId = [long]$comment.id
                            occurredUtc = $commentUtc.ToString('o')
                        })
                }
            }
        }
        $fetchLivePushIso = {
            param([Collections.IDictionary]$PushInfo)
            $pushId = [long]$PushInfo.PushId
            $pushKey = [string]$PushInfo.PushKey
            if (-not $pushDates.ContainsKey($pushKey)) {
                try {
                    $push = & $readPush $pushId $runBudget
                }
                catch {
                    $pushFailure =
                        & $failureReasonCommand $_
                    if ($pushFailure -cin @(
                            'stale-pr-read-budget-exhausted',
                            'stale-pr-deadline-exhausted')) {
                        throw
                    }
                    throw 'stale-pr-push-time-unknown'
                }
                if ($push -isnot
                        [Collections.IDictionary] -or
                    [long]$push.pushId -ne $pushId -or
                    $push.repository -isnot
                        [Collections.IDictionary] -or
                    [string]$push.repository.id -ine
                        $repositoryId -or
                    $push.repository.project -isnot
                        [Collections.IDictionary] -or
                    [string]$push.repository.project.id -ine
                        $projectId -or
                    [string]::IsNullOrWhiteSpace(
                        [string]$push.date)) {
                    throw 'stale-pr-push-time-unknown'
                }
                try {
                    $parsedLivePush = & $convertUtcCommand `
                        -Value ([string]$push.date) -Name pushDate
                }
                catch {
                    throw 'stale-pr-push-time-unknown'
                }
                $pushDates[$pushKey] = $parsedLivePush.ToString('o')
            }
            $liveIso = [string]$pushDates[$pushKey]
            $providerPushDates[[string]$PushInfo.ProviderPushKey] = $liveIso
            & $writeCachedPushDateCommand `
                -LifecycleRoot ([string]$cacheState.LifecycleRoot) `
                -Key $cacheState.Key `
                -ProjectId $projectId `
                -RepositoryId $repositoryId `
                -PullRequestId $PullRequestId `
                -IterationId ([int]$PushInfo.IterationId) `
                -PushId $pushId `
                -SourceCommit ([string]$PushInfo.SourceCommit) `
                -TargetCommit ([string]$PushInfo.TargetCommit) `
                -OccurredUtc $liveIso `
                -DeadlineUtc ([DateTime]$runBudget.DeadlineUtc) `
                -UtcNowProvider $peekUtcNow
            return $liveIso
        }
        $resolvedPushUtcByIndex = @{}
        $cachedPushByIndex = @{}
        for ($iterIndex = $iterationMeta.Count - 1;
            $iterIndex -ge 0;
            $iterIndex--) {
            $pushInfo = $iterationMeta[$iterIndex].Push
            if ($null -eq $pushInfo) { continue }
            $isNewestIteration = ($iterIndex -eq ($iterationMeta.Count - 1))
            if (-not [string]::IsNullOrWhiteSpace(
                    [string]$pushInfo.InlinePushUtc)) {
                $resolvedPushUtcByIndex[$iterIndex] =
                    [string]$pushInfo.InlinePushUtc
                continue
            }
            $pushKey = [string]$pushInfo.PushKey
            if ($pushDates.ContainsKey($pushKey)) {
                $liveIso = [string]$pushDates[$pushKey]
                $resolvedPushUtcByIndex[$iterIndex] = $liveIso
                $providerPushDates[[string]$pushInfo.ProviderPushKey] =
                    $liveIso
                & $writeCachedPushDateCommand `
                    -LifecycleRoot ([string]$cacheState.LifecycleRoot) `
                    -Key $cacheState.Key `
                    -ProjectId $projectId `
                    -RepositoryId $repositoryId `
                    -PullRequestId $PullRequestId `
                    -IterationId ([int]$pushInfo.IterationId) `
                    -PushId ([long]$pushInfo.PushId) `
                    -SourceCommit ([string]$pushInfo.SourceCommit) `
                    -TargetCommit ([string]$pushInfo.TargetCommit) `
                    -OccurredUtc $liveIso `
                    -DeadlineUtc ([DateTime]$runBudget.DeadlineUtc) `
                    -UtcNowProvider $peekUtcNow
                continue
            }
            if (-not $isPrewrite) {
                $cachedIso = $null
                $providerPushKey = [string]$pushInfo.ProviderPushKey
                if ($providerPushDates.ContainsKey($providerPushKey)) {
                    $cachedIso = [string]$providerPushDates[$providerPushKey]
                }
                else {
                    $cachedIso = & $readCachedPushDateCommand `
                        -LifecycleRoot ([string]$cacheState.LifecycleRoot) `
                        -Key $cacheState.Key `
                        -ProjectId $projectId `
                        -RepositoryId $repositoryId `
                        -PullRequestId $PullRequestId `
                        -IterationId ([int]$pushInfo.IterationId) `
                        -PushId ([long]$pushInfo.PushId) `
                        -SourceCommit ([string]$pushInfo.SourceCommit) `
                        -TargetCommit ([string]$pushInfo.TargetCommit) `
                        -DeadlineUtc ([DateTime]$runBudget.DeadlineUtc) `
                        -UtcNowProvider $peekUtcNow
                    if (-not [string]::IsNullOrWhiteSpace($cachedIso)) {
                        $providerPushDates[$providerPushKey] = $cachedIso
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($cachedIso)) {
                    $cachedUtc = & $convertUtcCommand `
                        -Value $cachedIso -Name pushDate
                    if ($hasCutoff -and $cachedUtc -gt $cutoffUtc) {
                        $hasRecentWitness = $true
                    }
                    $resolvedPushUtcByIndex[$iterIndex] =
                        $cachedUtc.ToString('o')
                    $cachedPushByIndex[$iterIndex] = $true
                    continue
                }
            }
            if ($isNewestIteration -or
                (-not $hasCutoff) -or
                (-not $hasRecentWitness)) {
                $liveIso = & $fetchLivePushIso $pushInfo
                $liveUtc = & $convertUtcCommand `
                    -Value $liveIso -Name pushDate
                if ($hasCutoff -and $liveUtc -gt $cutoffUtc) {
                    $hasRecentWitness = $true
                }
                $resolvedPushUtcByIndex[$iterIndex] = $liveUtc.ToString('o')
            }
        }
        if ($isPrewrite -or ($hasCutoff -and -not $hasRecentWitness)) {
            for ($iterIndex = 0;
                $iterIndex -lt $iterationMeta.Count;
                $iterIndex++) {
                $pushInfo = $iterationMeta[$iterIndex].Push
                if ($null -eq $pushInfo) { continue }
                if (-not $resolvedPushUtcByIndex.ContainsKey($iterIndex) -or
                    $cachedPushByIndex.ContainsKey($iterIndex)) {
                    $liveIso = & $fetchLivePushIso $pushInfo
                    $resolvedPushUtcByIndex[$iterIndex] = $liveIso
                    [void]$cachedPushByIndex.Remove($iterIndex)
                }
            }
        }
        $activity = [Collections.Generic.List[object]]::new()
        for ($iterIndex = 0;
            $iterIndex -lt $iterationMeta.Count;
            $iterIndex++) {
            $meta = $iterationMeta[$iterIndex]
            [void]$activity.Add([ordered]@{
                    kind = 'iteration-createdDate'
                    iterationId = [int]$meta.IterationId
                    occurredUtc = [string]$meta.CreatedUtc
                })
            [void]$activity.Add([ordered]@{
                    kind = 'iteration-updatedDate'
                    iterationId = [int]$meta.IterationId
                    occurredUtc = [string]$meta.UpdatedUtc
                })
            if ($null -ne $meta.Push -and
                $resolvedPushUtcByIndex.ContainsKey($iterIndex)) {
                [void]$activity.Add([ordered]@{
                        kind = 'source-push'
                        iterationId = [int]$meta.IterationId
                        pushId = [long]$meta.Push.PushId
                        occurredUtc = [string]$resolvedPushUtcByIndex[$iterIndex]
                    })
            }
        }
        foreach ($commentActivity in $commentActivities) {
            [void]$activity.Add($commentActivity)
        }
        $activityTimes = @($activity |
            ForEach-Object {
                & $convertUtcCommand `
                    -Value ([string]$_.occurredUtc) `
                    -Name activityUtc
            })
        $latestActivity = @(
            @($activityTimes) + @($creationUtc) |
                Sort-Object |
                Select-Object -Last 1)[0]
        return [ordered]@{
            schemaVersion = 1
            projectId = $projectId
            repositoryId = $repositoryId
            pullRequestId = [long]$pr.pullRequestId
            status = [string]$pr.status
            isDraft = [bool]$pr.isDraft
            sourceRef = $sourceRef
            targetRef = [string]$pr.targetRefName
            sourceCommit = $sourceCommit.ToLowerInvariant()
            targetCommit = $targetCommit.ToLowerInvariant()
            iterationId = $(if ($null -ne $latest) {
                    [int]$latest.id
                } else { 0 })
            creationUtc = $creationUtc.ToString('o')
            latestActivityUtc = $latestActivity.ToString('o')
            activityDigest =
                & $digestCommand $activity.ToArray()
            complete = $true
        }
    }.GetNewClosure()
    $handler = {
        param(
            [string]$Operation,
            [Collections.IDictionary]$Arguments
        )
        switch -CaseSensitive ($Operation) {
            Identity {
                $connectionUri = [Uri](
                    $organizationBase +
                    '/_apis/connectionData' +
                    '?connectOptions=1' +
                    '&api-version=7.1-preview.1')
                $connection = & $invokeHttp `
                    -Uri $connectionUri -Method GET `
                    -Budget $runBudget
                foreach ($name in @(
                        'authenticatedUser',
                        'authorizedUser')) {
                    $identity = $connection[$name]
                    if ($identity -isnot
                            [Collections.IDictionary] -or
                        [string]$identity.id -ine
                            [string]$actor.id -or
                        [string]$identity.subjectDescriptor -cne
                            [string]$actor.descriptor) {
                        throw 'stale-pr-provider-identity-mismatch'
                    }
                }
                if ([string]$connection.authenticatedUser.id -ine
                    [string]$connection.authorizedUser.id) {
                    throw 'stale-pr-provider-identity-mismatch'
                }
                return [ordered]@{} + $actor
            }
            ReadEvidence {
                return & $readEvidence (
                    [long]$Arguments.pullRequestId)
            }
            ReadStatus {
                $pr = & $read '?api-version=7.1' `
                    ([long]$Arguments.pullRequestId) `
                    $runBudget
                if ($writeState.StatusAttempts -eq 1 -and
                    [long]$pr.pullRequestId -eq $writeState.PullRequestId -and
                    [string]$pr.status -ceq 'abandoned') {
                    $writeState.Confirmed = $true
                }
                return [ordered]@{
                    pullRequestId = [long]$pr.pullRequestId
                    status = [string]$pr.status
                }
            }
            AbandonStatus {
                if ($Arguments.body -isnot
                        [Collections.IDictionary] -or
                    @($Arguments.body.Keys).Count -ne 1 -or
                    [string]$Arguments.body.status -cne 'abandoned') {
                    throw 'stale-pr-write-body-invalid'
                }
                if ($writeState.StatusAttempts -ge 1) {
                    throw 'stale-pr-status-attempt-cap'
                }
                $writeState.StatusAttempts++
                $writeState.PullRequestId = [long]$Arguments.pullRequestId
                $writeState.StatusIntentId = [string]$Arguments.statusIntentId
                $body = [Text.UTF8Encoding]::new(
                    $false).GetBytes(
                    (& $canonicalJsonCommand `
                        $Arguments.body))
                $uri = [Uri](
                    $organizationBase + '/' +
                    [Uri]::EscapeDataString($projectName) +
                    '/_apis/git/repositories/' +
                    [Uri]::EscapeDataString($repositoryId) +
                    '/pullrequests/' +
                    [Uri]::EscapeDataString(
                        [string][long]$Arguments.pullRequestId) +
                    '?api-version=7.1')
                return & $invokeHttp `
                    -Uri $uri -Method PATCH `
                    -Budget $runBudget -Body $body
            }
            ReadExplanation {
                if (-not $explanationAuthorized -or
                    [string]$Arguments.statusIntentId -cnotmatch
                        '^[0-9a-f]{32}$' -or
                    [string]$Arguments.marker -cne (
                        '<!-- devpilot-stale-abandonment:v1:' +
                        [string]$Arguments.statusIntentId + ' -->') -or
                    [string]$Arguments.content -cnotlike (
                        '*' + [string]$Arguments.marker + '*') -or
                    ([string]$Arguments.content).Length -gt 4096) {
                    throw 'stale-pr-explanation-not-authorized'
                }
                $beforeReads = [int]$runBudget.Count
                try {
                    $threads = & $read '/threads?api-version=7.1' `
                        ([long]$Arguments.pullRequestId) $runBudget
                }
                finally {
                    $runBudget.ExplanationCount +=
                        [int]$runBudget.Count - $beforeReads
                }
                if ($null -ne $threads.continuation_token -or
                    [int]$threads.count -ne @($threads.value).Count) {
                    throw 'stale-pr-explanation-history-incomplete'
                }
                $matches = [Collections.Generic.List[object]]::new()
                foreach ($thread in @($threads.value)) {
                    if ($thread.comments -isnot [array]) {
                        throw 'stale-pr-explanation-history-incomplete'
                    }
                    foreach ($comment in @($thread.comments)) {
                        if (([string]$comment.content).Contains(
                                [string]$Arguments.marker,
                                [StringComparison]::Ordinal)) {
                            [void]$matches.Add(@{
                                    threadId = [long]$thread.id
                                    commentId = [long]$comment.id
                                    exact = [string]$comment.content -ceq
                                        [string]$Arguments.content -and
                                        [string]$comment.author.id -ieq
                                            [string]$actor.id -and
                                        [string]$comment.commentType -ceq 'text' -and
                                        [int]$comment.parentCommentId -eq 0
                                })
                        }
                    }
                }
                $state = if ($matches.Count -eq 0) { 'absent' }
                    elseif ($matches.Count -eq 1 -and $matches[0].exact -and
                        $matches[0].threadId -gt 0 -and
                        $matches[0].commentId -gt 0) { 'confirmed' }
                    else { 'conflict' }
                if ($state -ceq 'absent' -and $writeState.Confirmed -and
                    $writeState.PullRequestId -eq [long]$Arguments.pullRequestId -and
                    $writeState.StatusIntentId -ceq [string]$Arguments.statusIntentId) {
                    $writeState.ApprovedContent = [string]$Arguments.content
                }
                return [ordered]@{
                    state = $state
                    pullRequestId = [long]$Arguments.pullRequestId
                    markerMatchCount = $matches.Count
                    bodyDigest = $(if ($state -ceq 'confirmed') {
                            & $digestCommand ([string]$Arguments.content)
                        } else { $null })
                    authorId = $(if ($state -ceq 'confirmed') {
                            [string]$actor.id
                        } else { $null })
                    threadId = $(if ($matches.Count -eq 1) {
                            $matches[0].threadId
                        } else { $null })
                    commentId = $(if ($matches.Count -eq 1) {
                            $matches[0].commentId
                        } else { $null })
                }
            }
            CreateExplanation {
                if (-not $explanationAuthorized -or
                    -not $writeState.Confirmed -or
                    $writeState.PullRequestId -ne [long]$Arguments.pullRequestId -or
                    $writeState.StatusIntentId -cne [string]$Arguments.statusIntentId -or
                    $writeState.ExplanationAttempts -ge 1 -or
                    [string]::IsNullOrWhiteSpace($writeState.ApprovedContent) -or
                    $writeState.ApprovedContent -cne [string]$Arguments.content) {
                    throw 'stale-pr-explanation-not-authorized'
                }
                $writeState.ExplanationAttempts++
                $request = [ordered]@{
                    comments = @([ordered]@{
                            parentCommentId = 0
                            content = [string]$Arguments.content
                            commentType = 1
                        })
                }
                $body = [Text.UTF8Encoding]::new($false).GetBytes(
                    (& $canonicalJsonCommand $request))
                $uri = [Uri](
                    $organizationBase + '/' +
                    [Uri]::EscapeDataString($projectName) +
                    '/_apis/git/repositories/' +
                    [Uri]::EscapeDataString($repositoryId) +
                    '/pullRequests/' +
                    [string][long]$Arguments.pullRequestId +
                    '/threads?api-version=7.1')
                return & $invokeHttp -Uri $uri -Method POST `
                    -Budget $runBudget -Body $body
            }
            default {
                throw "Unsupported stale PR operation '$Operation'."
            }
        }
    }.GetNewClosure()
    $handler | Add-Member -NotePropertyName StalePrBudget `
        -NotePropertyValue $runBudget
    $handler | Add-Member -NotePropertyName StalePrCache `
        -NotePropertyValue $cacheState
    return $handler
}

function New-StalePrExplanationIntent {
    param(
        [Collections.IDictionary]$StatusIntent,
        [Collections.IDictionary]$StatusOutcome
    )
    $format = 'yyyyMMddTHHmmssfffffffZ'
    $style = [Globalization.DateTimeStyles]::AssumeUniversal -bor
        [Globalization.DateTimeStyles]::AdjustToUniversal
    $times = @{}
    foreach ($entry in @(
            @{ Name = 'cutoff'; Value = $StatusIntent.cutoffUtc }
            @{ Name = 'creation'; Value = $StatusIntent.subject.creationUtc }
            @{ Name = 'activity'; Value = $StatusIntent.subject.latestActivityUtc }
        )) {
        $times[$entry.Name] = [DateTime]::ParseExact(
            [string]$entry.Value, $format,
            [Globalization.CultureInfo]::InvariantCulture, $style).ToString('o')
    }
    $marker = '<!-- devpilot-stale-abandonment:v1:' +
        [string]$StatusIntent.intentId + ' -->'
    $content = @(
        'This pull request was automatically abandoned because it was created more than one year ago and has had no counted activity since the frozen cutoff.'
        ''
        "Frozen cutoff (UTC): $($times.cutoff)"
        "Created (UTC): $($times.creation)"
        "Latest counted activity (UTC): $($times.activity)"
        'Counted activity includes source pushes, iterations, and non-system comments, replies, and edits by all actors, including bots. Metadata, votes, service statuses, and commit author dates do not count.'
        "Frozen evidence: $($StatusIntent.evidenceDigest)"
        $marker
    ) -join "`n"
    $intent = [ordered]@{
        schemaVersion = 1
        kind = 'stale-pr-abandonment-explanation-v1-intent'
        action = 'comment:create-after-confirmed-abandonment'
        runId = [string]$StatusIntent.runId
        statusIntentId = [string]$StatusIntent.intentId
        statusIntentDigest = Get-StalePrDigest $StatusIntent
        statusOutcomeDigest = Get-StalePrDigest $StatusOutcome
        policyDigest = [string]$StatusIntent.policyDigest
        actor = $StatusIntent.actor
        subject = $StatusIntent.subject
        cutoffUtc = [string]$StatusIntent.cutoffUtc
        marker = $marker
        content = $content
        bodyDigest = Get-StalePrDigest $content
    }
    $intent['identity'] = Get-StalePrDigest $intent
    return $intent
}

function Complete-StalePrExplanation {
    param(
        [Collections.IDictionary]$Intent,
        [string]$LifecycleRoot,
        [byte[]]$Key,
        [scriptblock]$Provider,
        [AllowNull()][Nullable[int]]$AttemptedWrites,
        [switch]$Reconcile,
        [AllowNull()][object]$Diagnostic,
        [AllowNull()][object]$KnownReadback
    )
    $providerBudget = if (
        $null -ne $Provider.PSObject.Properties['StalePrBudget']
    ) {
        $Provider.StalePrBudget
    }
    else { $null }
    $readback = $KnownReadback
    if ($null -eq $readback) {
        try {
            $readback = & $Provider ReadExplanation @{
                pullRequestId = [long]$Intent.subject.pullRequestId
                statusIntentId = [string]$Intent.statusIntentId
                marker = [string]$Intent.marker
                content = [string]$Intent.content
            }
        }
        catch {
            $Diagnostic = [ordered]@{
                kind = 'explanation-readback-failed'
                budget = Get-StalePrBudgetDiagnostic $_ `
                    -Budget $providerBudget
            }
        }
    }
    $confirmed = $false
    if ($readback -is [Collections.IDictionary]) {
        $keys = @($readback.Keys | Sort-Object -CaseSensitive)
        $exactShape = $keys.Count -eq 7 -and
            ($keys -join ',') -ceq (
                'authorId,bodyDigest,commentId,markerMatchCount,' +
                'pullRequestId,state,threadId')
        if ($exactShape) {
            $integerFields = @(
                'pullRequestId', 'markerMatchCount', 'threadId', 'commentId'
            )
            $integersValid = @($integerFields | Where-Object {
                    $readback[$_] -isnot [int] -and
                    $readback[$_] -isnot [long]
                }).Count -eq 0
            $confirmed = $integersValid -and
                $readback.state -is [string] -and
                $readback.state -ceq 'confirmed' -and
                $readback.pullRequestId -eq [long]$Intent.subject.pullRequestId -and
                $readback.markerMatchCount -eq 1 -and
                $readback.bodyDigest -is [string] -and
                $readback.bodyDigest -ceq [string]$Intent.bodyDigest -and
                $readback.authorId -is [string] -and
                $readback.authorId -ieq [string]$Intent.actor.id -and
                $readback.threadId -gt 0 -and
                $readback.commentId -gt 0
        }
    }
    if (-not $confirmed -and $null -ne $readback) {
        $Diagnostic = [ordered]@{
            kind = 'explanation-readback-unconfirmed'
            providerDiagnostic = $Diagnostic
        }
        $readback = $null
    }
    $state = if ($confirmed) { 'confirmed' } else { 'unknown' }
    $event = [ordered]@{
        schemaVersion = 1
        kind = 'stale-pr-abandonment-explanation-v1-event'
        action = [string]$Intent.action
        operation = $(if ($Reconcile) { 'reconcile' } else { 'create' })
        eventId = [guid]::NewGuid().ToString('N')
        occurredUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
        runId = [string]$Intent.runId
        statusIntentId = [string]$Intent.statusIntentId
        identity = [string]$Intent.identity
        policyDigest = [string]$Intent.policyDigest
        bodyDigest = [string]$Intent.bodyDigest
        intentDigest = Get-StalePrDigest $Intent
        actor = $Intent.actor
        subject = $Intent.subject
        readback = $readback
        state = $state
        diagnostic = $Diagnostic
        providerWriteCount = $(if ($Reconcile) { 0 } else { $AttemptedWrites })
        originalAttemptCount = $AttemptedWrites
        originalAttemptCeiling = 1
        providerWriteState = $state
        modelWriteCount = 0
        retryAuthorized = $false
    }
    $outcome = [ordered]@{
        schemaVersion = 1
        kind = 'stale-pr-abandonment-explanation-v1-outcome'
        action = [string]$Intent.action
        identity = [string]$Intent.identity
        statusIntentId = [string]$Intent.statusIntentId
        policyDigest = [string]$Intent.policyDigest
        bodyDigest = [string]$Intent.bodyDigest
        intentDigest = Get-StalePrDigest $Intent
        eventId = [string]$event.eventId
        state = $state
        providerWriteCount = $AttemptedWrites
        providerWriteState = $state
        retryAuthorized = $false
    }
    try {
        [void](Write-StalePrSignedRecord -LifecycleRoot $LifecycleRoot `
            -RelativePath "explanations\events\$($event.eventId).json" `
            -Payload $event -Key $Key)
        $outcomePath = if ($Reconcile) {
            "explanations\reconciliations\$($event.eventId).json"
        }
        else {
            "explanations\outcomes\$($Intent.subject.pullRequestId)\" +
                "$($Intent.statusIntentId).json"
        }
        [void](Write-StalePrSignedRecord -LifecycleRoot $LifecycleRoot `
            -RelativePath $outcomePath -Payload $outcome -Key $Key)
        if ($Reconcile -and $confirmed) {
            [void](Write-StalePrSignedRecord -LifecycleRoot $LifecycleRoot `
                -RelativePath (
                    "explanations\confirmations\$($Intent.subject.pullRequestId)\" +
                    "$($Intent.statusIntentId).json") -Key $Key -Payload ([ordered]@{
                        schemaVersion = 1
                        kind = 'stale-pr-abandonment-explanation-v1-confirmation'
                        action = [string]$Intent.action
                        identity = [string]$Intent.identity
                        intentDigest = Get-StalePrDigest $Intent
                        bodyDigest = [string]$Intent.bodyDigest
                        state = 'confirmed'
                        readback = $readback
                        retryAuthorized = $false
                    }))
        }
    }
    catch {
        $state = 'unknown'
        $Diagnostic = @{ kind = 'explanation-audit-write-failed' }
    }
    return [ordered]@{
        state = $state
        providerWrites = $(if ($Reconcile) { 0 } else { $AttemptedWrites })
        unconfirmedWrites = $(if ($confirmed -or $Reconcile) {
                0
            } else { $AttemptedWrites })
        identity = [string]$Intent.identity
        bodyDigest = [string]$Intent.bodyDigest
        diagnostic = $Diagnostic
        event = $event
    }
}

function Invoke-StalePrExplanation {
    param(
        [Collections.IDictionary]$StatusIntent,
        [Collections.IDictionary]$StatusOutcome,
        [string]$LifecycleRoot,
        [byte[]]$Key,
        [scriptblock]$Provider
    )
    $attempts = 0
    try {
        $intent = New-StalePrExplanationIntent $StatusIntent $StatusOutcome
        $id = [long]$intent.subject.pullRequestId
        $transition = [string]$intent.statusIntentId
        # Permanent, exclusive reservation: a crash never authorizes a second POST.
        $lock = [IO.File]::Open(
            (Join-Path $LifecycleRoot "locks\explanation-$id-$transition.lock"),
            [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $lock.Dispose()
        [void](Write-StalePrSignedRecord -LifecycleRoot $LifecycleRoot `
            -RelativePath "explanations\intents\$id\$transition.json" `
            -Payload $intent -Key $Key)
        $arguments = @{
            pullRequestId = $id
            statusIntentId = $transition
            marker = [string]$intent.marker
            content = [string]$intent.content
        }
        $preflight = & $Provider ReadExplanation $arguments
        if ([string]$preflight.state -cne 'absent') {
            return Complete-StalePrExplanation -Intent $intent `
                -LifecycleRoot $LifecycleRoot -Key $Key -Provider $Provider `
                -AttemptedWrites 0 -KnownReadback $preflight
        }
        $attempts = 1
        $diagnostic = $null
        try {
            [void](& $Provider CreateExplanation $arguments)
        }
        catch {
            $diagnostic = Get-StalePrWriteDiagnostic $_
        }
        return Complete-StalePrExplanation -Intent $intent `
            -LifecycleRoot $LifecycleRoot -Key $Key -Provider $Provider `
            -AttemptedWrites $attempts -Diagnostic $diagnostic
    }
    catch {
        $providerBudget = if (
            $null -ne $Provider.PSObject.Properties['StalePrBudget']
        ) {
            $Provider.StalePrBudget
        }
        else { $null }
        return [ordered]@{
            state = 'unknown'
            providerWrites = $attempts
            unconfirmedWrites = $attempts
            diagnostic = @{
                kind = 'explanation-preflight-or-audit-failed'
                budget = Get-StalePrBudgetDiagnostic $_ `
                    -Budget $providerBudget
            }
            event = $null
        }
    }
}

function Resolve-StalePrLifecycleExplanation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LifecycleRoot,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')]
        [string]$StatusIntentId,
        [Parameter(Mandatory)][Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][scriptblock]$Provider
    )
    if (-not (Test-StalePrExplanationAuthority $Policy) -or
        $PullRequestId -lt 1 -or $Key.Length -ne 32) {
        throw 'stale-pr-explanation-reconciliation-not-authorized'
    }
    $statusIntent = Read-StalePrLifecyclePolicy -Key $Key -Path (
        Join-Path $LifecycleRoot "intents\$PullRequestId\$StatusIntentId.json")
    $statusOutcome = Read-StalePrLifecyclePolicy -Key $Key -Path (
        Join-Path $LifecycleRoot "outcomes\$PullRequestId\$StatusIntentId.json")
    $intent = Read-StalePrLifecyclePolicy -Key $Key -Path (
        Join-Path $LifecycleRoot (
            "explanations\intents\$PullRequestId\$StatusIntentId.json"))
    $expected = New-StalePrExplanationIntent $statusIntent $statusOutcome
    $identity = & $Provider Identity @{}
    if ([string]$statusOutcome.providerWriteState -cne 'confirmed' -or
        [string]$statusOutcome.intentId -cne $StatusIntentId -or
        [string]$statusOutcome.action -cne 'status:abandoned' -or
        [string]$statusIntent.action -cne 'status:abandoned' -or
        [string]$statusIntent.intentId -cne $StatusIntentId -or
        [long]$statusIntent.subject.pullRequestId -ne $PullRequestId -or
        [string]$statusIntent.policyDigest -cne (Get-StalePrDigest $Policy) -or
        (Get-StalePrDigest $statusIntent.actor) -cne
            (Get-StalePrDigest $Policy.actor) -or
        (Get-StalePrDigest $intent) -cne (Get-StalePrDigest $expected) -or
        [string]$identity.id -ine [string]$intent.actor.id -or
        [string]$identity.descriptor -cne [string]$intent.actor.descriptor) {
        throw 'stale-pr-explanation-reconciliation-binding-changed'
    }
    $originalAttempts = $null
    $outcomePath = Join-Path $LifecycleRoot (
        "explanations\outcomes\$PullRequestId\$StatusIntentId.json")
    if (Test-Path -LiteralPath $outcomePath -PathType Leaf) {
        $originalOutcome = Read-StalePrLifecyclePolicy -Path $outcomePath -Key $Key
        if ([string]$originalOutcome.identity -cne [string]$intent.identity -or
            [string]$originalOutcome.intentDigest -cne (Get-StalePrDigest $intent) -or
            $originalOutcome.providerWriteCount -is [bool] -or
            [string]$originalOutcome.providerWriteCount -cnotmatch '^[01]$') {
            throw 'stale-pr-explanation-reconciliation-binding-changed'
        }
        $originalAttempts = [int]$originalOutcome.providerWriteCount
    }
    return Complete-StalePrExplanation -Intent $intent `
        -LifecycleRoot $LifecycleRoot -Key $Key -Provider $Provider `
        -AttemptedWrites $originalAttempts -Reconcile
}

function Invoke-StalePrLifecycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Inventory,
        [Parameter(Mandatory)][DateTime]$CutoffUtc,
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][string]$LifecycleRoot,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][scriptblock]$Provider
    )
    if ($CutoffUtc.Kind -cne [DateTimeKind]::Utc -or
        $Key.Length -ne 32) {
        throw 'Stale PR lifecycle requires one UTC cutoff and service key.'
    }
    $providerBudget = if (
        $null -ne $Provider.PSObject.Properties['StalePrBudget']
    ) {
        $Provider.StalePrBudget
    }
    else { $null }
    $providerCache = if (
        $null -ne $Provider.PSObject.Properties['StalePrCache']
    ) {
        $Provider.StalePrCache
    }
    else { $null }
    $providerDeadlineUtc = if (
        $null -ne $providerBudget -and
        $null -ne $providerBudget.PSObject.Properties['DeadlineUtc'] -and
        $null -ne $providerBudget.DeadlineUtc
    ) {
        [DateTime]$providerBudget.DeadlineUtc
    }
    else { $null }
    $providerUtcNowProvider = if (
        $null -ne $providerCache -and
        $null -ne $providerCache.PSObject.Properties['UtcNowProvider']
    ) {
        [scriptblock]$providerCache.UtcNowProvider
    }
    else { $null }
    if ($null -ne $providerCache) {
        $providerCache.LifecycleRoot = $LifecycleRoot
        $providerCache.Key = $Key
        $providerCache.CutoffUtc = $CutoffUtc
        $providerCache.Stage = 'decision'
    }
    $explanationEnabled = Test-StalePrExplanationAuthority $Policy
    $identity = & $Provider Identity @{}
    if ([string]$identity.id -ine [string]$Policy.actor.id -or
        [string]$identity.descriptor -cne
            [string]$Policy.actor.descriptor) {
        throw 'Stale PR lifecycle provider identity changed.'
    }
    $runId = [guid]::NewGuid().ToString('N')
    $policyDigest = Get-StalePrDigest $Policy
    $results = [Collections.Generic.List[object]]::new()
    $confirmed = [Collections.Generic.List[long]]::new()
    $reviewEligible =
        [Collections.Generic.HashSet[long]]::new()
    $events = [Collections.Generic.List[object]]::new()
    $explanationEvents = [Collections.Generic.List[object]]::new()
    $writes = 0
    $explanationWrites = 0
    $unconfirmedStatusWrites = 0
    $unconfirmedExplanationWrites = 0
    $unknown = 0
    $oldCandidates =
        [Collections.Generic.List[object]]::new()
    foreach ($item in @($Inventory)) {
        if ([string]$item.status -cne 'active' -or
            [bool]$item.isDraft -or
            [string]$item.targetRef -cne
                [string]$Policy.scope.targetRef) {
            continue
        }
        $id = [long]$item.pullRequestId
        try {
            $creation = ConvertTo-StalePrUtc `
                -Value ([string]$item.creationUtc) `
                -Name creationUtc
        }
        catch {
            [void]$oldCandidates.Add($item)
            continue
        }
        if ($creation -ge $CutoffUtc) {
            [void]$reviewEligible.Add($id)
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'no-op'
                    reason = 'creation-within-cutoff'
                    providerWrites = 0
                })
            continue
        }
        [void]$oldCandidates.Add($item)
    }
    $candidateCount = $oldCandidates.Count
    $candidateLimit = [Math]::Min(
        $candidateCount,
        [int]$Policy.authority.maxCandidatesPerRun)
    $cachedProofById = @{}
    $unprovenCandidateIds =
        [Collections.Generic.HashSet[long]]::new()
    $budgetExhausted = $false
    $deferredNextPullRequestId = $null
    $firstCachedPullRequestId = $null
    $nextPullRequestId = $null
    for ($candidateIndex = 0;
        $candidateIndex -lt $candidateLimit;
        $candidateIndex++) {
        $item = $oldCandidates[$candidateIndex]
        $id = [long]$item.pullRequestId
        if ($budgetExhausted) {
            continue
        }
        if ($candidateCount -gt 0) {
            $nextPullRequestId = [long]$oldCandidates[
                ($candidateIndex + 1) % $candidateCount
            ].pullRequestId
        }
        if ([string]$item.status -cne 'active' -or
            [bool]$item.isDraft -or
            [string]$item.targetRef -cne
                [string]$Policy.scope.targetRef) {
            continue
        }
        try {
            $creation = ConvertTo-StalePrUtc `
                -Value ([string]$item.creationUtc) `
                -Name creationUtc
        }
        catch {
            $reason = [string](
                Get-StalePrFailureReason $_)
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = [string]$_
            }
            if ($reason -cin @(
                    'stale-pr-read-budget-exhausted',
                    'stale-pr-deadline-exhausted')) {
                [void]$results.Add([ordered]@{
                        pullRequestId = $id
                        state = 'deferred'
                        reason = $reason
                        providerWrites = 0
                        diagnostic =
                            Get-StalePrBudgetDiagnostic $_ `
                                -Budget $providerBudget
                    })
                $budgetExhausted = $true
                $deferredNextPullRequestId = $nextPullRequestId
                continue
            }
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = 'creation-time-unknown'
                    providerWrites = 0
                })
            continue
        }
        if ($creation -ge $CutoffUtc) { continue }
        try {
            $priorWriteBlock =
                Get-StalePrPriorWriteBlock `
                    -LifecycleRoot $LifecycleRoot `
                    -PullRequestId $id -Key $Key
        }
        catch {
            $priorWriteBlock =
                'prior-audit-unknown'
        }
        if ($priorWriteBlock) {
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = $priorWriteBlock
                    providerWrites = 0
                })
            continue
        }
        if ($writes -ge
            [Math]::Min(1, [int]$Policy.authority.maxAbandonsPerRun)) {
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'deferred'
                    reason = 'run-cap-reached'
                    providerWrites = 0
                })
            continue
        }
        if ($null -ne $providerBudget) {
            try {
                $cachedProof = Get-StalePrCachedActivityProof `
                    -LifecycleRoot $LifecycleRoot `
                    -PullRequestId $id `
                    -Item $item `
                    -CutoffUtc $CutoffUtc `
                    -Policy $Policy `
                    -PolicyDigest $policyDigest `
                    -Key $Key `
                    -DeadlineUtc $providerDeadlineUtc `
                    -UtcNowProvider $providerUtcNowProvider
            }
            catch {
                $cacheReadReason = [string](Get-StalePrFailureReason $_)
                if ([string]::IsNullOrWhiteSpace($cacheReadReason)) {
                    $cacheReadReason = [string]$_
                }
                if ($cacheReadReason -cin @(
                        'stale-pr-read-budget-exhausted',
                        'stale-pr-deadline-exhausted')) {
                    [void]$results.Add([ordered]@{
                            pullRequestId = $id
                            state = 'deferred'
                            reason = $cacheReadReason
                            providerWrites = 0
                            diagnostic =
                                Get-StalePrBudgetDiagnostic $_ `
                                    -Budget $providerBudget
                        })
                    $budgetExhausted = $true
                    $deferredNextPullRequestId = $nextPullRequestId
                    continue
                }
                $cachedProof = $null
            }
            if ($null -ne $cachedProof) {
                $cachedProofById[$id] = $cachedProof
            }
            else {
                [void]$unprovenCandidateIds.Add($id)
            }
        }
        $useCachedProof = $false
        if ($null -ne $providerBudget -and
            $cachedProofById.ContainsKey($id)) {
            $remainingUnproven = ($candidateLimit - $candidateIndex - 1)
            if ($null -ne $firstCachedPullRequestId) {
                $useCachedProof = $true
            }
            else {
                $remainingReads = [int]$providerBudget.Ceiling -
                    [int]$providerBudget.Count
                $requiredReads = if ($remainingUnproven -gt 0) {
                    ($remainingUnproven * 4) + 4
                }
                else {
                    4
                }
                if ($remainingReads -lt $requiredReads) {
                    $useCachedProof = $true
                }
            }
        }
        if ($useCachedProof) {
            if ($null -eq $firstCachedPullRequestId) {
                $firstCachedPullRequestId = $id
            }
            [void]$reviewEligible.Add($id)
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'no-op'
                    reason = 'recent-activity'
                    providerWrites = 0
                })
            continue
        }
        try {
            if ($null -ne $providerCache) {
                $providerCache.Stage = 'decision'
            }
            $evidence = & $Provider ReadEvidence @{
                pullRequestId = $id
            }
            Assert-StalePrEvidence `
                -Evidence $evidence -Policy $Policy
            if ([long]$evidence.pullRequestId -ne $id) {
                throw 'stale-pr-subject-mismatch'
            }
        }
        catch {
            $reason = [string](
                Get-StalePrFailureReason $_)
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = [string]$_
            }
            if ($reason -cin @(
                    'stale-pr-read-budget-exhausted',
                    'stale-pr-deadline-exhausted')) {
                [void]$results.Add([ordered]@{
                        pullRequestId = $id
                        state = 'deferred'
                        reason = $reason
                        providerWrites = 0
                        diagnostic =
                            Get-StalePrBudgetDiagnostic $_ `
                                -Budget $providerBudget
                    })
                $budgetExhausted = $true
                $deferredNextPullRequestId = $nextPullRequestId
                continue
            }
            $invalidationFailure = $null
            try {
                Disable-StalePrCachedActivityProof `
                    -LifecycleRoot $LifecycleRoot `
                    -PullRequestId $id `
                    -PolicyDigest $policyDigest `
                    -Key $Key `
                    -DeadlineUtc $providerDeadlineUtc `
                    -UtcNowProvider $providerUtcNowProvider
            }
            catch {
                $invalidationFailure = [string](
                    Get-StalePrFailureReason $_)
                if ([string]::IsNullOrWhiteSpace($invalidationFailure)) {
                    $invalidationFailure = [string]$_
                }
            }
            $unknown++
            $failureDecision = [ordered]@{
                pullRequestId = $id
                state = 'unknown'
                reason = 'activity-evidence-unknown'
                providerWrites = 0
            }
            if (-not [string]::IsNullOrWhiteSpace($invalidationFailure)) {
                $failureDecision['diagnostic'] = [ordered]@{
                    kind = 'cache-invalidation-failed'
                    reason = $invalidationFailure
                    priorReason = $reason
                }
            }
            elseif ($reason -cin @(
                    'stale-pr-push-cache-write-failed',
                    'stale-pr-activity-proof-write-failed',
                    'stale-pr-activity-proof-invalidation-failed')) {
                $failureDecision['diagnostic'] = [ordered]@{
                    kind = 'cache-write-failed'
                    reason = $reason
                }
            }
            [void]$results.Add($failureDecision)
            continue
        }
        if (-not [bool]$evidence.complete) {
            try {
                Disable-StalePrCachedActivityProof `
                    -LifecycleRoot $LifecycleRoot `
                    -PullRequestId $id `
                    -PolicyDigest $policyDigest `
                    -Key $Key `
                    -DeadlineUtc $providerDeadlineUtc `
                    -UtcNowProvider $providerUtcNowProvider
            }
            catch {
                $invReason = [string](Get-StalePrFailureReason $_)
                if ([string]::IsNullOrWhiteSpace($invReason)) {
                    $invReason = [string]$_
                }
                $unknown++
                [void]$results.Add([ordered]@{
                        pullRequestId = $id
                        state = 'unknown'
                        reason = 'activity-evidence-unknown'
                        providerWrites = 0
                        diagnostic = [ordered]@{
                            kind = 'cache-invalidation-failed'
                            reason = $invReason
                        }
                    })
                continue
            }
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = 'activity-evidence-incomplete'
                    providerWrites = 0
                })
            continue
        }
        if ([string]$evidence.status -ceq 'abandoned') {
            try {
                Disable-StalePrCachedActivityProof `
                    -LifecycleRoot $LifecycleRoot `
                    -PullRequestId $id `
                    -PolicyDigest $policyDigest `
                    -Key $Key `
                    -DeadlineUtc $providerDeadlineUtc `
                    -UtcNowProvider $providerUtcNowProvider
            }
            catch {
                $invReason = [string](Get-StalePrFailureReason $_)
                if ([string]::IsNullOrWhiteSpace($invReason)) {
                    $invReason = [string]$_
                }
                $unknown++
                [void]$results.Add([ordered]@{
                        pullRequestId = $id
                        state = 'unknown'
                        reason = 'activity-evidence-unknown'
                        providerWrites = 0
                        diagnostic = [ordered]@{
                            kind = 'cache-invalidation-failed'
                            reason = $invReason
                        }
                    })
                continue
            }
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'no-op'
                    reason = 'already-abandoned'
                    providerWrites = 0
                })
            continue
        }
        if ([string]$evidence.status -cne 'active' -or
            [bool]$evidence.isDraft -or
            [string]$evidence.targetRef -cne
                [string]$Policy.scope.targetRef) {
            try {
                Disable-StalePrCachedActivityProof `
                    -LifecycleRoot $LifecycleRoot `
                    -PullRequestId $id `
                    -PolicyDigest $policyDigest `
                    -Key $Key `
                    -DeadlineUtc $providerDeadlineUtc `
                    -UtcNowProvider $providerUtcNowProvider
            }
            catch {
                $invReason = [string](Get-StalePrFailureReason $_)
                if ([string]::IsNullOrWhiteSpace($invReason)) {
                    $invReason = [string]$_
                }
                $unknown++
                [void]$results.Add([ordered]@{
                        pullRequestId = $id
                        state = 'unknown'
                        reason = 'activity-evidence-unknown'
                        providerWrites = 0
                        diagnostic = [ordered]@{
                            kind = 'cache-invalidation-failed'
                            reason = $invReason
                        }
                    })
                continue
            }
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'no-op'
                    reason = 'subject-left-policy'
                    providerWrites = 0
                })
            continue
        }
        $evidenceCreationUtc = ConvertTo-StalePrUtc `
            -Value ([string]$evidence.creationUtc) `
            -Name creationUtc
        $evidenceLatestActivityUtc = ConvertTo-StalePrUtc `
            -Value ([string]$evidence.latestActivityUtc) `
            -Name latestActivityUtc
        if ($evidenceCreationUtc -ge $CutoffUtc -or
            $evidenceLatestActivityUtc -gt $CutoffUtc) {
            if ($evidenceCreationUtc -lt $CutoffUtc -and
                $evidenceLatestActivityUtc -gt $CutoffUtc) {
                try {
                    $existingProofState = Get-StalePrActivityProofState `
                        -LifecycleRoot $LifecycleRoot `
                        -PullRequestId $id `
                        -Key $Key `
                        -DeadlineUtc $providerDeadlineUtc `
                        -UtcNowProvider $providerUtcNowProvider
                    if (-not [bool]$existingProofState.valid) {
                        throw 'stale-pr-activity-proof-write-failed'
                    }
                    if ([long]$existingProofState.maxSequence -lt $script:MaxActivityProofFilesPerPr) {
                        Write-StalePrActivityProof `
                            -LifecycleRoot $LifecycleRoot `
                            -PullRequestId $id `
                            -Evidence $evidence `
                            -PolicyDigest $policyDigest `
                            -Key $Key `
                            -DeadlineUtc $providerDeadlineUtc `
                            -UtcNowProvider $providerUtcNowProvider
                    }
                    else {
                        Disable-StalePrCachedActivityProof `
                            -LifecycleRoot $LifecycleRoot `
                            -PullRequestId $id `
                            -PolicyDigest $policyDigest `
                            -Key $Key `
                            -DeadlineUtc $providerDeadlineUtc `
                            -UtcNowProvider $providerUtcNowProvider
                    }
                }
                catch {
                    $writeProofReason = [string](Get-StalePrFailureReason $_)
                    if ([string]::IsNullOrWhiteSpace($writeProofReason)) {
                        $writeProofReason = [string]$_
                    }
                    if ($writeProofReason -cin @(
                            'stale-pr-read-budget-exhausted',
                            'stale-pr-deadline-exhausted')) {
                        [void]$results.Add([ordered]@{
                                pullRequestId = $id
                                state = 'deferred'
                                reason = $writeProofReason
                                providerWrites = 0
                                diagnostic =
                                    Get-StalePrBudgetDiagnostic $_ `
                                        -Budget $providerBudget
                            })
                        $budgetExhausted = $true
                        $deferredNextPullRequestId = $nextPullRequestId
                        continue
                    }
                    $unknown++
                    [void]$results.Add([ordered]@{
                            pullRequestId = $id
                            state = 'unknown'
                            reason = 'activity-evidence-unknown'
                            providerWrites = 0
                            diagnostic = [ordered]@{
                                kind = 'cache-write-failed'
                                reason = $writeProofReason
                            }
                        })
                    continue
                }
            }
            [void]$reviewEligible.Add($id)
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'no-op'
                    reason = 'recent-activity'
                    providerWrites = 0
                })
            continue
        }
        try {
            Disable-StalePrCachedActivityProof `
                -LifecycleRoot $LifecycleRoot `
                -PullRequestId $id `
                -PolicyDigest $policyDigest `
                -Key $Key `
                -DeadlineUtc $providerDeadlineUtc `
                -UtcNowProvider $providerUtcNowProvider
        }
        catch {
            $invReason = [string](Get-StalePrFailureReason $_)
            if ([string]::IsNullOrWhiteSpace($invReason)) {
                $invReason = [string]$_
            }
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = 'activity-evidence-unknown'
                    providerWrites = 0
                    diagnostic = [ordered]@{
                        kind = 'cache-invalidation-failed'
                        reason = $invReason
                    }
                })
            continue
        }
        $decisionDigest = Get-StalePrDigest (
            Get-StalePrEvidenceBinding $evidence)
        try {
            if ($null -ne $providerCache) {
                $providerCache.Stage = 'prewrite'
            }
            $prewrite = & $Provider ReadEvidence @{
                pullRequestId = $id
            }
            Assert-StalePrEvidence `
                -Evidence $prewrite -Policy $Policy
            if ([long]$prewrite.pullRequestId -ne $id) {
                throw 'stale-pr-subject-mismatch'
            }
            $prewriteDigest = Get-StalePrDigest (
                Get-StalePrEvidenceBinding $prewrite)
        }
        catch {
            $reason = [string](
                Get-StalePrFailureReason $_)
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = [string]$_
            }
            if ($reason -cin @(
                    'stale-pr-read-budget-exhausted',
                    'stale-pr-deadline-exhausted')) {
                [void]$results.Add([ordered]@{
                        pullRequestId = $id
                        state = 'deferred'
                        reason = $reason
                        providerWrites = 0
                        diagnostic =
                            Get-StalePrBudgetDiagnostic $_ `
                                -Budget $providerBudget
                    })
                $budgetExhausted = $true
                $deferredNextPullRequestId = $nextPullRequestId
                continue
            }
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = 'prewrite-evidence-unknown'
                    providerWrites = 0
                })
            continue
        }
        if ($prewriteDigest -cne $decisionDigest -or
            [string]$prewrite.status -cne 'active' -or
            -not [bool]$prewrite.complete) {
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = 'prewrite-race-withheld'
                    providerWrites = 0
                })
            continue
        }
        $intentId = [guid]::NewGuid().ToString('N')
        $request = [ordered]@{ status = 'abandoned' }
        $intent = [ordered]@{
            schemaVersion = 1
            kind = 'stale-pr-lifecycle-v1-intent'
            action = 'status:abandoned'
            runId = $runId
            intentId = $intentId
            createdUtc = [DateTime]::UtcNow.
                ToString('yyyyMMddTHHmmssfffffffZ')
            actor = [ordered]@{} + $Policy.actor
            subject = Get-StalePrEvidenceBinding $prewrite
            cutoffUtc =
                $CutoffUtc.ToString(
                    'yyyyMMddTHHmmssfffffffZ')
            evidenceDigest = $prewriteDigest
            policyDigest = $policyDigest
            request = $request
        }
        [void](Write-StalePrSignedRecord `
            -LifecycleRoot $LifecycleRoot `
            -RelativePath "intents\$id\$intentId.json" `
            -Payload $intent -Key $Key)
        $writeError = $null
        try {
            [void](& $Provider AbandonStatus @{
                    pullRequestId = $id
                    statusIntentId = $intentId
                    body = $request
                })
        }
        catch {
            $writeError = $_
        }
        $writes++
        $readback = $null
        try {
            $readback = & $Provider ReadStatus @{
                pullRequestId = $id
            }
        }
        catch {
            $readback = $null
        }
        $confirmedWrite =
            $readback -is [Collections.IDictionary] -and
            [long]$readback.pullRequestId -eq $id -and
            [string]$readback.status -ceq 'abandoned'
        if ($confirmedWrite) {
            [void]$confirmed.Add($id)
        }
        else {
            $unconfirmedStatusWrites++
        }
        $outcome = if ($confirmedWrite) {
            if ($null -eq $writeError) {
                'abandoned'
            } else { 'abandoned-confirmed-after-error' }
        }
        else { 'ambiguous-post-write' }
        $writeDiagnostic = if ($null -ne $writeError) {
            Get-StalePrWriteDiagnostic $writeError
        }
        else { $null }
        $event = [ordered]@{
            schemaVersion = 1
            kind = 'stale-pr-lifecycle-v1-event'
            action = 'status:abandoned'
            eventId = [guid]::NewGuid().ToString('N')
            runId = $runId
            intentId = $intentId
            occurredUtc = [DateTime]::UtcNow.
                ToString('yyyyMMddTHHmmssfffffffZ')
            actor = [ordered]@{} + $Policy.actor
            subject = Get-StalePrEvidenceBinding $prewrite
            cutoffUtc =
                $CutoffUtc.ToString(
                    'yyyyMMddTHHmmssfffffffZ')
            evidenceDigest = $prewriteDigest
            policyDigest = $policyDigest
            request = $request
            readback = $readback
            outcome = $outcome
            diagnostic = $writeDiagnostic
            providerWriteCount = 1
            providerWriteState = $(if ($confirmedWrite) {
                    'confirmed'
                } else { 'unknown' })
            modelWriteCount = 0
            otherWriteCount = 0
        }
        $outcomeRecord = [ordered]@{
            schemaVersion = 1
            kind = 'stale-pr-lifecycle-v1-outcome'
            action = 'status:abandoned'
            runId = $runId
            intentId = $intentId
            completedUtc = [DateTime]::UtcNow.
                ToString('yyyyMMddTHHmmssfffffffZ')
            eventId = [string]$event.eventId
            outcome = $outcome
            diagnostic = $writeDiagnostic
            providerWriteCount = 1
            providerWriteState = $(if ($confirmedWrite) {
                    'confirmed'
                } else { 'unknown' })
            retryAuthorized = $false
        }
        try {
            [void](Write-StalePrSignedRecord `
                -LifecycleRoot $LifecycleRoot `
                -RelativePath "events\$($event.eventId).json" `
                -Payload $event -Key $Key)
            [void](Write-StalePrSignedRecord `
                -LifecycleRoot $LifecycleRoot `
                -RelativePath "outcomes\$id\$intentId.json" `
                -Payload $outcomeRecord -Key $Key)
        }
        catch {
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = 'audit-write-failed'
                    providerWrites = 1
                })
            break
        }
        [void]$events.Add($event)
        if ($confirmedWrite) {
            $explanation = [ordered]@{
                state = 'not-authorized'
                providerWrites = 0
                unconfirmedWrites = 0
            }
            if ($explanationEnabled) {
                $explanation = Invoke-StalePrExplanation `
                    -StatusIntent $intent -StatusOutcome $outcomeRecord `
                    -LifecycleRoot $LifecycleRoot -Key $Key -Provider $Provider
                $explanationWrites += [int]$explanation.providerWrites
                $unconfirmedExplanationWrites += [int]$explanation.unconfirmedWrites
                if ($null -ne $explanation.event) {
                    [void]$explanationEvents.Add($explanation.event)
                }
                if ([string]$explanation.state -cne 'confirmed') {
                    $unknown++
                }
            }
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'abandoned'
                    reason = 'readback-confirmed'
                    providerWrites = 1 + [int]$explanation.providerWrites
                    statusWrites = 1
                    explanationWrites = [int]$explanation.providerWrites
                    explanation = $explanation
                })
        }
        else {
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = 'ambiguous-post-write'
                    providerWrites = 1
                })
            break
        }
    }
    if ($budgetExhausted) {
        $nextPullRequestId = $deferredNextPullRequestId
    }
    elseif ($null -ne $firstCachedPullRequestId) {
        $nextPullRequestId = $firstCachedPullRequestId
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'stale-pr-lifecycle-v1-run'
        runId = $runId
        cutoffUtc = $CutoffUtc.ToString('o')
        health = $(if ($unknown -gt 0) {
                'unknown'
            } elseif (@($results | Where-Object {
                        [string]$_.state -ceq 'deferred'
                    }).Count -gt 0) {
                'partial'
            } else { 'healthy' })
        providerWrites = $writes + $explanationWrites
        statusWrites = $writes
        explanationWrites = $explanationWrites
        unconfirmedStatusWrites = $unconfirmedStatusWrites
        unconfirmedExplanationWrites = $unconfirmedExplanationWrites
        unknownPossibleEffect =
            ($unconfirmedStatusWrites + $unconfirmedExplanationWrites) -gt 0
        providerReadCount = $(if (
            $null -ne $Provider.PSObject.Properties['StalePrBudget']
        ) { [int]$Provider.StalePrBudget.Count } else { $null })
        explanationReadCount = $(if (
            $null -ne $Provider.PSObject.Properties['StalePrBudget']
        ) { [int]$Provider.StalePrBudget.ExplanationCount } else { $null })
        modelWrites = 0
        confirmedAbandonedIds = $confirmed.ToArray()
        reviewEligibleIds = @(
            $reviewEligible |
                Sort-Object)
        nextPullRequestId = $nextPullRequestId
        decisions = $results.ToArray()
        events = $events.ToArray()
        explanationEvents = $explanationEvents.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Get-StalePrLifecycleConfiguration'
    'Initialize-StalePrLifecycleRoot'
    'Get-StalePrLifecycleKey'
    'New-StalePrLifecyclePolicy'
    'Write-StalePrLifecyclePolicy'
    'Read-StalePrLifecyclePolicy'
    'Assert-StalePrLifecyclePolicy'
    'New-StalePrAzureDevOpsProvider'
    'Invoke-StalePrLifecycle'
    'Resolve-StalePrLifecycleExplanation'
)
