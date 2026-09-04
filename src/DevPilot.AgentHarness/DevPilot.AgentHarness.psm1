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

. (Join-Path $PSScriptRoot 'AgentOutput.ps1')

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
$script:AgentManualAuthorities = @{}

function Get-AgentSupportedModels {
    return , @($script:AgentHarnessSupportedModels)
}

function Get-AgentDefaultModelSentinel {
    return $script:AgentHarnessDefaultModelSentinel
}

# ---------------------------------------------------------------------------
# Single source of truth for per-role manual capability ceilings (NOT config-
# supplied - this is the one place these literal capability names may be
# declared). Watch-DevPilotAgents.ps1, the broker's Get-RoleDescriptor, and
# Enter-AgentManualDispatchStartup all read this instead of keeping their own
# copy, so the three call sites can never independently drift. Pure and
# grant-free: no per-draft, per-grant, or persisted-override concept lives
# here (that is PR2+ scope). Every array is a fresh literal built on each
# call, so callers can freely mutate their own copy of the result without
# affecting any other caller or a later call.
# ---------------------------------------------------------------------------
function Get-AgentHarnessCapabilityDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role
    )
    $operationalTiers = if ($Role -eq 'reviewer') {
        [ordered]@{
            base = @('EnableFindingComments', 'EnableThreadReplies', 'EnableSummaryComment')
        }
    }
    else {
        [ordered]@{
            base       = @('EnableThreadReplies', 'EnableBuddyRequeue')
            codeUpdate = @('EnableCodeChanges', 'EnablePush', 'LocalValidation', 'ResumeCodingSession')
        }
    }
    $delegableDefaultOff = if ($Role -eq 'reviewer') { 'EnableApprovalVote' } else { 'EnableAutoComplete' }
    $allowedManualCapabilities = @($operationalTiers.Values | ForEach-Object { $_ } | Sort-Object -Unique)
    return [ordered]@{
        schemaVersion             = 1
        role                      = $Role
        operationalTiers          = $operationalTiers
        delegableDefaultOff       = $delegableDefaultOff
        allowedManualCapabilities = $allowedManualCapabilities
        # Pinned empty in PR1: no absolute-deny source exists yet (PR2+ kill switch/policy scope).
        absoluteDenies            = @()
    }
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

function New-AgentPipeName {
    <#
        Short, cryptographically random named-pipe name (10 random bytes ->
        20 lowercase hex chars, plus a 3-character 'dp-' prefix). Unix domain
        sockets cap the full path at 104 characters, and .NET's named pipe
        implementation on Unix builds that path as
        "<TMPDIR>/CoreFxPipe_<name>" - macOS's per-boot TMPDIR
        (/var/folders/xx/<~30 random chars>/T/) alone can consume half that
        budget, so the name itself must stay short. 80 bits of randomness is
        still ample to keep the name unpredictable and uniquely correlate a
        single dispatch/test instance.
    #>
    $bytes = New-Object byte[] 10
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return "dp-$(([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant())"
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
# Canonical work leases and shared durable state v2
# ---------------------------------------------------------------------------

function Get-AgentSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    try {
        return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-AgentDefaultDurableStateRoot {
    if ($IsWindows) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is required to resolve the durable-state root on Windows.' }
        return (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'DevPilot') 'state') 'v2')
    }
    $base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path (Join-Path $HOME '.local') 'state' }
    return (Join-Path (Join-Path (Join-Path $base 'devpilot') 'state') 'v2')
}

function Get-AgentDefaultLeaseRoot {
    if ($IsWindows) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is required to resolve the lease root on Windows.' }
        return (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'DevPilot') 'leases') 'v1')
    }
    $base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path (Join-Path $HOME '.local') 'state' }
    return (Join-Path (Join-Path (Join-Path $base 'devpilot') 'leases') 'v1')
}

function Get-AgentDefaultWatchStateRoot {
    if ($IsWindows) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is required to resolve the watch-state root on Windows.' }
        return (Join-Path (Join-Path $env:LOCALAPPDATA 'DevPilot') 'watch')
    }
    $base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path (Join-Path $HOME '.local') 'state' }
    return (Join-Path (Join-Path $base 'devpilot') 'watch')
}

function Test-AgentPathWithin {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Test-AgentOsCanonicalAlias {
    <#
        True only for the top-level directories macOS's Signed
        System Volume exposes as symlinks into /private for historical BSD
        compatibility that can contain trusted state (/var -> private/var and
        /tmp -> private/tmp). These are baked into the read-only system
        volume - an ordinary process cannot replant them - so recognizing
        exactly this fixed set does not weaken the reparse-point defense used
        against every other (attacker-plantable) symlink.
    #>
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$LinkTarget)
    if (-not $IsMacOS -or -not $LinkTarget) { return $false }
    $expectedTarget = switch -CaseSensitive ($Path) {
        '/var' { 'private/var' }
        '/tmp' { 'private/tmp' }
        default { $null }
    }
    return $expectedTarget -and $expectedTarget -ceq $LinkTarget
}

function Assert-AgentPathHasNoLinks {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item) {
            $isLink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType
            if ($isLink -and -not (Test-AgentOsCanonicalAlias -Path $current -LinkTarget $item.LinkTarget)) {
                throw "Trusted root '$Path' traverses link or reparse point '$current'."
            }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-AgentUnixOwner {
    param([Parameter(Mandatory)][string]$Path)
    $idPath = '/usr/bin/id'
    $statPath = '/usr/bin/stat'
    if (-not (Test-Path -LiteralPath $idPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $statPath -PathType Leaf)) {
        throw 'Trusted Unix ownership cannot be validated because id or stat is unavailable.'
    }
    $current = ([string](& $idPath -u)).Trim()
    if ($LASTEXITCODE -ne 0 -or $current -notmatch '^\d+$') {
        throw 'Trusted Unix ownership cannot be validated for the current process.'
    }
    $owner = if ($IsMacOS) {
        ([string](& $statPath -f '%u' $Path)).Trim()
    }
    else {
        ([string](& $statPath -c '%u' -- $Path)).Trim()
    }
    if ($LASTEXITCODE -ne 0 -or $owner -notmatch '^\d+$' -or $owner -cne $current) {
        throw "Trusted path '$Path' is not owned by the current user."
    }
}

function Assert-AgentWindowsAcl {
    param([Parameter(Mandatory)][string]$Path, [switch]$Private)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User
    $systemSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
        [Security.Principal.SecurityIdentifier])
    # Windows gives a file created by an elevated administrator's process the
    # Administrators group as its owner rather than the user's own SID. Accept
    # that only for a genuinely elevated caller; another elevated administrator
    # is already inside the same local-admin security boundary.
    $ownedByAdministratorsOnBehalfOfCurrentUser = $ownerSid -eq $administratorsSid -and
        [Security.Principal.WindowsPrincipal]::new($identity).IsInRole($administratorsSid)
    if ($ownerSid -ne $currentSid -and -not $ownedByAdministratorsOnBehalfOfCurrentUser) {
        throw "Trusted path '$Path' is not owned by the current user."
    }
    $writeRights = [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Modify -bor
        [Security.AccessControl.FileSystemRights]::FullControl -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.IdentityReference -eq $currentSid -or $rule.IdentityReference -eq $systemSid -or
            $rule.IdentityReference -eq $administratorsSid) {
            continue
        }
        if ($Private -or (($rule.FileSystemRights -band $writeRights) -ne 0)) {
            throw "Trusted path '$Path' grants unsafe access to another principal."
        }
    }
}

function Assert-AgentTrustedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$AllowedRoot,
        [string]$ExpectedPath,
        [switch]$Private
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw 'Trusted file path must be a non-empty absolute path.'
    }
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($ExpectedPath) {
        $expected = [IO.Path]::GetFullPath($ExpectedPath)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $resolved.Equals($expected, $comparison)) {
            throw "Trusted file '$resolved' is not the expected file '$expected'."
        }
    }
    if ($AllowedRoot -and -not (Test-AgentPathWithin -Path $resolved -Root $AllowedRoot)) {
        throw "Trusted file '$resolved' is outside the allowed root."
    }
    Assert-AgentPathHasNoLinks -Path $resolved
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Trusted file '$resolved' is not a file." }
    if ($IsWindows) {
        Assert-AgentWindowsAcl -Path $resolved -Private:$Private
    }
    else {
        Assert-AgentUnixOwner -Path $resolved
        $mode = [IO.File]::GetUnixFileMode($resolved)
        $unsafe = [IO.UnixFileMode]::GroupWrite -bor [IO.UnixFileMode]::OtherWrite
        if ($Private) {
            $unsafe = $unsafe -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor
                [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute
        }
        if (($mode -band $unsafe) -ne 0) {
            throw "Trusted file '$resolved' has unsafe Unix permissions."
        }
    }
    return $resolved
}

function Remove-AgentContainedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot,
        [Parameter(Mandatory)][string]$LeafPattern
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($AllowedRoot)
    if (-not (Test-AgentPathWithin -Path $resolved -Root $root) -or
        $resolved -eq $root -or (Split-Path $resolved -Leaf) -cnotmatch $LeafPattern) {
        throw "Refusing to remove '$resolved' outside the allowed contained directory."
    }
    if (-not (Test-Path -LiteralPath $resolved)) { return }
    Assert-AgentPathHasNoLinks -Path $resolved
    $items = @(Get-ChildItem -LiteralPath $resolved -Force -Recurse -ErrorAction Stop)
    if (-not $IsWindows) {
        Assert-AgentUnixOwner -Path $resolved
        foreach ($item in $items) {
            Assert-AgentPathHasNoLinks -Path $item.FullName
            Assert-AgentUnixOwner -Path $item.FullName
        }
        foreach ($directory in @($items | Where-Object { $_.PSIsContainer }) + @(Get-Item -LiteralPath $resolved -Force)) {
            $mode = [IO.File]::GetUnixFileMode($directory.FullName)
            [IO.File]::SetUnixFileMode($directory.FullName,
                $mode -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
    }
    foreach ($item in @($items | Where-Object { -not $_.PSIsContainer })) {
        if (-not (Test-AgentPathWithin -Path $item.FullName -Root $resolved)) {
            throw 'Refusing to remove an item outside the allowed contained directory.'
        }
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
    }
    foreach ($item in @($items | Where-Object { $_.PSIsContainer } |
            Sort-Object { $_.FullName.Length } -Descending)) {
        if (-not (Test-AgentPathWithin -Path $item.FullName -Root $resolved)) {
            throw 'Refusing to remove an item outside the allowed contained directory.'
        }
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
    }
    Remove-Item -LiteralPath $resolved -Force -ErrorAction Stop
}

function Resolve-AgentTrustedRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('durable-state', 'lease', 'watch-state', 'capability-overrides')][string]$Kind,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string[]]$DisallowedRoots = @(),
        [switch]$Create
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Kind root must be a non-empty absolute path."
    }
    $resolved = [IO.Path]::GetFullPath($Path)
    if (Test-AgentPathWithin -Path $resolved -Root $RepositoryRoot) {
        throw "$Kind root '$resolved' must be outside the repository."
    }
    foreach ($other in @($DisallowedRoots)) {
        if (-not $other) { continue }
        if ((Test-AgentPathWithin -Path $resolved -Root $other) -or (Test-AgentPathWithin -Path $other -Root $resolved)) {
            throw "$kind root '$resolved' must not contain or be contained by '$other'."
        }
    }
    Assert-AgentPathHasNoLinks -Path $resolved
    $created = -not (Test-Path -LiteralPath $resolved)
    if ($created) {
        if (-not $Create) { throw "$kind root '$resolved' does not exist." }
        New-Item -ItemType Directory -Path $resolved -Force -ErrorAction Stop | Out-Null
    }
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "$kind root '$resolved' is not a directory." }
    Assert-AgentPathHasNoLinks -Path $resolved

    if ($IsWindows) {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($created) {
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner($currentSid)
            $acl.SetAccessRuleProtection($true, $false)
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [Security.AccessControl.InheritanceFlags]::ObjectInherit
            $propagation = [Security.AccessControl.PropagationFlags]::None
            $allow = [Security.AccessControl.AccessControlType]::Allow
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    $currentSid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow))
            $systemSid = [Security.Principal.SecurityIdentifier]::new(
                [Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    $systemSid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow))
            Set-Acl -LiteralPath $resolved -AclObject $acl -ErrorAction Stop
        }
        Assert-AgentWindowsAcl -Path $resolved -Private
    }
    else {
        Assert-AgentUnixOwner -Path $resolved
        $mode = [IO.File]::GetUnixFileMode($resolved)
        $unsafe = [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupWrite -bor
            [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor
            [IO.UnixFileMode]::OtherWrite -bor [IO.UnixFileMode]::OtherExecute
        if (($mode -band $unsafe) -ne 0) {
            if (-not $created) { throw "$kind root '$resolved' grants group or other access." }
            [IO.File]::SetUnixFileMode($resolved,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
    }
    return $resolved
}

function Get-AgentRepositoryIdentityKey {
    param([Parameter(Mandatory)]$RepositoryIdentity)
    $key = [string](Get-AgentProviderValue -InputObject $RepositoryIdentity -Name 'key')
    $verified = [bool](Get-AgentProviderValue -InputObject $RepositoryIdentity -Name 'verified')
    if (-not $verified -or $key -notmatch '^v1:(azuredevops|github):[^:]+$') {
        throw 'A provider-verified RepositoryIdentityV1 is required.'
    }
    return $key
}

function Get-AgentExecutionKey {
    param(
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role
    )
    $repoKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $RepositoryIdentity
    return "$repoKey`:pr:$PullRequestId`:role:$Role"
}

function Enter-AgentExclusiveFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('lease-contended', 'state-contended', 'capability-override-contended')][string]$ContentionReason,
        [ValidateRange(0, 30000)][int]$TimeoutMilliseconds = 2000,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [hashtable]$Metadata = @{}
    )
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    do {
        $CancellationToken.ThrowIfCancellationRequested()
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.SetLength(0)
            $payload = [ordered]@{ pid = $PID; acquiredAtUtc = [DateTime]::UtcNow.ToString('o') }
            foreach ($key in @($Metadata.Keys | Sort-Object)) { $payload[$key] = $Metadata[$key] }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress -Depth 4))
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return @{ Acquired = $true; Reason = ''; Stream = $stream; Path = $Path }
        }
        catch [IO.IOException] {
            if ($deadline.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                return @{ Acquired = $false; Reason = $ContentionReason; Stream = $null; Path = $Path }
            }
            $remaining = $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
            $delay = [Math]::Min($remaining, [Random]::Shared.Next(50, 201))
            if ($delay -gt 0) {
                if ($CancellationToken.WaitHandle.WaitOne($delay)) { $CancellationToken.ThrowIfCancellationRequested() }
            }
        }
    } while ($true)
}

