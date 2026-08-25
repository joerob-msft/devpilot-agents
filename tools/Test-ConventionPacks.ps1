#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param([switch]$UpdateSnapshot)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\ConventionPacks.ps1")
$reviewerWrapperPath = Join-Path $repoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"
$reviewerWrapperText = Get-Content -LiteralPath $reviewerWrapperPath -Raw
if ($reviewerWrapperText -match 'return\s+,\s*\$snapshots\.ToArray\(\)') {
    throw "Convention snapshot collectors return nested arrays instead of flat source records."
}

$failures = New-Object System.Collections.Generic.List[string]
function Assert-ConventionTest {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
}
$worstCaseSnapshot = @{
    SourceId = "selected-source"; TrustTier = "pinned-external"; Organization = "contoso"
    Project = "Example"; RepositoryId = "11111111-2222-3333-4444-555555555555"
    Path = "/rules/selected.md"; Ref = "refs/heads/main"; CommitSha = ("a" * 40)
    Sha256 = ("b" * 64); MimeType = "text/markdown"; ByteLength = 16
}
function Assert-ConventionThrows {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-ConventionTest -Condition $threw -Message $Message
}
function Copy-ConventionObject {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
}
function ConvertTo-TestSourcePolicy {
    param([Parameter(Mandatory)]$RawSources)
    return @{
        TransportVersion = [int]$RawSources.transportVersion
        MaxTotalBytes    = [int]$RawSources.maxTotalBytes
        Sources          = @($RawSources.sources | ForEach-Object {
                @{
                    Name = [string]$_.name; Organization = [string]$_.organization
                    Project = [string]$_.project; RepositoryId = ([string]$_.repositoryId).ToLowerInvariant()
                    Path = [string]$_.path; Branch = [string]$_.branch; MaxBytes = [int]$_.maxBytes
                    Section = $(if ($_.PSObject.Properties['section']) { [string]$_.section } else { "" })
                    ExpectedSha256 = ""; ExpectedByteLength = 0
                }
            })
    }
}
function New-TestRawPolicy {
    return (@'
{
  "schemaVersion": 1,
  "requireAllSourcesReferenced": false,
  "authoritativeSources": {
    "transportVersion": 1,
    "maxTotalBytes": 32,
    "sources": [
      {
        "name": "selected-source",
        "organization": "contoso",
        "project": "Example",
        "repositoryId": "11111111-2222-3333-4444-555555555555",
        "path": "/rules/selected.md",
        "branch": "main",
        "maxBytes": 16
      },
      {
        "name": "unrelated-source",
        "organization": "contoso",
        "project": "Example",
        "repositoryId": "11111111-2222-3333-4444-555555555555",
        "path": "/rules/unrelated.md",
        "branch": "main",
        "maxBytes": 16
      }
    ]
  },
  "packs": [
    {
      "name": "selected-pack",
      "priority": 100,
      "changedPathGlobs": [ "src/**/*.cs" ],
      "authoritativeSourceRefs": [ "selected-source" ],
      "repositorySources": [],
      "maxBytes": 4096
    }
  ]
}
'@ | ConvertFrom-Json)
}
function ConvertTo-TestChangeResponse {
    param([string[]]$Paths)
    return @{ changeEntries = @($Paths | ForEach-Object {
                @{ item = @{ path = $_; isFolder = $false }; changeType = "edit" }
            }) }
}

$profilePath = Join-Path $repoRoot "samples\azureux-bpm-convention-packs.preview.json"
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$rawProfilePolicy = $profile.repoConventions.conventionPacks
$profilePolicy = ConvertTo-ReviewerConventionPackPolicy -RawPolicy $rawProfilePolicy `
    -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $rawProfilePolicy.authoritativeSources)
Assert-ConventionTest ($profile.previewOnly -eq $true) "The BPM fixture is not explicitly preview-only."
Assert-ConventionTest (@($profilePolicy.Packs).Count -eq 8) "The BPM fixture did not parse to exactly eight packs."

foreach ($replay in @($profile.replays)) {
    $entries = ConvertTo-ReviewerConventionChangeSet -Response (ConvertTo-TestChangeResponse -Paths @($replay.changedPaths))
    $selection = Select-ReviewerConventionPacks -Policy $profilePolicy -ChangeEntries $entries
    $actual = @($selection.Selected | ForEach-Object { $_.Pack.Name })
    $expected = @($replay.expectedPacks)
    Assert-ConventionTest (($actual -join "|") -ceq ($expected -join "|")) `
        "Replay '$($replay.name)' selected '$($actual -join ", ")'; expected '$($expected -join ", ")'."
    Assert-ConventionTest ($actual.Count -ge 1 -and $actual.Count -le 3) `
        "Replay '$($replay.name)' selected $($actual.Count) packs; the fixture should demonstrate the typical 1-3."
}

$pathCases = @(
    @{ Path = "/src/Api/Handler.cs"; Expect = "src/Api/Handler.cs" },
    @{ Path = "\src\Api\Handler.cs"; Expect = "src/Api/Handler.cs" },
    @{ Path = "src/Api/Handler.cs"; Expect = "src/Api/Handler.cs" }
)
foreach ($case in $pathCases) {
    $actual = ConvertTo-ReviewerConventionRelativePath -Path $case.Path
    Assert-ConventionTest ($actual -ceq $case.Expect) "Path '$($case.Path)' normalized to '$actual'."
}
foreach ($unsafePath in @("C:\repo\src\a.cs", "\\server\share\a.cs", "/src/../secret.md", "/src//a.cs")) {
    Assert-ConventionThrows { ConvertTo-ReviewerConventionRelativePath -Path $unsafePath } `
        "Unsafe changed path '$unsafePath' was accepted."
}

