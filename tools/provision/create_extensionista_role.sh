set -e
cd /var/www/html
vendor/bin/drush php:eval '
use Drupal\user\Entity\Role;

$permissions = [
  "access content",
  "access user profiles",
  "create noticia content",
  "edit own noticia content",
  "create relatorio content",
  "edit own relatorio content",
  "view own unpublished content",
  "use basic_editorial transition create_new_draft",
];

$storage = \Drupal::entityTypeManager()->getStorage("user_role");
$role = $storage->load("extensionista");
if (!$role) {
  $role = Role::create([
    "id" => "extensionista",
    "label" => "Extensionista",
  ]);
}
foreach ($role->getPermissions() as $existing) {
  $role->revokePermission($existing);
}
foreach ($permissions as $permission) {
  $role->grantPermission($permission);
}
$role->save();

$role = $storage->loadUnchanged("extensionista");
echo "ROLE|".$role->id()."|".$role->label().PHP_EOL;
foreach ($role->getPermissions() as $permission) {
  echo "PERM|".$permission.PHP_EOL;
}
'
