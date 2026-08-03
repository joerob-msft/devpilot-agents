#requires -Version 7.0

<#
.SYNOPSIS
    Portable, repo-agnostic harness for autonomous Copilot CLI agents.

.DESCRIPTION
    Shared building blocks for the API Hub autonomous-agent fleet (reviewer,
    review-handler, and future agents). This module carries NO repository,
    organization, project, pipeline, or Teams identifiers - every repo-specific
    value lives in a per-agent JSON config and is passed in by the thin wrapper
    script. Dropping `.github/copilot/agents/` into another Azure DevOps repo
    plus editing the config must be sufficient; nothing here needs editing.

    Every export is designed to be directly unit-testable in a wrapper's
    -DryRun self-checks without network access, ADO, or a real Copilot process.

    SECURITY NOTES:
      - The Copilot model is never granted a generic write tool. Wrappers own
        every PR/pipeline mutation and pass explicit allow/deny tool lists.
      - Config may NARROW a wrapper's code-defined allow-tool ceiling but never
        widen it (Test-AgentAllowToolCeiling); mandatory denies always win.
      - State files are wrapper-owned and never written by Copilot.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Code-defined Copilot CLI model allowlist (NOT config-supplied - a forked or
# compromised config file must never be able to widen this). `--model <id>`
# takes exactly one separate following argv entry. "auto" is intentionally
# excluded: agents want reproducible behavior, and "auto" is non-deterministic.
# Update ONLY this array when Copilot CLI adds/retires a model.
# ---------------------------------------------------------------------------
$script:AgentHarnessSupportedModels = @(
    "claude-sonnet-5",
    "claude-sonnet-4.6",
    "claude-haiku-4.5",
    "claude-opus-5",
    "claude-opus-4.8",
    "claude-opus-4.7",
    "claude-opus-4.6",
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-5.6-luna",
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.3-codex",
    "gpt-5.4-mini",
    "gpt-5-mini",
    "gemini-3.1-pro-preview",
    "gemini-3.6-flash",
    "gemini-3.5-flash",
    "grok-4.5",
    "mai-code-1-flash-picker"
)
$script:AgentHarnessDefaultModelSentinel = "copilot-cli-default"

function Get-AgentSupportedModels {
    return , @($script:AgentHarnessSupportedModels)
}

function Get-AgentDefaultModelSentinel {
    return $script:AgentHarnessDefaultModelSentinel
}

function Assert-AgentSupportedModel {
    param(
        [Parameter(Mandatory)][string]$ModelId,
        [string[]]$SupportedModels,
        [string]$Where = "model"
    )
    $allowed = if ($SupportedModels -and @($SupportedModels).Count -gt 0) { @($SupportedModels) } else { @($script:AgentHarnessSupportedModels) }
    if ($allowed -cnotcontains $ModelId) {
        throw "$Where : unsupported model id '$ModelId'. Allowed: $($allowed -join ', ')."
    }
    return $ModelId
}

# ---------------------------------------------------------------------------
# Parser / decision helpers (pure; unit-testable in -DryRun)
# ---------------------------------------------------------------------------

function Test-ParserValidity {
    <# Returns the (possibly empty) array of parse errors for a .ps1/.psm1 file. #>
    param([Parameter(Mandatory)][string]$Path)
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    return , @($errors)
}

function Test-AgentValidatedParamRebind {
    <#
        Detects a PowerShell footgun: a parameter carrying a validation
        attribute that is later re-assigned in the same scope. The attribute
        stays bound to the VARIABLE, and variable names are case-INSENSITIVE, so

            param([ValidateSet("pending","confirmed")][string]$State)
            $state = Get-JsonState -Path $p     # same variable!

        re-validates the hashtable against the ValidateSet and throws at
        runtime. This shipped undetected in a sibling agent and silently broke
        an entire code path, so it is checked mechanically rather than by
        review. Lives in the harness because every agent needs it and a copied
        detector is a detector that drifts.

        Returns a (possibly empty) array of human-readable findings.
    #>
    param([Parameter(Mandatory)][string[]]$ScriptPath)
    $attrNames = @('ValidateSet', 'ValidateRange', 'ValidatePattern', 'ValidateLength', 'ValidateScript', 'ValidateCount')
    $findings = New-Object System.Collections.Generic.List[string]

    foreach ($file in $ScriptPath) {
        $parseErrors = $null; $parseTokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $file).Path, [ref]$parseTokens, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) { continue }

        $scopes = New-Object System.Collections.Generic.List[object]
        [void]$scopes.Add([pscustomobject]@{ Label = '<script>'; ParamBlock = $ast.ParamBlock; Body = $ast })
        foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            [void]$scopes.Add([pscustomobject]@{ Label = $fn.Name; ParamBlock = $fn.Body.ParamBlock; Body = $fn.Body })
        }

        foreach ($scope in $scopes) {
            if (-not $scope.ParamBlock) { continue }
            $validated = @{}
            foreach ($p in $scope.ParamBlock.Parameters) {
                $attrs = @($p.Attributes | Where-Object { $attrNames -contains $_.TypeName.Name })
                if ($attrs.Count -gt 0) { $validated[$p.Name.VariablePath.UserPath.ToLowerInvariant()] = ($attrs | ForEach-Object { $_.TypeName.Name }) -join ',' }
            }
            if ($validated.Count -eq 0) { continue }

            $assignments = $scope.Body.FindAll({
                    param($a)
                    $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $a.Left -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true)
            foreach ($asn in $assignments) {
                $key = $asn.Left.VariablePath.UserPath.ToLowerInvariant()
                if (-not $validated.ContainsKey($key)) { continue }
                # An assignment inside a NESTED function is a different scope.
                $node = $asn; $nested = $false
                while ($node.Parent) {
                    $node = $node.Parent
                    if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ne $scope.Label) { $nested = $true; break }
                }
                if ($nested) { continue }
                [void]$findings.Add("$(Split-Path $file -Leaf) L$($asn.Extent.StartLineNumber) in $($scope.Label): `$$($asn.Left.VariablePath.UserPath) carries [$($validated[$key])] and is re-assigned")
            }
        }
    }
    # NOT `return ,$array`: for an EMPTY array that emits a single element which
    # is itself the empty array, so callers see one bogus finding. Returning the
    # array plainly emits zero elements when empty and N when populated.
    return $findings.ToArray()
}

function Get-OnceFinalExitCode {
    <#
        Pure decision function factored out so the "-Once must never mask a
        failed/timed-out cycle as exit 0" rule can be regression-tested
        directly. Loop mode never reaches this decision point in Main.
    #>
    param([bool]$IsOnce, [bool]$IsDryRun, [int]$LastCycleExitCode)
    if ($IsOnce -and -not $IsDryRun -and $LastCycleExitCode -ne 0) { return 1 }
    return 0
}

function Test-StrictJsonInt {
    <#
        True only for a genuine JSON-deserialized Int32/Int64 within [Min,Max].
        Never coerces a string ("5"), a boolean ($true/$false -> 1/0 under a
        bare [int] cast), a decimal, or $null. Anti-coercion guard against a
        hostile marker smuggling "999999999999" or `true` through [int]$x.
    #>
    param($Value, [long]$Min, [long]$Max)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $false }
    if (-not ($Value -is [int] -or $Value -is [long])) { return $false }
    $asLong = [long]$Value
    if ($asLong -lt $Min -or $asLong -gt $Max) { return $false }
    return $true
}

function New-AgentNonce {
    <#
        Cryptographically random per-cycle nonce (18 bytes, lowercase hex).
        Not a secret - never withheld from the prompt - but unpredictable
        enough that a stale/captured result marker cannot be replayed into a
        later cycle. The result marker must echo it back exactly (case
        sensitive) or ConvertFrom-AgentResultMarker rejects the marker.
    #>
    $bytes = New-Object byte[] 18
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Test-AgentProtectedBranch {
    <#
        True if $Branch matches a protected pattern (exact, case-insensitive,
        or a 'prefix/*' wildcard). An empty/unresolvable branch is treated as
        protected (fail closed) so a wrapper never pushes on uncertainty.
        Patterns are passed in by the wrapper - the harness hardcodes no
        repo-specific branch names.
    #>
    param(
        [string]$Branch,
        [string[]]$ProtectedPatterns = @('dev', 'main', 'master', 'release/*')
    )
    if ($null -eq $Branch) { return $true }
    $norm = ($Branch -replace '^refs/heads/', '').Trim()
    if ($norm -eq '') { return $true }
    foreach ($pat in @($ProtectedPatterns)) {
        $p = ($pat -replace '^refs/heads/', '').Trim()
        if ($p -eq '') { continue }
        if ($p.EndsWith('/*')) {
            $prefix = $p.Substring(0, $p.Length - 1)
            if ($norm.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        elseif ($norm -ieq $p) {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Config loading (generic; fail-closed)
# ---------------------------------------------------------------------------

function Get-AgentConfigProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where)
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { throw "$Where must be a JSON object." }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop) { throw "$Where.$Name is a required key and is missing." }
    return $prop.Value
}

function Get-AgentConfigString {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where, [int]$MaxLength = 256, [string]$Pattern, [switch]$AllowEmpty)
    $value = Get-AgentConfigProperty -Object $Object -Name $Name -Where $Where
    if ($value -isnot [string] -or $value.Length -gt $MaxLength) {
        throw "$Where.$Name must be a string of at most $MaxLength characters."
    }
    if (-not $AllowEmpty -and $value.Trim() -eq "") {
        throw "$Where.$Name must be a non-empty string of at most $MaxLength characters."
    }
    if ($Pattern -and $value -notmatch $Pattern) {
        throw "$Where.$Name '$value' does not match the required format."
    }
    return $value
}

function Get-AgentConfigInt {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where, [long]$Min, [long]$Max)
    $value = Get-AgentConfigProperty -Object $Object -Name $Name -Where $Where
    if ($null -eq $value -or $value -is [bool] -or -not ($value -is [int] -or $value -is [long] -or $value -is [double])) {
        throw "$Where.$Name must be a JSON integer."
    }
    if ($value -is [double] -and $value -ne [Math]::Floor($value)) {
        throw "$Where.$Name must be a JSON integer (no fractional component)."
    }
    $intValue = [long]$value
    if ($intValue -lt $Min -or $intValue -gt $Max) {
        throw "$Where.$Name must be between $Min and $Max (got $intValue)."
    }
    return $intValue
}

function Get-AgentConfigBool {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where)
    $value = Get-AgentConfigProperty -Object $Object -Name $Name -Where $Where
    if ($value -isnot [bool]) { throw "$Where.$Name must be a JSON boolean." }
    return $value
}

function Get-AgentConfigObject {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where)
    $value = Get-AgentConfigProperty -Object $Object -Name $Name -Where $Where
    if ($value -isnot [System.Management.Automation.PSCustomObject]) { throw "$Where.$Name must be a JSON object." }
    return $value
}

function Get-AgentConfigStringArray {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where, [int]$MaxItems = 128, [int]$MaxItemLength = 256)
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { throw "$Where must be a JSON object." }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop) { throw "$Where.$Name is a required key and is missing." }
    $rawValue = $prop.Value
    if ($rawValue -is [string] -or $rawValue -is [System.Management.Automation.PSCustomObject]) {
        throw "$Where.$Name must be a JSON array of strings."
    }
    $items = @()
    if ($null -ne $rawValue) { $items = @($rawValue) }
    if ($items.Count -gt $MaxItems) { throw "$Where.$Name must have at most $MaxItems entries." }
    foreach ($item in $items) {
        if ($item -isnot [string] -or $item.Trim() -eq "" -or $item.Length -gt $MaxItemLength) {
            throw "$Where.$Name entries must be non-empty strings of at most $MaxItemLength characters."
        }
    }
    return , @($items)
}

