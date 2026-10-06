# Changelog

Todas as mudanças relevantes serão registradas neste arquivo.

## [Unreleased]

### Security

- removidos identificadores de infra interna (hostname Tailscale, IPs tailnet, hostname do VPS, paths locais de operação) do código, scripts e documentação, preparando o repositório para visibilidade pública;
- app Flutter passa a exigir `--dart-define=NERUDS_BRIDGE_URL` para as funções privadas — sem bridge configurada, permanece apenas a leitura pública do portal;
- defaults do bridge para host VPS, origens CORS e SMTP agora são vazios — os endpoints `/infra/status` e `/mail/status` degradam para "não configurado" em vez de apontar para infra real;
- `.env.example` virou template com placeholders; valores reais ficam no `.env` local e em GitHub Secrets;
- scripts de operação (`start_bridge.ps1`, `bridge_supervisor.ps1`, `web_supervisor.ps1`, `NERUDS-Control-Center.ps1`, `export_mission_seed.ps1`, `e2e_extensionista.sh`) agora derivam caminhos do próprio checkout ou de variáveis de ambiente.

## [1.0.0-internal.1] - 2026-10-05

### Added

- aplicativo Flutter para Windows, Web e Android;
- autenticação delegada ao Drupal;
- papel Extensionista com privilégio mínimo;
- guarda server-side de rascunhos;
- missão operacional com 278 verificações;
- radar de oportunidades RSS/manual;
- revisão/auditoria básica;
- Poste.io integrado para notificações;
- TLS Let's Encrypt para `mail.neruds.org`;
- bridge privado via Tailscale Serve HTTPS;
- E2E de Extensionista com login, missão, rascunho e e-mail;
- design system e skill de UI/UX usada no desenvolvimento.

### Security

- senhas Drupal não persistidas;
- sessões somente em memória com TTL;
- rascunhos de Extensionista forçados a não publicados;
- bridge escuta somente em loopback;
- arquivos de segredo, bancos e builds excluídos do Git.
