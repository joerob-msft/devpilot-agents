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
#
# ORDERING IS PART OF THE CONTRACT: within each family the entries are listed
# NEWEST FIRST. Get-AgentGeneralistModelPair derives the current independent
# generalist pairing from that order, so retiring a model or adding its
# successor here is the ONE edit that moves every consumer - the reviewer's
# startup validation, its sealed-decision re-verification, and the offline
# qualification wrapper - at the same time. Nothing downstream may name a
# version of its own; that is precisely how a wrapper ends up asking for a
# model the agent no longer accepts.
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

# The two families an independent generalist cross-check is drawn from, and
# what disqualifies a member of each. Small/specialized variants are excluded
# by name-shape rather than by listing survivors, so a new "-mini" or "-codex"
# entry cannot quietly become a generalist by being added to the registry.
$script:AgentHarnessGeneralistFamilies = @(
    [ordered]@{ Family = "claude-opus"; Include = '^claude-opus-'; Exclude = '(?:-mini|-codex|-flash|-haiku)' },
    [ordered]@{ Family = "gpt"; Include = '^gpt-'; Exclude = '(?:-mini|-codex|-flash)' }
)

function Get-AgentSupportedModels {
    return , @($script:AgentHarnessSupportedModels)
}

function Get-AgentDefaultModelSentinel {
    return $script:AgentHarnessDefaultModelSentinel
}

function Get-AgentGeneralistModelPair {
    <#
        THE single source of truth for "which two models is an independent
        two-pass generalist review made of".

        Derived from the supported-model registry above rather than declared
        separately, because a second declaration is a second thing to forget:
        the defect this closes is a qualification wrapper that named
        claude-opus-4.8 while the agent's startup validation required
        claude-opus-5, so every slot died before a model was ever launched.
        With the pair derived, a registry edit moves the agent and every
        wrapper together and a stale version cannot be written down anywhere.

        Returns the ordered pair (first pass, second pass) plus the sorted
        '|'-joined key the reviewer seals into a decision as
        `generalistPassModels`, so callers never re-derive that string either.
    #>
    param([string[]]$SupportedModels)

    $allowed = if ($SupportedModels -and @($SupportedModels).Count -gt 0) {
        @($SupportedModels)
    }
    else { @($script:AgentHarnessSupportedModels) }

    $selected = @(foreach ($family in $script:AgentHarnessGeneralistFamilies) {
            $candidate = @($allowed | Where-Object {
                    $_ -cmatch $family.Include -and $_ -cnotmatch $family.Exclude
                }) | Select-Object -First 1
            if (-not $candidate) {
                throw ("The supported-model registry carries no '$($family.Family)' generalist. An independent " +
                    "two-pass review needs one model from each family; add the current one to " +
                    "`$script:AgentHarnessSupportedModels, newest first.")
            }
            [string]$candidate
        })
    if ($selected.Count -ne 2 -or $selected[0] -ceq $selected[1]) {
        throw "The derived generalist pairing is not two distinct models: $($selected -join ', ')."
    }
    foreach ($model in $selected) {
        [void](Assert-AgentSupportedModel -ModelId $model -SupportedModels $allowed -Where "derived generalist pairing")
    }
    return [ordered]@{
        First  = $selected[0]
        Second = $selected[1]
        Models = [string[]]@($selected)
        # Sorted, '|'-joined - the exact shape sealed into a gate decision's
        # generalistPassModels and re-verified on promotion.
        SortedKey = (@($selected) | Sort-Object) -join '|'
    }
}

