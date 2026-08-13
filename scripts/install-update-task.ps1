[CmdletBinding()]
param(
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'

$taskName = 'Kindle AI Quota Dashboard Update'
$updateScript = Join-Path $PSScriptRoot 'update-dashboard.ps1'
if (-not (Test-Path -LiteralPath $updateScript -PathType Leaf)) {
    throw "Update script was not found: $updateScript"
}
$hiddenLauncher = Join-Path $PSScriptRoot 'run-update-hidden.vbs'
if (-not (Test-Path -LiteralPath $hiddenLauncher -PathType Leaf)) {
    throw "Hidden update launcher was not found: $hiddenLauncher"
}

$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$arguments = '"{0}"' -f $hiddenLauncher
$action = New-ScheduledTaskAction -Execute $wscript -Argument $arguments
$repeatTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)
$logonTrigger = New-ScheduledTaskTrigger `
    -AtLogOn `
    -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($repeatTrigger, $logonTrigger) `
    -Settings $settings `
    -Principal $principal `
    -Description 'Collect Codex quota and Yangzhou weather every five minutes, then publish the Kindle dashboard.' `
    -Force | Out-Null

if ($RunNow) {
    Start-ScheduledTask -TaskName $taskName
}

Get-ScheduledTask -TaskName $taskName |
    Select-Object TaskName, State
