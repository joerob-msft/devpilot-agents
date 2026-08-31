#Requires -Version 7.0

<#
.SYNOPSIS
    The signed census manifest: the reviewer's own attestation of exactly which
    accounting artifacts a finished run left behind.

.DESCRIPTION
    WHY THIS FILE EXISTS. The model-start census counted a run's spend by reading
    two kinds of file out of that run's own state directory - the cycle log, and
    the sealed verification previews - and it trusted both because of their
    SHAPE. A file was believed if it parsed, carried the right mode words, and
    published the right property names. The preview reader said so in as many
    words: "It does not verify the signature."

    That is a census of whatever is on disk, not a census of what a run did.
    Anyone able to write into the run root could append accounting records, drop
    in an extra preview, delete an inconvenient one, or replace a preview's
    manifest text wholesale, and every number downstream would move while looking
    exactly like a clean measurement. The census feeds a budget, and a budget
    computed from forgeable evidence is worse than no budget: it is a number with
    a false provenance attached.

    WHAT REPLACES IT. The reviewer seals, at the end of a run, a
    domain-separated HMAC-signed manifest that names:

      - the cycle log, by SHA-256 of its bytes and by its byte length;
      - the EXACT inventory of sealed verification previews, each by name and by
        SHA-256 - exact meaning that a preview added after the seal, or removed
        after it, is a detectable difference and not a smaller number;
      - the run's own per-role inventory of attempt-accounting records and launch
        intents, so the log's contents have a second witness that a log rewritten
        to a consistent-looking smaller set must also match.

    The census then re-derives every one of those digests from the files it is
    about to read, and refuses to call itself authenticated unless all of them
    agree.

    DOMAIN SEPARATION. The signing key is derived from the run's artifact key
    under the label 'devpilot.reviewer.census.manifest.v1'. A census manifest can
    therefore not be produced by anything that can sign a gate decision, a
    verification preview or a convention plan, and none of those can be replayed
    as a census manifest.

    WHAT THIS DOES NOT DEFEND AGAINST, SAID PLAINLY. An attacker who can already
    run code as this user during the run can sign a manifest, exactly as they
    could already sign every other artifact in this tree. What changes is that
    evidence can no longer be edited AFTER the fact, and that a run which left no
    attestation at all is reported as unverified rather than counted as if it had
    been verified. That is the whole claim.

    NEVER AN UNDERCOUNT. Authentication failure never reduces a number. The
    counts a census reports are still the maximum of every witness it found; what
    authentication decides is whether the census may call itself COMPLETE. An
    unverified run is a blocked run, not a cheap one.

    OLD ARTIFACTS. A run sealed before this existed has no manifest and cannot
    grow one honestly. It is reported unauthenticated, with basis
    'noCensusManifest', and under the default authentication mode its census is
    incomplete. It is not rejected as corrupt and it is not silently trusted;
    it is exactly what it is - a run whose accounting nobody can check.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ReviewerBaseContract.ps1')

$script:ReviewerCensusManifestKind = 'reviewer-model-start-census-manifest'
$script:ReviewerCensusManifestVersion = 2
$script:ReviewerCensusManifestKeyLabel = 'devpilot.reviewer.census.manifest.v1'
$script:ReviewerCensusManifestFileName = 'model-start-census.manifest.json'
$script:ReviewerCensusManifestUtf8 = [Text.UTF8Encoding]::new($false, $true)
$script:ReviewerCensusManifestLogRelativePath = 'logs/reviewer.log.jsonl'
$script:ReviewerCensusManifestPreviewDirectory = 'verification-previews'

function Get-ReviewerModelStartCensusManifestPath {
    <#
    .SYNOPSIS
        Where a run's census attestation lives.
    #>
    param([Parameter(Mandatory)][string]$RunRoot)
    return (Join-Path $RunRoot $script:ReviewerCensusManifestFileName)
}

function Get-ReviewerCensusManifestKey {
    <#
    .SYNOPSIS
        The census-manifest signing key derived from a run's master key.
    .DESCRIPTION
        Derived under its own label so that the ability to sign any other
        reviewer artifact does not carry the ability to sign a census, and a
        census cannot be replayed as one of them.
    #>
    param([Parameter(Mandatory)][byte[]]$MasterKey)
    if (@($MasterKey).Count -eq 0) {
        throw 'The census manifest key cannot be derived from an empty master key.'
    }
    $hmac = [Security.Cryptography.HMACSHA256]::new($MasterKey)
    try { return , $hmac.ComputeHash($script:ReviewerCensusManifestUtf8.GetBytes($script:ReviewerCensusManifestKeyLabel)) }
    finally { $hmac.Dispose() }
}

function Get-ReviewerCensusManifestSignature {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([Convert]::ToHexString($hmac.ComputeHash($script:ReviewerCensusManifestUtf8.GetBytes($Json)))).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Get-ReviewerCensusRecordExecutionId {
    <#
    .SYNOPSIS
        The distinct session identities the accounting records themselves claim.
    .DESCRIPTION
        Every per-attempt record the reviewer writes carries the identity of the
        process that wrote it. Reading them back gives the census a witness to
        WHICH EXECUTION produced the log it is counting, independent of what a
        manifest sitting next to it says about itself.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        if (-not $record.PSObject.Properties['session']) { continue }
        $session = $record.session
        if ($null -eq $session -or -not $session.PSObject.Properties['sessionId']) { continue }
        [string]$identity = [string]$session.sessionId
        if ($identity.Length -gt 0) { [void]$seen.Add($identity) }
    }
    return @([string[]]@($seen) | Sort-Object -CaseSensitive)
}

