Set-StrictMode -Version Latest

$script:OwnerPreviewQueueCapability = 'bpm-test-ownership@1'
$script:OwnerPreviewQueueMaximumEntries = 10
$script:OwnerPreviewQueueMaximumStarts = 3
$script:OwnerPreviewQueueMaximumSeconds = 3000

function ConvertTo-OwnerPreviewQueueMap {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $Value.Keys) { $map[[string]$key] = ConvertTo-OwnerPreviewQueueMap $Value[$key] }
        return $map
    }
    if ($Value -is [pscustomobject]) {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-OwnerPreviewQueueMap $property.Value
        }
        return $map
    }
    if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        return , @($Value | ForEach-Object { ConvertTo-OwnerPreviewQueueMap $_ })
    }
    return $Value
}

function Get-OwnerPreviewQueueValue {
    param(
        [Parameter(Mandatory)]$Container,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Default = $null
    )
    if ($Container -is [System.Collections.IDictionary]) {
        if ($Container.Contains($Name)) { return $Container[$Name] }
        return $Default
    }
    $property = $Container.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Assert-OwnerPreviewQueueSafePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Where)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw "$Where path '$Path' is not absolute." }
    if ($Path -match '[\x00-\x1f\x7f"]') { throw "$Where path contains a control character or quote." }
    return [IO.Path]::GetFullPath($Path)
}

function Resolve-OwnerPreviewQueueStateRoot {
    param([string]$StateRoot, [string]$InstanceName)
    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        if ([string]::IsNullOrWhiteSpace($InstanceName)) {
            throw '-StateRoot is required unless an explicit validated -InstanceName selects the LOCALAPPDATA default.'
        }
        if ($InstanceName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            throw "Instance name '$InstanceName' is invalid."
        }
        $base = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($base)) { throw 'LOCALAPPDATA is unavailable; supply an absolute -StateRoot.' }
        $StateRoot = Join-Path (Join-Path (Join-Path $base 'DevPilot') 'OwnerPreviewQueue') $InstanceName
    }
    $full = Assert-OwnerPreviewQueueSafePath -Path $StateRoot -Where 'State root'
    if ($full -match '(?i)[\\/]\.copilot[\\/]repos[\\/]copilot-worktrees(?:[\\/]|$)' -or
        (Test-OwnerPreviewPathInsideRepository -Path $full)) {
        throw "State root '$full' is inside git or a Copilot worktree; queue state and evidence must be external."
    }
    return $full
}

function Read-OwnerPreviewQueueConfig {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RepoRoot)
    $full = Assert-OwnerPreviewQueueSafePath -Path $Path -Where 'Queue configuration'
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Queue configuration '$full' does not exist." }
    $raw = Get-Content -LiteralPath $full -Raw -Encoding UTF8
    $schema = Get-Content -LiteralPath (Join-Path $RepoRoot 'src/Agents/reviewer/schemas/reviewer.owner-preview-queue.v1.json') -Raw
    $valid = $false
    try { $valid = Test-Json -Json $raw -Schema $schema -ErrorAction Stop } catch { $valid = $false }
    if (-not $valid) { throw "Queue configuration '$full' does not satisfy reviewer.owner-preview-queue.v1." }
    $config = ConvertTo-OwnerPreviewQueueMap ($raw | ConvertFrom-Json -Depth 64)
    if (@($config.entries).Count -gt $script:OwnerPreviewQueueMaximumEntries) {
        throw "Queue configuration has more than $script:OwnerPreviewQueueMaximumEntries entries."
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($config.entries)) {
        if ([string]$entry.capability -cne $script:OwnerPreviewQueueCapability) {
            throw "Every queue entry must name capability '$script:OwnerPreviewQueueCapability'."
        }
        [void](Assert-AgentSupportedModel -ModelId ([string]$entry.model) -Where 'Owner preview queue model')
        foreach ($name in @('configPath', 'agencyPath')) {
            $entry[$name] = Assert-OwnerPreviewQueueSafePath -Path ([string]$entry[$name]) -Where "Entry $name"
        }
        foreach ($name in @('promptPath', 'repositoryPath', 'offlineModelAdapterManifest')) {
            if ($entry.Contains($name)) {
                $entry[$name] = Assert-OwnerPreviewQueueSafePath -Path ([string]$entry[$name]) -Where "Entry $name"
                if (-not (Test-Path -LiteralPath $entry[$name] -PathType Leaf) -and $name -cne 'repositoryPath') {
                    throw "Entry $name '$($entry[$name])' does not exist."
                }
            }
        }
        if (-not (Test-Path -LiteralPath $entry.configPath -PathType Leaf)) {
            throw "Reviewer configuration '$($entry.configPath)' does not exist."
        }
        if (-not (Test-Path -LiteralPath $entry.agencyPath -PathType Leaf)) {
            throw "Agency executable '$($entry.agencyPath)' does not exist."
        }
        if ([string]$entry.sourceHeadMode -ceq 'fixed' -and -not $entry.Contains('expectedSourceHead')) {
            throw 'A fixed queue entry must name expectedSourceHead.'
        }
        $identity = "{0}/{1}/{2}#{3}" -f $entry.organization, $entry.project, $entry.repositoryId, $entry.pullRequestId
        if (-not $seen.Add($identity)) { throw "Queue subject '$identity' is declared more than once." }
    }
    $config.toolkitRoot = Assert-OwnerPreviewQueueSafePath -Path ([string]$config.toolkitRoot) -Where 'Toolkit'
    return $config
}

