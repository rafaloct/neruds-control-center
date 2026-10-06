[CmdletBinding()]
param(
    [string]$ProjectRoot = 'D:\AI-Shared\neruds-control-center',
    [string]$BackupRoot = 'D:\NERUDS-Backups'
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$adminPrincipal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $adminPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Execute este script em um PowerShell elevado (Administrador).'
}

$script = Join-Path $ProjectRoot 'tools\operations\backup_mission_store.ps1'
if (-not (Test-Path $script)) {
    throw "Script de backup não encontrado em $script."
}
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

$argument = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -ProjectRoot "' + $ProjectRoot + '" -BackupRoot "' + $BackupRoot + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
$trigger = New-ScheduledTaskTrigger -Daily -At 02:00
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'NERUDS-Control-Backup' -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrincipal -Force | Out-Null
Write-Host "Backup automático diário instalado. Destino local: $BackupRoot"
Write-Host 'Configure retenção/cópia externa segundo a política institucional; o script não envia dados para terceiros.'
