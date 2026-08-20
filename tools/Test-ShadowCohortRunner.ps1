#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline suite for the sequential typed shadow cohort runner: a three-entry
    cohort with a success, an unsuccessful run and a fault, both stop policies,
    kill and restart at a cohort transition, the child fault matrix, global budget
    exhaustion, every identity refusal, and the rebuildable audit index.

.DESCRIPTION
    Everything here runs offline. No model is started, no provider is contacted,
    and nothing is written outside a temporary sandbox.

    The ENTRIES are stubbed and the RUNNER is not. That split is deliberate and it
    is the opposite way round from the single-run suite. What a cohort adds over a
    single preparation is entirely about accounting across processes - committing
    an intent before a child exists, refusing to reopen an entry that ended,
    admitting the next entry against a global ceiling, and surviving being killed
    between entries - and none of that is exercised by how faithfully the child
    reviews anything. A suite that ran the real preparation per entry would spend
    minutes proving what the single-run suite already proves and would still not
    be able to kill a runner at a chosen instant.

    So each entry is started as a real child process, against a real typed
    request that the real loader validates, writing a real audit that the real
    summary reader parses; the child simply reaches its outcome by reading a
    control file instead of by reviewing anything. The runner under test is the
    shipping runner, with no test mode.

    ONE scenario is the exception: the last one runs a real preparation, driven
    only as far as a snapshot state so no model is started, because the signing
    key a real preparation writes is the one thing a stub cannot stand in for.

.PARAMETER RepoRoot
    The toolkit under test. Defaults to this script's repository.

.PARAMETER KeepSandbox
    Leave the sandbox in place for inspection after the run.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$KeepSandbox
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Checks = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:PwshPath = (Get-Process -Id $PID).Path
$script:CohortDll = $null

function Assert-Cohort {
    param([Parameter(Mandatory)][AllowNull()]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:Checks++
    if (-not $Condition) {
        [void]$script:Failures.Add($Message)
        Write-Host "  FAIL - $Message" -ForegroundColor Red
    }
}

function Write-StrictJsonFile {
    <#
    .SYNOPSIS
        Writes strict UTF-8 without a byte-order mark, which is the only encoding
        these contracts are read in.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 16)
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent))
    $text = ConvertTo-Json -InputObject $Value -Depth $Depth -Compress:$false
    [IO.File]::WriteAllBytes($Path, ([Text.UTF8Encoding]::new($false, $true)).GetBytes($text))
    return [string]([IO.Path]::GetFullPath($Path))
}

function Get-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 32)
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-FakeCommit {
    <#
    .SYNOPSIS
        A 40-character lower-case hexadecimal identifier, which is all any of
        these contracts asks a commit to be.
    #>
    $bytes = [byte[]]::new(20)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return (([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant())
}

function New-FakeDigest {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return (([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant())
}

function New-CohortToolkit {
    <#
    .SYNOPSIS
        A checkout the head resolver can read, without needing git.

    .DESCRIPTION
        The resolver reads files rather than shelling out, and a detached HEAD is
        a file holding a commit identifier. Writing one directly is the same input
        a real detached checkout presents, and it lets the stale-head case be
        produced by editing one line.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Head)
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root '.git'))
    [IO.File]::WriteAllBytes(
        (Join-Path $Root '.git\HEAD'),
        ([Text.UTF8Encoding]::new($false)).GetBytes($Head + "`n"))
    return [string]([IO.Path]::GetFullPath($Root))
}

function New-StubPreparation {
    <#
    .SYNOPSIS
        Writes the stand-in preparation each entry starts.

    .DESCRIPTION
        It parses the two arguments the runner appends, reads its behaviour from a
        control file beside its request, and publishes an audit in the same shape
        and at the same path the real preparation publishes one. It has no test
        hook into the runner: everything it does, it does through the same files
        and the same exit codes a real preparation uses.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $body = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CanonicalScalarText {
    param([string]$Text)
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        switch ($character) {
            '"' { [void]$builder.Append('\"'); continue }
            '\' { [void]$builder.Append('\\'); continue }
        }
        if ($code -lt 32 -or $code -eq 127) {
            [void]$builder.Append('\u' + $code.ToString('x4'))
        } else {
            [void]$builder.Append($character)
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-CanonicalText {
    <#
        The same canonical form the coordinator's own writer produces: keys sorted
        ordinally, no whitespace, integers unquoted. The stub signs what it writes
        with the key it writes beside it, exactly as a real preparation does.
    #>
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (Write-CanonicalScalarText -Text $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) {
        return ([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [Collections.IDictionary]) {
        $names = [Collections.Generic.List[string]]::new()
        foreach ($name in $Value.Keys) { [void]$names.Add([string]$name) }
        $names.Sort([StringComparer]::Ordinal)
        $parts = [Collections.Generic.List[string]]::new()
        foreach ($name in $names) {
            [void]$parts.Add((Write-CanonicalScalarText -Text $name) + ':' + (ConvertTo-CanonicalText -Value $Value[$name]))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = [Collections.Generic.List[string]]::new()
        foreach ($item in $Value) { [void]$items.Add((ConvertTo-CanonicalText -Value $item)) }
        return '[' + ($items -join ',') + ']'
    }
    throw "The stub cannot canonicalize a $($Value.GetType().FullName)."
}

function Get-Sha256Text {
    param([string]$Text)
    $bytes = ([Text.UTF8Encoding]::new($false, $true)).GetBytes($Text)
    return ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes))).Replace('-', '').ToLowerInvariant()
}

$parsed = @{}
for ($index = 0; $index -lt $args.Count; $index++) {
    if ($args[$index] -like '--*') {
        $parsed[$args[$index].Substring(2)] = [string]$args[$index + 1]
        $index++
    }
}
if (-not $parsed.ContainsKey('request')) { exit 1 }

$requestPath = $parsed['request']
$request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -Depth 24
$outputRoot = $request.output.root
$controlPath = [Regex]::Replace($requestPath, '\.request\.json$', '.control.json')
$control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json -Depth 16

if ($control.startedMarker) {
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $control.startedMarker -Parent))
    [IO.File]::WriteAllText($control.startedMarker, [string]$PID)
}
if ($control.sleepSeconds -gt 0) { Start-Sleep -Seconds $control.sleepSeconds }

$coordinatorRoot = Join-Path $outputRoot 'coordinator'
$signingKeyBytes = [Convert]::FromHexString([string]$control.stateKey)
if ($control.writeStateKey) {
    [void](New-Item -ItemType Directory -Force -Path $coordinatorRoot)
    $keyPath = Join-Path $coordinatorRoot 'state.key'
    if (-not (Test-Path -LiteralPath $keyPath)) {
        # The production key format: 32 raw bytes, exactly as the real
        # preparation writes it. The control file carries the same bytes as
        # hexadecimal because JSON cannot hold bytes; what lands on disk is
        # what the coordinator itself would have written. The other encodings
        # exist so a reader that accepted them can be caught doing it.
        # Each branch yields its array as ONE object. A switch branch that emits
        # a bare empty array contributes nothing to the result, and the empty-key
        # case would then write no key at all - passing for the wrong reason,
        # because a preparation that published no key is a case already covered
        # elsewhere.
        $onDisk = switch ([string]$control.stateKeyEncoding) {
            'legacyHex' { , ([Text.ASCIIEncoding]::new()).GetBytes([string]$control.stateKey) }
            'short' { , [byte[]]$signingKeyBytes[0..30] }
            'long' { , [byte[]]($signingKeyBytes + [byte[]]@(0)) }
            'empty' { , [byte[]]@() }
            default { , [byte[]]$signingKeyBytes }
        }
        [IO.File]::WriteAllBytes($keyPath, [byte[]]$onDisk)
    }
}
if ($control.signingKeyOverride) {
    # The audit is signed with a key the root does not hold, which is what a
    # forged audit and a rotated key look like from the outside.
    $signingKeyBytes = [Convert]::FromHexString([string]$control.signingKeyOverride)
}

if ($control.writeAudit) {
    $transitions = @()
    $sequence = 0
    foreach ($state in $control.transitionStates) {
        $sequence++
        $transitions += [ordered]@{
            sequence = $sequence
            state = [string]$state
            atUtc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
            evidenceSha256 = [string]$control.evidenceSha256
            detail = 'stub'
        }
    }
    $requestBytes = [IO.File]::ReadAllBytes($requestPath)
    $requestSha256 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($requestBytes))).Replace('-', '').ToLowerInvariant()
    if ($control.requestSha256Override) { $requestSha256 = [string]$control.requestSha256Override }
    $subject = [ordered]@{
        organization = [string]$request.subject.organization
        project = [string]$request.subject.project
        repository = [string]$request.subject.repository
        pullRequestId = [long]$request.subject.pullRequestId
        iterationId = [long]$request.subject.iterationId
        sourceCommit = [string]$request.subject.sourceCommit
        commonCommit = [string]$request.subject.commonCommit
        targetCommit = [string]$request.subject.targetCommit
    }
    $subjectSha256 = Get-Sha256Text -Text (ConvertTo-CanonicalText -Value $subject)
    if ($control.subjectSha256Override) { $subjectSha256 = [string]$control.subjectSha256Override }
    $audit = [ordered]@{
        contractVersion = [string]$control.auditContractVersion
        kind = [string]$control.auditKind
        correlationId = [string]$request.correlationId
        requestSha256 = $requestSha256
        subjectSha256 = $subjectSha256
        finalState = [string]$control.finalState
        sequence = $sequence
        modelInvocationCount = [long]$control.modelInvocationCount
        slotLaunchCount = [long]$control.slotLaunchCount
        declaredSlotCount = [long]2
        supervisedSlotCount = [long]$control.supervisedSlotCount
        slots = @(
            [ordered]@{ name = 'slot1'; slotModelInvocationCount = [long]$control.slot1ModelInvocationCount },
            [ordered]@{ name = 'slot2'; slotModelInvocationCount = [long]$control.slot2ModelInvocationCount }
        )
        reconciliationPerformed = [bool]$control.reconciliationPerformed
        reconciliationSha256 = [string]$control.reconciliationSha256
        reconciliationReportSha256 = [string]$control.reconciliationReportSha256
        deliveryPerformed = [bool]$control.deliveryPerformed
        deliveryMode = 'previewOnly'
        deliveryAuthorizationKind = [string]$control.deliveryAuthorizationKind
        deliveryCommentsEnabled = [bool]$control.deliveryCommentsEnabled
        deliveryVotesEnabled = $false
        deliveryGatesEnabled = $false
        deliveryDecisionSha256 = [string]$control.deliveryDecisionSha256
        deliverySummarySha256 = [string]$control.deliverySummarySha256
        providerWriteCount = [long]$control.providerWriteCount
        writeToolInvocations = [long]$control.writeToolInvocations
        childResultTransitionCount = [long]$sequence
        transitions = @($transitions)
        terminalReason = [string]$control.terminalReason
        terminalDetail = 'stub'
        stateSha256 = [string]$control.stateSha256
    }
    $selfHash = Get-Sha256Text -Text (ConvertTo-CanonicalText -Value $audit)
    if ($control.tamperSelfHash) { $selfHash = [string]$control.evidenceSha256 }
    $audit['auditSha256'] = $selfHash
    $keyBytes = $signingKeyBytes
    $signed = ([BitConverter]::ToString(
        [Security.Cryptography.HMACSHA256]::HashData(
            $keyBytes,
            ([Text.UTF8Encoding]::new($false, $true)).GetBytes((ConvertTo-CanonicalText -Value $audit))))).Replace('-', '').ToLowerInvariant()
    if ($control.tamperSignature) { $signed = [string]$control.evidenceSha256 }
    $audit['signature'] = $signed
    $auditPath = Join-Path $coordinatorRoot 'audit.json'
    [void](New-Item -ItemType Directory -Force -Path $coordinatorRoot)
    $text = ConvertTo-CanonicalText -Value $audit
    [IO.File]::WriteAllBytes($auditPath, ([Text.UTF8Encoding]::new($false, $true)).GetBytes($text))
}

exit ([int]$control.exitCode)
'@
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent))
    [IO.File]::WriteAllBytes($Path, ([Text.UTF8Encoding]::new($false)).GetBytes($body))
    return [string]([IO.Path]::GetFullPath($Path))
}