$globCases = @(
    @{ Glob = "src/**/*.cs"; Path = "/src/a.cs"; Expect = $true },
    @{ Glob = "src/**/*.cs"; Path = "src/a.cs"; Expect = $true },
    @{ Glob = "src/**/*.cs"; Path = "\src\Api\Handler.cs"; Expect = $true },
    @{ Glob = "src/**/*.cs"; Path = "/SRC/Api/Handler.CS"; Expect = $true },
    @{ Glob = "src/flow/Tests/**/*.cs"; Path = "/src/flow/Tests/Tests.Flow.Web/EdifactEncodeTests.cs"; Expect = $true },
    @{ Glob = "**/*.cs"; Path = "/Root.cs"; Expect = $true },
    @{ Glob = "src/**/x.cs"; Path = "src/x.cs"; Expect = $true },
    @{ Glob = "src/*.cs"; Path = "src/Api/x.cs"; Expect = $false },
    @{ Glob = "docs/?.md"; Path = "docs/a.md"; Expect = $true },
    @{ Glob = "src/flow/Tests/**/*.cs"; Path = "/src/a.cs"; Expect = $false },
    @{ Glob = "src/**/*.cs"; Path = "/other/a.cs"; Expect = $false },
    @{ Glob = "src/**/*.cs"; Path = "/src//a.cs"; Expect = $false },
    @{ Glob = "src/**/*.cs"; Path = "/src/./a.cs"; Expect = $false },
    @{ Glob = "src/**/*.cs"; Path = "/src/../a.cs"; Expect = $false },
    @{ Glob = "src/**/*.cs"; Path = "/$([char]0x017f)rc/a.cs"; Expect = $false },
    @{ Glob = "src"; Path = "/src"; Expect = $true },
    @{ Glob = "src"; Path = "/src/x"; Expect = $false },
    @{ Glob = "src"; Path = "/src2"; Expect = $false },
    @{ Glob = "*"; Path = ("a" * $script:ReviewerConventionMaxPathLength); Expect = $false }
)
foreach ($case in $globCases) {
    Assert-ConventionTest ((Test-ReviewerConventionGlobMatch -Glob $case.Glob -Path $case.Path) -eq $case.Expect) `
        "Glob '$($case.Glob)' produced the wrong result for '$($case.Path)'."
}
Assert-ConventionTest (-not (Test-ReviewerConventionNormalizedGlobMatch -Glob "src/**/*.cs" -Path "/src/a.cs")) `
    "Sabotage failed: the raw, unnormalized anchored path unexpectedly matched."
foreach ($unsafeGlob in @("**", "/src/**/*.cs", "src\**\*.cs", "src/**foo.cs", "src/[ab].cs", "src/{a,b}.cs", "src/**/**/a.cs", "src/../a.cs")) {
    Assert-ConventionTest (-not (Test-ReviewerConventionGlob -Glob $unsafeGlob)) "Unsupported glob '$unsafeGlob' was accepted."
}

$exactPathRaw = New-TestRawPolicy
$exactPathRaw.packs[0].changedPathGlobs = @("src")
$exactPathPolicy = ConvertTo-ReviewerConventionPackPolicy -RawPolicy $exactPathRaw `
    -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $exactPathRaw.authoritativeSources)
$exactPathEntries = @(ConvertTo-ReviewerConventionChangeSet -Response (ConvertTo-TestChangeResponse -Paths @("/src")))
$exactPathSelection = Select-ReviewerConventionPacks -Policy $exactPathPolicy -ChangeEntries $exactPathEntries
Assert-ConventionTest ($exactPathEntries.Count -eq 1 -and $exactPathEntries[0].Path -ceq "/src") `
    "The exact /src change did not retain its canonical anchor."
Assert-ConventionTest ($exactPathSelection.Selected.Count -eq 1 -and
    $exactPathSelection.Selected[0].Matches.Count -eq 1 -and
    $exactPathSelection.Selected[0].Matches[0].path -ceq "/src") `
    "The exact src glob did not preserve /src routing evidence."

$maximumAnchoredPath = "/" + ("a" * ($script:ReviewerConventionMaxPathLength - 1))
$maximumAnchoredEntries = @(ConvertTo-ReviewerConventionChangeSet -Response (
        ConvertTo-TestChangeResponse -Paths @($maximumAnchoredPath)))
Assert-ConventionTest ($maximumAnchoredEntries.Count -eq 1 -and
    $maximumAnchoredEntries[0].Path.Length -eq $script:ReviewerConventionMaxPathLength) `
    "A maximum-length canonical anchored path was rejected."
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionChangeSet -Response (
        ConvertTo-TestChangeResponse -Paths @((
                "a" * $script:ReviewerConventionMaxPathLength))) | Out-Null
} "A relative path that exceeds the canonical anchored limit was accepted."

