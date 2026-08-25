[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$startMenuDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) 'Hermes Companion'
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hermes Companion.lnk'
$sourceScript = Join-Path $PSScriptRoot 'HermesCompanion.ps1'

$companionProcesses = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($sourceScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 }

foreach ($process in $companionProcesses) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force
}
if (Test-Path -LiteralPath $startMenuDirectory) {
    Remove-Item -LiteralPath $startMenuDirectory -Recurse -Force
}

# These are the terminal launcher scripts the companion generated.
$terminalLaunchers = Get-ChildItem -Path $env:TEMP -Filter 'HermesCompanion-*.cmd' -ErrorAction SilentlyContinue
foreach ($terminalLauncher in $terminalLaunchers) {
    Remove-Item -LiteralPath $terminalLauncher.FullName -Force
}

Write-Output 'Hermes Companion shortcuts and terminal launcher scripts were removed and the source checkout was left unchanged.'
Write-Output 'Hermes Agent and its gateway were not changed.'
