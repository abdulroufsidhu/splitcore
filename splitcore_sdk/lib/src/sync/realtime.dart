// PocketBase's realtime channel, reduced to the one signal the engine
// needs: "something you can see changed".
//
// The payload is deliberately ignored. Applying a record straight from an
// event would give the local database a second write path with its own
// ordering and its own bugs, and a client that missed events while
// backgrounded would silently diverge. Instead an event just marks the
// engine dirty and the existing version-cursored pull decides what actually
// changed — one code path, whether the wake came from SSE, a reconnect, or
// a manual sync.
import 'dart:async';

import 'package:pocketbase/pocketbase.dart';

/// The collections whose changes affect what a member sees. `split_entries`
/// is absent on purpose: it never changes without its parent expense
/// changing too, so subscribing would double every event.
const _watched = ['groups', 'group_members', 'expenses', 'settlements', 'balances'];

class RealtimeSubscriber {
  RealtimeSubscriber(this._pb, this._onChanged);

  final PocketBase _pb;
  final void Function() _onChanged;

  final _unsubscribers = <UnsubscribeFunc>[];
  Timer? _debounce;
  bool _starting = false;

  bool get isActive => _unsubscribers.isNotEmpty;

  /// Subscribes if not already subscribed. Requires a session — PocketBase
  /// scopes realtime to what the caller may read — so this is called after a
  /// successful sync rather than at construction, when the SDK may not be
  /// signed in yet.
  Future<void> start() async {
    if (isActive || _starting || !_pb.authStore.isValid) return;
    _starting = true;
    try {
      for (final collection in _watched) {
        _unsubscribers.add(await _pb.collection(collection).subscribe('*', (_) => _schedule()));
      }
    } catch (_) {
      // Realtime is an optimisation, not a requirement: without it the app
      // still syncs on reconnect and on every write. Never let a failed
      // subscription fail the sync that triggered it.
      await stop();
    } finally {
      _starting = false;
    }
  }

  /// Coalesces a burst into one pull. Saving an expense writes the expense,
  /// its split entries and the recomputed balances, and every member's
  /// client sees all of them — without this each one would start its own
  /// pull of the same group.
  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _onChanged);
  }

  Future<void> stop() async {
    _debounce?.cancel();
    _debounce = null;
    final pending = List.of(_unsubscribers);
    _unsubscribers.clear();
    for (final unsubscribe in pending) {
      try {
        await unsubscribe();
      } catch (_) {
        // Already torn down by a dropped connection. Nothing to undo.
      }
    }
  }
}
