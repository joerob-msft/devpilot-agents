param([string]$DescriptorPath)
$descriptor = Get-Content -Raw -Path $DescriptorPath | ConvertFrom-Json
$requestLogPath = $descriptor.requestLogPath
$dispatchEventLogPath = $descriptor.dispatchEventLogPath
$simpleFlow = $descriptor.simpleFlow -eq $true
if ($dispatchEventLogPath -and -not $simpleFlow) {
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
if ($simpleFlow) {
  $delegableAvailable = @()
  if ($descriptor.role -eq 'review-handler') {
    $baseCapabilities = @('EnableCodeChanges', 'EnablePush', 'EnableThreadReplies', 'LocalValidation')
    $baseMandatoryDenies = @('EnableAutoComplete')
  }
  if ($descriptor.previewOnly -eq $true) { $baseCapabilities = @() }
  $allowedManualCapabilities = @($baseCapabilities)
}
$baselineDigest = ('1' * 64)
$widenedDigest = ('2' * 64)
$prStateFingerprint = ('3' * 64)
$dispatchDraftId = '11111111-1111-1111-1111-111111111111'
$dispatchId = if ($descriptor.dispatchId) {
  [Guid]::Parse([string]$descriptor.dispatchId).ToString()
} else { [Guid]::NewGuid().ToString() }
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
$scanRequests = 0
function Append-Log([object]$request) {
  [System.IO.File]::AppendAllText($requestLogPath, (($request | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine))
}
function Assert-AutomationRequest([object]$request) {
  if ((($request.PSObject.Properties.Name | Sort-Object) -join ',') -ne 'operation,requestId,schemaVersion') {
    throw 'Automation status and scan requests must not carry PIDs, roles or other arguments.'
  }
}
function Automation-Status-Response([object]$request) {
  Assert-AutomationRequest $request
  $response = @{
    schemaVersion=1;requestId=$request.requestId;operation='automation-status';automationVersion=1
    available=$false;scope=$null;agents=@()
  }
  if ($descriptor.automationFlow -eq $true) {
    $response.available = $true
    $response.scope = 'current-launcher'
    $response.agents = @(
      @{role='reviewer';continuous=$true;intervalSeconds=900;state='waiting';canScanNow=$true},
      @{role='review-handler';continuous=$true;intervalSeconds=900;state='scanning';canScanNow=$false}
    )
  }
  return $response | ConvertTo-Json -Compress -Depth 10
}
function Scan-Now-Response([object]$request) {
  Assert-AutomationRequest $request
  if ($descriptor.automationFlow -ne $true) {
    return @{schemaVersion=1;requestId=$request.requestId;operation='rejected'
      code='automation-unavailable';detail='This fixture does not own an automatic launcher.'
    } | ConvertTo-Json -Compress
  }
  $script:scanRequests++
  Start-Sleep -Milliseconds 700
  $reviewerOutcome = if ($descriptor.automationManualPriorityAfterFirst -eq $true -and $script:scanRequests -gt 1) {
    'manual-priority'
  } else { 'requested' }
  return @{schemaVersion=1;requestId=$request.requestId;operation='scan-now-result'
    automationVersion=1;scope='current-launcher';results=@(
      @{role='reviewer';outcome=$reviewerOutcome},
      @{role='review-handler';outcome='already-running'}
    )
  } | ConvertTo-Json -Compress -Depth 10
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
  if ($simpleFlow) {
    return @{
      capabilities = [string[]]$baseCapabilities
      mandatoryDenies = [string[]]$baseMandatoryDenies
      provenance = @{}
    }
  }
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
  $response = @{
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
  }
  if ($request.operation -eq 'profile-current') {
    $response.operation = 'capability-profile'
    foreach ($field in @('dispatchDraftId', 'capabilityPolicyDigest', 'prStateFingerprint')) { $response.Remove($field) }
  }
  return $response | ConvertTo-Json -Compress -Depth 10
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
  if (-not $simpleFlow -and $script:wideningStage -ne 'minted') { throw 'widening grant not minted' }
  $expectedDigest = if ($simpleFlow) { $baselineDigest } else { $widenedDigest }
  if ($request.dispatchDraftId -ne $dispatchDraftId -or $request.capabilityPolicyDigest -ne $expectedDigest -or $request.prStateFingerprint -ne $prStateFingerprint) {
    throw 'dispatch bindings do not match the widened draft'
  }
  $script:dispatchActive = $true
  if ($simpleFlow) { Start-Sleep -Milliseconds 700 }
  return @{
    schemaVersion = 1
    requestId = $request.requestId
    operation = 'accepted'
    dispatchId = $dispatchId
    repositoryIdentity = $repositoryIdentity
    pullRequestId = 104
    role = $request.role
    capabilityPolicyDigest = $expectedDigest
    prStateFingerprint = $prStateFingerprint
    childProcessId = 4242
    eventLogPath = $dispatchEventLogPath
  } | ConvertTo-Json -Compress -Depth 10
}
function Cancel-Dispatch([object]$request) {
  if (-not $script:dispatchActive) { throw 'dispatch is not active' }
  if ($request.dispatchId -ne $dispatchId) { throw 'dispatch cancellation ID does not match the active fixture dispatch' }
  $script:dispatchActive = $false
  if ($simpleFlow) { Start-Sleep -Milliseconds 400 }
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
    'get-automation-status' { Write-Output (Automation-Status-Response $request) }
    'scan-now' { Write-Output (Scan-Now-Response $request) }
    'profile-current' { Write-Output (Describe-Response $request) }
    'describe' { Write-Output (Describe-Response $request) }
    'describe-widening' { Write-Output (Describe-Widening $request) }
    'confirm-widening-preview' { Write-Output (Confirm-Widening-Preview $request) }
    'confirm-widening-mint' { Write-Output (Confirm-Widening-Mint $request) }
    'cancel-widening' { Write-Output (Cancel-Widening $request) }
    'dispatch' {
      Write-Output (Dispatch-Response $request)
      if ($simpleFlow -and $descriptor.complete -eq $true) {
        Start-Sleep -Seconds 4
        $script:dispatchActive = $false
        Write-Output (@{
          schemaVersion = 1
          requestId = $request.requestId
          operation = 'completed'
          dispatchId = $dispatchId
          exitCode = 0
        } | ConvertTo-Json -Compress)
      }
    }
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
