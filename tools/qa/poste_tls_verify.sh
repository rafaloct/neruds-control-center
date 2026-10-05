set -e
echo '--- MAILSERVER STATUS ---'
docker ps --filter name=mailserver --format '{{.Names}}|{{.Status}}|{{.Ports}}'
echo '--- RECENT LOGS ---'
docker logs --tail 80 mailserver 2>&1 | tail -80
echo '--- PORTS ---'
for p in 25 465 587 993 8443; do
  if timeout 2 bash -c "</dev/tcp/127.0.0.1/$p" 2>/dev/null; then echo "$p OPEN"; else echo "$p CLOSED"; fi
done
echo '--- SMTP RAW ---'
timeout 8 openssl s_client -connect 127.0.0.1:587 -starttls smtp -servername mail.neruds.org -showcerts </dev/null 2>&1 | head -80 || true
echo '--- IMAPS RAW ---'
timeout 8 openssl s_client -connect 127.0.0.1:993 -servername mail.neruds.org -showcerts </dev/null 2>&1 | head -80 || true
