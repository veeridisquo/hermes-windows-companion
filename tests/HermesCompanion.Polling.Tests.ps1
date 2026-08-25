Describe 'Hermes Companion polling scheduler' {
    BeforeAll {
        $script:CompanionScriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'HermesCompanion.ps1'
    }

    It 'continues scheduling after update progress has no work' {
        $probePath = Join-Path $TestDrive 'PollingProbe.ps1'
        $escapedCompanionPath = $script:CompanionScriptPath.Replace("'", "''")
        @"
Add-Type -AssemblyName System.Windows.Forms
. '$escapedCompanionPath' -ParsersOnly
`$script:VersionCheckReached = `$false
function Request-VersionCheck { `$script:VersionCheckReached = `$true }
`$context = New-Object System.Windows.Forms.ApplicationContext
`$pollTimer = New-Object System.Windows.Forms.Timer
`$pollTimer.Interval = 25
`$pollTimer.add_Tick({
    try { Invoke-PollTick }
    finally { `$context.ExitThread() }
}.GetNewClosure())
`$guardTimer = New-Object System.Windows.Forms.Timer
`$guardTimer.Interval = 500
`$guardTimer.add_Tick({ `$context.ExitThread() }.GetNewClosure())
try {
    `$pollTimer.Start()
    `$guardTimer.Start()
    [System.Windows.Forms.Application]::Run(`$context)
}
finally {
    `$pollTimer.Dispose()
    `$guardTimer.Dispose()
    `$context.Dispose()
}
if (`$script:VersionCheckReached) { Write-Output 'SCHEDULED'; exit 0 }
exit 1
"@ | Set-Content -LiteralPath $probePath -Encoding UTF8

        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -ExecutionPolicy Bypass -File $probePath

        $LASTEXITCODE | Should -Be 0
        $output | Should -Contain 'SCHEDULED'
    }
}
