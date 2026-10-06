<?php

declare(strict_types=1);

namespace Drupal\neruds_extensionista_guard\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Session\AccountProxyInterface;
use Drupal\user\UserInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;

/**
 * Extensionista account lifecycle for the NERUDS Control Center.
 *
 * These endpoints keep account administration behind the dedicated
 * "administer neruds extensionistas" permission so the bridge never needs
 * a generic "administer users" grant.
 */
final class IdentityController extends ControllerBase {

  public function __construct(
    private readonly AccountProxyInterface $account,
    private readonly EntityTypeManagerInterface $entityTypes,
  ) {}

  public static function create(ContainerInterface $container): static {
    return new static(
      $container->get('current_user'),
      $container->get('entity_type.manager'),
    );
  }

  public function listAccounts(): JsonResponse {
    $storage = $this->entityTypes->getStorage('user');
    $uids = $storage->getQuery()
      ->accessCheck(FALSE)
      ->condition('roles', 'extensionista')
      ->sort('uid')
      ->execute();

    $accounts = [];
    foreach ($storage->loadMultiple($uids) as $user) {
      $accounts[] = $this->serializeAccount($user);
    }

    return new JsonResponse([
      'accounts' => $accounts,
      'actor' => $this->account->getAccountName(),
    ]);
  }

  public function createAccount(Request $request): JsonResponse {
    $payload = json_decode($request->getContent(), TRUE) ?: [];
    $name = trim((string) ($payload['name'] ?? ''));
    $mail = trim((string) ($payload['mail'] ?? ''));

    if ($name === '' || $mail === '' || !filter_var($mail, FILTER_VALIDATE_EMAIL)) {
      return new JsonResponse(['detail' => 'Informe name e mail válidos.'], 422);
    }

    $storage = $this->entityTypes->getStorage('user');
    $nameTaken = (bool) $storage->getQuery()
      ->accessCheck(FALSE)
      ->condition('name', $name)
      ->range(0, 1)
      ->execute();
    $mailTaken = (bool) $storage->getQuery()
      ->accessCheck(FALSE)
      ->condition('mail', $mail)
      ->range(0, 1)
      ->execute();
    if ($nameTaken || $mailTaken) {
      return new JsonResponse(['detail' => 'Nome ou e-mail já cadastrado no Drupal.'], 409);
    }

    $temporaryPassword = NULL;
    $password = (string) ($payload['pass'] ?? '');
    if ($password === '') {
      $temporaryPassword = user_password(24);
      $password = $temporaryPassword;
    }

    /** @var \Drupal\user\UserInterface $user */
    $user = $storage->create([
      'name' => $name,
      'mail' => $mail,
      'pass' => $password,
      'status' => 1,
      'roles' => ['extensionista'],
    ]);
    $user->save();

    $result = $this->serializeAccount($user);
    if ($temporaryPassword !== NULL) {
      $result['temporary_password'] = $temporaryPassword;
    }
    $result['created_by'] = $this->account->getAccountName();

    return new JsonResponse($result, 201);
  }

  public function setStatus(int $uid, Request $request): JsonResponse {
    $payload = json_decode($request->getContent(), TRUE) ?: [];
    $active = (bool) ($payload['active'] ?? FALSE);
    $user = $this->loadExtensionista($uid);
    if (!$user) {
      return new JsonResponse(['detail' => 'Conta extensionista não encontrada.'], 404);
    }

    if ($active) {
      $user->activate();
    }
    else {
      $user->block();
    }
    $user->save();

    $result = $this->serializeAccount($user);
    $result['changed_by'] = $this->account->getAccountName();
    return new JsonResponse($result);
  }

  public function passwordReset(int $uid): JsonResponse {
    $user = $this->loadExtensionista($uid);
    if (!$user) {
      return new JsonResponse(['detail' => 'Conta extensionista não encontrada.'], 404);
    }
    if ($user->isBlocked()) {
      return new JsonResponse(['detail' => 'Conta bloqueada não aceita reset de senha.'], 409);
    }

    return new JsonResponse([
      'uid' => (int) $user->id(),
      'name' => $user->getAccountName(),
      'reset_url' => user_pass_reset_url($user),
      'issued_by' => $this->account->getAccountName(),
    ]);
  }

  private function loadExtensionista(int $uid): ?UserInterface {
    $user = $this->entityTypes->getStorage('user')->load($uid);
    if (!$user instanceof UserInterface) {
      return NULL;
    }
    if (!in_array('extensionista', $user->getRoles(), TRUE)) {
      return NULL;
    }
    return $user;
  }

  private function serializeAccount(UserInterface $user): array {
    $nodeStorage = $this->entityTypes->getStorage('node');
    $authored = (int) $nodeStorage->getQuery()
      ->accessCheck(FALSE)
      ->condition('uid', $user->id())
      ->count()
      ->execute();
    $pendingDrafts = (int) $nodeStorage->getQuery()
      ->accessCheck(FALSE)
      ->condition('uid', $user->id())
      ->condition('status', 0)
      ->count()
      ->execute();

    return [
      'uid' => (int) $user->id(),
      'name' => $user->getAccountName(),
      'mail' => $user->getEmail(),
      'active' => $user->isActive(),
      'roles' => array_values($user->getRoles()),
      'created' => (int) $user->getCreatedTime(),
      'last_access' => $user->getLastAccessedTime() ? (int) $user->getLastAccessedTime() : NULL,
      'last_login' => $user->getLastLoginTime() ? (int) $user->getLastLoginTime() : NULL,
      'authored_nodes' => $authored,
      'pending_drafts' => $pendingDrafts,
    ];
  }

}
