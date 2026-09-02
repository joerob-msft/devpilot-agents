<#
    bpm-test-ownership@1: the capability's own checks.

    Two things are proved here, and they are different things.

    The first is that the OWNER RULE can be read off a change set at all - that
    a combined attribute list is not mistaken for a missing attribute, that a
    comma inside an attribute's arguments is not mistaken for another attribute,
    and that context the wrapper never read is reported unknown rather than as
    an absence. Those are the cases that decide precision, and a false positive
    here is worse than a miss: it tells an engineer their compliant code is
    wrong.

    The second is that a correct answer SURVIVES the trip back. The live replay
    of PR16991680 produced the right finding in one slot and lost it in the
    other, because one candidate cited a declaration-census id in a field that
    only accepted review-fact ids and the whole marker was refused. Contract v3
    is checked here against that exact recorded marker.
#>

param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
. (Join-Path $RepoRoot 'src\Agents\reviewer\ChangedConstructs.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\SourceTransport.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\ConventionSpecialist.ps1')

$script:OwnerChecks = 0
$script:OwnerFailures = [System.Collections.Generic.List[string]]::new()

function Get-OwnerUnionAnchors {
    <#
        The union of every accepted candidate's changed-line anchors.

        THIS is what convention coverage means. A rule's violations may be
        published as one candidate or as one per file - both are correct, and
        which one a model produces is not a measure of whether it found the
        violations. Counting only the first candidate's anchors is how a run that
        found all nine declarations and split them across two accepted candidates
        was scored as finding eight.
    #>
    param([AllowEmptyCollection()][object[]]$Candidates = @())
    $union = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($Candidates)) {
        $targets = @([string]$candidate.primaryTarget) + @(([string]$candidate.manifestations) -split ',')
        foreach ($target in $targets) {
            $trimmed = ([string]$target).Trim()
            if ($trimmed -and $union -cnotcontains $trimmed) { [void]$union.Add($trimmed) }
        }
    }
    $sorted = [string[]]@($union.ToArray())
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return , $sorted
}

function Assert-Owner {
    param([bool]$Condition, [string]$Message)
    $script:OwnerChecks++
    if (-not $Condition) { [void]$script:OwnerFailures.Add($Message) }
}

$corpusPath = Join-Path $RepoRoot 'tools\testdata\reviewer-owner-convention-corpus.v1.json'
$corpus = Get-Content -LiteralPath $corpusPath -Raw | ConvertFrom-Json
Assert-Owner ([int]$corpus.corpusVersion -eq 1) "The ownership corpus is not version 1."
Assert-Owner ([string]$corpus.capability -ceq 'bpm-test-ownership@1') "The ownership corpus names the wrong capability."

# The rule governs declarations. A rule that claims to reach invocations,
# comments and assignments has claimed to have weighed things it cannot weigh.
Assert-Owner ((@($corpus.rule.scope) -join ',') -ceq 'declaration') `
    "The ownership rule's scope is not exactly 'declaration'."

# The authoritative text covers classes AND methods. The target repository's own
# instructions say methods only; transporting that weaker phrasing instead is
# precisely the delivery defect this capability exists to correct.
Assert-Owner ([string]$corpus.rule.semantics -match 'CLASSES') "The corpus lost the class scope of the ownership rule."
Assert-Owner ([string]$corpus.rule.semantics -match 'METHODS') "The corpus lost the method scope of the ownership rule."

# ---------------------------------------------------------------------------
# Attribute shape. Every source-bearing case is run through the real lexer.
# ---------------------------------------------------------------------------
foreach ($case in @($corpus.cases)) {
    if (-not $case.PSObject.Properties['source']) { continue }
    $lines = [string[]]@($case.source)
    $masked = @((Get-ReviewerConstructMaskedLines -Lines $lines).Lines)
    $declaration = Get-ReviewerConstructDeclarationAt -MaskedLines $masked -Index ([int]$case.declarationLine - 1)
    Assert-Owner ($null -ne $declaration) "Corpus case '$($case.id)': the declaration was not recognized at all."
    if ($null -eq $declaration) { continue }

    $actual = (@($declaration.Attributes) -join ',')
    $expected = (@($case.expectedAttributes) -join ',')
    Assert-Owner ($actual -ceq $expected) `
        "Corpus case '$($case.id)': attributes read as [$actual]; expected [$expected]."

    # A shape the wrapper could not establish must never be reported as a
    # complete attribute list, because "complete and without Owner" is a
    # finding and "incomplete" is not.
    Assert-Owner (-not ([bool]$declaration.Truncated -or [bool]$declaration.ShapeUncertain)) `
        "Corpus case '$($case.id)': a fully readable declaration was marked incomplete."

    $carriesOwner = (@($declaration.Attributes) -ccontains 'Owner')
    if ([string]$case.expect -ceq 'compliant') {
        Assert-Owner $carriesOwner "Corpus case '$($case.id)': a compliant declaration did not read as carrying Owner."
    }
    elseif ([string]$case.expect -ceq 'violation') {
        Assert-Owner (-not $carriesOwner) "Corpus case '$($case.id)': a violating declaration read as carrying Owner."
    }
}

# The combined-list case is the one that decides precision, so it is asserted
# by name rather than only as part of the sweep above.
$combined = @($corpus.cases | Where-Object { [string]$_.id -ceq 'method-owner-combined-list' })
Assert-Owner ($combined.Count -eq 1) "The corpus lost its combined-attribute-list case."
if ($combined.Count -eq 1) {
    $masked = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@($combined[0].source))).Lines)
    $declaration = Get-ReviewerConstructDeclarationAt -MaskedLines $masked -Index ([int]$combined[0].declarationLine - 1)
    Assert-Owner ((@($declaration.Attributes) -ccontains 'Owner') -and (@($declaration.Attributes) -ccontains 'TestMethod')) `
        "[TestMethod, Owner(...)] did not yield both attributes: a compliant declaration would be reported as a violation."
}

# An unreadable group yields no name and marks the declaration uncertain. It
# must not silently produce a short, confident attribute list.
$unreadable = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@(
                '[TestMethod, 9invalid]',
                'public void GivenSomethingItDoesSomething()'))).Lines)
$unreadableDeclaration = Get-ReviewerConstructDeclarationAt -MaskedLines $unreadable -Index 1
Assert-Owner ($null -ne $unreadableDeclaration -and ([bool]$unreadableDeclaration.Truncated -or [bool]$unreadableDeclaration.ShapeUncertain)) `
    "An unreadable attribute segment did not mark the declaration incomplete."

# A group that never closes is not a declaration the wrapper will speak about.
$unclosed = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@(
                '[TestMethod',
                'public void GivenSomethingItDoesSomething()'))).Lines)
Assert-Owner ($null -eq (Get-ReviewerConstructDeclarationAt -MaskedLines $unclosed -Index 0)) `
    "An unclosed attribute group was accepted as a declaration."

# ---------------------------------------------------------------------------
# Contract v2 is frozen; contract v3 carries the reduced, wrapper-owned shape.
# ---------------------------------------------------------------------------
$v2 = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject 'One' -ExpectedNonce ('a' * 36) -ContractVersion 2
$v3 = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject 'One' -ExpectedNonce ('a' * 36) -ContractVersion 3
$v2Keys = @($v2.Fields.candidates.Item.Keys)
$v3Keys = @($v3.Fields.candidates.Item.Keys)

foreach ($owned in @('filePath', 'line', 'packName', 'ruleSourceId', 'ruleSourceRepositoryId',
        'ruleSourcePath', 'ruleSourceCommit', 'ruleSourceSha256')) {
    Assert-Owner ($v2Keys -ccontains $owned) "Contract v2 lost '$owned'; v2 is frozen and must not change shape."
    Assert-Owner ($v3Keys -cnotcontains $owned) "Contract v3 still asks the model to retype '$owned'."
}
Assert-Owner ($v3Keys -ccontains 'ruleRef') "Contract v3 does not ask for ruleRef."
Assert-Owner ($v2Keys -cnotcontains 'ruleRef') "Contract v2 gained ruleRef; v2 is frozen."
Assert-Owner ($v3Keys.Count -eq $v2Keys.Count - 7) `
    "Contract v3 candidate keys ($($v3Keys.Count)) are not v2's ($($v2Keys.Count)) less eight plus ruleRef."

# The census id an adoption rule depends on must be citable.
Assert-Owner ('rdf1:' + ('a' * 64) -cmatch $v3.Fields.candidates.Item.Fields.factIds.Pattern) `
    "Contract v3 still refuses a declaration-census id in factIds."
Assert-Owner ('rf1:' + ('a' * 64) -cmatch $v3.Fields.candidates.Item.Fields.factIds.Pattern) `
    "Contract v3 refuses a review-fact id in factIds."
Assert-Owner (-not ('rdf1:' + ('a' * 64) -cmatch $v2.Fields.candidates.Item.Fields.factIds.Pattern)) `
    "Contract v2's factIds rule changed; v2 is frozen."

# Degradation is opt-in, and opted in only where it is needed.
Assert-Owner ([string]$v3.Fields.candidates.ElementFailurePolicy -ceq 'drop') `
    "Contract v3 does not withhold a single unreadable candidate."
Assert-Owner ([string]$v2.Fields.candidates.ElementFailurePolicy -ceq 'fail') `
    "Contract v2 no longer fails closed on a bad candidate; v2 is frozen."

# The largest legal marker must still fit the window it will actually be read
# through - the specialist's own 327680-char window, not the harness default.
$specialistWindow = 327680
$fit = Test-AgentMarkerSchemaFitsScanWindow -Schema $v3 -ScanWindowChars $specialistWindow
Assert-Owner ([bool]$fit.Fits) `
    "The v3 contract's largest legal marker ($($fit.WorstCaseChars) chars) does not fit the $($fit.WindowChars)-char scan window."
$v2Fit = Test-AgentMarkerSchemaFitsScanWindow -Schema $v2 -ScanWindowChars $specialistWindow
Assert-Owner ([int]$fit.WorstCaseChars -lt [int]$v2Fit.WorstCaseChars) `
    "Contract v3 did not shrink the largest legal marker (v3 $($fit.WorstCaseChars) vs v2 $($v2Fit.WorstCaseChars))."

