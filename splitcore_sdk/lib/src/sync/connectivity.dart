// How the SDK learns that the network came back, without depending on
// Flutter. Every real implementation lives outside this package: the app
// wraps connectivity_plus, a CLI could watch a socket. The SDK only needs
// the transition.
import 'dart:async';

abstract class ConnectivityMonitor {
  /// Emits on every *transition*. A repeated status must not emit — the
  /// sync engine treats each event as "the network just came back" and
  /// would otherwise resync on every duplicate notification the platform
  /// decides to send.
  Stream<bool> get onStatusChange;

  Future<bool> isOnline();
}

/// The default when the caller supplies nothing: assume a connection and
/// let requests fail normally. Behaviourally identical to the SDK before
/// offline support existed.
class AlwaysOnline implements ConnectivityMonitor {
  @override
  Stream<bool> get onStatusChange => const Stream.empty();

  @override
  Future<bool> isOnline() async => true;
}

/// Drives connectivity by hand. Exported rather than confined to `test/` so
/// the app can use it in widget tests too — a sync engine waiting on a real
/// clock is a flaky-test generator.
class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({bool online = true}) : _online = online;

  bool _online;
  final _controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get onStatusChange => _controller.stream;

  @override
  Future<bool> isOnline() async => _online;

  void goOnline() => _set(true);

  void goOffline() => _set(false);

  void _set(bool value) {
    if (_online == value) return;
    _online = value;
    _controller.add(value);
  }

  Future<void> dispose() => _controller.close();
}