function Get-AgentConfig {
    <#
        Loads and generically validates a per-agent JSON config, failing closed
        on anything missing/malformed. Enforces: single JSON object top level;
        an integer schemaVersion within $SupportedSchemaVersions; and a prompt
        file field that is a BARE file name (no separators, no '..') resolving
        to an existing file under $AgentDir. Repo-specific field validation is
        left to the wrapper via the Get-AgentConfig* accessors so this stays
        portable.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AgentDir,
        [int[]]$SupportedSchemaVersions = @(1),
        [string]$PromptFileField = "promptFile"
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Agent config '$Path' does not exist or is not a regular file."
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    try {
        $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Agent config '$resolved' is not valid JSON ($($_.Exception.Message))."
    }
    if ($cfg -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Agent config '$resolved' must contain a single JSON object."
    }
    $svProp = $cfg.PSObject.Properties["schemaVersion"]
    if (-not $svProp) { throw "Agent config '$resolved': 'schemaVersion' is required." }
    if (-not (Test-StrictJsonInt -Value $svProp.Value -Min ([long][int]::MinValue) -Max ([long][int]::MaxValue))) {
        throw "Agent config '$resolved': 'schemaVersion' must be a JSON integer."
    }
    $schemaVersion = [int]$svProp.Value
    if (@($SupportedSchemaVersions) -notcontains $schemaVersion) {
        throw "Agent config '$resolved': unsupported schemaVersion $schemaVersion (supported: $(@($SupportedSchemaVersions) -join ', '))."
    }
    $pfProp = $cfg.PSObject.Properties[$PromptFileField]
    if (-not $pfProp) { throw "Agent config '$resolved': '$PromptFileField' is required." }
    $promptName = $pfProp.Value
    if ($promptName -isnot [string] -or $promptName.Trim() -eq "" -or $promptName.Length -gt 128) {
        throw "Agent config '$resolved': '$PromptFileField' must be a non-empty string of at most 128 characters."
    }
    if ($promptName -match '[\\/]' -or $promptName -match '\.\.') {
        throw "Agent config '$resolved': '$PromptFileField' must be a bare file name (no path separators or '..')."
    }
    $agentDirResolved = (Resolve-Path -LiteralPath $AgentDir).Path
    $promptPath = Join-Path $agentDirResolved $promptName
    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) {
        throw "Agent config '$resolved': prompt file '$promptName' does not exist under '$agentDirResolved'."
    }
    $promptPath = (Resolve-Path -LiteralPath $promptPath).Path
    if (-not $promptPath.StartsWith($agentDirResolved + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Agent config '$resolved': prompt file resolved outside '$agentDirResolved'."
    }
    return @{
        Raw            = $cfg
        ConfigPath     = $resolved
        PromptFileName = [string]$promptName
        PromptFilePath = $promptPath
        SchemaVersion  = $schemaVersion
    }
}

function Test-AgentAllowToolCeiling {
    <#
        A config allow-list may NARROW a wrapper's code-defined ceiling but
        never widen it, and may never name a mandatory-denied tool. Throws
        (fail closed) on any violation. Case-sensitive membership.
    #>
    param(
        [string[]]$Candidates,
        [Parameter(Mandatory)][string[]]$Ceiling,
        [string[]]$MandatoryDeny = @(),
        [string]$Where = "allowTools"
    )
    $cands = @($Candidates)
    $unsupported = @($cands | Where-Object { @($Ceiling) -cnotcontains $_ })
    if ($unsupported.Count -gt 0) {
        throw "$Where contains tool(s) outside the code-defined supported ceiling: $($unsupported -join ', ')."
    }
    $denied = @($cands | Where-Object { @($MandatoryDeny) -ccontains $_ })
    if ($denied.Count -gt 0) {
        throw "$Where contains tool(s) that are also mandatory-denied and can never be allowed: $($denied -join ', ')."
    }
}

function Get-AgentCopilotArgs {
    <#
        Builds the FULL argument list for the `agency` executable:

          agency copilot [-a <agent> --source <source>] -- <engine args...>

        `-a <agent> --source <source>` are Agency's OWN options and are
        OPTIONAL. Omit them (pass an empty -AgentName) when the agent's own
        cycle prompt is the complete instruction set: loading an unrelated
        repo custom agent on top of a single-purpose autonomous prompt makes
        the model follow that agent's persona instead of the cycle contract.
        The literal `--` is REQUIRED so the engine-facing flags after it (-s,
        --no-ask-user, --disallow-temp-dir, --allow-tool, --deny-tool,
        --model, --resume) reach the Copilot engine and are not reinterpreted
        by Agency's own parser. `--model` and its id are two SEPARATE argv
        entries. Model is validated against a code-defined allowlist.
    #>
    param(
        [string]$AgentName,
        [string]$Source,
        [string[]]$AllowTools = @(),
        [string[]]$DenyTools = @(),
        [string]$Model,
        [switch]$UseYolo,
        [string]$ResumeSessionId,
        [string[]]$SupportedModels,
        [switch]$JsonOutput
    )
    $allow = @($AllowTools)
    $deny = @($DenyTools)
    $engineArgs = @("-s", "--no-ask-user", "--disallow-temp-dir")
    if ($JsonOutput) { $engineArgs += @("--output-format", "json") }
    if ($UseYolo) {
        $engineArgs += "--yolo"
    }
    elseif ($allow.Count -gt 0) {
        $engineArgs += @("--allow-tool=$($allow -join ', ')")
    }
    if ($deny.Count -gt 0) {
        $engineArgs += @("--deny-tool=$($deny -join ', ')")
    }
    if ($Model) {
        $validated = Assert-AgentSupportedModel -ModelId $Model -SupportedModels $SupportedModels -Where "Get-AgentCopilotArgs -Model"
        $engineArgs += @("--model", $validated)
    }
    if ($ResumeSessionId) {
        if ($ResumeSessionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            throw "Get-AgentCopilotArgs: -ResumeSessionId '$ResumeSessionId' is not a valid session GUID."
        }
        $engineArgs += @("--resume", $ResumeSessionId)
    }
    $cliArgs = @("copilot")
    if (-not [string]::IsNullOrWhiteSpace($AgentName)) {
        if ([string]::IsNullOrWhiteSpace($Source)) {
            throw "Get-AgentCopilotArgs: -Source is required whenever -AgentName is supplied."
        }
        $cliArgs += @("-a", $AgentName, "--source", $Source)
    }
    $cliArgs += @("--") + $engineArgs
    return , $cliArgs
}

function Get-AgentSessionIsolationEnvVars {
    <#
        Environment variables that scope a Copilot/Agency process to an EXISTING
        session. They MUST be stripped from every child process this harness
        launches, or the child silently ATTACHES to the parent session instead of
        starting its own.

        This is not theoretical: when an agent wrapper is launched from inside a
        Copilot session (interactive dogfooding, a nested agent, or a Copilot-run
        scheduled task), the inherited COPILOT_AGENT_SESSION_ID / AGENCY_SESSION_ID
        cause the child `agency copilot` to join the PARENT conversation. The
        wrapper then reads the parent's own chatter back as "model output", never
        sees a result marker, and every cycle fails with no obvious cause.

        COPILOT_CUSTOM_INSTRUCTIONS_DIRS is included for the same class of reason:
        it injects the parent's custom instructions into the child, which competes
        with the agent's own cycle prompt.
    #>
    return @(
        "COPILOT_AGENT_SESSION_ID",
        "COPILOT_SESSION_ID",
        "COPILOT_LOADER_PID",
        "COPILOT_CUSTOM_INSTRUCTIONS_DIRS",
        "AGENCY_SESSION_ID",
        "AGENCY_SESSION_SUBPROCESS",
        "AGENCY_OPERATION_ID",
        "AGENCY_LOG_SESSION_DIR",
        "AGENCY_REPO_DIR"
    )
}

# ---------------------------------------------------------------------------
# Locking (OS-level exclusive file handle; released automatically on death)
# ---------------------------------------------------------------------------

function Enter-AgentLock {
    param([Parameter(Mandatory)][string]$Path, [string]$AgentName = "agent")
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw "Another agent instance already holds the lock at '$Path' (StateDir is in use). Use a different -AgentName / -StateDir to run a second instance."
    }
    $stream.SetLength(0)
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.WriteLine("pid=$PID")
    $writer.WriteLine("started=$((Get-Date).ToUniversalTime().ToString('o'))")
    $writer.WriteLine("agent=$AgentName")
    $writer.Flush()
    return $stream
}

function Exit-AgentLock {
    param([System.IO.FileStream]$Stream)
    if ($Stream) { $Stream.Dispose() }
}

# ---------------------------------------------------------------------------
# Wrapper-owned JSON state (never repo-relative, never written by Copilot)
# ---------------------------------------------------------------------------

function Get-JsonState {
    <#
        Reads a wrapper-owned JSON state file into a hashtable. A non-object
        top level is treated as corruption. -FailClosedOnCorruption quarantines
        the file (timestamped rename, never discarded in place) and returns
        $null; otherwise a warning is emitted and an empty map is returned.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$FailClosedOnCorruption)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if (-not $raw -or $raw.Trim() -eq "") { return @{} }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $obj -or $obj -isnot [System.Management.Automation.PSCustomObject]) {
            $shapeName = if ($null -eq $obj) { "null" } else { $obj.GetType().Name }
            throw "State file '$Path' top-level JSON value is not an object (found $shapeName)."
        }
        $ht = @{}
        foreach ($prop in $obj.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        return $ht
    }
    catch {
        if ($FailClosedOnCorruption) {
            $quarantinePath = "$Path.corrupt-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))"
            try {
                Move-Item -LiteralPath $Path -Destination $quarantinePath -Force -ErrorAction Stop
                Write-Warning "State file '$Path' was corrupt and has been quarantined to '$quarantinePath'."
            }
            catch {
                Write-Warning "State file '$Path' was corrupt and could NOT be quarantined."
            }
            return $null
        }
        Write-Warning "State file '$Path' could not be parsed; treating as empty."
        return @{}
    }
}

function Set-JsonState {
    <# Atomic write via temp file + [System.IO.File]::Replace. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$State)
    $tempPath = "$Path.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
    $backupPath = "$Path.bak-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        ($State | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $tempPath -Encoding UTF8
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tempPath, $Path, $backupPath)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-AgentMetadata {
    <# Append one compact JSON object per line to a JSONL log. #>
    param([Parameter(Mandatory)][string]$LogPath, [Parameter(Mandatory)][hashtable]$Fields)
    $entry = [ordered]@{ timestamp = (Get-Date).ToUniversalTime().ToString("o") }
    foreach ($key in $Fields.Keys) { $entry[$key] = $Fields[$key] }
    ($entry | ConvertTo-Json -Compress -Depth 10) | Add-Content -LiteralPath $LogPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Result-marker parsing (generic, schema-driven; hostile input)
# ---------------------------------------------------------------------------

function ConvertTo-AgentMarkerFieldValue {
    <#
        Validates ONE marker field against its typed schema entry and returns
        @{ Ok = $bool; Value = <converted> }. A hashtable result is used rather
        than "$null means invalid" because $null is itself a legal value for the
        nullable types.

        Split out of ConvertFrom-AgentResultMarker so that objectArray items are
        validated by exactly the same code as top-level fields - an array whose
        elements were checked more loosely than scalars would be a silent hole
        in the only boundary that treats model output as hostile.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Spec,
        [AllowNull()]$Value,
        [int]$Depth = 0
    )
    $bad = @{ Ok = $false; Value = $null }
    # objectArray may not contain objectArray. Bounding the nesting keeps the
    # validator's cost linear in the payload and stops a crafted marker from
    # driving deep recursion.
    if ($Depth -gt 1) { return $bad }

    switch ([string]$Spec.Type) {
        "int" {
            if (-not (Test-StrictJsonInt -Value $Value -Min ([long]$Spec.Min) -Max ([long]$Spec.Max))) { return $bad }
            return @{ Ok = $true; Value = [int]$Value }
        }
        "guid" {
            if ($Value -isnot [string] -or $Value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $bad }
            return @{ Ok = $true; Value = [string]$Value }
        }
        "exact" {
            if ($Value -isnot [string] -or $Value -cne [string]$Spec.Expected) { return $bad }
            return @{ Ok = $true; Value = [string]$Value }
        }
        "hex" {
            if ($Value -isnot [string] -or $Value -notmatch "^[0-9a-fA-F]{$([int]$Spec.Length)}$") { return $bad }
            return @{ Ok = $true; Value = [string]$Value }
        }
        "hexOrNull" {
            if ($null -eq $Value) { return @{ Ok = $true; Value = $null } }
            if ($Value -is [string] -and $Value -match "^[0-9a-fA-F]{$([int]$Spec.Length)}$") { return @{ Ok = $true; Value = [string]$Value } }
            return $bad
        }
        "enum" {
            if ($Value -isnot [string] -or (@($Spec.Values) -cnotcontains $Value)) { return $bad }
            return @{ Ok = $true; Value = [string]$Value }
        }
        "bool" {
            if ($Value -isnot [bool]) { return $bad }
            return @{ Ok = $true; Value = [bool]$Value }
        }
        "string" {
            # Free text authored by the model. Length is always bounded, and
            # control characters are rejected outright: this text is destined
            # for a PR comment, and an embedded CR/LF/NUL is the cheapest way to
            # forge structure in something that reads it back line-by-line.
            # Tab and newline are allowed only when the schema opts in.
            if ($Value -isnot [string]) { return $bad }
            $text = [string]$Value
            $max = if ($Spec.ContainsKey('MaxLength')) { [int]$Spec.MaxLength } else { 1000 }
            if ($text.Length -gt $max) { return $bad }
            if (-not ($Spec.ContainsKey('AllowEmpty') -and [bool]$Spec.AllowEmpty) -and $text.Trim() -eq "") { return $bad }
            $allowNewlines = ($Spec.ContainsKey('AllowNewlines') -and [bool]$Spec.AllowNewlines)
            foreach ($ch in $text.ToCharArray()) {
                if ([char]::IsControl($ch)) {
                    if ($allowNewlines -and ($ch -eq "`n" -or $ch -eq "`r" -or $ch -eq "`t")) { continue }
                    return $bad
                }
            }
            if ($Spec.ContainsKey('Pattern') -and $Spec.Pattern) {
                if ($text -notmatch [string]$Spec.Pattern) { return $bad }
            }
            return @{ Ok = $true; Value = $text }
        }
        "objectArray" {
            # A bounded, homogeneous array of flat objects. This exists so a
            # wrapper can receive STRUCTURED results (e.g. review findings) and
            # perform the writes itself, instead of granting the model a write
            # tool and trusting it to use it correctly. Every element is subject
            # to the same exact-key-set rule as the top-level object.
            if ($null -eq $Value) { return $bad }
            # ConvertFrom-Json yields Object[]; a bare object or scalar is not an
            # array and must not be silently promoted to a one-element list.
            if ($Value -isnot [System.Object[]]) { return $bad }
            $items = @($Value)
            $maxItems = if ($Spec.ContainsKey('MaxItems')) { [int]$Spec.MaxItems } else { 25 }
            if ($items.Count -gt $maxItems) { return $bad }
            $itemSchema = $Spec.Item
            if ($null -eq $itemSchema) { return $bad }
            # $itemSchema.Keys must be the DECLARED key list. PowerShell's
            # hashtable adapter returns the 'Keys' entry when one exists, but
            # falls back to the hashtable's own key collection when it does not -
            # which would silently validate elements against ('Keys','Fields').
            # Require both entries so a malformed schema fails closed.
            if ($itemSchema -isnot [hashtable] -or -not $itemSchema.ContainsKey('Keys') -or -not $itemSchema.ContainsKey('Fields')) { return $bad }
            $itemKeys = @($itemSchema.Keys)
            $out = New-Object System.Collections.Generic.List[hashtable]
            foreach ($element in $items) {
                if ($element -isnot [System.Management.Automation.PSCustomObject]) { return $bad }
                $elementKeys = @($element.PSObject.Properties | ForEach-Object { $_.Name })
                foreach ($name in $elementKeys) { if ($itemKeys -notcontains $name) { return $bad } }
                foreach ($name in $itemKeys) { if (-not $element.PSObject.Properties[$name]) { return $bad } }
                $record = @{}
                foreach ($name in $itemKeys) {
                    $fieldSpec = $itemSchema.Fields[$name]
                    if ($null -eq $fieldSpec) { return $bad }
                    $converted = ConvertTo-AgentMarkerFieldValue -Spec $fieldSpec -Value $element.PSObject.Properties[$name].Value -Depth ($Depth + 1)
                    if (-not $converted.Ok) { return $bad }
                    $record[$name] = $converted.Value
                }
                [void]$out.Add($record)
            }
            return @{ Ok = $true; Value = $out.ToArray() }
        }
        default { return $bad }
    }
}

