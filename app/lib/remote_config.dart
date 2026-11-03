import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_config.dart';
import 'bridge_http.dart' as http;

/// Remote configuration served by the bridge at `/config/app`.
///
/// Lets ops toggle features, onboarding and announcements on all clients —
/// web, desktop and mobile — without a rebuild or redeploy. Loaded once per
/// app start; failures keep the safe defaults baked into the client.
class RemoteConfig extends ChangeNotifier {
  RemoteConfig._();

  static final RemoteConfig instance = RemoteConfig._();

  Map<String, dynamic> _data = const {};
  bool _loading = false;

  /// True after the first successful fetch this run.
  bool loaded = false;

  Map<String, dynamic> get data => _data;

  /// Loads (or reloads) the remote config. Safe to call repeatedly.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    try {
      final uri = AppConfig.endpoint('/config/app');
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        apply(jsonDecode(utf8.decode(response.bodyBytes)) as Map);
      }
    } catch (_) {
      // Bridge unreachable or not configured: keep defaults silently.
    } finally {
      _loading = false;
    }
  }

  /// Applies a fetched payload and notifies listeners.
  @visibleForTesting
  void apply(Map<dynamic, dynamic> payload) {
    _data = payload.map((k, v) => MapEntry(k.toString(), v));
    loaded = true;
    notifyListeners();
  }

  bool feature(String name, {bool fallback = true}) {
    final features = _data['features'];
    if (features is Map && features[name] is bool) {
      return features[name] as bool;
    }
    return fallback;
  }

  bool get onboardingEnabled {
    final onboarding = _data['onboarding'];
    if (onboarding is Map && onboarding['enabled'] is bool) {
      return onboarding['enabled'] as bool;
    }
    return true;
  }

  /// Optional banner text shown on the dashboard (e.g. maintenance notice).
  String? get announcement {
    final value = _data['announcement'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  /// Remote display name; falls back to the compiled-in default.
  String get appName {
    final value = _data['app_name'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return 'NERUDS Control Center';
  }
}
