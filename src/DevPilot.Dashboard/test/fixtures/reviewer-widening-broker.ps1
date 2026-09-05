param([string]$DescriptorPath)
$descriptor = Get-Content -Raw -Path $DescriptorPath | ConvertFrom-Json
$requestLogPath = $descriptor.requestLogPath
$dispatchEventLogPath = $descriptor.dispatchEventLogPath
if ($dispatchEventLogPath) {
  New-Item -ItemType File -Force -Path $dispatchEventLogPath | Out-Null
}
$repositoryIdentity = @{
  schemaVersion = 1
  provider = 'GitHub'
  repositoryId = '10400000000000001'
  organization = 'devpilot'
  project = ''
  repositoryName = 'operations-dashboard'
  slug = 'devpilot/operations-dashboard'
  key = 'v1:github:10400000000000001'
  verifiedAtUtc = '2026-09-03T15:00:00Z'
  verified = $true
  dispatchEligible = $true
}
$prSnapshot = @{
  schemaVersion = 1
  pullRequestId = 104
  sourceCommit = ('a' * 40)
  sourceRef = 'contributor/issue-105-pr2'
  targetRef = 'main'
  active = $true
  draft = $false
  author = 'Ada'
  title = 'ConPTY widening flow'
}
$baseCapabilities = @('EnableSummaryComment', 'EnableThreadReplies', 'EnableFindingComments')
$baseMandatoryDenies = @('EnableApprovalVote')
$delegableAvailable = @('EnableApprovalVote')
$absoluteDenies = @('EnableAutoComplete')
$allowedManualCapabilities = @('EnableSummaryComment', 'EnableThreadReplies', 'EnableFindingComments')
$baselineDigest = ('1' * 64)
$widenedDigest = ('2' * 64)
$prStateFingerprint = ('3' * 64)
$dispatchDraftId = '11111111-1111-1111-1111-111111111111'
$dispatchId = '22222222-2222-2222-2222-222222222222'
$previewChallenge = ('a' * 48)
$summaryChallenge = ('b' * 48)
$previewExpiresAtUtc = [DateTime]::UtcNow.AddMinutes(10).ToString('o')
$summaryExpiresAtUtc = [DateTime]::UtcNow.AddMinutes(11).ToString('o')
$grantExpiresAtUtc = [DateTimeOffset]::UtcNow.AddHours(8).ToUnixTimeSeconds()
$previewDiff = @{
  addedCapabilities = @('EnableApprovalVote')
  removedDenies = @('EnableApprovalVote')
  pairedCapability = 'EnableFindingComments'
  pairedCapabilityActive = $true
}
$wideningStage = $null
$wideningGeneration = 0
$dispatchActive = $false
function Append-Log([object]$request) {
  [System.IO.File]::AppendAllText($requestLogPath, (($request | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine))
}
function Provenance([bool]$widened) {
  if ($widened) {
    return [ordered]@{
      EnableFindingComments = 'repo-worktree'
      EnableSummaryComment = 'machine'
      EnableThreadReplies = 'user'
      EnableApprovalVote = 'repo-worktree'
    }
  }
  return [ordered]@{
    EnableFindingComments = 'repo-worktree'
    EnableSummaryComment = 'machine'
    EnableThreadReplies = 'user'
    EnableApprovalVote = 'operational-default'
  }
}
function Current-Effect([bool]$widened) {
  $capabilities = if ($widened) { @('EnableSummaryComment', 'EnableThreadReplies', 'EnableFindingComments', 'EnableApprovalVote') } else { @($baseCapabilities) }
  $mandatoryDenies = [System.Collections.Generic.List[string]]::new()
  if (-not $widened) { [void]$mandatoryDenies.Add('EnableApprovalVote') }
  return @{
    capabilities = [string[]]$capabilities
    mandatoryDenies = $mandatoryDenies
    provenance = Provenance $widened
  }
}
function Describe-Response([object]$request) {
  $effect = Current-Effect $false
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'capability-summary'
    role = $request.role
    dispatchDraftId = $dispatchDraftId
    repositoryIdentity = $repositoryIdentity
    prSnapshot = $prSnapshot
    capabilityPolicyDigest = $baselineDigest
    prStateFingerprint = $prStateFingerprint
    capabilities = [string[]]$effect.capabilities
    mandatoryDenies = [string[]]$effect.mandatoryDenies
    dynamicConstraints = @()
    absoluteDenies = [string[]]$absoluteDenies
    allowedManualCapabilities = [string[]]$allowedManualCapabilities
    delegableAvailable = [string[]]$delegableAvailable
    provenance = $effect.provenance
    killSwitchActive = $false
    killSwitchExpiresAtUtc = $null
  } | ConvertTo-Json -Compress -Depth 10
}
function Describe-Widening([object]$request) {
  if ($request.capability -ne 'EnableApprovalVote') { throw 'unexpected widening capability' }
  if ($script:wideningStage -eq 'minted') { throw 'widening already minted' }
  $script:wideningStage = 'previewed'
  $script:wideningGeneration = 1
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'widening-preview'
    state = 'previewed'
    dispatchDraftId = $dispatchDraftId
    capability = $request.capability
    challenge = $previewChallenge
    effectiveDiff = $previewDiff
    expiresAtUtc = $previewExpiresAtUtc
    generation = $script:wideningGeneration
  } | ConvertTo-Json -Compress -Depth 10
}
function Confirm-Widening-Preview([object]$request) {
  if ($script:wideningStage -ne 'previewed' -or $request.capability -ne 'EnableApprovalVote' -or $request.challenge -ne $previewChallenge) {
    throw 'unexpected widening preview confirmation'
  }
  $script:wideningStage = 'summary'
  $script:wideningGeneration++
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'widening-summary'
    state = 'awaiting-final-confirmation'
    dispatchDraftId = $dispatchDraftId
    capability = $request.capability
    challenge = $summaryChallenge
    effectiveDiff = $previewDiff
    expiresAtUtc = $summaryExpiresAtUtc
    generation = $script:wideningGeneration
  } | ConvertTo-Json -Compress -Depth 10
}
function Confirm-Widening-Mint([object]$request) {
  if ($script:wideningStage -ne 'summary' -or $request.capability -ne 'EnableApprovalVote' -or $request.challenge -ne $summaryChallenge) {
    throw 'unexpected widening mint confirmation'
  }
  $script:wideningStage = 'minted'
  $script:wideningGeneration++
  $effect = Current-Effect $true
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'widening-minted'
    state = 'minted'
    dispatchDraftId = $dispatchDraftId
    capability = $request.capability
    capabilities = [string[]]$effect.capabilities
    mandatoryDenies = [string[]]$effect.mandatoryDenies
    capabilityPolicyDigest = $widenedDigest
    effectiveDiff = $previewDiff
    grantExpiresAtUtc = $grantExpiresAtUtc
    generation = $script:wideningGeneration
  } | ConvertTo-Json -Compress -Depth 10
}
function Cancel-Widening([object]$request) {
  if ($script:wideningStage -notin @('previewed', 'summary', 'minted')) {
    throw 'unexpected widening cancellation'
  }
  if ($request.generation -ne $script:wideningGeneration) {
    throw 'unexpected widening generation'
  }
  $script:wideningStage = $null
  $script:wideningGeneration++
  $effect = Current-Effect $false
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'widening-cancelled'
    state = 'cancelled'
    dispatchDraftId = $dispatchDraftId
    capabilities = [string[]]$effect.capabilities
    mandatoryDenies = [string[]]$effect.mandatoryDenies
    capabilityPolicyDigest = $baselineDigest
    delegableAvailable = [string[]]$delegableAvailable
    generation = $script:wideningGeneration
  } | ConvertTo-Json -Compress -Depth 10
}
function Dispatch-Response([object]$request) {
  if ($script:wideningStage -ne 'minted') { throw 'widening grant not minted' }
  if ($request.dispatchDraftId -ne $dispatchDraftId -or $request.capabilityPolicyDigest -ne $widenedDigest -or $request.prStateFingerprint -ne $prStateFingerprint) {
    throw 'dispatch bindings do not match the widened draft'
  }
  $script:dispatchActive = $true
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'accepted'
    dispatchId = $dispatchId
    repositoryIdentity = $repositoryIdentity
    pullRequestId = 104
    role = $request.role
    capabilityPolicyDigest = $widenedDigest
    prStateFingerprint = $prStateFingerprint
    childProcessId = 4242
    eventLogPath = $dispatchEventLogPath
  } | ConvertTo-Json -Compress -Depth 10
}
function Cancel-Dispatch([object]$request) {
  if (-not $script:dispatchActive) { throw 'dispatch is not active' }
  $script:dispatchActive = $false
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'cancelled'
    dispatchId = $request.dispatchId
    result = 'cooperatively'
    handleReleaseObserved = $true
  } | ConvertTo-Json -Compress -Depth 10
}
$accepting = $true
while ($accepting -and $null -ne ($line = [Console]::In.ReadLine())) {
  $request = $line | ConvertFrom-Json
  Append-Log $request
  switch ($request.operation) {
    'describe' { Write-Output (Describe-Response $request) }
    'describe-widening' { Write-Output (Describe-Widening $request) }
    'confirm-widening-preview' { Write-Output (Confirm-Widening-Preview $request) }
    'confirm-widening-mint' { Write-Output (Confirm-Widening-Mint $request) }
    'cancel-widening' { Write-Output (Cancel-Widening $request) }
    'dispatch' { Write-Output (Dispatch-Response $request) }
    'cancel' { Write-Output (Cancel-Dispatch $request) }
    'shutdown' {
      $accepting = $false
      Write-Output (@{
        schemaVersion = 1
        requestId = $request.requestId
        operation = 'shutdown-complete'
      } | ConvertTo-Json -Compress -Depth 10)
    }
    default { throw "unexpected operation $($request.operation)" }
  }
}