function Test-AgentGeneralistModelPair {
    <#
        True only when the supplied models are exactly the derived pairing -
        both members, no third model, no repeat. Case-sensitive, because a
        model id is an exact argv token.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Models,
        [string[]]$SupportedModels
    )
    $pair = Get-AgentGeneralistModelPair -SupportedModels $SupportedModels
    $supplied = @(@($Models) | Where-Object { $_ })
    if ($supplied.Count -ne 2) { return $false }
    return ((@($supplied) | Sort-Object) -join '|') -ceq $pair.SortedKey
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
        --no-ask-user, --disallow-temp-dir, --available-tools, --allow-tool,
        --deny-tool, --model, --resume) reach the Copilot engine and are not
        reinterpreted by Agency's own parser. `--model` and its id are two
        SEPARATE argv entries. Model is validated against a code-defined
        allowlist.
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
        [switch]$JsonOutput,
        [string[]]$AvailableTools = @()
    )
    $available = @($AvailableTools)
    $allow = @($AllowTools)
    $deny = @($DenyTools)
    $invalidAvailable = @($available | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$' })
    if ($invalidAvailable.Count -gt 0) {
        throw "Get-AgentCopilotArgs: -AvailableTools accepts literal CLI tool names only, not permission patterns: $($invalidAvailable -join ', ')."
    }
    $engineArgs = @("-s", "--no-ask-user", "--disallow-temp-dir")
    if ($JsonOutput) { $engineArgs += @("--output-format", "json") }
    if ($available.Count -gt 0) {
        $engineArgs += @("--available-tools=$($available -join ', ')")
    }
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
        if ($ResumeSessionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') {
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
    # A top-level array may contain exact objects with scalar fields. Bounding
    # the nesting still rejects recursive object/array structures.
    if ($Depth -gt 2) { return $bad }

    switch ([string]$Spec.Type) {
        "int" {
            if (-not (Test-StrictJsonInt -Value $Value -Min ([long]$Spec.Min) -Max ([long]$Spec.Max))) { return $bad }
            return @{ Ok = $true; Value = [int]$Value }
        }
        "guid" {
            if ($Value -isnot [string] -or $Value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z') { return $bad }
            return @{ Ok = $true; Value = [string]$Value }
        }
        "exact" {
            if ($Value -isnot [string] -or $Value -cne [string]$Spec.Expected) { return $bad }
            return @{ Ok = $true; Value = [string]$Value }
        }
        "hex" {
            if ($Value -isnot [string] -or $Value -notmatch "^[0-9a-fA-F]{$([int]$Spec.Length)}\z") { return $bad }
            return @{ Ok = $true; Value = [string]$Value }
        }
        "hexOrNull" {
            if ($null -eq $Value) { return @{ Ok = $true; Value = $null } }
            if ($Value -is [string] -and $Value -match "^[0-9a-fA-F]{$([int]$Spec.Length)}\z") { return @{ Ok = $true; Value = [string]$Value } }
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
            if ($Spec.ContainsKey('NormalizeTypography') -and [bool]$Spec.NormalizeTypography) {
                # A fixed, meaning-preserving transliteration of the typographic
                # characters a model reaches for without thinking. Markers have
                # been lost whole - candidates, accounting and all - over a
                # single em dash inside an otherwise perfect sentence.
                #
                # This is not a relaxation of the ASCII rule. The rule exists so
                # that text destined for a comment cannot carry structure or
                # controls, and every one of these maps to the character a
                # reader would have read anyway. Anything NOT in this table is
                # still rejected, and so is every control character.
                $text = $text.
                Replace([string][char]0x2018, "'").Replace([string][char]0x2019, "'").
                Replace([string][char]0x201A, "'").Replace([string][char]0x201B, "'").
                Replace([string][char]0x201C, '"').Replace([string][char]0x201D, '"').
                Replace([string][char]0x201E, '"').Replace([string][char]0x201F, '"').
                Replace([string][char]0x2010, "-").Replace([string][char]0x2011, "-").
                Replace([string][char]0x2012, "-").Replace([string][char]0x2013, "-").
                Replace([string][char]0x2014, "-").Replace([string][char]0x2015, "-").
                Replace([string][char]0x2026, "...").Replace([string][char]0x00A0, " ").
                Replace([string][char]0x2032, "'").Replace([string][char]0x2033, '"').
                Replace([string][char]0x00AB, '"').Replace([string][char]0x00BB, '"')
            }
            $max = if ($Spec.ContainsKey('MaxLength')) { [int]$Spec.MaxLength } else { 1000 }
            # Keep the text as it arrived: the control-character scan and the
            # pattern are checked against this, not against a shortened copy.
            $original = $text
            if ($text.Length -gt $max) {
                # A field may opt into being SHORTENED rather than rejected. Only
                # fields that never become external text may do so: a comment
                # body must be exactly what the model wrote or nothing at all.
                # For a reporting field, though, rejecting the whole marker over
                # a long sentence throws away every finding the marker carries -
                # the report destroying the thing it reports on. Twice now a
                # complete accounting was lost that way.
                if (-not ($Spec.ContainsKey('Truncate') -and [bool]$Spec.Truncate)) { return $bad }
                if ($max -le 3) { return $bad }
                $cut = $max - 3
                # Never cut between a surrogate pair. A lone half is not a
                # control character and has no pattern to fail, so it survives
                # validation and then throws when the preview is written as
                # strict UTF-8 - losing the whole pass to the very mechanism
                # added to stop passes being lost.
                if ($cut -gt 0 -and [char]::IsHighSurrogate($text[$cut - 1])) { $cut-- }
                $text = $text.Substring(0, $cut) + "..."
            }
            # Against the ORIGINAL, like the control-character scan and the
            # pattern below. Checked after truncation, a field of four hundred
            # spaces becomes "..." and passes as non-empty.
            if (-not ($Spec.ContainsKey('AllowEmpty') -and [bool]$Spec.AllowEmpty) -and $original.Trim() -eq "") { return $bad }
            $allowNewlines = ($Spec.ContainsKey('AllowNewlines') -and [bool]$Spec.AllowNewlines)
            foreach ($ch in $original.ToCharArray()) {
                if ([char]::IsControl($ch)) {
                    if ($allowNewlines -and ($ch -eq "`n" -or $ch -eq "`r" -or $ch -eq "`t")) { continue }
                    return $bad
                }
            }
            if ($Spec.ContainsKey('Pattern') -and $Spec.Pattern) {
                # Against the ORIGINAL, not the shortened text. Checking the cut
                # version would accept a string whose only violation happened to
                # sit past the cut, which is a pattern that does not mean what
                # it says.
                if ($original -notmatch [string]$Spec.Pattern) { return $bad }
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
        "object" {
            if ($Value -isnot [System.Management.Automation.PSCustomObject]) { return $bad }
            if (-not $Spec.ContainsKey('Schema')) { return $bad }
            $objectSchema = $Spec.Schema
            if ($objectSchema -isnot [hashtable] -or
                -not $objectSchema.ContainsKey('Keys') -or
                -not $objectSchema.ContainsKey('Fields')) {
                return $bad
            }
            $objectKeys = @($objectSchema.Keys)
            $valueKeys = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($name in $valueKeys) { if ($objectKeys -notcontains $name) { return $bad } }
            foreach ($name in $objectKeys) { if (-not $Value.PSObject.Properties[$name]) { return $bad } }
            $record = @{}
            foreach ($name in $objectKeys) {
                $fieldSpec = $objectSchema.Fields[$name]
                if ($null -eq $fieldSpec) { return $bad }
                $converted = ConvertTo-AgentMarkerFieldValue -Spec $fieldSpec `
                    -Value $Value.PSObject.Properties[$name].Value -Depth ($Depth + 1)
                if (-not $converted.Ok) { return $bad }
                $record[$name] = $converted.Value
            }
            return @{ Ok = $true; Value = $record }
        }
        default { return $bad }
    }
}

function ConvertTo-AgentCanonicalMarkerJson {
    <#
        Order-preserving canonical rendering of a parsed marker payload, used to
        compare two occurrences of the same marker for MEANING rather than for
        byte equality.

        Copilot's stdout carries the same marker more than once in practice, and
        the two renderings are not always byte-identical: a model that prints a
        pretty, fenced copy in its closing summary and a compact copy on the
        final line has emitted one result, not two. Byte comparison rejected
        those cycles. Canonical comparison accepts them while still rejecting
        two markers that actually SAY different things, which is the property
        that matters against an injected marker.

        Object keys are sorted so key order cannot smuggle a difference, and the
        depth is bounded so a hostile deeply nested payload cannot recurse.
    #>
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 24) { throw "Marker payload exceeded the maximum canonical depth." }
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }
    if ($Value -is [string]) { return (ConvertTo-Json -InputObject $Value -Compress) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)
        $parts = @($names | ForEach-Object {
                (ConvertTo-Json -InputObject $_ -Compress) + ":" +
                (ConvertTo-AgentCanonicalMarkerJson -Value $Value.PSObject.Properties[$_].Value -Depth ($Depth + 1))
            })
        return "{" + ($parts -join ",") + "}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($item in $Value) { $parts += (ConvertTo-AgentCanonicalMarkerJson -Value $item -Depth ($Depth + 1)) }
        return "[" + ($parts -join ",") + "]"
    }
    throw "Marker payload contained an unsupported JSON type."
}

# ---------------------------------------------------------------------------
# Result-marker extraction budget (shared by extraction AND schema sizing).
#
# The scan window is expressed in CHARACTERS because the brace-matching scan
# below indexes $StdOutText by UTF-16 code unit. Sharing ONE budget between the
# extraction scan and the worst-case schema sizing (Measure-AgentMarkerSchema
# WorstCaseChars) is what lets a caller PROVE, before it ever launches a model,
# that the largest object its declared schema can legally produce still fits the
# window the extractor will scan - or fail closed at startup if it cannot.
# ---------------------------------------------------------------------------
$script:AgentMarkerScanWindowChars = 65536   # per-anchor brace-scan window
$script:AgentMarkerMaxPrefixScans = 20000    # bare-prefix occurrences examined
$script:AgentMarkerMaxExaminedPayloads = 512 # payload-bearing anchors examined
$script:AgentMarkerMaxRetainedCandidates = 16

# Typed extraction outcome status values. A caller uses these to decide, with no
# prose matching, whether a failed extraction is a retryable result-EMISSION
# slip (retry with a fresh nonce) or a terminal rejection (never retried).
$script:AgentMarkerStatus = @{
    Success         = 'success'         # a single schema-valid, bound marker
    MissingMarker   = 'missingMarker'   # no prefixed line carried a payload
    MalformedMarker = 'malformedMarker' # a payload was present but not JSON
    NonObject       = 'nonObject'       # the JSON payload was an array/scalar
    Truncated       = 'truncated'       # the object never closed within window
    Overflow        = 'overflow'        # too many carrying-the-nonce occurrences
    SchemaInvalid   = 'schemaInvalid'   # parsed object failed the typed schema
    WrongBinding    = 'wrongBinding'    # an exact field carried the wrong value
    AmbiguousMarker = 'ambiguousMarker' # two occurrences meant different things
}

function Test-AgentMarkerStatusRetryable {
    <#
        A result-EMISSION failure - the model did the work but did not frame the
        answer the wrapper can read - is worth exactly one fresh-nonce retry. A
        marker that carries the WRONG binding (an exact field echoed with the
        wrong value, e.g. a replayed nonce) is not: a second attempt would not
        change what the model chose to bind to, and retrying it is how a replay
        would be handed extra tries. Process/timeout/environment failures are
        classified by the caller, not here.
    #>
    param([Parameter(Mandatory)][string]$Status)
    switch ($Status) {
        'success' { return $false }
        'wrongBinding' { return $false }
        'missingMarker' { return $true }
        'malformedMarker' { return $true }
        'nonObject' { return $true }
        'truncated' { return $true }
        'overflow' { return $true }
        'schemaInvalid' { return $true }
        'ambiguousMarker' { return $true }
        default { return $false }
    }
}

function Get-AgentResultMarkerOutcome {
    <#
        Typed core of result-marker extraction. Parses a single strict
        `<PREFIX>: <json>` result line as HOSTILE input and returns a typed
        outcome instead of a bare object/$null, so a caller can tell a missing
        marker from a malformed one from a schema-invalid one from a
        wrong-binding one and act (retry/accounting) deterministically.

        Returns a hashtable:
          @{
            Status    = one of $script:AgentMarkerStatus values
            Value     = parsed marker hashtable (only when Status -eq 'success')
            Field     = offending field name for schemaInvalid/wrongBinding, or $null
            Retryable = [bool] (see Test-AgentMarkerStatusRetryable)
            Reason    = short human string
          }

        Behaviour is byte-for-byte identical to the historical
        ConvertFrom-AgentResultMarker for the accept/reject decision: the same
        anchors are scanned, the same candidates are collected, the same
        canonical-agreement and schema checks run in the same order. The ONLY
        addition is that each fail-closed exit now records WHY. A schema-invalid
        or wrong-binding occurrence is still DROPPED as a candidate (never a
        veto), so a later valid marker still wins - the typed reason is reported
        only when no valid marker exists.

        $Schema = @{
            Keys   = @(<ordered allowed/required key names>)
            Fields = @{ <name> = @{ Type = 'int'|'guid'|'exact'|'hex'|'hexOrNull'|'enum'|'bool'|'string'|'object'|'objectArray'; ... } }
        }
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText,
        [Parameter(Mandatory)][string]$MarkerPrefix,
        [Parameter(Mandatory)][hashtable]$Schema,
        [int]$ScanWindowChars = $script:AgentMarkerScanWindowChars
    )
    $mk = {
        param([string]$Status, $Value, $Field, [string]$Reason)
        return @{
            Status    = $Status
            Value     = $Value
            Field     = $Field
            Retryable = (Test-AgentMarkerStatusRetryable -Status $Status)
            Reason    = $Reason
        }
    }
    try {
        if ($ScanWindowChars -lt 2) { $ScanWindowChars = $script:AgentMarkerScanWindowChars }
        if ([string]::IsNullOrWhiteSpace($StdOutText)) {
            return (& $mk $script:AgentMarkerStatus.MissingMarker $null $null "No output was produced.")
        }

        # The strongest diagnostic seen while collecting candidates, reported
        # only if no valid candidate survives. Higher rank = more informative /
        # more terminal, so a definite wrong-binding signal is surfaced ahead of
        # a mere "the payload did not parse". Held in FUNCTION-LOCAL state (a
        # hashtable the $note closure mutates by member, never reassigns) so the
        # parse is reentrant and leaves no module-global residue.
        $rankOf = {
            param([string]$s)
            switch ($s) {
                'wrongBinding' { return 6 }
                'schemaInvalid' { return 5 }
                'nonObject' { return 4 }
                'truncated' { return 3 }
                'malformedMarker' { return 2 }
                'missingMarker' { return 1 }
                default { return 0 }
            }
        }
        $best = @{ Rank = -1; Status = $null; Field = $null }
        $note = {
            param([string]$Status, $Field)
            $r = (& $rankOf $Status)
            if ($r -gt $best.Rank) {
                $best.Rank = $r
                $best.Status = $Status
                $best.Field = $Field
            }
        }

        $parsedCandidates = New-Object System.Collections.Generic.List[object]
        $quoteChar = [char]'"'
        $escapeChar = [char]'\'
        $openBrace = [char]'{'
        $closeBrace = [char]'}'
        $exactFields = @($Schema.Keys | Where-Object {
                $spec = $Schema.Fields[$_]
                $null -ne $spec -and [string]$spec.Type -ceq 'exact'
            })
        $anchorPattern = "(?m)^[ `t]*" + [regex]::Escape($MarkerPrefix)
        $scanned = 0
        $examined = 0
        foreach ($anchor in [regex]::Matches($StdOutText, $anchorPattern)) {
            $scanned++
            if ($scanned -gt $script:AgentMarkerMaxPrefixScans) {
                Write-Verbose "Result-marker scan stopped after $scanned prefix occurrence(s)."
                break
            }
            $hit = $anchor.Index
            $lineEnd = $StdOutText.IndexOf("`n", $hit, [StringComparison]::Ordinal)
            if ($lineEnd -lt 0) { $lineEnd = $StdOutText.Length }
            $searchStart = $hit + $anchor.Length
            if ($searchStart -ge $lineEnd) { continue }
            $jsonStart = $StdOutText.IndexOf($openBrace, $searchStart, $lineEnd - $searchStart)
            if ($jsonStart -lt 0) { continue }
            $examined++
            if ($examined -gt $script:AgentMarkerMaxExaminedPayloads) { break }
            $depth = 0
            $inString = $false
            $escaped = $false
            $jsonEnd = -1
            $limit = [Math]::Min($StdOutText.Length, $jsonStart + $ScanWindowChars)
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
            if ($jsonEnd -lt 0) {
                # The object never closed inside the window: either it was cut
                # off (truncated) or an over-long/over-nested payload overflowed
                # the bounded scan. Both are the same fail-closed exit.
                & $note $script:AgentMarkerStatus.Truncated $null
                continue
            }
            $parsed = $null
            try { $parsed = $StdOutText.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json -ErrorAction Stop }
            catch {
                & $note $script:AgentMarkerStatus.MalformedMarker $null
                continue
            }
            if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
                & $note $script:AgentMarkerStatus.NonObject $null
                continue
            }
            if ($exactFields.Count -gt 0) {
                $bound = $true
                foreach ($name in $exactFields) {
                    $property = $parsed.PSObject.Properties[$name]
                    if ($null -eq $property -or $property.Value -isnot [string]) {
                        # The binding field is absent or not even a string: the
                        # model failed to EMIT it. That is a schema-shape slip,
                        # not evidence of a marker bound to the wrong work, so it
                        # is retryable with a fresh nonce.
                        & $note $script:AgentMarkerStatus.SchemaInvalid $name
                        $bound = $false
                        break
                    }
                    if ([string]$property.Value -cne [string]$Schema.Fields[$name].Expected) {
                        # The field is present but carries the WRONG value (a
                        # replayed or invented nonce, a foreign project). Never
                        # retried.
                        & $note $script:AgentMarkerStatus.WrongBinding $name
                        $bound = $false
                        break
                    }
                }
                if (-not $bound) { continue }
            }
            [void]$parsedCandidates.Add($parsed)
            if ($parsedCandidates.Count -gt $script:AgentMarkerMaxRetainedCandidates) {
                return (& $mk $script:AgentMarkerStatus.Overflow $null $null `
                        "More than $script:AgentMarkerMaxRetainedCandidates marker occurrences carried this cycle's nonce.")
            }
        }
        if ($parsedCandidates.Count -eq 0) {
            $status = if ($best.Status) { $best.Status } else { $script:AgentMarkerStatus.MissingMarker }
            $field = $best.Field
            $reason = switch ($status) {
                'wrongBinding' { "A marker echoed the wrong '$field' value." }
                'schemaInvalid' { "A marker omitted or malformed the required '$field' field." }
                'nonObject' { "The marker payload was not a JSON object." }
                'truncated' { "The marker payload did not close inside the $ScanWindowChars-character scan window." }
                'malformedMarker' { "A marker prefix was present but its payload was not valid JSON." }
                default { "No valid result marker was found." }
            }
            return (& $mk $status $null $field $reason)
        }

        # Every surviving occurrence must MEAN the same thing.
        $obj = $null
        $canonical = $null
        foreach ($parsed in $parsedCandidates) {
            $parsedCanonical = ConvertTo-AgentCanonicalMarkerJson -Value $parsed
            if ($null -eq $canonical) {
                $canonical = $parsedCanonical
                $obj = $parsed
                continue
            }
            if ($parsedCanonical -cne $canonical) {
                return (& $mk $script:AgentMarkerStatus.AmbiguousMarker $null $null `
                        "Two marker occurrences carried this cycle's nonce but disagreed.")
            }
        }
        if ($obj -isnot [System.Management.Automation.PSCustomObject]) {
            return (& $mk $script:AgentMarkerStatus.NonObject $null $null "The marker payload was not a JSON object.")
        }

        $allowedKeys = @($Schema.Keys)
        $actualKeys = @($obj.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($name in $actualKeys) {
            if ($allowedKeys -notcontains $name) {
                return (& $mk $script:AgentMarkerStatus.SchemaInvalid $null $name "The marker carried an unexpected key '$name'.")
            }
        }
        foreach ($name in $allowedKeys) {
            if (-not $obj.PSObject.Properties[$name]) {
                return (& $mk $script:AgentMarkerStatus.SchemaInvalid $null $name "The marker omitted the required key '$name'.")
            }
        }

        $out = @{}
        foreach ($name in $allowedKeys) {
            $spec = $Schema.Fields[$name]
            if ($null -eq $spec) {
                return (& $mk $script:AgentMarkerStatus.SchemaInvalid $null $name "The schema declared no rule for key '$name'.")
            }
            $converted = ConvertTo-AgentMarkerFieldValue -Spec $spec -Value $obj.PSObject.Properties[$name].Value
            if (-not $converted.Ok) {
                # A present-but-wrong exact field is a wrong binding; every other
                # field failure is a schema-shape failure.
                $status = if ([string]$spec.Type -ceq 'exact') { $script:AgentMarkerStatus.WrongBinding } else { $script:AgentMarkerStatus.SchemaInvalid }
                return (& $mk $status $null $name "The marker field '$name' failed its typed schema rule.")
            }
            $out[$name] = $converted.Value
        }
        return (& $mk $script:AgentMarkerStatus.Success $out $null "")
    }
    catch {
        return (& $mk $script:AgentMarkerStatus.MalformedMarker $null $null "The marker could not be parsed: $($_.Exception.Message)")
    }
}

function ConvertFrom-AgentResultMarker {
    <#
        Compatibility wrapper preserved for every existing caller: returns the
        parsed marker hashtable on success and $null on any fail-closed
        condition, exactly as before. New callers that need to distinguish
        WHY extraction failed (for retry/accounting) use
        ConvertFrom-AgentResultMarkerOutcome instead. Both share one
        implementation (Get-AgentResultMarkerOutcome) so the accept/reject
        decision can never drift between them.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText,
        [Parameter(Mandatory)][string]$MarkerPrefix,
        [Parameter(Mandatory)][hashtable]$Schema,
        [int]$ScanWindowChars = $script:AgentMarkerScanWindowChars
    )
    $outcome = Get-AgentResultMarkerOutcome -StdOutText $StdOutText -MarkerPrefix $MarkerPrefix `
        -Schema $Schema -ScanWindowChars $ScanWindowChars
    if ($outcome.Status -ceq $script:AgentMarkerStatus.Success) { return $outcome.Value }
    return $null
}

function ConvertFrom-AgentResultMarkerOutcome {
    <#
        Public typed extraction entry point. Identical parse to
        ConvertFrom-AgentResultMarker but returns the full typed outcome
        (Status/Value/Field/Retryable/Reason). See Get-AgentResultMarkerOutcome.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText,
        [Parameter(Mandatory)][string]$MarkerPrefix,
        [Parameter(Mandatory)][hashtable]$Schema,
        [int]$ScanWindowChars = $script:AgentMarkerScanWindowChars
    )
    return Get-AgentResultMarkerOutcome -StdOutText $StdOutText -MarkerPrefix $MarkerPrefix `
        -Schema $Schema -ScanWindowChars $ScanWindowChars
}

function Measure-AgentMarkerSchemaWorstCaseChars {
    <#
        Upper bound, in CHARACTERS, on the compact JSON serialization of the
        largest object a marker schema can legally produce. Character-based to
        match the extractor's character-indexed scan window, so the two share
        one budget: a schema whose worst case exceeds the window has a legal
        object the extractor could never capture, and the caller can refuse to
        launch rather than discover it on a real review.

        String fields forbid control characters, so the only in-string
        expansion is the escaping of `"` and `\` (one char -> two), bounded by
        MaxLength; hence MaxLength*2 + 2 quotes is a true upper bound per string.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Schema,
        [int]$Depth = 0
    )
    if ($Depth -gt 24) { throw "Marker schema exceeded the maximum measurable depth." }
    $fieldChars = {
        param([hashtable]$Spec)
        switch ([string]$Spec.Type) {
            'int' {
                $max = if ($Spec.ContainsKey('Max')) { [long]$Spec.Max } else { [long][int]::MaxValue }
                $min = if ($Spec.ContainsKey('Min')) { [long]$Spec.Min } else { [long][int]::MinValue }
                $digits = [Math]::Max(([string][Math]::Abs($max)).Length, ([string][Math]::Abs($min)).Length)
                $sign = if ($min -lt 0) { 1 } else { 0 }
                return $digits + $sign
            }
            'guid' { return 38 }                                  # 36 + 2 quotes
            'bool' { return 5 }                                   # "false"
            'hex' { return ([int]$Spec.Length) + 2 }
            'hexOrNull' { return [Math]::Max((([int]$Spec.Length) + 2), 4) }
            'exact' { return (ConvertTo-Json -InputObject ([string]$Spec.Expected) -Compress).Length }
            'enum' {
                $m = 0
                foreach ($v in @($Spec.Values)) {
                    $len = (ConvertTo-Json -InputObject ([string]$v) -Compress).Length
                    if ($len -gt $m) { $m = $len }
                }
                return $m
            }
            'string' {
                $maxLen = if ($Spec.ContainsKey('MaxLength')) { [int]$Spec.MaxLength } else { 0 }
                return ($maxLen * 2) + 2
            }
            'object' {
                return (Measure-AgentMarkerSchemaWorstCaseChars -Schema ([hashtable]$Spec.Schema) -Depth ($Depth + 1))
            }
            'objectArray' {
                $maxItems = if ($Spec.ContainsKey('MaxItems')) { [int]$Spec.MaxItems } else { 25 }
                $itemSchema = @{ Keys = @($Spec.Item.Keys); Fields = $Spec.Item.Fields }
                $itemChars = Measure-AgentMarkerSchemaWorstCaseChars -Schema $itemSchema -Depth ($Depth + 1)
                # [ ] plus each item and a separating comma.
                return 2 + ($maxItems * ($itemChars + 1))
            }
            default { throw "Cannot size unknown marker field type '$($Spec.Type)'." }
        }
    }
    $total = 2   # the object's own braces
    $keys = @($Schema.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $name = [string]$keys[$i]
        $spec = $Schema.Fields[$name]
        if ($null -eq $spec) { throw "Schema key '$name' has no field rule." }
        $keyChars = (ConvertTo-Json -InputObject $name -Compress).Length   # "name"
        $total += $keyChars + 1 + (& $fieldChars ([hashtable]$spec))       # "name":value
        if ($i -lt $keys.Count - 1) { $total += 1 }                        # comma
    }
    return $total
}

function Test-AgentMarkerSchemaFitsScanWindow {
    <#
        Returns whether the largest legal object a schema can produce still fits
        the extractor's scan window. A caller asserts Fits before launching a
        model so a schema/window mismatch fails at startup (deterministically),
        not on a real review whose complete, valid marker the window would
        silently truncate.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Schema,
        [int]$ScanWindowChars = $script:AgentMarkerScanWindowChars,
        [string]$MarkerPrefix = ""
    )
    $worst = Measure-AgentMarkerSchemaWorstCaseChars -Schema $Schema
    # The extractor scans from the opening brace; the prefix and the single
    # space before the brace sit OUTSIDE the window, so they do not count here.
    return [pscustomobject][ordered]@{
        Fits           = ($worst -le $ScanWindowChars)
        WorstCaseChars = $worst
        WindowChars    = $ScanWindowChars
    }
}

function Measure-AgentMarkerSchemaWorstCaseBytes {
    <#
        Upper bound, in UTF-8 BYTES, on the compact JSON serialization of the
        largest object a marker schema can legally produce. The char-based
        Measure-AgentMarkerSchemaWorstCaseChars sizes the extractor's scan
        window; this sizes the surface's hard output byte cap, which is what a
        model process is actually bounded by. They differ whenever a string
        field permits non-ASCII: a JSON string escapes only `"` and `\` (one
        char -> two ASCII bytes), but an unescaped non-ASCII BMP code unit costs
        up to THREE UTF-8 bytes. Three bytes per character dominates the doubled
        escape, so a string field's worst case is MaxLength*3 + 2 quote bytes -
        conservative regardless of whether a field's pattern happens to forbid
        non-ASCII. Numeric, guid, hex and boolean literals are ASCII, so their
        byte cost equals their char cost; exact/enum values are measured as the
        actual UTF-8 byte length of their JSON.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Schema,
        [int]$Depth = 0
    )
    if ($Depth -gt 24) { throw "Marker schema exceeded the maximum measurable depth." }
    $fieldBytes = {
        param([hashtable]$Spec)
        switch ([string]$Spec.Type) {
            'int' {
                $max = if ($Spec.ContainsKey('Max')) { [long]$Spec.Max } else { [long][int]::MaxValue }
                $min = if ($Spec.ContainsKey('Min')) { [long]$Spec.Min } else { [long][int]::MinValue }
                $digits = [Math]::Max(([string][Math]::Abs($max)).Length, ([string][Math]::Abs($min)).Length)
                $sign = if ($min -lt 0) { 1 } else { 0 }
                return $digits + $sign
            }
            'guid' { return 38 }
            'bool' { return 5 }
            'hex' { return ([int]$Spec.Length) + 2 }
            'hexOrNull' { return [Math]::Max((([int]$Spec.Length) + 2), 4) }
            'exact' { return [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject ([string]$Spec.Expected) -Compress)) }
            'enum' {
                $m = 0
                foreach ($v in @($Spec.Values)) {
                    $len = [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject ([string]$v) -Compress))
                    if ($len -gt $m) { $m = $len }
                }
                return $m
            }
            'string' {
                $maxLen = if ($Spec.ContainsKey('MaxLength')) { [int]$Spec.MaxLength } else { 0 }
                return ($maxLen * 3) + 2
            }
            'object' {
                return (Measure-AgentMarkerSchemaWorstCaseBytes -Schema ([hashtable]$Spec.Schema) -Depth ($Depth + 1))
            }
            'objectArray' {
                $maxItems = if ($Spec.ContainsKey('MaxItems')) { [int]$Spec.MaxItems } else { 25 }
                $itemSchema = @{ Keys = @($Spec.Item.Keys); Fields = $Spec.Item.Fields }
                $itemBytes = Measure-AgentMarkerSchemaWorstCaseBytes -Schema $itemSchema -Depth ($Depth + 1)
                return 2 + ($maxItems * ($itemBytes + 1))
            }
            default { throw "Cannot size unknown marker field type '$($Spec.Type)'." }
        }
    }
    $total = 2   # the object's own braces
    $keys = @($Schema.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $name = [string]$keys[$i]
        $spec = $Schema.Fields[$name]
        if ($null -eq $spec) { throw "Schema key '$name' has no field rule." }
        $keyBytes = [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $name -Compress))   # "name"
        $total += $keyBytes + 1 + (& $fieldBytes ([hashtable]$spec))                                            # "name":value
        if ($i -lt $keys.Count - 1) { $total += 1 }                                                            # comma
    }
    return $total
}

