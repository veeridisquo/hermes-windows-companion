Describe 'Hermes Companion native command execution' {
    BeforeAll {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'HermesCompanion.ps1'

        . $scriptPath -ParsersOnly
    }

    BeforeEach {
        $script:HermesPath = (Get-Process -Id $PID).Path
        $script:ActiveOperation = $null
        $script:UpdateInProgress = $false
        $script:CapturedOperationResult = $null
        $script:CapturedOperationContext = $null
    }

    It 'drains both output streams without crashing the PowerShell host' {
        $started = Start-HermesOperation -Arguments @(
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            '1..3000 | ForEach-Object { [Console]::Out.WriteLine(("stdout-{0:D4}-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" -f $_)); [Console]::Error.WriteLine(("stderr-{0:D4}-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" -f $_)) }'
        ) -Context ([pscustomobject]@{ Request = 'high-volume-probe' }) -OnComplete {
            param($result, $context)
            $script:CapturedOperationResult = $result
            $script:CapturedOperationContext = $context
        }

        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ($script:ActiveOperation -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
            Complete-ActiveOperation
        }

        $started | Should -Be $true
        $script:ActiveOperation | Should -BeNullOrEmpty
        $script:CapturedOperationResult.ExitCode | Should -Be 0
        $script:CapturedOperationContext.Request | Should -Be 'high-volume-probe'

        $outputLines = @($script:CapturedOperationResult.Output -split "`r?`n")
        $errorLines = @($script:CapturedOperationResult.Error -split "`r?`n")
        $outputLines.Count | Should -Be 3000
        $errorLines.Count | Should -Be 3000
        $outputLines[0] | Should -Be 'stdout-0001-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        $outputLines[-1] | Should -Be 'stdout-3000-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        $errorLines[0] | Should -Be 'stderr-0001-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        $errorLines[-1] | Should -Be 'stderr-3000-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
    }
}
