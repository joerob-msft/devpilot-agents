#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Proves the on-disk half of the stage file contract is in force under the
    opt-in shadow switch - and that every way of neutering it fails here.

.DESCRIPTION
    tools/Test-ReviewerStageContract.ps1 proves the file contract behaves.
    tools/Test-ReviewerStageProducerContract.ps1 proves the twelve in-memory
    boundaries are adopted. Neither of them puts a versioned envelope on disk on
    a live path, which is exactly why the escape ledger recorded the on-disk half
    as complete but not in force.

    This suite is the evidence for the on-disk half. It proves:

      * DEFAULT OFF. With the switch disabled the publish boundary is the
        identity function, writes nothing, and returns the same object instance.
        Production behaviour is unchanged unless the switch is enabled.

      * REFUSAL. The switch will not open while any delivery capability is live,
        will not open without the delivery authority loaded, will not adopt a
        directory it does not own, and will not accept a hand-made capability
        summary in place of the authority's answer.

      * CARDINALITY THROUGH A FILE. Every one of the twelve stage kinds is driven
        at zero, one, many, max, and duplicate through the real builder with the
        switch on, and the census read back off disk is compared against the
        census that went in. Null and wrong-scalar are refused at the boundary
        with no artifact published.

      * FAULT. A BOM, a truncation, a stdout prologue or epilogue, an unknown or
        missing envelope field, a foreign kind, an unsupported version, a
        form/byte disagreement, and a weakened collection are each refused by the
        reader by name.

      * SABOTAGE. Removing the publish call, parking it under a literal-false
        clause, piping it to Out-Null, discarding its result, publishing a
        payload that is not the judged one, dropping -StrictShape, ignoring the
        read verdict, or deleting the round-trip comparison are each caught -
        statically by an adoption checker whose bite is proven by mutation, and
        dynamically by overriding the reader and the writer under the real
        publish path.

    No model, no network, no repository write. Files are created only under a
    per-run temporary directory and removed at the end.

.EXAMPLE
    ./tools/Test-ReviewerStageShadow.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'src\Agents\reviewer\StageProducers.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\SourceTransport.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\CrossVerification.ps1')
. (Join-Path $repoRoot 'src\Agents\reviewer\DeliveryGates.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Assert-Shadow {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) { [void]$script:failures.Add($Message) }
}

function Assert-ShadowThrows {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$ExpectedMessageLike
    )
    $script:checks++
    $thrown = $null
    try { & $Action | Out-Null } catch { $thrown = $_ }
    if ($null -eq $thrown) { [void]$script:failures.Add($Message); return }
    # "It threw" is not the assertion. A typo throws too, and a suite that
    # accepts any throw retires the guarantee it claims to hold while staying
    # green.
    if ([string]$thrown.Exception.Message -notlike $ExpectedMessageLike) {
        [void]$script:failures.Add("$Message (threw '$($thrown.Exception.Message)', expected like '$ExpectedMessageLike')")
    }
}

# The real reader and writer, captured before anything in this suite is allowed
# to shadow them. A sabotage case calls through these to produce a genuine
# result and then corrupts exactly one field of it, so the case proves the
# publish path consumes that field rather than proving the reader can fail.
$script:RealReadArtifact = Get-Command -Name 'Read-ReviewerStageArtifact' -CommandType Function
$script:RealWriteArtifact = Get-Command -Name 'Write-ReviewerStageArtifact' -CommandType Function