function Get-ReviewerCensusRunRootIdentity {
    <#
    .SYNOPSIS
        The digest of a run root's own location, used to pin an attestation to
        the run it was sealed over.

    .DESCRIPTION
        WHY AN IDENTITY IS BOUND AT ALL. Without one, a census manifest is a
        statement about a SET OF FILES and says nothing about WHICH RUN produced
        them. Every run belonging to one operator is sealed under the same master
        key, so a correctly signed manifest from a cheap run - together with its
        log and previews - can simply be copied over an expensive run's evidence
        and will verify perfectly. The result is an authenticated, complete
        census reporting the cheap run's smaller number: an undercount that
        carries a valid signature, which is worse than no signature at all.

        Binding the run root closes that. A manifest is now a statement about
        this run's files in this run's place.

        The digest rather than the path itself, because the manifest is committed
        to being free of absolute paths: a reader that ships a manifest around
        should not be shipping someone's directory layout with it. A digest binds
        the identity without publishing it.

        A run root that is legitimately MOVED will no longer authenticate. That
        is the safe direction and it is deliberate: the census blocks, reports
        exactly which check failed, and never lowers a count.
    #>
    param([Parameter(Mandatory)][string]$RunRoot)
    $full = $RunRoot
    try { $full = [IO.Path]::GetFullPath($RunRoot) } catch { $full = $RunRoot }
    $full = $full.TrimEnd([char]'\', [char]'/')
    # Case-insensitively on the platforms whose file systems are, so that a run
    # root reached through a differently-cased but identical path is the same
    # run rather than a tamper report.
    if ($IsWindows) { $full = $full.ToLowerInvariant() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha.ComputeHash($script:ReviewerCensusManifestUtf8.GetBytes($full)))).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-ReviewerCensusFileDigest {
    <#
    .SYNOPSIS
        SHA-256 over a file's bytes, or $null when it is not there.
    .DESCRIPTION
        Bytes, never text. A digest taken over decoded text would agree across
        two files that differ in encoding or line endings, and the point of this
        digest is that the reader and the sealer looked at the same octets.

        Opened with full sharing so that a concurrent reader - the very thing the
        atomic-publish work exists to tolerate - cannot turn an integrity check
        into a sharing violation.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([Convert]::ToHexString($sha.ComputeHash($stream))).ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-ReviewerCensusPreviewInventory {
    <#
    .SYNOPSIS
        The sealed verification previews under a run root, by ordinal name.
    .DESCRIPTION
        Names are compared with ordinal case sensitivity even though Windows
        paths are not case sensitive. That is deliberate: an inventory keyed on a
        case-insensitive comparison would let 'Preview-1.json' stand in for
        'preview-1.json', and the two are different rows in an attestation even
        when they are the same file on this file system. The digest is what makes
        them the same file; the name is only how they are found.
    #>
    param([Parameter(Mandatory)][string]$RunRoot)
    $directory = Join-Path $RunRoot $script:ReviewerCensusManifestPreviewDirectory
    $rows = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $rows.ToArray() }
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name)
    foreach ($file in $files) {
        [void]$rows.Add([ordered]@{
                name   = [string]$file.Name
                sha256 = [string](Get-ReviewerCensusFileDigest -Path ([string]$file.FullName))
            })
    }
    # Emitted as a pipeline of rows rather than as one array object. Returning
    # ",$array" would make every caller's @(...) collect a single element that is
    # itself the array, and the row-shaped reads that follow would then see one
    # "row" whose name property is every name joined together - a mismatch that
    # reads like tampering and is only a wrapping mistake.
    return $rows.ToArray()
}

function Get-ReviewerCensusRecordInventory {
    <#
    .SYNOPSIS
        The per-mode and per-role record counts a run's log carries.
    .DESCRIPTION
        A second witness to the log's contents. The log digest already pins the
        bytes, so this cannot catch anything the digest does not - but it makes
        the failure legible: an inventory mismatch names the role and mode that
        moved, where a digest mismatch says only that something did.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    $modes = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $roles = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        if (-not $record.PSObject.Properties['mode']) { continue }
        $mode = [string]$record.mode
        if ($modes.ContainsKey($mode)) { $modes[$mode] = [int]$modes[$mode] + 1 } else { $modes[$mode] = 1 }
        if ($record.PSObject.Properties['censusRole']) {
            $roleKey = "$mode|$([string]$record.censusRole)"
            if ($roles.ContainsKey($roleKey)) { $roles[$roleKey] = [int]$roles[$roleKey] + 1 } else { $roles[$roleKey] = 1 }
        }
    }
    $modeRows = [Collections.Generic.List[object]]::new()
    foreach ($mode in @([string[]]@($modes.Keys) | Sort-Object -CaseSensitive)) {
        [void]$modeRows.Add([ordered]@{ count = [int]$modes[$mode]; mode = [string]$mode })
    }
    $roleRows = [Collections.Generic.List[object]]::new()
    foreach ($key in @([string[]]@($roles.Keys) | Sort-Object -CaseSensitive)) {
        $parts = $key.Split('|', 2)
        [void]$roleRows.Add([ordered]@{ censusRole = [string]$parts[1]; count = [int]$roles[$key]; mode = [string]$parts[0] })
    }
    return [ordered]@{
        byMode = @($modeRows.ToArray())
        byRole = @($roleRows.ToArray())
    }
}

