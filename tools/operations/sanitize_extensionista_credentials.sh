set -e
f=/root/neruds_extensionista_credentials.tsv
if [ ! -f "$f" ]; then
  echo CREDENTIAL_FILE_NOT_FOUND
  exit 0
fi
cp "$f" "$f.before-portal-password-rotation"
chmod 600 "$f.before-portal-password-rotation"
awk -F '\t' 'BEGIN{OFS="\t"} {$3="ROTATED_NOT_STORED"; print}' "$f" > "$f.tmp"
chmod 600 "$f.tmp"
mv "$f.tmp" "$f"
echo PORTAL_PASSWORD_FIELD_SANITIZED
stat -c '%a|%U|%G|%s|%n' "$f"
