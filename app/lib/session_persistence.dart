import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'app_session.dart';
import 'bridge_http.dart' as http;

/// Persists the bridge bearer token so a sign-in survives app restarts and
/// works across web, desktop and mobile without machine-local state.
///
/// The token itself is issued by the bridge (backed by the Drupal session
/// stored server-side). On startup [restoreStoredSession] validates it
/// against `/me`; a 401 means the server session is gone and the token is
/// discarded locally.
const _kToken = 'neruds.session.token';
const _kUsername = 'neruds.session.username';

bool _attached = false;
bool _restored = false;

/// Mirrors session changes into persistent storage. Idempotent.
void attachSessionPersistence() {
  if (_attached) return;
  _attached = true;
  AppSession.instance.addListener(_syncStoredSession);
}

Future<void> _syncStoredSession() async {
  final prefs = await SharedPreferences.getInstance();
  final session = AppSession.instance;
  final token = session.token;
  if (session.authenticated && token != null) {
    await prefs.setString(_kToken, token);
    await prefs.setString(_kUsername, session.username ?? '');
  } else {
    await prefs.remove(_kToken);
    await prefs.remove(_kUsername);
  }
}

/// Validates a stored token against the bridge and restores the session.
/// Runs at most once per process; safe to call from `initState`.
Future<bool> restoreStoredSession() async {
  if (_restored) return AppSession.instance.authenticated;
  _restored = true;
  attachSessionPersistence();
  if (!AppConfig.isConfigured) return false;
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString(_kToken);
  if (token == null || token.isEmpty) return false;
  try {
    final response = await http.get(
      AppConfig.endpoint('/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      // A manual sign-in during this request must not be overwritten.
      if (AppSession.instance.authenticated) return true;
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      AppSession.instance.setSession(
        tokenValue: token,
        usernameValue:
            data['username']?.toString() ??
            prefs.getString(_kUsername) ??
            '',
        rolesValue: (data['roles'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(),
        canReviewValue: data['can_review'] == true,
        canPublishValue: data['can_publish'] == true,
        canAdminUsersValue: data['can_admin_users'] == true,
      );
      return true;
    }
    if (response.statusCode == 401) {
      await prefs.remove(_kToken);
      await prefs.remove(_kUsername);
    }
  } catch (_) {
    // Bridge unreachable: keep the token for the next app start.
  }
  return false;
}