$realGate5Response = [pscustomobject]@{
    iterationId = 5
    nextSkip = 10
    nextTop = 1000
    changes = @(
        @{ changeId = 1; changeType = "Edit"; item = @{ path = "/src/flow/Roles/Flow.Integration/Engines/EdifactMessageEncodingEngine.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 2; changeType = "Edit"; item = @{ path = "/src/flow/Tests/Tests.Flow.Web/EdifactEncodeTests.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 3; changeType = "Edit"; item = @{ path = "/.config/.inc/versions.xml"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 4; changeType = "Edit"; item = @{ path = "/src/flow/Roles/Flow.Data.Edge/Providers/BuiltInApiOperationsDataProvider.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 5; changeType = "Edit"; item = @{ path = "/src/flow/Roles/Flow.Integration/Operations/Edifact/EdifactBatchEncodeActionInput.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 6; changeType = "Edit"; item = @{ path = "/src/flow/Roles/Flow.Integration/Operations/Edifact/EdifactEncodeActionInput.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 7; changeType = "Edit"; item = @{ path = "/src/flow/Roles/Flow.Web.Edge/Engines/EdgeFlowDefinitionValidationEngine.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 8; changeType = "Edit"; item = @{ path = "/src/flow/Roles/Flow.Worker.Common/Jobs/Actions/EdifactBatchEncodeActionJob.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 9; changeType = "Edit"; item = @{ path = "/src/flow/Roles/Flow.Worker.Common/Jobs/Actions/EdifactEncodeActionJob.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} },
        @{ changeId = 10; changeType = "Edit"; item = @{ path = "/src/flow/Tests/Tests.Flow.Web/EdifactBatchEncodeTests.cs"; isFolder = $false; gitObjectType = "blob" }; diff = @{} }
    )
}
$realGate5Raw = New-TestRawPolicy
$realGate5Raw.packs[0].name = "csharp-localization"
$realGate5Raw.packs[0].changedPathGlobs = @("src/**/*.cs", "src/flow/Tests/**/*.cs")
$realGate5Policy = ConvertTo-ReviewerConventionPackPolicy -RawPolicy $realGate5Raw `
    -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $realGate5Raw.authoritativeSources)
$realGate5Entries = @(ConvertTo-ReviewerConventionChangeSet -Response $realGate5Response)
$realGate5Selection = Select-ReviewerConventionPacks -Policy $realGate5Policy -ChangeEntries $realGate5Entries
Assert-ConventionTest ((@($realGate5Selection.Selected.Pack.Name) -join "|") -ceq "csharp-localization") `
    "The exact PR16833498 change-response shape did not select the C# localization pack."
Assert-ConventionTest ($realGate5Entries.Count -eq 10 -and
    @($realGate5Entries | Where-Object { -not $_.Path.StartsWith("/", [StringComparison]::Ordinal) }).Count -eq 0) `
    "The exact PR16833498 paths were not retained as canonical anchored paths."
Assert-ConventionTest (@($realGate5Selection.Selected[0].Matches | Where-Object {
            $_.path -ceq "/src/flow/Tests/Tests.Flow.Web/EdifactEncodeTests.cs" -and
            (@($_.globs) -join "|") -ceq "src/**/*.cs|src/flow/Tests/**/*.cs"
        }).Count -eq 1) `
    "The nested test path did not retain its anchored evidence or both intended matching globs."
Assert-ConventionTest (@($realGate5Selection.Selected[0].Matches | Where-Object {
            $_.path -ceq "/.config/.inc/versions.xml"
        }).Count -eq 0) `
    "Convention routing widened beyond the intended C# globs."

$renameResponse = @{ changes = @{ value = @(
            @{ item = @{ path = "/src/New.cs" }; sourceServerItem = "/docs/Old.md"; changeType = "edit, Rename" }
        ) } }
$renameEntries = @(ConvertTo-ReviewerConventionChangeSet -Response $renameResponse)
Assert-ConventionTest ($renameEntries.Count -eq 2) "Rename extraction did not retain both old and new paths."
Assert-ConventionTest (@($renameEntries | Where-Object { $_.Role -eq "previous" -and $_.Path -ceq "/docs/Old.md" }).Count -eq 1) `
    "Rename extraction lost the previous path."
$deleteEntries = @(ConvertTo-ReviewerConventionChangeSet -Response @{
        changeEntries = @(@{ item = @{ path = "/deployment/old.json" }; changeType = 16 })
    })
Assert-ConventionTest ($deleteEntries.Count -eq 1 -and $deleteEntries[0].Role -ceq "deleted") `
    "Integer delete changeType was not normalized to a deleted path."
$folderEntries = @(ConvertTo-ReviewerConventionChangeSet -Response @{
        changeEntries = @(@{ item = @{ path = "/src"; isFolder = $true }; changeType = "edit" })
    })
Assert-ConventionTest ($folderEntries.Count -eq 0) "Folder changes were treated as matchable files."
Assert-ConventionTest (Test-ReviewerConventionCommitEqual -Left ("A" * 40) -Right ("a" * 40)) `
    "Equivalent source commits with different hex casing were treated as movement."
$environmentProbe = New-ReviewerConventionEnvironmentException -Operation "probe" `
    -InnerException ([System.TimeoutException]::new("timed out"))
Assert-ConventionTest (Test-ReviewerConventionEnvironmentException -Exception $environmentProbe) `
    "A tagged convention transport fault was not classified as an environment fault."
Assert-ConventionTest (-not (Test-ReviewerConventionEnvironmentException -Exception ([InvalidOperationException]::new("cap overflow")))) `
    "An untagged deterministic convention failure was classified as an environment fault."

$renameCeilingProbe = @{ changeEntries = @(
        1..500 | ForEach-Object {
            @{ item = @{ path = "/src/new$_.cs" }; sourceServerItem = "/src/old$_.cs"; changeType = "rename" }
        }
    ) }
Assert-ConventionTest (-not (Test-ReviewerConventionResponseTruncated -Response $renameCeilingProbe -Limit 1000)) `
    "Five hundred renames were mistaken for one thousand transport entries."
Assert-ConventionTest (@(ConvertTo-ReviewerConventionChangeSet -Response $renameCeilingProbe).Count -eq 1000) `
    "The rename truncation regression fixture no longer expands to two normalized records per entry."
$transportCeilingProbe = @{ changeEntries = @(
        1..1000 | ForEach-Object {
            @{ item = @{ path = "/src/item$_"; isFolder = ($_ -le 5) }; changeType = "edit" }
        }
    ) }
Assert-ConventionTest (Test-ReviewerConventionResponseTruncated -Response $transportCeilingProbe -Limit 1000) `
    "A transport response at the 1000-entry ceiling escaped truncation detection."
Assert-ConventionTest (@(ConvertTo-ReviewerConventionChangeSet -Response $transportCeilingProbe).Count -eq 995) `
    "The truncation regression fixture no longer proves raw-entry counting is required."
foreach ($unknownResponse in @(
        @{ unexpectedEnvelope = @() },
        @{ count = 0; value = @() }
    )) {
    $unknownEntries = @(ConvertTo-ReviewerConventionChangeSet -Response $unknownResponse)
    Assert-ConventionThrows {
        Assert-ReviewerConventionChangeSetKnown -Entries $unknownEntries -Where "test change set"
    } "An unknown or empty change-set response was treated as a ready no-match plan."
}
try {
    Assert-ReviewerConventionChangeSetKnown -Entries $renameEntries -Where "rename test"
    Assert-ReviewerConventionChangeSetKnown -Entries $deleteEntries -Where "delete test"
}
catch {
    [void]$failures.Add("A legitimate rename or delete change set was rejected as unknown: $($_.Exception.Message)")
}

$generatedEntries = ConvertTo-ReviewerConventionChangeSet -Response (ConvertTo-TestChangeResponse -Paths @("/src/Api/Generated/Client.g.cs"))
$generatedSelection = Select-ReviewerConventionPacks -Policy $profilePolicy -ChangeEntries $generatedEntries
$generatedNames = @($generatedSelection.Selected | ForEach-Object { $_.Pack.Name })
Assert-ConventionTest (($generatedNames -join "|") -ceq "csharp-core|generated-code-and-packages") `
    "Generated files were globally hidden or selected by an implicit heuristic."

$raw = New-TestRawPolicy
$policy = ConvertTo-ReviewerConventionPackPolicy -RawPolicy $raw `
    -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $raw.authoritativeSources)
$requiredPackBytes = [int]$policy.Packs[0].RequiredMaxBytes
$boundaryRaw = Copy-ConventionObject $raw
$boundaryRaw.packs[0].maxBytes = $requiredPackBytes
$boundaryPolicy = ConvertTo-ReviewerConventionPackPolicy -RawPolicy $boundaryRaw `
    -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $boundaryRaw.authoritativeSources)
Assert-ConventionTest ($boundaryPolicy.Packs[0].RequiredMaxBytes -eq $requiredPackBytes) `
    "The exact startup pack-cap boundary was not accepted."
$underBoundaryRaw = Copy-ConventionObject $boundaryRaw
$underBoundaryRaw.packs[0].maxBytes = $requiredPackBytes - 1
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $underBoundaryRaw `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $underBoundaryRaw.authoritativeSources)
} "A pack cap one byte below worst-case source content and provenance was accepted at startup."
$entries = ConvertTo-ReviewerConventionChangeSet -Response (ConvertTo-TestChangeResponse -Paths @("/SRC/Api/Handler.cs"))
$selection = Select-ReviewerConventionPacks -Policy $policy -ChangeEntries $entries
$requests = Get-ReviewerConventionSourceRequests -Selection $selection
Assert-ConventionTest (($requests.AuthoritativeSourceNames -join "|") -ceq "selected-source") `
    "An unrelated authoritative source was requested."

$negative = Copy-ConventionObject $raw
$negative.packs[0].authoritativeSourceRefs[0] = "not-configured"
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $negative `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $negative.authoritativeSources)
} "An unknown authoritative source reference was accepted."

