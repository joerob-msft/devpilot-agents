#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The reviewed, no-model surface that turns one operator-authorized request into
    one immutable typed cohort-entry evidence package.

.DESCRIPTION
    A Gate5 operator preparing a cohort entry has, until now, assembled the same
    evidence by hand every time: open a session, read the pull request, read the
    repository, read the branch, read the changes, read the files, write a corpus,
    write a recipe, write a request, hash everything, and hope the shapes match
    what the reviewer will ask for when it finally runs. Every step of that is a
    place a defect has actually landed - a byte-order mark on a hand-edited JSON
    file, a repository named by GUID where the read wants its name, a raw provider
    repository object with a flat 'project' string where the wrapper contract wants
    a reduced identity with a nested projectReference, a get_changes variant nobody
    recorded, a configuration bound to a different target branch, a census written
    in the order the filesystem happened to enumerate.

    This file builds that evidence once, in one order, through the reviewed read
    seam, and refuses rather than repairs.

    WHAT IT IS NOT. It launches no model. It opens no writing session and requests
    no write action - the read plan below is a closed list and anything outside it
    is refused before it is issued. It reaches no verdict, carries no severity,
    reads no oracle and produces no expected finding: the request schema forbids
    those fields by name AND by path, and the check is recursive, so an answer key
    can reach this build neither as data nor as a file name.

    WHAT IT PRODUCES. A package a C# ShadowRunCoordinator cohort manifest accepts
    directly, with nothing in between translating it: an identity witness, a
    validated reviewer configuration whose target ref is the exact ref the pull
    request merges into, an ordinal changed-path census with span evidence, corpus
    declarations and the index inputs the typed stager consumes, the pinned rule
    bundle, a typed coordinator request, and the sealed model-start and verifier
    bounds the cohort's budgets are checked against.

    HOW IT FAILS. With an exact code. Every refusal in this file is a member of the
    catalogue below, every code names one condition, and the code is the first
    token of the message, so a caller matches on the code rather than on prose that
    may be reworded. A build that cannot prove something refuses; it never
    downgrades, never substitutes, and never publishes a partial package.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CorpusSeal.ps1')
# The reviewer's own source transport, for its right-hand span extractor. Loaded
# rather than reimplemented: a second reading of 'lineDiffBlocks' written here
# would be exactly the raw-interpretation this builder exists to stop, and it
# would drift from the reviewer's reading the first time a block shape changed.
. (Join-Path $PSScriptRoot 'SourceTransport.ps1')

$script:ReviewerCohortEntryUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

$script:ReviewerCohortEntryRequestKind = 'reviewer-cohort-entry-evidence-request'
$script:ReviewerCohortEntryPackageKind = 'devpilot.shadow-cohort.entry-evidence.v1'
$script:ReviewerCohortEntryCoordinatorContract = 'devpilot.shadow-run-coordinator.request.v2'
# The one kind the shipping cohort runner reads (CohortRunner.ModelStartBoundKind).
# Bumping it here would make an artifact this builder invented loadable, which is
# how a placeholder budget becomes an under-declared one.
$script:ReviewerCohortEntryModelStartBoundKind = 'devpilot.shadow-cohort.model-start-bound.v2'
$script:ReviewerCohortEntryChangedPathsContract = 'devpilot.shadow-run-coordinator.changed-paths.v1'
# One leaf name, spelled the way the shipping reader spells it. The character
# class alone would accept 's1..x': the leading class rules out '.' and '..'
# themselves but not a '..' further in, and SlotAuthorization.RequireLeafName
# refuses ANY value containing '..'. A name this reader accepted and the typed
# reader refused would be a refusal an operator could only discover by running
# the coordinator - against an entry that is by then sealed and read-only.
$script:ReviewerCohortEntryPathComponentPattern = '^(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._-]*$'

<#
    The exact refusal catalogue. Each code names exactly one condition, and a
    condition gains a code rather than sharing one, because an operator acting on
    a refusal has to be able to tell "the request named a field I mistyped" from
    "the pull request moved under me" without reading prose.
#>
$script:ReviewerCohortEntryErrorCatalog = [ordered]@{
    CE100 = 'The request file does not exist.'
    CE101 = 'The request bytes begin with a UTF-8 byte-order mark.'
    CE102 = 'The request is not readable UTF-8 JSON.'
    CE103 = 'The request declares a contract this build does not read.'
    CE104 = 'The request omits a required field.'
    CE105 = 'The request carries a field this contract does not declare.'
    CE106 = 'A request field has the wrong shape, type or range.'
    CE107 = 'The request carries an oracle or expected-decision key.'
    CE108 = 'The request carries an oracle or expected-decision path.'
    CE109 = 'The private output root is inside the toolkit repository.'
    CE110 = 'The rule bundle declares one path twice.'
    CE111 = 'A declared path escapes its own root or is not a plain relative path.'
    CE112 = 'The rule bundle declaration does not match its declared digest.'
    CE200 = 'The toolkit head does not match the repository the request names.'
    CE201 = 'The required ref does not resolve to the pinned toolkit head.'
    CE202 = 'The authoritative repository identity is not the reduced wrapper-contract shape.'
    CE203 = 'The authoritative repository identity is a raw provider shape, not the reduced contract shape.'
    CE204 = 'The authoritative repository identity is for another repository.'
    CE205 = 'The branch resolution is not the exact requested ref and one 40-hex commit.'
    CE206 = 'The pull request does not target the declared target ref.'
    CE207 = 'The pull request is a draft.'
    CE208 = 'The pull request is not active.'
    CE209 = 'The pull request identity drifted between the two identity reads.'
    CE210 = 'The pull request iteration binding is incomplete.'
    CE211 = 'The reviewer configuration target does not equal the declared target ref.'
    CE212 = 'The reviewer configuration repository identity does not equal the subject.'
    CE213 = 'The toolkit working tree carries tracked modifications, so its assets are not the pinned commit.'
    CE300 = 'A planned read was never performed.'
    CE301 = 'A read outside the closed plan was performed.'
    CE302 = 'A response is not the exact resource envelope the plan declares.'
    CE303 = 'A response is a raw provider body rather than a wrapper-contract tool result.'
    CE304 = 'A resource URI does not equal the wrapper-requested URI.'
    CE305 = 'A payload exceeds the declared byte cap.'
    CE306 = 'A payload begins with a UTF-8 byte-order mark.'
    CE307 = 'A replay capture attempted a live fallback.'
    CE308 = 'A write tool or a write action was requested.'
    CE309 = 'The plan records the same read key twice.'
    CE310 = "A rule section's bytes disagree with its pin."
    CE400 = 'The changed-path census is not in its declared ordinal order.'
    CE401 = 'The changed-path census carries a duplicate path.'
    CE402 = 'The changed-file count exceeds the declared cap.'
    CE403 = 'The changed-path content coverage is below the declared floor.'
    CE404 = 'A span is out of range, empty or out of order.'
    CE406 = 'The thread count exceeds the declared cap.'
    CE407 = 'The changed-path census is empty.'
    CE408 = 'The thread list reached the page the reviewer''s own read asks for, so it cannot be proven complete.'
    CE500 = 'The private output root already holds a package.'
    CE501 = 'The atomic publish did not complete.'
    CE502 = 'The published package is not read-only.'
    CE503 = 'The published inventory disagrees with what is on disk.'
    CE504 = 'The seal key is missing or malformed.'
    CE505 = 'A published path is a reparse point.'
    CE506 = 'A published path escapes the output root.'
    CE600 = 'The typed preflight did not reach runSetReady.'
    CE601 = 'The typed preflight consumed a slot, a model or a launch token.'
    CE700 = 'An execution plan was declared at a schema version that does not carry one.'
    CE701 = 'The execution plan does not enable shadow slots.'
    CE702 = 'The execution plan does not declare exactly the two slots slot1 and slot2, in order.'
    CE703 = 'The execution plan reviewer script is missing or disagrees with its pinned digest.'
    CE704 = 'The execution plan names a model the supported-model registry does not carry.'
    CE705 = 'The execution plan generalist pair is not the pair derived from the registry.'
    CE706 = 'The execution plan specialist or verifier disagrees with the reviewer configuration.'
    CE707 = 'The execution plan declares a delivery capability that writes.'
    CE708 = 'The execution plan declares a slot state or terminal name that collides with another.'
    CE709 = 'The execution plan slot count does not equal the declared planned run count.'
    CE710 = 'The execution plan declares a supervision timeout outside the supervised range.'
    CE711 = 'The execution plan names a launch authorization inside the sealed package.'
    CE712 = 'The execution plan does not bound a non-zero finite model start and verifier estimate.'
    CE713 = 'The execution plan reconciliation and delivery outputs are the same directory.'
    CE714 = 'The model start bound could not be derived, or the derived bound does not bind this request.'
    CE715 = 'A runnable execution plan entry has no declared run set and launch authorization to run under.'
    CE716 = 'The execution plan names a launch authorization path; the builder derives that path itself.'
    CE800 = 'A live identity read carries no value for a field the corpus seal binds by name.'
    CE802 = 'A changed path carries right-hand content but no right-hand span.'
    CE803 = 'The pinned toolkit ships no source-transport policy to derive the seal under.'
    CE805 = 'The emitted corpus seal recipe is not acceptable to the shipping sealer.'
    CE806 = 'The corpus seal recipe cites a payload or a change-set path this build did not stage.'
}

function Get-ReviewerCohortEntryErrorCatalog {
    <#
    .SYNOPSIS
        The exact refusal catalogue, as an ordered code-to-condition map.
    #>
    return $script:ReviewerCohortEntryErrorCatalog
}

<#
    The run-set layout the SHIPPING qualification publishes into, stated once.

    'Invoke-ReviewerReplayQualification -Mode Declare' mints the launch token
    inside its publish transaction and renames it into <root>/qualification/
    runset/launch-authorization.token together with the sealed declaration. Every
    consumer here derives that path from these two constants rather than
    restating it, because the whole defect this binding exists to remove was a
    request naming a token path the run set would never publish to.
#>
$script:ReviewerCohortEntryRunSetDirectoryName = 'qualification/runset'
$script:ReviewerCohortEntryLaunchTokenFileName = 'launch-authorization.token'

