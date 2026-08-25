[CmdletBinding()]
param(
    [switch]$ParsersOnly
)

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
$script:RestartDashboardAfterUpdate = $false
$script:HermesInstallDirectory = $null
$script:HermesInstallMethod = $null
$script:RecommendedUpdateCommand = $null
$script:UpdateStatusText = $null
$script:UpdateProgressReadAt = [DateTime]::MinValue
$script:UpdateHeartbeatAt = [DateTime]::MinValue
$script:Profiles = @()
$script:ProfileRefreshPending = $true

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

    if ($script:UpdateInProgress) {
        if (-not $QuietWhenBusy) {
            Show-Notification 'Hermes update in progress' 'Wait for the update to finish before running another command.'
        }
        return $false
    }

    if ($script:ActiveOperation) {
        if (-not $QuietWhenBusy) {
            Show-Notification 'Hermes is already handling another request.' 'Please wait a moment and try again.'
        }
        return $false
    }

    $process = $null
    try {
        $info = New-HermesProcessStartInfo -Arguments $Arguments -RedirectOutput
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        $outputBuilder = New-Object System.Text.StringBuilder
        $errorBuilder = New-Object System.Text.StringBuilder
        # Process events drain each pipe as data arrives, so a chatty Hermes
        # failure cannot block on a full pipe before it exits.
        $outputDataReceived = {
            param($sender, $eventArgs)

            if ($eventArgs.Data -ne $null) {
                [void]$outputBuilder.AppendLine($eventArgs.Data)
            }
        }.GetNewClosure()
        $errorDataReceived = {
            param($sender, $eventArgs)

            if ($eventArgs.Data -ne $null) {
                [void]$errorBuilder.AppendLine($eventArgs.Data)
            }
        }.GetNewClosure()
        $process.add_OutputDataReceived($outputDataReceived)
        $process.add_ErrorDataReceived($errorDataReceived)
        if (-not $process.Start()) {
            throw 'The Hermes process did not start.'
        }
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        $script:ActiveOperation = [pscustomobject]@{
            Process = $process
            Arguments = $Arguments
            OnComplete = $OnComplete
            StartedAt = [DateTime]::UtcNow
            TimeoutSeconds = $TimeoutSeconds
            OutputBuilder = $outputBuilder
            ErrorBuilder = $errorBuilder
            OutputDataReceived = $outputDataReceived
            ErrorDataReceived = $errorDataReceived
        }
        return $true
    }
    catch {
        if ($process) {
            # A reader setup failure leaves no operation to manage a process
            # that may have started, so stop it before releasing the handle.
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit()
                }
            }
            catch {
                Write-Verbose 'The Hermes process could not be stopped after startup failed.'
            }
            $process.Dispose()
        }
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
        try { $operation.Process.Kill() } catch { Write-Verbose 'The timed out Hermes process was already gone.' }
        $operation.Process.WaitForExit()
        $result = [pscustomobject]@{
            ExitCode = -1
            Output = ''
            Error = 'The Hermes command timed out.'
        }
    }
    else {
        # Wait once more after exit so the asynchronous readers receive their
        # final lines before their builders are converted to result strings.
        $operation.Process.WaitForExit()
        $result = [pscustomobject]@{
            ExitCode = $operation.Process.ExitCode
            Output = $operation.OutputBuilder.ToString().Trim()
            Error = $operation.ErrorBuilder.ToString().Trim()
        }
    }

    $operation.Process.remove_OutputDataReceived($operation.OutputDataReceived)
    $operation.Process.remove_ErrorDataReceived($operation.ErrorDataReceived)
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
    <#
        Take the notification area's own icon size for this display, and pull
        that exact size out of the .ico. Windows picks the nearest embedded
        image, so a file carrying 16, 20, 24 and 32 hands back artwork drawn
        for the size rather than anything resampled at runtime.
    #>
    param([switch]$Muted)

    if (-not (Test-Path -LiteralPath $script:IconPath)) {
        throw "The tray icon is missing: $script:IconPath"
    }

    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize
    $icon = New-Object System.Drawing.Icon -ArgumentList $script:IconPath, $size.Width, $size.Height
    if (-not $Muted) {
        return $icon
    }

    # The stopped state reuses the same artwork, greyed and faded. That is a
    # per-pixel colour change at the icon's own size, so nothing is rescaled.
    $bitmap = $icon.ToBitmap()
    $icon.Dispose()

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

    $handle = $bitmap.GetHicon()
    $mutedIcon = [System.Drawing.Icon]::FromHandle($handle).Clone()
    [HermesCompanionNativeMethods]::DestroyIcon($handle) | Out-Null
    $bitmap.Dispose()
    return $mutedIcon
}

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
    $script:UpdateLogItem.Enabled = $Enabled
    $script:ProfilesMenu.Enabled = $Enabled
}