$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ("reviewer-stage-shadow-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

function New-ShadowScratchDirectory {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:scratchRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return (Resolve-Path -LiteralPath $path).ProviderPath
}

# previewOnly with every switch off is the only policy a shadow run may hold.
# It is handed to the delivery authority, not asserted about.
$previewPolicy = [pscustomobject]@{
    mode = 'previewOnly'
    approval = [pscustomobject]@{ enabled = $false }
}

function Enable-ShadowFor {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$Depth = 48,
        [string]$Form = 'compact'
    )
    return Enable-ReviewerStageShadowContract -Directory $Directory `
        -EffectivePolicy $script:previewPolicy -CommentSwitchOn $false `
        -SuggestionSwitchOn $false -ApprovalSwitchOn $false `
        -Reason 'stage-shadow-suite' -Depth $Depth -Form $Form
}

function New-ShadowCardinalityValue {
    param([Parameter(Mandatory)][int]$Count, [Parameter(Mandatory)][bool]$Duplicate)
    $items = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        [void]$items.Add($(if ($Duplicate) { 'element-0' } else { "element-$i" }))
    }
    Write-Output -NoEnumerate ([object[]]$items.ToArray())
}

function New-ShadowCardinalityMap {
    param([Parameter(Mandatory)][int]$Count, [Parameter(Mandatory)][bool]$Duplicate)
    $map = [ordered]@{}
    for ($i = 0; $i -lt $Count; $i++) {
        $map["key-$i"] = $(if ($Duplicate) { 'element-0' } else { "element-$i" })
    }
    return $map
}

function Get-ShadowLedgerRecord {
    # Get-ReviewerStageShadowContractLedger emits its collection un-enumerated on
    # purpose, so a caller cannot silently turn one record into a scalar. That
    # also means @() around it wraps rather than unrolls, which is why this
    # re-emits the entries one by one and every call site wraps in @().
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in (Get-ReviewerStageShadowContractLedger)) { [void]$records.Add($entry) }
    return $records.ToArray()
}

function Get-ShadowStageRow {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in (Get-ReviewerStageProducerContract)) { [void]$rows.Add($row) }
    return $rows.ToArray()
}

$stageRows = @(Get-ShadowStageRow)

# ---------------------------------------------------------------------------
# 1. Default off. Nothing about an ordinary run may change.
# ---------------------------------------------------------------------------

Assert-Shadow (-not (Test-ReviewerStageShadowContractEnabled)) `
    "The stage shadow contract reported itself enabled before anything enabled it."

Assert-ShadowThrows { Get-ReviewerStageShadowContractState } `
    "Asking for the shadow state while disabled returned a value instead of refusing." `
    '*not enabled*'

$offDirectory = New-ShadowScratchDirectory -Name 'default-off'
$offPayload = [ordered]@{ changedPaths = [object[]]@('a.ps1', 'b.ps1') }
$offResult = Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
    -Payload $offPayload -Producer 'suite'
Assert-Shadow ([object]::ReferenceEquals($offResult, $offPayload)) `
    "With the switch off the publish boundary did not return the very object it was handed."
Assert-Shadow (@(Get-ChildItem -LiteralPath $offDirectory -Force).Count -eq 0) `
    "With the switch off the publish boundary touched the filesystem."

# The twelve shipping builders must behave identically with the switch off, or
# "default production behaviour is unchanged" is not a claim this suite can make.
foreach ($row in $stageRows) {
    $stage = [string]$row.Stage
    $value = New-ShadowCardinalityValue -Count 2 -Duplicate $false
    $judged = Invoke-ReviewerStageProducerBuilder -Stage $stage -Slot 'collection' -Value $value
    Assert-Shadow ($null -ne $judged) `
        "Stage '$stage' produced nothing with the shadow switch off."
    $slotField = [string]$row.CollectionSlot
    Assert-Shadow (@($judged.Item($slotField)).Count -eq 2) `
        "Stage '$stage' did not carry its two-element census with the shadow switch off."
}
Assert-Shadow (@(Get-ShadowLedgerRecord).Count -eq 0) `
    "The shadow ledger recorded a publication while the switch was off."

# ---------------------------------------------------------------------------
# 2. Refusal. The switch must fail closed on every question it cannot answer.
# ---------------------------------------------------------------------------

$refusalDirectory = New-ShadowScratchDirectory -Name 'refusal'

# A capability is live only when the CLI switch AND the effective policy mode
# both allow it, so each refusal case has to drive both halves. Asserting only
# on the switch would pass in previewOnly, where every capability is false
# whatever the switches say, and would prove nothing.
$liveCapabilityCases = [ordered]@{
    Comments = @{
        Policy = [pscustomobject]@{ mode = 'unattendedComment'; approval = [pscustomobject]@{ enabled = $false } }
        Comment = $true; Suggestion = $false; Approval = $false
    }
    Suggestions = @{
        Policy = [pscustomobject]@{ mode = 'unattendedCommentAndSuggestion'; approval = [pscustomobject]@{ enabled = $false } }
        Comment = $false; Suggestion = $true; Approval = $false
    }
    Approval = @{
        Policy = [pscustomobject]@{ mode = 'approvalVote'; approval = [pscustomobject]@{ enabled = $true } }
        Comment = $false; Suggestion = $false; Approval = $true
    }
}
foreach ($capability in $liveCapabilityCases.Keys) {
    $case = $liveCapabilityCases[$capability]
    Assert-ShadowThrows {
        Enable-ReviewerStageShadowContract -Directory $refusalDirectory `
            -EffectivePolicy $case.Policy -CommentSwitchOn ([bool]$case.Comment) `
            -SuggestionSwitchOn ([bool]$case.Suggestion) -ApprovalSwitchOn ([bool]$case.Approval)
    } "The shadow switch opened while $capability could be published." "*delivery capability $capability is enabled*"
    # A refusal that still left the switch open would cascade into every case
    # below and turn one failure into a suite that cannot be read.
    if (Test-ReviewerStageShadowContractEnabled) {
        Assert-Shadow $false "The shadow switch was left enabled after a $capability refusal."
        Disable-ReviewerStageShadowContract
    }
}

Assert-ShadowThrows {
    Assert-ReviewerStageShadowNoWriteCapability -WriteCapability ([pscustomobject]@{
            Comments = $false; Suggestions = $false })
} "A capability summary missing Approval was accepted." '*did not report capability*'

Assert-ShadowThrows {
    Assert-ReviewerStageShadowNoWriteCapability -WriteCapability ([pscustomobject]@{
            Comments = $false; Suggestions = $false; Approval = 'no' })
} "A non-boolean capability was accepted as false." '*is not a boolean*'

# An unknown capability that is true is a refusal, not a tolerated extra: growing
# a fourth way to write must not become a way to write during a shadow run.
Assert-ShadowThrows {
    Assert-ReviewerStageShadowNoWriteCapability -WriteCapability ([pscustomobject]@{
            Comments = $false; Suggestions = $false; Approval = $false; Merges = $true })
} "An unknown live capability was tolerated." '*Merges is enabled*'

Assert-ShadowThrows { Assert-ReviewerStageShadowNoWriteCapability -WriteCapability $null } `
    "A null capability summary was accepted." '*returned nothing*'

# Without the delivery authority loaded the question cannot be asked, and "the
# check was unavailable" must not resolve the same way as "the check passed".
# Only a fresh process can prove that, because this one has the authority.
$authorityProbe = Join-Path $scratchRoot 'authority-probe.ps1'
$authorityProbeText = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. '$(Join-Path $repoRoot 'src\Agents\reviewer\StageContract.ps1')'
. '$(Join-Path $repoRoot 'src\Agents\reviewer\StageShadow.ps1')'
if (Get-Command -Name 'Get-ReviewerGateWritesCurrentlyRequested' -CommandType Function -ErrorAction SilentlyContinue) {
    Write-Output 'AUTHORITY-PRESENT'
    exit 0
}
try {
    `$null = Enable-ReviewerStageShadowContract -Directory '$(Join-Path $scratchRoot 'authority')' ``
        -EffectivePolicy ([pscustomobject]@{ mode = 'previewOnly' }) -CommentSwitchOn `$false ``
        -SuggestionSwitchOn `$false -ApprovalSwitchOn `$false
    Write-Output 'OPENED'
}
catch { Write-Output "REFUSED: `$(`$_.Exception.Message)" }
"@
[IO.File]::WriteAllText($authorityProbe, $authorityProbeText, [System.Text.UTF8Encoding]::new($false))
$authorityOutcome = [string](& pwsh -NoProfile -File $authorityProbe 2>&1 | Select-Object -Last 1)
Assert-Shadow ($authorityOutcome -like 'REFUSED:*delivery write authority*') `
    "Enabling the shadow switch without the delivery write authority loaded did not fail closed (got '$authorityOutcome')."

# A directory holding something this switch did not write is somebody else's.
$foreignDirectory = New-ShadowScratchDirectory -Name 'foreign'
[IO.File]::WriteAllText((Join-Path $foreignDirectory 'notes.txt'), 'not ours')
Assert-ShadowThrows { Enable-ShadowFor -Directory $foreignDirectory } `
    "The shadow switch adopted a directory it did not own." '*refusing to adopt it as private state*'

$doubleDirectory = New-ShadowScratchDirectory -Name 'double'
$null = Enable-ShadowFor -Directory $doubleDirectory
Assert-Shadow (Test-ReviewerStageShadowContractEnabled) `
    "The shadow switch did not report itself enabled after enabling."
Assert-ShadowThrows { Enable-ShadowFor -Directory $doubleDirectory } `
    "The shadow switch enabled twice without being disabled." '*already enabled*'
Disable-ReviewerStageShadowContract
Assert-Shadow (-not (Test-ReviewerStageShadowContractEnabled)) `
    "The shadow switch stayed enabled after being disabled."
# Re-enabling a directory this switch already marked is reuse, not adoption.
$null = Enable-ShadowFor -Directory $doubleDirectory
Assert-Shadow (Test-ReviewerStageShadowContractEnabled) `
    "The shadow switch refused to reuse a directory it had already marked as its own."
Disable-ReviewerStageShadowContract

$markerPath = Join-Path $doubleDirectory '.reviewer-stage-shadow.json'
Assert-Shadow (Test-Path -LiteralPath $markerPath -PathType Leaf) `
    "The shadow switch did not leave a marker naming the directory as its own."
$markerBytes = [IO.File]::ReadAllBytes($markerPath)
Assert-Shadow (-not ($markerBytes.Length -ge 3 -and $markerBytes[0] -eq 0xEF -and
        $markerBytes[1] -eq 0xBB -and $markerBytes[2] -eq 0xBF)) `
    "The shadow session marker starts with a UTF-8 BOM."
$marker = [System.Text.UTF8Encoding]::new($false).GetString($markerBytes) | ConvertFrom-Json -Depth 8
Assert-Shadow ([string]$marker.kind -ceq 'reviewer.stage.shadow.session') `
    "The shadow session marker does not declare its kind."
Assert-Shadow (-not [bool]$marker.writeCapability.comments -and
    -not [bool]$marker.writeCapability.suggestions -and
    -not [bool]$marker.writeCapability.approval) `
    "The shadow session marker recorded a live delivery capability."

# ---------------------------------------------------------------------------
# 3. Every stage kind, every cardinality, through a real file.
# ---------------------------------------------------------------------------

$cardinalityVariants = [ordered]@{
    zero = @{ Count = 0; Duplicate = $false }
    one = @{ Count = 1; Duplicate = $false }
    many = @{ Count = 3; Duplicate = $false }
    max = @{ Count = 32; Duplicate = $false }
    duplicate = @{ Count = 3; Duplicate = $true }
}

$cardinalityDirectory = New-ShadowScratchDirectory -Name 'cardinality'
Clear-ReviewerStageShadowContractLedger
$null = Enable-ShadowFor -Directory $cardinalityDirectory
$publishedByStage = @{}
try {
    foreach ($row in $stageRows) {
        $stage = [string]$row.Stage
        $kind = [string]$row.Kind
        $slotField = [string]$row.CollectionSlot
        $slots = if ([string]::IsNullOrEmpty([string]$row.MapSlot)) {
            [string[]]@('collection')
        }
        else {
            [string[]]@('collection', 'map')
        }
        $publishedByStage[$stage] = 0
        foreach ($variantName in $cardinalityVariants.Keys) {
            $variant = $cardinalityVariants[$variantName]
            foreach ($slot in $slots) {
                $before = @(Get-ShadowLedgerRecord).Count
                $value = if ($slot -ceq 'map') {
                    New-ShadowCardinalityMap -Count ([int]$variant.Count) -Duplicate ([bool]$variant.Duplicate)
                }
                else {
                    New-ShadowCardinalityValue -Count ([int]$variant.Count) -Duplicate ([bool]$variant.Duplicate)
                }
                $judged = Invoke-ReviewerStageProducerBuilder -Stage $stage -Slot $slot -Value $value
                $records = @(Get-ShadowLedgerRecord)
                Assert-Shadow ($records.Count -eq $before + 1) `
                    "Stage '$stage' published no artifact for the $variantName cardinality in its $slot slot."
                if ($records.Count -ne $before + 1) { continue }
                $publishedByStage[$stage] = [int]$publishedByStage[$stage] + 1
                $record = $records[$records.Count - 1]
                Assert-Shadow ([string]$record.Kind -ceq $kind -and [int]$record.ContractVersion -eq 1) `
                    "Stage '$stage' published an artifact that does not declare kind '$kind' at contract version 1."
                Assert-Shadow ([bool]$record.ReadOnly) `
                    "Stage '$stage' left its $variantName $slot artifact writable."
                # The census the strict reader saw on disk, not the census the
                # harness hoped for: this is the whole point of the file half.
                $observed = -1
                if ($null -ne $record.ObservedCounts -and $record.ObservedCounts.Contains($slotField)) {
                    $observed = [int]$record.ObservedCounts[$slotField]
                }
                $expected = if ($slot -ceq 'map') { 0 } else { [int]$variant.Count }
                Assert-Shadow ($observed -eq $expected) `
                    "Stage '$stage' read back a census of $observed for '$slotField' at the $variantName cardinality in its $slot slot, not $expected."
                Assert-Shadow ($null -ne $judged) `
                    "Stage '$stage' returned nothing from its $variantName $slot publication."
            }
        }

        # Null and a bare scalar are the two shapes a producer must never be able
        # to publish. The evidence is refusal with nothing on disk, because a
        # refusal that still wrote a file is not a refusal.
        foreach ($slot in $slots) {
            $refusedField = if ($slot -ceq 'map') { [string]$row.MapSlot } else { $slotField }
            foreach ($bad in [object[]]([object]$null, 'element-0')) {
                $beforeRefusal = @(Get-ShadowLedgerRecord).Count
                $refusal = ''
                try { $null = Invoke-ReviewerStageProducerBuilder -Stage $stage -Slot $slot -Value $bad }
                catch { $refusal = [string]$_.Exception.Message }
                $shape = if ($null -eq $bad) { 'null' } else { 'wrong-scalar' }
                Assert-Shadow ($refusal.Length -gt 0) `
                    "Stage '$stage' accepted a $shape payload in its $slot slot with the shadow switch on."
                Assert-Shadow ($refusal.Contains($refusedField)) `
                    "Stage '$stage' refused a $shape $slot payload without naming '$refusedField': $refusal"
                Assert-Shadow (@(Get-ShadowLedgerRecord).Count -eq $beforeRefusal) `
                    "Stage '$stage' published an artifact for a refused $shape $slot payload."
            }
        }
    }
}
finally {
    Disable-ReviewerStageShadowContract
}

foreach ($row in $stageRows) {
    $stage = [string]$row.Stage
    $expectedPublications = if ([string]::IsNullOrEmpty([string]$row.MapSlot)) { 5 } else { 10 }
    Assert-Shadow ([int]$publishedByStage[$stage] -eq $expectedPublications) `
        "Stage '$stage' published $($publishedByStage[$stage]) artifact(s) across the cardinality corpus, not $expectedPublications."
}

# Atomicity: the writer stages to a sibling temporary name and moves it into
# place. A leftover temporary file means a reader could have observed a
# partially written contract.
$leftovers = @(Get-ChildItem -LiteralPath $cardinalityDirectory -Force -Filter '*.tmp')
Assert-Shadow ($leftovers.Count -eq 0) `
    "The shadow publisher left $($leftovers.Count) temporary file(s) behind."

$publishedFiles = @(Get-ChildItem -LiteralPath $cardinalityDirectory -File -Filter '*.stage.json')
Assert-Shadow ($publishedFiles.Count -eq @(Get-ShadowLedgerRecord).Count) `
    "The shadow directory holds $($publishedFiles.Count) artifact(s) but the ledger recorded $(@(Get-ShadowLedgerRecord).Count)."
$withBom = @($publishedFiles | Where-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    })
Assert-Shadow ($withBom.Count -eq 0) `
    "$($withBom.Count) published artifact(s) start with a UTF-8 BOM."
$writable = @($publishedFiles | Where-Object { -not $_.IsReadOnly })
Assert-Shadow ($writable.Count -eq 0) `
    "$($writable.Count) published artifact(s) are still writable."

# Immutable means immutable: a later stage cannot rewrite evidence an earlier
# stage published.
$sampleArtifact = $publishedFiles[0].FullName
Assert-ShadowThrows { [IO.File]::WriteAllText($sampleArtifact, 'overwritten') } `
    "A published stage artifact could be overwritten in place." '*'

# ...including through the publisher itself. The sequence is process state and
# the atomic writer's move would replace a read-only destination without a
# murmur, so a second session over the same directory has to continue past what
# is already there, and a name collision has to be refused outright rather than
# resolved in favour of the newcomer.
$reuseDirectory = New-ShadowScratchDirectory -Name 'reuse'
Clear-ReviewerStageShadowContractLedger
$null = Enable-ReviewerStageShadowContract -Directory $reuseDirectory -EffectivePolicy $previewPolicy `
    -CommentSwitchOn $false -SuggestionSwitchOn $false -ApprovalSwitchOn $false
try {
    $null = Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
        -Payload ([ordered]@{ changedPaths = [object[]]@('first.ps1') }) -Producer 'reuse'
}
finally {
    Disable-ReviewerStageShadowContract
}
$firstPass = @(Get-ChildItem -LiteralPath $reuseDirectory -File -Filter '*.stage.json')
Assert-Shadow ($firstPass.Count -eq 1) `
    "The reuse fixture published $($firstPass.Count) artifact(s) on its first session, not 1."
$firstDigest = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($firstPass[0].FullName)))

