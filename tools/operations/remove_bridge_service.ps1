[CmdletBinding()]
param(
    [string]$ProjectRoot = 'D:\AI-Shared\neruds-control-center',
    [string]$ServiceName = 'NERUDS-Control-Bridge'
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Execute este script em um PowerShell elevado (Administrador).'
}

$python = Join-Path $ProjectRoot 'bridge\.venv\Scripts\python.exe'
$serviceScript = Join-Path $ProjectRoot 'bridge\windows_service.py'

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Host "Serviço '$ServiceName' não está instalado."
    exit 0
}

if ($service.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceName -Force
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
}

& $python $serviceScript remove
if ($LASTEXITCODE -ne 0) {
    throw "Não foi possível remover o serviço '$ServiceName'."
}
Write-Host "Serviço '$ServiceName' removido."
