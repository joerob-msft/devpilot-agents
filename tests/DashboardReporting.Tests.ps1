BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Launcher = Join-Path $script:RepoRoot 'tools\Start-DevPilotDashboard.ps1'
    $script:Sample = Join-Path $script:RepoRoot 'samples\owner-v2-reporting.config.json'
    $script:ReportingSource = Join-Path $script:RepoRoot 'src\DevPilot.Dashboard\src\reporting.ts'
}

Describe 'Owner reporting dashboard startup boundary' {
    It 'accepts a reporting-only configuration during startup validation' {
        $dashboardRoot = Join-Path $script:RepoRoot 'src\DevPilot.Dashboard'
        $npm = (Get-Command npm -CommandType Application -ErrorAction Stop |
                Select-Object -First 1).Source
        Push-Location $dashboardRoot
        try {
            $buildOutput = & $npm run build 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($buildOutput -join [Environment]::NewLine)
        }
        finally {
            Pop-Location
        }
        $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop |
                Select-Object -First 1).Source
        $output = & $pwsh -NoProfile -NonInteractive -File $script:Launcher `
            -ReportingConfigPath $script:Sample -ValidateOnly 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'keeps the local reporting adapter free of provider and task mutation commands' {
        $source = Get-Content -LiteralPath $script:ReportingSource -Raw
        $source | Should -Not -Match 'CreateThread|UpdateComment|Invoke-RestMethod'
        $source | Should -Not -Match 'Register-ScheduledTask|Set-ScheduledTask|Unregister-ScheduledTask'
    }
}