# A fresh process is simulated by resetting the sequence, which is exactly what
# Clear-ReviewerStageShadowContractLedger does.
Clear-ReviewerStageShadowContractLedger
$null = Enable-ReviewerStageShadowContract -Directory $reuseDirectory -EffectivePolicy $previewPolicy `
    -CommentSwitchOn $false -SuggestionSwitchOn $false -ApprovalSwitchOn $false
try {
    $null = Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
        -Payload ([ordered]@{ changedPaths = [object[]]@('second.ps1') }) -Producer 'reuse'
}
finally {
    Disable-ReviewerStageShadowContract
}
$secondPass = @(Get-ChildItem -LiteralPath $reuseDirectory -File -Filter '*.stage.json')
Assert-Shadow ($secondPass.Count -eq 2) `
    "A second shadow session over a marked directory left $($secondPass.Count) artifact(s), not 2; earlier evidence was overwritten."
$survivingDigest = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($firstPass[0].FullName)))
Assert-Shadow ($survivingDigest -ceq $firstDigest) `
    'A second shadow session rewrote the first session''s published artifact.'

# And if the sequence is forced onto an existing name anyway, the publisher
# refuses rather than replacing evidence.
Clear-ReviewerStageShadowContractLedger
$null = Enable-ReviewerStageShadowContract -Directory $reuseDirectory -EffectivePolicy $previewPolicy `
    -CommentSwitchOn $false -SuggestionSwitchOn $false -ApprovalSwitchOn $false
