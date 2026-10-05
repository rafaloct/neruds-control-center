set -e
SRC=/etc/letsencrypt/live/mail.neruds.org
DST=/opt/poste_data/ssl
cp "$DST/server.crt" "$DST/server.crt.leaf-backup"
install -m 0644 "$SRC/fullchain.pem" "$DST/server.crt"

HOOK=/etc/letsencrypt/renewal-hooks/deploy/poste-mail-cert.sh
cat > "$HOOK" <<'EOF'
#!/bin/sh
set -eu
SRC=/etc/letsencrypt/live/mail.neruds.org
DST=/opt/poste_data/ssl
[ -f "$SRC/fullchain.pem" ] || exit 0
install -m 0644 "$SRC/fullchain.pem" "$DST/server.crt"
install -m 0644 "$SRC/chain.pem" "$DST/ca.crt"
install -m 0600 "$SRC/privkey.pem" "$DST/server.key"
docker restart mailserver >/dev/null
EOF
chmod 0750 "$HOOK"

docker restart mailserver >/dev/null
sleep 12

check_tls() {
  label="$1"; shift
  echo "$label"
  timeout 10 openssl s_client "$@" -servername mail.neruds.org </dev/null 2>&1 | grep -E 'subject=|issuer=|Verify return code' | tail -6
}

check_tls SMTP -connect 127.0.0.1:587 -starttls smtp
check_tls IMAPS -connect 127.0.0.1:993
check_tls HTTPS8443 -connect 127.0.0.1:8443
