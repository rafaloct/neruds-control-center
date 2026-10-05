# Changelog

Todas as mudanças relevantes serão registradas neste arquivo.

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
