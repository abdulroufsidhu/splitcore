// Adapts connectivity_plus to the SDK's ConnectivityMonitor. This lives in
// the app rather than the SDK because connectivity_plus is a Flutter plugin
// and splitcore_sdk is pure Dart.
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

class ConnectivityPlusMonitor implements ConnectivityMonitor {
  ConnectivityPlusMonitor() {
    _sub = _connectivity.onConnectivityChanged.listen((results) {
      final online = _isOnline(results);
      // Transitions only: Android re-announces the same state freely, and
      // the sync engine reads every event as "the network just came back".
      if (online == _last) return;
      _last = online;
      _controller.add(online);
    });
  }

  final _connectivity = Connectivity();
  final _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool? _last;

  @override
  Stream<bool> get onStatusChange => _controller.stream;

  @override
  Future<bool> isOnline() async => _isOnline(await _connectivity.checkConnectivity());

  // "Has an interface" is not "can reach the server" — a captive portal
  // passes this check. That is fine: the request failing is the real test,
  // and this only decides when it is worth trying.
  bool _isOnline(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
