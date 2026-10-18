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
    It 'exports the fixed eighteen-rule allow set' {
        @(Get-ContextualConventionRuleIds) |
            Should -HaveCount 18
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
}
