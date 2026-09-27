#requires -Version 7.0
Import-Module "$PSScriptRoot\..\src\DevPilot.TestProjectEvidence\DevPilot.TestProjectEvidence.psd1" -Force

Describe 'Source-bound C# Compile project evidence' {
    BeforeAll {
        $script:repo = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $script:commit = 'b' * 40
        $script:fileId = 'c' * 40
        function New-Graph {
            param([string]$ChangedPath = '/Shared/Helper.cs')
            return @{
                path = $ChangedPath
                entries = [System.Collections.Generic.List[object]]::new()
                contents = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
            }
        }
        function Add-GraphBlob {
            param([hashtable]$Graph, [string]$Path, [string]$Content,
                [string]$Id = ('d' * 40))
            $Graph.entries.Add(@{ path = $Path; objectId = $Id; gitObjectType = 'blob' })
            $Graph.contents[$Path] = $Content
        }
        function Invoke-Graph {
            param([hashtable]$Graph, [int]$MaxProjects = 128, [int]$MaxFiles = 10000)
            $reader = { param($path, $objectId) $Graph.contents[$path] }.GetNewClosure()
            Get-TestProjectGraphEvidence -RepositoryId $script:repo -SourceCommit $script:commit `
                -Path $Graph.path -ObjectId $script:fileId -Entries $Graph.entries.ToArray() `
                -ReadItem $reader -MaxProjects $MaxProjects -MaxFiles $MaxFiles
        }
        function Add-ChangedFile {
            param([hashtable]$Graph)
            Add-GraphBlob $Graph $Graph.path 'class Helper {}' $script:fileId
        }
    }

    It 'proves a fixture and helper under an explicitly compiled test project' {
        $graph = New-Graph '/Tests/Fixture.cs'
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup>
<ItemGroup><Compile Include="Fixture.cs;Helper.cs"/></ItemGroup></Project>
'@
        Add-GraphBlob $graph '/Tests/Helper.cs' 'class Helper {}'
        $evidence = Invoke-Graph $graph
        @($evidence.Keys).Count | Should -Be 8
        $evidence.schemaVersion | Should -Be 1
        $evidence.kind | Should -BeExactly 'source-bound-evaluated-project-graph-v1'
        $evidence.complete | Should -BeTrue
        $evidence.repositoryId | Should -BeExactly $script:repo
        $evidence.sourceCommit | Should -BeExactly $script:commit
        $evidence.path | Should -BeExactly '/Tests/Fixture.cs'
        $evidence.objectId | Should -BeExactly $script:fileId
        @($evidence.projects).Count | Should -Be 1
        @($evidence.projects[0].Keys).Count | Should -Be 4
        $evidence.projects[0].path | Should -BeExactly '/Tests/Tests.csproj'
        $evidence.projects[0].compileIncluded | Should -BeTrue
        $evidence.projects[0].isTestProject | Should -BeTrue
    }

    It 'identifies a product-only file as non-test even without IsTestProject' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Product/Product.csproj' @'
<Project><ItemGroup><Compile Include="../Shared/Helper.cs" Link="Helper.cs"/></ItemGroup></Project>
'@
        (Invoke-Graph $graph).projects[0].isTestProject | Should -BeFalse
    }

    It 'returns both owners of a shared linked file with mixed test identity' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Product/Product.csproj' @'
