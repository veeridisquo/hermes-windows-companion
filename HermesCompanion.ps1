[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class HermesCompanionNativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppName = 'Hermes Companion'
$script:DashboardUrl = 'http://127.0.0.1:9119'
$script:LogsPath = Join-Path $env:LOCALAPPDATA 'hermes\logs'
$script:IconPath = Join-Path $PSScriptRoot 'hermes-agent.ico'
$script:IconImagePath = Join-Path $PSScriptRoot 'hermes-agent.png'
$script:StartupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hermes Companion.lnk'
$script:HermesPath = $null
$script:ActiveOperation = $null
$script:RefreshPending = $false
$script:GatewayRunning = $false
$script:DashboardRunning = $false
$script:LastError = $null
$script:HermesVersion = $null
$script:UpdateBehind = $null
$script:UpdateNotified = $false
$script:VersionCheckPending = $true
$script:UpdateInProgress = $false
$script:UpdateOperation = $null

function Show-CompanionError {
    param([string]$Message)

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Find-HermesExecutable {
    $command = Get-Command hermes.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        $command = Get-Command hermes -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($command) {
        return $command.Source
    }

    return $null
}

function ConvertTo-NativeArgument {
    param([string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function New-HermesProcessStartInfo {
    param(
        [string[]]$Arguments,
        [switch]$RedirectOutput
    )

    if (-not $script:HermesPath) {
        $script:HermesPath = Find-HermesExecutable
    }
    if (-not $script:HermesPath) {
        throw 'Hermes was not found on PATH.'
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:HermesPath
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')

    if ($RedirectOutput) {
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # Hermes is a Python program. Force UTF-8 on both sides so the status
        # and version text parses the same way on every Windows code page.
        $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
        $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }

    return $info
}

function Start-HermesDetached {
    param([string[]]$Arguments)

    try {
        $info = New-HermesProcessStartInfo -Arguments $Arguments
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) {
            throw 'The Hermes process did not start.'
        }
        $process.Dispose()
        return $true
    }
    catch {
        Show-CompanionError $_.Exception.Message
        return $false
    }
}

function Start-HermesOperation {
    param(
        [string[]]$Arguments,
        [scriptblock]$OnComplete,
        [int]$TimeoutSeconds = 30,
        [switch]$QuietWhenBusy
    )

    if ($script:ActiveOperation) {
        if (-not $QuietWhenBusy) {
            Show-Notification 'Hermes is already handling another request.' 'Please wait a moment and try again.'
        }
        return $false
    }

    try {
        $info = New-HermesProcessStartInfo -Arguments $Arguments -RedirectOutput
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) {
            throw 'The Hermes process did not start.'
        }

        $script:ActiveOperation = [pscustomobject]@{
            Process = $process
            Arguments = $Arguments
            OnComplete = $OnComplete
            StartedAt = [DateTime]::UtcNow
            TimeoutSeconds = $TimeoutSeconds
        }
        return $true
    }
    catch {
        $script:LastError = $_.Exception.Message
        Update-TrayDisplay
        if (-not $QuietWhenBusy) {
            Show-CompanionError $_.Exception.Message
        }
        return $false
    }
}

function Complete-ActiveOperation {
    $operation = $script:ActiveOperation
    if (-not $operation) {
        return
    }

    $timedOut = ([DateTime]::UtcNow - $operation.StartedAt).TotalSeconds -gt $operation.TimeoutSeconds
    if (-not $operation.Process.HasExited -and -not $timedOut) {
        return
    }

    if ($timedOut -and -not $operation.Process.HasExited) {
        try { $operation.Process.Kill() } catch {}
        $result = [pscustomobject]@{
            ExitCode = -1
            Output = ''
            Error = 'The Hermes command timed out.'
        }
    }
    else {
        $output = $operation.Process.StandardOutput.ReadToEnd()
        $errorOutput = $operation.Process.StandardError.ReadToEnd()
        $result = [pscustomobject]@{
            ExitCode = $operation.Process.ExitCode
            Output = $output.Trim()
            Error = $errorOutput.Trim()
        }
    }

    $operation.Process.Dispose()
    $script:ActiveOperation = $null

    try {
        & $operation.OnComplete $result
    }
    catch {
        $script:LastError = $_.Exception.Message
        Update-TrayDisplay
    }
}

function New-TrayIcon {
    param([switch]$Muted)

    $bitmap = New-Object System.Drawing.Bitmap 16, 16
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $baseImage = $null
    if (Test-Path -LiteralPath $script:IconImagePath) {
        $baseImage = [System.Drawing.Image]::FromFile($script:IconImagePath)
        $graphics.DrawImage($baseImage, 0, 0, 16, 16)
    }
    else {
        $fallbackColor = if ($Muted) { [System.Drawing.Color]::Gray } else { [System.Drawing.Color]::White }
        $brush = New-Object System.Drawing.SolidBrush $fallbackColor
        $graphics.FillEllipse($brush, 2, 2, 11, 11)
        $brush.Dispose()
    }

    if ($baseImage) { $baseImage.Dispose() }
    $graphics.Dispose()

    if ($Muted) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) {
            for ($y = 0; $y -lt $bitmap.Height; $y++) {
                $pixel = $bitmap.GetPixel($x, $y)
                if ($pixel.A -gt 0) {
                    $gray = [int][Math]::Round((($pixel.R + $pixel.G + $pixel.B) / 3) * 0.55)
                    $alpha = [int][Math]::Round($pixel.A * 0.55)
                    $bitmap.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($alpha, $gray, $gray, $gray))
                }
            }
        }
    }

    $handle = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($handle).Clone()
    [HermesCompanionNativeMethods]::DestroyIcon($handle) | Out-Null
    $bitmap.Dispose()
    return $icon
}

$script:ActiveIcon = New-TrayIcon
$script:MutedIcon = New-TrayIcon -Muted

function Show-Notification {
    param(
        [string]$Title,
        [string]$Text
    )

    $script:TrayIcon.BalloonTipTitle = $Title
    $script:TrayIcon.BalloonTipText = $Text
    $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $script:TrayIcon.ShowBalloonTip(2500)
}

function Set-HermesMenuEnabled {
    param([bool]$Enabled)

    $script:OpenDashboardItem.Enabled = $Enabled
    $script:DesktopItem.Enabled = $Enabled
    $script:StartDashboardItem.Enabled = $Enabled
    $script:StopDashboardItem.Enabled = $Enabled
    $script:GatewayStatusItem.Enabled = $Enabled
    $script:GatewayStartItem.Enabled = $Enabled
    $script:GatewayStopItem.Enabled = $Enabled
    $script:GatewayRestartItem.Enabled = $Enabled
    $script:CheckUpdateItem.Enabled = $Enabled
    $script:UpdateHermesItem.Enabled = $Enabled
}

function Update-TrayDisplay {
    $script:VersionSummaryItem.Text = Get-VersionSummaryText

    if ($script:UpdateInProgress) {
        # Any Hermes command started now would trip the concurrent-process
        # guard in 'hermes update', so no Hermes action stays available.
        $script:TrayIcon.Icon = $script:ActiveIcon
        $script:TrayIcon.Text = 'Hermes Companion - updating Hermes'
        $script:GatewaySummaryItem.Text = 'Gateway: paused for update'
        $script:DashboardSummaryItem.Text = 'Dashboard: paused for update'
        Set-HermesMenuEnabled $false
        return
    }

    if (-not $script:HermesPath -or $script:LastError) {
        $script:TrayIcon.Icon = $script:MutedIcon
        $script:TrayIcon.Text = 'Hermes Companion - unavailable'
        $script:GatewaySummaryItem.Text = 'Gateway: unavailable'
        $script:DashboardSummaryItem.Text = 'Dashboard: unknown'
        Set-HermesMenuEnabled $false
        return
    }

    if ($script:GatewayRunning -or $script:DashboardRunning) {
        $script:TrayIcon.Icon = $script:ActiveIcon
        $script:TrayIcon.Text = 'Hermes Companion - active'
    }
    else {
        $script:TrayIcon.Icon = $script:MutedIcon
        $script:TrayIcon.Text = 'Hermes Companion - all services stopped'
    }

    if (Test-UpdateAvailable) {
        $script:TrayIcon.Text += ' - update available'
    }

    $gatewayText = if ($script:GatewayRunning) { 'running' } else { 'stopped' }
    $dashboardText = if ($script:DashboardRunning) { 'running' } else { 'stopped' }
    $script:GatewaySummaryItem.Text = "Gateway: $gatewayText"
    $script:DashboardSummaryItem.Text = "Dashboard: $dashboardText"
    $script:OpenDashboardItem.Enabled = $true
    $script:DesktopItem.Enabled = $true
    $script:StartDashboardItem.Enabled = -not $script:DashboardRunning
    $script:StopDashboardItem.Enabled = $script:DashboardRunning
    $script:GatewayStatusItem.Enabled = $true
    $script:GatewayStartItem.Enabled = -not $script:GatewayRunning
    $script:GatewayStopItem.Enabled = $script:GatewayRunning
    $script:GatewayRestartItem.Enabled = $script:GatewayRunning
    $script:CheckUpdateItem.Enabled = $true
    $script:UpdateHermesItem.Enabled = $true
}

function Test-DashboardEndpoint {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connection = $client.ConnectAsync('127.0.0.1', 9119)
        if (-not $connection.Wait(500)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Stop-VerifiedDashboardListener {
    # Hermes v0.20.x can occasionally lose track of a dashboard it launched.
    # Only stop the loopback:9119 owner when its command line verifies that it
    # is the Hermes dashboard, and only after the user explicitly chose Stop.
    try {
        $connections = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 9119 -State Listen -ErrorAction Stop
        foreach ($processId in ($connections.OwningProcess | Select-Object -Unique)) {
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
            if ($processInfo.CommandLine -match '(?i)hermes\.exe"?\s+dashboard(?:\s|$)') {
                Stop-Process -Id $processId -Force -ErrorAction Stop
            }
        }
    }
    catch {
        return $false
    }

    Start-Sleep -Milliseconds 300
    return -not (Test-DashboardEndpoint)
}

function Request-StatusRefresh {
    if ($script:UpdateInProgress) {
        return
    }

    if ($script:ActiveOperation) {
        $script:RefreshPending = $true
        return
    }

    $script:RefreshPending = $false
    $script:HermesPath = Find-HermesExecutable
    $script:LastError = $null

    if (-not $script:HermesPath) {
        $script:GatewayRunning = $false
        $script:DashboardRunning = $false
        $script:LastError = 'Hermes was not found on PATH.'
        Update-TrayDisplay
        return
    }

    $started = Start-HermesOperation -Arguments @('gateway', 'list') -QuietWhenBusy -OnComplete {
        param($gatewayResult)

        $gatewayText = "$($gatewayResult.Output)`n$($gatewayResult.Error)"
        $script:GatewayRunning = $gatewayResult.ExitCode -eq 0 -and $gatewayText -match '(?i)PID\s*\d+|process running|gateway running'
        if ($gatewayResult.ExitCode -ne 0) {
            $script:LastError = if ($gatewayResult.Error) { $gatewayResult.Error } else { 'Gateway status failed.' }
        }

        Start-HermesOperation -Arguments @('dashboard', '--status') -QuietWhenBusy -OnComplete {
            param($dashboardResult)

            $dashboardText = "$($dashboardResult.Output)`n$($dashboardResult.Error)"
            $reportedRunning = $dashboardResult.ExitCode -eq 0 -and $dashboardText -notmatch '(?i)no hermes dashboard processes running'
            $script:DashboardRunning = $reportedRunning -or (Test-DashboardEndpoint)
            if ($dashboardResult.ExitCode -ne 0 -and -not $script:LastError) {
                $script:LastError = if ($dashboardResult.Error) { $dashboardResult.Error } else { 'Dashboard status failed.' }
            }
            Update-TrayDisplay
        } | Out-Null
    }

    if (-not $started) {
        Update-TrayDisplay
    }
}

function Invoke-GatewayAction {
    param([ValidateSet('start', 'stop', 'restart')][string]$Action)

    Start-HermesOperation -Arguments @('gateway', $Action) -OnComplete {
        param($result)

        if ($result.ExitCode -eq 0) {
            Show-Notification "Gateway $Action requested" 'Hermes completed the command.'
        }
        else {
            $message = if ($result.Error) { $result.Error } else { $result.Output }
            Show-CompanionError "Gateway command failed.`n`n$message"
        }
        Request-StatusRefresh
    } | Out-Null
}

function Show-GatewayStatus {
    Start-HermesOperation -Arguments @('gateway', 'status') -OnComplete {
        param($result)

        $message = if ($result.Output) { $result.Output } elseif ($result.Error) { $result.Error } else { 'No status output was returned.' }
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Hermes Gateway Status',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        Request-StatusRefresh
    } | Out-Null
}

function Start-Dashboard {
    if (Test-DashboardEndpoint) {
        $script:DashboardRunning = $true
        Update-TrayDisplay
        Show-Notification 'Dashboard already running' $script:DashboardUrl
        return
    }

    if (Start-HermesDetached -Arguments @('dashboard', '--no-open')) {
        Show-Notification 'Dashboard starting' $script:DashboardUrl
        $script:RefreshPending = $true
    }
}

function Stop-Dashboard {
    Start-HermesOperation -Arguments @('dashboard', '--stop') -OnComplete {
        param($result)

        Start-Sleep -Milliseconds 300
        $stopped = -not (Test-DashboardEndpoint)
        if (-not $stopped) {
            $stopped = Stop-VerifiedDashboardListener
        }

        if ($result.ExitCode -eq 0 -and $stopped) {
            Show-Notification 'Dashboard stopped' 'The Hermes dashboard was stopped.'
        }
        else {
            $message = if ($result.Error) { $result.Error } elseif ($result.Output) { $result.Output } else { 'The dashboard is still listening on port 9119.' }
            Show-CompanionError "Dashboard stop failed.`n`n$message"
        }
        Request-StatusRefresh
    } | Out-Null
}

function Open-Dashboard {
    if ($script:DashboardRunning) {
        Start-Process $script:DashboardUrl
    }
    else {
        Start-HermesDetached -Arguments @('dashboard') | Out-Null
        $script:RefreshPending = $true
    }
}

function Open-HermesDesktop {
    Start-HermesDetached -Arguments @('desktop') | Out-Null
}

function Remove-AnsiEscape {
    param([string]$Text)

    $escape = [char]27
    return ($Text -replace "$escape\[[0-9;]*[A-Za-z]", '')
}

function Read-VersionOutput {
    param([string]$Text)

    $clean = Remove-AnsiEscape $Text
    $script:HermesVersion = $null
    $script:UpdateBehind = $null

    if ($clean -match '(?im)^\s*Hermes Agent\s+v?(\S+)') {
        $script:HermesVersion = $Matches[1]
    }

    # 'hermes version' reports one of: a commit count behind, an unqualified
    # 'Update available', 'Up to date', or nothing when it cannot tell.
    if ($clean -match '(?im)^\s*Update available:\s*(\d+)\s+commits?\s+behind') {
        $script:UpdateBehind = [int]$Matches[1]
    }
    elseif ($clean -match '(?im)^\s*Update available') {
        $script:UpdateBehind = -1
    }
    elseif ($clean -match '(?im)^\s*Up to date') {
        $script:UpdateBehind = 0
    }
}

function Test-UpdateAvailable {
    return ($null -ne $script:UpdateBehind) -and ($script:UpdateBehind -ne 0)
}

function Get-UpdateSummaryText {
    if ($script:UpdateBehind -gt 0) {
        $commitWord = if ($script:UpdateBehind -eq 1) { 'commit' } else { 'commits' }
        return "$($script:UpdateBehind) $commitWord behind"
    }
    if ($script:UpdateBehind -eq -1) {
        return 'a newer version is available'
    }
    return 'up to date'
}

function Get-VersionSummaryText {
    if (-not $script:HermesVersion) {
        return 'Hermes: version unknown'
    }
    if ($null -eq $script:UpdateBehind) {
        return "Hermes: v$($script:HermesVersion)"
    }
    if (Test-UpdateAvailable) {
        return "Hermes: v$($script:HermesVersion) - update available"
    }
    return "Hermes: v$($script:HermesVersion) - up to date"
}

function Request-VersionCheck {
    param([switch]$Announce)

    if ($script:UpdateInProgress) {
        return
    }

    if (-not $script:HermesPath) {
        $script:VersionCheckPending = $false
        $script:HermesVersion = $null
        $script:UpdateBehind = $null
        Update-TrayDisplay
        return
    }

    # 'hermes version' owns the upstream check and caches its result for six
    # hours. It can fetch from git, so allow well beyond the normal timeout.
    $started = Start-HermesOperation -Arguments @('version') -TimeoutSeconds 60 -QuietWhenBusy -OnComplete {
        param($result)

        $script:VersionCheckPending = $false
        Read-VersionOutput "$($result.Output)`n$($result.Error)"
        Update-TrayDisplay

        if (Test-UpdateAvailable) {
            if (-not $script:UpdateNotified) {
                $script:UpdateNotified = $true
                Show-Notification 'Hermes update available' "Installed v$($script:HermesVersion), $(Get-UpdateSummaryText). Use the tray menu to update."
            }
        }
        else {
            $script:UpdateNotified = $false
        }
    }

    if ($started) {
        $script:VersionCheckPending = $false
        if ($Announce) {
            Show-Notification 'Checking for updates' 'Hermes is checking for a newer version.'
        }
    }
    else {
        $script:VersionCheckPending = $true
    }
}

function Start-HermesUpdate {
    if ($script:UpdateInProgress) {
        Show-Notification 'Update already running' 'Hermes is still installing an update.'
        return
    }

    if (-not $script:HermesPath) {
        Show-CompanionError 'Hermes was not found on PATH.'
        return
    }

    $versionLine = if ($script:HermesVersion) { "Installed version: v$($script:HermesVersion)" } else { 'Installed version: unknown' }
    $statusLine = if ($null -eq $script:UpdateBehind) { 'Update status: unknown' } else { "Update status: $(Get-UpdateSummaryText)" }
    $warning = ''
    if ($script:GatewayRunning -or $script:DashboardRunning) {
        $warning = "`n`nHermes is running. Hermes pauses its gateway during the update, and it refuses to update while another hermes command is running. Stop the dashboard first if the update fails."
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Update Hermes Agent now?`n`n$versionLine`n$statusLine`n`nThe update runs in the background and can take several minutes. Hermes Companion reports the result in the notification area. Do not run other Hermes commands while it runs.$warning",
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    # The update prints a lot and runs for minutes. Redirect through cmd.exe
    # into files instead of pipes, because a full pipe buffer that nobody
    # drains until exit would block Hermes.
    $stamp = [Guid]::NewGuid().ToString('N')
    $outFile = Join-Path $env:TEMP "HermesCompanion-update-$stamp.out"
    $errorFile = Join-Path $env:TEMP "HermesCompanion-update-$stamp.err"
    $commandLine = '"{0}" update --yes > "{1}" 2> "{2}"' -f $script:HermesPath, $outFile, $errorFile

    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $info.Arguments = '/s /c "' + $commandLine + '"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
        $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) {
            throw 'The Hermes update process did not start.'
        }

        $script:UpdateOperation = [pscustomobject]@{
            Process = $process
            OutputFile = $outFile
            ErrorFile = $errorFile
            StartedAt = [DateTime]::UtcNow
            TimeoutSeconds = 3600
        }
        $script:UpdateInProgress = $true
        Update-TrayDisplay
        Show-Notification 'Hermes update started' 'The update runs in the background. This can take several minutes.'
    }
    catch {
        Show-CompanionError "Could not start the Hermes update.`n`n$($_.Exception.Message)"
    }
}

function Get-UpdateLogTail {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop | Where-Object { $_.Trim() })
        return (Remove-AnsiEscape (($lines | Select-Object -Last 20) -join "`n")).Trim()
    }
    catch {
        return ''
    }
}

function Complete-UpdateOperation {
    $operation = $script:UpdateOperation
    if (-not $operation) {
        return
    }

    $timedOut = ([DateTime]::UtcNow - $operation.StartedAt).TotalSeconds -gt $operation.TimeoutSeconds
    if (-not $operation.Process.HasExited -and -not $timedOut) {
        return
    }

    # A half-finished install is worse than a slow one, so a timed-out update
    # is reported and released rather than killed.
    $exitCode = if ($operation.Process.HasExited) { $operation.Process.ExitCode } else { $null }
    $standardOutput = Get-UpdateLogTail $operation.OutputFile
    $errorOutput = Get-UpdateLogTail $operation.ErrorFile

    if ($operation.Process.HasExited) {
        $operation.Process.Dispose()
        foreach ($file in @($operation.OutputFile, $operation.ErrorFile)) {
            try { Remove-Item -LiteralPath $file -Force -ErrorAction Stop } catch {}
        }
    }

    $script:UpdateOperation = $null
    $script:UpdateInProgress = $false

    if ($null -eq $exitCode) {
        Show-CompanionError "The Hermes update is still running after an hour.`n`nHermes Companion stopped watching it. Check the update output before you start Hermes again:`n$($operation.OutputFile)"
    }
    elseif ($exitCode -eq 0) {
        $script:UpdateNotified = $false
        $script:VersionCheckPending = $true
        Show-Notification 'Hermes updated' 'The update finished. Hermes Companion is rechecking the version.'
    }
    else {
        $detail = if ($errorOutput) { $errorOutput } elseif ($standardOutput) { $standardOutput } else { 'Hermes returned no output.' }
        Show-CompanionError "The Hermes update failed with exit code $exitCode.`n`n$detail"
    }

    Update-TrayDisplay
    Request-StatusRefresh
}

function Set-StartupEnabled {
    param([bool]$Enabled)

    try {
        if ($Enabled) {
            $launcherPath = Join-Path $PSScriptRoot 'HermesCompanion.vbs'
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($script:StartupShortcut)
            $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            $shortcut.Arguments = '"' + $launcherPath + '"'
            $shortcut.WorkingDirectory = $PSScriptRoot
            $shortcut.Description = 'Start Hermes Companion at Windows login'
            if (Test-Path -LiteralPath $script:IconPath) {
                $shortcut.IconLocation = "$script:IconPath,0"
            }
            $shortcut.Save()
        }
        elseif (Test-Path -LiteralPath $script:StartupShortcut) {
            Remove-Item -LiteralPath $script:StartupShortcut -Force
        }
        $startupState = if (Test-Path -LiteralPath $script:StartupShortcut) { 'On' } else { 'Off' }
        $script:StartupItem.Text = "Start with Windows: $startupState"
    }
    catch {
        $startupState = if (Test-Path -LiteralPath $script:StartupShortcut) { 'On' } else { 'Off' }
        $script:StartupItem.Text = "Start with Windows: $startupState"
        Show-CompanionError "Could not update startup settings.`n`n$($_.Exception.Message)"
    }
}

function Add-MenuHeading {
    param(
        [System.Windows.Forms.ContextMenuStrip]$Menu,
        [string]$Text
    )

    $heading = New-Object System.Windows.Forms.ToolStripLabel $Text.ToUpperInvariant()
    $heading.ForeColor = [System.Drawing.SystemColors]::GrayText
    $heading.Font = New-Object System.Drawing.Font $Menu.Font, ([System.Drawing.FontStyle]::Bold)
    $heading.Margin = New-Object System.Windows.Forms.Padding 4, 3, 4, 0
    $Menu.Items.Add($heading) | Out-Null
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$createdNew = $false
$script:SingleInstanceMutex = New-Object System.Threading.Mutex($true, "Local\HermesCompanion_$identity", [ref]$createdNew)
if (-not $createdNew) {
    $script:SingleInstanceMutex.Dispose()
    exit 0
}

$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = $script:MutedIcon
$script:TrayIcon.Text = 'Hermes Companion - checking status'
$script:TrayIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.AutoSize = $true
$menu.ShowImageMargin = $false
$menu.ShowCheckMargin = $false

$titleItem = New-Object System.Windows.Forms.ToolStripLabel 'Hermes Companion'
$titleItem.Font = New-Object System.Drawing.Font $menu.Font, ([System.Drawing.FontStyle]::Bold)
$titleItem.Margin = New-Object System.Windows.Forms.Padding 4, 4, 4, 4
$menu.Items.Add($titleItem) | Out-Null

$script:GatewaySummaryItem = New-Object System.Windows.Forms.ToolStripLabel 'Gateway: checking...'
$script:GatewaySummaryItem.Margin = New-Object System.Windows.Forms.Padding 4, 0, 4, 0
$menu.Items.Add($script:GatewaySummaryItem) | Out-Null

$script:DashboardSummaryItem = New-Object System.Windows.Forms.ToolStripLabel 'Dashboard: checking...'
$script:DashboardSummaryItem.Margin = New-Object System.Windows.Forms.Padding 4, 0, 4, 0
$menu.Items.Add($script:DashboardSummaryItem) | Out-Null

$script:VersionSummaryItem = New-Object System.Windows.Forms.ToolStripLabel 'Hermes: checking...'
$script:VersionSummaryItem.Margin = New-Object System.Windows.Forms.Padding 4, 0, 4, 4
$menu.Items.Add($script:VersionSummaryItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

Add-MenuHeading -Menu $menu -Text 'Open'

$script:OpenDashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Dashboard'
$script:OpenDashboardItem.ToolTipText = 'Open the Hermes browser dashboard'
$script:OpenDashboardItem.add_Click({ Open-Dashboard })
$menu.Items.Add($script:OpenDashboardItem) | Out-Null

$script:DesktopItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Desktop app'
$script:DesktopItem.ToolTipText = 'Open the Hermes desktop application'
$script:DesktopItem.add_Click({ Open-HermesDesktop })
$menu.Items.Add($script:DesktopItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

Add-MenuHeading -Menu $menu -Text 'Services'

$dashboardMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Dashboard service'
$script:StartDashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start'
$script:StartDashboardItem.add_Click({ Start-Dashboard })
$dashboardMenu.DropDownItems.Add($script:StartDashboardItem) | Out-Null
$script:StopDashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop'
$script:StopDashboardItem.add_Click({ Stop-Dashboard })
$dashboardMenu.DropDownItems.Add($script:StopDashboardItem) | Out-Null
$menu.Items.Add($dashboardMenu) | Out-Null

$gatewayMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Gateway service'
$script:GatewayStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem 'View detailed status'
$script:GatewayStatusItem.add_Click({ Show-GatewayStatus })
$gatewayMenu.DropDownItems.Add($script:GatewayStatusItem) | Out-Null
$gatewayMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$script:GatewayStartItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start'
$script:GatewayStartItem.add_Click({ Invoke-GatewayAction 'start' })
$gatewayMenu.DropDownItems.Add($script:GatewayStartItem) | Out-Null
$script:GatewayStopItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop'
$script:GatewayStopItem.add_Click({ Invoke-GatewayAction 'stop' })
$gatewayMenu.DropDownItems.Add($script:GatewayStopItem) | Out-Null
$script:GatewayRestartItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Restart'
$script:GatewayRestartItem.add_Click({ Invoke-GatewayAction 'restart' })
$gatewayMenu.DropDownItems.Add($script:GatewayRestartItem) | Out-Null
$menu.Items.Add($gatewayMenu) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

Add-MenuHeading -Menu $menu -Text 'Tools'

$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Refresh status'
$refreshItem.add_Click({ Request-StatusRefresh })
$menu.Items.Add($refreshItem) | Out-Null

$script:CheckUpdateItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Check for updates'
$script:CheckUpdateItem.ToolTipText = 'Ask Hermes whether a newer version is available'
$script:CheckUpdateItem.add_Click({ Request-VersionCheck -Announce })
$menu.Items.Add($script:CheckUpdateItem) | Out-Null

$script:UpdateHermesItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Update Hermes...'
$script:UpdateHermesItem.ToolTipText = 'Install the latest Hermes Agent version'
$script:UpdateHermesItem.add_Click({ Start-HermesUpdate })
$menu.Items.Add($script:UpdateHermesItem) | Out-Null

$logsItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open logs folder'
$logsItem.add_Click({
    if (Test-Path -LiteralPath $script:LogsPath) {
        Start-Process explorer.exe -ArgumentList ('"' + $script:LogsPath + '"')
    }
    else {
        Show-CompanionError "The Hermes logs directory does not exist yet:`n$script:LogsPath"
    }
})
$menu.Items.Add($logsItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

Add-MenuHeading -Menu $menu -Text 'Preferences'

$startupState = if (Test-Path -LiteralPath $script:StartupShortcut) { 'On' } else { 'Off' }
$script:StartupItem = New-Object System.Windows.Forms.ToolStripMenuItem "Start with Windows: $startupState"
$script:StartupItem.add_Click({ Set-StartupEnabled (-not (Test-Path -LiteralPath $script:StartupShortcut)) })
$menu.Items.Add($script:StartupItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
$menu.Items.Add($exitItem) | Out-Null

$script:TrayIcon.ContextMenuStrip = $menu
$script:TrayIcon.add_DoubleClick({ Open-Dashboard })

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 250
$pollTimer.add_Tick({
    Complete-UpdateOperation
    Complete-ActiveOperation
    if ($script:ActiveOperation -or $script:UpdateInProgress) {
        return
    }
    if ($script:RefreshPending) {
        Request-StatusRefresh
    }
    elseif ($script:VersionCheckPending) {
        Request-VersionCheck
    }
})
$pollTimer.Start()

$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 10000
$refreshTimer.add_Tick({ Request-StatusRefresh })
$refreshTimer.Start()

$applicationContext = New-Object System.Windows.Forms.ApplicationContext
$exitItem.add_Click({ $applicationContext.ExitThread() })

try {
    Request-StatusRefresh
    [System.Windows.Forms.Application]::Run($applicationContext)
}
finally {
    $pollTimer.Stop()
    $refreshTimer.Stop()
    if ($script:ActiveOperation -and -not $script:ActiveOperation.Process.HasExited) {
        try { $script:ActiveOperation.Process.Kill() } catch {}
        $script:ActiveOperation.Process.Dispose()
    }
    if ($script:UpdateOperation) {
        # Killing a running update would strand a half-installed Hermes.
        try { $script:UpdateOperation.Process.Dispose() } catch {}
    }
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    $menu.Dispose()
    $script:ActiveIcon.Dispose()
    $script:MutedIcon.Dispose()
    $script:SingleInstanceMutex.ReleaseMutex()
    $script:SingleInstanceMutex.Dispose()
}
