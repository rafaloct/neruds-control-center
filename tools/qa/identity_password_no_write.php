<?php

declare(strict_types=1);

// Run with drush php:script after bootstrap. The selected controller is loaded
// without changing the live container. User creation/save and queries are fakes.
$qaControllerPath = getenv('NERUDS_QA_CONTROLLER_PATH');
if (!$qaControllerPath || !is_file($qaControllerPath)) {
  throw new RuntimeException('Set NERUDS_QA_CONTROLLER_PATH to the candidate PHP file.');
}
$qaControllerClass = \Drupal\neruds_extensionista_guard\Controller\IdentityController::class;
if (class_exists($qaControllerClass, FALSE)) {
  $qaLoadedPath = (new ReflectionClass($qaControllerClass))->getFileName();
  if (realpath($qaLoadedPath) !== realpath($qaControllerPath)) {
    throw new RuntimeException('Controller already loaded from a different path; use a fresh drush process.');
  }
}
else {
  require $qaControllerPath;
}

$qaState = (object) ['created' => 0, 'saved' => 0, 'values' => []];

$qaUser = new class([], $qaState) extends \Drupal\user\Entity\User {
  public function __construct(private array $qaValues, private object $qaState) {}
  public function withValues(array $values): self {
    return new self($values, $this->qaState);
  }
  public function save() { $this->qaState->saved++; return 1; }
  public function id() { return 42424242; }
  public function getAccountName() { return $this->qaValues['name']; }
  public function getEmail() { return $this->qaValues['mail']; }
  public function isActive() { return (bool) $this->qaValues['status']; }
  public function getRoles($exclude_locked_roles = FALSE) { return $this->qaValues['roles']; }
  public function getCreatedTime() { return 1; }
  public function getLastAccessedTime() { return 0; }
  public function getLastLoginTime() { return 0; }
};

$qaStorage = new class($qaState, $qaUser) {
  public function __construct(private object $qaState, private object $qaUser) {}
  public function getQuery($conjunction = 'AND'): object {
    return new class {
      private bool $qaCount = FALSE;
      public function accessCheck($enabled = TRUE): self { return $this; }
      public function condition($field, $value = NULL, $operator = NULL, $langcode = NULL): self { return $this; }
      public function range($start = NULL, $length = NULL): self { return $this; }
      public function count(): self { $this->qaCount = TRUE; return $this; }
      public function execute(): array|int { return $this->qaCount ? 0 : []; }
    };
  }
  public function create(array $values = []): \Drupal\user\UserInterface {
    $this->qaState->created++;
    $this->qaState->values = $values;
    return $this->qaUser->withValues($values);
  }
};

$qaManager = new class($qaStorage) extends \Drupal\Core\Entity\EntityTypeManager {
  public function __construct(private object $qaStorage) {}
  public function getStorage($entity_type_id) {
    if (!in_array($entity_type_id, ['user', 'node'], TRUE)) {
      throw new RuntimeException('Unexpected storage requested.');
    }
    return $this->qaStorage;
  }
};

$qaRealContainer = \Drupal::getContainer();
$qaGenerator = $qaRealContainer->get('password_generator');
if (!$qaGenerator instanceof \Drupal\Core\Password\PasswordGeneratorInterface) {
  throw new RuntimeException('The real password generator does not implement the expected interface.');
}
// This adapter is deliberately not installed as Drupal's global container.
$qaContainer = new \Symfony\Component\DependencyInjection\ContainerBuilder();
$qaContainer->set('current_user', $qaRealContainer->get('current_user'));
$qaContainer->set('entity_type.manager', $qaManager);
$qaContainer->set('password_generator', $qaGenerator);
$qaController = $qaControllerClass::create($qaContainer);
$qaRequest = \Symfony\Component\HttpFoundation\Request::create(
  '/qa/identity-no-write',
  'POST',
  [],
  [],
  [],
  ['CONTENT_TYPE' => 'application/json'],
  json_encode(['name' => 'qa.identity.memory', 'mail' => 'qa.identity@example.invalid'], JSON_THROW_ON_ERROR),
);
$qaResponse = $qaController->createAccount($qaRequest);
$qaBody = json_decode($qaResponse->getContent(), TRUE, 512, JSON_THROW_ON_ERROR);
$qaCheck = static function (bool $condition, string $label): void {
  if (!$condition) {
    throw new RuntimeException('FAIL ' . $label);
  }
  echo 'PASS ' . $label . PHP_EOL;
};
$qaCheck($qaResponse->getStatusCode() === 201, 'createAccount without password returns 201');
$qaPassword = $qaBody['temporary_password'] ?? NULL;
$qaCheck(is_string($qaPassword) && strlen($qaPassword) === 24, 'real generator returns a 24-character temporary password');
$qaCheck(hash_equals((string) ($qaState->values['pass'] ?? ''), (string) $qaPassword), 'returned password matches the in-memory user value');
$qaCheck($qaState->created === 1 && $qaState->saved === 1, 'one in-memory create and intercepted save');
$qaCheck(($qaBody['active'] ?? FALSE) === TRUE && in_array('extensionista', $qaBody['roles'] ?? [], TRUE), 'active extensionista response preserved');
$qaCheck(\Drupal::getContainer() === $qaRealContainer, 'global Drupal container unchanged');
echo 'IDENTITY_PASSWORD_REGRESSION=PASS' . PHP_EOL;
echo 'REAL_USER_WRITES=0 (storage and save are in-memory stubs)' . PHP_EOL;
unset($qaBody, $qaPassword, $qaState, $qaUser, $qaStorage, $qaManager, $qaController);