function Enter-AgentWorkLease {
    param(
        [Parameter(Mandatory)][string]$LeaseRoot,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [ValidateRange(0, 30000)][int]$TimeoutMilliseconds = 2000,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    $executionKey = Get-AgentExecutionKey -RepositoryIdentity $RepositoryIdentity -PullRequestId $PullRequestId -Role $Role
    $keyHash = Get-AgentSha256 -Text $executionKey
    if ($script:AgentManualAuthorities.ContainsKey($executionKey)) {
        return @{
            Acquired = $true; Reason = ''; Stream = $null
            Path = $script:AgentManualAuthorities[$executionKey].Lease.Path
            KeyHash = $keyHash; Preacquired = $true
        }
    }
    $result = Enter-AgentExclusiveFile -Path (Join-Path $LeaseRoot "$keyHash.lease") `
        -ContentionReason lease-contended -TimeoutMilliseconds $TimeoutMilliseconds `
        -CancellationToken $CancellationToken -Metadata @{ keyHash = $keyHash; role = $Role }
    $result['KeyHash'] = $keyHash
    return $result
}

function Get-AgentDurableStateContext {
    param(
        [Parameter(Mandatory)][string]$DurableStateRoot,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [switch]$Create
    )
    $repositoryKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $RepositoryIdentity
    $repositoryKeyHash = Get-AgentSha256 -Text $repositoryKey
    $roleRoot = Join-Path (Join-Path $DurableStateRoot $repositoryKeyHash) $Role
    if ($Create -and -not (Test-Path -LiteralPath $roleRoot)) {
        New-Item -ItemType Directory -Path $roleRoot -Force -ErrorAction Stop | Out-Null
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($roleRoot,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
    }
    return @{
        RoleRoot = $roleRoot
        StatePath = Join-Path $roleRoot 'state.v2.json'
        JournalPath = Join-Path $roleRoot 'state.v2.journal.json'
        LockPath = Join-Path $roleRoot 'state.v2.lock'
        InitializedPath = Join-Path $roleRoot 'initialized.v2'
        RepositoryKey = $repositoryKey
        RepositoryKeyHash = $repositoryKeyHash
        Role = $Role
        RepositoryIdentity = $RepositoryIdentity
    }
}

function Enter-AgentDurableStateLock {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [ValidateRange(0, 30000)][int]$TimeoutMilliseconds = 2000,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    if (-not (Test-Path -LiteralPath $Context.RoleRoot)) {
        throw "Durable role root '$($Context.RoleRoot)' does not exist."
    }
    $preacquired = @($script:AgentManualAuthorities.Values | Where-Object {
            $_.StateLock.Path -ceq $Context.LockPath
        } | Select-Object -First 1)
    if ($preacquired.Count -gt 0) {
        return @{ Acquired = $true; Reason = ''; Stream = $null; Path = $Context.LockPath; Preacquired = $true }
    }
    return Enter-AgentExclusiveFile -Path $Context.LockPath -ContentionReason state-contended `
        -TimeoutMilliseconds $TimeoutMilliseconds -CancellationToken $CancellationToken `
        -Metadata @{ repositoryKeyHash = $Context.RepositoryKeyHash; role = $Context.Role }
}

function Invoke-AgentWithWorkAuthority {
    param(
        [Parameter(Mandatory)][string]$LeaseRoot,
        [Parameter(Mandatory)][hashtable]$DurableContext,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [Parameter(Mandatory)][scriptblock]$Action,
        [ValidateRange(0, 30000)][int]$TimeoutMilliseconds = 2000,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    $executionKey = Get-AgentExecutionKey -RepositoryIdentity $RepositoryIdentity -PullRequestId $PullRequestId -Role $Role
    if ($script:AgentManualAuthorities.ContainsKey($executionKey)) {
        $authority = $script:AgentManualAuthorities[$executionKey]
        Repair-AgentDurableState -Context $DurableContext
        $value = & $Action
        return @{ Acquired = $true; Reason = ''; KeyHash = $authority.KeyHash; Value = $value }
    }
    $lease = Enter-AgentWorkLease -LeaseRoot $LeaseRoot -RepositoryIdentity $RepositoryIdentity `
        -PullRequestId $PullRequestId -Role $Role -TimeoutMilliseconds $TimeoutMilliseconds `
        -CancellationToken $CancellationToken
    if (-not $lease.Acquired) {
        return @{ Acquired = $false; Reason = $lease.Reason; KeyHash = $lease.KeyHash; Value = $null }
    }

    try {
        $stateLock = Enter-AgentDurableStateLock -Context $DurableContext `
            -TimeoutMilliseconds $TimeoutMilliseconds -CancellationToken $CancellationToken
        if (-not $stateLock.Acquired) {
            return @{ Acquired = $false; Reason = $stateLock.Reason; KeyHash = $lease.KeyHash; Value = $null }
        }
        try {
            Repair-AgentDurableState -Context $DurableContext
            $value = & $Action
            return @{ Acquired = $true; Reason = ''; KeyHash = $lease.KeyHash; Value = $value }
        }
        finally {
            Exit-AgentLock -Stream $stateLock.Stream
        }
    }
    finally {
        Exit-AgentLock -Stream $lease.Stream
    }
}

# ---------------------------------------------------------------------------
# Outside-repository capability-override store (PR2): hardened root, stable
# reads, narrow-only schema validation, effective-settings resolution, and
# the advisory lock shared with child-startup re-verification. No writer
# exists yet anywhere in this change -- TUI edit/reset/kill switch is PR3,
# checked-in delegation policy and ephemeral widening are PR4. Everything
# below is read/resolve-only and can only ever narrow an already-open
# capability to a mandatory deny, never grant one.
#
# Root convention: this follows the exact same per-user %LOCALAPPDATA% (Windows) /
# ${XDG_STATE_HOME:-$HOME/.local/state} (POSIX) convention this module already uses for the
# durable-state/lease/watch-state roots -- a per-machine, per-LOCAL-USER install location, not a
# roaming or shared one. The logical 'machine' scope name below means "this machine, for this
# local user's DevPilot installation" -- i.e. the broadest baseline this one user's agents see on
# this one box -- and is deliberately NOT an administrator-owned, multi-user machine-wide policy
# store: it is written and read entirely with the invoking user's own privileges, same as every
# other root this module resolves. This matches the approved architecture; do not rehome it under
# ProgramData (Windows) or /etc (POSIX) or otherwise widen it to a multi-user/elevated location.
# ---------------------------------------------------------------------------

function Get-AgentDefaultCapabilityOverrideRoot {
    if ($IsWindows) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is required to resolve the capability-override root on Windows.' }
        return (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'DevPilot') 'capability-overrides') 'v1')
    }
    $base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path (Join-Path $HOME '.local') 'state' }
    return (Join-Path (Join-Path (Join-Path $base 'devpilot') 'capability-overrides') 'v1')
}

function Get-AgentCapabilityOverrideRoot {
    <#
        Resolves and hardens the capability-override root. Deliberately takes no root/path
        parameter from any caller -- unlike durable-state/lease/watch-state, this root is never
        forwarded through a broker descriptor or CLI argument; every consumer computes it the same
        way, from the same environment convention, so nothing external can redirect where overrides
        are read from. Disjoint by construction from every other default root this module resolves.
        Re-validated (ACL/symlink/ownership) on every call rather than cached, matching this
        function's own "resolve internally, never trust a forwarded value" contract; call frequency
        here is human-interaction-scale (profile/describe/dispatch/startup), not a hot loop.
    #>
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $default = Get-AgentDefaultCapabilityOverrideRoot
    $siblings = @((Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot))
    return Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $RepositoryRoot `
        -DisallowedRoots $siblings -Create
}

function ConvertTo-AgentCanonicalEpochSeconds {
    param([Parameter(Mandatory)][DateTime]$Value)
    $utc = if ($Value.Kind -eq [DateTimeKind]::Utc) { $Value } else { $Value.ToUniversalTime() }
    return [long][Math]::Floor(($utc - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds)
}

function Get-AgentWorktreeIdentity {
    <#
        Stable identity for one repository worktree: the SHA-256 of its canonical, case-normalized
        (Windows only) absolute path. Two worktrees of the identical repository checked out at
        different filesystem paths (e.g. two `git worktree add` checkouts) always resolve to
        different ids; the same worktree path always resolves to the same id.
    #>
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot) -or -not [IO.Path]::IsPathFullyQualified($RepositoryRoot)) {
        throw 'RepositoryRoot must be a non-empty absolute path.'
    }
    $full = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalized = if ($IsWindows) { $full.ToLowerInvariant() } else { $full }
    return Get-AgentSha256 -Text $normalized
}

function Read-AgentStableFile {
    <#
        Stat-before/read-once/stat-after stable read: retries while a concurrent writer appears to
        be racing this read (size/mtime disagree before vs. after, or existence itself flips), and
        fails closed rather than ever returning a possibly-torn read. The returned Bytes are the
        exact bytes the fingerprint was computed from -- callers that need to parse content
        (ConvertFrom-AgentTrustedCapabilityJson) never perform a second, separate read.

        MaxBytes is enforced BEFORE any read buffer is allocated: the file is opened once and its
        length is inspected from that open FileStream first, and an oversized file is rejected
        immediately -- this function never performs the ReadAllBytes-equivalent of allocating a
        buffer sized from an unchecked length. The bounded buffer is then filled from that SAME
        single FileStream (never a second, separate open); a short read (fewer bytes delivered than
        the checked length -- truncation mid-read) or the stream's length disagreeing with what was
        checked immediately before the read (growth mid-read) both fail this attempt as unstable and
        retry, exactly like the pre-existing before/after metadata race check below. A path that
        exists but is not a regular file (a directory, or any other non-file object) is never
        silently treated as "absent" -- Test-Path's plain existence check is evaluated first, and
        only THEN is its type checked; an existing non-file object always fails closed instead of
        being masked as a missing/un-narrowed override.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 5)][int]$MaxAttempts = 3,
        [ValidateRange(1, 1048576)][int]$MaxBytes = 65536
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) {
            return [ordered]@{ Path = $Path; Exists = $false; Size = 0; MTime = 0; Sha256 = $null; Bytes = [byte[]]@() }
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw '[stable-read-invalid] An existing non-file object occupies the path.'
        }
        $before = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (-not $before) {
            # Test-Path just confirmed a leaf existed at this path; a failure here means it raced a
            # concurrent delete between the two calls. Retry like any other stat instability rather
            # than falling back to "does not exist".
            continue
        }
        $bytes = $null
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            $length = $stream.Length
            if ($length -gt $MaxBytes) {
                throw "[stable-read-too-large] File exceeds the maximum allowed size of $MaxBytes bytes."
            }
            $buffer = [byte[]]::new([int]$length)
            $offset = 0
            $truncated = $false
            while ($offset -lt $buffer.Length) {
                $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
                if ($read -le 0) { $truncated = $true; break }
                $offset += $read
            }
            if (-not $truncated -and $stream.Length -eq $length) { $bytes = $buffer }
        }
        finally { $stream.Dispose() }
        if (-not $bytes) {
            # Truncated mid-read or grew past the length we bounded the buffer to -- a concurrent
            # writer raced this read. Retry.
            continue
        }
        $after = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($after -and $before.Length -eq $after.Length -and $before.LastWriteTimeUtc -eq $after.LastWriteTimeUtc -and
            $bytes.Length -eq $before.Length) {
            return [ordered]@{
                Path = $Path; Exists = $true; Size = $bytes.Length
                MTime = (ConvertTo-AgentCanonicalEpochSeconds $after.LastWriteTimeUtc)
                Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                Bytes = $bytes
            }
        }
        # Stat-before and stat-after (or existence itself) disagree -- a concurrent writer raced
        # this read. Retry.
    }
    throw '[stable-read-unstable] File changed while being read.'
}

function Test-AgentSecretShapedText {
    <#
        Conservative, intentionally narrow "does this look like a credential rather than a
        capability name" heuristic. Defense in depth only, layered on top of this store's own
        structural rules (fixed capability-name shape, enum-only settings values, fixed hex identity
        formats), in case a future change loosens any of those. False negatives are expected and
        acceptable here precisely because the structural checks alongside it are the primary
        defense.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text.Length -ge 32 -and $Text -cmatch '^[0-9a-fA-F]{32,}$') { return $true }
    if ($Text.Length -ge 24 -and $Text -cmatch '^[A-Za-z0-9+/]{24,}={0,2}$') { return $true }
    if ($Text -cmatch '^(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}$') { return $true }
    if ($Text -cmatch '^(?:sk|pk|rk)_[A-Za-z0-9]{16,}$') { return $true }
    if ($Text -cmatch '^AKIA[A-Z0-9]{16}$') { return $true }
    if ($Text -cmatch '^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') { return $true }
    if ($Text -cmatch '-----BEGIN [A-Z ]*PRIVATE KEY-----') { return $true }
    return $false
}

function Get-AgentRedactedFieldReference {
    <#
        Renders an untrusted JSON property/capability name as a bounded, non-reversible reference
        safe to interpolate into an exception message: a short SHA-256 prefix of the raw value plus
        its 1-based ordinal position among the sibling keys/entries being validated. Every capability-
        override parsing error that would otherwise echo a raw, potentially secret-shaped or
        otherwise sensitive property name (duplicate/case-collision keys, malformed/unrecognized
        capability names, unknown top-level fields) must use this instead of the raw text --
        Test-AgentSecretShapedText exists specifically to catch credential-looking values, and
        putting the very value it flagged into the message that reports it would defeat the purpose
        of flagging it. An engineer holding the original candidate value can still confirm a match by
        hashing it the same way; the raw value itself never appears in logs, IcM, or protocol
        responses.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Position)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
    return "sha256:$($hash.Substring(0, 12))@$Position"
}

function Assert-AgentCapabilityJsonRawShape {
    <#
        Recursively walks the RAW JSON via System.Text.Json.JsonDocument -- BEFORE any
        ConvertFrom-Json/hashtable conversion -- to catch duplicate and case-collision object keys
        that ConvertFrom-Json's own last-value-wins folding would otherwise silently hide. Also
        enforces hard bounds on nesting depth, total element count, and string length so a
        pathological file cannot exhaust memory/CPU before schema validation even begins. Iterative
        (explicit stack), not recursive, so a pathological depth fails via the bound check rather
        than risking a real stack overflow.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [ValidateRange(1, 64)][int]$MaxDepth = 6,
        [ValidateRange(1, 4096)][int]$MaxElements = 512,
        [ValidateRange(1, 65536)][int]$MaxStringLength = 4096
    )
    $document = [Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]$Bytes)
    try {
        $elementCount = 0
        $stack = [Collections.Generic.Stack[object]]::new()
        $stack.Push(@{ Node = $document.RootElement; Depth = 0 })
        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            $node = $frame.Node
            $depth = $frame.Depth
            if ($depth -gt $MaxDepth) { throw '[capability-settings-invalid] JSON exceeds the maximum nesting depth.' }
            $elementCount++
            if ($elementCount -gt $MaxElements) { throw '[capability-settings-invalid] JSON exceeds the maximum element count.' }
            switch ($node.ValueKind) {
                ([Text.Json.JsonValueKind]::Object) {
                    $seenExact = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    $seenFold = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    $propertyIndex = 0
                    foreach ($property in $node.EnumerateObject()) {
                        $propertyIndex++
                        if ($property.Name.Length -gt $MaxStringLength) {
                            throw '[capability-settings-invalid] JSON property name exceeds the maximum length.'
                        }
                        if (-not $seenExact.Add($property.Name)) {
                            $ref = Get-AgentRedactedFieldReference -Text $property.Name -Position $propertyIndex
                            throw "[capability-settings-invalid] Duplicate property ($ref) in capability settings JSON."
                        }
                        if (-not $seenFold.Add($property.Name)) {
                            $ref = Get-AgentRedactedFieldReference -Text $property.Name -Position $propertyIndex
                            throw "[capability-settings-invalid] Property ($ref) collides case-insensitively with a sibling."
                        }
                        $stack.Push(@{ Node = $property.Value; Depth = ($depth + 1) })
                    }
                }
                ([Text.Json.JsonValueKind]::Array) {
                    foreach ($item in $node.EnumerateArray()) { $stack.Push(@{ Node = $item; Depth = ($depth + 1) }) }
                }
                ([Text.Json.JsonValueKind]::String) {
                    if ($node.GetString().Length -gt $MaxStringLength) {
                        throw '[capability-settings-invalid] JSON string value exceeds the maximum length.'
                    }
                }
                default {}
            }
        }
    }
    finally { $document.Dispose() }
}