try {
    Set-Variable -Name 'ReviewerStageShadowSequence' -Scope Script -Value 0
    Assert-ShadowThrows {
        Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
            -Payload ([ordered]@{ changedPaths = [object[]]@('collision.ps1') }) -Producer 'reuse'
    } 'The publisher overwrote a published artifact on a name collision.' '*would overwrite published evidence*'
}
finally {
    Disable-ReviewerStageShadowContract
}
Assert-Shadow (@(Get-ChildItem -LiteralPath $reuseDirectory -File -Filter '*.stage.json').Count -eq 2) `
    'A refused collision still changed the published artifact set.'
# The reservation must never be the artifact path. If it were, a losing publisher
# - or a reader arriving mid-write - would see a zero-byte artifact where the
# contract promises a whole one. Prove the sidecar carries the exclusion instead:
# every published artifact still parses, and none of them is empty.
$collisionArtifacts = @(Get-ChildItem -LiteralPath $reuseDirectory -File -Filter '*.stage.json')
foreach ($collisionArtifact in $collisionArtifacts) {
    Assert-Shadow ($collisionArtifact.Length -gt 0) `
        "The collision reservation left a zero-byte artifact at '$($collisionArtifact.Name)'."
}
$collisionFirst = @($collisionArtifacts | Where-Object { $_.Name -like '*-source.stage.json' })[0]
$collisionRead = Read-ReviewerStageArtifact -Path $collisionFirst.FullName -Kind 'reviewer.stage.source.v1'
Assert-Shadow ($collisionRead.payload.changedPaths[0] -eq 'first.ps1') `
    'A refused collision replaced the payload of the artifact it collided with.'
Assert-Shadow (Test-Path -LiteralPath ($collisionFirst.FullName + '.reservation')) `
    'The publisher did not reserve the artifact name through a sidecar.'
Clear-ReviewerStageShadowContractLedger

# A publish that reserves a name and then refuses the payload - the ordinary
# outcome of the strict shape check this switch exists to surface - leaves a
# sidecar and no artifact. A later session must seed past that burned name. If it
# seeded from artifacts alone it would land on the burned number and be refused
# forever, over "published evidence" that was never written, and the only recovery
# would be deleting a file the publisher calls a tombstone.
$burnedDirectory = New-ShadowScratchDirectory -Name 'burned'
Clear-ReviewerStageShadowContractLedger
$null = Enable-ReviewerStageShadowContract -Directory $burnedDirectory -EffectivePolicy $previewPolicy `
    -CommentSwitchOn $false -SuggestionSwitchOn $false -ApprovalSwitchOn $false
try {
    $null = Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
        -Payload ([ordered]@{ changedPaths = [object[]]@('kept.ps1') }) -Producer 'burned'
    Assert-ShadowThrows {
        Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
            -Payload ([ordered]@{ changedPaths = 'not-an-array' }) -Producer 'burned'
    } 'A collapsed collection field reached disk instead of being refused.' '*collapsed collection field*'
}
finally {
    Disable-ReviewerStageShadowContract
}
$burnedArtifacts = @(Get-ChildItem -LiteralPath $burnedDirectory -File -Filter '*.stage.json')
Assert-Shadow ($burnedArtifacts.Count -eq 1) `
    "A refused payload left $($burnedArtifacts.Count) artifact(s) behind, not 1."
Assert-Shadow (Test-Path -LiteralPath (Join-Path $burnedDirectory '00002-source.stage.json.reservation')) `
    'A refused payload did not leave the reservation that burns its name.'

Clear-ReviewerStageShadowContractLedger
$null = Enable-ReviewerStageShadowContract -Directory $burnedDirectory -EffectivePolicy $previewPolicy `
    -CommentSwitchOn $false -SuggestionSwitchOn $false -ApprovalSwitchOn $false
try {
    $null = Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
        -Payload ([ordered]@{ changedPaths = [object[]]@('after-burn.ps1') }) -Producer 'burned'
    $burnedLedgerResult = Get-ReviewerStageShadowContractLedger
    $burnedLedger = [object[]]@($burnedLedgerResult)
    Assert-Shadow ($burnedLedger.Count -eq 1) `
        "The later session recorded $($burnedLedger.Count) ledger entr(y/ies), not 1."
    $burnedName = Split-Path -Leaf ([string]$burnedLedger[0].Path)
    Assert-Shadow ($burnedName -eq '00003-source.stage.json') `
        "A later session seeded onto '$burnedName' instead of past the burned name."
}
finally {
    Disable-ReviewerStageShadowContract
}
Assert-Shadow (@(Get-ChildItem -LiteralPath $burnedDirectory -File -Filter '*.stage.json').Count -eq 2) `
    'A later session over a directory with a burned name did not publish.'
$burnedKept = Read-ReviewerStageArtifact -Path (Join-Path $burnedDirectory '00001-source.stage.json') `
    -Kind 'reviewer.stage.source.v1'
