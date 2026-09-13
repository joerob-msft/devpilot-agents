param(
    [Parameter(Mandatory)][string]$Mode,
    [string]$StatePath = '-'
)

$ErrorActionPreference = 'Stop'
if ($StatePath -ceq '-') { $StatePath = $null }

$line = [Console]::In.ReadLine()
if ($null -eq $line) { exit 22 }

if ($StatePath) {
    $request = $line | ConvertFrom-Json -AsHashtable -Depth 16
    $summary = [ordered]@{
        method = $request.method
        protocolVersion = $request.params.protocolVersion
        clientCapabilities = $request.params.clientCapabilities
        commandLine = [Environment]::CommandLine
        environmentNames = @(
            Get-ChildItem env: | Select-Object -ExpandProperty Name | Sort-Object
        )
    }
    [IO.File]::WriteAllText(
        $StatePath,
        (ConvertTo-Json -InputObject $summary -Depth 8 -Compress),
        [Text.UTF8Encoding]::new($false))
}

$result = [ordered]@{
    jsonrpc = '2.0'
    id = 1
    result = [ordered]@{
        protocolVersion = 1
        agentCapabilities = [ordered]@{
            loadSession = $false
            mcpCapabilities = [ordered]@{
                http = $true
                sse = $true
            }
            promptCapabilities = [ordered]@{
                image = $true
                audio = $false
                embeddedContext = $true
            }
            sessionCapabilities = [ordered]@{
                close = @{}
            }
        }
        agentInfo = [ordered]@{
            name = 'Owner ACP deterministic fake'
            version = '1.0.79'
        }
        authMethods = @()
    }
}

switch ($Mode) {
    'persistent' {
        $result.result.agentCapabilities.loadSession = $true
        $result.result.agentCapabilities.sessionCapabilities.list = @{}
    }
    'wrong-id' { $result.id = 2 }
    'wrong-version' { $result.result.protocolVersion = 2 }
    'malformed' {
        [Console]::Out.WriteLine('{')
        exit 0
    }
    'bad-utf8' {
        $stream = [Console]::OpenStandardOutput()
        $stream.Write([byte[]]@(0xff, 0x0a))
        $stream.Flush()
        exit 0
    }
    'duplicate-property' {
        [Console]::Out.WriteLine(
            '{"jsonrpc":"2.0","id":1,"id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}')
        exit 0
    }
    'extra-message' {
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $result -Depth 8 -Compress))
        [Console]::Out.WriteLine('{"jsonrpc":"2.0","method":"session/update","params":{}}')
        exit 0
    }
    'stdout-flood' {
        [Console]::Out.Write(('x' * 131072))
        exit 0
    }
    'stderr-flood' {
        [Console]::Error.Write(('private-diagnostic-' + ('x' * 131072)))
        exit 0
    }
    'disconnect' { exit 0 }
    'timeout' {
        Start-Sleep -Seconds 30
        exit 0
    }
    'descendant' {
        $pwsh = (Get-Command pwsh).Source
        $descendant = Start-Process -FilePath $pwsh -PassThru -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
        if ($StatePath) {
            [IO.File]::WriteAllText($StatePath, [string]$descendant.Id)
        }
        Start-Sleep -Seconds 30
        exit 0
    }
}

[Console]::Out.WriteLine((ConvertTo-Json -InputObject $result -Depth 8 -Compress))