function ConvertFrom-AgentTrustedCapabilityJson {
    <#
        Parses and validates one capability-override settings record from already-read bytes
        (Read-AgentStableFile) -- performs no file I/O of its own, so the single stable read is
        authoritative for both fingerprint and content. Any schema, shape, or binding violation
        rejects the ENTIRE record, not just the offending field, and fails closed.

        AllowedCapabilities must be the union of every known role's allowedManualCapabilities, not
        only the resolving caller's role: the physical file layout has no role segment (one file
        serves every role for a given scope), so a key relevant only to another role must still
        validate here. A role's delegableDefaultOff/absoluteDenies names are deliberately excluded
        from that union by the caller, so they always fail as unrecognized -- persisted settings may
        only narrow a capability that is already part of some role's open ceiling, never name one
        that was never open to begin with.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateSet('machine', 'user', 'repo-worktree', 'pr')][string]$SourceScope,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedCapabilities
    )
    if ($Bytes.Length -eq 0) { throw "[capability-settings-invalid] ($SourceScope) Empty capability settings content." }
    if ($Bytes.Length -gt 65536) { throw "[capability-settings-invalid] ($SourceScope) Capability settings content exceeds the byte limit." }
    Assert-AgentCapabilityJsonRawShape -Bytes $Bytes
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $record = $strictUtf8.GetString($Bytes) | ConvertFrom-Json -AsHashtable -Depth 8 -ErrorAction Stop
    if ($record -isnot [Collections.IDictionary]) { throw "[capability-settings-invalid] ($SourceScope) Record is not a JSON object." }

    $scopedFields = @{
        machine         = @{ Required = @(); Forbidden = @('repositoryKey', 'worktreeId', 'pullRequestId', 'sourceCommit', 'expiresAtUtc') }
        user            = @{ Required = @(); Forbidden = @('repositoryKey', 'worktreeId', 'pullRequestId', 'sourceCommit', 'expiresAtUtc') }
        'repo-worktree' = @{ Required = @('repositoryKey', 'worktreeId'); Forbidden = @('pullRequestId', 'sourceCommit', 'expiresAtUtc') }
        pr              = @{ Required = @('repositoryKey', 'worktreeId', 'pullRequestId', 'sourceCommit', 'expiresAtUtc'); Forbidden = @() }
    }
    $rules = $scopedFields[$SourceScope]
    $baseRequired = @('schemaVersion', 'settings')
    foreach ($name in ($baseRequired + $rules.Required)) {
        if (-not $record.Contains($name)) { throw "[capability-settings-invalid] ($SourceScope) Missing required field '$name'." }
    }
    foreach ($name in $rules.Forbidden) {
        if ($record.Contains($name)) { throw "[capability-settings-invalid] ($SourceScope) Field '$name' is forbidden for this scope." }
    }
    $knownFields = [Collections.Generic.HashSet[string]]::new(
        [string[]]($baseRequired + @('repositoryKey', 'worktreeId', 'pullRequestId', 'sourceCommit', 'expiresAtUtc')),
        [StringComparer]::Ordinal)
    $topLevelIndex = 0
    foreach ($name in @($record.Keys)) {
        $topLevelIndex++
        if (-not $knownFields.Contains($name)) {
            $ref = Get-AgentRedactedFieldReference -Text $name -Position $topLevelIndex
            throw "[capability-settings-invalid] ($SourceScope) Unknown top-level field ($ref)."
        }
    }
    # ConvertFrom-Json -AsHashtable returns JSON integers as [int64] (not [int]) on this PowerShell
    # version, so every integer field below accepts both CLR widths and compares by value.
    if (($record.schemaVersion -isnot [int] -and $record.schemaVersion -isnot [long]) -or [int64]$record.schemaVersion -ne 1) {
        throw "[capability-settings-invalid] ($SourceScope) Unsupported schemaVersion."
    }
    if ($record.settings -isnot [Collections.IDictionary]) {
        throw "[capability-settings-invalid] ($SourceScope) 'settings' must be a JSON object."
    }
    $allowedSet = [Collections.Generic.HashSet[string]]::new([string[]]$AllowedCapabilities, [StringComparer]::Ordinal)
    $settings = [ordered]@{}
    $settingIndex = 0
    foreach ($name in @($record.settings.Keys)) {
        $settingIndex++
        if ($name.Length -eq 0 -or $name.Length -gt 256 -or $name -cnotmatch '^[A-Za-z][A-Za-z0-9]*$') {
            throw "[capability-settings-invalid] ($SourceScope) Malformed capability name ($(Get-AgentRedactedFieldReference -Text $name -Position $settingIndex))."
        }
        if (Test-AgentSecretShapedText -Text $name) {
            throw "[capability-settings-invalid] ($SourceScope) Capability name ($(Get-AgentRedactedFieldReference -Text $name -Position $settingIndex)) looks secret-shaped."
        }
        if (-not $allowedSet.Contains($name)) {
            throw "[capability-settings-invalid] ($SourceScope) Capability ($(Get-AgentRedactedFieldReference -Text $name -Position $settingIndex)) is not a recognized manually-selectable capability."
        }
        $value = $record.settings[$name]
        if ($value -isnot [string] -or $value -cnotin @('inherit', 'off')) {
            throw "[capability-settings-invalid] ($SourceScope) Capability '$name' has an unsupported value; only 'inherit'/'off' may be persisted."
        }
        $settings[$name] = $value
    }

    $result = [ordered]@{ SchemaVersion = 1; SourceScope = $SourceScope; Settings = $settings }
    if ($record.Contains('repositoryKey')) {
        $key = [string]$record.repositoryKey
        if ($key -notmatch '^v1:(azuredevops|github):[^:]+$') { throw "[capability-settings-invalid] ($SourceScope) repositoryKey is malformed." }
        $result.RepositoryKey = $key
    }
    if ($record.Contains('worktreeId')) {
        $worktreeId = [string]$record.worktreeId
        if ($worktreeId -cnotmatch '^[0-9a-f]{64}$') { throw "[capability-settings-invalid] ($SourceScope) worktreeId is malformed." }
        $result.WorktreeId = $worktreeId
    }
    if ($record.Contains('pullRequestId')) {
        if (($record.pullRequestId -isnot [int] -and $record.pullRequestId -isnot [long]) -or [int64]$record.pullRequestId -le 0) {
            throw "[capability-settings-invalid] ($SourceScope) pullRequestId is malformed."
        }
        $result.PullRequestId = [int]$record.pullRequestId
    }
    if ($record.Contains('sourceCommit')) {
        $sourceCommit = [string]$record.sourceCommit
        if ($sourceCommit -cnotmatch '^[0-9a-f]{40}$') { throw "[capability-settings-invalid] ($SourceScope) sourceCommit must be a full 40-hex SHA." }
        $result.SourceCommit = $sourceCommit
    }
    if ($record.Contains('expiresAtUtc')) {
        if ($record.expiresAtUtc -isnot [int] -and $record.expiresAtUtc -isnot [long]) {
            throw "[capability-settings-invalid] ($SourceScope) expiresAtUtc must be an integer epoch-seconds value."
        }
        $result.ExpiresAtUtc = [long]$record.expiresAtUtc
    }
    return $result
}

function Resolve-AgentEffectiveCapabilitySettings {
    <#
        Resolves the effective, outside-repository capability-override narrowing for one
        repository worktree + pull request, across all four logical scopes (machine, user,
        repo-worktree, pr) under the single hardened capability-overrides root. Persisted settings
        can only ever narrow an already-open capability to 'off' -- never grant one -- so scopes are
        applied broad-to-narrow and are purely additive/monotonic: once any scope turns a capability
        off, no narrower scope can turn it back on, and provenance records the broadest (first) scope
        that did so.

        A single physical settings file is shared by every role that operates in that scope (the
        layout has no role segment), so capability-name validation uses the union of every known
        role's allowedManualCapabilities; callers that need a role-specific ceiling apply
        Resolve-AgentCapabilityPolicyPartition afterward with their own role's descriptor.

        PR-scope lookup is fully deterministic from PullRequestId + the current source commit's
        first 12 hex characters -- no directory enumeration. The short SHA only selects which
        candidate FILE to open; the full sourceCommit recorded inside that file's content is what is
        actually checked for staleness, so a short-SHA collision can never silently authorize a
        narrowing that belongs to a different commit.

        Synchronous by design: every file this function reads is small (<=64KB) and local, bounded
        by the same byte/depth/element/string limits Assert-AgentCapabilityJsonRawShape already
        enforces -- the same order of local I/O this broker already performs synchronously elsewhere
        (config/descriptor/durable-state reads). This broker has no RunspacePool/bounded-worker
        infrastructure today (PR2 does not introduce one), so adding asynchronous plumbing solely for
        this resolver would be new, untested async infrastructure rather than reuse of an existing,
        bounded one; keeping this call synchronous preserves today's protocol responsiveness without
        that risk.

        Any schema, integrity, staleness, expiry, or path-safety failure on a file that DOES exist
        fails the WHOLE resolution closed (throws) rather than silently discarding just that scope --
        silently ignoring a corrupt/stale/expired narrowing record would make the effective policy
        MORE permissive than the operator's last-known-good intent, which is the one direction this
        feature must never move in unattended. A scope file that is simply absent is not an error:
        an entirely empty store resolves to empty Settings/Provenance, identical to PR1's behavior.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CurrentSourceCommit,
        # PR3-only: previews a single hypothetical scope-file edit (never persisted) by overlaying
        # it onto that ONE scope's parsed record before the normal broad-to-narrow fold runs --
        # every other scope, and the fold logic itself, is completely unchanged. This guarantees a
        # preview can never drift from the real resolver: it IS the real resolver, called with one
        # extra input. $null (every existing PR1/PR2 caller) reproduces today's behavior exactly.
        [AllowNull()][hashtable]$HypotheticalOverride
    )
    $killSwitchState = Get-AgentCapabilityOverrideKillSwitchState -RepositoryRoot $RepositoryRoot
    if ($killSwitchState.Active) {
        # Emergency operational lever (PR3): ignores every persisted override record and returns
        # ceiling-only output, tagged distinctly (KillSwitchActive) so callers can render
        # provenance as 'kill-switch' rather than silently indistinguishable from an empty store.
        # Checked first, via a cheap Test-Path-backed check, before any scope-file parsing.
        # KillSwitchExpiresAtUtc (PR3 completion) is the sentinel's own raw epoch-seconds TTL,
        # surfaced so Get-BrokerCapabilityProfile/Invoke-Profile/Invoke-Describe can put it on the
        # wire alongside KillSwitchActive.
        return @{
            Settings = [ordered]@{}; Provenance = [ordered]@{}; FileFingerprints = @()
            KillSwitchActive = $true; KillSwitchExpiresAtUtc = $killSwitchState.ExpiresAtUtc
        }
    }
    $root = Get-AgentCapabilityOverrideRoot -RepositoryRoot $RepositoryRoot
    $allowedCapabilities = [Collections.Generic.List[string]]::new()
    foreach ($knownRole in @('reviewer', 'review-handler')) {
        foreach ($name in @((Get-AgentHarnessCapabilityDescriptor -Role $knownRole).allowedManualCapabilities)) {
            if (-not $allowedCapabilities.Contains($name)) { [void]$allowedCapabilities.Add($name) }
        }
    }
    $repositoryKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $RepositoryIdentity
    $worktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $RepositoryRoot
    $repoRoot = Join-Path (Join-Path $root 'repo') (Get-AgentSha256 -Text $repositoryKey)
    $candidates = [ordered]@{
        machine         = @{ Path = (Join-Path $root 'machine.settings.v1.json'); RequireBinding = $false }
        user            = @{ Path = (Join-Path $root 'user.settings.v1.json'); RequireBinding = $false }
        'repo-worktree' = @{ Path = (Join-Path $repoRoot "$worktreeId.settings.v1.json"); RequireBinding = $true }
        pr              = @{
            Path = (Join-Path (Join-Path $repoRoot 'pr') "$PullRequestId-$($CurrentSourceCommit.Substring(0, 12)).settings.v1.json")
            RequireBinding = $true
        }
    }
    $settings = [ordered]@{}
    $provenance = [ordered]@{}
    $fingerprints = [Collections.Generic.List[hashtable]]::new()
    foreach ($scope in @('machine', 'user', 'repo-worktree', 'pr')) {
        $path = [IO.Path]::GetFullPath($candidates[$scope].Path)
        if (-not (Test-AgentPathWithin -Path $path -Root $root)) {
            throw "[capability-settings-invalid] ($scope) Resolved settings path escaped the capability-override root."
        }
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$fingerprints.Add([ordered]@{ Path = $path; Exists = $false; Size = 0; MTime = 0; Sha256 = $null })
            # No file on disk for this scope. Ordinarily a no-op continue -- but when the caller is
            # previewing a hypothetical edit AT this exact scope, an absent file behaves exactly
            # like PR2's existing "empty store" contract: an empty settings record to overlay onto,
            # not a reason to skip the scope entirely.
            if (-not ($HypotheticalOverride -and [string]$HypotheticalOverride.Scope -ceq $scope)) { continue }
            $record = [ordered]@{ Settings = [ordered]@{} }
        }
        else {
            # An existing path that is NOT a regular file (a directory, or any other non-file object)
            # must never be silently treated the same as "absent" -- that would mask an intended
            # narrowing record as if the store were empty, which is a silent WIDENING of the effective
            # ceiling. Assert-AgentTrustedFile itself rejects a non-file (PSIsContainer) below, so this
            # is deliberately only a plain existence check, not -PathType Leaf.
            try {
                $path = Assert-AgentTrustedFile -Path $path -AllowedRoot $root -Private
                $stable = Read-AgentStableFile -Path $path -MaxBytes 65536
            }
            catch [Management.Automation.ItemNotFoundException] {
                # Existed an instant ago (the Test-Path above) but vanished before validation/read could
                # complete -- a race, not a genuine absence and not malformed/corrupt content. Surface
                # the same distinct, explicitly-retryable signal Read-AgentStableFile itself raises for
                # in-flight instability, so callers (Get-BrokerCapabilityProfile) can retry once under
                # the capability-override lock instead of failing this closed as "invalid".
                throw "[stable-read-unstable] ($scope) File vanished while being validated/read."
            }
            [void]$fingerprints.Add([ordered]@{ Path = $stable.Path; Exists = $stable.Exists; Size = $stable.Size; MTime = $stable.MTime; Sha256 = $stable.Sha256 })
            $record = ConvertFrom-AgentTrustedCapabilityJson -Bytes $stable.Bytes -SourceScope $scope -AllowedCapabilities $allowedCapabilities
            if ($candidates[$scope].RequireBinding -and
                ([string]$record.RepositoryKey -cne $repositoryKey -or [string]$record.WorktreeId -cne $worktreeId)) {
                throw "[capability-settings-invalid] ($scope) Record identity binding does not match the current repository/worktree."
            }
            if ($scope -eq 'pr') {
                if ([int]$record.PullRequestId -ne $PullRequestId) {
                    throw '[capability-settings-invalid] (pr) Record pullRequestId does not match the current pull request.'
                }
                if ([string]$record.SourceCommit -cne $CurrentSourceCommit) {
                    throw '[capability-settings-stale] Persisted PR-scope override no longer matches the current source commit.'
                }
                if ([long]$record.ExpiresAtUtc -le (ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow))) {
                    throw '[capability-settings-expired] Persisted PR-scope override has expired.'
                }
            }
        }
        if ($HypotheticalOverride -and [string]$HypotheticalOverride.Scope -ceq $scope) {
            $previewCapability = [string]$HypotheticalOverride.Capability
            if ([string]$HypotheticalOverride.Action -ceq 'off') { $record.Settings[$previewCapability] = 'off' }
            else { $record.Settings.Remove($previewCapability) }
        }
        foreach ($name in @($record.Settings.Keys)) {
            if ([string]$record.Settings[$name] -cne 'off') { continue }
            if (-not $settings.Contains($name)) {
                $settings[$name] = 'off'
                $provenance[$name] = $scope
            }
        }
    }
    return @{
        Settings = $settings; Provenance = $provenance; FileFingerprints = @($fingerprints.ToArray())
        KillSwitchActive = $false; KillSwitchExpiresAtUtc = $null
    }
}

function Resolve-AgentCapabilityPolicyPartition {
    <#
        Pure set-math shared by every caller that needs to apply a persisted narrowing to a role's
        capability ceiling (the broker's describe/profile builder and, at child startup, the
        independent re-verification in Enter-AgentManualDispatchStartup): turn every capability the
        operator persisted as 'off' from an active capability into a mandatory deny. Persisted
        settings can only ever narrow this ceiling, never widen it -- a name that is not already an
        active capability is a no-op here, and 'inherit' entries are already absent from
        PersistedNarrowing by construction (Resolve-AgentEffectiveCapabilitySettings only ever
        returns 'off' entries). Delegation/widening (checked-in delegation policy, ephemeral grants)
        is out of scope for this change and intentionally not modeled here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$RoleDescriptor,
        [Parameter(Mandatory)][hashtable]$PersistedNarrowing
    )
    $capabilities = [Collections.Generic.List[string]]::new([string[]]@($RoleDescriptor.capabilities | Sort-Object -Unique))
    $mandatoryDenies = [Collections.Generic.List[string]]::new([string[]]@($RoleDescriptor.mandatoryDenies | Sort-Object -Unique))
    foreach ($name in @($PersistedNarrowing.Keys | Where-Object { [string]$PersistedNarrowing[$_] -ceq 'off' })) {
        if ($capabilities.Contains($name)) {
            [void]$capabilities.Remove($name)
            if (-not $mandatoryDenies.Contains($name)) { [void]$mandatoryDenies.Add($name) }
        }
    }
    return @{ capabilities = @($capabilities | Sort-Object -Unique); mandatoryDenies = @($mandatoryDenies | Sort-Object -Unique) }
}

function Enter-AgentCapabilityOverrideLock {
    <#
        Same exclusive, FileShare.None-backed advisory file lock idiom as Enter-AgentWorkLease/
        Enter-AgentDurableStateLock, against one lock file at the root of the capability-override
        store. No writer takes this lock yet in this change (TUI edit/reset/kill switch is PR3);
        Enter-AgentManualDispatchStartup is its first caller, holding it across live re-verification
        through the ready/proceed handshake so no future cooperating writer can narrow settings out
        from under an in-flight startup decision.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [ValidateRange(0, 30000)][int]$TimeoutMilliseconds = 2000,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    $root = Get-AgentCapabilityOverrideRoot -RepositoryRoot $RepositoryRoot
    return Enter-AgentExclusiveFile -Path (Join-Path $root 'capability-overrides.lock') `
        -ContentionReason capability-override-contended -TimeoutMilliseconds $TimeoutMilliseconds `
        -CancellationToken $CancellationToken -Metadata @{}
}

