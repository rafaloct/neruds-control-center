$ErrorActionPreference = 'Continue'
$root = Join-Path $PSScriptRoot 'app\build\web'
$health = 'http://127.0.0.1:8790/'
Set-Location $root

while ($true) {
  try {
    $response = Invoke-WebRequest -Uri $health -UseBasicParsing -TimeoutSec 3
    if ($response.StatusCode -eq 200) {
      Start-Sleep -Seconds 20
      continue
    }
  }
  catch {
  }

  try {
    & python -m http.server 8790 --bind 127.0.0.1 --directory $root
  }
  catch {
  }

  Start-Sleep -Seconds 5
}
