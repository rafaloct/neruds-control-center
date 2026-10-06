[CmdletBinding()]
param(
    [string]$ProjectRoot = 'D:\AI-Shared\neruds-control-center',
    [string]$BackupRoot = 'D:\NERUDS-Backups'
)

$ErrorActionPreference = 'Stop'
$python = Join-Path $ProjectRoot 'bridge\.venv\Scripts\python.exe'
$database = Join-Path $ProjectRoot 'data\missions.sqlite3'
$tool = Join-Path $ProjectRoot 'bridge\backup_store.py'

if (-not (Test-Path $python)) {
    throw "Ambiente Python não encontrado em $python."
}
if (-not (Test-Path $database)) {
    throw "Mission store não encontrado em $database."
}

New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
& $python $tool --database $database backup --destination $BackupRoot
if ($LASTEXITCODE -ne 0) {
    throw 'O backup do mission store falhou.'
}