# ---------------------------------------------------------------------------
# TUI edit/diff/reset UX + emergency kill switch (PR3): the first, and only, supported writer for
# the outside-repository capability-override store PR2 introduced. Every mutation goes through
# Set-AgentCapabilityOverrideSetting (atomic temp-write-then-replace, one scope file at a time) or
# Enable-/Disable-AgentCapabilityOverrideKillSwitch (a separate owner-private sentinel, deliberately
# outside the versioned v1 store so a future schema bump never orphans it). Callers are required
# to hold Enter-AgentCapabilityOverrideLock for the same RepositoryRoot before calling any of these,
# exactly like Write-AgentDurableState is always called under Enter-AgentDurableStateLock, so every
# supported writer and every reader that must observe a consistent snapshot
# (Resolve-AgentEffectiveCapabilitySettings via Get-BrokerCapabilityProfile,
# Enter-AgentManualDispatchStartup) serializes through the identical single lock.
# ---------------------------------------------------------------------------

function Get-AgentDefaultCapabilityOverrideKillSwitchRoot {
    <#
        A dedicated root, sibling to (never nested under) the versioned 'capability-overrides\v1'
        store -- deliberately its own independently-created-and-hardened directory rather than the
        literal filesystem parent of the v1 root. That parent can already exist as a side effect of
        Get-AgentCapabilityOverrideRoot's New-Item -Force creating 'v1' underneath it, in which case
        Resolve-AgentTrustedRoot would see it as pre-existing and skip its own one-time
        ACL-hardening branch, silently leaving it on whatever permissions it happened to inherit. A
        brand-new path nothing else ever creates has no such history: the first
        Enable-AgentCapabilityOverrideKillSwitch call is guaranteed to be the call that creates it,
        so Resolve-AgentTrustedRoot's hardening branch always actually runs. This still satisfies
        "outside the v1 child scope": a future schema version bump to the override store itself
        never touches this path.
    #>
    if ($IsWindows) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is required to resolve the capability-override kill-switch root on Windows.' }
        return (Join-Path (Join-Path $env:LOCALAPPDATA 'DevPilot') 'capability-overrides.disabled')
    }
    $base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path (Join-Path $HOME '.local') 'state' }
    return (Join-Path (Join-Path $base 'devpilot') 'capability-overrides.disabled')
}

function Get-AgentCapabilityOverrideKillSwitchDisallowedRoots {
    [Collections.Generic.List[string]]::new([string[]]@(
            (Get-AgentDefaultDurableStateRoot), (Get-AgentDefaultLeaseRoot), (Get-AgentDefaultWatchStateRoot),
            (Get-AgentDefaultCapabilityOverrideRoot)))
}

function Read-AgentCapabilityOverrideKillSwitchSentinel {
    <#
        Single-source-of-truth sentinel parser/validator shared by
        Get-AgentCapabilityOverrideKillSwitchState (read path) and
        Enable-AgentCapabilityOverrideKillSwitch (write path) -- issue #105 PR3 completion. Neither
        caller re-implements its own parsing, so the two can never disagree about what makes a
        sentinel valid.

        Returns @{ Status = 'absent' | 'active' | 'expired' | 'malformed'; ExpiresAtUtc = [Nullable[long]] }:
          - 'absent': no sentinel file exists.
          - 'active': a well-formed, non-expired sentinel; ExpiresAtUtc is its raw epoch-seconds value.
          - 'expired': a well-formed but expired sentinel -- ALREADY DELETED by this call (the same
            cleanup-on-observation behavior this function has always had), so no caller ever sees a
            stale file after this returns.
          - 'malformed': the file exists but fails validation (unparseable JSON, a non-object body,
            a field outside the exact allowed set, a missing/wrong schemaVersion, or a missing/
            non-numeric enabledAtUtc/expiresAtUtc). Never deleted here -- a malformed sentinel is
            left in place for an operator to inspect rather than silently discarded, and its very
            existence is what makes Enable-AgentCapabilityOverrideKillSwitch fail closed with an
            explicit error instead of guessing at a migration. A missing expiresAtUtc is
            deliberately 'malformed', never 'active' with a null expiry -- a kill switch can never
            be indefinitely active by omission (issue #105 PR3 review).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Status = 'absent'; ExpiresAtUtc = $null } }
    $trustedPath = Assert-AgentTrustedFile -Path $Path -AllowedRoot $Root -ExpectedPath $Path -Private
    $stable = Read-AgentStableFile -Path $trustedPath -MaxBytes 65536
    if (-not $stable.Exists) { return @{ Status = 'absent'; ExpiresAtUtc = $null } }
    try {
        $sentinel = [Text.Encoding]::UTF8.GetString($stable.Bytes) | ConvertFrom-Json -AsHashtable -Depth 5
    }
    catch { return @{ Status = 'malformed'; ExpiresAtUtc = $null } }
    if ($sentinel -isnot [Collections.IDictionary]) { return @{ Status = 'malformed'; ExpiresAtUtc = $null } }
    $allowedFields = [string[]]@('schemaVersion', 'enabledAtUtc', 'expiresAtUtc')
    foreach ($key in @($sentinel.Keys)) {
        if ($allowedFields -cnotcontains $key) { return @{ Status = 'malformed'; ExpiresAtUtc = $null } }
    }
    if (-not $sentinel.Contains('schemaVersion') -or -not $sentinel.Contains('enabledAtUtc') -or
        -not $sentinel.Contains('expiresAtUtc')) {
        return @{ Status = 'malformed'; ExpiresAtUtc = $null }
    }
    $schemaVersionRaw = $sentinel['schemaVersion']
    if (($schemaVersionRaw -isnot [double] -and $schemaVersionRaw -isnot [long] -and $schemaVersionRaw -isnot [int]) -or
        [long][double]$schemaVersionRaw -ne 1) {
        return @{ Status = 'malformed'; ExpiresAtUtc = $null }
    }
    $enabledAtUtcRaw = $sentinel['enabledAtUtc']
    $expiresAtUtcRaw = $sentinel['expiresAtUtc']
    if ($enabledAtUtcRaw -isnot [double] -and $enabledAtUtcRaw -isnot [long] -and $enabledAtUtcRaw -isnot [int]) {
        return @{ Status = 'malformed'; ExpiresAtUtc = $null }
    }
    if ($expiresAtUtcRaw -isnot [double] -and $expiresAtUtcRaw -isnot [long] -and $expiresAtUtcRaw -isnot [int]) {
        return @{ Status = 'malformed'; ExpiresAtUtc = $null }
    }
    $expiresAtUtc = [long][double]$expiresAtUtcRaw
    if ($expiresAtUtc -le (ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow))) {
        Assert-AgentPathHasNoLinks -Path $Path
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return @{ Status = 'expired'; ExpiresAtUtc = $null }
    }
    return @{ Status = 'active'; ExpiresAtUtc = $expiresAtUtc }
}

