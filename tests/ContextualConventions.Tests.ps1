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
                    spans = @([ordered]@{
                            startLine = 1
                            endLine = $lines
                        })
                })
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

}

Describe 'Contextual convention analyzer' {
    It 'exports the fixed seventeen-rule allow set' {
        @(Get-ContextualConventionRuleIds) |
            Should -HaveCount 17
    }

    It 'detects a high-confidence <Rule> violation' -TestCases $script:Cases {
        param($Rule, $Violation, $Exemption)
        $result = Invoke-ConventionCase `
            -RuleId $Rule -Content $Violation
        $result.state | Should -BeExactly 'violation'
        $result.line | Should -BeGreaterThan 0
        $result.evidence | Should -Not -BeNullOrEmpty
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
}
