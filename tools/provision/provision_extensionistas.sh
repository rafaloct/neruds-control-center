set -euo pipefail
cd /var/www/html
CRED=/root/neruds_extensionista_credentials.tsv
umask 077
touch "$CRED"
chmod 600 "$CRED"

get_saved() {
  local user="$1" col="$2"
  awk -F '\t' -v u="$user" -v c="$col" '$1==u {print $c; exit}' "$CRED"
}

for n in 1 2; do
  user="extensionista.$n"
  email="$user@neruds.org"
  portal_pass="$(get_saved "$user" 3)"
  mail_pass="$(get_saved "$user" 4)"

  if [ -z "$portal_pass" ]; then
    portal_pass="NrD!$(openssl rand -hex 12)Aa1"
  fi
  if [ -z "$mail_pass" ]; then
    mail_pass="Mail!$(openssl rand -hex 12)Bb2"
  fi

  if ! awk -F '\t' -v u="$user" '$1==u {found=1} END{exit !found}' "$CRED"; then
    printf '%s\t%s\t%s\t%s\n' "$user" "$email" "$portal_pass" "$mail_pass" >> "$CRED"
  fi

  if docker exec mailserver sh -lc '/usr/sbin/poste email:list --no-ansi' | grep -Fq "$email ("; then
    echo "MAILBOX|$email|exists"
  else
    docker exec mailserver /usr/sbin/poste email:create --no-ansi "$email" "$mail_pass" "Extensionista $n" >/dev/null
    echo "MAILBOX|$email|created"
  fi

  if vendor/bin/drush user:information "$user" --field=uid >/dev/null 2>&1; then
    echo "DRUPAL|$user|exists"
  else
    vendor/bin/drush user:create "$user" --mail="$email" --password="$portal_pass" --format=null
    echo "DRUPAL|$user|created"
  fi

  vendor/bin/drush user:role:add extensionista "$user" >/dev/null
done

echo '--- VERIFY DRUPAL ---'
vendor/bin/drush php:eval '
$storage = \\Drupal::entityTypeManager()->getStorage("user");
$ids = $storage->getQuery()->accessCheck(FALSE)->condition("name", "extensionista.%", "LIKE")->execute();
foreach ($storage->loadMultiple($ids) as $u) {
  echo "USER|".$u->id()."|".$u->getAccountName()."|".$u->getEmail()."|".($u->isActive()?"active":"blocked")."|".implode(",", $u->getRoles()).PHP_EOL;
}
'
echo '--- VERIFY MAILBOXES ---'
docker exec mailserver sh -lc '/usr/sbin/poste email:list --no-ansi' | grep -E '^extensionista\.[12]@neruds\.org'
echo "CREDENTIAL_FILE=$CRED"