$negative = Copy-ConventionObject $raw
$duplicatePack = Copy-ConventionObject $negative.packs[0]
$negative.packs = @($negative.packs[0], $duplicatePack)
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $negative `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $negative.authoritativeSources)
} "A duplicate pack name was accepted."

$negative = Copy-ConventionObject $raw
$duplicateDefinition = Copy-ConventionObject $negative.packs[0]
$duplicateDefinition.name = "same-definition"
$duplicateDefinition.priority = 101
$negative.packs = @($negative.packs[0], $duplicateDefinition)
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $negative `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $negative.authoritativeSources)
} "An ambiguous duplicate pack definition was accepted."

$negative = Copy-ConventionObject $raw
$negative.requireAllSourcesReferenced = $true
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $negative `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $negative.authoritativeSources)
} "A configured zero-use authoritative source was accepted."

$negative = Copy-ConventionObject $raw
$negative.packs[0].maxBytes = 1
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $negative `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $negative.authoritativeSources)
} "A pack cap too small for required provenance was accepted."

$negative = Copy-ConventionObject $raw
$negative.packs = @()
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $negative `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $negative.authoritativeSources)
} "An empty convention pack list was accepted."

$negative = Copy-ConventionObject $raw
$negative.packs[0].authoritativeSourceRefs = @()
$negative.packs[0].repositorySources = @(@{ path = "/docs/shared.md"; maxBytes = 512 })
$negative.packs[0].maxBytes = 4096
$conflictingLocal = Copy-ConventionObject $negative.packs[0]
$conflictingLocal.name = "conflicting-local-cap"
$conflictingLocal.changedPathGlobs = @("test/**/*.cs")
$conflictingLocal.repositorySources[0].maxBytes = 1024
$negative.packs = @($negative.packs[0], $conflictingLocal)
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $negative `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $negative.authoritativeSources)
} "Conflicting cross-pack maxBytes for one repository source was deferred to runtime."