function ConvertFrom-AgentResultMarker {
    <#
        Parses a single strict `<PREFIX>: <json>` result line as HOSTILE input.
        All body logic is wrapped in one try/catch; any invalid condition
        returns $null (fail closed). Enforces, in order:
          - exactly one non-blank line starts with $MarkerPrefix, and it is the
            FINAL non-blank line, byte-identical to that single prefixed line;
          - the JSON payload is exactly one object (never array/scalar);
          - top-level keys are EXACTLY the schema's key set (no extra, none
            missing);
          - each field validates against its typed schema entry (strict int
            typing, exact-format GUID, case-sensitive string/enum/nonce
            equality, fixed-length hex, nullable hex, bounded control-character
            -free text, and bounded arrays of flat objects).

        $Schema = @{
            Keys   = @(<ordered allowed/required key names>)
            Fields = @{ <name> = @{ Type = 'int'|'guid'|'exact'|'hex'|'hexOrNull'|'enum'|'bool'|'string'|'objectArray'; ... } }
        }

        'string'      = @{ MaxLength = <int>; AllowEmpty = <bool>; AllowNewlines = <bool>; Pattern = <regex> }
        'objectArray' = @{ MaxItems = <int>; Item = @{ Keys = @(...); Fields = @{...} } }

        'objectArray' exists so an agent can return STRUCTURED results that the
        wrapper acts on itself. That is what lets a wrapper own every write
        instead of handing the model a write tool: the model reports findings,
        the schema bounds them, and the wrapper decides what to do with them.
    #>
    param(
        [Parameter(Mandatory)][string]$StdOutText,
        [Parameter(Mandatory)][string]$MarkerPrefix,
        [Parameter(Mandatory)][hashtable]$Schema
    )
    try {
        if ([string]::IsNullOrWhiteSpace($StdOutText)) { return $null }

        # Copilot's stdout framing does NOT guarantee the marker sits alone on
        # the final line: a following message can be concatenated onto the same
        # line without a newline, and the model may restate the marker in a
        # closing summary turn. Both happen in practice, and the earlier
        # "exactly one prefixed line, and it must be last" rule rejected those
        # cycles even though the work had completed correctly.
        #
        # Extract EVERY marker occurrence by brace-matching the JSON that
        # follows it, then require every occurrence to be byte-identical. This
        # preserves the anti-injection property of the stricter rule:
        #   - two DIFFERENT markers (e.g. one echoed out of hostile PR content)
        #     still fail closed rather than "last wins";
        #   - a marker the model never produced cannot match the expected nonce,
        #     which is generated per cycle AFTER the PR content was authored.
        $candidates = New-Object System.Collections.Generic.List[string]
        $quoteChar = [char]'"'
        $escapeChar = [char]'\'
        $openBrace = [char]'{'
        $closeBrace = [char]'}'
        $searchIndex = 0
        while ($true) {
            $hit = $StdOutText.IndexOf($MarkerPrefix, $searchIndex, [StringComparison]::Ordinal)
            if ($hit -lt 0) { break }
            $jsonStart = $StdOutText.IndexOf($openBrace, $hit + $MarkerPrefix.Length)
            if ($jsonStart -lt 0) { return $null }
            # Bounded brace-depth scan. String contents are respected so a brace
            # inside a JSON string value cannot terminate the object early.
            # The bound is generous rather than tight because a marker carrying
            # an objectArray of findings is legitimately tens of KB; the schema
            # (MaxItems / MaxLength) is what actually constrains the payload,
            # while this bound only stops an unterminated brace from scanning an
            # entire multi-megabyte transcript.
            $depth = 0
            $inString = $false
            $escaped = $false
            $jsonEnd = -1
            $limit = [Math]::Min($StdOutText.Length, $jsonStart + 65536)
            for ($i = $jsonStart; $i -lt $limit; $i++) {
                $ch = $StdOutText[$i]
                if ($inString) {
                    if ($escaped) { $escaped = $false }
                    elseif ($ch -eq $escapeChar) { $escaped = $true }
                    elseif ($ch -eq $quoteChar) { $inString = $false }
                    continue
                }
                if ($ch -eq $quoteChar) { $inString = $true; continue }
                if ($ch -eq $openBrace) { $depth++; continue }
                if ($ch -eq $closeBrace) {
                    $depth--
                    if ($depth -eq 0) { $jsonEnd = $i; break }
                }
            }
            if ($jsonEnd -lt 0) { return $null }
            [void]$candidates.Add($StdOutText.Substring($jsonStart, $jsonEnd - $jsonStart + 1))
            $searchIndex = $jsonEnd + 1
        }
        if ($candidates.Count -eq 0) { return $null }
        $jsonText = $candidates[0]
        foreach ($candidate in $candidates) {
            if ($candidate -cne $jsonText) { return $null }
        }

        $obj = $jsonText | ConvertFrom-Json -ErrorAction Stop
        if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return $null }

        $allowedKeys = @($Schema.Keys)
        $actualKeys = @($obj.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($name in $actualKeys) {
            if ($allowedKeys -notcontains $name) { return $null }
        }
        foreach ($name in $allowedKeys) {
            if (-not $obj.PSObject.Properties[$name]) { return $null }
        }

        $out = @{}
        foreach ($name in $allowedKeys) {
            $spec = $Schema.Fields[$name]
            if ($null -eq $spec) { return $null }
            $converted = ConvertTo-AgentMarkerFieldValue -Spec $spec -Value $obj.PSObject.Properties[$name].Value
            if (-not $converted.Ok) { return $null }
            $out[$name] = $converted.Value
        }
        return $out
    }
    catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Local Copilot session store (branch -> coding session resolution)
# ---------------------------------------------------------------------------