Assert-Shadow ($burnedKept.payload.changedPaths[0] -eq 'kept.ps1') `
    'Publishing past a burned name disturbed the artifact that preceded it.'
Clear-ReviewerStageShadowContractLedger

# The inventory is a read-only census and must agree with what was published.
$inventory = [object[]]@()
foreach ($entry in (Get-ReviewerStageArtifactInventory -Directory $cardinalityDirectory -Filter '*.stage.json')) {
    $inventory += , $entry
}
Assert-Shadow ($inventory.Count -eq $publishedFiles.Count) `
    "The stage artifact inventory saw $($inventory.Count) file(s), not $($publishedFiles.Count)."
$notEnvelope = @($inventory | Where-Object { [string]$_.Status -cne 'envelope' })
Assert-Shadow ($notEnvelope.Count -eq 0) `
    "$($notEnvelope.Count) published artifact(s) do not read as an envelope."
$unversioned = @($inventory | Where-Object { [int]$_.ContractVersion -ne 1 -or [string]$_.Kind -eq '' })
Assert-Shadow ($unversioned.Count -eq 0) `
    "$($unversioned.Count) published artifact(s) do not carry a kind and a contract version."

# ---------------------------------------------------------------------------
# 4. Faults on the file itself. Each one is refused by name.
# ---------------------------------------------------------------------------

$faultDirectory = New-ShadowScratchDirectory -Name 'fault'
$faultKind = 'reviewer.stage.source.v1'
$faultSeed = Join-Path $faultDirectory 'seed.stage.json'
$null = Write-ReviewerStageArtifact -Path $faultSeed -Kind $faultKind -Depth 8 -Form 'compact' `
    -Payload ([ordered]@{ changedPaths = [object[]]@('a.ps1', 'b.ps1') })
$seedBytes = [IO.File]::ReadAllBytes($faultSeed)
$seedText = [System.Text.UTF8Encoding]::new($false).GetString($seedBytes)

function Test-ShadowFault {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyCollection()][byte[]]$Bytes,
        [string]$Text,
        [Parameter(Mandatory)][string]$ExpectedMessageLike,
        [string]$Kind = 'reviewer.stage.source.v1'
    )
    # Text and Bytes are the same fault expressed two ways. Taking the text here,
    # rather than at every call site, keeps a command result from crossing a typed
    # array parameter, which is itself one of the shapes this repository refuses.
    if ($PSBoundParameters.ContainsKey('Text')) {
        if ($PSBoundParameters.ContainsKey('Bytes')) {
            throw "Test-ShadowFault '$Name' was given both -Text and -Bytes."
        }
        $Bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    }
    elseif (-not $PSBoundParameters.ContainsKey('Bytes')) {
        throw "Test-ShadowFault '$Name' was given neither -Text nor -Bytes."
    }
    $path = Join-Path $script:faultDirectory "$Name.stage.json"
    [IO.File]::WriteAllBytes($path, $Bytes)
    Assert-ShadowThrows { Read-ReviewerStageArtifact -Path $path -Kind $Kind } `
        "A $Name artifact was read back instead of refused." $ExpectedMessageLike
}


Test-ShadowFault -Name 'bom' -ExpectedMessageLike '*UTF-8 BOM*' `
    -Bytes ([byte[]]@(0xEF, 0xBB, 0xBF) + $seedBytes)
Test-ShadowFault -Name 'empty' -ExpectedMessageLike '*is empty*' -Bytes ([byte[]]@())
Test-ShadowFault -Name 'whitespace' -ExpectedMessageLike '*only whitespace*' `
    -Text "   `n  "
Test-ShadowFault -Name 'truncated' -ExpectedMessageLike '*does not end with a JSON object*' `
    -Text $seedText.Substring(0, $seedText.Length - 12)
Test-ShadowFault -Name 'stdout-prologue' -ExpectedMessageLike '*does not begin with a JSON object*' `
    -Text ("VERBOSE: preparing`n" + $seedText)
Test-ShadowFault -Name 'stdout-epilogue' -ExpectedMessageLike '*does not end with a JSON object*' `
    -Text ($seedText.TrimEnd() + "`nWARNING: done`n")
Test-ShadowFault -Name 'unknown-envelope-field' -ExpectedMessageLike '*unknown field*' `
    -Text ($seedText.TrimEnd().Insert(1, '"trailer":1,'))
Test-ShadowFault -Name 'missing-envelope-field' -ExpectedMessageLike '*is missing*' `
    -Text $seedText.Replace('"depth":8,', '')
Test-ShadowFault -Name 'foreign-kind' -ExpectedMessageLike '*kind mismatch*' `
    -Text $seedText.Replace('reviewer.stage.source.v1', 'reviewer.stage.corpus.v1')
Test-ShadowFault -Name 'unsupported-version' -ExpectedMessageLike '*supported versions are*' `
    -Text $seedText.Replace('"contractVersion":1', '"contractVersion":99')
Test-ShadowFault -Name 'unsupported-envelope-version' -ExpectedMessageLike '*envelope version*' `
    -Text $seedText.Replace('"envelopeVersion":1', '"envelopeVersion":7')
Test-ShadowFault -Name 'form-disagreement' -ExpectedMessageLike '*declares form*' `
    -Text $seedText.Replace('"form":"compact"', '"form":"indented"')
Test-ShadowFault -Name 'out-of-range-depth' -ExpectedMessageLike '*out-of-range depth*' `
    -Text $seedText.Replace('"depth":8', '"depth":128')
Test-ShadowFault -Name 'collapsed-collection' -ExpectedMessageLike '*lost collection shape*' `
    -Text $seedText.Replace('["a.ps1","b.ps1"]', '"a.ps1"')
Test-ShadowFault -Name 'null-collection' -ExpectedMessageLike '*changedPaths*' `
    -Text $seedText.Replace('["a.ps1","b.ps1"]', 'null')
Test-ShadowFault -Name 'missing-payload-field' -ExpectedMessageLike '*changedPaths*' `
    -Text $seedText.Replace('"changedPaths":["a.ps1","b.ps1"]', '"other":1')
Test-ShadowFault -Name 'not-json' -ExpectedMessageLike '*not parsable JSON*' `
    -Text "{not json}`n"

# A payload deeper than the depth it would be published at is silently truncated
# by ConvertTo-Json, and both sides of a same-depth round-trip comparison
# truncate identically. Only a strictly deeper probe can see it.
$deep = [ordered]@{ changedPaths = [object[]]@('a.ps1') }
$node = $deep
for ($i = 0; $i -lt 12; $i++) {
    $child = [ordered]@{ level = $i }
    $node['nested'] = $child
    $node = $child
}
Assert-ShadowThrows {
    Assert-ReviewerStageShadowDepthSufficient -Payload $deep -Depth 4 -Kind $faultKind
} "A payload deeper than its publication depth was accepted." '*silently truncated*'
Assert-Shadow ($null -eq (Assert-ReviewerStageShadowDepthSufficient -Payload $deep -Depth 48 -Kind $faultKind)) `
    "A payload well within its publication depth was refused."

# The probe is a strictly deeper serialization, and the comparable helper is
# bounded to the stage contract's declared 2..64 range - not to ConvertTo-Json's
# own limit, which is 100. So at 64 there is nothing deeper the helper will
# produce. Returning quietly there would make the deepest permitted depth the one
# place truncation is invisible.
Assert-ShadowThrows {
    Assert-ReviewerStageShadowDepthSufficient -Payload $deep -Depth 64 -Kind $faultKind
} "The depth probe accepted a depth at which no deeper probe exists." '*no deeper probe inside the stage contract*'
Assert-Shadow ($null -eq (Assert-ReviewerStageShadowDepthSufficient -Payload $deep -Depth 56 -Kind $faultKind)) `
    "The highest publishable depth was refused by the probe."
