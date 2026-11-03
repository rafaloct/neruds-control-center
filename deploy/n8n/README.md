# Automação n8n — NERUDS Control Center

Workflows que eliminam o preenchimento manual dos artefatos de
acompanhamento. Executam no n8n existente em `srv1533541`
(`n8n.ipexdesenvolvimento.cloud`, container `kreativ-n8n`).

## `neruds-planilha-acompanhamento.json`

Gera a planilha de acompanhamento da missão todos os dias e sob demanda:

```text
Schedule 07h BRT ─┐
                  ├─> login servico.neruds ─> GET /missions/1/export.xlsx
Webhook POST ─────┘        │                     (bridge, sessão efêmera)
   /webhook/neruds-        │
   planilha-export         ├─> grava /home/node/.n8n-files/neruds/*.xlsx
                           └─> envia e-mail com anexo (Gmail SMTP)
```

### Conta de serviço

`servico.neruds` (Drupal, papel `authenticated` apenas) — login feito a cada
execução, sem token armazenado. Senha fica no nó "Login no bridge" do
workflow importado (**não** no arquivo do repo — placeholder
`PREENCHER_SENHA_SERVICO`).

### Importar

```bash
# no srv1533541, com o JSON já injetado com a senha real:
docker cp neruds-wf.json kreativ-n8n:/tmp/
docker exec kreativ-n8n n8n import:workflow --input=/tmp/neruds-wf.json
docker exec kreativ-n8n n8n update:workflow --id=<id> --active=true
docker restart kreativ-n8n   # registra webhook e agenda o cron
```

O import exige campo `id` no workflow. O destino de escrita precisa estar
dentro de `~/.n8n-files` (restrição padrão do n8n, `restrictFileAccessTo`).

### Credencial SMTP

`NERUDS SMTP Gmail` (`nrudsSmtpGmail001`) — importada via
`n8n import:credentials` a partir do `N8N_SMTP_*` já configurado no container
(Gmail com app password). O egress SMTP do host permite smtp.gmail.com:587.
