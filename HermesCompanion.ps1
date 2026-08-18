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

function Update-TrayDisplay {
    if (-not $script:HermesPath -or $script:LastError) {
        $script:TrayIcon.Icon = $script:MutedIcon
        $script:TrayIcon.Text = 'Hermes Companion - unavailable'
        $script:GatewaySummaryItem.Text = 'Gateway: unavailable'
        $script:DashboardSummaryItem.Text = 'Dashboard: unknown'
        $script:OpenDashboardItem.Enabled = $false
        $script:DesktopItem.Enabled = $false
        $script:StartDashboardItem.Enabled = $false
        $script:StopDashboardItem.Enabled = $false
        $script:GatewayStatusItem.Enabled = $false
        $script:GatewayStartItem.Enabled = $false
        $script:GatewayStopItem.Enabled = $false
        $script:GatewayRestartItem.Enabled = $false
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
        $script:StartupItem.ShortcutKeyDisplayString = if (Test-Path -LiteralPath $script:StartupShortcut) { 'On' } else { 'Off' }
    }
    catch {
        $script:StartupItem.ShortcutKeyDisplayString = if (Test-Path -LiteralPath $script:StartupShortcut) { 'On' } else { 'Off' }
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
$menu.MinimumSize = New-Object System.Drawing.Size 230, 0
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
$script:DashboardSummaryItem.Margin = New-Object System.Windows.Forms.Padding 4, 0, 4, 4
$menu.Items.Add($script:DashboardSummaryItem) | Out-Null
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

$script:StartupItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
$script:StartupItem.ShowShortcutKeys = $true
$script:StartupItem.ShortcutKeyDisplayString = if (Test-Path -LiteralPath $script:StartupShortcut) { 'On' } else { 'Off' }
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
    Complete-ActiveOperation
    if (-not $script:ActiveOperation -and $script:RefreshPending) {
        Request-StatusRefresh
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
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    $menu.Dispose()
    $script:ActiveIcon.Dispose()
    $script:MutedIcon.Dispose()
    $script:SingleInstanceMutex.ReleaseMutex()
    $script:SingleInstanceMutex.Dispose()
}
