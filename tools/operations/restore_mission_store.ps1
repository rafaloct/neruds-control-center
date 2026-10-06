[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$BackupFile,
    [string]$ProjectRoot = 'D:\AI-Shared\neruds-control-center'
)

$ErrorActionPreference = 'Stop'
$python = Join-Path $ProjectRoot 'bridge\.venv\Scripts\python.exe'
$database = Join-Path $ProjectRoot 'data\missions.sqlite3'
& $python (Join-Path $ProjectRoot 'bridge\backup_store.py') --database $database restore --source $BackupFile
