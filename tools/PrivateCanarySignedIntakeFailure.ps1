function Write-PrivateCanarySignedIntakeFailure {
    param([Parameter(Mandatory)][Collections.IDictionary]$Diagnostic)
    $Diagnostic | ConvertTo-Json -Depth 10 -Compress
    if ($Diagnostic.failureCode -ceq 'canary-private-state-cleanup-failed') {
        throw 'canary-private-state-cleanup-failed'
    }
    throw 'canary-signed-intake-blocked'
}
