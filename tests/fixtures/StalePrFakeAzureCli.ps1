#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logPath = [Environment]::GetEnvironmentVariable(
    'DEVPILOT_STALE_PR_FAKE_AZ_LOG')
if ([string]::IsNullOrWhiteSpace($logPath)) {
    throw 'Fake Azure CLI log path was not configured.'
}
$inputIndex = [Array]::IndexOf(
    [object[]]$Arguments, '--in-file')
if ($inputIndex -lt 0 -or
    $inputIndex + 1 -ge $Arguments.Count) {
    throw 'Fake Azure CLI expected --in-file.'
}
$inputPath = [string]$Arguments[$inputIndex + 1]
$bytes = [IO.File]::ReadAllBytes($inputPath)
$record = [ordered]@{
    arguments = @($Arguments)
    inputPath = $inputPath
    inputExistsDuringProcess =
        Test-Path -LiteralPath $inputPath -PathType Leaf
    bodyBase64 = [Convert]::ToBase64String($bytes)
    bodyLength = $bytes.Length
}
[IO.File]::WriteAllText(
    $logPath,
    (ConvertTo-Json $record -Depth 8),
    [Text.UTF8Encoding]::new($false))
$exitText = [Environment]::GetEnvironmentVariable(
    'DEVPILOT_STALE_PR_FAKE_AZ_EXIT')
if (-not [string]::IsNullOrWhiteSpace($exitText)) {
    $exitCode = 0
    if (-not [int]::TryParse(
            $exitText, [ref]$exitCode) -or
        $exitCode -eq 0) {
        throw 'Fake Azure CLI exit code was invalid.'
    }
    Write-Output 'RAW-SECRET-MARKER-STDOUT'
    exit $exitCode
}
'{"status":"abandoned"}'