function Get-ReviewerCohortEntryPreparationRoot {
    <#
    .SYNOPSIS
        The coordinator's output root for a package published at $OutputRoot.

    .DESCRIPTION
        A SIBLING of the package, never inside it: the package is sealed
        read-only the moment it is published and the coordinator writes state,
        audit and a lease every time it runs.

        Derived in exactly one place because two callers need it - the request
        reader, to stamp the launch authorization path into the execution plan
        before anything is hashed, and the builder, to run the coordinator. Two
        derivations would be two answers, and the request would name a token the
        coordinator never publishes.
    #>
    param([Parameter(Mandatory)][string]$OutputRoot)
    return [IO.Path]::GetFullPath(($OutputRoot.TrimEnd('\', '/') + '.preparation'))
}

function Get-ReviewerCohortEntryLaunchAuthorizationPath {
    <#
    .SYNOPSIS
        The one path a launch authorization for this entry can ever be at.

    .DESCRIPTION
        Deliberately NOT an operator input. An operator who could name this path
        could name one the declaration never publishes to, and the resulting
        entry would seal, pass a cohort walk and reach runSetReady before failing
        at the first launch with a token that was never going to be there.
    #>
    param([Parameter(Mandatory)][string]$PreparationOutputRoot)
    $runSetRoot = Join-Path ([IO.Path]::GetFullPath($PreparationOutputRoot)) $script:ReviewerCohortEntryRunSetDirectoryName
    return [IO.Path]::GetFullPath((Join-Path $runSetRoot $script:ReviewerCohortEntryLaunchTokenFileName))
}

function New-ReviewerCohortEntryRefusal {
    <#
    .SYNOPSIS
        Throws one catalogued refusal, code first.

    .DESCRIPTION
        The code is the first token of the message and is validated against the
        catalogue here, so a refusal cannot be raised under a code nobody
        declared and a caller can match on the code rather than on the prose.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Detail
    )
    if (-not $script:ReviewerCohortEntryErrorCatalog.Contains($Code)) {
        throw "CE000 An uncatalogued refusal code '$Code' was raised: $Detail"
    }
    throw "$Code $($script:ReviewerCohortEntryErrorCatalog[$Code]) $Detail"
}

function Get-ReviewerCohortEntryErrorCode {
    <#
    .SYNOPSIS
        The catalogue code a refusal was raised under, or the empty string.
    #>
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Message)
    if ($Message -cmatch '^(CE[0-9]{3})\b') { return [string]$Matches[1] }
    return ''
}

# ---------------------------------------------------------------------------
# Strict request reading
# ---------------------------------------------------------------------------

<#
    Field names that would carry an answer, and path fragments that would name a
    file carrying one. Both lists are matched case-insensitively against every
    key and every string value in the request, recursively, so an oracle cannot
    arrive as data under a benign key or as a benign key naming an oracle file.
#>
$script:ReviewerCohortEntryOracleKeys = [string[]]@(
    'oracle', 'expected', 'expectedfindings', 'expecteddecision', 'expectedverdict',
    'groundtruth', 'truth', 'label', 'labels', 'answer', 'answerkey', 'findings',
    'verdict', 'severity', 'decision', 'adjudication', 'goldset', 'golden'
)

$script:ReviewerCohortEntryOraclePathFragments = [string[]]@(
    'oracle', 'expected', 'ground-truth', 'groundtruth', 'answer-key', 'answerkey',
    'gold', 'label', 'verdict', 'adjudicat', 'finding'
)

function Assert-ReviewerCohortEntryOracleFree {
    <#
    .SYNOPSIS
        Refuses any request that carries an answer, as a key or as a path.

    .DESCRIPTION
        Recursive over objects and arrays. A key is refused when its name
        contains a catalogued oracle token; a string VALUE is refused when it
        looks like a path and contains a catalogued path fragment. Values that
        are not path-shaped are left alone, because a correlation id may
        legitimately contain a word this list also uses.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Node,
        [Parameter(Mandatory)][string]$Path
    )
    if ($null -eq $Node) { return }
    if ($Node -is [string]) {
        $text = [string]$Node
        if ($text.Contains('/') -or $text.Contains('\')) {
            $lowered = $text.ToLowerInvariant()
            foreach ($fragment in $script:ReviewerCohortEntryOraclePathFragments) {
                if ($lowered.Contains($fragment)) {
                    New-ReviewerCohortEntryRefusal -Code 'CE108' `
                        -Detail "At '$Path' the request names '$text', whose path carries the oracle fragment '$fragment'."
                }
            }
        }
        return
    }
    if ($Node -is [bool] -or $Node -is [ValueType]) { return }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $properties = @($Node.PSObject.Properties)
        foreach ($property in $properties) {
            $name = [string]$property.Name
            $lowered = $name.ToLowerInvariant()
            foreach ($token in $script:ReviewerCohortEntryOracleKeys) {
                if ($lowered.Contains($token)) {
                    New-ReviewerCohortEntryRefusal -Code 'CE107' `
                        -Detail "At '$Path' the request declares '$name', which carries the oracle token '$token'."
                }
            }
            Assert-ReviewerCohortEntryOracleFree -Node $property.Value -Path "$Path.$name"
        }
        return
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $index = 0
        foreach ($element in $Node) {
            Assert-ReviewerCohortEntryOracleFree -Node $element -Path "$Path[$index]"
            $index++
        }
    }
}

function Assert-ReviewerCohortEntryExactKeys {
    <#
    .SYNOPSIS
        Requires an object to declare exactly the named fields: none missing,
        none extra.
    #>
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Where,
        [Parameter(Mandatory)][string[]]$Required,
        [string[]]$Optional = [string[]]@()
    )
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The $Where is not a JSON object."
    }
    $present = [string[]]@($Object.PSObject.Properties.Name)
    $missing = [string[]]@($Required | Where-Object { $present -cnotcontains $_ })
    if ($missing.Count -gt 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE104' -Detail "The $Where omits: $($missing -join ', ')."
    }
    $known = [string[]]@($Required + $Optional)
    $unknown = [string[]]@($present | Where-Object { $known -cnotcontains $_ })
    if ($unknown.Count -gt 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE105' -Detail "The $Where declares: $($unknown -join ', ')."
    }
}

function Get-ReviewerCohortEntryString {
    <#
    .SYNOPSIS
        One required string field, shape-checked against a pattern.
    #>
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where,
        [string]$Pattern = '',
        [int]$MaxLength = 1024
    )
    $value = $Object.$Name
    if ($value -isnot [string] -or [string]::IsNullOrEmpty([string]$value)) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The $Where field '$Name' is not a non-empty string."
    }
    $text = [string]$value
    if ($text.Length -gt $MaxLength) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The $Where field '$Name' is $($text.Length) characters, over $MaxLength."
    }
    if ($Pattern -and $text -cnotmatch $Pattern) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The $Where field '$Name' value '$text' does not match $Pattern."
    }
    return $text
}

function Get-ReviewerCohortEntryInt {
    <#
    .SYNOPSIS
        One required integer field, range-checked. A boolean is refused rather
        than coerced, because PowerShell would otherwise read $true as 1.
    #>
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where,
        [Parameter(Mandatory)][int]$Minimum,
        [Parameter(Mandatory)][int]$Maximum
    )
    $value = $Object.$Name
    if ($value -is [bool] -or ($value -isnot [int] -and $value -isnot [long])) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The $Where field '$Name' is not an integer."
    }
    $number = [long]$value
    if ($number -lt $Minimum -or $number -gt $Maximum) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' `
            -Detail "The $Where field '$Name' is $number, outside [$Minimum, $Maximum]."
    }
    return [int]$number
}

function Test-ReviewerCohortEntryPathWithin {
    <#
    .SYNOPSIS
        Whether a candidate path resolves inside a root, compared as full paths
        with a trailing separator so a sibling directory whose name merely
        starts with the root's name is outside it.
    #>
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Root
    )
    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedCandidate = [IO.Path]::GetFullPath($Candidate)
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if ($normalizedCandidate.Equals($normalizedRoot, $comparison)) { return $true }
    return $normalizedCandidate.StartsWith($normalizedRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-ReviewerCohortEntryRepositoryRelativePath {
    <#
    .SYNOPSIS
        Requires a provider path to be a plain, rooted, forward-slash path with
        no traversal, no drive, no UNC prefix and no alternate stream.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Where
    )
    if (-not $Path.StartsWith('/', [StringComparison]::Ordinal)) {
        New-ReviewerCohortEntryRefusal -Code 'CE111' -Detail "The $Where path '$Path' is not rooted at '/'."
    }
    if ($Path.Contains('\') -or $Path.Contains('//') -or $Path.Contains(':')) {
        New-ReviewerCohortEntryRefusal -Code 'CE111' -Detail "The $Where path '$Path' is not a plain provider path."
    }
    $segments = [string[]]@($Path.Split('/'))
    foreach ($segment in $segments) {
        if ($segment -ceq '.' -or $segment -ceq '..') {
            New-ReviewerCohortEntryRefusal -Code 'CE111' -Detail "The $Where path '$Path' traverses."
        }
    }
    if ($Path.EndsWith('/', [StringComparison]::Ordinal)) {
        New-ReviewerCohortEntryRefusal -Code 'CE111' -Detail "The $Where path '$Path' names a directory."
    }
}

function Get-ReviewerCohortEntryModelRegistry {
    <#
    .SYNOPSIS
        The shared supported-model registry and the generalist pair DERIVED from
        it, read from the one module that owns both.

    .DESCRIPTION
        Loaded on demand rather than at file scope, because a preparation-only
        build has no business requiring the agent harness to be installed - only
        an execution plan names a model at all.

        Nothing here restates a model version. The registry's own comment says it
        plainly: a wrapper that names its own version is how a slot ends up asking
        for a model the agent no longer accepts, and the fix was to make one edit
        in one list move every consumer. This function is a consumer.
    #>
    if (-not (Get-Module DevPilot.AgentHarness)) {
        $manifest = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) { Import-Module $manifest -Force -ErrorAction Stop }
        else { Import-Module DevPilot.AgentHarness -ErrorAction Stop }
    }
    # Assign before wrapping. Get-AgentSupportedModels returns its list with a
    # unary comma, so the array survives the pipeline as ONE object; @() around
    # the call therefore yields a single-element array holding the array, and
    # the [string[]] cast then flattens that element to its joined ToString().
    # Every membership check would have compared against one 295-character
    # string. Binding to a variable first restores the twenty elements.
    $supported = Get-AgentSupportedModels
    $pair = Get-AgentGeneralistModelPair
    return [pscustomobject][ordered]@{
        Supported = [string[]]@($supported)
        GeneralistPair = [string[]]@($pair.Models)
    }
}

function Get-ReviewerCohortEntryBool {
    <#
    .SYNOPSIS
        One required boolean field, required to be an actual JSON boolean.

    .DESCRIPTION
        A string "false" and the number 0 are both refused rather than coerced.
        Every boolean this contract reads is a CAPABILITY switch, and PowerShell
        reads the string "false" as $true - so a plan that wrote its delivery
        capabilities as strings would enable all three while looking disabled.
    #>
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where
    )
    $value = $Object.$Name
    if ($value -isnot [bool]) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The $Where field '$Name' is not a boolean."
    }
    return [bool]$value
}

