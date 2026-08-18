[CmdletBinding()]
param(
    [switch]$NoAutoStart,
    [switch]$NoLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$appName = 'Hermes Companion'
$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Hermes Companion'
$startMenuDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) 'Hermes Companion'
$startMenuShortcut = Join-Path $startMenuDirectory 'Hermes Companion.lnk'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hermes Companion.lnk'
$requiredFiles = @('HermesCompanion.ps1', 'HermesCompanion.vbs', 'Uninstall.ps1', 'LICENSE', 'README.md')

foreach ($file in $requiredFiles) {
    $source = Join-Path $PSScriptRoot $file
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required project file is missing: $source"
    }
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $startMenuDirectory -Force | Out-Null

foreach ($file in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $installDirectory $file) -Force
}

$shell = New-Object -ComObject WScript.Shell
$launcherPath = Join-Path $installDirectory 'HermesCompanion.vbs'
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'

$shortcut = $shell.CreateShortcut($startMenuShortcut)
$shortcut.TargetPath = $wscriptPath
$shortcut.Arguments = '"' + $launcherPath + '"'
$shortcut.WorkingDirectory = $installDirectory
$shortcut.Description = 'Manage Hermes Agent from the Windows notification area'
$shortcut.Save()

if (-not $NoAutoStart) {
    $shortcut = $shell.CreateShortcut($startupShortcut)
    $shortcut.TargetPath = $wscriptPath
    $shortcut.Arguments = '"' + $launcherPath + '"'
    $shortcut.WorkingDirectory = $installDirectory
    $shortcut.Description = 'Start Hermes Companion at Windows login'
    $shortcut.Save()
}

if (-not $NoLaunch) {
    Start-Process -FilePath $wscriptPath -ArgumentList ('"' + $launcherPath + '"')
}

Write-Host "Installed $appName to: $installDirectory"
Write-Host "Start Menu shortcut: $startMenuShortcut"
Write-Host "Start with Windows: $(-not $NoAutoStart)"
