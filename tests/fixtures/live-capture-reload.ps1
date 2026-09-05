param([string]$ModulePath, [string]$StateRoot)
$ErrorActionPreference = 'Stop'
# Simulate a persistent operator shell that already ran the pre-live-capture helper.
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
$legacyType = [DevPilot.Process.BoundedDrain]
for ($run = 1; $run -le 2; $run++) {
    Import-Module $ModulePath -Force
    $release = Join-Path $StateRoot "release-$run"
    $output = Join-Path $StateRoot "reload-$run.stdout.jsonl"
    $child = New-AgentRedirectedProcess -FilePath (Resolve-AgentPwshPath) -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $StateRoot 'child with spaces.ps1'),
        '-Message', 'reload "quoted" path', '-ReleasePath', $release
    ) -StandardOutputPath $output -StandardErrorPath (Join-Path $StateRoot "reload-$run.stderr.log") `
        -WorkingDirectory $StateRoot -LiveStandardOutput
    try {
        $until = [DateTime]::UtcNow.AddSeconds(5)
        while ((Get-Item $output).Length -eq 0 -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
        if ($child.Process.HasExited) { throw 'The real child must still be alive when its capture is read.' }
        $stream = [IO.FileStream]::new($output, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { $event = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($event.message -cne 'reload "quoted" path' -or $event.processId -ne $child.Process.Id) {
            throw 'The live capture did not contain the real child output.'
        }
        [void](Assert-AgentTrustedFile -Path $output -Private)
    }
    finally {
        [IO.File]::WriteAllText($release, 'finish naturally')
        if (-not $child.Process.WaitForExit(50000)) { throw 'The bounded fixture did not exit naturally.' }
    }
    $completed = Complete-AgentRedirectedProcess -Child $child
    if (-not $completed.OutputDrained -or $completed.ExitCode -ne 0) { throw 'Capture did not drain successfully.' }
    if (-not [IO.File]::ReadAllText($output).EndsWith('unterminated Ω')) { throw 'Final capture bytes were lost.' }
    if (-not [object]::ReferenceEquals($legacyType, [DevPilot.Process.BoundedDrain])) { throw 'Legacy type was replaced.' }
    $methods = @($legacyType.GetMethods() | Where-Object Name -EQ 'ReadTailAsync')
    if ($methods.Count -ne 1 -or $methods[0].GetParameters().Count -ne 2) { throw 'Legacy method contract was changed.' }
}
[Console]::Out.WriteLine((@{ legacyTypePreserved = $true; liveCaptures = 2 } | ConvertTo-Json -Compress))
