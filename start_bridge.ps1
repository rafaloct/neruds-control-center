$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot 'bridge')
$bridgeHost = '127.0.0.1'
Write-Host "NERUDS Control Bridge local em http://${bridgeHost}:8787"
Write-Host "Exposição tailnet: publicar via 'tailscale serve' na porta HTTPS escolhida (ver README.md)."
uv run uvicorn main:app --host $bridgeHost --port 8787
