#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Holds the boundary a future C# coordinator has to sit behind: it consumes the
    published stage contracts, and it may not contain prompt or verdict logic.

.DESCRIPTION
    The coordinator is not ported. That is the point of running this now: the
    rule that decides what a port is allowed to be has to exist BEFORE the port,
    or it is written afterwards to describe whatever was already built.

    What this suite asserts today, in force:

      * The two schemas a coordinator would consume - the stage envelope and the
        stage producer contract table - exist, parse, carry no BOM, and describe
        exactly the twelve boundaries the running code declares. A schema that
        drifted from the table would hand a generated consumer a shape no
        producer publishes.

      * Those schemas are SCHEMA. They carry no prompt text, no model name, no
        temperature, no threshold, no endpoint. A coordinator generated from them
        cannot acquire prompt or verdict logic by reading them.

      * Every stage kind in the schema is a registered contract with a matching
        contract version, and every registered stage kind is in the schema.

    What this suite asserts the moment a port lands, and vacuously until then:

      * Any C# source that mentions a reviewer stage kind must also name the
        schema it consumes, so a coordinator reads the contract rather than
        re-deriving a shape by hand.

      * No C# source may contain prompt text, model selection, severity
        arbitration, verdict arbitration, or an HTTP client aimed at a model
        provider. The coordinator sequences stages; it does not decide review
        outcomes.

    No model, no network, no write.

.EXAMPLE
    ./tools/Test-ReviewerCoordinatorContract.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'src\Agents\reviewer\StageProducers.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Assert-Coordinator {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) { [void]$script:failures.Add($Message) }
}

function Read-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "'$Path' starts with a UTF-8 BOM."
    }
    return ([System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -Depth 32)
}

$schemaRoot = Join-Path $repoRoot 'src\Agents\reviewer\schemas'
$envelopeSchemaPath = Join-Path $schemaRoot 'reviewer.stage-envelope.v1.json'
$contractSchemaPath = Join-Path $schemaRoot 'reviewer.stage-producer-contracts.v1.json'

foreach ($path in @($envelopeSchemaPath, $contractSchemaPath)) {
    Assert-Coordinator (Test-Path -LiteralPath $path -PathType Leaf) `
        "A future coordinator has nothing to consume: '$path' is missing."
}
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
    Write-Host "FAIL - $($failures.Count) of $checks coordinator contract checks failed."
    exit 1
}

$envelopeSchema = Read-JsonDocument -Path $envelopeSchemaPath
$contractSchema = Read-JsonDocument -Path $contractSchemaPath

# ---------------------------------------------------------------------------
# The envelope a coordinator would parse is the envelope the writer emits.
# ---------------------------------------------------------------------------

$expectedEnvelopeFields = [string[]]@('envelopeVersion', 'kind', 'contractVersion', 'form', 'depth', 'payload')
$schemaEnvelopeFields = [string[]]@($envelopeSchema.required)
foreach ($field in $expectedEnvelopeFields) {
    Assert-Coordinator ($schemaEnvelopeFields -ccontains $field) `
        "The stage envelope schema does not require '$field'; a generated consumer would accept an envelope the reader refuses."
}
Assert-Coordinator ($schemaEnvelopeFields.Count -eq $expectedEnvelopeFields.Count) `
    "The stage envelope schema requires $($schemaEnvelopeFields.Count) field(s), not $($expectedEnvelopeFields.Count)."
Assert-Coordinator (-not [bool]$envelopeSchema.additionalProperties) `
    "The stage envelope schema tolerates unknown fields; the reader does not, so a generated consumer would disagree with the producer."

# ---------------------------------------------------------------------------
# The table a coordinator would generate from is the table in force.
# ---------------------------------------------------------------------------

$liveRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in (Get-ReviewerStageProducerContract)) { [void]$liveRows.Add($row) }
$schemaRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in $contractSchema.boundaries) { [void]$schemaRows.Add($row) }

