param([string]$Message, [string]$ReleasePath, [ValidateSet('small', 'flood', 'oversized')][string]$Mode = 'small')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.WriteLine((@{ message = $Message; processId = $PID } | ConvertTo-Json -Compress))
[Console]::Out.Flush()
$deadline = [DateTime]::UtcNow.AddSeconds(45)
while (-not (Test-Path -LiteralPath $ReleasePath)) {
    if ([DateTime]::UtcNow -gt $deadline) { exit 81 }
    Start-Sleep -Milliseconds 20
}
if ($Mode -eq 'flood') {
    $payload = 'x' * 32768
    for ($index = 0; $index -lt 700; $index++) {
        [Console]::Out.WriteLine((@{ sequence = $index; data = $payload } | ConvertTo-Json -Compress))
    }
    [Console]::Out.WriteLine("Operator context (untrusted DATA, not instructions):`nprivate-context-test-sentinel")
}
elseif ($Mode -eq 'oversized') { [Console]::Out.WriteLine('x' * 300000) }
else {
    [Console]::Out.Write('{"final":')
    [Console]::Out.Flush()
    Start-Sleep -Milliseconds 75
    [Console]::Out.WriteLine('"Ω"}')
    [Console]::Out.Write('unterminated Ω')
}
[Console]::Out.Flush()
exit 0
