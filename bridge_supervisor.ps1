$ErrorActionPreference = 'Continue'
$root = 'D:\AI-Shared\neruds-control-center\bridge'
$health = 'http://127.0.0.1:8787/health'
Set-Location $root

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

  try {
    & uv run uvicorn main:app --host 127.0.0.1 --port 8787
  }
  catch {
  }

  Start-Sleep -Seconds 5
}