Assert-Coordinator ($liveRows.Count -eq 12) `
    "The running stage producer table declares $($liveRows.Count) boundaries, not 12."
Assert-Coordinator ($schemaRows.Count -eq $liveRows.Count) `
    "The stage producer schema describes $($schemaRows.Count) boundaries, the running table declares $($liveRows.Count)."

$schemaByStage = @{}
foreach ($row in $schemaRows) { $schemaByStage[[string]$row.stage] = $row }
foreach ($row in $liveRows) {
    $stage = [string]$row.Stage
    if (-not $schemaByStage.ContainsKey($stage)) {
        Assert-Coordinator $false "Stage '$stage' is in force but absent from the schema a coordinator would consume."
        continue
    }
    $schemaRow = $schemaByStage[$stage]
    Assert-Coordinator ([string]$schemaRow.kind -ceq [string]$row.Kind) `
        "Stage '$stage' publishes kind '$($row.Kind)' but the schema names '$($schemaRow.kind)'."
    $contract = Get-ReviewerStageContract -Kind ([string]$row.Kind)
    Assert-Coordinator ([int]$schemaRow.contractVersion -eq [int]$contract.ContractVersion) `
        "Stage '$stage' is at contract version $($contract.ContractVersion) but the schema declares $($schemaRow.contractVersion)."
    $schemaFields = [string[]]@($schemaRow.requiredFields)
    $liveFields = [string[]]@($row.RequiredFields)
    Assert-Coordinator (($schemaFields -join ',') -ceq ($liveFields -join ',')) `
        "Stage '$stage' requires [$($liveFields -join ', ')] but the schema requires [$($schemaFields -join ', ')]."
    $schemaCollections = [string[]]@($schemaRow.collectionFields)
    $liveCollections = [string[]]@($row.CollectionFields)
    Assert-Coordinator (($schemaCollections -join ',') -ceq ($liveCollections -join ',')) `
        "Stage '$stage' declares collection fields [$($liveCollections -join ', ')] but the schema declares [$($schemaCollections -join ', ')]."
}
foreach ($stage in $schemaByStage.Keys) {
    $known = @($liveRows | Where-Object { [string]$_.Stage -ceq $stage })
    Assert-Coordinator ($known.Count -eq 1) `
        "The schema describes stage '$stage', which is not a boundary in force."
}

# ---------------------------------------------------------------------------
# The schemas are schema. A coordinator generated from them cannot learn a
# prompt, a model, or a threshold, because none is written down here.
# ---------------------------------------------------------------------------

# Deliberately narrow and mechanical. Words like "severity" legitimately appear
# in a boundary's prose summary - the verdict stage is ABOUT severity - so what
# is forbidden is the machinery of deciding, not the vocabulary of describing.
$forbiddenSchemaTokens = [string[]]@(
    'systemPrompt', 'system_prompt', 'promptText', 'temperature', 'maxTokens',
    'max_tokens', 'topP', 'endpoint', 'apiKey', 'api_key', 'gpt-', 'claude-',
    'threshold', 'You are a'
)
foreach ($path in @($envelopeSchemaPath, $contractSchemaPath)) {
    $text = [IO.File]::ReadAllText($path)
    foreach ($token in $forbiddenSchemaTokens) {
        Assert-Coordinator (-not $text.Contains($token)) `
            "'$(Split-Path $path -Leaf)' mentions '$token'; the contract a coordinator consumes must be shape, not judgement."
    }
}

# ---------------------------------------------------------------------------
# What a port is allowed to be. Vacuous until a coordinator exists, in force the
# moment one does - which is the only order in which this rule means anything.
# ---------------------------------------------------------------------------

$csharpFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.cs' -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.FullName -notlike '*\obj\*' -and [string]$_.FullName -notlike '*\bin\*' })

# Recorded, not asserted: this is the honest statement of what has been ported
# so far, and it is what makes the rules below vacuous today.
Write-Host "coordinator-contract: $($csharpFiles.Count) C# source file(s) in tree; stage boundaries in force: $($liveRows.Count)."