$orderingRaw = Copy-ConventionObject $raw
$second = Copy-ConventionObject $orderingRaw.packs[0]
$orderingRaw.packs[0].name = "z-pack"
$orderingRaw.packs[0].changedPathGlobs = @("src/**/*.cs")
$second.name = "a-pack"
$second.changedPathGlobs = @("test/**/*.cs")
$second.priority = 100
$orderingRaw.packs = @($orderingRaw.packs[0], $second)
$orderingPolicy = ConvertTo-ReviewerConventionPackPolicy -RawPolicy $orderingRaw `
    -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $orderingRaw.authoritativeSources)
Assert-ConventionTest ((@($orderingPolicy.Packs | ForEach-Object { $_.Name }) -join "|") -ceq "a-pack|z-pack") `
    "Equal-priority packs were not ordered by exact name."

$originalCulture = [System.Globalization.CultureInfo]::CurrentCulture
try {
    $cultureResponse = ConvertTo-TestChangeResponse -Paths @(
        "/src/a-b.cs", "/src/aa.cs", "/src/ab.cs", "/src/zz.cs"
    )
    [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("en-US")
    $enEntries = @(ConvertTo-ReviewerConventionChangeSet -Response $cultureResponse)
    $enDigest = Get-ReviewerConventionChangeSetDigest -Entries $enEntries
    $enOrder = @($enEntries | ForEach-Object { $_.Path }) -join "|"
    $enPackOrder = @((ConvertTo-ReviewerConventionPackPolicy -RawPolicy $orderingRaw `
                -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $orderingRaw.authoritativeSources)).Packs |
            ForEach-Object { $_.Name }) -join "|"
    [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("da-DK")
    $daEntries = @(ConvertTo-ReviewerConventionChangeSet -Response $cultureResponse)
    $daDigest = Get-ReviewerConventionChangeSetDigest -Entries $daEntries
    $daOrder = @($daEntries | ForEach-Object { $_.Path }) -join "|"
    $daPackOrder = @((ConvertTo-ReviewerConventionPackPolicy -RawPolicy $orderingRaw `
                -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $orderingRaw.authoritativeSources)).Packs |
            ForEach-Object { $_.Name }) -join "|"
    Assert-ConventionTest ($enOrder -ceq $daOrder -and $enDigest -ceq $daDigest -and $enPackOrder -ceq $daPackOrder) `
        "Change-set or pack ordering depends on the current culture."
}
finally {
    [System.Globalization.CultureInfo]::CurrentCulture = $originalCulture
}

$snapshot = @{
    SourceId = "selected-source"; TrustTier = "pinned-external"; Organization = "contoso"
    Project = "Example"; RepositoryId = "11111111-2222-3333-4444-555555555555"
    Path = "/rules/selected.md"; Ref = "refs/heads/main"; CommitSha = ("a" * 40)
    Sha256 = ("b" * 64); MimeType = "text/markdown"; ByteLength = 7
}
$binding = @{
    Organization = "contoso"; Project = "Example"; RepositoryId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    PullRequestId = 42; SourceCommit = ("c" * 40); TargetCommit = ("d" * 40)
    ChangeSetDigest = Get-ReviewerConventionChangeSetDigest -Entries $entries
}
$plan = New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
    -AuthoritativeSnapshots @($snapshot) -RepositorySnapshots @() `
    -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64)
