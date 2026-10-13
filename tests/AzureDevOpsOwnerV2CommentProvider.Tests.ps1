#requires -Version 7.0

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot `
        'src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1')
}

Describe 'Azure DevOps Owner v2 CLI transport' {
    It 'preserves non-BMP JSON text as exact UTF-8' {
        $folder = [char]::ConvertFromUtf32(0x1F4C2)
        $script = @'
$folder = [char]::ConvertFromUtf32(0x1F4C2)
[Console]::OutputEncoding =
    [Text.UTF8Encoding]::new($false)
[Console]::Out.Write(
    (@{ content = "$folder$folder$folder" } |
        ConvertTo-Json -Compress))
'@
        $result = Invoke-ApprovedOwnerV2AzureCliJson `
            -AzureCliPath (
                (Get-Command pwsh -CommandType Application).
                    Source) `
            -Arguments @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                $script)

        [string]$result.content |
            Should -BeExactly "$folder$folder$folder"
    }
}
