#requires -Version 7.0

BeforeDiscovery {
    $script:Cases = @(
        @{
            Rule = 'exception-logging'
            Violation = 'class C { void M() { try { X(); } catch (Exception ex) { Logger.Error(ex.Message); } } }'
            Exemption = 'class C { void M() { try { X(); } catch (Exception ex) when (!ex.IsFatal()) { Logger.Error(message: "failed", exception: ex); } } }'
        },
        @{
            Rule = 'exception-propagation'
            Violation = 'class C { void M() { try { X(); } catch (Exception ex) { throw ex; } } }'
            Exemption = 'class C { void M() { try { X(); } catch (Exception ex) when (!ex.IsFatal()) { throw; } } }'
        },
        @{
            Rule = 'type-based-decisions'
            Violation = 'class C { bool M(Exception ex) { if (ex.Message.Contains("timeout")) { return true; } return false; } }'
            Exemption = 'class C { bool M(Exception ex) { return ex is TimeoutException; } }'
        },
        @{
            Rule = 'explicit-string-comparison'
            Violation = 'class C { bool M(string a, string b) { return a == b; } }'
            Exemption = 'class C { bool M(string a, string b) { return string.Equals(a, b, StringComparison.Ordinal); } }'
        },
        @{
            Rule = 'named-call-arguments'
            Violation = 'class C { void Target(string left, string right) {} void M() { Target("a", "b"); } }'
            Exemption = 'class C { void Target(string left, string right) {} void M() { Target(left: "a", right: "b"); } }'
        },
        @{
            Rule = 'xml-summary-layout'
            Violation = @'
class C {
/// <summary>Gets value.</summary>
public string Value { get; set; }
}
'@
            Exemption = @'
class C {
/// <summary>
/// Gets value.
/// </summary>
public string Value { get; set; }
}
'@
        },
        @{
            Rule = 'collection-cardinality'
            Violation = 'class C { object M(IEnumerable<object> values) { var matches = values.Where(x => x != null).ToList(); return matches.First(); } }'
            Exemption = 'class C { object M(IEnumerable<object> values) { var matches = values.Where(x => x != null).ToList(); if (matches.Count != 1) throw new Exception(); return matches.Single(); } }'
        },
        @{
            Rule = 'cheap-validation'
            Violation = 'class C { void M() { Func<Request, Task<bool>> validator = async request => await repository.ExistsAsync(request.Id); } }'
            Exemption = 'class C { void M() { Func<Request, bool> validator = request => request.Id != null; } }'
        },
        @{
            Rule = 'async-all-the-way'
            Violation = 'class C { string M() { return GetValueAsync().Result; } Task<string> GetValueAsync() => Task.FromResult("x"); }'
            Exemption = 'class C { Task<string> M() => GetValueAsync(); Task<string> GetValueAsync() => Task.FromResult("x"); }'
        },
        @{
            Rule = 'async-io'
            Violation = 'class C { async Task<string> M(string path) { return File.ReadAllText(path); } }'
            Exemption = 'class C { async Task<string> M(string path) { return await File.ReadAllTextAsync(path).ConfigureAwait(false); } }'
        },
        @{
            Rule = 'async-wait-sync'
            Violation = 'class C { async Task M() { Thread.Sleep(1000); await WorkAsync(); } }'
            Exemption = 'class C { async Task M(CancellationToken token) { await Task.Delay(1000, token).ConfigureAwait(false); } }'
        },
        @{
            Rule = 'http-client-lifetime'
            Violation = 'using System.Net.Http; class C { async Task M() { using var client = new HttpClient(); await client.GetAsync("https://example.invalid"); } }'
            Exemption = 'using System.Net.Http; class C { private static readonly HttpClient Client = new HttpClient(); async Task M() { await Client.GetAsync("https://example.invalid"); } }'
        },
        @{
            Rule = 'thread-safe-immutable'
            Violation = 'class C { private static Client client; Client Get() { if (client == null) { client = new Client(); } return client; } }'
            Exemption = 'class C { private static readonly Lazy<Client> Client = new Lazy<Client>(() => new Client()); }'
        },
        @{
            Rule = 'cache-streaming'
            Violation = 'class C { MethodInfo M(Type type) { var first = type.GetMethod("Run"); return type.GetMethod("Stop"); } }'
            Exemption = 'class C { private static readonly MethodInfo Run = typeof(C).GetMethod("Run"); }'
        },
        @{
            Rule = 'typed-contracts'
            Violation = 'class C { object M(JObject request) { var a = request["name"]; var b = request["count"]; return a; } }'
            Exemption = 'class Request { public string Name { get; set; } public int Count { get; set; } }'
        },
        @{
            Rule = 'json-contracts'
            Violation = '[JsonObject] class Response { public string Value { get; set; } }'
            Exemption = '[JsonObject] class Response { [JsonProperty] public string Value { get; set; } }'
        },
        @{
            Rule = 'api-errors'
            Violation = 'class WidgetController { [HttpGet] public Response Get() { throw new InvalidOperationException("bad"); } }'
            Exemption = 'class WidgetController { [HttpGet] public Response Get() { throw new ErrorResponseMessageException(HttpStatusCode.BadRequest, ErrorCode.Invalid, Resource.Invalid.ToLocalizedMessage()); } }'
        },
        @{
            Rule = 'secret-redaction'
            Violation = 'class C { TokenResponse CreateResponse(Config config) { var cached = cache.Get(); if (cached == null) { var response = new TokenResponse(); response.Token = config.Token; return response; } return cached; } }'
            Exemption = 'class C { TokenResponse CreateResponse(Config config) { var response = new TokenResponse(); response.Token = Redact(config.Token); return response; } }'
        }
    )
}

BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.ContextualConventions\DevPilot.ContextualConventions.psd1" -Force

    function New-LiteralComparisonFile {
        param(
            [string]$Content,
            [AllowEmptyString()][string]$Target = '',
            [string]$Path = 'src/C.cs',
            [string]$Project = 'src/App.csproj'
        )
        $digest = {
            param([string]$Text)
            'v1:sha256:' + [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
        }
        return @{
            path=$Path;content=$Content;state='complete';changeType='modified'
            sourceCommit=('a'*40);targetCommit=('b'*40)
            spans=@(@{startLine=1;endLine=([regex]::Split($Content, '\r?\n').Count)})
            projectContext=@{state='complete';path=$Project;content='<Project><PropertyGroup><LangVersion>latest</LangVersion></PropertyGroup></Project>'}
            comparison=@{
                schemaVersion=1;state='complete';path=$Path;targetPath=$Path
                sourceCommit=('a'*40);targetCommit=('b'*40);sourceDigest=(& $digest $Content)
                targetDigest=(& $digest $Target);byteLength=[Text.Encoding]::UTF8.GetByteCount($Target)
                content=$Target;targetState='present'
            }
        }
    }

    function Invoke-ConventionCase {
        param(
            [Parameter(Mandatory)][string]$RuleId,
            [Parameter(Mandatory)][string]$Content,
            [string]$Path = 'src/Changed.cs',
            [object[]]$SnapshotFiles = @()
        )
        $lines = [Math]::Max(
            1,
            ($Content -split "`r?`n").Count)
        $files = if ($SnapshotFiles.Count) {
            $SnapshotFiles
        }
        else {
            @([ordered]@{
                    path = $Path
                    content = $Content
                    state = 'complete'
                    projectContext = [ordered]@{
                        state = 'complete'
                        path = 'src/App.csproj'
                        content = '<Project><PropertyGroup><LangVersion>7.2</LangVersion></PropertyGroup></Project>'
                    }
                    spans = @([ordered]@{
                            startLine = 1
                            endLine = $lines
                        })
                })
        }
        if ($RuleId -ceq 'reused-string-literals') {
            foreach ($file in $files) {
                if ([string]$file.path -imatch '\.cs$' -and
                    $file.content -is [string] -and -not $file.Contains('comparison')) {
                    $file.sourceCommit='a'*40
                    $file.targetCommit='b'*40
                    $file.changeType='modified'
                    $file.comparison=(New-LiteralComparisonFile -Content $file.content -Path $file.path).comparison
                }
            }
        }
        return @(
            Get-ContextualConventionOutcomes `
                -Content $Content -Path $Path `
                -Spans @([ordered]@{
                        startLine = 1
                        endLine = $lines
                    }) `
                -SnapshotFiles $files |
                Where-Object ruleId -CEQ $RuleId)[0]
    }

    function New-SyntheticPullRequestMetadata {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$Description,
            [string]$Template = @'
**Problem:**

**Solution:**

**Validation:**
Describe what validations are needed:
- [ ] Optional full test pass

**Release Notes**
'@,
            [string]$State = 'complete'
        )
        $digest = {
            param([string]$Text)
            'v1:sha256:' + [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.UTF8Encoding]::new($false).
                        GetBytes($Text))).
                ToLowerInvariant()
        }
        if ($State -cne 'complete') {
            return [ordered]@{
                state = 'unknown'
                title = 'Synthetic PR'
                description = $Description
                descriptionDigest = & $digest $Description
                template = [ordered]@{
                    state = 'unknown'
                    reason = $State
                }
            }
        }
        return [ordered]@{
            state = 'complete'
            title = 'Synthetic PR'
            description = $Description
            descriptionDigest =
                & $digest $Description
            template = [ordered]@{
                path =
                    '/.azuredevops/pull_request_template.txt'
                configurationRef =
                    'refs/heads/master'
                configurationCommit = 'a' * 40
                blob = 'b' * 40
                contentDigest =
                    & $digest $Template
                content = $Template
            }
        }
    }

}

Describe 'Contextual convention analyzer' {
    It 'does not turn moved or rewritten existing repetitions into newly reused strings' {
        $file=New-LiteralComparisonFile -Content @'
class C {
 string First() { return "Failed"; }
 string Second() { return "Failed"; }
}
'@ -Target 'class C { string First() => "Failed"; string Second() => "Failed"; }'
        $result=@(Get-ContextualConventionOutcomes -Content $file.content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) | Where-Object ruleId -CEQ reused-string-literals)
        @($result | Where-Object state -CEQ violation) | Should -HaveCount 0
        $result[0].state | Should -BeExactly compliant
    }

    It 'keeps independent class-local and cross-project literal ownership separate' {
        $reader=New-LiteralComparisonFile -Path 'src/A/Reader.cs' -Project 'src/A/App.csproj' -Content @'
class Reader {
 string LocalA => "local";
 string LocalB => "local";
 string Shared => "contract";
}
'@
        $writer=New-LiteralComparisonFile -Path 'src/B/Writer.cs' -Project 'src/B/App.csproj' `
            -Content 'class Writer { string Shared => "contract"; }'
        $result=@(Get-ContextualConventionOutcomes -Content $reader.content -Path $reader.path `
            -Spans $reader.spans -SnapshotFiles @($reader,$writer) |
            Where-Object { $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'violation' })
        $result | Should -HaveCount 2
        $local=@($result | Where-Object { 'local' -cin $_.literalValues })[0]
        $shared=@($result | Where-Object { 'contract' -cin $_.literalValues })[0]
        $local.evidence | Should -Match 'private const string'
        $local.line | Should -Be 2
        $local.endLine | Should -Be 3
        $shared.evidence | Should -Match 'lowest common project dependency'
        $shared.line | Should -Be 4
        $shared.endLine | Should -Be 4
    }

    It 'withholds newly reused literals when the target baseline is <Mode>' -TestCases @(
        @{Mode='missing'},@{Mode='tampered'},@{Mode='wrong-source'},@{Mode='wrong-target'},
        @{Mode='wrong-path'},@{Mode='wrong-target-path'},@{Mode='wrong-length'},@{Mode='invalid-syntax'}
    ) {
        param($Mode)
        $file=New-LiteralComparisonFile -Content 'class C { string A => "wire"; string B => "wire"; }'
        switch($Mode) {
            missing { $file.Remove('comparison') }
            tampered { $file.comparison.content='class C {}' }
            wrong-source { $file.comparison.sourceCommit='c'*40 }
            wrong-target { $file.comparison.targetCommit='c'*40 }
            wrong-path { $file.comparison.path='src/Other.cs' }
            wrong-target-path { $file.comparison.targetPath='src/Other.cs' }
            wrong-length { $file.comparison.byteLength=1 }
            invalid-syntax {
                $other=New-LiteralComparisonFile -Content $file.content -Target 'class C {'
                $file.comparison=$other.comparison
            }
        }
        $result=@(Get-ContextualConventionOutcomes -Content $file.content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) | Where-Object ruleId -CEQ reused-string-literals)
        @($result | Where-Object state -CEQ violation) | Should -HaveCount 0
        $result[0].state | Should -BeExactly unknown
    }

    It 'reuses a uniquely proved existing class constant instead of declaring another' {
        $file=New-LiteralComparisonFile -Content @'
class C {
 private const string Key = "wire";
 string A => "wire";
 string B => "wire";
}
'@ -Target 'class C { private const string Key = "wire"; }'
        $result=@(Get-ContextualConventionOutcomes -Content $file.content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) |
            Where-Object { $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'violation' })
        $result | Should -HaveCount 1
        $result[0].evidence | Should -Match 'Reuse.*C.*Key'
        $result[0].evidence | Should -Not -Match 'Declare constants'
    }

    It 'does not invent an existing constant value from part of a constant expression' {
        $file=New-LiteralComparisonFile -Content 'class C { const string Key = "wi" + "re"; string A => "wi"; string B => "wi"; }'
        $result=@(Get-ContextualConventionOutcomes -Content $file.content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) |
            Where-Object { $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'violation' })
        $result | Should -HaveCount 1
        $result[0].evidence | Should -Not -Match 'Reuse C.Key'
    }

    It 'detects a genuine increase from one literal use to repeated uses' {
        $file=New-LiteralComparisonFile -Content 'class C { string A => "wire"; string B => "wire"; }' `
            -Target 'class C { string A => "wire"; }'
        $result=@(Get-ContextualConventionOutcomes -Content $file.content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) |
            Where-Object { $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'violation' })
        $result | Should -HaveCount 1
        $result[0].occurrenceCounts.source | Should -Be 2
        $result[0].occurrenceCounts.target | Should -Be 1
    }

    It 'does not assume a public field in a private nested type is accessible to a sibling' {
        $file=New-LiteralComparisonFile -Content @'
class Hidden { private class Keys { public const string Key = "wire"; } }
class C { string A => "wire"; string B => "wire"; }
'@
        $result=@(Get-ContextualConventionOutcomes -Content $file.content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) |
            Where-Object { $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'violation' })
        $result | Should -HaveCount 1
        $result[0].evidence | Should -Not -Match 'Reuse Hidden.Keys.Key'
    }

    It 'charges source and comparison content against the unchanged analyzer byte ceiling' {
        $file=New-LiteralComparisonFile -Content (' ' * (8MB + 1)) -Target (' ' * 8MB)
        {
            Get-ContextualConventionOutcomes -Content $file.content -Path $file.path `
                -Spans $file.spans -SnapshotFiles @($file)
        } | Should -Throw '*bounded limits*'
    }

    It 'does not add another declaration when several existing constants are accessible' {
        $file=New-LiteralComparisonFile -Content 'class C { const string A = "wire"; const string B = "wire"; string X => "wire"; string Y => "wire"; }'
        $result=@(Get-ContextualConventionOutcomes -Content $file.content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) |
            Where-Object { $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'violation' })
        $result | Should -HaveCount 1
        $result[0].evidence | Should -Match '^Reuse an existing accessible constant'
        $result[0].evidence | Should -Not -Match 'Declare constants'
    }

    It 'exports the fixed twenty-three-rule allow set' {
        @(Get-ContextualConventionRuleIds) |
            Should -HaveCount 23
        $policy = Get-Content "$PSScriptRoot\..\src\DevPilot.OwnerCapability\Policy\contextual-conventions.v1.json" -Raw |
            ConvertFrom-Json -AsHashtable
        @($policy.rules.id | Sort-Object) |
            Should -Be @(Get-ContextualConventionRuleIds | Sort-Object)
    }

    It 'detects a high-confidence <Rule> violation' -TestCases $script:Cases {
        param($Rule, $Violation, $Exemption)
        $result = Invoke-ConventionCase `
            -RuleId $Rule -Content $Violation
        $result.state | Should -BeExactly 'violation'
        $result.line | Should -BeGreaterThan 0
        $result.evidence | Should -Not -BeNullOrEmpty
    }

    It 'declares reused string constants within one class without comparing constant declarations' {
        $content = @'
class C {
    string First() => "wire";
    string Second() => "wire";
}
'@
        $result = Invoke-ConventionCase -RuleId reused-string-literals -Content $content
        $result.state | Should -BeExactly violation
        $result.line | Should -Be 2
        $result.endLine | Should -Be 3
        $result.evidence | Should -Match 'private const string atop the class'
        $result.literalValues | Should -Be @('wire')
        $result.relatedUses | Should -HaveCount 2
        (Invoke-ConventionCase -RuleId duplicate-constant-declarations -Content $content).state |
            Should -BeExactly compliant
    }

    It 'uses decoded identity for <Literal> rather than raw spelling' -TestCases @(
        @{ Literal = '"wire"' }
        @{ Literal = '"\u0077ire"' }
        @{ Literal = '@"wire"' }
        @{ Literal = '"""wire"""' }
    ) {
        param($Literal)
        $content = 'class C { string First() => "wire"; string Second() => ' + $Literal + '; }'
        $files = @(@{
            path='src/Changed.cs';state='complete';content=$content
            projectContext=@{state='complete';path='src/App.csproj';content='<Project><PropertyGroup><LangVersion>latest</LangVersion></PropertyGroup></Project>'}
        })
        $result = Invoke-ConventionCase -RuleId reused-string-literals -Content $content -SnapshotFiles $files
        $result.state | Should -BeExactly violation
        $result.literalValues | Should -Be @('wire')
        $result.relatedUses | Should -HaveCount 2
    }

    It 'selects project constants across types including types in the same file' {
        $result = Invoke-ConventionCase -RuleId reused-string-literals -Content @'
namespace N {
class First { string Value => "shared"; }
class Second { string Value => "shared"; }
}
'@
        $result.state | Should -BeExactly violation
        $result.evidence | Should -Match 'common Constants class for the project'
        $result.line | Should -Be 2
        $result.relatedUses | Should -HaveCount 2
    }

    It 'keeps canonically equivalent Unicode strings ordinally distinct' {
        $content='class C { string A => "\u00e9"; string B => "\u00e9"; string Cc => "e\u0301"; string D => "e\u0301"; }'
        $file=New-LiteralComparisonFile -Content $content
        $result=@(Get-ContextualConventionOutcomes -Content $content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) |
            Where-Object { $_.ruleId -ceq 'reused-string-literals' -and $_.state -ceq 'violation' })
        $result | Should -HaveCount 2
        @($result | ForEach-Object {$_.literalValues}) | Should -HaveCount 2
        @($result | ForEach-Object {$_.relatedUses}) | Should -HaveCount 4
    }

    It 'keeps case-distinct C# types in separate ownership scopes' {
        $result=Invoke-ConventionCase -RuleId reused-string-literals `
            -Content 'class C { string A => "wire"; } class c { string B => "wire"; }'
        $result.state | Should -BeExactly violation
        $result.evidence | Should -Match 'common Constants class for the project'
    }

    It 'does not treat <Case> as reused changed literal strings' -TestCases @(
        @{ Case = 'unique values'; Content = 'class C { string A => "one"; string B => "two"; }'; Path = 'src/C.cs' }
        @{ Case = 'case-different values'; Content = 'class C { string A => "wire"; string B => "WIRE"; }'; Path = 'src/C.cs' }
        @{ Case = 'constant member uses'; Content = 'class C { private const string Key = "wire"; string A => Key; string B => C.Key; }'; Path = 'src/C.cs' }
        @{ Case = 'duplicate constant declarations'; Content = 'class C { const string A = "wire"; const string B = "wire"; }'; Path = 'src/C.cs' }
        @{ Case = 'comments and attributes'; Content = '[Description("wire")] class C { /* "wire" */ string A => "wire"; }'; Path = 'src/C.cs' }
        @{ Case = 'localized resources'; Content = 'class C { string A => Resources.Message.ToLocalizedMessage(); string B => Resources.Message.ToLocalizedMessage(); }'; Path = 'src/C.cs' }
        @{ Case = 'generated files'; Content = 'class C { string A => "wire"; string B => "wire"; }'; Path = 'src/C.g.cs' }
        @{ Case = 'generated headers'; Content = "// <auto-generated>`nclass C { string A => `"wire`"; string B => `"wire`"; }"; Path = 'src/C.cs' }
    ) {
        param($Case, $Content, $Path)
        (Invoke-ConventionCase -RuleId reused-string-literals -Content $Content -Path $Path).state |
            Should -BeExactly compliant
    }

    It 'keeps old repetitions outside the changed use anchor' {
        $content = @'
class C {
    string A => "old";
    string B => "old";
    string Added => "new";
}
'@
        $file = [ordered]@{
            path = 'src/C.cs'; content = $content; state = 'complete'
            spans = @(@{ startLine = 4; endLine = 4 })
            projectContext = @{ state = 'complete'; path = 'src/App.csproj'; content = '<Project />' }
        }
        $result = @(Get-ContextualConventionOutcomes -Content $content -Path $file.path `
            -Spans $file.spans -SnapshotFiles @($file) |
            Where-Object ruleId -CEQ reused-string-literals)
        $result | Should -HaveCount 1
        $result[0].state | Should -BeExactly compliant
    }

    It 'excludes only proved test project repetitions and withholds <Proof>' -TestCases @(
        @{ Proof = 'test'; Project = @{state='complete';path='src/App.csproj';content='<Project><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>'}; Expected = 'compliant' }
        @{ Proof = 'explicit non-test'; Project = @{state='complete';path='src/App.csproj';content='<Project><PropertyGroup><IsTestProject>false</IsTestProject></PropertyGroup></Project>'}; Expected = 'violation' }
        @{ Proof = 'missing project'; Project = @{state='unknown';reason='missing'}; Expected = 'unknown' }
        @{ Proof = 'malformed project'; Project = @{state='complete';path='src/App.csproj';content='<Project>'}; Expected = 'unknown' }
        @{ Proof = 'conditional project'; Project = @{state='complete';path='src/App.csproj';content='<Project><PropertyGroup><LangVersion Condition="unproved">latest</LangVersion></PropertyGroup></Project>'}; Expected = 'unknown' }
        @{ Proof = 'stale project'; Project = @{state='complete';path='src/App.csproj';content='<Project />';sourceDigest=('v1:sha256:' + ('0' * 64))}; Expected = 'unknown' }
        @{ Proof = 'foreign project'; Project = @{state='complete';path='other/App.csproj';content='<Project />'}; Expected = 'unknown' }
        @{ Proof = 'conditional test membership'; Project = @{state='complete';path='src/App.csproj';content='<Project><PropertyGroup Condition="unproved"><IsTestProject>true</IsTestProject></PropertyGroup></Project>'}; Expected = 'unknown' }
    ) {
        param($Proof, $Project, $Expected)
        $content = 'class C { string A => "wire"; string B => "wire"; }'
        $files = @(@{ path = 'src/C.cs'; state = 'complete'; content = $content; projectContext = $Project })
        (Invoke-ConventionCase -RuleId reused-string-literals -Content $content -Path 'src/C.cs' -SnapshotFiles $files).state |
            Should -BeExactly $Expected
    }

    It 'withholds conditional and incomplete peer evidence instead of claiming a clean result' {
        foreach ($content in @(
                "#if FEATURE`nclass C { string A => `"wire`"; string B => `"wire`"; }`n#endif",
                'class C { string A => "wire"; }')) {
            $files = @(
                @{path='src/C.cs';state='complete';content=$content;projectContext=@{state='complete';path='src/App.csproj';content='<Project />'}},
                @{path='src/Peer.cs';state='unknown';content=''}
            )
            (Invoke-ConventionCase -RuleId reused-string-literals -Content $content -Path 'src/C.cs' -SnapshotFiles $files).state |
                Should -BeExactly unknown
        }

    }

    It 'withholds raw literal equality under a project language version that cannot compile it' {
        (Invoke-ConventionCase -RuleId reused-string-literals `
            -Content 'class C { string A => "wire"; string B => """wire"""; }').state |
            Should -BeExactly unknown
    }

    It 'honors the documented <Rule> exemption' -TestCases $script:Cases {
        param($Rule, $Violation, $Exemption)
        $result = Invoke-ConventionCase `
            -RuleId $Rule -Content $Exemption
        $result.state | Should -Not -BeExactly 'violation'
    }

    It 'reports dependency graph absence as unknown, not a violation' {
        $content = @'
<Project>
  <ItemGroup>
    <PackageReference Include="Contoso.Client" Version="2.0.0" />
  </ItemGroup>
</Project>
'@
        $result = Invoke-ConventionCase `
            -RuleId dependency-fanout `
            -Content $content -Path 'src/App/App.csproj' `
            -SnapshotFiles @([ordered]@{
                    path = 'src/App/App.csproj'
                    content = $content
                    state = 'complete'
                    spans = @([ordered]@{
                            startLine = 1
                            endLine = 5
                        })
                })
        $result.state | Should -BeExactly 'unknown'
    }

    It 'detects a proven dependency version mismatch across changed surfaces' {
        $project = '<PackageReference Include="Contoso.Client" Version="2.0.0" />'
        $lock = '<package id="Contoso.Client" version="1.0.0" />'
        $files = @(
            [ordered]@{
                path = 'src/App/App.csproj'
                content = $project
                state = 'complete'
                spans = @([ordered]@{
                        startLine = 1
                        endLine = 1
                    })
            },
            [ordered]@{
                path = 'src/App/packages.config'
                content = $lock
                state = 'complete'
                spans = @([ordered]@{
                        startLine = 1
                        endLine = 1
                    })
            })
        $result = Invoke-ConventionCase `
            -RuleId dependency-fanout `
            -Content $project -Path 'src/App/App.csproj' `
            -SnapshotFiles $files
        $result.state | Should -BeExactly 'violation'
    }

    It 'withholds all unproven rules when changed C# syntax is incomplete' {
        $outcomes = Get-ContextualConventionOutcomes `
            -Content 'class C { void M(' `
            -Path 'src/Broken.cs' `
            -Spans @([ordered]@{
                    startLine = 1
                    endLine = 1
                }) `
            -SnapshotFiles @([ordered]@{
                    path = 'src/Broken.cs'
                    content = 'class C { void M('
                    state = 'complete'
                    spans = @([ordered]@{
                            startLine = 1
                            endLine = 1
                        })
                })
        @($outcomes | Where-Object state -CEQ violation) |
            Should -HaveCount 0
        @($outcomes | Where-Object state -CEQ unknown).Count |
            Should -BeGreaterThan 0
    }

    It 'does not flag a short synchronous lock inside an async method' {
        $content = 'class C { async Task M() { lock (gate) { value++; } await SaveAsync(); } }'
        (Invoke-ConventionCase `
            -RuleId async-wait-sync `
            -Content $content).state |
            Should -Not -BeExactly violation
    }

    It 'does not assume a custom HttpClient type is System.Net.Http.HttpClient' {
        $content = 'namespace Custom { class HttpClient {} class C { void M() { var client = new HttpClient(); } } }'
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $content).state |
            Should -BeExactly unknown
    }

    It 'enforces all three named-call triggers with one rule' {
        $cases = @(
            @{
                reason = 'repeated formal types'
                expectedReason =
                    'documented-trigger-positional-arguments'
                source = 'class C { void Target(string left, string right, System.Uri endpoint) {} void M(string a, string b, System.Uri u) { Target(a, b, u); } }'
            },
            @{
                reason = 'one argument per line'
                expectedReason =
                    'documented-trigger-positional-arguments'
                source = @'
class C {
    void Target(int first, string second, bool third) {}
    void M(int a, string b, bool c) {
        Target(
            a,
            b,
            c);
    }
}
'@
            },
            @{
                reason = 'literal constant'
                expectedReason =
                    'documented-constant-argument-positional'
                source = 'class C { void Target(int count) {} void M() { Target(0); } }'
            },
            @{
                reason = 'declared compile-time constant'
                expectedReason =
                    'documented-constant-argument-positional'
                source = 'class C { const int Count = 1; void Target(int count) {} void M() { Target(Count); } }'
            })
        foreach ($case in $cases) {
            $outcome = Invoke-ConventionCase `
                -RuleId named-call-arguments `
                -Content $case.source
            $outcome.state |
                Should -BeExactly violation `
                -Because $case.reason
            $outcome.reason |
                Should -BeExactly `
                    $case.expectedReason
        }
    }

    It 'limits a constant-only trigger to proven constant arguments' {
        $compliant = @(
            'class C { void Target(string text, int count, object state) {} void M(string text, int count) { Target(text, count, state: null); } }',
            'class C { const int DefaultCount = 1; void Target(string text, int count) {} void M(string text) { Target(text, count: DefaultCount); } }')
        foreach ($content in $compliant) {
            $outcome =
                Invoke-ConventionCase `
                    -RuleId named-call-arguments `
                    -Content $content
            $outcome.state |
                Should -BeExactly compliant
            $outcome.reason |
                Should -BeExactly `
                    documented-constant-arguments-named
        }

        $violation =
            Invoke-ConventionCase `
                -RuleId named-call-arguments `
                -Content (
                    'class C { void Target(int count, object first, System.Uri second) {} void M(int count) { Target(count, null, second: null); } }')
        $violation.state |
            Should -BeExactly violation
        $violation.reason |
            Should -BeExactly `
                documented-constant-argument-positional
        $violation.evidence |
            Should -BeExactly (
                'Name each compile-time constant argument; ' +
                'other distinct nonconstant arguments do not ' +
                'need names.')
    }

    It 'accepts all-named calls for every documented trigger' {
        $controls = @(
            'class C { void Target(string left, string right) {} void M() { Target(left: "a", right: "b"); } }',
            @'
class C {
    void Target(int first, string second) {}
    void M(int a, string b) {
        Target(
            first: a,
            second: b);
    }
}
'@,
            'class C { void Target(int count) {} void M() { Target(count: 0); } }')
        foreach ($content in $controls) {
            $outcome = Invoke-ConventionCase `
                -RuleId named-call-arguments `
                -Content $content
            $outcome.state |
                Should -Not -BeExactly violation
        }
    }

    It 'does not duplicate the Assert AreEqual named-argument rule' {
        $content = @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
class C {
    void M() {
        Assert.AreEqual(0, 1);
    }
}
'@
        (Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $content).state |
            Should -BeExactly compliant
    }

    It 'does not infer constants from capitalized identifiers' {
        $content = 'class C { void Target(int count) {} void M(int Count) { Target(Count); } }'
        (Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $content).state |
            Should -BeExactly compliant
    }

    It 'requires syntactic proof for declared constants' {
        $content = 'class C { const int Count = Get(); static int Get() => 1; void Target(int count) {} void M() { Target(Count); } }'
        (Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $content).state |
            Should -BeExactly compliant
    }

    It 'does not treat a newline inside one expression as argument-per-line formatting' {
        $content = @'
class C {
    void Target(int first, int second) {}
    int Get(
        int value) => value;
    void M(int a, int b) {
        Target(Get(
            a), b);
    }
}
'@
        $outcome = Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $content
        $outcome.reason |
            Should -Not -BeExactly one-argument-per-line
    }

    It 'supports object construction and this/base constructor initializers with proven signatures' {
        $object = 'class Item { Item(string left, string right) {} } class C { void M() { var value = new Item("a", "b"); } }'
        $thisInitializer = @'
class C {
    C(int first, string second) : this(
        first,
        second,
        true) {}
    C(int first, string second, bool third) {}
}
'@
        $baseInitializer = @'
class B { public B(string left, string right) {} }
class C : B { C() : base("a", "b") {} }
'@
        foreach ($content in @(
                $object,
                $thisInitializer,
                $baseInitializer)) {
            (Invoke-ConventionCase `
                -RuleId named-call-arguments `
                -Content $content).state |
                Should -BeExactly violation
        }
    }

    It 'withholds ambiguous dynamic params expression-tree and unknown-language calls' {
        $controls = @(
            @{
                reason = 'selected-overload-ambiguous'
                source = 'class C { void Target(int value) {} void Target(string value) {} void M() { Target(0); } }'
                files = @()
            },
            @{
                reason = 'dynamic-argument-binding-unproven'
                source = 'class C { void Target(int first, int second) {} void M(dynamic value) { Target(value, 0); } }'
                files = @()
            },
            @{
                reason = 'expanded-params-binding-unproven'
                source = 'class C { void Target(params int[] values) {} void M() { Target(0); } }'
                files = @()
            },
            @{
                reason = 'expression-tree-named-arguments-unproven'
                source = 'class C { void Target(int value) {} void Setup(System.Action f) {} void M() { Setup(() => Target(0)); } }'
                files = @()
            },
            @{
                reason = 'project-language-version-unknown'
                source = 'class C { void Target(int value) {} void M() { Target(0); } }'
                files = @([ordered]@{
                        path = 'src/Changed.cs'
                        state = 'complete'
                        content = 'class C { void Target(int value) {} void M() { Target(0); } }'
                        spans = @([ordered]@{
                                startLine = 1
                                endLine = 1
                            })
                    })
            },
            @{
                reason = 'call-receiver-type-unproven'
                source = 'class Service { void Target(int value) {} } class C { void M(Service service) { service.Target(0); } }'
                files = @()
            },
            @{
                reason = 'argument-modifier-binding-unproven'
                source = 'class C { void Target(ref int first, ref int second) {} void M(int a, int b) { Target(a, b); } }'
                files = @()
            })
        foreach ($case in $controls) {
            $outcome = if ($case.files.Count) {
                Invoke-ConventionCase `
                    -RuleId named-call-arguments `
                    -Content $case.source `
                    -SnapshotFiles $case.files
            }
            else {
                Invoke-ConventionCase `
                    -RuleId named-call-arguments `
                    -Content $case.source
            }
            $outcome.state |
                Should -BeExactly unknown `
                -Because $case.reason
            $outcome.reason |
                Should -BeExactly $case.reason
        }
    }

    It 'resolves the pinned BCL string Equals signature without overlapping comparison semantics' {
        $content = 'class C { bool M(string a, string b) { return string.Equals(a, b, System.StringComparison.Ordinal); } }'
        $outcome = Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $content
        $outcome.state | Should -BeExactly violation
        $outcome.symbol | Should -BeExactly Equals
    }

    It 'preserves ref out and in argument binding' {
        $content = 'class C { void Target(ref int first, ref int second) {} void M(int a, int b) { Target(ref a, ref b); } }'
        $outcome = Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $content
        $outcome.state | Should -BeExactly violation
        $outcome.reason |
            Should -BeExactly documented-trigger-positional-arguments
    }

    It 'flags the actual compact XML summary layout at its changed summary line' {
        $content = @'
class C
{
    /// <summary>Gets or sets reviewed provider rules to install with storage rules.</summary>
    public string ProviderEgressRules { get; set; }
}
'@
        $outcome = @(
            Get-ContextualConventionOutcomes `
                -Content $content `
                -Path 'src/Request.cs' `
                -Spans @([ordered]@{
                        startLine = 3
                        endLine = 4
                    }) `
                -SnapshotFiles @([ordered]@{
                        path = 'src/Request.cs'
                        content = $content
                        state = 'complete'
                        spans = @([ordered]@{
                                startLine = 3
                                endLine = 4
                            })
                    }) |
                Where-Object {
                    [string]$_.ruleId -ceq
                        'xml-summary-layout'
                })[0]
        $outcome.state | Should -BeExactly violation
        $outcome.line | Should -Be 3
        $outcome.symbol |
            Should -BeExactly ProviderEgressRules
    }

    It 'accepts standalone summary tags and preserves inline body markup' {
        $content = @'
class C
{
    /// <summary>
    /// Gets a <see cref="System.String"/> for <paramref name="value"/>.
    /// </summary>
    /// <param name="value">The value.</param>
    public string M(string value) => value;
}
'@
        (Invoke-ConventionCase `
            -RuleId xml-summary-layout `
            -Content $content).state |
            Should -BeExactly compliant
    }

    It 'requires matching documentation indentation and nonempty summary bodies' {
        $cases = @(
            @'
class C
{
    /// <summary>
        /// Mismatched body indentation.
  /// </summary>
    public int Value { get; set; }
}
'@,
            @'
class C
{
    /// <summary>
    ///
    /// </summary>
    public int Value { get; set; }
}
'@,
            @'
class C
{
    /// <summary/>
    public int Value { get; set; }
}
'@)
        foreach ($content in $cases) {
            (Invoke-ConventionCase `
                -RuleId xml-summary-layout `
                -Content $content).state |
                Should -BeExactly violation
        }
    }

    It 'reports field event-field and indexer declaration symbols' {
        $cases = @(
            [ordered]@{
                symbol = 'value'
                content = @'
class C
{
    /// <summary>Compact field.</summary>
    private readonly int value;
}
'@
            },
            [ordered]@{
                symbol = 'Changed'
                content = @'
using System;
class C
{
    /// <summary>Compact event.</summary>
    public event EventHandler Changed;
}
'@
            },
            [ordered]@{
                symbol = 'this'
                content = @'
class C
{
    /// <summary>Compact indexer.</summary>
    public int this[int index] => index;
}
'@
            })
        foreach ($case in $cases) {
            $outcome = Invoke-ConventionCase `
                -RuleId xml-summary-layout `
                -Content $case.content
            $outcome.state | Should -BeExactly violation
            $outcome.symbol |
                Should -BeExactly $case.symbol
        }
    }

    It 'does not flag one-line param docs strings ordinary comments or missing docs' {
        $content = @'
class C
{
    // <summary>Ordinary comment.</summary>
    private const string Example = "/// <summary>string</summary>";
    public string Value { get; set; }
}
'@
        (Invoke-ConventionCase `
            -RuleId xml-summary-layout `
            -Content $content).state |
            Should -BeExactly compliant
    }

    It 'excludes generated files and auto-generated sources' {
        $content = @'
// <auto-generated>
class C
{
    /// <summary>Generated compact summary.</summary>
    public string Value { get; set; }
}
'@
        foreach ($path in @(
                'src/Generated.g.cs',
                'src/Generated.cs')) {
            (Invoke-ConventionCase `
                -RuleId xml-summary-layout `
                -Content $content -Path $path).state |
                Should -BeExactly compliant
        }
    }

    It 'does not report an unchanged compact summary when only the declaration changed' {
        $content = @'
class C
{
    /// <summary>Existing compact summary.</summary>
    public string Value { get; set; }
}
'@
        $outcome = @(
            Get-ContextualConventionOutcomes `
                -Content $content `
                -Path 'src/Changed.cs' `
                -Spans @([ordered]@{
                        startLine = 4
                        endLine = 4
                    }) `
                -SnapshotFiles @([ordered]@{
                        path = 'src/Changed.cs'
                        content = $content
                        state = 'complete'
                        spans = @([ordered]@{
                                startLine = 4
                                endLine = 4
                            })
                    }) |
                Where-Object {
                    [string]$_.ruleId -ceq
                        'xml-summary-layout'
                })[0]
        $outcome.state | Should -BeExactly compliant
    }

    It 'detects a proven duplicate constant cluster for one shared contract' {
        $candidate = @'
namespace N {
/// <summary>Wire contract <c>adc.egress.hook/v1</c>.</summary>
internal static class Candidate {
internal const string ApiVersionHeaderName = "x-adc-api-version";
internal const string SupportedApiVersion = "adc.egress.hook/v1";
internal const string SupportedProtocol = "http";
internal const string SupportedScheme = "https";
internal const string AuthorizationHeaderName = "Authorization";
internal const string DenyReason = "candidate reason";
} }
'@
        $comparison = @'
namespace N {
/// <summary>Shared <c>adc.egress.hook/v1</c> wire contract.</summary>
internal static class Existing {
internal const string ApiVersionHeaderName = "x-adc-api-version";
internal const string SupportedApiVersion = "adc.egress.hook/v1";
internal const string SupportedProtocol = "http";
internal const string SupportedScheme = "https";
internal const string AuthorizationHeaderName = "Authorization";
internal const string DenyReason = "existing reason";
} }
'@
        $project = [ordered]@{
            state = 'complete'
            path = 'src/App.csproj'
            sourceDigest =
                'v1:sha256:' + ('1' * 64)
            content = '<Project />'
        }
        $files = @(
            [ordered]@{
                path = 'src/Candidate.cs'
                content = $candidate
                state = 'complete'
                projectContext = $project
                spans = @([ordered]@{
                        startLine = 4
                        endLine = 9
                    })
            },
            [ordered]@{
                path = 'src/Existing.cs'
                content = $comparison
                state = 'complete'
                projectContext = $project
                spans = @()
            })
        $outcome = Invoke-ConventionCase `
            -RuleId duplicate-constant-declarations `
            -Content $candidate `
            -Path 'src/Candidate.cs' `
            -SnapshotFiles $files

        $outcome.state | Should -BeExactly violation
        $outcome.reason |
            Should -BeExactly duplicate-shared-contract-constants
        $outcome.line | Should -Be 4
        $outcome.endLine | Should -Be 8
        $outcome.evidence |
            Should -Match 'ApiVersionHeaderName'
        $outcome.evidence |
            Should -Not -Match 'DenyReason'
    }

    It 'withholds or excludes unproved duplicate constant relations' {
        $baseCandidate = @'
namespace N {
/// <summary>Wire contract <c>contract/a</c>.</summary>
internal static class Candidate {
internal const string Value = "same";
} }
'@
        $sameProject = [ordered]@{
            state = 'complete'
            path = 'src/App.csproj'
            sourceDigest =
                'v1:sha256:' + ('2' * 64)
            content = '<Project />'
        }
        $cases = @(
            [ordered]@{
                reason =
                    'duplicate-constant-relation-unproven'
                comparison = @'
namespace N {
/// <summary>Different <c>contract/b</c>.</summary>
internal static class Existing {
internal const string Value = "same";
} }
'@
                candidateProject = $sameProject
                comparisonProject = $sameProject
            },
            [ordered]@{
                reason =
                    'duplicate-constant-relation-unproven'
                comparison = @'
namespace Other {
/// <summary>Wire contract <c>contract/a</c>.</summary>
internal static class Existing {
internal const string Value = "same";
} }
'@
                candidateProject = $sameProject
                comparisonProject = $sameProject
            },
            [ordered]@{
                reason =
                    'duplicate-constant-relation-unproven'
                comparison = @'
namespace N {
/// <summary>Wire contract <c>contract/a</c>.</summary>
internal static class Existing {
internal const string Value = "same";
} }
'@
                candidateProject = [ordered]@{
                    state = 'complete'
                    path = 'src/App.csproj'
                    content =
                        '<Project><PropertyGroup Condition="x"><LangVersion>7.2</LangVersion></PropertyGroup></Project>'
                }
                comparisonProject = $sameProject
            })
        foreach ($case in $cases) {
            $files = @(
                [ordered]@{
                    path = 'src/Candidate.cs'
                    content = $baseCandidate
                    state = 'complete'
                    projectContext =
                        $case.candidateProject
                    spans = @([ordered]@{
                            startLine = 4
                            endLine = 4
                        })
                },
                [ordered]@{
                    path = 'src/Existing.cs'
                    content = $case.comparison
                    state = 'complete'
                    projectContext =
                        $case.comparisonProject
                    spans = @()
                })
            $outcome = Invoke-ConventionCase `
                -RuleId duplicate-constant-declarations `
                -Content $baseCandidate `
                -Path 'src/Candidate.cs' `
                -SnapshotFiles $files
            $outcome.state | Should -BeExactly unknown
            $outcome.reason |
                Should -BeExactly $case.reason
        }
    }

    It 'does not flag different values private enum test generated or unchanged constants' {
        $project = [ordered]@{
            state = 'complete'
            path = 'src/App.csproj'
            content = '<Project />'
        }
        $testProject = [ordered]@{
            state = 'complete'
            path = 'tests/Tests.csproj'
            content =
                '<Project><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>'
        }
        $controls = @(
            [ordered]@{
                candidate = 'namespace N { /// <summary><c>x</c></summary> internal static class A { internal const string Value = "one"; } }'
                comparison = 'namespace N { /// <summary><c>x</c></summary> internal static class B { internal const string Value = "two"; } }'
                project = $project
                comparisonPath = 'src/B.cs'
                changed = $true
            },
            [ordered]@{
                candidate = 'namespace N { /// <summary><c>x</c></summary> internal static class A { private const string Value = "same"; } }'
                comparison = 'namespace N { /// <summary><c>x</c></summary> internal static class B { internal const string Value = "same"; } }'
                project = $project
                comparisonPath = 'src/B.cs'
                changed = $true
            },
            [ordered]@{
                candidate = 'namespace N { internal enum A { Value } }'
                comparison = 'namespace N { internal enum B { Value } }'
                project = $project
                comparisonPath = 'src/B.cs'
                changed = $true
            },
            [ordered]@{
                candidate = 'namespace N { /// <summary><c>x</c></summary> internal static class A { internal const string Value = "same"; } }'
                comparison = 'namespace N { /// <summary><c>x</c></summary> internal static class B { internal const string Value = "same"; } }'
                project = $testProject
                comparisonPath = 'tests/B.cs'
                changed = $true
            },
            [ordered]@{
                candidate = 'namespace N { /// <summary><c>x</c></summary> internal static class A { internal const string Value = "same"; } }'
                comparison = 'namespace N { /// <summary><c>x</c></summary> internal static class B { internal const string Value = "same"; } }'
                project = $project
                comparisonPath = 'src/Generated.g.cs'
                changed = $true
            },
            [ordered]@{
                candidate = 'namespace N { /// <summary><c>x</c></summary> internal static class A { internal const string Value = "same"; } }'
                comparison = 'namespace N { /// <summary><c>x</c></summary> internal static class B { internal const string Value = "same"; } }'
                project = $project
                comparisonPath = 'src/B.cs'
                changed = $false
            })
        foreach ($control in $controls) {
            $candidateLines = [Math]::Max(
                1,
                ($control.candidate -split "`r?`n").Count)
            $spans = if ($control.changed) {
                @([ordered]@{
                        startLine = 1
                        endLine = $candidateLines
                    })
            }
            else {
                @([ordered]@{
                        startLine = $candidateLines + 1
                        endLine = $candidateLines + 1
                    })
            }
            $files = @(
                [ordered]@{
                    path = 'src/A.cs'
                    content = $control.candidate
                    state = 'complete'
                    projectContext = $control.project
                    spans = $spans
                },
                [ordered]@{
                    path = $control.comparisonPath
                    content = $control.comparison
                    state = 'complete'
                    projectContext = $control.project
                    spans = @()
                })
            $outcome = @(
                Get-ContextualConventionOutcomes `
                    -Content $control.candidate `
                    -Path 'src/A.cs' `
                    -Spans $spans `
                    -SnapshotFiles $files |
                    Where-Object {
                        [string]$_.ruleId -ceq
                            'duplicate-constant-declarations'
                    })[0]
            $outcome.state |
                Should -Not -BeExactly violation
        }
    }

    It 'does not crash on omitted object-creation parentheses or unproven base lists' {
        $objectInitializer =
            'class C { int P { get; set; } void M() { var x = new C { P = 1 }; } }'
        $partialBase =
            'partial class C { C() : base(0) {} }'
        foreach ($content in @(
                $objectInitializer,
                $partialBase)) {
            $outcomes = @(
                Get-ContextualConventionOutcomes `
                    -Content $content `
                    -Path 'src/Changed.cs' `
                    -Spans @([ordered]@{
                            startLine = 1
                            endLine = 1
                        }) `
                    -SnapshotFiles @([ordered]@{
                            path = 'src/Changed.cs'
                            content = $content
                            state = 'complete'
                            projectContext = [ordered]@{
                                state = 'complete'
                                content = '<Project><PropertyGroup><LangVersion>7.2</LangVersion></PropertyGroup></Project>'
                            }
                            spans = @([ordered]@{
                                    startLine = 1
                                    endLine = 1
                                })
                        }))
            $outcomes | Should -HaveCount 23
            @($outcomes | Where-Object {
                    [string]$_.ruleId -cne
                        'named-call-arguments'
                }) | Should -HaveCount 22
        }
    }

    It 'withholds unproven receiver and container bindings' {
        $controls = @(
            'class Unrelated { void Target(string a, string b) {} } class C : Base, System.IDisposable { void M(string x, string y) { base.Target(x, y); } }',
            'class Service { void Target(int x) {} } class C { IOther Service { get; } void M() { this.Service.Target(0); } }',
            'class Service { static void Target(int x) {} } class C { void M(IOther Service) { Service.Target(0); } }',
            'class Service { void Target(int x) {} } class C { void M() { Service.Target(0); } }')
        foreach ($content in $controls) {
            $outcome = Invoke-ConventionCase `
                -RuleId named-call-arguments `
                -Content $content
            $outcome.state | Should -BeExactly unknown
            $outcome.reason |
                Should -BeExactly call-receiver-type-unproven
        }
    }

    It 'matches optional arity and withholds competing overloads and params' {
        $optional = 'class C { void Target(string a, string b, int timeout = 0) {} void M(string x, string y) { Target(x, y); } }'
        (Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $optional).state |
            Should -BeExactly violation

        $ambiguous = @(
            'class C { void Target(string a, string b) {} void Target(int a, int b) {} void M(string x, string y) { Target(x, y); } }',
            'class C { void Target(string a, string b) {} void Target(int a, string b, bool f = false) {} void M(int x, string y) { Target(x, y); } }')
        foreach ($content in $ambiguous) {
            $outcome = Invoke-ConventionCase `
                -RuleId named-call-arguments `
                -Content $content
            $outcome.state | Should -BeExactly unknown
            $outcome.reason |
                Should -BeExactly selected-overload-ambiguous
        }

        $params = 'class C { void Target(params string[] values) {} void M(string x, string y) { Target(x, y); } }'
        $paramsOutcome = Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $params
        $paramsOutcome.state | Should -BeExactly unknown
        $paramsOutcome.reason |
            Should -BeExactly expanded-params-binding-unproven
    }

    It 'normalizes proven BCL type names and withholds generic instantiations' {
        $sameType = 'using System; class C { void Target(String a, string b) {} void M(string x, string y) { Target(x, y); } }'
        (Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $sameType).state |
            Should -BeExactly violation

        foreach ($receiver in @(
                'String.Equals',
                'System.String.Equals',
                'global::System.String.Equals')) {
            $content =
                "using System; class C { bool M(string a, string b) { return $receiver(a, b, StringComparison.Ordinal); } }"
            (Invoke-ConventionCase `
                -RuleId named-call-arguments `
                -Content $content).state |
                Should -BeExactly violation
        }

        $generic = 'class C { void Target<T1, T2>(T1 a, T2 b) {} void M(string x, string y) { Target(x, y); } }'
        $genericOutcome = Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $generic
        $genericOutcome.state | Should -BeExactly unknown
        $genericOutcome.reason |
            Should -BeExactly generic-type-parameter-binding-unproven
    }

    It 'scopes constants and recognizes unary and parenthesized constants' {
        $shadowed =
            'class C { void Target(int x) {} void A() { const int value = 1; } void B(int value) { Target(value); } }'
        (Invoke-ConventionCase `
            -RuleId named-call-arguments `
            -Content $shadowed).state |
            Should -BeExactly compliant

        foreach ($expression in @(
                '-1',
                '(0)',
                '~0',
                '!false',
                '1 + 2')) {
            $content =
                "class C { void Target(int x) {} void M() { Target($expression); } }"
            (Invoke-ConventionCase `
                -RuleId named-call-arguments `
                -Content $content).state |
                Should -BeExactly violation
        }
    }

    It 'flags default HttpClient construction with a namespace-scoped using' {
        $content = @(
            'namespace Fixture'
            '{'
            '    using System.Net.Http;'
            '    class C'
            '    {'
            '        void M()'
            '        {'
            '            using (var client = new HttpClient())'
            '            {'
            '            }'
            '        }'
            '    }'
            '}'
        ) -join "`n"
        $outcome = Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $content
        $outcome.state | Should -BeExactly violation
        $outcome.reason |
            Should -BeExactly request-path-http-client-construction
        $outcome.line | Should -Be 8
        $outcome.symbol | Should -BeExactly M
    }

    It 'selects the first default construction after custom-handler test clients' {
        $content = @(
            'namespace Fixture'
            '{'
            '    using System.Net.Http;'
            '    class C'
            '    {'
            '        void M(HttpMessageHandler handler)'
            '        {'
            '            using (var configured = new HttpClient(handler))'
            '            {'
            '            }'
            '            using (var backendClient = new HttpClient())'
            '            {'
            '            }'
            '            using (var gatewayClient = new HttpClient())'
            '            {'
            '            }'
            '        }'
            '    }'
            '}'
        ) -join "`n"
        $outcome = Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $content
        $outcome.state | Should -BeExactly violation
        $outcome.line | Should -Be 11
        $outcome.symbol | Should -BeExactly M
    }

    It 'withholds custom-handler lifetime without exempting default construction' {
        $content = 'using System.Net.Http; class C { void M(HttpMessageHandler handler) { using var client = new HttpClient(handler); } }'
        $outcome = Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $content
        $outcome.state | Should -BeExactly unknown
        $outcome.reason |
            Should -BeExactly custom-handler-lifetime-unproven
    }

    It 'accepts static readonly and static-constructor singletons' {
        $controls = @(
            'using System.Net.Http; class C { private static readonly HttpClient Client = new HttpClient(); }',
            'using System.Net.Http; class C { private static readonly HttpClient Client; static C() { C.Client = new HttpClient(); } }'
        )
        foreach ($content in $controls) {
            (Invoke-ConventionCase `
                -RuleId http-client-lifetime `
                -Content $content).state |
                Should -Not -BeExactly violation
        }
    }

    It 'flags instance-owned default HttpClient construction' {
        $controls = @(
            'using System.Net.Http; class C { private readonly HttpClient client = new HttpClient(); }',
            'using System.Net.Http; class C { private readonly HttpClient client; C() { this.client = new HttpClient(); } }'
        )
        foreach ($content in $controls) {
            (Invoke-ConventionCase `
                -RuleId http-client-lifetime `
                -Content $content).state |
                Should -BeExactly violation
        }
    }

    It 'resolves System HttpClient aliases and withholds foreign aliases' {
        $system = 'using Client = System.Net.Http.HttpClient; class C { void M() { using var client = new Client(); } }'
        $foreign = 'using HttpClient = Custom.HttpClient; class C { void M() { var client = new HttpClient(); } }'
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $system).state |
            Should -BeExactly violation
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $foreign).state |
            Should -BeExactly unknown
    }

    It 'does not leak namespace imports or aliases across sibling namespaces' {
        $usingLeak = 'namespace A { using System.Net.Http; class Imported { } } namespace B { using Foreign; class C { void M() { var c = new HttpClient(); } } }'
        $aliasLeak = 'namespace A { using Client = Foreign.HttpClient; class Imported { } } namespace B { using Client = System.Net.Http.HttpClient; class C { void M() { var c = new Client(); } } }'
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $usingLeak).state |
            Should -BeExactly unknown
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $aliasLeak).state |
            Should -BeExactly violation
    }

    It 'flags target-typed System HttpClient construction' {
        $content = 'using System.Net.Http; class C { void M() { HttpClient client = new(); } }'
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $content).state |
            Should -BeExactly violation
    }

    It 'does not mistake a readonly client factory delegate for a singleton' {
        $content = 'using System; using System.Net.Http; class C { private static readonly Func<HttpClient> Factory = () => new HttpClient(); }'
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $content).state |
            Should -BeExactly violation
    }

    It 'binds static-constructor singleton proof to the same containing type' {
        $content = 'using System.Net.Http; class A { private static readonly HttpClient Client = new HttpClient(); } class B { static B() { HttpClient Client; Client = new HttpClient(); } }'
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $content).state |
            Should -BeExactly violation
    }

    It 'does not flag factory-managed client acquisition' {
        $content = 'using System.Net.Http; class C { private readonly IHttpClientFactory factory; C(IHttpClientFactory factory) { this.factory = factory; } HttpClient M() { return this.factory.CreateClient("managed"); } }'
        (Invoke-ConventionCase `
            -RuleId http-client-lifetime `
            -Content $content).state |
            Should -Not -BeExactly violation
    }

    It 'does not treat a successful HttpResponseMessage as an API error' {
        $content = 'class CController { [HttpGet] HttpResponseMessage M() { return new HttpResponseMessage(HttpStatusCode.OK); } }'
        (Invoke-ConventionCase `
            -RuleId api-errors `
            -Content $content).state |
            Should -Not -BeExactly violation
    }

    It 'does not treat a null secret-shaped response field as a leak' {
        $content = 'class C { TokenResponse CreateResponse() { var response = new TokenResponse(); response.ApiKey = null; return response; } }'
        (Invoke-ConventionCase `
            -RuleId secret-redaction `
            -Content $content).state |
            Should -BeExactly unknown
    }

    It 'honors JsonObject OptIn for deliberately unannotated scratch properties' {
        $content = '[JsonObject(MemberSerialization.OptIn)] class Response { public string Scratch { get; set; } [JsonProperty] public string Value { get; set; } }'
        (Invoke-ConventionCase `
            -RuleId json-contracts `
            -Content $content).state |
            Should -Not -BeExactly violation
    }

    It 'does not call one bounded reflection lookup repeated work' {
        $content = 'class C { MethodInfo M(Type type) { return type.GetMethod("Run"); } }'
        (Invoke-ConventionCase `
            -RuleId cache-streaming `
            -Content $content).state |
            Should -Not -BeExactly violation
    }

    It 'does not compare dependency versions across unrelated project directories' {
        $project = '<PackageReference Include="Contoso.Client" Version="2.0.0" />'
        $files = @(
            [ordered]@{
                path = 'src/App/App.csproj'
                content = $project
                state = 'complete'
                spans = @([ordered]@{
                        startLine = 1
                        endLine = 1
                    })
            },
            [ordered]@{
                path = 'src/Other/packages.config'
                content = '<package id="Contoso.Client" version="1.0.0" />'
                state = 'complete'
                spans = @([ordered]@{
                        startLine = 1
                        endLine = 1
                    })
            })
        (Invoke-ConventionCase `
            -RuleId dependency-fanout `
            -Content $project `
            -Path 'src/App/App.csproj' `
            -SnapshotFiles $files).state |
            Should -BeExactly unknown
    }

    It 'keeps receiver, lexical scope, and control-flow controls non-violating' {
        $controls = @(
            @{
                rule = 'exception-logging'
                source = 'using System; using System.IO; class Logger { public void LogError(Exception exception, string message, string detail) { } } class C { private readonly Logger logger = new Logger(); void M() { try { File.OpenRead("fixture"); } catch (IOException ex) { logger.LogError(ex, "Handled I/O failure", ex.Message); } } }'
            },
            @{
                rule = 'async-all-the-way'
                source = 'using System.Threading.Tasks; class Value { public int Result => 42; } class C { public async Task<int> ReadAsync(Value value) { await Task.Delay(1).ConfigureAwait(false); return value.Result; } }'
            },
            @{
                rule = 'async-io'
                source = 'using System.Threading.Tasks; class Counter { public int Read() => 42; } class C { public async Task<int> ReadAsync(Counter counter) { await Task.Delay(1).ConfigureAwait(false); return counter.Read(); } }'
            },
            @{
                rule = 'thread-safe-immutable'
                source = 'class Client { } class C { private static int unrelatedCount; public Client Create() { Client local = null; if (local == null) { local = new Client(); } return local; } }'
            },
            @{
                rule = 'type-based-decisions'
                source = 'class Request { public string Message { get; set; } } class C { public bool IsEmpty(Request ex) { if (ex.Message.Length == 0) { return true; } return false; } }'
            },
            @{
                rule = 'cache-streaming'
                source = 'class Routes { public string GetMethod(string name) => name; } class C { public string Select(Routes routes) { var first = routes.GetMethod("one"); var second = routes.GetMethod("two"); return first + second; } }'
            },
            @{
                rule = 'cache-streaming'
                source = 'using System; using System.Net.Http; using System.Threading.Tasks; class C { public async Task<byte[]> ReadAsync(HttpResponseMessage response) { if (response.Content.Headers.ContentLength > 1048576) { throw new InvalidOperationException("Bounded input rejected"); } return await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false); } }'
            },
            @{
                rule = 'http-client-lifetime'
                source = 'using System.Net.Http; namespace Fixture { class HttpClient { public void Process() { } } class C { public void M() { var client = new HttpClient(); client.Process(); } } }'
            },
            @{
                rule = 'cheap-validation'
                source = 'using System; using System.Threading.Tasks; class Request { public string Id { get; set; } } class C { public void Register() { Func<Request, bool> validator = request => request.Id != null; } public async Task FetchAsync() { await Task.Delay(1).ConfigureAwait(false); } }'
            },
            @{
                rule = 'explicit-string-comparison'
                source = 'using System; class C { public bool CompareText(string a, string b) { return string.Equals(a, b, StringComparison.Ordinal); } public bool CompareNumbers(int a, int b) { return a == b; } }'
            },
            @{
                rule = 'exception-propagation'
                source = 'using System; class C { public void Fail(Exception ex) { throw ex; } }'
            }
        )
        foreach ($control in $controls) {
            (Invoke-ConventionCase `
                -RuleId $control.rule `
                -Content $control.source).state |
                Should -Not -BeExactly violation `
                    -Because $control.rule
        }
    }

    It 'ignores inactive packages.config under explicit PackageReference style' {
        $project = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework><RestoreProjectStyle>PackageReference</RestoreProjectStyle></PropertyGroup><ItemGroup><PackageReference Include="Example.Package" Version="2.0.0" /></ItemGroup></Project>'
        $files = @(
            [ordered]@{
                path = 'src/Fixture/Fixture.csproj'
                content = $project
                state = 'complete'
                spans = @([ordered]@{
                        startLine = 1
                        endLine = 1
                    })
            },
            [ordered]@{
                path = 'src/Fixture/packages.config'
                content = '<packages><package id="Example.Package" version="1.0.0" targetFramework="net48" /></packages>'
                state = 'complete'
                spans = @([ordered]@{
                        startLine = 1
                        endLine = 1
                    })
            })
        (Invoke-ConventionCase `
            -RuleId dependency-fanout `
            -Content $project `
            -Path 'src/Fixture/Fixture.csproj' `
            -SnapshotFiles $files).state |
            Should -Not -BeExactly violation
    }
    It 'withholds violation anchors outside the changed spans' {
        $cases = @(
            @{ rule = 'collection-cardinality'; line = 1; source = "class C { object M(System.Collections.Generic.IEnumerable<object> values) { var item = values.First();`nvar changed = 1; return item; } }" },
            @{ rule = 'async-all-the-way'; line = 1; source = "class C { int M(System.Threading.Tasks.Task<int> task) { var item = task.Result;`nvar changed = 1; return item; } }" },
            @{ rule = 'explicit-string-comparison'; line = 1; source = "class C { bool M(string left, string right) { var item = left == right;`nvar changed = 1; return item; } }" }
        )
        foreach ($case in $cases) {
            $outcome = @(Get-ContextualConventionOutcomes `
                    -Content $case.source -Path 'src/Changed.cs' `
                    -Spans @([ordered]@{ startLine = 2; endLine = 2 }) `
                    -SnapshotFiles @([ordered]@{
                            path = 'src/Changed.cs'
                            content = $case.source
                            state = 'complete'
                            spans = @([ordered]@{ startLine = 2; endLine = 2 })
                        }) | Where-Object ruleId -CEQ $case.rule)[0]
            $outcome.state | Should -Not -BeExactly violation
            $outcome.reason | Should -BeExactly candidate-outside-changed-spans
        }
    }

    It 'honors terminating Count(), stable ordering, and protocol ordering' {
        $controls = @(
            'class C { int M(int[] values) { if (values.Count() != 1) throw new Exception(); return values.First(); } }',
            'class C { int M(int[] values) { var ordered = values.OrderBy(value => value); return ordered.FirstOrDefault(); } }',
            'class C { string M(string header) { return header.Split(";").First(); } }',
            'class C { object M(Method method) { return method.Body.Statements.First(); } }'
        )
        foreach ($source in $controls) {
            (Invoke-ConventionCase `
                -RuleId collection-cardinality `
                -Content $source).state |
                Should -Not -BeExactly violation
        }
    }

    It 'accepts only equivalence-preserving grouped representative deduplication' {
        $controls = @(
            'class C { IEnumerable<int> M(IEnumerable<int> values) { return values.GroupBy(value => value).Select(group => group.First()); } }',
            'class C { object M(IEnumerable<string> paths) { return paths.Select(path => Microsoft.CodeAnalysis.MetadataReference.CreateFromFile(path)).GroupBy(reference => reference.Display, StringComparer.OrdinalIgnoreCase).Select(group => group.First()); } }'
        )
        foreach ($source in $controls) {
            $outcome = Invoke-ConventionCase `
                -RuleId collection-cardinality -Content $source
            $outcome.state | Should -BeExactly compliant
            $outcome.reason |
                Should -BeExactly equivalent-group-representative-dedup
        }

        $unknown = @(
            'class C { object M(Item[] values) { return values.GroupBy(value => value.Id).Select(group => group.First()); } }',
            'class C { object M(Item<int>[] values) { return values.GroupBy(value => value).Select(group => group.First()); } }',
            'class C { IEnumerable<int> M(IEnumerable<int> values, IEqualityComparer<int> comparer) { return values.GroupBy(value => value, comparer).Select(group => group.First()); } }',
            'class C { object M(IEnumerable<string> paths) { return RoslynCompilationTestHelper.CreateMetadataReferencesForExistingAssemblies(paths).GroupBy(reference => reference.Display, StringComparer.OrdinalIgnoreCase).Select(group => group.First()); } }'
        )
        foreach ($source in $unknown) {
            $outcome = Invoke-ConventionCase `
                -RuleId collection-cardinality -Content $source
            $outcome.state | Should -BeExactly unknown
            $outcome.reason |
                Should -BeExactly group-representative-equivalence-unproven
        }

        $payload = 'class C { object M(Item[] values) { return values.GroupBy(value => value.Id).Select(group => group.First().Payload); } }'
        (Invoke-ConventionCase `
            -RuleId collection-cardinality -Content $payload).state |
            Should -BeExactly violation
    }

    It 'withholds only synchronous assertion callbacks from file IO guidance' {
        $sync = 'class C { byte[] M(string path) { return File.ReadAllBytes(path); } }'
        (Invoke-ConventionCase `
            -RuleId async-io -Content $sync).state |
            Should -BeExactly violation

        $assertion = 'class C { void M(string path) { Assert.ThrowsException<Exception>(() => File.ReadAllBytes(path)); } }'
        $assertionOutcome = Invoke-ConventionCase `
            -RuleId async-io -Content $assertion
        $assertionOutcome.state | Should -BeExactly unknown
        $assertionOutcome.reason |
            Should -BeExactly assertion-callback-io-context-unproven

        $async = 'class C { async Task<byte[]> M(string path) { await Task.Yield(); return File.ReadAllBytes(path); } }'
        (Invoke-ConventionCase `
            -RuleId async-io -Content $async).state |
            Should -BeExactly violation
    }

    It 'binds cheap validation only to actual validation callback APIs' {
        $wrapper = 'class C { Task<string> ValidateAndCreateFlow() { return TemplateEngine.HandleTemplateException(protectedMethod: async () => await Database.ReadAsync()); } }'
        (Invoke-ConventionCase `
            -RuleId cheap-validation `
            -Content $wrapper).state |
            Should -Not -BeExactly violation
        $validation = 'class C { Task<bool> M() { return RequestValidation.Validate(validationDelegate: async () => await Database.ExistsAsync()); } }'
        (Invoke-ConventionCase `
            -RuleId cheap-validation `
            -Content $validation).state |
            Should -BeExactly violation
    }
    It 'keeps a changed violation when an unchanged neighbor follows it' {
        $source = @(
            'using System.Linq;'
            'class C {'
            '    object M(object[] changed, object[] old) {'
            '        var current = changed.First();'
            '        var previous = old.First();'
            '        return current;'
            '    }'
            '}'
        ) -join "`n"
        $outcome = @(Get-ContextualConventionOutcomes `
                -Content $source -Path 'src/Mixed.cs' `
                -Spans @([ordered]@{ startLine = 4; endLine = 4 }) `
                -SnapshotFiles @([ordered]@{
                        path = 'src/Mixed.cs'
                        content = $source
                        state = 'complete'
                        spans = @([ordered]@{ startLine = 4; endLine = 4 })
                    }) | Where-Object ruleId -CEQ collection-cardinality)[0]
        $outcome.state | Should -BeExactly violation
        $outcome.line | Should -Be 4
    }
    It 'withholds typed generic catch filters without fatal classification semantics' {
        $source = 'class C { object M() { try { return Read(); } catch (Exception ex) when (ex is FormatException || ex is ArgumentException) { return null; } } }'
        $outcome = Invoke-ConventionCase `
            -RuleId exception-propagation -Content $source
        $outcome.state | Should -BeExactly unknown
        $outcome.reason | Should -BeExactly typed-filter-fatal-semantics-unproven
    }

    It 'withholds predicate First selection without a proven uniqueness contract' {
        $source = 'class C { object M(object[] values) { return values.FirstOrDefault(value => value != null); } }'
        $outcome = Invoke-ConventionCase `
            -RuleId collection-cardinality -Content $source
        $outcome.state | Should -BeExactly unknown
        $outcome.reason | Should -BeExactly predicate-selection-cardinality-unproven
    }
    It 'withholds protocol and positional First selections without uniqueness proof' {
        $controls = @(
            'class C { string M(HttpRequest request) { return request.Headers.GetValues("x").FirstOrDefault(); } }'
            'class C { object M(ItemList items) { if (items.Any()) { return items.First(); } return null; } }'
            'class C { object M(Part[] parts) { return parts.OfType<TextPart>().FirstOrDefault(); } }'
            'class C { object M(Flow flow) { return flow.Definition.Triggers.FirstOrDefault(); } }'
        )
        foreach ($source in $controls) {
            $outcome = Invoke-ConventionCase `
                -RuleId collection-cardinality -Content $source
            $outcome.state | Should -BeExactly unknown
            $outcome.reason | Should -BeExactly positional-selection-cardinality-unproven
        }
    }

    It 'retains predicate First when the method proves a unique collection contract' {
        $source = 'class C { object M(ChannelMap channels) { var selected = channels.Out.First(kvp => kvp.Value != null); var only = channels?.Out.Values.SingleOrDefault(); return selected; } }'
        $outcome = Invoke-ConventionCase `
            -RuleId collection-cardinality -Content $source
        $outcome.state | Should -BeExactly violation
        $outcome.reason | Should -BeExactly arbitrary-first-selection
    }

    It 'evaluates the synthetic required PR-template structure without optional checklist expansion' {
        $description = @'
**Problem:**
The dispatcher is not started by the test host.

**Solution:**
Start the dispatcher during test-host initialization.

**Validation:**
N/A because this synthetic change only exercises documentation parsing.
- [ ] Optional full test pass

**Release Notes**
'@
        $outcome =
            Get-ContextualPullRequestTemplateOutcome `
                -Metadata (
                    New-SyntheticPullRequestMetadata `
                        -Description $description)
        $outcome.state |
            Should -BeExactly compliant
    }

    It 'accepts bold and ATX heading variants with case and whitespace normalization' {
        $description = @'
##   problem
Observed synthetic failure.

** SOLUTION : **
Applied a synthetic correction.

### VaLiDaTiOn:
Focused synthetic verification completed.
'@
        (Get-ContextualPullRequestTemplateOutcome `
                -Metadata (
                    New-SyntheticPullRequestMetadata `
                        -Description $description)).state |
            Should -BeExactly compliant
    }

    It 'rejects missing, empty, copied-scaffold, fenced, and quoted required sections' {
        $cases = @(
            'No structural sections are present.'
            @'
**Problem:**

**Solution:**

**Validation:**
Describe what validations are needed:
- [ ] Optional full test pass
'@
            @'
```markdown
**Problem:**
Example
**Solution:**
Example
**Validation:**
Example
```
'@
            @'
> **Problem:**
> Example
> **Solution:**
> Example
> **Validation:**
> Example
'@
        )
        foreach ($description in $cases) {
            $outcome =
                Get-ContextualPullRequestTemplateOutcome `
                    -Metadata (
                        New-SyntheticPullRequestMetadata `
                            -Description $description)
            $outcome.state |
                Should -BeExactly violation
            @($outcome.missingSections).Count |
                Should -BeGreaterThan 0
        }
    }

    It 'fails closed when current template authority is unavailable, ambiguous, stale, or malformed' {
        foreach ($reason in @(
                'template-authority-unavailable',
                'template-authority-ambiguous',
                'template-authority-stale',
                'template-authority-malformed')) {
            $outcome =
                Get-ContextualPullRequestTemplateOutcome `
                    -Metadata (
                        New-SyntheticPullRequestMetadata `
                            -Description 'Synthetic' `
                            -State $reason)
            $outcome.state |
                Should -BeExactly unknown
        }
    }
}