$boundarySelection = Select-ReviewerConventionPacks -Policy $boundaryPolicy -ChangeEntries $entries
$worstCasePlan = New-ReviewerConventionContextPlan -Policy $boundaryPolicy -Selection $boundarySelection -Binding $binding `
    -AuthoritativeSnapshots @($worstCaseSnapshot) -RepositorySnapshots @() `
    -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64)
Assert-ConventionTest ($worstCasePlan.selectedPacks[0].contextBytes -eq $requiredPackBytes) `
    "Startup pack-cap feasibility did not equal runtime bytes at declared source maxima and longest MIME."
Assert-ConventionTest ($worstCaseSnapshot.CommitSha.Length -eq 40 -and $worstCaseSnapshot.Sha256.Length -eq 64) `
    "Worst-case provenance width assumptions changed without updating startup feasibility."
$exactPackBytes = [int]$plan.selectedPacks[0].contextBytes
$manyEntries = ConvertTo-ReviewerConventionChangeSet -Response (ConvertTo-TestChangeResponse -Paths @(
        1..100 | ForEach-Object { "/src/Feature$_.cs" }
    ))
$manySelection = Select-ReviewerConventionPacks -Policy $policy -ChangeEntries $manyEntries
$manyPlan = New-ReviewerConventionContextPlan -Policy $policy -Selection $manySelection -Binding $binding `
    -AuthoritativeSnapshots @($snapshot) -RepositorySnapshots @() `
    -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64)
