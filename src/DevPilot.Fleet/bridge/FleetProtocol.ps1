function New-FleetResultSchema {
    param([string]$Nonce, [string]$InputHash)
    return @{
        Keys = @('schemaVersion', 'nonce', 'inputHash', 'summary', 'findings')
        Fields = @{
            schemaVersion = @{ Type = 'int'; Min = 1; Max = 1 }
            nonce = @{ Type = 'exact'; Expected = $Nonce }
            inputHash = @{ Type = 'exact'; Expected = $InputHash }
            summary = @{ Type = 'string'; MaxLength = 4000; AllowNewlines = $true }
            findings = @{
                Type = 'objectArray'; MaxItems = 8
                Item = @{
                    Keys = @('title', 'evidence', 'recommendation')
                    Fields = @{
                        title = @{ Type = 'string'; MaxLength = 200 }
                        evidence = @{ Type = 'string'; MaxLength = 1500; AllowNewlines = $true }
                        recommendation = @{ Type = 'string'; MaxLength = 1500; AllowNewlines = $true }
                    }
                }
            }
        }
    }
}

function ConvertFrom-FleetAnswer {
    param([string]$Answer, [hashtable]$Schema)
    $trimmed = $Answer.Trim()
    if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) {
        # A complete bare JSON object is equivalent to the prefixed form, not a last-object-wins fallback.
        try {
            $value = ConvertFrom-Json -InputObject $trimmed -ErrorAction Stop
            if ($value -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        }
        catch { return $null }
        $trimmed = "FLEET_RESULT: $trimmed"
    }
    return ConvertFrom-AgentResultMarker -StdOutText $trimmed -MarkerPrefix 'FLEET_RESULT:' -Schema $Schema
}
