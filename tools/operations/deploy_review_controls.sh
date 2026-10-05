set -e
cd /var/www/html
php -l web/modules/custom/neruds_extensionista_guard/src/Controller/ControlController.php
php -l web/modules/custom/neruds_extensionista_guard/neruds_extensionista_guard.module
vendor/bin/drush cr

vendor/bin/drush php:eval '
$storage = \Drupal::entityTypeManager()->getStorage("user_role");

$revisor = $storage->load("revisor");
if ($revisor) {
  $revisor->grantPermission("review neruds news");
  $revisor->save();
  echo "REVISOR_REVIEW=".($revisor->hasPermission("review neruds news")?"1":"0").PHP_EOL;
}

$editor = $storage->load("content_editor");
if ($editor) {
  $editor->grantPermission("review neruds news");
  $editor->grantPermission("publish neruds news");
  $editor->save();
  echo "EDITOR_REVIEW=".($editor->hasPermission("review neruds news")?"1":"0").PHP_EOL;
  echo "EDITOR_PUBLISH=".($editor->hasPermission("publish neruds news")?"1":"0").PHP_EOL;
}

$ext = $storage->load("extensionista");
if ($ext) {
  echo "EXT_REVIEW=".($ext->hasPermission("review neruds news")?"1":"0").PHP_EOL;
  echo "EXT_PUBLISH=".($ext->hasPermission("publish neruds news")?"1":"0").PHP_EOL;
}
'

vendor/bin/drush cr >/dev/null

echo '--- ROUTES ---'
curl -ksS -I https://neruds.org/neruds-control/session | head -8
