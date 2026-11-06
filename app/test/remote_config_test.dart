import 'package:flutter_test/flutter_test.dart';
import 'package:neruds_control_center/remote_config.dart';

void main() {
  tearDown(() {
    RemoteConfig.instance.apply(const {});
  });

  test('feature falls back to true before any remote payload', () {
    RemoteConfig.instance.apply(const {});
    expect(RemoteConfig.instance.feature('monitoring'), isTrue);
    expect(RemoteConfig.instance.feature('opportunities'), isTrue);
  });

  test('feature flags read from remote payload', () {
    RemoteConfig.instance.apply(const {
      'features': {'monitoring': false, 'opportunities': true},
    });
    expect(RemoteConfig.instance.feature('monitoring'), isFalse);
    expect(RemoteConfig.instance.feature('opportunities'), isTrue);
    expect(RemoteConfig.instance.feature('missions'), isTrue);
  });

  test('onboardingEnabled respects remote flag', () {
    RemoteConfig.instance.apply(const {
      'onboarding': {'enabled': false},
    });
    expect(RemoteConfig.instance.onboardingEnabled, isFalse);
    RemoteConfig.instance.apply(const {
      'onboarding': {'enabled': true},
    });
    expect(RemoteConfig.instance.onboardingEnabled, isTrue);
  });

  test('announcement trims and ignores empty values', () {
    RemoteConfig.instance.apply(const {'announcement': '  Manutenção às 20h  '});
    expect(RemoteConfig.instance.announcement, 'Manutenção às 20h');
    RemoteConfig.instance.apply(const {'announcement': '   '});
    expect(RemoteConfig.instance.announcement, isNull);
    RemoteConfig.instance.apply(const {});
    expect(RemoteConfig.instance.announcement, isNull);
  });

  test('appName falls back to compiled default', () {
    RemoteConfig.instance.apply(const {});
    expect(RemoteConfig.instance.appName, 'NERUDS Control Center');
    RemoteConfig.instance.apply(const {'app_name': 'NERUDS Hub'});
    expect(RemoteConfig.instance.appName, 'NERUDS Hub');
  });

  test('malformed payloads do not throw', () {
    RemoteConfig.instance.apply(const {
      'features': 'broken',
      'onboarding': 42,
      'announcement': 7,
      'app_name': 3.14,
    });
    expect(RemoteConfig.instance.feature('monitoring'), isTrue);
    expect(RemoteConfig.instance.onboardingEnabled, isTrue);
    expect(RemoteConfig.instance.announcement, isNull);
    expect(RemoteConfig.instance.appName, 'NERUDS Control Center');
  });
}
