Describe 'Hermes Companion CLI output parsers' {
    BeforeAll {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'HermesCompanion.ps1'
        $fixtureDirectory = Join-Path $PSScriptRoot 'fixtures'

        . $scriptPath -ParsersOnly
    }

    Context 'parser-only loading' {
        It 'defines each parser without constructing the tray application' {
            Get-Command Read-ProfileList -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command Read-UpdateStatus -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command Read-VersionOutput -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command Get-ProfileGatewayInstalledState -CommandType Function | Should -Not -BeNullOrEmpty
            Get-Command Get-UpdateProgressLine -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    Context 'profile list output' {
        It 'returns every profile, including long IDs and display-named profiles' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'profile-list.txt') -Raw -Encoding UTF8
            $profiles = @(Read-ProfileList $output)

            $profiles.Count | Should -Be 3
            $profiles.Name | Should -Contain 'long-profile-name'
            $profiles.Name | Should -Contain 'personal'
        }

        It 'uses the canonical ID rather than the display label' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'profile-list.txt') -Raw -Encoding UTF8
            $matched = @(Read-ProfileList $output | Where-Object { $_.Name -eq 'personal' })

            $matched.Count | Should -Be 1
            $matched[0].Name | Should -Be 'personal'
        }

        It 'marks only the active profile and skips table decorations' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'profile-list.txt') -Raw -Encoding UTF8
            $profiles = @(Read-ProfileList $output)
            $active = @($profiles | Where-Object { $_.IsActive })

            $active.Count | Should -Be 1
            $active[0].Name | Should -Be 'default'
            $profiles.Name | Should -Not -Contain 'Profile'
        }
    }

    Context 'gateway status output' {
        It 'recognises a registered Windows Scheduled Task' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'gateway-installed.txt') -Raw -Encoding UTF8

            Get-ProfileGatewayInstalledState $output | Should -BeTrue
        }

        It 'reports no installation when Hermes reports no gateway service' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'gateway-not-installed.txt') -Raw -Encoding UTF8

            Get-ProfileGatewayInstalledState $output | Should -BeFalse
        }

        It 'reports no installation when a gateway is running manually' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'gateway-manual.txt') -Raw -Encoding UTF8

            Get-ProfileGatewayInstalledState $output | Should -BeFalse
        }
    }

    Context 'version output' {
        It 'extracts version and installation details from the basic banner' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'version-up-to-date.txt') -Raw -Encoding UTF8

            Read-VersionOutput $output

            $script:HermesVersion | Should -Be '0.20.5'
            $script:HermesInstallDirectory | Should -Be 'C:\Users\Daniel\hermes-agent'
            $script:HermesInstallMethod | Should -Be 'git'
        }

        It 'extracts version and installation details from the upstream banner' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'version-update-available.txt') -Raw -Encoding UTF8

            Read-VersionOutput $output

            $script:HermesVersion | Should -Be '0.20.5'
            $script:HermesInstallDirectory | Should -Be 'C:\Users\Daniel\hermes-agent'
            $script:HermesInstallMethod | Should -Be 'git'
        }
    }

    Context 'update output' {
        It 'reports zero commits behind when Hermes is up to date' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'update-check-up-to-date.txt') -Raw -Encoding UTF8

            Read-UpdateStatus $output | Should -BeTrue
            $script:UpdateBehind | Should -Be 0
        }

        It 'reports an unspecified available update and its command' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'version-update-available.txt') -Raw -Encoding UTF8

            Read-UpdateStatus $output | Should -BeTrue
            $script:UpdateBehind | Should -Be -1
            $script:RecommendedUpdateCommand | Should -Be 'hermes update'
        }

        It 'reports the commit distance and recommended command' {
            $output = Get-Content -LiteralPath (Join-Path $fixtureDirectory 'update-check-available.txt') -Raw -Encoding UTF8

            Read-UpdateStatus $output | Should -BeTrue
            $script:UpdateBehind | Should -Be 3
            $script:RecommendedUpdateCommand | Should -Be 'hermes update'
        }
    }
}