// Isolated CSRF regression: real core checks, in-memory session, fixture key.
$qaRoutesPath = getenv('NERUDS_QA_ROUTES_PATH');
if (!$qaRoutesPath || !is_file($qaRoutesPath)) {
  throw new RuntimeException('Set NERUDS_QA_ROUTES_PATH to the candidate routing YAML.');
}
$qaRoutes = \Symfony\Component\Yaml\Yaml::parseFile($qaRoutesPath);
$qaMetadata = new \Drupal\Core\Session\MetadataBag(\Drupal\Core\Site\Settings::getInstance());
$qaSession = new \Symfony\Component\HttpFoundation\Session\Session(new \Symfony\Component\HttpFoundation\Session\Storage\MockArraySessionStorage('QA_CSRF', $qaMetadata));
$qaSession->start();
$qaKey = new class extends \Drupal\Core\PrivateKey {
  public function __construct() {}
  public function get() { return 'qa-csrf-memory-fixture-key'; }
};
$qaCsrfGenerator = new \Drupal\Core\Access\CsrfTokenGenerator($qaKey, $qaMetadata);
$qaSessionConfig = new \Drupal\Core\Session\SessionConfiguration(['cookie_domain' => '.example.invalid']);
$qaCsrfChecker = new \Drupal\Core\Access\CsrfRequestHeaderAccessCheck($qaSessionConfig, $qaCsrfGenerator);
$qaHttp = \Symfony\Component\HttpFoundation\Request::create('https://example.invalid/neruds-control/extensionistas', 'POST');
$qaHttp->setSession($qaSession);
$qaHttp->cookies->set($qaSessionConfig->getOptions($qaHttp)['name'], 'qa-memory-session');
$qaUserSession = new \Drupal\Core\Session\UserSession(['uid' => 42424242, 'name' => 'qa.memory', 'roles' => ['authenticated', 'content_editor']]);
foreach (['extensionistas_create', 'extensionistas_status', 'extensionistas_password_reset'] as $qaRouteName) {
  $qaEntry = $qaRoutes['neruds_extensionista_guard.' . $qaRouteName];
  $qaRoute = new \Symfony\Component\Routing\Route($qaEntry['path']);
  $qaRoute->setRequirements($qaEntry['requirements']);
  $qaRoute->setMethods($qaEntry['methods']);
  $qaCheck($qaCsrfChecker->applies($qaRoute) === TRUE
    && ($qaEntry['requirements']['_permission'] ?? '') === 'administer neruds extensionistas'
    && !isset($qaEntry['requirements']['_csrf_token'])
    && ($qaEntry['requirements']['_csrf_request_header_token'] ?? '') === 'TRUE'
    && $qaRoute->getMethods() === ['POST'] && ($qaEntry['options']['no_cache'] ?? FALSE) === TRUE,
    $qaRouteName . ' retains permission, POST, no_cache and requires header CSRF');
}
$qaPublish = $qaRoutes['neruds_extensionista_guard.publish_news']['requirements'];
$qaCheck(($qaPublish['_csrf_token'] ?? '') === 'TRUE' && !isset($qaPublish['_csrf_request_header_token']), 'publish_news CSRF requirement unchanged');
$qaCheck($qaUserSession->isAuthenticated() && $qaSessionConfig->hasSession($qaHttp), 'authenticated fixture and session cookie exercise CSRF validation');
$qaCheck($qaCsrfChecker->access($qaHttp, $qaUserSession)->isForbidden(), 'missing header is forbidden');
$qaHttp->headers->set('X-CSRF-Token', 'invalid-qa-token');
$qaCheck($qaCsrfChecker->access($qaHttp, $qaUserSession)->isForbidden(), 'invalid header is forbidden');
$qaToken = (new \Drupal\system\Controller\CsrfTokenController($qaCsrfGenerator))->csrfToken()->getContent();
$qaHttp->headers->set('X-CSRF-Token', $qaToken);
$qaCheck($qaCsrfChecker->access($qaHttp, $qaUserSession)->isAllowed(), 'token from real CsrfTokenController passes header checker');
$qaLegacyRoute = new \Symfony\Component\Routing\Route('/neruds-control/extensionistas', [], ['_csrf_token' => 'TRUE']);
$qaLegacyMatch = new \Drupal\Core\Routing\RouteMatch('neruds_extensionista_guard.extensionistas_create', $qaLegacyRoute);
$qaLegacyResult = (new \Drupal\Core\Access\CsrfAccessCheck($qaCsrfGenerator))->access($qaLegacyRoute, $qaHttp, $qaLegacyMatch);
$qaCheck($qaLegacyResult->isForbidden() && $qaLegacyResult->getReason() === "'csrf_token' URL query argument is missing.", 'legacy URL-token checker rejects the valid header before reaching controller');
echo 'LEGACY_CSRF_REASON=' . $qaLegacyResult->getReason() . PHP_EOL;
$qaCheck(\Drupal::getContainer() === $qaRealContainer, 'global container unchanged after CSRF checks');
echo 'IDENTITY_CSRF_REGRESSION=PASS' . PHP_EOL;
echo 'REAL_USER_AND_SESSION_WRITES=0 (CSRF uses MockArraySessionStorage)' . PHP_EOL;
unset($qaToken, $qaKey, $qaSession, $qaMetadata, $qaCsrfGenerator, $qaCsrfChecker, $qaHttp);
