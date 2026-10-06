# NERUDS Control Center

Aplicativo multiplataforma para transformar a manutenção do portal [neruds.org](https://neruds.org) em fluxos guiados para extensionistas, revisores e coordenação, sem exigir acesso a SSH, VPS ou administração Drupal.

## Estado atual

**Versão do app:** 1.0.0+1

**Bridge:** 0.3.3

**Situação:** aprovado para uso interno na Tailscale.

Validado em 05/10/2026:

- Flutter para Windows, Android e Web;
- `dart analyze`: 0 issues;
- testes Flutter: 2/2 PASS;
- build Windows: PASS;
- build Web: PASS;
- APK Android debug: PASS;
- E2E real de Extensionista: PASS;
- criação de rascunho não publicado: PASS;
- notificação de revisão por e-mail: PASS;
- Poste.io com TLS Let's Encrypt válido;
- contas `extensionista.1` e `extensionista.2` validadas.

## Arquitetura de acesso

O FastAPI não é exposto diretamente na interface Tailscale.

No host do bridge ele escuta apenas em:

```text
http://127.0.0.1:8787
```

O Tailscale Serve publica, somente para a tailnet:

```text
https://<host-bridge>.<tailnet>.ts.net:8443
```

Configuração esperada:

```text
https://<host-bridge>.<tailnet>.ts.net:8443
└── /  ->  http://127.0.0.1:8787
```

Não voltar a bindar o Uvicorn em `0.0.0.0` ou no IP Tailscale sem uma necessidade específica.

## Estrutura

- `app/` — aplicativo Flutter.
- `bridge/` — FastAPI, missão, oportunidades e revisão.
- `server/neruds_extensionista_guard/` — proteção Drupal para conteúdo de Extensionista.
- `docs/` — arquitetura, roadmap e status operacional.
- `design-system/` — decisões de UI/UX.
- `skills/` — instruções locais de Drupal.
- `.agents/skills/ui-ux-pro-max/` — skill de UI/UX instalada no projeto.
- `tools/qa/` — testes operacionais reproduzíveis.
- `tools/provision/` — provisionamento de papel/contas.
- `tools/operations/` — manutenção controlada.
- `source/` — planilha fonte da missão.
- `release/` — artefatos internos gerados.

## Bridge

Para execução manual no host do bridge:

```powershell
cd <pasta-do-checkout>\neruds-control-center\bridge
uv run uvicorn main:app --host 127.0.0.1 --port 8787
```

Também existem:

- `start_bridge.ps1`;
- `bridge_supervisor.ps1`;
- startup do Windows para iniciar o supervisor no logon do operador.

Verifique a exposição segura com:

```powershell
tailscale serve status
```

Health pela tailnet:

```text
https://<host-bridge>.<tailnet>.ts.net:8443/health
```

## Aplicativo

O endpoint HTTPS do bridge não fica gravado no código: configure-o em tempo de execução/compilação via `NERUDS_BRIDGE_URL` (ex.: `https://<host-bridge>.<tailnet>.ts.net:8443`). Em desenvolvimento:

### Windows

```powershell
cd app
flutter run -d windows --dart-define=NERUDS_BRIDGE_URL=https://<host-bridge>.<tailnet>.ts.net:8443
```

### Web

```powershell
flutter run -d chrome --dart-define=NERUDS_BRIDGE_URL=https://<host-bridge>.<tailnet>.ts.net:8443
```

### Android

```powershell
flutter run -d android --dart-define=NERUDS_BRIDGE_URL=https://<host-bridge>.<tailnet>.ts.net:8443
```

Sem `NERUDS_BRIDGE_URL` o app segue funcionando apenas com leitura pública do portal; as funções privadas (login, missão, oportunidades, revisão) avisam que a URL da bridge não foi configurada.

O dispositivo precisa estar conectado à mesma tailnet para usar as funções privadas do Control Center.

## Identidade e segurança

O Drupal continua sendo a fonte de verdade de identidade e autorização.

O bridge:

- encaminha a senha ao formulário nativo do Drupal;
- não persiste a senha;
- guarda apenas cookies Drupal e CSRF em memória;
- entrega ao app um bearer token temporário;
- expira a sessão após 8 horas de inatividade;
- perde todas as sessões em um restart.

Extensionistas não recebem SSH/root.

## Papel Extensionista

Contas iniciais:

- `extensionista.1` — `extensionista.1@neruds.org`;
- `extensionista.2` — `extensionista.2@neruds.org`.

Permissões do papel:

- acessar conteúdo e perfis;
- criar Notícia;
- editar apenas a própria Notícia;
- criar Relatório;
- editar apenas o próprio Relatório;
- visualizar o próprio conteúdo não publicado;
- criar novo rascunho.

Não pode:

- publicar;
- despublicar;
- excluir conteúdo;
- editar conteúdo alheio;
- administrar menus, aliases ou site;
- criar Basic page.

O módulo `neruds_extensionista_guard` força novos `noticia` e `relatorio` criados por Extensionista a permanecerem **não publicados** e pertencentes ao próprio usuário.

## Fluxo editorial

Fluxo de baixo risco:

```text
Extensionista
  -> pesquisa/evidência
  -> rascunho
  -> revisão
  -> aprovação
  -> publicação por perfil autorizado
```

RSS e oportunidades nunca publicam automaticamente.

## Missão do estagiário

A planilha `TREINAMENTO_NERUDS_Gestao_e_Preenchimento.xlsm` foi convertida para uma missão rastreável:

- Controle Master: 205 tarefas;
- atividades complementares: 73;
- total: 278 verificações;
- P0: 8;
- P1: 191;
- P2: 6;
- Pessoa A: 103 tarefas primárias;
- Pessoa B: 102 tarefas primárias.

Fluxo:

```text
Triagem
-> Em pesquisa
-> Evidência registrada
-> Revisão cruzada
-> Aguardando validação
-> Conferência pública
-> Concluído
```

Também existe `Bloqueado`.

A trilha preserva origem da planilha, prioridade, IDs, URLs, fontes, evidências, responsáveis, revisão cruzada, prazos, checklists e histórico.

## Radar de oportunidades

Categorias:

- Edital;
- Chamada para revista;
- Oportunidade de extensão;
- Grupo/rede de pesquisa;
- Bolsa;
- Evento científico;
- Notícia institucional;
- Outro.

Fluxo:

```text
Novo -> Em triagem -> Fonte verificada -> Pauta aprovada -> Rascunho Drupal -> Revisão editorial
```

Há captura manual de URL oficial para fontes sem RSS/Atom. A URL manual não é buscada automaticamente pelo servidor.

## Poste.io

O Poste.io roda no VPS de e-mail.

TLS validado:

- SMTP/STARTTLS 587: OK;
- IMAPS 993: OK;
- HTTPS 8443: OK.

`mail.neruds.org` usa certificado Let's Encrypt com renovação Certbot e deploy hook.

O bridge envia notificações internas por:

- conexão: `<ip-tailscale-do-vps>:25` via Tailscale;
- identidade TLS: `mail.neruds.org`;
- STARTTLS validado;
- sem armazenar senha SMTP;
- destinatário atual: `admin@neruds.org`.

## QA E2E

Teste reproduzível:

```text
tools/qa/e2e_extensionista.sh
```

Último resultado:

```text
LOGIN_CODE=200
ME_CODE=200
MISSION_CODE=200
DRAFT_CODE=200
DRAFT_ID=356
NOTIFY_SENT=true
NODE_STATE=DRAFT|356
MAIL_COUNT=1
END_TO_END=PASS
```

Os artefatos temporários do teste foram removidos depois da validação.

## Release interno

Consulte:

```text
release/README.txt
docs/FINALIZATION_STATUS.md
```

Artefatos:

- `release/NERUDS-Control-Center-Windows.zip`;
- `release/NERUDS-Control-Center-Web.zip`;
- `release/android/NERUDS-Control-Center-debug.apk`.

### Android formal

O projeto possui configuração de `key.properties`, mas não existe atualmente um arquivo `.jks/.keystore` no host de operação/projeto.

Por isso o APK entregue é **debug para uso interno**. Não criar uma nova chave de assinatura sem decisão explícita, porque essa chave passa a definir a identidade das futuras atualizações Android.
