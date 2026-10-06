set -euo pipefail
cd /var/www/html

# Sufixo unico por execucao: nunca colide com contas preexistentes.
SUFFIX="$(date +%s)"
ADMIN_NAME="e2e.admin.${SUFFIX}"
ADMIN_MAIL="${ADMIN_NAME}@neruds.org"
TARGET_NAME="e2e.target.${SUFFIX}"
TARGET_MAIL="${TARGET_NAME}@neruds.org"
PASS="Tmp!$(openssl rand -hex 12)Aa1"
BRIDGE="${E2E_BRIDGE:-https://largeo.tail2faed0.ts.net:8443}"

# Contas efetivamente criadas por ESTA execucao (cleanup nunca toca em outras).
CREATED_USERS=()

say() { echo "== $*"; }

user_exists() {
  vendor/bin/drush user:information "$1" --format=json 2>/dev/null \
    | grep -q '"uid"'
}

drupal_user() {
  E2E_DRUPAL_USERNAME="$1" vendor/bin/drush php:eval '
$name = getenv("E2E_DRUPAL_USERNAME");
if ($name === FALSE || $name === "") {
  echo "MISSING";
  return;
}
$storage = \Drupal::entityTypeManager()->getStorage("user");
$uids = $storage->getQuery()
  ->accessCheck(FALSE)
  ->condition("name", $name)
  ->range(0, 1)
  ->execute();
$user = $uids ? $storage->load(reset($uids)) : NULL;
if (!$user) {
  echo "MISSING";
  return;
}
echo json_encode([
  "uid" => (int) $user->id(),
  "status" => (int) $user->isActive(),
  "roles" => array_values($user->getRoles()),
], JSON_THROW_ON_ERROR);
' 2>/dev/null
}

cleanup() {
  for U in "${CREATED_USERS[@]:-}"; do
    [ -n "$U" ] || continue
    vendor/bin/drush user:cancel "$U" --delete-content -y >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

say "execucao $SUFFIX — usuarios de teste: $ADMIN_NAME / $TARGET_NAME"

# Aborta se o nome ja existir (defesa extra alem do sufixo).
for U in "$ADMIN_NAME" "$TARGET_NAME"; do
  if user_exists "$U"; then
    say "ABORT: $U ja existe no Drupal — recusando prosseguir"
    exit 1
  fi
done

# --- setup: disposable content_editor (tem 'administer neruds extensionistas')
say "setup: criando $ADMIN_NAME (content_editor)"
vendor/bin/drush user:create "$ADMIN_NAME" --mail="$ADMIN_MAIL" --password="$PASS" --format=null >/dev/null
CREATED_USERS+=("$ADMIN_NAME")
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
CREATED_USERS+=("$TARGET_NAME")
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
# ATENCAO: este passo anexa um arquivo real numa tarefa de producao.
# So executa com E2E_ALLOW_PROD_EVIDENCE=1; caso contrario e pulado.
if [ "${E2E_ALLOW_PROD_EVIDENCE:-0}" = '1' ]; then
  say "5/8 evidência por arquivo (upload -> download) [ESCREVE EM PRODUCAO]"
  TASK_ID=$(curl -sS -H "$AUTH" "$BRIDGE/missions/1/tasks?limit=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["id"])')
  printf 'E2E evidence payload %s' "$(date -Is)" > /tmp/e2e_evidence.txt
  UP=$(curl -sS -w '\n%{http_code}' -X POST -H "$AUTH" \
    -F "file=@/tmp/e2e_evidence.txt;filename=e2e-prova-${SUFFIX}.txt;type=text/plain" \
    -F "note=anexo e2e ${SUFFIX}" "$BRIDGE/mission-tasks/$TASK_ID/evidence-files")
  [ "$(printf '%s' "$UP" | tail -n1)" = '201' ]
  EV_ID=$(printf '%s' "$UP" | sed '$d' | python3 -c 'import json,sys; print(json.load(sys.stdin)["evidence"]["id"])')
  curl -sS -H "$AUTH" "$BRIDGE/mission-evidence/$EV_ID" -o /tmp/e2e_evidence_dl.txt
  cmp -s /tmp/e2e_evidence.txt /tmp/e2e_evidence_dl.txt
  say "PASS evidência id=$EV_ID na task $TASK_ID (bytes conferem)"
else
  say "5/8 SKIP evidência — defina E2E_ALLOW_PROD_EVIDENCE=1 para anexar em producao"
fi

# --- 6. offboarding
say "6/8 POST /identity/accounts/$TARGET_UID/offboarding"
CODE=$(curl -sS -o /tmp/e2e_offboard.json -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$AUTH" \
  -d "{\"note\": \"offboarding e2e ${SUFFIX}\"}" "$BRIDGE/identity/accounts/$TARGET_UID/offboarding")
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
python3 -c 'import json,sys; items=json.load(open("/tmp/e2e_events.json")).get("items",[]); target=sys.argv[1]; assert any(e.get("username")==target for e in items), "sem eventos do alvo"' "$TARGET_NAME"
say "PASS trilha de eventos registrada"

say "E2E OK — usuarios e2e.*.${SUFFIX} removidos"