<Project><PropertyGroup><IsTestProject>false</IsTestProject></PropertyGroup>
<ItemGroup><Compile Include="../Shared/Helper.cs"><Link>Helper.cs</Link></Compile></ItemGroup></Project>
'@
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup>
<ItemGroup><Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>
'@ ('e' * 40)
        $owners = (Invoke-Graph $graph).projects
        @($owners).Count | Should -Be 2
        @($owners | Where-Object isTestProject).Count | Should -Be 1
        @($owners | Where-Object { -not $_.isTestProject }).Count | Should -Be 1
    }

    It 'attributes the standard SDK default Compile glob to every nested mixed owner' {
        $graph = New-Graph '/Tests/Product/Nested/Fixture.cs'
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>
'@
        Add-GraphBlob $graph '/Tests/Product/Product.csproj' @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>false</IsTestProject></PropertyGroup></Project>
'@ ('e' * 40)
        $owners = (Invoke-Graph $graph).projects
        @($owners).Count | Should -Be 2
        @($owners | Where-Object isTestProject).Count | Should -Be 1
        @($owners | Where-Object { -not $_.isTestProject }).Count | Should -Be 1
    }

    It 'returns both standard SDK projects in the same directory' {
        $graph = New-Graph '/Tests/Fixture.cs'
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>
'@
        Add-GraphBlob $graph '/Tests/Product.csproj' @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>false</IsTestProject></PropertyGroup></Project>
'@ ('e' * 40)
        $owners = (Invoke-Graph $graph).projects
        @($owners).Count | Should -Be 2
        @($owners | Where-Object isTestProject).Count | Should -Be 1
        @($owners | Where-Object { -not $_.isTestProject }).Count | Should -Be 1
    }

    It 'refuses to assert the SDK default glob under excluded or hidden directories' {
        foreach ($path in @('/Tests/obj/Fixture.cs', '/Tests/bin/Fixture.cs',
                '/Tests/.hidden/Fixture.cs')) {
            $graph = New-Graph $path
            Add-ChangedFile $graph
            Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>
'@
            { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        }
    }

    It 'evaluates nested wildcard Includes, Excludes and Removes in order' {
        $graph = New-Graph '/Shared/Nested/Fixture.cs'
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Shared/Nested/Excluded.cs' 'class Excluded {}'
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup>
<ItemGroup>
<Compile Include="../Shared/**/*.cs" Exclude="../Shared/**/Excluded.cs"/>
<Compile Remove="../Shared/Nested/Fixture.cs"/>
<Compile Include="../Shared/Nested/Fixture.cs" Link="Fixture.cs"/>
</ItemGroup></Project>
'@
        (Invoke-Graph $graph).projects[0].isTestProject | Should -BeTrue
    }

    It 'resolves a pinned simple import and a known condition' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><PropertyGroup><Flavor>test</Flavor></PropertyGroup>
<Import Project="../Shared/compile.props" Condition="'$(Flavor)' == 'test'"/>
</Project>
'@
        Add-GraphBlob $graph '/Shared/compile.props' @'
<Project><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup>
<ItemGroup Condition="'$(Flavor)' == 'test'">
<Compile Include="Helper.cs"/>
</ItemGroup></Project>
'@
        (Invoke-Graph $graph).projects[0].isTestProject | Should -BeTrue
    }

    It 'passes the inventory path and object ID to the verified blob reader' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><ItemGroup><Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>
