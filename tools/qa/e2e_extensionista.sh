set -euo pipefail
cd /var/www/html
USER_NAME='extensionista.bridge.test'
USER_MAIL='extensionista.bridge.test@neruds.org'
PASS="Tmp!$(openssl rand -hex 12)Aa1"
TITLE='[TESTE AUTOMATICO] Bridge Extensionista'
BRIDGE="${NERUDS_BRIDGE_URL:?defina NERUDS_BRIDGE_URL (ex.: https://<bridge-tailnet>:8443)}"
CREATED_NODE_ID=''

cleanup() {
  if [ -n "$CREATED_NODE_ID" ]; then
    vendor/bin/drush entity:delete node "$CREATED_NODE_ID" -y >/dev/null 2>&1 || true
  fi
  vendor/bin/drush php:eval '
  $storage = \Drupal::entityTypeManager()->getStorage("user");
  $users = $storage->loadByProperties(["name" => "extensionista.bridge.test"]);
  if ($users) {
    $u = reset($users);
    $nids = \Drupal::entityQuery("node")->accessCheck(FALSE)->condition("uid", $u->id())->condition("title", "[TESTE AUTOMATICO] Bridge Extensionista")->execute();
    if ($nids) { \Drupal::entityTypeManager()->getStorage("node")->delete(\Drupal::entityTypeManager()->getStorage("node")->loadMultiple($nids)); }
    $u->delete();
  }
  ' >/dev/null 2>&1 || true
}
trap cleanup EXIT

vendor/bin/drush user:create "$USER_NAME" --mail="$USER_MAIL" --password="$PASS" --format=null >/dev/null
vendor/bin/drush user:role:add extensionista "$USER_NAME" >/dev/null

LOGIN_JSON=$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$USER_NAME" "$PASS")
LOGIN_RESP=$(curl -sS -w '\n%{http_code}' -H 'Content-Type: application/json' -d "$LOGIN_JSON" "$BRIDGE/auth/login")
LOGIN_CODE=$(printf '%s' "$LOGIN_RESP" | tail -n1)
LOGIN_BODY=$(printf '%s' "$LOGIN_RESP" | sed '$d')
echo "LOGIN_CODE=$LOGIN_CODE"
[ "$LOGIN_CODE" = '200' ]
TOKEN=$(printf '%s' "$LOGIN_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

ME_CODE=$(curl -sS -o /tmp/neruds_me.json -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BRIDGE/auth/me")
MISSION_CODE=$(curl -sS -o /tmp/neruds_mission.json -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BRIDGE/missions/1/dashboard")
echo "ME_CODE=$ME_CODE"
echo "MISSION_CODE=$MISSION_CODE"
[ "$ME_CODE" = '200' ]
[ "$MISSION_CODE" = '200' ]

DRAFT_JSON=$(python3 -c 'import json; print(json.dumps({"title":"[TESTE AUTOMATICO] Bridge Extensionista","summary":"Teste temporario","body":"Teste temporario do fluxo ponta a ponta."}))')
DRAFT_RESP=$(curl -sS -w '\n%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d "$DRAFT_JSON" "$BRIDGE/content/news/draft")
DRAFT_CODE=$(printf '%s' "$DRAFT_RESP" | tail -n1)
DRAFT_BODY=$(printf '%s' "$DRAFT_RESP" | sed '$d')
echo "DRAFT_CODE=$DRAFT_CODE"
[ "$DRAFT_CODE" = '200' ]
CREATED_NODE_ID=$(printf '%s' "$DRAFT_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id") or "")')
echo "DRAFT_ID=$CREATED_NODE_ID"
[ -n "$CREATED_NODE_ID" ]
NOTIFY_SENT=$(printf '%s' "$DRAFT_BODY" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("notification",{}).get("sent",False)).lower())')
echo "NOTIFY_SENT=$NOTIFY_SENT"
[ "$NOTIFY_SENT" = 'true' ]

NODE_STATE=$(vendor/bin/drush php:eval '
$storage = \Drupal::entityTypeManager()->getStorage("user");
$user = reset($storage->loadByProperties(["name" => "extensionista.bridge.test"]));
$nids = \Drupal::entityQuery("node")->accessCheck(FALSE)->condition("uid", $user->id())->condition("title", "[TESTE AUTOMATICO] Bridge Extensionista")->execute();
$nodes = \Drupal::entityTypeManager()->getStorage("node")->loadMultiple($nids);
foreach ($nodes as $node) { echo ($node->isPublished() ? "PUBLISHED" : "DRAFT") . "|" . $node->id(); }
')
echo "NODE_STATE=$NODE_STATE"
printf '%s' "$NODE_STATE" | grep -q '^DRAFT|'

sleep 5
MAIL_COUNT=$(docker exec mailserver doveadm search -u admin@neruds.org mailbox INBOX SUBJECT "Bridge Extensionista" 2>/dev/null | wc -l)
echo "MAIL_COUNT=$MAIL_COUNT"
[ "$MAIL_COUNT" -ge 1 ]
docker exec mailserver doveadm expunge -u admin@neruds.org mailbox INBOX SUBJECT "Bridge Extensionista" >/dev/null 2>&1 || true

curl -sS -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" "$BRIDGE/auth/logout" || true
echo 'END_TO_END=PASS'
