import 'package:flutter/foundation.dart';

/// Tracks in-memory proposals so an intentional sign-out can protect them.
class UnsavedWork extends ChangeNotifier {
  UnsavedWork._();
  static final UnsavedWork instance = UnsavedWork._();
  final Set<Object> _owners = {};

  bool get hasChanges => _owners.isNotEmpty;

  void setDirty(Object owner, bool dirty) {
    final changed = dirty ? _owners.add(owner) : _owners.remove(owner);
    if (changed) notifyListeners();
  }

  void remove(Object owner) => setDirty(owner, false);
}