Assert-ConventionTest ($manyPlan.selectedPacks[0].contextBytes -eq $exactPackBytes) `
    "Matched-path evidence incorrectly consumed source convention context bytes."
Assert-ConventionTest ($manyPlan.selectedPacks[0].routingEvidenceBytes -gt $plan.selectedPacks[0].routingEvidenceBytes) `
    "Routing evidence growth was not reported separately from convention context."
$policy.Packs[0].MaxBytes = $exactPackBytes
[void](New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
        -AuthoritativeSnapshots @($snapshot) -RepositorySnapshots @() `
        -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64))
$policy.Packs[0].MaxBytes = $exactPackBytes - 1
Assert-ConventionThrows {
    New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
        -AuthoritativeSnapshots @($snapshot) -RepositorySnapshots @() `
        -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64)
} "A one-byte per-pack context overflow was accepted."
$policy.Packs[0].MaxBytes = $exactPackBytes
$policy.MaxTotalBytes = $exactPackBytes
[void](New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
        -AuthoritativeSnapshots @($snapshot) -RepositorySnapshots @() `
        -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64))
$policy.MaxTotalBytes = $exactPackBytes - 1
Assert-ConventionThrows {
    New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
        -AuthoritativeSnapshots @($snapshot) -RepositorySnapshots @() `
        -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64)
} "A one-byte total context overflow was accepted."

# ---------------------------------------------------------------------------
# Offline-replay convention-source degrade.
#
# When the immutable corpus never captured an authoritative/repository source
# (a legitimate offline condition, not a hostile one), the planner must withhold
# only that pack at candidate level and flag the plan evidence-degraded, instead
# of throwing - which would abort the whole cycle, taking functional generalist
# discovery down with it. The plan must stay structurally "ready" (a usable,
# digest-bound object) and keep an exact target commit and change-set digest so
# reciprocal cross-verification still runs for the functional candidates.
# ---------------------------------------------------------------------------
$policy.Packs[0].MaxBytes = $exactPackBytes
$policy.MaxTotalBytes = $exactPackBytes

# Default (live) behavior is unchanged: a selected pack whose source did not
# resolve is a hard configuration/transport error.
Assert-ConventionThrows {
    New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
        -AuthoritativeSnapshots @() -RepositorySnapshots @() `
        -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64)
} "A missing convention source was accepted without -AllowDegradedSources."

$degradedPlan = New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
    -AuthoritativeSnapshots @() -RepositorySnapshots @() `
    -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64) -AllowDegradedSources
Assert-ConventionTest ([string]$degradedPlan.status -ceq "ready") `
    "A degraded convention plan must remain structurally ready."
Assert-ConventionTest ([bool]$degradedPlan.evidenceDegraded -and [string]$degradedPlan.evidenceStatus -ceq "degraded") `
    "A withheld-source plan must report evidenceStatus=degraded."
Assert-ConventionTest (@($degradedPlan.selectedPacks).Count -eq 0) `
    "A pack whose only source is unavailable must not be selected."
Assert-ConventionTest (@($degradedPlan.withheldPacks | Where-Object {
            [string]$_.reason -ceq "authoritative-source-unavailable" -and [bool]$_.degraded -eq $true
        }).Count -ge 1) `
    "A degraded pack must be withheld with a typed authoritative-source-unavailable reason."
Assert-ConventionTest ([string]$degradedPlan.targetCommit -ceq [string]$binding.TargetCommit -and
    [string]$degradedPlan.changeSetDigest -ceq [string]$binding.ChangeSetDigest) `
    "A degraded plan must still carry the exact sealed target commit and change-set digest."
Assert-ConventionTest ([string]$degradedPlan.degradedReason -match "unavailable") `
    "A degraded plan must name why its evidence is incomplete."

# With the same switch on and the source PRESENT, the plan is not degraded and
# selects the pack exactly as the default path would - the switch only changes
# the unavailable-source case, never a fully-evidenced one.
$notDegradedPlan = New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
    -AuthoritativeSnapshots @($snapshot) -RepositorySnapshots @() `
    -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64) -AllowDegradedSources
Assert-ConventionTest (-not [bool]$notDegradedPlan.evidenceDegraded -and
    [string]$notDegradedPlan.evidenceStatus -ceq "complete" -and
    @($notDegradedPlan.selectedPacks).Count -eq 1) `
    "-AllowDegradedSources must not degrade a plan whose sources are all present."

