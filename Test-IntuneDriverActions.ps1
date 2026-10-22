#requires -Version 5.1

$watchPath = Join-Path $PSScriptRoot 'Watch-IntuneDriverPause.ps1'
$guiPath = Join-Path $PSScriptRoot 'Start-IntuneDriverPauseGui.ps1'
$catalogPath = Join-Path $PSScriptRoot 'Get-IntuneDriverPauseCatalog.ps1'
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

Describe 'Driver actions with mocked Microsoft Graph' {
    BeforeEach {
        $script:Requests = New-Object 'System.Collections.Generic.List[object]'
        $script:TestProfiles = @(
            [pscustomobject] @{ id = 'profile-a'; displayName = 'Profile A'; approvalType = 'manual' },
            [pscustomobject] @{ id = 'profile-b'; displayName = 'Profile B'; approvalType = 'automatic' }
        )
        $script:TestInventories = @{}
        foreach ($profile in $script:TestProfiles) {
            $script:TestInventories[$profile.id] = @(
                [pscustomobject] @{
                    id = 'driver-a'; name = 'Target'; version = '1.0'
                    manufacturer = 'Contoso'; approvalStatus = 'suspended'
                },
                [pscustomobject] @{
                    id = 'driver-other'; name = 'Other'; version = '2.0'
                    manufacturer = 'Contoso'; approvalStatus = 'needsReview'
                }
            )
        }
        $script:RunParameters = @{
            DriverId = 'driver-a'
            AuthenticationMode = 'CurrentContext'
            VerificationAttempts = 2
            VerificationDelaySeconds = 0
            LogPath = Join-Path $TestDrive 'actions.log'
        }
        $global:IntuneDriverActionTestState = @{
            Requests = $script:Requests
            Profiles = $script:TestProfiles
            Inventories = $script:TestInventories
            ResponseMode = 'Success'
            InventoryReads = 0
        }
        Mock Get-MgContext {
            [pscustomobject] @{ TenantId = 'test'; ClientId = 'test'; AuthType = 'Delegated' }
        }
        Mock Connect-MgGraph {}
        Mock Disconnect-MgGraph {}
        Mock Invoke-MgGraphRequest {
            param($Method, $Uri, $Body)

            if ($Method -eq 'GET' -and $Uri -match '/windowsDriverUpdateProfiles\?') {
                return [pscustomobject] @{ value = $global:IntuneDriverActionTestState.Profiles }
            }
            if ($Method -eq 'GET' -and $Uri -match '/windowsDriverUpdateProfiles/([^/]+)/driverInventories') {
                $global:IntuneDriverActionTestState.InventoryReads++
                return [pscustomobject] @{ value = $global:IntuneDriverActionTestState.Inventories[$Matches[1]] }
            }
            if ($Method -eq 'POST' -and $Uri -match '/windowsDriverUpdateProfiles/([^/]+)/executeAction$') {
                $profileId = $Matches[1]
                $request = ConvertFrom-Json $Body
                $global:IntuneDriverActionTestState.Requests.Add([pscustomobject] @{ ProfileId = $profileId; Body = $request })
                $profileRequestCount = @($global:IntuneDriverActionTestState.Requests |
                    Where-Object { $_.ProfileId -eq $profileId }).Count
                if ($global:IntuneDriverActionTestState.ResponseMode -eq 'Throw') {
                    throw 'Graph access denied'
                }
                $failed = @()
                $notFound = @()
                if ($global:IntuneDriverActionTestState.ResponseMode -eq 'Rejected') {
                    $failed = @($request.driverIds)
                }
                elseif ($global:IntuneDriverActionTestState.ResponseMode -eq 'NotFound') {
                    $notFound = @($request.driverIds)
                }
                elseif ($global:IntuneDriverActionTestState.ResponseMode -in @('RejectOnce', 'RejectThenUnapprove') -and
                    $profileRequestCount -eq 1) {
                    $failed = @($request.driverIds)
                }
                elseif ($global:IntuneDriverActionTestState.ResponseMode -eq 'PartialRejectOnce' -and
                    $profileRequestCount -eq 1) {
                    $failed = @($request.driverIds | Select-Object -Last 1)
                }
                elseif ($global:IntuneDriverActionTestState.ResponseMode -eq 'RejectedButApplied') {
                    $failed = @($request.driverIds)
                }
                if ($global:IntuneDriverActionTestState.ResponseMode -notin @('Unconfirmed', 'NotFound')) {
                    foreach ($driver in $global:IntuneDriverActionTestState.Inventories[$profileId]) {
                        if ($driver.id -in $request.driverIds -and
                            ($driver.id -notin $failed -or
                                $global:IntuneDriverActionTestState.ResponseMode -eq 'RejectedButApplied')) {
                            $driver.approvalStatus = if ($request.actionName -eq 'approve') {
                                'approved'
                            }
                            else {
                                'suspended'
                            }
                        }
                    }
                    if ($global:IntuneDriverActionTestState.ResponseMode -eq 'RejectThenUnapprove') {
                        foreach ($driver in $global:IntuneDriverActionTestState.Inventories[$profileId]) {
                            if ($driver.id -in $failed) {
                                $driver.approvalStatus = 'needsReview'
                            }
                        }
                    }
                }
                return [pscustomobject] @{
                    value = [pscustomobject] @{
                        failedDriverIds = $failed
                        notFoundDriverIds = $notFound
                    }
                }
            }
            throw "Unexpected Graph request: $Method $Uri"
        }
    }

    AfterEach {
        Remove-Variable -Name IntuneDriverActionTestState -Scope Global
    }

    It 'approves only the selected profile and driver, with a current UTC deployment date' {
        $start = [DateTimeOffset]::UtcNow
        & $watchPath @RunParameters -Action Approve -ProfileId 'profile-a'
        $script:Requests.Count | Should Be 1
        $script:Requests[0].ProfileId | Should Be 'profile-a'
        $body = $script:Requests[0].Body
        $body.actionName | Should Be 'approve'
        @($body.driverIds).Count | Should Be 1
        $body.driverIds[0] | Should Be 'driver-a'
        $date = [DateTimeOffset]::Parse($body.deploymentDate)
        ($date -ge $start -and $date -le [DateTimeOffset]::UtcNow) | Should Be $true
        $date.Offset.TotalMinutes | Should Be 0
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'approved'
        $script:TestInventories['profile-b'][0].approvalStatus | Should Be 'suspended'
        $script:TestInventories['profile-a'][1].approvalStatus | Should Be 'needsReview'
        $global:IntuneDriverActionTestState.InventoryReads | Should Be 2
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'APPROVE_CONFIRMED'
    }

    It 'approves in every profile and leaves already approved drivers unchanged' {
        $script:TestInventories['profile-b'][0].approvalStatus = 'approved'
        & $watchPath @RunParameters -Action Approve
        $script:Requests.Count | Should Be 1
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'approved'
        $script:TestInventories['profile-b'][0].approvalStatus | Should Be 'approved'
        & $watchPath @RunParameters -Action Approve
        $script:Requests.Count | Should Be 1
    }

    It 'sends approval to all profiles when both require approval' {
        & $watchPath @RunParameters -Action Approve
        $script:Requests.Count | Should Be 2
        @($script:Requests | Where-Object { $_.Body.actionName -eq 'approve' }).Count | Should Be 2
    }

    It 'does not send an action in approval simulation' {
        & $watchPath @RunParameters -Action Approve -WhatIf
        $script:Requests.Count | Should Be 0
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'suspended'
    }

    It 'preserves suspension as the default and does not send a deployment date' {
        $script:TestInventories['profile-b'][0].approvalStatus = 'approved'
        & $watchPath @RunParameters
        $script:Requests.Count | Should Be 1
        $script:Requests[0].ProfileId | Should Be 'profile-b'
        $script:Requests[0].Body.actionName | Should Be 'suspend'
        $script:Requests[0].Body.PSObject.Properties.Name -contains 'deploymentDate' | Should Be $false
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'AlreadySuspended=1; SuspendedNow=1'
    }

    It 'fails if Graph rejects a driver and still processes other profiles' {
        $global:IntuneDriverActionTestState.ResponseMode = 'Rejected'
        { & $watchPath @RunParameters -Action Approve } | Should Throw
        $script:Requests.Count | Should Be 6
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'Graph a refuse'
    }

    It 'retries a rejected approval after reading the inventory again' {
        $global:IntuneDriverActionTestState.ResponseMode = 'RejectOnce'
        & $watchPath @RunParameters -Action Approve -ProfileId 'profile-a'
        $script:Requests.Count | Should Be 2
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'approved'
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'ACTION_RETRY'
    }

    It 'retries a rejected suspension without ever approving the driver' {
        $global:IntuneDriverActionTestState.ResponseMode = 'RejectOnce'
        $script:TestInventories['profile-a'][0].approvalStatus = 'approved'
        & $watchPath @RunParameters -ProfileId 'profile-a'
        $script:Requests.Count | Should Be 2
        @($script:Requests | Where-Object { $_.Body.actionName -ne 'suspend' }).Count | Should Be 0
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'suspended'
    }

    It 'retries only the rejected drivers from a partially accepted batch' {
        $global:IntuneDriverActionTestState.ResponseMode = 'PartialRejectOnce'
        $RunParameters.Remove('DriverId')
        $RunParameters.DriverName = @('Target', 'Other')
        & $watchPath @RunParameters -Action Approve -ProfileId 'profile-a'
        $script:Requests.Count | Should Be 2
        @($script:Requests[0].Body.driverIds).Count | Should Be 2
        @($script:Requests[1].Body.driverIds).Count | Should Be 1
        $script:Requests[1].Body.driverIds[0] | Should Be 'driver-other'
    }

    It 'verifies an already converged result without resending a rejected action' {
        $global:IntuneDriverActionTestState.ResponseMode = 'RejectedButApplied'
        & $watchPath @RunParameters -Action Approve -ProfileId 'profile-a'
        $script:Requests.Count | Should Be 1
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'approved'
    }

    It 'does not retry suspension if the driver is no longer approved' {
        $global:IntuneDriverActionTestState.ResponseMode = 'RejectThenUnapprove'
        $script:TestInventories['profile-a'][0].approvalStatus = 'approved'
        { & $watchPath @RunParameters -ProfileId 'profile-a' } | Should Throw
        $script:Requests.Count | Should Be 1
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'needsReview'
    }

    It 'reports needsReview in each profile without attempting an invalid suspension or approval' {
        $script:TestInventories['profile-a'][0].approvalStatus = 'needsReview'
        $script:TestInventories['profile-b'][0].approvalStatus = 'needsReview'
        $failure = $null
        try {
            & $watchPath @RunParameters
        }
        catch {
            $failure = $_.Exception.Message
        }
        $failure | Should Match 'Suspension impossible'
        $failure | Should Match 'needsReview'
        $failure | Should Match 'Profile A'
        $failure | Should Match 'Profile B'
        $failure | Should Match 'Target'
        $script:Requests.Count | Should Be 0
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'SUSPEND_NOT_ALLOWED'
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'needsReview'
    }

    It 'does not attempt to suspend declined or unknown driver states' {
        $script:TestInventories['profile-a'][0].approvalStatus = 'declined'
        $script:TestInventories['profile-b'][0].approvalStatus = 'unexpected'
        { & $watchPath @RunParameters } | Should Throw
        $script:Requests.Count | Should Be 0
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'Status="declined"'
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'Status="unexpected"'
    }

    It 'still suspends an approved driver when a different profile is not suspendable' {
        $script:TestInventories['profile-a'][0].approvalStatus = 'needsReview'
        $script:TestInventories['profile-b'][0].approvalStatus = 'approved'
        { & $watchPath @RunParameters } | Should Throw
        $script:Requests.Count | Should Be 1
        $script:Requests[0].ProfileId | Should Be 'profile-b'
        $script:Requests[0].Body.actionName | Should Be 'suspend'
        $script:TestInventories['profile-b'][0].approvalStatus | Should Be 'suspended'
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'needsReview'
    }

    It 'processes approved drivers in the same profile before reporting unsuspendable matches' {
        $script:TestInventories['profile-a'][0].approvalStatus = 'approved'
        $RunParameters.Remove('DriverId')
        $RunParameters.DriverName = @('Target', 'Other')
        { & $watchPath @RunParameters -ProfileId 'profile-a' } | Should Throw
        $script:Requests.Count | Should Be 1
        @($script:Requests[0].Body.driverIds).Count | Should Be 1
        $script:Requests[0].Body.driverIds[0] | Should Be 'driver-a'
        $script:TestInventories['profile-a'][1].approvalStatus | Should Be 'needsReview'
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'SuspendedNow=1; ProfileErrors=1'
    }

    It 'reports unsupported suspension states in simulation without changing them' {
        $script:TestInventories['profile-a'][0].approvalStatus = 'needsReview'
        { & $watchPath @RunParameters -WhatIf } | Should Throw
        $script:Requests.Count | Should Be 0
        $script:TestInventories['profile-a'][0].approvalStatus | Should Be 'needsReview'
    }

    It 'fails if Graph reports a missing driver' {
        $global:IntuneDriverActionTestState.ResponseMode = 'NotFound'
        { & $watchPath @RunParameters -Action Approve } | Should Throw
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'NotFound="driver-a"'
    }

    It 'fails if approval cannot be verified after the configured attempts' {
        $global:IntuneDriverActionTestState.ResponseMode = 'Unconfirmed'
        { & $watchPath @RunParameters -Action Approve -ProfileId 'profile-a' } | Should Throw
        $global:IntuneDriverActionTestState.InventoryReads | Should Be 3
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'Etat approved non confirme'
    }

    It 'surfaces Graph request errors' {
        $global:IntuneDriverActionTestState.ResponseMode = 'Throw'
        { & $watchPath @RunParameters -Action Approve } | Should Throw
        (Get-Content $RunParameters.LogPath -Raw) | Should Match 'Graph access denied'
    }

    It 'does not report successful approval when no target driver exists' {
        $RunParameters.DriverId = 'absent'
        { & $watchPath @RunParameters -Action Approve } | Should Throw
        $script:Requests.Count | Should Be 0
    }

    It 'does not report successful approval when the profile no longer exists' {
        { & $watchPath @RunParameters -Action Approve -ProfileId 'absent' } | Should Throw
        $script:Requests.Count | Should Be 0
    }

    It 'connects once for a catalog and reuses the context for actions and refreshes' {
        $null = & $catalogPath -Resource Snapshot -AuthenticationMode Interactive -KeepGraphConnection
        & $watchPath @RunParameters -Action Approve -KeepGraphConnection
        $null = & $catalogPath -Resource Snapshot -AuthenticationMode CurrentContext -KeepGraphConnection
        Assert-MockCalled Connect-MgGraph -Times 1 -Exactly -Scope It -ParameterFilter {
            $ContextScope -eq 'Process'
        }
        Assert-MockCalled Disconnect-MgGraph -Times 0 -Exactly -Scope It
    }

    It 'continues to disconnect an independently authenticated standalone script' {
        $RunParameters.AuthenticationMode = 'Interactive'
        & $watchPath @RunParameters
        Assert-MockCalled Connect-MgGraph -Times 1 -Exactly -Scope It
        Assert-MockCalled Disconnect-MgGraph -Times 1 -Exactly -Scope It
    }

    It 'does not silently authenticate again when a reused context has been lost' {
        Mock Get-MgContext { $null }
        { & $watchPath @RunParameters -KeepGraphConnection } | Should Throw
        Assert-MockCalled Connect-MgGraph -Times 0 -Exactly -Scope It
    }

    It 'renews a client-secret token without interactive authentication or losing read-only capabilities' {
        Mock Invoke-RestMethod {
            $payload = @{ roles = @('DeviceManagementConfiguration.Read.All') } | ConvertTo-Json -Compress
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=')
            [pscustomobject] @{ access_token = "e30.$encoded.signature" }
        }
        $secret = ConvertTo-SecureString 'test-secret' -AsPlainText -Force
        $parameters = @{
            Resource = 'Snapshot'; AuthenticationMode = 'ClientSecret'
            TenantId = 'tenant'; ClientId = 'application'; ClientSecret = $secret
            KeepGraphConnection = $true
        }
        $first = & $catalogPath @parameters | ConvertFrom-Json
        $second = & $catalogPath @parameters | ConvertFrom-Json
        $first.capabilities.canWrite | Should Be $false
        $second.capabilities.canWrite | Should Be $false
        Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly -Scope It
        Assert-MockCalled Connect-MgGraph -Times 2 -Exactly -Scope It -ParameterFilter {
            $null -ne $AccessToken
        }
        Assert-MockCalled Disconnect-MgGraph -Times 0 -Exactly -Scope It
    }
}