# ...and the enable path cannot ask for a depth the probe would refuse.
Assert-ShadowThrows {
    Enable-ReviewerStageShadowContract -Directory (New-ShadowScratchDirectory -Name 'ceiling') `
        -EffectivePolicy $previewPolicy -CommentSwitchOn $false -SuggestionSwitchOn $false `
        -ApprovalSwitchOn $false -Depth 64
} "The switch accepted a publication depth its own truncation probe cannot cover." '*'

# ---------------------------------------------------------------------------
# 5. Dynamic sabotage: the publish path must genuinely consume the read verdict
#    and genuinely write the file.
# ---------------------------------------------------------------------------

function Invoke-ShadowPublishUnderSabotage {
    <#
        Publishes one real payload with exactly one field of the read verdict
        corrupted. PowerShell resolves functions along the dynamic scope chain,
        so a function defined here is the one the publish path finds - and the
        real reader is still reachable through the command object captured
        before this suite shadowed anything.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('null', 'kind', 'version', 'adapted', 'digest', 'form', 'depth', 'payload')]
        [string]$Corruption,
        [Parameter(Mandatory)]$Payload
    )

    function Read-ReviewerStageArtifact {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Kind,
            [int]$MaxBytes = 0
        )
        if ($Corruption -ceq 'null') { return $null }
        $real = & $script:RealReadArtifact -Path $Path -Kind $Kind
        $mutated = [ordered]@{}
        foreach ($property in $real.PSObject.Properties) { $mutated[$property.Name] = $property.Value }
        switch ($Corruption) {
            # SourceKind and SourceVersion, not Kind and ContractVersion: the
            # latter pair is the registry echoing the caller's own request and
            # can never disagree with itself, so comparing it would prove
            # nothing. These two are what the file declared.
            'kind' { $mutated['SourceKind'] = 'reviewer.stage.corpus.v1' }
            'version' { $mutated['SourceVersion'] = 99 }
            'adapted' { $mutated['Adapted'] = $true }
            'digest' { $mutated['Sha256'] = ('0' * 64) }
            'form' { $mutated['Form'] = 'indented' }
            'depth' { $mutated['Depth'] = 3 }
            'payload' { $mutated['Payload'] = [pscustomobject]@{ changedPaths = [object[]]@('substituted.ps1') } }
        }
        return [pscustomobject]$mutated
    }

    return Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
        -Payload $Payload -Producer 'sabotage'
}

function Invoke-ShadowPublishWithoutWriting {
    <#
        The writer reports success without putting bytes anywhere. If the publish
        path did not actually read its own artifact back, this would sail
        through, which is exactly the failure mode "we wrote a file" claims
        rule out.
    #>
    param([Parameter(Mandatory)]$Payload)

    function Write-ReviewerStageArtifact {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Kind,
            [Parameter(Mandatory)]$Payload,
            [Parameter(Mandatory)][int]$Depth,
            [Parameter(Mandatory)][string]$Form,
            [int]$MaxBytes = 0,
            [switch]$StrictShape
        )
        return [pscustomobject][ordered]@{
            Path = $Path; Kind = $Kind; ContractVersion = 1; Form = $Form; Depth = $Depth
            ByteLength = 0; Sha256 = ('0' * 64)
        }
    }

    return Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
        -Payload $Payload -Producer 'sabotage'
}

function Invoke-ShadowPublishWithoutStrictShape {
    <#
        The writer accepts a collapsed collection because -StrictShape was
        dropped. A publish path that relies on the writer's strict verdict must
        still refuse, and this proves the switch is asking for it.
    #>
    param([Parameter(Mandatory)]$Payload)

    function Write-ReviewerStageArtifact {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$Kind,
            [Parameter(Mandatory)]$Payload,
            [Parameter(Mandatory)][int]$Depth,
            [Parameter(Mandatory)][string]$Form,
            [int]$MaxBytes = 0,
            [switch]$StrictShape
        )
        if ($StrictShape) { throw "STRICT-SHAPE-REQUESTED" }
        return & $script:RealWriteArtifact -Path $Path -Kind $Kind -Payload $Payload `
            -Depth $Depth -Form $Form
    }

    return Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
        -Payload $Payload -Producer 'sabotage'
}

$sabotageDirectory = New-ShadowScratchDirectory -Name 'sabotage'
$null = Enable-ShadowFor -Directory $sabotageDirectory
try {
    $sabotagePayload = [ordered]@{ changedPaths = [object[]]@('a.ps1', 'b.ps1') }

    # The unsabotaged control. Without it, every refusal below could be a refusal
    # of something unrelated to the corruption under test.
    $control = Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
        -Payload $sabotagePayload -Producer 'sabotage'
    Assert-Shadow ([object]::ReferenceEquals($control, $sabotagePayload)) `
        "The publish path returned a reconstruction instead of the in-memory payload it was handed."

    # Exactly one object on the success stream. A boundary that also emits a
    # progress line puts that line into whatever its caller assigns, and a
    # producer whose stdout is redirected into a contract file writes a prologue
    # that no reader can recover from.
    $emitted = @(Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
            -Payload $sabotagePayload -Producer 'sabotage' 6>&1 5>&1 4>&1 3>&1)
    Assert-Shadow ($emitted.Count -eq 1) `
        "The publish boundary emitted $($emitted.Count) object(s) across its output streams, not 1."

    $sabotageCases = [ordered]@{
        null = '*read nothing back*'
        kind = '*read back kind*'
        version = '*needed a version adapter*'
        adapted = '*needed a version adapter*'
        digest = '*read back different bytes*'
        form = '*different serialization decision*'
        depth = '*different serialization decision*'
        payload = '*did not survive its own file round trip*'
    }
    foreach ($corruption in $sabotageCases.Keys) {
        Assert-ShadowThrows {
            Invoke-ShadowPublishUnderSabotage -Corruption $corruption -Payload $sabotagePayload
        } "The publish path ignored a corrupted '$corruption' in the read verdict." $sabotageCases[$corruption]
    }

    # The collision reservation is a sidecar, not the artifact path, so a publish
    # that skips the write leaves no artifact at all and the reader refuses it as
    # missing - which also proves the reservation never masquerades as evidence.
    Assert-ShadowThrows { Invoke-ShadowPublishWithoutWriting -Payload $sabotagePayload } `
        "The publish path reported success without any bytes on disk." '*does not exist*'

    Assert-ShadowThrows { Invoke-ShadowPublishWithoutStrictShape -Payload $sabotagePayload } `
        "The publish path did not ask the writer for the strict-shape verdict." '*STRICT-SHAPE-REQUESTED*'

    # A collapsed collection must be refused before it becomes a file, so the
    # strict verdict is load-bearing rather than decorative.
    Assert-ShadowThrows {
        Publish-ReviewerStageShadowArtifact -Stage 'source' -Kind 'reviewer.stage.source.v1' `
            -Payload ([ordered]@{ changedPaths = 'a.ps1' }) -Producer 'sabotage'
    } "The publish path wrote a collapsed collection." '*collapsed collection field*'
}
finally {
    Disable-ReviewerStageShadowContract
}

