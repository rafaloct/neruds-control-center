[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BackupFile,
    [string]$ProjectRoot = 'D:\AI-Shared\neruds-control-center',
    [string]$ServiceName = 'NERUDS-Control-Bridge'
)

$ErrorActionPreference = 'Stop'

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') {
    throw "Pare o serviço '$ServiceName' antes de restaurar o mission store."
}

$python = Join-Path $ProjectRoot 'bridge\.venv\Scripts\python.exe'
$database = Join-Path $ProjectRoot 'data\missions.sqlite3'
if (-not (Test-Path $python)) {
    throw "Ambiente Python não encontrado em $python."
}
if (-not (Test-Path $BackupFile)) {
    throw "Backup não encontrado: $BackupFile"
}

& $python (Join-Path $ProjectRoot 'bridge\backup_store.py') --database $database restore --source $BackupFile
if ($LASTEXITCODE -ne 0) {
    throw 'A restauração falhou.'
}
Write-Host 'Restauração concluída. Inicie o serviço e valide /ready antes de liberar o uso.'