# ---------------------------------------------------------------------------
# The recorded live marker. Under v2 this exact text was refused whole; the
# Owner finding it contained has to come back under v3.
# ---------------------------------------------------------------------------
$recordedPath = Join-Path $RepoRoot 'tools\testdata\reviewer-owner-recorded-marker.v1.json'
if (Test-Path -LiteralPath $recordedPath) {
    $recorded = Get-Content -LiteralPath $recordedPath -Raw
    $recordedObject = $recorded | ConvertFrom-Json
    $project = [string]$recordedObject.project
    $nonce = [string]$recordedObject.nonce

    $v2Schema = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject $project -ExpectedNonce $nonce -ContractVersion 2
    $v2Outcome = ConvertFrom-AgentResultMarkerOutcome -StdOutText "CONVENTION_REVIEW_RESULT_V2: $recorded" `
        -MarkerPrefix 'CONVENTION_REVIEW_RESULT_V2:' -Schema $v2Schema
    Assert-Owner ([string]$v2Outcome.Status -cne 'success') `
        "The recorded marker no longer reproduces the live loss; the regression it guards is gone."
    Assert-Owner ([string]$v2Outcome.Field -like '*factIds*') `
        "The recorded loss is no longer attributed to factIds (field '$($v2Outcome.Field)')."

    # The same answer in the shape v3 asks for: no retyped provenance, ruleRef
    # instead. Nothing about the finding itself is altered.
    $wrapperOwned = @('filePath', 'line', 'packName', 'ruleSourceId', 'ruleSourceRepositoryId',
        'ruleSourcePath', 'ruleSourceCommit', 'ruleSourceSha256')
    $v3Object = $recorded | ConvertFrom-Json
    $v3Object.schemaVersion = 3
    $rewritten = @()
    foreach ($candidate in @($v3Object.candidates)) {
        $shaped = [ordered]@{}
        foreach ($property in $candidate.PSObject.Properties) {
            if ($wrapperOwned -contains $property.Name) { continue }
            $shaped[$property.Name] = $property.Value
        }
        $shaped['ruleRef'] = 'rs0'
        $rewritten += [pscustomobject]$shaped
    }
    $v3Object.candidates = $rewritten
    $v3Json = $v3Object | ConvertTo-Json -Depth 24 -Compress

    $v3Schema = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject $project -ExpectedNonce $nonce -ContractVersion 3
    $v3Outcome = ConvertFrom-AgentResultMarkerOutcome -StdOutText "CONVENTION_REVIEW_RESULT_V3: $v3Json" `
        -MarkerPrefix 'CONVENTION_REVIEW_RESULT_V3:' -Schema $v3Schema
    Assert-Owner ([string]$v3Outcome.Status -ceq 'success') `
        "Contract v3 refused the recorded answer (status '$($v3Outcome.Status)', field '$($v3Outcome.Field)')."

    if ([string]$v3Outcome.Status -ceq 'success') {
        $owner = @(@($v3Outcome.Value.candidates) | Where-Object { [string]$_.candidateId -like '*owner*' })
        Assert-Owner ($owner.Count -ge 1) "The recovered marker does not contain the Owner finding."
        if ($owner.Count -ge 1) {
            Assert-Owner (@($owner | Where-Object { [string]$_.factIds -like 'rdf1:*' }).Count -ge 1) `
                "The Owner finding no longer cites the declaration census it rests on."
            # Coverage is the UNION of every accepted candidate's anchors, not a
            # property of one chosen candidate. A model that answers per file and
            # one that answers in a single block are both right, and the metric
            # that scored the second as a miss is the metric that produced a
            # NO-GO for a semantically perfect run.
            $ownerAnchors = Get-OwnerUnionAnchors -Candidates $owner
            Assert-Owner ($ownerAnchors.Count -eq 9) `
                "The Owner finding's union anchor coverage is $($ownerAnchors.Count), not the nine expected declarations."
            Assert-Owner ($ownerAnchors -ccontains 'cf4:69') `
                "The Owner finding's union coverage lost the recorded first anchor cf4:69."
        }
        Assert-Owner (@($v3Outcome.Value.ruleCoverage).Count -ge 1) `
            "The rule-coverage row was lost along with the provenance fields."
    }

    # One unrelated candidate goes bad. The Owner finding must not go with it,
    # and the loss must be reported rather than shortening the list in silence.
    $sabotaged = $v3Json | ConvertFrom-Json
    if (@($sabotaged.candidates).Count -ge 2) {
        @($sabotaged.candidates)[1].candidateId = 'NOT A VALID CANDIDATE ID'
        $sabotagedOutcome = ConvertFrom-AgentResultMarkerOutcome `
            -StdOutText ("CONVENTION_REVIEW_RESULT_V3: " + ($sabotaged | ConvertTo-Json -Depth 24 -Compress)) `
            -MarkerPrefix 'CONVENTION_REVIEW_RESULT_V3:' -Schema $v3Schema
        Assert-Owner ([string]$sabotagedOutcome.Status -ceq 'success') `
            "One unreadable candidate still sinks the whole marker under v3."
        $survivors = @(@($sabotagedOutcome.Value.candidates) | ForEach-Object { [string]$_.candidateId })
        Assert-Owner ($survivors.Count -eq 1 -and $survivors[0] -like '*owner*') `
            "The Owner finding did not survive a broken sibling (survivors: $($survivors -join ', '))."
        Assert-Owner (@($sabotagedOutcome.DroppedElements).Count -eq 1) `
            "A withheld candidate was not reported, so a shortened list reads as a clean review."
    }

    # Binding is not negotiable, in either contract.
    $foreign = $v3Json | ConvertFrom-Json
    $foreign.project = 'AForeignProject'
    $foreignOutcome = ConvertFrom-AgentResultMarkerOutcome `
        -StdOutText ("CONVENTION_REVIEW_RESULT_V3: " + ($foreign | ConvertTo-Json -Depth 24 -Compress)) `
        -MarkerPrefix 'CONVENTION_REVIEW_RESULT_V3:' -Schema $v3Schema
    Assert-Owner ([string]$foreignOutcome.Status -ceq 'wrongBinding') `
        "A marker bound to a foreign project was not refused outright under v3."
}
else {
    Assert-Owner $false "The recorded live marker fixture is missing at $recordedPath."
}

# An unreadable element's identifier must never be able to compose a line.
# A rejected key's NAME is model-authored text that no field rule ever sees -
# the key is refused before any rule is consulted - and it ends up in an
# artifact a person reads to decide whether a finding is real. A key named with
# newlines and Markdown could forge whole sections of that artifact, under the
# artifact's own integrity hash, and read as authentic.
$injectionKey = "x`nINJECTED`n### forged-candidate`n- Severity: important`n- Impact: reviewed and clean"
$injectionSchema = @{
    Keys = @('nonce', 'candidates')
    Fields = @{
        nonce = @{ Type = 'exact'; Expected = 'n1' }
        candidates = @{
            Type = 'objectArray'; MaxItems = 4; ElementFailurePolicy = 'drop'
            Item = @{ Keys = @('id'); Fields = @{ id = @{ Type = 'string'; MaxLength = 8; Pattern = '^[a-z]+$' } } }
        }
    }
}
$injectionPayload = [pscustomobject]@{
    nonce = 'n1'
    candidates = @([pscustomobject]@{ id = 'aaa'; $injectionKey = 1 }, [pscustomobject]@{ id = 'bbb' })
}
$injectionOutcome = ConvertFrom-AgentResultMarkerOutcome `
    -StdOutText ("OWNER_PROBE_V1: " + ($injectionPayload | ConvertTo-Json -Depth 8 -Compress)) `
    -MarkerPrefix 'OWNER_PROBE_V1:' -Schema $injectionSchema
Assert-Owner ([string]$injectionOutcome.Status -ceq 'success') `
    "The injection probe marker did not parse (status '$($injectionOutcome.Status)')."
Assert-Owner (@($injectionOutcome.DroppedElements).Count -eq 1) `
    "The element carrying an unexpected key was not withheld."
if (@($injectionOutcome.DroppedElements).Count -eq 1) {
    $reportedField = [string](@($injectionOutcome.DroppedElements)[0].Field)
    Assert-Owner ($reportedField -cnotmatch '[\r\n]') `
        "A withheld element's reported identifier carried a newline: it can forge lines in a rendered artifact."
    Assert-Owner ($reportedField -cnotmatch '#') `
        "A withheld element's reported identifier carried Markdown heading syntax."
    Assert-Owner (-not $reportedField.Contains('Severity')) `
        "A withheld element's reported identifier carried the model's own text verbatim."
    Assert-Owner ($reportedField -cmatch '^[A-Za-z0-9_.\[\]~-]+$') `
        "A withheld element's reported identifier is not a safe token ('$reportedField')."
}
# The surviving sibling is still returned: containment must not cost the answer.
Assert-Owner (@($injectionOutcome.Value.candidates).Count -eq 1) `
    "The readable sibling of an injected element was lost."

# A key of otherwise-safe characters ending in ONE newline. In .NET `$` matches
# before a final newline, so an anchor of `$` rather than `\z` lets exactly this
# variant through with the break intact - and a test that only tries an EMBEDDED
# newline certifies an invariant that does not hold.
$trailingKey = "Severity_important_reviewed_clean`n"
$trailingPayload = [pscustomobject]@{
    nonce = 'n1'
    candidates = @([pscustomobject]@{ id = 'aaa'; $trailingKey = 1 })
}
$trailingOutcome = ConvertFrom-AgentResultMarkerOutcome `
    -StdOutText ("OWNER_PROBE_V1: " + ($trailingPayload | ConvertTo-Json -Depth 8 -Compress)) `
    -MarkerPrefix 'OWNER_PROBE_V1:' -Schema $injectionSchema
