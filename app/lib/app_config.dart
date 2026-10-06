import 'package:flutter/foundation.dart';

/// Computer-specific addresses are supplied at build time, never in source.
class AppConfig {
  AppConfig._();

  static const _bridge = String.fromEnvironment('NERUDS_BRIDGE_URL');
  static const _portal = String.fromEnvironment('NERUDS_PORTAL_URL');
  static String? _testBridge;
  static String? _testPortal;
  static String? _discoveredPortal;

  static String get bridgeUrl => (_testBridge ?? _bridge).trim();
  static String get portalUrl =>
      (_testPortal ?? (_portal.isNotEmpty ? _portal : _discoveredPortal) ?? '')
          .trim();

  static bool get isConfigured {
    final uri = webUri(bridgeUrl);
    return uri != null && !uri.hasQuery && !uri.hasFragment;
  }

  static Uri? webUri(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  static Uri endpoint(String path) {
    final base = webUri(bridgeUrl);
    if (base == null || base.hasQuery || base.hasFragment) {
      throw const AppConfigurationException();
    }
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw ArgumentError.value(path, 'path', 'Use a service-relative path.');
    }
    return Uri.parse('${bridgeUrl.replaceAll(RegExp(r'/+$'), '')}$path');
  }

  static void rememberPortalUrl(String? value) {
    final uri = webUri(value);
    if (uri != null && !uri.hasQuery && !uri.hasFragment) {
      _discoveredPortal = uri.toString().replaceAll(RegExp(r'/+$'), '');
    }
  }

  @visibleForTesting
  static void configureForTesting({String? bridgeUrl, String? portalUrl}) {
    _testBridge = bridgeUrl;
    _testPortal = portalUrl;
    _discoveredPortal = null;
  }
}

class AppConfigurationException implements Exception {
  const AppConfigurationException();
}