function Get-AgentCapabilityOverrideKillSwitchState {
    <#
        Emergency operational lever (PR3): existence of a VALID sentinel file is authoritative for
        Active -- content is parsed/validated (never merely tested for existence) via the shared
        Read-AgentCapabilityOverrideKillSwitchSentinel, which also enforces the sentinel's TTL
        (default one hour -- see Enable-AgentCapabilityOverrideKillSwitch's TtlSeconds), so a
        forgotten "ignore local narrowing overrides" toggle can never silently persist forever
        (issue #105 PR3 review). A missing/invalid schemaVersion, a disallowed field, or a missing
        TTL makes the sentinel 'malformed', which this treats as fail-closed INACTIVE -- never as
        indefinitely active (issue #105 PR3 completion). This never throws on a malformed sentinel
        (unlike Enable-AgentCapabilityOverrideKillSwitch's explicit rejection of the same
        condition): describe/profile/capability resolution must keep working even with a corrupt
        local sentinel. An expired (but well-formed) sentinel is cleaned up (deleted) the first
        time anything observes it past expiry, rather than left for a separate janitor to find --
        safe because every caller of this helper (Test-AgentCapabilityOverrideKillSwitch,
        Resolve-AgentEffectiveCapabilitySettings, Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc)
        is only ever invoked while the caller already holds Enter-AgentCapabilityOverrideLock,
        exactly like every writer in this module. Checked via a cheap Test-Path against the
        (possibly still nonexistent) kill-switch root FIRST, so a machine that has never toggled
        the kill switch never pays the cost of, or triggers, ACL/symlink hardening on every
        describe/profile call.

        Shared, single-source-of-truth sentinel reader (issue #105 PR3 completion) behind the
        boolean Test-AgentCapabilityOverrideKillSwitch gate, Resolve-AgentEffectiveCapabilitySettings's
        KillSwitchExpiresAtUtc wire field, and Invoke-SetKillSwitch's response (via
        Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc) -- exactly one place parses/expires the
        sentinel, so none of those three callers can ever disagree about whether the lever is
        active or when it expires. Returns @{ Active = [bool]; ExpiresAtUtc = [Nullable[long]] };
        ExpiresAtUtc is the raw epoch-seconds sentinel value (only meaningful while Active is
        $true), never reformatted here -- callers decide their own wire/return representation.
    #>
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
    if (-not (Test-Path -LiteralPath $default -PathType Container)) { return @{ Active = $false; ExpiresAtUtc = $null } }
    $root = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $RepositoryRoot `
        -DisallowedRoots (Get-AgentCapabilityOverrideKillSwitchDisallowedRoots)
    $sentinel = Read-AgentCapabilityOverrideKillSwitchSentinel -Root $root -Path (Join-Path $root 'sentinel.json')
    if ($sentinel.Status -eq 'active') { return @{ Active = $true; ExpiresAtUtc = $sentinel.ExpiresAtUtc } }
    return @{ Active = $false; ExpiresAtUtc = $null }
}

function Test-AgentCapabilityOverrideKillSwitch {
    <#
        Boolean gate wrapping Get-AgentCapabilityOverrideKillSwitchState -- see that function for
        the sentinel/TTL/cleanup semantics this preserves unchanged.
    #>
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    return (Get-AgentCapabilityOverrideKillSwitchState -RepositoryRoot $RepositoryRoot).Active
}

function Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc {
    <#
        Broker-facing accessor for Invoke-SetKillSwitch's response (issue #105 PR3 completion): the
        one kill-switch caller that is NOT already threaded through
        Resolve-AgentEffectiveCapabilitySettings's Override object, because that resolver is
        PR-scoped (requires a PullRequestId/CurrentSourceCommit binding) and set-kill-switch is
        deliberately not bound to any one pull request. Returns the same raw epoch-seconds value
        (or $null when inactive) Resolve-AgentEffectiveCapabilitySettings itself would report via
        KillSwitchExpiresAtUtc for the identical shared sentinel state, so a caller can never
        observe a different answer than the profile/describe path would for the same instant.
        Caller must hold Enter-AgentCapabilityOverrideLock, exactly like every other kill-switch
        primitive in this module.
    #>
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    return (Get-AgentCapabilityOverrideKillSwitchState -RepositoryRoot $RepositoryRoot).ExpiresAtUtc
}

function Enable-AgentCapabilityOverrideKillSwitch {
    <#
        Idempotent: enabling an already-active kill switch is a no-op, never a second write, and
        never restarts/extends the already-running TTL window -- it returns that active sentinel's
        OWN actual expiry (issue #105 PR3 completion), not a newly-computed one, so a caller can
        never be told a fresher expiry than what is really persisted.

        Reads and validates the existing sentinel under the caller-held
        Enter-AgentCapabilityOverrideLock via the same shared
        Read-AgentCapabilityOverrideKillSwitchSentinel Get-AgentCapabilityOverrideKillSwitchState
        uses, before ever deciding whether to write (issue #105 PR3 completion):
          - 'active'    -> idempotent no-op; returns the sentinel's real Active/ExpiresAtUtc.
          - 'expired'   -> the shared reader has ALREADY removed the stale file; a fresh sentinel is
                           written atomically, exactly as if none had existed.
          - 'absent'    -> a fresh sentinel is written atomically.
          - 'malformed' -> fails closed with an explicit error instead of guessing at a migration or
                           silently overwriting -- there is no documented schema-migration rule for
                           this sentinel (schemaVersion has only ever been 1), so an operator must
                           resolve it (typically by deleting the bad file) rather than have this
                           silently replace or silently honor it. A missing TTL is one of the
                           conditions this rejects; it is never treated as "active forever".

        Atomic owner-private create via the same temp-write-then-replace idiom every other writer
        in this store uses (Write-AgentFileThrough + Install-AgentFileAtomic) -- no partial file is
        ever observable at the final path. Caller must hold Enter-AgentCapabilityOverrideLock.
        TtlSeconds (issue #105 PR3 review): the emergency lever is short-lived by design -- default
        one hour -- so it can never be silently left on indefinitely; see
        Get-AgentCapabilityOverrideKillSwitchState for the corresponding enforcement/cleanup.

        Returns @{ Active = $true; ExpiresAtUtc = [long] } on success (idempotent or freshly
        written); throws [kill-switch-invalid] on a malformed pre-existing sentinel.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [ValidateRange(60, 86400)][int]$TtlSeconds = 3600
    )
    $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
    $root = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $RepositoryRoot `
        -DisallowedRoots (Get-AgentCapabilityOverrideKillSwitchDisallowedRoots) -Create
    $path = Join-Path $root 'sentinel.json'
    $existing = Read-AgentCapabilityOverrideKillSwitchSentinel -Root $root -Path $path
    if ($existing.Status -eq 'active') { return @{ Active = $true; ExpiresAtUtc = $existing.ExpiresAtUtc } }
    if ($existing.Status -eq 'malformed') {
        throw "[kill-switch-invalid] Existing kill-switch sentinel at '$path' failed validation (unexpected schema, disallowed field, or missing/invalid TTL); refusing to enable. Remove the file to recover."
    }
    $enabledAtUtc = [DateTime]::UtcNow
    $expiresAtUtcValue = ConvertTo-AgentCanonicalEpochSeconds $enabledAtUtc.AddSeconds($TtlSeconds)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-AgentCanonicalJson ([ordered]@{
                    schemaVersion = 1
                    enabledAtUtc = (ConvertTo-AgentCanonicalEpochSeconds $enabledAtUtc)
                    expiresAtUtc = $expiresAtUtcValue
                })))
    $tempPath = Join-Path $root "sentinel.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
    try {
        Write-AgentFileThrough -Path $tempPath -Bytes $bytes
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($tempPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        Install-AgentFileAtomic -Source $tempPath -Destination $path
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
    return @{ Active = $true; ExpiresAtUtc = $expiresAtUtcValue }
}

function Disable-AgentCapabilityOverrideKillSwitch {
    <#
        Idempotent: disabling an already-disabled (or never-enabled) kill switch is a no-op.
        Caller must hold Enter-AgentCapabilityOverrideLock.
    #>
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $default = Get-AgentDefaultCapabilityOverrideKillSwitchRoot
    if (-not (Test-Path -LiteralPath $default -PathType Container)) { return }
    $root = Resolve-AgentTrustedRoot -Path $default -Kind capability-overrides -RepositoryRoot $RepositoryRoot `
        -DisallowedRoots (Get-AgentCapabilityOverrideKillSwitchDisallowedRoots)
    $path = Join-Path $root 'sentinel.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    Assert-AgentPathHasNoLinks -Path $path
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
}

function Set-AgentCapabilityOverrideSetting {
    <#
        THE atomic writer PR3 introduces: the only supported way any code narrows or resets a
        persisted capability-override entry. Caller must already hold
        Enter-AgentCapabilityOverrideLock for the same RepositoryRoot -- this function does not take
        the lock itself, mirroring every other write-adjacent primitive in this module (e.g.
        Write-AgentDurableState, always called from inside a caller-held lock).

        'off' upserts the single named capability as 'off' in the selected scope's settings file.
        'inherit' removes that single entry -- 'inherit' is never itself persisted as a settings
        value (PR2's schema never accepted it as one). If removing (or never having added) any
        entries leaves the scope's settings object empty, the file itself is deleted instead of
        being written back as a near-empty residue record, atomically and safely, so a
        never-edited scope and a fully-reset scope are indistinguishable on disk -- exactly like
        PR2's existing "absent file means inherit" contract.

        Every write is round-trip validated (re-parsed through the identical trusted reader a
        future caller will use) before ever touching disk, and lands via the same
        temp-file-in-the-same-directory + flush + atomic replace/rename idiom as every other write
        in this module -- no partial file is ever observable at the final path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CurrentSourceCommit,
        [Parameter(Mandatory)][ValidateSet('machine', 'user', 'repo-worktree', 'pr')][string]$Scope,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')][string]$Capability,
        [Parameter(Mandatory)][ValidateSet('off', 'inherit')][string]$Action,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedCapabilities,
        [ValidateRange(60, 31536000)][int]$PrScopeTtlSeconds = 2592000
    )
    if ($AllowedCapabilities -cnotcontains $Capability) {
        throw "[narrowing-invalid] Capability '$Capability' is not a recognized manually-selectable capability."
    }
    $root = Get-AgentCapabilityOverrideRoot -RepositoryRoot $RepositoryRoot
    $repositoryKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $RepositoryIdentity
    $worktreeId = Get-AgentWorktreeIdentity -RepositoryRoot $RepositoryRoot
    $repoRoot = Join-Path (Join-Path $root 'repo') (Get-AgentSha256 -Text $repositoryKey)
    $path = switch ($Scope) {
        'machine' { Join-Path $root 'machine.settings.v1.json' }
        'user' { Join-Path $root 'user.settings.v1.json' }
        'repo-worktree' { Join-Path $repoRoot "$worktreeId.settings.v1.json" }
        'pr' { Join-Path (Join-Path $repoRoot 'pr') "$PullRequestId-$($CurrentSourceCommit.Substring(0, 12)).settings.v1.json" }
    }
    $path = [IO.Path]::GetFullPath($path)
    if (-not (Test-AgentPathWithin -Path $path -Root $root)) {
        throw '[narrowing-invalid] Resolved settings path escaped the capability-override root.'
    }
    $parent = Split-Path $path -Parent
    # First-write dynamic parent creation (issue #105 PR3 review): repo-worktree/pr scopes create
    # nested directories ('repo\<hash>' and 'repo\<hash>\pr') lazily, on the first override ever
    # written for that repository/worktree/PR -- unlike the store root itself (hardened once by
    # Resolve-AgentTrustedRoot), nothing validated these deeper, dynamically-created path segments
    # before now. Checked for a planted link/junction/reparse point both BEFORE creating (catches
    # an ancestor an attacker already planted) and AFTER (catches one swapped in during the TOCTOU
    # window the New-Item call itself opens), mirroring Resolve-AgentTrustedRoot's own
    # check-create-recheck idiom exactly.
    Assert-AgentPathHasNoLinks -Path $parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($parent, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
    }
    Assert-AgentPathHasNoLinks -Path $parent
    $existingSettings = [ordered]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $trustedPath = Assert-AgentTrustedFile -Path $path -AllowedRoot $root -Private
        $stable = Read-AgentStableFile -Path $trustedPath -MaxBytes 65536
        if ($stable.Exists) {
            $existingRecord = ConvertFrom-AgentTrustedCapabilityJson -Bytes $stable.Bytes -SourceScope $Scope -AllowedCapabilities $AllowedCapabilities
            foreach ($key in @($existingRecord.Settings.Keys)) { $existingSettings[$key] = $existingRecord.Settings[$key] }
        }
    }
    if ($Action -ceq 'off') { $existingSettings[$Capability] = 'off' } else { $existingSettings.Remove($Capability) }

    if ($existingSettings.Count -eq 0) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Assert-AgentPathHasNoLinks -Path $path
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        return
    }
    $record = [ordered]@{ schemaVersion = 1; settings = $existingSettings }
    if ($Scope -eq 'repo-worktree' -or $Scope -eq 'pr') {
        $record.repositoryKey = $repositoryKey
        $record.worktreeId = $worktreeId
    }
    if ($Scope -eq 'pr') {
        $record.pullRequestId = $PullRequestId
        $record.sourceCommit = $CurrentSourceCommit
        $record.expiresAtUtc = (ConvertTo-AgentCanonicalEpochSeconds ([DateTime]::UtcNow.AddSeconds($PrScopeTtlSeconds)))
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Compress -Depth 8))
    # Round-trip validated before ever touching disk: the bytes about to be written must themselves
    # parse back through the exact same trusted parser a future reader will use, with the identical
    # settings -- catches a schema/serialization mismatch here, synchronously, rather than
    # persisting a file this store's own reader could later reject or misinterpret.
    $roundTrip = ConvertFrom-AgentTrustedCapabilityJson -Bytes $bytes -SourceScope $Scope -AllowedCapabilities $AllowedCapabilities
    if ((ConvertTo-AgentCanonicalJson $roundTrip.Settings) -cne (ConvertTo-AgentCanonicalJson $existingSettings)) {
        throw '[narrowing-invalid] Serialized settings failed round-trip validation.'
    }
    $tempPath = Join-Path $parent ("{0}.tmp-{1}-{2}" -f (Split-Path $path -Leaf), $PID, ([Guid]::NewGuid().ToString('N')))
    try {
        Write-AgentFileThrough -Path $tempPath -Bytes $bytes
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($tempPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        Install-AgentFileAtomic -Source $tempPath -Destination $path
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Enter-AgentManualDispatchStartup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][hashtable]$DurableContext,
        [Parameter(Mandatory)][string]$LeaseRoot,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [Parameter(Mandatory)][string]$EventLogPath,
        [Parameter(Mandatory)][hashtable]$BoundCapabilities
    )
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
    $policyIdentity = if ($manifest.policy -is [Collections.IDictionary] -and
        $manifest.policy.Contains('repositoryIdentity')) {
        $manifest.policy['repositoryIdentity']
    } else { $null }
    if ($policyIdentity -is [Collections.IDictionary] -and
        $policyIdentity.Contains('verifiedAtUtc') -and
        $policyIdentity['verifiedAtUtc'] -is [DateTime]) {
        $policyIdentity['verifiedAtUtc'] =
            $policyIdentity['verifiedAtUtc'].ToUniversalTime().ToString('o')
    }
    # Same module, no cross-module import needed: the child re-derives its own ceiling from the
    # identical checked-in descriptor the broker's Get-RoleDescriptor also reads (single source of
    # truth), rather than trusting anything the broker sent over the wire (ANT-2).
    $harnessRole = Get-AgentHarnessCapabilityDescriptor -Role $Role
    $requiredDeny = $harnessRole.delegableDefaultOff
    $allowedCapabilities = $harnessRole.allowedManualCapabilities
    $capabilities = @($manifest.policy.capabilities)
    $mandatoryDenies = @($manifest.policy.mandatoryDenies)
    $boundNames = @($BoundCapabilities.Keys)
    $actualCapabilities = @($boundNames | Where-Object { [bool]$BoundCapabilities[$_] } | Sort-Object -Unique)
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.role -cne $Role -or
        [string]$manifest.policy.role -cne $Role -or
        [string]$manifest.dispatchId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $mandatoryDenies -cnotcontains $requiredDeny -or
        @($capabilities | Where-Object { $mandatoryDenies -ccontains $_ }).Count -gt 0 -or
        @($capabilities | Where-Object { $allowedCapabilities -cnotcontains $_ }).Count -gt 0 -or
        @($boundNames | Where-Object { ($_ -cnotin $allowedCapabilities) -and ($_ -cnotin $mandatoryDenies) }).Count -gt 0 -or
        @($mandatoryDenies | Where-Object {
                -not $BoundCapabilities.ContainsKey($_) -or [bool]$BoundCapabilities[$_]
            }).Count -gt 0 -or
        (ConvertTo-AgentCanonicalJson @($actualCapabilities)) -cne
            (ConvertTo-AgentCanonicalJson @($capabilities | Sort-Object -Unique))) {
        throw '[launch-failed] Manual dispatch manifest policy is malformed or inconsistent.'
    }
    $policy = Get-AgentCanonicalDigest -InputObject $manifest.policy
    if ($policy -cne [string]$manifest.capabilityPolicyDigest) {
        throw '[policy-changed] Manual dispatch policy digest does not match its snapshot.'
    }
    # The pre-narrowing ceiling is NOT independently re-derived here -- unlike allowedCapabilities/
    # requiredDeny (read fresh from this same module's own Get-AgentHarnessCapabilityDescriptor),
    # the broker's per-repo role descriptor (its configured capabilities/mandatoryDenies before any
    # override narrowing) lives only in the broker's own config file; this child process has no
    # independent copy of it to compare against. ceilingCapabilities/ceilingMandatoryDenies are
    # therefore wire-supplied, exactly like capabilities/mandatoryDenies above -- but they are not
    # trusted blindly: every entry is constrained to lie within the shared maximum descriptor
    # (allowedCapabilities/requiredDeny, re-derived independently just above), the already-narrowed
    # capabilities/mandatoryDenies must be exactly reachable from this ceiling by narrowing alone
    # (never wider, and any deny not already on the ceiling must have come from a ceiling
    # capability), and the whole policy object -- ceiling included -- is bound to
    # manifest.capabilityPolicyDigest and re-verified live under the capability-override lock below.
    # The manifest file itself is written by the broker into a path this child only ever reads
    # through Assert-AgentTrustedFile-style protections and the dedicated startupPipe handshake, so
    # a party that could forge ceilingCapabilities would already have to be inside that trust
    # boundary.
    $ceilingCapabilities = @($manifest.policy.ceilingCapabilities)
    $ceilingMandatoryDenies = @($manifest.policy.ceilingMandatoryDenies)
    if ($ceilingMandatoryDenies -cnotcontains $requiredDeny -or
        @($ceilingCapabilities | Where-Object { $ceilingMandatoryDenies -ccontains $_ }).Count -gt 0 -or
        @($ceilingCapabilities | Where-Object { $allowedCapabilities -cnotcontains $_ }).Count -gt 0 -or
        @($capabilities | Where-Object { $ceilingCapabilities -cnotcontains $_ }).Count -gt 0 -or
        @($mandatoryDenies | Where-Object {
                $ceilingMandatoryDenies -cnotcontains $_ -and $ceilingCapabilities -cnotcontains $_
            }).Count -gt 0) {
        throw '[launch-failed] Manual dispatch manifest ceiling policy is malformed or inconsistent.'
    }
    $expectedRepositoryKey = Get-AgentRepositoryIdentityKey -RepositoryIdentity $RepositoryIdentity
    if ([string]$manifest.repositoryKey -cne $expectedRepositoryKey) {
        throw '[repository-mismatch] Manual dispatch identity changed.'
    }
    $prId = [int]$manifest.pullRequestId
    $lease = $null
    $stateLock = $null
    $capabilityLock = $null
    try {
        $lease = Enter-AgentWorkLease -LeaseRoot $LeaseRoot -RepositoryIdentity $RepositoryIdentity `
            -PullRequestId $prId -Role $Role -TimeoutMilliseconds 2000
        if (-not $lease.Acquired) { throw "[already-running] $($lease.Reason)" }
        $stateLock = Enter-AgentDurableStateLock -Context $DurableContext -TimeoutMilliseconds 2000
        if (-not $stateLock.Acquired) { throw "[already-running] $($stateLock.Reason)" }
        Repair-AgentDurableState -Context $DurableContext
        if ($Role -eq 'reviewer') {
            $records = Get-AgentDurableRecords -Context $DurableContext
            if (Test-AgentReviewerDeliveryPending -Records $records -PullRequestId $prId `
                    -SourceCommit ([string]$manifest.prStateFingerprintSourceCommit)) {
                throw '[delivery-pending] Reviewer delivery is already pending for this source commit.'
            }
        }

        $runtimeRoot = [IO.Path]::GetFullPath([string]$manifest.runtimeRoot)
        $promptPath = [IO.Path]::GetFullPath([string]$manifest.operatorPromptPath)
        if (-not (Test-AgentPathWithin -Path $promptPath -Root $runtimeRoot) -or
            ((Get-Item -LiteralPath $promptPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '[prompt-invalid] Operator prompt path is not protected.'
        }
        $promptStream = [IO.FileStream]::new($promptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            if ($promptStream.Length -gt 4096) { throw '[prompt-invalid] Operator prompt byte limit exceeded.' }
            $promptBytes = [byte[]]::new([int]$promptStream.Length)
            [void]$promptStream.Read($promptBytes, 0, $promptBytes.Length)
        }
        finally { $promptStream.Dispose() }
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $prompt = Test-AgentOperatorPrompt -Prompt ($strictUtf8.GetString($promptBytes))
        Remove-Item -LiteralPath $promptPath -Force -ErrorAction Stop
        if (-not $IsWindows -and (Test-Path -LiteralPath $promptPath)) {
            throw '[prompt-invalid] Operator prompt cleanup failed.'
        }

        # Decisive enforcement boundary (§5): hold the same lock every capability-override writer
        # will take (PR3+) across the entire remaining ready/proceed exchange, so no cooperating
        # writer can narrow settings out from under a startup decision already in flight. A
        # non-cooperative write that bypasses this lock is outside the trust boundary (ANT-1/ANT-2)
        # but is still caught fail-closed by the live equality check below.
        $capabilityLock = Enter-AgentCapabilityOverrideLock -RepositoryRoot $RepositoryRoot -TimeoutMilliseconds 2000
        if (-not $capabilityLock.Acquired) { throw "[already-running] $($capabilityLock.Reason)" }
        $liveOverride = Resolve-AgentEffectiveCapabilitySettings -RepositoryIdentity $RepositoryIdentity `
            -RepositoryRoot $RepositoryRoot -PullRequestId $prId `
            -CurrentSourceCommit ([string]$manifest.prStateFingerprintSourceCommit)
        $livePartition = Resolve-AgentCapabilityPolicyPartition `
            -RoleDescriptor ([hashtable]@{ capabilities = $ceilingCapabilities; mandatoryDenies = $ceilingMandatoryDenies }) `
            -PersistedNarrowing $liveOverride.Settings
        $livePolicy = [ordered]@{
            schemaVersion = 1; repositoryIdentity = $manifest.policy.repositoryIdentity; role = $Role
            capabilities = $livePartition.capabilities; mandatoryDenies = $livePartition.mandatoryDenies
            ceilingCapabilities = @($ceilingCapabilities | Sort-Object -Unique)
            ceilingMandatoryDenies = @($ceilingMandatoryDenies | Sort-Object -Unique)
            configSnapshotSha256 = [string]$manifest.policy.configSnapshotSha256
        }
        $liveDigest = Get-AgentCanonicalDigest -InputObject $livePolicy
        if ($liveDigest -cne [string]$manifest.capabilityPolicyDigest -or
            (ConvertTo-AgentCanonicalJson @($livePartition.capabilities    | Sort-Object -Unique)) -cne
                (ConvertTo-AgentCanonicalJson @($capabilities    | Sort-Object -Unique)) -or
            (ConvertTo-AgentCanonicalJson @($livePartition.mandatoryDenies | Sort-Object -Unique)) -cne
                (ConvertTo-AgentCanonicalJson @($mandatoryDenies | Sort-Object -Unique))) {
            throw '[policy-changed] Live capability settings no longer match the dispatch manifest.'
        }

        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', [string]$manifest.startupPipe,
            [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
        try {
            $pipe.Connect(10000)
            $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
            $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
            $writer.AutoFlush = $true
            $ready = [ordered]@{
                schemaVersion = 1; operation = 'ready'; dispatchId = [string]$manifest.dispatchId
                processId = $PID; leaseKeyHash = $lease.KeyHash; eventLogPath = [IO.Path]::GetFullPath($EventLogPath)
                boundCapabilities = $actualCapabilities
                enforcedDenies = @($mandatoryDenies | Sort-Object -Unique)
            }
            $writer.WriteLine((ConvertTo-AgentCanonicalJson $ready))
            $reply = $reader.ReadLine() | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ([string]$reply.operation -cne 'proceed' -or [string]$reply.dispatchId -cne [string]$manifest.dispatchId) {
                throw '[launch-failed] Broker did not authorize startup.'
            }
        }
        finally {
            if ($pipe) { $pipe.Dispose() }
            # Released the instant the ready/proceed exchange concludes -- success or throw -- never
            # held for the remainder of the function (cancellation-binding validation,
            # $script:AgentManualAuthorities bookkeeping), since only this window needs to be
            # race-free against a cooperating settings writer.
            if ($capabilityLock -and $capabilityLock.Acquired) { Exit-AgentLock $capabilityLock.Stream; $capabilityLock.Acquired = $false }
        }

        $executionKey = Get-AgentExecutionKey -RepositoryIdentity $RepositoryIdentity -PullRequestId $prId -Role $Role
        $runtimeRoot = [IO.Path]::GetFullPath([string]$manifest.runtimeRoot)
        $cancelPath = [IO.Path]::GetFullPath([string]$manifest.cancellationRequestPath)
        $cancelAckPath = [IO.Path]::GetFullPath([string]$manifest.cancellationAcknowledgementPath)
        $cancelNonce = [string]$manifest.cancellationNonce
        if ($cancelNonce -notmatch '^[0-9a-f]{36}$' -or
            -not (Test-AgentPathWithin -Path $cancelPath -Root $runtimeRoot) -or
            -not (Test-AgentPathWithin -Path $cancelAckPath -Root $runtimeRoot) -or
            (Split-Path $cancelPath -Leaf) -cne 'cancel.requested.json' -or
            (Split-Path $cancelAckPath -Leaf) -cne 'cancel.acknowledged.json') {
            throw '[launch-failed] Manual dispatch cancellation binding is malformed.'
        }
        $script:AgentManualAuthorities[$executionKey] = @{
            Lease = $lease; StateLock = $stateLock; KeyHash = $lease.KeyHash
            OperatorContext = $prompt.Text
            DispatchId = [string]$manifest.dispatchId
            CancellationNonce = $cancelNonce
            CancellationRequestPath = $cancelPath
            CancellationAcknowledgementPath = $cancelAckPath
        }
        return $prompt.Text
    }
    catch {
        try {
            $message = $_.Exception.Message
            $code = if ($message -match '^\[([a-z-]+)\]') { $Matches[1] } else { 'launch-failed' }
            $detail = if ($code -eq 'already-running' -and
                $message -match '^\[already-running\]\s+(lease-contended|state-contended|capability-override-contended)$') {
                $Matches[1]
            }
            else { '' }
            $failurePipe = [IO.Pipes.NamedPipeClientStream]::new('.', [string]$manifest.startupPipe,
                [IO.Pipes.PipeDirection]::Out, [IO.Pipes.PipeOptions]::Asynchronous)
            try {
                $failurePipe.Connect(1000)
                $failureWriter = [IO.StreamWriter]::new($failurePipe, [Text.UTF8Encoding]::new($false))
                $failureWriter.WriteLine((ConvertTo-AgentCanonicalJson @{
                            schemaVersion = 1; operation = 'rejected'
                            dispatchId = [string]$manifest.dispatchId; code = $code; detail = $detail
                        }))
                $failureWriter.Flush()
            }
            finally { $failurePipe.Dispose() }
        }
        catch {
            # The broker also observes an early child exit; notification is best effort.
        }
        if ($capabilityLock -and $capabilityLock.Acquired) { Exit-AgentLock $capabilityLock.Stream }
        if ($stateLock -and $stateLock.Acquired) { Exit-AgentLock $stateLock.Stream }
        if ($lease -and $lease.Acquired) { Exit-AgentLock $lease.Stream }
        throw
    }
}

function Get-AgentManualOperatorContext {
    param(
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role
    )
    $key = Get-AgentExecutionKey -RepositoryIdentity $RepositoryIdentity -PullRequestId $PullRequestId -Role $Role
    if (-not $script:AgentManualAuthorities.ContainsKey($key)) { return '' }
    return [string]$script:AgentManualAuthorities[$key].OperatorContext
}

function Test-AgentManualCancellationRequested {
    param(
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role
    )
    $key = Get-AgentExecutionKey -RepositoryIdentity $RepositoryIdentity -PullRequestId $PullRequestId -Role $Role
    if (-not $script:AgentManualAuthorities.ContainsKey($key)) { return $false }
    $authority = $script:AgentManualAuthorities[$key]
    $requestPath = [string]$authority.CancellationRequestPath
    if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) { return $false }
    [void](Assert-AgentTrustedFile -Path $requestPath -AllowedRoot (Split-Path $requestPath -Parent) -Private)
    $request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
    if ([int]$request.schemaVersion -ne 1 -or [string]$request.operation -cne 'cancel' -or
        [string]$request.dispatchId -cne [string]$authority.DispatchId -or
        [string]$request.nonce -cne [string]$authority.CancellationNonce) {
        throw '[cancel-invalid] Manual cancellation request failed its manifest binding.'
    }
    $ack = [ordered]@{
        schemaVersion = 1; operation = 'cancel-acknowledged'
        dispatchId = [string]$authority.DispatchId
        nonce = [string]$authority.CancellationNonce
        processId = $PID
    }
    $ackPath = [string]$authority.CancellationAcknowledgementPath
    $temp = "$ackPath.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temp, (ConvertTo-AgentCanonicalJson $ack), [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($temp,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    [IO.File]::Move($temp, $ackPath, $true)
    return $true
}

function Get-AgentCancellationOutcome {
    param(
        [Parameter(Mandatory)][bool]$AcknowledgementPresent,
        [Parameter(Mandatory)][bool]$AuthenticatedAcknowledgement,
        [Parameter(Mandatory)][bool]$TreeExitedDuringGrace,
        [Parameter(Mandatory)][bool]$ForcedContainmentSucceeded
    )
    if ($TreeExitedDuringGrace -and $AuthenticatedAcknowledgement) {
        return @{ Operation = 'cancelled'; Result = 'cancelled-cooperative'; HandleReleaseObserved = $true }
    }
    if ($TreeExitedDuringGrace -and -not $AcknowledgementPresent) {
        return @{ Operation = 'completed'; Result = 'completed'; HandleReleaseObserved = $true }
    }
    if ($ForcedContainmentSucceeded) {
        return @{ Operation = 'cancelled'; Result = 'cancelled-forced'; HandleReleaseObserved = $true }
    }
    return @{ Operation = 'rejected'; Result = 'termination-failed'; HandleReleaseObserved = $false }
}

function Exit-AgentManualDispatchAuthority {
    foreach ($key in @($script:AgentManualAuthorities.Keys)) {
        $authority = $script:AgentManualAuthorities[$key]
        Exit-AgentLock -Stream $authority.StateLock.Stream
        Exit-AgentLock -Stream $authority.Lease.Stream
        $script:AgentManualAuthorities.Remove($key)
    }
}

function Write-AgentFileThrough {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Install-AgentFileAtomic {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) {
        $replaceBackup = "$Destination.replace-$PID-$([Guid]::NewGuid().ToString('N'))"
        try { [IO.File]::Replace($Source, $Destination, $replaceBackup, $true) }
        finally { Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue }
    }
    else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Read-AgentDurableState {
    param([Parameter(Mandatory)][hashtable]$Context)
    $initialized = Test-Path -LiteralPath $Context.InitializedPath -PathType Leaf
    $bytes = $null
    $lastIoError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            $stream = [IO.FileStream]::new($Context.StatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            try {
                if ($stream.Length -gt 20MB) { throw "Durable state '$($Context.StatePath)' exceeds the size limit." }
                $bytes = [byte[]]::new([int]$stream.Length)
                $offset = 0
                while ($offset -lt $bytes.Length) {
                    $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                    if ($read -eq 0) { throw [IO.IOException]::new('Durable state changed during the snapshot read.') }
                    $offset += $read
                }
            }
            finally { $stream.Dispose() }
            break
        }
        catch [IO.IOException] {
            $lastIoError = $_.Exception
            if (-not $initialized -and $attempt -eq 0) {
                return @{
                    schemaVersion = 2; generation = 0; repositoryKey = $Context.RepositoryKey
                    role = $Context.Role; records = @{}; migrationReceipts = @{}
                }
            }
            if ($attempt -eq 9) { throw }
            Start-Sleep -Milliseconds 25
        }
        catch [UnauthorizedAccessException] {
            $lastIoError = $_.Exception
            if ($attempt -eq 9) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
    if ($null -eq $bytes) { throw $lastIoError }
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $state = $strictUtf8.GetString($bytes) |
        ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
    if ($state -isnot [hashtable] -or [int]$state.schemaVersion -ne 2 -or
        [string]$state.repositoryKey -cne $Context.RepositoryKey -or [string]$state.role -cne $Context.Role -or
        $state.records -isnot [hashtable] -or [long]$state.generation -lt 0) {
        throw "Durable state '$($Context.StatePath)' is malformed or bound to another repository/role."
    }
    if ($state.migrationReceipts -isnot [hashtable]) { $state.migrationReceipts = @{} }
    return $state
}

function Repair-AgentDurableState {
    param([Parameter(Mandatory)][hashtable]$Context)
    if (-not (Test-Path -LiteralPath $Context.JournalPath)) {
        foreach ($orphan in @(Get-ChildItem -LiteralPath $Context.RoleRoot -Filter 'state.v2.tmp-*' -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $orphan.FullName -Force -ErrorAction Stop
        }
        return
    }
    $journal = $null
    try {
        $journal = Get-Content -LiteralPath $Context.JournalPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $Context.JournalPath -Force -ErrorAction Stop
        return
    }
    $installed = $false
    if (Test-Path -LiteralPath $Context.StatePath) {
        $bytes = [IO.File]::ReadAllBytes($Context.StatePath)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $installed = ($bytes.Length -eq [long]$journal.payloadLength -and
            $hash -ceq [string]$journal.payloadSha256)
        if ($installed) {
            try {
                $candidate = [Text.Encoding]::UTF8.GetString($bytes) |
                    ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop
                $installed = ([long]$candidate.generation -eq [long]$journal.intendedGeneration)
            }
            catch { $installed = $false }
        }
    }
    if (-not $installed) {
        $backupPath = Join-Path $Context.RoleRoot ([string]$journal.backupName)
        if ([string]$journal.backupName -and (Test-Path -LiteralPath $backupPath)) {
            $backupBytes = [IO.File]::ReadAllBytes($backupPath)
            $backupHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($backupBytes)).ToLowerInvariant()
            if ($backupBytes.Length -ne [long]$journal.backupLength -or
                $backupHash -cne [string]$journal.backupSha256) {
                throw "Durable-state journal backup failed integrity validation."
            }
            $restoreTemp = Join-Path $Context.RoleRoot "state.v2.tmp-restore-$PID-$([Guid]::NewGuid().ToString('N'))"
            Write-AgentFileThrough -Path $restoreTemp -Bytes $backupBytes
            Install-AgentFileAtomic -Source $restoreTemp -Destination $Context.StatePath
        }
        elseif ([long]$journal.previousGeneration -eq 0) {
            Remove-Item -LiteralPath $Context.StatePath -Force -ErrorAction SilentlyContinue
        }
        else {
            throw 'Durable-state journal cannot restore its previous committed generation.'
        }
    }
    foreach ($name in @([string]$journal.tempName, [string]$journal.backupName)) {
        if ($name -and [IO.Path]::GetFileName($name) -ceq $name) {
            Remove-Item -LiteralPath (Join-Path $Context.RoleRoot $name) -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $Context.JournalPath -Force -ErrorAction Stop
}

function Write-AgentDurableState {
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][hashtable]$State)
    $current = Read-AgentDurableState -Context $Context
    $next = [ordered]@{
        schemaVersion = 2
        generation = ([long]$current.generation + 1)
        repositoryKey = $Context.RepositoryKey
        repositoryIdentity = $Context.RepositoryIdentity
        role = $Context.Role
        records = $State.records
        migrationReceipts = $State.migrationReceipts
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $payload = [Text.UTF8Encoding]::new($false).GetBytes(($next | ConvertTo-Json -Compress -Depth 100))
    $payloadHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
    $token = "$PID-$([Guid]::NewGuid().ToString('N'))"
    $tempName = "state.v2.tmp-$token"
    $tempPath = Join-Path $Context.RoleRoot $tempName
    $backupName = ''
    $backupLength = 0
    $backupHash = ''
    try {
        Write-AgentFileThrough -Path $tempPath -Bytes $payload
        if (Test-Path -LiteralPath $Context.StatePath) {
            $backupName = "state.v2.backup-$token"
            $backupPath = Join-Path $Context.RoleRoot $backupName
            $backupBytes = [IO.File]::ReadAllBytes($Context.StatePath)
            Write-AgentFileThrough -Path $backupPath -Bytes $backupBytes
            $backupLength = $backupBytes.Length
            $backupHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($backupBytes)).ToLowerInvariant()
        }
        $journal = [ordered]@{
            schemaVersion = 1; previousGeneration = [long]$current.generation
            intendedGeneration = [long]$next.generation; payloadLength = $payload.Length
            payloadSha256 = $payloadHash; tempName = $tempName; backupName = $backupName
            backupLength = $backupLength; backupSha256 = $backupHash; phase = 'prepared'
        }
        $journalBytes = [Text.UTF8Encoding]::new($false).GetBytes(($journal | ConvertTo-Json -Compress))
        $journalTemp = "$($Context.JournalPath).tmp-$token"
        Write-AgentFileThrough -Path $journalTemp -Bytes $journalBytes
        Install-AgentFileAtomic -Source $journalTemp -Destination $Context.JournalPath
        Install-AgentFileAtomic -Source $tempPath -Destination $Context.StatePath
        Remove-Item -LiteralPath $Context.JournalPath -Force -ErrorAction Stop
        if ($backupName) { Remove-Item -LiteralPath (Join-Path $Context.RoleRoot $backupName) -Force -ErrorAction Stop }
        return $next
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-AgentDurableRecords {
    param([Parameter(Mandatory)][hashtable]$Context)
    Repair-AgentDurableState -Context $Context
    return (Read-AgentDurableState -Context $Context).records
}

function Get-AgentDurableRecordsSnapshot {
    <#
        Lock-free, non-authoritative scheduling view. Atomic state replacement
        makes the committed file safe to read without taking the role lock.
        Callers must still re-read under work authority before acting.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)
    return (Read-AgentDurableState -Context $Context).records
}

function Set-AgentDurableRecords {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Records,
        [hashtable]$MigrationReceipts
    )
    $current = Read-AgentDurableState -Context $Context
    if ($null -eq $MigrationReceipts) { $MigrationReceipts = $current.migrationReceipts }
    return Write-AgentDurableState -Context $Context -State @{
        records = $Records; migrationReceipts = $MigrationReceipts
    }
}

function Initialize-AgentDurableState {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Records,
        [Parameter(Mandatory)][string]$ReceiptKey,
        [Parameter(Mandatory)][string]$ReceiptSha256
    )
    Repair-AgentDurableState -Context $Context
    $current = Read-AgentDurableState -Context $Context
    $writeMarker = {
        param([long]$Generation)
        if (Test-Path -LiteralPath $Context.InitializedPath) { return }
        $markerBytes = [Text.UTF8Encoding]::new($false).GetBytes("generation=$Generation`n")
        $markerTemp = "$($Context.InitializedPath).tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
        Write-AgentFileThrough -Path $markerTemp -Bytes $markerBytes
        Install-AgentFileAtomic -Source $markerTemp -Destination $Context.InitializedPath
    }
    if ($current.migrationReceipts.ContainsKey($ReceiptKey)) {
        if ([string]$current.migrationReceipts[$ReceiptKey].sha256 -cne $ReceiptSha256) {
            throw 'A different migration receipt already exists for this legacy state source.'
        }
        & $writeMarker ([long]$current.generation)
        return $current
    }
    if ($current.generation -gt 0) {
        throw 'Durable state is already initialized; migration will not merge or overwrite it.'
    }
    $receipts = $current.migrationReceipts
    $receipts[$ReceiptKey] = @{
        sha256 = $ReceiptSha256; importedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $written = Set-AgentDurableRecords -Context $Context -Records $Records -MigrationReceipts $receipts
    $verified = Read-AgentDurableState -Context $Context
    if ((Get-AgentCanonicalDigest $verified.records) -cne (Get-AgentCanonicalDigest $Records) -or
        -not $verified.migrationReceipts.ContainsKey($ReceiptKey)) {
        throw 'Durable state did not verify after migration write; initialization marker was withheld.'
    }
    & $writeMarker ([long]$written.generation)
    return $written
}

function Test-AgentAnalysisRequired {
    param([bool]$AlreadyProcessed, [bool]$ForceAnalysis)
    return ($ForceAnalysis -or -not $AlreadyProcessed)
}

function Test-AgentReviewerDeliveryPending {
    param(
        [hashtable]$Records,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$SourceCommit
    )
    if ($null -eq $Records -or -not $Records.ContainsKey([string]$PullRequestId)) { return $false }
    $record = $Records[[string]$PullRequestId]
    return (([string](Get-AgentProviderValue $record sourceCommit)) -ieq $SourceCommit -and
        [bool](Get-AgentProviderValue $record deliveryPending))
}

function Confirm-AgentLegacyRecordsForMigration {
    param(
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [Parameter(Mandatory)][hashtable]$Records,
        [Parameter(Mandatory)][scriptblock]$PullRequestReader
    )
    $confirmed = @{}
    foreach ($key in @($Records.Keys)) {
        $prId = 0
        if (-not [int]::TryParse([string]$key, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$prId) -or $prId -le 0) {
            throw "Legacy state contains invalid pull request key '$key'."
        }
        $record = $Records[$key]
        $commit = [string](Get-AgentProviderValue $record sourceCommit)
        if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
            throw "Legacy state for PR $prId has no valid source-commit binding."
        }
        $snapshot = & $PullRequestReader $prId
        $liveCommit = [string](Get-AgentProviderValue $snapshot sourceCommit)
        if ($liveCommit -ine $commit) {
            throw "Legacy state for PR $prId does not match the provider's current source commit."
        }
        if ($Role -eq 'reviewer' -and [bool](Get-AgentProviderValue $record deliveryPending)) {
            $artifactPath = [string](Get-AgentProviderValue $record artifactPath)
            if (-not $artifactPath -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                throw "Legacy reviewer state for PR $prId has a pending delivery but its sealed manifest is missing."
            }
        }
        $confirmed[[string]$prId] = $record
    }
    return $confirmed
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

function Resolve-AgentPwshPath {
    $command = Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $path = [IO.Path]::GetFullPath($command.Source)
    if (-not [IO.Path]::IsPathFullyQualified($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'pwsh did not resolve to an absolute executable path.'
    }
    return $path
}

function ConvertTo-AgentCanonicalJson {
    param([AllowNull()]$InputObject)

    function ConvertValue {
        param([AllowNull()]$Value)
        if ($null -eq $Value) { return 'null' }
        if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
        if ($Value -is [string] -or $Value -is [char]) {
            return ConvertTo-Json -InputObject ([string]$Value) -Compress
        }
        if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
            $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64]) {
            return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        if ($Value -is [uint64] -and $Value -le [uint64][long]::MaxValue) {
            return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        if ($Value -is [System.Collections.IDictionary] -or $Value -is [Management.Automation.PSCustomObject]) {
            $keys = if ($Value -is [System.Collections.IDictionary]) {
                @($Value.Keys | ForEach-Object { [string]$_ })
            }
            else {
                @($Value.PSObject.Properties.Name)
            }
            $entries = foreach ($key in @($keys | Sort-Object -CaseSensitive)) {
                $item = if ($Value -is [System.Collections.IDictionary]) { $Value[$key] } else { $Value.PSObject.Properties[$key].Value }
                '{0}:{1}' -f (ConvertTo-Json -InputObject $key -Compress), (ConvertValue $item)
            }
            return '{' + ($entries -join ',') + '}'
        }
        if ($Value -is [System.Collections.IEnumerable]) {
            return '[' + (@($Value | ForEach-Object { ConvertValue $_ }) -join ',') + ']'
        }
        throw "Canonical JSON v1 does not support values of type '$($Value.GetType().FullName)'."
    }

    return ConvertValue $InputObject
}

function Get-AgentCanonicalDigest {
    param([Parameter(Mandatory)]$InputObject)
    return Get-AgentSha256 -Text (ConvertTo-AgentCanonicalJson -InputObject $InputObject)
}

function Test-AgentOperatorPrompt {
    param([AllowNull()][string]$Prompt)
    $normalized = if ($null -eq $Prompt) { '' } else { $Prompt.Replace("`r`n", "`n").Replace("`r", "`n") }
    $count = 0
    for ($index = 0; $index -lt $normalized.Length; $index++) {
        $character = $normalized[$index]
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $normalized.Length -or -not [char]::IsLowSurrogate($normalized[$index + 1])) {
                throw '[prompt-invalid] Operator prompt contains an unpaired surrogate.'
            }
            $value = [char]::ConvertToUtf32($character, $normalized[++$index])
        }
        elseif ([char]::IsLowSurrogate($character)) {
            throw '[prompt-invalid] Operator prompt contains an unpaired surrogate.'
        }
        else {
            $value = [int]$character
        }
        if (($value -lt 0x20 -and $value -notin @(0x09, 0x0A)) -or
            ($value -ge 0x7F -and $value -le 0x9F)) {
            throw '[prompt-invalid] Operator prompt contains a prohibited control character.'
        }
        $count++
        if ($count -gt 512) { throw '[prompt-invalid] Operator prompt exceeds 512 Unicode scalar values.' }
    }
    return [ordered]@{
        Text = $normalized
        ScalarCount = $count
        Sha256 = Get-AgentSha256 -Text $normalized
        Preview = if ($count -eq 0) { '' } else { '[operator context redacted]' }
    }
}

function New-AgentRedirectedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$StandardOutputPath,
        [Parameter(Mandatory)][string]$StandardErrorPath,
        [string]$WorkingDirectory,
        [string[]]$EnvironmentVariablesToRemove = @()
    )
    $absolute = [IO.Path]::GetFullPath($FilePath)
    if (-not [IO.Path]::IsPathFullyQualified($absolute) -or -not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        throw "Child executable must be an existing absolute file: '$FilePath'."
    }
    foreach ($path in @($StandardOutputPath, $StandardErrorPath)) {
        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($path))
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    if ($IsWindows) {
        $psi.FileName = $absolute
        Set-TimedProcessArguments -Psi $psi -ArgumentList $ArgumentList
    }
    else {
        $setsid = Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($setsid) {
            $psi.FileName = [IO.Path]::GetFullPath($setsid.Source)
            Set-TimedProcessArguments -Psi $psi -ArgumentList (@($absolute) + @($ArgumentList))
        }
        else {
            $perl = Get-Command perl -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $perl) {
                throw 'Unix process containment requires a trusted setsid executable or Perl POSIX shim.'
            }
            $psi.FileName = [IO.Path]::GetFullPath($perl.Source)
            Set-TimedProcessArguments -Psi $psi -ArgumentList (@(
                '-MPOSIX', '-e', 'POSIX::setsid() >= 0 or die "setsid failed: $!"; exec @ARGV or die "exec failed: $!";',
                '--', $absolute
            ) + @($ArgumentList))
        }
    }
    if ($WorkingDirectory) { $psi.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.StandardInputEncoding = $utf8
    foreach ($name in @($EnvironmentVariablesToRemove) + @(Get-AgentSessionIsolationEnvVars)) {
        [void]$psi.Environment.Remove($name)
    }
    if (-not ('DevPilot.Process.BoundedDrain' -as [type])) {
        Add-Type -TypeDefinition @'
using System.IO;
using System.Text;
using System.Threading.Tasks;
namespace DevPilot.Process {
  public static class BoundedDrain {
    public static async Task<string> ReadTailAsync(TextReader reader, int maximumCharacters) {
      var tail = new StringBuilder();
      var buffer = new char[8192];
      int count;
      while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0) {
        tail.Append(buffer, 0, count);
        if (tail.Length > maximumCharacters) {
          tail.Remove(0, tail.Length - maximumCharacters);
        }
      }
      return tail.ToString();
    }
  }
}
'@
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Failed to start '$absolute'." }
    $process.StandardInput.Close()
    $stdoutTask = [DevPilot.Process.BoundedDrain]::ReadTailAsync($process.StandardOutput, 10MB)
    $stderrTask = [DevPilot.Process.BoundedDrain]::ReadTailAsync($process.StandardError, 10MB)
    return @{
        Process = $process
        StdOutTask = $stdoutTask
        StdErrTask = $stderrTask
        StdOutPath = [IO.Path]::GetFullPath($StandardOutputPath)
        StdErrPath = [IO.Path]::GetFullPath($StandardErrorPath)
        StartedAtUtc = [DateTime]::UtcNow
    }
}

function New-AgentPersistentRedirectedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$StandardOutputPath,
        [Parameter(Mandatory)][string]$StandardErrorPath,
        [string]$WorkingDirectory,
        [string[]]$EnvironmentVariablesToRemove = @()
    )
    $absolute = [IO.Path]::GetFullPath($FilePath)
    if (-not [IO.Path]::IsPathFullyQualified($absolute) -or -not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        throw "Child executable must be an existing absolute file: '$FilePath'."
    }
    $stdoutPath = [IO.Path]::GetFullPath($StandardOutputPath)
    $stderrPath = [IO.Path]::GetFullPath($StandardErrorPath)
    foreach ($path in @($stdoutPath, $stderrPath)) {
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
    }
    $savedEnvironment = @{}
    $removedNames = @($EnvironmentVariablesToRemove) + @(Get-AgentSessionIsolationEnvVars) |
        Sort-Object -Unique
    if ($IsWindows) {
        # On Windows, Start-Process -RedirectStandardOutput/-RedirectStandardError
        # is implemented via CreateProcess with real file handles wired directly
        # into the child's STARTUPINFO, so the redirection is native OS-level
        # plumbing that survives this launching process's own exit.
        try {
            foreach ($name in $removedNames) {
                $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
            }
            $parameters = @{
                FilePath = $absolute
                ArgumentList = $ArgumentList
                RedirectStandardOutput = $stdoutPath
                RedirectStandardError = $stderrPath
                PassThru = $true
            }
            if ($WorkingDirectory) { $parameters.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory) }
            $process = Start-Process @parameters
        }
        finally {
            foreach ($name in $removedNames) {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
            }
        }
    }
    else {
        # On Unix, PowerShell's Start-Process redirection is implemented with
        # Process.BeginOutputReadLine()/BeginErrorReadLine() - async managed
        # callbacks that copy pipe data into the target file from *this*
        # launching process. Once this process exits, those callbacks stop
        # running even though the spawned child keeps writing, so output
        # produced after the launcher exits is silently lost. Get real,
        # launcher-independent redirection the same way a shell does: have
        # /bin/sh dup2 the target files onto fds 1/2 and then exec() the real
        # program in place, so the child's own OS-level file descriptors -
        # not a pipe read by this process - point at the output files.
        $shell = '/bin/sh'
        if (-not (Test-Path -LiteralPath $shell -PathType Leaf)) {
            throw "Required trusted Unix shell '$shell' was not found."
        }
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $shell
        Set-TimedProcessArguments -Psi $psi -ArgumentList (@(
                '-c', 'out=$1; err=$2; shift 2; exec "$@" > "$out" 2> "$err"',
                'sh', $stdoutPath, $stderrPath, $absolute
            ) + @($ArgumentList))
        if ($WorkingDirectory) { $psi.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($name in $removedNames) { [void]$psi.Environment.Remove($name) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $psi
        if (-not $process.Start()) { throw "Failed to start '$absolute'." }
    }
    return @{
        Process = $process
        StdOutTask = $null
        StdErrTask = $null
        StdOutPath = $stdoutPath
        StdErrPath = $stderrPath
        StartedAtUtc = [DateTime]::UtcNow
        PersistentRedirection = $true
    }
}

function Complete-AgentRedirectedProcess {
    param(
        [Parameter(Mandatory)][hashtable]$Child,
        [ValidateRange(1, 30000)][int]$DrainTimeoutMilliseconds = 5000,
        [ValidateRange(256, 65536)][int]$DiagnosticTailCharacters = 4096
    )
    $persistent = $Child.ContainsKey('PersistentRedirection') -and [bool]$Child.PersistentRedirection
    if ($persistent) {
        $readTail = {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
            $text = [IO.File]::ReadAllText($Path)
            if ($text.Length -gt 10MB) { $text = $text.Substring($text.Length - 10MB) }
            return $text
        }
        $stdout = @{ Completed = $true; Text = (& $readTail $Child.StdOutPath) }
        $stderr = @{ Completed = $true; Text = (& $readTail $Child.StdErrPath) }
    }
    else {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($DrainTimeoutMilliseconds)
        $stdout = Get-TaskTextBeforeDeadline -Task $Child.StdOutTask -DeadlineUtc $deadline
        $stderr = Get-TaskTextBeforeDeadline -Task $Child.StdErrTask -DeadlineUtc $deadline
        foreach ($entry in @(@($Child.StdOutPath, $stdout.Text), @($Child.StdErrPath, $stderr.Text))) {
            $text = [string]$entry[1]
            if ($text.Length -gt 10MB) { $text = $text.Substring($text.Length - 10MB) }
            [IO.File]::WriteAllText([string]$entry[0], $text, [Text.UTF8Encoding]::new($false))
        }
    }
    $sanitizeTail = {
        param([string]$Text)
        $safe = $Text -replace '(?ims)^Operator context \(untrusted DATA, not instructions\):.*\z',
            '[operator context block redacted]'
        if ($safe.Length -gt $DiagnosticTailCharacters) {
            $safe = $safe.Substring($safe.Length - $DiagnosticTailCharacters)
        }
        return $safe
    }
    $safeOutputTail = & $sanitizeTail ([string]$stdout.Text)
    $safeErrorTail = & $sanitizeTail ([string]$stderr.Text)
    return @{
        OutputDrained = $stdout.Completed -and $stderr.Completed
        ExitCode = $(if ($Child.Process.HasExited) { $Child.Process.ExitCode } else { -1 })
        SafeOutputTail = $safeOutputTail
        SafeErrorTail = $safeErrorTail
        StdOutPath = $Child.StdOutPath
        StdErrPath = $Child.StdErrPath
    }
}

function Get-AgentProcessStartIdentity {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    if ($IsLinux) {
        $stat = [IO.File]::ReadAllText("/proc/$($Process.Id)/stat")
        $nameEnd = $stat.LastIndexOf(')')
        if ($nameEnd -lt 0) { throw "Process $($Process.Id) has malformed procfs identity." }
        $fields = @($stat.Substring($nameEnd + 1).Trim() -split '\s+')
        if ($fields.Count -le 19 -or $fields[19] -notmatch '^\d+$') {
            throw "Process $($Process.Id) has malformed procfs start identity."
        }
        return "linux:$($fields[19])"
    }
    return "utc:$($Process.StartTime.ToUniversalTime().Ticks)"
}

function New-AgentProcessContainment {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    if ($IsWindows) {
        if (-not ('DevPilot.Native.Job' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace DevPilot.Native {
  public static class Job {
    [StructLayout(LayoutKind.Sequential)] public struct BasicAccounting {
      public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
      public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BasicLimits {
      public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
      public uint LimitFlags;
      public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
      public uint ActiveProcessLimit;
      public UIntPtr Affinity;
      public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] public struct IoCounters {
      public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
      public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ExtendedLimits {
      public BasicLimits BasicLimitInformation;
      public IoCounters IoInfo;
      public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32.dll")] public static extern bool SetInformationJobObject(IntPtr j, int c, ref ExtendedLimits i, uint l);
    [DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32.dll")] public static extern bool TerminateJobObject(IntPtr j, uint c);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(
      IntPtr j, int c, out BasicAccounting i, uint l, IntPtr r);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    public static IntPtr CreateKillOnClose(int pid, IntPtr processHandle) {
      IntPtr job = CreateJobObject(IntPtr.Zero, null);
      if (job == IntPtr.Zero) throw new Win32Exception();
      var limits = new ExtendedLimits();
      limits.BasicLimitInformation.LimitFlags = 0x00002000;
      if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()) ||
          !AssignProcessToJobObject(job, processHandle)) {
        int error = Marshal.GetLastWin32Error(); CloseHandle(job); throw new Win32Exception(error);
      }
      return job;
    }
    public static bool IsEmpty(IntPtr job) {
      BasicAccounting accounting;
      if (!QueryInformationJobObject(job, 1, out accounting, (uint)Marshal.SizeOf<BasicAccounting>(), IntPtr.Zero))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      return accounting.ActiveProcesses == 0;
    }
  }
}
'@
        }
        return @{ Platform = 'Windows'; Handle = [DevPilot.Native.Job]::CreateKillOnClose($Process.Id, $Process.Handle); ProcessGroupId = 0 }
    }
    if (-not ('DevPilot.Native.UnixProcessGroup' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DevPilot.Native {
  public static class UnixProcessGroup {
    [DllImport("libc", SetLastError=true)] public static extern int kill(int pid, int signal);
    public static int LastError() { return Marshal.GetLastWin32Error(); }
  }
}
'@
    }
    if ($Process.Id -le 1) {
        throw 'Unix containment requires a child-owned process group leader PID greater than 1.'
    }
    return @{
        Platform = 'Unix'; Handle = $null; ProcessGroupId = $Process.Id
        LeaderStartIdentity = Get-AgentProcessStartIdentity -Process $Process
        ContainmentToken = [Guid]::NewGuid().ToString('N')
    }
}

function Invoke-AgentUnixProcessGroupSignal {
    param(
        [Parameter(Mandatory)][hashtable]$Containment,
        [Parameter(Mandatory)][ValidateSet(0, 9, 15)][int]$Signal,
        [Diagnostics.Process]$Process
    )
    if ($Signal -eq 0) {
        $processGroupId = [int]$Containment.ProcessGroupId
        if ($processGroupId -le 1) {
            throw 'Unix containment process group must be greater than 1.'
        }
        $result = [DevPilot.Native.UnixProcessGroup]::kill(-$processGroupId, 0)
        if ($result -eq 0) { return 'alive' }
        $errorNumber = [DevPilot.Native.UnixProcessGroup]::LastError()
        if ($errorNumber -eq 3) { return 'absent' }
        if ($errorNumber -eq 1) { return 'unknown' }
        throw "Unix process-group observation failed with errno $errorNumber."
    }
    if (-not $Process) {
        throw 'Unix containment leader identity is unavailable; refusing to signal a process group.'
    }
    $processGroupId = [int]$Containment.ProcessGroupId
    if ($processGroupId -le 1 -or $processGroupId -ne $Process.Id) {
        throw 'Unix containment process group is not the verified child leader; refusing to signal.'
    }
    $Process.Refresh()
    if ($Process.HasExited) {
        throw 'Unix containment leader has exited; refusing to signal an unverifiable process group.'
    }
    if ((Get-AgentProcessStartIdentity -Process $Process) -cne [string]$Containment.LeaderStartIdentity) {
        throw 'Unix containment leader identity changed; refusing to signal a stale process group.'
    }
    $result = [DevPilot.Native.UnixProcessGroup]::kill(-$processGroupId, $Signal)
    if ($result -eq 0) { return 'alive' }
    $errorNumber = [DevPilot.Native.UnixProcessGroup]::LastError()
    if ($errorNumber -eq 3) { return 'absent' }
    if ($errorNumber -eq 1) {
        throw "Unix process group $($Containment.ProcessGroupId) exists but signaling was denied (EPERM)."
    }
    throw "Unix process-group signal $Signal failed with errno $errorNumber."
}

function Stop-AgentProcessContainment {
    param([Parameter(Mandatory)][hashtable]$Containment, [Diagnostics.Process]$Process)
    if ($Containment.Platform -eq 'Windows') {
        [void][DevPilot.Native.Job]::TerminateJobObject($Containment.Handle, 1)
    }
    else {
        try {
            if (-not $Process -or [int]$Containment.ProcessGroupId -le 1 -or
                [int]$Containment.ProcessGroupId -ne $Process.Id) {
                return $false
            }
            $Process.Refresh()
            if (-not $Process.HasExited) {
                if ((Get-AgentProcessStartIdentity -Process $Process) -cne [string]$Containment.LeaderStartIdentity) {
                    return $false
                }
                [void](Invoke-AgentUnixProcessGroupSignal -Containment $Containment -Signal 15 -Process $Process)
            }
        }
        catch { return $false }
    }
    $graceDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $graceDeadline) {
        if (Test-AgentProcessContainmentExited -Containment $Containment -Process $Process) { return $true }
        Start-Sleep -Milliseconds 25
    }
    if ($Containment.Platform -eq 'Unix') {
        try {
            if (Test-AgentProcessContainmentExited -Containment $Containment -Process $Process) { return $true }
            $Process.Refresh()
            if (-not $Process.HasExited -and
                (Get-AgentProcessStartIdentity -Process $Process) -ceq [string]$Containment.LeaderStartIdentity) {
                [void](Invoke-AgentUnixProcessGroupSignal -Containment $Containment -Signal 9 -Process $Process)
            }
        }
        catch { return $false }
    }
    else {
        [void][DevPilot.Native.Job]::TerminateJobObject($Containment.Handle, 1)
    }
    $killDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $killDeadline) {
        if (Test-AgentProcessContainmentExited -Containment $Containment -Process $Process) { return $true }
        Start-Sleep -Milliseconds 25
    }
    return $false
}

function Test-AgentProcessContainmentExited {
    param([Parameter(Mandatory)][hashtable]$Containment, [Diagnostics.Process]$Process)
    if ($Process) { $Process.Refresh() }
    if ($Containment.Platform -eq 'Windows') {
        return [DevPilot.Native.Job]::IsEmpty($Containment.Handle)
    }
    try {
        if (-not $Process) { return $false }
        if ([int]$Containment.ProcessGroupId -le 1 -or
            [int]$Containment.ProcessGroupId -ne $Process.Id) {
            return $false
        }
        if (-not $Process.HasExited -and
            (Get-AgentProcessStartIdentity -Process $Process) -cne [string]$Containment.LeaderStartIdentity) {
            return $false
        }
        return (Invoke-AgentUnixProcessGroupSignal -Containment $Containment -Signal 0 -Process $Process) -eq 'absent'
    }
    catch { return $false }
}

function Close-AgentProcessContainment {
    param([AllowNull()][hashtable]$Containment)
    if ($Containment -and $Containment.Platform -eq 'Windows' -and $Containment.Handle -ne [IntPtr]::Zero) {
        [void][DevPilot.Native.Job]::CloseHandle($Containment.Handle)
        $Containment.Handle = [IntPtr]::Zero
    }
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

function Test-IsClosedChildStdinException {
    param([Parameter(Mandatory)][System.Exception]$Exception)

    $pending = New-Object System.Collections.Generic.Queue[System.Exception]
    $pending.Enqueue($Exception)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if ($current -is [System.IO.IOException]) {
            $nativeError = $current.HResult -band 0xFFFF
            if ($nativeError -in @(109, 232)) { return $true }
        }
        # On Unix, a child that exits before the redirected stdin write
        # completes surfaces as a SocketException ("Broken pipe", errno
        # EPIPE) wrapped in the IOException above and then in the
        # AggregateException from Task.Wait - there is no other reason a
        # SocketException would appear while writing to the child's own
        # stdin pipe, so it is the Unix equivalent of the Windows
        # ERROR_BROKEN_PIPE/ERROR_NO_DATA HResults checked above.
        if ($current -is [System.Net.Sockets.SocketException]) { return $true }
        if ($current -is [System.AggregateException]) {
            foreach ($inner in $current.InnerExceptions) {
                if ($inner) { $pending.Enqueue($inner) }
            }
        }
        elseif ($current.InnerException) {
            $pending.Enqueue($current.InnerException)
        }
    }
    return $false
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
        [scriptblock]$CancellationProbe,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    Set-TimedProcessArguments -Psi $psi -ArgumentList $ArgumentList
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.RedirectStandardInput = $true
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
            try {
                if (-not $writeTask.Wait($writeDeadlineMs)) {
                    $timedOut = $true
                }
            }
            catch {
                if (-not (Test-IsClosedChildStdinException -Exception $_.Exception)) { throw }
            }
            finally {
                if ($writeTask.IsCompleted) {
                    try { $proc.StandardInput.Close() } catch {}
                }
            }
        }
        else {
            $proc.StandardInput.Close()
        }

        $exited = $false
        $cancelled = $false
        if (-not $timedOut) {
            while ([DateTime]::UtcNow -lt $deadline) {
                if ($proc.WaitForExit(100)) { $exited = $true; break }
                if ($CancellationProbe -and (& $CancellationProbe)) {
                    $cancelled = $true
                    break
                }
            }
            $timedOut = -not $exited -and -not $cancelled
        }

        if ($timedOut -or $cancelled) {
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
            Cancelled = $cancelled
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
        [scriptblock]$GitHubApiInvoker,
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
        GitHubApiInvoker = $GitHubApiInvoker
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

function New-AgentUnverifiedRepositoryIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('AzureDevOps', 'GitHub')][string]$Provider,
        [Parameter(Mandatory)][string]$Organization,
        [string]$Project = '',
        [Parameter(Mandatory)][string]$RepositoryName
    )
    return [ordered]@{
        schemaVersion = 1
        provider = $Provider
        repositoryId = ''
        organization = $Organization
        project = $Project
        repositoryName = $RepositoryName
        slug = if ($Provider -eq 'GitHub') { "$Organization/$RepositoryName" } else { "$Organization/$Project/$RepositoryName" }
        key = ''
        verifiedAtUtc = ''
        verified = $false
        dispatchEligible = $false
    }
}

