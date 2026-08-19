<#
.SYNOPSIS
    Verifies the versioned stage file contract: round trip, fail-closed
    rejections, atomicity, version adapters, and the read-only inventory.

.DESCRIPTION
    Every stage child process publishes its result as one envelope written to a
    caller-named file. This check exercises the writer and the reader against
    the payload shapes a broken or truncated child can actually produce, so a
    collapsed collection or a stdout-contaminated artifact fails closed instead
    of being consumed as if it were a valid empty result.

    No models are invoked and nothing outside the temporary directory is written.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'src/Agents/reviewer/StageContract.ps1')

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Detail = ''
    )

    $script:Checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:Failures.Add("$Name :: $Detail") }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )

    Add-Result -Name $Name -Passed $Condition -Detail $Detail
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Expect,
        [object[]]$Arguments = @()
    )

    # State the loop-varying values as arguments instead of capturing them with
    # GetNewClosure, which copies variables but not the surrounding scope.
    try {
        & $Action @Arguments | Out-Null
        Add-Result -Name $Name -Passed $false -Detail 'accepted a payload it had to reject'
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -like "*$Expect*") {
            Add-Result -Name $Name -Passed $true -Detail $Expect
        }
        else {
            Add-Result -Name $Name -Passed $false -Detail "rejected with an unexpected reason: $message"
        }
    }
}

# ---------------------------------------------------------------------------
# Fixture contracts. Employer-neutral and shaped only to exercise the helper.
# ---------------------------------------------------------------------------

Clear-ReviewerStageContractRegistry