function Assert-ReviewerCohortEntryDerivedLaunchAuthorization {
    <#
    .SYNOPSIS
        Refuses an execution plan section that still names its own launch
        authorization path.

    .DESCRIPTION
        Named explicitly rather than left to the exact-keys check, which would
        report it as an unexpected field and tell an operator nothing about why
        the field went away or what replaced it. A request written against the
        earlier shape is a request whose token path was very probably never
        going to resolve, so this refusal is the one that matters most.
    #>
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Where
    )
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties['launchAuthorizationTokenPath']) {
        New-ReviewerCohortEntryRefusal -Code 'CE716' `
            -Detail ("The $Where names 'launchAuthorizationTokenPath'. Remove it: the builder derives that path from the " +
                "preparation root, at the exact location the run set declaration publishes its token to.")
    }
}

function Read-ReviewerCohortEntryExecutionPlan {
    <#
    .SYNOPSIS
        The optional v2 execution plan: the complete run declaration the emitted
        coordinator request will carry, read strictly and closed to anything that
        writes.

    .DESCRIPTION
        This section is what makes the difference between an entry that
        authorizes a preparation and an entry that authorizes a whole shadow run
        set. It is therefore read with the same rules as everything else here -
        exact keys, exact types, exact values - and with two extra rules of its
        own.

        FIRST: every capability that could write is required to be its off value
        rather than merely defaulted to it. The delivery kind must be
        'PreviewOnly', the three capability switches must be $false and the
        provider write budget must be 0. An operator cannot write a plan that
        delivers a comment, and cannot write one that leaves the question open.

        SECOND: the output directories are named by a single path COMPONENT, not
        by a path. The builder joins them under the preparation root it derives
        itself, so there is no string an operator can write here that puts a
        run's output anywhere else - not next to the sealed package, not inside
        it, not on another volume.

        THIRD, and for the same reason: the launch authorization is NOT an
        operator field at all. It is derived from the preparation root, at the
        exact path the shipping declaration publishes its token to. An operator
        who could name it could name a path no declaration ever writes, and the
        entry would seal, pass a cohort walk and reach runSetReady before dying
        at the first launch on a token that was never going to exist. A plan that
        still carries the field is refused by name rather than ignored, because
        an ignored path is a path an operator believes is in force.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][int]$PlannedRunCount,
        [Parameter(Mandatory)][string]$PreparationOutputRoot
    )

    $launchTokenPath = Get-ReviewerCohortEntryLaunchAuthorizationPath -PreparationOutputRoot $PreparationOutputRoot

    Assert-ReviewerCohortEntryExactKeys -Object $Plan -Where 'request executionPlan' -Required @(
        'shadowSlotsEnabled', 'reviewerScript', 'models', 'timeouts', 'slots', 'reconciliation', 'delivery')

    if (-not (Get-ReviewerCohortEntryBool -Object $Plan -Name 'shadowSlotsEnabled' -Where 'request executionPlan')) {
        New-ReviewerCohortEntryRefusal -Code 'CE701' `
            -Detail 'The execution plan sets shadowSlotsEnabled to false; a plan that declares a run set nothing may run is not a plan.'
    }

    $script = $Plan.reviewerScript
    Assert-ReviewerCohortEntryExactKeys -Object $script -Where 'request executionPlan reviewerScript' -Required @('path', 'sha256')
    $scriptPath = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $script -Name 'path' -Where 'request executionPlan reviewerScript'))
    $scriptSha = Get-ReviewerCohortEntryString -Object $script -Name 'sha256' -Where 'request executionPlan reviewerScript' `
        -Pattern '^[0-9a-f]{64}$' -MaxLength 64

    $models = $Plan.models
    Assert-ReviewerCohortEntryExactKeys -Object $models -Where 'request executionPlan models' -Required @(
        'generalistPairSource', 'generalistPair', 'conventionSpecialistModel', 'conventionVerifierModel')
    $pairSource = Get-ReviewerCohortEntryString -Object $models -Name 'generalistPairSource' -Where 'request executionPlan models' -MaxLength 64
    if ($pairSource -cne 'derivedFromSupportedModelRegistry') {
        New-ReviewerCohortEntryRefusal -Code 'CE106' `
            -Detail "The execution plan declares generalistPairSource '$pairSource'; the pair is derived from the registry and from nothing else."
    }
    $declaredPair = @($models.generalistPair)
    if ($declaredPair.Count -ne 2) {
        New-ReviewerCohortEntryRefusal -Code 'CE705' `
            -Detail "The execution plan declares $($declaredPair.Count) generalist model(s); an independent cross-check is exactly two."
    }
    foreach ($model in $declaredPair) {
        if ($model -isnot [string] -or [string]$model -cnotmatch '^[a-z0-9][a-z0-9.-]*$') {
            New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The execution plan generalist pair carries '$model', which is not a model identifier."
        }
    }
    $specialist = Get-ReviewerCohortEntryString -Object $models -Name 'conventionSpecialistModel' `
        -Where 'request executionPlan models' -Pattern '^[a-z0-9][a-z0-9.-]*$' -MaxLength 64
    $verifier = Get-ReviewerCohortEntryString -Object $models -Name 'conventionVerifierModel' `
        -Where 'request executionPlan models' -Pattern '^[a-z0-9][a-z0-9.-]*$' -MaxLength 64

    $timeouts = $Plan.timeouts
    Assert-ReviewerCohortEntryExactKeys -Object $timeouts -Where 'request executionPlan timeouts' -Required @(
        'perCallTimeoutSeconds', 'slotTimeoutSeconds', 'progressTimeoutSeconds', 'supervisionGraceSeconds')
    $perCall = Get-ReviewerCohortEntryInt -Object $timeouts -Name 'perCallTimeoutSeconds' -Where 'request executionPlan timeouts' -Minimum 1 -Maximum 14400
    $slotTimeout = Get-ReviewerCohortEntryInt -Object $timeouts -Name 'slotTimeoutSeconds' -Where 'request executionPlan timeouts' -Minimum 1 -Maximum 14400
    $progress = Get-ReviewerCohortEntryInt -Object $timeouts -Name 'progressTimeoutSeconds' -Where 'request executionPlan timeouts' -Minimum 0 -Maximum 14400
    # The one timeout that actually travels into the coordinator request, so its
    # range is the coordinator's own range rather than a range chosen here: a
    # value this reader accepted and the typed reader refused would be a refusal
    # an operator could only discover by running the coordinator.
    $grace = Get-ReviewerCohortEntryInt -Object $timeouts -Name 'supervisionGraceSeconds' -Where 'request executionPlan timeouts' -Minimum 30 -Maximum 3600
    if ($perCall -gt $slotTimeout) {
        New-ReviewerCohortEntryRefusal -Code 'CE710' `
            -Detail "The execution plan allows $perCall second(s) per call inside a $slotTimeout second slot; one call could outlive the slot that supervises it."
    }

    $slots = @($Plan.slots)
    if ($slots.Count -ne 2) {
        New-ReviewerCohortEntryRefusal -Code 'CE702' `
            -Detail "The execution plan declares $($slots.Count) slot(s); the typed coordinator declares exactly two, from creation."
    }
    if ($PlannedRunCount -ne $slots.Count) {
        New-ReviewerCohortEntryRefusal -Code 'CE709' `
            -Detail "The request plans $PlannedRunCount run(s) and the execution plan declares $($slots.Count) slot(s); the coordinator requires them equal."
    }
    $expectedNames = @('slot1', 'slot2')
    $slotList = [System.Collections.Generic.List[object]]::new()
    $seenDirs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $slots.Count; $i++) {
        $slot = $slots[$i]
        Assert-ReviewerCohortEntryDerivedLaunchAuthorization -Object $slot -Where "request executionPlan slot $($i + 1)"
        Assert-ReviewerCohortEntryExactKeys -Object $slot -Where "request executionPlan slot $($i + 1)" -Required @(
            'name', 'stateDirName', 'terminalName', 'modelPlan')
        $name = Get-ReviewerCohortEntryString -Object $slot -Name 'name' -Where "request executionPlan slot $($i + 1)" -MaxLength 16
        # By POSITION, not by set membership. The coordinator reads declaration
        # zero as slot1 and declaration one as slot2; a plan that listed them the
        # other way round would be accepted by a membership check and would then
        # run slot2's state directory under slot1's supervision.
        if ($name -cne $expectedNames[$i]) {
            New-ReviewerCohortEntryRefusal -Code 'CE702' `
                -Detail "The execution plan names declaration $($i + 1) '$name'; the coordinator reads it as '$($expectedNames[$i])'."
        }
        $stateDir = Get-ReviewerCohortEntryString -Object $slot -Name 'stateDirName' -Where "request executionPlan slot $name" `
            -Pattern $script:ReviewerCohortEntryPathComponentPattern -MaxLength 128
        $terminal = Get-ReviewerCohortEntryString -Object $slot -Name 'terminalName' -Where "request executionPlan slot $name" `
            -Pattern $script:ReviewerCohortEntryPathComponentPattern -MaxLength 128
        # Case-INSENSITIVE, because these are file system names on a file system
        # that does not distinguish them: two slots whose state directories
        # differed only in case would be one directory holding two runs.
        foreach ($component in @($stateDir, $terminal)) {
            if (-not $seenDirs.Add($component)) {
                New-ReviewerCohortEntryRefusal -Code 'CE708' `
                    -Detail "The execution plan uses '$component' for more than one slot state or terminal; two runs would share one path."
            }
        }
        $modelPlan = $slot.modelPlan
        Assert-ReviewerCohortEntryExactKeys -Object $modelPlan -Where "request executionPlan slot $name modelPlan" -Required @('bindSealedArguments', 'opaqueArguments')
        $bind = Get-ReviewerCohortEntryBool -Object $modelPlan -Name 'bindSealedArguments' -Where "request executionPlan slot $name modelPlan"
        $opaque = [string[]]@($modelPlan.opaqueArguments)
        if ($opaque.Count -gt 64) {
            New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The execution plan slot $name declares $($opaque.Count) opaque argument(s); the coordinator reads at most 64."
        }
        foreach ($argument in $opaque) {
            if ([string]::IsNullOrEmpty($argument) -or $argument.Length -gt 256) {
                New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The execution plan slot $name declares an opaque argument of $($argument.Length) character(s)."
            }
            # A model plan carries arguments the builder does not interpret. It
            # may not carry arguments that make the reviewer do something OTHER
            # than review - a test hook, a fault injection or a forced outcome -
            # because those are exactly the arguments an opaque list would hide.
            if ($argument -match '(?i)(^|[^A-Za-z0-9])-{1,2}(test|fault|inject|simulate|force|dry-?run|whatif)') {
                New-ReviewerCohortEntryRefusal -Code 'CE308' `
                    -Detail "The execution plan slot $name declares the argument '$argument', which is a test or fault switch rather than a review argument."
            }
        }
        if ($bind -and $opaque.Count -lt 1) {
            New-ReviewerCohortEntryRefusal -Code 'CE106' `
                -Detail "The execution plan slot $name binds sealed arguments and declares none; the coordinator requires at least one."
        }
        [void]$slotList.Add([pscustomobject][ordered]@{
                Name = $name
                StateDirName = $stateDir
                TerminalName = $terminal
                LaunchAuthorizationTokenPath = $launchTokenPath
                BindSealedArguments = $bind
                OpaqueArguments = $opaque
            })
    }

    $reconciliation = $Plan.reconciliation
    Assert-ReviewerCohortEntryDerivedLaunchAuthorization -Object $reconciliation -Where 'request executionPlan reconciliation'
    Assert-ReviewerCohortEntryExactKeys -Object $reconciliation -Where 'request executionPlan reconciliation' -Required @(
        'reconciliationEnabled', 'outputDirName')
    if (-not (Get-ReviewerCohortEntryBool -Object $reconciliation -Name 'reconciliationEnabled' -Where 'request executionPlan reconciliation')) {
        New-ReviewerCohortEntryRefusal -Code 'CE701' `
            -Detail 'The execution plan disables reconciliation; two runs nobody compares are not a cross-check.'
    }
    $reconciliationDir = Get-ReviewerCohortEntryString -Object $reconciliation -Name 'outputDirName' -Where 'request executionPlan reconciliation' `
        -Pattern $script:ReviewerCohortEntryPathComponentPattern -MaxLength 128

    $delivery = $Plan.delivery
    Assert-ReviewerCohortEntryDerivedLaunchAuthorization -Object $delivery -Where 'request executionPlan delivery'
    Assert-ReviewerCohortEntryExactKeys -Object $delivery -Where 'request executionPlan delivery' -Required @(
        'deliveryEnabled', 'authorizationKind', 'outputDirName',
        'commentsEnabled', 'votesEnabled', 'gatesEnabled', 'providerWriteBudget')
    if (-not (Get-ReviewerCohortEntryBool -Object $delivery -Name 'deliveryEnabled' -Where 'request executionPlan delivery')) {
        New-ReviewerCohortEntryRefusal -Code 'CE701' -Detail 'The execution plan disables delivery; a plan present is a plan declared in full.'
    }
    $authorizationKind = Get-ReviewerCohortEntryString -Object $delivery -Name 'authorizationKind' -Where 'request executionPlan delivery' -MaxLength 32
    if ($authorizationKind -cne 'PreviewOnly') {
        New-ReviewerCohortEntryRefusal -Code 'CE707' `
            -Detail "The execution plan declares delivery authorization '$authorizationKind'; this builder emits PreviewOnly and nothing else."
    }
    foreach ($capability in @('commentsEnabled', 'votesEnabled', 'gatesEnabled')) {
        if (Get-ReviewerCohortEntryBool -Object $delivery -Name $capability -Where 'request executionPlan delivery') {
            New-ReviewerCohortEntryRefusal -Code 'CE707' `
                -Detail "The execution plan enables delivery capability '$capability'; a no-write entry authorizes none of them."
        }
    }
    # Read over the WHOLE integer range and then compared, rather than
    # range-checked to [0,0]. A range check would refuse a budget of 1 as a
    # malformed field; it is not malformed, it is a request to write, and an
    # operator has to be told which of those two things they did.
    $writeBudget = Get-ReviewerCohortEntryInt -Object $delivery -Name 'providerWriteBudget' -Where 'request executionPlan delivery' -Minimum 0 -Maximum ([int]::MaxValue)
    if ($writeBudget -ne 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE707' -Detail "The execution plan budgets $writeBudget provider write(s); a no-write entry budgets none."
    }
    $deliveryDir = Get-ReviewerCohortEntryString -Object $delivery -Name 'outputDirName' -Where 'request executionPlan delivery' `
        -Pattern $script:ReviewerCohortEntryPathComponentPattern -MaxLength 128
    if ($deliveryDir.Equals($reconciliationDir, [StringComparison]::OrdinalIgnoreCase)) {
        New-ReviewerCohortEntryRefusal -Code 'CE713' `
            -Detail "The execution plan writes reconciliation and delivery both into '$deliveryDir'; the coordinator requires two distinct directories."
    }
    if ($seenDirs.Contains($reconciliationDir) -or $seenDirs.Contains($deliveryDir)) {
        New-ReviewerCohortEntryRefusal -Code 'CE708' `
            -Detail 'The execution plan reuses a slot state or terminal name for a reconciliation or delivery output.'
    }

    return [pscustomobject][ordered]@{
        ShadowSlotsEnabled = $true
        ReviewerScriptPath = $scriptPath
        ReviewerScriptSha256 = $scriptSha
        GeneralistPair = [string[]]@($declaredPair | ForEach-Object { [string]$_ })
        ConventionSpecialistModel = $specialist
        ConventionVerifierModel = $verifier
        PerCallTimeoutSeconds = $perCall
        SlotTimeoutSeconds = $slotTimeout
        ProgressTimeoutSeconds = $progress
        SupervisionGraceSeconds = $grace
        Slots = [object[]]$slotList.ToArray()
        ReconciliationOutputDirName = $reconciliationDir
        ReconciliationTokenPath = $launchTokenPath
        DeliveryOutputDirName = $deliveryDir
        DeliveryTokenPath = $launchTokenPath
        LaunchAuthorizationTokenPath = $launchTokenPath
        DeliveryAuthorizationKind = 'PreviewOnly'
    }
}

function Read-ReviewerCohortEntryRequest {
    <#
    .SYNOPSIS
        Loads and strictly validates one operator request, returning the frozen
        shape the rest of this file works from.

    .DESCRIPTION
        The bytes are read ONCE and both obeyed and digested, so the bytes that
        were obeyed and the bytes the digest attests to cannot differ. A
        byte-order mark is a refusal rather than something skipped: a request
        that arrives with one has been through an editor that rewrote it, and
        the digest an operator recorded for it no longer describes it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        New-ReviewerCohortEntryRefusal -Code 'CE100' -Detail "Looked for '$full'."
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        New-ReviewerCohortEntryRefusal -Code 'CE101' -Detail "The request at '$full' begins EF BB BF."
    }
    $requestSha256 = Get-ReviewerCorpusSealSha256 -Bytes $bytes
    $text = ''
    try { $text = $script:ReviewerCohortEntryUtf8.GetString($bytes) }
    catch { New-ReviewerCohortEntryRefusal -Code 'CE102' -Detail "The request at '$full' is not valid UTF-8." }
    $root = $null
    try { $root = $text | ConvertFrom-Json -Depth 64 }
    catch { New-ReviewerCohortEntryRefusal -Code 'CE102' -Detail "The request at '$full' is not readable JSON: $($_.Exception.Message)" }
    if ($root -isnot [System.Management.Automation.PSCustomObject]) {
        New-ReviewerCohortEntryRefusal -Code 'CE102' -Detail "The request at '$full' is not a JSON object."
    }

    Assert-ReviewerCohortEntryExactKeys -Object $root -Where 'request' -Required @(
        'schemaVersion', 'kind', 'correlationId', 'toolkit', 'subject',
        'reviewer', 'ruleBundle', 'capture', 'coverage', 'output') -Optional @('executionPlan')

    # Two versions are loadable, and they differ by exactly one section. A v1
    # request can never grow slots - not by adding the section, not by any
    # argument - so every request written before this slice keeps producing the
    # identical preparation-only entry it produced then. A v2 request WITHOUT the
    # section produces that same entry too; the version is the operator's
    # statement of what they are authorizing, and the section is what they
    # authorized.
    $schemaVersion = Get-ReviewerCohortEntryInt -Object $root -Name 'schemaVersion' -Where 'request' -Minimum 1 -Maximum 2
    $executionPlanProperty = $root.PSObject.Properties['executionPlan']
    $hasExecutionPlan = $null -ne $executionPlanProperty
    # An explicit null is a present property with no plan in it. Left to the
    # plan reader it would fail on a MANDATORY parameter binding, which carries
    # no catalogued code and exits 1 instead of 8 - so an operator scripting
    # against the exit codes would read a contract refusal as a crash.
    if ($hasExecutionPlan -and $null -eq $executionPlanProperty.Value) {
        New-ReviewerCohortEntryRefusal -Code 'CE700' `
            -Detail 'The request carries an executionPlan of null; omit the section to build a preparation-only entry.'
    }
    if ($hasExecutionPlan -and $schemaVersion -lt 2) {
        New-ReviewerCohortEntryRefusal -Code 'CE700' `
            -Detail "The request declares schemaVersion $schemaVersion and carries an executionPlan; the plan section arrived at version 2."
    }
    $kind = [string]$root.kind
    if ($kind -cne $script:ReviewerCohortEntryRequestKind) {
        New-ReviewerCohortEntryRefusal -Code 'CE103' `
            -Detail "The request declares kind '$kind'; this build reads '$($script:ReviewerCohortEntryRequestKind)' only."
    }

    # Before a single field is interpreted, and over the WHOLE document rather
    # than over the fields this reader happens to name.
    Assert-ReviewerCohortEntryOracleFree -Node $root -Path 'request'

    $correlationId = Get-ReviewerCohortEntryString -Object $root -Name 'correlationId' -Where 'request' `
        -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$' -MaxLength 64

    $toolkit = $root.toolkit
    Assert-ReviewerCohortEntryExactKeys -Object $toolkit -Where 'request toolkit' -Required @('repositoryRoot', 'head', 'requiredRef')
    $toolkitRoot = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $toolkit -Name 'repositoryRoot' -Where 'request toolkit'))
    $toolkitHead = Get-ReviewerCohortEntryString -Object $toolkit -Name 'head' -Where 'request toolkit' -Pattern '^[0-9a-f]{40}$' -MaxLength 40
    $requiredRef = Get-ReviewerCohortEntryString -Object $toolkit -Name 'requiredRef' -Where 'request toolkit' -Pattern '^refs/[A-Za-z0-9._/-]+$' -MaxLength 512

    $subject = $root.subject
    Assert-ReviewerCohortEntryExactKeys -Object $subject -Where 'request subject' -Required @(
        'organization', 'project', 'repositoryId', 'repositoryName', 'pullRequestId', 'targetRefName')
    $organization = Get-ReviewerCohortEntryString -Object $subject -Name 'organization' -Where 'request subject' -Pattern '^[^/\s]+$' -MaxLength 128
    $project = Get-ReviewerCohortEntryString -Object $subject -Name 'project' -Where 'request subject' -Pattern '^[^/\s]+$' -MaxLength 128
    $repositoryId = Get-ReviewerCohortEntryString -Object $subject -Name 'repositoryId' -Where 'request subject' `
        -Pattern '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -MaxLength 36
    $repositoryName = Get-ReviewerCohortEntryString -Object $subject -Name 'repositoryName' -Where 'request subject' -Pattern '^[^/\s]+$' -MaxLength 128
    $pullRequestId = Get-ReviewerCohortEntryInt -Object $subject -Name 'pullRequestId' -Where 'request subject' -Minimum 1 -Maximum ([int]::MaxValue)
    $targetRefName = Get-ReviewerCohortEntryString -Object $subject -Name 'targetRefName' -Where 'request subject' -Pattern '^refs/[A-Za-z0-9._/-]+$' -MaxLength 512

    $reviewer = $root.reviewer
    Assert-ReviewerCohortEntryExactKeys -Object $reviewer -Where 'request reviewer' -Required @(
        'configPath', 'repositoryPath', 'operatorAlias', 'powerShellPath',
        'childTimeoutSeconds', 'plannedRunCount', 'runSetKeyPath')

    $ruleBundle = $root.ruleBundle
    Assert-ReviewerCohortEntryExactKeys -Object $ruleBundle -Where 'request ruleBundle' -Required @(
        'sourceKind', 'declarationPath', 'declarationSha256', 'sections')
    $ruleSourceKind = Get-ReviewerCohortEntryString -Object $ruleBundle -Name 'sourceKind' -Where 'request ruleBundle' -MaxLength 64
    if ($ruleSourceKind -cne 'pinnedRepositorySections') {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The request ruleBundle declares sourceKind '$ruleSourceKind'."
    }
    $sections = @($ruleBundle.sections)
    if ($sections.Count -lt 1 -or $sections.Count -gt 64) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The request ruleBundle declares $($sections.Count) section(s)."
    }
    $sectionList = [System.Collections.Generic.List[object]]::new()
    $seenSections = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($section in $sections) {
        Assert-ReviewerCohortEntryExactKeys -Object $section -Where 'request ruleBundle section' -Required @('path', 'commit', 'sha256', 'byteLength')
        $sectionPath = Get-ReviewerCohortEntryString -Object $section -Name 'path' -Where 'request ruleBundle section'
        Assert-ReviewerCohortEntryRepositoryRelativePath -Path $sectionPath -Where 'request ruleBundle section'
        if (-not $seenSections.Add($sectionPath)) {
            New-ReviewerCohortEntryRefusal -Code 'CE110' -Detail "The rule bundle declares '$sectionPath' twice."
        }
        [void]$sectionList.Add([pscustomobject][ordered]@{
                Path = $sectionPath
                Commit = (Get-ReviewerCohortEntryString -Object $section -Name 'commit' -Where 'request ruleBundle section' -Pattern '^[0-9a-f]{40}$' -MaxLength 40)
                Sha256 = (Get-ReviewerCohortEntryString -Object $section -Name 'sha256' -Where 'request ruleBundle section' -Pattern '^[0-9a-f]{64}$' -MaxLength 64)
                ByteLength = (Get-ReviewerCohortEntryInt -Object $section -Name 'byteLength' -Where 'request ruleBundle section' -Minimum 1 -Maximum 1048576)
            })
    }

    $capture = $root.capture
    Assert-ReviewerCohortEntryExactKeys -Object $capture -Where 'request capture' -Required @('mode') `
        -Optional @('replayRoot', 'replaySnapshotName', 'replayManifestDigest', 'agencyPath', 'requestTimeoutSeconds')
    $captureMode = Get-ReviewerCohortEntryString -Object $capture -Name 'mode' -Where 'request capture' -MaxLength 16
    if ($captureMode -cne 'replay' -and $captureMode -cne 'live') {
        New-ReviewerCohortEntryRefusal -Code 'CE106' -Detail "The request capture declares mode '$captureMode'."
    }
    $replayRoot = ''
    $replaySnapshotName = ''
    $replayManifestDigest = ''
    $agencyPath = ''
    if ($captureMode -ceq 'replay') {
        foreach ($name in @('replayRoot', 'replaySnapshotName', 'replayManifestDigest')) {
            if (-not $capture.PSObject.Properties[$name]) {
                New-ReviewerCohortEntryRefusal -Code 'CE104' -Detail "A replay capture omits '$name'."
            }
        }
        $replayRoot = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $capture -Name 'replayRoot' -Where 'request capture'))
        $replaySnapshotName = Get-ReviewerCohortEntryString -Object $capture -Name 'replaySnapshotName' -Where 'request capture' -Pattern '^[^/\s]+$' -MaxLength 128
        $replayManifestDigest = Get-ReviewerCohortEntryString -Object $capture -Name 'replayManifestDigest' -Where 'request capture' -Pattern '^[0-9a-f]{64}$' -MaxLength 64
    }
    else {
        if (-not $capture.PSObject.Properties['agencyPath']) {
            New-ReviewerCohortEntryRefusal -Code 'CE104' -Detail "A live capture omits 'agencyPath'."
        }
        $agencyPath = Get-ReviewerCohortEntryString -Object $capture -Name 'agencyPath' -Where 'request capture' -MaxLength 512
    }
    $requestTimeoutSeconds = 0
    if ($capture.PSObject.Properties['requestTimeoutSeconds']) {
        $requestTimeoutSeconds = Get-ReviewerCohortEntryInt -Object $capture -Name 'requestTimeoutSeconds' -Where 'request capture' -Minimum 1 -Maximum 600
    }

    $coverage = $root.coverage
    Assert-ReviewerCohortEntryExactKeys -Object $coverage -Where 'request coverage' -Required @(
        'maxChangedFiles', 'maxFileBytes', 'maxSiblingFiles', 'maxThreads', 'minChangedPathCoveragePercent')

    $output = $root.output
    Assert-ReviewerCohortEntryExactKeys -Object $output -Where 'request output' -Required @('root', 'entryId', 'ordinal', 'sealKeyPath')
    $outputRoot = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $output -Name 'root' -Where 'request output'))
    if (Test-ReviewerCohortEntryPathWithin -Candidate $outputRoot -Root $toolkitRoot) {
        New-ReviewerCohortEntryRefusal -Code 'CE109' `
            -Detail "The output root '$outputRoot' is inside the toolkit '$toolkitRoot'; private evidence is kept one commit away from being published."
    }

    $plannedRunCount = Get-ReviewerCohortEntryInt -Object $reviewer -Name 'plannedRunCount' -Where 'request reviewer' -Minimum 2 -Maximum 16
    $executionPlan = $null
    if ($hasExecutionPlan) {
        # The preparation root is derived HERE, before the plan is read, so the
        # launch authorization path is stamped into the plan the emitted request
        # carries rather than patched in afterwards. Nothing is rewritten after
        # the request is hashed because nothing needs to be: the path was known
        # from the output root the operator declared.
        $preparationOutputRoot = Get-ReviewerCohortEntryPreparationRoot -OutputRoot $outputRoot
        $executionPlan = Read-ReviewerCohortEntryExecutionPlan -Plan $root.executionPlan `
            -PlannedRunCount $plannedRunCount -PreparationOutputRoot $preparationOutputRoot
        # A launch authorization inside the package would be published with it,
        # frozen read-only with it, and inventoried with it - which is to say the
        # entry would ship the very token that lets it run. The derived path is a
        # sibling of the package rather than a child, and this asserts that the
        # derivation actually kept it there instead of trusting that it did.
        foreach ($tokenPath in @(
                @($executionPlan.Slots | ForEach-Object { [string]$_.LaunchAuthorizationTokenPath }) +
                @($executionPlan.ReconciliationTokenPath, $executionPlan.DeliveryTokenPath))) {
            if (Test-ReviewerCohortEntryPathWithin -Candidate $tokenPath -Root $outputRoot) {
                New-ReviewerCohortEntryRefusal -Code 'CE711' `
                    -Detail "The execution plan names the launch authorization '$tokenPath', which is inside the sealed package root '$outputRoot'."
            }
        }
    }

    # The thread cap is the operator's ceiling on the SUBJECT, not on the read.
    # The read asks for exactly the page the live cycle asks for, so a ceiling
    # above that page is a ceiling this build could never observe being crossed:
    # it would admit a subject with more threads than the operator authorized and
    # call the census complete. Refuse the request rather than the evidence.
    $declaredThreadCap = Get-ReviewerCohortEntryInt -Object $coverage -Name 'maxThreads' `
        -Where 'request coverage' -Minimum 1 -Maximum 1000
    if ($declaredThreadCap -gt (Get-ReviewerThreadListTop)) {
        New-ReviewerCohortEntryRefusal -Code 'CE408' `
            -Detail ("The request caps threads at $declaredThreadCap and the reviewer's own thread read asks " +
                "for $(Get-ReviewerThreadListTop).")
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = $schemaVersion
        Kind = $kind
        CorrelationId = $correlationId
        RequestPath = $full
        RequestSha256 = $requestSha256
        ToolkitRoot = $toolkitRoot
        ToolkitHead = $toolkitHead
        RequiredRef = $requiredRef
        Organization = $organization
        Project = $project
        RepositoryId = $repositoryId
        RepositoryName = $repositoryName
        PullRequestId = $pullRequestId
        TargetRefName = $targetRefName
        ReviewerConfigPath = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $reviewer -Name 'configPath' -Where 'request reviewer'))
        ReviewerRepositoryPath = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $reviewer -Name 'repositoryPath' -Where 'request reviewer'))
        OperatorAlias = (Get-ReviewerCohortEntryString -Object $reviewer -Name 'operatorAlias' -Where 'request reviewer' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$' -MaxLength 64)
        PowerShellPath = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $reviewer -Name 'powerShellPath' -Where 'request reviewer'))
        ChildTimeoutSeconds = (Get-ReviewerCohortEntryInt -Object $reviewer -Name 'childTimeoutSeconds' -Where 'request reviewer' -Minimum 1 -Maximum 14400)
        PlannedRunCount = $plannedRunCount
        RunSetKeyPath = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $reviewer -Name 'runSetKeyPath' -Where 'request reviewer'))
        RuleBundleSourceKind = $ruleSourceKind
        RuleBundleDeclarationPath = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $ruleBundle -Name 'declarationPath' -Where 'request ruleBundle'))
        RuleBundleDeclarationSha256 = (Get-ReviewerCohortEntryString -Object $ruleBundle -Name 'declarationSha256' -Where 'request ruleBundle' -Pattern '^[0-9a-f]{64}$' -MaxLength 64)
        RuleSections = [object[]]$sectionList.ToArray()
        CaptureMode = $captureMode
        ReplayRoot = $replayRoot
        ReplaySnapshotName = $replaySnapshotName
        ReplayManifestDigest = $replayManifestDigest
        AgencyPath = $agencyPath
        RequestTimeoutSeconds = $requestTimeoutSeconds
        MaxChangedFiles = (Get-ReviewerCohortEntryInt -Object $coverage -Name 'maxChangedFiles' -Where 'request coverage' -Minimum 1 -Maximum 1000)
        MaxFileBytes = (Get-ReviewerCohortEntryInt -Object $coverage -Name 'maxFileBytes' -Where 'request coverage' -Minimum 1 -Maximum 5242880)
        MaxSiblingFiles = (Get-ReviewerCohortEntryInt -Object $coverage -Name 'maxSiblingFiles' -Where 'request coverage' -Minimum 0 -Maximum 256)
        MaxThreads = $declaredThreadCap
        MinChangedPathCoveragePercent = (Get-ReviewerCohortEntryInt -Object $coverage -Name 'minChangedPathCoveragePercent' -Where 'request coverage' -Minimum 1 -Maximum 100)
        OutputRoot = $outputRoot
        EntryId = (Get-ReviewerCohortEntryString -Object $output -Name 'entryId' -Where 'request output' -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]{3,63}$' -MaxLength 64)
        Ordinal = (Get-ReviewerCohortEntryInt -Object $output -Name 'ordinal' -Where 'request output' -Minimum 1 -Maximum 64)
        SealKeyPath = [IO.Path]::GetFullPath((Get-ReviewerCohortEntryString -Object $output -Name 'sealKeyPath' -Where 'request output'))
        ExecutionPlan = $executionPlan
    }
}

