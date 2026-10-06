<?php

declare(strict_types=1);

namespace Drupal\neruds_extensionista_guard\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Session\AccountProxyInterface;
use Drupal\node\NodeInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

final class ControlController extends ControllerBase {

  public function __construct(
    private readonly AccountProxyInterface $account,
  ) {}

  public static function create(ContainerInterface $container): static {
    return new static(
      $container->get('current_user'),
    );
  }

  public function session(): JsonResponse {
    return new JsonResponse([
      'uid' => (int) $this->account->id(),
      'username' => $this->account->getAccountName(),
      'roles' => array_values($this->account->getRoles()),
      'can_review' => $this->account->hasPermission('review neruds news'),
      'can_publish' => $this->account->hasPermission('publish neruds news'),
      'can_admin_users' => $this->account->hasPermission('administer neruds extensionistas'),
    ]);
  }

  public function publishNews(NodeInterface $node): JsonResponse {
    if ($node->bundle() !== 'noticia') {
      throw new NotFoundHttpException();
    }

    if (!$node->isPublished()) {
      $node->setNewRevision(TRUE);
      $node->setRevisionUserId((int) $this->account->id());
      $node->setRevisionLogMessage('Publicado pelo NERUDS Control Center após revisão.');
      $node->setPublished();
      $node->save();
    }

    return new JsonResponse([
      'ok' => TRUE,
      'nid' => (int) $node->id(),
      'published' => $node->isPublished(),
      'published_by' => $this->account->getAccountName(),
    ]);
  }

}