function New-ReviewerModelStartCensusManifestContent {
    <#
    .SYNOPSIS
        The manifest body for one finished run, read from that run's files.
    .DESCRIPTION
        Every path recorded is relative to the run root. An absolute path would
        bind the attestation to the directory it happened to be sealed in, so a
        run root that is legitimately moved or replayed elsewhere would read as
        tampered - a false alarm that trains readers to ignore real ones.
    #>
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$RunExecutionId,
        [AllowEmptyCollection()][object[]]$Records = @()
    )
    if ([string]::IsNullOrWhiteSpace($RunExecutionId)) {
        throw 'A census manifest must name the execution that sealed it; an empty run execution identity is refused.'
    }
    if (-not (Test-Path -LiteralPath $RunRoot -PathType Container)) {
        throw "The run root '$RunRoot' does not exist, so no census manifest can be sealed over it."
    }
    $logPath = Join-Path $RunRoot ($script:ReviewerCensusManifestLogRelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    $logDigest = Get-ReviewerCensusFileDigest -Path $logPath
    $logBytes = 0
    if ($null -ne $logDigest) { $logBytes = [int]([IO.FileInfo]::new($logPath).Length) }
    $inventory = Get-ReviewerCensusRecordInventory -Records @($Records)
    return [ordered]@{
        kind                  = $script:ReviewerCensusManifestKind
        logBytes              = [int]$logBytes
        logPath               = $script:ReviewerCensusManifestLogRelativePath
        logPresent            = [bool]($null -ne $logDigest)
        logSha256             = [string]$(if ($null -eq $logDigest) { '' } else { $logDigest })
        manifestVersion       = [int]$script:ReviewerCensusManifestVersion
        previews              = @(Get-ReviewerCensusPreviewInventory -RunRoot $RunRoot)
        recordInventory       = $inventory
        # WHY BOTH. The run root identity says WHERE this attestation was sealed;
        # the execution identity says WHICH RUN sealed it. A run root is a
        # directory that gets re-used - the next run in the same slot lands in
        # the same place - so location alone lets a cheap run's manifest be kept
        # and re-presented as an expensive run's. The execution identity is
        # minted once per reviewer process and never re-used, so a manifest
        # carrying a stale one is a stale manifest no matter where it sits.
        runExecutionId        = [string]$RunExecutionId
        runRootIdentitySha256 = Get-ReviewerCensusRunRootIdentity -RunRoot $RunRoot
    }
}

function Save-ReviewerModelStartCensusManifest {
    <#
    .SYNOPSIS
        Seals a run's census attestation. Returns the path written.
    .DESCRIPTION
        Written last, after every other artifact the run produces, because it
        digests them. Sealing earlier would attest to a state the run then leaves
        behind, and a manifest that disagrees with its own run is worse than
        none: it would report tampering on every honest run and so be switched
        off.
    #>
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][string]$RunExecutionId,
        [AllowEmptyCollection()][object[]]$Records = @()
    )
    $content = New-ReviewerModelStartCensusManifestContent -RunRoot $RunRoot -RunExecutionId $RunExecutionId -Records @($Records)
    $manifestJson = ConvertTo-ReviewerBaseContractCanonicalText -Value $content
    $key = Get-ReviewerCensusManifestKey -MasterKey $MasterKey
    $envelope = [ordered]@{
        manifestJson = $manifestJson
        signature    = Get-ReviewerCensusManifestSignature -Json $manifestJson -Key $key
        signatureAlg = 'HMACSHA256'
    }
    $path = Get-ReviewerModelStartCensusManifestPath -RunRoot $RunRoot
    $temporary = "$path." + [Guid]::NewGuid().ToString('n') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($envelope | ConvertTo-Json -Depth 8 -Compress:$false), $script:ReviewerCensusManifestUtf8)
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    return $path
}

function Read-ReviewerModelStartCensusManifest {
    <#
    .SYNOPSIS
        Reads and authenticates a run's census attestation, or throws.
    #>
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][byte[]]$MasterKey
    )
    $path = Get-ReviewerModelStartCensusManifestPath -RunRoot $RunRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The run '$RunRoot' published no census manifest, so its accounting artifacts are unauthenticated."
    }
    $envelope = $null
    try { $envelope = [IO.File]::ReadAllText($path, $script:ReviewerCensusManifestUtf8) | ConvertFrom-Json -Depth 16 }
    catch { throw "The census manifest '$path' could not be read: $($_.Exception.Message)" }
    if ($null -eq $envelope) { throw "The census manifest '$path' is empty." }
    foreach ($field in @('manifestJson', 'signature', 'signatureAlg')) {
        if (-not $envelope.PSObject.Properties[$field]) {
            throw "The census manifest '$path' carries no '$field'."
        }
    }
    if ([string]$envelope.signatureAlg -cne 'HMACSHA256') {
        throw "The census manifest '$path' declares signature algorithm '$([string]$envelope.signatureAlg)'."
    }
    $signature = [string]$envelope.signature
    if ($signature -cnotmatch '^[0-9a-f]{64}$') {
        throw "The census manifest '$path' carries a signature that is not a lowercase HMAC-SHA256 hex digest."
    }
    $manifestJson = [string]$envelope.manifestJson
    $key = Get-ReviewerCensusManifestKey -MasterKey $MasterKey
    $expected = Get-ReviewerCensusManifestSignature -Json $manifestJson -Key $key
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            [Convert]::FromHexString($expected), [Convert]::FromHexString($signature))) {
        throw "The census manifest '$path' does not verify under this run's census key."
    }
    $manifest = $null
    try { $manifest = $manifestJson | ConvertFrom-Json -Depth 32 }
    catch { throw "The census manifest '$path' carries a body this build cannot parse." }
    if ([string]$manifest.kind -cne $script:ReviewerCensusManifestKind) {
        throw "The census manifest '$path' declares kind '$([string]$manifest.kind)'."
    }
    if ([int]$manifest.manifestVersion -ne $script:ReviewerCensusManifestVersion) {
        throw "The census manifest '$path' declares version $([int]$manifest.manifestVersion), which this build does not verify."
    }
    return $manifest
}

