$ErrorActionPreference = 'Continue'
# Supervisor do bridge: mantém o uvicorn vivo e sobe de novo se cair.
# Executado pelo agendador de tarefas NERUDSBridge (tools/install_bridge_service.ps1)
# ou manualmente em sessão de depuração.
$root = 'D:\AI-Shared\neruds-control-center\bridge'
$health = 'http://127.0.0.1:8787/health'
$logDir = Join-Path $root '..\data\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'supervisor.log'
Set-Location $root

# Prefere o python do venv do projeto: não depende de PATH nem do perfil do
# usuário quando a tarefa roda como SYSTEM sem logon interativo.
$venvPython = Join-Path $root '.venv\Scripts\python.exe'

function Start-Bridge {
  if (Test-Path $venvPython) {
    & $venvPython -m uvicorn main:app --host 127.0.0.1 --port 8787 *>> $logFile
  } else {
    & uv run uvicorn main:app --host 127.0.0.1 --port 8787 *>> $logFile
  }
}

"$(Get-Date -Format o) supervisor iniciado" | Out-File -Append -Encoding utf8 $logFile

while ($true) {
  try {
    $status = Invoke-RestMethod -Uri $health -TimeoutSec 3
    if ($status.ok) {
      Start-Sleep -Seconds 20
      continue
    }
  }
  catch {
  }

  "$(Get-Date -Format o) uvicorn ausente — reiniciando" | Out-File -Append -Encoding utf8 $logFile
  try {
    Start-Bridge
  }
  catch {
    "$(Get-Date -Format o) falha ao iniciar: $($_.Exception.Message)" |
      Out-File -Append -Encoding utf8 $logFile
  }

  Start-Sleep -Seconds 5
}