function Find-CopilotSessionForBranch {
    <#
        Scans `~/.copilot/session-state/*/workspace.yaml` (a flat, line-based
        YAML scalar file) in PURE PowerShell - no SQLite, no Python - and
        returns sessions whose `branch` matches $Branch (and, when supplied,
        `repository` / `git_root`), newest `updated_at` first. Sessions holding
        an `inuse.*.lock` are skipped as busy. Only line-anchored scalar keys
        are read; free-text keys such as `name:` are ignored (never trusted).
    #>
    param(
        [Parameter(Mandatory)][string]$Branch,
        [string]$Repository,
        [string]$GitRoot,
        [string]$SessionStateRoot
    )
    if (-not $SessionStateRoot) {
        $SessionStateRoot = Join-Path (Join-Path $HOME ".copilot") "session-state"
    }
    if (-not (Test-Path -LiteralPath $SessionStateRoot -PathType Container)) { return , @() }

    $normBranch = ($Branch -replace '^refs/heads/', '').Trim()
    $results = New-Object System.Collections.Generic.List[object]
    $sessionDirs = @(Get-ChildItem -LiteralPath $SessionStateRoot -Directory -ErrorAction SilentlyContinue)
    foreach ($dir in $sessionDirs) {
        $wsPath = Join-Path $dir.FullName "workspace.yaml"
        if (-not (Test-Path -LiteralPath $wsPath -PathType Leaf)) { continue }

        $lockFiles = @(Get-ChildItem -LiteralPath $dir.FullName -Filter "inuse.*.lock" -File -ErrorAction SilentlyContinue)
        if ($lockFiles.Count -gt 0) { continue }

        $fields = @{}
        foreach ($line in @(Get-Content -LiteralPath $wsPath -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*(id|cwd|git_root|repository|host_type|branch|updated_at|created_at):\s*(.*)$') {
                $key = $matches[1]
                $val = $matches[2].Trim()
                if ($val.Length -ge 2) {
                    $firstChar = $val[0]
                    $lastChar = $val[$val.Length - 1]
                    if (($firstChar -eq '"' -and $lastChar -eq '"') -or ($firstChar -eq "'" -and $lastChar -eq "'")) {
                        $val = $val.Substring(1, $val.Length - 2)
                    }
                }
                if (-not $fields.ContainsKey($key)) { $fields[$key] = $val }
            }
        }

        if (-not $fields.ContainsKey('branch')) { continue }
        $sessBranch = ($fields['branch'] -replace '^refs/heads/', '').Trim()
        if ($sessBranch -ne $normBranch) { continue }
        if ($Repository -and $fields.ContainsKey('repository') -and $fields['repository'] -ne $Repository) { continue }
        if ($GitRoot -and $fields.ContainsKey('git_root') -and $fields['git_root'] -ne $GitRoot) { continue }

        $updatedRaw = if ($fields.ContainsKey('updated_at')) { [string]$fields['updated_at'] } else { "" }
        $updatedUtc = [DateTime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        [void][DateTime]::TryParse($updatedRaw, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$updatedUtc)

        $results.Add([pscustomobject]@{
                SessionId    = if ($fields.ContainsKey('id')) { [string]$fields['id'] } else { $dir.Name }
                Branch       = $sessBranch
                Repository   = if ($fields.ContainsKey('repository')) { [string]$fields['repository'] } else { "" }
                GitRoot      = if ($fields.ContainsKey('git_root')) { [string]$fields['git_root'] } else { "" }
                Cwd          = if ($fields.ContainsKey('cwd')) { [string]$fields['cwd'] } else { "" }
                HostType     = if ($fields.ContainsKey('host_type')) { [string]$fields['host_type'] } else { "" }
                UpdatedAt    = $updatedRaw
                UpdatedAtUtc = $updatedUtc
                SessionDir   = $dir.FullName
            })
    }
    $sorted = @($results | Sort-Object -Property UpdatedAtUtc -Descending)
    return , $sorted
}

# ---------------------------------------------------------------------------
# Timed subprocess execution (real Copilot invocation + -DryRun timeout test)
# ---------------------------------------------------------------------------

function Set-TimedProcessArguments {
    param([Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$Psi, [string[]]$ArgumentList)
    foreach ($argument in @($ArgumentList)) { $Psi.ArgumentList.Add($argument) }
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    try { $Process.Kill($true); return } catch {}
    try { & taskkill.exe /PID $Process.Id /T /F 2>$null 1>$null } catch {}
    try { $Process.Kill() } catch {}
}

function Get-TaskTextBeforeDeadline {
    param([AllowNull()][System.Threading.Tasks.Task]$Task, [Parameter(Mandatory)][DateTime]$DeadlineUtc)
    if ($null -eq $Task) { return @{ Completed = $true; Text = "" } }
    if (-not $Task.IsCompleted) {
        $remainingMs = [Math]::Max(0, [int]($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remainingMs -eq 0) { return @{ Completed = $false; Text = "" } }
        try {
            if (-not $Task.Wait($remainingMs)) { return @{ Completed = $false; Text = "" } }
        }
        catch {
            if (-not $Task.IsCompleted) { return @{ Completed = $false; Text = "" } }
        }
    }
    try { return @{ Completed = $true; Text = [string]$Task.GetAwaiter().GetResult() } }
    catch { return @{ Completed = $true; Text = "" } }
}

function Invoke-TimedProcess {
    <#
        Runs a child process with async stdout/stderr capture, UTF-8 (no BOM)
        stdin, and a hard wall-clock deadline that covers start, stdin write,
        exit, and output drain. On expiry the process tree is killed
        (Kill($true) -> taskkill /T /F -> Kill()). Returns
        @{ ExitCode; TimedOut; StdOut; StdErr; ProcessId }.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$StandardInputContent,
        [switch]$CaptureStdOut,
        [switch]$CaptureStdErr,
        [string]$WorkingDirectory,
        [string[]]$EnvironmentVariablesToRemove = @(),
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    Set-TimedProcessArguments -Psi $psi -ArgumentList $ArgumentList
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.RedirectStandardInput = [bool]$StandardInputContent
    $psi.RedirectStandardOutput = [bool]$CaptureStdOut
    $psi.RedirectStandardError = [bool]$CaptureStdErr
    $psi.UseShellExecute = $false
    $utf8Encoding = New-Object System.Text.UTF8Encoding($false)
    if ($CaptureStdOut -and $psi.GetType().GetProperty("StandardOutputEncoding")) { $psi.StandardOutputEncoding = $utf8Encoding }
    if ($CaptureStdErr -and $psi.GetType().GetProperty("StandardErrorEncoding")) { $psi.StandardErrorEncoding = $utf8Encoding }
    if ($psi.RedirectStandardInput -and $psi.GetType().GetProperty("StandardInputEncoding")) { $psi.StandardInputEncoding = $utf8Encoding }
    foreach ($variableName in @($EnvironmentVariablesToRemove)) { [void]$psi.EnvironmentVariables.Remove($variableName) }
    foreach ($variableName in (Get-AgentSessionIsolationEnvVars)) { [void]$psi.EnvironmentVariables.Remove($variableName) }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)

        $stdoutTask = $null
        $stderrTask = $null
        if ($CaptureStdOut) { $stdoutTask = $proc.StandardOutput.ReadToEndAsync() }
        if ($CaptureStdErr) { $stderrTask = $proc.StandardError.ReadToEndAsync() }

        $timedOut = $false
        if ($StandardInputContent) {
            $stdinBytes = $utf8Encoding.GetBytes($StandardInputContent)
            $writeTask = $proc.StandardInput.BaseStream.WriteAsync($stdinBytes, 0, $stdinBytes.Length)
            $writeDeadlineMs = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $writeTask.Wait($writeDeadlineMs)) {
                $timedOut = $true
            }
            else {
                try { $proc.StandardInput.Close() } catch {}
            }
        }

        $exited = $false
        if (-not $timedOut) {
            $remainingMs = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $exited = $proc.WaitForExit($remainingMs)
            $timedOut = -not $exited
        }

        if ($timedOut) {
            Stop-ProcessTree -Process $proc
            $proc.WaitForExit(5000) | Out-Null
        }

        $stdoutResult = Get-TaskTextBeforeDeadline -Task $stdoutTask -DeadlineUtc $deadline
        $stderrResult = Get-TaskTextBeforeDeadline -Task $stderrTask -DeadlineUtc $deadline
        if (-not $stdoutResult.Completed -or -not $stderrResult.Completed) { $timedOut = $true }

        $exitCode = -1
        if ($exited -and -not $timedOut) {
            try { $exitCode = $proc.ExitCode } catch { $exitCode = -1 }
        }

        return @{
            ExitCode  = $exitCode
            TimedOut  = $timedOut
            StdOut    = $stdoutResult.Text
            StdErr    = $stderrResult.Text
            ProcessId = $proc.Id
        }
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# Generic Agency MCP JSON-RPC stdio client (portable; used only in live mode)
# ---------------------------------------------------------------------------

function Send-AgentMcpRequest {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [Nullable[DateTime]]$DeadlineUtc
    )
    if (-not $Session.Process) { throw "Agent MCP session is closed." }
    $Session.NextId = [long]$Session.NextId + 1
    $requestId = [long]$Session.NextId
    $request = [ordered]@{ jsonrpc = "2.0"; id = $requestId; method = $Method; params = $Params }
    $line = $request | ConvertTo-Json -Compress -Depth 20
    try {
        $Session.Process.StandardInput.WriteLine($line)
        $Session.Process.StandardInput.Flush()
    }
    catch {
        Close-AgentMcpSession -Session $Session -Abort
        throw "Could not write to Agent MCP."
    }

    $deadline = [DateTime]::UtcNow.AddSeconds([int]$Session.TimeoutSeconds)
    if ($null -ne $DeadlineUtc -and [DateTime]$DeadlineUtc -lt $deadline) { $deadline = [DateTime]$DeadlineUtc }
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            $process = [System.Diagnostics.Process]$Session.Process
            if ($process.HasExited) { throw "Agent MCP exited before returning a response." }
            if ($null -eq $Session.ReadTask) { $Session.ReadTask = $process.StandardOutput.ReadLineAsync() }
            if (-not $Session.ReadTask.Wait(200)) { continue }
            $respLine = $Session.ReadTask.Result
            $Session.ReadTask = $null
            if ($null -eq $respLine) { throw "Agent MCP closed stdout before returning a response." }
            try { $response = $respLine | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "Agent MCP returned malformed JSON-RPC." }
            if ($response -isnot [System.Management.Automation.PSCustomObject] -or
                -not $response.PSObject.Properties["jsonrpc"] -or [string]$response.jsonrpc -cne "2.0") {
                throw "Agent MCP returned an invalid JSON-RPC envelope."
            }
            $idProperty = $response.PSObject.Properties["id"]
            if ($null -eq $idProperty) { continue }
            if (-not (Test-StrictJsonInt -Value $idProperty.Value -Min 1 -Max ([long]::MaxValue)) -or [long]$idProperty.Value -ne $requestId) {
                throw "Agent MCP returned an unexpected response id."
            }
            $hasResult = $null -ne $response.PSObject.Properties["result"]
            $hasError = $null -ne $response.PSObject.Properties["error"]
            if ($hasResult -eq $hasError) { throw "Agent MCP returned an invalid result/error envelope." }
            if ($hasError) {
                $errorCode = if ($response.error -and $response.error.PSObject.Properties["code"]) { [string]$response.error.code } else { "unknown" }
                throw "Agent MCP request failed (JSON-RPC error code $errorCode)."
            }
            return $response.result
        }
        throw "Agent MCP response timed out."
    }
    catch {
        Close-AgentMcpSession -Session $Session -Abort
        throw
    }
}

