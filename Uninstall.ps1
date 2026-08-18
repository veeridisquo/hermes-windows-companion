[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Hermes Companion'
$startMenuDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) 'Hermes Companion'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hermes Companion.lnk'
$installedScript = Join-Path $installDirectory 'HermesCompanion.ps1'

$companionProcesses = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($installedScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 }

foreach ($process in $companionProcesses) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force
}
if (Test-Path -LiteralPath $startMenuDirectory) {
    Remove-Item -LiteralPath $startMenuDirectory -Recurse -Force
}

$resolvedPrograms = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
$resolvedInstall = [IO.Path]::GetFullPath($installDirectory)
if (-not $resolvedInstall.StartsWith($resolvedPrograms, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($resolvedInstall) -ne 'Hermes Companion') {
    throw "Refusing to remove unexpected install path: $resolvedInstall"
}

if (Test-Path -LiteralPath $resolvedInstall) {
    Remove-Item -LiteralPath $resolvedInstall -Recurse -Force
}

Write-Host 'Hermes Companion was removed. Hermes Agent and its gateway were not changed.'