Assert-Owner (@($trailingOutcome.DroppedElements).Count -eq 1) `
    "The element carrying a trailing-newline key was not withheld."
if (@($trailingOutcome.DroppedElements).Count -eq 1) {
    $trailingField = [string](@($trailingOutcome.DroppedElements)[0].Field)
    Assert-Owner ($trailingField -cnotmatch '[\r\n]') `
        "A trailing newline survived into a withheld element's reported identifier ('$trailingField')."
}

# Regressions found in review. Each of these was a way for the lexer to be
# CONFIDENTLY WRONG, which is worse than being unsure: an invented attribute
# reads as a rule already satisfied and hides a real violation, and a dropped
# group reports compliant code as a violation. Both must be `unknown`.
foreach ($shape in @(
        @{ Name = 'generic attribute'; Lines = @('[Owner<A,B>]', 'public void A()') },
        @{ Name = 'generic attribute naming Owner'; Lines = @('[GenericAttr<int, Owner>]', 'public void A()') },
        @{ Name = 'group wrapped across lines'; Lines = @('[TestMethod,', 'Owner("alias")]', 'public void A()') },
        @{ Name = 'trailing junk after an attribute'; Lines = @('[Owner("alias") junk]', 'public void A()') },
        # A wrapped group whose closing line contains '[' inside an argument.
        # "Contains no bracket" declined to flag exactly these, and they are the
        # common real shape: an array, a typeof, an indexer.
        @{ Name = 'wrapped group closing on an array argument'; Lines = @('[Owner("alias"),', 'DataRow(new object[] { 1, 2 })]', 'public void A()') },
        @{ Name = 'wrapped group closing on a typeof argument'; Lines = @('[Owner("alias"),', 'DataRow(typeof(int[]))]', 'public void A()') }
    )) {
    $shapeMasked = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@($shape.Lines))).Lines)
    $shapeDeclaration = Get-ReviewerConstructDeclarationAt -MaskedLines $shapeMasked -Index ($shape.Lines.Count - 1)
    Assert-Owner ($null -ne $shapeDeclaration) "Shape '$($shape.Name)': the declaration was not recognized."
    if ($null -ne $shapeDeclaration) {
        Assert-Owner (@($shapeDeclaration.Attributes).Count -eq 0) `
            "Shape '$($shape.Name)': invented attribute(s) [$(@($shapeDeclaration.Attributes) -join ',')]."
        Assert-Owner (([bool]$shapeDeclaration.Truncated -or [bool]$shapeDeclaration.ShapeUncertain)) `
            "Shape '$($shape.Name)': an unreadable attribute shape was reported as a complete, established fact."
    }
}

# A comment between two attribute lines is masked to spaces before the scan, so
# it is indistinguishable from a blank line. Stopping there drops every
# attribute above it; calling the remainder complete turns owned code into a
# violation.
$commentSplit = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@(
                '[Owner("alias")]',
                '// Tracked by work item 12345.',
                '[TestMethod]',
                'public void A()'))).Lines)
$commentDeclaration = Get-ReviewerConstructDeclarationAt -MaskedLines $commentSplit -Index 3
Assert-Owner ($null -ne $commentDeclaration -and ([bool]$commentDeclaration.Truncated -or [bool]$commentDeclaration.ShapeUncertain)) `
    "An attribute list interrupted by a comment was reported as complete, losing the attributes above it."

# An unread line directly above a declaration is ignorance, not absence.
$sparse = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@(
                '[Owner("alias")]',
                '[TestMethod]',
                'public void A()'))).Lines)
$deliveredOnly = [System.Collections.Generic.HashSet[int]]::new()
[void]$deliveredOnly.Add(3)
$sparseDeclaration = Get-ReviewerConstructDeclarationAt -MaskedLines $sparse -Index 2 -Delivered $deliveredOnly
Assert-Owner ($null -ne $sparseDeclaration -and ([bool]$sparseDeclaration.Truncated -or [bool]$sparseDeclaration.ShapeUncertain)) `
    "A declaration whose attribute lines were never delivered was reported as carrying no attributes."

# The trial-1 regression. An unread line above ONE declaration used to be
# laundered into the file-wide attribute flag, which marked EVERY declaration in
# the file unknown. In the live trial that turned all nine changed test methods
# into unknowns, the specialist correctly refused to call an unknown a
# violation, and the capability reported nothing at all. Doubt about one
# declaration's own shape must stay with that declaration.
$mixedLines = [string[]]@(
    '[TestMethod]',
    'public void OwnedElsewhere()',
    '{',
    '}',
    '[TestMethod]',
    'public void AlsoChanged()')
$mixedMasked = @((Get-ReviewerConstructMaskedLines -Lines $mixedLines).Lines)
# Build the index the way production does - through the delivered set - or the
# records carry no uncertainty at all and the test cannot discriminate.
$mixedDelivered = @(2, 3, 4, 5, 6)
$mixedIndex = Get-ReviewerConstructDeclarationIndex -MaskedLines $mixedMasked -DeliveredLines $mixedDelivered
# Only the SECOND declaration changed, so the first is an unchanged neighbour -
# which is the path that feeds the file-wide flag this correction is about.
$mixedResult = Get-ReviewerChangedDeclarations -Path '/src/Tests/WidgetTests.cs' `
    -ChangedLines @(6) -MaskedLines $mixedMasked -DeclarationIndex $mixedIndex `
    -DeliveredLines $mixedDelivered
$mixedSecond = @(@($mixedResult.Constructs) | Where-Object { [int]$_.line -eq 6 })
Assert-Owner ($mixedSecond.Count -eq 1) "The fully delivered declaration was not enumerated."
if ($mixedSecond.Count -eq 1) {
    Assert-Owner ([string]$mixedSecond[0].status -ceq 'known') `
        ("A declaration whose own attribute line WAS delivered was marked '$($mixedSecond[0].status)' " +
        "because a different declaration in the same file sat next to an unread line.")
    Assert-Owner (@($mixedSecond[0].attributes) -ccontains 'TestMethod') `
        "The fully delivered declaration lost its own attribute."
}
# The neighbour itself must still be uncertain - the fix keeps doubt local, it
# does not delete it.
$mixedNeighbour = @($mixedIndex | Where-Object { $null -ne $_ -and [string]$_.Name -ceq 'OwnedElsewhere' })
Assert-Owner ($mixedNeighbour.Count -eq 1 -and
    (Get-ReviewerConstructShapeUncertain -Declaration $mixedNeighbour[0])) `
    "The declaration sitting next to an unread line lost its own uncertainty."

# An unread line directly above a declaration can never be discharged by
# looking further up: that line is the one whose content decides the list.
$unreadAbove = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@(
                '}',
                '[Owner("alias")]',
                'public void GivenSomethingItDoesSomething()'))).Lines)
$unreadDelivered = [System.Collections.Generic.HashSet[int]]::new()
[void]$unreadDelivered.Add(1)
[void]$unreadDelivered.Add(3)
$unreadDeclaration = Get-ReviewerConstructDeclarationAt -MaskedLines $unreadAbove -Index 2 -Delivered $unreadDelivered
Assert-Owner ($null -ne $unreadDeclaration -and
    (Get-ReviewerConstructShapeUncertain -Declaration $unreadDeclaration)) `
    "An unread line directly above a declaration was discharged by a delivered line above IT, claiming absence of an attribute nobody read."

# A long masked comment run between attributes must not fall outside the peek.
$longComment = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@(
                '[Owner("alias")]',
                '// one',
                '// two',
                '// three',
                '// four',
                '[TestMethod]',
                'public void GivenSomethingItDoesSomething()'))).Lines)
$longCommentDeclaration = Get-ReviewerConstructDeclarationAt -MaskedLines $longComment -Index 6
Assert-Owner ($null -ne $longCommentDeclaration -and
    (Get-ReviewerConstructShapeUncertain -Declaration $longCommentDeclaration)) `
    "A four-line comment between attribute lines fell outside the peek, dropping the attributes above it and reporting the list complete."

# A wrapped group's continuation line above a gap is proof the block did not end.
$wrappedAbove = @((Get-ReviewerConstructMaskedLines -Lines ([string[]]@(
                '[TestMethod,',
                'Owner("alias")]',
                '',
                '[TestCategory("Unit")]',
                'public void GivenSomethingItDoesSomething()'))).Lines)
$wrappedAboveDeclaration = Get-ReviewerConstructDeclarationAt -MaskedLines $wrappedAbove -Index 4
Assert-Owner ($null -ne $wrappedAboveDeclaration -and
    (Get-ReviewerConstructShapeUncertain -Declaration $wrappedAboveDeclaration)) `
    "A wrapped-group continuation above the gap was read as an ordinary statement, discharging the doubt it proves."

# An under-counted census must never publish as complete.
$censusLines = [string[]]@(
    '[TestMethod]',
    '[Owner("alias")]',
    'public void A()',
    '{',
    '}',
    '[TestMethod,',
    'Owner("alias")]',
    'public void B()')
