# Sincroniza o bridge/.env real do LARGeo para os GitHub Secrets do repo.
# Executar na máquina onde o .env de produção existe (nunca commitar o .env).
#
# Uso:  powershell -File tools/operations/sync_github_secrets.ps1 [-EnvFile bridge/.env] [-Repo rafaloct/neruds-control-center] [-DryRun]
#
# Pré-requisitos: gh autenticado com scope repo ("gh auth login" ou GH_TOKEN).
# A variável GITHUB_TOKEN inválida desta máquina é ignorada via -u no fallback keyring.

param(
    [string]$EnvFile = (Join-Path $PSScriptRoot "..\..\bridge\.env"),
    [string]$Repo = "rafaloct/neruds-control-center",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFile)) {
    Write-Error "Arquivo não encontrado: $EnvFile"
    exit 1
}

# Variáveis cujos valores reais devem viver apenas em GitHub Secrets.
# Configurações não sensíveis (porta, flags) também entram aqui para que o
# .env.example público possa ficar 100% com placeholders.
$AllowedKeys = @(
    "NERUDS_PORTAL_URL",
    "NERUDS_VPS_TAILSCALE_HOST",
    "NERUDS_SESSION_IDLE_HOURS",
    "NERUDS_ALLOWED_ORIGINS",
    "NERUDS_SMTP_HOST",
    "NERUDS_SMTP_CONNECT_HOST",
    "NERUDS_SMTP_PORT",
    "NERUDS_SMTP_STARTTLS",
    "NERUDS_SMTP_USER",
    "NERUDS_SMTP_PASSWORD",
    "NERUDS_SMTP_FROM",
    "NERUDS_SMTP_REVIEW_TO",
    "NERUDS_SSH_USER",
    "NERUDS_SSH_KEY_PATH",
    "NERUDS_AUDIT_DB"
)

$written = 0
$skipped = 0
foreach ($line in Get-Content $EnvFile) {
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith("#") -or $line -notmatch "=") { continue }
    $name, $value = $line.Split("=", 2)
    $name = $name.Trim()
    $value = $value.Trim()
    if ($AllowedKeys -notcontains $name) {
        Write-Host "IGNORADO (fora da lista): $name"
        continue
    }
    if (-not $value) {
        Write-Host "VAZIO (não gravado): $name"
        $skipped++
        continue
    }
    if ($DryRun) {
        Write-Host "DRY-RUN gravaria: $name ($($value.Length) chars)"
        $written++
        continue
    }
    $value | & gh secret set $name --repo $Repo
    if ($LASTEXITCODE -ne 0) { throw "gh secret set falhou para $name" }
    Write-Host "OK $name"
    $written++
}

Write-Host ""
Write-Host "Concluído: $written secrets gravados, $skipped vazios ignorados."
Write-Host "Verifique com: gh secret list --repo $Repo"
