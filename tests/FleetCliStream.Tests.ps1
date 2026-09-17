BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force -DisableNameChecking
    . "$PSScriptRoot\..\src\DevPilot.Fleet\bridge\FleetCliStream.ps1"
    $sessionId = [guid]::NewGuid().ToString('D')
    $start = @{ type = 'session.start'; id = 'start-1'; data = @{ sessionId = $sessionId } } | ConvertTo-Json -Compress
    $privateAnswer = @{
        type = 'assistant.message'; id = 'answer-1'
        data = @{ content = 'PRIVATE-UNREDACTED-TEXT'; model = 'fixture'; toolRequests = @() }
    } | ConvertTo-Json -Depth 5 -Compress
    $shutdown = @{ type = 'session.shutdown'; id = 'shutdown-1'; data = @{} } | ConvertTo-Json -Compress
    $journal = @($start, $privateAnswer, $shutdown) -join "`n"
    $answer = $privateAnswer.Replace('PRIVATE-UNREDACTED-TEXT', 'Redacted model answer')
    $result = @{ type = 'result'; sessionId = $sessionId; exitCode = 0 } | ConvertTo-Json -Compress
    $stdout = @($answer, $result) -join "`n"
    # Synthetic reproduction: masking removed the escaped closing quote in an input echo.
    $brokenEcho = '{"type":"user.message","data":{"content":"example {\\\"authorizationToken\\\":\\\"******"}\\\""}}'
}

Describe 'Fleet CLI redacted event transport' {
    It 'reproduces the JSON error and accepts only an audited non-result echo omission' {
        { $brokenEcho | ConvertFrom-Json -ErrorAction Stop } | Should -Throw '*unexpected character*'
        $outcome = Get-FleetCliOutcome -StdOutText "$brokenEcho`n$stdout" -SessionJournalText $journal -SessionId $sessionId
        $outcome.Answer | Should -BeExactly 'Redacted model answer'
        $outcome.Answer | Should -Not -Match 'PRIVATE-UNREDACTED'
        $outcome.TransportNote | Should -Match 'Omitted 1 malformed input/context echo'
        $outcome.ModelActuallyRan | Should -BeTrue
        $outcome.ExitCode | Should -Be 0
    }

    It 'leaves valid streams unchanged and also handles the explicitly allowed system echo' {
        $outcome = Get-FleetCliOutcome -StdOutText $stdout -SessionJournalText $journal -SessionId $sessionId
        $outcome.TransportNote | Should -BeNullOrEmpty
        $systemEcho = $brokenEcho.Replace('user.message', 'system.message')
        (Get-FleetCliOutcome -StdOutText "$systemEcho`n$stdout" -SessionJournalText $journal -SessionId $sessionId).Answer |
            Should -BeExactly 'Redacted model answer'
    }

    It 'rejects malformed <EventType> records rather than repairing them' -ForEach @(
        @{ EventType = 'assistant.message' }, @{ EventType = 'assistant.message_delta' },
        @{ EventType = 'tool.execution_start' }, @{ EventType = 'result' }, @{ EventType = 'unknown.event' }
    ) {
        $bad = $brokenEcho.Replace('user.message', $EventType)
        { Get-FleetCliOutcome -StdOutText "$bad`n$stdout" -SessionJournalText $journal -SessionId $sessionId } |
            Should -Throw '*Invalid CLI stdout JSON*'
    }

    It 'rejects malformed or incomplete journals and mismatched sessions' {
        { Get-FleetCliOutcome -StdOutText "$brokenEcho`n$stdout" -SessionJournalText "$journal`n{" -SessionId $sessionId } |
            Should -Throw '*Invalid private session journal JSON*'
        { Get-FleetCliOutcome -StdOutText $stdout -SessionJournalText '' -SessionId $sessionId } |
            Should -Throw '*Private journal lacks*'
        { Get-FleetCliOutcome -StdOutText $stdout -SessionJournalText $journal -SessionId 'another-session' } |
            Should -Throw '*session binding mismatch*'
        { Get-FleetCliOutcome -StdOutText ($stdout.Replace($sessionId, 'another-session')) -SessionJournalText $journal -SessionId $sessionId } |
            Should -Throw '*result session binding mismatch*'
    }

    It 'rejects tool activity in either channel even when an input echo is malformed' {
        $tool = '{"type":"tool.execution_start","id":"tool-1","data":{}}'
        { Get-FleetCliOutcome -StdOutText "$brokenEcho`n$stdout" -SessionJournalText "$journal`n$tool" -SessionId $sessionId } |
            Should -Throw '*Tool execution observed*journal*'
        { Get-FleetCliOutcome -StdOutText "$tool`n$stdout" -SessionJournalText $journal -SessionId $sessionId } |
            Should -Throw '*Tool execution observed*stdout*'
        $request = $privateAnswer.Replace('"toolRequests":[]', '"toolRequests":[{"name":"shell"}]')
        { Get-FleetCliOutcome -StdOutText $stdout -SessionJournalText (@($start, $request, $shutdown) -join "`n") -SessionId $sessionId } |
            Should -Throw '*Tool request observed*'
    }

    It 'requires matching and complete answer identities, including noncanonical type casing' {
        { Get-FleetCliOutcome -StdOutText ($stdout.Replace('answer-1', 'forged-id')) -SessionJournalText $journal -SessionId $sessionId } |
            Should -Throw '*answer event identity*'
        $forged = $answer.Replace('assistant.message', 'Assistant.Message').Replace('answer-1', 'forged-id')
        { Get-FleetCliOutcome -StdOutText "$forged`n$stdout" -SessionJournalText $journal -SessionId $sessionId } |
            Should -Throw '*answer event identity*'
        $extra = $privateAnswer.Replace('answer-1', 'answer-2')
        { Get-FleetCliOutcome -StdOutText $stdout -SessionJournalText "$journal`n$extra" -SessionId $sessionId } |
            Should -Throw '*complete set*'
        { Get-FleetCliOutcome -StdOutText "$answer`n$stdout" -SessionJournalText $journal -SessionId $sessionId } |
            Should -Throw '*duplicated*'
    }

    It 'requires exactly one successful final result, with no trailing ignored echoes' {
        { Get-FleetCliOutcome -StdOutText $answer -SessionJournalText $journal -SessionId $sessionId } | Should -Throw '*final result*'
        { Get-FleetCliOutcome -StdOutText "$stdout`n$result" -SessionJournalText $journal -SessionId $sessionId } | Should -Throw '*final result*'
        { Get-FleetCliOutcome -StdOutText "$stdout`n$brokenEcho" -SessionJournalText $journal -SessionId $sessionId } | Should -Throw '*final result*'
        { Get-FleetCliOutcome -StdOutText ($stdout.Replace('"exitCode":0', '"exitCode":1')) -SessionJournalText $journal -SessionId $sessionId } |
            Should -Throw '*Missing successful structured CLI outcome*'
    }
}