function New-StubControl {
    <#
    .SYNOPSIS
        How one entry's stand-in preparation behaves, and what it publishes.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$ExitCode = 0,
        [int]$SleepSeconds = 0,
        [bool]$WriteAudit = $true,
        [string]$FinalState = 'deliveryTerminalVerified',
        [string]$TerminalReason = 'targetReached',
        [int]$ModelInvocationCount = 0,
        [int]$Slot1ModelInvocationCount = 1,
        [int]$Slot2ModelInvocationCount = 1,
        [int]$SlotLaunchCount = 2,
        [int]$SupervisedSlotCount = 2,
        [int]$ProviderWriteCount = 0,
        [int]$WriteToolInvocations = 0,
        [string]$AuditContractVersion = 'devpilot.shadow-run-coordinator.audit.v1',
        [string]$AuditKind = 'shadow-run-coordinator-audit',
        [string]$DeliveryAuthorizationKind = 'PreviewOnly',
        [bool]$DeliveryCommentsEnabled = $false,
        [bool]$WriteStateKey = $true,
        [bool]$TamperSelfHash = $false,
        [bool]$TamperSignature = $false,
        [string]$RequestSha256Override = '',
        [string]$SubjectSha256Override = '',
        [string]$StateKey = '',
        [ValidateSet('raw', 'legacyHex', 'short', 'long', 'empty')][string]$StateKeyEncoding = 'raw',
        [string]$SigningKeyOverride = '',
        [string[]]$TransitionStates = @(
            'requestValidated', 'snapshotVerified', 'runSetReady',
            'slot1TerminalVerified', 'slot2TerminalVerified',
            'reconciliationVerified', 'deliveryTerminalVerified'),
        [string]$StartedMarker = ''
    )
    $control = [ordered]@{
        exitCode = $ExitCode
        sleepSeconds = $SleepSeconds
        writeAudit = $WriteAudit
        writeStateKey = $WriteStateKey
        stateKey = $(if ($StateKey) { $StateKey } else { (New-FakeDigest) })
        stateKeyEncoding = $StateKeyEncoding
        signingKeyOverride = $SigningKeyOverride
        tamperSelfHash = $TamperSelfHash
        tamperSignature = $TamperSignature
        requestSha256Override = $RequestSha256Override
        subjectSha256Override = $SubjectSha256Override
        finalState = $FinalState
        terminalReason = $TerminalReason
        modelInvocationCount = $ModelInvocationCount
        slot1ModelInvocationCount = $Slot1ModelInvocationCount
        slot2ModelInvocationCount = $Slot2ModelInvocationCount
        slotLaunchCount = $SlotLaunchCount
        supervisedSlotCount = $SupervisedSlotCount
        providerWriteCount = $ProviderWriteCount
        writeToolInvocations = $WriteToolInvocations
        auditContractVersion = $AuditContractVersion
        auditKind = $AuditKind
        deliveryAuthorizationKind = $DeliveryAuthorizationKind
        deliveryCommentsEnabled = $DeliveryCommentsEnabled
        deliveryPerformed = $true
        reconciliationPerformed = $true
        reconciliationSha256 = (New-FakeDigest)
        reconciliationReportSha256 = (New-FakeDigest)
        deliveryDecisionSha256 = (New-FakeDigest)
        deliverySummarySha256 = (New-FakeDigest)
        evidenceSha256 = (New-FakeDigest)
        stateSha256 = (New-FakeDigest)
        auditSha256 = (New-FakeDigest)
        transitionStates = @($TransitionStates)
        startedMarker = $StartedMarker
    }
    return (Write-StrictJsonFile -Path $Path -Value ([pscustomobject]$control))
}

function New-CohortEntryRequest {
    <#
    .SYNOPSIS
        One entry's typed coordinator request: the full declaration, written
        before the cohort is declared, exactly as an operator would write it.
    #>
    param(
        [Parameter(Mandatory)][string]$Sandbox,
        [Parameter(Mandatory)][string]$EntryId,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$RequiredRef,
        [Parameter(Mandatory)][int]$PullRequestId,
        [int]$IterationId = 1,
        [string]$OutputRoot,
        [hashtable]$Digests,
        [switch]$WithoutDelivery,
        [string]$DeliveryAuthorizationKind = 'PreviewOnly',
        [int]$ProviderWriteBudget = 0
    )
    if (-not $OutputRoot) { $OutputRoot = Join-Path $Sandbox "roots\$EntryId" }
    $OutputRoot = [string]([IO.Path]::GetFullPath($OutputRoot))
    if (-not $Digests) {
        $Digests = @{ configSha256 = (New-FakeDigest); promptSha256 = (New-FakeDigest); schemaSha256 = (New-FakeDigest) }
    }
    $subject = [ordered]@{
        organization = 'contoso-shadow-org'
        project = 'contoso-shadow-project'
        repository = 'contoso-shadow-repository'
        pullRequestId = $PullRequestId
        iterationId = $IterationId
        sourceCommit = (New-FakeCommit)
        commonCommit = (New-FakeCommit)
        targetCommit = (New-FakeCommit)
    }
    $token = [string]([IO.Path]::GetFullPath((Join-Path $Sandbox "inputs\$EntryId.token")))
    $slot = {
        param($name, $stateDir, $terminal)
        [ordered]@{
            name = $name
            reviewerScriptPath = [string]([IO.Path]::GetFullPath((Join-Path $ToolkitRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1')))
            launchAuthorizationTokenPath = $token
            supervisionGraceSeconds = 60
            stateDirName = $stateDir
            terminalName = $terminal
            modelPlan = [ordered]@{ bindSealedArguments = $false; opaqueArguments = @() }
        }
    }
    $slots = [ordered]@{
        shadowSlotsEnabled = $true
        declared = @((& $slot 'slot1' 'slot1-state' 'slot1-terminal.json'), (& $slot 'slot2' 'slot2-state' 'slot2-terminal.json'))
        reconciliation = [ordered]@{
            reconciliationEnabled = $true
            outputDirectory = [string]([IO.Path]::GetFullPath((Join-Path $OutputRoot 'reconciliation')))
            requiredRunCount = 2
            launchAuthorizationTokenPath = $token
            supervisionGraceSeconds = 60
        }
    }
    if (-not $WithoutDelivery.IsPresent) {
        $slots.Add('delivery', [ordered]@{
            deliveryEnabled = $true
            authorizationKind = $DeliveryAuthorizationKind
            outputDirectory = [string]([IO.Path]::GetFullPath((Join-Path $OutputRoot 'delivery')))
            requiredRunCount = 2
            launchAuthorizationTokenPath = $token
            supervisionGraceSeconds = 60
            commentsEnabled = $false
            votesEnabled = $false
            gatesEnabled = $false
            providerWriteBudget = $ProviderWriteBudget
        })
    }
    $request = [ordered]@{
        contractVersion = 'devpilot.shadow-run-coordinator.request.v2'
        kind = 'shadow-run-preparation'
        correlationId = "cohort-$EntryId"
        toolkit = [ordered]@{ repositoryRoot = $ToolkitRoot; head = $Head }
        subject = $subject
        digests = [ordered]@{
            configSha256 = $Digests.configSha256
            promptSha256 = $Digests.promptSha256
            schemaSha256 = $Digests.schemaSha256
        }
        corpus = [ordered]@{
            root = [string]([IO.Path]::GetFullPath((Join-Path $Sandbox "corpus\$EntryId")))
            indexSha256 = (New-FakeDigest)
            recipePath = [string]([IO.Path]::GetFullPath((Join-Path $Sandbox "corpus\$EntryId\recipe.json")))
            changedPathsPath = [string]([IO.Path]::GetFullPath((Join-Path $Sandbox "corpus\$EntryId\changed-paths.json")))
        }
        output = [ordered]@{ root = $OutputRoot }
        children = [ordered]@{ powerShellPath = $script:PwshPath; timeoutSeconds = 900 }
        qualification = [ordered]@{
            operatorAlias = 'example-operator'
            reviewerConfigPath = [string]([IO.Path]::GetFullPath((Join-Path $Sandbox 'inputs\reviewer.config.json')))
            reviewerRepositoryPath = [string]([IO.Path]::GetFullPath((Join-Path $Sandbox 'reviewed-repo')))
            expectedCommit = $Head
            requiredRef = $RequiredRef
            plannedRunCount = 2
            runSetKeyPath = [string]([IO.Path]::GetFullPath((Join-Path $Sandbox 'inputs\run-set.key')))
        }
        slots = $slots
    }
    $path = Write-StrictJsonFile -Path (Join-Path $Sandbox "requests\$EntryId.request.json") -Value ([pscustomobject]$request) -Depth 20
    return [pscustomobject][ordered]@{
        EntryId = $EntryId
        Path = $path
        ControlPath = [Regex]::Replace($path, '\.request\.json$', '.control.json')
        Sha256 = (Get-Sha256 -Path $path)
        OutputRoot = $OutputRoot
        Subject = $subject
        Digests = $Digests
    }
}

function New-CohortEntryDeclaration {
    <#
    .SYNOPSIS
        The manifest entry that pins one already-written request.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][int]$Ordinal,
        [Parameter(Mandatory)][string]$RuleBundlePath,
        [int]$EstimatedModelStarts = 2,
        [int]$EstimatedVerifierAssignments = 4,
        [int]$EstimatedWallClockSeconds = 300,
        [string]$OutputRootOverride,
        [hashtable]$SubjectOverride
    )
    $subject = [ordered]@{
        organization = $Request.Subject.organization
        project = $Request.Subject.project
        repository = $Request.Subject.repository
        pullRequestId = $Request.Subject.pullRequestId
        iterationId = $Request.Subject.iterationId
        sourceCommit = $Request.Subject.sourceCommit
        commonCommit = $Request.Subject.commonCommit
        targetCommit = $Request.Subject.targetCommit
    }
    if ($SubjectOverride) {
        foreach ($name in $SubjectOverride.Keys) { $subject[$name] = $SubjectOverride[$name] }
    }
    $outputRoot = $Request.OutputRoot
    if ($OutputRootOverride) { $outputRoot = $OutputRootOverride }
    return [ordered]@{
        ordinal = $Ordinal
        entryId = $Request.EntryId
        request = [ordered]@{ path = $Request.Path; sha256 = $Request.Sha256 }
        output = [ordered]@{ root = $outputRoot }
        subject = $subject
        digests = [ordered]@{
            configSha256 = $Request.Digests.configSha256
            promptSha256 = $Request.Digests.promptSha256
            schemaSha256 = $Request.Digests.schemaSha256
        }
        ruleBundle = [ordered]@{
            sourceKind = 'reviewedRepositoryDeclaration'
            declarationPath = $RuleBundlePath
            declarationSha256 = (Get-Sha256 -Path $RuleBundlePath)
        }
        planEstimate = [ordered]@{
            modelStarts = $EstimatedModelStarts
            verifierAssignments = $EstimatedVerifierAssignments
            wallClockSeconds = $EstimatedWallClockSeconds
        }
    }
}

function New-CohortManifestFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$RequiredRef,
        [Parameter(Mandatory)][string]$JournalRoot,
        [Parameter(Mandatory)][string]$IndexPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries,
        [Parameter(Mandatory)][string]$StubPath,
        [string]$CommandPath = '',
        [string[]]$ArgumentPrefixOverride,
        [string]$CohortId = 'cohort-alpha-one',
        [string]$CorrelationId = 'cohort-correlation-one',
        [int]$Concurrency = 1,
        [string]$StopPolicy = 'continueOnTerminalFailure',
        [string]$AuthorizationKind = 'PreviewOnly',
        [string]$Target = 'deliveryTerminalVerified',
        [int]$EntryTimeoutSeconds = 120,
        [int]$MaxPullRequests = 8,
        [int]$MaxModelStarts = 64,
        [int]$MaxVerifierAssignments = 64,
        [int]$MaxWallClockSeconds = 3600,
        [int]$ProviderWriteBudget = 0,
        [hashtable]$ExtraRoot
    )
    $resolvedPrefix = [string[]]@('-NoProfile', '-NonInteractive', '-File', $StubPath)
    if ($ArgumentPrefixOverride) { $resolvedPrefix = [string[]]@($ArgumentPrefixOverride) }
    $manifest = [ordered]@{
        contractVersion = 'devpilot.shadow-cohort.manifest.v1'
        kind = 'shadow-cohort-run'
        cohortId = $CohortId
        correlationId = $CorrelationId
        toolkit = [ordered]@{ repositoryRoot = $ToolkitRoot; head = $Head; requiredRef = $RequiredRef }
        execution = [ordered]@{
            concurrency = $Concurrency
            stopPolicy = $StopPolicy
            authorizationKind = $AuthorizationKind
            commandPath = $(if ($CommandPath) { $CommandPath } else { $script:PwshPath })
            argumentPrefix = $resolvedPrefix
            target = $Target
            entryTimeoutSeconds = $EntryTimeoutSeconds
        }
        budgets = [ordered]@{
            maxPullRequests = $MaxPullRequests
            maxModelStarts = $MaxModelStarts
            maxVerifierAssignments = $MaxVerifierAssignments
            maxWallClockSeconds = $MaxWallClockSeconds
            providerWriteBudget = $ProviderWriteBudget
        }
        journal = [ordered]@{ root = $JournalRoot }
        audit = [ordered]@{ indexPath = $IndexPath }
        entries = @($Entries)
    }
    if ($ExtraRoot) { foreach ($name in $ExtraRoot.Keys) { $manifest[$name] = $ExtraRoot[$name] } }
    return (Write-StrictJsonFile -Path $Path -Value ([pscustomobject]$manifest) -Depth 24)
}

function Invoke-Cohort {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$AuthorizedBy = 'test-operator',
        [switch]$RebuildIndex,
        [switch]$OmitAuthorization,
        [string[]]$Extra
    )
    $argv = [System.Collections.Generic.List[string]]::new()
    [void]$argv.Add($script:CohortDll)
    [void]$argv.Add('--cohort'); [void]$argv.Add($ManifestPath)
    if (-not $OmitAuthorization.IsPresent) { [void]$argv.Add('--authorized-by'); [void]$argv.Add($AuthorizedBy) }
    if ($RebuildIndex.IsPresent) { [void]$argv.Add('--rebuild-index') }
    if ($Extra) { foreach ($item in $Extra) { [void]$argv.Add($item) } }
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & dotnet @argv 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally { $PSNativeCommandUseErrorActionPreference = $previous }
}

function Get-CohortJournalEntry {
    param([Parameter(Mandatory)][string]$JournalRoot, [Parameter(Mandatory)][string]$EntryId)
    $journal = Get-JsonFile -Path (Join-Path $JournalRoot 'cohort-journal.json')
    if (-not $journal) { return $null }
    return ($journal.entries | Where-Object { $_.entryId -eq $EntryId } | Select-Object -First 1)
}

function Get-CohortIndexEntry {
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$EntryId)
    return ($Index.entries | Where-Object { $_.entryId -eq $EntryId } | Select-Object -First 1)
}

# ---------------------------------------------------------------------------
$sandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("shadow-cohort-" + [Guid]::NewGuid().ToString('N').Substring(0, 10))
[void](New-Item -ItemType Directory -Force -Path $sandboxRoot)
Write-Host "sandbox: $sandboxRoot" -ForegroundColor DarkGray