function Assert-OwnerPreviewQueueStableToolkit {
    param([Parameter(Mandatory)]$Config)
    $root = [string]$Config.toolkitRoot
    if ($root -match '(?i)[\\/]copilot-worktrees(?:[\\/]|$)') {
        throw "Toolkit '$root' is a linked or ephemeral Copilot worktree."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container)) {
        throw "Toolkit '$root' is not a stable ordinary checkout (.git must be a directory)."
    }
    Push-Location -LiteralPath $root
    try {
        $headOutput = @(& git rev-parse HEAD 2>&1)
        $headExit = $LASTEXITCODE
        $head = ([string[]]$headOutput -join [Environment]::NewLine).Trim().ToLowerInvariant()
        if ($headExit -ne 0 -or $head -cne ([string]$Config.expectedToolkitHead).ToLowerInvariant()) {
            throw "Toolkit head '$head' does not equal expected head $($Config.expectedToolkitHead)."
        }
        $refOutput = @(& git symbolic-ref -q HEAD 2>&1)
        $refExit = $LASTEXITCODE
        $ref = ([string[]]$refOutput -join [Environment]::NewLine).Trim()
        if ($refExit -ne 0 -or [string]::IsNullOrWhiteSpace($ref)) {
            throw "Toolkit '$root' is detached; scheduler deployment requires a named stable ref."
        }
        if ($ref -cne [string]$Config.expectedToolkitRef) {
            throw "Toolkit ref '$ref' does not equal expected ref $($Config.expectedToolkitRef)."
        }
    }
    finally { Pop-Location }
    return $true
}

function Get-OwnerPreviewQueueHmac {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][byte[]]$Key)
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([Convert]::ToHexString($hmac.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Get-OwnerPreviewQueueKey {
    param([Parameter(Mandatory)][string]$StateRoot)
    $keyRoot = Join-Path $StateRoot 'keys'
    [void](New-Item -ItemType Directory -Force -Path $keyRoot)
    $path = Join-Path $keyRoot 'ledger.key'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $recordPaths = @(
            (Join-Path $StateRoot 'ledger.json'),
            (Join-Path $StateRoot 'journals'),
            (Join-Path $StateRoot 'artifacts'),
            (Join-Path $StateRoot 'index')
        )
        if (@($recordPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) {
            throw 'The ledger key is missing while queue records exist; records are refused rather than re-keyed.'
        }
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $text = [Convert]::ToBase64String($bytes)
            $encoded = [Text.UTF8Encoding]::new($false).GetBytes($text)
            $stream.Write($encoded, 0, $encoded.Length)
        }
        finally { $stream.Dispose() }
    }
    $raw = (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
    try { $key = [Convert]::FromBase64String($raw) } catch { throw 'The ledger key is not canonical base64.' }
    if ($key.Length -lt 32 -or [Convert]::ToBase64String($key) -cne $raw) {
        throw 'The ledger key is invalid or non-canonical.'
    }
    return , $key
}

function Initialize-OwnerPreviewQueueLayerKeys {
    param([Parameter(Mandatory)][string]$StateRoot)
    $root = Join-Path (Join-Path $StateRoot 'keys') 'layer1'
    [void](New-Item -ItemType Directory -Force -Path $root)
    foreach ($definition in @(
            @{ Name = 'owner-preview-entry.key'; Prefix = 'raw:' },
            @{ Name = 'owner-preview-run-set.key'; Prefix = '' })) {
        $path = Join-Path $root $definition.Name
        if (Test-Path -LiteralPath $path -PathType Leaf) { continue }
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $text = [string]$definition.Prefix + [Convert]::ToBase64String($bytes)
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $encoded = [Text.UTF8Encoding]::new($false).GetBytes($text)
            $stream.Write($encoded, 0, $encoded.Length)
        }
        finally { $stream.Dispose() }
    }
    return $root
}

function Protect-OwnerPreviewQueuePayload {
    param([Parameter(Mandatory)]$Payload, [Parameter(Mandatory)][byte[]]$Key)
    # Sign the exact JSON-compatible shape Set-JsonState will persist, not live
    # PowerShell runtime types whose integer widths can change on round-trip.
    $normalized = ConvertTo-OwnerPreviewQueueMap (
        ($Payload | ConvertTo-Json -Depth 64 -Compress) | ConvertFrom-Json -Depth 64)
    $canonical = ConvertTo-AgentReplayCanonicalJson -Value $normalized
    return @{
        schemaVersion = 1
        kind = 'reviewer-owner-preview-signed-record'
        payload = $normalized
        hmac = Get-OwnerPreviewQueueHmac -Text $canonical -Key $Key
    }
}

function Read-OwnerPreviewQueueSignedFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Key)
    $envelopes = @(Get-JsonState -Path $Path -FailClosedOnCorruption)
    if ($envelopes.Count -eq 0 -or $null -eq $envelopes[0]) { throw "Signed queue record '$Path' is corrupt." }
    $envelope = $envelopes[0]
    if ($envelope.Count -eq 0) { return $null }
    if ([string]$envelope.kind -cne 'reviewer-owner-preview-signed-record') {
        throw "Queue record '$Path' has the wrong kind."
    }
    $payload = ConvertTo-OwnerPreviewQueueMap $envelope.payload
    $expected = Get-OwnerPreviewQueueHmac -Text (ConvertTo-AgentReplayCanonicalJson -Value $payload) -Key $Key
    if ([string]$envelope.hmac -cne $expected) { throw "Queue record '$Path' failed HMAC verification." }
    return $payload
}

function Write-OwnerPreviewQueueSignedFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Payload, [Parameter(Mandatory)][byte[]]$Key)
    $directory = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Force -Path $directory)
    $envelope = Protect-OwnerPreviewQueuePayload -Payload $Payload -Key $Key
    Set-JsonState -Path $Path -State $envelope
}

function Write-OwnerPreviewQueueImmutableRecord {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Payload, [Parameter(Mandatory)][byte[]]$Key)
    $directory = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Force -Path $directory)
    $envelope = Protect-OwnerPreviewQueuePayload -Payload $Payload -Key $Key
    $text = ConvertTo-AgentReplayCanonicalJson -Value $envelope
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]::ReadOnly)
}

function New-OwnerPreviewQueueLedger {
    return [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-owner-preview-ledger'
        sequence = 0
        intents = [ordered]@{}
        records = [ordered]@{}
        requeues = @()
    }
}

function Read-OwnerPreviewQueueLedger {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][byte[]]$Key)
    $path = Join-Path $StateRoot 'ledger.json'
    $ledger = Read-OwnerPreviewQueueSignedFile -Path $path -Key $Key
    if ($null -eq $ledger) {
        $priorEvidence = @(
            (Join-Path $StateRoot 'journals'),
            (Join-Path $StateRoot 'artifacts'),
            (Join-Path $StateRoot 'index'),
            (Join-Path $StateRoot 'cycles')
        )
        $quarantined = @(Get-ChildItem -LiteralPath $StateRoot -Filter 'ledger.json.corrupt-*' -ErrorAction SilentlyContinue)
        if ($quarantined.Count -gt 0 -or @($priorEvidence | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) {
            throw 'The signed ledger is absent while queue evidence exists; dedupe state is refused rather than reset.'
        }
        return New-OwnerPreviewQueueLedger
    }
    if ([string]$ledger.kind -cne 'reviewer-owner-preview-ledger') { throw 'The signed ledger has the wrong payload kind.' }
    return $ledger
}

function Save-OwnerPreviewQueueLedger {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$Ledger, [Parameter(Mandatory)][byte[]]$Key)
    Write-OwnerPreviewQueueSignedFile -Path (Join-Path $StateRoot 'ledger.json') -Payload $Ledger -Key $Key
}

function Add-OwnerPreviewQueueJournal {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)]$Ledger,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][string]$RecordKey,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)]$Detail
    )
    $Ledger.sequence = [int]$Ledger.sequence + 1
    $payload = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-owner-preview-journal-event'
        sequence = [int]$Ledger.sequence
        recordKey = $RecordKey
        state = $State
        createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        detail = $Detail
    }
    # Make the sequence durable before its immutable event appears. A process
    # death can leave a ledger without the event, but never an event whose
    # sequence the ledger will accidentally reuse.
    Save-OwnerPreviewQueueLedger -StateRoot $StateRoot -Ledger $Ledger -Key $Key
    $name = '{0:d8}-{1}.json' -f [int]$Ledger.sequence, [guid]::NewGuid().ToString('N')
    Write-OwnerPreviewQueueImmutableRecord -Path (Join-Path (Join-Path $StateRoot 'journals') (Join-Path $RecordKey $name)) `
        -Payload $payload -Key $Key
    return $payload
}

function Get-OwnerPreviewQueueRuleSections {
    param([Parameter(Mandatory)]$Entry)
    $sections = Get-OwnerPreviewRuleSections -ConfigFile ([string]$Entry.configPath) `
        -RuleCommit ([string]$Entry.authoritativeRuleCommit)
    return , @($sections)
}