# ---------------------------------------------------------------------------
# 6. Static sabotage: the twelve builders must publish, and the checker that
#    says so must bite when they stop.
# ---------------------------------------------------------------------------

function Get-ShadowPublicationViolation {
    <#
        Whether one builder's body really hands its judged payload to the publish
        boundary and returns the result. Text matching would report a call that
        was parked under a false clause, piped to a sink, or discarded as
        adopted, so this walks the parsed tree instead.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Builder,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Kind
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        [void]$violations.Add("the producer file does not parse")
        return , $violations.ToArray()
    }
    $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $Builder
        }, $true)
    if ($null -eq $function) {
        [void]$violations.Add("builder '$Builder' is not defined")
        return , $violations.ToArray()
    }

    $assertCalls = @($function.Find({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                [string]$node.GetCommandName() -ceq 'Assert-ReviewerStageContract'
            }, $true))
    if ($assertCalls.Count -ne 1) {
        [void]$violations.Add("builder '$Builder' calls Assert-ReviewerStageContract $($assertCalls.Count) time(s)")
    }

    $publishCalls = @($function.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                [string]$node.GetCommandName() -ceq 'Publish-ReviewerStageShadowArtifact'
            }, $true))
    if ($publishCalls.Count -ne 1) {
        [void]$violations.Add("builder '$Builder' calls Publish-ReviewerStageShadowArtifact $($publishCalls.Count) time(s)")
        return , $violations.ToArray()
    }
    $publish = $publishCalls[0]

    # Reachability. A call the interpreter can never run is not a boundary, and
    # the builder name stays in the tree either way.
    $node = $publish
    while ($null -ne $node) {
        if ($node -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $node.Clauses) {
                $condition = [string]$clause.Item1.Extent.Text
                if ($condition -cmatch '^\s*\$false\s*$' -or $condition -cmatch '^\s*\$null\s*$') {
                    [void]$violations.Add("builder '$Builder' parks its publication under a constant-false clause")
                }
            }
        }
        $node = $node.Parent
    }

    # The call must be the value of a return statement: not piped anywhere, not
    # assigned to a sink, not evaluated and dropped.
    $pipeline = $publish.Parent
    if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst]) {
        [void]$violations.Add("builder '$Builder' does not publish as a bare pipeline")
        return , $violations.ToArray()
    }
    if ($pipeline.PipelineElements.Count -ne 1) {
        [void]$violations.Add("builder '$Builder' pipes its publication into $($pipeline.PipelineElements.Count - 1) further stage(s)")
    }
    $statement = $pipeline.Parent
    if ($statement -isnot [System.Management.Automation.Language.ReturnStatementAst]) {
        [void]$violations.Add("builder '$Builder' does not return the published payload")
    }

    # The payload published has to be the judged verdict, not the raw input the
    # producer had before Assert-ReviewerStageContract looked at it.
    $judgedName = ''
    if ($assertCalls.Count -eq 1) {
        $assignment = $assertCalls[0].Parent
        while ($null -ne $assignment -and
            $assignment -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
            $assignment = $assignment.Parent
        }
        if ($null -eq $assignment) {
            [void]$violations.Add("builder '$Builder' does not assign the contract verdict")
        }
        else {
            $judgedName = [string]$assignment.Left.Extent.Text
        }
    }
    $payloadArgument = ''
    for ($i = 0; $i -lt $publish.CommandElements.Count - 1; $i++) {
        $element = $publish.CommandElements[$i]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
            $element.ParameterName -ceq 'Payload') {
            $payloadArgument = [string]$publish.CommandElements[$i + 1].Extent.Text
        }
    }
    if ($judgedName.Length -gt 0 -and $payloadArgument -cne $judgedName) {
        [void]$violations.Add("builder '$Builder' publishes '$payloadArgument' rather than its judged verdict '$judgedName'")
    }

    # The stage and kind a builder publishes under are what a consumer sorts on;
    # a mislabelled artifact is worse than a missing one.
    $declared = @{}
    for ($i = 0; $i -lt $publish.CommandElements.Count - 1; $i++) {
        $element = $publish.CommandElements[$i]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            $declared[[string]$element.ParameterName] = [string]$publish.CommandElements[$i + 1].Extent.Text
        }
    }
    foreach ($pair in @(@{ Name = 'Stage'; Value = $Stage }, @{ Name = 'Kind'; Value = $Kind })) {
        $expected = "'$($pair.Value)'"
        if (-not $declared.ContainsKey([string]$pair.Name) -or
            [string]$declared[[string]$pair.Name] -cne $expected) {
            [void]$violations.Add("builder '$Builder' does not publish under $($pair.Name) $expected")
        }
    }

    return , $violations.ToArray()
}

$producersPath = Join-Path $repoRoot 'src\Agents\reviewer\StageProducers.ps1'
$producersText = [IO.File]::ReadAllText($producersPath)

foreach ($row in $stageRows) {
    $violations = Get-ShadowPublicationViolation -Text $producersText -Builder ([string]$row.Builder) `
        -Stage ([string]$row.Stage) -Kind ([string]$row.Kind)
    Assert-Shadow ($violations.Count -eq 0) `
        "Stage '$($row.Stage)' does not publish its contract to disk under the shadow switch: $($violations -join '; ')."
}

# The sabotage is run against the delivery-decision builder because it has a
# single collection field, so a mutation cannot be caught for an unrelated
# reason. Every mutation must be reported.
$sabotageRow = Get-ReviewerStageProducerContract -Stage 'deliveryDecision'
$live = @"
    return Publish-ReviewerStageShadowArtifact -Stage 'deliveryDecision' -Kind 'reviewer.stage.deliverydecision.v1' ``
        -Payload `$judged -Producer `$Producer