function Update-TrayDisplay {
    $script:VersionSummaryItem.Text = Get-VersionSummaryText

    if ($script:UpdateInProgress) {
        # Any Hermes command started now would trip the concurrent-process
        # guard in 'hermes update', so no Hermes action stays available.
        $script:TrayIcon.Icon = $script:ActiveIcon

        $elapsed = if ($script:UpdateOperation) { Format-UpdateElapsed ([DateTime]::UtcNow - $script:UpdateOperation.StartedAt) } else { $null }
        $step = if ($script:UpdateStatusText) { $script:UpdateStatusText } else { 'Preparing...' }

        $tooltip = "Updating Hermes - $step"
        if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 60) + '...' }
        $script:TrayIcon.Text = $tooltip

        $heading = if ($elapsed) { "Updating Hermes... ($elapsed)" } else { 'Updating Hermes...' }
        $detail = if ($step.Length -gt 60) { $step.Substring(0, 57) + '...' } else { $step }
        $script:GatewaySummaryItem.Text = $heading
        $script:DashboardSummaryItem.Text = $detail
        Set-HermesMenuEnabled $false
        $script:UpdateLogItem.Enabled = $true
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
    Set-HermesMenuEnabled $true
    $script:StartDashboardItem.Enabled = -not $script:DashboardRunning
    $script:StopDashboardItem.Enabled = $script:DashboardRunning
    $script:GatewayStartItem.Enabled = -not $script:GatewayRunning
    $script:GatewayStopItem.Enabled = $script:GatewayRunning
    $script:GatewayRestartItem.Enabled = $script:GatewayRunning
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

    $onComplete = {
        param($result)

        if ($result.ExitCode -eq 0) {
            Show-Notification "Gateway $Action requested" 'Hermes completed the command.'
        }
        else {
            $message = if ($result.Error) { $result.Error } else { $result.Output }
            Show-CompanionError "Gateway command failed.`n`n$message"
        }
        Request-StatusRefresh
    }.GetNewClosure()
    Start-HermesOperation -Arguments @('gateway', $Action) -OnComplete $onComplete | Out-Null
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

function Read-UpdateStatus {
    <#
        Both 'hermes version' and 'hermes update --check' report the same three
        outcomes, but --check prefixes its lines with a status glyph, so these
        patterns are deliberately not anchored to the start of a line.
    #>
    param([string]$Text)

    # Both commands name the update command that suits this install:
    # 'hermes update' for a git checkout, an out-of-band command otherwise.
    if ($Text -match "(?i)run '([^']+)'") {
        $script:RecommendedUpdateCommand = $Matches[1]
    }

    if ($Text -match '(?i)Update available:\s*(\d+)\s+commits?\s+behind') {
        $script:UpdateBehind = [int]$Matches[1]
        return $true
    }
    if ($Text -match '(?i)Update available') {
        $script:UpdateBehind = -1
        return $true
    }
    if ($Text -match '(?i)(already )?up to date') {
        $script:UpdateBehind = 0
        return $true
    }

    return $false
}

function Read-VersionOutput {
    param([string]$Text)

    $clean = Remove-AnsiEscape $Text
    $script:HermesVersion = $null
    $script:UpdateBehind = $null

    if ($clean -match '(?im)^\s*Hermes Agent\s+v?(\d+(?:\.\d+)+\S*)') {
        $script:HermesVersion = $Matches[1]
    }

    # 'hermes version' reports the install directory. The update preflight
    # needs it to find the processes holding this install's Python venv.
    if ($clean -match '(?im)^\s*Install directory:\s*(.+?)\s*$') {
        $script:HermesInstallDirectory = $Matches[1]
    }

    if ($clean -match '(?im)^\s*Install method:\s*(\S+)') {
        $script:HermesInstallMethod = $Matches[1]
    }

    Read-UpdateStatus $clean | Out-Null
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

    # 'hermes --version' reports the version, the install, and the update
    # status. It owns the upstream check and caches it for six hours, and it
    # can fetch from git, so allow well beyond the normal timeout.
    $started = Start-HermesOperation -Arguments @('--version') -TimeoutSeconds 60 -QuietWhenBusy -OnComplete {
        param($result)

        $script:VersionCheckPending = $false
        Read-VersionOutput "$($result.Output)`n$($result.Error)"
        Update-TrayDisplay

        if ($result.ExitCode -ne 0 -or -not $script:HermesVersion) {
            $script:LastError = 'Hermes did not report its version.'
            Update-TrayDisplay
            return
        }

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
    }
    else {
        $script:VersionCheckPending = $true
    }
}

function Request-UpdateCheck {
    <#
        'hermes update --check' is the documented way to ask whether an update
        is available. Unlike 'hermes version' it always fetches, so a check the
        user asked for never answers from Hermes's six-hour cache.
    #>
    if ($script:UpdateInProgress) {
        return
    }

    if (-not $script:HermesPath) {
        Show-CompanionError 'Hermes was not found on PATH.'
        return
    }

    $started = Start-HermesOperation -Arguments @('update', '--check') -TimeoutSeconds 120 -OnComplete {
        param($result)

        $text = Remove-AnsiEscape "$($result.Output)`n$($result.Error)"
        if ($result.ExitCode -ne 0 -or -not (Read-UpdateStatus $text)) {
            $detail = if ($text.Trim()) { $text.Trim() } else { 'Hermes returned no output.' }
            Show-CompanionError "The update check failed.`n`n$detail"
            Update-TrayDisplay
            return
        }

        Update-TrayDisplay
        if (Test-UpdateAvailable) {
            $script:UpdateNotified = $true
            Show-Notification 'Hermes update available' "Installed v$($script:HermesVersion), $(Get-UpdateSummaryText). Use the tray menu to update."
        }
        else {
            $script:UpdateNotified = $false
            Show-Notification 'Hermes is up to date' "Installed v$($script:HermesVersion)."
        }
    }

    if ($started) {
        Show-Notification 'Checking for updates' 'Hermes is contacting its upstream repository.'
    }
}