$censusMasked = @((Get-ReviewerConstructMaskedLines -Lines $censusLines).Lines)
$censusIndex = Get-ReviewerConstructDeclarationIndex -MaskedLines $censusMasked
$censusFrequency = Get-ReviewerConstructAttributeFrequency -DeclarationIndex $censusIndex
Assert-Owner ([bool]$censusFrequency.Truncated) `
    "A file containing a declaration whose attribute list could not be established published a COMPLETE census, so an under-count becomes a citable 'this file never used it' fact."

# siblingNotRequiredReason is the reason sibling evidence was NOT required.
# Under `checked` there is no such reason and the wrapper insists the field be
# empty, so requiring the model to emit an empty string for it is asking it to
# restate a decision it already made. Three real-model trials lost an otherwise
# correct nine-declaration finding to exactly that omission.
$siblingSchemaV3 = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject 'One' -ExpectedNonce ('a' * 36) -ContractVersion 3
$siblingSchemaV2 = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject 'One' -ExpectedNonce ('a' * 36) -ContractVersion 2
Assert-Owner (@($siblingSchemaV3.Fields.candidates.Item.Keys) -ccontains 'siblingNotRequiredReason') `
    "Contract v3 dropped siblingNotRequiredReason from the key set instead of defaulting it."

if (Test-Path -LiteralPath $recordedPath) {
    $siblingBase = Get-Content -LiteralPath $recordedPath -Raw | ConvertFrom-Json
    $siblingProject = [string]$siblingBase.project
    $siblingNonce = [string]$siblingBase.nonce
    $wrapperOwnedSibling = @('filePath', 'line', 'packName', 'ruleSourceId', 'ruleSourceRepositoryId',
        'ruleSourcePath', 'ruleSourceCommit', 'ruleSourceSha256')

    function New-OwnerSiblingMarker {
        param([string]$Status, [switch]$OmitReason)
        $object = Get-Content -LiteralPath $recordedPath -Raw | ConvertFrom-Json
        $object.schemaVersion = 3
        $shaped = [ordered]@{}
        foreach ($property in (@($object.candidates)[0]).PSObject.Properties) {
            if ($wrapperOwnedSibling -contains $property.Name) { continue }
            $shaped[$property.Name] = $property.Value
        }
        $shaped['ruleRef'] = 'rs0'
        $shaped['siblingStatus'] = $Status
        if ($Status -ceq 'notRequired') { $shaped['siblingEvidence'] = '' }
        if ($OmitReason) { [void]$shaped.Remove('siblingNotRequiredReason') }
        else { $shaped['siblingNotRequiredReason'] = $(if ($Status -ceq 'notRequired') { 'no comparable sibling exists' } else { '' }) }
        $object.candidates = @([pscustomobject]$shaped)
        return ($object | ConvertTo-Json -Depth 24 -Compress)
    }

    $schemaFor = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject $siblingProject -ExpectedNonce $siblingNonce -ContractVersion 3
    # checked + omitted => accepted, and the default is recorded, not silent.
    $checkedOmitted = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome `
        -StdOutText ("CONVENTION_REVIEW_RESULT_V3: " + (New-OwnerSiblingMarker -Status 'checked' -OmitReason)) `
        -Schema $schemaFor -ContractVersion 3
    Assert-Owner ([string]$checkedOmitted.Status -ceq 'success') `
        "A checked-sibling candidate that omitted siblingNotRequiredReason was still refused (status '$($checkedOmitted.Status)', field '$($checkedOmitted.Field)')."
    if ([string]$checkedOmitted.Status -ceq 'success') {
        Assert-Owner (@($checkedOmitted.Value.candidates).Count -eq 1) "The defaulted candidate was not kept."
        Assert-Owner ([string]@($checkedOmitted.Value.candidates)[0].siblingNotRequiredReason -ceq '') `
            "The wrapper default did not produce an empty reason."
        Assert-Owner (@(@($checkedOmitted.NormalizedFields) | Where-Object {
                    [string]$_.Field -like '*siblingNotRequiredReason' }).Count -eq 1) `
            "The wrapper defaulted a model-owned field without recording it."
    }
    # checked + present-and-empty => still accepted (no behaviour change).
    $checkedPresent = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome `
        -StdOutText ("CONVENTION_REVIEW_RESULT_V3: " + (New-OwnerSiblingMarker -Status 'checked')) `
        -Schema $schemaFor -ContractVersion 3
    Assert-Owner ([string]$checkedPresent.Status -ceq 'success') `
        "A checked-sibling candidate that DID emit an empty reason was refused."

    # notRequired + omitted => still refused. The reason is real content the
    # wrapper cannot invent, so its absence stays a refusal.
    $notRequiredOmitted = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome `
        -StdOutText ("CONVENTION_REVIEW_RESULT_V3: " + (New-OwnerSiblingMarker -Status 'notRequired' -OmitReason)) `
        -Schema $schemaFor -ContractVersion 3
    $notRequiredDrops = @(@($notRequiredOmitted.DroppedElements) | Where-Object {
            [string]$_.Field -like '*siblingNotRequiredReason' })
    $notRequiredDropped = ($notRequiredDrops.Count -ge 1)
    Assert-Owner (([string]$notRequiredOmitted.Status -cne 'success') -or $notRequiredDropped) `
        "A notRequired-sibling candidate with NO reason was silently accepted; the wrapper invented content it cannot know."
    if ([string]$notRequiredOmitted.Status -ceq 'success') {
        Assert-Owner (@($notRequiredOmitted.Value.candidates).Count -eq 0) `
            "A notRequired-sibling candidate missing its reason survived into the candidate list."
    }

    # v2 is frozen: it must still require the key outright.
    $v2Schema = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject $siblingProject -ExpectedNonce $siblingNonce -ContractVersion 2
    $v2Object = Get-Content -LiteralPath $recordedPath -Raw | ConvertFrom-Json
    $v2Shaped = [ordered]@{}
    foreach ($property in (@($v2Object.candidates)[0]).PSObject.Properties) {
        if ($property.Name -ceq 'siblingNotRequiredReason') { continue }
        $v2Shaped[$property.Name] = $property.Value
    }
    $v2Shaped['siblingStatus'] = 'checked'
    $v2Object.candidates = @([pscustomobject]$v2Shaped)
    $v2Outcome = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome `
        -StdOutText ("CONVENTION_REVIEW_RESULT_V2: " + ($v2Object | ConvertTo-Json -Depth 24 -Compress)) `
        -Schema $v2Schema -ContractVersion 2
    Assert-Owner ([string]$v2Outcome.Status -cne 'success') `
        "Contract v2 accepted a candidate missing siblingNotRequiredReason; v2 is frozen and must not gain the default."
}

# ---------------------------------------------------------------------------
# v3 local declaration evidence and wrapper-derived primary targets.
# ---------------------------------------------------------------------------
$localRepoId = '11111111-2222-3333-4444-555555555555'
$localSourceRepoId = '22222222-3333-4444-5555-666666666666'
$localSourceSha = 'd' * 64
$localRuleQuote = 'owner attribute on test methods'
$localSourceText = "Claim ownership: $localRuleQuote must be present."
$localSource = [pscustomobject][ordered]@{
    PackName = 'bpm-test-ownership'
    PackDeclarationEvidence = 'local'
    SourceId = 'enghub-automated-tests-ownership'
    TrustTier = 'pinned-external'
    Organization = 'contoso'
    Project = 'Guidance'
    RepositoryId = $localSourceRepoId
    Path = '/reviewer/conventions/automated-tests.md'
    CommitSha = 'c' * 40
    Sha256 = $localSourceSha
    MimeType = 'text/markdown'
    ByteLength = $localSourceText.Length
    Text = $localSourceText
}
$localSources = @($localSource)
$localPlan = [pscustomobject][ordered]@{
    selectedPacks = @([pscustomobject][ordered]@{ name = 'bpm-test-ownership'; declarationEvidence = 'local' })
}
$localFactPlan = [pscustomobject][ordered]@{ facts = @() }
$localHashes = [ordered]@{
    conventionPlanSha256 = '1' * 64
    factPlanSha256 = '2' * 64
    configSha256 = '3' * 64
    scriptSha256 = '4' * 64
    promptSha256 = '5' * 64
}

function New-OwnerLocalCandidate {
    param(
        [string]$CandidateId = 'owner-local',
        [string]$PrimaryTarget = 'cf0:10',
        [string]$Manifestations = '',
        [string]$RuleRef = 'rs0',
        [string]$FixTargets = 'dc0'
    )
    return [pscustomobject][ordered]@{
        candidateId = $CandidateId
        category = 'convention'
        severity = 'important'
        anchorKind = 'changedFile'
        primaryTarget = $PrimaryTarget
        manifestations = $Manifestations
        ruleRef = $RuleRef
        ruleSection = 'Claim ownership'
        ruleQuote = $script:localRuleQuote
        diffEvidence = 'A changed test declaration has TestMethod but no Owner attribute.'
        impactCategory = 'buildOrTestExecution'
        impact = 'Ownership metadata drives test accountability.'
        expectedFixOrValidation = 'Add the Owner attribute to the changed test declaration.'
        siblingStatus = 'notRequired'
        siblingEvidence = ''
        siblingNotRequiredReason = 'placeholder ignored for local declaration evidence'
        factIds = ''
        confidence = 'high'
        residualRiskSummary = ''
        semanticCandidateVersion = 2
        changedCodeFix = [pscustomobject][ordered]@{
            action = 'add'
            targets = $FixTargets
            conventionKey = 'Owner'
            valueSource = 'authoritativeRule'
            evidenceFactIds = ''
        }
        existingDebtFollowUp = [pscustomobject][ordered]@{
            status = 'none'
            evidenceFactId = ''
            selectorKey = ''
            scopeKind = ''
            scopePath = ''
            comparableCount = 0
            compliantCount = 0
            action = ''
        }
    }
}

function New-OwnerLocalCoverageRow {
    param(
        [string]$Status = 'violation',
        [string]$Violating = 'dc0',
        [string]$Unknown = '',
        [string]$NotInReach = '',
        [string]$CandidateId = 'owner-local'
    )
    return [pscustomobject][ordered]@{
        ruleRef = 'rs0'
        ruleSourceSha256 = $script:localSourceSha
        ruleQuote = $script:localRuleQuote
        status = $Status
        scope = 'declaration'
        violatingConstructs = $Violating
        compliantConstructs = ''
        notInReachConstructs = $NotInReach
        unknownConstructs = $Unknown
        violatingChangedFileTargets = ''
        codeEvidence = 'The changed TestMethod declaration lacks Owner.'
        siblingStatus = 'unavailable'
        siblingEvidence = ''
        candidateId = $CandidateId
        notes = ''
    }
}

function New-OwnerLocalMarker {
    param(
        [object[]]$Candidates,
        [object[]]$Rows,
        [string]$Nonce = 'owner-local-nonce'
    )
    return [pscustomobject][ordered]@{
        schemaVersion = 3
        prId = 16991680
        repositoryId = $script:localRepoId
        project = 'One'
        reviewedSourceCommit = '6' * 40
        targetCommit = '7' * 40
        changeSetDigest = '8' * 64
        conventionPlanSha256 = $script:localHashes.conventionPlanSha256
        factPlanSha256 = $script:localHashes.factPlanSha256
        configSha256 = $script:localHashes.configSha256
        scriptSha256 = $script:localHashes.scriptSha256
        promptSha256 = $script:localHashes.promptSha256
        candidates = @($Candidates)
        ruleCoverage = @($Rows)
        withheld = @()
        residualRisks = @()
        nonce = $Nonce
    }
}

function ConvertTo-OwnerLocalParsedMarker {
    param([Parameter(Mandatory)]$Marker, [string]$Nonce = 'owner-local-nonce')
    $schema = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject 'One' `
        -ExpectedNonce $Nonce -ContractVersion 3
    return ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome `
        -StdOutText ("CONVENTION_REVIEW_RESULT_V3: " + ($Marker | ConvertTo-Json -Depth 24 -Compress)) `
        -Schema $schema -ContractVersion 3
}

