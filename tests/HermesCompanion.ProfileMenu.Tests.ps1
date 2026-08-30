Describe 'Hermes Companion profile menu' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'HermesCompanion.ps1'
        $script:FixtureDirectory = Join-Path $PSScriptRoot 'fixtures'
        . $scriptPath -ParsersOnly
    }

    AfterEach {
        if ($script:ProfilesMenu) {
            $script:ProfilesMenu.Dispose()
        }
    }

    It 'publishes a deferred profile refresh when the open menu closes' {
        $script:ProfilesMenu = New-ProfileMenu
        $script:Profiles = @()
        Update-ProfileMenu

        $script:Profiles = @([pscustomobject]@{
            Name = 'probe'
            IsActive = $true
            GatewayRunning = $false
            GatewayInstalled = $true
        })
        $script:ProfilesMenu.DropDown.Show((New-Object System.Drawing.Point -10000, -10000))
        Update-ProfileMenu
        $script:ProfilesMenu.DropDown.Close()
        Complete-DeferredProfileMenuRefresh

        @($script:ProfilesMenu.DropDownItems).Count | Should -Be 1
        $script:ProfilesMenu.DropDownItems[0].Text | Should -Be 'probe (active, gateway stopped)'
    }

    It 'does not dispose a profile submenu inside the drop-down close event' {
        $script:ProfilesMenu = New-ProfileMenu
        $script:Profiles = @([pscustomobject]@{
            Name = 'old-profile'
            IsActive = $true
            GatewayRunning = $false
            GatewayInstalled = $true
        })
        Update-ProfileMenu
        $previousProfileDropDown = $script:ProfilesMenu.DropDownItems[0].DropDown

        $script:ProfilesMenu.DropDown.Show((New-Object System.Drawing.Point -10000, -10000))
        $script:Profiles = @([pscustomobject]@{
            Name = 'new-profile'
            IsActive = $true
            GatewayRunning = $false
            GatewayInstalled = $true
        })
        Update-ProfileMenu
        $script:ProfilesMenu.DropDown.Close()

        $previousProfileDropDown.IsDisposed | Should -BeFalse
        Complete-DeferredProfileMenuRefresh
        $previousProfileDropDown.IsDisposed | Should -BeTrue
        $script:ProfilesMenu.DropDownItems[0].Text | Should -Be 'new-profile (active, gateway stopped)'
    }

    It 'publishes profiles when the asynchronous profile-list command completes' {
        $script:ProfilesMenu = New-ProfileMenu
        $script:Profiles = @()
        $script:HermesPath = $null
        $script:ProfileRefreshPending = $true
        $profileListOutput = Get-Content -LiteralPath (Join-Path $script:FixtureDirectory 'profile-list.txt') -Raw -Encoding UTF8

        Complete-ProfileRefresh ([pscustomobject]@{
            ExitCode = 0
            Output = $profileListOutput
            Error = ''
        })

        @($script:ProfilesMenu.DropDownItems).Count | Should -Be 2
        $script:ProfilesMenu.DropDownItems[0].Text | Should -Be 'long-profile-name (gateway checking)'
        $script:ProfilesMenu.DropDownItems[1].Text | Should -Be 'personal (gateway checking)'
        $script:ProfileRefreshPending | Should -Be $false
    }

    It 'shows only custom profiles' {
        $script:ProfilesMenu = New-ProfileMenu
        $script:Profiles = @(
            [pscustomobject]@{
                Name = 'default'
                IsActive = $true
                GatewayRunning = $true
                GatewayInstalled = $true
            },
            [pscustomobject]@{
                Name = 'work'
                IsActive = $false
                GatewayRunning = $false
                GatewayInstalled = $true
            }
        )

        Update-ProfileMenu

        @($script:ProfilesMenu.DropDownItems).Count | Should -Be 1
        $script:ProfilesMenu.DropDownItems[0].Text | Should -Be 'work (gateway stopped)'
    }

    It 'publishes the gateway installation state from the asynchronous status command' {
        $script:ProfilesMenu = New-ProfileMenu
        $script:HermesPath = $null
        $script:ProfileRefreshGeneration = 7
        $script:ProfileGatewayInstallationRefreshInProgress = $true
        $script:ProfileGatewayInstallationRefreshGeneration = 7
        $hermesProfile = [pscustomobject]@{
            Name = 'hebe'
            IsActive = $false
            GatewayRunning = $false
            GatewayInstalled = $null
        }
        $script:Profiles = @($hermesProfile)

        Complete-ProfileGatewayInstallationRefresh -Result ([pscustomobject]@{
            ExitCode = 0
            Output = 'Scheduled Task registered'
            Error = ''
        }) -HermesProfile $hermesProfile -NextIndex 1 -Generation 7

        $hermesProfile.GatewayInstalled | Should -BeTrue
        $script:ProfilesMenu.DropDownItems[0].Text | Should -Be 'hebe (gateway stopped)'
        $script:ProfileGatewayInstallationRefreshInProgress | Should -BeFalse
    }
}
