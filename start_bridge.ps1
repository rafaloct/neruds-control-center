$ErrorActionPreference = 'Stop'
Set-Location 'D:\AI-Shared\neruds-control-center\bridge'
$bridgeHost = '127.0.0.1'
Write-Host "NERUDS Control Bridge local em http://${bridgeHost}:8787"
Write-Host "Acesso tailnet: https://largeo.tail2faed0.ts.net:8443"
uv run uvicorn main:app --host $bridgeHost --port 8787