# ---------------------------------------------------------------------------
# The closed read plan
# ---------------------------------------------------------------------------

function Get-ReviewerCohortEntryShortBranch {
    <#
    .SYNOPSIS
        The short branch name the reviewer's own repo_branch read asks for,
        taken from a fully qualified refs/heads ref.
    #>
    param([Parameter(Mandatory)][string]$TargetRefName)
    if (-not $TargetRefName.StartsWith('refs/heads/', [StringComparison]::Ordinal)) {
        New-ReviewerCohortEntryRefusal -Code 'CE106' `
            -Detail "The target ref '$TargetRefName' is not a refs/heads ref, and repo_branch resolves branches only."
    }
    return $TargetRefName.Substring('refs/heads/'.Length)
}

function Get-ReviewerCohortEntryResourceUri {
    <#
    .SYNOPSIS
        The exact embedded-resource URI the wrapper answers for one repository
        path.

    .DESCRIPTION
        It is the repository-relative path itself, unchanged. This looks like a
        function that does nothing, and that is the point: the natural mistake -
        made once already while building this - is to compose a synthetic
        'ado://<org>/<project>/<repoId><path>' URI, because that IS the form the
        offline corpus-seal RECORD uses for provenance. The wrapper does not
        answer under that URI, so every live embedded-resource read is refused at
        CE304 while the reviewer, which passes the bare path as its expected URI
        at every repo_file call site, reads the same bytes without complaint.
        Naming the identity here keeps the two URIs from being confused again.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )
    return $Path
}

function New-ReviewerCohortEntryRead {
    <#
    .SYNOPSIS
        One planned read: its stable id, the tool, the EXACT argument vector, the
        envelope its response is stored in, and where the payload lands.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Arguments,
        [Parameter(Mandatory)][ValidateSet('mcpTextContent', 'mcpResourceContent')][string]$Envelope,
        [Parameter(Mandatory)][string]$PayloadFile,
        [Parameter(Mandatory)][string]$Role,
        [AllowEmptyString()][string]$ResourceUri = '',
        [AllowEmptyString()][string]$MimeType = '',
        [AllowEmptyString()][string]$ProviderPath = '',
        [AllowEmptyString()][string]$DuplicateOf = ''
    )
    return [pscustomobject][ordered]@{
        Id = $Id
        Tool = $Tool
        Arguments = $Arguments
        Envelope = $Envelope
        PayloadFile = $PayloadFile
        Role = $Role
        ResourceUri = $ResourceUri
        MimeType = $MimeType
        ProviderPath = $ProviderPath
        DuplicateOf = $DuplicateOf
    }
}

function Get-ReviewerCohortEntryIdentityReadPlan {
    <#
    .SYNOPSIS
        The identity half of the closed plan: everything that can be issued
        before a single changed path is known.

    .DESCRIPTION
        The order is the contract. The candidate identity read comes first
        because everything after it is bound to what it returned; the live
        identity re-read comes LAST, after every other read, so that the
        drift check covers the whole capture rather than its opening moment.

        The repository is named three different ways across four reads, and each
        way is the way that read's own reviewed call site names it:

          repo_repository       repositoryNameOrId = the repository GUID
          repo_branch           repositoryId       = the repository GUID
          repo_pull_request     repositoryId       = the repository NAME
          repo_file             repositoryId       = the repository GUID

        Those are not interchangeable, and an operator assembling this by hand
        has to remember which is which four times. Here it is stated once.
    #>
    param([Parameter(Mandatory)]$Request)

    $branch = Get-ReviewerCohortEntryShortBranch -TargetRefName $Request.TargetRefName
    $reads = [System.Collections.Generic.List[object]]::new()

    [void]$reads.Add((New-ReviewerCohortEntryRead -Id 'candidate-identity' -Tool 'repo_pull_request' -Role 'identity' `
                -Arguments ([ordered]@{
                    action = 'get'
                    project = $Request.Project
                    repositoryId = $Request.RepositoryName
                    pullRequestId = $Request.PullRequestId
                }) -Envelope 'mcpTextContent' -PayloadFile 'payloads/pr-get.json'))

    [void]$reads.Add((New-ReviewerCohortEntryRead -Id 'repository-identity' -Tool 'repo_repository' -Role 'identity' `
                -Arguments ([ordered]@{
                    action = 'get'
                    project = $Request.Project
                    repositoryNameOrId = $Request.RepositoryId
                }) -Envelope 'mcpTextContent' -PayloadFile 'payloads/repo-identity.json'))

    [void]$reads.Add((New-ReviewerCohortEntryRead -Id 'target-branch' -Tool 'repo_branch' -Role 'identity' `
                -Arguments ([ordered]@{
                    action = 'get'
                    project = $Request.Project
                    repositoryId = $Request.RepositoryId
                    branchName = $branch
                }) -Envelope 'mcpTextContent' -PayloadFile 'payloads/target-branch.json'))

    # Both get_changes variants, because they are two distinct read keys and a
    # snapshot that recorded only the plain one leaves the reviewer's diff-
    # bearing read unanswered at the moment it is issued - which is a live
    # fallback in a mode that has no live seam.
    # 'top' is asked ONE ABOVE the declared cap on THESE reads, deliberately. A
    # provider asked for exactly the cap answers exactly the cap when there are
    # more, and a count-equals-cap answer is indistinguishable from a complete
    # one - which is how a capped census once looked complete and admitted a
    # subject larger than the operator authorized. Asking for cap+1 makes
    # overflow observable: a count above the cap is a refusal, and a count at the
    # cap is genuinely all there is. This is sound only because the change-set
    # cap is the BUILDER's own; see the thread read below for the read that is
    # not.
    [void]$reads.Add((New-ReviewerCohortEntryRead -Id 'changes-plain' -Tool 'repo_pull_request' -Role 'change' `
                -Arguments ([ordered]@{
                    action = 'get_changes'
                    project = $Request.Project
                    repositoryId = $Request.RepositoryName
                    pullRequestId = $Request.PullRequestId
                    top = ($Request.MaxChangedFiles + 1)
                }) -Envelope 'mcpTextContent' -PayloadFile 'payloads/changes.json'))

    [void]$reads.Add((New-ReviewerCohortEntryRead -Id 'changes-diffs' -Tool 'repo_pull_request' -Role 'change' `
                -Arguments ([ordered]@{
                    action = 'get_changes'
                    project = $Request.Project
                    repositoryId = $Request.RepositoryName
                    pullRequestId = $Request.PullRequestId
                    includeDiffs = $true
                    includeLineContent = $true
                    top = ($Request.MaxChangedFiles + 1)
                }) -Envelope 'mcpTextContent' -PayloadFile 'payloads/changes-diffs.json'))

    # The thread read is NOT shaped here. It is the live cycle's read, taken from
    # the one shared helper, because a replay answers the arguments it recorded
    # and never falls through to a live one: a thread vector assembled
    # independently here is a slot that dies mid-cycle on a read it needs. The
    # cap+1 probe above is correct for the change-set reads, which this builder
    # does own; it is wrong for this one, so thread completeness is accounted
    # after the fact instead (CE406/CE408).
    $threadRequest = New-ReviewerThreadListRequest -Project $Request.Project `
        -RepositoryName $Request.RepositoryName -PullRequestId $Request.PullRequestId
    [void]$reads.Add((New-ReviewerCohortEntryRead -Id 'threads' -Tool $threadRequest.Name -Role 'thread' `
                -Arguments $threadRequest.Arguments -Envelope 'mcpTextContent' -PayloadFile 'payloads/threads.json'))

    return [object[]]$reads.ToArray()
}