function Get-OwnerPreviewQueueIntent {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)]$Config)
    $prompt = if ($Entry.Contains('promptPath')) { [string]$Entry.promptPath } else {
        Join-Path ([string]$Config.toolkitRoot) 'src/Agents/reviewer/review-cycle.prompt.md'
    }
    $scriptPath = Join-Path ([string]$Config.toolkitRoot) 'src/Agents/reviewer/Start-ReviewerAgent.ps1'
    $supportedModels = Get-AgentSupportedModels
    $registry = [ordered]@{ supportedModels = @($supportedModels) }
    $ruleSections = Get-OwnerPreviewQueueRuleSections -Entry $Entry
    $material = [ordered]@{
        capability = $script:OwnerPreviewQueueCapability
        subject = [ordered]@{
            organization = [string]$Entry.organization
            project = [string]$Entry.project
            repositoryId = [string]$Entry.repositoryId
            repositoryName = [string]$Entry.repositoryName
            pullRequestId = [int]$Entry.pullRequestId
            targetRefName = [string]$Entry.targetRefName
            sourceHeadMode = [string]$Entry.sourceHeadMode
            expectedSourceHead = [string](Get-OwnerPreviewQueueValue $Entry 'expectedSourceHead' '')
        }
        rules = @($ruleSections)
        model = [string]$Entry.model
        modelRegistrySha256 = Get-OwnerPreviewCanonicalSha256 -Value $registry
        configSha256 = Get-OwnerPreviewFileSha256 -Path ([string]$Entry.configPath)
        promptSha256 = Get-OwnerPreviewFileSha256 -Path $prompt
        scriptSha256 = Get-OwnerPreviewFileSha256 -Path $scriptPath
        offlineAdapterSha256 = $(if ($Entry.Contains('offlineModelAdapterManifest')) {
                Get-OwnerPreviewFileSha256 -Path ([string]$Entry.offlineModelAdapterManifest)
            }
            else { '' })
        toolkitHead = ([string]$Config.expectedToolkitHead).ToLowerInvariant()
    }
    return [pscustomobject]@{
        Key = Get-OwnerPreviewCanonicalSha256 -Value $material
        Material = $material
        PromptPath = $prompt
    }
}

function Get-OwnerPreviewQueueHeadKey {
    param([Parameter(Mandatory)]$Intent, [Parameter(Mandatory)]$Subject)
    $material = [ordered]@{
        capability = $script:OwnerPreviewQueueCapability
        subject = [ordered]@{
            organization = [string]$Subject.subject.organization
            project = [string]$Subject.subject.project
            repositoryId = [string]$Subject.subject.repositoryId
            repositoryName = [string]$Subject.subject.repositoryName
            pullRequestId = [int]$Subject.subject.pullRequestId
            sourceCommit = [string]$Subject.subject.sourceCommit
            targetCommit = [string]$Subject.subject.targetCommit
            targetRefName = [string]$Subject.subject.targetRefName
        }
        rules = @($Intent.Material.rules)
        modelRegistrySha256 = [string]$Intent.Material.modelRegistrySha256
        model = [string]$Intent.Material.model
        configSha256 = [string]$Intent.Material.configSha256
        promptSha256 = [string]$Intent.Material.promptSha256
        scriptSha256 = [string]$Intent.Material.scriptSha256
        offlineAdapterSha256 = [string]$Intent.Material.offlineAdapterSha256
        replayManifestDigest = [string]$Subject.snapshot.manifestDigest
        toolkitHead = [string]$Intent.Material.toolkitHead
    }
    return Get-OwnerPreviewCanonicalSha256 -Value $material
}