try {
    # -----------------------------------------------------------------------
    Write-Host '1/23 build the shipping coordinator' -ForegroundColor Cyan
    $project = Join-Path $RepoRoot 'tools\ShadowRunCoordinator\ShadowRunCoordinator.csproj'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    & dotnet build $project --configuration Release --nologo --verbosity quiet | Out-Null
    Assert-Cohort ($LASTEXITCODE -eq 0) 'The coordinator did not build.'
    $script:CohortDll = Join-Path $RepoRoot 'tools\ShadowRunCoordinator\bin\Release\net10.0\ShadowRunCoordinator.dll'
    Assert-Cohort (Test-Path -LiteralPath $script:CohortDll -PathType Leaf) 'The coordinator assembly was not produced.'

    $head = New-FakeCommit
    $requiredRef = 'refs/heads/main'
    $toolkit = New-CohortToolkit -Root (Join-Path $sandboxRoot 'toolkit') -Head $head
    $stub = New-StubPreparation -Path (Join-Path $sandboxRoot 'stub\stub-preparation.ps1')
    $ruleBundle = Write-StrictJsonFile -Path (Join-Path $sandboxRoot 'inputs\rule-bundle.json') -Value ([pscustomobject][ordered]@{
            contractVersion = 'devpilot.reviewer.rule-bundle-declaration.v1'
            sourceKind = 'reviewedRepositoryDeclaration'
            declaredPaths = @('docs/reviewer-rules.md')
        })

    # -----------------------------------------------------------------------
    Write-Host '2/23 three-entry cohort: complete, not-complete, complete' -ForegroundColor Cyan
    $caseA = Join-Path $sandboxRoot 'case-a'
    $a1 = New-CohortEntryRequest -Sandbox $caseA -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $a2 = New-CohortEntryRequest -Sandbox $caseA -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    $a3 = New-CohortEntryRequest -Sandbox $caseA -EntryId 'entry-three' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918275
    [void](New-StubControl -Path $a1.ControlPath -ExitCode 0)
    # Exit 5 is the preparation's own word for "the run I supervised ended other
    # than complete". The cohort must carry that across as an outcome and must not
    # re-attempt it.
    [void](New-StubControl -Path $a2.ControlPath -ExitCode 5 -FinalState 'slot2TerminalFailed' `
            -TerminalReason 'supervisedRunNotComplete' -Slot2ModelInvocationCount 1 -SupervisedSlotCount 2 `
            -TransitionStates @('requestValidated', 'snapshotVerified', 'runSetReady', 'slot1TerminalVerified', 'slot2TerminalFailed'))
    [void](New-StubControl -Path $a3.ControlPath -ExitCode 0)
    $manifestA = New-CohortManifestFile -Path (Join-Path $caseA 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseA 'journal') -IndexPath (Join-Path $caseA 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $a1 -Ordinal 1 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $a2 -Ordinal 2 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $a3 -Ordinal 3 -RuleBundlePath $ruleBundle))

    $runA = Invoke-Cohort -ManifestPath $manifestA
    Assert-Cohort ($runA.ExitCode -eq 5) "A cohort with one entry other than complete exited $($runA.ExitCode); expected 5."
    $indexA = Get-JsonFile -Path (Join-Path $caseA 'index\cohort-index.json')
    Assert-Cohort ($null -ne $indexA) 'The cohort published no index.'
    Assert-Cohort ($indexA.terminalReason -eq 'completedWithEntryFailure') `
        "The continue policy left terminal reason '$($indexA.terminalReason)'; expected completedWithEntryFailure."
    Assert-Cohort ($indexA.declaredEntryCount -eq 3 -and $indexA.completedEntryCount -eq 2 -and $indexA.pendingEntryCount -eq 0) `
        'The index did not account for three entries with two complete and none pending.'
    Assert-Cohort (@($indexA.entries).Count -eq 3) 'The index does not carry one summary per declared entry.'
    Assert-Cohort ($indexA.entries[0].entryId -eq 'entry-one' -and $indexA.entries[1].entryId -eq 'entry-two' -and $indexA.entries[2].entryId -eq 'entry-three') `
        'The index entries are not in declared order.'
    Assert-Cohort ($indexA.consumed.providerWrites -eq 0) 'The index reports a provider write in a preview-only cohort.'
    Assert-Cohort ($indexA.consumed.modelStarts -eq 6) "The index totalled $($indexA.consumed.modelStarts) model starts; expected 6."
    $summaryTwo = Get-CohortIndexEntry -Index $indexA -EntryId 'entry-two'
    Assert-Cohort ($summaryTwo.outcome -eq 'runNotComplete') "Entry two was recorded '$($summaryTwo.outcome)'; expected runNotComplete."
    Assert-Cohort ($summaryTwo.preparationFinalState -eq 'slot2TerminalFailed') 'The summary did not carry the preparation final state across.'
    Assert-Cohort ($summaryTwo.verifierAssignmentCount -eq 2) `
        "Entry two counted $($summaryTwo.verifierAssignmentCount) verifier assignments; expected 2 from its committed verifier-backed transitions."
    Assert-Cohort ($summaryTwo.modelStartCount -eq 2) 'A partially completed entry did not contribute its actual model starts.'
    # One key format across this program: the journal signs itself with 32 raw
    # bytes, which is what the preparation writes into every entry root and what
    # the one reader accepts.
    $journalKeyA = Join-Path $caseA 'journal\cohort-journal.key'
    $journalKeyLength = [IO.File]::ReadAllBytes($journalKeyA).Length
    Assert-Cohort ($journalKeyLength -eq 32) `
        "The cohort journal key is $journalKeyLength bytes; expected the 32 raw bytes this build writes."
    $entryKeyA = Join-Path $a1.OutputRoot 'coordinator\state.key'
    $entryKeyLength = [IO.File]::ReadAllBytes($entryKeyA).Length
    Assert-Cohort ($entryKeyLength -eq 32) `
        'An entry signing key is not the 32 raw bytes the preparation writes.'

    # -----------------------------------------------------------------------
    Write-Host '3/23 the summary carries no subject, finding text or judgement' -ForegroundColor Cyan
    $indexText = Get-Content -LiteralPath (Join-Path $caseA 'index\cohort-index.json') -Raw
    # The sentinel names are chosen not to occur inside a hexadecimal digest, so
    # their absence is evidence rather than luck. The field names are checked
    # quoted, because a declared source kind may legitimately contain the word
    # "repository" without carrying anybody's repository.
    foreach ($forbidden in @('contoso', '"organization"', '"repository"', '"pullRequestId"', '"iterationId"',
            'sourceCommit', 'finding', 'severity', 'verdict', 'promotable')) {
        Assert-Cohort ($indexText -notmatch [Regex]::Escape($forbidden)) `
            "The published cohort index names '$forbidden'; the index is opaque and identifies its entries by digest."
    }
    Assert-Cohort ($null -ne $indexA.entries[0].subjectSha256) 'The index does not bind its entries to a subject digest.'
    Assert-Cohort ($null -ne $indexA.indexSha256 -and $null -ne $indexA.signature) 'The index is neither self-hashed nor signed.'

    # -----------------------------------------------------------------------
    Write-Host '4/23 an ended entry is never re-attempted' -ForegroundColor Cyan
    $rerunA = Invoke-Cohort -ManifestPath $manifestA
    Assert-Cohort ($rerunA.ExitCode -eq 5) "Re-running a finished cohort exited $($rerunA.ExitCode); expected the same 5."
    $journalA = Get-JsonFile -Path (Join-Path $caseA 'journal\cohort-journal.json')
    foreach ($entryId in @('entry-one', 'entry-two', 'entry-three')) {
        $record = Get-CohortJournalEntry -JournalRoot (Join-Path $caseA 'journal') -EntryId $entryId
        Assert-Cohort ($record.attempt -eq 1) "Entry '$entryId' was attempted $($record.attempt) time(s); a cohort never re-attempts an entry that ended."
    }
    $launchEvents = @($journalA.events | Where-Object { $_.kind -eq 'launchIntended' })
    Assert-Cohort ($launchEvents.Count -eq 3) "The journal records $($launchEvents.Count) launch intents for three entries; expected exactly three."

    # -----------------------------------------------------------------------
    Write-Host '5/23 the index is rebuildable from the journal and the entry audits' -ForegroundColor Cyan
    $indexPathA = Join-Path $caseA 'index\cohort-index.json'
    $beforeRebuild = Get-JsonFile -Path $indexPathA
    Remove-Item -LiteralPath $indexPathA -Force
    $rebuild = Invoke-Cohort -ManifestPath $manifestA -RebuildIndex
    Assert-Cohort ($rebuild.ExitCode -eq 0) "Rebuilding the index exited $($rebuild.ExitCode); expected 0."
    $afterRebuild = Get-JsonFile -Path $indexPathA
    Assert-Cohort ($null -ne $afterRebuild) 'The rebuild published no index.'
    Assert-Cohort ((ConvertTo-Json -InputObject $afterRebuild.entries -Depth 24 -Compress) -eq (ConvertTo-Json -InputObject $beforeRebuild.entries -Depth 24 -Compress)) `
        'The rebuilt index does not reproduce the per-entry summaries.'
    Assert-Cohort ((ConvertTo-Json -InputObject $afterRebuild.consumed -Depth 8 -Compress) -eq (ConvertTo-Json -InputObject $beforeRebuild.consumed -Depth 8 -Compress)) `
        'The rebuilt index does not reproduce the consumed totals.'
    Assert-Cohort ($afterRebuild.journalSha256 -eq $beforeRebuild.journalSha256) 'The rebuilt index names a different journal.'
    # An index that claims to be rebuildable from its artifacts has to notice when
    # one of them is gone. Otherwise a removed audit would simply be re-signed as
    # an entry that never ran, and the signature would say so with confidence.
    $auditA1 = Join-Path $a1.OutputRoot 'coordinator\audit.json'
    $stashedAudit = [IO.File]::ReadAllBytes($auditA1)
    Remove-Item -LiteralPath $auditA1 -Force
    $rebuildMissing = Invoke-Cohort -ManifestPath $manifestA -RebuildIndex
    Assert-Cohort ($rebuildMissing.ExitCode -eq 11) `
        "Rebuilding over a removed entry audit exited $($rebuildMissing.ExitCode); expected 11."
    [IO.File]::WriteAllBytes($auditA1, $stashedAudit)
    $rebuildRestored = Invoke-Cohort -ManifestPath $manifestA -RebuildIndex
    Assert-Cohort ($rebuildRestored.ExitCode -eq 0) `
        "Rebuilding over the restored audit exited $($rebuildRestored.ExitCode); expected 0."
    $restoredIndex = Get-JsonFile -Path $indexPathA
    Assert-Cohort ((ConvertTo-Json -InputObject $restoredIndex.entries -Depth 24 -Compress) -eq (ConvertTo-Json -InputObject $beforeRebuild.entries -Depth 24 -Compress)) `
        'The index rebuilt after the audit was restored does not reproduce the original summaries.'
    # A rebuild reports a record; it does not stand in for one. Pointed at a root
    # holding no journal it must refuse, because going ahead would mint a key
    # nobody else holds and sign an index no later run could verify.
    $emptyRebuildRoot = Join-Path $sandboxRoot 'case-a-rebuild-empty'
    $manifestEmptyRebuild = New-CohortManifestFile -Path (Join-Path $emptyRebuildRoot 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $emptyRebuildRoot 'journal') -IndexPath (Join-Path $emptyRebuildRoot 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $a1 -Ordinal 1 -RuleBundlePath $ruleBundle))
    $rebuildEmpty = Invoke-Cohort -ManifestPath $manifestEmptyRebuild -RebuildIndex
    Assert-Cohort ($rebuildEmpty.ExitCode -eq 2) `
        "Rebuilding an index with no journal to rebuild it from exited $($rebuildEmpty.ExitCode); expected 2."
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $emptyRebuildRoot 'index\cohort-index.json'))) `
        'A rebuild with no journal published an index anyway.'
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $emptyRebuildRoot 'journal\cohort-journal.key'))) `
        'A rebuild with no journal left a signing key behind.'
    # The word a cohort publishes about itself is committed into the signed
    # journal, so a rebuild reports it rather than inferring one from the entry
    # records - which cannot tell a budget stop from a killed runner.
    $journalTerminalA = Get-JsonFile -Path (Join-Path $caseA 'journal\cohort-journal.json')
    Assert-Cohort ($journalTerminalA.terminal.reason -eq $beforeRebuild.terminalReason) `
        "The journal records terminal reason '$($journalTerminalA.terminal.reason)' and the index published '$($beforeRebuild.terminalReason)'."
    Assert-Cohort ($journalTerminalA.terminal.detailSha256 -eq $beforeRebuild.terminalDetailSha256) `
        'The journal and the index disagree about the digest of the word published.'
    Assert-Cohort ($afterRebuild.terminalReason -eq $beforeRebuild.terminalReason) `
        "The rebuilt index says '$($afterRebuild.terminalReason)' and the run published '$($beforeRebuild.terminalReason)'."

    # -----------------------------------------------------------------------
    Write-Host '6/23 failFast leaves the remaining entries pending' -ForegroundColor Cyan
    $caseB = Join-Path $sandboxRoot 'case-b'
    $b1 = New-CohortEntryRequest -Sandbox $caseB -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $b2 = New-CohortEntryRequest -Sandbox $caseB -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    $b3 = New-CohortEntryRequest -Sandbox $caseB -EntryId 'entry-three' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918275
    [void](New-StubControl -Path $b1.ControlPath -ExitCode 0)
    # Exit 4 is a child failure inside the preparation itself, which is a
    # different event from a supervised run ending other than complete. It
    # published its audit before it fell over, so the cohort can account for it
    # and the stop policy is the only thing deciding what happens next.
    [void](New-StubControl -Path $b2.ControlPath -ExitCode 4)
    [void](New-StubControl -Path $b3.ControlPath -ExitCode 0)
    $manifestB = New-CohortManifestFile -Path (Join-Path $caseB 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -StopPolicy 'failFast' `
        -JournalRoot (Join-Path $caseB 'journal') -IndexPath (Join-Path $caseB 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $b1 -Ordinal 1 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $b2 -Ordinal 2 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $b3 -Ordinal 3 -RuleBundlePath $ruleBundle))

    $runB = Invoke-Cohort -ManifestPath $manifestB
    Assert-Cohort ($runB.ExitCode -eq 5) "The failFast cohort exited $($runB.ExitCode); expected 5."
    $indexB = Get-JsonFile -Path (Join-Path $caseB 'index\cohort-index.json')
    Assert-Cohort ($indexB.terminalReason -eq 'stoppedOnEntryFailure') `
        "The failFast cohort left terminal reason '$($indexB.terminalReason)'; expected stoppedOnEntryFailure."
    Assert-Cohort ($indexB.pendingEntryCount -eq 1) "The failFast cohort left $($indexB.pendingEntryCount) entries pending; expected 1."
    $recordB2 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseB 'journal') -EntryId 'entry-two'
    Assert-Cohort ($recordB2.outcome -eq 'preparationFaulted') "Entry two ended '$($recordB2.outcome)'; expected preparationFaulted."
    $recordB3 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseB 'journal') -EntryId 'entry-three'
    Assert-Cohort ($recordB3.state -eq 'pending' -and $recordB3.attempt -eq 0) 'The entry after a failFast stop was not left untouched.'
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $b3.OutputRoot 'coordinator\audit.json'))) `
        'The entry after a failFast stop produced evidence, so it was started.'
    $summaryB3 = Get-CohortIndexEntry -Index $indexB -EntryId 'entry-three'
    Assert-Cohort ($summaryB3.state -eq 'pending' -and $summaryB3.auditSha256 -eq 'none') `
        'The index does not report the untouched entry as pending with no audit.'
    # A rebuild reports what the journal says happened, not what a clean run would
    # have said. A rebuild that always claimed completion would launder a stop.
    $rebuildB = Invoke-Cohort -ManifestPath $manifestB -RebuildIndex
    Assert-Cohort ($rebuildB.ExitCode -eq 0) "Rebuilding the failFast index exited $($rebuildB.ExitCode); expected 0."
    $indexBRebuilt = Get-JsonFile -Path (Join-Path $caseB 'index\cohort-index.json')
    Assert-Cohort ($indexBRebuilt.terminalReason -eq 'stoppedOnEntryFailure') `
        "The rebuilt failFast index claims terminal reason '$($indexBRebuilt.terminalReason)'; expected stoppedOnEntryFailure."
    Assert-Cohort ($indexBRebuilt.pendingEntryCount -eq 1) `
        "The rebuilt failFast index reports $($indexBRebuilt.pendingEntryCount) pending; expected 1."

    # The other policy, over the same shape. An entry that failed and published its
    # audit is an entry the cohort can account for, so continuing past it is a
    # decision about policy rather than a guess about what happened.
    $caseB2 = Join-Path $sandboxRoot 'case-b2'
    $bc1 = New-CohortEntryRequest -Sandbox $caseB2 -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $bc2 = New-CohortEntryRequest -Sandbox $caseB2 -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    $bc3 = New-CohortEntryRequest -Sandbox $caseB2 -EntryId 'entry-three' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918275
    [void](New-StubControl -Path $bc1.ControlPath -ExitCode 0)
    [void](New-StubControl -Path $bc2.ControlPath -ExitCode 4)
    [void](New-StubControl -Path $bc3.ControlPath -ExitCode 0)
    $manifestB2 = New-CohortManifestFile -Path (Join-Path $caseB2 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -StopPolicy 'continueOnTerminalFailure' `
        -JournalRoot (Join-Path $caseB2 'journal') -IndexPath (Join-Path $caseB2 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $bc1 -Ordinal 1 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $bc2 -Ordinal 2 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $bc3 -Ordinal 3 -RuleBundlePath $ruleBundle))
    $runB2 = Invoke-Cohort -ManifestPath $manifestB2
    Assert-Cohort ($runB2.ExitCode -eq 5) "The continuing cohort exited $($runB2.ExitCode); expected 5."
    $indexB2 = Get-JsonFile -Path (Join-Path $caseB2 'index\cohort-index.json')
    Assert-Cohort ($indexB2.terminalReason -eq 'completedWithEntryFailure') `
        "The continuing cohort left terminal reason '$($indexB2.terminalReason)'; expected completedWithEntryFailure."
    Assert-Cohort ($indexB2.pendingEntryCount -eq 0) `
        "The continuing cohort left $($indexB2.pendingEntryCount) entries pending; expected 0."
    $recordB2c2 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseB2 'journal') -EntryId 'entry-two'
    Assert-Cohort ($recordB2c2.outcome -eq 'preparationFaulted' -and $recordB2c2.auditSha256 -ne 'none') `
        'The failed entry the cohort continued past did not end faulted with its own audit recorded.'
    $recordB2c3 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseB2 'journal') -EntryId 'entry-three'
    Assert-Cohort ($recordB2c3.outcome -eq 'complete') 'The continue policy did not carry on past an accounted-for failure.'

    # -----------------------------------------------------------------------
    Write-Host '7/23 a child that hangs is killed at its declared ceiling' -ForegroundColor Cyan
    $caseC = Join-Path $sandboxRoot 'case-c'
    $c1 = New-CohortEntryRequest -Sandbox $caseC -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $c2 = New-CohortEntryRequest -Sandbox $caseC -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    $marker = Join-Path $caseC 'markers\entry-one.pid'
    [void](New-StubControl -Path $c1.ControlPath -ExitCode 0 -SleepSeconds 300 -WriteAudit $false -StartedMarker $marker)
    [void](New-StubControl -Path $c2.ControlPath -ExitCode 0)
    $manifestC = New-CohortManifestFile -Path (Join-Path $caseC 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -EntryTimeoutSeconds 3 `
        -JournalRoot (Join-Path $caseC 'journal') -IndexPath (Join-Path $caseC 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $c1 -Ordinal 1 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $c2 -Ordinal 2 -RuleBundlePath $ruleBundle))

    $runC = Invoke-Cohort -ManifestPath $manifestC
    # A killed child publishes nothing, so there is no account of what it started
    # or whether anything acted on its behalf. That stops the cohort regardless of
    # policy rather than indexing an entry nobody can speak for.
    Assert-Cohort ($runC.ExitCode -eq 11) "The cohort with a hung entry exited $($runC.ExitCode); expected 11."
    $recordC1 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseC 'journal') -EntryId 'entry-one'
    Assert-Cohort ($recordC1.state -eq 'ended' -and $recordC1.outcome -eq 'evidenceRefused') `
        "The hung entry ended '$($recordC1.outcome)' in state '$($recordC1.state)'; expected an ended entry with its evidence refused."
    $recordC2 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseC 'journal') -EntryId 'entry-two'
    Assert-Cohort ($recordC2.state -eq 'pending' -and $recordC2.attempt -eq 0) `
        'The entry after a killed one was started, so a cohort carried on past a preparation it cannot account for.'
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $c2.OutputRoot 'coordinator\audit.json'))) `
        'The entry after a killed one produced evidence, so it was started.'
    $indexC = Get-JsonFile -Path (Join-Path $caseC 'index\cohort-index.json')
    Assert-Cohort ($indexC.terminalReason -eq 'blocked') `
        "The cohort holding a killed entry published terminal reason '$($indexC.terminalReason)'; expected blocked."
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $hungPid = [int]((Get-Content -LiteralPath $marker -Raw).Trim())
        $alive = $null -ne (Get-Process -Id $hungPid -ErrorAction SilentlyContinue)
        Assert-Cohort (-not $alive) "The hung child (process $hungPid) was still running after its entry timed out."
    }
    # Running it again does not settle anything about that output root, so it does
    # not un-block the cohort either.
    $rerunC = Invoke-Cohort -ManifestPath $manifestC
    Assert-Cohort ($rerunC.ExitCode -eq 11) "Resuming over a refused entry exited $($rerunC.ExitCode); expected 11."
    $recordC2Again = Get-CohortJournalEntry -JournalRoot (Join-Path $caseC 'journal') -EntryId 'entry-two'
    Assert-Cohort ($recordC2Again.state -eq 'pending' -and $recordC2Again.attempt -eq 0) `
        'A resume over a refused entry started the entry after it.'

    # -----------------------------------------------------------------------
    Write-Host '8/23 kill at a cohort transition, then refuse to run beside a live child' -ForegroundColor Cyan
    $caseD = Join-Path $sandboxRoot 'case-d'
    $d1 = New-CohortEntryRequest -Sandbox $caseD -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $d2 = New-CohortEntryRequest -Sandbox $caseD -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    $d3 = New-CohortEntryRequest -Sandbox $caseD -EntryId 'entry-three' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918275
    $markerD = Join-Path $caseD 'markers\entry-two.pid'
    [void](New-StubControl -Path $d1.ControlPath -ExitCode 0)
    [void](New-StubControl -Path $d2.ControlPath -ExitCode 0 -SleepSeconds 300 -WriteAudit $false -StartedMarker $markerD)
    [void](New-StubControl -Path $d3.ControlPath -ExitCode 0)
    $journalD = Join-Path $caseD 'journal'
    $manifestD = New-CohortManifestFile -Path (Join-Path $caseD 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -EntryTimeoutSeconds 600 `
        -JournalRoot $journalD -IndexPath (Join-Path $caseD 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $d1 -Ordinal 1 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $d2 -Ordinal 2 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $d3 -Ordinal 3 -RuleBundlePath $ruleBundle))

    [void](New-Item -ItemType Directory -Force -Path (Join-Path $caseD 'logs'))
    $runner = Start-Process -FilePath 'dotnet' -PassThru -NoNewWindow `
        -ArgumentList @($script:CohortDll, '--cohort', $manifestD, '--authorized-by', 'test-operator') `
        -RedirectStandardOutput (Join-Path $caseD 'logs\runner.out') `
        -RedirectStandardError (Join-Path $caseD 'logs\runner.err')
    $deadline = (Get-Date).AddSeconds(120)
    $childPid = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $record = Get-CohortJournalEntry -JournalRoot $journalD -EntryId 'entry-two'
        if ($record -and $record.state -eq 'running' -and $record.childProcessId -gt 0) {
            $childPid = [int]$record.childProcessId
            break
        }
    }
    Assert-Cohort ($childPid -gt 0) 'The cohort never recorded a running child for the second entry.'
    # Killed WITHOUT its tree, which is what an operator's kill, a lost session or
    # a machine that dropped the runner looks like: the entry's preparation
    # survives its parent.
    Stop-Process -Id $runner.Id -Force
    $runner.WaitForExit()
    $recordD2 = Get-CohortJournalEntry -JournalRoot $journalD -EntryId 'entry-two'
    Assert-Cohort ($recordD2.state -eq 'running') 'A runner killed mid-entry did not leave a committed running record.'
    $recordD1 = Get-CohortJournalEntry -JournalRoot $journalD -EntryId 'entry-one'
    Assert-Cohort ($recordD1.state -eq 'ended' -and $recordD1.outcome -eq 'complete') 'The entry before the kill was not durably accounted for.'

    $resumeBlocked = Invoke-Cohort -ManifestPath $manifestD
    Assert-Cohort ($resumeBlocked.ExitCode -eq 6) `
        "Resuming beside a live entry child exited $($resumeBlocked.ExitCode); expected 6."
    Assert-Cohort ($resumeBlocked.Output -match 'live child') 'The refusal did not name the live child it declined to run beside.'
    $recordD2Again = Get-CohortJournalEntry -JournalRoot $journalD -EntryId 'entry-two'
    Assert-Cohort ($recordD2Again.attempt -eq 1) 'A blocked resume still counted an attempt.'

    if ($childPid -gt 0 -and (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $childPid -Force
        Start-Sleep -Milliseconds 500
    }
    # -----------------------------------------------------------------------
    Write-Host '9/23 resume is idempotent and starts exactly the next entry' -ForegroundColor Cyan
    [void](New-StubControl -Path $d2.ControlPath -ExitCode 0 -StartedMarker $markerD)
    $resumed = Invoke-Cohort -ManifestPath $manifestD
    Assert-Cohort ($resumed.ExitCode -eq 0) "The resumed cohort exited $($resumed.ExitCode); expected 0."
    $recordD1After = Get-CohortJournalEntry -JournalRoot $journalD -EntryId 'entry-one'
    Assert-Cohort ($recordD1After.attempt -eq 1) 'The resume re-attempted an entry that had already ended.'
    $recordD2After = Get-CohortJournalEntry -JournalRoot $journalD -EntryId 'entry-two'
    Assert-Cohort ($recordD2After.attempt -eq 2 -and $recordD2After.outcome -eq 'complete') `
        'The resume did not carry the interrupted entry to an ending on a second attempt.'
    $recordD3After = Get-CohortJournalEntry -JournalRoot $journalD -EntryId 'entry-three'
    Assert-Cohort ($recordD3After.outcome -eq 'complete') 'The resume did not go on to the entry after the interrupted one.'
    $indexD = Get-JsonFile -Path (Join-Path $caseD 'index\cohort-index.json')
    Assert-Cohort ($indexD.terminalReason -eq 'completed' -and $indexD.completedEntryCount -eq 3) `
        'The resumed cohort did not publish a completed index over all three entries.'

    # -----------------------------------------------------------------------
    Write-Host '10/23 a journal edited after it was written is refused' -ForegroundColor Cyan
    $journalPathD = Join-Path $journalD 'cohort-journal.json'
    $tamperedJournal = (Get-Content -LiteralPath $journalPathD -Raw) -replace '"attempt": 2', '"attempt": 3'
    [IO.File]::WriteAllBytes($journalPathD, ([Text.UTF8Encoding]::new($false)).GetBytes($tamperedJournal))
    $tamperRun = Invoke-Cohort -ManifestPath $manifestD
    Assert-Cohort ($tamperRun.ExitCode -eq 2) "An edited journal exited $($tamperRun.ExitCode); expected 2."
    Assert-Cohort ($tamperRun.Output -match 'signature') 'The refusal did not name the signature that failed.'

    # -----------------------------------------------------------------------
    Write-Host '11/23 a manifest edited between runs is refused' -ForegroundColor Cyan
    $caseE = Join-Path $sandboxRoot 'case-e'
    $e1 = New-CohortEntryRequest -Sandbox $caseE -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    [void](New-StubControl -Path $e1.ControlPath -ExitCode 0)
    $manifestE = New-CohortManifestFile -Path (Join-Path $caseE 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseE 'journal') -IndexPath (Join-Path $caseE 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $e1 -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runE = Invoke-Cohort -ManifestPath $manifestE
    Assert-Cohort ($runE.ExitCode -eq 0) "The single-entry cohort exited $($runE.ExitCode); expected 0."
    $editedManifest = (Get-Content -LiteralPath $manifestE -Raw) -replace '"entryTimeoutSeconds": 120', '"entryTimeoutSeconds": 121'
    [IO.File]::WriteAllBytes($manifestE, ([Text.UTF8Encoding]::new($false)).GetBytes($editedManifest))
    $editedRun = Invoke-Cohort -ManifestPath $manifestE
    Assert-Cohort ($editedRun.ExitCode -eq 2) "Resuming under an edited manifest exited $($editedRun.ExitCode); expected 2."

    # -----------------------------------------------------------------------
    Write-Host '12/23 a journal key without its journal is not started over' -ForegroundColor Cyan
    Remove-Item -LiteralPath (Join-Path $caseE 'journal\cohort-journal.json') -Force
    $orphanKey = Invoke-Cohort -ManifestPath $manifestE
    Assert-Cohort ($orphanKey.ExitCode -eq 2) "A key without a journal exited $($orphanKey.ExitCode); expected 2."
    Assert-Cohort ($orphanKey.Output -match 'not resumable') 'The refusal did not say the journal root is not resumable.'
    # A key on its own is not a record. A runner killed after minting the key and
    # before its first journal reached the disk started nothing, and wedging a
    # root that never launched anything is not a safety property. The key planted
    # here is the 64-character hexadecimal form an earlier build wrote, which is
    # the one legacy encoding this build still reads: an operator resuming a root
    # written before this change must not be told his own journal is unreadable.
    $caseE2 = Join-Path $sandboxRoot 'case-e2'
    $e2 = New-CohortEntryRequest -Sandbox $caseE2 -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918281
    [void](New-StubControl -Path $e2.ControlPath -ExitCode 0)
    $manifestE2 = New-CohortManifestFile -Path (Join-Path $caseE2 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseE2 'journal') -IndexPath (Join-Path $caseE2 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $e2 -Ordinal 1 -RuleBundlePath $ruleBundle))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $caseE2 'journal'))
    [IO.File]::WriteAllBytes((Join-Path $caseE2 'journal\cohort-journal.key'), `
        ([Text.UTF8Encoding]::new($false)).GetBytes(('a' * 64)))
    $mintedOnly = Invoke-Cohort -ManifestPath $manifestE2
    Assert-Cohort ($mintedOnly.ExitCode -eq 0) "A key minted before any launch exited $($mintedOnly.ExitCode); expected 0."
    $recordE2 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseE2 'journal') -EntryId 'entry-one'
    Assert-Cohort ($recordE2.attempt -eq 1) "The entry under the adopted key was attempted $($recordE2.attempt) time(s); expected 1."

    # The same case under the format this build writes, so the raw path is not
    # kept alive only by the legacy one, and a journal key of any other shape is
    # refused rather than adopted.
    $caseE2b = Join-Path $sandboxRoot 'case-e2b'
    $e2b = New-CohortEntryRequest -Sandbox $caseE2b -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918283
    [void](New-StubControl -Path $e2b.ControlPath -ExitCode 0)
    $manifestE2b = New-CohortManifestFile -Path (Join-Path $caseE2b 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseE2b 'journal') -IndexPath (Join-Path $caseE2b 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $e2b -Ordinal 1 -RuleBundlePath $ruleBundle))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $caseE2b 'journal'))
    $plantedKey = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($plantedKey)
    [IO.File]::WriteAllBytes((Join-Path $caseE2b 'journal\cohort-journal.key'), $plantedKey)
    $rawAdopted = Invoke-Cohort -ManifestPath $manifestE2b
    Assert-Cohort ($rawAdopted.ExitCode -eq 0) "A raw key minted before any launch exited $($rawAdopted.ExitCode); expected 0."

    $caseE2c = Join-Path $sandboxRoot 'case-e2c'
    $e2c = New-CohortEntryRequest -Sandbox $caseE2c -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918284
    [void](New-StubControl -Path $e2c.ControlPath -ExitCode 0)
    $manifestE2c = New-CohortManifestFile -Path (Join-Path $caseE2c 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseE2c 'journal') -IndexPath (Join-Path $caseE2c 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $e2c -Ordinal 1 -RuleBundlePath $ruleBundle))
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $caseE2c 'journal'))
    [IO.File]::WriteAllBytes((Join-Path $caseE2c 'journal\cohort-journal.key'), `
        ([Text.UTF8Encoding]::new($false)).GetBytes(('A' * 64)))
    $badJournalKey = Invoke-Cohort -ManifestPath $manifestE2c
    Assert-Cohort ($badJournalKey.ExitCode -eq 2) `
        "A journal key of an encoding this build never wrote exited $($badJournalKey.ExitCode); expected 2."
    Assert-Cohort ($badJournalKey.Output -notmatch 'Unhandled exception') `
        'A journal key of the wrong encoding came out as a crash rather than as a refusal.'

    # A child reports whatever exit code the operating system gives it, and on
    # this platform an unhandled managed exception reports a negative one. A
    # journal that could not hold what its own writer produced would be signed and
    # then unreadable, and a signed file cannot be repaired by hand.
    $caseE3 = Join-Path $sandboxRoot 'case-e3'
    $e3 = New-CohortEntryRequest -Sandbox $caseE3 -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918282
    [void](New-StubControl -Path $e3.ControlPath -ExitCode -1073741819 -WriteAudit $false)
    $manifestE3 = New-CohortManifestFile -Path (Join-Path $caseE3 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseE3 'journal') -IndexPath (Join-Path $caseE3 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $e3 -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runE3 = Invoke-Cohort -ManifestPath $manifestE3
    Assert-Cohort ($runE3.ExitCode -eq 11) "A cohort whose child died hard exited $($runE3.ExitCode); expected 11."
    $recordE3 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseE3 'journal') -EntryId 'entry-one'
    Assert-Cohort ($recordE3.outcome -eq 'evidenceRefused') "The hard-dying entry ended '$($recordE3.outcome)'; expected evidenceRefused."
    Assert-Cohort ($recordE3.exitCode -lt 0) "The hard-dying entry recorded exit code $($recordE3.exitCode); this case is only a case when it is negative."
    $rebuildE3 = Invoke-Cohort -ManifestPath $manifestE3 -RebuildIndex
    Assert-Cohort ($rebuildE3.ExitCode -eq 0) `
        "Rebuilding over a journal holding a negative exit code exited $($rebuildE3.ExitCode); expected 0."
    $rerunE3 = Invoke-Cohort -ManifestPath $manifestE3
    Assert-Cohort ($rerunE3.ExitCode -eq 11) `
        "Resuming over a journal holding a negative exit code exited $($rerunE3.ExitCode); expected 11."

    # -----------------------------------------------------------------------
    Write-Host '13/23 global budget exhaustion stops before the next entry' -ForegroundColor Cyan
    $caseF = Join-Path $sandboxRoot 'case-f'
    $f1 = New-CohortEntryRequest -Sandbox $caseF -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $f2 = New-CohortEntryRequest -Sandbox $caseF -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    $f3 = New-CohortEntryRequest -Sandbox $caseF -EntryId 'entry-three' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918275
    # Each entry costs four model starts against a sealed estimate of two, which
    # is the shape a real overrun takes: the plan was honest and the world was
    # more expensive.
    foreach ($control in @($f1.ControlPath, $f2.ControlPath, $f3.ControlPath)) {
        [void](New-StubControl -Path $control -ExitCode 0 -Slot1ModelInvocationCount 2 -Slot2ModelInvocationCount 2)
    }
    $manifestF = New-CohortManifestFile -Path (Join-Path $caseF 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -MaxModelStarts 9 `
        -JournalRoot (Join-Path $caseF 'journal') -IndexPath (Join-Path $caseF 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $f1 -Ordinal 1 -RuleBundlePath $ruleBundle -EstimatedModelStarts 2),
        (New-CohortEntryDeclaration -Request $f2 -Ordinal 2 -RuleBundlePath $ruleBundle -EstimatedModelStarts 2),
        (New-CohortEntryDeclaration -Request $f3 -Ordinal 3 -RuleBundlePath $ruleBundle -EstimatedModelStarts 2))
    $runF = Invoke-Cohort -ManifestPath $manifestF
    Assert-Cohort ($runF.ExitCode -eq 10) "The budget-exhausted cohort exited $($runF.ExitCode); expected 10."
    $indexF = Get-JsonFile -Path (Join-Path $caseF 'index\cohort-index.json')
    Assert-Cohort ($indexF.terminalReason -eq 'budgetExhausted') `
        "The budget stop left terminal reason '$($indexF.terminalReason)'; expected budgetExhausted."
    Assert-Cohort ($indexF.pendingEntryCount -eq 1) "The budget stop left $($indexF.pendingEntryCount) entries pending; expected 1."
    Assert-Cohort ($indexF.consumed.modelStarts -eq 8) "The budget stop accounted $($indexF.consumed.modelStarts) model starts; expected 8."
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $f3.OutputRoot 'coordinator\audit.json'))) `
        'The entry past the ceiling produced evidence, so the ceiling was checked too late.'

    # An entry that ran and left no readable audit did not thereby cost nothing;
    # it cost an amount nobody can state, and nothing it left behind says whether
    # anything acted on its behalf. Neither the ceiling nor the zero-write claim
    # can be computed over that, so the cohort stops there whatever the stop
    # policy says, and stays stopped until an operator settles that output root.
    $caseFq = Join-Path $sandboxRoot 'case-f-unaccounted'
    $fq1 = New-CohortEntryRequest -Sandbox $caseFq -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $fq2 = New-CohortEntryRequest -Sandbox $caseFq -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    $fq3 = New-CohortEntryRequest -Sandbox $caseFq -EntryId 'entry-three' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918275
    [void](New-StubControl -Path $fq1.ControlPath -ExitCode 0)
    [void](New-StubControl -Path $fq2.ControlPath -ExitCode -1073741819 -WriteAudit $false)
    [void](New-StubControl -Path $fq3.ControlPath -ExitCode 0)
    $manifestFq = New-CohortManifestFile -Path (Join-Path $caseFq 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -MaxModelStarts 9 -StopPolicy 'continueOnTerminalFailure' `
        -JournalRoot (Join-Path $caseFq 'journal') -IndexPath (Join-Path $caseFq 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $fq1 -Ordinal 1 -RuleBundlePath $ruleBundle -EstimatedModelStarts 2),
        (New-CohortEntryDeclaration -Request $fq2 -Ordinal 2 -RuleBundlePath $ruleBundle -EstimatedModelStarts 2),
        (New-CohortEntryDeclaration -Request $fq3 -Ordinal 3 -RuleBundlePath $ruleBundle -EstimatedModelStarts 2))
    $runFq = Invoke-Cohort -ManifestPath $manifestFq
    Assert-Cohort ($runFq.ExitCode -eq 11) `
        "A cohort holding an entry with no audit exited $($runFq.ExitCode); expected 11, so the continue policy did not carry it past a preparation nobody can account for."
    $recordFq2 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseFq 'journal') -EntryId 'entry-two'
    Assert-Cohort ($recordFq2.outcome -eq 'evidenceRefused') "The unaccounted entry ended '$($recordFq2.outcome)'; expected evidenceRefused."
    Assert-Cohort ($recordFq2.auditSha256 -eq 'none') 'The unaccounted entry recorded an audit digest it never published.'
    Assert-Cohort ($recordFq2.modelStartCount -eq 0) 'The unaccounted entry recorded model starts it never reported.'
    $recordFq3 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseFq 'journal') -EntryId 'entry-three'
    Assert-Cohort ($recordFq3.state -eq 'pending' -and $recordFq3.attempt -eq 0) `
        'The entry after an unaccounted one was started, so the ceiling was funded by a run nobody can account for.'
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $fq3.OutputRoot 'coordinator\audit.json'))) `
        'The entry past an unaccounted one produced evidence.'
    $indexFq = Get-JsonFile -Path (Join-Path $caseFq 'index\cohort-index.json')
    Assert-Cohort ($indexFq.terminalReason -eq 'blocked') `
        "The cohort holding an unaccounted entry published terminal reason '$($indexFq.terminalReason)'; expected blocked."
    $summaryFq2 = Get-CohortIndexEntry -Index $indexFq -EntryId 'entry-two'
    Assert-Cohort ($summaryFq2.providerWriteCount -eq 0 -and $summaryFq2.state -eq 'ended') `
        'The index does not report the unaccounted entry as ended.'

    # -----------------------------------------------------------------------
    Write-Host '14/23 an observed provider write blocks the whole cohort' -ForegroundColor Cyan
    $caseG = Join-Path $sandboxRoot 'case-g'
    $g1 = New-CohortEntryRequest -Sandbox $caseG -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $g2 = New-CohortEntryRequest -Sandbox $caseG -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    [void](New-StubControl -Path $g1.ControlPath -ExitCode 0 -ProviderWriteCount 1 -WriteToolInvocations 1)
    [void](New-StubControl -Path $g2.ControlPath -ExitCode 0)
    $manifestG = New-CohortManifestFile -Path (Join-Path $caseG 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseG 'journal') -IndexPath (Join-Path $caseG 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $g1 -Ordinal 1 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $g2 -Ordinal 2 -RuleBundlePath $ruleBundle))
    $runG = Invoke-Cohort -ManifestPath $manifestG
    Assert-Cohort ($runG.ExitCode -eq 11) "A cohort that observed a provider write exited $($runG.ExitCode); expected 11."
    $indexG = Get-JsonFile -Path (Join-Path $caseG 'index\cohort-index.json')
    Assert-Cohort ($indexG.terminalReason -eq 'blocked') "The write observation left terminal reason '$($indexG.terminalReason)'; expected blocked."
    Assert-Cohort ($indexG.terminalDetail -notmatch [regex]::Escape($caseG)) 'The index published a refusal that names an output root.'
    Assert-Cohort ($indexG.terminalDetailSha256 -match '^[0-9a-f]{64}$') 'The index published no digest of the refusal it is reporting.'
    $recordG2 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseG 'journal') -EntryId 'entry-two'
    Assert-Cohort ($recordG2.state -eq 'pending') 'A blocked cohort still went on to its next entry.'
    # The entry whose evidence was refused is CLOSED, not left running. An entry
    # left open once its child is gone is an entry a resume would start a second
    # time against an output root that already reported a write.
    $recordG1 = Get-CohortJournalEntry -JournalRoot (Join-Path $caseG 'journal') -EntryId 'entry-one'
    Assert-Cohort ($recordG1.state -eq 'ended' -and $recordG1.outcome -eq 'evidenceRefused') `
        "The refused entry was left '$($recordG1.state)'/'$($recordG1.outcome)'; expected ended/evidenceRefused."
    # And the cohort stays blocked. Re-running does not walk past the refusal,
    # and does not attempt either entry again.
    $rerunG = Invoke-Cohort -ManifestPath $manifestG
    Assert-Cohort ($rerunG.ExitCode -eq 11) "Re-running a blocked cohort exited $($rerunG.ExitCode); expected 11."
    $recordG1After = Get-CohortJournalEntry -JournalRoot (Join-Path $caseG 'journal') -EntryId 'entry-one'
    Assert-Cohort ($recordG1After.attempt -eq 1) "The refused entry was attempted $($recordG1After.attempt) time(s); expected 1."
    $recordG2After = Get-CohortJournalEntry -JournalRoot (Join-Path $caseG 'journal') -EntryId 'entry-two'
    Assert-Cohort ($recordG2After.state -eq 'pending' -and $recordG2After.attempt -eq 0) `
        'A blocked cohort started its next entry on a later run.'
    Assert-Cohort (-not ($rerunG.Output -match 'contoso')) 'A cohort refusal spoke a subject on stdout or stderr.'
    # The observed write survives into the index. An entry closed BECAUSE its audit
    # reported a write must not be summarized as one that wrote nothing: that would
    # publish, over a signature, the opposite of the fact that stopped the cohort.
    $indexEntryG1 = Get-CohortIndexEntry -Index (Get-JsonFile -Path (Join-Path $caseG 'index\cohort-index.json')) -EntryId 'entry-one'
    Assert-Cohort ($indexEntryG1.providerWriteCount -eq 1) `
        "The index reports $($indexEntryG1.providerWriteCount) provider write(s) for the entry that was refused for writing; expected 1."
    Assert-Cohort ($indexG.consumed.providerWrites -ge 1) `
        'The index totals report no provider write for a cohort that stopped because it observed one.'

    # -----------------------------------------------------------------------
    Write-Host '15/23 an entry audit this build cannot read blocks the whole cohort' -ForegroundColor Cyan
    $caseH = Join-Path $sandboxRoot 'case-h'
    $h1 = New-CohortEntryRequest -Sandbox $caseH -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $h2 = New-CohortEntryRequest -Sandbox $caseH -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    [void](New-StubControl -Path $h1.ControlPath -ExitCode 0 -AuditContractVersion 'devpilot.shadow-run-coordinator.audit.v99')
    [void](New-StubControl -Path $h2.ControlPath -ExitCode 0)
    $manifestH = New-CohortManifestFile -Path (Join-Path $caseH 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseH 'journal') -IndexPath (Join-Path $caseH 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $h1 -Ordinal 1 -RuleBundlePath $ruleBundle),
        (New-CohortEntryDeclaration -Request $h2 -Ordinal 2 -RuleBundlePath $ruleBundle))
    $runH = Invoke-Cohort -ManifestPath $manifestH
    Assert-Cohort ($runH.ExitCode -eq 11) "An unreadable entry audit exited $($runH.ExitCode); expected 11."

    # An audit is only worth what it can be shown to be. Each of these publishes a
    # perfectly well-shaped audit at the right path with the right correlation, and
    # each is refused: an unbound one, a carelessly edited one, a carefully edited
    # one, and one whose key is gone.
    $tampers = @(
        @{ Id = 'unbound'; Control = @{ RequestSha256Override = ('c' * 64) } },
        @{ Id = 'careless'; Control = @{ TamperSelfHash = $true } },
        @{ Id = 'careful'; Control = @{ TamperSignature = $true } },
        @{ Id = 'keyless'; Control = @{ WriteStateKey = $false } },
        # The key format itself. A key is 32 raw bytes; every other shape a file
        # in that place could take is refused as a key this build never wrote,
        # and refused as a refusal rather than as a fault from underneath. The
        # hexadecimal one is the format an earlier build used for the COHORT
        # journal key and never for this one, so it is not quietly adopted here.
        @{ Id = 'hexkey'; Control = @{ StateKeyEncoding = 'legacyHex' }; ExpectKeyLength = 64 },
        @{ Id = 'shortkey'; Control = @{ StateKeyEncoding = 'short' }; ExpectKeyLength = 31 },
        @{ Id = 'longkey'; Control = @{ StateKeyEncoding = 'long' }; ExpectKeyLength = 33 },
        @{ Id = 'emptykey'; Control = @{ StateKeyEncoding = 'empty' }; ExpectKeyLength = 0 },
        @{ Id = 'wrongkey'; Control = @{ SigningKeyOverride = ('e' * 64) } },
        @{ Id = 'othersubject'; Control = @{ SubjectSha256Override = ('d' * 64) } })
    foreach ($tamper in $tampers) {
        $caseTamper = Join-Path $sandboxRoot ('case-h-' + $tamper.Id)
        $tamperRequest = New-CohortEntryRequest -Sandbox $caseTamper -EntryId 'entry-one' `
            -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918275
        $tamperControl = @($tamper.Control)[0]
        [void](New-StubControl -Path $tamperRequest.ControlPath -ExitCode 0 @tamperControl)
        $manifestTamper = New-CohortManifestFile -Path (Join-Path $caseTamper 'cohort.json') `
            -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
            -JournalRoot (Join-Path $caseTamper 'journal') -IndexPath (Join-Path $caseTamper 'index\cohort-index.json') `
            -StubPath $stub -Entries @(
            (New-CohortEntryDeclaration -Request $tamperRequest -Ordinal 1 -RuleBundlePath $ruleBundle))
        $runTamper = Invoke-Cohort -ManifestPath $manifestTamper
        Assert-Cohort ($runTamper.ExitCode -eq 11) `
            "An entry audit that could not be authenticated ($($tamper.Id)) exited $($runTamper.ExitCode); expected 11."
        $recordTamper = Get-CohortJournalEntry -JournalRoot (Join-Path $caseTamper 'journal') -EntryId 'entry-one'
        Assert-Cohort ($recordTamper.outcome -eq 'evidenceRefused') `
            "An unauthenticated audit ($($tamper.Id)) left outcome '$($recordTamper.outcome)'; expected evidenceRefused."
        # A key-format case that never wrote the key it names would be refused for
        # the reason every keyless entry is refused, and would keep passing if the
        # length rules it exists to pin were removed. So the file it planted is
        # read back, and the refusal is required to be about that length.
        if ($tamper.ContainsKey('ExpectKeyLength')) {
            $tamperKeyPath = Join-Path $tamperRequest.OutputRoot 'coordinator\state.key'
            Assert-Cohort (Test-Path -LiteralPath $tamperKeyPath) `
                "The $($tamper.Id) case planted no key at all, so it does not test the key format."
            $tamperKeyLength = [IO.File]::ReadAllBytes($tamperKeyPath).Length
            Assert-Cohort ($tamperKeyLength -eq $tamper.ExpectKeyLength) `
                "The $($tamper.Id) case planted a $tamperKeyLength byte key; expected $($tamper.ExpectKeyLength)."
            Assert-Cohort ($runTamper.Output -match "is $tamperKeyLength bytes, not 32") `
                "The $($tamper.Id) case was not refused for the length it planted. $($runTamper.Output)"
        }
    }

    # The absolute path of the key is in the refusal, because the operator's next
    # action is to go and look at that file.
    $caseKeyPath = Join-Path $sandboxRoot 'case-h-keypath'
    $keyPathRequest = New-CohortEntryRequest -Sandbox $caseKeyPath -EntryId 'entry-one' `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918277
    [void](New-StubControl -Path $keyPathRequest.ControlPath -ExitCode 0 -StateKeyEncoding 'short')
    $manifestKeyPath = New-CohortManifestFile -Path (Join-Path $caseKeyPath 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseKeyPath 'journal') -IndexPath (Join-Path $caseKeyPath 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $keyPathRequest -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runKeyPath = Invoke-Cohort -ManifestPath $manifestKeyPath
    Assert-Cohort ($runKeyPath.ExitCode -eq 11) `
        "A key of the wrong length exited $($runKeyPath.ExitCode); expected 11."
    $expectedKeyFile = [string]([IO.Path]::GetFullPath((Join-Path $keyPathRequest.OutputRoot 'coordinator\state.key')))
    Assert-Cohort ($runKeyPath.Output -match [Regex]::Escape($expectedKeyFile)) `
        'The refusal did not name the absolute path of the key it could not take.'
    Assert-Cohort ($runKeyPath.Output -match '31 bytes') `
        'The refusal did not say what was found instead of a key.'

    # A key that cannot be read at all, rather than one that reads as the wrong
    # thing. This is the fault the pilot hit: a read that throws from underneath
    # is a runtime crash, and a cohort that crashes has published nothing about
    # what it did. It must come out as a refusal with an exit code.
    $caseUnreadable = Join-Path $sandboxRoot 'case-h-unreadable'
    $unreadable = New-CohortEntryRequest -Sandbox $caseUnreadable -EntryId 'entry-one' `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918278
    [void](New-StubControl -Path $unreadable.ControlPath -ExitCode 0)
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $unreadable.OutputRoot 'coordinator\state.key'))
    $manifestUnreadable = New-CohortManifestFile -Path (Join-Path $caseUnreadable 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseUnreadable 'journal') -IndexPath (Join-Path $caseUnreadable 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $unreadable -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runUnreadable = Invoke-Cohort -ManifestPath $manifestUnreadable
    Assert-Cohort ($runUnreadable.ExitCode -eq 11) `
        "A key that could not be read exited $($runUnreadable.ExitCode); expected 11."
    Assert-Cohort ($runUnreadable.Output -notmatch 'Unhandled exception') `
        'A key that could not be read came out as a crash rather than as a refusal.'

    # A key replaced after the entry was authenticated. The index is rebuilt from
    # the artifacts, so the second reading is a fresh read of the same file, and a
    # root whose key changed underneath cannot be shown to hold what it published.
    $caseRotated = Join-Path $sandboxRoot 'case-h-rotated'
    $rotated = New-CohortEntryRequest -Sandbox $caseRotated -EntryId 'entry-one' `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918279
    [void](New-StubControl -Path $rotated.ControlPath -ExitCode 0)
    $manifestRotated = New-CohortManifestFile -Path (Join-Path $caseRotated 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseRotated 'journal') -IndexPath (Join-Path $caseRotated 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $rotated -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runRotated = Invoke-Cohort -ManifestPath $manifestRotated
    Assert-Cohort ($runRotated.ExitCode -eq 0) `
        "An entry signed with the key in its own root exited $($runRotated.ExitCode); expected 0."
    $rotatedKeyPath = Join-Path $rotated.OutputRoot 'coordinator\state.key'
    $replacement = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($replacement)
    [IO.File]::WriteAllBytes($rotatedKeyPath, $replacement)
    $rebuildRotated = Invoke-Cohort -ManifestPath $manifestRotated -RebuildIndex
    Assert-Cohort ($rebuildRotated.ExitCode -eq 11) `
        "A rebuild over a rotated key exited $($rebuildRotated.ExitCode); expected 11."


    # A key that is not text in any encoding, which is what most 32-byte keys are.
    # Deterministic where the real preparation's random key is one draw: these
    # bytes decode as nothing, and the entry they sign must still authenticate.
    $caseBinaryKey = Join-Path $sandboxRoot 'case-h-binarykey'
    $binaryKey = New-CohortEntryRequest -Sandbox $caseBinaryKey -EntryId 'entry-one' `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918280
    [void](New-StubControl -Path $binaryKey.ControlPath -ExitCode 0 -StateKey ('ff' * 32))
    $manifestBinaryKey = New-CohortManifestFile -Path (Join-Path $caseBinaryKey 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseBinaryKey 'journal') -IndexPath (Join-Path $caseBinaryKey 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $binaryKey -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runBinaryKey = Invoke-Cohort -ManifestPath $manifestBinaryKey
    Assert-Cohort ($runBinaryKey.ExitCode -eq 0) `
        "An entry signed with a key that is not valid UTF-8 exited $($runBinaryKey.ExitCode); expected 0. $($runBinaryKey.Output)"
    $indexBinaryKey = Get-JsonFile -Path (Join-Path $caseBinaryKey 'index\cohort-index.json')
    $summaryBinaryKey = Get-CohortIndexEntry -Index $indexBinaryKey -EntryId 'entry-one'
    Assert-Cohort ($summaryBinaryKey.outcome -eq 'complete') `
        "An entry under a non-textual key was recorded '$($summaryBinaryKey.outcome)'; expected complete."

    # An audit that cannot be read at all. A cohort treats a failure to WRITE its
    # index leniently - the journal is authoritative - so a failure to READ an
    # audit must not arrive as the same kind of fault, or a locked artifact would
    # be reported as a cohort that published nothing and carried on. It is a
    # refusal that blocks the set, and under a rebuild it is still a refusal
    # rather than a crash.
    $caseLockedAudit = Join-Path $sandboxRoot 'case-h-lockedaudit'
    $lockedAudit = New-CohortEntryRequest -Sandbox $caseLockedAudit -EntryId 'entry-one' `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918281
    [void](New-StubControl -Path $lockedAudit.ControlPath -ExitCode 0)
    $manifestLockedAudit = New-CohortManifestFile -Path (Join-Path $caseLockedAudit 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseLockedAudit 'journal') -IndexPath (Join-Path $caseLockedAudit 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $lockedAudit -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runLockedAudit = Invoke-Cohort -ManifestPath $manifestLockedAudit
    Assert-Cohort ($runLockedAudit.ExitCode -eq 0) `
        "The run before the locked-audit rebuild exited $($runLockedAudit.ExitCode); expected 0."
    $lockedAuditPath = Join-Path $lockedAudit.OutputRoot 'coordinator\audit.json'
    $lockedHandle = [IO.File]::Open($lockedAuditPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try
    {
        $rebuildLocked = Invoke-Cohort -ManifestPath $manifestLockedAudit -RebuildIndex
    }
    finally
    {
        $lockedHandle.Dispose()
    }
    Assert-Cohort ($rebuildLocked.ExitCode -eq 11) `
        "A rebuild over an audit no reader could open exited $($rebuildLocked.ExitCode); expected 11. $($rebuildLocked.Output)"
    Assert-Cohort ($rebuildLocked.Output -notmatch 'Unhandled exception') `
        'An audit that could not be opened came out as a crash rather than as a refusal.'
    Assert-Cohort ($rebuildLocked.Output -match [regex]::Escape($lockedAuditPath)) `
        'A rebuild refused over an unreadable audit did not name the audit it could not read.'
    $rebuildAfterUnlock = Invoke-Cohort -ManifestPath $manifestLockedAudit -RebuildIndex
    Assert-Cohort ($rebuildAfterUnlock.ExitCode -eq 0) `
        "A rebuild after the audit was released exited $($rebuildAfterUnlock.ExitCode); expected 0."

    # A preparation that exits cleanly has published its audit; that is what
    # exiting cleanly means here. Absence is not a cheap success: summarized as
    # not-run it would report a completed entry with no evidence, no model starts
    # and no write counters, which is exactly the shape of a cohort claiming to
    # have written nothing while having no idea what it did.
    $caseHollow = Join-Path $sandboxRoot 'case-h-hollow'
    $hollow = New-CohortEntryRequest -Sandbox $caseHollow -EntryId 'entry-one' `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918276
    [void](New-StubControl -Path $hollow.ControlPath -ExitCode 0 -WriteAudit $false)
    $manifestHollow = New-CohortManifestFile -Path (Join-Path $caseHollow 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseHollow 'journal') -IndexPath (Join-Path $caseHollow 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $hollow -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runHollow = Invoke-Cohort -ManifestPath $manifestHollow
    Assert-Cohort ($runHollow.ExitCode -eq 11) `
        "A completed entry that published no audit exited $($runHollow.ExitCode); expected 11."
    $recordHollow = Get-CohortJournalEntry -JournalRoot (Join-Path $caseHollow 'journal') -EntryId 'entry-one'
    Assert-Cohort ($recordHollow.outcome -eq 'evidenceRefused') `
        "A completed entry with no audit left outcome '$($recordHollow.outcome)'; expected evidenceRefused."
    $indexHollow = Get-JsonFile -Path (Join-Path $caseHollow 'index\cohort-index.json')
    Assert-Cohort ($indexHollow.terminalReason -eq 'blocked') `
        "A completed entry with no audit published terminal reason '$($indexHollow.terminalReason)'; expected blocked."

    # -----------------------------------------------------------------------
    Write-Host '16/23 identity drift between the manifest and the request is refused' -ForegroundColor Cyan
    $caseI = Join-Path $sandboxRoot 'case-i'
    $i1 = New-CohortEntryRequest -Sandbox $caseI -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    [void](New-StubControl -Path $i1.ControlPath -ExitCode 0)
    $manifestI = New-CohortManifestFile -Path (Join-Path $caseI 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseI 'journal') -IndexPath (Join-Path $caseI 'index\cohort-index.json') `
        -StubPath $stub -Entries @(
        (New-CohortEntryDeclaration -Request $i1 -Ordinal 1 -RuleBundlePath $ruleBundle -SubjectOverride @{ iterationId = 7 }))
    $runI = Invoke-Cohort -ManifestPath $manifestI
    Assert-Cohort ($runI.ExitCode -eq 2) "An entry whose subject drifted exited $($runI.ExitCode); expected 2."
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $i1.OutputRoot 'coordinator\audit.json'))) `
        'An entry with a drifted subject was started anyway.'
    $indexI = Get-JsonFile -Path (Join-Path $caseI 'index\cohort-index.json')
    Assert-Cohort ($indexI.terminalReason -eq 'contractRefusal') 'The refusal was not published in the index.'

    # -----------------------------------------------------------------------
    Write-Host '17/23 a request edited after the manifest sealed it is refused' -ForegroundColor Cyan
    $caseJ = Join-Path $sandboxRoot 'case-j'
    $j1 = New-CohortEntryRequest -Sandbox $caseJ -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    [void](New-StubControl -Path $j1.ControlPath -ExitCode 0)
    $manifestJ = New-CohortManifestFile -Path (Join-Path $caseJ 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseJ 'journal') -IndexPath (Join-Path $caseJ 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $j1 -Ordinal 1 -RuleBundlePath $ruleBundle))
    $editedRequest = (Get-Content -LiteralPath $j1.Path -Raw) -replace '"timeoutSeconds": 900', '"timeoutSeconds": 901'
    [IO.File]::WriteAllBytes($j1.Path, ([Text.UTF8Encoding]::new($false)).GetBytes($editedRequest))
    $runJ = Invoke-Cohort -ManifestPath $manifestJ
    Assert-Cohort ($runJ.ExitCode -eq 2) "An edited entry request exited $($runJ.ExitCode); expected 2."
    Assert-Cohort ($runJ.Output -match 'nobody authorized') 'The refusal did not say the request was never authorized.'

    # -----------------------------------------------------------------------
    Write-Host '18/23 a rule bundle that changed under the declaration is refused' -ForegroundColor Cyan
    $caseK = Join-Path $sandboxRoot 'case-k'
    $bundleK = Write-StrictJsonFile -Path (Join-Path $caseK 'inputs\rule-bundle.json') -Value ([pscustomobject]@{ declaredPaths = @('a') })
    $k1 = New-CohortEntryRequest -Sandbox $caseK -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    [void](New-StubControl -Path $k1.ControlPath -ExitCode 0)
    $manifestK = New-CohortManifestFile -Path (Join-Path $caseK 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseK 'journal') -IndexPath (Join-Path $caseK 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $k1 -Ordinal 1 -RuleBundlePath $bundleK))
    [void](Write-StrictJsonFile -Path $bundleK -Value ([pscustomobject]@{ declaredPaths = @('a', 'b') }))
    $runK = Invoke-Cohort -ManifestPath $manifestK
    Assert-Cohort ($runK.ExitCode -eq 2) "A changed rule bundle exited $($runK.ExitCode); expected 2."

    # -----------------------------------------------------------------------
    Write-Host '19/23 a toolkit that moved under the cohort is refused' -ForegroundColor Cyan
    $caseL = Join-Path $sandboxRoot 'case-l'
    $movedToolkit = New-CohortToolkit -Root (Join-Path $caseL 'toolkit') -Head $head
    $l1 = New-CohortEntryRequest -Sandbox $caseL -EntryId 'entry-one' -ToolkitRoot $movedToolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    [void](New-StubControl -Path $l1.ControlPath -ExitCode 0)
    $manifestL = New-CohortManifestFile -Path (Join-Path $caseL 'cohort.json') `
        -ToolkitRoot $movedToolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseL 'journal') -IndexPath (Join-Path $caseL 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $l1 -Ordinal 1 -RuleBundlePath $ruleBundle))
    [void](New-CohortToolkit -Root $movedToolkit -Head (New-FakeCommit))
    $runL = Invoke-Cohort -ManifestPath $manifestL
    Assert-Cohort ($runL.ExitCode -eq 2) "A cohort whose checkout moved exited $($runL.ExitCode); expected 2."
    Assert-Cohort ($runL.Output -match 'reviewed build') 'The refusal did not say a moved checkout is a different build.'
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $l1.OutputRoot 'coordinator\audit.json'))) `
        'An entry was started under a checkout the manifest no longer describes.'

    # -----------------------------------------------------------------------
    Write-Host '20/23 manifest shapes this build never runs' -ForegroundColor Cyan
    $caseM = Join-Path $sandboxRoot 'case-m'
    $m1 = New-CohortEntryRequest -Sandbox $caseM -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273
    $m2 = New-CohortEntryRequest -Sandbox $caseM -EntryId 'entry-two' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918274
    $declarationM1 = New-CohortEntryDeclaration -Request $m1 -Ordinal 1 -RuleBundlePath $ruleBundle
    $declarationM2 = New-CohortEntryDeclaration -Request $m2 -Ordinal 2 -RuleBundlePath $ruleBundle

    $parallel = New-CohortManifestFile -Path (Join-Path $caseM 'parallel.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -Concurrency 2 `
        -JournalRoot (Join-Path $caseM 'journal-parallel') -IndexPath (Join-Path $caseM 'index\parallel.json') `
        -StubPath $stub -Entries @($declarationM1, $declarationM2)
    $runParallel = Invoke-Cohort -ManifestPath $parallel
    Assert-Cohort ($runParallel.ExitCode -eq 2) "A cohort declaring concurrency 2 exited $($runParallel.ExitCode); expected 2."

    $empty = New-CohortManifestFile -Path (Join-Path $caseM 'empty.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseM 'journal-empty') -IndexPath (Join-Path $caseM 'index\empty.json') `
        -StubPath $stub -Entries @()
    Assert-Cohort ((Invoke-Cohort -ManifestPath $empty).ExitCode -eq 2) 'A cohort declaring no entries was not refused.'

    $duplicateSubject = New-CohortEntryDeclaration -Request $m2 -Ordinal 2 -RuleBundlePath $ruleBundle `
        -SubjectOverride @{ pullRequestId = $m1.Subject.pullRequestId; iterationId = $m1.Subject.iterationId }
    $duplicate = New-CohortManifestFile -Path (Join-Path $caseM 'duplicate.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseM 'journal-duplicate') -IndexPath (Join-Path $caseM 'index\duplicate.json') `
        -StubPath $stub -Entries @($declarationM1, $duplicateSubject)
    $runDuplicate = Invoke-Cohort -ManifestPath $duplicate
    Assert-Cohort ($runDuplicate.ExitCode -eq 2) "A cohort declaring one pull request twice exited $($runDuplicate.ExitCode); expected 2."
    Assert-Cohort ($runDuplicate.Output -match 'more than once') 'The refusal did not name the repeated subject.'

    $collision = New-CohortEntryDeclaration -Request $m2 -Ordinal 2 -RuleBundlePath $ruleBundle -OutputRootOverride $m1.OutputRoot
    $collided = New-CohortManifestFile -Path (Join-Path $caseM 'collision.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseM 'journal-collision') -IndexPath (Join-Path $caseM 'index\collision.json') `
        -StubPath $stub -Entries @($declarationM1, $collision)
    $runCollision = Invoke-Cohort -ManifestPath $collided
    Assert-Cohort ($runCollision.ExitCode -eq 2) "A cohort sharing one output root exited $($runCollision.ExitCode); expected 2."

    $outOfOrder = New-CohortEntryDeclaration -Request $m2 -Ordinal 3 -RuleBundlePath $ruleBundle
    $misordered = New-CohortManifestFile -Path (Join-Path $caseM 'order.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseM 'journal-order') -IndexPath (Join-Path $caseM 'index\order.json') `
        -StubPath $stub -Entries @($declarationM1, $outOfOrder)
    Assert-Cohort ((Invoke-Cohort -ManifestPath $misordered).ExitCode -eq 2) 'A cohort whose declared order disagrees with itself was not refused.'

    $overBudget = New-CohortManifestFile -Path (Join-Path $caseM 'over-budget.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -MaxModelStarts 3 `
        -JournalRoot (Join-Path $caseM 'journal-over') -IndexPath (Join-Path $caseM 'index\over.json') `
        -StubPath $stub -Entries @($declarationM1, $declarationM2)
    $runOver = Invoke-Cohort -ManifestPath $overBudget
    Assert-Cohort ($runOver.ExitCode -eq 2) "A cohort that cannot fit its own ceiling exited $($runOver.ExitCode); expected 2."

    $unknown = New-CohortManifestFile -Path (Join-Path $caseM 'unknown.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseM 'journal-unknown') -IndexPath (Join-Path $caseM 'index\unknown.json') `
        -StubPath $stub -Entries @($declarationM1) -ExtraRoot @{ retryPolicy = 'twice' }
    $runUnknown = Invoke-Cohort -ManifestPath $unknown
    Assert-Cohort ($runUnknown.ExitCode -eq 2) "A manifest carrying an unknown field exited $($runUnknown.ExitCode); expected 2."

    # Where a cohort's own record lives cannot depend on the directory a run was
    # started from, or a resume would read a different journal and start entries
    # that already ran.
    $relativeJournal = New-CohortManifestFile -Path (Join-Path $caseM 'relative-journal.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot 'journal-relative' -IndexPath (Join-Path $caseM 'index\relative.json') `
        -StubPath $stub -Entries @($declarationM1)
    $runRelativeJournal = Invoke-Cohort -ManifestPath $relativeJournal
    Assert-Cohort ($runRelativeJournal.ExitCode -eq 2) "A cohort declaring a relative journal root exited $($runRelativeJournal.ExitCode); expected 2."
    Assert-Cohort ($runRelativeJournal.Output -match 'absolute path') 'The refusal did not ask for an absolute journal root.'

    $relativeIndex = New-CohortManifestFile -Path (Join-Path $caseM 'relative-index.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseM 'journal-relative-index') -IndexPath 'index\relative.json' `
        -StubPath $stub -Entries @($declarationM1)
    Assert-Cohort ((Invoke-Cohort -ManifestPath $relativeIndex).ExitCode -eq 2) 'A cohort declaring a relative index path was not refused.'

    # Rooted is not enough on Windows: a drive-relative path and a root-relative
    # one are both rooted and both still resolve against the current directory.
    $partialIndex = 0
    foreach ($partial in @('\cohort\index.json', 'C:cohort-index.json')) {
        $partialIndex++
        $partiallyQualified = New-CohortManifestFile -Path (Join-Path $caseM "partial-$partialIndex.json") `
            -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
            -JournalRoot (Join-Path $caseM "journal-partial-$partialIndex") -IndexPath $partial `
            -StubPath $stub -Entries @($declarationM1)
        $runPartial = Invoke-Cohort -ManifestPath $partiallyQualified
        Assert-Cohort ($runPartial.ExitCode -eq 2) `
            "A cohort declaring the partially qualified index path '$partial' exited $($runPartial.ExitCode); expected 2."
    }

    # The index is rewritten on every publish, including while the walk is still
    # going, so declaring it over the record it is derived from would destroy that
    # record before anyone read either.
    $overJournalRoot = Join-Path $caseM 'journal-over-index'
    $overCase = 0
    foreach ($over in @(
            (Join-Path $overJournalRoot 'cohort-journal.json'),
            (Join-Path $overJournalRoot 'cohort-journal.key'),
            (Join-Path $overJournalRoot 'intents'),
            $m1.Path,
            $ruleBundle,
            (Join-Path $m1.OutputRoot 'coordinator\audit.json'))) {
        $overCase++
        $overIndex = New-CohortManifestFile -Path (Join-Path $caseM "over-$overCase.json") `
            -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
            -JournalRoot $overJournalRoot -IndexPath $over `
            -StubPath $stub -Entries @($declarationM1)
        $runOverIndex = Invoke-Cohort -ManifestPath $overIndex
        Assert-Cohort ($runOverIndex.ExitCode -eq 2) `
            "A cohort declaring its index over '$([IO.Path]::GetFileName($over))' exited $($runOverIndex.ExitCode); expected 2."
    }

    # The manifest is the one input the whole cohort is read from, so an index
    # declared over it would leave the cohort unable to be resumed at all.
    $overSelfPath = Join-Path $caseM 'over-self.json'
    [void](New-CohortManifestFile -Path $overSelfPath `
            -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
            -JournalRoot (Join-Path $caseM 'journal-over-self') -IndexPath $overSelfPath `
            -StubPath $stub -Entries @($declarationM1))
    $runOverSelf = Invoke-Cohort -ManifestPath $overSelfPath
    Assert-Cohort ($runOverSelf.ExitCode -eq 2) `
        "A cohort declaring its index over its own manifest exited $($runOverSelf.ExitCode); expected 2."

    # An entry path is held to the same rule as the journal for a sharper reason:
    # the child preparation is started in the toolkit checkout, so the parent and
    # the child would resolve a relative one against two different directories.
    foreach ($shape in @('request', 'output', 'ruleBundle')) {
        $partialEntry = New-CohortEntryDeclaration -Request $m1 -Ordinal 1 -RuleBundlePath $ruleBundle
        if ($shape -eq 'request') { $partialEntry.request.path = 'entry-one.request.json' }
        if ($shape -eq 'output') { $partialEntry.output.root = 'runs\entry-one' }
        if ($shape -eq 'ruleBundle') { $partialEntry.ruleBundle.declarationPath = 'rules\bundle.json' }
        $partialManifest = New-CohortManifestFile -Path (Join-Path $caseM "entry-relative-$shape.json") `
            -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
            -JournalRoot (Join-Path $caseM "journal-entry-relative-$shape") `
            -IndexPath (Join-Path $caseM "index\entry-relative-$shape.json") `
            -StubPath $stub -Entries @($partialEntry)
        $runPartialEntry = Invoke-Cohort -ManifestPath $partialManifest
        Assert-Cohort ($runPartialEntry.ExitCode -eq 2) `
            "A cohort declaring a relative entry $shape path exited $($runPartialEntry.ExitCode); expected 2."
    }

    $wrongKind = New-CohortManifestFile -Path (Join-Path $caseM 'kind.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -AuthorizationKind 'PreviewAndComment' `
        -JournalRoot (Join-Path $caseM 'journal-kind') -IndexPath (Join-Path $caseM 'index\kind.json') `
        -StubPath $stub -Entries @($declarationM1)
    Assert-Cohort ((Invoke-Cohort -ManifestPath $wrongKind).ExitCode -eq 2) 'A cohort authorizing anything but preview-only was not refused.'

    $writeBudget = New-CohortManifestFile -Path (Join-Path $caseM 'writes.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -ProviderWriteBudget 1 `
        -JournalRoot (Join-Path $caseM 'journal-writes') -IndexPath (Join-Path $caseM 'index\writes.json') `
        -StubPath $stub -Entries @($declarationM1)
    Assert-Cohort ((Invoke-Cohort -ManifestPath $writeBudget).ExitCode -eq 2) 'A cohort asking for a write budget was not refused.'

    # -----------------------------------------------------------------------
    Write-Host '21/23 an entry that declares less than the full pipeline is refused' -ForegroundColor Cyan
    $caseN = Join-Path $sandboxRoot 'case-n'
    $n1 = New-CohortEntryRequest -Sandbox $caseN -EntryId 'entry-one' -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef -PullRequestId 918273 -WithoutDelivery
    [void](New-StubControl -Path $n1.ControlPath -ExitCode 0)
    $manifestN = New-CohortManifestFile -Path (Join-Path $caseN 'cohort.json') `
        -ToolkitRoot $toolkit -Head $head -RequiredRef $requiredRef `
        -JournalRoot (Join-Path $caseN 'journal') -IndexPath (Join-Path $caseN 'index\cohort-index.json') `
        -StubPath $stub -Entries @((New-CohortEntryDeclaration -Request $n1 -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runN = Invoke-Cohort -ManifestPath $manifestN
    Assert-Cohort ($runN.ExitCode -eq 2) "An entry declaring no delivery exited $($runN.ExitCode); expected 2."
    Assert-Cohort (-not (Test-Path -LiteralPath (Join-Path $n1.OutputRoot 'coordinator\audit.json'))) `
        'An entry declaring less than the full pipeline was started anyway.'

    # -----------------------------------------------------------------------
    Write-Host '22/23 a cohort is an operator action, not an invocation shape' -ForegroundColor Cyan
    $noAlias = Invoke-Cohort -ManifestPath $manifestA -OmitAuthorization
    Assert-Cohort ($noAlias.ExitCode -eq 1) "A cohort without --authorized-by exited $($noAlias.ExitCode); expected 1."
    Assert-Cohort ($noAlias.Output -match 'never by a timer') 'The refusal did not say a cohort is started by an operator.'
    $mixed = Invoke-Cohort -ManifestPath $manifestA -Extra @('--request', $a1.Path)
    Assert-Cohort ($mixed.ExitCode -eq 1) "A cohort mixed with a single request exited $($mixed.ExitCode); expected 1."
    $badAlias = Invoke-Cohort -ManifestPath $manifestA -AuthorizedBy 'op'
    Assert-Cohort ($badAlias.ExitCode -eq 2) "A malformed operator alias exited $($badAlias.ExitCode); expected 2."
    $rebuildAlone = & {
        $previous = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        try {
            $text = & dotnet $script:CohortDll '--rebuild-index' '--request' $a1.Path 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
        }
        finally { $PSNativeCommandUseErrorActionPreference = $previous }
    }
    Assert-Cohort ($rebuildAlone.ExitCode -eq 1) "--rebuild-index outside a cohort exited $($rebuildAlone.ExitCode); expected 1."

    # -----------------------------------------------------------------------
    Write-Host '23/23 the key a real preparation writes is the key the cohort reads' -ForegroundColor Cyan
    # The one entry in this suite that is NOT a stub. Everything else here proves
    # accounting across processes and is faster and sharper for being stubbed;
    # this proves the one thing a stub cannot, which is that the bytes the real
    # preparation writes into its own root are bytes this runner can authenticate.
    # A key is 32 random bytes and most such sequences are not text in any
    # encoding, so a reader that decoded it would fail on almost every real root
    # and on almost no fixture. That is exactly the defect this scenario exists
    # to stop coming back.
    #
    # No model is started: the entry is driven to a snapshot state, which is
    # before the first slot is declared, let alone launched.
    Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    . (Join-Path $RepoRoot 'src\Agents\reviewer\SourceTransport.ps1')
    . (Join-Path $RepoRoot 'src\Agents\reviewer\CorpusSeal.ps1')
    . (Join-Path $RepoRoot 'tools\CorpusSealFixture.ps1')
    . (Join-Path $RepoRoot 'tools\ShadowCoordinatorFixture.ps1')

    $caseReal = Join-Path $sandboxRoot 'case-real'
    $realFixture = New-ShadowCoordinatorFixture -Sandbox (Join-Path $caseReal 'fixture') `
        -ToolkitRoot $RepoRoot -ShadowSlotsEnabled -ReconciliationEnabled -DeliveryEnabled
    Assert-Cohort (Test-Path -LiteralPath $realFixture.RequestPath -PathType Leaf) `
        'The real fixture did not write a coordinator request.'
    $realEntry = [pscustomobject]@{
        EntryId = 'entry-real'
        Path = [string]$realFixture.RequestPath
        Sha256 = (Get-Sha256 -Path $realFixture.RequestPath)
        OutputRoot = [string]$realFixture.OutputRoot
        Subject = $realFixture.Request.subject
        Digests = $realFixture.Request.digests
    }
    $dotnetPath = [string](Get-Command dotnet -CommandType Application | Select-Object -First 1).Source
    $manifestReal = New-CohortManifestFile -Path (Join-Path $caseReal 'cohort.json') `
        -ToolkitRoot $realFixture.ToolkitCopy -Head $realFixture.Head -RequiredRef $realFixture.RequiredRef `
        -JournalRoot (Join-Path $caseReal 'journal') -IndexPath (Join-Path $caseReal 'index\cohort-index.json') `
        -StubPath $stub -CommandPath $dotnetPath -ArgumentPrefixOverride @($script:CohortDll) `
        -Target 'snapshotVerified' -EntryTimeoutSeconds 900 `
        -Entries @((New-CohortEntryDeclaration -Request $realEntry -Ordinal 1 -RuleBundlePath $ruleBundle))
    $runReal = Invoke-Cohort -ManifestPath $manifestReal
    Assert-Cohort ($runReal.ExitCode -eq 0) `
        "A cohort over a real preparation exited $($runReal.ExitCode); expected 0. $($runReal.Output)"
    $realKeyPath = Join-Path $realFixture.OutputRoot 'coordinator\state.key'
    Assert-Cohort (Test-Path -LiteralPath $realKeyPath -PathType Leaf) `
        'The real preparation wrote no signing key.'
    $realKeyBytes = [IO.File]::ReadAllBytes($realKeyPath)
    Assert-Cohort ($realKeyBytes.Length -eq 32) `
        "The real preparation wrote a $($realKeyBytes.Length)-byte key; expected 32 raw bytes."
    # Not a claim about this particular key - it is random - but a statement of
    # what the format is: bytes, not characters. Recorded rather than asserted,
    # because a reader that required text would be betting on the key happening
    # to be text, and this run is one draw.
    $decodable = $true
    try { [void]([Text.UTF8Encoding]::new($false, $true)).GetString($realKeyBytes) }
    catch { $decodable = $false }
    Write-Host "  real key decodes as UTF-8: $decodable" -ForegroundColor DarkGray
    $indexReal = Get-JsonFile -Path (Join-Path $caseReal 'index\cohort-index.json')
    Assert-Cohort ($null -ne $indexReal) 'The cohort over a real preparation published no index.'
    $summaryReal = Get-CohortIndexEntry -Index $indexReal -EntryId 'entry-real'
    Assert-Cohort ($null -ne $summaryReal -and $summaryReal.auditSha256 -cmatch '^[0-9a-f]{64}$') `
        'The real entry was summarized without an authenticated audit digest.'
    Assert-Cohort ($indexReal.consumed.modelStarts -eq 0) `
        "A cohort driven to a snapshot state reported $($indexReal.consumed.modelStarts) model starts; expected 0."
    Assert-Cohort ($indexReal.consumed.providerWrites -eq 0) `
        'A cohort over a real preparation reported a provider write.'
    # The same real root read a second time, from the artifacts alone. This is the
    # path the pilot crashed on.
    $rebuildReal = Invoke-Cohort -ManifestPath $manifestReal -RebuildIndex
    Assert-Cohort ($rebuildReal.ExitCode -eq 0) `
        "A rebuild over a real preparation exited $($rebuildReal.ExitCode); expected 0. $($rebuildReal.Output)"
    Assert-Cohort ($rebuildReal.Output -notmatch 'Unhandled exception') `
        'A rebuild over a real key came out as a crash.'
    # And the same root with the real key replaced: the signature is over bytes
    # that are no longer there, so it is refused rather than accepted.
    $realReplacement = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($realReplacement)
    [IO.File]::WriteAllBytes($realKeyPath, $realReplacement)
    $rebuildForged = Invoke-Cohort -ManifestPath $manifestReal -RebuildIndex
    Assert-Cohort ($rebuildForged.ExitCode -eq 11) `
        "A rebuild over a replaced real key exited $($rebuildForged.ExitCode); expected 11."
    [IO.File]::WriteAllBytes($realKeyPath, $realKeyBytes)
}
finally {
    if (-not $KeepSandbox.IsPresent) {
        Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "sandbox kept at $sandboxRoot" -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED $($script:Failures.Count) of $($script:Checks) checks" -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "PASSED $($script:Checks) checks" -ForegroundColor Green
exit 0