function Send-AgentMcpNotification {
    param([Parameter(Mandatory)][hashtable]$Session, [Parameter(Mandatory)][string]$Method, [hashtable]$Params = @{})
    $notification = [ordered]@{ jsonrpc = "2.0"; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 10
    try {
        $Session.Process.StandardInput.WriteLine($notification)
        $Session.Process.StandardInput.Flush()
    }
    catch {
        Close-AgentMcpSession -Session $Session -Abort
        throw "Could not write an Agent MCP notification."
    }
}

function Close-AgentMcpSession {
    param([hashtable]$Session, [switch]$Abort)
    if (-not $Session -or -not $Session.Process) { return }
    $process = [System.Diagnostics.Process]$Session.Process
    try { $process.StandardInput.Close() } catch {}
    if ($Abort -or -not $process.WaitForExit(2000)) {
        Stop-ProcessTree -Process $process
        try { $process.WaitForExit(5000) | Out-Null } catch {}
    }
    $process.Dispose()
    $Session.Process = $null
}

function Open-AgentMcpSession {
    <#
        Starts `agency mcp <Server> [--organization <org>] [--toolsets <list>]`
        and performs the JSON-RPC initialize/initialized handshake. Repo/tool
        agnostic - the wrapper chooses the server, organization and toolsets.
        Sensitive credential env vars are stripped from the child.
    #>
    param(
        [Parameter(Mandatory)][string]$AgencyPath,
        [Parameter(Mandatory)][string]$Server,
        [string]$Organization,
        [string[]]$Toolsets = @(),
        [ValidateRange(5, 120)][int]$TimeoutSeconds = 30,
        [string]$ProtocolVersion = "2024-11-05",
        [string]$ClientName = "copilot-agent-harness",
        [string[]]$EnvironmentVariablesToRemove = @("AZURE_DEVOPS_EXT_PAT", "SYSTEM_ACCESSTOKEN")
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AgencyPath
    $args = @("mcp", $Server)
    if ($Organization) { $args += @("--organization", $Organization) }
    if (@($Toolsets).Count -gt 0) { $args += @("--toolsets", (@($Toolsets) -join ",")) }
    Set-TimedProcessArguments -Psi $psi -ArgumentList $args
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($propertyName in @("StandardInputEncoding", "StandardOutputEncoding", "StandardErrorEncoding")) {
        if ($psi.GetType().GetProperty($propertyName)) { $psi.$propertyName = $utf8 }
    }
    foreach ($variableName in @($EnvironmentVariablesToRemove)) { [void]$psi.EnvironmentVariables.Remove($variableName) }
    foreach ($variableName in (Get-AgentSessionIsolationEnvVars)) { [void]$psi.EnvironmentVariables.Remove($variableName) }

    $process = [System.Diagnostics.Process]::Start($psi)
    $session = @{
        Process        = $process
        NextId         = [long]0
        ReadTask       = $null
        ErrorDrainTask = $process.StandardError.ReadToEndAsync()
        TimeoutSeconds = $TimeoutSeconds
        Server         = $Server
    }
    try {
        $initializeResult = Send-AgentMcpRequest -Session $session -Method "initialize" -Params @{
            protocolVersion = $ProtocolVersion
            capabilities    = @{}
            clientInfo      = @{ name = $ClientName; version = "1.0" }
        }
        if ($initializeResult -isnot [System.Management.Automation.PSCustomObject] -or
            -not $initializeResult.PSObject.Properties["protocolVersion"]) {
            throw "Agent MCP did not return a protocol version during initialize."
        }
        Send-AgentMcpNotification -Session $session -Method "notifications/initialized"
        return $session
    }
    catch {
        Close-AgentMcpSession -Session $session -Abort
        throw
    }
}

function Invoke-AgentMcpTool {
    <#
        Calls one MCP tool and returns its single text content parsed from JSON.
        Fails closed on any unexpected envelope/content shape.

        -RawText returns the validated TEXT instead of parsing it. Not every ADO
        MCP action answers with JSON: write actions on repo_pull_request_write
        confirm with a human-readable sentence, so JSON-parsing them throws
        AFTER the action has already been applied - leaving the caller unable to
        distinguish "it failed" from "it succeeded, response unreadable". Read
        paths keep the JSON default unchanged.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{},
        [Nullable[DateTime]]$DeadlineUtc,
        [switch]$RawText
    )
    $toolResult = Send-AgentMcpRequest -Session $Session -Method "tools/call" -Params @{ name = $Name; arguments = $Arguments } -DeadlineUtc $DeadlineUtc
    if ($toolResult -isnot [System.Management.Automation.PSCustomObject]) { throw "Agent MCP tool returned an unexpected result shape." }
    if ($toolResult.PSObject.Properties["isError"] -and $toolResult.isError -eq $true) { throw "Agent MCP tool '$Name' reported failure." }
    $contentProperty = $toolResult.PSObject.Properties["content"]
    if ($null -eq $contentProperty) { throw "Agent MCP tool '$Name' response omitted content." }
    $content = @($contentProperty.Value)
    if ($content.Count -lt 1 -or
        $content[0] -isnot [System.Management.Automation.PSCustomObject] -or
        -not $content[0].PSObject.Properties["text"] -or
        $content[0].text -isnot [string] -or
        $content[0].text.Length -gt 20MB) {
        throw "Agent MCP tool '$Name' returned invalid content."
    }
    if ($RawText) { return [string]$content[0].text }
    try { return ($content[0].text | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Agent MCP tool '$Name' returned malformed JSON content." }
}

function Get-AgentCliJsonOutcome {
    <#
        Extracts the outcome from Copilot CLI's `--output-format json` channel
        (JSONL, one object per line). Reading the structured event stream is far
        more reliable than scraping prose stdout, which interleaves progress
        text, reasoning, and tool traffic with the answer.

        Event shape verified against the installed CLI:
          {"type":"assistant.message","data":{"content":"...","model":"..."}}
          {"type":"result","exitCode":0,"usage":{"codeChanges":{"filesModified":[]}}}

        Only `assistant.message` is read for text: `assistant.message_delta`
        events are streaming fragments of the SAME message, so including them
        would duplicate the answer (and any result marker inside it).

        Returns @{ Answer; Model; ModifiedFiles; ExitCode } or $null when the
        output is not JSONL - an older CLI, or a run without --output-format -
        so the caller falls back to raw stdout instead of failing the cycle.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText)
    if ([string]::IsNullOrWhiteSpace($StdOutText)) { return $null }
    $phased = New-Object System.Collections.Generic.List[string]
    $noToolMessages = New-Object System.Collections.Generic.List[string]
    $allMessages = New-Object System.Collections.Generic.List[string]
    $modified = New-Object System.Collections.Generic.List[string]
    $model = ""
    $exitCode = $null
    $sawJson = $false
    $sawAssistantMessage = $false
    foreach ($line in ($StdOutText -split "`r?`n")) {
        $trimmed = "$line".Trim()
        if ($trimmed.Length -lt 2 -or -not $trimmed.StartsWith("{")) { continue }
        $evt = $null
        try { $evt = $trimmed | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($evt -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $typeProp = $evt.PSObject.Properties["type"]
        if (-not $typeProp) { continue }
        $sawJson = $true
        $eventType = [string]$typeProp.Value
        $data = $null
        $dataProp = $evt.PSObject.Properties["data"]
        if ($dataProp) { $data = $dataProp.Value }

        if ($eventType -eq "assistant.message" -and $data) {
            $sawAssistantMessage = $true
            $contentProp = $data.PSObject.Properties["content"]
            $text = if ($contentProp -and $contentProp.Value -is [string]) { [string]$contentProp.Value } else { "" }
            if ($text.Trim() -ne "") {
                [void]$allMessages.Add($text)
                # A message that requested NO tools is a terminal answer rather
                # than commentary preceding a tool call.
                $toolProp = $data.PSObject.Properties["toolRequests"]
                if (-not $toolProp -or @($toolProp.Value).Count -eq 0) { [void]$noToolMessages.Add($text) }
                # Honor an explicit phase when the CLI emits one, but never
                # REQUIRE it: builds that omit the field would otherwise have
                # every completed run discarded.
                $phaseProp = $data.PSObject.Properties["phase"]
                if ($phaseProp -and ([string]$phaseProp.Value) -eq "final_answer") { [void]$phased.Add($text) }
            }
            $modelProp = $data.PSObject.Properties["model"]
            if ($modelProp -and $modelProp.Value -is [string] -and $modelProp.Value.Trim() -ne "") {
                $model = [string]$modelProp.Value
            }
        }
        elseif ($eventType -eq "result") {
            $ecProp = $evt.PSObject.Properties["exitCode"]
            if ($ecProp -and (Test-StrictJsonInt -Value $ecProp.Value -Min -2147483648 -Max 2147483647)) { $exitCode = [int]$ecProp.Value }
            $usageProp = $evt.PSObject.Properties["usage"]
            if ($usageProp -and $usageProp.Value) {
                $ccProp = $usageProp.Value.PSObject.Properties["codeChanges"]
                if ($ccProp -and $ccProp.Value) {
                    $fmProp = $ccProp.Value.PSObject.Properties["filesModified"]
                    if ($fmProp) {
                        foreach ($v in @($fmProp.Value)) { if ($v -is [string] -and $v.Trim() -ne "") { [void]$modified.Add([string]$v) } }
                    }
                }
            }
        }
    }
    if (-not $sawJson) { return $null }
    # Narrowest reliable selection first, widest last. Assigned with plain
    # statements, NOT `$x = if (...) { $list }`: an if-expression's output goes
    # through the pipeline, which unrolls a one-element List into a String and
    # breaks .ToArray() below.
    $selected = $allMessages
    if ($phased.Count -gt 0) { $selected = $phased }
    elseif ($noToolMessages.Count -gt 0) { $selected = $noToolMessages }
    return @{
        Answer         = ($selected.ToArray() -join "`n")
        Model          = $model
        ModifiedFiles  = @($modified.ToArray() | Select-Object -Unique)
        ExitCode       = $exitCode
        ModelActuallyRan = $sawAssistantMessage
    }
}

function Get-AgentMissingMcpServers {
    <#
        The allow-list can grant tools like ado(...) or bluebird, but those come
        from an MCP server the TARGET REPO must actually declare. A repo without
        one launches perfectly happily and the model simply has no tools - it
        cannot read a PR or post a comment, and nothing in the run says why. The
        cycle then produces no marker and the PR quietly starves.

        This matters most for the portability promise: dropping this folder into
        another Azure DevOps repo is supposed to need only a config edit, and
        this is the failure that would otherwise greet the first run.

        Copilot resolves MCP servers from the repo's .mcp.json and from the
        user-level ~/.copilot/mcp-config.json, so both are consulted before
        declaring a server missing. Built-in (non-MCP) tools are exempt.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowToolEntries,
        [Parameter(Mandatory)][string]$RepositoryPath,
        [string[]]$BuiltInTools = @("read", "edit", "create", "shell", "web_search", "web_fetch", "glob", "grep", "view", "write")
    )
    $requiredServers = @($AllowToolEntries | ForEach-Object {
            $entry = [string]$_
            $name = if ($entry.Contains("(")) { $entry.Substring(0, $entry.IndexOf("(")) } else { $entry }
            $name.Trim()
        } | Where-Object { $_ -and $BuiltInTools -cnotcontains $_ } | Select-Object -Unique)
    if ($requiredServers.Count -eq 0) { return @() }

    $declaredServers = New-Object System.Collections.Generic.HashSet[string]
    foreach ($configPath in @(
            (Join-Path $RepositoryPath ".mcp.json"),
            (Join-Path $HOME ".copilot/mcp-config.json")
        )) {
        if (-not (Test-Path -LiteralPath $configPath)) { continue }
        try { $parsed = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        foreach ($sectionName in @("mcpServers", "servers")) {
            $section = $parsed.PSObject.Properties[$sectionName]
            if (-not $section -or $null -eq $section.Value) { continue }
            foreach ($server in $section.Value.PSObject.Properties) { [void]$declaredServers.Add([string]$server.Name) }
        }
    }
    return @($requiredServers | Where-Object { -not $declaredServers.Contains($_) })
}

function Get-AgentLaunchFailureReason {
    <#
        Recognizes environment/launch failures so they can be excluded from
        per-candidate starvation counting: a PR is not "unreviewable" because
        the host lost its credentials.

        SECURITY: scanned from STDERR ONLY. Agency and the Copilot engine write
        launch diagnostics to stderr; the model's own text does not appear
        there. If stdout were consulted, a hostile PR could make the model emit
        a recognized signature, masquerade as an environment fault, and exempt
        itself from starvation forever - an unbounded retry loop on a PR the
        agent can never finish.
    #>
    param([AllowEmptyString()][string]$StdErrText)
    if ([string]::IsNullOrWhiteSpace($StdErrText)) { return $null }
    if ($StdErrText -match '(?i)No authentication information found') {
        return "Copilot could not authenticate to GitHub. Set COPILOT_GITHUB_TOKEN (or GH_TOKEN/GITHUB_TOKEN), or run 'copilot login'. An interactive shell can inherit a transient token that a scheduled task will not have."
    }
    if ($StdErrText -match '(?i)(is not recognized as|command not found|No such file or directory).*(agency|copilot)') {
        return "The Agency or Copilot executable could not be launched on this host."
    }
    if ($StdErrText -match '(?i)failed to (start|launch) MCP server') {
        return "An MCP server failed to start, so the model would have had no tools."
    }
    return $null
}

function Remove-StaleAgentAttempts {
    <#
        Age-based pruning of per-candidate failure records. Without it a PR that
        failed transiently weeks ago stays starved forever, and the state file
        grows without bound.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$AttemptsState,
        [int]$MaxAgeDays = 14,
        [Nullable[DateTime]]$NowUtc
    )
    $now = if ($NowUtc) { [DateTime]$NowUtc } else { [DateTime]::UtcNow }
    $cutoff = $now.AddDays(-[Math]::Abs($MaxAgeDays))
    $stale = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($AttemptsState.Keys)) {
        $entry = $AttemptsState[$key]
        $lastText = $null
        if ($entry -is [hashtable] -and $entry.ContainsKey('lastAt')) { $lastText = [string]$entry['lastAt'] }
        elseif ($entry -is [System.Management.Automation.PSCustomObject] -and $entry.PSObject.Properties['lastAt']) { $lastText = [string]$entry.lastAt }
        if ([string]::IsNullOrWhiteSpace($lastText)) { continue }
        $parsed = [DateTime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if ([DateTime]::TryParse($lastText, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed) -and $parsed -lt $cutoff) {
            [void]$stale.Add($key)
        }
    }
    foreach ($key in $stale) { $AttemptsState.Remove($key) }
    return $stale.Count
}

function Get-AgentWorkIqTargetUrl {
    <#
        Returns the single entity URL a WorkIQ call targets, per the tool's REAL
        argument contract: `fetch` takes an entityUrls ARRAY and `create_entity`
        takes a parentUrl string. Resolving the URL in one place keeps the path
        allowlist enforceable regardless of which argument name a tool uses - a
        future tool added without a case here resolves to $null and the call is
        refused rather than silently escaping the allowlist.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Arguments)
    switch ($Name) {
        "fetch" {
            if (-not $Arguments.ContainsKey("entityUrls")) { return $null }
            $urls = @($Arguments["entityUrls"])
            if ($urls.Count -ne 1) { return $null }
            return [string]$urls[0]
        }
        "create_entity" {
            if (-not $Arguments.ContainsKey("parentUrl")) { return $null }
            return [string]$Arguments["parentUrl"]
        }
    }
    return $null
}

function Invoke-AgentWorkIqTool {
    <#
        Calls one WorkIQ MCP tool under a fixed tool-name and URL-prefix
        allowlist, both validated BEFORE the request is sent.

        WorkIQ does NOT use the ADO envelope: it answers with an EMPTY content
        array and puts the payload in structuredContent, in one of two shapes -
        `fetch` returns a per-entity results[] array, `create_entity` returns a
        single {data, statusCode} envelope. Both are normalized to one entry
        here. A non-2xx status is a failure even though the MCP call itself
        succeeded, and the server's own error text is surfaced: discarding it
        makes a wrong-argument-shape bug indistinguishable from an auth failure.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [string[]]$AllowedTools = @("fetch", "create_entity"),
        [string[]]$AllowedPathPrefixes = @("/me", "/users/", "/chats", "/teams/"),
        [Nullable[DateTime]]$DeadlineUtc
    )
    if ($AllowedTools -cnotcontains $Name) {
        throw "Refusing to call WorkIQ tool '$Name': not in the allowed tool list ($($AllowedTools -join ', '))."
    }
    $targetUrl = Get-AgentWorkIqTargetUrl -Name $Name -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($targetUrl)) {
        throw "Refusing to call WorkIQ tool '$Name' without exactly one target entity URL."
    }
    # OData query options ($select/$top) live in the URL, so compare only the path.
    $pathOnly = ($targetUrl -split '\?', 2)[0]
    $allowed = $false
    foreach ($prefix in @($AllowedPathPrefixes)) {
        if ($pathOnly.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
    }
    if (-not $allowed) {
        throw "Refusing to call WorkIQ tool '$Name' for '$pathOnly': outside the allowed path prefixes."
    }

    $toolResult = Send-AgentMcpRequest -Session $Session -Method "tools/call" -Params @{ name = $Name; arguments = $Arguments } -DeadlineUtc $DeadlineUtc
    if ($toolResult -isnot [System.Management.Automation.PSCustomObject]) { throw "WorkIQ tool '$Name' returned an unexpected result shape." }

    if ($toolResult.PSObject.Properties["isError"] -and $toolResult.isError -eq $true) {
        $detail = ""
        $errorContent = $toolResult.PSObject.Properties["content"]
        if ($errorContent) {
            $errorText = @(@($errorContent.Value) | Where-Object { $_.PSObject.Properties["text"] })[0]
            if ($errorText) {
                $detail = [string]$errorText.text
                if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + "..." }
            }
        }
        throw "WorkIQ tool '$Name' reported failure.$(if ($detail) { " Server said: $detail" })"
    }

    $structuredProperty = $toolResult.PSObject.Properties["structuredContent"]
    if (-not $structuredProperty -or $null -eq $structuredProperty.Value) {
        throw "WorkIQ tool '$Name' response omitted structuredContent."
    }
    $resultsProperty = $structuredProperty.Value.PSObject.Properties["results"]
    if ($resultsProperty) {
        $results = @($resultsProperty.Value)
        if ($results.Count -ne 1) {
            throw "WorkIQ tool '$Name' returned $($results.Count) results for a single-entity request."
        }
        $entry = $results[0]
    }
    else {
        $entry = $structuredProperty.Value
    }
    if ($entry -isnot [System.Management.Automation.PSCustomObject]) {
        throw "WorkIQ tool '$Name' returned an unexpected result entry."
    }
    $statusProperty = $entry.PSObject.Properties["statusCode"]
    if (-not $statusProperty -or -not (Test-StrictJsonInt -Value $statusProperty.Value -Min 100 -Max 599)) {
        throw "WorkIQ tool '$Name' returned no valid statusCode."
    }
    $statusCode = [int]$statusProperty.Value
    if ($statusCode -lt 200 -or $statusCode -gt 299) {
        throw "WorkIQ tool '$Name' returned HTTP $statusCode for the requested entity."
    }
    $dataProperty = $entry.PSObject.Properties["data"]
    if (-not $dataProperty) { return $null }
    return $dataProperty.Value
}

