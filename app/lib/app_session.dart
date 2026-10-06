import 'package:flutter/foundation.dart';

class AppSession extends ChangeNotifier {
  AppSession._();

  static final AppSession instance = AppSession._();

  String? token;
  String? username;
  List<String> roles = const [];
  bool canReview = false;
  bool canPublish = false;
  bool canAdminUsers = false;

  bool get authenticated => token != null && token!.isNotEmpty;

  Map<String, String> get authHeaders => {
        if (token != null) 'Authorization': 'Bearer $token',
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
    token = tokenValue;
    username = usernameValue;
    roles = List.unmodifiable(rolesValue);
    canReview = canReviewValue;
    canPublish = canPublishValue;
    canAdminUsers = canAdminUsersValue;
    notifyListeners();
  }

  void clear() {
    token = null;
    username = null;
    roles = const [];
    canReview = false;
    canPublish = false;
    canAdminUsers = false;
    notifyListeners();
  }
}
