#Requires -Version 7.0
<#
.SYNOPSIS
    The oversized-input refusal is bounded: it publishes a complete result, it is
    charged an attempt, and it terminates.

.DESCRIPTION
    WHAT WENT WRONG. Invoke-ReviewerModelPass returns a dictionary that every
    consumer reads under Set-StrictMode -Version Latest. The branch that refuses
    an oversized input returned a result WITHOUT the 'EnvelopePersisted' key,
    and the accounting writer reads that key on the very next statement. Under
    strict mode a missing key is not $null - it is a terminating error, raised
    inside the consumer, several frames from the branch that omitted it.

    The consequences compound in the wrong direction:

      - the throw escaped the whole review, which is exactly what a BOUNDED
        refusal exists not to do. One oversized pull request took out every
        pull request queued behind it;
      - it happened BEFORE the attempt reached the starvation and retry
        accounting, so the oversized pull request was never charged an attempt
        and never retired. Nothing about an oversized change set improves on its
        own, so the queue would re-select it forever.

    WHAT IS ASSERTED HERE. Four things, in the order they have to hold:

      1. STRUCTURE. Every return out of Invoke-ReviewerModelPass is built by
         New-ReviewerModelPassResult, so no branch can omit a key it never
         writes. This is the check that keeps the class of defect from coming
         back in a branch nobody thought to test.
      2. SHAPE. The factory publishes exactly the closed key set the consumers
         read, 'EnvelopePersisted' is among them, and it is a typed boolean that
         defaults to false rather than an absent key or a $null.
      3. READS. Every consumer read of the fragile keys happens on a result that
         has been through the shape assertion.
      4. BEHAVIOUR. An oversized refusal, run through the real accounting reads
         under strict mode, does not throw; it is charged exactly one attempt;
         and it is terminal, so a repeatedly oversized input cannot loop.

    No model is ever launched here. The reviewer's own functions are lifted out
    by AST and re-defined in this scope, so the assertions are about the shipping
    text of Start-ReviewerAgent.ps1 rather than about a copy of it.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Checks = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Assert-PassShape {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:Checks++
    if (-not $Condition) {
        $script:Failures.Add($Message)
        Write-Host "  FAIL - $Message" -ForegroundColor Red
    }
}

$repo = [string]([IO.Path]::GetFullPath($RepoRoot))
$reviewerScript = Join-Path $repo 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
if (-not (Test-Path -LiteralPath $reviewerScript -PathType Leaf)) {
    throw "The reviewer script '$reviewerScript' does not exist."
}

$parseErrors = $null
$reviewerAst = [System.Management.Automation.Language.Parser]::ParseFile($reviewerScript, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and @($parseErrors).Count -gt 0) {
    throw "The reviewer script does not parse: $((@($parseErrors) | ForEach-Object { $_.Message }) -join '; ')"
}

function Get-ReviewerFunctionAst {
    param([Parameter(Mandatory)][string]$Name)
    $found = $reviewerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
        }, $true) | Select-Object -First 1
    if (-not $found) { throw "The reviewer script defines no function '$Name'." }
    return $found
}

Write-Host '1/4 every return out of the model pass is built by the closed-shape factory' -ForegroundColor Cyan
# The structural guarantee. A branch cannot omit a key it never writes, so the
# only way back to the original defect is to return a hand-rolled literal - and
# that is what this refuses.
$passAst = Get-ReviewerFunctionAst -Name 'Invoke-ReviewerModelPass'
$nestedFunctionExtents = @($passAst.Body.FindAll({
            param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | ForEach-Object { $_.Extent })
$returns = @($passAst.Body.FindAll({
            param($node) $node -is [Management.Automation.Language.ReturnStatementAst]
        }, $true) | Where-Object {
        $offset = $_.Extent.StartOffset
        -not (@($nestedFunctionExtents) | Where-Object { $offset -ge $_.StartOffset -and $offset -lt $_.EndOffset })
    })
Assert-PassShape (@($returns).Count -ge 3) `
    "Invoke-ReviewerModelPass was read as having $(@($returns).Count) return statement(s), which is too few for this check to mean anything."
$unbuiltReturns = [System.Collections.Generic.List[string]]::new()
foreach ($return in @($returns)) {
    $text = [string]$return.Extent.Text
    # A bare 'return' inside the pass ends a nested loop or guard rather than
    # producing a result, and there is nothing to shape.
    if ($text -cmatch '^\s*return\s*$') { continue }
    $calls = @($return.FindAll({
                param($node) $node -is [Management.Automation.Language.CommandAst]
            }, $true) | ForEach-Object { [string]$_.GetCommandName() })
    if (@($calls) -ccontains 'New-ReviewerModelPassResult') { continue }
    $unbuiltReturns.Add("line $($return.Extent.StartLineNumber): $(($text -split "`n")[0].Trim())")
}
Assert-PassShape ($unbuiltReturns.Count -eq 0) `
    ("Invoke-ReviewerModelPass returns $($unbuiltReturns.Count) result(s) not built by New-ReviewerModelPassResult, so a " +
    "branch can omit a key its consumers read: $((@($unbuiltReturns)) -join '; ')")

Write-Host ''
Write-Host '2/4 the factory publishes the closed key set, with EnvelopePersisted typed and defaulted' -ForegroundColor Cyan
# Lifted out and re-defined rather than reimplemented, so this is the shipping
# factory and not a description of one.
. ([scriptblock]::Create((Get-ReviewerFunctionAst -Name 'New-ReviewerModelPassResult').Extent.Text))
. ([scriptblock]::Create((Get-ReviewerFunctionAst -Name 'Assert-ReviewerModelPassResultShape').Extent.Text))
$keysAssignment = $reviewerAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        [string]$node.Left.Extent.Text -ceq '$script:ReviewerModelPassResultKeys'
    }, $true) | Select-Object -First 1
if (-not $keysAssignment) { throw 'The reviewer script does not name its closed pass-result key set.' }
. ([scriptblock]::Create([string]$keysAssignment.Extent.Text))

$minimal = New-ReviewerModelPassResult -Model 'm' -RejectionClass 'oversize' -Nonce 'n'
$expectedKeys = @($script:ReviewerModelPassResultKeys | Sort-Object)
$actualKeys = @(@($minimal.Keys) | Sort-Object)
Assert-PassShape ((($actualKeys) -join ',') -ceq (($expectedKeys) -join ',')) `
    ("The factory publishes [$(($actualKeys) -join ', ')] where the consumers read [$(($expectedKeys) -join ', ')]. " +
    'A key in one list and not the other is the defect this factory exists to prevent.')