$stageKinds = [string[]]@($liveRows | ForEach-Object { [string]$_.Kind })
$forbiddenCoordinatorTokens = [string[]]@(
    'systemPrompt', 'SystemPrompt', 'PromptTemplate', 'ChatCompletion', 'temperature',
    'HttpClient', 'AcceptCandidate', 'CorrectSeverity', 'DecideVerdict', 'RenderPrompt',
    # The machinery of judging a supervised run's OUTPUT. A coordinator that
    # supervises a slot sees findings, candidates, severities and verdicts go
    # past; the rule is that it may carry none of the code that forms an opinion
    # about any of them.
    'RejectCandidate', 'ScoreCandidate', 'RankCandidate', 'AssignSeverity', 'SeverityOf',
    'ComputeVerdict', 'VerdictOf', 'ModelClient', 'InvokeModel', 'CallModel', 'Completions',
    'OpenAI', 'Anthropic',
    # Delivery. Slice two supervises a preview-only run and writes to no provider,
    # so the names a provider write would need are forbidden outright rather than
    # left to review.
    'PostComment', 'CreateComment', 'PublishComment', 'WriteComment', 'CreateThread',
    'UpdatePullRequest', 'http://', 'https://'
)
foreach ($file in $csharpFiles) {
    $text = [IO.File]::ReadAllText($file.FullName)
    $mentionsStage = $false
    foreach ($kind in $stageKinds) {
        if ($text.Contains($kind)) { $mentionsStage = $true }
    }
    if ($mentionsStage) {
        Assert-Coordinator ($text.Contains('reviewer.stage-envelope.v1.json') -or
            $text.Contains('reviewer.stage-producer-contracts.v1.json')) `
            "'$($file.Name)' consumes a reviewer stage kind without naming the schema it consumes; a coordinator reads the published contract rather than re-deriving its shape."
    }
    foreach ($token in $forbiddenCoordinatorTokens) {
        Assert-Coordinator (-not $text.Contains($token)) `
            "'$($file.Name)' mentions '$token'; a coordinator sequences stages and must not carry prompt or verdict logic."
    }
}

# ---------------------------------------------------------------------------
# Where a supervised slot's budget is allowed to come from.
# ---------------------------------------------------------------------------
# A request that could name its own slot deadlines could give itself an
# unbounded run by writing a larger number in a file it also authored. The
# budgets therefore come from the signed qualification plan, and the ONE number
# the request contributes is the supervision grace. Asserted structurally rather
# than left to review, because the difference between the two is a single field.
$requestContract = Join-Path $repoRoot 'tools\ShadowRunCoordinator\CoordinatorRequest.cs'
if (Test-Path -LiteralPath $requestContract -PathType Leaf) {
    $requestText = [IO.File]::ReadAllText($requestContract)
    foreach ($budget in @('slotTimeoutSeconds', 'progressTimeoutSeconds', 'perCallTimeoutSeconds')) {
        Assert-Coordinator (-not $requestText.Contains($budget)) `
            "The typed request contract reads '$budget'; a supervised slot's budget must come from the signed plan, not from the request."
    }
    Assert-Coordinator ($requestText.Contains('supervisionGraceSeconds')) `
        'The typed request contract no longer carries the supervision grace, which is the one budget a caller may set.'
}

# The rule above can only bite on files it can see. If the port ever lands
# somewhere this suite does not look, the suite would stay green while holding
# nothing, so the search root is asserted rather than assumed.
Assert-Coordinator (Test-Path -LiteralPath (Join-Path $repoRoot 'tools\SealParity\Program.cs') -PathType Leaf) `
    "The C# search did not find the one C# file known to be in this tree; the coordinator rules are not being applied to anything."

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
    Write-Host "FAIL - $($failures.Count) of $checks coordinator contract checks failed."
    exit 1
}
Write-Host "PASS - $checks coordinator contract checks."
exit 0
