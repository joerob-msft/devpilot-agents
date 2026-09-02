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
        Assert-Owner ($owner.Count -eq 1) "The recovered marker does not contain the Owner finding."
        if ($owner.Count -eq 1) {
            Assert-Owner ([string]$owner[0].factIds -like 'rdf1:*') `
                "The Owner finding no longer cites the declaration census it rests on."
            Assert-Owner ([string]$owner[0].primaryTarget -ceq 'cf4:69') `
                "The Owner finding moved off its recorded anchor (now '$($owner[0].primaryTarget)')."
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

if ($script:OwnerFailures.Count -gt 0) {
    foreach ($failure in $script:OwnerFailures) { Write-Host "FAIL: $failure" -ForegroundColor Red }
    throw "bpm-test-ownership: $($script:OwnerFailures.Count) of $script:OwnerChecks check(s) failed."
}
Write-Host "bpm-test-ownership@1: all $script:OwnerChecks checks passed." -ForegroundColor Green
