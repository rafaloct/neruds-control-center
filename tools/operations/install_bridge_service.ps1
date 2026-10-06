[CmdletBinding()]
param(
    [string]$ProjectRoot = 'D:\AI-Shared\neruds-control-center',
    [string]$TaskName = 'NERUDS-Control-Bridge'
)

$ErrorActionPreference = 'Stop'
$bridgeRoot = Join-Path $ProjectRoot 'bridge'
$python = Join-Path $bridgeRoot '.venv\Scripts\python.exe'
if (-not (Test-Path $python)) {
    throw "Ambiente Python não encontrado em $python. Execute 'uv sync' em $bridgeRoot primeiro."
}

$action = New-ScheduledTaskAction -Execute $python -Argument '-m uvicorn main:app --host 127.0.0.1 --port 8787' -WorkingDirectory $bridgeRoot
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 0)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Tarefa de serviço '$TaskName' instalada para iniciar no boot como SYSTEM."
