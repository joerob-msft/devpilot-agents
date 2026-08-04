#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param([switch]$UpdateSnapshot)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\ConventionPacks.ps1")

$failures = New-Object System.Collections.Generic.List[string]
function Assert-ConventionTest {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
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
    @{ Glob = "src/**/*.cs"; Path = "SRC/Api/Handler.CS"; Expect = $true },
    @{ Glob = "**/*.cs"; Path = "Root.cs"; Expect = $true },
    @{ Glob = "src/**/x.cs"; Path = "src/x.cs"; Expect = $true },
    @{ Glob = "src/*.cs"; Path = "src/Api/x.cs"; Expect = $false },
    @{ Glob = "docs/?.md"; Path = "docs/a.md"; Expect = $true }
)
foreach ($case in $globCases) {
    Assert-ConventionTest ((Test-ReviewerConventionGlobMatch -Glob $case.Glob -Path $case.Path) -eq $case.Expect) `
        "Glob '$($case.Glob)' produced the wrong result for '$($case.Path)'."
}
foreach ($unsafeGlob in @("**", "/src/**/*.cs", "src\**\*.cs", "src/**foo.cs", "src/[ab].cs", "src/{a,b}.cs", "src/**/**/a.cs", "src/../a.cs")) {
    Assert-ConventionTest (-not (Test-ReviewerConventionGlob -Glob $unsafeGlob)) "Unsupported glob '$unsafeGlob' was accepted."
}

$renameResponse = @{ changes = @{ value = @(
            @{ item = @{ path = "/src/New.cs" }; sourceServerItem = "/docs/Old.md"; changeType = "edit, Rename" }
        ) } }
$renameEntries = @(ConvertTo-ReviewerConventionChangeSet -Response $renameResponse)
Assert-ConventionTest ($renameEntries.Count -eq 2) "Rename extraction did not retain both old and new paths."
Assert-ConventionTest (@($renameEntries | Where-Object { $_.Role -eq "previous" -and $_.Path -ceq "docs/Old.md" }).Count -eq 1) `
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

$generatedEntries = ConvertTo-ReviewerConventionChangeSet -Response (ConvertTo-TestChangeResponse -Paths @("/src/Api/Generated/Client.g.cs"))
$generatedSelection = Select-ReviewerConventionPacks -Policy $profilePolicy -ChangeEntries $generatedEntries
$generatedNames = @($generatedSelection.Selected | ForEach-Object { $_.Pack.Name })
Assert-ConventionTest (($generatedNames -join "|") -ceq "csharp-core|generated-code-and-packages") `
    "Generated files were globally hidden or selected by an implicit heuristic."

$raw = New-TestRawPolicy
$policy = ConvertTo-ReviewerConventionPackPolicy -RawPolicy $raw `
    -AuthoritativeSourcePolicy (ConvertTo-TestSourcePolicy -RawSources $raw.authoritativeSources)
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
$exactPackBytes = [int]$plan.selectedPacks[0].contextBytes
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

if ($failures.Count -gt 0) {
    Write-Host "FAIL - $($failures.Count) convention-pack test(s):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "PASS - convention-pack schema, matching, provenance plans, replay, and exact caps." -ForegroundColor Green
