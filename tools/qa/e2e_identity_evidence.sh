set -euo pipefail
cd /var/www/html

ADMIN_NAME='e2e.admin.test'
ADMIN_MAIL='e2e.admin.test@neruds.org'
TARGET_NAME='e2e.target.test'
TARGET_MAIL='e2e.target.test@neruds.org'
PASS="Tmp!$(openssl rand -hex 12)Aa1"
BRIDGE='https://largeo.tail2faed0.ts.net:8443'

say() { echo "== $*"; }

drupal_user() {
  vendor/bin/drush user:information "$1" --format=json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    users = json.load(sys.stdin)
    u = list(users.values())[0] if isinstance(users, dict) and users else None
except Exception:
    u = None
if not u:
    print("MISSING")
else:
    roles = u.get("roles") or []
    print(json.dumps({
        "uid": int(u.get("uid") or 0),
        "status": int(u.get("status") or 0),
        "roles": list(roles) if isinstance(roles, (list, dict)) else [],
    }))'
}

cleanup() {
  for U in "$ADMIN_NAME" "$TARGET_NAME"; do
    vendor/bin/drush user:cancel "$U" --delete-content -y >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# --- setup: disposable content_editor (has 'administer neruds extensionistas')
say "setup: criando $ADMIN_NAME (content_editor)"
vendor/bin/drush user:create "$ADMIN_NAME" --mail="$ADMIN_MAIL" --password="$PASS" --format=null >/dev/null
vendor/bin/drush user:role:add content_editor "$ADMIN_NAME" >/dev/null

# --- 1. login + can_admin_users
say "1/8 login no bridge"
LOGIN_RESP=$(curl -sS -w '\n%{http_code}' -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$ADMIN_NAME" "$PASS")" \
  "$BRIDGE/auth/login")
[ "$(printf '%s' "$LOGIN_RESP" | tail -n1)" = '200' ]
TOKEN=$(printf '%s' "$LOGIN_RESP" | sed '$d' | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
AUTH="Authorization: Bearer $TOKEN"

ME=$(curl -sS -H "$AUTH" "$BRIDGE/auth/me")
printf '%s' "$ME" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("can_admin_users") is True, d'
say "PASS can_admin_users=true"

# --- 2. roster
say "2/8 GET /identity/roster"
CODE=$(curl -sS -o /tmp/e2e_roster.json -w '%{http_code}' -H "$AUTH" "$BRIDGE/identity/roster")
[ "$CODE" = '200' ]
say "PASS roster 200"

# --- 3. provision disposable extensionista via bridge
say "3/8 POST /identity/accounts"
CREATE=$(curl -sS -w '\n%{http_code}' -H 'Content-Type: application/json' -H "$AUTH" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"mail":sys.argv[2]}))' "$TARGET_NAME" "$TARGET_MAIL")" \
  "$BRIDGE/identity/accounts")
[ "$(printf '%s' "$CREATE" | tail -n1)" = '201' ]
CBODY=$(printf '%s' "$CREATE" | sed '$d')
TARGET_UID=$(printf '%s' "$CBODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["account"]["drupal_uid"])')
printf '%s' "$CBODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["drupal"].get("temporary_password"), "sem senha temporaria na resposta"'
say "PASS criado uid=$TARGET_UID (senha temporaria so na resposta)"

DJSON=$(drupal_user "$TARGET_NAME")
printf '%s' "$DJSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]==1 and "extensionista" in d["roles"], d'
say "PASS usuario existe no Drupal, ativo, papel extensionista"

# --- 4. block via bridge -> verify Drupal
say "4/8 POST /identity/accounts/$TARGET_UID/status (block)"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$AUTH" \
  -d '{"active": false}' "$BRIDGE/identity/accounts/$TARGET_UID/status")
[ "$CODE" = '200' ]
DJSON=$(drupal_user "$TARGET_NAME")
printf '%s' "$DJSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]==0, d'
say "PASS status=0 no Drupal"

# --- 5. evidence upload + download (byte round-trip)
say "5/8 evidência por arquivo (upload -> download)"
TASK_ID=$(curl -sS -H "$AUTH" "$BRIDGE/missions/1/tasks?limit=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["id"])')
printf 'E2E evidence payload %s' "$(date -Is)" > /tmp/e2e_evidence.txt
UP=$(curl -sS -w '\n%{http_code}' -X POST -H "$AUTH" \
  -F "file=@/tmp/e2e_evidence.txt;filename=e2e-prova.txt;type=text/plain" \
  -F "note=anexo e2e" "$BRIDGE/mission-tasks/$TASK_ID/evidence-files")
[ "$(printf '%s' "$UP" | tail -n1)" = '201' ]
EV_ID=$(printf '%s' "$UP" | sed '$d' | python3 -c 'import json,sys; print(json.load(sys.stdin)["evidence"]["id"])')
curl -sS -H "$AUTH" "$BRIDGE/mission-evidence/$EV_ID" -o /tmp/e2e_evidence_dl.txt
cmp -s /tmp/e2e_evidence.txt /tmp/e2e_evidence_dl.txt
say "PASS evidência id=$EV_ID na task $TASK_ID (bytes conferem)"

# --- 6. offboarding
say "6/8 POST /identity/accounts/$TARGET_UID/offboarding"
CODE=$(curl -sS -o /tmp/e2e_offboard.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$AUTH" \
  -d '{"note": "offboarding e2e"}' "$BRIDGE/identity/accounts/$TARGET_UID/offboarding")
[ "$CODE" = '200' ]
DJSON=$(drupal_user "$TARGET_NAME")
printf '%s' "$DJSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]==0, d'
say "PASS offboarding (conta permanece bloqueada no Drupal)"

# --- 7. checklist persisted
say "7/8 GET /identity/accounts/$TARGET_UID/checklist"
CODE=$(curl -sS -o /tmp/e2e_check.json -w '%{http_code}' -H "$AUTH" "$BRIDGE/identity/accounts/$TARGET_UID/checklist")
[ "$CODE" = '200' ]
say "PASS checklist"

# --- 8. events audit trail
say "8/8 GET /identity/events"
CODE=$(curl -sS -o /tmp/e2e_events.json -w '%{http_code}' -H "$AUTH" "$BRIDGE/identity/events?limit=50")
[ "$CODE" = '200' ]
python3 -c 'import json; items=json.load(open("/tmp/e2e_events.json")).get("items",[]); assert any(e.get("username")=="e2e.target.test" for e in items), "sem eventos do alvo"'
say "PASS trilha de eventos registrada"

say "E2E OK — usuarios de teste removidos; evidencia de teste permanece na task $TASK_ID (sem endpoint de remocao)"
