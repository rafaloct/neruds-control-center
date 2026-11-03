# Changelog

Todas as mudanças relevantes serão registradas neste arquivo.

## [Unreleased]

### Added

- criação de rascunho por tipo de conteúdo (`GET /content/types` +
  `POST /content/{bundle}/draft`):
  - o app passa a oferecer todos os tipos que a sessão pode criar no
    Drupal — o próprio `/node/add/{bundle}` decide o acesso (extensionista
    vê notícia/relatório; coordenação vê os demais);
  - campos obrigatórios por tipo descritos no `CONTENT_BUNDLES` (ex.:
    evento científico pede data + local; projeto pede coordenador) e o
    formulário do app os exige antes de enviar — sem depender de rebuild
    para aparecer novos tipos permitidos;
  - Editorial: seletor "Tipo de conteúdo" com campos dinâmicos (data com
    calendário, texto livre), título e instruções adaptados ao tipo;
  - `/content/news/draft` preservado como caminho compatível;
- migração de idioma do portal (executada em produção, fora do código):
  - 337 nodes, 441 termos de taxonomia, 31 itens de menu e 12 mídias com
    `langcode=en` migrados para `pt-br` — as URLs canônicas deixam de ter
    prefixo `/en/` e os aliases antigos `/en/*` continuam resolvendo;
- automação n8n (`deploy/n8n/`):
  - workflow "Planilha de acompanhamento" ativo no n8n existente: cron
    diário 07h BRT + webhook `POST /webhook/neruds-planilha-export`;
    login `servico.neruds` → export XLSX do bridge → grava em
    `~/.n8n-files/neruds/` e envia por e-mail com a planilha anexada;
  - README com procedimento de importação e credencial SMTP;

- produção pública via Dokploy + Cloudflare (`srv1533541`):
  - projeto dedicado `neruds-control-center` no Dokploy, isolado dos demais;
  - `deploy/dokploy/`: Dockerfile do bridge (uvicorn), Dockerfile do app web
    (Flutter Web → nginx), docker-compose com labels Traefik para
    `api.neruds.org` + `app.neruds.org` (Let's Encrypt via `dokploy-network`);
  - DNS `app`/`api` na Cloudflare → `46.202.150.132` (proxied, Full strict);
- sessões persistentes no bridge:
  - `session_store` (SQLite `data/sessions.sqlite3`) substitui o dict em
    memória — login sobrevive a restart e a mesma conta opera em web,
    desktop e mobile simultaneamente;
  - cookies Drupal + CSRF criptografados em repouso via Fernet
    (`NERUDS_SESSION_KEY`); sem a chave, cai no comportamento antigo
    (sessões efêmeras) com aviso;
  - expurgo automático de sessões inativas além do TTL no boot;
- config remota do aplicativo (`GET/PUT /config/app`):
  - features (`monitoring`, `opportunities`), `onboarding.enabled`,
    `announcement`, `app_name` e links ajustáveis sem rebuild/redeploy —
    arquivo `data/app_config.json` também editável direto no servidor;
- persistência de sessão no app (web/desktop/mobile):
  - token salvo via `shared_preferences` e revalidado em `/me` na abertura;
    sessão contínua sem depender de estado local de máquina.

### Changed

- bridge `0.5.0` → `0.6.0`.

### Added

- identidade e ciclo de vida de extensionistas (Onda 5 do roadmap):
  - módulo Drupal `neruds_extensionista_guard` ganha rotas
    `/neruds-control/extensionistas*` (roster, criação, bloqueio e link de
    reset) protegidas pela nova permissão `administer neruds extensionistas`;
  - bridge expõe `GET /identity/roster`, `POST /identity/accounts`,
    `POST /identity/accounts/{uid}/status`,
    `POST /identity/accounts/{uid}/password-reset`,
    `POST /identity/accounts/{uid}/offboarding`,
    `GET|POST /identity/accounts/{uid}/checklist` e `GET /identity/events`;
  - `identity_store` (SQLite `data/identity.sqlite3`) registra contas
    operacionais, eventos administrativos e checklist de offboarding;
  - offboarding bloqueia a conta no Drupal, transfere tarefas abertas da
    missão para outra extensionista e emite alertas (rascunhos pendentes,
    mailbox Poste.io, sessões Drupal);
  - reset de senha usa link de uso único do Drupal — a senha temporária de
    provisão só aparece na resposta de criação e nunca é persistida;
  - app ganha página "Usuários e papéis" na aba Administração, visível
    apenas para sessões com `can_admin_users`.
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
- evidência por arquivo (Onda 2 do roadmap):
  - `POST /mission-tasks/{id}/evidence-files` aceita upload multipart
    (máx. 10 MB), armazena em `data/evidence/` com sha256 e registra
    evento de auditoria;
  - `GET /mission-tasks/{id}/evidence-files` lista anexos e
    `GET /mission-evidence/{id}` baixa o arquivo;
  - dialog da tarefa no app Flutter lista anexos e permite anexar/baixar
    via `file_picker`.

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