function Resolve-AgentTeamsUserChatId {
    <#
        Resolves a one-on-one chat with $RecipientUpn: fetch /me, fetch
        /users/{upn}, then POST /chats with chatType=oneOnOne and two owner
        members. Microsoft Graph returns the EXISTING one-on-one chat when one
        is already present, so this is safe to call every time.

        Graph requires two UNIQUE members - there is no "chat with yourself"
        shape. The ids are compared here rather than letting create_entity fail
        with an opaque Graph error, because for a self-PR agent the recipient
        very often IS the signed-in user.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$RecipientUpn,
        [Nullable[DateTime]]$DeadlineUtc
    )
    $me = Invoke-AgentWorkIqTool -Session $Session -Name "fetch" -Arguments @{ entityUrls = @('/me?$select=id') } -DeadlineUtc $DeadlineUtc
    $selfId = [string](Get-AgentRequiredProperty -Object $me -Name "id")
    $recipient = Invoke-AgentWorkIqTool -Session $Session -Name "fetch" -Arguments @{
        entityUrls = @("/users/$([Uri]::EscapeDataString($RecipientUpn))?`$select=id")
    } -DeadlineUtc $DeadlineUtc
    $recipientId = [string](Get-AgentRequiredProperty -Object $recipient -Name "id")

    $selfObjectId = [Guid]::Empty
    $recipientObjectId = [Guid]::Empty
    if (-not [Guid]::TryParse($selfId, [ref]$selfObjectId) -or -not [Guid]::TryParse($recipientId, [ref]$recipientObjectId)) {
        throw "WorkIQ returned an invalid Microsoft Entra object id while resolving the signed-in user or '$RecipientUpn'; refusing to create a chat."
    }
    if ($selfObjectId -eq $recipientObjectId) {
        throw ("Microsoft Graph does not support a one-on-one chat where the signed-in user and '$RecipientUpn' are the same person " +
            "(POST /chats requires two unique members). Set teamsNotifications.directAuthor.recipientUpn to a different person, " +
            "or use a Teams channel destination instead.")
    }
    $chat = Invoke-AgentWorkIqTool -Session $Session -Name "create_entity" -Arguments @{
        parentUrl = "/chats"
        jsonBody  = @{
            chatType = "oneOnOne"
            members  = @(
                @{ "@odata.type" = "#microsoft.graph.aadUserConversationMember"; roles = @("owner"); "user@odata.bind" = "https://graph.microsoft.com/v1.0/users('$selfId')" },
                @{ "@odata.type" = "#microsoft.graph.aadUserConversationMember"; roles = @("owner"); "user@odata.bind" = "https://graph.microsoft.com/v1.0/users('$recipientId')" }
            )
        }
    } -DeadlineUtc $DeadlineUtc
    return [string](Get-AgentRequiredProperty -Object $chat -Name "id")
}

function Send-AgentTeamsDirectMessage {
    <# Posts one HTML message to a one-on-one chat with $RecipientUpn. #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$RecipientUpn,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string[]]$Links = @(),
        [Nullable[DateTime]]$DeadlineUtc
    )
    $chatId = Resolve-AgentTeamsUserChatId -Session $Session -RecipientUpn $RecipientUpn -DeadlineUtc $DeadlineUtc
    $html = New-AgentTeamsMessageHtml -Title $Title -Body $Body -Links $Links
    return Invoke-AgentWorkIqTool -Session $Session -Name "create_entity" -Arguments @{
        parentUrl = "/chats/$chatId/messages"
        jsonBody  = @{ body = @{ contentType = "html"; content = $html } }
    } -DeadlineUtc $DeadlineUtc
}

function Get-AgentRequiredProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { throw "Expected an object carrying '$Name' but got null." }
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value -or [string]::IsNullOrWhiteSpace([string]$p.Value)) {
        throw "Response did not include a usable '$Name' property."
    }
    return $p.Value
}

function New-AgentTeamsMessageHtml {
    <#
        Builds the message body. Every dynamic value is HTML-encoded: text is
        assembled from PR titles and branch names, which are untrusted.

        The agent posts as the signed-in user, so every message MUST identify
        itself as automated - otherwise recipients read agent output as a
        personal message from the operator.
    #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string[]]$Links = @())
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $html = "<strong>[Automated message]</strong><br/><strong>$(& $enc $Title)</strong><br/>$(& $enc $Body)"
    foreach ($link in @($Links)) {
        if ($link) { $html += "<br/><a href=`"$(& $enc $link)`">$(& $enc $link)</a>" }
    }
    return $html
}

function Send-AgentTeamsChannelMessage {
    <#
        Posts one HTML message to a Teams channel through WorkIQ. Every dynamic
        value is HTML-encoded: notification text is assembled from PR titles and
        branch names, which are untrusted input.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$TeamId,
        [Parameter(Mandatory)][string]$ChannelId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body,
        [string[]]$Links = @(),
        [Nullable[DateTime]]$DeadlineUtc
    )
    $html = New-AgentTeamsMessageHtml -Title $Title -Body $Body -Links $Links
    $arguments = @{
        parentUrl = "/teams/$TeamId/channels/$ChannelId/messages"
        jsonBody  = @{ body = @{ contentType = "html"; content = $html } }
    }
    return Invoke-AgentWorkIqTool -Session $Session -Name "create_entity" -Arguments $arguments -DeadlineUtc $DeadlineUtc
}

function Get-DevPilotAgentPath {
    <#
        Resolves an asset that ships WITH the toolkit (agent scripts, prompts,
        schemas, fixtures) regardless of where the module was installed.

        A PowerShell module ships its .psm1, but consumers also need the .md
        prompts and JSON schema. Without a resolver they would install the
        module successfully and then find the agents cannot start, because the
        prompt file could not be located. Everything under src/Agents is
        addressed relative to the module root through here.

        Examples:
            Get-DevPilotAgentPath                       # the Agents root
            Get-DevPilotAgentPath -Agent review-handler # one agent's folder
            Get-DevPilotAgentPath -Agent review-handler -Leaf handle-cycle.prompt.md
    #>
    param([string]$Agent, [string]$Leaf)
    $moduleRoot = $PSScriptRoot                       # ...\src\DevPilot.AgentHarness
    $agentsRoot = Join-Path (Split-Path $moduleRoot -Parent) "Agents"
    if (-not (Test-Path -LiteralPath $agentsRoot)) {
        throw "DevPilot agents root not found at '$agentsRoot'. The module appears to have been installed without its agent assets."
    }
    $path = $agentsRoot
    if ($Agent) { $path = Join-Path $path $Agent }
    if ($Leaf) { $path = Join-Path $path $Leaf }
    if (-not (Test-Path -LiteralPath $path)) { throw "DevPilot asset not found: '$path'." }
    return (Resolve-Path -LiteralPath $path).Path
}

function Resolve-AgentRepositoryRoot {
    <#
        Resolves the repository the agent OPERATES ON - which is not the
        repository the toolkit lives in.

        This is the single most dangerous difference between running in-repo
        and running as an installed module. The original code probed upward
        from the script location for a .git directory. Once the toolkit is
        installed outside the consuming repo, that probe silently resolves to
        the TOOLKIT's own repo and the agent would operate on the wrong
        repository without any error.

        Resolution order, most explicit first:
          1. -RepoPath, when the operator passed one.
          2. The directory containing the config file, walked up to its .git.
             The config always lives inside the consuming repo, so this is
             correct by construction.
          3. Fail loudly. There is deliberately no "current directory"
             fallback: guessing here is how an agent ends up committing to the
             wrong repository.
    #>
    param([string]$RepoPath, [string]$ConfigPath)
    if ($RepoPath) {
        if (-not (Test-Path -LiteralPath $RepoPath)) { throw "-RepoPath '$RepoPath' does not exist." }
        return (Resolve-Path -LiteralPath $RepoPath).Path
    }
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        $probe = Split-Path (Resolve-Path -LiteralPath $ConfigPath).Path -Parent
        while ($probe) {
            if (Test-Path -LiteralPath (Join-Path $probe ".git")) { return $probe }
            $parent = Split-Path $probe -Parent
            if ($parent -eq $probe) { break }
            $probe = $parent
        }
    }
    throw ("Could not determine which repository to operate on. Pass -RepoPath explicitly, " +
        "or place the agent config inside the target repository so its root can be resolved from there.")
}

<#
    Provider layer.

    Both agents were written against Azure DevOps, and its assumptions reach
    further than a transport: pull-request status vocabulary, review/vote
    semantics, thread lifecycle, and how a validation run is located all differ
    between hosts. This layer defines ONE normalized shape for each of those
    and implements it per provider, so agent logic above it does not branch on
    the host.

    The normalized pull-request snapshot is deliberately the shape the Azure
    DevOps path already produced, so that path can adopt this layer without any
    behavioural change and its existing self-checks keep their meaning.

    Transport per provider:
      AzureDevOps - the caller's existing MCP invoker, passed in. Nothing about
                    that path is reimplemented here.
      GitHub      - the `gh` CLI, which already holds the operator's
                    credentials. REST for most reads; GraphQL for review-thread
                    resolution, which REST does not expose at all.
#>

$script:AgentSupportedProviders = @('AzureDevOps', 'GitHub')

function Get-AgentSupportedProvider {
    <#
    .SYNOPSIS
        Providers this harness can service.
    #>
    [CmdletBinding()]
    param()
    return , @($script:AgentSupportedProviders)
}

function Test-AgentProviderSupported {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Provider)
    # Case-sensitive on purpose: config values are checked in, not typed, and a
    # near-miss should be corrected rather than silently accepted.
    return ($script:AgentSupportedProviders -ccontains $Provider)
}

function New-AgentProviderContext {
    <#
    .SYNOPSIS
        Validates provider scope up front and returns the handle every provider
        operation takes.

    .DESCRIPTION
        Fails closed on an unknown provider and on scope that cannot address a
        repository. Doing it here means an operation never has to re-derive
        scope from config, and a misconfiguration surfaces at startup rather
        than mid-cycle.

        AzureDevOps requires McpInvoker: a scriptblock taking (Name, Arguments,
        RawText) that performs one MCP tool call. Passing the caller's existing
        invoker is what keeps that path byte-identical.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Organization,
        [string]$Project = '',
        [Parameter(Mandatory)][string]$RepositoryName,
        [string]$RepositoryId = '',
        [scriptblock]$McpInvoker,
        [int]$TimeoutSeconds = 60
    )

    if (-not (Test-AgentProviderSupported -Provider $Provider)) {
        throw "Provider '$Provider' is not supported. Supported providers: $($script:AgentSupportedProviders -join ', ')."
    }
    if ([string]::IsNullOrWhiteSpace($Organization)) { throw "Provider context requires a non-empty Organization." }
    if ([string]::IsNullOrWhiteSpace($RepositoryName)) { throw "Provider context requires a non-empty RepositoryName." }
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 3600) { throw "Provider TimeoutSeconds must be between 1 and 3600." }

    switch ($Provider) {
        'AzureDevOps' {
            if ([string]::IsNullOrWhiteSpace($Project)) { throw "The AzureDevOps provider requires a Project." }
            if (-not $McpInvoker) { throw "The AzureDevOps provider requires -McpInvoker; this layer does not reimplement that transport." }
        }
        'GitHub' {
            # 'owner/repo' is the only addressable form, and the owner is the
            # organization. Project is accepted and ignored so one config shape
            # serves both providers.
            if ($Organization -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$') {
                throw "GitHub owner '$Organization' is not a valid account name."
            }
            if ($RepositoryName -notmatch '^[A-Za-z0-9._-]{1,100}$') {
                throw "GitHub repository '$RepositoryName' is not a valid repository name."
            }
        }
    }

    return @{
        Provider       = $Provider
        Organization   = $Organization
        Project        = $Project
        RepositoryName = $RepositoryName
        RepositoryId   = $RepositoryId
        McpInvoker     = $McpInvoker
        TimeoutSeconds = $TimeoutSeconds
        Slug           = if ($Provider -eq 'GitHub') { "$Organization/$RepositoryName" } else { "$Organization/$Project/$RepositoryName" }
    }
}

function Assert-AgentProviderContext {
    param([Parameter(Mandatory)]$Context, [string]$RequiredProvider = '')
    if ($Context -isnot [hashtable] -or -not $Context.ContainsKey('Provider')) {
        throw "A provider context created by New-AgentProviderContext is required."
    }
    if ($RequiredProvider -and $Context.Provider -cne $RequiredProvider) {
        throw "This operation requires the $RequiredProvider provider, but the context is $($Context.Provider)."
    }
}

# ---------------------------------------------------------------------------
# GitHub transport
# ---------------------------------------------------------------------------

function Invoke-AgentGitHubApi {
    <#
    .SYNOPSIS
        One `gh api` call, returning parsed JSON.

    .DESCRIPTION
        Reads the exit code immediately and keeps stderr out of the value.
        Piping a native command into something that stops the pipeline early can
        leave $LASTEXITCODE stale, which turns a failed call into a plausible
        looking result - a failure mode this project has already been bitten by.

        Method is constrained to the verbs the agents actually need. There is no
        way to reach a destructive verb through this function by argument alone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'POST', 'PATCH')][string]$Method = 'GET',
        [hashtable]$Body,
        [int]$TimeoutSeconds = 60
    )

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "The GitHub provider requires the 'gh' CLI on PATH. Install it and run 'gh auth login'." }
    # A path is always relative to the API root; an absolute URL would let a
    # caller (or a value that came from repository content) reach another host.
    if ($Path -match '^[a-z][a-z0-9+.-]*://' -or $Path.StartsWith('//')) {
        throw "GitHub API path '$Path' must be relative to the API root, not an absolute URL."
    }

    $arguments = @('api', $Path, '--method', $Method)
    if ($Body) {
        $arguments += @('--input', '-')
    }
    $stdin = if ($Body) { ($Body | ConvertTo-Json -Depth 10 -Compress) } else { $null }

    $result = Invoke-TimedProcess -FilePath $gh.Source -ArgumentList $arguments `
        -StandardInputContent $stdin -CaptureStdOut -CaptureStdErr -TimeoutSeconds $TimeoutSeconds

    if ($result.TimedOut) { throw "GitHub API call '$Method $Path' timed out after $TimeoutSeconds second(s)." }
    if ($result.ExitCode -ne 0) {
        $detail = if ($result.StdErr) { ($result.StdErr -split "`n" | Select-Object -First 3) -join ' ' } else { "exit code $($result.ExitCode)" }
        throw "GitHub API call '$Method $Path' failed: $detail"
    }
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) { return $null }
    try { return ($result.StdOut | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "GitHub API call '$Method $Path' returned malformed JSON." }
}

function Invoke-AgentGitHubGraphQl {
    <#
    .SYNOPSIS
        One `gh api graphql` call. Needed because review-thread resolution
        state is not exposed by the REST API at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Variables = @{},
        [int]$TimeoutSeconds = 60
    )
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "The GitHub provider requires the 'gh' CLI on PATH. Install it and run 'gh auth login'." }

    $arguments = @('api', 'graphql', '-f', "query=$Query")
    foreach ($key in $Variables.Keys) {
        # -F coerces numbers/booleans; -f would send everything as a string and
        # GraphQL rejects a string where Int! is declared.
        $arguments += @('-F', "$key=$($Variables[$key])")
    }

    $result = Invoke-TimedProcess -FilePath $gh.Source -ArgumentList $arguments `
        -CaptureStdOut -CaptureStdErr -TimeoutSeconds $TimeoutSeconds
    if ($result.TimedOut) { throw "GitHub GraphQL call timed out after $TimeoutSeconds second(s)." }
    if ($result.ExitCode -ne 0) {
        $detail = if ($result.StdErr) { ($result.StdErr -split "`n" | Select-Object -First 3) -join ' ' } else { "exit code $($result.ExitCode)" }
        throw "GitHub GraphQL call failed: $detail"
    }
    try { $parsed = $result.StdOut | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "GitHub GraphQL call returned malformed JSON." }
    # GraphQL reports errors in a 200 body, so a non-zero exit code is not
    # sufficient to detect failure here.
    if ($parsed.PSObject.Properties['errors'] -and $parsed.errors) {
        $first = @($parsed.errors)[0]
        $message = if ($first.PSObject.Properties['message']) { [string]$first.message } else { 'unspecified error' }
        throw "GitHub GraphQL call reported an error: $message"
    }
    return $parsed
}

# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------

function ConvertTo-AgentProviderPullRequestStatus {
    <#
    .SYNOPSIS
        Normalizes a host's pull-request state to the shared vocabulary
        (Active / Completed / Abandoned).

    .DESCRIPTION
        GitHub reports 'closed' for both a merged and an abandoned pull request,
        and distinguishes them only by the merge flag. Collapsing those two into
        one status would make an agent treat merged work as abandoned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [bool]$IsMerged = $false
    )
    switch ($Provider) {
        'AzureDevOps' {
            if (@('Active', 'Completed', 'Abandoned', 'NotSet') -cnotcontains $State) {
                throw "Unrecognized Azure DevOps pull-request status '$State'."
            }
            return $State
        }
        'GitHub' {
            switch ($State.ToLowerInvariant()) {
                'open' { return 'Active' }
                'closed' { if ($IsMerged) { return 'Completed' } else { return 'Abandoned' } }
                default { throw "Unrecognized GitHub pull-request state '$State'." }
            }
        }
        default { throw "Unrecognized provider '$Provider'." }
    }
}

function ConvertTo-AgentProviderVote {
    <#
    .SYNOPSIS
        Normalizes a review outcome to the Azure DevOps vote scale, which is
        the one the agents' gating logic already speaks.

        10 approved | 5 approved with suggestions | 0 no vote
        -5 waiting for author | -10 rejected
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][AllowEmptyString()][string]$State
    )
    switch ($Provider) {
        'GitHub' {
            switch ($State.ToUpperInvariant()) {
                'APPROVED' { return 10 }
                'CHANGES_REQUESTED' { return -10 }
                # A comment-only or dismissed review is explicitly NOT a signal
                # either way; treating it as approval would let an agent
                # auto-complete on a review that approved nothing.
                'COMMENTED' { return 0 }
                'DISMISSED' { return 0 }
                'PENDING' { return 0 }
                default { throw "Unrecognized GitHub review state '$State'." }
            }
        }
        default { throw "ConvertTo-AgentProviderVote does not translate for provider '$Provider'." }
    }
}

function ConvertTo-AgentProviderSnapshot {
    <#
    .SYNOPSIS
        Normalizes a GitHub pull request (plus its reviews) into the shared
        snapshot shape.

    .DESCRIPTION
        Validated rather than trusted: every field the agents gate on is
        type- and range-checked here, because everything downstream treats a
        snapshot as wrapper-owned truth.

        Reviews collapse to one entry per reviewer using the LATEST submitted
        review. GitHub keeps the whole history, so a reviewer who requested
        changes and later approved appears twice; taking the newest is what
        matches how a human reads the PR.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PullRequest,
        [AllowNull()]$Reviews,
        [Parameter(Mandatory)][string]$ExpectedOwner,
        [Parameter(Mandatory)][string]$ExpectedRepository
    )

    foreach ($required in 'number', 'state', 'draft', 'title', 'base', 'head', 'user') {
        if (-not $PullRequest.PSObject.Properties[$required]) {
            throw "GitHub pull-request response omitted '$required'."
        }
    }

    $number = $PullRequest.number
    if ($number -isnot [int] -and $number -isnot [long]) { throw "GitHub pull-request number is not an integer." }
    if ([int]$number -le 0) { throw "GitHub pull-request number must be positive." }

    $isMerged = [bool]($PullRequest.PSObject.Properties['merged'] -and $PullRequest.merged -eq $true)
    $status = ConvertTo-AgentProviderPullRequestStatus -Provider 'GitHub' -State ([string]$PullRequest.state) -IsMerged $isMerged

    $headSha = [string]$PullRequest.head.sha
    if ($headSha -notmatch '^[0-9a-fA-F]{40}$') { throw "GitHub head commit '$headSha' is not a 40-character hexadecimal SHA." }

    $baseRef = [string]$PullRequest.base.ref
    if ([string]::IsNullOrWhiteSpace($baseRef)) { throw "GitHub pull request has an empty base ref." }

    $title = [string]$PullRequest.title
    if ($title.Length -gt 4000) { throw "GitHub pull-request title exceeds 4000 characters." }
    $body = if ($PullRequest.PSObject.Properties['body'] -and $null -ne $PullRequest.body) { [string]$PullRequest.body } else { '' }
    if ($body.Length -gt 1MB) { throw "GitHub pull-request body exceeds 1MB." }

    $login = [string]$PullRequest.user.login
    if ($login -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$') {
        throw "GitHub pull-request author login '$login' failed validation."
    }

    $latestByReviewer = @{}
    foreach ($review in @($Reviews)) {
        if ($null -eq $review) { continue }
        if (-not $review.PSObject.Properties['user'] -or -not $review.user -or -not $review.PSObject.Properties['state']) { continue }
        $reviewerLogin = [string]$review.user.login
        if ([string]::IsNullOrWhiteSpace($reviewerLogin)) { continue }
        $submitted = if ($review.PSObject.Properties['submitted_at'] -and $review.submitted_at) {
            [DateTime]::Parse([string]$review.submitted_at, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        }
        else { [DateTime]::MinValue }
        # A PENDING review is not visible to anyone but its author and must not
        # count toward approval.
        if ([string]$review.state -ceq 'PENDING') { continue }
        if (-not $latestByReviewer.ContainsKey($reviewerLogin) -or $submitted -ge $latestByReviewer[$reviewerLogin].submittedAt) {
            $latestByReviewer[$reviewerLogin] = @{ submittedAt = $submitted; state = [string]$review.state }
        }
    }

    $reviewers = @()
    foreach ($reviewerLogin in ($latestByReviewer.Keys | Sort-Object)) {
        $reviewers += @{
            id          = $reviewerLogin
            vote        = ConvertTo-AgentProviderVote -Provider 'GitHub' -State $latestByReviewer[$reviewerLogin].state
            isContainer = $false
        }
    }

    return @{
        prId             = [int]$number
        repositoryId     = "$ExpectedOwner/$ExpectedRepository"
        project          = $ExpectedOwner
        status           = $status
        isDraft          = [bool]$PullRequest.draft
        targetRefName    = "refs/heads/$baseRef"
        sourceCommitId   = $headSha.ToLowerInvariant()
        authorAlias      = $login
        # GitHub does not expose a verified address on the pull-request payload,
        # and a public profile email is not an identity claim. Left null rather
        # than synthesized, so nothing downstream mistakes it for one.
        authorUniqueName = $null
        title            = $title
        description      = $body
        reviewers        = $reviewers
    }
}

function ConvertTo-AgentProviderThreadStatus {
    <#
    .SYNOPSIS
        Normalizes review-thread state to the shared vocabulary the thread
        classifier already uses (Active / Fixed / Closed).

    .DESCRIPTION
        An outdated-but-unresolved GitHub thread stays Active on purpose: the
        code moved, the question was never answered.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$IsResolved, [bool]$IsOutdated = $false)
    if ($IsResolved) { return 'Closed' }
    return 'Active'
}

# ---------------------------------------------------------------------------
# Provider operations
# ---------------------------------------------------------------------------