$policy.Packs[0].MaxBytes = $exactPackBytes
$policy.MaxTotalBytes = $exactPackBytes
$plan = New-ReviewerConventionContextPlan -Policy $policy -Selection $selection -Binding $binding `
    -AuthoritativeSnapshots @($snapshot) -RepositorySnapshots @() `
    -ScriptSha256 ("e" * 64) -ConfigSha256 ("f" * 64)
$snapshotPath = Join-Path $repoRoot "src\Agents\reviewer\testdata\convention-plan.snapshot.json"
$snapshotJson = $plan | ConvertTo-Json -Depth 16
if ($UpdateSnapshot) {
    $snapshotDirectory = Split-Path $snapshotPath -Parent
    if (-not (Test-Path -LiteralPath $snapshotDirectory)) { New-Item -ItemType Directory -Path $snapshotDirectory | Out-Null }
    Set-Content -LiteralPath $snapshotPath -Value $snapshotJson -Encoding UTF8
}
elseif (-not (Test-Path -LiteralPath $snapshotPath)) {
    [void]$failures.Add("Convention plan snapshot is missing: $snapshotPath")
}
else {
    $expectedSnapshot = (Get-Content -LiteralPath $snapshotPath -Raw).TrimEnd()
    Assert-ConventionTest ($snapshotJson.TrimEnd() -ceq $expectedSnapshot) "The exact selected convention context plan changed."
}

# ---------------------------------------------------------------------------
# Section identity.
#
# Two rules routinely live in one engineering-guidance document, and naming a
# section is the only way such a document is transportable at all - transporting
# 60 KB whole exceeds any sane pack budget. So "two sections of one document"
# has to be a legal catalog, while "the same section twice" must still be the
# configuration error it always was.
# ---------------------------------------------------------------------------

$sectionRaw = New-TestRawPolicy
$sectionRaw.authoritativeSources.maxTotalBytes = 64
$sectionSourceTemplate = $sectionRaw.authoritativeSources.sources[0]
$sectionRaw.authoritativeSources.sources = @(
    (Copy-ConventionObject -Value $sectionSourceTemplate),
    (Copy-ConventionObject -Value $sectionSourceTemplate)
)
$sectionRaw.authoritativeSources.sources[0].name = "rule-one"
$sectionRaw.authoritativeSources.sources[1].name = "rule-two"
foreach ($sectionSource in $sectionRaw.authoritativeSources.sources) {
    $sectionSource | Add-Member -NotePropertyName 'section' -NotePropertyValue '' -Force
}
$sectionRaw.authoritativeSources.sources[0].section = "### First rule"
$sectionRaw.authoritativeSources.sources[1].section = "### Second rule"
$sectionRaw.packs = @((Copy-ConventionObject -Value $sectionRaw.packs[0]))
$sectionRaw.packs[0].authoritativeSourceRefs = @("rule-one", "rule-two")
$sectionRaw.packs[0].maxBytes = 4096

$sectionPolicy = ConvertTo-ReviewerConventionPackPolicy -RawPolicy $sectionRaw `
    -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $sectionRaw.authoritativeSources)
Assert-ConventionTest (@($sectionPolicy.Packs).Count -eq 1) `
    "Two named sections of the same document are a legal convention catalog."

$sameSectionRaw = Copy-ConventionObject -Value $sectionRaw
$sameSectionRaw.authoritativeSources.sources[1].section = "### First rule"
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $sameSectionRaw `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $sameSectionRaw.authoritativeSources) `
} "The same section of the same document declared twice is still a duplicate."

$wholeFileTwiceRaw = Copy-ConventionObject -Value $sectionRaw
$wholeFileTwiceRaw.authoritativeSources.sources[0].section = ""
$wholeFileTwiceRaw.authoritativeSources.sources[1].section = ""
Assert-ConventionThrows {
    ConvertTo-ReviewerConventionPackPolicy -RawPolicy $wholeFileTwiceRaw `
        -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $wholeFileTwiceRaw.authoritativeSources) `
} "The same whole document declared twice is still a duplicate."

if ($failures.Count -gt 0) {
    Write-Host "FAIL - $($failures.Count) convention-pack test(s):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "PASS - convention-pack schema, matching, provenance plans, replay, and exact caps." -ForegroundColor Green