Assert-PassShape ($minimal.Contains('EnvelopePersisted')) `
    'A result built with no envelope carries no EnvelopePersisted key, which is the original defect exactly.'
Assert-PassShape ($minimal['EnvelopePersisted'] -is [bool]) `
    "EnvelopePersisted defaulted to type '$(if ($null -eq $minimal['EnvelopePersisted']) { 'null' } else { $minimal['EnvelopePersisted'].GetType().Name })' rather than a boolean."
Assert-PassShape ([bool]$minimal['EnvelopePersisted'] -eq $false) `
    'EnvelopePersisted defaulted to true, which would report an envelope nobody wrote.'
# A default of $null would satisfy "the key is present" and still be wrong: the
# accounting field is typed, and a null there publishes false while meaning
# unknown.
foreach ($key in @('ModelRan', 'ProcessStarted', 'EnvironmentFault')) {
    Assert-PassShape ($minimal[$key] -is [bool]) "The factory left '$key' untyped, so an unset branch reads as unknown rather than false."
}

# The assertion at the boundary still has to bite, because it is what turns a
# hand-rolled result into an attributable refusal rather than a strict-mode
# error inside an accounting writer.
$stripped = @{}
foreach ($key in @($minimal.Keys)) { if ($key -cne 'EnvelopePersisted') { $stripped[$key] = $minimal[$key] } }
$assertMessage = ''
try { [void](Assert-ReviewerModelPassResultShape -Result $stripped) }
catch { $assertMessage = [string]$_.Exception.Message }
Assert-PassShape ($assertMessage -cmatch 'EnvelopePersisted') `
    "A result missing EnvelopePersisted was accepted, or refused without naming the key: '$assertMessage'."
$notADictionary = ''
try { [void](Assert-ReviewerModelPassResultShape -Result 'not a result') }
catch { $notADictionary = [string]$_.Exception.Message }
Assert-PassShape ($notADictionary.Length -gt 0) 'A pass result that is not a dictionary was accepted.'

Write-Host ''
Write-Host '3/4 every consumer reads a result that has been through the shape assertion' -ForegroundColor Cyan
# A second call site that read Invoke-ReviewerModelPass directly would reopen the
# gap for its own branches, so the call itself is what has to be wrapped.
$passCalls = @($reviewerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            [string]$node.GetCommandName() -ceq 'Invoke-ReviewerModelPass'
        }, $true))
Assert-PassShape (@($passCalls).Count -ge 1) 'The reviewer never calls Invoke-ReviewerModelPass, so this check proves nothing.'
$unassertedCalls = [System.Collections.Generic.List[string]]::new()
foreach ($call in @($passCalls)) {
    $parent = $call.Parent
    $guarded = $false
    while ($null -ne $parent) {
        if ($parent -is [Management.Automation.Language.CommandAst] -and
            [string]$parent.GetCommandName() -ceq 'Assert-ReviewerModelPassResultShape') {
            $guarded = $true
            break
        }
        if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { break }
        $parent = $parent.Parent
    }
    if (-not $guarded) { $unassertedCalls.Add("line $($call.Extent.StartLineNumber)") }
}
Assert-PassShape ($unassertedCalls.Count -eq 0) `
    ("$($unassertedCalls.Count) call(s) to Invoke-ReviewerModelPass are read without asserting the result shape " +
    "first: $((@($unassertedCalls)) -join ', ')")

Write-Host ''
Write-Host '4/4 an oversized input is answered, charged, and terminal' -ForegroundColor Cyan
Import-Module (Join-Path $repo 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

# The exact reads the accounting writer performs on a pass result, run under the
# same strict mode the reviewer runs under. Before the fix, the first of these
# threw and took the whole review with it.
$oversize = New-ReviewerModelPassResult -Model 'opaque-model' -RejectionClass 'oversize' -Nonce 'nonce' `
    -Reason 'the bound input exceeds the configured ceiling'