function Get-ReviewerCohortEntryFileRead {
    <#
    .SYNOPSIS
        One planned repo_file read, in the exact argument vector and embedded-
        resource envelope the reviewer's own source read uses.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ProviderPath,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$PayloadFile,
        [string]$MimeType = 'text/plain'
    )
    Assert-ReviewerCohortEntryRepositoryRelativePath -Path $ProviderPath -Where "planned $Role read"
    return (New-ReviewerCohortEntryRead -Id $Id -Tool 'repo_file' -Role $Role `
            -Arguments ([ordered]@{
                action = 'get_content'
                project = $Request.Project
                repositoryId = $Request.RepositoryId
                path = $ProviderPath
                versionType = 'Commit'
                version = $Commit
            }) -Envelope 'mcpResourceContent' -PayloadFile $PayloadFile `
            -ResourceUri (Get-ReviewerCohortEntryResourceUri -Path $ProviderPath) `
            -MimeType $MimeType -ProviderPath $ProviderPath)
}

function Assert-ReviewerCohortEntryPlanIsClosed {
    <#
    .SYNOPSIS
        Refuses a plan that reaches outside the read ceiling or records one read
        key twice.

    .DESCRIPTION
        Reached through the harness's own replay permission predicate rather
        than through a second copy of the ceiling here, so a tool or action this
        build may not read is the same set the replay loader refuses to serve.

        A read may share another read's request key ONLY by declaring
        'DuplicateOf' naming that read, and only if its argument vector is
        byte-identical to it. That is how the closing live-identity re-read is
        declared in the plan before the first read is issued rather than issued
        outside it: an undeclared second execution of a planned read is a read
        the plan does not describe, and this build has no way to authorize one.
    #>
    param([Parameter(Mandatory)][object[]]$Plan)
    $seen = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $byId = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($read in $Plan) {
        $id = [string]$read.Id
        if ($byId.ContainsKey($id)) {
            New-ReviewerCohortEntryRefusal -Code 'CE309' -Detail "The plan declares the read id '$id' twice."
        }
        $byId[$id] = $read
        $permitted = Test-AgentReplayToolPermitted -Name $read.Tool -Arguments $read.Arguments
        if (-not $permitted.Permitted) {
            New-ReviewerCohortEntryRefusal -Code 'CE308' -Detail "The planned read '$id' is refused: $($permitted.Reason)."
        }
        $key = (Get-AgentReplayRequestKey -Name $read.Tool -Arguments $read.Arguments).Key
        $duplicateOf = [string]$read.DuplicateOf
        if ($duplicateOf) {
            if (-not $byId.ContainsKey($duplicateOf)) {
                New-ReviewerCohortEntryRefusal -Code 'CE309' `
                    -Detail "The planned read '$id' declares itself a re-read of '$duplicateOf', which the plan does not declare before it."
            }
            $originalKey = (Get-AgentReplayRequestKey -Name $byId[$duplicateOf].Tool -Arguments $byId[$duplicateOf].Arguments).Key
            if ($originalKey -cne $key) {
                New-ReviewerCohortEntryRefusal -Code 'CE309' `
                    -Detail "The planned read '$id' declares itself a re-read of '$duplicateOf' but asks a different question."
            }
            continue
        }
        if ($seen.ContainsKey($key)) {
            New-ReviewerCohortEntryRefusal -Code 'CE309' `
                -Detail "The planned reads '$($seen[$key])' and '$id' resolve to one request key."
        }
        $seen[$key] = $id
    }
}

