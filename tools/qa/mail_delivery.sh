set -e
SUBJ='NERUDS-Control-Test-20261003'
for email in extensionista.1@neruds.org extensionista.2@neruds.org; do
  printf 'From: admin@neruds.org\nTo: %s\nSubject: %s\n\nTeste automatico de entrega local do NERUDS Control Center.\n' "$email" "$SUBJ" | docker exec -i mailserver sendmail -t
done
sleep 2
for email in extensionista.1@neruds.org extensionista.2@neruds.org; do
  count=$(docker exec mailserver doveadm search -u "$email" mailbox INBOX HEADER Subject "$SUBJ" 2>/dev/null | wc -l)
  echo "DELIVERY|$email|matches=$count"
  if [ "$count" -gt 0 ]; then
    docker exec mailserver doveadm expunge -u "$email" mailbox INBOX HEADER Subject "$SUBJ" >/dev/null 2>&1 || true
    echo "CLEANUP|$email|done"
  fi
done