'@ ('e' * 40)
        $calls = [System.Collections.Generic.List[string]]::new()
        $read = {
            param($path, $id)
            $calls.Add("$path|$id")
            if ($path -ne '/Tests/Tests.csproj' -or $id -cne ('e' * 40)) {
                throw 'unexpected unpinned read'
            }
            $graph.contents[$path]
        }.GetNewClosure()
        $evidence = Get-TestProjectGraphEvidence $script:repo $script:commit $graph.path `
            $script:fileId $graph.entries.ToArray() $read
        $evidence.projects[0].objectId | Should -BeExactly ('e' * 40)
        $calls.ToArray() | Should -Be @("/Tests/Tests.csproj|$('e' * 40)")
    }

    It 'rejects missing changed files, missing imports, and graphs with no owner' {
        $graph = New-Graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' '<Project/>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        Add-ChangedFile $graph
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.contents['/Tests/Tests.csproj'] =
            '<Project><Import Project="missing.props"/></Project>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
    }

    It 'rejects every unexamined non-C# project as a possible owner' {
        foreach ($extension in @('proj', 'fsproj', 'vbproj', 'shproj')) {
            $graph = New-Graph
            Add-ChangedFile $graph
            Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><ItemGroup><Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>
'@
            Add-GraphBlob $graph "/Other/PossibleOwner.$extension" '<Project/>'
            { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        }
    }

    It 'rejects unaccounted props, targets, and shared items that could inject Compile' {
        foreach ($extension in @('props', 'targets', 'projitems')) {
            $graph = New-Graph
            Add-ChangedFile $graph
            Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><ItemGroup><Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>
'@
            Add-GraphBlob $graph "/Other/injected.$extension" @'
<Project><ItemGroup><Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>
'@
            { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        }
        $sdkGraph = New-Graph '/Tests/Fixture.cs'
        Add-ChangedFile $sdkGraph
        Add-GraphBlob $sdkGraph '/Tests/Tests.csproj' @'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>
'@
        Add-GraphBlob $sdkGraph '/Other/injected.targets' '<Project/>'
        { Invoke-Graph $sdkGraph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
    }

    It 'rejects case-ambiguous paths, duplicate entries and blob mismatches' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' '<Project><ItemGroup><Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>'
        $graph.entries.Add(@{ path = '/shared/helper.cs'; objectId = 'f' * 40; gitObjectType = 'blob' })
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.entries.RemoveAt($graph.entries.Count - 1)
        $graph.entries.Add($graph.entries[0])
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.entries.RemoveAt($graph.entries.Count - 1)
        $graph.entries[0].objectId = 'f' * 40
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
    }

    It 'rejects case-dependent glob matches and changed-path case mismatches' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><ItemGroup><Compile Include="../shared/**/*.cs"/></ItemGroup></Project>
'@
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.contents['/Tests/Tests.csproj'] =
            '<Project><ItemGroup><Compile Include="../Shared/**/*.cs"/></ItemGroup></Project>'
        $graph.path = '/shared/Helper.cs'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
    }

    It 'fails closed for customized SDK defaults, Directory.Build and dynamic constructs' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><EnableDefaultCompileItems>false</EnableDefaultCompileItems><IsTestProject>true</IsTestProject></PropertyGroup></Project>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.contents['/Tests/Tests.csproj'] =
            '<Project><ItemGroup><Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>'
        Add-GraphBlob $graph '/Directory.Build.props' '<Project/>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.entries.RemoveAt($graph.entries.Count - 1)
        $graph.contents['/Tests/Tests.csproj'] =
            '<Project><ItemGroup><Compile Include="$(Unpinned)/Helper.cs"/></ItemGroup></Project>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.contents['/Tests/Tests.csproj'] =
            '<Project><ItemGroup><ProjectReference Include="../Other/Other.csproj"/></ItemGroup></Project>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
    }

    It 'rejects unpinned condition variables, malformed XML and imported cycles' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' @'
<Project><ItemGroup Condition="'$(Configuration)' == 'Debug'">
<Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>
'@
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.contents['/Tests/Tests.csproj'] =
            '<!DOCTYPE Project [<!ENTITY x "evil">]><Project><ItemGroup><Compile Include="../Shared/Helper.cs"/></ItemGroup></Project>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        $graph.contents['/Tests/Tests.csproj'] =
            '<Project><Import Project="Tests.csproj"/></Project>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
    }

    It 'rejects out-of-root items and limits before asserting completeness' {
        $graph = New-Graph
        Add-ChangedFile $graph
        Add-GraphBlob $graph '/Tests/Tests.csproj' '<Project><ItemGroup><Compile Include="../../outside.cs"/></ItemGroup></Project>'
        { Invoke-Graph $graph } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        { Invoke-Graph $graph -MaxFiles 1 } | Should -Throw -ExpectedMessage 'project-identity-unknown'
        { Invoke-Graph $graph -MaxProjects 0 } | Should -Throw -ExpectedMessage 'project-identity-unknown'
    }
}
