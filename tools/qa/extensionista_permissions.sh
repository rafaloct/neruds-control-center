set -e
cd /var/www/html
vendor/bin/drush php:eval '
$storage = \Drupal::entityTypeManager()->getStorage("user");
$user = reset($storage->loadByProperties(["name" => "extensionista.1"]));
$handler = \Drupal::entityTypeManager()->getAccessControlHandler("node");
echo "CREATE_NOTICIA|".($handler->createAccess("noticia", $user) ? "ALLOW" : "DENY").PHP_EOL;
echo "CREATE_RELATORIO|".($handler->createAccess("relatorio", $user) ? "ALLOW" : "DENY").PHP_EOL;
echo "CREATE_PAGE|".($handler->createAccess("page", $user) ? "ALLOW" : "DENY").PHP_EOL;
echo "PUBLISH_PERMISSION|".($user->hasPermission("use basic_editorial transition publish") ? "ALLOW" : "DENY").PHP_EOL;
echo "DELETE_OWN_NOTICIA|".($user->hasPermission("delete own noticia content") ? "ALLOW" : "DENY").PHP_EOL;
$node = \Drupal\node\Entity\Node::create([
  "type" => "noticia",
  "title" => "[TESTE] Permissoes Extensionista - remover",
  "uid" => $user->id(),
  "status" => 0,
  "body" => ["value" => "Teste temporario de permissao.", "format" => "basic_html"],
]);
$node->save();
echo "TEST_NODE_CREATED|".$node->id()."|status=".$node->isPublished()."|owner=".$node->getOwnerId().PHP_EOL;
echo "UPDATE_OWN|".($node->access("update", $user) ? "ALLOW" : "DENY").PHP_EOL;
echo "DELETE_NODE_ACCESS|".($node->access("delete", $user) ? "ALLOW" : "DENY").PHP_EOL;
$node->delete();
echo "TEST_NODE_DELETED|OK".PHP_EOL;
'
