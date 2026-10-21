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
    if (-not [DateTime]::TryParse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor
                [Globalization.DateTimeStyles]::AdjustToUniversal,
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
        [ValidateRange(1, 2)][int]$MaxAbandonsPerRun = 2,
        [Parameter(DontShow)][switch]$AllowDirty,
        [string]$CreatedUtc =
            ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
    )
    return [ordered]@{
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
    return ''
}

function New-StalePrAzureDevOpsProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Config,
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
        $configuredReadCeilings |
            Measure-Object -Minimum).
        Minimum
    $maximumSeconds = [int]$Config.limits.maxSeconds
    $getUtcNow = if ($null -ne $UtcNowProvider) {
        [scriptblock]$UtcNowProvider
    }
    else {
        { [DateTime]::UtcNow }
    }
    $runBudget = [pscustomobject]@{
        Count = 0
        DeadlineUtc = (& $getUtcNow).
            AddSeconds($maximumSeconds)
    }
    $convertUtcCommand =
        ${function:ConvertTo-StalePrUtc}
    $digestCommand =
        ${function:Get-StalePrDigest}
    $failureReasonCommand =
        ${function:Get-StalePrFailureReason}
    $canonicalJsonCommand =
        ${function:ConvertTo-ApprovedOwnerV2CanonicalJson}
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
    $getAccessToken = {
        if (-not [string]::IsNullOrWhiteSpace(
                [string]$tokenState.AccessToken)) {
            return [string]$tokenState.AccessToken
        }
        $response = if ($null -ne $TokenInvoker) {
            & $TokenInvoker
        }
        else {
            [void][Environment]::SetEnvironmentVariable(
                'AZURE_DEVOPS_EXT_PAT', $null,
                [EnvironmentVariableTarget]::Process)
            [void][Environment]::SetEnvironmentVariable(
                'SYSTEM_ACCESSTOKEN', $null,
                [EnvironmentVariableTarget]::Process)
            $output = @(& $AzureCliPath `
                account get-access-token `
                --resource `
                    499b84ac-1321-427f-aa17-267ca6975798 `
                --only-show-errors -o json 2>$null)
            if ($LASTEXITCODE -ne 0) {
                throw 'stale-pr-token-unavailable'
            }
            ($output -join "`n") |
                ConvertFrom-Json -AsHashtable -Depth 16
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
            [ValidateSet('GET', 'PATCH')]
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
            throw 'stale-pr-read-budget-exhausted'
        }
        if ((& $getUtcNow) -ge
            [DateTime]$Budget.DeadlineUtc) {
            throw 'stale-pr-deadline-exhausted'
        }
        if ($Method -ceq 'GET') {
            $Budget.Count++
        }
        $token = & $getAccessToken
        $afterTokenUtc = & $getUtcNow
        if ($afterTokenUtc -ge
            [DateTime]$Budget.DeadlineUtc) {
            throw 'stale-pr-deadline-exhausted'
        }
        $remaining =
            ([DateTime]$Budget.DeadlineUtc -
                $afterTokenUtc).TotalSeconds
        if ($remaining -le 0) {
            throw 'stale-pr-deadline-exhausted'
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
        if ($Method -ceq 'PATCH') {
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
            if ($null -ne $_.Exception.Response) {
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
        if ((& $getUtcNow) -ge
            [DateTime]$Budget.DeadlineUtc) {
            throw 'stale-pr-deadline-exhausted'
        }
        if ($response -is [Collections.IDictionary]) {
            return $response
        }
        if ([long]$response.RawContentLength -lt 0 -or
            [long]$response.RawContentLength -gt 16777216) {
            throw 'stale-pr-read-budget-exhausted'
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
        $activity = [Collections.Generic.List[object]]::new()
        foreach ($iteration in $orderedIterations) {
            foreach ($name in @('createdDate', 'updatedDate')) {
                if ([string]::IsNullOrWhiteSpace(
                        [string]$iteration[$name])) {
                    throw 'stale-pr-iteration-time-unknown'
                }
                [void]$activity.Add([ordered]@{
                        kind = "iteration-$name"
                        iterationId = [int]$iteration.id
                        occurredUtc = (
                            & $convertUtcCommand `
                                -Value ([string]$iteration[$name]) `
                                -Name $name).ToString('o')
                    })
            }
            if ($null -ne $iteration.push) {
                $pushId = [long]$iteration.push.pushId
                if ($pushId -lt 1) {
                    throw 'stale-pr-push-time-unknown'
                }
                $pushDate = [string]$iteration.push.date
                if ([string]::IsNullOrWhiteSpace($pushDate)) {
                    $pushKey = [string]$pushId
                    if ($pushDates.ContainsKey($pushKey)) {
                        $pushDate = [string]$pushDates[$pushKey]
                    }
                    else {
                        try {
                            $push = & $readPush $pushId $runBudget
                        }
                        catch {
                            $pushFailure =
                                & $failureReasonCommand $_
                            if ($pushFailure -cin @(
                                    'stale-pr-read-budget-exhausted',
                                    'stale-pr-deadline-exhausted')) {
                                throw $pushFailure
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
                        $pushDate = [string]$push.date
                        $pushDates[$pushKey] = $pushDate
                    }
                }
                try {
                    $pushUtc = & $convertUtcCommand `
                        -Value $pushDate -Name pushDate
                }
                catch {
                    throw 'stale-pr-push-time-unknown'
                }
                [void]$activity.Add([ordered]@{
                        kind = 'source-push'
                        iterationId = [int]$iteration.id
                        pushId = $pushId
                        occurredUtc = $pushUtc.ToString('o')
                    })
            }
        }
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
                    [void]$activity.Add([ordered]@{
                            kind = $(if (
                                [int]$comment.parentCommentId -gt 0
                            ) { "reply-$name" } else {
                                "comment-$name"
                            })
                            threadId = [long]$thread.id
                            commentId = [long]$comment.id
                            occurredUtc = (
                                & $convertUtcCommand `
                                    -Value ([string]$comment[$name]) `
                                    -Name $name).ToString('o')
                        })
                }
            }
        }
        $activityTimes = @($activity |
            ForEach-Object {
                & $convertUtcCommand `
                    -Value ([string]$_.occurredUtc) `
                    -Name activityUtc
            })
        $creationUtc = & $convertUtcCommand `
            -Value ([string]$pr.creationDate) `
            -Name creationDate
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
            default {
                throw "Unsupported stale PR operation '$Operation'."
            }
        }
    }.GetNewClosure()
    return $handler
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
    $events = [Collections.Generic.List[object]]::new()
    $writes = 0
    $unknown = 0
    foreach ($item in @($Inventory | Sort-Object {
                [long]$_.pullRequestId
            } | Select-Object -First (
                [int]$Policy.authority.maxCandidatesPerRun))) {
        $id = [long]$item.pullRequestId
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
                    })
                break
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
            [int]$Policy.authority.maxAbandonsPerRun) {
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'deferred'
                    reason = 'run-cap-reached'
                    providerWrites = 0
                })
            continue
        }
        try {
            $evidence = & $Provider ReadEvidence @{
                pullRequestId = $id
            }
            Assert-StalePrEvidence `
                -Evidence $evidence -Policy $Policy
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
                    })
                break
            }
            $unknown++
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'unknown'
                    reason = 'activity-evidence-unknown'
                    providerWrites = 0
                })
            continue
        }
        if (-not [bool]$evidence.complete) {
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
                [string]$Policy.scope.targetRef -or
            (ConvertTo-StalePrUtc `
                -Value ([string]$evidence.creationUtc) `
                -Name creationUtc) -ge $CutoffUtc -or
            (ConvertTo-StalePrUtc `
                -Value ([string]$evidence.latestActivityUtc) `
                -Name latestActivityUtc) -gt $CutoffUtc) {
            continue
        }
        $decisionDigest = Get-StalePrDigest (
            Get-StalePrEvidenceBinding $evidence)
        try {
            $prewrite = & $Provider ReadEvidence @{
                pullRequestId = $id
            }
            Assert-StalePrEvidence `
                -Evidence $prewrite -Policy $Policy
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
                    })
                break
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
            [void]$confirmed.Add($id)
            [void]$results.Add([ordered]@{
                    pullRequestId = $id
                    state = 'abandoned'
                    reason = 'readback-confirmed'
                    providerWrites = 1
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
        providerWrites = $writes
        modelWrites = 0
        confirmedAbandonedIds = $confirmed.ToArray()
        decisions = $results.ToArray()
        events = $events.ToArray()
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
)