function Get-AgentProviderPullRequestSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$PullRequestId
    )
    Assert-AgentProviderContext -Context $Context
    if ($PullRequestId -le 0) { throw "PullRequestId must be positive." }

    switch ($Context.Provider) {
        'GitHub' {
            $slug = $Context.Slug
            $pr = Invoke-AgentGitHubApi -Path "repos/$slug/pulls/$PullRequestId" -TimeoutSeconds $Context.TimeoutSeconds
            $reviews = Invoke-AgentGitHubApi -Path "repos/$slug/pulls/$PullRequestId/reviews?per_page=100" -TimeoutSeconds $Context.TimeoutSeconds
            return ConvertTo-AgentProviderSnapshot -PullRequest $pr -Reviews $reviews `
                -ExpectedOwner $Context.Organization -ExpectedRepository $Context.RepositoryName
        }
        default {
            throw "Get-AgentProviderPullRequestSnapshot is not implemented for '$($Context.Provider)' in this layer; the Azure DevOps path uses its existing MCP invoker."
        }
    }
}

function Get-AgentProviderActivePullRequestIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$TargetRefName = '',
        [AllowEmptyCollection()][string[]]$AuthorAliases = @(),
        [int]$MaxPages = 20
    )
    Assert-AgentProviderContext -Context $Context -RequiredProvider 'GitHub'

    $slug = $Context.Slug
    $baseFilter = if ($TargetRefName) { ($TargetRefName -replace '^refs/heads/', '') } else { '' }
    $ids = New-Object System.Collections.Generic.List[int]
    $pageSize = 100

    for ($page = 1; $page -le $MaxPages; $page++) {
        $path = "repos/$slug/pulls?state=open&per_page=$pageSize&page=$page"
        if ($baseFilter) { $path += "&base=$baseFilter" }
        $entries = @(Invoke-AgentGitHubApi -Path $path -TimeoutSeconds $Context.TimeoutSeconds)

        foreach ($entry in $entries) {
            if ($null -eq $entry) { continue }
            if ($entry.PSObject.Properties['draft'] -and $entry.draft -eq $true) { continue }
            $login = if ($entry.PSObject.Properties['user'] -and $entry.user) { [string]$entry.user.login } else { '' }
            if (@($AuthorAliases).Count -gt 0 -and $AuthorAliases -notcontains $login) { continue }
            $number = $entry.number
            if ($number -isnot [int] -and $number -isnot [long]) { throw "GitHub pull-request list returned a non-integer number." }
            [void]$ids.Add([int]$number)
        }
        if ($entries.Count -lt $pageSize) { return , (@($ids) | Sort-Object -Unique) }
    }
    throw "GitHub pull-request listing exceeded the safety page limit ($MaxPages)."
}

function Get-AgentProviderCommitDateUtc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$CommitId
    )
    Assert-AgentProviderContext -Context $Context -RequiredProvider 'GitHub'
    if ($CommitId -notmatch '^[0-9a-fA-F]{40}$') { throw "Commit id '$CommitId' is not a 40-character hexadecimal SHA." }

    $slug = $Context.Slug
    $commit = Invoke-AgentGitHubApi -Path "repos/$slug/commits/$CommitId" -TimeoutSeconds $Context.TimeoutSeconds
    # Committer date, not author date: a rebased or cherry-picked commit keeps
    # its original author date, which would make fresh work look stale and be
    # skipped by commit-age gating.
    $raw = $commit.commit.committer.date
    if ([string]::IsNullOrWhiteSpace([string]$raw)) { throw "GitHub commit '$CommitId' has no committer date." }
    return [DateTime]::Parse([string]$raw, [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

function Get-AgentProviderPullRequestThreads {
    <#
    .SYNOPSIS
        Review threads with resolution state, normalized to the shape the
        thread classifier consumes.

    .DESCRIPTION
        Uses GraphQL because REST has no concept of a review thread: it returns
        a flat comment list whose structure must be inferred from
        in_reply_to_id, and it never exposes whether a thread was resolved.
        Resolution is exactly what separates an answered comment from an open
        one, so REST alone cannot support the classifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$PullRequestId,
        [int]$MaxThreads = 100,
        [int]$MaxCommentsPerThread = 50
    )
    Assert-AgentProviderContext -Context $Context -RequiredProvider 'GitHub'

    $query = @'
query($owner:String!,$repo:String!,$number:Int!,$threads:Int!,$comments:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$number){
      reviewThreads(first:$threads){
        nodes{
          id isResolved isOutdated path line
          comments(first:$comments){ nodes{ databaseId author{login} body createdAt } }
        }
      }
    }
  }
}
'@
    $response = Invoke-AgentGitHubGraphQl -Query $query -Variables @{
        owner    = $Context.Organization
        repo     = $Context.RepositoryName
        number   = $PullRequestId
        threads  = $MaxThreads
        comments = $MaxCommentsPerThread
    } -TimeoutSeconds $Context.TimeoutSeconds

    $nodes = @($response.data.repository.pullRequest.reviewThreads.nodes)
    $threads = @()
    foreach ($node in $nodes) {
        if ($null -eq $node) { continue }
        $comments = @()
        foreach ($comment in @($node.comments.nodes)) {
            if ($null -eq $comment) { continue }
            $author = if ($comment.PSObject.Properties['author'] -and $comment.author) { [string]$comment.author.login } else { '' }
            $comments += @{
                id           = if ($comment.PSObject.Properties['databaseId']) { $comment.databaseId } else { $null }
                authorAlias  = $author
                authorUnique = $author
                content      = if ($comment.PSObject.Properties['body'] -and $null -ne $comment.body) { [string]$comment.body } else { '' }
                publishedAt  = if ($comment.PSObject.Properties['createdAt']) { [string]$comment.createdAt } else { '' }
            }
        }
        $threads += @{
            id           = [string]$node.id
            status       = ConvertTo-AgentProviderThreadStatus -IsResolved ([bool]$node.isResolved) -IsOutdated ([bool]$node.isOutdated)
            isResolved   = [bool]$node.isResolved
            isOutdated   = [bool]$node.isOutdated
            filePath     = if ($node.PSObject.Properties['path']) { [string]$node.path } else { '' }
            line         = if ($node.PSObject.Properties['line'] -and $null -ne $node.line) { [int]$node.line } else { $null }
            comments     = $comments
            commentCount = $comments.Count
        }
    }
    return , $threads
}

function Get-AgentProviderValidationRun {
    <#
    .SYNOPSIS
        The validation run for a pull request's head commit.

    .DESCRIPTION
        Azure DevOps locates this by pipeline id against a merge ref that
        GitHub has no equivalent of. On GitHub, check runs are attached
        directly to the head SHA, which is both simpler and more precise -
        there is no ambiguity about which commit was validated.

        Returns a normalized summary rather than the raw payload, so gating
        logic does not learn either host's conclusion vocabulary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$HeadSha,
        [string]$CheckNameFilter = ''
    )
    Assert-AgentProviderContext -Context $Context -RequiredProvider 'GitHub'
    if ($HeadSha -notmatch '^[0-9a-fA-F]{40}$') { throw "HeadSha '$HeadSha' is not a 40-character hexadecimal SHA." }

    $slug = $Context.Slug
    $payload = Invoke-AgentGitHubApi -Path "repos/$slug/commits/$HeadSha/check-runs?per_page=100" -TimeoutSeconds $Context.TimeoutSeconds
    $runs = @($payload.check_runs)
    if ($CheckNameFilter) { $runs = @($runs | Where-Object { $_.name -like $CheckNameFilter }) }

    if ($runs.Count -eq 0) {
        return @{ found = $false; state = 'None'; isComplete = $false; isSuccess = $false; runs = @(); headSha = $HeadSha.ToLowerInvariant() }
    }

    $normalized = @()
    foreach ($run in $runs) {
        $normalized += @{
            name       = [string]$run.name
            status     = [string]$run.status
            conclusion = if ($run.PSObject.Properties['conclusion'] -and $null -ne $run.conclusion) { [string]$run.conclusion } else { '' }
            startedAt  = if ($run.PSObject.Properties['started_at']) { [string]$run.started_at } else { '' }
        }
    }

    $allComplete = -not ($normalized | Where-Object { $_.status -ne 'completed' })
    # 'neutral' and 'skipped' are not failures, but they are not evidence of a
    # passing build either. Only 'success' counts as green, so a gate that
    # requires green fails closed.
    $allSuccess = $allComplete -and -not ($normalized | Where-Object { $_.conclusion -ne 'success' })

    $state = if (-not $allComplete) { 'InProgress' } elseif ($allSuccess) { 'Succeeded' } else { 'Failed' }
    return @{
        found      = $true
        state      = $state
        isComplete = $allComplete
        isSuccess  = $allSuccess
        runs       = $normalized
        headSha    = $HeadSha.ToLowerInvariant()
    }
}

function Set-AgentProviderPullRequestVote {
    <#
    .SYNOPSIS
        Casts a review on a pull request.

    .DESCRIPTION
        Deliberately narrow: only Approved and WaitingForAuthor are accepted,
        matching what the agents are permitted to express. There is no path
        here to merge, close, or otherwise alter a pull request.

        The write is confirmed by re-reading the pull request's reviews rather
        than by parsing the response body, because a response that is hard to
        parse must never be mistaken for a write that did not land.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidateSet('Approved', 'WaitingForAuthor')][string]$Vote,
        [string]$Body = ''
    )
    Assert-AgentProviderContext -Context $Context -RequiredProvider 'GitHub'
    if ($PullRequestId -le 0) { throw "PullRequestId must be positive." }

    $event = switch ($Vote) {
        'Approved' { 'APPROVE' }
        'WaitingForAuthor' { 'REQUEST_CHANGES' }
    }
    # GitHub rejects REQUEST_CHANGES with an empty body.
    if ($event -eq 'REQUEST_CHANGES' -and [string]::IsNullOrWhiteSpace($Body)) {
        throw "A REQUEST_CHANGES review requires a non-empty body."
    }

    $slug = $Context.Slug
    $payload = @{ event = $event }
    if ($Body) { $payload['body'] = $Body }

    $null = Invoke-AgentGitHubApi -Path "repos/$slug/pulls/$PullRequestId/reviews" -Method POST -Body $payload -TimeoutSeconds $Context.TimeoutSeconds

    $after = Get-AgentProviderPullRequestSnapshot -Context $Context -PullRequestId $PullRequestId
    $expectedState = if ($event -eq 'APPROVE') { 'APPROVED' } else { 'CHANGES_REQUESTED' }
    $expected = ConvertTo-AgentProviderVote -Provider 'GitHub' -State $expectedState
    $landed = @($after.reviewers | Where-Object { $_.vote -eq $expected }).Count -gt 0
    return @{ requested = $Vote; confirmed = $landed; snapshot = $after }
}

# Exports are declared by the root module (DevPilot.AgentHarness.psm1), which
# dot-sources this file. Declaring them here as well would replace the root's
# export list rather than add to it.

Export-ModuleMember -Function @(
    "Get-DevPilotAgentPath",
    "Resolve-AgentRepositoryRoot",
    "Get-AgentSupportedModels",
    "Get-AgentSessionIsolationEnvVars",
    "Get-AgentWorkIqTargetUrl",
    "Get-AgentMissingMcpServers",
    "Get-AgentLaunchFailureReason",
    "Remove-StaleAgentAttempts",
    "Get-AgentCliJsonOutcome",
    "Invoke-AgentWorkIqTool",
    "Send-AgentTeamsChannelMessage",
    "Send-AgentTeamsDirectMessage",
    "Resolve-AgentTeamsUserChatId",
    "New-AgentTeamsMessageHtml",
    "Get-AgentRequiredProperty",
    "Get-AgentDefaultModelSentinel",
    "Assert-AgentSupportedModel",
    "Test-ParserValidity",
    "Get-OnceFinalExitCode",
    "Test-StrictJsonInt",
    "New-AgentNonce",
    "Test-AgentValidatedParamRebind",
    "Test-AgentProtectedBranch",
    "Get-AgentConfigProperty",
    "Get-AgentConfigString",
    "Get-AgentConfigInt",
    "Get-AgentConfigBool",
    "Get-AgentConfigObject",
    "Get-AgentConfigStringArray",
    "Get-AgentConfig",
    "Test-AgentAllowToolCeiling",
    "Get-AgentCopilotArgs",
    "Enter-AgentLock",
    "Exit-AgentLock",
    "Get-JsonState",
    "Set-JsonState",
    "Write-AgentMetadata",
    "ConvertFrom-AgentResultMarker",
    "Find-CopilotSessionForBranch",
    "Set-TimedProcessArguments",
    "Stop-ProcessTree",
    "Get-TaskTextBeforeDeadline",
    "Invoke-TimedProcess",
    "Open-AgentMcpSession",
    "Close-AgentMcpSession",
    "Send-AgentMcpRequest",
    "Send-AgentMcpNotification",
    "Invoke-AgentMcpTool",
    "Get-AgentSupportedProvider",
    "Test-AgentProviderSupported",
    "New-AgentProviderContext",
    "Assert-AgentProviderContext",
    "Invoke-AgentGitHubApi",
    "Invoke-AgentGitHubGraphQl",
    "ConvertTo-AgentProviderPullRequestStatus",
    "ConvertTo-AgentProviderVote",
    "ConvertTo-AgentProviderSnapshot",
    "ConvertTo-AgentProviderThreadStatus",
    "Get-AgentProviderPullRequestSnapshot",
    "Get-AgentProviderActivePullRequestIds",
    "Get-AgentProviderCommitDateUtc",
    "Get-AgentProviderPullRequestThreads",
    "Get-AgentProviderValidationRun",
    "Set-AgentProviderPullRequestVote"
)



