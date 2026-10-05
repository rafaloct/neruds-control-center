$ErrorActionPreference = 'Stop'

$bridgeUrl = 'http://127.0.0.1:8787'
$projectRoot = 'D:\AI-Shared\neruds-control-center'
$bridgeRoot = Join-Path $projectRoot 'bridge'
$appExe = Join-Path $projectRoot 'app\build\windows\x64\runner\Release\neruds_control_center.exe'

function Test-NerudsBridge {
    try {
        $health = Invoke-RestMethod -Uri "$bridgeUrl/health" -TimeoutSec 2
        return ($health.ok -eq $true -and $health.version -eq '0.3.3')
    }
    catch {
        return $false
    }
}

if (-not (Test-NerudsBridge)) {
    $uv = (Get-Command uv -ErrorAction Stop).Source
    Start-Process -FilePath $uv -ArgumentList @(
        'run', 'uvicorn', 'main:app',
        '--host', '127.0.0.1',
        '--port', '8787'
    ) -WorkingDirectory $bridgeRoot -WindowStyle Hidden

    $ready = $false
    1..12 | ForEach-Object {
        Start-Sleep -Milliseconds 500
        if (Test-NerudsBridge) {
            $ready = $true
            return
        }
    }

    if (-not $ready) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            'O serviço local do NERUDS não iniciou. Verifique a Tailscale e tente novamente.',
            'NERUDS Control Center'
        ) | Out-Null
        exit 1
    }
}

if (-not (Test-Path $appExe)) {
    throw "Executável não encontrado: $appExe"
}

Start-Process -FilePath $appExe -WorkingDirectory (Split-Path $appExe)
