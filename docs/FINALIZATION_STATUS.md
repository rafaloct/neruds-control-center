# NERUDS Control Center — Status final

**Data:** 05/10/2026

**App:** 1.0.0+1

**Bridge:** 0.3.3
**Classificação:** concluído para uso interno na Tailscale

## Gates aprovados

- Flutter analyze: 0 issues
- Flutter tests: 2/2 PASS
- Windows build: PASS
- Web build: PASS
- Android debug build: PASS
- Endpoint HTTPS da tailnet acessível a partir da VPS com validação TLS
- E2E descartável completo: PASS
- extensionista.1 real: PASS
- extensionista.2 real: PASS
- rascunho forçado a não publicado: PASS
- notificação de revisão por e-mail: PASS
- limpeza dos artefatos de teste conhecidos: PASS

## Arquitetura final do bridge

O Uvicorn escuta somente em:

`127.0.0.1:8787`

A tailnet publica:

`https://<host-bridge>.<tailnet>.ts.net:8443`

por Tailscale Serve para `http://127.0.0.1:8787`.

Isso substitui o acesso HTTP direto anterior em `<ip-tailscale-do-host>:8787`.

## Identidade e sessão

O login é delegado ao formulário nativo do Drupal 11.
O bridge lê o valor real do botão do formulário, inclusive interface pt-BR.
A senha Drupal não é persistida.
Sessões do bridge vivem em memória e expiram após 8h de inatividade.

## Papel Extensionista

Contas reais:

- extensionista.1 / extensionista.1@neruds.org / UID 2
- extensionista.2 / extensionista.2@neruds.org / UID 3

Permissões:

- access content
- access user profiles
- create noticia content
- edit own noticia content
- create relatorio content
- edit own relatorio content
- view own unpublished content
- use basic_editorial transition create_new_draft

Não possui permissão de publicação, despublicação, exclusão ou edição de conteúdo alheio.

## Guarda server-side

Módulo:

`web/modules/custom/neruds_extensionista_guard`

Para novos `noticia` e `relatorio` criados por Extensionista:

- força owner para o usuário autenticado;
- força status não publicado.

## E2E final HTTPS

Resultado:

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

O node 356 e outros nodes temporários conhecidos foram removidos após o teste.

## Contas reais

Teste interativo de 03/10/2026:

```text
extensionista.1|LOGIN=PASS|ME=extensionista.1|MISSION=205/278|DRAFTS=PASS|DRAFT_CREATE=PASS
extensionista.2|LOGIN=PASS|ME=extensionista.2|MISSION=205/278|DRAFTS=PASS|DRAFT_CREATE=PASS
```

Os nodes reais de teste 352 e 353 foram confirmados como status=0, owners 2 e 3, e removidos.

## Poste.io

Certificado dedicado `mail.neruds.org` emitido via Let's Encrypt.
Certbot possui renovação automática e deploy hook que atualiza o volume do Poste.io.

Validação:

- SMTP/STARTTLS 587: Verify return code 0
- IMAPS 993: Verify return code 0
- HTTPS 8443: Verify return code 0

Notificações do bridge usam conexão Tailscale para `<ip-tailscale-do-vps>:25`, identidade TLS `mail.neruds.org`, STARTTLS validado e entrega local para `admin@neruds.org`, sem senha SMTP armazenada.

## Missão do estagiário

- 205 registros de Controle Master
- 73 atividades complementares
- total: 278 verificações rastreáveis
- SQLite com histórico, checklists, evidências, responsáveis e etapas

## Oportunidades

- RSS/Atom com proteção SSRF
- captura manual de URL oficial sem fetch automático
- classificação editorial
- triagem/verificação
- aprovação de pauta
- criação de rascunho
- nunca publica automaticamente

## Artefatos

`release/NERUDS-Control-Center-Windows.zip`

SHA256:
`AFBEA2C986C75116AD7F65899E9C94EDD4B4577E28FAED2982A0D63DA44D1087`

`release/NERUDS-Control-Center-Web.zip`

SHA256:
`274B159E61D1C61BB8BF9953C9EE15281370F179504E76275E85652AB4CD5B93`

`release/android/NERUDS-Control-Center-debug.apk`

SHA256:
`9AC0BDC491AFEBD73369181C34523BCCE69DC299BC974BA8616773DCC8445F94`

## Único gate fora do release interno

O projeto possui `secrets/android/key.properties`, mas não há keystore `.jks/.keystore` disponível no host de operação ou projeto.

Consequência: Android está concluído para teste/uso interno como APK debug, mas ainda não para distribuição assinada em loja.

Não criar uma nova identidade de assinatura sem decisão explícita.