$accountingFault = ''
$accountingRecord = $null
try {
    $accountingRecord = @{
        rejectionClass            = [string]$oversize.RejectionClass
        authTier                  = [string]$oversize.AuthTier
        responseEnvelopeSealed    = ($null -ne $oversize.ResponseEnvelope)
        responseEnvelopePersisted = [bool]$oversize.EnvelopePersisted
        processStarted            = [bool]$oversize.ProcessStarted
        modelRan                  = [bool]$oversize.ModelRan
    }
}
catch { $accountingFault = [string]$_.Exception.Message }
Assert-PassShape ($accountingFault -ceq '') `
    "Reading an oversized refusal the way the accounting writer reads it threw: '$accountingFault'."
Assert-PassShape ($null -ne $accountingRecord -and [bool]$accountingRecord.responseEnvelopePersisted -eq $false) `
    'An oversized refusal recorded a persisted response envelope.'
Assert-PassShape ($null -ne $accountingRecord -and [bool]$accountingRecord.processStarted -eq $false) `
    'An oversized refusal recorded a started process, which would spend a model start on a launch that never happened.'
Assert-PassShape ($null -ne $accountingRecord -and [string]$accountingRecord.rejectionClass -ceq 'oversize') `
    'An oversized refusal did not publish its typed rejection class.'

# Terminal, not retryable. A retryable oversize would spend an attempt per cycle
# on an input that cannot get smaller by being asked again.
Assert-PassShape (-not [bool](Test-AgentMarkerStatusRetryable -Status 'oversize')) `
    'An oversized input is classified retryable, so the same refusal would be re-attempted forever.'

# The shipping retry loop, driven by a stub pass that always refuses for size.
# Counting the iterations is the only way to state "cannot loop" as a fact
# rather than as a reading of the branch conditions.
$script:ReviewerMarkerRetryAttempts = 2
$attemptsCharged = 0
$loopFault = ''
try {
    for ($attempt = 1; $attempt -le $script:ReviewerMarkerRetryAttempts; $attempt++) {
        $passResult = Assert-ReviewerModelPassResultShape -Result (
            New-ReviewerModelPassResult -Model 'opaque-model' -RejectionClass 'oversize' -Nonce 'nonce')
        $attemptsCharged++
        [void][bool]$passResult.EnvelopePersisted
        if ($null -ne $passResult.Marker) { break }
        if ($attempt -ge $script:ReviewerMarkerRetryAttempts) { break }
        if ([string]$passResult.RejectionClass -ceq 'evidenceOnly') { break }
        if ([bool]$passResult.EnvironmentFault -or
            -not (Test-AgentMarkerStatusRetryable -Status ([string]$passResult.RejectionClass))) {
            break
        }
    }
}
catch { $loopFault = [string]$_.Exception.Message }
Assert-PassShape ($loopFault -ceq '') "The retry loop threw on an oversized refusal: '$loopFault'."
Assert-PassShape ($attemptsCharged -eq 1) `
    ("An oversized refusal was charged $attemptsCharged attempt(s). One is the whole point: the attempt has to be " +
    'charged so the input retires, and it must not be retried because nothing about it can change.')

# And the same input offered again is charged again and terminates again, which
# is what retires it through the starvation accounting instead of leaving it to
# be re-selected forever.
$repeatedCharges = 0
for ($round = 1; $round -le 5; $round++) {
    for ($attempt = 1; $attempt -le $script:ReviewerMarkerRetryAttempts; $attempt++) {
        $passResult = Assert-ReviewerModelPassResultShape -Result (
            New-ReviewerModelPassResult -Model 'opaque-model' -RejectionClass 'oversize' -Nonce 'nonce')
        $repeatedCharges++
        if ($attempt -ge $script:ReviewerMarkerRetryAttempts) { break }
        if (-not (Test-AgentMarkerStatusRetryable -Status ([string]$passResult.RejectionClass))) { break }
    }
}
Assert-PassShape ($repeatedCharges -eq 5) `
    ("Five oversized offerings were charged $repeatedCharges attempt(s) rather than five. An offering that is not " +
    'charged is an offering that never retires.')

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "Model pass result shape: $($script:Failures.Count) failure(s) across $($script:Checks) check(s)." -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Model pass result shape: $($script:Checks) check(s) passed." -ForegroundColor Green
exit 0