# ---------------------------------------------------------------------------
# Identity assertions over wrapper-contract responses
# ---------------------------------------------------------------------------

function Get-ReviewerCohortEntryProperty {
    <#
    .SYNOPSIS
        One property of a parsed provider result, present-or-refused.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Where,
        [Parameter(Mandatory)][string]$Code
    )
    if ($null -eq $Object -or $Object -isnot [System.Management.Automation.PSCustomObject] -or
        -not $Object.PSObject.Properties[$Name]) {
        New-ReviewerCohortEntryRefusal -Code $Code -Detail "The $Where carries no '$Name'."
    }
    return $Object.$Name
}

function Assert-ReviewerCohortEntryRepositoryIdentity {
    <#
    .SYNOPSIS
        Requires the reduced wrapper-contract repository identity, and names the
        raw provider shape as its own refusal.

    .DESCRIPTION
        The reviewed contract is a reduced object: an 'id' that is the repository
        GUID and a NESTED 'projectReference' whose 'name' is the project. A raw
        Azure DevOps repository body instead carries a flat 'project' object, and
        it is a shape an operator reaches for constantly because it is what a
        REST response looks like and it "has the project in it".

        That case gets CE203 rather than CE202. The two refusals mean different
        things: CE202 says the response is not a repository identity at all, and
        CE203 says it IS one but it is the raw body rather than the contract the
        reviewer reads - which is a mistake in how the evidence was obtained, not
        in what was asked for.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Repository,
        [Parameter(Mandatory)][string]$ExpectedProject,
        [Parameter(Mandatory)][string]$ExpectedRepositoryId
    )
    if ($Repository -isnot [System.Management.Automation.PSCustomObject]) {
        New-ReviewerCohortEntryRefusal -Code 'CE202' -Detail 'The repository identity is not a JSON object.'
    }
    $names = [string[]]@($Repository.PSObject.Properties.Name)
    if ($names -cnotcontains 'projectReference' -and $names -ccontains 'project') {
        New-ReviewerCohortEntryRefusal -Code 'CE203' `
            -Detail ("The repository identity carries a flat 'project' and no 'projectReference'. " +
                'That is the raw provider body; the reviewer reads a reduced identity whose project is nested under projectReference.')
    }
    if ($names -cnotcontains 'id') {
        New-ReviewerCohortEntryRefusal -Code 'CE202' -Detail "The repository identity carries no 'id'."
    }
    if ([string]$Repository.id -cne $ExpectedRepositoryId) {
        New-ReviewerCohortEntryRefusal -Code 'CE204' `
            -Detail "The repository identity names '$([string]$Repository.id)' and the request names '$ExpectedRepositoryId'."
    }
    if ($names -cnotcontains 'projectReference') {
        New-ReviewerCohortEntryRefusal -Code 'CE202' -Detail "The repository identity carries no 'projectReference'."
    }
    $reference = $Repository.projectReference
    if ($reference -isnot [System.Management.Automation.PSCustomObject] -or
        -not $reference.PSObject.Properties['name']) {
        New-ReviewerCohortEntryRefusal -Code 'CE202' -Detail "The repository identity's 'projectReference' carries no 'name'."
    }
    if ([string]$reference.name -cne $ExpectedProject) {
        New-ReviewerCohortEntryRefusal -Code 'CE204' `
            -Detail "The repository identity's project is '$([string]$reference.name)' and the request names '$ExpectedProject'."
    }
}

function Get-ReviewerCohortEntryBranchCommit {
    <#
    .SYNOPSIS
        The one 40-hex commit an exact branch resolution returned, lowercased.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$BranchResult,
        [Parameter(Mandatory)][string]$ExpectedRefName
    )
    if ($BranchResult -isnot [System.Management.Automation.PSCustomObject] -or
        -not $BranchResult.PSObject.Properties['name'] -or
        -not $BranchResult.PSObject.Properties['objectId']) {
        New-ReviewerCohortEntryRefusal -Code 'CE205' -Detail 'The branch resolution carries no name and objectId.'
    }
    $short = $ExpectedRefName.Substring('refs/heads/'.Length)
    $observed = [string]$BranchResult.name
    if ($observed -cne $ExpectedRefName -and $observed -cne $short) {
        New-ReviewerCohortEntryRefusal -Code 'CE205' `
            -Detail "The branch resolution named '$observed' and the request asked for '$ExpectedRefName'."
    }
    $objectId = [string]$BranchResult.objectId
    if ($objectId -cnotmatch '^[0-9a-fA-F]{40}$') {
        New-ReviewerCohortEntryRefusal -Code 'CE205' -Detail "The branch resolution returned objectId '$objectId'."
    }
    return $objectId.ToLowerInvariant()
}

