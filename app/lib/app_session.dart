import 'package:flutter/foundation.dart';

class AppSession extends ChangeNotifier {
  AppSession._();

  static final AppSession instance = AppSession._();

  String? token;
  String? username;
  String? _identityUsername;
  List<String> roles = const [];
  bool canReview = false;
  bool canPublish = false;
  bool canAdminUsers = false;
  bool expired = false;
  int _identityEpoch = 0;

  int get identityEpoch => _identityEpoch;
  String? get reauthenticationUsername => _identityUsername;

  bool get authenticated => token != null && token!.isNotEmpty;

  Map<String, String> get authHeaders => {
    if (authenticated) 'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  void setSession({
    required String tokenValue,
    required String usernameValue,
    List<String> rolesValue = const [],
    bool canReviewValue = false,
    bool canPublishValue = false,
    bool canAdminUsersValue = false,
  }) {
    if (usernameValue != _identityUsername) {
      _identityEpoch++;
    }
    _identityUsername = usernameValue;
    token = tokenValue;
    username = usernameValue;
    roles = List.unmodifiable(rolesValue);
    canReview = canReviewValue;
    canPublish = canPublishValue;
    canAdminUsers = canAdminUsersValue;
    expired = false;
    notifyListeners();
  }

  /// A same-user sign-in can resume unsaved work after an expired session.
  void expire() {
    if (!authenticated) return;
    _resetCredentials();
    expired = true;
    notifyListeners();
  }

  /// Explicit sign-out ends the association with all unsaved local work.
  void clear() {
    _resetCredentials();
    _identityUsername = null;
    expired = false;
    _identityEpoch++;
    notifyListeners();
  }

  void _resetCredentials() {
    token = null;
    username = null;
    roles = const [];
    canReview = false;
    canPublish = false;
    canAdminUsers = false;
  }
}
