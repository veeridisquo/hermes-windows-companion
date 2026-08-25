[CmdletBinding()]
param(
    [switch]$NoAutoStart,
    [switch]$NoLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$appName = 'Hermes Companion'
$sourceDirectory = [IO.Path]::GetFullPath($PSScriptRoot)
$startMenuDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) 'Hermes Companion'
$startMenuShortcut = Join-Path $startMenuDirectory 'Hermes Companion.lnk'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hermes Companion.lnk'
$requiredFiles = @('HermesCompanion.ps1', 'HermesCompanion.vbs', 'hermes-agent.ico')

foreach ($file in $requiredFiles) {
    $source = Join-Path $PSScriptRoot $file
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Required project file is missing: $source"
    }
}

New-Item -ItemType Directory -Path $startMenuDirectory -Force | Out-Null

$shell = New-Object -ComObject WScript.Shell
$launcherPath = Join-Path $sourceDirectory 'HermesCompanion.vbs'
$iconPath = Join-Path $sourceDirectory 'hermes-agent.ico'
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'

$shortcut = $shell.CreateShortcut($startMenuShortcut)
$shortcut.TargetPath = $wscriptPath
$shortcut.Arguments = '"' + $launcherPath + '"'
$shortcut.WorkingDirectory = $sourceDirectory
$shortcut.Description = 'Manage Hermes Agent from the Windows notification area'
$shortcut.IconLocation = "$iconPath,0"
$shortcut.Save()

if (-not $NoAutoStart) {
    $shortcut = $shell.CreateShortcut($startupShortcut)
    $shortcut.TargetPath = $wscriptPath
    $shortcut.Arguments = '"' + $launcherPath + '"'
    $shortcut.WorkingDirectory = $sourceDirectory
    $shortcut.Description = 'Start Hermes Companion at Windows login'
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Save()
}
elseif (Test-Path -LiteralPath $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force
}

if (-not $NoLaunch) {
    Start-Process -FilePath $wscriptPath -ArgumentList ('"' + $launcherPath + '"')
}

Write-Output "Registered $appName from: $sourceDirectory"
Write-Output "Start Menu shortcut: $startMenuShortcut"
Write-Output "Start with Windows: $(-not $NoAutoStart)"
