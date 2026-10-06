[CmdletBinding()]
param(
    [string]$ProjectRoot = 'D:\AI-Shared\neruds-control-center',
    [string]$BackupRoot = 'D:\NERUDS-Backups'
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $ProjectRoot 'tools\operations\backup_mission_store.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -ProjectRoot `"$ProjectRoot`" -BackupRoot `"$BackupRoot`""
$trigger = New-ScheduledTaskTrigger -Daily -At 02:00
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'NERUDS-Control-Backup' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Backup automático diário instalado. Retenha e copie $BackupRoot para armazenamento externo."
