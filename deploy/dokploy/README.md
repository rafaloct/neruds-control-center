# Deploy — Dokploy (srv1533541) + Cloudflare

Stack dedicada do NERUDS Control Center. **Não misturar com os demais
projetos do Dokploy** (kreativ, cartilhas, tutor-tds, n8n etc.).

## Topologia

```text
app.neruds.org ──Cloudflare──> Traefik (srv1533541) ──> web (nginx, Flutter Web)
api.neruds.org ──Cloudflare──> Traefik (srv1533541) ──> bridge:8787 (FastAPI)
                                                        │
                                                        └─> neruds.org (Drupal)
                                                        └─> mail.neruds.org (Poste.io)
                                                        └─> volume neruds-bridge-data
                                                              ├─ sessions.sqlite3
                                                              ├─ missions.sqlite3
                                                              ├─ identity.sqlite3
                                                              ├─ app_config.json
                                                              ├─ backups/ logs/ evidence/
```

## Pré-requisitos

1. DNS na Cloudflare (zone `neruds.org`):
   - `A app.neruds.org → 46.202.150.132` — proxied (nuvem laranja)
   - `A api.neruds.org → 46.202.150.132` — proxied
   - SSL/TLS mode: **Full (strict)** — o Traefik emite Let's Encrypt real
     (HTTP-01 passa pelo proxy sem problema).
2. Projeto `neruds-control-center` no Dokploy, serviço **Compose** apontando
   para `deploy/dokploy/docker-compose.yml` com o repo como contexto.
3. `deploy/dokploy/.env` preenchido (ver `.env.production.example`) —
   principalmente `NERUDS_SESSION_KEY` (Fernet) e SMTP.

## Deploy manual (fallback, via SSH)

```bash
ssh root@100.90.91.35
cd /root/neruds-control-center        # clone do repo (branch de release)
cp deploy/dokploy/.env.production.example deploy/dokploy/.env
# editar segredos
docker compose -p neruds-control-center \
  -f deploy/dokploy/docker-compose.yml \
  --env-file deploy/dokploy/.env up -d --build
```

## Atualizar o app sem redeploy

- **Web**: o usuário recebe a build nova ao recarregar — basta rebuildar o
  serviço `web` (merge → deploy).
- **Config remota**: `GET /config/app` é mesclado sobre
  `data/app_config.json`. Edite o arquivo no volume ou use
  `PUT /config/app` (admin) para alterar features, onboarding, anúncios e
  links sem rebuild algum.
- **Feature flags ativas**: `features.monitoring`, `features.opportunities`,
  `onboarding.enabled`, `announcement`, `app_name`.

## Sessões

`data/sessions.sqlite3` guarda tokens com cookies Drupal + CSRF
criptografados (Fernet, `NERUDS_SESSION_KEY`). Login sobrevive a restart e o
mesmo usuário pode operar de web, desktop e mobile ao mesmo tempo — cada
cliente recebe seu próprio token. TTL: 8h de inatividade
(`NERUDS_SESSION_IDLE_HOURS`); sessões vencidas são expurgadas no boot.

## Verificação

```bash
curl https://api.neruds.org/health
curl https://api.neruds.org/config/app
curl -I https://app.neruds.org
```

Antes do DNS propagar, valide pelo IP com Host header:

```bash
curl --resolve api.neruds.org:443:46.202.150.132 https://api.neruds.org/health
```