"@
Assert-Shadow ($producersText.Contains($live)) `
    "The delivery-decision publication is not where the static sabotage expects it; the mutations below prove nothing."

$mutations = [ordered]@{
    removed = "    return `$judged"
    unreachable = @"
    if (`$false) { return Publish-ReviewerStageShadowArtifact -Stage 'deliveryDecision' -Kind 'reviewer.stage.deliverydecision.v1' ``
        -Payload `$judged -Producer `$Producer }
    return `$judged
"@
    sunk = @"
    Publish-ReviewerStageShadowArtifact -Stage 'deliveryDecision' -Kind 'reviewer.stage.deliverydecision.v1' ``
        -Payload `$judged -Producer `$Producer | Out-Null
    return `$judged
"@
    discarded = @"
    `$null = Publish-ReviewerStageShadowArtifact -Stage 'deliveryDecision' -Kind 'reviewer.stage.deliverydecision.v1' ``
        -Payload `$judged -Producer `$Producer
    return `$judged
"@
    unjudged = @"
    return Publish-ReviewerStageShadowArtifact -Stage 'deliveryDecision' -Kind 'reviewer.stage.deliverydecision.v1' ``
        -Payload ([ordered]@{ selectedEntries = `$SelectedEntries }) -Producer `$Producer
"@
    mislabelled = @"
    return Publish-ReviewerStageShadowArtifact -Stage 'deliveryDecision' -Kind 'reviewer.stage.corpus.v1' ``
        -Payload `$judged -Producer `$Producer
"@
    unjudgedVerdict = @"
    `$judged = [ordered]@{ selectedEntries = `$SelectedEntries }
    return Publish-ReviewerStageShadowArtifact -Stage 'deliveryDecision' -Kind 'reviewer.stage.deliverydecision.v1' ``
        -Payload `$judged -Producer `$Producer
"@
}

foreach ($name in $mutations.Keys) {
    $mutated = $producersText.Replace($live, [string]$mutations[$name])
    Assert-Shadow ($mutated -cne $producersText) `
        "The '$name' publication sabotage did not change the producer text."
    if ($name -ceq 'unjudgedVerdict') {
        # This one also has to remove the real assertion, or the builder simply
        # has two verdicts and the checker is right to accept it.
        $mutated = $mutated.Replace(
            "`$judged = Assert-ReviewerStageContract -Kind 'reviewer.stage.deliverydecision.v1'",
            "`$ignored = Assert-ReviewerStageContract -Kind 'reviewer.stage.deliverydecision.v1'")
    }
    $mutatedViolations = Get-ShadowPublicationViolation -Text $mutated `
        -Builder ([string]$sabotageRow.Builder) -Stage ([string]$sabotageRow.Stage) `
        -Kind ([string]$sabotageRow.Kind)
    Assert-Shadow ($mutatedViolations.Count -gt 0) `
        "The '$name' publication sabotage left the checker reporting the delivery-decision boundary as publishing."
}

# ---------------------------------------------------------------------------
# 7. The switch's own text: the clauses that make it evidence rather than
#    decoration must be present, and removing any of them must be caught.
# ---------------------------------------------------------------------------

$shadowPath = Join-Path $repoRoot 'src\Agents\reviewer\StageShadow.ps1'
$shadowText = [IO.File]::ReadAllText($shadowPath)

$requiredClauses = [ordered]@{
    'strict shape' = '-Depth $depth -Form ([string]$state.Form) -StrictShape'
    'read back' = '$read = Read-ReviewerStageArtifact -Path $path -Kind $Kind'
    'kind consumed' = 'if ([string]$read.SourceKind -cne [string]$Kind) {'
    'adapter refused' = 'if ([int]$read.SourceVersion -ne [int]$written.ContractVersion -or [bool]$read.Adapted) {'
    'digest consumed' = 'if ([string]$read.Sha256 -cne [string]$written.Sha256 -or'
    'form consumed' = 'if ([string]$read.Form -cne [string]$written.Form -or [int]$read.Depth -ne [int]$written.Depth) {'
    'round trip consumed' = 'if ($expected -cne $actual) {'
    'read only' = '$item.IsReadOnly = $true'
    'collision refused' = '[System.IO.FileMode]::CreateNew,'
    'default off' = 'if ($null -eq $script:ReviewerStageShadowState) { return $Payload }'
    'depth probe' = 'Assert-ReviewerStageShadowDepthSufficient -Payload $Payload -Depth $depth -Kind $Kind'
    'depth ceiling refused' = 'if ($Depth -ge $script:ReviewerStageShadowProbeCeiling) {'
    'write refusal' = 'Assert-ReviewerStageShadowNoWriteCapability -WriteCapability $capability'
    'private directory' = '$resolved = Assert-ReviewerStageShadowPrivateDirectory -Directory $Directory'
}
foreach ($clause in $requiredClauses.Keys) {
    Assert-Shadow ($shadowText.Contains([string]$requiredClauses[$clause])) `
        "The shadow switch no longer carries its '$clause' clause; the on-disk half is not in force as described."
}

# The registry-held Kind and ContractVersion are the reader echoing the caller's
# own request. Comparing them would read as evidence and prove nothing, so the
# switch must not do it - a reviewer who "restores" those comparisons has made
# the boundary weaker while making it look stronger.
foreach ($tautology in [string[]]@(
        'if ([string]$read.Kind -cne [string]$written.Kind) {',
        'if ([int]$read.ContractVersion -ne [int]$written.ContractVersion) {')) {
    Assert-Shadow (-not $shadowText.Contains($tautology)) `
        "The shadow switch compares a registry-held field ('$tautology') that cannot disagree with itself; that is decoration, not evidence."
}

# The load guard has to be a script-scoped VARIABLE, not a command. A visible
# function whose $script: state lives in another scope is exactly the failure
# this file already hit once.
$producersGuard = "if (-not (Get-Variable -Name 'ReviewerStageShadowMarkerName' -Scope Script -ErrorAction SilentlyContinue)) {"
Assert-Shadow ($producersText.Contains($producersGuard)) `
    'StageProducers.ps1 no longer guards its shadow dot-source on a script-scoped variable; a Get-Command guard silently splits script scope.'

# No provider, no model, no external write. This is a static proof over the
# switch and its runner, because a run that merely happened not to reach a
# network call is not the same fact as code that cannot make one.
$forbiddenTokens = [string[]]@(
    'Invoke-WebRequest', 'Invoke-RestMethod', 'System.Net.Http', 'Net.WebClient',
    'Start-Process', 'Invoke-Expression', 'Add-Type', 'New-ReviewerModelAdapter',
    'Invoke-ReviewerModelCall', 'Publish-ReviewerReviewComment', 'git push', 'gh pr'
)
$runnerPath = Join-Path $repoRoot 'tools\Invoke-ReviewerStageShadowRun.ps1'
foreach ($file in @($shadowPath, $runnerPath)) {
    $text = [IO.File]::ReadAllText($file)
    foreach ($token in $forbiddenTokens) {
        Assert-Shadow (-not $text.Contains($token)) `
            "'$(Split-Path $file -Leaf)' mentions '$token'; a shadow run must be provably free of providers, models, and external writes."
    }
}

# ---------------------------------------------------------------------------
# 8. Wiring: every builder in the table is reachable, and the table is the only
#    place the twelve stages are declared.
# ---------------------------------------------------------------------------

Assert-Shadow ($stageRows.Count -eq 12) `
    "The stage producer table declares $($stageRows.Count) boundaries, not 12."
$publishMentions = @([regex]::Matches($producersText, 'Publish-ReviewerStageShadowArtifact -Stage'))
Assert-Shadow ($publishMentions.Count -eq 12) `
    "StageProducers.ps1 publishes at $($publishMentions.Count) boundaries, not 12."

foreach ($row in $stageRows) {
    Assert-Shadow ($null -ne (Get-Command -Name ([string]$row.Builder) -CommandType Function -ErrorAction SilentlyContinue)) `
        "Stage '$($row.Stage)' names builder '$($row.Builder)', which is not defined."
}

# ---------------------------------------------------------------------------
Get-ChildItem -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue |
    ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL: $failure" }
    Write-Host "FAIL - $($failures.Count) of $checks stage shadow checks failed."
    exit 1
}
Write-Host "PASS - $checks stage shadow contract checks."
exit 0
