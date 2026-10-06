[CmdletBinding()]
param(
    [string]$ProjectRoot = 'D:\AI-Shared\neruds-control-center',
    [string]$BackupRoot = 'D:\NERUDS-Backups'
)

$ErrorActionPreference = 'Stop'
$python = Join-Path $ProjectRoot 'bridge\.venv\Scripts\python.exe'
$database = Join-Path $ProjectRoot 'data\missions.sqlite3'
& $python (Join-Path $ProjectRoot 'bridge\backup_store.py') --database $database backup --destination $BackupRoot
