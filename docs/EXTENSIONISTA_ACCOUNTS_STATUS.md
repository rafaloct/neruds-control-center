# Contas Extensionista — estado operacional

**Provisionamento inicial:** 03/10/2026

**Última validação:** 05/10/2026

## Acesso VPS

- aliases SSH de operação: registrados fora do repositório
- destino operacional: `<ip-tailscale-do-vps>` via Tailscale
- host: `<hostname-do-vps>`

## Papel Drupal

Papel:

`extensionista` / **Extensionista**

Permissões:

- access content
- access user profiles
- create noticia content
- edit own noticia content
- create relatorio content
- edit own relatorio content
- view own unpublished content
- use basic_editorial transition create_new_draft

Negado por desenho:

- publicar;
- despublicar;
- excluir conteúdo;
- editar conteúdo de terceiros;
- administrar menus/aliases/site;
- criar Basic page.

O módulo `neruds_extensionista_guard` também força novos `noticia` e `relatorio` de Extensionista a owner=usuário autenticado e status=não publicado.

## Contas

- `extensionista.1` — `extensionista.1@neruds.org` — Drupal UID 2 — ativa
- `extensionista.2` — `extensionista.2@neruds.org` — Drupal UID 3 — ativa

Papéis:

- authenticated
- extensionista

## Validação real

As duas contas foram testadas interativamente com suas senhas atuais:

```text
extensionista.1|LOGIN=PASS|ME=extensionista.1|MISSION=205/278|DRAFTS=PASS|DRAFT_CREATE=PASS
extensionista.2|LOGIN=PASS|ME=extensionista.2|MISSION=205/278|DRAFTS=PASS|DRAFT_CREATE=PASS
```

Os rascunhos reais de teste foram confirmados como não publicados e removidos depois da validação.

## Poste.io

Caixas:

- `extensionista.1@neruds.org`
- `extensionista.2@neruds.org`

Entrega local validada nas duas INBOXes.

## Senhas

As senhas Drupal atuais foram definidas interativamente pelo responsável e **não ficam armazenadas no Control Center**.

O arquivo root-only:

`/root/neruds_extensionista_credentials.tsv`

continua com permissão:

`600 root:root`

O campo referente à senha Drupal inicial foi sanitizado para `ROTATED_NOT_STORED` depois da rotação. A cópia que continha a senha antiga foi removida.

As senhas de mailbox continuam sob controle do Poste.io/root e não são expostas ao app.

## QA de permissão

Com papel Extensionista:

- Criar Notícia: ALLOW
- Criar Relatório: ALLOW
- Criar Basic page: DENY
- Publicar: DENY
- Excluir própria Notícia: DENY
- Editar próprio rascunho: ALLOW

Artefatos temporários de QA conhecidos foram removidos do Drupal após os testes.
