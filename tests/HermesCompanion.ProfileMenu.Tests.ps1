Describe 'Hermes Companion profile menu' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'HermesCompanion.ps1'
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

        @($script:ProfilesMenu.DropDownItems).Count | Should -Be 1
        $script:ProfilesMenu.DropDownItems[0].Text | Should -Be 'probe (active, gateway stopped)'
    }
}
