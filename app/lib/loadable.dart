// One async value with the three states every screen actually has:
// loading, failed (with a way to try again), and loaded. Every screen was
// hand-rolling this as a (data, error, loading) triple plus two setState
// blocks, and none of them offered a retry — the only recovery from a
// failed load was to leave the screen and come back.
//
// The loader is injected rather than reached for, which is also what makes
// a screen widget-testable: a test hands it a function returning fixtures
// instead of a live SDK and server.
import 'package:flutter/foundation.dart';

class Loadable<T> extends ChangeNotifier {
  Loadable(this._loader);

  final Future<T> Function() _loader;

  T? _value;
  Object? _error;
  bool _isLoading = false;

  T? get value => _value;
  Object? get error => _error;
  bool get isLoading => _isLoading;

  /// True on the very first load, when there is nothing to show yet — the
  /// difference between "show a skeleton" and "keep the list on screen
  /// while it refreshes".
  bool get isInitialLoad => _isLoading && _value == null;

  /// Runs the loader. A reload keeps the previous value: blanking a
  /// populated list back to a skeleton on every refresh reads as the app
  /// losing the data, and a refresh that fails should leave the last good
  /// data on screen rather than replacing it with an error.
  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _value = await _loader();
    } catch (e) {
      _error = e;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Same as [load]; named separately so call sites read as what the user
  /// did ("tapped Retry") rather than what the code does.
  Future<void> retry() => load();

  /// Replaces the value without a round trip — for a screen that just
  /// created or edited a row and already knows the new state.
  void setValue(T value) {
    _value = value;
    _error = null;
    notifyListeners();
  }
}