function Invoke-OwnerPreviewQueueCycleDriver {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Intent,
        [Parameter(Mandatory)][string]$CycleRoot,
        [Parameter(Mandatory)][scriptblock]$BeforeLaunch
    )
    $nonce = [guid]::NewGuid().ToString('N')
    $readyPath = Join-Path $CycleRoot 'prelaunch-ready.json'
    $permitPath = Join-Path $CycleRoot 'prelaunch-permit.json'
    $subjectRoot = Join-Path $CycleRoot 'evidence'
    $stateRoot = Split-Path (Split-Path (Split-Path $CycleRoot -Parent) -Parent) -Parent
    $layerKeyRoot = Initialize-OwnerPreviewQueueLayerKeys -StateRoot $stateRoot
    [void](New-Item -ItemType Directory -Force -Path $CycleRoot)
    $tool = Join-Path ([string]$Config.toolkitRoot) 'tools/Invoke-OwnerPreviewCycle.ps1'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $tool,
        '-Action', 'prepare-run', '-SubjectRoot', $subjectRoot,
        '-PullRequestId', [string][int]$Entry.pullRequestId,
        '-Organization', [string]$Entry.organization, '-Project', [string]$Entry.project,
        '-RepositoryId', [string]$Entry.repositoryId, '-RepositoryName', [string]$Entry.repositoryName,
        '-TargetRefName', [string]$Entry.targetRefName, '-RuleCommit', [string]$Entry.authoritativeRuleCommit,
        '-ConfigFile', [string]$Entry.configPath, '-Model', [string]$Entry.model,
        '-ToolkitRoot', [string]$Config.toolkitRoot, '-ToolkitRequiredRef', [string]$Config.expectedToolkitRef,
        '-ExpectedReviewerBaseCommit', [string]$Entry.expectedReviewerBaseCommit,
        '-CaptureMode', 'live', '-AgencyPath', [string]$Entry.agencyPath,
        '-SealKeyRoot', $layerKeyRoot,
        '-PrelaunchReadyPath', $readyPath, '-PrelaunchPermitPath', $permitPath,
        '-PrelaunchNonce', $nonce, '-PrelaunchTimeoutSeconds', '120'
    )
    if ($Entry.Contains('expectedSourceHead')) { $arguments += @('-ExpectedSourceCommit', [string]$Entry.expectedSourceHead) }
    if ($Entry.Contains('sourceRefName')) { $arguments += @('-SourceRefName', [string]$Entry.sourceRefName) }
    if ($Entry.Contains('repositoryPath')) { $arguments += @('-RepositoryPath', [string]$Entry.repositoryPath) }
    if ($Entry.Contains('promptPath')) { $arguments += @('-PromptFile', [string]$Entry.promptPath) }
    if ($Entry.Contains('offlineModelAdapterManifest')) {
        $arguments += @(
            '-UseOfflineStubAdapter',
            '-OfflineModelAdapterManifest', [string]$Entry.offlineModelAdapterManifest
        )
    }

    $start = [DateTime]::UtcNow
    $deadline = $start.AddSeconds($script:OwnerPreviewQueueMaximumSeconds)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [string](Get-Process -Id $PID).Path
    $info.UseShellExecute = $false
    foreach ($argument in $arguments) { [void]$info.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'The Owner preview prepare-run process did not start.' }
    try {
        while (-not $process.HasExited -and -not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            if ([DateTime]::UtcNow -ge $deadline) {
                Stop-ProcessTree -Process $process
                throw 'The queue cycle exceeded its 50-minute wall budget before prelaunch.'
            }
            Start-Sleep -Milliseconds 200
        }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            return [pscustomobject]@{ Ready = $null; Status = $null; ExitCode = $process.ExitCode; DurationMs = [int]([DateTime]::UtcNow - $start).TotalMilliseconds }
        }
        $ready = Get-Content -LiteralPath $readyPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 16
        if ([string]$ready.kind -cne 'reviewer-owner-preview-prelaunch-ready' -or [string]$ready.nonce -cne $nonce) {
            throw 'The Layer 1 prelaunch record did not bind this queue invocation.'
        }
        $subject = Read-OwnerPreviewSubject -Root $subjectRoot -HeadKey ([string]$ready.headKey)
        & $BeforeLaunch $ready $subject
        [void](Write-OwnerPreviewJsonFile -Path $permitPath -Value ([ordered]@{
                    schemaVersion = 1
                    kind = 'reviewer-owner-preview-prelaunch-permit'
                    nonce = $nonce
                    headKey = [string]$ready.headKey
                }))
        $remaining = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $process.WaitForExit($remaining)) {
            Stop-ProcessTree -Process $process
            throw 'The queue cycle exceeded its 50-minute wall budget.'
        }
        $statusPath = Join-Path (Join-Path (Join-Path $subjectRoot 'runs') ([string]$ready.headKey)) 'owner-preview-status.json'
        $status = if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64 -AsHashtable
        }
        else { $null }
        return [pscustomobject]@{
            Ready = $ready
            Subject = $subject
            Status = $status
            ExitCode = $process.ExitCode
            DurationMs = [int]([DateTime]::UtcNow - $start).TotalMilliseconds
            SubjectRoot = $subjectRoot
        }
    }
    finally { $process.Dispose() }
}

function Set-OwnerPreviewQueueArtifact {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$HeadKey,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $artifact = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-owner-preview-queue-artifact'
        capability = $script:OwnerPreviewQueueCapability
        headKey = $HeadKey
        attempt = $Attempt
        subjectRoot = [string]$Result.SubjectRoot
        statusSha256 = Get-OwnerPreviewFileSha256 -Path (Join-Path (Join-Path (Join-Path $Result.SubjectRoot 'runs') ([string]$Result.Ready.headKey)) 'owner-preview-status.json')
        createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    }
    $path = Join-Path (Join-Path $StateRoot 'artifacts') (Join-Path $HeadKey ("attempt-{0:d3}.json" -f $Attempt))
    Write-OwnerPreviewQueueImmutableRecord -Path $path -Payload $artifact -Key $Key
    return $path
}