function Get-ReviewerCohortEntryPullRequestIdentity {
    <#
    .SYNOPSIS
        The identity witness one pull request read proves, or a refusal naming
        exactly which admission condition failed.

    .DESCRIPTION
        Draft and non-active are separate codes because they are separate
        operator actions: a draft is waiting for its author and an abandoned or
        completed pull request is finished. Both refuse the entry; neither is
        the other's problem.

        The source commit is read from its nested 'lastMergeSourceCommit.commitId'
        the way the reviewer reads it, rather than from a flat 'sourceCommit'
        that no provider emits and that a hand-assembled witness routinely
        invents.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$PullRequest,
        [Parameter(Mandatory)]$Request
    )
    if ($PullRequest -isnot [System.Management.Automation.PSCustomObject]) {
        New-ReviewerCohortEntryRefusal -Code 'CE210' -Detail 'The pull request read did not return an object.'
    }
    $observedId = [int](Get-ReviewerCohortEntryProperty -Object $PullRequest -Name 'pullRequestId' -Where 'pull request' -Code 'CE210')
    if ($observedId -ne $Request.PullRequestId) {
        New-ReviewerCohortEntryRefusal -Code 'CE210' `
            -Detail "The pull request read returned $observedId and the request names $($Request.PullRequestId)."
    }
    $status = [string](Get-ReviewerCohortEntryProperty -Object $PullRequest -Name 'status' -Where 'pull request' -Code 'CE208')
    $isDraft = [bool](Get-ReviewerCohortEntryProperty -Object $PullRequest -Name 'isDraft' -Where 'pull request' -Code 'CE207')
    if ($isDraft) {
        New-ReviewerCohortEntryRefusal -Code 'CE207' -Detail "Pull request $observedId is a draft."
    }
    # Compared case-INSENSITIVELY, the way the reviewer compares it. The wrapper
    # answers 'Active' from one surface and 'active' from another, and the
    # reviewer's own eligibility rule has always used -ine; a cohort entry that
    # refused a live pull request the reviewer would happily run is a false
    # refusal, not a stricter check.
    if ($status -ine 'active') {
        New-ReviewerCohortEntryRefusal -Code 'CE208' -Detail "Pull request $observedId reports status '$status'."
    }
    $targetRefName = [string](Get-ReviewerCohortEntryProperty -Object $PullRequest -Name 'targetRefName' -Where 'pull request' -Code 'CE206')
    if ($targetRefName -cne $Request.TargetRefName) {
        New-ReviewerCohortEntryRefusal -Code 'CE206' `
            -Detail "Pull request $observedId targets '$targetRefName' and the request declares '$($Request.TargetRefName)'."
    }
    $mergeSource = Get-ReviewerCohortEntryProperty -Object $PullRequest -Name 'lastMergeSourceCommit' -Where 'pull request' -Code 'CE210'
    $mergeTarget = Get-ReviewerCohortEntryProperty -Object $PullRequest -Name 'lastMergeTargetCommit' -Where 'pull request' -Code 'CE210'
    $mergeCommon = Get-ReviewerCohortEntryProperty -Object $PullRequest -Name 'lastMergeCommit' -Where 'pull request' -Code 'CE210'
    $sourceCommit = [string](Get-ReviewerCohortEntryProperty -Object $mergeSource -Name 'commitId' -Where 'pull request lastMergeSourceCommit' -Code 'CE210')
    $targetCommit = [string](Get-ReviewerCohortEntryProperty -Object $mergeTarget -Name 'commitId' -Where 'pull request lastMergeTargetCommit' -Code 'CE210')
    $commonCommit = [string](Get-ReviewerCohortEntryProperty -Object $mergeCommon -Name 'commitId' -Where 'pull request lastMergeCommit' -Code 'CE210')
    foreach ($pair in @(
            @{ Name = 'lastMergeSourceCommit'; Value = $sourceCommit },
            @{ Name = 'lastMergeTargetCommit'; Value = $targetCommit },
            @{ Name = 'lastMergeCommit'; Value = $commonCommit })) {
        if ([string]$pair.Value -cnotmatch '^[0-9a-fA-F]{40}$') {
            New-ReviewerCohortEntryRefusal -Code 'CE210' `
                -Detail "Pull request $observedId reports $($pair.Name) '$([string]$pair.Value)'."
        }
    }
    return [pscustomobject][ordered]@{
        PullRequestId = $observedId
        Status = $status
        IsDraft = $isDraft
        TargetRefName = $targetRefName
        SourceCommit = $sourceCommit.ToLowerInvariant()
        TargetCommit = $targetCommit.ToLowerInvariant()
        CommonCommit = $commonCommit.ToLowerInvariant()
    }
}

function Assert-ReviewerCohortEntryIdentityStable {
    <#
    .SYNOPSIS
        Requires the closing identity re-read to agree with the opening one,
        field by field.

    .DESCRIPTION
        The whole capture sits between these two reads. If the author pushed, or
        the pull request was drafted, abandoned or retargeted while the evidence
        was being assembled, then the corpus describes one iteration and the
        identity witness describes another - and every downstream digest would
        agree with itself while describing two different things.
    #>
    param(
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$Live
    )
    foreach ($name in @('PullRequestId', 'Status', 'IsDraft', 'TargetRefName', 'SourceCommit', 'TargetCommit', 'CommonCommit')) {
        $before = [string]$Candidate.$name
        $after = [string]$Live.$name
        if ($before -cne $after) {
            New-ReviewerCohortEntryRefusal -Code 'CE209' `
                -Detail "The identity field '$name' read '$before' before the capture and '$after' after it."
        }
    }
}

function Get-ReviewerCohortEntryIterationBinding {
    <#
    .SYNOPSIS
        The iteration id and its three commits, from a change-set response.

    .DESCRIPTION
        A change set that carries no iteration is refused rather than defaulted
        to one: iteration 1 is a real iteration, and an entry pinned to it by
        default would be pinned to the wrong evidence for every pull request
        that has ever been updated.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Changes,
        [Parameter(Mandatory)]$Identity
    )
    if ($Changes -isnot [System.Management.Automation.PSCustomObject]) {
        New-ReviewerCohortEntryRefusal -Code 'CE210' -Detail 'The change set is not a JSON object.'
    }
    $iterationValue = Get-ReviewerCohortEntryProperty -Object $Changes -Name 'iterationId' -Where 'change set' -Code 'CE210'
    if ($iterationValue -is [bool] -or ($iterationValue -isnot [int] -and $iterationValue -isnot [long])) {
        New-ReviewerCohortEntryRefusal -Code 'CE210' -Detail "The change set reports iterationId '$iterationValue', which is not an integer."
    }
    $iterationId = [int]$iterationValue
    if ($iterationId -lt 1 -or $iterationId -gt 4096) {
        New-ReviewerCohortEntryRefusal -Code 'CE210' -Detail "The change set reports iterationId $iterationId."
    }
    return [pscustomobject][ordered]@{
        IterationId = $iterationId
        SourceCommit = $Identity.SourceCommit
        CommonCommit = $Identity.CommonCommit
        TargetCommit = $Identity.TargetCommit
    }
}

# ---------------------------------------------------------------------------
# Ordinal census
# ---------------------------------------------------------------------------