function Get-AgentProviderValue {
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -ieq $Name) { return $InputObject[$key] }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties | Where-Object Name -IEq $Name | Select-Object -First 1
    return $(if ($property) { $property.Value } else { $null })
}

function Resolve-AgentProviderRepositoryIdentity {
    <#
    .SYNOPSIS
        Resolves the immutable repository ID from the configured provider.

    .DESCRIPTION
        Configuration supplies an address, never identity authority. Azure
        DevOps repository GUIDs are checked against the provider response.
        GitHub numeric IDs are read as raw JSON tokens so values above the
        JavaScript safe-integer limit remain exact opaque decimal strings.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    Assert-AgentProviderContext -Context $Context
    $repositoryId = ''
    $organization = [string]$Context.Organization
    $project = [string]$Context.Project
    $repositoryName = ''

    switch ($Context.Provider) {
        'AzureDevOps' {
            $configuredGuid = [Guid]::Empty
            if (-not [Guid]::TryParseExact(([string]$Context.RepositoryId), 'D', [ref]$configuredGuid)) {
                throw "[identity-unresolved] Azure DevOps config repository.id must be a GUID in D format."
            }
            $response = & $Context.McpInvoker 'repo_repository' @{
                action = 'get'
                orgName = $organization
                project = $project
                repositoryNameOrId = [string]$Context.RepositoryName
            } $false
            $providerGuid = [Guid]::Empty
            $rawId = [string](Get-AgentProviderValue -InputObject $response -Name 'id')
            if (-not [Guid]::TryParseExact($rawId, 'D', [ref]$providerGuid)) {
                throw "[identity-unresolved] Azure DevOps returned a missing or malformed repository ID."
            }
            if ($configuredGuid -ne $providerGuid) {
                throw "[repository-mismatch] Azure DevOps returned a repository ID that does not match config."
            }
            $repositoryName = [string](Get-AgentProviderValue -InputObject $response -Name 'name')
            $providerProject = Get-AgentProviderValue -InputObject $response -Name 'project'
            if (-not $providerProject) {
                $providerProject = Get-AgentProviderValue -InputObject $response -Name 'projectReference'
            }
            $providerProjectName = [string](Get-AgentProviderValue -InputObject $providerProject -Name 'name')
            if (-not $repositoryName -or -not $providerProjectName) {
                throw "[identity-unresolved] Azure DevOps returned incomplete repository metadata."
            }
            if ($repositoryName -ine [string]$Context.RepositoryName -or $providerProjectName -ine $project) {
                throw "[repository-mismatch] Azure DevOps repository address does not match config."
            }
            $repositoryId = $providerGuid.ToString('D').ToLowerInvariant()
            $project = $providerProjectName
        }
        'GitHub' {
            $raw = if ($Context.GitHubApiInvoker) {
                & $Context.GitHubApiInvoker "repos/$($Context.Slug)" ([Math]::Min(10, [int]$Context.TimeoutSeconds))
            }
            else {
                Invoke-AgentGitHubApi -Path "repos/$($Context.Slug)" -TimeoutSeconds ([Math]::Min(10, [int]$Context.TimeoutSeconds)) -RawText
            }
            try {
                $document = [System.Text.Json.JsonDocument]::Parse($raw)
                try {
                    $root = $document.RootElement
                    $idElement = [System.Text.Json.JsonElement]::new()
                    $fullNameElement = [System.Text.Json.JsonElement]::new()
                    $nameElement = [System.Text.Json.JsonElement]::new()
                    if (-not $root.TryGetProperty('id', [ref]$idElement) -or
                        $idElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Number) {
                        throw "missing id"
                    }
                    $repositoryId = $idElement.GetRawText()
                    if ($repositoryId -notmatch '^[1-9][0-9]*$') { throw "invalid id" }
                    if (-not $root.TryGetProperty('full_name', [ref]$fullNameElement) -or
                        $fullNameElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                        throw "missing full_name"
                    }
                    if ([string]$fullNameElement.GetString() -ine [string]$Context.Slug) {
                        throw "[repository-mismatch] GitHub repository address does not match config."
                    }
                    if (-not $root.TryGetProperty('name', [ref]$nameElement) -or
                        $nameElement.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                        throw "missing name"
                    }
                    $repositoryName = [string]$nameElement.GetString()
                    if (-not $repositoryName) { throw "missing name" }
                }
                finally { $document.Dispose() }
            }
            catch {
                if ($_.Exception.Message.StartsWith('[repository-mismatch]')) { throw }
                throw "[identity-unresolved] GitHub returned malformed repository identity metadata."
            }
        }
    }

    return [ordered]@{
        schemaVersion = 1
        provider = [string]$Context.Provider
        repositoryId = $repositoryId
        organization = $organization
        project = $project
        repositoryName = $repositoryName
        slug = if ($Context.Provider -eq 'GitHub') { "$organization/$repositoryName" } else { "$organization/$project/$repositoryName" }
        key = "v1:$(([string]$Context.Provider).ToLowerInvariant()):$repositoryId"
        verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
        verified = $true
        dispatchEligible = $true
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
        [int]$TimeoutSeconds = 60,
        [switch]$RawText
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
    if ($RawText) { return [string]$result.StdOut }
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
        'AzureDevOps' {
            $pr = & $Context.McpInvoker 'repo_pull_request' @{
                action = 'get'
                orgName = $Context.Organization
                project = $Context.Project
                repositoryId = $Context.RepositoryName
                pullRequestId = $PullRequestId
            } $false
            $commit = [string](Get-AgentProviderValue $pr sourceCommitId)
            if (-not $commit) {
                $mergeSource = Get-AgentProviderValue $pr lastMergeSourceCommit
                $commit = [string](Get-AgentProviderValue $mergeSource commitId)
            }
            if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
                throw "Azure DevOps pull request $PullRequestId has no valid source commit."
            }
            return @{
                prId = $PullRequestId
                sourceCommit = $commit.ToLowerInvariant()
                status = [string](Get-AgentProviderValue $pr status)
                isDraft = [bool](Get-AgentProviderValue $pr isDraft)
                targetRefName = [string](Get-AgentProviderValue $pr targetRefName)
                sourceRefName = [string](Get-AgentProviderValue $pr sourceRefName)
                title = [string](Get-AgentProviderValue $pr title)
            }
        }
        default {
            throw "Get-AgentProviderPullRequestSnapshot is not implemented for '$($Context.Provider)'."
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
    "Get-AgentHarnessCapabilityDescriptor",
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
    "New-AgentPipeName",
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
    "Get-AgentSha256",
    "Get-AgentDefaultDurableStateRoot",
    "Get-AgentDefaultLeaseRoot",
    "Get-AgentDefaultWatchStateRoot",
    "Test-AgentPathWithin",
    "Resolve-AgentTrustedRoot",
    "Assert-AgentTrustedFile",
    "Remove-AgentContainedDirectory",
    "Get-AgentRepositoryIdentityKey",
    "Get-AgentExecutionKey",
    "Enter-AgentWorkLease",
    "Get-AgentDurableStateContext",
    "Enter-AgentDurableStateLock",
    "Invoke-AgentWithWorkAuthority",
    "Enter-AgentManualDispatchStartup",
    "Get-AgentManualOperatorContext",
    "Test-AgentManualCancellationRequested",
    "Get-AgentCancellationOutcome",
    "Exit-AgentManualDispatchAuthority",
    "Get-AgentDefaultCapabilityOverrideRoot",
    "ConvertTo-AgentCanonicalEpochSeconds",
    "Get-AgentWorktreeIdentity",
    "Read-AgentStableFile",
    "ConvertFrom-AgentTrustedCapabilityJson",
    "Resolve-AgentEffectiveCapabilitySettings",
    "Resolve-AgentCapabilityPolicyPartition",
    "Enter-AgentCapabilityOverrideLock",
     "Get-AgentDefaultCapabilityOverrideKillSwitchRoot",
     "Test-AgentCapabilityOverrideKillSwitch",
     "Enable-AgentCapabilityOverrideKillSwitch",
     "Disable-AgentCapabilityOverrideKillSwitch",
     "Get-AgentCapabilityOverrideKillSwitchExpiresAtUtc",
     "Set-AgentCapabilityOverrideSetting",
    "Repair-AgentDurableState",
    "Read-AgentDurableState",
    "Write-AgentDurableState",
    "Get-AgentDurableRecords",
    "Get-AgentDurableRecordsSnapshot",
    "Set-AgentDurableRecords",
    "Initialize-AgentDurableState",
    "Test-AgentAnalysisRequired",
    "Test-AgentReviewerDeliveryPending",
    "Confirm-AgentLegacyRecordsForMigration",
    "Get-JsonState",
    "Set-JsonState",
    "Write-AgentMetadata",
    "ConvertFrom-AgentResultMarker",
    "Find-CopilotSessionForBranch",
    "Set-TimedProcessArguments",
    "Resolve-AgentPwshPath",
    "ConvertTo-AgentCanonicalJson",
    "Get-AgentCanonicalDigest",
    "Test-AgentOperatorPrompt",
    "New-AgentRedirectedProcess",
    "New-AgentPersistentRedirectedProcess",
    "Complete-AgentRedirectedProcess",
    "Get-AgentProcessStartIdentity",
    "New-AgentProcessContainment",
    "Stop-AgentProcessContainment",
    "Test-AgentProcessContainmentExited",
    "Close-AgentProcessContainment",
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
    "New-AgentUnverifiedRepositoryIdentity",
    "Resolve-AgentProviderRepositoryIdentity",
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