Describe 'GUI approval targeting and controls' {
    . $guiPath -ValidateOnly -AutomatedTest | Out-Null
    $processTimer.Stop()

    function Wait-TestGuiOperation {
        $timeout = [Diagnostics.Stopwatch]::StartNew()
        while ($null -ne $script:ActiveInvocation -and -not $script:ActiveInvocation.IsCompleted) {
            if ($timeout.Elapsed.TotalSeconds -gt 15) {
                $script:ActivePowerShell.Stop()
                Update-TrackedPowerShell
                throw 'The background operation did not complete within 15 seconds.'
            }
            Start-Sleep -Milliseconds 20
        }
        Update-TrackedPowerShell
    }

    BeforeEach {
        $tenantIdTextBox.Text = ''
        $clientIdTextBox.Text = ''
        $script:IsBusy = $false
        $script:SessionAuthentication = [pscustomobject] @{
            AuthenticationMode = 'Interactive'; TenantId = ''; ClientId = ''
            ClientSecret = $null; CertificateThumbprint = ''; CanWrite = $true
        }
        $script:Profiles = @(
            [pscustomobject] @{ id = 'profile-a'; displayName = 'Profile A'; approvalType = 'manual' },
            [pscustomobject] @{ id = 'profile-b'; displayName = 'Profile B'; approvalType = 'automatic' }
        )
        $script:SelectedProfile = $script:Profiles[0]
        $script:DriverInventories = @{}
        foreach ($profile in $script:Profiles) {
            $script:DriverInventories[$profile.id] = @(
                [pscustomobject] @{
                    id = 'driver-a'; name = 'Target'; version = '1.0'
                    manufacturer = 'Contoso'; approvalStatus = 'suspended'
                }
            )
        }
        $script:SelectedDriver = $script:DriverInventories['profile-a'][0]
        Show-DriverProfileCatalog
        $driverProfilesComboBox.SelectedValue = 'driver-a'
        $useSelectedDriverRadioButton.IsChecked = $true
        $logPathTextBox.Text = Join-Path $TestDrive 'gui.log'
        $taskNameTextBox.Text = ''
        Show-TargetControl
    }

    It 'generates approval commands using exactly one driver ID and the requested scope' {
        $approveProfileButton.IsEnabled | Should Be $true
        $approveAllButton.IsEnabled | Should Be $true
        $configuration = Get-DriverApprovalConfiguration
        $configuration.ProfileIds.Count | Should Be 1
        $configuration.ProfileIds[0] | Should Be 'profile-a'
        $command = Get-WatchCommand -Configuration $configuration -Action Approve
        $command | Should Match '-Action ''Approve'''
        $command | Should Match '-DriverId @\(''driver-a''\)'
        $command | Should Match '-ProfileId @\(''profile-a''\)'
        $command | Should Not Match '-DriverName'
        $all = Get-DriverApprovalConfiguration -AllProfiles
        $all.ProfileIds.Count | Should Be 0
        (Get-WatchCommand -Configuration $all -Action Approve) | Should Not Match '-ProfileId'
    }

    It 'disables approval without write permission and rejects configuration' {
        $script:SessionAuthentication.CanWrite = $false
        Show-TargetControl
        $approveProfileButton.IsEnabled | Should Be $false
        $approveAllButton.IsEnabled | Should Be $false
        { Get-DriverApprovalConfiguration } | Should Throw
    }

    It 'disables approval during an operation' {
        Show-InterfaceBusy -Busy $true
        $approveProfileButton.IsEnabled | Should Be $false
        $approveAllButton.IsEnabled | Should Be $false
    }

    It 'requires a selected driver rather than manual name matching' {
        $useManualDriverRadioButton.IsChecked = $true
        Show-TargetControl
        $approveProfileButton.IsEnabled | Should Be $false
        $approveAllButton.IsEnabled | Should Be $false
        { Get-DriverApprovalConfiguration } | Should Throw
    }

    It 'disables approval when no driver is selected' {
        $script:SelectedDriver = $null
        Show-TargetControl
        $approveProfileButton.IsEnabled | Should Be $false
        $approveAllButton.IsEnabled | Should Be $false
        { Get-DriverApprovalConfiguration } | Should Throw
    }

    It 'rejects missing driver or profile identifiers' {
        $script:SelectedDriver.id = ''
        { Get-DriverApprovalConfiguration } | Should Throw
        $script:SelectedDriver.id = 'driver-a'
        $script:SelectedProfile.id = ''
        { Get-DriverApprovalConfiguration } | Should Throw
    }

    It 'updates only the approved profile in the paused-driver summary' {
        Show-DriverActionResult -Configuration (Get-DriverApprovalConfiguration) -ApprovalStatus approved
        $script:DriverInventories['profile-a'][0].approvalStatus | Should Be 'approved'
        $script:DriverInventories['profile-b'][0].approvalStatus | Should Be 'suspended'
        $rows = @($pausedDriversDataGrid.ItemsSource)
        $rows.Count | Should Be 1
        $rows[0].MissingProfileIds[0] | Should Be 'profile-a'
        $selectedDriverTextBox.Text | Should Match 'approved'
    }

    It 'removes a fully approved driver from the paused-driver summary' {
        $onSuccess = Get-DriverActionCompletion `
            -Configuration (Get-DriverApprovalConfiguration -AllProfiles) -ApprovalStatus approved
        & $onSuccess
        @($pausedDriversDataGrid.ItemsSource).Count | Should Be 0
        $script:DriverInventories['profile-b'][0].approvalStatus | Should Be 'approved'
    }

    It 'places the profile lookup tab immediately after the actions tab' {
        $tabs = $driverProfilesComboBox.Parent.Parent.Parent.Parent
        $tabs.Items[0].Header | Should Be 'Actions sur les drivers'
        $tabs.Items[1].Header | Should Be 'Profils du driver'
        $tabs.Items[2].Header | Should Be 'Suivi des drivers en pause'
    }

    It 'lists all profiles containing a driver with their individual status and approval mode' {
        $script:DriverInventories['profile-b'][0].approvalStatus = 'approved'
        Show-DriverProfiles
        $rows = @($driverProfilesDataGrid.ItemsSource)
        $rows.Count | Should Be 2
        $rows[0].ProfileId | Should Be 'profile-a'
        $rows[0].ApprovalStatus | Should Be 'suspended'
        $rows[0].ApprovalType | Should Be 'manual'
        $rows[1].ProfileId | Should Be 'profile-b'
        $rows[1].ApprovalStatus | Should Be 'approved'
        $rows[1].ApprovalType | Should Be 'automatic'
    }

    It 'deduplicates driver IDs but keeps different IDs with identical names separate' {
        $script:DriverInventories['profile-b'] += [pscustomobject] @{
            id = 'driver-other'; name = 'Target'; version = '1.0'
            manufacturer = 'Contoso'; approvalStatus = 'needsReview'
        }
        Show-DriverProfileCatalog
        $driverProfilesComboBox.Items.Count | Should Be 2
        $driverProfilesComboBox.SelectedValue = 'driver-other'
        $rows = @($driverProfilesDataGrid.ItemsSource)
        $rows.Count | Should Be 1
        $rows[0].ProfileId | Should Be 'profile-b'
        $rows[0].ApprovalStatus | Should Be 'needsReview'
        $driverProfilesComboBox.SelectedItem.Label | Should Match 'driver-other'
        $script:SelectedDriver.id | Should Be 'driver-a'
    }

    It 'returns no profile for an absent driver and ignores profiles without inventory' {
        $script:Profiles += [pscustomobject] @{
            id = 'profile-empty'; displayName = 'Empty'; approvalType = 'manual'
        }
        @(Get-DriverProfileRows -DriverId 'absent' `
            -Profiles $script:Profiles -Inventories $script:DriverInventories).Count | Should Be 0
        @(Get-DriverProfileRows -DriverId 'driver-a' `
            -Profiles $script:Profiles -Inventories $script:DriverInventories).Count | Should Be 2
    }

    It 'displays an unnamed profile using its identifier' {
        $script:Profiles[0].displayName = ''
        $rows = @(Get-DriverProfileRows -DriverId 'driver-a' `
            -Profiles $script:Profiles -Inventories $script:DriverInventories)
        @($rows | Where-Object { $_.ProfileId -eq 'profile-a' })[0].ProfileName | Should Be 'profile-a'
    }

    It 'copies the driver selected in the actions tab to the lookup tab' {
        $driverProfilesComboBox.SelectedIndex = -1
        $driversDataGrid.ItemsSource = @($script:SelectedDriver)
        $driversDataGrid.SelectedIndex = 0
        $driverProfilesComboBox.SelectedValue | Should Be 'driver-a'
        @($driverProfilesDataGrid.ItemsSource).Count | Should Be 2
    }

    It 'allows profile lookup in a read-only session' {
        $script:SessionAuthentication.CanWrite = $false
        Show-AuthenticationControl
        Show-DriverProfiles
        $refreshDriverProfilesButton.IsEnabled | Should Be $true
        @($driverProfilesDataGrid.ItemsSource).Count | Should Be 2
    }

    It 'disables the lookup controls during an operation' {
        Show-InterfaceBusy -Busy $true
        $driverProfilesComboBox.IsEnabled | Should Be $false
        $driverProfilesDataGrid.IsEnabled | Should Be $false
        $refreshDriverProfilesButton.IsEnabled | Should Be $false
        Show-InterfaceBusy -Busy $false
        $driverProfilesComboBox.IsEnabled | Should Be $true
        $refreshDriverProfilesButton.IsEnabled | Should Be $true
    }

    It 'clears profile lookup on disconnection' {
        Clear-AuthenticationSession
        Clear-DriverCatalog
        $driverProfilesComboBox.Items.Count | Should Be 0
        $driverProfilesDataGrid.ItemsSource | Should BeNullOrEmpty
        $driverProfilesStatusTextBlock.Text | Should Match 'Connectez-vous'
        $refreshDriverProfilesButton.IsEnabled | Should Be $false
    }

    It 'handles an empty catalog without retaining the previous results' {
        $script:DriverInventories = @{}
        Show-DriverProfileCatalog
        $driverProfilesComboBox.Items.Count | Should Be 0
        $driverProfilesDataGrid.ItemsSource | Should BeNullOrEmpty
        $driverProfilesStatusTextBlock.Text | Should Match 'Aucun driver'
        @(Get-DriverProfileRows -DriverId 'driver-a' -Profiles @() -Inventories @{}).Count | Should Be 0
    }

    It 'refreshes profile lookup after verified approval and suspension callbacks' {
        $configuration = Get-DriverApprovalConfiguration
        $approve = Get-DriverActionCompletion -Configuration $configuration -ApprovalStatus approved
        & $approve
        @($driverProfilesDataGrid.ItemsSource)[0].ApprovalStatus | Should Be 'approved'
        $suspend = Get-DriverActionCompletion -Configuration $configuration -ApprovalStatus suspended
        & $suspend
        @($driverProfilesDataGrid.ItemsSource)[0].ApprovalStatus | Should Be 'suspended'
        @($driverProfilesDataGrid.ItemsSource)[1].ApprovalStatus | Should Be 'suspended'
        @($pausedDriversDataGrid.ItemsSource)[0].NeedsCompletion | Should Be $false
    }

    It 'reloads the driver lookup from a new catalog snapshot including new profiles' {
        $newProfile = [pscustomobject] @{
            id = 'profile-new'; displayName = 'New Profile'; approvalType = 'manual'
        }
        $catalog = @{
            profiles = @($script:Profiles) + @($newProfile)
            inventories = @(
                @{ profileId = 'profile-a'; value = $script:DriverInventories['profile-a'] },
                @{ profileId = 'profile-b'; value = $script:DriverInventories['profile-b'] },
                @{
                    profileId = 'profile-new'
                    value = @(
                        [pscustomobject] @{
                            id = 'driver-a'; name = 'Target'; version = '1.0'
                            manufacturer = 'Contoso'; approvalStatus = 'needsReview'
                        }
                    )
                }
            )
            capabilities = @{ canWrite = $false }
        }
        Show-CatalogResult -Json ($catalog | ConvertTo-Json -Depth 8)
        $driverProfilesComboBox.Items.Count | Should Be 1
        $rows = @($driverProfilesDataGrid.ItemsSource)
        $rows.Count | Should Be 3
        @($rows | Where-Object { $_.ProfileId -eq 'profile-new' })[0].ApprovalStatus | Should Be 'needsReview'
    }

    It 'uses the existing catalog refresh operation from the new tab' {
        Mock Invoke-CatalogRefresh {}
        $refreshDriverProfilesButton.RaiseEvent(
            (New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))
        )
        Assert-MockCalled Invoke-CatalogRefresh -Times 1 -Exactly -Scope It
    }

    It 'generates persistent Graph commands and uses the current context after login' {
        $authentication = Get-SessionAuthentication
        $initial = Get-CatalogCommand -Resource Snapshot -Authentication $authentication
        $refresh = Get-CatalogCommand -Resource Snapshot -Authentication $authentication -UseCurrentContext
        $action = Get-WatchCommand -Configuration (Get-DriverApprovalConfiguration) -Action Approve
        $initial | Should Match '-AuthenticationMode ''Interactive'''
        $refresh | Should Match '-AuthenticationMode ''CurrentContext'''
        $action | Should Match '-AuthenticationMode ''CurrentContext'''
        foreach ($command in @($initial, $refresh, $action)) {
            $command | Should Match '-KeepGraphConnection'
        }
    }

    It 'keeps the same background runspace and thread between operations' {
        try {
            Invoke-TrackedPowerShell -Command '$global:GuiTestCounter = 41; [Threading.Thread]::CurrentThread.ManagedThreadId' `
                -Activity 'Test' -SuccessMessage 'First operation completed'
            Wait-TestGuiOperation
            $worker = $script:GraphRunspace
            $firstThread = $outputTextBox.Text.Trim()
            Invoke-TrackedPowerShell -Command '$global:GuiTestCounter++; [Threading.Thread]::CurrentThread.ManagedThreadId' `
                -Activity 'Test' -SuccessMessage 'Second operation completed'
            Wait-TestGuiOperation
            [object]::ReferenceEquals($worker, $script:GraphRunspace) | Should Be $true
            $outputTextBox.Text.Trim() | Should Be $firstThread
            $script:GraphRunspace.SessionStateProxy.GetVariable('GuiTestCounter') | Should Be 42
            $script:ActiveProcess | Should BeNullOrEmpty
            $script:ActivePowerShell | Should BeNullOrEmpty
            $script:IsBusy | Should Be $false
            Test-Path -LiteralPath $script:StandardOutputPath | Should Be $false
        }
        finally {
            Close-GraphRunspace
        }
    }

    It 'surfaces a background error and permits the next operation on the same session' {
        try {
            $script:LastGuiError = $null
            Invoke-TrackedPowerShell -Command 'throw "mock Graph request failed"' `
                -Activity 'Test' -SuccessMessage 'Must not succeed'
            Wait-TestGuiOperation
            $worker = $script:GraphRunspace
            $script:LastGuiError | Should Match 'mock Graph request failed'
            $script:IsBusy | Should Be $false
            Invoke-TrackedPowerShell -Command '"next request succeeded"' `
                -Activity 'Test' -SuccessMessage 'Success'
            Wait-TestGuiOperation
            [object]::ReferenceEquals($worker, $script:GraphRunspace) | Should Be $true
            $outputTextBox.Text | Should Match 'next request succeeded'
        }
        finally {
            Close-GraphRunspace
        }
    }

    It 'loads catalog JSON without mixing Graph information and warnings into the result' {
        $received = New-Object 'Collections.Generic.List[string]'
        $showCatalog = Get-Command Show-CatalogResult -CommandType Function
        $onSuccess = {
            param($json)
            $received.Add($json)
            & $showCatalog -Json $json
        }.GetNewClosure()
        $script:LastGuiError = $null
        $script:PendingAuthenticationSession = $script:SessionAuthentication
        $script:SessionAuthentication = $null
        try {
            Invoke-TrackedPowerShell -Command @'
Write-Host 'NOTICE: Graph connection information'
Write-Warning 'Graph connection warning'
Write-Information 'Graph information stream' -InformationAction Continue
Write-Verbose 'Graph verbose stream' -Verbose
[ordered] @{
    profiles = @(@{ id = 'profile-a'; displayName = 'Profile A'; approvalType = 'manual' })
    inventories = @(@{
        profileId = 'profile-a'
        value = @(@{
            id = 'driver-a'; name = 'Target'; version = '1.0'
            manufacturer = 'Contoso'; approvalStatus = 'approved'
        })
    })
    capabilities = @{ canWrite = $true }
} | ConvertTo-Json -Depth 8 -Compress
'@ -Activity 'Loading catalog' -SuccessMessage 'Catalog loaded' -SuppressOutput -OnSuccess $onSuccess
            Wait-TestGuiOperation
            $script:LastGuiError | Should BeNullOrEmpty
            $received.Count | Should Be 1
            $received[0].TrimStart().StartsWith('{') | Should Be $true
            $received[0] | Should Not Match 'NOTICE|connection warning|information stream|verbose stream'
            $script:Profiles.Count | Should Be 1
            $driverProfilesComboBox.Items.Count | Should Be 1
            $script:SessionAuthentication | Should Not BeNullOrEmpty
            $outputTextBox.Text | Should Match 'NOTICE: Graph connection information'
            $outputTextBox.Text | Should Match 'Graph connection warning'
            $outputTextBox.Text | Should Match 'Graph information stream'
            $outputTextBox.Text | Should Match 'Graph verbose stream'
        }
        finally {
            Close-GraphRunspace
        }
    }

    It 'locks authentication during an operation and refuses concurrent operations' {
        try {
            Invoke-TrackedPowerShell -Command 'Start-Sleep -Milliseconds 200' `
                -Activity 'Test' -SuccessMessage 'Success'
            $authenticationModeComboBox.IsEnabled | Should Be $false
            $tenantIdTextBox.IsEnabled | Should Be $false
            $clientSecretPasswordBox.IsEnabled | Should Be $false
            { Invoke-TrackedPowerShell -Command '"concurrent"' -Activity 'Test' -SuccessMessage 'No' } | Should Throw
            { Close-GraphRunspace } | Should Throw
            Wait-TestGuiOperation
            $authenticationModeComboBox.IsEnabled | Should Be $true
        }
        finally {
            Wait-TestGuiOperation
            Close-GraphRunspace
        }
    }

    It 'keeps host logs and warnings visible for a failed driver operation' {
        $script:LastGuiError = $null
        try {
            Invoke-TrackedPowerShell `
                -Command 'Write-Host "APPROVE_REQUEST"; Write-Warning "Verification delayed"; throw "Approval verification failed"' `
                -Activity 'Test' -SuccessMessage 'Must not succeed'
            Wait-TestGuiOperation
            $script:LastGuiError | Should Match 'Approval verification failed'
            $outputTextBox.Text | Should Match 'APPROVE_REQUEST'
            $outputTextBox.Text | Should Match 'Verification delayed'
            $outputTextBox.Text | Should Match 'Approval verification failed'
        }
        finally {
            Close-GraphRunspace
        }
    }

    It 'still reports malformed catalog data instead of hiding a JSON error' {
        $showCatalog = Get-Command Show-CatalogResult -CommandType Function
        $onSuccess = {
            param($json)
            & $showCatalog -Json $json
        }.GetNewClosure()
        $script:LastGuiError = $null
        try {
            Invoke-TrackedPowerShell -Command 'Write-Host "Connection diagnostic"; "{invalid-json"' `
                -Activity 'Loading catalog' -SuccessMessage 'Must not succeed' -SuppressOutput -OnSuccess $onSuccess
            Wait-TestGuiOperation
            $script:LastGuiError | Should Not BeNullOrEmpty
            $statusTextBlock.Text | Should Not Be 'Must not succeed'
            $connectionStatusTextBlock.Text | Should Match 'catalogue'
            $outputTextBox.Text | Should Match 'Connection diagnostic'
            $script:IsBusy | Should Be $false
        }
        finally {
            Close-GraphRunspace
        }
    }

    It 'transfers the secret as a SecureString without changing the environment or logging it' {
        $oldEnvironment = [Environment]::GetEnvironmentVariable('INTUNE_DRIVER_PAUSE_CLIENT_SECRET')
        try {
            Invoke-TrackedPowerShell `
                -Command 'if ($GuiClientSecret -isnot [securestring]) { throw "Missing secure argument" }; "secure argument received"' `
                -ClientSecret 'test-sensitive-value' -Activity 'Test' -SuccessMessage 'Success'
            Wait-TestGuiOperation
            $outputTextBox.Text | Should Match 'secure argument received'
            $outputTextBox.Text | Should Not Match 'test-sensitive-value'
            [object]::Equals($oldEnvironment,
                [Environment]::GetEnvironmentVariable('INTUNE_DRIVER_PAUSE_CLIENT_SECRET')) | Should Be $true
            $script:GraphRunspace.SessionStateProxy.GetVariable('GuiClientSecret') | Should BeNullOrEmpty
        }
        finally {
            Close-GraphRunspace
        }
    }

    It 'disconnects Graph and releases the runspace when authentication is cleared' {
        $events = New-Object 'Collections.Concurrent.ConcurrentQueue[string]'
        try {
            $worker = Get-GraphRunspace
            $worker.SessionStateProxy.SetVariable('GuiTestEvents', $events)
            Invoke-TrackedPowerShell -Command @'
function global:Get-MgContext { [pscustomobject] @{ TenantId = 'test' } }
function global:Disconnect-MgGraph {
    [CmdletBinding()]
    param()
    $global:GuiTestEvents.Enqueue('disconnected')
}
'@ -Activity 'Test' -SuccessMessage 'Success'
            Wait-TestGuiOperation
            Clear-AuthenticationSession
            $events.Count | Should Be 1
            $events.ToArray()[0] | Should Be 'disconnected'
            $script:GraphRunspace | Should BeNullOrEmpty
            $script:SessionAuthentication | Should BeNullOrEmpty
            $newWorker = Get-GraphRunspace
            [object]::ReferenceEquals($worker, $newWorker) | Should Be $false
        }
        finally {
            Close-GraphRunspace
        }
    }

    It 'refreshes rather than reauthenticates when the connect button is used with an active session' {
        Mock Invoke-CatalogRefresh {}
        $loadProfilesButton.RaiseEvent(
            (New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))
        )
        Assert-MockCalled Invoke-CatalogRefresh -Times 1 -Exactly -Scope It
    }

    It 'provides offline help covering prerequisites, permissions, scope and troubleshooting without app versioning' {
        $helpTab = $window.FindName('HelpTabItem')
        $helpTab.Header | Should Be 'Aide'
        $sections = @($window.FindName('HelpContentPanel').Children |
            Where-Object { $_ -is [Windows.Controls.GroupBox] })
        $sections.Count | Should Be 9
        $text = foreach ($section in $sections) {
            $section.Header
            if ($section.Content -is [Windows.Controls.TextBlock]) {
                $section.Content.Text
            }
            else {
                $section.Content.Children | ForEach-Object { $_.Text }
            }
        }
        $text = $text -join ' '
        $text | Should Match 'DeviceManagementConfiguration.ReadWrite.All'
        $text | Should Match 'LocalMachine'
        $text | Should Match 'Simuler'
        $text | Should Match 'Approbation|Approuver'
        $text | Should Match 't.che horaire|tache horaire'
        $text | Should Match 'SecureString'
        $text | Should Not Match 'Version de l.application|v[0-9]+\.[0-9]+'
    }
}