function Get-ReviewerCohortEntryChangedPathCensus {
    <#
    .SYNOPSIS
        The ordinal changed-path census: every authoritative path once, in one
        declared order, with its change kinds.

    .DESCRIPTION
        The order is ORDINAL - assigned here by ordinal sort of the path - and
        not the order the provider happened to page them in. Two captures of one
        iteration must produce the same census bytes or the digest that binds a
        corpus to an entry means nothing, and a provider is under no obligation
        to page consistently.

        A duplicate path is a refusal rather than a de-duplication. A change set
        that names one path twice is either two change kinds the caller has to
        see or a paging fault the caller has to know about, and silently keeping
        the first is how a delete-then-add became an edit in an earlier census.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Changes,
        [Parameter(Mandatory)]$Request
    )
    # The wrapper contract answers 'changes'. The RAW Azure DevOps iteration-changes
    # shape answers 'changeEntries', and the two are not interchangeable: the raw
    # entry carries changeTrackingId and originalObjectId that the contract drops,
    # and reading one where the other was declared is the exact raw-versus-contract
    # confusion CE203 exists for. It is named here rather than tolerated.
    $rawShapeNames = @('changeEntries')
    foreach ($rawName in $rawShapeNames) {
        $rawProperty = $null
        if ($Changes -is [System.Collections.IDictionary]) { $rawProperty = $Changes.Contains($rawName) }
        elseif ($null -ne $Changes) { $rawProperty = ($null -ne $Changes.PSObject.Properties[$rawName]) }
        if ($rawProperty) {
            New-ReviewerCohortEntryRefusal -Code 'CE203' `
                -Detail "The change set answered with the raw provider key '$rawName'; the wrapper contract answers 'changes'."
        }
    }
    [void](Get-ReviewerCohortEntryProperty -Object $Changes -Name 'changes' -Where 'change set' -Code 'CE210')
    # An ARRAY, checked as one, and read WITHOUT the pipeline so PowerShell's own
    # single-element unrolling cannot decide the answer for us. A provider that
    # answers a one-change pull request with a bare object rather than a
    # one-element array is answering a different contract, and a bare @() would
    # quietly paper over it - which is how a singleton change set once produced a
    # census that looked complete and a corpus missing every other path in a
    # later, larger iteration.
    $rawEntries = $null
    if ($Changes -is [System.Collections.IDictionary]) {
        $rawEntries = $Changes['changes']
    }
    else {
        $rawEntries = $Changes.PSObject.Properties['changes'].Value
    }
    if ($rawEntries -is [string] -or $rawEntries -isnot [System.Collections.IList]) {
        New-ReviewerCohortEntryRefusal -Code 'CE210' `
            -Detail "The change set's 'changes' is not an array; a single change is a one-element array, not a bare object."
    }
    $entries = @($rawEntries)
    if ($entries.Count -gt $Request.MaxChangedFiles) {
        New-ReviewerCohortEntryRefusal -Code 'CE402' `
            -Detail "The change set carries $($entries.Count) entries and the request caps changed files at $($Request.MaxChangedFiles)."
    }
    # An empty authoritative census is refused rather than published. A package
    # built from it would declare 100% coverage of nothing and an empty
    # changedPaths, and the typed coordinator refuses an empty changed-path
    # contract outright - so the only thing publishing it can produce is a sealed
    # package that no cohort can ever run.
    if ($entries.Count -eq 0) {
        New-ReviewerCohortEntryRefusal -Code 'CE407' `
            -Detail 'The change set names no changed path; there is no subject to prepare.'
    }
    $byPath = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        # The path lives under 'item', where the contract puts it. Reading a bare
        # 'path' off the entry would silently accept the raw shape one level up.
        $item = Get-ReviewerCohortEntryProperty -Object $entry -Name 'item' -Where 'change entry' -Code 'CE210'
        $path = [string](Get-ReviewerCohortEntryProperty -Object $item -Name 'path' -Where 'change entry item' -Code 'CE210')
        Assert-ReviewerCohortEntryRepositoryRelativePath -Path $path -Where 'change entry'
        if ($byPath.ContainsKey($path)) {
            New-ReviewerCohortEntryRefusal -Code 'CE401' -Detail "The change set names '$path' twice."
        }
        # Lower-cased once, here. The wrapper answers 'Edit' and the reviewer's
        # own corpus records 'edit'; every later comparison in this builder is
        # ordinal, so the single normalization has to happen at the boundary or
        # every one of them has to remember to be case-insensitive.
        $changeType = ([string](Get-ReviewerCohortEntryProperty -Object $entry -Name 'changeType' -Where "change entry '$path'" -Code 'CE210')).ToLowerInvariant()
        $hasRightHand = $changeType -cne 'delete'
        $byPath[$path] = [pscustomobject][ordered]@{
            Path = $path
            ChangeType = $changeType
            HasRightHand = $hasRightHand
        }
    }
    $ordered = [string[]]@($byPath.Keys)
    [Array]::Sort($ordered, [StringComparer]::Ordinal)

    $census = [System.Collections.Generic.List[object]]::new()
    $ordinal = 1
    foreach ($path in $ordered) {
        $record = $byPath[$path]
        [void]$census.Add([pscustomobject][ordered]@{
                Ordinal = $ordinal
                Path = $record.Path
                ChangeType = $record.ChangeType
                HasRightHand = $record.HasRightHand
            })
        $ordinal++
    }
    return [object[]]$census.ToArray()
}

function Get-ReviewerCohortEntryThreadRecords {
    <#
    .SYNOPSIS
        The thread list, read exactly the way the reviewer reads it.

    .DESCRIPTION
        The live wrapper answers 'repo_pull_request_thread list' with a BARE JSON
        array of threads, not a {"value":[...]} envelope. The reviewer's own
        ConvertTo-ReviewerFactThreadSet accepts the bare array and also unwraps a
        'threads' or 'value' envelope, so this builder accepts exactly that set
        and nothing else. Assuming the envelope - which an operator assembling
        evidence from REST documentation naturally does, because the raw REST
        endpoint DOES return {"value":[...]} - refuses every live capture at
        CE210 while the reviewer itself would have read the same bytes happily.
        That divergence is the defect this function exists to close.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Threads)
    if ($null -eq $Threads) {
        New-ReviewerCohortEntryRefusal -Code 'CE210' -Detail 'The thread list is absent.'
    }
    if ($Threads -is [string]) {
        New-ReviewerCohortEntryRefusal -Code 'CE210' -Detail 'The thread list answered a string, not threads.'
    }
    if ($Threads -is [System.Collections.IList]) { return [object[]]@($Threads) }
    foreach ($key in @('threads', 'value')) {
        $inner = $null
        if ($Threads -is [System.Collections.IDictionary]) {
            if ($Threads.Contains($key)) { $inner = $Threads[$key] }
        }
        elseif ($null -ne $Threads.PSObject.Properties[$key]) {
            $inner = $Threads.PSObject.Properties[$key].Value
        }
        if ($null -eq $inner) { continue }
        if ($inner -is [string] -or $inner -isnot [System.Collections.IList]) {
            New-ReviewerCohortEntryRefusal -Code 'CE210' `
                -Detail "The thread list's '$key' is not an array; a single thread is a one-element array, not a bare object."
        }
        return [object[]]@($inner)
    }
    New-ReviewerCohortEntryRefusal -Code 'CE210' `
        -Detail "The thread list is neither an array nor an envelope carrying 'threads' or 'value'."
}

function Assert-ReviewerCohortEntryCensusOrder {
    <#
    .SYNOPSIS
        Requires a census to be exactly what an ordinal census is: ordinals 1..n
        with no gap, paths in ascending ordinal order, no duplicates.

    .DESCRIPTION
        Checked over the census as a VALUE rather than trusted because the
        builder produced it. This is the predicate the tests sabotage, and it is
        the predicate the published package's own re-verification runs, so a
        census that was reordered after it was built is caught by the same rule
        that built it.
    #>
    param([Parameter(Mandatory)][object[]]$Census)
    $previousPath = ''
    $expected = 1
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $Census) {
        if ([int]$record.Ordinal -ne $expected) {
            New-ReviewerCohortEntryRefusal -Code 'CE400' `
                -Detail "Position $expected declares ordinal $([int]$record.Ordinal)."
        }
        $path = [string]$record.Path
        if (-not $seen.Add($path)) {
            New-ReviewerCohortEntryRefusal -Code 'CE401' -Detail "The census names '$path' twice."
        }
        if ($previousPath -ne '' -and [string]::CompareOrdinal($previousPath, $path) -ge 0) {
            New-ReviewerCohortEntryRefusal -Code 'CE400' `
                -Detail "The census places '$path' after '$previousPath', which is not ascending ordinal order."
        }
        $previousPath = $path
        $expected++
    }
}

function Get-ReviewerCohortEntryLineCount {
    <#
    .SYNOPSIS
        How many lines one captured file text has, counted the way a line span
        counts them.

    .DESCRIPTION
        Line 1 is the first line, and a trailing newline does not create an empty
        line after it - a file ending "b`n" has two lines, not three. Off by one
        here would refuse a legitimate span that touches the last line of a file,
        or admit one that runs a line past the end of it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text.Length -eq 0) { return 0 }
    $normalized = $Text.Replace("`r`n", "`n")
    if ($normalized.EndsWith("`n")) { $normalized = $normalized.Substring(0, $normalized.Length - 1) }
    if ($normalized.Length -eq 0) { return 1 }
    return (@($normalized -split "`n").Count)
}

function Get-ReviewerCohortEntrySpanEvidence {
    <#
    .SYNOPSIS
        The right-hand line spans for one changed file, checked against the file
        it is a span of.

    .DESCRIPTION
        A span that starts past the end of the file, counts zero lines, or
        overlaps the span before it is refused. Every one of those has been
        published by a hand-assembled span list, and each of them makes the
        reviewer read bytes that are not the bytes the span claims.

        The spans handed in come from the reviewer's own right-hand extractor
        over the diff variant; what happens here is the half that extractor
        cannot do, because it never reads the file: comparing each span against
        the line count of the bytes this build captured at the source commit.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Spans,
        [Parameter(Mandatory)][int]$LineCount,
        [Parameter(Mandatory)][string]$Path
    )
    $list = @($Spans)
    $result = [System.Collections.Generic.List[object]]::new()
    $previousEnd = 0
    foreach ($span in $list) {
        $start = [int](Get-ReviewerCohortEntryProperty -Object $span -Name 'start' -Where "span for '$Path'" -Code 'CE404')
        $count = [int](Get-ReviewerCohortEntryProperty -Object $span -Name 'count' -Where "span for '$Path'" -Code 'CE404')
        if ($count -lt 1) {
            New-ReviewerCohortEntryRefusal -Code 'CE404' -Detail "A span for '$Path' counts $count lines."
        }
        if ($start -lt 1 -or $start -gt $LineCount) {
            New-ReviewerCohortEntryRefusal -Code 'CE404' `
                -Detail "A span for '$Path' starts at line $start of a $LineCount-line file."
        }
        if (($start + $count - 1) -gt $LineCount) {
            New-ReviewerCohortEntryRefusal -Code 'CE404' `
                -Detail "A span for '$Path' ends at line $($start + $count - 1) of a $LineCount-line file."
        }
        if ($start -le $previousEnd) {
            New-ReviewerCohortEntryRefusal -Code 'CE404' `
                -Detail "A span for '$Path' starts at line $start, at or before the previous span's last line $previousEnd."
        }
        $previousEnd = $start + $count - 1
        [void]$result.Add([ordered]@{ start = $start; count = $count })
    }
    return [object[]]$result.ToArray()
}

function Measure-ReviewerCohortEntryCoverage {
    <#
    .SYNOPSIS
        The changed-path content coverage this capture reached, and a refusal
        when it is under the declared floor.

    .DESCRIPTION
        Coverage is the share of the WHOLE census whose right-hand content this
        build actually stored. Measuring it over the right-hand paths alone
        would divide a set by itself - every right-hand read is mandatory and a
        failed one aborts the build - so the ratio would be the constant 100 and
        the operator's floor would be a knob wired to nothing.

        Over the whole census it measures something real and subject-dependent:
        a pull request that is mostly deletions carries content for only a small
        part of what it changed, and an operator assembling a cohort may
        legitimately refuse such a subject rather than review it on evidence
        that is mostly absent. A floor of 1 accepts any subject with content at
        all, which is the permissive setting for operators who do not care.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Census,
        [Parameter(Mandatory)][int]$CoveredCount,
        [Parameter(Mandatory)][int]$MinimumPercent
    )
    $eligible = [object[]]@($Census | Where-Object { [bool]$_.HasRightHand })
    if ($Census.Count -eq 0) {
        return [pscustomobject][ordered]@{ CensusCount = 0; EligibleCount = 0; CoveredCount = 0; Percent = 0 }
    }
    if ($CoveredCount -ne $eligible.Count) {
        New-ReviewerCohortEntryRefusal -Code 'CE403' `
            -Detail "The capture stored $CoveredCount right-hand payloads for $($eligible.Count) right-hand paths; a right-hand path without its content is not covered."
    }
    $percent = [int][Math]::Floor(($CoveredCount * 100.0) / $Census.Count)
    if ($percent -lt $MinimumPercent) {
        New-ReviewerCohortEntryRefusal -Code 'CE403' `
            -Detail "The capture stored content for $CoveredCount of $($Census.Count) changed paths ($percent%), under the declared floor of $MinimumPercent%."
    }
    return [pscustomobject][ordered]@{
        CensusCount = $Census.Count
        EligibleCount = $eligible.Count
        CoveredCount = $CoveredCount
        Percent = $percent
    }
}
