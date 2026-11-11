BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force

    function New-TestOwnerBinding {
        return New-OwnerPipelineBinding `
            -SubjectKey 'host:example/repository:review/42' `
            -HeadKey ('a' * 40) `
            -RuleKey 'rules:owner-v2/root' `
            -CapabilityKey 'capability:review-v1' `
            -AuthorizationKey 'authority:preview-only'
    }

    function New-TestDeliveryAdapter {
        return New-OwnerPipelineAdapter -Stage delivery -Name 'fake-delivery' -Handler {
            param($context)
            $global:OwnerPipelineDeliveryCalls++
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'delivered'
                writeCount = 1
            }
        }
    }

    function New-CompleteAcquisitionAdapter {
        param([string]$Name = 'fake-acquisition', [string]$Origin = 'fixture')

        $capturedOrigin = $Origin
        return New-OwnerPipelineAdapter -Stage acquisition -Name $Name -Handler {
            param($context)
            [void]$global:OwnerPipelineTestEvents.Add('acquisition')
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                adapterMetadata = @{ origin = $capturedOrigin }
                evidenceUnits = @(
                    @{ unitId = 'unit-a'; state = 'complete'; data = @{ text = 'alpha' } }
                    @{ unitId = 'unit-b'; state = 'complete'; data = @{ text = 'beta' } }
                )
            }
        }.GetNewClosure()
    }

    function New-CompleteCapabilityAdapter {
        return New-OwnerPipelineAdapter -Stage capability -Name 'fake-capability' -Handler {
            param($context)
            [void]$global:OwnerPipelineTestEvents.Add('capability')
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @(
                    @{
                        assessmentId = 'assessment-across-units'
                        evidenceUnitIds = @('unit-a', 'unit-b')
                        state = 'complete'
                        findings = @(
                            @{
                                findingId = 'finding-1'
                                summary = 'Deterministic fixture finding.'
                                data = @{ target = @{ kind = 'construct'; id = 'sample' } }
                            }
                        )
                    }
                )
            }
        }
    }
}

Describe 'Owner pipeline binding' {
    It 'owns immutable subject, head, rule, capability, and authorization identities' {
        $binding = New-TestOwnerBinding
        { $binding.SubjectKey = 'changed' } | Should -Throw
        { $binding.HeadKey = ('b' * 40) } | Should -Throw
        { $binding.RuleKey = 'changed' } | Should -Throw
        { $binding.AuthorizationKey = 'changed' } | Should -Throw

        $differentRule = New-OwnerPipelineBinding `
            -SubjectKey $binding.SubjectKey `
            -HeadKey $binding.HeadKey `
            -RuleKey 'rules:different' `
            -CapabilityKey $binding.CapabilityKey `
            -AuthorizationKey $binding.AuthorizationKey
        $differentAuthority = New-OwnerPipelineBinding `
            -SubjectKey $binding.SubjectKey `
            -HeadKey $binding.HeadKey `
            -RuleKey $binding.RuleKey `
            -CapabilityKey $binding.CapabilityKey `
            -AuthorizationKey 'authority:different'

        $binding.BindingId | Should -Match '^v1:sha256:[0-9a-f]{64}$'
        $differentRule.BindingId | Should -Not -Be $binding.BindingId
        $differentAuthority.BindingId | Should -Not -Be $binding.BindingId
    }
}

Describe 'Owner pipeline facade' {
    BeforeEach {
        $global:OwnerPipelineTestEvents = [Collections.Generic.List[string]]::new()
        $global:OwnerPipelineDeliveryCalls = 0
    }

    AfterEach {
        Remove-Variable OwnerPipelineTestEvents -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable OwnerPipelineDeliveryCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'runs the six wrapper-owned stages in order' {
        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter) `
            -CapabilityAdapter (New-CompleteCapabilityAdapter)

        @($result.stages.name) -join ' -> ' | Should -Be (
            'Acquire snapshot -> Build evidence -> Run capability -> ' +
            'Validate findings -> Preview -> Authorize delivery')
        @($result.stages.state) | Should -Not -Contain 'pending'
        @($result.stages.state) | Should -Not -Contain 'running'
        @($global:OwnerPipelineTestEvents) -join ',' | Should -Be 'acquisition,capability'
        $result.state | Should -Be 'complete'
        ($result.evidence.evidenceUnits -is [object[]]) | Should -BeTrue
        ($result.capability.assessments -is [object[]]) | Should -BeTrue
        ($result.preview.findings -is [object[]]) | Should -BeTrue
        ($result.preview.unitCoverage -is [object[]]) | Should -BeTrue
    }

    It 'fails closed when an adapter changes the atomic binding' {
        $binding = New-TestOwnerBinding
        $acquisition = New-OwnerPipelineAdapter -Stage acquisition -Name 'wrong-binding' -Handler {
            param($context)
            [void]$global:OwnerPipelineTestEvents.Add('acquisition')
            return @{
                schemaVersion = 1
                bindingId = ('v1:sha256:' + ('0' * 64))
                state = 'complete'
                evidenceUnits = @()
            }
        }
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'must-not-run' -Handler {
            param($context)
            [void]$global:OwnerPipelineTestEvents.Add('capability')
            throw 'capability should not run'
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding $binding `
            -AcquisitionAdapter $acquisition `
            -CapabilityAdapter $capability `
            -DeliveryAdapter (New-TestDeliveryAdapter)

        $result.state | Should -Be 'failed'
        $result.stages[0].state | Should -Be 'failed'
        @($result.stages | Select-Object -Skip 1).state | Should -Not -Contain 'complete'
        @($global:OwnerPipelineTestEvents) -join ',' | Should -Be 'acquisition'
        $global:OwnerPipelineDeliveryCalls | Should -Be 0
        @($result.diagnostics.code) | Should -Contain 'binding-mismatch'
    }

    It 'preserves uncovered partial units as unknown and withholds delivery' {
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'partial-capability' -Handler {
            param($context)
            [void]$global:OwnerPipelineTestEvents.Add('capability')
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @(
                    @{
                        assessmentId = 'only-unit-a'
                        evidenceUnitIds = @('unit-a')
                        state = 'complete'
                        findings = @()
                    }
                )
            }
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter) `
            -CapabilityAdapter $capability `
            -DeliveryAdapter (New-TestDeliveryAdapter) `
            -AuthorizeDelivery

        $result.state | Should -Be 'unknown'
        ($result.validation.unitCoverage | Where-Object unitId -EQ 'unit-a').state | Should -Be 'complete'
        ($result.validation.unitCoverage | Where-Object unitId -EQ 'unit-b').state | Should -Be 'unknown'
        $result.delivery.state | Should -Be 'blocked'
        $result.delivery.attempted | Should -BeFalse
        $global:OwnerPipelineDeliveryCalls | Should -Be 0
        ($result.preview.findings -is [object[]]) | Should -BeTrue
        $result.preview.findings.Count | Should -Be 0
    }

    It 'never invokes delivery by default' {
        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter) `
            -CapabilityAdapter (New-CompleteCapabilityAdapter) `
            -DeliveryAdapter (New-TestDeliveryAdapter)

        $result.preview.writeAllowed | Should -BeFalse
        $result.delivery.state | Should -Be 'not-authorized'
        $result.delivery.attempted | Should -BeFalse
        $result.delivery.writeCount | Should -Be 0
        $global:OwnerPipelineDeliveryCalls | Should -Be 0
    }

    It 'treats empty evidence as unknown and never authorizes it for delivery' {
        $acquisition = New-OwnerPipelineAdapter -Stage acquisition -Name 'empty-acquisition' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                evidenceUnits = @()
            }
        }
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'empty-capability' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @()
            }
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter $acquisition `
            -CapabilityAdapter $capability `
            -DeliveryAdapter (New-TestDeliveryAdapter) `
            -AuthorizeDelivery

        $result.state | Should -Be 'unknown'
        ($result.evidence.evidenceUnits -is [object[]]) | Should -BeTrue
        $result.evidence.evidenceUnits.Count | Should -Be 0
        $result.validation.state | Should -Be 'unknown'
        $result.delivery.state | Should -Be 'blocked'
        $global:OwnerPipelineDeliveryCalls | Should -Be 0
    }

    It 'keeps case-distinct evidence identities separate during validation' {
        $acquisition = New-OwnerPipelineAdapter -Stage acquisition -Name 'case-acquisition' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'incomplete'
                evidenceUnits = @(
                    @{ unitId = 'unit'; state = 'unknown'; data = @{} }
                    @{ unitId = 'UNIT'; state = 'complete'; data = @{} }
                )
            }
        }
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'case-capability' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @(
                    @{
                        assessmentId = 'upper-only'
                        evidenceUnitIds = @('UNIT')
                        state = 'complete'
                        findings = @()
                    }
                )
            }
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter $acquisition `
            -CapabilityAdapter $capability `
            -DeliveryAdapter (New-TestDeliveryAdapter) `
            -AuthorizeDelivery

        ($result.validation.unitCoverage | Where-Object unitId -CEQ 'unit').state | Should -Be 'unknown'
        ($result.validation.unitCoverage | Where-Object unitId -CEQ 'UNIT').state | Should -Be 'complete'
        $result.state | Should -Be 'unknown'
        $global:OwnerPipelineDeliveryCalls | Should -Be 0
    }

    It 'invokes an authorized delivery adapter once with a bound writable preview' {
        $delivery = New-OwnerPipelineAdapter -Stage delivery -Name 'json-delivery' -Handler {
            param($context)
            $global:OwnerPipelineDeliveryCalls++
            $context.preview.writeAllowed | Should -BeTrue
            $context.authorization.authorized | Should -BeTrue
            $context.authorization.bindingId | Should -Be $context.binding.BindingId
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'delivered'
                writeCount = [long]1
            }
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter) `
            -CapabilityAdapter (New-CompleteCapabilityAdapter) `
            -DeliveryAdapter $delivery `
            -AuthorizeDelivery

        $global:OwnerPipelineDeliveryCalls | Should -Be 1
        $result.preview.writeAllowed | Should -BeFalse
        $result.delivery.state | Should -Be 'delivered'
        $result.delivery.attempted | Should -BeTrue
        $result.delivery.writeCount | Should -Be 1
        $result.preview.findings[0].assessmentId | Should -Be 'assessment-across-units'
        @($result.preview.findings[0].evidenceUnitIds) | Should -Be @('unit-a', 'unit-b')
    }

    It 'fails closed when delivery does not echo the binding' {
        $delivery = New-OwnerPipelineAdapter -Stage delivery -Name 'wrong-delivery-binding' -Handler {
            param($context)
            $global:OwnerPipelineDeliveryCalls++
            return @{
                schemaVersion = 1
                bindingId = ('v1:sha256:' + ('f' * 64))
                state = 'delivered'
                writeCount = 1
            }
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter) `
            -CapabilityAdapter (New-CompleteCapabilityAdapter) `
            -DeliveryAdapter $delivery `
            -AuthorizeDelivery

        $global:OwnerPipelineDeliveryCalls | Should -Be 1
        $result.state | Should -Be 'failed'
        $result.delivery.state | Should -Be 'failed'
        $result.delivery.writeCount | Should -Be 0
        @($result.diagnostics.code) | Should -Contain 'binding-mismatch'
    }

    It 'isolates adapter failures and keeps diagnostics bounded' {
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'failing-capability' -Handler {
            param($context)
            [void]$global:OwnerPipelineTestEvents.Add('capability')
            throw 'sensitive fixture detail that must not cross the facade'
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter) `
            -CapabilityAdapter $capability `
            -DeliveryAdapter (New-TestDeliveryAdapter)

        $result.state | Should -Be 'failed'
        ($result.stages | Where-Object name -EQ 'Run capability').state | Should -Be 'failed'
        ($result.stages | Where-Object name -EQ 'Validate findings').state | Should -Be 'skipped'
        $result.preview | Should -BeNullOrEmpty
        $global:OwnerPipelineDeliveryCalls | Should -Be 0
        $result.diagnostics.Count | Should -BeLessOrEqual 16
        $result.diagnostics[0].message.Length | Should -BeLessOrEqual 240
        ($result.diagnostics | ConvertTo-Json -Compress) | Should -Not -Match 'sensitive fixture detail'
    }

    It 'preserves timestamp strings and rejects non-JSON adapter data without throwing' {
        $timestamp = '2026-09-08T12:00:00Z'
        $timestampAcquisition = New-OwnerPipelineAdapter -Stage acquisition -Name 'timestamp-acquisition' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                evidenceUnits = @(
                    @{ unitId = 'unit-a'; state = 'complete'; data = @{ committedAt = $timestamp } }
                )
            }
        }.GetNewClosure()
        $singleCapability = New-OwnerPipelineAdapter -Stage capability -Name 'single-capability' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @(
                    @{
                        assessmentId = 'single'
                        evidenceUnitIds = @('unit-a')
                        state = 'complete'
                        findings = @()
                    }
                )
            }
        }

        $timestampResult = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter $timestampAcquisition `
            -CapabilityAdapter $singleCapability
        $timestampResult.state | Should -Be 'complete'
        $timestampResult.evidence.evidenceUnits[0].data.committedAt | Should -Be $timestamp
        $timestampResult.evidence.evidenceUnits[0].data.committedAt | Should -BeOfType [string]

        $invalidAcquisition = New-OwnerPipelineAdapter -Stage acquisition -Name 'invalid-data' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                evidenceUnits = @(
                    @{ unitId = 'unit-a'; state = 'complete'; data = @{ executable = { 'not JSON' } } }
                )
            }
        }
        { $script:invalidResult = Invoke-OwnerReviewPipeline `
                -Binding (New-TestOwnerBinding) `
                -AcquisitionAdapter $invalidAcquisition `
                -CapabilityAdapter $singleCapability } | Should -Not -Throw
        $script:invalidResult.state | Should -Be 'failed'
        @($script:invalidResult.diagnostics.code) | Should -Contain 'snapshot-unit-invalid'
    }

    It 'reserves diagnostic capacity for facade failures' {
        $acquisition = New-OwnerPipelineAdapter -Stage acquisition -Name 'noisy-acquisition' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                evidenceUnits = @(
                    @{ unitId = 'unit-a'; state = 'complete'; data = @{} }
                )
                diagnostics = @(1..20 | ForEach-Object {
                        @{ code = 'adapter-noise'; message = "noise $_" }
                    })
            }
        }
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'wrong-binding' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = ('v1:sha256:' + ('0' * 64))
                state = 'complete'
                assessments = @()
            }
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter $acquisition `
            -CapabilityAdapter $capability

        @($result.diagnostics | Where-Object code -EQ 'adapter-noise').Count | Should -Be 4
        @($result.diagnostics.code) | Should -Contain 'binding-mismatch'
    }

    It 'preserves case-distinct object members and hashes them deterministically across cultures' {
        $data = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        $data.Add('Value', 'upper')
        $data.Add('value', 'lower')
        $data.Add('co-op', 1)
        $data.Add('coop', 2)
        $acquisition = New-OwnerPipelineAdapter -Stage acquisition -Name 'ordinal-data' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                evidenceUnits = @(
                    @{ unitId = 'unit-a'; state = 'complete'; data = $data }
                )
            }
        }.GetNewClosure()
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'ordinal-capability' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @(
                    @{
                        assessmentId = 'ordinal'
                        evidenceUnitIds = @('unit-a')
                        state = 'complete'
                        findings = @()
                    }
                )
            }
        }
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
            $english = Invoke-OwnerReviewPipeline `
                -Binding (New-TestOwnerBinding) `
                -AcquisitionAdapter $acquisition `
                -CapabilityAdapter $capability
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('da-DK')
            $danish = Invoke-OwnerReviewPipeline `
                -Binding (New-TestOwnerBinding) `
                -AcquisitionAdapter $acquisition `
                -CapabilityAdapter $capability
        }
        finally {
            [Globalization.CultureInfo]::CurrentCulture = $originalCulture
        }

        $english.evidence.evidenceUnits[0].data.Count | Should -Be 4
        $english.evidence.evidenceUnits[0].data['Value'] | Should -Be 'upper'
        $english.evidence.evidenceUnits[0].data['value'] | Should -Be 'lower'
        $english.evidence.evidenceDigest | Should -Be $danish.evidence.evidenceDigest
    }

    It 'accepts aggregate evidence within per-unit and facade count bounds' {
        $units = @(
            1..200 | ForEach-Object {
                @{
                    unitId = "unit-$_"
                    state = 'complete'
                    data = @{ items = @(1..60) }
                }
            }
        )
        $unitIds = @($units | ForEach-Object { $_.unitId })
        $acquisition = New-OwnerPipelineAdapter -Stage acquisition -Name 'bounded-aggregate' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                evidenceUnits = $units
            }
        }.GetNewClosure()
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'bounded-aggregate-capability' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @(
                    @{
                        assessmentId = 'all-units'
                        evidenceUnitIds = $unitIds
                        state = 'complete'
                        findings = @()
                    }
                )
            }
        }.GetNewClosure()

        { $script:aggregateResult = Invoke-OwnerReviewPipeline `
                -Binding (New-TestOwnerBinding) `
                -AcquisitionAdapter $acquisition `
                -CapabilityAdapter $capability } | Should -Not -Throw
        $script:aggregateResult.state | Should -Be 'complete'
        $script:aggregateResult.evidence.evidenceUnits.Count | Should -Be 200
    }

    It 'never publishes raw capability data when validation fails' {
        $capability = New-OwnerPipelineAdapter -Stage capability -Name 'invalid-capability-data' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                assessments = @(
                    @{
                        assessmentId = 'invalid'
                        evidenceUnitIds = @('missing-unit')
                        state = 'complete'
                        findings = @(
                            @{
                                findingId = 'raw-finding'
                                summary = 'Must not escape validation.'
                                data = @{ executable = { 'not JSON' }; oversized = ('x' * 100000) }
                            }
                        )
                    }
                )
            }
        }

        $result = Invoke-OwnerReviewPipeline `
            -Binding (New-TestOwnerBinding) `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter) `
            -CapabilityAdapter $capability

        $result.state | Should -Be 'failed'
        $result.capability.assessments.Count | Should -Be 0
        @($result.diagnostics.code) | Should -Contain 'findings-invalid'
    }

    It 'normalizes evidence-unit order before hashing' {
        $forward = New-OwnerPipelineAdapter -Stage acquisition -Name 'forward-order' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                evidenceUnits = @(
                    @{ unitId = 'unit-a'; state = 'complete'; data = @{ value = 1 } }
                    @{ unitId = 'unit-b'; state = 'complete'; data = @{ value = 2 } }
                )
            }
        }
        $reverse = New-OwnerPipelineAdapter -Stage acquisition -Name 'reverse-order' -Handler {
            param($context)
            return @{
                schemaVersion = 1
                bindingId = $context.binding.BindingId
                state = 'complete'
                evidenceUnits = @(
                    @{ unitId = 'unit-b'; state = 'complete'; data = @{ value = 2 } }
                    @{ unitId = 'unit-a'; state = 'complete'; data = @{ value = 1 } }
                )
            }
        }
        $binding = New-TestOwnerBinding
        $capability = New-CompleteCapabilityAdapter
        $forwardResult = Invoke-OwnerReviewPipeline `
            -Binding $binding `
            -AcquisitionAdapter $forward `
            -CapabilityAdapter $capability
        $reverseResult = Invoke-OwnerReviewPipeline `
            -Binding $binding `
            -AcquisitionAdapter $reverse `
            -CapabilityAdapter $capability

        @($reverseResult.evidence.evidenceUnits.unitId) | Should -Be @('unit-a', 'unit-b')
        $forwardResult.evidence.evidenceDigest | Should -Be $reverseResult.evidence.evidenceDigest
    }

    It 'normalizes replay and live acquisition to the same facade boundary' {
        $binding = New-TestOwnerBinding
        $capability = New-CompleteCapabilityAdapter

        $replay = Invoke-OwnerReviewPipeline `
            -Binding $binding `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter -Name 'replay-adapter' -Origin 'replay') `
            -CapabilityAdapter $capability
        $live = Invoke-OwnerReviewPipeline `
            -Binding $binding `
            -AcquisitionAdapter (New-CompleteAcquisitionAdapter -Name 'live-adapter' -Origin 'live') `
            -CapabilityAdapter $capability

        $replay.evidence.evidenceDigest | Should -Be $live.evidence.evidenceDigest
        ($replay.evidence | ConvertTo-Json -Depth 20 -Compress) |
            Should -Be ($live.evidence | ConvertTo-Json -Depth 20 -Compress)
        ($replay.validation | ConvertTo-Json -Depth 20 -Compress) |
            Should -Be ($live.validation | ConvertTo-Json -Depth 20 -Compress)
        ($replay.preview | ConvertTo-Json -Depth 20 -Compress) |
            Should -Be ($live.preview | ConvertTo-Json -Depth 20 -Compress)
    }
}

Describe 'Owner pipeline module surface' {
    It 'exports only the minimal layer-one facade' {
        $commands = @(Get-Command -Module DevPilot.OwnerPipeline).Name | Sort-Object
        $commands | Should -Be @(
            'Invoke-OwnerReviewPipeline',
            'New-OwnerPipelineAdapter',
            'New-OwnerPipelineBinding'
        )
        Test-ModuleManifest "$PSScriptRoot\..\src\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" |
            Should -Not -BeNullOrEmpty
    }
}