function Resolve-OwnerLocalMarker {
    param(
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][object[]]$Constructs,
        [Parameter(Mandatory)][object[]]$ChangeEntries,
        [Parameter(Mandatory)][hashtable]$Ranges,
        [object[]]$ConstructFiles = @(),
        [object[]]$DroppedElements = @()
    )
    $outcome = ConvertTo-OwnerLocalParsedMarker -Marker $Marker
    Assert-Owner ([string]$outcome.Status -ceq 'success') `
        "The local-evidence v3 marker did not parse (status '$($outcome.Status)', field '$($outcome.Field)')."
    if ([string]$outcome.Status -cne 'success') { return $null }
    return Resolve-ReviewerConventionSpecialistCandidates -Marker $outcome.Value `
        -ConventionPlan $script:localPlan -FactPlan $script:localFactPlan `
        -ResolvedSources $script:localSources -ChangeEntries $ChangeEntries `
        -Constructs $Constructs -ConstructFiles $ConstructFiles `
        -RightHandRangesByPath $Ranges -ContractVersion 3 `
        -DroppedElements $DroppedElements
}

$knownLocalDeclaration = [pscustomobject][ordered]@{
    constructId = 'dc0'
    kind = 'declaration'
    path = 'src/Tests/OwnerTests.cs'
    line = 10
    endLine = 10
    name = 'MissingOwner'
    attributes = @('TestMethod')
    siblingAttributes = @()
    absentHere = @('Owner')
    status = 'known'
}
$unknownLocalDeclaration = [pscustomobject][ordered]@{
    constructId = 'dc1'
    kind = 'declaration'
    path = 'src/Tests/OwnerTests.cs'
    line = 20
    endLine = 20
    name = 'UnknownOwner'
    attributes = @()
    siblingAttributes = @()
    absentHere = @()
    status = 'unknown'
}
$localRowRequest = Get-ReviewerConventionSpecialistRuleRequest -ResolvedSources $localSources `
    -Constructs @($knownLocalDeclaration, $unknownLocalDeclaration) -ContractVersion 3
$localRequiredRow = @($localRowRequest.Requested)[0]
Assert-Owner ([bool]$localRequiredRow.siblingEvidenceRequired -eq $false) `
    "The local declaration pack did not mark sibling evidence wrapper-owned."
Assert-Owner ([string]$localRequiredRow.locallyAdjudicableConstructs -ceq 'dc0') `
    "The local declaration row did not expose only known declarations (got '$($localRequiredRow.locallyAdjudicableConstructs)')."

$knownChanges = @([pscustomobject][ordered]@{
        Path = 'src/Tests/OwnerTests.cs'
        Role = 'current'
        ChangeTypes = @('edit')
    })
$knownRanges = @{ '/src/Tests/OwnerTests.cs' = @([pscustomobject]@{ startLine = 10; endLine = 10 }) }
$incompleteCensus = [pscustomObject][ordered]@{
    evidenceFactId = 'rdf1:' + ('9' * 64)
    path = 'src/Tests/OwnerTests.cs'
    declarationCount = 2
    attributeFrequency = @()
    generatedCode = $false
    wholeFileComplete = $false
    wholeFileLineCount = 200
    wholeFileSha256 = 'a' * 64
    attributeCountsComplete = $false
}
$knownMarker = New-OwnerLocalMarker -Candidates @((New-OwnerLocalCandidate)) `
    -Rows @((New-OwnerLocalCoverageRow))
$knownResult = Resolve-OwnerLocalMarker -Marker $knownMarker -Constructs @($knownLocalDeclaration) `
    -ChangeEntries $knownChanges -Ranges $knownRanges -ConstructFiles @($incompleteCensus)
Assert-Owner ($null -ne $knownResult -and @($knownResult.Candidates).Count -eq 1) `
    "A known changed declaration was not adjudicable when its file census was incomplete."
if ($null -ne $knownResult -and @($knownResult.Candidates).Count -eq 1) {
    $kept = @($knownResult.Candidates)[0]
    Assert-Owner ([string]$kept.siblingStatus -ceq 'checked' -and
        [string]$kept.siblingNotRequiredReason -ceq '' -and
        [string]$kept.siblingEvidence -like 'Wrapper local declaration evidence:*status known*') `
        "The wrapper did not replace model sibling fields with local declaration evidence."
}

$unknownRanges = @{ '/src/Tests/OwnerTests.cs' = @([pscustomobject]@{ startLine = 20; endLine = 20 }) }
$unknownMarker = New-OwnerLocalMarker -Candidates @((New-OwnerLocalCandidate `
            -CandidateId 'owner-unknown' -PrimaryTarget 'cf0:20' -FixTargets 'cf0:20')) `
    -Rows @((New-OwnerLocalCoverageRow -Status 'unknown' -Violating '' -Unknown 'dc1' -CandidateId ''))
$unknownResult = Resolve-OwnerLocalMarker -Marker $unknownMarker -Constructs @($unknownLocalDeclaration) `
    -ChangeEntries $knownChanges -Ranges $unknownRanges
Assert-Owner ($null -ne $unknownResult -and @($unknownResult.Candidates).Count -eq 0 -and
    @($unknownResult.Withheld | Where-Object {
        [string]$_.candidateId -ceq 'owner-unknown' -and [string]$_.reason -ceq 'invalidEvidence'
    }).Count -eq 1) `
    "An unknown declaration became adjudicable from local declaration evidence."

$derivedConstructs = @(
    [pscustomobject][ordered]@{
        constructId = 'dc0'; kind = 'declaration'; path = 'src/BTests.cs'; line = 10; endLine = 10
        name = 'B'; attributes = @('TestMethod'); siblingAttributes = @(); absentHere = @('Owner'); status = 'known'
    },
    [pscustomobject][ordered]@{
        constructId = 'dc1'; kind = 'declaration'; path = 'src/ATests.cs'; line = 20; endLine = 20
        name = 'A'; attributes = @('TestMethod'); siblingAttributes = @(); absentHere = @('Owner'); status = 'known'
    }
)
$derivedChanges = @(
    [pscustomobject][ordered]@{ Path = 'src/BTests.cs'; Role = 'current'; ChangeTypes = @('edit') },
    [pscustomobject][ordered]@{ Path = 'src/ATests.cs'; Role = 'current'; ChangeTypes = @('edit') }
)
$derivedRanges = @{
    '/src/BTests.cs' = @([pscustomobject]@{ startLine = 10; endLine = 10 })
    '/src/ATests.cs' = @([pscustomobject]@{ startLine = 20; endLine = 20 })
}
$derivedMarker = New-OwnerLocalMarker -Candidates @((New-OwnerLocalCandidate `
            -CandidateId 'owner-derived' -PrimaryTarget '' -Manifestations 'cf1:10,cf0:20' `
            -FixTargets 'dc0,dc1')) `
    -Rows @((New-OwnerLocalCoverageRow -Violating 'dc0-dc1' -CandidateId 'owner-derived'))
$derivedResult = Resolve-OwnerLocalMarker -Marker $derivedMarker -Constructs $derivedConstructs `
    -ChangeEntries $derivedChanges -Ranges $derivedRanges
Assert-Owner ($null -ne $derivedResult -and @($derivedResult.Candidates).Count -eq 1) `
    "A candidate with omitted primaryTarget was not accepted for deterministic derivation."
