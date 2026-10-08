$ErrorActionPreference = 'Stop'
Set-Location 'D:\AI-Shared\neruds-control-center\bridge'
# O RotatingFileHandler abre o arquivo antes da app criar data/logs.
New-Item -ItemType Directory -Force -Path '..\data\logs' | Out-Null
$bridgeHost = '127.0.0.1'
Write-Host "NERUDS Control Bridge local em http://${bridgeHost}:8787"
Write-Host "Acesso tailnet: https://largeo.tail2faed0.ts.net:8443"
uv run uvicorn main:app --host $bridgeHost --port 8787 --no-access-log --log-config tools\uvicorn-logging.json
