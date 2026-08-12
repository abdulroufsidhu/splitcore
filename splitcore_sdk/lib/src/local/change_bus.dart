// Announces which tables a committed write touched. Every `watch*` stream
// in the SDK is this plus a re-query — table granularity, not row, because
// re-querying one group's rows is cheap and row-level tracking is a whole
// invalidation protocol nobody asked for.
import 'dart:async';

class ChangeBus {
  final _controller = StreamController<Set<String>>.broadcast();

  Stream<Set<String>> get changes => _controller.stream;

  /// Announces [tables]. Called only after a transaction commits — an
  /// announcement for a rolled-back write would make listeners re-query and
  /// see nothing, or worse, act on a write that never happened.
  void emit(Set<String> tables) {
    if (tables.isEmpty || _controller.isClosed) return;
    _controller.add(tables);
  }

  Future<void> close() => _controller.close();
}