function Publish-OwnerPreviewQueueIndex {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$Ledger, [Parameter(Mandatory)][byte[]]$Key)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($recordKey in @($Ledger.records.Keys | Sort-Object -CaseSensitive)) {
        $record = $Ledger.records[$recordKey]
        [void]$rows.Add([ordered]@{
                headKey = $recordKey
                capability = $script:OwnerPreviewQueueCapability
                state = [string]$record.state
                subject = $record.subject
                rule = $record.rule
                terminal = $record.terminal
                counts = $record.counts
                attempts = [int]$record.attempts
                modelAttempts = [int]$record.modelAttempts
                startCount = [int]$record.startCount
                latencyMs = [int]$record.latencyMs
                providerWriteCount = [int]$record.providerWriteCount
                writeToolInvocations = [int]$record.writeToolInvocations
                generalistModelStarts = [int]$record.generalistModelStarts
                artifact = [string](Get-OwnerPreviewQueueValue $record 'artifact' '')
            })
    }
    $index = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-owner-preview-queue-index'
        capability = $script:OwnerPreviewQueueCapability
        generatedUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        records = $rows.ToArray()
    }
    $indexRoot = Join-Path $StateRoot 'index'
    Write-OwnerPreviewQueueSignedFile -Path (Join-Path $indexRoot 'current.json') -Payload $index -Key $Key
    $historyName = '{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'), [guid]::NewGuid().ToString('N')
    Write-OwnerPreviewQueueImmutableRecord -Path (Join-Path (Join-Path $indexRoot 'history') $historyName) `
        -Payload $index -Key $Key
    return $index
}

function Repair-OwnerPreviewQueueInterrupted {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$Ledger, [Parameter(Mandatory)][byte[]]$Key)
    foreach ($headKey in @($Ledger.records.Keys)) {
        $record = $Ledger.records[$headKey]
        if ([string]$record.state -cne 'running') { continue }
        $record.state = 'incomplete'
        $record.terminal = [ordered]@{ status = 'incomplete'; markerStatus = 'interruptedUnknown' }
        $record.latencyMs = 0
        $intentKey = [string]$record.intentKey
        if ($Ledger.intents.Contains($intentKey)) {
            $intent = $Ledger.intents[$intentKey]
            $intent.state = 'incomplete'
            $Ledger.intents[$intentKey] = $intent
        }
        [void](Add-OwnerPreviewQueueJournal -StateRoot $StateRoot -Ledger $Ledger -Key $Key -RecordKey $headKey `
                -State 'incomplete' -Detail ([ordered]@{ markerStatus = 'interruptedUnknown'; modelStarts = 'unknown' }))
    }
}