function Read-ProfileList {
    <#
        Parse the table 'hermes profile list' prints: one row per profile with
        name, model, gateway state, alias, and distribution. The active profile
        carries a marker outside ASCII, and so does the rule under the header,
        so both are recognised by that property rather than by the characters
        themselves. This file has no byte order mark, and PowerShell 5.1 would
        read such characters using the system code page.
    #>
    param([string]$Text)

    $profiles = @()
    foreach ($rawLine in ((Remove-AnsiEscape $Text) -split "`r?`n")) {
        $line = $rawLine.TrimEnd()
        if (-not $line.Trim()) {
            continue
        }

        $isActive = $line.TrimStart() -match '^[^\x00-\x7F]'
        $stripped = ($line.TrimStart() -replace '^[^\x00-\x7F\s]+', '').Trim()
        if (-not $stripped) {
            continue
        }

        $fields = @($stripped -split '\s{2,}')
        $name = $fields[0].Trim()
        if ($name -notmatch '^[A-Za-z0-9._-]+$' -or $name -eq 'Profile') {
            continue
        }

        $gateway = if ($fields.Count -ge 3) { $fields[2].Trim() } else { '' }
        $alias = if ($fields.Count -ge 4 -and $fields[3].Trim() -match '^[A-Za-z0-9._-]+$') { $fields[3].Trim() } else { $null }

        $profiles += [pscustomobject]@{
            Name = $name
            Model = if ($fields.Count -ge 2) { $fields[1].Trim() } else { '' }
            GatewayRunning = ($gateway -match '(?i)^running')
            GatewayInstalled = $null
            Alias = $alias
            IsActive = $isActive
        }
    }

    return @($profiles)
}

function Request-ProfileRefresh {
    if ($script:UpdateInProgress -or -not $script:HermesPath) {
        return
    }

    $started = Start-HermesOperation -Arguments @('profile', 'list') -QuietWhenBusy -OnComplete {
        param($result)

        $script:ProfileRefreshPending = $false
        if ($result.ExitCode -eq 0) {
            $script:Profiles = Read-ProfileList "$($result.Output)`n$($result.Error)"
        }
        Update-ProfileMenu
        Request-ProfileGatewayInstallationRefresh
    }

    if ($started) {
        $script:ProfileRefreshPending = $false
    }
    else {
        $script:ProfileRefreshPending = $true
    }
}

function Get-ProfileGatewayInstalledState {
    <#
        A stopped gateway is not necessarily ready to start. On Windows Hermes
        creates either a Scheduled Task or a Startup-folder item before it can
        run a profile gateway in the background. Its status command is the
        authoritative source for that distinction.
    #>
    param([string]$Text)

    $clean = Remove-AnsiEscape $Text
    if ($clean -match '(?i)Scheduled Task registered|Windows login item installed|Gateway service (?:is )?installed') {
        return $true
    }
    if ($clean -match '(?is)\b(?:To install|To start):.*?\bgateway install\b|Gateway service is not installed') {
        return $false
    }

    return $null
}

function Request-ProfileGatewayInstallationRefresh {
    param([int]$Index = 0)

    $profiles = @($script:Profiles)
    if ($script:UpdateInProgress -or -not $script:HermesPath -or $Index -ge $profiles.Count) {
        return
    }

    $hermesProfile = $profiles[$Index]
    $onComplete = {
        param($result)

        if ($result.ExitCode -eq 0) {
            $hermesProfile.GatewayInstalled = Get-ProfileGatewayInstalledState "$($result.Output)`n$($result.Error)"
        }
        else {
            $hermesProfile.GatewayInstalled = $null
        }

        Update-ProfileMenu
        Request-ProfileGatewayInstallationRefresh -Index ($Index + 1)
    }.GetNewClosure()
    $started = Start-HermesOperation -Arguments @('-p', $hermesProfile.Name, 'gateway', 'status') -QuietWhenBusy -OnComplete $onComplete

    if (-not $started) {
        # A refresh will retry after the command already in flight completes.
        $script:ProfileRefreshPending = $true
    }
}

function Get-TerminalLaunch {
    <#
        Prefer Windows Terminal, which renders the Hermes interface properly,
        and use a console window where it is not installed.
    #>
    param(
        [string]$Title,
        [string]$Command
    )

    $windowsTerminal = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $windowsTerminal) {
        return [pscustomobject]@{
            FilePath = $windowsTerminal
            Arguments = '--title "' + $Title + '" cmd /k ' + $Command
        }
    }

    return [pscustomobject]@{
        FilePath = Join-Path $env:SystemRoot 'System32\cmd.exe'
        Arguments = '/k ' + $Command
    }
}