function Test-AgentMarkerSchemaFitsLaunchContract {
    <#
        A surface's complete result-contract fit check: the largest legal marker
        the schema can produce must fit BOTH the character scan window the
        extractor will use AND the surface's hard UTF-8 output byte cap. Callers
        assert Fits before launching a model, so a schema/window/cap mismatch
        fails deterministically at startup rather than silently dropping a
        complete, valid marker on a real review. Returns the measured worst
        cases so a refusal can name exactly which bound was exceeded.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Schema,
        [Parameter(Mandatory)][int]$ScanWindowChars,
        [Parameter(Mandatory)][int]$MaxOutputBytes
    )
    $worstChars = Measure-AgentMarkerSchemaWorstCaseChars -Schema $Schema
    $worstBytes = Measure-AgentMarkerSchemaWorstCaseBytes -Schema $Schema
    $fitsWindow = ($worstChars -le $ScanWindowChars)
    $fitsCap = ($worstBytes -le $MaxOutputBytes)
    $reason = $null
    if (-not $fitsWindow) {
        $reason = "largest legal marker is $worstChars chars, above the ${ScanWindowChars}-char scan window"
    }
    elseif (-not $fitsCap) {
        $reason = "largest legal marker is $worstBytes bytes, above the ${MaxOutputBytes}-byte output cap"
    }
    return [pscustomobject][ordered]@{
        Fits           = ($fitsWindow -and $fitsCap)
        WorstCaseChars = $worstChars
        WorstCaseBytes = $worstBytes
        ScanWindowChars = $ScanWindowChars
        MaxOutputBytes = $MaxOutputBytes
        Reason         = $reason
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

function Add-AgentOfflineTelemetryEvent {
    param(
        [Parameter(Mandatory)][string]$Event,
        [hashtable]$Data = @{}
    )
    if ($env:DEVPILOT_OFFLINE_TELEMETRY_MODE -cne "production-test-only" -or
        [string]::IsNullOrWhiteSpace($env:DEVPILOT_OFFLINE_TELEMETRY_PATH)) {
        return
    }
    $record = [ordered]@{
        schemaVersion = 1
        event = $Event
        processId = $PID
        recordedAtUtc = [DateTime]::UtcNow.ToString("o")
        data = [ordered]@{}
    }
    foreach ($key in @($Data.Keys | Sort-Object -CaseSensitive)) {
        $record.data[[string]$key] = $Data[$key]
    }
    [IO.File]::AppendAllText(
        $env:DEVPILOT_OFFLINE_TELEMETRY_PATH,
        (ConvertTo-Json -InputObject $record -Depth 12 -Compress) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
}

function Set-TimedProcessArguments {
    param([Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$Psi, [string[]]$ArgumentList)
    foreach ($argument in @($ArgumentList)) { $Psi.ArgumentList.Add($argument) }
}

function Stop-ProcessTree {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    # A direct child can exit while one of its descendants still owns a copied
    # stdout/stderr handle. Process.Kill(true) can no longer discover that tree
    # once the root has exited, but Win32_Process retains each descendant's
    # ParentProcessId. Snapshot and stop deepest-first before the normal kill
    # fallbacks so output-drain timeouts do not leave detached pipe holders.
    if ($IsWindows) {
        try {
            $rootStartedAt = $Process.StartTime.ToUniversalTime()
            $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop)
            $frontier = @([int]$Process.Id)
            $descendants = [System.Collections.Generic.List[int]]::new()
            while ($frontier.Count -gt 0) {
                $next = [System.Collections.Generic.List[int]]::new()
                foreach ($candidate in $allProcesses) {
                    if ($frontier -contains [int]$candidate.ParentProcessId -and
                        [DateTime]$candidate.CreationDate -ge $rootStartedAt.AddSeconds(-1)) {
                        [void]$descendants.Add([int]$candidate.ProcessId)
                        [void]$next.Add([int]$candidate.ProcessId)
                    }
                }
                $frontier = @($next)
            }
            for ($index = $descendants.Count - 1; $index -ge 0; $index--) {
                Stop-Process -Id $descendants[$index] -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
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
        [string]$ProgressPath = "",
        [ValidateRange(0, 86400)][int]$ProgressTimeoutSeconds = 0,
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

    $startedAtUtc = [DateTime]::UtcNow
    $deadline = $startedAtUtc.AddSeconds($TimeoutSeconds)
    $lastProgressUtc = $startedAtUtc
    $progressObserved = $false
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $telemetryArguments = @($ArgumentList)
        for ($argumentIndex = 0; $argumentIndex -lt $telemetryArguments.Count - 1; $argumentIndex++) {
            if ([string]$telemetryArguments[$argumentIndex] -ceq '-BindingBase64') {
                $telemetryArguments[$argumentIndex + 1] = '$OPERATIONAL_BINDING'
            }
        }
        Add-AgentOfflineTelemetryEvent -Event "process.started" -Data @{
            executable = [string]$psi.FileName
            childProcessId = [int]$proc.Id
            arguments = $telemetryArguments
        }

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
        $timeoutReason = ""
        if (-not $timedOut) {
            if (-not $ProgressPath -or $ProgressTimeoutSeconds -le 0) {
                $remainingMs = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                $exited = $proc.WaitForExit($remainingMs)
                $timedOut = -not $exited
                if ($timedOut) { $timeoutReason = "hardDeadline" }
            }
            else {
                while (-not $exited) {
                    $nowUtc = [DateTime]::UtcNow
                    if ($nowUtc -ge $deadline) {
                        $timedOut = $true
                        $timeoutReason = "hardDeadline"
                        break
                    }
                    if (Test-Path -LiteralPath $ProgressPath) {
                        $progressItems = [System.Collections.Generic.List[object]]::new()
                        $rootProgress = Get-Item -LiteralPath $ProgressPath -ErrorAction SilentlyContinue
                        if ($rootProgress) { [void]$progressItems.Add($rootProgress) }
                        foreach ($progressItem in @(Get-ChildItem -LiteralPath $ProgressPath -File -Recurse `
                                    -ErrorAction SilentlyContinue)) {
                            [void]$progressItems.Add($progressItem)
                        }
                        $latestProgress = @($progressItems |
                                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
                        if ($latestProgress.Count -eq 1) {
                            if (-not $progressObserved -or $latestProgress[0].LastWriteTimeUtc -gt $lastProgressUtc) {
                                $lastProgressUtc = $latestProgress[0].LastWriteTimeUtc
                            }
                            $progressObserved = $true
                        }
                    }
                    if ($progressObserved -and
                        ($nowUtc - $lastProgressUtc).TotalSeconds -ge $ProgressTimeoutSeconds) {
                        $timedOut = $true
                        $timeoutReason = "progressDeadline"
                        break
                    }
                    $remainingMs = [Math]::Max(1, [int]($deadline - $nowUtc).TotalMilliseconds)
                    $exited = $proc.WaitForExit([Math]::Min(250, $remainingMs))
                }
            }
        }

        if ($timedOut) {
            if (-not $timeoutReason) { $timeoutReason = "standardInputDeadline" }
            Stop-ProcessTree -Process $proc
            $proc.WaitForExit(5000) | Out-Null
        }

        $stdoutResult = Get-TaskTextBeforeDeadline -Task $stdoutTask -DeadlineUtc $deadline
        $stderrResult = Get-TaskTextBeforeDeadline -Task $stderrTask -DeadlineUtc $deadline
        if (-not $stdoutResult.Completed -or -not $stderrResult.Completed) {
            $timedOut = $true
            if (-not $timeoutReason) { $timeoutReason = "outputDrainDeadline" }
            Stop-ProcessTree -Process $proc
        }

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
            TimeoutReason = $timeoutReason
            StartedAtUtc = $startedAtUtc.ToString("o")
            EndedAtUtc = [DateTime]::UtcNow.ToString("o")
            LastProgressUtc = $lastProgressUtc.ToString("o")
        }
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# Offline snapshot replay of the MCP read seam.
#
# Every repository read in this toolkit funnels through Send-AgentMcpRequest,
# so a snapshot served THERE drives the entire stack above it - transport,
# convention packs, facts, model passes, verification, gates and previews -
# without changing a line of it, and without the tool response shapes those
# layers validate differing by a byte from a live run.
#
# The snapshot is operator-supplied local input, so it is treated as hostile:
# named as a single child of an explicit replay root, canonicalized, refused
# if any component is a reparse point, hashed at load, held in memory so
# nothing on disk can change under it, and re-hashed at every serve. A
# resource that was not recorded is a failure, never a reason to reach the
# network.
# ---------------------------------------------------------------------------

# Code-defined, not manifest-defined: a bound a snapshot can raise is not a bound.
$script:AgentReplaySchemaVersions = @(1, 2)
$script:AgentReplayKind = "agent-replay-snapshot"
$script:AgentReplayMaxResources = 4096
$script:AgentReplayMaxPayloadBytes = 25165824
$script:AgentReplayMaxTotalPayloadBytes = 67108864
$script:AgentReplayMaxManifestBytes = 8388608
$script:AgentReplayMaxSourceTransportBytes = 16777216
$script:AgentReplaySnapshotNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z'
$script:AgentReplayPayloadSegmentPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[A-Za-z0-9_-]\z|^[A-Za-z0-9]\z'
$script:AgentReplayHexPattern = '^[0-9a-f]{64}\z'
# Seal kinds a manifest classification may declare. A classification only ever
# WITHDRAWS promotability, so every kind here is non-promotable by definition;
# the list exists so an unknown label is refused rather than honoured blindly.
$script:AgentReplayNonPromotableSealKinds = @("offlineCorpusSeal")
# Reference-identity seal, not a string: a constant that a hand-built hashtable
# can carry would let any in-process caller present itself as a loaded snapshot
# and skip every check in New-AgentReplaySnapshot. Same pattern as the
# reviewer's delivery-authorization seal.
$script:AgentReplaySnapshotSeal = [object]::new()
# A code-defined CEILING of the exact {tool, action} pairs the wrappers in this
# toolkit issue as reads - not a blocklist of writes. A tool or action this
# table does not name cannot be recorded in a snapshot and cannot be served
# from one, so a new write action added upstream is refused by default rather
# than admitted until someone notices.
$script:AgentReplayReadCeiling = [System.Collections.Generic.Dictionary[string, string[]]]::new([StringComparer]::Ordinal)
$script:AgentReplayReadCeiling.Add("repo_pull_request", @("get", "get_changes", "list"))
$script:AgentReplayReadCeiling.Add("repo_pull_request_thread", @("list"))
$script:AgentReplayReadCeiling.Add("repo_file", @("get_content"))
$script:AgentReplayReadCeiling.Add("repo_branch", @("get"))
$script:AgentReplayReadCeiling.Add("repo_repository", @("get", "list"))

function ConvertTo-AgentReplayJsonString {
    <#
        Explicit JSON string escaping. Delegating this to ConvertTo-Json would
        make every lookup key and the manifest digest a function of the host
        PowerShell build's serializer choices; a snapshot has to survive that.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $builder = [System.Text.StringBuilder]::new($Value.Length + 2)
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        switch ($character) {
            '"' { [void]$builder.Append('\"'); continue }
            '\' { [void]$builder.Append('\\'); continue }
            "`b" { [void]$builder.Append('\b'); continue }
            "`f" { [void]$builder.Append('\f'); continue }
            "`n" { [void]$builder.Append('\n'); continue }
            "`r" { [void]$builder.Append('\r'); continue }
            "`t" { [void]$builder.Append('\t'); continue }
            default {
                if ($code -lt 32 -or $code -eq 127) { [void]$builder.AppendFormat('\u{0:x4}', $code) }
                else { [void]$builder.Append($character) }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-AgentReplaySortedNames {
    <#
        ORDINAL ordering. Sort-Object is a culture comparison: 'aa','Aa','ab'
        orders differently under da-DK than under en-US, which would make both
        the lookup key and the manifest digest depend on the locale of the host
        that computed them. A snapshot captured on one machine has to load on
        another.
    #>
    param([string[]]$Names)
    $sorted = [string[]]@($Names)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return , $sorted
}

function ConvertTo-AgentReplayCanonicalJson {
    <#
        Deterministic JSON rendering used for BOTH the resource lookup key and
        the manifest digest. Object keys are sorted ordinally, so key order can
        never change a key or a digest, and dictionaries are rendered as objects
        rather than as the DictionaryEntry sequence a generic enumerable walk
        would produce.
    #>
    param($Value, [int]$Depth = 0)
    if ($Depth -gt 24) { throw "Replay payload exceeded the maximum canonical depth." }
    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }
    if ($Value -is [string]) { return (ConvertTo-AgentReplayJsonString -Value $Value) }
    if ($Value -is [int] -or $Value -is [long]) { return [Convert]::ToString([long]$Value, [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [double] -or $Value -is [decimal]) {
        # A non-integral number in a lookup key or a digest would make the key
        # depend on round-tripping; refuse rather than render one ambiguously.
        throw "Replay canonical JSON does not accept non-integral numbers."
    }
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) {
        # PowerShell's JSON reader turns extended-format ISO-8601 strings into
        # DateTime objects. Rendering one here would make the digest depend on
        # a formatting choice the manifest never stated, so it is refused: a
        # timestamp that must survive a snapshot is written in the basic form
        # this schema requires, which stays a string on both sides.
        throw "Replay canonical JSON does not accept date values; write timestamps in the basic yyyyMMddTHHmmssZ form."
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $names = Get-AgentReplaySortedNames -Names @($Value.Keys | ForEach-Object { [string]$_ })
        $parts = @($names | ForEach-Object {
                (ConvertTo-AgentReplayJsonString -Value $_) + ":" +
                (ConvertTo-AgentReplayCanonicalJson -Value $Value[$_] -Depth ($Depth + 1))
            })
        return "{" + ($parts -join ",") + "}"
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = Get-AgentReplaySortedNames -Names @($Value.PSObject.Properties.Name)
        $parts = @($names | ForEach-Object {
                (ConvertTo-AgentReplayJsonString -Value $_) + ":" +
                (ConvertTo-AgentReplayCanonicalJson -Value $Value.PSObject.Properties[$_].Value -Depth ($Depth + 1))
            })
        return "{" + ($parts -join ",") + "}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($item in $Value) { $parts += (ConvertTo-AgentReplayCanonicalJson -Value $item -Depth ($Depth + 1)) }
        return "[" + ($parts -join ",") + "]"
    }
    throw "Replay canonical JSON encountered an unsupported type."
}

function Get-AgentReplayTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = ([System.Text.UTF8Encoding]::new($false, $true)).GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-AgentReplayBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-AgentReplayRequestKey {
    <#
        The identity of one recorded read: the tool name and the EXACT argument
        set the wrapper asked with. Two calls that differ in any argument are
        two different resources, so a snapshot can never answer a question it
        was not asked at capture time.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Arguments
    )
    $canonical = ConvertTo-AgentReplayCanonicalJson -Value ([ordered]@{ arguments = $Arguments; name = $Name })
    return @{ Canonical = $canonical; Key = (Get-AgentReplayTextSha256 -Text $canonical) }
}

function Test-AgentReplayToolPermitted {
    <#
        Fail-closed read CEILING. Applied when a snapshot is LOADED (so a
        recorded write cannot sit in a snapshot at all) and again when a call is
        SERVED (so no code path can ask replay to answer a write). A tool the
        ceiling does not name, or an action it does not name for that tool, is
        refused - including a call that carries no action at all.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Arguments
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return @{ Permitted = $false; Reason = "an unnamed tool" } }
    if (-not $script:AgentReplayReadCeiling.ContainsKey($Name)) {
        return @{ Permitted = $false; Reason = "'$Name' is not in the replay read ceiling" }
    }
    $action = $null
    $actionSeen = $false
    if ($Arguments -is [System.Collections.IDictionary]) {
        foreach ($key in @($Arguments.Keys)) {
            if ([string]$key -ceq "action") { $action = $Arguments[$key]; $actionSeen = $true }
        }
    }
    elseif ($Arguments -is [System.Management.Automation.PSCustomObject] -and $Arguments.PSObject.Properties["action"]) {
        $action = $Arguments.PSObject.Properties["action"].Value
        $actionSeen = $true
    }
    if (-not $actionSeen) {
        return @{ Permitted = $false; Reason = "'$Name' was asked without an action" }
    }
    if ($action -isnot [string] -or $script:AgentReplayReadCeiling[$Name] -cnotcontains [string]$action) {
        return @{ Permitted = $false; Reason = "'$Name' was asked for an action outside the replay read ceiling" }
    }
    return @{ Permitted = $true; Reason = "" }
}

function Assert-AgentReplayPathSafe {
    <#
        Windows-shaped path defence. A snapshot is operator input, and the
        interesting attack here is not "../.." in the manifest - it is a
        junction or symlink that makes a name inside the replay root resolve to
        bytes outside it. Hard links are deliberately NOT chased: a hard link
        can only ever supply the exact bytes the manifest already pins by
        SHA-256, so aliasing buys nothing that content pinning does not already
        cover.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Within,
        [Parameter(Mandatory)][ValidateSet("Directory", "File")][string]$Kind
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($Kind -eq "Directory" -and -not $item.PSIsContainer) { throw "Replay path '$Path' is not a directory." }
    if ($Kind -eq "File" -and $item.PSIsContainer) { throw "Replay path '$Path' is not a file." }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
        throw "Replay path '$Path' is a reparse point; a replay snapshot may not redirect outside its own root."
    }
    if ($item.PSObject.Properties["LinkType"] -and $item.LinkType) {
        throw "Replay path '$Path' is a $($item.LinkType); a replay snapshot may not alias other content."
    }
    # Resolve through the filesystem's own casing/short-name normalization, then
    # confirm the resolved name is still strictly inside the boundary. Comparing
    # the manifest string alone would accept an 8.3 short name or a name that
    # only becomes an escape after resolution.
    $resolved = [System.IO.Path]::GetFullPath($item.FullName)
    $boundary = [System.IO.Path]::GetFullPath($Within).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Replay path '$Path' resolved outside the replay boundary '$Within'."
    }
    return $resolved
}

function Get-AgentReplayManifestField {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet("string", "sha256", "int", "bool", "object", "array")][string]$Type,
        [long]$Min = 0,
        [long]$Max = 2147483647,
        [string]$Pattern
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Replay manifest is missing required field '$Name'." }
    $value = $property.Value
    switch ($Type) {
        "string" {
            if ($value -isnot [string]) { throw "Replay manifest field '$Name' must be a string." }
            if ($Pattern -and [string]$value -cnotmatch $Pattern) { throw "Replay manifest field '$Name' does not match its required shape." }
            return [string]$value
        }
        "sha256" {
            if ($value -isnot [string] -or [string]$value -cnotmatch $script:AgentReplayHexPattern) {
                throw "Replay manifest field '$Name' must be a lowercase SHA-256 hex digest."
            }
            return [string]$value
        }
        "int" {
            if (-not (Test-StrictJsonInt -Value $value -Min $Min -Max $Max)) {
                throw "Replay manifest field '$Name' must be an integer in [$Min,$Max]."
            }
            return [long]$value
        }
        "bool" {
            if ($value -isnot [bool]) { throw "Replay manifest field '$Name' must be a boolean." }
            return [bool]$value
        }
        "object" {
            if ($value -isnot [System.Management.Automation.PSCustomObject]) { throw "Replay manifest field '$Name' must be an object." }
            return $value
        }
        "array" {
            if ($value -isnot [System.Object[]]) { throw "Replay manifest field '$Name' must be an array." }
            return @($value)
        }
    }
}

function Assert-AgentReplayExactKeys {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Where
    )
    $actual = @($Object.PSObject.Properties.Name)
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($unexpected.Count -gt 0) { throw "$Where carries unexpected field(s): $($unexpected -join ', ')." }
    $missing = @($Expected | Where-Object { -not $Object.PSObject.Properties[$_] })
    if ($missing.Count -gt 0) { throw "$Where is missing field(s): $($missing -join ', ')." }
}

function New-AgentReplaySnapshot {
    <#
        Loads and seals one replay snapshot. Every payload is read into memory
        here: a snapshot verified on disk and re-read later is a snapshot that
        can change between the check and the use, and holding the bytes removes
        that window entirely. Returns a hashtable the MCP session layer serves
        from; it carries a fresh per-run nonce so two replays of the same
        snapshot are distinguishable, and a domain-separated seal so a replay
        artifact can be recognized as one wherever it surfaces.
    #>
    param(
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$SnapshotName,
        [string]$ExpectedManifestDigest
    )
    if ($SnapshotName -cnotmatch $script:AgentReplaySnapshotNamePattern) {
        throw "Replay snapshot name '$SnapshotName' must be a single path-free name of at most 64 characters."
    }
    if (-not (Test-Path -LiteralPath $ReplayRoot -PathType Container)) {
        throw "Replay root '$ReplayRoot' does not exist."
    }
    $rootFull = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $ReplayRoot -Force -ErrorAction Stop).FullName)
    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
        throw "Replay root '$rootFull' is a reparse point."
    }
    $snapshotPath = Join-Path $rootFull $SnapshotName
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Container)) {
        throw "Replay snapshot '$SnapshotName' does not exist under '$rootFull'."
    }
    $snapshotFull = Assert-AgentReplayPathSafe -Path $snapshotPath -Within $rootFull -Kind Directory

    $manifestPath = Join-Path $snapshotFull "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Replay snapshot '$SnapshotName' has no manifest.json."
    }
    [void](Assert-AgentReplayPathSafe -Path $manifestPath -Within $snapshotFull -Kind File)
    $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    if ($manifestBytes.Length -lt 2 -or $manifestBytes.Length -gt $script:AgentReplayMaxManifestBytes) {
        throw "Replay manifest is $($manifestBytes.Length) bytes; expected 2..$script:AgentReplayMaxManifestBytes."
    }
    $manifestText = ([System.Text.UTF8Encoding]::new($false, $true)).GetString($manifestBytes)
    try { $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Replay manifest is not valid JSON." }
    if ($manifest -isnot [System.Management.Automation.PSCustomObject]) { throw "Replay manifest must be a JSON object." }

    $schemaVersion = Get-AgentReplayManifestField -Object $manifest -Name "schemaVersion" -Type int -Min 1 -Max 2
    $manifestKeys = @(
        "schemaVersion", "kind", "snapshotId", "capturedUtc", "provider",
        "binding", "bindings", "resources", "manifestDigest"
    )
    if ($schemaVersion -eq 2) { $manifestKeys += "sourceTransport" }
    # `classification` is the ONE optional manifest key. It is optional because
    # every snapshot sealed before it existed has to keep loading and keep its
    # digest; it is a manifest key rather than a free-standing sidecar because a
    # label that is not covered by the digest is a label anyone can delete. A
    # snapshot that omits it is an ordinary promotable snapshot, which is what
    # schema v1 and pre-existing v2 snapshots are.
    $hasClassification = [bool]$manifest.PSObject.Properties["classification"]
    if ($hasClassification) {
        if ($schemaVersion -ne 2) {
            throw "Replay manifest carries a classification but declares schema version $schemaVersion; classification is a schema-v2 field."
        }
        $manifestKeys += "classification"
    }
    Assert-AgentReplayExactKeys -Object $manifest -Where "Replay manifest" -Expected $manifestKeys
    if ($script:AgentReplaySchemaVersions -notcontains $schemaVersion) {
        throw "Replay manifest declares schema version $schemaVersion; this build reads versions $($script:AgentReplaySchemaVersions -join ', ')."
    }
    $kind = Get-AgentReplayManifestField -Object $manifest -Name "kind" -Type string
    if ($kind -cne $script:AgentReplayKind) { throw "Replay manifest kind '$kind' is not '$script:AgentReplayKind'." }
    $snapshotId = Get-AgentReplayManifestField -Object $manifest -Name "snapshotId" -Type string -Pattern $script:AgentReplaySnapshotNamePattern
    if ($snapshotId -cne $SnapshotName) {
        throw "Replay manifest declares snapshotId '$snapshotId' but was loaded as '$SnapshotName'."
    }
    $capturedUtc = Get-AgentReplayManifestField -Object $manifest -Name "capturedUtc" -Type string -Pattern '^\d{8}T\d{6}Z\z'
    $provider = Get-AgentReplayManifestField -Object $manifest -Name "provider" -Type string -Pattern '^[a-z][a-z0-9-]{0,31}\z'

    $binding = Get-AgentReplayManifestField -Object $manifest -Name "binding" -Type object
    $bindingKeys = @(
        "organization", "project", "repositoryId", "pullRequestId",
        "sourceCommit", "targetCommit", "changeSetSha256"
    )
    if ($schemaVersion -eq 2) { $bindingKeys += @("iterationId", "commonCommit") }
    Assert-AgentReplayExactKeys -Object $binding -Where "Replay manifest binding" -Expected $bindingKeys
    $bindingRecord = [ordered]@{
        Organization    = Get-AgentReplayManifestField -Object $binding -Name "organization" -Type string -Pattern '^[^\s]{1,128}\z'
        Project         = Get-AgentReplayManifestField -Object $binding -Name "project" -Type string -Pattern '^[^\s]{1,128}\z'
        RepositoryId    = Get-AgentReplayManifestField -Object $binding -Name "repositoryId" -Type string -Pattern '^[^\s]{1,128}\z'
        PullRequestId   = Get-AgentReplayManifestField -Object $binding -Name "pullRequestId" -Type int -Min 1 -Max 2147483647
        SourceCommit    = Get-AgentReplayManifestField -Object $binding -Name "sourceCommit" -Type string -Pattern '^[0-9a-f]{40}\z'
        TargetCommit    = Get-AgentReplayManifestField -Object $binding -Name "targetCommit" -Type string -Pattern '^[0-9a-f]{40}\z'
        ChangeSetSha256 = Get-AgentReplayManifestField -Object $binding -Name "changeSetSha256" -Type sha256
    }
    if ($schemaVersion -eq 2) {
        $bindingRecord["IterationId"] = Get-AgentReplayManifestField -Object $binding -Name "iterationId" `
            -Type int -Min 1 -Max 2147483647
        $bindingRecord["CommonCommit"] = Get-AgentReplayManifestField -Object $binding -Name "commonCommit" `
            -Type string -Pattern '^[0-9a-f]{40}\z'
    }

    $bindings = Get-AgentReplayManifestField -Object $manifest -Name "bindings" -Type object
    Assert-AgentReplayExactKeys -Object $bindings -Where "Replay manifest bindings" -Expected @(
        "configSha256", "scriptSha256", "promptSha256", "models"
    )
    $models = @(Get-AgentReplayManifestField -Object $bindings -Name "models" -Type array)
    if ($models.Count -gt 8) { throw "Replay manifest binds more than 8 models." }
    foreach ($model in $models) {
        if ($model -isnot [string] -or [string]$model -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            throw "Replay manifest model binding is not a plain model name."
        }
    }
    $bindingsRecord = [ordered]@{
        ConfigSha256 = Get-AgentReplayManifestField -Object $bindings -Name "configSha256" -Type sha256
        ScriptSha256 = Get-AgentReplayManifestField -Object $bindings -Name "scriptSha256" -Type sha256
        PromptSha256 = Get-AgentReplayManifestField -Object $bindings -Name "promptSha256" -Type sha256
        Models       = @($models | ForEach-Object { [string]$_ })
    }

    $resources = @(Get-AgentReplayManifestField -Object $manifest -Name "resources" -Type array)
    if ($resources.Count -lt 1 -or $resources.Count -gt $script:AgentReplayMaxResources) {
        throw "Replay manifest declares $($resources.Count) resource(s); expected 1..$script:AgentReplayMaxResources."
    }
    $recordedDigest = Get-AgentReplayManifestField -Object $manifest -Name "manifestDigest" -Type sha256

    $served = @{}
    $totalBytes = [long]0
    $resourceSummaries = [System.Collections.Generic.List[object]]::new()
    $sourceTransportRecord = $null
    $sourceTransportDigestRecord = $null
    if ($schemaVersion -eq 2) {
        $sourceTransport = Get-AgentReplayManifestField -Object $manifest -Name "sourceTransport" -Type object
        Assert-AgentReplayExactKeys -Object $sourceTransport -Where "Replay manifest sourceTransport" -Expected @(
            "mode", "artifactFile", "artifactSha256", "artifactByteLength"
        )
        $sourceMode = Get-AgentReplayManifestField -Object $sourceTransport -Name "mode" -Type string `
            -Pattern '^(mcpFlat|azureDevOpsCliFallback|legacyMcp)$'
        $artifactRelative = Get-AgentReplayManifestField -Object $sourceTransport -Name "artifactFile" -Type string
        if ($artifactRelative.Length -lt 1 -or $artifactRelative.Length -gt 512) {
            throw "Replay source-transport artifactFile must be 1..512 characters."
        }
        $artifactSegments = @($artifactRelative -split '/')
        foreach ($segment in $artifactSegments) {
            if ($segment -cnotmatch $script:AgentReplayPayloadSegmentPattern) {
                throw "Replay source-transport artifactFile '$artifactRelative' is not a plain relative path inside the snapshot."
            }
        }
        $artifactPath = $snapshotFull
        for ($segmentIndex = 0; $segmentIndex -lt $artifactSegments.Count; $segmentIndex++) {
            $artifactPath = Join-Path $artifactPath $artifactSegments[$segmentIndex]
            $segmentKind = if ($segmentIndex -eq ($artifactSegments.Count - 1)) { "File" } else { "Directory" }
            [void](Assert-AgentReplayPathSafe -Path $artifactPath -Within $snapshotFull -Kind $segmentKind)
        }
        $artifactLength = Get-AgentReplayManifestField -Object $sourceTransport -Name "artifactByteLength" `
            -Type int -Min 2 -Max $script:AgentReplayMaxSourceTransportBytes
        $artifactSha = Get-AgentReplayManifestField -Object $sourceTransport -Name "artifactSha256" -Type sha256
        $artifactBytes = [IO.File]::ReadAllBytes($artifactPath)
        if ($artifactBytes.Length -ne $artifactLength) {
            throw "Replay source-transport artifact '$artifactRelative' is $($artifactBytes.Length) bytes; the manifest records $artifactLength."
        }
        if ((Get-AgentReplayBytesSha256 -Bytes $artifactBytes) -cne $artifactSha) {
            throw "Replay source-transport artifact '$artifactRelative' does not match its recorded SHA-256."
        }
        $totalBytes += $artifactBytes.Length
        if ($totalBytes -gt $script:AgentReplayMaxTotalPayloadBytes) {
            throw "Replay snapshot '$SnapshotName' carries more than $script:AgentReplayMaxTotalPayloadBytes payload bytes."
        }
        $sourceTransportRecord = @{
            Mode = $sourceMode
            ArtifactFile = $artifactRelative
            ArtifactSha256 = $artifactSha
            ArtifactBytes = $artifactBytes
        }
        $sourceTransportDigestRecord = [ordered]@{
            mode = $sourceMode
            artifactFile = $artifactRelative
            artifactSha256 = $artifactSha
            artifactByteLength = [long]$artifactBytes.Length
        }
    }

    # -- classification, and the sidecar it binds ---------------------------
    # Default: an ordinary, promotable snapshot. Stated explicitly rather than
    # left null, because a consumer that has to test for absence before it can
    # tell whether something is promotable will eventually forget to.
    $classificationRecord = @{
        SealKind      = "standard"
        NonPromotable = $false
        SidecarFile   = ""
        SidecarSha256 = ""
        Sidecar       = $null
    }
    $classificationDigestRecord = $null
    if ($hasClassification) {
        $classification = Get-AgentReplayManifestField -Object $manifest -Name "classification" -Type object
        Assert-AgentReplayExactKeys -Object $classification -Where "Replay manifest classification" -Expected @(
            "sealKind", "nonPromotable", "sidecarFile", "sidecarSha256"
        )
        $sealKind = Get-AgentReplayManifestField -Object $classification -Name "sealKind" -Type string `
            -Pattern '^[a-z][A-Za-z0-9]{0,31}\z'
        if ($script:AgentReplayNonPromotableSealKinds -cnotcontains $sealKind) {
            throw "Replay manifest classification declares sealKind '$sealKind', which this build does not recognize."
        }
        $nonPromotable = Get-AgentReplayManifestField -Object $classification -Name "nonPromotable" -Type bool
        if (-not $nonPromotable) {
            # A classification block exists ONLY to withdraw promotability. If it
            # could also assert promotability it would be a way to launder a
            # sealed snapshot into a promotable one by editing four fields, and
            # the whole point is that this label can never be talked out of.
            throw "Replay manifest classification declares nonPromotable = false; a classification may only withdraw promotability, never grant it."
        }
        $sidecarRelative = Get-AgentReplayManifestField -Object $classification -Name "sidecarFile" -Type string
        if ($sidecarRelative.Length -lt 1 -or $sidecarRelative.Length -gt 512) {
            throw "Replay classification sidecarFile must be 1..512 characters."
        }
        $sidecarSegments = @($sidecarRelative -split '/')
        foreach ($segment in $sidecarSegments) {
            if ($segment -cnotmatch $script:AgentReplayPayloadSegmentPattern) {
                throw "Replay classification sidecarFile '$sidecarRelative' is not a plain relative path inside the snapshot."
            }
        }
        $sidecarSha = Get-AgentReplayManifestField -Object $classification -Name "sidecarSha256" -Type sha256
        $sidecarPath = $snapshotFull
        for ($segmentIndex = 0; $segmentIndex -lt $sidecarSegments.Count; $segmentIndex++) {
            $sidecarPath = Join-Path $sidecarPath $sidecarSegments[$segmentIndex]
            $segmentKind = if ($segmentIndex -eq ($sidecarSegments.Count - 1)) { "File" } else { "Directory" }
            if (-not (Test-Path -LiteralPath $sidecarPath)) {
                # Deleting the sidecar is the obvious way to try to shed the
                # label, so it fails the LOAD rather than merely being noticed.
                throw "Replay snapshot '$SnapshotName' is classified '$sealKind' but its sidecar '$sidecarRelative' is missing."
            }
            [void](Assert-AgentReplayPathSafe -Path $sidecarPath -Within $snapshotFull -Kind $segmentKind)
        }
        $sidecarBytes = [System.IO.File]::ReadAllBytes($sidecarPath)
        if ($sidecarBytes.Length -lt 2 -or $sidecarBytes.Length -gt $script:AgentReplayMaxManifestBytes) {
            throw "Replay classification sidecar '$sidecarRelative' is $($sidecarBytes.Length) bytes; expected 2..$script:AgentReplayMaxManifestBytes."
        }
        if ((Get-AgentReplayBytesSha256 -Bytes $sidecarBytes) -cne $sidecarSha) {
            throw "Replay classification sidecar '$sidecarRelative' does not match its recorded SHA-256."
        }
        $sidecarText = ([System.Text.UTF8Encoding]::new($false, $true)).GetString($sidecarBytes)
        try { $sidecar = $sidecarText | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Replay classification sidecar '$sidecarRelative' is not valid JSON." }
        if ($sidecar -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Replay classification sidecar '$sidecarRelative' must be a JSON object."
        }
        # The sidecar has to agree with the manifest about what it is about. The
        # binding runs manifest -> sidecar only: the manifest pins the sidecar's
        # hash and the digest pins the manifest, so a sidecar that also carried
        # the manifest digest would close a cycle neither side could compute.
        foreach ($pair in @(
                @("snapshotId", $snapshotId),
                @("sealKind", $sealKind))) {
            $name = [string]$pair[0]
            if (-not $sidecar.PSObject.Properties[$name]) {
                throw "Replay classification sidecar '$sidecarRelative' omits '$name'."
            }
            if ([string]$sidecar.PSObject.Properties[$name].Value -cne [string]$pair[1]) {
                throw "Replay classification sidecar '$sidecarRelative' disagrees with the manifest about '$name'."
            }
        }
        if (-not $sidecar.PSObject.Properties["nonPromotable"] -or -not [bool]$sidecar.nonPromotable) {
            throw "Replay classification sidecar '$sidecarRelative' does not record nonPromotable = true."
        }
        $totalBytes += $sidecarBytes.Length
        if ($totalBytes -gt $script:AgentReplayMaxTotalPayloadBytes) {
            throw "Replay snapshot '$SnapshotName' carries more than $script:AgentReplayMaxTotalPayloadBytes payload bytes."
        }
        $classificationRecord = @{
            SealKind      = $sealKind
            NonPromotable = $true
            SidecarFile   = $sidecarRelative
            SidecarSha256 = $sidecarSha
            Sidecar       = $sidecar
        }
        $classificationDigestRecord = [ordered]@{
            sealKind      = $sealKind
            nonPromotable = $true
            sidecarFile   = $sidecarRelative
            sidecarSha256 = $sidecarSha
        }
    }

    foreach ($resource in $resources) {
        if ($resource -isnot [System.Management.Automation.PSCustomObject]) { throw "Replay manifest resource must be an object." }
        Assert-AgentReplayExactKeys -Object $resource -Where "Replay manifest resource" -Expected @(
            "tool", "arguments", "requestSha256", "payloadFile", "payloadSha256", "payloadByteLength"
        )
        $tool = Get-AgentReplayManifestField -Object $resource -Name "tool" -Type string -Pattern '^[a-z][a-z0-9_]{0,63}$'
        $arguments = Get-AgentReplayManifestField -Object $resource -Name "arguments" -Type object
        $permitted = Test-AgentReplayToolPermitted -Name $tool -Arguments $arguments
        if (-not $permitted.Permitted) {
            throw "Replay snapshot '$SnapshotName' records $($permitted.Reason); a replay snapshot may only carry reads."
        }
        $requestKey = Get-AgentReplayRequestKey -Name $tool -Arguments $arguments
        $recordedRequestSha = Get-AgentReplayManifestField -Object $resource -Name "requestSha256" -Type sha256
        if ($requestKey.Key -cne $recordedRequestSha) {
            throw "Replay resource for '$tool' records a requestSha256 that does not match its own arguments."
        }
        if ($served.ContainsKey($requestKey.Key)) {
            throw "Replay snapshot '$SnapshotName' records the same '$tool' request twice; a snapshot must answer each request one way."
        }

        $payloadRelative = Get-AgentReplayManifestField -Object $resource -Name "payloadFile" -Type string
        if ($payloadRelative.Length -lt 1 -or $payloadRelative.Length -gt 512) {
            throw "Replay resource payloadFile must be 1..512 characters."
        }
        $segments = @($payloadRelative -split '/')
        foreach ($segment in $segments) {
            if ($segment -cnotmatch $script:AgentReplayPayloadSegmentPattern) {
                throw "Replay resource payloadFile '$payloadRelative' is not a plain relative path inside the snapshot."
            }
        }
        $payloadPath = $snapshotFull
        for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
            $payloadPath = Join-Path $payloadPath $segments[$segmentIndex]
            # By index, not by value: a payload at "a/b/a" would otherwise have
            # its first directory checked as a file because it happens to share
            # the leaf's name.
            $segmentKind = if ($segmentIndex -eq ($segments.Count - 1)) { "File" } else { "Directory" }
            [void](Assert-AgentReplayPathSafe -Path $payloadPath -Within $snapshotFull -Kind $segmentKind)
        }

        $expectedBytes = Get-AgentReplayManifestField -Object $resource -Name "payloadByteLength" -Type int -Min 2 -Max $script:AgentReplayMaxPayloadBytes
        $expectedSha = Get-AgentReplayManifestField -Object $resource -Name "payloadSha256" -Type sha256
        # The safety check above and this read are two operations on one name,
        # so the name can in principle be swapped between them. That window is
        # harmless rather than unclosed: whatever the read returns is hashed
        # against the manifest immediately below, so a swapped file fails the
        # load. The worst a race can do here is refuse a snapshot.
        $payloadBytes = [System.IO.File]::ReadAllBytes($payloadPath)
        if ($payloadBytes.Length -ne $expectedBytes) {
            throw "Replay payload '$payloadRelative' is $($payloadBytes.Length) bytes; the manifest records $expectedBytes."
        }
        $actualSha = Get-AgentReplayBytesSha256 -Bytes $payloadBytes
        if ($actualSha -cne $expectedSha) { throw "Replay payload '$payloadRelative' does not match its recorded SHA-256." }
        $totalBytes += $payloadBytes.Length
        if ($totalBytes -gt $script:AgentReplayMaxTotalPayloadBytes) {
            throw "Replay snapshot '$SnapshotName' carries more than $script:AgentReplayMaxTotalPayloadBytes payload bytes."
        }

        # Reject a recorded failure at load, not at serve: a snapshot that
        # cannot answer is a broken snapshot, and finding that out halfway
        # through a replay would leave a half-run to interpret.
        $payloadText = ([System.Text.UTF8Encoding]::new($false, $true)).GetString($payloadBytes)
        try { $envelope = $payloadText | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Replay payload '$payloadRelative' is not valid JSON." }
        if ($envelope -isnot [System.Management.Automation.PSCustomObject] -or
            -not $envelope.PSObject.Properties["jsonrpc"] -or [string]$envelope.jsonrpc -cne "2.0" -or
            -not $envelope.PSObject.Properties["result"] -or $envelope.PSObject.Properties["error"]) {
            throw "Replay payload '$payloadRelative' is not a successful JSON-RPC response envelope."
        }
        # A well-formed envelope is not the same as a readable one. Every reader
        # in this toolkit consumes a tool result through Invoke-AgentMcpTool,
        # which requires the MCP content shape; a raw REST body wrapped in a
        # JSON-RPC envelope loads, hashes and binds perfectly and then fails at
        # the read that needs it - after a run has already started. Checking it
        # here means a snapshot that cannot answer is refused whole, at load,
        # for EVERY recorded read rather than only the first one a run happens
        # to reach.
        if (-not (Test-AgentMcpToolResultShape -Result $envelope.result)) {
            throw ("Replay payload '$payloadRelative' is not an MCP tool result: it carries no content array " +
                "with text or an embedded resource, so no reader could consume it. Record the response the MCP " +
                "server returns, not the REST body it wraps.")
        }

        $served[$requestKey.Key] = @{
            Tool          = $tool
            PayloadFile   = $payloadRelative
            PayloadBytes  = $payloadBytes
            PayloadSha256 = $expectedSha
        }
        [void]$resourceSummaries.Add([ordered]@{
                tool              = $tool
                requestSha256     = $requestKey.Key
                payloadFile       = $payloadRelative
                payloadSha256     = $expectedSha
                payloadByteLength = [long]$payloadBytes.Length
                arguments         = $arguments
            })
    }

    # The digest covers everything the manifest asserts EXCEPT the digest field
    # itself, so editing any binding, argument, payload hash or ordering changes
    # it. Payload bytes are covered transitively through payloadSha256, each of
    # which was verified against the bytes just read. It is built from the
    # manifest's OWN field names so that a writer can compute the same value
    # without reproducing this function's internal record shapes.
    $digestInput = [ordered]@{
        schemaVersion = $schemaVersion
        kind          = $kind
        snapshotId    = $snapshotId
        capturedUtc   = $capturedUtc
        provider      = $provider
        binding       = [ordered]@{
            organization    = $bindingRecord.Organization
            project         = $bindingRecord.Project
            repositoryId    = $bindingRecord.RepositoryId
            pullRequestId   = $bindingRecord.PullRequestId
            sourceCommit    = $bindingRecord.SourceCommit
            targetCommit    = $bindingRecord.TargetCommit
            changeSetSha256 = $bindingRecord.ChangeSetSha256
        }
        bindings      = [ordered]@{
            configSha256 = $bindingsRecord.ConfigSha256
            scriptSha256 = $bindingsRecord.ScriptSha256
            promptSha256 = $bindingsRecord.PromptSha256
            models       = @($bindingsRecord.Models)
        }
        resources     = @($resourceSummaries.ToArray())
    }
    if ($schemaVersion -eq 2) {
        $digestInput.binding["iterationId"] = $bindingRecord.IterationId
        $digestInput.binding["commonCommit"] = $bindingRecord.CommonCommit
    }
    if ($schemaVersion -eq 2) { $digestInput["sourceTransport"] = $sourceTransportDigestRecord }
    # The classification is part of what the manifest ASSERTS, so it is part of
    # what the digest covers. Editing the sealKind, flipping nonPromotable,
    # repointing the sidecar or swapping the sidecar's bytes all change this
    # value, which is what makes the label survive an edit rather than merely
    # describe one. Absent classification contributes nothing, so every snapshot
    # sealed before this field existed keeps exactly the digest it had.
    if ($null -ne $classificationDigestRecord) { $digestInput["classification"] = $classificationDigestRecord }
    $computedDigest = Get-AgentReplayTextSha256 -Text (ConvertTo-AgentReplayCanonicalJson -Value $digestInput)
    if ($computedDigest -cne $recordedDigest) {
        # Deliberately not worded as tamper detection. This digest is unkeyed:
        # anyone who edits a snapshot can recompute it. What it does catch is a
        # manifest that no longer describes its own payloads - corruption, a
        # partial edit, or a recorder that disagrees with this reader. Binding a
        # replay to a snapshot an operator actually vouched for is the job of
        # -ExpectedManifestDigest, which is why the reviewer requires one.
        throw "Replay manifest digest does not match its own contents; the manifest and its payloads disagree."
    }
    if ($ExpectedManifestDigest -and $computedDigest -cne $ExpectedManifestDigest.ToLowerInvariant()) {
        throw "Replay manifest digest $computedDigest does not match the operator-supplied $ExpectedManifestDigest."
    }

    return @{
        SchemaVersion  = $schemaVersion
        SnapshotId     = $snapshotId
        SnapshotPath   = $snapshotFull
        ReplayRoot     = $rootFull
        CapturedUtc    = $capturedUtc
        Provider       = $provider
        Binding        = $bindingRecord
        Bindings       = $bindingsRecord
        ManifestDigest = $computedDigest
        ResourceCount  = $served.Count
        PayloadBytes   = $totalBytes
        ReplayNonce    = (New-AgentNonce)
        Seal           = $script:AgentReplaySnapshotSeal
        Served         = $served
        ServedKeys     = @($served.Keys)
        SourceTransport = $sourceTransportRecord
        Classification = $classificationRecord
    }
}

function Assert-AgentReplaySnapshotPromotable {
    <#
        The one gate every promotable flow calls before it treats a replayed
        result as something that can be published, promoted or counted as a
        qualification. A snapshot that carries a classification has withdrawn
        its own promotability permanently, and the withdrawal is covered by the
        manifest digest, so it cannot be shed by deleting a file.

        Deliberately a THROW rather than a boolean. A caller that has to
        remember to test the answer is a caller that can forget to.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [string]$Operation = "Promotion"
    )
    if ($Snapshot["Seal"] -isnot [object] -or -not [object]::ReferenceEquals($Snapshot["Seal"], $script:AgentReplaySnapshotSeal)) {
        throw "$Operation requires a snapshot produced by New-AgentReplaySnapshot."
    }
    $classification = $Snapshot["Classification"]
    if ($null -eq $classification) { return $true }
    if ([bool]$classification.NonPromotable) {
        throw ("$Operation refused: replay snapshot '$($Snapshot.SnapshotId)' is classified " +
            "'$($classification.SealKind)' and is permanently non-promotable. It was sealed offline from captured " +
            "material, contacted no live host, and cannot stand behind a published or promoted result.")
    }
    return $true
}

function Get-AgentReplayResponse {
    <#
        Answers one recorded read. Re-hashes the held bytes before parsing, so a
        snapshot object that was tampered with in memory is caught here too, and
        parses fresh on every call so no caller can mutate a shared object out
        from under a later one.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Arguments
    )
    $permitted = Test-AgentReplayToolPermitted -Name $Name -Arguments $Arguments
    if (-not $permitted.Permitted) {
        throw "Replay refused $($permitted.Reason): a replay never writes and never authorizes a write."
    }
    $requestKey = Get-AgentReplayRequestKey -Name $Name -Arguments $Arguments
    if (-not $Snapshot.Served.ContainsKey($requestKey.Key)) {
        # Naming the exact request is the difference between "this snapshot is
        # incomplete" and a day of guessing which argument differed. Bounded,
        # because the arguments are operator input like everything else here.
        $described = $requestKey.Canonical
        if ($described.Length -gt 512) { $described = $described.Substring(0, 512) + "..." }
        throw ("Replay snapshot '$($Snapshot.SnapshotId)' has no recorded response for '$Name' with these exact arguments; " +
            "a replay never falls through to a live read. Requested: $described")
    }
    $entry = $Snapshot.Served[$requestKey.Key]
    $actualSha = Get-AgentReplayBytesSha256 -Bytes $entry.PayloadBytes
    if ($actualSha -cne $entry.PayloadSha256) {
        throw "Replay payload '$($entry.PayloadFile)' changed after it was sealed."
    }
    $payloadText = ([System.Text.UTF8Encoding]::new($false, $true)).GetString($entry.PayloadBytes)
    $envelope = $payloadText | ConvertFrom-Json -ErrorAction Stop
    return $envelope.result
}

function Test-AgentReplaySnapshotHasResponse {
    <#
        A non-throwing availability probe over the same request key
        Get-AgentReplayResponse serves from. It exists so an offline planner can
        tell a source that was never captured (a reason to degrade a candidate,
        not to fall through to a live read) apart from a source that is present.
        It never returns payload bytes and never contacts anything: like the
        serve path it refuses a write tool outright, and otherwise answers only
        whether this exact tool-and-arguments read was recorded. Probing and
        then skipping keeps a replay from even issuing a request it knows the
        snapshot cannot answer.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Arguments
    )
    if ($Snapshot["Seal"] -isnot [object] -or -not [object]::ReferenceEquals($Snapshot["Seal"], $script:AgentReplaySnapshotSeal)) {
        throw "Replay availability probe requires a snapshot produced by New-AgentReplaySnapshot."
    }
    $permitted = Test-AgentReplayToolPermitted -Name $Name -Arguments $Arguments
    if (-not $permitted.Permitted) { return $false }
    $requestKey = Get-AgentReplayRequestKey -Name $Name -Arguments $Arguments
    return [bool]$Snapshot.Served.ContainsKey($requestKey.Key)
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
    if ($Session.ContainsKey("Replay") -and $null -ne $Session.Replay) {
        # A replay session has no process and no socket. Every branch below this
        # one is unreachable from here, which is the point: there is no code path
        # from a replay session to the network. -DeadlineUtc is deliberately not
        # consulted - a serve is a bounded in-memory hash and parse with nothing
        # to wait for, so honouring a deadline here would only ever be theatre.
        if ($Method -cne "tools/call") {
            throw "Replay session refuses JSON-RPC method '$Method'; a replay answers recorded tool reads only."
        }
        if (-not $Params.ContainsKey("name") -or -not $Params.ContainsKey("arguments")) {
            throw "Replay session received a tools/call without a name and arguments."
        }
        Add-AgentOfflineTelemetryEvent -Event "provider.replayServed" -Data @{
            method = $Method
            tool = [string]$Params["name"]
        }
        return (Get-AgentReplayResponse -Snapshot $Session.Replay -Name ([string]$Params["name"]) -Arguments $Params["arguments"])
    }
    if (-not $Session.Process) { throw "Agent MCP session is closed." }
    $Session.NextId = [long]$Session.NextId + 1
    $requestId = [long]$Session.NextId
    $request = [ordered]@{ jsonrpc = "2.0"; id = $requestId; method = $Method; params = $Params }
    $line = $request | ConvertTo-Json -Compress -Depth 20
    try {
        Add-AgentOfflineTelemetryEvent -Event "provider.liveWrite" -Data @{
            method = $Method
            childProcessId = [int]$Session.Process.Id
        }
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
    if ($Session.ContainsKey("Replay") -and $null -ne $Session.Replay) {
        throw "Replay session refuses JSON-RPC notification '$Method'; a replay answers recorded tool reads only."
    }
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
    if (-not $Session) { return }
    if ($Session.ContainsKey("Replay") -and $null -ne $Session.Replay) {
        # Dropping the snapshot reference ends the session; there was never a
        # process to stop. Serving after this point fails on the null check
        # in Send-AgentMcpRequest, exactly as a closed live session does.
        $Session.Replay = $null
        return
    }
    if (-not $Session.Process) { return }
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
        [string[]]$EnvironmentVariablesToRemove = @("AZURE_DEVOPS_EXT_PAT", "SYSTEM_ACCESSTOKEN"),
        [hashtable]$ReplaySnapshot
    )
    if ($ReplaySnapshot) {
        # Offline replay: no process is started, so -AgencyPath is never
        # executed and the child-environment scrubbing below has nothing to
        # scrub. The returned session carries the same Server/Organization the
        # caller asked for, because callers assert on those before using it.
        if (-not [object]::ReferenceEquals($ReplaySnapshot.Seal, $script:AgentReplaySnapshotSeal)) {
            throw "Replay session requires a snapshot produced by New-AgentReplaySnapshot."
        }
        # A snapshot captured against a different organization would answer
        # every question consistently and wrongly. Bind it here, at the one
        # place a session is created, rather than trusting each caller.
        if ($Organization -and [string]$ReplaySnapshot.Binding.Organization -cne $Organization) {
            throw "Replay snapshot '$($ReplaySnapshot.SnapshotId)' was captured against organization '$($ReplaySnapshot.Binding.Organization)', not '$Organization'."
        }
        Add-AgentOfflineTelemetryEvent -Event "provider.replaySessionOpened" -Data @{
            server = $Server
            snapshotId = [string]$ReplaySnapshot.SnapshotId
        }
        return @{
            Process        = $null
            NextId         = [long]0
            ReadTask       = $null
            ErrorDrainTask = $null
            TimeoutSeconds = $TimeoutSeconds
            Server         = $Server
            Organization   = $Organization
            Replay         = $ReplaySnapshot
        }
    }
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
    Add-AgentOfflineTelemetryEvent -Event "provider.liveProcessStarted" -Data @{
        executable = [string]$psi.FileName
        childProcessId = [int]$process.Id
        server = $Server
    }
    $session = @{
        Process        = $process
        NextId         = [long]0
        ReadTask       = $null
        ErrorDrainTask = $process.StandardError.ReadToEndAsync()
        TimeoutSeconds = $TimeoutSeconds
        Server         = $Server
        Organization   = $Organization
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

function Test-AgentMcpToolResultShape {
    <#
        True when a JSON-RPC `result` is something a reader could actually
        consume: the MCP tool-result shape, a content array whose first item
        carries text or an embedded resource. This is the load-time and
        seal-time mirror of what Invoke-AgentMcpTool requires at read time, so
        a recorded response that no reader could parse is refused while it is
        still being written down rather than in the middle of a run.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Result)
    if ($Result -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    if ($Result.PSObject.Properties["isError"] -and $Result.isError -eq $true) { return $false }
    $contentProperty = $Result.PSObject.Properties["content"]
    if ($null -eq $contentProperty) { return $false }
    $content = @($contentProperty.Value)
    if ($content.Count -lt 1 -or $content[0] -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $first = $content[0]
    $textTypeValid = (-not $first.PSObject.Properties["type"] -or [string]$first.type -ceq "text")
    if ($textTypeValid -and $first.PSObject.Properties["text"] -and
        $first.text -is [string] -and $first.text.Length -le 20MB) {
        return $true
    }
    if ($first.PSObject.Properties["resource"] -and
        $first.PSObject.Properties["type"] -and [string]$first.type -ceq "resource" -and
        $first.resource -is [System.Management.Automation.PSCustomObject]) {
        if ($content.Count -ne 1) { return $false }
        if (@($first.PSObject.Properties.Name | Where-Object { @("resource", "type") -cnotcontains $_ }).Count -gt 0) {
            return $false
        }
        $resource = $first.resource
        if (@("blob", "mimeType", "uri") | Where-Object { -not $resource.PSObject.Properties[$_] }) {
            return $false
        }
        if (@($resource.PSObject.Properties.Name | Where-Object {
                    @("blob", "mimeType", "uri") -cnotcontains $_
                }).Count -gt 0) {
            return $false
        }
        if ($resource.uri -isnot [string] -or [string]::IsNullOrWhiteSpace($resource.uri) -or
            $resource.uri.Length -gt 2048 -or
            $resource.mimeType -isnot [string] -or [string]::IsNullOrWhiteSpace($resource.mimeType) -or
            $resource.mimeType.Length -gt 128 -or
            $resource.blob -isnot [string] -or [string]::IsNullOrWhiteSpace($resource.blob)) {
            return $false
        }
        $blob = [string]$resource.blob
        if (($blob.Length % 4) -ne 0 -or $blob -notmatch '^[A-Za-z0-9+/]*={0,2}$') { return $false }
        try { $bytes = [Convert]::FromBase64String($blob) }
        catch { return $false }
        if ($bytes.Length -lt 1 -or $bytes.Length -gt 5MB -or
            [Convert]::ToBase64String($bytes) -cne $blob -or
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
            return $false
        }
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        catch { return $false }
        foreach ($character in $text.ToCharArray()) {
            $code = [int]$character
            if (($code -lt 32 -and $code -notin @(9, 10, 13)) -or $code -eq 127) {
                return $false
            }
        }
        return $true
    }
    return $false
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

function ConvertFrom-AgentMcpResourceContent {
        <#
            Converts one MCP embedded-resource content item into bounded UTF-8 text.
            This function never dereferences the resource URI. The caller supplies
            the exact URI and MIME allow-list expected from its wrapper-owned tool
            request; all other result shapes fail closed.
        #>
        param(
            [Parameter(Mandatory)]$ToolResult,
            [Parameter(Mandatory)][string]$ExpectedUri,
            [ValidateRange(1, 5242880)][int]$MaxBytes,
            [string[]]$AllowedMimeTypes = @("text/plain", "text/markdown")
        )
        if ($ToolResult -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Agent MCP resource response had an unexpected result shape."
        }
        if ($ToolResult.PSObject.Properties["isError"] -and $ToolResult.isError -eq $true) {
            throw "Agent MCP resource response reported failure."
        }
        if ($ExpectedUri.Length -gt 2048 -or [string]::IsNullOrWhiteSpace($ExpectedUri)) {
            throw "Agent MCP resource expected URI must be a non-empty string of at most 2048 characters."
        }
        $allowed = @($AllowedMimeTypes)
        if ($allowed.Count -eq 0 -or @($allowed | Where-Object {
                    $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_.Length -gt 128
                }).Count -gt 0) {
            throw "Agent MCP resource MIME allow-list must contain non-empty strings of at most 128 characters."
        }

        $contentProperty = $ToolResult.PSObject.Properties["content"]
        if (-not $contentProperty) { throw "Agent MCP resource response omitted content." }
        $content = @($contentProperty.Value)
        if ($content.Count -ne 1 -or $content[0] -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Agent MCP resource response must contain exactly one object."
        }
        $item = $content[0]
        if (-not $item.PSObject.Properties["type"] -or [string]$item.type -cne "resource" -or
            -not $item.PSObject.Properties["resource"] -or
            $item.resource -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Agent MCP resource response did not contain one embedded resource."
        }
        $unexpectedItemProperties = @($item.PSObject.Properties.Name | Where-Object { @("resource", "type") -cnotcontains $_ })
        if ($unexpectedItemProperties.Count -gt 0) {
            throw "Agent MCP resource content contained unexpected property/properties: $($unexpectedItemProperties -join ', ')."
        }

        $resource = $item.resource
        $requiredResourceProperties = @("blob", "mimeType", "uri")
        $missingResourceProperties = @($requiredResourceProperties | Where-Object { -not $resource.PSObject.Properties[$_] })
        if ($missingResourceProperties.Count -gt 0) {
            throw "Agent MCP resource omitted required property/properties: $($missingResourceProperties -join ', ')."
        }
        $unexpectedResourceProperties = @($resource.PSObject.Properties.Name | Where-Object { $requiredResourceProperties -cnotcontains $_ })
        if ($unexpectedResourceProperties.Count -gt 0) {
            throw "Agent MCP resource contained unexpected property/properties: $($unexpectedResourceProperties -join ', ')."
        }
        if ($resource.uri -isnot [string] -or [string]$resource.uri -cne $ExpectedUri) {
            throw "Agent MCP resource URI did not exactly match the wrapper-requested path."
        }
        if ($resource.mimeType -isnot [string] -or $allowed -cnotcontains [string]$resource.mimeType) {
            throw "Agent MCP resource MIME type was not in the wrapper's case-sensitive allow-list."
        }
        if ($resource.blob -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$resource.blob)) {
            throw "Agent MCP resource blob must be non-empty base64 text."
        }
        $blob = [string]$resource.blob
        if (($blob.Length % 4) -ne 0 -or $blob -notmatch '^[A-Za-z0-9+/]*={0,2}$') {
            throw "Agent MCP resource blob was not canonical base64."
        }
        try { $bytes = [Convert]::FromBase64String($blob) }
        catch { throw "Agent MCP resource blob was not valid base64." }
        if ([Convert]::ToBase64String($bytes) -cne $blob) {
            throw "Agent MCP resource blob was not canonical base64."
        }
        if ($bytes.Length -lt 1 -or $bytes.Length -gt $MaxBytes) {
            throw "Agent MCP resource decoded to $($bytes.Length) bytes; expected 1..$MaxBytes."
        }
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw "Agent MCP resource text must be UTF-8 without a byte-order mark."
        }
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strictUtf8.GetString($bytes)
        }
        catch {
            throw "Agent MCP resource was not valid UTF-8 text."
        }
        foreach ($character in $text.ToCharArray()) {
            $code = [int]$character
            if (($code -lt 32 -and $code -notin @(9, 10, 13)) -or $code -eq 127) {
                throw "Agent MCP resource text contained a disallowed control character."
            }
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hashBytes = $sha.ComputeHash($bytes) }
        finally { $sha.Dispose() }
        return @{
            Uri        = [string]$resource.uri
            MimeType   = [string]$resource.mimeType
            ByteLength = [int]$bytes.Length
            Sha256     = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
            Text       = [string]$text
        }
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

        Usage accounting is read from two events, when present, so a caller can
        record exact per-attempt cost even for a run that produced no marker:
          {"type":"result","usage":{"premiumRequests":N,"totalApiDurationMs":N,"sessionDurationMs":N}}
          {"type":"session.usage_checkpoint","data":{"totalNanoAiu":N,"totalPremiumRequests":N}}
        The checkpoint is cumulative, so the LAST one seen wins. Every usage
        figure is null when its event/field is absent - never zero, so a caller
        can tell "the CLI did not report this" from "the CLI reported zero".

        Returns @{ Answer; Model; ModifiedFiles; ToolRequests; ExitCode; ModelActuallyRan; Usage }
        or $null when the output is not JSONL - an older CLI, or a run without
        --output-format - so the caller falls back to raw stdout instead of
        failing the cycle. Usage is a hashtable whose values are null when the
        CLI did not report them.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$StdOutText)
    if ([string]::IsNullOrWhiteSpace($StdOutText)) { return $null }
    $phased = New-Object System.Collections.Generic.List[string]
    $noToolMessages = New-Object System.Collections.Generic.List[string]
    $allMessages = New-Object System.Collections.Generic.List[string]
    $modified = New-Object System.Collections.Generic.List[string]
    $toolRequests = New-Object System.Collections.Generic.List[string]
    $model = ""
    $exitCode = $null
    $usagePremiumRequests = $null
    $usageTotalApiDurationMs = $null
    $usageSessionDurationMs = $null
    $usageTotalNanoAiu = $null
    $usageTotalPremiumRequests = $null
    $sawJson = $false
    $sawAssistantMessage = $false
    # A CLI usage figure may exceed [int]::MaxValue (nano-AIU totals are large),
    # so these are read as [long] with a strict non-negative integral check that
    # rejects strings, fractions, and negatives - never coercing junk to a number.
    $readLong = {
        param($Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [double] -or $Value -is [single]) {
            if ([double]$Value -ne [Math]::Floor([double]$Value)) { return $null }
        }
        [long]$parsed = 0
        if (-not [long]::TryParse(([string]$Value), [ref]$parsed)) { return $null }
        if ($parsed -lt 0) { return $null }
        return $parsed
    }
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
            $toolProp = $data.PSObject.Properties["toolRequests"]
            if ($toolProp -and $null -ne $toolProp.Value -and @($toolProp.Value).Count -gt 0) {
                foreach ($request in @($toolProp.Value)) {
                    if ($request -is [string] -and $request.Trim()) {
                        [void]$toolRequests.Add([string]$request)
                        continue
                    }
                    $nameProp = if ($request -is [System.Management.Automation.PSCustomObject]) {
                        $request.PSObject.Properties["name"]
                    }
                    else { $null }
                    if ($nameProp -and $nameProp.Value -is [string] -and $nameProp.Value.Trim()) {
                        [void]$toolRequests.Add([string]$nameProp.Value)
                    }
                    else { [void]$toolRequests.Add("<unparsed>") }
                }
            }
            if ($text.Trim() -ne "") {
                [void]$allMessages.Add($text)
                # A message that requested NO tools is a terminal answer rather
                # than commentary preceding a tool call.
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
                $prProp = $usageProp.Value.PSObject.Properties["premiumRequests"]
                if ($prProp) { $usagePremiumRequests = (& $readLong $prProp.Value) }
                $adProp = $usageProp.Value.PSObject.Properties["totalApiDurationMs"]
                if ($adProp) { $usageTotalApiDurationMs = (& $readLong $adProp.Value) }
                $sdProp = $usageProp.Value.PSObject.Properties["sessionDurationMs"]
                if ($sdProp) { $usageSessionDurationMs = (& $readLong $sdProp.Value) }
            }
        }
        elseif ($eventType -eq "session.usage_checkpoint" -and $data) {
            # Cumulative: the last checkpoint carries the run's running totals.
            $naProp = $data.PSObject.Properties["totalNanoAiu"]
            if ($naProp) { $v = (& $readLong $naProp.Value); if ($null -ne $v) { $usageTotalNanoAiu = $v } }
            $tprProp = $data.PSObject.Properties["totalPremiumRequests"]
            if ($tprProp) { $v = (& $readLong $tprProp.Value); if ($null -ne $v) { $usageTotalPremiumRequests = $v } }
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
        ToolRequests   = @($toolRequests.ToArray())
        ExitCode       = $exitCode
        ModelActuallyRan = $sawAssistantMessage
        Usage          = @{
            PremiumRequests      = $usagePremiumRequests
            TotalApiDurationMs   = $usageTotalApiDurationMs
            SessionDurationMs    = $usageSessionDurationMs
            TotalNanoAiu         = $usageTotalNanoAiu
            TotalPremiumRequests = $usageTotalPremiumRequests
        }
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

function Invoke-AgentGitHubApiResult {
    <#
    .SYNOPSIS
        A structured-error variant of Invoke-AgentGitHubApi for callers that
        must distinguish a definitive negative from an unknown one.

    .DESCRIPTION
        Invoke-AgentGitHubApi throws on any non-2xx response and collapses
        stderr to three lines, which loses the status code entirely. That is
        fine for a caller that only needs "did this work", but a fail-closed
        capability read - "does this branch dismiss stale reviews on push" -
        needs the distinction: a 404 on branch protection means the branch
        DEFINITELY has no protection rule (known=$true), while a 403 means the
        token cannot tell (known=$false). Collapsing both to "it failed" would
        make an operator debugging a closed gate unable to tell "there is
        genuinely no rule" from "grant the token more scope".

        Never throws for a well-formed HTTP response, including non-2xx ones;
        still throws for a missing 'gh' CLI, an unsafe path, or a transport
        timeout, because none of those are a status this layer can normalize.
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
    if ($Path -match '^[a-z][a-z0-9+.-]*://' -or $Path.StartsWith('//')) {
        throw "GitHub API path '$Path' must be relative to the API root, not an absolute URL."
    }

    # -i prints the status line and headers ahead of the body so the status
    # code can be recovered even though `gh api` exits non-zero on a non-2xx
    # response (which is exactly the case this function exists to inspect).
    $arguments = @('api', $Path, '--method', $Method, '-i')
    if ($Body) { $arguments += @('--input', '-') }
    $stdin = if ($Body) { ($Body | ConvertTo-Json -Depth 10 -Compress) } else { $null }

    $result = Invoke-TimedProcess -FilePath $gh.Source -ArgumentList $arguments `
        -StandardInputContent $stdin -CaptureStdOut -CaptureStdErr -TimeoutSeconds $TimeoutSeconds

    if ($result.TimedOut) {
        return @{ Ok = $false; StatusCode = 0; Value = $null; Error = "GitHub API call '$Method $Path' timed out after $TimeoutSeconds second(s)." }
    }

    $stdOutText = [string]$result.StdOut
    $statusMatch = [Text.RegularExpressions.Regex]::Match(
        $stdOutText, '^HTTP\/[\d.]+\s+(\d{3})', [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $statusMatch.Success) {
        $detail = if ($result.StdErr) { (([string]$result.StdErr) -split "`n" | Select-Object -First 3) -join ' ' } else { "exit code $($result.ExitCode)" }
        return @{ Ok = $false; StatusCode = 0; Value = $null; Error = "GitHub API call '$Method $Path' returned no recognizable HTTP status line: $detail" }
    }
    $statusCode = [int]$statusMatch.Groups[1].Value

    # The body follows the header block after the first blank line; `gh`
    # writes CRLF-terminated header lines regardless of host OS.
    $headerBodySplit = $stdOutText.IndexOf("`r`n`r`n")
    $bodyText = if ($headerBodySplit -ge 0) {
        $stdOutText.Substring($headerBodySplit + 4)
    }
    else {
        $altSplit = $stdOutText.IndexOf("`n`n")
        if ($altSplit -ge 0) { $stdOutText.Substring($altSplit + 2) } else { "" }
    }
    $value = $null
    if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
        try { $value = ($bodyText | ConvertFrom-Json -ErrorAction Stop) } catch { $value = $null }
    }
    if ($statusCode -ge 200 -and $statusCode -lt 300) {
        return @{ Ok = $true; StatusCode = $statusCode; Value = $value; Error = $null }
    }
    $message = if ($value -and $value.PSObject.Properties['message']) { [string]$value.message } else { "HTTP $statusCode" }
    return @{ Ok = $false; StatusCode = $statusCode; Value = $value; Error = $message }
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

function ConvertTo-AgentProviderCheckRunsSnapshot {
    <#
    .SYNOPSIS
        Pure normalization of a raw GitHub check-runs payload, separated from
        Get-AgentProviderValidationRun's API call so it is unit-testable
        against a fixture the same way ConvertTo-AgentProviderSnapshot is.

    .DESCRIPTION
        'found=$false' (no checks at all) is UNKNOWN, not clean - a gate that
        requires green must not treat "nothing reported yet" as passing.
        'neutral' and 'skipped' are not failures, but are not evidence of a
        passing build either; only 'success' counts as green.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$HeadSha,
        [string]$CheckNameFilter = ''
    )
    $runs = @($Payload.check_runs)
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
    return ConvertTo-AgentProviderCheckRunsSnapshot -Payload $payload -HeadSha $HeadSha -CheckNameFilter $CheckNameFilter
}

function ConvertTo-AgentProviderReviewDismissalPolicy {
    <#
    .SYNOPSIS
        Pure normalization of an Invoke-AgentGitHubApiResult-shaped branch-
        protection read into the structured known/true/false shape, separated
        from the API call so it is unit-testable against a fixture.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ApiResult)
    if (-not $ApiResult.Ok) {
        if ($ApiResult.StatusCode -eq 404) {
            return @{ known = $true; dismissesStaleReviews = $false; source = 'none'; reason = 'no branch protection rule exists for this branch' }
        }
        if ($ApiResult.StatusCode -eq 403) {
            return @{ known = $false; dismissesStaleReviews = $false; source = 'unknown'; reason = "insufficient permission to read branch protection: $($ApiResult.Error)" }
        }
        return @{ known = $false; dismissesStaleReviews = $false; source = 'unknown'; reason = "branch protection read failed: $($ApiResult.Error)" }
    }
    $reviews = $null
    if ($ApiResult.Value -and $ApiResult.Value.PSObject.Properties['required_pull_request_reviews']) {
        $reviews = $ApiResult.Value.required_pull_request_reviews
    }
    if ($null -eq $reviews) {
        return @{ known = $true; dismissesStaleReviews = $false; source = 'branchProtection'; reason = 'branch protection exists but does not require pull request reviews' }
    }
    $dismisses = [bool]($reviews.PSObject.Properties['dismiss_stale_reviews'] -and $reviews.dismiss_stale_reviews -eq $true)
    return @{ known = $true; dismissesStaleReviews = $dismisses; source = 'branchProtection'; reason = 'read from required_pull_request_reviews.dismiss_stale_reviews' }
}

function Get-AgentProviderReviewDismissalPolicy {
    <#
    .SYNOPSIS
        Whether pushing new commits to a branch resets (dismisses) stale
        review approvals there, for GitHub classic branch protection.

    .DESCRIPTION
        Returns a STRUCTURED known/true/false, never a plausible-looking
        default: `known=$false` means the caller could not determine the
        answer at all (an unattended approval gate must treat that as closed,
        the same as an explicit $false). A 404 on the protection endpoint is a
        definitive "no rule exists" and is therefore known=$true,
        dismissesStaleReviews=$false. A 403 (a token without repository-admin
        scope, which is common) is genuinely unknown.

        Only GitHub's classic branch-protection API is read. GitHub's newer
        repository-ruleset mechanism can also enforce dismissal and is NOT
        checked here - `source` therefore only ever returns 'branchProtection',
        'none', or 'unknown' in this version, never 'ruleset'. A repository
        that dismisses stale reviews ONLY via a ruleset will read as 'none'
        (dismissesStaleReviews=$false) here, which fails the approval gate
        closed rather than open - the safe direction for an unimplemented
        surface - but is not a positive proof either way. See
        docs/delivery-gates.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$TargetBranch)
    Assert-AgentProviderContext -Context $Context -RequiredProvider 'GitHub'
    if ([string]::IsNullOrWhiteSpace($TargetBranch)) { throw "TargetBranch must be non-empty." }

    $slug = $Context.Slug
    $encodedBranch = [Uri]::EscapeDataString($TargetBranch)
    $result = Invoke-AgentGitHubApiResult -Path "repos/$slug/branches/$encodedBranch/protection" -TimeoutSeconds $Context.TimeoutSeconds
    return ConvertTo-AgentProviderReviewDismissalPolicy -ApiResult $result
}

function ConvertTo-AgentProviderRequiredChecksSnapshot {
    <#
    .SYNOPSIS
        Pure normalization from an already-normalized checks snapshot (the
        shape Get-AgentProviderValidationRun/ConvertTo-AgentProviderCheckRunsSnapshot
        return) plus a required-name list, into known/allComplete/allSuccess/
        missingRequired/runs/sha256.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ValidationRun,
        [AllowEmptyCollection()][string[]]$RequiredNames = @()
    )
    $runsByName = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($checkRun in @($ValidationRun.runs)) {
        $rawName = if ($checkRun -is [hashtable]) { $checkRun.name } else { $checkRun.Name }
        $name = [string]$rawName
        if ($name -and -not $runsByName.ContainsKey($name)) { $runsByName.Add($name, $checkRun) }
    }
    $missingRequired = [System.Collections.Generic.List[string]]::new()
    foreach ($requiredName in @($RequiredNames)) {
        if (-not $runsByName.ContainsKey([string]$requiredName)) { [void]$missingRequired.Add([string]$requiredName) }
    }
    $known = [bool]$ValidationRun.found
    $allComplete = $known -and [bool]$ValidationRun.isComplete -and $missingRequired.Count -eq 0
    $allSuccess = $known -and [bool]$ValidationRun.isSuccess -and $missingRequired.Count -eq 0

    $snapshotText = (@(@($ValidationRun.runs) | ForEach-Object {
                $entry = $_
                $name = if ($entry -is [hashtable]) { $entry.name } else { $entry.Name }
                $status = if ($entry -is [hashtable]) { $entry.status } else { $entry.Status }
                $conclusion = if ($entry -is [hashtable]) { $entry.conclusion } else { $entry.Conclusion }
                "$([string]$name)|$([string]$status)|$([string]$conclusion)"
            } | Sort-Object) -join "`n") + "`n" + (@($missingRequired) -join ',')
    $sha = [Security.Cryptography.SHA256]::Create()
    $sha256 = ""
    try {
        $sha256 = ([BitConverter]::ToString(
                $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($snapshotText)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }

    return @{
        known           = $known
        allComplete     = $allComplete
        allSuccess      = $allSuccess
        missingRequired = @($missingRequired.ToArray())
        runs            = @($ValidationRun.runs)
        sha256          = $sha256
    }
}

function Get-AgentProviderRequiredChecksSnapshot {
    <#
    .SYNOPSIS
        Whether every EXPLICITLY named required check for a commit is complete
        and green, for GitHub check runs.

    .DESCRIPTION
        Builds on Get-AgentProviderValidationRun's normalized run list (which
        already treats "no checks found" as 'None', not as "nothing to block
        on", and 'InProgress' as incomplete) and additionally verifies every
        name in -RequiredNames actually appears. A name that never ran at all
        is reported in missingRequired rather than silently passing because it
        was never contradicted.

        `known=$false` when the commit reports no check runs at all - that is
        unknown territory (checks may not have started), never treated as
        "nothing required, so this passes".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$HeadSha,
        [AllowEmptyCollection()][string[]]$RequiredNames = @()
    )
    Assert-AgentProviderContext -Context $Context -RequiredProvider 'GitHub'
    $run = Get-AgentProviderValidationRun -Context $Context -HeadSha $HeadSha
    return ConvertTo-AgentProviderRequiredChecksSnapshot -ValidationRun $run -RequiredNames $RequiredNames
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
    "Get-AgentGeneralistModelPair",
    "Test-AgentGeneralistModelPair",
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
    "ConvertFrom-AgentResultMarkerOutcome",
    "Get-AgentResultMarkerOutcome",
    "Test-AgentMarkerStatusRetryable",
    "Measure-AgentMarkerSchemaWorstCaseChars",
    "Measure-AgentMarkerSchemaWorstCaseBytes",
    "Test-AgentMarkerSchemaFitsScanWindow",
    "Test-AgentMarkerSchemaFitsLaunchContract",
    "ConvertTo-AgentCanonicalMarkerJson",
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
    "Test-AgentMcpToolResultShape",
    "ConvertFrom-AgentMcpResourceContent",
    "ConvertTo-AgentReplayCanonicalJson",
    "Get-AgentReplayRequestKey",
    "Test-AgentReplayToolPermitted",
    "New-AgentReplaySnapshot",
    "Assert-AgentReplaySnapshotPromotable",
    "Get-AgentReplayResponse",
    "Test-AgentReplaySnapshotHasResponse",
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
    "Set-AgentProviderPullRequestVote",
    "Invoke-AgentGitHubApiResult",
    "ConvertTo-AgentProviderCheckRunsSnapshot",
    "ConvertTo-AgentProviderReviewDismissalPolicy",
    "ConvertTo-AgentProviderRequiredChecksSnapshot",
    "Get-AgentProviderReviewDismissalPolicy",
    "Get-AgentProviderRequiredChecksSnapshot"
)