Register-ReviewerStageContract `
    -Kind 'fixture.stage.union' `
    -ContractVersion 2 `
    -SupportedVersions @(1, 2) `
    -RequiredFields @('items', 'fingerprints') `
    -OptionalFields @('notes') `
    -CollectionFields @('items', 'fingerprints', 'items[*].evidenceFactIds') `
    -Adapters @{
        1 = {
            param($Legacy)
            $upgraded = [ordered]@{
                items = @()
                fingerprints = @()
            }
            $legacyItems = @()
            if ($null -ne $Legacy.entries) { $legacyItems = @($Legacy.entries) }
            $rebuilt = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in $legacyItems) {
                $rebuilt.Add([ordered]@{
                    id = [string]$entry.id
                    evidenceFactIds = [object[]]@()
                })
            }
            $upgraded['items'] = [object[]]$rebuilt.ToArray()
            $upgraded['fingerprints'] = [object[]]@()
            return $upgraded
        }
    } | Out-Null

Register-ReviewerStageContract `
    -Kind 'fixture.stage.other' `
    -ContractVersion 1 `
    -RequiredFields @('items') `
    -CollectionFields @('items') | Out-Null

# A path whose last segment is [*] is accepted by the segment parser, so the
# boundary has to judge it from the parent value: a null or zero-element value
# has no elements to walk, and those are exactly the shapes that must fail.
Register-ReviewerStageContract `
    -Kind 'fixture.stage.each' `
    -ContractVersion 1 `
    -RequiredFields @('values') `
    -CollectionFields @('values[*]') | Out-Null

$root = Join-Path ([IO.Path]::GetTempPath()) ("reviewer-stage-contract-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

function New-FixturePayload {
    param([int]$ItemCount = 1, [int]$FingerprintCount = 0, [hashtable]$ExtraFields = @{})

    $items = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $ItemCount; $i++) {
        $items.Add([ordered]@{
            id = "item-$i"
            evidenceFactIds = [object[]]@()
        })
    }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $FingerprintCount; $i++) { [void]$set.Add("fp-$i") }
    $payload = [ordered]@{
        items = [object[]]$items.ToArray()
        fingerprints = $set
    }
    foreach ($key in (ConvertTo-ReviewerStageArray -Value $ExtraFields.Keys)) {
        $payload[[string]$key] = $ExtraFields[$key]
    }
    return $payload
}

function Write-RawArtifact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$Bom
    )

    $path = Join-Path $root $Name
    $encoding = [Text.UTF8Encoding]::new($Bom.IsPresent)
    [IO.File]::WriteAllBytes($path, $encoding.GetPreamble() + $encoding.GetBytes($Text))
    return $path
}

try {
    # -----------------------------------------------------------------------
    # Round trip and cardinality preservation.
    # -----------------------------------------------------------------------

    foreach ($case in @(
            @{ Label = 'zero'; Items = 0; Fingerprints = 0 }
            @{ Label = 'one'; Items = 1; Fingerprints = 1 }
            @{ Label = 'many'; Items = 5; Fingerprints = 3 }
        )) {
        $path = Join-Path $root "roundtrip-$($case.Label).json"
        $written = Write-ReviewerStageArtifact `
            -Path $path `
            -Kind 'fixture.stage.union' `
            -Payload (New-FixturePayload -ItemCount $case.Items -FingerprintCount $case.Fingerprints) `
            -Depth 12 -Form compact
        $read = Read-ReviewerStageArtifact -Path $path -Kind 'fixture.stage.union'
        $items = @($read.Payload.items)
        $fingerprints = @($read.Payload.fingerprints)
        Assert-True -Name "roundtrip/$($case.Label)/item-count" `
            -Condition ($items.Count -eq $case.Items) `
            -Detail "expected $($case.Items), read $($items.Count)"
        Assert-True -Name "roundtrip/$($case.Label)/fingerprint-count" `
            -Condition ($fingerprints.Count -eq $case.Fingerprints) `
            -Detail "expected $($case.Fingerprints), read $($fingerprints.Count)"
        Assert-True -Name "roundtrip/$($case.Label)/digest-stable" `
            -Condition ($read.Sha256 -eq $written.Sha256) `
            -Detail 'reader and writer disagreed about the bytes'
    }

    $singletonPath = Join-Path $root 'singleton-shape.json'
    Write-ReviewerStageArtifact -Path $singletonPath -Kind 'fixture.stage.union' `
        -Payload (New-FixturePayload -ItemCount 1 -FingerprintCount 1) -Depth 12 -Form compact | Out-Null
    $singletonText = [IO.File]::ReadAllText($singletonPath)
    Assert-True -Name 'roundtrip/singleton-serializes-as-array' `
        -Condition ($singletonText.Contains('"items":[{') -and $singletonText.Contains('"fingerprints":["fp-0"]')) `
        -Detail 'a one-element collection was serialized as a bare object or scalar'

    $emptyPath = Join-Path $root 'empty-shape.json'
    Write-ReviewerStageArtifact -Path $emptyPath -Kind 'fixture.stage.union' `
        -Payload (New-FixturePayload -ItemCount 0 -FingerprintCount 0) -Depth 12 -Form compact | Out-Null
    $emptyText = [IO.File]::ReadAllText($emptyPath)
    Assert-True -Name 'roundtrip/empty-set-serializes-as-empty-array' `
        -Condition ($emptyText.Contains('"items":[]') -and $emptyText.Contains('"fingerprints":[]')) `
        -Detail 'an empty collection collapsed to null instead of []'

    # -----------------------------------------------------------------------
    # Encoding, form, and file discipline.
    # -----------------------------------------------------------------------

    $bytes = [IO.File]::ReadAllBytes($emptyPath)
    Assert-True -Name 'encoding/no-bom' `
        -Condition (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) `
        -Detail 'writer emitted a UTF-8 BOM'
    Assert-True -Name 'encoding/single-trailing-newline' `
        -Condition ($bytes[$bytes.Length - 1] -eq 0x0A -and $bytes[$bytes.Length - 2] -ne 0x0A) `
        -Detail 'artifact did not end with exactly one newline'
    Assert-True -Name 'encoding/no-carriage-return' `
        -Condition (-not ($bytes -contains 0x0D)) `
        -Detail 'artifact contains CR bytes, so digests differ per platform'

    $indentedPath = Join-Path $root 'indented.json'
    Write-ReviewerStageArtifact -Path $indentedPath -Kind 'fixture.stage.union' `
        -Payload (New-FixturePayload -ItemCount 2) -Depth 12 -Form indented | Out-Null
    $indentedRead = Read-ReviewerStageArtifact -Path $indentedPath -Kind 'fixture.stage.union'
    Assert-True -Name 'form/indented-round-trip' `
        -Condition ($indentedRead.Form -eq 'indented' -and @($indentedRead.Payload.items).Count -eq 2) `
        -Detail 'indented form did not round trip'

    Assert-Throws -Name 'write/rejects-bare-file-name' `
        -Expect 'must name a directory' `
        -Action { Write-ReviewerStageArtifact -Path 'union.json' -Kind 'fixture.stage.union' -Payload (New-FixturePayload) -Depth 12 -Form compact }

    Assert-Throws -Name 'write/rejects-missing-directory' `
        -Expect 'does not exist' `
        -Action { Write-ReviewerStageArtifact -Path (Join-Path $root 'no-such-dir/union.json') -Kind 'fixture.stage.union' -Payload (New-FixturePayload) -Depth 12 -Form compact }

    Assert-Throws -Name 'write/rejects-unknown-payload-field' `
        -Expect 'unknown field' `
        -Action {
            Write-ReviewerStageArtifact -Path (Join-Path $root 'unknown.json') -Kind 'fixture.stage.union' `
                -Payload (New-FixturePayload -ExtraFields @{ surprise = 'value' }) -Depth 12 -Form compact
        }

    Assert-Throws -Name 'write/rejects-missing-required-field' `
        -Expect 'missing required field' `
        -Action {
            Write-ReviewerStageArtifact -Path (Join-Path $root 'missing.json') -Kind 'fixture.stage.union' -Payload ([ordered]@{ items = [object[]]@() }) -Depth 12 -Form compact
        }

    Assert-Throws -Name 'write/rejects-scalar-payload' `
        -Expect 'collapsed to a bare' `
        -Action { Write-ReviewerStageArtifact -Path (Join-Path $root 'scalar.json') -Kind 'fixture.stage.union' -Payload 'not-an-object' -Depth 12 -Form compact }

    Assert-Throws -Name 'write/rejects-array-payload' `
        -Expect 'must be an object' `
        -Action { Write-ReviewerStageArtifact -Path (Join-Path $root 'array.json') -Kind 'fixture.stage.union' -Payload ([object[]]@(1, 2)) -Depth 12 -Form compact }

    $repairPath = Join-Path $root 'repair-scalar.json'
    Write-ReviewerStageArtifact -Path $repairPath -Kind 'fixture.stage.other' `
        -Payload ([ordered]@{ items = 'one-item' }) -Depth 12 -Form compact | Out-Null
    $repaired = [IO.File]::ReadAllText($repairPath)
    Assert-True -Name 'write/repairs-unrolled-singleton-into-array' `
        -Condition ($repaired.Contains('"items":["one-item"]')) `
        -Detail 'a singleton that PowerShell unrolled to a scalar was not restored to an array'

    # A repaired singleton is still only repaired in shape. An element that does
    # not carry a declared nested collection is a producer defect, and the
    # writer has to say so rather than publish a payload a strict-mode consumer
    # would throw on.
    Assert-Throws -Name 'write/rejects-element-missing-declared-nested-collection' `
        -Expect 'evidenceFactIds is missing' `
        -Action {
            Write-ReviewerStageArtifact -Path (Join-Path $root 'nested-missing.json') -Kind 'fixture.stage.union' `
                -Payload ([ordered]@{ items = 'one-item'; fingerprints = [object[]]@() }) -Depth 12 -Form compact
        }

    # -StrictShape reports the producer's own collapse instead of repairing it.
    Assert-Throws -Name 'write/strict-shape-reports-producer-collapse' `
        -Expect 'received collapsed collection field' `
        -Action {
            Write-ReviewerStageArtifact -Path (Join-Path $root 'strict.json') -Kind 'fixture.stage.other' `
                -Payload ([ordered]@{ items = 'one-item' }) -Depth 12 -Form compact -StrictShape
        }

    $lenientPath = Join-Path $root 'lenient.json'
    Write-ReviewerStageArtifact -Path $lenientPath -Kind 'fixture.stage.other' `
        -Payload ([ordered]@{ items = [object[]]@('a') }) -Depth 12 -Form compact -StrictShape | Out-Null
    Assert-True -Name 'write/strict-shape-accepts-conforming-producer' `
        -Condition ([IO.File]::ReadAllText($lenientPath).Contains('"items":["a"]')) `
        -Detail 'a producer that already emitted a real array was rejected under -StrictShape'

    # Terminal [*] must be judged from the parent value, not from elements that
    # a null or empty value does not have.
    $terminalNull = $null
    foreach ($terminalCase in @(
            @{ Label = 'null'; Value = $terminalNull; Violates = $true }
            @{ Label = 'scalar'; Value = 'x'; Violates = $true }
            @{ Label = 'empty'; Value = [object[]]@(); Violates = $false }
            @{ Label = 'many'; Value = [object[]]@('a', 'b'); Violates = $false }
        )) {
        $terminalPayload = [ordered]@{ values = $terminalCase.Value }
        $terminalViolations = Test-ReviewerStageCollectionShape -Payload $terminalPayload -CollectionFields @('values[*]')
        Assert-True -Name "shape/terminal-each-$($terminalCase.Label)" `
            -Condition (($terminalViolations.Count -gt 0) -eq $terminalCase.Violates) `
            -Detail "values[*] with a $($terminalCase.Label) value reported $($terminalViolations.Count) violation(s)"
    }

    $terminalMissing = Test-ReviewerStageCollectionShape -Payload ([ordered]@{ other = 1 }) -CollectionFields @('values[*]')
    Assert-True -Name 'shape/terminal-each-missing' `
        -Condition ($terminalMissing.Count -eq 1 -and $terminalMissing[0] -eq 'values is missing') `
        -Detail "an absent values[*] reported: $($terminalMissing -join '; ')"

    Assert-Throws -Name 'read/rejects-null-terminal-each' -Expect 'lost collection shape' -Action {
        $eachPath = Join-Path $root 'each-null.json'
        [IO.File]::WriteAllText($eachPath, (ConvertTo-Json -Depth 32 -Compress -InputObject ([ordered]@{
                        envelopeVersion = 1
                        kind = 'fixture.stage.each'
                        contractVersion = 1
                        form = 'compact'
                        depth = 12
                        payload = [ordered]@{ values = $null }
                    })), [Text.UTF8Encoding]::new($false))
        Read-ReviewerStageArtifact -Path $eachPath -Kind 'fixture.stage.each'
    }

    Assert-Throws -Name 'write/rejects-unregistered-kind' `
        -Expect 'is not registered' `
        -Action { Write-ReviewerStageArtifact -Path (Join-Path $root 'nokind.json') -Kind 'fixture.stage.absent' -Payload (New-FixturePayload) -Depth 12 -Form compact }

    Assert-Throws -Name 'write/rejects-oversize-payload' `
        -Expect 'above the' `
        -Action {
            Write-ReviewerStageArtifact -Path (Join-Path $root 'oversize.json') -Kind 'fixture.stage.union' `
                -Payload (New-FixturePayload -ItemCount 40) -Depth 12 -Form compact -MaxBytes 64
        }

    # -----------------------------------------------------------------------
    # Reader rejections. Each case is a payload a broken child can produce.
    # -----------------------------------------------------------------------

    $rejections = @(
        @{ Name = 'read/rejects-empty-file'; Text = ''; Expect = 'is empty' }
        @{ Name = 'read/rejects-whitespace-only'; Text = "   `n  "; Expect = 'only whitespace' }
        @{ Name = 'read/rejects-bare-scalar'; Text = '42'; Expect = 'does not begin with a JSON object' }
        @{ Name = 'read/rejects-bare-array'; Text = '[]'; Expect = 'does not begin with a JSON object' }
        @{ Name = 'read/rejects-stdout-prologue'; Text = "VERBOSE: starting`n{`"envelopeVersion`":1}"; Expect = 'does not begin with a JSON object' }
        @{ Name = 'read/rejects-stdout-epilogue'; Text = '{"envelopeVersion":1} WARNING: done'; Expect = 'does not end with a JSON object' }
        @{ Name = 'read/rejects-truncated-json'; Text = '{"envelopeVersion":1,"kind":"fixture.stage.union","contractVersion":2,"form":"compact","depth":12,"payload":{"items":['; Expect = 'does not end with a JSON object' }
        @{ Name = 'read/rejects-brace-balanced-but-unparsable'; Text = '{"envelopeVersion":1,,}'; Expect = 'is not parsable JSON' }
    )
    foreach ($case in $rejections) {
        $path = Write-RawArtifact -Name ("reject-" + ($case.Name -replace '[^a-z0-9]', '-') + '.json') -Text $case.Text
        Assert-Throws -Name $case.Name -Expect $case.Expect -Arguments @($path) `
            -Action { param($ArtifactPath) Read-ReviewerStageArtifact -Path $ArtifactPath -Kind 'fixture.stage.union' }
    }

    $bomPath = Write-RawArtifact -Name 'reject-bom.json' -Text ([IO.File]::ReadAllText($emptyPath)) -Bom
    Assert-Throws -Name 'read/rejects-utf8-bom' -Expect 'UTF-8 BOM' `
        -Action { Read-ReviewerStageArtifact -Path $bomPath -Kind 'fixture.stage.union' }

    Assert-Throws -Name 'read/rejects-missing-file' -Expect 'does not exist' `
        -Action { Read-ReviewerStageArtifact -Path (Join-Path $root 'absent.json') -Kind 'fixture.stage.union' }

    Assert-Throws -Name 'read/rejects-oversize-file' -Expect 'above the' `
        -Action { Read-ReviewerStageArtifact -Path $emptyPath -Kind 'fixture.stage.union' -MaxBytes 8 }

    $validEnvelope = ([IO.File]::ReadAllText($emptyPath)).Trim() | ConvertFrom-Json -Depth 32 -AsHashtable

    function New-Envelope {
        param([hashtable]$Overrides = @{}, [string[]]$Remove = @())

        $copy = [ordered]@{}
        foreach ($key in @('envelopeVersion', 'kind', 'contractVersion', 'form', 'depth', 'payload')) {
            if ($Remove -contains $key) { continue }
            $copy[$key] = $validEnvelope.$key
        }
        foreach ($key in $Overrides.Keys) { $copy[$key] = $Overrides[$key] }
        return (ConvertTo-Json -InputObject $copy -Depth 32 -Compress)
    }

    # Hoisted so the fixture table itself contains no literal $null element.
    $absentCollection = $null
    $envelopeCases = [object[]]@(
        @{ Name = 'read/rejects-missing-envelope-field'; Text = (New-Envelope -Remove @('depth')); Expect = 'envelope is missing' }
        @{ Name = 'read/rejects-unknown-envelope-field'; Text = (New-Envelope -Overrides @{ extra = 'x' }); Expect = 'unknown field' }
        @{ Name = 'read/rejects-unsupported-envelope-version'; Text = (New-Envelope -Overrides @{ envelopeVersion = 9 }); Expect = 'envelope version' }
        @{ Name = 'read/rejects-kind-mismatch'; Text = (New-Envelope -Overrides @{ kind = 'fixture.stage.other' }); Expect = 'kind mismatch' }
        @{ Name = 'read/rejects-unknown-form'; Text = (New-Envelope -Overrides @{ form = 'pretty' }); Expect = "unsupported form" }
        @{ Name = 'read/rejects-out-of-range-depth'; Text = (New-Envelope -Overrides @{ depth = 0 }); Expect = 'out-of-range depth' }
        @{ Name = 'read/rejects-unsupported-contract-version'; Text = (New-Envelope -Overrides @{ contractVersion = 7 }); Expect = 'supported versions are' }
        @{ Name = 'read/rejects-collapsed-collection'; Text = (New-Envelope -Overrides @{ payload = [ordered]@{ items = 'scalar'; fingerprints = [object[]]@() } }); Expect = 'lost collection shape' }
        @{ Name = 'read/rejects-null-collection'; Text = (New-Envelope -Overrides @{ payload = [ordered]@{ items = $absentCollection; fingerprints = [object[]]@() } }); Expect = 'lost collection shape' }
        @{ Name = 'read/rejects-missing-payload-field'; Text = (New-Envelope -Overrides @{ payload = [ordered]@{ items = [object[]]@() } }); Expect = 'missing required field' }
        @{ Name = 'read/rejects-unknown-payload-field'; Text = (New-Envelope -Overrides @{ payload = [ordered]@{ items = [object[]]@(); fingerprints = [object[]]@(); rogue = 1 } }); Expect = 'unknown field' }
        @{ Name = 'read/rejects-scalar-payload'; Text = (New-Envelope -Overrides @{ payload = 'collapsed' }); Expect = 'collapsed to a bare' }
        # An element that omits a declared nested collection used to read clean,
        # then throw in the consumer under Set-StrictMode. Absent is a boundary
        # rejection, not a silently skipped site.
        @{ Name = 'read/rejects-element-missing-nested-collection'
            Text = (New-Envelope -Overrides @{ payload = [ordered]@{ items = [object[]]@([ordered]@{ id = 'x' }); fingerprints = [object[]]@() } })
            Expect = 'evidenceFactIds is missing'
        }
    )
    foreach ($case in $envelopeCases) {
        $path = Write-RawArtifact -Name ("envelope-" + ($case.Name -replace '[^a-z0-9]', '-') + '.json') -Text $case.Text
        Assert-Throws -Name $case.Name -Expect $case.Expect -Arguments @($path) `
            -Action { param($ArtifactPath) Read-ReviewerStageArtifact -Path $ArtifactPath -Kind 'fixture.stage.union' }
    }

    $indentedText = [IO.File]::ReadAllText($indentedPath)
    $mislabeled = $indentedText.Trim() | ConvertFrom-Json -Depth 32 -AsHashtable
    $mislabeled.form = 'compact'
    $mislabeledPath = Write-RawArtifact -Name 'form-mismatch.json' -Text (ConvertTo-Json -InputObject $mislabeled -Depth 32)
    Assert-Throws -Name 'read/rejects-form-vs-bytes-mismatch' -Expect "declares form" `
        -Action { Read-ReviewerStageArtifact -Path $mislabeledPath -Kind 'fixture.stage.union' }

    # -----------------------------------------------------------------------
    # Version adapters. Older artifacts are read only through an explicit one.
    # -----------------------------------------------------------------------

    $legacyText = ConvertTo-Json -Depth 32 -Compress -InputObject ([ordered]@{
            envelopeVersion = 1
            kind = 'fixture.stage.union'
            contractVersion = 1
            form = 'compact'
            depth = 12
            payload = [ordered]@{ entries = [object[]]@([ordered]@{ id = 'legacy-0' }) }
        })
    $legacyPath = Write-RawArtifact -Name 'legacy-v1.json' -Text $legacyText
    $legacyRead = Read-ReviewerStageArtifact -Path $legacyPath -Kind 'fixture.stage.union'
    Assert-True -Name 'adapter/upgrades-declared-version' `
        -Condition ($legacyRead.Adapted -and $legacyRead.SourceVersion -eq 1 -and $legacyRead.ContractVersion -eq 2) `
        -Detail 'a v1 artifact was not routed through the registered adapter'
    Assert-True -Name 'adapter/preserves-collection-shape' `
        -Condition (@($legacyRead.Payload.items).Count -eq 1 -and @($legacyRead.Payload.items[0].evidenceFactIds).Count -eq 0) `
        -Detail 'adapter output failed the collection contract'
    Assert-True -Name 'roundtrip/current-artifact-not-adapted' `
        -Condition (-not $indentedRead.Adapted) `
        -Detail 'a current-version artifact was adapted'

    Assert-Throws -Name 'register/rejects-supported-version-without-adapter' `
        -Expect 'without an explicit adapter' `
        -Action {
            Register-ReviewerStageContract -Kind 'fixture.stage.gap' -ContractVersion 2 -SupportedVersions @(1, 2) -RequiredFields @('items') -CollectionFields @('items')
        }

    Assert-Throws -Name 'register/rejects-adapter-for-current-version' `
        -Expect 'adapter from its own current version' `
        -Action {
            Register-ReviewerStageContract -Kind 'fixture.stage.selfadapt' -ContractVersion 1 -RequiredFields @('items') -CollectionFields @('items') -Adapters @{ 1 = { param($p) $p } }
        }

    Assert-Throws -Name 'register/rejects-non-dotted-kind' -Expect 'is not a dotted lowercase' `
        -Action { Register-ReviewerStageContract -Kind 'FixtureStageUnion' -ContractVersion 1 -RequiredFields @('items') }

    Assert-Throws -Name 'register/rejects-required-and-optional-overlap' -Expect 'both required and optional' `
        -Action { Register-ReviewerStageContract -Kind 'fixture.stage.overlap' -ContractVersion 1 -RequiredFields @('items') -OptionalFields @('items') }

    # -----------------------------------------------------------------------
    # Atomicity and read-only inventory.
    # -----------------------------------------------------------------------

    $atomicPath = Join-Path $root 'atomic.json'
    Write-ReviewerStageArtifact -Path $atomicPath -Kind 'fixture.stage.union' `
        -Payload (New-FixturePayload -ItemCount 3) -Depth 12 -Form compact | Out-Null
    $before = [IO.File]::ReadAllBytes($atomicPath)
    try {
        Write-ReviewerStageArtifact -Path $atomicPath -Kind 'fixture.stage.union' `
            -Payload (New-FixturePayload -ItemCount 4 -ExtraFields @{ rogue = 'undeclared' }) `
            -Depth 12 -Form compact | Out-Null
    }
    catch {
        # Expected: the failed write must not disturb the previous artifact.
    }
    $after = [IO.File]::ReadAllBytes($atomicPath)
    Assert-True -Name 'atomicity/failed-write-leaves-previous-artifact' `
        -Condition ([Convert]::ToHexString($before) -eq [Convert]::ToHexString($after)) `
        -Detail 'a rejected write replaced or truncated the existing file'
    Assert-True -Name 'atomicity/no-temporary-files-remain' `
        -Condition (@(Get-ChildItem -LiteralPath $root -Filter '*.tmp' -File).Count -eq 0) `
        -Detail 'temporary artifacts were left behind'

    $inventoryDir = Join-Path $root 'inventory'
    New-Item -ItemType Directory -Path $inventoryDir | Out-Null
    Write-ReviewerStageArtifact -Path (Join-Path $inventoryDir 'a-good.json') -Kind 'fixture.stage.union' `
        -Payload (New-FixturePayload -ItemCount 1) -Depth 12 -Form compact | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $inventoryDir 'b-garbage.json'), [Text.Encoding]::UTF8.GetBytes('not json'))
    $readOnlyPath = Join-Path $inventoryDir 'c-readonly.json'
    Write-ReviewerStageArtifact -Path $readOnlyPath -Kind 'fixture.stage.other' `
        -Payload ([ordered]@{ items = [object[]]@('x') }) -Depth 12 -Form compact | Out-Null
    Set-ItemProperty -LiteralPath $readOnlyPath -Name IsReadOnly -Value $true

    $inventorySnapshot = @(Get-ChildItem -LiteralPath $inventoryDir -File | ForEach-Object {
            '{0}|{1}|{2:o}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc
        })
    $inventory = Get-ReviewerStageArtifactInventory -Directory $inventoryDir
    $inventoryRows = @($inventory)
    Assert-True -Name 'inventory/reports-every-file' -Condition ($inventoryRows.Count -eq 3) `
        -Detail "expected 3 rows, got $($inventoryRows.Count)"
    Assert-True -Name 'inventory/flags-unreadable-artifact' `
        -Condition (@($inventoryRows | Where-Object { $_.Status -ne 'envelope' }).Count -eq 1) `
        -Detail 'a non-contract file was not flagged'
    Assert-True -Name 'inventory/reads-read-only-artifact' `
        -Condition (@($inventoryRows | Where-Object { $_.Name -eq 'c-readonly.json' -and $_.Kind -eq 'fixture.stage.other' }).Count -eq 1) `
        -Detail 'a read-only artifact was not inventoried'
    $inventoryAfter = @(Get-ChildItem -LiteralPath $inventoryDir -File | ForEach-Object {
            '{0}|{1}|{2:o}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc
        })
    Assert-True -Name 'inventory/does-not-modify-artifacts' `
        -Condition (($inventorySnapshot -join ';') -eq ($inventoryAfter -join ';')) `
        -Detail 'the inventory mutated the directory it read'

    $readOnlyRead = Read-ReviewerStageArtifact -Path $readOnlyPath -Kind 'fixture.stage.other'
    Assert-True -Name 'read/accepts-read-only-artifact' `
        -Condition (@($readOnlyRead.Payload.items).Count -eq 1) `
        -Detail 'a read-only contract artifact could not be read'

    # -----------------------------------------------------------------------
    # Member access must hand back the value itself
    # -----------------------------------------------------------------------
    # Write-Output -NoEnumerate wraps a scalar in a one-element list, which made
    # every non-array member arrive as a container: a nested object stopped
    # answering the has-member test, so a valid nested collection path was
    # rejected as missing, and a bare scalar looked like an object to any shape
    # check. These pin the accessor to the value's own identity.
    Assert-True -Name 'member/returns-scalar-unwrapped' `
        -Condition ((Get-ReviewerStageMember -Node ([ordered]@{ v = 'x' }) -Name 'v') -is [string]) `
        -Detail 'a scalar member came back wrapped in a container'
    Assert-True -Name 'member/returns-nested-object-unwrapped' `
        -Condition ((Get-ReviewerStageMember -Node ([ordered]@{ v = [ordered]@{ k = 1 } }) -Name 'v') -is [System.Collections.IDictionary]) `
        -Detail 'a nested dictionary member came back wrapped in a container'
    Assert-True -Name 'member/keeps-empty-array-a-collection' `
        -Condition ((Get-ReviewerStageMember -Node ([ordered]@{ v = @() }) -Name 'v') -is [System.Array]) `
        -Detail 'an empty collection member did not survive as a collection'
    Assert-True -Name 'shape/accepts-valid-nested-collection-path' `
        -Condition ((Test-ReviewerStageCollectionShape -Payload ([ordered]@{ outer = [ordered]@{ inner = @('a') } }) -CollectionFields @('outer.inner')).Count -eq 0) `
        -Detail 'a well-formed nested collection path was reported as a violation'
    Assert-True -Name 'shape/names-the-real-collapsed-type' `
        -Condition (((Test-ReviewerStageCollectionShape -Payload ([ordered]@{ v = 'x' }) -CollectionFields @('v')) -join ';') -like '*String*') `
        -Detail 'a collapsed collection was reported as the wrong type'

    # -----------------------------------------------------------------------
    # Declared maps
    # -----------------------------------------------------------------------
    # A map is not a list and has no repair from an array or a scalar, so it is
    # validated and never normalized.
    Assert-True -Name 'map/accepts-keyed-object' `
        -Condition ((Test-ReviewerStageMapShape -Payload ([ordered]@{ m = [ordered]@{ k = 'v' } }) -MapFields @('m')).Count -eq 0) `
        -Detail 'a well-formed map was rejected'
    Assert-True -Name 'map/accepts-empty-object' `
        -Condition ((Test-ReviewerStageMapShape -Payload ([ordered]@{ m = [ordered]@{} }) -MapFields @('m')).Count -eq 0) `
        -Detail 'an empty map was rejected'
    Assert-True -Name 'map/rejects-array' `
        -Condition (((Test-ReviewerStageMapShape -Payload ([ordered]@{ m = @('a') }) -MapFields @('m')) -join ';') -like '*array*') `
        -Detail 'an array in a declared map field was accepted'
    Assert-True -Name 'map/rejects-scalar' `
        -Condition (((Test-ReviewerStageMapShape -Payload ([ordered]@{ m = 'a' }) -MapFields @('m')) -join ';') -like '*String*') `
        -Detail 'a scalar in a declared map field was accepted'
    Assert-True -Name 'map/rejects-null-and-missing-distinctly' `
        -Condition ((((Test-ReviewerStageMapShape -Payload ([ordered]@{ m = $null }) -MapFields @('m')) -join ';') -like '*null*') -and
        (((Test-ReviewerStageMapShape -Payload ([ordered]@{}) -MapFields @('m')) -join ';') -like '*missing*')) `
        -Detail 'a null map and an absent map were not distinguished'

    Register-ReviewerStageContract -Kind 'fixture.stage.map' -ContractVersion 1 `
        -RequiredFields @('m') -MapFields @('m') | Out-Null
    Assert-Throws -Name 'register/rejects-collection-and-map-conflict' `
        -Action { Register-ReviewerStageContract -Kind 'fixture.stage.conflict' -ContractVersion 1 -RequiredFields @('m') -CollectionFields @('m') -MapFields @('m') } `
        -Expect 'both a collection and a map'

    $mapDir = Join-Path $root 'maps'
    New-Item -ItemType Directory -Path $mapDir | Out-Null
    $mapPath = Join-Path $mapDir 'map.json'
    Write-ReviewerStageArtifact -Path $mapPath -Kind 'fixture.stage.map' -Depth 8 -Form compact `
        -Payload ([ordered]@{ m = [ordered]@{ 'k-0' = 'v-0' } }) | Out-Null
    $mapRead = Read-ReviewerStageArtifact -Path $mapPath -Kind 'fixture.stage.map'
    Assert-True -Name 'map/round-trips-through-a-file' `
        -Condition (@($mapRead.Payload.m.PSObject.Properties | ForEach-Object { $_.Name }).Count -eq 1) `
        -Detail 'a declared map did not survive a write and read'
    Assert-Throws -Name 'write/rejects-array-in-declared-map' `
        -Action { Write-ReviewerStageArtifact -Path (Join-Path $mapDir 'bad.json') -Kind 'fixture.stage.map' -Depth 8 -Form compact -Payload ([ordered]@{ m = @('a') }) } `
        -Expect 'unusable map field'
    Assert-Throws -Name 'write/rejects-scalar-in-declared-map' `
        -Action { Write-ReviewerStageArtifact -Path (Join-Path $mapDir 'bad2.json') -Kind 'fixture.stage.map' -Depth 8 -Form compact -Payload ([ordered]@{ m = 'a' }) } `
        -Expect 'unusable map field'

    $collapsedMapEnvelope = ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
            envelopeVersion = 1
            kind = 'fixture.stage.map'
            contractVersion = 1
            form = 'compact'
            depth = 8
            payload = [ordered]@{ m = @('a') }
        })
    $collapsedMapPath = Join-Path $mapDir 'collapsed.json'
    [IO.File]::WriteAllText($collapsedMapPath, $collapsedMapEnvelope + "`n", (New-Object Text.UTF8Encoding $false))
    Assert-Throws -Name 'read/rejects-array-in-declared-map' `
        -Action { Read-ReviewerStageArtifact -Path $collapsedMapPath -Kind 'fixture.stage.map' } `
        -Expect 'lost map shape'

    # ------------------------------------------------------------------
    # Canonical key order is ordinal and type-independent.
    #
    # Sorting with Sort-Object -CaseSensitive is culture-AWARE: -CaseSensitive
    # changes case handling, not collation, and the default comparer follows the
    # current culture. With keys that are file paths or identifiers, en-US,
    # da-DK and tr-TR each produce a different order, so identical evidence
    # digests differently depending on where it was canonicalized.
    # These keys are deliberately case-distinct: PowerShell dictionaries are
    # case-insensitive, so a fixture with 'aa' and 'AA' would silently collapse
    # and test nothing. 'aa' sorts after 'z' in da-DK, and a hyphen is ignored by
    # cultural collation but is 0x2D ordinally, so each of these separates the
    # ordinal answer from the cultural one.
    $orderingKeys = @('Ab', 'Za', 'aa', 'aa-bb', 'aabb', 'i', 'ig', 'z')
    $orderingSeed = [ordered]@{}
    foreach ($key in $orderingKeys) { $orderingSeed[$key] = $key.Length }

    $cultureOrders = [System.Collections.Generic.List[string]]::new()
    $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($cultureName in @('en-US', 'da-DK', 'tr-TR', 'sv-SE')) {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new($cultureName)
            $ordered = ConvertTo-ReviewerStageDeterministicKeyOrder -Node $orderingSeed
            $cultureOrders.Add((@($ordered.Keys) -join '|'))
        }
    }
    finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
    Assert-True -Name 'canonical/key-order-is-culture-independent' `
        -Condition (@($cultureOrders | Select-Object -Unique).Count -eq 1) `
        -Detail "Four cultures produced these orders: $($cultureOrders -join ' ;; ')"

    $expectedOrder = [string[]]$orderingKeys
    [Array]::Sort($expectedOrder, [StringComparer]::Ordinal)
    Assert-True -Name 'canonical/key-order-is-ordinal' `
        -Condition ($cultureOrders[0] -ceq ($expectedOrder -join '|')) `
        -Detail "Ordered as '$($cultureOrders[0])' rather than '$($expectedOrder -join '|')'."

    # A JSON object has no order to preserve, so wire identity must not depend on
    # which PowerShell type the producer happened to build it with.
    $asHashtable = @{}
    foreach ($key in $orderingKeys) { $asHashtable[$key] = $key.Length }
    $asCustomObject = [pscustomobject]$orderingSeed
    $shapes = @(
        (ConvertTo-ReviewerStageDeterministicKeyOrder -Node $orderingSeed),
        (ConvertTo-ReviewerStageDeterministicKeyOrder -Node $asHashtable),
        (ConvertTo-ReviewerStageDeterministicKeyOrder -Node $asCustomObject)
    )
    $shapeTexts = @($shapes | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 8 -Compress })
    Assert-True -Name 'canonical/key-order-is-type-independent' `
        -Condition (@($shapeTexts | Select-Object -Unique).Count -eq 1) `
        -Detail "Ordered dictionary, hashtable and PSCustomObject serialized as: $($shapeTexts -join ' ;; ')"
}
finally {
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Set-ItemProperty -LiteralPath $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Clear-ReviewerStageContractRegistry
}

$report = [ordered]@{
    check = 'reviewer-stage-contract'
    total = $script:Checks.Count
    passed = @($script:Checks | Where-Object { $_.passed }).Count
    failed = $script:Failures.Count
}
if (-not $Quiet) {
    ConvertTo-Json -InputObject $report -Depth 4 -Compress | Write-Host
}

if ($script:Failures.Count -gt 0) {
    throw "Stage contract enforcement failed $($script:Failures.Count) check(s):`n - $($script:Failures -join "`n - ")"
}

Write-Host "PASS: stage contract enforcement ($($report.passed) checks)."

