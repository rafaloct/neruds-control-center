$ErrorActionPreference = 'Continue'
# Supervisor do bridge: mantém o uvicorn vivo e sobe de novo se cair.
# Executado pelo agendador de tarefas NERUDSBridge (tools/install_bridge_service.ps1)
# ou manualmente em sessão de depuração.
# O root deriva do local deste script — acompanha o -RepoRoot da instalação.
$repoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { 'D:\AI-Shared\neruds-control-center' }
$root = Join-Path $repoRoot 'bridge'
$health = 'http://127.0.0.1:8787/health'
$logDir = Join-Path $repoRoot 'data\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'supervisor.log'
$maxLogBytes = 5MB
Set-Location $root

# Prefere o python do venv do projeto: não depende de PATH nem do perfil do
# usuário quando a tarefa roda como SYSTEM sem logon interativo.
$venvPython = Join-Path $root '.venv\Scripts\python.exe'

function Protect-LogSize {
  # Mantém no máximo uma geração anterior: supervisor.log.old
  if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt $maxLogBytes) {
    Move-Item $logFile "$logFile.old" -Force
  }
}

function Write-SupLog($msg) {
  Protect-LogSize
  "$(Get-Date -Format o) $msg" | Out-File -Append -Encoding utf8 $logFile
}

function Start-Bridge {
  Protect-LogSize
  if (Test-Path $venvPython) {
    & $venvPython -m uvicorn main:app --host 127.0.0.1 --port 8787 *>> $logFile
  } else {
    & uv run uvicorn main:app --host 127.0.0.1 --port 8787 *>> $logFile
  }
}

Write-SupLog 'supervisor iniciado'

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

  Write-SupLog 'uvicorn ausente — reiniciando'
  try {
    Start-Bridge
  }
  catch {
    Write-SupLog "falha ao iniciar: $($_.Exception.Message)"
  }

  Start-Sleep -Seconds 5
}
