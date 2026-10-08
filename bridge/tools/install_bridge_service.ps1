#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Registra o bridge do NERUDS como tarefa agendada que inicia com o Windows,
  independente de logon de usuário.

.DESCRIPTION
  Cria a tarefa "NERUDSBridge" (ONSTART, conta SYSTEM) que executa
  bridge_supervisor.ps1. O supervisor mantém o uvicorn vivo e o reinicia
  se o processo cair. Reversível com:

    Unregister-ScheduledTask -TaskName 'NERUDSBridge' -Confirm:$false

  Uso (PowerShell elevado, no LARGeo):

    powershell -ExecutionPolicy Bypass -File bridge\tools\install_bridge_service.ps1

  Parâmetro opcional: -RepoRoot <pasta do repositório>
#>
param(
  [string]$RepoRoot = 'D:\AI-Shared\neruds-control-center'
)

$ErrorActionPreference = 'Stop'
$taskName = 'NERUDSBridge'
$supervisor = Join-Path $RepoRoot 'bridge_supervisor.ps1'

if (-not (Test-Path $supervisor)) {
  throw "bridge_supervisor.ps1 não encontrado em $RepoRoot"
}

$action = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$supervisor`"" `
  -WorkingDirectory (Join-Path $RepoRoot 'bridge')

$trigger = New-ScheduledTaskTrigger -AtStartup

# SYSTEM: sem senha, sem necessidade de logon interativo.
$principal = New-ScheduledTaskPrincipal `
  -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries

Register-ScheduledTask `
  -TaskName $taskName `
  -Action $action `
  -Trigger $trigger `
  -Principal $principal `
  -Settings $settings `
  -Description 'NERUDS Control Bridge (uvicorn 127.0.0.1:8787) — supervisor com reinício automático' `
  -Force | Out-Null

Write-Host "Tarefa '$taskName' registrada (ONSTART, SYSTEM)." -ForegroundColor Green
Write-Host "Inicie agora com: Start-ScheduledTask -TaskName '$taskName'"
Write-Host "Valide com:        Invoke-RestMethod http://127.0.0.1:8787/ready"