function Invoke-OwnerPreviewQueueTick {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$StateRoot)
    $key = Get-OwnerPreviewQueueKey -StateRoot $StateRoot
    $ledger = Read-OwnerPreviewQueueLedger -StateRoot $StateRoot -Key $key
    Repair-OwnerPreviewQueueInterrupted -StateRoot $StateRoot -Ledger $ledger -Key $key
    Save-OwnerPreviewQueueLedger -StateRoot $StateRoot -Ledger $ledger -Key $key

    $selected = $null
    $selectedIntent = $null
    foreach ($entry in @($Config.entries)) {
        $intent = Get-OwnerPreviewQueueIntent -Entry $entry -Config $Config
        if ($ledger.intents.Contains($intent.Key)) {
            $known = $ledger.intents[$intent.Key]
            if ([string]$known.state -cne 'pending') { continue }
        }
        $selected = $entry
        $selectedIntent = $intent
        break
    }
    if ($null -eq $selected) {
        $index = Publish-OwnerPreviewQueueIndex -StateRoot $StateRoot -Ledger $ledger -Key $key
        return [ordered]@{ action = 'run'; outcome = 'noEligibleEntry'; processed = 0; index = $index }
    }

    $priorIntent = Get-OwnerPreviewQueueValue $ledger.intents $selectedIntent.Key $null
    $attempt = if ($null -eq $priorIntent) { 1 } else { [int]$priorIntent.attempts + 1 }
    $cycleRoot = Join-Path (Join-Path $StateRoot 'cycles') (Join-Path $selectedIntent.Key ("attempt-{0:d3}" -f $attempt))
    $context = [ordered]@{ HeadKey = ''; Record = $null }
    $beforeLaunch = {
        param($ready, $subject)
        $headKey = Get-OwnerPreviewQueueHeadKey -Intent $selectedIntent -Subject $subject
        if ($ledger.records.Contains($headKey) -and [string]$ledger.records[$headKey].state -cne 'pending') {
            throw "Head '$headKey' already has a terminal or running record; duplicate spend was refused."
        }
        $record = if ($ledger.records.Contains($headKey)) { $ledger.records[$headKey] } else {
            [ordered]@{
                state = 'pending'
                intentKey = $selectedIntent.Key
                subject = $subject.subject
                rule = @($selectedIntent.Material.rules)[0]
                terminal = [ordered]@{ status = 'pending'; markerStatus = 'notStarted' }
                counts = [ordered]@{ checked = 0; violations = 0; unknown = 0; notInReach = 0; notRouted = 0 }
                attempts = 0
                modelAttempts = 0
                startCount = 0
                latencyMs = 0
                providerWriteCount = 0
                writeToolInvocations = 0
                generalistModelStarts = 0
            }
        }
        $record.attempts = $attempt
        $record.state = 'pending'
        [void](Add-OwnerPreviewQueueJournal -StateRoot $StateRoot -Ledger $ledger -Key $key -RecordKey $headKey `
                -State 'pending' -Detail ([ordered]@{ intentKey = $selectedIntent.Key; attempt = $attempt }))
        $record.state = 'running'
        $record.terminal = [ordered]@{ status = 'running'; markerStatus = 'modelStartReserved' }
        $record.startCount = $script:OwnerPreviewQueueMaximumStarts
        $ledger.records[$headKey] = $record
        $ledger.intents[$selectedIntent.Key] = [ordered]@{ headKey = $headKey; state = 'running'; attempts = $attempt }
        [void](Add-OwnerPreviewQueueJournal -StateRoot $StateRoot -Ledger $ledger -Key $key -RecordKey $headKey `
                -State 'running' -Detail ([ordered]@{ attempt = $attempt; maximumChargedStarts = $script:OwnerPreviewQueueMaximumStarts }))
        Save-OwnerPreviewQueueLedger -StateRoot $StateRoot -Ledger $ledger -Key $key
        $context.HeadKey = $headKey
        $context.Record = $record
    }

    $result = $null
    $failure = ''
    try {
        if ($null -ne $script:OwnerPreviewQueueTestDriver) {
            $result = & $script:OwnerPreviewQueueTestDriver $selected $Config $selectedIntent $cycleRoot $beforeLaunch
        }
        else {
            $result = Invoke-OwnerPreviewQueueCycleDriver -Entry $selected -Config $Config -Intent $selectedIntent `
                -CycleRoot $cycleRoot -BeforeLaunch $beforeLaunch
        }
    }
    catch { $failure = [string]$_.Exception.Message }

    if ([string]::IsNullOrWhiteSpace([string]$context.HeadKey)) {
        $ledger.intents[$selectedIntent.Key] = [ordered]@{
            headKey = ''
            state = 'blocked'
            attempts = $attempt
            diagnostic = $(if ($failure -ne '') { $failure } else { 'Layer 1 refused before a bound head reached prelaunch.' })
        }
        [void](Add-OwnerPreviewQueueJournal -StateRoot $StateRoot -Ledger $ledger -Key $key -RecordKey $selectedIntent.Key `
                -State 'blocked' -Detail $ledger.intents[$selectedIntent.Key])
        Save-OwnerPreviewQueueLedger -StateRoot $StateRoot -Ledger $ledger -Key $key
        $index = Publish-OwnerPreviewQueueIndex -StateRoot $StateRoot -Ledger $ledger -Key $key
        return [ordered]@{ action = 'run'; outcome = 'blocked'; processed = 1; diagnostic = $ledger.intents[$selectedIntent.Key].diagnostic; index = $index }
    }

    $record = $ledger.records[$context.HeadKey]
    $status = if ($null -ne $result) { $result.Status } else { $null }
    if ($null -eq $status) {
        $record.state = 'incomplete'
        $record.terminal = [ordered]@{
            status = 'incomplete'
            markerStatus = $(if ($failure -ne '') { 'interruptedUnknown' } else { 'absent' })
            diagnostic = $failure
        }
    }
    else {
        $statusSchema = Get-Content -LiteralPath (Join-Path ([string]$Config.toolkitRoot) `
                'src/Agents/reviewer/schemas/reviewer.owner-preview-status.v1.json') -Raw
        $statusValid = $false
        try {
            $statusJson = $status | ConvertTo-Json -Depth 64 -Compress
            $statusValid = Test-Json -Json $statusJson `
                -Schema $statusSchema -ErrorAction Stop
        }
        catch { $statusValid = $false }
        if (-not $statusValid) {
            $record.state = 'blocked'
            $record.terminal = [ordered]@{ status = 'blocked'; markerStatus = 'invalidStatusEvidence' }
            $record.latencyMs = if ($null -ne $result) { [int]$result.DurationMs } else { 0 }
            $ledger.records[$context.HeadKey] = $record
            $ledger.intents[$selectedIntent.Key] = [ordered]@{
                headKey = $context.HeadKey; state = 'blocked'; attempts = $attempt
            }
            [void](Add-OwnerPreviewQueueJournal -StateRoot $StateRoot -Ledger $ledger -Key $key `
                    -RecordKey $context.HeadKey -State 'blocked' `
                    -Detail ([ordered]@{ markerStatus = 'invalidStatusEvidence' }))
            Save-OwnerPreviewQueueLedger -StateRoot $StateRoot -Ledger $ledger -Key $key
            $index = Publish-OwnerPreviewQueueIndex -StateRoot $StateRoot -Ledger $ledger -Key $key
            return [ordered]@{
                action = 'run'; outcome = 'blocked'; processed = 1; headKey = $context.HeadKey; index = $index
            }
        }
        $record.terminal = ConvertTo-OwnerPreviewQueueMap $status.terminal
        $record.counts = [ordered]@{
            checked = [int]$status.counts.checked
            violations = [int]$status.counts.violations
            unknown = [int]$status.counts.unknown
            notInReach = [int](Get-OwnerPreviewQueueValue $status.counts 'notInReach' 0)
            notRouted = [int](Get-OwnerPreviewQueueValue $status.counts 'notRouted' 0)
        }
        $record.startCount = [int]$status.spend.modelStarts
        $record.modelAttempts = [int](Get-OwnerPreviewQueueValue $status.spend 'attempts' $record.startCount)
        $record.providerWriteCount = [int]$status.spend.providerWriteCount
        $record.writeToolInvocations = [int]$status.spend.writeToolInvocations
        $record.generalistModelStarts = [int]$status.spend.generalistModelStarts
        if ($record.startCount -gt $script:OwnerPreviewQueueMaximumStarts -or
            $record.providerWriteCount -ne 0 -or $record.writeToolInvocations -ne 0 -or
            $record.generalistModelStarts -ne 0) {
            $record.state = 'blocked'
            $record.terminal = [ordered]@{ status = 'blocked'; markerStatus = 'budgetEvidence' }
        }
        else { $record.state = [string]$status.terminal.status }
        if ($null -ne $result.SubjectRoot) {
            $record.artifact = Set-OwnerPreviewQueueArtifact -StateRoot $StateRoot -HeadKey $context.HeadKey `
                -Attempt $attempt -Result $result -Key $key
        }
    }
    $record.latencyMs = if ($null -ne $result) { [int]$result.DurationMs } else { 0 }
    $ledger.records[$context.HeadKey] = $record
    $ledger.intents[$selectedIntent.Key] = [ordered]@{
        headKey = $context.HeadKey
        state = [string]$record.state
        attempts = $attempt
    }
    [void](Add-OwnerPreviewQueueJournal -StateRoot $StateRoot -Ledger $ledger -Key $key -RecordKey $context.HeadKey `
            -State ([string]$record.state) -Detail ([ordered]@{
                terminal = $record.terminal
                starts = $record.startCount
                providerWrites = $record.providerWriteCount
                writeToolInvocations = $record.writeToolInvocations
                generalistModelStarts = $record.generalistModelStarts
                latencyMs = $record.latencyMs
            }))
    Save-OwnerPreviewQueueLedger -StateRoot $StateRoot -Ledger $ledger -Key $key
    $index = Publish-OwnerPreviewQueueIndex -StateRoot $StateRoot -Ledger $ledger -Key $key
    return [ordered]@{ action = 'run'; outcome = [string]$record.state; processed = 1; headKey = $context.HeadKey; index = $index }
}

