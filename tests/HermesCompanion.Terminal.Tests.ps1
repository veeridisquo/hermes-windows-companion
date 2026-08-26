Describe 'Hermes Companion terminal launch' {
    BeforeAll {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'HermesCompanion.ps1'
        . $scriptPath -ParsersOnly
    }

    It 'uses Windows PowerShell when Windows Terminal is unavailable' {
        $previousLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $TestDrive
            $launch = Get-TerminalLaunch 'Hermes - iris' 'C:\Temp\HermesCompanion-iris-session.ps1'
        }
        finally {
            $env:LOCALAPPDATA = $previousLocalAppData
        }

        $launch.FilePath | Should -Match '(?i)\\powershell\.exe$'
        $launch.Arguments | Should -Match '(?i)-NoExit'
        $launch.Arguments | Should -Match 'HermesCompanion-iris-session\.ps1'
        $launch.Arguments | Should -Not -Match '(?i)\bcmd(?:\.exe)?\b'
    }

    It 'uses Windows PowerShell inside Windows Terminal when it is available' {
        $previousLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $TestDrive
            $windowsApps = Join-Path $TestDrive 'Microsoft\WindowsApps'
            New-Item -ItemType Directory -Path $windowsApps -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $windowsApps 'wt.exe') -Force | Out-Null

            $launch = Get-TerminalLaunch 'Hermes - iris' 'C:\Temp\HermesCompanion-iris-session.ps1'
        }
        finally {
            $env:LOCALAPPDATA = $previousLocalAppData
        }

        $launch.FilePath | Should -Match '(?i)\\wt\.exe$'
        $launch.Arguments | Should -Match '(?i)\\powershell\.exe'
        $launch.Arguments | Should -Match '(?i)-NoExit'
        $launch.Arguments | Should -Match 'HermesCompanion-iris-session\.ps1'
        $launch.Arguments | Should -Not -Match '(?i)\bcmd(?:\.exe)?\b'
    }

    It 'escapes profile names as PowerShell string literals' {
        ConvertTo-PowerShellLiteral "daniel's profile" | Should -Be "'daniel''s profile'"
    }

    It 'writes a PowerShell launcher for the selected profile' {
        $previousTemp = $env:TEMP
        $previousHermesPath = $script:HermesPath
        try {
            $env:TEMP = $TestDrive
            $script:HermesPath = 'C:\Program Files\Hermes\hermes.exe'
            Mock Start-Process { }

            Open-HermesTerminal -Title "Hermes - daniel's profile" -ScriptName 'profile-session' -Arguments @('-p', "daniel's profile")

            $launcherPath = Join-Path $TestDrive 'HermesCompanion-profile-session.ps1'
            $launcherPath | Should -Exist
            $launcher = Get-Content -LiteralPath $launcherPath -Raw
            $expectedTitleLine = '$Host.UI.RawUI.WindowTitle = ' + "'Hermes - daniel''s profile'"
            $launcher | Should -Match ([regex]::Escape($expectedTitleLine))
            $launcher | Should -Match "(?m)^& 'C:\\Program Files\\Hermes\\hermes\.exe' '-p' 'daniel''s profile'"
            (Join-Path $TestDrive 'HermesCompanion-profile-session.cmd') | Should -Not -Exist
            Should -Invoke Start-Process -Exactly 1
        }
        finally {
            $script:HermesPath = $previousHermesPath
            $env:TEMP = $previousTemp
        }
    }
}
