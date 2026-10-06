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

$bridgeRoot = Join-Path $ProjectRoot 'bridge'
$python = Join-Path $bridgeRoot '.venv\Scripts\python.exe'
$serviceScript = Join-Path $bridgeRoot 'windows_service.py'

if (-not (Test-Path $python)) {
    throw "Ambiente Python não encontrado em $python. Execute 'uv sync' em $bridgeRoot primeiro."
}
if (-not (Test-Path $serviceScript)) {
    throw "Wrapper do serviço não encontrado em $serviceScript."
}

& $python -c 'import win32serviceutil' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "pywin32 não está disponível no ambiente Windows. Execute 'uv sync' em $bridgeRoot."
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$created = $null -eq $existing

try {
    if ($existing) {
        if ($existing.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force
            $existing.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
        }
        & $python $serviceScript --startup auto update
    } else {
        & $python $serviceScript --startup auto install
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'pywin32 não conseguiu instalar/atualizar o serviço.'
    }

    & sc.exe description $ServiceName "NERUDS Control Bridge - FastAPI local em 127.0.0.1:8787"
    & sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000
    & sc.exe failureflag $ServiceName 1

    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus(
        'Running',
        [TimeSpan]::FromSeconds(20)
    )

    $ready = $null
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        try {
            $ready = Invoke-RestMethod 'http://127.0.0.1:8787/ready' -TimeoutSec 2
            if ($ready.ok -eq $true) { break }
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    if (-not $ready -or $ready.ok -ne $true) {
        throw 'O serviço iniciou, mas o endpoint /ready não confirmou prontidão.'
    }

    Write-Host "Serviço '$ServiceName' instalado e pronto para iniciar automaticamente no boot."
    Write-Host 'Confirme o Tailscale Serve antes de remover qualquer launcher legado de Startup.'
}
catch {
    if ($created) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        & $python $serviceScript remove 2>$null | Out-Null
    }
    throw
}
