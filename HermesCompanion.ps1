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

function New-StatusIcon {
    param([System.Drawing.Color]$Color)

    $bitmap = New-Object System.Drawing.Bitmap 16, 16
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $baseImage = $null
    if (Test-Path -LiteralPath $script:IconImagePath) {
        $baseImage = [System.Drawing.Image]::FromFile($script:IconImagePath)
        $graphics.DrawImage($baseImage, 0, 0, 16, 16)
    }

    $brush = New-Object System.Drawing.SolidBrush $Color
    $outlinePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
    if ($baseImage) {
        $graphics.FillEllipse($brush, 10, 10, 5, 5)
        $graphics.DrawEllipse($outlinePen, 9, 9, 6, 6)
    }
    else {
        $graphics.FillEllipse($brush, 2, 2, 11, 11)
        $graphics.DrawEllipse($outlinePen, 2, 2, 11, 11)
    }

    $handle = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($handle).Clone()
    [HermesCompanionNativeMethods]::DestroyIcon($handle) | Out-Null
    if ($baseImage) { $baseImage.Dispose() }
    $outlinePen.Dispose()
    $brush.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    return $icon
}

$script:GreenIcon = New-StatusIcon ([System.Drawing.Color]::FromArgb(38, 166, 91))
$script:YellowIcon = New-StatusIcon ([System.Drawing.Color]::FromArgb(245, 166, 35))
$script:RedIcon = New-StatusIcon ([System.Drawing.Color]::FromArgb(208, 57, 64))

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
        $script:TrayIcon.Icon = $script:RedIcon
        $script:TrayIcon.Text = 'Hermes Companion - unavailable'
        $script:StatusItem.Text = 'Status: Hermes unavailable'
        return
    }

    if ($script:GatewayRunning) {
        $script:TrayIcon.Icon = $script:GreenIcon
        $script:TrayIcon.Text = 'Hermes Companion - gateway running'
        $gatewayText = 'running'
    }
    else {
        $script:TrayIcon.Icon = $script:YellowIcon
        $script:TrayIcon.Text = 'Hermes Companion - gateway stopped'
        $gatewayText = 'stopped'
    }

    $dashboardText = if ($script:DashboardRunning) { 'running' } else { 'stopped' }
    $script:StatusItem.Text = "Gateway: $gatewayText | Dashboard: $dashboardText"
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
        $script:StartupItem.Checked = Test-Path -LiteralPath $script:StartupShortcut
    }
    catch {
        $script:StartupItem.Checked = Test-Path -LiteralPath $script:StartupShortcut
        Show-CompanionError "Could not update startup settings.`n`n$($_.Exception.Message)"
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$createdNew = $false
$script:SingleInstanceMutex = New-Object System.Threading.Mutex($true, "Local\HermesCompanion_$identity", [ref]$createdNew)
if (-not $createdNew) {
    $script:SingleInstanceMutex.Dispose()
    exit 0
}

$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = $script:YellowIcon
$script:TrayIcon.Text = 'Hermes Companion - checking status'
$script:TrayIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Status: checking...'
$script:StatusItem.Enabled = $false
$menu.Items.Add($script:StatusItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$openDashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Dashboard'
$openDashboardItem.add_Click({ Open-Dashboard })
$menu.Items.Add($openDashboardItem) | Out-Null

$startDashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start Dashboard'
$startDashboardItem.add_Click({ Start-Dashboard })
$menu.Items.Add($startDashboardItem) | Out-Null

$stopDashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop Dashboard'
$stopDashboardItem.add_Click({ Stop-Dashboard })
$menu.Items.Add($stopDashboardItem) | Out-Null

$desktopItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Hermes Desktop'
$desktopItem.add_Click({ Open-HermesDesktop })
$menu.Items.Add($desktopItem) | Out-Null

$gatewayMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Gateway'
$gatewayStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Show Status'
$gatewayStatusItem.add_Click({ Show-GatewayStatus })
$gatewayMenu.DropDownItems.Add($gatewayStatusItem) | Out-Null
$gatewayMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

foreach ($action in @('Start', 'Stop', 'Restart')) {
    $actionItem = New-Object System.Windows.Forms.ToolStripMenuItem "$action Gateway"
    $capturedAction = $action.ToLowerInvariant()
    $actionItem.add_Click({ Invoke-GatewayAction $capturedAction }.GetNewClosure())
    $gatewayMenu.DropDownItems.Add($actionItem) | Out-Null
}
$menu.Items.Add($gatewayMenu) | Out-Null

$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Refresh Status'
$refreshItem.add_Click({ Request-StatusRefresh })
$menu.Items.Add($refreshItem) | Out-Null

$logsItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Hermes Logs'
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

$script:StartupItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
$script:StartupItem.CheckOnClick = $true
$script:StartupItem.Checked = Test-Path -LiteralPath $script:StartupShortcut
$script:StartupItem.add_Click({ Set-StartupEnabled $script:StartupItem.Checked })
$menu.Items.Add($script:StartupItem) | Out-Null

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit Hermes Companion'
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
    $script:GreenIcon.Dispose()
    $script:YellowIcon.Dispose()
    $script:RedIcon.Dispose()
    $script:SingleInstanceMutex.ReleaseMutex()
    $script:SingleInstanceMutex.Dispose()
}