function Get-ReviewerCensusKeyFromRunRoot {
    <#
    .SYNOPSIS
        The signing key stored in a run's own state directory, or $null.

    .DESCRIPTION
        Read-only on purpose. The reviewer's own accessor MINTS a key when none
        is there, which is right for a run that is about to sign things and
        exactly wrong for a reader: a census that minted a key would verify
        nothing and then report success under a key it had just invented.
        Absence is reported as absence.

        WHAT THIS KEY IS AND IS NOT GOOD FOR. It lives INSIDE the directory it
        would be authenticating. Anything that can rewrite this run's log or
        previews can also drop its own key here and re-sign the manifest over the
        doctored evidence, so a signature checked with this key proves only
        self-consistency: that whoever wrote the evidence also wrote the
        attestation. It cannot establish that the reviewer wrote either. Callers
        therefore get this key clearly labelled as run-root-sourced, and the
        authenticity verdict refuses to call a run AUTHENTICATED on the strength
        of it - see Test-ReviewerModelStartCensusAuthenticity. It is still worth
        reading, because a self-consistency failure is a real finding, but it is
        never the basis for believing a count.

        The census manifest is sealed under the per-user MASTER key rather than
        the replay-derived run key. The replay derivation exists so that a replay
        artifact can never verify against the key that promotion reads with -
        it is a publication control. A census manifest is never promoted and
        carries no review content; it attests to file digests. Binding it to the
        replay derivation would only mean a replayed run root could not have its
        own accounting checked, which is the opposite of the goal.
    #>
    param([Parameter(Mandatory)][string]$RunRoot)
    $keyPath = Join-Path $RunRoot 'artifact-signing.key'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { return $null }
    $line = ''
    try { $line = ([IO.File]::ReadAllText($keyPath)).Trim() } catch { return $null }
    if ($line.Length -eq 0) { return $null }
    $format = $(if ($IsWindows) { 'dpapi' } else { 'raw' })
    $separator = $line.IndexOf(':')
    if ($separator -gt 0) {
        $format = $line.Substring(0, $separator)
        $line = $line.Substring($separator + 1)
    }
    $stored = $null
    try { $stored = [Convert]::FromBase64String($line) } catch { return $null }
    switch ($format) {
        'raw' { return , $stored }
        'dpapi' {
            try {
                return , [Security.Cryptography.ProtectedData]::Unprotect(
                    $stored, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            }
            catch { return $null }
        }
        default { return $null }
    }
}

function Test-ReviewerCensusPathInsideRunRoot {
    <#
    .SYNOPSIS
        Whether a resolved path is genuinely inside the run root being audited.

    .DESCRIPTION
        Compared after full resolution, so '..' segments, mixed separators and a
        differently-cased spelling of the same directory all reduce to the same
        answer. A path that cannot be resolved at all is not inside anything and
        is refused: this is a containment check, and it fails closed.

        The separator is appended to both sides before comparing so that a
        sibling directory whose name merely STARTS with the run root's name -
        'run-42-evil' next to 'run-42' - is not mistaken for a child of it.
    #>
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $rootFull = ''
    $pathFull = ''
    try {
        $rootFull = [IO.Path]::GetFullPath($RunRoot).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar
        $pathFull = [IO.Path]::GetFullPath($Path)
    }
    catch { return $false }
    $comparison = [StringComparison]::Ordinal
    if ($IsWindows) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    return $pathFull.StartsWith($rootFull, $comparison)
}

function Get-ReviewerCensusPreviewSignature {
    param(
        [Parameter(Mandatory)][string]$ManifestJson,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][string]$RunExecutionId
    )
    $payload = "devpilot.reviewer.census-preview.v1`0$RunExecutionId`0$ManifestJson"
    $signer = [Security.Cryptography.HMACSHA256]::new($MasterKey)
    try {
        return [Convert]::ToHexString(
            $signer.ComputeHash($script:ReviewerCensusManifestUtf8.GetBytes($payload))).ToLowerInvariant()
    }
    finally { $signer.Dispose() }
}

