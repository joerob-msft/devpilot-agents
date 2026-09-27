function ConvertTo-PrivateCanaryIdentityOutput {
    param(
        [Parameter(Mandatory)][string]$Json,
        [bool]$Run,
        [bool]$VerifyGraph
    )
    try { $result = ConvertFrom-Json -InputObject $Json -AsHashtable -Depth 4 }
    catch { throw 'identity-diagnostic-result-invalid' }
    $fields = @('state', 'reason', 'getAttempts', 'providerWrites',
        'modelToolInvocations')
    if ($result -isnot [Collections.IDictionary] -or
        $result.Count -ne $fields.Count -or
        @($fields | Where-Object { -not $result.Contains($_) }).Count -ne 0) {
        throw 'identity-diagnostic-result-invalid'
    }
    $attempts = $result['getAttempts']
    if ($attempts -isnot [long] -and $attempts -isnot [int]) {
        throw 'identity-diagnostic-result-invalid'
    }
    if (($result['providerWrites'] -isnot [long] -and
            $result['providerWrites'] -isnot [int]) -or
        ($result['modelToolInvocations'] -isnot [long] -and
            $result['modelToolInvocations'] -isnot [int]) -or
        $result['providerWrites'] -ne 0 -or
        $result['modelToolInvocations'] -ne 0) {
        throw 'identity-diagnostic-result-invalid'
    }
    if (-not $Run) {
        if ($result['state'] -cne 'disabled' -or
            $result['reason'] -cne 'disabled' -or $attempts -ne 0) {
            throw 'identity-diagnostic-result-invalid'
        }
    } else {
        $reasons = @('valid', 'identity-fields-missing',
            'identity-fields-invalid', 'optional-name-mismatch',
            'graph-user-mismatch', 'storage-key-mismatch', 'http-failure',
            'encoded-response', 'non-json-media', 'utf8-bom',
            'invalid-utf8', 'invalid-json', 'json-depth-over-12',
            'unclassified')
        if (-not $VerifyGraph) {
            $reasons += @('principal-mismatch', 'send-failure', 'read-failure')
        }
        $maximum = if ($VerifyGraph) { 3 } else { 1 }
        if ($attempts -lt 1 -or $attempts -gt $maximum -or
            $result['reason'] -cnotin $reasons -or
            ($result['state'] -ceq 'verified' -and
                ($result['reason'] -cne 'valid' -or
                    $attempts -ne $maximum)) -or
            ($result['state'] -ceq 'unknown' -and
                $result['reason'] -ceq 'valid') -or
            $result['state'] -cnotin @('verified', 'unknown')) {
            throw 'identity-diagnostic-result-invalid'
        }
    }
    [ordered]@{
        state = $result['state']
        reason = $result['reason']
        getAttempts = [long]$attempts
        providerWrites = 0
        modelToolInvocations = 0
    } | ConvertTo-Json -Compress -Depth 2
}