if ($null -ne $derivedResult -and @($derivedResult.Candidates).Count -eq 1) {
    $derivedCandidate = @($derivedResult.Candidates)[0]
    Assert-Owner ([string]$derivedCandidate.primaryTarget -ceq 'cf0:20' -and
        [string]$derivedCandidate.manifestations -ceq 'cf1:10') `
        "Omitted primaryTarget was not derived as ordinal-first with the rest as manifestations."
}

$unknownRefMarker = New-OwnerLocalMarker -Candidates @((New-OwnerLocalCandidate `
            -CandidateId 'owner-unresolved-target' -PrimaryTarget '' -Manifestations 'cf99:10' `
            -FixTargets 'cf0:10')) `
    -Rows @((New-OwnerLocalCoverageRow -CandidateId 'owner-unresolved-target'))
$unknownRefResult = Resolve-OwnerLocalMarker -Marker $unknownRefMarker -Constructs @($knownLocalDeclaration) `
    -ChangeEntries $knownChanges -Ranges $knownRanges
Assert-Owner ($null -ne $unknownRefResult -and @($unknownRefResult.Candidates).Count -eq 0 -and
    @($unknownRefResult.Withheld | Where-Object {
        [string]$_.candidateId -ceq 'owner-unresolved-target' -and [string]$_.reason -ceq 'invalidTarget'
    }).Count -eq 1) `
    "An omitted primaryTarget with unresolved refs was guessed instead of withheld."

$unboundMarker = New-OwnerLocalMarker -Candidates @((New-OwnerLocalCandidate `
            -CandidateId 'owner-unbound-rule' -RuleRef 'rs9')) `
    -Rows @((New-OwnerLocalCoverageRow -CandidateId 'owner-unbound-rule'))
$unboundResult = Resolve-OwnerLocalMarker -Marker $unboundMarker -Constructs @($knownLocalDeclaration) `
    -ChangeEntries $knownChanges -Ranges $knownRanges
Assert-Owner ($null -ne $unboundResult -and @($unboundResult.Candidates).Count -eq 0 -and
    @($unboundResult.Withheld | Where-Object {
        [string]$_.candidateId -ceq 'owner-unbound-rule' -and [string]$_.reason -ceq 'invalidEvidence'
    }).Count -eq 1) `
    "A candidate became eligible from an unbound rule reference."

$droppedMarker = New-OwnerLocalMarker -Candidates @() `
    -Rows @((New-OwnerLocalCoverageRow -CandidateId 'owner-dropped'))
$droppedResult = Resolve-OwnerLocalMarker -Marker $droppedMarker -Constructs @($knownLocalDeclaration) `
    -ChangeEntries $knownChanges -Ranges $knownRanges `
    -DroppedElements @([pscustomobject]@{ Field = 'candidates[0].candidateId'; Reason = 'Pattern' })
Assert-Owner ($null -ne $droppedResult -and @($droppedResult.Candidates).Count -eq 0 -and
    @($droppedResult.Withheld | Where-Object { [string]$_.reason -ceq 'schemaInvalidCandidate' }).Count -eq 1) `
    "A candidate became eligible from evidence that the marker reader had dropped."

Assert-Owner ('' -notmatch $siblingSchemaV2.Fields.candidates.Item.Fields.primaryTarget.Pattern) `
    "Contract v2 accepted an empty primaryTarget; v2 is frozen."
Assert-Owner ('' -match $siblingSchemaV3.Fields.candidates.Item.Fields.primaryTarget.Pattern) `
    "Contract v3 does not allow wrapper-derived empty primaryTarget."

# ---------------------------------------------------------------------------
# Contract v4: the per-construct verdict matrix.
#
# Ten qualification runs against contract v3 found all nine violating
# declarations every time, with zero false positives, and lost them anyway - to
# a primaryTarget written as a construct id, to six spellings of a
# conventionKey, to a notInReachConstructs list that omitted the 25 out-of-kind
# ids it was the complement of, and to a row status the wrapper already derived.
# Version 4 removes every one of those from the model. These checks are the
# proof that it did, and that what is left cannot lose a finding the same ways.
# ---------------------------------------------------------------------------
$v4 = Get-ReviewerConventionSpecialistMarkerSchema -ExpectedProject 'One' -ExpectedNonce ('a' * 36) -ContractVersion 4

# The key set EXACTLY, never as a delta from v3. A delta assertion passes when a
# v4 branch silently inherits a v3 field through an open-ended `-ge 3` test,
# which is the whole failure mode this contract is trying to avoid.
Assert-Owner ((@($v4.Keys) -join ',') -ceq (
        'schemaVersion,prId,repositoryId,project,reviewedSourceCommit,targetCommit,changeSetDigest,' +
        'conventionPlanSha256,factPlanSha256,configSha256,scriptSha256,promptSha256,' +
        'assessments,withheld,residualRisks,nonce')) `
    "Contract v4's top-level key set is not exactly the binding block plus assessments/withheld/residualRisks/nonce."
Assert-Owner ((@($v4.Fields.assessments.Item.Keys) -join ',') -ceq 'ruleRef,constructs,notes') `
    "Contract v4's assessment row is not exactly ruleRef, constructs and notes."
Assert-Owner ((@($v4.Fields.assessments.Item.Fields.constructs.Item.Keys) -join ',') -ceq 'constructRef,verdict') `
    "Contract v4 asks a construct verdict for more than an opaque ref and an enum."
Assert-Owner ((@($v4.Fields.assessments.Item.Fields.notes.Item.Keys) -join ',') -ceq 'constructRef,rationale,suggestion') `
    "Contract v4's note is not exactly a construct ref and two sentences."

# Every field that cost a real run a finding must be unaskable in v4.
foreach ($gone in @('primaryTarget', 'manifestations', 'filePath', 'line', 'packName', 'ruleSourceId',
        'ruleSourceRepositoryId', 'ruleSourcePath', 'ruleSourceCommit', 'ruleSourceSha256', 'ruleQuote',
        'ruleSection', 'factIds', 'severity', 'impactCategory', 'confidence', 'candidateId',
        'siblingStatus', 'siblingEvidence', 'siblingNotRequiredReason', 'changedCodeFix',
        'existingDebtFollowUp', 'scope', 'status', 'notInReachConstructs', 'violatingChangedFileTargets')) {
    $reachable = ((@($v4.Fields.assessments.Item.Keys) -ccontains $gone) -or
        (@($v4.Fields.assessments.Item.Fields.constructs.Item.Keys) -ccontains $gone) -or
        (@($v4.Fields.assessments.Item.Fields.notes.Item.Keys) -ccontains $gone))
    Assert-Owner (-not $reachable) "Contract v4 still asks the model for '$gone'."
}
Assert-Owner (-not (@($v4.Keys) -ccontains 'candidates') -and -not (@($v4.Keys) -ccontains 'ruleCoverage')) `
    "Contract v4 still carries a candidate or coverage array; the wrapper derives both."

# The verdict enum has no escape hatch. `notApplicable` would let a model answer
# a construct without deciding anything, and out-of-reach constructs are already
# excluded from the in-scope set by the wrapper.
Assert-Owner ((@($v4.Fields.assessments.Item.Fields.constructs.Item.Fields.verdict.Values) -join ',') -ceq
    'violation,compliant,unknown') "Contract v4's verdict enum is not exactly violation/compliant/unknown."

# Failure locality: a row drops itself, a note drops itself, but a construct
# entry may NOT drop itself - a dropped verdict is indistinguishable from one
# the model never sent, and both must make the row incomplete instead of
# quietly shrinking the set that got a verdict.
Assert-Owner ([string]$v4.Fields.assessments.ElementFailurePolicy -ceq 'drop') `
    "Contract v4 does not keep an unreadable rule row local to that rule."
Assert-Owner ([string]$v4.Fields.assessments.Item.Fields.notes.ElementFailurePolicy -ceq 'drop') `
    "Contract v4 lets an unreadable sentence cost more than itself."
Assert-Owner ([string]$v4.Fields.assessments.Item.Fields.constructs.ElementFailurePolicy -ceq 'fail') `
    "Contract v4 lets a construct verdict drop itself, which silently shrinks the answered set."

# The row can always answer for every construct the enumerator can produce.
Assert-Owner ([int]$v4.Fields.assessments.Item.Fields.constructs.MaxItems -ge [int]$script:ReviewerConstructMaxTotal) `
    ("Contract v4 caps a row at $([int]$v4.Fields.assessments.Item.Fields.constructs.MaxItems) constructs, " +
    "below the $([int]$script:ReviewerConstructMaxTotal) the enumerator can produce, so a full change set could not be answered.")

# The largest legal v4 marker must fit the window it is actually read through,
# and - because the matrix is verbose - it must be measured, not assumed. It is
# in fact SMALLER than v3's, because the prose that dominated the worst case now
# lives in a separately bounded array instead of on every verdict.
$v4Fit = Test-AgentMarkerSchemaFitsScanWindow -Schema $v4 -ScanWindowChars $specialistWindow
Assert-Owner ([bool]$v4Fit.Fits) `
    "The v4 contract's largest legal marker ($($v4Fit.WorstCaseChars) chars) does not fit the $($v4Fit.WindowChars)-char scan window."
Assert-Owner ([int]$v4Fit.WorstCaseChars -lt [int]$fit.WorstCaseChars) `
    "Contract v4 did not shrink the largest legal marker (v4 $($v4Fit.WorstCaseChars) vs v3 $($fit.WorstCaseChars))."

# Version dispatch: exact, and ambiguity is a refusal rather than a preference.
Assert-Owner ((Get-ReviewerConventionSpecialistMarkerPrefixForVersion -ContractVersion 4) -ceq
    'CONVENTION_REVIEW_RESULT_V4:') "Contract v4 does not have its own marker prefix."
Assert-Owner ((Get-ReviewerConventionSpecialistMarkerPrefixForVersion -ContractVersion 3) -ceq
    'CONVENTION_REVIEW_RESULT_V3:') "The v3 prefix moved; sealed v3 artifacts would stop being readable."
Assert-Owner ((Get-ReviewerConventionSpecialistContractVersionFromText -Text 'CONVENTION_REVIEW_RESULT_V4: {}') -eq 4) `
    "A v4 marker is not read as v4."
Assert-Owner ((Get-ReviewerConventionSpecialistContractVersionFromText -Text 'CONVENTION_REVIEW_RESULT_V3: {}') -eq 3) `
    "A v3 marker is not read as v3."
Assert-Owner ((Get-ReviewerConventionSpecialistContractVersionFromText -Text 'no marker at all') -eq 2) `
    "A prefixless marker is no longer read under the frozen v2 rules."
Assert-Owner ((Get-ReviewerConventionSpecialistContractVersionFromText -Text (
            'CONVENTION_REVIEW_RESULT_V4: {"x":"CONVENTION_REVIEW_RESULT_V3:"}')) -eq 0) `
    "A marker claiming two contracts is resolved to one instead of refused."
$ambiguityRefused = $false
try { [void](Resolve-ReviewerConventionSpecialistSealedContractVersion -Text (
            'CONVENTION_REVIEW_RESULT_V4: CONVENTION_REVIEW_RESULT_V2:')) }
catch { $ambiguityRefused = $true }
Assert-Owner $ambiguityRefused "An ambiguous sealed marker was assigned a contract version instead of being refused."

# The v4 prompt is a separate file, so the v3 promptSha256 that sealed artifacts
# retain does not move.
Assert-Owner ((Get-ReviewerConventionSpecialistPromptFileName -ContractVersion 4) -ceq 'convention-review.v4.prompt.md') `
    "Contract v4 does not have its own prompt file."
Assert-Owner ((Get-ReviewerConventionSpecialistPromptFileName -ContractVersion 3) -ceq 'convention-review.prompt.md') `
    "The v3 prompt file moved; every sealed v3 promptSha256 would stop reproducing."

# ---------------------------------------------------------------------------
# The ten preserved qualification trials, re-expressed as v4 matrices.
#
# Each row below is what one real run actually asserted, in the shape v4 asks
# for. Every one of them recovers all nine declarations, because none of the
# things those runs got wrong are expressible here.
# ---------------------------------------------------------------------------
$ownerFileA = '/src/flow/Tests/Tests.Flow.Data/AutomationConnectionUtilityTests.cs'
$ownerFileB = '/src/flow/Tests/Tests.Flow.Web/AutomationApiOperationApiEngineTests.cs'
$ownerDeclarations = [ordered]@{
    dc0 = @($ownerFileA, 20); dc1 = @($ownerFileA, 30); dc2 = @($ownerFileA, 69)
    dc3 = @($ownerFileA, 81); dc4 = @($ownerFileA, 115); dc5 = @($ownerFileA, 126)
    dc6 = @($ownerFileA, 137); dc7 = @($ownerFileA, 148); dc8 = @($ownerFileA, 159)
    dc9 = @($ownerFileA, 174); dc10 = @($ownerFileB, 398); dc11 = @($ownerFileA, 200)
}
$ownerNine = @('dc2', 'dc3', 'dc4', 'dc5', 'dc6', 'dc7', 'dc8', 'dc9', 'dc10')
$ownerConstructs = @()
foreach ($id in @($ownerDeclarations.Keys)) {
    $ownerConstructs += [pscustomobject]@{
        constructId = [string]$id; kind = 'declaration'; path = [string]$ownerDeclarations[$id][0]
        line = [int]$ownerDeclarations[$id][1]; endLine = [int]$ownerDeclarations[$id][1]
        name = [string]$id; status = 'known'
    }
}
# Two constructs of other kinds. Under v3 the model had to name these among the
# out-of-kind complement; under v4 the wrapper rules them out itself.
$ownerConstructs += [pscustomobject]@{ constructId = 'mi0'; kind = 'invocation'; path = $ownerFileA; line = 70; endLine = 70; name = 'Assert'; status = 'known' }
$ownerConstructs += [pscustomobject]@{ constructId = 'cm0'; kind = 'comment'; path = $ownerFileA; line = 68; endLine = 68; status = 'known' }

$ownerChangeEntries = @(
    [pscustomobject]@{ Path = $ownerFileA; Role = 'current'; ChangeTypes = @('edit') },
    [pscustomobject]@{ Path = $ownerFileB; Role = 'current'; ChangeTypes = @('edit') }
)
$ownerRanges = @{
    $ownerFileA = @(@{ startLine = 1; endLine = 400 })
    $ownerFileB = @(@{ startLine = 1; endLine = 400 })
}
$ownerPlan = [pscustomobject]@{
    selectedPacks = @([pscustomobject]@{
            name = 'bpm-test-ownership'
            matchedPaths = @([pscustomobject]@{ path = $ownerFileA }, [pscustomobject]@{ path = $ownerFileB })
        })
}
$ownerRuleText = ("# Automated tests`n`n## Claim ownership`n`n" +
    "Every test class and test method must carry the Owner attribute naming an alias.`n`n## Next`n")
$ownerSources = @([pscustomobject]@{
        PackName = 'bpm-test-ownership'; SourceId = 'enghub-automated-tests-ownership'
        RepositoryId = '11111111-2222-3333-4444-555555555555'
        Path = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
        CommitSha = ('f' * 40); Sha256 = ('b' * 64)
        Section = '## Claim ownership'; Text = $ownerRuleText; PackDeclarationEvidence = ''
    })
$ownerConstructFiles = @(
    [pscustomobject]@{ path = $ownerFileA; evidenceFactId = ("rdf1:" + ('a' * 64)); attributeCountsComplete = $true; wholeFileComplete = $true; declarationCount = 12; wholeFileLineCount = 400; wholeFileSha256 = ('c' * 64); generatedCode = $false; attributeFrequency = @() },
    [pscustomobject]@{ path = $ownerFileB; evidenceFactId = ("rdf1:" + ('d' * 64)); attributeCountsComplete = $false; wholeFileComplete = $false; declarationCount = 1; wholeFileLineCount = 400; wholeFileSha256 = ('e' * 64); generatedCode = $false; attributeFrequency = @() }
)
$ownerFactPlan = [pscustomobject]@{ facts = @() }

$ownerRequest = Get-ReviewerConventionSpecialistRuleRequest -ResolvedSources $ownerSources `
    -Constructs $ownerConstructs -ContractVersion 4 -ConventionPlan $ownerPlan
$ownerInScope = [string[]]@((@($ownerRequest.Requested)[0]).inScopeConstructIds)
Assert-Owner ([bool](@($ownerRequest.Requested)[0]).inScopeResolved) `
    "The wrapper could not derive the Owner rule's in-scope set from its pack routing."
Assert-Owner ($ownerInScope.Count -eq 14) `
    "The Owner rule's in-scope set is $($ownerInScope.Count) constructs, not the 14 in its routed files."

$ownerAnchorIndex = Get-ReviewerConventionSpecialistChangedFileIndex -ChangeEntries $ownerChangeEntries `
    -RightHandRangesByPath $ownerRanges
$ownerAnchorByPath = @{}
foreach ($anchor in @($ownerAnchorIndex)) { $ownerAnchorByPath[[string]$anchor.path] = [string]$anchor.anchorId }
$ownerExpectedAnchors = [string[]]@(@($ownerNine) | ForEach-Object {
        $declarationPath = ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path ([string]$ownerDeclarations[$_][0])
        "$($ownerAnchorByPath[$declarationPath]):$([int]$ownerDeclarations[$_][1])"
    } | Sort-Object)

function New-OwnerV4Marker {
    param([AllowEmptyCollection()][object[]]$Constructs = @(), [AllowEmptyCollection()][object[]]$Notes = @(),
        [switch]$NoRow)
    $rows = @()
    if (-not $NoRow) { $rows = @(@{ ruleRef = 'rs0'; constructs = $Constructs; notes = $Notes }) }
    return @{
        schemaVersion = 4; prId = 16991680
        repositoryId = '11111111-2222-3333-4444-555555555555'; project = 'One'
        reviewedSourceCommit = ('a' * 40); targetCommit = ('b' * 40); changeSetDigest = ('c' * 64)
        conventionPlanSha256 = ('d' * 64); factPlanSha256 = ('e' * 64); configSha256 = ('f' * 64)
        scriptSha256 = ('0' * 64); promptSha256 = ('1' * 64)
        assessments = $rows; withheld = @(); residualRisks = @(); nonce = ('n' * 32)
    }
}
function New-OwnerV4Matrix {
    param([string[]]$Violating = @(), [hashtable]$Override = @{})
    $entries = @()
    foreach ($id in $ownerInScope) {
        $verdict = if ($Override.ContainsKey($id)) { [string]$Override[$id] }
        elseif ($Violating -ccontains $id) { 'violation' }
        else { 'compliant' }
        $entries += @{ constructRef = $id; verdict = $verdict }
    }
    return $entries
}
function Resolve-OwnerV4 {
    param([hashtable]$Marker)
    return Resolve-ReviewerConventionSpecialistCandidates -Marker $Marker -ConventionPlan $ownerPlan `
        -FactPlan $ownerFactPlan -ResolvedSources $ownerSources -ChangeEntries $ownerChangeEntries `
        -Constructs $ownerConstructs -ConstructFiles $ownerConstructFiles `
        -RightHandRangesByPath $ownerRanges -ContractVersion 4
}

# The ten trials. `Withheld` is what the model itself set aside; every trial's
# semantic assertion was "these nine violate", however it was packaged.
$ownerTrials = @(
    @{ Name = 'qual1'; Lost = 'primaryTarget written as a construct id' },
    @{ Name = 'qual2'; Lost = 'dc10 withheld for an incomplete census' },
    @{ Name = 'qual3'; Lost = 'nothing; accounting complete' },
    @{ Name = 'qual4'; Lost = 'notInReachConstructs omitted the out-of-kind complement' },
    @{ Name = 'qual5'; Lost = 'notInReachConstructs omitted the out-of-kind complement' },
    @{ Name = 'r5_qual1'; Lost = 'row status disagreed with its own anchor verdicts' },
    @{ Name = 'r5_qual2'; Lost = 'changedCodeFix.conventionKey carried spaces (two candidates dropped)' },
    @{ Name = 'r5_qual3'; Lost = 'changedCodeFix.conventionKey carried spaces' },
    @{ Name = 'r5_qual4'; Lost = 'nothing; scored a miss only because coverage counted one candidate' },
    @{ Name = 'r5_qual5'; Lost = 'row status disagreed with its own anchor verdicts' }
)
foreach ($trial in $ownerTrials) {
    $trialResult = Resolve-OwnerV4 (New-OwnerV4Marker -Constructs (New-OwnerV4Matrix -Violating $ownerNine) `
            -Notes @(@{ constructRef = 'dc2'; rationale = 'No Owner attribute on this test method.'; suggestion = 'Add [Owner("alias")].' }))
    $trialAnchors = Get-OwnerUnionAnchors -Candidates @($trialResult.Candidates)
    Assert-Owner (($trialAnchors -join ',') -ceq ($ownerExpectedAnchors -join ',')) `
        ("Trial $($trial.Name) - which under v3 lost its finding to $($trial.Lost) - does not recover all nine " +
        "declarations under v4 (got $($trialAnchors -join ','))." )
    Assert-Owner (@($trialResult.Withheld).Count -eq 0) `
        "Trial $($trial.Name) withheld something under v4 (got $(@($trialResult.Withheld).Count))."
    Assert-Owner ([bool]$trialResult.RuleCoverage.Complete) `
        "Trial $($trial.Name) did not produce complete rule accounting under v4."
}

# Grouping independence, stated directly: the nine are grouped by the WRAPPER,
# so the answer cannot depend on how the model packaged it. Reordering the
# matrix must produce byte-identical coverage and the same candidate count.
$ownerBase = Resolve-OwnerV4 (New-OwnerV4Marker -Constructs (New-OwnerV4Matrix -Violating $ownerNine))
$ownerShuffled = @(New-OwnerV4Matrix -Violating $ownerNine)
$ownerReordered = @($ownerShuffled[7..($ownerShuffled.Count - 1)] + $ownerShuffled[0..6])
$ownerReorderedResult = Resolve-OwnerV4 (New-OwnerV4Marker -Constructs $ownerReordered)
Assert-Owner (((Get-OwnerUnionAnchors -Candidates @($ownerBase.Candidates)) -join ',') -ceq
    ((Get-OwnerUnionAnchors -Candidates @($ownerReorderedResult.Candidates)) -join ',')) `
    "The order a model answers in changed the coverage; grouping is supposed to be the wrapper's."
Assert-Owner (@($ownerBase.Candidates).Count -eq @($ownerReorderedResult.Candidates).Count) `
    "The order a model answers in changed how many candidates the wrapper published."
Assert-Owner (@($ownerBase.Candidates).Count -eq 2) `
    "The nine declarations across two files did not group into two per-file candidates (got $(@($ownerBase.Candidates).Count))."

# Every published candidate is wrapper-owned in the ways the trials got wrong.
foreach ($candidate in @($ownerBase.Candidates)) {
    Assert-Owner ([string]$candidate.severity -ceq 'suggestion' -and [string]$candidate.impactCategory -ceq 'none') `
        "A v4 candidate did not take the wrapper's default severity and impact."
    Assert-Owner ([string]$candidate.changedCodeFix.conventionKey -ceq 'enghub-automated-tests-ownership') `
        "A v4 candidate's convention key was not derived from the transported rule source."
    Assert-Owner ([string]$candidate.existingDebtFollowUp.status -ceq 'none') `
        "A v4 candidate claimed an existing-debt follow-up the contract cannot substantiate."
    Assert-Owner ([string]$candidate.ruleQuote -clike 'Every test class*') `
        "A v4 candidate's rule quote was not cut from the rule's own section by the wrapper."
    Assert-Owner ([string]$candidate.primaryTarget -cmatch '^cf[0-9]{1,3}:[1-9][0-9]{0,6}$') `
        "A v4 candidate's primary anchor is not a wrapper-resolved changed line."
}
# Evidence follows the census: file A's is complete, file B's is not.
$ownerCandidateA = @($ownerBase.Candidates | Where-Object {
        [string]$_.filePath -ceq (ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path $ownerFileA) })
$ownerCandidateB = @($ownerBase.Candidates | Where-Object {
        [string]$_.filePath -ceq (ConvertTo-ReviewerConventionSpecialistCanonicalPath -Path $ownerFileB) })
Assert-Owner ($ownerCandidateA.Count -eq 1 -and [string]$ownerCandidateA[0].factIds -ceq ("rdf1:" + ('a' * 64))) `
    "The wrapper did not cite the complete declaration census as the finding's evidence."
Assert-Owner ($ownerCandidateB.Count -eq 1 -and [string]$ownerCandidateB[0].factIds -ceq '') `
    "The wrapper cited an INCOMPLETE declaration census as evidence; a partial count cannot say an attribute is absent."

# Omission is never compliance. This is the property the whole matrix exists for.
$ownerPartial = @(New-OwnerV4Matrix -Violating $ownerNine | Where-Object { $_.constructRef -cne 'dc5' })
$ownerPartialResult = Resolve-OwnerV4 (New-OwnerV4Marker -Constructs $ownerPartial)
Assert-Owner (@($ownerPartialResult.Candidates).Count -eq 0) `
    "A row that did not account for every in-scope construct still published a finding."
Assert-Owner ([string]@($ownerPartialResult.RuleCoverage.Rows)[0].status -ceq 'unknown') `
    "A row missing one construct verdict was not recorded unknown."
Assert-Owner (@(@($ownerPartialResult.RuleCoverage.Rows)[0].compliantConstructs).Count -eq 0) `
    "An omitted construct was recorded as compliant."
Assert-Owner (@($ownerPartialResult.Withheld | Where-Object { [string]$_.detail -like '*dc5*' }).Count -ge 1) `
    "The construct that got no verdict was not named in the withheld diagnostic."

# A duplicate verdict and a verdict on a construct the wrapper did not ask about
# are the same class of defect, and neither may narrow the answered set.
foreach ($case in @(
        @{ Label = 'duplicated'; Extra = @{ constructRef = 'dc5'; verdict = 'compliant' } },
        @{ Label = 'unrequested'; Extra = @{ constructRef = 'dc99'; verdict = 'violation' } })) {
    $defective = @(New-OwnerV4Matrix -Violating $ownerNine) + @($case.Extra)
    $defectiveResult = Resolve-OwnerV4 (New-OwnerV4Marker -Constructs $defective)
    Assert-Owner ([string]@($defectiveResult.RuleCoverage.Rows)[0].status -ceq 'unknown') `
        "A $($case.Label) construct verdict did not make its row unknown."
    Assert-Owner (@($defectiveResult.Candidates).Count -eq 0) `
        "A $($case.Label) construct verdict still published a finding."
}

# A rule the model never answered is a gap in the accounting, not a pass.
$ownerSilent = Resolve-OwnerV4 (New-OwnerV4Marker -NoRow)
Assert-Owner (-not [bool]$ownerSilent.RuleCoverage.Complete) `
    "A rule the model never assessed left the accounting looking complete."
Assert-Owner (@($ownerSilent.Candidates).Count -eq 0) `
    "A rule the model never assessed produced a finding."

# Zero false positives: an all-compliant matrix must publish nothing at all.
$ownerClean = Resolve-OwnerV4 (New-OwnerV4Marker -Constructs (New-OwnerV4Matrix -Violating @()))
Assert-Owner (@($ownerClean.Candidates).Count -eq 0) `
    "An all-compliant matrix produced a candidate."
Assert-Owner ([string]@($ownerClean.RuleCoverage.Rows)[0].status -ceq 'compliant') `
    "An all-compliant matrix was not recorded compliant."

# `unknown` is always available and always safe: it publishes nothing and says so.
$ownerUnknown = Resolve-OwnerV4 (New-OwnerV4Marker -Constructs (New-OwnerV4Matrix -Violating @() `
            -Override @{ dc2 = 'unknown' }))
Assert-Owner (@($ownerUnknown.Candidates).Count -eq 0) 'An unknown verdict published a finding.'
Assert-Owner ([string]@($ownerUnknown.RuleCoverage.Rows)[0].status -ceq 'unknown') `
    'A row carrying an unknown verdict was not recorded unknown.'

# Prose is non-eligibility-critical, end to end: unusable sentences, a note for a
# construct that got no verdict, and a duplicate note must all cost nothing.
$ownerBadNotes = Resolve-OwnerV4 (New-OwnerV4Marker -Constructs (New-OwnerV4Matrix -Violating $ownerNine) -Notes @(
        @{ constructRef = 'dc2'; rationale = ('x' * 5000); suggestion = "bad`u{2028}char" },
        @{ constructRef = 'dc2'; rationale = 'duplicate note'; suggestion = 'duplicate note' },
        @{ constructRef = 'dc0'; rationale = 'a note about a construct with no violation'; suggestion = 'none' }
    ))
$ownerBadNoteAnchors = Get-OwnerUnionAnchors -Candidates @($ownerBadNotes.Candidates)
Assert-Owner (($ownerBadNoteAnchors -join ',') -ceq ($ownerExpectedAnchors -join ',')) `
    "Unusable prose cost the finding its coverage; prose is supposed to be non-eligibility-critical."
Assert-Owner ([bool]$ownerBadNotes.RuleCoverage.Complete) `
    "Unusable prose broke the rule accounting."

if ($script:OwnerFailures.Count -gt 0) {
    foreach ($failure in $script:OwnerFailures) { Write-Host "FAIL: $failure" -ForegroundColor Red }
    throw "bpm-test-ownership: $($script:OwnerFailures.Count) of $script:OwnerChecks check(s) failed."
}
Write-Host "bpm-test-ownership@1: all $script:OwnerChecks checks passed." -ForegroundColor Green