function Test-ReviewerModelStartCensusAuthenticity {
    <#
    .SYNOPSIS
        Whether a run's accounting artifacts are the ones its reviewer attested
        to, and if not, exactly which of them are not.

    .DESCRIPTION
        Returns a verdict rather than throwing, because the census's answer to
        unauthenticated evidence is to BLOCK - report the run incomplete with a
        reason - and not to abort a cohort walk. Every objection is collected, so
        one failure does not hide the next.

        The checks, in the order a reader should think about them:

          1. a manifest exists and verifies under the run's own census key. No
             key, no manifest, wrong key, edited body: all objections.
          2. the cycle log's bytes hash to what the manifest recorded.
          3. the record inventory the log yields equals the attested inventory,
             so a log rewritten into a smaller but internally consistent set is
             caught by name.
          4. the set of verification previews on disk is EXACTLY the attested
             set - no additions, no removals, compared by ordinal name - and each
             one's bytes hash to what was attested.
          5. for every preview, the input artifact it names is present and hashes
             to the digest that preview itself published. This is the check that
             stops an input being swapped underneath a preview that is otherwise
             perfectly sealed. A preview that declares the reviewed side's
             evidence-loss tuple - empty input path with an all-zero digest - is
             not asked to produce an input, because by construction it has none;
             it is already charged as lost evidence by the census.
    #>
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [byte[]]$MasterKey,
        [AllowEmptyCollection()][object[]]$Records = @(),
        [AllowEmptyString()][string]$ExpectedRunExecutionId = '',
        [switch]$CorroborateExecutionFromRecords,
        [AllowNull()][Collections.Generic.Dictionary[string, object]]$PreviewSnapshot = $null,
        [switch]$CompareRecordInventory
    )
    # A CALLER MUST NAME ITS WITNESS. An expectation that defaults to empty is not
    # a check: the caller that omits it - and the caller an attacker arranges to be
    # - silently gets back the replayable behaviour this parameter exists to
    # remove, with nothing in the verdict to say so. So there is no omitted form.
    # Either the caller knows the execution it asked about, or it says out loud
    # that it is relying on the weaker witness in the accounting records.
    if ([string]::IsNullOrWhiteSpace($ExpectedRunExecutionId) -and -not $CorroborateExecutionFromRecords) {
        throw ('A census cannot be authenticated without saying which execution it is about. Pass ' +
            '-ExpectedRunExecutionId with the execution this audit was asked about, or pass ' +
            '-CorroborateExecutionFromRecords to accept the weaker witness carried by the accounting records ' +
            'themselves. Neither is optional, because an absent expectation would silently accept a manifest ' +
            'sealed by an earlier, cheaper run in this same re-used directory.')
    }
    $objections = [Collections.Generic.List[string]]::new()
    $result = [ordered]@{
        authenticated            = $false
        basis                    = 'unverified'
        objections               = @()
        manifestPresent          = $false
        previewsVerified         = 0
        inputsVerified           = 0
        runExecutionCorroborated = $false
    }
    $manifestPath = Get-ReviewerModelStartCensusManifestPath -RunRoot $RunRoot
    $result.manifestPresent = [bool](Test-Path -LiteralPath $manifestPath -PathType Leaf)
    if (-not $result.manifestPresent) {
        $result.basis = 'noCensusManifest'
        $objections.Add(("The run published no census manifest at '$manifestPath', so nothing it left behind can be " +
                'told apart from something written next to it. This is how every run sealed before census ' +
                'authentication existed reads, and it is reported rather than assumed either way.'))
        $result.objections = @($objections.ToArray())
        return [pscustomobject]$result
    }
    # WHERE THE KEY CAME FROM IS PART OF THE VERDICT. A key handed in by the
    # caller was held somewhere this run root could not reach. A key found inside
    # the run root was reachable by whatever wrote the evidence, so verifying
    # against it proves self-consistency and nothing more - and self-consistency
    # is exactly what a forger produces for free by re-signing the files they
    # just doctored. The distinction is carried all the way to the verdict rather
    # than resolved here, because the checks below are still worth running: they
    # say WHICH artifact disagrees, which is useful even when the key proves
    # nothing about who wrote it.
    $keyIsSelfSourced = $false
    if ($null -eq $MasterKey -or @($MasterKey).Count -eq 0) {
        $MasterKey = Get-ReviewerCensusKeyFromRunRoot -RunRoot $RunRoot
        $keyIsSelfSourced = ($null -ne $MasterKey -and @($MasterKey).Count -gt 0)
    }
    if ($null -eq $MasterKey -or @($MasterKey).Count -eq 0) {
        $result.basis = 'noCensusKey'
        $objections.Add('No signing key was supplied, so the census manifest present in this run root cannot be verified.')
        $result.objections = @($objections.ToArray())
        return [pscustomobject]$result
    }

    $manifest = $null
    try { $manifest = Read-ReviewerModelStartCensusManifest -RunRoot $RunRoot -MasterKey $MasterKey }
    catch {
        $result.basis = 'censusManifestRejected'
        $objections.Add([string]$_.Exception.Message)
        $result.objections = @($objections.ToArray())
        return [pscustomobject]$result
    }

    # THE MANIFEST MUST BE ABOUT THIS RUN. Every run belonging to one operator
    # seals under the same master key, so without this check a correctly signed
    # manifest from a cheaper run - carried in alongside that run's log and
    # previews - verifies perfectly here and reports its own smaller count as
    # authenticated. That is a signed undercount, which is the one outcome this
    # whole mechanism exists to make impossible.
    $expectedRunIdentity = Get-ReviewerCensusRunRootIdentity -RunRoot $RunRoot
    $attestedRunIdentity = ''
    if ($manifest.PSObject.Properties['runRootIdentitySha256']) {
        $attestedRunIdentity = [string]$manifest.runRootIdentitySha256
    }
    if ($attestedRunIdentity.Length -eq 0) {
        $objections.Add(('The census manifest binds no run identity, so it cannot be told apart from a manifest sealed ' +
                'over a different run and copied here.'))
    }
    elseif ($attestedRunIdentity -cne $expectedRunIdentity) {
        $objections.Add(('The census manifest was sealed over a different run root than the one being audited, so the ' +
                'accounting it attests to belongs to another run.'))
    }

    # THE MANIFEST MUST BE ABOUT THIS EXECUTION, NOT JUST THIS PLACE. A run root
    # is re-used: the next run in the same slot lands in the same directory under
    # the same key, so run-root identity alone lets a cheaper earlier run's
    # manifest be kept in place and re-presented. The execution identity is
    # minted once per reviewer process, so it separates those two runs.
    #
    # There are two witnesses, and the caller has already had to say which one it
    # is relying on:
    #
    #   - an EXPECTED identity, handed in from OUTSIDE the run root. Strong:
    #     nothing that can write into the run root can produce it.
    #   - the accounting records, each stamped with the execution that wrote it.
    #     Weaker - a forger who replaces the log replaces these too - but it is
    #     exactly what catches the realistic replay, where a stale manifest is
    #     left beside a log the current run really did write. When this is the
    #     witness in use, the ABSENCE of any record identity is itself an
    #     objection: a census with no witness at all must not authenticate.
    [string]$attestedExecution = ''
    if ($manifest.PSObject.Properties['runExecutionId']) {
        $attestedExecution = [string]$manifest.runExecutionId
    }
    [string[]]$recordExecutions = @(Get-ReviewerCensusRecordExecutionId -Records @($Records))
    if ($attestedExecution.Length -eq 0) {
        $objections.Add(('The census manifest names no execution identity, so it cannot be told apart from a manifest ' +
                'sealed by an earlier run in this same directory.'))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ExpectedRunExecutionId)) {
        if ($attestedExecution -cne [string]$ExpectedRunExecutionId) {
            $objections.Add(("The census manifest was sealed by execution '$attestedExecution', not by the execution this " +
                    'census was asked to audit. A manifest left behind by an earlier run in the same directory is refused.'))
        }
        else { $result.runExecutionCorroborated = $true }
    }
    elseif (@($recordExecutions).Count -eq 0) {
        $objections.Add(('No accounting record under this run root names the execution that wrote it, so the census was ' +
                'asked to corroborate the manifest against the log and the log can witness nothing. A manifest left ' +
                'behind by an earlier run in this same directory would be indistinguishable from this one.'))
    }
    elseif (@($recordExecutions) -cnotcontains $attestedExecution) {
        $objections.Add(("The census manifest was sealed by execution '$attestedExecution', which wrote none of " +
                'the accounting records this census read. The manifest and the log describe different runs.'))
    }
    else { $result.runExecutionCorroborated = $true }
    # The log is a second opinion even when the strong witness decided, so a
    # manifest that matches the caller's expectation but disagrees with the
    # records beside it is still reported.
    if ($attestedExecution.Length -gt 0 -and -not [string]::IsNullOrWhiteSpace($ExpectedRunExecutionId) -and
        @($recordExecutions).Count -gt 0 -and @($recordExecutions) -cnotcontains $attestedExecution) {
        $objections.Add(("The census manifest was sealed by execution '$attestedExecution', which wrote none of " +
                'the accounting records this census read. The manifest and the log describe different runs.'))
    }

    $logPath = Join-Path $RunRoot ([string]$manifest.logPath -replace '/', [IO.Path]::DirectorySeparatorChar)
    $logDigest = Get-ReviewerCensusFileDigest -Path $logPath
    if ([bool]$manifest.logPresent) {
        if ($null -eq $logDigest) {
            $objections.Add("The census manifest attests to a cycle log at '$([string]$manifest.logPath)' that is no longer there.")
        }
        elseif ($logDigest -cne ([string]$manifest.logSha256)) {
            $objections.Add(("The cycle log '$([string]$manifest.logPath)' hashes to $logDigest, not the " +
                    "$([string]$manifest.logSha256) its run attested to. The accounting records it carries are not this run's."))
        }
    }
    elseif ($null -ne $logDigest) {
        $objections.Add("The run attested to having no cycle log, and one is present at '$([string]$manifest.logPath)'.")
    }

    if ($CompareRecordInventory) {
        $liveInventory = Get-ReviewerCensusRecordInventory -Records @($Records)
        $liveModeText = (ConvertTo-ReviewerBaseContractCanonicalText -Value $liveInventory)
        $attestedModeText = (ConvertTo-ReviewerBaseContractCanonicalText -Value $manifest.recordInventory)
        if ($liveModeText -cne $attestedModeText) {
            $objections.Add(('The per-mode and per-role record inventory read from the cycle log is not the inventory the ' +
                    'run attested to, so the log describes a different run than the one that sealed this manifest.'))
        }
    }

    $liveP = @(Get-ReviewerCensusPreviewInventory -RunRoot $RunRoot)
    $attestedP = @($manifest.previews)
    $attestedByName = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($row in $attestedP) { $attestedByName[[string]$row.name] = [string]$row.sha256 }
    $liveByName = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($row in $liveP) { $liveByName[[string]$row.name] = [string]$row.sha256 }
    # THE CALLER'S READ IS THE WHOLE READ. When the caller already read the
    # previews in order to count them, that read decides both WHICH previews
    # exist and WHAT they contain: a fresh enumeration here would authenticate
    # bytes nobody counted, and the gap between the two reads is exactly where a
    # writer can show the count a thinner set - one preview renamed aside - and
    # the check a complete one. Substituting content was already refused; hiding
    # a whole preview from the count and restoring it before this ran would
    # otherwise be verified from disk, counted toward previewsVerified, and raise
    # nothing, because the extras loop below only objects to names that are not
    # attested. Assignment ids are deduplicated ACROSS previews precisely because
    # different previews carry different sets, so a dropped preview drops real
    # assignments - a signed, self-consistent UNDERCOUNT.
    #
    # So the snapshot replaces the inventory rather than overwriting rows in it,
    # and anything on disk the caller did not read is an objection in its own
    # right rather than something this function reads for itself.
    if ($null -ne $PreviewSnapshot) {
        [string[]]$onDiskNames = @([string[]]@($liveByName.Keys))
        $liveByName = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        foreach ($name in @([string[]]@($PreviewSnapshot.Keys))) {
            $liveByName[[string]$name] = [string]$PreviewSnapshot[$name].sha256
        }
        foreach ($name in @($onDiskNames | Sort-Object -CaseSensitive)) {
            if (-not $liveByName.ContainsKey([string]$name)) {
                $objections.Add(("The verification preview '$name' is present under the run root but was not read by the " +
                        'census being authenticated, so it was hidden from the count this manifest is being checked against.'))
            }
        }
    }
    foreach ($name in @([string[]]@($attestedByName.Keys) | Sort-Object -CaseSensitive)) {
        if (-not $liveByName.ContainsKey($name)) {
            $objections.Add("The attested verification preview '$name' is missing, so what it recorded is unknown rather than none.")
            continue
        }
        if ([string]$liveByName[$name] -cne [string]$attestedByName[$name]) {
            $objections.Add("The verification preview '$name' does not hash to the digest its run attested to.")
            continue
        }
        $result.previewsVerified = [int]$result.previewsVerified + 1
    }
    foreach ($name in @([string[]]@($liveByName.Keys) | Sort-Object -CaseSensitive)) {
        if (-not $attestedByName.ContainsKey($name)) {
            $objections.Add("The verification preview '$name' was added after this run sealed its census manifest.")
        }
    }

    # The input a preview stands on is named BY the preview and is not itself
    # sealed by the preview's signature, so a preview can be entirely valid over
    # an input that has since been replaced. Rehashing it here is what closes
    # that gap.
    $previewDirectory = Join-Path $RunRoot $script:ReviewerCensusManifestPreviewDirectory
    foreach ($name in @([string[]]@($liveByName.Keys) | Sort-Object -CaseSensitive)) {
        if (-not $attestedByName.ContainsKey($name)) { continue }
        if ([string]$liveByName[$name] -cne [string]$attestedByName[$name]) { continue }
        $previewPath = Join-Path $previewDirectory $name
        $envelope = $null
        # Same rule as above: the caller's buffer decides. Re-reading here would
        # check the input containment of a preview other than the one counted.
        if ($null -ne $PreviewSnapshot -and $PreviewSnapshot.ContainsKey([string]$name)) {
            try { $envelope = [string]$PreviewSnapshot[$name].text | ConvertFrom-Json -Depth 64 }
            catch {
                $objections.Add("The verification preview '$name' could not be read while checking the input it stands on.")
                continue
            }
        }
        else {
            try { $envelope = [IO.File]::ReadAllText($previewPath, $script:ReviewerCensusManifestUtf8) | ConvertFrom-Json -Depth 64 }
            catch {
                $objections.Add("The verification preview '$name' could not be read while checking the input it stands on.")
                continue
            }
        }
        if ($null -eq $envelope -or -not $envelope.PSObject.Properties['manifestJson']) {
            $objections.Add("The verification preview '$name' carries no manifest.")
            continue
        }
        $previewManifestJson = [string]$envelope.manifestJson
        if (-not $keyIsSelfSourced) {
            $previewSignatureAlg = if ($envelope.PSObject.Properties['censusSignatureAlg']) {
                [string]$envelope.censusSignatureAlg
            } else { '' }
            $previewExecution = if ($envelope.PSObject.Properties['censusRunExecutionId']) {
                [string]$envelope.censusRunExecutionId
            } else { '' }
            $previewSignature = if ($envelope.PSObject.Properties['censusSignature']) {
                [string]$envelope.censusSignature
            } else { '' }
            if ($previewSignatureAlg -cne 'HMACSHA256' -or
                $previewExecution -cnotmatch '^[0-9a-f]{32}\z' -or
                $previewSignature -cnotmatch '^[0-9a-f]{64}\z') {
                $objections.Add(("The verification preview '$name' has no external census signature and execution " +
                        'binding, so the final census cannot endorse its assignment count.'))
                continue
            }
            if ($previewExecution -cne $attestedExecution) {
                $objections.Add(("The verification preview '$name' was sealed by execution '$previewExecution', not " +
                        "the census execution '$attestedExecution'."))
                continue
            }
            $expectedPreviewSignature = Get-ReviewerCensusPreviewSignature -ManifestJson $previewManifestJson `
                -MasterKey $MasterKey -RunExecutionId $previewExecution
            if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                    [Convert]::FromHexString($expectedPreviewSignature),
                    [Convert]::FromHexString($previewSignature))) {
                $objections.Add("The verification preview '$name' failed its external census signature.")
                continue
            }
        }
        $previewManifest = $null
        try { $previewManifest = $previewManifestJson | ConvertFrom-Json -Depth 64 }
        catch { continue }
        if ($null -eq $previewManifest) { continue }
        if (-not $keyIsSelfSourced -and
            (-not $previewManifest.PSObject.Properties['runExecutionId'] -or
                [string]$previewManifest.runExecutionId -cne $attestedExecution)) {
            $objections.Add(("The verification preview '$name' manifest is not bound to census execution " +
                    "'$attestedExecution'."))
            continue
        }
        if (-not $previewManifest.PSObject.Properties['inputArtifactPath'] -or
            -not $previewManifest.PSObject.Properties['inputManifestSha256']) {
            continue
        }
        $declaredPath = [string]$previewManifest.inputArtifactPath
        $declaredManifestDigest = [string]$previewManifest.inputManifestSha256
        if ($declaredManifestDigest -cnotmatch '^[0-9a-f]{64}$') {
            $objections.Add("The verification preview '$name' names an input manifest digest that is not a lowercase SHA-256.")
            continue
        }
        # Older standalone artifacts remain readable for diagnostics, but an
        # externally authenticated census cannot endorse an input it cannot
        # recheck byte-for-byte.
        if (-not $previewManifest.PSObject.Properties['inputArtifactSha256']) {
            if (-not $keyIsSelfSourced) {
                $objections.Add(("The verification preview '$name' predates the signed input-artifact digest, so an " +
                        'externally authenticated census cannot establish what input bytes it verified.'))
            }
            continue
        }
        $declaredDigest = [string]$previewManifest.inputArtifactSha256
        if ($declaredPath.Length -eq 0 -and $declaredManifestDigest -ceq ('0' * 64) -and
            $declaredDigest -ceq ('0' * 64)) {
            continue
        }
        if ($declaredDigest -cnotmatch '^[0-9a-f]{64}$') {
            $objections.Add("The verification preview '$name' names an input artifact digest that is not a lowercase SHA-256.")
            continue
        }
        $resolved = $declaredPath
        if (-not [IO.Path]::IsPathRooted($resolved)) { $resolved = Join-Path $RunRoot ($declaredPath -replace '/', [IO.Path]::DirectorySeparatorChar) }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            # A preview names its input by the absolute path the run saw. A run
            # root that is legitimately moved - a replay checkout, an archived
            # slot, a harness temp tree - keeps the artifact and loses the path,
            # so the same file is looked for under this run root before the
            # absence is believed. The digest still decides; only the search
            # widens, and it widens only within the run root being audited.
            $rebased = Join-Path $RunRoot (Join-Path 'verification-inputs' ([IO.Path]::GetFileName($declaredPath)))
            if (Test-Path -LiteralPath $rebased -PathType Leaf) { $resolved = $rebased }
        }
        # CONTAINMENT. The path is named by the preview, and the preview is a
        # file an attacker may have written, so an unconstrained path lets the
        # attestation be satisfied by ANY readable file on the machine that
        # happens to carry the expected digest - including one the attacker put
        # there. Everything this census attests to must live inside the run root
        # it is auditing, so the resolved path is required to.
        if (-not (Test-ReviewerCensusPathInsideRunRoot -RunRoot $RunRoot -Path $resolved)) {
            $objections.Add(("The verification preview '$name' names an input artifact outside the run root being " +
                    'audited, so what it stands on is not this run''s evidence and is not accepted as proof of it.'))
            continue
        }
        [byte[]]$inputBytes = $null
        try { $inputBytes = [IO.File]::ReadAllBytes($resolved) }
        catch { $inputBytes = $null }
        if ($null -eq $inputBytes) {
            $objections.Add(("The verification preview '$name' stands on the input artifact '$declaredPath', which is not " +
                    'present, so what was verified cannot be established.'))
            continue
        }
        $actual = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($inputBytes)).ToLowerInvariant()
        if ($actual -cne $declaredDigest) {
            $objections.Add(("The input artifact '$declaredPath' that verification preview '$name' stands on hashes to " +
                    "$actual, not the $declaredDigest the preview published. The preview is sealed over an input that " +
                    'has since been replaced.'))
            continue
        }
        try {
            $inputEnvelope = $script:ReviewerCensusManifestUtf8.GetString($inputBytes) | ConvertFrom-Json -Depth 64
            $inputManifest = [string]$inputEnvelope.manifestJson | ConvertFrom-Json -Depth 64
        }
        catch {
            $objections.Add(("The input artifact '$declaredPath' that verification preview '$name' stands on cannot " +
                    'be read as the signed input envelope whose bytes it names.'))
            continue
        }
        if ($null -eq $inputManifest -or
            -not $inputManifest.PSObject.Properties['inputManifestSha256'] -or
            [string]$inputManifest.inputManifestSha256 -cne $declaredManifestDigest) {
            $objections.Add(("The input artifact '$declaredPath' that verification preview '$name' stands on does not " +
                    "carry its declared canonical manifest digest '$declaredManifestDigest'."))
            continue
        }
        $result.inputsVerified = [int]$result.inputsVerified + 1
    }

    if ($objections.Count -eq 0 -and $keyIsSelfSourced) {
        # Every check passed, and every check was made with a key that lived
        # inside the directory it was checking. Whoever wrote the evidence could
        # have written this key and re-signed over their own edits, so what has
        # been established is that the run root is internally consistent - not
        # that the reviewer produced it. Reporting that as authentication would
        # hand an attacker the exact word an operator is looking for.
        $result.basis = 'selfAttestedCensusKey'
        $objections.Add(('The census manifest verified only under a signing key read from the run root it attests to. ' +
                'Anything able to rewrite this run''s accounting could also have written that key, so the manifest ' +
                'shows the run root is self-consistent and cannot show who made it so. Supply the operator-held ' +
                'master key to authenticate this run.'))
    }
    if ($objections.Count -eq 0) {
        $result.authenticated = $true
        $result.basis = 'signedCensusManifest'
    }
    else {
        $result.basis = [string]$(if ([string]$result.basis -ceq 'unverified') { 'censusEvidenceMismatch' } else { [string]$result.basis })
    }
    $result.objections = @($objections.ToArray())
    return [pscustomobject]$result
}
