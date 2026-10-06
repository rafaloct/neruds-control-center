# Changelog

Todas as mudanças relevantes serão registradas neste arquivo.

## [Unreleased]

### Added

- automação da missão (Onda 2 do roadmap):
  - `GET /missions/{id}/automation` com sugestão de próximas tarefas P0/P1,
    itens sem evidência, possíveis duplicidades e estado da verificação de
    URLs públicas;
  - `POST /missions/{id}/url-check` para verificar URLs públicas em lotes
    com proteção SSRF e persistência do último resultado;
  - `GET /mission-tasks/{id}/drupal-duplicates` consultando o JSON:API do
    Drupal por título no bundle correspondente ao tipo de conteúdo;
  - card "Sugestões automáticas" na tela Missão do app Flutter;
  - nenhuma automação conclui ou altera etapa de tarefa automaticamente.

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