function Open-HermesTerminal {
    <#
        Windows Terminal is an app execution alias: it hands the request to the
        Windows Terminal process, which starts the shell from its own
        environment rather than the companion's. Run the Hermes executable by
        its resolved path so the launched terminal does not depend on PATH.
    #>
    param(
        [string]$Title,
        [string]$ScriptName,
        [string[]]$Arguments
    )

    if (-not $script:HermesPath) {
        Show-CompanionError 'Hermes was not found on PATH.'
        return
    }

    $lines = @(
        '@echo off',
        "title $title",
        ('call "' + $script:HermesPath + '" ' + (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '))
    )

    # One script per action/profile, rewritten on each launch, so these do not
    # pile up in the temp directory or replace a terminal that is still open.
    $scriptPath = Join-Path $env:TEMP "HermesCompanion-$ScriptName.cmd"
    try {
        Set-Content -LiteralPath $scriptPath -Value $lines -Encoding Ascii -ErrorAction Stop
    }
    catch {
        Show-CompanionError "Could not prepare the terminal session.`n`n$($_.Exception.Message)"
        return
    }

    $launch = Get-TerminalLaunch -Title $title -Command ('"' + $scriptPath + '"')
    try {
        Start-Process -FilePath $launch.FilePath -ArgumentList $launch.Arguments -ErrorAction Stop
    }
    catch {
        Show-CompanionError "Could not open a Hermes terminal.`n`n$($_.Exception.Message)"
    }
}

function Open-ProfileTerminal {
    param([string]$Name)

    Open-HermesTerminal -Title "Hermes - $Name" -ScriptName "$Name-session" -Arguments @('-p', $Name)
}

function Install-ProfileGateway {
    param([string]$Name)

    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Install a Windows background gateway for profile '$Name'?`n`nHermes will create a per-profile Windows startup entry. It can then start this profile's gateway without an open terminal.",
        'Install profile gateway',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    # Hermes may need user input or a Windows UAC approval to create its task.
    # Use a real terminal for that installer; a hidden command would leave its
    # prompt unanswered and make the companion appear stuck.
    Open-HermesTerminal -Title "Install Hermes gateway - $Name" -ScriptName "$Name-gateway-install" -Arguments @('-p', $Name, 'gateway', 'install')
    Show-Notification 'Complete gateway installation' "Finish the Hermes prompts for profile $Name, then choose Refresh status."
}

function Show-ProfileDetails {
    param([string]$Name)

    Start-HermesOperation -Arguments @('profile', 'show', $Name) -OnComplete {
        param($result)

        $message = if ($result.Output) { $result.Output } elseif ($result.Error) { $result.Error } else { 'Hermes returned no details.' }
        [System.Windows.Forms.MessageBox]::Show(
            (Remove-AnsiEscape $message),
            "Hermes Profile",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } | Out-Null
}

function Open-ProfileFolder {
    param([string]$Name)

    # 'hermes profile show' reports the profile's directory, so the layout of
    # the Hermes home never has to be guessed at here.
    Start-HermesOperation -Arguments @('profile', 'show', $Name) -OnComplete {
        param($result)

        $text = Remove-AnsiEscape "$($result.Output)`n$($result.Error)"
        if ($text -match '(?im)^\s*Path:\s*(.+?)\s*$') {
            $path = $Matches[1]
            if (Test-Path -LiteralPath $path) {
                Start-Process explorer.exe -ArgumentList ('"' + $path + '"')
                return
            }
            Show-CompanionError "The profile directory does not exist:`n$path"
            return
        }

        Show-CompanionError 'Hermes did not report a directory for this profile.'
    } | Out-Null
}

function Invoke-ProfileGatewayAction {
    param(
        [string]$Name,
        [ValidateSet('start', 'stop', 'restart')][string]$Action
    )

    $onComplete = {
        param($result)

        if ($result.ExitCode -eq 0) {
            Show-Notification "Gateway $Action requested" "Profile $Name"
        }
        else {
            $message = if ($result.Error) { $result.Error } else { $result.Output }
            Show-CompanionError "Gateway command failed for profile '$Name'.`n`n$message"
        }
        $script:ProfileRefreshPending = $true
        Request-StatusRefresh
    }.GetNewClosure()
    Start-HermesOperation -Arguments @('-p', $Name, 'gateway', $Action) -OnComplete $onComplete | Out-Null
}

function Update-ProfileMenu {
    $script:ProfilesMenu.DropDownItems.Clear()

    if (@($script:Profiles).Count -eq 0) {
        $empty = New-Object System.Windows.Forms.ToolStripMenuItem 'No profiles found'
        $empty.Enabled = $false
        $script:ProfilesMenu.DropDownItems.Add($empty) | Out-Null
        return
    }

    foreach ($hermesProfile in $script:Profiles) {
        $name = $hermesProfile.Name
        $labels = @()
        if ($hermesProfile.IsActive) { $labels += 'active' }
        $gatewayState = if ($hermesProfile.GatewayRunning) {
            'gateway running'
        }
        elseif ($hermesProfile.GatewayInstalled -eq $true) {
            'gateway stopped'
        }
        elseif ($hermesProfile.GatewayInstalled -eq $false) {
            'gateway not installed'
        }
        else {
            'gateway checking'
        }
        $labels += $gatewayState
        $item = New-Object System.Windows.Forms.ToolStripMenuItem ("$name ($($labels -join ', '))")

        $terminalItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Hermes in terminal'
        $terminalItem.add_Click({ Open-ProfileTerminal -Name $name }.GetNewClosure())
        $item.DropDownItems.Add($terminalItem) | Out-Null

        $detailsItem = New-Object System.Windows.Forms.ToolStripMenuItem 'View details'
        $detailsItem.add_Click({ Show-ProfileDetails -Name $name }.GetNewClosure())
        $item.DropDownItems.Add($detailsItem) | Out-Null

        $folderItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open profile folder'
        $folderItem.add_Click({ Open-ProfileFolder -Name $name }.GetNewClosure())
        $item.DropDownItems.Add($folderItem) | Out-Null

        $item.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

        $startItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start gateway'
        $startItem.Enabled = $hermesProfile.GatewayInstalled -eq $true -and -not $hermesProfile.GatewayRunning
        $startItem.add_Click({ Invoke-ProfileGatewayAction -Name $name -Action 'start' }.GetNewClosure())
        $item.DropDownItems.Add($startItem) | Out-Null

        $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop gateway'
        $stopItem.Enabled = $hermesProfile.GatewayRunning
        $stopItem.add_Click({ Invoke-ProfileGatewayAction -Name $name -Action 'stop' }.GetNewClosure())
        $item.DropDownItems.Add($stopItem) | Out-Null

        if ($hermesProfile.GatewayInstalled -eq $false) {
            $item.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
            $installItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Install gateway...'
            $installItem.add_Click({ Install-ProfileGateway -Name $name }.GetNewClosure())
            $item.DropDownItems.Add($installItem) | Out-Null
        }

        $script:ProfilesMenu.DropDownItems.Add($item) | Out-Null
    }
}

function Get-HermesInstallDirectory {
    if ($script:HermesInstallDirectory -and (Test-Path -LiteralPath $script:HermesInstallDirectory)) {
        return [IO.Path]::GetFullPath($script:HermesInstallDirectory)
    }

    # Before the first version check lands, derive the install directory from
    # the executable. Hermes installs its entry point as <install>\bin\hermes.
    if ($script:HermesPath) {
        $candidate = Split-Path -Parent (Split-Path -Parent $script:HermesPath)
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'venv'))) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

function Get-UpdateBlockingProcess {
    <#
        Mirror the venv guard 'hermes update' enforces on Windows. Any live
        process running from, or importing out of, this install's venv keeps
        native .pyd files mapped, and a dependency sync that dies partway
        strands the install between versions, so Hermes refuses to start.

        Gateway processes are reported separately. Hermes pauses them before
        the update and restarts them afterwards, so stopping them here would
        only rob Hermes of the state it needs to bring them back.
    #>
    $installDirectory = Get-HermesInstallDirectory
    if (-not $installDirectory) {
        return @()
    }

    $rootPrefix = $installDirectory.TrimEnd('\') + '\'
    $venvPrefix = (Join-Path $installDirectory 'venv').TrimEnd('\') + '\'

    try {
        $snapshot = Get-CimInstance Win32_Process -ErrorAction Stop |
            Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine
    }
    catch {
        return @()
    }

    $blockers = foreach ($process in $snapshot) {
        $executable = if ($process.ExecutablePath) { $process.ExecutablePath } else { '' }
        $commandLine = if ($process.CommandLine) { $process.CommandLine } else { '' }

        $isHolder = $executable.StartsWith($venvPrefix, [StringComparison]::OrdinalIgnoreCase)
        if (-not $isHolder) {
            $isHolder = $commandLine.IndexOf($venvPrefix, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        if (-not $isHolder -and $commandLine.IndexOf('hermes_cli.main', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $isHolder = $commandLine.IndexOf($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        if (-not $isHolder) {
            continue
        }

        [pscustomobject]@{
            ProcessId = [int]$process.ProcessId
            Name = $process.Name
            CommandLine = $commandLine
            IsGateway = $commandLine -match '(?i)gateway\s+run'
        }
    }

    return @($blockers)
}

function Get-ProcessTreeId {
    param(
        [int]$ProcessId,
        $Snapshot
    )

    $installDirectory = Get-HermesInstallDirectory
    $rootPrefix = if ($installDirectory) { $installDirectory.TrimEnd('\') + '\' } else { $null }

    $identifiers = [System.Collections.Generic.List[int]]::new()
    $pending = [System.Collections.Generic.Queue[int]]::new()
    $pending.Enqueue($ProcessId)

    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if ($identifiers.Contains($current)) {
            continue
        }
        $identifiers.Add($current)
        foreach ($child in ($Snapshot | Where-Object { $_.ParentProcessId -eq $current })) {
            $pending.Enqueue([int]$child.ProcessId)
        }
    }

    # Walk up through this install's launcher shims. A dashboard is a
    # hermes.exe parent over a venv python, and leaving the shim behind keeps
    # a half-dead dashboard holding port 9119.
    if ($rootPrefix) {
        $current = $ProcessId
        for ($depth = 0; $depth -lt 5; $depth++) {
            $process = $Snapshot | Where-Object { $_.ProcessId -eq $current } | Select-Object -First 1
            if (-not $process) { break }
            $parent = $Snapshot | Where-Object { $_.ProcessId -eq $process.ParentProcessId } | Select-Object -First 1
            if (-not $parent -or -not $parent.ExecutablePath) { break }
            if (-not $parent.ExecutablePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { break }
            if (-not $identifiers.Contains([int]$parent.ProcessId)) {
                $identifiers.Add([int]$parent.ProcessId)
            }
            $current = [int]$parent.ProcessId
        }
    }

    return $identifiers
}

function Stop-UpdateBlockingProcess {
    param($Blockers)

    try {
        $snapshot = Get-CimInstance Win32_Process -ErrorAction Stop |
            Select-Object ProcessId, ParentProcessId, Name, ExecutablePath
    }
    catch {
        $snapshot = @()
    }

    foreach ($blocker in $Blockers) {
        foreach ($identifier in (Get-ProcessTreeId -ProcessId $blocker.ProcessId -Snapshot $snapshot)) {
            try { Stop-Process -Id $identifier -Force -ErrorAction Stop } catch {}
        }
    }
}

function Wait-ActiveOperationDrained {
    <#
        The companion's own status commands run from the venv, so one in flight
        blocks the update just as much as a dashboard. Pump it to completion
        instead of killing it; these commands finish in about a second.
    #>
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ($script:ActiveOperation -and [DateTime]::UtcNow -lt $deadline) {
        Complete-ActiveOperation
        if ($script:ActiveOperation) {
            Start-Sleep -Milliseconds 100
        }
    }

    return (-not $script:ActiveOperation)
}

function Format-BlockerList {
    param($Blockers)

    $items = @($Blockers)
    $lines = foreach ($blocker in ($items | Select-Object -First 6)) {
        $command = $blocker.CommandLine
        if ($command.Length -gt 90) { $command = $command.Substring(0, 90) + '...' }
        "  $($blocker.Name) (PID $($blocker.ProcessId))  $command"
    }
    if ($items.Count -gt 6) {
        $lines = @($lines) + "  ... and $($items.Count - 6) more"
    }

    return (@($lines) -join "`n")
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

    # Hermes reports the update command that suits this install. Anything but
    # 'hermes update' means an in-place update cannot work here, so show the
    # command instead of running one, as the Hermes dashboard does.
    $unsupportedMethod = $script:HermesInstallMethod -and ($script:HermesInstallMethod -match '(?i)^(docker|nix|nixos|apt)$')
    $unsupportedCommand = $script:RecommendedUpdateCommand -and ($script:RecommendedUpdateCommand -notmatch '(?i)^hermes\s+update$')
    if ($unsupportedMethod -or $unsupportedCommand) {
        $method = if ($script:HermesInstallMethod) { " ($($script:HermesInstallMethod) install)" } else { '' }
        $command = if ($script:RecommendedUpdateCommand) { $script:RecommendedUpdateCommand } else { 'the command for your install method' }
        Show-CompanionError "Hermes Companion cannot update this installation in place$method.`n`nUpdate it with:`n$command"
        return
    }

    $versionLine = if ($script:HermesVersion) { "Installed version: v$($script:HermesVersion)" } else { 'Installed version: unknown' }
    $statusLine = if ($null -eq $script:UpdateBehind) { 'Update status: unknown' } else { "Update status: $(Get-UpdateSummaryText)" }

    # Name every process that will be stopped, so the one confirmation covers
    # all of it. Hermes handles its own gateway, so it is excluded.
    $blockers = @(Get-UpdateBlockingProcess | Where-Object { -not $_.IsGateway })
    $blockerNote = ''
    if ($blockers.Count -gt 0) {
        $blockerNote = "`n`nThese Hermes processes hold the Python environment and will be stopped:`n$(Format-BlockerList $blockers)`n`nUnsaved work in them is lost. The dashboard starts again when the update ends."
    }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Update Hermes Agent now?`n`n$versionLine`n$statusLine`n`nThe update runs in the background and can take several minutes. Hermes Companion reports the result in the notification area. Hermes pauses and restarts its own gateway.$blockerNote",
        $script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    # Claim the update now so no status poll starts a hermes command. A stray
    # hermes process would trip the concurrent-process guard in 'hermes update'.
    $script:UpdateInProgress = $true
    $script:RestartDashboardAfterUpdate = $script:DashboardRunning
    Update-TrayDisplay

    if (-not (Wait-ActiveOperationDrained)) {
        $script:UpdateInProgress = $false
        $script:RestartDashboardAfterUpdate = $false
        Show-CompanionError 'The update was cancelled because the active Hermes command did not finish before the eight-second drain period. Try again in a moment.'
        Update-TrayDisplay
        return
    }

    # Re-read the blockers. The list shown in the dialog can be stale by the
    # time the user answers it.
    $blockers = @(Get-UpdateBlockingProcess | Where-Object { -not $_.IsGateway })
    if ($blockers.Count -gt 0) {
        Stop-UpdateBlockingProcess $blockers
        $script:DashboardRunning = $false
        # Windows releases the mapped extension files a moment after exit.
        Start-Sleep -Milliseconds 1500
    }

    $remaining = @(Get-UpdateBlockingProcess | Where-Object { -not $_.IsGateway })
    if ($remaining.Count -gt 0) {
        $script:UpdateInProgress = $false
        Show-CompanionError "The update was cancelled because these Hermes processes could not be stopped:`n`n$(Format-BlockerList $remaining)`n`nStop them yourself, then try again."
        Restore-DashboardAfterUpdate
        Update-TrayDisplay
        Request-StatusRefresh
        return
    }

    Invoke-HermesUpdateProcess
}

function Invoke-HermesUpdateProcess {
    <#
        Match how the Hermes dashboard spawns its own update: no --yes, an
        explicit HERMES_NONINTERACTIVE marker, stdin closed, and stdout and
        stderr merged into one log. Hermes then answers its own prompts from
        updates.non_interactive_local_changes instead of blocking on input.

        The command goes through cmd.exe so the output lands in a file. The
        update prints a lot and runs for minutes, and a pipe that nobody drains
        until exit would block Hermes once the buffer filled.
    #>
    try {
        New-Item -ItemType Directory -Path $script:LogsPath -Force -ErrorAction Stop | Out-Null
    }
    catch {
        $script:UpdateInProgress = $false
        Show-CompanionError "Could not prepare the update log.`n`n$($_.Exception.Message)"
        Restore-DashboardAfterUpdate
        Update-TrayDisplay
        return
    }

    # Keep the latest complete update output where the menu can open it after
    # the process ends. A temporary log made failure reports point at a file
    # that was already deleted.
    $logFile = Join-Path $script:LogsPath 'update.log'
    $commandLine = '"{0}" update < NUL > "{1}" 2>&1' -f $script:HermesPath, $logFile
    $workingDirectory = Get-HermesInstallDirectory
    if (-not $workingDirectory) {
        $workingDirectory = [Environment]::GetFolderPath('UserProfile')
    }

    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $info.Arguments = '/s /c "' + $commandLine + '"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.WorkingDirectory = $workingDirectory
        $info.EnvironmentVariables['HERMES_NONINTERACTIVE'] = '1'
        $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) {
            throw 'The Hermes update process did not start.'
        }

        $script:UpdateOperation = [pscustomobject]@{
            Process = $process
            LogFile = $logFile
            StartedAt = [DateTime]::UtcNow
            TimeoutSeconds = 3600
        }
        $script:UpdateInProgress = $true
        $script:UpdateStatusText = 'Starting...'
        $script:UpdateProgressReadAt = [DateTime]::MinValue
        $script:UpdateHeartbeatAt = [DateTime]::UtcNow
        Update-TrayDisplay
        Show-Notification 'Hermes update started' 'The update runs in the background. Hover the tray icon to see progress.'
    }
    catch {
        $script:UpdateInProgress = $false
        Show-CompanionError "Could not start the Hermes update.`n`n$($_.Exception.Message)"
        Restore-DashboardAfterUpdate
        Update-TrayDisplay
    }
}

function Restore-DashboardAfterUpdate {
    if (-not $script:RestartDashboardAfterUpdate) {
        return
    }

    $script:RestartDashboardAfterUpdate = $false
    if (Start-HermesDetached -Arguments @('dashboard', '--no-open')) {
        $script:RefreshPending = $true
    }
}

function Read-LogTailText {
    <#
        Read the end of a file the update process still has open for writing.
        A plain read would be denied, so the share mode has to allow writers.
    #>
    param(
        [string]$Path,
        [int]$ByteCount = 16384
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
    }
    catch {
        return ''
    }

    try {
        if ($stream.Length -gt $ByteCount) {
            $stream.Seek(-$ByteCount, [System.IO.SeekOrigin]::End) | Out-Null
        }
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        try {
            return (Remove-AnsiEscape $reader.ReadToEnd())
        }
        finally {
            $reader.Dispose()
        }
    }
    catch {
        return ''
    }
    finally {
        $stream.Dispose()
    }
}

function Get-UpdateLogTail {
    param([string]$Path)

    $text = Read-LogTailText -Path $Path
    if (-not $text) {
        return ''
    }

    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
    return ((($lines | Select-Object -Last 20) -join "`n").Trim())
}

function Get-UpdateProgressLine {
    <#
        Hermes marks each step of an update with a leading symbol outside
        ASCII. Match on that property rather than on the symbols themselves,
        so this file stays ASCII: PowerShell 5.1 reads a file without a byte
        order mark using the system code page, which would corrupt them.

        Preferring marked lines skips the npm and vite noise the desktop and
        web builds produce.
    #>
    param([string]$Path)

    $text = Read-LogTailText -Path $Path
    if (-not $text) {
        return $null
    }

    $lines = @($text -split "`r?`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) {
        return $null
    }

    $steps = @($lines | Where-Object { $_.TrimStart() -match '^[^\x00-\x7F]' })
    $line = if ($steps.Count -gt 0) { $steps[-1] } else { $lines[-1] }

    return ($line -replace '^[\s]*[^\x00-\x7F\s]+[\s]*', '').Trim()
}

function Format-UpdateElapsed {
    param([TimeSpan]$Elapsed)

    if ($Elapsed.TotalMinutes -lt 1) {
        return "$([int]$Elapsed.TotalSeconds)s"
    }

    return "$([int]$Elapsed.TotalMinutes)m $($Elapsed.Seconds)s"
}

function Update-UpdateProgress {
    $operation = $script:UpdateOperation
    if (-not $operation) {
        return
    }

    $now = [DateTime]::UtcNow
    if (($now - $script:UpdateProgressReadAt).TotalMilliseconds -lt 1000) {
        return
    }
    $script:UpdateProgressReadAt = $now

    $line = Get-UpdateProgressLine $operation.LogFile
    if ($line) {
        $script:UpdateStatusText = $line
    }

    # The tooltip and menu only tell the user something when they look. Send a
    # balloon every few minutes so a long update still reports for itself.
    if (($now - $script:UpdateHeartbeatAt).TotalSeconds -ge 300) {
        $script:UpdateHeartbeatAt = $now
        $elapsed = Format-UpdateElapsed ($now - $operation.StartedAt)
        $detail = if ($script:UpdateStatusText) { $script:UpdateStatusText } else { 'Working...' }
        Show-Notification "Hermes update running - $elapsed" $detail
    }

    Update-TrayDisplay
}

function Get-UpdateCompletionLine {
    param([string]$Path)

    $text = Read-LogTailText -Path $Path -ByteCount 65536
    if ($text -match '(?im)^\s*\S*\s*(Update complete.*)$') {
        return $Matches[1].Trim()
    }

    return $null
}

function Get-UpdateWarningLines {
    <#
        An update can finish successfully and still leave something for the
        user to act on: a stash it could not restore, a step it skipped. Those
        scroll past in a log nobody reads, so surface them explicitly.
    #>
    param([string]$Path)

    $text = Read-LogTailText -Path $Path -ByteCount 4194304
    if (-not $text) {
        return ''
    }

    # Hermes shouts CONFLICT and SKIPPED in capitals. Matching those case
    # sensitively keeps out the lowercase 'skipped' that npm and electron
    # builder print constantly.
    $shouted = 'CONFLICT|SKIPPED'
    $phrases = 'Stash ref:|Restore your changes later|could not restore'
    $lines = @($text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and (($_ -cmatch $shouted) -or ($_ -match $phrases)) } |
        Select-Object -Unique)

    if ($lines.Count -eq 0) {
        return ''
    }

    return ((($lines | Select-Object -First 12) -join "`n").Trim())
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
    $output = Get-UpdateLogTail $operation.LogFile
    $completionLine = Get-UpdateCompletionLine $operation.LogFile
    $warnings = Get-UpdateWarningLines $operation.LogFile

    if ($operation.Process.HasExited) {
        $operation.Process.Dispose()
    }

    $script:UpdateOperation = $null
    $script:UpdateInProgress = $false
    $script:UpdateStatusText = $null

    if ($null -eq $exitCode) {
        $script:RestartDashboardAfterUpdate = $false
        Show-CompanionError "The Hermes update is still running after an hour.`n`nHermes Companion stopped watching it. Check the update output before you start Hermes again:`n$($operation.LogFile)"
    }
    elseif ($exitCode -eq 0) {
        $script:UpdateNotified = $false
        $script:VersionCheckPending = $true
        $script:ProfileRefreshPending = $true
        $summary = if ($completionLine) { $completionLine } else { 'The update finished.' }
        Show-Notification 'Hermes updated' $summary
        if ($warnings) {
            [System.Windows.Forms.MessageBox]::Show(
                "$summary`n`nThe update finished, but it left these notes:`n`n$warnings",
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
        Restore-DashboardAfterUpdate
    }
    else {
        $detail = if ($output) { $output } else { 'Hermes returned no output.' }
        $updateLog = Join-Path $script:LogsPath 'update.log'
        Show-CompanionError "The Hermes update failed with exit code $exitCode.`n`n$detail`n`nHermes keeps the full output in:`n$updateLog"
        Restore-DashboardAfterUpdate
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

# Parser tests dot-source this script to exercise the CLI-output readers
# without loading WinForms or creating the notification-area application.
if ($ParsersOnly) {
    return
}

# Icon construction is eager launch-time work, so it stays after the parser-only exit.
$script:ActiveIcon = New-TrayIcon
$script:MutedIcon = New-TrayIcon -Muted

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

Add-MenuHeading -Menu $menu -Text 'Profiles'

$script:ProfilesMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Hermes profiles'
$script:ProfilesMenu.ToolTipText = 'Profiles configured in Hermes'
$menu.Items.Add($script:ProfilesMenu) | Out-Null
Update-ProfileMenu
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

Add-MenuHeading -Menu $menu -Text 'Tools'

$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Refresh status'
$refreshItem.add_Click({
    $script:ProfileRefreshPending = $true
    Request-StatusRefresh
})
$menu.Items.Add($refreshItem) | Out-Null

$script:CheckUpdateItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Check for updates'
$script:CheckUpdateItem.ToolTipText = 'Ask Hermes whether a newer version is available'
$script:CheckUpdateItem.add_Click({ Request-UpdateCheck })
$menu.Items.Add($script:CheckUpdateItem) | Out-Null

$script:UpdateHermesItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Update Hermes...'
$script:UpdateHermesItem.ToolTipText = 'Install the latest Hermes Agent version'
$script:UpdateHermesItem.add_Click({ Start-HermesUpdate })
$menu.Items.Add($script:UpdateHermesItem) | Out-Null

$script:UpdateLogItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open update log'
$script:UpdateLogItem.ToolTipText = 'Show the output of the Hermes update'
$script:UpdateLogItem.add_Click({
    $path = if ($script:UpdateOperation) { $script:UpdateOperation.LogFile } else { Join-Path $script:LogsPath 'update.log' }
    if (Test-Path -LiteralPath $path) {
        Start-Process notepad.exe -ArgumentList ('"' + $path + '"')
    }
    else {
        Show-CompanionError "No update log exists yet:`n$path"
    }
})
$menu.Items.Add($script:UpdateLogItem) | Out-Null

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
    Update-UpdateProgress
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
    elseif ($script:ProfileRefreshPending) {
        Request-ProfileRefresh
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
        try { $script:ActiveOperation.Process.Kill() } catch { Write-Verbose 'The active Hermes process was already gone during shutdown.' }
        $script:ActiveOperation.Process.Dispose()
    }
    if ($script:UpdateOperation) {
        # Killing a running update would strand a half-installed Hermes.
        try { $script:UpdateOperation.Process.Dispose() } catch { Write-Verbose 'The update process had already released its resources during shutdown.' }
    }
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    $menu.Dispose()
    $script:ActiveIcon.Dispose()
    $script:MutedIcon.Dispose()
    $script:SingleInstanceMutex.ReleaseMutex()
    $script:SingleInstanceMutex.Dispose()
}