function Invoke-OwnerPreviewQueueRequeue {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$HeadKey,
        [Parameter(Mandatory)][string]$Reason
    )
    if ($HeadKey -notmatch '^[0-9a-f]{64}$') { throw 'Requeue HeadKey must be 64 lowercase hexadecimal characters.' }
    if ([string]::IsNullOrWhiteSpace($Reason) -or $Reason.Length -gt 1024 -or $Reason -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') {
        throw 'Requeue Reason must be 1-1024 printable characters.'
    }
    $key = Get-OwnerPreviewQueueKey -StateRoot $StateRoot
    $ledger = Read-OwnerPreviewQueueLedger -StateRoot $StateRoot -Key $key
    if (-not $ledger.records.Contains($HeadKey)) { throw "No ledger record exists for head '$HeadKey'." }
    $record = $ledger.records[$HeadKey]
    if ([string]$record.state -ceq 'running' -or [string]$record.state -ceq 'pending') {
        throw "Head '$HeadKey' is already $($record.state)."
    }
    $audit = [ordered]@{
        headKey = $HeadKey
        priorState = [string]$record.state
        reason = $Reason
        createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    }
    $ledger.requeues = @($ledger.requeues) + @($audit)
    $record.state = 'pending'
    $record.terminal = [ordered]@{ status = 'pending'; markerStatus = 'auditedRequeue' }
    $ledger.records[$HeadKey] = $record
    $intent = $ledger.intents[[string]$record.intentKey]
    $intent.state = 'pending'
    $ledger.intents[[string]$record.intentKey] = $intent
    [void](Add-OwnerPreviewQueueJournal -StateRoot $StateRoot -Ledger $ledger -Key $key -RecordKey $HeadKey `
            -State 'pending' -Detail $audit)
    Save-OwnerPreviewQueueLedger -StateRoot $StateRoot -Ledger $ledger -Key $key
    [void](Publish-OwnerPreviewQueueIndex -StateRoot $StateRoot -Ledger $ledger -Key $key)
    return $audit
}

function Get-OwnerPreviewQueueTaskPlan {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$ConfigFile, [Parameter(Mandatory)][string]$StateRoot)
    $taskName = "DevPilotOwnerPreview-$($Config.instanceName)"
    $scriptPath = Join-Path ([string]$Config.toolkitRoot) 'tools/Invoke-OwnerPreviewQueue.ps1'
    foreach ($value in @($taskName, $scriptPath, $ConfigFile, $StateRoot)) {
        if ([string]$value -match '[\x00-\x1f\x7f"]') { throw 'Task name or action value contains an unsafe character.' }
    }
    $arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -Action run -ConfigFile "{1}" -StateRoot "{2}"' -f `
        $scriptPath, $ConfigFile, $StateRoot
    return [ordered]@{
        taskName = $taskName
        execute = [string](Get-Process -Id $PID).Path
        workingDirectory = [string]$Config.toolkitRoot
        arguments = $arguments
        principal = [ordered]@{
            userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            logonType = 'Interactive'
            runLevel = 'Limited'
        }
        trigger = [ordered]@{ intervalMinutes = 60 }
        settings = [ordered]@{ multipleInstances = 'IgnoreNew'; executionTimeLimitMinutes = 55 }
    }
}

$script:OwnerPreviewQueueTestDriver = $null
